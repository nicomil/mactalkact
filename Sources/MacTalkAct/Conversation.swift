import AppKit
import ApplicationServices

/// Everything the app remembers about "the conversation in progress".
/// Lives only in RAM and is owned by the Coordinator (AD-4).
@MainActor
final class ConversationState {
    /// After the wake phrase alone ("Computer…"): the next sentence is for us, whatever it is.
    var armedUntil = Date.distantPast
    /// After a response: sentences are evaluated even without the wake phrase (FR-7).
    var windowUntil = Date.distantPast
    /// "Di' «scrivilo»": text waiting for the user's go-ahead (FR-4).
    var proposedText: (text: String, expires: Date)?
    let log = ConversationLog()

    var isArmed: Bool { Date() < armedUntil }
    var isWindowOpen: Bool { Date() < windowUntil }

    var pendingProposal: String? {
        guard let p = proposedText, Date() < p.expires else { return nil }
        return p.text
    }

    func arm(seconds: TimeInterval) { armedUntil = Date().addingTimeInterval(seconds) }
    func disarm() { armedUntil = .distantPast }
    func openWindow(seconds: TimeInterval) { windowUntil = Date().addingTimeInterval(seconds) }
    func closeWindow() { windowUntil = .distantPast }
}

/// The last few interactions, so the agent understands "rimetti com'era prima" (FR-8).
/// Never written to disk; forgotten after 10 minutes of silence.
@MainActor
final class ConversationLog {
    struct Entry {
        let time: Date
        let request: String
        let outcome: String
        let app: String
        /// Text changes made during the interaction ("before → after"), when known.
        var changes: [String]
    }

    private(set) var entries: [Entry] = []
    var maxEntries: Int { max(1, AppSettings.shared.conversationMemoryCount) }
    var maxAge: TimeInterval { AppSettings.shared.conversationMemoryMinutes * 60 }

    func add(request: String, outcome: String, app: String, changes: [String] = []) {
        expire()
        entries.append(Entry(time: Date(), request: request, outcome: outcome, app: app, changes: Array(changes.suffix(6))))
        if entries.count > maxEntries { entries.removeFirst(entries.count - maxEntries) }
    }

    func clear() { entries.removeAll() }

    /// Drops everything if the last interaction is older than `maxAge`.
    func expire() {
        if let last = entries.last, Date().timeIntervalSince(last.time) > maxAge { entries.removeAll() }
    }

    /// The `<recent>` block sent to the agent. Empty when there is nothing recent.
    var promptBlock: String {
        expire()
        guard !entries.isEmpty else { return "" }
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        var lines = ["<recent>", "Most recent last. Use it to resolve references like «di prima», «anche l'altra», «rimetti com'era»."]
        for e in entries {
            var line = "- \(f.string(from: e.time)) in \(e.app): «\(e.request)» → \(e.outcome)"
            if !e.changes.isEmpty { line += "\n  changes: " + e.changes.joined(separator: " | ") }
            lines.append(line)
        }
        lines.append("</recent>")
        return lines.joined(separator: "\n")
    }
}

/// Every piece of text the app types, so "cancella quello che hai scritto" can remove
/// exactly that and nothing of the user's (FR-10, AD-5).
@MainActor
final class InsertionJournal {
    struct Insertion {
        let time: Date
        let pid: pid_t
        let element: AXUIElement?
        let text: String
        /// Text before the caret right after the insertion ("" when the field does not expose it).
        let textAfter: String
    }

    private(set) var last: Insertion?

    func record(text: String, before: ScreenContext) async {
        try? await Task.sleep(for: .milliseconds(120))
        let after = ScreenContext.capture(includeLabels: false)
        let element = AX.frontmostApplication().flatMap { AX.focusedElement(in: AX.app($0.processIdentifier)) }
        last = Insertion(time: Date(), pid: after.pid, element: element, text: text, textAfter: after.textBeforeCursor)
    }

    func clear() { last = nil }

    enum UndoPlan: Equatable {
        case deleteCharacters(Int)
        case commandZ
        case nothing
    }

    /// How to remove the last insertion given what is on screen now.
    func undoPlan(now: ScreenContext) -> UndoPlan {
        guard let last, Date().timeIntervalSince(last.time) < 10 * 60 else { return .nothing }
        guard now.pid == last.pid else { return .commandZ }
        let focused = AX.frontmostApplication().flatMap { AX.focusedElement(in: AX.app($0.processIdentifier)) }
        let sameElement: Bool = {
            guard let a = last.element, let b = focused else { return false }
            return CFEqual(a, b)
        }()
        if sameElement, !last.textAfter.isEmpty, now.textBeforeCursor == last.textAfter,
           now.textBeforeCursor.hasSuffix(last.text) {
            return .deleteCharacters(last.text.count)
        }
        return .commandZ
    }
}
