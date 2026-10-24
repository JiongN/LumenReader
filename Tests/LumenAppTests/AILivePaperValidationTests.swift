import Foundation
import Testing
import LumenKit
@testable import LumenApp

@Suite("真实论文 AI 验证", .serialized)
@MainActor
struct AILivePaperValidationTests {
    @Test func rawEvidenceProtocol() async throws {
        guard ProcessInfo.processInfo.environment["LUMEN_LIVE_EVIDENCE_DEBUG"] == "1",
              let path = ProcessInfo.processInfo.environment["LUMEN_TEST_PDF"],
              let output = ProcessInfo.processInfo.environment["LUMEN_TEST_OUTPUT"] else { return }
        let real = AppPaths.realSupportRoot
        let settings = try JSONDecoder().decode(AppSettings.self, from: Data(contentsOf: real.appendingPathComponent("settings.json")))
        let config = try #require(settings.ai.providers.first { $0.id == settings.ai.activeProviderID })
        let key = try #require(CredentialFileStore(directory: real.appendingPathComponent("credentials")).read(account: config.keychainAccount))
        let snapshot = try await PDFDocumentContextCache.shared.snapshot(path: path)
        let messages = PromptLibrary.messages(task: .ask(question: "作者是否主张完全停止在科研中使用 AI？请回到原文说明，并引用其表述。"),
            selection: nil, metadata: .init(), locatorLabel: "全文", context: snapshot.context.text, memory: "",
            evidenceInstruction: AnswerEvidence.instruction)
        let raw = try await OpenAICompatibleProvider(config: config, apiKey: key).completeText(messages: messages)
        try raw.write(to: URL(fileURLWithPath: output).appendingPathComponent("live-evidence-raw.txt"), atomically: true, encoding: .utf8)
        let resolved = AnswerEvidence.resolve(raw, documents: [snapshot.context], supplied: snapshot.context.evidence)
        #expect(!resolved.citations.isEmpty)
    }

    @Test func configuredVisionProviderInterpretsRealFigurePage() async throws {
        guard ProcessInfo.processInfo.environment["LUMEN_LIVE_VISION"] == "1",
              let path = ProcessInfo.processInfo.environment["LUMEN_TEST_PDF"],
              let output = ProcessInfo.processInfo.environment["LUMEN_TEST_OUTPUT"] else { return }
        let real = AppPaths.realSupportRoot
        let data = try Data(contentsOf: real.appendingPathComponent("settings.json"))
        let root = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let aiData = try JSONSerialization.data(withJSONObject: try #require(root["ai"]))
        let settings = try JSONDecoder().decode(AISettings.self, from: aiData)
        var config = try #require(settings.visionProvider)
        if let model = ProcessInfo.processInfo.environment["LUMEN_LIVE_VISION_MODEL"] {
            #expect(config.models.contains(model))
            config.selectedModel = model
        }
        let key = try #require(CredentialFileStore(directory: real.appendingPathComponent("credentials"))
            .read(account: config.keychainAccount))
        // Figure 1 and Table 1 are on physical PDF page 5 in the user-selected test paper.
        let image = try await PDFPageAssets.shared.image(path: path, pageIndex: 4)
        let snapshot = try await PDFDocumentContextCache.shared.snapshot(path: path)
        let pageText = snapshot.context.evidence.filter { $0.locator.pageIndex == 4 }
            .map(\.text).joined(separator: "\n\n")
        var vision = config; vision.maxTokens = min(700, config.maxTokens)
        let messages: [AIMessage] = [
            .system("只依据提供的页图和同页提取文字回答。先逐列逐行核对表格，不从常识补充文中不存在的比较维度；图文冲突或单元格不可读时明确说明。"),
            .init(role: .user, content: "概述 Table 1 的四类 AI 愿景、研究阶段、作者称其克服的限制及愿景描述。只能列出表格实际存在的列。\n\n同页提取文字：\n\(pageText)", images: [image])
        ]
        let providerClient = OpenAICompatibleProvider(config: vision, apiKey: key)
        var answer = "", usage: AIUsage?
        for try await event in providerClient.stream(messages: messages) {
            switch event {
            case .delta(let text): answer += text
            case .usage(let value): usage = value
            default: break
            }
        }
        guard !answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw AIError.emptyResponse }
        for expected in ["Oracle", "Surrogate", "Quant", "Arbiter"] { #expect(answer.localizedCaseInsensitiveContains(expected)) }
        #expect(answer.localizedCaseInsensitiveContains("Research stage") || answer.contains("研究阶段"))
        #expect(!answer.localizedCaseInsensitiveContains("Surveillance"))
        #expect(!answer.localizedCaseInsensitiveContains("Arbitrariness"))
        let report = "# 真实视觉模型验收\n\n服务商：\(config.name)；模型：\(config.selectedModel)\n\n页图：\(image.label)\n\n\(answer)\n\nusage：\(String(describing: usage))\n"
        try report.write(to: URL(fileURLWithPath: output).appendingPathComponent("live-vision-validation.md"), atomically: true, encoding: .utf8)
    }

