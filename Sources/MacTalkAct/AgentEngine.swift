import Foundation

/// Who does the thinking for the agent (AD-13). The tools, the prompt and the
/// confirmations are the same for every engine: only the model changes.
enum EngineID: String, CaseIterable, Identifiable, Codable {
    case claude, codex, local

    var id: String { rawValue }

    /// The name as the user sees it, in messages and menus.
    var displayName: String {
        switch self {
        case .claude: return "Claude"
        case .codex: return "Codex"
        case .local: return "modello locale"
        }
    }

    /// Capitalised, for menus and settings.
    var title: String {
        switch self {
        case .claude: return "Claude"
        case .codex: return "Codex"
        case .local: return "Locale (sul Mac)"
        }
    }

    /// Subject of a sentence: «Codex è tornato», «Il modello locale si è fermato».
    var subject: String {
        switch self {
        case .claude: return "Claude"
        case .codex: return "Codex"
        case .local: return "Il modello locale"
        }
    }

    var isCloud: Bool { self != .local }

    /// The fallback chain (FR-27): chosen → the other cloud engine → local.
    /// A local choice stays local: whoever picks it does not want data to leave the Mac (NFR-10).
    var chain: [EngineID] {
        switch self {
        case .claude: return [.claude, .codex, .local]
        case .codex: return [.codex, .claude, .local]
        case .local: return [.local]
        }
    }
}

/// Two levels for every engine (AD-6): fast for 1-3 step requests, deep for long tasks.
enum AgentLevel: String {
    case fast, deep
}

/// What an engine needs to reach the app's tools.
struct AgentToolAccess {
    /// MCP server for engines that run in another process (Claude, Codex).
    let mcpURL: String
    let mcpToken: String
    let mcpConfigJSON: String
    /// The tools themselves, for engines that run inside the app (local model).
    let tools: AgentTools
}

/// One request, already composed by AgentRunner (screen, memory, <recent>, request).
struct AgentRequest {
    let message: String
    /// The same request in a compact Italian form, for the local engine's small context.
    let localMessage: String
    let level: AgentLevel
}

/// Why an engine stopped. AgentRunner decides from this whether another engine can try (AD-15).
enum AgentEngineError: LocalizedError {
    /// Usage limit of the subscription: the engine pauses until `until`.
    case limit(message: String, until: Date)
    case notFound(String)
    case loginNeeded(String)
    case network(String)
    case timeout
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .limit(let m, _): return m
        case .notFound(let m), .loginNeeded(let m), .network(let m), .failed(let m): return m
        case .timeout: return "L'agente non ha risposto in tempo"
        }
    }

    /// The engine could not even start working: another engine may try the same request.
    var allowsFallback: Bool {
        switch self {
        case .limit, .notFound, .loginNeeded, .network: return true
        case .timeout, .failed: return false
        }
    }
}

/// An engine that runs agent requests (AD-13). Engines never touch the HUD, the
/// Coordinator or the Executor: they only call the app's tools.
@MainActor
protocol AgentEngine: AnyObject {
    var id: EngineID { get }
    /// Owned by the engine itself (AD-14): limit pauses, missing command, login.
    var availability: AgentAvailability { get }
    var onAvailabilityChange: ((AgentAvailability) -> Void)? { get set }
    /// The model used for a level, for logs and menus.
    func model(for level: AgentLevel) -> String
    /// Re-checks the command and the login, without touching a pause in progress.
    func refreshAvailability()
    /// Gets ready for the next request (warm processes, loaded model). May do nothing.
    func prewarm()
    /// Runs one request to completion and returns the final sentence for the user.
    func run(_ request: AgentRequest) async throws -> String
    func cancel()
    func shutdown()
}

// MARK: - Selection (AD-14)

struct EngineChoice: Equatable {
    let engine: EngineID
    /// Not the engine the user chose.
    let isFallback: Bool
    let reason: String
}

/// Picks the engine of a request. Pure: no effects, tested by `--selftest`.
enum EngineSelector {
    static func select(chosen: EngineID, engines: [EngineID: AgentAvailability], fallback: Bool,
                       excluding: Set<EngineID> = []) -> EngineChoice? {
        let order = fallback ? chosen.chain : [chosen]
        for id in order where !excluding.contains(id) {
            guard engines[id] == .available else { continue }
            if id == chosen { return EngineChoice(engine: id, isFallback: false, reason: "scelto") }
            return EngineChoice(engine: id, isFallback: true,
                                reason: "\(chosen.displayName) \(state(engines[chosen] ?? .missing))")
        }
        return nil
    }

