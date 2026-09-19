import SwiftUI
import AppKit
import Combine
import LumenKit

// MARK: - 跨窗口共享服务

/// 与窗口 / 标签无关、整个进程共享一份的服务。
///
/// 设置、最近打开、快捷键、跨会话记忆都是「应用级」的东西：
/// 无论在哪个窗口改设置，所有窗口立刻生效；记忆也不绑定任何一本书。
/// 窗口自己的状态（打开了哪些标签、面板收不收、沉浸与否）在 `AppState` 里。
@MainActor
final class AppServices: ObservableObject {

    let settingsStore: SettingsStore
    let recent: RecentDocuments
    let keyBindings: KeyBindingStore
    let memory: MemoryStore

    init(
        settingsStore: SettingsStore? = nil,
        recent: RecentDocuments? = nil
    ) {
        let settings = settingsStore ?? SettingsStore()
        self.settingsStore = settings
        self.recent = recent ?? RecentDocuments()
        self.keyBindings = KeyBindingStore()
        self.memory = MemoryStore()

        // ── 自检开关：以前写在 AppState.init 里，挪到共享服务这一层 ──
        // 主题不走这里（setter 会防抖落盘）；这里只处理会污染 settings.json 的项。

        // --panel-width：与拖动分隔线同一个设置项（侧栏分量已废弃，仅解析不生效）。
        if let panel = LaunchOptions.panelWidth {
            settings.suppressSave = true
            settings.commitAIPanelWidth(panel.ai)
            NSLog("[Lumen] 自检：--panel-width 只设 AI 面板 = \(Int(panel.ai))pt"
                  + "（侧栏分量 \(Int(panel.sidebar))pt 已废弃，侧栏固定 \(Int(UISettings.PanelWidth.sidebarDefault))pt）")
        }

        if LaunchOptions.perfReport {
            settings.suppressSave = true
        }
        // 卡顿自检（含 --jank-watch 真实交互）都会高频改宽度 / 阅读位置，统一关落盘。
        if LaunchOptions.jankReport || LaunchOptions.jankWatch {
            settings.suppressSave = true
        }

        if LaunchOptions.isAuditRun {
            settings.suppressSave = true
            if let value = LaunchOptions.value(for: "--reading-theme"), let theme = ReadingThemeID(rawValue: value) {
                settings.reader.themeID = theme
            }
            if let value = LaunchOptions.value(for: "--epub-columns") { settings.reader.epubDoubleColumn = value == "2" }
            if let value = LaunchOptions.value(for: "--pdf-original") { settings.reader.pdfOriginalColors = value == "1" }
        }

        // --mock-ai：把服务商临时指向本机桩服务，走和设置页同一份内存配置。
        if let mock = LaunchOptions.mockAI {
            settings.suppressSave = true
            let provider = AIProviderConfig(
                name: "桩服务（自检）",
                baseURL: "http://\(mock.host):\(mock.port)/v1",
                models: ["mock-chat"],
                selectedModel: "mock-chat"
            )
            settings.settings.ai.providers = [provider]
            settings.settings.ai.activeProviderID = provider.id
        }
    }
}

// MARK: - 窗口管理器

/// 窗口的生灭与「文件该在哪个窗口打开」的唯一裁决者。
///
/// 默认策略（用户明确要求）：**一个窗口、多个标签页**。
/// - 欢迎页 / 菜单 / 访达打开文件 → 进当前窗口的新标签；
/// - 已经在某个窗口标签里打开的同一路径 → 直接切过去，不重复开；
/// - 标签右键「在独立窗口打开」→ 会话整体搬到新窗口。
///
/// 之所以不用 SwiftUI `WindowGroup`：它对外部文件打开事件的默认处理就是
/// 「每份文件开一个新窗口」，且没有公开 API 把事件改成「进标签」。
/// 窗口改成 AppKit 显式创建后，外部事件统一由 `application(_:open:)`
/// 送到这里路由，行为才完全可控。
@MainActor
final class WindowManager: ObservableObject {

    static let shared = WindowManager()

    let services: AppServices

    /// 当前所有窗口的工作区（与窗口一一对应）。
    @Published private(set) var workspaces: [AppState] = []
    /// 最前面的窗口对应的工作区，菜单栏读它决定动作落在谁身上。
    @Published private(set) var activeWorkspace: AppState?

    /// 给设置窗口兜底用的「无文档工作区」：设置页只用到共享服务，
    /// 但它的子视图声明了 `@EnvironmentObject AppState`，给一个不挂窗口的即可。
    private(set) lazy var utilityWorkspace: AppState = AppState(services: services)

    private var windowControllers: [LumenWindowController] = []

    private init() {
        services = AppServices()
    }

    // MARK: 启动

