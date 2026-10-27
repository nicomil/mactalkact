import AppKit
import ApplicationServices

/// Thin helpers over the macOS Accessibility API (AXUIElement).
enum AX {
    static func value(_ el: AXUIElement, _ attr: String) -> CFTypeRef? {
        var v: CFTypeRef?
        return AXUIElementCopyAttributeValue(el, attr as CFString, &v) == .success ? v : nil
    }

    static func string(_ el: AXUIElement, _ attr: String) -> String? {
        value(el, attr) as? String
    }

    static func element(_ el: AXUIElement, _ attr: String) -> AXUIElement? {
        guard let v = value(el, attr), CFGetTypeID(v) == AXUIElementGetTypeID() else { return nil }
        return (v as! AXUIElement)
    }

    static func children(_ el: AXUIElement) -> [AXUIElement] {
        (value(el, kAXChildrenAttribute) as? [AXUIElement]) ?? []
    }

    static func role(_ el: AXUIElement) -> String {
        string(el, kAXRoleAttribute) ?? ""
    }

    static func actions(_ el: AXUIElement) -> [String] {
        var names: CFArray?
        guard AXUIElementCopyActionNames(el, &names) == .success else { return [] }
        return (names as? [String]) ?? []
    }

    static func isSettable(_ el: AXUIElement, _ attr: String) -> Bool {
        var settable: DarwinBoolean = false
        return AXUIElementIsAttributeSettable(el, attr as CFString, &settable) == .success && settable.boolValue
    }

    static func frame(_ el: AXUIElement) -> CGRect? {
        guard let pv = value(el, kAXPositionAttribute), CFGetTypeID(pv) == AXValueGetTypeID(),
              let sv = value(el, kAXSizeAttribute), CFGetTypeID(sv) == AXValueGetTypeID() else { return nil }
        var p = CGPoint.zero, s = CGSize.zero
        guard AXValueGetValue(pv as! AXValue, .cgPoint, &p), AXValueGetValue(sv as! AXValue, .cgSize, &s) else { return nil }
        return CGRect(origin: p, size: s)
    }

    static func selectedRange(_ el: AXUIElement) -> CFRange? {
        guard let v = value(el, kAXSelectedTextRangeAttribute), CFGetTypeID(v) == AXValueGetTypeID() else { return nil }
        var r = CFRange()
        return AXValueGetValue(v as! AXValue, .cfRange, &r) ? r : nil
    }

    @discardableResult
    static func press(_ el: AXUIElement) -> Bool {
        AXUIElementPerformAction(el, kAXPressAction as CFString) == .success
    }

    static func app(_ pid: pid_t) -> AXUIElement {
        let a = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(a, 0.6)
        return a
    }

    private static let chromiumPrefixes = [
        "com.microsoft.edgemac", "com.google.Chrome", "com.brave.Browser", "company.thebrowser",
        "org.chromium", "com.vivaldi", "com.operasoftware", "com.yandex",
    ]
    private nonisolated(unsafe) static var prepared = Set<pid_t>()
    /// Debug only: inspect this app instead of the frontmost one.
    nonisolated(unsafe) static var debugTargetBundle: String?

    /// Chromium browsers and Electron apps only expose their full UI tree (web pages
    /// included) when they believe assistive technology is running. Done once per process.
    static func prepare(_ app: AXUIElement, pid: pid_t, bundleID: String?) {
        guard !prepared.contains(pid) else { return }
        prepared.insert(pid)
        AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        let chromium = bundleID.map { id in chromiumPrefixes.contains(where: id.hasPrefix) } ?? false
        if chromium {
            AXUIElementSetAttributeValue(app, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)
            Log.debug("Accessibilità web attivata per \(bundleID ?? "")")
        }
        // Electron and Chromium build the web tree only now: at the first contact, wait until a web
        // area has children, at most 1 s, so the first observation is not empty (FR-44). The main
        // run loop keeps turning meanwhile; native apps (no Electron framework) never wait.
        let electron = bundleID.flatMap { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) }
            .map { FileManager.default.fileExists(atPath: $0.appendingPathComponent("Contents/Frameworks/Electron Framework.framework").path) } ?? false
        guard (chromium || electron), UserDefaults.standard.object(forKey: "fixedCostObservation") as? Bool ?? true, let window = focusedWindow(in: app) else { return }
        AXUIElementSetMessagingTimeout(app, 0.2)
        defer { AXUIElementSetMessagingTimeout(app, 0) }
        let started = Date()
        while Date().timeIntervalSince(started) < 1, !webAreaReady(window) {
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        Log.debug(String(format: "Accessibilità: albero di %@ pronto in %.2f s", bundleID ?? "", Date().timeIntervalSince(started)))
    }

