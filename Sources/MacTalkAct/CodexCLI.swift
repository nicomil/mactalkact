import Foundation

/// Talks to Codex through `codex exec` with the user's ChatGPT login (FR-26).
///
/// One process per request: the spike of Story 4.1 measured that a process started in
/// advance saves only a few tenths of a second, because `codex exec` starts its session
/// only after reading the whole request. Codex sees only the app's MCP server (AD-16):
/// its shell, computer use, browser, plugins, web search and the user's config are off.
final class CodexCLI: @unchecked Sendable {

    struct Config: Equatable {
        let model: String
        let effort: String
        let instructionsFile: String
        let mcpURL: String
        let mcpToken: String
    }

    enum Outcome: Equatable {
        case answer(String)
        case failed(String)
    }

    private let lock = NSLock()
    private var current: Process?

    var executablePath: () -> String? = { CodexCLI.locate(custom: nil) }

    // MARK: Locating the binary

    /// Finder-launched apps get a minimal PATH, so look in the usual install places.
    /// Shims of other apps (e.g. terminals that wrap `codex`) are skipped: they may add
    /// their own tools to Codex.
    static func locate(custom: String?) -> String? {
        let fm = FileManager.default
        if let custom, !custom.isEmpty {
            let expanded = (custom as NSString).expandingTildeInPath
            return fm.isExecutableFile(atPath: expanded) ? expanded : nil
        }
        let home = NSHomeDirectory()
        let candidates = [
            "\(home)/.local/bin/codex",
            "/Applications/ChatGPT.app/Contents/Resources/codex-cli/bin/codex",
            "/Applications/Codex.app/Contents/Resources/codex-cli/bin/codex",
            "/opt/homebrew/bin/codex",
            "/usr/local/bin/codex",
            "\(home)/.npm-global/bin/codex",
            "\(home)/.bun/bin/codex",
        ]
        if let hit = candidates.first(where: { fm.isExecutableFile(atPath: $0) && !isShim($0) }) { return hit }

        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/zsh")
        p.arguments = ["-lc", "which -a codex"]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = Pipe()
        guard (try? p.run()) != nil else { return nil }
        p.waitUntilExit()
        let text = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        return text.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
            .first { fm.isExecutableFile(atPath: $0) && !isShim($0) }
    }

    static func isShim(_ path: String) -> Bool {
        let l = path.lowercased()
        return l.contains("shim") || l.contains("/.cmuxterm/")
    }

    // MARK: Version (FR-45, AD-14)

    /// Minimum verified version (CVE-2026-19591); later ones, ChatGPT.app alphas included, count as a range.
    static let minimumVersion = "0.131.0"

    // MARK: Login

