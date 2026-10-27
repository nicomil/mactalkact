import AppKit
import Foundation

/// `--apple-events-spike` (Story 8.4, FR-49): five direct actions via Apple Events, 3 s each, to
/// decide in the next cycle whether to open that channel. A debug command, never a tool of the
/// agent (AD-20). No `do shell script`, no `execute javascript`; nothing is sent.
@MainActor
enum AppleEventsSpike {
    struct Outcome {
        let action: String
        let app: String
        let version: String
        let consent: String
        let seconds: Double?
        let error: String
    }

    static func run() async {
        let page = URL(fileURLWithPath: "Tests/bench/pages/sito.html").absoluteString
        let readme = FileManager.default.currentDirectoryPath + "/README.md"
        let chromium = ["com.brave.Browser", "com.google.Chrome", "com.microsoft.edgemac"]
            .first { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) != nil }
        let chromiumName = chromium.flatMap { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) }
            .map { FileManager.default.displayName(atPath: $0.path).replacingOccurrences(of: ".app", with: "") }
        var actions: [(String, String, String)] = [
            ("aprire un indirizzo in una scheda", "com.apple.Safari", """
             tell application "Safari"
                 set d to make new document with properties {URL:"\(page)"}
                 delay 0.5
                 close d
             end tell
             """),
            ("creare un evento", "com.apple.iCal", """
             tell application "Calendar"
                 set c to first calendar whose writable is true
                 set e to make new event at end of events of c with properties {summary:"Banco MacTalkAct spike", start date:(current date) + 86400, end date:(current date) + 90000}
                 delete e
             end tell
             """),
            ("rivelare un file", "com.apple.finder", """
             tell application "Finder" to reveal POSIX file "\(readme)"
             """),
            ("cercare in una casella", "com.apple.mail", """
             tell application "Mail" to count (messages of inbox whose subject contains "Banco")
             """),
            ("preparare una bozza (invio solo con la conferma di Nico)", "com.apple.mail", """
             tell application "Mail"
                 set m to make new outgoing message with properties {subject:"Banco MacTalkAct spike", content:"prova", visible:false}
                 tell m to make new to recipient with properties {address:"prova@example.invalid"}
                 delete m
             end tell
             """),
        ]
        if let chromium, let chromiumName {
            actions.insert(("aprire un indirizzo in una scheda", chromium, """
             tell application "\(chromiumName)"
                 if (count of windows) = 0 then make new window
                 set t to make new tab at end of tabs of front window with properties {URL:"\(page)"}
                 delay 0.5
                 close t
             end tell
             """), at: 1)
        }
        var outcomes: [Outcome] = []
        for (action, bundle, script) in actions {
            let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundle)
            let name = app.map { FileManager.default.displayName(atPath: $0.path).replacingOccurrences(of: ".app", with: "") } ?? bundle
            let version = app.flatMap { Bundle(url: $0)?.infoDictionary?["CFBundleShortVersionString"] as? String } ?? "—"
            let consent = permission(bundle)
            guard consent == "concesso" else {
                outcomes.append(Outcome(action: action, app: name, version: version, consent: consent, seconds: nil, error: "non eseguita"))
                continue
            }
            let started = Date()
            let error = await execute("with timeout of 3 seconds\n\(script)\nend timeout")
            outcomes.append(Outcome(action: action, app: name, version: version, consent: consent,
                                    seconds: Date().timeIntervalSince(started), error: error ?? "—"))
        }
        print("Spike Apple Events (macOS \(ProcessInfo.processInfo.operatingSystemVersionString)):")
        for o in outcomes {
            print("  \(o.app) \(o.version) · \(o.action) · consenso: \(o.consent) · tempo: \(o.seconds.map { String(format: "%.2f s", $0) } ?? "—") · errore: \(o.error)")
        }
    }

    /// Automation consent for `bundle`, asked without showing a dialog.
    static func permission(_ bundle: String) -> String {
        guard NSRunningApplication.runningApplications(withBundleIdentifier: bundle).first != nil
                || NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundle) != nil else { return "app assente" }
        var target = AEAddressDesc()
        let data = Array(bundle.utf8)
        let created = data.withUnsafeBytes { AECreateDesc(DescType(typeApplicationBundleID), $0.baseAddress, $0.count, &target) }
        guard created == noErr else { return "errore \(created)" }
        defer { AEDisposeDesc(&target) }
        let status = AEDeterminePermissionToAutomateTarget(&target, AEEventClass(typeWildCard), AEEventID(typeWildCard), false)
        switch status {
        case noErr: return "concesso"
        case OSStatus(errAEEventNotPermitted): return "negato (-1743)"
        case OSStatus(errAEEventWouldRequireUserConsent): return "da chiedere a Nico (-1744)"
        case OSStatus(procNotFound): return "app non avviata (-600)"
        default: return "stato \(status)"
        }
    }

    /// Runs an AppleScript off the main thread; nil on success, the error otherwise.
    static func execute(_ source: String) async -> String? {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                var info: NSDictionary?
                let script = NSAppleScript(source: source)
                _ = script?.executeAndReturnError(&info)
                if let info {
                    let n = info[NSAppleScript.errorNumber] as? Int ?? 0
                    let m = info[NSAppleScript.errorMessage] as? String ?? ""
                    continuation.resume(returning: "\(n) \(m.prefix(80))")
                } else {
                    continuation.resume(returning: nil)
                }
            }
        }
    }
}
