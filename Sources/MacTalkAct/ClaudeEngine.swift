import Foundation

/// Claude through the `claude` command (Claude Code) on the user's subscription.
/// Two processes are kept ready, one per level, already connected to the tools.
@MainActor
final class ClaudeEngine: AgentEngine {
    let id = EngineID.claude
    private let settings: AppSettings
    private let toolAccess: () -> AgentToolAccess?
    private let cliDeep = ClaudeCLI()
    private let cliFast = ClaudeCLI()
    private let pause = EnginePause()

    private(set) var availability: AgentAvailability = .available
    var onAvailabilityChange: ((AgentAvailability) -> Void)?
    var onPhase: PhaseSink?

    init(settings: AppSettings, toolAccess: @escaping () -> AgentToolAccess?) {
        self.settings = settings
        self.toolAccess = toolAccess
        availability = settings.claudeExecutable == nil ? .missing : .available
    }

    private func setAvailability(_ a: AgentAvailability) {
        guard a != availability else { return }
        availability = a
        Log.info("Motore Claude: \(a)")
        onAvailabilityChange?(a)
    }

    func refreshAvailability() {
        if case .paused(let until) = availability, Date() < until { return }
        setAvailability(settings.claudeExecutable == nil ? .missing : .available)
        refreshStatus()
    }

    /// "You've hit your session limit · resets 7pm (Europe/Rome)" → pause until then (FR-14).
    func pauseForLimit(message: String) -> Date {
        let until = LimitMessage.resetDate(from: message) ?? Date().addingTimeInterval(30 * 60)
        setAvailability(.paused(until: until))
        pause.schedule(until: until) { [weak self] in
            guard let self else { return }
            self.setAvailability(.available)
            self.refreshAvailability()
            self.prewarm()
        }
        return until
    }

    func model(for level: AgentLevel) -> String {
        level == .deep || !settings.useFastModel ? settings.model : settings.fastModel
    }

    private func useDeep(_ level: AgentLevel) -> Bool { level == .deep || !settings.useFastModel }

    /// The spawn may happen on a background queue: capture the path setting now.
    private func refreshExecutable() {
        let custom = settings.claudePath
        cliDeep.executablePath = { ClaudeCLI.locate(custom: custom) }
        cliFast.executablePath = { ClaudeCLI.locate(custom: custom) }
    }

    private func config(deep: Bool) -> ClaudeCLI.Config? {
        guard let access = toolAccess() else { return nil }
        return ClaudeCLI.Config(
            model: deep ? settings.model : settings.fastModel,
            systemPrompt: AgentRunner.systemPrompt,
            effort: deep ? settings.deepEffort : settings.fastEffort,
            extraArgs: [
                "--mcp-config", access.mcpConfigJSON,
                "--permission-mode", "dontAsk",
                "--permission-prompts", "none",
                "--max-turns", "\(settings.agentMaxTurns)",
                "--allowedTools", "mcp__\(MCPServer.serverName)",
                "--disallowedTools", "Agent", "TaskStop",
            ]
        )
    }

    private func cli(deep: Bool) -> ClaudeCLI { deep ? cliDeep : cliFast }

    /// Keeps `claude` processes ready, already connected to the tools.
    func prewarm() {
        guard availability == .available else { return }
        refreshExecutable()
        if cliStatus == .unverified(nil) { refreshStatus() }
        // The Long session starts with the first request, never in advance (AD-6).
        if usesSession { return }
        var pairs: [(ClaudeCLI, ClaudeCLI.Config)] = []
        if let c = config(deep: true) { pairs.append((cliDeep, c)) }
        if settings.useFastModel, let c = config(deep: false) { pairs.append((cliFast, c)) }
        for (cli, c) in pairs {
            DispatchQueue.global(qos: .utility).async { cli.prewarm(c) }
        }
    }

    /// «Riavvio l'Agente» and similar, for the HUD through AgentRunner (engines never touch the HUD).
    var onNotice: ((String) -> Void)?
    /// What the app knows about the `claude` version (FR-45). Read off the main thread.
    private(set) var cliStatus: CLIStatus = .unverified(nil)

