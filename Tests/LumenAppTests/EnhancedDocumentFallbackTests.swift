import Foundation
import PDFKit
import Synchronization
import Testing
import LumenKit
@testable import LumenApp

private final class RefusedOCRProtocol: URLProtocol, @unchecked Sendable {
    static let calls = Mutex(0)
    static let disconnected = Mutex(false)
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.calls.withLock { $0 += 1 }
        if Self.disconnected.withLock({ $0 }) {
            client?.urlProtocol(self, didFailWithError: URLError(.networkConnectionLost))
            return
        }
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 429, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(#"{"message":"Service tier capacity exceeded for this model"}"#.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@Suite("增强解析失败隔离", .serialized)
struct EnhancedDocumentFallbackTests {
    @Test(arguments: [false, true])
    func serviceFailureKeepsNativeMaterialAndStopsRepeatedCloudCalls(disconnected: Bool) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("enhanced-fallback-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("fixture.pdf")
        let pdf = PDFDocument()
        for _ in 0..<3 { pdf.insert(PDFPage(), at: pdf.pageCount) }
        #expect(pdf.write(to: file))
        let evidence = (0..<3).map { DocumentEvidence(id: "p\($0)", path: file.path, label: "Page \($0)",
            locator: .pdf(page: $0, charOffset: 0), text: "Table 1: Native material must not disappear.") }
        let document = DocumentContext(version: try DocumentSourceVersion.current(path: file.path), path: file.path, evidence: evidence, missingUnits: [1], unitCount: 3)
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [RefusedOCRProtocol.self]
        let parser = MistralDocumentParser(client: .init(baseURL: "http://localhost/v1", apiKey: "", session: URLSession(configuration: config)), model: "fixed")
        let service = EnhancedDocumentService(parser: parser)
        var options = DocumentAIOptions(); options.parsingEnabled = true
        options.parsingBaseURL = "http://localhost/v1"; options.parsingModel = "fixed"
        RefusedOCRProtocol.calls.withLock { $0 = 0 }
        RefusedOCRProtocol.disconnected.withLock { $0 = disconnected }
        let first = try await service.enrich(document, options: options, allowedPages: [1], progress: { _ in })
        #expect(first.evidence == evidence)
        #expect(first.extractionNote?.contains(disconnected ? URLError(.networkConnectionLost).localizedDescription : "429") == true)
        #expect(first.extractionNote?.contains("本机提取") == true)
        #expect(first.extractionNote?.contains("未完成页：2") == true)
        let second = try await service.enrich(document, options: options, allowedPages: [1], progress: { _ in })
        #expect(second.evidence == evidence)
        #expect(RefusedOCRProtocol.calls.withLock { $0 } == 1)
    }

    @Test func readableCaptionsAndShortPagesNeverStartCloudOCR() async throws {
        let path = "/tmp/readable-\(UUID()).pdf"
        let sources = ["Table 1: Native cells.", "Fig. 2: A readable caption.", "摘要", "正文包含完整可读的文字层。"]
            .enumerated().map { DocumentEvidence(id: "p\($0.offset)", path: path, label: "Page \($0.offset)",
                locator: .pdf(page: $0.offset, charOffset: 0), text: $0.element) }
        let document = DocumentContext(version: "readable", path: path, evidence: sources, unitCount: sources.count)
        var options = DocumentAIOptions(); options.parsingEnabled = true
        // No real PDF or configured endpoint exists: readable input must return
        // before credentials, page rendering, cache creation or network access.
        let result = try await EnhancedDocumentService().enrich(document, options: options, progress: { _ in
            Issue.record("Readable pages unexpectedly entered enhanced parsing")
        })
        #expect(result == document)
    }
}
