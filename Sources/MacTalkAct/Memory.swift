import AppKit

/// Personal memory: facts, aliases and voice macros, kept in a plain Markdown file
/// the user can read and edit (~/Library/Application Support/MacTalkAct/memoria.md).
///
/// Format:
///   ## Fatti
///   - «profilo aula IB» = Microsoft Edge, profilo «Aulab»
///   ## Macro
///   - modalità lavoro: apri Slack; apri Mail; apri Visual Studio Code
@MainActor
final class Memory {
    static let shared = Memory()

    struct Macro: Equatable {
        let name: String
        let steps: [String]
    }

    private(set) var facts: [String] = []
    private(set) var macros: [Macro] = []
    private var loadedAt = Date.distantPast

    let fileURL: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("MacTalkAct", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base.appendingPathComponent("memoria.md")
    }()

    private init() {
        reload()
    }

    // MARK: File

    /// Re-reads the file if it changed (the user may edit it by hand).
    func reload() {
        let fm = FileManager.default
        if !fm.fileExists(atPath: fileURL.path) { save() }
        let modified = (try? fm.attributesOfItem(atPath: fileURL.path)[.modificationDate] as? Date) ?? Date()
        guard modified > loadedAt else { return }
        loadedAt = modified
        guard let text = try? String(contentsOf: fileURL, encoding: .utf8) else { return }

        var section = ""
        var newFacts: [String] = []
        var newMacros: [Macro] = []
        for raw in text.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("## ") {
                section = Grammar.normalize(String(line.dropFirst(3)))
                continue
            }
            guard line.hasPrefix("- ") || line.hasPrefix("* ") else { continue }
            let item = String(line.dropFirst(2)).trimmingCharacters(in: .whitespaces)
            guard !item.isEmpty else { continue }
            if section.hasPrefix("macro") {
                guard let colon = item.firstIndex(of: ":") else { continue }
                let name = item[..<colon].trimmingCharacters(in: .whitespaces)
                let steps = item[item.index(after: colon)...].split(separator: ";")
                    .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                if !name.isEmpty, !steps.isEmpty { newMacros.append(Macro(name: name, steps: steps)) }
            } else {
                newFacts.append(item)
            }
        }
        facts = newFacts
        macros = newMacros
    }

    private func save() {
        var text = """
        # Memoria di MacTalkAct

        Cose che l'agente usa per capirti. Puoi modificare questo file a mano:
        una riga per fatto; per le macro «nome: passo; passo; passo».

        ## Fatti

        """
        for f in facts { text += "- \(f)\n" }
        text += "\n## Macro\n\n"
        for m in macros { text += "- \(m.name): \(m.steps.joined(separator: "; "))\n" }
        try? text.write(to: fileURL, atomically: true, encoding: .utf8)
        Log.protect(fileURL)
        loadedAt = (try? FileManager.default.attributesOfItem(atPath: fileURL.path)[.modificationDate] as? Date) ?? Date()
    }

    func openInEditor() {
        reload()
        let editor = URL(fileURLWithPath: "/System/Applications/TextEdit.app")
        NSWorkspace.shared.open([fileURL], withApplicationAt: editor, configuration: NSWorkspace.OpenConfiguration())
    }

    // MARK: Facts

    enum RememberOutcome { case saved, empty, sensitive, privateMode }

    /// Saves a fact, unless it contains sensitive data (passwords, codes, card or bank details,
    /// tax codes) or private mode is on.
    @discardableResult
    func remember(_ fact: String) -> RememberOutcome {
        reload()
        let f = fact.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !f.isEmpty else { return .empty }
        if AppSettings.shared.privateModeActive { return .privateMode }
        if Privacy.containsSensitive(f) {
            Log.info("Memoria: fatto non salvato, contiene dati sensibili")
            return .sensitive
        }
        guard !facts.contains(f) else { return .saved }
        facts.append(f)
        save()
        Log.info("Memoria: + 1 fatto")
        Log.detail("Memoria: + \(f)")
        return .saved
    }

    /// Removes facts containing the given text. Returns how many were removed.
    @discardableResult
    func forget(_ text: String) -> Int {
        reload()
        let needle = Grammar.normalize(text)
        guard !needle.isEmpty else { return 0 }
        let before = facts.count
        facts.removeAll { Grammar.normalize($0).contains(needle) }
        let removed = before - facts.count
        if removed > 0 { save(); Log.info("Memoria: − \(removed) fatti") }
        return removed
    }

    // MARK: Macros

    func saveMacro(name: String, steps: [String]) {
        reload()
        let clean = steps.map { $0.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ";", with: ",") }
            .filter { !$0.isEmpty }
        guard !name.isEmpty, !clean.isEmpty else { return }
        macros.removeAll { Grammar.normalize($0.name) == Grammar.normalize(name) }
        macros.append(Macro(name: name.replacingOccurrences(of: ":", with: " "), steps: clean))
        save()
        Log.info("Memoria: macro «\(name)», \(clean.count) passi")
        Log.detail("Memoria: macro «\(name)» = \(clean.joined(separator: "; "))")
    }

    @discardableResult
    func deleteMacro(_ name: String) -> Bool {
        reload()
        let n = Grammar.normalize(name)
        let before = macros.count
        macros.removeAll { Grammar.normalize($0.name) == n }
        guard macros.count != before else { return false }
        save()
        return true
    }

    /// The macro the user is invoking: its exact name, or "esegui/avvia/lancia <name>".
    func macro(for utterance: String) -> Macro? {
        reload()
        var n = Grammar.normalize(utterance)
        for prefix in ["esegui la macro ", "esegui macro ", "avvia la macro ", "avvia macro ", "macro ", "esegui ", "avvia "] where n.hasPrefix(prefix) {
            n = String(n.dropFirst(prefix.count))
            break
        }
        return macros.first { Grammar.normalize($0.name) == n }
    }

    // MARK: Prompt

    /// Facts sharing at least one meaningful word with the request (local engine: small context).
    func relevantFacts(for request: String, limit: Int) -> [String] {
        reload()
        let words = Set(Grammar.normalize(request).split(separator: " ").map(String.init).filter { $0.count > 3 })
        guard !words.isEmpty else { return [] }
        return facts.filter { fact in
            let f = Set(Grammar.normalize(fact).split(separator: " ").map(String.init))
            return !f.isDisjoint(with: words)
        }.prefix(limit).map { $0 }
    }

    /// What the agent receives with every request.
    var promptText: String {
        reload()
        var lines: [String] = []
        lines.append(facts.isEmpty ? "(no saved facts yet)" : facts.map { "- \($0)" }.joined(separator: "\n"))
        if !macros.isEmpty {
            lines.append("Macros: " + macros.map { "«\($0.name)»" }.joined(separator: ", "))
        }
        return lines.joined(separator: "\n")
    }
}
