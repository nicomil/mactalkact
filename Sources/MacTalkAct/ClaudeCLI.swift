import Foundation

enum ClaudeCLIError: LocalizedError {
    case notFound
    case timeout
    case failed(String)
    case noOutput(String)
    /// A Long session ended in the middle of a message (the process exited).
    case sessionDied(String)
    /// The output stream ended before a `result` (the process is gone).
    case streamEnded(String)

    var errorDescription: String? {
        switch self {
        case .notFound: return "Comando «claude» non trovato. Installa Claude Code o indica il percorso nelle impostazioni."
        case .timeout: return "Claude non ha risposto in tempo"
        case .failed(let m): return "Claude: \(m)"
        case .noOutput(let m): return "Nessuna risposta da Claude \(m)"
        case .sessionDied(let m): return "La sessione di Claude si è chiusa \(m)"
        case .streamEnded(let m): return "Nessuna risposta da Claude \(m)"
        }
    }
}

/// Talks to Claude through the `claude` command (Claude Code) in print mode,
/// so requests run on the user's Claude subscription instead of an API key.
///
/// Starting the CLI takes ~2 s, so one process is always kept ready ("warm"):
/// it is spawned in advance and waits on stdin. A request is written to it,
/// and a fresh spare is started right after, ready for the next one.
final class ClaudeCLI: @unchecked Sendable {

    struct Config: Equatable {
        /// Extra environment of the child (the MCP token: never in the arguments, AD-16).
        var env: [String: String] = [:]
        let model: String
        let systemPrompt: String
        /// JSON Schema for structured output; empty = plain text answer.
        var schemaJSON: String = ""
        var effort: String = "low"
        /// Extra CLI arguments (e.g. MCP server and tool permissions for the agent).
        var extraArgs: [String] = []
    }

    private final class Running {
        let process: Process
        let stdin: FileHandle
        let stdout: FileHandle
        let stderr: Box<Data>
        let config: Config
        let started = Date()

        init(process: Process, stdin: FileHandle, stdout: FileHandle, stderr: Box<Data>, config: Config) {
            self.process = process
            self.stdin = stdin
            self.stdout = stdout
            self.stderr = stderr
            self.config = config
        }

        func terminate() {
            if process.isRunning { process.terminate() }
        }
    }

    private let lock = NSLock()
    private var spare: Running?
    private var current: Running?
    /// A warm process older than this is replaced, in case its session went stale.
    private let maxSpareAge: TimeInterval = 20 * 60

    var executablePath: () -> String? = { ClaudeCLI.locate(custom: nil) }

    // MARK: Locating the binary

    /// Finder-launched apps get a minimal PATH, so look in the usual install places.
    static func locate(custom: String?) -> String? {
        let fm = FileManager.default
        if let custom, !custom.isEmpty {
            let expanded = (custom as NSString).expandingTildeInPath
            return fm.isExecutableFile(atPath: expanded) ? expanded : nil
        }
        let home = NSHomeDirectory()
        let candidates = [
            "\(home)/.local/bin/claude",
            "/opt/homebrew/bin/claude",
            "/usr/local/bin/claude",
            "\(home)/.claude/local/claude",
            "\(home)/.npm-global/bin/claude",
            "\(home)/.bun/bin/claude",
        ]
        if let hit = candidates.first(where: fm.isExecutableFile(atPath:)) { return hit }

        // Last resort: ask a login shell.
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/zsh")
        p.arguments = ["-lc", "command -v claude"]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = Pipe()
        guard (try? p.run()) != nil else { return nil }
        p.waitUntilExit()
        let text = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let path = text.split(separator: "\n").last.map(String.init)?.trimmingCharacters(in: .whitespaces) ?? ""
        return fm.isExecutableFile(atPath: path) ? path : nil
    }

    // MARK: Public API

