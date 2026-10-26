import AppKit
import ApplicationServices

enum ExecError: LocalizedError {
    case notFound(String)
    case appNotFound(String)
    case badKeys(String)
    case textChanged
    case unknownAction(String)

    var errorDescription: String? {
        switch self {
        case .notFound(let l): return "Non trovo «\(l)» sullo schermo"
        case .appNotFound(let a): return "Non trovo l'app «\(a)»"
        case .badKeys(let k): return "Scorciatoia non valida: \(k)"
        case .textChanged: return "Il testo è cambiato nel frattempo, riprova"
        case .unknownAction(let a): return "Azione sconosciuta: \(a)"
        }
    }
}

/// A key press such as "cmd+shift+z", parsed into a virtual key code and modifiers.
struct KeyCombo {
    let code: CGKeyCode
    let flags: CGEventFlags

    // ANSI virtual key codes (physical positions; letters match the Italian layout).
    private static let codes: [String: CGKeyCode] = [
        "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9, "b": 11,
        "q": 12, "w": 13, "e": 14, "r": 15, "y": 16, "t": 17, "1": 18, "2": 19, "3": 20, "4": 21,
        "6": 22, "5": 23, "=": 24, "9": 25, "7": 26, "-": 27, "8": 28, "0": 29, "]": 30, "o": 31,
        "u": 32, "[": 33, "i": 34, "p": 35, "l": 37, "j": 38, "'": 39, "k": 40, ";": 41, "\\": 42,
        ",": 43, "/": 44, "n": 45, "m": 46, ".": 47, "`": 50,
        "return": 36, "enter": 36, "invio": 36, "tab": 48, "space": 49, "spazio": 49,
        "delete": 51, "backspace": 51, "escape": 53, "esc": 53, "forwarddelete": 117,
        "home": 115, "end": 119, "pageup": 116, "pagedown": 121,
        "left": 123, "right": 124, "down": 125, "up": 126,
        "f1": 122, "f2": 120, "f3": 99, "f4": 118, "f5": 96, "f6": 97, "f7": 98, "f8": 100,
        "f9": 101, "f10": 109, "f11": 103, "f12": 111,
        "comma": 43, "period": 47, "slash": 44, "minus": 27, "equal": 24,
    ]

    static func parse(_ s: String) -> KeyCombo? {
        let parts = s.lowercased().split(separator: "+").map { $0.trimmingCharacters(in: .whitespaces) }
        guard let keyName = parts.last, !keyName.isEmpty else { return nil }
        var flags: CGEventFlags = []
        for mod in parts.dropLast() {
            switch mod {
            case "cmd", "command", "⌘", "meta": flags.insert(.maskCommand)
            case "shift", "⇧": flags.insert(.maskShift)
            case "alt", "option", "opt", "⌥": flags.insert(.maskAlternate)
            case "ctrl", "control", "⌃": flags.insert(.maskControl)
            case "fn": flags.insert(.maskSecondaryFn)
            default: return nil
            }
        }
        guard let code = codes[keyName] else { return nil }
        if [123, 124, 125, 126].contains(code) { flags.insert(.maskNumericPad); flags.insert(.maskSecondaryFn) }
        return KeyCombo(code: code, flags: flags)
    }

    func post() {
        let src = CGEventSource(stateID: .combinedSessionState)
        let down = CGEvent(keyboardEventSource: src, virtualKey: code, keyDown: true)
        down?.flags = flags
        down?.post(tap: .cghidEventTap)
        let up = CGEvent(keyboardEventSource: src, virtualKey: code, keyDown: false)
        up?.flags = flags
        up?.post(tap: .cghidEventTap)
    }
}

/// The "hands": turns decisions into keyboard, mouse and Accessibility actions.
@MainActor
final class Executor {
    /// Every text the app types, for "cancella quello che hai scritto" (AD-5).
    let journal = InsertionJournal()

    // MARK: Keys

    func press(_ combo: String) throws {
        guard let k = KeyCombo.parse(combo) else { throw ExecError.badKeys(combo) }
        k.post()
    }

