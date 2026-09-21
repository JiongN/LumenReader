import Foundation

// MARK: - Agent 技能

/// 一条可复用的「技能」= 一段独立的行为要求 + 一个只用于辨认的名字。
///
/// 技能存在一个**全局技能库**里（`AISettings.skillLibrary`），Agent 只记自己勾了哪些 id。
/// 为什么不做成每个 Agent 各存一份：技能是**读法**，不是某个角色的私产——
/// 「论据回原文」这条规矩这次用在这个角色上，下次也想勾到另一个角色上；
/// 各存一份的话，用户在 A 里调好的技能切到 B 就没了，只能重写一遍。
///
/// 代价如实写下：改一条技能的要求，**用它的所有 Agent 一起变**。
/// 这本来就是「样式」该有的语义（改一处、处处生效），代价是不能给某个 Agent 留特例。
public struct AgentSkill: Codable, Identifiable, Sendable, Equatable {
    /// 稳定标识。
    ///
    /// 内置技能的 id 沿用旧版枚举的 rawValue（`"socratic"` 等）——**老配置里
    /// `skills` 存的就是这些字符串**，改 id 等于让老用户的技能静默消失。
    public var id: String
    public var name: String
    public var instruction: String

    public init(id: String = UUID().uuidString, name: String, instruction: String) {
        self.id = id
        self.name = name
        self.instruction = instruction
    }
}

public extension AgentSkill {

    /// 「列文献」的稳定 id。
    ///
    /// 它是否真的发给模型取决于有没有开联网检索（没开的时候空谈「结合检索结果」
    /// 只会让模型自己编）。判定必须按 id 而不是名字：用户改个名字不该改变这个行为。
    static let literatureID = "literature"

    /// 内置技能。首次启动灌进技能库，也是「恢复内置技能」的来源。
    ///
    /// 用户改的是技能库里那一份（改完所有 Agent 一起变），这里的内置条目只用来
    /// **灌初始值**和**按 id 恢复**，不参与「用户改了哪条」的判断。
    static let catalog: [AgentSkill] = [
        AgentSkill(
            id: "socratic",
            name: "苏格拉底式",
            instruction: "不要直接给出结论。用 2–4 个递进的问题引导读者自己推出来；每个问题后面可以点明这个问题关键在哪。"
        ),
        AgentSkill(
            id: "evidence",
            name: "论据回原文",
            instruction: "每个判断都要落到原文：能引原文就引（短引，用「」括起），并说明它在这一页的哪个位置；原文里找不到依据的判断，明说「这是我的推断，原文未直接支持」。"
        ),
        AgentSkill(
            id: "concepts",
            name: "概念界定",
            instruction: "先界定关键概念的学理来源：它出自谁、在什么脉络里被提出、与近义概念的区别在哪。界定之后再展开论述。"
        ),
        AgentSkill(
            id: "critique",
            name: "批判审读",
            instruction: "站在审稿人的立场：指出这段论述的薄弱处、未处理的反例、以及作者可能默认了但没论证的前提。措辞要对事不对人。"
        ),
        AgentSkill(
            id: "outline",
            name: "先给提纲",
            instruction: "先给一个结构化提纲（分点、带层级），再按提纲逐条展开。"
        ),
        AgentSkill(
            id: "plainLanguage",
            name: "大白话",
            instruction: "用日常语言解释，别堆术语；必须用到专业词时，用一句大白话补一句它的意思。"
        ),
        AgentSkill(
            id: "literature",
            name: "列文献",
            instruction: "涉及研究现状、理论出处、实证结论时，结合下面提供的联网检索结果，列出可核查的文献（作者 + 年份 + 标题 + 来源），并说明它与本书论点的关系；检索结果里没有的，不要凭印象补。"
        ),
        AgentSkill(
            id: "argumentChain",
            name: "论证链",
            instruction: "把核心论证写成“前提 → 推理 → 结论”，逐项指出原文依据；缺失的环节明确标为隐含前提。"
        ),
        AgentSkill(
            id: "termShift",
            name: "术语变化",
            instruction: "同一术语在文中含义发生变化时，分别说明各处用法，不用一个定义强行统一。"
        ),
        AgentSkill(
            id: "cognitiveCheck",
            name: "认知检查",
            instruction: "每轮最后指出读者当前最可能混淆的两个概念，并给出一个可回到原文验证的问题。"
        ),
        AgentSkill(
            id: "researchDesign",
            name: "研究设计",
            instruction: "遇到经验研究时，明确区分研究问题、材料、方法、发现与解释，不把作者的解释写成数据本身。"
        ),
        AgentSkill(
            id: "contextMapping",
            name: "脉络定位",
            instruction: "把文献分成继承、竞争、补充三类关系；没有检索证据时不猜测作者之间的影响关系。"
        ),
        AgentSkill(
            id: "writableParagraph",
            name: "可写段落",
            instruction: "先给一句可作为段落主题句的判断，再给证据与限定条件；不要虚构页码和参考文献。"
        ),
        AgentSkill(
            id: "counterArgument",
            name: "反方检验",
            instruction: "为核心判断补一个最强反对意见，并说明现有材料能否回应。"
        )
    ]

