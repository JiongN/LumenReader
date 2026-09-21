import SwiftUI
import Combine
import LumenKit

/// 一个标签页 = 一份打开的文档 + 它专属的全部阅读状态。
///
/// 为什么会话要把 bridge / chat / smartOutline 一起装进来：
/// 这三样原本挂在全局 `AppState` 上，隐含假设「一个窗口最多一本书」。
/// 改成一个窗口多标签之后，A 书的 PDFView 不能把请求发到 B 书的 bridge，
/// A 书的对话也不能串到 B 书的气泡里——所以它们的作用域必须跟着文档走，
/// 一份文档一个会话，标签切换 = 换一个会话，标签移出独立窗口 = 会话整体搬走。
///
/// 视图层保持存活（标签切走不销毁），所以切回来时阅读位置、滚动状态、
/// 正在流式输出的回答都还在；真正的解析/渲染仍由各阅读视图自己持有。
@MainActor
final class ReaderSession: ObservableObject, Identifiable {

    let id: UUID
    let document: OpenDocument

    /// 阅读视图与外壳之间的唯一通道（PDF / EPUB 各自填闭包）。
    let bridge = ReaderBridge()
    /// 这份文档的 AI 智能目录。
    ///
    /// 注意：AI 对话不再挂在会话上——全局共享一份（见 `ConversationStore` /
    /// `AIChatModel`），由 `AppState.chat`（= `services.activeChat`）统一取用。
    /// 这里刻意不再持有 `chat`，避免「A 标签的请求落到 B 标签的气泡」这类串台，
    /// 也避免一份会话被多份会话各自持有、各自落盘。
    let smartOutline = SmartOutlineModel()

    /// 阅读区上报的文档元数据镜像，导出摘要时需要作者 / 篇幅。
    @Published var documentMetadata = DocumentMetadata()

    /// 由划词浮动条 / 命令面板投递、供这份文档的 AI 面板消费的请求。
    /// 必须按会话隔离：在 A 标签划词，请求不该被 B 标签的面板消费。
    @Published var pendingAIRequest: AIRequest?

    /// 长任务进度（全文抽取 / 逐页 OCR）。按会话记账，
    /// 标签切走后任务继续，标签上可以显示忙碌态。
    @Published var busy: BusyState?
    var busyCancel: (() -> Void)?
    var fullTextTask: Task<Void, Never>?

    /// 文档元数据（书名、页数）是异步加载的，转发它的变更，
    /// 标签标题 / 窗口标题才能在加载完成后刷新。
    private var documentObservation: AnyCancellable?

    init(document: OpenDocument, id: UUID = UUID()) {
        self.id = id
        self.document = document
        // 智能目录按文档路径存取，只在创建会话时绑定，重新挂载视图不清空草稿、不重读文件。
        smartOutline.bind(to: document, unitName: document.kind == .epub ? "章" : "页")

        documentObservation = document.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
    }

    /// Only close tears down work; moving a tab to another window preserves its session.
    ///
    /// 不在这里调用 `chat.stop()`：对话是全局共享的（见 `AppState.chat`），
    /// 关掉一个文档标签不该把正在进行的整篇回答中断掉。流式任务会随全局
    /// `AIChatModel` 的生命周期自然结束。
    func close() {
        busyCancel?()
        busyCancel = nil
        fullTextTask?.cancel()
        fullTextTask = nil
        smartOutline.cancelAllWork()
        bridge.closeReader?()
        bridge.reset()
        pendingAIRequest = nil
    }

    /// 标签上显示的标题（文档元数据加载完可能是书名，否则是文件名）。
    var title: String { document.displayTitle }
}
