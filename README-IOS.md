# iOS 构建说明(无 Mac、纯云端)

目标:不在本地拥有一台 Mac 的前提下,用 GitHub Actions 的 macOS runner 编出
**未签名 ipa**,越狱机自签安装。

## 一、为什么这条路成立

- GitHub Actions 提供 `macos-14` runner,Xcode / iOS SDK / clang(cgo 所需)预装,
  所以整条链路不需要实体 Mac。
- 核心下载/解析/BT 引擎是 Go(gopeed 1.8.1),经 `gomobile bind` 产出;安卓编
  `.aar`、iOS 编 `.xcframework`,**同一份 Go 源码零改动**。
- Windows 专属 syscall 已用 build tag 隔离(`*_windows.go` 各配 `*_other.go`),
  iOS 编译天然走兜底分支。
- 越狱机装 unsigned ipa 无需苹果开发者账号。

## 二、本次新增/修改的文件

| 文件 | 作用 |
|------|------|
| `stub_plugins/window_manager` | 纯 Dart 空实现桩,`window_manager` 仅支持 Linux/macOS/Windows |
| `stub_plugins/tray_manager` | 同上,托盘插件无 iOS 后端 |
| `native/build-gopeed-ios.sh` | `gomobile bind -target=ios` 产出 AsterLink.xcframework |
| `plugins/asterlink_native/` | iOS-only 宿主插件:MethodChannel 桥 + podspec 链接 xcframework |
| `tool/ios_prepare.rb` | CI 注入桩覆盖 + Info.plist 权限 |
| `.github/workflows/ios.yml` | 云端构建流水线 |
| `lib/app_services.dart` | `Platform.isAndroid` → 含 `isIOS`,复用 MethodChannel 传输 |

## 三、关键设计决策

**1. 为什么不改那 5 个 import 了 window_manager 的文件**
`window_manager`/`tray_manager` 只提供 Linux/macOS/Windows 后端。删依赖会让
iOS 编译直接失败;保留则 CocoaPods 找不到原生实现。方案是 `dependency_overrides`
指向同名**纯 Dart 桩包**——import 语句完全合法,桩的方法全部空实现。主源码
(main.dart / playback_device.dart / windows_pip.dart / pip_resize_handles.dart)
一行不动。桩覆盖**只在 CI 注入,不入库**,桌面端仍用真插件。

**2. 为什么用本地插件而不是改 pbxproj**
Flutter 的 iOS 模板是 Objective-C AppDelegate,把 Swift 桥塞进 Runner 需要
改 pbxproj + 桥接头,在 CI 里最易碎。改用 iOS-only 插件:Flutter 自动注册,
podspec 的 `vendored_frameworks` 由 CocoaPods 自动链接/嵌入,全程不碰工程文件。

**3. iOS 如何复用 Dart 传输层**
`AndroidGopeedTransport` 是纯 MethodChannel RPC(`com.asterlink.app/native`
+ `gopeed` 方法),与平台无关。`app_services.dart` 把守卫扩成
`isAndroid || isIOS` 即可复用;Swift 侧一比一复刻 Kotlin `NativeBridge.kt`
第 293-317 行的 17 个方法分发。密钥不需要自建——Dart 已在
`flutter_secure_storage`(iOS Keychain)里管好并随 `open` 参数传入。

## 四、必须实测的三个风险

1. **gomobile iOS bind 首跑**:CI 第一道关。若报 cgo/链接错,查是否有未隔离的
   平台 syscall。
2. **Swift 选择器校准**:`Gopeed.*` 的具体 Swift 签名取决于 x/mobile 版本。
   首编打开 `AsterLink.xcframework/ios-arm64/*/Headers/*.h` 核对模块名与参数标签;
   分发逻辑(哪个 method → 调哪个 Go 函数 → 返回什么串)是权威的,只需调拼写。
3. **media_kit(libmpv) CocoaPods 拉取超时**:给 pub-cache 与 cocoapods 加缓存。

## 五、暂未实现(首批不阻断端到端验证)

Android 宿主里这些能力还没有 iOS 对应实现,桥中以 no-op 或空值兜底:
文件保存到"文件"App(`saveFile`)、外部播放器选择、悬浮窗/保活通知、
系统浏览器 Cookie 登录(`clientEnvironment`)、诊断快照。
下载解析与在线播放可先跑通,再补齐这些。

## 六、怎么触发

```bash
git tag v1.5.0-ios && git push origin v1.5.0-ios
```
或在 Actions 页面点 `Build iOS ipa (unsigned)` → `Run workflow`。
产物在 artifact `asterlink-ios-unsigned`,用 TrollStore(版本支持则永久免签)
或 Sideloadly / AltStore 装入越狱机。

## 七、协议

仓库为 AGPL-3.0。对外分发修改版须开源改动;自用不受分发条款约束。
