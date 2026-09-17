import Foundation
import AppKit
import LumenKit

/// 面板宽度自检：`--resize-report 1`。
///
/// 十二条断言，分两组：
///
/// **写入组**（①–④，六条，原有的）：验「写进设置 → 布局跟随」，以及拖拽提交
/// 路径上的钳制（上限、下限、逐帧连写）。
///
/// **窗口缩放组**（⑤–⑩，六条，本批新增）：起因是一个真实缺陷——钳制只发生在
/// 拖拽提交那一刻，窗口被拉小之后**没有任何一次提交**，落库的旧宽度原样参与
/// 布局：920pt 窗口下阅读区只剩 266pt，再窄一点图标栏被推到 x = −97
/// （切页签的入口直接跑到屏幕外）。修法是「渲染时按容器宽度求显示宽度、落库值
/// 不动」，这六条盯的正是它的三个承诺与两个坑：
///
/// | # | 断言 | 防的是什么 |
/// | - | ---- | ---------- |
/// | ⑤ | 最挤状态下阅读区仍不低于保底 320pt | 修了个寂寞：面板照旧把正文挤没 |
/// | ⑥ | 最挤状态下侧栏被压到落库偏好以内 | 渲染时根本没按容器宽度重算 |
/// | ⑦ | 最挤状态下图标栏完整落在窗口内 | 图标栏被推出屏幕左缘 |
/// | ⑧ | 收窄窗口不改写落库的侧栏偏好 | 修成「覆写式钳制」——拉回去宽度就永远丢了 |
/// | ⑨ | 窗口拉宽后侧栏回到落库的偏好值 | 同上，从**渲染结果**这一侧验 |
/// | ⑩ | 极窄容器下两侧面板不超出预算 | 那道等比压缩的闸被删（界面到不了，仅算式层） |
///
/// 「最挤状态」= 窗口压到应用声明的最小宽度 920pt，且两侧面板的偏好都顶到各自
/// 的静态上限（52 + 2 + 420 + 640 = 1114pt > 920pt）。两侧都顶满才会真的挤到
/// 图标栏；只把侧栏顶满的话总宽仍装得下，⑦ 就成了恒真断言。
///
/// 所有写入都走 `SettingsStore.commitSidebarWidth`，与拖拽松手的提交**同一个函数**。
/// 这一点是硬的：自检若走另一条写入路径，它验证的就是一段死代码。
///
/// 「真实鼠标拖拽」仍然验不了（这台机器没有辅助功能授权，无法合成拖拽事件），
/// 但手势本身只做一件事——把位移写进这个设置项——而「写进设置项之后布局跟随」
/// 正是本自检覆盖的部分。这个诚实边界沿用 `docs/VERIFY.md` 的既有结论。
@MainActor
enum ResizeAudit {

    /// 一条断言的结果。
    ///
    /// 单独成结构而不是就地判定，是为了让「窗口缩放」那一组能在另一个函数里
    /// 算完再交回来统一计数——`check` 是 `run` 里的局部函数，带不出去。
    private struct CheckResult {
        let name: String
        let ok: Bool
        let detail: String
    }

    /// 三个探针在同一时刻的一组读数。
    private struct Frames {
        let container: CGFloat
        let sidebar: CGRect
        let rail: CGRect
        let reader: CGRect
    }

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

        // ⑤–⑩ 窗口缩放
        if state.isSidebarVisible && state.isAIPanelVisible && !state.isImmersive {
            for result in await Self.windowScalingChecks(state: state) {
                check(result.name, result.ok, result.detail)
            }
        } else {
            NSLog("[Lumen][resize] ⚠️ 两侧面板没有同时可见（侧栏 \(state.isSidebarVisible)"
                  + " / AI \(state.isAIPanelVisible) / 沉浸 \(state.isImmersive)），"
                  + "跳过窗口缩放断言——它们验的正是三栏同时在场时的挤压")
        }

