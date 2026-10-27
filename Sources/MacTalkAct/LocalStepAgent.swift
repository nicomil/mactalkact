import Foundation
import FoundationModels

/// One step chosen by the local model, with guided generation (Story 5.4).
@Generable
struct LocalStep {
    @Guide(description: "il prossimo passo", .anyOf(["clicca", "clicca_tutti", "scrivi", "sostituisci", "tasti",
                                                      "apri_app", "apri_sito", "scorri", "fatto", "impossibile"]))
    var azione: String
    @Guide(description: "id dell'elemento (clicca, scrivi, sostituisci); 0 se non serve")
    var id: Int
    @Guide(description: "per clicca_tutti: tutti gli id da cliccare")
    var ids: [Int]
    @Guide(description: "testo da scrivere, testo nuovo, nome dell'app, sito, tasti come cmd+t, oppure giu/su/fondo per scorri")
    var valore: String
    @Guide(description: "solo per sostituisci: il testo attuale esatto da cambiare")
    var trova: String
    @Guide(description: "per fatto o impossibile: una frase breve in italiano per l'utente")
    var risposta: String
}

/// The local agent as a loop driven by the app (AD-17, Story 5.4): the app observes the
/// window, keeps the elements that matter for the request, and the model only chooses the
/// next action among a few, with guided generation. Small models are much more reliable
/// this way than with free tool calling: they never act on ids they have not seen, and
/// every prompt stays a few hundred tokens long.
@MainActor
struct LocalStepAgent {
    let model: any LanguageModel
    let tools: AgentTools
    let maxSteps: Int

    static let instructions = """
    Controlli il Mac di una persona che parla. Ricevi la richiesta, i passi già fatti e gli elementi \
    della finestra in primo piano con il loro [id]. Scegli UN solo passo alla volta:
    - clicca: id dell'elemento (pulsanti, link, caselle, voci).
    - clicca_tutti: ids di più elementi da cliccare insieme (es. molte caselle).
    - scrivi: id del campo e valore = testo da scrivere.
    - sostituisci: id del campo, trova = testo attuale esatto, valore = testo nuovo.
    - tasti: valore = scorciatoia, es. cmd+t, return, escape.
    - apri_app / apri_sito: valore = nome dell'app o indirizzo.
    - scorri: valore = giu, su o fondo.
    - fatto: la richiesta è soddisfatta; risposta = cosa hai fatto, in poche parole.
    - impossibile: non si può fare con questi elementi; risposta = perché.
    Usa solo id presenti nell'elenco. Fai solo ciò che è chiesto. Quando la richiesta è soddisfatta scegli fatto.
    """

    private static let stopWords: Set<String> = [
        "il", "lo", "la", "i", "gli", "le", "un", "uno", "una", "di", "a", "da", "in", "con", "su", "per", "tra", "fra",
        "del", "della", "dei", "delle", "al", "alla", "ai", "alle", "nel", "nella", "sul", "sulla", "che", "e", "o",
        "mi", "me", "ti", "ci", "si", "tutto", "tutti", "tutte", "questa", "questo", "quella", "quello", "poi",
        "apri", "clicca", "vai", "metti", "fai", "scrivi", "cambia", "modifica", "spunta", "togli", "cerca",
    ]

    /// Words of the request that may appear in element labels.
    static func keywords(_ request: String) -> [String] {
        Grammar.normalize(request).split(separator: " ").map(String.init)
            .filter { !stopWords.contains($0) && ($0.count >= 3 || $0.allSatisfy(\.isNumber)) }
    }

    struct Element {
        let id: Int
        let line: String
        let label: String
        let role: String
    }

