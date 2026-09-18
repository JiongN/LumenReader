import Foundation
import SwiftUI
import AppKit
import PDFKit
import LumenKit

// MARK: - 重活计数

/// 连续交互路径上的「重活」种类。每类记一个计数，用来把停顿归因到具体环节。
///
/// 为什么用 enum 而不是散落的静态变量：新增一条计数只改这里一处；
/// 报告按 `allCases` 顺序输出，漏掉哪条一眼能看出来。
enum JankCounter: String, CaseIterable {
    case containerBody = "ReaderContainerView.body"
    case aiPanelBody = "AIPanelView.body"
    case sidebarBody = "SidebarColumn.body"
    case thumbnailPaneBody = "ThumbnailPane.body"
    case updateNSView = "updateNSView(PDFKit)"
    case pdfViewLayout = "PDFView.layout"
    case pdfViewDraw = "PDFView.draw(重绘)"
    case thumbnailRender = "缩略图渲染"
    case positionCallback = "onPositionChange"

    /// watch 日志里的短名（那一行要塞下所有计数器的增量，长名会撑爆）。
    var short: String {
        switch self {
        case .containerBody: return "body"
        case .aiPanelBody: return "ai"
        case .sidebarBody: return "side"
        case .thumbnailPaneBody: return "thumbBody"
        case .updateNSView: return "update"
        case .pdfViewLayout: return "layout"
        case .pdfViewDraw: return "draw"
        case .thumbnailRender: return "thumbR"
        case .positionCallback: return "pos"
        }
    }
}

/// 计数累加器。用锁而不是 `@MainActor`：`PDFView.layout` 理论上可能被非主线程触发，
/// 计数本身不该因此崩掉或漏记。
final class JankTally {
    static let shared = JankTally()
    private var counts: [JankCounter: Int] = [:]
    private let lock = NSLock()

    func bump(_ counter: JankCounter) {
        lock.lock(); counts[counter, default: 0] += 1; lock.unlock()
    }

    func reset() {
        lock.lock(); counts.removeAll(); lock.unlock()
    }

    func snapshot() -> [JankCounter: Int] {
        lock.lock(); defer { lock.unlock() }
        return counts
    }
}

/// 计数入口。`isEnabled` 用 `let` 缓存，避免在 body 热路径里反复解析命令行参数。
///
/// 关掉自检时 `tick` 就是一次静态布尔判断 + 提前 return，开销可忽略；
/// 只有这样才敢把它接在 `body` / `layout` 这种每帧都走的路径上。
///
/// 用法：在视图 `body` 的**第一条语句**写 `let _ = Jank.tick(.xxx)`。
/// 不要做成 `ViewModifier` —— 实测 SwiftUI 会对「结构没变、修饰符值相等」的节点
/// 复用上一次的 `body(content:)` 结果，修饰符里的 tick 只在首次构造时跑一次，
/// 计数恒为 0（本轮踩过）；直接写在 body 里的语句才每次求值都执行。
enum Jank {
    static let isEnabled = CommandLine.arguments.contains("--jank-report")
        || CommandLine.arguments.contains("--jank-watch")

    static func tick(_ counter: JankCounter) {
        guard isEnabled else { return }
        JankTally.shared.bump(counter)
    }
}

// MARK: - 主线程停顿计量

/// 60Hz 定时器测量**它自己的迟到量**（实际间隔 − 16.7ms）。
///
/// 为什么用「定时器迟到」当掉帧代理：主线程一旦被重活占住，排在主队列上的定时器
/// 必然迟发——这个迟到量直接反映「这一帧主线程被占用了多久」，比「某段渲染耗时」
/// 更接近用户的手感。上一轮的 `--perf-report` 量的是**单次渲染代价**，量不到这个。
@MainActor
final class MainStallMeter {

    static let frameMs: Double = 1000.0 / 60.0

    private var timer: DispatchSourceTimer?
    private var lastTick: DispatchTime = .now()
    private var samples: [Double] = []

    var isRunning: Bool { timer != nil }

