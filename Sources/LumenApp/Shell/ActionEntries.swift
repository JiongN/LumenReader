import Foundation
import LumenKit

/// 用户可见动作**归属哪一个入口组**的单一真相源。
///
/// 为什么需要它：本轮要修的不是「某个菜单少了一项」，而是**同一个动作被分别写进了
/// 多个菜单**——「导出摘要」同时出现在顶栏复制菜单、AI 面板 ⋯ 菜单与菜单栏「文件 > 导出」。
/// 这类重复读代码几乎发现不了：三处各自都「看起来是对的」，只有把三处摊在一起，
/// 才会发现同一个动作出现了三次。所以把「谁属于哪儿」抽成一份**纯数据**，
/// 让三个菜单都**从这份数据长出条目**（顺序、文案、分隔线归属都取自这里），
/// 再用 `--entry-report` 断言这份数据的性质。
///
/// 与 `PDFContextMenuPlanner.items`（OCR 右键菜单）同构：判定是纯函数 / 纯数据，
/// 视图只负责把判定翻译成控件。区别是多了一列「归属」，因为要抓的正是
/// 「一个动作归了几个入口」——这份数据若被改坏（导出项溜回 ⋯ 菜单、复制项溜进导出），
/// `EntryAudit` 立刻红。
///
/// **范围说明**：这里只登记「AI 相关入口职责边界」涉及的那几个入口（顶栏复制菜单、
/// 文件 > 导出、AI 面板 ⋯ 菜单、AI 面板空状态引导卡）与命令面板这一全局索引层。
/// 系统惯例位置（编辑菜单的「复制全文」、文件菜单的「复制文件」）不纳入本表——
/// 它们是 macOS 标准落点，不是这次要收敛的重复入口；纳入进来反而会让「复制类只归 copy」
/// 这条断言失去意义。
enum ActionEntries {

    /// 这份数据是整个模块唯一的一份；顺序即各菜单内的排列顺序。
    static let all: [ActionEntry] = [
        // ── 顶栏「复制」菜单：只放去向为**剪贴板**的动作 ──
        ActionEntry(.copyFullText, group: .copy, category: .copy,
                    title: "复制全文为纯文本", action: .copyFullText),
        ActionEntry(.copyFile, group: .copy, category: .copy,
                    title: "复制文件", action: .copyFile),

        // ── 菜单栏「文件 > 导出」：去向为**磁盘文件**的动作，唯一入口 ──
        ActionEntry(.exportSummary, group: .fileExport, category: .export,
                    title: LumenAction.exportSummary.title, action: .exportSummary),
        ActionEntry(.exportTranscript, group: .fileExport, category: .export,
                    title: "导出对话记录为 Markdown…", action: .exportTranscript),

        // ── AI 面板 ⋯ 菜单：只放 AI 动作，且**不含任何导出项** ──
        ActionEntry(.summarizeUnit, group: .aiPanel, category: .summarize, title: "总结当前页/章"),
        ActionEntry(.summarizeAll, group: .aiPanel, category: .summarize, title: "总结全文"),
        ActionEntry(.rerunLast, group: .aiPanel, category: .chat,
                    title: "重新生成上一条回答", section: 1),
        ActionEntry(.rememberSelection, group: .aiPanel, category: .memory,
                    title: "记住选中内容", section: 2),
        ActionEntry(.rememberCurrentUnit, group: .aiPanel, category: .memory,
                    title: "记住当前这一节"),
        ActionEntry(.clearChat, group: .aiPanel, category: .chat,
                    title: "清空当前会话", section: 3),
        ActionEntry(.openAISettings, group: .aiPanel, category: .settings,
                    title: "AI 与阅读设置…"),

        // ── AI 面板头部的「会话」菜单：会话管理只归这里，**不重复出现在 ⋯ 菜单** ──
        //
        // 为什么单列一组：本轮第一版把这三项注册进了 `.aiPanel`，于是「新建 / 重命名 /
        // 删除会话」在头部会话菜单与 ⋯ 菜单里各出现一次，两处都能改同一个状态。
        // 这正是本枚举存在的理由——同一个动作被分别写进多个菜单，读代码发现不了；
        // 而且当时 `EntryAudit` 的类别断言还是绿的，因为它只查「类别归属的组集合」，
        // 查不出「同一动作被两个菜单各自渲染了一遍」。
        // 拆成独立组之后：`⋯` 菜单（渲染 `.aiPanel`）不再出现会话管理项；
        // 头部会话菜单的动态行（历史会话）由 `ConversationMenuPlanner` 给出，
        // 但它的三行静态项文案取自本组（`ActionEntries.title(of:)`），视图里不再抄第二份。
        ActionEntry(.newConversation, group: .headerSessionMenu, category: .conversation,
                    title: "新建会话"),
        ActionEntry(.renameConversation, group: .headerSessionMenu, category: .conversation,
                    title: "重命名当前会话…", section: 1),
        ActionEntry(.deleteConversation, group: .headerSessionMenu, category: .conversation,
                    title: "删除当前会话", section: 2),

        // ── AI 面板空状态引导卡：还没有对话时的一次性引导，有对话后自动消失 ──
        ActionEntry(.guideExplain, group: .aiPanelGuide, category: .chat, title: "解释选中内容"),
        ActionEntry(.guideTranslate, group: .aiPanelGuide, category: .chat, title: "翻译选中内容"),
        ActionEntry(.guideSummarizeUnit, group: .aiPanelGuide, category: .summarize, title: "总结当前页/章"),
        ActionEntry(.guideSummarizeAll, group: .aiPanelGuide, category: .summarize, title: "总结全文"),

        // ── 命令面板：全局索引层（列出所有动作），**不计入「重复入口」判定** ──
        ActionEntry(.paletteExplain, group: .commandPalette, category: .chat, title: "解释选中内容"),
        ActionEntry(.paletteTranslate, group: .commandPalette, category: .chat, title: "翻译选中内容"),
        ActionEntry(.paletteSummarizeUnit, group: .commandPalette, category: .summarize, title: "总结当前页/章"),
        ActionEntry(.paletteSummarizeAll, group: .commandPalette, category: .summarize, title: "总结全文"),
        ActionEntry(.paletteRememberSelection, group: .commandPalette, category: .memory, title: "记住选中内容"),
        ActionEntry(.paletteClearChat, group: .commandPalette, category: .chat, title: "清空当前对话"),
        ActionEntry(.paletteExportSummary, group: .commandPalette, category: .export,
                    title: LumenAction.exportSummary.title),
        ActionEntry(.paletteExportTranscript, group: .commandPalette, category: .export,
                    title: "导出对话记录为 Markdown…"),
    ]

