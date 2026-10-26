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