        NSLog("[Lumen][resize] 自检：通过 \(passed) 项，失败 \(failures.count) 项"
              + (failures.isEmpty ? " ✅" : " ❌ " + failures.joined(separator: "；")))
    }

    // MARK: - 窗口缩放组

    /// 把窗口依次设成「宽」「最小 920（两侧都顶到上限，最坏可达情形）」「再拉回宽」，
    /// 每次都读布局探针，核对显示宽度、阅读区保底、图标栏位置与落库偏好。
    ///
    /// 两个刻意的选择：
    ///
    /// - **窗口尺寸由本函数自己控制**，而不是沿用 `--window-size` 传进来的值：
    ///   这几条断言要在**确定的**挤压条件下才有意义（920pt 下必定压得下、
    ///   拉宽后必定放得开），沿用外部尺寸会让「够不够窄」变成掷骰子。
    /// - **从宽到窄走一遍真实的缩放**，而不是停在窄窗口上读一次数。
    ///   「覆盖式钳制」那种实现（窗口一变就把钳制值写回落库）只有在这条路径上
    ///   才会动手——停在窄窗口上读，它根本没有被触发的机会，断言就成了恒真。
    private static func windowScalingChecks(state: AppState) async -> [CheckResult] {
        guard let window = mainWindow() else {
            NSLog("[Lumen][resize] ❌ 找不到主窗口，跳过窗口缩放断言")
            return []
        }

        let store = state.settingsStore
        let minimumReader = UISettings.PanelWidth.minimumReaderWidth
        let aiLower = UISettings.PanelWidth.aiRange.lowerBound
        let aiUpper = UISettings.PanelWidth.aiRange.upperBound
        // 一个明显超出窄窗口能给的宽度：920pt 下必定被压，宽窗口下必定放得开
        let preference = UISettings.PanelWidth.sidebarRange.upperBound
        store.ui.sidebarWidth = preference

        var results: [CheckResult] = []

        // —— 先拉宽：确认偏好在放得开的时候就是它自己。
        //
        // 这一步把 AI 面板压到它自己的下限：「宽窗口下 420pt 放得开」于是只取决于
        // 侧栏，期望值不必再把「对侧分到多少」这条规则算进来——
        // 把实现算式当作期望值，等于拿实现验证实现。
        let wideWidth = Self.wideWindowWidth()
        store.ui.aiPanelWidth = aiLower
        await setContentSize(width: wideWidth, on: window)
        guard let baseline = Self.frames() else {
            NSLog("[Lumen][resize] ❌ 宽窗口下读不到布局探针")
            return results
        }
        NSLog("[Lumen][resize] 宽窗口 \(Int(baseline.container))pt：\(Self.describe(baseline))；"
              + "侧栏实渲染 \(Int(baseline.sidebar.width))pt（落库 \(Int(preference))pt）")

        // —— 收窄到应用声明的最小窗口宽度（920pt），并把 AI 面板顶到它的静态上限。
        //
        // 两侧同时顶满才是界面真的能到达的最挤状态（52 + 2 + 420 + 640 = 1114 > 920）。
        // 只把侧栏顶满的话总宽仍装得下，图标栏根本不会被挤——那样⑦就成了恒真断言。
        store.ui.aiPanelWidth = aiUpper
        await setContentSize(width: 920, on: window)
        guard let narrow = Self.frames() else {
            NSLog("[Lumen][resize] ❌ 窄窗口下读不到布局探针")
            return results
        }
        NSLog("[Lumen][resize] 窄窗口 \(Int(narrow.container))pt：\(Self.describe(narrow))；"
              + "侧栏实渲染 \(Int(narrow.sidebar.width))pt（落库 \(Int(preference))pt）")

        results.append(CheckResult(
            name: "最挤状态下阅读区仍不低于保底 \(Int(minimumReader))pt",
            ok: narrow.reader.width >= minimumReader - 0.5,
            detail: "实际 \(Int(narrow.reader.width))pt（面板把正文挤没了）"))
        results.append(CheckResult(
            name: "最挤状态下侧栏被压到落库偏好以内",
            ok: narrow.sidebar.width < preference - 2,
            detail: "落库 \(Int(preference))pt，实渲染 \(Int(narrow.sidebar.width))pt"
                + "（渲染时没有按容器宽度重算）"))
        results.append(CheckResult(
            name: "最挤状态下图标栏完整落在窗口内",
            ok: Self.railIsOnScreen(narrow),
            detail: Self.railDetail(narrow)))
        results.append(CheckResult(
            name: "收窄窗口不改写落库的侧栏偏好",
            ok: abs(store.ui.sidebarWidth - preference) < 0.5,
            detail: "落库变成了 \(Int(store.ui.sidebarWidth))pt（偏好被覆写成了钳制值）"))

        // —— 再拉回宽窗口：偏好必须原样回来（防「覆盖式钳制」）
        //
        // 期望值成立有个前提：宽窗口真的装得下「侧栏偏好 + AI 下限 + 图标栏
        // + 两条分隔线 + 阅读区保底」。显示器比这还窄时如实跳过，
        // 而不是把期望值改成实现算出来的数。
        let needed = preference + aiLower
            + Double(LeftRail.width)
            + 2 * PanelWidthPolicy.handleWidth
            + minimumReader
        store.ui.aiPanelWidth = aiLower
        await setContentSize(width: wideWidth, on: window)
        guard let wide = Self.frames() else {
            NSLog("[Lumen][resize] ❌ 宽窗口下读不到布局探针")
            return results
        }
        NSLog("[Lumen][resize] 宽窗口 \(Int(wide.container))pt：\(Self.describe(wide))；"
              + "侧栏实渲染 \(Int(wide.sidebar.width))pt（落库 \(Int(preference))pt）")

        if Double(wide.container) >= needed - 1 {
            results.append(CheckResult(
                name: "窗口拉宽后侧栏回到落库的偏好值 \(Int(preference))pt",
                ok: abs(wide.sidebar.width - preference) < 2,
                detail: "实渲染 \(Int(wide.sidebar.width))pt（偏好被窄窗口的钳制值覆写了）"))
        } else {
            NSLog("[Lumen][resize] ⚠️ 宽窗口只有 \(Int(wide.container))pt（需要 ≥\(Int(needed))pt），"
                  + "跳过「偏好还原」断言——硬跑会把「显示器不够宽」误报成实现问题")
        }

        // —— 极窄容器的算式层保证。
        //
        // 500pt 的窗口界面上到不了：SwiftUI 用 `.frame(minWidth: 920)` 把
        // NSWindow 的 minSize 兜住了，实测 `setContentSize(700)` 会被拉回 920，
        // 连脚本改窗口尺寸都钻不过去。所以这一条只在**算式层**验：
        // 断言的不变量是「两侧宽度之和不得超过预算」，即图标栏的 x 不可能为负。
        // 它盯的是 `PanelWidthPolicy` 最后那道等比压缩的闸——那道闸一旦被删，
        // 这个不变量就破，而界面上没有任何一条路径能替它报警。
        let extremeContainer: CGFloat = 500
        let railAndHandles = Double(LeftRail.width) + 2 * PanelWidthPolicy.handleWidth
        let extreme = PanelWidthPolicy.resolve(
            containerWidth: extremeContainer,
            showsRail: true,
            sidebarPreferred: UISettings.PanelWidth.sidebarRange.upperBound,
            aiPanelPreferred: UISettings.PanelWidth.aiRange.upperBound
        )
        let extremeBudget = Double(extremeContainer) - railAndHandles
        let extremeUsed = (extreme.sidebar ?? 0) + (extreme.aiPanel ?? 0)
        NSLog("[Lumen][resize] 极窄容器 \(Int(extremeContainer))pt（界面到不了，仅算式层）："
              + "\(extreme.description)，预算 \(Int(extremeBudget))pt，面板占用 \(Int(extremeUsed))pt")
        results.append(CheckResult(
            name: "极窄容器下两侧面板不超出预算（图标栏 x 不会为负）",
            ok: extremeUsed <= extremeBudget + 0.5,
            detail: "面板占用 \(Int(extremeUsed))pt > 预算 \(Int(extremeBudget))pt"))

        return results
    }

    // MARK: - 读数与工具

    private static func frames() -> Frames? {
        guard let sidebar = LayoutAuditLog.shared.frame(named: "sidebar"),
              let rail = LayoutAuditLog.shared.frame(named: "sidebarRail"),
              let reader = LayoutAuditLog.shared.frame(named: "readerSurface") else { return nil }
        return Frames(container: containerWidth(), sidebar: sidebar, rail: rail, reader: reader)
    }

    /// 一行人能读的读数。只报探针量到的数，不掺任何「按算式应该是多少」——
    /// 那会让日志读起来像在自我印证。
    private static func describe(_ frames: Frames) -> String {
        "侧栏 \(Int(frames.sidebar.width))pt / 阅读区 \(Int(frames.reader.width))pt"
            + " / 图标栏 x=\(String(format: "%.1f", frames.rail.minX))"
            + " w=\(Int(frames.rail.width))pt"
    }

    /// 图标栏的整条都要在窗口里：x 不能为负（被推出左缘），右缘也不能越出窗口。
    private static func railIsOnScreen(_ frames: Frames) -> Bool {
        frames.rail.minX >= -0.5 && frames.rail.maxX <= frames.container + 0.5
    }

    private static func railDetail(_ frames: Frames) -> String {
        "图标栏 x=\(String(format: "%.1f", frames.rail.minX))"
            + " maxX=\(String(format: "%.1f", frames.rail.maxX))"
            + " 窗口宽 \(Int(frames.container))pt"
    }

    /// 「拉宽」这一步用多宽：默认 1340（与常规窗口一致），但不超出显示器。
    private static func wideWindowWidth() -> CGFloat {
        let screen = NSScreen.main?.visibleFrame.width ?? 1440
        return max(920, min(1340, screen - 40))
    }

    /// 把主窗口内容区改成指定宽度（自检用），高度保持不变。
    ///
    /// 应用声明了 920pt 的最小窗口宽度：实测把窗口设成 700pt 会被拉回 920
    /// （SwiftUI 的 `.frame(minWidth:)` 会持续兜住 NSWindow 的 minSize），
    /// 连脚本改窗口尺寸都钻不过去。所以本自检只在**可达的**宽度之间切换，
    /// 比最小宽度还窄的情形改由算式层断言覆盖。
    private static func setContentSize(width: CGFloat, on window: NSWindow) async {
        let height = window.contentView?.bounds.height ?? 620
        window.setContentSize(NSSize(width: width, height: height))
        // 等窗口改完尺寸、布局再跑一轮；0.9s 足够，又不至于把自检拖太久
        try? await Task.sleep(nanoseconds: 900_000_000)
    }

    private static func mainWindow() -> NSWindow? {
        NSApp.windows.first { $0.isVisible && ($0.contentView?.bounds.height ?? 0) > 100 }
    }

    private static func containerWidth() -> CGFloat {
        mainWindow()?.contentView?.bounds.width ?? 0
    }

    // MARK: - 与界面共用同一条算式

    /// 侧栏的可用上限。刻意直接调 `PanelWidthPolicy`——拖拽提交走的就是它，
    /// 自检另写一份等于验了个寂寞。
    private static func sidebarCap(state: AppState) -> Double {
        PanelWidthPolicy.sidebarCap(
            containerWidth: containerWidth(),
            showsRail: !state.isImmersive,
            aiPanelPreferred: (state.isAIPanelVisible && !state.isImmersive)
                ? state.settingsStore.ui.aiPanelWidth
                : nil
        )
    }
}
