import Foundation
import FoundationModels

/// A one-step action the app can run by itself, without the agent (FR-11).
enum LocalAction: Equatable {
    case keys(combo: String, label: String)
    case openApp(String)
    case openURL(String)
    case scroll(direction: String)

    var summary: String {
        switch self {
        case .keys(let combo, let label): return "\(label) (\(combo))"
        case .openApp(let name): return "apri \(name)"
        case .openURL(let url): return "apri \(url)"
        case .scroll(let d): return d == "up" ? "scorri su" : "scorri giù"
        }
    }
}

/// What the on-device model proposes: data only, checked by the validator before anything runs (AD-3).
struct LocalProposal: Equatable {
    var kind: String   // tasti | apri_app | apri_sito | scorri | nessuna
    var value: String
}

@Generable
struct OnDeviceProposal {
    @Guide(description: "tipo di azione", .anyOf(["tasti", "apri_app", "apri_sito", "scorri", "nessuna"]))
    var tipo: String
    @Guide(description: "tasti: combinazione come cmd+t; apri_app: nome dell'app; apri_sito: nome o indirizzo del sito; scorri: su o giu; nessuna: vuoto")
    var valore: String
}

/// Asks the on-device model for a single action, or "nessuna" when it takes more than one step.
@MainActor
final class LocalActionProposer {
    let timeout: Duration
    private var ready: LanguageModelSession?

    static let instructions = """
    Traduci un comando vocale per macOS in UNA sola azione, solo se basta un'azione.
    - tasti: una scorciatoia. Nuova scheda cmd+t; chiudi scheda cmd+w; riapri scheda chiusa cmd+shift+t; \
    nuova finestra cmd+n; finestra privata cmd+shift+n; indietro cmd+[; avanti cmd+]; ricarica cmd+r; \
    barra degli indirizzi cmd+l; cerca nella pagina cmd+f; schermo intero ctrl+cmd+f; ingrandisci cmd+=; \
    rimpicciolisci cmd+-; dimensione normale cmd+0; minimizza cmd+m; scheda successiva ctrl+tab; \
    scheda precedente ctrl+shift+tab; prima scheda cmd+1; ultima scheda cmd+9; grassetto cmd+b; corsivo cmd+i; \
    sottolineato cmd+u; annulla cmd+z; ripristina cmd+shift+z; salva cmd+s.
    - apri_app: aprire un'applicazione per nome (Spotify, Mail, Note, Calendario).
    - apri_sito: aprire un sito web (youtube, google, wikipedia, repubblica.it).
    - scorri: su oppure giu.
    - nessuna: servono più passi, bisogna leggere o cliccare qualcosa sullo schermo, scrivere o modificare \
    testo, oppure non sei sicuro.
    """

    init(timeout: Duration = .milliseconds(1500)) {
        self.timeout = timeout
    }

    static var isAvailable: Bool { OnDeviceClassifier.isAvailable }

    func prewarm() {
        guard Self.isAvailable else { return }
        if let ready { ready.prewarm(); return }
        let s = LanguageModelSession(instructions: Self.instructions)
        s.prewarm()
        ready = s
    }

