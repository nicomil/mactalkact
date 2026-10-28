import AppKit
import Foundation

/// `--apple-events-spike` (Story 8.4, FR-49): five direct actions via Apple Events (six with a Chromium
/// browser), each event waiting at most 3 s for its reply, to
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
        /// What the script returned as proof of the action (an id, a count).
        var proof = ""
    }

    /// `launch`: open Calendar and Mail first (`--avvia`): without them running there is no consent to read.
    static func run(launch: Bool = false) async {
        let pagePath = FileManager.default.currentDirectoryPath + "/Tests/bench/pages/sito.html"
        let readme = FileManager.default.currentDirectoryPath + "/README.md"
        guard FileManager.default.fileExists(atPath: pagePath), FileManager.default.fileExists(atPath: readme) else {
            print("Lancia lo spike dalla cartella del progetto (servono Tests/bench/pages/sito.html e README.md)."); return
        }
        let page = URL(fileURLWithPath: pagePath).absoluteString
        if launch {
            for id in ["com.apple.iCal", "com.apple.mail"] {
                if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) {
                    let config = NSWorkspace.OpenConfiguration()
                    config.activates = false
                    _ = try? await NSWorkspace.shared.openApplication(at: url, configuration: config)
                }
            }
            try? await Task.sleep(for: .seconds(3))
        }
        let chromium = ["com.brave.Browser", "com.google.Chrome", "com.microsoft.edgemac"]
            .first { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) != nil }
        var actions: [(String, String, String)] = [
            ("aprire un indirizzo in una scheda", "com.apple.Safari", """
             tell application id "com.apple.Safari"
                 set d to make new document with properties {URL:"\(page)"}
                 try
                     close d
                 end try
             end tell
             """),
            ("creare un evento", "com.apple.iCal", """
             tell application id "com.apple.iCal"
                 try
                     set c to first calendar whose writable is true
                     set e to make new event at end of events of c with properties {summary:"Banco MacTalkAct spike", start date:(current date) + 86400, end date:(current date) + 90000}
                     delete e
                 on error msg number n
                     try
                         delete (every event of c whose summary is "Banco MacTalkAct spike")
                     end try
                     error msg number n
                 end try
             end tell
             """),
            ("rivelare un file", "com.apple.finder", """
             tell application id "com.apple.finder" to reveal POSIX file "\(readme)"
             """),
            ("cercare in una casella", "com.apple.mail", """
             tell application id "com.apple.mail" to count (messages of inbox whose subject contains "Banco")
             """),
            ("preparare una bozza (invio solo con la conferma di Nico)", "com.apple.mail", """
             tell application id "com.apple.mail"
                 try
                     set m to make new outgoing message with properties {subject:"Banco MacTalkAct spike", content:"prova", visible:false}
                     tell m to make new to recipient with properties {address:"prova@example.invalid"}
                     close m saving no
                 on error msg number n
                     try
                         delete (every outgoing message whose subject is "Banco MacTalkAct spike")
                     end try
                     error msg number n
                 end try
             end tell
             """),
        ]
        if let chromium {
            actions.insert(("aprire un indirizzo in una scheda", chromium, """
             tell application id "\(chromium)"
                 if (count of windows) = 0 then make new window
                 set t to make new tab at end of tabs of front window with properties {URL:"\(page)"}
                 try
                     close t
                 end try
             end tell
             """), at: 1)
        }
        var outcomes: [Outcome] = []
        for (action, bundle, script) in actions {
            let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundle)
            let name = app.map { FileManager.default.displayName(atPath: $0.path).replacingOccurrences(of: ".app", with: "") } ?? bundle
            let version = app.flatMap { Bundle(url: $0)?.infoDictionary?["CFBundleShortVersionString"] as? String } ?? "—"
            let status = permissionStatus(bundle)
            let consent = consentLabel(status)
            guard mayRun(status) else {
                outcomes.append(Outcome(action: action, app: name, version: version, consent: consent, seconds: nil, error: "non eseguita"))
                continue
            }
            let started = Date()
            let (error, proof) = await execute("with timeout of 3 seconds\n\(script)\nend timeout")
            var o = Outcome(action: action, app: name, version: version, consent: consent,
                            seconds: Date().timeIntervalSince(started), error: error ?? "—")
            o.proof = proof
            outcomes.append(o)
        }
        // Mail saves the closed draft in the account a few seconds later: the Bench cleanup removes it.
        if outcomes.contains(where: { $0.app == "Mail" && $0.seconds != nil }) { BenchFixtures.osascript(BenchFixtures.mailCleanup) }
        // The Automation consent belongs to the responsible process: the terminal for a bare binary.
        let who = Bundle.main.bundleIdentifier.map { "app \($0)" } ?? "binario lanciato dal terminale (il consenso va al terminale, non all'app)"
        var report = ["Spike Apple Events (macOS \(ProcessInfo.processInfo.operatingSystemVersionString)) · chi chiede: \(who)"]
        for o in outcomes {
            let within = o.seconds.map { $0 <= 3 ? "entro 3 s" : "OLTRE 3 s" } ?? ""
            report.append("  \(o.app) \(o.version) · \(o.action) · consenso: \(o.consent) · tempo: \(o.seconds.map { String(format: "%.2f s", $0) } ?? "—") \(within) · errore: \(o.error)\(o.proof.isEmpty ? "" : " · prova: \(o.proof)")")
        }
        print(report.joined(separator: "\n"))
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd-HHmm"
        let out = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/MacTalkAct-apple-events-\(f.string(from: Date())).txt")
        try? (report.joined(separator: "\n") + "\n").write(to: out, atomically: true, encoding: .utf8)
        print("Report: \(out.path)")
    }

    /// Automation consent for `bundle`, read WITHOUT showing a dialog (`askUserIfNeeded = false`).
    /// nil: the app is not installed.
    static func permissionStatus(_ bundle: String) -> OSStatus? {
        guard NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundle) != nil else { return nil }
        var target = AEAddressDesc()
        let data = Array(bundle.utf8)
        let created = data.withUnsafeBytes { AECreateDesc(DescType(typeApplicationBundleID), $0.baseAddress, $0.count, &target) }
        guard created == noErr else { return OSStatus(created) }
        defer { AEDisposeDesc(&target) }
        return AEDeterminePermissionToAutomateTarget(&target, AEEventClass(typeWildCard), AEEventID(typeWildCard), Self.askUser)
    }

    /// Never a consent dialog from the spike: Nico may not be at the Mac.
    static let askUser = false

    /// Only with the consent already given does an action run. Pure, tested by `--selftest`.
    static func mayRun(_ status: OSStatus?) -> Bool { status == noErr }

    static func consentLabel(_ status: OSStatus?) -> String {
        switch status {
        case nil: return "app assente"
        case noErr: return "concesso"
        case OSStatus(errAEEventNotPermitted): return "negato (-1743)"
        case OSStatus(errAEEventWouldRequireUserConsent): return "da chiedere a Nico (-1744)"
        case OSStatus(procNotFound): return "app non avviata (-600)"
        case let s?: return "stato \(s)"
        }
    }

    /// Runs an AppleScript on the main thread (NSAppleScript wants it); nil on success, the error
    /// otherwise. `with timeout` bounds each event's reply; a script also gets compiled first, so the
    /// time measured includes that.
    static func execute(_ source: String) async -> (error: String?, proof: String) {
        guard let script = NSAppleScript(source: source) else { return ("script non valido", "") }
        var info: NSDictionary?
        let result = script.executeAndReturnError(&info)
        guard let info else { return (nil, result.stringValue ?? "") }
        let n = info[NSAppleScript.errorNumber] as? Int ?? 0
        let m = info[NSAppleScript.errorMessage] as? String ?? ""
        return ("\(n)\(n == -1712 ? " (tempo scaduto)" : "") \(m.prefix(80))", "")
    }
}
