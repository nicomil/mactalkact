import Foundation
import FoundationModels

/// A bigger model served on the Mac by Ollama, LM Studio, mlx_lm.server or Rapid-MLX,
/// through their OpenAI-compatible API (FR-31, AD-17).
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

    /// Model names offered by the server.
    static func models(baseURL: String, timeout: TimeInterval = 3) async throws -> [String] {
        guard let url = URL(string: baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + "/models") else {
            throw ServerError(message: "indirizzo non valido")
        }
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

    /// The model for a FoundationModels session (Story 5.3).
    static func make(baseURL: String, model: String, keepAliveMinutes: Double) -> (any LanguageModel)? {
        nil
    }
}