    func start() {
        guard timer == nil else { return }
        samples.removeAll(keepingCapacity: true)
        lastTick = .now()

        let interval = Self.frameMs / 1000.0
        let source = DispatchSource.makeTimerSource(queue: .main)
        source.schedule(deadline: .now() + interval, repeating: interval, leeway: .nanoseconds(0))
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                let now = DispatchTime.now()
                let deltaMs = Double(now.uptimeNanoseconds - self.lastTick.uptimeNanoseconds) / 1_000_000
                self.lastTick = now
                // 迟到量 = 实际间隔 − 一帧预算。理想情况接近 0（甚至略负，定时器偶尔提前）。
                self.samples.append(deltaMs - Self.frameMs)
            }
        }
        source.resume()
        timer = source
    }

    func stop() -> [Double] {
        timer?.cancel()
        timer = nil
        return samples
    }
}

// MARK: - 卡顿自检主体

/// 连续交互（拖动分隔线 / 触控板滚动）的卡顿自检：`--jank-report 1`。
///
/// 把「手感卡」拆成两个客观读数：
/// 1. **主线程停顿**（p50/p95/max 迟到量）——真实帧预算有没有被占穿。
/// 2. **每步重活计数**——一次拖动/滚动步进，各条热路径各被重算了几次。
///    这一项负责**定位**：比如「一步拖动 = 一次 `PDFView.layout`」就能直接指认
///    「阅读区每帧重排」这个元凶。
///
/// 驱动走**真实路径**：滚动用 `CGEvent` 造像素级滚动事件投给 `PDFView.scrollWheel(with:)`
/// （进程内方法调用，不需要辅助功能权限），拖动直接写分隔线的 `liveWidth` 本地状态
/// ——都是用户手势会走的那条路，不是旁路。
@MainActor
enum JankAudit {

    /// 单帧主线程停顿的目标上限（ms）。迟到超过一帧预算就算掉了一帧。
    static let stallBudgetMs: Double = 16.7

    /// 每个显示帧里模拟几个指针事件。3 ≈ 200Hz 指针 @ 60Hz 屏，
    /// 覆盖「触控板 / 高回报率鼠标的事件率高于屏幕刷新」这一真实情况。
    ///
    /// 之所以要显式模拟：拖动分隔线的元凶如果是「每个指针事件都重排 + 重光栅化」，
    /// 那么把事件率提上去，重活计数就该按比例翻倍；反之若 SwiftUI 已经把同一帧内的
    /// 多次写入合并掉，计数就不会翻——这直接决定「合并写入」这个优化值不值得做。
    static let pointerWritesPerFrame = 3

    static func run(
        scrollSurface: @escaping () -> NSView?,
        setLiveWidth: @escaping (Double?) -> Void,
        committedWidth: Double,
        range: ClosedRange<Double>,
        steps: Int
    ) async {
        NSLog("[Lumen][jank] ── 连续交互卡顿自检（每段 \(steps) 步，帧预算 \(Int(stallBudgetMs))ms）──")

        let meter = MainStallMeter()

        // —— 阶段一：触控板滚动 ——
        // 阅读视图是异步装好的（PDF 要先解析），挂钩子可能晚于本自检启动。
        // 轮询等它出现，别用固定 sleep 赌时序——赌输了会静默跳过整个滚动阶段。
        if let pdfView = await waitForScrollSurface(scrollSurface) as? PDFView {
            logEnvironment(pdfView)
            await verifyDrawCounter(pdfView)
            await measureScroll(pdfView: pdfView, meter: meter, steps: steps)
        } else {
            NSLog("[Lumen][jank] 滚动：等不到 PDFView（可能是 EPUB 或文档未装好），跳过")
        }

        // —— 阶段二：拖动分隔线 ——
        await measureDrag(
            setLiveWidth: setLiveWidth,
            committedWidth: committedWidth,
            range: range,
            meter: meter,
            steps: steps
        )

        // 收尾：把宽度释放回「不在拖」的状态（走与手势结束同一条路径）。
        setLiveWidth(nil)
    }

