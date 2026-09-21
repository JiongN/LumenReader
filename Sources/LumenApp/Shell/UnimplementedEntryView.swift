import SwiftUI

/// planner 里登记了、但当前视图还没写翻译分支的入口的**兜底显示**。
///
/// 为什么不能是 `default: EmptyView()`：那会让「往 planner 的某个组新增一条、却忘了在
/// 菜单的 switch 里补 case」变成**静默少渲染一项**——不报错、不崩溃、自检也不会红，
/// 正是本轮要消灭的那类缺陷。这里把「漏补 case」顶到开发眼前：
/// DEBUG 下 `assertionFailure` 直接断言中断，Release 下渲染一条肉眼可见的红字。
struct UnimplementedEntryView: View {

    let entry: ActionEntry

    var body: some View {
        // `let _ =` 把断言放进 body：只在**真的走到兜底分支**时触发，
        // 正常路径（每条 planner 条目都有实现）永远不会碰到它。
        let _ = assertionFailure(
            "ActionEntries 新增了未实现的入口：\(entry.id.rawValue)"
                + "（请在菜单的 switch 里补 case）"
        )
        Text("未实现的入口：\(entry.id.rawValue)")
            .font(DS.Typo.caption)
            .foregroundStyle(DS.Palette.danger)
            .disabled(true)
    }
}
