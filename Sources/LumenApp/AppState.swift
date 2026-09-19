import SwiftUI
import AppKit
import Combine
import LumenKit

/// 当前打开的文档。
///
/// 刻意做成薄壳：只持有 URL / 类型 / 加载状态，真正的解析器由各阅读视图自己创建，
/// 这样 PDF 与 EPUB 的加载失败互不影响，也不会把 PDFKit 的类型漏到 UI 层之外。
@MainActor
final class OpenDocument: ObservableObject, Identifiable {

    let url: URL
    let kind: DocumentKind
    nonisolated var id: String { url.standardizedFileURL.path }

    @Published var title: String
    @Published var isLoading: Bool = true
    @Published var loadError: String?
    /// 供工具栏显示的副标题（页数 / 章节数）
    @Published var detail: String = ""

    init(url: URL, kind: DocumentKind) {
        self.url = url
        self.kind = kind
        self.title = url.deletingPathExtension().lastPathComponent
    }

    var displayTitle: String {
        title.isEmpty ? url.lastPathComponent : title
    }
}

/// 一个窗口的工作区：标签集合 + 窗口级界面状态 + 动作。
///
/// 作用域划分（多标签改造后的关键边界）：
/// - **跟着标签走的**（每份文档一份）：`ReaderSession` 里的 bridge / chat /
///   smartOutline / 元数据 / AI 请求 / 忙碌状态；
/// - **跟着窗口走的**：标签集合、当前标签、两块面板的显隐、沉浸状态、
///   alert / toast、命令面板与跳页面板；
/// - **整个进程一份的**（`AppServices`）：设置、最近打开、快捷键、记忆。
///
/// 为了让菜单栏、命令面板、浮层这些「窗口级」代码少改动，文档级的东西
/// 在这里保留同名计算属性（`document` / `bridge` / `chat` …），
/// 它们一律解析到**当前标签**的会话。
@MainActor
final class AppState: ObservableObject {

    let services: AppServices

    // MARK: 标签（会话）

    /// 这个窗口里打开的全部标签，顺序即标签栏顺序。
    @Published var sessions: [ReaderSession] = [] {
        didSet { syncActiveSession() }
    }

    /// 当前标签 id。
    @Published var activeSessionID: UUID? {
        didSet { syncActiveSession() }
    }

    /// 「主页标签」是否处于激活状态。
    ///
    /// 为什么不是往 `sessions` 里塞一个空会话：`ReaderSession` 的整个生命周期都
    /// 建立在「有一份文档」之上（bridge / chat / 智能目录 / 元数据全是文档级的），
    /// 造一个没有文档的会话等于让一半代码路径去判空。主页本来就是「当前没有会话」
    /// 这一状态，只是它现在要能在**旁边还有别的标签**时也存在，所以单独立一个开关：
    /// 打开时 `activeSession` 解析为 nil（正文落到欢迎页），标签栏照常在。
    @Published var homeTabIsActive = false

    /// 当前标签。与 `activeSessionID` 保持同步（id 失效时回退第一个）。
    @Published private(set) var activeSession: ReaderSession?

    /// 已经挂载过阅读视图的标签：文档解析很重，切到才挂载；挂过就保活，
    /// 切回来不重新解析（阅读位置、滚动、流式回答都还在）。
    @Published private(set) var loadedSessionIDs: Set<UUID> = []

    /// 欢迎页（一个标签都没有）时给窗口级视图兜底的空通道，
    /// 保证 `@EnvironmentObject` 永远能解析到对象。
    let idleBridge = ReaderBridge()
    let idleChat = AIChatModel()
    let idleSmartOutline = SmartOutlineModel()

    /// 当前标签变化时，把它的对象变更转发成工作区的变更——
    /// 否则窗口级浮层（忙碌卡片等）只观察工作区，读计算属性时收不到刷新。
    private var activeSessionObservation: AnyCancellable?

    // MARK: 共享服务（便捷代理）

    var settingsStore: SettingsStore { services.settingsStore }
    var recent: RecentDocuments { services.recent }
    var keyBindings: KeyBindingStore { services.keyBindings }
    var memory: MemoryStore { services.memory }

    // MARK: 当前标签的文档级状态（代理）

    var document: OpenDocument? { activeSession?.document }
    var bridge: ReaderBridge { activeSession?.bridge ?? idleBridge }
    var chat: AIChatModel { activeSession?.chat ?? idleChat }
    var smartOutline: SmartOutlineModel { activeSession?.smartOutline ?? idleSmartOutline }

    var documentMetadata: DocumentMetadata {
        get { activeSession?.documentMetadata ?? DocumentMetadata() }
        set { activeSession?.documentMetadata = newValue }
    }

