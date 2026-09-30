import SwiftUI
import AppKit
import LumenKit

/// 三栏在某一时刻的**显示宽度**。
///
/// 与「用户存了多少」是两件事：设置里存的是偏好，这里给的是**这一轮布局**
/// 实际要给多少。左右面板各有偏好，窄窗口按阅读区保底动态收窄。
struct PanelLayout {
    /// nil = 这一栏当前不参与布局
    var sidebar: Double?
    var aiPanel: Double?
    /// 阅读区实际分到的宽度
    var reader: Double
    /// 窗口窄到连两侧下限都装不下：已放弃「阅读区保底 320pt」，正文被压
    var isReaderBelowGuarantee: Bool
    /// 为了不让图标栏被顶出屏幕，把面板压到了下限以下（比应用最小窗口还窄才会发生）
    var isSqueezedBelowMinimum: Bool

    var description: String {
        var text = "侧栏 \(sidebar.map { "\(Int($0))pt" } ?? "隐藏")"
            + " / AI \(aiPanel.map { "\(Int($0))pt" } ?? "隐藏")"
            + " / 阅读区 \(Int(reader))pt"
        if isReaderBelowGuarantee { text += "（阅读区已低于保底）" }
        if isSqueezedBelowMinimum { text += "（面板已压过下限）" }
        return text
    }
}

/// 面板宽度的换算。
///
/// 收成一个枚举而不是散在 `ReaderContainerView` 与 `ResizeAudit` 里各写一份：
/// 拖拽上限、显示宽度、自检断言必须走**同一条算式**，否则自检验的是一段死代码——
/// 「改了算式只改一处」正是这类断言最容易悄悄失效的方式。
///
/// 左右面板分别可拖；优先保证阅读区保底，再给两侧各自的最小宽度。
///
/// ## 为什么每次布局都要重算（而不是只在拖拽提交那一刻钳一次）
///
/// 钳制只发生在拖拽提交那一刻是不够的：窗口被拉小时**没有任何一次提交**，
/// 落库的旧宽度会原样参与布局。实测 920pt 窗口下不改会挤到阅读区低于保底，
/// 再窄一点图标栏被推到 x = −97——切页签的入口直接跑到屏幕外。
///
/// ## 为什么重算不等于覆写
///
/// 这里只做换算，**不写任何设置**。落库值仍是用户拖出来的那个数，
/// 算出的只是「此刻能显示多少」，窗口拉回原尺寸偏好自然回来。
/// 若把钳制值直接写回设置，用户把窗口拉回去之后宽度就永远丢了。
enum PanelWidthPolicy {

    /// 阅读区至少要留这么宽。
    ///
    /// 这一条是**上限随窗口收窄**的依据，不是保证——窗口实在太窄时下限优先，
    /// 此时只能让正文被压一点（总好过面板点不到）。
    static var minimumReaderWidth: Double { UISettings.PanelWidth.minimumReaderWidth }

    /// 分隔线的真实命中宽度。零宽容器的 overlay 实际只剩细线可抓；
    /// 给 12pt 布局命中区，窄窗口时由侧栏动态让出空间保留正文 320pt。
    static let handleWidth: Double = 12

    /// 侧栏默认宽度。
    static var fixedSidebarWidth: Double { UISettings.PanelWidth.sidebarDefault }

