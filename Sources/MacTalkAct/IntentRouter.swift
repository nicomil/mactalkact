import Foundation

/// Snapshot of everything the router needs to know about the app, as plain values.
struct RouterState {
    enum Listening { case pushToTalk, wakeWord, session, off }

    var listening: Listening = .wakeWord
    /// Push-to-talk sentence: always addressed to the app.
    var pushToTalk = false
    var armed = false
    var windowOpen = false
    var numbersVisible = false
    var pendingConfirmation = false
    var proposedText: String?
    var wakePhrases: [String] = ["computer"]
    /// Claude is usable at all (installed / configured).
    var aiAvailable = true
    var agentAvailability: AgentAvailability = .available
    var localLane = true
}

/// Is the agent usable right now? Owned by AgentRunner (AD-7).
enum AgentAvailability: Equatable {
    case available
    case paused(until: Date)
    case missing
}

/// The single decision taken for a sentence (AD-1). Every case carries a readable reason.
enum RouteDecision {
    case ignore(reason: String)
    case arm
    case number(Int, method: String)
    case confirmation(yes: Bool)
    case macro(Memory.Macro)
    case fast(Command, text: String)
    case dictate(String, reason: String)
    case askToType(String, reason: String)
    case typeProposed(String)
    case undoInsertion
    case closeConversation
    case forgetConversation
    case local(LocalAction, text: String)
    case agent(String, deep: Bool, reason: String)
    case reduced(String, reason: String)

    /// Short label for logs and tests.
    var label: String {
        switch self {
        case .ignore: return "ignora"
        case .arm: return "arma"
        case .number: return "numero"
        case .confirmation: return "conferma"
        case .macro: return "macro"
        case .fast: return "rapido"
        case .dictate: return "scrivi"
        case .askToType: return "chiedi"
        case .typeProposed: return "scrivilo"
        case .undoInsertion: return "annulla-scritto"
        case .closeConversation: return "chiudi-conversazione"
        case .forgetConversation: return "dimentica-conversazione"
        case .local: return "locale"
        case .agent: return "agente"
        case .reduced: return "ridotta"
        }
    }

    var reason: String {
        switch self {
        case .ignore(let r): return r
        case .arm: return "solo parola di attivazione"
        case .number(let n, _): return "numero \(n)"
        case .confirmation(let yes): return yes ? "sì" : "no"
        case .macro(let m): return "macro «\(m.name)»"
        case .fast(let c, _): return "grammatica: \(c)"
        case .dictate(_, let r), .askToType(_, let r), .agent(_, _, let r), .reduced(_, let r): return r
        case .typeProposed: return "conferma della proposta"
        case .undoInsertion: return "richiesta esplicita"
        case .closeConversation: return "chiusura esplicita"
        case .forgetConversation: return "richiesta esplicita"
        case .local(let a, _): return "proposta valida: \(a.summary)"
        }
    }

    /// Whether the log may contain the sentence (AD-9: never for ignored talk).
    var logsText: Bool {
        switch self {
        case .ignore, .arm: return false
        default: return true
        }
    }
}

/// Decides what to do with a sentence. No side effects: it never types, clicks or shows
/// anything; the Coordinator executes the returned decision (AD-1).
@MainActor
final class IntentRouter {
    let classifier: IntentClassifier
    let proposer: LocalActionProposer?
    let validator: LocalActionValidator
    /// Looks up a voice macro; injectable so tests do not read the user's memory file.
    var macroLookup: (String) -> Memory.Macro? = { Memory.shared.macro(for: $0) }

    init(classifier: IntentClassifier, proposer: LocalActionProposer?, validator: LocalActionValidator) {
        self.classifier = classifier
        self.proposer = proposer
        self.validator = validator
    }

    /// `editable`: whether the caret is in a text field (asked lazily, it costs an AX round trip).
    func decide(_ raw: String, editable: () -> Bool, state: RouterState) async -> RouteDecision {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return .ignore(reason: "frase vuota") }

