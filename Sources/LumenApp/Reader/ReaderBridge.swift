import SwiftUI
import AppKit
import LumenKit

/// 阅读视图 ⇄ 外壳（工具栏 / 侧栏 / AI 面板）之间的唯一通道。
///
/// 两个方向各走一半：视图把状态（当前页、选区、进度、目录）发布上来，
/// 外壳把命令（跳转、翻页、查找）注册下去。这样 PDF 与 EPUB 两条实现
/// 只需要各自实现同一组接口，外壳完全不需要知道底下是什么。
@MainActor
final class ReaderBridge: ObservableObject {

    // MARK: 状态（视图 → 外壳）

    /// 当前选区，AI 功能的输入
    @Published var selection: ReaderSelection?
    /// 当前选区是不是「**拖动划选**」得来的。
    ///
    /// 存在的理由：在正文里**单击**也会产生一个 1 字符的选区（PDFKit / WebKit 都如此），
    /// 于是用户随手点一下，划词浮动条就弹出来——挡住正文、又没法一眼关掉。
    /// 用户要的是「拖动划选才弹」。所以选区额外带一个来源标记：
    /// PDF 侧按鼠标按下点与松开点的距离判定（< 4pt 算单击），
    /// EPUB 侧在注入的 JS 里判同一个距离。划词条只在 `isUsable && selectionFromDrag` 时出现。
    ///
    /// 默认 false：任何没显式标注来源的选区（含程序注入的）都当作单击处理，宁可少弹。
    @Published var selectionFromDrag: Bool = false
    /// 位置标签，例如「第 12 / 340 页」
    @Published var positionLabel: String = ""
    /// 0…1 进度
    @Published var progress: Double = 0
    /// 目录树
    @Published var outline: [OutlineNode] = []
    /// 检索结果
    @Published var searchResults: [SearchHit] = []
    @Published var searchQuery: String = ""
    @Published var isSearching: Bool = false
    /// 加载状态
    @Published var isLoading: Bool = true
    @Published var loadError: String?
    /// 当前所在目录项（用于侧栏高亮）
    @Published var activeOutlineID: UUID?

    /// 当前位置与总单元数（PDF 为页，EPUB 为章）
    @Published var currentUnitIndex: Int = 0
    @Published var unitCount: Int = 0
    /// 文档元数据，供 AI 构造上下文
    @Published var metadata: DocumentMetadata = DocumentMetadata()

    /// 侧栏当前页签
    @Published var sidebarTab: SidebarTab = .outline

    /// 批注变更计数。侧栏批注页签按它刷新——
    /// 批注存在两种后端里（PDF 写文件、EPUB 存数据目录），没有统一的「已变更」事件，
    /// 用一个自增计数把两条路径汇合成同一种刷新信号。
    @Published var annotationRevision: Int = 0

    /// 当前被「聚焦」的批注（正文里点中的、或刚新建的）。
    /// 侧栏批注页签据此滚动到对应行并高亮——双向联动的侧栏一侧。
    @Published var focusedAnnotationID: String?

    /// 当前文档是否为「没有文本层」的扫描件。为真时阅读区会给 OCR 入口。
    @Published var isScannedDocument: Bool = false
    /// 正在识别的页号（nil 表示空闲），供状态条显示进度
    @Published var ocrRunningPage: Int?

    // MARK: 命令（外壳 → 视图）

