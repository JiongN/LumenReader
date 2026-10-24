import Foundation
import Testing
import Synchronization
@testable import LumenKit

private final class IntelligenceProtocol: URLProtocol, @unchecked Sendable {
    static let captured = Mutex<[Data]>([])
    static let reply = Mutex<String>("")
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        var data = request.httpBody ?? Data()
        if let stream = request.httpBodyStream {
            stream.open(); defer { stream.close() }
            var buffer = [UInt8](repeating: 0, count: 8192)
            while stream.hasBytesAvailable {
                let size = stream.read(&buffer, maxLength: buffer.count)
                if size <= 0 { break }; data.append(contentsOf: buffer.prefix(size))
            }
        }
        Self.captured.withLock { $0.append(data) }
        let reply = Self.reply.withLock { $0 }
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil,
            headerFields: ["Content-Type": reply.hasPrefix("data:") ? "text/event-stream" : "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(reply.utf8)); client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@Suite("文档智能边界", .serialized)
struct DocumentIntelligenceTests {
    private func source(_ id: String, _ text: String) -> DocumentEvidence {
        .init(id: id, path: "/source.pdf", label: "第 3 页", locator: .pdf(page: 2, charOffset: 0), text: text)
    }
    private func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [IntelligenceProtocol.self]
        return URLSession(configuration: configuration)
    }

    @Test func readbackFindsLateSentenceAndRetainsIdentity() {
        let original = source("last", String(repeating: "Other unrelated context. ", count: 500) + "The exceptional result is 17 percent under condition Delta. End.")
        let excerpt = DocumentRetrieval.excerpt(original, query: "exceptional Delta", tokenLimit: 96)
        #expect(excerpt.text.contains("17 percent"))
        #expect(excerpt.citationID == original.citationID)
        #expect(excerpt.locator == original.locator)
        #expect(ContextBudget.estimatedTokens(excerpt.text) <= 96)
    }

    @Test func lexicalRankingUsesWordsAndChineseSegmentation() {
        let index = DocumentRetrieval([source("wrong", "Cartography cartography."), source("right", "The art of education requires 教育交往与理解。")])
        #expect(index.search("art").first?.evidence.id == "right")
        #expect(index.search("教育交往").first?.evidence.id == "right")
        #expect(index.search("absent").isEmpty)
    }

    @Test func multimodalRequestCarriesActualBytesAndTextRemainsCompatible() async throws {
        IntelligenceProtocol.captured.withLock { $0 = [] }
        IntelligenceProtocol.reply.withLock { $0 = "data: {\"choices\":[{\"delta\":{\"content\":\"read image\"},\"finish_reason\":\"stop\"}]}\n\ndata: [DONE]\n\n" }
        let config = AIProviderConfig(name: "vision", baseURL: "http://localhost/v1", models: ["vision"], selectedModel: "vision")
        let provider = OpenAICompatibleProvider(config: config, apiKey: "", session: session())
        let image = AIImage(data: Data([1, 2, 3]), label: "page 3")
        for try await _ in provider.stream(messages: [.system("read"), .init(role: .user, content: "explain", images: [image])]) {}
        let data = try #require(IntelligenceProtocol.captured.withLock { $0.last })
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let messages = try #require(object["messages"] as? [[String: Any]])
        #expect(messages[0]["content"] as? String == "read")
        let parts = try #require(messages[1]["content"] as? [[String: Any]])
        #expect((parts.last?["image_url"] as? [String: String])?["url"] == "data:image/jpeg;base64,AQID")
        #expect(parts.first?["text"] as? String == "explain")
    }

    @Test func embeddingResponseMustCoverEveryInputExactlyOnce() async throws {
        IntelligenceProtocol.reply.withLock { $0 = "{\"data\":[{\"index\":0,\"embedding\":[1,0]},{\"index\":0,\"embedding\":[0,1]}]}" }
        let client = DocumentAIClient(baseURL: "http://localhost/v1", apiKey: "", session: session())
        await #expect(throws: AIError.self) { try await client.embeddings(["one", "two"], model: "embedding") }
        #expect(DocumentAIClient.cosine([1, 0], [0, 1]) == 0)
        #expect(DocumentAIClient.cosine([1], [1, 2]) == 0)
    }

    @Test func parserPreservesFurnitureAndRefusesWrongPages() throws {
        let data = Data(#"{"pages":[{"index":0,"markdown":"body","dimensions":{"width":100,"height":200},"header":"running title","blocks":[{"type":"paragraph","content":"body","bbox":[10,20,90,180]}]}],"model":"fixed"}"#.utf8)
        let raw = try JSONDecoder().decode(DocumentJSON.self, from: data)
        let page = try MistralDocumentParser.normalized(raw, pageIndex: 19, parser: "fixed")
        #expect(page.pageIndex == 19)
        #expect(page.blocks[0].bounds?.x == 0.1)
        #expect(page.blocks.contains { $0.kind == .header && $0.text == "running title" })
        #expect(page.raw == raw)
        let bad = try JSONDecoder().decode(DocumentJSON.self, from: Data(#"{"pages":[{"index":3,"markdown":"wrong"}]}"#.utf8))
        #expect(throws: AIError.self) { try MistralDocumentParser.normalized(bad, pageIndex: 19, parser: "fixed") }
    }

    @Test func newSettingsDecodePartialOptionsAndLegacyDocument() throws {
        let options = try JSONDecoder().decode(DocumentAIOptions.self, from: Data(#"{"parsingEnabled":true}"#.utf8))
        #expect(options.parsingEnabled)
        #expect(options.parsingModel == "mistral-ocr-4-1")
        #expect(options.visionProviderID == nil)
        #expect(!DocumentBlock.Bounds(x: 0.5, y: 0, width: 0.8, height: 1).isValid)
        let context = DocumentContext(version: "one", path: "/source.pdf", evidence: [source("p", "text")], unitCount: 3)
        #expect(context.blocks.count == 1)
        #expect(try JSONDecoder().decode(DocumentContext.self, from: JSONEncoder().encode(context)) == context)
    }

    @Test func officialOCRFieldsKeepGeometryTypesConfidenceAndOneTable() throws {
        let json = #"{"pages":[{"index":0,"markdown":"body","dimensions":{"width":100,"height":200},"blocks":[{"type":"title","content":"Heading","top_left_x":10,"top_left_y":20,"bottom_right_x":90,"bottom_right_y":40,"confidence_scores":{"average_content_confidence_score":0.98}},{"type":"table","table_id":"tbl-0.html","top_left_x":10,"top_left_y":50,"bottom_right_x":90,"bottom_right_y":180}],"tables":[{"id":"tbl-0.html","content":"<table><tr><th>A</th><td>17</td></tr></table>"}]}]}"#
        let raw = try JSONDecoder().decode(DocumentJSON.self, from: Data(json.utf8))
        let page = try MistralDocumentParser.normalized(raw, pageIndex: 2, parser: "fixed")
        #expect(page.blocks[0].kind == .heading)
        #expect(page.blocks[0].bounds?.x == 0.1)
        #expect(page.blocks[0].confidence == 0.98)
        #expect(page.blocks.filter { $0.kind == .table }.count == 1)
        #expect(page.blocks[1].tableCells?.last?.text == "17")
        #expect(page.blocks[1].bounds?.height == 0.65)
    }

    @Test func unavailableOldOCRDefaultMigratesOnlyOnOfficialService() throws {
        let official = try JSONDecoder().decode(DocumentAIOptions.self, from: Data(#"{"parsingModel":"mistral-ocr-4-0"}"#.utf8))
        #expect(official.parsingModel == "mistral-ocr-4-1")
        let custom = try JSONDecoder().decode(DocumentAIOptions.self, from: Data(#"{"parsingBaseURL":"http://localhost/v1","parsingModel":"mistral-ocr-4-0"}"#.utf8))
        #expect(custom.parsingModel == "mistral-ocr-4-0")
        let message = DocumentAIClient.failureMessage(Data(#"{"message":"Service tier capacity exceeded for this model secret-test-key"}"#.utf8), status: 429)
        #expect(message.contains("服务层级"))
        #expect(!message.contains("secret-test-key"))
    }

    @Test func cancelledQueuedRequestDoesNotLeakPermit() async throws {
        let gate = AsyncRequestGate(limit: 1)
        try await gate.acquire()
        let pending = Task { try await gate.acquire() }
        await Task.yield(); pending.cancel()
        do { try await pending.value; Issue.record("Cancelled waiter acquired the gate") } catch {}
        await gate.release()
        try await gate.acquire()
        await gate.release()
    }
}