    /// "[12]* link «Prezzi» @10,20 50x16" → id 12, compact line without coordinates.
    static func parse(_ observed: String) -> (header: [String], elements: [Element], truncated: Bool) {
        var header: [String] = []
        var elements: [Element] = []
        var truncated = false
        for raw in observed.split(separator: "\n").map(String.init) {
            if raw.hasPrefix("[") {
                guard let close = raw.firstIndex(of: "]"), let id = Int(raw[raw.index(after: raw.startIndex)..<close]) else { continue }
                var line = raw.replacingOccurrences(of: #" @-?\d+,-?\d+ \d+x\d+$"#, with: "", options: .regularExpression)
                line = line.replacingOccurrences(of: "]*", with: "]")
                let label = raw.range(of: "«").flatMap { a in raw.range(of: "»", range: a.upperBound..<raw.endIndex).map { String(raw[a.upperBound..<$0.lowerBound]) } } ?? ""
                let role = raw[raw.index(after: close)...].split(separator: " ").first.map(String.init)?
                    .replacingOccurrences(of: "*", with: "") ?? ""
                elements.append(Element(id: id, line: line, label: label, role: role))
            } else if raw.hasPrefix("(list truncated") || raw.hasPrefix("(search stopped") {
                truncated = true
            } else if raw.hasPrefix("APP:") || raw.hasPrefix("WINDOW:") || raw.hasPrefix("FOCUSED:") {
                header.append(raw.replacingOccurrences(of: #" size \d+x\d+$"#, with: "", options: .regularExpression))
            }
        }
        return (header, elements, truncated)
    }

    /// The elements most related to the request, in screen order.
    static func relevant(_ elements: [Element], request: String, limit: Int = 30) -> [Element] {
        let kws = keywords(request)
        let n = Grammar.normalize(request)
        let writes = ["scrivi", "compila", "cerca", "cambia", "modifica", "sostituisci", "nome", "email", "campo", "cancella", "testo"]
            .contains { n.contains($0) }
        let ticks = ["spunta", "togli", "casella", "seleziona"].contains { n.contains($0) }
        func score(_ e: Element) -> Int {
            let label = Grammar.normalize(e.label)
            let words = label.split(separator: " ").map(String.init)
            var s = 0
            for k in kws {
                if k.allSatisfy(\.isNumber) {
                    if words.contains(k) { s += 4 }
                } else if words.contains(where: { $0.hasPrefix(String(k.prefix(5))) || k.hasPrefix(String($0.prefix(5))) && $0.count >= 4 }) {
                    s += 2
                }
            }
            if writes, ["textfield", "textarea", "searchfield", "combobox", "popupbutton"].contains(e.role) { s += 1 }
            if ticks, e.role == "checkbox" { s += 1 }
            if e.line.contains("(focused)") { s += 1 }
            return s
        }
        guard elements.count > limit else { return elements }
        let ranked = elements.enumerated().sorted { a, b in
            let (sa, sb) = (score(a.element), score(b.element))
            return sa != sb ? sa > sb : a.offset < b.offset
        }
        return ranked.prefix(limit).map(\.element).sorted { $0.id < $1.id }
    }

    private func text(_ r: AgentTools.Result) -> String {
        r.content.compactMap { $0["text"] as? String }.joined(separator: "\n")
    }

    /// Observes the window; on a truncated list, searches the most specific word of the request.
    private func look(_ request: String) async -> (header: [String], elements: [Element], note: String) {
        var observed = await tools.call("observe", [:])
        var parsed = Self.parse(text(observed))
        var note = ""
        if parsed.truncated {
            let labels = parsed.elements.map { Grammar.normalize($0.label) }.joined(separator: " ")
            let missing = Self.keywords(request).sorted { a, b in
                (a.allSatisfy(\.isNumber) ? 0 : 1, -a.count) < (b.allSatisfy(\.isNumber) ? 0 : 1, -b.count)
            }.first { !labels.contains($0) }
            if let kw = missing {
                // The searched word goes with its neighbour ("articolo 137").
                let words = Grammar.normalize(request).split(separator: " ").map(String.init)
                var query = kw
                if let i = words.firstIndex(of: kw), i > 0, !Self.stopWords.contains(words[i - 1]) { query = words[i - 1] + " " + kw }
                observed = await tools.call("observe", ["query": query])
                let found = Self.parse(text(observed))
                if !found.elements.isEmpty {
                    parsed = found
                    note = "(risultati della ricerca «\(query)» nella finestra)"
                }
            }
        }
        return (parsed.header, Self.relevant(parsed.elements, request: request), note)
    }

    struct Outcome {
        let answer: String
        let completed: Bool
    }

    func run(request: String, context: String) async throws -> Outcome {
        var history: [String] = []
        var lastAction = ""
        var repeats = 0
        for step in 1...max(1, maxSteps) {
            try Task.checkCancellation()
            let seen = await look(request)
            let elementLines = seen.elements.map(\.line).joined(separator: "\n")
            let prompt = """
            \(context)
            \(seen.header.joined(separator: "\n"))
            Passi già fatti:
            \(history.isEmpty ? "nessuno" : history.joined(separator: "\n"))
            Elementi \(seen.note):
            \(elementLines.isEmpty ? "(nessun elemento leggibile)" : elementLines)
            Passo \(step): scegli il prossimo passo per «\(request)».
            """
            let session = LanguageModelSession(model: model, instructions: Self.instructions)
            let choice = try await session.respond(to: prompt, generating: LocalStep.self,
                                                   options: GenerationOptions(samplingMode: .greedy)).content
            let signature = "\(choice.azione)|\(choice.id)|\(choice.ids)|\(choice.valore)|\(choice.trova)"
            repeats = signature == lastAction ? repeats + 1 : 0
            lastAction = signature
            Log.debug("Locale passo \(step): \(signature)")
            switch choice.azione {
            case "fatto":
                return Outcome(answer: choice.risposta.isEmpty ? "Fatto" : choice.risposta, completed: true)
            case "impossibile":
                return Outcome(answer: "Col modello locale non ci riesco: \(choice.risposta)", completed: false)
            default:
                break
            }
            if repeats >= 2 {
                return Outcome(answer: "Col modello locale non ci riesco: ripeto sempre lo stesso passo", completed: false)
            }
            let label = seen.elements.first { $0.id == choice.id }?.label ?? ""
            let result = await execute(choice, label: label)
            history.append("\(step). \(describe(choice, label: label)) → \(result.prefix(120).replacingOccurrences(of: "\n", with: " "))")
        }
        return Outcome(answer: "Col modello locale non ci riesco in \(maxSteps) passi", completed: false)
    }

    private func describe(_ c: LocalStep, label: String) -> String {
        switch c.azione {
        case "clicca": return "clicca [\(c.id)] «\(label)»"
        case "clicca_tutti": return "clicca_tutti \(c.ids)"
        case "scrivi": return "scrivi «\(c.valore)» in [\(c.id)]"
        case "sostituisci": return "sostituisci «\(c.trova)» con «\(c.valore)» in [\(c.id)]"
        default: return "\(c.azione) «\(c.valore)»"
        }
    }

    /// Runs the step with the app's tools; a risky action asks the user first (NFR-5).
    private func execute(_ c: LocalStep, label: String) async -> String {
        func call(_ name: String, _ args: [String: Any]) async -> String {
            var r = await tools.call(name, args)
            var t = text(r)
            if r.isError, t.contains("confirm") {
                let what = label.isEmpty ? "Confermi?" : "Confermi «\(label)»?"
                let answer = text(await tools.call("confirm", ["action": what]))
                guard answer.contains("approved") else { return "l'utente non ha confermato" }
                r = await tools.call(name, args)
                t = text(r)
            }
            return (r.isError ? "ERRORE: " : "ok: ") + t
        }
        switch c.azione {
        case "clicca":
            return await call("click", ["id": c.id, "method": "auto"])
        case "clicca_tutti":
            return await call("click_many", ["ids": c.ids.isEmpty ? [c.id] : c.ids, "method": "auto"])
        case "scrivi":
            var args: [String: Any] = ["text": c.valore]
            if c.id > 0 { args["id"] = c.id }
            return await call("type_text", args)
        case "sostituisci":
            if c.id > 0 { _ = await tools.call("click", ["id": c.id, "method": "mouse"]) }
            if c.trova.isEmpty {
                // Whole field: select all and type.
                _ = await tools.call("press_keys", ["keys": "cmd+a"])
                return await call("type_text", ["text": c.valore])
            }
            return await call("replace_text", ["find": c.trova, "replace": c.valore])
        case "tasti":
            return await call("press_keys", ["keys": c.valore])
        case "apri_app":
            return await call("open_app", ["name": c.valore])
        case "apri_sito":
            return await call("open_url", ["url": c.valore])
        case "scorri":
            let v = Grammar.normalize(c.valore)
            let up = v.hasPrefix("su") || v.contains("alto") || v.contains("cima")
            let far = v.contains("fondo") || v.contains("cima") || v.contains("fine")
            var args: [String: Any] = ["direction": up ? "up" : "down", "amount": far ? 10 : 2]
            if c.id > 0 { args["id"] = c.id }
            return await call("scroll", args)
        default:
            return "ERRORE: azione sconosciuta «\(c.azione)»"
        }
    }
}
