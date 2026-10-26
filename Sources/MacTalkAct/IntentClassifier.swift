import Foundation
import FoundationModels

/// What a sentence is, as far as the router cares.
struct Classification: Equatable {
    enum Kind: String { case command = "comando", dictation = "dettatura", chatter = "chiacchiera", uncertain = "incerto" }
    var kind: Kind
    /// Who answered: "on-device", "regole", "timeout"…
    var source: String
}

/// Decides whether a sentence is a command, text to type or talk with other people.
/// It only returns data: it never touches the screen (AD-2).
@MainActor
protocol IntentClassifier: AnyObject {
    var name: String { get }
    func classify(_ text: String, editable: Bool) async -> Classification
    func prewarm()
}

// MARK: - Rules (fallback, prudent)

/// Deterministic fallback when the on-device model is not available.
/// Says "uncertain" whenever it does not really know, so nothing is typed by mistake.
@MainActor
final class RuleClassifier: IntentClassifier {
    let name = "regole"

    func classify(_ text: String, editable: Bool) async -> Classification {
        if Grammar.startsWithActionVerb(text) { return Classification(kind: .command, source: name) }
        if RouteHeuristics.isShortChatter(text) { return Classification(kind: .chatter, source: name) }
        return Classification(kind: .uncertain, source: name)
    }

    func prewarm() {}
}

// MARK: - Apple on-device model

@Generable
struct OnDeviceIntent {
    @Guide(description: "categoria della frase", .anyOf(["comando", "dettatura", "chiacchiera"]))
    var tipo: String
}

/// Apple's on-device language model (FoundationModels): ~0.6 s, offline, free.
@MainActor
final class OnDeviceClassifier: IntentClassifier {
    let name = "on-device"
    let timeout: Duration
    private var ready: LanguageModelSession?

    static let instructions = """
    Classifica una frase detta a voce da chi usa il Mac con un bambino in braccio.
    comando: chiede al computer di fare qualcosa (aprire, cambiare, rimettere, cliccare, scorrere), anche breve o riferito a prima.
    dettatura: testo da scrivere nel documento per un destinatario assente (messaggi, mail, appunti).
    chiacchiera: parla a chi è nella stanza (bambino, partner): saluti, complimenti, domande a loro, esclamazioni.
    """

    static var isAvailable: Bool {
        if case .available = SystemLanguageModel.default.availability { return true }
        return false
    }

    init(timeout: Duration = .milliseconds(1500)) {
        self.timeout = timeout
    }

    private func makeSession() -> LanguageModelSession {
        LanguageModelSession(instructions: Self.instructions)
    }

    /// Loads the model in memory so the next sentence answers in ~0.6 s instead of ~2 s.
    func prewarm() {
        guard Self.isAvailable, ready == nil else { return }
        let s = makeSession()
        s.prewarm()
        ready = s
    }

    func classify(_ text: String, editable: Bool) async -> Classification {
        guard Self.isAvailable else { return Classification(kind: .uncertain, source: "on-device non disponibile") }
        let session = ready ?? makeSession()
        ready = nil
        let prompt = editable ? "«\(text)»" : "«\(text)» (nessun campo di testo attivo)"
        let limit = timeout
        let result: String? = await withTaskGroup(of: String?.self) { group in
            group.addTask { @MainActor in
                (try? await session.respond(to: prompt, generating: OnDeviceIntent.self))?.content.tipo
            }
            group.addTask {
                try? await Task.sleep(for: limit)
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
        prewarm()
        guard let tipo = result, let kind = Classification.Kind(rawValue: tipo) else {
            return Classification(kind: .uncertain, source: result == nil ? "timeout" : "risposta non valida")
        }
        return Classification(kind: kind, source: name)
    }
}

// MARK: - Small deterministic helpers shared by router and classifiers

enum RouteHeuristics {
    private static let chatterWords: Set<String> = [
        "ok", "okay", "si", "no", "bene", "bello", "bellissimo", "bellissima", "brava", "bravo", "grazie",
        "ciao", "evvai", "dai", "ecco", "perfetto", "fantastico", "wow", "ah", "oh", "eh", "mmm", "uffa",
        "amore", "tesoro", "piccolo", "piccola", "stop", "basta", "aspetta",
    ]

    /// "Bellissimo, ok, stop", "ciao amore": short sentences made only of exclamations.
    static func isShortChatter(_ text: String) -> Bool {
        let words = Grammar.normalize(text).split(separator: " ").map(String.init)
        guard !words.isEmpty, words.count <= 4 else { return false }
        return words.allSatisfy(chatterWords.contains)
    }

    private static let complexMarkers = [
        "tutte", "tutti", "ogni", "ciascun", "e poi", "dopo di che", "scrivi a", "rispondi", "cerca", "trova",
        "mail", "messaggio", "riassumi", "traduci", "confronta", "compila", "prenota", "per ciascun",
    ]

    /// Rough size of an agent request: simple ones go to the faster model (FR-13).
    static func isComplex(_ text: String) -> Bool {
        let n = Grammar.normalize(text)
        if n.contains("pensaci bene") || n.contains("con calma") { return true }
        if n.split(separator: " ").count > 14 { return true }
        return complexMarkers.contains { n.contains($0) }
    }

    /// "pensaci bene" forces the deep model.
    static func wantsDeepThinking(_ text: String) -> Bool {
        let n = Grammar.normalize(text)
        return n.contains("pensaci bene") || n.contains("ragionaci bene")
    }
}
