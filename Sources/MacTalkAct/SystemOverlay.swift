import AppKit
import CoreGraphics

/// Mission Control, App Exposé and Launchpad: the Dock covers a whole screen with one window at its own
/// level (20), while the app «in front» stays the one of before. Esc closes them and goes to the Dock,
/// not to that app.
enum SystemOverlay {
    struct WindowInfo: Equatable {
        let owner: String
        let layer: Int
        let size: CGSize
    }

    static let dockLayer = 20

    /// A Dock window at the Dock level as large as a screen. Pure, tested by `--selftest`.
    static func isOpen(windows: [WindowInfo], screens: [CGSize]) -> Bool {
        windows.contains { w in
            w.owner == "Dock" && w.layer == dockLayer
                && screens.contains { w.size.width >= $0.width * 0.9 && w.size.height >= $0.height * 0.9 }
        }
    }

    static func isOpen() -> Bool {
        let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
        let windows = list.compactMap { info -> WindowInfo? in
            guard let owner = info[kCGWindowOwnerName as String] as? String, owner == "Dock",
                  let layer = info[kCGWindowLayer as String] as? Int,
                  let bounds = info[kCGWindowBounds as String] as? [String: Any],
                  let w = (bounds["Width"] as? NSNumber)?.doubleValue, let h = (bounds["Height"] as? NSNumber)?.doubleValue else { return nil }
            return WindowInfo(owner: owner, layer: layer, size: CGSize(width: w, height: h))
        }
        return isOpen(windows: windows, screens: NSScreen.screens.map(\.frame.size))
    }
}