    var pendingAIRequest: AIRequest? {
        get { activeSession?.pendingAIRequest }
        set { activeSession?.pendingAIRequest = newValue }
    }

    var busy: BusyState? {
        get { activeSession?.busy }
        set { activeSession?.busy = newValue }
    }

    var busyCancel: (() -> Void)? {
        get { activeSession?.busyCancel }
        set { activeSession?.busyCancel = newValue }
    }

    var fullTextTask: Task<Void, Never>? {
        get { activeSession?.fullTextTask }
        set { activeSession?.fullTextTask = newValue }
    }

    // MARK: 窗口级界面状态

    /// 全局提示。
    ///
    /// 收成「一个值」而不是「标题 + 正文两个字段」的原因：现在有两种提示形态——
    /// 单按钮的告知、和一个确认按钮的询问（例如「这是扫描件，要先识别吗」）。
    /// 用两个字段表达不了「确认后要干什么」，而挂两个 `.alert` 修饰符在同一个窗口上
    /// 会互相抢展示权（后挂的赢），所以统一成一条通道。
    @Published var alert: AppAlert?

    /// 轻量提示条（复制成功这类）。会自动消失，不打断操作。
    @Published var toast: StatusToast?

    /// 命令面板
    @Published var isCommandPaletteVisible: Bool = false
    /// 「跳转到页码」输入条
    @Published var isPageJumpVisible: Bool = false

    /// AI 面板是否可见（窗口级：对当前窗口所有标签生效）
    @Published var isAIPanelVisible: Bool = true
    /// 侧栏是否可见
    @Published var isSidebarVisible: Bool = true

    /// 沉浸阅读模式：隐藏顶栏与两侧面板、正文居中收窄。不做系统全屏（用户要求
    /// 「不必全屏」，只是收起左侧工具栏和顶部标签栏）。
    @Published var isImmersive = false

    /// 进入沉浸之前两块面板的可见性，退出时原样恢复。
    private var sidebarBeforeImmersive = true
    private var aiPanelBeforeImmersive = true

    /// 本窗口。全屏是**窗口级**操作，必须有个明确的施力对象。
    private weak var mainWindow: NSWindow?

    private var toastTask: Task<Void, Never>?

    private var cancellables = Set<AnyCancellable>()

    // MARK: 初始化

    init(services provided: AppServices? = nil) {
        let services = provided ?? AppServices()
        self.services = services

        // 自检通道：把面板可见性钉在指定状态，用于核对「三栏全开」「只留阅读区」等布局。
        // 主题不走这里——`SettingsStore` 的 setter 会防抖落盘，从命令行改主题会污染
        // 用户的 settings.json。要验深色主题就直接改那个文件。
        if let sidebar = LaunchOptions.initialSidebarVisible { isSidebarVisible = sidebar }
        if let aiPanel = LaunchOptions.initialAIPanelVisible { isAIPanelVisible = aiPanel }

        // 自检用：直接进沉浸模式。走真实入口 setImmersive，不测手填三态。
        if LaunchOptions.startsImmersive {
            setImmersive(true)
        }

        // 动效门必须在首帧之前拿到配置，否则欢迎页的入场动画会先按默认值跑一遍
        MotionGate.observeSystemPreference()
        MotionGate.apply(self.services.settingsStore.settings.ui)
        UIFontGate.apply(self.services.settingsStore.settings.ui)

        // 设置页改完界面偏好，下一次取令牌就已经是新值——令牌都是计算属性，不需要额外通知
        self.services.settingsStore.$settings
            .map(\.ui)
            .removeDuplicates()
            .dropFirst()
            .sink { ui in
                MotionGate.apply(ui)
                UIFontGate.apply(ui)
            }
            .store(in: &cancellables)
    }

    // MARK: - 标签管理

    /// 新增标签并切过去。
    func add(_ session: ReaderSession) {
        homeTabIsActive = false
        sessions.append(session)
        activate(session)
    }

    /// 打开一个「主页」标签：正文回到欢迎页，已打开的文档标签原样保留在旁边。
    ///
    /// 没有已打开文档时不动作——那已经是主页了，再挂一个空标签只是多一枚点不掉的按钮。
    func addHomeTab() {
        guard !sessions.isEmpty else { return }
        homeTabIsActive = true
        syncActiveSession()
    }

    /// 关掉主页标签：回到最后一个文档标签（没有就回到纯欢迎页）。
    func closeHomeTab() {
        guard homeTabIsActive else { return }
        homeTabIsActive = false
        if let last = sessions.last {
            activate(last)
        } else {
            syncActiveSession()
        }
    }

