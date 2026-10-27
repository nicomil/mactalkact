import Foundation
import FoundationModels

/// The agent on the Mac (FR-30, AD-17): a FoundationModels session whose tools call the
/// app's own `AgentTools` (same safety, same confirmations), with a short Italian prompt,
/// fewer tools and a low step limit. The model is interchangeable: Apple's on-device
/// model, or an OpenAI-compatible server on the Mac (`OpenAICompatibleModel`).
@MainActor
final class LocalEngine: AgentEngine {
    let id = EngineID.local
    private let settings: AppSettings
    private let toolAccess: () -> AgentToolAccess?
    private var runningTask: Task<String, Error>?
    /// The server answered the last check (only for the server provider).
    private var serverReachable: Bool?
    /// Set when a request fell back from the server to Apple's model: shown once.
    var onNotice: ((String) -> Void)?

    private(set) var availability: AgentAvailability = .available
    var onAvailabilityChange: ((AgentAvailability) -> Void)?
    var onPhase: PhaseSink?

    /// Debug commands only (`--agent-bench --model`): provider, server and model without touching the settings.
    struct Override {
        var provider: LocalProvider
        var url: String
        var model: String
        var mode: Mode? = nil
    }

    /// How the local model works (Story 5.4): steps chosen with guided generation in a loop
    /// driven by the app, or free tool calling. Chosen with the bench.
    enum Mode: String { case plan, steps, tools }
    static let defaultMode = Mode.plan
    private var mode: Mode { override?.mode ?? Self.defaultMode }
    var override: Override?
    private var provider: LocalProvider { override?.provider ?? settings.localProvider }
    private var serverURL: String { override?.url ?? settings.localServerURL }
    private var serverModel: String { override?.model ?? settings.localServerModel }

    init(settings: AppSettings, toolAccess: @escaping () -> AgentToolAccess?) {
        self.settings = settings
        self.toolAccess = toolAccess
        availability = Self.appleAvailability()
    }

    // MARK: Availability

    static var appleModelAvailable: Bool {
        if case .available = SystemLanguageModel.default.availability { return true }
        return false
    }

    /// Apple's model is the floor: when it is off the engine is usable only with a server.
    private static func appleAvailability() -> AgentAvailability {
        switch SystemLanguageModel.default.availability {
        case .available: return .available
        case .unavailable(let reason):
            switch reason {
            case .appleIntelligenceNotEnabled: return .unavailable("Apple Intelligence spenta")
            case .deviceNotEligible: return .unavailable("Mac non compatibile con il modello Apple")
            case .modelNotReady: return .unavailable("modello Apple in preparazione")
            @unknown default: return .unavailable("modello Apple non disponibile")
            }
        }
    }

    private func setAvailability(_ a: AgentAvailability) {
        guard a != availability else { return }
        availability = a
        Log.info("Motore locale: \(a)")
        onAvailabilityChange?(a)
    }

    func refreshAvailability() {
        let apple = Self.appleAvailability()
        guard provider == .server else {
            setAvailability(apple)
            return
        }
        // With a server the engine works if the server answers, or with Apple's model.
        Task { @MainActor in
            let ok = await OpenAICompatibleModel.ping(baseURL: serverURL)
            serverReachable = ok
            setAvailability(ok ? .available : apple)
        }
    }

    // MARK: Model

    func model(for level: AgentLevel) -> String {
        if provider == .server, serverReachable != false, !serverModel.isEmpty {
            return serverModel
        }
        return "apple-on-device"
    }

    /// The model of the next request: the server when chosen and allowed, otherwise Apple's.
    private func languageModel() -> (any LanguageModel, String) {
        if provider == .server, !serverModel.isEmpty, serverReachable != false,
           // A server on another computer is not «on the Mac»: never for private or reserved windows.
           OpenAICompatibleModel.isAllowed(baseURL: serverURL,
                                           allowRemote: settings.localServerAllowRemote && PrivacyGuard.cloudBlockReason() == nil),
           let m = OpenAICompatibleModel.make(baseURL: serverURL, model: serverModel,
                                              keepAliveMinutes: settings.localKeepAliveMinutes) {
            return (m, serverModel)
        }
        return (SystemLanguageModel.default, "apple-on-device")
    }

    func prewarm() {
        guard provider == .apple || serverReachable == false, Self.appleModelAvailable else { return }
        LanguageModelSession(instructions: Self.instructions).prewarm()
    }

    // MARK: Prompt and tools

