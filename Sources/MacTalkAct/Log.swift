import Foundation
import os

/// Minimal logging: unified log plus stdout (useful when launched from Terminal).
enum Log {
    private static let logger = Logger(subsystem: "local.mactalkact", category: "app")

    /// ~/Library/Logs/MacTalkAct.log, readable with Console.app or `tail -f`.
    static let fileURL: URL = {
        let dir = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first!
            .appendingPathComponent("Logs", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("MacTalkAct.log")
    }()

    private static let queue = DispatchQueue(label: "local.mactalkact.log")
    private static let stamp: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()

    private static func write(_ line: String) {
        let text = "\(stamp.string(from: Date())) \(line)\n"
        queue.async {
            guard let data = text.data(using: .utf8) else { return }
            if let h = try? FileHandle(forWritingTo: fileURL) {
                h.seekToEndOfFile()
                h.write(data)
                try? h.close()
            } else {
                try? data.write(to: fileURL)
            }
        }
    }

    static func debug(_ message: String) {
        write(message)
    }

    static func info(_ message: String) {
        logger.info("\(message, privacy: .public)")
        print("[MacTalkAct] \(message)")
        write(message)
    }

    static func error(_ message: String) {
        logger.error("\(message, privacy: .public)")
        print("[MacTalkAct] ERRORE: \(message)")
        write("ERRORE: \(message)")
    }

    /// What the user said: kept private in the unified log.
    static func speech(_ message: String) {
        logger.info("\(message, privacy: .private)")
        print("[MacTalkAct] 🎙 \(message)")
        write("🎙 \(message)")
    }
}
