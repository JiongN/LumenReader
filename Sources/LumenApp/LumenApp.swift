import SwiftUI
import AppKit
import LumenKit

@main
struct LumenApp: App {

    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        // 阅读器窗口由 AppKit（WindowManager）显式创建与管理，不走 WindowGroup：
        // WindowGroup 对外部文件打开事件的默认行为是「每份文件开一个新窗口」，
        // 无法改成「进当前窗口的新标签」。这里只保留 SwiftUI 的设置场景。
        Settings {
            SettingsRootView()
                .environmentObject(WindowManager.shared.utilityWorkspace)
                .environmentObject(WindowManager.shared.services.settingsStore)
                .environmentObject(WindowManager.shared.services.memory)
                .environmentObject(WindowManager.shared.services.keyBindings)
                // 680 宽放得下五个页签；高度给到 640 是因为「快捷键」页有 16 行，
                // 580 一屏只能看到一半，来回滚动很烦。
                .frame(width: 680, height: 640)
        }
        .commands {
            LumenCommands()
        }
    }
}

// MARK: - 应用生命周期

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {

    /// 本次运行的构建标记（dist bundle 里由 build.sh 写入的 lumen-build-stamp）。
    /// 拿不到时给出明确提示——多半意味着跑的不是 dist 产物，而是某个旧副本。
    static var buildStamp: String {
        guard let url = Bundle.main.url(forResource: "lumen-build-stamp", withExtension: nil),
              let text = try? String(contentsOf: url, encoding: .utf8)
                  .trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty else { return "未知（不在 dist 产物内？）" }
        return text
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // 从命令行 / `open` 启动时保证窗口前置并获得焦点
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)

        NSLog("[Lumen] 启动参数：\(CommandLine.arguments.dropFirst().joined(separator: " "))")
        // 构建标记随每次启动打印。背景：build.sh 每次构建会把旧 bundle 挪进
        // dist/.trash，而 Launch Services 仍保留旧路径的注册——从 Spotlight /
        // 「打开方式」进来可能复活旧二进制，症状与「修复没生效」一模一样。
        // 有了这行日志，一眼即可分辨当前跑的是哪一次构建。
        NSLog("[Lumen] 构建标记：\(AppDelegate.buildStamp)")

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

        // OCR 右键菜单自检：纯函数表驱动断言（菜单本身没法自动化验证）
        OCRMenuAudit.run()

        // Agent 自检：预设、提示词拼装、一次真实的联网文献检索
        if LaunchOptions.agentReport {
            Task { await AgentAudit.run() }
        }

        // 联网文献检索自检：逐源跑一遍，记录命中数 / 失败 / 耗时（真实联网）
        if LaunchOptions.webSearchReport {
            Task { await WebSearchAudit.run() }
        }

        // 钥匙串自检：只读查询，打印访问成本与缓存状态（不写不删用户钥匙串）
        // Credentials are local files; no keychain queries during startup.

        // 字体目录后台预热：用户点开字体选择器时就不必看到"正在读取系统字体…"
        FontCatalog.prewarm()

        // 显式创建第一个阅读器窗口（欢迎页或 --open 指定的文档）。
        // 必须在截图自检注册之前：窗口是同步创建的，不再依赖 SwiftUI 场景的异步装配。
        WindowManager.shared.startup()

        // AppKit 显式建窗后 SwiftUI 命令菜单的快捷键不落地，在这里装全局按键路由。
        GlobalShortcutRouter.shared.install(services: WindowManager.shared.services)
        // 标题栏透明 + 没有系统工具栏后，AppKit 仍会给「帮助」菜单自动塞一个
        // 「Toggle Sidebar ⌘S」。它与我们的自定义 ⌘S 抢键，正是冲突音来源。清掉它的键等价物。
        stripSystemToggleSidebarShortcut()

        WindowCapture.scheduleCaptureIfRequested()

        // 快捷键自检：合成 ⌘⌥S 喂给全局路由，验证面板切换真正响应。
        if LaunchOptions.shortcutReport {
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 800_000_000)
                runShortcutSelfCheck()
            }
        }

        // 自检：延时把当前标签拆到独立窗口（无辅助功能权限也能验证 detach 链路）。
        if let delay = LaunchOptions.detachAfter {
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                WindowManager.shared.detachActiveForAudit()
                // 再把来源窗口置前：非关键窗口里 PDFKit 会暂停绘制，
                // 截图通道需要它在关键窗口状态下才能拍到剩余标签的真实画面。
                try? await Task.sleep(nanoseconds: 2_500_000_000)
                WindowManager.shared.focusSourceWorkspaceForAudit()
            }
        }
    }

    /// 外部「打开文件」事件（访达打开方式 / 拖到 Dock 图标 / `open -a`）：
    /// 全部进当前窗口的新标签，而不是让系统再开一个窗口。
    func application(_ application: NSApplication, open urls: [URL]) {
        WindowManager.shared.openExternally(urls: urls)
    }

    /// 阅读器不是常驻后台工具，关掉最后一个窗口就应当退出。
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            WindowManager.shared.ensureWindow()
        }
        return true
    }
}

