import SwiftUI
import AppKit
import LumenKit
import LumenKit

struct RootView: View {

    /// 每个窗口一份工作区。由 `WindowManager` 显式创建窗口时注入；
    /// 用 StateObject 接住，保证窗口生命周期内不被重建。
    @StateObject private var state: AppState
    @ObservedObject private var settings: SettingsStore

    @Environment(\.colorScheme) private var systemColorScheme
    /// 打开「设置」窗口。用官方的环境动作，不去 sendAction 那些私有 selector——
    /// 私有 selector 的名字在 macOS 14 前后变过一次，且失败时静默无返回，很难查。
    @Environment(\.openSettings) private var openSettings

    init(state: AppState) {
        _state = StateObject(wrappedValue: state)
        _settings = ObservedObject(wrappedValue: state.settingsStore)
    }

    private var systemIsDark: Bool { systemColorScheme == .dark }

    /// 窗口最终该用深色还是浅色。
    ///
    /// 打开文档后由阅读主题统辖（选了「深夜」就整屏暗下来），欢迎页跟随系统深浅色。
    private var effectiveIsDark: Bool {
        state.document == nil ? systemIsDark : settings.reader.theme.isDark
    }

    var body: some View {
        VStack(spacing: 0) {
            // 标签栏：有文档且非沉浸时才出现。欢迎页不需要，沉浸模式要「只剩正文」。
            if state.activeSession != nil && !state.isImmersive {
                TabBar()
            }

            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        // 标题栏透明（fullSizeContentView）后，让整棵树延伸到窗口最顶，标签栏才能与
        // 红黄绿交通灯落在同一行（Obsidian 式）。交通灯悬浮在最左，TabBar 已预留空位。
        .ignoresSafeArea(edges: .top)
        // 窗口级浮层与菜单动作一律作用于「当前标签」：这里注入当前会话的对象，
        // 各标签宿主内部还会再注入自己的会话，保证后台标签不串台。
        .environmentObject(state.bridge)
        .environmentObject(state.chat)
        .environmentObject(state.smartOutline)
        // 沉浸 HUD（ImmersiveHUD）在 overlay 里 `@EnvironmentObject` 读 AppState 与
        // KeyBindingStore；这里必须注入，否则沉浸条一浮现就因缺环境对象崩溃（EnvironmentObject.error）。
        .environmentObject(state)
        .environmentObject(state.keyBindings)
        // 欢迎页 ↔ 阅读器之间交叉淡入。
        .animation(DS.Motion.content, value: state.document?.id)
        // 主题过渡**只挂在这块垫色上**（见 ThemeBackdrop 注释）。
        .background(ThemeBackdrop(
            isWelcome: state.document == nil,
            themeID: settings.reader.themeID
        ))
        .overlay {
            if state.isCommandPaletteVisible {
                CommandPaletteOverlay()
                    .transition(.opacity)
            }
        }
        .overlay {
            if state.isPageJumpVisible {
                PageJumpPanel()
                    .transition(.opacity)
            }
        }
        .overlay { BusyOverlay() }
        .overlay(alignment: .top) { ToastLayer().padding(.top, 76) }
        // 沉浸模式的悬浮控制条。环境对象在用点再显式注入一遍：根链上已注入
        // （见上方 environmentObject 系列），但 ImmersiveHUD 是挂在链尾的 overlay、
        // 且同时读 state / bridge / keyBindings 三个对象，历史上它曾因环境缺失
        // 在「控制条浮现」时崩溃——用点直注把这条路径彻底钉死，双保险。
        .overlay(alignment: .bottom) {
            ImmersiveHUD()
                .environmentObject(state)
                .environmentObject(state.bridge)
                .environmentObject(state.keyBindings)
        }
        .windowAppearance(isDark: effectiveIsDark)
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

            // --open 由 WindowManager.startup 在建窗时处理（要进标签而不是替换文档）。

            if let prompt = LaunchOptions.askPrompt {
                // 等阅读视图与聊天模型完成绑定
                try? await Task.sleep(nanoseconds: 1_200_000_000)
                state.pendingAIRequest = AIRequest(kind: .custom, customPrompt: prompt)
            }

            if LaunchOptions.opensPalette {
                try? await Task.sleep(nanoseconds: 600_000_000)
                state.isCommandPaletteVisible = true
            }
        }
        .onAppear { ThemePalette.shared.theme = settings.reader.theme }
        .onChange(of: settings.reader.themeID) { _, _ in
            ThemePalette.shared.theme = settings.reader.theme
        }
        .tint(settings.reader.theme.accent)
        // 顶部只有一条标签栏（TabBar 已并入侧栏/AI/复制/沉浸等操作按钮），不再有
        // 独立的窗口工具栏「标题行」，避免「工具栏 + 标签行」叠成两行。
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

    /// 主区域：有标签时是「全部已挂载标签的叠层」，否则是欢迎页。
    @ViewBuilder
    private var content: some View {
        if state.activeSession != nil {
            sessionStack
                .transition(.opacity)
        } else {
            WelcomeView()
                .transition(.opacity)
        }
    }

    /// 标签宿主叠层：访问过的标签都保活（PDF/WebView 不重新解析），
    /// 非当前标签透明且不接收点击。
    private var sessionStack: some View {
        ZStack {
            ForEach(state.sessions) { session in
                if state.loadedSessionIDs.contains(session.id) {
                    SessionHostView(session: session)
                        // 让每个标签宿主撑满 ZStack 的高度（而不是停在子视图的理想高度）。
                        // 不撑的话 ReaderContainerView 的三栏只用到窗口约一半的高度，
                        // 上方会留下一大片空白（底部对齐）。加这里 <-> 外部 content 的
                        // `.frame(maxHeight: .infinity)` 配合，阅读区高度才等于内容区高度。
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .opacity(session.id == state.activeSessionID ? 1 : 0)
                        .allowsHitTesting(session.id == state.activeSessionID)
                        .accessibilityHidden(session.id != state.activeSessionID)
                }
            }
        }
        .animation(DS.Motion.quick, value: state.activeSessionID)
    }

    /// 把窗口内容区改成指定尺寸（自检用）。
    private static func applyWindowSize(_ size: CGSize) async {
        for _ in 0..<30 {
            if let window = NSApp.windows.first(where: { ($0.contentView?.bounds.height ?? 0) > 100 }) {
                window.setContentSize(size)
                try? await Task.sleep(nanoseconds: 250_000_000)
                return
            }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        NSLog("[Lumen] 未能应用自检窗口尺寸：始终没等到窗口")
    }

}

// MARK: - 标签宿主

/// 一个标签的完整阅读界面：注入这份会话专属的 bridge / chat / smartOutline，
/// 保证后台标签的请求、对话、目录互不串台。
struct SessionHostView: View {

    @ObservedObject var session: ReaderSession

    var body: some View {
        ReaderContainerView(session: session)
            .environmentObject(session)
            .environmentObject(session.bridge)
            .environmentObject(session.chat)
            .environmentObject(session.smartOutline)
    }
}

// MARK: - 主题垫色

/// 阅读器与欢迎页共用的一层垫色，**主题切换的过渡只做在这里**。
private struct ThemeBackdrop: View {

    let isWelcome: Bool
    let themeID: ReadingThemeID

    var body: some View {
        (isWelcome ? DS.Palette.surfaceSunken : Color.clear)
            .animation(DS.Motion.theme, value: themeID)
    }
}