    /// Reads `claude --version` in the background; the status page and the Long session use it.
    func refreshStatus() {
        refreshExecutable()
        let cli = cliDeep
        Task.detached(priority: .utility) { [weak self] in
            let status = cli.status()
            await MainActor.run {
                guard let self, self.cliStatus != status else { return }
                self.cliStatus = status
                Log.info("Motore Claude: \(status)")
            }
        }
    }

    /// Long session only with a verified CLI and the switch on (FR-42, FR-45, NFR-15).
    private var usesSession: Bool { settings.longSession && cliStatus.isVerified }

    /// Ends both Long sessions (memory emptied, private mode, settings changed).
    func endSessions(reason: String) {
        cliDeep.endSession(reason: reason)
        cliFast.endSession(reason: reason)
    }

    func run(_ request: AgentRequest) async throws -> String {
        let deep = useDeep(request.level)
        guard let config = config(deep: deep) else { throw AgentEngineError.failed("server strumenti non avviato") }
        refreshExecutable()
        let cli = cli(deep: deep)
        do {
            let data: Data
            if usesSession {
                data = try await runInSession(cli, config, request)
            } else {
                data = try await cli.run(config, message: request.message, timeout: request.clock.remaining, onPhase: onPhase)
            }
            return (String(data: data, encoding: .utf8) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        } catch let error as ClaudeCLIError {
            let message = error.localizedDescription
            if LimitMessage.isLimit(message) {
                let until = pauseForLimit(message: message)
                throw AgentEngineError.limit(message: message, until: until)
            }
            switch error {
            case .notFound:
                setAvailability(.missing)
                throw AgentEngineError.notFound(message)
            case .timeout:
                throw AgentEngineError.timeout
            case .failed, .noOutput, .sessionDied:
                if ClaudeEngine.isLoginMessage(message) {
                    // Started without the subscription login: no Long session until checked again.
                    cli.markUnverified()
                    cliStatus = cli.status()
                    throw AgentEngineError.loginNeeded(message)
                }
                if ClaudeEngine.isNetworkMessage(message) { throw AgentEngineError.network(message) }
                throw AgentEngineError.failed(message)
            }
        }
    }

    private func runInSession(_ cli: ClaudeCLI, _ config: ClaudeCLI.Config, _ request: AgentRequest) async throws -> Data {
        let maxRequests = max(1, settings.sessionMaxRequests)
        let tools = toolAccess()?.tools
        let onRestart: (String) -> Void = { [weak self] reason in
            Log.info("Agente (claude/\(config.model)): riavvio la sessione, \(reason)")
            self?.onNotice?("Riavvio l'Agente")
        }
        func attempt() async throws -> Data {
            try await cli.runInSession(config, memory: request.memory, maxRequests: maxRequests,
                                       timeout: request.clock.remaining,
                                       message: { seq in seq.map(request.messageSince) ?? request.message },
                                       onPhase: onPhase, onRestart: onRestart)
        }
        do {
            return try await attempt()
        } catch ClaudeCLIError.sessionDied(let m) where (tools?.effectfulCalls ?? 1) == 0 && !(tools?.cancelled ?? true) {
            // The session died before doing anything: once more, on a new session (FR-28).
            Log.info("Agente (claude/\(config.model)): sessione chiusa a metà senza azioni \(m), ripeto la richiesta")
            onNotice?("Riavvio l'Agente")
            return try await attempt()
        }
    }

    /// "Invalid API key · Please run /login", "OAuth token has expired".
    static func isLoginMessage(_ m: String) -> Bool {
        let l = m.lowercased()
        return l.contains("/login") || l.contains("not logged in") || l.contains("oauth token") || l.contains("401")
    }

    static func isNetworkMessage(_ m: String) -> Bool {
        let l = m.lowercased()
        return l.contains("connection error") || l.contains("network") || l.contains("enotfound")
            || l.contains("econnrefused") || l.contains("timed out") || l.contains("offline")
    }

    func cancel() {
        cliDeep.cancelCurrent()
        cliFast.cancelCurrent()
    }

    func shutdown() {
        pause.cancel()
        endSessions(reason: "app chiusa")
        cliDeep.shutdown()
        cliFast.shutdown()
    }
}
