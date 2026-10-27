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

/// After an action: is the request done?
@Generable
struct LocalCheck {
    @Guide(description: "le cose distinte che la richiesta chiede di fare, una per voce (es. scrivere il nome; scrivere l'email)")
    var parti: [String]
    @Guide(description: "le parti che i passi fatti NON hanno ancora eseguito con esito ok")
    var mancanti: [String]
    @Guide(description: "una frase breve in italiano che dice cosa è stato fatto")
    var risposta: String
}

/// One step of a plan: the element is named by its text, the app finds its id (Story 5.4).
@Generable
struct LocalPlanStep {
    @Guide(description: "azione", .anyOf(["clicca", "scrivi", "sostituisci", "tasti", "apri_app", "apri_sito", "scorri"]))
    var azione: String
    @Guide(description: "il testo dell'elemento esattamente come appare nell'elenco (pulsante, link, casella, campo); vuoto per tasti, apri_app, apri_sito, scorri")
    var elemento: String
    @Guide(description: "testo da scrivere, testo nuovo, tasti come cmd+t, nome dell'app, sito, oppure giu/su/fondo")
    var valore: String
    @Guide(description: "solo per sostituisci: il testo attuale esatto da cambiare")
    var trova: String
}

/// The whole plan for a request, in one call.
@Generable
struct LocalPlan {
    @Guide(description: "i passi in ordine, uno per ogni cosa da fare; vuoto se la richiesta non si può fare con questi elementi", .maximumCount(8))
    var passi: [LocalPlanStep]
    @Guide(description: "frase breve in italiano al passato, es. «Ho aperto la mail di Marco», oppure perché non si può fare")
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
    /// For confirmations: the user hears what the action is for.
    var currentRequest = ""

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
        /// Distance from the top of the window, in points.
        var y: Int = 0
        /// The window belongs to a web browser.
        var inBrowser = false
        /// The observation marks page elements with «(page)» (so unmarked ones are browser chrome).
        var pageMarked = false
        /// Inside the web page.
        var inPage = false
    }

    static let browsers = ["com.apple.Safari", "com.google.Chrome", "com.microsoft.edgemac", "org.mozilla.firefox",
                           "company.thebrowser.Browser", "com.brave.Browser"]

    /// "[12]* link «Prezzi» @10,20 50x16" → id 12, compact line without coordinates.
    static func parse(_ observed: String) -> (header: [String], elements: [Element], truncated: Bool) {
        var header: [String] = []
        var elements: [Element] = []
        var truncated = false
        let browser = browsers.contains { observed.prefix(200).contains("(\($0))") }
        let marked = observed.contains("(page)")
        for raw in observed.split(separator: "\n").map(String.init) {
            if raw.hasPrefix("[") {
                guard let close = raw.firstIndex(of: "]"), let id = Int(raw[raw.index(after: raw.startIndex)..<close]) else { continue }
                var line = raw.replacingOccurrences(of: " (page)", with: "")
                    .replacingOccurrences(of: #" @-?\d+,-?\d+ \d+x\d+$"#, with: "", options: .regularExpression)
                if line.count > 90 { line = String(line.prefix(87)) + "…»" } // small context: short lines
                line = line.replacingOccurrences(of: "]*", with: "]")
                let label = raw.range(of: "«").flatMap { a in raw.range(of: "»", range: a.upperBound..<raw.endIndex).map { String(raw[a.upperBound..<$0.lowerBound]) } } ?? ""
                let role = raw[raw.index(after: close)...].replacingOccurrences(of: "*", with: "")
                    .split(separator: " ").first.map(String.init) ?? ""
                var y = 0
                if let at = raw.range(of: #" @-?\d+,(-?\d+) "#, options: .regularExpression) {
                    y = Int(raw[at].split(separator: ",").last?.trimmingCharacters(in: .whitespaces) ?? "") ?? 0
                }
                elements.append(Element(id: id, line: line.replacingOccurrences(of: " (page)", with: ""), label: label,
                                        role: role, y: y, inBrowser: browser, pageMarked: marked, inPage: raw.contains(" (page)")))
            } else if raw.hasPrefix("(list truncated") || raw.hasPrefix("(search stopped") {
                truncated = true
            } else if raw.hasPrefix("APP:") || raw.hasPrefix("WINDOW:") || raw.hasPrefix("FOCUSED:") {
                header.append(raw.replacingOccurrences(of: #" size \d+x\d+$"#, with: "", options: .regularExpression))
            }
        }
        return (header, elements, truncated)
    }

    /// The elements most related to the request, in screen order.
    static func relevant(_ all: [Element], request: String, limit: Int = 30) -> [Element] {
        let elements = all.filter { !isBrowserChrome($0) }
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
        let r = await lookAll(request)
        return (r.header, Self.relevant(r.elements, request: request), r.note)
    }

    private func lookAll(_ request: String) async -> (header: [String], elements: [Element], note: String) {
        let observed = await tools.call("observe", [:])
        let parsed = Self.parse(text(observed))
        // A number or a name of the request that is not on screen (e.g. «articolo 137» further down):
        // search the whole window for it. A search makes the previous ids stale, so either its
        // results are used or the window is observed again.
        let original = request.split(separator: " ").map { String($0).trimmingCharacters(in: .punctuationCharacters) }
        let names = Set(original.filter { $0.first?.isUppercase == true }.map { Grammar.normalize($0) })
        let labels = parsed.elements.map { Grammar.normalize($0.label) }.joined(separator: " ")
        let missing = Self.keywords(request)
            .filter { $0.allSatisfy(\.isNumber) || (names.contains($0) && $0.count >= 4) || parsed.truncated && $0.count >= 5 }
            .sorted { ($0.allSatisfy(\.isNumber) ? 0 : 1, -$0.count) < ($1.allSatisfy(\.isNumber) ? 0 : 1, -$1.count) }
            .first { !labels.split(separator: " ").contains(Substring($0)) }
        guard let kw = missing else { return (parsed.header, parsed.elements, "") }
        let words = Grammar.normalize(request).split(separator: " ").map(String.init)
        var query = kw
        if let i = words.firstIndex(of: kw), i > 0, !Self.stopWords.contains(words[i - 1]) { query = words[i - 1] + " " + kw }
        let found = Self.parse(text(await tools.call("observe", ["query": query])))
        if !found.elements.isEmpty {
            return (found.header, found.elements, "(risultati della ricerca «\(query)» nella finestra)")
        }
        let again = Self.parse(text(await tools.call("observe", [:])))
        return (again.header, again.elements, "")
    }

    struct Outcome {
        let answer: String
        let completed: Bool
    }

    /// Asks the model whether the steps done so far satisfy the request.
    private func isDone(request: String, history: [String]) async throws -> String? {
        let session = LanguageModelSession(model: model, instructions: """
        Controlli se una richiesta fatta al computer è già stata eseguita. Guarda solo i passi fatti e il loro esito.
        """)
        let prompt = """
        Richiesta: «\(request)»
        Passi fatti:
        \(history.joined(separator: "\n"))
        Elenca le parti della richiesta e quelle che mancano ancora.
        """
        let check = try await session.respond(to: prompt, generating: LocalCheck.self,
                                              options: GenerationOptions(samplingMode: .greedy)).content
        Log.detail("Locale verifica: parti \(check.parti) · mancanti \(check.mancanti)")
        guard check.mancanti.isEmpty, !check.parti.isEmpty else { return nil }
        return check.risposta.isEmpty ? "Fatto" : check.risposta
    }

    // MARK: Plan mode (default)

    /// Greedy and short: a plan never needs more than a few hundred tokens (a runaway answer
    /// filled the small context in ~70 s before failing).
    static let planOptions = GenerationOptions(samplingMode: .greedy, maximumResponseTokens: 800)

    static let planInstructions = """
    Pianifichi le azioni sul Mac per una richiesta detta a voce. Ricevi gli elementi della finestra in primo \
    piano, ognuno con il suo testo tra « ». Rispondi con i passi in ordine, uno per ogni cosa da fare.
    Regole:
    - Indica ogni elemento con il suo testo tra « » (solo il testo, senza tipo né id).
    - Puoi indicare anche elementi che compariranno dopo un clic: per esempio, dopo aver aperto una mail, \
    i suoi pulsanti «Elimina» o «Segna come letta».
    - Per scrivere in un campo: scrivi, con elemento = testo del campo e valore = testo da scrivere.
    - Per cambiare un testo esistente: sostituisci, con trova = testo attuale e valore = testo nuovo.
    - Per cancellare tutto il testo di un campo: sostituisci con trova vuoto e valore vuoto.
    - Non usare mai la barra degli indirizzi del browser se la richiesta riguarda la pagina.
    - Per spuntare una casella: clicca sulla casella se è (unchecked). Per togliere la spunta: clicca se è (checked).
    - Per aprire una voce, una mail o un link: clicca sul suo testo.
    - Per inviare un modulo: clicca sul pulsante di invio, dopo aver compilato i campi.
    - Per scorrere la pagina usa scorri (valore giu, su o fondo): non cliccare voci a caso.
    - Per cercare in una pagina o in una posta: scrivi nel campo di ricerca.
    - Per scegliere una voce di un menu a tendina: clicca sul menu con valore = voce da scegliere.
    - Fai solo ciò che è chiesto, niente di più.
    Esempi:
    «apri la mail di Ottavio» → clicca «Ottavio Zeta Gita in barca»
    «cerca le mail di Ottavio» → scrivi «Cerca» valore Ottavio
    «elimina la mail dello zoo» → clicca «Zoo Biglietti ridotti»; clicca «Elimina»
    «spunta Ottavio alle 07:15» → clicca «Ottavio 07:15»
    «scegli Aosta come città» → clicca «Città» valore Aosta
    «scorri fino in fondo» → scorri valore fondo
    «scrivi Ottavio nel campo nome e invia» → scrivi «Nome» valore Ottavio; clicca «Invia»
    I nomi degli esempi sono inventati: usa solo elementi dell'elenco che c'entrano con la richiesta.
    """

    private static let roleWords: Set<String> = ["textfield", "textarea", "searchfield", "button", "link", "checkbox",
                                                 "popupbutton", "statictext", "combobox", "radiobutton", "menuitem",
                                                 "campo", "pulsante", "casella", "elemento"]

    /// "textfield «Nome»" → "Nome": the model often copies the whole line.
    static func cleanName(_ name: String) -> String {
        if let a = name.range(of: "«"), let b = name.range(of: "»", range: a.upperBound..<name.endIndex) {
            return String(name[a.upperBound..<b.lowerBound])
        }
        var words = name.replacingOccurrences(of: "\"", with: " ").split(separator: " ").map(String.init)
        while let w = words.first, roleWords.contains(w.lowercased()) { words.removeFirst() }
        if let w = words.first, w.hasPrefix("["), w.hasSuffix("]") { words.removeFirst() }
        return words.joined(separator: " ")
    }

    /// Browser toolbars are never the target of a request about the page.
    static func isBrowserChrome(_ e: Element) -> Bool {
        // In a browser only the page counts: toolbars, tabs and sidebars are never the target.
        // Menus opened by the page (drop-down lists) live outside the web area but belong to it.
        if e.inBrowser, e.pageMarked, !e.inPage, !e.role.contains("menu") { return true }
        // Tabs (radio buttons, cells) and toolbar buttons at the top of a browser window.
        if e.inBrowser, e.y < 130, ["radiobutton", "cell", "tab", "button", "menubutton", "toolbar"].contains(e.role) { return true }
        let l = Grammar.normalize(e.label)
        return ["smart search field", "address and search bar", "barra degli indirizzi", "cerca o inserisci",
                "indirizzo e ricerca", "tab bar", "barra dei pannelli"].contains { l.contains($0) }
    }

    /// A small model asked to change existing text tends to type the new text next to the old one.
    /// The local engine never types into a field that already has content when the request is an
    /// edit: it says so instead of damaging the document (Story 5.4).
    static func unsafeEdit(_ p: LocalPlanStep, element e: Element, request: String) -> String? {
        guard p.azione == "scrivi" else { return nil }
        let n = Grammar.normalize(request)
        let edit = ["modifica", "cambia", "sostituisci", "correggi", "rimetti", "aggiorna"].contains { n.contains($0) }
        guard edit else { return nil }
        let hasValue = e.line.range(of: #"value=«[^»]+»"#, options: .regularExpression) != nil
        let isCodeCell = ["textarea", "group", "statictext"].contains(e.role) && e.label.count > 20
        guard hasValue || isCodeCell || e.role == "textarea" else { return nil }
        return "Col modello locale non modifico testi già scritti: rischierei di rovinarli. Chiedilo a Claude o a Codex."
    }

    /// «Elimina», «Invia», «Segna come letta», «Salva», «Cerca»: labels of commands, not of content.
    static func commandLabel(_ name: String) -> Bool {
        let first = Grammar.normalize(cleanName(name)).split(separator: " ").first.map(String.init) ?? ""
        return ["elimina", "invia", "segna", "salva", "cerca", "rispondi", "inoltra", "archivia", "annulla", "conferma",
                "ok", "chiudi", "apri", "aggiungi", "modifica", "avanti", "indietro", "accedi", "esci", "iscriviti"].contains(first)
    }

    /// Best element for a name given by the model: exact label, then shared words.
    /// Numbers must match exactly ("Articolo 137" is never "Articolo 23").
    static func resolve(_ name: String, among elements: [Element], azione: String, value: String = "") -> Element? {
        let n = Grammar.normalize(cleanName(name))
        guard !n.isEmpty else { return nil }
        let numbers = Set(n.split(separator: " ").map(String.init).filter { $0.allSatisfy(\.isNumber) })
        let elements = elements.filter { !isBrowserChrome($0) && (numbers.isEmpty || numbers.isSubset(of:
            Set(Grammar.normalize($0.label).split(separator: " ").map(String.init)))) }
        let textRoles: Set<String> = ["textfield", "textarea", "searchfield", "combobox"]
        let wantsField = azione == "scrivi" || azione == "sostituisci"
        let nWords = Set(n.split(separator: " ").map(String.init))
        func score(_ e: Element) -> Int {
            let l = Grammar.normalize(e.label)
            guard !l.isEmpty else { return 0 }
            var s = 0
            if l == n { s += 100 } else if l.contains(n) { s += 40 } else if n.contains(l), l.count >= 3 { s += 30 }
            let lWords = Set(l.split(separator: " ").map(String.init))
            s += 5 * nWords.intersection(lWords).count
            if s > 0, wantsField { s += textRoles.contains(e.role) ? 20 : -10 }
            if s > 0, azione == "clicca" {
                // A click goes to a control, not to its caption; a value means a drop-down menu.
                if ["button", "link", "checkbox", "radiobutton", "popupbutton", "combobox", "menuitem", "menubutton", "cell"].contains(e.role) { s += 15 }
                if !value.isEmpty, ["popupbutton", "combobox"].contains(e.role) { s += 25 }
            }
            return s
        }
        let best = elements.map { ($0, score($0)) }.filter { $0.1 > 0 }.max { a, b in
            a.1 != b.1 ? a.1 < b.1 : a.0.id > b.0.id // ties: the first on screen
        }
        return best?.0
    }

    func runPlan(request: String, context: String) async throws -> Outcome {
        var me = self
        me.currentRequest = request
        return try await me.runPlanBody(request: request, context: context)
    }

    private func runPlanBody(request: String, context: String) async throws -> Outcome {
        let first = await lookAll(request)
        func makePrompt(_ limit: Int) -> String {
            let shown = Self.relevant(first.elements, request: request, limit: limit)
            return """
            \(context)
            \(first.header.joined(separator: "\n"))
            Elementi \(first.note):
            \(shown.isEmpty ? "(nessun elemento leggibile)" : shown.map(\.line).joined(separator: "\n"))
            Fai il piano per: «\(request)»
            """
        }
        let plan: LocalPlan
        do {
            plan = try await LanguageModelSession(model: model, instructions: Self.planInstructions)
                .respond(to: makePrompt(25), generating: LocalPlan.self, options: Self.planOptions).content
        } catch {
            // Context full or an answer cut short: once more, with the most relevant elements only.
            // Apple's model has a small context: try again with the most relevant elements only.
            Log.detail("Locale: contesto pieno, riprovo con meno elementi")
            plan = try await LanguageModelSession(model: model, instructions: Self.planInstructions)
                .respond(to: makePrompt(10), generating: LocalPlan.self, options: Self.planOptions).content
        }
        Log.detail("Locale piano: " + plan.passi.map { "\($0.azione) «\($0.elemento)» «\($0.valore)»" }.joined(separator: "; "))
        guard !plan.passi.isEmpty else {
            return Outcome(answer: "Col modello locale non ci riesco: \(plan.risposta)", completed: false)
        }
        // A click on something unrelated to the request (copied from an example, or a guess) is dropped:
        // the target must share a word with the request, or be a short command label («Elimina», «Invia»).
        let requestWords = Set(Self.keywords(request).map { String($0.prefix(5)) })
        let related = plan.passi.filter { p in
            guard p.azione == "clicca" else { return true }
            let words = Self.keywords(Self.cleanName(p.elemento))
            // Sending, deleting, buying only when the request asks for it (never «scrivi il nome» → «Invia»).
            if Safety.isRiskyLabel(Self.cleanName(p.elemento)), !Safety.isRiskyLabel(request) {
                Log.detail("Locale: scarto «\(p.elemento)», azione rischiosa non chiesta")
                return false
            }
            if words.count <= 3, !words.isEmpty, words.allSatisfy({ !$0.first!.isNumber }), Self.commandLabel(p.elemento) { return true }
            let keep = words.contains { requestWords.contains(String($0.prefix(5))) } || !p.valore.isEmpty
            if !keep { Log.detail("Locale: scarto «\(p.elemento)», non c'entra con la richiesta") }
            return keep
        }
        // Sending, deleting, buying go after everything else (a small model may put «Invia» first).
        func risky(_ p: LocalPlanStep) -> Bool { p.azione == "clicca" && Safety.isRiskyLabel(Self.cleanName(p.elemento)) }
        let safeSteps: [LocalPlanStep] = related.filter { !risky($0) }
        let riskySteps: [LocalPlanStep] = related.filter { risky($0) }
        let ordered: [LocalPlanStep] = safeSteps + riskySteps
        var elements = first.elements
        var history: [String] = []
        var queue = Array(ordered.prefix(maxSteps))
        var done: [(LocalStep, String)] = []
        var retried = Set<Int>()
        var index = 0
        var actions = 0
        while index < queue.count, actions < maxSteps {
            try Task.checkCancellation()
            var p = queue[index]
            if actions > 0 {
                try? await Task.sleep(for: .milliseconds(300))
                elements = await lookAll(p.elemento.isEmpty ? request : Self.cleanName(p.elemento)).elements
            }
            // «scrivi» nothing = clear the field; «scorri» to the end of a page = end of page.
            if p.azione == "scrivi", p.valore.isEmpty { p.azione = "sostituisci"; p.trova = "" }
            if p.azione == "scorri", ["fondo", "fine pagina", "in fondo"].contains(where: { Grammar.normalize(request).contains($0) }) {
                p.valore = "fondo"; p.elemento = ""
            }
            var step = LocalStep(azione: p.azione, id: 0, ids: [], valore: p.valore, trova: p.trova, risposta: "")
            var label = ""
            var detour = false
            if ["clicca", "scrivi", "sostituisci"].contains(p.azione) {
                if var e = Self.resolve(p.elemento, among: elements, azione: p.azione, value: p.valore) {
                    // «Città» is often the caption of a drop-down whose own label is its value («Scegli…»).
                    if p.azione == "clicca", !p.valore.isEmpty, !["popupbutton", "combobox"].contains(e.role),
                       let menu = elements.first(where: { ["popupbutton", "combobox"].contains($0.role) && $0.id > e.id && $0.id <= e.id + 4 }) {
                        e = menu
                    }
                    step.id = e.id
                    label = e.label
                    if let refusal = Self.unsafeEdit(p, element: e, request: request) {
                        return Outcome(answer: refusal, completed: false)
                    }
                    // «clicca Città» then «scrivi Città Torino»: one choice from the menu.
                    if e.role == "popupbutton", p.valore.isEmpty, index + 1 < queue.count,
                       Grammar.normalize(Self.cleanName(queue[index + 1].elemento)) == Grammar.normalize(e.label),
                       !queue[index + 1].valore.isEmpty {
                        p.valore = queue[index + 1].valore
                        queue.remove(at: index + 1)
                    }
                    if p.azione != "sostituisci", e.role == "popupbutton", !p.valore.isEmpty {
                        // A drop-down menu: open it, then choose the entry.
                        let r = await execute(step, label: label)
                        try? await Task.sleep(for: .milliseconds(400))
                        let menu = await lookAll(p.valore).elements
                        if let item = Self.resolve(p.valore, among: menu.filter { $0.role.contains("menu") }, azione: "clicca")
                            ?? Self.resolve(p.valore, among: menu, azione: "clicca") {
                            let r2 = await execute(LocalStep(azione: "clicca", id: item.id, ids: [], valore: "", trova: "", risposta: ""), label: item.label)
                            history.append("\(history.count + 1). scegli «\(item.label)» in «\(label)» → \(r2.prefix(80))")
                            if r2.hasPrefix("ok") {
                                done.append((LocalStep(azione: "scegli", id: item.id, ids: [], valore: item.label, trova: "", risposta: ""), label))
                            }
                        } else {
                            _ = await tools.call("press_keys", ["keys": "escape"])
                            history.append("\(history.count + 1). apri «\(label)» → \(r.prefix(60)); voce «\(p.valore)» non trovata → ERRORE")
                        }
                        actions += 1
                        index += 1
                        continue
                    }
                } else {
                    // Not on screen by that name: let the model choose among what is there.
                    let seen = await look(Self.cleanName(p.elemento) + " " + request)
                    let ask = """
                    Richiesta: «\(request)»
                    Passo da fare ora: \(p.azione) «\(Self.cleanName(p.elemento))» \(p.valore)
                    Passi già fatti:
                    \(history.isEmpty ? "nessuno" : history.joined(separator: "\n"))
                    Elementi:
                    \(seen.elements.map(\.line).joined(separator: "\n"))
                    Scegli il passo.
                    """
                    let s2 = LanguageModelSession(model: model, instructions: Self.instructions)
                    let c = try await s2.respond(to: ask, generating: LocalStep.self, options: GenerationOptions(samplingMode: .greedy)).content
                    if c.azione == "fatto" { index += 1; continue }
                    if c.azione == "impossibile" { return Outcome(answer: "Col modello locale non ci riesco: \(c.risposta)", completed: false) }
                    step = c
                    label = seen.elements.first { $0.id == c.id }?.label ?? ""
                    if let e = seen.elements.first(where: { $0.id == c.id }),
                       let refusal = Self.unsafeEdit(LocalPlanStep(azione: c.azione, elemento: e.label, valore: c.valore, trova: c.trova),
                                                     element: e, request: request) {
                        return Outcome(answer: refusal, completed: false)
                    }
                    if c.azione == "clicca", Safety.isRiskyLabel(label), !Safety.isRiskyLabel(request) {
                        return Outcome(answer: "Col modello locale mi fermo: «\(label)» non era nella richiesta", completed: false)
                    }
                    // Something else first (e.g. open the mail that shows «Elimina»): then try this step again.
                    detour = !retried.contains(index) && Grammar.normalize(label) != Grammar.normalize(Self.cleanName(p.elemento))
                }
            }
            let result = await execute(step, label: label)
            actions += 1
            if result.hasPrefix("ok") { done.append((step, label)) }
            history.append("\(history.count + 1). \(describe(step, label: label)) → \(result.prefix(100).replacingOccurrences(of: "\n", with: " "))")
            Log.detail("Locale esegue: \(history.last ?? "")")
            if result.contains("non ha confermato") {
                return Outcome(answer: "Mi fermo: non hai confermato", completed: false)
            }
            if detour, result.hasPrefix("ok") {
                retried.insert(index + 1) // the copy never detours again
                queue.insert(p, at: index + 1) // same step again, now that the screen changed
            }
            index += 1
        }
        let failed = history.filter { $0.contains("→ ERRORE") }.count
        if failed == history.count {
            return Outcome(answer: "Col modello locale non ci riesco: \(history.last.map { String($0.prefix(80)) } ?? plan.risposta)", completed: false)
        }
        // What was really done, said plainly (the model's own sentence may promise more).
        let summary = done.isEmpty ? "Fatto" : Self.summary(done)
        return Outcome(answer: failed == 0 ? summary : summary + " (qualche passo non è riuscito: controlla)", completed: failed == 0)
    }

    // MARK: Step mode

    func run(request: String, context: String) async throws -> Outcome {
        var me = self
        me.currentRequest = request
        return try await me.runSteps(request: request, context: context)
    }

    private func runSteps(request: String, context: String) async throws -> Outcome {
        var history: [String] = []
        var lastAction = ""
        var repeats = 0
        var doneActions: Set<String> = []
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
            let label = seen.elements.first { $0.id == choice.id }?.label ?? ""
            // Ids change at every observe: compare actions by what they act on.
            let signature = "\(choice.azione)|\(Grammar.normalize(label))|\(choice.ids.count)|\(choice.valore)|\(choice.trova)"
            repeats = signature == lastAction ? repeats + 1 : 0
            lastAction = signature
            Log.detail("Locale passo \(step): \(signature) (id \(choice.id))")
            switch choice.azione {
            case "fatto":
                return Outcome(answer: choice.risposta.isEmpty ? "Fatto" : choice.risposta, completed: true)
            case "impossibile":
                return Outcome(answer: "Col modello locale non ci riesco: \(choice.risposta)", completed: false)
            default:
                break
            }
            // The same action, already done with success, is never repeated (typing twice, clicking a box twice).
            if doneActions.contains(signature) {
                if let answer = try await isDone(request: request, history: history) {
                    return Outcome(answer: answer, completed: true)
                }
                if repeats >= 1 {
                    return Outcome(answer: "Col modello locale non ci riesco: ripeto sempre lo stesso passo", completed: false)
                }
                history.append("\(step). \(describe(choice, label: label)) → già fatto prima: scegli un altro passo o fatto")
                continue
            }
            let result = await execute(choice, label: label)
            history.append("\(step). \(describe(choice, label: label)) → \(result.prefix(120).replacingOccurrences(of: "\n", with: " "))")
            if result.hasPrefix("ok") {
                doneActions.insert(signature)
                if let answer = try await isDone(request: request, history: history) {
                    return Outcome(answer: answer, completed: true)
                }
            }
        }
        return Outcome(answer: "Col modello locale non ci riesco in \(maxSteps) passi", completed: false)
    }

    /// «Ho cliccato «Prezzi»», «Ho scritto «Mario» in «Nome» e ho cliccato «Invia»».
    static func summary(_ steps: [(LocalStep, String)]) -> String {
        func one(_ c: LocalStep, _ label: String) -> String {
            switch c.azione {
            case "clicca": return label.isEmpty ? "ho cliccato" : "ho cliccato «\(label.prefix(40))»"
            case "clicca_tutti": return "ho cliccato \(c.ids.count) elementi"
            case "scrivi": return "ho scritto «\(c.valore.prefix(40))»" + (label.isEmpty ? "" : " in «\(label.prefix(30))»")
            case "sostituisci": return c.trova.isEmpty ? "ho svuotato «\(label.prefix(30))»" : "ho cambiato «\(c.trova.prefix(30))» in «\(c.valore.prefix(30))»"
            case "tasti": return "ho premuto \(c.valore)"
            case "apri_app", "apri_sito": return "ho aperto \(c.valore)"
            case "scorri": return "ho scorso la pagina"
            case "scegli": return "ho scelto «\(c.valore.prefix(30))» in «\(label.prefix(30))»"
            default: return c.azione
            }
        }
        var parts = steps.map { one($0.0, $0.1) }
        // Many clicks of the same kind read better as a count.
        if parts.count > 3 { parts = Array(parts.prefix(2)) + ["altri \(parts.count - 2) passi"] }
        let text = parts.count > 1 ? parts.dropLast().joined(separator: ", ") + " e " + parts.last! : parts[0]
        return text.prefix(1).uppercased() + text.dropFirst()
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
        let request = currentRequest
        func call(_ name: String, _ args: [String: Any]) async -> String {
            // A risky action asks the user inside the tool (FR-51): a «no» comes back as an error.
            let r = await tools.call(name, args)
            let t = text(r)
            if r.isError, t.contains("did not confirm") { return "l'utente non ha confermato" }
            return (r.isError ? "ERRORE: " : "ok: ") + t
        }
        switch c.azione {
        case "clicca":
            return await call("click", ["id": c.id, "method": "auto"])
        case "clicca_tutti":
            return await call("click_many", ["ids": c.ids.isEmpty ? [c.id] : c.ids, "method": "auto"])
        case "scrivi" where c.valore.isEmpty:
            // Writing nothing means emptying the field.
            if c.id > 0 { _ = await tools.call("click", ["id": c.id, "method": "mouse"]) }
            return await call("press_keys", ["keys": "cmd+a delete"])
        case "scrivi":
            // A real click focuses web fields reliably; type_text then checks the field.
            var args: [String: Any] = ["text": c.valore]
            if c.id > 0 {
                _ = await tools.call("click", ["id": c.id, "method": "mouse"])
                args["id"] = c.id
            }
            return await call("type_text", args)
        case "sostituisci":
            if c.id > 0 { _ = await tools.call("click", ["id": c.id, "method": "mouse"]) }
            if c.trova.isEmpty {
                // Only «cancella tutto»: never rewrite a whole field the model has not read.
                guard c.valore.isEmpty else { return "ERRORE: per sostituire serve il testo attuale da cambiare (trova)" }
                return await call("press_keys", ["keys": "cmd+a delete"])
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
            if c.id == 0, v.contains("fondo") || v.contains("fine") { return await call("press_keys", ["keys": "cmd+down"]) }
            if c.id == 0, v.contains("cima") || v.contains("inizio") { return await call("press_keys", ["keys": "cmd+up"]) }
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
