import Foundation
import AppKit
import SwiftUI
import LumenKit

/// 面板展开 / 收起过渡自检：`--panel-transition-report 1`。
///
/// **存在理由**（用户报的症状：大文件上展开 / 收回面板时 PDF 屏闪）：
///
/// 面板可见性的切换全仓原本散在 7 处，各自 `withAnimation(DS.Motion.panel) { 状态.toggle() }`。
/// 动画期间阅读区宽度**每帧都在变**，而 `PDFView.autoScales == true` 会让 PDFKit 每帧
/// 重算「适宽倍率」、丢掉并重新栅格化整页瓦片 —— 文件越大越明显，就是肉眼看到的闪。
///
/// 项目里**早就有**躲开这个坑的机制：`PDFController.setPanelResizing(_:)`（拖分隔线那条路
/// 一直在用）会先钉住 `autoScales`、记下滚动锚点，动完再恢复并补偿滚动位置。
/// 但**展开 / 收起这条路从来没调用过它**。修法是把 7 个写入点收敛到
/// `AppState.setSidebarVisible(_:animated:)` / `setAIPanelVisible(_:animated:)`，
/// 由它们在改状态**之前**进入「调整中」、在 `withAnimation(_:completion:)` 完成时退出。
///
/// 本通道证明三件事，每一件都能被证伪：
///
/// | # | 断言 | 防的是什么 |
/// | - | ---- | ---------- |
/// | ① | 一次展开 / 收起各触发 `setPanelResizing(true)` / `(false)` **恰好一次** | 漏调（回到旧行为）、或每帧狂调 |
/// | ② | **动画进行中** `autoScales` 实际为 `false`，结束后恢复成进入前的值 | 钉了没恢复 / 只调了方法但内部没真钉住 |
/// | ③ | 滚动锚点（当前页 + 页内归一化位置）在动画前后未显著漂移 | 补偿逻辑被删 |
/// | ④ | **反向对照**：绕过方法直接 `withAnimation` 写状态时，① 不成立、② 不成立 | 恒真断言：证明 ① ② 真的在区分「走方法」与「不走方法」 |
///
/// ④ 是这套断言的关键 —— 它复刻的正是**修复前**的那段代码。若有人把写入点改回
/// 直接 `withAnimation`，④ 与 ① 会同时红。
///
/// **诚实边界**：这台机器没有视觉通道。本通道**证明不了「屏闪在观感上消失了」**，
/// 它证明的是「动画期间适宽倍率被钉住、结束后恢复、锚点未漂移」——即屏闪的**成因**。
/// 观感需要人眼确认，这一点已写进 `docs/VERIFY.md`。
///
/// 开关以 `-report` 结尾 → `LaunchOptions.isAuditRun` 自动成立 → `suppressSave` 自动开、
/// 数据目录切到 `LUMEN_TEST_DATA`，所以不会污染用户配置。
extension LaunchOptions {
    static var panelTransitionReport: Bool { flag("--panel-transition-report") }
}

@MainActor
enum PanelTransitionAudit {

    /// 锚点漂移容差：页高的 5%。
    ///
    /// 取页高的比例而不是 pt：`panelAnchor()` 给的本来就是「页内归一化位置」，
    /// 换页 / 缩放后页高会变，用绝对 pt 比会随文档尺寸漂。
    /// 5% 的依据是「半行正文」——同一行在页内的位置反复进出面板后不该跨过半行，
    /// 肉眼才看不出跳。第一次跑出来的实际值写在日志里，若实际远小于它，
    /// 也不把容差收紧到贴着实测值（那会变成「谁的实现谁定标准」）。
    private static let anchorTolerance = 0.05