    // MARK: 第一步：证伪「计数器 / 环境」是否可信

    /// 打印窗口与 App 的可见性状态。
    ///
    /// 存在的理由：AppKit 的 **responsive scrolling** 在窗口不可见 / 被遮挡时会把绘制
    /// 推迟（走 overdraw，甚至把滚动搬到后台线程）。若自检跑在「窗口不在屏上」的条件下，
    /// 「滚动没触发重绘」就只是环境产物，不能当作「滚动不卡」的证据。
    private static func logEnvironment(_ pdfView: PDFView) {
        let window = pdfView.window
        let visible = window?.occlusionState.contains(.visible) ?? false
        NSLog("[Lumen][jank] 环境：窗口 \(window == nil ? "无" : "有")"
            + " key=\(window?.isKeyWindow ?? false) visible=\(window?.isVisible ?? false)"
            + " occlusionVisible=\(visible) appActive=\(NSApp.isActive)"
            + " layerBacked=\(pdfView.wantsLayer)")
    }

    /// 计数器自检：**强制一次确定会发生**的重绘，确认 `PDFView.draw` 真的会 +1。
    ///
    /// 存在的理由：如果这个计数器在任何场景下都恒为 0，那滚动段的读数一律作废——
    /// 必须先排除「计数器坏了」，再谈「滚动到底重绘没重绘」。
    /// 顺带说清楚它**覆盖不到**什么：`draw(_:)` 只在 AppKit 认为这一层需要重画时被调用
    /// （例如视图 frame 变化）。PDFKit 翻页 / 滚动时的**分页光栅化走的是内部文档视图
    /// 的 tiled/layer 绘制路径**，不经过 `PDFView.draw(_:)`——所以本计数器量不到它。
    private static func verifyDrawCounter(_ pdfView: PDFView) async {
        JankTally.shared.reset()
        let before = JankTally.shared.snapshot()[.pdfViewDraw] ?? 0
        pdfView.needsDisplay = true
        pdfView.displayIfNeeded()
        let after = JankTally.shared.snapshot()[.pdfViewDraw] ?? 0
        let ok = after > before
        NSLog("[Lumen][jank] 计数器自检（强制重绘）：PDFView.draw \(before) → \(after) "
            + (ok ? "✅ 能亮" : "❌ 恒为 0——本计数器不可信，滚动段读数作废"))
        NSLog("[Lumen][jank] 计数器覆盖范围：PDFView.draw 只反映「view 被要求重画」"
            + "（frame 变化等）；PDFKit 翻页/滚动的分页光栅化走内部文档视图的 tiled/layer 路径，"
            + "**不经此计数器**——所以滚动段 draw=0 不能推出「滚动没重绘」。")
    }

    /// 进程累计 CPU 时间（所有线程，user+system）。用它当**与线程无关**的工作量旁证：
    /// 若滚动把光栅化丢到后台线程，主线程停顿会是 0，但进程 CPU 时间照样涨。
    /// 主线程停顿低 + 进程 CPU 也低，才是「真的没干活」。
    static func processCPUSeconds() -> Double {
        var usage = rusage()
        guard getrusage(RUSAGE_SELF, &usage) == 0 else { return 0 }
        func seconds(_ tv: timeval) -> Double {
            Double(tv.tv_sec) + Double(tv.tv_usec) / 1_000_000
        }
        return seconds(usage.ru_utime) + seconds(usage.ru_stime)
    }

    /// 最多等 10s 让滚动宿主出现（300ms 一次）。
    private static func waitForScrollSurface(_ provider: () -> NSView?) async -> NSView? {
        for _ in 0..<34 {
            if let surface = provider() { return surface }
            try? await Task.sleep(nanoseconds: 300_000_000)
        }
        return provider()
    }

    // MARK: 滚动

