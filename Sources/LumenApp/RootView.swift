import SwiftUI
import AppKit
import LumenKit

struct RootView: View {

    @EnvironmentObject private var state: AppState
    @EnvironmentObject private var keyBindings: KeyBindingStore

    @Environment(\.colorScheme) private var systemColorScheme
    /// 打开「设置」窗口。用官方的环境动作，不去 sendAction 那些私有 selector——
    /// 私有 selector 的名字在 macOS 14 前后变过一次，且失败时静默无返回，很难查。
    @Environment(\.openSettings) private var openSettings

    private var systemIsDark: Bool { systemColorScheme == .dark }

    var body: some View {
        Group {
            if let document = state.document {
                ReaderContainerView(document: document)
                    .transition(.opacity)
            } else {
                WelcomeView()
                    .transition(.opacity)
            }
        }
        // 欢迎页 ↔ 阅读器之间交叉淡入。硬切的话，点开一本书的瞬间画面会「跳」一下——
        // 一边是暗底欢迎页、一边是纸白阅读面，亮度差很大，不淡入相当刺眼。
        // 用 `.animation(_:value:)` 而不是给 onOpen 加 withAnimation：
        // 打开文档的路径有好几条（欢迎页、菜单、命令面板、最近列表、拖拽），
        // 挂在状态本身上才能一次覆盖全部，漏掉任何一条都会退化成硬切。
        .animation(DS.Motion.content, value: state.document?.id)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(state.document == nil ? AnyView(DS.Palette.surfaceSunken) : AnyView(Color.clear))
        // 主题切换的过渡只做到这一层垫色为止，不往下碰阅读内容。
        //
        // 边界在哪儿、以及为什么在这儿：PDF 要整页重绘、EPUB 的 WebView 要重新排版，
        // 把它们卷进动画只会看到一片闪白（详见 `DS.Motion.theme` 的注释）；而窗口外观
        // （`windowAppearance`）是即时生效的 AppKit 属性，也没法插值。
        // 剩下唯一能真正平滑过渡的，就是这块纯 SwiftUI 绘制的背景。
        .animation(DS.Motion.theme, value: state.settingsStore.reader.theme.id)
        .overlay {
            if state.isCommandPaletteVisible {
                CommandPaletteOverlay()
                    .transition(.opacity)
            }
        }
        .overlay { BusyOverlay() }
        .overlay(alignment: .top) { ToastLayer().padding(.top, 76) }
        // 打开文档后由阅读主题统辖窗口外观；欢迎页跟随系统深浅色
        .windowAppearance(isDark: state.document == nil ? systemIsDark : state.settingsStore.reader.theme.isDark)
        .task {
            if let size = LaunchOptions.windowSize {
                await Self.applyWindowSize(size)
            }

            if let memo = LaunchOptions.rememberText {
                state.remember(text: memo, source: "命令行")
            }

            if LaunchOptions.opensSettings {
                try? await Task.sleep(nanoseconds: 700_000_000)
                openSettings()
            }

            guard let path = LaunchOptions.openPath else { return }
            // 等首帧布局完成再挂载文档，否则自动截图可能拍到尚未成形的画面
            try? await Task.sleep(nanoseconds: 350_000_000)
            state.open(url: URL(fileURLWithPath: path))

            if let prompt = LaunchOptions.askPrompt {
                // 再等一会儿，让阅读视图与聊天模型完成绑定
                try? await Task.sleep(nanoseconds: 1_200_000_000)
                state.pendingAIRequest = AIRequest(kind: .custom, customPrompt: prompt)
            }

            if LaunchOptions.opensPalette {
                try? await Task.sleep(nanoseconds: 600_000_000)
                state.isCommandPaletteVisible = true
            }
        }
        .toolbar { toolbarContent }
        // 单一 alert 通道：告知与确认共用一条，避免两个 `.alert` 修饰符在同一个窗口上
        // 互相抢展示权（后挂的那个会赢，先挂的直接不出现）。
        .alert(
            state.alert?.title ?? "",
            isPresented: Binding(
                get: { state.alert != nil },
                set: { if !$0 { state.alert = nil } }
            ),
            presenting: state.alert
        ) { alert in
            switch alert.kind {
            case .message:
                Button("好") { state.alert = nil }
            case .confirm(let confirmTitle, let isDestructive):
                Button(confirmTitle, role: isDestructive ? .destructive : nil) {
                    // 先收掉 alert 再执行动作：动作里往往要再弹一次提示或改状态，
                    // 在 alert 还挂着的时候做，新提示会被系统吞掉。
                    let action = alert.action
                    state.alert = nil
                    action?()
                }
                Button("取消", role: .cancel) { state.alert = nil }
            }
        } message: { alert in
            Text(alert.message)
        }
    }

