import SwiftUI
import AppKit
import LumenKit
import PDFKit

/// PDFKit 的命令式外壳。
///
/// 之所以不做成纯 SwiftUI 的 NSViewRepresentable + Binding：PDFView 有大量
/// 命令式操作（缩放、查找、跳页、选区），用 Controller 持有实例比在
/// updateNSView 里做 diff 更直接，也避免了 SwiftUI 每帧重建 PDFView 的开销。
@MainActor
final class PDFController: NSObject, ObservableObject {

    let view: AnnotatedPDFView
    private let readingDocumentDelegate = ReadingPDFDocumentDelegate()
    private(set) var document: PDFDocument?
    private(set) var documentURL: URL?
    private(set) var pageCount = 0
    private var observers: [NSObjectProtocol] = []
    private var suppressCallbacks = false
    private var lastPublishedPage: Int?
    private weak var viewportState: PDFViewportState?
    private var viewportObserver: NSObjectProtocol?
    private var viewportWork: DispatchWorkItem?
    private var viewportDocumentID = UUID()
    private var resizeAnchor: (PDFPage, CGPoint, Bool)?

    func connectViewport(_ state: PDFViewportState) {
        viewportState = state
        state.onTrackingChange = { [weak self] in self?.scheduleViewport() }
        viewportDocumentID = UUID()
        state.pageAspects = (0..<pageCount).map { index in
            guard let page = document?.page(at: index) else { return 1.4 }
            let bounds = page.bounds(for: .cropBox)
            let rotated = abs(page.rotation % 180) == 90
            return rotated ? bounds.width / max(1, bounds.height) : bounds.height / max(1, bounds.width)
        }
        if let old = viewportObserver { NotificationCenter.default.removeObserver(old) }
        if let clip = view.documentView?.enclosingScrollView?.contentView {
            clip.postsBoundsChangedNotifications = true
            viewportObserver = NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification, object: clip, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.scheduleViewport() }
            }
        }
        publishViewport()
    }

    private func scheduleViewport() {
        guard viewportState?.isTracking == true, viewportWork == nil else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.viewportWork = nil
            self.publishViewport()
        }
        viewportWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0 / 60.0, execute: work)
    }

    private func publishViewport() {
        guard let state = viewportState, let doc = document else { return }
        var snapshot = PDFViewportState.Snapshot(documentID: viewportDocumentID)
        let visible = view.bounds
        for page in view.visiblePages {
            let rect = view.convert(page.bounds(for: .cropBox), from: page)
            if let normalized = ReadingViewportGeometry.normalized(page: rect, visible: visible, flipped: view.isFlipped) {
                snapshot.pageRects[doc.index(for: page)] = normalized
            }
        }
        if let page = view.page(for: CGPoint(x: visible.midX, y: visible.midY), nearest: true) {
            snapshot.centerPage = doc.index(for: page)
            let rect = view.convert(page.bounds(for: .cropBox), from: page)
            let fraction = view.isFlipped ? (visible.midY - rect.minY) / max(1, rect.height) : (rect.maxY - visible.midY) / max(1, rect.height)
            snapshot.centerProgress = min(1, max(0, fraction))
        }
        if state.snapshot != snapshot { state.snapshot = snapshot }
    }

    /// 面板展开 / 收起过渡的观测点（`--panel-transition-report` 读它）。
    ///
    /// 记在 PDFController 而不是 AppState：要断言的现象——`autoScales` 在动画期间的实际取值、
    /// 滚动锚点有没有漂——只有这里看得到。AppState 那边最多能证明「方法被调用了」，
    /// 证明不了「适宽倍率被钉住了」。
    struct PanelTransitionTrace {
        var enters = 0
        var exits = 0
        /// 每次进入「调整中」时 autoScales 的**实际值**（期望一律 false）
        var autoScalesAtEnter: [Bool] = []
        /// 每次退出时恢复用的目标值（期望等于进入前的实际值）
        var restoreTargets: [Bool] = []
        var anchorAtEnter: [(page: Int, progress: Double)] = []
        var anchorAtExit: [(page: Int, progress: Double)] = []
        /// 进入请求因「已经在调整中 / 取不到锚点页」被挡掉的次数
        var ignoredEnters = 0
    }
    private(set) var panelTrace = PanelTransitionTrace()

    /// 自检读的**一次性快照**：累计读数 + 此刻的 `autoScales`。
    ///
    /// 做成快照而不是暴露两个桥闭包：自检要的是「动画进行中它到底是什么值」，
    /// 这必须与累计读数在同一瞬间取到，分两次调用可能跨过完成回调。
    struct PanelTransitionProbe {
        var trace: PanelTransitionTrace
        var autoScalesNow: Bool
    }

    func panelTransitionProbe() -> PanelTransitionProbe {
        PanelTransitionProbe(trace: panelTrace, autoScalesNow: view.autoScales)
    }

    func resetPanelTrace() { panelTrace = PanelTransitionTrace() }

    /// 当前滚动锚点：可见区中心落在哪一页、页内归一化位置多少。
    /// 与 `publishViewport()` 同一套算法——断言量的必须是用户看到的那件事。
    func panelAnchor() -> (page: Int, progress: Double)? {
        guard let doc = document else { return nil }
        let visible = view.bounds
        guard let page = view.page(for: CGPoint(x: visible.midX, y: visible.midY), nearest: true) else { return nil }
        let rect = view.convert(page.bounds(for: .cropBox), from: page)
        let fraction = view.isFlipped
            ? (visible.midY - rect.minY) / max(1, rect.height)
            : (rect.maxY - visible.midY) / max(1, rect.height)
        return (doc.index(for: page), min(1, max(0, fraction)))
    }

    func setPanelResizing(_ active: Bool) {
        // 只在跑面板过渡自检时留痕：这条路径平时每拖一次分隔线会走两回，
        // 无条件打印会把正常使用者的日志灌满。
        if LaunchOptions.panelTransitionReport {
            NSLog("%@", "[Lumen][panel] setPanelResizing(\(active)) 被调用"
                  + "：anchor=\(resizeAnchor == nil ? "无" : "有") autoScales=\(view.autoScales)")
        }
        if active {
            guard resizeAnchor == nil,
                  let page = view.page(for: CGPoint(x: view.bounds.midX, y: view.bounds.midY), nearest: true) else {
                panelTrace.ignoredEnters += 1
                return
            }
            let point = view.convert(CGPoint(x: view.bounds.midX, y: view.bounds.midY), to: page)
            resizeAnchor = (page, point, view.autoScales)
            // 记读数必须在把 autoScales 改掉**之前**
            panelTrace.enters += 1
            panelTrace.autoScalesAtEnter.append(view.autoScales)
            if let anchor = panelAnchor() { panelTrace.anchorAtEnter.append(anchor) }
            view.autoScales = false
        } else {
            guard let (page, point, automatic) = resizeAnchor else { return }
            resizeAnchor = nil
            panelTrace.exits += 1
            panelTrace.restoreTargets.append(automatic)
            DispatchQueue.main.async { [weak self] in
                guard let self, self.resizeAnchor == nil else { return }
                self.view.autoScales = automatic
                if automatic { self.view.scaleFactor = self.view.scaleFactorForSizeToFit }
                self.view.layoutDocumentView()
                if let scroll = self.view.documentView?.enclosingScrollView, let documentView = self.view.documentView {
                    let target = documentView.convert(self.view.convert(point, from: page), from: self.view)
                    let clip = scroll.contentView
                    clip.scroll(to: CGPoint(x: target.x - clip.bounds.width / 2, y: target.y - clip.bounds.height / 2))
                    scroll.reflectScrolledClipView(clip)
                }
                if let anchor = self.panelAnchor() { self.panelTrace.anchorAtExit.append(anchor) }
                self.scheduleViewport()
            }
        }
    }

    /// OCR 结果缓存。按页存，识别过一次就不再重复花钱——
    /// 同一页在 AI 上下文、复制、整书总结这几条路径上会被反复取用。
    private var ocrCache: [Int: OCRPageResult] = [:]

    /// 搜索命中的原始选区（与 `search(_:)` 返回结果一一对应）。
    /// 页面高亮不是存出来的，是每次搜索临时画的；留下选区是为了逐条定位。
    private var searchSelections: [PDFSelection] = []
    /// 搜索高亮的临时批注，连同各自挂载的页一起记下——
    /// 摘除时直奔挂载页，而不是「每条批注扫全书每一页」地找。
    /// saveToFile 前必须摘除，否则搜索痕迹会被写进用户的书里。
    private var searchAnnotations: [(page: PDFPage, annotation: PDFAnnotation)] = []

    /// 写回原文件的结果回报（成功给 toast，失败给 toast + 错误文案）
    var onFileSaved: ((Bool, String) -> Void)?

    /// 正文里点中批注时回调（参数与批注清单里的条目 id 一致）。
    /// 链路：PDFViewAnnotationHit 系统通知 → 这里 → 视图层 → 侧栏批注页签聚焦该行。
    /// 这是「双向联动」的正文 → 侧栏方向；侧栏 → 正文走 `revealAnnotation(id:)`。
    var onAnnotationTapped: ((String) -> Void)?

    var onPositionChange: ((Int, Int) -> Void)?          // (pageIndex, pageCount)
    var onSelectionChange: ((ReaderSelection?) -> Void)?
    var onOutline: (([OutlineNode]) -> Void)?

    /// 右键菜单点了「识别本页文字（OCR）」时递增。
    ///
    /// 用计数器而不是把「识别」的闭包直接存到 `view` 上：后者会让
    /// controller → view → 闭包 → 视图 struct → StateObject → controller 形成引用环。
    /// 视图层用 `onReceive(controller.$ocrRequestTick)` 接住，再跑识别。
    @Published var ocrRequestTick = 0

    override init() {
        // 子类化而不是直接用 PDFView：右键菜单里要能删批注，
        // 命中判断需要拿到事件坐标 → 页面 → 批注，这个职责放在视图层最自然。
        let annotatableView = AnnotatedPDFView()
        self.view = annotatableView
        super.init()
        // controller 回指必须等 super.init 之后：在那之前使用 self 是不允许的
        annotatableView.controller = self
        configureView()
        installObservers()
    }

    deinit {
        if let viewportObserver { NotificationCenter.default.removeObserver(viewportObserver) }
        viewportWork?.cancel()
        for observer in observers {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    // MARK: - 视图配置

    private func configureView() {
        view.displayMode = .singlePageContinuous
        view.displayDirection = .vertical
        view.displaysAsBook = false
        // —— 渲染三旋钮（滚动卡顿的优化面）——
        //
        // 由 `PDFRenderTuning.current` 统一决定，默认 = **原样**（PDFKit 默认 + .high）。
        // 三个旋钮已被单变量实测证伪（省不下 CPU），所以默认不改渲染；
        // `--pdf-render-slim 1` / 单项开关只是留作复跑对照。见 `PDFRenderTuning` 与 VERIFY.md 第七节。
        let tuning = PDFRenderTuning.current
        view.pageShadowsEnabled = tuning.pageShadows
        view.displaysPageBreaks = tuning.pageBreaks
        view.interpolationQuality = tuning.interpolation

        view.pageBreakMargins = NSEdgeInsets(top: 14, left: 0, bottom: 14, right: 0)
        view.autoScales = true
        view.minScaleFactor = 0.2
        view.maxScaleFactor = 8.0
        // 打开时不要让 PDFKit 自作主张地缩小到「适宽」以外的倍率
        view.scaleFactor = 1.0

        NSLog("%@", "[Lumen][pdf] 渲染旋钮：\(tuning.summary)"
            + (tuning.isBaseline ? "（默认·与改造前一致）" : "（非默认：被开关覆盖，见 --pdf-render-slim / --pdf-page-*）"))
    }

    func applyAppearance(theme: ReadingTheme, brightness: Double, original: Bool = false) {
        let base = NSColor(hex: theme.surfaceHex)
        let clamped = min(max(brightness, 0.4), 1.0)
        let target = (base.blended(withFraction: 1 - clamped, of: .black) ?? base).usingColorSpace(.sRGB) ?? base
        view.backgroundColor = target
        guard readingDocumentDelegate.tone.update(original ? nil : PDFReadingTone(theme: theme)),
              let document else { return }
        // Recreate native tiles only when the theme changes, retaining position and selection.
        // setNeedsDisplay on the outer PDFView does not invalidate PDFKit's cached page tiles.
        let destination = view.currentDestination
        let scrollOrigin = view.documentView?.enclosingScrollView?.contentView.bounds.origin
        let selection = view.currentSelection
        let automatic = view.autoScales
        let scale = view.scaleFactor
        suppressCallbacks = true
        view.document = nil
        view.document = document
        view.autoScales = automatic
        view.layoutDocumentView()
        view.scaleFactor = automatic ? view.scaleFactorForSizeToFit : scale
        if let scrollOrigin, let scrollView = view.documentView?.enclosingScrollView {
            scrollView.contentView.scroll(to: scrollOrigin)
            scrollView.reflectScrolledClipView(scrollView.contentView)
        } else if let destination, let page = destination.page {
            let restored = PDFDestination(page: page, at: destination.point)
            restored.zoom = view.scaleFactor
            view.go(to: restored)
        }
        view.setCurrentSelection(selection, animate: false)
        // PDFKit queues an initial scroll after assigning the document; restore after that.
        DispatchQueue.main.async { [weak self, weak document] in
            guard let self, let document, self.document === document else { return }
            if let destination { self.view.go(to: destination) }
            self.view.autoScales = automatic
            self.view.scaleFactor = automatic ? self.view.scaleFactorForSizeToFit : scale
            if let scrollOrigin, let scrollView = self.view.documentView?.enclosingScrollView {
                scrollView.contentView.scroll(to: scrollOrigin)
                scrollView.reflectScrolledClipView(scrollView.contentView)
            }
            self.suppressCallbacks = false
            if let state = self.viewportState { self.connectViewport(state) }
        }
    }

    func apply(flowMode: ReadingFlowMode) {
        view.displayMode = flowMode == .continuous ? .singlePageContinuous : .singlePage
    }

    private func installObservers() {
        let center = NotificationCenter.default

        // 点正文里的批注（高亮 / 便签图标）→ 回报条目 id，让侧栏聚焦对应行。
        // PDFView 自己会把点击路由给批注并发出这个通知，不需要自己摆鼠标事件。
        observers.append(center.addObserver(
            forName: .PDFViewAnnotationHit, object: view, queue: .main
        ) { [weak self] notification in
            MainActor.assumeIsolated {
                guard let self,
                      let annotation = notification.userInfo?["PDFAnnotationHitKey"] as? PDFAnnotation
                else { return }
                // 搜索临时高亮与便签自动带的 Popup 影子不是批注条目，点了不响应
                guard annotation.userName != Self.searchHighlightMarker,
                      annotation.lumenTypeName != "Popup" else { return }
                self.didTapAnnotation(annotation)
            }
        })

        observers.append(center.addObserver(
            forName: .PDFViewPageChanged, object: view, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, !self.suppressCallbacks else { return }
                self.publishPosition()
            }
        })

        observers.append(center.addObserver(
            forName: .PDFViewSelectionChanged, object: view, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, !self.suppressCallbacks else { return }
                self.publishSelection()
            }
        })

        observers.append(center.addObserver(
            forName: .PDFViewScaleChanged, object: view, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.scheduleViewport()
                self.objectWillChange.send()
            }
        })
    }

    // MARK: - 载入

    @discardableResult
    func load(url: URL) -> PDFDocument? {
        guard let doc = PDFDocument(url: url) else { return nil }
        doc.delegate = readingDocumentDelegate
        suppressCallbacks = true
        lastPublishedPage = nil
        document = doc
        documentURL = url
        pageCount = doc.pageCount
        view.document = doc
        view.autoScales = true
        publishPosition()
        publishOutline(doc)
        suppressCallbacks = false
        return doc
    }

    func unload() {
        suppressCallbacks = true
        viewportWork?.cancel()
        viewportWork = nil
        if let viewportObserver { NotificationCenter.default.removeObserver(viewportObserver) }
        viewportObserver = nil
        resizeAnchor = nil
        if let window = view.window, let responder = window.firstResponder as? NSView,
           responder === view || responder.isDescendant(of: view) {
            window.makeFirstResponder(nil)
        }
        view.clearSelection()
        view.document = nil
        document = nil
        documentURL = nil
        pageCount = 0
        // 换文档必须清缓存：页号在新书里指向完全不同的内容
        ocrCache.removeAll()
        searchSelections.removeAll()
        searchAnnotations.removeAll()
        suppressCallbacks = false
    }

    // MARK: - 状态上报

    private func publishPosition() {
        guard let doc = document, let page = view.currentPage else { return }
        let index = doc.index(for: page)
        scheduleViewport()
        guard lastPublishedPage != index else { return }
        lastPublishedPage = index
        onPositionChange?(index, pageCount)
    }

    private func publishSelection() {
        guard let doc = document,
              let selection = view.currentSelection,
              let text = selection.string,
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            onSelectionChange?(nil)
            return
        }

        let pageIndex = selection.pages.first.map { doc.index(for: $0) } ?? currentPageIndex
        let pageText = selection.pages.first?.string ?? text
        let offset = pageText.range(of: text)?.lowerBound.utf16Offset(in: pageText) ?? 0

        // 取选区前后各一段作为上下文，提升 AI 判断准确度
        let preceding = String(pageText.prefix(max(0, offset)))
        let followingStart = min(pageText.count, offset + text.count)
        let following = String(pageText.dropFirst(followingStart))

        onSelectionChange?(ReaderSelection(
            text: text,
            locator: .pdf(page: max(0, pageIndex), charOffset: offset),
            precedingContext: String(preceding.suffix(900)),
            followingContext: String(following.prefix(900))
        ))
    }

    /// 鼠标手势结束后重新发布一次选区。
    ///
    /// 由 `AnnotatedPDFView.mouseUp` 调用：PDFKit 在拖动**过程中**就发过一批
    /// `.PDFViewSelectionChanged`，那一轮的来源标记可能还没越过 4pt 阈值；松手这一刻
    /// 补发，保证「最终选区 + 最终来源标记」一起同步到桥。
    func refreshSelectionFromGesture() {
        publishSelection()
    }

    /// 最近一次选区是否来自**拖动划选**（阈值判定见 `AnnotatedPDFView`）。
    /// 视图层据此写进 `ReaderBridge.selectionFromDrag`。程序化选区（搜索定位、侧栏
    /// 联动）不经过鼠标手势，会保留上一次手势的值——这不影响主诉求（单击不弹），
    /// 且程序化选中一段并显示浮条在语义上也说得通。
    var isSelectionFromDrag: Bool { view.lastGestureWasDrag }

    /// 当前页此刻的 OCR 菜单状态。视图层把它写进 `AnnotatedPDFView.ocrMenuDescriptor`。
    func ocrMenuDescriptor(isRunning: Bool) -> OCRMenuDescriptor {
        if isRunning { return .running }
        return hasCachedOCR(currentPageIndex) ? .alreadyDone : .idle
    }


    private func publishOutline(_ doc: PDFDocument) {
        guard let root = doc.outlineRoot else {
            onOutline?([])
            return
        }
        onOutline?(Self.buildOutline(from: root, document: doc, depth: 0))
    }

    private static func buildOutline(from parent: PDFOutline, document: PDFDocument, depth: Int) -> [OutlineNode] {
        guard depth < 8 else { return [] }
        var nodes: [OutlineNode] = []
        for index in 0..<parent.numberOfChildren {
            guard let child = parent.child(at: index) else { continue }
            let pageIndex = Self.pageIndex(of: child, in: document) ?? 0
            let grandChildren = buildOutline(from: child, document: document, depth: depth + 1)
            nodes.append(OutlineNode(
                title: (child.label ?? "未命名").trimmingCharacters(in: .whitespacesAndNewlines),
                locator: .pdf(page: pageIndex, charOffset: 0),
                children: grandChildren,
                depth: depth
            ))
        }
        return nodes
    }

    private static func pageIndex(of outline: PDFOutline, in document: PDFDocument) -> Int? {
        if let destination = outline.destination, let page = destination.page {
            return document.index(for: page)
        }
        // 有些 PDF 的目录项用 GoTo action 而不是 destination
        if let goTo = outline.action as? PDFActionGoTo, let page = goTo.destination.page {
            return document.index(for: page)
        }
        return nil
    }

    // MARK: - 命令

    var currentPageIndex: Int {
        guard let doc = document, let page = view.currentPage else { return 0 }
        return doc.index(for: page)
    }

    func go(to pageIndex: Int) {
        guard let doc = document, pageIndex >= 0, pageIndex < doc.pageCount,
              let page = doc.page(at: pageIndex) else { return }
        suppressCallbacks = true
        view.go(to: page)
        suppressCallbacks = false
        publishPosition()
    }

    func go(to locator: DocumentLocator) {
        go(to: locator.pageIndex)
    }

    /// 侧栏译文与正文联动。按当前页片段定位，并用 PDFKit 原生选区暂时标出原文；
    /// 不创建批注、不写回文件。页面坐标直接交给 `PDFView.go(to:on:)`，旋转页也由 PDFKit 转换。
    func revealTranslationParagraph(_ paragraph: PDFParagraph, preferredPage: Int) {
        guard let doc = document else { return }
        let fragment = paragraph.fragment(on: preferredPage) ?? paragraph.fragments.first
        guard let fragment, let page = doc.page(at: fragment.pageIndex) else { return }
        view.go(to: page)
        view.layoutDocumentView()
        view.go(to: fragment.bounds.insetBy(dx: -18, dy: -32), on: page)
        if let selection = page.selection(for: fragment.bounds), !(selection.string ?? "").isEmpty {
            view.setCurrentSelection(selection, animate: false)
        }
        publishPosition()
    }

    func goToNextPage() {
        guard let doc = document else { return }
        let next = currentPageIndex + 1
        guard next < doc.pageCount else { return }
        go(to: next)
    }

    func goToPreviousPage() {
        go(to: currentPageIndex - 1)
    }

    /// 缩放并保持视口中心不跳
    func stepZoom(by factor: CGFloat) {
        let target = min(max(view.scaleFactor * factor, view.minScaleFactor), view.maxScaleFactor)
        zoomAroundCenter(to: target)
    }

    func zoomToFitWidth() {
        guard let page = view.currentPage else { return }
        let bounds = page.bounds(for: .mediaBox)
        guard bounds.width > 0 else { return }
        let available = view.bounds.width - 48
        zoomAroundCenter(to: max(view.minScaleFactor, available / bounds.width))
    }

    func resetZoom() {
        zoomAroundCenter(to: view.scaleFactorForSizeToFit)
    }

    /// 以视口中心为锚点缩放。
    /// 直接改 scaleFactor 会让内容从左上角开始重排，视觉上「跳」一下；
    /// 先记录中心点对应的页面坐标，缩放后再把该点挪回视口中心。
    private func zoomAroundCenter(to target: CGFloat) {
        let clamped = min(max(target, view.minScaleFactor), view.maxScaleFactor)

        guard let page = view.currentPage else {
            view.scaleFactor = clamped
            objectWillChange.send()
            return
        }

        let anchor = view.convert(view.bounds.center, to: page)
        view.scaleFactor = clamped
        let point = view.convert(anchor, from: page)
        view.bounds.origin.x += point.x - view.bounds.midX
        view.bounds.origin.y += point.y - view.bounds.midY
        objectWillChange.send()
    }

    /// 查找。PDFKit 的 findString 是同步的，500 页量级通常在百毫秒到 1 秒之间，
    /// 因此调用方需要先显示进度指示。
    ///
    /// 命中的选区会留下来（`searchSelections`）并画成页面高亮：
    /// 搜到 30 处却只能去侧栏里逐条点，等于把「一眼扫到关键词在哪」这件事做丢了。
    /// 高亮是临时批注，清除搜索时摘除，写盘前也会被剥掉。
    func search(_ query: String, limit: Int = 200) -> [SearchHit] {
        clearSearchHighlights()
        guard let doc = document, !query.trimmingCharacters(in: .whitespaces).isEmpty else { return [] }
        let selections = doc.findString(query, withOptions: [.caseInsensitive])

        var hits: [SearchHit] = []
        var highlights: [(page: PDFPage, annotation: PDFAnnotation)] = []
        for selection in selections.prefix(limit) {
            guard let page = selection.pages.first else { continue }
            let pageIndex = doc.index(for: page)
            let snippet = Self.snippet(selection: selection, pageText: page.string ?? "")
            let pageText = page.string ?? ""
            let offset: Int
            if let text = selection.string, let range = pageText.range(of: text) {
                offset = range.lowerBound.utf16Offset(in: pageText)
            } else {
                offset = 0
            }
            hits.append(SearchHit(
                snippet: snippet,
                locator: .pdf(page: pageIndex, charOffset: offset),
                range: offset..<(offset + (selection.string?.count ?? 0))
            ))

            // 临时高亮。每条命中画一个 highlight 批注，颜色与用户批注区分开。
            for line in selection.selectionsByLine() {
                guard let linePage = line.pages.first else { continue }
                let bounds = line.bounds(for: linePage)
                guard bounds.width > 0.5, bounds.height > 0.5 else { continue }
                let piece = PDFAnnotation(bounds: bounds, forType: .highlight, withProperties: nil)
                piece.color = NSColor.systemYellow.withAlphaComponent(0.55)
                piece.userName = Self.searchHighlightMarker
                linePage.addAnnotation(piece)
                highlights.append((linePage, piece))
            }
        }

        searchSelections = Array(selections.prefix(limit))
        searchAnnotations = highlights
        return hits
    }

    /// 逐条定位搜索命中：把对应选区设为当前选区并滚过去。
    /// 比「跳到那一页」准——同一页有五处命中时，页顶跳进来还是不知道看哪里。
    func revealSearchHit(_ index: Int) {
        guard index >= 0, index < searchSelections.count else { return }
        view.setCurrentSelection(searchSelections[index], animate: true)
        view.go(to: searchSelections[index])
    }

    /// 摘掉所有搜索临时高亮。
    func clearSearchHighlights() {
        for (page, annotation) in searchAnnotations {
            page.removeAnnotation(annotation)
        }
        searchAnnotations.removeAll()
    }

    /// 搜索临时高亮的作者标记。
    ///
    /// `nonisolated`：批注清单的枚举是 `nonisolated` 的（自检要在独立 PDFDocument 上
    /// 用同一套 id 对账），它要读这个常量。它是一个 `String` 字面量，跨隔离读是安全的；
    /// 不加会因为「主 actor 隔离的属性被非隔离上下文引用」而在 Swift 6 语言模式下报错。
    nonisolated private static let searchHighlightMarker = "LumenSearch"

    private static func snippet(selection: PDFSelection, pageText: String, radius: Int = 48) -> String {
        guard let match = selection.string, !pageText.isEmpty,
              let range = pageText.range(of: match) else {
            return selection.string ?? ""
        }
        let start = pageText.index(range.lowerBound, offsetBy: -radius, limitedBy: pageText.startIndex) ?? pageText.startIndex
        let end = pageText.index(range.upperBound, offsetBy: radius, limitedBy: pageText.endIndex) ?? pageText.endIndex
        let prefix = start == pageText.startIndex ? "" : "…"
        let suffix = end == pageText.endIndex ? "" : "…"
        return prefix + pageText[start..<end].replacingOccurrences(of: "\n", with: " ") + suffix
    }

    // MARK: - 供 AI / 检索使用的文本

    /// 取一页的可用文本：优先文本层，文本层不够用时回落到已缓存的 OCR 结果。
    ///
    /// 「够不够用」用 24 个字符做门槛，而不是「非空」——扫描件里常常残留
    /// 一两个页眉页码字符，非空判断会让整页正文被一个页码顶掉。
    func usableText(of pageIndex: Int) -> String {
        if let text = document?.page(at: pageIndex)?.string,
           text.trimmingCharacters(in: .whitespacesAndNewlines).count >= 24 {
            return text
        }
        return ocrCache[pageIndex]?.text ?? ""
    }

    /// 取指定页附近的文本（含前后各 radius 页），并给出定位符。
    func text(around pageIndex: Int, radius: Int) -> String {
        guard let doc = document else { return "" }
        let lower = max(0, pageIndex - radius)
        let upper = min(doc.pageCount - 1, pageIndex + radius)
        guard lower <= upper else { return "" }
        return (lower...upper)
            .map { usableText(of: $0) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
    }

    func fullText() -> String {
        guard let doc = document else { return "" }
        var buffer = String()
        buffer.reserveCapacity(1 << 20)
        for index in 0..<doc.pageCount {
            let text = usableText(of: index)
            guard !text.isEmpty else { continue }
            buffer.append(text)
            buffer.append("\n")
        }
        return buffer
    }

    // MARK: - 全文抽取（复制全文）

    /// 逐页抽取纯文本。
    ///
    /// 与 `usableText` 的取舍**故意不同**，这点很关键：
    /// `usableText` 用 24 字符当门槛，是为了 AI 上下文——那种场景下宁可这页什么都不给，
    /// 也好过把「12」这种页码当成正文喂给模型。但「复制全文」是给用户自己用，少一格正文
    /// 比多一个页码严重得多，所以这里默认只要文本层非空就采用。
    ///
    /// 唯一的例外是扫描件：那种文档的文本层里往往散着几个页码水印，这时仍用 24 字符门槛，
    /// 让这些页走 OCR，读者才不会拿到一本只剩页码的书。
    ///
    /// - Parameters:
    ///   - allowOCR: 没有文本层的页要不要现场识别。为 false 时只消费已有缓存。
    ///   - progress: 每页回调一次，用来驱动进度卡片。
    func extractFullText(
        allowOCR: Bool,
        progress: (TextExtractionProgress) -> Void
    ) async -> DocumentTextReport {
        guard let doc = document else { return DocumentTextReport() }

        let total = doc.pageCount
        let scanned = detectScannedDocument()
        let layerThreshold = scanned ? 24 : 1

        var report = DocumentTextReport()
        report.totalUnits = total

        var pieces: [String] = []
        pieces.reserveCapacity(total)

        for index in 0..<total {
            if Task.isCancelled { break }

            let raw = (doc.page(at: index)?.string ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let layerUsable = raw.count >= layerThreshold

            if layerUsable {
                pieces.append(raw)
                report.textLayerUnits += 1
            } else if let cached = ocrCache[index]?.text,
                      !cached.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                pieces.append(cached.trimmingCharacters(in: .whitespacesAndNewlines))
                report.ocrUnits += 1
            } else if allowOCR {
                progress(TextExtractionProgress(
                    completed: index,
                    total: total,
                    phase: "正在识别第 \(index + 1) / \(total) 页"
                ))
                if let result = try? await recognize(page: index) {
                    let recognized = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !recognized.isEmpty {
                        pieces.append(recognized)
                        report.ocrUnits += 1
                    }
                }
            }

            progress(TextExtractionProgress(
                completed: index + 1,
                total: total,
                phase: "已处理 \(index + 1) / \(total) 页"
            ))
        }

        report.text = pieces.joined(separator: "\n\n")
        return report
    }

    // MARK: - 扫描件与 OCR

    /// 判定这本 PDF 是不是「没有文本层」的扫描件。
    ///
    /// 不逐页扫（几百页的 'string' 加起来会卡住主线程），而是等距抽样几页：
    /// 一本真正的扫描书不会只有首页没文本层。抽到的页里多数为空即判定为扫描件。
    func detectScannedDocument(samples: Int = 8) -> Bool {
        guard let doc = document, doc.pageCount > 0 else { return false }
        let step = max(1, doc.pageCount / max(samples, 1))

        var checked = 0
        var empty = 0
        var index = 0
        while index < doc.pageCount && checked < samples {
            checked += 1
            let text = doc.page(at: index)?.string ?? ""
            if text.trimmingCharacters(in: .whitespacesAndNewlines).count < 24 {
                empty += 1
            }
            index += step
        }

        guard checked > 0 else { return false }
        return Double(empty) / Double(checked) >= 0.6
    }

    /// 指定页有没有可用的文本层
    func hasTextLayer(_ index: Int) -> Bool {
        guard let page = document?.page(at: index) else { return false }
        let text = page.string ?? ""
        return text.trimmingCharacters(in: .whitespacesAndNewlines).count >= 24
    }

    /// 已识别的页（缓存命中即可同步取用，供 AI 上下文与整书总结直接消费）
    func cachedOCRText(_ index: Int) -> String? {
        ocrCache[index]?.text
    }

    func hasCachedOCR(_ index: Int) -> Bool {
        ocrCache[index] != nil
    }

    /// 已经识别过的页号，用于在缩略图/状态条上做标记
    var ocrRecognizedPages: Set<Int> { Set(ocrCache.keys) }

    /// 对一页跑 OCR。
    ///
    /// 渲染在主线程（PDFKit 不是线程安全的），识别放到后台——
    /// 一页 2 倍图在 .accurate 下要 1~3 秒，留在主线程就是肉眼可见的卡顿。
    func recognize(page index: Int, scale: CGFloat = 2.0) async throws -> OCRPageResult {
        guard let doc = document, index >= 0, index < doc.pageCount else {
            throw OCRError.renderFailure
        }
        if let cached = ocrCache[index] { return cached }

        guard let image = Self.renderImage(page: doc.page(at: index), scale: scale) else {
            throw OCRError.renderFailure
        }

        let result = try await Task.detached(priority: .userInitiated) {
            try OCRService.recognize(in: image)
        }.value

        ocrCache[index] = result
        return result
    }

    /// 把一页画成位图。
    private static func renderImage(page: PDFPage?, scale: CGFloat) -> CGImage? {
        guard let page else { return nil }

        let bounds = page.bounds(for: .mediaBox)
        guard bounds.width > 1, bounds.height > 1 else { return nil }

        // 上限 3600px 边长：再高对识别没有增益，只会让内存和耗时翻倍
        let longest = max(bounds.width, bounds.height) * scale
        let clamp = longest > 3600 ? 3600 / longest : 1
        let effectiveScale = scale * clamp

        let width = Int((bounds.width * effectiveScale).rounded())
        let height = Int((bounds.height * effectiveScale).rounded())
        guard width > 0, height > 0 else { return nil }

        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ) else { return nil }

        // 先铺白底：没铺的话透明区域在二值化时会被当成黑，识别率直接崩
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))

        context.scaleBy(x: effectiveScale, y: effectiveScale)
        context.translateBy(x: -bounds.origin.x, y: -bounds.origin.y)
        if let readingPage = page as? ReadingPDFPage {
            readingPage.drawOriginal(with: .mediaBox, to: context)
        } else {
            page.draw(with: .mediaBox, to: context)
        }

        return context.makeImage()
    }

    // MARK: - 批注（写入原 PDF 文件）

    /// 我们创建的批注都带这个作者标记，与搜索高亮、外来批注（Preview / Acrobat 画的）区分。
    private static let annotationAuthor = "Lumen"

    /// 把「划线片段」扩成它所在的**整行**。
    ///
    /// 为什么必须扩：`selectionsByLine()` 给出的矩形只是**选中片段**的范围。用户从词中间
    /// 起划、在句中收手时，这段矩形就只有半行——画出来的高亮从词中间断开，清单里的引文
    /// 也只剩「人）属于哪个群体」这种断头句（实测用户库里 13 条高亮里有 3 条是这样）。
    /// 批注的语义是「这一行」，不是「这几个字」。
    ///
    /// 取整行用整页宽的窄带交给 PDFKit 反查，**不能自己在 `page.string` 里找行边界**：
    /// 同一页出现多个相同文字时字符串查找会选错位置，而矩形探测自带位置信息。
    ///
    /// 竖直方向只取行高的中段（±0.2 起、0.6 高）：相邻行间距小时，压满行高的窄带会把
    /// 上下相邻行的字一起带进来。
    ///
    /// 三道守卫，任一不过就返回 nil（由调用方回退到原片段，保证扫描件与异常版面不会把高亮弄丢）：
    /// 1. 竖直带必须与片段有足够重叠（真在同一行）；
    /// 2. 结果高度不得明显大于片段（防 API 把两行并成一行）；
    /// 3. 结果必须真的**包含**片段（防止给出别的行）。
    ///
    /// - Important: **未做分栏检测。** 实测用户库中的文档均为单栏（把页渲染成像素、
    ///   按列统计墨迹密度，中央 30% 区域密度 64~84 / 峰值 170~240，剖面均匀、无栏沟），
    ///   整页宽带在那里就是正解。若将来遇到**真正的**双栏 PDF，本扩展可能跨栏。
    ///   留这条边界是因为本机没有可验证的双栏样本，做一个验不了的检测器等于没做。
    nonisolated static func fullRowBounds(for fragment: CGRect, on page: PDFPage) -> CGRect? {
        let media = page.bounds(for: .mediaBox)
        guard media.width > 1, fragment.height > 0.5 else { return nil }
        let band = CGRect(
            x: media.minX,
            y: fragment.minY + fragment.height * 0.2,
            width: media.width,
            height: fragment.height * 0.6
        )
        // `page.selection(for:)` 没压到文字时返回的是**空选区而不是 nil**（项目里踩过这个坑）
        guard let selection = page.selection(for: band),
              let text = selection.string,
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        let row = selection.bounds(for: page)
        guard row.width > 0.5, row.height > 0.5 else { return nil }

        // 守卫 1：竖直方向确实在同一行
        let overlap = min(row.maxY, fragment.maxY) - max(row.minY, fragment.minY)
        guard overlap > fragment.height * 0.4 else { return nil }
        // 守卫 2：高度不能明显超出片段（否则多半把邻行并进来了）
        guard row.height < fragment.height * 1.8 else { return nil }
        // 守卫 3：必须真的包含原片段
        guard row.minX <= fragment.minX + 1, row.maxX >= fragment.maxX - 1 else { return nil }
        return row
    }

    /// `NSColor` → `#RRGGBB`。取不到 sRGB 表示时返回 nil。
    nonisolated static func hexString(from color: NSColor?) -> String? {
        guard let c = color?.usingColorSpace(.sRGB) else { return nil }
        let r = Int((c.redComponent * 255).rounded())
        let g = Int((c.greenComponent * 255).rounded())
        let b = Int((c.blueComponent * 255).rounded())
        return String(format: "#%02X%02X%02X", r, g, b)
    }

    /// 同一页放便签图标时，找一个不与已有 Text 批注重叠的落点。
    ///
    /// 原本固定放在 `(width-44, height-44)`，于是**同一页的每条便签原点完全相同**，
    /// 而 `entryID` 正是「页号 + 原点 + 类型」——同页两条便签必然撞 id，
    /// 清单里点哪条都跳到第一条。这里按 30pt 逐级下移找空位。
    nonisolated static func freeNoteIconOrigin(on page: PDFPage, existing: [PDFAnnotation]) -> CGPoint {
        let pageBounds = page.bounds(for: .mediaBox)
        let taken = Set(existing
            .filter { $0.lumenTypeName == "Text" }
            .map { Int($0.bounds.origin.y.rounded()) })
        var y = pageBounds.height - 44
        while taken.contains(Int(y.rounded())) && y > 40 {
            y -= 30
        }
        return CGPoint(x: pageBounds.width - 44, y: y)
    }

    /// 高亮当前选区。
    ///
    /// - Parameter note: 批注正文，可空——纯高亮没有正文。
    /// 每页使用一个标准 QuadPoints 高亮，跨行仍属于同一条批注。
    /// - Returns: 是否至少画上了一处（扫描件上没有文本层时选区是空的）。
    @discardableResult
    func addHighlight(fromCurrentSelection note: String) -> Bool {
        guard let selection = view.currentSelection, document != nil else { return false }

        guard addMarkup(selection: selection, note: note, color: NSColor.systemYellow.withAlphaComponent(0.45)) else { return false }
        // 选区已被「用掉」：高亮之后还留着蓝色选区会让人以为没生效
        view.setCurrentSelection(nil, animate: false)
        return saveToFile()
    }

    private func addMarkup(selection: PDFSelection, note: String, color: NSColor) -> Bool {
        var added = false
        for page in selection.pages {
            let rectangles = selection.selectionsByLine().filter { $0.pages.contains(page) }
                .map { $0.bounds(for: page) }
            guard let annotation = PDFAnnotationGeometry.makeHighlight(rectangles: rectangles,
                note: note, color: color, author: Self.annotationAuthor) else { continue }
            page.addAnnotation(annotation)
            added = true
        }
        return added
    }

    /// 在指定页加一条纯文字批注（页面右上角的便签图标，点开看内容）。
    ///
    /// - Parameter anchorText: 可选的锚文本。给得出锚文本时先在页内找到它并画高亮，
    ///   批注文字挂在高亮上——「AI 的这句话指向原文哪一段」就一目了然；
    ///   找不到（比如扫描件）就退回页面便签。
    @discardableResult
    func addNote(pageIndex: Int, anchorText: String, body: String) -> Bool {
        guard let doc = document, pageIndex >= 0, pageIndex < doc.pageCount,
              let page = doc.page(at: pageIndex) else { return false }

        let trimmedAnchor = anchorText.trimmingCharacters(in: .whitespacesAndNewlines)
        let stamp = Date()

        // 锚文本定位：在**本页**范围内找，避免全书 findString 把别的页的同名句抢走
        if trimmedAnchor.count >= 6, let anchorSelection = selection(of: trimmedAnchor, on: pageIndex) {
            if addMarkup(selection: anchorSelection, note: body, color: NSColor.systemTeal.withAlphaComponent(0.40)) {
                return saveToFile()
            }
        }

        // 页面便签：放在右上角空白处，图标式批注不遮正文。
        // 落点要与本页已有便签错开——同页两条便签原点相同会让它们的清单 id 撞车。
        let origin = Self.freeNoteIconOrigin(on: page, existing: page.annotations)
        let iconBounds = CGRect(x: origin.x, y: origin.y, width: 24, height: 24)
        let annotation = PDFAnnotation(bounds: iconBounds, forType: .text, withProperties: nil)
        annotation.contents = body
        annotation.userName = Self.annotationAuthor
        annotation.modificationDate = stamp
        annotation.color = NSColor.systemTeal
        page.addAnnotation(annotation)
        return saveToFile()
    }

    /// 当前选区的划线原文（创建批注条目时用）。
    var currentSelectionText: String {
        view.currentSelection?.string ?? ""
    }

    /// 当前页面里挂着的搜索临时高亮条数。自检用：
    /// 「搜索高亮没有写进文件」这条断言需要先能数出它确实存在过。
    var searchHighlightCount: Int { searchAnnotations.count }

    /// 找出一段文字在**指定页**上的选区。
    ///
    /// 这里有两条能达到同一终值的路，代价差一个量级，实测后选了后者：
    ///
    /// - `PDFDocument.findString` 是**全书**范围的。用它做「本页定位」要先扫完全书、
    ///   再按页号筛，一本书 500 页时为了一句锚文本白扫一遍；
    /// - `PDFPage.selection(for: NSRange)` 的 range 是**本页字符串**的索引，
    ///   于是可以先在 `page.string` 里做普通字符串查找拿到精确 range，
    ///   再交给 PDFKit 出选区。代价只与本页字数有关，也不可能被别页的同名句抢走。
    ///
    /// 换用页内查找还有一个更硬的理由：**`findString` 只认「文档里就是空格」的位置**。
    /// 实测（`/tmp/pdfprobe3.swift`）：`findString("知识\n教师")` 命中 1 处，
    /// 而 `findString("知识 教师")` 命中 0 处。引文只要跨了换行、又在中途被换成空格，
    /// 整段就再也匹配不上——AI 复述的引文十有八九是这种形态。
    ///
    /// 所以候选串按「从长到短」逐个试（见 `anchorCandidates`）。
    /// **宁可锚得短一点，也不要锚错**——锚不准的批注比没有批注更糟：
    /// 它会把一段不相干的话标成高亮，用户看到时已经分辨不出是谁标错了。
    private func selection(of text: String, on pageIndex: Int) -> PDFSelection? {
        guard let doc = document, let page = doc.page(at: pageIndex) else { return nil }
        let pageText = page.string ?? ""
        guard !pageText.isEmpty else { return nil }

        for candidate in Self.anchorCandidates(from: text) {
            guard let range = pageText.range(of: candidate, options: [.caseInsensitive]) else { continue }
            if let selection = page.selection(for: NSRange(range, in: pageText)),
               !(selection.string ?? "").isEmpty {
                return selection
            }
        }
        return nil
    }

    /// 锚文本的候选串，从长到短、去重。
    ///
    /// 输入通常是「用户拖选的一段」或「AI 复述的一句」，与页面字符串的空白形态未必一致：
    /// 行尾换行、行内多空格都可能对不上。整段匹配不上时按行退让——
    /// 先试每一行（行内连续空白折叠成单空格），再试首行的前缀。
    /// 前缀截断一定会停下：每次缩短到 3/4，下限 8 字。
    static func anchorCandidates(from text: String) -> [String] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        var candidates: [String] = [trimmed]

        let lines = trimmed
            .split(whereSeparator: { $0.isNewline })
            .map { $0.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ") }
            .filter { $0.count >= 4 }
        if lines.count > 1 {
            candidates.append(contentsOf: lines)
        }

        for line in lines {
            var length = line.count
            while length > 8 {
                length = max(8, length * 3 / 4)
                candidates.append(String(line.prefix(length)))
            }
        }

        // 页内查找是线性扫描，候选串里重复项白扫一遍，且重复的短路没意义
        var seen = Set<String>()
        return candidates.filter { $0.count >= 4 && seen.insert($0).inserted }
    }

    /// 「全书 findString + 按页筛」与「页内查找」的耗时对照。自检用：
    /// 两条路返回的**是同一段文字**，所以断言只能打在代价上——否则换了实现也看不出来。
    /// 只报数、不断言：耗时本来就抖，把它写成断言只会得到一条时灵时不灵的测试。
    func anchorLookupCostProbe(anchor: String, pageIndex: Int) -> (wholeBook: Int, pageLocal: Int) {
        guard let doc = document, let page = doc.page(at: pageIndex) else { return (0, 0) }
        let pageText = page.string ?? ""

        // 冷启动（首次 findString 要建索引）放在最前，别让它污染第二次测量
        let t0 = Date()
        _ = doc.findString(anchor, withOptions: [.caseInsensitive]).first { selection in
            selection.pages.first.map { doc.index(for: $0) == pageIndex } ?? false
        }
        let wholeBook = Int(Date().timeIntervalSince(t0) * 1_000_000)

        let t1 = Date()
        _ = pageText.range(of: anchor, options: [.caseInsensitive])
        let pageLocal = Int(Date().timeIntervalSince(t1) * 1_000_000)

        return (wholeBook, pageLocal)
    }

    /// 全书批注清单（含外来批注：Preview、Acrobat 画的也能看见、能删）。
    ///
    /// 逐页扫。批注量与页数都大时可能上百毫秒，因此做成 async，
    /// 调用方（侧栏列表）挂到任务里跑，每 24 页让一次主线程。
    ///
    /// **顺序按内容位置排**（页号升序 → 页内自上而下 → 从左到右），不再按创建时间倒序。
    /// 原来的「什么时候划的」排法在真实文件上把清单打成一串碎片——
    /// 实测用户那份 31 页论文返回的是 `p16 p16 p14 p8 p8 p8 p7 p7 p7 p5 p5 p3 p3 p3`，
    /// 页码来回跳，读者没法用它对着正文从头看。
    func annotationsList() async -> [AnnotationItem] {
        guard let doc = document else { return [] }
        // 位置信息（页号 / 页内 y / x）只在排序时需要，不塞进 AnnotationItem——
        // 那是跨格式的展示模型，为排序往里面塞 PDF 专有几何字段会污染 EPUB 侧。
        var rows: [(item: AnnotationItem, page: Int, y: CGFloat, x: CGFloat)] = []

        for (offset, entry) in enumerateAnnotationEntries().enumerated() {
            if offset % 24 == 0 { await Task.yield() }
            let annotation = entry.annotation
            let isMarkup = annotation.lumenIsMarkup
            let page = doc.page(at: entry.pageIndex)

            let stored = entry.bounds
            let row = stored
            let truncated = isMarkup && entry.members.contains { member in
                guard member.value(forAnnotationKey: PDFAnnotationGeometry.identityKey) == nil,
                      (member.quadrilateralPoints?.count ?? 0) <= 4,
                      let page, let expanded = Self.fullRowBounds(for: member.bounds, on: page) else { return false }
                return expanded.minX < member.bounds.minX - 0.5 || expanded.maxX > member.bounds.maxX + 0.5
            }
            var quote = ""
            if isMarkup, let page {
                let rects = entry.members.flatMap { member -> [CGRect] in
                    if member.value(forAnnotationKey: PDFAnnotationGeometry.identityKey) == nil,
                       (member.quadrilateralPoints?.count ?? 0) <= 4,
                       let expanded = Self.fullRowBounds(for: member.bounds, on: page) { return [expanded] }
                    return PDFAnnotationGeometry.rectangles(of: member)
                }
                quote = rects.compactMap { page.selection(for: $0)?.string }.joined(separator: "\n")
            }
            // FreeText 的正文就是它显示的字，没有独立引文
            if quote.isEmpty, annotation.lumenTypeName == "FreeText" {
                quote = annotation.contents ?? ""
            }

            let item = AnnotationItem(
                id: entry.id,
                locator: .pdf(page: entry.pageIndex, charOffset: 0),
                quote: String(quote.prefix(400)),
                note: annotation.contents ?? "",
                hasHighlight: isMarkup,
                createdAt: annotation.modificationDate ?? Date.distantPast,
                // 高亮类才带色：列表里据此显示与页面一致的色块
                highlightHex: isMarkup ? Self.hexString(from: annotation.color) : nil,
                truncated: truncated
            )
            rows.append((item, entry.pageIndex, row.origin.y, row.origin.x))
        }

        rows.sort { l, r in
            if l.page != r.page { return l.page < r.page }
            // PDF 原点在左下角，y 越大越靠上 ⇒ 阅读顺序越前，故降序
            if abs(l.y - r.y) > 0.5 { return l.y > r.y }
            return l.x < r.x
        }
        return rows.map(\.item)
    }

    /// (页号, 批注, 清单 id) 的**唯一枚举源**：列表、删除、更新、定位四处共用。
    ///
    /// 抽出来是因为 id 现在带「同基串出现序号」（见 `entryID`）：一旦枚举逻辑分家，
    /// 列表算出的 id 与按 id 定位时算出的 id 就会不一致，表现为**点删除删错条**。
    ///
    /// id 的生成只依赖文档本身，**与展示排序无关**——所以这里页内按 y 升序枚举
    /// （保证同一基串的出现序号是文档的确定函数），而 `annotationsList()` 另按阅读顺序展示。
    private struct AnnotationEntry {
        let id: String
        let pageIndex: Int
        let members: [PDFAnnotation]
        var annotation: PDFAnnotation { members[0] }
        var bounds: CGRect { members.dropFirst().reduce(annotation.bounds) { $0.union($1.bounds) } }
    }

    private func enumerateAnnotationEntries() -> [AnnotationEntry] {
        guard let doc = document else { return [] }
        var out: [AnnotationEntry] = []
        var seen: [String: Int] = [:]
        for index in 0..<doc.pageCount {
            guard let page = doc.page(at: index) else { continue }
            let candidates = page.annotations.filter { Self.isListableAnnotation($0) }.sorted {
                if abs($0.bounds.maxY - $1.bounds.maxY) > 0.5 { return $0.bounds.maxY > $1.bounds.maxY }
                return $0.bounds.minX < $1.bounds.minX
            }
            var groups: [[PDFAnnotation]] = []
            for annotation in candidates {
                if let last = groups.last?.last,
                   PDFAnnotationGeometry.continuesLegacyGroup(last, annotation, author: Self.annotationAuthor) {
                    groups[groups.count - 1].append(annotation)
                } else { groups.append([annotation]) }
            }
            for members in groups {
                let base = Self.entryID(members[0], pageIndex: index)
                let count = (seen[base] ?? 0) + 1
                seen[base] = count
                out.append(AnnotationEntry(id: count == 1 ? base : "\(base)#\(count)", pageIndex: index, members: members))
            }
        }
        return out
    }

    func annotationID(for annotation: PDFAnnotation) -> String? {
        enumerateAnnotationEntries().first { $0.members.contains { $0 === annotation } }?.id
    }

    func didTapAnnotation(_ annotation: PDFAnnotation) {
        if let id = annotationID(for: annotation) { onAnnotationTapped?(id) }
    }

    /// 能进清单的批注：排除搜索临时高亮、排除 Popup 影子批注，其余高亮/便签都算。
    nonisolated static func isListableAnnotation(_ annotation: PDFAnnotation) -> Bool {
        if annotation.userName == searchHighlightMarker { return false }
        if annotation.lumenTypeName == "Popup" { return false }
        return annotation.lumenIsMarkup || annotation.lumenIsNote
    }

    /// 按 `annotationsList()` 给出的 id 删除批注。
    @discardableResult
    func deleteAnnotation(id: String) -> Bool {
        guard let doc = document,
              let entry = enumerateAnnotationEntries().first(where: { $0.id == id }),
              let page = doc.page(at: entry.pageIndex) else { return false }
        entry.members.forEach { page.removeAnnotation($0) }
        return saveToFile()
    }

    /// 清单条目 id 的**基串**（列表、删除、更新、定位共用）。
    ///
    /// 组成是「页号 + 原点 + 类型」，**刻意不含时间戳**：
    /// - 跨行高亮会一口气画出多条共享同一个 `modificationDate` 的批注，
    ///   只按时间戳生成 id 必然撞车，ForEach 撞上重复 id 的行为是未定义的；
    /// - 更隐蔽的是精度：PDF 日期格式只存到**秒**，而内存里的 Date 带亚秒——
    ///   写盘再重开 id 就变了，「编辑后从文件里核对」永远对不上账。
    /// 四舍五入而不是截断，避免存取之间的小数漂移恰好跨过整数边界。
    /// nonisolated：自检的独立 PDFDocument 也要用同一套 id 对账。
    ///
    /// ⚠️ 这个基串**并不保证唯一**。原注释断言「同一页同一原点还同类型的两条批注
    /// 实际上不存在」，但 `addPageNoteAtCurrentPosition` 把便签图标固定放在页面右上角
    /// （`width-44, height-44`）——同页两条便签原点完全相同，这个前提不成立。
    /// 真正的唯一 id 由 `enumerateAnnotationEntries()` 在基串后追加出现序号 `#k` 得到；
    /// 落点冲突本身也已在 `freeNoteIconOrigin(on:existing:)` 里修掉。
    nonisolated static func entryID(_ annotation: PDFAnnotation, pageIndex: Int) -> String {
        if let identity = annotation.value(forAnnotationKey: PDFAnnotationGeometry.identityKey) as? String {
            return "\(pageIndex)-lumen-\(identity)"
        }
        let origin = annotation.bounds.origin
        return "\(pageIndex)-\(Int(origin.x.rounded()))x\(Int(origin.y.rounded()))-\(annotation.lumenTypeName)"
    }

    /// 按 id 更新批注正文并写盘（批注面板的「编辑」走这里）。
    /// 找不到返回 false——比如文档已经换掉了。
    @discardableResult
    func updateNote(id: String, body: String) -> Bool {
        guard let entry = enumerateAnnotationEntries().first(where: { $0.id == id }) else { return false }
        entry.members.forEach { $0.contents = body }
        return saveToFile()
    }

    /// 按 id 定位一条批注：翻到所在页、滚到批注的位置，划线类还会短暂选中原文——
    /// 「是哪一处」要有明确的视觉回应，只翻页是找不到一条便签图标的。
    @discardableResult
    func revealAnnotation(id: String) -> Bool {
        guard let doc = document,
              let entry = enumerateAnnotationEntries().first(where: { $0.id == id }),
              let page = doc.page(at: entry.pageIndex) else { return false }
        let annotation = entry.annotation
        let row = entry.bounds
        view.go(to: page)
        view.layoutDocumentView()
        // Rect-based navigation handles page rotation and keeps the target inside the viewport.
        view.go(to: row.insetBy(dx: -24, dy: -48), on: page)
        if annotation.lumenIsMarkup {
            let selection = PDFSelection(document: doc)
            for rect in entry.members.flatMap({ PDFAnnotationGeometry.rectangles(of: $0) }) {
                if let fragment = page.selection(for: rect) { selection.add(fragment) }
            }
            view.setCurrentSelection(selection, animate: false)
        }
        return true
    }

    /// 把**文件里已存在的** Lumen 高亮矩形扩到整行（历史数据修正）。
    ///
    /// 读取侧（清单引文、定位高亮）已经会补算整行，但存进 PDF 的矩形还是半行：
    /// 用系统「预览」或 Acrobat 打开同一个文件看到的仍是半行，本应用重开时
    /// 页面上画的也是那个半行矩形。这个方法把文件里的矩形真正改宽，两边才一致。
    ///
    /// 边界（都写在这里，因为它动的是用户的文件）：
    /// - 只动 **Lumen 自己画的划线类批注**（`userName == annotationAuthor`），
    ///   Preview / Acrobat 画的批注一律不碰；
    /// - **只加宽，不删除、不改任何文字内容**（`contents` 原样保留）；
    /// - 扩不动（扫描件无文本层、多行高亮等被三道守卫拦下）的保持原样；
    /// - 全过程只写一次盘（大文件上这一次序列化约 0.5s，见 `saveToFile` 的说明）。
    ///
    /// - Returns: 实际被加宽的条数；0 表示无需修正或写盘失败。
    @discardableResult
    func normalizeAnnotationRows() -> Int {
        guard let doc = document else { return 0 }
        var changed = 0
        for entry in enumerateAnnotationEntries() {
            guard let page = doc.page(at: entry.pageIndex) else { continue }
            var groupChanged = false
            for annotation in entry.members {
                guard annotation.lumenIsMarkup, annotation.userName == Self.annotationAuthor,
                      annotation.value(forAnnotationKey: PDFAnnotationGeometry.identityKey) == nil,
                      (annotation.quadrilateralPoints?.count ?? 0) <= 4,
                      let row = Self.fullRowBounds(for: annotation.bounds, on: page),
                      row.minX < annotation.bounds.minX - 0.5 || row.maxX > annotation.bounds.maxX + 0.5 else { continue }
                annotation.bounds = row
                groupChanged = true
            }
            if groupChanged { changed += 1 }
        }
        guard changed > 0 else { return 0 }
        return saveToFile() ? changed : 0
    }

    /// 在当前页加一条空白便签并返回它的清单条目（批注面板「新建」走这里）。
    /// 返回 nil 表示创建或写盘失败。
    func addPageNoteAtCurrentPosition() -> AnnotationItem? {
        guard let doc = document else { return nil }
        let pageIndex = min(max(currentPageIndex, 0), doc.pageCount - 1)
        guard let page = doc.page(at: pageIndex) else { return nil }

        let stamp = Date()
        // 落点要避开本页已有便签：固定右上角会让同页两条便签的原点完全相同，
        // 而清单 id 是「页号 + 原点 + 类型」，撞 id 后点哪条都跳到第一条。
        let origin = Self.freeNoteIconOrigin(on: page, existing: page.annotations)
        let iconBounds = CGRect(x: origin.x, y: origin.y, width: 24, height: 24)
        let annotation = PDFAnnotation(bounds: iconBounds, forType: .text, withProperties: nil)
        annotation.contents = ""
        annotation.userName = Self.annotationAuthor
        annotation.modificationDate = stamp
        annotation.color = NSColor.systemTeal
        page.addAnnotation(annotation)
        guard saveToFile() else { return nil }

        // id 必须走与清单**同一个**枚举源：直接算 entryID 会漏掉 #k 序号，
        // 于是新建出来的那条 id 与列表里的对不上，紧接着的「编辑」会找不到它。
        guard let entry = enumerateAnnotationEntries().first(where: { $0.annotation === annotation }) else {
            return nil
        }
        return AnnotationItem(
            id: entry.id,
            locator: .pdf(page: pageIndex, charOffset: 0),
            quote: "",
            note: "",
            hasHighlight: false,
            createdAt: stamp
        )
    }

    /// 右键菜单命中批注后回调：`AnnotatedPDFView` 负责找批注，这里负责动作。
    /// 返回的 Bool 表示是否已删除并写盘成功。
    @discardableResult
    func delete(annotation: PDFAnnotation) -> Bool {
        guard let id = annotationID(for: annotation) else { return false }
        return deleteAnnotation(id: id)
    }

    /// 把当前文档（含批注）写回**原文件**。
    ///
    /// 先摘除搜索临时高亮再取字节流，写完放回去——搜索痕迹绝不能固化进用户的书。
    /// 原子写：写坏一半的 PDF 比没有批注严重得多。
    @discardableResult
    func saveToFile() -> Bool {
        guard let doc = document, let url = documentURL else { return false }

        detachSearchHighlights()
        defer { reattachSearchHighlights() }

        guard let data = PDFOriginalRendering.data(of: doc) else {
            onFileSaved?(false, "无法生成 PDF 数据")
            return false
        }
        do {
            try data.write(to: url, options: .atomic)
            onFileSaved?(true, "已保存到原文件")
            return true
        } catch {
            onFileSaved?(false, "保存失败：\(error.localizedDescription)")
            return false
        }
    }

    private func detachSearchHighlights() {
        for (page, annotation) in searchAnnotations {
            page.removeAnnotation(annotation)
        }
    }

    private func reattachSearchHighlights() {
        for (page, annotation) in searchAnnotations {
            page.addAnnotation(annotation)
        }
    }
}

