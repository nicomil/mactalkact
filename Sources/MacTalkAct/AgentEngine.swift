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
    /// One-step commands with a known target, Claude only (FR-43): Haiku, one tool call, then
    /// the executor judges the outcome and escalates to `.fast` if needed.
    case instant
    case fast, deep
}

/// What an engine needs to reach the app's tools.
struct AgentToolAccess {
    /// MCP server for engines that run in another process (Claude, Codex).
    let mcpURL: String
    let mcpToken: String
    /// The `--mcp-config` file (0600) with a reference to the token, never the token itself.
    let mcpConfigPath: String
    /// The tools themselves, for engines that run inside the app (local model).
    let tools: AgentTools
}

/// One request, already composed by AgentRunner (screen, memory, <recent>, request).
struct AgentRequest {
    var message: String
    /// The same request in a compact Italian form, for the local engine's small context.
    let localMessage: String
    /// Only the user's words.
    let userRequest: String
    var level: AgentLevel
    /// The one deadline of the turn (AD-24): engines have no timeout of their own.
    var clock = TurnClock(seconds: 240) // AgentRunner sets it from `agentTimeout`
    /// The conversation memory when the request was composed, for a Long session (FR-42).
    var memory = MemorySnapshot(generation: 0, lastSeq: 0)
    /// The message with only the memory entries after `seq` (a Long session saw the rest).
    var messageSince: (Int) -> String = { _ in "" }
}

/// Where the conversation memory stood: `generation` changes when the memory is emptied.
struct MemorySnapshot: Equatable {
    let generation: Int
    let lastSeq: Int
}

/// One clock for the turn (AD-24). Started with the request; paused while a question waits for
/// the user's answer (Story 9.2), so a confirmation never makes the turn expire. Shared by reference:
/// the CLI reading the engine's output and the tools asking the user see the same clock.
final class TurnClock: @unchecked Sendable {
    private let lock = NSLock()
    private let limit: Duration
    private let started = ContinuousClock.now
    private var paused: Duration = .zero
    private var pausedSince: ContinuousClock.Instant?
    /// Questions waiting at the same time: the clock runs again only when the last one ends.
    private var depth = 0

    init(seconds: Double) {
        let s = seconds.isFinite ? min(max(1, seconds), 86_400) : 240
        limit = .milliseconds(Int(s * 1000))
    }

    func pause() {
        lock.withLock {
            depth += 1
            if pausedSince == nil { pausedSince = .now }
        }
    }

    func resume() {
        lock.withLock {
            depth = max(0, depth - 1)
            guard depth == 0, let since = pausedSince else { return }
            paused += ContinuousClock.now - since
            pausedSince = nil
        }
    }

    var isPaused: Bool { lock.withLock { pausedSince != nil } }

    /// Seconds left; it does not decrease while paused.
    var remaining: TimeInterval {
        lock.withLock {
            let now = pausedSince ?? .now
            let left = limit - (now - started - paused)
            return max(0, Double(left.components.seconds) + Double(left.components.attoseconds) / 1e18)
        }
    }

    /// Returns when the turn's time is over (never while a question is waiting).
    func untilExpired() async {
        while true {
            let left = remaining
            if left <= 0, !isPaused { return }
            try? await Task.sleep(for: .milliseconds(Int(max(0.05, min(left, 0.5)) * 1000)))
            if Task.isCancelled { return }
        }
    }
}

/// What the app knows about a CLI's version (AD-14). Separate from availability: the selector
/// never reads it; `ClaudeCLI` uses it to decide on the Long session, the status page shows it.
enum CLIStatus: Equatable, CustomStringConvertible {
    case verified(String)
    case unverified(String?)
    case belowMinimum(String)

