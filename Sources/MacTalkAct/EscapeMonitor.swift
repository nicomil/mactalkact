import AppKit

/// Esc pressed by the user stops the agent (FR-39), like the computer use of Claude.
/// Active only while the agent works; Esc keys posted by the app itself carry
/// `Executor.eventMarker` and are ignored. The key still reaches the frontmost app.
@MainActor
final class EscapeMonitor {
    private var monitor: Any?

    func start(_ onEscape: @escaping @MainActor () -> Void) {
        stop()
        monitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { event in
            guard event.keyCode == 53 else { return }
            let marker = event.cgEvent?.getIntegerValueField(.eventSourceUserData) ?? 0
            guard marker != Executor.eventMarker, Date().timeIntervalSince(KeyCombo.lastEscapePosted) > 0.5 else { return }
            Task { @MainActor in onEscape() }
        }
    }

    func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }
}
