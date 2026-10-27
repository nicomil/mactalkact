import AppKit
import AVFoundation
import Foundation
import Speech

/// Command-line entry points for testing pieces without the full app.
@MainActor
enum DebugCLI {

    /// `--selftest`: checks the local grammar and helpers.
    static func selfTest() -> Bool {
        var failures = 0
        func check(_ name: String, _ ok: Bool) {
            print(ok ? "  ok   \(name)" : "  FAIL \(name)")
            if !ok { failures += 1 }
        }

        print("Fine della dettatura:")
        check("«Fine»", Grammar.dictationEnding("Fine.") == (true, ""))
        check("«Fine fine»", Grammar.dictationEnding("Fine fine") == (true, ""))
        check("«Ok, fine»", Grammar.dictationEnding("Ok, fine.") == (true, ""))
        check("«Basta così»", Grammar.dictationEnding("Basta così") == (true, ""))
        check("testo e poi «Fine.»", Grammar.dictationEnding("Ci vediamo domani. Fine.") == (true, "Ci vediamo domani."))
        check("«alla fine» resta testo", Grammar.dictationEnding("Siamo arrivati alla fine.") == (false, "Siamo arrivati alla fine."))
        check("«fine settimana» resta testo", !Grammar.dictationEnding("Ci vediamo nel fine settimana").ends)

        print("Fasi del Banco (Storia 7.1):")
        do {
            let t = PhaseTimer()
            func wait() { Thread.sleep(forTimeInterval: 0.03) }
            wait(); t.mark(.session)
            wait(); t.event(.sessionStarted)
            wait(); t.event(.serverConnected)
            wait(); t.event(.firstToken)
            wait(); t.mark(.actions); wait(); t.mark(.reasoning)
            wait(); t.mark(.actions); wait(); t.mark(.reasoning)
            wait(); t.event(.turnFinished(turns: 3))
            wait()
            let (phases, total) = t.finish()
            check("somma delle fasi = totale", abs(phases.values.reduce(0, +) - total) < 0.001)
            check("tutte le fasi presenti", [.scan, .session, .mcp, .firstToken, .actions, .reasoning, .finalTurn, .close].allSatisfy { (phases[$0] ?? 0) > 0 })
            check("ragionamento dopo l'ultima azione = turno finale", (phases[.finalTurn] ?? 0) > 0.02 && (phases[.reasoning] ?? 0) > (phases[.finalTurn] ?? 0))
            check("turni dal Motore", t.turns == 3)
            check("finish due volte non cambia", t.finish().phases == phases)
            let e = PhaseTimer()
            wait(); e.mark(.session); e.event(.sessionStarted); wait()
            let (ep, et) = e.finish() // error before the first token: no final turn, the sum still holds
            check("errore a metà: somma = totale", abs(ep.values.reduce(0, +) - et) < 0.001 && ep[.finalTurn] == nil)
        }
        print("Sessione lunga e versioni delle CLI (Storia 7.2):")
        do {
            check("claude 2.1.311 verificata", CLIStatus.from(versionOutput: "2.1.311 (Claude Code)", minimum: "2.1.299") == .verified("2.1.311"))
            check("claude 2.1.250 sotto la minima", CLIStatus.from(versionOutput: "2.1.250 (Claude Code)", minimum: "2.1.299") == .belowMinimum("2.1.250"))
            check("versione illeggibile: non verificata", CLIStatus.from(versionOutput: "boh", minimum: "2.1.299") == .unverified(nil))
            check("codex 0.131.0 verificata", CLIStatus.from(versionOutput: "codex-cli 0.131.0", minimum: "0.131.0").isVerified)
            check("codex alpha successiva: intervallo", CLIStatus.from(versionOutput: "codex-cli 0.133.0-alpha.2", minimum: "0.131.0").isVerified)
            check("codex 0.130.9 sotto la minima", CLIStatus.from(versionOutput: "codex-cli 0.130.9", minimum: "0.131.0") == .belowMinimum("0.130.9"))
            check("pre-release della minima: sotto", CLIStatus.from(versionOutput: "2.1.299-beta.1", minimum: "2.1.299") == .belowMinimum("2.1.299"))
            check("login mancante: stessa versione, non verificata", CLIStatus.verified("2.1.311").unverifiedForLogin == .unverified("2.1.311"))
            func reason(_ r: Int, _ idle: TimeInterval, config: Bool = false, memory: Bool = false) -> String? {
                SessionPolicy.restartReason(requests: r, maxRequests: 8, idle: idle, configChanged: config, memoryChanged: memory)
            }
            check("sessione riusata", reason(3, 60) == nil)
            check("8 richieste → riavvio", reason(8, 60) == "8 richieste")
            check("10 minuti di inattività → riavvio", reason(1, 601) == "inattiva da 10 minuti")
            check("modello o effort cambiati → riavvio", reason(1, 1, config: true) == "modello o effort cambiati")
            check("memoria azzerata → riavvio", reason(1, 1, memory: true) == "memoria azzerata")
            let log = ConversationLog()
            let g0 = log.generation
            if AppSettings.shared.privateModeActive { print("  —    memoria delta: saltata, modalità privata attiva") }
            log.add(request: "apri la mail", outcome: "fatto", app: "Mail")
            let first = log.snapshot.lastSeq
            log.add(request: "rispondi", outcome: "scritta", app: "Mail")
            let delta = log.promptBlock(after: first)
            check("memoria delta: solo la voce nuova", delta.contains("rispondi") && !delta.contains("apri la mail"))
            check("memoria completa: tutte e due", log.promptBlock.contains("apri la mail") && log.promptBlock.contains("rispondi"))
            check("niente di nuovo: blocco vuoto", log.promptBlock(after: log.snapshot.lastSeq).isEmpty)
            log.clear()
            check("dimentica: generazione nuova", log.generation == g0 + 1 && log.entries.isEmpty)
        }
        print("Eventi dei Motori per le fasi:")
        do {
            check("Claude: init con server → MCP connesso", ClaudeCLI.phase(of: ["type": "system", "subtype": "init", "mcp_servers": [["name": "mactalk", "status": "connected"]]]) == .serverConnected)
            check("Claude: init senza server → niente", ClaudeCLI.phase(of: ["type": "system", "subtype": "init", "mcp_servers": [] as [Any]]) == nil)
            check("Claude: stream_event → primo token", ClaudeCLI.phase(of: ["type": "stream_event"]) == .firstToken)
            check("Claude: result → fine turno con num_turns", ClaudeCLI.phase(of: ["type": "result", "num_turns": 3]) == .turnFinished(turns: 3))
            var parser = CodexEventParser()
            var phases: [EnginePhase] = []
            for line in ((try? String(contentsOfFile: "Tests/fixtures/codex/success.jsonl", encoding: .utf8)) ?? "").split(separator: "\n") {
                if let p = parser.phase(String(line)) { phases.append(p) }
            }
            check("Codex: turn.started → MCP, primo item → primo token", phases == [.serverConnected, .firstToken])
            check("Codex: un turno", parser.turns == 1)
            var other = CodexEventParser()
            check("Codex: «item.» dentro il testo non conta", other.phase(#"{"type":"error","message":"vedi \"item.started\""}"#) == nil)
        }
        print("Compiti del Banco:")
        do {
            let tasks = parseBench("""
            a\tposta.html\tbreve\tapri\t+aperta: X;-chiusa
            b\tapp:Finder:banco\tbreve\trinomina\t+file:finale.txt;-file:bozza.txt
            c\tapp:Calendar\tmedio\tevento\t+evento:Banco riunione
            d\twebmail:#inbox\tosserva\tcerca\t+url:search
            e\tfrase:posta.html\tbreve\tehm\t
            """)
            check("cinque compiti letti", tasks.count == 5)
            if tasks.count == 5 {
                check("pagina come prima", tasks[0].kind == .page("posta.html") && tasks[0].checks == [BenchCheck(mustContain: true, target: .title, text: "aperta: X"), BenchCheck(mustContain: false, target: .title, text: "chiusa")])
                check("Finder sulla cartella", tasks[1].kind == .app(name: "Finder", folder: true) && tasks[1].checks.map(\.target) == [.file, .file] && !tasks[1].checks[1].mustContain)
                check("evento", tasks[2].kind == .app(name: "Calendar", folder: false) && tasks[2].checks.first?.target == .event)
                check("webmail", tasks[3].kind == .webmail("#inbox") && tasks[3].kind.isReal && tasks[3].checks.first?.target == .url)
                check("frase spuria senza verifiche", tasks[4].kind == .phrase(page: "posta.html") && tasks[4].checks.isEmpty && !tasks[4].kind.isReal)
            }
            let all = loadBench("Tests/bench/agente.tsv")
            let native = all.filter { if case .app = $0.kind { return true } else { return false } }
            check("≥ 5 compiti su Mail, Calendario e Finder", native.count >= 5)
            check("≥ 2 compiti webmail", all.filter { if case .webmail = $0.kind { return true } else { return false } }.count >= 2)
            check("≥ 5 Frasi spurie", all.filter { if case .phrase = $0.kind { return true } else { return false } }.count >= 5)
            check("pagina con canvas", all.contains { $0.page == "lavagna.html" })
        }

        print("Grammatica:")
        check("giù", Grammar.parse("Giù.") == .scroll(direction: "down", amount: 1))
        check("scorri giù per favore", Grammar.parse("Scorri giù, per favore.") == .scroll(direction: "down", amount: 1))
        check("vai su = scroll", Grammar.parse("vai su") == .scroll(direction: "up", amount: 1))
        check("annulla", Grammar.parse("Annulla.") == .keys(combo: "cmd+z", label: "Annulla", confirm: false))
        check("premi invio", Grammar.parse("Premi invio") == .keys(combo: "return", label: "Invio", confirm: false))
        check("premi tab", Grammar.parse("premi tab") == .keys(combo: "tab", label: "Tab", confirm: false))
        check("chiudi applicazione chiede conferma", Grammar.parse("chiudi l'app") == .keys(combo: "cmd+q", label: "Chiudo l'app?", confirm: true))
        check("apri Safari", Grammar.parse("Apri Safari.") == .openApp("Safari"))
        check("vai su Slack", Grammar.parse("vai su Slack") == .openApp("Slack"))
        check("apri youtube.com", Grammar.parse("apri youtube.com") == .openURL("youtube.com"))
        check("clicca su Invia", Grammar.parse("Clicca su Invia.") == .click("Invia"))
        check("scrivi ciao", Grammar.parse("Scrivi ciao a tutti.") == .type("ciao a tutti."))
        check("scrivi a Marco → Claude", Grammar.parse("scrivi a Marco che arrivo alle cinque") == nil)
        check("apri lunga → Claude", Grammar.parse("apri la mail di Marco di ieri sera") == nil)
        check("apri la prima mail → agente", Grammar.parse("Apri la prima mail") == nil)
        check("mostra l'ultimo messaggio → agente", Grammar.parse("mostra l'ultimo messaggio") == nil)
        check("app: prima mail ≠ Mail", Executor.appMatchScore(query: "prima mail", name: "Mail") == 0)
        check("app: edge = Microsoft Edge", Executor.appMatchScore(query: "edge", name: "Microsoft Edge") >= 75)
        check("app: mail = Mail", Executor.appMatchScore(query: "mail", name: "Mail") == 100)
        check("app: visual studio", Executor.appMatchScore(query: "visual studio", name: "Visual Studio Code") >= 75)
        check("app: calcol", Executor.appMatchScore(query: "calcol", name: "Calcolatrice") >= 75)
        check("app: note ≠ OneNote", Executor.appMatchScore(query: "note", name: "OneNote") == 0)
        check("mostra numeri", Grammar.parse("Mostra i numeri.") == .showNumbers)
        check("numero 12", Grammar.numberChoice("12")! == (12, "auto"))
        check("clicca il 7", Grammar.numberChoice("Clicca il 7.")! == (7, "auto"))
        check("dodici", Grammar.numberChoice("dodici")?.number == 12)
        check("ventitré", Grammar.numberChoice("ventitré")?.number == 23)
        check("quarantadue", Grammar.numberChoice("quarantadue")?.number == 42)
        check("centouno", Grammar.numberChoice("centouno")?.number == 101)
        check("doppio clic 5", Grammar.numberChoice("doppio clic 5")! == (5, "double"))
        check("tasto destro 3", Grammar.numberChoice("tasto destro 3")! == (3, "right"))
        check("non numero", Grammar.numberChoice("apri safari") == nil)
        check("frase normale = dettatura", Grammar.parse("Ciao Marco, arrivo tra cinque minuti.") == nil)
        check("stop", Grammar.isStop("Basta."))
        check("sì", Grammar.isYes("Sì."))
        check("sì vai", Grammar.isYes("Sì, vai"))
        check("no", !Grammar.isYes("No, lascia stare"))
        check("verbo d'azione", Grammar.startsWithActionVerb("Cancella l'ultima frase"))
        check("non verbo", !Grammar.startsWithActionVerb("Ci vediamo domani"))

        print("Frase di attivazione:")
        let phrases = ["ehi mac", "hey mac"]
        let wakes = ["computer", "ok computer"]
        check("frase a metà: allora vediamo computer apri Safari",
              WakeWord.extract("Allora vediamo, computer apri Safari", phrases: wakes) == "apri Safari")
        check("solo computer", WakeWord.extract("Computer.", phrases: wakes) == "")
        check("niente computer", WakeWord.extract("ciao amore", phrases: wakes) == nil)
        check("scorre giù", Grammar.parse("Scorre giù") == .scroll(direction: "down", amount: 1))
        check("Ehi Mac, apri Mail", WakeWord.strip("Ehi Mac, apri Mail.", phrases: phrases) == "apri Mail")
        check("Hey Mac", WakeWord.strip("Hey Mac", phrases: phrases) == "")
        check("senza frase", WakeWord.strip("apri Mail", phrases: phrases) == nil)
        let defaults = ["computer", "ok computer", "ehi computer", "i computer"]
        check("Ok, computer scorri giù", WakeWord.strip("Ok, computer scorri giù", phrases: defaults) == "scorri giù")
        check("I computer, apri Safari", WakeWord.strip("I computer, apri Safari", phrases: defaults) == "apri Safari")

        print("Etichette:")
        let labels = ["Inviato", "Invia", "Rispondi a tutti", "Rispondi"]
        check("il pulsante invia", LabelMatcher.best(query: "il pulsante invia", labels: labels) == 1)
        check("rispondi", LabelMatcher.best(query: "rispondi", labels: labels) == 3)
        check("niente", LabelMatcher.best(query: "elimina", labels: labels) == nil)

        print("Testo:")
        let e = TextDiff.backspaceEdit(old: "Ciao. Arrivo martedì.", new: "Ciao. Arrivo giovedì.")
        check("diff martedì→giovedì", e.deletes == 8 && e.insert == "giovedì.")
        check("spazio aggiunto", TextDiff.spaced("arrivo", after: "Ciao") == " arrivo")
        check("niente spazio dopo spazio", TextDiff.spaced("arrivo", after: "Ciao ") == "arrivo")
        check("niente spazio prima di virgola", TextDiff.spaced(", poi", after: "Ciao") == ", poi")

        print("Tasti:")
        check("cmd+shift+z", KeyCombo.parse("cmd+shift+z") != nil)
        check("return", KeyCombo.parse("return")?.code == 36)
        check("sconosciuto", KeyCombo.parse("cmd+boh") == nil)

        print("Router e conversazione:")
        check("chiacchiera breve", RouteHeuristics.isShortChatter("Bellissimo, ok, stop"))
        check("non chiacchiera", !RouteHeuristics.isShortChatter("Rimetti la domanda di prima"))
        check("solo intercalari", RouteHeuristics.isOnlyFillers("ehm, allora"))
        check("scrivilo", Phrases.isTypeIt("Sì, scrivilo."))
        check("cancella quello che hai scritto", Phrases.isUndoInsertion("Cancella quello che hai scritto!"))
        check("basta così chiude", Phrases.isCloseConversation("Basta così."))
        check("complessa", RouteHeuristics.isComplex("rispondi a Marco che arrivo alle cinque"))
        check("semplice", !RouteHeuristics.isComplex("modifica la domanda"))
        check("pensaci bene", RouteHeuristics.wantsDeepThinking("Pensaci bene e riordina le slide"))
        check("risposta vuota: sì", AgentTools.isEmptyAnswer("Sì."))
        check("risposta piena", !AgentTools.isEmptyAnswer("Che cos'è Internet?"))
        let log = ConversationLog()
        log.add(request: "modifica la domanda", outcome: "fatto", app: "Edge", changes: ["«A» → «B»"])
        check("blocco recent", log.promptBlock.contains("«modifica la domanda»") && log.promptBlock.contains("«A» → «B»"))
        for i in 0..<7 { log.add(request: "r\(i)", outcome: "ok", app: "X") }
        check("memoria max 5", log.entries.count == 5)

        print("Corsia locale:")
        check("Command+T", LocalActionValidator.canonicalCombo("Command+T") == "cmd+t")
        check("⌘⇧T", LocalActionValidator.canonicalCombo("⌘⇧T") == "cmd+shift+t")
        check("cmd++", LocalActionValidator.canonicalCombo("cmd++") == "cmd+=")
        check("control+command+f", LocalActionValidator.canonicalCombo("control+command+f") == "ctrl+cmd+f")
        let v = LocalActionValidator { $0.lowercased() == "spotify" ? "Spotify" : nil }
        check("tasti consentiti", v.validate(LocalProposal(kind: "tasti", value: "cmd+t"), sentence: "apri nuova tab") == .keys(combo: "cmd+t", label: "Nuova scheda"))
        check("tasto inventato respinto", v.validate(LocalProposal(kind: "tasti", value: "ingrandisci"), sentence: "ingrandisci il testo") == nil)
        check("[ da solo respinto", v.validate(LocalProposal(kind: "tasti", value: "["), sentence: "torna indietro") == nil)
        check("cmd+q respinto", v.validate(LocalProposal(kind: "tasti", value: "cmd+q"), sentence: "esci") == nil)
        check("youtube come sito", v.validate(LocalProposal(kind: "apri_app", value: "youtube"), sentence: "vai su youtube") == .openURL("youtube.com"))
        check("prima mail ≠ Mail", v.validate(LocalProposal(kind: "apri_app", value: "Mail"), sentence: "apri la prima mail") == nil)
        check("ricerca ≠ apri sito", v.validate(LocalProposal(kind: "apri_sito", value: "youtube"), sentence: "cerca su youtube una ninna nanna") == nil)
        check("apri Spotify", v.validate(LocalProposal(kind: "apri_app", value: "Spotify"), sentence: "aprimi Spotify") == .openApp("Spotify"))

        print("Limite della subscription:")
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Europe/Rome")!
        let base = cal.date(from: DateComponents(year: 2026, month: 10, day: 26, hour: 18, minute: 25))!
        let reset = AgentRunner.resetDate(from: "Claude: You've hit your session limit · resets 7pm (Europe/Rome)", now: base)
        check("resets 7pm → 19:00", reset.map { cal.component(.hour, from: $0) == 19 && cal.component(.day, from: $0) == 26 } ?? false)
        let reset2 = AgentRunner.resetDate(from: "limit · resets 1:30am (Europe/Rome)", now: base)
        check("resets 1:30am → domani", reset2.map { cal.component(.hour, from: $0) == 1 && cal.component(.minute, from: $0) == 30 && cal.component(.day, from: $0) == 27 } ?? false)
        check("messaggio di limite", AgentRunner.isLimitMessage("You've hit your session limit · resets 7pm"))
        check("errore normale ≠ limite", !AgentRunner.isLimitMessage("Claude non ha risposto in tempo"))
        check("senza ora → nil", AgentRunner.resetDate(from: "limit reached", now: base) == nil)

        print("Motori (Epic 4):")
        let now = Date()
        let later = now.addingTimeInterval(3600)
        typealias S = EngineSelector
        let all: [EngineID: AgentAvailability] = [.claude: .available, .codex: .available, .local: .available]
        check("scelto disponibile", S.select(chosen: .codex, engines: all, fallback: true) == EngineChoice(engine: .codex, isFallback: false, reason: "scelto"))
        let codexPaused: [EngineID: AgentAvailability] = [.claude: .available, .codex: .paused(until: later), .local: .available]
        check("Codex in pausa → Claude", S.select(chosen: .codex, engines: codexPaused, fallback: true)?.engine == .claude)
        check("riserva segnata", S.select(chosen: .codex, engines: codexPaused, fallback: true)?.isFallback == true)
        check("senza riserva → nessuno", S.select(chosen: .codex, engines: codexPaused, fallback: false) == nil)
        let cloudsDown: [EngineID: AgentAvailability] = [.claude: .missing, .codex: .loginNeeded, .local: .available]
        check("Claude e Codex giù → locale", S.select(chosen: .claude, engines: cloudsDown, fallback: true)?.engine == .local)
        check("messaggio passaggio al locale",
              S.fallbackMessage(chosen: .claude, using: .local, engines: cloudsDown) == "Claude e Codex non disponibili · passo al modello locale")
        check("messaggio Codex → Claude", S.fallbackMessage(chosen: .codex, using: .claude, engines: codexPaused).hasPrefix("Codex in pausa fino alle "))
        let nothing: [EngineID: AgentAvailability] = [.claude: .paused(until: later), .codex: .missing, .local: .unavailable("modello Apple spento")]
        check("nessun motore → ridotta", S.select(chosen: .claude, engines: nothing, fallback: true) == nil)
        check("locale scelto resta locale", S.select(chosen: .local, engines: [.claude: .available, .codex: .available, .local: .unavailable("x")], fallback: true) == nil)
        check("esclusi dopo un errore", S.select(chosen: .claude, engines: all, fallback: true, excluding: [.claude])?.engine == .codex)
        for chosen in EngineID.allCases {
            for fb in [true, false] {
                for a in [AgentAvailability.available, .paused(until: later), .missing, .loginNeeded, .unavailable("x")] {
                    var states = all
                    states[chosen] = a
                    let pick = S.select(chosen: chosen, engines: states, fallback: fb)
                    let expected: EngineID? = a == .available ? chosen : (fb ? chosen.chain.dropFirst().first { states[$0] == .available } : nil)
                    if pick?.engine != expected { check("selettore \(chosen) \(a) riserva=\(fb)", false) }
                }
            }
        }
        check("selettore: tutte le combinazioni", true)

        print("Messaggi di limite (Claude e Codex):")
        let rome = cal
        let b2 = rome.date(from: DateComponents(year: 2026, month: 10, day: 27, hour: 14, minute: 0))!
        if let lines = try? String(contentsOfFile: "Tests/fixtures/codex/limit-messages.txt", encoding: .utf8) {
            for line in lines.split(separator: "\n") where !line.hasPrefix("#") {
                let parts = line.split(separator: "\t").map(String.init)
                guard parts.count == 2 else { continue }
                let (msg, want) = (parts[0], parts[1])
                let got = LimitMessage.resetDate(from: msg, now: b2, calendar: rome)
                let ok: Bool
                if want == "30m" {
                    ok = got == nil && LimitMessage.isLimit(msg)
                } else if want.hasPrefix("+") {
                    ok = got.map { Int($0.timeIntervalSince(b2) / 60) == Int(want.dropFirst()) } ?? false
                } else if want.count == 5 {
                    let hm = want.split(separator: ":").compactMap { Int($0) }
                    ok = got.map { rome.component(.hour, from: $0) == hm[0] && rome.component(.minute, from: $0) == hm[1] && $0 > b2 } ?? false
                } else {
                    let f = DateFormatter()
                    f.timeZone = rome.timeZone
                    f.dateFormat = "yyyy-MM-dd HH:mm"
                    ok = got.map { f.string(from: $0) == want } ?? false
                }
                check("limite: \(msg.suffix(38)) → \(want)", ok && LimitMessage.isLimit(msg))
            }
        } else {
            print("  (fixture dei limiti non trovate: esegui dalla cartella del progetto)")
        }

        print("Codex (JSONL):")
        func parse(_ file: String) -> CodexCLI.Outcome? {
            guard let text = try? String(contentsOfFile: "Tests/fixtures/codex/\(file)", encoding: .utf8) else { return nil }
            var p = CodexEventParser()
            for line in text.split(separator: "\n") { if let o = p.feed(String(line)) { return o } }
            return p.finish()
        }
        check("risposta finale", parse("success.jsonl") == .answer("In primo piano c’è Note."))
        if case .failed(let m) = parse("unauthorized.jsonl") { check("401 → accesso da fare", CodexEventParser.isLogin(m)) } else { check("401 → accesso da fare", false) }
        if case .failed(let m) = parse("limit-at-time.jsonl") { check("limite letto subito", LimitMessage.isLimit(m)) } else { check("limite letto subito", false) }
        let cfg = CodexCLI.Config(model: "gpt-6-luna", effort: "low", instructionsFile: "/tmp/i.md", mcpURL: "http://127.0.0.1:1/mcp", mcpToken: "SEGRETO")
        let args = CodexCLI.arguments(cfg)
        check("token mai negli argomenti", !args.joined(separator: " ").contains("SEGRETO"))
        check("niente configurazione dell'utente", args.contains("--ignore-user-config") && args.contains("--ephemeral"))
        check("shell e computer use spenti", ["shell_tool", "unified_exec", "computer_use", "browser_use"].allSatisfy { f in
            args.indices.contains { args[$0] == "--disable" && $0 + 1 < args.count && args[$0 + 1] == f } })
        check("strumenti approvati senza chiedere", args.contains("mcp_servers.mactalk.default_tools_approval_mode=\"approve\""))
        check("shim di altre app saltati", CodexCLI.isShim("/Users/x/.cmuxterm/cmux-cli-shims/A/codex") && !CodexCLI.isShim("/Users/x/.local/bin/codex"))

        print("Motore locale:")
        let stepSchema = (try? ServerModelExecutor.jsonSchema(LocalStep.generationSchema)) ?? [:]
        let schemaText = (try? JSONSerialization.data(withJSONObject: stepSchema, options: [.sortedKeys])).flatMap { String(data: $0, encoding: .utf8) } ?? ""
        if ProcessInfo.processInfo.environment["MTA_DEBUG"] != nil { print(schemaText) }
        check("schema del passo in JSON Schema", schemaText.contains("\"properties\"") && schemaText.contains("clicca_tutti"))
        let toolSchema = try? LocalTool.schema(name: "click", from: (AgentTools.definitions.first { $0["name"] as? String == "click" }?["inputSchema"] as? [String: Any]) ?? [:])
        check("schema degli strumenti", toolSchema != nil)
        let parsedObs = LocalStepAgent.parse("APP: Safari (com.apple.Safari)\nWINDOW: Banco sito size 1440x869\n[3]* link «Prezzi» @10,20 50x16\n[4] checkbox «Anna 18:30» (checked) @1,2 3x4\n(list truncated: …)")
        check("elenco compatto", parsedObs.elements.map(\.line) == ["[3] link «Prezzi»", "[4] checkbox «Anna 18:30» (checked)"] && parsedObs.truncated)
        check("ruolo degli elementi cliccabili", parsedObs.elements.first?.role == "link" && parsedObs.elements.last?.role == "checkbox")
        check("parole chiave", LocalStepAgent.keywords("apri l'articolo 137") == ["articolo", "137"])
        check("solo server locali senza conferma", OpenAICompatibleModel.isLocal(baseURL: "http://127.0.0.1:11434/v1")
              && !OpenAICompatibleModel.isAllowed(baseURL: "http://192.168.1.5:11434/v1", allowRemote: false))
        check("JSON dentro il testo", ServerModelExecutor.jsonPart(of: "<think>…</think> ecco {\"a\":1} fine") == "{\"a\":1}")

        print("Impostazioni:")
        typealias Df = AppSettings.Defaults
        check("predefiniti = comportamento di prima",
              Df.vadEndSilence == 0.8 && Df.vadMinStartRMS == 0.006 && Df.vadNoiseFactor == 4 && Df.vadMaxSegment == 60
              && Df.dictationEndSilence == 1.6 && Df.dictationIdleSeconds == 4 && Df.sessionIdleSeconds == 60
              && Df.armedSeconds == 8 && Df.proposalSeconds == 8 && Df.agentQuestionSeconds == 25 && Df.confirmationSeconds == 20
              && Df.conversationMemoryCount == 5 && Df.conversationMemoryMinutes == 10 && Df.classifierTimeout == 1.5
              && Df.localLaneMaxWords == 6 && Df.deepEffort == "medium" && Df.fastEffort == "low" && Df.agentMaxSteps == 60
              && Df.agentMaxTurns == 40 && Df.agentTimeout == 240 && Df.confirmValiditySeconds == 45 && Df.speechVolume == 0.45
              && Df.speechRate == 1.05 && Df.soundsVolume == 0.2 && Df.hudSuccessSeconds == 1.3 && Df.hudAnswerSeconds == 5
              && Df.hudErrorSeconds == 4 && Df.numbersTimeout == 30 && Df.numbersLimit == 180)
        let st = AppSettings.shared
        let saved = (st.armedSeconds, st.vadEndSilence)
        st.armedSeconds = 17
        st.vadEndSilence = 1.2
        st.reset(.conversation)
        check("ripristino solo della sezione", st.armedSeconds == Df.armedSeconds && st.vadEndSilence == 1.2)
        st.armedSeconds = saved.0
        st.vadEndSilence = saved.1
        let audio = AudioRouter()
        audio.configure(minStartRMS: 0.01, noiseFactor: 6, endSilence: 1.1, maxSegment: 30)
        check("rilevatore di voce riconfigurato", audio.config.endSilence == 1.1 && audio.config.minStartRMS == 0.01
              && audio.config.noiseFactor == 6 && audio.config.maxSegment == 30)
        check("parola predefinita = elenco di prima",
              AppSettings.wakePhrases(word: Df.wakeWord, variants: true, extra: "")
                == Df.legacyWakePhrases.split(separator: ",").map { Grammar.normalize(String($0)) })
        let jarvis = AppSettings.wakePhrases(word: "Jarvis", variants: true, extra: "ehi mac, Jarvis")
        check("parola scelta + varianti + altre", jarvis == ["jarvis", "ok jarvis", "ehi jarvis", "hey jarvis", "i jarvis", "e jarvis", "ehi mac"])
        check("senza varianti", AppSettings.wakePhrases(word: "Jarvis", variants: false, extra: "") == ["jarvis"])
        check("Jarvis, apri Safari", WakeWord.extract("Jarvis, apri Safari.", phrases: jarvis) == "apri Safari")
        check("computer non attiva più", WakeWord.extract("Computer, apri Safari", phrases: jarvis) == nil)
        check("avviso parola vuota", AppSettings.wakeWordWarning("  ") != nil)
        check("avviso parola corta", AppSettings.wakeWordWarning("Bo") != nil)
        check("avviso parola comune", AppSettings.wakeWordWarning("Amore") != nil)
        check("nessun avviso per Jarvis", AppSettings.wakeWordWarning("Jarvis") == nil)
        check("tutte le sezioni hanno titolo e icona", SettingsSection.allCases.allSatisfy { !$0.title.isEmpty && !$0.icon.isEmpty })

        print("Privacy:")
        check("email mascherata nel log", Privacy.redact("scrivi a mario.rossi@gmail.com che arrivo") == "scrivi a [email] che arrivo")
        check("cellulare mascherato", Privacy.redact("chiama il 347 123 4567") == "chiama il [telefono]")
        check("telefono con prefisso", Privacy.redact("numero +39 02 1234 5678") == "numero [telefono]")
        check("IBAN mascherato", Privacy.redact("IBAN IT60 X054 2811 1010 0000 0123 456 grazie") == "IBAN [IBAN] grazie")
        check("carta (Luhn) mascherata", Privacy.redact("carta 4111 1111 1111 1111 scade") == "carta [carta] scade")
        check("numero lungo non carta resta", Privacy.redact("ordine 1234567890123") == "ordine 1234567890123")
        check("codice fiscale", Privacy.redact("il mio CF è RSSMRA85T10A562S") == "il mio CF è [codice fiscale]")
        check("password", Privacy.redact("la password è gattino") == "la password è [segreto]")
        check("PIN numerico", Privacy.redact("il pin: 4821") == "il pin: [segreto]")
        check("codice di verifica", Privacy.redact("codice di verifica 482913") == "codice di verifica [segreto]")
        check("orari e date restano", Privacy.redact("alle 17:40 del 27.10.2026, 320 ms") == "alle 17:40 del 27.10.2026, 320 ms")
        check("cloud: email resta", Privacy.redact("scrivi a mario@x.it", forCloud: true) == "scrivi a mario@x.it")
        check("cloud: telefono resta", Privacy.redact("chiama il 347 123 4567", forCloud: true) == "chiama il 347 123 4567")
        check("cloud: «Password dimenticata?» resta", Privacy.redact("[3]* link «Password dimenticata?»", forCloud: true) == "[3]* link «Password dimenticata?»")
        check("cloud: carta nascosta", Privacy.redact("«4111 1111 1111 1111»", forCloud: true) == "«[carta]»")
        check("memoria: rifiuta password", Privacy.containsSensitive("la password del wifi è Gatto2024"))
        check("memoria: rifiuta IBAN", Privacy.containsSensitive("IBAN di Marco IT60X0542811101000000123456"))
        check("memoria: accetta profilo", !Privacy.containsSensitive("«profilo aula IB» = Microsoft Edge, profilo «Aulab»"))
        check("app riservata per id", Privacy.isReservedApp(name: "1Password", bundleID: "com.1password.1password", list: Privacy.defaultReservedApps))
        check("app riservata per nome", Privacy.isReservedApp(name: "Banca Mia", bundleID: "x.y", list: "# commento\nbanca mia"))
        check("Safari non riservata", !Privacy.isReservedApp(name: "Safari", bundleID: "com.apple.Safari", list: Privacy.defaultReservedApps))
        check("sito: sottodominio", Privacy.reservedSite(host: "www.paypal.com", title: "", list: Privacy.defaultReservedSites) == "paypal.com")
        check("sito: dominio diverso", Privacy.reservedSite(host: "paypal.com.truffa.ru", title: "", list: "paypal.com") == nil)
        check("sito: parola nell'indirizzo", Privacy.reservedSite(host: "online.miabanca.it", title: "", list: "banca") == "banca")
        check("sito: dal titolo", Privacy.reservedSite(host: nil, title: "Intesa Sanpaolo – Home", list: Privacy.defaultReservedSites) == "intesasanpaolo.com")
        check("sito: titolo qualsiasi", Privacy.reservedSite(host: nil, title: "YouTube", list: Privacy.defaultReservedSites) == nil)
        check("«modalità privata»", Phrases.privateMode("Modalità privata.") == true)
        check("«esci dalla modalità privata»", Phrases.privateMode("esci dalla modalità privata") == false)
        check("frase qualsiasi non è privata", Phrases.privateMode("apri la mail") == nil)
        let day = DateFormatter()
        day.dateFormat = "yyyy-MM-dd"
        let logNow = day.date(from: "2026-10-27")!.addingTimeInterval(3600 * 10)
        let names = ["MacTalkAct.log", "MacTalkAct-2026-10-27.log", "MacTalkAct-2026-10-21.log", "MacTalkAct-2026-10-20.log",
                     "MacTalkAct-2026-10-19-101010.log", "MacTalkAct-bench-2026-10-01-0101-local.tsv", "Altro-2026-01-01.log"]
        check("log: tiene 7 giorni, tocca solo i suoi file",
              Set(Log.archivesToDelete(names, now: logNow, days: 7)) == ["MacTalkAct-2026-10-20.log", "MacTalkAct-2026-10-19-101010.log"])
        check("log: 1 giorno = solo oggi",
              Log.archivesToDelete(["MacTalkAct-2026-10-26.log", "MacTalkAct-2026-10-27.log"], now: logNow, days: 1) == ["MacTalkAct-2026-10-26.log"])

        print(failures == 0 ? "Tutto ok." : "\(failures) test falliti.")
        return failures == 0
    }

    /// `--transcribe <file>`: runs the Italian on-device recogniser on an audio file.
    static func transcribe(_ path: String) async {
        do {
            let locale = try await SpeechEngine.italianLocale()
            try await SpeechEngine.ensureModel(locale: locale) { print("Scarico il modello italiano…") }
            let transcriber = SpeechEngine.makeTranscriber(locale: locale)
            let collector = Task { () -> [String] in
                var out: [String] = []
                for try await r in transcriber.results where r.isFinal {
                    out.append(String(r.text.characters))
                }
                return out
            }
            let file = try AVAudioFile(forReading: URL(fileURLWithPath: path))
            let started = Date()
            // MTA_VOCAB="output,wincleaner": the contextual strings of the live recognizer, to compare.
            let context = AnalysisContext()
            if let v = ProcessInfo.processInfo.environment["MTA_VOCAB"] {
                context.contextualStrings[.general] = v == "base" ? SpeechVocabulary.base : v.split(separator: ",").map(String.init)
            }
            let analyzer = ProcessInfo.processInfo.environment["MTA_VOCAB"] == nil
                ? try await SpeechAnalyzer(inputAudioFile: file, modules: [transcriber], finishAfterFile: true)
                : try await SpeechAnalyzer(inputAudioFile: file, modules: [transcriber], analysisContext: context, finishAfterFile: true)
            _ = analyzer
            let parts = try await collector.value
            let text = parts.joined(separator: " ")
            print("Trascrizione (\(String(format: "%.2f", Date().timeIntervalSince(started)))s): \(text)")
            print("Comando rapido: \(Grammar.parse(text).map { "\($0)" } ?? "nessuno (dettatura o Claude)")")
        } catch {
            print("Errore: \(error.localizedDescription)")
        }
    }

    /// `--plan "<frase>"`: asks Claude for a plan against the current frontmost window.
    static func plan(_ utterance: String) async {
        let settings = AppSettings.shared
        guard settings.aiAvailable else {
            print("Claude non configurato (comando «claude» o chiave API).")
            return
        }
        let ctx = ScreenContext.capture(includeLabels: true)
        print(ctx.promptDescription.prefix(1500))
        do {
            let planner = LLMPlanner()
            if settings.backend == .subscription {
                // Measure like the app does: the process is already warm when the request arrives.
                planner.prewarm(model: settings.model)
                try await Task.sleep(for: .seconds(4))
            }
            let started = Date()
            let plan = try await planner.plan(utterance: utterance, context: ctx, model: settings.model,
                                              backend: settings.backend, apiKey: settings.apiKey)
            let data = try JSONEncoder().encode(plan)
            print("Piano (\(String(format: "%.2f", Date().timeIntervalSince(started)))s): \(String(data: data, encoding: .utf8) ?? "")")
        } catch {
            print("Errore: \(error.localizedDescription)")
        }
    }
}

extension DebugCLI {
    /// `--stream-test <file>`: feeds a file into an analyzer through a stream that stays open
    /// (like the microphone in continuous mode) and checks how finalize behaves.
    /// `--vad-test file`: the voice detector of the app over an audio file, chunk by chunk like the
    /// microphone tap: when sentences open and close, and how much of them was crying.
    static func vadTest(_ path: String) {
        do {
            let file = try AVAudioFile(forReading: URL(fileURLWithPath: path))
            let format = file.processingFormat
            let router = AudioRouter()
            var t: Double = 0
            var opened: Double = 0
            var cryChunks = 0, chunks = 0
            router.onSegmentStart = { _, _ in opened = t; print(String(format: "%6.2fs  apre", t)) }
            router.onSegmentEnd = { _ in print(String(format: "%6.2fs  chiude (frase di %.1fs)", t, t - opened)) }
            router.setVAD(true)
            let size: AVAudioFrameCount = 1024
            while file.framePosition < file.length {
                guard let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: size) else { break }
                try file.read(into: buf, frameCount: size)
                let n = Int(buf.frameLength)
                guard n > 0, let ch = buf.floatChannelData?[0] else { break }
                var sum: Float = 0
                for i in 0..<n { sum += ch[i] * ch[i] }
                let rms = (sum / Float(n)).squareRoot()
                let p = Pitch.dominant(ch, count: n, sampleRate: format.sampleRate)
                let cry = rms > 0.004 && Pitch.isCry(p) && ProcessInfo.processInfo.environment["MTA_NOCRY"] == nil
                chunks += 1
                if cry { cryChunks += 1 }
                router.process([], rms: rms, duration: Double(n) / format.sampleRate, cry: cry)
                t += Double(n) / format.sampleRate
            }
            router.closeAny()
            print(String(format: "Durata %.1fs · pezzi riconosciuti come pianto: %d%%", t, cryChunks * 100 / max(1, chunks)))
        } catch {
            print("Errore: \(error.localizedDescription)")
        }
    }

    static func streamTest(_ path: String) async {
        do {
            let t0 = Date()
            func ts() -> String { String(format: "%5.2fs", Date().timeIntervalSince(t0)) }
            let locale = try await SpeechEngine.italianLocale()
            let transcriber = SpeechEngine.makeTranscriber(locale: locale)
            guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else { return }
            let analyzer = SpeechAnalyzer(modules: [transcriber])
            let (stream, cont) = AsyncStream<AnalyzerInput>.makeStream()
            Task {
                for try await r in transcriber.results {
                    print("\(ts()) \(r.isFinal ? "FINAL" : "volat") \(String(r.text.characters))")
                }
                print("\(ts()) results ended")
            }
            let file = try AVAudioFile(forReading: URL(fileURLWithPath: path))
            let buf = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length))!
            try file.read(into: buf)
            let conv = AnalyzerInputConverter(analyzerFormat: format)
            // MTA_VOCAB="base" or "a,b,c": the contextual strings the app passes to the live recognizer.
            if let v = ProcessInfo.processInfo.environment["MTA_VOCAB"] {
                let context = AnalysisContext()
                context.contextualStrings[.general] = v.split(separator: ",").flatMap { $0 == "base" ? SpeechVocabulary.base : [String($0)] }
                try await analyzer.setContext(context)
            }
            try await analyzer.prepareToAnalyze(in: format)
            try await analyzer.start(inputSequence: stream)
            for input in try conv.convert(buf, at: nil) { cont.yield(input) }
            for input in try conv.flush() { cont.yield(input) }
            print("\(ts()) audio fed, stream still open")
            try await Task.sleep(for: .seconds(2))
            print("\(ts()) calling finalize(through: nil)…")
            let done = Box(false)
            Task { try? await analyzer.finalize(through: nil); done.value = true; print("\(ts()) finalize(nil) returned") }
            try await Task.sleep(for: .seconds(4))
            print("\(ts()) finalize(nil) returned within 4s: \(done.value)")
            cont.finish()
            try? await analyzer.finalizeAndFinishThroughEndOfInput()
            try await Task.sleep(for: .seconds(1))
        } catch {
            print("Errore: \(error)")
        }
    }
}

