import SwiftUI
import AppKit
import LumenKit

/// 三栏在某一时刻的**显示宽度**。
///
/// 与「用户存了多少」是两件事：设置里存的是偏好，这里给的是**这一轮布局**
/// 实际要给多少。窗口被拉小之后，两侧偏好加起来可能已经超过窗口能给的，
/// 差额必须有人让——让的是面板，不是阅读区，更不是图标栏。
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
/// ## 为什么每次布局都要重算
///
/// 钳制只发生在拖拽提交那一刻是不够的：窗口被拉小时**没有任何一次提交**，
/// 落库的旧宽度会原样参与布局。实测 920pt 窗口下阅读区只剩 266pt，
/// 再窄一点图标栏被推到 x = −97——切页签的入口直接跑到屏幕外。
///
/// ## 为什么重算不等于覆写
///
/// 这里只做换算，**不写任何设置**。落库值仍是用户拖出来的那个数，
/// 算出的只是「此刻能显示多少」，窗口拉回原尺寸偏好自然回来。
/// 若把钳制值直接写回设置，用户把窗口拉回去之后宽度就永远丢了。
enum PanelWidthPolicy {

    /// 谁的宽度「说多少就是多少」，差额由对侧吸收。
    ///
    /// 拖动时是被拖的那一侧——分隔线必须跟着鼠标走，否则手感像在拖一根皮筋。
    /// 不拖动时固定是侧栏（见 `resolve` 的默认值）。
    enum PinnedSide {
        case sidebar
        case aiPanel
    }

    /// 阅读区至少要留这么宽。
    ///
    /// 面板上限不能只按 `sidebarRange.upperBound` 定死：窗口只有 920pt 时，
    /// 420 + 640 两侧全开会直接把正文挤没，而用户看到的是「书不见了」。
    /// 这一条是**上限随窗口收窄**的依据，不是保证——窗口实在太窄时下限优先，
    /// 此时只能让正文被压一点（总好过面板点不到）。
    static var minimumReaderWidth: Double { UISettings.PanelWidth.minimumReaderWidth }

    /// 分隔线占的布局宽度。上限算式里要把它减掉，否则算出来的宽度会让
    /// 三栏总宽超出窗口 1pt，表现为「阅读区右侧被切掉一条」。
    static let handleWidth: Double = 1

