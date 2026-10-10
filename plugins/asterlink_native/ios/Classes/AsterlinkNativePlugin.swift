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
// Generated surface (confirmed from AsterLink.xcframework .../Headers/Gopeed.objc.h):
//   gomobile emits plain C functions, NOT an ObjC class:
//     BOOL   GopeedOpen(storageDir, cacheDir, encodedKey, NSError**) 
//     BOOL   GopeedBegin(value, NSError**)            BOOL GopeedPause(id, NSError**)
//     BOOL   GopeedRemove(id, NSError**)              BOOL GopeedClose(NSError**)
//     BOOL   GopeedStartHttpProbe(value, NSError**)   BOOL GopeedResolveTorrent(value, NSError**)
//     NSString* GopeedSnapshot(id, NSError**)         NSString* GopeedHttpProbeStatus(id, NSError**)
//     NSString* GopeedTorrentMetadata(id, NSError**)  NSString* GopeedStartTorrentStream(value, NSError**)
//     NSString* GopeedTorrentStreamStatus(id, NSError**)
//     void   GopeedStopHttpProbe(id)  GopeedStopTorrentStream(id)
//     void   GopeedCancelTorrent(id)  GopeedInterruptTorrentStream(id)
//   Swift imports the NSError** form as `throws`, hence the calls below.
//   The framework ships no module.modulemap; the CI job injects one at the
//   framework root (umbrella header "Headers/AsterLink.h") so `import AsterLink`
//   resolves these symbols.

import Flutter
import Foundation
import UIKit
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
        shared.rootVC = registrar.view()
    }
}

// MARK: - Bridge

/// Thrown inside the RPC layer and mapped to FlutterError at the channel
/// boundary. FlutterError is a struct and cannot be thrown directly.
private struct BridgeError: Error {
    let code: String
    let message: String
}

/// Swift does not auto-bridge the trailing NSError** of these plain C imports
/// into `throws`, so the out-parameter is passed explicitly and mapped here.
private func goBool(_ body: (NSErrorPointer) -> Bool) throws {
    var error: NSError?
    _ = body(&error)
    if let error { throw BridgeError(code: "operation", message: error.localizedDescription) }
}
private func goString(_ body: (NSErrorPointer) -> String) throws -> String {
    var error: NSError?
    let value = body(&error)
    if let error { throw BridgeError(code: "operation", message: error.localizedDescription) }
    return value
}

@objc final class GopeedBridge: NSObject {
    private var nativeStarted = false
    private let lock = NSLock()
    /// The Flutter view controller, supplied by the registrar at launch.
    /// Used as the presenter for UI overlays (directory picker, etc.).
    weak var rootVC: UIViewController?

