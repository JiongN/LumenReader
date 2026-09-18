import SwiftUI
import AppKit
import LumenKit
import PDFKit

/// 把 PDFKit 的视图塞进 SwiftUI。视图实例由 Controller 持有，
/// 这里只负责挂载，不做任何状态 diff，避免每帧重建 PDFView。
struct PDFKitRepresentable: NSViewRepresentable {

    let controller: PDFController

    func makeNSView(context: Context) -> PDFView {
        controller.view
    }

    func updateNSView(_ nsView: PDFView, context: Context) {
        // 状态同步全部走 Controller 的命令方法，不需要在这里处理。
        // 卡顿自检：记一次「这一步 SwiftUI 把 PDFKit 这个 representable 重算了一遍」
        // ——拖动分隔线时若它每步都跑，说明阅读区在跟着重排。
        Jank.tick(.updateNSView)
    }
}

/// PDF 阅读区。
struct PDFReaderView: View {

    let document: OpenDocument
    let theme: ReadingTheme
    let reader: ReaderSettings

    @EnvironmentObject private var state: AppState
    @EnvironmentObject private var bridge: ReaderBridge

    @StateObject private var controller = PDFController()
    @State private var store: ReadingStateStore?
    /// 识别结果弹层
    @State private var ocrSheet: OCRSheetPayload?
    @State private var isOCRRunning = false

    var body: some View {
        ZStack {
            theme.background

            PDFKitRepresentable(controller: controller)
                .opacity(bridge.isLoading ? 0 : 1)

            if bridge.isLoading {
                LoadingStateView(title: "正在打开 PDF", subtitle: document.displayTitle)
            }

            if let error = bridge.loadError {
                ErrorStateView(title: "无法打开", message: error) {
                    Task { await prepare() }
                }
            }
        }
        .overlay(alignment: .top) { scannedBanner }
        .sheet(item: $ocrSheet) { payload in
            OCRResultSheet(payload: payload)
                .environmentObject(bridge)
                .environmentObject(state)
        }
        .task(id: document.id) { await prepare() }
        .onChange(of: theme.id) { _, _ in applyAppearance() }
        .onChange(of: reader.pdfCanvasBrightness) { _, _ in applyAppearance() }
        .onChange(of: reader.flowMode) { _, newValue in controller.apply(flowMode: newValue) }
        .onChange(of: isOCRRunning) { _, running in
            bridge.ocrRunningPage = running ? controller.currentPageIndex : nil
            // OCR 状态一变，右键菜单的启用/禁用与文案也要跟着变（识别中 → 禁用）。
            syncOCRMenuDescriptor()
        }
        // 翻页后「本页是否已识别」会变，菜单文案（识别 / 重新识别）也要跟着刷新。
        .onChange(of: bridge.currentUnitIndex) { _, _ in syncOCRMenuDescriptor() }
        // 右键菜单点了「识别本页文字（OCR）」：controller 递增计数器，这里接住并跑识别。
        // 走计数器而不是「把闭包直接存到 view 上」是为了避开引用环：
        // controller → view → 闭包 → 视图 struct → StateObject → controller。
        .onReceive(controller.$ocrRequestTick.dropFirst()) { _ in
            // 与横幅按钮**同一个** runOCR，不复制一份逻辑（重复实现迟早只改一处）。
            Task { await runOCR() }
        }
        .onDisappear {
            store?.flush()
            state.recent.updateProgress(
                path: document.url.standardizedFileURL.path,
                progress: bridge.progress
            )
        }
    }

