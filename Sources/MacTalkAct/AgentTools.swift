import AppKit
import ApplicationServices

/// The tools the agent (Claude, Codex or the local model) uses to see and act on the Mac.
/// Exposed over MCP by `MCPServer`; every call runs here, inside the app,
/// with the app's own permissions and safety rules (AD-16, AD-20).
///
/// Like the computer use of Claude and Codex (Epic 6): elements keep their id for the whole
/// request, and every action waits for the interface to settle and reports what changed (AD-19).
@MainActor
final class AgentTools {

    /// Progress line for the HUD ("Clicco «Invia»").
    var onProgress: ((String) -> Void)?
    /// Asks the user something by voice. `confirmation` = yes/no question. Returns nil on timeout.
    var askUser: ((String, Bool) async -> String?)?
    /// Add «what changed» to the result of every action (AD-19). The local engine observes on its own.
    var reportOutcome = true

    private let executor: Executor
    private var registry: [Int: (element: AXUIElement, label: String, role: String)] = [:]
    /// Elements already seen in this request, to give them back the same id (FR-36).
    private var known: [CFHashCode: [(element: AXUIElement, id: Int)]] = [:]
    private var nextID = 1
    private(set) var generation = 0
    private var lastShot: WindowShot?
    /// The last full view of the window: the outcome of an action is the difference from it.
    private var lastView: View?
    /// The web area seen in the last view: its loading progress says when a page is still loading.
    private var lastWebArea: AXUIElement?
    private var confirmedUntil = Date.distantPast
    private(set) var callCount = 0
    /// Calls that changed something on the Mac in this task (AD-15): after the first one,
    /// a request is never repeated on another engine.
    private(set) var effectfulCalls = 0
    /// When the first tool was called in this task (time to first tool, NFR-9).
    private(set) var firstCallAt: Date?
    /// When the first action with effects happened (local engine: the app observes first).
    private(set) var firstEffectAt: Date?
    /// Text changes made during the current task, for the conversation memory (FR-8).
    private(set) var changes: [String] = []
    /// The app the task works in: keystrokes and clicks stop if another app takes the front
    /// (the user switched app), unless the agent itself opened it.
    private var targetPID: pid_t?
    private var maxCalls: Int { AppSettings.shared.agentMaxSteps }
    var cancelled = false

    init(executor: Executor) {
        self.executor = executor
    }

    /// Debug only (`--fallback-test`): counts an action with effects without doing anything.
    func simulateEffect() { effectfulCalls += 1 }

    /// Fresh state for a new task. `keepElements`: the same task retried on another engine before
    /// any action (AD-15): the screen did not change, the ids already sent stay valid.
    func reset(keepElements: Bool = false) {
        if !keepElements {
            registry.removeAll()
            known.removeAll()
            nextID = 1
            generation = 0
            lastView = nil
            lastWebArea = nil
        }
        lastShot = nil
        confirmedUntil = .distantPast
        callCount = 0
        effectfulCalls = 0
        firstCallAt = nil
        firstEffectAt = nil
        changes = []
        cancelled = false
        targetPID = AX.realFrontmostApplication()?.processIdentifier
    }

    /// Tools that press, click or type in the frontmost app: blocked without the Accessibility
    /// permission or if the user switched app.
    private static let actingTools: Set<String> = [
        "click", "click_many", "type_text", "press_keys", "replace_text", "edit_text", "scroll",
        "set_value", "perform_action", "select_text", "drag", "hover", "menu",
    ]
    /// Everything that changes the screen, an app or the user's data. Reading tools
    /// (observe, screenshot, get_text, browser_profiles, wait) and questions are not here.
    static let effectfulTools: Set<String> = actingTools.union(["open_app", "open_url", "save_macro", "delete_macro"])
    /// Tools whose result ends with «what changed» (AD-19).
    private static let outcomeTools: Set<String> = actingTools.union(["open_app", "open_url", "wait", "act"])
    /// Tools allowed as steps of `act`.
    private static let actSteps: Set<String> = actingTools.union(["open_app", "open_url", "wait"])

    /// nil when it is safe to act; otherwise an error for the agent.
    private func frontmostChanged() -> String? {
        guard let target = targetPID, let now = AX.realFrontmostApplication() else { return nil }
        if now.processIdentifier == target || now.bundleIdentifier == Bundle.main.bundleIdentifier { return nil }
        return "The frontmost app changed to «\(now.localizedName ?? "?")»: the user probably switched app. Do not act there. Stop and tell the user in one short Italian sentence."
    }

    // MARK: Definitions (MCP tools/list)

    private static let idOrPoint: [String: Any] = [
        "id": ["type": "integer", "description": "Element id from observe or screenshot."],
        "x": ["type": "number", "description": "X in the latest screenshot (instead of id)."],
        "y": ["type": "number", "description": "Y in the latest screenshot (instead of id)."],
    ]
    private static let afterAction = " Returns what changed on screen (title, focus, elements added/removed/changed): no need to observe again unless you need more."