    private static func measureScroll(pdfView: PDFView, meter: MainStallMeter, steps: Int) async {
        // 方向自适应：不同系统 / 触控板的「自然滚动」设置会翻转滚轮事件的符号约定。
        // 写死符号的话，在一半的机器上「往下滚」实际是「往上滚」——文档已在顶部，
        // 于是怎么投事件都滚不动，计数全 0 还自称「通过」（本轮踩过）。
        let sign = await detectScrollSign(pdfView)

        // 归零到文档开头，保证每一轮从同一起点出发（读数可比）。
        pdfView.document.map { doc in
            if doc.pageCount > 0 { pdfView.go(to: doc.page(at: 0)!) }
        }
        try? await Task.sleep(nanoseconds: 300_000_000)

        let offsetBefore = scrollOffsetY(pdfView)
        let pageBefore = currentPageIndex(pdfView)

        JankTally.shared.reset()
        let cpuBefore = processCPUSeconds()
        meter.start()
        for _ in 0..<steps {
            scrollStep(pdfView: pdfView, deltaY: CGFloat(sign) * 30)
            await awaitFrame()
        }
        NSLog("[Lumen][jank] 滚动：投完 \(steps) 步时 页码=\(currentPageIndex(pdfView).map(String.init) ?? "?")"
            + " 偏移=\(fmt(scrollOffsetY(pdfView)))（落定后的回调还没发生，下面等惯性）")
        // 关键：投完事件不能立刻收尾。带精确增量的滚轮会进入「响应式滚动 / 惯性」，
        // PDFKit 的页码变更通知要等滚动落定才发——立刻读计数会全 0（本轮踩过）。
        // 这里再等一段「惯性滑行」，把落定后才产生的回调也纳入统计，更贴近真实手感。
        try? await Task.sleep(nanoseconds: 500_000_000)
        let samples = meter.stop()
        let counts = JankTally.shared.snapshot()
        let cpuSeconds = processCPUSeconds() - cpuBefore

        let offsetAfter = scrollOffsetY(pdfView)
        let pageAfter = currentPageIndex(pdfView)
        report(phase: "滚动", samples: samples, counts: counts, steps: steps, cpuSeconds: cpuSeconds)

        // 解释一行：主线程停顿低 ≠ 没干活。PDFKit 的分页光栅化常在**后台线程**上做，
        // 主线程停顿与 PDFView.draw 都量不到它，只有「进程 CPU 时间」看得见。
        // 这一行专门防止把「主线程不卡」误读成「滚动很轻」。
        let cpuPerStep = cpuSeconds * 1000 / Double(max(steps, 1))
        let stallP95 = stats(samples).p95
        if cpuPerStep > 4 && stallP95 < 4 {
            NSLog(String(
                format: "[Lumen][jank] 滚动：⚠️ 主线程停顿低（p95=%.2fms）但进程 CPU 高（%.2fms/步）"
                    + "——重活在后台线程（PDFKit 分页光栅化），主线程停顿与本通道的 draw 计数都覆盖不到它。"
                    + "「滚动不卡」不能由本段读数推出。",
                stallP95, cpuPerStep
            ))
        }

        // 驱动自证：滚动事件真的把文档滚动了。偏移与页码都看——
        // 偏移是连续的，一个 300px 小步就动；页码要跨过一整页才变，量级太粗。
        let moved = (offsetBefore != offsetAfter) || (pageBefore != pageAfter)
        let before = pageBefore.map(String.init) ?? "?"
        let after = pageAfter.map(String.init) ?? "?"
        NSLog("[Lumen][jank] 滚动驱动自证：页码 \(before) → \(after)，滚动偏移 \(fmt(offsetBefore)) → \(fmt(offsetAfter)) "
            + (moved ? "✅ 确实滚了" : "❌ 没滚动（读数无效）"))
    }

    /// 探一次滚轮符号：试着滚一下，看偏移有没有前进。两个方向都不动就退回 +1
    /// （此时「没滚动」会被自证那句挑明，而不是伪装成一次干净的 0 卡顿）。
    private static func detectScrollSign(_ pdfView: PDFView) async -> Int32 {
        guard let doc = pdfView.document, doc.pageCount > 0 else { return 1 }
        logScrollEventOnce(pdfView)
        for candidate in [Int32(-1), Int32(1)] {
            pdfView.go(to: doc.page(at: 0)!)
            try? await Task.sleep(nanoseconds: 150_000_000)
            let before = scrollOffsetY(pdfView)
            for _ in 0..<10 {
                scrollStep(pdfView: pdfView, deltaY: CGFloat(candidate) * 30)
                await awaitFrame()
            }
            if scrollOffsetY(pdfView) != before { return candidate }
        }
        return 1
    }