    /// 扫描件提示条。
    ///
    /// 不做自动识别：一本 300 页的扫描书全量 OCR 要几分钟，
    /// 用户可能只是想翻翻图。给一个入口，让他自己决定在哪一页花这几秒。
    @ViewBuilder
    private var scannedBanner: some View {
        if bridge.isScannedDocument && !bridge.isLoading && bridge.loadError == nil {
            HStack(spacing: DS.Space.s) {
                Image(systemName: "text.viewfinder")
                    .font(DS.Typo.ui(size: 12, weight: .semibold))
                    .foregroundStyle(DS.Palette.warning)

                VStack(alignment: .leading, spacing: 1) {
                    Text("这一本是扫描版（没有文本层）")
                        .font(DS.Typo.ui(size: 12, weight: .semibold))
                        .foregroundStyle(DS.Palette.textPrimary)
                    Text("识别本页文字后即可选中、复制，并交给 AI 提问与整书总结")
                        .font(DS.Typo.ui(size: 11))
                        .foregroundStyle(DS.Palette.textSecondary)
                }

                Spacer(minLength: DS.Space.s)

                if isOCRRunning {
                    HStack(spacing: 5) {
                        ProgressView().controlSize(.small)
                        Text("识别中…")
                            .font(DS.Typo.ui(size: 11.5))
                            .foregroundStyle(DS.Palette.textSecondary)
                    }
                } else {
                    Button("识别本页文字") { Task { await runOCR() } }
                        .controlSize(.small)
                        .buttonStyle(.borderedProminent)
                        .tint(DS.Palette.accent)
                }
            }
            .padding(.horizontal, DS.Space.m)
            .padding(.vertical, DS.Space.s)
            .background(
                RoundedRectangle(cornerRadius: DS.Radius.m, style: .continuous)
                    .fill(.thickMaterial)
                    .overlay(
                        RoundedRectangle(cornerRadius: DS.Radius.m, style: .continuous)
                            .strokeBorder(DS.Palette.warning.opacity(0.35), lineWidth: 0.5)
                    )
            )
            .shadow(color: .black.opacity(0.12), radius: 12, y: 4)
            .padding(DS.Space.m)
            .frame(maxWidth: 520)
            .transition(.move(edge: .top).combined(with: .opacity))
        }
    }

    // MARK: - OCR

    /// 把「当前页 + 是否识别中」换算成菜单文案，写进 PDFView。
    ///
    /// 右键菜单本身没法自动化验证（本机没有辅助功能权限，合成不出真实右键），
    /// 所以可断言的部分抽成了纯函数 `PDFContextMenuPlanner.items`；
    /// 这里只负责把纯函数的输入（当前页是否已识别、是否正在识别）喂给视图。
    private func syncOCRMenuDescriptor() {
        controller.view.ocrMenuDescriptor = controller.ocrMenuDescriptor(isRunning: isOCRRunning)
    }

