import AppKit
import ApplicationServices

/// Who proposed an action (FR-56). The gate judges only what a model proposed: quick commands,
/// dictation, numbers and macros come from the user and never pass through it.
enum ActionOrigin: String {
    case user
    case model
}

/// The one gate every action proposed by a model goes through (AD-21, AD-22, FR-51…FR-56):
/// access level of the app in front, password fields, «conferma ogni azione», the second layer and
/// the confirmation question with its grant. The callers gather the facts (resolved element,
/// labels, actions to judge) and ask the gate; the decisions, the counters and the log lines live here.
@MainActor
final class AccessGate {

    // MARK: Wiring

    /// Asks the user something by voice. `confirmation` = yes/no question. Returns nil on timeout.
    var askUser: ((String, Bool) async -> String?)?
    /// Start (`true`) and end of a question to the user: the turn's clock waits (AD-24).
    var onQuestion: ((Bool) -> Void)?
    /// «🔐 Terminal: solo clic», when the app in front has a level (FR-54).
    var onAccessNotice: ((String) -> Void)?
    /// Seconds spent judging, for the «classificatore» phase of the Banco.
    var onClassified: ((Double) -> Void)?
    /// Replaces the model in the tests: a fixed verdict, so the gate around it is what is tested.
    var riskJudge: ((RiskAction) async -> RiskVerdict)?
    let riskClassifier = OnDeviceRiskClassifier()

    /// What the gate reads of the Mac. Replaced by `--selftest`, which checks the gate without a screen.
    @MainActor struct Environment {
        var level: () -> AccessLevel = { PrivacyGuard.accessLevel() }
        /// The name of the app in front, as the user sees it.
        var appName: () -> String? = { AX.frontmostApplication()?.localizedName }
        /// The app really in front: a «sì» given after a change of app is not used.
        var frontPID: () -> pid_t? = { AX.realFrontmostApplication()?.processIdentifier }
        /// The focused field is a password field (for the tools without an element).
        var focusedFieldIsSecure: () -> Bool = { ScreenContext.capture(includeLabels: false).isSecure }
        /// The second layer is on in the settings.
        var secondLayerOn: () -> Bool = { AppSettings.shared.riskClassifier }
        /// The bundle id of the app in front, for the shortcuts that are risky only in some apps.
        var bundleID: () -> String? = { AX.frontmostApplication()?.bundleIdentifier }
        /// The title of the window in front: the window a «sì» to a shortcut is for.
        var windowTitle: () -> String = { ScreenContext.capture(includeLabels: false).windowTitle }
        /// The chat in front where Enter sends the message (its name), or nil.
        var composerApp: () -> String? = { AccessGate.composerApp() }
    }
    var environment = Environment()

    /// The facts the caller knows about the action: the gate decides on them.
    @MainActor struct ActionFacts {
        /// Whether the element of an id is a password field; nil when the id is unknown (the gate
        /// then judges the focused field, as for a tool without an element).
        var isSecureElement: (Int) -> Bool?
        /// The actions as the second layer sees them, for the app in front (none: nothing to judge).
        var riskActions: (_ app: String) -> [RiskAction]
    }

    // MARK: State of the request

    /// The request of this task, to tell the user when an action was not asked for.
    var currentRequest = ""
    /// The user said «no» (or did not answer) to an action in this request: no level retries it.
    private(set) var deniedThisRequest = false
    /// Bench counters (FR-41): confirmations asked, and actions stopped without a «sì».
    private(set) var confirmationsAsked = 0
    /// Actions with external effects not done because the user did not say «sì».
    private(set) var deniedConfirmations = 0
    /// Calls refused by the access level or by a password field (read by the security suite).
    var refusals = 0
    /// The target of the last question, for the tests.
    private(set) var lastTarget: ConfirmationTarget?
    /// The access level shown last in the HUD, to show a change of app once.
    private var lastAccessNotice = ""
    /// One verdict per action (tool, label, role, app, window, dialog), across requests; emptied at 500.
    private var riskCache: [String: RiskVerdict] = [:]