    /// `codex login status`: exit 0 and «Logged in…» when the user is logged in.
    static func isLoggedIn(executable: String) -> Bool {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: executable)
        p.arguments = ["login", "status"]
        p.environment = environment(token: nil)
        let out = Pipe()
        p.standardOutput = out
        p.standardError = out
        guard (try? p.run()) != nil else { return false }
        p.waitUntilExit()
        let text = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        return p.terminationStatus == 0 && text.lowercased().contains("logged in") && !text.lowercased().contains("not logged in")
    }

    // MARK: Arguments

    /// The options verified in the spike of Story 4.1 (see the research document).
    static func arguments(_ c: Config) -> [String] {
        var args = [
            "exec", "-", "--json", "--ephemeral", "--skip-git-repo-check",
            "--ignore-user-config", "--ignore-rules", "--strict-config",
            "--sandbox", "read-only",
        ]
        if !c.model.isEmpty { args += ["-m", c.model] }
        args += ["-c", "model_reasoning_effort=\"\(c.effort)\""]
        for feature in ["shell_tool", "unified_exec", "computer_use", "browser_use", "apps", "plugins",
                        "image_generation", "skill_search", "tool_suggest", "view_image", "sleep_tool",
                        "goals", "multi_agent"] {
            args += ["--disable", feature]
        }
        args += [
            "-c", "web_search=\"disabled\"",
            "-c", "model_instructions_file=\(tomlString(c.instructionsFile))",
            "-c", "project_doc_max_bytes=0",
            "-c", "include_permissions_instructions=false",
            "-c", "include_apps_instructions=false",
            "-c", "include_environment_context=false",
            "-c", "mcp_servers.\(MCPServer.serverName).url=\(tomlString(c.mcpURL))",
            "-c", "mcp_servers.\(MCPServer.serverName).bearer_token_env_var=\"\(tokenVariable)\"",
            "-c", "mcp_servers.\(MCPServer.serverName).required=true",
            "-c", "mcp_servers.\(MCPServer.serverName).default_tools_approval_mode=\"approve\"",
        ]
        return args
    }

    /// The MCP token travels only in the child's environment, never in its arguments (AD-16).
    static let tokenVariable = MCPServer.tokenVariable

    private static func tomlString(_ s: String) -> String {
        "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    static func environment(token: String?) -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        let home = NSHomeDirectory()
        env["PATH"] = "\(home)/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        // Use the ChatGPT login, not an API key that may be in the environment.
        for key in ["OPENAI_API_KEY", "CODEX_API_KEY", "CODEX_THREAD_ID"] { env.removeValue(forKey: key) }
        if let token { env[tokenVariable] = token } else { env.removeValue(forKey: tokenVariable) }
        return env
    }

    // MARK: Running

    func run(_ config: Config, message: String, timeout: TimeInterval, onPhase: PhaseSink? = nil) async throws -> Outcome {
        guard let path = executablePath() else { throw AgentEngineError.notFound("Comando «codex» non trovato. Installa ChatGPT o Codex, o indica il percorso nelle impostazioni.") }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.currentDirectoryURL = Self.workingDirectory()
        p.arguments = Self.arguments(config)
        p.environment = Self.environment(token: config.mcpToken)
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
        onPhase?(.sessionStarted)
        lock.withLock { current = p }
        defer {
            lock.withLock { current = nil }
            if p.isRunning { p.terminate() }
        }
        try inPipe.fileHandleForWriting.write(contentsOf: Data(message.utf8))
        try inPipe.fileHandleForWriting.close()

        let stdout = outPipe.fileHandleForReading
        return try await withThrowingTaskGroup(of: Outcome.self) { group in
            group.addTask {
                var parser = CodexEventParser()
                for try await line in stdout.bytes.lines {
                    if let phase = parser.phase(line) { onPhase?(phase) }
                    if let outcome = parser.feed(line) {
                        onPhase?(.turnFinished(turns: parser.turns))
                        if !parser.usage.isEmpty { Log.info("Codex: token \(parser.usage)") }
                        return outcome
                    }
                }
                if let outcome = parser.finish() { return outcome }
                let err = String(data: errBuffer.value, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                return .failed(err.isEmpty ? "Codex si è chiuso senza risposta" : String(err.suffix(300)))
            }
            group.addTask {
                try await Task.sleep(for: .seconds(timeout))
                throw AgentEngineError.timeout
            }
            defer { group.cancelAll() }
            guard let result = try await group.next() else { throw AgentEngineError.timeout }
            return result
        }
    }

    /// Stops an in-flight request ("stop!").
    func cancelCurrent() {
        lock.withLock { current }?.terminate()
    }

    static func workingDirectory() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = base.appendingPathComponent("MacTalkAct", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// The agent's instructions as a file, for `model_instructions_file` (rewritten only when they change).
    static func instructionsFile(_ text: String) -> String {
        let url = workingDirectory().appendingPathComponent("codex-instructions.md")
        if (try? String(contentsOf: url, encoding: .utf8)) != text {
            try? text.write(to: url, atomically: true, encoding: .utf8)
        }
        return url.path
    }
}

/// Reads `codex exec --json` events (JSONL). Pure, tested with `Tests/fixtures/codex`.
struct CodexEventParser {
    private(set) var lastMessage = ""
    private(set) var toolCalls = 0
    /// Token use of the turn («12000 in (8000 cached), 300 out»), for the log.
    private(set) var usage = ""
    /// Turns started in this run, for the Bench.
    private(set) var turns = 0
    private var sawItem = false

    /// The phase event of one line, read from its `type` (the end of the turn comes with `feed`).
    mutating func phase(_ line: String) -> EnginePhase? {
        guard let obj = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any],
              let type = obj["type"] as? String else { return nil }
        switch type {
        case "turn.started":
            turns += 1
            return turns == 1 ? .serverConnected : nil
        case "item.started", "item.completed":
            guard !sawItem else { return nil }
            sawItem = true
            return .firstToken
        default:
            return nil
        }
    }

    /// Returns an outcome when the turn is over, or when an error makes waiting useless
    /// (usage limit, missing login: Codex would retry for ~20 s).
    mutating func feed(_ line: String) -> CodexCLI.Outcome? {
        guard let obj = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any],
              let type = obj["type"] as? String else { return nil }
        switch type {
        case "item.started", "item.completed":
            guard let item = obj["item"] as? [String: Any] else { return nil }
            let itemType = item["type"] as? String
            if itemType == "agent_message", type == "item.completed", let text = item["text"] as? String {
                lastMessage = text.trimmingCharacters(in: .whitespacesAndNewlines)
            } else if itemType == "mcp_tool_call", type == "item.started" {
                toolCalls += 1
            }
            return nil
        case "turn.completed":
            if let u = obj["usage"] as? [String: Any] {
                usage = "\(u["input_tokens"] as? Int ?? 0) in (\(u["cached_input_tokens"] as? Int ?? 0) cached), \(u["output_tokens"] as? Int ?? 0) out"
            }
            return .answer(lastMessage)
        case "turn.failed":
            let message = ((obj["error"] as? [String: Any])?["message"] as? String) ?? "errore"
            return .failed(message)
        case "error":
            let message = obj["message"] as? String ?? ""
            if LimitMessage.isLimit(message) || CodexEventParser.isLogin(message) { return .failed(message) }
            // Without network Codex retries 5 times (~20 s): give up at the second try so
            // the fallback engine can answer quickly; a single blip still recovers.
            if message.hasPrefix("Reconnecting"), message.contains(" 2/"), CodexEventParser.isNetwork(message) {
                return .failed(message)
            }
            return nil
        default:
            return nil
        }
    }

    func finish() -> CodexCLI.Outcome? {
        lastMessage.isEmpty ? nil : .answer(lastMessage)
    }

    static func isLogin(_ m: String) -> Bool {
        let l = m.lowercased()
        return l.contains("401 unauthorized") || l.contains("not logged in") || l.contains("please log in")
            || l.contains("refresh token")
    }

    static func isNetwork(_ m: String) -> Bool {
        let l = m.lowercased()
        return l.contains("error sending request") || l.contains("stream disconnected") || l.contains("failed to connect")
            || l.contains("dns") || l.contains("network") || l.contains("connection refused") || l.contains("timed out")
    }
}
