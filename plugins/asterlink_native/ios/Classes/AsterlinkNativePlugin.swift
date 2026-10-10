// AsterlinkNativePlugin.swift
//
// iOS counterpart of android/.../NativeBridge.kt's `gopeed` RPC dispatcher.
// Dart's AndroidGopeedTransport is a pure MethodChannel RPC reused unchanged on
// iOS (app_services.dart routes iOS through the same branch), so this plugin
// implements the native side of the two channels Dart needs at startup:
//
//   com.asterlink.app/native  "paths"  -> {data, cache, freeBytes}
//   com.asterlink.app/native  "gopeed" -> {method, args(JSON)} -> JSON string
//
// The engine is the gomobile-bound Go package `gopeed`
// (native/gopeed/bind/asterlink), built to AsterLink.xcframework by
// native/build-gopeed-ios.sh. Go funcs map to the Obj-C/Swift class `Gopeed`.
// The dispatch table below mirrors NativeBridge.kt lines 293-317 one-for-one.
//
// SELECTOR / MODULE CALIBRATION (first build only):
//   gomobile bind's generated surface depends on the x/mobile pin
//   (v0.0.0-20250911085028-...). Two things to verify against
//   AsterLink.xcframework/ios-arm64/*/Headers/*.h:
//
//   (a) Module import. gomobile frameworks often ship WITHOUT a module.modulemap,
//       in which case `import AsterLink` fails. Two fixes, pick one:
//         - add a modulemap under the framework's Modules/ dir:
//             module AsterLink { umbrella header "AsterLink.h"; export *; }
//           and point the podspec at it via
//             s.pod_target_xcconfig = { 'HEADER_SEARCH_PATHS' => ... }
//         - or call the Obj-C class from an .m file instead (no Swift import),
//           which needs no modulemap at all.
//   (b) Error style. Go funcs returning `error` may surface as Swift `throws`
//       (as coded below) or as a trailing `GopeedGoError **` out-parameter /
//       nullable return. If the compiler objects to `try Gopeed.x(...)`, switch
//       that call to the Obj-C form.
//
//   The dispatch LOGIC (which method -> which Go func -> which string to return)
//   mirrors NativeBridge.kt exactly and is authoritative; only the call spelling
//   may need tuning.

import Flutter
import Foundation
// Module name == framework/product name.
import AsterLink

@objc public class AsterlinkNativePlugin: NSObject, FlutterPlugin {
    private static let shared = GopeedBridge()

    public static func register(with registrar: FlutterPluginRegistrar) {
        let channel = FlutterMethodChannel(
            name: "com.asterlink.app/native",
            binaryMessenger: registrar.messenger()
        )
        channel.setMethodCallHandler(shared.handle)
    }
}

// MARK: - Bridge

@objc final class GopeedBridge: NSObject {
    private var nativeStarted = false
    private let lock = NSLock()

