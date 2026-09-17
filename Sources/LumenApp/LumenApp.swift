import SwiftUI
import AppKit
import LumenKit

@main
struct LumenApp: App {

    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var state = AppState()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(state)
                .environmentObject(state.settingsStore)
                .environmentObject(state.recent)
                .environmentObject(state.memory)
                .environmentObject(state.chat)
                .environmentObject(state.bridge)
                .environmentObject(state.keyBindings)
                .frame(minWidth: 920, minHeight: 620)
                .onOpenURL { url in
                    if url.isFileURL {
                        state.open(url: url)
                    }
                }
        }
        .windowToolbarStyle(.unified(showsTitle: false))
        .defaultSize(width: 1340, height: 860)
        .commands { LumenCommands(state: state, keyBindings: state.keyBindings) }

        Settings {
            SettingsRootView()
                .environmentObject(state)
                .environmentObject(state.settingsStore)
                .environmentObject(state.memory)
                .environmentObject(state.keyBindings)
                // 680 宽放得下五个页签；高度给到 640 是因为「快捷键」页有 16 行，
                // 580 一屏只能看到一半，来回滚动很烦。
                .frame(width: 680, height: 640)
        }
    }
}

// MARK: - 应用生命周期

final class AppDelegate: NSObject, NSApplicationDelegate {

    func applicationDidFinishLaunching(_ notification: Notification) {
        // 从命令行 / `open` 启动时保证窗口前置并获得焦点
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)

        NSLog("[Lumen] 启动参数：\(CommandLine.arguments.dropFirst().joined(separator: " "))")

        if LaunchOptions.fontReport {
            Task { await FontCatalog.logReport() }
        }

        if LaunchOptions.themeReport {
            let ids = ReadingTheme.all.map { "\($0.id.rawValue)/\($0.id.displayName)" }
            NSLog("[Lumen][theme] 可选主题 \(ReadingTheme.all.count) 个：\(ids.joined(separator: "、"))")
            NSLog("[Lumen][theme] 是否含纯黑 oled：\(ReadingTheme.all.contains { $0.id == .oled })")
            NSLog("[Lumen][theme] theme(for: .oled) → \(ReadingTheme.theme(for: .oled).id.rawValue)")
            NSLog("[Lumen][theme] ReadingThemeID.oled.migrated → \(ReadingThemeID.oled.migrated.rawValue)")
        }

        // 快捷键自检：打印当前表并实跑一遍改绑规则（用临时文件，不碰用户配置）
        KeyBindingsAudit.run()

        // 钥匙串自检：只读查询，打印访问成本与缓存状态（不写不删用户钥匙串）
        KeychainAudit.run()

        // 字体目录后台预热：用户点开字体选择器时就不必看到"正在读取系统字体…"
        FontCatalog.prewarm()

        WindowCapture.scheduleCaptureIfRequested()
    }

    /// 阅读器不是常驻后台工具，关掉最后一个窗口就应当退出。
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            for window in sender.windows where window.canBecomeMain {
                window.makeKeyAndOrderFront(nil)
                break
            }
        }
        return true
    }
}

// MARK: - 菜单与快捷键

/// 菜单栏。
///
/// 所有快捷键都从 `KeyBindingStore` 现取，不再在代码里写死 `.keyboardShortcut("s")`——
/// 否则用户在设置页改了绑定，菜单里显示的却还是旧组合，按下去也不生效。
/// 这也是为什么 `item(_:)` 里读的是 `combo(for:)?.keyboardShortcut`：
/// 拿不到组合（用户清空了）时传 nil，SwiftUI 会把快捷键整个去掉，菜单项仍然可用。
struct LumenCommands: Commands {

    @ObservedObject var state: AppState
    @ObservedObject var keyBindings: KeyBindingStore

    var body: some Commands {
        // 文件
        CommandGroup(replacing: .newItem) {
            item(.openDocument)
            item(.openMostRecent)
            item(.closeDocument)

            Divider()

            item(.copyFile)

            Divider()

            Menu("导出") {
                item(.exportSummary)
                Button("对话记录为 Markdown…") { state.exportTranscriptToFile() }
                    .disabled(state.chat.bubbles.isEmpty)
            }

            Divider()

            Menu("最近打开") {
                if state.recent.entries.isEmpty {
                    Text("暂无记录")
                } else {
                    ForEach(state.recent.entries.prefix(12)) { entry in
                        Button(entry.displayName) { state.reopen(entry) }
                            .disabled(!entry.fileExists)
                    }
                    Divider()
                    Button("清除记录") { state.recent.clear() }
                }
            }
        }

        // 显示
        CommandGroup(after: .toolbar) {
            Divider()
            item(.toggleSidebar)
            item(.toggleAIPanel)
            item(.toggleImmersive)

            // 沉浸模式的 Esc 出口。
            //
            // 敢用 Esc 的前提是：菜单项被 `.disabled` 时 SwiftUI 会一并释放它的快捷键，
            // 所以非沉浸状态下 Esc 不会被我这条抢走——命令面板、跳页输入框、划词操作
            // 都靠 Esc 关闭，抢了它们会集体失灵。
            Button("退出沉浸模式") { state.setImmersive(false) }
                .keyboardShortcut(.escape, modifiers: [])
                .disabled(!state.isImmersive)

            Divider()

            item(.commandPalette)
        }

        // 编辑：全文复制紧跟在系统「复制」后面，是最符合直觉的位置
        CommandGroup(after: .pasteboard) {
            Divider()
            item(.copyFullText)
        }

        // 排版
        CommandGroup(after: .textFormatting) {
            item(.fontIncrease)
            item(.fontDecrease)
        }

        // 阅读：翻页、跳页、侧栏页签
        //
        // 这个菜单不是为了「多一个入口」，而是**快捷键生效的前提**：
        // SwiftUI 的 `.keyboardShortcut` 只有在菜单项上才会全局响应。
        // 这些动作原先只在命令面板里有，于是 ⌘G、⌥⌘→ 这些绑定了也不会真的响应——
        // 用户能在设置页改它们，改了却按不出效果，属于骗人。
        CommandMenu("阅读") {
            item(.goToPage)

            Divider()

            item(.nextUnit)
            item(.previousUnit)

            Divider()

            item(.showOutline)
            item(.showSmartOutline)
            item(.showSearch)
            item(.showAnnotations)
            item(.showThumbnails)

            Divider()

            // 「生成」与「查看」分开：前者要花钱、要等十几秒，做成菜单项但不给快捷键——
            // 一次误触的代价是一次真实的模型调用。查看那一项才值得绑快捷键（⌘2）。
            Button(state.smartOutline.outline == nil ? "生成 AI 智能目录" : "重新生成 AI 智能目录") {
                state.generateSmartOutline()
            }
            .disabled(state.document == nil
                || state.bridge.unitSnippetProvider == nil
                || state.smartOutline.phase.isWorking)

            Button("查看 AI 智能目录") { state.revealSidebar(tab: .smartOutline) }
                .disabled(state.document == nil || state.smartOutline.outline == nil)
        }
    }

    /// 菜单项。可用性判断与命令面板共用同一套，避免两处状态不一致。
    @ViewBuilder
    private func item(_ action: LumenAction) -> some View {
        Button(action.title) { action.run(state) }
            .keyboardShortcut(keyBindings.combo(for: action)?.keyboardShortcut)
            .disabled(!action.isEnabled(in: state))
    }
}
