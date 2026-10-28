import AppKit

/// Emergency stop for the debug commands that drive the real mouse and keyboard (Banco, hands
/// test, security suite…). While such a command runs, the user may not be able to take the Mac
/// back: Esc pressed on the real keyboard ends the process at once, releases the mouse button
/// and the modifier keys, and says how to clean up. Keys posted by the tests themselves (marked
/// with `Executor.eventMarker`, or coming from this process) never trigger it.
enum TestKillSwitch {
    /// The commands that click, type or bring apps to the front.
    static let screenFlags: Set<String> = [
        "--agent-bench", "--hands-test", "--security-suite", "--tools-test", "--agent-test",
        "--phase3-test", "--apple-events-spike", "--mail-search-spike", "--local-vision-test", "--activate-test",
    ]

    static func needed(for arguments: [String]) -> Bool {
        arguments.contains(where: screenFlags.contains)
    }

    nonisolated(unsafe) private static var tap: CFMachPort?

    /// Installs the stop on its own thread, so it works even while the main actor is busy.
    static func install() {
        let ready = DispatchSemaphore(value: 0)
        let thread = Thread {
            let mask = CGEventMask(1 << CGEventType.keyDown.rawValue)
            guard let port = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                               eventsOfInterest: mask, callback: TestKillSwitch.callback, userInfo: nil) else {
                FileHandle.standardError.write(Data("⚠︎ Stop con Esc non disponibile (manca il permesso di Accessibilità per il terminale). Per fermare: pkill -f MacTalkAct\n".utf8))
                ready.signal()
                return
            }
            tap = port
            let source = CFMachPortCreateRunLoopSource(nil, port, 0)
            CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
            CGEvent.tapEnable(tap: port, enable: true)
            print("⛔︎ Per fermare il test in qualunque momento premi Esc sulla tastiera.")
            ready.signal()
            CFRunLoopRun()
        }
        thread.name = "TestKillSwitch"
        thread.start()
        _ = ready.wait(timeout: .now() + 2)
    }

    /// Whether a key event comes from the user's keyboard and is Esc.
    static func isUserEscape(keyCode: Int64, marker: Int64, sourcePID: Int64, ownPID: Int64) -> Bool {
        keyCode == 53 && marker != Executor.eventMarker && sourcePID != ownPID
    }

    private static let callback: CGEventTapCallBack = { _, type, event, _ in
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)
        }
        if type == .keyDown,
           isUserEscape(keyCode: event.getIntegerValueField(.keyboardEventKeycode),
                        marker: event.getIntegerValueField(.eventSourceUserData),
                        sourcePID: event.getIntegerValueField(.eventSourceUnixProcessID),
                        ownPID: Int64(getpid())) {
            stopNow()
        }
        return Unmanaged.passUnretained(event)
    }

    /// Lets go of what a test may be holding, then ends the process.
    private static func stopNow() {
        let source = CGEventSource(stateID: .hidSystemState)
        let at = CGEvent(source: nil)?.location ?? .zero
        if CGEventSource.buttonState(.combinedSessionState, button: .left) {
            CGEvent(mouseEventSource: source, mouseType: .leftMouseUp, mouseCursorPosition: at, mouseButton: .left)?.post(tap: .cghidEventTap)
        }
        if CGEventSource.buttonState(.combinedSessionState, button: .right) {
            CGEvent(mouseEventSource: source, mouseType: .rightMouseUp, mouseCursorPosition: at, mouseButton: .right)?.post(tap: .cghidEventTap)
        }
        // Modifier keys left down by a test (⌘, ⇧, ⌥, ⌃).
        for code: CGKeyCode in [55, 54, 56, 60, 58, 61, 59, 62] {
            guard let up = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: false) else { continue }
            up.flags = []
            up.post(tap: .cghidEventTap)
        }
        FileHandle.standardError.write(Data("\n⛔︎ Test interrotto con Esc. Per chiudere le pagine del Banco: .build/debug/MacTalkAct --bench-cleanup\n".utf8))
        exit(130)
    }
}
