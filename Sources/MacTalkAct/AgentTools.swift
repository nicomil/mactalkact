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
    private var lastShot: WindowShot?
    private var confirmedUntil = Date.distantPast
    private(set) var callCount = 0
    private let maxCalls = 60
    var cancelled = false

    init(executor: Executor) {
        self.executor = executor
    }

    /// Fresh state for a new task.
    func reset() {
        registry.removeAll()
        nextID = 1
        lastShot = nil
        confirmedUntil = .distantPast
        callCount = 0
        cancelled = false
    }

    // MARK: Definitions (MCP tools/list)

    static let definitions: [[String: Any]] = [
        tool("observe",
             "Describe the frontmost window: app, title, focused element, and the visible UI elements with an [id] you can pass to click/type_text/scroll. Clickable elements are marked with *. Large web pages are truncated: pass `query` to search the WHOLE window for elements whose text contains it (e.g. a mail subject or sender). IDs are only valid until the next observe.",
             ["query": ["type": "string", "description": "Optional text to search for (case and accent insensitive)."]]),
        tool("screenshot",
             "Take a JPEG screenshot of the frontmost window with an orange numbered tag on every clickable element: click(id) with that number. Use it when observe is not enough (icons without labels, canvas, visual layout, to verify a result). Pixel coordinates can also be passed to click as x/y.",
             [:]),
        tool("click",
             "Click an element by id (from the latest observe) or at x/y image coordinates (from the latest screenshot). method: 'auto' (accessibility press, then real mouse click), 'mouse' (real mouse click, best for web pages and lists), 'double' (double click), 'right' (right click).",
             ["id": ["type": "integer"], "x": ["type": "number"], "y": ["type": "number"],
              "method": ["type": "string", "enum": ["auto", "mouse", "double", "right"]]]),
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
        if callCount > maxCalls { return .error("Step limit reached. Stop and tell the user what is left to do.") }
        Log.debug("Agente → \(name) \(Self.compact(args))")
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
                registry.removeAll()
                nextID = 1
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

        case "type_text":
            guard let text = a["text"] as? String else { return .error("Missing text") }
            if let id = Self.int(a["id"]) {
                guard let item = registry[id] else { return .error("Unknown id \(id): call observe again.") }
                if AXUIElementSetAttributeValue(item.element, kAXFocusedAttribute as CFString, kCFBooleanTrue) != .success,
                   let f = AX.frame(item.element) {
                    await executor.mouseClick(at: CGPoint(x: f.midX, y: f.midY))
                }
                try await Task.sleep(for: .milliseconds(150))
            }
            onProgress?("Scrivo…")
            await executor.paste(text)
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
            try await Task.sleep(for: .milliseconds(250))
            return .text("Scrolled \(direction) \(amount). IDs may have changed: observe again before clicking.")

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
            if mode == "replace_selection" {
                await executor.paste(text)
            } else {
                try await executor.rewriteBeforeCursor(new: text)
            }
            return .text("Text edited.")

        case "ask_user":
            guard let q = a["question"] as? String else { return .error("Missing question") }
            guard let answer = await askUser?(q, false), !answer.isEmpty else {
                return .text("(no answer from the user)")
            }
            return .text("User answered: \(answer)")

        case "confirm":
            guard let action = a["action"] as? String else { return .error("Missing action") }
            let answer = await askUser?(action, true)
            if let answer, Grammar.isYes(answer) {
                confirmedUntil = Date().addingTimeInterval(45)
                return .text("approved")
            }
            return .text("denied — do not perform the action. Tell the user it was cancelled.")

        default:
            return .error("Unknown tool \(name)")
        }
    }

    private var confirmed: Bool { Date() < confirmedUntil }

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
        registry.removeAll()
        nextID = 1
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
        var queue: [(AXUIElement, Int)] = [(root, 0)]
        var index = 0
        var emitted = 0
        var lastLabel = ""
        var truncated = false

        while index < queue.count {
            if emitted >= maxItems || index >= maxNodes || Date().timeIntervalSince(start) > deadline {
                truncated = true
                break
            }
            let (el, depth) = queue[index]
            index += 1
            let v = AX.multi(el, Self.attrs)
            let role = (v[0] as? String) ?? ""
            let frame = AX.rect(position: v[5], size: v[6])

            // Skip whole subtrees scrolled out of the window.
            if let wf = windowFrame, let f = frame, f.width > 0, f.height > 0,
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
                    if focused { line += " (focused)" }
                    if let f = frame, let wf = windowFrame {
                        line += " @\(Int(f.minX - wf.minX)),\(Int(f.minY - wf.minY)) \(Int(f.width))x\(Int(f.height))"
                    }
                    lines.append(line)
                }
            }
            if depth < 60, let children = v[4] as? [AXUIElement] {
                for c in children { queue.append((c, depth + 1)) }
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

    private func click(_ a: [String: Any]) async throws -> Result {
        let method = (a["method"] as? String) ?? "auto"
        var point: CGPoint?
        var label = ""

        if let id = Self.int(a["id"]) {
            guard let item = registry[id] else { return .error("Unknown id \(id): call observe again.") }
            label = item.label
            if Safety.isRiskyLabel(label), !confirmed {
                return .error("Clicking «\(label)» may send or delete something: call confirm first.")
            }
            onProgress?("Clicco «\(label)»")
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

    private static func compact(_ args: [String: Any]) -> String {
        var copy = args
        if let t = copy["text"] as? String, t.count > 60 { copy["text"] = String(t.prefix(60)) + "…" }
        let data = (try? JSONSerialization.data(withJSONObject: copy, options: [.sortedKeys])) ?? Data()
        return String(data: data, encoding: .utf8) ?? ""
    }
}