    /// A password field (FR-52): subrole `AXSecureTextField`, native or web. When the subrole cannot be
    /// read, a single-line text field is treated as one (better a field not read than a password read).
    static func isSecureField(_ el: AXUIElement) -> Bool {
        var v: CFTypeRef?
        let err = AXUIElementCopyAttributeValue(el, kAXSubroleAttribute as CFString, &v)
        if err == .success { return (v as? String) == "AXSecureTextField" }
        let readable: Set<AXError> = [.noValue, .attributeUnsupported]
        guard !readable.contains(err) else { return false }
        // Not readable at all: a text field, or something whose role cannot be read either, is treated as one.
        let r = role(el)
        return r == "AXTextField" || r.isEmpty
    }

    /// The label of the element under a screen point, or of its first labelled ancestor (a click by x/y).
    static func labelAt(_ point: CGPoint) -> String? {
        var el: AXUIElement?
        guard AXUIElementCopyElementAtPosition(AXUIElementCreateSystemWide(), Float(point.x), Float(point.y), &el) == .success,
              var current = el else { return nil }
        func own(_ e: AXUIElement) -> String? {
            [string(e, kAXTitleAttribute), string(e, kAXDescriptionAttribute)]
                .compactMap { $0 }.first { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        }
        for _ in 0..<5 {
            let r = role(current)
            // The page or the window is not the target: their title says nothing about the point.
            if ["AXWebArea", "AXWindow", "AXApplication", "AXScrollArea"].contains(r) { return nil }
            if let label = own(current) { return label }
            if r == "AXStaticText", let text = string(current, kAXValueAttribute), !text.isEmpty { return text }
            // A group without a name (a column, a drop zone): its heading or first text names it.
            if r == "AXGroup", let heading = children(current).first(where: { ["AXHeading", "AXStaticText"].contains(role($0)) }) {
                if let label = own(heading) ?? string(heading, kAXValueAttribute) ?? children(heading).compactMap({ string($0, kAXValueAttribute) }).first,
                   !label.isEmpty { return label }
            }
            guard let parent = value(current, kAXParentAttribute) else { return nil }
            current = parent as! AXUIElement
        }
        return nil
    }

    /// A web area with children within the first nodes of the window (Electron/Chromium ready).
    static func webAreaReady(_ window: AXUIElement) -> Bool {
        var queue = [window]
        var i = 0
        while i < queue.count, i < 300 {
            let el = queue[i]
            i += 1
            if role(el) == "AXWebArea" { return !children(el).isEmpty }
            queue += children(el)
        }
        return false
    }

    /// The app that really has the focus right now. Asked to the Accessibility
    /// system every time: `NSWorkspace.frontmostApplication` can be stale.
    static func frontmostApplication() -> NSRunningApplication? {
        if let override = debugTargetBundle,
           let app = NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == override }) {
            return app
        }
        return realFrontmostApplication()
    }

    /// Like `frontmostApplication`, ignoring the debug override: where keystrokes really go.
    static func realFrontmostApplication() -> NSRunningApplication? {
        let system = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(system, 0.5)
        if let focused = element(system, kAXFocusedApplicationAttribute) {
            var pid: pid_t = 0
            if AXUIElementGetPid(focused, &pid) == .success, let app = NSRunningApplication(processIdentifier: pid) {
                return app
            }
        }
        return NSWorkspace.shared.frontmostApplication
    }

    /// The frontmost app's AX element, prepared for full tree access.
    @MainActor
    static func frontApp() -> (app: AXUIElement, running: NSRunningApplication)? {
        var front = frontmostApplication()
        if let override = debugTargetBundle {
            front = NSWorkspace.shared.runningApplications.first { $0.bundleIdentifier == override }
        }
        guard let front else { return nil }
        let a = app(front.processIdentifier)
        prepare(a, pid: front.processIdentifier, bundleID: front.bundleIdentifier)
        return (a, front)
    }

    static func focusedElement(in app: AXUIElement) -> AXUIElement? {
        let system = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(system, 0.6)
        return element(system, kAXFocusedUIElementAttribute) ?? element(app, kAXFocusedUIElementAttribute)
    }

    static func focusedWindow(in app: AXUIElement) -> AXUIElement? {
        element(app, kAXFocusedWindowAttribute) ?? element(app, kAXMainWindowAttribute)
    }

    /// Reads several attributes in one round-trip (much faster on big trees).
    static func multi(_ el: AXUIElement, _ attrs: [String]) -> [CFTypeRef?] {
        var values: CFArray?
        let err = AXUIElementCopyMultipleAttributeValues(el, attrs as CFArray, AXCopyMultipleAttributeOptions(rawValue: 0), &values)
        guard err == .success, let array = values as? [CFTypeRef], array.count == attrs.count else {
            return Array(repeating: nil, count: attrs.count)
        }
        return array.map { v in
            if CFGetTypeID(v) == AXValueGetTypeID(), AXValueGetType(v as! AXValue) == .axError { return nil }
            return v
        }
    }

    static func rect(position: CFTypeRef?, size: CFTypeRef?) -> CGRect? {
        guard let position, let size, CFGetTypeID(position) == AXValueGetTypeID(), CFGetTypeID(size) == AXValueGetTypeID() else { return nil }
        var p = CGPoint.zero, s = CGSize.zero
        guard AXValueGetValue(position as! AXValue, .cgPoint, &p), AXValueGetValue(size as! AXValue, .cgSize, &s) else { return nil }
        return CGRect(origin: p, size: s)
    }

    static func collapse(_ s: String, max: Int = 80) -> String {
        let one = s.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return one.count > max ? String(one.prefix(max)) + "…" : one
    }
}

