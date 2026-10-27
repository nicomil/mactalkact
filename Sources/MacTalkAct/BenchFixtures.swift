import AppKit
import EventKit
import Foundation

/// What the Bench (`--agent-bench`) needs beyond the HTML pages (Story 7.1): native apps with data
/// created and removed by the Bench, a test webmail, and misheard sentences that must do nothing.
enum BenchKind: Equatable {
    /// A page of `Tests/bench/pages`, opened in Safari.
    case page(String)
    /// A native app; `folder`: Finder opened on the Bench folder.
    case app(name: String, folder: Bool)
    /// The test webmail (`MACTALK_BENCH_WEBMAIL`), with a path appended.
    case webmail(String)
    /// A misheard sentence, said with a page in front: it goes through the Router.
    case phrase(page: String)

    init(_ field: String) {
        if field.hasPrefix("app:") {
            let parts = field.dropFirst(4).split(separator: ":").map(String.init)
            self = .app(name: parts.first ?? "", folder: parts.dropFirst().first == "banco")
        } else if field.hasPrefix("webmail:") {
            self = .webmail(String(field.dropFirst(8)))
        } else if field.hasPrefix("frase:") {
            self = .phrase(page: String(field.dropFirst(6)))
        } else {
            self = .page(field)
        }
    }

    var isPhrase: Bool { if case .phrase = self { return true } else { return false } }

    /// Real apps and accounts: the Bench never says «sì» there (a «sì» in Mail would really send).
    var isReal: Bool {
        switch self {
        case .app, .webmail: return true
        case .page, .phrase: return false
        }
    }
}

/// One check of a task: `+text`/`-text` on the front window title, or `file:`, `evento:`, `url:`.
struct BenchCheck: Equatable {
    enum Target: Equatable { case title, file, event, url }
    let mustContain: Bool
    let target: Target
    let text: String

    static func parse(_ field: String) -> [BenchCheck] {
        field.split(separator: ";").compactMap { c in
            let s = c.trimmingCharacters(in: .whitespaces)
            guard !s.isEmpty else { return nil }
            let must = !s.hasPrefix("-")
            var body = String(s.hasPrefix("-") || s.hasPrefix("+") ? s.dropFirst() : Substring(s))
            var target = Target.title
            for (prefix, t) in [("file:", Target.file), ("evento:", .event), ("url:", .url)] where body.hasPrefix(prefix) {
                target = t
                body = String(body.dropFirst(prefix.count))
            }
            return BenchCheck(mustContain: must, target: target, text: body)
        }
    }
}

@MainActor
enum BenchFixtures {
    /// The Bench's own folder: created before a Finder task, always removed after.
    static let folder = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Desktop/Banco MacTalkAct", isDirectory: true)
    /// Everything the Bench creates in Calendar and Mail starts with this: specific enough that
    /// a real «Banco alimentare» event or mail is never touched.
    static let marker = "Banco MacTalkAct"
    /// Written in the Bench folder: the folder is removed only when it carries it (never a folder of Nico's).
    static let sentinel = ".creata-dal-banco-mactalkact"

    static let store = EKEventStore()
    private static var calendarAllowed: Bool?

    static var webmailURL: String? { ProcessInfo.processInfo.environment["MACTALK_BENCH_WEBMAIL"].flatMap { $0.isEmpty ? nil : $0 } }
    static var webmailPersonal: Bool { ProcessInfo.processInfo.environment["MACTALK_BENCH_WEBMAIL_PERSONAL"] == "1" }

    /// Prepares the data of a task. Returns a reason when the task cannot run (it is then skipped).
    static func setUp(_ kind: BenchKind, checks: [BenchCheck]) async -> String? {
        // Calendar access first: the cleanup of leftovers below needs it.
        if checks.contains(where: { $0.target == .event }), await !calendarAccess() {
            return "accesso al Calendario negato"
        }
        await tearDown(kind, checks: checks) // leftovers of an interrupted run
        if FileManager.default.fileExists(atPath: folder.path) {
            return "sulla Scrivania c'è già una cartella «Banco MacTalkAct» che non è del Banco"
        }
        let reason = await prepare(kind, checks: checks)
        if reason != nil { await tearDown(kind, checks: checks) }
        return reason
    }

