import 'dart:convert';

import 'package:crypto/crypto.dart';

import '../../core/json.dart';
import '../../domain/auth.dart';
import '../../diagnostics/app_log.dart';
import '../http.dart';
import 'baidu_app_client.dart';
import 'baidu_link_service.dart';

/// 路线 3：本地取链 —— 不依赖任何自建服务端。
///
/// 与上游 [BaiduLinkService] 的唯一区别是"取链接"这一步在本地完成，
/// 因此不需要服务器、不需要域名、不需要 accessKey。
///
/// 接入方式（lib/data/cloud_repository.dart，约第 51 行）：
///
///   CloudPlatform.baidu: BaiduConnector(
///     http,
///     store: vault,
///     stageCleanup: _stageCleanup,
///     linkLookup: BaiduDirectLink(http, version: BaiduAppClient.version).resolve, // ← 仅此一行
///   ),
///
/// 资源占用：与上游一致 —— 不新增任何服务端负担。请求直接发自客户端，
/// 凭证是用户自己的 Cookie，瓶颈只有用户家宽出口带宽。
///
/// 需要自行验证的一点（见文件末尾）：百度对 App 端取链接口有签名校验。
/// [_appToken] 提供的是 `bdstoken`；若接口返回 errno 31023 / -6，
/// 需要按百度 App 的 Sign-1/2/3 算法补一个 `sign` 字段。
class BaiduDirectLink {
  /// [version] 默认取 [BaiduAppClient.version]，保证与 UA / serviceDevice 同源，
  /// 否则百度端 filemetas 的 `downloadVersion` 校验会失败。
  BaiduDirectLink(this.http, {this.appId = '250528', String? version})
    : version = version ?? BaiduAppClient.version,
      _client = BaiduAppClient();

  final BaiduAppClient _client;

  final JsonHttp http;

  /// 百度 Android 端 app_id（与 baidu.dart 的 defaultAppId 一致）。
  final String appId;

  /// 需要与 [BaiduAppClient.version] 保持一致。
  final String version;

  /// 百度 PC/App 端取链节点池。**刻意排除 `d.pcs.baidu.com`**，
  /// 否则会构成回环（百度把它当作"外部下载器"而返回受限直链）。
  static const _signServers = <String>[
    'pan.baidu.com',
    'pcs.baidu.com',
    'pan.baidu.com', // 轮换时提供两次命中机会
    'pcs.baidu.com',
  ];

  /// 百度直链的合法 host 白名单（与 BaiduLinkService 的校验保持一致）。
  static const _dlinkDomains = <String>[
    'baidu.com',
    'baidupcs.com',
    'baidubce.com',
  ];

  static int _rotation = 0;

  /// 复用 [BaiduAppClient] 的 UA，避免与 `serviceDevice.downloadVersion` 不一致。
  String get _ua => _client.downloadUserAgent;

  /// 与 [BaiduAppClient.parameters] 一致的 device 三元组，供取链接口使用。
  Map<String, Object?> get _deviceParams => _client.parameters;

  /// 符合 [BaiduLinkLookup] 签名，可直接注入 [BaiduConnector]。
  Future<BaiduResolvedLink> resolve({
    required String cookie,
    required String path,
    required String fileId,
    required Json device,
    required String appId,
  }) async {
    final ck = cookie.trim();
    require(ck.isNotEmpty, '百度登录已失效，请重新网页登录');

    final elapsed = Stopwatch()..start();
    final requestedVersion = device.str('downloadVersion');
    final fsId = fileId.trim().isEmpty || fileId.trim() == '0'
        ? await _fsIdByPath(ck, path)
        : fileId.trim();
    require(fsId.isNotEmpty, '百度文件或账号参数无效，请刷新列表');
    RequestScope.checkpoint();

    final token = _appToken(ck);

    // 依次尝试节点；每轮都是一次独立请求，不存在跨节点复用。
    Object? lastError;
    for (var i = 0; i < _signServers.length; i++) {
      final server = _signServers[(_rotation + i) % _signServers.length];
      try {
        final result = await http.get(
          'https://$server/rest/2.0/xpan/file'
          '?method=filemetas'
          '&dlink=1'
          '&thumb=0'
          '&fsids=${Uri.encodeComponent('[$fsId]')}'
          '&app_id=$appId'
          '&clienttype=0'
          '&channel=android_13_bd-netdisk_1'
          '&version=$version'
          '&bdstoken=$token'
          '&client_ua=${Uri.encodeComponent(_ua)}',
          {
            'Cookie': ck,
            'User-Agent': _ua,
            'Referer': 'https://pan.baidu.com/',
            'Accept': 'application/json',
          },
        );

        if (!result.successful) {
          lastError = HttpRequestFailure(
            '百度没有返回可用下载链接',
            kind: 'baidu_direct',
            status: result.status,
            retryable: {408, 429, 500, 502, 503, 504}.contains(result.status),
          );
          continue;
        }

        final data = result.json;
        final errno = data.integer('errno');
        if (errno != 0) {
          lastError = _mapErrno(errno);
          // 仅"节点被拒/需要签名"这类原因才值得换节点重试。
          if (errno != -6 && errno != 31023 && errno != 31024) throw lastError!;
          continue;
        }

        final info = data.list('info').firstOrNull;
        require(info != null, '百度没有返回可用下载链接');

        final dlink = info!.str('dlink').trim();
        final uri = Uri.tryParse(dlink);
        final host = uri?.host.toLowerCase() ?? '';
        require(
          uri != null &&
              {'https', 'http'}.contains(uri.scheme) &&
              uri.userInfo.isEmpty &&
              _dlinkDomains.any((d) => host == d || host.endsWith('.$d')) &&
              // 回环保护：d.pcs.baidu.com 是"外部下载器"入口，会拿到受限链接。
              host != 'd.pcs.baidu.com',
          '百度没有返回可用下载链接',
        );

        // dlink 是短时签名地址，其 host 不是 pcs.baidu.com 时即为预览/降级链接。
        final preview = !host.endsWith('pcs.baidu.com');

        // 与上游一致：服务端返回的 downloadVersion 必须匹配当前客户端。
        final served = info!.str('downloadVersion');
        require(
          requestedVersion.isEmpty || served.isEmpty || served == requestedVersion,
          '百度取链服务与当前应用不兼容，请联系服务提供方更新服务',
        );

        _rotation = (_rotation + i + 1) % _signServers.length;
        DiagnosticLog.event(
          'baidu.link_resolved',
          fields: {
            'profile': preview ? 'baidu_preview' : 'baidu',
            'host': host,
            'elapsedMs': elapsed.elapsedMilliseconds,
          },
        );
        return (url: uri.toString(), preview: preview);
      } catch (e) {
        lastError = e;
        continue;
      }
    }

    if (lastError is AppException) throw lastError;
    throw HttpRequestFailure(
      '百度取链服务暂不可用，请稍后重试',
      kind: 'baidu_direct_exhausted',
      retryable: true,
      requestNotSent: false,
    );
  }