    /// "cmd+a delete" → two presses in sequence.
    func pressSequence(_ keys: String) async throws {
        for part in keys.split(separator: " ") where !part.isEmpty {
            try press(String(part))
            try await Task.sleep(for: .milliseconds(60))
        }
    }

    func deleteBackward(_ count: Int) async {
        guard count > 0, let k = KeyCombo.parse("delete") else { return }
        for i in 0..<count {
            k.post()
            if i % 10 == 9 { try? await Task.sleep(for: .milliseconds(8)) }
        }
        try? await Task.sleep(for: .milliseconds(40))
    }

    // MARK: Text

    /// Inserts text at the caret via the clipboard (works in almost every app),
    /// then restores whatever the user had copied.
    func paste(_ text: String) async {
        let pb = NSPasteboard.general
        let saved: [[(NSPasteboard.PasteboardType, Data)]] = (pb.pasteboardItems ?? []).map { item in
            item.types.compactMap { t in item.data(forType: t).map { (t, $0) } }
        }
        pb.clearContents()
        pb.setString(text, forType: .string)
        // Tells clipboard managers not to record this temporary content.
        pb.setData(Data(), forType: NSPasteboard.PasteboardType("org.nspasteboard.TransientType"))
        try? press("cmd+v")
        try? await Task.sleep(for: .milliseconds(450))

        pb.clearContents()
        let items = saved.map { pairs -> NSPasteboardItem in
            let item = NSPasteboardItem()
            for (t, d) in pairs { item.setData(d, forType: t) }
            return item
        }
        if !items.isEmpty { pb.writeObjects(items) }
    }

    func insertDictation(_ text: String, context: ScreenContext) async {
        let t = context.selectedText.isEmpty ? TextDiff.spaced(text, after: context.textBeforeCursor) : text
        guard !t.isEmpty else { return }
        await paste(t)
        await journal.record(text: t, before: context)
    }

    /// Types text for the agent or the local lane, and records it.
    func typeText(_ text: String) async {
        let before = ScreenContext.capture(includeLabels: false)
        await paste(text)
        if before.selectedText.isEmpty { await journal.record(text: text, before: before) } else { journal.clear() }
    }

    /// Removes the last text the app typed, if the field is still as the app left it (FR-10).
    /// Returns a short description for the HUD.
    func undoLastInsertion() async -> String? {
        let now = ScreenContext.capture(includeLabels: false)
        switch journal.undoPlan(now: now) {
        case .nothing:
            return nil
        case .deleteCharacters(let n):
            await deleteBackward(n)
            journal.clear()
            return "Tolto quello che avevo scritto"
        case .commandZ:
            try? press("cmd+z")
            journal.clear()
            return "Ho usato Annulla: controlla il risultato"
        }
    }

    /// Agent version: diffs against the text before the caret as it is right now.
    func rewriteBeforeCursor(new: String) async throws {
        let fresh = ScreenContext.capture(includeLabels: false)
        try await rewriteBeforeCursor(original: fresh, new: new)
    }

    /// Replaces the text before the caret with `new`, deleting only what changed.
    func rewriteBeforeCursor(original: ScreenContext, new: String) async throws {
        let fresh = ScreenContext.capture(includeLabels: false)
        guard fresh.textBeforeCursor == original.textBeforeCursor else { throw ExecError.textChanged }
        if !fresh.selectedText.isEmpty {
            try press("left") // collapse the selection to its start
            try await Task.sleep(for: .milliseconds(50))
        }
        let edit = TextDiff.backspaceEdit(old: original.textBeforeCursor, new: new)
        await deleteBackward(edit.deletes)
        if !edit.insert.isEmpty { await paste(edit.insert) }
    }

    // MARK: Replace text (also in web editors)

    enum ReplaceResult: Equatable {
        case done(String)
        case notFound(String)
        case unverified(String)
        case noField
    }

