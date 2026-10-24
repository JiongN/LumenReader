import Foundation
import Testing
@testable import LumenKit

private final class TranslationRequests: @unchecked Sendable {
    private let lock = NSLock()
    private var requests: [String: [URLRequest]] = [:]
    func append(_ request: URLRequest, scenario: String) -> Int {
        lock.withLock {
            requests[scenario, default: []].append(request)
            return requests[scenario, default: []].filter { $0.httpMethod == request.httpMethod }.count
        }
    }
    func read(_ scenario: String) -> [URLRequest] { lock.withLock { requests[scenario] ?? [] } }
}

private final class TranslationProtocol: URLProtocol, @unchecked Sendable {
    static let records = TranslationRequests()
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let scenario = request.value(forHTTPHeaderField: "X-Test-Scenario") ?? "normal"
        let attempt = Self.records.append(request, scenario: scenario)
        let isPost = request.httpMethod == "POST"
        if scenario == "network", isPost, attempt == 1 {
            client?.urlProtocol(self, didFailWithError: URLError(.networkConnectionLost))
            return
        }
        let status: Int
        if scenario == "rate", isPost { status = 429 }
        else if scenario == "auth", isPost, attempt == 1 { status = 403 }
        else if scenario == "server", isPost, attempt == 1 { status = 503 }
        else { status = 200 }
        let data: Data
        if !isPost {
            data = Data(#"params_AbusePreventionHelper = [123,"mock-token",3600000]; IG:"mock-ig"; _iid="mock-iid";"#.utf8)
        } else if scenario == "body-rate" { data = Data(#"{"statusCode":429}"#.utf8) }
        else if scenario == "empty" { data = Data(#"[{"translations":[{"text":" "}]}]"#.utf8) }
        else { data = Data(#"[{"translations":[{"text":"translated"}]}]"#.utf8) }
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status,
            httpVersion: "HTTP/1.1", headerFields: ["Retry-After": "120"])!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@Suite("Microsoft translation network recovery", .serialized)
struct MicrosoftTranslatorNetworkTests {
    private func session(_ scenario: String) -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [TranslationProtocol.self]
        configuration.httpAdditionalHeaders = ["X-Test-Scenario": scenario]
        return URLSession(configuration: configuration)
    }

    @Test func formPreservesPlusSignsAndRequestsHaveFiniteTimeouts() async throws {
        let session = session("form")
        defer { session.invalidateAndCancel() }
        let translator = MicrosoftTranslator(session: session)
        #expect(try await translator.translate("C++ + a&b=3", to: "zh-Hans") == "translated")
        let requests = TranslationProtocol.records.read("form")
        #expect(requests.count == 2)
        #expect(requests.allSatisfy { $0.timeoutInterval == 20 })
        let post = try #require(requests.last)
        // URLSession may represent the body as a stream when invoking URLProtocol.
        var data = post.httpBody ?? Data()
        if let stream = post.httpBodyStream {
            stream.open()
            defer { stream.close() }
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count <= 0 { break }
                data.append(contentsOf: buffer.prefix(count))
            }
        }
        let body = String(decoding: data, as: UTF8.self)
        #expect(body.contains("C%2B%2B%20%2B%20a%26b%3D3"))
    }

    @Test func rateLimitDoesNotRefreshCredentialsOrHammerServer() async throws {
        for scenario in ["rate", "body-rate"] {
            let session = session(scenario)
            defer { session.invalidateAndCancel() }
            let translator = MicrosoftTranslator(session: session)
            for _ in 0..<2 {
                do { _ = try await translator.translate("test", to: "zh-Hans"); Issue.record("Rate limit was ignored") }
                catch { if case MicrosoftTranslator.TranslationError.serverStatus(429, _) = error {} else { Issue.record("Wrong error: \(error)") } }
            }
            #expect(TranslationProtocol.records.read(scenario).count == 2)
        }
    }

    @Test func staleCredentialsRefreshOnceButTransientFailureReusesCredentials() async throws {
        for scenario in ["auth", "server", "network"] {
            let session = session(scenario)
            defer { session.invalidateAndCancel() }
            #expect(try await MicrosoftTranslator(session: session).translate("test", to: "zh-Hans") == "translated")
            let requests = TranslationProtocol.records.read(scenario)
            #expect(requests.filter { $0.httpMethod == "POST" }.count == 2)
            #expect(requests.filter { $0.httpMethod != "POST" }.count == (scenario == "auth" ? 2 : 1))
        }
    }

    @Test func emptyResultIsNotCachedAsSuccess() async throws {
        let session = session("empty")
        defer { session.invalidateAndCancel() }
        do { _ = try await MicrosoftTranslator(session: session).translate("test", to: "zh-Hans"); Issue.record("Empty result accepted") }
        catch { #expect(error as? MicrosoftTranslator.TranslationError == .emptyResponse) }
    }

    @Test func cancelledCallDoesNotStartRequests() async {
        let session = session("cancelled")
        defer { session.invalidateAndCancel() }
        let pending = Task {
            // Enter the translator with an already-cancelled task, not a test-side guard.
            try? await Task.sleep(for: .seconds(10))
            return try await MicrosoftTranslator(session: session).translate("test", to: "zh-Hans")
        }
        pending.cancel()
        do { _ = try await pending.value; Issue.record("Cancelled request returned") }
        catch { #expect(error is CancellationError) }
        #expect(TranslationProtocol.records.read("cancelled").isEmpty)
    }
}