    func propose(_ text: String) async -> LocalProposal? {
        guard Self.isAvailable else { return nil }
        let session = ready ?? LanguageModelSession(instructions: Self.instructions)
        ready = nil
        let limit = timeout
        let result: LocalProposal? = await withTaskGroup(of: LocalProposal?.self) { group in
            group.addTask { @MainActor in
                guard let r = try? await session.respond(to: "Comando: «\(text)»", generating: OnDeviceProposal.self) else { return nil }
                return LocalProposal(kind: r.content.tipo, value: r.content.valore)
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
        return result
    }
}

/// Deterministic rules that approve a proposal or send the sentence to the agent (FR-12, AD-3).
@MainActor
final class LocalActionValidator {
    /// Resolves a spoken app name to an installed app's name, or nil.
    var resolveApp: (String) -> String?

    init(resolveApp: @escaping (String) -> String?) {
        self.resolveApp = resolveApp
    }

    static let allowedKeys: [String: String] = [
        "cmd+t": "Nuova scheda", "cmd+w": "Chiudi scheda", "cmd+shift+t": "Riapri scheda",
        "cmd+n": "Nuova finestra", "cmd+shift+n": "Finestra privata", "cmd+[": "Indietro", "cmd+]": "Avanti",
        "cmd+r": "Ricarica", "cmd+l": "Barra indirizzi", "cmd+f": "Cerca", "ctrl+cmd+f": "Schermo intero",
        "cmd+=": "Ingrandisci", "cmd+-": "Rimpicciolisci", "cmd+0": "Dimensione normale", "cmd+m": "Minimizza",
        "ctrl+tab": "Scheda successiva", "ctrl+shift+tab": "Scheda precedente",
        "cmd+1": "Scheda 1", "cmd+2": "Scheda 2", "cmd+3": "Scheda 3", "cmd+4": "Scheda 4", "cmd+5": "Scheda 5",
        "cmd+6": "Scheda 6", "cmd+7": "Scheda 7", "cmd+8": "Scheda 8", "cmd+9": "Ultima scheda",
        "cmd+b": "Grassetto", "cmd+i": "Corsivo", "cmd+u": "Sottolineato", "cmd+z": "Annulla",
        "cmd+shift+z": "Ripristina", "cmd+s": "Salvato", "cmd+a": "Seleziona tutto", "cmd+c": "Copiato",
        "cmd+v": "Incollato",
    ]

    static let knownSites: [String: String] = [
        "youtube": "youtube.com", "google": "google.com", "gmail": "mail.google.com",
        "wikipedia": "it.wikipedia.org", "facebook": "facebook.com", "instagram": "instagram.com",
        "linkedin": "linkedin.com", "amazon": "amazon.it", "netflix": "netflix.com", "github": "github.com",
        "whatsapp": "web.whatsapp.com", "twitter": "x.com", "x": "x.com", "repubblica": "repubblica.it",
        "corriere": "corriere.it", "google maps": "maps.google.com", "maps": "maps.google.com",
        "google drive": "drive.google.com", "drive": "drive.google.com", "chatgpt": "chatgpt.com",
        "claude": "claude.ai", "spotify web": "open.spotify.com",
    ]

    /// Words that may surround the target of «apri X» without changing its meaning.
    private static let openFillers: Set<String> = [
        "apri", "aprimi", "riapri", "vai", "andiamo", "porta", "portami", "mostra", "mostrami", "lancia", "avvia",
        "su", "sul", "sulla", "a", "al", "alla", "in", "il", "lo", "la", "l", "i", "gli", "le", "un", "una", "uno",
        "sito", "app", "applicazione", "programma", "pagina", "di", "del", "della", "mi", "per", "favore", "computer",
        "ok", "dai", "adesso", "ora", "subito", "web", "www", "com", "it",
    ]

    /// The proposal must explain the whole sentence: «cerca su YouTube una ninna nanna» is not «apri YouTube».
    static func coversSentence(_ sentence: String, target: String) -> Bool {
        let targetWords = Set(Grammar.normalize(target).split(separator: " ").map(String.init))
        let leftover = Grammar.normalize(sentence).split(separator: " ").map(String.init)
            .filter { !openFillers.contains($0) && !targetWords.contains($0) }
        return leftover.isEmpty
    }

    func validate(_ p: LocalProposal, sentence: String) -> LocalAction? {
        let value = p.value.trimmingCharacters(in: .whitespacesAndNewlines)
        let words = Grammar.normalize(sentence).split(separator: " ").count
        switch p.kind {
        case "tasti":
            guard words <= 7, let combo = Self.canonicalCombo(value), let label = Self.allowedKeys[combo],
                  !Safety.isRiskyKeys(combo) else { return nil }
            return .keys(combo: combo, label: label)
        case "apri_app":
            guard Self.coversSentence(sentence, target: value) else { return nil }
            if let name = resolveApp(value) { return .openApp(name) }
            if let site = Self.site(for: value) { return .openURL(site) }
            return nil
        case "apri_sito":
            guard Self.coversSentence(sentence, target: value) else { return nil }
            return Self.site(for: value).map { .openURL($0) }
        case "scorri":
            let n = Grammar.normalize(value)
            if ["su", "alto", "in alto", "sopra"].contains(n) { return .scroll(direction: "up") }
            if ["giu", "basso", "in basso", "sotto"].contains(n) { return .scroll(direction: "down") }
            return nil
        default:
            return nil
        }
    }

    static func site(for spoken: String) -> String? {
        let n = Grammar.normalize(spoken.replacingOccurrences(of: "www.", with: ""))
        if let s = knownSites[n] { return s }
        let raw = spoken.trimmingCharacters(in: Grammar.edgePunctuation).lowercased()
        if raw.hasPrefix("https://") || raw.hasPrefix("http://") { return raw }
        if Grammar.looksLikeDomain(raw) { return raw }
        return nil
    }

    /// "Command+T", "⌘T", "cmd + plus", "cmd++" → "cmd+t", "cmd+=". Modifiers in a fixed order.
    static func canonicalCombo(_ s: String) -> String? {
        var t = s.lowercased()
            .replacingOccurrences(of: "⌘", with: "cmd+").replacingOccurrences(of: "⇧", with: "shift+")
            .replacingOccurrences(of: "⌥", with: "alt+").replacingOccurrences(of: "⌃", with: "ctrl+")
            .replacingOccurrences(of: " ", with: "")
        if t.hasSuffix("++") { t = String(t.dropLast(2)) + "+=" }
        var mods = Set<String>()
        var key = ""
        for part in t.split(separator: "+").map(String.init) where !part.isEmpty {
            switch part {
            case "cmd", "command", "meta": mods.insert("cmd")
            case "ctrl", "control": mods.insert("ctrl")
            case "alt", "option", "opt": mods.insert("alt")
            case "shift": mods.insert("shift")
            case "plus", "piu": key = "="
            case "minus", "meno": key = "-"
            default: key = part
            }
        }
        guard !key.isEmpty, key.count <= 3 else { return nil }
        let order = ["ctrl", "alt", "shift", "cmd"].filter(mods.contains)
        // Shortcuts are written with cmd first, except ctrl+… combos.
        let ordered = order.contains("cmd") && !order.contains("ctrl")
            ? ["cmd"] + order.filter { $0 != "cmd" } : order
        return (ordered + [key]).joined(separator: "+")
    }
}