    /// 外部（独立窗口）直接放入一个已存在的会话。
    func adopt(_ session: ReaderSession) {
        homeTabIsActive = false
        sessions = sessions + [session]
        loadedSessionIDs.insert(session.id)
        activeSessionID = session.id
    }

    /// 切到指定标签（懒挂载在这里发生）。
    func activate(_ session: ReaderSession) {
        loadedSessionIDs.insert(session.id)
        if activeSessionID != session.id {
            activeSessionID = session.id
        } else {
            syncActiveSession()
        }
    }

    func activateTab(id: UUID) {
        guard let session = sessions.first(where: { $0.id == id }) else { return }
        activate(session)
    }

    /// 关闭标签。最后一个关掉后回到欢迎页。
    func close(_ session: ReaderSession) {
        // 先记住邻接标签：关的是当前标签时，激活右侧（没有则左侧）那一个，
        // 而不是粗暴地回到第一个标签。
        if let index = sessions.firstIndex(where: { $0 === session }) {
            let wasActive = activeSessionID == session.id
            sessions.remove(at: index)
            session.busyCancel?()
            // 最后一个文档标签也关掉时顺手收掉主页标签：没有文档标签却留着一枚
            // 「主页」芯片，标签栏上就只剩一个点不掉也没处可去的按钮。
            if sessions.isEmpty { homeTabIsActive = false }
            if wasActive {
                let neighbor = min(index, sessions.count - 1)
                if sessions.indices.contains(neighbor) {
                    activeSessionID = sessions[neighbor].id
                }
            }
        }
    }

    /// 关闭当前标签（菜单 ⌘W / 标签上的 ×）。
    func closeActiveTab() {
        if let activeSession { close(activeSession) }
    }

    func closeOthers(keeping kept: ReaderSession) {
        for session in sessions where session !== kept {
            session.busyCancel?()
        }
        sessions.removeAll { $0 !== kept }
        activate(kept)
    }

    /// 循环切换标签（⌘⇧[ / ⌘⇧]）。
    func cycleTab(forward: Bool) {
        guard sessions.count > 1, let current = activeSession,
              let index = sessions.firstIndex(where: { $0 === current }) else { return }
        let count = sessions.count
        let next = forward ? (index + 1) % count : (index - 1 + count) % count
        activate(sessions[next])
    }

    /// 把当前标签（或指定标签）移到独立窗口。
    func detach(_ session: ReaderSession? = nil) {
        guard let session = session ?? activeSession else { return }
        WindowManager.shared.detach(session, from: self)
    }

    /// 独立窗口接管会话时，把它从本窗口摘走（由 WindowManager 调用）。
    func withdraw(_ session: ReaderSession) {
        if let index = sessions.firstIndex(where: { $0 === session }) {
            let wasActive = activeSessionID == session.id
            sessions.remove(at: index)
            session.busyCancel?()
            if wasActive {
                let neighbor = min(index, sessions.count - 1)
                if sessions.indices.contains(neighbor) {
                    activeSessionID = sessions[neighbor].id
                }
            }
        }
    }

    /// 保持 `activeSession` 与 id / 列表一致，并切换会话观察。
    private func syncActiveSession() {
        let target = homeTabIsActive
            ? nil
            : (sessions.first { $0.id == activeSessionID } ?? sessions.first)

        // 当前标签被关闭 / 拆走后，id 会指向一个已不存在的会话。
        // 必须先把 id 校正到邻接标签（赋值会重新进入本方法），
        // 否则视图层的 opacity 判断（session.id == activeSessionID）
        // 会让剩下的标签永远停在透明态——界面只剩标签栏、正文一片空白。
        if target?.id != activeSessionID {
            activeSessionID = target?.id
            return
        }

        guard target?.id != activeSession?.id else {
            if target == nil { activeSession = nil }
            return
        }
        activeSession = target
        if let target {
            loadedSessionIDs.insert(target.id)
            // 转发当前会话的变更，窗口级浮层才能跟着 busy / 请求状态刷新。
            activeSessionObservation = target.objectWillChange.sink { [weak self] _ in
                self?.objectWillChange.send()
            }
        } else {
            activeSessionObservation = nil
        }
    }

    // MARK: - 打开与关闭