extension DebugCLI {
    /// `--mic-test <seconds>`: prints raw recogniser events from the real microphone.
    static func micTest(_ seconds: Double) async {
        let t0 = Date()
        let engine = SpeechEngine()
        engine.onUtterance = { text in
            print(String(format: "%5.2fs ", Date().timeIntervalSince(t0)) + "FRASE «\(text)»")
        }
        do {
            try await engine.prepare()
            try await engine.startAudio(vad: true)
            print("In ascolto per \(Int(seconds)) s…")
            try await Task.sleep(for: .seconds(seconds))
            await engine.stopAudio()
        } catch {
            print("Errore: \(error.localizedDescription)")
        }
    }
}

extension DebugCLI {
    /// `--route-test [file] [--rules]`: runs the router on the corpus, without microphone or screen.
    /// Exits with an error if a command or chatter would be typed (FR-6, NFR-4).
    static func routeTest(path: String, rulesOnly: Bool) async -> Bool {
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else {
            print("Non trovo il corpus: \(path)")
            return false
        }
        let onDevice = !rulesOnly && OnDeviceClassifier.isAvailable
        let classifier: IntentClassifier = onDevice ? OnDeviceClassifier(timeout: .seconds(5)) : RuleClassifier()
        let proposer = onDevice ? LocalActionProposer(timeout: .seconds(5)) : nil
        let apps = ["Spotify", "Mail", "Safari", "Calendario", "Note", "Microsoft Edge", "Finder", "Calcolatrice", "Musica"]
        let validator = LocalActionValidator { spoken in
            let q = Grammar.normalize(spoken).replacingOccurrences(of: "il ", with: "").replacingOccurrences(of: "la ", with: "")
            return apps.first { Executor.appMatchScore(query: q, name: $0) >= 75 }
        }
        let router = IntentRouter(classifier: classifier, proposer: proposer, validator: validator)
        router.macroLookup = { _ in nil }
        classifier.prewarm()
        proposer?.prewarm()
        try? await Task.sleep(for: .seconds(1))
        print("Classificatore: \(classifier.name)\(proposer == nil ? "" : " + corsia locale")")

        var total = 0, correct = 0, critical = 0
        var times: [Double] = []
        var errorsByKind: [String: Int] = [:]
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) where !line.hasPrefix("#") {
            let f = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            guard f.count >= 4 else { continue }
            let sentence = f[0], editable = f[1] == "si", stateName = f[2]
            var expected = Set(f[3].split(separator: "|").map(String.init))
            var state = RouterState()
            state.wakePhrases = ["computer", "ok computer", "ehi computer", "hey computer", "i computer", "e computer"]
            switch stateName {
            case "armato": state.armed = true
            case "finestra": state.windowOpen = true
            case "seguito":
                // The window right after an answer of the agent: follow-up questions refer to it.
                state.windowOpen = true
                state.lastExchange = "«Cosa vedo in questa cartella?» → Nella cartella ci sono: _bmad, build, README.md, Sources e Tests."
            case "ptt": state.listening = .pushToTalk; state.pushToTalk = true
            case "sessione": state.listening = .session
            case "proposta": state.proposedText = "testo proposto"; state.windowOpen = true
            case "conferma": state.pendingConfirmation = true
            case "numeri": state.numbersVisible = true
            case "pausa": state.agentAvailability = .paused(until: Date().addingTimeInterval(3600))
            default: break
            }
            if !onDevice {
                // Without the model the router is prudent: asking is fine wherever it would type or call the agent.
                if !expected.isDisjoint(with: ["scrivi", "agente", "locale"]) { expected.insert("chiedi") }
                if expected.contains("locale") { expected.insert("agente") }
            }
            let started = Date()
            let d = await router.decide(sentence, editable: { editable }, state: state)
            let ms = Date().timeIntervalSince(started) * 1000
            times.append(ms)
            total += 1
            let ok = expected.contains(d.label)
            if ok { correct += 1 } else { errorsByKind["\(f[3]) → \(d.label)", default: 0] += 1 }
            let isCritical = d.label == "scrivi" && !expected.contains("scrivi")
            if isCritical { critical += 1 }
            let mark = ok ? "✓" : (isCritical ? "‼︎" : "✗")
            print(String(format: "%@ %5.0f ms  %-22@ %@  [%@, %@]", mark, ms, d.label as NSString, sentence, editable ? "campo" : "-", stateName))
            if !ok { print("        atteso \(f[3]) · motivo: \(d.reason)") }
        }
        let sorted = times.sorted()
        let p90 = sorted.isEmpty ? 0 : sorted[min(sorted.count - 1, Int(Double(sorted.count) * 0.9))]
        let accuracy = total == 0 ? 0 : Double(correct) / Double(total) * 100
        print(String(format: "\nAccuratezza: %d/%d (%.1f%%) · scritture indebite: %d · 90° percentile: %.0f ms", correct, total, accuracy, critical, p90))
        for (k, n) in errorsByKind.sorted(by: { $0.value > $1.value }) { print("  \(n)× \(k)") }
        if critical > 0 { print("FALLITO: almeno una frase sarebbe stata scritta per errore.") }
        return critical == 0
    }
}