    @Test func configuredProviderDialogueAndTranslation() async throws {
        guard ProcessInfo.processInfo.environment["LUMEN_LIVE_AI"] == "1",
              let path = ProcessInfo.processInfo.environment["LUMEN_TEST_PDF"],
              let output = ProcessInfo.processInfo.environment["LUMEN_TEST_OUTPUT"] else { return }
        let real = AppPaths.realSupportRoot
        let json = try JSONSerialization.jsonObject(with: Data(contentsOf: real.appendingPathComponent("settings.json"))) as! [String: Any]
        let aiData = try JSONSerialization.data(withJSONObject: json["ai"]!)
        let settings = try JSONDecoder().decode(AISettings.self, from: aiData)
        let config = try #require(settings.providers.first { $0.id == settings.activeProviderID })
        let credentials = CredentialFileStore(directory: real.appendingPathComponent("credentials"))
        let key = try #require(credentials.read(account: config.keychainAccount))
        let chat = AIChatModel(store: ConversationStore(), providerFactory: {
            RecordingLiveProvider(provider: OpenAICompatibleProvider(config: $0, apiKey: key),
                directory: URL(fileURLWithPath: output))
        })
        chat.newConversation(sourcePath: path, sourceTitle: "Messeri & Crockett 2024")
        let snapshot = try await PDFDocumentContextCache.shared.snapshot(path: path)
        let questions = [
            "请概括这篇论文的核心论点，完整列出四类 AI 愿景和三类理解错觉，并给出对应页码。",
            "Which of these risks cannot be solved purely by making AI more accurate? Explain the connection with scientific monocultures and cite pages.",
            "作者是否主张完全停止在科研中使用 AI？请回到原文说明，并引用其表述。"
        ]
        var report = "# Messeri & Crockett 2024 实测\n\n服务商：\(config.name)；模型：\(config.selectedModel)；上下文容量：\(config.contextWindow)\n"
        for question in questions {
            let start = Date()
            chat.submit(task: .ask(question: question), selection: nil, metadata: .init(), locatorLabel: "全文", context: "",
                locator: .pdf(page: 0, charOffset: 0), config: config, memory: "", translateTarget: "简体中文",
                agent: .init(name: "原文核验", skills: [AgentSkill.evidenceID]), skills: AgentSkill.catalog,
                sourcePath: path, contextLoader: { [snapshot.context] })
            let deadline = Date().addingTimeInterval(600)
            while chat.isStreaming, Date() < deadline { try await Task.sleep(for: .milliseconds(200)) }
            if chat.isStreaming { chat.stop() }
            let bubble = try #require(chat.bubbles.last)
            report += "\n## \(question)\n\n\(bubble.text)\n\n覆盖：\(bubble.coverage)；耗时：\(Int(Date().timeIntervalSince(start))) s；请求：\(bubble.requestCount)；返回统计：\(bubble.usageReports)\n"
            let references = bubble.answerEvidence ?? []
            for ref in references {
                report += "\n已核验依据 [\(ref.number ?? 0)]：\(ref.label)；\(ref.quote ?? "")\n"
            }
            #expect(!bubble.failed)
            if !bubble.failed { #expect(!references.isEmpty) }
            try report.write(to: URL(fileURLWithPath: output).appendingPathComponent("live-paper-validation.md"), atomically: true, encoding: .utf8)
            if bubble.failed { return }
        }
        let abstract = try #require(snapshot.paragraphs.first { $0.text.hasPrefix("Scientists are enthusiastically imagining") })
        let provider = OpenAICompatibleProvider(config: config, apiKey: key)
        let start = Date()
        let translation = try await provider.completeText(messages: [.system("将学术摘要准确翻译为简体中文，保留完整论证关系。只输出译文。"), .user(abstract.text)])
        #expect(translation.contains("理解"))
        report += "\n## 摘要翻译\n\n原文：\(abstract.text)\n\n译文：\(translation)\n\n耗时：\(Int(Date().timeIntervalSince(start))) s\n"
        try report.write(to: URL(fileURLWithPath: output).appendingPathComponent("live-paper-validation.md"), atomically: true, encoding: .utf8)
    }
}

private final class RecordingLiveProvider: AIProvider, @unchecked Sendable {
    private let provider: OpenAICompatibleProvider
    private let directory: URL
    var displayName: String { provider.displayName }
    var modelName: String { provider.modelName }
    init(provider: OpenAICompatibleProvider, directory: URL) {
        self.provider = provider; self.directory = directory
    }
    func availableModels() async throws -> [String] { try await provider.availableModels() }
    func stream(messages: [AIMessage]) -> AsyncThrowingStream<AIStreamEvent, Error> {
        let provider = provider, directory = directory
        return AsyncThrowingStream { continuation in
            let task = Task {
                var raw = ""
                do {
                    for try await event in provider.stream(messages: messages) {
                        if case .delta(let text) = event { raw += text }
                        continuation.yield(event)
                    }
                    let id = UUID().uuidString
                    try raw.write(to: directory.appendingPathComponent("live-response-\(id).txt"), atomically: true, encoding: .utf8)
                    continuation.finish()
                } catch { continuation.finish(throwing: error) }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
