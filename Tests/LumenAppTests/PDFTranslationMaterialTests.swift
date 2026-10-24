import Foundation
import PDFKit
import Synchronization
import Testing
import LumenKit
@testable import LumenApp

private final class TranslationOCRProtocol: URLProtocol, @unchecked Sendable {
    static let state = Mutex((calls: 0, response: Data(), status: 200, slow: false, cancellations: 0))
    private let stopped = Mutex(false)
    private let replied = Mutex(false)
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let value = Self.state.withLock { state in state.calls += 1; return state }
        let reply: @Sendable () -> Void = { [self] in
            guard !stopped.withLock({ $0 }) else { return }
            replied.withLock { $0 = true }
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: value.status, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: value.response)
            client?.urlProtocolDidFinishLoading(self)
        }
        if value.slow { DispatchQueue.global().asyncAfter(deadline: .now() + 1, execute: reply) }
        else { reply() }
    }
    override func stopLoading() {
        stopped.withLock { $0 = true }
        if !replied.withLock({ $0 }) { Self.state.withLock { $0.cancellations += 1 } }
    }
}

@Suite("翻译增强解析接入", .serialized)
struct PDFTranslationMaterialTests {
    private static let body = "Using the notion of risk aversion, this study explores the decisions teachers make when constructing a curriculum. The findings show that teachers largely adopt a low-risk approach."
    private static let keywords = "Risk taking; risk aversion; teachers’ decision-making; curriculum construction"

    private func native(page: Int = 0) -> [PDFParagraph] {
        [PDFParagraph(pageIndex: page, text: Self.body, bounds: CGRect(x: 60, y: 400, width: 280, height: 100), lineCount: 10, firstLineOrdinal: 0, isShort: false),
         PDFParagraph(pageIndex: page, text: Self.keywords, bounds: CGRect(x: 360, y: 460, width: 80, height: 40), lineCount: 4, firstLineOrdinal: 10, isShort: false)]
    }

    @Test func normalTextAndSymmetricColumnsDoNotUseCloud() {
        var columns = native()
        columns[1].bounds = CGRect(x: 360, y: 400, width: 280, height: 100)
        #expect(PDFTranslationMaterial.complexPages(columns).isEmpty)
        #expect(PDFTranslationMaterial.complexPages([columns[0]]).isEmpty)
        #expect(PDFTranslationMaterial.complexPages(native()) == [0])
    }

    @Test(arguments: [200, 429]) func enhancesOnlyRequestedPageAndReusesDurableCache(status: Int) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("translation-material-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("fixture.pdf")
        let pdf = PDFDocument(); pdf.insert(PDFPage(), at: 0); pdf.insert(PDFPage(), at: 1)
        #expect(pdf.write(to: file))
        let original = native(page: 1)
        let sources = original.map { DocumentEvidence(id: $0.id, path: file.path, label: "Page 2", locator: .pdf(page: 1, charOffset: 0), text: $0.text) }
        let context = DocumentContext(version: try DocumentSourceVersion.current(path: file.path), path: file.path, evidence: sources, unitCount: 2)
        let snapshot = PDFContextSnapshot(context: context, paragraphs: original, ocrPages: [])
        let raw = #"{"pages":[{"index":0,"markdown":"body","dimensions":{"width":600,"height":800},"blocks":[{"type":"text","content":"BODY","bbox":[60,300,340,400]},{"type":"text","content":"KEYWORDS","bbox":[360,300,440,340]},{"type":"header","content":"Journal name","bbox":[40,10,500,30]}]}]}"#
            .replacingOccurrences(of: "BODY", with: Self.body).replacingOccurrences(of: "KEYWORDS", with: Self.keywords)
        TranslationOCRProtocol.state.withLock { $0 = (0, Data(raw.utf8), status, false, 0) }
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [TranslationOCRProtocol.self]
        let parser = MistralDocumentParser(client: .init(baseURL: "http://localhost/v1", apiKey: "", session: URLSession(configuration: config)), model: "fixed")
        let service = EnhancedDocumentService(parser: parser)
        let material = PDFTranslationMaterial(service: service)
        var options = DocumentAIOptions(); options.parsingEnabled = true; options.parsingModel = "fixed"
        let first = try await material.prepare(snapshot, options: options, pageRange: 1...1)
        #expect(first.paragraphs.map(\.text) == original.map(\.text))
        #expect(first.paragraphs.allSatisfy { $0.pageIndex == 1 })
        if status == 200 {
            #expect(first.paragraphs[0].bounds.minY != original[0].bounds.minY)
            #expect(first.note?.contains("1/1") == true)
            // Reopening the service (not just reusing actor state) keeps the paid result.
            let reopened = PDFTranslationMaterial(service: EnhancedDocumentService(parser: parser))
            let second = try await reopened.prepare(snapshot, options: options, pageRange: 1...1)
            #expect(second.paragraphs == first.paragraphs)
        } else {
            #expect(first.paragraphs == original)
            #expect(first.note?.contains("429") == true)
            _ = try await material.prepare(snapshot, options: options, pageRange: 1...1)
        }
        #expect(TranslationOCRProtocol.state.withLock { $0.calls } == 1)
    }

