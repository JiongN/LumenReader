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

    static func run() async {
        var passed = 0
        var failures: [String] = []
        func check(_ name: String, _ ok: Bool, _ detail: String = "") {
            if ok { passed += 1 } else { failures.append(name) }
            NSLog("[Lumen][agent] \(ok ? "✅" : "❌") \(name)\(detail.isEmpty ? "" : " —— \(detail)")")
        }

        NSLog("[Lumen][agent] 预设 Agent：\(AgentConfig.presets.count) 个")
        for agent in AgentConfig.presets {
            NSLog("[Lumen][agent]   \(agent.name)｜技能=\(agent.skills.map(\.title).joined(separator: "/"))"
                + "｜联网=\(agent.usesWebSearch)｜id=\(agent.id.prefix(8))…")
        }

        // 预设 id 必须稳定：写死字面量，否则「配置里没有 agents 时退回预设」这条路径
        // 每次都得到新 id，用户选中的 Agent 会静默丢失。
        let firstRun = AgentConfig.presets.map(\.id)
        let secondRun = AgentConfig.presets.map(\.id)
        check("预设 id 稳定（可被配置引用）", firstRun == secondRun)

        // 角色 + 技能是否真的进了系统提示，且没有顶掉默认约束
        guard let socratic = AgentConfig.presets.first(where: { $0.name == "苏格拉底导师" }) else {
            check("找得到苏格拉底预设", false)
            return
        }
        let system = PromptLibrary.systemPrompt(readerPersona: "自检读者背景", agent: socratic)
        check("系统提示里含角色设定", system.contains("善于提问的导师"))
        check("系统提示里含苏格拉底技能", system.contains("不要直接给出结论"))
        check("默认的防幻觉约束仍在", system.contains("原文没有提到"))
        check("读者背景仍在", system.contains("自检读者背景"))

        let withoutAgent = PromptLibrary.systemPrompt(readerPersona: "")
        check("不选 Agent 时不出现角色段落", !withoutAgent.contains("角色设定"))

        // 联网检索：真跑一次，把结果和失败原因都打出来
        let query = "cultural capital education inequality"
        NSLog("[Lumen][agent] 联网检索测试：query = 「\(query)」")
        let started = Date()
        let outcome = await WebLiteratureSearch.search(query: query)
        let elapsed = Int(Date().timeIntervalSince(started) * 1000)
        NSLog("[Lumen][agent] 耗时 \(elapsed)ms，命中 \(outcome.hits.count) 条，失败 \(outcome.failures.count) 个源")
        for failure in outcome.failures {
            NSLog("[Lumen][agent]   源失败：\(failure)")
        }
        for hit in outcome.hits.prefix(5) {
            NSLog("[Lumen][agent]   [\(hit.source)] \(hit.title.prefix(60))"
                + " — \(hit.authors.prefix(30)) \(hit.year) \(hit.identifier)")
        }

        let block = WebLiteratureSearch.promptBlock(outcome)
        check("检索结果能渲染成提示词段落", !outcome.hits.isEmpty && block.contains("联网检索到的文献"),
              "命中 \(outcome.hits.count) 条")

        // 只看「有结果」还不够：三个源里挂两个、只剩一个在撑，从终值上分辨不出来。
        // 把出结果的源列出来，才看得出覆盖面。
        let sources = Set(outcome.hits.map(\.source)).sorted()
        NSLog("[Lumen][agent] 出结果的源：\(sources.isEmpty ? "无" : sources.joined(separator: "、"))")
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

        NSLog("[Lumen][agent] 自检：通过 \(passed) 项，失败 \(failures.count) 项"
            + (failures.isEmpty ? " ✅" : " ❌ " + failures.joined(separator: "；")))
    }
}
