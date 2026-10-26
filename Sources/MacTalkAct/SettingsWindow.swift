import AppKit
import SwiftUI

/// What the settings window needs from the rest of the app, without owning it.
@MainActor
struct SettingsContext {
    var agentStatus: () -> String = { "—" }
    var routerDescription: () -> String = { "—" }
    var conversationCount: () -> Int = { 0 }
    var clearConversation: () -> Void = {}
    var showHelp: () -> Void = {}
}

/// Builds the settings window. Shared by the app and by `--settings-shot`.
@MainActor
enum SettingsWindowFactory {
    static func make(settings: AppSettings, context: SettingsContext) -> NSWindow {
        let host = NSHostingController(rootView: SettingsRootView(settings: settings, context: context))
        let w = NSWindow(contentViewController: host)
        w.title = "MacTalkAct – Impostazioni"
        w.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
        w.toolbarStyle = .unified
        w.isReleasedWhenClosed = false
        // A grouped Form has no ideal height of its own: without an explicit size the window
        // opened with only its title bar.
        w.setContentSize(NSSize(width: 880, height: 620))
        w.contentMinSize = NSSize(width: 760, height: 520)
        w.setFrameAutosaveName("MacTalkActSettings")
        return w
    }
}

// MARK: - Root

struct SettingsRootView: View {
    @ObservedObject var settings: AppSettings
    let context: SettingsContext
    @State private var selection: SettingsSection?

    var body: some View {
        NavigationSplitView {
            List(SettingsSection.allCases, selection: $selection) { section in
                Label(section.title, systemImage: section.icon).tag(section)
            }
            .navigationSplitViewColumnWidth(min: 190, ideal: 210, max: 260)
        } detail: {
            let section = selection ?? settings.lastSettingsSection
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    SectionContent(section: section, settings: settings, context: context)
                }
                .frame(maxWidth: 640, alignment: .leading)
                .padding(.horizontal, 28)
                .padding(.vertical, 22)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .navigationTitle(section.title)
        }
        .frame(minWidth: 760, minHeight: 520)
        .onAppear { selection = settings.lastSettingsSection }
        .onChange(of: settings.lastSettingsSection) { _, new in if selection != new { selection = new } }
        .onChange(of: selection) { _, new in if let new, new != settings.lastSettingsSection { settings.lastSettingsSection = new } }
    }
}

private struct SectionContent: View {
    let section: SettingsSection
    @ObservedObject var settings: AppSettings
    let context: SettingsContext

    var body: some View {
        switch section {
        case .listening: ListeningSection(settings: settings)
        case .conversation: ConversationSection(settings: settings, context: context)
        case .understanding: UnderstandingSection(settings: settings)
        case .agent: AgentSection(settings: settings)
        case .voice: VoiceSection(settings: settings)
        case .numbers: NumbersSection(settings: settings)
        case .memory: MemorySection(context: context)
        case .permissions: PermissionsSection()
        case .status: StatusSection(settings: settings, context: context)
        }
    }
}

// MARK: - Building blocks

/// A titled card, like the groups in System Settings.
private struct Card<Content: View>: View {
    let title: String
    var footer: String = ""
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.headline)
            VStack(alignment: .leading, spacing: 14) { content }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.background.secondary, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            if !footer.isEmpty {
                Text(footer).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.bottom, 22)
    }
}

/// A number with a slider, its value and a short explanation.
private struct NumberRow: View {
    let title: String
    var help: String = ""
    @Binding var value: Double
    let range: ClosedRange<Double>
    var step: Double = 1
    var unit: String = "s"
    var decimals: Int = 1
    var defaultValue: Double?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title)
                Spacer()
                Slider(value: $value, in: range, step: step).frame(width: 200)
                Text(formatted).monospacedDigit().frame(width: 72, alignment: .trailing)
            }
            if !help.isEmpty || defaultValue != nil {
                Text(caption).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func format(_ v: Double) -> String {
        let n = String(format: "%.\(decimals)f", v).replacingOccurrences(of: ".", with: ",")
        return unit.isEmpty ? n : "\(n) \(unit)"
    }

    private var formatted: String { format(value) }

    private var caption: String {
        var parts: [String] = []
        if !help.isEmpty { parts.append(help) }
        if let d = defaultValue { parts.append("Predefinito: \(format(d)).") }
        return parts.joined(separator: " ")
    }
}

