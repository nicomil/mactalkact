import NaturalLanguage
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
    /// `after`: the last exchange with the computer («richiesta» → risposta) when the sentence
    /// comes during the conversation window: a follow-up question refers to it.
    func classify(_ text: String, editable: Bool, after: String?) async -> Classification
    func prewarm()
}

extension IntentClassifier {
    func classify(_ text: String, editable: Bool) async -> Classification {
        await classify(text, editable: editable, after: nil)
    }
}

// MARK: - Rules (fallback, prudent)

/// Deterministic fallback when the on-device model is not available.
/// Says "uncertain" whenever it does not really know, so nothing is typed by mistake.
@MainActor
final class RuleClassifier: IntentClassifier {
    let name = "regole"

    func classify(_ text: String, editable: Bool, after: String?) async -> Classification {
        if Grammar.startsWithActionVerb(text) || RouteHeuristics.isRequestToComputer(text) || RouteHeuristics.isScreenQuestion(text) {
            return Classification(kind: .command, source: name)
        }
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
    chiacchiera: parla a chi è nella stanza (bambino, partner): saluti, complimenti, domande personali a loro, esclamazioni.
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
    /// Called again when the user starts speaking: after some idle time macOS unloads the model,
    /// and a cold model misses the timeout.
    func prewarm() {
        guard Self.isAvailable else { return }
        if let ready { ready.prewarm(); return }
        let s = makeSession()
        s.prewarm()
        ready = s
    }

    func classify(_ text: String, editable: Bool, after: String?) async -> Classification {
        guard Self.isAvailable else { return Classification(kind: .uncertain, source: "on-device non disponibile") }
        let session = ready ?? makeSession()
        ready = nil
        var prompt = editable ? "«\(text)»" : "«\(text)» (nessun campo di testo attivo)"
        if let after, !after.isEmpty {
            // Follow-ups («e che cosa sono?») only make sense next to what the computer just said.
            prompt += "\n(Ultimo scambio col computer: \(after.prefix(300)))"
        }
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

    private static let requestOpenings = [
        "mi spieghi", "spiegami", "mi dici", "dimmi", "leggimi", "mi leggi", "riassumi", "mi riassumi", "traduci",
        "mi traduci", "mostrami", "fammi vedere", "descrivimi", "cosa c'e scritto", "che cosa c'e scritto",
    ]

    private static let connectives: Set<String> = ["e", "ed", "ma", "ora", "adesso", "poi", "allora", "invece", "ok", "okay", "anche"]

    /// «E torna a quello di prima» → «torna a quello di prima»: the follow-up without its opening words.
    static func withoutConnectives(_ text: String) -> String {
        var words = text.split(whereSeparator: \.isWhitespace).map(String.init)
        while words.count > 1, connectives.contains(Grammar.normalize(words[0])) { words.removeFirst() }
        return words.joined(separator: " ")
    }

    private static let questionWords = ["cosa", "che cosa", "cos e", "che e", "come", "perche", "quale", "quali", "quanti", "quante", "dove", "chi"]
    private static let screenWords: Set<String> = [
        "schermo", "finestra", "cartella", "cartelle", "file", "comando", "comandi", "output", "terminale", "pagina",
        "app", "applicazione", "interfaccia", "errore", "errori", "messaggio", "scritto", "scritta", "vedo", "vede",
        "vedi", "vediamo", "vedendo", "guardando", "qui", "qua", "questo", "questa", "questi", "queste", "codice", "tabella",
        "grafico", "pulsante", "bottone", "menu", "risultato", "risultati", "elenco", "lista", "documento", "progetto",
    ]

    /// «Cosa vedo qui?», «che cos'è questo errore?», «cosa c'è in questa cartella?»: a question about
    /// what is on screen. «Dove hai messo le chiavi?» is not (no reference to the screen).
    static func isScreenQuestion(_ text: String) -> Bool {
        let n = Grammar.normalize(withoutConnectives(text)).replacingOccurrences(of: "'", with: " ")
        guard questionWords.contains(where: { n.hasPrefix($0 + " ") || n.contains(" " + $0 + " ") }) else { return false }
        let words = Set(n.split(separator: " ").map(String.init))
        return !words.isDisjoint(with: screenWords)
    }

    private static let pronounQuestionWords: Set<String> = [
        "e", "ma", "che", "cosa", "cos", "come", "perche", "quale", "quali", "quanti", "quante", "sono", "significa",
        "significano", "vuol", "vuole", "dire", "fa", "fanno", "serve", "servono", "questo", "questa", "questi",
        "queste", "quello", "quella", "quelli", "quelle", "ci", "c", "li", "lo", "a", "di", "invece", "allora", "poi",
    ]
    private static let questionStarts: Set<String> = ["che", "cosa", "cos", "come", "perche", "quale", "quali", "quanti", "quante", "a", "di"]

    /// «E che cosa sono?», «a cosa servono?», «perché?»: a question made only of question words and
    /// pronouns refers to what the computer just said. «Dove sono le salviette?» names its own object.
    static func isPronounQuestion(_ text: String) -> Bool {
        let words = Grammar.normalize(withoutConnectives(text)).replacingOccurrences(of: "'", with: " ")
            .split(separator: " ").map(String.init)
        guard let first = words.first, words.count <= 6, questionStarts.contains(first) else { return false }
        return words.allSatisfy(pronounQuestionWords.contains)
    }

    private static let referencePhrases = [
        "quella sotto", "quello sotto", "quella sopra", "quello sopra", "quella dopo", "quello dopo", "l altra",
        "l altro", "la seconda", "il secondo", "la terza", "il terzo", "la prossima", "il prossimo", "la precedente",
        "il precedente", "di prima", "come prima", "lo stesso", "la stessa", "anche quella", "anche quello",
    ]

    /// «No aspetta, quella sotto», «fai lo stesso con l'altra»: a correction or a repetition that only
    /// makes sense right after the computer acted.
    static func isReferenceCorrection(_ text: String) -> Bool {
        let n = " " + Grammar.normalize(text).replacingOccurrences(of: "'", with: " ") + " "
        return referencePhrases.contains { n.contains(" \($0) ") }
    }

    /// A sentence of the conversation window that continues the exchange: an action verb even after
    /// «e», «ma», «ora» («e torna a quello di prima»), a request to the computer, a question on the screen.
    static func isFollowUpRequest(_ text: String) -> Bool {
        let stripped = withoutConnectives(text)
        return Grammar.startsWithActionVerb(stripped) || isRequestToComputer(stripped) || isScreenQuestion(text)
            || isPronounQuestion(text) || isReferenceCorrection(text)
    }

    /// «Mi spieghi cos'è questa app?», «dimmi cosa c'è scritto»: questions and requests to the computer
    /// about the screen, recognizable from how they start.
    static func isRequestToComputer(_ text: String) -> Bool {
        let n = Grammar.normalize(text).replacingOccurrences(of: "'", with: " ")
        return requestOpenings.contains { n.hasPrefix(Grammar.normalize($0).replacingOccurrences(of: "'", with: " ")) }
    }

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

    /// One action, said briefly: no «e»/comma joining two actions, no complex markers (FR-43).
    static func isOneStep(_ text: String) -> Bool {
        let n = Grammar.normalize(text)
        let words = n.split(separator: " ")
        // «mail» or «messaggio» make a request complex for the model choice, not more than one step:
        // «apri la mail di Laura» is one click.
        guard !words.isEmpty, words.count <= 8 else { return false }
        // Whole words or phrases: «ricerca» is not «cerca», «sogni» is not «ogni».
        let padded = " " + n + " "
        if multiStepMarkers.contains(where: { padded.contains(" \($0) ") }) { return false }
        if text.contains(where: { ",.;".contains($0) }) { return false }
        let joiners: Set<Substring> = ["e", "ed", "poi", "anche", "quindi", "dopo", "oppure", "infine", "o"]
        return !words.contains(where: joiners.contains)
    }

    /// The request names something the app knows (AD-23, FR-43): an installed app, a site,
    /// an element visible on screen, or something from the conversation memory.
    @MainActor static func hasKnownTarget(_ text: String, knownApp: (String) -> Bool, labels: [String], memory: [String]) -> Bool {
        let n = Grammar.normalize(text)
        let words = n.split(separator: " ").map(String.init).filter { $0.count >= 3 && !targetStopwords.contains($0) }
        guard !words.isEmpty else { return false }
        // App or site: any word, or the words after the verb («apri la mail di Laura» → «mail di laura»).
        if words.contains(where: knownApp) || words.contains(where: { LocalActionValidator.site(for: $0) != nil }) { return true }
        func matches(_ s: String) -> Bool {
            let l = Grammar.normalize(s)
            guard l.count >= 3 else { return false }
            return words.contains { w in l == w || l.split(separator: " ").contains(Substring(w)) }
        }
        return labels.contains(where: matches) || memory.contains(where: matches)
    }

    private static let multiStepMarkers = [
        "tutte", "tutti", "ogni", "ciascun", "dopo di che", "scrivi a", "rispondi", "cerca", "trova", "riassumi",
        "traduci", "confronta", "compila", "prenota", "pensaci bene", "con calma",
    ]

    private static let targetStopwords: Set<String> = [
        "seleziona", "spunta", "riapri", "attiva", "disattiva", "copia", "incolla", "vedere", "torna", "scorri", "porta",
        "apri", "clicca", "premi", "chiudi", "vai", "metti", "togli", "scrivi", "mostra", "fammi", "della", "dello",
        "delle", "degli", "nella", "nello", "sulla", "sullo", "con", "per", "che", "una", "uno", "gli", "dal", "dalla",
        "pulsante", "bottone", "tasto", "voce", "scheda", "finestra", "pagina", "questa", "questo", "quella", "quello",
    ]

    /// Why a sentence without the wake word looks heard by chance (FR-48, AD-23), or nil:
    /// at most three words and no known target, or mostly words that are not Italian.
    @MainActor static func spuriousReason(_ text: String, knownTarget: (String) -> Bool) -> String? {
        let words = Grammar.normalize(text).split(separator: " ").map(String.init)
        guard !words.isEmpty else { return "frase vuota dopo la normalizzazione" }
        let known = knownTarget(text)
        if words.count <= 3, !known { return "frase breve senza un bersaglio noto" }
        // The language of a short sentence, or of one that names something known, is not reliable.
        if !known, words.count >= 3, mostlyForeign(text) { return "parole che non sono italiane" }
        return nil
    }

    /// The sentence is in another language: the Italian dictionary accepts many English words
    /// («the», «story»), the language of the whole sentence does not (`NLLanguageRecognizer`).
    /// The original text, with its accents and apostrophes, helps the recognizer.
    static func mostlyForeign(_ text: String) -> Bool {
        let r = NLLanguageRecognizer()
        r.languageConstraints = [.italian, .english, .spanish, .french, .german, .portuguese]
        r.processString(text)
        let it = r.languageHypotheses(withMaximum: 6)[.italian] ?? 0
        return it < 0.2
    }

    /// "pensaci bene" forces the deep model.
    static func wantsDeepThinking(_ text: String) -> Bool {
        let n = Grammar.normalize(text)
        return n.contains("pensaci bene") || n.contains("ragionaci bene")
    }
}
