import AppKit
import Security
import SwiftUI

enum PTTKey: String, CaseIterable, Identifiable {
    case rightOption, rightCommand, fn

    var id: String { rawValue }

    var label: String {
        switch self {
        case .rightOption: return "Option destro (⌥)"
        case .rightCommand: return "Command destro (⌘)"
        case .fn: return "Fn / 🌐"
        }
    }

    var short: String {
        switch self {
        case .rightOption: return "⌥ destro"
        case .rightCommand: return "⌘ destro"
        case .fn: return "Fn"
        }
    }

    var keyCode: UInt16 {
        switch self {
        case .rightOption: return 61
        case .rightCommand: return 54
        case .fn: return 63
        }
    }

    var flag: NSEvent.ModifierFlags {
        switch self {
        case .rightOption: return .option
        case .rightCommand: return .command
        case .fn: return .function
        }
    }
}

@MainActor
final class AppSettings: ObservableObject {
    static let shared = AppSettings()
    private let defaults = UserDefaults.standard

    @Published var model: String { didSet { defaults.set(model, forKey: "model") } }
    @Published var useAI: Bool { didSet { defaults.set(useAI, forKey: "useAI") } }
    @Published var cleanDictation: Bool { didSet { defaults.set(cleanDictation, forKey: "cleanDictation") } }
    @Published var pttKey: PTTKey { didSet { defaults.set(pttKey.rawValue, forKey: "pttKey") } }
    @Published var wakePhrases: String { didSet { defaults.set(wakePhrases, forKey: "wakePhrases") } }
    @Published var startListening: Bool { didSet { defaults.set(startListening, forKey: "startListening") } }
    @Published var backend: AIBackend { didSet { defaults.set(backend.rawValue, forKey: "backend") } }
    @Published var claudePath: String { didSet { defaults.set(claudePath, forKey: "claudePath") } }
    @Published var speakReplies: Bool { didSet { defaults.set(speakReplies, forKey: "speakReplies") } }
    /// Model for simple agent requests (FR-13); `model` is the deep one.
    @Published var fastModel: String { didSet { defaults.set(fastModel, forKey: "fastModel") } }
    @Published var useFastModel: Bool { didSet { defaults.set(useFastModel, forKey: "useFastModel") } }
    /// Apple's on-device model decides between command, dictation and chatter (FR-3).
    @Published var useOnDeviceRouter: Bool { didSet { defaults.set(useOnDeviceRouter, forKey: "useOnDeviceRouter") } }
    /// One-step commands run locally without the agent (FR-11).
    @Published var useLocalLane: Bool { didSet { defaults.set(useLocalLane, forKey: "useLocalLane") } }
    /// Seconds the conversation stays open after a response (FR-7).
    @Published var conversationSeconds: Double { didSet { defaults.set(conversationSeconds, forKey: "conversationSeconds") } }

    private init() {
        model = defaults.string(forKey: "model") ?? "claude-opus-5-5"
        useAI = defaults.object(forKey: "useAI") as? Bool ?? true
        cleanDictation = defaults.bool(forKey: "cleanDictation")
        pttKey = PTTKey(rawValue: defaults.string(forKey: "pttKey") ?? "") ?? .rightOption
        wakePhrases = defaults.string(forKey: "wakePhrases") ?? "computer, ok computer, ehi computer, hey computer, i computer, e computer"
        startListening = defaults.bool(forKey: "startListening")
        backend = AIBackend(rawValue: defaults.string(forKey: "backend") ?? "") ?? .subscription
        claudePath = defaults.string(forKey: "claudePath") ?? ""
        speakReplies = defaults.bool(forKey: "speakReplies")
        fastModel = defaults.string(forKey: "fastModel") ?? "claude-sonnet-5-5"
        useFastModel = defaults.object(forKey: "useFastModel") as? Bool ?? true
        useOnDeviceRouter = defaults.object(forKey: "useOnDeviceRouter") as? Bool ?? true
        useLocalLane = defaults.object(forKey: "useLocalLane") as? Bool ?? true
        conversationSeconds = defaults.object(forKey: "conversationSeconds") as? Double ?? 20
    }

    /// Path of the `claude` command, if installed (custom path wins).
    var claudeExecutable: String? { ClaudeCLI.locate(custom: claudePath) }

    var wakePhraseList: [String] {
        wakePhrases.split(separator: ",").map { Grammar.normalize(String($0)) }.filter { !$0.isEmpty }
    }