private extension CGRect {
    var center: CGPoint { CGPoint(x: midX, y: midY) }
}

// MARK: - 批注类型判定

/// PDFKit 的类型名有**两种写法**，这是踩过一次的地方：
///
/// - `PDFAnnotationSubtype.highlight.rawValue` == `"/Highlight"`（**带斜杠**，PDF 里的名字）；
/// - `annotation.type` == `"Highlight"`（**不带斜杠**）。
///
/// 直接拿两者比相等，永远为假——而且失败得很安静：批注明明画在页面上、
/// 也写进了文件，清单里却是空的。所以这里统一成「去掉斜杠」的形式再比。
extension PDFAnnotation {

    var lumenTypeName: String {
        let raw = type ?? ""
        return raw.hasPrefix("/") ? String(raw.dropFirst()) : raw
    }

    /// 划线类批注（高亮 / 下划线 / 删除线）。这些能在页面上看见划线。
    var lumenIsMarkup: Bool {
        let name = lumenTypeName
        return name == "Highlight" || name == "Underline"
            || name == "StrikeOut" || name == "Squiggly"
    }

    /// 便签类批注（图标 + 点开看内容）。
    var lumenIsNote: Bool {
        let name = lumenTypeName
        return name == "Text" || name == "FreeText"
    }

