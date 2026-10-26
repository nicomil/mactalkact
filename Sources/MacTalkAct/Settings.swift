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

/// The sections of the settings window (also used by the menu bar).
enum SettingsSection: String, CaseIterable, Identifiable {
    case listening, conversation, understanding, agent, voice, numbers, memory, permissions, status

    var id: String { rawValue }

    var title: String {
        switch self {
        case .listening: return "Ascolto"
        case .conversation: return "Conversazione"
        case .understanding: return "Comprensione"
        case .agent: return "Agente"
        case .voice: return "Voce e suoni"
        case .numbers: return "Numeri"
        case .memory: return "Memoria e macro"
        case .permissions: return "Permessi"
        case .status: return "Stato e diagnostica"
        }
    }

    var icon: String {
        switch self {
        case .listening: return "ear"
        case .conversation: return "bubble.left.and.bubble.right"
        case .understanding: return "brain"
        case .agent: return "sparkles"
        case .voice: return "speaker.wave.2"
        case .numbers: return "number.square"
        case .memory: return "book.closed"
        case .permissions: return "lock.shield"
        case .status: return "stethoscope"
        }
    }
}

/// Every adjustable behaviour of the app (AD-11). Components read these values when they
/// need them, so a change applies from the next action, without restarting.
@MainActor
final class AppSettings: ObservableObject {
    static let shared = AppSettings()
    private let defaults = UserDefaults.standard

    /// Factory values: identical to the constants used before the settings existed (AD-12).
    enum Defaults {
        // Listening
        static let pttKey = PTTKey.rightOption
        static let wakePhrases = "computer, ok computer, ehi computer, hey computer, i computer, e computer"
        static let startListening = false
        static let vadEndSilence = 0.8
        static let vadMinStartRMS = 0.006
        static let vadNoiseFactor = 4.0
        static let vadMaxSegment = 60.0
        static let dictationEndSilence = 1.6
        static let dictationIdleSeconds = 4.0
        static let sessionIdleSeconds = 60.0
        // Conversation
        static let conversationSeconds = 20.0
        static let armedSeconds = 8.0
        static let proposalSeconds = 8.0
        static let agentQuestionSeconds = 25.0
        static let confirmationSeconds = 20.0
        static let conversationMemoryCount = 5
        static let conversationMemoryMinutes = 10.0
        // Understanding
        static let useOnDeviceRouter = true
        static let useLocalLane = true
        static let classifierTimeout = 1.5
        static let localLaneMaxWords = 6
        // Agent
        static let useAI = true
        static let backend = AIBackend.subscription
        static let claudePath = ""
        static let model = "claude-opus-5-5"
        static let fastModel = "claude-sonnet-5-5"
        static let useFastModel = true
        static let deepEffort = "medium"
        static let fastEffort = "low"
        static let agentMaxSteps = 60
        static let agentMaxTurns = 40
        static let agentTimeout = 240.0
        static let confirmValiditySeconds = 45.0
        static let cleanDictation = false
        // Voice and sounds
        static let speakReplies = false
        static let speechVolume = 0.45
        static let speechRate = 1.05
        static let soundsEnabled = true
        static let soundsVolume = 0.2
        static let hudSuccessSeconds = 1.3
        static let hudAnswerSeconds = 5.0
        static let hudErrorSeconds = 4.0
        // Numbers
        static let numbersTimeout = 30.0
        static let numbersLimit = 180
    }

    // MARK: Listening
    @Published var pttKey: PTTKey { didSet { defaults.set(pttKey.rawValue, forKey: "pttKey") } }
    @Published var wakePhrases: String { didSet { defaults.set(wakePhrases, forKey: "wakePhrases") } }
    @Published var startListening: Bool { didSet { defaults.set(startListening, forKey: "startListening") } }
    @Published var vadEndSilence: Double { didSet { defaults.set(vadEndSilence, forKey: "vadEndSilence") } }
    @Published var vadMinStartRMS: Double { didSet { defaults.set(vadMinStartRMS, forKey: "vadMinStartRMS") } }
    @Published var vadNoiseFactor: Double { didSet { defaults.set(vadNoiseFactor, forKey: "vadNoiseFactor") } }
    @Published var vadMaxSegment: Double { didSet { defaults.set(vadMaxSegment, forKey: "vadMaxSegment") } }
    @Published var dictationEndSilence: Double { didSet { defaults.set(dictationEndSilence, forKey: "dictationEndSilence") } }
    @Published var dictationIdleSeconds: Double { didSet { defaults.set(dictationIdleSeconds, forKey: "dictationIdleSeconds") } }
    @Published var sessionIdleSeconds: Double { didSet { defaults.set(sessionIdleSeconds, forKey: "sessionIdleSeconds") } }

