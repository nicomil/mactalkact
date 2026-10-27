import Foundation
import os

/// Logging: unified log, stdout (useful when launched from Terminal) and a file.
///
/// Privacy rules for the file:
/// - every line goes through `Privacy.redact` (emails, phone numbers, IBANs, cards, secrets);
/// - what the user says is written only for sentences the app accepted (`said`), and only
///   their length in private mode; dictated text only as a length (`dictation`);
/// - what the agent saw and did (`detail`) only with the detailed log on;
/// - one file per day, kept for `retentionDays` days, readable only by the user (0600).
enum Log {
    private static let logger = Logger(subsystem: "local.mactalkact", category: "app")

    static let directory: URL = {
        let dir = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first!
            .appendingPathComponent("Logs", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    /// ~/Library/Logs/MacTalkAct.log (today), readable with Console.app or `tail -f`.
    /// Older days: MacTalkAct-AAAA-MM-GG.log next to it.
    static let fileURL = directory.appendingPathComponent("MacTalkAct.log")

    private static let queue = DispatchQueue(label: "local.mactalkact.log")
    private static let stamp: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()
    private static let dayFormat: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    // MARK: Policy

    private struct Policy {
        var detailed = false
        var privateUntil: Date?
        var retentionDays = 7
    }
    private static let lock = NSLock()
    nonisolated(unsafe) private static var policy = Policy()
    /// Debug commands: always the detailed log (benchmarks, tests).
    nonisolated(unsafe) static var forceDetail = false

    /// Copied from `AppSettings` whenever one of its privacy settings changes.
    static func setPolicy(detailed: Bool, privateUntil: Date?, retentionDays: Int) {
        lock.lock()
        policy = Policy(detailed: detailed, privateUntil: privateUntil, retentionDays: max(1, retentionDays))
        lock.unlock()
    }

    private static var current: Policy {
        lock.lock()
        defer { lock.unlock() }
        return policy
    }

    static var isPrivate: Bool { current.privateUntil.map { $0 > Date() } ?? false }

    /// The detailed log is on (never in private mode).
    static var isDetailed: Bool { forceDetail || (current.detailed && !isPrivate) }

    // MARK: Writing

    private static func write(_ line: String) {
        let text = "\(stamp.string(from: Date())) \(line)\n"
        queue.async {
            guard let data = text.data(using: .utf8) else { return }
            rotateIfNeeded(now: Date())
            if let h = try? FileHandle(forWritingTo: fileURL) {
                h.seekToEndOfFile()
                h.write(data)
                try? h.close()
            } else {
                try? data.write(to: fileURL)
                protect(fileURL)
            }
        }
    }

    /// One line, after masking sensitive data, to the file, stdout and the unified log.
    private static func emit(_ message: String, level: OSLogType = .info, prefix: String = "") {
        let clean = Privacy.redact(message)
        logger.log(level: level, "\(prefix + clean, privacy: .public)")
        print("[MacTalkAct] \(prefix)\(clean)")
        write(prefix + clean)
    }

    static func debug(_ message: String) {
        write(Privacy.redact(message))
    }

    static func info(_ message: String) {
        emit(message)
    }

    static func error(_ message: String) {
        emit(message, level: .error, prefix: "ERRORE: ")
    }

    /// Only in the detailed log: what the agent saw and did, the text of ignored sentences.
    static func detail(_ message: @autoclosure () -> String) {
        guard isDetailed else { return }
        write(Privacy.redact(message()))
    }

    /// A sentence the app accepted, ready to put in a log line: the text (masked), or only its
    /// length in private mode.
    static func said(_ text: String) -> String {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return isPrivate ? "\(t.count) caratteri" : "«\(t)»"
    }

    /// Text written for the user (dictation): it is meant for someone else, only its length.
    static func dictation(_ text: String) {
        debug("✍️ " + (isDetailed ? "«\(text)»" : "\(text.count) caratteri"))
    }

    // MARK: Files

    nonisolated(unsafe) private static var checkedDay = ""
    nonisolated(unsafe) private static var writesSinceCheck = 0
    /// Over this size the file of the day is closed and a new one starts.
    private static let maxBytes = 20 * 1024 * 1024

    /// On the log queue: closes the file of a past day (or a too big one) and removes old days.
    private static func rotateIfNeeded(now: Date) {
        let today = dayFormat.string(from: now)
        writesSinceCheck += 1
        guard checkedDay != today || writesSinceCheck >= 500 else { return }
        let firstCheck = checkedDay.isEmpty
        checkedDay = today
        writesSinceCheck = 0
        let fm = FileManager.default
        if let attrs = try? fm.attributesOfItem(atPath: fileURL.path) {
            let modified = (attrs[.modificationDate] as? Date) ?? now
            let size = (attrs[.size] as? NSNumber)?.intValue ?? 0
            let day = dayFormat.string(from: modified)
            if day != today || size > maxBytes {
                var dest = directory.appendingPathComponent("MacTalkAct-\(day).log")
                if fm.fileExists(atPath: dest.path) {
                    let t = DateFormatter()
                    t.dateFormat = "HHmmss"
                    dest = directory.appendingPathComponent("MacTalkAct-\(day)-\(t.string(from: now)).log")
                }
                try? fm.moveItem(at: fileURL, to: dest)
            } else if firstCheck {
                protect(fileURL)
            }
        }
        let names = (try? fm.contentsOfDirectory(atPath: directory.path)) ?? []
        for name in archivesToDelete(names, now: now, days: current.retentionDays) {
            try? fm.removeItem(at: directory.appendingPathComponent(name))
        }
    }

    /// The archived days older than `days` days (today included). Other files are never touched.
    static func archivesToDelete(_ names: [String], now: Date, days: Int) -> [String] {
        let calendar = Calendar.current
        guard let cutoff = calendar.date(byAdding: .day, value: -(max(1, days) - 1), to: calendar.startOfDay(for: now)) else { return [] }
        return names.filter { name in
            guard name.hasPrefix("MacTalkAct-"), name.hasSuffix(".log") else { return false }
            let day = String(name.dropFirst("MacTalkAct-".count).prefix(10))
            guard let date = dayFormat.date(from: day) else { return false }
            return date < cutoff
        }
    }

    /// Every log file of the app (today and the archived days).
    static func allFiles() -> [URL] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        return names.filter { $0 == "MacTalkAct.log" || ($0.hasPrefix("MacTalkAct-") && $0.hasSuffix(".log")) }
            .map { directory.appendingPathComponent($0) }
    }

    /// «Cancella i log»: removes every log file. Returns how many.
    @discardableResult
    static func deleteAll() -> Int {
        queue.sync {
            var n = 0
            for url in allFiles() where (try? FileManager.default.removeItem(at: url)) != nil { n += 1 }
            checkedDay = ""
            return n
        }
    }

    /// Only the user can read the file.
    static func protect(_ url: URL) {
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}