private struct IntRow: View {
    let title: String
    var help: String = ""
    @Binding var value: Int
    let range: ClosedRange<Int>
    var step: Int = 1
    var unit: String = ""
    var defaultValue: Int?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title)
                Spacer()
                Stepper(value: $value, in: range, step: step) {
                    Text(unit.isEmpty ? "\(value)" : "\(value) \(unit)").monospacedDigit()
                }
            }
            if !help.isEmpty || defaultValue != nil {
                Text([help, defaultValue.map { "Predefinito: \($0)\(unit.isEmpty ? "" : " " + unit)." } ?? ""]
                        .filter { !$0.isEmpty }.joined(separator: " "))
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

private struct ToggleRow: View {
    let title: String
    var help: String = ""
    @Binding var isOn: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Toggle(isOn: $isOn) { Text(title) }.toggleStyle(.switch)
            if !help.isEmpty {
                Text(help).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

private struct ResetButton: View {
    let section: SettingsSection
    let settings: AppSettings

    var body: some View {
        HStack {
            Spacer()
            Button("Ripristina predefiniti") { settings.reset(section) }
        }
    }
}

private typealias D = AppSettings.Defaults

// MARK: - Sections

private struct ListeningSection: View {
    @ObservedObject var settings: AppSettings

    var body: some View {
        Card(title: "Attivazione",
             footer: "Doppio tocco sul tasto: sessione a mani libere, senza parola di attivazione. Se scegli Fn, imposta prima Tastiera › «Premi il tasto 🌐 per» › «Non fare nulla».") {
            Picker("Tasto da tenere premuto per parlare", selection: $settings.pttKey) {
                ForEach(PTTKey.allCases) { Text($0.label).tag($0) }
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("Parole di attivazione, separate da virgola")
                TextField("computer, ok computer", text: $settings.wakePhrases)
                Text("La prima è quella mostrata nei suggerimenti. Le varianti servono quando il riconoscimento capisce «i computer» o «e computer».")
                    .font(.caption).foregroundStyle(.secondary)
            }
            ToggleRow(title: "All'avvio resta in ascolto della parola di attivazione", isOn: $settings.startListening)
        }
        Card(title: "Frasi") {
            NumberRow(title: "Silenzio che chiude una frase", help: "Più corto risponde prima, ma può tagliare chi parla con pause.",
                      value: $settings.vadEndSilence, range: 0.3...2.0, step: 0.1, defaultValue: D.vadEndSilence)
            NumberRow(title: "Durata massima di una frase", value: $settings.vadMaxSegment, range: 10...120, step: 5,
                      decimals: 0, defaultValue: D.vadMaxSegment)
        }
        Card(title: "Dettatura lunga («scrivi», «detta»)") {
            NumberRow(title: "Pausa tra le frasi dettate", help: "Durante la dettatura lunga si possono fare pause più lunghe senza chiudere la frase.",
                      value: $settings.dictationEndSilence, range: 0.8...3.0, step: 0.1, defaultValue: D.dictationEndSilence)
            NumberRow(title: "Silenzio che chiude la dettatura", value: $settings.dictationIdleSeconds, range: 2...15, step: 1,
                      decimals: 0, defaultValue: D.dictationIdleSeconds)
        }
        Card(title: "Sessione a mani libere") {
            NumberRow(title: "Si chiude dopo un silenzio di", value: $settings.sessionIdleSeconds, range: 15...300, step: 15,
                      decimals: 0, defaultValue: D.sessionIdleSeconds)
        }
        Card(title: "Avanzate: rilevatore di voce",
             footer: "Valori sbagliati possono rendere l'ascolto sordo o troppo sensibile: in caso di dubbio usa «Ripristina predefiniti».") {
            NumberRow(title: "Soglia minima della voce", help: "Più bassa sente anche le voci deboli, ma anche più rumore.",
                      value: $settings.vadMinStartRMS, range: 0.002...0.03, step: 0.001, unit: "", decimals: 3, defaultValue: D.vadMinStartRMS)
            NumberRow(title: "Quanto la voce deve superare il rumore di fondo", help: "In una stanza rumorosa conviene alzarlo.",
                      value: $settings.vadNoiseFactor, range: 2...8, step: 0.5, unit: "×", defaultValue: D.vadNoiseFactor)
        }
        ResetButton(section: .listening, settings: settings)
    }
}

private struct ConversationSection: View {
    @ObservedObject var settings: AppSettings
    let context: SettingsContext
    @State private var cleared = false

    var body: some View {
        Card(title: "Finestra di conversazione",
             footer: "Dopo ogni risposta puoi continuare senza ripetere la parola di attivazione; la chiacchiera con chi è nella stanza viene ignorata. 0 la disattiva.") {
            NumberRow(title: "Resta aperta per", value: $settings.conversationSeconds, range: 0...60, step: 5, decimals: 0,
                      defaultValue: D.conversationSeconds)
        }
        Card(title: "Attese") {
            NumberRow(title: "Ascolto dopo «\(settings.firstWakePhrase)» da solo", value: $settings.armedSeconds, range: 3...30,
                      step: 1, decimals: 0, defaultValue: D.armedSeconds)
            NumberRow(title: "Proposta «scrivilo»", help: "Quanto resta valida una frase che l'app non ha scritto perché incerta.",
                      value: $settings.proposalSeconds, range: 3...30, step: 1, decimals: 0, defaultValue: D.proposalSeconds)
            NumberRow(title: "Risposta a una domanda dell'agente", value: $settings.agentQuestionSeconds, range: 10...60, step: 5,
                      decimals: 0, defaultValue: D.agentQuestionSeconds)
            NumberRow(title: "Conferma di un'azione («sì»)", value: $settings.confirmationSeconds, range: 10...60, step: 5,
                      decimals: 0, defaultValue: D.confirmationSeconds)
        }
        Card(title: "Memoria di conversazione",
             footer: "Le ultime cose fatte, passate all'agente per capire «rimetti com'era prima». Vive solo in memoria: non viene mai salvata su disco.") {
            IntRow(title: "Interazioni ricordate", value: $settings.conversationMemoryCount, range: 1...10, defaultValue: D.conversationMemoryCount)
            NumberRow(title: "Dimenticate dopo", value: $settings.conversationMemoryMinutes, range: 1...60, step: 1, unit: "min",
                      decimals: 0, defaultValue: D.conversationMemoryMinutes)
            HStack {
                Text(cleared ? "Memoria svuotata" : "Adesso contiene \(context.conversationCount()) interazioni")
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Svuota ora") { context.clearConversation(); cleared = true }
            }
        }
        ResetButton(section: .conversation, settings: settings)
    }
}

private struct UnderstandingSection: View {
    @ObservedObject var settings: AppSettings

    var body: some View {
        Card(title: "Come l'app capisce le frasi",
             footer: OnDeviceClassifier.isAvailable
                ? "Il modello Apple è disponibile su questo Mac."
                : "Il modello Apple non è disponibile (serve Apple Intelligence attiva): l'app usa regole prudenti e chiede «scrivilo» quando è incerta.") {
            ToggleRow(title: "Usa il modello Apple sul Mac per distinguere comandi, dettatura e chiacchiera",
                      help: "Funziona offline e non consuma la subscription. Senza, nei campi di testo l'app chiede «scrivilo» prima di scrivere una frase ambigua.",
                      isOn: $settings.useOnDeviceRouter)
            NumberRow(title: "Tempo massimo per decidere", help: "Oltre questo tempo la frase è considerata incerta e non viene scritta.",
                      value: $settings.classifierTimeout, range: 0.5...5, step: 0.25, decimals: 2, defaultValue: D.classifierTimeout)
        }
        Card(title: "Corsia locale ⚡️",
             footer: "Comandi di un solo passo (nuova scheda, schermo intero, apri un'app o un sito) eseguiti dal modello Apple, controllati da regole fisse, senza Claude. Mai dentro un campo di testo.") {
            ToggleRow(title: "Esegui da solo i comandi semplici", isOn: $settings.useLocalLane)
            IntRow(title: "Frasi lunghe al massimo", help: "Le frasi più lunghe vanno direttamente all'agente, risparmiando circa un secondo.",
                   value: $settings.localLaneMaxWords, range: 2...12, unit: "parole", defaultValue: D.localLaneMaxWords)
        }
        ResetButton(section: .understanding, settings: settings)
    }
}

private struct AgentSection: View {
    @ObservedObject var settings: AppSettings
    @State private var keyField = ""
    @State private var keyStatus = ""
    @State private var claudeFound: String?

    private let models: [(String, String)] = [
        ("claude-opus-5-5", "Claude Opus 5.5 (più capace)"),
        ("claude-sonnet-5-5", "Claude Sonnet 5.5 (equilibrato)"),
        ("claude-haiku-5-5", "Claude Haiku 5.5 (più veloce)"),
    ]
    private let efforts: [(String, String)] = [("low", "Basso"), ("medium", "Medio"), ("high", "Alto")]

    var body: some View {
        Card(title: "Accesso a Claude") {
            ToggleRow(title: "Usa Claude per ciò che non è un comando rapido o una dettatura", isOn: $settings.useAI)
            Picker("Accesso", selection: $settings.backend) {
                Text("Abbonamento Claude (comando «claude»)").tag(AIBackend.subscription)
                Text("Chiave API Anthropic").tag(AIBackend.apiKey)
            }
            if settings.backend == .subscription {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Percorso del comando «claude»")
                    TextField("vuoto = cerca da solo", text: $settings.claudePath)
                    Text(claudeFound.map { "Trovato: \($0). Deve aver fatto l'accesso con «claude» almeno una volta." }
                         ?? "Comando «claude» non trovato: installa Claude Code o indica il percorso.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            } else {
                HStack {
                    SecureField("Chiave API Anthropic (sk-ant-…)", text: $keyField)
                    Button("Salva") {
                        let ok = Keychain.save(keyField.trimmingCharacters(in: .whitespacesAndNewlines))
                        keyStatus = ok ? "Chiave salvata nel Portachiavi" : "Errore nel salvataggio"
                        keyField = ""
                    }
                }
                Text(keyStatus.isEmpty ? (settings.apiKey == nil ? "Nessuna chiave: funzionano solo comandi rapidi e dettatura." : "Chiave presente.") : keyStatus)
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .onAppear { claudeFound = settings.claudeExecutable }
        .onChange(of: settings.claudePath) { _, _ in claudeFound = settings.claudeExecutable }

        Card(title: "Modelli",
             footer: "Le richieste semplici usano il modello rapido; quelle lunghe (più passi, mail, ricerche) il modello per i compiti lunghi. Di' «pensaci bene» per forzarlo. Cambiare modello o effort riavvia il processo di Claude tenuto pronto.") {
            Picker("Compiti lunghi", selection: $settings.model) { ForEach(models, id: \.0) { Text($0.1).tag($0.0) } }
            Picker("Effort dei compiti lunghi", selection: $settings.deepEffort) { ForEach(efforts, id: \.0) { Text($0.1).tag($0.0) } }
                .pickerStyle(.segmented)
            ToggleRow(title: "Usa un modello più rapido per le richieste semplici", isOn: $settings.useFastModel)
            if settings.useFastModel {
                Picker("Richieste semplici", selection: $settings.fastModel) { ForEach(models, id: \.0) { Text($0.1).tag($0.0) } }
                Picker("Effort delle richieste semplici", selection: $settings.fastEffort) { ForEach(efforts, id: \.0) { Text($0.1).tag($0.0) } }
                    .pickerStyle(.segmented)
            }
        }
        Card(title: "Limiti di un compito") {
            IntRow(title: "Passi massimi (azioni dell'agente)", value: $settings.agentMaxSteps, range: 10...150, step: 5,
                   defaultValue: D.agentMaxSteps)
            IntRow(title: "Turni massimi di Claude", value: $settings.agentMaxTurns, range: 10...100, step: 5, defaultValue: D.agentMaxTurns)
            NumberRow(title: "Tempo massimo", value: $settings.agentTimeout, range: 60...600, step: 30, decimals: 0,
                      defaultValue: D.agentTimeout)
            NumberRow(title: "Dopo un «sì», azioni rischiose consentite per",
                      help: "Inviare, eliminare, comprare: senza conferma recente l'app le blocca.",
                      value: $settings.confirmValiditySeconds, range: 10...120, step: 5, decimals: 0,
                      defaultValue: D.confirmValiditySeconds)
        }
        Card(title: "Dettatura") {
            ToggleRow(title: "Ripulisci la dettatura con Claude (più lento)",
                      help: "Toglie intercalari e corregge la punteggiatura prima di scrivere.", isOn: $settings.cleanDictation)
        }
        ResetButton(section: .agent, settings: settings)
    }
}

private struct VoiceSection: View {
    @ObservedObject var settings: AppSettings

    var body: some View {
        Card(title: "Risposte a voce", footer: "L'app pronuncia l'esito dell'agente e le sue domande. Mentre parla non ascolta; «stop» la interrompe.") {
            ToggleRow(title: "Rispondi a voce", isOn: $settings.speakReplies)
            NumberRow(title: "Volume", value: $settings.speechVolume, range: 0.1...1, step: 0.05, unit: "", decimals: 2,
                      defaultValue: D.speechVolume)
            NumberRow(title: "Velocità", value: $settings.speechRate, range: 0.6...1.6, step: 0.05, unit: "×", decimals: 2,
                      defaultValue: D.speechRate)
        }
        Card(title: "Suoni", footer: "Suoni brevi quando l'app ascolta, chiede conferma o sbaglia. Bassi apposta, per non svegliare nessuno.") {
            ToggleRow(title: "Suoni", isOn: $settings.soundsEnabled)
            NumberRow(title: "Volume dei suoni", value: $settings.soundsVolume, range: 0.05...1, step: 0.05, unit: "", decimals: 2,
                      defaultValue: D.soundsVolume)
        }
        Card(title: "Messaggi sullo schermo") {
            NumberRow(title: "Azione riuscita", value: $settings.hudSuccessSeconds, range: 0.5...5, step: 0.1, defaultValue: D.hudSuccessSeconds)
            NumberRow(title: "Risposta dell'agente", value: $settings.hudAnswerSeconds, range: 2...15, step: 0.5, defaultValue: D.hudAnswerSeconds)
            NumberRow(title: "Errore", value: $settings.hudErrorSeconds, range: 2...10, step: 0.5, defaultValue: D.hudErrorSeconds)
        }
        ResetButton(section: .voice, settings: settings)
    }
}

private struct NumbersSection: View {
    @ObservedObject var settings: AppSettings

    var body: some View {
        Card(title: "«Mostra numeri»", footer: "Un numero su ogni elemento cliccabile della finestra; poi di' il numero da cliccare.") {
            NumberRow(title: "Spariscono dopo", value: $settings.numbersTimeout, range: 10...120, step: 5, decimals: 0,
                      defaultValue: D.numbersTimeout)
            IntRow(title: "Numeri al massimo", value: $settings.numbersLimit, range: 50...400, step: 10, defaultValue: D.numbersLimit)
        }
        ResetButton(section: .numbers, settings: settings)
    }
}

private struct MemorySection: View {
    let context: SettingsContext
    @State private var facts: [String] = []
    @State private var macros: [Memory.Macro] = []

    private func reload() {
        let m = Memory.shared
        m.reload()
        facts = m.facts
        macros = m.macros
    }

    var body: some View {
        Card(title: "Fatti ricordati",
             footer: "Si aggiungono a voce: «ricorda che il profilo aula IB è il profilo Aulab di Edge». L'agente li usa per capirti.") {
            if facts.isEmpty {
                Text("Nessun fatto salvato.").foregroundStyle(.secondary)
            }
            ForEach(facts, id: \.self) { fact in
                HStack(alignment: .top) {
                    Text(fact).fixedSize(horizontal: false, vertical: true)
                    Spacer()
                    Button(role: .destructive) { Memory.shared.forget(fact); reload() } label: { Image(systemName: "trash") }
                        .buttonStyle(.borderless).help("Dimentica")
                }
            }
        }
        Card(title: "Macro vocali",
             footer: "Si creano a voce: «crea una macro modalità lavoro: apri Slack, apri Mail». Poi basta dirne il nome.") {
            if macros.isEmpty {
                Text("Nessuna macro.").foregroundStyle(.secondary)
            }
            ForEach(macros, id: \.name) { macro in
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("«\(macro.name)»").fontWeight(.medium)
                        Text(macro.steps.joined(separator: " → ")).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button(role: .destructive) { Memory.shared.deleteMacro(macro.name); reload() } label: { Image(systemName: "trash") }
                        .buttonStyle(.borderless).help("Elimina la macro")
                }
            }
        }
        HStack {
            Button("Apri il file della memoria") { Memory.shared.openInEditor() }
            Button("Ricarica") { reload() }
            Spacer()
            Button("Svuota la memoria di conversazione") { context.clearConversation() }
        }
        .onAppear { reload() }
    }
}

private struct PermissionsSection: View {
    var body: some View {
        TimelineView(.periodic(from: .now, by: 2)) { _ in
            Card(title: "Permessi di macOS", footer: "Lo stato si aggiorna da solo. Dopo aver concesso la Registrazione schermo, riapri l'app.") {
                PermissionRow(title: "Accessibilità", detail: "Leggere lo schermo, premere tasti e cliccare.",
                              granted: Permissions.accessibility) {
                    Permissions.promptAccessibility()
                    Permissions.openAccessibilitySettings()
                }
                PermissionRow(title: "Microfono", detail: "Ascoltare la voce. Il riconoscimento avviene sul Mac.",
                              granted: Permissions.microphone) { Permissions.openMicrophoneSettings() }
                PermissionRow(title: "Registrazione schermo", detail: "Screenshot della finestra per l'agente, solo durante un compito.",
                              granted: ScreenCapture.hasPermission) {
                    ScreenCapture.requestPermission()
                    Permissions.openScreenRecordingSettings()
                }
            }
        }
    }
}

private struct PermissionRow: View {
    let title: String
    let detail: String
    let granted: Bool
    let action: () -> Void

    var body: some View {
        HStack(alignment: .top) {
            Image(systemName: granted ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                .foregroundStyle(granted ? .green : .orange).font(.title3)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).fontWeight(.medium)
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if granted {
                Text("Concesso").foregroundStyle(.secondary)
            } else {
                Button("Concedi…", action: action)
            }
        }
    }
}

private struct StatusSection: View {
    @ObservedObject var settings: AppSettings
    let context: SettingsContext
    @State private var claudePath: String?

    private var version: String {
        let info = Bundle.main.infoDictionary
        let v = info?["CFBundleShortVersionString"] as? String ?? "sviluppo"
        let b = info?["CFBundleVersion"] as? String ?? ""
        return b.isEmpty ? v : "\(v) (\(b))"
    }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 2)) { _ in
            Card(title: "Componenti") {
                StatusRow(title: "Modello Apple sul Mac", value: OnDeviceClassifier.isAvailable ? "Disponibile" : "Non disponibile",
                          ok: OnDeviceClassifier.isAvailable)
                StatusRow(title: "Router", value: context.routerDescription(), ok: true)
                StatusRow(title: "Comando «claude»", value: claudePath ?? "Non trovato", ok: claudePath != nil)
                StatusRow(title: "Agente", value: context.agentStatus(), ok: context.agentStatus().hasPrefix("Disponibile"))
                StatusRow(title: "Versione", value: version, ok: true)
            }
        }
        .onAppear { claudePath = settings.claudeExecutable }
        Card(title: "Diagnostica",
             footer: "Il log mostra, per ogni frase, la decisione presa e il motivo («Instradamento: …»). Le chiacchiere non vengono salvate, solo la loro lunghezza.") {
            HStack {
                Button("Apri il log") { NSWorkspace.shared.open(Log.fileURL) }
                Button("Mostra nel Finder") { NSWorkspace.shared.activateFileViewerSelecting([Log.fileURL]) }
                Button("Cartella dei dati") { NSWorkspace.shared.open(Memory.shared.fileURL.deletingLastPathComponent()) }
                Spacer()
                Button("Guida ai comandi…") { context.showHelp() }
            }
        }
    }
}

private struct StatusRow: View {
    let title: String
    let value: String
    let ok: Bool

    var body: some View {
        HStack {
            Image(systemName: ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill").foregroundStyle(ok ? .green : .orange)
            Text(title)
            Spacer()
            Text(value).foregroundStyle(.secondary).multilineTextAlignment(.trailing).textSelection(.enabled)
        }
    }
}
