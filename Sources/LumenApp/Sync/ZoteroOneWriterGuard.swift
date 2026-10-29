import Foundation

enum ZoteroOneWriterGuard {
    /// The installed add-on's default is enabled. If its effective preference
    /// cannot be established, refuse to take ownership of the same directory.
    static func isSafe(notesDirectory: URL, profileRoot: URL? = nil) -> Bool {
        let base = profileRoot ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Zotero/Profiles", isDirectory: true)
        guard FileManager.default.fileExists(atPath: base.path) else { return true }
        guard let profiles = try? FileManager.default.contentsOfDirectory(at: base, includingPropertiesForKeys: nil) else { return false }
        for profile in profiles {
            let addon = profile.appendingPathComponent("extensions/zoteroif@qnscholar.xpi")
            guard FileManager.default.fileExists(atPath: addon.path) else { continue }
            let prefs = profile.appendingPathComponent("prefs.js")
            guard let text = try? String(contentsOf: prefs, encoding: .utf8) else { return false }
            let prefix = "user_pref(\"extensions.zotero.zoteroif.obsidianmarkdownfolderpath\", "
            guard let line = text.components(separatedBy: .newlines).first(where: { $0.hasPrefix(prefix) }),
                  line.hasSuffix(");"),
                  let data = String(line.dropFirst(prefix.count).dropLast(2)).data(using: .utf8),
                  let path = try? JSONDecoder().decode(String.self, from: data) else { return false }
            let destination = URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL.resolvingSymlinksInPath()
            guard destination.path == notesDirectory.standardizedFileURL.resolvingSymlinksInPath().path else { continue }
            let off = "user_pref(\"extensions.zotero.zoteroif.obsidianautoupdatenotes\", false);"
            if !text.components(separatedBy: .newlines).contains(off) { return false }
        }
        return true
    }
}