    /// "in pausa fino alle 17:40", "non trovato"…
    static func state(_ a: AgentAvailability) -> String {
        switch a {
        case .available: return "disponibile"
        case .paused(let until):
            let f = DateFormatter()
            f.dateFormat = Calendar.current.isDate(until, inSameDayAs: Date()) ? "HH:mm" : "EEEE HH:mm"
            f.locale = Locale(identifier: "it_IT")
            return "in pausa fino alle \(f.string(from: until))"
        case .missing: return "non trovato"
        case .loginNeeded: return "senza accesso"
        case .unavailable(let why): return why
        }
    }

    /// «Codex in pausa fino alle 17:40 · uso Claude», «Claude e Codex non disponibili · passo al modello locale».
    static func fallbackMessage(chosen: EngineID, using: EngineID, engines: [EngineID: AgentAvailability]) -> String {
        if using == .local {
            let clouds = chosen.chain.filter(\.isCloud)
            if clouds.count == 2 {
                return "\(clouds[0].displayName) e \(clouds[1].displayName) non disponibili · passo al modello locale"
            }
        }
        return "\(chosen.displayName) \(state(engines[chosen] ?? .missing)) · uso \(using.displayName)"
    }

    /// Reduced mode: no engine can take the request.
    static func unavailableMessage(chosen: EngineID, engines: [EngineID: AgentAvailability]) -> String {
        "\(chosen.subject) \(state(engines[chosen] ?? .missing))"
    }
}

// MARK: - Pauses

/// Limit pauses shared by the cloud engines: until the reset time, then back to available.
@MainActor
final class EnginePause {
    private var task: Task<Void, Never>?

    /// Waits until `until` (plus a minute of margin) and then calls `resume`.
    func schedule(until: Date, resume: @escaping @MainActor () -> Void) {
        task?.cancel()
        task = Task { @MainActor in
            let wait = max(5, until.timeIntervalSinceNow + 60)
            try? await Task.sleep(for: .seconds(wait))
            guard !Task.isCancelled else { return }
            resume()
        }
    }

    func cancel() {
        task?.cancel()
        task = nil
    }
}

// MARK: - Limit messages

/// Reads the reset time out of the engines' usage-limit messages.
enum LimitMessage {
    /// Claude: "You've hit your session limit · resets 7pm", "usage limit reached", "5-hour limit reached".
    /// Codex: "You've hit your usage limit. … try again at 5:40 PM", "try again in 2 hours".
    static func isLimit(_ message: String) -> Bool {
        let m = message.lowercased()
        if m.contains("usage limit") || m.contains("rate limit reached") { return true }
        return m.contains("limit") && (m.contains("hit") || m.contains("reached") || m.contains("resets") || m.contains("exceeded"))
    }

    /// When the engine comes back; nil when the message does not say it.
    static func resetDate(from message: String, now: Date = Date(), calendar: Calendar = .current) -> Date? {
        claudeReset(message, now: now, calendar: calendar)
            ?? codexResetIn(message, now: now)
            ?? codexResetAt(message, now: now, calendar: calendar)
    }

    /// "resets 7pm", "resets 7:30pm (Europe/Rome)".
    private static func claudeReset(_ message: String, now: Date, calendar: Calendar) -> Date? {
        guard let r = message.range(of: "resets ", options: .caseInsensitive) else { return nil }
        let tail = String(message[r.upperBound...]).lowercased()
        var cal = calendar
        if let open = tail.firstIndex(of: "("), let close = tail.firstIndex(of: ")"), open < close,
           let tz = TimeZone(identifier: String(message[r.upperBound...])
                .split(separator: "(").last?.split(separator: ")").first.map(String.init) ?? "") {
            cal.timeZone = tz
        }
        return clockTime(in: tail, now: now, calendar: cal)
    }