    static func run(state: AppState) async {
        // 探针首轮 dump 在首次上报后 2s；再留余量等布局稳定（与 ResizeAudit 同款节奏）
        try? await Task.sleep(nanoseconds: 2_600_000_000)

        var passed = 0
        var failures: [String] = []
        func check(_ name: String, _ ok: Bool, _ detail: String = "") {
            if ok { passed += 1 } else { failures.append(name) }
            NSLog("%@", "[Lumen][panel] \(ok ? "✅" : "❌") \(name)"
                  + (ok || detail.isEmpty ? "" : " —— \(detail)"))
        }

        let bridge = state.bridge
        guard bridge.panelTransitionProbe != nil,
              bridge.resetPanelTransitionTrace != nil else {
            NSLog("%@", "[Lumen][panel] ❌ 当前标签拿不到 PDF 面板过渡探针"
                  + "（EPUB 标签不装控制器；请用 --open 打开一份 PDF）")
            return
        }
        guard state.activeSession != nil else {
            NSLog("%@", "[Lumen][panel] ❌ 没有活动会话——探针会落到欢迎页的空桥上，读数无意义")
            return
        }

        // 桥的闭包「本身可为 nil」且「返回值也可为 nil」（控制器用 weak 持有、
        // EPUB 标签根本没装）。这里拍平成一层：`nil` 一律表示「拿不到读数」。
        //
        // 刻意**不加** `@Sendable`：`bridge.panelTransitionProbe` 是 main-actor 隔离的，
        // 加上去反而编译不过（本函数整体已在 `@MainActor` 上）。
        func probe() -> PDFController.PanelTransitionProbe? {
            bridge.panelTransitionProbe?() ?? nil
        }

        // 动效被静音时 `DS.Motion.panel` 会退化成 `.linear(duration: 0)`，
        // 「动画进行中」这个观测窗口根本不存在。此时如实跳过并说明，
        // **不能**报通过 —— 那会是一条恒真的断言。
        let motionMuted = MotionGate.isMuted
        NSLog("%@", "[Lumen][panel] 动效门：静音=\(motionMuted ? "是" : "否")"
              + "（静音时 withAnimation 退化成 0 时长，②的「动画进行中」窗口不存在）")

        // 基线：确保侧栏可见。**用 animated: false** —— 它不走 beginPanelTransition，
        // 因此不会在我们的计数里塞进一笔无关读数。
        if !state.isSidebarVisible {
            state.setSidebarVisible(true, animated: false)
            try? await Task.sleep(nanoseconds: 400_000_000)
        }
        NSLog("%@", "[Lumen][panel] 基线：侧栏可见=\(state.isSidebarVisible)"
              + " AI面板可见=\(state.isAIPanelVisible) 沉浸=\(state.isImmersive)")

        bridge.resetPanelTransitionTrace?()

        // ── ① ② 收起 → 展开，各走一次方法路径 ──
        //
        // 标签与布尔值的映射关系是**这里最容易写反的一处**，而且写反了不会报错：
        // 「收起」若映射成 `true`，那就是一次空操作（本来已经可见），断言会红成
        // 「setPanelResizing 没被调用」——看着像功能坏了，其实是自检自己坏了。
        // 本通道第一版就真踩了这个坑，所以下面专门有「状态真的翻转了」一条盯着它。
        for (round, leg, target) in [(1, "收起", false), (2, "展开", true)] {
            let visibleBefore = state.isSidebarVisible
            // 冻结断言的基线：必须在**进入动画之前**取——进入那一刻冻结就生效了。
            let jankBefore = JankTally.shared.snapshot()
            state.setSidebarVisible(target)
            NSLog("%@", "[Lumen][panel] 第 \(round) 轮（\(leg)）："
                  + "isSidebarVisible \(visibleBefore) → \(state.isSidebarVisible)（目标 \(target)）")
            check("第 \(round) 轮（\(leg)）可见性真的翻转了（防标签与布尔值写反）",
                  state.isSidebarVisible == target && visibleBefore != target,
                  "调用前 \(visibleBefore) → 调用后 \(state.isSidebarVisible)，目标 \(target)"
                      + "（没翻转 = 要么映射写反，要么 setSidebarVisible 被改成了空实现）")

            // 进入是**同步**发生的（beginPanelTransition 在 withAnimation 之前调），
            // 所以这里立刻就能读到一笔 enters。
            let atEnter = probe()
            check("第 \(round) 轮（\(leg)）进入调整：setPanelResizing(true) 恰好 1 次",
                  atEnter?.trace.enters == round,
                  "enters=\(atEnter?.trace.enters ?? -1)，期望 \(round)")

            // 动画窗口内探一次：此刻应当已被钉住。
            // 150ms 落在 spring(response: 0.34) 的中段——既晚于起始、又早于收敛。
            try? await Task.sleep(nanoseconds: 150_000_000)
            let during = probe()
            if motionMuted {
                NSLog("%@", "[Lumen][panel] ⚠️ 第 \(round) 轮跳过「动画进行中」两项断言：动效已静音"
                      + "（0 时长动画下冻结窗口也一并消失，frozen 读到 0 属于正常而非失败）")
            } else {
                check("第 \(round) 轮（\(leg)）动画进行中 autoScales 被钉住（=false）",
                      during?.autoScalesNow == false,
                      "实际 autoScales=\(during?.autoScalesNow.description ?? "nil")"
                          + "（true = 仍在每帧重算适宽倍率，即屏闪成因未除）")

                // ── 冻结是否真挡住了重排 ──
                //
                // 两条读数必须**成对**看：`frozen` 是「父布局来敲了几次门」，
                // `layout+draw` 是「真重排了几次」。真机修复前是 2 秒内各 308 次；
                // 冻住之后应当变成 frozen 涨、layout/draw 几乎不动。
                // 只看其中一个都说明不了问题：frozen=0 可能是「这段没人动」，
                // layout=0 也可能是「没人动」——两个一起看才排除这种侥幸。
                let now = JankTally.shared.snapshot()
                let frozen = (now[.pdfViewFrozen] ?? 0) - (jankBefore[.pdfViewFrozen] ?? 0)
                let relayout = ((now[.pdfViewLayout] ?? 0) - (jankBefore[.pdfViewLayout] ?? 0))
                    + ((now[.pdfViewDraw] ?? 0) - (jankBefore[.pdfViewDraw] ?? 0))
                NSLog("%@", "[Lumen][panel] 第 \(round) 轮（\(leg)）动画期间重排："
                      + "被冻结挡掉 \(frozen) 次，真重排 \(relayout) 次")
                check("第 \(round) 轮（\(leg)）动画期间重排被冻结（frozen>0 且 layout+draw≤2）",
                      frozen > 0 && relayout <= 2,
                      "frozen=\(frozen) layout+draw=\(relayout)"
                          + "（frozen=0 = 这段根本没重排请求，断言未生效；"
                          + "layout+draw>2 = 冻结没挡住，面板卡顿成因仍在）")
            }

            // 等动画收敛 + setPanelResizing(false) 里那个 async 恢复块跑完
            try? await Task.sleep(nanoseconds: 900_000_000)
            let after = probe()
            check("第 \(round) 轮（\(leg)）退出调整：setPanelResizing(false) 恰好 1 次",
                  after?.trace.exits == round,
                  "exits=\(after?.trace.exits ?? -1)，期望 \(round)")
            check("第 \(round) 轮（\(leg)）结束后 autoScales 恢复为 true",
                  after?.autoScalesNow == true,
                  "实际 \(after?.autoScalesNow.description ?? "nil")（没恢复 = 之后滚动/缩放都不再适宽）")

            NSLog("%@", "[Lumen][panel] 第 \(round) 轮（\(leg)）读数："
                  + "进入时 autoScales=\(after?.trace.autoScalesAtEnter.last.map(String.init) ?? "nil")"
                  + " 恢复目标=\(after?.trace.restoreTargets.last.map(String.init) ?? "nil")"
                  + " 被挡掉的进入=\(after?.trace.ignoredEnters ?? -1)")
        }

        // 恢复目标必须等于进入前的实际值（而不是硬编码 true）
        if let trace = probe()?.trace {
            let pairs = zip(trace.autoScalesAtEnter, trace.restoreTargets)
            let allMatch = pairs.allSatisfy { $0 == $1 }
            check("恢复目标 = 进入前的 autoScales 实际值（不是硬编码 true）",
                  allMatch && trace.restoreTargets.count == 2,
                  "进入时 \(trace.autoScalesAtEnter) vs 恢复目标 \(trace.restoreTargets)")
        }

        // ── ③ 锚点漂移 ──
        if let trace = probe()?.trace,
           trace.anchorAtEnter.count == trace.anchorAtExit.count, !trace.anchorAtEnter.isEmpty {
            for (index, pair) in zip(trace.anchorAtEnter, trace.anchorAtExit).enumerated() {
                let pageSame = pair.0.page == pair.1.page
                let delta = abs(pair.0.progress - pair.1.progress)
                NSLog("%@", "[Lumen][panel] 第 \(index + 1) 轮锚点："
                      + "进入 第\(pair.0.page + 1)页/\(String(format: "%.3f", pair.0.progress)) → "
                      + "退出 第\(pair.1.page + 1)页/\(String(format: "%.3f", pair.1.progress))"
                      + " 漂移 \(String(format: "%.4f", delta))（容差 \(anchorTolerance)）")
                check("第 \(index + 1) 轮滚动锚点未漂移（当前页不变且页内位移 ≤ \(anchorTolerance)）",
                      pageSame && delta <= anchorTolerance,
                      pageSame
                        ? "归一化位移 \(String(format: "%.4f", delta)) > \(anchorTolerance)（补偿逻辑没生效）"
                        : "换了页：\(pair.0.page + 1) → \(pair.1.page + 1)")
            }
        } else {
            NSLog("%@", "[Lumen][panel] ⚠️ 锚点读数不齐（进入 \(probe()?.trace.anchorAtEnter.count ?? -1)"
                  + " / 退出 \(probe()?.trace.anchorAtExit.count ?? -1)），"
                  + "跳过锚点断言——硬跑会把「取不到锚点页」误报成漂移")
        }

        // ── ④ 反向对照：复刻修复前的写法 ──
        //
        // 直接 withAnimation 写状态（不经方法），断言两件事同时**不成立**。
        // 这一组是本通道的「证伪器」：若有人把写入点改回去，① 会红；
        // 若有人把 setPanelResizing 的钉住逻辑删掉，② 会红；若有人把断言写成恒真，
        // 本组会红（因为它期望 false / 0）。
        let entersBefore = probe()?.trace.enters ?? -1
        let frozenBefore = JankTally.shared.snapshot()[.pdfViewFrozen] ?? 0
        let directTarget = !state.isSidebarVisible
        withAnimation(DS.Motion.panel) { state.isSidebarVisible = directTarget }
        try? await Task.sleep(nanoseconds: 150_000_000)
        let directProbe = probe()
        check("反向对照：绕过方法直接改状态时 setPanelResizing 不被调用（证明①非恒真）",
              directProbe?.trace.enters == entersBefore,
              "enters 从 \(entersBefore) 涨到 \(directProbe?.trace.enters ?? -1)"
                  + "（说明有人把 beginPanelTransition 塞进了 withAnimation 之外的公共路径）")
        let frozenDirect = (JankTally.shared.snapshot()[.pdfViewFrozen] ?? 0) - frozenBefore
        check("反向对照：绕过方法时冻结计数不涨（证明 frozen 来自 setPanelResizing 而非恒真）",
              frozenDirect == 0,
              "frozen 涨了 \(frozenDirect) 次（说明别处也在冻结 PDFView 重排，"
                  + "上面那条「重排被冻结」的因果链需要重查）")
        if motionMuted {
            NSLog("%@", "[Lumen][panel] ⚠️ 反向对照跳过「动画中 autoScales 仍为 true」：动效已静音")
        } else {
            check("反向对照：绕过方法时动画进行中 autoScales 仍为 true（= 修复前的屏闪条件）",
                  directProbe?.autoScalesNow == true,
                  "实际 \(directProbe?.autoScalesNow.description ?? "nil")"
                      + "（false = 有人在别处也钉了 autoScales，本通道的因果链需要重查）")
        }

        // 收尾：把状态用方法路径复原，留给后续自检一个干净环境
        try? await Task.sleep(nanoseconds: 700_000_000)
        state.setSidebarVisible(true, animated: false)
        try? await Task.sleep(nanoseconds: 400_000_000)

        NSLog("%@", "[Lumen][panel] 自检：通过 \(passed) 项，失败 \(failures.count) 项"
              + (failures.isEmpty ? " ✅" : " ❌ " + failures.joined(separator: "；")))
    }
}
