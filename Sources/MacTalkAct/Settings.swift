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
    case listening, conversation, understanding, agent, voice, numbers, memory, privacy, permissions, status

    var id: String { rawValue }

    var title: String {
        switch self {
        case .listening: return "Ascolto"
        case .conversation: return "Conversazione"
        case .understanding: return "Comprensione"
        case .agent: return "Motori"
        case .voice: return "Voce e suoni"
        case .numbers: return "Numeri"
        case .memory: return "Memoria e macro"
        case .privacy: return "Privacy"
        case .permissions: return "Permessi"
        case .status: return "Stato e diagnostica"
        }
    }

    var icon: String {
        switch self {
        case .listening: return "ear"
        case .conversation: return "bubble.left.and.bubble.right"
        case .understanding: return "brain"
        case .agent: return "cpu"
        case .voice: return "speaker.wave.2"
        case .numbers: return "number.square"
        case .memory: return "book.closed"
        case .privacy: return "hand.raised"
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
        static let wakeWord = "computer"
        static let wakeVariants = true
        static let extraWakePhrases = ""
        /// Before Story 3.7 the list was stored as is: still read to migrate a customised one.
        static let legacyWakePhrases = "computer, ok computer, ehi computer, hey computer, i computer, e computer"
        /// Prefixes added to the wake word: polite forms and what the recogniser hears instead ("i computer").
        static let wakePrefixes = ["ok", "ehi", "hey", "i", "e"]
        static let startListening = false
        static let vadEndSilence = 0.8
        static let vadMinStartRMS = 0.006
        static let vadNoiseFactor = 4.0
        static let vadMaxSegment = 60.0
        static let dictationEndSilence = 1.6
        static let dictationIdleSeconds = 4.0
        static let sessionIdleSeconds = 60.0
        /// «Attenzione dalla fotocamera»: off until Nico turns it on.
        static let headAttention = false
        /// «Conferma con un sì della testa»: off, and shown only after a check passed.
        static let headYesConfirms = false
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
        /// Long session of Claude (FR-42): one process kept open between requests.
        static let longSession = true
        static let sessionMaxRequests = 8
        /// Story 11.2 (FR-59): the Long sessions start when the wake phrase is heard or the key is pressed.
        static let prepareSessionOnWake = true
        /// Instant level (FR-43): one-step commands with a known target.
        static let instantLevel = true
        static let instantModel = "claude-haiku-5-5"
        static let instantEffort = "low"
        /// Screen reading at fixed cost (FR-44).
        static let fixedCostObservation = true
        static let riskClassifier = true
        /// The agent names the evidence before saying «fatto» (FR-46).
        static let evidenceBeforeDone = true
        /// Story 11.4 (NFR-15): a verified last action ends the turn, the app writes the answer.
        static let quickReplies = true
        static let cleanDictation = false
        // Engines (Epic 4-5)
        static let agentEngine = EngineID.claude
        static let engineFallback = true
        static let codexPath = ""
        static let approvedCodexInstructions = ""
        static let codexModel = "gpt-6.1-sol"
        static let codexFastModel = "gpt-6-luna"
        static let codexDeepEffort = "medium"
        static let codexFastEffort = "low"
        static let localMaxSteps = 8
        static let localProvider = LocalProvider.apple
        static let localServerURL = "http://127.0.0.1:11434/v1"
        static let localServerModel = ""
        static let localKeepAliveMinutes = 10.0
        static let localServerAllowRemote = false
        // Voice and sounds
        static let speakReplies = false
        static let speechVolume = 0.45
        static let speechRate = 1.05
        static let soundsEnabled = true
        static let soundsVolume = 0.2
        static let hudSuccessSeconds = 1.3
        static let hudAnswerSeconds = 5.0
        static let hudErrorSeconds = 4.0
        static let hudPosition = HUDPosition.auto
        static let hudCompact = true
        // Numbers
        static let numbersTimeout = 30.0
        static let numbersLimit = 180
        // Privacy
        static let privateModeMinutes = 30.0
        static let reservedApps = Privacy.defaultReservedApps
        static let reservedSites = Privacy.defaultReservedSites
        /// Access levels per app (FR-54).
        static let accessLevels = AccessLevel.defaultList
        static let hideSensitiveFromCloud = true
        static let logRetentionDays = 7
        static let detailedLog = false
    }

    // MARK: Listening
    @Published var pttKey: PTTKey { didSet { defaults.set(pttKey.rawValue, forKey: "pttKey") } }
    /// The word that wakes the app ("computer", or what the user chooses).
    @Published var wakeWord: String { didSet { defaults.set(wakeWord, forKey: "wakeWord") } }
    /// Also accept "ok …", "ehi …", "hey …" and the recogniser's "i …", "e …".
    @Published var wakeVariants: Bool { didSet { defaults.set(wakeVariants, forKey: "wakeVariants") } }
    /// More phrases, comma separated.
    @Published var extraWakePhrases: String { didSet { defaults.set(extraWakePhrases, forKey: "extraWakePhrases") } }
    @Published var startListening: Bool { didSet { defaults.set(startListening, forKey: "startListening") } }
    @Published var vadEndSilence: Double { didSet { defaults.set(vadEndSilence, forKey: "vadEndSilence") } }
    @Published var vadMinStartRMS: Double { didSet { defaults.set(vadMinStartRMS, forKey: "vadMinStartRMS") } }
    @Published var vadNoiseFactor: Double { didSet { defaults.set(vadNoiseFactor, forKey: "vadNoiseFactor") } }
    @Published var vadMaxSegment: Double { didSet { defaults.set(vadMaxSegment, forKey: "vadMaxSegment") } }
    @Published var dictationEndSilence: Double { didSet { defaults.set(dictationEndSilence, forKey: "dictationEndSilence") } }
    @Published var dictationIdleSeconds: Double { didSet { defaults.set(dictationIdleSeconds, forKey: "dictationIdleSeconds") } }
    @Published var sessionIdleSeconds: Double { didSet { defaults.set(sessionIdleSeconds, forKey: "sessionIdleSeconds") } }
    /// While continuous listening is on, the camera ignores the Frasi said turned to the room and
    /// sees a «no» with the head (research §40).
    @Published var headAttention: Bool { didSet { defaults.set(headAttention, forKey: "headAttention") } }
    /// The calibrated «looking at the screen» pose (yaw, pitch in degrees). Only two angles.
    @Published var headReference: HeadPose? {
        didSet { defaults.set(headReference.map { [$0.yaw, $0.pitch] }, forKey: "headReference") }
    }
    /// When the reference was calibrated, shown in the settings.
    @Published var headCalibratedAt: Date? { didSet { defaults.set(headCalibratedAt, forKey: "headCalibratedAt") } }
    /// Personal thresholds from «Calibrazione completa». Nil: the defaults of the spike.
    @Published var headProfile: HeadProfile? {
        didSet { defaults.set(headProfile.flatMap { try? JSONEncoder().encode($0) }, forKey: "headProfile") }
    }
    /// The «sì» with the head writes the «scrivilo» proposal. Works only with `headProfile.yesVerified`.
    @Published var headYesConfirms: Bool { didSet { defaults.set(headYesConfirms, forKey: "headYesConfirms") } }

    /// Saves a guided calibration: profile, reference and date. A «sì» that did not pass the check
    /// turns the option off, even if it was on with an older profile.
    func saveHeadProfile(_ profile: HeadProfile, reference: HeadPose) {
        headProfile = profile
        headReference = reference
        headCalibratedAt = profile.date
        if !profile.yesVerified { headYesConfirms = false }
    }

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
    @Published var longSession: Bool { didSet { defaults.set(longSession, forKey: "longSession") } }
    @Published var sessionMaxRequests: Int { didSet { defaults.set(sessionMaxRequests, forKey: "sessionMaxRequests") } }
    @Published var prepareSessionOnWake: Bool { didSet { defaults.set(prepareSessionOnWake, forKey: "prepareSessionOnWake") } }
    @Published var instantLevel: Bool { didSet { defaults.set(instantLevel, forKey: "instantLevel") } }
    @Published var instantModel: String { didSet { defaults.set(instantModel, forKey: "instantModel") } }
    @Published var instantEffort: String { didSet { defaults.set(instantEffort, forKey: "instantEffort") } }
    @Published var fixedCostObservation: Bool { didSet { defaults.set(fixedCostObservation, forKey: "fixedCostObservation") } }
    /// The on-device model as a second safety layer (Story 9.5): it may only add confirmations.
    @Published var riskClassifier: Bool { didSet { defaults.set(riskClassifier, forKey: "riskClassifier") } }
    @Published var evidenceBeforeDone: Bool { didSet { defaults.set(evidenceBeforeDone, forKey: "evidenceBeforeDone") } }
    /// «Risposte rapide» (Story 11.4): the app writes the answer from a verified outcome of the last action.
    @Published var quickReplies: Bool { didSet { defaults.set(quickReplies, forKey: "quickReplies") } }
    @Published var cleanDictation: Bool { didSet { defaults.set(cleanDictation, forKey: "cleanDictation") } }

    // MARK: Engines
    /// The engine chosen by the user (FR-25).
    @Published var agentEngine: EngineID { didSet { defaults.set(agentEngine.rawValue, forKey: "agentEngine") } }
    /// Use the other engines when the chosen one is not available (FR-27).
    @Published var engineFallback: Bool { didSet { defaults.set(engineFallback, forKey: "engineFallback") } }
    @Published var codexPath: String { didSet { defaults.set(codexPath, forKey: "codexPath") } }
    /// SHA-256 of the texts of `~/.codex/AGENTS.md` the user approved, one per line (FR-50).
    @Published var approvedCodexInstructions: String { didSet { defaults.set(approvedCodexInstructions, forKey: "approvedCodexInstructions") } }
    var approvedCodexInstructionSet: Set<String> {
        Set(approvedCodexInstructions.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) })
    }
    @Published var codexModel: String { didSet { defaults.set(codexModel, forKey: "codexModel") } }
    @Published var codexFastModel: String { didSet { defaults.set(codexFastModel, forKey: "codexFastModel") } }
    @Published var codexDeepEffort: String { didSet { defaults.set(codexDeepEffort, forKey: "codexDeepEffort") } }
    @Published var codexFastEffort: String { didSet { defaults.set(codexFastEffort, forKey: "codexFastEffort") } }
    /// Step limit of the local engine, lower than the cloud one (FR-30).
    @Published var localMaxSteps: Int { didSet { defaults.set(localMaxSteps, forKey: "localMaxSteps") } }
    /// Apple's model, or a bigger model served on the Mac (FR-31).
    @Published var localProvider: LocalProvider { didSet { defaults.set(localProvider.rawValue, forKey: "localProvider") } }
    @Published var localServerURL: String { didSet { defaults.set(localServerURL, forKey: "localServerURL") } }
    @Published var localServerModel: String { didSet { defaults.set(localServerModel, forKey: "localServerModel") } }
    @Published var localKeepAliveMinutes: Double { didSet { defaults.set(localKeepAliveMinutes, forKey: "localKeepAliveMinutes") } }
    /// The user confirmed that a server outside this Mac may receive the screen (NFR-10).
    @Published var localServerAllowRemote: Bool { didSet { defaults.set(localServerAllowRemote, forKey: "localServerAllowRemote") } }

    // MARK: Voice and sounds
    @Published var speakReplies: Bool { didSet { defaults.set(speakReplies, forKey: "speakReplies") } }
    @Published var speechVolume: Double { didSet { defaults.set(speechVolume, forKey: "speechVolume") } }
    @Published var speechRate: Double { didSet { defaults.set(speechRate, forKey: "speechRate") } }
    @Published var soundsEnabled: Bool { didSet { defaults.set(soundsEnabled, forKey: "soundsEnabled") } }
    @Published var soundsVolume: Double { didSet { defaults.set(soundsVolume, forKey: "soundsVolume") } }
    @Published var hudSuccessSeconds: Double { didSet { defaults.set(hudSuccessSeconds, forKey: "hudSuccessSeconds") } }
    @Published var hudAnswerSeconds: Double { didSet { defaults.set(hudAnswerSeconds, forKey: "hudAnswerSeconds") } }
    @Published var hudErrorSeconds: Double { didSet { defaults.set(hudErrorSeconds, forKey: "hudErrorSeconds") } }
    /// Where the floating messages appear; `auto` moves them away from the caret and the pointer.
    @Published var hudPosition: HUDPosition { didSet { defaults.set(hudPosition.rawValue, forKey: "hudPosition") } }
    /// Smaller messages; «Ti ascolto ancora» becomes a small pill.
    @Published var hudCompact: Bool { didSet { defaults.set(hudCompact, forKey: "hudCompact") } }

    // MARK: Numbers
    @Published var numbersTimeout: Double { didSet { defaults.set(numbersTimeout, forKey: "numbersTimeout") } }
    @Published var numbersLimit: Int { didSet { defaults.set(numbersLimit, forKey: "numbersLimit") } }

    // MARK: Privacy
    /// How long «modalità privata» lasts before switching off by itself.
    @Published var privateModeMinutes: Double { didSet { defaults.set(privateModeMinutes, forKey: "privateModeMinutes") } }
    /// Apps never shown to a cloud engine (bundle identifier or name, one per line).
    @Published var reservedApps: String { didSet { defaults.set(reservedApps, forKey: "reservedApps") } }
    @Published var accessLevels: String { didSet { defaults.set(accessLevels, forKey: "accessLevels") } }
    /// Sites never shown to a cloud engine (domain or word, one per line).
    @Published var reservedSites: String { didSet { defaults.set(reservedSites, forKey: "reservedSites") } }
    /// Masks card numbers, IBANs, tax codes and numeric secrets in what the cloud engines read.
    @Published var hideSensitiveFromCloud: Bool { didSet { defaults.set(hideSensitiveFromCloud, forKey: "hideSensitiveFromCloud") } }
    /// Days of log kept on disk.
    @Published var logRetentionDays: Int { didSet { defaults.set(logRetentionDays, forKey: "logRetentionDays"); syncLogPolicy() } }
    /// The log also contains what the agent saw and did and the text of ignored sentences (diagnosis).
    @Published var detailedLog: Bool { didSet { defaults.set(detailedLog, forKey: "detailedLog"); syncLogPolicy() } }
    /// Until when «modalità privata» is on. Never saved: a restart ends it.
    @Published private(set) var privateModeUntil: Date? { didSet { syncLogPolicy() } }

    var privateModeActive: Bool { privateModeUntil.map { $0 > Date() } ?? false }

    func setPrivateMode(_ on: Bool) {
        privateModeUntil = on ? Date().addingTimeInterval(max(1, privateModeMinutes) * 60) : nil
    }

    /// The log runs on its own queue: it gets a copy of the rules it needs.
    private func syncLogPolicy() {
        Log.setPolicy(detailed: detailedLog, privateUntil: privateModeUntil, retentionDays: logRetentionDays)
    }

    // MARK: Window
    @Published var lastSettingsSection: SettingsSection { didSet { defaults.set(lastSettingsSection.rawValue, forKey: "lastSettingsSection") } }

    private init() {
        let d = UserDefaults.standard
        func double(_ k: String, _ v: Double) -> Double { d.object(forKey: k) as? Double ?? v }
        func int(_ k: String, _ v: Int) -> Int { d.object(forKey: k) as? Int ?? v }
        func bool(_ k: String, _ v: Bool) -> Bool { d.object(forKey: k) as? Bool ?? v }
        func string(_ k: String, _ v: String) -> String { d.string(forKey: k) ?? v }

        pttKey = PTTKey(rawValue: string("pttKey", "")) ?? Defaults.pttKey
        // Migration: a list customised before Story 3.7 becomes word + extra phrases.
        let legacy = d.string(forKey: "wakePhrases")
        if d.object(forKey: "wakeWord") == nil, let legacy, Grammar.normalize(legacy) != Grammar.normalize(Defaults.legacyWakePhrases) {
            let parts = legacy.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            wakeWord = parts.first ?? Defaults.wakeWord
            wakeVariants = false
            extraWakePhrases = parts.dropFirst().joined(separator: ", ")
        } else {
            wakeWord = string("wakeWord", Defaults.wakeWord)
            wakeVariants = bool("wakeVariants", Defaults.wakeVariants)
            extraWakePhrases = string("extraWakePhrases", Defaults.extraWakePhrases)
        }
        startListening = bool("startListening", Defaults.startListening)
        vadEndSilence = double("vadEndSilence", Defaults.vadEndSilence)
        vadMinStartRMS = double("vadMinStartRMS", Defaults.vadMinStartRMS)
        vadNoiseFactor = double("vadNoiseFactor", Defaults.vadNoiseFactor)
        vadMaxSegment = double("vadMaxSegment", Defaults.vadMaxSegment)
        dictationEndSilence = double("dictationEndSilence", Defaults.dictationEndSilence)
        dictationIdleSeconds = double("dictationIdleSeconds", Defaults.dictationIdleSeconds)
        sessionIdleSeconds = double("sessionIdleSeconds", Defaults.sessionIdleSeconds)
        headAttention = bool("headAttention", Defaults.headAttention)
        headReference = (d.array(forKey: "headReference") as? [Double]).flatMap { $0.count == 2 ? HeadPose(yaw: $0[0], pitch: $0[1]) : nil }
        headCalibratedAt = d.object(forKey: "headCalibratedAt") as? Date
        headProfile = d.data(forKey: "headProfile").flatMap { try? JSONDecoder().decode(HeadProfile.self, from: $0) }
        headYesConfirms = bool("headYesConfirms", Defaults.headYesConfirms)

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
        longSession = bool("longSession", Defaults.longSession)
        sessionMaxRequests = d.object(forKey: "sessionMaxRequests") as? Int ?? Defaults.sessionMaxRequests
        prepareSessionOnWake = bool("prepareSessionOnWake", Defaults.prepareSessionOnWake)
        instantLevel = bool("instantLevel", Defaults.instantLevel)
        instantModel = d.string(forKey: "instantModel") ?? Defaults.instantModel
        instantEffort = d.string(forKey: "instantEffort") ?? Defaults.instantEffort
        fixedCostObservation = bool("fixedCostObservation", Defaults.fixedCostObservation)
        riskClassifier = bool("riskClassifier", Defaults.riskClassifier)
        evidenceBeforeDone = bool("evidenceBeforeDone", Defaults.evidenceBeforeDone)
        quickReplies = bool("quickReplies", Defaults.quickReplies)
        d.removeObject(forKey: "confirmValiditySeconds") // removed with Story 9.2: no time window any more
        cleanDictation = bool("cleanDictation", Defaults.cleanDictation)

        agentEngine = EngineID(rawValue: string("agentEngine", "")) ?? Defaults.agentEngine
        engineFallback = bool("engineFallback", Defaults.engineFallback)
        codexPath = string("codexPath", Defaults.codexPath)
        approvedCodexInstructions = string("approvedCodexInstructions", Defaults.approvedCodexInstructions)
        codexModel = string("codexModel", Defaults.codexModel)
        codexFastModel = string("codexFastModel", Defaults.codexFastModel)
        codexDeepEffort = string("codexDeepEffort", Defaults.codexDeepEffort)
        codexFastEffort = string("codexFastEffort", Defaults.codexFastEffort)
        localMaxSteps = int("localMaxSteps", Defaults.localMaxSteps)
        localProvider = LocalProvider(rawValue: string("localProvider", "")) ?? Defaults.localProvider
        localServerURL = string("localServerURL", Defaults.localServerURL)
        localServerModel = string("localServerModel", Defaults.localServerModel)
        localKeepAliveMinutes = double("localKeepAliveMinutes", Defaults.localKeepAliveMinutes)
        localServerAllowRemote = bool("localServerAllowRemote", Defaults.localServerAllowRemote)

        speakReplies = bool("speakReplies", Defaults.speakReplies)
        speechVolume = double("speechVolume", Defaults.speechVolume)
        speechRate = double("speechRate", Defaults.speechRate)
        soundsEnabled = bool("soundsEnabled", Defaults.soundsEnabled)
        soundsVolume = double("soundsVolume", Defaults.soundsVolume)
        hudSuccessSeconds = double("hudSuccessSeconds", Defaults.hudSuccessSeconds)
        hudAnswerSeconds = double("hudAnswerSeconds", Defaults.hudAnswerSeconds)
        hudErrorSeconds = double("hudErrorSeconds", Defaults.hudErrorSeconds)
        hudPosition = HUDPosition(rawValue: string("hudPosition", "")) ?? Defaults.hudPosition
        hudCompact = bool("hudCompact", Defaults.hudCompact)

        numbersTimeout = double("numbersTimeout", Defaults.numbersTimeout)
        numbersLimit = int("numbersLimit", Defaults.numbersLimit)

        privateModeMinutes = double("privateModeMinutes", Defaults.privateModeMinutes)
        reservedApps = string("reservedApps", Defaults.reservedApps)
        accessLevels = string("accessLevels", Defaults.accessLevels)
        reservedSites = string("reservedSites", Defaults.reservedSites)
        hideSensitiveFromCloud = bool("hideSensitiveFromCloud", Defaults.hideSensitiveFromCloud)
        logRetentionDays = int("logRetentionDays", Defaults.logRetentionDays)
        detailedLog = bool("detailedLog", Defaults.detailedLog)
        privateModeUntil = nil

        lastSettingsSection = SettingsSection(rawValue: string("lastSettingsSection", "")) ?? .listening
        syncLogPolicy()
    }

    /// "Ripristina predefiniti": only the keys of one section (AD-12).
    func reset(_ section: SettingsSection) {
        switch section {
        case .listening:
            pttKey = Defaults.pttKey; wakeWord = Defaults.wakeWord; wakeVariants = Defaults.wakeVariants
            extraWakePhrases = Defaults.extraWakePhrases; startListening = Defaults.startListening
            vadEndSilence = Defaults.vadEndSilence; vadMinStartRMS = Defaults.vadMinStartRMS
            vadNoiseFactor = Defaults.vadNoiseFactor; vadMaxSegment = Defaults.vadMaxSegment
            dictationEndSilence = Defaults.dictationEndSilence; dictationIdleSeconds = Defaults.dictationIdleSeconds
            sessionIdleSeconds = Defaults.sessionIdleSeconds
            headAttention = Defaults.headAttention // the calibration stays: it describes the desk, not a preference
            headYesConfirms = Defaults.headYesConfirms
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
            agentTimeout = Defaults.agentTimeout
            longSession = Defaults.longSession; sessionMaxRequests = Defaults.sessionMaxRequests
            prepareSessionOnWake = Defaults.prepareSessionOnWake
            instantLevel = Defaults.instantLevel; instantModel = Defaults.instantModel; instantEffort = Defaults.instantEffort
            fixedCostObservation = Defaults.fixedCostObservation; riskClassifier = Defaults.riskClassifier; evidenceBeforeDone = Defaults.evidenceBeforeDone
            quickReplies = Defaults.quickReplies
            cleanDictation = Defaults.cleanDictation
            agentEngine = Defaults.agentEngine; engineFallback = Defaults.engineFallback
            codexPath = Defaults.codexPath; codexModel = Defaults.codexModel; codexFastModel = Defaults.codexFastModel
            codexDeepEffort = Defaults.codexDeepEffort; codexFastEffort = Defaults.codexFastEffort
            localMaxSteps = Defaults.localMaxSteps; localProvider = Defaults.localProvider
            localServerURL = Defaults.localServerURL; localServerModel = Defaults.localServerModel
            localKeepAliveMinutes = Defaults.localKeepAliveMinutes; localServerAllowRemote = Defaults.localServerAllowRemote
        case .voice:
            speakReplies = Defaults.speakReplies; speechVolume = Defaults.speechVolume; speechRate = Defaults.speechRate
            soundsEnabled = Defaults.soundsEnabled; soundsVolume = Defaults.soundsVolume
            hudSuccessSeconds = Defaults.hudSuccessSeconds; hudAnswerSeconds = Defaults.hudAnswerSeconds
            hudErrorSeconds = Defaults.hudErrorSeconds
            hudPosition = Defaults.hudPosition; hudCompact = Defaults.hudCompact
        case .numbers:
            numbersTimeout = Defaults.numbersTimeout; numbersLimit = Defaults.numbersLimit
        case .privacy:
            privateModeMinutes = Defaults.privateModeMinutes; reservedApps = Defaults.reservedApps; accessLevels = Defaults.accessLevels
            reservedSites = Defaults.reservedSites; hideSensitiveFromCloud = Defaults.hideSensitiveFromCloud
            logRetentionDays = Defaults.logRetentionDays; detailedLog = Defaults.detailedLog
        case .memory, .permissions, .status:
            break
        }
    }

    /// Path of the `claude` command, if installed (custom path wins).
    var claudeExecutable: String? { ClaudeCLI.locate(custom: claudePath) }

    /// Path of the `codex` command, if installed (custom path wins).
    var codexExecutable: String? { CodexCLI.locate(custom: codexPath) }

    /// The wake word as typed, or «computer» when the field is empty.
    var effectiveWakeWord: String {
        let w = wakeWord.trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
        return Grammar.normalize(w).isEmpty ? Defaults.wakeWord : w
    }

    /// Every phrase that wakes the app, normalised, without duplicates.
    var wakePhraseList: [String] {
        Self.wakePhrases(word: effectiveWakeWord, variants: wakeVariants, extra: extraWakePhrases)
    }

    static func wakePhrases(word: String, variants: Bool, extra: String) -> [String] {
        let w = Grammar.normalize(word)
        var list = [w]
        if variants { list += Defaults.wakePrefixes.map { "\($0) \(w)" } }
        list += extra.split(separator: ",").map { Grammar.normalize(String($0)) }
        var seen = Set<String>()
        return list.filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    var firstWakePhrase: String { effectiveWakeWord }

    /// A word that is likely to wake the app by mistake, with the reason; nil when it looks fine.
    static func wakeWordWarning(_ word: String) -> String? {
        let n = Grammar.normalize(word)
        if n.isEmpty { return "Campo vuoto: resta «computer»." }
        let common: Set<String> = ["si", "no", "ok", "ciao", "allora", "ecco", "dai", "casa", "mamma", "papa", "amore",
                                   "bene", "senti", "guarda", "aspetta", "basta", "vai", "apri", "scrivi", "stop"]
        if common.contains(n) { return "«\(word)» si dice spesso in casa o è già un comando: l'app potrebbe attivarsi per sbaglio." }
        if n.replacingOccurrences(of: " ", with: "").count < 4 { return "Una parola così corta può essere riconosciuta per sbaglio: meglio almeno 4 lettere." }
        return nil
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

/// Where the floating messages (HUD) appear.
enum HUDPosition: String, CaseIterable, Identifiable {
    /// At the bottom, moving to the top when it would cover the caret or the pointer.
    case auto
    case bottom
    case top
    case topRight
    case bottomRight

    var id: String { rawValue }
    var title: String {
        switch self {
        case .auto: return "Automatica (si sposta se copre)"
        case .bottom: return "In basso al centro"
        case .top: return "In alto al centro"
        case .topRight: return "In alto a destra"
        case .bottomRight: return "In basso a destra"
        }
    }
}

/// Which model the local engine uses (FR-31).
enum LocalProvider: String, CaseIterable, Identifiable {
    /// Apple's on-device model (always there with Apple Intelligence).
    case apple
    /// An OpenAI-compatible server on the Mac (Ollama, LM Studio, mlx_lm.server, Rapid-MLX).
    case server

    var id: String { rawValue }
    var title: String {
        switch self {
        case .apple: return "Modello Apple"
        case .server: return "Server sul Mac (Ollama, LM Studio, MLX)"
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