    /// Copies the current selection without disturbing the user's clipboard.
    func copySelection() async -> String? {
        let pb = NSPasteboard.general
        let saved: [[(NSPasteboard.PasteboardType, Data)]] = (pb.pasteboardItems ?? []).map { item in
            item.types.compactMap { t in item.data(forType: t).map { (t, $0) } }
        }
        let before = pb.changeCount
        try? press("cmd+c")
        var copied: String?
        for _ in 0..<10 {
            try? await Task.sleep(for: .milliseconds(40))
            if pb.changeCount != before { copied = pb.string(forType: .string); break }
        }
        pb.clearContents()
        let items = saved.map { pairs -> NSPasteboardItem in
            let item = NSPasteboardItem()
            for (t, d) in pairs { item.setData(d, forType: t) }
            return item
        }
        if !items.isEmpty { pb.writeObjects(items) }
        return copied
    }

    /// Replaces `find` with `new` in the focused field (FR-16). Tries, in order:
    /// 1. Accessibility (native fields): select the exact range and paste;
    /// 2. the current line (web code editors, notebook cells): select line, copy, check, paste;
    /// 3. the whole field (short cells): select all, copy, check, paste.
    /// Each path verifies the result before reporting success.
    /// Test switch: skip the Accessibility path to exercise the keyboard ones.
    static var keyboardOnlyReplace = ProcessInfo.processInfo.environment["MTA_KEYBOARD_REPLACE"] != nil

    func replaceText(find: String, with new: String) async -> ReplaceResult {
        let ctx = ScreenContext.capture(includeLabels: false)
        guard let front = AX.frontmostApplication() else { return .noField }
        let app = AX.app(front.processIdentifier)
        let focused = AX.focusedElement(in: app)

        // 1. Accessibility
        if !Self.keyboardOnlyReplace, let el = focused, AX.isSettable(el, kAXValueAttribute), let value = AX.string(el, kAXValueAttribute),
           let r = value.range(of: find) {
            let ns = NSRange(r, in: value)
            var cf = CFRange(location: ns.location, length: ns.length)
            if let axRange = AXValueCreate(.cfRange, &cf),
               AXUIElementSetAttributeValue(el, kAXSelectedTextRangeAttribute as CFString, axRange) == .success {
                try? await Task.sleep(for: .milliseconds(60))
                await typeText(new)
                try? await Task.sleep(for: .milliseconds(150))
                let after = AX.string(el, kAXValueAttribute) ?? ""
                return after.contains(new) ? .done("accessibility") : .unverified("accessibility")
            }
        }
        // Outside a text field, cmd+← in a browser means "go back": keyboard paths only inside a field.
        guard ctx.isEditable else { return .noField }

        // 2. Current line
        try? press("cmd+left")
        try? press("cmd+shift+right")
        try? await Task.sleep(for: .milliseconds(80))
        if let line = await copySelection()?.trimmingCharacters(in: .newlines), line.contains(find) {
            let expected = line.replacingOccurrences(of: find, with: new, options: [], range: line.range(of: find))
            await typeText(expected)
            try? await Task.sleep(for: .milliseconds(150))
            try? press("cmd+left")
            try? press("cmd+shift+right")
            try? await Task.sleep(for: .milliseconds(80))
            let check = await copySelection()?.trimmingCharacters(in: .newlines)
            try? press("right")
            return check == expected ? .done("riga") : .unverified("riga")
        }
        try? press("right")

        // 3. Whole field (notebook cell, short text area)
        try? press("cmd+a")
        try? await Task.sleep(for: .milliseconds(80))
        guard let all = await copySelection(), !all.isEmpty else { try? press("right"); return .notFound("") }
        guard all.count < 20_000, let r = all.range(of: find) else {
            try? press("right")
            return .notFound(String(all.prefix(200)))
        }
        let expected = all.replacingCharacters(in: r, with: new)
        await typeText(expected)
        try? await Task.sleep(for: .milliseconds(200))
        try? press("cmd+a")
        try? await Task.sleep(for: .milliseconds(80))
        let check = await copySelection()
        try? press("right")
        return check?.trimmingCharacters(in: .newlines) == expected.trimmingCharacters(in: .newlines)
            ? .done("campo intero") : .unverified("campo intero")
    }

