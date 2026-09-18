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
/// 修法：把「写入」与「应用」解耦。指针事件只更新 `pending`；用一个 **60Hz 合并节拍**
/// 把最新的 `pending` 应用一次。屏幕本来就只按刷新率显示，用户**看不出任何差别**，
/// 但重活从「按指针事件率」降到「按刷新率」——120Hz 触控板下就是 2× ，高回报率鼠标下更大。
///
/// 这不改变「拖动期间不写设置」的原则（见 `PanelResizeHandle`）：合并的是本地即时宽度，
/// 落库仍只在松手时发生一次。
///
/// ## 节拍为什么是 `DispatchSourceTimer` 而不是 `CADisplayLink`（本轮改的，附证据）
///
/// 最初用的是 `NSScreen.displayLink(target:selector:)`——它跟屏幕刷新对齐，理论上更"准"。
/// 但它的回调由 **CoreAnimation 驱动**，而 CA 在**窗口被判定为遮挡 / 应用非激活 / 屏幕休眠**
/// 时会**静默停发**。实测（`--jank-report` 新增的计数，同一份 release 构建）：
///
///     拖动驱动自证：写入 181 次 → 实际应用 1 次；显示刷新回调 0 次；容器重算 1 次
///
/// 也就是说：**整段拖动里 CADisplayLink 一次都没回调**。后果有两层——
/// 1. **功能上**：`pending` 永远等不到应用 → 拖动期间面板根本不跟手（窗口被遮挡时拖分隔线，
///    面板纹丝不动）。真实拖动通常窗口在前台，所以平时不发作；但这属于"一遮挡就坏"的脆弱。
/// 2. **读数上**：自检的"每步重活"全归 0，看起来像"拖动一点都不卡"，其实是**链路没跑**。
///    更糟的是它让"同一份构建、同一条命令"两次跑出 67 与 0 两个极端（A/B 之谜的答案）。
///
/// 换成主队列 `DispatchSourceTimer`（60Hz）之后：
/// - **只要主队列在跑就一定触发**，与 CA / 遮挡无关（同文件的 `MainStallMeter` 就是这套，
///   实测一次 1.6s 的驱动里回调了 97 次，稳定）；
/// - 合并语义不变：仍是"每 ~16.7ms 最多应用一次"，且 `DispatchSourceTimer` 会**合并补偿**
///   错过的触发（不会补发一串），与掉帧时的自然合并行为一致；
/// - 唯一牺牲的是"与 vsync 严格对齐"——但宽度是**布局输入**，不是正在播放的动画，
///   错开不到一帧的相位用户看不出来，换来的是"任何环境下都不冻结"。
@MainActor
final class LivePanelWidth: ObservableObject, LiveWidthApplying {

    /// 合并节拍周期：1/60 秒。与 `MainStallMeter` 同源（都以"一帧"为单位）。
    static let tickInterval: Double = 1.0 / 60.0

    /// 是否把写入合并到显示刷新。默认开；`--jank-no-coalesce 1` 关掉它做证伪对照。
    private let coalescesFrames: Bool

    init(coalescesFrames: Bool = true) {
        self.coalescesFrames = coalescesFrames
    }

    /// 已应用的即时宽度。`nil` 表示当前没在拖，布局应当用落库值。
    @Published private(set) var value: Double?

    /// 最近一次写入、但尚未在节拍上应用的值。
    private var pending: Double?

    /// 合并节拍定时器。仅在拖动期间存在。
    private var ticker: DispatchSourceTimer?

    // MARK: - 自检计数（`LiveWidthApplying`）

    /// 指针写入次数。**证明「写发生了」**。
    private(set) var submitCount = 0
    /// `value` **实际改变**的次数——这才是「触发了一次布局失效」的次数。
    /// 值没变时不发通知（见 `applyPending`），所以它 ≤ `tickCount`。
    private(set) var appliedCount = 0
    /// 合并节拍回调被调用的次数。**证明「合并链路真的跑了」**。
    /// 它与 `appliedCount` 一起，把两种"0"分开：没触发节拍（链路没跑）vs 触发了但值没变。
    private(set) var tickCount = 0

    /// 指针写入入口。传入 `nil` 表示手势结束。
    ///
    /// 非 nil：只登记 `pending`，等下一个合并节拍统一应用。
    /// nil：**立刻**结束（不能等下一次节拍）——手势已经结束，布局要马上回到落库值，
    /// 否则会看到宽度在松手后还多停一拍。
    func submit(_ newValue: Double?) {
        submitCount += 1

        // 证伪对照：关掉合并时退化成「每个事件都直接应用」。
        guard coalescesFrames else {
            pending = nil
            stop()
            if value != newValue { value = newValue; appliedCount += 1 }
            return
        }

        guard let newValue else {
            pending = nil
            stop()
            if value != nil { value = nil; appliedCount += 1 }
            return
        }
        pending = newValue
        start()
    }

    /// 立刻把待应用值落下来（不等下一个节拍）。
    ///
    /// 给自检收尾用：驱动跑完最后一步时，`pending` 可能还没被任何一次节拍取走；
    /// 不显式落一次就取计数，会把「还没应用」误读成「没有重活」。正常运行时**不需要**
    /// 调它——拖动期间每次节拍都会自然消费掉 `pending`。
    func flushNow() {
        applyPending()
    }

    // MARK: - 合并节拍

    private func start() {
        guard ticker == nil else { return }
        let source = DispatchSource.makeTimerSource(queue: .main)
        source.schedule(
            deadline: .now() + Self.tickInterval,
            repeating: Self.tickInterval,
            leeway: .milliseconds(1)
        )
        source.setEventHandler { [weak self] in
            // 主队列定时器：闭包确实跑在主线程，但编译器不认，需要显式声明。
            // 与 `MainStallMeter` 同一写法。
            MainActor.assumeIsolated { self?.onTick() }
        }
        source.resume()
        ticker = source
    }

    private func stop() {
        ticker?.cancel()
        ticker = nil
    }

    private func onTick() {
        tickCount += 1
        applyPending()
    }

    private func applyPending() {
        guard let next = pending else { return }
        pending = nil
        // 值没变就不发通知，避免无谓的失效。
        if value != next { value = next; appliedCount += 1 }
    }
}
