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
            let analyzer = try await SpeechAnalyzer(inputAudioFile: file, modules: [transcriber], finishAfterFile: true)
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
            for request in ["modifica la domanda: che cos'è il cloud computing diventa che cos'è Internet",
                            "rimetti la domanda di prima"] {
                let ctx = ScreenContext.capture(includeLabels: false)
                let started = Date()
                let answer = try await agent.run(request, context: ctx, recent: log.promptBlock, deep: false)
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
