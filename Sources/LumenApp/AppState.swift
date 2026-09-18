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

@MainActor
final class AppState: ObservableObject {

    let settingsStore: SettingsStore
    let recent: RecentDocuments
    /// 快捷键绑定。放全局是因为菜单栏、命令面板、设置页三处都要读，
    /// 而菜单栏不是 `RootView` 的子视图，拿不到环境注入。
    let keyBindings = KeyBindingStore()
    /// 跨会话记忆。放全局是因为它的寿命不绑定任何一本书——
    /// 在 A 书里记下「我在做扎根理论研究」，换到 B 书提问时同样应该带着。
    let memory = MemoryStore()
    /// AI 对话。放在全局是为了让菜单栏、命令面板也能驱动它（导出摘要、清空对话），
    /// 否则这些动作只能藏在 AI 面板右上角那个 ⋯ 里。
    let chat = AIChatModel()
    /// AI 智能目录。同样放全局：菜单命令与命令面板都要能触发它，
    /// 而它们都不是侧栏的子视图，拿不到环境注入。
    let smartOutline = SmartOutlineModel()
    /// 阅读视图与外壳之间的通道。同样提到全局：命令面板在欢迎页（没有阅读视图）时
    /// 也要能列出命令，它需要一个始终存在的通道对象，而不是随阅读视图生灭的那个。
    let bridge = ReaderBridge()

    @Published var document: OpenDocument?

    /// 全局提示。
    ///
    /// 收成「一个值」而不是「标题 + 正文两个字段」的原因：现在有两种提示形态——
    /// 单按钮的告知、和一个确认按钮的询问（例如「这是扫描件，要先识别吗」）。
    /// 用两个字段表达不了「确认后要干什么」，而挂两个 `.alert` 修饰符在同一个窗口上
    /// 会互相抢展示权（后挂的赢），所以统一成一条通道。
    @Published var alert: AppAlert?

    /// 轻量提示条（复制成功这类）。会自动消失，不打断操作。
    @Published var toast: StatusToast?

    /// 长任务进度（提取全文 / 逐页 OCR）。有值时外壳会显示一个可取消的进度卡片。
    @Published var busy: BusyState?
    /// 取消当前长任务
    var busyCancel: (() -> Void)?

    private var toastTask: Task<Void, Never>?
    /// 正在跑的全文抽取任务。非 nil 即表示「正在抽取」，同时兼任取消句柄。
    var fullTextTask: Task<Void, Never>?

    /// AI 面板是否可见
    @Published var isAIPanelVisible: Bool = true
    /// 侧栏是否可见
    @Published var isSidebarVisible: Bool = true
    /// 命令面板
    @Published var isCommandPaletteVisible: Bool = false
    /// 「跳转到页码」输入条
    @Published var isPageJumpVisible: Bool = false

    /// 沉浸阅读模式：隐藏所有面板与工具栏、正文居中收窄、窗口进入系统全屏。
    @Published var isImmersive = false

    /// 进入沉浸之前两块面板的可见性，退出时原样恢复。
    ///
    /// 记下来是必须的：如果只是「进入时全关、退出时全开」，
    /// 那么进来之前本来就关着 AI 面板的用户，一进一出就被打开了，
    /// 而他从没要求过——这种"帮你恢复到你没设过的状态"最容易招人烦。
    private var sidebarBeforeImmersive = true
    private var aiPanelBeforeImmersive = true

    /// 承载阅读界面的主窗口。全屏是**窗口级**操作，必须有个明确的施力对象——
    /// 用 `keyWindow` 会在「刚在设置窗口里点过一下」时把设置窗口全屏掉，
    /// 而阅读窗口纹丝不动。由 `WindowStateProbe` 在视图挂上窗口时报进来。
    private weak var mainWindow: NSWindow?

    /// 阅读区上报的文档元数据镜像。
    /// 菜单栏与命令面板拿不到 `ReaderBridge`，但「导出摘要」这类动作需要作者/篇幅，
    /// 与其让每个调用方各取一次，不如在桥外留一份。
    @Published var documentMetadata = DocumentMetadata()

    /// 由划词浮动条投递、供 AI 面板消费的请求。
    /// 用「投递 + 消费后清空」而不是直接调用 AI 面板的方法，是为了让阅读区和 AI 面板
    /// 之间不需要互相持有引用。
    @Published var pendingAIRequest: AIRequest?