    static let definitions: [[String: Any]] = [
        tool("observe",
             "Describe the frontmost window: app, title, focused element, and the visible UI elements with an [id] for the other tools. Clickable elements are marked with *; in browsers, elements of the web page are marked (page). `value=` is the current value, `settable` means set_value works, `actions=` lists extra actions for perform_action. Ids stay the same for the whole request while the element exists. Large web pages are truncated: pass `query` to search the WHOLE window for elements whose text contains it (e.g. a mail subject or sender).",
             ["query": ["type": "string", "description": "Optional text to search for (case and accent insensitive)."]]),
        tool("screenshot",
             "JPEG screenshot of the frontmost window with an orange numbered tag on every clickable element: click(id) with that number. Use it when observe is not enough (icons without labels, images, canvas, visual layout). Pass `region` [x0, y0, x1, y1] (coordinates of the latest screenshot) to zoom into a part at full resolution, e.g. small text; click x/y keep using the coordinates of the full screenshot.",
             ["region": ["type": "array", "items": ["type": "number"], "description": "Optional [x0, y0, x1, y1] to zoom into."]]),
        tool("click",
             "Click an element by id or at x/y of the latest screenshot. method: 'auto' (accessibility press, then real mouse click), 'mouse' (real mouse click, best for web pages and lists), 'double', 'right' (context menu), 'middle'. `count` 2 or 3 for double/triple click (triple selects a line or paragraph). `modifiers` e.g. 'cmd' or 'shift' for cmd-click (new tab, multiple selection) or shift-click (range)." + afterAction,
             idOrPoint.merging([
                 "method": ["type": "string", "enum": ["auto", "mouse", "double", "right", "middle"]],
                 "count": ["type": "integer", "description": "1-3. Default 1."],
                 "modifiers": ["type": "string", "description": "Keys held during the click: 'cmd', 'shift', 'alt', 'ctrl', or 'cmd+shift'."],
             ]) { $1 }),
        tool("click_many",
             "Click several elements in one call (e.g. many checkboxes in a list), in order. Returns, for each id, whether it worked and the element's state afterwards (checked/unchecked when it is a checkbox). Prefer this to many single clicks." + afterAction,
             ["ids": ["type": "array", "items": ["type": "integer"]],
              "method": ["type": "string", "enum": ["auto", "mouse"]]], required: ["ids"]),
        tool("type_text",
             "Type text at the caret (pasted, any length, any language). If id is given, that field is focused first and the result is checked." + afterAction,
             ["text": ["type": "string"], "id": ["type": "integer"]], required: ["text"]),
        tool("set_value",
             "Set the value of an element marked `settable` in observe: a slider or stepper (number), a native text field, a date field. Instant and exact; the value is read back to check it. For web form fields prefer type_text." + afterAction,
             ["id": ["type": "integer"], "value": ["type": "string", "description": "New value (a number for sliders)."]], required: ["id", "value"]),
        tool("select_text",
             "Select text inside a text field or text area (id, or the focused field), or put the caret before/after it. `prefix`/`suffix`: text just before/after the wanted occurrence, when it appears more than once. Then type_text replaces the selection, or press_keys acts on it." + afterAction,
             ["text": ["type": "string"], "id": ["type": "integer"],
              "prefix": ["type": "string"], "suffix": ["type": "string"],
              "where": ["type": "string", "enum": ["text", "before", "after"], "description": "Select the text (default), or caret before/after it."]],
             required: ["text"]),
        tool("perform_action",
             "Run an accessibility action listed in `actions=` for that element in observe (e.g. Increment, Decrement, Confirm, Cancel, or an app's custom action like Archive). Do not guess action names." + afterAction,
             ["id": ["type": "integer"], "action": ["type": "string"]], required: ["id", "action"]),
        tool("drag",
             "Drag with the mouse from an element or point to another: move a card to a column, a file into a folder, a slider handle, a window divider. Use from_id/to_id, or from_x/from_y/to_x/to_y of the latest screenshot (they can be mixed)." + afterAction,
             ["from_id": ["type": "integer"], "to_id": ["type": "integer"],
              "from_x": ["type": "number"], "from_y": ["type": "number"], "to_x": ["type": "number"], "to_y": ["type": "number"],
              "modifiers": ["type": "string", "description": "Keys held during the drag, e.g. 'alt' to copy."]]),
        tool("hover",
             "Move the mouse over an element or point and leave it there: opens menus and tooltips that appear on hover. The result lists the elements that appeared." + afterAction,
             idOrPoint),
        tool("menu",
             "Use the menu bar of the frontmost app by name, without coordinates. path 'Formato > Font > Grassetto' chooses that item; a partial path ('Formato') or an empty path lists the items with their keyboard shortcuts. Names match ignoring case and accents; the app's language is usually Italian." + afterAction,
             ["path": ["type": "string"]]),
        tool("act",
             "Run several actions in one call, in order, and get one outcome at the end: fill a form, a known sequence of clicks and keys. Each step is an object with `tool` (click, type_text, press_keys, set_value, select_text, perform_action, drag, hover, menu, scroll, replace_text, edit_text, click_many, open_app, open_url, wait) and that tool's arguments, e.g. {\"tool\":\"type_text\",\"id\":12,\"text\":\"Luca\"}. Stops at the first error; later steps are reported as not executed. Ids must come from the latest observe. Confirmations still apply to every step.",
             ["steps": ["type": "array", "items": ["type": "object", "properties": ["tool": ["type": "string"]], "required": ["tool"]]]],
             required: ["steps"]),
        tool("replace_text",
             "Replace text inside the focused text field, document or code/notebook cell, then verify it. Works also in web editors (Jupyter, Colab, code editors) where get_text sees nothing: click into the field or cell first. `find` must be the exact current text (a word, a line or more).",
             ["find": ["type": "string"], "replace": ["type": "string"]], required: ["find", "replace"]),
        tool("press_keys",
             "Press keyboard shortcuts or special keys: 'cmd+shift+d', 'return', 'escape', 'tab', 'down', 'pagedown', or a sequence separated by spaces like 'cmd+a delete'. Letters and digits work as keys; to type text or symbols (* + = @ …) use type_text." + afterAction,
             ["keys": ["type": "string"]], required: ["keys"]),
        tool("scroll",
             "Scroll the window, or the element with the given id (e.g. a list or the page)." + afterAction,
             ["direction": ["type": "string", "enum": ["up", "down", "left", "right"]],
              "amount": ["type": "integer", "description": "Screens to scroll, 1-10. Default 1."],
              "id": ["type": "integer"]], required: ["direction"]),
        tool("open_app",
             "Open or bring to front an application by name (e.g. 'Microsoft Edge', 'Mail', 'Finder'). For Edge, Chrome or Brave, `profile` opens a window of that browser profile (name as the user says it, or as listed by browser_profiles).",
             ["name": ["type": "string"], "profile": ["type": "string"]], required: ["name"]),
        tool("open_url",
             "Open a URL, optionally in a specific browser app (e.g. 'Microsoft Edge') and browser profile.",
             ["url": ["type": "string"], "browser": ["type": "string"], "profile": ["type": "string"]], required: ["url"]),
        tool("browser_profiles",
             "List the profiles of a Chromium browser (Edge, Chrome, Brave): directory, name, account email.",
             ["browser": ["type": "string"]], required: ["browser"]),
        tool("remember",
             "Save a short fact in the user's personal memory (Italian), e.g. «profilo aula IB» = Edge, profilo «Aulab». Use when the user says «ricorda che…» or when you learn a stable preference or alias.",
             ["fact": ["type": "string"]], required: ["fact"]),
        tool("forget",
             "Remove facts from the personal memory that contain this text («dimentica…»).",
             ["text": ["type": "string"]], required: ["text"]),
        tool("save_macro",
             "Create or replace a voice macro: when the user says its name, each step is run in order. Steps are short Italian commands like «apri Slack», «apri youtube.com», «vai su Mail».",
             ["name": ["type": "string"], "steps": ["type": "array", "items": ["type": "string"]]], required: ["name", "steps"]),
        tool("delete_macro",
             "Delete a voice macro by name.",
             ["name": ["type": "string"]], required: ["name"]),
        tool("wait",
             "Wait for something slow (a download, an animation). Actions already wait for the interface to settle and for pages to load: use this only when the outcome says something is still in progress. Max 5 seconds.",
             ["seconds": ["type": "number"]], required: ["seconds"]),
        tool("get_text",
             "Read the focused text field: selected text and the text before the caret (last 600 characters).",
             [:]),
        tool("edit_text",
             "Edit the focused text field. mode 'replace_selection': replace the selected text with `text`. mode 'rewrite_before_cursor': `text` is the full new version of the text before the caret as returned by get_text; only the changed part is retyped.",
             ["mode": ["type": "string", "enum": ["replace_selection", "rewrite_before_cursor"]],
              "text": ["type": "string"]], required: ["mode", "text"]),
        tool("ask_user",
             "Ask the user a short question (spoken answer) when the request is ambiguous. Returns their answer.",
             ["question": ["type": "string", "description": "Short Italian question."]], required: ["question"]),
        tool("confirm",
             "Ask the user to confirm an action that sends, deletes, buys, publishes or closes something. REQUIRED before such actions: the app blocks them otherwise. Returns 'approved' or 'denied'.",
             ["action": ["type": "string", "description": "Short Italian description, e.g. «Invio la mail a Marco?»"]], required: ["action"]),
    ]

    private static func tool(_ name: String, _ description: String, _ properties: [String: Any],
                             required: [String] = []) -> [String: Any] {
        var schema: [String: Any] = ["type": "object", "properties": properties]
        if !required.isEmpty { schema["required"] = required }
        return ["name": name, "description": description, "inputSchema": schema]
    }

    // MARK: Dispatch

    struct Result {
        var content: [[String: Any]]
        var isError = false
        /// The tool changed nothing (a menu listing): no outcome to report.
        var readOnly = false

        static func text(_ s: String) -> Result { Result(content: [["type": "text", "text": s]]) }
        static func error(_ s: String) -> Result { Result(content: [["type": "text", "text": s]], isError: true) }
        var text: String { content.compactMap { $0["text"] as? String }.joined(separator: "\n") }
    }

    /// An error for the agent, thrown from deep inside a tool.
    struct ToolError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    func call(_ name: String, _ args: [String: Any]) async -> Result {
        if cancelled { return .error("The user cancelled the task. Stop now.") }
        callCount += 1
        if firstCallAt == nil { firstCallAt = Date() }
        if callCount > maxCalls { return .error("Step limit reached. Stop and tell the user what is left to do.") }
        Log.debug("Agente → \(name) \(Self.compact(args))")
        var result = await perform(name, args)
        if reportOutcome, Self.outcomeTools.contains(name), !result.readOnly, !cancelled,
           !result.text.hasPrefix("MacTalkAct does not have"), !result.text.hasPrefix("The frontmost app changed") {
            await settle()
            result.content.append(["type": "text", "text": outcome()])
        }
        let summary = (result.content.first?["text"] as? String).map { String($0.prefix(160)) } ?? "(immagine)"
        Log.debug("Agente ← \(name)\(result.isError ? " ERRORE" : ""): \(summary.replacingOccurrences(of: "\n", with: " ⏎ "))")
        return result
    }

