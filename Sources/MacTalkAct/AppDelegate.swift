import AppKit
import AVFoundation
import Combine
import SwiftUI

enum Permissions {
    static var accessibility: Bool { AXIsProcessTrusted() }

    static func promptAccessibility() {
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    static var microphone: Bool { AVCaptureDevice.authorizationStatus(for: .audio) == .authorized }

    static func openAccessibilitySettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }

    static func openScreenRecordingSettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
    }

    static func openMicrophoneSettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!)
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let settings = AppSettings.shared
    private var statusItem: NSStatusItem!
    private var hud: HUDController!
    private var coordinator: Coordinator!
    private var hotkey: HotkeyMonitor?
    private var settingsWindow: NSWindow?
    private var helpWindow: NSWindow?
    private var cancellables = Set<AnyCancellable>()
    private var permissionTimer: Timer?
    private var hadAccessibility = false
    private var lastAgentConfigKey = ""

    /// What the warm `claude` processes depend on: when it changes they are replaced.
    private var agentConfigKey: String {
        [settings.model, settings.fastModel, "\(settings.useFastModel)", settings.deepEffort, settings.fastEffort,
         "\(settings.agentMaxTurns)", settings.backend.rawValue, settings.claudePath, "\(settings.useAI)",
         settings.agentEngine.rawValue, "\(settings.engineFallback)", settings.codexPath, settings.localProvider.rawValue,
         settings.localServerURL, settings.localServerModel, "\(settings.localServerAllowRemote)"].joined(separator: "|")
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Text recognition (FR-47) loads in the background: listening is not delayed.
        TextReader.shared.warmUp()
        hud = HUDController()
        coordinator = Coordinator(hud: hud, settings: settings)
        coordinator.onModeChange = { [weak self] in self?.updateIcon() }
        coordinator.onPrivateModeChange = { [weak self] _ in self?.updateIcon() }
        coordinator.onShowHelp = { [weak self] in self?.showHelp() }

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
        updateIcon()

        hadAccessibility = Permissions.accessibility
        if !hadAccessibility { Permissions.promptAccessibility() }
        Task {
            if !Permissions.microphone { _ = await AVCaptureDevice.requestAccess(for: .audio) }
            await coordinator.prepare()
        }

        setupHotkey()
        settings.$pttKey.dropFirst().sink { [weak self] _ in
            DispatchQueue.main.async { self?.setupHotkey() }
        }.store(in: &cancellables)

        // Global key monitoring only works once Accessibility is granted: re-arm when it is.
        permissionTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let now = Permissions.accessibility
                if now && !self.hadAccessibility { self.setupHotkey() }
                self.hadAccessibility = now
            }
        }

        // Every change applies from the next action (AD-11): push the voice-detector values to the
        // audio thread and get a `claude` process ready with the new model/effort/limits.
        settings.objectWillChange
            .debounce(for: .milliseconds(400), scheduler: DispatchQueue.main)
            .sink { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.coordinator.applyListeningSettings()
                    let key = self.agentConfigKey
                    if key != self.lastAgentConfigKey {
                        self.lastAgentConfigKey = key
                        // Engines may have changed: re-check them, then warm the next one (AD-14).
                        self.coordinator.agent.refreshAvailability()
                        self.coordinator.prewarmAI()
                    }
                }
            }
            .store(in: &cancellables)
        lastAgentConfigKey = agentConfigKey

        if settings.useAI, !coordinator.agentReady { showSettings() }
    }

    func applicationWillTerminate(_ notification: Notification) {
        coordinator.planner.cli.shutdown()
        coordinator.agent.shutdown()
    }

    private func setupHotkey() {
        hotkey?.stop()
        let h = HotkeyMonitor(key: settings.pttKey)
        h.onPress = { [weak self] in self?.coordinator.pttDown() }
        h.onRelease = { [weak self] in self?.coordinator.pttUp() }
        h.onTap = { [weak self] in self?.coordinator.pttCancel() }
        h.onCancel = { [weak self] in self?.coordinator.pttCancel() }
        h.onDoubleTap = { [weak self] in self?.coordinator.toggleSession() }
        h.start()
        hotkey = h
    }

    private func updateIcon() {
        if settings.privateModeActive {
            statusItem.button?.image = NSImage(systemSymbolName: "lock.fill", accessibilityDescription: "MacTalkAct (modalità privata)")
            return
        }
        let symbol: String
        switch coordinator?.mode ?? .off {
        case .off: symbol = "hand.raised"
        case .wakeWord: symbol = "ear"
        case .session: symbol = "waveform"
        }
        if case .paused = coordinator?.agent.availability {
            statusItem.button?.image = NSImage(systemSymbolName: symbol == "hand.raised" ? "hand.raised.slash" : "\(symbol).badge.exclamationmark",
                                               accessibilityDescription: "MacTalkAct (agente in pausa)")
                ?? NSImage(systemSymbolName: symbol, accessibilityDescription: "MacTalkAct")
            return
        }
        statusItem.button?.image = NSImage(systemSymbolName: symbol, accessibilityDescription: "MacTalkAct")
    }

    // MARK: Menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let header = NSMenuItem(title: "Tieni premuto \(settings.pttKey.short) e parla", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)

        // Status
        let agentLine = NSMenuItem(title: "Agente: \(agentStatusText)", action: #selector(openStatusSection), keyEquivalent: "")
        agentLine.target = self
        let choice = coordinator.agent.currentChoice()
        agentLine.image = NSImage(systemSymbolName: choice == nil ? "pause.circle" : (choice!.isFallback ? "arrow.triangle.branch" : "sparkles"),
                                  accessibilityDescription: nil)
        menu.addItem(agentLine)
        let engineItem = NSMenuItem(title: "Motore dell'agente", action: nil, keyEquivalent: "")
        engineItem.image = NSImage(systemSymbolName: "cpu", accessibilityDescription: nil)
        let em = NSMenu()
        for id in EngineID.allCases {
            let state = coordinator.agent.availability(of: id)
            let note = state == .available ? "" : " — \(EngineSelector.state(state))"
            let item = NSMenuItem(title: id.title + note, action: #selector(chooseEngine(_:)), keyEquivalent: "")
            item.representedObject = id.rawValue
            item.state = settings.agentEngine == id ? .on : .off
            item.target = self
            em.addItem(item)
        }
        em.addItem(.separator())
        let fb = NSMenuItem(title: "Passa agli altri motori quando serve", action: #selector(quickToggle(_:)), keyEquivalent: "")
        fb.representedObject = "engineFallback"
        fb.state = settings.engineFallback ? .on : .off
        fb.target = self
        em.addItem(fb)
        let recheck = NSMenuItem(title: "Ricontrolla i motori", action: #selector(recheckEngines), keyEquivalent: "")
        recheck.target = self
        em.addItem(recheck)
        engineItem.submenu = em
        menu.addItem(engineItem)
        let routerLine = NSMenuItem(title: "Comprensione: \(routerStatusText)", action: #selector(openUnderstandingSection), keyEquivalent: "")
        routerLine.target = self
        routerLine.image = NSImage(systemSymbolName: "brain", accessibilityDescription: nil)
        menu.addItem(routerLine)
        menu.addItem(.separator())

        // Listening modes
        let wake = NSMenuItem(title: "Ascolto continuo («\(settings.firstWakePhrase)»)", action: #selector(toggleWake), keyEquivalent: "")
        wake.state = coordinator.mode == .wakeWord ? .on : .off
        wake.target = self
        menu.addItem(wake)
        let session = NSMenuItem(title: "Sessione a mani libere (doppio tocco)", action: #selector(toggleSession), keyEquivalent: "")
        session.state = coordinator.mode == .session ? .on : .off
        session.target = self
        menu.addItem(session)
        let priv = NSMenuItem(title: "Modalità privata (\(Int(settings.privateModeMinutes.rounded())) min)",
                              action: #selector(togglePrivateMode), keyEquivalent: "")
        priv.image = NSImage(systemSymbolName: "lock", accessibilityDescription: nil)
        priv.state = settings.privateModeActive ? .on : .off
        priv.target = self
        menu.addItem(priv)
        menu.addItem(.separator())

        // Quick settings
        let quick = NSMenuItem(title: "Impostazioni rapide", action: nil, keyEquivalent: "")
        quick.image = NSImage(systemSymbolName: "slider.horizontal.3", accessibilityDescription: nil)
        let q = NSMenu()
        func toggle(_ title: String, _ on: Bool, _ key: String) {
            let item = NSMenuItem(title: title, action: #selector(quickToggle(_:)), keyEquivalent: "")
            item.state = on ? .on : .off
            item.representedObject = key
            item.target = self
            q.addItem(item)
        }
        toggle("Modello Apple per capire le frasi", settings.useOnDeviceRouter, "useOnDeviceRouter")
        toggle("Corsia locale ⚡️ (comandi semplici senza Claude)", settings.useLocalLane, "useLocalLane")
        toggle("Modello rapido per le richieste semplici", settings.useFastModel, "useFastModel")
        toggle("Usa l'agente", settings.useAI, "useAI")
        q.addItem(.separator())
        toggle("Rispondi a voce", settings.speakReplies, "speakReplies")
        toggle("Suoni", settings.soundsEnabled, "soundsEnabled")
        toggle("All'avvio resta in ascolto", settings.startListening, "startListening")
        q.addItem(.separator())
        let conv = NSMenuItem(title: "Conversazione aperta dopo ogni risposta", action: nil, keyEquivalent: "")
        let cm = NSMenu()
        for seconds in [0, 10, 20, 30, 45, 60] {
            let item = NSMenuItem(title: seconds == 0 ? "Disattivata" : "\(seconds) secondi", action: #selector(setConversationSeconds(_:)), keyEquivalent: "")
            item.tag = seconds
            item.state = Int(settings.conversationSeconds) == seconds ? .on : .off
            item.target = self
            cm.addItem(item)
        }
        conv.submenu = cm
        q.addItem(conv)
        if settings.agentEngine != .local {
            let codex = settings.agentEngine == .codex
            let models = NSMenuItem(title: "Modello di \(settings.agentEngine.displayName) per i compiti lunghi", action: nil, keyEquivalent: "")
            let mm = NSMenu()
            let list = codex
                ? [("gpt-6.1-sol", "GPT-6.1 Sol"), ("gpt-6-astra", "GPT-6 Astra"), ("gpt-6.1-terra", "GPT-6.1 Terra")]
                : [("claude-opus-5-5", "Opus 5.5"), ("claude-sonnet-5-5", "Sonnet 5.5"), ("claude-haiku-5-5", "Haiku 5.5")]
            for (id, name) in list {
                let item = NSMenuItem(title: name, action: #selector(setDeepModel(_:)), keyEquivalent: "")
                item.representedObject = id
                item.state = (codex ? settings.codexModel : settings.model) == id ? .on : .off
                item.target = self
                mm.addItem(item)
            }
            models.submenu = mm
            q.addItem(models)
        }
        quick.submenu = q
        menu.addItem(quick)

        // Settings sections
        let prefs = NSMenuItem(title: "Impostazioni", action: nil, keyEquivalent: "")
        prefs.image = NSImage(systemSymbolName: "gearshape", accessibilityDescription: nil)
        let pm = NSMenu()
        let all = NSMenuItem(title: "Apri le impostazioni…", action: #selector(showSettings as () -> Void), keyEquivalent: ",")
        all.target = self
        pm.addItem(all)
        pm.addItem(.separator())
        for section in SettingsSection.allCases {
            let item = NSMenuItem(title: section.title, action: #selector(openSection(_:)), keyEquivalent: "")
            item.representedObject = section.rawValue
            item.image = NSImage(systemSymbolName: section.icon, accessibilityDescription: nil)
            item.target = self
            pm.addItem(item)
        }
        prefs.submenu = pm
        menu.addItem(prefs)

        // Permissions that are missing
        let missing = [("Accessibilità", Permissions.accessibility), ("Microfono", Permissions.microphone),
                       ("Registrazione schermo", ScreenCapture.hasPermission)].filter { !$0.1 }
        if !missing.isEmpty {
            let p = NSMenuItem(title: "Permessi da concedere: \(missing.map(\.0).joined(separator: ", "))…",
                               action: #selector(openPermissionsSection), keyEquivalent: "")
            p.image = NSImage(systemSymbolName: "exclamationmark.triangle", accessibilityDescription: nil)
            p.target = self
            menu.addItem(p)
        }
        menu.addItem(.separator())

        let memory = NSMenuItem(title: "Memoria e macro…", action: #selector(openMemorySection), keyEquivalent: "")
        memory.target = self
        menu.addItem(memory)
        let help = NSMenuItem(title: "Guida ai comandi…", action: #selector(showHelp), keyEquivalent: "")
        help.target = self
        menu.addItem(help)
        let log = NSMenuItem(title: "Apri il log", action: #selector(openLog), keyEquivalent: "")
        log.target = self
        menu.addItem(log)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Esci da MacTalkAct", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
    }

    private var agentStatusText: String {
        guard settings.useAI else { return "disattivato" }
        if settings.backend == .apiKey { return "Claude con chiave API" }
        let agent = coordinator.agent
        guard let choice = agent.currentChoice() else {
            return EngineSelector.unavailableMessage(chosen: settings.agentEngine, engines: agent.engines.mapValues(\.availability))
        }
        let engine = agent.engines[choice.engine]
        let models = settings.useFastModel
            ? "\(Self.short(engine?.model(for: .fast) ?? "")) / \(Self.short(engine?.model(for: .deep) ?? ""))"
            : Self.short(engine?.model(for: .deep) ?? "")
        let name = choice.engine == .local ? "Locale" : choice.engine.displayName
        if choice.isFallback { return "\(name) (\(choice.reason))" }
        return "\(name) · \(models)"
    }

    private var routerStatusText: String {
        let model = settings.useOnDeviceRouter && OnDeviceClassifier.isAvailable ? "modello Apple" : "regole prudenti"
        return settings.useLocalLane ? "\(model) + corsia locale" : model
    }

    private static func short(_ model: String) -> String {
        if model.hasPrefix("claude-") {
            return model.replacingOccurrences(of: "claude-", with: "").replacingOccurrences(of: "-5-5", with: " 5.5").capitalized
        }
        return model.replacingOccurrences(of: "gpt-", with: "GPT-")
    }

    @objc private func quickToggle(_ sender: NSMenuItem) {
        guard let key = sender.representedObject as? String else { return }
        switch key {
        case "useOnDeviceRouter": settings.useOnDeviceRouter.toggle()
        case "useLocalLane": settings.useLocalLane.toggle()
        case "useFastModel": settings.useFastModel.toggle()
        case "useAI": settings.useAI.toggle()
        case "engineFallback": settings.engineFallback.toggle()
        case "speakReplies": settings.speakReplies.toggle()
        case "soundsEnabled": settings.soundsEnabled.toggle()
        case "startListening": settings.startListening.toggle()
        default: break
        }
    }

    @objc private func setConversationSeconds(_ sender: NSMenuItem) { settings.conversationSeconds = Double(sender.tag) }

    @objc private func chooseEngine(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let id = EngineID(rawValue: raw) else { return }
        settings.agentEngine = id
        coordinator.agent.updateAggregate()
    }

    @objc private func recheckEngines() {
        coordinator.agent.refreshAvailability()
    }

    @objc private func setDeepModel(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        if id.hasPrefix("gpt-") { settings.codexModel = id } else { settings.model = id }
    }

    @objc private func openSection(_ sender: NSMenuItem) {
        if let raw = sender.representedObject as? String, let section = SettingsSection(rawValue: raw) { showSettings(section: section) }
    }

    @objc private func openStatusSection() { showSettings(section: .status) }
    @objc private func openUnderstandingSection() { showSettings(section: .understanding) }
    @objc private func openPermissionsSection() { showSettings(section: .permissions) }
    @objc private func openMemorySection() { showSettings(section: .memory) }
    @objc private func togglePrivateMode() {
        coordinator.setPrivateMode(!settings.privateModeActive)
    }

    @objc private func openLog() { NSWorkspace.shared.open(Log.fileURL) }

    @objc private func toggleWake() {
        coordinator.setMode(coordinator.mode == .wakeWord ? .off : .wakeWord)
    }

    @objc private func toggleSession() {
        coordinator.toggleSession()
    }





    // MARK: Windows

    @objc func showSettings() { showSettings(section: nil) }

    func showSettings(section: SettingsSection?) {
        if let section { settings.lastSettingsSection = section }
        if settingsWindow == nil {
            settingsWindow = SettingsWindowFactory.make(settings: settings, context: settingsContext)
            settingsWindow?.center()
        }
        NSApp.activate()
        settingsWindow?.makeKeyAndOrderFront(nil)
        settingsWindow?.orderFrontRegardless() // a menu-bar app may not be activated by macOS
    }

    private var settingsContext: SettingsContext {
        var c = SettingsContext()
        c.agentStatus = { [weak self] in self?.agentStatusText ?? "—" }
        c.routerDescription = { [weak self] in self?.routerStatusText ?? "—" }
        c.conversationCount = { [weak self] in
            guard let self else { return 0 }
            self.coordinator.conversation.log.expire()
            return self.coordinator.conversation.log.entries.count
        }
        c.clearConversation = { [weak self] in self?.coordinator.conversation.log.clear() }
        c.setPrivateMode = { [weak self] on in self?.coordinator.setPrivateMode(on) }
        c.showHelp = { [weak self] in self?.showHelp() }
        c.engineStates = { [weak self] in self?.coordinator.agent.engines.mapValues(\.availability) ?? [:] }
        c.recheckEngines = { [weak self] in self?.coordinator.agent.refreshAvailability() }
        c.engineErrors = { [weak self] in self?.coordinator.agent.lastErrors ?? [:] }
        c.engineCLIStatus = { [weak self] in self?.coordinator.agent.cliStatuses ?? [:] }
        c.testLocalEngine = { [weak self] in await self?.coordinator.testLocalEngine() ?? "—" }
        return c
    }

    @objc func showHelp() {
        if helpWindow == nil {
            let w = NSWindow(contentViewController: NSHostingController(rootView: HelpView()))
            w.title = "MacTalkAct – Cosa puoi dire"
            w.styleMask = [.titled, .closable, .resizable]
            w.isReleasedWhenClosed = false
            helpWindow = w
        }
        helpWindow?.center()
        helpWindow?.orderFrontRegardless()
    }
}

struct HelpView: View {
    @ObservedObject private var settings = AppSettings.shared

    private var sections: [(String, [String])] {
        let w = settings.effectiveWakeWord
        let W = w.prefix(1).uppercased() + w.dropFirst()
        return [
        ("Come attivarla", [
            "Tieni premuto ⌥ destro mentre parli, poi rilascia",
            "Doppio tocco su ⌥ destro: sessione a mani libere, di' «basta» per chiudere",
            "Ascolto continuo dal menu: di' «\(W)» seguito dal comando (es. «\(W), apri Mail»)",
            "La parola di attivazione si cambia in Impostazioni › Ascolto",
        ]),
        ("Scrivere", [
            "Con il cursore in un campo di testo, detta: il modello Apple sul Mac capisce se è testo da scrivere, un comando o chiacchiera",
            "Nel dubbio non scrive: ti mostra la frase e aspetta «scrivilo»",
            "«scrivi …» per forzare la dettatura",
            "«cancella quello che hai scritto»: toglie l'ultima cosa scritta dall'app",
            "«a capo», «invio», «cancella», «cancella parola», «seleziona tutto»",
        ]),
        ("Conversazione", [
            "Dopo ogni risposta hai \(Int(settings.conversationSeconds)) secondi per continuare senza dire «\(w)» («💬 Ti ascolto ancora»)",
            "In quei secondi la chiacchiera con chi è nella stanza viene ignorata",
            "«basta così» o «grazie» chiudono subito la conversazione",
            "L'agente ricorda le ultime 5 cose fatte (10 minuti): «rimetti com'era prima», «fai lo stesso con l'altra»",
            "«dimentica la conversazione» cancella questa memoria (non viene mai salvata su disco)",
        ]),
        ("Privacy", [
            "«modalità privata»: per \(Int(settings.privateModeMinutes.rounded())) minuti niente Claude né Codex, niente testo nel log, niente memoria",
            "«esci dalla modalità privata» la chiude prima",
            "Nelle app e nei siti riservati (password, banche, pagamenti) l'agente usa solo il modello sul Mac",
            "I campi password non vengono mai letti; carte, IBAN e codici vengono mascherati per Claude e Codex",
        ]),
        ("Muoversi", [
            "«giù», «su», «scorri molto giù», «pagina giù», «vai in cima», «vai in fondo»",
            "«ancora» ripete l'ultimo comando",
            "«indietro», «avanti», «ricarica», «nuova scheda», «scheda successiva»",
        ]),
        ("Cliccare e aprire", [
            "«clicca Invia», «clicca su Rispondi», «premi Salva»",
            "«apri Safari», «vai su Slack», «apri youtube.com»",
            "«app precedente», «minimizza», «chiudi»",
        ]),
        ("Modificare", [
            "«copia», «incolla», «taglia», «annulla», «ripristina», «salva»",
        ]),
        ("Dettatura lunga", [
            "«scrivi …» oppure «detta»: tutto quello che dici viene scritto, anche con pause",
            "Si chiude con «fine» oppure dopo 4 secondi di silenzio",
        ]),
        ("L'agente (tutto il resto)", [
            "Richieste libere: «apri la mail di LangChain», «cerca su YouTube ninna nanna»",
            "Guarda lo schermo, agisce, verifica e ti dice com'è andata",
            "Può farti una domanda: rispondi a voce",
            "«cancella l'ultima frase», «sostituisci martedì con giovedì», «traducilo in inglese»",
            "«stop» lo ferma in qualsiasi momento",
            "Le richieste semplici usano un modello più rapido; «pensaci bene» usa quello più capace",
            "I comandi di un solo passo (nuova scheda, schermo intero, apri un'app o un sito) partono subito, senza Claude ⚡️",
            "Se finisce la subscription l'agente va in pausa fino all'ora di ripresa: dettatura, comandi e numeri funzionano",
        ]),
        ("Numeri", [
            "«mostra numeri»: un numero su ogni elemento cliccabile della finestra",
            "Poi di' «12» (o «dodici», «clicca 12», «doppio clic 12», «destro 12»)",
            "«nascondi numeri» per toglierli; spariscono anche da soli dopo 30 secondi",
        ]),
        ("Memoria e macro", [
            "«ricorda che il profilo lavoro è il profilo Lavoro di Edge»",
            "«apri Edge profilo lavoro», «dimentica il profilo lavoro»",
            "«crea una macro modalità lavoro: apri Slack, apri Mail, apri Visual Studio Code»",
            "Poi basta dire «modalità lavoro». Il file si apre da menu › Memoria e macro…",
        ]),
        ("Voce", [
            "Impostazioni › «Rispondi a voce»: l'app dice a bassa voce com'è andata e ti fa le domande",
        ]),
        ("Impostazioni", [
            "Menu ✋ › Impostazioni: ogni comportamento dell'app, per sezioni, con «Ripristina predefiniti»",
            "Menu ✋ › Impostazioni rapide: gli interruttori più usati, al volo",
        ]),
        ("Sicurezza", [
            "Invio, eliminazione e acquisti chiedono sempre conferma: rispondi «sì»",
            "«stop» interrompe un'azione in corso",
        ]),
    ]
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                ForEach(sections, id: \.0) { title, lines in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(title).font(.headline)
                        ForEach(lines, id: \.self) { Text("• " + $0).font(.body) }
                    }
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(width: 560, height: 520)
    }
}