    @Test func incompleteResultsNeverReplaceReadableBody() {
        let block = DocumentBlock(id: "no-box", kind: .paragraph, pageIndex: 0, order: 0, text: Self.body, parser: "fixed")
        #expect(PDFTranslationMaterial.paragraphs(blocks: [block], displaySize: CGSize(width: 600, height: 800)).isEmpty)
        #expect(!PDFTranslationMaterial.preservesBody(native(), replacement: [native()[1]]))
    }

    @Test @MainActor func stoppingPreparationCancelsCloudRequestAndDoesNotWriteLateResults() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("translation-cancel-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("fixture.pdf")
        let pdf = PDFDocument(); pdf.insert(PDFPage(), at: 0)
        #expect(pdf.write(to: file))
        TranslationOCRProtocol.state.withLock { $0 = (0, Data(#"{"pages":[{"index":0,"markdown":"late response"}]}"#.utf8), 200, true, 0) }
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [TranslationOCRProtocol.self]
        let parser = MistralDocumentParser(client: .init(baseURL: "http://localhost/v1", apiKey: "", session: URLSession(configuration: config)), model: "fixed")
        let controller = PDFTranslationController(material: PDFTranslationMaterial(service: EnhancedDocumentService(parser: parser)))
        var options = DocumentAIOptions(); options.parsingEnabled = true; options.parsingModel = "fixed"
        let task = Task {
            await controller.prepare(documentPath: file.path, target: "zh-Hans", engineID: "microsoft-bing", glossary: [], parsingOptions: options)
        }
        let deadline = Date().addingTimeInterval(3)
        while TranslationOCRProtocol.state.withLock({ $0.calls }) == 0, Date() < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(TranslationOCRProtocol.state.withLock { $0.calls } == 1)
        controller.stop()
        await task.value
        #expect(controller.phase == .cancelled)
        #expect(controller.paragraphs.isEmpty)
        #expect(TranslationOCRProtocol.state.withLock { $0.cancellations } == 1)
        let directory = AppPaths.documentDirectory(forPath: file.path).appendingPathComponent("enhanced")
        let files = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        #expect(files.filter { $0.hasSuffix(".json") }.isEmpty)
    }

    @Test func tableCellsKeepEmptyColumnsAndExcludeFurniture() throws {
        let cells = try #require(StructuredTable.cells(html: "<table><tr><th>A</th><th>B</th></tr><tr><td></td><td>17</td></tr></table>"))
        let blocks = [DocumentBlock(id: "table", kind: .table, pageIndex: 3, order: 1, text: "html", bounds: .init(x: 0.1, y: 0.2, width: 0.6, height: 0.3), parser: "fixed", tableCells: cells),
                      DocumentBlock(id: "header", kind: .header, pageIndex: 3, order: 0, text: "Header", parser: "fixed")]
        let result = PDFTranslationMaterial.paragraphs(blocks: blocks, displaySize: CGSize(width: 600, height: 800))
        #expect(result.count == 1)
        #expect(result[0].text == "A\tB\n\t17")
        #expect(result[0].kind == .table)
        #expect(result[0].bounds == CGRect(x: 60, y: 400, width: 360, height: 240))
    }
}