    /// 量出三栏此刻各该多宽。
    ///
    /// 分配顺序：侧栏（若可见）先足额拿走 248pt；AI 面板拿「剩下的、但不超过它自己要的、
    /// 且不低于下限」；阅读区拿最后剩下的。装不下时：
    ///
    /// 1. AI 面板顶到自己的下限，阅读区让位（**降级**，`isReaderBelowGuarantee` 置位）；
    /// 2. 若连两侧之和都超过预算（容器窄到 920 以下），最后一道闸等比压缩两侧，
    ///    宁可面板比下限还窄，也不让图标栏被顶出屏幕（`isSqueezedBelowMinimum` 置位）。
    ///
    /// - Parameters:
    ///   - sidebarVisible: 侧栏内容面板当前是否在版面上（沉浸 / 收起时为 false）。
    ///   - aiPanelPreferred: 用户这一刻想要的 AI 面板宽度；nil = 面板不参与布局。
    static func resolve(
        containerWidth: CGFloat,
        showsRail: Bool,
        sidebarVisible: Bool,
        aiPanelPreferred: Double?,
        sidebarPreferred: Double? = nil
    ) -> PanelLayout {
        let scale = Double(DS.Size.windowScale(for: containerWidth))
        let aiRange = (UISettings.PanelWidth.aiRange.lowerBound * scale)...(UISettings.PanelWidth.aiRange.upperBound * scale)
        let sidebarRange = (UISettings.PanelWidth.sidebarRange.lowerBound * scale)...(UISettings.PanelWidth.sidebarRange.upperBound * scale)
        let sidebarWidth = clamped((sidebarPreferred ?? fixedSidebarWidth) * scale, to: sidebarRange)

        // 容器宽度还没量到（首帧、视图尚未出现）时不做任何压缩：
        // 此时 containerWidth 是 0，按它算会把两侧压成 0pt，界面先闪一下空面板。
        guard containerWidth > 1 else {
            return PanelLayout(
                sidebar: sidebarVisible ? sidebarWidth : nil,
                aiPanel: aiPanelPreferred.map { clamped($0 * scale, to: aiRange) },
                reader: 0,
                isReaderBelowGuarantee: false,
                isSqueezedBelowMinimum: false
            )
        }

        let railWidth: Double = showsRail ? Double(LeftRail.width) * scale : 0
        // 两侧各有一条 12pt 分隔线，必须从可用宽度里扣除。
        let handleCount = (aiPanelPreferred == nil ? 0 : 1) + (sidebarVisible ? 1 : 0)
        // 扣掉图标栏与分隔线之后，面板与阅读区总共能分到的量
        let budget = max(0, Double(containerWidth) - railWidth - handleWidth * Double(handleCount))
        // 面板能拿走、且阅读区仍保底 320pt 的上限
        let available = budget - minimumReaderWidth

        // 两侧都要保住下限和正文宽度；拖左侧时为右侧至少留出 AI 下限。
        let sidebarLimit = available - (aiPanelPreferred == nil ? 0 : aiRange.lowerBound)
        var sidebar: Double? = sidebarVisible
            ? min(sidebarWidth, max(sidebarRange.lowerBound, sidebarLimit)) : nil
        var aiPanel: Double? = nil
        var belowGuarantee = false

        if let wantedAI = aiPanelPreferred {
            let wantAI = clamped(wantedAI * scale, to: aiRange)
            let remaining = available - (sidebar ?? 0)
            if remaining >= aiRange.lowerBound {
                aiPanel = min(wantAI, remaining)
            } else {
                // 装不下 AI 面板的下限：下限优先，阅读区让位（降级）。
                // 这不是「按窗口等比缩 AI」——AI 面板窄到 300 以下时 footer 会换行，
                // 所以下限是硬的，让的只能是阅读区保底。
                aiPanel = aiRange.lowerBound
                belowGuarantee = true
            }
        }

        // 最后一道闸：图标栏的 x 必须 ≥ 0。
        //
        // 上面的降级允许阅读区被压到保底以下，但不允许**面板把图标栏顶出屏幕**。
        // 窗口窄到 920pt 以下时（正常交互到不了，脚本改窗口尺寸可以），
        // 侧栏 248 + AI 下限 300 加起来就已经超出容器了。此时宁可让面板比下限还窄：
        // 面板窄是难用，图标栏跑到屏幕外是「切页签的入口消失了」，后者严重得多。
        var squeezed = false
        let used = (sidebar ?? 0) + (aiPanel ?? 0)
        if used > budget, used > 0 {
            let scale = budget / used
            sidebar = sidebar.map { $0 * scale }
            aiPanel = aiPanel.map { $0 * scale }
            squeezed = true
        }

        let finalUsed = (sidebar ?? 0) + (aiPanel ?? 0)
        return PanelLayout(
            sidebar: sidebar,
            aiPanel: aiPanel,
            reader: max(0, budget - finalUsed),
            isReaderBelowGuarantee: belowGuarantee,
            isSqueezedBelowMinimum: squeezed
        )
    }