// 把键名折成键码（仅自检合成事件用；路由器匹配主要靠 characters，非特殊键给个非特殊码即可）
private func keyCodeFor(_ name: String) -> UInt16 {
    switch name {
    case KeyCombo.SpecialKey.leftArrow:  return 123
    case KeyCombo.SpecialKey.rightArrow: return 124
    case KeyCombo.SpecialKey.downArrow:  return 125
    case KeyCombo.SpecialKey.upArrow:    return 126
    case KeyCombo.SpecialKey.escape:     return 53
    case KeyCombo.SpecialKey.tab:        return 48
    case KeyCombo.SpecialKey.space:      return 49
    case KeyCombo.SpecialKey.return:     return 36
    case KeyCombo.SpecialKey.delete:     return 51
    default: break
    }
    // 字母/数字：近似取 ANSI 键码；路由器用 characters 匹配，键码只需非特殊即可
    let lower = name.lowercased()
    if let sc = lower.unicodeScalars.first, sc.value >= 97, sc.value <= 122 {
        // 'a'=0 起；'s'=1。用字符到常用键码的近似映射即可自洽。
        return UInt16(sc.value - 96)
    }
    return 1
}

/// 去掉 AppKit 自动注入的「Toggle Sidebar ⌘S」菜单项键等价物。
///
/// 只要窗口还带 `.titled`，AppKit 就会在「帮助」菜单自动生成一个 Toggle Sidebar 项
/// 并把 ⌘S 设给它，跟我们的自定义键盘路由抢同一个键 → 按下时系统先响冲突音。
/// 我们用自己的 GlobalShortcutRouter 负责按键，不再需要这个系统项的快捷键，
/// 只保留菜单项本身（可鼠标点，无副作用）。遍历主菜单把它的 keyEquivalent 清空。
@MainActor
func stripSystemToggleSidebarShortcut() {
    func strip(in menu: NSMenu) {
        for item in menu.items {
            if item.submenu != nil { strip(in: item.submenu!) ; continue }
            if item.title == "Toggle Sidebar" && item.keyEquivalent != "" {
                item.keyEquivalent = ""
                NSLog("[Lumen][keys] 已清除系统 Toggle Sidebar 的 ⌘s 键等价物（避免冲突音）")
            }
        }
    }
    if let main = NSApp.mainMenu { strip(in: main) }
}

// 快捷键自检：合成 keyDown 事件过一遍全局路由（无辅助功能权限也可验证）
@MainActor func runShortcutSelfCheck() {
    guard let workspace = WindowManager.shared.activeWorkspace else {
        NSLog("[Lumen][keys] 自检：没有活动工作区，跳过")
        return
    }
    let kb = WindowManager.shared.services.keyBindings
    // 用当前配置的真实组合拼事件，而不是硬编码 ⌘⌥S——用户可能已改绑/清空。
    guard let combo = kb.combo(for: .toggleSidebar) else {
        NSLog("[Lumen][keys] toggleSidebar 无有效组合（已被清空），跳过")
        return
    }
    var flags: NSEvent.ModifierFlags = []
    if combo.modifiers.contains(KeyModifier.command) { flags.insert(NSEvent.ModifierFlags.command) }
    if combo.modifiers.contains(KeyModifier.option)  { flags.insert(NSEvent.ModifierFlags.option) }
    if combo.modifiers.contains(KeyModifier.shift)   { flags.insert(NSEvent.ModifierFlags.shift) }
    if combo.modifiers.contains(KeyModifier.control) { flags.insert(NSEvent.ModifierFlags.control) }
    let char = combo.key
    let keyCode = keyCodeFor(char)   // 专门为自检把字符折成键码
    let ev = NSEvent.keyEvent(with: .keyDown, location: .zero,
                              modifierFlags: flags,
                              timestamp: 0, windowNumber: 0, context: nil,
                              characters: char, charactersIgnoringModifiers: char,
                              isARepeat: false, keyCode: keyCode)!
    let sidCombo = kb.combo(for: .toggleSidebar)
    let sidEnabled = LumenAction.toggleSidebar.isEnabled(in: workspace)
    NSLog("[Lumen][keys] toggleSidebar combo=\(sidCombo?.display ?? "nil") isEnabled=\(sidEnabled)")
    let before = workspace.isSidebarVisible
    let consumed = GlobalShortcutRouter.shared.routeTest(ev)
    let after = workspace.isSidebarVisible
    let changed = before != after
    NSLog("[Lumen][keys] 侧栏 ⌘⌥S 被消费=\(consumed) 翻转=\(changed) 前=\(before) 后=\(after)")
    NSLog("[Lumen][keys] 自检结果：\(consumed && changed ? "通过 ✅" : "失败 ❌")")
}