    /// 识别当前页。识别结果同时进缓存——AI 上下文、整书总结都会从这里取。
    private func runOCR() async {
        guard !isOCRRunning else { return }
        let page = controller.currentPageIndex
        isOCRRunning = true
        defer { isOCRRunning = false }

        do {
            let result = try await controller.recognize(page: page)
            NSLog("[Lumen] OCR 第 \(page + 1) 页完成：\(result.lines.count) 行，平均置信度 \(Int(result.averageConfidence * 100))%")
            if result.isEmpty {
                state.presentAlert(
                    title: "没有识别到文字",
                    message: "第 \(page + 1) 页没有识别出任何文本。这一页可能是纯插图，或原图分辨率过低。"
                )
                return
            }
            ocrSheet = OCRSheetPayload(pageIndex: page, result: result)
        } catch {
            state.presentAlert(
                title: "识别失败",
                message: (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            )
        }
    }

    private func applyAppearance() {
        controller.applyAppearance(theme: theme, brightness: reader.pdfCanvasBrightness)
    }

    // MARK: - 载入

    private func prepare() async {
        bridge.reset()
        applyAppearance()
        controller.apply(flowMode: reader.flowMode)

        let store = ReadingStateStore(documentPath: document.url.standardizedFileURL.path)
        self.store = store
        wireCallbacks(store: store)

        guard let pdf = controller.load(url: document.url) else {
            bridge.isLoading = false
            bridge.loadError = "PDFKit 无法解析该文件。可能是文件损坏、权限不足，或它其实是受密码保护的文档。"
            document.loadError = bridge.loadError
            return
        }

        document.title = Self.title(of: pdf, fallback: document.url)
        document.detail = "\(pdf.pageCount) 页"
        bridge.unitCount = pdf.pageCount
        bridge.metadata = Self.metadata(of: pdf)
        bridge.isScannedDocument = controller.detectScannedDocument()
        wireDocumentWideProviders()

        // 恢复上次位置
        if let locator = DocumentLocator.parse(storageKey: store.state.locationKey) {
            controller.go(to: locator)
        }

        bridge.currentUnitIndex = controller.currentPageIndex
        bridge.progress = Double(controller.currentPageIndex + 1) / Double(max(pdf.pageCount, 1))
        bridge.isLoading = false

        // 自检通道：无 UI 自动化权限的环境下验证扫描件识别链路
        if LaunchOptions.autoOCR {
            await runOCR()
        }

        // 自检通道：批注写盘 / 搜索高亮（都在 /tmp 副本上做，不碰用户文件）
        if LaunchOptions.annotateReport {
            await AnnotationAudit.runDocumentAudit(sourceURL: document.url)
        }
        if LaunchOptions.searchReport {
            await AnnotationAudit.runSearchAudit(sourceURL: document.url)
        }
        // PDF 浏览性能自检：连翻若干页、报耗时分布与内存增量（`--perf-report 1`）。
        if LaunchOptions.perfReport {
            await PDFPerfAudit.run(controller: controller)
        }
    }

    private static func metadata(of pdf: PDFDocument) -> DocumentMetadata {
        var meta = DocumentMetadata()
        if let attributes = pdf.documentAttributes {
            meta.title = attributes[PDFDocumentAttribute.titleAttribute] as? String ?? ""
            meta.author = attributes[PDFDocumentAttribute.authorAttribute] as? String ?? ""
            meta.subject = attributes[PDFDocumentAttribute.subjectAttribute] as? String ?? ""
        }
        meta.unitCount = pdf.pageCount
        return meta
    }

    /// 接通「整本书级别」的两条数据通道：检索（提问时先找到相关段落）
    /// 与切片（整本书总结的 map 阶段）。PDF 没有章的概念，按固定页数分块。
    private func wireDocumentWideProviders() {
        let bridge = self.bridge

        // 卡顿自检的滚动驱动需要拿到真正被滚动的 PDFView。
        if LaunchOptions.jankReport {
            bridge.jankScrollSurface = { [weak controller] in controller?.view }
        }

        bridge.retrieveProvider = { [weak controller] query in
            guard let controller else { return [] }
            var seenPages = Set<Int>()
            var slices: [(label: String, locator: DocumentLocator, text: String)] = []

            for hit in controller.search(query, limit: 60) {
                let page = hit.locator.pageIndex
                guard page >= 0, !seenPages.contains(page) else { continue }
                seenPages.insert(page)

                let text = controller.usableText(of: page)
                guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }

                slices.append((
                    label: "第 \(page + 1) 页",
                    locator: .pdf(page: page, charOffset: 0),
                    text: PromptLibrary.truncate(text, limit: 1500)
                ))
                if slices.count >= 8 { break }
            }
            return slices
        }

        bridge.slicesProvider = { [weak controller] in
            guard let controller, controller.pageCount > 0 else { return [] }
            let chunkSize = max(1, Int(ceil(Double(controller.pageCount) / 20.0)))
            var slices: [(label: String, text: String)] = []
            var start = 0

            while start < controller.pageCount {
                let end = min(controller.pageCount - 1, start + chunkSize - 1)
                let text = (start...end)
                    .map { controller.usableText(of: $0) }
                    .filter { !$0.isEmpty }
                    .joined(separator: "\n")
                if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    let label = start == end ? "第 \(start + 1) 页" : "第 \(start + 1)–\(end + 1) 页"
                    slices.append((label: label, text: text))
                }
                start = end + 1
            }
            return slices
        }
    }

    private static func title(of pdf: PDFDocument, fallback url: URL) -> String {
        if let attributes = pdf.documentAttributes,
           let title = attributes[PDFDocumentAttribute.titleAttribute] as? String,
           !title.trimmingCharacters(in: .whitespaces).isEmpty {
            return title
        }
        return url.deletingPathExtension().lastPathComponent
    }

    private func wireCallbacks(store: ReadingStateStore) {
        let bridge = self.bridge
        let state = self.state
        let documentPath = document.url.standardizedFileURL.path
        let progressThrottle = ProgressThrottle()

        controller.onPositionChange = { [weak controller] page, count in
            guard count > 0 else { return }
            // 卡顿自检：记一次位置回调（滚动时若它每步都发，说明滚动在推 SwiftUI 状态）。
            Jank.tick(.positionCallback)
            let progress = Double(page + 1) / Double(count)

            bridge.positionLabel = "第 \(page + 1) / \(count) 页"
            bridge.progress = progress
            bridge.currentUnitIndex = page

            store.update {
                $0.locationKey = DocumentLocator.pdf(page: page, charOffset: 0).storageKey
                $0.progress = progress
            }

            // 每前进 5% 才写一次「最近打开」，避免翻页时疯狂写盘
            if progressThrottle.shouldReport(progress) {
                state.recent.updateProgress(path: documentPath, progress: progress)
            }
            // 让依赖 scaleFactor 的控件（缩放百分比）刷新
            controller?.objectWillChange.send()
        }

        controller.onSelectionChange = { [weak controller] (selection: ReaderSelection?) in
            // 必须包 `withAnimation`：划词条自己写了 transition（淡入 + 上浮 10pt），
            // 但 transition 只在「状态变化处于动画事务内」时才跑。这里裸赋值的话
            // 那条 transition 等于白写——拖完鼠标，条子是「啪」地闪出来的。
            // 用 reveal（easeOut 0.26）而不是面板那套弹簧：划完词要的是「顺手浮起」，
            // 弹一下反而显得迟钝。
            withAnimation(DS.Motion.reveal) {
                bridge.selection = selection
                // 拖动 / 单击来源同步：单击也会产生 1 字符选区，浮条只在
                // `isUsable && selectionFromDrag` 时出现（见 `SelectionActionBarLayer`）。
                // 选区为空时来源也一并复位，避免残留的 true 让下一次单击错误地弹条。
                bridge.selectionFromDrag = selection == nil
                    ? false
                    : (controller?.isSelectionFromDrag ?? false)
            }
        }

        // 右键菜单里的「识别本页文字（OCR）」：菜单项动作只递增计数器，真正的识别
        // 由视图层的 `onReceive(controller.$ocrRequestTick)` 在当前视图上跑。
        controller.view.onOCRRequested = { [weak controller] in
            controller?.ocrRequestTick += 1
        }
        syncOCRMenuDescriptor()

        controller.onOutline = { (nodes: [OutlineNode]) in
            bridge.outline = nodes
        }

        bridge.goTo = { [weak controller] locator in controller?.go(to: locator) }
        bridge.goToNextUnit = { [weak controller] in controller?.goToNextPage() }
        bridge.goToPreviousUnit = { [weak controller] in controller?.goToPreviousPage() }
        bridge.zoomIn = { [weak controller] in controller?.stepZoom(by: 1.2) }
        bridge.zoomOut = { [weak controller] in controller?.stepZoom(by: 1 / 1.2) }
        bridge.zoomToFit = { [weak controller] in controller?.zoomToFitWidth() }

        bridge.performSearch = { [weak controller] query in
            Task { @MainActor in
                bridge.isSearching = true
                // 让进度指示先渲染出来，再去跑同步的查找
                await Task.yield()
                bridge.searchResults = controller?.search(query) ?? []
                bridge.isSearching = false
            }
        }
        bridge.clearSearch = { [weak controller] in
            controller?.clearSearchHighlights()
            bridge.searchResults = []
            bridge.searchQuery = ""
        }
        // 点搜索结果：定位到具体命中并选中，而不是只翻到那一页
        bridge.revealSearchHit = { [weak controller] index in
            controller?.revealSearchHit(index)
        }

        // MARK: 批注（写回原 PDF 文件）

        // 只报告失败：成功那句由具体动作来说（「已写入原 PDF 文件」比
        // 「已保存到原文件」更能说明改的是哪本书），两条 toast 叠着看只会打架。
        controller.onFileSaved = { [weak state] ok, message in
            if !ok { state?.showToast(message, isError: true) }
        }
        bridge.addHighlight = { [weak controller] note in
            guard let controller else { return }
            if !controller.addHighlight(fromCurrentSelection: note) {
                state.showToast("高亮失败：选区已失效或该页没有文本层", isError: true)
            } else {
                // 让侧栏批注列表（若开着）立刻刷新
                bridge.annotationRevision += 1
            }
        }
        bridge.addPageNote = { [weak controller] pageIndex, anchorText, body in
            guard let controller else { return }
            if !controller.addNote(pageIndex: pageIndex, anchorText: anchorText, body: body) {
                state.showToast("添加批注失败", isError: true)
            } else {
                bridge.annotationRevision += 1
                state.showToast("已写入原 PDF 文件")
            }
        }
        bridge.annotationsProvider = { [weak controller] in
            await controller?.annotationsList() ?? []
        }
        bridge.deleteAnnotation = { [weak controller] id in
            let ok = controller?.deleteAnnotation(id: id) ?? false
            if ok { bridge.annotationRevision += 1 }
            return ok
        }
        // 侧栏点一条批注 → 正文翻到那一处（滚到位置 + 划线类短暂选中原文）
        bridge.revealAnnotation = { [weak controller] id in
            _ = controller?.revealAnnotation(id: id)
        }
        // 批注面板里编辑正文 → 改批注 contents 并写回原文件
        bridge.updateAnnotationNote = { [weak controller] id, note in
            let ok = controller?.updateNote(id: id, body: note) ?? false
            if ok { bridge.annotationRevision += 1 }
            return ok
        }
        // 批注面板「新建」→ 当前页一条空白便签，返回条目让面板直接进入编辑
        bridge.addNoteAtCurrentPosition = { [weak controller] in
            controller?.addPageNoteAtCurrentPosition()
        }
        // 正文里点批注（PDFViewAnnotationHit）→ 侧栏聚焦对应行。
        // 若批注页签不在前台，顺势切过去——用户点的是批注，就该看到批注清单。
        controller.onAnnotationTapped = { [weak bridge, weak state] id in
            bridge?.focusedAnnotationID = id
            state?.revealSidebar(tab: .annotations)
        }

        bridge.currentContextProvider = { [weak controller] in
            let page = controller?.currentPageIndex ?? 0
            // 扫描件走 OCR 缓存：没有它，「解释这一节」拿到的是空字符串，
            // 模型只会回一句「请提供需要解释的内容」，用户完全不知道为什么。
            let text = controller?.text(around: page, radius: 1) ?? ""
            return (text, .pdf(page: page, charOffset: 0))
        }

        bridge.ocrTextProvider = { [weak controller] page in
            controller?.cachedOCRText(page)
        }

        bridge.extractFullText = { [weak controller] allowOCR, progress in
            guard let controller else { return DocumentTextReport() }
            return await controller.extractFullText(allowOCR: allowOCR, progress: progress)
        }

        // 智能目录：只要每页**开头**那一小截。取满了再送过去是浪费——
        // 章节标题几乎都在页首，而全文喂进去既慢又贵，还会让模型在细节里迷路。
        bridge.unitSnippetProvider = { [weak controller] in
            guard let controller, controller.pageCount > 0 else { return [] }
            var snippets: [(index: Int, text: String)] = []
            snippets.reserveCapacity(controller.pageCount)

            for index in 0..<controller.pageCount {
                // 每 24 页让一次主线程。`page.string` 是同步的，一本五百页的书
                // 一口气取完会把界面钉死好几秒——这是用户手动触发的动作，
                // 也不该表现为「点了没反应」。
                if index % 24 == 0 { await Task.yield() }

                let text = controller.usableText(of: index)
                guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
                snippets.append((index: index, text: text))
            }
            return snippets
        }

        bridge.sectionTextProvider = { [weak controller] start, end in
            guard let controller, controller.pageCount > 0 else { return "" }
            let lower = max(0, min(start, end))
            let upper = min(controller.pageCount - 1, max(start, end))
            guard lower <= upper else { return "" }

            var pieces: [String] = []
            var budget = 12_000

            for page in lower...upper where budget > 0 {
                if page % 24 == 0 { await Task.yield() }
                let text = controller.usableText(of: page)
                guard !text.isEmpty else { continue }
                pieces.append(text)
                // 预算按字符算、超了就停在整页边界上：截半页会把一页中间的
                // 半句话喂给模型，摘要很容易顺着半句话编下去。
                budget -= text.count
            }
            return pieces.joined(separator: "\n")
        }

        bridge.requestOCR = { [weak controller, weak state] page in
            guard let state else { return }
            Task { @MainActor in
                guard let controller else { return }
                do {
                    let result = try await controller.recognize(page: page)
                    if result.isEmpty {
                        state.presentAlert(title: "没有识别到文字",
                                           message: "第 \(page + 1) 页没有识别出任何文本。")
                    } else {
                        state.presentAlert(
                            title: "已识别第 \(page + 1) 页",
                            message: String(result.text.prefix(600))
                        )
                    }
                } catch {
                    state.presentAlert(
                        title: "识别失败",
                        message: (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                    )
                }
            }
        }

        // 缩略图侧栏的数据源。这里只暴露一个取图闭包，缓存与懒加载策略留在
        // ThumbnailPane，因为它才是实际可见性的知情者。
        bridge.thumbnailProvider = { [weak controller] index, size in
            controller?.document?.page(at: index)?.thumbnail(of: size, for: .mediaBox)
        }
    }
}

