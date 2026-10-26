import AppKit

/// Ties everything together: listening modes, the three-lane router
/// (fast command → dictation → Claude), confirmations and HUD feedback.
@MainActor
final class Coordinator {
    enum Mode { case off, wakeWord, session }

    private(set) var mode: Mode = .off
    private var modeBeforeSession: Mode = .off
    var onModeChange: (() -> Void)?
    var onShowHelp: (() -> Void)?

    let hud: HUDController
    let settings: AppSettings
    let engine = SpeechEngine()
    let executor = Executor()
    let planner = LLMPlanner()
    lazy var agent = AgentRunner(executor: executor, settings: settings)
    let numbers = NumberOverlay()
    let speaker = Speaker()
    /// A question the agent asked the user, waiting for the spoken answer.
    private var agentQuestion: CheckedContinuation<String?, Never>?

    private(set) var ready = false
    private var pttHeld = false
    private var pttStart: Task<Void, Never>?
    /// Test mode: print what would be executed instead of doing it.
    var dryRun = false
    var onDryRun: ((String) -> Void)?
    private var sessionIdleTask: Task<Void, Never>?
    /// After a command: a few seconds in which short fast commands ("giù", "ancora")
    /// work without the wake phrase. Free speech still needs it.
    private var followUpUntil = Date.distantPast
    /// After the wake phrase alone ("Computer…"): the next sentence is for us, whatever it is.
    private var armedUntil = Date.distantPast
    private var pending: PendingPlan?
    /// Long dictation: everything said is typed until "fine" or a long silence.
    private var dictating = false
    private var dictationOpenedMic = false
    private var dictationIdle: Task<Void, Never>?
    private var dictationChain: Task<Void, Never>?
    private let dictationTimeout: Duration = .seconds(4)
    private var lastRepeatable: Command?
    private var busy = false
    private var cancelRequested = false

    private struct PendingPlan {
        let plan: Plan
        let context: ScreenContext
        let expires: Date
    }

    init(hud: HUDController, settings: AppSettings) {
        self.hud = hud
        self.settings = settings
        engine.onLive = { [weak self] text in self?.handleLive(text) }
        engine.onUtterance = { [weak self] text in self?.handleUtterance(text, addressed: false) }
        engine.onSpeechStart = { [weak self] in self?.dictationIdle?.cancel() }
        setupAgent()
        // Don't listen to our own voice.
        speaker.onSpeakingChange = { [weak self] speaking in
            guard let self else { return }
            if speaking {
                self.engine.setVAD(false)
            } else if self.mode != .off || self.dictating {
                self.engine.setVAD(true)
            }
        }
        engine.onLevel = { [weak self] level in self?.hud.model.level = level }
    }

    func prepare() async {
        do {
            try await engine.prepare(onDownload: { [weak self] in
                self?.hud.show(.thinking, "Scarico il modello vocale italiano…", detail: "Solo la prima volta")
            })
            ready = true
            hud.show(.info, "Pronto. Tieni premuto \(settings.pttKey.short) e parla",
                     detail: "Doppio tocco: mani libere", autoHide: 3.5)
            if mode != .off {
                startContinuous() // the user turned listening on while we were still loading
            } else if settings.startListening {
                setMode(.wakeWord)
            }
            prewarmAI()
        } catch {
            hud.show(.error, "Riconoscimento vocale non disponibile", detail: error.localizedDescription, autoHide: 8)
            Log.error("prepare: \(error)")
        }
    }

    /// Keeps a `claude` process ready so free-form requests answer in ~2 s.
    func prewarmAI() {
        guard settings.aiAvailable, settings.backend == .subscription else { return }
        Task {
            do {
                try await agent.start()
                agent.prewarm()
            } catch {
                Log.error("Server strumenti agente: \(error.localizedDescription)")
            }
        }
    }

    private func setupAgent() {
        agent.tools.onProgress = { [weak self] line in
            self?.hud.show(.working, line, detail: "🤖 Agente · di' «stop» per fermarlo")
        }
        agent.tools.askUser = { [weak self] question, isConfirmation in
            await self?.askByVoice(question, confirmation: isConfirmation)
        }
    }

