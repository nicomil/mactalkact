import AppKit
import Foundation

/// `--mail-search-spike [--terms a,b,c]` (Story 11.5, FR-61): five searches in Nico's Mail along two
/// roads, to decide on numbers whether Apple Events become a tool (AD-20).
/// (a) Apple Events on a smaller perimeter: the inboxes, messages of the last 30 days.
/// (b) The Spotlight index of Mail (`mdfind`), restricted to the inboxes.
/// Read only: nothing is moved, opened or marked. The report holds times, counts and permissions,
/// never subjects, senders or text. No consent dialog is ever shown (`AppleEventsSpike.askUser`).
@MainActor
enum MailSearchSpike {
    static let defaultTerms = ["fattura", "riunione", "preventivo", "ordine", "conferma"]
    static let days = 30
    /// Each search may take this long before it counts as failed (the 3 s of the 8.4 spike are the
    /// threshold to judge, not the limit to stop at).
    static let timeoutSeconds = 10

    struct Search {
        let term: String
        var seconds: Double?
        var count: Int?
        var error: String = ""
    }

    static func run(terms: [String]) async {
        let consent = AppleEventsSpike.permissionStatus("com.apple.mail")
        var roadA: [Search] = []
        for term in terms {
            var s = Search(term: term)
            if AppleEventsSpike.mayRun(consent) {
                let started = Date()
                let (error, proof) = await AppleEventsSpike.execute(appleScript(term: term))
                s.seconds = Date().timeIntervalSince(started)
                s.count = Int(proof)
                s.error = error ?? ""
            } else {
                s.error = "non eseguita: \(AppleEventsSpike.consentLabel(consent))"
            }
            roadA.append(s)
        }
        var roadB: [Search] = []
        for term in terms {
            var s = Search(term: term)
            let started = Date()
            let (paths, error) = spotlight(term: term)
            s.seconds = Date().timeIntervalSince(started)
            s.count = paths.map { $0.filter(isInboxPath).count }
            s.error = error ?? ""
            roadB.append(s)
        }
        let indexed = spotlightCount("kMDItemContentType == \"com.apple.mail.emlx\"")
        let report = self.report(roadA: roadA, roadB: roadB, consent: AppleEventsSpike.consentLabel(consent), indexed: indexed)
        print(report.joined(separator: "\n"))
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd-HHmm"
        let out = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/MacTalkAct-mail-search-\(f.string(from: Date())).txt")
        try? (report.joined(separator: "\n") + "\n").write(to: out, atomically: true, encoding: .utf8)
        print("Report: \(out.path)")
    }

    /// Road (a): a count, so no message is opened or marked. The term is escaped for AppleScript.
    static func appleScript(term: String) -> String {
        let t = term.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        return """
        with timeout of \(timeoutSeconds) seconds
            tell application id "com.apple.mail"
                set limitDate to (current date) - (\(days) * days)
                count (messages of inbox whose subject contains "\(t)" and date received > limitDate)
            end tell
        end timeout
        """
    }

    /// Road (b): the Spotlight query for messages of the last `days` days whose subject contains the term.
    static func spotlightQuery(term: String) -> String {
        let t = term.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        return "kMDItemContentType == \"com.apple.mail.emlx\" && kMDItemSubject == \"*\(t)*\"cd && kMDItemContentCreationDate >= $time.today(-\(days))"
    }

    /// The inbox of any account: `…/INBOX.mbox/…` in Mail's folders.
    static func isInboxPath(_ path: String) -> Bool { path.contains("/INBOX.mbox/") }

    private static func spotlight(term: String) -> (paths: [String]?, error: String?) {
        let (out, status) = mdfind([spotlightQuery(term: term)])
        guard status == 0 else { return (nil, "mdfind \(status)") }
        return (out.split(separator: "\n").map(String.init), nil)
    }

    private static func spotlightCount(_ query: String) -> Int? {
        let (out, status) = mdfind(["-count", query])
        return status == 0 ? Int(out.trimmingCharacters(in: .whitespacesAndNewlines)) : nil
    }

    private static func mdfind(_ args: [String]) -> (String, Int32) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/mdfind")
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return ("", -1) }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (String(data: data, encoding: .utf8) ?? "", p.terminationStatus)
    }

    /// The report: times, counts and permissions only, never what the messages say. Pure, tested by
    /// `--selftest`.
    static func report(roadA: [Search], roadB: [Search], consent: String, indexed: Int?) -> [String] {
        func summary(_ searches: [Search]) -> String {
            let times = searches.compactMap(\.seconds).sorted()
            guard !times.isEmpty else { return "nessuna ricerca eseguita" }
            let failed = searches.filter { !$0.error.isEmpty }.count
            let within = times.filter { $0 <= 3 }.count
            return String(format: "mediana %.2f s · massimo %.2f s · entro 3 s %d/%d · errori %d", median(times), times.last ?? 0, within, times.count, failed)
        }
        var lines = ["Spike ricerca in Mail (ultimi \(days) giorni, posta in arrivo) · \(roadA.count) ricerche per strada"]
        lines.append("(a) Apple Events · consenso Automazione verso Mail: \(consent) · \(summary(roadA))")
        for s in roadA { lines.append("    «\(s.term)» · \(s.seconds.map { String(format: "%.2f s", $0) } ?? "—") · \(s.count.map(String.init) ?? "—") messaggi\(s.error.isEmpty ? "" : " · \(s.error)")") }
        let index = indexed.map { $0 == 0 ? "0 messaggi di Mail visibili (indice assente o non leggibile senza accesso completo al disco)" : "\($0) messaggi di Mail nell'indice" } ?? "conteggio non riuscito"
        lines.append("(b) Spotlight · \(index) · \(summary(roadB))")
        for (i, s) in roadB.enumerated() {
            let a = i < roadA.count ? roadA[i].count : nil
            let completeness = (a != nil && s.count != nil) ? " · rispetto ad (a): \(s.count!)/\(a!)" : ""
            lines.append("    «\(s.term)» · \(s.seconds.map { String(format: "%.2f s", $0) } ?? "—") · \(s.count.map(String.init) ?? "—") messaggi\(completeness)\(s.error.isEmpty ? "" : " · \(s.error)")")
        }
        if roadB.allSatisfy({ ($0.count ?? 0) == 0 }) {
            lines.append("    apertura per identificativo: non provata (nessun risultato da Spotlight)")
        }
        return lines
    }

    static func median(_ sorted: [Double]) -> Double {
        guard !sorted.isEmpty else { return 0 }
        let n = sorted.count
        return n % 2 == 1 ? sorted[n / 2] : (sorted[n / 2 - 1] + sorted[n / 2]) / 2
    }
}