    /// 缩略图提供者（PDF 专用）
    let viewport = PDFViewportState()
    var setPanelResizing: ((Bool) -> Void)?
    var thumbnailProvider: ((Int, CGSize) -> NSImage?)?
    /// 卡顿自检（`--jank-report`）用：真正被滚动的那个视图（PDF 侧是 `PDFView`）。
    ///
    /// 取 `NSView` 而不是 `PDFView`：桥不做 PDFKit 的决策，由自检自己转型。
    /// 它存在的唯一理由是——滚动驱动的宿主在 `ReaderContainerView`（它管布局），
    /// 而 PDFView 由 `PDFReaderView` 持有；跨这一层需要一个不含业务语义的把手。
    var jankScrollSurface: (() -> NSView?)?
    /// 全书检索。给定问题，返回最相关的若干片段及各自定位符，用于把提问从
    /// 「当前这一屏」扩展到「整本书」——不引向量库，靠关键词检索 + 定位符引用
    /// 就能让回答可追溯，这是阅读场景下性价比最高的做法。
    var retrieveProvider: ((String) -> [(label: String, locator: DocumentLocator, text: String)])?
    /// 全文切片，用于整本书总结的 map 阶段
    var slicesProvider: (() -> [(label: String, text: String)])?
    /// 跳转到指定位置
    var goTo: ((DocumentLocator) -> Void)?
    /// 上一 / 下一单元（页或章）
    var goToNextUnit: (() -> Void)?
    var goToPreviousUnit: (() -> Void)?
    /// 查找
    var performSearch: ((String) -> Void)?
    var clearSearch: (() -> Void)?
    /// 放大 / 缩小 / 适宽（PDF 专用）
    var zoomIn: (() -> Void)?
    var zoomOut: (() -> Void)?
    var zoomToFit: (() -> Void)?
    /// 取当前视图的上下文文本，供 AI 使用
    var currentContextProvider: (() -> (String, DocumentLocator))?
    /// 取**每个单元开头的短文本**，供 AI 智能目录推断结构。
    ///
    /// 与 `slicesProvider` 分开而不是复用它，是因为两者的取样方式正好相反：
    /// 切片要「每段尽可能多的正文」好用来总结内容，而识别结构只需要每页开头那一小截
    /// （标题、编号都在页首）。复用的话，一本 300 页的书要把全文都读出来才能给出
    /// 首页那点信息，白等好几秒。
    var unitSnippetProvider: (() async -> [(index: Int, text: String)])?
    /// 取某个单元区间（含首尾）的正文，供生成单节摘要。
    /// 区间由调用方决定：一条目录项覆盖到「下一条目录项之前」，桥本身不需要知道目录。
    var sectionTextProvider: ((_ startUnit: Int, _ endUnit: Int) async -> String)?
    /// 同步取某页已缓存的 OCR 文本（扫描件用）
    var ocrTextProvider: ((Int) -> String?)?
    /// 请求对某一页做 OCR
    var requestOCR: ((Int) -> Void)?
    /// 抽取全文（纯文本），供「复制全文」使用。
    ///
    /// 做成异步而不是同步返回字符串：扫描件要靠逐页 OCR 补齐，那是分钟级的事；
    /// 同步接口会逼调用方在主线程上干等。`progress` 每页回调一次，驱动进度卡片。
    var extractFullText: ((_ allowOCR: Bool, _ progress: (TextExtractionProgress) -> Void) async -> DocumentTextReport)?

    // MARK: 批注（外壳 → 视图）

    /// 高亮当前选区并写盘。note 为批注正文，可为空串。
    /// PDF 直接写回原文件；EPUB 存应用数据目录并在页面里画高亮。
    var addHighlight: ((_ note: String) -> Void)?
    /// 把一段文字作为批注插到指定页 / 章。AI「添加到批注」用：
    /// 给得出锚文本时优先锚到原文，否则退为页面便签 / 章节批注。
    var addPageNote: ((_ unitIndex: Int, _ anchorText: String, _ body: String) -> Void)?
    /// 全书批注清单（异步：PDF 要逐页扫）。
    var annotationsProvider: (() async -> [AnnotationItem])?
    /// 删除一条批注。
    var deleteAnnotation: ((_ id: String) async -> Bool)?
    /// 定位第 index 条搜索命中（滚动到具体位置并选中，比跳页更准）。
    var revealSearchHit: ((_ index: Int) -> Void)?
    /// 定位一条批注：翻页 + 滚到位置 + 划线类短暂选中原文（侧栏 → 正文方向）。
    var revealAnnotation: ((_ id: String) -> Void)?
    /// 更新批注正文并落盘（批注面板的「编辑」保存走这里）。
    var updateAnnotationNote: ((_ id: String, _ note: String) async -> Bool)?
    /// 在当前位置新建一条空白批注，返回清单条目（面板的「新建」按钮用）。
    /// 返回 nil 表示创建失败。
    var addNoteAtCurrentPosition: (() async -> AnnotationItem?)?

