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
    func run(_ config: Config, message: String, timeout: TimeInterval = 60, onPhase: PhaseSink? = nil) async throws -> Data {
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
                try await Task.sleep(for: .seconds(timeout))
                // The reader does not stop on cancellation: ending the process ends its stream.
                proc.terminate()
                throw ClaudeCLIError.timeout
            }
            defer { group.cancelAll() }
            guard let result = try await group.next() else { throw ClaudeCLIError.timeout }
            return result
        }
    }

    /// Stops an in-flight request ("stop!").
    func cancelCurrent() {
        lock.withLock { current }?.terminate()
    }

    func shutdown() {
        lock.lock()
        spare?.terminate()
        current?.terminate()
        spare = nil
        session?.process.terminate()
        session = nil
        lock.unlock()
    }

    // MARK: Long session (FR-42, AD-6)

    /// One `claude` process kept open between requests: stdin stays open, every message gets
    /// its own `result`, the prompt cache stays warm. Started at the first request, never in advance.
    private final class Session {
        let process: Running
        var lines: AsyncLineSequence<FileHandle.AsyncBytes>.AsyncIterator
        let generation: Int
        var cursor: Int
        var requests = 0
        var lastUsed = Date()

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

    /// The entry of this request is added right after it returns: the session has seen it.
    static func cursor(after memory: MemorySnapshot) -> Int { memory.lastSeq + 1 }

    /// The cursor of the live session, if any: the engine composes the short message on its own actor.
    func liveCursor(memory: MemorySnapshot) -> Int? {
        lock.withLock { session.flatMap { $0.generation == memory.generation && $0.process.process.isRunning ? $0.cursor : nil } }
    }

    /// Ends a session that stays idle for `SessionPolicy.maxIdle`: no process waits for hours.
    private func scheduleIdleEnd(_ s: Session) {
        let used = lock.withLock { s.lastUsed }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + SessionPolicy.maxIdle) { [weak self] in
            guard let self else { return }
            let idle = self.lock.withLock { self.session === s && s.lastUsed == used }
            if idle { self.endSession(reason: "inattiva da 10 minuti") }
        }
    }
    /// Prompt tokens read from the cache in the last Long-session turn (log and `--session-test`).
    private(set) var lastCacheRead = 0

    /// Closes the Long session (shutdown, private mode, settings changed).
    func endSession(reason: String) {
        let s = lock.withLock { () -> Session? in defer { session = nil }; return session }
        guard let s else { return }
        s.process.terminate()
        Log.info("claude: sessione chiusa, \(reason)")
    }

    /// Sends one message on the Long session, starting it again first when a rule says so.
    /// `message(nil)` is the full message, `message(seq)` the one with only the memory after `seq`.
    /// `onRestart` is called with the reason when a live session is replaced.
    func runInSession(_ config: Config, memory: MemorySnapshot, maxRequests: Int, timeout: TimeInterval,
                      message: (Int?) -> String, onPhase: PhaseSink?, onRestart: (String) -> Void) async throws -> Data {
        // Never a warm spare next to a Long session: one process per level.
        lock.withLock { spare?.terminate(); spare = nil }
        var live = lock.withLock { session }
        if let s = live {
            let (requests, lastUsed) = lock.withLock { (s.requests, s.lastUsed) }
            let old = s.process.config
            let reason = !s.process.process.isRunning ? "processo chiuso"
                : SessionPolicy.restartReason(requests: requests, maxRequests: maxRequests,
                                              idle: Date().timeIntervalSince(lastUsed),
                                              configChanged: old != config,
                                              modelOrEffortChanged: old.model != config.model || old.effort != config.effort,
                                              memoryChanged: s.generation != memory.generation)
            if let reason {
                endSession(reason: reason)
                onRestart(reason)
                live = nil
            }
        }
        let s: Session
        let text: String
        if let live {
            s = live
            text = message(lock.withLock { live.cursor })
            onPhase?(.sessionReused)
        } else {
            s = Session(process: try spawn(config), generation: memory.generation)
            lock.withLock { session = s }
            text = message(nil)
            onPhase?(.sessionStarted)
        }
        lock.withLock { lastAttemptReused = live != nil }
        lock.withLock { current = s.process }
        defer { lock.withLock { current = nil } }

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
                    try await Task.sleep(for: .seconds(timeout))
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
