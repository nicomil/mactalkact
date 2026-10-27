import Combine
import Foundation

/// Claude through the `claude` command (Claude Code) on the user's subscription.
/// One process per level: a Long session kept open between requests, or (switch off, CLI not
/// verified) a process kept ready and used once.
@MainActor
final class ClaudeEngine: AgentEngine {
    let id = EngineID.claude
    private let settings: AppSettings
    private let toolAccess: () -> AgentToolAccess?
    private let cliDeep = ClaudeCLI()
    private let cliFast = ClaudeCLI()
    private let cliInstant = ClaudeCLI()
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
        refreshStatus(force: true)
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
        switch effective(level) {
        case .instant: return settings.instantModel
        case .fast: return settings.fastModel
        case .deep: return settings.model
        }
    }

    /// The level actually used: the Instant level only when switched on, the fast one only when used.
    private func effective(_ level: AgentLevel) -> AgentLevel {
        Self.effective(level, instantOn: settings.instantLevel, useFastModel: settings.useFastModel)
    }

    /// Pure, tested by `--selftest`.
    nonisolated static func effective(_ level: AgentLevel, instantOn: Bool, useFastModel: Bool) -> AgentLevel {
        if level == .instant, instantOn { return .instant }
        return level == .deep || !useFastModel ? .deep : .fast
    }

    /// The spawn may happen on a background queue: capture the path setting now.
    private func refreshExecutable() {
        let custom = settings.claudePath
        cliDeep.executablePath = { ClaudeCLI.locate(custom: custom) }
        cliFast.executablePath = { ClaudeCLI.locate(custom: custom) }
        cliInstant.executablePath = { ClaudeCLI.locate(custom: custom) }
    }

    private func config(_ level: AgentLevel) -> ClaudeCLI.Config? {
        guard let access = toolAccess() else { return nil }
        let effort: String
        switch level {
        case .instant: effort = settings.instantEffort
        case .fast: effort = settings.fastEffort
        case .deep: effort = settings.deepEffort
        }
        return ClaudeCLI.Config(
            env: Self.mcpEnvironment(access),
            model: model(for: level),
            systemPrompt: AgentRunner.systemPrompt,
            effort: effort,
            extraArgs: Self.mcpArguments(access) + [
                "--permission-mode", "dontAsk",
                "--permission-prompts", "none",
                "--max-turns", "\(settings.agentMaxTurns)",
                "--allowedTools", "mcp__\(MCPServer.serverName)",
                "--disallowedTools", "Agent", "TaskStop",
            ]
        )
    }

    /// The token travels only in the child's environment (AD-16, FR-50).
    nonisolated static func mcpEnvironment(_ access: AgentToolAccess) -> [String: String] {
        [MCPServer.tokenVariable: access.mcpToken]
    }

    /// The arguments for the tools: the PATH of the config file, never its content nor the token.
    nonisolated static func mcpArguments(_ access: AgentToolAccess) -> [String] {
        ["--mcp-config", access.mcpConfigPath]
    }

    private func cli(_ level: AgentLevel) -> ClaudeCLI {
        switch level {
        case .instant: return cliInstant
        case .fast: return cliFast
        case .deep: return cliDeep
        }
    }

    /// Keeps `claude` processes ready, already connected to the tools.
    func prewarm() {
        guard availability == .available else { return }
        refreshExecutable()
        if cliStatus == .unverified(nil) { refreshStatus() }
        // The Long session starts with the first request, never in advance (AD-6).
        if usesSession { return }
        var pairs: [(ClaudeCLI, ClaudeCLI.Config)] = []
        if let c = config(.deep) { pairs.append((cliDeep, c)) }
        if settings.useFastModel, let c = config(.fast) { pairs.append((cliFast, c)) }
        if settings.instantLevel, let c = config(.instant) { pairs.append((cliInstant, c)) }
        for (cli, c) in pairs {
            DispatchQueue.global(qos: .utility).async { cli.prewarm(c) }
        }
    }

    /// «Riavvio l'Agente» and similar, for the HUD through AgentRunner (engines never touch the HUD).
    var onNotice: ((String) -> Void)?
    /// The notice of a Long-session restart (the Bench counts it).
    nonisolated static let restartNotice = "Riavvio l'Agente"
    /// What the app knows about the `claude` version (FR-45).
    private(set) var cliStatus: CLIStatus = .unverified(nil)
    /// `claude` answered without the subscription login: no Long session until the engines are checked again.
    private var loginFailed = false
    private var longSessionWatch: AnyCancellable?

    /// Reads `claude --version` in the background; the status page and the Long session use it.
    /// `force`: read it again (engines checked again, a CLI upgraded in place).
    func refreshStatus(force: Bool = false) {
        refreshExecutable()
        if force { loginFailed = false }
        let cli = cliDeep
        Task.detached(priority: .utility) { [weak self] in
            let status = cli.status(force: force)
            await MainActor.run {
                guard let self else { return }
                let shown = self.loginFailed ? status.unverifiedForLogin : status
                guard self.cliStatus != shown else { return }
                self.cliStatus = shown
                Log.info("Motore Claude: \(shown)")
            }
        }
    }

    /// Long session only with a verified CLI and the switch on (FR-42, FR-45, NFR-15).
    private var usesSession: Bool { settings.longSession && cliStatus.isVerified }

    /// Ends both Long sessions (memory emptied, private mode, switch turned off).
    func endSessions(reason: String) {
        cliDeep.endSession(reason: reason)
        cliFast.endSession(reason: reason)
        cliInstant.endSession(reason: reason)
    }

    /// The Long session is retried once only when a live session died before any action (FR-28):
    /// a fresh session failing at once would fail again.
    nonisolated static func retriesDeadSession(reused: Bool, effectfulCalls: Int, cancelled: Bool) -> Bool {
        reused && effectfulCalls == 0 && !cancelled
    }

    func run(_ request: AgentRequest) async throws -> String {
        let level = effective(request.level)
        guard let config = config(level) else { throw AgentEngineError.failed("server strumenti non avviato") }
        refreshExecutable()
        if longSessionWatch == nil {
            longSessionWatch = settings.$longSession.dropFirst().sink { [weak self] on in
                if !on { self?.endSessions(reason: "Sessione lunga spenta") }
            }
        }
        let cli = cli(level)
        var inSession = usesSession
        while true {
            do {
                let data: Data
                if inSession {
                    data = try await runInSession(cli, config, request)
                } else {
                    data = try await cli.run(config, message: request.message, timeout: request.clock.remaining, clock: request.clock, onPhase: onPhase)
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
                case .failed, .noOutput, .sessionDied, .streamEnded:
                    if ClaudeEngine.isLoginMessage(message) {
                        if !loginFailed {
                            loginFailed = true
                            cliStatus = cliStatus.unverifiedForLogin
                            Log.info("Motore Claude: avvio senza il login dell'abbonamento, \(cliStatus)")
                        }
                        let tools = toolAccess()?.tools
                        if inSession, (tools?.effectfulCalls ?? 1) == 0, tools?.escalation == nil {
                            // Without a verified login: the same request with one process, as before (FR-45).
                            inSession = false
                            continue
                        }
                        throw AgentEngineError.loginNeeded(message)
                    }
                    if ClaudeEngine.isNetworkMessage(message) { throw AgentEngineError.network(message) }
                    throw AgentEngineError.failed(message)
                }
            }
        }
    }

    private func runInSession(_ cli: ClaudeCLI, _ config: ClaudeCLI.Config, _ request: AgentRequest) async throws -> Data {
        // The session never remembers more turns than the conversation memory allows.
        let maxRequests = max(1, min(settings.sessionMaxRequests, settings.conversationMemoryCount))
        let tools = toolAccess()?.tools
        let model = config.model
        let notice: @Sendable (String) -> Void = { [weak self] reason in
            Log.info("Agente (claude/\(model)): riavvio la sessione, \(reason)")
            Task { @MainActor in self?.onNotice?(ClaudeEngine.restartNotice) }
        }
        func attempt() async throws -> Data {
            // Both messages are composed here, on the main actor: the CLI only picks one.
            let cursor = cli.liveCursor(memory: request.memory)
            let short = cursor.map(request.messageSince)
            let full = request.message
            return try await cli.runInSession(config, memory: request.memory, maxRequests: maxRequests,
                                              timeout: request.clock.remaining, clock: request.clock,
                                              message: { seq in seq != nil && seq == cursor ? (short ?? full) : full },
                                              onPhase: onPhase, onRestart: notice)
        }
        do {
            return try await attempt()
        } catch ClaudeCLIError.sessionDied(let m)
                    where Self.retriesDeadSession(reused: cli.lastAttemptReused, effectfulCalls: tools?.effectfulCalls ?? 1,
                                                  cancelled: tools?.cancelled ?? true) && tools?.escalation == nil {
            Log.info("Agente (claude/\(model)): sessione chiusa a metà senza azioni \(m), ripeto la richiesta")
            onNotice?("Ripeto la richiesta")
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

    /// Ends the turn but keeps the Long session (scalata from the Instant level).
    func interrupt() {
        cliInstant.interruptCurrent()
        cliFast.interruptCurrent()
        cliDeep.interruptCurrent()
    }

    func cancel() {
        cliDeep.cancelCurrent()
        cliFast.cancelCurrent()
        cliInstant.cancelCurrent()
    }

    func shutdown() {
        pause.cancel()
        endSessions(reason: "app chiusa")
        cliDeep.shutdown()
        cliFast.shutdown()
        cliInstant.shutdown()
    }
}
