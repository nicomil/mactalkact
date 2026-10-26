import AppKit

/// Watches a single modifier key (e.g. right Option) system-wide.
///
/// - hold:        push-to-talk (`onPress` … `onRelease`)
/// - short tap:   `onTap` (cancels the push-to-talk that just started)
/// - double tap:  `onDoubleTap` (toggles hands-free session)
/// - any other key pressed while holding: `onCancel` (the user was typing ⌥+letter)
@MainActor
final class HotkeyMonitor {
    var onPress: (() -> Void)?
    var onRelease: (() -> Void)?
    var onTap: (() -> Void)?
    var onDoubleTap: (() -> Void)?
    var onCancel: (() -> Void)?

    private let key: PTTKey
    private var monitors: [Any] = []
    private var isDown = false
    private var cancelled = false
    private var pressedAt = Date.distantPast
    private var lastTapAt = Date.distantPast

    init(key: PTTKey) {
        self.key = key
    }

    func start() {
        stop()
        let mask: NSEvent.EventTypeMask = [.flagsChanged, .keyDown]
        if let g = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: { [weak self] e in
            MainActor.assumeIsolated { self?.handle(e) }
        }) { monitors.append(g) }
        if let l = NSEvent.addLocalMonitorForEvents(matching: mask, handler: { [weak self] e in
            MainActor.assumeIsolated { self?.handle(e) }
            return e
        }) { monitors.append(l) }
    }

    func stop() {
        monitors.forEach(NSEvent.removeMonitor)
        monitors.removeAll()
    }

    private func handle(_ e: NSEvent) {
        if e.type == .keyDown {
            if isDown && !cancelled {
                cancelled = true
                onCancel?()
            }
            return
        }
        guard e.keyCode == key.keyCode else { return }
        let down = e.modifierFlags.contains(key.flag)
        let now = Date()

        if down && !isDown {
            isDown = true
            cancelled = false
            pressedAt = now
            onPress?()
        } else if !down && isDown {
            isDown = false
            guard !cancelled else { return }
            if now.timeIntervalSince(pressedAt) < 0.25 {
                onTap?()
                if now.timeIntervalSince(lastTapAt) < 0.45 {
                    lastTapAt = .distantPast
                    onDoubleTap?()
                } else {
                    lastTapAt = now
                }
            } else {
                onRelease?()
            }
        }
    }
}