    /// The safety checks and the tool itself, without the outcome (`act` runs its steps here).
    private func perform(_ name: String, _ args: [String: Any]) async -> Result {
        if Self.actingTools.contains(name), !AXIsProcessTrusted() {
            // Without the Accessibility permission macOS drops synthetic keys and clicks
            // silently: say so instead of reporting an action that never happened.
            Log.info("Agente: azione bloccata, manca il permesso di Accessibilità")
            return .error("MacTalkAct does not have the Accessibility permission, so keys and clicks are ignored by macOS. Stop and tell the user to enable MacTalkAct in System Settings › Privacy & Security › Accessibility.")
        }
        if Self.actingTools.contains(name), let problem = frontmostChanged() {
            Log.info("Agente: azione bloccata, app in primo piano cambiata")
            return .error(problem)
        }
        if Self.effectfulTools.contains(name) {
            effectfulCalls += 1
            if firstEffectAt == nil { firstEffectAt = Date() }
        }
        do {
            return try await dispatch(name, args)
        } catch {
            return .error(error.localizedDescription)
        }
    }

    private func dispatch(_ name: String, _ a: [String: Any]) async throws -> Result {
        switch name {
        case "observe":
            let query = (a["query"] as? String)?.trimmingCharacters(in: .whitespaces)
            onProgress?(query.map { "Cerco «\($0)»…" } ?? "Guardo lo schermo…")
            return .text(observe(query: query?.isEmpty == true ? nil : query))

        case "screenshot":
            return try await screenshot(a)

        case "click":
            return try await click(a)

        case "click_many":
            let ids = ((a["ids"] as? [Any]) ?? []).compactMap { Self.int($0) }
            guard !ids.isEmpty else { return .error("Missing ids") }
            let method = (a["method"] as? String) ?? "auto"
            onProgress?("Clicco \(ids.count) elementi…")
            var lines: [String] = []
            for id in ids {
                if cancelled { lines.append("[\(id)] not done: cancelled"); break }
                let r: Result
                do { r = try await click(["id": id, "method": method], quiet: true) } catch { r = .error(error.localizedDescription) }
                var line = r.isError ? "[\(id)] ERROR: \(r.text)" : "[\(id)] «\(registry[id]?.label ?? "")» ok"
                if !r.isError, let el = registry[id]?.element {
                    try? await Task.sleep(for: .milliseconds(120))
                    if let state = Self.toggleState(el) { line += ", now \(state)" }
                }
                lines.append(line)
            }
            return .text(lines.joined(separator: "\n"))

        case "replace_text":
            guard let find = a["find"] as? String, let replace = a["replace"] as? String, !find.isEmpty else {
                return .error("Missing find/replace")
            }
            onProgress?("Sostituisco il testo…")
            let r = await executor.replaceText(find: find, with: replace)
            switch r {
            case .done(let how):
                changes.append("«\(Self.short(find))» → «\(Self.short(replace))»")
                return .text("Replaced and verified (\(how)).")
            case .notFound(let seen):
                return .error("«\(Self.short(find, max: 60))» not found in the focused field\(seen.isEmpty ? "" : " (it contains: «\(Self.short(seen, max: 200))»)"). Click into the right field or cell, or check the exact text.")
            case .unverified(let how):
                return .error("Typed the replacement (\(how)) but could not verify it: take a screenshot to check.")
            case .noField:
                return .error("No text field is focused: click into the field or cell first.")
            }

        case "type_text":
            guard let text = a["text"] as? String else { return .error("Missing text") }
            var target: (element: AXUIElement, label: String, role: String)?
            if let id = Self.int(a["id"]) {
                let item = try resolve(id)
                target = item
                if AXUIElementSetAttributeValue(item.element, kAXFocusedAttribute as CFString, kCFBooleanTrue) != .success,
                   let f = AX.frame(item.element) {
                    await executor.mouseClick(at: CGPoint(x: f.midX, y: f.midY))
                }
                try await Task.sleep(for: .milliseconds(150))
            }
            onProgress?("Scrivo…")
            await executor.typeText(text)
            changes.append("typed «\(Self.short(text))»")
            // Check the field when it exposes its value: pasting into an unfocused web field fails silently.
            if let id = Self.int(a["id"]), let item = target, !text.isEmpty,
               ["AXTextField", "AXTextArea", "AXSearchField", "AXComboBox"].contains(item.role) {
                let want = Grammar.normalize(String(text.prefix(30)))
                var value = AX.string(item.element, kAXValueAttribute)
                for _ in 0..<3 where value.map({ !Grammar.normalize($0).contains(want) }) ?? false {
                    try await Task.sleep(for: .milliseconds(200)) // web fields update their value a moment later
                    value = AX.string(item.element, kAXValueAttribute)
                }
                if let value, !Grammar.normalize(value).contains(want) {
                    return .error("Typed \(text.count) characters, but the field [\(id)] does not show them: click into the field (method 'mouse') and type again.")
                }
            }
            return .text("Typed \(text.count) characters.")

        case "set_value":
            return try await setValue(a)

        case "select_text":
            return try await selectText(a)

        case "perform_action":
            return try await performAction(a)

        case "drag":
            return try await drag(a)

        case "hover":
            let (point, label) = try target(a)
            onProgress?("Passo sopra «\(label)»")
            await executor.moveMouse(to: point)
            try await Task.sleep(for: .milliseconds(300))
            return .text("The mouse is over «\(label)» and stays there.")

        case "menu":
            return try await menu(a)

        case "act":
            return await act(a)

        case "press_keys":
            guard let keys = a["keys"] as? String else { return .error("Missing keys") }
            if Safety.isRiskyKeys(keys), !confirmed {
                return .error("«\(keys)» can close or delete things: call confirm first.")
            }
            onProgress?("Premo \(keys)")
            try await executor.pressSequence(keys)
            try await Task.sleep(for: .milliseconds(250))
            return .text("Pressed \(keys).")

        case "scroll":
            let direction = (a["direction"] as? String) ?? "down"
            let amount = Self.int(a["amount"]) ?? 1
            var point: CGPoint?
            if let id = Self.int(a["id"]), let f = AX.frame(try resolve(id).element) {
                point = CGPoint(x: f.midX, y: f.midY)
            }
            onProgress?(direction == "up" ? "Scorro su" : "Scorro giù")
            await executor.scroll(direction, amount: amount, at: point)
            lastShot = nil // x/y from the old screenshot no longer match the screen
            try await Task.sleep(for: .milliseconds(250))
            return .text("Scrolled \(direction) \(amount). Element ids still work; x/y coordinates need a new screenshot.")

        case "open_app":
            guard let name = a["name"] as? String else { return .error("Missing name") }
            if let profileName = a["profile"] as? String, !profileName.isEmpty {
                return try await openProfile(browser: name, profile: profileName, url: nil)
            }
            onProgress?("Apro \(name)")
            let opened = try await executor.openApp(name)
            try await Task.sleep(for: .milliseconds(500))
            let front = AX.frontmostApplication()?.localizedName ?? "?"
            if Grammar.normalize(front) == Grammar.normalize(opened) {
                targetPID = AX.realFrontmostApplication()?.processIdentifier
                return .text("\(opened) is now frontmost.")
            }
            return .error("\(opened) was opened but the frontmost app is still \(front).")

        case "open_url":
            guard let url = a["url"] as? String else { return .error("Missing url") }
            if let profileName = a["profile"] as? String, !profileName.isEmpty {
                return try await openProfile(browser: (a["browser"] as? String) ?? "Microsoft Edge", profile: profileName, url: url)
            }
            onProgress?("Apro \(url)")
            try await executor.openURL(url, in: a["browser"] as? String)
            try await Task.sleep(for: .milliseconds(1200))
            targetPID = AX.realFrontmostApplication()?.processIdentifier
            return .text("Opened \(url).")

        case "browser_profiles":
            let browser = (a["browser"] as? String) ?? "Microsoft Edge"
            let profiles = BrowserProfiles.list(browser: browser)
            guard !profiles.isEmpty else {
                return .error("macOS does not let the app read \(browser)'s profile list. Open the browser and use its profile menu (observe/click), then remember which profile the user meant.")
            }
            return .text(profiles.map { "\($0.directory): «\($0.name)»\($0.email.isEmpty ? "" : " <\($0.email)>")" }
                .joined(separator: "\n"))

        case "remember":
            guard let fact = a["fact"] as? String else { return .error("Missing fact") }
            Memory.shared.remember(fact)
            onProgress?("Ricordo: \(fact)")
            return .text("Saved.")

        case "forget":
            guard let text = a["text"] as? String else { return .error("Missing text") }
            let n = Memory.shared.forget(text)
            return .text(n > 0 ? "Removed \(n) fact(s)." : "Nothing matched.")

        case "save_macro":
            guard let name = a["name"] as? String, let steps = a["steps"] as? [String], !steps.isEmpty else {
                return .error("Missing name/steps")
            }
            Memory.shared.saveMacro(name: name, steps: steps)
            onProgress?("Macro «\(name)» salvata")
            return .text("Macro saved. The user can now say «\(name)».")

        case "delete_macro":
            guard let name = a["name"] as? String else { return .error("Missing name") }
            return .text(Memory.shared.deleteMacro(name) ? "Deleted." : "No macro with that name.")

        case "wait":
            let seconds = min(max((a["seconds"] as? Double) ?? Double(Self.int(a["seconds"]) ?? 1), 0.1), 5)
            try await Task.sleep(for: .seconds(seconds))
            return .text("Waited \(seconds) s.")

        case "get_text":
            let ctx = ScreenContext.capture(includeLabels: false)
            guard ctx.isEditable else { return .error("No editable text field is focused.") }
            return .text("SELECTED_TEXT: <<<\(ctx.selectedText)>>>\nTEXT_BEFORE_CURSOR: <<<\(ctx.textBeforeCursor)>>>")

        case "edit_text":
            guard let text = a["text"] as? String, let mode = a["mode"] as? String else { return .error("Missing mode/text") }
            onProgress?("Modifico il testo…")
            let before = ScreenContext.capture(includeLabels: false)
            if mode == "replace_selection" {
                await executor.typeText(text)
                changes.append("«\(Self.short(before.selectedText))» → «\(Self.short(text))»")
            } else {
                try await executor.rewriteBeforeCursor(new: text)
                changes.append("«\(Self.short(String(before.textBeforeCursor.suffix(160))))» → «\(Self.short(String(text.suffix(160))))»")
            }
            return .text("Text edited.")

        case "ask_user":
            guard let q = a["question"] as? String else { return .error("Missing question") }
            // A bare «sì»/«no» does not answer an open question: ask once more (FR-9).
            var answer = await askUser?(q, false)
            if let a = answer, Self.isEmptyAnswer(a) {
                answer = await askUser?("Mi serve la risposta precisa: \(q)", false)
            }
            guard let answer, !answer.isEmpty, !Self.isEmptyAnswer(answer) else {
                return .text("No usable answer from the user. Do not guess: stop without acting and say you need the missing detail.")
            }
            return .text("User answered: \(answer)")

        case "confirm":
            guard let action = a["action"] as? String else { return .error("Missing action") }
            let answer = await askUser?(action, true)
            if let answer, Grammar.isYes(answer) {
                confirmedUntil = Date().addingTimeInterval(AppSettings.shared.confirmValiditySeconds)
                return .text("approved")
            }
            return .text("denied — do not perform the action. Tell the user it was cancelled.")

        default:
            return .error("Unknown tool \(name)")
        }
    }

