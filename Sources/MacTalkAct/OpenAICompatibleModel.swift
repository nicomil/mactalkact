import Foundation
import FoundationModels

/// A bigger model served on the Mac by Ollama, LM Studio, mlx_lm.server or Rapid-MLX,
/// through their OpenAI-compatible API (FR-31, AD-17). It is a FoundationModels
/// `LanguageModel` (macOS 27): the same `LanguageModelSession`, tools and guided
/// generation work with Apple's model and with this one.
enum OpenAICompatibleModel {
    struct ServerError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    /// Only this Mac, unless the user confirmed otherwise (NFR-10).
    static func isLocal(baseURL: String) -> Bool {
        guard let host = URL(string: baseURL)?.host?.lowercased() else { return false }
        return host == "localhost" || host == "127.0.0.1" || host == "::1" || host == "[::1]"
    }

    static func isAllowed(baseURL: String, allowRemote: Bool) -> Bool {
        isLocal(baseURL: baseURL) || allowRemote
    }

    /// The server answers `GET /models` within 1.5 s.
    static func ping(baseURL: String) async -> Bool {
        (try? await models(baseURL: baseURL, timeout: 1.5)) != nil
    }

    static func endpoint(_ baseURL: String, _ path: String) -> URL? {
        URL(string: baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/ ")) + path)
    }

    /// Model names offered by the server.
    static func models(baseURL: String, timeout: TimeInterval = 3) async throws -> [String] {
        guard let url = endpoint(baseURL, "/models") else { throw ServerError(message: "indirizzo non valido") }
        var req = URLRequest(url: url, timeoutInterval: timeout)
        req.httpMethod = "GET"
        let (data, response) = try await URLSession.shared.data(for: req)
        guard (response as? HTTPURLResponse)?.statusCode == 200,
              let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let list = obj["data"] as? [[String: Any]] else {
            throw ServerError(message: "risposta del server non valida")
        }
        return list.compactMap { $0["id"] as? String }.sorted()
    }

    /// The model for a FoundationModels session.
    static func make(baseURL: String, model: String, keepAliveMinutes: Double) -> (any LanguageModel)? {
        guard !model.isEmpty, endpoint(baseURL, "/chat/completions") != nil else { return nil }
        return ServerLanguageModel(executorConfiguration: .init(baseURL: baseURL, model: model,
                                                                keepAliveMinutes: Int(keepAliveMinutes.rounded())))
    }

    /// Ollama listens on 11434 and accepts `keep_alive` (how long the model stays in memory).
    static func isOllama(_ baseURL: String) -> Bool {
        URL(string: baseURL)?.port == 11434
    }
}

/// The model description for FoundationModels.
struct ServerLanguageModel: LanguageModel {
    typealias Executor = ServerModelExecutor
    let executorConfiguration: ServerModelExecutor.Configuration

    var capabilities: LanguageModelCapabilities {
        LanguageModelCapabilities([.toolCalling, .guidedGeneration])
    }
}

/// Turns a FoundationModels request into one `/v1/chat/completions` call.
struct ServerModelExecutor: LanguageModelExecutor {
    struct Configuration: Hashable, Sendable {
        let baseURL: String
        let model: String
        let keepAliveMinutes: Int
    }
    typealias Model = ServerLanguageModel

    let configuration: Configuration

    init(configuration: Configuration) throws {
        self.configuration = configuration
    }

    /// Loads the model in the server's memory ahead of the first request (Ollama).
    func prewarm(model: ServerLanguageModel, transcript: Transcript) {
        let c = configuration
        guard OpenAICompatibleModel.isOllama(c.baseURL),
              let url = OpenAICompatibleModel.endpoint(c.baseURL.replacingOccurrences(of: "/v1", with: ""), "/api/generate") else { return }
        var req = URLRequest(url: url, timeoutInterval: 60)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: ["model": c.model, "keep_alive": "\(c.keepAliveMinutes)m"])
        Task.detached { _ = try? await URLSession.shared.data(for: req) }
    }

