import Foundation
import Testing
import LumenKit
@testable import LumenApp

@Suite struct LiteratureNoteFilesTests {
    private let link = "zotero://select/library/items/ABCDEFGH"

    @Test func readOnlyLiteraturePageRefusesBothExportAndPropertyEdits() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let page = root.appendingPathComponent("readonly.md")
        let original = "---\n总结: 保留\n---\n\n个人笔记\n"
        try original.write(to: page, atomically: true, encoding: .utf8)
        let files = LiteratureNoteFiles(backupDirectory: root.appendingPathComponent("backups"))
        let snapshot = LiteratureAttachmentSnapshot(documentID: "readonly", title: "paper.pdf", annotations: [])
        let prepared = try await files.prepare(url: page, initial: "", snapshot: snapshot, baseline: nil)
        try FileManager.default.setAttributes([.posixPermissions: 0o444], ofItemAtPath: page.path)
        await #expect(throws: (any Error).self) { try await files.commit(prepared, firstTakeover: true) }
        await #expect(throws: (any Error).self) {
            try await files.editPage(url: page) { text in
                try LiteraturePageEditor.set(text, key: "总结", value: "不应保存", expected: LiteraturePageEditor.properties(text).first { $0.key == "总结" })
            }
        }
        #expect(try String(contentsOf: page, encoding: .utf8) == original)
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("backups").path))
    }

    @Test func longEmojiFilenameRemainsWritableAfterACollisionSuffix() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let identity = LiteratureZoteroIdentity(library: "library", itemKey: UUID().uuidString, attachmentKey: "ATTACH01",
                                               title: "文章", authors: "", year: "")
        let filename = String(repeating: "📚", count: 120)
        let first = LiteratureNoteIndex.newPageURL(in: root, identity: identity, filename: filename)
        try Data("existing".utf8).write(to: first)
        let second = LiteratureNoteIndex.newPageURL(in: root, identity: identity, filename: filename)
        #expect(first != second)
        try Data("new".utf8).write(to: second)
        #expect(try String(contentsOf: first, encoding: .utf8) == "existing")
    }

    @Test func indexUsesOnlyAnUnambiguousFrontmatterIdentity() throws {
        #expect(LiteratureNoteIndex.itemLink(in: "---\nitemLink: [\(link)]\n---\n") == link)
        #expect(LiteratureNoteIndex.itemLink(in: "---\nitemLink: \"\(link)\"\n---\n") == link)
        #expect(LiteratureNoteIndex.itemLink(in: "---\nitemLink: [\(link), \(link)]\n---\n") == nil)
        #expect(LiteratureNoteIndex.itemLink(in: "---\nitemLink: \(link)\nitemLink: \(link)\n---\n") == nil)
        #expect(LiteratureNoteIndex.itemLink(in: "---\n标题: 其他\n---\n\(link)") == nil)
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try "---\nitemLink: [\(link)]\n---\n".write(to: dir.appendingPathComponent("a.md"), atomically: true, encoding: .utf8)
        #expect(try LiteratureNoteIndex.matchingPage(in: dir, itemLink: link)?.lastPathComponent == "a.md")
        try "---\nitemLink: \(link)\n---\n".write(to: dir.appendingPathComponent("b.md"), atomically: true, encoding: .utf8)
        #expect(throws: LiteratureFileError.duplicatePages) { try LiteratureNoteIndex.matchingPage(in: dir, itemLink: link) }
    }

    @Test func takeoverBacksUpAndProtectsConcurrentEdits() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("文献.md")
        let original = "---\nitemLink: [\(link)]\n---\n# 我自己的笔记\n"
        try original.write(to: url, atomically: true, encoding: .utf8)
        let worker = LiteratureNoteFiles(backupDirectory: dir.appendingPathComponent("backups"))
        let item = LiteratureAnnotation(AnnotationItem(id: "0-lumen-A", locator: .pdf(page: 0, charOffset: 0),
            quote: "摘录", note: "批注", hasHighlight: true, createdAt: .distantPast))
        let snapshot = LiteratureAttachmentSnapshot(documentID: "doc", title: "文章.pdf", annotations: [item])
        let prepared = try await worker.prepare(url: url, initial: "", snapshot: snapshot, baseline: nil)
        let backup = try #require(try await worker.commit(prepared, firstTakeover: true))
        #expect(try String(contentsOf: backup, encoding: .utf8) == original)
        #expect(try String(contentsOf: url, encoding: .utf8).contains("# 我自己的笔记"))
        let next = try await worker.prepare(url: url, initial: "", snapshot: snapshot, baseline: prepared.merge.baseline)
        let changed = "另一个程序刚修改"
        try changed.write(to: url, atomically: true, encoding: .utf8)
        do {
            _ = try await worker.commit(next, firstTakeover: false)
            Issue.record("A changed page was overwritten")
        } catch let error as LiteratureFileError { #expect(error == .noteChanged) }
        #expect(try String(contentsOf: url, encoding: .utf8) == changed)
    }
    @Test func filenameAndBibliographicTitleRemainIndependentDuringMigration() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let identity = LiteratureZoteroIdentity(library: "library", itemKey: "ABCDEFGH", attachmentKey: "ATTACH01", title: "文献正式标题", authors: "作者", year: "2026-03-15")
        let url = LiteratureNoteIndex.newPageURL(in: dir, identity: identity, filename: "原始文件名")
        #expect(url.lastPathComponent == "原始文件名.md")
        let worker = LiteratureNoteFiles(backupDirectory: dir.appendingPathComponent("backups"))
        let snapshot = LiteratureAttachmentSnapshot(documentID: "doc", title: "原始文件名.pdf", annotations: [])
        let page = try await worker.prepare(url: url, initial: LiteratureNoteIndex.newPage(for: identity), snapshot: snapshot, baseline: nil,
            metadata: identity, initializeProperties: true, filename: "原始文件名", migratePageStyle: true)
        #expect(try LiteraturePageEditor.properties(page.merge.document).first { $0.key == "标题" }?.value == "文献正式标题")
        #expect(!page.merge.document.contains("## 文献信息"))
        #expect(!page.merge.document.contains("## 我的整理"))
        #expect(try LiteraturePageEditor.properties(page.merge.document).first { $0.key == "日期" }?.value == "2026-03-15")
        #expect(try LiteraturePageEditor.properties(page.merge.document).first { $0.key == "时间" } == nil)
        let local = try await worker.prepare(url: dir.appendingPathComponent("local.md"), initial: "# Local file\n", snapshot: snapshot,
            baseline: nil, initializeProperties: true, filename: "Local file", migratePageStyle: true)
        #expect(try LiteraturePageEditor.properties(local.merge.document).first { $0.key == "标题" }?.value == "")
        var old = try LiteraturePageEditor.set(page.merge.document, key: "标题", value: "原始文件名", expected: LiteraturePageEditor.properties(page.merge.document).first { $0.key == "标题" })
        try old.write(to: url, atomically: true, encoding: .utf8)
        let repaired = try await worker.prepare(url: url, initial: "", snapshot: snapshot, baseline: page.merge.baseline,
            metadata: identity, metadataBaseline: page.metadataRendered, filename: "原始文件名", migratePageStyle: true)
        #expect(try LiteraturePageEditor.properties(repaired.merge.document).first { $0.key == "标题" }?.value == identity.title)
        old = try LiteraturePageEditor.set(old, key: "标题", value: "我自己改的标题", expected: LiteraturePageEditor.properties(old).first { $0.key == "标题" })
        old = try LiteraturePageEditor.set(old, key: "时间", value: "2020-01-02 03:04", expected: LiteraturePageEditor.properties(old).first { $0.key == "时间" })
        try old.write(to: url, atomically: true, encoding: .utf8)
        let custom = try await worker.prepare(url: url, initial: "", snapshot: snapshot, baseline: page.merge.baseline,
            metadata: identity, metadataBaseline: page.metadataRendered, filename: "原始文件名", migratePageStyle: true)
        #expect(try LiteraturePageEditor.properties(custom.merge.document).first { $0.key == "标题" }?.value == "我自己改的标题")
        #expect(try LiteraturePageEditor.properties(custom.merge.document).first { $0.key == "时间" }?.value == "2020-01-02 03:04")
    }
}