    /// Makes sure a ready process exists for `config`.
    func prewarm(_ config: Config) {
        lock.lock()
        defer { lock.unlock() }
        if let s = spare, s.config == config, s.process.isRunning,
           Date().timeIntervalSince(s.started) < maxSpareAge {
            return
        }
        spare?.terminate()
        spare = try? spawn(config)
    }

    /// Sends one message and returns the `structured_output` JSON as Data.
    /// Sends one message; for a plain-text config the Data is the final answer text.
    func run(_ config: Config, message: String, timeout: TimeInterval = 60, clock: TurnClock? = nil,
             onPhase: PhaseSink? = nil) async throws -> Data {
        let proc: Running
        if let spare = takeSpare(config) {
            proc = spare
            onPhase?(.sessionReused)
        } else {
            proc = try spawn(config)
            onPhase?(.sessionStarted)
        }
        lock.withLock { current = proc }
        defer {
            lock.withLock { current = nil }
            proc.terminate()
            // Get the next one ready while the user acts on this answer.
            DispatchQueue.global(qos: .utility).async { [weak self] in self?.prewarm(config) }
        }

        let line: [String: Any] = ["type": "user", "message": ["role": "user", "content": message]]
        var data = try JSONSerialization.data(withJSONObject: line)
        data.append(0x0A)
        try proc.stdin.write(contentsOf: data)
        try proc.stdin.close()

        return try await withThrowingTaskGroup(of: Data.self) { group in
            group.addTask {
                do { return try await Self.readResult(proc, onPhase: onPhase) } catch ClaudeCLIError.streamEnded(let m) {
                    throw ClaudeCLIError.noOutput(m)
                }
            }
            group.addTask {
                if let clock { await clock.untilExpired() } else { try await Task.sleep(for: .seconds(timeout)) }
                try Task.checkCancellation()
                // The reader does not stop on cancellation: ending the process ends its stream.
                proc.terminate()
                throw ClaudeCLIError.timeout
            }
            defer { group.cancelAll() }
            guard let result = try await group.next() else { throw ClaudeCLIError.timeout }
            return result
        }
    }

    /// Stops an in-flight request ("stop!"). Before the message is written (waiting for a preparation,
    /// starting the process) the request is marked, so it ends without sending anything.
    func cancelCurrent() {
        lock.withLock { () -> Running? in
            if requestOpen, current == nil { stopRequested = true }
            return current
        }?.terminate()
    }