extension DebugCLI {
    /// `--tools-test <page.html>`: tries click_many, stale ids and replace_text on a local test page
    /// opened in Safari (no Claude involved). It acts on the screen: run it only when the Mac is idle.
    static func toolsTest(page: String) async {
        let previous = AX.frontmostApplication()
        let ex = Executor()
        let url = URL(fileURLWithPath: page)
        guard let safari = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Safari") else { print("Safari assente"); return }
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        _ = try? await NSWorkspace.shared.open([url], withApplicationAt: safari, configuration: config)
        try? await Task.sleep(for: .seconds(2.5))
        if let app = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.Safari").first {
            await ex.bringToFront(app)
        }
        AX.debugTargetBundle = "com.apple.Safari"
        let tools = AgentTools(executor: ex)
        tools.reset() // the task's app is Safari: actions stop if another app takes the front
        func text(_ r: AgentTools.Result) -> String { (r.content.first?["text"] as? String) ?? "" }
        func ids(_ observed: String, containing: String) -> [Int] {
            observed.split(separator: "\n").filter { $0.contains(containing) }.compactMap { line in
                line.split(separator: "]").first.flatMap { Int($0.dropFirst()) }
            }
        }

        // 1. click_many on the 18:30 boxes of the rows whose 21:30 is checked (Anna, Carla, Dario).
        let o1 = text(await tools.call("observe", ["query": "18:30"]))
        if ProcessInfo.processInfo.environment["MTA_DEBUG"] != nil {
            print(o1)
            print(text(await tools.call("observe", [:])).split(separator: "\n").prefix(40).joined(separator: "\n"))
        }
        let wanted = ["Anna", "Carla", "Dario"].flatMap { ids(o1, containing: "\($0) 18:30") }
        print("id trovati per Anna/Carla/Dario 18:30: \(wanted)")
        let many = await tools.call("click_many", ["ids": wanted, "method": "auto"])
        print("click_many →\n\(text(many))")
        print("verifica stati: \(text(many).components(separatedBy: "now checked").count - 1)/\(wanted.count) spuntate")

