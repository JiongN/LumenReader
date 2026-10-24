import AppKit
import CoreText
import PDFKit
import Testing
import LumenKit
@testable import LumenApp

@Suite("PDF 页码范围与原文依据", .serialized)
@MainActor
struct PDFRangeAndEvidenceTests {
    private func fixture() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("range-\(UUID()).pdf")
        var bounds = CGRect(x: 0, y: 0, width: 600, height: 800)
        let cg = try #require(CGContext(url as CFURL, mediaBox: &bounds, nil))
        for page in 0..<3 {
            cg.beginPDFPage(nil)
            cg.textPosition = CGPoint(x: 40, y: 650)
            CTLineDraw(CTLineCreateWithAttributedString(NSAttributedString(string: "Page \(page + 1) has distinct source evidence.",
                attributes: [.font: NSFont.systemFont(ofSize: 16)])), cg)
            cg.endPDFPage()
        }
        cg.closePDF()
        return url
    }

    @Test func selectedPagesDoNotPopulateFullCacheAndRestartReusesRange() async throws {
        let url = try fixture()
        defer { try? FileManager.default.removeItem(at: url) }
        let folder = AppPaths.documentDirectory(forPath: url.path)
        defer { try? FileManager.default.removeItem(at: folder) }
        let range = try await PDFDocumentContextCache().snapshot(path: url.path, pageRange: 1...1)
        #expect(!range.paragraphs.isEmpty)
        #expect(range.paragraphs.allSatisfy { $0.pageIndices == [1] })
        #expect(range.context.missingUnits == [0, 2])
        #expect(!FileManager.default.fileExists(atPath: folder.appendingPathComponent("document-context.json").path))
        let again = try await PDFDocumentContextCache().snapshot(path: url.path, pageRange: 1...1)
        #expect(again.context == range.context)
        let whole = try await PDFDocumentContextCache().snapshot(path: url.path)
        #expect(whole.context.missingUnits.isEmpty)
        #expect(Set(whole.paragraphs.flatMap(\.pageIndices)) == [0, 1, 2])
        #expect(whole.context.evidence.allSatisfy { $0.pdfFragments != nil })
    }

    @Test func invalidRangeIsRejectedRatherThanSilentlyExpanded() async throws {
        let url = try fixture()
        defer { try? FileManager.default.removeItem(at: url) }
        do {
            _ = try await PDFDocumentContextCache().snapshot(path: url.path, pageRange: 2...8)
            Issue.record("Out-of-bounds range was accepted")
        } catch {}
    }

    @Test func citationHighlightIsTransientAndDoesNotOpenSelectionToolbar() async throws {
        let url = try fixture()
        defer { try? FileManager.default.removeItem(at: url) }
        let bytes = try Data(contentsOf: url)
        let controller = PDFController()
        defer { controller.unload() }
        _ = try #require(controller.load(url: url))
        let page = try #require(controller.document?.page(at: 1))
        let before = page.annotations.count
        let evidence = DocumentEvidence(id: "p1", path: url.path, label: "第 2 页", locator: .pdf(page: 1, charOffset: 0), text: page.string ?? "")
        var citation = DocumentCitation(evidence: evidence, version: "v1")
        citation.quote = "distinct source evidence."
        controller.revealEvidence(citation)
        #expect(controller.currentPageIndex == 1)
        #expect(controller.view.currentSelection?.string?.contains("distinct source evidence") == true)
        #expect(!controller.view.isUserSelection)
        #expect(page.annotations.count == before)
        #expect(controller.pendingSaveCount == 0)
        #expect(try Data(contentsOf: url) == bytes)
    }

    @Test func selectionTranslationUsesExistingGeometryWithoutCreatingAnnotations() throws {
        let url = try fixture()
        defer { try? FileManager.default.removeItem(at: url) }
        let bytes = try Data(contentsOf: url)
        let controller = PDFController()
        defer { controller.unload() }
        let document = try #require(controller.load(url: url))
        let page = try #require(document.page(at: 1))
        let selected = try #require(page.selection(for: NSRange(location: 0, length: 12)))
        controller.view.setCurrentSelection(selected, animate: false)
        let paragraph = PDFParagraph(pageIndex: 1,
            text: TranslationTextSplitter.selectionText(selected.string ?? ""), bounds: .zero,
            lineCount: 1, firstLineOrdinal: 0, isShort: false)
        controller.revealTranslationParagraph(paragraph, preferredPage: 1)
        #expect(controller.view.currentSelection?.string?.contains("Page 2") == true)
        #expect(!controller.view.isUserSelection)
        #expect(page.annotations.isEmpty && controller.pendingSaveCount == 0)
        #expect(try Data(contentsOf: url) == bytes)
    }

    @Test func backgroundMetadataCannotPublishAfterUnload() async throws {
        let url = try fixture()
        defer { try? FileManager.default.removeItem(at: url) }
        let controller = PDFController(), viewport = PDFViewportState()
        _ = controller.load(url: url)
        controller.connectViewport(viewport)
        controller.unload()
        try await Task.sleep(for: .milliseconds(100))
        #expect(viewport.pageAspects.isEmpty)
        #expect(controller.document == nil)
    }

    @Test func crossPageEvidenceFindsQuotedPageAndIgnoresLineWrapWhitespace() throws {
        let url = try fixture()
        defer { try? FileManager.default.removeItem(at: url) }
        let controller = PDFController()
        defer { controller.unload() }
        let document = try #require(controller.load(url: url))
        let fragments = (0...1).map { PDFParagraphFragment(pageIndex: $0, bounds: CGRect(x: 35, y: 640, width: 450, height: 30)) }
        let paragraph = PDFParagraph(pageIndex: 0, text: "Page 1 has distinct source evidence. Page 2 has distinct source evidence.", bounds: fragments[0].bounds, lineCount: 2, firstLineOrdinal: 0, isShort: false, fragments: fragments)
        #expect(paragraph.pageLabel == "第 1–2 页")
        let evidence = DocumentEvidence(id: paragraph.id, path: url.path, label: paragraph.pageLabel, locator: .pdf(page: 0, charOffset: 0), text: paragraph.text, pdfFragments: fragments)
        var citation = DocumentCitation(evidence: evidence, version: "v1")
        citation.quote = "Page 2\n has  distinct source evidence."
        controller.revealEvidence(citation)
        #expect(controller.currentPageIndex == 1)
        #expect(controller.view.currentSelection?.string == document.page(at: 1)?.string?.trimmingCharacters(in: .whitespacesAndNewlines))
        #expect(!controller.view.isUserSelection)
        #expect(controller.pendingSaveCount == 0)
    }

    @Test func pageGeometryIsLazyAndTrackingStillReceivesIt() async throws {
        let url = try fixture()
        defer { try? FileManager.default.removeItem(at: url) }
        let controller = PDFController(), viewport = PDFViewportState()
        defer { controller.unload() }
        _ = try #require(controller.load(url: url))
        controller.connectViewport(viewport)
        try await Task.sleep(for: .milliseconds(300))
        #expect(viewport.pageAspects.isEmpty)
        viewport.isTracking = true
        for _ in 0..<50 where viewport.pageAspects.isEmpty {
            try await Task.sleep(for: .milliseconds(40))
        }
        #expect(viewport.pageAspects.count == 3)
        #expect(viewport.pageAspects.allSatisfy { abs($0 - 4.0 / 3.0) < 0.001 })
        controller.unload()
        #expect(viewport.pageAspects.isEmpty)
    }

    @Test func annotationCacheInvalidatesOnlyChangedPagesAndPreservesEdits() async throws {
        let url = try fixture()
        defer { try? FileManager.default.removeItem(at: url) }
        let controller = PDFController()
        defer { controller.unload() }
        _ = try #require(controller.load(url: url, attachToView: false))
        #expect(await controller.annotationsList().isEmpty)
        #expect(controller.annotationListCacheStats.pages == 3)
        #expect(controller.addNote(pageIndex: 1, anchorText: "", body: "first"))
        #expect(controller.annotationListCacheStats.pages == 2)
        let first = try #require(await controller.annotationsList().first)
        #expect(first.note == "first")
        #expect(controller.annotationListCacheStats.pages == 3)
        #expect(controller.updateNote(id: first.id, body: "updated"))
        #expect(await controller.annotationsList().first?.note == "updated")
        #expect(controller.deleteAnnotation(id: first.id))
        #expect(await controller.annotationsList().isEmpty)
        await controller.waitForPendingSaves()
        controller.unload()
        #expect(controller.annotationListCacheStats.pages == 0)
        #expect(controller.annotationListCacheStats.bytes == 0)
    }

    @Test func currentCitationVersionRejectsChangedAndMissingFiles() throws {
        let url = try fixture()
        defer { try? FileManager.default.removeItem(at: url) }
        let evidence = DocumentEvidence(id: "p0", path: url.path, label: "第 1 页", locator: .pdf(page: 0, charOffset: 0), text: "source text")
        let citation = DocumentCitation(evidence: evidence, version: try DocumentSourceVersion.current(path: url.path))
        #expect(try DocumentSourceVersion.matches(citation))
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1_500_000_000)], ofItemAtPath: url.path)
        #expect(try !DocumentSourceVersion.matches(citation))
        try FileManager.default.removeItem(at: url)
        #expect(throws: (any Error).self) { try DocumentSourceVersion.matches(citation) }
    }

    @Test func thumbnailRenderingSerializesConcurrentRequests() async throws {
        let url = try fixture()
        defer { try? FileManager.default.removeItem(at: url) }
        let renderer = PDFThumbnailRenderer(url: url)
        let valid = await withTaskGroup(of: Bool.self) { group in
            for index in 0..<12 {
                group.addTask {
                    let image = renderer.render(index: index % 3, size: CGSize(width: 90, height: 120))
                    return (image?.size.width ?? 0) > 0 && (image?.size.height ?? 0) > 0
                }
            }
            var results: [Bool] = []
            for await value in group { results.append(value) }
            return results.count == 12 && results.allSatisfy { $0 }
        }
        #expect(valid)
    }

    @Test func annotationSaveCannotOverwriteExternallyReplacedDocument() async throws {
        let url = try fixture()
        defer { try? FileManager.default.removeItem(at: url) }
        let controller = PDFController()
        defer { controller.unload() }
        _ = try #require(controller.load(url: url, attachToView: false))
        let updated = try #require(PDFDocument(url: url))
        let note = PDFAnnotation(bounds: CGRect(x: 20, y: 20, width: 24, height: 24), forType: .text, withProperties: nil)
        note.userName = "Lumen"; note.contents = "another window's note"
        updated.page(at: 0)?.addAnnotation(note)
        try #require(updated.write(to: url))
        let externalBytes = try Data(contentsOf: url)
        #expect(!controller.addNote(pageIndex: 0, anchorText: "", body: "stale window's note"))
        #expect(controller.pendingSaveCount == 0)
        #expect(try Data(contentsOf: url) == externalBytes)
        #expect(PDFDocument(url: url)?.page(at: 0)?.annotations.contains { $0.contents == note.contents } == true)
    }
}