    private static func prepare(_ kind: BenchKind, checks: [BenchCheck]) async -> String? {
        switch kind {
        case .app(let name, let inFolder):
            if name == "Finder" || inFolder || checks.contains(where: { $0.target == .file }) {
                do {
                    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                    try Data().write(to: folder.appendingPathComponent(sentinel))
                    try "Bozza del Banco di prova.\n".write(to: folder.appendingPathComponent("bozza.txt"), atomically: true, encoding: .utf8)
                    try "Nota del Banco di prova.\n".write(to: folder.appendingPathComponent("nota.txt"), atomically: true, encoding: .utf8)
                } catch { return "preparazione fallita: \(error.localizedDescription)" }
            }
            if inFolder {
                NSWorkspace.shared.open(folder)
            } else if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID(name)) {
                let config = NSWorkspace.OpenConfiguration()
                config.activates = true
                _ = try? await NSWorkspace.shared.openApplication(at: url, configuration: config)
            } else {
                return "\(name) non installata"
            }
            try? await Task.sleep(for: .seconds(2))
            return nil
        case .webmail:
            guard webmailURL != nil else { return "MACTALK_BENCH_WEBMAIL non impostata" }
            return nil
        case .page, .phrase:
            return nil
        }
    }

    /// Removes what the Bench created. Runs before and after every task, also when it failed.
    static func tearDown(_ kind: BenchKind, checks: [BenchCheck]) async {
        guard case .app(let name, _) = kind else { return }
        if FileManager.default.fileExists(atPath: folder.appendingPathComponent(sentinel).path) {
            closeFinderWindows()
            try? FileManager.default.removeItem(at: folder)
        }
        if checks.contains(where: { $0.target == .event }), calendarAllowed == true {
            for event in events() where (event.title ?? "").hasPrefix(marker) {
                try? store.remove(event, span: .thisEvent, commit: false)
            }
            try? store.commit()
        }
        if name == "Mail" {
            // Drafts and compose windows of the Bench only, never sent.
            osascript("""
            tell application "Mail"
                close (every window whose name contains "\(marker)") saving no
                delete (every outgoing message whose subject contains "\(marker)")
                repeat with a in accounts
                    try
                        delete (every message of (mailbox "Drafts" of a) whose subject contains "\(marker)")
                    end try
                end repeat
                try
                    delete (every message of drafts mailbox whose subject contains "\(marker)")
                end try
            end tell
            """)
        }
    }

    /// Checks the state a task should leave behind.
    static func passes(_ checks: [BenchCheck], title: String, url: String) -> Bool {
        checks.allSatisfy { c in
            let found: Bool
            switch c.target {
            case .title: found = title.contains(c.text)
            case .url: found = url.contains(c.text)
            case .file: found = FileManager.default.fileExists(atPath: folder.appendingPathComponent(c.text).path)
            case .event: found = calendarAllowed == true && events().contains { ($0.title ?? "").contains(c.text) }
            }
            return found == c.mustContain
        }
    }

    static func frontURL() -> String {
        guard let app = AX.frontmostApplication(), let window = AX.focusedWindow(in: AX.app(app.processIdentifier)) else { return "" }
        return AX.webURL(in: window)?.absoluteString ?? ""
    }

    private static func events() -> [EKEvent] {
        let now = Date()
        let predicate = store.predicateForEvents(withStart: now.addingTimeInterval(-7 * 86_400),
                                                 end: now.addingTimeInterval(7 * 86_400), calendars: nil)
        return store.events(matching: predicate)
    }

    private static func calendarAccess() async -> Bool {
        if let calendarAllowed { return calendarAllowed }
        let ok = (try? await store.requestFullAccessToEvents()) ?? false
        calendarAllowed = ok
        return ok
    }

    static func bundleID(_ name: String) -> String {
        switch name {
        case "Mail": return "com.apple.mail"
        case "Calendar", "Calendario": return "com.apple.iCal"
        case "Finder": return "com.apple.finder"
        default: return name
        }
    }

    private static func osascript(_ script: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        p.arguments = ["-e", script]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { Log.info("Banco: osascript non avviato"); return }
        // A pending Automation prompt or a stuck Mail must not freeze the Bench.
        let deadline = Date().addingTimeInterval(10)
        while p.isRunning, Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.1)) }
        if p.isRunning {
            p.terminate()
            print("      ! pulizia di Mail interrotta dopo 10 s (permesso di Automazione?)")
        } else if p.terminationStatus != 0 {
            print("      ! pulizia di Mail non riuscita (codice \(p.terminationStatus))")
        }
    }

    /// Closes the Finder windows showing the Bench folder: a window left open would make
    /// «apri la cartella» pass without the agent doing anything.
    private static func closeFinderWindows() {
        guard let finder = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.finder").first else { return }
        let app = AX.app(finder.processIdentifier)
        for w in (AX.value(app, kAXWindowsAttribute) as? [AXUIElement]) ?? [] where AX.string(w, kAXTitleAttribute) == folder.lastPathComponent {
            if let close = AX.value(w, kAXCloseButtonAttribute) { AX.press(close as! AXUIElement) }
        }
    }

    /// The app a task expects in front, to check before the agent starts.
    static func expectedBundle(_ kind: BenchKind) -> String? {
        switch kind {
        case .app(let name, _): return bundleID(name)
        case .page, .phrase, .webmail: return "com.apple.Safari"
        }
    }
}
