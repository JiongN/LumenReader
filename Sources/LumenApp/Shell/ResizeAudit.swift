import Foundation
import AppKit
import LumenKit

/// 面板宽度自检：`--resize-report 1`。
///
/// 四条断言，前两条是原有的，后两条是这次补的：
///
/// 1. **布局跟随宽度写入** —— 验的是**这次真的坏过的那条链路**：写
///    `settingsStore.ui.sidebarWidth`，布局却不动（视图没有观察 `SettingsStore`，
///    写入不触发任何视图失效）。所以断言必须打在「视图出现之后」。
/// 2. **越界写入被钳制** —— 拖到边界要停得住的前提。写入远超上限的值，
///    落进设置项的必须是钳制值。
/// 3. **低于下限的写入被钳回下限**（新增）—— 与第 2 条配成一对：
///    只有上限没有下限的话，用户把分隔线往左拖到底会得到一条 20pt 的面板。
/// 4. **连续快速写 N 次后终值正确且中间不越界**（新增）—— 模拟逐帧拖拽。
///    这一条防的是「逐帧写入」这条路径本身：一旦有人把它改回每帧写设置，
///    中间态就会短暂越界，而终端值照样是对的——只看终值的断言抓不到。
///
/// 所有写入都走 `SettingsStore.commitSidebarWidth`，与拖拽松手的提交**同一个函数**。
/// 这一点是硬的：自检若走另一条写入路径，它验证的就是一段死代码。
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

        var passed = 0
        var failures: [String] = []
        func check(_ name: String, _ ok: Bool, _ detail: String = "") {
            if ok { passed += 1 } else { failures.append(name) }
            // 通过时不打 detail：那些数字在每条目上面已经单独打过一行，
            // 通过时再附一句「（响应式断了）」反而让人误读成失败。
            NSLog("[Lumen][resize] \(ok ? "✅" : "❌") \(name)"
                  + (ok || detail.isEmpty ? "" : " —— \(detail)"))
        }

        let lowerBound = UISettings.PanelWidth.sidebarRange.lowerBound
        let staticUpper = UISettings.PanelWidth.sidebarRange.upperBound
        let cap = Self.sidebarCap(state: state)
        NSLog("[Lumen][resize] 窗口可用宽度 \(Int(Self.containerWidth()))pt；"
              + "侧栏上限 静态 \(Int(staticUpper))pt / 按窗口 \(Int(cap))pt；下限 \(Int(lowerBound))pt")

        guard let beforeFrame = LayoutAuditLog.shared.frame(named: "sidebar") else {
            NSLog("[Lumen][resize] ❌ 没有读到侧栏布局探针（--open 打开文档了吗？）")
            return
        }
        NSLog("[Lumen][resize] 修改前：侧栏实际宽度 \(Int(beforeFrame.width))pt")

        // ① 布局跟随：写入一个**与当前值明显不同**的宽度，读探针看它有没有真的变宽。
        //
        // 「明显不同」是硬要求：写一个和当前值相同的值，断言会恒真（它只是验了
        // 「没变还是没变」）。所以先试 +60，到顶了就改成 −60。
        // 区间都不足 40pt（窗口极窄）时如实跳过，而不是假报通过。
        if cap - lowerBound >= 40 {
            let current = beforeFrame.width
            let target = (current + 60 <= cap) ? current + 60 : max(lowerBound, current - 60)

            store.commitSidebarWidth(target, maxWidth: cap)

            // 布局跟随需要一次视图失效 + 布局帧；0.8s 足够，又不至于拖慢自检
            try? await Task.sleep(nanoseconds: 800_000_000)
            guard let afterFrame = LayoutAuditLog.shared.frame(named: "sidebar") else {
                NSLog("[Lumen][resize] ❌ 修改后读不到布局探针")
                return
            }
            NSLog("[Lumen][resize] 写入 \(Int(target))pt → 实际渲染 \(Int(afterFrame.width))pt")
            check("布局跟随宽度写入",
                  abs(afterFrame.width - target) < 2,
                  "期望 \(Int(target))pt，实际 \(Int(afterFrame.width))pt（响应式断了）")
        } else {
            NSLog("[Lumen][resize] ⚠️ 窗口过窄（侧栏可用区间 \(Int(cap - lowerBound))pt < 40pt），"
                  + "跳过「布局跟随」断言——此处若硬跑，断言会是恒真的")
        }

        // ② 越界钳制（上限）
        store.commitSidebarWidth(cap + 500, maxWidth: cap)
        let clampedHigh = store.ui.sidebarWidth
        check("越界写入被钳制到上限 \(Int(cap))pt",
              abs(clampedHigh - cap) < 0.5,
              "实际 \(Int(clampedHigh))pt")

        // ③ 越界钳制（下限）：往下拖到底也要停得住
        store.commitSidebarWidth(20, maxWidth: cap)
        let clampedLow = store.ui.sidebarWidth
        check("低于下限的写入被钳回下限 \(Int(lowerBound))pt",
              abs(clampedLow - lowerBound) < 0.5,
              "实际 \(Int(clampedLow))pt")

        // ④ 逐帧写入：连写 N 次（模拟拖拽 60 帧），中间值不得越界，终值必须等于上限
        var observedMin = Double.infinity
        var observedMax = -Double.infinity
        let frames = 60
        for index in 0..<frames {
            // 从下限之下起步、每帧 +12pt，末帧远超上限
            store.commitSidebarWidth(Double(lowerBound) - 40 + Double(index) * 12, maxWidth: cap)
            observedMin = min(observedMin, store.ui.sidebarWidth)
            observedMax = max(observedMax, store.ui.sidebarWidth)
        }
        let finalValue = store.ui.sidebarWidth
        let stayedInBounds = observedMin >= lowerBound - 0.001 && observedMax <= cap + 0.001
        let finalIsCap = abs(finalValue - cap) < 0.5

        try? await Task.sleep(nanoseconds: 800_000_000)
        guard let frameAfterBurst = LayoutAuditLog.shared.frame(named: "sidebar") else {
            NSLog("[Lumen][resize] ❌ 连续写入后读不到布局探针")
            return
        }
        let layoutMatches = abs(frameAfterBurst.width - finalValue) < 2

        NSLog("[Lumen][resize] 连续写 \(frames) 次：区间 [\(Int(observedMin)), \(Int(observedMax))]pt，"
              + "终值 \(Int(finalValue))pt，布局实测 \(Int(frameAfterBurst.width))pt")
        check("逐帧写入期间不越界", stayedInBounds,
              "观测到 [\(Int(observedMin)), \(Int(observedMax))]pt，允许 [\(Int(lowerBound)), \(Int(cap))]pt")
        check("逐帧写入后终值等于上限", finalIsCap,
              "终值 \(Int(finalValue))pt，上限 \(Int(cap))pt")
        check("逐帧写入后布局与终值一致", layoutMatches,
              "布局 \(Int(frameAfterBurst.width))pt vs 设置 \(Int(finalValue))pt")

        NSLog("[Lumen][resize] 自检：通过 \(passed) 项，失败 \(failures.count) 项"
              + (failures.isEmpty ? " ✅" : " ❌ " + failures.joined(separator: "；")))
    }

    // MARK: - 与界面共用同一条算式

    /// 侧栏的可用上限。刻意直接调 `PanelWidthPolicy`——拖拽提交走的就是它，
    /// 自检另写一份等于验了个寂寞。
    private static func sidebarCap(state: AppState) -> Double {
        PanelWidthPolicy.sidebarCap(
            containerWidth: containerWidth(),
            aiPanelWidth: state.settingsStore.ui.aiPanelWidth,
            isAIPanelVisible: state.isAIPanelVisible && !state.isImmersive
        )
    }

    private static func containerWidth() -> CGFloat {
        NSApp.windows
            .first { $0.isVisible && ($0.contentView?.bounds.height ?? 0) > 100 }?
            .contentView?.bounds.width ?? 0
    }
}
