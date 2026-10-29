import AppKit

/// Profiles of Chromium browsers (Edge, Chrome, Brave), read from their "Local State" file,
/// so "apri Edge profilo lavoro" opens the right profile.
enum BrowserProfiles {
    struct Profile {
        let directory: String   // e.g. "Profile 1"
        let name: String        // e.g. "Lavoro"
        let email: String
    }

    private static let localStates: [(match: String, path: String)] = [
        ("edge", "Library/Application Support/Microsoft Edge/Local State"),
        ("chrome", "Library/Application Support/Google/Chrome/Local State"),
        ("brave", "Library/Application Support/BraveSoftware/Brave-Browser/Local State"),
    ]

    private static func localState(for browser: String) -> URL? {
        let b = Grammar.normalize(browser)
        guard let entry = localStates.first(where: { b.contains($0.match) }) else { return nil }
        return URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(entry.path)
    }

    static func list(browser: String) -> [Profile] {
        guard let url = localState(for: browser) else { return [] }
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            Log.error("Profili \(browser): non riesco a leggere \(url.path) (\(error.localizedDescription))")
            return []
        }
        guard
              let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let cache = (json["profile"] as? [String: Any])?["info_cache"] as? [String: Any] else { return [] }
        return cache.compactMap { dir, value in
            guard let info = value as? [String: Any] else { return nil }
            return Profile(directory: dir,
                           name: info["name"] as? String ?? dir,
                           email: info["user_name"] as? String ?? "")
        }.sorted { $0.directory < $1.directory }
    }

    /// Best profile for a spoken name ("lavoro", "personale", an email).
    static func find(browser: String, spoken: String) -> Profile? {
        let profiles = list(browser: browser)
        let q = Grammar.normalize(spoken)
        guard !q.isEmpty else { return nil }
        if let exact = profiles.first(where: { Grammar.normalize($0.name) == q || Grammar.normalize($0.directory) == q }) {
            return exact
        }
        let scored = profiles.map { p -> (Profile, Int) in
            let s = max(LabelMatcher.score(query: q, label: p.name), LabelMatcher.score(query: q, label: p.email))
            return (p, s)
        }
        return scored.filter { $0.1 >= 45 }.max { $0.1 < $1.1 }?.0
    }

    /// Opens a window of `appURL` with the given profile (and optionally a URL).
    static func open(appURL: URL, profile: Profile, url: String?) throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        var args = ["-na", appURL.path, "--args", "--profile-directory=\(profile.directory)"]
        if let url, !url.isEmpty { args.append(url) }
        p.arguments = args
        try p.run()
        p.waitUntilExit()
    }
}
