import AppKit
import ApplicationServices

/// Brings an app to the front even when the caller is a background app.
///
/// Since macOS 14 a background app may not activate another one through the public
/// APIs (activation is "cooperative"). Window switchers such as AltTab use this
/// SkyLight call, which acts as if the user had clicked the app. Loaded dynamically:
/// if it ever disappears, the public path is still tried.
enum FrontProcess {
    private typealias SetFrontFn = @convention(c) (UnsafeMutablePointer<ProcessSerialNumber>, UInt32, UInt32) -> Int32
    private typealias GetPSNFn = @convention(c) (pid_t, UnsafeMutablePointer<ProcessSerialNumber>) -> OSStatus

    private static let setFront: SetFrontFn? = {
        guard let h = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY),
              let sym = dlsym(h, "_SLPSSetFrontProcessWithOptions") else { return nil }
        return unsafeBitCast(sym, to: SetFrontFn.self)
    }()

    private static let getPSN: GetPSNFn? = {
        guard let sym = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "GetProcessForPID") else { return nil } // RTLD_DEFAULT
        return unsafeBitCast(sym, to: GetPSNFn.self)
    }()

    /// The id of the app's frontmost normal window, or 0.
    static func topWindowID(pid: pid_t) -> UInt32 {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
                as? [[String: Any]] else { return 0 }
        for w in list where (w[kCGWindowOwnerPID as String] as? pid_t) == pid && (w[kCGWindowLayer as String] as? Int) == 0 {
            return (w[kCGWindowNumber as String] as? UInt32) ?? 0
        }
        return 0
    }

    @discardableResult
    static func activate(pid: pid_t) -> Bool {
        guard let setFront, let getPSN else { return false }
        var psn = ProcessSerialNumber()
        guard getPSN(pid, &psn) == noErr else { return false }
        let userGenerated: UInt32 = 0x200
        return setFront(&psn, topWindowID(pid: pid), userGenerated) == 0
    }
}