    private func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        switch call.method {
        case "paths":
            result(Self.pathsPayload())
        case "gopeed":
            // Engine calls run off the platform thread, like nativeWorker.
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                guard let self else { return }
                let args = (call.arguments as? [String: Any]) ?? [:]
                let method = (args["method"] as? String) ?? ""
                let payload = (args["args"] as? String) ?? "{}"
                do {
                    let out = try self.nativeCall(method, payload)
                    DispatchQueue.main.async { result(out) }
                } catch let e as FlutterError {
                    DispatchQueue.main.async { result(e) }
                } catch {
                    DispatchQueue.main.async {
                        result(FlutterError(
                            code: "operation",
                            message: "下载组件操作失败，请重试并检查下载目录",
                            details: nil
                        ))
                    }
                }
            }
        // Low-risk no-ops for Android-only bridges not required on the first
        // iOS end-to-end pass. See README-IOS.md for the deferred list.
        case "legacySnapshot":
            result("{}")
        case "clientEnvironment":
            result([String: Any]())
        case "diagnosticPaths":
            result(["logs": Self.dataDir().appendingPathComponent("diagnostics").path,
                    "enabled": false])
        case "diagnosticSnapshot":
            result([String: Any]())
        case "diagnosticEnabled", "diagnosticClear", "flushStateKeyStorage":
            result(nil)
        default:
            result(FlutterMethodNotImplemented)
        }
    }

    // MARK: Sandbox paths (Dart 'paths' contract)

    static func dataDir() -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("AsterLink", isDirectory: true)
    }
    static func cacheDir() -> URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("asterlink_downloads", isDirectory: true)
    }
    private static func pathsPayload() -> [String: Any] {
        let data = dataDir(), cache = cacheDir()
        try? FileManager.default.createDirectory(at: data, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        let free = (try? cache.resourceValues(
            forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?
            .volumeAvailableCapacityForImportantUsage ?? 0
        return ["data": data.path, "cache": cache.path, "freeBytes": Int(free)]
    }

    // MARK: Engine RPC (mirrors NativeBridge.kt nativeCall, L293-317)

    private func requireId(_ method: String, _ id: String) throws {
        if ["pause", "remove", "snapshot"].contains(method),
           id.range(of: "^[A-Za-z0-9_-]{1,100}$", options: .regularExpression) == nil {
            throw FlutterError(code: "operation", message: "无效的下载任务编号", details: nil)
        }
    }
    private func requireStarted() throws {
        guard nativeStarted else {
            throw FlutterError(code: "operation", message: "下载组件连接已中断", details: nil)
        }
    }

    /// Returns the JSON string Dart's AndroidGopeedTransport will jsonDecode,
    /// or "null" for void engine calls — the exact Kotlin `when` contract.
    ///
    /// Signatures per native/gopeed/bind/asterlink Go source:
    ///   Open/Begin/ResolveTorrent/StartHttpProbe/StartTorrentStream -> (…, err)
    ///   Snapshot/TorrentMetadata/HttpProbeStatus/TorrentStreamStatus -> (String, err)
    ///   Pause/Remove/Close -> (err)      Stop/Cancel/Interrupt -> void
    /// Adjust only parameter labels to the generated header if needed.
    private func nativeCall(_ method: String, _ rawArgs: String) throws -> String {
        let args = (try? JSONSerialization.jsonObject(with: Data(rawArgs.utf8)))
            as? [String: Any] ?? [:]
        let id = (args["id"] as? String) ?? ""
        try requireId(method, id)

        switch method {
        case "version":
            return "{\"version\":\"1.8.1\",\"protocol\":1}"
        case "open":
            try openNative(args)
            return "null"
        case "begin":
            try requireStarted(); _ = try Gopeed.begin(rawArgs); return "null"
        case "httpProbeStart":
            try requireStarted(); _ = try Gopeed.startHttpProbe(rawArgs); return "null"
        case "httpProbeStatus":
            try requireStarted(); return try Gopeed.httpProbeStatus(id)
        case "httpProbeStop":
            if nativeStarted { Gopeed.stopHttpProbe(id) }
            return "null"
        case "torrentResolve":
            try requireStarted(); _ = try Gopeed.resolveTorrent(rawArgs); return "null"
        case "torrentMetadata":
            try requireStarted(); return try Gopeed.torrentMetadata(id)
        case "torrentCancel":
            if nativeStarted { Gopeed.cancelTorrent(id) }
            return "null"
        case "torrentStreamStart":
            try requireStarted(); return try Gopeed.startTorrentStream(rawArgs)
        case "torrentStreamStatus":
            try requireStarted(); return try Gopeed.torrentStreamStatus(id)
        case "torrentStreamStop":
            if nativeStarted { Gopeed.stopTorrentStream(id) }
            return "null"
        case "torrentStreamInterrupt":
            if nativeStarted { Gopeed.interruptTorrentStream(id) }
            return "null"
        case "snapshot":
            try requireStarted(); return try Gopeed.snapshot(id)
        case "pause":
            if nativeStarted { _ = try Gopeed.pause(id) }
            return "null"
        case "remove":
            if nativeStarted { _ = try Gopeed.remove(id) }
            return "null"
        case "close":
            if nativeStarted { _ = try Gopeed.close(); nativeStarted = false }
            return "null"
        default:
            throw FlutterError(code: "operation", message: "未知平台请求", details: nil)
        }
    }

    // openNative: Android manages its own sealed key file; iOS receives
    // storageDir/cacheDir/key straight from Dart GopeedEngine._start, where the
    // key already lives in flutter_secure_storage (Keychain). Feed it to Go.
    private func openNative(_ args: [String: Any]) throws {
        lock.lock(); defer { lock.unlock() }
        guard !nativeStarted else { return }
        let dir = (args["storageDir"] as? String).map(URL.init(fileURLWithPath:)) ?? Self.dataDir()
        let cache = (args["cacheDir"] as? String).map(URL.init(fileURLWithPath:)) ?? Self.cacheDir()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        let key = (args["key"] as? String) ?? ""
        guard !key.isEmpty else {
            throw FlutterError(code: "operation", message: "下载存储密钥无效", details: nil)
        }
        _ = try Gopeed.open(dir.path, cache.path, key)
        nativeStarted = true
    }
}
