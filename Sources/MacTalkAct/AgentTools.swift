import AppKit
import ApplicationServices

/// The tools the agent (Claude) uses to see and act on the Mac.
/// Exposed over MCP by `MCPServer`; every call runs here, inside the app,
/// with the app's own permissions and safety rules.
@MainActor
final class AgentTools {

    /// Progress line for the HUD ("Clicco «Invia»").
    var onProgress: ((String) -> Void)?
    /// Asks the user something by voice. `confirmation` = yes/no question. Returns nil on timeout.
    var askUser: ((String, Bool) async -> String?)?

    private let executor: Executor
    private var registry: [Int: (element: AXUIElement, label: String, role: String)] = [:]
    private var nextID = 1
    /// First id of the current snapshot: smaller ids come from an older observe/screenshot (AD-8).
    private var generationStart = 1
    private(set) var generation = 0
    private var lastShot: WindowShot?
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

    /// Fresh state for a new task.
    func reset() {
        registry.removeAll()
        nextID = 1
        generationStart = 1
        generation = 0
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

    private static let actingTools: Set<String> = ["click", "click_many", "type_text", "press_keys", "replace_text", "edit_text", "scroll"]
    /// Everything that changes the screen, an app or the user's data. Reading tools
    /// (observe, screenshot, get_text, browser_profiles, wait) and questions are not here.
    static let effectfulTools: Set<String> = actingTools.union(["open_app", "open_url", "save_macro", "delete_macro"])

    /// nil when it is safe to act; otherwise an error for the agent.
    private func frontmostChanged() -> String? {
        guard let target = targetPID, let now = AX.realFrontmostApplication() else { return nil }
        if now.processIdentifier == target || now.bundleIdentifier == Bundle.main.bundleIdentifier { return nil }
        return "The frontmost app changed to «\(now.localizedName ?? "?")»: the user probably switched app. Do not act there. Stop and tell the user in one short Italian sentence."
    }

    // MARK: Definitions (MCP tools/list)

    static let definitions: [[String: Any]] = [
        tool("observe",
             "Describe the frontmost window: app, title, focused element, and the visible UI elements with an [id] you can pass to click/type_text/scroll. Clickable elements are marked with *; in browsers, elements of the web page are marked (page). Large web pages are truncated: pass `query` to search the WHOLE window for elements whose text contains it (e.g. a mail subject or sender). IDs are only valid until the next observe.",
             ["query": ["type": "string", "description": "Optional text to search for (case and accent insensitive)."]]),
        tool("screenshot",
             "Take a JPEG screenshot of the frontmost window with an orange numbered tag on every clickable element: click(id) with that number. Use it when observe is not enough (icons without labels, canvas, visual layout, to verify a result). Pixel coordinates can also be passed to click as x/y.",
             [:]),
        tool("click",
             "Click an element by id (from the latest observe) or at x/y image coordinates (from the latest screenshot). method: 'auto' (accessibility press, then real mouse click), 'mouse' (real mouse click, best for web pages and lists), 'double' (double click), 'right' (right click).",
             ["id": ["type": "integer"], "x": ["type": "number"], "y": ["type": "number"],
              "method": ["type": "string", "enum": ["auto", "mouse", "double", "right"]]]),
        tool("click_many",
             "Click several elements in one call (e.g. many checkboxes in a list), in order. Returns, for each id, whether it worked and the element's state afterwards (checked/unchecked when it is a checkbox). Prefer this to many single clicks. Ids must come from the latest observe/screenshot.",
             ["ids": ["type": "array", "items": ["type": "integer"]],
              "method": ["type": "string", "enum": ["auto", "mouse"]]], required: ["ids"]),
        tool("replace_text",
             "Replace text inside the focused text field, document or code/notebook cell, then verify it. Works also in web editors (Jupyter, Colab, code editors) where get_text sees nothing: click into the field or cell first. `find` must be the exact current text (a word, a line or more).",
             ["find": ["type": "string"], "replace": ["type": "string"]], required: ["find", "replace"]),
        tool("type_text",
             "Type text at the caret (pasted, any length, any language). If id is given, that field is focused first.",
             ["text": ["type": "string"], "id": ["type": "integer"]], required: ["text"]),
        tool("press_keys",
             "Press keyboard shortcuts or special keys: 'cmd+shift+d', 'return', 'escape', 'tab', 'down', 'pagedown', or a sequence separated by spaces like 'cmd+a delete'. Letters and digits work as keys; to type text or symbols (* + = @ …) use type_text.",
             ["keys": ["type": "string"]], required: ["keys"]),
        tool("scroll",
             "Scroll the window, or the element with the given id (e.g. a list or the page).",
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
             "Wait for the UI to update (e.g. a page loading). Max 5 seconds.",
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

        static func text(_ s: String) -> Result { Result(content: [["type": "text", "text": s]]) }
        static func error(_ s: String) -> Result { Result(content: [["type": "text", "text": s]], isError: true) }
    }

    func call(_ name: String, _ args: [String: Any]) async -> Result {
        if cancelled { return .error("The user cancelled the task. Stop now.") }
        callCount += 1
        if firstCallAt == nil { firstCallAt = Date() }
        if callCount > maxCalls { return .error("Step limit reached. Stop and tell the user what is left to do.") }
        Log.debug("Agente → \(name) \(Self.compact(args))")
        if Self.actingTools.contains(name), let problem = frontmostChanged() {
            Log.info("Agente: azione bloccata, app in primo piano cambiata")
            return .error(problem)
        }
        if Self.effectfulTools.contains(name) {
            effectfulCalls += 1
            if firstEffectAt == nil { firstEffectAt = Date() }
        }
        let result: Result
        do {
            result = try await dispatch(name, args)
        } catch {
            result = .error(error.localizedDescription)
        }
        let summary = (result.content.first?["text"] as? String).map { String($0.prefix(160)) } ?? "(immagine)"
        Log.debug("Agente ← \(name)\(result.isError ? " ERRORE" : ""): \(summary.replacingOccurrences(of: "\n", with: " ⏎ "))")
        return result
    }

    private func dispatch(_ name: String, _ a: [String: Any]) async throws -> Result {
        switch name {
        case "observe":
            let query = (a["query"] as? String)?.trimmingCharacters(in: .whitespaces)
            onProgress?(query.map { "Cerco «\($0)»…" } ?? "Guardo lo schermo…")
            return .text(observe(query: query?.isEmpty == true ? nil : query))

        case "screenshot":
            onProgress?("Guardo la finestra…")
            guard ScreenCapture.hasPermission else {
                ScreenCapture.requestPermission()
                return .error("Screen Recording permission not granted. Use observe instead.")
            }
            let shot = try await ScreenCapture.frontWindow()
            lastShot = shot
            // Number every clickable element on the image (set-of-marks).
            var marks: [(Int, CGRect)] = []
            var legend: [String] = []
            if let (app, _) = AX.frontApp(), let window = AX.focusedWindow(in: app), let wf = AX.frame(window) {
                newGeneration()
                for c in AXTree.clickables(in: window, windowFrame: wf, limit: 150) {
                    let id = nextID
                    nextID += 1
                    registry[id] = (c.element, c.label.isEmpty ? c.role : c.label, c.role)
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
                : " Orange tags are element ids for click(id) (they replace earlier observe ids); click x/y also works for untagged spots."
            if !legend.isEmpty { note += "\nLabelled tags: " + legend.joined(separator: ", ") }
            return Result(content: [
                ["type": "image", "data": jpeg.base64EncodedString(), "mimeType": "image/jpeg"],
                ["type": "text", "text": note],
            ])

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
                let r = try await click(["id": id, "method": method], quiet: true)
                let text = (r.content.first?["text"] as? String) ?? ""
                var line = r.isError ? "[\(id)] ERROR: \(text)" : "[\(id)] «\(registry[id]?.label ?? "")» ok"
                if !r.isError, let el = registry[id]?.element {
                    try? await Task.sleep(for: .milliseconds(120))
                    if let state = Self.toggleState(el) { line += ", now \(state)" }
                }
                lines.append(line)
            }
            return .text(lines.joined(separator: "\n") + "\nScreenshot to double-check visually if needed.")

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
            if let id = Self.int(a["id"]) {
                guard let item = registry[id] else { return .error(staleMessage(id)) }
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
            if let id = Self.int(a["id"]), let item = registry[id], !text.isEmpty,
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
            if let id = Self.int(a["id"]), let item = registry[id], let f = AX.frame(item.element) {
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
            return .text("Opened \(url). The page may still be loading.")

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

    /// A new snapshot: old ids stop working, numbering continues (ids are never reused in a task).
    private func newGeneration() {
        registry.removeAll()
        generation += 1
        generationStart = nextID
    }

    private func staleMessage(_ id: Int) -> String {
        id < generationStart && id > 0
            ? "Id \(id) comes from an older observe/screenshot and may now point elsewhere: observe or screenshot again."
            : "Unknown id \(id): observe or screenshot first."
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

    private static let attrs = [
        kAXRoleAttribute, kAXTitleAttribute, kAXDescriptionAttribute, kAXValueAttribute,
        kAXChildrenAttribute, kAXPositionAttribute, kAXSizeAttribute, kAXFocusedAttribute,
    ] as [String]

    private static let clickableRoles: Set<String> = [
        "AXButton", "AXLink", "AXMenuItem", "AXMenuButton", "AXPopUpButton", "AXCheckBox", "AXRadioButton",
        "AXTab", "AXCell", "AXRow", "AXDisclosureTriangle", "AXComboBox", "AXMenuBarItem", "AXSwitch",
        "AXToggle", "AXTextField", "AXTextArea", "AXSearchField", "AXSlider", "AXIncrementor",
    ]
    private static let textRoles: Set<String> = ["AXStaticText", "AXHeading", "AXImage"]

    private func observe(query: String?) -> String {
        newGeneration()
        guard let (app, running) = AX.frontApp() else { return "No frontmost application." }
        let window = AX.focusedWindow(in: app)
        let ctx = ScreenContext.capture(includeLabels: false)
        let windowFrame = window.flatMap { AX.frame($0) }

        var lines: [String] = [
            "APP: \(running.localizedName ?? "") (\(running.bundleIdentifier ?? ""))",
            "WINDOW: \(ctx.windowTitle)" + (windowFrame.map { " size \(Int($0.width))x\(Int($0.height))" } ?? ""),
            "FOCUSED: \(ctx.focusedRole.isEmpty ? "none" : ctx.focusedRole)\(ctx.isEditable ? " (editable)" : "")",
        ]
        guard let root = window else {
            lines.append("This app has no open window in front.")
            return lines.joined(separator: "\n")
        }

        let needle = query.map { Grammar.normalize($0) }
        let maxItems = needle == nil ? 220 : 60
        let deadline: TimeInterval = needle == nil ? 1.8 : 4.0
        let maxNodes = needle == nil ? 12_000 : 40_000
        let start = Date()
        // Third value: inside a web page (AXWebArea), as opposed to the browser's own toolbars and sidebars.
        var queue: [(AXUIElement, Int, Bool)] = [(root, 0, false)]
        var index = 0
        var emitted = 0
        var lastLabel = ""
        var truncated = false
        // The same element can be reachable from two parents (web tables in Safari): visit it once.
        var seen: [CFHashCode: [AXUIElement]] = [:]

        while index < queue.count {
            if emitted >= maxItems || index >= maxNodes || Date().timeIntervalSince(start) > deadline {
                truncated = true
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
            if label.isEmpty, !value.isEmpty, !["AXTextArea", "AXTextField"].contains(role) || role == "AXStaticText" {
                label = value
            }
            label = AX.collapse(label, max: 100)

            let interesting = (clickable || Self.textRoles.contains(role)) && !label.isEmpty
                || (["AXTextField", "AXTextArea", "AXSearchField"].contains(role))
            if interesting, label != lastLabel || clickable {
                let matches = needle.map { Grammar.normalize(label).contains($0) } ?? true
                if matches {
                    let id = nextID
                    nextID += 1
                    registry[id] = (el, label, role)
                    emitted += 1
                    lastLabel = label
                    var line = "[\(id)]\(clickable ? "*" : "") \(role.replacingOccurrences(of: "AX", with: "").lowercased())"
                    if !label.isEmpty { line += " «\(label)»" }
                    if ["AXTextField", "AXTextArea", "AXSearchField"].contains(role), !value.isEmpty {
                        line += " value=«\(AX.collapse(value, max: 60))»"
                    }
                    if ["AXCheckBox", "AXRadioButton", "AXSwitch"].contains(role), let on = v[3] as? NSNumber {
                        line += on.intValue == 0 ? " (unchecked)" : " (checked)"
                    }
                    if focused { line += " (focused)" }
                    if inWeb { line += " (page)" }
                    if let f = frame, let wf = windowFrame {
                        line += " @\(Int(f.minX - wf.minX)),\(Int(f.minY - wf.minY)) \(Int(f.width))x\(Int(f.height))"
                    }
                    lines.append(line)
                }
            }
            if depth < 60, let children = v[4] as? [AXUIElement] {
                let childrenInWeb = inWeb || role == "AXWebArea"
                for c in children { queue.append((c, depth + 1, childrenInWeb)) }
            }
        }

        if emitted == 0 {
            lines.append(needle != nil ? "Nothing matches «\(query!)». Try other words, scroll, or take a screenshot."
                                       : "No readable elements (the app may not support Accessibility): take a screenshot.")
        } else if truncated {
            lines.append(needle != nil ? "(search stopped early: results may be incomplete)"
                                       : "(list truncated: use observe with a query to find something specific, or a screenshot)")
        }
        return lines.joined(separator: "\n")
    }

    // MARK: Click

    private func click(_ a: [String: Any], quiet: Bool = false) async throws -> Result {
        let method = (a["method"] as? String) ?? "auto"
        var point: CGPoint?
        var label = ""

        if let id = Self.int(a["id"]) {
            guard let item = registry[id] else { return .error(staleMessage(id)) }
            label = item.label
            if Safety.isRiskyLabel(label), !confirmed {
                return .error("Clicking «\(label)» may send or delete something: call confirm first.")
            }
            if !quiet { onProgress?("Clicco «\(label)»") }
            if method == "auto" {
                if AX.press(item.element) {
                    try await Task.sleep(for: .milliseconds(350))
                    return .text("Pressed [\(id)] «\(label)». Observe or screenshot to verify.")
                }
                var current = item.element
                for _ in 0..<6 {
                    guard let parent = AX.element(current, kAXParentAttribute) else { break }
                    if AX.actions(parent).contains(kAXPressAction), AX.press(parent) {
                        try await Task.sleep(for: .milliseconds(350))
                        return .text("Pressed the container of [\(id)] «\(label)». Observe or screenshot to verify.")
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
        } else if let x = a["x"] as? Double ?? (Self.int(a["x"]).map(Double.init)),
                  let y = a["y"] as? Double ?? (Self.int(a["y"]).map(Double.init)) {
            guard let shot = lastShot else { return .error("x/y need a screenshot first.") }
            point = shot.screenPoint(imageX: x, imageY: y)
            label = "\(Int(x)),\(Int(y))"
            onProgress?("Clicco nel punto indicato")
        } else {
            return .error("Pass id or x/y.")
        }

        guard let p = point else { return .error("Nothing to click.") }
        switch method {
        case "double": await executor.mouseClick(at: p, count: 2)
        case "right": await executor.mouseClick(at: p, right: true)
        default: await executor.mouseClick(at: p)
        }
        try await Task.sleep(for: .milliseconds(350))
        return .text("Clicked «\(label)» with the mouse. Observe or screenshot to verify.")
    }

    // MARK: Helpers

    private static func int(_ v: Any?) -> Int? {
        if let i = v as? Int { return i }
        if let d = v as? Double { return Int(d) }
        if let s = v as? String { return Int(s) }
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