    /// From `--version` output («2.1.311 (Claude Code)», «codex-cli 0.131.0»).
    static func from(versionOutput: String?, minimum: String) -> CLIStatus {
        guard let out = versionOutput,
              let r = out.range(of: #"\d+\.\d+\.\d+"#, options: .regularExpression) else { return .unverified(nil) }
        let v = String(out[r])
        let c = compare(v, minimum)
        // A pre-release of the minimum itself («2.1.299-beta.1») comes before it.
        let prerelease = out[r.upperBound...].hasPrefix("-")
        return c > 0 || (c == 0 && !prerelease) ? .verified(v) : .belowMinimum(v)
    }

    /// -1, 0, 1 like a comparator, on dotted numbers.
    static func compare(_ a: String, _ b: String) -> Int {
        let x = a.split(separator: ".").map { Int($0) ?? 0 }, y = b.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(x.count, y.count) {
            let l = i < x.count ? x[i] : 0, r = i < y.count ? y[i] : 0
            if l != r { return l < r ? -1 : 1 }
        }
        return 0
    }

    var isVerified: Bool { if case .verified = self { return true } else { return false } }

    /// The same version, no longer verified: `claude` started without the subscription login.
    var unverifiedForLogin: CLIStatus {
        switch self {
        case .verified(let v), .belowMinimum(let v): return .unverified(v)
        case .unverified: return self
        }
    }

    var description: String {
        switch self {
        case .verified(let v): return "versione \(v) verificata"
        case .unverified(let v): return v.map { "versione \($0) non verificata" } ?? "versione non verificata"
        case .belowMinimum(let v): return "versione \(v) non verificata (sotto la minima)"
        }
    }
}

/// When a Long session must start again (FR-42, AD-6). Pure, tested by `--selftest`.
enum SessionPolicy {
    static let maxIdle: TimeInterval = 10 * 60

    static func restartReason(requests: Int, maxRequests: Int, idle: TimeInterval,
                              configChanged: Bool, modelOrEffortChanged: Bool = true, memoryChanged: Bool) -> String? {
        if configChanged { return modelOrEffortChanged ? "modello o effort cambiati" : "configurazione cambiata" }
        if memoryChanged { return "memoria azzerata" }
        if requests >= maxRequests { return "\(maxRequests) richieste" }
        if idle >= maxIdle { return "inattiva da 10 minuti" }
        return nil
    }
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
    /// Events of the request in progress, for the phases of the Bench (AD-13, AD-18).
    var onPhase: PhaseSink? { get set }
    /// The model used for a level, for logs and menus.
    func model(for level: AgentLevel) -> String
    /// Re-checks the command and the login, without touching a pause in progress.
    func refreshAvailability()
    /// Gets ready for the next request (warm processes, loaded model). May do nothing.
    func prewarm()
    /// Runs one request to completion and returns the final sentence for the user.
    func run(_ request: AgentRequest) async throws -> String
    func cancel()
    /// Ends the turn in progress without losing the engine's state (scalata, AD-13). By default, `cancel()`.
    func interrupt()
    func shutdown()
}

extension AgentEngine {
    func interrupt() { cancel() }
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

// MARK: - Phases of a request (AD-13, AD-18)

/// What an engine sees while it works. Engines report events, never durations:
/// the clock belongs to `AgentRunner`.
enum EnginePhase: Sendable, Equatable {
    case sessionStarted
    case sessionReused
    case serverConnected
    case firstToken
    /// The turn is over; `turns` is the number of model turns when the engine knows it.
    case turnFinished(turns: Int?)
}

typealias PhaseSink = @Sendable (EnginePhase) -> Void

/// The phases of the Bench table, in order. Contiguous: every instant of a request belongs
/// to exactly one phase, so the phases add up to the total.
enum BenchPhase: String, CaseIterable, Sendable {
    case scan = "scansione"
    case session = "sessione"
    case mcp = "mcp"
    case firstToken = "primo_token"
    case actions = "azioni"
    /// The model thinking between two tools.
    case reasoning = "ragionamento"
    /// The on-device safety classifier (Story 9.5).
    case classifier = "classificatore"
    case finalTurn = "turno_finale"
    case close = "chiusura"
}

/// One monotonic clock per request. `mark` closes the current phase and opens the next one;
/// thread-safe because engines report from their reading tasks and tools from MCP requests.
final class PhaseTimer: @unchecked Sendable {
    private let lock = NSLock()
    private let clock = ContinuousClock()
    private let started: ContinuousClock.Instant
    private var current: BenchPhase
    private var since: ContinuousClock.Instant
    private var segments: [(BenchPhase, Duration)] = []
    private var finished: (phases: [BenchPhase: Double], total: Double)?
    /// Tools running right now: with parallel calls the phase is «azioni» until the last one ends.
    private var inFlight = 0
    private var _turns: Int?
    var turns: Int? { lock.withLock { _turns } }
    /// Seconds from the start of the request to the first token of the last attempt (after a
    /// scalata, the attempt that answers): the «primo token sulla webmail» of NFR-12 (Story 11.1).
    private var _firstTokenAt: Double?
    var firstTokenAt: Double? { lock.withLock { _firstTokenAt } }

