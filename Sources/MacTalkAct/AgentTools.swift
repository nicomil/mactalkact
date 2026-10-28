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
    /// The access gate (AD-21): every action of the agent is `.model` and passes through it.
    let gate = AccessGate()
    /// Asks the user something by voice. `confirmation` = yes/no question. Returns nil on timeout.
    var askUser: ((String, Bool) async -> String?)? {
        get { gate.askUser }
        set { gate.askUser = newValue }
    }
    /// Add «what changed» to the result of every action (AD-19). The local engine observes on its own.
    var reportOutcome = true
    /// The engine calling the tools runs in the cloud: reserved windows are off limits and
    /// sensitive data in the results is masked.
    var cloudEngine = false

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
    private(set) var callCount = 0
    /// Calls that changed something on the Mac in this task (AD-15): after the first one,
    /// a request is never repeated on another engine.
    private(set) var effectfulCalls = 0
    /// When the first tool was called in this task (time to first tool, NFR-9).
    private(set) var firstCallAt: Date?
    /// When the first action with effects happened (local engine: the app observes first).
    private(set) var firstEffectAt: Date?
    /// Bench counters (FR-41): confirmations asked, and actions stopped without a «sì».
    var confirmationsAsked: Int { gate.confirmationsAsked }
    /// Actions with external effects not done because the user did not say «sì».
    var blockedCalls: Int { gate.deniedConfirmations }
    /// Start (`true`) and end (`false`) of every tool call, settling included: the phases of the Bench.
    var onCall: ((Bool) -> Void)?
    /// Instant level (FR-43): one tool call; an action without effect, or a second call, escalates.
    var instantGuard = false
    var onEscalate: ((String) -> Void)?
    private(set) var escalation: String?
    /// The calls of this request with the first line of their result, for the level that takes over.
    private(set) var callLog: [String] = []
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
        callCount = 0
        escalation = nil
        instantGuard = false
        // The same request retried on another engine keeps what the first one asked (AD-15).
        gate.reset(keepCounters: keepElements)
        if !keepElements {
            callLog = []
            readTextSeconds = []
        }
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
             "JPEG screenshot of the frontmost window with an orange numbered tag on every clickable element: click(id) with that number. Use it when observe is not enough (icons without labels, images, canvas, visual layout). Pass `region` [x0, y0, x1, y1] (coordinates of the latest screenshot) to zoom into a part at full resolution; when the region is only text, the text read on the Mac comes back instead of the image — pass `image: true` to always get the image. Click x/y keep using the coordinates of the full screenshot.",
             ["region": ["type": "array", "items": ["type": "number"], "description": "Optional [x0, y0, x1, y1] to zoom into."],
              "image": ["type": "boolean", "description": "With region: always return the image, even when the text alone would do."]]),
        tool("read_text",
             "Read the text of the frontmost window, or of `region` [x0, y0, x1, y1] of the latest screenshot, with the Mac's text recognition: labels, photos, canvas, scanned documents, small print. Returns each line with its position in window points (@x,y like observe; to click, use an id from observe or x/y of a screenshot). The image never leaves the Mac: prefer it to screenshot when you only need the text.",
             ["region": ["type": "array", "items": ["type": "number"], "description": "Optional [x0, y0, x1, y1] in coordinates of the latest screenshot."]]),
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
             "Save a short fact in the user's personal memory (Italian), e.g. «profilo aula IB» = Edge, profilo «Aulab». Use when the user says «ricorda che…» or when you learn a stable preference or alias. Never save passwords, codes, card or bank details, health information or other people's personal data (phone numbers, addresses) unless the user explicitly asks to remember that exact thing.",
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
             "Not needed any more: when you perform an action that sends, deletes, buys, publishes or closes something, the app itself asks the user at that moment and tells you the answer. Kept only for compatibility.",
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
        var asReadOnly: Result { var r = self; r.readOnly = true; return r }
    }

    /// An error for the agent, thrown from deep inside a tool.
    struct ToolError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    func call(_ name: String, _ args: [String: Any]) async -> Result {
        if cancelled { return .error("The user cancelled the task. Stop now.") }
        if instantGuard, escalation != nil || callCount >= 1 {
            escalate(escalation ?? "seconda chiamata (\(name))")
            return .error("Stop now: another assistant continues this task. Do not call tools; reply with one word.")
        }
        onCall?(true)
        defer { onCall?(false) }
        callCount += 1
        if firstCallAt == nil { firstCallAt = Date() }
        if callCount > maxCalls { return .error("Step limit reached. Stop and tell the user what is left to do.") }
        Log.debug("Agente → \(name) \(Log.isDetailed ? Self.compact(args) : Self.shape(args))")
        if cloudEngine, let why = PrivacyGuard.cloudBlockReason() {
            Log.info("Agente: \(name) bloccato, \(why)")
            return Self.privateWindowError(why)
        }
        if let refusal = gate.cloudReadRefusal(name, cloud: cloudEngine) { return .error(refusal) }
        var result = await perform(name, args)
        if reportOutcome, Self.outcomeTools.contains(name), !result.readOnly, !cancelled,
           !result.text.hasPrefix("MacTalkAct does not have"), !result.text.hasPrefix("The frontmost app changed") {
            await settle()
            if cloudEngine, let why = PrivacyGuard.cloudBlockReason() {
                // The action led to a reserved window: the engine does not see what is there.
                Log.info("Agente: dopo \(name) la finestra è riservata, \(why)")
                return Self.privateWindowError(why)
            }
            result.content.append(["type": "text", "text": outcome()])
        }
        // «Solo clic» app, cloud engine: only the controls, never text of the window (FR-54). Before the
        // call log, so the level that takes over after a scalata does not receive it either.
        if gate.showsOnlyControls(cloud: cloudEngine) {
            result.content = result.content.compactMap { item in
                guard (item["type"] as? String) == "text", let t = item["text"] as? String else { return nil }
                var copy = item
                if name == "observe" {
                    copy["text"] = Self.controlsOnly(t)
                } else {
                    // Step lines of act («2. click: ok — …» → «2. click: ok») and the first line otherwise.
                    let lines = t.split(separator: "\n").map(String.init)
                    let steps = lines.filter { $0.range(of: #"^\d+\. "#, options: .regularExpression) != nil }
                        .map { $0.components(separatedBy: " — ").first ?? $0 }
                    copy["text"] = steps.isEmpty ? (lines.first?.components(separatedBy: " «").first ?? "") : steps.joined(separator: "\n")
                }
                return copy
            }
        }
        // After the outcome: «nothing changed» is in it (FR-43). `act` is judged too: it is the call
        // the Instant level is told to use.
        let lines = result.text.split(separator: "\n").map(String.init)
        let resultLine = lines.first { $0.hasPrefix("RESULT") }.map { " · " + $0.prefix(120) } ?? ""
        callLog.append("- \(name) \(Self.compact(args)) → \(result.isError ? "ERROR " : "")\(lines.first?.prefix(160) ?? "")\(resultLine)")
        // After a «no» of the user nothing escalates: the fast level must not ask again (FR-51).
        if instantGuard, !deniedThisRequest, Self.effectfulTools.contains(name) || name == "act", let why = Self.instantFailure(result) { escalate(why) }
        if cloudEngine, AppSettings.shared.hideSensitiveFromCloud {
            result.content = result.content.map { item in
                guard let t = item["text"] as? String else { return item }
                var copy = item
                copy["text"] = Privacy.redact(t, forCloud: true)
                return copy
            }
        }
        if Log.isDetailed {
            let summary = (result.content.first?["text"] as? String).map { String($0.prefix(160)) } ?? "(immagine)"
            Log.debug("Agente ← \(name)\(result.isError ? " ERRORE" : ""): \(summary.replacingOccurrences(of: "\n", with: " ⏎ "))")
        } else {
            // What is on screen stays out of the log: only the size of the answer.
            let images = result.content.filter { ($0["type"] as? String) == "image" }.count
            Log.debug("Agente ← \(name)\(result.isError ? " ERRORE" : ""): \(result.text.count) caratteri\(images > 0 ? " + immagine" : "")")
        }
        return result
    }

    private static func privateWindowError(_ why: String) -> Result {
        .error("PRIVATE WINDOW (\(why)): the user does not want a cloud assistant to see or touch this window. Do not call any more tools. Reply in one short Italian sentence that you stopped because the window is private and they can do it by hand or with the local engine.")
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
        // Access level, password fields, «conferma ogni azione» and second layer: the gate decides (AD-21).
        if let refusal = await gate.check(name, args, origin: .model, facts: facts(name, args)) {
            return .error(refusal)
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

    // MARK: Facts for the gate

    var riskClassifier: OnDeviceRiskClassifier { gate.riskClassifier }
    /// Replaces the model in the tests: a fixed verdict, so the gate around it is what is tested.
    var riskJudge: ((RiskAction) async -> RiskVerdict)? {
        get { gate.riskJudge }
        set { gate.riskJudge = newValue }
    }
    /// Seconds spent judging, for the «classificatore» phase of the Banco.
    var onClassified: ((Double) -> Void)? {
        get { gate.onClassified }
        set { gate.onClassified = newValue }
    }

    /// What the gate needs to know about this call, read only when it asks (in the order of its checks).
    private func facts(_ name: String, _ args: [String: Any]) -> AccessGate.ActionFacts {
        AccessGate.ActionFacts(
            isSecureElement: { [unowned self] id in (try? self.resolve(id)).map { AX.isSecureField($0.element) } },
            riskActions: { [unowned self] app in self.riskActions(name, args, app: app) })
    }

    /// The actions as the second layer sees them: none when there is nothing to judge (a tool
    /// without external effects of its own, or an action the fixed rules already stop).
    private func riskActions(_ name: String, _ a: [String: Any], app: String) -> [RiskAction] {
        if name == "click_many" {
            let method = (a["method"] as? String) ?? "auto"
            return ((a["ids"] as? [Any]) ?? []).compactMap { Self.int($0) }.compactMap { riskAction("click", ["id": $0, "method": method], app: app) }
        }
        return riskAction(name, a, app: app).map { [$0] } ?? []
    }

    /// `place`: the window title and dialog text when the caller already read them (judgement in
    /// advance, many controls of the same window).
    private func riskAction(_ name: String, _ a: [String: Any], app: String, place: (window: String, dialog: String)? = nil) -> RiskAction? {
        var label = "", role = ""
        switch name {
        case "click":
            // A right click opens a menu: it does not press.
            if (a["method"] as? String) == "right" { return nil }
            if let id = Self.int(a["id"]) {
                guard let item = try? resolve(id) else { return nil }
                (label, role) = (item.label, AX.role(item.element))
                // Text or an icon inside a control: the control is what gets pressed, so it is judged.
                if ["AXStaticText", "AXImage"].contains(role), let outer = Self.pressableAncestor(item.element) {
                    let name = Self.ownLabel(outer)
                    if AccessGate.fixedRuleAsks(name) { return nil } // click() asks for it
                    (label, role) = (name.isEmpty ? label : "\(name) (\(label))", AX.role(outer))
                }
            } else if let x = Self.double(a["x"]), let y = Self.double(a["y"]), let shot = lastShot {
                label = AX.labelAt(shot.screenPoint(imageX: x, imageY: y)) ?? ""
            } else { return nil }
            if AccessGate.fixedRuleAsks(label) { return nil }
        case "perform_action":
            // The action that will really run (as performAction resolves it), and only actions that act.
            guard let id = Self.int(a["id"]), let item = try? resolve(id), let wanted = a["action"] as? String else { return nil }
            let w = Grammar.normalize(wanted.hasPrefix("AX") ? String(wanted.dropFirst(2)) : wanted)
            guard let raw = AX.actions(item.element).first(where: { Grammar.normalize(Self.actionName($0)) == w }) else { return nil }
            let passive: Set<String> = ["AXShowMenu", "AXScrollToVisible", "AXIncrement", "AXDecrement", "AXRaise", "AXCancel", "AXShowDefaultUI", "AXShowAlternateUI"]
            if passive.contains(raw) { return nil }
            if AccessGate.fixedRuleAsks(item.label) || AccessGate.fixedRuleAsks(Self.actionName(raw)) { return nil }
            (label, role) = ("\(item.label) → \(Self.actionName(raw))", AX.role(item.element))
        case "menu":
            // The item the menu tool will really choose, not the words the model wrote.
            let path = (a["path"] as? String) ?? ""
            guard !AppMenu.split(path).isEmpty, let front = AX.frontApp(),
                  case .item(let walked, let item) = AppMenu.resolve(path, in: front.app), item.enabled else { return nil }
            if walked.contains(where: AccessGate.fixedRuleAsks) || AccessGate.fixedRuleAsks(item.title) { return nil }
            (label, role) = ((walked.dropLast() + [item.title]).joined(separator: " > "), "menu")
        default:
            return nil
        }
        // Fields, tabs, rows and pop-ups send nothing out by themselves: no verdict, no latency.
        // Boxes, radio buttons and cells stay: a «Profilo pubblico» switch, an «Approva» cell.
        if Self.inertRoles.contains(role) { return nil }
        // Buttons that only open a draft: the send comes later and the fixed rules stop it (Invia,
        // ⌘Invio, Invio in a composer). The on-device model takes «Componi» for «invio».
        if Self.opensDraft(label) { return nil }
        // An icon without a name: the window and the dialog may still say what it does.
        if label.trimmingCharacters(in: .whitespaces).isEmpty { label = "(senza etichetta)" }
        return RiskAction(tool: name, label: label, role: role, app: app, window: place?.window ?? Self.frontWindowTitle(),
                          dialog: place?.dialog ?? Self.frontDialogText(), request: currentRequest)
    }

    /// Fields, tabs, rows and pop-ups send nothing out by themselves: the second layer does not judge them.
    private static let inertRoles: Set<String> = ["AXTextField", "AXTextArea", "AXTab", "AXRow", "AXPopUpButton", "AXComboBox", "AXSlider",
                                                  "AXDisclosureTriangle", "AXSearchField", "AXScrollBar"]

    /// The controls of a view the second layer may judge in advance (Story 10.3): visible pressable
    /// controls, nearest to the focus first, as the click on each would be judged (same filters: fixed
    /// rules, inert roles, buttons that open a draft), keeping only those `wanted` accepts (not in the
    /// cache, not in progress) and stopping at `AccessGate.anticipationLimit`.
    private func anticipationCandidates(_ view: View, app: String, wanted: (RiskAction) -> Bool) -> [RiskAction] {
        let place = (window: Self.frontWindowTitle(), dialog: Self.frontDialogText())
        var out: [RiskAction] = []
        var seen: Set<String> = []
        for id in Self.anticipationOrder(view.controls, focus: view.focusFrame) where out.count < AccessGate.anticipationLimit {
            if let action = riskAction("click", ["id": id], app: app, place: place), wanted(action), seen.insert(action.cacheKey).inserted {
                out.append(action)
            }
        }
        return out
    }

    /// The ids to judge in advance, in order (pure, tested by `--selftest`): inert roles dropped,
    /// nearest to the focus first, the same distance in reading order; without a focus, reading order.
    static func anticipationOrder(_ controls: [(id: Int, role: String, frame: CGRect)], focus: CGRect?) -> [Int] {
        let kept = controls.enumerated().filter { !inertRoles.contains($0.element.role) }
        guard let focus else { return kept.map(\.element.id) }
        func distance(_ r: CGRect) -> CGFloat { hypot(r.midX - focus.midX, r.midY - focus.midY) }
        return kept.sorted { a, b in
            let (da, db) = (distance(a.element.frame), distance(b.element.frame))
            return da == db ? a.offset < b.offset : da < db
        }.map(\.element.id)
    }

    /// The fallback chain moved to another cloud engine: the queue of the last observation starts
    /// again (the reset of the request cancelled it).
    func anticipateCurrentView() {
        guard let view = lastView, !view.controls.isEmpty else { return }
        gate.anticipate { [weak self] app, wanted in self?.anticipationCandidates(view, app: app, wanted: wanted) ?? [] }
    }

    static func opensDraft(_ label: String) -> Bool {
        let n = Grammar.normalize(label)
        return ["nuovo messaggio", "nuova mail", "nuova email", "new message", "new email", "componi", "compose", "scrivi",
                "rispondi", "rispondi a tutti", "reply", "reply all", "write"].contains(n)
    }

    private static func ownLabel(_ el: AXUIElement) -> String {
        [AX.string(el, kAXTitleAttribute), AX.string(el, kAXDescriptionAttribute)]
            .compactMap { $0 }.first { !$0.trimmingCharacters(in: .whitespaces).isEmpty } ?? ""
    }

    /// The first ancestor (up to 6 levels) that can be pressed. Safari gives a press action to the
    /// text inside a clickable div too: pressing the text presses the div.
    static func pressableAncestor(_ el: AXUIElement) -> AXUIElement? {
        var current = el
        for _ in 0..<6 {
            guard let parent = AX.element(current, kAXParentAttribute) else { return nil }
            if AX.actions(parent).contains(kAXPressAction) { return parent }
            current = parent
        }
        return nil
    }

    /// The text of a sheet or dialog in front of the window («Eliminare definitivamente 12 elementi?»):
    /// alerts have no title and sheets carry the title of their window.
    static func frontDialogText() -> String {
        guard let window = AX.frontApp().flatMap({ AX.focusedWindow(in: $0.app) }) else { return "" }
        let sub = AX.string(window, kAXSubroleAttribute) ?? ""
        let dialog = ["AXDialog", "AXSystemDialog", "AXFloatingWindow"].contains(sub) ? window
            : AX.children(window).first { AX.role($0) == "AXSheet" }
        guard let dialog else { return "" }
        var texts: [String] = []
        func walk(_ el: AXUIElement, _ depth: Int) {
            guard depth < 4, texts.count < 6 else { return }
            for c in AX.children(el) {
                if AX.role(c) == "AXStaticText", let v = AX.string(c, kAXValueAttribute), !v.isEmpty { texts.append(v) }
                walk(c, depth + 1)
            }
        }
        walk(dialog, 0)
        return String(texts.joined(separator: " ").prefix(160))
    }

    /// Calls refused by the access level or by a password field (read by the security suite).
    var refusals: Int {
        get { gate.refusals }
        set { gate.refusals = newValue }
    }
    /// «🔐 Terminal: solo clic», when the app in front has a level (FR-54).
    var onAccessNotice: ((String) -> Void)? {
        get { gate.onAccessNotice }
        set { gate.onAccessNotice = newValue }
    }

    /// For the cloud engines in a «solo clic» app: only roles and labels of the controls, never
    /// values, text or images (FR-54).
    static func controlsOnly(_ observed: String) -> String {
        observed.split(separator: "\n").compactMap { raw -> String? in
            let line = String(raw)
            if line.hasPrefix("APP:") { return line }
            if line.hasPrefix("WINDOW:") { return "WINDOW: (title hidden)" }
            guard line.hasPrefix("["), line.contains("]*") else { return nil }
            // Everything from « value=» to the next marker («(…)», «@x,y», « settable», « actions=») goes.
            return line.replacingOccurrences(of: #" value=.*?(?= \(| @\d| settable| actions=|$)"#, with: "", options: .regularExpression)
        }.joined(separator: "\n") + "\n(Access level «solo clic»: only the controls are shown, no text of the window.)"
    }

    private func dispatch(_ name: String, _ a: [String: Any]) async throws -> Result {
        switch name {
        case "observe":
            let query = (a["query"] as? String)?.trimmingCharacters(in: .whitespaces)
            onProgress?(query.map { "Cerco «\($0)»…" } ?? "Guardo lo schermo…")
            return .text(observe(query: query?.isEmpty == true ? nil : query))

        case "screenshot":
            return try await screenshot(a)

        case "read_text":
            return try await readText(a)

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
            // A line break typed in a chat sends the message, like Enter (FR-51).
            if let refusal = await gate.confirmTypedText(text, origin: .model) { return .error(refusal) }
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
            if let refusal = await gate.confirmKeys(keys, origin: .model) { return .error(refusal) }
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
            switch Memory.shared.remember(fact) {
            case .saved:
                onProgress?("Ricordo: \(fact)")
                return .text("Saved.")
            case .sensitive:
                return .error("Not saved: the fact contains sensitive data (password, code, card or bank details, tax code). The app never stores these. Tell the user in one short Italian sentence.")
            case .privateMode:
                return .error("Not saved: private mode is on, nothing is remembered. Tell the user in one short Italian sentence.")
            case .empty:
                return .text("Nothing to save.")
            }

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
            guard !ctx.isSecure else { return .error("The focused field is a password field: its content is never read.") }
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
            onQuestion?(true)
            defer { onQuestion?(false) }
            var answer = await askUser?(q, false)
            if let a = answer, Self.isEmptyAnswer(a) {
                answer = await askUser?("Mi serve la risposta precisa: \(q)", false)
            }
            guard let answer, !answer.isEmpty, !Self.isEmptyAnswer(answer) else {
                return .text("No usable answer from the user. Do not guess: stop without acting and say you need the missing detail.")
            }
            return .text("User answered: \(answer)")

        case "confirm":
            // A question of the engine never produces a grant (FR-51): the app asks the user itself,
            // right when the action runs, for that action only.
            return .text("Not needed: just perform the action. If it sends, deletes or pays, the app asks the user at that moment and tells you the answer.").asReadOnly

        default:
            return .error("Unknown tool \(name)")
        }
    }

    // MARK: Confirmations (FR-51, FR-53, AD-21)

    /// The request of this task, to tell the user when an action was not asked for.
    var currentRequest: String {
        get { gate.currentRequest }
        set { gate.currentRequest = newValue }
    }
    /// The user said «no» (or did not answer) to an action in this request: no level retries it.
    var deniedThisRequest: Bool { gate.deniedThisRequest }
    /// Start (`true`) and end of a question to the user: the turn's clock waits (AD-24).
    var onQuestion: ((Bool) -> Void)? {
        get { gate.onQuestion }
        set { gate.onQuestion = newValue }
    }

    private static func frontWindowTitle() -> String { ScreenContext.capture(includeLabels: false).windowTitle }

    /// The rule that judges the one call of the Instant level (FR-43). Pure, tested by `--selftest`.
    static func instantFailure(_ result: Result) -> String? {
        if result.isError { return "errore: \(result.text.split(separator: "\n").first.map(String.init)?.prefix(60) ?? "")" }
        if result.text.contains("nothing changed") { return "nessun effetto" }
        return nil
    }

    /// The Instant turn ended without doing the job: no action with effects, or an answer that says so.
    /// Pure, tested by `--selftest`.
    static func instantGaveUp(answer: String, effectfulCalls: Int) -> String? {
        if effectfulCalls == 0 { return "nessuna azione" }
        // Only the first sentence: «Fatto. Vuoi che lo invii?» is a success.
        let first = answer.split(whereSeparator: { ".!?\n".contains($0) }).first.map(String.init) ?? answer
        let n = Grammar.normalize(first)
        let signs = ["non sono riuscit", "non riesco", "non ho potuto", "non posso", "non trovo", "non ho trovato",
                     "non ho ancora", "non e stato possibile", "non si e aperto", "non vedo", "non c e", "non ce",
                     "impossibile", "purtroppo", "non esiste", "i couldn", "i can t", "unable"]
        return signs.contains(where: n.contains) ? "risposta senza risultato" : nil
    }

    private func escalate(_ reason: String) {
        guard escalation == nil else { return }
        escalation = reason
        onEscalate?(reason)
    }



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
            let p = shot.screenPoint(imageX: x, imageY: y)
            // What is under the point names the target, so the gate can judge a drop on the Bin.
            return (p, AX.labelAt(p) ?? "\(Int(x)),\(Int(y))")
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
        /// Long containers showed only their visible part (fixed cost): what is on screen is complete.
        var capped = false
        /// Clickable controls inside the window, for the judgement in advance (Story 10.3).
        var controls: [(id: Int, role: String, frame: CGRect)] = []
        /// Where the focus is, in screen coordinates.
        var focusFrame: CGRect?
    }

    /// Observation at fixed cost (FR-44): children per container, roles with nothing useful below.
    static let perContainer = 60
    /// Roles that may expose `AXVisibleRows`/`AXVisibleChildren`. The cap itself applies to any element.
    private static let containerRoles: Set<String> = ["AXList", "AXTable", "AXOutline", "AXBrowser", "AXGrid", "AXScrollArea"]
    private static let leafRoles: Set<String> = ["AXStaticText", "AXImage", "AXScrollBar", "AXValueIndicator",
                                                 "AXBusyIndicator", "AXProgressIndicator", "AXSplitter"]

    private static let attrs = [
        kAXRoleAttribute, kAXTitleAttribute, kAXDescriptionAttribute, kAXValueAttribute,
        kAXChildrenAttribute, kAXPositionAttribute, kAXSizeAttribute, kAXFocusedAttribute, kAXSubroleAttribute,
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
        let anticipating = gate.anticipationWouldRun
        let view = scan(query: nil, anticipating: anticipating)
        lastView = view
        generation += 1
        if anticipating {
            gate.anticipate { [weak self] app, wanted in self?.anticipationCandidates(view, app: app, wanted: wanted) ?? [] }
        }
        let text = render(view, query: nil)
        return gate.showsOnlyControls(cloud: cloudEngine) ? Self.controlsOnly(text) : text
    }

    private func observe(query: String?) -> String {
        generation += 1
        let anticipating = query == nil && gate.anticipationWouldRun
        let view = scan(query: query, anticipating: anticipating)
        if query == nil {
            lastView = view
            // A new observation: the second layer judges its controls while the engine thinks.
            if anticipating {
                gate.anticipate { [weak self] app, wanted in self?.anticipationCandidates(view, app: app, wanted: wanted) ?? [] }
            } else {
                gate.cancelAnticipation()
            }
        }
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
        } else if view.capped {
            lines.append("(long lists show only their visible part: scroll, or use observe with a query, for the rest)")
        }
        return lines.joined(separator: "\n")
    }

    /// `anticipating`: also collect the controls and the focus position for the judgement in advance.
    private func scan(query: String?, anticipating: Bool = false) -> View {
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
        let focused = AX.focusedElement(in: app)
        view.focus = Self.describeFocus(focused)
        if anticipating { view.focusFrame = focused.flatMap { AX.frame($0) } }
        view.selection = focused.flatMap { AX.string($0, kAXSelectedTextAttribute) }
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
        let fixedCost = AppSettings.shared.fixedCostObservation
        let maxItems = needle == nil ? 220 : 60
        // Fixed cost: a time budget under a second for the plain observation (FR-44).
        let deadline: TimeInterval = needle == nil ? (fixedCost ? 0.9 : 1.8) : 4.0
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
                    // The same rule as type_text and get_text (FR-52): subrole, or unreadable single-line field.
                    if (v[8] as? String) == "AXSecureTextField" || (role == "AXTextField" && v[8] == nil && AX.isSecureField(el)) {
                        line += " (password field: content never read)"
                    } else if Self.textInputRoles.contains(role), !value.isEmpty {
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
                        if anticipating, clickable, f.width > 0, f.height > 0, wf.intersects(f) { view.controls.append((id, role, f)) }
                    }
                    view.items.append((id, line))
                }
            }
            if depth < 60, var children = v[4] as? [AXUIElement] {
                let childrenInWeb = inWeb || role == "AXWebArea"
                if fixedCost, needle == nil {
                    // Fixed cost (FR-44, AD-19): leaves bring nothing below them; a long element offers
                    // what is visible, at most `Self.perContainer` children, so one long list never
                    // takes the budget of the toolbar.
                    if Self.leafRoles.contains(role) { children = [] }
                    if children.count > Self.perContainer {
                        var candidates = children
                        var extra: [AXUIElement] = []
                        if Self.containerRoles.contains(role),
                           let v = (AX.value(el, "AXVisibleRows") ?? AX.value(el, "AXVisibleChildren")) as? [AXUIElement], !v.isEmpty {
                            candidates = v
                            // Headers, columns and sort buttons are not rows: they stay.
                            if role == "AXTable" || role == "AXOutline" { extra = Array(children.filter { AX.role($0) != "AXRow" }.prefix(10)) }
                        }
                        // Some apps (Safari lists) call every child «visible»: keep the ones whose frame is
                        // in the window, never simply the first ones of the list.
                        var visible: [AXUIElement] = []
                        if candidates.count > Self.perContainer, let wf = windowFrame {
                            let area = wf.insetBy(dx: -4, dy: -4)
                            for c in candidates where visible.count < Self.perContainer {
                                if let f = AX.frame(c), area.intersects(f) { visible.append(c) }
                                else if !visible.isEmpty { break } // past the visible block of the list
                            }
                        } else {
                            visible = candidates
                        }
                        children = extra + Array((visible.isEmpty ? candidates : visible).prefix(Self.perContainer))
                        view.capped = true
                    }
                }
                for c in children { queue.append((c, depth + 1, childrenInWeb)) }
            }
        }
        if let webArea { lastWebArea = webArea }
        return view
    }

    /// «textfield «Nome»», «webarea», «none»: the focused element in a few words.
    private static func describeFocus(_ focused: AXUIElement?) -> String {
        guard let f = focused else { return "" }
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
            return try await zoom(region, forceImage: (a["image"] as? Bool) == true)
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

    /// Seconds of each `read_text` of this request, for the Bench (Story 8.3).
    private(set) var readTextSeconds: [Double] = []

    /// The text of the window or of a region of the latest screenshot, read on the Mac (FR-47).
    private func readText(_ a: [String: Any]) async throws -> Result {
        onProgress?("Leggo il testo…")
        guard ScreenCapture.hasPermission else {
            ScreenCapture.requestPermission()
            return .error("Screen Recording permission not granted. Use observe instead.")
        }
        let started = Date()
        let scale = NSScreen.main?.backingScaleFactor ?? 2
        let full = try await ScreenCapture.frontWindow(maxSide: 8000, scaleFactor: scale)
        let sx = CGFloat(full.image.width) / full.windowFrame.width
        let sy = CGFloat(full.image.height) / full.windowFrame.height
        var crop = CGRect(x: 0, y: 0, width: full.image.width, height: full.image.height)
        if a["region"] != nil {
            guard let raw = a["region"] as? [Any], raw.count == 4, case let r = raw.compactMap(Self.double), r.count == 4 else {
                return .error("region must be four numbers [x0, y0, x1, y1] in coordinates of the latest screenshot.")
            }
            guard let shot = lastShot else { return .error("region uses the coordinates of a screenshot: take one, or call read_text without region for the whole window.") }
            let p0 = shot.screenPoint(imageX: min(r[0], r[2]), imageY: min(r[1], r[3]))
            let p1 = shot.screenPoint(imageX: max(r[0], r[2]), imageY: max(r[1], r[3]))
            crop = CGRect(x: (p0.x - full.windowFrame.minX) * sx, y: (p0.y - full.windowFrame.minY) * sy,
                          width: (p1.x - p0.x) * sx, height: (p1.y - p0.y) * sy).integral
                .intersection(CGRect(x: 0, y: 0, width: full.image.width, height: full.image.height))
        }
        guard !crop.isEmpty, let image = full.image.cropping(to: crop) else {
            return .error("The region is empty or outside the window: use coordinates of the latest screenshot.")
        }
        guard let lines = await TextReader.shared.read(image) else {
            return .text("Text not readable right now (text recognition still loading or too slow): try again, or take a screenshot.").asReadOnly
        }
        readTextSeconds.append(Date().timeIntervalSince(started))
        guard !lines.isEmpty else { return .text("No text found there.").asReadOnly }
        // Positions in window points, like observe.
        let rows = TextReader.ordered(lines)
            .map { l -> String in
                let x = Int((crop.minX + l.box.minX) / sx), y = Int((crop.minY + l.box.minY) / sy)
                return "«\(l.text)» @\(x),\(y) \(Int(l.box.width / sx))x\(Int(l.box.height / sy))"
            }
        return .text("Text read on the Mac (\(rows.count) lines):\n" + rows.joined(separator: "\n")).asReadOnly
    }

    /// A region of the latest screenshot at full (Retina) resolution, like Claude's `zoom`.
    private func zoom(_ r: [Double], forceImage: Bool = false) async throws -> Result {
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
        // The text of the region, read on the Mac (FR-47). When it is read with confidence, it
        // replaces the image: the picture does not have to go to the cloud to be read.
        let hint = " For click x/y keep using the coordinates of the full screenshot."
        if let image = full.image.cropping(to: crop.integral), let lines = await TextReader.shared.read(image, limit: 2), !lines.isEmpty {
            let text = TextReader.ordered(lines).map(\.text)
            let confident = lines.map(\.confidence).reduce(0, +) / Float(lines.count) >= 0.8
            // Only text, when it is read with confidence and covers a good part of the region.
            let covered = lines.reduce(0) { $0 + $1.box.width * $1.box.height } / max(1, crop.width * crop.height)
            if confident, covered > 0.15, !forceImage {
                return .text("Text of region \(r.map { String(Int($0)) }.joined(separator: ",")), read on the Mac (the image was not needed):\n"
                             + text.map { "«\($0)»" }.joined(separator: "\n")
                             + "\nTo see the region itself (colors, icons, layout), call screenshot with the same region and image: true." + hint)
            }
            return Result(content: [
                ["type": "image", "data": jpeg.base64EncodedString(), "mimeType": "image/jpeg"],
                ["type": "text", "text": "Zoom of \(r.map { String(Int($0)) }.joined(separator: ",")) at full resolution (\(Int(size.width))x\(Int(size.height)) px). Text read on the Mac" + (confident ? ": " : " (uncertain): ") + text.map { "«\($0)»" }.joined(separator: " · ") + "." + hint],
            ])
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
            // Text or an icon inside a control: the control is what gets pressed (FR-51), «➤» inside «Invia».
            // Also any element that cannot be pressed itself: the click goes to the container.
            let container: () -> String? = {
                guard ["AXStaticText", "AXImage", "AXGroup"].contains(AX.role(item.element)) || !AX.actions(item.element).contains(kAXPressAction),
                      let outer = Self.pressableAncestor(item.element) else { return nil }
                return Self.ownLabel(outer)
            }
            if let refusal = await gate.confirmClick(id: id, label: label, container: container, origin: .model) {
                return .error(refusal)
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
            // A click by coordinates is judged on what is under the point (FR-51): «Invia» stays «Invia».
            if let p = point, let hit = AX.labelAt(p),
               let refusal = await gate.confirmIfRiskyLabel(hit, target: .element(id: 0, action: "click x/y"), verb: "clicchi", origin: .model) {
                return .error(refusal)
            }
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
                // Safari may report the new value a moment later: read again (4 × 50 ms) while the value
                // is missing or still the old one, before taking it as the end.
                func fresh(after old: Double) async -> Double? {
                    var read = (AX.value(item.element, kAXValueAttribute) as? NSNumber)?.doubleValue
                    for _ in 0..<4 where read == nil || read == old {
                        try? await Task.sleep(for: .milliseconds(50))
                        if Task.isCancelled { break }
                        read = (AX.value(item.element, kAXValueAttribute) as? NSNumber)?.doubleValue
                    }
                    return read
                }
                var value = start
                var steppedBackFrom: Double?
                for _ in 0..<500 where abs(value - target) > 0.001 {
                    if Task.isCancelled { break }
                    AXUIElementPerformAction(item.element, (value < target ? "AXIncrement" : "AXDecrement") as CFString)
                    guard let next = await fresh(after: value), next != value else { break }
                    // Overshoot with big steps: stop at the closest value.
                    if (value < target) != (next < target), abs(next - target) > abs(value - target) {
                        AXUIElementPerformAction(item.element, (next < target ? "AXIncrement" : "AXDecrement") as CFString)
                        steppedBackFrom = next
                        break
                    }
                    value = next
                }
                // The value shown after the step back, not the one before it.
                if let from = steppedBackFrom { _ = await fresh(after: from) }
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
        if let refusal = await gate.confirmIfRiskyLabel(item.label, also: [Self.actionName(raw)], target: .element(id: id, action: Self.actionName(raw)),
                                                        verb: "esegua «\(Self.actionName(raw))» su", origin: .model) {
            return .error(refusal)
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
        if let refusal = await gate.confirmIfRiskyLabel(toLabel, target: .drop(onto: Self.int(a["to_id"]), label: toLabel), verb: "trascini «\(fromLabel)» su",
                                                        scenario: "trascinamento verso un bersaglio rischioso", origin: .model) {
            return .error(refusal)
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
            if let refusal = await gate.confirmIfRiskyLabel(item.title, target: .menu(path: walked), verb: "scelga dal menu", origin: .model) {
                return .error(refusal)
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
            Log.debug("Agente → act \(i + 1). \(name) \(Log.isDetailed ? Self.compact(args) : Self.shape(args))")
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
        if let d = v as? Double { return Int(exactly: d) } // NaN or a huge id from the model must not crash
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

    /// Arguments without their text, for the normal log: «type_text {"text":"«42 car.»"}».
    private static let plainArgs: Set<String> = ["method", "modifiers", "keys", "direction", "mode", "browser", "count", "amount"]
    static func shape(_ args: [String: Any]) -> String {
        var copy: [String: Any] = [:]
        for (k, v) in args {
            if let s = v as? String {
                if k == "url" { copy[k] = URL(string: s.contains("://") ? s : "https://" + s)?.host ?? "«\(s.count) car.»" }
                else { copy[k] = plainArgs.contains(k) || k == "app" ? s : "«\(s.count) car.»" }
            } else if let list = v as? [Any], k != "ids", k != "region" {
                copy[k] = "\(list.count) elementi"
            } else {
                copy[k] = v
            }
        }
        let data = (try? JSONSerialization.data(withJSONObject: copy, options: [.sortedKeys])) ?? Data()
        return String(data: data, encoding: .utf8) ?? ""
    }

    private static func compact(_ args: [String: Any]) -> String {
        var copy = args
        if let t = copy["text"] as? String, t.count > 60 { copy["text"] = String(t.prefix(60)) + "…" }
        let data = (try? JSONSerialization.data(withJSONObject: copy, options: [.sortedKeys])) ?? Data()
        return String(data: data, encoding: .utf8) ?? ""
    }
}