    private var confirmed: Bool { Date() < confirmedUntil }

    // MARK: Elements

    /// The id of an element: the same as before if it was already seen in this request (FR-36).
    private func id(for element: AXUIElement, label: String, role: String) -> Int {
        let h = CFHash(element)
        if let hit = known[h]?.first(where: { CFEqual($0.element, element) }) {
            registry[hit.id] = (element, label, role)
            return hit.id
        }
        let id = nextID
        nextID += 1
        known[h, default: []].append((element, id))
        registry[id] = (element, label, role)
        return id
    }

    /// The element behind an id, if it still exists.
    private func resolve(_ id: Int) throws -> (element: AXUIElement, label: String, role: String) {
        guard let item = registry[id] else {
            throw ToolError(message: "Unknown id \(id): observe or screenshot first.")
        }
        var role: CFTypeRef?
        if AXUIElementCopyAttributeValue(item.element, kAXRoleAttribute as CFString, &role) == .invalidUIElement {
            throw ToolError(message: "Element [\(id)] «\(item.label)» no longer exists (the screen changed): observe again.")
        }
        return item
    }

    /// A point on screen from `id` or `x`/`y` (latest screenshot), with a label for messages.
    private func target(_ a: [String: Any], id idKey: String = "id", x xKey: String = "x", y yKey: String = "y") throws -> (CGPoint, String) {
        if let id = Self.int(a[idKey]) {
            let item = try resolve(id)
            guard let f = AX.frame(item.element) else { throw ToolError(message: "Element [\(id)] has no position: try a screenshot.") }
            return (CGPoint(x: f.midX, y: f.midY), item.label)
        }
        if let x = Self.double(a[xKey]), let y = Self.double(a[yKey]) {
            guard let shot = lastShot else { throw ToolError(message: "x/y need a screenshot first.") }
            return (shot.screenPoint(imageX: x, imageY: y), "\(Int(x)),\(Int(y))")
        }
        throw ToolError(message: "Pass \(idKey) or \(xKey)/\(yKey).")
    }

    /// Checked/unchecked state of checkboxes, radios and switches after an action.
    private static func toggleState(_ element: AXUIElement) -> String? {
        let role = AX.role(element)
        guard ["AXCheckBox", "AXRadioButton", "AXSwitch", "AXToggle", "AXCell", "AXRow", "AXMenuItem"].contains(role) else { return nil }
        if ["AXCheckBox", "AXRadioButton", "AXSwitch", "AXToggle"].contains(role),
           let n = AX.value(element, kAXValueAttribute) as? NSNumber {
            return n.intValue == 0 ? "unchecked" : "checked"
        }
        // Web tables: the checkbox is often inside the clicked cell or row.
        var queue = AX.children(element)
        var visited = 0
        while !queue.isEmpty, visited < 40 {
            let child = queue.removeFirst()
            visited += 1
            if ["AXCheckBox", "AXRadioButton"].contains(AX.role(child)),
               let n = AX.value(child, kAXValueAttribute) as? NSNumber {
                return "contains a checkbox now " + (n.intValue == 0 ? "unchecked" : "checked")
            }
            queue += AX.children(child)
        }
        if role == "AXCell" || role == "AXRow" { return "this is a table \(role == "AXCell" ? "cell" : "row"), not a checkbox" }
        if let b = AX.value(element, kAXSelectedAttribute) as? Bool { return b ? "selected" : "not selected" }
        return nil
    }

    private func openProfile(browser: String, profile: String, url: String?) async throws -> Result {
        guard let appURL = executor.findApp(browser) else { return .error("Browser «\(browser)» not found.") }
        guard let p = BrowserProfiles.find(browser: browser, spoken: profile) else {
            let all = BrowserProfiles.list(browser: browser)
            if all.isEmpty {
                // Profile list unreadable: open the browser so the agent can use its profile menu.
                _ = try await executor.openApp(browser)
                return .error("\(browser) is open, but its profile list is not readable. Switch to profile «\(profile)» with the browser's profile menu (observe/click; in Edge it is the profile picture at the top left), then remember how you did it.")
            }
            let names = all.map { "«\($0.name)»" }.joined(separator: ", ")
            return .error("No profile matches «\(profile)». Profiles: \(names)")
        }
        onProgress?("Apro \(browser), profilo «\(p.name)»")
        try BrowserProfiles.open(appURL: appURL, profile: p, url: url)
        try await Task.sleep(for: .milliseconds(1200))
        if let app = NSRunningApplication.runningApplications(withBundleIdentifier: Bundle(url: appURL)?.bundleIdentifier ?? "").first {
            await executor.bringToFront(app)
            targetPID = app.processIdentifier
        }
        return .text("Opened a \(browser) window with profile «\(p.name)» (\(p.directory)).")
    }

