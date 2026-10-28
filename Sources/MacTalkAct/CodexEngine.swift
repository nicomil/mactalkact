import Foundation

/// Codex through `codex exec` on the user's ChatGPT login (FR-26), with the same tools,
/// prompt and confirmations as Claude.
@MainActor
final class CodexEngine: AgentEngine {
    let id = EngineID.codex
    private let settings: AppSettings
    private let toolAccess: () -> AgentToolAccess?
    private let cli = CodexCLI()
    private let pause = EnginePause()

    private(set) var availability: AgentAvailability = .missing
    var onAvailabilityChange: ((AgentAvailability) -> Void)?
    var onPhase: PhaseSink?
    /// What the app knows about the `codex` version (FR-45): shown in Stato e diagnostica only.
    private(set) var cliStatus: CLIStatus = .unverified(nil)

    init(settings: AppSettings, toolAccess: @escaping () -> AgentToolAccess?) {
        self.settings = settings
        self.toolAccess = toolAccess
        availability = settings.codexExecutable == nil ? .missing : .available
        refreshAvailability()
    }

    private func setAvailability(_ a: AgentAvailability) {
        guard a != availability else { return }
        availability = a
        Log.info("Motore Codex: \(a)")
        onAvailabilityChange?(a)
    }

    /// Command installed? Logged in? (`codex login status`, off the main thread.)
    func refreshAvailability() {
        if case .paused(let until) = availability, Date() < until { return }
        guard let path = settings.codexExecutable else {
            setAvailability(.missing)
            return
        }
        if let problem = CodexCLI.instructionFilesProblem(approved: settings.approvedCodexInstructionSet) {
            setAvailability(.unavailable(problem))
            return
        }
        Task.detached(priority: .utility) {
            let logged = CodexCLI.isLoggedIn(executable: path)
            await MainActor.run { [weak self] in
                guard let self else { return }
                if case .paused(let until) = self.availability, Date() < until { return }
                self.setAvailability(logged ? .available : .loginNeeded)
            }
            // After the login check, so availability is never delayed by it (read with a time limit).
            let status = CLIStatus.from(versionOutput: ClaudeCLI.versionOutput(path), minimum: CodexCLI.minimumVersion)
            await MainActor.run { [weak self] in
                guard let self, self.cliStatus != status else { return }
                self.cliStatus = status
                Log.info("Motore Codex: \(status)")
            }
        }
    }

    func pauseForLimit(message: String) -> Date {
        let until = LimitMessage.resetDate(from: message) ?? Date().addingTimeInterval(30 * 60)
        setAvailability(.paused(until: until))
        pause.schedule(until: until) { [weak self] in
            guard let self else { return }
            self.setAvailability(.available)
            self.refreshAvailability()
        }
        return until
    }

    func model(for level: AgentLevel) -> String {
        level == .deep || !settings.useFastModel ? settings.codexModel : settings.codexFastModel
    }

    private func effort(for level: AgentLevel) -> String {
        level == .deep || !settings.useFastModel ? settings.codexDeepEffort : settings.codexFastEffort
    }

    /// Nothing to warm: one process per request (spike of Story 4.1).
    func prewarm() {}

    func run(_ request: AgentRequest) async throws -> String {
        guard let access = toolAccess() else { throw AgentEngineError.failed("server strumenti non avviato") }
        // Checked at every request: a file written after the start must not be read as orders (FR-50).
        if let problem = CodexCLI.instructionFilesProblem(approved: settings.approvedCodexInstructionSet) {
            setAvailability(.unavailable(problem))
            throw AgentEngineError.failed("Codex: \(problem)")
        }
        let custom = settings.codexPath
        cli.executablePath = { CodexCLI.locate(custom: custom) }
        let config = CodexCLI.Config(model: model(for: request.level), effort: effort(for: request.level),
                                     instructionsFile: CodexCLI.instructionsFile(AgentRunner.systemPrompt),
                                     mcpURL: access.mcpURL, mcpToken: access.mcpToken)
        let outcome: CodexCLI.Outcome
        do {
            outcome = try await cli.run(config, message: request.message, timeout: request.clock.remaining, clock: request.clock, onPhase: onPhase)
        } catch let error as AgentEngineError {
            if case .notFound = error { setAvailability(.missing) }
            throw error
        }
        switch outcome {
        case .answer(let text):
            return text
        case .failed(let message):
            if LimitMessage.isLimit(message) {
                let until = pauseForLimit(message: message)
                throw AgentEngineError.limit(message: "Codex: limite d'uso raggiunto", until: until)
            }
            if CodexEventParser.isLogin(message) {
                setAvailability(.loginNeeded)
                throw AgentEngineError.loginNeeded("Codex: accesso da rifare (apri ChatGPT o esegui «codex login»)")
            }
            if CodexEventParser.isNetwork(message) {
                throw AgentEngineError.network("Codex: rete non raggiungibile")
            }
            throw AgentEngineError.failed("Codex: \(message.prefix(200))")
        }
    }

    func cancel() { cli.cancelCurrent() }

    func shutdown() {
        pause.cancel()
        cli.cancelCurrent()
    }
}