    var firstWakePhrase: String {
        wakePhrases.split(separator: ",").first.map { $0.trimmingCharacters(in: .whitespaces) } ?? "computer"
    }

    var apiKey: String? {
        if let k = Keychain.read(), !k.isEmpty { return k }
        if let k = ProcessInfo.processInfo.environment["ANTHROPIC_API_KEY"], !k.isEmpty { return k }
        return nil
    }

    var aiAvailable: Bool {
        guard useAI else { return false }
        switch backend {
        case .subscription: return claudeExecutable != nil
        case .apiKey: return apiKey != nil
        }
    }
}

/// The API key lives in the login Keychain, never in plain preferences.
enum Keychain {
    private static let service = "local.mactalkact"
    private static let account = "anthropic-api-key"

    static func read() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var out: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess, let data = out as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    @discardableResult
    static func save(_ value: String) -> Bool {
        delete()
        guard !value.isEmpty else { return true }
        let item: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: Data(value.utf8),
        ]
        return SecItemAdd(item as CFDictionary, nil) == errSecSuccess
    }

    static func delete() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
    }
}

struct SettingsView: View {
    @ObservedObject var settings: AppSettings
    @State private var keyField = ""
    @State private var keyStatus = ""

    var body: some View {
        Form {
            Section("Attivazione") {
                Picker("Tasto da tenere premuto per parlare", selection: $settings.pttKey) {
                    ForEach(PTTKey.allCases) { Text($0.label).tag($0) }
                }
                TextField("Frasi di attivazione (separate da virgola)", text: $settings.wakePhrases)
                Toggle("All'avvio resta in ascolto della frase di attivazione", isOn: $settings.startListening)
                Toggle("Rispondi a voce (volume basso): esito dell'agente e sue domande", isOn: $settings.speakReplies)
                Text("Doppio tocco sul tasto: sessione a mani libere (niente frase di attivazione, di' «basta» per chiudere).")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Capire le frasi") {
                Toggle("Usa il modello Apple sul Mac per distinguere comandi, dettatura e chiacchiera", isOn: $settings.useOnDeviceRouter)
                Toggle("Esegui da solo i comandi semplici (nuova scheda, apri un'app), senza Claude", isOn: $settings.useLocalLane)
                Stepper("Conversazione aperta dopo ogni risposta: \(Int(settings.conversationSeconds)) s",
                        value: $settings.conversationSeconds, in: 0...60, step: 5)
                Text("Senza il modello Apple, nei campi di testo l'app chiede «Di' scrivilo» prima di scrivere una frase ambigua.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Claude (richieste libere)") {
                Toggle("Usa Claude per ciò che non è un comando rapido", isOn: $settings.useAI)
                Picker("Modello per i compiti lunghi", selection: $settings.model) {
                    Text("Claude Opus 5.5 (più capace)").tag("claude-opus-5-5")
                    Text("Claude Sonnet 5.5 (equilibrato)").tag("claude-sonnet-5-5")
                    Text("Claude Haiku 5.5 (più veloce ed economico)").tag("claude-haiku-5-5")
                }
                Toggle("Usa un modello più rapido per le richieste semplici", isOn: $settings.useFastModel)
                if settings.useFastModel {
                    Picker("Modello per le richieste semplici", selection: $settings.fastModel) {
                        Text("Claude Sonnet 5.5 (equilibrato)").tag("claude-sonnet-5-5")
                        Text("Claude Haiku 5.5 (più veloce)").tag("claude-haiku-5-5")
                        Text("Claude Opus 5.5 (più capace)").tag("claude-opus-5-5")
                    }
                    Text("Di' «pensaci bene» per usare il modello dei compiti lunghi.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Toggle("Ripulisci anche la dettatura con Claude (più lento)", isOn: $settings.cleanDictation)
                Picker("Accesso a Claude", selection: $settings.backend) {
                    Text("Abbonamento Claude (comando «claude»)").tag(AIBackend.subscription)
                    Text("Chiave API Anthropic").tag(AIBackend.apiKey)
                }
                if settings.backend == .subscription {
                    TextField("Percorso di «claude» (vuoto = automatico)", text: $settings.claudePath)
                    Text(settings.claudeExecutable.map { "Trovato: \($0). Deve aver fatto l'accesso con «claude» almeno una volta." }
                         ?? "Comando «claude» non trovato: installa Claude Code o indica il percorso.")
                        .font(.caption).foregroundStyle(.secondary)
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
        }
        .formStyle(.grouped)
        .frame(width: 560)
        .padding(.vertical, 8)
    }
}
