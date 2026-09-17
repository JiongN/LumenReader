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

    /// 当前文档是否为「没有文本层」的扫描件。为真时阅读区会给 OCR 入口。
    @Published var isScannedDocument: Bool = false
    /// 正在识别的页号（nil 表示空闲），供状态条显示进度
    @Published var ocrRunningPage: Int?

    // MARK: 命令（外壳 → 视图）

    /// 缩略图提供者（PDF 专用）
    var thumbnailProvider: ((Int, CGSize) -> NSImage?)?
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
    /// 同步取某页已缓存的 OCR 文本（扫描件用）
    var ocrTextProvider: ((Int) -> String?)?
    /// 请求对某一页做 OCR
    var requestOCR: ((Int) -> Void)?
    /// 抽取全文（纯文本），供「复制全文」使用。
    ///
    /// 做成异步而不是同步返回字符串：扫描件要靠逐页 OCR 补齐，那是分钟级的事；
    /// 同步接口会逼调用方在主线程上干等。`progress` 每页回调一次，驱动进度卡片。
    var extractFullText: ((_ allowOCR: Bool, _ progress: (TextExtractionProgress) -> Void) async -> DocumentTextReport)?

    // MARK: 便利

    /// 载入新文档时重置全部状态，避免上一本的残留串台。
    func reset() {
        selection = nil
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
    }
}

enum SidebarTab: String, CaseIterable, Identifiable {
    case outline
    case search
    case thumbnails

    var id: String { rawValue }

    var title: String {
        switch self {
        case .outline:    return "目录"
        case .search:     return "搜索"
        case .thumbnails: return "页面"
        }
    }

    var systemImage: String {
        switch self {
        case .outline:    return "list.bullet.indent"
        case .search:     return "magnifyingglass"
        case .thumbnails: return "square.grid.2x2"
        }
    }
}
