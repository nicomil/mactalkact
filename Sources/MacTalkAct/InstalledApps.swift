import AppKit
import Foundation

/// An app the user can give an access level to (Story 11.7): installed or running.
struct InstalledApp: Identifiable, Hashable, Sendable {
    var id: String { bundleID }
    let bundleID: String
    let name: String
    let path: String
}

enum InstalledApps {
    /// The folders macOS installs apps into, and their first level of subfolders (Utility, Xcode…).
    static var folders: [URL] {
        let fm = FileManager.default
        return ["/Applications", "/System/Applications", fm.homeDirectoryForCurrentUser.appendingPathComponent("Applications").path]
            .map { URL(fileURLWithPath: $0) }
    }

    /// Installed and running apps, one per bundle identifier, sorted by name. Reads only the bundles'
    /// Info.plist; runs off the main thread.
    static func scan() -> [InstalledApp] {
        var found: [String: InstalledApp] = [:]
        let fm = FileManager.default
        func add(_ url: URL) {
            guard let bundle = Bundle(url: url), let id = bundle.bundleIdentifier, found[id.lowercased()] == nil else { return }
            let name = fm.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
            found[id.lowercased()] = InstalledApp(bundleID: id, name: name, path: url.path)
        }
        for folder in folders {
            for item in (try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? [] {
                if item.pathExtension == "app" { add(item); continue }
                var isDir: ObjCBool = false
                guard fm.fileExists(atPath: item.path, isDirectory: &isDir), isDir.boolValue else { continue }
                for inner in (try? fm.contentsOfDirectory(at: item, includingPropertiesForKeys: nil)) ?? [] where inner.pathExtension == "app" {
                    add(inner)
                }
            }
        }
        for app in NSWorkspace.shared.runningApplications where app.activationPolicy == .regular {
            if let url = app.bundleURL { add(url) }
        }
        return found.values.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// Apps matching the search, those with a setting first (pure, tested by `--selftest`).
    static func filtered(_ apps: [InstalledApp], query: String, configured: (InstalledApp) -> Bool) -> [InstalledApp] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        let matching = q.isEmpty ? apps : apps.filter { $0.name.lowercased().contains(q) || $0.bundleID.lowercased().contains(q) }
        return matching.filter(configured) + matching.filter { !configured($0) }
    }
}
