import Foundation

// MARK: - Agent 技能

/// 一个可开关的「技能」= 一段固定指令。
///
/// 之所以做成枚举而不是让用户自由填写：这些指令是**行为约束**，
/// 写得对不对直接决定输出质量（比如「不直接给结论」这句话必须足够明确才压得住模型的惯性）。
/// 让用户在文本框里从零写，等于把调提示词的活推给他；给成勾选项，才是一句话就能配好的东西。
public enum AgentSkill: String, Codable, CaseIterable, Identifiable, Sendable {
    /// 苏格拉底式：用提问引导，不直接给结论
    case socratic
    /// 论据回原文：每个判断都要锚到原文引文
    case evidence
    /// 概念界定：先讲清关键术语的学理来源
    case concepts
    /// 批判审读：指出论证薄弱处与反例
    case critique
    /// 结构化：先给提纲再展开
    case outline
    /// 大白话：少术语，讲给非本专业的人听
    case plainLanguage
    /// 文献检索：联网找可核查的文献并列出
    case literature

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .socratic:      return "苏格拉底式"
        case .evidence:      return "论据回原文"
        case .concepts:      return "概念界定"
        case .critique:      return "批判审读"
        case .outline:       return "先给提纲"
        case .plainLanguage: return "大白话"
        case .literature:    return "列文献"
        }
    }

    public var detail: String {
        switch self {
        case .socratic:
            return "不直接给结论，用一连串问题把读者逼到自己的判断上"
        case .evidence:
            return "每个判断都锚到原文，能引就引，引不到就明说"
        case .concepts:
            return "先界定关键概念的学理来源与用法差异"
        case .critique:
            return "站在审稿人立场，指出论证薄弱处与可能的反例"
        case .outline:
            return "先给结构化提纲，再逐条展开"
        case .plainLanguage:
            return "用日常语言解释，少用术语"
        case .literature:
            return "联网检索相关文献并列出可核查的来源"
        }
    }

    public var systemImage: String {
        switch self {
        case .socratic:      return "questionmark.bubble"
        case .evidence:      return "text.quote"
        case .concepts:      return "character.book.closed"
        case .critique:      return "exclamationmark.magnifyingglass"
        case .outline:       return "list.bullet.indent"
        case .plainLanguage: return "text.bubble"
        case .literature:    return "books.vertical"
        }
    }

    /// 写进系统提示的那句话。
    ///
    /// 明确写成「怎么做」而不是「做什么」：模型对祈使句的遵循度明显更高，
    /// 而「你是苏格拉底式导师」这种身份描述经常被它当成修辞、不做行为改变。
    public var instruction: String {
        switch self {
        case .socratic:
            return "- 不要直接给出结论。用 2–4 个递进的问题引导读者自己推出来；每个问题后面可以点明这个问题关键在哪。"
        case .evidence:
            return "- 每个判断都要落到原文：能引原文就引（短引，用「」括起），并说明它在这一页的哪个位置；原文里找不到依据的判断，明说「这是我的推断，原文未直接支持」。"
        case .concepts:
            return "- 先界定关键概念的学理来源：它出自谁、在什么脉络里被提出、与近义概念的区别在哪。界定之后再展开论述。"
        case .critique:
            return "- 站在审稿人的立场：指出这段论述的薄弱处、未处理的反例、以及作者可能默认了但没论证的前提。措辞要对事不对人。"
        case .outline:
            return "- 先给一个结构化提纲（分点、带层级），再按提纲逐条展开。"
        case .plainLanguage:
            return "- 用日常语言解释，别堆术语；必须用到专业词时，用一句大白话补一句它的意思。"
        case .literature:
            return "- 涉及研究现状、理论出处、实证结论时，结合下面提供的联网检索结果，列出可核查的文献（作者 + 年份 + 标题 + 来源），并说明它与本书论点的关系；检索结果里没有的，不要凭印象补。"
        }
    }
}

