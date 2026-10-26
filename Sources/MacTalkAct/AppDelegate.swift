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

    func applicationDidFinishLaunching(_ notification: Notification) {
        hud = HUDController()
        coordinator = Coordinator(hud: hud, settings: settings)
        coordinator.onModeChange = { [weak self] in self?.updateIcon() }
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

        // Restart the warm `claude` process when the model or backend changes.
        settings.$model.combineLatest(settings.$backend).dropFirst()
            .debounce(for: .milliseconds(300), scheduler: DispatchQueue.main)
            .sink { [weak self] _ in self?.coordinator.prewarmAI() }
            .store(in: &cancellables)

        if !settings.aiAvailable { showSettings() }
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
        let symbol: String
        switch coordinator?.mode ?? .off {
        case .off: symbol = "hand.raised"
        case .wakeWord: symbol = "ear"
        case .session: symbol = "waveform"
        }
        statusItem.button?.image = NSImage(systemSymbolName: symbol, accessibilityDescription: "MacTalkAct")
    }

    // MARK: Menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let header = NSMenuItem(title: "Tieni premuto \(settings.pttKey.short) e parla", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        menu.addItem(.separator())

        let wake = NSMenuItem(title: "Ascolto continuo («\(settings.firstWakePhrase)»)", action: #selector(toggleWake), keyEquivalent: "")
        wake.state = coordinator.mode == .wakeWord ? .on : .off
        wake.target = self
        menu.addItem(wake)

        let session = NSMenuItem(title: "Sessione a mani libere (doppio tocco)", action: #selector(toggleSession), keyEquivalent: "")
        session.state = coordinator.mode == .session ? .on : .off
        session.target = self
        menu.addItem(session)
        menu.addItem(.separator())

        let ax = NSMenuItem(title: Permissions.accessibility ? "Accessibilità: concessa ✓" : "Accessibilità: da concedere…",
                            action: #selector(openAccessibility), keyEquivalent: "")
        ax.target = self
        menu.addItem(ax)
        let mic = NSMenuItem(title: Permissions.microphone ? "Microfono: concesso ✓" : "Microfono: da concedere…",
                             action: #selector(openMicrophone), keyEquivalent: "")
        mic.target = self
        menu.addItem(mic)
        let screen = NSMenuItem(title: ScreenCapture.hasPermission ? "Registrazione schermo: concessa ✓" : "Registrazione schermo: da concedere… (per l'agente)",
                                action: #selector(openScreenRecording), keyEquivalent: "")
        screen.target = self
        menu.addItem(screen)
        menu.addItem(.separator())

        let memory = NSMenuItem(title: "Memoria e macro…", action: #selector(openMemory), keyEquivalent: "")
        memory.target = self
        menu.addItem(memory)
        let help = NSMenuItem(title: "Guida ai comandi…", action: #selector(showHelp), keyEquivalent: "")
        help.target = self
        menu.addItem(help)
        let prefs = NSMenuItem(title: "Impostazioni…", action: #selector(showSettings), keyEquivalent: ",")
        prefs.target = self
        menu.addItem(prefs)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Esci da MacTalkAct", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
    }

    @objc private func toggleWake() {
        coordinator.setMode(coordinator.mode == .wakeWord ? .off : .wakeWord)
    }

    @objc private func toggleSession() {
        coordinator.toggleSession()
    }

    @objc private func openAccessibility() {
        Permissions.promptAccessibility()
        Permissions.openAccessibilitySettings()
    }

    @objc private func openMemory() {
        Memory.shared.openInEditor()
    }

    @objc private func openScreenRecording() {
        ScreenCapture.requestPermission()
        Permissions.openScreenRecordingSettings()
    }

    @objc private func openMicrophone() {
        Permissions.openMicrophoneSettings()
    }

    // MARK: Windows

    @objc func showSettings() {
        if settingsWindow == nil {
            let w = NSWindow(contentViewController: NSHostingController(rootView: SettingsView(settings: settings)))
            w.title = "MacTalkAct – Impostazioni"
            w.styleMask = [.titled, .closable]
            w.isReleasedWhenClosed = false
            settingsWindow = w
        }
        NSApp.activate()
        settingsWindow?.center()
        settingsWindow?.makeKeyAndOrderFront(nil)
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
    private let sections: [(String, [String])] = [
        ("Come attivarla", [
            "Tieni premuto ⌥ destro mentre parli, poi rilascia",
            "Doppio tocco su ⌥ destro: sessione a mani libere, di' «basta» per chiudere",
            "Ascolto continuo dal menu: di' «Computer» seguito dal comando (es. «Computer, apri Mail»)",
        ]),
        ("Scrivere", [
            "Con il cursore in un campo di testo, parla e basta: viene scritto",
            "«scrivi …» per forzare la dettatura",
            "«a capo», «invio», «cancella», «cancella parola», «seleziona tutto»",
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
        ]),
        ("Numeri", [
            "«mostra numeri»: un numero su ogni elemento cliccabile della finestra",
            "Poi di' «12» (o «dodici», «clicca 12», «doppio clic 12», «destro 12»)",
            "«nascondi numeri» per toglierli; spariscono anche da soli dopo 30 secondi",
        ]),
        ("Memoria e macro", [
            "«ricorda che il profilo aula IB è il profilo Aulab di Edge»",
            "«apri Edge profilo aula IB», «dimentica il profilo aula IB»",
            "«crea una macro modalità lavoro: apri Slack, apri Mail, apri Visual Studio Code»",
            "Poi basta dire «modalità lavoro». Il file si apre da menu › Memoria e macro…",
        ]),
        ("Voce", [
            "Impostazioni › «Rispondi a voce»: l'app dice a bassa voce com'è andata e ti fa le domande",
        ]),
        ("Sicurezza", [
            "Invio, eliminazione e acquisti chiedono sempre conferma: rispondi «sì»",
            "«stop» interrompe un'azione in corso",
        ]),
    ]

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