    /// PDFView 内部滚动视图的纵向偏移。拿它作滚动动没动的判据，比只看页码灵敏得多。
    fileprivate static func scrollOffsetY(_ pdfView: PDFView) -> CGFloat? {
        firstScrollView(in: pdfView)?.contentView.bounds.origin.y
    }

    private static func firstScrollView(in view: NSView) -> NSScrollView? {
        if let scroll = view as? NSScrollView { return scroll }
        for sub in view.subviews {
            if let found = firstScrollView(in: sub) { return found }
        }
        return nil
    }

    fileprivate static func fmt(_ value: CGFloat?) -> String {
        value.map { String(format: "%.0f", $0) } ?? "?"
    }

    /// 造一个像素级滚动事件，投给 PDFView **内部的 NSScrollView** —— 走真实滚动路径
    /// （含滚动条、回弹、页间布局），不是 `scroll(to:)` 那种旁路。
    ///
    /// 为什么不投给 `PDFView` 本身：`PDFView` 不处理滚轮，它只把事件沿响应链往上传；
    /// 直接调用 `pdfView.scrollWheel(with:)` 等于把事件交给一个不接的人，什么都不会发生
    /// （本轮踩过——页码与滚动偏移纹丝不动，读数全 0 还自称通过）。
    /// 真正消化滚轮事件的是它内部那个 `NSScrollView`，投给它才是「用户滚了一下」。
    private static func scrollStep(pdfView: PDFView, deltaY: CGFloat) {
        guard let cgEvent = CGEvent(
            scrollWheelEvent2Source: nil,
            units: .pixel,
            wheelCount: 1,
            wheel1: Int32(deltaY),
            wheel2: 0,
            wheel3: 0
        ), let event = NSEvent(cgEvent: cgEvent) else { return }

        if let scrollView = firstScrollView(in: pdfView) {
            scrollView.scrollWheel(with: event)
        } else {
            pdfView.scrollWheel(with: event)
        }
    }

    /// 只打一次的诊断：把事件的增量字段与内部滚动视图的几何摊开，
    /// 免得「滚不动」这种情况又要靠猜方向、猜单位、猜投给谁。
    private static var didLogScrollEvent = false

    private static func logScrollEventOnce(_ pdfView: PDFView) {
        guard !didLogScrollEvent else { return }
        didLogScrollEvent = true
        let sv = firstScrollView(in: pdfView)
        let cg = CGEvent(
            scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1,
            wheel1: 30, wheel2: 0, wheel3: 0
        )
        let e = cg.flatMap { NSEvent(cgEvent: $0) }
        NSLog("[Lumen][jank] 滚动事件诊断：units=pixel wheel1=30 → "
            + "scrollingDeltaY=\(e?.scrollingDeltaY ?? -999) deltaY=\(e?.deltaY ?? -999) "
            + "precise=\(e?.hasPreciseScrollingDeltas ?? false) "
            + "phase=\(e.map { String($0.phase.rawValue) } ?? "n/a") "
            + "momentum=\(e.map { String($0.momentumPhase.rawValue) } ?? "n/a")")
        NSLog("[Lumen][jank] 内部滚动视图：\(sv == nil ? "未找到" : "找到")"
            + " contentView.bounds=\(NSStringFromRect(sv?.contentView.bounds ?? .zero))"
            + " documentView.frame=\(NSStringFromRect(sv?.documentView?.frame ?? .zero))"
            + " hasVerticalScroller=\(sv?.hasVerticalScroller ?? false)")
    }

    fileprivate static func currentPageIndex(_ pdfView: PDFView) -> Int? {
        guard let doc = pdfView.document, let page = pdfView.currentPage else { return nil }
        return doc.index(for: page)
    }

