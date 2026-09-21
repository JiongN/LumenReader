import Foundation
import Testing
@testable import LumenKit

@Suite("AI 服务商与 Agent 配置")
struct AIConfigurationTests {

    @Test("自定义问题在无选区时仍携带文档上下文")
    func customPromptKeepsContext() {
        let marker = "【双文档对照】\n【文档 A】A 的论点\n【文档 B】B 的论点"
        let messages = PromptLibrary.messages(
            task: .custom(prompt: "比较两份文档"),
            selection: nil,
            metadata: DocumentMetadata(),
            locatorLabel: "第 1 页",
            context: marker,
            memory: ""
        )
        #expect(messages.last?.content.contains(marker) == true)
    }

    @Test("超长文档分段覆盖每一页且不超过请求上限")
    func summarySliceCoverage() {
        for itemCount in [1, 20, 31, 120, 600, 2_001] {
            let ranges = SummarySlicePlanner.ranges(itemCount: itemCount, maximumGroups: 30)
            #expect(ranges.count == min(itemCount, 30))
            #expect(ranges.flatMap(Array.init) == Array(0..<itemCount))
            #expect((ranges.map(\.count).max() ?? 0) - (ranges.map(\.count).min() ?? 0) <= 1)
        }
    }
    @Test("一个服务商保留多个模型并去重")
    func providerKeepsMultipleModels() throws {
        let provider = AIProviderConfig(
            name: "Test",
            baseURL: "https://example.com/v1",
            models: ["fast", "strong", "fast", "  "],
            selectedModel: "custom"
        )
        #expect(provider.models == ["fast", "strong", "custom"])

        let decoded = try JSONDecoder().decode(
            AIProviderConfig.self,
            from: JSONEncoder().encode(provider)
        )
        #expect(decoded.models == provider.models)
        #expect(decoded.selectedModel == "custom")
    }

    @Test("技能按 id 持久化，并要求用技能库解析")
    func agentSkillsRoundTrip() throws {
        let agent = AgentConfig(name: "方法审查", skills: ["socratic"])
        let data = try JSONEncoder().encode(agent)
        let decoded = try JSONDecoder().decode(AgentConfig.self, from: data)
        #expect(decoded.skills == ["socratic"])
        // Agent 上只有 id：不给技能库就拼不出要求（这正是「改一处、处处生效」的代价，
        // 所以 `PromptLibrary.systemPrompt` 必须把库一起传进来）。
        #expect(decoded.promptSection(in: []).isEmpty)
        #expect(decoded.promptSection(in: AgentSkill.catalog).contains("不要直接给出结论"))
        #expect(!(String(data: data, encoding: .utf8) ?? "").contains("carriedSkills"))
    }

    /// 迁移载体 `carriedSkills` 只在解码路上有用：写回磁盘就等于技能全文又存回 Agent 身上，
    /// 技能库不再是一份来源，两条真相迟早分叉。
    @Test("迁移载体不会被写回磁盘")
    func carriedSkillsAreNotEncoded() throws {
        let json = """
        {"id":"L","name":"旧","persona":"",
         "skills":[{"id":"C1","name":"因果检查","instruction":"区分相关与因果。"}]}
        """
        let decoded = try JSONDecoder().decode(AgentConfig.self, from: Data(json.utf8))
        #expect(decoded.skills == ["C1"])
        #expect(decoded.carriedSkills.count == 1)

        let reencoded = String(data: try JSONEncoder().encode(decoded), encoding: .utf8) ?? ""
        #expect(!reencoded.contains("carriedSkills"))
        #expect(!reencoded.contains("因果检查"))
    }