    /// 量出三栏此刻各该多宽。
    ///
    /// - Parameters:
    ///   - pinned: 宽度足额的一方。拖动时传被拖的那一侧；不拖动时默认侧栏。
    ///
    /// **不拖动时为什么钉住侧栏而不是两侧等比压缩**：等比看着更公平，但会让
    /// 「写入 X → 渲染 X」这条关系在窄窗口下失效——写 266 只渲染出 225，
    /// 于是拖到底再松手、宽度反而比拖动中更窄，且每次松手都要重新分配一次。
    /// 钉住一侧则天然是**不动点**：侧栏拿走它的（上限之内）全部，
    /// AI 面板拿「剩下的、但不超过它自己要的」，把结果再喂回这个算式
    /// 得到的是同一组值——这正是「拖完不弹回」的数学保证。
    ///
    /// 让侧栏优先而不是 AI 面板：侧栏装的是目录 / 搜索结果 / 批注这类
    /// **结构化列表**，窄到 200pt 以下就开始横向裁字，且没法靠重排补救；
    /// AI 面板装的是会自己换行的正文与气泡，窄 100pt 只是行长变短。
    /// AI 面板还有退路（整个收起），图标栏没有。
    static func resolve(
        containerWidth: CGFloat,
        showsRail: Bool,
        sidebarPreferred: Double?,
        aiPanelPreferred: Double?,
        pinned: PinnedSide = .sidebar
    ) -> PanelLayout {
        let sidebarRange = UISettings.PanelWidth.sidebarRange
        let aiRange = UISettings.PanelWidth.aiRange

        // 容器宽度还没量到（首帧、视图尚未出现）时不做任何压缩：
        // 此时 containerWidth 是 0，按它算会把两侧压成 0pt，界面先闪一下空面板。
        guard containerWidth > 1 else {
            return PanelLayout(
                sidebar: sidebarPreferred.map { clamped($0, to: sidebarRange) },
                aiPanel: aiPanelPreferred.map { clamped($0, to: aiRange) },
                reader: 0,
                isReaderBelowGuarantee: false,
                isSqueezedBelowMinimum: false
            )
        }

        let railWidth: Double = showsRail ? Double(LeftRail.width) : 0
        let handleCount = (sidebarPreferred == nil ? 0 : 1) + (aiPanelPreferred == nil ? 0 : 1)
        // 扣掉图标栏与分隔线之后，面板与阅读区总共能分到的量
        let budget = max(0, Double(containerWidth) - railWidth - handleWidth * Double(handleCount))
        // 面板能拿走、且阅读区仍保底 320pt 的上限
        let available = budget - minimumReaderWidth

        var sidebar: Double? = nil
        var aiPanel: Double? = nil
        var belowGuarantee = false

        switch (sidebarPreferred, aiPanelPreferred) {
        case (let wantedSidebar?, let wantedAI?):
            let wantSidebar = clamped(wantedSidebar, to: sidebarRange)
            let wantAI = clamped(wantedAI, to: aiRange)
            switch pinned {
            case .sidebar:
                let width = Self.width(
                    for: wantSidebar,
                    range: sidebarRange,
                    reservedForOther: aiRange.lowerBound,
                    available: available
                )
                sidebar = width
                aiPanel = Self.remainder(
                    for: wantAI,
                    range: aiRange,
                    takenByOther: width,
                    available: available
                )
            case .aiPanel:
                let width = Self.width(
                    for: wantAI,
                    range: aiRange,
                    reservedForOther: sidebarRange.lowerBound,
                    available: available
                )
                aiPanel = width
                sidebar = Self.remainder(
                    for: wantSidebar,
                    range: sidebarRange,
                    takenByOther: width,
                    available: available
                )
            }
            belowGuarantee = (sidebar ?? 0) + (aiPanel ?? 0) > available + 0.001

        case (let wantedSidebar?, nil):
            let width = clamped(wantedSidebar, to: sidebarRange)
            if available >= sidebarRange.lowerBound {
                sidebar = min(width, available)
            } else {
                // 装不下下限：下限优先，阅读区让位（降级）
                sidebar = sidebarRange.lowerBound
                belowGuarantee = true
            }

        case (nil, let wantedAI?):
            let width = clamped(wantedAI, to: aiRange)
            if available >= aiRange.lowerBound {
                aiPanel = min(width, available)
            } else {
                aiPanel = aiRange.lowerBound
                belowGuarantee = true
            }

        case (nil, nil):
            break
        }

        // 最后一道闸：图标栏的 x 必须 ≥ 0。
        //
        // 上面的降级允许阅读区被压到保底以下，但不允许**面板把图标栏顶出屏幕**。
        // 窗口窄到 534pt 以下时（正常交互到不了，脚本改窗口尺寸可以），
        // 两个下限加起来就已经超出容器了。此时宁可让面板比下限还窄：
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

    /// 侧栏此刻最多能拖到多宽。
    ///
    /// 把侧栏的需求顶到静态上限、再按「拖动中」那条分支走一遍——上限与显示宽度
    /// 必须是同一条算式，否则会出现「拖到 300 松手、画面停在 266」这种
    /// 拖了没反馈的毛病。
    static func sidebarCap(
        containerWidth: CGFloat,
        showsRail: Bool,
        aiPanelPreferred: Double?
    ) -> Double {
        let upper = UISettings.PanelWidth.sidebarRange.upperBound
        return resolve(
            containerWidth: containerWidth,
            showsRail: showsRail,
            sidebarPreferred: upper,
            aiPanelPreferred: aiPanelPreferred,
            pinned: .sidebar
        ).sidebar ?? upper
    }

    /// AI 面板此刻最多能拖到多宽，同理。
    static func aiCap(
        containerWidth: CGFloat,
        showsRail: Bool,
        sidebarPreferred: Double?
    ) -> Double {
        let upper = UISettings.PanelWidth.aiRange.upperBound
        return resolve(
            containerWidth: containerWidth,
            showsRail: showsRail,
            sidebarPreferred: sidebarPreferred,
            aiPanelPreferred: upper,
            pinned: .aiPanel
        ).aiPanel ?? upper
    }

    // MARK: - 分配

    /// 被钉住的一侧能拿多宽：要多少给多少，但给对侧留够下限，且不超过静态上限。
    private static func width(
        for wanted: Double,
        range: ClosedRange<Double>,
        reservedForOther: Double,
        available: Double
    ) -> Double {
        let ceiling = min(range.upperBound, max(range.lowerBound, available - reservedForOther))
        return min(max(wanted, range.lowerBound), ceiling)
    }

    /// 对侧能拿多宽：剩下的全给它，但不超过它自己要的（也就不会超过它的静态上限）。
    private static func remainder(
        for wanted: Double,
        range: ClosedRange<Double>,
        takenByOther: Double,
        available: Double
    ) -> Double {
        min(max(wanted, range.lowerBound), max(range.lowerBound, available - takenByOther))
    }

    private static func clamped(_ value: Double, to range: ClosedRange<Double>) -> Double {
        guard value.isFinite else { return range.lowerBound }
        return min(max(value, range.lowerBound), range.upperBound)
    }
}

/// 面板之间那条「可以拖」的分隔线。
///
/// 三个关键决定，都不是随意选的：
///
/// 1. **视觉 1pt，命中区 10pt。** 视觉上必须和原来的静态分隔线一样细，
///    否则三栏会变得很吵；但 1pt 的线用鼠标是抓不住的，用户会自动得出
///    「这条线不能拖」的结论。所以命中区用一层完全透明的 overlay 撑到 10pt，
///    视觉宽度不受影响。
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

