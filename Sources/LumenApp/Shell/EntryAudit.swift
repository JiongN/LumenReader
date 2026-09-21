import Foundation
import LumenKit

/// 入口归属自检：`--entry-report 1`。
///
/// 为什么要单开一条：本轮问题的根因是「**同一个人工动作被分别写进多个菜单**」——
/// 这类错误读代码发现不了（三处各自都像是对的），而菜单又没法自动化点击核对
/// （这台机器没有辅助功能权限，也拍不到原生菜单）。所以把「谁归属哪个入口组」
/// 抽成纯数据 `ActionEntries`，在这里做断言。
///
/// 这是**可证伪**的：把「导出摘要」重新塞回 AI 面板 ⋯ 菜单、或把复制项挪进导出菜单，
/// 对应的断言立刻红，而不是靠读代码相信菜单是对的。视图侧（TabBar 的复制菜单、
/// AIPanelView 的 ⋯ 菜单、LumenCommands 的文件 > 导出）都从同一份 `ActionEntries`
/// 长出条目，因此这里断言的性质就是那三个菜单的性质。
@MainActor
enum EntryAudit {

    static func run() {
        guard LaunchOptions.entryReport else { return }

        var passed = 0
        var failures: [String] = []
        func check(_ name: String, _ ok: Bool, _ detail: String = "") {
            if ok { passed += 1 } else { failures.append(name) }
            // 走 `%@`：文案里可能有 `%`（与 ThemeAudit 同理），不能把拼好的串当格式串。
            NSLog("%@", "[Lumen][entry] \(ok ? "✅" : "❌") \(name)"
                  + (ok || detail.isEmpty ? "" : " —— \(detail)"))
        }

        func describe(_ groups: Set<ActionEntryGroup>) -> String {
            "{" + groups.map(\.rawValue).sorted().joined(separator: ", ") + "}"
        }

        // ── 总览（读数，不是断言）─────────────────────────────────────────
        for group in ActionEntryGroup.allCases {
            let titles = ActionEntries.entries(in: group).map { "\($0.id.rawValue)「\($0.title)」" }
            // 显式占位符：格式串与参数分开。标题文案里将来若含 `%`，直接当格式串会被
            // printf 解释掉、整行被拦腰截断（见 check() 与汇总行的同类处理）。
            NSLog("[Lumen][entry] %@（%d 项）：%@",
                  group.rawValue, titles.count, titles.joined(separator: " / "))
        }
        NSLog("[Lumen][entry] 注：commandPalette 是全局索引层，列出所有动作，"
              + "**不计入**「重复入口」判定；下列实体入口断言均已排除它。")

        // 1. 每个 id 恰好出现一次：重复 id = 同一动作被写进两处，这正是要抓的病。
        var seen = Set<ActionEntryID>()
        var duplicates: [String] = []
        for entry in ActionEntries.all where !seen.insert(entry.id).inserted {
            duplicates.append(entry.id.rawValue)
        }
        check("每个动作 id 唯一（无重复条目）", duplicates.isEmpty,
              "重复：\(duplicates.joined(separator: ", "))")

        // 2. 导出类只归「文件 > 导出」。（出现在 copy / aiPanel 即失败）
        let exportGroups = ActionEntries.physicalGroups(of: .export)
        check("导出类动作只归属 {fileExport}", exportGroups == [.fileExport],
              "得到 \(describe(exportGroups))，期望 {fileExport}")

        // 3. 复制类只归顶栏「复制」菜单。
        let copyGroups = ActionEntries.physicalGroups(of: .copy)
        check("复制类动作只归属 {copy}", copyGroups == [.copy],
              "得到 \(describe(copyGroups))，期望 {copy}")

        // 3.5. 会话管理类（新建 / 重命名 / 删除）只归头部「会话」菜单。
        //
        // 这条断言本轮真的抓到过东西：第一版把这三项注册进 `.aiPanel`，于是它们在
        // 头部会话菜单和 ⋯ 菜单里各出现一次、两处都能改同一个状态——而把期望写成
        // 「{aiPanel}」时断言依然是绿的，因为它只查「类别归属的组集合」，查不出
        // 「同一动作被两个菜单各自渲染了一遍」。所以这里：精确相等 + 明写 ⋯ 菜单不含会话项。
        let conversationGroups = ActionEntries.physicalGroups(of: .conversation)
        check("会话管理类动作只归属 {headerSessionMenu}",
              conversationGroups == [.headerSessionMenu],
              "得到 \(describe(conversationGroups))，期望 {headerSessionMenu}")

        let conversationInAIPanel = ActionEntries.entries(in: .aiPanel).filter { $0.category == .conversation }
        check("⋯ 菜单不含任何会话管理项（避免与头部会话菜单重复入口）",
              conversationInAIPanel.isEmpty,
              "得到 \(conversationInAIPanel.map(\.id.rawValue))")

        // 4. 总结类只在 AI 面板 / 引导卡 / 命令面板里出现。
        let summarizeGroups = ActionEntries.groups(of: .summarize)
        let allowedSummarize: Set<ActionEntryGroup> = [.aiPanel, .aiPanelGuide, .commandPalette]
        check("总结类动作归属 ⊆ {aiPanel, aiPanelGuide, commandPalette}",
              summarizeGroups.isSubset(of: allowedSummarize),
              "得到 \(describe(summarizeGroups))，允许 \(describe(allowedSummarize))")

        // 5. AI 面板 ⋯ 菜单里不得出现任何导出项。
        let exportInAIPanel = ActionEntries.entries(in: .aiPanel).filter { $0.category == .export }
        check("AI 面板 ⋯ 菜单不含任何导出项", exportInAIPanel.isEmpty,
              "得到 \(exportInAIPanel.map(\.id.rawValue))")

        // 6. 「文件 > 导出」恰好两项，且就是摘要 + 对话记录（防止再多长出第三项）。
        let exportIDs = ActionEntries.entries(in: .fileExport).map(\.id)
        check("「文件 > 导出」恰好两项：摘要 + 对话记录",
              exportIDs == [.exportSummary, .exportTranscript],
              "得到 \(exportIDs.map(\.rawValue))，期望 [exportSummary, exportTranscript]")

        // 7. 导出菜单的条目**结构上**由 planner 生成（LumenCommands 里是
        //    `ForEach(ActionEntries.entries(in: .fileExport))`），所以渲染条目数恒等于
        //    planner 条目数。这里把它算出来——**这条只是结构性护栏，不是证伪项**：
        //    若有人绕过 planner 把导出项硬编码进菜单，本断言不会红。真正的证伪在于
        //    第 2/5/6 条类别归属断言。日志行里也写明这一点，避免把 8/0 误读成
        //    「重复入口不存在」的证明。
        check("导出菜单条目数 = \(exportIDs.count)（结构性护栏，非证伪项——真正抓重复的是上面的类别归属断言）",
              exportIDs.count == 2)

        // 8. planner 里登记为导出的可改绑动作，恰好覆盖两个导出 LumenAction
        //    （若将来新增导出动作却忘了登记，这里会红）。
        let plannedExportActions = Set(ActionEntries.entries(category: .export).compactMap { $0.action })
        let knownExportActions: Set<LumenAction> = [.exportSummary, .exportTranscript]
        check("planner 的导出条目覆盖全部导出动作（exportSummary / exportTranscript）",
              plannedExportActions == knownExportActions,
              "得到 \(plannedExportActions.map(\.rawValue).sorted())")

        // 9. 空状态引导卡：恰好 4 项，构成与文案固定（改了文案立刻红）。
        let guideTitles = ActionEntries.entries(in: .aiPanelGuide).map(\.title)
        check("空状态引导卡恰好 4 项，文案与顺序固定",
              guideTitles == ["解释选中内容", "翻译选中内容", "总结当前页/章", "总结全文"],
              "得到 \(guideTitles)，期望 [解释选中内容, 翻译选中内容, 总结当前页/章, 总结全文]")

        // 10. 无幽灵组：每个入口组都至少被一条条目认领——防止将来新增一个组却没人渲染它。
        let emptyGroups = ActionEntryGroup.allCases.filter { ActionEntries.entries(in: $0).isEmpty }
        check("每个入口组都至少有一条条目（无空组）",
              emptyGroups.isEmpty,
              "空组：\(emptyGroups.map(\.rawValue))")

        NSLog("%@", "[Lumen][entry] 自检：通过 \(passed) 项，失败 \(failures.count) 项"
              + (failures.isEmpty ? " ✅" : " ❌ " + failures.joined(separator: "；")))
    }
}