    /// 迁移路径：旧配置里技能全文只存在于 Agent 上（`skills` 是带全文的对象数组，
    /// 或者更早的 `customSkills` 那一块）。两者都要并进技能库，Agent 上只留 id ——
    /// 只认新格式的话，用户自己写的技能会在升级那一刻静默消失。
    @Test("旧的技能定义并进技能库，Agent 上只留 id")
    func legacySkillsMigrateIntoLibrary() throws {
        let json = """
        {"providers":[],"streaming":true,"templates":[],
         "agents":[{"id":"legacy","name":"旧 Agent","persona":"","skills":["socratic","critique"],
                    "customSkills":[{"id":"C1","name":"因果检查","instruction":"区分相关关系与因果关系。"}],
                    "usesWebSearch":false,"isBuiltIn":false}]}
        """
        let settings = try JSONDecoder().decode(AISettings.self, from: Data(json.utf8))
        let agent = try #require(settings.agents.first)
        #expect(agent.skills == ["socratic", "critique", "C1"])
        #expect(settings.skillLibrary.contains { $0.id == "C1" })
        #expect(agent.promptSection(in: settings.skillLibrary)
            .contains("【因果检查】区分相关关系与因果关系。"))
    }

    /// 老配置里「论证链」「术语变化」是用户自建技能（各自带一个 UUID），
    /// 而它们现在是内置技能。不按名字认领的话，技能库里会出现两张同名卡。
    @Test("同名旧技能认领到内置那条，不新增重复卡")
    func sameNameSkillIsClaimed() throws {
        let json = """
        {"providers":[],"streaming":true,"templates":[],
         "agents":[{"id":"legacy","name":"同名","persona":"","skills":[],
                    "customSkills":[{"id":"X1","name":"论证链","instruction":"把核心论证写成链条。"}],
                    "usesWebSearch":false,"isBuiltIn":false}]}
        """
        let settings = try JSONDecoder().decode(AISettings.self, from: Data(json.utf8))
        #expect(settings.skillLibrary.filter { $0.name == "论证链" }.count == 1)
        #expect(settings.agents.first?.skills == ["argumentChain"])
    }

    @Test("技能库里没有的 id 读盘时被清掉")
    func danglingSkillIDsAreRemoved() throws {
        let json = """
        {"providers":[],"streaming":true,"templates":[],"skillLibrary":[],
         "agents":[{"id":"a","name":"悬空","persona":"","skills":["ghost"],
                    "usesWebSearch":false,"isBuiltIn":false}]}
        """
        let settings = try JSONDecoder().decode(AISettings.self, from: Data(json.utf8))
        #expect(settings.agents.first?.skills.isEmpty == true)
    }

    /// 与「删掉的 Agent 不补回来」同一条规则：技能库缺键才灌内置技能，
    /// 已被用户清空就保持为空，否则删掉的技能下次启动会自己长回来。
    @Test("技能库缺键才灌内置技能，空数组保持为空")
    func skillLibrarySeeding() throws {
        let fresh = try JSONDecoder().decode(
            AISettings.self,
            from: Data(#"{"providers":[],"streaming":true,"templates":[]}"#.utf8)
        )
        #expect(Set(fresh.skillLibrary.map(\.id)) == Set(AgentSkill.catalog.map(\.id)))

        let emptied = try JSONDecoder().decode(
            AISettings.self,
            from: Data(#"{"providers":[],"streaming":true,"templates":[],"skillLibrary":[]}"#.utf8)
        )
        #expect(emptied.skillLibrary.isEmpty)
    }

    /// 旧 Agent 配置里还留着一批已经取消的字段（`customInstruction`、`customSkills`、枚举
    /// rawValue）。缺一个键就整份解码失败的话，用户自己建的 Agent 会被静默重置成预设。
    @Test("旧 Agent 配置里已取消的字段不影响解码")
    func legacyAgentWithRemovedFields() throws {
        let json = """
        {"id":"legacy","name":"旧 Agent","persona":"","skills":[],"usesWebSearch":false,
         "isBuiltIn":false,"customInstruction":"每次都要给出一条可证伪的反对意见","customSkills":[]}
        """
        let decoded = try JSONDecoder().decode(AgentConfig.self, from: Data(json.utf8))
        #expect(decoded.skills.isEmpty)
        #expect(decoded.promptSection(in: AgentSkill.catalog).isEmpty)
    }

    /// 编辑器允许删除任意 Agent（包括内置预设），所以读盘时**不能**再把缺的预设补回来，
    /// 否则用户删掉的那个会在下次启动自己长回来。
    @Test("磁盘上 agents 为空时保持为空，不被预设补回")
    func deletedAgentsStayDeleted() throws {
        let json = """
        {"providers":[],"streaming":true,"templates":[],"agents":[]}
        """
        let settings = try JSONDecoder().decode(AISettings.self, from: Data(json.utf8))
        #expect(settings.agents.isEmpty)
    }

    /// 与上一条互为边界：磁盘上**完全没有** `agents` 这个键（首次启动 / 该功能上线前的旧配置）
    /// 才灌预设，否则老用户打开编辑器会看到一片空白。
    @Test("配置里没有 agents 键时才灌入预设")
    func freshInstallSeedsPresets() throws {
        let json = """
        {"providers":[],"streaming":true,"templates":[]}
        """
        let settings = try JSONDecoder().decode(AISettings.self, from: Data(json.utf8))
        #expect(Set(settings.agents.map(\.id)) == Set(AgentConfig.presets.map(\.id)))
    }

    /// 已下线的预设（从产品里移除，不在 `presets` 表里）会以旧数据的形态留在用户磁盘上，
    /// 读盘要清掉它，并且不能留下悬空的 `activeAgentID`。
    @Test("磁盘上残留的下线预设读盘时被清掉且不留悬空选择")
    func retiredPresetIsCleanedOnLoad() throws {
        let retiredID = try #require(AgentConfig.retiredPresetIDs.first)
        let json = """
        {"providers":[],"streaming":true,"templates":[],
         "agents":[{"id":"\(retiredID)","name":"批判审稿人","persona":"","skills":["critique"],
                    "usesWebSearch":false,"isBuiltIn":true}],
         "activeAgentID":"\(retiredID)"}
        """
        let settings = try JSONDecoder().decode(AISettings.self, from: Data(json.utf8))
        #expect(!settings.agents.contains { $0.id == retiredID })
        #expect(settings.activeAgentID == nil)
    }
}