    /// "try again in 2 hours 10 minutes", "try again in 45 minutes", "try again in 3 days".
    private static func codexResetIn(_ message: String, now: Date) -> Date? {
        guard let r = message.range(of: "try again in ", options: .caseInsensitive) else { return nil }
        let tail = String(message[r.upperBound...]).lowercased()
        let pattern = #"(\d+(?:\.\d+)?)\s*(days?|d\b|hours?|hrs?|h\b|minutes?|mins?|m\b|seconds?|secs?|s\b)"#
        guard let re = try? NSRegularExpression(pattern: pattern) else { return nil }
        var seconds = 0.0
        // Only the numbers right after "try again in" (stop at the first sentence end).
        let clause = tail.replacingOccurrences(of: ". ", with: ";").split(whereSeparator: { ";\n".contains($0) })
            .first.map(String.init) ?? tail
        for m in re.matches(in: clause, range: NSRange(clause.startIndex..., in: clause)) {
            guard let vR = Range(m.range(at: 1), in: clause), let uR = Range(m.range(at: 2), in: clause),
                  let v = Double(clause[vR]) else { continue }
            let unit = clause[uR]
            if unit.hasPrefix("d") { seconds += v * 86400 }
            else if unit.hasPrefix("h") { seconds += v * 3600 }
            else if unit.hasPrefix("m") { seconds += v * 60 }
            else { seconds += v }
        }
        return seconds > 0 ? now.addingTimeInterval(seconds) : nil
    }

    /// "try again at 5:40 PM", "try again at Nov 3rd, 2026 9:15 AM".
    private static func codexResetAt(_ message: String, now: Date, calendar: Calendar) -> Date? {
        guard let r = message.range(of: "try again at ", options: .caseInsensitive) else { return nil }
        let tail = String(message[r.upperBound...])
        let months = ["jan", "feb", "mar", "apr", "may", "jun", "jul", "aug", "sep", "oct", "nov", "dec"]
        let datePattern = #"^([A-Za-z]{3})[a-z]*\.?\s+(\d{1,2})(?:st|nd|rd|th)?,?\s*(\d{4})?,?\s+"#
        if let re = try? NSRegularExpression(pattern: datePattern),
           let m = re.firstMatch(in: tail, range: NSRange(tail.startIndex..., in: tail)),
           let monR = Range(m.range(at: 1), in: tail), let dayR = Range(m.range(at: 2), in: tail),
           let month = months.firstIndex(of: tail[monR].lowercased()), let day = Int(tail[dayR]),
           let rest = Range(m.range(at: 0), in: tail) {
            var year = calendar.component(.year, from: now)
            if let yR = Range(m.range(at: 3), in: tail), let y = Int(tail[yR]) { year = y }
            guard let (hour, minute) = hourMinute(in: String(tail[rest.upperBound...])) else { return nil }
            return calendar.date(from: DateComponents(year: year, month: month + 1, day: day, hour: hour, minute: minute))
        }
        return clockTime(in: tail.lowercased(), now: now, calendar: calendar)
    }

    /// The next occurrence of the first clock time in `text` ("7pm", "17:40", "5:40 pm").
    private static func clockTime(in text: String, now: Date, calendar: Calendar) -> Date? {
        guard let (hour, minute) = hourMinute(in: text) else { return nil }
        guard var date = calendar.date(bySettingHour: hour, minute: minute, second: 0, of: now) else { return nil }
        if date <= now { date = calendar.date(byAdding: .day, value: 1, to: date) ?? date }
        return date
    }

    private static func hourMinute(in text: String) -> (Int, Int)? {
        let t = text.lowercased()
        let pattern = #"(\d{1,2})(?::(\d{2}))?\s*(am|pm|a\.m\.|p\.m\.)?"#
        guard let re = try? NSRegularExpression(pattern: pattern),
              let m = re.firstMatch(in: t, range: NSRange(t.startIndex..., in: t)),
              let hR = Range(m.range(at: 1), in: t), var hour = Int(t[hR]) else { return nil }
        let minute = Range(m.range(at: 2), in: t).flatMap { Int(t[$0]) } ?? 0
        if let apR = Range(m.range(at: 3), in: t) {
            let ap = t[apR]
            if ap.hasPrefix("p"), hour < 12 { hour += 12 }
            if ap.hasPrefix("a"), hour == 12 { hour = 0 }
        }
        guard hour < 24, minute < 60 else { return nil }
        return (hour, minute)
    }
}