    @State private var isHovering = false
    /// 按下那一刻的宽度。nil 表示当前没有在拖。
    @State private var widthAtDragStart: Double?

    /// 命中区宽度：够大才好抓，又不至于盖住相邻控件。
    private let hitWidth: CGFloat = 10

    private var isDragging: Bool { liveWidth != nil }
    private var isActive: Bool { isHovering || isDragging }

    var body: some View {
        Color.clear
            // 只占 1pt 布局空间，顶替原来那条静态 Divider，三栏总宽度不变
            .frame(width: 1)
            .frame(maxHeight: .infinity)
            .overlay {
                Rectangle()
                    .fill(lineColor)
                    // 高亮时可以比 1pt 粗——overlay 不参与布局，不会推挤三栏
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
            .help("拖动调整宽度，双击复位")
            .accessibilityLabel(panelIsLeading ? "侧栏宽度" : "AI 面板宽度")
    }

    private var lineColor: Color {
        if isDragging { return DS.Palette.accent }
        if isHovering { return DS.Palette.accent.opacity(0.55) }
        return DS.Palette.separator
    }

    private var dragGesture: some Gesture {
        DragGesture(minimumDistance: 1)
            .onChanged { value in
                if widthAtDragStart == nil {
                    // 起点取**已提交值**而不是「设置里当前的宽度」：
                    // 后者在极端情况下（窗口刚被改小、上限刚收窄）可能与
                    // 正在显示的宽度不一致，接手那一帧就会跳一下。
                    widthAtDragStart = liveWidth ?? committedWidth
                }
                guard let start = widthAtDragStart else { return }
                let delta = panelIsLeading ? value.translation.width : -value.translation.width
                // 钳制放在写入这一侧，而不是只依赖设置解码时的钳制：
                // 拖到边界时要立刻停住，不能让中间态越界（越界期间阅读区会被压成负宽）。
                liveWidth = min(max(start + delta, range.lowerBound), range.upperBound)
            }
            .onEnded { _ in
                if let live = liveWidth { onCommit(live) }
                liveWidth = nil
                widthAtDragStart = nil
            }
    }

    private func resetToDefault() {
        withAnimation(DS.Motion.panel) { onCommit(defaultWidth) }
    }

    private func handleHover(_ inside: Bool) {
        // 这个 guard 不能省：onHover 在鼠标横向微动时会重复回调同一个值，
        // 而 NSCursor 的 push/pop 是配对的——多 push 一次就永久歪了光标。
        guard isHovering != inside else { return }
        isHovering = inside
        if inside {
            NSCursor.resizeLeftRight.push()
        } else {
            NSCursor.pop()
        }
    }
}
