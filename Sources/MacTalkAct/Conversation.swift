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
        /// Progressive number: a Long session receives only the entries after the last one it saw.
        var seq = 0
        let time: Date
        let request: String
        let outcome: String
        let app: String
        /// Text changes made during the interaction ("before → after"), when known.
        var changes: [String]
    }

    private(set) var entries: [Entry] = []
    /// Grows every time the memory is emptied («dimentica», private mode, expiry): a Long session
    /// that saw another generation starts again, so it forgets too.
    private(set) var generation = 0
    private var nextSeq = 1
    var snapshot: MemorySnapshot { expire(); return MemorySnapshot(generation: generation, lastSeq: entries.last?.seq ?? nextSeq - 1) }
    var maxEntries: Int { max(1, AppSettings.shared.conversationMemoryCount) }
    var maxAge: TimeInterval { AppSettings.shared.conversationMemoryMinutes * 60 }

    func add(request: String, outcome: String, app: String, changes: [String] = []) {
        // Private mode: nothing is remembered, not even in RAM.
        guard !AppSettings.shared.privateModeActive else { return }
        expire()
        entries.append(Entry(seq: nextSeq, time: Date(), request: request, outcome: outcome, app: app, changes: Array(changes.suffix(6))))
        nextSeq += 1
        if entries.count > maxEntries { entries.removeFirst(entries.count - maxEntries) }
    }

    func clear() {
        entries.removeAll()
        generation += 1
    }

    /// Drops everything if the last interaction is older than `maxAge`.
    func expire() {
        if let last = entries.last, Date().timeIntervalSince(last.time) > maxAge { clear() }
    }

    /// The `<recent>` block sent to the agent. Empty when there is nothing recent.
    static let outcomeWords = 40
    static let maxWords = 300

    static func shorten(_ text: String, words: Int) -> String {
        let w = text.split(whereSeparator: \.isWhitespace)
        return w.count <= words ? text : w.prefix(words).joined(separator: " ") + " …"
    }

    var promptBlock: String { promptBlock(after: 0) }

    /// The block with only the entries after `seq`: what a Long session has not seen yet.
    func promptBlock(after seq: Int) -> String {
        expire()
        let entries = self.entries.filter { $0.seq > seq }
        guard !entries.isEmpty else { return "" }
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        // Outcome and changed text, never the whole observation: at most `outcomeWords` per outcome
        // and `maxWords` for the block, dropping the oldest entries first (FR-47).
        var body: [String] = []
        for e in entries.reversed() {
            var line = "- \(f.string(from: e.time)) in \(e.app): «\(e.request)» → \(Self.shorten(e.outcome, words: Self.outcomeWords))"
            if !e.changes.isEmpty { line += "\n  changes: " + e.changes.joined(separator: " | ") }
            let count = (body + [line]).joined(separator: " ").split(whereSeparator: \.isWhitespace).count
            if count > Self.maxWords, !body.isEmpty { break }
            body.insert(line, at: 0)
        }
        return (["<recent>", "Most recent last. Use it to resolve references like «di prima», «anche l'altra», «rimetti com'era»."]
                + body + ["</recent>"]).joined(separator: "\n")
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