/// An element the user could ask to click, with the text they would use for it.
struct LabeledElement {
    let element: AXUIElement
    let label: String
    let role: String
}

enum AXTree {
    private static let interactiveRoles: Set<String> = [
        "AXButton", "AXLink", "AXMenuItem", "AXMenuButton", "AXPopUpButton", "AXCheckBox",
        "AXRadioButton", "AXTab", "AXCell", "AXRow", "AXDisclosureTriangle", "AXComboBox",
        "AXTextField", "AXTextArea", "AXSearchField", "AXMenuBarItem", "AXSwitch", "AXToggle",
    ]
    /// Roles that are sometimes clickable (web divs with click handlers).
    private static let maybeClickable: Set<String> = ["AXGroup", "AXImage", "AXStaticText"]

    /// Breadth-first walk of `root`, collecting labelled clickable elements.
    /// Bounded in nodes and time so a huge web page never freezes the app.
    static func collect(in root: AXUIElement, limit: Int = 400, deadline: TimeInterval = 0.6) -> [LabeledElement] {
        let start = Date()
        let rootFrame = AX.frame(root)
        var queue: [(AXUIElement, Int)] = [(root, 0)]
        var index = 0
        var out: [LabeledElement] = []

        while index < queue.count, out.count < limit, index < 6000,
              Date().timeIntervalSince(start) < deadline {
            let (el, depth) = queue[index]
            index += 1
            let role = AX.role(el)

            var candidate = interactiveRoles.contains(role)
            if !candidate && maybeClickable.contains(role) {
                candidate = AX.actions(el).contains(kAXPressAction)
            }
            if candidate, let label = label(for: el, role: role), !label.isEmpty {
                // Skip elements scrolled far outside the window.
                if let rf = rootFrame, let f = AX.frame(el), f.width > 0, f.height > 0, !rf.insetBy(dx: -20, dy: -20).intersects(f) {
                    // off-screen
                } else {
                    out.append(LabeledElement(element: el, label: label, role: role))
                }
            }
            if depth < 45 {
                for child in AX.children(el) { queue.append((child, depth + 1)) }
            }
        }
        return out
    }