    /// Shows the agent's question and waits for the next sentence (25 s max).
    private func askByVoice(_ question: String, confirmation: Bool) async -> String? {
        Sound.confirm()
        let how = mode == .off ? "Tieni premuto \(settings.pttKey.short) e rispondi" : "Rispondi a voce"
        hud.show(.confirm, question, detail: confirmation ? "\(how): «sì» conferma, altro annulla" : how, autoHide: 25)
        if settings.speakReplies { await speaker.say(question) }
        armedUntil = Date().addingTimeInterval(25)
        return await withCheckedContinuation { (c: CheckedContinuation<String?, Never>) in
            agentQuestion?.resume(returning: nil)
            agentQuestion = c
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(25))
                self?.answerAgent(nil)
            }
        }
    }

    private func answerAgent(_ text: String?) {
        guard let q = agentQuestion else { return }
        agentQuestion = nil
        q.resume(returning: text)
    }

    // MARK: Modes

    func setMode(_ newMode: Mode) {
        guard newMode != mode else { return }
        if newMode == .session { modeBeforeSession = mode }
        mode = newMode
        onModeChange?()
        sessionIdleTask?.cancel()
        Log.info("Modalità: \(newMode)")

        switch newMode {
        case .off:
            Task { await engine.stopAudio() }
            hud.show(.info, "Ascolto continuo disattivato", autoHide: 1.5)
        case .wakeWord:
            startContinuous()
            hud.show(.info, "In ascolto: di' «\(settings.firstWakePhrase)» e poi il comando", autoHide: 3)
        case .session:
            startContinuous()
            Sound.listen()
            hud.show(.listening, "Mani libere: parla pure", detail: "Di' «basta» per chiudere")
            restartSessionIdle()
        }
    }

    func toggleSession() {
        if mode == .session { endSession() } else { setMode(.session) }
    }

    private func endSession() {
        let back: Mode = modeBeforeSession == .session ? .off : modeBeforeSession
        setMode(back)
        if back == .off { hud.show(.info, "Sessione chiusa", autoHide: 1.5) }
    }

    private func startContinuous() {
        guard ready else {
            hud.show(.thinking, "Preparo il riconoscimento vocale…", detail: "L'ascolto parte appena è pronto", autoHide: 4)
            return
        }
        Task {
            do { try await engine.startAudio(vad: true) } catch {
                hud.show(.error, "Non riesco ad ascoltare", detail: error.localizedDescription, autoHide: 5)
                mode = .off
                onModeChange?()
            }
        }
    }

    private func restartSessionIdle() {
        sessionIdleTask?.cancel()
        sessionIdleTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(60))
            guard !Task.isCancelled, let self, self.mode == .session else { return }
            self.endSession()
        }
    }

    // MARK: Push-to-talk

    func pttDown() {
        guard ready else {
            hud.show(.info, "Sto ancora preparando il riconoscimento vocale…", autoHide: 2)
            return
        }
        pttHeld = true
        Sound.listen()
        hud.show(.listening, "Ti ascolto…")
        let continuous = mode != .off
        pttStart = Task {
            do { try await engine.beginPushToTalk(continuous: continuous) } catch {
                pttHeld = false
                hud.show(.error, "Non riesco ad ascoltare", detail: error.localizedDescription, autoHide: 5)
            }
        }
    }

    func pttUp() {
        guard pttHeld else { return }
        pttHeld = false
        let heard = hud.model.title
        hud.show(.thinking, heard == "Ti ascolto…" ? "…" : heard)
        Task {
            await pttStart?.value
            let text = await engine.endPushToTalk()
            if mode == .off { await engine.stopAudio() }
            handleUtterance(text, addressed: true)
        }
    }

    /// Short tap or ⌥+letter: not a voice command, drop it silently.
    func pttCancel() {
        guard pttHeld else { return }
        pttHeld = false
        Task {
            await pttStart?.value
            engine.cancelPushToTalk()
            if mode == .off { await engine.stopAudio() }
        }
        if pending == nil { hud.hide() }
    }

    // MARK: Transcription

    /// Live text while a sentence is being spoken.
    private func handleLive(_ live: String) {
        if pttHeld {
            hud.update(live.isEmpty ? "Ti ascolto…" : live)
            return
        }
        if dictating, !live.isEmpty {
            hud.show(.listening, live, detail: "✍️ Dettatura · di' «fine» per chiudere")
            return
        }
        guard mode != .off, !busy, !live.isEmpty else { return }
        let wake = WakeWord.extract(live, phrases: settings.wakePhraseList)
        let addressed = mode == .session || Date() < armedUntil || pending != nil || wake != nil
        if addressed {
            hud.show(.listening, wake.map { $0.isEmpty ? "Dimmi pure…" : $0 } ?? live)
        }
    }

    /// A complete sentence: from push-to-talk (`addressed`) or from voice detection.
    private func handleUtterance(_ raw: String, addressed: Bool) {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if speaker.isSpeaking && !addressed { return } // our own voice
        if dictating {
            if text.isEmpty { restartDictationIdle(); return }
            let previous = dictationChain
            dictationChain = Task { await previous?.value; await self.dictate(text) }
            return
        }
        guard !text.isEmpty else {
            if addressed && pending == nil { hud.hide() }
            return
        }
        if busy {
            let spoken = WakeWord.extract(text, phrases: settings.wakePhraseList).flatMap { $0.isEmpty ? nil : $0 } ?? text
            if Grammar.isStop(spoken) {
                speaker.stop()
                cancelRequested = true
                planner.cli.cancelCurrent()
                agent.cancel()
                answerAgent(nil)
                hud.show(.info, "Mi fermo", autoHide: 1.2)
            } else if agentQuestion != nil {
                Log.speech("Risposta all'agente: \(spoken)")
                hud.show(.working, spoken, detail: "🤖 Ricevuto")
                answerAgent(spoken)
            }
            return
        }
        Task { await handle(text, addressed: addressed) }
    }

    // MARK: Router

    private func handle(_ raw: String, addressed: Bool) async {
        var text = raw
        let armed = Date() < armedUntil
        let inConversation = addressed || mode == .session || armed || pending != nil
        armedUntil = .distantPast

        // Numbers on screen: "12" / "clicca 12" picks one, no wake phrase needed.
        if numbers.isVisible {
            let spoken = WakeWord.extract(text, phrases: settings.wakePhraseList).flatMap { $0.isEmpty ? nil : $0 } ?? text
            if let choice = Grammar.numberChoice(spoken) {
                Log.speech(spoken)
                await clickNumber(choice.number, method: choice.method)
                return
            }
        }

        if !inConversation {
            // Continuous listening: speech containing the wake phrase is for us…
            if let stripped = WakeWord.extract(text, phrases: settings.wakePhraseList) {
                text = stripped
                if text.isEmpty {
                    armedUntil = Date().addingTimeInterval(8)
                    Sound.listen()
                    hud.show(.listening, "Dimmi pure…", autoHide: 8)
                    return
                }
            } else if Date() < followUpUntil, Grammar.parse(text) != nil {
                // …and so is a short fast command right after another command.
            } else {
                Log.debug("Ignorato (manca «\(settings.firstWakePhrase)»)")
                if hud.model.phase == .listening { hud.hide() }
                return
            }
        } else if let stripped = WakeWord.extract(text, phrases: settings.wakePhraseList), !stripped.isEmpty {
            text = stripped
        }

        if mode != .off { followUpUntil = Date().addingTimeInterval(8) }
        if mode == .session { restartSessionIdle() }
        Log.speech(text)
        if dryRun {
            switch Grammar.parse(text) {
            case .type(let t)?:
                onDryRun?("SCRIVEREI: «\(t)»")
                startDictation(announce: false)
                return
            case .startDictation?:
                onDryRun?("INIZIO DETTATURA")
                startDictation(announce: true)
                return
            default:
                break
            }
            let fast = Grammar.parse(text).map { "comando rapido \($0)" } ?? "dettatura o Claude"
            onDryRun?("ESEGUIREI: «\(text)» → \(fast)")
            hud.show(.success, text, detail: "(prova: \(fast))", autoHide: 2)
            return
        }

        busy = true
        cancelRequested = false
        defer { busy = false }

        if let p = pending {
            pending = nil
            if Date() < p.expires && Grammar.isYes(text) {
                await execute(p.plan, context: p.context)
            } else {
                Sound.cancel()
                hud.show(.info, "Annullato", autoHide: 1.5)
            }
            return
        }

        if let macro = Memory.shared.macro(for: text) {
            await runMacro(macro)
            return
        }

        if let cmd = Grammar.parse(text) {
            if case .stop = cmd {
                if mode == .session { endSession() } else { hud.show(.info, "Ok", autoHide: 1) }
                return
            }
            await runFast(cmd, original: text)
            return
        }
        await runSmart(text)
    }

    // MARK: Dictation

    /// Starts a long dictation. Works in every mode: with push-to-talk only, the
    /// microphone stays on hands-free until the dictation ends.
    private func startDictation(announce: Bool) {
        dictating = true
        engine.setEndSilence(1.6)
        if mode == .off {
            dictationOpenedMic = true
            Task { try? await engine.startAudio(vad: true) }
        }
        Log.info("Dettatura iniziata")
        hud.show(.listening, announce ? "Detta pure…" : "Continua pure…", detail: "✍️ Dettatura · di' «fine» per chiudere")
        if announce { Sound.listen() }
        restartDictationIdle()
    }

    private func stopDictation(reason: String) {
        guard dictating else { return }
        dictating = false
        dictationIdle?.cancel()
        engine.setEndSilence(0.8)
        if dictationOpenedMic {
            dictationOpenedMic = false
            if mode == .off { Task { await engine.stopAudio() } }
        }
        followUpUntil = Date().addingTimeInterval(8)
        Log.info("Dettatura chiusa (\(reason))")
        hud.show(.success, "Dettatura chiusa", detail: reason, autoHide: 1.5)
    }

    private func restartDictationIdle() {
        dictationIdle?.cancel()
        dictationIdle = Task { [weak self] in
            guard let self else { return }
            try? await Task.sleep(for: self.dictationTimeout)
            guard !Task.isCancelled else { return }
            self.stopDictation(reason: "silenzio")
        }
    }

    private func dictate(_ raw: String) async {
        var text = raw
        if let stripped = WakeWord.extract(text, phrases: settings.wakePhraseList) { text = stripped }
        if Grammar.isDictationEnd(text) || text.isEmpty {
            stopDictation(reason: "«\(text.isEmpty ? settings.firstWakePhrase : text)»")
            return
        }
        Log.speech("✍️ \(text)")
        if !dryRun {
            await executor.insertDictation(text, context: ScreenContext.capture(includeLabels: false))
        } else {
            onDryRun?("SCRIVEREI: «\(text)»")
        }
        hud.show(.listening, text, detail: "✍️ Scritto · continua o di' «fine»")
        restartDictationIdle()
    }

    // MARK: Lane 1: fast commands

    private func runFast(_ cmd: Command, original: String) async {
        do {
            switch cmd {
            case .keys(let combo, let label, let confirm):
                if confirm {
                    let plan = Plan(kind: "act", hud: label, needs_confirmation: true, steps: [.keys(combo)])
                    askConfirmation(plan, context: ScreenContext())
                    return
                }
                try executor.press(combo)
                lastRepeatable = cmd
                done(label)
            case .scroll(let direction, let amount):
                await executor.scroll(direction, amount: amount)
                lastRepeatable = cmd
                done(direction == "up" ? "↑ Su" : "↓ Giù")
            case .repeatLast:
                if let last = lastRepeatable { await runFast(last, original: original) }
                else { hud.show(.info, "Niente da ripetere", autoHide: 1.5) }
            case .openApp(let name):
                let opened = try await executor.openApp(name)
                done("Apro \(opened)")
            case .openURL(let url):
                executor.openURL(url)
                done("Apro \(url)")
            case .click(let label):
                let clicked = try await executor.click(label)
                done("Cliccato «\(clicked)»")
            case .type(let text):
                await executor.insertDictation(text, context: ScreenContext.capture(includeLabels: false))
                if mode != .off {
                    startDictation(announce: false) // keep typing what follows, pauses included
                } else {
                    done(text, detail: "✍️ Scritto")
                }
            case .startDictation:
                startDictation(announce: true)
            case .showNumbers:
                let count = numbers.show()
                if count == 0 {
                    fail("Non trovo elementi cliccabili in questa finestra")
                } else {
                    hud.show(.info, "Di' il numero da cliccare", detail: "\(count) elementi · «nascondi numeri» per chiudere", autoHide: 30)
                }
            case .hideNumbers:
                numbers.hide()
                hud.hide()
            case .help:
                onShowHelp?()
                hud.hide()
            case .stop:
                break
            }
        } catch {
            // "apri il file budget" or "clicca la seconda mail" may need real understanding.
            switch cmd {
            case .openApp where settings.aiAvailable, .click where settings.aiAvailable:
                await runSmart(original)
            default:
                fail(error.localizedDescription)
            }
        }
    }

    // MARK: Numbers and macros

    private func clickNumber(_ n: Int, method: String) async {
        guard let item = numbers.item(n) else {
            fail("Il numero \(n) non c'è", detail: "Di' «mostra numeri» per aggiornarli")
            return
        }
        numbers.hide()
        let center = CGPoint(x: item.frame.midX, y: item.frame.midY)
        switch method {
        case "double": await executor.mouseClick(at: center, count: 2)
        case "right": await executor.mouseClick(at: center, right: true)
        default:
            if !AX.press(item.element) { await executor.mouseClick(at: center) }
        }
        done("Cliccato \(n)")
    }

    /// Runs each step like a spoken command: fast command if possible, otherwise the agent.
    private func runMacro(_ macro: Memory.Macro) async {
        Log.info("Macro «\(macro.name)»: \(macro.steps.joined(separator: "; "))")
        for (i, step) in macro.steps.enumerated() {
            if cancelRequested { hud.show(.info, "Macro interrotta", autoHide: 1.5); return }
            hud.show(.working, step, detail: "Macro «\(macro.name)» · \(i + 1)/\(macro.steps.count)")
            if let cmd = Grammar.parse(step) {
                await runFast(cmd, original: step)
            } else if settings.aiAvailable && settings.backend == .subscription {
                await runAgent(step, context: ScreenContext.capture(includeLabels: false))
            } else {
                await runSmart(step)
            }
            try? await Task.sleep(for: .milliseconds(500))
        }
        done("Macro «\(macro.name)» completata")
    }

    // MARK: Lanes 2 and 3: dictation or Claude

    private func runSmart(_ text: String) async {
        let ctx = ScreenContext.capture(includeLabels: false)
        let looksLikeDictation = ctx.isEditable && !Grammar.startsWithActionVerb(text)

        if looksLikeDictation || (!settings.aiAvailable && ctx.isEditable) {
            var out = text
            if settings.cleanDictation, settings.aiAvailable {
                hud.show(.thinking, text, detail: "Ripulisco il testo…")
                out = (try? await planner.cleanDictation(text, appName: ctx.appName, model: settings.model,
                                                         backend: settings.backend, apiKey: settings.apiKey)) ?? text
            }
            await executor.insertDictation(out, context: ctx)
            done(out, detail: "✍️ Scritto")
            return
        }

        guard settings.aiAvailable else {
            fail("Non ho capito «\(text)»",
                 detail: settings.useAI ? "Claude non è configurato: controlla le impostazioni" : "")
            return
        }

        if settings.backend == .subscription {
            await runAgent(text, context: ctx)
            return
        }

        hud.show(.thinking, text, detail: "Ci penso…")
        let full = ScreenContext.capture(includeLabels: true)
        do {
            let plan = try await planner.plan(utterance: text, context: full, model: settings.model,
                                              backend: settings.backend, apiKey: settings.apiKey)
            guard !cancelRequested else { hud.show(.info, "Interrotto", autoHide: 1.2); return }
            await handlePlan(plan, context: full)
        } catch {
            fail("Claude non ha risposto", detail: error.localizedDescription)
        }
    }

    /// Lane 3: the agent observes and acts until the request is done.
    private func runAgent(_ text: String, context: ScreenContext) async {
        hud.show(.thinking, text, detail: "🤖 Ci penso…")
        do {
            try await agent.start()
            let answer = try await agent.run(text, context: context)
            if cancelRequested {
                hud.show(.info, "Interrotto", autoHide: 1.5)
            } else {
                hud.show(.success, answer.isEmpty ? "Fatto" : answer, autoHide: 5)
                if settings.speakReplies { await speaker.say(answer.isEmpty ? "Fatto" : answer) }
            }
        } catch {
            let message = error.localizedDescription
            if cancelRequested {
                hud.show(.info, "Interrotto", autoHide: 1.5)
            } else if message.localizedCaseInsensitiveContains("limit") {
                // Subscription usage limit: say when it comes back, in plain words.
                let reset = message.range(of: "resets ").map { String(message[$0.upperBound...]) } ?? ""
                fail("Limite della subscription raggiunto",
                     detail: reset.isEmpty ? "Comandi rapidi e dettatura funzionano ancora" : "Riprende alle \(reset) · comandi rapidi e dettatura funzionano")
                if settings.speakReplies { await speaker.say("Ho raggiunto il limite della subscription.") }
            } else {
                fail("L'agente non ce l'ha fatta", detail: message)
                if settings.speakReplies { await speaker.say("Non ci sono riuscito.") }
            }
        }
        followUpUntil = Date().addingTimeInterval(8)
        agent.prewarm()
    }

    private func handlePlan(_ plan: Plan, context: ScreenContext) async {
        switch plan.kind {
        case "act" where !plan.steps.isEmpty:
            if plan.needs_confirmation || Safety.isRisky(plan) {
                askConfirmation(plan, context: context)
            } else {
                await execute(plan, context: context)
            }
        case "clarify":
            armedUntil = Date().addingTimeInterval(15)
            Sound.confirm()
            hud.show(.confirm, plan.hud, detail: "Rispondi riformulando la richiesta", autoHide: 8)
        default:
            fail(plan.hud.isEmpty ? "Non so come farlo" : plan.hud)
        }
    }

    private func askConfirmation(_ plan: Plan, context: ScreenContext) {
        pending = PendingPlan(plan: plan, context: context, expires: Date().addingTimeInterval(20))
        followUpUntil = Date().addingTimeInterval(20)
        Sound.confirm()
        let how = mode == .off ? "Tieni premuto \(settings.pttKey.short) e di' «sì»" : "Di' «sì»"
        hud.show(.confirm, plan.hud, detail: "\(how) per confermare, altro per annullare", autoHide: 20)
    }

    private func execute(_ plan: Plan, context: ScreenContext) async {
        hud.show(.working, plan.hud.isEmpty ? "Eseguo…" : plan.hud)
        do {
            for step in plan.steps {
                if cancelRequested {
                    hud.show(.info, "Interrotto", autoHide: 1.5)
                    return
                }
                try await executor.run(step, context: context)
                try await Task.sleep(for: .milliseconds(120))
            }
            done(plan.hud.isEmpty ? "Fatto" : plan.hud)
        } catch {
            fail(error.localizedDescription)
        }
    }

    // MARK: Feedback

    private func done(_ title: String, detail: String = "") {
        Log.info("✓ \(title)\(detail.isEmpty ? "" : " (\(detail))")")
        hud.show(.success, title, detail: detail, autoHide: 1.3)
    }

    private func fail(_ title: String, detail: String = "") {
        Sound.error()
        hud.show(.error, title, detail: detail, autoHide: 4)
        Log.error("\(title) \(detail)")
    }
}
