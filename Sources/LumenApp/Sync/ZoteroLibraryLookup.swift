import Foundation
import SQLite3

/// Prefer the running application's API. A closed Zotero library is read in a
/// read-only SQLite transaction; a locked/busy library is never copied or forced
/// open. No query, pragma or migration here writes to the user's database.
enum ZoteroLibraryLookup {
    struct Location: Sendable {
        var directory: URL
        var attachmentBase: URL?
    }

    static func resolve(documentURL: URL) async throws -> LiteratureZoteroIdentity {
        do { return try await ZoteroLocalLookup.resolve(documentURL: documentURL) }
        catch is CancellationError { throw CancellationError() }
        catch ZoteroLookupError.noMatch { throw ZoteroLookupError.noMatch }
        catch ZoteroLookupError.ambiguous(let choices) { throw ZoteroLookupError.ambiguous(choices) }
        catch {
            let onlineError = error
            do { return try await diskIdentity(documentURL: documentURL) }
            catch ZoteroLookupError.noMatch { throw onlineError }
        }
    }

    static func refresh(_ identity: LiteratureZoteroIdentity, documentURL: URL) async throws -> LiteratureZoteroIdentity {
        do { return try await ZoteroLocalLookup.refresh(identity, documentURL: documentURL) }
        catch ZoteroLookupError.unavailable {
            let local = try await diskIdentity(documentURL: documentURL)
            guard local.itemLink == identity.itemLink, local.attachmentKey == identity.attachmentKey else {
                throw ZoteroLookupError.noMatch
            }
            return local
        }
    }

    private static func diskIdentity(documentURL: URL) async throws -> LiteratureZoteroIdentity {
        try await Task.detached(priority: .utility) {
            try fromDisk(documentURL: documentURL, locations: locations())
        }.value
    }

