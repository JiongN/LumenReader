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

    /// 窗口最终该用深色还是浅色。
    ///
    /// 打开文档后由阅读主题统辖（选了「深夜」就整屏暗下来），欢迎页跟随系统深浅色。
    /// 抽成属性而不是把三元留在修饰符链里，理由见 `.windowAppearance` 那行的注释。
    private var effectiveIsDark: Bool {
        state.document == nil ? systemIsDark : state.settingsStore.reader.theme.isDark
    }

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
        // 主题过渡**只挂在这块垫色上**。
        //
        // 之前这个 `.animation(theme)` 直接挂在 `Group` 上，覆盖面是整棵子树——
        // 注释写着「不往下碰阅读内容」，实现上却把 `ReaderContainerView`（内含
        // PDFView / WKWebView）一起卷进了动画事务，主题一变每帧都要为它们求可动画值。
        // 收窄到背景层之后，动画作用域才和注释一致：只有这块纯 SwiftUI 颜色在插值。
        // （PDF 要整页重绘、WebView 要重新排版，卷进动画只会看到闪白；
        //   窗口外观 `windowAppearance` 是即时生效的 AppKit 属性，也没法插值。）
        .background(ThemeBackdrop(
            isWelcome: state.document == nil,
            themeID: state.settingsStore.reader.themeID
        ))
        .overlay {
            if state.isCommandPaletteVisible {
                CommandPaletteOverlay()
                    .transition(.opacity)
            }
        }
        // 跳页输入条独立成一层，不和命令面板复用同一个 overlay：
        // 两者可能被同时触发（⌘K 里再按 ⌘G），共用一层时后挂的 transition 会赢，
        // 结果是一个的进出动画按另一个的令牌跑。
        .overlay {
            if state.isPageJumpVisible {
                PageJumpPanel()
                    .transition(.opacity)
            }
        }
        .overlay { BusyOverlay() }
        .overlay(alignment: .top) { ToastLayer().padding(.top, 76) }
        // 沉浸模式的悬浮控制条。挂在最外层而不是阅读区里：
        // 它要在全屏窗口的底部中央出现，而阅读区在沉浸时可能已经被收窄居中，
        // 锚在阅读区上会跟着一起缩，位置就不在"屏幕底部"了。
        .overlay(alignment: .bottom) { ImmersiveHUD() }
        // 打开文档后由阅读主题统辖窗口外观；欢迎页跟随系统深浅色。
        // 用计算属性而不是把三元写进来：三元里的两次属性链访问同样会给
        // 编译器增加推断负担，而这行已经在一条很长的修饰符链上了。
        .windowAppearance(isDark: effectiveIsDark)
        // 窗口探针：把主窗口交给 AppState（全屏必须作用在它上面，
        // 而不是 keyWindow——在设置窗口点过一下就会打错对象），
        // 并接住系统全屏的进出通知。沉浸模式此前只有「去程」没有「回程」，
        // 用系统方式退出全屏后状态永远卡在沉浸里，就是丢在这里。
        .windowState(state)
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
            // 自检不记「最近打开」：测试书会把用户真实的阅读记录顶下去，
            // 而跑自检的人并不是在读这本书。正常从命令行开一本书照旧记录。
            let records = !LaunchOptions.isAuditRun
            if !records {
                NSLog("[Lumen] 自检模式：本次打开的文档不写入「最近打开」")
            }
            state.open(url: URL(fileURLWithPath: path), recordInRecents: records)

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
        // 沉浸模式下把工具栏也收掉。用 SwiftUI 的可见性修饰符而不是直接动
        // `window.toolbar`：在 `.unified` 样式下两者共享同一个 NSToolbar，
        // 从 AppKit 侧改会和 SwiftUI 的同步逻辑打架（表现为工具栏偶发不回来）。
        .toolbar(state.isImmersive ? .hidden : .visible, for: .windowToolbar)
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
                state.setImmersive(!state.isImmersive)
            } label: {
                Image(systemName: state.isImmersive
                      ? "arrow.down.right.and.arrow.up.left"
                      : "arrow.up.left.and.arrow.down.right")
            }
            .help(helpText("沉浸阅读模式", for: .toggleImmersive))
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

// MARK: - 主题垫色

/// 阅读器与欢迎页共用的一层垫色，**主题切换的过渡只做在这里**。
///
/// 单独成一个视图而不是内联成 `.background { … }` 闭包：闭包里的三元表达式
/// 会叠进 `body` 那条已经很长的修饰符链，把编译器的类型推断拖垮
/// （报 `unable to type-check this expression in reasonable time`）。
/// 顺带也把「过渡边界在哪儿」变成一处能指认的代码，而不是链条里的一段闭包。
private struct ThemeBackdrop: View {

    let isWelcome: Bool
    let themeID: ReadingThemeID

    var body: some View {
        (isWelcome ? DS.Palette.surfaceSunken : Color.clear)
            .animation(DS.Motion.theme, value: themeID)
    }
}
