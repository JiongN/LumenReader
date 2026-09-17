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
    private(set) var document: PDFDocument?
    private(set) var documentURL: URL?
    private(set) var pageCount = 0
    private var observers: [NSObjectProtocol] = []
    private var suppressCallbacks = false

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

    var onPositionChange: ((Int, Int) -> Void)?          // (pageIndex, pageCount)
    var onSelectionChange: ((ReaderSelection?) -> Void)?
    var onOutline: (([OutlineNode]) -> Void)?

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
        for observer in observers {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    // MARK: - 视图配置

    private func configureView() {
        view.displayMode = .singlePageContinuous
        view.displayDirection = .vertical
        view.displaysAsBook = false
        view.displaysPageBreaks = true
        view.pageBreakMargins = NSEdgeInsets(top: 14, left: 0, bottom: 14, right: 0)
        view.autoScales = true
        view.minScaleFactor = 0.2
        view.maxScaleFactor = 8.0
        // 打开时不要让 PDFKit 自作主张地缩小到「适宽」以外的倍率
        view.scaleFactor = 1.0
        view.interpolationQuality = .high
    }

    func applyAppearance(theme: ReadingTheme, brightness: Double) {
        let base = NSColor(hex: theme.isDark ? theme.surfaceHex : 0xE8E8EC)
        let clamped = min(max(brightness, 0.4), 1.0)
        view.backgroundColor = clamped >= 0.999
            ? base
            : (base.blended(withFraction: 1 - clamped, of: .black) ?? base)
    }

    func apply(flowMode: ReadingFlowMode) {
        view.displayMode = flowMode == .continuous ? .singlePageContinuous : .singlePage
    }

    private func installObservers() {
        let center = NotificationCenter.default

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
                self.objectWillChange.send()
            }
        })
    }

    // MARK: - 载入

    @discardableResult
    func load(url: URL) -> PDFDocument? {
        guard let doc = PDFDocument(url: url) else { return nil }
        suppressCallbacks = true
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

    private static let searchHighlightMarker = "LumenSearch"

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
        page.draw(with: .mediaBox, to: context)

        return context.makeImage()
    }

    // MARK: - 批注（写入原 PDF 文件）

    /// 我们创建的批注都带这个作者标记，与搜索高亮、外来批注（Preview / Acrobat 画的）区分。
    private static let annotationAuthor = "Lumen"

    /// 高亮当前选区。
    ///
    /// - Parameter note: 批注正文，可空——纯高亮没有正文。
    /// 跨页选区按行拆开画：`selectionsByLine()` 给出的每行 bounds 才是能贴住文字的矩形。
    /// - Returns: 是否至少画上了一处（扫描件上没有文本层时选区是空的）。
    @discardableResult
    func addHighlight(fromCurrentSelection note: String) -> Bool {
        guard let selection = view.currentSelection, document != nil else { return false }

        let stamp = Date()
        var added = 0
        for line in selection.selectionsByLine() {
            guard let page = line.pages.first else { continue }
            let bounds = line.bounds(for: page)
            guard bounds.width > 0.5, bounds.height > 0.5 else { continue }

            let annotation = PDFAnnotation(bounds: bounds, forType: .highlight, withProperties: nil)
            annotation.color = NSColor.systemYellow.withAlphaComponent(0.45)
            annotation.contents = note
            annotation.userName = Self.annotationAuthor
            annotation.modificationDate = stamp
            page.addAnnotation(annotation)
            added += 1
        }

        guard added > 0 else { return false }
        // 选区已被「用掉」：高亮之后还留着蓝色选区会让人以为没生效
        view.setCurrentSelection(nil, animate: false)
        return saveToFile()
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
            var added = 0
            for line in anchorSelection.selectionsByLine() {
                guard let linePage = line.pages.first else { continue }
                let bounds = line.bounds(for: linePage)
                guard bounds.width > 0.5, bounds.height > 0.5 else { continue }
                let annotation = PDFAnnotation(bounds: bounds, forType: .highlight, withProperties: nil)
                annotation.color = NSColor.systemTeal.withAlphaComponent(0.40)
                annotation.contents = body
                annotation.userName = Self.annotationAuthor
                annotation.modificationDate = stamp
                linePage.addAnnotation(annotation)
                added += 1
            }
            if added > 0 { return saveToFile() }
        }

        // 页面便签：放在右上角空白处，图标式批注不遮正文
        let pageBounds = page.bounds(for: .mediaBox)
        let iconBounds = CGRect(x: pageBounds.width - 44, y: pageBounds.height - 44, width: 24, height: 24)
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
    func annotationsList() async -> [AnnotationItem] {
        guard let doc = document else { return [] }
        var items: [AnnotationItem] = []

        for index in 0..<doc.pageCount {
            if index % 24 == 0 { await Task.yield() }
            guard let page = doc.page(at: index) else { continue }
            for annotation in page.annotations {
                // 搜索高亮不是批注，不能出现在清单里
                if annotation.userName == Self.searchHighlightMarker { continue }
                let isMarkup = annotation.lumenIsMarkup
                let isNote = annotation.lumenIsNote
                guard isMarkup || isNote else { continue }
                // 便签类批注里，从属的 Popup 不算独立条目——它是 Text 的影子
                if annotation.lumenTypeName == "Popup" { continue }

                // 划线原文从页面几何反查：批注 bounds 圈住的文字就是被划的那段
                var quote = ""
                if isMarkup, let selection = page.selection(for: annotation.bounds) {
                    quote = selection.string ?? ""
                }
                if quote.isEmpty, annotation.lumenTypeName == "FreeText" {
                    quote = annotation.contents ?? ""
                }

                let stamp = annotation.modificationDate
                let id: String
                if let stamp {
                    id = "t\(stamp.timeIntervalSinceReferenceDate)"
                } else {
                    // 外来批注可能没有修改时间：用位置当 id（同一处不会有两个批注）
                    let origin = annotation.bounds.origin
                    id = "p\(index)-\(Int(origin.x))x\(Int(origin.y))"
                }

                items.append(AnnotationItem(
                    id: id,
                    locator: .pdf(page: index, charOffset: 0),
                    quote: String(quote.prefix(400)),
                    note: annotation.contents ?? "",
                    hasHighlight: isMarkup,
                    createdAt: stamp ?? Date.distantPast
                ))
            }
        }
        return items.sorted { $0.createdAt > $1.createdAt }
    }

    /// 按 `annotationsList()` 给出的 id 删除批注。
    @discardableResult
    func deleteAnnotation(id: String) -> Bool {
        guard let doc = document else { return false }
        for index in 0..<doc.pageCount {
            guard let page = doc.page(at: index) else { continue }
            for annotation in page.annotations {
                if Self.matchesID(id, annotation: annotation, pageIndex: index) {
                    page.removeAnnotation(annotation)
                    return saveToFile()
                }
            }
        }
        return false
    }

    private static func matchesID(_ id: String, annotation: PDFAnnotation, pageIndex: Int) -> Bool {
        if let stamp = annotation.modificationDate, id == "t\(stamp.timeIntervalSinceReferenceDate)" {
            return true
        }
        let origin = annotation.bounds.origin
        return id == "p\(pageIndex)-\(Int(origin.x))x\(Int(origin.y))"
    }

    /// 右键菜单命中批注后回调：`AnnotatedPDFView` 负责找批注，这里负责动作。
    /// 返回的 Bool 表示是否已删除并写盘成功。
    @discardableResult
    func delete(annotation: PDFAnnotation) -> Bool {
        guard let doc = document else { return false }
        for index in 0..<doc.pageCount {
            guard let page = doc.page(at: index) else { continue }
            if page.annotations.contains(annotation) {
                page.removeAnnotation(annotation)
                return saveToFile()
            }
        }
        return false
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

        guard let data = doc.dataRepresentation() else {
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

/// 右键点在批注上时给出「删除 / 拷贝内容」菜单，其余情况回落系统默认菜单。
///
/// 命中链路：窗口坐标 → 视图坐标 → 页面坐标 → `page.annotation(at:)`。
@MainActor
final class AnnotatedPDFView: PDFView {

    weak var controller: PDFController?

    override func menu(for event: NSEvent) -> NSMenu? {
        let location = convert(event.locationInWindow, from: nil)
        guard let page = self.page(for: location, nearest: true),
              let annotation = page.annotation(at: convert(location, to: page)),
              !annotation.lumenIsInteractive
        else { return super.menu(for: event) }

        let menu = NSMenu()
        if let controller {
            let deleteItem = NSMenuItem(title: "删除批注", action: #selector(deleteHitAnnotation(_:)), keyEquivalent: "")
            deleteItem.target = self
            menu.addItem(deleteItem)
            _ = controller // 保持引用语义清晰：删除走 controller.saveToFile
        }
        let contents = (annotation.contents ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if !contents.isEmpty {
            let copyItem = NSMenuItem(title: "拷贝批注内容", action: #selector(copyHitAnnotation(_:)), keyEquivalent: "")
            copyItem.target = self
            copyItem.representedObject = contents
            menu.addItem(copyItem)
        }
        hitAnnotation = annotation
        return menu.items.isEmpty ? super.menu(for: event) : menu
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
}