    // MARK: Conversation
    /// Seconds the conversation stays open after a response (FR-7).
    @Published var conversationSeconds: Double { didSet { defaults.set(conversationSeconds, forKey: "conversationSeconds") } }
    @Published var armedSeconds: Double { didSet { defaults.set(armedSeconds, forKey: "armedSeconds") } }
    @Published var proposalSeconds: Double { didSet { defaults.set(proposalSeconds, forKey: "proposalSeconds") } }
    @Published var agentQuestionSeconds: Double { didSet { defaults.set(agentQuestionSeconds, forKey: "agentQuestionSeconds") } }
    @Published var confirmationSeconds: Double { didSet { defaults.set(confirmationSeconds, forKey: "confirmationSeconds") } }
    @Published var conversationMemoryCount: Int { didSet { defaults.set(conversationMemoryCount, forKey: "conversationMemoryCount") } }
    @Published var conversationMemoryMinutes: Double { didSet { defaults.set(conversationMemoryMinutes, forKey: "conversationMemoryMinutes") } }

    // MARK: Understanding
    /// Apple's on-device model decides between command, dictation and chatter (FR-3).
    @Published var useOnDeviceRouter: Bool { didSet { defaults.set(useOnDeviceRouter, forKey: "useOnDeviceRouter") } }
    /// One-step commands run locally without the agent (FR-11).
    @Published var useLocalLane: Bool { didSet { defaults.set(useLocalLane, forKey: "useLocalLane") } }
    @Published var classifierTimeout: Double { didSet { defaults.set(classifierTimeout, forKey: "classifierTimeout") } }
    @Published var localLaneMaxWords: Int { didSet { defaults.set(localLaneMaxWords, forKey: "localLaneMaxWords") } }

    // MARK: Agent
    @Published var useAI: Bool { didSet { defaults.set(useAI, forKey: "useAI") } }
    @Published var backend: AIBackend { didSet { defaults.set(backend.rawValue, forKey: "backend") } }
    @Published var claudePath: String { didSet { defaults.set(claudePath, forKey: "claudePath") } }
    /// The deep model (long tasks); `fastModel` serves simple requests (FR-13).
    @Published var model: String { didSet { defaults.set(model, forKey: "model") } }
    @Published var fastModel: String { didSet { defaults.set(fastModel, forKey: "fastModel") } }
    @Published var useFastModel: Bool { didSet { defaults.set(useFastModel, forKey: "useFastModel") } }
    @Published var deepEffort: String { didSet { defaults.set(deepEffort, forKey: "deepEffort") } }
    @Published var fastEffort: String { didSet { defaults.set(fastEffort, forKey: "fastEffort") } }
    @Published var agentMaxSteps: Int { didSet { defaults.set(agentMaxSteps, forKey: "agentMaxSteps") } }
    @Published var agentMaxTurns: Int { didSet { defaults.set(agentMaxTurns, forKey: "agentMaxTurns") } }
    @Published var agentTimeout: Double { didSet { defaults.set(agentTimeout, forKey: "agentTimeout") } }
    @Published var confirmValiditySeconds: Double { didSet { defaults.set(confirmValiditySeconds, forKey: "confirmValiditySeconds") } }
    @Published var cleanDictation: Bool { didSet { defaults.set(cleanDictation, forKey: "cleanDictation") } }

