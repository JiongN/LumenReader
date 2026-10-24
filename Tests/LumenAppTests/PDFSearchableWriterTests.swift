import AppKit
import CoreText
import PDFKit
import Testing
import LumenKit
@testable import LumenApp

@Suite("可搜索 PDF 写回", .serialized)
@MainActor
struct PDFSearchableWriterTests {
    private let english = "Searchable PDF preserves the original page image."
    private let chinese = "扫描书籍保存文字，下次打开即可搜索。"

    private func fixture(rotation: Int = 0) throws -> URL {
        let data = NSMutableData()
        var box = CGRect(x: 0, y: 0, width: 600, height: 800)
        let consumer = try #require(CGDataConsumer(data: data))
        let context = try #require(CGContext(consumer: consumer, mediaBox: &box, nil))
        context.beginPDFPage(nil)
        for (text, y) in [(english, CGFloat(650)), (chinese, CGFloat(600))] {
            context.textPosition = CGPoint(x: 40, y: y)
            CTLineDraw(CTLineCreateWithAttributedString(NSAttributedString(string: text,
                attributes: [.font: NSFont.systemFont(ofSize: 16)])), context)
        }
        context.endPDFPage(); context.closePDF()
        let native = try #require(PDFDocument(data: data as Data))
        let image = try #require(PDFPageRenderer.render(native.page(at: 0)!, scale: 2))
        let scan = PDFDocument()
        let page = try #require(PDFPage(image: NSImage(cgImage: image, size: box.size)))
        page.setBounds(box, for: .mediaBox)
        page.setBounds(CGRect(x: 20, y: 20, width: 560, height: 760), for: .cropBox)
        page.rotation = rotation
        scan.insert(page, at: 0)
        scan.insert(try #require(native.page(at: 0)?.copy() as? PDFPage), at: 1)
        let note = PDFAnnotation(bounds: CGRect(x: 40, y: 520, width: 25, height: 25), forType: .text, withProperties: nil)
        note.contents = "Preserve this annotation"
        note.userName = "Other reader"
        page.addAnnotation(note)
        let link = PDFAnnotation(bounds: CGRect(x: 40, y: 450, width: 80, height: 25), forType: .link, withProperties: nil)
        link.action = PDFActionGoTo(destination: PDFDestination(page: page, at: CGPoint(x: 40, y: 650)))
        scan.page(at: 1)?.addAnnotation(link)
        let root = PDFOutline(), chapter = PDFOutline()
        chapter.label = "Scanned chapter"
        chapter.destination = PDFDestination(page: page, at: CGPoint(x: 40, y: 650))
        root.insertChild(chapter, at: 0)
        scan.outlineRoot = root
        scan.documentAttributes = [PDFDocumentAttribute.titleAttribute: "OCR fixture",
                                   PDFDocumentAttribute.keywordsAttribute: ["keep-keyword"]]
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("lumen-searchable-\(UUID()).pdf")
        try #require(scan.write(to: url))
        return url
    }

    private var lines: [PDFTextLine] {
        [.init(pageIndex: 0, text: english, bounds: CGRect(x: 40, y: 645, width: 390, height: 20)),
         .init(pageIndex: 0, text: chinese, bounds: CGRect(x: 40, y: 595, width: 300, height: 20))]
    }

    private func pixels(_ page: PDFPage) throws -> Data {
        let image = try #require(PDFPageRenderer.render(page, scale: 1))
        return try #require(image.dataProvider?.data) as Data
    }

    @Test func nativeHiddenTextIsReadableBeforeFileSerialization() throws {
        let url = try fixture()
        defer { try? FileManager.default.removeItem(at: url) }
        let source = try #require(PDFDocument(url: url)?.page(at: 0))
        let page = try PDFSearchableWriter.searchablePage(source: source, lines: lines)
        #expect(page.string?.contains(english) == true)
        #expect(page.string?.contains(chinese) == true)
        let document = PDFDocument()
        document.insert(page, at: 0)
        let serialized = try #require(document.dataRepresentation())
        let saved = try #require(PDFDocument(data: serialized)?.page(at: 0))
        #expect(saved.string?.contains(english) == true)
        #expect(saved.string?.contains(chinese) == true)
        #expect(saved.string == page.string)
    }

    @Test func invisibleLayerPreservesPixelsAnnotationsMetadataAndDestinations() throws {
        let url = try fixture()
        defer { try? FileManager.default.removeItem(at: url) }
        let original = try #require(PDFDocument(url: url))
        let before = try pixels(original.page(at: 0)!)
        let fingerprint = try PDFLargeAnnotationSave.fingerprint(of: url)
        _ = try PDFSearchableWriter.write(url: url, pages: [.init(index: 0, lines: lines)], expected: fingerprint)
        let reopened = try #require(PDFDocument(url: url))
        let page = try #require(reopened.page(at: 0))
        #expect(page.string?.contains(chinese) == true)
        #expect(page.string?.contains(english) == true)
        #expect(reopened.findString("保存文字", withOptions: []).count == 1)
        #expect(try pixels(page) == before)
        #expect(page.bounds(for: .cropBox) == original.page(at: 0)?.bounds(for: .cropBox))
        #expect(page.annotations.first?.contents == "Preserve this annotation")
        #expect(reopened.documentAttributes?[PDFDocumentAttribute.titleAttribute] as? String == "OCR fixture")
        #expect((reopened.documentAttributes?[PDFDocumentAttribute.keywordsAttribute] as? [String])?.contains("keep-keyword") == true)
        #expect(PDFSearchableWriter.completedPages(in: reopened) == [0])
        let destination = try #require(reopened.outlineRoot?.child(at: 0)?.destination?.page)
        #expect(reopened.index(for: destination) == 0)
        let link = try #require(reopened.page(at: 1)?.annotations.first?.action as? PDFActionGoTo)
        #expect(link.destination.page.map { reopened.index(for: $0) } == 0)
        let updated = try PDFLargeAnnotationSave.fingerprint(of: url)
        _ = try PDFSearchableWriter.write(url: url, pages: [.init(index: 0, lines: lines)], expected: updated)
        #expect(try PDFLargeAnnotationSave.fingerprint(of: url) == updated)
    }

    @Test func rotatedPageKeepsNativeRotationAndAppearance() throws {
        let url = try fixture(rotation: 90)
        defer { try? FileManager.default.removeItem(at: url) }
        let old = try #require(PDFDocument(url: url)?.page(at: 0))
        let before = try pixels(old)
        _ = try PDFSearchableWriter.write(url: url, pages: [.init(index: 0, lines: lines)], expected: PDFLargeAnnotationSave.fingerprint(of: url))
        let page = try #require(PDFDocument(url: url)?.page(at: 0))
        #expect(page.rotation == 90)
        #expect(try pixels(page) == before)
        #expect(page.string?.contains(chinese) == true)
    }

    @Test func blankPagesAreMarkedWithoutAddingFakeText() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("lumen-blank-\(UUID()).pdf")
        defer { try? FileManager.default.removeItem(at: url) }
        let doc = PDFDocument()
        let page = PDFPage()
        page.setBounds(CGRect(x: 0, y: 0, width: 600, height: 800), for: .mediaBox)
        doc.insert(page, at: 0)
        try #require(doc.write(to: url))
        _ = try await PDFDocumentContextCache().snapshot(path: url.path)
        let written = try #require(PDFDocument(url: url))
        #expect(PDFSearchableWriter.completedPages(in: written) == [0])
        let blankText = written.page(at: 0)?.string ?? ""
        #expect(blankText.isEmpty)
        try FileManager.default.removeItem(at: AppPaths.documentDirectory(forPath: url.path).appendingPathComponent("document-context.json"))
        let result = try await PDFDocumentContextCache().snapshot(path: url.path)
        #expect(result.ocrPages.isEmpty)
    }

