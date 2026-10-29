import Foundation
import SQLite3
import Testing
@testable import LumenApp

@Suite struct ZoteroLibraryLookupTests {
    private func fixture() throws -> (URL, OpaquePointer) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        var db: OpaquePointer?
        #expect(sqlite3_open(root.appendingPathComponent("zotero.sqlite").path, &db) == SQLITE_OK)
        let connection = try #require(db)
        try execute(connection, """
            CREATE TABLE items (itemID INTEGER, libraryID INTEGER, key TEXT);
            CREATE TABLE itemAttachments (itemID INTEGER, parentItemID INTEGER, path TEXT);
            CREATE TABLE libraries (libraryID INTEGER, type TEXT);
            CREATE TABLE groups (libraryID INTEGER, groupID INTEGER);
            CREATE TABLE deletedItems (itemID INTEGER);
            CREATE TABLE itemData (itemID INTEGER, fieldID INTEGER, valueID INTEGER);
            CREATE TABLE itemDataValues (valueID INTEGER, value TEXT);
            CREATE TABLE fieldsCombined (fieldID INTEGER, fieldName TEXT);
            CREATE TABLE creators (creatorID INTEGER, firstName TEXT, lastName TEXT);
            CREATE TABLE itemCreators (itemID INTEGER, creatorID INTEGER, orderIndex INTEGER);
            INSERT INTO libraries VALUES (1,'user'),(2,'group');
            INSERT INTO groups VALUES (2,123);
            INSERT INTO items VALUES (1,1,'PARENT01'),(2,1,'ATTACH01'),(3,2,'PARENT02'),(4,2,'ATTACH02');
            INSERT INTO itemAttachments VALUES (2,1,'storage:中文书.pdf'),(4,3,'attachments:子目录/中文书.pdf');
            INSERT INTO fieldsCombined VALUES (1,'title'),(2,'date'),(3,'publicationTitle');
            INSERT INTO itemDataValues VALUES (1,'真正的文献题名'),(2,'2024-03-12'),(3,'测试期刊');
            INSERT INTO itemData VALUES (1,1,1),(1,2,2),(1,3,3),(3,1,1);
            INSERT INTO creators VALUES (1,'Jane','Smith'),(2,'','研究机构');
            INSERT INTO itemCreators VALUES (1,1,0),(1,2,1);
            """)
        return (root, connection)
    }
    private func execute(_ db: OpaquePointer, _ sql: String) throws {
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else {
            throw NSError(domain: "SQLiteFixture", code: Int(sqlite3_errcode(db)))
        }
    }

    @Test func closedLibraryReadsMetadataAndExactStoredAttachmentWithoutWrites() throws {
        let (root, db) = try fixture()
        sqlite3_close(db)
        defer { try? FileManager.default.removeItem(at: root) }
        let database = root.appendingPathComponent("zotero.sqlite")
        let before = try Data(contentsOf: database)
        let file = root.appendingPathComponent("storage/ATTACH01/中文书.pdf")
        let result = try ZoteroLibraryLookup.fromDisk(documentURL: file, locations: [.init(directory: root)])
        #expect(result.title == "真正的文献题名")
        #expect(result.authors == "Jane Smith, 研究机构")
        #expect(result.year == "2024-03-12")
        #expect(result.journal == "测试期刊")
        #expect(result.itemLink == "zotero://select/library/items/PARENT01")
        #expect(try Data(contentsOf: database) == before)
        #expect(!FileManager.default.fileExists(atPath: database.path + "-journal"))
        #expect(throws: ZoteroLookupError.noMatch) {
            try ZoteroLibraryLookup.fromDisk(documentURL: root.appendingPathComponent("elsewhere/中文书.pdf"), locations: [.init(directory: root)])
        }
    }

    @Test func linkedGroupsSymlinksAndDuplicateReferencesDoNotGuessByFilename() throws {
        let (root, db) = try fixture()
        defer { sqlite3_close(db); try? FileManager.default.removeItem(at: root) }
        let base = root.appendingPathComponent("linked")
        try FileManager.default.createDirectory(at: base.appendingPathComponent("子目录"), withIntermediateDirectories: true)
        let linked = base.appendingPathComponent("子目录/中文书.pdf")
        try Data("fixture".utf8).write(to: linked)
        let alias = root.appendingPathComponent("alias.pdf")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: linked)
        let location = ZoteroLibraryLookup.Location(directory: root, attachmentBase: base)
        let result = try ZoteroLibraryLookup.fromDisk(documentURL: alias, locations: [location])
        #expect(result.library == "groups/123")
        #expect(result.attachmentKey == "ATTACH02")
        try execute(db, "UPDATE itemAttachments SET path='\(linked.path)' WHERE itemID=2")
        do {
            _ = try ZoteroLibraryLookup.fromDisk(documentURL: linked, locations: [location])
            Issue.record("Duplicate exact-path associations must not choose a library")
        } catch ZoteroLookupError.ambiguous(let choices) { #expect(choices.count == 2) }
        try execute(db, "INSERT INTO deletedItems VALUES(1)")
        #expect(try ZoteroLibraryLookup.fromDisk(documentURL: linked, locations: [location]).library == "groups/123")
    }

    @Test func lockedAndCorruptLibrariesNeverGetForcedOpenOrModified() throws {
        let (root, db) = try fixture()
        defer { sqlite3_close(db); try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("storage/ATTACH01/中文书.pdf")
        try execute(db, "BEGIN EXCLUSIVE")
        #expect(throws: (any Error).self) {
            try ZoteroLibraryLookup.fromDisk(documentURL: file, locations: [.init(directory: root)])
        }
        try execute(db, "ROLLBACK")
        #expect(try ZoteroLibraryLookup.fromDisk(documentURL: file, locations: [.init(directory: root)]).itemKey == "PARENT01")
        let broken = root.appendingPathComponent("broken")
        try FileManager.default.createDirectory(at: broken, withIntermediateDirectories: true)
        let bytes = Data("corrupt sqlite".utf8)
        let url = broken.appendingPathComponent("zotero.sqlite")
        try bytes.write(to: url)
        #expect(throws: (any Error).self) {
            try ZoteroLibraryLookup.fromDisk(documentURL: file, locations: [.init(directory: broken)])
        }
        #expect(try Data(contentsOf: url) == bytes)
    }

    @Test func customDataAndAttachmentDirectoriesComeFromProfiles() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: home) }
        let profile = home.appendingPathComponent("Library/Application Support/Zotero/Profiles/test.default")
        try FileManager.default.createDirectory(at: profile, withIntermediateDirectories: true)
        let prefs = """
        user_pref("extensions.zotero.useDataDir", true);
        user_pref("extensions.zotero.dataDir", "/some/custom/library");
        user_pref("extensions.zotero.baseAttachmentPath", "/some/books");
        """
        try prefs.write(to: profile.appendingPathComponent("prefs.js"), atomically: true, encoding: .utf8)
        let result = ZoteroLibraryLookup.locations(home: home)
        #expect(result.count == 1)
        #expect(result.first?.directory.path == "/some/custom/library")
        #expect(result.first?.attachmentBase?.path == "/some/books")
    }

    @Test @MainActor func allThemesHaveReadableProminentButtons() {
        func luminance(_ hex: UInt32) -> Double {
            let rgb = [16,8,0].map { shift -> Double in
                let value = Double((hex >> shift) & 255) / 255
                return value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
            }
            return rgb[0] * 0.2126 + rgb[1] * 0.7152 + rgb[2] * 0.0722
        }
        for theme in ReadingTheme.all {
            let a = luminance(theme.accentHex), b = luminance(theme.onAccentHex)
            #expect((max(a,b) + 0.05) / (min(a,b) + 0.05) >= 4.5)
        }
    }
}
