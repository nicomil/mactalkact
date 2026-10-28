import AppKit
import Carbon
import ApplicationServices

/// Privacy rules: what the app may write in its log, keep in its memory and send to the
/// cloud engines. Pure helpers, testable without the app; the choices live in `AppSettings`.
enum Privacy {

    // MARK: Sensitive data in text

    private static func regex(_ pattern: String, _ options: NSRegularExpression.Options = []) -> NSRegularExpression {
        // The patterns are constants: a bad one is a programming error.
        try! NSRegularExpression(pattern: pattern, options: options)
    }

    private static let emailRE = regex(#"[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}"#)
    /// IBAN: two capital letters, two check digits, then 11-30 letters or digits, maybe in groups.
    private static let ibanRE = regex(#"\b[A-Z]{2}\d{2}(?: ?[A-Z0-9]){11,30}\b"#)
    /// Italian tax code (codice fiscale): RSSMRA85T10A562S.
    private static let taxCodeRE = regex(#"\b[A-Za-z]{6}\d{2}[A-Za-z]\d{2}[A-Za-z]\d{3}[A-Za-z]\b"#)
    /// Runs of digits with spaces, dots or dashes: card numbers and phone numbers are told apart later.
    private static let digitsRE = regex(#"(?<![\w+])\+?\d[\d .-]{6,}\d(?!\w)"#)
    /// «password: ciao123», «il PIN è 4821», «codice di verifica 482913».
    private static let secretRE = regex(
        #"\b(password|passwd|pwd|pin|otp|cvv|cvc|parola d'ordine|codice(?: di verifica| di sicurezza| segreto| otp| pin)?)\b(\s*(?:è|e'|=|:)?\s*)(\S+)"#,
        [.caseInsensitive])
    /// Words that always mean a secret, even when the value has no digits.
    private static let strongSecretWords: Set<String> = ["password", "passwd", "pwd", "parola d'ordine"]

    /// Masks sensitive data in a text.
    ///
    /// - For the log (`forCloud == false`): emails, phone numbers, IBANs, card numbers,
    ///   tax codes and secrets after «password», «PIN», «codice…».
    /// - For the cloud engines (`forCloud == true`): only what a task never needs to read —
    ///   card numbers, IBANs, tax codes and numeric secrets. Emails and phone numbers stay,
    ///   because «rispondi a Marco» needs them.
    static func redact(_ text: String, forCloud: Bool = false) -> String {
        guard text.count >= 6 else { return text }
        var s = text
        s = replace(secretRE, in: s) { m, ns in
            let key = ns.substring(with: m.range(at: 1))
            let value = ns.substring(with: m.range(at: 3))
            let strong = strongSecretWords.contains(key.lowercased())
            guard value.contains(where: \.isNumber) || (strong && !forCloud) else { return nil }
            return key + ns.substring(with: m.range(at: 2)) + "[segreto]"
        }
        s = replace(ibanRE, in: s) { _, _ in "[IBAN]" }
        s = replace(taxCodeRE, in: s) { _, _ in "[codice fiscale]" }
        if !forCloud { s = replace(emailRE, in: s) { _, _ in "[email]" } }
        s = replace(digitsRE, in: s) { m, ns in
            let raw = ns.substring(with: m.range)
            let digits = raw.filter(\.isNumber)
            if (13...19).contains(digits.count), luhn(digits) { return "[carta]" }
            if !forCloud, (8...15).contains(digits.count),
               raw.hasPrefix("+") || raw.hasPrefix("0") || raw.hasPrefix("3") {
                return "[telefono]"
            }
            return nil
        }
        return s
    }

    /// Data the app never saves in its memory: passwords, codes, card and bank details, tax codes.
    static func containsSensitive(_ text: String) -> Bool {
        if redact(text, forCloud: true) != text { return true }
        let words = Set(Grammar.normalize(text).split(separator: " ").map(String.init))
        return !words.isDisjoint(with: ["password", "passwd", "pwd", "pin", "cvv", "cvc", "iban"])
            || Grammar.normalize(text).contains("parola d ordine")
    }

    /// Luhn checksum: tells a card number from any other long number.
    static func luhn(_ digits: String) -> Bool {
        var sum = 0
        for (i, ch) in digits.reversed().enumerated() {
            guard var d = ch.wholeNumberValue else { return false }
            if i % 2 == 1 {
                d *= 2
                if d > 9 { d -= 9 }
            }
            sum += d
        }
        return sum % 10 == 0
    }

    private static func replace(_ re: NSRegularExpression, in text: String,
                                _ make: (NSTextCheckingResult, NSString) -> String?) -> String {
        let ns = text as NSString
        let matches = re.matches(in: text, range: NSRange(location: 0, length: ns.length))
        guard !matches.isEmpty else { return text }
        let out = NSMutableString(string: text)
        for m in matches.reversed() {
            if let r = make(m, ns) { out.replaceCharacters(in: m.range, with: r) }
        }
        return out as String
    }

    // MARK: Reserved apps and sites

    /// Password managers: never shown to a cloud engine.
    static let defaultReservedApps = [
        "com.apple.Passwords", "com.apple.keychainaccess", "com.1password.1password", "com.agilebits.onepassword7",
        "com.bitwarden.desktop", "org.keepassxc.keepassxc",
    ].joined(separator: "\n")

    /// Banks, payments, public administration and password managers on the web.
    static let defaultReservedSites = [
        "paypal.com", "intesasanpaolo.com", "unicredit.it", "bancobpm.it", "bper.it", "mps.it", "bnl.it",
        "finecobank.com", "poste.it", "credem.it", "mediolanum.it", "ing.it", "n26.com", "revolut.com",
        "satispay.com", "agenziaentrate.gov.it", "inps.it", "fascicolosanitario.gov.it",
        "1password.com", "bitwarden.com", "passwords.google.com",
    ].joined(separator: "\n")

    /// Browsers whose address can be read to recognise a reserved site.
    static let browsers: Set<String> = [
        "com.apple.Safari", "com.apple.SafariTechnologyPreview", "com.google.Chrome", "com.google.Chrome.canary",
        "com.microsoft.edgemac", "com.microsoft.edgemac.Dev", "com.microsoft.edgemac.Beta", "com.brave.Browser",
        "company.thebrowser.Browser", "org.mozilla.firefox", "com.operasoftware.Opera", "com.vivaldi.Vivaldi",
        "org.chromium.Chromium", "com.kagi.kagimacOS",
    ]

    /// One entry per line (commas also work); lines starting with # are comments.
    static func entries(_ list: String) -> [String] {
        list.split(whereSeparator: { $0 == "\n" || $0 == "," })
            .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }
    }

    /// The app is in the list, by bundle identifier or by name.
    static func isReservedApp(name: String, bundleID: String, list: String) -> Bool {
        let n = Grammar.normalize(name), b = bundleID.lowercased()
        return entries(list).contains { e in e == b || (!n.isEmpty && Grammar.normalize(e) == n) }
    }

    /// The list of reserved apps with the app in or out (Story 11.7). Out: every entry for it, by
    /// identifier or name, also inside a line with commas. In: its identifier on a new line, once. Pure.
    static func settingReserved(_ on: Bool, bundleID: String, name: String, in list: String) -> String {
        let n = Grammar.normalize(name), b = bundleID.lowercased()
        func matches(_ e: String) -> Bool {
            let t = e.trimmingCharacters(in: .whitespaces)
            return !t.hasPrefix("#") && (t.lowercased() == b || (!n.isEmpty && Grammar.normalize(t) == n))
        }
        if on { return isReservedApp(name: name, bundleID: bundleID, list: list) ? list : (list.isEmpty || list.hasSuffix("\n") ? list : list + "\n") + bundleID }
        return list.components(separatedBy: "\n").compactMap { line -> String? in
            let items = line.components(separatedBy: ",")
            let kept = items.filter { !matches($0) }
            if kept.count == items.count { return line }
            let joined = kept.map { $0.trimmingCharacters(in: .whitespaces) }.joined(separator: ", ")
            return joined.isEmpty ? nil : joined
        }.joined(separator: "\n")
    }

    /// The list entry matching the site, or nil. With the address: the host is the entry or one of
    /// its subdomains (a word without a dot matches anywhere in the host). Without the address
    /// (browsers that do not expose it): the site name in the window title.
    static func reservedSite(host: String?, title: String, list: String) -> String? {
        let h = (host ?? "").lowercased()
        let t = Grammar.normalize(title).replacingOccurrences(of: " ", with: "")
        for e in entries(list) {
            if !h.isEmpty {
                if h == e || h.hasSuffix("." + e) || (!e.contains(".") && h.contains(e)) { return e }
            } else {
                let key = Grammar.normalize(String(e.split(separator: ".").first ?? "")).replacingOccurrences(of: " ", with: "")
                if key.count >= 5, t.contains(key) { return e }
            }
        }
        return nil
    }
}

/// How much the agent may do in an app (FR-54, AD-22): two axes, who and how much.
struct AccessLevel: Equatable {
    enum Scope: String, Equatable {
        /// Only clicks and scrolling; to the cloud engines only roles and labels of the controls.
        case clickOnly = "solo clic"
        /// Every action with effects asks first (Impostazioni di Sistema).
        case confirmAll = "conferma ogni azione"
        /// The normal rules: actions with external effects ask first.
        case full = "normale"
    }
    var cloudAllowed: Bool
    var scope: Scope

    /// The default list, one app per line «bundle id o nome = solo clic | conferma ogni azione | normale».
    static let defaultList = """
    com.apple.Terminal = solo clic
    com.googlecode.iterm2 = solo clic
    dev.warp.Warp-Stable = solo clic
    com.mitchellh.ghostty = solo clic
    net.kovidgoyal.kitty = solo clic
    org.alacritty = solo clic
    com.cmuxterm.app = solo clic
    com.apple.keychainaccess = solo clic
    com.1password.1password = solo clic
    com.bitwarden.desktop = solo clic
    com.apple.systempreferences = conferma ogni azione
    com.apple.ScriptEditor2 = conferma ogni azione
    com.apple.Automator = conferma ogni azione
    com.apple.finder = normale
    """

    /// The level of an app from the list (pure, tested by `--selftest`); unknown apps are `.full`.
    /// The last line for the app wins (a line added at the bottom overrides the default). A level
    /// that is not recognised («solo click») fails closed: «conferma ogni azione».
    static func level(bundleID: String, name: String, list: String) -> Scope {
        for line in list.split(whereSeparator: \.isNewline).reversed() {
            let parts = line.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            guard parts.count == 2, !parts[0].isEmpty, !parts[0].hasPrefix("#") else { continue }
            let key = parts[0].lowercased()
            guard key == bundleID.lowercased() || (!name.isEmpty && key == name.lowercased()) else { continue }
            let value = parts[1].lowercased().split(whereSeparator: \.isWhitespace).joined(separator: " ")
            return Scope.allCasesList.first { $0.rawValue == value } ?? .confirmAll
        }
        return .full
    }
}

extension AccessLevel.Scope {
    static let allCasesList: [AccessLevel.Scope] = [.clickOnly, .confirmAll, .full]
}

extension AccessLevel {
    /// The list with `scope` for the app (Story 11.7, the panel in Impostazioni › Privacy): the lines of
    /// that app (by identifier or name) go, comments and other apps stay, and a line by identifier is
    /// added at the bottom unless the scope is «normale», which an unlisted app already has. Pure.
    static func setting(_ scope: Scope, bundleID: String, name: String, in list: String) -> String {
        var lines = list.components(separatedBy: "\n").filter { line in
            let parts = line.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            guard parts.count == 2, !parts[0].hasPrefix("#") else { return true }
            let key = parts[0].lowercased()
            return !(key == bundleID.lowercased() || (!name.isEmpty && key == name.lowercased()))
        }
        while lines.last?.trimmingCharacters(in: .whitespaces).isEmpty == true { lines.removeLast() }
        if scope != .full { lines.append("\(bundleID) = \(scope.rawValue)") }
        return lines.joined(separator: "\n")
    }
}

/// macOS secure keyboard entry (a password field or an app that asks for it): no synthetic typing
/// reaches other apps. The app that turned it on, for the message to the user (FR-52).
enum SecureInput {
    static var isOn: Bool { IsSecureEventInputEnabled() }

    static func ownerName() -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/sbin/ioreg")
        p.arguments = ["-l", "-w", "0", "-d", "1", "-c", "IOConsoleUsers"]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return nil }
        // Read first: the output is larger than the pipe, waiting before reading would never end.
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return securePID(in: String(data: data, encoding: .utf8) ?? "").flatMap { NSRunningApplication(processIdentifier: $0)?.localizedName }
    }

    /// The pid that holds secure input in the session on the console (pure, tested by `--selftest`):
    /// with fast user switching other sessions may have their own.
    static func securePID(in ioreg: String) -> pid_t? {
        for session in ioreg.components(separatedBy: "kCGSSessionAuditIDKey") where session.contains("\"kCGSSessionOnConsoleKey\"=Yes") {
            guard let r = session.range(of: #"kCGSSessionSecureInputPID"=(\d+)"#, options: .regularExpression) else { continue }
            return pid_t(session[r].split(separator: "=").last.map(String.init) ?? "")
        }
        return nil
    }
}

/// Decides, for the window in front, whether the cloud engines may see it.
@MainActor
enum PrivacyGuard {
    /// Levels added by the test commands only, in memory: an interrupted test never leaves them
    /// in the user's settings. They come last, so they win.
    static var testLevels = ""

    /// The access level of the frontmost app (FR-54): reserved apps, sites and private mode keep the
    /// cloud engines out; the list in the settings says how much the agent may do.
    static func accessLevel() -> AccessLevel {
        guard let front = AX.frontmostApplication() else {
            // Nothing known in front: the prudent level.
            return AccessLevel(cloudAllowed: false, scope: .confirmAll)
        }
        let scope = AccessLevel.level(bundleID: front.bundleIdentifier ?? "", name: front.localizedName ?? "",
                                      list: AppSettings.shared.accessLevels + "\n" + testLevels)
        return AccessLevel(cloudAllowed: cloudBlockReason() == nil, scope: scope)
    }

    private static var cache: (key: String, reason: String?, at: Date)?

    /// Why the cloud engines must not see or touch the frontmost window, or nil when they may:
    /// private mode, a reserved app or a reserved site.
    static func cloudBlockReason() -> String? {
        let settings = AppSettings.shared
        if settings.privateModeActive { return "modalità privata" }
        guard let front = AX.frontmostApplication() else { return nil }
        let name = front.localizedName ?? ""
        let bundle = front.bundleIdentifier ?? ""
        if Privacy.isReservedApp(name: name, bundleID: bundle, list: settings.reservedApps) {
            return "«\(name)» è un'app riservata"
        }
        guard Privacy.browsers.contains(bundle) else { return nil }
        let app = AX.app(front.processIdentifier)
        guard let window = AX.focusedWindow(in: app) else { return nil }
        let title = AX.string(window, kAXTitleAttribute) ?? ""
        // Reading the address walks part of the tree: reuse it for a moment on the same page.
        let key = "\(front.processIdentifier)|\(title)|\(settings.reservedSites.hashValue)"
        if let c = cache, c.key == key, Date().timeIntervalSince(c.at) < 2 { return c.reason }
        let host = AX.webURL(in: window)?.host
        let reason = Privacy.reservedSite(host: host, title: title, list: settings.reservedSites)
            .map { "«\($0)» è un sito riservato" }
        cache = (key, reason, Date())
        return reason
    }
}

extension AX {
    /// The address of the page shown in a browser window (AXURL of its web area), when exposed.
    static func webURL(in window: AXUIElement, maxNodes: Int = 600) -> URL? {
        var queue = [window]
        var index = 0
        while index < queue.count, index < maxNodes {
            let el = queue[index]
            index += 1
            if role(el) == "AXWebArea" {
                if let v = value(el, "AXURL") {
                    if CFGetTypeID(v) == CFURLGetTypeID() { return (v as! CFURL) as URL }
                    if let s = v as? String { return URL(string: s) }
                }
                continue // the page itself: its address is not deeper down
            }
            queue += children(el)
        }
        return nil
    }
}