    // MARK: 拖动

    private static func measureDrag(
        setLiveWidth: @escaping (Double?) -> Void,
        committedWidth: Double,
        range: ClosedRange<Double>,
        meter: MainStallMeter,
        steps: Int
    ) async {
        // 来回扫一遍：从下限上方 1/4 处到上限下方 1/4 处，覆盖布局真会变的区间。
        let span = range.upperBound - range.lowerBound
        let from = range.lowerBound + span * 0.2
        let to = range.lowerBound + span * 0.8
        let widthBefore = committedWidth

        // 区间塌成一点时，每一步写的都是同一个宽度 → 布局根本不重算，
        // 所有重活计数会假绿成 0。这在本机的表现是：窗口 920pt（最小）+ 侧栏可见时，
        // AI 面板上限被阅读区保底压回到下限 300，`range` 成了 300...300。
        // 必须显式说穿，否则读数看起来像「拖动一点都不卡」。
        if span < 20 {
            NSLog("[Lumen][jank] 拖动：可用区间仅 \(Int(span))pt（\(Int(range.lowerBound))…\(Int(range.upperBound))）"
                + "——分隔线没有可拖动的余量，本段读数无效。请加大 --window-size 重跑。")
        }

        JankTally.shared.reset()
        let cpuBefore = processCPUSeconds()
        meter.start()
        setLiveWidth(from)
        await awaitFrame()
        for step in 1...steps {
            let t = Double(step) / Double(steps)
            let target = from + (to - from) * t
            let previous = from + (to - from) * (Double(step - 1) / Double(steps))

            // 真实指针一个显示帧里会送来**好几个**事件：MacBook 触控板约 90–120Hz、
            // 游戏鼠标上千 Hz，都高于 60Hz 的屏幕刷新。这里照实模拟——
            // 帧内多写几次宽度、每次之间让出调度点，看「每帧重活」会不会随事件数翻倍。
            // 这正是「要不要把宽度写入合并到每个显示刷新一次」的实验依据：
            // 若 3 次写入换来 3 次重排+重绘，合并就是实打实的 3→1。
            for write in 1...Self.pointerWritesPerFrame {
                let fraction = Double(write) / Double(Self.pointerWritesPerFrame)
                setLiveWidth(previous + (target - previous) * fraction)
                if write < Self.pointerWritesPerFrame {
                    await Task.yield()
                }
            }
            await awaitFrame()
        }
        let samples = meter.stop()
        let counts = JankTally.shared.snapshot()
        let cpuSeconds = processCPUSeconds() - cpuBefore

        report(phase: "拖动", samples: samples, counts: counts, steps: steps, cpuSeconds: cpuSeconds)
        NSLog("[Lumen][jank] 拖动驱动自证：宽度 \(Int(widthBefore))pt → \(Int(from))…\(Int(to))pt，"
            + "每帧 \(pointerWritesPerFrame) 次指针写入（走的是与真实手势同一条 liveWidth 写入路径）")
    }

    // MARK: 让出一帧

    /// 让出到下一帧，让 SwiftUI 把这一步的布局真正做掉。
    /// 用 16ms 睡眠而不是 `Task.yield()`：`yield` 只换调度点，不保证主 runloop
    /// 跑完一次布局/绘制；睡一帧才能让「这一步的重活」落在两次采样之间被量到。
    private static func awaitFrame() async {
        try? await Task.sleep(nanoseconds: 16_000_000)
    }

    // MARK: 报文