    /// Test helper: the whole content of the focused field (select all + copy, then collapse).
    func copySelectionOfField() async -> String? {
        try? press("cmd+a")
        try? await Task.sleep(for: .milliseconds(80))
        let t = await copySelection()
        try? press("right")
        return t
    }

    // MARK: Click

    /// Finds the on-screen element whose label best matches what the user said and presses it.
    func click(_ query: String) async throws -> String {
        guard let front = AX.frontmostApplication() else { throw ExecError.notFound(query) }
        let app = AX.app(front.processIdentifier)
        AX.prepare(app, pid: front.processIdentifier, bundleID: front.bundleIdentifier)
        let root = AX.focusedWindow(in: app) ?? app
        var items = AXTree.collect(in: root, limit: 800, deadline: 1.0)
        // Also look at the menu bar ("clicca File", "clicca Modifica").
        if let menuBar = AX.element(app, kAXMenuBarAttribute) {
            items += AX.children(menuBar).compactMap { item in
                AX.string(item, kAXTitleAttribute).map { LabeledElement(element: item, label: $0, role: "AXMenuBarItem") }
            }
        }
        guard let i = LabelMatcher.best(query: query, labels: items.map(\.label)) else {
            throw ExecError.notFound(query)
        }
        let target = items[i]

        if AX.press(target.element) { return target.label }
        var current = target.element
        for _ in 0..<3 {
            guard let parent = AX.element(current, kAXParentAttribute) else { break }
            if AX.actions(parent).contains(kAXPressAction), AX.press(parent) { return target.label }
            current = parent
        }
        if let f = AX.frame(target.element) {
            await mouseClick(at: CGPoint(x: f.midX, y: f.midY))
            return target.label
        }
        throw ExecError.notFound(query)
    }