    @Test func changedSourceAndBrokenExistingTextAreNotOverwritten() throws {
        let url = try fixture()
        defer { try? FileManager.default.removeItem(at: url) }
        let old = try PDFLargeAnnotationSave.fingerprint(of: url)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(10)], ofItemAtPath: url.path)
        let contents = try Data(contentsOf: url)
        #expect(throws: PDFSearchableWriter.WriteError.self) {
            try PDFSearchableWriter.write(url: url, pages: [.init(index: 0, lines: lines)], expected: old)
        }
        #expect(try Data(contentsOf: url) == contents)
        #expect(throws: PDFSearchableWriter.WriteError.self) {
            try PDFSearchableWriter.write(url: url, pages: [.init(index: 1, lines: lines)], expected: PDFLargeAnnotationSave.fingerprint(of: url))
        }
        #expect(try Data(contentsOf: url) == contents)
    }

    @Test func cancelledWriterLeavesSourceUntouched() async throws {
        let url = try fixture()
        defer { try? FileManager.default.removeItem(at: url) }
        let bytes = try Data(contentsOf: url)
        let old = try PDFLargeAnnotationSave.fingerprint(of: url)
        let values = lines
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try PDFSearchableWriter.write(url: url, pages: [.init(index: 0, lines: values)], expected: old)
        }
        do { _ = try await task.value; Issue.record("Expected cancellation") }
        catch { #expect(error is CancellationError) }
        #expect(try Data(contentsOf: url) == bytes)
    }

    @Test func fullOCRIsSavedAndWorksAfterDeletingTheExtractionCache() async throws {
        let url = try fixture()
        defer { try? FileManager.default.removeItem(at: url) }
        let value = try await PDFDocumentContextCache().snapshot(path: url.path)
        #expect(value.context.extractionNote == nil)
        #expect(value.pendingOCRLines == nil)
        let reopened = try #require(PDFDocument(url: url))
        #expect(PDFSearchableWriter.completedPages(in: reopened) == [0])
        #expect(reopened.page(at: 0)?.string?.contains("Searchable PDF") == true)
        let directory = AppPaths.documentDirectory(forPath: url.path)
        try FileManager.default.removeItem(at: directory.appendingPathComponent("document-context.json"))
        let restart = try await PDFDocumentContextCache().snapshot(path: url.path)
        #expect(restart.ocrPages.isEmpty)
        #expect(restart.context.text.contains("Searchable PDF"))
        #expect(PDFSearchableWriter.completedPages(in: try #require(PDFDocument(url: url))) == [0])
    }

    @Test func singlePageWritesAndLiveControllerRetainsTextAfterAnnotationSave() async throws {
        let url = try fixture()
        defer { try? FileManager.default.removeItem(at: url) }
        let controller = PDFController()
        _ = try #require(controller.load(url: url))
        let result = try await controller.recognize(page: 0)
        #expect(result.text.contains("Searchable PDF"))
        controller.flushPendingReadingPosition()
        #expect(controller.document?.page(at: 0)?.string?.contains("Searchable PDF") == true)
        #expect(controller.addNote(pageIndex: 0, anchorText: "", body: "After OCR"))
        while controller.pendingSaveCount > 0 { try await Task.sleep(for: .milliseconds(20)) }
        let saved = try #require(PDFDocument(url: url))
        #expect(saved.page(at: 0)?.string?.contains("Searchable PDF") == true)
        #expect(saved.page(at: 0)?.annotations.contains { $0.contents == "After OCR" } == true)
    }

    @Test func copyingWholeScannedDocumentCommitsOnlyOnce() async throws {
        let url = try fixture()
        defer { try? FileManager.default.removeItem(at: url) }
        let controller = PDFController()
        _ = try #require(controller.load(url: url))
        var commits = 0
        let observer = NotificationCenter.default.addObserver(forName: PDFSearchableWriter.didWrite, object: nil, queue: .main) { notification in
            guard notification.object as? String == url.path else { return }
            MainActor.assumeIsolated { commits += 1 }
        }
        defer { NotificationCenter.default.removeObserver(observer) }
        let report = await controller.extractFullText(allowOCR: true) { _ in }
        #expect(report.text.contains("Searchable PDF"))
        #expect(report.totalUnits == 2)
        #expect(commits == 1)
        #expect(PDFSearchableWriter.completedPages(in: try #require(PDFDocument(url: url))) == [0])
    }

    @Test func readOnlySourceRetainsOCRAndCanRetryWritingWithoutRecognizingAgain() async throws {
        let url = try fixture()
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            try? FileManager.default.removeItem(at: url)
        }
        let original = try Data(contentsOf: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o400], ofItemAtPath: url.path)
        let failed = try await PDFDocumentContextCache().snapshot(path: url.path)
        #expect(failed.context.extractionNote?.contains("未写回") == true)
        #expect(failed.pendingOCRLines != nil)
        #expect(failed.context.text.contains("Searchable PDF"))
        #expect(try Data(contentsOf: url) == original)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        let retry = try await PDFDocumentContextCache().snapshot(path: url.path)
        #expect(retry.context.extractionNote == nil)
        #expect(retry.pendingOCRLines == nil)
        #expect(PDFDocument(url: url)?.page(at: 0)?.string?.contains("Searchable PDF") == true)
    }

    @Test func lateCopyProgressCannotChangeAnotherTabOrReviveCancelledWork() async throws {
        let state = AppState()
        let first = ReaderSession(document: OpenDocument(url: URL(fileURLWithPath: "/tmp/lumen-copy-first.pdf"), kind: .pdf))
        let second = ReaderSession(document: OpenDocument(url: URL(fileURLWithPath: "/tmp/lumen-copy-second.pdf"), kind: .pdf))
        first.bridge.extractFullText = { _, progress in
            progress(.init(completed: 1, total: 2, phase: "First tab"))
            try? await Task.sleep(for: .milliseconds(80))
            progress(.init(completed: 2, total: 2, phase: "Late progress"))
            return DocumentTextReport()
        }
        state.add(first)
        state.copyFullText()
        let task = try #require(first.fullTextTask)
        await Task.yield()
        state.add(second)
        second.busy = .init(title: "Second tab", detail: "Unchanged", progress: 0)
        first.busyCancel?()
        await task.value
        #expect(first.busy == nil)
        #expect(first.fullTextTask == nil)
        #expect(second.busy?.detail == "Unchanged")
        first.close(); second.close()
    }
}