    // MARK: Voice and sounds
    @Published var speakReplies: Bool { didSet { defaults.set(speakReplies, forKey: "speakReplies") } }
    @Published var speechVolume: Double { didSet { defaults.set(speechVolume, forKey: "speechVolume") } }
    @Published var speechRate: Double { didSet { defaults.set(speechRate, forKey: "speechRate") } }
    @Published var soundsEnabled: Bool { didSet { defaults.set(soundsEnabled, forKey: "soundsEnabled") } }
    @Published var soundsVolume: Double { didSet { defaults.set(soundsVolume, forKey: "soundsVolume") } }
    @Published var hudSuccessSeconds: Double { didSet { defaults.set(hudSuccessSeconds, forKey: "hudSuccessSeconds") } }
    @Published var hudAnswerSeconds: Double { didSet { defaults.set(hudAnswerSeconds, forKey: "hudAnswerSeconds") } }
    @Published var hudErrorSeconds: Double { didSet { defaults.set(hudErrorSeconds, forKey: "hudErrorSeconds") } }

    // MARK: Numbers
    @Published var numbersTimeout: Double { didSet { defaults.set(numbersTimeout, forKey: "numbersTimeout") } }
    @Published var numbersLimit: Int { didSet { defaults.set(numbersLimit, forKey: "numbersLimit") } }

    // MARK: Window
    @Published var lastSettingsSection: SettingsSection { didSet { defaults.set(lastSettingsSection.rawValue, forKey: "lastSettingsSection") } }

    private init() {
        let d = UserDefaults.standard
        func double(_ k: String, _ v: Double) -> Double { d.object(forKey: k) as? Double ?? v }
        func int(_ k: String, _ v: Int) -> Int { d.object(forKey: k) as? Int ?? v }
        func bool(_ k: String, _ v: Bool) -> Bool { d.object(forKey: k) as? Bool ?? v }
        func string(_ k: String, _ v: String) -> String { d.string(forKey: k) ?? v }

        pttKey = PTTKey(rawValue: string("pttKey", "")) ?? Defaults.pttKey
        wakePhrases = string("wakePhrases", Defaults.wakePhrases)
        startListening = bool("startListening", Defaults.startListening)
        vadEndSilence = double("vadEndSilence", Defaults.vadEndSilence)
        vadMinStartRMS = double("vadMinStartRMS", Defaults.vadMinStartRMS)
        vadNoiseFactor = double("vadNoiseFactor", Defaults.vadNoiseFactor)
        vadMaxSegment = double("vadMaxSegment", Defaults.vadMaxSegment)
        dictationEndSilence = double("dictationEndSilence", Defaults.dictationEndSilence)
        dictationIdleSeconds = double("dictationIdleSeconds", Defaults.dictationIdleSeconds)
        sessionIdleSeconds = double("sessionIdleSeconds", Defaults.sessionIdleSeconds)

        conversationSeconds = double("conversationSeconds", Defaults.conversationSeconds)
        armedSeconds = double("armedSeconds", Defaults.armedSeconds)
        proposalSeconds = double("proposalSeconds", Defaults.proposalSeconds)
        agentQuestionSeconds = double("agentQuestionSeconds", Defaults.agentQuestionSeconds)
        confirmationSeconds = double("confirmationSeconds", Defaults.confirmationSeconds)
        conversationMemoryCount = int("conversationMemoryCount", Defaults.conversationMemoryCount)
        conversationMemoryMinutes = double("conversationMemoryMinutes", Defaults.conversationMemoryMinutes)

        useOnDeviceRouter = bool("useOnDeviceRouter", Defaults.useOnDeviceRouter)
        useLocalLane = bool("useLocalLane", Defaults.useLocalLane)
        classifierTimeout = double("classifierTimeout", Defaults.classifierTimeout)
        localLaneMaxWords = int("localLaneMaxWords", Defaults.localLaneMaxWords)

        useAI = bool("useAI", Defaults.useAI)
        backend = AIBackend(rawValue: string("backend", "")) ?? Defaults.backend
        claudePath = string("claudePath", Defaults.claudePath)
        model = string("model", Defaults.model)
        fastModel = string("fastModel", Defaults.fastModel)
        useFastModel = bool("useFastModel", Defaults.useFastModel)
        deepEffort = string("deepEffort", Defaults.deepEffort)
        fastEffort = string("fastEffort", Defaults.fastEffort)
        agentMaxSteps = int("agentMaxSteps", Defaults.agentMaxSteps)
        agentMaxTurns = int("agentMaxTurns", Defaults.agentMaxTurns)
        agentTimeout = double("agentTimeout", Defaults.agentTimeout)
        confirmValiditySeconds = double("confirmValiditySeconds", Defaults.confirmValiditySeconds)
        cleanDictation = bool("cleanDictation", Defaults.cleanDictation)

        speakReplies = bool("speakReplies", Defaults.speakReplies)
        speechVolume = double("speechVolume", Defaults.speechVolume)
        speechRate = double("speechRate", Defaults.speechRate)
        soundsEnabled = bool("soundsEnabled", Defaults.soundsEnabled)
        soundsVolume = double("soundsVolume", Defaults.soundsVolume)
        hudSuccessSeconds = double("hudSuccessSeconds", Defaults.hudSuccessSeconds)
        hudAnswerSeconds = double("hudAnswerSeconds", Defaults.hudAnswerSeconds)
        hudErrorSeconds = double("hudErrorSeconds", Defaults.hudErrorSeconds)

        numbersTimeout = double("numbersTimeout", Defaults.numbersTimeout)
        numbersLimit = int("numbersLimit", Defaults.numbersLimit)

        lastSettingsSection = SettingsSection(rawValue: string("lastSettingsSection", "")) ?? .listening
    }