    // MARK: 便利

    /// 载入新文档时重置全部状态，避免上一本的残留串台。
    func reset() {
        selection = nil
        selectionFromDrag = false
        positionLabel = ""
        progress = 0
        outline = []
        searchResults = []
        searchQuery = ""
        isSearching = false
        isLoading = true
        loadError = nil
        activeOutlineID = nil
        currentUnitIndex = 0
        unitCount = 0
        metadata = DocumentMetadata()
        isScannedDocument = false
        ocrRunningPage = nil
        thumbnailProvider = nil
        setPanelResizing = nil
        viewport.snapshot = .init()
        viewport.pageAspects = []
        jankScrollSurface = nil
        retrieveProvider = nil
        slicesProvider = nil
        goTo = nil
        goToNextUnit = nil
        goToPreviousUnit = nil
        performSearch = nil
        clearSearch = nil
        zoomIn = nil
        zoomOut = nil
        zoomToFit = nil
        currentContextProvider = nil
        ocrTextProvider = nil
        requestOCR = nil
        extractFullText = nil
        unitSnippetProvider = nil
        sectionTextProvider = nil
        addHighlight = nil
        addPageNote = nil
        annotationsProvider = nil
        deleteAnnotation = nil
        revealSearchHit = nil
        revealAnnotation = nil
        updateAnnotationNote = nil
        addNoteAtCurrentPosition = nil
        focusedAnnotationID = nil
    }
}

enum SidebarTab: String, CaseIterable, Identifiable {
    case outline
    case smartOutline
    case search
    case annotations
    case thumbnails

    var id: String { rawValue }

    /// 当前文档可用的页签，顺序即 ⌘1–⌘5 的编号。
    ///
    /// 抽成函数而不是留在视图里：`LeftRail`（图标栏）与 `SidebarColumn`（内容面板）
    /// 都要它，各写一份的话新增页签时漏改一处，表现是「图标栏有五个、菜单里只有四个」。
    static func available(for kind: DocumentKind?) -> [SidebarTab] {
        kind == .pdf
            ? [.outline, .smartOutline, .search, .annotations, .thumbnails]
            : [.outline, .smartOutline, .search, .annotations]
    }

    var title: String {
        switch self {
        case .outline:      return "目录"
        // 页签栏在 248pt 的默认侧栏里只有约 56pt/个，「智能目录」四个字放不下。
        // 缩成两个字 + 星芒图标，指向仍然是唯一的（页内空状态写的是全称）。
        case .smartOutline: return "智能"
        case .search:       return "搜索"
        case .annotations:  return "批注"
        case .thumbnails:   return "页面"
        }
    }

    /// 悬停提示用的全称。
    var fullTitle: String {
        switch self {
        case .outline:      return "文档目录"
        case .smartOutline: return "AI 智能目录"
        case .search:       return "全文搜索"
        case .annotations:  return "批注与高亮"
        case .thumbnails:   return "页面缩略图"
        }
    }

    var systemImage: String {
        switch self {
        case .outline:      return "list.bullet.indent"
        case .smartOutline: return "sparkles.rectangle.stack"
        case .search:       return "magnifyingglass"
        case .annotations:  return "square.and.pencil"
        case .thumbnails:   return "square.grid.2x2"
        }
    }
}