/// 进度写盘节流：只在跨过 5% 台阶时上报。
final class ProgressThrottle {
    private var last: Double = -1

    func shouldReport(_ progress: Double) -> Bool {
        guard last < 0 || progress - last >= 0.05 else { return false }
        last = progress
        return true
    }
}

// MARK: - OCR 结果弹层

struct OCRSheetPayload: Identifiable {
    let pageIndex: Int
    let result: OCRPageResult

    var id: Int { pageIndex }
}

/// 识别结果确认层。
///
/// 存在的意义是「让用户核对」：OCR 一定会有错字，直接默默塞进 AI 上下文，
/// 用户会以为是 AI 读错了书。给一个能看见、能复制、能改的中间态。
struct OCRResultSheet: View {

    let payload: OCRSheetPayload

    @EnvironmentObject private var bridge: ReaderBridge
    @EnvironmentObject private var state: AppState
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            transcript
            Divider()
            footer
        }
        .frame(width: 620, height: 480)
        .background(DS.Palette.surfaceRaised)
    }

    private var header: some View {
        HStack(spacing: DS.Space.s) {
            Image(systemName: "text.viewfinder")
                .font(DS.Typo.ui(size: 13, weight: .semibold))
                .foregroundStyle(DS.Palette.accent)

            VStack(alignment: .leading, spacing: 1) {
                Text("第 \(payload.pageIndex + 1) 页 · 识别结果")
                    .font(DS.Typo.headline)
                    .foregroundStyle(DS.Palette.textPrimary)
                Text(confidenceSummary)
                    .font(DS.Typo.ui(size: 11))
                    .foregroundStyle(DS.Palette.textTertiary)
            }

            Spacer(minLength: 0)

            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(DS.Typo.ui(size: 15))
                    .foregroundStyle(DS.Palette.textTertiary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, DS.Space.l)
        .frame(height: DS.Size.toolbarHeight)
    }

    private var confidenceSummary: String {
        let average = Int(payload.result.averageConfidence * 100)
        let low = payload.result.lowConfidenceLineCount
        var text = "\(payload.result.lines.count) 行 · 平均置信度 \(average)%"
        if low > 0 {
            text += " · 其中 \(low) 行置信度偏低，建议核对"
        }
        return text
    }

    private var transcript: some View {
        ScrollView {
            Text(payload.result.text)
                .font(DS.Typo.ui(size: 13))
                .foregroundStyle(DS.Palette.textPrimary)
                .lineSpacing(5)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(DS.Space.l)
        }
        .frame(maxHeight: .infinity)
    }

    private var footer: some View {
        HStack(spacing: DS.Space.s) {
            Button {
                copyToPasteboard()
            } label: {
                Label("复制全文", systemImage: "doc.on.doc")
            }
            .controlSize(.small)

            Spacer(minLength: 0)

            Button {
                remember()
            } label: {
                Label("记入记忆", systemImage: "bookmark")
            }
            .controlSize(.small)

            Button {
                dismiss()
            } label: {
                Text("完成")
                    .frame(minWidth: 52)
            }
            .controlSize(.small)
            .buttonStyle(.borderedProminent)
            .tint(DS.Palette.accent)
        }
        .padding(.horizontal, DS.Space.l)
        .padding(.vertical, DS.Space.m)
    }

    // MARK: 动作

    private func copyToPasteboard() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(payload.result.text, forType: .string)
    }

    private func remember() {
        state.remember(
            text: payload.result.text,
            source: state.currentDocumentTitle,
            locatorLabel: "第 \(payload.pageIndex + 1) 页"
        )
    }
}