        // 2. Stale ids are rejected after a new observe.
        _ = await tools.call("observe", ["query": "21:30"])
        let stale = await tools.call("click", ["id": wanted.first ?? -1])
        print("id vecchio rifiutato: \(stale.isError) · \(text(stale).prefix(90))")

        // 3. replace_text in a native textarea.
        let o3 = text(await tools.call("observe", ["query": "Campo nativo"]))
        if let id = ids(o3, containing: "Campo nativo").first {
            _ = await tools.call("click", ["id": id, "method": "mouse"])
            let r = await tools.call("replace_text", ["find": "Che cos'è il cloud computing?", "replace": "Che cos'è Internet?"])
            print("replace_text campo nativo: \(r.isError ? "ERRORE" : "ok") · \(text(r))")
        } else { print("campo nativo non trovato") }

        // 4. replace_text in a contenteditable "cell" (like a web code editor).
        let o4 = text(await tools.call("observe", ["query": "Cella di codice"]))
        if let id = ids(o4, containing: "Cella di codice").first {
            _ = await tools.call("click", ["id": id, "method": "mouse"])
            let r = await tools.call("replace_text", ["find": "Che cos'è il cloud computing?", "replace": "Che cos'è Internet?"])
            print("replace_text cella: \(r.isError ? "ERRORE" : "ok") · \(text(r))")
            let check = await ex.copySelectionOfField()
            print("contenuto cella dopo: \(check.map { $0.replacingOccurrences(of: "\n", with: " ⏎ ") } ?? "?")")
        } else { print("cella non trovata") }

