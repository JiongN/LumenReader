import Foundation
import LumenKit

// MARK: - Agent 与联网检索

/// Agent 自检。
///
/// 提示词这一层的验证要点是「拼出来的到底是什么」——所以直接把最终 system / user
/// 消息打出来，人（或下一步的断言）能逐字核对。同时打一份上网检索的真实结果：
/// 检索是**联网动作**，失败的形态很多（超时、限流、被墙），必须如实报出来，
/// 而不是让「Agent 说找不到文献」变成一个查不出原因的黑盒。
enum AgentAudit {

    /// 温度覆盖的两条断言：盖得住、且不改回写服务商设置。
    @MainActor
    private static func checkTemperatureOverride(_ check: (String, Bool, String) -> Void) {
        // 自检里要建一个模型做温度覆盖断言：现在 AIChatModel 不再有裸 init，
        // 必须传一个 store。这里用一份临时 store（自检模式 supportRoot 已被重定向到临时目录，
        // 不会污染真实对话数据）。
        let model = AIChatModel(store: ConversationStore())
        let provider = AIProviderConfig(
            name: "自检服务商",
            baseURL: "http://127.0.0.1:1/v1",
            models: ["mock"],
            selectedModel: "mock",
            temperature: 0.9
        )
        let originalTemperature = provider.temperature

        func snapshot(with agent: AgentConfig?) -> AIChatModel.RequestSnapshot {
            AIChatModel.RequestSnapshot(
                task: .explain,
                selection: nil,
                metadata: DocumentMetadata(title: "自检文档"),
                locatorLabel: "第 1 页",
                context: "自检正文",
                locator: .pdf(page: 0, charOffset: 0),
                citations: [],
                config: provider,
                memory: "",
                translateTarget: "简体中文",
                template: nil,
                agent: agent,
                webSearchEnabled: false
            )
        }

        var withOverride = AgentConfig(name: "自检 Agent", temperatureOverride: 0.15)
        let overridden = model.effectiveConfig(for: snapshot(with: withOverride)).temperature
        check("Agent 的温度覆盖生效", abs(overridden - 0.15) < 0.0001,
              "实际 \(overridden)，期望 0.15")

        // 越界值必须被钳制：手改 settings.json 塞个 9.9 进来，
        // 不加这道闸就会把请求直接打成一个服务端会拒绝的参数。
        let upperBound = AgentConfig.temperatureRange.upperBound
        withOverride.temperatureOverride = 9.9
        let clamped = model.effectiveConfig(for: snapshot(with: withOverride)).temperature
        check("越界的温度覆盖被钳制到 \(upperBound)", abs(clamped - upperBound) < 0.0001,
              "实际 \(clamped)，期望 \(upperBound)")

        withOverride.temperatureOverride = nil
        let followed = model.effectiveConfig(for: snapshot(with: withOverride)).temperature
        check("未设覆盖时跟随服务商设置", abs(followed - originalTemperature) < 0.0001,
              "实际 \(followed)，期望 \(originalTemperature)")
    }

    private static func decode<T: Decodable>(_ type: T.Type, from json: String) -> T? {
        guard let data = json.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }

    /// 编码再解码一遍，用来验「新格式存下去还读得回来」。
    private static func roundTrip(_ agent: AgentConfig) -> AgentConfig? {
        guard let data = try? JSONEncoder().encode(agent) else { return nil }
        return try? JSONDecoder().decode(AgentConfig.self, from: data)
    }