    /// Fresh state for a new request. `keepCounters`: the same request retried on another engine
    /// (AD-15) keeps what the first one asked.
    func reset(keepCounters: Bool = false) {
        deniedThisRequest = false
        if !keepCounters {
            lastAccessNotice = ""
            confirmationsAsked = 0
            deniedConfirmations = 0
        }
    }

    // MARK: Before the action

    /// The tools a «solo clic» app allows.
    static let clickOnlyTools: Set<String> = ["click", "click_many", "scroll", "hover", "open_app"]
    /// Tools that write text or change a value: never in a password field.
    static let writingTools: Set<String> = ["type_text", "replace_text", "edit_text", "set_value", "select_text", "press_keys"]
    static let toolWords: [String: String] = [
        "click": "il clic", "click_many": "i clic", "type_text": "la scrittura", "replace_text": "la modifica del testo",
        "edit_text": "la modifica del testo", "press_keys": "i tasti", "drag": "il trascinamento", "menu": "la voce di menu",
        "set_value": "la modifica del valore", "perform_action": "l'azione", "select_text": "la selezione", "scroll": "lo scorrimento",
        "hover": "il passaggio del mouse", "open_app": "l'apertura dell'app", "open_url": "l'apertura dell'indirizzo",
        "save_macro": "il salvataggio della macro", "delete_macro": "l'eliminazione della macro", "act": "la serie di azioni",
    ]
    private static let riskVerb = ["click": "clicchi", "click_many": "clicchi", "perform_action": "esegua", "menu": "scelga"]

    /// The checks before a tool runs, in this order: access level («solo clic»), password field,
    /// «conferma ogni azione», second layer. nil to go on; otherwise the error for the engine.
    /// Actions of the user are not judged.
    func check(_ name: String, _ args: [String: Any], origin: ActionOrigin, facts: ActionFacts) async -> String? {
        guard origin == .model else { return nil }
        let effectful = AgentTools.effectfulTools.contains(name)
        // Access level of the app in front (FR-54, AD-22): the same rules for every engine.
        let level = environment.level()
        let app = environment.appName() ?? "questa app"
        if level.scope != .full, "\(app)|\(level.scope)" != lastAccessNotice {
            lastAccessNotice = "\(app)|\(level.scope)"
            onAccessNotice?("🔐 \(app): \(level.scope.rawValue)")
        }
        if level.scope == .clickOnly, effectful, !Self.clickOnlyTools.contains(name) {
            Log.info("Agente: \(name) bloccato, \(app) è «solo clic»")
            refusals += 1
            return "In «\(app)» the agent may only click and scroll (access level set by the user). Do not type or press keys here; tell the user in one short Italian sentence."
        }
        // Never write in a password field, with any tool (FR-52).
        if Self.writingTools.contains(name), passwordTarget(name, args, facts) {
            refusals += 1
            Log.info("Agente: \(name) bloccato, campo password")
            return "That is a password field: the agent never reads or types there. Tell the user to type it themselves."
        }
        // «Conferma ogni azione»: one question for the action; the specific checks (Elimina, Invio in
        // a chat) still ask on their own, with their own target.
        if level.scope == .confirmAll, effectful,
           !(await confirm(Self.levelTarget(name, args), label: "\(Self.toolWords[name] ?? "l'azione") in \(app)",
                           verb: "faccia", scenario: "app con conferma per ogni azione", origin: origin)) {
            return Self.denied("\(Self.toolWords[name] ?? name) in \(app)")
        }
        // Second layer (Story 9.5, FR-55): where the fixed rules do not ask, the on-device model may
        // add a confirmation. «Conferma ogni azione» already asked for this call.
        if level.scope != .confirmAll, environment.secondLayerOn(), riskJudge != nil || OnDeviceRiskClassifier.isAvailable {
            for action in facts.riskActions(app) {
                let verdict: RiskVerdict
                if let cached = riskCache[action.cacheKey] {
                    verdict = cached
                    Log.debug("Sicurezza: secondo strato · \(name) · \(cached.external ? "esterno" : "interno") · dalla cache")
                } else {
                    verdict = await (riskJudge ?? riskClassifier.judge)(action)
                    // Greedy: the same prompt gives the same verdict, so it is kept across requests (the
                    // dialog text is in the key). Timeouts and errors are never kept.
                    if verdict.source.hasPrefix("on-device") {
                        if riskCache.count > 500 { riskCache.removeAll() }
                        riskCache[action.cacheKey] = verdict
                    }
                    onClassified?(verdict.seconds)
                    Log.info(String(format: "Sicurezza: secondo strato · %@ «%d caratteri» · %@ · %@ · %.2f s", name, action.label.count,
                                    verdict.external ? "esterno" : "interno", verdict.source, verdict.seconds))
                }
                if verdict.external,
                   !(await confirm(Self.levelTarget(name, args), label: action.label, verb: Self.riskVerb[name] ?? "faccia",
                                   scenario: "secondo strato", origin: origin)) {
                    return Self.denied(action.label)
                }
            }
        }
        return nil
    }

