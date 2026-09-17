import SwiftUI
import AppKit
import LumenKit

/// 面板宽度的上下限策略。
///
/// 收成一个枚举而不是散在 `ReaderContainerView` 与 `ResizeAudit` 里各写一份：
/// 拖拽提交与自检断言必须走**同一条算式**，否则自检验的是一段死代码——
/// 「改了算式只改一处」正是这类断言最容易悄悄失效的方式。
enum PanelWidthPolicy {

    /// 阅读区至少要留这么宽。
    ///
    /// 面板上限不能只按 `sidebarRange.upperBound` 定死：窗口只有 920pt 时，
    /// 420 + 640 两侧全开会直接把正文挤没，而用户看到的是「书不见了」。
    /// 这一条是**上限随窗口收窄**的依据，不是保证——窗口实在太窄时下限优先，
    /// 此时只能让正文被压一点（总好过面板点不到）。
    static var minimumReaderWidth: Double { UISettings.PanelWidth.minimumReaderWidth }

    /// 侧栏可用上限：窗口宽 − 图标栏 − 阅读区保底 − AI 面板（含分隔线）。
    static func sidebarCap(
        containerWidth: CGFloat,
        aiPanelWidth: Double,
        isAIPanelVisible: Bool
    ) -> Double {
        guard containerWidth > 1 else { return UISettings.PanelWidth.sidebarRange.upperBound }
        let reserved = LeftRail.width
            + (isAIPanelVisible ? aiPanelWidth + Self.handleWidth : 0)
        return UISettings.PanelWidth.sidebarMaxWidth(
            containerWidth: Double(containerWidth),
            reserved: Double(reserved)
        )
    }

    /// AI 面板可用上限：窗口宽 − 图标栏 − 阅读区保底 − 侧栏（含分隔线）。
    static func aiCap(
        containerWidth: CGFloat,
        sidebarWidth: Double,
        isSidebarVisible: Bool
    ) -> Double {
        guard containerWidth > 1 else { return UISettings.PanelWidth.aiRange.upperBound }
        let reserved = LeftRail.width
            + (isSidebarVisible ? sidebarWidth + Self.handleWidth : 0)
        return UISettings.PanelWidth.aiMaxWidth(
            containerWidth: Double(containerWidth),
            reserved: Double(reserved)
        )
    }

    /// 分隔线占的布局宽度。上限算式里要把它减掉，否则算出来的宽度会让
    /// 三栏总宽超出窗口 1pt，表现为「阅读区右侧被切掉一条」。
    static let handleWidth: Double = 1
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

    /// 已提交的宽度（唯一真相源：设置）。拖动期间**不写**它。
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