    /// 链接、表单域这类「不是批注」的交互元素。右键菜单不该给它们弹「删除批注」。
    var lumenIsInteractive: Bool {
        let name = lumenTypeName
        return name == "Link" || name == "Widget" || name == "Popup"
    }
}

// MARK: - 支持批注右键菜单的 PDFView

/// 右键菜单里「我们这一侧」追加的项。
///
/// 做成枚举而不是直接拼 `NSMenuItem`：`menu(for:)` 没法自动化验证（这台机器没有
/// 辅助功能权限，合成不出真实右键），所以把「该出现哪些项、该叫什么文案」这段**判定**
/// 抽成纯函数（`PDFContextMenuPlanner.items`），用断言去验它；视图层只负责把判定结果
/// 翻译成 `NSMenuItem`，不做任何决策。
enum PDFContextMenuItem: Equatable {
    case deleteAnnotation
    case copyAnnotation
    case ocr(OCRMenuDescriptor)
}

/// OCR 菜单项此刻的状态。
enum OCRMenuDescriptor: Equatable {
    /// 空闲：还没识别过这一页
    case idle
    /// 正在识别：项要**禁用**（不能重复触发付费动作），文案给进度感
    case running
    /// 这一页已识别过：文案变成「重新识别」，仍然可点
    case alreadyDone

