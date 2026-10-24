import Foundation
import Testing
import Synchronization
@testable import LumenKit

private final class OfficialTranslationProtocol: URLProtocol, @unchecked Sendable {
    static let requests = Mutex<[(URLRequest, Data)]>([])
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        var body = request.httpBody ?? Data()
        if let stream = request.httpBodyStream {
            stream.open(); defer { stream.close() }
            var buffer = [UInt8](repeating: 0, count: 2048)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count <= 0 { break }; body.append(contentsOf: buffer.prefix(count))
            }
        }
        Self.requests.withLock { $0.append((request, body)) }
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(#"[{"translations":[{"text":"翻译结果","to":"zh-Hans"}]}]"#.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@Suite("官方翻译 API 请求", .serialized)
struct OfficialTranslationEngineTests {
    @Test func azureV3RequestUsesHeaderKeyAndEscapedQuery() async throws {
        OfficialTranslationProtocol.requests.withLock { $0 = [] }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [OfficialTranslationProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let engine = OfficialTranslationEngine(baseURL: "https://translator.example", key: "test-key", region: "eastus", session: session)
        #expect(try await engine.translate("A + B", to: "简体中文", from: "en") == "翻译结果")
        let captured = try #require(OfficialTranslationProtocol.requests.withLock { $0.last })
        let request = captured.0
        #expect(request.url?.absoluteString == "https://translator.example/translate?api-version=3.0&to=zh-Hans&from=en")
        #expect(request.value(forHTTPHeaderField: "Ocp-Apim-Subscription-Key") == "test-key")
        #expect(request.value(forHTTPHeaderField: "Ocp-Apim-Subscription-Region") == "eastus")
        #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
        let body = try #require(JSONSerialization.jsonObject(with: captured.1) as? [[String: String]])
        #expect(body.first?["Text"] == "A + B")
    }
}