    init(start phase: BenchPhase = .scan) {
        started = clock.now
        since = started
        current = phase
    }

    /// Opens `phase` now. Also used to go back to `.session` when another engine takes over.
    func mark(_ phase: BenchPhase) {
        lock.withLock {
            // A new attempt (scalata, fallback): only its own first token counts.
            if phase == .session, finished == nil { _firstTokenAt = nil }
            move(to: phase)
        }
    }

    /// Time spent in `phase` inside the current one (the classifier during a tool call): it is
    /// counted there and taken away from the current phase.
    func carve(_ phase: BenchPhase, seconds: Double) {
        lock.withLock {
            guard finished == nil, seconds > 0 else { return }
            let d = Duration.milliseconds(Int64(seconds * 1000))
            // Parallel tool calls: never carve more than the current phase has had.
            let room = clock.now - since
            let cut = min(d, room)
            guard cut > .zero else { return }
            segments.append((phase, cut))
            since = since + cut
        }
    }

    /// Start (`true`) or end (`false`) of a tool call.
    func tool(_ start: Bool) {
        lock.withLock {
            guard current != .close else { return }
            if start {
                inFlight += 1
                move(to: .actions)
            } else {
                inFlight = max(0, inFlight - 1)
                if inFlight == 0, current == .actions { move(to: .reasoning) }
            }
        }
    }

    /// Maps an engine event onto the phase that starts with it. Events only move forward:
    /// one read late (the first token after the first tool already started) changes nothing.
    func event(_ e: EnginePhase) {
        lock.withLock {
            switch e {
            case .sessionStarted, .sessionReused:
                if current == .session { move(to: .mcp) }
            case .serverConnected:
                if current == .session || current == .mcp { move(to: .firstToken) }
            case .firstToken:
                if [.session, .mcp, .firstToken].contains(current) {
                    if finished == nil { _firstTokenAt = Self.seconds(clock.now - started) }
                    move(to: .reasoning)
                }
            case .turnFinished(let t):
                _turns = t
                inFlight = 0
                move(to: .close)
            }
        }
    }

    /// Closes the timer. The model's thinking after the last tool is the final turn.
    @discardableResult
    func finish() -> (phases: [BenchPhase: Double], total: Double) {
        lock.withLock {
            if let finished { return finished }
            let now = clock.now
            segments.append((current, now - since))
            if let i = segments.lastIndex(where: { $0.0 == .reasoning }),
               !segments[i...].contains(where: { $0.0 == .actions }) {
                segments[i].0 = .finalTurn
            }
            var out: [BenchPhase: Double] = [:]
            for (p, d) in segments { out[p, default: 0] += Self.seconds(d) }
            let result = (out, Self.seconds(now - started))
            finished = result
            return result
        }
    }

    /// Call with the lock held.
    private func move(to phase: BenchPhase) {
        guard finished == nil, phase != current else { return }
        let now = clock.now
        segments.append((current, now - since))
        current = phase
        since = now
    }

    private static func seconds(_ d: Duration) -> Double {
        Double(d.components.seconds) + Double(d.components.attoseconds) / 1e18
    }
}