    private static func report(
        phase: String,
        samples: [Double],
        counts: [JankCounter: Int],
        steps: Int,
        cpuSeconds: Double
    ) {
        let s = stats(samples)
        let over = samples.filter { $0 > stallBudgetMs }.count
        NSLog(String(
            format: "[Lumen][jank] %@：主线程停顿 p50=%.2fms p95=%.2fms max=%.2fms 均值=%.2fms",
            phase, s.p50, s.p95, s.max, s.mean
        ))
        NSLog("[Lumen][jank] %@：停顿 > %.1fms 的采样 = %d / %d（%.0f%%）",
              phase, stallBudgetMs, over, samples.count,
              samples.isEmpty ? 0 : Double(over) / Double(samples.count) * 100)

        // 进程 CPU 时间增量（所有线程）：与主线程停顿互为旁证。
        // 主线程停顿低 + CPU 增量也低 = 真的没干活；主线程停顿低但 CPU 增量高 = 活被丢到了后台线程。
        NSLog(String(
            format: "[Lumen][jank] %@：进程 CPU 时间增量 %.0fms（%.2fms/步，含所有线程）",
            phase, cpuSeconds * 1000, cpuSeconds * 1000 / Double(max(steps, 1))
        ))

        // 每步重活：把总次数除以步数，得到「一步发生几次」——比总数更能指认元凶。
        let perStep = JankCounter.allCases.map { counter -> String in
            let total = counts[counter] ?? 0
            let avg = Double(total) / Double(max(steps, 1))
            return "\(counter.rawValue)=\(total)(\(String(format: "%.2f", avg))/步)"
        }
        NSLog("[Lumen][jank] %@：每步重活（总次数 + 每步均次）  " + perStep.joined(separator: "  "), phase)
    }

    fileprivate struct Stats {
        let p50: Double
        let p95: Double
        let max: Double
        let mean: Double
    }

    fileprivate static func stats(_ samples: [Double]) -> Stats {
        guard !samples.isEmpty else { return Stats(p50: 0, p95: 0, max: 0, mean: 0) }
        let sorted = samples.sorted()
        func percentile(_ p: Double) -> Double {
            let index = min(sorted.count - 1, max(0, Int(Double(sorted.count - 1) * p)))
            return sorted[index]
        }
        let mean = samples.reduce(0, +) / Double(samples.count)
        return Stats(p50: percentile(0.5), p95: percentile(0.95),
                     max: sorted.last ?? 0, mean: mean)
    }
}

// MARK: - 被动监视（真机手势）

/// `--jank-watch 1`：**不驱动任何东西**，正常启动、正常运行，只在后台把卡顿埋点
/// 定期落成日志，交给用户用**真触控板**产生手势来复现。
///
/// 为什么需要它：合成事件（`CGEvent`）复现不了真实触控板的**连续惯性滚动**——
/// 那是 AppKit 响应式滚动 + 后台光栅化的组合，进程内手搓不出来。与其硬凑，不如把
/// 「产生手势」这件事交还给用户，我们只负责把「哪一段出现了停顿尖峰、那一段的重活计数」
/// 记下来。
///
/// 开销纪律（否则埋点本身就成了被测对象）：
/// - 计数走 `JankTally`（`NSLock` 自增），**热路径里不做字符串拼接、不碰 IO**；
/// - 日志统一在**每 2 秒**的汇总时刻写一次文件（`FileHandle` 追加），不在绘制/布局路径里写；
/// - 只读不写：配合 `suppressSave`，跑前跑后 `settings.json` 不变。
@MainActor
final class JankWatch {

    static let shared = JankWatch()
    static let logPath = "/tmp/lumen-jank-watch.log"

    /// 每个汇总行覆盖的时长（秒）。
    private let windowSeconds: Double = 2

    private var timer: DispatchSourceTimer?
    private var started = false

    private var lastTick: DispatchTime = .now()
    private var startTick: DispatchTime = .now()
    private var samples: [Double] = []
    private var tickCount = 0
    private var windowTickTarget = 0

    private var lastCounts: [JankCounter: Int] = [:]
    private var lastCPUSeconds: Double = 0

    private var surface: (() -> NSView?)?
    private var handle: FileHandle?