    /// 应用启动后创建第一个窗口（欢迎页或 `--open` 指定的文档）。
    ///
    /// 显式建窗替代 WindowGroup 的隐式建窗：以前从命令行直接启动二进制时
    /// SwiftUI 有概率不创建窗口（见 LaunchDiagnostics 的记录），现在窗口是同步创建的，
    /// 这条时序坑随之消失。
    func startup() {
        // 冷启动从访达 / Dock 打开文件时，odoc 事件可能在 didFinishLaunching
        // 之前就送达：那时 openExternally 已经建好窗口并载入了文档。
        // 这里若无条件再建一个，就会变成「文档窗口 + 空白欢迎窗口」两个窗口。
        guard workspaces.isEmpty else {
            NSLog("[Lumen][tabs] startup：已有外部事件建好的窗口 \(workspaces.count) 个，跳过建窗")
            workspaces.last?.window?.makeKeyAndOrderFront(nil)
            return
        }

        let workspace = makeWorkspace()
        createWindow(for: workspace)

        NSLog("[Lumen][tabs] startup：窗口已建，openPath = \(LaunchOptions.openPath ?? "nil")")
        if let path = LaunchOptions.openPath {
            // 自检不记「最近打开」（测试书会顶掉真实记录）；正常命令行打开照旧记录。
            workspace.open(
                url: URL(fileURLWithPath: path),
                recordInRecents: !LaunchOptions.isAuditRun
            )
            NSLog("[Lumen][tabs] startup 打开后会话数 = \(workspace.sessions.count)")
        }

        // 自检用：`--home-tab 1` 走一次「点 + 建主页标签」。
        // 判据不写「开关为 true」这种自证——看 `--layout-report` 里阅读区的探针
        // 还在不在：主页标签激活时正文应当是欢迎页，readerSurface / sidebar 都不该再上报。
        if LaunchOptions.homeTab {
            workspace.addHomeTab()
            NSLog("[Lumen][tabs] 自检：新建主页标签 → 会话数 = \(workspace.sessions.count)"
                  + " / 主页激活 = \(workspace.activeSession == nil)"
                  + " / 标签栏存在 = \(!workspace.sessions.isEmpty || workspace.homeTabIsActive)")
        }
    }

