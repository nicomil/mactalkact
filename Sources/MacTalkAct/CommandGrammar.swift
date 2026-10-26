import Foundation

/// A command recognised locally, without AI. Executed in milliseconds.
enum Command: Equatable {
    case keys(combo: String, label: String, confirm: Bool)
    case scroll(direction: String, amount: Int)
    case repeatLast
    case openApp(String)
    case openURL(String)
    case click(String)
    case type(String)
    case stop
    case help
    case startDictation
    case showNumbers
    case hideNumbers
}

/// Fast-path grammar for Italian voice commands.
///
/// Matching is done on a normalised form of the transcript (lowercase, no
/// accents, no punctuation) so that "Giù." and "giu" are the same command.
/// Whole-utterance matching is deliberate: "copia" alone is a command, but a
/// sentence that merely contains "copia" is dictation.
enum Grammar {

    // MARK: Normalisation

    static func normalize(_ s: String) -> String {
        let folded = s.folding(options: [.diacriticInsensitive, .caseInsensitive, .widthInsensitive],
                               locale: Locale(identifier: "it_IT")).lowercased()
        var out = String.UnicodeScalarView()
        for scalar in folded.unicodeScalars {
            if CharacterSet.alphanumerics.contains(scalar) {
                out.append(scalar)
            } else {
                out.append(" ")
            }
        }
        return String(out).split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    static let edgePunctuation = CharacterSet.whitespacesAndNewlines.union(.punctuationCharacters)

    private static let leadingFillers: Set<String> = ["ok", "okay", "allora", "dai", "ehm", "uhm", "beh", "ecco"]
    private static let trailingFillers: Set<String> = ["grazie"]

    /// Removes polite fillers ("per favore", "grazie", "ok") around a command.
    static func stripFillers(_ words: [String]) -> [String] {
        var w = words
        while let first = w.first {
            let n = normalize(first)
            if n.isEmpty || leadingFillers.contains(n) { w.removeFirst(); continue }
            if n == "per", w.count > 1, normalize(w[1]) == "favore" { w.removeFirst(2); continue }
            break
        }
        while let last = w.last {
            let n = normalize(last)
            if n.isEmpty || trailingFillers.contains(n) { w.removeLast(); continue }
            if n == "favore", w.count > 1, normalize(w[w.count - 2]) == "per" { w.removeLast(2); continue }
            break
        }
        return w
    }

    // MARK: Exact phrases

    static let exact: [String: Command] = {
        var m: [String: Command] = [:]
        func k(_ phrases: [String], _ combo: String, _ label: String, confirm: Bool = false) {
            for p in phrases { m[p] = .keys(combo: combo, label: label, confirm: confirm) }
        }
        k(["invio", "premi invio", "enter", "manda invio"], "return", "Invio")
        k(["a capo", "vai a capo", "nuova riga", "accapo"], "shift+return", "A capo")
        k(["tab", "premi tab", "tabulazione", "campo successivo"], "tab", "Tab")
        k(["campo precedente"], "shift+tab", "Campo precedente")
        k(["esc", "escape", "premi esc", "esci"], "escape", "Esc")
        k(["annulla", "annulla ultima azione", "undo"], "cmd+z", "Annulla")
        k(["ripristina", "rifai", "redo"], "cmd+shift+z", "Ripristina")
        k(["copia"], "cmd+c", "Copiato")
        k(["incolla"], "cmd+v", "Incollato")
        k(["taglia"], "cmd+x", "Tagliato")
        k(["seleziona tutto", "seleziona tutto il testo"], "cmd+a", "Seleziona tutto")
        k(["salva", "salva il file", "salva documento"], "cmd+s", "Salvato")
        k(["chiudi", "chiudi finestra", "chiudi la finestra", "chiudi scheda", "chiudi la scheda", "chiudi tab"], "cmd+w", "Chiudi")
        k(["chiudi applicazione", "chiudi l app", "chiudi app", "esci dall app", "esci dall applicazione"], "cmd+q", "Chiudo l'app?", confirm: true)
        k(["nuova scheda", "nuovo tab", "apri nuova scheda"], "cmd+t", "Nuova scheda")
        k(["nuova finestra"], "cmd+n", "Nuova finestra")
        k(["scheda successiva", "prossima scheda", "tab successivo"], "ctrl+tab", "Scheda successiva")
        k(["scheda precedente", "tab precedente"], "ctrl+shift+tab", "Scheda precedente")
        k(["indietro", "torna indietro", "pagina precedente"], "cmd+[", "Indietro")
        k(["avanti", "vai avanti", "pagina successiva"], "cmd+]", "Avanti")
        k(["ricarica", "aggiorna", "ricarica pagina", "ricarica la pagina", "aggiorna pagina"], "cmd+r", "Ricarica")
        k(["cerca", "trova", "cerca nella pagina"], "cmd+f", "Cerca")
        k(["barra indirizzi", "vai alla barra indirizzi", "indirizzo"], "cmd+l", "Barra indirizzi")
        k(["cancella", "cancella carattere", "backspace"], "delete", "Cancella")
        k(["cancella parola", "cancella ultima parola", "cancella l ultima parola"], "alt+delete", "Cancella parola")
        k(["cancella riga", "cancella la riga"], "cmd+delete", "Cancella riga")
        k(["spazio", "premi spazio"], "space", "Spazio")
        k(["freccia su"], "up", "↑")
        k(["freccia giu"], "down", "↓")
        k(["freccia sinistra", "sinistra"], "left", "←")
        k(["freccia destra", "destra"], "right", "→")
        k(["inizio riga"], "cmd+left", "Inizio riga")
        k(["fine riga"], "cmd+right", "Fine riga")
        k(["vai in cima", "inizio pagina", "torna in cima", "in cima"], "cmd+up", "In cima")
        k(["vai in fondo", "fine pagina", "in fondo"], "cmd+down", "In fondo")
        k(["pagina giu"], "pagedown", "Pagina giù")
        k(["pagina su"], "pageup", "Pagina su")
        k(["minimizza", "riduci", "riduci a icona"], "cmd+m", "Minimizza")
        k(["schermo intero", "tutto schermo"], "ctrl+cmd+f", "Schermo intero")
        k(["app precedente", "cambia app", "torna all app precedente", "applicazione precedente"], "cmd+tab", "App precedente")

        for p in ["giu", "scorri", "scorri giu", "scorre", "scorre giu", "scendi", "scorri in basso", "piu giu", "vai giu", "abbassa", "scorri verso il basso"] {
            m[p] = .scroll(direction: "down", amount: 1)
        }
        for p in ["su", "scorri su", "scorre su", "sali", "scorri in alto", "piu su", "vai su", "scorri verso l alto"] {
            m[p] = .scroll(direction: "up", amount: 1)
        }
        for p in ["scorri molto giu", "giu giu", "molto giu"] { m[p] = .scroll(direction: "down", amount: 3) }
        for p in ["scorri molto su", "su su", "molto su"] { m[p] = .scroll(direction: "up", amount: 3) }
        for p in ["ancora", "di nuovo", "ripeti", "ancora una volta", "un altra volta"] { m[p] = .repeatLast }
        for p in ["stop", "fermati", "ferma", "basta", "fine", "smetti di ascoltare", "stop ascolto"] { m[p] = .stop }
        for p in ["aiuto", "comandi", "cosa posso dire", "guida", "mostra comandi"] { m[p] = .help }
        for p in ["mostra numeri", "mostra i numeri", "mostrami i numeri", "numeri", "numera", "numeri sullo schermo",
                  "metti i numeri"] { m[p] = .showNumbers }
        for p in ["nascondi numeri", "nascondi i numeri", "togli i numeri", "togli numeri", "via i numeri"] { m[p] = .hideNumbers }
        for p in ["scrivi", "detta", "dettatura", "inizia dettatura", "inizia a scrivere", "modalita dettatura"] { m[p] = .startDictation }
        return m
    }()

    // MARK: Prefix commands

    private enum PrefixKind { case open, click, type }

    /// Longest prefixes first so "clicca su" wins over "clicca".
    private static let prefixes: [(String, PrefixKind)] = [
        ("fai clic su", .click), ("clicca sulla", .click), ("clicca sul", .click), ("clicca su", .click),
        ("click su", .click), ("clic su", .click), ("premi su", .click), ("clicca", .click),
        ("premi", .click), ("tocca", .click), ("seleziona", .click),
        ("vai su", .open), ("vai a", .open), ("passa a", .open), ("apri", .open), ("lancia", .open), ("avvia", .open),
        ("mostrami", .open), ("mostra", .open), ("torna su", .open), ("torna a", .open), ("porta in primo piano", .open),
        ("scrivi", .type), ("digita", .type), ("detta", .type),
    ]

    /// Key names that may follow "premi" ("premi tab", "premi esc").
    private static let keyNames: [String: (String, String)] = [
        "tab": ("tab", "Tab"), "esc": ("escape", "Esc"), "invio": ("return", "Invio"),
        "spazio": ("space", "Spazio"), "cancella": ("delete", "Cancella"),
    ]

    static func parse(_ text: String) -> Command? {
        let words = stripFillers(text.split(whereSeparator: \.isWhitespace).map(String.init))
        guard !words.isEmpty else { return nil }
        let n = normalize(words.joined(separator: " "))
        guard !n.isEmpty else { return nil }

        if let c = exact[n] { return c }

        for (prefix, kind) in prefixes where n.hasPrefix(prefix + " ") {
            let count = prefix.split(separator: " ").count
            let rest = words.dropFirst(count).joined(separator: " ")
                .trimmingCharacters(in: edgePunctuation)
            guard !rest.isEmpty else { return nil }
            let restNorm = normalize(rest)
            let restWords = restNorm.split(separator: " ").count

            switch kind {
            case .type:
                // "scrivi a Marco che…" / "scrivi una mail…" is a request, not text to type.
                let firstRest = restNorm.split(separator: " ").first.map(String.init) ?? ""
                let requestStarts: Set<String> = ["a", "al", "alla", "allo", "ai", "agli", "alle", "una", "un", "uno"]
                if prefix == "scrivi" && requestStarts.contains(firstRest) && restWords > 2 { return nil }
                // Keep the dictated punctuation at the end ("ciao a tutti.").
                let dictated = words.dropFirst(count).joined(separator: " ")
                    .trimmingCharacters(in: .whitespaces)
                    .drop(while: { $0 == ":" || $0 == "," })
                return .type(String(dictated).trimmingCharacters(in: .whitespaces))
            case .click:
                if let (combo, label) = keyNames[restNorm] { return .keys(combo: combo, label: label, confirm: false) }
                // "seleziona" followed by a long phrase is an edit request, not a click.
                if prefix == "seleziona" && restWords > 4 { return nil }
                return .click(rest)
            case .open:
                if looksLikeDomain(rest) { return .openURL(rest) }
                // "apri la prima mail", "mostra l'ultimo messaggio": an item on screen, not an app.
                let ordinals: Set<String> = ["primo", "prima", "secondo", "seconda", "terzo", "terza", "ultimo",
                                             "ultima", "penultimo", "penultima", "questo", "questa", "quel", "quella"]
                if restNorm.split(separator: " ").contains(where: { ordinals.contains(String($0)) }) { return nil }
                // "apri la mail di Marco di ieri" is too rich for the fast path.
                return restWords <= 4 ? .openApp(rest) : nil
            }
        }
        return nil
    }

    static func looksLikeDomain(_ s: String) -> Bool {
        let t = s.lowercased().trimmingCharacters(in: edgePunctuation)
        guard !t.contains(" "), t.contains(".") else { return false }
        let tld = t.split(separator: ".").last ?? ""
        return tld.count >= 2 && tld.allSatisfy(\.isLetter)
    }

    // MARK: Intent hints

    private static let actionVerbs: Set<String> = [
        "apri", "clicca", "premi", "chiudi", "vai", "cerca", "rispondi", "invia", "manda", "inoltra",
        "cancella", "elimina", "seleziona", "sostituisci", "traduci", "rendi", "rendilo", "rendila",
        "riscrivi", "correggi", "sistema", "sposta", "trascina", "copia", "incolla", "salva", "scorri",
        "torna", "crea", "aggiungi", "togli", "rimuovi", "allega", "scarica", "metti", "accorcia",
        "riassumi", "formatta", "evidenzia", "passa", "mostra", "nascondi", "ingrandisci", "rimpicciolisci",
        "compila", "riempi", "attiva", "disattiva", "imposta", "programma", "fissa", "condividi",
        "mostrami", "trova", "trovami", "ricorda", "ricordati", "dimentica", "memorizza", "cercami", "leggi", "leggimi", "dimmi", "fammi", "prenota", "aggiorna",
        "archivia", "segna", "ordina", "filtra", "scegli", "spunta", "chiama", "riproduci",
    ]

    /// True when the utterance sounds like an instruction to the computer
    /// rather than text to type ("cancella l'ultima frase" vs "ci vediamo domani").
    static func startsWithActionVerb(_ text: String) -> Bool {
        let words = stripFillers(text.split(whereSeparator: \.isWhitespace).map(String.init))
        guard let first = words.first else { return false }
        return actionVerbs.contains(normalize(first))
    }

    private static let yesWords: Set<String> = [
        "si", "conferma", "confermo", "vai", "procedi", "ok", "okay", "esegui", "certo", "fallo",
        "si grazie", "si vai", "si procedi", "si conferma", "va bene", "certamente", "yes",
    ]

    static func isYes(_ text: String) -> Bool {
        let n = normalize(text)
        return yesWords.contains(n) || (n.hasPrefix("si ") && n.split(separator: " ").count <= 3)
    }

    private static let dictationEndWords: Set<String> = [
        "fine", "fine dettatura", "basta", "stop", "ho finito", "fine testo", "chiudi dettatura", "basta cosi",
    ]

    /// "fine" / "basta" closes a long dictation.
    static func isDictationEnd(_ text: String) -> Bool {
        dictationEndWords.contains(normalize(text))
    }

    /// "dodici" → 12, "ventitre" → 23 … up to 300. Apple's formatter writes compound
    /// numbers well but cannot parse them, so the table is built from its output.
    private static let wordNumbers: [String: Int] = {
        let f = NumberFormatter()
        f.locale = Locale(identifier: "it_IT")
        f.numberStyle = .spellOut
        var map: [String: Int] = [:]
        for n in 1...300 {
            guard let w = f.string(from: NSNumber(value: n)) else { continue }
            let clean = normalize(w.replacingOccurrences(of: "\u{00AD}", with: "")).replacingOccurrences(of: " ", with: "")
            map[clean] = n
        }
        map["un"] = 1
        return map
    }()

    private static let numberFillers: Set<String> = [
        "clicca", "click", "clic", "premi", "tocca", "apri", "numero", "il", "lo", "la", "l", "sul", "sullo",
        "sulla", "su", "al", "allo", "alla", "n", "elemento",
    ]

    /// "12", "dodici", "clicca il 12", "doppio clic 7", "tasto destro 3" → number + click method.
    static func numberChoice(_ text: String) -> (number: Int, method: String)? {
        var words = normalize(text).split(separator: " ").map(String.init)
        var method = "auto"
        if words.contains("doppio") { method = "double"; words.removeAll { $0 == "doppio" } }
        if words.contains("destro") { method = "right"; words.removeAll { $0 == "destro" || $0 == "tasto" } }
        words.removeAll { numberFillers.contains($0) }
        guard !words.isEmpty, words.count <= 3 else { return nil }
        if words.count == 1, let n = Int(words[0]), n > 0 { return (n, method) }
        return wordNumbers[words.joined()].map { ($0, method) }
    }

    static func isStop(_ text: String) -> Bool {
        if case .stop? = parse(text) { return true }
        return false
    }
}

// MARK: - Wake phrase

enum WakeWord {
    /// If `text` starts with one of the wake phrases, returns the rest (possibly empty).
    static func strip(_ text: String, phrases: [String]) -> String? {
        let words = text.split(whereSeparator: \.isWhitespace).map(String.init)
        let normWords = words.map { Grammar.normalize($0) }
        for phrase in phrases {
            let pw = phrase.split(separator: " ").map(String.init)
            guard !pw.isEmpty, normWords.count >= pw.count else { continue }
            if Array(normWords.prefix(pw.count)) == pw {
                return words.dropFirst(pw.count).joined(separator: " ")
                    .trimmingCharacters(in: Grammar.edgePunctuation)
            }
        }
        return nil
    }

