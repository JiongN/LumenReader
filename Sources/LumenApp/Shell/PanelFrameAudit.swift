import Foundation
import AppKit
import SwiftUI
import LumenKit

/// Measures panel actions and their settling period. Timer lateness is not a
/// rendered-frame count; visual blanking must be checked separately.
extension LaunchOptions {
    static var panelFrameReport: Bool { flag("--panel-frame-report") }
}

@MainActor
enum PanelFrameAudit {

    /// 动画段时长。spring(response: 0.34) ≈ 0.4s 收敛，取 0.55s 留余量。
    private static let animWindow: Double = 0.55
    /// 落定段时长：收尾重排与重光栅化常常拖在动画之后。
    private static let settleWindow: Double = 1.0

    /// 重复轮数。默认 2；定位时加大到 6–8 轮。
    ///
    /// 为什么需要它：那记几百毫秒的堵塞**是随机的**（同一份构建、同一次运行里，
    /// 8 次切换中只出现 2–3 次）。只跑两轮时「某档没有巨块」很可能是没碰上，
    /// 而不是真的消除了——把轮数加上去、比**出现率**才有统计意义。
    private static var rounds: Int {
        guard let raw = LaunchOptions.value(for: "--panel-rounds"),
              let n = Int(raw), n >= 1 else { return 2 }
        return min(n, 10)
    }

    static func run(state: AppState) async {
        // 与 PanelTransitionAudit 同款节奏：等布局稳定、等文档装好。
        try? await Task.sleep(nanoseconds: 2_600_000_000)

        let meter = MainStallMeter()
        let originalSidebar = state.isSidebarVisible
        let originalAI = state.isAIPanelVisible
        NSLog("%@", "[Lumen][panelFrame] Production panel path; PDF geometry updates without width animation")

        // 空闲基线：同样的采样时长、什么都不做。
        //
        // 没有它就没法判断「p95=30ms」到底是卡还是这台机器的底噪
        // （实测空闲底噪 p95 也有 0.8–1.0ms，max 偶尔几十 ms）。
        JankTally.shared.reset()
        meter.start()
        let idle = await sample(meter, seconds: 1.0)
        report("空闲基线（1.0s 什么都没做）", samples: idle, cpuBefore: nil)

        typealias Leg = (name: String, set: (Bool) -> Void, isOn: () -> Bool)
        let legs: [Leg] = [
            ("侧栏", { state.setSidebarVisible($0, animated: true) }, { state.isSidebarVisible }),
            ("AI面板", { state.setAIPanelVisible($0, animated: true) }, { state.isAIPanelVisible })
        ]

        var bigStalls = 0
        var switchCount = 0
        for round in 1...rounds {
            for leg in legs {
                // 先收起再展开，两向都量：收起时阅读区变宽、展开时变窄，
                // 两条方向的重排代价并不对称（适宽倍率一个变大一个变小）。
                let collapse = leg.isOn()
                for (phaseName, target) in [("收起", !collapse), ("展开", collapse)] {
                    if leg.isOn() == target {
                        NSLog("%@", "[Lumen][panelFrame] 跳过 \(leg.name) \(phaseName)：已是目标状态")
                        continue
                    }
                    try? await Task.sleep(nanoseconds: 400_000_000)
                    let cpuBefore = JankAudit.processCPUSeconds()
                    JankTally.shared.reset()
                    meter.start()
                    leg.set(target)
                    let animSamples = await sample(meter, seconds: animWindow)
                    report("第\(round)轮 \(leg.name)\(phaseName)·动画段", samples: animSamples, cpuBefore: cpuBefore)
                    switchCount += 1
                    // 「巨块」判据：动画段里出现过一次 > 150ms 的停顿。
                    // 150ms 而不是预算 16.7ms：正常掉帧是 20–80ms 量级，
                    // 而用户看到的「卡一下」是几百毫秒那一档，两者要分开数。


                    let cpuSettle = JankAudit.processCPUSeconds()
                    JankTally.shared.reset()
                    meter.start()
                    let settleSamples = await sample(meter, seconds: settleWindow)
                    report("第\(round)轮 \(leg.name)\(phaseName)·落定段", samples: settleSamples, cpuBefore: cpuSettle)
                    if (animSamples + settleSamples).contains(where: { $0 > 150 }) { bigStalls += 1 }
                }
            }
        }

        NSLog("%@", String(
            format: "[Lumen][panelFrame] 汇总：%d 次切换里 %d 次出现 >150ms 的巨块停顿（%.0f%%）",
            switchCount, bigStalls, switchCount == 0 ? 0 : Double(bigStalls) / Double(switchCount) * 100
        ))

        // 收尾复原，留给后续自检干净环境
        state.setSidebarVisible(originalSidebar, animated: false)
        state.setAIPanelVisible(originalAI, animated: false)
    }

    private static func sample(_ meter: MainStallMeter, seconds: Double) async -> [Double] {
        try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
        return meter.stop()
    }

    private static func report(_ label: String, samples: [Double], cpuBefore: Double?) {
        let s = Self.stats(samples)
        let over = samples.filter { $0 > JankAudit.stallBudgetMs }.count
        let pct = samples.isEmpty ? 0 : Double(over) / Double(samples.count) * 100
        let cpu = cpuBefore.map { (JankAudit.processCPUSeconds() - $0) * 1000 } ?? -1

        let counts = JankTally.shared.snapshot()
        func n(_ c: JankCounter) -> Int { counts[c] ?? 0 }

        NSLog("%@", String(
            format: "[Lumen][panelFrame] %@：停顿 p50=%.2f p95=%.2f max=%.2f ms |"
                + " >%.1fms %d/%d（%.0f%%） | CPU %@ | body=%d layout=%d draw=%d"
                + " rail=%d side=%d ai=%d thumbR=%d",
            label, s.p50, s.p95, s.max, JankAudit.stallBudgetMs, over, samples.count, pct,
            cpu < 0 ? "  n/a" : String(format: "+%.0fms", cpu),
            n(.containerBody), n(.pdfViewLayout), n(.pdfViewDraw),
            n(.sidebarRailBody), n(.sidebarBody), n(.aiPanelBody), n(.thumbnailRender)
        ))
    }

    // MARK: - 统计

    private struct Stats { let p50: Double; let p95: Double; let max: Double }

    private static func stats(_ samples: [Double]) -> Stats {
        guard !samples.isEmpty else { return Stats(p50: 0, p95: 0, max: 0) }
        let sorted = samples.sorted()
        func at(_ p: Double) -> Double {
            let index = min(sorted.count - 1, max(0, Int((Double(sorted.count) * p).rounded(.up)) - 1))
            return sorted[index]
        }
        return Stats(p50: at(0.5), p95: at(0.95), max: sorted.last ?? 0)
    }
}