    init(settingsStore: SettingsStore? = nil, recent: RecentDocuments? = nil) {
        self.settingsStore = settingsStore ?? SettingsStore()
        self.recent = recent ?? RecentDocuments()

        // 自检通道：把面板可见性钉在指定状态，用于核对「三栏全开」「只留阅读区」等布局。
        // 主题不走这里——`SettingsStore` 的 setter 会防抖落盘，从命令行改主题会污染
        // 用户的 settings.json。要验深色主题就直接改那个文件。
        if let sidebar = LaunchOptions.initialSidebarVisible { isSidebarVisible = sidebar }
        if let aiPanel = LaunchOptions.initialAIPanelVisible { isAIPanelVisible = aiPanel }

        // 自检用：把 AI 面板宽度直接写成指定值。走的是和拖动分隔线**同一个设置项**，
        // 所以「改宽度 → 布局跟随 → 越界被钳制」这条链路是真的被验到了，
        // 而不是在测一个只为自检而存在的旁路。
        //
        // 本批语义变更：侧栏宽度固定（248pt），不再从设置读，所以 `--panel-width`
        // 只设 AI 面板。为了不破坏既有的 `--panel-width 400x300` 写法，第一个数
        // （侧栏）仍被解析但**不生效**，第二个数才是 AI 面板宽度。
        if let panel = LaunchOptions.panelWidth {
            // 先关掉落盘：这是自检在改宽度，不能把用户的真实配置覆盖成测试值。
            // 注意用 self.：init 的参数也叫 settingsStore（可选类型），不加 self. 会指到参数上。
            self.settingsStore.suppressSave = true
            self.settingsStore.commitAIPanelWidth(panel.ai)
            NSLog("[Lumen] 自检：--panel-width 只设 AI 面板 = \(Int(panel.ai))pt"
                  + "（侧栏分量 \(Int(panel.sidebar))pt 已废弃，侧栏固定 \(Int(UISettings.PanelWidth.sidebarDefault))pt）")
        }

        // 自检用：性能自检会连翻若干页、反复进出缩略图，阅读位置会高频变动。
        // 关掉落盘，保证无论这条链路以后会不会碰设置，都不会覆盖用户的真实配置。
        if LaunchOptions.perfReport {
            self.settingsStore.suppressSave = true
        }

        // 自检用：卡顿自检会驱动真实的滚动/拖动，阅读位置与面板宽度都会高频变动。
        // 同样是「只改内存、不落盘」，保证跑完不覆盖用户的真实配置。
        // watch 模式（--jank-watch）是用户正常交互（含拖动分隔线会在松手时提交宽度），
        // 也一并关掉落盘。
        if LaunchOptions.jankReport || LaunchOptions.jankWatch {
            self.settingsStore.suppressSave = true
        }

        // 自检用：把 AI 服务商临时指向本机的桩服务。走的是和设置页**同一份**内存配置
        // （providers + activeProviderID），所以「智能目录真的能拿到配置并发出请求」
        // 这条链路是被完整验到的，而不是在测一个只为自检存在的旁路。
        // 127.0.0.1 会被 `isLocalEndpoint` 判为本地端点，因此不需要 API 密钥。
        if let mock = LaunchOptions.mockAI {
            self.settingsStore.suppressSave = true
            let provider = AIProviderConfig(
                name: "桩服务（自检）",
                baseURL: "http://\(mock.host):\(mock.port)/v1",
                models: ["mock-chat"],
                selectedModel: "mock-chat"
            )
            self.settingsStore.settings.ai.providers = [provider]
            self.settingsStore.settings.ai.activeProviderID = provider.id
        }

        // 自检用：直接进沉浸模式。走的是真实入口 `setImmersive`，
        // 而不是手工把三个状态各设一遍——后者测不出「退出时能否恢复原面板可见性」。
        if LaunchOptions.startsImmersive {
            setImmersive(true)
        }

        // 动效门必须在首帧之前拿到配置，否则欢迎页的入场动画会先按默认值跑一遍
        MotionGate.observeSystemPreference()
        MotionGate.apply(self.settingsStore.settings.ui)
        UIFontGate.apply(self.settingsStore.settings.ui)

        // 设置页改完界面偏好，下一次取令牌就已经是新值——令牌都是计算属性，不需要额外通知
        self.settingsStore.$settings
            .map(\.ui)
            .removeDuplicates()
            .dropFirst()
            .sink { ui in
                MotionGate.apply(ui)
                UIFontGate.apply(ui)
            }
            .store(in: &cancellables)
    }