    /// Finds the wake phrase anywhere (last occurrence) and returns what follows it.
    /// Speech captured before it (TV, a chat with the baby) is dropped.
    static func extract(_ text: String, phrases: [String]) -> String? {
        let words = text.split(whereSeparator: \.isWhitespace).map(String.init)
        let normWords = words.map { Grammar.normalize($0) }
        var bestEnd: Int?
        for phrase in phrases {
            let pw = phrase.split(separator: " ").map(String.init)
            guard !pw.isEmpty, normWords.count >= pw.count else { continue }
            for start in 0...(normWords.count - pw.count) where Array(normWords[start..<start + pw.count]) == pw {
                let end = start + pw.count
                if bestEnd == nil || end > bestEnd! { bestEnd = end }
            }
        }
        guard let end = bestEnd else { return nil }
        return words.dropFirst(end).joined(separator: " ").trimmingCharacters(in: Grammar.edgePunctuation)
    }

    static func contains(_ text: String, phrases: [String]) -> Bool {
        extract(text, phrases: phrases) != nil
    }

    static func startsWithWake(_ text: String, phrases: [String]) -> Bool {
        let n = Grammar.normalize(text)
        return phrases.contains { !$0.isEmpty && (n == $0 || n.hasPrefix($0 + " ")) }
    }
}

// MARK: - Label matching

enum LabelMatcher {
    private static let stopWords: Set<String> = [
        "il", "lo", "la", "i", "gli", "le", "l", "un", "uno", "una", "su", "sul", "sulla", "sullo",
        "pulsante", "bottone", "tasto", "link", "voce", "icona", "scheda", "menu", "di", "del", "della",
    ]