    /// AI 面板此刻最多能拖到多宽。
    ///
    /// 把 AI 面板的需求顶到静态上限、再按正常分支走一遍——上限与显示宽度
    /// 必须是同一条算式，否则会出现「拖到 500 松手、画面停在 480」这种
    /// 拖了没反馈的毛病。
    static func aiCap(
        containerWidth: CGFloat,
        showsRail: Bool,
        sidebarVisible: Bool,
        sidebarPreferred: Double? = nil
    ) -> Double {
        let scale = Double(DS.Size.windowScale(for: containerWidth))
        let upper = UISettings.PanelWidth.aiRange.upperBound
        return resolve(
            containerWidth: containerWidth,
            showsRail: showsRail,
            sidebarVisible: sidebarVisible,
            aiPanelPreferred: upper,
            sidebarPreferred: sidebarPreferred
        ).aiPanel ?? upper * scale
    }

    static func sidebarCap(containerWidth: CGFloat, showsRail: Bool, aiPanelVisible: Bool) -> Double {
        let scale = Double(DS.Size.windowScale(for: containerWidth))
        let rail = showsRail ? Double(LeftRail.width) * scale : 0
        let reservedAI = aiPanelVisible ? UISettings.PanelWidth.aiRange.lowerBound * scale : 0
        let handles = handleWidth * (aiPanelVisible ? 2 : 1)
        let available = Double(containerWidth) - rail - handles - minimumReaderWidth - reservedAI
        return max(UISettings.PanelWidth.sidebarRange.lowerBound * scale,
                   min(UISettings.PanelWidth.sidebarRange.upperBound * scale, available))
    }

    private static func clamped(_ value: Double, to range: ClosedRange<Double>) -> Double {
        guard value.isFinite else { return range.lowerBound }
        return min(max(value, range.lowerBound), range.upperBound)
    }
}

/// 面板之间那条「可以拖」的分隔线。
///
/// 左右面板共用；方向由 `panelIsLeading` 决定。
///
/// 三个关键决定，都不是随意选的：
///
/// 1. **布局命中区 12pt，视觉线 1pt。**
///    零宽 overlay 在真实界面中太难抓取；命中区参与布局，面板上限扣除它。
///
/// 2. **拖动期间只写本地状态，不加动画。** 两点一起说：
///    - 不加动画：套上 `withAnimation` 的话面板会「追」着鼠标走，手感发飘，
///      像在拖一个系了皮筋的东西。只有「双击复位」才用动画。
///    - 不写设置：宽度存在 `SettingsStore.settings`（`@Published` 的整个结构体）里，
///      每帧写一次会让**所有**观察 `SettingsStore` 的视图整棵失效——
///      阅读区（PDFKit / WKWebView）与两块 `.regularMaterial` 背景都在其中，
///      于是拖动手感变成抖动。拖动期间改由 `liveWidth` 这份本地状态驱动布局，
///      松手时才提交一次。
///
/// 3. **用增量，不用绝对位置。** 若把鼠标的全局 x 直接当成宽度，由于分隔线与面板
///    之间还有内边距、外侧还有别的栏，接手的第一帧必然跳一下。记下按下时的宽度
///    再加位移最稳。
struct PanelResizeHandle: View {

    /// 当前显示宽度（= 落库值经窗口上限重算后的结果）。拖动期间**不写**它。
    ///
    /// 用显示值而不是落库值做拖动起点：窄窗口下落库值可能大于此刻能显示的宽度，
    /// 从落库值起算的话第一帧会先跳到上限，手感上就是「刚按下就弹了一下」。
    let committedWidth: Double
    /// 拖动过程中的即时宽度，由容器持有一份本地 `@State`。
    /// `nil` 表示当前没在拖，布局应当用 `committedWidth`。
    @Binding var liveWidth: Double?
    /// 当前允许的上下限。上限按窗口宽度动态收窄（`PanelWidthPolicy`），
    /// 因此每次求值都重新算，不是常量。
    let range: ClosedRange<Double>
    let defaultWidth: Double
    /// 面板位于分隔线左侧时为 `true`（侧栏），右侧为 `false`（AI 面板）。
    /// 决定拖动方向的正负——鼠标右移，对左侧面板是变宽，对右侧面板是变窄。
    let panelIsLeading: Bool
    /// 松手（或双击复位）时的提交动作。走 `SettingsStore.commit*Width`，
    /// 与设置页、自检通道共用同一道钳制闸。
    let onCommit: (Double) -> Void
    var onDragStateChange: (Bool) -> Void = { _ in }

