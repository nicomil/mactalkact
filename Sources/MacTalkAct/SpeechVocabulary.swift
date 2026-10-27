import AppKit

/// Words the recognizer should expect (contextual strings of SpeechAnalyzer): technical terms the
/// user says while working, the wake phrases, the names in the personal memory and the words
/// visible in the frontmost window («wincleaner», «Sources», a file or a workspace name).
/// Without them the Italian model hears «hotspot» for «output» and «Win cleaner» for «wincleaner».
@MainActor
final class SpeechVocabulary {
    /// Called with the new list whenever it changes.
    var onChange: (([String]) -> Void)?

    static let base = [
        "output", "input", "terminale", "comando", "cartella", "file", "workspace", "tab", "scheda", "finestra",
        "notebook", "cella", "Python", "Swift", "JavaScript", "codice", "script", "build", "README", "Markdown",
        "JSON", "API", "URL", "link", "browser", "Safari", "Edge", "Chrome", "Finder", "Keynote", "slide", "Xcode",
        "Claude", "Codex", "ChatGPT", "Ollama", "MacTalkAct", "git", "commit", "push", "pull", "branch", "merge",
        "log", "login", "screenshot", "prompt", "agente", "cursore", "download", "upload", "ls", "cd", "sudo",
        "Zoom", "Teams", "Slack", "WhatsApp", "Gmail", "Google", "YouTube", "Wi-Fi", "Bluetooth",
    ]

    private var signature = ""
    private var observer: NSObjectProtocol?
    private var refreshTask: Task<Void, Never>?

    func start() {
        observer = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh(after: 0.6) }
        }
        refresh(after: 0)
    }

    /// Reads the frontmost window again after `delay` (when the window changed since last time).
    func refresh(after delay: Double) {
        refreshTask?.cancel()
        refreshTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard let self, !Task.isCancelled else { return }
            let quick = ScreenContext.capture(includeLabels: false)
            let sig = quick.bundleID + "|" + quick.windowTitle
            guard sig != self.signature else { return }
            self.signature = sig
            let ctx = ScreenContext.capture(includeLabels: true)
            let words = Self.build(labels: [ctx.windowTitle, ctx.appName] + ctx.visibleLabels,
                                   wakePhrases: AppSettings.shared.wakePhraseList, memory: Memory.shared)
            self.onChange?(words)
        }
    }

    /// Base terms, wake phrases, short memory names, then words and short labels from the screen.
    static func build(labels: [String], wakePhrases: [String], memory: Memory) -> [String] {
        var out: [String] = []
        var seen = Set<String>()
        func add(_ s: String) {
            let t = s.trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
            guard t.count >= 2, t.count <= 40, seen.insert(t.lowercased()).inserted else { return }
            out.append(t)
        }
        base.forEach(add)
        wakePhrases.forEach(add)
        memory.macros.forEach { add($0.name) }
        // Screen: short labels as phrases, and the unusual words of every label.
        for label in labels {
            let words = label.split(whereSeparator: { !$0.isLetter && !$0.isNumber && $0 != "_" && $0 != "-" && $0 != "." })
            if (1...3).contains(words.count), label.count <= 30 { add(label) }
            for w in words where w.count >= 4 && Self.isDistinctive(String(w)) { add(String(w)) }
            if out.count >= 160 { break }
        }
        return Array(out.prefix(160))
    }

    /// Words the recognizer would not guess: mixed case, digits, underscores, or not plain Italian.
    private static func isDistinctive(_ w: String) -> Bool {
        if w.contains(where: \.isNumber) || w.contains("_") || w.contains(".") { return true }
        if w.dropFirst().contains(where: \.isUppercase) { return true } // camelCase, acronyms
        let n = Grammar.normalize(w)
        return !common.contains(n)
    }

    private static let common: Set<String> = [
        "della", "delle", "degli", "dello", "nella", "nelle", "negli", "sono", "come", "questo", "questa", "anche",
        "tutti", "tutte", "dopo", "prima", "senza", "sempre", "quando", "perche", "ancora", "molto", "altro",
        "altri", "nuovo", "nuova", "apri", "chiudi", "salva", "modifica", "vista", "aiuto", "finestra", "inserisci",
        "formato", "strumenti", "impostazioni", "preferenze", "cerca", "indietro", "avanti", "pagina", "home",
        "file", "edit", "view", "help", "window", "open", "close", "save", "new", "the", "and", "with", "from",
        "this", "that", "your", "button", "share", "back", "forward", "reload", "search", "settings", "menu",
    ]
}
