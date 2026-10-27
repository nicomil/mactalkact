import Foundation

enum ClaudeCLIError: LocalizedError {
    case notFound
    case timeout
    case failed(String)
    case noOutput(String)

    var errorDescription: String? {
        switch self {
        case .notFound: return "Comando «claude» non trovato. Installa Claude Code o indica il percorso nelle impostazioni."
        case .timeout: return "Claude non ha risposto in tempo"
        case .failed(let m): return "Claude: \(m)"
        case .noOutput(let m): return "Nessuna risposta da Claude \(m)"
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
            group.addTask { try await Self.readResult(proc, onPhase: onPhase) }
            group.addTask {
                try await Task.sleep(for: .seconds(timeout))
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
        lock.unlock()
    }

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
        for key in ["ANTHROPIC_API_KEY", "CLAUDECODE", "CLAUDE_CODE_ENTRYPOINT"] { env.removeValue(forKey: key) }
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

    private static func readResult(_ proc: Running, onPhase: PhaseSink? = nil) async throws -> Data {
        var sawToken = false
        for try await line in proc.stdout.bytes.lines {
            guard let obj = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any] else { continue }
            if obj["type"] as? String == "system", obj["subtype"] as? String == "init",
               let servers = obj["mcp_servers"] as? [[String: Any]], !servers.isEmpty {
                let status = servers.map { "\($0["name"] ?? "?")=\($0["status"] ?? "?")" }.joined(separator: ", ")
                Log.debug("claude: server MCP \(status)")
                onPhase?(.serverConnected)
            }
            if !sawToken, obj["type"] as? String == "assistant" || obj["type"] as? String == "stream_event" {
                sawToken = true
                onPhase?(.firstToken)
            }
            guard obj["type"] as? String == "result" else { continue }
            onPhase?(.turnFinished(turns: obj["num_turns"] as? Int))

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
        let err = String(data: proc.stderr.value, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        throw ClaudeCLIError.noOutput(err.isEmpty ? "" : "(\(err.prefix(300)))")
    }
}