        print("modifiche registrate: \(tools.changes)")
        try? ex.press("cmd+w")
        if let previous { await ex.bringToFront(previous) }
    }
}

extension DebugCLI {
    /// `--converse-test <page.html>`: two real agent requests in a row on the test page (Safari),
    /// with the conversation memory, using the fast model. Acts on the screen and uses the subscription.
    static func converseTest(page: String) async {
        let previous = AX.frontmostApplication()
        let ex = Executor()
        guard let safari = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Safari") else { return }
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        _ = try? await NSWorkspace.shared.open([URL(fileURLWithPath: page)], withApplicationAt: safari, configuration: config)
        try? await Task.sleep(for: .seconds(2.5))
        if let app = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.Safari").first {
            await ex.bringToFront(app)
        }
        AX.debugTargetBundle = "com.apple.Safari"
        let agent = AgentRunner(executor: ex, settings: AppSettings.shared)
        agent.tools.onProgress = { print("  · \($0)") }
        agent.tools.askUser = { q, _ in print("  ? \(q) → (test: nessuna risposta)"); return nil }
        let log = ConversationLog()

        // Put the caret in the native field, as the user would have it.
        let o = (await agent.tools.call("observe", ["query": "Campo nativo"]).content.first?["text"] as? String) ?? ""
        if let line = o.split(separator: "\n").first(where: { $0.contains("Campo nativo") }),
           let id = line.split(separator: "]").first.flatMap({ Int($0.dropFirst()) }) {
            _ = await agent.tools.call("click", ["id": id, "method": "mouse"])
        }
        func fieldText() -> String {
            guard let app = AX.frontmostApplication(), let el = AX.focusedElement(in: AX.app(app.processIdentifier)) else { return "?" }
            return (AX.string(el, kAXValueAttribute) ?? "?").replacingOccurrences(of: "\n", with: " ⏎ ")
        }
        print("campo all'inizio: \(fieldText())")
        do {
            try await agent.start()
            agent.prewarm()
            try await Task.sleep(for: .seconds(5))
            let env = ProcessInfo.processInfo.environment
            let requests = env["MTA_REQUESTS"].map { $0.components(separatedBy: "||") }
                ?? ["modifica la domanda: che cos'è il cloud computing diventa che cos'è Internet", "rimetti la domanda di prima"]
            for request in requests {
                let ctx = ScreenContext.capture(includeLabels: false)
                let started = Date()
                let answer = try await agent.run(request, context: ctx, recent: log.promptBlock, deep: RouteHeuristics.isComplex(request))
                log.add(request: request, outcome: answer, app: ctx.appName, changes: agent.tools.changes)
                print(String(format: "«%@» → %.1fs, %d chiamate: %@", request, Date().timeIntervalSince(started), agent.tools.callCount, answer))
                print("  modifiche: \(agent.tools.changes)")
                print("  campo dopo: \(fieldText())")
            }
        } catch {
            print("Errore: \(error.localizedDescription)")
        }
        agent.shutdown()
        try? ex.press("cmd+w")
        if let previous { await ex.bringToFront(previous) }
    }
}

extension DebugCLI {
    /// `--settings-shot <dir>`: builds the settings window with the app's own factory, off screen,
    /// and saves one PNG per section (no Screen Recording permission needed).
    static func settingsShot(dir: String) async {
        let settings = AppSettings.shared
        let original = settings.lastSettingsSection
        var context = SettingsContext()
        context.agentStatus = { "Disponibile (Sonnet 5.5 / Opus 5.5)" }
        context.routerDescription = { "modello Apple + corsia locale" }
        context.engineStates = { [.claude: .available, .codex: .paused(until: Date().addingTimeInterval(5400)), .local: .available] }
        let window = SettingsWindowFactory.make(settings: settings, context: context)
        window.setFrameOrigin(NSPoint(x: -20_000, y: -20_000))
        window.orderFrontRegardless()
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        for section in SettingsSection.allCases {
            settings.lastSettingsSection = section
            try? await Task.sleep(for: .milliseconds(700))
            guard let view = window.contentView?.superview ?? window.contentView,
                  let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { continue }
            view.cacheDisplay(in: view.bounds, to: rep)
            let url = URL(fileURLWithPath: dir).appendingPathComponent("\(SettingsSection.allCases.firstIndex(of: section)!)-\(section.rawValue).png")
            try? rep.representation(using: .png, properties: [:])?.write(to: url)
            print("\(section.title): \(Int(view.bounds.width))×\(Int(view.bounds.height)) → \(url.lastPathComponent)")
        }
        settings.lastSettingsSection = original
        window.close()
    }
}

/// A pretend engine for `--fallback-test`: optionally "acts" a few times, then fails or answers.
@MainActor
final class FakeEngine: AgentEngine {
    let id: EngineID
    var availability: AgentAvailability = .available
    var onAvailabilityChange: ((AgentAvailability) -> Void)?
    var onPhase: PhaseSink?
    private let tools: AgentTools
    private let effectsBeforeFailure: Int
    private let fails: Bool
    /// Reports phase events and calls one read-only tool, like a real engine (Bench test).
    var phased = false
    private(set) var runs = 0

    init(_ id: EngineID, tools: AgentTools, effectsBeforeFailure: Int = 0, fails: Bool) {
        self.id = id
        self.tools = tools
        self.effectsBeforeFailure = effectsBeforeFailure
        self.fails = fails
    }

    func model(for level: AgentLevel) -> String { "finto-\(id.rawValue)" }
    func refreshAvailability() {}
    func prewarm() {}
    func cancel() {}
    func shutdown() {}