    static let instructions = """
    Sei le mani di una persona che usa il Mac a voce perché ha le mani occupate. Esegui la richiesta \
    sulla finestra in primo piano con gli strumenti, poi rispondi con UNA frase italiana breve \
    (massimo 12 parole) che dice cosa hai fatto. Niente markdown.
    Regole:
    - Prima chiama observe per avere gli id degli elementi; se cerchi qualcosa di preciso passa query.
    - Usa gli id dell'ultimo observe per click, type_text e scroll.
    - Per aprire un sito usa open_url, per un'app open_app, per le scorciatoie press_keys.
    - Per cambiare un testo in un campo usa replace_text con il testo esatto da trovare.
    - Prima di inviare, eliminare, comprare o pubblicare chiama confirm.
    - Fai solo quello che è chiesto. Se non ci riesci in pochi passi, fermati e dillo.
    """

    /// Tools the local model gets (AD-17): no screenshot (no vision), no memory or macros.
    static let toolNames = ["observe", "click", "click_many", "type_text", "replace_text", "press_keys",
                            "open_app", "open_url", "scroll", "wait", "confirm", "ask_user"]

    /// Short Italian descriptions: small models read every word at every step.
    static let descriptions: [String: String] = [
        "observe": "Elenca gli elementi della finestra in primo piano con un [id]. query: testo da cercare in tutta la finestra.",
        "click": "Clicca l'elemento con questo id (dall'ultimo observe). method: auto, mouse, double, right.",
        "click_many": "Clicca più elementi in una volta (es. caselle) e restituisce lo stato di ciascuno.",
        "type_text": "Scrive testo nel punto del cursore; con id prima mette il cursore in quel campo.",
        "replace_text": "Sostituisce nel campo attivo il testo esatto find con replace e verifica.",
        "press_keys": "Preme scorciatoie o tasti: 'cmd+t', 'return', 'escape', 'cmd+a delete'.",
        "open_app": "Apre o porta in primo piano un'app per nome.",
        "open_url": "Apre un sito o un indirizzo.",
        "scroll": "Scorre la finestra o l'elemento id. direction: up, down, left, right.",
        "wait": "Aspetta qualche secondo (max 5) che la pagina si aggiorni.",
        "confirm": "Chiede conferma all'utente prima di inviare, eliminare, comprare. Risponde approved o denied.",
        "ask_user": "Fa una domanda breve all'utente e restituisce la risposta.",
    ]

    /// Longest tool result passed to the model: Apple's model has a small context.
    static let maxResultCharacters = 2400

    private func makeTools(_ access: AgentToolAccess, budget: StepBudget) -> [any Tool] {
        let defs = AgentTools.definitions
        return Self.toolNames.compactMap { name -> (any Tool)? in
            guard let def = defs.first(where: { $0["name"] as? String == name }),
                  let schema = def["inputSchema"] as? [String: Any],
                  let parameters = try? LocalTool.schema(name: name, from: schema) else { return nil }
            let tools = access.tools
            return LocalTool(name: name, description: Self.descriptions[name] ?? (def["description"] as? String ?? ""),
                             parameters: parameters) { args in
                await budget.take() ? await Self.text(tools.call(name, args))
                    : "Limite di passi raggiunto: fermati e di' in una frase che cosa manca."
            }
        }
    }

    @MainActor
    private static func text(_ r: AgentTools.Result) -> String {
        let t = r.content.compactMap { $0["text"] as? String }.joined(separator: "\n")
        let body = t.count > maxResultCharacters
            ? String(t.prefix(maxResultCharacters)) + "\n… (elenco troncato: usa observe con query per cercare un elemento)"
            : t
        return r.isError ? "ERRORE: \(body)" : body
    }

    // MARK: Running

    func run(_ request: AgentRequest) async throws -> String {
        guard let access = toolAccess() else { throw AgentEngineError.failed("strumenti non pronti") }
        // No process and no MCP server here: all of the model's time is thinking.
        onPhase?(.sessionReused)
        onPhase?(.serverConnected)
        onPhase?(.firstToken)
        defer { onPhase?(.turnFinished(turns: nil)) }
        var (model, name) = languageModel()
        if provider == .server, name == "apple-on-device" {
            onNotice?("Server locale non raggiungibile · uso il modello Apple")
        }
        guard name != "apple-on-device" || Self.appleModelAvailable else {
            throw AgentEngineError.failed("Modello Apple non disponibile")
        }
        do {
            return try await attempt(request, model: model, access: access)
        } catch let e as OpenAICompatibleModel.ServerError {
            // The server went away during the request: the same request with Apple's model.
            Log.info("Motore locale: server non raggiungibile (\(e.localizedDescription)), uso il modello Apple")
            serverReachable = false
            guard Self.appleModelAvailable, access.tools.effectfulCalls == 0 else {
                throw AgentEngineError.failed("Server locale non raggiungibile")
            }
            onNotice?("Server locale non raggiungibile · uso il modello Apple")
            (model, name) = (SystemLanguageModel.default, "apple-on-device")
            access.tools.reset()
            return try await attempt(request, model: model, access: access)
        }
    }

