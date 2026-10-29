import Foundation
import Testing
import AppKit
import PDFKit
import CoreText
import LumenKit
@testable import LumenApp

@Suite @MainActor struct LiteratureSyncIntegrationTests {
    @Test func slowLibraryLookupDoesNotHoldFirstNotesAndEventuallyLinksWithoutLosingEdits() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let folder = root.appendingPathComponent("notes")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("local.pdf")
        try Data("fixture".utf8).write(to: source)
        let identity = LiteratureZoteroIdentity(library: "library", itemKey: "PARENT01", attachmentKey: "ATTACH01",
                                               title: "识别到的题名", authors: "作者", year: "2024")
        let sync = LiteratureSyncService(stateURL: root.appendingPathComponent("state.json"),
            backupDirectory: root.appendingPathComponent("backups"), associationRetryInterval: 0,
            resolve: { _ in try await Task.sleep(for: .seconds(2)); return identity }, refresh: { value, _ in value },
            readAnnotations: { _, id in .init(documentID: id, title: "local.pdf", annotations: []) })
        sync.configureDirectory(folder); sync.setEnabled(true)
        let started = Date()
        await sync.setDocumentSync(true, documentURL: source)
        #expect(Date().timeIntervalSince(started) < 1.8)
        let record = try #require(sync.record(for: source.path))
        #expect(record.zotero == nil)
        let page = URL(fileURLWithPath: record.notePath)
        let text = try String(contentsOf: page, encoding: .utf8)
        try LiteraturePageEditor.setReadingNotes(text, value: "等待检索时就开始写", expected: LiteraturePageEditor.readingNotes(text))
            .write(to: page, atomically: true, encoding: .utf8)
        await sync.reconcile()
        #expect(sync.record(id: record.id)?.zotero?.itemKey == identity.itemKey)
        #expect(try LiteraturePageEditor.readingNotes(String(contentsOf: page, encoding: .utf8)) == "等待检索时就开始写")
    }
    @Test func corruptAndDuplicateSyncRecordsRemainUntouchedAndCannotEnableWrites() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("state.json")
        let record = LiteratureSyncService.Record(id: "same", documentPath: "/paper.pdf", notePath: "/note.md", title: "paper")
        let encoder = JSONEncoder()
        let duplicateRecord = String(decoding: try encoder.encode(record), as: UTF8.self)
        let inputs = [Data("broken JSON".utf8), Data("{\"version\":1,\"notesDirectory\":\"/tmp\",\"enabled\":true,\"records\":[\(duplicateRecord),\(duplicateRecord)]}".utf8)]
        for bytes in inputs {
            try bytes.write(to: file)
            let sync = LiteratureSyncService(stateURL: file, backupDirectory: root.appendingPathComponent("backups"))
            #expect(!sync.enabled)
            #expect(sync.error != nil)
            sync.configureDirectory(root)
            sync.setEnabled(true)
            #expect(!sync.enabled)
            #expect(try Data(contentsOf: file) == bytes)
        }
    }
    private actor Catalog {
        var title = "文章"
        func setTitle(_ value: String) { title = value }
        func refresh(_ value: LiteratureZoteroIdentity) -> LiteratureZoteroIdentity {
            var updated = value
            updated.title = title
            return updated
        }
    }
    private actor SnapshotReads {
        private var count = 0
        func read(_ url: URL, _ id: String) async throws -> LiteratureAttachmentSnapshot {
            count += 1
            return try await LiteratureAnnotationReader.read(documentURL: url, documentID: id)
        }
        func total() -> Int { count }
    }
    private actor OfflineCatalog {
        var available = false
        let identity = LiteratureZoteroIdentity(library: "library", itemKey: "ABCDEFGH", attachmentKey: "ATTACH01", title: "Zotero题名", authors: "作者", year: "2024", journal: "期刊")
        func setAvailable() { available = true }
        func lookup() throws -> LiteratureZoteroIdentity {
            guard available else { throw ZoteroLookupError.unavailable }
            return identity
        }
    }
    @Test func offlineFirstNoteLaterLinksWithoutLosingUserEdits() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let folder = root.appendingPathComponent("notes")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("paper.pdf"); try Data("fixture".utf8).write(to: source)
        let catalog = OfflineCatalog()
        let service = LiteratureSyncService(stateURL: root.appendingPathComponent("state.json"), backupDirectory: root.appendingPathComponent("backups"), associationRetryInterval: 0, resolve: { _ in try await catalog.lookup() }, refresh: { value, _ in value }, readAnnotations: { _, id in .init(documentID: id, title: "paper.pdf", annotations: []) })
        service.configureDirectory(folder); service.setEnabled(true)
        await service.setDocumentSync(true, documentURL: source)
        let initial = try #require(service.record(for: source.path)); #expect(initial.zotero == nil)
        let page = URL(fileURLWithPath: initial.notePath)
        let text = try String(contentsOf: page, encoding: .utf8)
        #expect(try LiteraturePageEditor.properties(text).contains { $0.key == "作者" })
        #expect(try LiteraturePageEditor.properties(text).contains { $0.key == "日期" })
        var edited = try LiteraturePageEditor.setReadingNotes(text, value: "我的笔记 [[思考]]", expected: LiteraturePageEditor.readingNotes(text))
        edited = try LiteraturePageEditor.set(edited, key: "标题", value: "我的题名", expected: LiteraturePageEditor.properties(edited).first { $0.key == "标题" })
        edited = try LiteraturePageEditor.set(edited, key: "日期", value: nil, expected: LiteraturePageEditor.properties(edited).first { $0.key == "日期" })
        try edited.write(to: page, atomically: true, encoding: .utf8)
        await catalog.setAvailable()
        let other = folder.appendingPathComponent("已有文献.md")
        let otherText = "---\nitemLink: zotero://select/library/items/ABCDEFGH\n---\n已有内容"
        try otherText.write(to: other, atomically: true, encoding: .utf8)
        await service.syncNow(recordID: initial.id)
        #expect(service.record(for: source.path)?.zotero == nil)
        #expect(service.statuses[source.path]?.contains("已有 Zotero 文献页") == true)
        #expect(try String(contentsOf: other, encoding: .utf8) == otherText)
        #expect(try LiteraturePageEditor.readingNotes(String(contentsOf: page, encoding: .utf8)) == "我的笔记 [[思考]]")
        try FileManager.default.removeItem(at: other)
        await service.reconcile()
        let linked = try #require(service.record(for: source.path)); #expect(linked.zotero?.itemKey == "ABCDEFGH")
        #expect(URL(fileURLWithPath: linked.notePath).resolvingSymlinksInPath() == URL(fileURLWithPath: initial.notePath).resolvingSymlinksInPath())
        let result = try String(contentsOf: page, encoding: .utf8)
        #expect(try LiteraturePageEditor.readingNotes(result) == "我的笔记 [[思考]]")
        #expect(try LiteraturePageEditor.properties(result).first { $0.key == "标题" }?.value == "我的题名")
        #expect(try LiteraturePageEditor.properties(result).first { $0.key == "作者" }?.value == "作者")
        #expect(try LiteraturePageEditor.properties(result).first { $0.key == "日期" } == nil)
        #expect(LiteratureNoteIndex.itemLink(in: result) == linked.zotero?.itemLink)
        #expect(try String(contentsOfFile: #require(linked.backupPath), encoding: .utf8) == edited)
    }

    @Test func multilinePDFAndEPUBCommentsSurviveReopen() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let pdf = root.appendingPathComponent("proof.pdf")
        var bounds = CGRect(x: 0, y: 0, width: 400, height: 300)
        let context = try #require(CGContext(pdf as CFURL, mediaBox: &bounds, nil))
        context.beginPDFPage(nil); context.endPDFPage(); context.closePDF()
        let controller = PDFController()
        defer { controller.unload() }
        _ = try #require(controller.load(url: pdf, attachToView: false))
        #expect(controller.addNote(pageIndex: 0, anchorText: "", body: "原评论"))
        await controller.waitForPendingSaves()
        let snapshot = try await LiteratureAnnotationReader.read(documentURL: pdf, documentID: "proof")
        let id = try #require(snapshot.annotations.first?.id)
        #expect(controller.updateNote(id: id, body: "多行正文\n第二行"))
        await controller.waitForPendingSaves()
        let reopened = try await LiteratureAnnotationReader.read(documentURL: pdf, documentID: "proof")
        #expect(reopened.annotations.first?.note == "多行正文\n第二行")

        let epub = root.appendingPathComponent("proof.epub")
        try Data("fixture".utf8).write(to: epub)
        let epubData = AppPaths.documentDirectory(forPath: epub.path)
        defer { try? FileManager.default.removeItem(at: epubData) }
        let store = AnnotationStore(documentPath: epub.path)
        #expect(store.add(AnnotationItem(id: "epub-proof", locator: .epub(chapterIndex: 0, anchor: "", charOffset: 0),
            quote: "摘录", note: "原评论", hasHighlight: true, createdAt: .distantPast)))
        #expect(store.updateNote(id: "epub-proof", note: "双向试验\n第二行"))
        let reopenedEPUB = AnnotationStore(documentPath: epub.path)
        #expect(reopenedEPUB.items.first?.note == "双向试验\n第二行")
    }

    @Test func backgroundPDFSnapshotMatchesReaderAnnotations() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("snapshot-\(UUID()).pdf")
        defer { try? FileManager.default.removeItem(at: url) }
        var bounds = CGRect(x: 0, y: 0, width: 400, height: 300)
        let context = try #require(CGContext(url as CFURL, mediaBox: &bounds, nil))
        context.beginPDFPage(nil)
        context.textPosition = CGPoint(x: 40, y: 200)
        let text = NSAttributedString(string: "Selected passage for comment",
                                      attributes: [.font: NSFont.systemFont(ofSize: 18)])
        CTLineDraw(CTLineCreateWithAttributedString(text), context)
        context.endPDFPage()
        context.closePDF()
        let controller = PDFController()
        defer { controller.unload() }
        let document = try #require(controller.load(url: url, attachToView: false))
        let page = try #require(document.page(at: 0))
        let selection = try #require(page.selection(for: NSRange(location: 0, length: 8)))
        #expect(controller.addContextAnnotation(pageIndex: 0, selection: selection, body: "选区批注"))
        #expect(controller.addNote(pageIndex: 0, anchorText: "", body: "页面便签"))
        await controller.waitForPendingSaves()
        let inReader = await controller.annotationsList().map(LiteratureAnnotation.init)
        let snapshot = try await LiteratureAnnotationReader.read(documentURL: url, documentID: "test")
        #expect(snapshot.annotations == inReader)
        #expect(snapshot.annotations.contains { $0.quote.contains("Selected") && $0.note == "选区批注" })
        let bytes = try Data(contentsOf: url)
        let inHelper = try await LiteratureAnnotationReader.read(documentURL: url, documentID: "test", forceHelper: true)
        #expect(inHelper == snapshot)
        #expect(try Data(contentsOf: url) == bytes)
    }

    @Test func pdfAndEPUBShareExistingLiteraturePageWithoutOverwritingEdits() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let vault = root.appendingPathComponent("notes")
        try FileManager.default.createDirectory(at: vault, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let pdf = root.appendingPathComponent("paper.pdf")
        var bounds = CGRect(x: 0, y: 0, width: 400, height: 500)
        let context = try #require(CGContext(pdf as CFURL, mediaBox: &bounds, nil))
        context.beginPDFPage(nil)
        context.endPDFPage()
        context.closePDF()
        let controller = PDFController()
        defer { controller.unload() }
        _ = try #require(controller.load(url: pdf))
        #expect(controller.addNote(pageIndex: 0, anchorText: "", body: "PDF 原始批注"))
        await controller.waitForPendingSaves()
        let row = try #require(await controller.annotationsList().first)
        #expect(row.id.contains("-lumen-"))

        let identity = LiteratureZoteroIdentity(library: "library", itemKey: "ABCDEFGH", attachmentKey: "ATTACH01",
                                               title: "文章", authors: "作者", year: "2026")
        let note = vault.appendingPathComponent("原有文献页.md")
        let existing = "---\nitemLink: [\(identity.itemLink)]\n自定义: 保留\n---\n\n## 我的整理\n我自己的文字 [[概念]]\n"
        try existing.write(to: note, atomically: true, encoding: .utf8)
        let state = root.appendingPathComponent("state.json")
        let backups = root.appendingPathComponent("backups")
        let catalog = Catalog()
        let reads = SnapshotReads()
        let sync = LiteratureSyncService(stateURL: state, backupDirectory: backups,
                                         resolve: { _ in identity }, refresh: { value, _ in await catalog.refresh(value) },
                                         readAnnotations: { url, id in try await reads.read(url, id) })
        sync.configureDirectory(vault)
        sync.setEnabled(true)
        #expect(sync.enabled)
        await sync.adoptAndSync(documentURL: pdf)
        let first = try #require(sync.record(for: pdf.path))
        #expect(URL(fileURLWithPath: first.notePath).lastPathComponent == note.lastPathComponent)
        #expect(FileManager.default.contentsEqual(atPath: first.notePath, andPath: note.path))
        #expect(first.baseline != nil)
        #expect(await reads.total() == 1)
        let output = try String(contentsOf: note, encoding: .utf8)
        #expect(output.contains("PDF 原始批注"))
        #expect(output.contains("我自己的文字 [[概念]]"))
        #expect(try String(contentsOf: URL(fileURLWithPath: try #require(first.backupPath)), encoding: .utf8) == existing)

        await catalog.setTitle("更新后的文献题名")
        await sync.syncNow(recordID: first.id)
        #expect(await reads.total() == 1) // A metadata refresh must not reopen an unchanged PDF.
        let metadataUpdated = try String(contentsOf: note, encoding: .utf8)
        #expect(metadataUpdated.contains("更新后的文献题名"))
        #expect(metadataUpdated.contains("自定义: 保留"))

        #expect(controller.updateNote(id: row.id, body: "PDF 修改后"))
        await controller.waitForPendingSaves()
        await sync.sync(recordID: first.id)
        #expect(await reads.total() == 2) // A saved PDF change must invalidate the snapshot.
        #expect(try String(contentsOf: note, encoding: .utf8).contains("PDF 修改后"))

        let epub = root.appendingPathComponent("第二附件.epub")
        try Data("fixture".utf8).write(to: epub)
        let epubData = AppPaths.documentDirectory(forPath: epub.path)
        defer { try? FileManager.default.removeItem(at: epubData) }
        let store = AnnotationStore(documentPath: epub.path)
        #expect(store.add(AnnotationItem(id: "epub-1", locator: .epub(chapterIndex: 1, anchor: "", charOffset: 0),
            quote: "EPUB 摘录", note: "EPUB 评论", hasHighlight: true, createdAt: .distantPast)))
        await sync.adoptAndSync(documentURL: epub)
        let second = try #require(sync.record(for: epub.path))
        #expect(second.notePath == first.notePath)
        let both = try String(contentsOf: note, encoding: .utf8)
        #expect(both.contains("PDF 修改后"))
        #expect(both.contains("EPUB 评论"))
        #expect(both.contains("我自己的文字 [[概念]]"))

        var changed = both.replacingOccurrences(of: "> PDF 修改后", with: "> Obsidian 的修改")
        changed = try LiteraturePageEditor.setReadingNotes(changed, value: "外部阅读笔记 [[概念]]", expected: LiteraturePageEditor.readingNotes(changed))
        changed = try LiteraturePageEditor.set(changed, key: "总结", value: "外部总结", expected: LiteraturePageEditor.properties(changed).first { $0.key == "总结" })
        #expect(changed != both)
        try changed.write(to: note, atomically: true, encoding: .utf8)
        await sync.sync(recordID: first.id)
        #expect(sync.statuses[pdf.path]?.contains("已暂停") != true)
        let refreshed = try String(contentsOf: note, encoding: .utf8)
        #expect(refreshed.contains("> PDF 修改后"))
        #expect(refreshed.contains("EPUB 评论"))
        #expect(try LiteraturePageEditor.readingNotes(refreshed) == "外部阅读笔记 [[概念]]")
        #expect(try LiteraturePageEditor.properties(refreshed).first { $0.key == "总结" }?.value == "外部总结")
        let conflictBackup = try #require(sync.record(for: pdf.path)?.backupPath)
        #expect(try String(contentsOfFile: conflictBackup, encoding: .utf8) == changed)
        #expect(try #require(PDFDocument(url: pdf)?.page(at: 0)?.annotations.first { $0.userName == "Lumen" }).contents == "PDF 修改后")
        let restarted = LiteratureSyncService(stateURL: state, backupDirectory: backups,
                                              resolve: { _ in identity }, refresh: { value, _ in value })
        #expect(restarted.records.count == 2)
        #expect(restarted.record(for: pdf.path)?.baseline != nil)
    }

    @Test func renamedPageIsFoundAndDuplicateIdentityPausesBothKindsOfNotes() async throws {
        for standalone in [false, true] {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            let notes = root.appendingPathComponent("notes")
            try FileManager.default.createDirectory(at: notes, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: root) }
            let pdf = root.appendingPathComponent("paper.pdf")
            var bounds = CGRect(x: 0, y: 0, width: 300, height: 300)
            let context = try #require(CGContext(pdf as CFURL, mediaBox: &bounds, nil))
            context.beginPDFPage(nil); context.endPDFPage(); context.closePDF()
            let identity = LiteratureZoteroIdentity(library: "library", itemKey: "ABCDEFGH", attachmentKey: "ATTACH01",
                                                    title: "文章", authors: "作者", year: "2026")
            let sync = LiteratureSyncService(stateURL: root.appendingPathComponent("state.json"),
                backupDirectory: root.appendingPathComponent("backups"), resolve: { _ in if standalone { throw ZoteroLookupError.unavailable }; return identity }, refresh: { value, _ in value })
            sync.configureDirectory(notes)
            sync.setEnabled(true)
            await sync.adoptAndSync(documentURL: pdf)
            let original = try #require(sync.record(for: pdf.path))
            #expect(original.baseline != nil, "initial status: \(sync.statuses[pdf.path] ?? "none")")
            let oldPage = URL(fileURLWithPath: original.notePath)
            if !standalone {
                let created = try String(contentsOf: oldPage, encoding: .utf8)
                #expect(LiteratureNoteIndex.itemLink(in: created) == identity.itemLink, "created page: \(created)")
            }
            let renamed = notes.appendingPathComponent("重命名.md")
            try FileManager.default.moveItem(at: oldPage, to: renamed)
            await sync.sync(recordID: original.id)
            #expect(URL(fileURLWithPath: sync.record(id: original.id)?.notePath ?? "").lastPathComponent == renamed.lastPathComponent,
                    "renamed status: \(sync.statuses[pdf.path] ?? "none")")
            let duplicate = notes.appendingPathComponent("重复.md")
            try FileManager.default.copyItem(at: renamed, to: duplicate)
            let before = try Data(contentsOf: renamed)
            await sync.sync(recordID: original.id)
            #expect(sync.statuses[pdf.path]?.contains("多个文献页") == true,
                    "duplicate status: \(sync.statuses[pdf.path] ?? "none")")
            #expect(try Data(contentsOf: renamed) == before)
            #expect(try Data(contentsOf: duplicate) == before)
        }
    }

    @Test func zoteroOneAutoModeMustBeExplicitlyOff() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let profile = root.appendingPathComponent("profile")
        let extensions = profile.appendingPathComponent("extensions")
        try FileManager.default.createDirectory(at: extensions, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data().write(to: extensions.appendingPathComponent("zoteroif@qnscholar.xpi"))
        let notes = root.appendingPathComponent("笔记")
        let encoded = try #require(String(data: JSONEncoder().encode(notes.path), encoding: .utf8))
        let prefix = "user_pref(\"extensions.zotero.zoteroif.obsidianmarkdownfolderpath\", \(encoded));\n"
        let prefs = profile.appendingPathComponent("prefs.js")
        try prefix.write(to: prefs, atomically: true, encoding: .utf8)
        #expect(!ZoteroOneWriterGuard.isSafe(notesDirectory: notes, profileRoot: root))
        try (prefix + "user_pref(\"extensions.zotero.zoteroif.obsidianautoupdatenotes\", false);\n").write(to: prefs, atomically: true, encoding: .utf8)
        #expect(ZoteroOneWriterGuard.isSafe(notesDirectory: notes, profileRoot: root))
    }

    @Test func documentSyncSwitchRequiresOptInPersistsPauseAndCancelsQueuedSaves() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let notes = root.appendingPathComponent("notes")
        try FileManager.default.createDirectory(at: notes, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("paper.pdf")
        try Data("initial comment".utf8).write(to: source)
        let identity = LiteratureZoteroIdentity(library: "library", itemKey: "ABCDEFGH", attachmentKey: "ATTACH01",
            title: "题名", authors: "作者", year: "2026")
        let state = root.appendingPathComponent("state.json")
        let reader: @Sendable (URL, String) async throws -> LiteratureAttachmentSnapshot = { url, id in
            let note = try String(contentsOf: url, encoding: .utf8)
            return .init(documentID: id, title: "paper.pdf", annotations: [LiteratureAnnotation(AnnotationItem(
                id: "stable", locator: .pdf(page: 0, charOffset: 0), quote: "摘录", note: note, hasHighlight: true, createdAt: .distantPast))])
        }
        let sync = LiteratureSyncService(stateURL: state, backupDirectory: root.appendingPathComponent("backups"),
            resolve: { _ in identity }, refresh: { value, _ in value }, readAnnotations: reader)
        sync.configureDirectory(notes)
        sync.setEnabled(true)
        sync.annotationSaved(documentURL: source)
        try await Task.sleep(for: .milliseconds(1100))
        #expect(sync.records.isEmpty)
        #expect(try FileManager.default.contentsOfDirectory(atPath: notes.path).isEmpty)

        await sync.setDocumentSync(true, documentURL: source)
        let record = try #require(sync.record(for: source.path))
        let page = URL(fileURLWithPath: record.notePath)
        let original = try Data(contentsOf: page)
        #expect(!record.paused)
        try Data("changed after sync was scheduled".utf8).write(to: source)
        sync.annotationSaved(documentURL: source)
        await sync.setDocumentSync(false, documentURL: source)
        await sync.syncNow(recordID: record.id)
        try await Task.sleep(for: .milliseconds(1100))
        #expect(sync.record(id: record.id)?.paused == true)
        #expect(try Data(contentsOf: page) == original)

        let restarted = LiteratureSyncService(stateURL: state, backupDirectory: root.appendingPathComponent("backups"),
            resolve: { _ in identity }, refresh: { value, _ in value }, readAnnotations: reader)
        #expect(restarted.record(for: source.path)?.paused == true)
        await restarted.setDocumentSync(true, documentURL: source)
        #expect(restarted.record(for: source.path)?.paused == false)
        #expect(try String(contentsOf: page, encoding: .utf8).contains("changed after sync was scheduled"))
    }
}