    func run(_ request: AgentRequest) async throws -> String {
        runs += 1
        if phased {
            func pause() async { try? await Task.sleep(for: .milliseconds(40)) }
            await pause(); onPhase?(.sessionStarted)
            await pause(); onPhase?(.serverConnected)
            await pause(); onPhase?(.firstToken)
            await pause(); _ = await tools.call("menu", ["path": ""])
            onPhase?(.firstToken) // late duplicate: must not move the phases back
            await pause(); onPhase?(.turnFinished(turns: 2))
            await pause()
            return "fatto con le fasi"
        }
        for _ in 0..<effectsBeforeFailure { tools.simulateEffect() }
        if fails {
            let until = Date().addingTimeInterval(3600)
            availability = .paused(until: until)
            onAvailabilityChange?(availability)
            throw AgentEngineError.limit(message: "limite simulato", until: until)
        }
        return "fatto da \(id.rawValue)"
    }
}

extension DebugCLI {
    /// `--fallback-test`: a limit before any action moves the request to the next engine;
    /// a limit after an action stops it (FR-28, AD-15). No real engine, nothing on screen.
    static func fallbackTest() async -> Bool {
        var failures = 0
        func check(_ name: String, _ ok: Bool) {
            print(ok ? "  ok   \(name)" : "  FAIL \(name)")
            if !ok { failures += 1 }
        }
        for effects in [0, 1] {
            let agent = AgentRunner(executor: Executor(), settings: AppSettings.shared)
            try? await agent.start()
            let claude = FakeEngine(.claude, tools: agent.tools, effectsBeforeFailure: effects, fails: true)
            let codex = FakeEngine(.codex, tools: agent.tools, fails: false)
            let local = FakeEngine(.local, tools: agent.tools, fails: false)
            agent.register(claude); agent.register(codex); agent.register(local)
            agent.overrideChoice = (.claude, true)
            var switches: [String] = []
            agent.onEngineSwitch = { switches.append($0.message) }
            do {
                let answer = try await agent.run("prova", context: ScreenContext(), deep: false)
                print("  N=\(effects): risposta «\(answer)», passaggi: \(switches)")
                check("N=\(effects): completata dal secondo motore", effects == 0 && answer == "fatto da codex" && codex.runs == 1)
                check("N=\(effects): passaggio annunciato", switches.first?.hasPrefix("Claude in pausa fino alle") == true && switches.first?.hasSuffix("uso Codex") == true)
            } catch {
                print("  N=\(effects): fermata · \(error.localizedDescription)")
                let midway: Bool
                if case AgentRunner.RunError.stoppedMidway(let e, let steps, _, let next) = error {
                    midway = e == .claude && steps == 1 && next == .codex
                } else { midway = false }
                check("N=\(effects): fermata a metà senza ripetere", effects == 1 && midway && codex.runs == 0)
            }
            agent.shutdown()
        }

        print("Fasi attraverso AgentRunner (Storia 7.1):")
        do {
            let agent = AgentRunner(executor: Executor(), settings: AppSettings.shared)
            try? await agent.start()
            let claude = FakeEngine(.claude, tools: agent.tools, fails: false)
            claude.phased = true
            agent.register(claude)
            agent.overrideChoice = (.claude, false)
            _ = try? await agent.run("prova", context: ScreenContext(), deep: false)
            let p = agent.lastPhases
            for phase in [BenchPhase.session, .mcp, .firstToken, .finalTurn, .close] {
                check("fase \(phase.rawValue) > 0", (p[phase] ?? 0) > 0.02)
            }
            check("fase azioni presente", (p[.actions] ?? 0) > 0) // a read-only call can take a millisecond
            check("somma = totale del runner", abs(p.values.reduce(0, +) - agent.lastTotal) < 0.01)
            check("turni dal Motore", agent.lastTurns == 2)
            agent.shutdown()
        }

        print("Sessione lunga con un claude finto (Storia 7.2):")
        do {
            let fake = FileManager.default.currentDirectoryPath + "/Tests/fixtures/claude/finto-claude"
            let cli = ClaudeCLI()
            cli.executablePath = { fake }
            check("versione letta dal finto", cli.status(force: true) == .verified("2.1.311"))
            let base = ClaudeCLI.Config(model: "finto", systemPrompt: "prova", effort: "low")
            var restarts: [String] = []
            var sentWith: [Int?] = []
            func ask(_ text: String, _ config: ClaudeCLI.Config, memory: MemorySnapshot, max: Int = 8, timeout: TimeInterval = 10) async -> Result<String, Error> {
                do {
                    let data = try await cli.runInSession(config, memory: memory, maxRequests: max, timeout: timeout,
                                                          message: { seq in sentWith.append(seq); return seq.map { "dopo \($0): \(text)" } ?? "tutto: \(text)" },
                                                          onPhase: nil, onRestart: { restarts.append($0) })
                    return .success(String(data: data, encoding: .utf8) ?? "")
                } catch { return .failure(error) }
            }
            let m0 = MemorySnapshot(generation: 0, lastSeq: 4)
            let r1 = await ask("uno", base, memory: m0)
            check("prima: sessione nuova, messaggio completo", (try? r1.get()) == "ricevuto: tutto: uno" && sentWith == [nil])
            // The Coordinator adds entry 5 for «uno»; another path adds entry 6.
            let r2 = await ask("due", base, memory: MemorySnapshot(generation: 0, lastSeq: 6))
            check("seconda: sessione riusata, solo la memoria dopo la voce 5", (try? r2.get()) == "ricevuto: dopo 5: due" && cli.lastAttemptReused)
            check("cursore = ultima voce + 1", ClaudeCLI.cursor(after: m0) == 5 && cli.liveCursor(memory: MemorySnapshot(generation: 0, lastSeq: 6)) == 7)
            check("cursore di un'altra generazione: nessuno", cli.liveCursor(memory: MemorySnapshot(generation: 1, lastSeq: 6)) == nil)
            var other = base
            other.effort = "medium"
            _ = await ask("tre", other, memory: MemorySnapshot(generation: 0, lastSeq: 7))
            check("effort cambiato → riavvio", restarts == ["modello o effort cambiati"])
            _ = await ask("quattro", other, memory: MemorySnapshot(generation: 0, lastSeq: 8), max: 1)
            check("tetto di richieste → riavvio", restarts.last == "1 richieste")
            var extra = other
            extra.extraArgs = ["--max-turns", "3"]
            _ = await ask("cinque", extra, memory: MemorySnapshot(generation: 0, lastSeq: 9))
            check("altro argomento → «configurazione cambiata»", restarts.last == "configurazione cambiata")
            let started = Date()
            let slow = await ask("DORMI", extra, memory: MemorySnapshot(generation: 0, lastSeq: 10), timeout: 1)
            var timedOut = false
            if case .failure(ClaudeCLIError.timeout) = slow { timedOut = true }
            check("turno scaduto: errore entro 3 s", timedOut && Date().timeIntervalSince(started) < 3)
            _ = await ask("sei", extra, memory: MemorySnapshot(generation: 0, lastSeq: 11))
            check("dopo la scadenza: sessione nuova", !cli.lastAttemptReused)
            let dead = await ask("MUORI", extra, memory: MemorySnapshot(generation: 0, lastSeq: 12))
            var died = false
            if case .failure(ClaudeCLIError.sessionDied) = dead { died = true }
            check("processo uscito a metà → sessione morta, era riusata", died && cli.lastAttemptReused)
            check("ripete solo una sessione riusata, senza azioni, non annullata",
                  ClaudeEngine.retriesDeadSession(reused: true, effectfulCalls: 0, cancelled: false)
                  && !ClaudeEngine.retriesDeadSession(reused: true, effectfulCalls: 1, cancelled: false)
                  && !ClaudeEngine.retriesDeadSession(reused: false, effectfulCalls: 0, cancelled: false)
                  && !ClaudeEngine.retriesDeadSession(reused: true, effectfulCalls: 0, cancelled: true))
            cli.shutdown()
        }

        print("Conferme e azioni bloccate (Storia 7.1):")
        do {
            let tools = AgentTools(executor: Executor())
            var answer = "no"
            tools.askUser = { _, _ in answer }
            _ = await tools.call("confirm", ["action": "elimina la mail"])
            check("confermata negata: 1 chiesta, 1 bloccata", tools.confirmationsAsked == 1 && tools.blockedCalls == 1)
            answer = "sì"
            _ = await tools.call("confirm", ["action": "elimina la mail"])
            check("confermata approvata: 2 chieste, sempre 1 bloccata", tools.confirmationsAsked == 2 && tools.blockedCalls == 1)
            tools.reset(keepElements: true)
            check("ripetizione su un altro Motore: contatori tenuti", tools.confirmationsAsked == 2 && tools.blockedCalls == 1)
            tools.reset()
            check("richiesta nuova: contatori a zero", tools.confirmationsAsked == 0 && tools.blockedCalls == 0)
        }
        return failures == 0
    }
}

extension DebugCLI {
    /// `--session-test`: two real messages on Claude's Long session (FR-42). It uses the subscription
    /// for two tiny answers, no tools and nothing on screen.
    static func sessionTest() async -> Bool {
        var failures = 0
        func check(_ name: String, _ ok: Bool, _ detail: String = "") {
            print(ok ? "  ok   \(name)" : "  FAIL \(name)\(detail.isEmpty ? "" : " — \(detail)")")
            if !ok { failures += 1 }
        }
        let cli = ClaudeCLI()
        let custom = AppSettings.shared.claudePath
        cli.executablePath = { ClaudeCLI.locate(custom: custom) }
        let status = cli.status()
        print("  claude: \(status)")
        check("versione verificata", status.isVerified)
        // A system prompt above the cache minimum, like the agent's.
        let prompt = "Rispondi con una parola sola, in italiano.\n" + String(repeating: "Regola di prova del Banco di MacTalkAct, da ignorare. ", count: 120)
        let config = ClaudeCLI.Config(model: AppSettings.shared.fastModel, systemPrompt: prompt, effort: "low")
        let phases = Box<[EnginePhase]>([])
        let sink: PhaseSink = { p in DispatchQueue.main.async { phases.value.append(p) } }
        var restarts: [String] = []
        var memory = MemorySnapshot(generation: 0, lastSeq: 0)
        func ask(_ text: String) async -> String? {
            do {
                let data = try await cli.runInSession(config, memory: memory, maxRequests: 8, timeout: 60,
                                                      message: { seq in seq == nil ? text : "(seguito) " + text },
                                                      onPhase: sink, onRestart: { restarts.append($0) })
                return String(data: data, encoding: .utf8)
            } catch { print("  errore: \(error.localizedDescription)"); return nil }
        }
        let a = await ask("Di che colore è il cielo?")
        try? await Task.sleep(for: .milliseconds(100))
        check("prima risposta", a != nil, a ?? "")
        check("prima richiesta: sessione avviata", phases.value.contains(.sessionStarted))
        phases.value = []
        let b = await ask("E l'erba?")
        try? await Task.sleep(for: .milliseconds(100))
        check("seconda risposta", b != nil, b ?? "")
        check("seconda richiesta: sessione riusata", phases.value.contains(.sessionReused) && !phases.value.contains(.sessionStarted))
        check("cache letta > 0", cli.lastCacheRead > 0, "\(cli.lastCacheRead)")
        memory = MemorySnapshot(generation: 1, lastSeq: 0)
        phases.value = []
        _ = await ask("E il mare?")
        try? await Task.sleep(for: .milliseconds(100))
        check("memoria azzerata: riavvio con motivo", restarts == ["memoria azzerata"] && phases.value.contains(.sessionStarted), "\(restarts)")
        cli.shutdown()
        return failures == 0
    }
}