    var title: String {
        switch self {
        case .idle:        return "识别本页文字（OCR）"
        case .running:     return "识别中…"
        case .alreadyDone: return "重新识别本页文字"
        }
    }

    var isEnabled: Bool { self != .running }
}

/// 右键菜单项的**纯判定**（无副作用、无 AppKit 依赖），专为可断言而存在。
enum PDFContextMenuPlanner {

    /// 算出应当追加的菜单项。
    ///
    /// - Parameters:
    ///   - annotationHit: 右键是否命中了一条批注。
    ///   - annotationHasContents: 命中的批注是否有正文（没正文时不该给「拷贝批注内容」）。
    ///   - ocr: 当前页的 OCR 状态。
    /// - Returns: 追加项，顺序即菜单里的显示顺序；OCR 项**任何情况下都在末尾**。
    static func items(
        annotationHit: Bool,
        annotationHasContents: Bool,
        ocr: OCRMenuDescriptor
    ) -> [PDFContextMenuItem] {
        var result: [PDFContextMenuItem] = []
        if annotationHit {
            result.append(.deleteAnnotation)
            if annotationHasContents { result.append(.copyAnnotation) }
        }
        // OCR 入口无条件提供：即便这一页有文本层，「重新识别」也可能是用户想要的
        // （文本层残缺、复制出来乱码时用它补齐）。把它放在最末，与批注动作之间有分隔线。
        result.append(.ocr(ocr))
        return result
    }
}