    /// 按 id 在内置技能里找一条。找不到返回 nil（旧配置里可能存着已下线的技能）。
    static func catalogEntry(id: String) -> AgentSkill? {
        catalog.first { $0.id == id }
    }
}

// MARK: - 旧版「自定义技能」

/// 只用于**读旧文件**的形状。
///
/// 2026-09-21 之前，技能分成「内置枚举勾选」与「自定义技能」两块，后者单独存在
/// `AgentConfig.customSkills` 里。两者合并成全局技能库之后这个字段不再产出，
/// 但**老配置里还有**，所以留一个只解码的结构把它读出来、并进技能库。
/// 不删的原因：删了就等于把用户自己攒的技能在升级那一刻丢掉。
private struct LegacyCustomSkill: Codable {
    var id: String?
    var name: String?
    var instruction: String?
}

// MARK: - Agent 配置

/// 一个 Agent = 角色设定 + 勾选的技能 + 是否联网检索 + 参数覆盖。
///
/// 与「提示词模板」的分工：模板换的是**读法**（整段替换系统提示），
/// Agent 补的是**身份与工具**（追加在默认约束之后）。
/// 两者可以同时用：模板决定立场，Agent 决定谁来读、带着什么装备读。
public struct AgentConfig: Codable, Identifiable, Sendable, Equatable {
    public var id: String
    public var name: String
    /// 角色设定（自由文本）。留空表示不加角色。
    public var persona: String
    /// 勾选的技能 id，指向全局技能库（`AISettings.skillLibrary`）。
    ///
    /// 存 id 而不是技能定义：技能库改了要求，用它的 Agent 才会跟着变。
    /// 磁盘上的键**仍叫 `skills`**——老配置里就是这个键（先是枚举 rawValue 的字符串数组，
    /// 中间一度是带全文的对象数组），沿用键名让绝大多数老配置原样读得出来。
    public var skills: [String]
    /// 是否在提问前联网检索文献
    public var usesWebSearch: Bool
    public var isBuiltIn: Bool
    /// 温度覆盖。`nil` = 跟随服务商设置（默认）。
    ///
    /// 只影响**对话请求**（AI 面板里的提问 / 解释 / 翻译 / 总结），
    /// 不影响智能目录这类内部请求——后者要的是稳定的 JSON，不该被 Agent 的
    /// 创造性设置带偏。这一点在编辑器里也写明了。
    public var temperatureOverride: Double?

    /// 迁移专用载体：解码时把旧格式里**带着全文**的技能定义捎出来，
    /// 交给 `AISettings` 并进技能库。
    ///
    /// 不参与编码（`CodingKeys` 里没有它，所以不会被写回磁盘）。
    /// 存在的理由：旧格式的技能全文只存在于 Agent 上，技能库里没有对应条目，
    /// 不捎出来就只能丢——而这是**静默**的，用户自己写的技能无声无息就没了。
    var carriedSkills: [AgentSkill] = []

    /// 温度的允许区间。滑杆与解码都按它钳制。
    public static let temperatureRange: ClosedRange<Double> = 0...2

    /// 显式列出参与编解码的键。
    ///
    /// 必须显式写：`carriedSkills` 是迁移载体，不能跟着被写回磁盘，
    /// 而合成的 `CodingKeys` 会把所有存储属性都包进来。
    enum CodingKeys: String, CodingKey {
        case id, name, persona, skills, usesWebSearch, isBuiltIn, temperatureOverride
    }

    public init(
        id: String = UUID().uuidString,
        name: String,
        persona: String = "",
        skills: [String] = [],
        usesWebSearch: Bool = false,
        isBuiltIn: Bool = false,
        temperatureOverride: Double? = nil
    ) {
        self.id = id
        self.name = name
        self.persona = persona
        self.skills = skills
        self.usesWebSearch = usesWebSearch
        self.isBuiltIn = isBuiltIn
        self.temperatureOverride = temperatureOverride
    }