// MARK: - Banco di prova dell'Agente (Story 5.1)

extension DebugCLI {
    struct BenchTask {
        let id, page, level, request: String
        let checks: [BenchCheck]
        var kind: BenchKind { BenchKind(page) }
    }

    static func loadBench(_ path: String) -> [BenchTask] {
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return [] }
        return parseBench(text)
    }

    static func parseBench(_ text: String) -> [BenchTask] {
        text.split(separator: "\n").compactMap { line in
            guard !line.hasPrefix("#") else { return nil }
            let f = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            guard f.count >= 5 else { return nil }
            return BenchTask(id: f[0], page: f[1], level: f[2], request: f[3], checks: BenchCheck.parse(f[4]))
        }
    }

    /// `--hands-test`: the hands of Epic 6 without a model, on the Bench pages (it acts on the screen).
    /// Stable ids, outcome of actions, hover, drag, set_value, select_text, menu, act, zoom.
    static func handsTest() async -> Bool {
        guard let safari = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Safari") else { print("Safari assente"); return false }
        let previous = AX.frontmostApplication()
        let ex = Executor()
        let tools = AgentTools(executor: ex)
        tools.askUser = { _, c in c ? "sì" : nil }
        let base = URL(fileURLWithPath: "Tests/bench/pages")
        var ok = true
        func check(_ name: String, _ pass: Bool, _ detail: String = "") {
            print("  \(pass ? "ok  " : "FAIL") \(name)\(detail.isEmpty ? "" : " — \(detail.prefix(220))")")
            if !pass { ok = false }
        }
        func open(_ page: String) async {
            let config = NSWorkspace.OpenConfiguration()
            config.activates = true
            _ = try? await NSWorkspace.shared.open([base.appendingPathComponent(page)], withApplicationAt: safari, configuration: config)
            try? await Task.sleep(for: .seconds(2))
            if let app = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.Safari").first { await ex.bringToFront(app) }
            try? await Task.sleep(for: .seconds(0.4))
            tools.reset()
        }
        func text(_ r: AgentTools.Result) -> String { r.text }
        func id(_ observed: String, _ containing: String) -> Int? {
            guard let line = observed.split(separator: "\n").first(where: { $0.contains(containing) }),
                  let r = line.range(of: #"\[(\d+)\]"#, options: .regularExpression) else { return nil }
            return Int(line[r].dropFirst().dropLast())
        }
        func title() -> String { ScreenContext.capture(includeLabels: false).windowTitle }

        print("Menu a comparsa (hover) e id stabili:")
        await open("menu.html")
        let o1 = text(await tools.call("observe", [:]))
        let o2 = text(await tools.call("observe", [:]))
        check("stessi id in due observe", id(o1, "«Home»") != nil && id(o1, "«Home»") == id(o2, "«Home»"))
        if let p = id(o1, "Prodotti") {
            let r = text(await tools.call("hover", ["id": p]))
            check("hover mostra le voci nascoste", r.contains("Accessori"), r.components(separatedBy: "\n").prefix(3).joined(separator: " | "))
            if let acc = id(r, "link «Accessori»") {
                let c = text(await tools.call("click", ["id": acc]))
                check("clic con esito: nuovo titolo", c.contains("pagina: Accessori"), c.components(separatedBy: "\n").prefix(2).joined(separator: " | "))
            } else { check("id di Accessori nell'esito", false, r) }
        } else { check("Prodotti visibile", false) }
        let same = text(await tools.call("press_keys", ["keys": "shift"]))
        check("azione senza effetti: nothing changed", same.contains("nothing changed"), same)

        print("Trascinamento:")
        await open("kanban.html")
        let k = text(await tools.call("observe", [:]))
        if let card = id(k, "«Preventivo»"), let col = id(k, "heading «Fatto»") {
            let r = text(await tools.call("drag", ["from_id": card, "to_id": col]))
            check("scheda in Fatto", title().contains("Fatto=Preventivo"), r.components(separatedBy: "\n").prefix(2).joined(separator: " | "))
        } else { check("scheda e colonna trovate", false, k) }

        print("Cursore:")
        await open("cursore.html")
        let c = text(await tools.call("observe", [:]))
        if let s = id(c, "slider «Volume»") {
            let line = c.split(separator: "\n").first { $0.contains("slider «Volume»") } ?? ""
            check("slider con value e settable", line.contains("value=70"), String(line))
            let r = text(await tools.call("set_value", ["id": s, "value": "30"]))
            try? await Task.sleep(for: .seconds(0.7))
            check("set_value 30", title().contains("volume=30"), r.components(separatedBy: "\n").first ?? "")
        } else { check("slider trovato", false, c) }

        print("Modulo in una chiamata e selezione:")
        await open("iscrizione.html")
        let f = text(await tools.call("observe", [:]))
        if let n = id(f, "textfield «Nome»"), let cg = id(f, "textfield «Cognome»"), let note = id(f, "textarea «Note»") {
            let r = await tools.call("act", ["steps": [
                ["tool": "type_text", "id": n, "text": "Luca"],
                ["tool": "type_text", "id": cg, "text": "Verdi"],
                ["tool": "type_text", "id": note, "text": "arrivo alle 9"],
            ]])
            try? await Task.sleep(for: .seconds(0.7))
            check("act compila tre campi", title().contains("nome=Luca") && title().contains("cognome=Verdi") && title().contains("note=arrivo alle 9"), r.text.components(separatedBy: "\n").prefix(4).joined(separator: " | "))
            let sel = text(await tools.call("select_text", ["id": note, "text": "9"]))
            let typed = text(await tools.call("type_text", ["text": "10"]))
            try? await Task.sleep(for: .seconds(0.7))
            check("select_text + type_text", title().contains("note=arrivo alle 10"), sel + " | " + (typed.components(separatedBy: "\n").first ?? ""))
            let bad = await tools.call("act", ["steps": [["tool": "click", "id": 99999], ["tool": "type_text", "text": "x"]]])
            check("act si ferma al primo errore", bad.isError && bad.text.contains("not executed"), bad.text.replacingOccurrences(of: "\n", with: " | "))
        } else { check("campi trovati", false, f) }

        print("Menu dell'app:")
        let m = text(await tools.call("menu", ["path": ""]))
        check("barra dei menu di Safari", m.contains("File") || m.contains("Archivio") || m.contains("Modifica"), m)
        let v = text(await tools.call("menu", ["path": m.contains("View") ? "View" : "Vista"]))
        check("voci del menu Vista con scorciatoie", v.contains("⌘"), v)

        print("Zoom:")
        await open("etichetta.html")
        let shot = await tools.call("screenshot", [:])
        let z = await tools.call("screenshot", ["region": [0, 0, 400, 300]])
        check("screenshot con region", !z.isError && z.content.contains { ($0["type"] as? String) == "image" }, z.text)
        _ = shot

        print("Esc:")
        let esc = EscapeMonitor()
        var stopped = 0
        esc.start { stopped += 1 }
        KeyCombo.lastEscapePosted = .distantPast
        try? ex.press("escape") // the agent's own Esc: marked, ignored
        try? await Task.sleep(for: .milliseconds(600))
        check("Esc dell'agente ignorato", stopped == 0)
        KeyCombo.lastEscapePosted = .distantPast
        let src = CGEventSource(stateID: .hidSystemState) // like a real keyboard: no marker
        CGEvent(keyboardEventSource: src, virtualKey: 53, keyDown: true)?.post(tap: .cghidEventTap)
        CGEvent(keyboardEventSource: src, virtualKey: 53, keyDown: false)?.post(tap: .cghidEventTap)
        try? await Task.sleep(for: .milliseconds(600))
        if stopped == 0 {
            // Global key monitors need Input Monitoring for the process: the terminal may not have it.
            print("  —    Esc dell'utente: non verificabile da riga di comando (permesso Monitoraggio input del terminale)")
        } else {
            check("Esc dell'utente ferma", stopped == 1, "chiamate: \(stopped)")
        }
        esc.stop()

        await closeBenchPages(ex)
        if let previous { await ex.bringToFront(previous) }
        return ok
    }

    /// Closes every Safari tab of the Bench (title «Banco …»), answering Safari's «unsubmitted form»
    /// sheet when it appears: otherwise windows pile up and confuse screenshots and clicks.
    /// Only Bench pages are closed; keys are pressed only while Safari is in front.
    static func closeBenchPages(_ ex: Executor) async {
        guard let safari = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.Safari").first else { return }
        let app = AX.app(safari.processIdentifier)
        func buttons(in el: AXUIElement, depth: Int = 0) -> [AXUIElement] {
            guard depth < 6 else { return [] }
            return AX.children(el).flatMap { c in AX.role(c) == "AXButton" ? [c] : buttons(in: c, depth: depth + 1) }
        }
        for _ in 0..<60 {
            let windows = (AX.value(app, kAXWindowsAttribute) as? [AXUIElement]) ?? []
            guard let w = windows.first(where: { (AX.string($0, kAXTitleAttribute) ?? "").hasPrefix("Banco") }) else { return }
            if let sheet = AX.children(w).first(where: { AX.role($0) == "AXSheet" }) {
                let all = buttons(in: sheet)
                let close = all.first { b in
                    let t = Grammar.normalize(AX.string(b, kAXTitleAttribute) ?? "")
                    return t.contains("chiudi") || t.contains("close") || t.contains("esci") || t.contains("leave")
                } ?? all.first { !Grammar.normalize(AX.string($0, kAXTitleAttribute) ?? "").contains("annulla") }
                if let close { AX.press(close) }
                try? await Task.sleep(for: .milliseconds(400))
                continue
            }
            AXUIElementPerformAction(w, kAXRaiseAction as CFString)
            await ex.bringToFront(safari)
            try? await Task.sleep(for: .milliseconds(250))
            guard AX.frontmostApplication()?.bundleIdentifier == "com.apple.Safari" else { return }
            try? ex.press("cmd+w")
            try? await Task.sleep(for: .milliseconds(450))
        }
    }

    /// `--agent-bench [file] --engine claude|codex|local [--only id,id] [--server URL --model NAME]`:
    /// runs every task with one engine and checks the state it leaves (page, files, events, URL).
    /// Each request is split into phases (FR-41). It acts on the screen: run it only when the Mac is idle.
    static func agentBench(path: String, engine: EngineID, only: Set<String>, server: (url: String, model: String)?,
                           mode: LocalEngine.Mode? = nil) async {
        let tasks = loadBench(path).filter { only.isEmpty || only.contains($0.id) }
        guard !tasks.isEmpty else { print("Nessun compito in \(path)"); return }
        guard let safari = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Safari") else { print("Safari assente"); return }
        let previous = AX.frontmostApplication()
        let ex = Executor()
        let agent = AgentRunner(executor: ex, settings: AppSettings.shared)
        agent.forcedEngine = engine
        if let local = agent.engines[.local] as? LocalEngine, server != nil || mode != nil {
            local.override = LocalEngine.Override(provider: server == nil ? .apple : .server, url: server?.url ?? "",
                                                  model: server?.model ?? "", mode: mode)
        }
        // «sì» on the Bench pages; «no» on real apps and accounts, where a «sì» would really send.
        let sayYes = Box(true)
        // On the personal webmail account only times go out: questions may quote the mail.
        let quiet = Box(false)
        agent.tools.askUser = { q, confirmation in
            let yes = confirmation && sayYes.value
            print("      ? \(quiet.value ? "(domanda nascosta)" : q) → \(confirmation ? (yes ? "sì (banco)" : "no (app vera)") : "nessuna risposta")")
            return confirmation ? (yes ? "sì" : "no") : nil
        }
        do { try await agent.start() } catch { print("Server strumenti: \(error)"); return }
        await closeBenchPages(ex)
        agent.refreshAvailability()
        try? await Task.sleep(for: .seconds(2))
        print("Banco di prova · motore \(engine.rawValue)\(engine == .local ? " (\((mode ?? LocalEngine.defaultMode).rawValue))" : "") · \(tasks.count) compiti · \(agent.availability(of: engine))")

        let validator = LocalActionValidator { spoken in
            ex.findApp(spoken).map { FileManager.default.displayName(atPath: $0.path).replacingOccurrences(of: ".app", with: "") }
        }
        let onDevice = OnDeviceClassifier.isAvailable
        let classifier: IntentClassifier = onDevice ? OnDeviceClassifier(timeout: .milliseconds(Int(AppSettings.shared.classifierTimeout * 1000))) : RuleClassifier()
        let router = IntentRouter(classifier: classifier, proposer: LocalActionProposer.isAvailable ? LocalActionProposer() : nil, validator: validator)
        router.macroLookup = { _ in nil }

        struct Row {
            let task: BenchTask; let ok: Bool; let skipped: String?; let steps: Int; let first: Double?; let total: Double
            let model: String; let note: String; let phases: [BenchPhase: Double]; let turns: Int?; let confirmations: Int; let blocked: Int
            /// Time of the Router's decision (Frasi spurie only): before the agent, outside its phases.
            var router: Double = 0
            var sumOK: Bool { skipped != nil || phases.isEmpty || abs(phases.values.reduce(0, +) + router - total) <= 0.2 }
        }
        var rows: [Row] = []
        let base = URL(fileURLWithPath: path).deletingLastPathComponent().appendingPathComponent("pages")

        func openInSafari(_ url: URL) async {
            let config = NSWorkspace.OpenConfiguration()
            config.activates = true
            _ = try? await NSWorkspace.shared.open([url], withApplicationAt: safari, configuration: config)
            try? await Task.sleep(for: .seconds(2.5))
            if let app = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.Safari").first {
                await ex.bringToFront(app)
            }
            try? await Task.sleep(for: .seconds(0.5))
        }

        for task in tasks {
            let kind = task.kind
            func skip(_ why: String) {
                print("— \(task.id): saltato (\(why))")
                rows.append(Row(task: task, ok: false, skipped: why, steps: 0, first: nil, total: 0, model: "", note: "",
                                phases: [:], turns: nil, confirmations: 0, blocked: 0))
            }
            if case .webmail = kind, BenchFixtures.webmailPersonal, task.level != "osserva" {
                skip("account personale: solo compiti di osservazione"); continue
            }
            if let why = await BenchFixtures.setUp(kind, checks: task.checks) { skip(why); continue }
            sayYes.value = !kind.isReal
            if case .webmail = kind { quiet.value = BenchFixtures.webmailPersonal } else { quiet.value = false }
            switch kind {
            case .page(let page), .phrase(let page):
                await openInSafari(base.appendingPathComponent(page))
            case .webmail(let suffix):
                guard let root = BenchFixtures.webmailURL, let url = URL(string: root + suffix) else {
                    skip("indirizzo della webmail non valido"); continue
                }
                await openInSafari(url)
            case .app:
                break
            }
            let ctx = ScreenContext.capture(includeLabels: false)
            // The agent must never start on whatever real app happens to be in front.
            let pageMissing: Bool
            switch kind {
            case .page, .phrase: pageMissing = !(ctx.bundleID == "com.apple.Safari" && ctx.windowTitle.hasPrefix("Banco"))
            default: pageMissing = ctx.bundleID != BenchFixtures.expectedBundle(kind)
            }
            if pageMissing {
                print("✗ \(task.id): app attesa non in primo piano (\(ctx.appName)\(quiet.value ? "" : " · \(ctx.windowTitle)"))")
                rows.append(Row(task: task, ok: false, skipped: nil, steps: 0, first: nil, total: 0, model: "", note: "pagina non aperta",
                                phases: [:], turns: nil, confirmations: 0, blocked: 0))
                await BenchFixtures.tearDown(kind, checks: task.checks)
                continue
            }
            let started = Date()
            var note = ""
            var ranAgent = true
            var phraseOK = true
            var routerTime = 0.0
            if case .phrase = kind {
                // A misheard sentence goes through the Router like in the app: only an agent decision reaches the agent.
                // Continuous listening with the conversation window open: no wake word is needed, so this
                // is where a misheard sentence can start the agent (FR-48).
                var state = RouterState()
                state.listening = .session
                state.windowOpen = true
                let decision = await router.decide(task.request, editable: { false }, state: state)
                routerTime = Date().timeIntervalSince(started)
                switch decision {
                case .agent(let text, let deep, _):
                    do { note = try await agent.run(text, context: ctx, deep: deep) } catch { note = "errore: \(error.localizedDescription)" }
                case .ignore, .askToType:
                    ranAgent = false
                    note = "router: \(String(describing: decision).prefix(60))"
                default:
                    ranAgent = false
                    phraseOK = false
                    note = "router agisce: \(String(describing: decision).prefix(60))"
                }
            } else {
                do {
                    note = try await agent.run(task.request, context: ctx, deep: task.level == "medio")
                } catch {
                    note = "errore: \(error.localizedDescription)"
                }
            }
            let total = Date().timeIntervalSince(started)
            try? await Task.sleep(for: .seconds(1.2))
            let title = ScreenContext.capture(includeLabels: false).windowTitle
            let ok: Bool
            if case .phrase = kind {
                ok = phraseOK && (!ranAgent || agent.tools.effectfulCalls == 0)
            } else {
                ok = BenchFixtures.passes(task.checks, title: title, url: BenchFixtures.frontURL())
            }
            // Time to the first action: the local engine observes on its own before the model speaks.
            let first = ranAgent ? (agent.tools.firstEffectAt ?? agent.tools.firstCallAt).map { $0.timeIntervalSince(started) } : nil
            // On the personal account only the times go to the table, never what the agent read.
            if case .webmail = kind, BenchFixtures.webmailPersonal { note = "" }
            var row = Row(task: task, ok: ok, skipped: nil, steps: ranAgent ? agent.tools.callCount : 0, first: first, total: total,
                          model: ranAgent ? agent.lastModel : "", note: note, phases: ranAgent ? agent.lastPhases : [:],
                          turns: ranAgent ? agent.lastTurns : nil, confirmations: ranAgent ? agent.tools.confirmationsAsked : 0,
                          blocked: ranAgent ? agent.tools.blockedCalls : 0)
            row.router = routerTime
            rows.append(row)
            print(String(format: "%@ %-18@ %2d passi · primo %@ · %5.1f s · %@", ok ? "✓" : "✗", task.id as NSString, row.steps,
                         first.map { String(format: "%4.1f s", $0) } ?? "  — ", total, String(note.prefix(70))))
            if !row.phases.isEmpty {
                let parts = BenchPhase.allCases.compactMap { p in row.phases[p].map { String(format: "%@ %.1f", p.rawValue, $0) } }
                print("      fasi: \(routerTime > 0 ? String(format: "router %.1f · ", routerTime) : "")\(parts.joined(separator: " · "))\(row.sumOK ? "" : " ⚠︎ somma ≠ totale") · turni \(row.turns.map(String.init) ?? "—") · conferme \(row.confirmations) · bloccate \(row.blocked)")
            }
            if !ok, !quiet.value, task.kind.isPhrase == false { print("      titolo: \(title.prefix(160))") }
            await BenchFixtures.tearDown(kind, checks: task.checks)
            await closeBenchPages(ex)
        }
        agent.shutdown()
        if let previous { await ex.bringToFront(previous) }

        func median(_ v: [Double]) -> Double { let s = v.sorted(); return s.isEmpty ? 0 : s[s.count / 2] }
        func p90(_ v: [Double]) -> Double { let s = v.sorted(); return s.isEmpty ? 0 : s[min(s.count - 1, Int(Double(s.count) * 0.9))] }
        let ran = rows.filter { $0.skipped == nil }
        let firsts = ran.compactMap(\.first)
        let totals = ran.map(\.total)
        print("\nRisultato (\(engine.rawValue)\(ran.first(where: { !$0.model.isEmpty }).map { "/" + $0.model } ?? "")):")
        for level in ["breve", "medio", "osserva"] {
            let r = ran.filter { $0.task.level == level }
            guard !r.isEmpty else { continue }
            print(String(format: "  %@: %d/%d riusciti", level, r.filter(\.ok).count, r.count))
        }
        let skipped = rows.count - ran.count
        print(String(format: "  totale: %d/%d (%.0f%%)%@ · passi medi %.1f · primo strumento mediana %.1f s, 90° %.1f s · tempo mediana %.1f s, 90° %.1f s",
                     ran.filter(\.ok).count, ran.count, ran.isEmpty ? 0 : Double(ran.filter(\.ok).count) / Double(ran.count) * 100,
                     skipped > 0 ? " · \(skipped) saltati" : "",
                     ran.isEmpty ? 0 : Double(ran.map(\.steps).reduce(0, +)) / Double(ran.count), median(firsts), p90(firsts), median(totals), p90(totals)))
        let withPhases = ran.filter { !$0.phases.isEmpty }
        let phaseMedians = BenchPhase.allCases.map { p in (p, median(withPhases.map { $0.phases[p] ?? 0 })) }
        print("  fasi (mediane): " + phaseMedians.map { String(format: "%@ %.2f s", $0.0.rawValue, $0.1) }.joined(separator: " · "))
        print("  somma delle fasi = totale entro 0,2 s: \(ran.allSatisfy(\.sumOK) ? "sì, su ogni compito" : "NO su \(ran.filter { !$0.sumOK }.map(\.task.id).joined(separator: ", "))")")

        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd-HHmm"
        let out = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/MacTalkAct-bench-\(f.string(from: Date()))-\(engine.rawValue).tsv")
        let phaseHeader = BenchPhase.allCases.map { "\($0.rawValue)_s" }.joined(separator: "\t")
        var tsv = "id\tlivello\tesito\tpassi\tprimo_strumento_s\ttotale_s\t\(phaseHeader)\trouter_s\tsomma_ok\tturni\tconferme\tbloccate\tmodello\trisposta\n"
        for r in rows {
            let esito = r.skipped != nil ? "saltato" : (r.ok ? "ok" : "no")
            let phases = BenchPhase.allCases.map { p in r.phases[p].map { String(format: "%.2f", $0) } ?? "" }.joined(separator: "\t")
            let answer = (r.skipped ?? r.note).replacingOccurrences(of: "\t", with: " ").replacingOccurrences(of: "\n", with: " ")
            tsv += "\(r.task.id)\t\(r.task.level)\t\(esito)\t\(r.steps)\t\(r.first.map { String(format: "%.1f", $0) } ?? "")\t\(String(format: "%.1f", r.total))\t\(phases)\t\(String(format: "%.2f", r.router))\t\(r.sumOK ? "sì" : "no")\t\(r.turns.map(String.init) ?? "")\t\(r.confirmations)\t\(r.blocked)\t\(r.model)\t\(answer)\n"
        }
        try? tsv.write(to: out, atomically: true, encoding: .utf8)
        print("Tabella: \(out.path)")
    }
}