    /// "Ripristina predefiniti": only the keys of one section (AD-12).
    func reset(_ section: SettingsSection) {
        switch section {
        case .listening:
            pttKey = Defaults.pttKey; wakePhrases = Defaults.wakePhrases; startListening = Defaults.startListening
            vadEndSilence = Defaults.vadEndSilence; vadMinStartRMS = Defaults.vadMinStartRMS
            vadNoiseFactor = Defaults.vadNoiseFactor; vadMaxSegment = Defaults.vadMaxSegment
            dictationEndSilence = Defaults.dictationEndSilence; dictationIdleSeconds = Defaults.dictationIdleSeconds
            sessionIdleSeconds = Defaults.sessionIdleSeconds
        case .conversation:
            conversationSeconds = Defaults.conversationSeconds; armedSeconds = Defaults.armedSeconds
            proposalSeconds = Defaults.proposalSeconds; agentQuestionSeconds = Defaults.agentQuestionSeconds
            confirmationSeconds = Defaults.confirmationSeconds; conversationMemoryCount = Defaults.conversationMemoryCount
            conversationMemoryMinutes = Defaults.conversationMemoryMinutes
        case .understanding:
            useOnDeviceRouter = Defaults.useOnDeviceRouter; useLocalLane = Defaults.useLocalLane
            classifierTimeout = Defaults.classifierTimeout; localLaneMaxWords = Defaults.localLaneMaxWords
        case .agent:
            useAI = Defaults.useAI; backend = Defaults.backend; claudePath = Defaults.claudePath
            model = Defaults.model; fastModel = Defaults.fastModel; useFastModel = Defaults.useFastModel
            deepEffort = Defaults.deepEffort; fastEffort = Defaults.fastEffort
            agentMaxSteps = Defaults.agentMaxSteps; agentMaxTurns = Defaults.agentMaxTurns
            agentTimeout = Defaults.agentTimeout; confirmValiditySeconds = Defaults.confirmValiditySeconds
            cleanDictation = Defaults.cleanDictation
        case .voice:
            speakReplies = Defaults.speakReplies; speechVolume = Defaults.speechVolume; speechRate = Defaults.speechRate
            soundsEnabled = Defaults.soundsEnabled; soundsVolume = Defaults.soundsVolume
            hudSuccessSeconds = Defaults.hudSuccessSeconds; hudAnswerSeconds = Defaults.hudAnswerSeconds
            hudErrorSeconds = Defaults.hudErrorSeconds
        case .numbers:
            numbersTimeout = Defaults.numbersTimeout; numbersLimit = Defaults.numbersLimit
        case .memory, .permissions, .status:
            break
        }
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

