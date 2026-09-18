import AppKit
import Combine

/// 拖动分隔线期间的「即时面板宽度」，**每个显示刷新只应用一次**。
///
/// 为什么需要它（实测数据说话）：
///
/// 拖动分隔线时，指针事件率通常**高于屏幕刷新率**——MacBook 触控板约 90–120Hz，
/// 游戏鼠标可到上千 Hz，而屏幕只有 60Hz（ProMotion 120Hz）。若每个指针事件都写一次
/// `liveAIPanelWidth`，就换来一次「整棵三栏容器重排 + PDFView 重新布局 + 整页重光栅化」。
/// `--jank-report` 的读数（每帧 3 次指针写入）：
///
///     ReaderContainerView.body=181(3.02/步)  PDFView.layout=168(2.80/步)  PDFView.draw=168(2.80/步)
///
/// 即：**一个显示帧里的 3 个指针事件 → 3 次重光栅化**。SwiftUI 不会把跨调度点的多次
/// 写入合并（同一 runloop 内的才合并），所以这件事只能由数据源这侧来管。
///
/// 修法：把「写入」与「应用」解耦。指针事件只更新 `pending`；用一个 `CADisplayLink`
/// 在每个显示刷新到来时把最新的 `pending` 应用一次。屏幕本来就只按刷新率显示，
/// 用户**看不出任何差别**，但重活从「按指针事件率」降到「按刷新率」——
/// 120Hz 触控板下就是 2× ，高回报率鼠标下提升更大。
///
/// 这不改变「拖动期间不写设置」的原则（见 `PanelResizeHandle`）：合并的是本地即时宽度，
/// 落库仍只在松手时发生一次。
@MainActor
final class LivePanelWidth: ObservableObject {

    /// 是否把写入合并到显示刷新。默认开；`--jank-no-coalesce 1` 关掉它做证伪对照。
    private let coalescesFrames: Bool

    init(coalescesFrames: Bool = true) {
        self.coalescesFrames = coalescesFrames
    }

    /// 已应用的即时宽度。`nil` 表示当前没在拖，布局应当用落库值。
    @Published private(set) var value: Double?

    /// 最近一次写入、但尚未在显示刷新上应用的值。
    private var pending: Double?

    /// 显示刷新定时器。仅在拖动期间存在。
    private var link: CADisplayLink?

    /// 指针写入入口。传入 `nil` 表示手势结束。
    ///
    /// 非 nil：只登记 `pending`，等下一个显示刷新统一应用。
    /// nil：**立刻**结束（不能等下一帧）——手势已经结束，布局要马上回到落库值，
    /// 否则会看到宽度在松手后还多停一帧。
    func submit(_ newValue: Double?) {
        // 证伪对照：关掉合并时退化成「每个事件都直接应用」。
        guard coalescesFrames else {
            pending = nil
            stop()
            if value != newValue { value = newValue }
            return
        }

        guard let newValue else {
            pending = nil
            stop()
            if value != nil { value = nil }
            return
        }
        pending = newValue
        start()
    }

    private func start() {
        guard link == nil else { return }
        // 拿不到屏幕（极端的无显示环境）时退化为「立即应用」，功能不受影响，
        // 只是失去了合并——宁可多花一点，也不要让分隔线拖不动。
        guard let screen = NSScreen.main else {
            applyPending()
            return
        }
        let link = screen.displayLink(target: self, selector: #selector(onFrame))
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    private func stop() {
        link?.invalidate()
        link = nil
    }

    @objc private func onFrame() {
        applyPending()
    }

    private func applyPending() {
        guard let next = pending else { return }
        pending = nil
        // 值没变就不发通知，避免无谓的失效。
        if value != next { value = next }
    }
}