    static func run() async {
        var passed = 0
        var failures: [String] = []
        func check(_ name: String, _ ok: Bool, _ detail: String = "") {
            if ok { passed += 1 } else { failures.append(name) }
            NSLog("%@", "[Lumen][agent] \(ok ? "✅" : "❌") \(name)\(detail.isEmpty ? "" : " —— \(detail)")")
        }

        let library = AgentSkill.catalog
        NSLog("%@", "[Lumen][agent] 内置技能：\(library.count) 条"
            + "（" + library.map(\.name).joined(separator: "、") + "）")

        NSLog("%@", "[Lumen][agent] 预设 Agent：\(AgentConfig.presets.count) 个")
        for agent in AgentConfig.presets {
            let names = agent.resolvedSkills(in: library).map(\.name).joined(separator: "/")
            NSLog("%@", "[Lumen][agent]   \(agent.name)｜技能=\(names)"
                + "｜联网=\(agent.usesWebSearch)｜id=\(agent.id.prefix(8))…")
        }

        // 预设里写错一个技能 id 的后果是那条技能**静默**不生效（系统提示里少一行，
        // 界面上完全看不出来），所以逐条对一遍。
        let unknownSkillIDs = AgentConfig.presets.flatMap(\.skills)
            .filter { AgentSkill.catalogEntry(id: $0) == nil }
        check("预设引用的技能都在内置技能里", unknownSkillIDs.isEmpty,
              "找不到：\(Set(unknownSkillIDs).sorted())")

        // 预设 id 必须稳定：写死字面量，否则「配置里没有 agents 时退回预设」这条路径
        // 每次都得到新 id，用户选中的 Agent 会静默丢失。
        let firstRun = AgentConfig.presets.map(\.id)
        let secondRun = AgentConfig.presets.map(\.id)
        check("预设 id 稳定（可被配置引用）", firstRun == secondRun)

        // 已下线的预设：不在预设表里 + 已登记（登记了才会在读盘时把用户那份旧副本清掉）。
        // 两条一起断言，是因为只删预设表而漏登记，用户那边的「批判审稿人」会一直活着。
        check("预设表里已经没有「批判审稿人」",
              !AgentConfig.presets.contains { $0.name == "批判审稿人" })
        check("批判审稿人的 id 已登记为下线预设",
              AgentConfig.retiredPresetIDs.contains("3C9D5F71-2B8E-4A63-9F07-1E5A8C4B6D22"))
        check("没有预设用着下线名单里的 id",
              !AgentConfig.presets.contains { AgentConfig.retiredPresetIDs.contains($0.id) })

        // 原先是两条独立的自定义技能，现在并进了内置技能目录 ——
        // 断言名字而不只是条数：条数对了但内容是别的，从终值上看不出来。
        check("「论证链」「术语变化」已并入内置技能目录",
              ["论证链", "术语变化"].allSatisfy { name in
                  AgentSkill.catalog.contains { $0.name == name }
              })

        // 角色 + 技能是否真的进了系统提示，且没有顶掉默认约束
        guard let socratic = AgentConfig.presets.first(where: { $0.name == "苏格拉底导师" }) else {
            check("找得到苏格拉底预设", false)
            return
        }
        let system = PromptLibrary.systemPrompt(readerPersona: "自检读者背景", agent: socratic, skills: library)
        check("系统提示里含角色设定", system.contains("善于提问的导师"))
        check("系统提示里含苏格拉底技能", system.contains("不要直接给出结论"))
        check("默认的防幻觉约束仍在", system.contains("原文没有提到"))
        check("读者背景仍在", system.contains("自检读者背景"))

        let withoutAgent = PromptLibrary.systemPrompt(readerPersona: "")
        check("不选 Agent 时不出现角色段落", !withoutAgent.contains("角色设定"))

        // 技能库是**共用样式**：改一处，用它的所有 Agent 一起变。
        // 这是这次改动的核心语义，也是「改了只对自己那个 Agent 生效」这种半生效状态的守门断言。
        var editedLibrary = library
        if let index = editedLibrary.firstIndex(where: { $0.id == "concepts" }) {
            editedLibrary[index].instruction = "自检改写的概念界定要求。"
        }
        let conceptAgents = [
            AgentConfig(name: "甲", skills: ["concepts"]),
            AgentConfig(name: "乙", skills: ["concepts"])
        ]
        check("改一条技能，用它的所有 Agent 一起变",
              conceptAgents.allSatisfy { $0.promptSection(in: editedLibrary).contains("自检改写的概念界定要求。") })
        check("没改到的技能不受影响",
              conceptAgents[0].promptSection(in: library).contains("自检改写的概念界定要求。") == false)

        // MARK: 技能：id 往返 + 三条旧格式的迁移
        //
        // 迁移断言是这个改动里最要紧的：技能全文原先存在 Agent 上，
        // 现在只有技能库里有全文。搬错一步，用户自己写的技能就会**静默**消失
        // ——系统提示变短了，界面上却看不出少了什么。
        let roundTripAgent = AgentConfig(name: "往返", skills: ["socratic", "concepts"])
        check("技能按 id 存取往返不丢",
              roundTrip(roundTripAgent).map { agent in
                  agent.skills == ["socratic", "concepts"]
                      && agent.promptSection(in: library).contains("不要直接给出结论")
              } ?? false)

        // 旧格式 ②：`skills` 是带全文的对象数组（2026-09-21 一度用过）。
        // 全文要经 `AISettings` 并进技能库，Agent 上只留 id。
        let legacyFull = """
        {"providers":[],"streaming":true,"templates":[],
         "agents":[{"id":"LEGACY-FULL","name":"旧技能 Agent","persona":"",
                    "skills":[{"id":"socratic","name":"苏格拉底式","instruction":"不要直接给出结论。"},
                              {"id":"C1","name":"因果检查","instruction":"区分相关关系与因果关系。"}],
                    "usesWebSearch":false,"isBuiltIn":false}]}
        """
        if let migrated = decode(AISettings.self, from: legacyFull) {
            check("旧的对象数组技能只留 id",
                  migrated.agents.first?.skills == ["socratic", "C1"],
                  "实得 \(migrated.agents.first?.skills ?? [])")
            check("带全文的自建技能被并进技能库",
                  migrated.skillLibrary.contains { $0.id == "C1" && $0.name == "因果检查" },
                  "实得 \(migrated.skillLibrary.map(\.name))")
            check("并库之后它照样进系统提示",
                  migrated.agents.first?
                      .promptSection(in: migrated.skillLibrary)
                      .contains("【因果检查】区分相关关系与因果关系。") ?? false)
        } else {
            check("旧的对象数组技能能解码", false)
        }

        // 旧格式 ③：`skills` 是枚举 rawValue + 另一块 `customSkills`。
        let legacyMerged = """
        {"providers":[],"streaming":true,"templates":[],
         "agents":[{"id":"LEGACY-BOTH","name":"旧混合 Agent","persona":"","skills":["socratic","critique"],
                    "customSkills":[{"id":"C2","name":"因果检查","instruction":"区分相关关系与因果关系。"}],
                    "usesWebSearch":false,"isBuiltIn":false}]}
        """
        if let merged = decode(AISettings.self, from: legacyMerged) {
            check("旧的字符串技能与自定义技能并进同一条清单",
                  merged.agents.first?.skills == ["socratic", "critique", "C2"],
                  "实得 \(merged.agents.first?.skills ?? [])")
            check("还原出来的技能带着名字与要求",
                  merged.agents.first?.resolvedSkills(in: merged.skillLibrary).first?.name == "苏格拉底式")
        } else {
            check("旧的字符串技能能解码", false)
        }

        // 同名的认领到库里那条：老配置里「论证链」「术语变化」是用户自建技能（各自带 UUID），
        // 而它们现在是内置技能。不认领的话技能库里会出现两张同名卡，用户看到的是
        // 「怎么有两个论证链」。
        let legacySameName = """
        {"providers":[],"streaming":true,"templates":[],
         "agents":[{"id":"LEGACY-SAME","name":"同名","persona":"","skills":[],
                    "customSkills":[{"id":"X1","name":"论证链","instruction":"把核心论证写成链条。"}],
                    "usesWebSearch":false,"isBuiltIn":false}]}
        """
        if let claimed = decode(AISettings.self, from: legacySameName) {
            check("同名的旧技能认领到内置那条，不新增重复卡",
                  claimed.skillLibrary.filter { $0.name == "论证链" }.count == 1
                      && claimed.agents.first?.skills == ["argumentChain"],
                  "同名卡 \(claimed.skillLibrary.filter { $0.name == "论证链" }.count) 张，"
                      + "勾选 \(claimed.agents.first?.skills ?? [])")
        } else {
            check("同名旧技能能解码", false)
        }

        // 悬空 id：技能库里没有的 id 在界面上是一张勾不掉的空卡，读盘时清掉。
        let dangling = """
        {"providers":[],"streaming":true,"templates":[],"skillLibrary":[],
         "agents":[{"id":"DANGLE","name":"悬空","persona":"","skills":["ghost"],
                    "usesWebSearch":false,"isBuiltIn":false}]}
        """
        check("库里没有的技能 id 被清掉",
              decode(AISettings.self, from: dangling)?.agents.first?.skills.isEmpty == true)

        // 刚点「新建技能」还没写要求的空条目不该发出去——发一条空白要求只会让模型困惑，
        // 而这种失败在界面上完全看不出来（用户看到的是「技能已添加」）。
        let blankLibrary = library + [AgentSkill(id: "blank", name: "还没写", instruction: "   ")]
        let blankAgent = AgentConfig(name: "空技能", skills: ["blank"])
        check("空要求不会变成一条空白约束发出去",
              !PromptLibrary.systemPrompt(agent: blankAgent, skills: blankLibrary).contains("还没写"))

        // 「列文献」只在开了联网检索时才发出去；判定看 id，不看名字。
        // 改名字就失效的话，用户给技能改个名会莫名其妙地改变行为。
        if AgentSkill.catalogEntry(id: AgentSkill.literatureID) != nil {
            let searchOff = AgentConfig(name: "联网关", skills: [AgentSkill.literatureID], usesWebSearch: false)
            let searchOn = AgentConfig(name: "联网开", skills: [AgentSkill.literatureID], usesWebSearch: true)
            let marker = "联网检索结果"
            check("没开联网时「列文献」的要求不发给模型",
                  !searchOff.promptSection(in: library).contains(marker)
                      && searchOn.promptSection(in: library).contains(marker),
                  "关=\(searchOff.promptSection(in: library).contains(marker))"
                      + " 开=\(searchOn.promptSection(in: library).contains(marker))")

            // 把库里那条的名字改掉，按 id 判定的实现照样拦得住
            var renamedLibrary = library
            if let index = renamedLibrary.firstIndex(where: { $0.id == AgentSkill.literatureID }) {
                renamedLibrary[index].name = "找文献"
            }
            check("「列文献」的判定看 id 不看名字",
                  !AgentConfig(name: "改了名的联网关", skills: [AgentSkill.literatureID], usesWebSearch: false)
                      .promptSection(in: renamedLibrary).contains("找文献"))
        } else {
            check("内置技能里有「列文献」", false)
        }

        // 容错解码：旧配置里没有 `temperatureOverride` 这个键。缺一个键就整份解码失败的话，
        // 用户自己建的 Agent 会被静默重置成预设——这属于最糟的那类降级。
        let legacyAgent = """
        {"id":"LEGACY-1","name":"旧 Agent","persona":"旧角色","skills":["socratic"],
         "usesWebSearch":false,"isBuiltIn":false}
        """
        let legacyAgentOK = decode(AgentConfig.self, from: legacyAgent).map { agent in
            agent.name == "旧 Agent"
                && agent.temperatureOverride == nil
                && agent.skills.count == 1
        } ?? false
        check("旧 Agent 配置缺新字段仍能解码", legacyAgentOK)

        let legacyAI = """
        {"providers":[],"streaming":true,"templates":[],"agents":[]}
        """
        let legacyAIOK = decode(AISettings.self, from: legacyAI).map { settings in
            settings.webSearchEnabled == false && settings.agents.isEmpty
        } ?? false
        check("旧 AI 配置缺 webSearchEnabled 时默认为关；agents 为空就保持为空", legacyAIOK)

        // 删除 Agent 之后它不能自己长回来：以前这里是「缺哪个预设就补哪个」，
        // 与「允许删除任意 Agent」并存就会出现「删掉的 Agent 下次启动自己长回来」。
        // （上面那条 `agents: []` 的断言就是这条规则本身。）
        let freshInstall = """
        {"providers":[],"streaming":true,"templates":[]}
        """
        check("配置里完全没有 agents 键时才灌预设",
              decode(AISettings.self, from: freshInstall).map {
                  Set($0.agents.map(\.id)) == Set(AgentConfig.presets.map(\.id))
              } ?? false)

        // 已下线预设留在用户磁盘上：读盘必须把它清掉，且不能留下悬空的 activeAgentID
        // （悬空的表现是面板显示「Agent」却不带勾选，从界面上看不出所以然）。
        if let retiredID = AgentConfig.retiredPresetIDs.first {
            let staleRetired = """
            {"providers":[],"streaming":true,"templates":[],
             "agents":[{"id":"\(retiredID)","name":"批判审稿人","persona":"","skills":["critique"],
                        "usesWebSearch":false,"isBuiltIn":true}],
             "activeAgentID":"\(retiredID)"}
            """
            let cleaned = decode(AISettings.self, from: staleRetired)
            check("磁盘上残留的下线预设读盘时被清掉",
                  cleaned?.agents.contains { $0.id == retiredID } == false,
                  "实得 \(cleaned?.agents.map(\.name) ?? [])")
            check("清掉之后 activeAgentID 不悬空", cleaned?.activeAgentID == nil,
                  "实得 \(cleaned?.activeAgentID ?? "nil")")
        } else {
            check("下线预设名单不为空", false)
        }

        // 技能库：首次启动灌内置技能；用户删掉的不自己长回来（与 agents 同一条规则，
        // 否则「删了又回来」会让用户以为删除功能坏了）。
        let freshAI = """
        {"providers":[],"streaming":true,"templates":[]}
        """
        check("首次启动灌入内置技能库",
              decode(AISettings.self, from: freshAI).map {
                  Set($0.skillLibrary.map(\.id)) == Set(AgentSkill.catalog.map(\.id))
              } ?? false)
        let emptiedAI = """
        {"providers":[],"streaming":true,"templates":[],"skillLibrary":[]}
        """
        check("技能库被清空后不会自动补回",
              decode(AISettings.self, from: emptiedAI)?.skillLibrary.isEmpty == true)

        let customSkill = AgentSkill(name: "因果检查", instruction: "区分相关与因果。")
        check("用户自建技能进入系统提示",
              PromptLibrary.systemPrompt(
                  agent: AgentConfig(name: "自建", skills: [customSkill.id]),
                  skills: library + [customSkill]
              ).contains("【因果检查】区分相关与因果。"))

        // 温度覆盖：Agent 上那个值要盖掉服务商的，且**不能**回头改掉服务商设置本身。
        // 这是纯输入→输出的规则，可以直接实跑断言；不这么验的话，
        // 「温度到底有没有传出去」在这台没有视觉通道的机器上无从判断。
        await checkTemperatureOverride(check)

        // 联网检索：真跑一次，把结果和失败原因都打出来
        let query = "cultural capital education inequality"
        NSLog("%@", "[Lumen][agent] 联网检索测试：query = 「\(query)」")
        let started = Date()
        let outcome = await WebLiteratureSearch.search(query: query)
        let elapsed = Int(Date().timeIntervalSince(started) * 1000)
        NSLog("%@", "[Lumen][agent] 耗时 \(elapsed)ms，命中 \(outcome.hits.count) 条，失败 \(outcome.failures.count) 个源")
        for failure in outcome.failures {
            NSLog("%@", "[Lumen][agent]   源失败：\(failure)")
        }
        for hit in outcome.hits.prefix(5) {
            NSLog("%@", "[Lumen][agent]   [\(hit.source)] \(hit.title.prefix(60))"
                + " — \(hit.authors.prefix(30)) \(hit.year) \(hit.identifier)")
        }

        let block = WebLiteratureSearch.promptBlock(outcome)
        check("检索结果能渲染成提示词段落", !outcome.hits.isEmpty && block.contains("联网检索到的文献"),
              "命中 \(outcome.hits.count) 条")

        // 只看「有结果」还不够：三个源里挂两个、只剩一个在撑，从终值上分辨不出来。
        // 把出结果的源列出来，才看得出覆盖面。
        let sources = Set(outcome.hits.map(\.source)).sorted()
        NSLog("%@", "[Lumen][agent] 出结果的源：\(sources.isEmpty ? "无" : sources.joined(separator: "、"))")
        check("至少两个数据源出了结果（单源故障不影响可用性）", sources.count >= 2,
              "\(sources.count) 个源")

        if !outcome.hits.isEmpty {
            check("段落里带可核查的出处", block.contains("DOI") || block.contains("arxiv") || block.contains("arXiv"))
            check("段落里写明「检索不到就不要编」", block.contains("不要凭记忆补写"))
        }

        // OpenAlex 不直接给摘要文本，给的是一张「词 → 位置数组」的倒排索引
        // （受法律约束的取巧：只有词与位置，不构成原作品的可读复制）。
        // 还原是纯函数，可以精确断言——不还原的话这一源就只有标题和作者。
        let restored = WebLiteratureSearch.abstractFromInvertedIndex([
            "of": [0], "cultural": [1, 5], "capital": [2], "and": [3], "education": [4]
        ])
        check("OpenAlex 倒排索引能还原成正常语序",
              restored == "of cultural capital and education cultural", restored)
        check("没有倒排索引时摘要为空而不是崩掉",
              WebLiteratureSearch.abstractFromInvertedIndex(nil).isEmpty
                && WebLiteratureSearch.abstractFromInvertedIndex([:]).isEmpty)

        // 拼装后的 user 消息里，三块材料的先后关系必须对得上：
        // 文档抬头 → 原文 → 联网检索结果 → 任务要求。
        // 这条断言是有来历的：旧版把 webContext 追加在 switch 之后，也就是排到了
        // 任务要求**后面**，而它上面的注释写的是「排在任务要求之前」——
        // 注释与实现相反，从终值上完全看不出来（同一条消息、同样都含这些字）。
        let messages = PromptLibrary.messages(
            task: .ask(question: "这本书讲的结论和学界主流一致吗？"),
            selection: nil,
            metadata: DocumentMetadata(title: "自检文档"),
            locatorLabel: "第 1 页",
            context: "自检正文",
            memory: "",
            agent: socratic,
            skills: library,
            webContext: block
        )
        if let last = messages.last {
            let docIndex = last.content.range(of: "【文档信息】")?.lowerBound
            let textIndex = last.content.range(of: "自检正文")?.lowerBound
            let webIndex = last.content.range(of: "联网检索到的文献")?.lowerBound
            let taskIndex = last.content.range(of: "读者的问题")?.lowerBound

            if let webIndex, let taskIndex {
                check("检索结果排在任务要求之前", webIndex < taskIndex,
                      taskIndex > webIndex ? "" : "检索段落跑到了问题后面")
            } else {
                check("user 消息里同时含检索结果与问题", false,
                      "检索段落=\(webIndex != nil) 问题=\(taskIndex != nil)")
            }
            if let docIndex, let textIndex, let webIndex {
                check("原文排在联网检索结果之前",
                      docIndex < textIndex && textIndex < webIndex)
            }
        }

        NSLog("%@", "[Lumen][agent] 自检：通过 \(passed) 项，失败 \(failures.count) 项"
            + (failures.isEmpty ? " ✅" : " ❌ " + failures.joined(separator: "；")))
    }
}