    /// 没有任何窗口时（点 Dock 图标 / AppleScript reopen）补一个。
    func ensureWindow() {
        if let last = workspaces.last {
            last.window?.makeKeyAndOrderFront(nil)
        } else {
            createWindow(for: makeWorkspace())
        }
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: 外部文件事件

    /// 处理「访达打开方式 / 将文件拖到 Dock 图标」送来的文件。
    /// 全部进当前窗口的新标签；一个窗口都没有就先开窗。
    func openExternally(urls: [URL]) {
        NSLog("[Lumen][tabs] 收到外部打开事件：\(urls.map(\.path))，当前窗口数 = \(workspaces.count)")
        let workspace = activeWorkspace ?? workspaces.last ?? {
            let workspace = makeWorkspace()
            createWindow(for: workspace)
            return workspace
        }()

        for url in urls {
            workspace.open(url: url)
        }

        workspace.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: 工作区 / 窗口的生灭

    @discardableResult
    func makeWorkspace(initial session: ReaderSession? = nil) -> AppState {
        let workspace = AppState(services: services)
        if let session {
            workspace.adopt(session)
        }
        return workspace
    }

    @discardableResult
    func createWindow(for workspace: AppState) -> LumenWindowController {
        let controller = LumenWindowController(workspace: workspace)
        windowControllers.append(controller)
        if !workspaces.contains(where: { $0 === workspace }) {
            workspaces.append(workspace)
        }

        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        if activeWorkspace == nil {
            activeWorkspace = workspace
        }
        return controller
    }

    /// 窗口成为主窗口。
    func activate(_ workspace: AppState) {
        if activeWorkspace !== workspace {
            activeWorkspace = workspace
        }
    }

    /// 窗口关闭：摘掉工作区；最后一个窗口关闭由 AppDelegate 决定是否退出。
    func remove(_ workspace: AppState) {
        workspace.teardown()
        workspaces.removeAll { $0 === workspace }
        windowControllers.removeAll { $0.workspace === workspace }
        if activeWorkspace === workspace {
            activeWorkspace = workspaces.last
        }
    }

    // MARK: 标签路由

    /// 这份文档是否已经在某个窗口里打开。返回所在工作区与会话，用于去重。
    func existingSession(for path: String) -> ReaderSession? {
        workspaces.lazy
            .flatMap { $0.sessions }
            .first { $0.document.url.standardizedFileURL.path == path }
    }

    /// 把已经打开着的会话连同它的窗口、标签一起带到最前。
    func focus(_ session: ReaderSession) {
        guard let workspace = workspaces.first(where: { state in
            state.sessions.contains { $0 === session }
        }) else { return }
        workspace.activate(session)
        workspace.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// 自检：把第一个窗口（detach 后的来源窗口）置前。
    func focusSourceWorkspaceForAudit() {
        guard let workspace = workspaces.first else { return }
        workspace.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// 自检入口：把最前面窗口的当前标签拆到独立窗口，返回是否执行。
    @discardableResult
    func detachActiveForAudit() -> Bool {
        guard let workspace = activeWorkspace, workspace.activeSession != nil else {
            NSLog("[Lumen][tabs] detach 自检：没有可拆的标签")
            return false
        }
        workspace.detach()
        NSLog("[Lumen][tabs] detach 自检：已拆出，当前窗口数 = \(workspaces.count)")
        return true
    }

    /// 把某个标签从原窗口搬到新的独立窗口。
    ///
    /// 会话整体迁移：对话、智能目录跟着走；PDFView / WKWebView 这类视图由
    /// SwiftUI 持有、无法跨窗口搬运，新窗口会重新解析文档，阅读位置由
    /// ReadingStateStore 落盘后自动恢复。
    func detach(_ session: ReaderSession, from workspace: AppState) {
        workspace.withdraw(session)

        let newWorkspace = makeWorkspace(initial: session)
        let controller = createWindow(for: newWorkspace)

        // 新窗口相对来源窗口错位排开，避免完全盖住原窗口。
        if let sourceFrame = workspace.window?.frame,
           let newWindow = controller.window {
            var frame = newWindow.frame
            frame.origin = NSPoint(
                x: sourceFrame.origin.x + 60,
                y: sourceFrame.origin.y - 60
            )
            newWindow.setFrame(frame, display: true, animate: false)
        }
    }
}

// MARK: - 窗口控制器

/// 一个阅读器窗口：NSWindow + 托管 RootView 的 NSHostingController。
@MainActor
final class LumenWindowController: NSWindowController, NSWindowDelegate {

    let workspace: AppState
    private var titleSync: AnyCancellable?

    init(workspace: AppState) {
        self.workspace = workspace

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1340, height: 860),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        // 去掉系统的 unified 工具栏：它两害——
        // 1) 会自动生成一个「Toggle Sidebar ⌘s」系统菜单项抢占我们的快捷键，产生冲突音；
        // 2) 白白占掉窗口顶部一行，让「工具栏 + 标签」叠成两行。
        // 改成标题栏透明 + 内容延伸到最顶，红黄绿交通灯悬浮在自定义标签栏同一行里（Obsidian 式）。
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.minSize = CGSize(width: 920, height: 620)
        // 我们自己做标签，关掉系统的窗口标签化，否则窗口菜单里会出现
        // 「显示标签栏 / ⌘T」等与自定义标签冲突的项。
        window.tabbingMode = .disallowed
        window.isRestorable = false

        super.init(window: window)
        window.delegate = self

        let root = RootView(state: workspace)
            .environmentObject(workspace)
            .environmentObject(workspace.services.settingsStore)
            .environmentObject(workspace.services.recent)
            .environmentObject(workspace.services.memory)
            .environmentObject(workspace.services.keyBindings)
        let hosting = NSHostingController(rootView: root)
        // 关键：让托管视图随窗口撑满。
        //
        // `NSHostingController.sizingOptions` 默认是 `.preferredContentSize`——它会把
        // SwiftUI 内容区收缩到视图的理想尺寸，而不是让视图填满窗口。这是「打开文档后
        // 上方一大片空白、三栏压到底部」这条布局错误的直接来源：阅读区高度只剩约一半，
        // 剩下的是露出来的窗口底色。清空后在窗口 resize 时托管视图按内容区撑满。
        hosting.sizingOptions = []
        window.contentViewController = hosting

        // 装上托管视图后，自动布局会按内容的最小宽高把窗口收窄到 minSize，
        // 所以默认尺寸必须在这之后再显式设一次（对齐旧 WindowGroup 的 defaultSize）。
        window.setContentSize(NSSize(width: 1340, height: 860))
        window.center()

        workspace.attach(window: window)

        // 窗口标题 / 代理图标跟随当前标签；标签全部关闭后复位。
        titleSync = workspace.$activeSession
            .sink { [weak self] session in
                guard let self, let window = self.window else { return }
                window.title = session?.document.displayTitle ?? "流明"
                window.representedURL = session?.document.url
            }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func windowDidBecomeKey(_ notification: Notification) {
        WindowManager.shared.activate(workspace)
    }

    func windowWillClose(_ notification: Notification) {
        titleSync?.cancel()
        WindowManager.shared.remove(workspace)
    }
}