    /// Cloud engines in a «solo clic» app see only the controls, never text or images (FR-54).
    func showsOnlyControls(cloud: Bool) -> Bool {
        cloud && environment.level().scope == .clickOnly
    }

    /// Tools that read the text or the image of the window.
    private static let windowReadingTools: Set<String> = ["screenshot", "get_text", "read_text"]

    /// The error for a cloud engine that asks for text or images of a «solo clic» app (FR-54), or nil.
    func cloudReadRefusal(_ name: String, cloud: Bool) -> String? {
        guard Self.windowReadingTools.contains(name), showsOnlyControls(cloud: cloud) else { return nil }
        return "In this app (access level «solo clic») the cloud engines get no text or images of the window: use observe, which shows the controls."
    }

    // MARK: Fixed rules (FR-51, AD-21)

    /// A label the fixed rules stop (Invia, Elimina, Paga…): the second layer leaves it to them.
    static func fixedRuleAsks(_ label: String) -> Bool { Safety.isRiskyLabel(label) }

    /// Asks when `label` (or one of `also`, e.g. the name of an accessibility action) is one the fixed
    /// rules stop. nil to go on; otherwise the error for the engine.
    func confirmIfRiskyLabel(_ label: String, also: [String] = [], target: ConfirmationTarget, verb: String,
                             scenario: String = "azione con effetti esterni", origin: ActionOrigin) async -> String? {
        guard Self.fixedRuleAsks(label) || also.contains(where: Self.fixedRuleAsks) else { return nil }
        return await confirm(target, label: label, verb: verb, scenario: scenario, origin: origin) ? nil : Self.denied(label)
    }

    /// A click on element `id`: its own label, or else the label of the control around it (the text «➤»
    /// inside «Invia»), read only when needed. nil to go on; otherwise the error for the engine.
    func confirmClick(id: Int, label: String, container: () -> String?, origin: ActionOrigin) async -> String? {
        if Self.fixedRuleAsks(label) {
            return await confirmIfRiskyLabel(label, target: .element(id: id, action: "click"), verb: "clicchi", origin: origin)
        }
        guard let name = container() else { return nil }
        return await confirmIfRiskyLabel(name, target: .element(id: id, action: "click"), verb: "clicchi", origin: origin)
    }

    /// Text typed with a line break in a chat sends the message, like Enter (FR-51).
    func confirmTypedText(_ text: String, origin: ActionOrigin) async -> String? {
        guard text.contains("\n") || text.contains("\r"), let app = environment.composerApp() else { return nil }
        return await confirmSend(in: app, origin: origin)
    }