    /// A real mouse click (the pointer jumps there and comes back).
    func mouseClick(at point: CGPoint, count: Int = 1, right: Bool = false) async {
        let original = CGEvent(source: nil)?.location
        let down: CGEventType = right ? .rightMouseDown : .leftMouseDown
        let up: CGEventType = right ? .rightMouseUp : .leftMouseUp
        let button: CGMouseButton = right ? .right : .left
        CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: point, mouseButton: button)?
            .post(tap: .cghidEventTap)
        try? await Task.sleep(for: .milliseconds(30))
        for n in 1...max(1, count) {
            let d = CGEvent(mouseEventSource: nil, mouseType: down, mouseCursorPosition: point, mouseButton: button)
            d?.setIntegerValueField(.mouseEventClickState, value: Int64(n))
            d?.post(tap: .cghidEventTap)
            let u = CGEvent(mouseEventSource: nil, mouseType: up, mouseCursorPosition: point, mouseButton: button)
            u?.setIntegerValueField(.mouseEventClickState, value: Int64(n))
            u?.post(tap: .cghidEventTap)
            try? await Task.sleep(for: .milliseconds(40))
        }
        try? await Task.sleep(for: .milliseconds(60))
        if let original { CGWarpMouseCursorPosition(original) }
    }

    // MARK: Scroll

    /// Scrolls the focused window (not whatever happens to be under the mouse).
    func scroll(_ direction: String, amount: Int, at target: CGPoint? = nil) async {
        let ctx = ScreenContext.capture(includeLabels: false)
        let point: CGPoint
        if let target {
            point = target
        } else if let f = ctx.windowFrame {
            point = CGPoint(x: f.midX, y: f.midY)
        } else {
            point = CGEvent(source: nil)?.location ?? .zero
        }
        let total = 380 * max(1, min(amount, 10))
        let steps = 8
        let per = Int32(total / steps)
        var dy: Int32 = 0, dx: Int32 = 0
        switch direction {
        case "up": dy = per
        case "down": dy = -per
        case "left": dx = per
        case "right": dx = -per
        default: dy = -per
        }
        for _ in 0..<steps {
            let ev = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2, wheel1: dy, wheel2: dx, wheel3: 0)
            ev?.location = point
            ev?.post(tap: .cghidEventTap)
            try? await Task.sleep(for: .milliseconds(12))
        }
    }

    // MARK: Apps

    private static let aliases: [String: String] = [
        "posta": "mail", "email": "mail", "e mail": "mail", "impostazioni": "impostazioni di sistema",
        "preferenze": "impostazioni di sistema", "chrome": "google chrome", "vs code": "visual studio code",
        "vscode": "visual studio code", "codice": "visual studio code", "browser": "safari",
        "file": "finder", "cartelle": "finder", "word": "microsoft word", "excel": "microsoft excel",
        "powerpoint": "microsoft powerpoint", "teams": "microsoft teams", "outlook": "microsoft outlook",
    ]
    private static let articles: Set<String> = ["il", "lo", "la", "l", "i", "gli", "le", "app", "applicazione", "programma"]

    private lazy var installedApps: [(name: String, url: URL)] = Self.scanApplications()

    private static func scanApplications() -> [(name: String, url: URL)] {
        let fm = FileManager.default
        let dirs = ["/Applications", "/Applications/Utilities", "/System/Applications",
                    "/System/Applications/Utilities", NSHomeDirectory() + "/Applications"]
        var out: [(String, URL)] = []
        for dir in dirs {
            guard let items = try? fm.contentsOfDirectory(atPath: dir) else { continue }
            for item in items where item.hasSuffix(".app") {
                let path = dir + "/" + item
                let url = URL(fileURLWithPath: path)
                let display = fm.displayName(atPath: path).replacingOccurrences(of: ".app", with: "")
                out.append((display, url))
                let raw = String(item.dropLast(4))
                if raw != display { out.append((raw, url)) }
            }
        }
        return out
    }

    /// How well a spoken name matches an app name. The whole spoken name must match the
    /// app name (or a word-aligned part of it): "edge" → «Microsoft Edge» yes,
    /// "prima mail" → «Mail» no (that is a request about an email, not an app).
    static func appMatchScore(query: String, name: String) -> Int {
        let q = Grammar.normalize(query), n = Grammar.normalize(name)
        guard !q.isEmpty, !n.isEmpty else { return 0 }
        if n == q { return 100 }
        if n.hasPrefix(q + " ") { return 90 }
        if n.hasSuffix(" " + q) || n.contains(" " + q + " ") { return 80 }
        if n.hasPrefix(q), q.count >= 4 { return 75 } // "calcol" → «Calcolatrice»
        return 0
    }

    private static func cleanAppQuery(_ spoken: String) -> String {
        var q = Grammar.normalize(spoken).split(separator: " ").map(String.init)
        while let first = q.first, articles.contains(first) { q.removeFirst() }
        let query = q.joined(separator: " ")
        return aliases[query] ?? query
    }

    /// Finds an installed or running application by (spoken) name.
    func findApp(_ spoken: String) -> URL? {
        let query = Self.cleanAppQuery(spoken)
        let running = NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular }
        if let app = running.max(by: { Self.appMatchScore(query: query, name: $0.localizedName ?? "") < Self.appMatchScore(query: query, name: $1.localizedName ?? "") }),
           Self.appMatchScore(query: query, name: app.localizedName ?? "") >= 75, let url = app.bundleURL {
            return url
        }
        let best = installedApps.max { Self.appMatchScore(query: query, name: $0.name) < Self.appMatchScore(query: query, name: $1.name) }
        return best.flatMap { Self.appMatchScore(query: query, name: $0.name) >= 75 ? $0.url : nil }
    }

    func openApp(_ spoken: String) async throws -> String {
        let query = Self.cleanAppQuery(spoken)
        guard !query.isEmpty else { throw ExecError.appNotFound(spoken) }
        func score(_ name: String) -> Int { Self.appMatchScore(query: query, name: name) }

        let running = NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular }
        let bestRunning = running.map { ($0, score($0.localizedName ?? "")) }.max { $0.1 < $1.1 }
        if let (app, s) = bestRunning, s >= 75 {
            if !(await bringToFront(app)), let url = app.bundleURL { try await activate(url) }
            return app.localizedName ?? spoken
        }

        let bestInstalled = installedApps.map { ($0, score($0.name)) }.max { $0.1 < $1.1 }
        if let (app, s) = bestInstalled, s >= 75 {
            try await activate(app.url)
            return app.name
        }
        throw ExecError.appNotFound(spoken)
    }

    /// Launches (if needed) and brings an app to the front.
    /// macOS does not let a background app activate another one, so after asking
    /// politely we force it through Accessibility, like window managers do.
    @discardableResult
    func activate(_ url: URL) async throws -> Bool {
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        let app = try await NSWorkspace.shared.openApplication(at: url, configuration: config)
        return await bringToFront(app)
    }

    @discardableResult
    func bringToFront(_ app: NSRunningApplication) async -> Bool {
        for attempt in 0..<25 {
            if AX.frontmostApplication()?.processIdentifier == app.processIdentifier { return true }
            app.unhide()
            if attempt == 2 || attempt == 10 {
                // The polite way did not work: switch like a window switcher would.
                FrontProcess.activate(pid: app.processIdentifier)
            }
            let ax = AX.app(app.processIdentifier)
            AXUIElementSetAttributeValue(ax, kAXFrontmostAttribute as CFString, kCFBooleanTrue)
            let window = AX.element(ax, kAXMainWindowAttribute) ?? AX.element(ax, kAXFocusedWindowAttribute)
                ?? (AX.value(ax, kAXWindowsAttribute) as? [AXUIElement])?.first
            if let window {
                AXUIElementPerformAction(window, kAXRaiseAction as CFString)
                AXUIElementSetAttributeValue(window, kAXMainAttribute as CFString, kCFBooleanTrue)
            }
            try? await Task.sleep(for: .milliseconds(attempt < 5 ? 80 : 160))
        }
        let ok = AX.frontmostApplication()?.processIdentifier == app.processIdentifier
        if !ok { Log.error("Non riesco a portare in primo piano \(app.localizedName ?? "?")") }
        return ok
    }

    func openURL(_ spoken: String) {
        var s = spoken.trimmingCharacters(in: Grammar.edgePunctuation)
        if !s.lowercased().hasPrefix("http") { s = "https://" + s }
        if let url = URL(string: s) { NSWorkspace.shared.open(url) }
    }

    /// Opens a URL, optionally in a given browser.
    func openURL(_ spoken: String, in browser: String?) async throws {
        guard let browser, !browser.isEmpty else { openURL(spoken); return }
        guard let appURL = findApp(browser) else { throw ExecError.appNotFound(browser) }
        var s = spoken.trimmingCharacters(in: Grammar.edgePunctuation)
        if !s.lowercased().hasPrefix("http") { s = "https://" + s }
        guard let url = URL(string: s) else { return }
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        _ = try await NSWorkspace.shared.open([url], withApplicationAt: appURL, configuration: config)
    }

    // MARK: Plan steps

    func run(_ step: PlanStep, context: ScreenContext) async throws {
        switch step.action {
        case "insert_text":
            await insertDictation(step.text, context: ScreenContext.capture(includeLabels: false))
        case "replace_selection":
            await paste(step.text)
        case "rewrite_before_cursor":
            try await rewriteBeforeCursor(original: context, new: step.text)
        case "press_keys":
            try await pressSequence(step.keys)
        case "click":
            _ = try await click(step.target)
        case "open_app":
            _ = try await openApp(step.target)
            try await Task.sleep(for: .milliseconds(800))
        case "open_url":
            openURL(step.target)
            try await Task.sleep(for: .milliseconds(800))
        case "scroll":
            await scroll(step.target, amount: max(1, step.amount))
        case "wait":
            try await Task.sleep(for: .milliseconds(min(max(step.amount, 0), 5000)))
        default:
            throw ExecError.unknownAction(step.action)
        }
    }
}