    func open(url: URL, recordInRecents: Bool = true) {
        let normalized = url.standardizedFileURL

        guard FileManager.default.fileExists(atPath: normalized.path) else {
            NSLog("[Lumen][tabs] open 失败：文件不存在 \(normalized.path)")
            presentAlert(title: "文件不存在", message: "找不到 \(normalized.path)\n\n它可能已被移动或删除。")
            return
        }

        guard let kind = DocumentKind.from(url: normalized) else {
            presentAlert(
                title: "不支持的文件格式",
                message: "「\(normalized.lastPathComponent)」不是 PDF 或 EPUB 文件。\n\n目前支持的扩展名：\(DocumentKind.supportedExtensions.sorted().joined(separator: "、"))"
            )
            return
        }

        if recordInRecents {
            recent.record(url: normalized, kind: kind)
        }

        // 已经在某个窗口的标签里打开着：切过去，不重复开第二份。
        if let existing = WindowManager.shared.existingSession(for: normalized.path) {
            WindowManager.shared.focus(existing)
            return
        }

        let document = OpenDocument(url: normalized, kind: kind)
        add(ReaderSession(document: document))
        NSLog("[Lumen][tabs] open 已加标签：\(normalized.lastPathComponent)，当前会话数 = \(sessions.count)")
    }

    /// 菜单「关闭文档」的新语义：关闭当前标签。
    func closeDocument() {
        closeActiveTab()
    }

    /// 跳到第 `index` 个单元（0-based；PDF 是页、EPUB 是章）。
    @discardableResult
    func jump(toUnit index: Int) -> Int? {
        let total = bridge.unitCount
        guard total > 0 else { return nil }

        // 越界钳到边界：用户输 9999 的意图是「跳到末尾」，报错再让他重输是把一件事拆成两件
        let clamped = min(max(index, 0), total - 1)
        let locator: DocumentLocator = document?.kind == .epub
            ? .epub(chapterIndex: clamped, anchor: "", charOffset: 0)
            : .pdf(page: clamped, charOffset: 0)

        bridge.goTo?(locator)
        return clamped
    }

    func reopen(_ entry: RecentEntry) {
        open(url: entry.url)
    }

    // MARK: 智能目录

    /// 目录条目叫「第几页」还是「第几章」，由桥上报的文档类型决定。
    var unitName: String {
        document?.kind == .epub ? "章" : "页"
    }

    /// 触发一次智能目录生成（有缓存也重新生成一份新的）。
    func generateSmartOutline() {
        guard document != nil else { return }
        revealSidebar(tab: .smartOutline)
        smartOutline.generate(
            bridge: bridge,
            metadata: bridge.metadata,
            config: settingsStore.activeProvider
        )
    }

    // MARK: - 窗口

    /// 窗口创建后把自己登记进来（全屏操作的施力对象）。
    func attach(window: NSWindow) {
        adoptMainWindow(window)
    }

    /// 窗口关闭时的清理。
    func teardown() {
        activeSessionObservation?.cancel()
        activeSessionObservation = nil
        for session in sessions {
            session.busyCancel?()
        }
    }

    // MARK: - 沉浸模式

    /// 进入 / 退出沉浸模式（含系统全屏）。
    func setImmersive(_ on: Bool) {
        setIsImmersive(on, animated: true)
    }