    /// Keys that send, delete or close (⌘⇧D in Mail, cmd+q…), then Enter in a chat. nil to go on.
    func confirmKeys(_ keys: String, origin: ActionOrigin) async -> String? {
        if Safety.isRiskyKeys(keys, app: environment.bundleID()),
           !(await confirm(.shortcut(keys: keys, window: environment.windowTitle()), label: keys, verb: "prema", origin: origin)) {
            return Self.denied(keys)
        }
        if Self.containsSendKey(keys), let app = environment.composerApp() {
            return await confirmSend(in: app, origin: origin)
        }
        return nil
    }

    private func confirmSend(in app: String, origin: ActionOrigin) async -> String? {
        await confirm(.keyInComposer(app: app), label: "Invio in \(app)", verb: "prema",
                      scenario: "invio in un campo di composizione", origin: origin) ? nil : Self.denied("Invio in \(app)")
    }

    /// Return or Enter alone.
    static func isSendKey(_ keys: String) -> Bool {
        ["return", "enter", "invio"].contains(keys.lowercased().trimmingCharacters(in: .whitespaces))
    }

    /// A sequence with a plain Return or Enter in it («tab return»), not cmd+return (that one is a shortcut).
    static func containsSendKey(_ keys: String) -> Bool {
        keys.split(separator: " ").contains { isSendKey(String($0)) }
    }

    /// Apps where Enter in the text field sends the message (chats).
    private static let chatApps: Set<String> = ["com.apple.MobileSMS", "net.whatsapp.WhatsApp", "com.tinyspeck.slackmacgap",
                                                "ru.keepcoder.Telegram", "com.hnc.Discord", "com.microsoft.teams2", "org.whispersystems.signal-desktop"]
    /// The chat in front where Enter sends: its name, or nil.
    static func composerApp() -> String? {
        guard let app = AX.frontmostApplication(), let id = app.bundleIdentifier else { return nil }
        let title = Grammar.normalize(ScreenContext.capture(includeLabels: false).windowTitle)
        return needsComposerGate(bundleID: id, windowTitle: title) ? (app.localizedName ?? id) : nil
    }

    /// Chat apps, and chats open in a browser, where Enter sends (pure, tested by `--selftest`).
    static func needsComposerGate(bundleID: String, windowTitle: String) -> Bool {
        if chatApps.contains(bundleID) { return true }
        let webChats = ["whatsapp", "telegram", "messenger", "slack", "discord", "teams", "signal"]
        return webChats.contains { windowTitle.contains($0) }
    }

    /// The target of the «conferma ogni azione» question, from the tool and its arguments.
    static func levelTarget(_ name: String, _ a: [String: Any]) -> ConfirmationTarget {
        if let id = int(a["id"]) { return .element(id: id, action: name) }
        if name == "press_keys", let keys = a["keys"] as? String { return .shortcut(keys: keys, window: "") }
        return .tool(name: name)
    }

    /// The tool would write in a password field: its target, or the focused field when it has none.
    private func passwordTarget(_ name: String, _ a: [String: Any], _ facts: ActionFacts) -> Bool {
        if let id = Self.int(a["id"]), let secure = facts.isSecureElement(id) { return secure }
        // No element, or an id the caller does not know: the focused field decides (fail closed).
        guard environment.focusedFieldIsSecure() else { return false }
        // In a password field only moving away is allowed: Tab, Escape, arrows.
        if name == "press_keys", let keys = a["keys"] as? String {
            let moves: Set<String> = ["tab", "shift+tab", "escape", "esc", "up", "down", "left", "right"]
            return !keys.lowercased().split(separator: " ").allSatisfy { moves.contains(String($0)) }
        }
        return true
    }

    private static func int(_ v: Any?) -> Int? {
        if let i = v as? Int { return i }
        // Only whole finite numbers: a NaN or a huge id from the model must not crash, 5.7 is not 5.
        if let d = v as? Double { return Int(exactly: d) }
        if let s = v as? String { return Int(s) }
        return nil
    }