    /// 把窗口内容区改成指定尺寸（自检用）。
    ///
    /// 必须轮询等窗口出现：`.task` 可能在 SwiftUI 建窗之前就跑起来了，
    /// 一次性取 `NSApp.windows.first` 会拿到 nil，然后自检就以默认尺寸跑完，
    /// 结论「窄窗口没问题」是假的。
    private static func applyWindowSize(_ size: CGSize) async {
        for _ in 0..<30 {
            if let window = NSApp.windows.first(where: { ($0.contentView?.bounds.height ?? 0) > 100 }) {
                window.setContentSize(size)
                // 让布局跑完一轮再交还给后续流程，避免截图拍到改尺寸前的画面
                try? await Task.sleep(nanoseconds: 250_000_000)
                return
            }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        NSLog("[Lumen] 未能应用自检窗口尺寸：始终没等到窗口")
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            Button {
                withAnimation(DS.Motion.panel) { state.isSidebarVisible.toggle() }
            } label: {
                Image(systemName: "sidebar.leading")
            }
            .help(helpText(state.isSidebarVisible ? "隐藏侧栏" : "显示侧栏", for: .toggleSidebar))
            .disabled(state.document == nil)
        }

        ToolbarItem(placement: .principal) {
            VStack(spacing: 1) {
                Text(state.document?.displayTitle ?? "流明")
                    .font(DS.Typo.headline)
                    .foregroundStyle(DS.Palette.textPrimary)
                    .lineLimit(1)
                if let detail = state.document?.detail, !detail.isEmpty {
                    Text(detail)
                        .font(DS.Typo.caption)
                        .foregroundStyle(DS.Palette.textTertiary)
                }
            }
            .frame(maxWidth: 420)
        }

        ToolbarItemGroup(placement: .primaryAction) {
            // 「复制」菜单：复制全文 / 复制文件是新加的能力，藏在菜单栏的「编辑」里
            // 还算符合直觉，但阅读时手在窗口里，给一个工具栏入口更找得到。
            Menu {
                Button("复制全文为纯文本") { state.copyFullText() }
                    .disabled(state.bridge.extractFullText == nil)
                Button("复制文件") { state.copyDocumentFileToPasteboard() }
                Divider()
                Button("导出 AI 摘要为 Markdown…") { state.exportSummaryToFile() }
                    .disabled(state.chat.lastSubstantialAnswer.isEmpty)
                Button("导出对话记录为 Markdown…") { state.exportTranscriptToFile() }
                    .disabled(state.chat.bubbles.isEmpty)
            } label: {
                Image(systemName: "doc.on.doc")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .frame(width: 26)
            .help("复制与导出")
            .disabled(state.document == nil)

            Button {
                withAnimation(DS.Motion.panel) { state.isAIPanelVisible.toggle() }
            } label: {
                Image(systemName: state.isAIPanelVisible ? "sparkles.rectangle.stack.fill" : "sparkles.rectangle.stack")
            }
            .help(helpText(state.isAIPanelVisible ? "隐藏 AI 面板" : "显示 AI 面板", for: .toggleAIPanel))
            .disabled(state.document == nil)

            Button {
                state.showOpenPanel()
            } label: {
                Image(systemName: "folder")
            }
            .help(helpText("打开文档", for: .openDocument))
        }
    }

    /// 提示文案带上用户当前的真实绑定，而不是写死的默认值——
    /// 否则改了快捷键之后，悬停提示会一直骗人。
    private func helpText(_ label: String, for action: LumenAction) -> String {
        guard let combo = keyBindings.combo(for: action) else { return label }
        return "\(label) (\(combo.display))"
    }
}