        // 1. Numbers on screen: "12", "clicca il 7", no wake phrase needed.
        if state.numbersVisible {
            let spoken = WakeWord.extract(text, phrases: state.wakePhrases).flatMap { $0.isEmpty ? nil : $0 } ?? text
            if let choice = Grammar.numberChoice(spoken) { return .number(choice.number, method: choice.method) }
        }

        // 2. The wake phrase. Alone, it only arms: it is never typed (FR-2).
        let wakeRest = WakeWord.extract(text, phrases: state.wakePhrases)
        if let rest = wakeRest {
            if rest.isEmpty || RouteHeuristics.isOnlyFillers(rest) { return .arm }
            text = rest
        }
        let explicit = state.pushToTalk || wakeRest != nil || state.armed || state.listening == .session

        // 3. Answers to something the app asked.
        if state.pendingConfirmation { return .confirmation(yes: Grammar.isYes(text)) }
        if let proposal = state.proposedText, Phrases.isTypeIt(text) { return .typeProposed(proposal) }

        // 4. Conversation controls (explicit, or during the conversation window).
        if explicit || state.windowOpen {
            if Phrases.isUndoInsertion(text) { return .undoInsertion }
            if Phrases.isForgetConversation(text) { return .forgetConversation }
            if state.windowOpen && !explicit && Phrases.isCloseConversation(text) { return .closeConversation }
        }

        // 5. Not addressed to us: only a conversation window can still pick it up.
        if !explicit {
            guard state.windowOpen else { return .ignore(reason: "manca la parola di attivazione") }
            if let cmd = Grammar.parse(text) {
                if case .stop = cmd { return .closeConversation }
                if let fast = fastDecision(cmd, text: text) { return fast }
            }
            if let m = macroLookup(text) { return .macro(m) }
            if RouteHeuristics.isShortChatter(text) { return .ignore(reason: "chiacchiera breve nella finestra") }
            let c = await classifier.classify(text, editable: editable())
            guard c.kind == .command else {
                return .ignore(reason: "finestra aperta, ma \(c.kind.rawValue) (\(c.source))")
            }
            return await commandRoute(text, editable: editable, state: state, why: "comando nella finestra (\(c.source))")
        }

        // 6. Addressed: macros and the fixed grammar first.
        if let m = macroLookup(text) { return .macro(m) }
        if let cmd = Grammar.parse(text), let fast = fastDecision(cmd, text: text) { return fast }