    private var cancellables = Set<AnyCancellable>()

    // MARK: - 打开与关闭

    func open(url: URL, recordInRecents: Bool = true) {
        let normalized = url.standardizedFileURL

        guard FileManager.default.fileExists(atPath: normalized.path) else {
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
        document = OpenDocument(url: normalized, kind: kind)
    }

    func closeDocument() {
        document = nil
        documentMetadata = DocumentMetadata()
        chat.bind(to: nil)
        smartOutline.bind(to: nil)
    }

    /// 跳到第 `index` 个单元（0-based；PDF 是页、EPUB 是章）。
    ///
    /// 抽成一个方法而不是写在输入框的提交回调里：跳页有两个入口（点击页码、⌘G 面板），
    /// 而且它是**无 UI 也能验证**的一段逻辑——自检通道要靠它把「输入 7 是不是真的到了第 7 页」
    /// 变成一条可断言的日志。逻辑留在 View 里就只能靠手点。
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

    // MARK: - 智能目录

    /// 目录条目叫「第几页」还是「第几章」，由桥上报的文档类型决定。
    var unitName: String {
        document?.kind == .epub ? "章" : "页"
    }

    /// 触发一次智能目录生成（有缓存也重新生成一份新的）。
    ///
    /// 收成一个方法而不是让菜单栏、命令面板、侧栏按钮各写一遍：
    /// 三处都要先「把侧栏露出来并切到智能目录页签」，否则用户点了菜单里那一项
    /// 会看不到任何反应——生成要跑好几秒，而结果落在一个收起来的侧栏里。
    func generateSmartOutline() {
        guard document != nil else { return }
        revealSidebar(tab: .smartOutline)
        smartOutline.generate(
            bridge: bridge,
            metadata: bridge.metadata,
            config: settingsStore.activeProvider
        )
    }

    // MARK: - 沉浸模式

    /// 进入 / 退出沉浸模式（含系统全屏）。
    func setImmersive(_ on: Bool) {
        setIsImmersive(on, animated: true)
    }

    /// 由 `WindowStateProbe` 在视图挂上窗口时调用。
    ///
    /// 两件事都在拿到窗口的这一刻做掉：
    /// 1. 把窗口记下来，供全屏操作施力。
    /// 2. 让它出现在**用户当前所在的空间**。用户开了多个桌面时，不做这一步，
    ///    从命令行或程序化启动的窗口会落在别的桌面，用户会觉得「点了没反应」。
    func adoptMainWindow(_ window: NSWindow) {
        window.collectionBehavior.insert(.moveToActiveSpace)
        guard mainWindow !== window else { return }
        mainWindow = window

        // 补一次全屏。启动路径上 `setImmersive(true)`（`--immersive 1`）跑在窗口创建之前，
        // 那时没有窗口可施力，全屏这一步会被静默丢掉——剩下半套状态的沉浸最难排查。
        // 真实用户点按钮时窗口早已存在，走不到这里。
        if isImmersive, !window.styleMask.contains(.fullScreen) {
            window.toggleFullScreen(nil)
        }
    }

    /// 系统全屏状态变化（来自窗口的进出全屏通知）。
    ///
    /// **只处理「退出全屏」这一个方向，是刻意的。**
    ///
    /// 退出全屏必须把沉浸一起收掉：全屏可以脱离沉浸单独存在（用户直接按系统
    /// ⌃⌘F 或绿灯进入全屏，此时面板、工具栏都该留着），但反过来不行——
    /// 沉浸态下工具栏被 `.hidden` 锁住、两侧面板收着、正文限宽，
    /// 如果用户用系统方式退出全屏而这里不响应，这些状态就永远回不来了。
    /// 此前没有任何地方监听全屏通知，所以「退出 zoom 后回不到正常页面」必然发生。
    func systemFullScreenChanged(_ isFullScreen: Bool) {
        NSLog("[Lumen][immersive] 收到全屏通知 isFullScreen=\(isFullScreen)"
            + " 当前 isImmersive=\(isImmersive)")
        guard isImmersive, !isFullScreen else { return }
        // 不走动画：退出全屏的动画由系统负责，这里再叠一层 SwiftUI 动画
        // 会让面板展开与跨 Space 动画互相抢帧。
        setIsImmersive(false, animated: false)
        NSLog("[Lumen][immersive] 已随退出全屏复位：isImmersive=\(isImmersive)"
            + " 侧栏=\(isSidebarVisible) AI面板=\(isAIPanelVisible)")
    }

    /// 自检：模拟「用户从系统那一侧退出全屏」。
    ///
    /// 刻意**不**调用 `setImmersive(false)`——那正是被测的那条捷径，
    /// 走它当然能对；走它也就等于什么都没验到。这里只 toggle 窗口，
    /// 剩下的全交给通知链路，以此证明回程确实存在。
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
            self.isSidebarVisible = on ? false : self.sidebarBeforeImmersive
            self.isAIPanelVisible = on ? false : self.aiPanelBeforeImmersive
        }
        if animated {
            withAnimation(DS.Motion.panel) { apply() }
        } else {
            apply()
        }

