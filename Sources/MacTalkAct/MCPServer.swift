import Foundation
import Network

/// A minimal MCP server (Streamable HTTP transport, JSON responses only) listening on
/// 127.0.0.1 with a random bearer token. The `claude` process started by the app
/// connects to it and gets the agent tools; nothing else on the network can reach it.
final class MCPServer: @unchecked Sendable {
    typealias ToolHandler = @Sendable (String, [String: Any]) async -> AgentTools.Result

    let token = UUID().uuidString + UUID().uuidString
    private(set) var port: UInt16 = 0
    /// The last `MCP-Protocol-Version` seen, logged once per change.
    fileprivate var loggedVersion = ""
    private var listener: NWListener?
    private let queue = DispatchQueue(label: "local.mactalkact.mcp")
    private let tools: [[String: Any]]
    private let handler: ToolHandler
    static let serverName = "mactalk"

    init(tools: [[String: Any]], handler: @escaping ToolHandler) {
        self.tools = tools
        self.handler = handler
    }

    var url: String { "http://127.0.0.1:\(port)/mcp" }

    /// The variable that carries the token in the child's environment (AD-16, FR-50).
    static let tokenVariable = "MACTALK_MCP_TOKEN"

    /// The `--mcp-config` for `claude`: a file readable only by the user, with a REFERENCE to the
    /// token (`${MACTALK_MCP_TOKEN}`, expanded by the CLI from its environment). The token never
    /// appears in the arguments of a process (`ps`) nor on disk.
    static func configJSON(url: String) -> String {
        let config: [String: Any] = ["mcpServers": [serverName: [
            "type": "http", "url": url, "headers": ["Authorization": "Bearer ${\(tokenVariable)}"],
        ]]]
        let data = (try? JSONSerialization.data(withJSONObject: config, options: [.sortedKeys, .withoutEscapingSlashes])) ?? Data()
        return String(data: data, encoding: .utf8) ?? "{}"
    }

    /// Path of the config file, written when the server starts.
    private(set) var configPath = ""

    private func writeConfig() throws {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MacTalkAct", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let file = base.appendingPathComponent("mcp-config-\(getpid()).json")
        FileManager.default.createFile(atPath: file.path, contents: Data(Self.configJSON(url: url).utf8),
                                       attributes: [.posixPermissions: 0o600])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        configPath = file.path
    }

    /// Removes the config file (the app is quitting).
    func removeConfig() {
        if !configPath.isEmpty { try? FileManager.default.removeItem(atPath: configPath) }
    }

    /// The `Origin` and `Host` a request may carry (FR-50): no web page, and only this server's address.
    static func allowed(origin: String?, host: String?, port: UInt16) -> Bool {
        let hosts = ["127.0.0.1:\(port)", "localhost:\(port)"]
        guard let host, hosts.contains(host.lowercased()) else { return false }
        guard let origin, !origin.isEmpty else { return true } // the CLIs send no Origin
        return hosts.map { "http://\($0)" }.contains(origin.lowercased())
    }

    /// Starts listening on a free local port; returns once the port is known.
    func start() async throws {
        guard listener == nil else { return }
        let params = NWParameters.tcp
        params.requiredLocalEndpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: .any)
        params.allowLocalEndpointReuse = true
        let l = try NWListener(using: params)
        listener = l
        l.newConnectionHandler = { [weak self] conn in
            guard let self else { return }
            HTTPConnection(connection: conn, server: self).start(on: self.queue)
        }
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            let resumed = Box(false)
            l.stateUpdateHandler = { [weak self] state in
                switch state {
                case .ready:
                    self?.port = l.port?.rawValue ?? 0
                    if !resumed.value { resumed.value = true; c.resume() }
                case .failed(let error):
                    if !resumed.value { resumed.value = true; c.resume(throwing: error) }
                default:
                    break
                }
            }
            l.start(queue: queue)
        }
        Log.info("Server strumenti agente su \(url)")
        try writeConfig()
    }

    func stop() {
        listener?.cancel()
        listener = nil
    }

    // MARK: JSON-RPC

    /// Returns the response object, or nil for notifications.
    fileprivate func handle(_ message: [String: Any]) async -> [String: Any]? {
        let id = message["id"]
        let method = message["method"] as? String ?? ""
        let params = message["params"] as? [String: Any] ?? [:]
        guard let id, !(id is NSNull) else { return nil } // notification

        func reply(_ result: [String: Any]) -> [String: Any] { ["jsonrpc": "2.0", "id": id, "result": result] }
        func fail(_ code: Int, _ text: String) -> [String: Any] {
            ["jsonrpc": "2.0", "id": id, "error": ["code": code, "message": text]]
        }

        switch method {
        case "initialize":
            let supported = ["2025-11-25", "2025-06-18", "2025-03-26", "2024-11-05"]
            let requested = params["protocolVersion"] as? String ?? "2025-06-18"
            let client = (params["clientInfo"] as? [String: Any])?["name"] as? String ?? "?"
            Log.info("Server strumenti: \(client) chiede la revisione \(requested), negoziata \(supported.contains(requested) ? requested : "2025-06-18")")
            return reply([
                "protocolVersion": supported.contains(requested) ? requested : "2025-06-18",
                "capabilities": ["tools": ["listChanged": false]],
                "serverInfo": ["name": "MacTalkAct", "version": "0.2.0"],
                "instructions": "Tools that see and control the user's Mac on their behalf.",
            ])
        case "ping":
            return reply([:])
        case "tools/list":
            return reply(["tools": tools])
        case "tools/call":
            let name = params["name"] as? String ?? ""
            let args = params["arguments"] as? [String: Any] ?? [:]
            let result = await handler(name, args)
            return reply(["content": result.content, "isError": result.isError])
        default:
            return fail(-32601, "Method not found: \(method)")
        }
    }
}

