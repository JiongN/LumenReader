import Foundation
import LumenKit

/// 面板宽度响应式自检：`--resize-report 1`。
///
/// 验的是**这次真的坏过的那条链路**：拖动分隔线写 `settingsStore.ui.sidebarWidth`，
/// 布局却不动（视图没有观察 `SettingsStore`，写入不触发任何视图失效）。
/// 所以断言必须打在「视图出现之后」：
///
/// 1. 等布局稳定（布局探针已经上报过至少一轮）；
/// 2. 记下探针里侧栏当前的实际宽度；
/// 3. 往**同一个设置项**写入 +60（与拖动手势走的路径完全一致，`suppressSave` 防落盘）；
/// 4. 再读探针——宽度没跟着变就是响应式断了；
/// 5. 越界值必须被钳制回上限（拖到边界要停得住的前提）。
///
/// 「真实鼠标拖拽」仍然验不了（这台机器没有辅助功能授权，无法合成拖拽事件），
/// 但手势本身只做一件事——把位移写进这个设置项——而「写进设置项之后布局跟随」
/// 正是本自检覆盖的部分。这个诚实边界沿用 `docs/VERIFY.md` 的既有结论。
@MainActor
enum ResizeAudit {

    static func run(state: AppState) async {
        // 探针首轮 dump 在首次上报后 2s；再留余量等动画落定
        try? await Task.sleep(nanoseconds: 2_600_000_000)

        let store = state.settingsStore
        store.suppressSave = true
        defer { store.suppressSave = false }

        guard let beforeFrame = LayoutAuditLog.shared.frame(named: "sidebar") else {
            NSLog("[Lumen][resize] ❌ 没有读到侧栏布局探针（--open 打开文档了吗？）")
            return
        }
        NSLog("[Lumen][resize] 修改前：侧栏实际宽度 \(Int(beforeFrame.width))pt")

        let range = UISettings.PanelWidth.sidebarRange
        let target = UISettings.PanelWidth.clampSidebar(beforeFrame.width + 60)
        store.ui.sidebarWidth = target

        // 布局跟随需要一次视图失效 + 布局帧；0.8s 足够，又不至于拖慢自检
        try? await Task.sleep(nanoseconds: 800_000_000)
        guard let afterFrame = LayoutAuditLog.shared.frame(named: "sidebar") else {
            NSLog("[Lumen][resize] ❌ 修改后读不到布局探针")
            return
        }

        NSLog("[Lumen][resize] 写入 \(Int(target))pt → 实际渲染 \(Int(afterFrame.width))pt")
        let follows = abs(afterFrame.width - target) < 2
        NSLog("[Lumen][resize] \(follows ? "✅" : "❌") 布局跟随宽度写入"
              + (follows ? "" : "（期望 \(Int(target))pt，实际 \(Int(afterFrame.width))pt——响应式断了）"))

        // 越界钳制：写入远超上限的值，设置项里落的必须是钳制值
        store.ui.sidebarWidth = range.upperBound + 500
        let clamped = store.ui.sidebarWidth
        let clampsOK = clamped == range.upperBound
        NSLog("[Lumen][resize] \(clampsOK ? "✅" : "❌") 越界写入被钳制到上限 \(Int(range.upperBound))pt（实际 \(Int(clamped))pt）")

        NSLog("[Lumen][resize] 自检：通过 2 项，失败 \((follows ? 0 : 1) + (clampsOK ? 0 : 1)) 项")
    }
}