    // MARK: Observe

    /// What the agent saw: header and one line per element, in reading order.
    private struct View {
        var app = ""
        var title = ""
        var focus = ""
        var selection = ""
        var header: [String] = []
        var items: [(id: Int, line: String)] = []
        var truncated = false
    }

    private static let attrs = [
        kAXRoleAttribute, kAXTitleAttribute, kAXDescriptionAttribute, kAXValueAttribute,
        kAXChildrenAttribute, kAXPositionAttribute, kAXSizeAttribute, kAXFocusedAttribute,
    ] as [String]

    private static let clickableRoles: Set<String> = [
        "AXButton", "AXLink", "AXMenuItem", "AXMenuButton", "AXPopUpButton", "AXCheckBox", "AXRadioButton",
        "AXTab", "AXCell", "AXRow", "AXDisclosureTriangle", "AXComboBox", "AXMenuBarItem", "AXSwitch",
        "AXToggle", "AXTextField", "AXTextArea", "AXSearchField", "AXSlider", "AXIncrementor",
        "AXDateField", "AXTimeField", "AXColorWell", "AXStepper",
    ]
    private static let textRoles: Set<String> = ["AXStaticText", "AXHeading", "AXImage"]
    private static let textInputRoles: Set<String> = ["AXTextField", "AXTextArea", "AXSearchField"]
    /// Roles whose value is a number or a choice worth showing (`value=`) and maybe settable.
    private static let valueRoles: Set<String> = [
        "AXSlider", "AXIncrementor", "AXStepper", "AXLevelIndicator", "AXProgressIndicator", "AXValueIndicator",
        "AXPopUpButton", "AXComboBox", "AXDateField", "AXTimeField",
    ]
    /// Actions every element has, not worth listing.
    private static let commonActions: Set<String> = [
        "AXPress", "AXShowMenu", "AXScrollToVisible", "AXShowDefaultUI", "AXShowAlternateUI", "AXRaise", "AXZoomWindow",
    ]

    /// The elements of the window for the request itself, like the initial state Codex sends with
    /// every app: the engine can act at once instead of calling observe first.
    func initialObservation() -> String {
        let view = scan(query: nil)
        lastView = view
        generation += 1
        return render(view, query: nil)
    }

    private func observe(query: String?) -> String {
        generation += 1
        let view = scan(query: query)
        if query == nil { lastView = view }
        return render(view, query: query)
    }

    private func render(_ view: View, query: String?) -> String {
        var lines = view.header + view.items.map(\.line)
        if view.items.isEmpty, view.header.count >= 3 {
            lines.append(query != nil ? "Nothing matches «\(query!)». Try other words, scroll, or take a screenshot."
                                      : "No readable elements (the app may not support Accessibility): take a screenshot.")
        } else if view.truncated {
            lines.append(query != nil ? "(search stopped early: results may be incomplete)"
                                      : "(list truncated: use observe with a query to find something specific, or a screenshot)")
        }
        return lines.joined(separator: "\n")
    }

    private func scan(query: String?) -> View {
        var view = View()
        guard let (app, running) = AX.frontApp() else {
            view.header = ["No frontmost application."]
            return view
        }
        let window = AX.focusedWindow(in: app)
        let ctx = ScreenContext.capture(includeLabels: false)
        let windowFrame = window.flatMap { AX.frame($0) }
        view.app = running.localizedName ?? ""
        view.title = ctx.windowTitle
        view.focus = Self.describeFocus(in: app)
        view.selection = AX.focusedElement(in: app).flatMap { AX.string($0, kAXSelectedTextAttribute) }
            .map { AX.collapse($0, max: 60) } ?? ""
        view.header = [
            "APP: \(running.localizedName ?? "") (\(running.bundleIdentifier ?? ""))",
            "WINDOW: \(ctx.windowTitle)" + (windowFrame.map { " size \(Int($0.width))x\(Int($0.height))" } ?? ""),
            "FOCUSED: \(ctx.focusedRole.isEmpty ? "none" : ctx.focusedRole)\(ctx.isEditable ? " (editable)" : "")",
        ]
        guard let root = window else {
            view.header.append("This app has no open window in front.")
            return view
        }

        let needle = query.map { Grammar.normalize($0) }
        let maxItems = needle == nil ? 220 : 60
        let deadline: TimeInterval = needle == nil ? 1.8 : 4.0
        let maxNodes = needle == nil ? 12_000 : 40_000
        let start = Date()
        // Third value: inside a web page (AXWebArea), as opposed to the browser's own toolbars and sidebars.
        var queue: [(AXUIElement, Int, Bool)] = [(root, 0, false)]
        var index = 0
        var lastLabel = ""
        // The same element can be reachable from two parents (web tables in Safari): visit it once.
        var seen: [CFHashCode: [AXUIElement]] = [:]
        var webArea: AXUIElement?

        while index < queue.count {
            if view.items.count >= maxItems || index >= maxNodes || Date().timeIntervalSince(start) > deadline {
                view.truncated = true
                break
            }
            let (el, depth, inWeb) = queue[index]
            index += 1
            let h = CFHash(el)
            if seen[h]?.contains(where: { CFEqual($0, el) }) == true { continue }
            seen[h, default: []].append(el)
            let v = AX.multi(el, Self.attrs)
            let role = (v[0] as? String) ?? ""
            let frame = AX.rect(position: v[5], size: v[6])
            if role == "AXWebArea", webArea == nil { webArea = el }

            // Skip whole subtrees scrolled out of the window (a search looks everywhere:
            // web elements can be pressed even when scrolled out of view).
            if needle == nil, let wf = windowFrame, let f = frame, f.width > 0, f.height > 0,
               !wf.insetBy(dx: -4, dy: -4).intersects(f) {
                continue
            }

            let title = (v[1] as? String) ?? ""
            let desc = (v[2] as? String) ?? ""
            let value = (v[3] as? String) ?? ""
            let focused = (v[7] as? Bool) ?? false
            let clickable = Self.clickableRoles.contains(role)
            var label = [title, desc].first { !$0.trimmingCharacters(in: .whitespaces).isEmpty } ?? ""
            if label.isEmpty, !value.isEmpty, !Self.textInputRoles.contains(role), !Self.valueRoles.contains(role) {
                label = value
            }
            label = AX.collapse(label, max: 100)

            let interesting = (clickable || Self.textRoles.contains(role)) && !label.isEmpty
                || Self.textInputRoles.contains(role)
                || (Self.valueRoles.contains(role) && v[3] != nil)
            if interesting, label != lastLabel || clickable {
                let matches = needle.map { Grammar.normalize(label).contains($0) } ?? true
                if matches {
                    let id = id(for: el, label: label.isEmpty ? role : label, role: role)
                    lastLabel = label
                    var line = "[\(id)]\(clickable ? "*" : "") \(role.replacingOccurrences(of: "AX", with: "").lowercased())"
                    if !label.isEmpty { line += " «\(label)»" }
                    if Self.textInputRoles.contains(role), !value.isEmpty {
                        line += " value=«\(AX.collapse(value, max: 60))»"
                    }
                    if Self.valueRoles.contains(role) {
                        if let n = v[3] as? NSNumber { line += " value=\(n)" }
                        else if !value.isEmpty { line += " value=«\(AX.collapse(value, max: 40))»" }
                        if AX.isSettable(el, kAXValueAttribute) { line += " settable" }
                    }
                    if ["AXCheckBox", "AXRadioButton", "AXSwitch"].contains(role), let on = v[3] as? NSNumber {
                        line += on.intValue == 0 ? " (unchecked)" : " (checked)"
                    }
                    if clickable {
                        let extra = AX.actions(el).filter { !Self.commonActions.contains($0) }.map(Self.actionName)
                        if !extra.isEmpty { line += " actions=\(extra.prefix(5).joined(separator: ","))" }
                    }
                    if focused { line += " (focused)" }
                    if inWeb { line += " (page)" }
                    if let f = frame, let wf = windowFrame {
                        line += " @\(Int(f.minX - wf.minX)),\(Int(f.minY - wf.minY)) \(Int(f.width))x\(Int(f.height))"
                    }
                    view.items.append((id, line))
                }
            }
            if depth < 60, let children = v[4] as? [AXUIElement] {
                let childrenInWeb = inWeb || role == "AXWebArea"
                for c in children { queue.append((c, depth + 1, childrenInWeb)) }
            }
        }
        if let webArea { lastWebArea = webArea }
        return view
    }