    // MARK: Confirmation (FR-51, FR-53, AD-21)

    /// What a «sì» is for: one action on one target, in this request and this window. Never a time window.
    enum ConfirmationTarget: Equatable, CustomStringConvertible {
        case element(id: Int, action: String)
        case shortcut(keys: String, window: String)
        case keyInComposer(app: String)
        case drop(onto: Int?, label: String)
        case menu(path: [String])
        /// A tool without a precise element («conferma ogni azione»): open_url, scroll, act…
        case tool(name: String)

        var description: String {
            switch self {
            case .element(let id, let action): return "elemento \(id) · \(action)"
            case .shortcut(let keys, let window): return "scorciatoia \(keys) · \(window)"
            case .keyInComposer(let app): return "Invio nella composizione · \(app)"
            case .drop(let id, let label): return "trascinamento su \(id.map(String.init) ?? "x/y") «\(label)»"
            case .menu(let path): return "menu \(path.joined(separator: " > "))"
            case .tool(let name): return "strumento \(name)"
            }
        }

        /// For the log without detail: the kind of target, no text read on screen (AD-9).
        var kind: String {
            switch self {
            case .element(let id, let action): return "elemento \(id) · \(action)"
            case .shortcut(let keys, _): return "scorciatoia \(keys)"
            case .keyInComposer: return "Invio nella composizione"
            case .drop(let id, _): return "trascinamento su \(id.map(String.init) ?? "x/y")"
            case .menu(let path): return "menu (\(path.count) livelli)"
            case .tool(let name): return "strumento \(name)"
            }
        }
    }

    /// The call stops here, asks the user about this target and goes on only with a «sì»: the grant
    /// is used by this action and ends with it. No extra round trip to the engine.
    func confirm(_ target: ConfirmationTarget, label: String, verb: String,
                 scenario: String = "azione con effetti esterni", origin: ActionOrigin) async -> Bool {
        guard origin == .model else { return true }
        confirmationsAsked += 1
        lastTarget = target
        let notAsked = !Self.requestMentions(currentRequest, label)
        let question = "Vuoi che \(verb) «\(label)»\(notAsked ? ", che tu non hai chiesto" : "")?"
        let front = environment.frontPID()
        let levelBefore = environment.level().scope.rawValue
        let answer: String?
        do {
            onQuestion?(true)
            defer { onQuestion?(false) }
            answer = await askUser?(question, true)
        }
        var ok = answer.map(Grammar.isYes) ?? false
        // The «sì» is for the window the question was about: if the user changed app meanwhile, no.
        if ok, environment.frontPID() != front {
            ok = false
            Log.info("Sicurezza: «sì» non usato, l'app in primo piano è cambiata durante la domanda")
        }
        if !ok { deniedConfirmations += 1; deniedThisRequest = true }
        logBlock(scenario: scenario, target: target, label: label, origin: origin,
                 outcome: ok ? "confermata" : (answer == nil ? "senza risposta" : "negata"))
        if !ok, Log.isDetailed {
            // A blocked action, ready to become a row of Tests/bench/sicurezza.tsv (Story 9.4): copy what
            // follows «→». Page and allowed changes depend on the test page, so they stay to fill in.
            Log.debug("Sicurezza: riga per sicurezza.tsv →\n" + Self.scenarioRow(label: label, level: levelBefore, request: currentRequest))
        }
        return ok
    }

    /// The error for the engine when the user did not confirm.
    static func denied(_ what: String) -> String {
        "The user did not confirm «\(what)»: it was NOT done. Do not try it another way; tell the user it was cancelled."
    }

    // MARK: Log (Story 9.4)

    /// id · pagina · livello · richiesta · blocco atteso · cambi ammessi, with no tab or newline inside a field.
    static func scenarioRow(label: String, level: String, request: String) -> String {
        func clean(_ s: String) -> String { s.replacingOccurrences(of: "\t", with: " ").replacingOccurrences(of: "\n", with: " ") }
        let slug = Grammar.normalize(label).split(separator: " ").prefix(3).joined(separator: "-")
        return ["blocco-" + (slug.isEmpty ? "azione" : slug), "<pagina>", level, clean(request), "domanda", ""].joined(separator: "\t")
    }

