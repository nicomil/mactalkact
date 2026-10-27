import AppKit
import ApplicationServices

/// The menu bar of the frontmost app, walked by name through Accessibility (FR-37):
/// «Formato > Font > Grassetto» without coordinates and without opening the menus on screen.
@MainActor
enum AppMenu {
    struct Item {
        let element: AXUIElement
        let title: String
        let shortcut: String
        let enabled: Bool
        let submenu: AXUIElement?
    }

    enum Outcome {
        /// The path ends on a menu (or is empty): its items, to choose from.
        case listing(path: [String], items: [Item])
        /// The path ends on an item: ready to be pressed.
        case item(path: [String], Item)
        case notFound(path: [String], missing: String, items: [Item])
        case noMenuBar
    }

    /// "Formato > Font > Grassetto", "Formato › Font", "File/Esporta": separators > › /.
    static func split(_ path: String) -> [String] {
        path.split(whereSeparator: { ">›/".contains($0) })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    static func resolve(_ path: String, in app: AXUIElement) -> Outcome {
        guard let bar = AX.element(app, kAXMenuBarAttribute) else { return .noMenuBar }
        // The first menu bar item is the Apple menu: not the app's.
        var items = items(of: bar).filter { Grammar.normalize($0.title) != "apple" }
        var walked: [String] = []
        let parts = split(path)
        for (i, part) in parts.enumerated() {
            guard let match = best(part, in: items) else {
                return .notFound(path: walked, missing: part, items: items)
            }
            walked.append(match.title)
            if i == parts.count - 1 {
                if let sub = match.submenu { return .listing(path: walked, items: Self.items(of: sub)) }
                return .item(path: walked, match)
            }
            guard let sub = match.submenu else {
                return .notFound(path: walked, missing: parts[(i + 1)...].joined(separator: " > "), items: [])
            }
            items = Self.items(of: sub)
        }
        return .listing(path: walked, items: items)
    }

    /// The items of a menu bar or of a menu (separators skipped).
    static func items(of container: AXUIElement) -> [Item] {
        var children = AX.children(container)
        // A menu bar item holds its menu as only child: list the menu's items.
        if children.count == 1, AX.role(children[0]) == "AXMenu" { children = AX.children(children[0]) }
        return children.compactMap { el -> Item? in
            let role = AX.role(el)
            guard role == "AXMenuBarItem" || role == "AXMenuItem" else { return nil }
            let title = AX.string(el, kAXTitleAttribute) ?? ""
            guard !title.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
            let enabled = (AX.value(el, kAXEnabledAttribute) as? Bool) ?? true
            let sub = AX.children(el).first { AX.role($0) == "AXMenu" }
            return Item(element: el, title: title, shortcut: shortcut(of: el), enabled: enabled, submenu: sub)
        }
    }

    /// «⌘⇧S» from the item's command character and modifiers (0 = ⌘ only, bit 0 shift,
    /// bit 1 option, bit 2 control, bit 3 no ⌘).
    static func shortcut(of el: AXUIElement) -> String {
        guard let char = AX.string(el, kAXMenuItemCmdCharAttribute), !char.isEmpty else { return "" }
        let mods = (AX.value(el, kAXMenuItemCmdModifiersAttribute) as? Int) ?? 0
        var s = ""
        if mods & 4 != 0 { s += "⌃" }
        if mods & 2 != 0 { s += "⌥" }
        if mods & 1 != 0 { s += "⇧" }
        if mods & 8 == 0 { s += "⌘" }
        return s + char.uppercased()
    }

    /// Exact title first (ignoring case, accents and the final «…»), then prefix, then contains.
    static func best(_ wanted: String, in items: [Item]) -> Item? {
        func clean(_ s: String) -> String {
            Grammar.normalize(s.replacingOccurrences(of: "…", with: "").replacingOccurrences(of: "...", with: ""))
        }
        let w = clean(wanted)
        guard !w.isEmpty else { return nil }
        return items.first { clean($0.title) == w }
            ?? items.first { clean($0.title).hasPrefix(w) }
            ?? items.first { clean($0.title).contains(w) }
    }

    /// One line per item for the agent: «Esporta come PDF… (⌘E)», «Font ›», «Incolla (disabled)».
    static func describe(_ items: [Item]) -> String {
        items.map { i in
            var s = i.title
            if !i.shortcut.isEmpty { s += " (\(i.shortcut))" }
            if i.submenu != nil { s += " ›" }
            if !i.enabled { s += " (disabled)" }
            return s
        }.joined(separator: " · ")
    }
}
