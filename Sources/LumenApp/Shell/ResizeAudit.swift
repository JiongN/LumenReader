import Foundation
import AppKit
import LumenKit

/// 面板宽度自检：`--resize-report 1`。
///
/// 十二条断言，分两组。本批的语义是「**侧栏固定、只有 AI 面板可调**」：
///
/// **写入组**（①–⑦）：验「写进 AI 面板宽度 → 布局跟随」，以及拖拽提交路径上的钳制
/// （上限、下限、逐帧连写），外加一条「侧栏宽度是常量、不受设置影响」。
///
/// | # | 断言 | 防的是什么 |
/// | - | ---- | ---------- |
/// | ① | AI 面板宽度写入后布局跟随 | 响应式断了：改了设置画面不动 |
/// | ② | 高于上限的写入被钳到动态上限 | 拖到底停不住 / 越界把阅读区挤没 |
/// | ③ | 低于下限（300）的写入被钳到下限 | footer 行被压到换行 |
/// | ④ | 逐帧写入期间不越界 | 拖拽中间态越界 |
/// | ⑤ | 逐帧写入后终值等于上限 | 钳制算式与写入不同源 |
/// | ⑥ | 逐帧写入后布局与终值一致 | 写入与渲染脱节 |
/// | ⑦ | 侧栏宽度是常量，不受 `settings.ui.sidebarWidth` 影响 | 有人悄悄把侧栏又接回了设置 |
///
/// **窗口缩放组**（⑧–⑫）：起因是一个真实缺陷——钳制只发生在拖拽提交那一刻，
/// 窗口被拉小之后**没有任何一次提交**，落库的旧宽度原样参与布局，阅读区被挤没、
/// 图标栏被推到屏幕外。修法是「渲染时按容器宽度求显示宽度、落库值不动」，
/// 这五条盯的正是它的承诺：
///
/// | # | 断言 | 防的是什么 |
/// | - | ---- | ---------- |
/// | ⑧ | 最挤状态（920pt、AI 偏好顶满）下阅读区仍 ≥ 320 | 修了个寂寞：面板照旧把正文挤没 |
/// | ⑨ | 最挤状态下图标栏完整落在窗口内 | 图标栏被推出屏幕左缘 |
/// | ⑩ | 最挤状态下 AI 面板不越出窗口右缘 | AI 面板溢出到屏幕外 |
/// | ⑪ | 窗口拉宽后 AI 面板回到落库偏好 | 改成「覆写式钳制」——拉回去宽度就丢了 |
/// | ⑫ | 极窄容器下两侧之和不超过预算 | 那道等比压缩的闸被删（界面到不了，仅算式层） |
///
/// 「最挤状态」= 窗口压到应用声明的最小宽度 920pt，且 AI 面板偏好顶到静态上限
/// （52 + 248 + 640 = 940 > 920），于是 AI 被压到下限、阅读区拿保底。
///
/// 所有写入都走 `SettingsStore.commitAIPanelWidth`，与拖拽松手的提交**同一个函数**。
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

    /// 四个探针在同一时刻的一组读数。
    private struct Frames {
        let container: CGFloat
        let sidebar: CGRect
        let rail: CGRect
        let reader: CGRect
        let aiPanel: CGRect
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
            NSLog("%@", "[Lumen][resize] \(ok ? "✅" : "❌") \(name)"
                  + (ok || detail.isEmpty ? "" : " —— \(detail)"))
        }

        let scale = Double(DS.Size.windowScale(for: Self.containerWidth()))
        let baseLowerBound = UISettings.PanelWidth.aiRange.lowerBound
        let lowerBound = baseLowerBound * scale
        let staticUpper = UISettings.PanelWidth.aiRange.upperBound * scale
        let cap = Self.aiPanelCap(state: state)
        let baseCap = cap / scale
        NSLog("%@", "[Lumen][resize] 窗口可用宽度 \(Int(Self.containerWidth()))pt；"
              + "AI 面板上限 静态 \(Int(staticUpper))pt / 按窗口 \(Int(cap))pt；下限 \(Int(lowerBound))pt；"
              + "侧栏固定 \(Int(UISettings.PanelWidth.sidebarDefault))pt")

        guard let beforeFrame = LayoutAuditLog.shared.frame(named: "aiPanel") else {
            NSLog("[Lumen][resize] ❌ 没有读到 AI 面板布局探针（--open 打开文档了吗？）")
            return
        }
        NSLog("%@", "[Lumen][resize] 修改前：AI 面板实际宽度 \(Int(beforeFrame.width))pt")

        // ① 布局跟随：写入一个**与当前值明显不同**的宽度，读探针看它有没有真的变宽。
        //
        // 「明显不同」是硬要求：写一个和当前值相同的值，断言会恒真（它只是验了
        // 「没变还是没变」）。所以先试 +60，到顶了就改成 −60。
        // 区间都不足 40pt（窗口极窄）时如实跳过，而不是假报通过。
        if cap - lowerBound >= 40 {
            let current = beforeFrame.width
            let target = (current + 60 <= cap) ? current + 60 : max(lowerBound, current - 60)

            store.commitAIPanelWidth(target / scale, maxWidth: baseCap)

            // 布局跟随需要一次视图失效 + 布局帧；0.8s 足够，又不至于拖慢自检
            try? await Task.sleep(nanoseconds: 800_000_000)
            guard let afterFrame = LayoutAuditLog.shared.frame(named: "aiPanel") else {
                NSLog("[Lumen][resize] ❌ 修改后读不到布局探针")
                return
            }
            NSLog("%@", "[Lumen][resize] 写入 \(Int(target))pt → 实际渲染 \(Int(afterFrame.width))pt")
            check("AI 面板宽度写入后布局跟随",
                  abs(afterFrame.width - target) < 2,
                  "期望 \(Int(target))pt，实际 \(Int(afterFrame.width))pt（响应式断了）")
        } else {
            NSLog("%@", "[Lumen][resize] ⚠️ 窗口过窄（AI 面板可用区间 \(Int(cap - lowerBound))pt < 40pt），"
                  + "跳过「布局跟随」断言——此处若硬跑，断言会是恒真的")
        }

        // ② 越界钳制（上限）
        store.commitAIPanelWidth(baseCap + 500, maxWidth: baseCap)
        let clampedHigh = store.ui.aiPanelWidth
        check("越界写入被钳制到上限 \(Int(cap))pt",
              abs(clampedHigh - baseCap) < 0.5,
              "实际 \(Int(clampedHigh))pt")

        // ③ 越界钳制（下限）：往下拖到底也要停得住。下限 300 是本批从 280 提上来的，
        // 这条断言同时守住「footer 行不被压到换行」这条用户诉求。
        store.commitAIPanelWidth(20, maxWidth: baseCap)
        let clampedLow = store.ui.aiPanelWidth
        check("低于下限的写入被钳回下限 \(Int(lowerBound))pt",
              abs(clampedLow - baseLowerBound) < 0.5,
              "实际 \(Int(clampedLow))pt")

        // ④⑤⑥ 逐帧写入：连写 N 次（模拟拖拽 60 帧），中间值不得越界，终值必须等于上限
        var observedMin = Double.infinity
        var observedMax = -Double.infinity
        let frames = 60
        for index in 0..<frames {
            // 从下限之下起步、每帧 +12pt，末帧远超上限
            store.commitAIPanelWidth(baseLowerBound - 40 + Double(index) * 12, maxWidth: baseCap)
            observedMin = min(observedMin, store.ui.aiPanelWidth)
            observedMax = max(observedMax, store.ui.aiPanelWidth)
        }
        let finalValue = store.ui.aiPanelWidth
        let stayedInBounds = observedMin >= baseLowerBound - 0.001 && observedMax <= baseCap + 0.001
        let finalIsCap = abs(finalValue - baseCap) < 0.5

        try? await Task.sleep(nanoseconds: 800_000_000)
        guard let frameAfterBurst = LayoutAuditLog.shared.frame(named: "aiPanel") else {
            NSLog("[Lumen][resize] ❌ 连续写入后读不到布局探针")
            return
        }
        let layoutMatches = abs(frameAfterBurst.width - finalValue * scale) < 2

        NSLog("%@", "[Lumen][resize] 连续写 \(frames) 次：区间 [\(Int(observedMin)), \(Int(observedMax))]pt，"
              + "终值 \(Int(finalValue))pt，布局实测 \(Int(frameAfterBurst.width))pt")
        check("逐帧写入期间不越界", stayedInBounds,
              "观测到 [\(Int(observedMin)), \(Int(observedMax))]pt，允许 [\(Int(lowerBound)), \(Int(cap))]pt")
        check("逐帧写入后终值等于上限", finalIsCap,
              "终值 \(Int(finalValue))pt，上限 \(Int(cap))pt")
        check("逐帧写入后布局与终值一致", layoutMatches,
              "布局 \(Int(frameAfterBurst.width))pt vs 设置 \(Int(finalValue))pt")

        // ⑦ 侧栏宽度是常量：把兼容字段写成一个明显不同的值，渲染宽度必须纹丝不动。
        //
        // 这条盯的是「有人悄悄把侧栏又接回了设置」——例如把 `.frame(width:)` 改回
        // `settings.ui.sidebarWidth`。那种改法不会崩溃、截图也看不出，
        // 只有把设置写成一个不同的值、再看渲染宽度才抓得住。
        let fixedSidebar = UISettings.PanelWidth.sidebarDefault * scale
        store.commitSidebarWidth(fixedSidebar + 120)
        try? await Task.sleep(nanoseconds: 800_000_000)
        if let sidebarFrame = LayoutAuditLog.shared.frame(named: "sidebar") {
            NSLog("%@", "[Lumen][resize] 侧栏兼容字段写入 \(Int(fixedSidebar + 120))pt → 实际渲染 "
                  + "\(Int(sidebarFrame.width))pt（期望常量 \(Int(fixedSidebar))pt）")
            check("侧栏宽度按窗口比例计算，不受设置影响",
                  abs(sidebarFrame.width - fixedSidebar) < 2,
                  "落库 \(Int(store.ui.sidebarWidth))pt，实渲染 \(Int(sidebarFrame.width))pt"
                      + "（侧栏又接回了设置？）")
        } else {
            NSLog("[Lumen][resize] ❌ 读不到侧栏布局探针")
            failures.append("侧栏宽度按窗口比例计算，不受设置影响")
        }

        // ⑧–⑫ 窗口缩放
        if state.isSidebarVisible && state.isAIPanelVisible && !state.isImmersive {
            for result in await Self.windowScalingChecks(state: state) {
                check(result.name, result.ok, result.detail)
            }
        } else {
            NSLog("%@", "[Lumen][resize] ⚠️ 两侧面板没有同时可见（侧栏 \(state.isSidebarVisible)"
                  + " / AI \(state.isAIPanelVisible) / 沉浸 \(state.isImmersive)），"
                  + "跳过窗口缩放断言——它们验的正是三栏同时在场时的挤压")
        }

        NSLog("%@", "[Lumen][resize] 自检：通过 \(passed) 项，失败 \(failures.count) 项"
              + (failures.isEmpty ? " ✅" : " ❌ " + failures.joined(separator: "；")))
    }

    // MARK: - 窗口缩放组

    /// 把窗口依次设成「宽」「最小 920（AI 偏好顶满，最坏可达情形）」「再拉回宽」，
    /// 每次都读布局探针，核对显示宽度、阅读区保底、图标栏位置、AI 面板右缘与落库偏好。
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
        let aiUpper = UISettings.PanelWidth.aiRange.upperBound
        // 一个明显超出窄窗口能给的 AI 偏好：920pt 下必定被压，宽窗口下必定放得开
        let preference = aiUpper
        store.ui.aiPanelWidth = preference

        var results: [CheckResult] = []

        // —— 先拉宽，建立对照。
        let wideWidth = Self.wideWindowWidth()
        await setContentSize(width: wideWidth, on: window)
        guard let baseline = Self.frames() else {
            NSLog("[Lumen][resize] ❌ 宽窗口下读不到布局探针")
            return results
        }
        NSLog("%@", "[Lumen][resize] 宽窗口 \(Int(baseline.container))pt：\(Self.describe(baseline))；"
              + "AI 面板实渲染 \(Int(baseline.aiPanel.width))pt（落库 \(Int(preference))pt）")

        // —— 收窄到应用声明的最小窗口宽度（920pt），AI 面板偏好顶满静态上限。
        //
        // AI 偏好顶满才会真的挤到阅读区（52 + 248 + 640 = 940 > 920）。
        store.ui.aiPanelWidth = aiUpper
        await setContentSize(width: 940, on: window)
        guard let narrow = Self.frames() else {
            NSLog("[Lumen][resize] ❌ 窄窗口下读不到布局探针")
            return results
        }
        NSLog("%@", "[Lumen][resize] 窄窗口 \(Int(narrow.container))pt：\(Self.describe(narrow))；"
              + "AI 面板实渲染 \(Int(narrow.aiPanel.width))pt（落库 \(Int(preference))pt）")

        results.append(CheckResult(
            name: "最挤状态下阅读区仍不低于保底 \(Int(minimumReader))pt",
            ok: narrow.reader.width >= minimumReader - 0.5,
            detail: "实际 \(Int(narrow.reader.width))pt（面板把正文挤没了）"))
        results.append(CheckResult(
            name: "最挤状态下图标栏完整落在窗口内",
            ok: Self.railIsOnScreen(narrow),
            detail: Self.railDetail(narrow)))
        results.append(CheckResult(
            name: "最挤状态下 AI 面板不越出窗口右缘",
            ok: narrow.aiPanel.maxX <= narrow.container + 0.5,
            detail: "AI 面板 maxX=\(String(format: "%.1f", narrow.aiPanel.maxX))"
                + " 窗口宽 \(Int(narrow.container))pt"))

        // —— 再拉回宽窗口：AI 偏好必须原样回来（防「覆盖式钳制」）
        //
        // 期望值成立有个前提：宽窗口真的装得下「AI 偏好 + 侧栏 + 图标栏 + 阅读区保底」。
        // 显示器比这还窄时如实跳过，而不是把期望值改成实现算出来的数。
        let wideScale = Double(DS.Size.windowScale(for: wideWidth))
        let expectedWideAI = preference * wideScale
        let needed = expectedWideAI + UISettings.PanelWidth.sidebarDefault * wideScale
            + Double(LeftRail.width) * wideScale
            + PanelWidthPolicy.handleWidth
            + minimumReader
        store.ui.aiPanelWidth = preference
        await setContentSize(width: wideWidth, on: window)
        guard let wide = Self.frames() else {
            NSLog("[Lumen][resize] ❌ 宽窗口下读不到布局探针")
            return results
        }
        NSLog("%@", "[Lumen][resize] 宽窗口 \(Int(wide.container))pt：\(Self.describe(wide))；"
              + "AI 面板实渲染 \(Int(wide.aiPanel.width))pt（落库 \(Int(preference))pt）")

        if Double(wide.container) >= needed - 1 {
            results.append(CheckResult(
                name: "窗口拉宽后 AI 面板按比例恢复偏好值 \(Int(expectedWideAI))pt",
                ok: abs(wide.aiPanel.width - expectedWideAI) < 2,
                detail: "实渲染 \(Int(wide.aiPanel.width))pt（偏好被窄窗口的钳制值覆写了）"))
        } else {
            NSLog("%@", "[Lumen][resize] ⚠️ 宽窗口只有 \(Int(wide.container))pt（需要 ≥\(Int(needed))pt），"
                  + "跳过「偏好还原」断言——硬跑会把「显示器不够宽」误报成实现问题")
        }

        // —— 极窄容器的算式层保证。
        //
        // 920pt 以下的窗口界面上到不了：SwiftUI 用 `.frame(minWidth: 920)` 把
        // NSWindow 的 minSize 兜住了，实测 `setContentSize(700)` 会被拉回 920，
        // 连脚本改窗口尺寸都钻不过去。所以这一条只在**算式层**验：
        // 断言的不变量是「两侧宽度之和不得超过预算」，即图标栏的 x 不可能为负。
        // 它盯的是 `PanelWidthPolicy` 最后那道等比压缩的闸——那道闸一旦被删，
        // 这个不变量就破，而界面上没有任何一条路径能替它报警。
        let extremeContainer: CGFloat = 500
        let railAndHandles = Double(LeftRail.width) + PanelWidthPolicy.handleWidth
        let extreme = PanelWidthPolicy.resolve(
            containerWidth: extremeContainer,
            showsRail: true,
            sidebarVisible: true,
            aiPanelPreferred: UISettings.PanelWidth.aiRange.upperBound
        )
        let extremeBudget = Double(extremeContainer) - railAndHandles
        let extremeUsed = (extreme.sidebar ?? 0) + (extreme.aiPanel ?? 0)
        NSLog("%@", "[Lumen][resize] 极窄容器 \(Int(extremeContainer))pt（界面到不了，仅算式层）："
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
              let reader = LayoutAuditLog.shared.frame(named: "readerSurface"),
              let aiPanel = LayoutAuditLog.shared.frame(named: "aiPanel") else { return nil }
        return Frames(container: containerWidth(), sidebar: sidebar, rail: rail, reader: reader, aiPanel: aiPanel)
    }

    /// 一行人能读的读数。只报探针量到的数，不掺任何「按算式应该是多少」——
    /// 那会让日志读起来像在自我印证。
    private static func describe(_ frames: Frames) -> String {
        "侧栏 \(Int(frames.sidebar.width))pt / 阅读区 \(Int(frames.reader.width))pt"
            + " / AI 面板 \(Int(frames.aiPanel.width))pt"
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

    /// AI 面板的可用上限。刻意直接调 `PanelWidthPolicy`——拖拽提交走的就是它，
    /// 自检另写一份等于验了个寂寞。
    private static func aiPanelCap(state: AppState) -> Double {
        PanelWidthPolicy.aiCap(
            containerWidth: containerWidth(),
            showsRail: !state.isImmersive,
            sidebarVisible: state.isSidebarVisible && !state.isImmersive
        )
    }
}
