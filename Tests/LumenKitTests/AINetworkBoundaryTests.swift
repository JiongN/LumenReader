import Foundation
import Testing
@testable import LumenKit

private final class ModelListProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let oversized = request.url!.path.contains("large")
        let data = oversized ? Data(repeating: 32, count: 2 * 1024 * 1024 + 1)
            : Data(#"{"data":[{"id":"b"},{"id":"a"}]}"#.utf8)
        let headers = request.url!.path.contains("declared") ? ["Content-Length": "999999999"] : [:]
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200,
            httpVersion: "HTTP/1.1", headerFields: headers)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@Suite("AI 网络安全边界")
struct AINetworkBoundaryTests {
    private func provider(_ base: String, session: URLSession? = nil) -> OpenAICompatibleProvider {
        .init(config: .init(name: "test", baseURL: base, models: ["test"], selectedModel: "test"), apiKey: "", session: session)
    }

    @Test func endpointRejectsAmbiguousOrCredentialBearingURLs() {
        #expect(!AIError.invalidBaseURL("https://user:secret@example.com?key=secret").localizedDescription.contains("secret"))
        for base in ["file:///tmp/model", "ftp://example.com", "https://u:p@example.com", "https://example.com?key=x", "https://example.com#fragment"] {
            #expect(provider(base).endpoint("/models") == nil)
        }
        #expect(provider("https://api.openai.com/").endpoint("/models")?.path == "/v1/models")
        #expect(provider("https://notopenai.com/").endpoint("/models")?.path == "/models")
        #expect(provider("http://localhost:11434/v1/chat/completions").endpoint("/models")?.path == "/v1/models")
    }

    @Test func redirectKeepsOriginAndCannotDowngradeTLS() {
        let source = URL(string: "https://api.example.com/v1/chat/completions")!
        for target in ["http://api.example.com/v1", "https://other.example.com/v1", "https://api.example.com:444/v1", "https://user@api.example.com/v1"] {
            #expect(!SameOriginRedirectPolicy.permits(from: source, to: URL(string: target)))
        }
        #expect(SameOriginRedirectPolicy.permits(from: source, to: URL(string: "https://api.example.com:443/v2")))
    }

    @Test func modelListsAreBoundedWithAndWithoutContentLength() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ModelListProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        #expect(try await provider("http://localhost/normal", session: session).availableModels() == ["a", "b"])
        for path in ["large", "declared"] {
            do {
                _ = try await provider("http://localhost/\(path)", session: session).availableModels()
                Issue.record("Oversized response accepted")
            } catch { #expect(error as? AIError == .responseTooLarge) }
        }
    }
}