    static func label(for el: AXUIElement, role: String) -> String? {
        for attr in [kAXTitleAttribute, kAXDescriptionAttribute] {
            if let s = AX.string(el, attr), !s.trimmingCharacters(in: .whitespaces).isEmpty { return AX.collapse(s) }
        }
        let isText = ["AXTextField", "AXTextArea", "AXSearchField", "AXComboBox"].contains(role)
        if isText {
            if let p = AX.string(el, kAXPlaceholderValueAttribute), !p.isEmpty { return AX.collapse(p) }
        } else if let v = AX.string(el, kAXValueAttribute), !v.trimmingCharacters(in: .whitespaces).isEmpty {
            return AX.collapse(v)
        }
        if let h = AX.string(el, kAXHelpAttribute), !h.isEmpty { return AX.collapse(h) }
        // Links and cells often carry their text in a child static text.
        for child in AX.children(el).prefix(4) {
            if let v = AX.string(child, kAXValueAttribute) ?? AX.string(child, kAXTitleAttribute),
               !v.trimmingCharacters(in: .whitespaces).isEmpty {
                return AX.collapse(v)
            }
            for grand in AX.children(child).prefix(3) {
                if let v = AX.string(grand, kAXValueAttribute), !v.trimmingCharacters(in: .whitespaces).isEmpty {
                    return AX.collapse(v)
                }
            }
        }
        return nil
    }
}

extension AXTree {
    struct Clickable {
        let element: AXUIElement
        let frame: CGRect   // global, top-left origin
        let role: String
        let label: String
    }

    private static let markRoles: Set<String> = [
        "AXButton", "AXLink", "AXMenuButton", "AXPopUpButton", "AXCheckBox", "AXRadioButton", "AXTab",
        "AXCell", "AXRow", "AXDisclosureTriangle", "AXComboBox", "AXTextField", "AXTextArea", "AXSearchField",
        "AXSwitch", "AXToggle", "AXSlider", "AXIncrementor", "AXMenuBarItem", "AXImage",
    ]

    /// Every visible clickable element of a window (labelled or not), in reading order.
    /// Used by «mostra numeri» and by the numbered screenshots of the agent.
    static func clickables(in window: AXUIElement, windowFrame: CGRect, limit: Int = 180) -> [Clickable] {
        let attrs = [kAXRoleAttribute, kAXChildrenAttribute, kAXPositionAttribute, kAXSizeAttribute,
                     kAXTitleAttribute, kAXDescriptionAttribute, kAXValueAttribute] as [String]
        var queue: [(AXUIElement, Int)] = [(window, 0)]
        var index = 0
        var found: [Clickable] = []
        let start = Date()
        while index < queue.count, found.count < limit, index < 15_000, Date().timeIntervalSince(start) < 1.5 {
            let (el, depth) = queue[index]
            index += 1
            let v = AX.multi(el, attrs)
            let role = (v[0] as? String) ?? ""
            let frame = AX.rect(position: v[2], size: v[3])
            if let f = frame, f.width > 0, f.height > 0, !windowFrame.intersects(f) { continue }
            if markRoles.contains(role), let f = frame, f.width >= 6, f.height >= 6,
               windowFrame.insetBy(dx: -2, dy: -2).contains(CGPoint(x: f.midX, y: f.midY)),
               role != "AXImage" || f.width <= 64 {
                // Skip near-duplicates (a link and its row with the same box).
                let duplicate = found.contains { abs($0.frame.midX - f.midX) < 8 && abs($0.frame.midY - f.midY) < 8 }
                if !duplicate {
                    let text = [v[4], v[5], v[6]].compactMap { $0 as? String }
                        .first { !$0.trimmingCharacters(in: .whitespaces).isEmpty } ?? ""
                    found.append(Clickable(element: el, frame: f, role: role, label: AX.collapse(text, max: 60)))
                }
            }
            if depth < 50, let children = v[1] as? [AXUIElement] {
                for c in children { queue.append((c, depth + 1)) }
            }
        }
        found.sort { a, b in abs(a.frame.minY - b.frame.minY) > 6 ? a.frame.minY < b.frame.minY : a.frame.minX < b.frame.minX }
        return found
    }
}

