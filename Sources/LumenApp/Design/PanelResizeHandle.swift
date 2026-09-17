import SwiftUI
import AppKit
import LumenKit

/// 三栏在某一时刻的**显示宽度**。
///
/// 与「用户存了多少」是两件事：设置里存的是偏好，这里给的是**这一轮布局**
/// 实际要给多少。侧栏宽度是固定的（248pt），只有 AI 面板参与「窗口变窄时谁让」。
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
/// ## 本批的语义变更：侧栏固定，只有 AI 面板可调
///
/// 从前两侧面板各有一个拖拽分隔线，`resolve` 要在「两个偏好」之间分配预算。
/// 现在**侧栏宽度是常量**（`UISettings.PanelWidth.sidebarDefault` = 248pt，
/// 与 `DS.Size.sidebarIdeal` 同源），界面上只剩 AI 面板那条分隔线。于是算式退化成：
/// 侧栏先足额拿走 248pt，剩下的给 AI 面板，但 AI 面板不低于自己的下限、阅读区不低于保底。
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

    /// 分隔线占的**布局**宽度。
    ///
    /// 本批改成 0：分隔线改用 overlay 绘制（与 `LeftRail` 右侧那条分隔线同样的做法），
    /// 不再在 `HStack` 里占 1pt。这不是审美问题——它决定下面这条等式成不成立：
    ///
    ///     图标栏(52) + 侧栏(248) + AI 面板下限(300) + 阅读区保底(320) = 920 = 最小窗口宽
    ///
    /// 若分隔线再吃 1pt，最小窗口下阅读区就只能拿到 319pt，「920pt 最挤时阅读区 ≥ 320」
    /// 这条承诺永远差 1pt 兑现不了。把分隔线的绘制搬进 overlay 之后，
    /// 这条等式在最小窗口下**刚好**成立。
    static let handleWidth: Double = 0

    /// 侧栏固定宽度。与 `DS.Size.sidebarIdeal` 同值（都是 248），
    /// 但这里刻意走配置层而不是界面层的令牌——`LumenKit` 拿不到 `DS`。
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
        aiPanelPreferred: Double?
    ) -> PanelLayout {
        let aiRange = UISettings.PanelWidth.aiRange
        let sidebarWidth = fixedSidebarWidth

        // 容器宽度还没量到（首帧、视图尚未出现）时不做任何压缩：
        // 此时 containerWidth 是 0，按它算会把两侧压成 0pt，界面先闪一下空面板。
        guard containerWidth > 1 else {
            return PanelLayout(
                sidebar: sidebarVisible ? sidebarWidth : nil,
                aiPanel: aiPanelPreferred.map { clamped($0, to: aiRange) },
                reader: 0,
                isReaderBelowGuarantee: false,
                isSqueezedBelowMinimum: false
            )
        }

        let railWidth: Double = showsRail ? Double(LeftRail.width) : 0
        // 分隔线只算 AI 面板那一条（侧栏没有分隔线了）；handleWidth 现为 0，这一项恒为 0，
        // 保留算式是为了将来若又需要给分隔线留位时只改一处。
        let handleCount = aiPanelPreferred == nil ? 0 : 1
        // 扣掉图标栏与分隔线之后，面板与阅读区总共能分到的量
        let budget = max(0, Double(containerWidth) - railWidth - handleWidth * Double(handleCount))
        // 面板能拿走、且阅读区仍保底 320pt 的上限
        let available = budget - minimumReaderWidth

        var sidebar: Double? = sidebarVisible ? sidebarWidth : nil
        var aiPanel: Double? = nil
        var belowGuarantee = false

        if let wantedAI = aiPanelPreferred {
            let wantAI = clamped(wantedAI, to: aiRange)
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
        sidebarVisible: Bool
    ) -> Double {
        let upper = UISettings.PanelWidth.aiRange.upperBound
        return resolve(
            containerWidth: containerWidth,
            showsRail: showsRail,
            sidebarVisible: sidebarVisible,
            aiPanelPreferred: upper
        ).aiPanel ?? upper
    }

    private static func clamped(_ value: Double, to range: ClosedRange<Double>) -> Double {
        guard value.isFinite else { return range.lowerBound }
        return min(max(value, range.lowerBound), range.upperBound)
    }
}

/// 面板之间那条「可以拖」的分隔线。
///
/// 现在只剩 AI 面板左边这一条——侧栏宽度固定为 248pt，界面上不再给它入口。
///
/// 三个关键决定，都不是随意选的：
///
/// 1. **布局 0pt，视觉 1pt，命中区 10pt。**
///    布局宽度必须是 0：它决定「图标栏 + 侧栏 + AI 下限 + 阅读区保底 = 920」
///    这条等式在最小窗口下成不成立（见 `PanelWidthPolicy.handleWidth`）。
///    视觉上仍然画一条 1pt 的线（走 overlay，不占布局），否则阅读区与 AI 面板
///    之间会失去分界；而 1pt 的线用鼠标抓不住，所以命中区用另一层完全透明的
///    overlay 撑到 10pt。三层互不干扰。
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
            // **0pt 布局**：分隔线的绘制搬进 overlay（与 LeftRail 右侧那条线同做法），
            // 把这一像素还给阅读区——最小窗口下它是「阅读区保底 320」能否兑现的关键。
            .frame(width: PanelWidthPolicy.handleWidth)
            .frame(maxHeight: .infinity)
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