// MARK: - 菜单与快捷键

/// 菜单栏。
///
/// 可改绑动作（`LumenAction`）的快捷键不在菜单上注册，统一由
/// `GlobalShortcutRouter` 在 AppKit 层监听、命中即整包吞掉。菜单只提供可点击入口，
/// 用于鼠标操作与可发现性。这样菜单键等价物与路由不会同时认领同一组合键，
/// 也从根上消除了「菜单项被禁用时快捷键响冲突音」的问题。
/// 少数非 `LumenAction` 的窗口级快捷键（新建标签 ⌘T、上一个/下一个标签 ⌘⇧[、⌘⇧]、
/// 退出沉浸 Esc）仍在菜单项上注册，因为路由没有对应的动作可路由。
///
/// 多窗口后菜单动作落在**最前面窗口的工作区**（`WindowManager.activeWorkspace`）。
@MainActor
struct LumenCommands: Commands {

    @ObservedObject private var windows = WindowManager.shared

    private var state: AppState? { windows.activeWorkspace }

    var body: some Commands {
        // 文件
        CommandGroup(replacing: .newItem) {
            item(.openDocument)
            item(.openMostRecent)
            item(.closeDocument)

            Divider()

            // 新建标签 = 打开文件（可多选）。默认一个窗口多标签；
            // 想要独立窗口，请右键标签选「在独立窗口打开」。
            Button("新建标签页") {
                state?.showOpenPanel()
            }
            .keyboardShortcut("t", modifiers: .command)
            .disabled(state == nil)

            Divider()

            item(.copyFile)

            Divider()

            Menu("导出") {
                item(.exportSummary)
                Button("对话记录为 Markdown…") { state?.exportTranscriptToFile() }
                    .disabled(state?.chat.bubbles.isEmpty ?? true)
            }

            Divider()

            Menu("最近打开") {
                if windows.services.recent.entries.isEmpty {
                    Text("暂无记录")
                } else {
                    ForEach(windows.services.recent.entries.prefix(12)) { entry in
                        Button(entry.displayName) {
                            WindowManager.shared.openExternally(urls: [entry.url])
                        }
                        .disabled(!entry.fileExists)
                    }
                    Divider()
                    Button("清除记录") { windows.services.recent.clear() }
                }
            }
        }

        // 标签页：窗口间管理与标签切换
        CommandMenu("标签页") {
            Button("上一个标签页") { state?.cycleTab(forward: false) }
                .keyboardShortcut("[", modifiers: [.command, .shift])
                .disabled((state?.sessions.count ?? 0) < 2)
            Button("下一个标签页") { state?.cycleTab(forward: true) }
                .keyboardShortcut("]", modifiers: [.command, .shift])
                .disabled((state?.sessions.count ?? 0) < 2)

            Divider()

            Button("在独立窗口打开当前标签") { state?.detach() }
                .disabled(state?.activeSession == nil)
            Button("关闭其他标签页") {
                if let current = state?.activeSession {
                    state?.closeOthers(keeping: current)
                }
            }
            .disabled((state?.sessions.count ?? 0) < 2)
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
            Button("退出沉浸模式") { state?.setImmersive(false) }
                .keyboardShortcut(.escape, modifiers: [])
                .disabled(state?.isImmersive != true)

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
            Button(state?.smartOutline.outline == nil ? "生成 AI 智能目录" : "重新生成 AI 智能目录") {
                state?.generateSmartOutline()
            }
            .disabled(state?.document == nil
                || state?.bridge.unitSnippetProvider == nil
                || state?.smartOutline.phase.isWorking == true)

            Button("查看 AI 智能目录") { state?.revealSidebar(tab: .smartOutline) }
                .disabled(state?.document == nil || state?.smartOutline.outline == nil)
        }
    }

    /// 菜单项。可用性判断与命令面板共用同一套，避免两处状态不一致。
    /// 没有阅读器窗口时（极少数时序）菜单项可见但不可点。
    @ViewBuilder
    private func item(_ action: LumenAction) -> some View {
        if let state {
            // 快捷键统一由 GlobalShortcutRouter 在 AppKit 层监听，命中后整包吞掉；
            // 菜单这里不再挂 .keyboardShortcut，否则菜单键等价物会和路由同时认领同一
            // 组合键——菜单项一旦被禁用，系统就会对这些键响「冲突音」。
            Button(action.title) { action.run(state) }
                .disabled(!action.isEnabled(in: state))
        } else {
            Button(action.title) {}
                .disabled(true)
        }
    }
}