/// What is on screen right now, as seen through Accessibility.
struct ScreenContext {
    var appName = ""
    var bundleID = ""
    var pid: pid_t = 0
    var windowTitle = ""
    var focusedRole = ""
    var isEditable = false
    /// A password field: its text is never read.
    var isSecure = false
    var selectedText = ""
    var textBeforeCursor = ""
    var visibleLabels: [String] = []
    var windowFrame: CGRect?

    static let maxTextBeforeCursor = 600

    @MainActor
    static func capture(includeLabels: Bool) -> ScreenContext {
        var ctx = ScreenContext()
        guard let front = AX.frontmostApplication() else { return ctx }
        ctx.appName = front.localizedName ?? ""
        ctx.bundleID = front.bundleIdentifier ?? ""
        ctx.pid = front.processIdentifier

        let app = AX.app(front.processIdentifier)
        AX.prepare(app, pid: front.processIdentifier, bundleID: front.bundleIdentifier)
        let window = AX.focusedWindow(in: app)
        if let window {
            ctx.windowTitle = AX.string(window, kAXTitleAttribute) ?? ""
            ctx.windowFrame = AX.frame(window)
        }

        if let focused = AX.focusedElement(in: app) {
            ctx.focusedRole = AX.role(focused)
            let editableRoles: Set<String> = ["AXTextField", "AXTextArea", "AXComboBox", "AXSearchField"]
            let range = AX.selectedRange(focused)
            ctx.isEditable = editableRoles.contains(ctx.focusedRole)
                || (range != nil && AX.isSettable(focused, kAXValueAttribute))
            ctx.isSecure = AX.isSecureField(focused)
            if !ctx.isSecure {
                ctx.selectedText = AX.string(focused, kAXSelectedTextAttribute) ?? ""
            }

            if !ctx.isSecure, let range, let value = AX.string(focused, kAXValueAttribute) {
                let ns = value as NSString
                let caret = max(0, min(range.location, ns.length))
                let before = ns.substring(to: caret)
                ctx.textBeforeCursor = String(before.suffix(maxTextBeforeCursor))
            }
        }

        if includeLabels, let window {
            var seen = Set<String>()
            for item in AXTree.collect(in: window, limit: 250) where seen.insert(item.label).inserted {
                ctx.visibleLabels.append(item.label)
                if ctx.visibleLabels.count >= 150 { break }
            }
        }
        return ctx
    }

    /// Compact description sent to Claude.
    var promptDescription: String {
        var lines: [String] = []
        lines.append("APP: \(appName) (\(bundleID))")
        lines.append("WINDOW_TITLE: \(windowTitle)")
        lines.append("FOCUSED_ELEMENT: \(focusedRole.isEmpty ? "none" : focusedRole), editable: \(isEditable ? "yes" : "no")")
        lines.append("SELECTED_TEXT: <<<\(selectedText)>>>")
        lines.append("TEXT_BEFORE_CURSOR: <<<\(textBeforeCursor)>>>")
        lines.append("VISIBLE_CLICKABLE_LABELS: \(visibleLabels.joined(separator: " | "))")
        return lines.joined(separator: "\n")
    }
}