/// 右键点在批注上时给出「删除 / 拷贝内容」，并且**任何情况下都追加 OCR 入口**。
///
/// 命中链路：窗口坐标 → 视图坐标 → 页面坐标 → `page.annotation(at:)`。
///
/// 与旧实现的关键差别：过去命中批注时**整份替换**系统菜单，把自带的「拷贝 / 查找 /
/// 缩放」全丢了；现在一律在 `super.menu(for:)` 的结果上**追加**，系统项照旧。
@MainActor
final class AnnotatedPDFView: PDFView {

    weak var controller: PDFController?

    /// 拖动划选的判定阈值（pt）：低于它一律按**单击**算。
    ///
    /// 取 4pt 而不是 0：真实拖拽的第一帧位移通常就超过几个像素，而「手抖的单击」
    /// 一般落在 2–3pt 内，4pt 能把两者干净地分开。这个门是「单击不弹、拖动才弹」的核心。
    static let dragThreshold: CGFloat = 4

    /// 最近一次鼠标手势是否属于拖动划选。
    ///
    /// 生命周期：`mouseDown` 复位为 false → `mouseDragged` / `mouseUp` 一旦位移越过阈值置 true。
    /// 于是它描述的始终是「产出当前这段选区的那次手势」是否为拖动，而不是历史里最近一次。
    /// `PDFController` 把它连同选区一起上报给 `ReaderBridge.selectionFromDrag`。
    private(set) var lastGestureWasDrag = false
    /// 按下点（视图坐标）。仅在手势进行中有值。
    private var gestureStart: NSPoint?

