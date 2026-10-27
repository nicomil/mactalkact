import AppKit
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

/// Decides, for the window in front, whether the cloud engines may see it.
@MainActor
enum PrivacyGuard {
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
