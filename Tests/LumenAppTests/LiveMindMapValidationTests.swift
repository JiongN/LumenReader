import Foundation
import Testing
import LumenKit
@testable import LumenApp

@Suite("真实模型导图与翻译", .serialized)
@MainActor
struct LiveMindMapValidationTests {
    @Test func configuredModelProducesMapAndRealTranslation() async throws {
        guard ProcessInfo.processInfo.environment["LUMEN_LIVE_LAYOUT_AI"] == "1",
              let path = ProcessInfo.processInfo.environment["LUMEN_TEST_PDF"],
              let output = ProcessInfo.processInfo.environment["LUMEN_CORPUS_OUTPUT"] else { return }
        let real = AppPaths.realSupportRoot
        let original = try JSONDecoder().decode(AppSettings.self, from: Data(contentsOf: real.appendingPathComponent("settings.json")))
        var config = try #require(original.ai.providers.first { $0.id == original.ai.activeProviderID })
        let credentials = CredentialFileStore(directory: real.appendingPathComponent("credentials"))
        let key = credentials.read(account: config.keychainAccount) ?? ""
        config.maxTokens = 4096
        let snapshot = try await PDFDocumentContextCache().snapshot(path: path)
        let page = DocumentContext(version: snapshot.context.version, path: path,
            evidence: snapshot.context.evidence.filter { $0.locator.pageIndex == 0 }, unitCount: 1)
        let chat = AIChatModel(store: ConversationStore(), providerFactory: {
            OpenAICompatibleProvider(config: $0, apiKey: key)
        })
        chat.newConversation(sourcePath: path, sourceTitle: "Messeri & Crockett 2024")
        let started = Date()
        chat.submit(task: .ask(question: "请把第 1 页的核心论点与风险关系整理为思维导图。"),
            selection: nil, metadata: .init(), locatorLabel: "第 1 页", context: "",
            locator: .pdf(page: 0, charOffset: 0), config: config, memory: "", translateTarget: "简体中文",
            agent: AgentConfig.mindMapMode, sourcePath: path, contextLoader: { [page] })
        let deadline = Date().addingTimeInterval(240)
        while chat.isStreaming, Date() < deadline { try await Task.sleep(for: .milliseconds(100)) }
        if chat.isStreaming { chat.stop() }
        let bubble = try #require(chat.bubbles.last)
        let file = URL(fileURLWithPath: output).appendingPathComponent("live-validation.md")
        var report = "# 真实模型验证\n\n模型：\(config.selectedModel)；材料：论文第 1 页；耗时：\(Int(Date().timeIntervalSince(started))) 秒。\n\n\(bubble.text)\n\n失败：\(bubble.failed)；输入：\(bubble.usage?.input.map(String.init) ?? "未知")；输出：\(bubble.usage?.output.map(String.init) ?? "未知")；缓存：\(bubble.usage?.cached.map(String.init) ?? "未知")。\n"
        try report.write(to: file, atomically: true, encoding: .utf8)
        #expect(!bubble.failed)
        let parsed = MindMapResult.parse(bubble.text)
        #expect(parsed != nil)
        if bubble.failed { return }
        let paragraph = try #require(snapshot.paragraphs.first { $0.text.hasPrefix("Scientists are enthusiastically imagining") })
        let engine = LLMTranslationEngine(config: config, apiKey: key, glossary: [])
        let translation = try await engine.translate(paragraph.text, to: "zh-Hans", from: "en")
        #expect(translation.contains("理解"))
        report += "\n## 真实摘要翻译\n\n\(translation)\n"
        try report.write(to: file, atomically: true, encoding: .utf8)
        // Only a non-secret, isolated configuration is written for native UI verification.
        var isolated = AppSettings()
        isolated.ai.providers = [config]
        isolated.ai.activeProviderID = config.id
        isolated.ai.activeAgentID = AgentConfig.mindMapMode.id
        isolated.reader.translationProviderID = config.id
        isolated.reader.translationModel = config.selectedModel
        try JSONEncoder().encode(isolated).write(to: AppPaths.settingsFile)
    }
}