    /// «textfield «Nome»», «webarea», «none»: the focused element in a few words.
    private static func describeFocus(in app: AXUIElement) -> String {
        guard let f = AX.focusedElement(in: app) else { return "" }
        let role = AX.role(f).replacingOccurrences(of: "AX", with: "").lowercased()
        let label = [AX.string(f, kAXTitleAttribute), AX.string(f, kAXDescriptionAttribute)]
            .compactMap { $0 }.first { !$0.trimmingCharacters(in: .whitespaces).isEmpty } ?? ""
        return label.isEmpty ? role : "\(role) «\(AX.collapse(label, max: 50))»"
    }

    /// "AXIncrement" → "Increment"; custom actions "Name:Archive\nTarget:…" → "Archive".
    static func actionName(_ raw: String) -> String {
        if raw.hasPrefix("Name:") {
            return String(raw.dropFirst(5).prefix { $0 != "\n" })
        }
        return raw.hasPrefix("AX") ? String(raw.dropFirst(2)) : raw
    }

    // MARK: Outcome (AD-19)

    /// A cheap fingerprint of the window: app, title, focus, size of the web page, sheets.
    private func signature() -> String {
        guard let (app, running) = AX.frontApp() else { return "" }
        let window = AX.focusedWindow(in: app)
        let title = window.flatMap { AX.string($0, kAXTitleAttribute) } ?? ""
        let sheets = window.map { AX.children($0).filter { AX.role($0) == "AXSheet" }.count } ?? 0
        var focus = ""
        if let f = AX.focusedElement(in: app) {
            focus = "\(CFHash(f))|\((AX.string(f, kAXValueAttribute) ?? "").count)"
        }
        let web = lastWebArea.map { "\(AX.children($0).count)" } ?? ""
        return "\(running.processIdentifier)|\(title)|\(sheets)|\(focus)|\(web)"
    }

    private func pageLoading() -> Bool {
        guard let web = lastWebArea, let p = AX.value(web, "AXLoadingProgress") as? Double else { return false }
        return p < 1
    }

    /// Waits until the interface stops changing: the same fingerprint twice 150 ms apart and no page
    /// loading. At most 3 s, 6 s while a page loads (like the computer use of Codex).
    private func settle() async {
        let start = Date()
        var deadline = start.addingTimeInterval(3)
        var previous = signature()
        while Date() < deadline, !cancelled {
            try? await Task.sleep(for: .milliseconds(150))
            let now = signature()
            let loading = pageLoading()
            if loading { deadline = min(start.addingTimeInterval(6), max(deadline, Date().addingTimeInterval(1))) }
            if now == previous, !loading { return }
            previous = now
        }
    }