    func respond(to request: LanguageModelExecutorGenerationRequest, model: ServerLanguageModel,
                 streamingInto channel: LanguageModelExecutorGenerationChannel) async throws {
        let body = try Self.body(for: request, configuration: configuration)
        guard let url = OpenAICompatibleModel.endpoint(configuration.baseURL, "/chat/completions") else {
            throw OpenAICompatibleModel.ServerError(message: "indirizzo non valido")
        }
        var req = URLRequest(url: url, timeoutInterval: 180)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: req)
        } catch {
            throw OpenAICompatibleModel.ServerError(message: "server non raggiungibile: \(error.localizedDescription)")
        }
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            let text = String(data: data, encoding: .utf8) ?? ""
            throw OpenAICompatibleModel.ServerError(message: "errore del server \((response as? HTTPURLResponse)?.statusCode ?? 0): \(text.prefix(200))")
        }
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choice = (obj["choices"] as? [[String: Any]])?.first,
              let message = choice["message"] as? [String: Any] else {
            throw OpenAICompatibleModel.ServerError(message: "risposta del server non valida")
        }
        let usage = obj["usage"] as? [String: Any]
        let inputTokens = usage?["prompt_tokens"] as? Int ?? 0
        let outputTokens = usage?["completion_tokens"] as? Int ?? 0
        await channel.send(.response(action: .updateUsage(input: .init(totalTokenCount: inputTokens, cachedTokenCount: 0),
                                                          output: .init(totalTokenCount: outputTokens, reasoningTokenCount: 0))))

        if let calls = message["tool_calls"] as? [[String: Any]], !calls.isEmpty {
            for (i, call) in calls.enumerated() {
                guard let fn = call["function"] as? [String: Any], let name = fn["name"] as? String else { continue }
                let id = call["id"] as? String ?? "call_\(i)"
                var arguments = fn["arguments"] as? String ?? "{}"
                if let dict = fn["arguments"] as? [String: Any],
                   let d = try? JSONSerialization.data(withJSONObject: dict), let s = String(data: d, encoding: .utf8) {
                    arguments = s // some servers send an object instead of a string
                }
                await channel.send(.toolCalls(action: .toolCall(id: id, name: name,
                                                                action: .appendArguments(arguments, tokenCount: max(1, arguments.count / 4)))))
            }
            return
        }
        var content = message["content"] as? String ?? ""
        if request.schema != nil { content = Self.jsonPart(of: content) }
        await channel.send(.response(action: .appendText(content, tokenCount: max(1, outputTokens))))
    }

    /// Reasoning models sometimes wrap the JSON in text or <think>: keep the JSON object only.
    static func jsonPart(of text: String) -> String {
        var t = text
        if let end = t.range(of: "</think>") { t = String(t[end.upperBound...]) }
        guard let first = t.firstIndex(of: "{"), let last = t.lastIndex(of: "}"), first < last else { return t }
        return String(t[first...last])
    }

    // MARK: Request body

    static func body(for request: LanguageModelExecutorGenerationRequest, configuration: Configuration) throws -> [String: Any] {
        var messages: [[String: Any]] = []
        for entry in request.transcript {
            switch entry {
            case .instructions(let i):
                messages.append(["role": "system", "content": text(i.segments)])
            case .prompt(let p):
                messages.append(["role": "user", "content": text(p.segments)])
            case .response(let r):
                messages.append(["role": "assistant", "content": text(r.segments)])
            case .toolCalls(let calls):
                let list: [[String: Any]] = calls.map { c in
                    ["id": c.id, "type": "function", "function": ["name": c.toolName, "arguments": c.arguments.jsonString]]
                }
                messages.append(["role": "assistant", "content": "", "tool_calls": list])
            case .toolOutput(let o):
                messages.append(["role": "tool", "tool_call_id": o.id, "name": o.toolName, "content": text(o.segments)])
            default:
                break // reasoning: not sent back
            }
        }
        var body: [String: Any] = [
            "model": configuration.model,
            "messages": messages,
            "stream": false,
        ]
        if let t = request.generationOptions.temperature { body["temperature"] = t }
        if let m = request.generationOptions.maximumResponseTokens { body["max_tokens"] = m }
        if !request.enabledToolDefinitions.isEmpty {
            body["tools"] = try request.enabledToolDefinitions.map { d -> [String: Any] in
                ["type": "function", "function": ["name": d.name, "description": d.description,
                                                  "parameters": try jsonSchema(d.parameters)]]
            }
        }
        if let schema = request.schema {
            body["response_format"] = ["type": "json_schema",
                                       "json_schema": ["name": "risposta", "strict": true, "schema": try jsonSchema(schema)]]
        }
        if OpenAICompatibleModel.isOllama(configuration.baseURL) {
            body["keep_alive"] = "\(configuration.keepAliveMinutes)m"
        }
        return body
    }

    static func text(_ segments: [Transcript.Segment]) -> String {
        segments.compactMap { s -> String? in
            switch s {
            case .text(let t): return t.content
            case .structure(let st): return st.content.jsonString
            default: return nil
            }
        }.joined(separator: "\n")
    }

    /// GenerationSchema is Codable as a JSON Schema; drop keys that strict servers reject.
    static func jsonSchema(_ schema: GenerationSchema) throws -> [String: Any] {
        let data = try JSONEncoder().encode(schema)
        guard var obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { return ["type": "object"] }
        obj.removeValue(forKey: "x-order")
        obj.removeValue(forKey: "title")
        return obj
    }
}