        driveFullScreen(on, animated: animated)
    }

    /// 把窗口的全屏状态推向目标值。
    ///
    /// **进入时延后、退出时不延后**，不是随手选的：
    /// 进入沉浸要同时做两件事——收起面板（`DS.Motion.panel` 弹簧，response 0.34s）
    /// 与进入全屏（系统跨 Space 动画，约 0.5s）。两者同帧启动会互相抢帧，
    /// 布局在跨空间动画期间被反复重算，看到的正是「动作效果异常」。
    /// 把全屏推到布局动画之后，两段动画就串成了一条。
    /// 退出则不延后：退出全屏是回到原空间，越早启动越跟手，而且面板是在
    /// 空间切回之后才被看到的，观感上依然是「先退出全屏，再看到面板展开」。
    private func driveFullScreen(_ on: Bool, animated: Bool) {
        guard let window = resolvedWindow() else { return }
        // 状态一致就不要重复 toggle：连按两次会让窗口在全屏与不全屏之间来回横跳
        guard window.styleMask.contains(.fullScreen) != on else { return }

        guard on, animated else {
            window.toggleFullScreen(nil)
            return
        }

        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 340_000_000)
            // 这 0.34s 里用户可能已经改主意（又按了一次），所以重新取状态与窗口，
            // 而不是沿用启动那一刻的捕获值。
            guard let self, self.isImmersive,
                  let fresh = self.resolvedWindow(),
                  !fresh.styleMask.contains(.fullScreen) else { return }
            fresh.toggleFullScreen(nil)
        }
    }

    /// 全屏要作用在哪个窗口上。
    ///
    /// 优先用探针记下的主窗口；拿不到时退回「最大的可见窗口」，
    /// 避免子窗口 / 面板抢到全屏。
    private func resolvedWindow() -> NSWindow? {
        if let mainWindow, mainWindow.isVisible { return mainWindow }
        return NSApp.windows
            .filter { $0.isVisible && ($0.contentView?.bounds.height ?? 0) > 100 }
            .max { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height }
    }

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
        // 扫描件复制全文会走到这里，没有这个开关就只能验证到「弹了框」为止，
        // OCR 那半条链路永远验不到。
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

    func showOpenPanel() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowedContentTypes = DocumentKind.allowedContentTypes
        panel.prompt = "打开"
        panel.message = "选择一个 PDF 或 EPUB 文件"

        guard panel.runModal() == .OK, let url = panel.url else { return }
        open(url: url)
    }

    // MARK: - 便捷访问

    var settings: AppSettings {
        get { settingsStore.settings }
        set { settingsStore.settings = newValue }
    }

    // MARK: - 记忆

    /// 交给模型的记忆背景 = 长期偏好（自由文本）+ 结构化记忆条目。
    ///
    /// 两者分开渲染是为了让模型分得清层次：偏好是"该怎么回答"，
    /// 条目是"关于用户/这本书的已知事实"。
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