    /// The line without what moves by itself (position, focus mark): changes worth reporting.
    private static func key(_ line: String) -> String {
        var s = line
        if let r = s.range(of: #" @-?\d+,-?\d+ \d+x\d+$"#, options: .regularExpression) { s.removeSubrange(r) }
        return s.replacingOccurrences(of: " (focused)", with: "")
    }

    /// What changed since the last view, then the new view becomes the reference.
    private func outcome() -> String {
        let before = lastView
        let now = scan(query: nil)
        lastView = now
        guard let before else {
            return "NOW: app \(now.app) · window «\(now.title)» · focus \(now.focus.isEmpty ? "none" : now.focus). Observe to see the elements."
        }
        var head: [String] = []
        if now.app != before.app { head.append("app is now \(now.app)") }
        if now.title != before.title { head.append("window «\(now.title)» (was «\(before.title)»)") }
        if now.focus != before.focus { head.append("focus: \(now.focus.isEmpty ? "none" : now.focus)") }
        if now.selection != before.selection {
            head.append(now.selection.isEmpty ? "nothing selected" : "selected «\(now.selection)»")
        }

        let old = Dictionary(before.items.map { ($0.id, Self.key($0.line)) }, uniquingKeysWith: { a, _ in a })
        let newIDs = Set(now.items.map(\.id))
        var added: [String] = [], changed: [String] = [], removed: [String] = []
        for item in now.items {
            if let was = old[item.id] {
                if was != Self.key(item.line) { changed.append("~ " + item.line) }
            } else {
                added.append("+ " + item.line)
            }
        }
        for item in before.items where !newIDs.contains(item.id) { removed.append("- " + Self.key(item.line)) }

        if head.isEmpty, added.isEmpty, changed.isEmpty, removed.isEmpty {
            return "RESULT: nothing changed on screen (same window, focus and elements). If you expected a change, the action did not work: try another way."
        }
        var out = "RESULT: " + (head.isEmpty ? "window «\(now.title)»" : head.joined(separator: " · "))
        out += String(format: " · elements +%d −%d ~%d", added.count, removed.count, changed.count)
        if added.count + removed.count > 40 {
            // A new screen: the start of the new view is more useful than a long diff.
            out += "\nThe screen changed a lot. First elements now:\n"
                + now.items.prefix(20).map(\.line).joined(separator: "\n")
            if now.items.count > 20 { out += "\n(… observe for the rest)" }
            return out
        }
        let lines = changed + added + removed
        out += "\n" + lines.prefix(25).joined(separator: "\n")
        if lines.count > 25 { out += "\n(… \(lines.count - 25) more: observe for the full list)" }
        return out
    }

    // MARK: Screenshot

    private func screenshot(_ a: [String: Any]) async throws -> Result {
        onProgress?("Guardo la finestra…")
        guard ScreenCapture.hasPermission else {
            ScreenCapture.requestPermission()
            return .error("Screen Recording permission not granted. Use observe instead.")
        }
        if let region = (a["region"] as? [Any])?.compactMap(Self.double), region.count == 4 {
            return try await zoom(region)
        }
        let shot = try await ScreenCapture.frontWindow()
        lastShot = shot
        // Number every clickable element on the image (set-of-marks), with the same ids as observe.
        var marks: [(Int, CGRect)] = []
        var legend: [String] = []
        if let (app, _) = AX.frontApp(), let window = AX.focusedWindow(in: app), let wf = AX.frame(window) {
            generation += 1
            for c in AXTree.clickables(in: window, windowFrame: wf, limit: 150) {
                let id = id(for: c.element, label: c.label.isEmpty ? c.role : c.label, role: c.role)
                marks.append((id, c.frame))
                if !c.label.isEmpty {
                    legend.append("[\(id)] \(c.role.replacingOccurrences(of: "AX", with: "").lowercased()) «\(c.label)»")
                }
            }
        }
        guard let jpeg = shot.jpeg(marks: marks) else { throw CaptureError.encoding }
        var note = "Screenshot \(Int(shot.imageSize.width))x\(Int(shot.imageSize.height)) px of the frontmost window."
        note += marks.isEmpty
            ? " Use pixel coordinates with click x/y."
            : " Orange tags are element ids for click(id) and the other tools (same ids as observe); x/y also work for untagged spots."
        if !legend.isEmpty { note += "\nLabelled tags: " + legend.joined(separator: ", ") }
        return Result(content: [
            ["type": "image", "data": jpeg.base64EncodedString(), "mimeType": "image/jpeg"],
            ["type": "text", "text": note],
        ])
    }

    /// A region of the latest screenshot at full (Retina) resolution, like Claude's `zoom`.
    private func zoom(_ r: [Double]) async throws -> Result {
        guard let shot = lastShot else { return .error("region needs a screenshot first: take one, then zoom into its coordinates.") }
        let p0 = shot.screenPoint(imageX: min(r[0], r[2]), imageY: min(r[1], r[3]))
        let p1 = shot.screenPoint(imageX: max(r[0], r[2]), imageY: max(r[1], r[3]))
        let scale = NSScreen.main?.backingScaleFactor ?? 2
        let full = try await ScreenCapture.frontWindow(maxSide: 8000, scaleFactor: scale)
        let sx = CGFloat(full.image.width) / full.windowFrame.width
        let sy = CGFloat(full.image.height) / full.windowFrame.height
        let crop = CGRect(x: (p0.x - full.windowFrame.minX) * sx, y: (p0.y - full.windowFrame.minY) * sy,
                          width: (p1.x - p0.x) * sx, height: (p1.y - p0.y) * sy)
        guard let (jpeg, size) = ScreenCapture.zoomJPEG(full.image, crop: crop) else {
            return .error("The region is empty or outside the window: use coordinates of the latest screenshot.")
        }
        return Result(content: [
            ["type": "image", "data": jpeg.base64EncodedString(), "mimeType": "image/jpeg"],
            ["type": "text", "text": "Zoom of \(r.map { String(Int($0)) }.joined(separator: ",")) at full resolution (\(Int(size.width))x\(Int(size.height)) px). For click x/y keep using the coordinates of the full screenshot."],
        ])
    }

    // MARK: Click

    private func click(_ a: [String: Any], quiet: Bool = false) async throws -> Result {
        var method = (a["method"] as? String) ?? "auto"
        let count = min(3, max(1, Self.int(a["count"]) ?? (method == "double" ? 2 : 1)))
        let flags = KeyCombo.modifiers([(a["modifiers"] as? String) ?? ""] + ((a["modifiers"] as? [String]) ?? []))
        // Modifiers and multiple clicks need the real mouse.
        if method == "auto", !flags.isEmpty || count > 1 { method = "mouse" }
        var point: CGPoint?
        var label = ""

        if let id = Self.int(a["id"]) {
            let item = try resolve(id)
            label = item.label
            if Safety.isRiskyLabel(label), !confirmed {
                return .error("Clicking «\(label)» may send or delete something: call confirm first.")
            }
            if !quiet { onProgress?("Clicco «\(label)»") }
            if method == "auto" {
                if AX.press(item.element) {
                    try await Task.sleep(for: .milliseconds(350))
                    return .text("Pressed [\(id)] «\(label)».")
                }
                var current = item.element
                for _ in 0..<6 {
                    guard let parent = AX.element(current, kAXParentAttribute) else { break }
                    if AX.actions(parent).contains(kAXPressAction), AX.press(parent) {
                        try await Task.sleep(for: .milliseconds(350))
                        return .text("Pressed the container of [\(id)] «\(label)».")
                    }
                    current = parent
                }
            }
            // Elements found by a search may be scrolled out of view: bring them in before a real click.
            if let wf = AX.frontApp().flatMap({ AX.focusedWindow(in: $0.0) }).flatMap({ AX.frame($0) }),
               let f0 = AX.frame(item.element), !wf.insetBy(dx: 2, dy: 2).contains(CGPoint(x: f0.midX, y: f0.midY)) {
                AXUIElementPerformAction(item.element, "AXScrollToVisible" as CFString)
                try await Task.sleep(for: .milliseconds(350))
            }
            guard let f = AX.frame(item.element) else { return .error("Element [\(id)] has no position: try a screenshot.") }
            point = CGPoint(x: f.midX, y: f.midY)
        } else if let x = Self.double(a["x"]), let y = Self.double(a["y"]) {
            guard let shot = lastShot else { return .error("x/y need a screenshot first.") }
            point = shot.screenPoint(imageX: x, imageY: y)
            label = "\(Int(x)),\(Int(y))"
            onProgress?("Clicco nel punto indicato")
        } else {
            return .error("Pass id or x/y.")
        }

        guard let p = point else { return .error("Nothing to click.") }
        switch method {
        case "right": await executor.mouseClick(at: p, right: true, flags: flags)
        case "middle": await executor.mouseClick(at: p, middle: true, flags: flags)
        default: await executor.mouseClick(at: p, count: count, flags: flags)
        }
        try await Task.sleep(for: .milliseconds(350))
        let how = method == "right" ? "Right-clicked" : count == 3 ? "Triple-clicked" : count == 2 ? "Double-clicked" : "Clicked"
        return .text("\(how) «\(label)» with the mouse\(flags.isEmpty ? "" : " holding \((a["modifiers"] as? String) ?? "modifiers")").")
    }

    // MARK: New hands (FR-37)

    private func setValue(_ a: [String: Any]) async throws -> Result {
        guard let id = Self.int(a["id"]) else { return .error("Missing id") }
        let raw = (a["value"] as? String) ?? Self.double(a["value"]).map { String($0) } ?? ""
        let item = try resolve(id)
        guard AX.isSettable(item.element, kAXValueAttribute) else {
            return .error("The value of [\(id)] «\(item.label)» cannot be set directly: click it and type, use the arrow keys, or drag.")
        }
        onProgress?("Imposto «\(item.label)» a \(raw)")
        let current = AX.value(item.element, kAXValueAttribute)
        let newValue: CFTypeRef
        if current is NSNumber || Self.valueRoles.contains(item.role) && item.role != "AXPopUpButton" && item.role != "AXComboBox" {
            guard let n = Double(raw.replacingOccurrences(of: ",", with: ".")) else {
                return .error("[\(id)] «\(item.label)» needs a number.")
            }
            newValue = NSNumber(value: n)
        } else {
            newValue = raw as CFString
        }
        let err = AXUIElementSetAttributeValue(item.element, kAXValueAttribute as CFString, newValue)
        guard err == .success else { return .error("The app refused the value (\(err.rawValue)): click and type, or use the keys.") }
        changes.append("«\(item.label)» = «\(Self.short(raw))»")
        try await Task.sleep(for: .milliseconds(200))
        // Web sliders accept the value but ignore it: step there with Increment/Decrement.
        if let target = (newValue as? NSNumber)?.doubleValue, let start = (AX.value(item.element, kAXValueAttribute) as? NSNumber)?.doubleValue,
           abs(start - target) > 0.001 {
            let actions = AX.actions(item.element)
            if actions.contains("AXIncrement"), actions.contains("AXDecrement") {
                var value = start
                for _ in 0..<500 where abs(value - target) > 0.001 {
                    AXUIElementPerformAction(item.element, (value < target ? "AXIncrement" : "AXDecrement") as CFString)
                    guard let next = (AX.value(item.element, kAXValueAttribute) as? NSNumber)?.doubleValue, next != value else { break }
                    // Overshoot with big steps: stop at the closest value.
                    if (value < target) != (next < target), abs(next - target) > abs(value - target) {
                        AXUIElementPerformAction(item.element, (next < target ? "AXIncrement" : "AXDecrement") as CFString)
                        break
                    }
                    value = next
                }
            }
        }
        let now = AX.value(item.element, kAXValueAttribute)
        let shown = (now as? NSNumber).map { "\($0)" } ?? (now as? String) ?? "?"
        return .text("Set [\(id)] «\(item.label)» to \(raw); it now shows \(shown).")
    }

    private func selectText(_ a: [String: Any]) async throws -> Result {
        guard let text = a["text"] as? String, !text.isEmpty else { return .error("Missing text") }
        let element: AXUIElement
        if let id = Self.int(a["id"]) {
            element = try resolve(id).element
            AXUIElementSetAttributeValue(element, kAXFocusedAttribute as CFString, kCFBooleanTrue)
            try await Task.sleep(for: .milliseconds(120))
        } else {
            guard let app = AX.frontApp()?.app, let f = AX.focusedElement(in: app) else {
                return .error("No field is focused: pass the id of the field.")
            }
            element = f
        }
        guard let value = AX.string(element, kAXValueAttribute) else {
            return .error("This field does not expose its text: click into it and use replace_text, or double/triple-click to select.")
        }
        let ns = value as NSString
        var occurrences: [NSRange] = []
        for options in [NSString.CompareOptions(), [.caseInsensitive, .diacriticInsensitive]] {
            var from = 0
            while from < ns.length {
                let r = ns.range(of: text, options: options, range: NSRange(location: from, length: ns.length - from))
                if r.location == NSNotFound { break }
                occurrences.append(r)
                from = r.location + max(1, r.length)
            }
            if !occurrences.isEmpty { break }
        }
        let prefix = (a["prefix"] as? String) ?? ""
        let suffix = (a["suffix"] as? String) ?? ""
        let fitting = occurrences.filter { r in
            (prefix.isEmpty || ns.substring(to: r.location).hasSuffix(prefix))
                && (suffix.isEmpty || ns.substring(from: r.location + r.length).hasPrefix(suffix))
        }
        guard let r = fitting.first else {
            return .error(occurrences.isEmpty
                ? "«\(Self.short(text, max: 60))» is not in the field (it contains «\(Self.short(value, max: 160))»)."
                : "«\(Self.short(text, max: 60))» appears \(occurrences.count) times, none with that prefix/suffix.")
        }
        var range: CFRange
        switch (a["where"] as? String) ?? "text" {
        case "before": range = CFRange(location: r.location, length: 0)
        case "after": range = CFRange(location: r.location + r.length, length: 0)
        default: range = CFRange(location: r.location, length: r.length)
        }
        guard let axRange = AXValueCreate(.cfRange, &range),
              AXUIElementSetAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, axRange) == .success else {
            return .error("The field does not let me select text: double/triple-click it, or use replace_text.")
        }
        let note = fitting.count > 1 ? " (\(fitting.count) matches: the first one; pass prefix/suffix for another)" : ""
        return .text(range.length > 0 ? "Selected «\(Self.short(text, max: 60))»\(note)." : "Caret placed \(range.location == r.location ? "before" : "after") «\(Self.short(text, max: 60))»\(note).")
    }