// MARK: - 通用状态视图

struct LoadingStateView: View {
    let title: String
    var subtitle: String = ""

    var body: some View {
        VStack(spacing: DS.Space.m) {
            ProgressView()
                .controlSize(.large)
            Text(title)
                .font(DS.Typo.headline)
                .foregroundStyle(DS.Palette.textPrimary)
            if !subtitle.isEmpty {
                Text(subtitle)
                    .font(DS.Typo.callout)
                    .foregroundStyle(DS.Palette.textTertiary)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 320)
            }
        }
        .padding(DS.Space.xl)
    }
}

struct ErrorStateView: View {
    let title: String
    let message: String
    var retry: (() -> Void)?

    var body: some View {
        VStack(spacing: DS.Space.m) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(DS.Typo.ui(size: 28))
                .foregroundStyle(DS.Palette.warning)
            Text(title)
                .font(DS.Typo.headline)
                .foregroundStyle(DS.Palette.textPrimary)
            Text(message)
                .font(DS.Typo.callout)
                .foregroundStyle(DS.Palette.textSecondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 380)
                .fixedSize(horizontal: false, vertical: true)
            if let retry {
                Button("重试", action: retry)
                    .controlSize(.regular)
            }
        }
        .padding(DS.Space.xl)
        .background(
            RoundedRectangle(cornerRadius: DS.Radius.l, style: .continuous)
                .fill(DS.Palette.surfaceRaised)
        )
        .overlay(
            RoundedRectangle(cornerRadius: DS.Radius.l, style: .continuous)
                .strokeBorder(DS.Palette.separator, lineWidth: 0.5)
        )
        .shadow(color: .black.opacity(0.12), radius: 18, y: 8)
    }
}