  /// 百度 Android 端的 CSRF：`bdstoken = md5(BDUSS)`，不是浏览器那套 token。
  String _appToken(String cookie) {
    final bduss = _cookieValue(cookie, 'BDUSS');
    return bduss.isEmpty ? '' : md5.convert(utf8.encode(bduss)).toString();
  }

  String _cookieValue(String raw, String name) {
    for (final part in raw.split(';')) {
      final i = part.indexOf('=');
      if (i <= 0) continue;
      if (part.substring(0, i).trim() == name) {
        return part.substring(i + 1).trim();
      }
    }
    return '';
  }

  /// `fs_id` 缺失时（分享直链场景）按路径反查一次目录列表。
  Future<String> _fsIdByPath(String ck, String path) async {
    final dir = path.startsWith('/') ? path : '/$path';
    final sep = dir.lastIndexOf('/');
    final parent = sep <= 0 ? '/' : dir.substring(0, sep);
    final name = sep < 0 ? dir : dir.substring(sep + 1);
    if (name.isEmpty) return '';

    final result = await http.get(
      'https://pan.baidu.com/rest/2.0/xpan/file'
      '?method=list'
      '&dir=${Uri.encodeComponent(parent)}'
      '&order=name'
      '&start=0'
      '&limit=1000'
      '&app_id=$appId'
      '&clienttype=0'
      '&channel=android_13_bd-netdisk_1'
      '&version=$version'
      '&bdstoken=${_appToken(ck)}',
      {
        'Cookie': ck,
        'User-Agent': _ua,
        'Referer': 'https://pan.baidu.com/',
        'Accept': 'application/json',
      },
    );
    if (!result.successful) return '';
    final data = result.json;
    if (data.integer('errno') != 0) return '';
    for (final item in data.list('list')) {
      if (item.str('path') == dir || item.str('server_filename') == name) {
        return item.str('fs_id').ifEmpty('${item.integer('fs_id')}');
      }
    }
    return '';
  }

  /// 百度 errno → 与上游服务端 code 语义对齐的用户提示。
  AppException _mapErrno(int errno) => switch (errno) {
    // 详见文件末尾「待自行验证的一点」。
    -6 => HttpRequestFailure(
      '百度取链节点校验失败（-6），请更换版本或节点',
      kind: 'baidu_direct_verify',
      retryable: true,
    ),
    31023 => HttpRequestFailure(
      '百度取链参数无效（31023），请刷新列表后重试',
      kind: 'baidu_direct_param',
      retryable: true,
    ),
    -9 => const AccountLoginRequired('百度登录已失效，请重新网页登录'),
    -7 => const AccountLoginRequired('百度登录已失效，请重新网页登录'),
    31066 => HttpRequestFailure(
      '百度账号无权下载该文件',
      kind: 'baidu_direct_quota',
    ),
    _ => HttpRequestFailure(
      '百度取链失败（errno $errno），请稍后重试',
      kind: 'baidu_direct_$errno',
      retryable: errno > 0,
    ),
  };
}

// ---------------------------------------------------------------------------
// 待自行验证的一点
// ---------------------------------------------------------------------------
// 百度 App 端 /rest/2.0/xpan/file 部分场景要求 `sign` 字段（Sign-1/2/3）。
// 若实测稳定返回 errno -6 或 31023，补下面两步即可：
//
//  1) 抓一次百度网盘 Android App 自己的 filemetas 请求（root + tcpdump 或
//     mitm），取出 `sign` 与参与签名的参数顺序；
//  2) 在 _signServers 循环里把 sign 拼进 query。
//
// 注意：Sign-1/2/3 依赖 App 的 app_id(250528)、版本号、及一串静态 salt，
// 这些都能在 libapp.so 里用 Dart 字符串表（长度前缀 + ASCII）直接定位，
// 与本项目的既有方法一致。
//
// 如果不想折腾签名，直接用已有的 `server.py`（自建服务端）也能跑通，
// 协议已在本机端到端验证通过。