    /// 「识别本页文字（OCR）」被点中时的回调，由视图层接上 `Task { await runOCR() }`。
    ///
    /// 用闭包而不是让 `PDFController` 直接引用 `AppState`：保持
    /// PDFView → controller → 视图层 这条现有分层，controller 不做任何 UI 决策。
    var onOCRRequested: (() -> Void)?

    /// OCR 菜单项此刻的状态。由视图层维护（只有它知道 `isOCRRunning` 与当前页），
    /// `menu(for:)` 只读它。默认空闲。
    var ocrMenuDescriptor: OCRMenuDescriptor = .idle

    // MARK: 卡顿自检

    /// 卡顿自检：统计 PDFView 每步重排了几次。
    ///
    /// 它是「拖动分隔线 → 阅读区每帧重排 → PDFKit 重光栅化」这条链路的**第一环**：
    /// 如果一步拖动换来的是一次 `layout`，而其中又开着 `autoScales`，PDFKit 就会
    /// 为新的宽度重新绘制当前页——那正是手感抖动的来源。
    override func layout() {
        Jank.tick(.pdfViewLayout)
        super.layout()
    }

    /// 卡顿自检：统计 PDFView 每步重绘了几次。
    ///
    /// `layout` 只说明「框变了」，`draw` 才说明「真的把内容重画了一遍」。拖动分隔线时
    /// 若两者一起涨，就坐实了「每帧重排 + 每帧重光栅化」这条链路；若只有 `layout` 涨、
    /// `draw` 不涨，那重光栅化其实是 PDFKit 在别处懒做的，优化点也就不在这一层。
    override func draw(_ dirtyRect: NSRect) {
        Jank.tick(.pdfViewDraw)
        super.draw(dirtyRect)
    }

