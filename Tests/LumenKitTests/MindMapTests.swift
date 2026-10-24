import Foundation
import Testing
@testable import LumenKit

@Suite("思维导图与独立翻译模型")
struct MindMapTests {
    @Test func structuredTreeRendersWithBoundedLayout() throws {
        let text = "说明\n```mindmap\n{\"label\":\"主题\",\"children\":[{\"label\":\"证据\",\"source\":\"第 2 页\"},{\"label\":\"限定\",\"children\":[{\"label\":\"风险\"}]}]}\n```\n结论"
        let result = try #require(MindMapResult.parse(text))
        #expect(result.root.children.count == 2)
        #expect(result.surroundingText == "说明\n\n结论")
        let layout = MindMapLayout(root: result.root)
        #expect(layout.items.count == 4)
        #expect(layout.edges.count == 3)
        #expect(layout.items.allSatisfy { $0.center.x >= 84 && $0.center.y >= 36 && $0.center.x + 84 <= layout.size.width && $0.center.y + 36 <= layout.size.height })
    }

    @Test func malformedAndOversizedTreesRemainPlainText() throws {
        let deep = String(repeating: "{\"label\":\"x\",\"children\":[", count: 1000) + "{\"label\":\"leaf\"}" + String(repeating: "]}", count: 1000)
        #expect(MindMapResult.parse(deep) == nil)
        #expect(MindMapResult.parse("```mindmap\n{bad}\n```") == nil)
        #expect(MindMapResult.parse("```mindmap\n{\"label\":\"\"}\n```") == nil)
        let root = MindMapNode(label: "root", children: (0..<121).map { .init(label: String($0)) })
        let json = String(decoding: try JSONEncoder().encode(root), as: UTF8.self)
        #expect(MindMapResult.parse("```mindmap\n\(json)\n```") == nil)
        #expect(MindMapResult.parse("普通回答") == nil)
    }

    @Test func unfencedCompatibleProviderJSONAndEscapedBracesAreAccepted() throws {
        let result = try #require(MindMapResult.parse(" {\"label\":\"包含 } 和 \\\"引号\\\"\",\"children\":[{\"label\":\"分支\"}]}\n\n说明文字"))
        #expect(result.root.children.count == 1)
        #expect(result.root.label.contains("}"))
        #expect(result.surroundingText == "说明文字")
        #expect(MindMapResult.parse("```json\n{\"label\":\"主题\"}\n```") != nil)
    }

    @Test func mapModeSurvivesReloadAndDoesNotRequireSkillSelection() throws {
        var ai = AISettings()
        ai.activeAgentID = AgentConfig.mindMapMode.id
        ai.skillLibrary = []
        let restored = try JSONDecoder().decode(AISettings.self, from: JSONEncoder().encode(ai))
        #expect(restored.activeReadingMode == AgentConfig.mindMapMode)
        #expect(PromptLibrary.systemPrompt(agent: restored.activeReadingMode).contains("mindmap 代码块"))
    }

    @Test func translationChoiceDoesNotFollowOrMutateChat() throws {
        var ai = AISettings()
        let a = AIProviderConfig(name: "A", baseURL: "http://localhost:8777/v1", models: ["translate", "chat"], selectedModel: "chat")
        let b = AIProviderConfig(name: "B", baseURL: "http://localhost:8778/v1", models: ["other"], selectedModel: "other")
        ai.providers = [a, b]; ai.activeProviderID = a.id
        var reader = ReaderSettings()
        reader.translationProviderID = a.id; reader.translationModel = "translate"
        ai.activeProviderID = b.id
        ai.providers[0].selectedModel = "chat-updated"
        #expect(ai.translationProvider(for: reader)?.selectedModel == "translate")
        #expect(ai.translationProvider(for: reader)?.id == a.id)
        #expect(ai.activeProviderID == b.id)
        let restored = try JSONDecoder().decode(ReaderSettings.self, from: JSONEncoder().encode(reader))
        #expect(restored.translationModel == "translate")
        ai.providers.removeFirst()
        #expect(ai.translationProvider(for: reader) == nil)
        let legacy = try JSONDecoder().decode(ReaderSettings.self, from: Data("{}".utf8))
        #expect(legacy.translationProviderID == nil)
        #expect(legacy.translationModel.isEmpty)
    }
}