    /// Ends the turn in progress but keeps a Long session alive (scalata, FR-43): the CLI answers
    /// with a `result` of `error_during_execution`. Without a session the process is closed.
    func interruptCurrent() {
        let (proc, isSession) = lock.withLock { (current, current != nil && current === session?.process) }
        guard let proc else { return }
        guard isSession else { proc.terminate(); return }
        lock.withLock { interrupted = true }
        let line: [String: Any] = ["type": "control_request", "request_id": "interrupt-\(UUID().uuidString.prefix(8))",
                                   "request": ["subtype": "interrupt"]]
        guard var data = try? JSONSerialization.data(withJSONObject: line) else { proc.terminate(); return }
        data.append(0x0A)
        if (try? proc.stdin.write(contentsOf: data)) == nil { proc.terminate(); return }
        // If the CLI does not close the turn quickly, the process goes: the fast level must not wait.
        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 3) { [weak self] in
            guard let self else { return }
            let stuck = self.lock.withLock { self.interrupted && self.current === proc }
            if stuck { Log.info("claude: interruzione senza risposta, chiudo il processo"); proc.terminate() }
        }
    }

    func shutdown() {
        lock.lock()
        spare?.terminate()
        current?.terminate()
        spare = nil
        session?.process.terminate()
        session = nil
        sessionEpoch += 1 // a preparation still starting closes its process
        lock.unlock()
    }

    // MARK: Long session (FR-42, AD-6)

    /// One `claude` process kept open between requests: stdin stays open, every message gets
    /// its own `result`, the prompt cache stays warm. Started at the first request or, with «Sessione
    /// pronta all'ascolto», when the user starts talking to the app (Story 11.2, AD-6 amended).
    private final class Session {
        let process: Running
        var lines: AsyncLineSequence<FileHandle.AsyncBytes>.AsyncIterator
        /// A prepared session that has seen nothing adopts the generation of its first request.
        var generation: Int
        var cursor: Int
        var requests = 0
        var lastUsed = Date()
        /// Started in advance and not used yet: the first request sends the full message.
        var prepared = false

        init(process: Running, generation: Int) {
            self.process = process
            self.lines = process.stdout.bytes.lines.makeAsyncIterator()
            self.generation = generation
            self.cursor = 0
        }
    }

    private var session: Session?
    /// Whether the last `runInSession` reused a live session (a fresh one failing is not retried).
    private(set) var lastAttemptReused = false
    /// The turn in progress was interrupted on purpose: its error result does not end the session.
    private var interrupted = false
    /// A preparation starting the process right now (Story 11.2): a request waits for it.
    private var preparing: Task<Void, Never>?
    /// A request is using (or about to start) the Long session: no preparation meanwhile.
    private var inRequest = false
    /// A request on the Long session has started (it may still wait for a preparation).
    private var requestOpen = false
    /// «stop» arrived before the message was written: the request ends without sending it.
    private var stopRequested = false
    /// Grows when the session is closed: a preparation started before closes its own process.
    private var sessionEpoch = 0
    /// Why the Long session was closed last time (log and `--fallback-test`).
    private(set) var lastEndReason: String?
    /// Idle time after which the session is closed; shorter only in `--fallback-test`.
    var maxIdle: TimeInterval {
        get { lock.withLock { _maxIdle } }
        set { lock.withLock { _maxIdle = newValue } }
    }
    private var _maxIdle = SessionPolicy.maxIdle
    private let countLock = NSLock()
    private var spawnCount = 0
    private var lastProcess: Process?
    /// `claude` processes started by this instance (`--fallback-test`: never two per level).
    var spawns: Int { countLock.withLock { spawnCount } }
    /// Debug only: the last process started is still running.
    var lastSpawnRunning: Bool { countLock.withLock { lastProcess?.isRunning ?? false } }
    /// Debug only: a preparation is starting the process right now.
    var debugPreparing: Bool { lock.withLock { preparing != nil } }
    /// Debug only: a request on the Long session has started (it may be waiting for a preparation).
    var debugRequestOpen: Bool { lock.withLock { requestOpen } }
    /// Debug only: a Long session is open with a running process.
    var hasLiveSession: Bool { lock.withLock { session?.process.process.isRunning == true } }

    /// The entry of this request is added right after it returns: the session has seen it.
    static func cursor(after memory: MemorySnapshot) -> Int { memory.lastSeq + 1 }

    /// The cursor of the live session, if any: the engine composes the short message on its own actor.
    /// A session prepared and never used has seen nothing: no cursor, the full message goes.
    func liveCursor(memory: MemorySnapshot) -> Int? {
        lock.withLock { session.flatMap { $0.generation == memory.generation && $0.process.process.isRunning && !$0.prepared ? $0.cursor : nil } }
    }

    /// Ends a session that stays idle for `SessionPolicy.maxIdle`: no process waits for hours.
    /// A prepared session never used follows the same rule.
    private func scheduleIdleEnd(_ s: Session) {
        let used = lock.withLock { s.lastUsed }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + maxIdle) { [weak self] in
            guard let self else { return }
            let idle = self.lock.withLock { self.session === s && s.lastUsed == used }
            if idle { self.endSession(reason: "inattiva da 10 minuti") }
        }
    }
    /// Prompt tokens read from the cache in the last Long-session turn (log and `--session-test`).
    private(set) var lastCacheRead = 0

    /// Closes the Long session (shutdown, private mode, settings changed).
    func endSession(reason: String) {
        let ended = lock.withLock { () -> (Session, Bool)? in
            defer { session = nil }
            sessionEpoch += 1 // a preparation in progress must not bring the session back
            return session.map { ($0, $0.prepared) }
        }
        guard let (s, prepared) = ended else { return }
        s.process.terminate()
        lock.withLock { lastEndReason = reason }
        Log.info("claude: sessione chiusa\(prepared ? " (pronta, mai usata)" : ""), \(reason)")
    }

    /// Closes the session only if it was prepared and never used (engine changed, switch turned off).
    func endPreparedSession(reason: String) {
        let unused = lock.withLock { session?.prepared == true && current == nil && !requestOpen }
        if unused { endSession(reason: reason) }
    }

    // MARK: Session ready when the user speaks (Story 11.2, FR-59)

    /// Starts the Long session now, before the request, unless one is alive, being prepared or in use.
    /// Checked with the real CLI (2.1.312, 28/10): `claude -p --input-format stream-json` connects to
    /// the MCP servers as soon as it starts (initialize and tools/list ~1.2 s after launch), but writes
    /// `init` only after the first message. So the preparation is the start of the process: nothing is
    /// written to stdin and no token is spent; `init` arrives ~0.03 s after the request's message.
    /// Returns whether a preparation started.
    @discardableResult
    func prepareSession(_ config: Config, generation: Int) -> Bool {
        lock.withLock { () -> Bool in
            guard preparing == nil, !inRequest, current == nil else { return false }
            if let s = session, s.process.process.isRunning { return false }
            // Never a warm spare next to a Long session: one process per level.
            spare?.terminate()
            spare = nil
            let epoch = sessionEpoch
            // The task takes the lock only after this section: `preparing` is set before it can end.
            preparing = Task.detached(priority: .userInitiated) { [weak self] in
                self?.startPrepared(config, generation: generation, epoch: epoch)
            }
            return true
        }
    }

    private func startPrepared(_ config: Config, generation: Int, epoch: Int) {
        do {
            let proc = try spawn(config)
            let s = Session(process: proc, generation: generation)
            s.prepared = true
            let kept = lock.withLock { () -> Bool in
                defer { preparing = nil }
                guard sessionEpoch == epoch, session?.process.process.isRunning != true else { return false }
                session = s
                return true
            }
            guard kept else { proc.terminate(); return }
            Log.info("claude: sessione pronta all'ascolto (\(config.model), \(config.effort))")
            scheduleIdleEnd(s)
        } catch {
            lock.withLock { preparing = nil }
            Log.info("claude: sessione pronta non avviata, \(error.localizedDescription)")
        }
    }

    /// Waits for a preparation in progress, then marks the session as in use (one process per level).
    /// The wait is bounded by the turn's clock, and «stop» during it ends the request.
    /// Polled, not awaited: the start of a process cannot be cancelled, the wait can.
    private func beginRequest(clock: TurnClock?, timeout: TimeInterval) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            let waiting = lock.withLock { () -> Bool in
                if preparing != nil { return true }
                inRequest = true
                return false
            }
            guard waiting else { return }
            if Task.isCancelled || lock.withLock({ stopRequested }) { throw ClaudeCLIError.failed("interrotto dall'utente") }
            let expired = clock.map { $0.remaining <= 0 && !$0.isPaused } ?? (Date() >= deadline)
            if expired { throw ClaudeCLIError.timeout }
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    /// Sends one message on the Long session, starting it again first when a rule says so.
    /// `message(nil)` is the full message, `message(seq)` the one with only the memory after `seq`.
    /// `onRestart` is called with the reason when a live session is replaced.
    func runInSession(_ config: Config, memory: MemorySnapshot, maxRequests: Int, timeout: TimeInterval, clock: TurnClock? = nil,
                      message: (Int?) -> String, onPhase: PhaseSink?, onRestart: (String) -> Void) async throws -> Data {
        lock.withLock { requestOpen = true; stopRequested = false }
        defer { lock.withLock { requestOpen = false; stopRequested = false } }
        // A request during the preparation waits for it and uses that process (Story 11.2).
        try await beginRequest(clock: clock, timeout: timeout)
        defer { lock.withLock { inRequest = false } }
        // Never a warm spare next to a Long session: one process per level.
        lock.withLock { spare?.terminate(); spare = nil }
        var live = lock.withLock { session }
        if let s = live {
            let (requests, lastUsed) = lock.withLock { () -> (Int, Date) in
                // A prepared session has seen nothing: it takes the memory of this request, no restart.
                if s.prepared { s.generation = memory.generation }
                return (s.requests, s.lastUsed)
            }
            let old = s.process.config
            let reason = !s.process.process.isRunning ? "processo chiuso"
                : SessionPolicy.restartReason(requests: requests, maxRequests: maxRequests,
                                              idle: Date().timeIntervalSince(lastUsed),
                                              configChanged: old != config,
                                              modelOrEffortChanged: old.model != config.model || old.effort != config.effort,
                                              memoryChanged: lock.withLock { s.generation } != memory.generation)
            if let reason {
                endSession(reason: reason)
                onRestart(reason)
                live = nil
            }
        }
        let s: Session
        let text: String
        var usedPrepared = false
        if let live {
            s = live
            let (prepared, cursor) = lock.withLock { () -> (Bool, Int) in
                defer { live.prepared = false }
                return (live.prepared, live.cursor)
            }
            // A prepared session has seen nothing yet: the full message.
            text = prepared ? message(nil) : message(cursor)
            usedPrepared = prepared
            if prepared {
                Log.info(String(format: "claude: uso la sessione pronta, avviata %.1f s fa", Date().timeIntervalSince(s.process.started)))
            }
            onPhase?(.sessionReused)
        } else {
            s = Session(process: try spawn(config), generation: memory.generation)
            lock.withLock { session = s }
            text = message(nil)
            onPhase?(.sessionStarted)
        }
        // A prepared session never used is a fresh process: dying at once is not retried (FR-28).
        lock.withLock { lastAttemptReused = live != nil && !usedPrepared; interrupted = false }
        lock.withLock { current = s.process }
        defer { lock.withLock { current = nil } }
        // «stop» before anything was written: the session stays, unused, for the next request.
        if Task.isCancelled || lock.withLock({ stopRequested }) {
            lock.withLock { s.prepared = true }
            scheduleIdleEnd(s)
            throw ClaudeCLIError.failed("interrotto dall'utente")
        }

        let line: [String: Any] = ["type": "user", "message": ["role": "user", "content": text]]
        var data = try JSONSerialization.data(withJSONObject: line)
        data.append(0x0A)
        do { try s.process.stdin.write(contentsOf: data) } catch {
            endSession(reason: "scrittura non riuscita")
            throw ClaudeCLIError.sessionDied("(scrittura non riuscita)")
        }

        let stderr = s.process.stderr
        do {
            let result = try await withThrowingTaskGroup(of: Data.self) { group in
                group.addTask {
                    try await Self.readResult(next: { try await s.lines.next() }, stderr: stderr, onPhase: onPhase,
                                              onCache: { [weak self] n in self?.lock.withLock { self?.lastCacheRead = n } })
                }
                group.addTask {
                    if let clock { await clock.untilExpired() } else { try await Task.sleep(for: .seconds(timeout)) }
                    try Task.checkCancellation()
                    s.process.terminate() // the reader stops only when the stream ends
                    throw ClaudeCLIError.timeout
                }
                defer { group.cancelAll() }
                guard let result = try await group.next() else { throw ClaudeCLIError.timeout }
                return result
            }
            lock.withLock {
                s.requests += 1
                s.lastUsed = Date()
                s.cursor = Self.cursor(after: memory)
            }
            scheduleIdleEnd(s)
            return result
        } catch ClaudeCLIError.timeout {
            endSession(reason: "turno scaduto")
            throw ClaudeCLIError.timeout
        } catch ClaudeCLIError.streamEnded(let m) {
            // The stream ended without a result: the process is gone.
            endSession(reason: "processo uscito")
            throw ClaudeCLIError.sessionDied(m)
        } catch ClaudeCLIError.noOutput(let m) {
            // A result without text: the process is fine, the session stays.
            lock.withLock { s.requests += 1; s.lastUsed = Date(); s.cursor = Self.cursor(after: memory) }
            scheduleIdleEnd(s)
            throw ClaudeCLIError.noOutput(m)
        } catch ClaudeCLIError.failed(let m) where lock.withLock({ interrupted }) && s.process.process.isRunning {
            // Interrupted on purpose (scalata): the session stays for the next Instant request. The cursor
            // stays too: the outcome of this request comes from the fast level, so it is sent next time.
            lock.withLock { s.requests += 1; s.lastUsed = Date(); interrupted = false }
            scheduleIdleEnd(s)
            throw ClaudeCLIError.failed(m)
        } catch {
            // An error result (limit, login) leaves the process usable, but a fresh one is safer.
            endSession(reason: "errore: \(error.localizedDescription.prefix(60))")
            throw error
        }
    }

    // MARK: Version (FR-45, AD-14)

    /// `claude --version`, read once per executable path; minimum for the Long session.
    static let minimumForSession = "2.1.299"

    /// Blocking: call it off the main thread. `force` reads the version again (after an upgrade).
    func status(force: Bool = false) -> CLIStatus {
        guard let path = executablePath() else { return .unverified(nil) }
        if !force, let cached = lock.withLock({ statusCache }), cached.path == path { return cached.status }
        let status = CLIStatus.from(versionOutput: Self.versionOutput(path), minimum: Self.minimumForSession)
        lock.withLock { statusCache = (path, status) }
        return status
    }

    /// `<path> --version`, at most `limit` seconds: a stuck binary never blocks the check.
    static func versionOutput(_ path: String, limit: TimeInterval = 5) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = ["--version"]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = Pipe()
        guard (try? p.run()) != nil else { return nil }
        let deadline = Date().addingTimeInterval(limit)
        while p.isRunning, Date() < deadline { Thread.sleep(forTimeInterval: 0.05) }
        if p.isRunning { p.terminate(); return nil }
        return String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)
    }

    private var statusCache: (path: String, status: CLIStatus)?

    // MARK: Internals

    private func takeSpare(_ config: Config) -> Running? {
        lock.lock()
        defer { lock.unlock() }
        guard let s = spare else { return nil }
        spare = nil
        if s.config == config, s.process.isRunning, Date().timeIntervalSince(s.started) < maxSpareAge { return s }
        s.terminate()
        return nil
    }

    private static func workingDirectory() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = base.appendingPathComponent("MacTalkAct", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func spawn(_ config: Config) throws -> Running {
        guard let path = executablePath() else { throw ClaudeCLIError.notFound }

        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.currentDirectoryURL = Self.workingDirectory()
        p.arguments = [
            "-p",
            "--input-format", "stream-json",
            "--output-format", "stream-json",
            // Token-by-token events: the Bench measures the first token, not the first full message.
            "--include-partial-messages",
            "--verbose",
            "--model", config.model,
            "--effort", config.effort,
            "--system-prompt", config.systemPrompt,
            // No built-in tools, user MCP servers, hooks, plugins or skills:
            // only what the app explicitly provides.
            "--tools", "",
            "--strict-mcp-config",
            "--setting-sources", "",
            "--disable-slash-commands",
            "--no-session-persistence",
        ]
        if !config.schemaJSON.isEmpty { p.arguments! += ["--json-schema", config.schemaJSON] }
        // Variadic flags (--allowedTools, --disallowedTools) go last.
        p.arguments! += config.extraArgs

        var env = ProcessInfo.processInfo.environment
        let home = NSHomeDirectory()
        env["PATH"] = "\(home)/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        // Use the subscription login, and don't look like a nested Claude Code session.
        // CLAUDE_CODE_SIMPLE would start the «bare» mode without the subscription login (AD-14).
        for key in ["ANTHROPIC_API_KEY", "CLAUDECODE", "CLAUDE_CODE_ENTRYPOINT", "CLAUDE_CODE_SIMPLE"] { env.removeValue(forKey: key) }
        for (k, v) in config.env { env[k] = v }
        p.environment = env

        let inPipe = Pipe(), outPipe = Pipe(), errPipe = Pipe()
        p.standardInput = inPipe
        p.standardOutput = outPipe
        p.standardError = errPipe

        let errBuffer = Box(Data())
        errPipe.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            if chunk.isEmpty { handle.readabilityHandler = nil; return }
            if errBuffer.value.count < 16_000 { errBuffer.value.append(chunk) }
        }

        try p.run()
        countLock.withLock { spawnCount += 1; lastProcess = p }
        return Running(process: p, stdin: inPipe.fileHandleForWriting, stdout: outPipe.fileHandleForReading,
                       stderr: errBuffer, config: config)
    }

    /// The phase event carried by one stream-json event, if any (pure, tested by `--selftest`).
    static func phase(of obj: [String: Any]) -> EnginePhase? {
        switch obj["type"] as? String {
        case "system":
            guard obj["subtype"] as? String == "init", let servers = obj["mcp_servers"] as? [[String: Any]],
                  !servers.isEmpty else { return nil }
            return .serverConnected
        case "stream_event", "assistant": return .firstToken
        case "result": return .turnFinished(turns: obj["num_turns"] as? Int)
        default: return nil
        }
    }

    private static func readResult(_ proc: Running, onPhase: PhaseSink? = nil) async throws -> Data {
        var lines = proc.stdout.bytes.lines.makeAsyncIterator()
        return try await readResult(next: { try await lines.next() }, stderr: proc.stderr, onPhase: onPhase)
    }

    /// Reads events until the `result` of one message. A Long session calls it once per message
    /// on the same line iterator, so no buffered line is lost between two requests.
    private static func readResult(next: () async throws -> String?, stderr: Box<Data>, onPhase: PhaseSink?,
                                   onCache: ((Int) -> Void)? = nil) async throws -> Data {
        var sawToken = false
        while let line = try await next() {
            guard let obj = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any] else { continue }
            if obj["type"] as? String == "system", obj["subtype"] as? String == "init",
               let servers = obj["mcp_servers"] as? [[String: Any]], !servers.isEmpty {
                let status = servers.map { "\($0["name"] ?? "?")=\($0["status"] ?? "?")" }.joined(separator: ", ")
                Log.debug("claude: server MCP \(status)")
            }
            if let phase = phase(of: obj), phase != .firstToken || !sawToken {
                if phase == .firstToken { sawToken = true }
                onPhase?(phase)
            }
            guard obj["type"] as? String == "result" else { continue }
            if let usage = obj["usage"] as? [String: Any] {
                onCache?(usage["cache_read_input_tokens"] as? Int ?? 0)
                Log.info("claude: cache letta \(usage["cache_read_input_tokens"] as? Int ?? 0), scritta \(usage["cache_creation_input_tokens"] as? Int ?? 0), nuovi \(usage["input_tokens"] as? Int ?? 0)")
            }

            if (obj["is_error"] as? Bool) == true || (obj["subtype"] as? String) != "success" {
                let msg = (obj["result"] as? String) ?? (obj["subtype"] as? String) ?? "errore"
                throw ClaudeCLIError.failed(msg)
            }
            if let structured = obj["structured_output"], JSONSerialization.isValidJSONObject(structured) {
                return try JSONSerialization.data(withJSONObject: structured)
            }
            if let text = obj["result"] as? String, let data = text.data(using: .utf8) {
                return data
            }
            throw ClaudeCLIError.noOutput("")
        }
        let err = String(data: stderr.value, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        throw ClaudeCLIError.streamEnded(err.isEmpty ? "" : "(\(err.prefix(300)))")
    }
}
