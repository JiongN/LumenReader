import Foundation
import Testing
import LumenKit
@testable import LumenApp

@Suite("真实长书全文验证", .serialized)
@MainActor
struct LiveWholeBookTests {
    @Test func realBookOverviewAndMapWithCachedExtraction() async throws {
        guard ProcessInfo.processInfo.environment["LUMEN_LIVE_WHOLE"] == "1",
              let output = ProcessInfo.processInfo.environment["LUMEN_TEST_OUTPUT"] else { return }
        let real = AppPaths.realSupportRoot
        let settings = try JSONDecoder().decode(AppSettings.self, from: Data(contentsOf: real.appendingPathComponent("settings.json")))
        let config = try #require(settings.ai.providers.first { $0.id == settings.ai.activeProviderID })
        let key = CredentialFileStore(directory: real.appendingPathComponent("credentials")).read(account: config.keychainAccount) ?? ""
        let cache = real.appendingPathComponent("docs/b5c9bcd95f3fbd54/document-context.json")
        let snapshot = try JSONDecoder().decode(PDFContextSnapshot.self, from: Data(contentsOf: cache))
        let chat = AIChatModel(store: ConversationStore(), providerFactory: { OpenAICompatibleProvider(config: $0, apiKey: key) })
        chat.newConversation(sourcePath: snapshot.context.path, sourceTitle: "皮尔斯全书验证")
        var report = "# 全书实测\n\n模型：\(config.selectedModel)，页数：\(snapshot.context.unitCount)，材料字符数：\(snapshot.context.evidence.reduce(0) { $0 + $1.text.count })。使用既有真实文字缓存，无选区。\n"
        for (question, agent) in [
            ("请基于全书概括主要部分的内容和相互关系，兼顾前半部与后半部，不要只总结推理理论。列出原文来源范围。", Optional<AgentConfig>.none),
            ("请基于全书内容画思维导图，覆盖主要部分及相互关系，不要只展示推理这一章。", Optional(AgentConfig.mindMapMode))
        ] {
            let start = Date()
            chat.submit(task: .ask(question: question), selection: nil, metadata: .init(), locatorLabel: "全文", context: "",
                locator: .pdf(page: 0, charOffset: 0), config: config, memory: "", translateTarget: "简体中文",
                agent: agent, sourcePath: snapshot.context.path, contextLoader: { [snapshot.context] })
            while chat.isStreaming { try await Task.sleep(for: .milliseconds(200)) }
            let result = try #require(chat.bubbles.last)
            report += "\n## \(question)\n\n\(result.text)\n\n覆盖：\(result.coverage)；失败：\(result.failed)；耗时：\(Int(Date().timeIntervalSince(start)))s；请求：\(result.requestCount)；输入：\(result.usage?.input ?? -1)；输出：\(result.usage?.output ?? -1)。\n"
            try report.write(to: URL(fileURLWithPath: output).appendingPathComponent("live-whole-book.md"), atomically: true, encoding: .utf8)
            let failed = result.failed
            #expect(!failed)
            if agent != nil { #expect(MindMapResult.parse(result.text) != nil) }
            if result.failed { return }
        }
        // Non-secret isolated settings let native UI verify the resulting map.
        var isolated = AppSettings()
        isolated.ai.providers = [config]; isolated.ai.activeProviderID = config.id
        isolated.ai.activeAgentID = AgentConfig.mindMapMode.id
        try JSONEncoder().encode(isolated).write(to: AppPaths.settingsFile)
    }
}