        // 7. Free sentence. In a text field the classifier decides; elsewhere it is a request.
        let isEditable = editable()
        if isEditable {
            if RouteHeuristics.isShortChatter(text) {
                return state.pushToTalk
                    ? .askToType(text, reason: "chiacchiera breve con push-to-talk")
                    : .ignore(reason: "chiacchiera breve")
            }
            let c = await classifier.classify(text, editable: true)
            switch c.kind {
            case .dictation:
                return .dictate(text, reason: "dettatura (\(c.source))")
            case .command:
                return await commandRoute(text, editable: editable, state: state, why: "comando (\(c.source))")
            case .chatter:
                if state.listening == .session && !state.pushToTalk {
                    return .ignore(reason: "chiacchiera (\(c.source))")
                }
                return .askToType(text, reason: "chiacchiera rivolta all'app (\(c.source))")
            case .uncertain:
                return .askToType(text, reason: "incerto (\(c.source))")
            }
        }
        if RouteHeuristics.isShortChatter(text) { return .ignore(reason: "chiacchiera breve") }
        // Hands-free session without the wake phrase: talk with people in the room is not a request.
        if state.listening == .session && !state.pushToTalk && wakeRest == nil && !state.armed {
            let c = await classifier.classify(text, editable: false)
            if c.kind == .chatter { return .ignore(reason: "chiacchiera in sessione (\(c.source))") }
        }
        return await commandRoute(text, editable: editable, state: state, why: "richiesta fuori da un campo di testo")
    }

    /// A grammar command, except «apri X» when X is neither an installed app nor a known site:
    /// «apri una finestra privata», «apri la mail di Marco» need the rest of the router.
    private func fastDecision(_ cmd: Command, text: String) -> RouteDecision? {
        guard case .openApp(let name) = cmd, validator.resolveApp(name) == nil else { return .fast(cmd, text: text) }
        if let site = LocalActionValidator.site(for: name) { return .fast(.openURL(site), text: text) }
        return nil
    }

    /// A command that the grammar does not know: local lane, agent, or reduced mode.
    private func commandRoute(_ text: String, editable: () -> Bool, state: RouterState, why: String) async -> RouteDecision {
        // Only outside text fields: there, edits are about meaning and belong to the agent.
        // Long sentences are never one step: skip the model and save ~1 s for the agent.
        if state.localLane, Grammar.normalize(text).split(separator: " ").count <= 6, !editable(),
           let proposer, let proposal = await proposer.propose(text),
           let action = validator.validate(proposal, sentence: text) {
            return .local(action, text: text)
        }
        guard state.aiAvailable else {
            return .askToType(text, reason: "\(why), ma Claude non è configurato")
        }
        switch state.agentAvailability {
        case .available:
            let deep = RouteHeuristics.isComplex(text)
            return .agent(text, deep: deep, reason: "\(why) · \(deep ? "profondo" : "rapido")")
        case .paused(let until):
            let f = DateFormatter()
            f.dateFormat = "HH:mm"
            return .reduced(text, reason: "agente in pausa fino alle \(f.string(from: until))")
        case .missing:
            return .reduced(text, reason: "comando «claude» non disponibile")
        }
    }
}

/// Fixed phrases of the conversation layer.
enum Phrases {
    private static let typeIt: Set<String> = [
        "scrivilo", "scrivila", "scrivi", "si scrivilo", "si scrivi", "si scrivila", "scrivilo pure", "si",
        "si grazie", "ok scrivilo", "va bene scrivilo",
    ]
    static func isTypeIt(_ text: String) -> Bool { typeIt.contains(Grammar.normalize(text)) }

    private static let undo: Set<String> = [
        "cancella quello che hai scritto", "cancella cio che hai scritto", "togli quello che hai scritto",
        "non era da scrivere", "non dovevi scriverlo", "cancella quello che hai appena scritto",
        "togli quello che hai appena scritto", "elimina quello che hai scritto", "cancella l ultima cosa che hai scritto",
        "annulla quello che hai scritto", "cancellalo", "non era da scrivere cancellalo",
    ]
    static func isUndoInsertion(_ text: String) -> Bool { undo.contains(Grammar.normalize(text)) }

    private static let forget: Set<String> = [
        "dimentica la conversazione", "dimentica questa conversazione", "cancella la conversazione",
        "ricominciamo da capo", "dimentica tutto quello che ci siamo detti",
    ]
    static func isForgetConversation(_ text: String) -> Bool { forget.contains(Grammar.normalize(text)) }

    private static let close: Set<String> = [
        "basta cosi", "grazie", "grazie mille", "a posto", "a posto cosi", "ok grazie", "va bene grazie",
        "perfetto grazie", "abbiamo finito", "ho finito", "fine",
    ]
    static func isCloseConversation(_ text: String) -> Bool { close.contains(Grammar.normalize(text)) }
}

extension RouteHeuristics {
    private static let fillers: Set<String> = ["ok", "okay", "allora", "dai", "ehm", "uhm", "beh", "ecco", "si", "senti"]

    /// "Computer… ehm": only the wake phrase plus fillers.
    static func isOnlyFillers(_ text: String) -> Bool {
        let words = Grammar.normalize(text).split(separator: " ").map(String.init)
        return !words.isEmpty && words.allSatisfy(fillers.contains)
    }
}
