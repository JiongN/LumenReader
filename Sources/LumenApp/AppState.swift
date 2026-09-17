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
    }

    func reopen(_ entry: RecentEntry) {
        open(url: entry.url)
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
