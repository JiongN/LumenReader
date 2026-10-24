import Foundation
import Testing
import LumenKit
@testable import LumenApp

@MainActor
struct AIWebSearchLiveTests {
    @Test func chineseQuestionFindsRelatedEnglishLiterature() async throws {
        guard ProcessInfo.processInfo.environment["LUMEN_LIVE_WEB"] == "1",
              let path = ProcessInfo.processInfo.environment["LUMEN_TEST_PDF"],
              let output = ProcessInfo.processInfo.environment["LUMEN_TEST_OUTPUT"] else { return }
        let root = AppPaths.realSupportRoot
        let json = try JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent("settings.json"))) as! [String: Any]
        let settings = try JSONDecoder().decode(AISettings.self, from: JSONSerialization.data(withJSONObject: json["ai"]!))
        var config = try #require(settings.providers.first { $0.id == settings.activeProviderID })
        config.maxTokens = min(config.maxTokens, 600)
        let credentials = CredentialFileStore(directory: root.appendingPathComponent("credentials"))
        let key = try #require(credentials.read(account: config.keychainAccount))
        if let openAlexKey = credentials.read(account: "openalex-api") {
            #expect(AICredentialStore.save(openAlexKey, account: "openalex-api"))
        }
        defer { AICredentialStore.delete(account: "openalex-api") }
        let snapshot = try await PDFDocumentContextCache.shared.snapshot(path: path)
        let text = snapshot.paragraphs.prefix(8).map(\.text).joined(separator: "\n")
        let chat = AIChatModel(store: ConversationStore(), providerFactory: {
            var limits = AIStreamLimits()
            limits.idleTimeout = 12
            limits.totalTimeout = $0.maxTokens <= 350 ? 20 : 60
            return OpenAICompatibleProvider(config: $0, apiKey: key, limits: limits)
        })
        chat.newConversation(sourcePath: path, sourceTitle: "检索隔离验收")
        let start = Date()
        chat.submit(task: .ask(question: "请找与这篇论文讨论的 AI 理解错觉相关的文献，说明它们与原文的关系。"), selection: nil,
            metadata: .init(title: "Artificial intelligence and illusions of understanding in scientific research"),
            locatorLabel: "首页材料", context: String(text.prefix(3500)), locator: .pdf(page: 0, charOffset: 0),
            config: config, memory: "", translateTarget: "简体中文", webSearchEnabled: true, sourcePath: path)
        for _ in 0..<600 {
            if !chat.isStreaming { break }
            try await Task.sleep(for: .milliseconds(200))
        }
        if chat.isStreaming { chat.stop() }
        let bubble = try #require(chat.bubbles.last)
        let report = "模型：\(config.selectedModel)\n耗时：\(Int(Date().timeIntervalSince(start)))s\n\(bubble.searchCoverage)\n请求：\(bubble.requestCount)\n输入：\(bubble.usage?.input.map(String.init) ?? "未知")\n输出：\(bubble.usage?.output.map(String.init) ?? "未知")\n失败：\(bubble.failed)\n\n\(bubble.text)\n"
        try report.write(to: URL(fileURLWithPath: output).appendingPathComponent("live-search.txt"), atomically: true, encoding: .utf8)
        #expect(!bubble.failed)
        #expect(!bubble.searchCoverage.contains("· 0 篇"))
        #expect(!bubble.searchCoverage.contains("关键词生成失败"))
    }
}