    private func performAction(_ a: [String: Any]) async throws -> Result {
        guard let id = Self.int(a["id"]), let wanted = a["action"] as? String else { return .error("Missing id/action") }
        let item = try resolve(id)
        let actions = AX.actions(item.element)
        let w = Grammar.normalize(wanted.hasPrefix("AX") ? String(wanted.dropFirst(2)) : wanted)
        guard let raw = actions.first(where: { Grammar.normalize(Self.actionName($0)) == w }) else {
            return .error("[\(id)] «\(item.label)» has no action «\(wanted)». Its actions: \(actions.map(Self.actionName).joined(separator: ", ")).")
        }
        if Safety.isRiskyLabel(Self.actionName(raw)) || Safety.isRiskyLabel(item.label), !confirmed {
            return .error("«\(Self.actionName(raw))» on «\(item.label)» may send or delete something: call confirm first.")
        }
        onProgress?("\(Self.actionName(raw)) «\(item.label)»")
        let err = AXUIElementPerformAction(item.element, raw as CFString)
        guard err == .success else { return .error("The app refused «\(Self.actionName(raw))» (\(err.rawValue)).") }
        try await Task.sleep(for: .milliseconds(250))
        return .text("Done «\(Self.actionName(raw))» on [\(id)] «\(item.label)».")
    }

    private func drag(_ a: [String: Any]) async throws -> Result {
        let (from, fromLabel) = try target(a, id: "from_id", x: "from_x", y: "from_y")
        let (to, toLabel) = try target(a, id: "to_id", x: "to_x", y: "to_y")
        if Safety.isRiskyLabel(toLabel), !confirmed {
            return .error("Dropping on «\(toLabel)» may delete something: call confirm first.")
        }
        onProgress?("Trascino «\(fromLabel)» su «\(toLabel)»")
        let flags = KeyCombo.modifiers([(a["modifiers"] as? String) ?? ""])
        await executor.drag(from: from, to: to, flags: flags)
        lastShot = nil
        try await Task.sleep(for: .milliseconds(250))
        return .text("Dragged «\(fromLabel)» to «\(toLabel)».")
    }

    private func menu(_ a: [String: Any]) async throws -> Result {
        let path = (a["path"] as? String) ?? ""
        guard let (app, running) = AX.frontApp() else { return .error("No frontmost application.") }
        let name = running.localizedName ?? "app"
        switch AppMenu.resolve(path, in: app) {
        case .noMenuBar:
            return .error("\(name) has no menu bar readable through Accessibility.")
        case .listing(let walked, let items):
            var r = Result.text("Menu \(walked.isEmpty ? "bar of \(name)" : "«\(walked.joined(separator: " > "))»"): \(AppMenu.describe(items))")
            r.readOnly = true
            return r
        case .notFound(let walked, let missing, let items):
            var r = Result.error("No «\(missing)» in \(walked.isEmpty ? "the menu bar of \(name)" : "«\(walked.joined(separator: " > "))»")." + (items.isEmpty ? "" : " Items: \(AppMenu.describe(items))"))
            r.readOnly = true
            return r
        case .item(let walked, let item):
            guard item.enabled else {
                var r = Result.error("«\(walked.joined(separator: " > "))» is disabled right now (select something first, or it does not apply here).")
                r.readOnly = true
                return r
            }
            if Safety.isRiskyLabel(item.title), !confirmed {
                return .error("«\(item.title)» may delete, send or close something: call confirm first.")
            }
            onProgress?("Menu \(walked.joined(separator: " › "))")
            guard AX.press(item.element) else { return .error("The app did not accept «\(walked.joined(separator: " > "))».") }
            try await Task.sleep(for: .milliseconds(300))
            return .text("Chose «\(walked.joined(separator: " > "))»\(item.shortcut.isEmpty ? "" : " (shortcut \(item.shortcut))").")
        }
    }

    /// Several actions in one call (FR-38): same checks for every step, stop at the first error.
    private func act(_ a: [String: Any]) async -> Result {
        guard let steps = a["steps"] as? [[String: Any]], !steps.isEmpty else { return .error("Missing steps") }
        var lines: [String] = []
        var failed = false
        for (i, step) in steps.enumerated() {
            let name = (step["tool"] as? String) ?? ""
            if failed || cancelled {
                lines.append("\(i + 1). \(name): not executed")
                continue
            }
            guard Self.actSteps.contains(name) else {
                lines.append("\(i + 1). \(name): ERROR not allowed in act (allowed: \(Self.actSteps.sorted().joined(separator: ", ")))")
                failed = true
                continue
            }
            if i > 0 {
                callCount += 1
                if callCount > maxCalls {
                    lines.append("\(i + 1). \(name): not executed (step limit reached)")
                    failed = true
                    continue
                }
            }
            var args = step
            args.removeValue(forKey: "tool")
            Log.debug("Agente → act \(i + 1). \(name) \(Self.compact(args))")
            let r = await perform(name, args)
            lines.append("\(i + 1). \(name): \(r.isError ? "ERROR " : "ok — ")\(Self.short(r.text, max: 200))")
            if r.isError { failed = true }
            // Let the interface catch up before the next step (a field appearing, a menu opening).
            try? await Task.sleep(for: .milliseconds(120))
        }
        return Result(content: [["type": "text", "text": lines.joined(separator: "\n")]], isError: failed)
    }

    // MARK: Helpers

    private static func int(_ v: Any?) -> Int? {
        if let i = v as? Int { return i }
        if let d = v as? Double { return Int(d) }
        if let s = v as? String { return Int(s) }
        return nil
    }

    private static func double(_ v: Any?) -> Double? {
        if let d = v as? Double { return d }
        if let i = v as? Int { return Double(i) }
        if let s = v as? String { return Double(s) }
        return nil
    }

    static func short(_ s: String, max: Int = 120) -> String {
        let one = s.replacingOccurrences(of: "\n", with: " ⏎ ")
        return one.count > max ? String(one.prefix(max)) + "…" : one
    }

    private static let emptyAnswers: Set<String> = [
        "si", "no", "ok", "okay", "va bene", "certo", "boh", "non so", "si si", "no no", "esatto", "giusto", "vai",
    ]

    /// «sì», «ok», «boh»: no information for an open question.
    static func isEmptyAnswer(_ text: String) -> Bool {
        let n = Grammar.normalize(text)
        return n.isEmpty || emptyAnswers.contains(n)
    }

    private static func compact(_ args: [String: Any]) -> String {
        var copy = args
        if let t = copy["text"] as? String, t.count > 60 { copy["text"] = String(t.prefix(60)) + "…" }
        let data = (try? JSONSerialization.data(withJSONObject: copy, options: [.sortedKeys])) ?? Data()
        return String(data: data, encoding: .utf8) ?? ""
    }
}