    /// One line per blocked action, in the format the security suite reuses (Story 9.4).
    static func logLine(scenario: String, app: String, target: ConfirmationTarget, label: String,
                        origin: ActionOrigin = .model, outcome: String) -> String {
        "Sicurezza: blocco · scenario=\(scenario) · app=\(app) · bersaglio=\(target) «\(label)» · origine=\(origin.rawValue) · esito=\(outcome)"
    }

    /// The same line for the log without detail: the kind of target and the length of its label (AD-9).
    static func shortLogLine(scenario: String, app: String, target: ConfirmationTarget, label: String,
                             origin: ActionOrigin = .model, outcome: String) -> String {
        "Sicurezza: blocco · scenario=\(scenario) · app=\(app) · bersaglio=\(target.kind) («\(label.count) caratteri») · origine=\(origin.rawValue) · esito=\(outcome)"
    }

    private func logBlock(scenario: String, target: ConfirmationTarget, label: String, origin: ActionOrigin, outcome: String) {
        let app = environment.appName() ?? "?"
        Log.info(Log.isDetailed ? Self.logLine(scenario: scenario, app: app, target: target, label: label, origin: origin, outcome: outcome)
                 : Self.shortLogLine(scenario: scenario, app: app, target: target, label: label, origin: origin, outcome: outcome))
    }

    /// Whether the request names the target (otherwise the question says «che tu non hai chiesto»).
    static func requestMentions(_ request: String, _ label: String) -> Bool {
        let rq = request.lowercased()
        // A negated request («non eliminare niente») never counts as asking for it.
        if rq.hasPrefix("non ") || rq.contains(" non ") { return false }
        // Short targets (cmd+q, OK, Buy): the target as a whole word of the request.
        let tokens = rq.split(whereSeparator: { $0 == " " || $0 == "," }).map(String.init)
        if label.count <= 6, tokens.contains(label.lowercased()) { return true }
        let words = Grammar.normalize(request).split(separator: " ").map(String.init)
        // Whole words, or the same root (eliminare / elimina): at least 5 shared letters, never
        // «post» inside «posta».
        func sameRoot(_ a: String, _ b: String) -> Bool {
            let shared = zip(a, b).prefix { $0 == $1 }.count
            // The shorter word whole at the start of the other (elimina / eliminare): «inoltra» and
            // «inoltre» share 6 letters but are different words.
            return shared >= 5 && shared == min(a.count, b.count)
        }
        // «Invio in WhatsApp», «il clic in Safari»: the app name is not the target.
        let target = label.components(separatedBy: " in ").first ?? label
        let labelWords = Grammar.normalize(target).split(separator: " ").map(String.init)
        if labelWords.filter({ $0.count >= 4 }).contains(where: { w in words.contains { $0 == w || sameRoot($0, w) } }) { return true }
        // The same action said another way: «manda» for «Invia», «butta» for «Cestino». Exact words
        // only: a shared root would let «inoltre» stand for «inoltra».
        return synonymGroups.contains { group in
            words.contains(where: group.contains) && labelWords.contains(where: group.contains)
        }
    }

    private static let synonymGroups: [Set<String>] = [
        ["invia", "invio", "inviala", "invialo", "manda", "mandala", "mandalo", "mandagli", "mandale", "spedisci", "spediscila", "send", "return"],
        ["elimina", "eliminala", "eliminalo", "butta", "buttala", "buttalo", "cestino", "delete", "trash"],
        ["paga", "pagala", "compra", "acquista", "checkout"],
        ["clic", "clicca", "cliccaci", "premi", "spunta", "seleziona"],
        ["scrittura", "scrivi", "digita", "inserisci"],
    ]
}
