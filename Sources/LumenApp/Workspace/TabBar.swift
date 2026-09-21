import SwiftUI
import AppKit
import LumenKit

/// 窗口顶部的标签栏：一个窗口多份文档，每份文档一个标签。
///
/// 视觉取向与应用整体一致：克制的单色、细分割线、活动标签用「浮起」的底色区分，
/// 不模仿浏览器的梯形标签。标签过多时横向滚动，不挤压标题。
///
/// 标签的全部管理动作（切换 / 关闭 / 去重）都在 `AppState` 里；
/// 「在独立窗口打开」由 `WindowManager.detach` 承接。
struct TabBar: View {

    @EnvironmentObject private var state: AppState

    static let height: CGFloat = 40
    @State private var availableWidth: CGFloat = 1320
    private var layoutScale: CGFloat { DS.Size.windowScale(for: availableWidth) }
    private var adaptiveHeight: CGFloat { Self.height * layoutScale }

    /// 左侧给红黄绿交通灯留的横向空位（标题栏透明、交通灯悬浮在标签同一行）。
    static let trafficLightInset: CGFloat = 70

    var body: some View {
        HStack(spacing: 0) {
            // 标题栏透明后，红黄绿交通灯悬浮在窗口最左上。标签栏从它右边开始，
            // 左侧留出格位，避免标签被交通灯盖住（Obsidian 式单行顶栏）。
            Color.clear
                .frame(width: Self.trafficLightInset * layoutScale)

            // 「收起 / 展开侧栏」放最左、紧跟交通灯，之后才是标签页（Chrome/Obsidian 习惯）。
            Button {
                state.toggleSidebar()
            } label: {
                Image(systemName: "sidebar.leading")
                    .font(DS.Typo.ui(size: 14))
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(.plain)
            .foregroundStyle(DS.Palette.textSecondary)
            .help(ts(state.isSidebarVisible ? "隐藏侧栏" : "显示侧栏", for: .toggleSidebar))
            .disabled(state.document == nil)
            .padding(.leading, DS.Space.xs)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: DS.Space.xs) {
                    ForEach(state.sessions) { session in
                        TabItem(
                            session: session,
                            isActive: session.id == state.activeSessionID,
                            onActivate: { state.activate(session) },
                            onClose: { state.close(session) },
                            onDetach: { state.detach(session) },
                            onCloseOthers: { state.closeOthers(keeping: session) }
                        )
                    }

                    // 主页标签排在最后：和浏览器「在末尾开新标签」的手感一致。
                    if state.homeTabIsActive {
                        HomeTabItem(onClose: { state.closeHomeTab() })
                    }

                    addButton
                }
                .padding(.horizontal, DS.Space.s)
                .frame(height: adaptiveHeight)
            }

            Divider()

            toolbarActions
        }
        // 关键：把标签栏钉成固定高度。裸 `Divider()` 在 HStack 里是竖直柔性的
        // （会撑满父级提案的高度），不钉死的话 TabBar 会被顶层 VStack 当成一个
        // 可与阅读区平分的柔性子项——结果阅读区只剩约半窗、底部对齐。
        .frame(height: adaptiveHeight)
        .background(DS.Palette.surfaceSunken)
        .background {
            GeometryReader { proxy in
                Color.clear
                    .onAppear { availableWidth = proxy.size.width }
                    .onChange(of: proxy.size.width) { _, width in availableWidth = width }
            }
        }
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(DS.Palette.separator)
                .frame(height: 1)
        }
    }


    /// 顶栏右侧的操作按钮：外观 / 复制 / 沉浸 / AI 面板。
    /// 窗口不再有独立的工具栏行，这些动作统一收进这一条标签栏。
    @ViewBuilder
    private var toolbarActions: some View {
        HStack(spacing: DS.Space.s) {
            AppearanceMenuButton()
            Menu {
                // 只保留去向为**剪贴板**的动作（复制全文 / 复制文件）。
                // 导出类动作已收归菜单栏「文件 > 导出」唯一入口——这里不再出现，
                // 条目（含文案与顺序）统一从 `ActionEntries` 长出，避免同一个动作多处出现。
                ForEach(ActionEntries.entries(in: .copy)) { entry in
                    copyMenuItem(entry)
                }
            } label: {
                Image(systemName: "doc.on.doc")
                    .font(DS.Typo.ui(size: 14))
                    .frame(width: 22, height: 28)
                    .contentShape(Rectangle())
            }
            .foregroundStyle(DS.Palette.textSecondary)
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .frame(width: 32, height: 32)
            .help("复制")
            .disabled(state.document == nil)

            Button {
                state.setImmersive(!state.isImmersive)
            } label: {
                Image(systemName: state.isImmersive
                      ? "arrow.down.right.and.arrow.up.left"
                      : "arrow.up.left.and.arrow.down.right")
                    .font(DS.Typo.ui(size: 14))
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(.plain)
            .foregroundStyle(DS.Palette.textSecondary)
            .help(ts("沉浸阅读模式", for: .toggleImmersive))
            .disabled(state.document == nil)

            Button {
                state.toggleAIPanel()
            } label: {
                Image(systemName: "sidebar.trailing")
                    .font(DS.Typo.ui(size: 14))
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(.plain)
            .foregroundStyle(DS.Palette.textSecondary)
            .help(ts(state.isAIPanelVisible ? "隐藏 AI 面板" : "显示 AI 面板", for: .toggleAIPanel))
            .disabled(state.document == nil)
        }
        .fixedSize(horizontal: true, vertical: false)
        .padding(.horizontal, DS.Space.s)
        .foregroundStyle(DS.Palette.textTertiary)
    }

    /// 提示文案带上用户当前的真实绑定（与旧工具栏一致）。
    private func ts(_ label: String, for action: LumenAction) -> String {
        guard let combo = state.keyBindings.combo(for: action) else { return label }
        return "\(label) (\(combo.display))"
    }

    /// 顶栏「复制」菜单的一项：文案取自 planner，可用性与执行取自它挂的 `LumenAction`。
    /// 这样「复制全文」的可用性（有无文本层）与命令面板、菜单栏读的是同一个判断。
    @ViewBuilder
    private func copyMenuItem(_ entry: ActionEntry) -> some View {
        if let action = entry.action {
            Button(entry.title) { action.run(state) }
                .disabled(!action.isEnabled(in: state))
        } else {
            // 复制菜单里出现了一个没有 `LumenAction` 的条目：不静默（断言 + 可见兜底），
            // 否则这一项会悄悄消失——不报错、不崩溃、自检也不会红。
            UnimplementedEntryView(entry: entry)
        }
    }

    /// 标签栏末尾的「+」：新建标签页，正文回到主页（最近打开 / 打开按钮都在那儿）。
    ///
    /// 不再直接弹「打开文件」面板：那个动作已经有 ⌘O，而「+」在标签栏语境里的
    /// 通行含义是「再来一个空标签」，弹文件选择器属于答非所问。
    private var addButton: some View {
        Button {
            state.addHomeTab()
        } label: {
            Image(systemName: "plus")
                .font(DS.Typo.ui(size: 12, weight: .medium))
                .foregroundStyle(DS.Palette.textSecondary)
                .frame(width: 24, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("新建标签页（回到主页）")
    }
}

/// 主页标签：没有文档的那一枚。
///
/// 视觉与文档标签同构（同样的高度、圆角、选中底色），
/// 否则「新建标签页」在标签栏上会像一枚混进来的异形按钮。
private struct HomeTabItem: View {

    let onClose: () -> Void

    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "house")
                .font(DS.Typo.ui(size: 11))
                .foregroundStyle(DS.Palette.accent)

            Text("主页")
                .font(DS.Typo.ui(size: 12, weight: .semibold))
                .foregroundStyle(DS.Palette.textPrimary)
                .lineLimit(1)

            Spacer(minLength: 0)

            Button(action: onClose) {
                ZStack {
                    if isHovering {
                        Circle()
                            .fill(DS.Palette.textPrimary.opacity(0.12))
                            .frame(width: 15, height: 15)
                    }
                    Image(systemName: "xmark")
                        .font(.system(size: 7.5, weight: .bold))
                        .foregroundStyle(DS.Palette.textSecondary)
                }
                .frame(width: 15, height: 15)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .opacity(isHovering ? 1 : 0)
            .help("关闭标签页")
        }
        .padding(.horizontal, DS.Space.s)
        .frame(width: 126, height: 30)
        .background(
            RoundedRectangle(cornerRadius: DS.Radius.s, style: .continuous)
                .fill(DS.Palette.surfaceRaised)
        )
        .overlay(
            RoundedRectangle(cornerRadius: DS.Radius.s, style: .continuous)
                .strokeBorder(DS.Palette.separator, lineWidth: 0.5)
        )
        .contentShape(Rectangle())
        .onHover { hovering in
            withAnimation(DS.Motion.hover) { isHovering = hovering }
        }
        .help("主页：最近打开的文档都在这里")
    }
}

/// 单个标签。
private struct TabItem: View {

    @ObservedObject var session: ReaderSession
    let isActive: Bool
    let onActivate: () -> Void
    let onClose: () -> Void
    let onDetach: () -> Void
    let onCloseOthers: () -> Void

    @State private var isHovering = false

    private static let tabWidth: ClosedRange<CGFloat> = 120...190

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(DS.Typo.ui(size: 11))
                .foregroundStyle(isActive ? DS.Palette.accent : DS.Palette.textTertiary)

            Text(session.title)
                .font(DS.Typo.ui(size: 12, weight: isActive ? .semibold : .regular))
                .foregroundStyle(isActive ? DS.Palette.textPrimary : DS.Palette.textSecondary)
                .lineLimit(1)
                .truncationMode(.middle)

            Spacer(minLength: 0)

            trailingControl
        }
        .padding(.horizontal, DS.Space.s)
        .frame(width: 176, height: 30)
        .frame(minWidth: Self.tabWidth.lowerBound, maxWidth: Self.tabWidth.upperBound)
        .background(background)
        .overlay(border)
        .contentShape(Rectangle())
        .onTapGesture { onActivate() }
        .onHover { hovering in
            withAnimation(DS.Motion.hover) { isHovering = hovering }
        }
        .contextMenu { menu }
        .help(session.document.url.path)
    }

    @ViewBuilder
    private var trailingControl: some View {
        if session.busy != nil {
            // 长任务（全文抽取 / OCR）进行中：用小转圈占住关闭按钮的位置，
            // 一眼能看出哪个标签在忙，也避免误关。
            ProgressView()
                .controlSize(.mini)
                .frame(width: 14, height: 14)
        } else {
            Button(action: onClose) {
                ZStack {
                    if isHovering || isActive {
                        Circle()
                            .fill(DS.Palette.textPrimary.opacity(isHovering ? 0.12 : 0.06))
                            .frame(width: 15, height: 15)
                    }
                    Image(systemName: "xmark")
                        .font(.system(size: 7.5, weight: .bold))
                        .foregroundStyle(DS.Palette.textSecondary)
                }
                .frame(width: 15, height: 15)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .opacity(isHovering || isActive ? 1 : 0)
            .help("关闭标签（⌘W）")
        }
    }

    private var icon: String {
        switch session.document.kind {
        case .pdf:  return "doc.text"
        case .epub: return "book.closed"
        }
    }

    private var background: some View {
        RoundedRectangle(cornerRadius: DS.Radius.s, style: .continuous)
            .fill(isActive
                  ? DS.Palette.surfaceRaised
                  : (isHovering ? DS.Palette.textPrimary.opacity(0.05) : Color.clear))
    }

    private var border: some View {
        RoundedRectangle(cornerRadius: DS.Radius.s, style: .continuous)
            .strokeBorder(
                isActive ? DS.Palette.separator : Color.clear,
                lineWidth: 0.5
            )
    }

    /// 右键菜单：核心诉求是「在独立窗口打开」；顺手补齐标签的常用操作。
    @ViewBuilder
    private var menu: some View {
        Button("在独立窗口打开") { onDetach() }

        Divider()

        Button("关闭标签页") { onClose() }
        Button("关闭其他标签页") { onCloseOthers() }

        Divider()

        Button("在访达中显示") {
            NSWorkspace.shared.activateFileViewerSelecting([session.document.url])
        }
    }
}