    /// 旧文件里那个已经不再产出的字段名。单独列一份键，免得污染 `CodingKeys`
    /// （放进 `CodingKeys` 的话，合成的 `encode` 会去找一个不存在的属性而编不过）。
    private enum LegacyKeys: String, CodingKey {
        case customSkills
    }

    /// 容错解码。理由同其余设置结构：**旧配置里没有 `temperatureOverride` 这个键**，
    /// 缺一个键就让整份设置解码失败的话，用户所有的 Agent 会被静默重置成预设
    /// ——他自己建的那几个就白建了。
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = (try? container.decode(String.self, forKey: .id)) ?? UUID().uuidString
        self.name = (try? container.decode(String.self, forKey: .name)) ?? "未命名 Agent"
        self.persona = (try? container.decode(String.self, forKey: .persona)) ?? ""

        // 技能有三条来路，逐条试：
        //   ① 现在：[ "socratic", "3F2A…" ] —— 技能库里的 id
        //   ② 2026-09-21 一度用过：[ {id,name,instruction} ] —— 带全文
        //   ③ 更早：`skills` 是枚举 rawValue，另有 `customSkills` 一块
        // ②③ 里带全文的定义要捎给 `AISettings` 并进技能库：只认 ① 的话，
        // 用户自己写的技能会在升级那一刻静默消失（系统提示变短，界面看不出来）。
        var ids: [String] = []
        var carried: [AgentSkill] = []
        if let rawIDs = try? container.decode([String].self, forKey: .skills) {
            ids = rawIDs
        } else if let definitions = try? container.decode([AgentSkill].self, forKey: .skills) {
            ids = definitions.map(\.id)
            carried = definitions
        }
        if let legacyContainer = try? decoder.container(keyedBy: LegacyKeys.self),
           let legacy = try? legacyContainer.decode([LegacyCustomSkill].self, forKey: .customSkills) {
            let migrated = legacy.map {
                AgentSkill(id: $0.id ?? UUID().uuidString,
                           name: $0.name ?? "",
                           instruction: $0.instruction ?? "")
            }
            // 认不出的条目也留着：名字与要求都在，并进技能库就是一条可用的技能。
            ids.append(contentsOf: migrated.map(\.id))
            carried.append(contentsOf: migrated)
        }
        // 去重但保序（旧配置里同一个技能被写两遍不会造成两张勾选）
        var seen = Set<String>()
        self.skills = ids.filter { seen.insert($0).inserted }
        self.carriedSkills = carried

