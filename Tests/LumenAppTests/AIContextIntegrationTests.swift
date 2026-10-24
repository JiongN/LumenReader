import Foundation
import Testing
import Synchronization
import LumenKit
@testable import LumenApp

private final class ContextMockProtocol: URLProtocol, @unchecked Sendable {
    static let requests = Mutex<[Data]>([])
    static let overlongDigests = Mutex<Int>(0)
    static let citationReply = Mutex<String?>(nil)
    static let truncateReasoning = Mutex(false)
    static func captured() -> [[String: Any]] {
        requests.withLock { $0 }.compactMap { (try? JSONSerialization.jsonObject(with: $0)) as? [String: Any] }
    }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        var data = request.httpBody ?? Data()
        if data.isEmpty, let stream = request.httpBodyStream {
            stream.open(); defer { stream.close() }
            var buffer = [UInt8](repeating: 0, count: 8192)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count <= 0 { break }
                data.append(contentsOf: buffer.prefix(count))
            }
        }
        let payload = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        Self.requests.withLock { $0.append(data) }
        let messages = payload["messages"] as? [[String: String]] ?? []
        let system = messages.first?["content"] ?? ""
        var reply = system.contains("关键词") ? "AI Oracles Surrogates Quants Arbiters" : "【第 1 页】AI visions include Oracles, Surrogates, Quants and Arbiters."
        if system.contains("公开学术数据库的检索词") { reply = "{\"query\":\"artificial intelligence illusions understanding\"}" }
        if let start = system.firstIndex(of: "{"), let end = system.firstIndex(of: "}"), start < end,
           let data = String(system[start...end]).data(using: .utf8),
           let envelope = (try? JSONSerialization.jsonObject(with: data)) as? [String: String], let id = envelope["partID"] {
            reply = String(data: try! JSONSerialization.data(withJSONObject: ["partID": id, "summary": "Whole section evidence, source page retained."]), encoding: .utf8)!
            let overrun = Self.overlongDigests.withLock { count in
                if count <= 0 { return false }
                count -= 1; return true
            }
            if overrun {
                reply = String(data: try! JSONSerialization.data(withJSONObject: ["partID": id, "summary": String(repeating: "Too long evidence. ", count: 1000)]), encoding: .utf8)!
            }
        }
        let material = messages.dropFirst().first?["content"] ?? ""
        if let sourceReply = Self.citationReply.withLock({ $0 }), system.contains("lumen-evidence") { reply = sourceReply }
        if let marker = material.range(of: "<!-- lumen-coverage:"), let end = material[marker.upperBound...].range(of: "-->") {
            reply += "\n" + material[marker.lowerBound..<end.upperBound]
        }
        let truncated = Self.truncateReasoning.withLock { $0 }
        let json: [String: Any] = truncated
            ? ["choices": [["delta": ["reasoning_content": "正在思考"], "finish_reason": "length"]],
               "usage": ["prompt_tokens": 123, "completion_tokens": 2048]]
            : ["choices": [["delta": ["content": reply], "finish_reason": "stop"]]]
        let chunk = try! JSONSerialization.data(withJSONObject: json)
        var body = Data("data: ".utf8); body.append(chunk)
        body.append(Data("\n\ndata: {\"choices\":[],\"usage\":{\"prompt_tokens\":123,\"completion_tokens\":42,\"prompt_tokens_details\":{\"cached_tokens\":100}}}\n\ndata: [DONE]\n\n".utf8))
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "text/event-stream"])!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@Suite("AI 全文与取消隔离", .serialized)
@MainActor
struct AIContextIntegrationTests {
    private func model(search: ((String) async -> WebLiteratureSearch.Outcome)? = nil) -> AIChatModel {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ContextMockProtocol.self]
        let session = URLSession(configuration: configuration)
        let chat = AIChatModel(store: ConversationStore(), providerFactory: {
            OpenAICompatibleProvider(config: $0, apiKey: "local-test-only", session: session)
        }, literatureSearch: search)
        chat.newConversation(sourcePath: nil, sourceTitle: nil)
        return chat
    }
    private var config: AIProviderConfig {
        .init(name: "Mock", baseURL: "http://localhost:8777/v1", models: ["one", "two"], selectedModel: "one", maxTokens: 256, contextWindow: 128_000)
    }
    private func wait(_ chat: AIChatModel) async throws {
        for _ in 0..<500 {
            if !chat.isStreaming { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        throw AIError.cancelled
    }
    private func submit(_ chat: AIChatModel, text: String = "原文", loader: (@MainActor () async throws -> [DocumentContext])? = nil, config: AIProviderConfig? = nil, question: String = "核心观点？", evidence: Bool = false) {
        chat.submit(task: .ask(question: question), selection: nil, metadata: .init(), locatorLabel: "全文",
            context: text, locator: .pdf(page: 0, charOffset: 0), config: config ?? self.config,
            memory: "", translateTarget: "简体中文",
            agent: evidence ? .init(name: "核验", skills: [AgentSkill.evidenceID]) : nil,
            skills: AgentSkill.catalog, contextLoader: loader)
    }

    @Test func chatAndVisionRequestsUseIndependentModelsIncludingRerun() async throws {
        let chat = model()
        let settings = SettingsStore(fileURL: FileManager.default.temporaryDirectory.appendingPathComponent("roles-\(UUID()).json"))
        settings.suppressSave = true
        let initial = config
        settings.upsertProvider(initial)
        settings.selectProvider(id: initial.id, for: .vision)
        settings.selectModel("vision-model", for: .vision)
        ContextMockProtocol.requests.withLock { $0 = [] }
        submit(chat)
        try await wait(chat)
        #expect(ContextMockProtocol.captured().last?["model"] as? String == "one")
        settings.selectModel("two", for: .chat)
        chat.submit(task: .ask(question: "解读图表"), selection: nil, metadata: .init(), locatorLabel: "当前页",
            context: "图 1 数据", locator: .pdf(page: 0, charOffset: 0), config: settings.activeProvider,
            memory: "", translateTarget: "简体中文", visionConfig: settings.visionProvider,
            images: [.init(data: Data([1, 2, 3]), label: "图 1")])
        try await wait(chat)
        #expect(chat.bubbles.last?.failed == false)
        let request = try #require(ContextMockProtocol.captured().last)
        #expect(request["model"] as? String == "vision-model")
        let messages = try #require(request["messages"] as? [[String: Any]])
        let content = try #require(messages.last?["content"] as? [[String: Any]])
        #expect(content.contains { $0["type"] as? String == "image_url" })
        settings.selectModel("updated-vision", for: .vision)
        chat.rerunLast(settings: settings, memory: "")
        try await wait(chat)
        #expect(chat.bubbles.last?.failed == false)
        #expect(ContextMockProtocol.captured().last?["model"] as? String == "updated-vision")
        #expect(settings.activeProvider?.selectedModel == "two")
    }

    @Test func visionCanRunWithoutChatAndMissingVisionDoesNotSendImagesToChat() async throws {
        let chat = model()
        ContextMockProtocol.requests.withLock { $0 = [] }
        let image = AIImage(data: Data([1, 2, 3]), label: "图")
        chat.submit(task: .ask(question: "图表"), selection: nil, metadata: .init(), locatorLabel: "当前页",
            context: "图注", locator: .pdf(page: 0, charOffset: 0), config: config,
            memory: "", translateTarget: "简体中文", images: [image])
        #expect(ContextMockProtocol.captured().isEmpty)
        chat.submit(task: .ask(question: "图表"), selection: nil, metadata: .init(), locatorLabel: "当前页",
            context: "图注", locator: .pdf(page: 0, charOffset: 0), config: nil,
            memory: "", translateTarget: "简体中文", visionConfig: config, images: [image])
        try await wait(chat)
        #expect(chat.bubbles.last?.failed == false)
        #expect(ContextMockProtocol.captured().last?["model"] as? String == "one")
    }

    @Test func actualAnswerEvidenceIsVerifiedAndPersistsWithoutProtocolFooter() async throws {
        let chat = model()
        let source = DocumentEvidence(id: "p2", path: "/test/evidence.pdf", label: "第 2 页",
            locator: .pdf(page: 1, charOffset: 0), text: "The original gives verifiable evidence for this claim.")
        let document = DocumentContext(version: "v1", path: source.path, evidence: [source], unitCount: 2)
        ContextMockProtocol.citationReply.withLock {
            $0 = "这一判断有依据 [原文1]\n<!-- lumen-evidence: {\"citations\":[{\"number\":1,\"id\":\"\(source.citationID)\",\"quote\":\"verifiable evidence for this claim.\"}]} -->"
        }
        defer { ContextMockProtocol.citationReply.withLock { $0 = nil } }
        submit(chat, loader: { [document] }, question: "这一判断有何依据？", evidence: true)
        try await wait(chat)
        let answer = try #require(chat.bubbles.last)
        #expect(!answer.failed)
        #expect(answer.answerEvidence?.count == 1)
        #expect(answer.answerEvidence?.first?.locator == source.locator)
        #expect(!answer.text.contains("lumen-evidence"))
        chat.rerunLast(config: config, memory: "", template: nil, agent: nil, skills: [], webSearchEnabled: false, translateTarget: "简体中文")
        try await wait(chat)
        let messages = ContextMockProtocol.captured().last?["messages"] as? [[String: String]] ?? []
        #expect(messages.first?["content"]?.contains("Ground document-related claims") == false)
        #expect(chat.bubbles.last?.answerEvidence == nil)
        chat.showActiveConversation()
        #expect(chat.bubbles.last?.answerEvidence == nil)
    }

    @Test func defaultAnswersDoNotRequestEvidenceEvenWhenQuestionAsksForSources() async throws {
        ContextMockProtocol.requests.withLock { $0 = [] }
        let chat = model()
        submit(chat, question: "请提供原文依据")
        try await wait(chat)
        let messages = ContextMockProtocol.captured().last?["messages"] as? [[String: String]] ?? []
        #expect(messages.first?["content"]?.contains("lumen-evidence") == false)
        #expect(chat.bubbles.last?.answerEvidence == nil)
    }

    @Test func deepSeekThinkingSwitchIsSentAndFailedReasoningRetainsUsage() async throws {
        ContextMockProtocol.requests.withLock { $0 = [] }
        var provider = AIProviderConfig(name: "DeepSeek", baseURL: "https://api.deepseek.com/v1",
            models: ["deepseek-flash"], selectedModel: "deepseek-flash", maxTokens: 2048, contextWindow: 128_000)
        let chat = model()
        submit(chat, config: provider)
        try await wait(chat)
        #expect((ContextMockProtocol.captured().last?["thinking"] as? [String: String])?["type"] == "disabled")
        provider.extendedThinking = true
        ContextMockProtocol.truncateReasoning.withLock { $0 = true }
        defer { ContextMockProtocol.truncateReasoning.withLock { $0 = false } }
        submit(chat, config: provider)
        try await wait(chat)
        #expect((ContextMockProtocol.captured().last?["thinking"] as? [String: String])?["type"] == "enabled")
        let answer = try #require(chat.bubbles.last)
        #expect(answer.failed)
        #expect(answer.text.contains("2048"))
        #expect(answer.text.contains("finish_reason=length"))
        #expect(!answer.text.contains("导图节点"))
        #expect(answer.usage?.output == 2048)
        provider.baseURL = "https://gateway.example/v1"
        #expect(provider.deepSeekThinking == nil)
        provider.baseURL = "https://api.deepseek.com/v1"
        provider.selectedModel = "deepseek-reasoner"
        #expect(provider.deepSeekThinking == nil)
    }

    @Test func conceptQuestionKeepsWholeEvidenceWithoutRequiringEveryChapterInAnswer() async throws {
        ContextMockProtocol.requests.withLock { $0 = [] }
        let chat = model()
        let document = DocumentContext(version: "v1", path: "book.pdf", evidence: (1...3).map {
            .init(id: "P\($0)", path: "book.pdf", label: "第 \($0) 页",
                locator: .pdf(page: $0 - 1, charOffset: 0), text: "SOURCE_\($0) Peirce evidence.")
        }, unitCount: 3)
        submit(chat, loader: { [document] }, question: "基于全文核对规约符与对象的关系")
        try await wait(chat)
        let answer = try #require(chat.bubbles.last)
        #expect(!answer.failed)
        #expect(chat.historyMessageCount == 2)
        let contents = ContextMockProtocol.captured().flatMap { $0["messages"] as? [[String: String]] ?? [] }.compactMap { $0["content"] }.joined()
        for page in 1...3 { #expect(contents.contains("SOURCE_\(page)")) }
        #expect(!contents.contains("<!-- lumen-coverage:"))
        #expect(!answer.text.contains("HTTP 422"))
    }

    @Test func fullTextRerunUsesNewConfigWithoutExtractingAgainAndUsageSurvivesReload() async throws {
        ContextMockProtocol.requests.withLock { $0 = [] }
        let chat = model()
        var loads = 0
        let text = "START " + String(repeating: "evidence ", count: 3000) + " MIDDLE END"
        submit(chat, loader: {
            loads += 1
            return [.init(version: "v1", path: "/test/a.pdf", evidence: [.init(id: "p1", path: "/test/a.pdf", label: "第 1 页", locator: .pdf(page: 0, charOffset: 0), text: text)], unitCount: 1)]
        })
        try await wait(chat)
        #expect(chat.bubbles.last?.failed == false)
        #expect(chat.bubbles.last?.usage?.cached == 100)
        var next = config; next.selectedModel = "two"
        chat.rerunLast(config: next, memory: "新要求", template: nil, agent: nil, skills: [], webSearchEnabled: false, translateTarget: "简体中文")
        try await wait(chat)
        #expect(loads == 1)
        #expect(chat.bubbles.count == 2)
        #expect(chat.historyMessageCount == 2)
        let captured = ContextMockProtocol.captured()
        #expect(captured.count == 2)
        #expect(captured.last?["model"] as? String == "two")
        let messages = captured.last?["messages"] as? [[String: String]] ?? []
        #expect(messages.filter { $0["content"]?.contains(text) == true }.count == 1)
        chat.showActiveConversation()
        #expect(chat.bubbles.last?.evidence.first?.version == "v1")
        #expect(chat.bubbles.last?.usage?.input == 123)
    }

    @Test func newSelectionIsTheFinalRequestTargetAfterPreviousAnswer() async throws {
        ContextMockProtocol.requests.withLock { $0 = [] }
        let chat = model()
        let previous = ReaderSelection(text: "OLD_TARGET explanation", locator: .pdf(page: 0, charOffset: 0))
        let current = ReaderSelection(text: "NEW_TARGET another sentence", locator: .pdf(page: 3, charOffset: 42))
        for selection in [previous, current] {
            let request = AIRequest(kind: .explain, selection: selection)
            chat.submit(task: .explain, selection: request.selection, metadata: .init(), locatorLabel: "第 4 页",
                context: "", locator: try #require(request.locator), config: config, memory: "", translateTarget: "简体中文")
            try await wait(chat)
        }
        let messages = try #require(ContextMockProtocol.captured().last?["messages"] as? [[String: String]])
        #expect(messages.last?["content"]?.contains(current.text) == true)
        #expect(messages.last?["content"]?.contains(previous.text) == false)
        #expect(messages.filter { $0["content"]?.contains(current.text) == true }.count == 1)
        #expect(messages.contains { $0["content"]?.contains(previous.text) == true })
        #expect(chat.bubbles.suffix(2).first?.text.contains(current.text) == true)
        #expect(chat.bubbles.last?.citations == [current.locator])
    }

    @Test func webSearchUsesDocumentTopicAndPersistsQueryAndSourceFailures() async throws {
        ContextMockProtocol.requests.withLock { $0 = [] }
        var received = ""
        let chat = model(search: { query in
            received = query
            return .init(hits: [], failures: ["OpenAlex：服务返回 HTTP 401"], query: query)
        })
        let marker = UUID().uuidString
        chat.submit(task: .ask(question: "请找相关文献"), selection: nil,
            metadata: .init(title: "Artificial intelligence and illusions of understanding " + marker),
            locatorLabel: "当前页", context: "AI visions and scientific understanding.", locator: .pdf(page: 0, charOffset: 0),
            config: config, memory: "", translateTarget: "简体中文", webSearchEnabled: true)
        try await wait(chat)
        #expect(received == "artificial intelligence illusions understanding")
        #expect(chat.bubbles.last?.failed == false)
        #expect(chat.bubbles.last?.searchCoverage.contains("401") == true)
        #expect(chat.bubbles.last?.searchCoverage.contains(received) == true)
        let requests = ContextMockProtocol.captured()
        let planner = requests.first?["messages"] as? [[String: String]] ?? []
        #expect(planner.contains { $0["content"]?.contains("AI visions and scientific understanding") == true })
        let final = requests.last?["messages"] as? [[String: String]] ?? []
        #expect(final.contains { $0["content"]?.contains("没有取得通过相关性筛选") == true })
        chat.showActiveConversation()
        #expect(chat.bubbles.last?.searchCoverage.contains("401") == true)
    }

    @Test func cancelledPreparationCannotWriteToNewConversation() async throws {
        let chat = model()
        submit(chat, loader: {
            try? await Task.sleep(for: .milliseconds(200))
            return [.init(version: "stale", path: "/old.pdf", evidence: [.init(id: "old", path: "/old.pdf", label: "旧", locator: .pdf(page: 0, charOffset: 0), text: "OLD")], unitCount: 1)]
        })
        try await Task.sleep(for: .milliseconds(20))
        chat.newConversation(sourcePath: nil, sourceTitle: nil)
        submit(chat, text: "NEW")
        try await wait(chat)
        try await Task.sleep(for: .milliseconds(250))
        #expect(chat.bubbles.count == 2)
        #expect(chat.bubbles.last?.failed == false)
        #expect(chat.bubbles.last?.evidence.isEmpty == true)
        #expect(chat.historyMessageCount == 2)
    }

    @Test func stoppedAnswerIsNotReintroducedIntoHistory() async throws {
        let chat = model()
        chat.beginFakeStream()
        chat.appendFakeDelta("未完成")
        chat.stop()
        #expect(chat.bubbles.last?.failed == true)
        #expect(chat.historyMessageCount == 0)
        chat.showActiveConversation()
        #expect(chat.historyMessageCount == 0)
    }

    @Test func doubleDocumentEvidenceKeepsDistinctIdentityAndStableMaterials() async throws {
        ContextMockProtocol.requests.withLock { $0 = [] }
        let chat = model()
        let documents = ["/test/a.pdf", "/test/b.pdf"].enumerated().map { index, path in
            DocumentContext(version: "v\(index)", path: path,
                evidence: [.init(id: "p1", path: path, label: "第 1 页", locator: .pdf(page: 0, charOffset: 0), text: "Unique document \(index) source")], unitCount: 1)
        }
        submit(chat, loader: { documents })
        try await wait(chat)
        #expect(chat.bubbles.last?.evidence.map(\.path) == documents.map(\.path))
        #expect(chat.bubbles.last?.evidence.map(\.version) == documents.map(\.version))
        submit(chat, loader: { documents })
        try await wait(chat)
        let messages = ContextMockProtocol.captured().last?["messages"] as? [[String: String]] ?? []
        for index in 0..<2 {
            #expect(messages.filter { $0["content"]?.contains("Unique document \(index) source") == true }.count == 1)
        }
    }

    @Test func failedRerunDoesNotErasePreviousSuccessfulHistory() async throws {
        let chat = model()
        submit(chat)
        try await wait(chat)
        #expect(chat.historyMessageCount == 2)
        submit(chat, loader: { throw AIError.invalidResponse })
        try await wait(chat)
        #expect(chat.bubbles.last?.failed == true)
        chat.rerunLast(config: config, memory: "", template: nil, agent: nil, skills: [], webSearchEnabled: false, translateTarget: "简体中文")
        try await wait(chat)
        #expect(chat.historyMessageCount == 2)
    }

    @Test func oversizedDocumentUsesCachedSummariesAndBilingualQuery() async throws {
        ContextMockProtocol.requests.withLock { $0 = [] }
        let chat = model()
        var short = config; short.contextWindow = 4096
        let marker = UUID().uuidString
        let text = marker + " " + String(repeating: "AI Oracles and Surrogates. ", count: 800)
        let document = DocumentContext(version: marker, path: "/test/long.pdf",
            evidence: [.init(id: "p1", path: "/test/long.pdf", label: "第 1 页", locator: .pdf(page: 0, charOffset: 0), text: text)], unitCount: 1)
        submit(chat, loader: { [document] }, config: short)
        try await wait(chat)
        #expect(chat.bubbles.last?.failed == false, "\(chat.bubbles.last?.text ?? "")")
        let firstCount = ContextMockProtocol.requests.withLock { $0.count }
        #expect(firstCount > 2)
        submit(chat, loader: { [document] }, config: short, question: "Compare Oracles and Surrogates in this paper.")
        try await wait(chat)
        #expect(chat.bubbles.last?.failed == false)
        #expect(ContextMockProtocol.requests.withLock { $0.count } == firstCount + 1)
        #expect(chat.bubbles.last?.coverage.contains("全书摘要＋相关原文") == true)
        let requests = ContextMockProtocol.captured()
        for request in requests {
            let messages = request["messages"] as? [[String: String]] ?? []
            #expect(ContextBudget.estimatedTokens(messages.compactMap { $0["content"] }.joined()) <= ContextBudget.inputLimit(short))
        }
    }

    @Test func allWholeDocumentQuestionsKeepEverySectionAcrossFollowupsAndModelChanges() async throws {
        ContextMockProtocol.requests.withLock { $0 = [] }
        let chat = model()
        var short = config; short.contextWindow = 8192
        let version = UUID().uuidString
        let document = DocumentContext(version: version, path: "/book.pdf", evidence: (0..<6).map {
            .init(id: "page-\($0)", path: "/book.pdf", label: "第 \($0 + 1) 页", locator: .pdf(page: $0, charOffset: 0),
                  text: "TOPIC\($0) " + String(repeating: "chapter evidence ", count: 500))
        }, unitCount: 6, sections: (0..<6).map { .init(title: "CHAPTER\($0)", startUnit: $0, endUnit: $0) })
        for question in ["总结全书", "全书有哪些相互冲突的观点？", "Draw a whole-book mind map", "What is discussed in chapter 2?"] {
            submit(chat, loader: { [document] }, config: short, question: question)
            try await wait(chat)
            #expect(chat.bubbles.last?.failed == false)
            let messages = ContextMockProtocol.captured().last?["messages"] as? [[String: String]] ?? []
            let material = messages[1]["content"] ?? ""
            for index in 1...6 {
                #expect(material.contains("D1S\(index)F1"))
                #expect(material.contains("CHAPTER\(index - 1)"))
            }
            #expect(chat.bubbles.last?.coverage.contains("6/6") == true)
        }
        let before = ContextMockProtocol.captured().count
        var other = short; other.selectedModel = "two"
        chat.rerunLast(config: other, memory: "", template: nil, agent: nil, skills: [], webSearchEnabled: false, translateTarget: "简体中文")
        try await wait(chat)
        #expect(chat.bubbles.last?.failed == false)
        #expect(ContextMockProtocol.captured().count > before + 1) // Model-specific digest cache.
    }

    @Test func preparationDeadlineReleasesComposerAndCannotOverwriteNextRequest() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ContextMockProtocol.self]
        let session = URLSession(configuration: configuration)
        let chat = AIChatModel(store: ConversationStore(), answerTimeout: 0.08, providerFactory: {
            OpenAICompatibleProvider(config: $0, apiKey: "", session: session)
        })
        chat.newConversation(sourcePath: nil, sourceTitle: nil)
        submit(chat, loader: {
            try? await Task.sleep(for: .milliseconds(250))
            return []
        })
        try await wait(chat)
        #expect(chat.bubbles.last?.failed == true)
        #expect(chat.bubbles.last?.text.contains("总时限") == true)
        #expect(chat.historyMessageCount == 0)
        submit(chat, text: "NEW")
        try await wait(chat)
        try await Task.sleep(for: .milliseconds(300))
        #expect(chat.bubbles.count == 4)
        #expect(chat.bubbles.last?.failed == false)
        #expect(chat.historyMessageCount == 2)
    }

    @Test func overlongDigestIsRepairedWithoutDroppingSections() async throws {
        ContextMockProtocol.requests.withLock { $0 = [] }
        ContextMockProtocol.overlongDigests.withLock { $0 = 2 }
        defer { ContextMockProtocol.overlongDigests.withLock { $0 = 0 } }
        let chat = model()
        var small = config; small.contextWindow = 8192
        let document = DocumentContext(version: UUID().uuidString, path: "/repair.pdf", evidence: (0..<6).map {
            .init(id: "p\($0)", path: "/repair.pdf", label: "page \($0 + 1)", locator: .pdf(page: $0, charOffset: 0), text: String(repeating: "evidence ", count: 2000))
        }, unitCount: 6, sections: (0..<6).map { .init(title: "Section \($0)", startUnit: $0, endUnit: $0) })
        submit(chat, loader: { [document] }, config: small, question: "whole book overview")
        try await wait(chat)
        #expect(chat.bubbles.last?.failed == false)
        #expect(chat.bubbles.last?.coverage.contains("6/6") == true)
        let captured = ContextMockProtocol.captured()
        #expect(captured.count == 15) // 12 source fragments, two bounded repairs, one final answer.
        let final = captured.last?["messages"] as? [[String: String]] ?? []
        for index in 1...6 { #expect(final.contains { $0["content"]?.contains("D1S\(index)") == true }) }
    }

    @Test func longConversationPreservesTranscriptAndLimitsOnlyRequestHistoryAfterReload() async throws {
        ContextMockProtocol.requests.withLock { $0 = [] }
        let chat = model()
        for index in 0..<15 {
            submit(chat, question: "question \(index)")
            try await wait(chat)
        }
        #expect(chat.bubbles.count == 30)
        #expect(chat.historyMessageCount == 30)
        #expect(chat.bubbles.last?.historyCoverage.contains("阶段记录") == true)
        #expect(chat.store.activeConversation?.digest?.messageCount == 4)
        chat.showActiveConversation()
        #expect(chat.historyMessageCount == 30)
        submit(chat, question: "after reload")
        try await wait(chat)
        let messages = ContextMockProtocol.captured().last?["messages"] as? [[String: String]] ?? []
        #expect(messages.count == 27) // system, material, 12 turns, current question
        #expect(chat.bubbles.count == 32)
        let oldQuestions = messages.filter { $0["content"]?.contains("question 0") == true }
        #expect(oldQuestions.isEmpty)
    }

    @Test func largeDiagramPreviewFixtureKeepsOriginalForCopyAndExport() throws {
        guard ProcessInfo.processInfo.environment["LUMEN_UI_STRESS"] == "1" else { return }
        let store = ConversationStore()
        let id = store.createConversation(sourcePath: nil, sourceTitle: nil)
        let source = "```svg\n<svg>" + String(repeating: "<path d=\"M0 0L10 10\"/>", count: 3000) + "</svg>\n```"
        store.replaceContent(id: id, bubbles: [.init(role: .user, text: "绘图代码压力检查（模拟）"), .init(role: .assistant, text: source)], history: [])
        store.setActive(id)
        let reread = ConversationStore()
        #expect(reread.activeConversation?.bubbles.last?.text == source)
        #expect(source.count > 16_000)
    }
}