    func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        switch call.method {
        case "paths":
            result(Self.pathsPayload())
        case "chooseDirectory":
            Self.presentDirectoryPicker(result: result)
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
                } catch let e as BridgeError {
                    DispatchQueue.main.async {
                        result(FlutterError(code: e.code, message: e.message, details: nil))
                    }
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

    private static func freeBytes(at url: URL?) -> Int {
        let candidate = url ?? cacheDir()
        let values = try? candidate.resourceValues(
            forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return Int(values?.volumeAvailableCapacityForImportantUsage ?? 0)
    }

    // MARK: Directory picker

    /// file_selector_ios does not implement getDirectoryPath, so Dart's
    /// FileAccess.chooseDirectory would throw UnimplementedError on iOS. Present
    /// a folder-only UIDocumentPickerViewController here instead and resolve to
    /// the selected directory path.
    private static var pendingPicker: DirectoryPickerDelegate?

    private static func presentDirectoryPicker(result: @escaping FlutterResult) {
        DispatchQueue.main.async {
            guard let root = findRootViewController() else {
                result(FlutterError(code: "picker", message: "无法打开目录选择器", details: nil))
                return
            }
            let picker = UIDocumentPickerViewController(
                documentTypes: ["public.folder"], in: .open)
            picker.allowsMultipleSelection = false
            let delegate = DirectoryPickerDelegate { path in
                pendingPicker = nil
                result(path)
            }
            pendingPicker = delegate
            picker.delegate = delegate
            root.present(picker, animated: true, completion: nil)
        }
    }

    /// Returns the topmost usable view controller, preferring the registered
    /// Flutter view controller, then falling back to the key window via
    /// connected scenes.
    private static func findRootViewController() -> UIViewController? {
        // 1. Flutter registrar-supplied view controller (most reliable)
        if let vc = shared.rootVC { return vc }
        // 2. iOS 13+ key window from connected scenes
        if #available(iOS 13.0, *) {
            for scene in UIApplication.shared.connectedScenes {
                guard let windowScene = scene as? UIWindowScene,
                      let key = windowScene.windows.first(where: { $0.isKeyWindow }),
                      let root = key.rootViewController
                else { continue }
                return root
            }
        }
        // 3. Legacy delegate window fallback
        return UIApplication.shared.delegate?.window??.rootViewController
    }

    // MARK: Engine RPC (mirrors NativeBridge.kt nativeCall, L293-317)

    private func requireId(_ method: String, _ id: String) throws {
        if ["pause", "remove", "snapshot"].contains(method),
           id.range(of: "^[A-Za-z0-9_-]{1,100}$", options: .regularExpression) == nil {
            throw BridgeError(code: "operation", message: "无效的下载任务编号")
        }
    }
    private func requireStarted() throws {
        guard nativeStarted else {
            throw BridgeError(code: "operation", message: "下载组件连接已中断")
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
        case "freeSpace":
            // Not part of the Go engine surface. Desktop transport implements it
            // in the exe; on iOS report the volume's free capacity directly so
            // Dart's FileAccess.freeBytes does not fall through to the unknown
            // method error.
            let target = (args["path"] as? String).map(URL.init(fileURLWithPath:))
            return "{\"bytes\":\(Self.freeBytes(at: target))}"
        case "open":
            try openNative(args)
            return "null"
        case "begin":
            try requireStarted(); try goBool { GopeedBegin(rawArgs, $0) }; return "null"
        case "httpProbeStart":
            try requireStarted(); try goBool { GopeedStartHttpProbe(rawArgs, $0) }; return "null"
        case "httpProbeStatus":
            try requireStarted(); return try goString { GopeedHttpProbeStatus(id, $0) }
        case "httpProbeStop":
            if nativeStarted { GopeedStopHttpProbe(id) }
            return "null"
        case "torrentResolve":
            try requireStarted(); try goBool { GopeedResolveTorrent(rawArgs, $0) }; return "null"
        case "torrentMetadata":
            try requireStarted(); return try goString { GopeedTorrentMetadata(id, $0) }
        case "torrentCancel":
            if nativeStarted { GopeedCancelTorrent(id) }
            return "null"
        case "torrentStreamStart":
            try requireStarted(); return try goString { GopeedStartTorrentStream(rawArgs, $0) }
        case "torrentStreamStatus":
            try requireStarted(); return try goString { GopeedTorrentStreamStatus(id, $0) }
        case "torrentStreamStop":
            if nativeStarted { GopeedStopTorrentStream(id) }
            return "null"
        case "torrentStreamInterrupt":
            if nativeStarted { GopeedInterruptTorrentStream(id) }
            return "null"
        case "snapshot":
            try requireStarted(); return try goString { GopeedSnapshot(id, $0) }
        case "pause":
            if nativeStarted { try goBool { GopeedPause(id, $0) } }
            return "null"
        case "remove":
            if nativeStarted { try goBool { GopeedRemove(id, $0) } }
            return "null"
        case "close":
            if nativeStarted { try goBool { GopeedClose($0) }; nativeStarted = false }
            return "null"
        default:
            throw BridgeError(code: "operation", message: "未知平台请求")
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
            throw BridgeError(code: "operation", message: "下载存储密钥无效")
        }
        try goBool { GopeedOpen(dir.path, cache.path, key, $0) }
        nativeStarted = true
    }
}

/// Keeps the document picker alive until the user picks a folder or cancels,
/// then resolves the pending FlutterResult with the selected directory path.
final class DirectoryPickerDelegate: NSObject, UIDocumentPickerDelegate {
    private let completion: (String?) -> Void
    init(_ completion: @escaping (String?) -> Void) {
        self.completion = completion
    }

    func documentPicker(
        _ controller: UIDocumentPickerViewController,
        didPickDocumentsAt urls: [URL]
    ) {
        // Resolve to the on-disk path. "On My iPhone" folders are directly
        // writable; security-scoped URLs are accessed here for the current call.
        let url = urls.first
        _ = url?.startAccessingSecurityScopedResource()
        completion(url?.path)
    }

    func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
        completion(nil)
    }
}