    private func attempt(_ request: AgentRequest, model: any LanguageModel, access: AgentToolAccess) async throws -> String {
        let budget = StepBudget(limit: settings.localMaxSteps)
        let mode = self.mode
        let tools = mode == .tools ? makeTools(access, budget: budget) : []
        let session = LanguageModelSession(model: model, tools: tools, instructions: Self.instructions)
        let prompt = request.localMessage
        let timeout = request.clock.remaining // the one turn clock (AD-24)
        let stepAgent = LocalStepAgent(model: model, tools: access.tools, maxSteps: settings.localMaxSteps)
        let userRequest = request.userRequest
        let task = Task<String, Error> { @MainActor in
            try await withThrowingTaskGroup(of: String.self) { group in
                group.addTask { @MainActor in
                    if mode == .plan {
                        return try await stepAgent.runPlan(request: userRequest, context: prompt).answer
                    }
                    if mode == .steps {
                        return try await stepAgent.run(request: userRequest, context: prompt).answer
                    }
                    return try await session.respond(to: prompt).content
                }
                group.addTask {
                    try await Task.sleep(for: .seconds(timeout))
                    throw AgentEngineError.timeout
                }
                defer { group.cancelAll() }
                guard let r = try await group.next() else { throw AgentEngineError.timeout }
                return r
            }
        }
        runningTask = task
        defer { runningTask = nil }
        do {
            let answer = try await task.value.trimmingCharacters(in: .whitespacesAndNewlines)
            if await budget.exhausted {
                return "Col modello locale non ci riesco del tutto: \(answer)"
            }
            return answer
        } catch let e as OpenAICompatibleModel.ServerError {
            throw e
        } catch let e as AgentEngineError {
            throw e
        } catch is CancellationError {
            throw AgentEngineError.failed("Interrotto")
        } catch let e as LanguageModelError {
            switch e {
            case .contextSizeExceeded:
                throw AgentEngineError.failed("Col modello locale non ci riesco: la finestra ha troppi elementi")
            default:
                throw AgentEngineError.failed("Col modello locale non ci riesco: \(e.localizedDescription)")
            }
        } catch {
            throw AgentEngineError.failed("Col modello locale non ci riesco: \(error.localizedDescription)")
        }
    }

    func cancel() { runningTask?.cancel() }

    func shutdown() { runningTask?.cancel() }
}

/// Counts tool calls of one local request (FR-30).
actor StepBudget {
    private let limit: Int
    private var used = 0
    init(limit: Int) { self.limit = max(1, limit) }

    /// True while there are steps left; the first call over the limit marks the budget as exhausted.
    func take() -> Bool {
        used += 1
        return used <= limit
    }

    var exhausted: Bool { used > limit }
}

/// A FoundationModels tool built from one of the app's tool definitions.
struct LocalTool: Tool {
    typealias Arguments = GeneratedContent
    typealias Output = String

    let name: String
    let description: String
    let parameters: GenerationSchema
    let handler: @Sendable ([String: Any]) async -> String

    init(name: String, description: String, parameters: GenerationSchema,
         handler: @escaping @Sendable ([String: Any]) async -> String) {
        self.name = name
        self.description = description
        self.parameters = parameters
        self.handler = handler
    }

    func call(arguments: GeneratedContent) async throws -> String {
        let json = arguments.jsonString
        let args = (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Any] ?? [:]
        return await handler(args)
    }

    /// JSON Schema (as used over MCP) → generation schema for guided tool arguments.
    static func schema(name: String, from json: [String: Any]) throws -> GenerationSchema {
        let props = json["properties"] as? [String: Any] ?? [:]
        let required = Set(json["required"] as? [String] ?? [])
        let properties = props.keys.sorted().compactMap { key -> DynamicGenerationSchema.Property? in
            guard let p = props[key] as? [String: Any] else { return nil }
            return DynamicGenerationSchema.Property(name: key, description: p["description"] as? String,
                                                    schema: dynamic(p, name: "\(name)_\(key)"),
                                                    isOptional: !required.contains(key))
        }
        let root = DynamicGenerationSchema(name: name, properties: properties)
        return try GenerationSchema(root: root, dependencies: [])
    }

    private static func dynamic(_ p: [String: Any], name: String) -> DynamicGenerationSchema {
        if let choices = p["enum"] as? [String] { return DynamicGenerationSchema(name: name, anyOf: choices) }
        switch p["type"] as? String {
        case "integer": return DynamicGenerationSchema(type: Int.self)
        case "number": return DynamicGenerationSchema(type: Double.self)
        case "boolean": return DynamicGenerationSchema(type: Bool.self)
        case "array":
            let items = p["items"] as? [String: Any] ?? ["type": "string"]
            return DynamicGenerationSchema(arrayOf: dynamic(items, name: name + "_item"))
        default: return DynamicGenerationSchema(type: String.self)
        }
    }
}