    static func locations(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> [Location] {
        var result: [Location] = []
        let root = home.appendingPathComponent("Library/Application Support/Zotero/Profiles", isDirectory: true)
        let profiles = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        for profile in profiles {
            guard let text = try? String(contentsOf: profile.appendingPathComponent("prefs.js"), encoding: .utf8) else { continue }
            func preference(_ key: String) -> String? {
                let prefix = "user_pref(\"extensions.zotero.\(key)\", "
                guard let line = text.components(separatedBy: .newlines).last(where: { $0.hasPrefix(prefix) && $0.hasSuffix(");") }),
                      let data = String(line.dropFirst(prefix.count).dropLast(2)).data(using: .utf8) else { return nil }
                return try? JSONDecoder().decode(String.self, from: data)
            }
            let custom = text.components(separatedBy: .newlines).contains("user_pref(\"extensions.zotero.useDataDir\", true);")
            let directory = custom ? preference("dataDir").map { URL(fileURLWithPath: $0, isDirectory: true) }
                : home.appendingPathComponent("Zotero", isDirectory: true)
            if let directory {
                result.append(Location(directory: directory, attachmentBase: preference("baseAttachmentPath").map { URL(fileURLWithPath: $0, isDirectory: true) }))
            }
        }
        if result.isEmpty { result.append(Location(directory: home.appendingPathComponent("Zotero", isDirectory: true))) }
        var seen = Set<String>()
        return result.filter { seen.insert($0.directory.standardizedFileURL.resolvingSymlinksInPath().path).inserted }
    }

    static func fromDisk(documentURL: URL, locations: [Location]) throws -> LiteratureZoteroIdentity {
        let expected = documentURL.standardizedFileURL.resolvingSymlinksInPath()
        var matches: [LiteratureZoteroIdentity] = []
        var failure: Error?
        for location in locations {
            let url = location.directory.appendingPathComponent("zotero.sqlite")
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            do {
                let database = try Database(url)
                try database.execute("BEGIN")
                defer { try? database.execute("ROLLBACK") }
                let attachments = try database.rows("""
                    SELECT a.itemID, COALESCE(a.parentItemID, a.itemID), i.key, p.key,
                           l.type, COALESCE(g.groupID, 0), a.path
                    FROM itemAttachments a JOIN items i ON i.itemID = a.itemID
                    JOIN items p ON p.itemID = COALESCE(a.parentItemID, a.itemID)
                    JOIN libraries l ON l.libraryID = i.libraryID
                    LEFT JOIN groups g ON g.libraryID = i.libraryID
                    WHERE a.path IS NOT NULL AND l.type IN ('user','group')
                      AND NOT EXISTS (SELECT 1 FROM deletedItems d WHERE d.itemID IN (i.itemID,p.itemID))
                    """)
                for row in attachments {
                    let path = row[6]
                    let file: URL
                    if path.hasPrefix("storage:") {
                        file = location.directory.appendingPathComponent("storage").appendingPathComponent(row[2])
                            .appendingPathComponent(String(path.dropFirst("storage:".count)))
                    } else if path.hasPrefix("attachments:"), let base = location.attachmentBase {
                        file = base.appendingPathComponent(String(path.dropFirst("attachments:".count)))
                    } else if path.hasPrefix("/") { file = URL(fileURLWithPath: path) }
                    else { continue }
                    guard file.standardizedFileURL.resolvingSymlinksInPath() == expected,
                          let parentID = Int(row[1]), row[2].range(of: #"^[A-Z0-9]{8}$"#, options: .regularExpression) != nil,
                          row[3].range(of: #"^[A-Z0-9]{8}$"#, options: .regularExpression) != nil else { continue }
                    let fields = try database.rows("""
                        SELECT f.fieldName, v.value FROM itemData d
                        JOIN fieldsCombined f ON f.fieldID = d.fieldID JOIN itemDataValues v ON v.valueID = d.valueID
                        WHERE d.itemID = \(parentID) AND f.fieldName IN ('title','date','publicationTitle')
                        """)
                    let values = Dictionary(fields.map { ($0[0], $0[1]) }, uniquingKeysWith: { first, _ in first })
                    let creators = try database.rows("""
                        SELECT c.firstName, c.lastName FROM itemCreators ic JOIN creators c ON c.creatorID = ic.creatorID
                        WHERE ic.itemID = \(parentID) ORDER BY ic.orderIndex
                        """)
                    let library: String
                    if row[4] == "group" {
                        guard let groupID = Int(row[5]), groupID > 0 else { throw ZoteroLookupError.invalidResponse }
                        library = "groups/\(groupID)"
                    } else { library = "library" }
                    let authors = creators.map { $0.filter { !$0.isEmpty }.joined(separator: " ") }.joined(separator: ", ")
                    matches.append(.init(library: library, itemKey: row[3], attachmentKey: row[2],
                                         title: values["title"] ?? expected.deletingPathExtension().lastPathComponent,
                                         authors: authors, year: values["date"] ?? "", journal: values["publicationTitle"]))
                }
            } catch { failure = error }
        }
        // An unreadable second library might contain another exact-path match.
        if let failure { throw failure }
        guard matches.count < 2 else { throw ZoteroLookupError.ambiguous(matches) }
        guard let match = matches.first else { throw ZoteroLookupError.noMatch }
        return match
    }

    private final class Database {
        private var handle: OpaquePointer?
        init(_ url: URL) throws {
            guard sqlite3_open_v2(url.path, &handle, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX, nil) == SQLITE_OK else {
                if let handle { sqlite3_close(handle) }; handle = nil
                throw ZoteroLookupError.unavailable
            }
            sqlite3_busy_timeout(handle, 100)
        }
        deinit { sqlite3_close(handle) }
        func execute(_ sql: String) throws { _ = try rows(sql) }
        func rows(_ sql: String) throws -> [[String]] {
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else { throw ZoteroLookupError.invalidResponse }
            defer { sqlite3_finalize(statement) }
            var output: [[String]] = []
            while true {
                switch sqlite3_step(statement) {
                case SQLITE_DONE: return output
                case SQLITE_ROW:
                    output.append((0..<sqlite3_column_count(statement)).map { column in
                        sqlite3_column_text(statement, column).map { String(cString: $0) } ?? ""
                    })
                case SQLITE_BUSY, SQLITE_LOCKED: throw ZoteroLookupError.unavailable
                default: throw ZoteroLookupError.invalidResponse
                }
            }
        }
    }
}