    // MARK: - 查询

    /// 某个入口组里的条目，顺序即菜单内顺序。
    static func entries(in group: ActionEntryGroup) -> [ActionEntry] {
        all.filter { $0.group == group }
    }

    /// 取某个条目的菜单文案。
    ///
    /// 存在的理由：头部「会话」菜单的**行**是由 `ConversationMenuPlanner` 决定的（历史会话
    /// 列表是动态的，登记不到本表里），但它的三行静态项（新建 / 重命名 / 删除）文案必须
    /// 和本表一致——否则文案会在两个文件里各存一份、迟早漂移。
    /// 找不到就回落到 id 原样，**不返回空串**：宁可显示一个丑但可诊断的文案，
    /// 也不要让菜单项变成一片空白。
    static func title(of id: ActionEntryID) -> String {
        all.first { $0.id == id }?.title ?? id.rawValue
    }

    /// 某个动作类别的全部条目。
    static func entries(category: ActionCategory) -> [ActionEntry] {
        all.filter { $0.category == category }
    }

    /// 某个类别出现过的**全部**入口组（含命令面板）。
    static func groups(of category: ActionCategory) -> Set<ActionEntryGroup> {
        Set(entries(category: category).map(\.group))
    }

    /// 某个类别出现过的**实体入口**组——排除命令面板这一全局索引层。
    ///
    /// 「导出类只归文件 > 导出」「复制类只归顶栏复制」这两条断言必须看实体入口：
    /// 命令面板本就把所有动作摊平列出，把它算进来会让断言恒假（或被迫放宽到无意义）。
    static func physicalGroups(of category: ActionCategory) -> Set<ActionEntryGroup> {
        groups(of: category).subtracting([.commandPalette])
    }
}

// MARK: - 类型

/// 动作归属的入口组。
enum ActionEntryGroup: String, CaseIterable, Sendable {
    /// 顶栏右侧的「复制」菜单（去向：剪贴板）
    case copy
    /// 菜单栏「文件 > 导出」（去向：磁盘文件）
    case fileExport
    /// AI 面板头部的 ⋯ 菜单（只放 AI 动作）
    case aiPanel
    /// AI 面板头部的「会话」菜单（会话的新建 / 重命名 / 删除只归这里）
    case headerSessionMenu
    /// AI 面板空状态的引导卡（一次性）
    case aiPanelGuide
    /// ⌘K 命令面板——全局索引层，列出所有动作，不算并列入口
    case commandPalette
}

/// 动作的类别。断言用「同类动作只出现在允许的入口组里」。
enum ActionCategory: String, Sendable {
    case copy
    case export
    case summarize
    case chat
    case memory
    case settings
    /// 会话管理（新建 / 重命名 / 删除），只归 AI 面板（见 `EntryAudit` 断言）。
    case conversation
}

/// 条目标识。用穷尽枚举而不是裸字符串，切换菜单项时编译器会带你走完。
enum ActionEntryID: String, CaseIterable, Sendable {
    case copyFullText
    case copyFile
    case exportSummary
    case exportTranscript
    case summarizeUnit
    case summarizeAll
    case rerunLast
    case rememberSelection
    case rememberCurrentUnit
    case clearChat
    case newConversation
    case renameConversation
    case deleteConversation
    case openAISettings
    case guideExplain
    case guideTranslate
    case guideSummarizeUnit
    case guideSummarizeAll
    case paletteExplain
    case paletteTranslate
    case paletteSummarizeUnit
    case paletteSummarizeAll
    case paletteRememberSelection
    case paletteClearChat
    case paletteExportSummary
    case paletteExportTranscript
}

/// 一条菜单项的数据描述。视图据此渲染，不做任何「谁属于哪儿」的判断。
struct ActionEntry: Equatable, Sendable, Identifiable {

    let id: ActionEntryID
    /// 菜单文案。视图直接用它，不再从别处取标题。
    let title: String
    let group: ActionEntryGroup
    let category: ActionCategory
    /// 分节号：相邻两项 section 不同时才画分隔线（首项之前不画）。
    let section: Int
    /// 若这一项来自可改绑动作，记下它——菜单据此取可用性判断与执行入口。
    /// 纯 AI 面板动作（总结 / 清空 / 设置）没有对应的 `LumenAction`，为 nil。
    let action: LumenAction?

    init(
        _ id: ActionEntryID,
        group: ActionEntryGroup,
        category: ActionCategory,
        title: String,
        section: Int = 0,
        action: LumenAction? = nil
    ) {
        self.id = id
        self.group = group
        self.category = category
        self.title = title
        self.section = section
        self.action = action
    }
}
