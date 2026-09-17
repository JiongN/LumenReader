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

    let view = PDFView()
    private(set) var document: PDFDocument?
    private(set) var pageCount = 0
    private var observers: [NSObjectProtocol] = []
    private var suppressCallbacks = false

    /// OCR 结果缓存。按页存，识别过一次就不再重复花钱——
    /// 同一页在 AI 上下文、复制、整书总结这几条路径上会被反复取用。
    private var ocrCache: [Int: OCRPageResult] = [:]

    var onPositionChange: ((Int, Int) -> Void)?          // (pageIndex, pageCount)
    var onSelectionChange: ((ReaderSelection?) -> Void)?
    var onOutline: (([OutlineNode]) -> Void)?

    override init() {
        super.init()
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
        pageCount = 0
        // 换文档必须清缓存：页号在新书里指向完全不同的内容
        ocrCache.removeAll()
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
    func search(_ query: String, limit: Int = 200) -> [SearchHit] {
        guard let doc = document, !query.trimmingCharacters(in: .whitespaces).isEmpty else { return [] }
        let selections = doc.findString(query, withOptions: [.caseInsensitive])
        return selections.prefix(limit).compactMap { selection in
            guard let page = selection.pages.first else { return nil }
            let pageIndex = doc.index(for: page)
            let snippet = Self.snippet(selection: selection, pageText: page.string ?? "")
            let pageText = page.string ?? ""
            let offset: Int
            if let text = selection.string, let range = pageText.range(of: text) {
                offset = range.lowerBound.utf16Offset(in: pageText)
            } else {
                offset = 0
            }
            return SearchHit(
                snippet: snippet,
                locator: .pdf(page: pageIndex, charOffset: offset),
                range: offset..<(offset + (selection.string?.count ?? 0))
            )
        }
    }

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
}

private extension CGRect {
    var center: CGPoint { CGPoint(x: midX, y: midY) }
}