    @State private var isHovering = false
    /// 按下那一刻的宽度。nil 表示当前没有在拖。
    @State private var widthAtDragStart: Double?

    /// 命中区宽度：够大才好抓，又不至于盖住相邻控件。
    private let hitWidth: CGFloat = CGFloat(PanelWidthPolicy.handleWidth)

    private var isDragging: Bool { liveWidth != nil }
    private var isActive: Bool { isHovering || isDragging }

    var body: some View {
        Color.clear
            // 命中区真实参与布局；视觉线仍只画在中间。
            .frame(width: PanelWidthPolicy.handleWidth)
            .frame(maxHeight: .infinity)
            .background(DS.Palette.surfaceSunken)
            .overlay {
                Rectangle()
                    .fill(lineColor)
                    // 视觉比 1pt 粗只在拖动 / 悬停时——overlay 不参与布局，不会推挤三栏
                    .frame(width: isDragging ? 2.5 : (isHovering ? 1.5 : 1))
            }
            .overlay {
                // 透明的加宽命中区。放在 overlay 里是为了既不改布局，
                // 又能吃到比视觉线宽得多的鼠标事件。
                Color.clear
                    .frame(width: hitWidth)
                    .contentShape(Rectangle())
                    .onHover(perform: handleHover)
                    .gesture(dragGesture)
                    .onTapGesture(count: 2, perform: resetToDefault)
            }
            .onReceive(NotificationCenter.default.publisher(for: NSWindow.didResignKeyNotification)) { _ in cancelDrag() }
            .onDisappear { cancelDrag(); handleHover(false) }
            .help("拖动调整宽度，双击复位")
            .accessibilityLabel(panelIsLeading ? "侧栏宽度" : "AI 面板宽度")
    }

    private var lineColor: Color {
        if isDragging { return DS.Palette.accent }
        if isHovering { return DS.Palette.accent.opacity(0.55) }
        return DS.Palette.separator
    }

    private var dragGesture: some Gesture {
        DragGesture(minimumDistance: 1, coordinateSpace: .global)
            .onChanged { value in
                if widthAtDragStart == nil {
                    // 起点取**已提交值**而不是「设置里当前的宽度」：
                    // 后者在极端情况下（窗口刚被改小、上限刚收窄）可能与
                    // 正在显示的宽度不一致，接手那一帧就会跳一下。
                    widthAtDragStart = committedWidth
                    onDragStateChange(true)
                }
                guard let start = widthAtDragStart else { return }
                let delta = panelIsLeading ? value.translation.width : -value.translation.width
                // 钳制放在写入这一侧，而不是只依赖设置解码时的钳制：
                // 拖到边界时要立刻停住，不能让中间态越界（越界期间阅读区会被压成负宽）。
                liveWidth = PanelDragGeometry.width(start: start, delta: delta, range: range)
            }
            .onEnded { value in
                if let start = widthAtDragStart {
                    let delta = panelIsLeading ? value.translation.width : -value.translation.width
                    onCommit(PanelDragGeometry.width(start: start, delta: delta, range: range))
                }
                liveWidth = nil
                widthAtDragStart = nil
                onDragStateChange(false)
            }
    }

    private func cancelDrag() {
        guard widthAtDragStart != nil else { return }
        liveWidth = nil
        widthAtDragStart = nil
        onDragStateChange(false)
    }

    private func resetToDefault() {
        withAnimation(DS.Motion.panel) { onCommit(defaultWidth) }
    }

    private func handleHover(_ inside: Bool) {
        guard isHovering != inside else { return }
        isHovering = inside
        // Hover events can be lost when the divider is removed during a panel
        // transition. push/pop would leave an unmatched cursor on the global
        // stack, making the pointer switch unpredictably over the PDF.
        (inside ? NSCursor.resizeLeftRight : NSCursor.arrow).set()
    }
}