    /// 由 `WindowStateProbe` 在视图挂上窗口时调用。
    func adoptMainWindow(_ window: NSWindow) {
        window.collectionBehavior.insert(.moveToActiveSpace)
        guard mainWindow !== window else { return }
        mainWindow = window
        for button in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            window.standardWindowButton(button)?.isHidden = isImmersive
        }
    }

    /// 系统全屏状态变化（来自窗口的进出全屏通知）。只处理「退出全屏」方向。
    func systemFullScreenChanged(_ isFullScreen: Bool) {
        NSLog("[Lumen][immersive] 收到全屏通知 isFullScreen=\(isFullScreen)"
            + " 当前 isImmersive=\(isImmersive)")
        guard isImmersive, !isFullScreen else { return }
        setIsImmersive(false, animated: false)
        NSLog("[Lumen][immersive] 已随退出全屏复位：isImmersive=\(isImmersive)"
            + " 侧栏=\(isSidebarVisible) AI面板=\(isAIPanelVisible)")
    }

    /// 自检：模拟「用户从系统那一侧退出全屏」。
    func simulateSystemExitFullScreen() {
        guard let window = resolvedWindow(), window.styleMask.contains(.fullScreen) else {
            NSLog("[Lumen][immersive] 模拟退出全屏失败：窗口当前不在全屏")
            return
        }
        NSLog("[Lumen][immersive] 模拟系统方式退出全屏（未触碰 isImmersive，当前=\(isImmersive)）")
        window.toggleFullScreen(nil)
    }

    private func setIsImmersive(_ on: Bool, animated: Bool) {
        guard isImmersive != on else { return }

        if on {
            sidebarBeforeImmersive = isSidebarVisible
            aiPanelBeforeImmersive = isAIPanelVisible
        }

        let apply = {
            self.isImmersive = on
            if let window = self.mainWindow {
                for button in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
                    window.standardWindowButton(button)?.isHidden = on
                }
                window.toolbar?.isVisible = false
            }
            self.isSidebarVisible = on ? false : self.sidebarBeforeImmersive
            self.isAIPanelVisible = on ? false : self.aiPanelBeforeImmersive
        }
        if animated {
            withAnimation(DS.Motion.panel) { apply() }
        } else {
            apply()
        }
        // 沉浸（zoom）模式不再进系统全屏：用户要求「不必全屏，只收起左侧工具栏和
        // 顶部标签栏」。隐藏顶栏/侧栏由 RootView 与 ReaderContainerView 按 isImmersive 处理。
    }

    private func driveFullScreen(_ on: Bool, animated: Bool) {
        guard let window = resolvedWindow() else { return }
        guard window.styleMask.contains(.fullScreen) != on else { return }

        guard on, animated else {
            window.toggleFullScreen(nil)
            return
        }

        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 340_000_000)
            guard let self, self.isImmersive,
                  let fresh = self.resolvedWindow(),
                  !fresh.styleMask.contains(.fullScreen) else { return }
            fresh.toggleFullScreen(nil)
        }
    }

    private func resolvedWindow() -> NSWindow? {
        if let mainWindow, mainWindow.isVisible { return mainWindow }
        return NSApp.windows
            .filter { $0.isVisible && ($0.contentView?.bounds.height ?? 0) > 100 }
            .max { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height }
    }

    // MARK: - 提示

    func presentAlert(title: String, message: String) {
        alert = AppAlert(title: title, message: message)
    }

    /// 要求用户先确认再执行。`action` 只在点确认按钮时跑。
    func presentConfirmation(
        title: String,
        message: String,
        confirmTitle: String,
        isDestructive: Bool = false,
        action: @escaping () -> Void
    ) {
        // 自检通道：`--auto-confirm 1` 时直接执行，不弹框。
        if LaunchOptions.autoConfirms {
            NSLog("[Lumen][action] 自检自动确认：\(title)")
            action()
            return
        }

        alert = AppAlert(
            title: title,
            message: message,
            kind: .confirm(confirmTitle: confirmTitle, isDestructive: isDestructive),
            action: action
        )
    }

    // MARK: - 轻提示

    func showToast(_ message: String, isError: Bool = false) {
        toast = StatusToast(message: message, isError: isError)
        toastTask?.cancel()
        toastTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 2_600_000_000)
            guard !Task.isCancelled else { return }
            withAnimation(DS.Motion.content) { self?.toast = nil }
        }
    }

    func dismissToast() {
        toastTask?.cancel()
        withAnimation(DS.Motion.content) { toast = nil }
    }

    // MARK: - 打开面板

    /// 打开文件面板。允许一次选多个：每个文件都进当前窗口的一个新标签。
    func showOpenPanel() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowedContentTypes = DocumentKind.allowedContentTypes
        panel.prompt = "打开"
        panel.message = "选择一个或多个 PDF / EPUB 文件"

        guard panel.runModal() == .OK else { return }
        for url in panel.urls {
            open(url: url)
        }
    }

    // MARK: - 便捷访问

    var settings: AppSettings {
        get { services.settingsStore.settings }
        set { services.settingsStore.settings = newValue }
    }

    /// 本窗口（用于 WindowManager 排序、错位排开等）。
    var window: NSWindow? { mainWindow }

    // MARK: - 记忆

    /// 交给模型的记忆背景 = 长期偏好（自由文本）+ 结构化记忆条目。
    var aiMemoryPayload: String {
        var parts: [String] = []

        let persona = settingsStore.ai.persistentMemory
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !persona.isEmpty {
            parts.append(persona)
        }

        let memos = memory.promptFragment()
        if !memos.isEmpty {
            parts.append("""
            以下是此前记下的背景笔记（可能与当前这本书无关，只作参考，不要当作用户这次的问题）：
            \(memos)
            """)
        }

        return parts.joined(separator: "\n\n")
    }

    /// 记入跨会话记忆。返回 false 表示内容为空或已存在。
    @discardableResult
    func remember(text: String, source: String, locatorLabel: String = "") -> Bool {
        memory.add(text: text, source: source, locatorLabel: locatorLabel) != nil
    }

    /// 当前文档的展示名，用作记忆来源
    var currentDocumentTitle: String {
        document?.displayTitle ?? "未打开文档"
    }
}