// MARK: - Agent 配置

/// 一个 Agent = 角色设定 + 一组技能 + 是否联网检索。
///
/// 与「提示词模板」的分工：模板换的是**读法**（整段替换系统提示），
/// Agent 补的是**身份与工具**（追加在默认约束之后）。
/// 两者可以同时用：模板决定立场，Agent 决定谁来读、带着什么装备读。
public struct AgentConfig: Codable, Identifiable, Sendable, Equatable {
    public var id: String
    public var name: String
    /// 角色设定（自由文本）。留空表示不加角色。
    public var persona: String
    public var skills: [AgentSkill]
    /// 是否在提问前联网检索文献
    public var usesWebSearch: Bool
    public var isBuiltIn: Bool

    public init(
        id: String = UUID().uuidString,
        name: String,
        persona: String = "",
        skills: [AgentSkill] = [],
        usesWebSearch: Bool = false,
        isBuiltIn: Bool = false
    ) {
        self.id = id
        self.name = name
        self.persona = persona
        self.skills = skills
        self.usesWebSearch = usesWebSearch
        self.isBuiltIn = isBuiltIn
    }

    /// 拼进系统提示的段落。返回空串表示这个 Agent 不改变系统提示。
    public var promptSection: String {
        var lines: [String] = []
        let trimmedPersona = persona.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedPersona.isEmpty {
            lines.append("本次阅读的角色设定：")
            lines.append(trimmedPersona)
        }
        let activeSkills = skills.filter { $0 != .literature || usesWebSearch }
        if !activeSkills.isEmpty {
            lines.append("")
            lines.append("在遵守上面所有基本约束的前提下，另外执行以下要求：")
            lines.append(contentsOf: activeSkills.map(\.instruction))
        }
        return lines.joined(separator: "\n")
    }

    /// 预设 Agent。
    ///
    /// **id 必须是写死的字面量**，不能用 `UUID()`：计算属性每次求值都会得到新 id，
    /// 于是「设置里没有 agents 时退回预设」这条路径每轮 id 都不同，用户选中的
    /// Agent 会在下一次求值时静默丢失。（模板系统踩过同一个坑。）
    public static let presets: [AgentConfig] = [
        AgentConfig(
            id: "8F5E1C42-4A2B-4C7E-9D31-5A6F0B2C7D10",
            name: "苏格拉底导师",
            persona: "你是一位善于提问的导师，面对的是正在读教育学与社会科学文献的研究者。你的目标不是替他把这段话读懂，而是让他在回答你的问题之后，自己读懂了。",
            skills: [.socratic, .concepts],
            usesWebSearch: false,
            isBuiltIn: true
        ),
        AgentConfig(
            id: "1B7A93D0-6E4C-4F82-8A15-9C3D2E4F5A61",
            name: "教育学研究者",
            persona: "你与读者同属教育学研究共同体，熟悉质性研究、教育社会学与教育政策的常用理论框架。用同行的口吻讨论，不必解释领域常识。",
            skills: [.evidence, .concepts, .outline],
            usesWebSearch: false,
            isBuiltIn: true
        ),
        AgentConfig(
            id: "3C9D5F71-2B8E-4A63-9F07-1E5A8C4B6D22",
            name: "批判审稿人",
            persona: "你是期刊匿名审稿人，任务是判断这篇文字够不够发表。严格但公正，指出问题时给出具体位置，不空泛地说「论证不足」。",
            skills: [.critique, .evidence],
            usesWebSearch: false,
            isBuiltIn: true
        ),
        AgentConfig(
            id: "6E2B4A85-9C17-4D3F-A8B0-7F1C3E5D9A33",
            name: "文献综述助手",
            persona: "你帮读者把手上这本书放回研究传统里：它接的是哪条脉络，与哪些研究对话，又留下了什么没解决。",
            skills: [.literature, .concepts, .evidence],
            usesWebSearch: true,
            isBuiltIn: true
        )
    ]
}
