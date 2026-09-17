import SwiftUI
import AppKit
import LumenKit

/// 面板之间那条「可以拖」的分隔线。
///
/// 三个关键决定，都不是随意选的：
///
/// 1. **视觉 1pt，命中区 10pt。** 视觉上必须和原来的静态分隔线一样细，
///    否则三栏会变得很吵；但 1pt 的线用鼠标是抓不住的，用户会自动得出
///    「这条线不能拖」的结论。所以命中区用一层完全透明的 overlay 撑到 10pt，
///    视觉宽度不受影响。
///
/// 2. **拖动期间刻意不加动画。** 套上 `withAnimation` 的话面板会「追」着鼠标走，
///    手感发飘，像在拖一个系了皮筋的东西。只有「双击复位」才用动画。
///
/// 3. **用增量，不用绝对位置。** 若把鼠标的全局 x 直接当成宽度，由于分隔线与面板
///    之间还有内边距、外侧还有别的栏，接手的第一帧必然跳一下。记下按下时的宽度
///    再加位移最稳。
struct PanelResizeHandle: View {

    @Binding var width: Double
    let range: ClosedRange<Double>
    let defaultWidth: Double
    /// 面板位于分隔线左侧时为 `true`（侧栏），右侧为 `false`（AI 面板）。
    /// 决定拖动方向的正负——鼠标右移，对左侧面板是变宽，对右侧面板是变窄。
    let panelIsLeading: Bool

    @State private var isHovering = false
    @State private var isDragging = false
    /// 按下那一刻的宽度。nil 表示当前没有在拖。
    @State private var widthAtDragStart: Double?

    /// 命中区宽度：够大才好抓，又不至于盖住相邻控件。
    private let hitWidth: CGFloat = 10

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
                    widthAtDragStart = width
                    isDragging = true
                }
                guard let start = widthAtDragStart else { return }
                let delta = panelIsLeading ? value.translation.width : -value.translation.width
                // 钳制放在写入这一侧，而不是只依赖设置解码时的钳制：
                // 拖到边界时要立刻停住，不能让中间态越界（越界期间阅读区会被压成负宽）。
                width = min(max(start + delta, range.lowerBound), range.upperBound)
            }
            .onEnded { _ in
                widthAtDragStart = nil
                isDragging = false
            }
    }

    private func resetToDefault() {
        withAnimation(DS.Motion.panel) { width = defaultWidth }
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