    // MARK: 鼠标手势 → 拖动 / 单击来源

    override func mouseDown(with event: NSEvent) {
        // 每次手势开始都复位：来源标记必须描述「产出当前选区的那一次手势」。
        gestureStart = convert(event.locationInWindow, from: nil)
        lastGestureWasDrag = false
        super.mouseDown(with: event)
    }

    override func mouseDragged(with event: NSEvent) {
        if !lastGestureWasDrag, let start = gestureStart {
            let point = convert(event.locationInWindow, from: nil)
            if hypot(point.x - start.x, point.y - start.y) >= Self.dragThreshold {
                lastGestureWasDrag = true
            }
        }
        super.mouseDragged(with: event)
    }

    override func mouseUp(with event: NSEvent) {
        // 松手时再按「按下点 → 松开点」的总位移判一次：这才是最可靠的判据，
        // 拖动过程中 `mouseDragged` 未必每帧都送达。
        if let start = gestureStart {
            let point = convert(event.locationInWindow, from: nil)
            if hypot(point.x - start.x, point.y - start.y) >= Self.dragThreshold {
                lastGestureWasDrag = true
            }
        }
        gestureStart = nil
        super.mouseUp(with: event)
        // 手势结束后补发一次选区：PDFKit 在拖动过程中已经发过 selectionChanged，
        // 那一轮的来源标记可能还没越过阈值；松手这一刻再发布，保证最终状态同步到桥。
        controller?.refreshSelectionFromGesture()
        if !lastGestureWasDrag {
            let location = convert(event.locationInWindow, from: nil)
            if let page = page(for: location, nearest: false) {
                let point = convert(location, to: page)
                if let annotation = page.annotations.reversed().first(where: {
                    PDFController.isListableAnnotation($0)
                        && PDFAnnotationGeometry.rectangles(of: $0).contains { $0.insetBy(dx: -2, dy: -2).contains(point) }
                }) { controller?.didTapAnnotation(annotation) }
            }
        }
    }

