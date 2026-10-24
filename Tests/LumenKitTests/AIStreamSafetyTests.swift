import Foundation
import Testing
import Synchronization
@testable import LumenKit

private final class FaultStreamProtocol: URLProtocol, @unchecked Sendable {
    private let stopped = Mutex(false)
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let path = request.url!.path
        if path.contains("noHeaders") { return }
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "text/event-stream"])!, cacheStoragePolicy: .notAllowed)
        if path.contains("doneCRLF") {
            send("data: {\"choices\":[{\"delta\":{\"content\":\"完成\"}}]}\r\n\r\ndata: [DONE]\r\n\r\n")
        } else if path.contains("heartbeat") {
            for tick in 0..<15 { later(Double(tick) * 0.04, text: ": ping\n\n") }
        } else if path.contains("reasonForever") {
            for tick in 0..<30 { later(Double(tick) * 0.04, text: "data: {\"choices\":[{\"delta\":{\"reasoning_content\":\"思考\"}}]}\n\n") }
        } else if path.contains("finishTail") {
            send("data: {\"choices\":[{\"delta\":{\"content\":\"完成\"},\"finish_reason\":\"stop\"}]}\n\n")
            later(0.02, text: "data: {\"choices\":[],\"usage\":{\"prompt_tokens\":12,\"completion_tokens\":2}}\n\n")
        } else if path.contains("oversizedLine") {
            send(String(repeating: "x", count: 300_000))
        } else if path.contains("oversized") {
            send("data: {\"choices\":[{\"delta\":{\"content\":\"\(String(repeating: "x", count: 2000))\"}}]}\n\n")
        } else if path.contains("tool") {
            send("data: {\"choices\":[{\"delta\":{},\"finish_reason\":\"tool_calls\"}]}\n\n")
        } else if path.contains("truncated") {
            send("data: {\"choices\":[{\"delta\":{\"content\":\"partial\"},\"finish_reason\":\"length\"}]}\n\n")
        } else if path.contains("disconnect") {
            send("data: {\"choices\":[{\"delta\":{\"content\":\"partial\"}}]}\n\n")
            client?.urlProtocolDidFinishLoading(self)
        }
    }
    private func send(_ text: String) {
        guard !stopped.withLock({ $0 }) else { return }
        client?.urlProtocol(self, didLoad: Data(text.utf8))
    }
    private func later(_ seconds: Double, text: String) {
        DispatchQueue.global().asyncAfter(deadline: .now() + seconds) { self.send(text) }
    }
    override func stopLoading() { stopped.withLock { $0 = true } }
}

@Suite("流式卡死与异常输出防护", .serialized)
struct AIStreamSafetyTests {
    private func run(_ path: String, configure: (inout AIStreamLimits) -> Void = { _ in }) async -> (events: [AIStreamEvent], error: AIError?) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [FaultStreamProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        var limits = AIStreamLimits()
        limits.idleTimeout = 0.18; limits.totalTimeout = 0.5; limits.finishGrace = 0.08
        configure(&limits)
        let provider = OpenAICompatibleProvider(config: .init(name: "fault", baseURL: "http://localhost/\(path)", models: ["test"], selectedModel: "test"), apiKey: "", session: session, limits: limits)
        var events: [AIStreamEvent] = []
        do {
            for try await event in provider.stream(messages: [.user("test")]) { events.append(event) }
            return (events, nil)
        } catch { return (events, error as? AIError) }
    }
    @Test func missingHeadersAndHeartbeatCannotWaitIndefinitely() async {
        for mode in ["noHeaders", "heartbeat"] {
            let result = await run(mode)
            #expect(result.error == .streamTimeout("模型长时间没有返回有效内容"))
        }
    }
    @Test func terminalFrameClosesWithoutDONEButRetainsTrailingUsage() async {
        let result = await run("finishTail")
        #expect(result.error == nil)
        #expect(result.events.contains(.delta("完成")))
        #expect(result.events.contains(.usage(.init(input: 12, output: 2))))
        let crlf = await run("doneCRLF")
        #expect(crlf.error == nil)
        #expect(crlf.events.contains(.delta("完成")))
    }
    @Test func endlessReasoningHasAnAbsoluteDeadline() async {
        let result = await run("reasonForever")
        #expect(result.error == .streamTimeout("请求已达到总时限"))
    }
    @Test func excessiveOutputIsRejectedBeforePublishing() async {
        let result = await run("oversized") { $0.maxOutputBytes = 100 }
        #expect(result.error == .responseTooLarge)
        #expect(result.events.isEmpty)
        let line = await run("oversizedLine")
        #expect(line.error == .responseTooLarge)
    }
    @Test func partialAndToolResponsesCannotBecomeSuccessfulHistory() async {
        #expect(await run("tool").error == .unsupportedOutput)
        #expect(await run("truncated").error == .outputTruncated)
        #expect(await run("disconnect").error == .incompleteResponse)
    }

    @Test func cancellationUnblocksAWaitingConsumer() async throws {
        let task = Task { await run("noHeaders") { $0.idleTimeout = 10; $0.totalTimeout = 10 } }
        try await Task.sleep(for: .milliseconds(30))
        task.cancel()
        let result = await task.value
        #expect(result.events.isEmpty)
    }
}