    func start(surface: @escaping () -> NSView?) {
        guard !started else { return }
        started = true
        self.surface = surface
        startTick = .now()
        lastTick = .now()
        lastCPUSeconds = JankAudit.processCPUSeconds()
        lastCounts = JankTally.shared.snapshot()
        windowTickTarget = max(1, Int((windowSeconds * 1000 / MainStallMeter.frameMs).rounded()))

        openLog()
        writeHeader()

        let interval = MainStallMeter.frameMs / 1000.0
        let source = DispatchSource.makeTimerSource(queue: .main)
        source.schedule(deadline: .now() + interval, repeating: interval, leeway: .nanoseconds(0))
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated { self?.tick() }
        }
        source.resume()
        timer = source
    }

    func stop() {
        guard started else { return }
        started = false
        timer?.cancel()
        timer = nil
        try? handle?.close()
        handle = nil
    }

    // MARK: 采样

    private func tick() {
        let now = DispatchTime.now()
        let deltaMs = Double(now.uptimeNanoseconds - lastTick.uptimeNanoseconds) / 1_000_000
        lastTick = now
        samples.append(deltaMs - MainStallMeter.frameMs)

        tickCount += 1
        if tickCount >= windowTickTarget {
            flush()
            tickCount = 0
            samples.removeAll(keepingCapacity: true)
        }
    }

    private func flush() {
        guard !samples.isEmpty else { return }
        let s = JankAudit.stats(samples)
        let over = samples.filter { $0 > JankAudit.stallBudgetMs }.count

        let counts = JankTally.shared.snapshot()
        let cpuSeconds = JankAudit.processCPUSeconds()
        let cpuDeltaMs = (cpuSeconds - lastCPUSeconds) * 1000
        lastCPUSeconds = cpuSeconds

        let pdfView = surface?() as? PDFView
        let page = pdfView.flatMap { JankAudit.currentPageIndex($0) }
        let offset = pdfView.flatMap { JankAudit.scrollOffsetY($0) }

        let perCounter = JankCounter.allCases.map { counter -> String in
            let now = counts[counter] ?? 0
            let before = lastCounts[counter] ?? 0
            return "\(counter.short)=\(now - before)"
        }.joined(separator: " ")
        lastCounts = counts

        let elapsed = Double(DispatchTime.now().uptimeNanoseconds - startTick.uptimeNanoseconds) / 1_000_000_000
        let line = String(
            format: "+%.1fs 停顿 p50=%.2f p95=%.2f max=%.2f >16.7ms=%d/%d(%.0f%%) | CPU +%.0fms | 页=%@ 偏移=%@ | %@",
            elapsed, s.p50, s.p95, s.max, over, samples.count,
            samples.isEmpty ? 0 : Double(over) / Double(samples.count) * 100,
            cpuDeltaMs,
            page.map(String.init) ?? "?",
            JankAudit.fmt(offset),
            perCounter
        )
        write(line)
    }

    // MARK: 文件

    private func openLog() {
        let path = Self.logPath
        if !FileManager.default.fileExists(atPath: path) {
            FileManager.default.createFile(atPath: path, contents: nil)
        }
        handle = FileHandle(forWritingAtPath: path)
        handle?.seekToEndOfFile()
    }

    private func writeHeader() {
        let stamp = ISO8601DateFormatter().string(from: Date())
        let file = """
        ========================================
        jank watch 开始 @ \(stamp)
        每 \(Int(windowSeconds))s 一行。读数含义：停顿=60Hz 定时器迟到量(ms)，>16.7ms 即掉帧；
        计数器=该窗口内的增量（body/ai/side/thumbBody/update/layout/draw/thumbR/pos）；
        CPU=该窗口内进程所有线程的 CPU 时间增量(ms)。
        用法：正常上下滚动触控板 15–20s，再拖动右侧 AI 面板分隔线 15–20s，然后 ⌘Q 退出。
        ========================================
        """
        write(file)
        NSLog("[Lumen][jank] jank watch 已开启：日志 → \(Self.logPath)（正常交互即可，⌘Q 退出）")
    }

    private func write(_ line: String) {
        if let data = (line + "\n").data(using: .utf8) {
            handle?.write(data)
        }
        // 同时打一行到控制台，方便「确认它真的在跑」。
        NSLog("[Lumen][jank][watch] " + line.replacingOccurrences(of: "\n", with: " / "))
    }
}
