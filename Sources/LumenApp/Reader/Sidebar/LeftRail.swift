import SwiftUI
import LumenKit

/// 侧栏最左侧那条**常驻**的纵向图标栏。
///
/// 它和右侧的内容面板是两件事，因此也各自独立控制显隐：
///
/// - **图标栏**：只要不在沉浸模式就在。它是「侧栏的存在证明」——
///   内容面板收起之后，用户仍然要有一个能一眼看到、一键展开的入口。
///   此前页签选择器长在内容面板顶部，面板一收起，切页签的入口就跟着消失了，
///   ⌘1–⌘5 之外的鼠标用户只能用工具栏那个图标把整块面板叫回来。
/// - **内容面板**：由 `AppState.isSidebarVisible` 控制，行为与改造前一致。
///
/// 选中态只在**面板展开时**点亮：面板收起时没有任何页签处于「正在看」的状态，
/// 给一个高亮等于告诉用户「你现在在目录页」，而他其实什么都没在看。
struct LeftRail: View {

    /// 图标栏宽度。52pt 是「看着窄、点得中」的折中：
    /// 44pt 时手指（触控板光标）落在两个图标之间的空隙概率明显上升，
    /// 60pt 以上则在 920pt 的最小窗口里开始明显吃掉阅读区。
    static let width: CGFloat = 52

    let tabs: [SidebarTab]
    let activeTab: SidebarTab
    /// 内容面板当前是否展开
    let isExpanded: Bool
    let onSelect: (SidebarTab) -> Void

    @State private var hoveredTab: SidebarTab?

    var body: some View {
        VStack(spacing: DS.Space.xxs) {
            ForEach(tabs) { tab in
                railButton(tab)
            }
            Spacer(minLength: 0)
        }
        .padding(.top, DS.Space.m)
        .padding(.bottom, DS.Space.s)
        .frame(width: Self.width)
        // 右侧一条分隔线，把图标栏与内容面板分开。
        // 用 overlay 而不是在图标栏右侧再叠一个 1pt 的 Rectangle：
        // 少一层布局视图，宽度算式（PanelWidthPolicy）里也就少一个要减的量。
        .overlay(alignment: .trailing) {
            Rectangle()
                .fill(DS.Palette.separator)
                .frame(width: 1)
        }
    }

    private func railButton(_ tab: SidebarTab) -> some View {
        let isActive = isExpanded && tab == activeTab
        let isHovered = hoveredTab == tab

        return Button {
            onSelect(tab)
        } label: {
            Image(systemName: tab.systemImage)
                .font(DS.Typo.ui(size: 14.5, weight: isActive ? .semibold : .regular))
                .foregroundStyle(iconColor(isActive: isActive, isHovered: isHovered))
                .frame(width: 36, height: 34)
                .contentShape(RoundedRectangle(cornerRadius: DS.Radius.m, style: .continuous))
                .background(
                    RoundedRectangle(cornerRadius: DS.Radius.m, style: .continuous)
                        .fill(background(isActive: isActive, isHovered: isHovered))
                )
                // 悬停时给图标栏加一条极淡的描边：图标本身在材质背景上对比度有限，
                // 只靠底色变化在深色主题下几乎看不出来。
                .overlay(
                    RoundedRectangle(cornerRadius: DS.Radius.m, style: .continuous)
                        .strokeBorder(
                            isActive ? DS.Palette.accent.opacity(0.9) : DS.Palette.separator,
                            lineWidth: isHovered && !isActive ? 0.5 : 0
                        )
                )
        }
        .buttonStyle(.plain)
        // 悬停提示写全称（「AI 智能目录」而不是「智能」）：图标栏里没有文字标签，
        // 这是唯一能说清每个图标是什么的地方。
        .help(tab.fullTitle)
        .accessibilityLabel(tab.fullTitle)
        .onHover { hovering in
            // 离开时只清掉「自己」那一项：macOS 的 onHover 回调顺序不保证，
            // 从 A 直接移到 B 时可能先收到 B 的 true 再收到 A 的 false，
            // 无条件置 nil 会把刚点亮的 B 又抹掉。
            if hovering {
                hoveredTab = tab
            } else if hoveredTab == tab {
                hoveredTab = nil
            }
        }
    }

    private func iconColor(isActive: Bool, isHovered: Bool) -> Color {
        if isActive { return Color.white }
        if isHovered { return DS.Palette.textPrimary }
        return DS.Palette.textSecondary
    }

    private func background(isActive: Bool, isHovered: Bool) -> Color {
        if isActive { return DS.Palette.accent }
        if isHovered { return DS.Palette.surfaceRaised.opacity(0.7) }
        return .clear
    }
}