    // MARK: 右键菜单

    override func menu(for event: NSEvent) -> NSMenu? {
        // 一律从系统菜单出发再追加：命中批注时**不再替换**整份菜单，
        // 系统自带的「拷贝 / 查找 / 缩放」必须保留。
        let base = super.menu(for: event) ?? NSMenu()

        let location = convert(event.locationInWindow, from: nil)
        let hit = hitAnnotationInfo(at: location)
        let plan = PDFContextMenuPlanner.items(
            annotationHit: hit != nil,
            annotationHasContents: hit?.hasContents ?? false,
            ocr: ocrMenuDescriptor
        )
        guard !plan.isEmpty else { return base.items.isEmpty ? nil : base }

        if !base.items.isEmpty {
            base.addItem(.separator())
        }
        hitAnnotation = hit?.annotation

        for item in plan {
            switch item {
            case .deleteAnnotation:
                let menuItem = NSMenuItem(
                    title: "删除批注",
                    action: #selector(deleteHitAnnotation(_:)),
                    keyEquivalent: ""
                )
                menuItem.target = self
                base.addItem(menuItem)

            case .copyAnnotation:
                let menuItem = NSMenuItem(
                    title: "拷贝批注内容",
                    action: #selector(copyHitAnnotation(_:)),
                    keyEquivalent: ""
                )
                menuItem.target = self
                menuItem.representedObject = hit?.contents
                base.addItem(menuItem)

            case .ocr(let descriptor):
                // 识别中时 action 留空：`NSMenu` 的自动启用逻辑会把「没有 action 的项」
                // 显示为禁用，正好表达「进行中、别重复点」。不用去动
                // `autoenablesItems`，免得把系统菜单项的自启用行为一起关掉。
                let menuItem = NSMenuItem(
                    title: descriptor.title,
                    action: descriptor.isEnabled ? #selector(triggerOCR(_:)) : nil,
                    keyEquivalent: ""
                )
                menuItem.target = descriptor.isEnabled ? self : nil
                base.addItem(menuItem)
            }
        }
        return base
    }

    /// 右键命中批注的判定，返回批注本身与它是否有正文。
    private func hitAnnotationInfo(
        at location: NSPoint
    ) -> (annotation: PDFAnnotation, contents: String, hasContents: Bool)? {
        guard let page = self.page(for: location, nearest: true),
              let annotation = page.annotation(at: convert(location, to: page)),
              !annotation.lumenIsInteractive
        else { return nil }
        let contents = (annotation.contents ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return (annotation, contents, !contents.isEmpty)
    }

    private var hitAnnotation: PDFAnnotation?

    @objc private func deleteHitAnnotation(_ sender: Any?) {
        guard let hitAnnotation else { return }
        controller?.delete(annotation: hitAnnotation)
        self.hitAnnotation = nil
    }

    @objc private func copyHitAnnotation(_ sender: NSMenuItem) {
        guard let text = sender.representedObject as? String else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    @objc private func triggerOCR(_ sender: Any?) {
        onOCRRequested?()
    }
}
