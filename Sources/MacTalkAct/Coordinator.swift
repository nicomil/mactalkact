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
    /// Private mode switched on or off (menu bar).
    var onPrivateModeChange: ((Bool) -> Void)?

    let hud: HUDController
    let settings: AppSettings
    let engine = SpeechEngine()
    let executor = Executor()
    let planner = LLMPlanner()
    lazy var agent = AgentRunner(executor: executor, settings: settings)
    /// The gate of the Corsia locale (Story 10.2): same rules as the Agente's, its own counters, so a
    /// local request never mixes with the state of a request of the Agente.
    let localGate = AccessGate()
    let numbers = NumberOverlay()
    let speaker = Speaker()
    /// A question the agent asked the user, waiting for the spoken answer.
    private var agentQuestion: CheckedContinuation<String?, Never>?
    private var questionSerial = 0

    private(set) var ready = false
    private var pttHeld = false
    private var pttStart: Task<Void, Never>?
    /// Test mode: print what would be executed instead of doing it.
    var dryRun = false
    var onDryRun: ((String) -> Void)?
    private var sessionIdleTask: Task<Void, Never>?
    /// Armed state, conversation window, recent interactions (AD-4).
    let conversation = ConversationState()
    private var conversationHint: Task<Void, Never>?
    /// Sentences are routed one at a time, in order.
    private var routeChain: Task<Void, Never>?
    private var pending: PendingPlan?
    /// Long dictation: everything said is typed until "fine" or a long silence.
    private var dictating = false
    private var dictationOpenedMic = false
    private var dictationIdle: Task<Void, Never>?
    private var dictationChain: Task<Void, Never>?
    private var lastRepeatable: Command?
    /// The last repeatable action came from the Corsia locale: «ripeti» passes it through the gate again.
    private var lastRepeatableLocal: LocalAction?
    private var busy = false
    private var cancelRequested = false
    private let escape = EscapeMonitor()
    /// Words the recognizer should expect, refreshed when the frontmost window changes.
    private let vocabulary = SpeechVocabulary()
    /// Extra seconds a long answer stays on screen: the conversation window waits for it (FR-7).
    private var answerHold: TimeInterval = 0

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
        engine.onSpeechStart = { [weak self] in
            self?.dictationIdle?.cancel()
            self?.wakeModels()
        }
        vocabulary.onChange = { [weak self] words in
            self?.engine.vocabulary = words
            Log.debug("Vocabolario del riconoscimento: \(words.count) parole")
        }
        vocabulary.start()
        setupAgent()
        agent.onAvailabilityChange = { [weak self] a in self?.availabilityChanged(a) }
        agent.onEngineAvailabilityChange = { [weak self] id, a in self?.engineAvailabilityChanged(id, a) }
        agent.onEngineSwitch = { [weak self] change in self?.engineSwitched(change) }
        agent.onNotice = { [weak self] text in
            // Only while the agent works, never spoken: the restart is not news for the user.
            guard let self, self.agent.running else { return }
            self.hud.show(.thinking, text, detail: self.engineNotice ?? "🤖 Agente · di' «stop» per fermarlo")
        }
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
        applyListeningSettings()
    }

    /// Pushes the voice-detector settings to the audio thread (AD-11). Called at start and on every change.
    func applyListeningSettings() {
        engine.configureVAD(minStartRMS: Float(settings.vadMinStartRMS), noiseFactor: Float(settings.vadNoiseFactor),
                            endSilence: dictating ? settings.dictationEndSilence : settings.vadEndSilence,
                            maxSegment: settings.vadMaxSegment)
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
            prewarmRouter()
            if settings.cleanDictation { LocalText.prewarm() }
        } catch {
            hud.show(.error, "Riconoscimento vocale non disponibile", detail: error.localizedDescription, autoHide: 8)
            Log.error("prepare: \(error)")
        }
    }

    // MARK: Router

    private var routerCache: (key: String, router: IntentRouter)?

    /// The router, rebuilt when the relevant settings change.
    var router: IntentRouter {
        let onDevice = settings.useOnDeviceRouter && OnDeviceClassifier.isAvailable
        let timeout = settings.classifierTimeout
        let key = "\(onDevice)-\(timeout)"
        if let c = routerCache, c.key == key { return c.router }
        let classifier: IntentClassifier = onDevice ? OnDeviceClassifier(timeout: .milliseconds(Int(timeout * 1000))) : RuleClassifier()
        let proposer = LocalActionProposer.isAvailable ? LocalActionProposer() : nil
        let executor = self.executor
        let validator = LocalActionValidator { spoken in
            executor.findApp(spoken).map { FileManager.default.displayName(atPath: $0.path).replacingOccurrences(of: ".app", with: "") }
        }
        let r = IntentRouter(classifier: classifier, proposer: proposer, validator: validator)
        routerCache = (key, r)
        Log.info("Router: classificatore \(classifier.name)\(proposer == nil ? "" : " + corsia locale")")
        return r
    }

    private var modelsWokenAt = Date.distantPast

    /// The user started speaking: load Apple's model now, while they talk, so it answers
    /// within the timeout when the sentence ends. At most every 5 s.
    private func wakeModels() {
        guard Date().timeIntervalSince(modelsWokenAt) > 5 else { return }
        modelsWokenAt = Date()
        prewarmRouter()
    }

    /// Story 11.2 (FR-59): the user is talking to the app (wake phrase in the partial text, key pressed).
    /// Claude's Long sessions start now, so the request finds them ready; nothing is sent before the
    /// end of the Frase. AgentRunner checks the engine, the privacy, the switch and the 5 s throttle.
    private func prepareAgent() {
        guard settings.useAI, settings.backend == .subscription else { return }
        agent.prepareSession(generation: conversation.log.snapshot.generation)
    }

    /// The partial text starts Claude only when it carries the wake phrase (`wake`, from
    /// `WakeWord.extract`): chatter in continuous listening, or the conversation window open without
    /// «Computer», starts nothing, nor does the app's own spoken reply. Pure, tested by `--fallback-test`.
    nonisolated static func preparesSession(wake: String?, speaking: Bool) -> Bool {
        wake != nil && !speaking
    }

    private func prewarmRouter() {
        let r = router
        r.classifier.prewarm()
        if settings.useLocalLane { r.proposer?.prewarm() }
    }

    private func routerState(pushToTalk: Bool) -> RouterState {
        var s = RouterState()
        switch mode {
        case .off: s.listening = .pushToTalk
        case .wakeWord: s.listening = .wakeWord
        case .session: s.listening = .session
        }
        s.pushToTalk = pushToTalk
        s.armed = conversation.isArmed
        s.windowOpen = conversation.isWindowOpen && mode != .off
        if s.windowOpen, let last = conversation.log.entries.last {
            s.lastExchange = "«\(last.request)» → \(last.outcome.prefix(200))"
        }
        s.numbersVisible = numbers.isVisible
        if let p = pending, Date() >= p.expires { pending = nil } // an expired question is not an answer
        s.pendingConfirmation = pending != nil
        s.proposedText = conversation.pendingProposal
        s.wakePhrases = settings.wakePhraseList
        s.aiAvailable = agentReady
        s.agentAvailability = settings.backend == .subscription ? agent.availability : .available
        s.localLane = settings.useLocalLane
        s.localLaneMaxWords = settings.localLaneMaxWords
        // Instant level (FR-43): only when Claude would answer, and only for a target the app knows.
        s.instantLevel = settings.instantLevel && settings.backend == .subscription
            && agent.currentChoice()?.engine == .claude && PrivacyGuard.cloudBlockReason() == nil
        // The known target serves the Instant level and the Frasi spurie (FR-48): read only when asked.
        do {
            let executor = self.executor
            let log = conversation.log
            // The screen is read only when a rule asks, and once per sentence (Frasi spurie and
            // the Instant level share it). From the memory only Nico's requests: the agent's answers
            // are long sentences where almost any word appears.
            let labels = Box<[String]?>(nil)
            s.knownTarget = { text in
                if labels.value == nil { labels.value = ScreenContext.capture(includeLabels: true).visibleLabels }
                return RouteHeuristics.hasKnownTarget(text, knownApp: { executor.findApp($0) != nil }, labels: labels.value ?? [],
                                                      memory: log.entries.map(\.request))
            }
        }
        return s
    }

    /// The agent can be used at all: a configured engine (maybe paused) or the API key.
    var agentReady: Bool {
        guard settings.useAI else { return false }
        return settings.backend == .apiKey ? settings.apiKey != nil : agent.isConfigured
    }

    /// «Prova» in the settings: a harmless request to the local engine, with its timing (FR-31).
    func testLocalEngine() async -> String {
        guard !busy, !agent.running else { return "Sto già lavorando: riprova tra poco." }
        do {
            try await agent.start()
            agent.refreshAvailability()
            try? await Task.sleep(for: .milliseconds(1600)) // the server check
            let saved = agent.overrideChoice
            agent.overrideChoice = (.local, false)
            defer { agent.overrideChoice = saved }
            let started = Date()
            let answer = try await agent.run("Guarda la finestra in primo piano senza toccare nulla e dimmi in poche parole che app è.",
                                             context: ScreenContext.capture(includeLabels: false), deep: false)
            let first = agent.tools.firstCallAt.map { String(format: "%.1f s", $0.timeIntervalSince(started)) } ?? "nessuno"
            return String(format: "%@ · primo strumento: %@ · totale %.1f s · «%@»", agent.lastModel, first,
                          Date().timeIntervalSince(started), answer)
        } catch {
            return "Non riuscito: \(error.localizedDescription)"
        }
    }

    /// One engine changed state: «Codex è tornato» when the chosen one is back (FR-27).
    private func engineAvailabilityChanged(_ id: EngineID, _ a: AgentAvailability) {
        onModeChange?()
        guard id == settings.agentEngine, a == .available, !busy, let message = agent.chosenEngineIsBack() else { return }
        hud.show(.info, message, autoHide: 3)
        if settings.speakReplies { Task { await speaker.say(message) } }
    }

    private var lastAggregate: AgentAvailability = .available

    private func availabilityChanged(_ a: AgentAvailability) {
        onModeChange?()
        let previous = lastAggregate
        lastAggregate = a
        switch a {
        case .available:
            guard case .paused = previous else { return } // e.g. Codex found at launch: nothing came back
            hud.show(.info, "L'agente è tornato disponibile", autoHide: 3)
            if settings.speakReplies { Task { await speaker.say("L'agente è di nuovo disponibile.") } }
        case .paused(let until):
            let f = DateFormatter()
            f.dateFormat = "HH:mm"
            Log.info("Modalità ridotta fino alle \(f.string(from: until))")
        case .missing, .loginNeeded, .unavailable:
            break
        }
    }

    /// Keeps a `claude` process ready so free-form requests answer in ~2 s.
    func prewarmAI() {
        guard settings.useAI, settings.backend == .subscription else { return }
        Task {
            do {
                try await agent.start()
                agent.prewarm()
            } catch {
                Log.error("Server strumenti agente: \(error.localizedDescription)")
            }
        }
    }

    /// Shown with the agent's progress for the rest of the request (FR-27).
    private var engineNotice: String?

    private func engineSwitched(_ change: AgentRunner.EngineSwitch) {
        engineNotice = "🔀 \(change.message)"
        hud.show(.thinking, change.message, detail: "🤖 Agente · di' «stop» per fermarlo")
        if settings.speakReplies { Task { await speaker.say(change.message.replacingOccurrences(of: " · ", with: ", ")) } }
    }

    private func setupAgent() {
        agent.tools.onProgress = { [weak self] line in
            self?.hud.show(.working, line, detail: self?.engineNotice ?? "🤖 Agente · di' «stop» per fermarlo")
        }
        agent.tools.askUser = { [weak self] question, isConfirmation in
            await self?.askByVoice(question, confirmation: isConfirmation)
        }
        // The password field from the focused element alone: the gate adds at most ~20 ms to the lane.
        localGate.environment.focusedFieldIsSecure = { AccessGate.focusedFieldIsSecure() }
        // The Corsia locale asks with the same spoken question (AD-24): busy is on while it waits.
        localGate.askUser = { [weak self] question, isConfirmation in
            await self?.askByVoice(question, confirmation: isConfirmation)
        }
        // The access level in force, as while the Agente works (FR-54).
        localGate.onAccessNotice = { [weak self] text in
            self?.hud.show(.thinking, text, detail: "⚡️ Corsia locale")
        }
        // Esc while the Corsia locale asks: no answer, so the action is cancelled.
        localGate.onQuestion = { [weak self] asking in
            guard let self else { return }
            if asking {
                self.escape.start { [weak self] in
                    Log.info("Corsia locale: domanda annullata con Esc")
                    self?.answerAgent(nil)
                }
            } else {
                self.escape.stop()
            }
        }
    }

    /// Shows the agent's question and waits for the next sentence (25 s max).
    private func askByVoice(_ question: String, confirmation: Bool) async -> String? {
        Sound.confirm()
        let how = mode == .off ? "Tieni premuto \(settings.pttKey.short) e rispondi" : "Rispondi a voce"
        let wait = settings.agentQuestionSeconds
        hud.show(.confirm, question, detail: confirmation ? "\(how): «sì» conferma, altro annulla" : how, autoHide: wait)
        if settings.speakReplies { await speaker.say(question) }
        conversation.arm(seconds: wait)
        return await withCheckedContinuation { (c: CheckedContinuation<String?, Never>) in
            if agentQuestion != nil { Log.info("Domanda dell'agente sostituita da una nuova: resta senza risposta") }
            agentQuestion?.resume(returning: nil)
            agentQuestion = c
            questionSerial += 1
            let serial = questionSerial
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(wait))
                // Only its own question: a timer left by an earlier one never answers the next.
                guard let self, self.questionSerial == serial else { return }
                self.answerAgent(nil)
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
            try? await Task.sleep(for: .seconds(AppSettings.shared.sessionIdleSeconds))
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
        wakeModels()
        prepareAgent()
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
        if Self.preparesSession(wake: wake, speaking: speaker.isSpeaking) { prepareAgent() }
        let addressed = mode == .session || conversation.isArmed || pending != nil || wake != nil
        if addressed {
            hud.show(.listening, wake.map { $0.isEmpty ? "Dimmi pure…" : $0 } ?? live)
        }
    }

    /// A complete sentence: from push-to-talk (`addressed`) or from voice detection.
    private func handleUtterance(_ raw: String, addressed: Bool) {
        // The screen may change after this sentence: read the window again for the next ones.
        vocabulary.refresh(after: 2)
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
                // «ok», «bravo», «ciao amore» said to someone in the room are not an answer.
                let saidWake = WakeWord.extract(text, phrases: settings.wakePhraseList) != nil
                if !saidWake && !addressed && RouteHeuristics.isShortChatter(spoken) && !Grammar.isYes(spoken) {
                    Log.info("Instradamento: ignora · chiacchiera durante una domanda dell'agente · \(spoken.count) caratteri")
                    return
                }
                Log.info("🎙 Risposta alla domanda: \(Log.said(spoken))")
                hud.show(.working, spoken, detail: "🤖 Ricevuto")
                answerAgent(spoken)
            }
            return
        }
        let previous = routeChain
        // The Frase is handed over now: the first-response measure includes the wait in the chain (Story 11.1).
        let heard = Date()
        routeChain = Task { await previous?.value; await self.handle(text, addressed: addressed, heard: heard) }
    }

    // MARK: Routing

    /// Asks the router for a decision, logs it, and carries it out.
    /// `heard`: when the recognizer handed the Frase over, start of the «prima risposta visibile».
    private func handle(_ raw: String, addressed: Bool, heard: Date) async {
        guard !busy else { disarmFirstResponse(); return }
        let started = Date()
        var cached: ScreenContext?
        func screen() -> ScreenContext {
            if let c = cached { return c }
            let c = ScreenContext.capture(includeLabels: false)
            cached = c
            return c
        }
        let decision = await router.decide(raw, editable: { screen().isEditable }, state: routerState(pushToTalk: addressed))
        let ms = Int(Date().timeIntervalSince(started) * 1000)
        // Dictated text is meant for someone else: only its length, unless the detailed log is on.
        let dictated = Self.isDictation(decision) && !Log.isDetailed
        let what = decision.logsText && !dictated ? Log.said(raw) : "\(raw.count) caratteri"
        let reason = dictated && decision.label == "rapido" ? "grammatica: scrivi" : decision.reason
        Log.info("Instradamento: \(decision.label) · \(reason) · \(ms) ms · \(what)")
        if case .arm = decision {} else { conversation.disarm() }
        // «Prima risposta visibile» (Story 11.1): from the Frase handed over by the recognizer to the
        // first change of the HUD after this decision. An ignored sentence shows nothing: no line.
        firstResponse.arm(started: heard, label: decision.label)
        hud.onFirstShow = firstResponse.isArmed ? { [weak self] in
            if let line = self?.firstResponse.shown() { Log.info(line) }
        } : nil

        if dryRun {
            onDryRun?("DECISIONE: \(decision.label) · \(decision.reason) · \(ms) ms")
            if case .ignore = decision {} else { hud.show(.success, raw, detail: "(prova: \(decision.label))", autoHide: 2) }
            disarmFirstResponse()
            return
        }
        await perform(decision, screen: screen)
        // A path that never changed the HUD must not leave the measure to a later, unrelated show.
        disarmFirstResponse()
    }

    private func disarmFirstResponse() {
        firstResponse.disarm()
        hud.onFirstShow = nil
    }

    /// Decisions that type the sentence as text.
    private static func isDictation(_ decision: RouteDecision) -> Bool {
        switch decision {
        case .dictate, .askToType, .typeProposed: return true
        case .fast(let cmd, _):
            if case .type = cmd { return true }
            return false
        default: return false
        }
    }

    /// Measure of the first visible response of the sentence being handled (Story 11.1).
    private var firstResponse = FirstResponseMeter()

    /// What `perform` does around a decision (FR-48). Pure, tested by `--fallback-test`.
    struct DecisionHandling: Equatable {
        /// The conversation window opens afterwards (sentences without the wake phrase are evaluated).
        var opensWindow: Bool
        /// The hands-free session's idle timer starts again: the session stays open.
        var keepsSessionAlive: Bool
    }

    nonisolated static func handling(of decision: RouteDecision, mode: Mode) -> DecisionHandling {
        switch decision {
        case .ignore, .arm, .number, .askIntent:
            // «Vuoi che faccia qualcosa?» asks without opening the window and without keeping the
            // hands-free session alive; the others act on their own path.
            return DecisionHandling(opensWindow: false, keepsSessionAlive: false)
        default:
            return DecisionHandling(opensWindow: mode != .off, keepsSessionAlive: mode == .session)
        }
    }

    /// How long «Vuoi che faccia qualcosa?» stays up (FR-48).
    static let askIntentSeconds = 8.0
    private var askIntentShownAt = Date.distantPast

    private func perform(_ decision: RouteDecision, screen: () -> ScreenContext) async {
        let handling = Self.handling(of: decision, mode: mode)
        if handling.keepsSessionAlive { restartSessionIdle() }
        switch decision {
        case .ignore:
            if hud.model.phase == .listening && !conversation.isWindowOpen { hud.hide() }
            return
        case .arm:
            conversation.arm(seconds: settings.armedSeconds)
            Sound.listen()
            hud.show(.listening, "Dimmi pure…", autoHide: settings.armedSeconds)
            return
        case .number(let n, let method):
            await clickNumber(n, method: method)
            return
        case .askIntent(let text, _):
            // Asks, without arming nor opening the window, and without keeping the hands-free session
            // alive: the next sentence is judged as if the question was not there (FR-48). While the
            // question is still up, another chance sentence only updates it, without a new beep.
            if Date().timeIntervalSince(askIntentShownAt) > Self.askIntentSeconds { Sound.confirm() }
            askIntentShownAt = Date()
            let wake = settings.wakePhraseList.first ?? "computer"
            hud.show(.confirm, "Vuoi che faccia qualcosa?", detail: "Ho sentito «\(text.prefix(60))» · di' «\(wake)» e la richiesta",
                     autoHide: Self.askIntentSeconds)
            return
        default:
            break
        }

        busy = true
        cancelRequested = false
        var reopen = handling.opensWindow
        defer {
            busy = false
            if reopen { openConversation() }
        }

        switch decision {
        case .confirmation(let yes):
            guard let p = pending else { return }
            pending = nil
            if Date() < p.expires && yes {
                await execute(p.plan, context: p.context)
            } else {
                Sound.cancel()
                hud.show(.info, "Annullato", autoHide: 1.5)
            }
        case .macro(let macro):
            await runMacro(macro)
        case .fast(let cmd, let text):
            if case .stop = cmd {
                reopen = false
                if mode == .session { endSession() } else { conversation.closeWindow(); hud.show(.info, "Ok", autoHide: 1) }
                return
            }
            await runFast(cmd, original: text)
            conversation.log.add(request: text, outcome: "comando rapido eseguito", app: screen().appName)
        case .dictate(let text, _):
            await dictateOnce(text, context: screen())
        case .askToType(let text, let reason):
            conversation.proposedText = (text, Date().addingTimeInterval(settings.proposalSeconds))
            Sound.confirm()
            let detail = reason.contains("non è configurato") ? "Claude non è configurato · di' «scrivilo» per inserirlo"
                                                               : "Di' «scrivilo» per inserirlo"
            hud.show(.confirm, text, detail: detail, autoHide: settings.proposalSeconds)
        case .askIntent:
            break // handled before: it never arms nor reopens anything
        case .typeProposed(let text):
            conversation.proposedText = nil
            await dictateOnce(text, context: ScreenContext.capture(includeLabels: false))
        case .undoInsertion:
            if let message = await executor.undoLastInsertion() {
                done(message)
            } else {
                fail("Non ho scritto niente di recente")
            }
        case .closeConversation:
            reopen = false
            conversation.closeWindow()
            conversationHint?.cancel()
            hud.show(.info, "Ok, a dopo", autoHide: 1)
        case .forgetConversation:
            reopen = false
            conversation.log.clear()
            agent.endSessions(reason: "memoria azzerata")
            conversation.closeWindow()
            done("Conversazione dimenticata")
        case .privateMode(let on):
            setPrivateMode(on)
        case .local(let action, let text):
            await runLocal(action, text: text, app: screen().appName)
        case .agent(let text, let level, _):
            await runSmart(text, deep: level == .deep, instant: level == .instant, context: screen())
        case .reduced(_, let reason):
            Sound.error()
            hud.show(.info, reason.prefix(1).uppercased() + reason.dropFirst(),
                     detail: "Dettatura, comandi rapidi e numeri funzionano", autoHide: 4)
        case .ignore, .arm, .number:
            break
        }
    }

    /// After every response the conversation stays open for a while (FR-7).
    private func openConversation() {
        let seconds = settings.conversationSeconds + max(0, answerHold)
        answerHold = 0
        guard settings.conversationSeconds > 0 else { return }
        conversation.openWindow(seconds: seconds)
        conversationHint?.cancel()
        conversationHint = Task { @MainActor [weak self] in
            // Let the response stay readable first, then show a discreet "still listening".
            while let self, self.hud.isVisible, self.conversation.isWindowOpen {
                try? await Task.sleep(for: .milliseconds(300))
                if Task.isCancelled { return }
            }
            guard let self, !Task.isCancelled, !self.busy, self.conversation.isWindowOpen else { return }
            let left = self.conversation.windowUntil.timeIntervalSinceNow
            guard left > 1.5 else { return }
            self.hud.show(.listening, self.settings.hudCompact ? "Ti ascolto" : "💬 Ti ascolto ancora",
                          detail: "Continua senza «\(self.settings.firstWakePhrase)» · «basta così» per chiudere",
                          autoHide: left, mini: true)
        }
    }

    /// One dictated sentence (not the long dictation mode).
    /// macOS secure keyboard entry: nothing typed by an app gets through. Says which app has it on
    /// (FR-52) and returns true, so the text is not lost in silence.
    private func blockedBySecureInput() -> Bool {
        guard SecureInput.isOn else { return false }
        let owner = SecureInput.ownerName().map { "«\($0)»" } ?? "un'app"
        fail("Non posso scrivere: \(owner) ha attivato l'inserimento sicuro della tastiera",
             detail: "Succede con i campi password o con app come Terminal (Inserimento sicuro). Chiudilo e riprova.")
        return true
    }

    private func dictateOnce(_ text: String, context: ScreenContext) async {
        if blockedBySecureInput() { return }
        var out = text
        if settings.cleanDictation {
            hud.show(.thinking, text, detail: "Ripulisco il testo…")
            // Claude when it is the engine in use (as before); otherwise Apple's model, on the Mac (FR-33).
            let claudeInUse = (settings.backend == .apiKey ? settings.apiKey != nil
                : (settings.useAI && agent.currentChoice()?.engine == .claude))
                && PrivacyGuard.cloudBlockReason() == nil
            if claudeInUse, let c = try? await planner.cleanDictation(text, appName: context.appName, model: settings.model,
                                                                     backend: settings.backend, apiKey: settings.apiKey) {
                out = c
            } else if let c = await LocalText.cleanDictation(text) {
                out = c
            }
        }
        await executor.insertDictation(out, context: context)
        done(out, detail: "✍️ Scritto · «cancella quello che hai scritto» per toglierlo", logText: false)
    }

    /// Lane 2: a validated one-step action, run without the agent (FR-11). Proposed by a model, so
    /// it passes through the gate first (FR-56, Story 10.2): a refusal or a «no» never goes to the Agente.
    private func runLocal(_ action: LocalAction, text: String, app: String) async {
        localGate.reset()
        localGate.currentRequest = text
        let tool = AccessGate.toolCall(for: action).name
        let outcome = await localGate.runLocal(action, execute: {
            switch action {
            case .keys(let combo, let label):
                try executor.press(combo)
                // «ripeti» runs it again through the gate: the app in front may have changed.
                lastRepeatable = .keys(combo: combo, label: label, confirm: false)
                lastRepeatableLocal = action
                done(label, detail: "⚡️ \(combo)")
            case .openApp(let name):
                let opened = try await executor.openApp(name)
                done("Apro \(opened)", detail: "⚡️")
            case .openURL(let url):
                executor.openURL(url)
                done("Apro \(url)", detail: "⚡️")
            case .scroll(let direction):
                await executor.scroll(direction, amount: 1)
                lastRepeatable = .scroll(direction: direction, amount: 1)
                lastRepeatableLocal = action
                done(direction == "up" ? "↑ Su" : "↓ Giù", detail: "⚡️")
            }
        }, fallback: { error in
            // The local proposal did not work out, and nobody was asked: the agent can still try.
            Log.info("Corsia locale fallita (\(Log.isPrivate ? "errore" : error.localizedDescription)): passo all'agente")
            await runSmart(text, deep: false, context: ScreenContext.capture(includeLabels: false))
        })
        switch outcome {
        case .done:
            conversation.log.add(request: text, outcome: "fatto in locale: \(action.summary)", app: app)
        case .fellBack:
            break
        case .refused(let sentence):
            Log.info("Corsia locale: \(tool) rifiutato dal gate")
            fail(sentence)
            conversation.log.add(request: text, outcome: "rifiutato in locale: \(sentence)", app: app)
            if settings.speakReplies { await speaker.say(sentence) }
        case .cancelled:
            Log.info("Corsia locale: \(tool) annullato")
            Sound.cancel()
            hud.show(.info, "Annullato", autoHide: 1.5)
            conversation.log.add(request: text, outcome: "annullato: \(action.summary)", app: app)
        case .failed(let message):
            // After a «sì» the Agente would ask again: say it did not work instead.
            fail("Non riuscito", detail: message)
            conversation.log.add(request: text, outcome: "non riuscito in locale: \(action.summary)", app: app)
        }
    }

    // MARK: Dictation

    /// Starts a long dictation. Works in every mode: with push-to-talk only, the
    /// microphone stays on hands-free until the dictation ends.
    private func startDictation(announce: Bool) {
        dictating = true
        engine.setEndSilence(settings.dictationEndSilence)
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
        engine.setEndSilence(settings.vadEndSilence)
        if dictationOpenedMic {
            dictationOpenedMic = false
            if mode == .off { Task { await engine.stopAudio() } }
        }
        if mode != .off { conversation.openWindow(seconds: settings.conversationSeconds) }
        Log.info("Dettatura chiusa (\(reason))")
        hud.show(.success, "Dettatura chiusa", detail: reason, autoHide: 1.5)
    }

    private func restartDictationIdle() {
        dictationIdle?.cancel()
        dictationIdle = Task { [weak self] in
            guard let self else { return }
            try? await Task.sleep(for: .seconds(self.settings.dictationIdleSeconds))
            guard !Task.isCancelled else { return }
            self.stopDictation(reason: "silenzio")
        }
    }

    private func dictate(_ raw: String) async {
        if blockedBySecureInput() { return }
        var text = raw
        if let stripped = WakeWord.extract(text, phrases: settings.wakePhraseList) { text = stripped }
        let ending = Grammar.dictationEnding(text)
        if ending.ends || text.isEmpty {
            // «Ci vediamo domani. Fine.»: the text before the end phrase is still typed.
            if !ending.keep.isEmpty {
                Log.dictation(ending.keep)
                if !dryRun { await executor.insertDictation(ending.keep, context: ScreenContext.capture(includeLabels: false)) }
            }
            stopDictation(reason: "«\(text.isEmpty ? settings.firstWakePhrase : text)»")
            return
        }
        Log.dictation(text)
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
                lastRepeatableLocal = nil
                done(label)
            case .scroll(let direction, let amount):
                await executor.scroll(direction, amount: amount)
                lastRepeatable = cmd
                lastRepeatableLocal = nil
                done(direction == "up" ? "↑ Su" : "↓ Giù")
            case .repeatLast:
                if let local = lastRepeatableLocal {
                    // Proposed by a model: the gate judges it again, in the app in front now.
                    await runLocal(local, text: original, app: AX.frontmostApplication()?.localizedName ?? "")
                } else if let last = lastRepeatable { await runFast(last, original: original) }
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
                if blockedBySecureInput() { return }
                await executor.insertDictation(text, context: ScreenContext.capture(includeLabels: false))
                if mode != .off {
                    startDictation(announce: false) // keep typing what follows, pauses included
                } else {
                    done(text, detail: "✍️ Scritto", logText: false)
                }
            case .startDictation:
                startDictation(announce: true)
            case .showNumbers:
                let count = numbers.show(timeout: settings.numbersTimeout, limit: settings.numbersLimit)
                if count == 0 {
                    fail("Non trovo elementi cliccabili in questa finestra")
                } else {
                    hud.show(.info, "Di' il numero da cliccare", detail: "\(count) elementi · «nascondi numeri» per chiudere", autoHide: settings.numbersTimeout)
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
            case .openApp where agentReady, .click where agentReady:
                await runSmart(original, deep: false, context: ScreenContext.capture(includeLabels: false))
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
        Log.info("Macro «\(macro.name)»: \(macro.steps.count) passi")
        Log.detail("Macro «\(macro.name)»: \(macro.steps.joined(separator: "; "))")
        for (i, step) in macro.steps.enumerated() {
            if cancelRequested { hud.show(.info, "Macro interrotta", autoHide: 1.5); return }
            hud.show(.working, step, detail: "Macro «\(macro.name)» · \(i + 1)/\(macro.steps.count)")
            if let cmd = Grammar.parse(step) {
                await runFast(cmd, original: step)
            } else if agentReady {
                await runSmart(step, deep: RouteHeuristics.isComplex(step), context: ScreenContext.capture(includeLabels: false))
            } else {
                fail("Non so eseguire «\(step)» senza l'agente")
            }
            try? await Task.sleep(for: .milliseconds(500))
        }
        done("Macro «\(macro.name)» completata")
    }

    // MARK: Lane 3: Claude

    /// A request for Claude: the agent (subscription) or the single-shot planner (API key).
    private func runSmart(_ text: String, deep: Bool, instant: Bool = false, context ctx: ScreenContext) async {
        guard agentReady else {
            fail("Non ho capito «\(text)»",
                 detail: settings.useAI ? "Nessun motore dell'agente configurato: controlla le impostazioni" : "")
            return
        }

        // Private or reserved window: the agent with the local engine, never the API planner.
        if settings.backend == .subscription || PrivacyGuard.cloudBlockReason() != nil {
            await runAgent(text, context: ctx, deep: deep, instant: instant)
            return
        }

        hud.show(.thinking, text, detail: "Ci penso…")
        let full = ScreenContext.capture(includeLabels: true)
        do {
            let plan = try await planner.plan(utterance: text, context: full, model: settings.model,
                                              backend: settings.backend, apiKey: settings.apiKey)
            guard !cancelRequested else { hud.show(.info, "Interrotto", autoHide: 1.2); return }
            await handlePlan(plan, context: full)
            conversation.log.add(request: text, outcome: plan.hud, app: ctx.appName)
        } catch {
            fail("Claude non ha risposto", detail: error.localizedDescription)
        }
    }

    /// The agent observes and acts until the request is done.
    private func runAgent(_ text: String, context: ScreenContext, deep: Bool, instant: Bool = false) async {
        if agent.currentChoice() == nil {
            hud.show(.info, "Agente non disponibile",
                     detail: "\(EngineSelector.unavailableMessage(chosen: settings.agentEngine, engines: agent.engines.mapValues(\.availability))) · dettatura e comandi funzionano",
                     autoHide: 4)
            return
        }
        engineNotice = nil
        defer { engineNotice = nil }
        if settings.agentEngine.isCloud, let why = PrivacyGuard.cloudBlockReason() {
            // Reserved: the local engine works on it, Claude and Codex never see it.
            engineNotice = "🔒 \(why.prefix(1).uppercased() + why.dropFirst()) · resto sul Mac"
        } else if deep, agent.currentChoice()?.engine == .local {
            // Long tasks are beyond a small model: say it before starting (Story 5.4).
            engineNotice = "💻 Col modello locale potrebbe non riuscire"
        }
        hud.show(.thinking, text, detail: engineNotice ?? (deep ? "🤖 Ci penso con calma…" : "🤖 Ci penso…"))
        // Esc stops the agent while it works (FR-39).
        escape.start { [weak self] in
            guard let self, self.agent.running, !self.cancelRequested else { return }
            Log.info("Agente: interrotto con Esc")
            self.cancelRequested = true
            self.agent.cancel()
            self.answerAgent(nil)
            self.hud.show(.info, "Mi fermo", autoHide: 1.2)
        }
        defer { escape.stop() }
        do {
            try await agent.start()
            let answer = try await agent.run(text, context: context, recent: conversation.log.promptBlock, deep: deep,
                                             memory: conversation.log, instant: instant)
            conversation.log.add(request: text, outcome: answer.isEmpty ? "fatto" : answer, app: context.appName,
                                 changes: agent.tools.changes)
            if cancelRequested {
                hud.show(.info, "Interrotto", autoHide: 1.5)
            } else {
                // Long answers (explanations) stay as long as it takes to read them (~14 characters a second).
                let reading = min(30, max(settings.hudAnswerSeconds, Double(answer.count) / 14))
                answerHold = reading - settings.hudAnswerSeconds
                hud.show(.success, answer.isEmpty ? "Fatto" : answer, detail: engineNotice ?? "", autoHide: reading)
                if settings.speakReplies { await speaker.say(answer.isEmpty ? "Fatto" : answer) }
            }
        } catch {
            let message = error.localizedDescription
            conversation.log.add(request: text, outcome: "non riuscito: \(message.prefix(80))", app: context.appName,
                                 changes: agent.tools.changes)
            if cancelRequested {
                hud.show(.info, "Interrotto", autoHide: 1.5)
            } else if case AgentRunner.RunError.stoppedMidway = error {
                // A limit after the agent already acted: never repeated on another engine (FR-28).
                fail("Mi sono fermato a metà", detail: message)
                if settings.speakReplies { await speaker.say("Mi sono fermato a metà, controlla.") }
            } else if case .paused = agent.availability {
                // Usage limit and no other engine: reduced mode until it comes back (FR-14).
                fail("Limite d'uso raggiunto",
                     detail: "\(EngineSelector.unavailableMessage(chosen: settings.agentEngine, engines: agent.engines.mapValues(\.availability))) · dettatura e comandi funzionano")
                if settings.speakReplies { await speaker.say("Ho raggiunto il limite d'uso.") }
            } else {
                fail("L'agente non ce l'ha fatta", detail: message)
                if settings.speakReplies { await speaker.say("Non ci sono riuscito.") }
            }
        }
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
            conversation.arm(seconds: 15)
            Sound.confirm()
            hud.show(.confirm, plan.hud, detail: "Rispondi riformulando la richiesta", autoHide: 8)
        default:
            fail(plan.hud.isEmpty ? "Non so come farlo" : plan.hud)
        }
    }

    private func askConfirmation(_ plan: Plan, context: ScreenContext) {
        pending = PendingPlan(plan: plan, context: context, expires: Date().addingTimeInterval(settings.confirmationSeconds))
        Sound.confirm()
        let how = mode == .off ? "Tieni premuto \(settings.pttKey.short) e di' «sì»" : "Di' «sì»"
        hud.show(.confirm, plan.hud, detail: "\(how) per confermare, altro per annullare", autoHide: settings.confirmationSeconds)
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

    /// `logText: false` for text written for the user (dictation): the log gets only its length.
    private func done(_ title: String, detail: String = "", logText: Bool = true) {
        let what = logText && !Log.isPrivate ? title : (Log.isDetailed ? "«\(title)»" : "\(title.count) caratteri")
        Log.info("✓ \(what)\(detail.isEmpty ? "" : " (\(detail))")")
        hud.show(.success, title, detail: detail, autoHide: settings.hudSuccessSeconds)
    }

    private func fail(_ title: String, detail: String = "") {
        Sound.error()
        hud.show(.error, title, detail: detail, autoHide: settings.hudErrorSeconds)
        Log.error(Log.isPrivate ? "errore (modalità privata: \(title.count) + \(detail.count) caratteri)" : "\(title) \(detail)")
    }

    // MARK: Private mode

    private var privateModeEnd: Task<Void, Never>?

    /// «modalità privata»: for a while no cloud engine, no text in the log, nothing remembered.
    func setPrivateMode(_ on: Bool) {
        let was = settings.privateModeActive
        settings.setPrivateMode(on)
        conversation.log.clear()
        agent.endSessions(reason: "memoria azzerata")
        privateModeEnd?.cancel()
        privateModeEnd = nil
        onPrivateModeChange?(on)
        if on {
            let minutes = Int(settings.privateModeMinutes.rounded())
            Log.info("Modalità privata: attiva per \(minutes) minuti")
            hud.show(.info, "🔒 Modalità privata",
                     detail: "\(minutes) minuti: niente Claude né Codex, niente testo nel log · «esci dalla modalità privata»",
                     autoHide: 4)
            let until = settings.privateModeUntil ?? Date()
            privateModeEnd = Task { [weak self] in
                // A second after the end, so the mode is surely over when checked.
                try? await Task.sleep(for: .seconds(max(1, until.timeIntervalSinceNow + 1)))
                guard let self, !Task.isCancelled, !self.settings.privateModeActive else { return }
                self.settings.setPrivateMode(false)
                self.conversation.log.clear()
                self.onPrivateModeChange?(false)
                Log.info("Modalità privata: finita")
                self.hud.show(.info, "Modalità privata finita", autoHide: 2.5)
            }
        } else if was {
            Log.info("Modalità privata: disattivata")
            hud.show(.info, "Modalità privata finita", autoHide: 2)
        } else {
            hud.show(.info, "La modalità privata non era attiva", autoHide: 2)
        }
    }
}
