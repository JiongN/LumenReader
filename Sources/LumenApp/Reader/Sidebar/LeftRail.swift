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
    static let width: CGFloat = 56

    let tabs: [SidebarTab]
    let activeTab: SidebarTab
    /// 内容面板当前是否展开
    let isExpanded: Bool
    var layoutScale: CGFloat = 1
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
        .frame(width: Self.width * layoutScale)
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
            Group {
                // AI 页签用统一的环点字形（AIIcon v3：细线圆环 + 缺口处一枚实心点），
                // 与工具栏上的 AI 图标同形——
                // SF Symbols 的 sparkles.rectangle.stack 在 14pt 下细节糊成一团。
                if tab == .smartOutline {
                    // 环点字形与工具栏同形；颜色跟随页签状态，
                    // 不再单独调透明度（单色字形的层级靠颜色本身表达）
                    AIIcon(
                        size: 16,
                        color: isActive
                            ? DS.Palette.accent
                            : (isHovered ? DS.Palette.textPrimary : DS.Palette.textSecondary)
                    )
                } else {
                    Image(systemName: tab.systemImage)
                        .font(DS.Typo.ui(size: 15.5, weight: isActive ? .semibold : .regular))
                }
            }
            .foregroundStyle(iconColor(isActive: isActive, isHovered: isHovered))
            .frame(width: 40 * layoutScale, height: 38 * layoutScale)
            .contentShape(RoundedRectangle(cornerRadius: DS.Radius.m, style: .continuous))
            .background(
                RoundedRectangle(cornerRadius: DS.Radius.m, style: .continuous)
                    .fill(background(isActive: isActive, isHovered: isHovered))
            )
            // 悬停时给一条极淡的描边：图标本身在材质背景上对比度有限，
            // 只靠底色变化在深色主题下几乎看不出来。
            // 选中态不再描边——选中已经由胶囊底色表达，双重强调反而重。
            .overlay(
                RoundedRectangle(cornerRadius: DS.Radius.m, style: .continuous)
                    .strokeBorder(DS.Palette.separator, lineWidth: isHovered && !isActive ? 0.5 : 0)
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
        if isActive { return DS.Palette.accent }
        if isHovered { return DS.Palette.textPrimary }
        return DS.Palette.textSecondary
    }

    /// 选中态改为**淡强调色胶囊 + 强调色图标**（Apple 侧栏惯例），
    /// 不再是实心强调色块 + 白图标——后者在整条图标栏里是一块
    /// 持续存在的「高亮补丁」，阅读时会一直拉扯注意力。
    private func background(isActive: Bool, isHovered: Bool) -> Color {
        if isActive { return DS.Palette.accentSoft }
        if isHovered { return DS.Palette.surfaceRaised.opacity(0.7) }
        return .clear
    }
}

/// 把图标栏接到**它自己观察的那份 bridge** 上。
///
/// 存在的理由（这是个真 bug 的修复，不是包装）：图标栏的选中态读
/// `bridge.sidebarTab`，而 `ReaderContainerView` 只观察 `session` /
/// `AppState` / `SettingsStore`，**不观察 `ReaderBridge`**。于是「侧栏已经展开、
/// 只切换到另一个页签」这条最常见的路径上——`bridge.sidebarTab` 变了、
/// `AppState` 什么都没变——容器不会重绘，**高亮就停在原来那一格**，
/// 而内容面板（`SidebarColumn` 自己 `@EnvironmentObject bridge`）却真的换了。
/// 用户看到的正是「图标不跟帖」：内容换、图标不动。
///
/// 为什么不在 `ReaderContainerView` 上加 `@EnvironmentObject bridge`：
/// bridge 的 `@Published` 里还有视口快照、选区这类**每帧都在变**的字段，
/// 让整个容器观察它会把阅读区（PDFKit / WKWebView）一起拖进每帧重排——
/// 项目里已经为这个坑把视口 snapshot 抽成 `Equatable` 子视图了。
/// 观察点收在这一层：这里只有 5 枚按钮，重绘代价可以忽略。
struct SidebarRail: View {

    @EnvironmentObject private var bridge: ReaderBridge

    let tabs: [SidebarTab]
    /// 内容面板是否展开。由容器传入（容器自己观察 `AppState`，这一项本来就跟着刷新）。
    let isExpanded: Bool
    var layoutScale: CGFloat = 1
    let onSelect: (SidebarTab) -> Void

    var body: some View {
        // 计数写在 body 里而不是做成修饰符——见 `Jank` 的注释（修饰符会被复用、只跑一次）。
        // `--sidebar-tab-report` 靠它证明「图标栏确实跟着 bridge 重绘了」。
        let _ = Jank.tick(.sidebarRailBody)
        LeftRail(
            tabs: tabs,
            activeTab: bridge.sidebarTab,
            isExpanded: isExpanded,
            layoutScale: layoutScale,
            onSelect: onSelect
        )
    }
}