        self.usesWebSearch = (try? container.decode(Bool.self, forKey: .usesWebSearch)) ?? false
        self.isBuiltIn = (try? container.decode(Bool.self, forKey: .isBuiltIn)) ?? false
        // 缺失与显式 null 都落到 nil（= 跟随服务商设置）
        let rawTemperature = try? container.decode(Double.self, forKey: .temperatureOverride)
        self.temperatureOverride = rawTemperature.map {
            min(max($0, Self.temperatureRange.lowerBound), Self.temperatureRange.upperBound)
        }
    }

    // MARK: 技能解析

    /// 把勾选的 id 解析成技能定义。
    ///
    /// 库里有不认识的 id 就直接跳过，而不是整段不渲染：技能被删掉之后
    /// 指向它的 Agent 不该连其余技能一起失效。
    public func resolvedSkills(in library: [AgentSkill]) -> [AgentSkill] {
        skills.compactMap { id in library.first { $0.id == id } }
    }

    /// 拼进系统提示的段落。返回空串表示这个 Agent 不改变系统提示。
    ///
    /// 必须传技能库：技能在 Agent 上只是 id，光看 Agent 拼不出要求。
    public func promptSection(in library: [AgentSkill]) -> String {
        var lines: [String] = []
        let trimmedPersona = persona.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedPersona.isEmpty {
            lines.append("本次阅读的角色设定：")
            lines.append(trimmedPersona)
        }

        // 「列文献」按 id 判定，不看名字（见 `AgentSkill.literatureID`）。
        let activeSkills = resolvedSkills(in: library)
            .filter { $0.id != AgentSkill.literatureID || usesWebSearch }
        let skillLines = activeSkills.compactMap { skill -> String? in
            let instruction = skill.instruction.trimmingCharacters(in: .whitespacesAndNewlines)
            // 刚点「新建技能」还没写的空条目不发出去——发一条空白要求只会让模型困惑。
            guard !instruction.isEmpty else { return nil }
            let name = skill.name.trimmingCharacters(in: .whitespacesAndNewlines)
            // 统一渲染成「- 【名称】要求」：内置与自建走同一条规则，
            // 界面上就不必为两者维护两套约定。
            return name.isEmpty ? "- \(instruction)" : "- 【\(name)】\(instruction)"
        }
        if !skillLines.isEmpty {
            lines.append("")
            lines.append("在遵守上面所有基本约束的前提下，另外执行以下要求：")
            lines.append(contentsOf: skillLines)
        }
        return lines.joined(separator: "\n")
    }

    /// 是否真的带了内容（用于界面上「留空即等同不用 Agent」的说明）。
    public var isEmpty: Bool {
        persona.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && skills.isEmpty
            && temperatureOverride == nil
    }

    // MARK: 预设

    /// 已从产品里下线的内置预设 id。
    ///
    /// 只在代码里登记，不写进配置：删掉一个预设时，**用户磁盘上那份副本不会自己消失**
    /// ——不清理的话，「已经下线的功能」会以旧数据的形态继续活在编辑器里。
    /// `AISettings.init(from:)` 读盘时按这份名单清理。
    ///
    /// 注意与「用户自己删的预设」区分：那一类靠「不再按 id 补回缺失预设」来处理，
    /// 不需要在这里登记。这里只放**产品层面移除**的项。
    /// 清理按 id 进行，用户对它的改动也一并清掉——这一项本身就是被移除的功能。
    public static let retiredPresetIDs: Set<String> = [
        // 批判审稿人（2026-09-21 移除，编辑器里不再提供）
        "3C9D5F71-2B8E-4A63-9F07-1E5A8C4B6D22"
    ]

    /// 预设 Agent。
    ///
    /// **id 必须是写死的字面量**，不能用 `UUID()`：计算属性每次求值都会得到新 id，
    /// 于是「设置里没有 agents 时退回预设」这条路径每轮 id 都不同，用户选中的
    /// Agent 会在下一次求值时静默丢失。（模板系统踩过同一个坑。）
    ///
    /// 技能只写 id（内置技能里的那几条）。写错一个 id 的后果是那条技能静默不生效，
    /// 所以 `--agent-report` 里有一条「预设引用的技能都在内置技能里」的断言盯着它。
    public static let presets: [AgentConfig] = [
        AgentConfig(
            id: "8F5E1C42-4A2B-4C7E-9D31-5A6F0B2C7D10",
            name: "苏格拉底导师",
            persona: "你是一位善于提问的导师，面对的是正在读教育学与社会科学文献的研究者。你的目标不是替他把这段话读懂，而是让他在回答你的问题之后，自己读懂了。",
            skills: ["socratic", "concepts", "cognitiveCheck"],
            usesWebSearch: false,
            isBuiltIn: true
        ),
        AgentConfig(
            id: "1B7A93D0-6E4C-4F82-8A15-9C3D2E4F5A61",
            name: "教育学研究者",
            persona: "你与读者同属教育学研究共同体，熟悉质性研究、教育社会学与教育政策的常用理论框架。用同行的口吻讨论，不必解释领域常识。",
            skills: ["evidence", "concepts", "outline", "researchDesign"],
            usesWebSearch: false,
            isBuiltIn: true
        ),
        AgentConfig(
            id: "6E2B4A85-9C17-4D3F-A8B0-7F1C3E5D9A33",
            name: "文献综述助手",
            persona: "你帮读者把手上这本书放回研究传统里：它接的是哪条脉络，与哪些研究对话，又留下了什么没解决。",
            skills: ["literature", "concepts", "evidence", "contextMapping"],
            usesWebSearch: true,
            isBuiltIn: true
        ),
        AgentConfig(
            id: "A47C291E-53A8-4B89-9D24-67E1C3F50944",
            name: "理论精读助手",
            persona: "你是一位做概念史与理论分析的研究者。你关心作者如何界定概念、概念之间如何推演，以及论证在哪些句子发生转折。",
            skills: ["concepts", "evidence", "outline", "critique", "argumentChain", "termShift"],
            usesWebSearch: false,
            isBuiltIn: true
        ),
        AgentConfig(
            id: "D08F63B2-7C41-46E5-A190-2E4B6A8C1155",
            name: "研究写作编辑",
            persona: "你是一位社会科学论文编辑，帮助研究者把阅读所得转化为可写入论文的论点，同时严格区分原作者观点、读者推论与可核查事实。",
            skills: ["evidence", "critique", "outline", "plainLanguage", "writableParagraph", "counterArgument"],
            usesWebSearch: false,
            isBuiltIn: true
        )
    ]
}