    static func clean(_ query: String) -> String {
        Grammar.normalize(query).split(separator: " ").filter { !stopWords.contains(String($0)) }.joined(separator: " ")
    }

    /// 0...100 similarity between what the user said and an on-screen label.
    static func score(query: String, label: String) -> Int {
        let q = clean(query)
        let l = Grammar.normalize(label)
        guard !q.isEmpty, !l.isEmpty else { return 0 }
        if l == q { return 100 }
        if l.hasPrefix(q + " ") || l.hasSuffix(" " + q) { return 85 }
        if l.hasPrefix(q) { return 80 }
        if l.contains(q) { return 70 }
        if q.contains(l) && l.count >= 3 { return 60 }
        let qw = Set(q.split(separator: " ")), lw = Set(l.split(separator: " "))
        let common = qw.intersection(lw)
        guard !common.isEmpty else { return 0 }
        return Int(55.0 * Double(common.count) / Double(qw.count))
    }

    /// Index of the best label, preferring shorter labels on ties.
    static func best(query: String, labels: [String], threshold: Int = 45) -> Int? {
        var bestIndex: Int?
        var bestScore = threshold - 1
        for (i, label) in labels.enumerated() {
            let s = score(query: query, label: label)
            if s > bestScore || (s == bestScore && bestIndex != nil && label.count < labels[bestIndex!].count) {
                bestScore = s
                bestIndex = i
            }
        }
        return bestIndex
    }
}

// MARK: - Text editing

enum TextDiff {
    /// How to turn `old` (text before the caret) into `new` using only
    /// backspaces and an insertion at the caret.
    static func backspaceEdit(old: String, new: String) -> (deletes: Int, insert: String) {
        let o = Array(old), n = Array(new)
        var p = 0
        while p < o.count && p < n.count && o[p] == n[p] { p += 1 }
        return (o.count - p, String(n[p...]))
    }

    /// Adds a leading space when the new text would otherwise stick to the previous word.
    static func spaced(_ text: String, after before: String) -> String {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let first = t.first, let prev = before.last else { return t }
        if prev.isWhitespace || "([{\"'«“‘/-".contains(prev) { return t }
        if ",.;:!?)]}»”’".contains(first) { return t }
        return " " + t
    }
}