/// One keep-alive HTTP/1.1 connection: parses requests, answers POST /mcp.
private final class HTTPConnection: @unchecked Sendable {
    private let connection: NWConnection
    private let server: MCPServer
    private var buffer = Data()
    private var self_: HTTPConnection?
    private var queue: DispatchQueue?
    /// One request at a time per connection (buffer is only touched on `queue`).
    private var handling = false

    init(connection: NWConnection, server: MCPServer) {
        self.connection = connection
        self.server = server
    }

    func start(on queue: DispatchQueue) {
        self_ = self // keep alive until the connection closes
        self.queue = queue
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed, .cancelled: self?.self_ = nil
            default: break
            }
        }
        connection.start(queue: queue)
        receive()
    }

    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data { self.buffer.append(data) }
            self.processBuffer()
            if isComplete || error != nil {
                self.connection.cancel()
            } else {
                self.receive()
            }
        }
    }

    private func processBuffer() {
        guard !handling else { return }
        let separator = Data("\r\n\r\n".utf8)
        guard let headerEnd = buffer.range(of: separator) else { return }
        let headerText = String(data: buffer[buffer.startIndex..<headerEnd.lowerBound], encoding: .utf8) ?? ""
        var lines = headerText.components(separatedBy: "\r\n")
        let requestLine = lines.removeFirst().split(separator: " ")
        var headers: [String: String] = [:]
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { continue }
            headers[line[..<colon].lowercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        let length = Int(headers["content-length"] ?? "0") ?? 0
        let bodyStart = headerEnd.upperBound
        guard buffer.count - (bodyStart - buffer.startIndex) >= length else { return } // wait for the body
        let body = buffer[bodyStart..<(bodyStart + length)]
        buffer = Data(buffer[(bodyStart + length)...])

        let method = requestLine.first.map(String.init) ?? ""
        let path = requestLine.count > 1 ? String(requestLine[1]) : ""

        // FR-50: a web page (DNS rebinding, a local page) never reaches the tools.
        if !MCPServer.allowed(origin: headers["origin"], host: headers["host"], port: server.port) {
            Log.info("Server strumenti: rifiutata una richiesta da Origin \(headers["origin"] ?? "—"), Host \(headers["host"] ?? "—")")
            send(status: "403 Forbidden", body: nil)
            return
        }
        guard headers["authorization"] == "Bearer \(server.token)" else {
            send(status: "401 Unauthorized", body: nil)
            return
        }
        if let version = headers["mcp-protocol-version"], version != server.loggedVersion {
            server.loggedVersion = version
            Log.info("Server strumenti: MCP-Protocol-Version \(version)")
        }
        guard path.hasPrefix("/mcp") else {
            send(status: "404 Not Found", body: nil)
            return
        }
        guard method == "POST" else {
            send(status: "405 Method Not Allowed", body: nil, extra: ["Allow": "POST"])
            return
        }

        let json = try? JSONSerialization.jsonObject(with: Data(body))
        handling = true
        Task {
            var responses: [[String: Any]] = []
            if let batch = json as? [[String: Any]] {
                for m in batch { if let r = await self.server.handle(m) { responses.append(r) } }
            } else if let single = json as? [String: Any] {
                if let r = await self.server.handle(single) { responses.append(r) }
            }
            if responses.isEmpty {
                self.send(status: "202 Accepted", body: nil)
            } else {
                let payload: Any = (json is [Any]) ? responses : responses[0]
                let data = (try? JSONSerialization.data(withJSONObject: payload)) ?? Data()
                self.send(status: "200 OK", body: data, extra: ["Content-Type": "application/json"])
            }
            // Next request (pipelined or already buffered), back on the connection queue.
            self.queue?.async {
                self.handling = false
                self.processBuffer()
            }
        }
    }

    private func send(status: String, body: Data?, extra: [String: String] = [:]) {
        var head = "HTTP/1.1 \(status)\r\nContent-Length: \(body?.count ?? 0)\r\nConnection: keep-alive\r\n"
        for (k, v) in extra { head += "\(k): \(v)\r\n" }
        head += "\r\n"
        var data = Data(head.utf8)
        if let body { data.append(body) }
        connection.send(content: data, completion: .contentProcessed { _ in })
    }
}
