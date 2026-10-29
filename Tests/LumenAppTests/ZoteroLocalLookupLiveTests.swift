import Foundation
import Testing
@testable import LumenApp

@Suite @MainActor struct ZoteroLocalLookupLiveTests {
    @Test func resolvesExistingAttachmentByExactPath() async throws {
        guard ProcessInfo.processInfo.environment["LUMEN_RUN_ZOTERO_LOOKUP"] == "1" else { return }
        let base = "http://127.0.0.1:23119/api/users/0/items"
        var request = URLRequest(url: try #require(URL(string: base + "?itemType=attachment&limit=100")))
        request.setValue("3", forHTTPHeaderField: "Zotero-API-Version")
        let (data, _) = try await URLSession.shared.data(for: request)
        let objects = try #require(JSONSerialization.jsonObject(with: data) as? [[String: Any]])
        var fixture: (URL, String, String)?
        for object in objects {
            guard let fields = object["data"] as? [String: Any], let key = fields["key"] as? String,
                  let parent = fields["parentItem"] as? String else { continue }
            var fileRequest = URLRequest(url: try #require(URL(string: "\(base)/\(key)/file/view/url")))
            fileRequest.setValue("3", forHTTPHeaderField: "Zotero-API-Version")
            guard let (bytes, _) = try? await URLSession.shared.data(for: fileRequest),
                  let value = String(data: bytes, encoding: .utf8),
                  let url = URL(string: value.trimmingCharacters(in: .whitespacesAndNewlines)),
                  url.isFileURL, FileManager.default.fileExists(atPath: url.path) else { continue }
            fixture = (url, key, parent)
            break
        }
        let (url, key, parent) = try #require(fixture)
        let result = try await ZoteroLocalLookup.resolve(documentURL: url)
        #expect(result.library == "library")
        #expect(result.attachmentKey == key)
        #expect(result.itemKey == parent)
        let refreshed = try await ZoteroLocalLookup.refresh(result, documentURL: url)
        #expect(refreshed == result)
    }

    @Test func firstNoteUsesRealMetadataAndPreservesBidirectionalEdits() async throws {
        guard let path = ProcessInfo.processInfo.environment["LUMEN_LIVE_PDF"], !path.isEmpty else { return }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let folder = root.appendingPathComponent("notes")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = URL(fileURLWithPath: path)
        let originalBytes = try Data(contentsOf: source)
        let service = LiteratureSyncService(stateURL: root.appendingPathComponent("state.json"), backupDirectory: root.appendingPathComponent("backups"))
        service.configureDirectory(folder); service.setEnabled(true)
        await service.setDocumentSync(true, documentURL: source)
        let record = try #require(service.record(for: path))
        let firstIdentity = try #require(record.zotero)
        #expect(!firstIdentity.title.isEmpty)
        #expect(!firstIdentity.authors.isEmpty)
        let note = URL(fileURLWithPath: record.notePath)
        let initial = try String(contentsOf: note, encoding: .utf8)
        let edited = try LiteraturePageEditor.setReadingNotes(initial, value: "离线笔记 [[测试]]", expected: LiteraturePageEditor.readingNotes(initial))
        try edited.write(to: note, atomically: true, encoding: .utf8)
        await service.syncNow(recordID: record.id)
        let linked = try #require(service.record(for: path)?.zotero)
        let result = try String(contentsOf: note, encoding: .utf8)
        #expect(LiteratureNoteIndex.itemLink(in: result) == linked.itemLink)
        #expect(try LiteraturePageEditor.readingNotes(result) == "离线笔记 [[测试]]")
        let properties = try LiteraturePageEditor.properties(result)
        #expect(properties.first { $0.key == "标题" }?.value == firstIdentity.title)
        #expect(properties.first { $0.key == "作者" }?.value == firstIdentity.authors)
        #expect(properties.first { $0.key == "日期" }?.value == firstIdentity.year)
        #expect(properties.first { $0.key == "期刊" }?.value == (firstIdentity.journal ?? ""))
        #expect(try Data(contentsOf: source) == originalBytes)
        #expect(record.baseline != nil)
        let resumed = LiteratureSyncService(stateURL: root.appendingPathComponent("state.json"), backupDirectory: root.appendingPathComponent("backups"))
        await resumed.reconcile()
        #expect(URL(fileURLWithPath: try #require(resumed.record(for: path)?.notePath)).resolvingSymlinksInPath() == note.resolvingSymlinksInPath())
        #expect(try LiteraturePageEditor.readingNotes(String(contentsOf: note, encoding: .utf8)) == "离线笔记 [[测试]]")
    }

    @Test func unrelatedLocalFileDoesNotBecomeZoteroMatch() async throws {
        guard ProcessInfo.processInfo.environment["LUMEN_RUN_ZOTERO_LOOKUP"] == "1" else { return }
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("lumen-unmatched-\(UUID()).pdf")
        try Data("fixture".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        do {
            _ = try await ZoteroLocalLookup.resolve(documentURL: file)
            Issue.record("An unrelated file was matched to a Zotero attachment")
        } catch ZoteroLookupError.noMatch { }
    }
}
