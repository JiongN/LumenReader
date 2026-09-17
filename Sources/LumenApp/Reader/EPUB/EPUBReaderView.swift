import SwiftUI
import WebKit
import LumenKit

/// WKWebView 挂载点。视图实例由 Controller 持有，这里不做任何重建。
struct WebViewRepresentable: NSViewRepresentable {

    let webView: WKWebView

    func makeNSView(context: Context) -> WKWebView { webView }
    func updateNSView(_ nsView: WKWebView, context: Context) {}
}

/// EPUB 阅读区。
struct EPUBReaderView: View {

    let document: OpenDocument
    let theme: ReadingTheme
    let reader: ReaderSettings

    @EnvironmentObject private var state: AppState
    @EnvironmentObject private var bridge: ReaderBridge

    @StateObject private var controller: EPUBController
    @State private var store: ReadingStateStore?
    @State private var source: EPUBDocumentSource?

    init(document: OpenDocument, theme: ReadingTheme, reader: ReaderSettings) {
        self.document = document
        self.theme = theme
        self.reader = reader
        _controller = StateObject(wrappedValue: EPUBController(theme: theme, reader: reader))
    }

    var body: some View {
        ZStack {
            theme.background

            WebViewRepresentable(webView: controller.webView)
                .opacity(bridge.isLoading ? 0 : 1)

            if bridge.isLoading {
                LoadingStateView(title: "正在打开 EPUB", subtitle: document.displayTitle)
            }

            if let error = bridge.loadError {
                ErrorStateView(title: "无法打开", message: error) {
                    Task { await prepare() }
                }
            }
        }
        .task(id: document.id) { await prepare() }
        // **只留一条。** `ReaderSettings` 里就包含 `themeID`，所以换主题必然也表现为
        // `reader` 变化；原来另有一条 `.onChange(of: theme.id)` 也调 `applyTheme`，
        // 于是切一次主题要跑两遍 `evaluateJavaScript` 注入 CSS 变量——
        // 这正是「主题切换发滞」的一半来源。
        .onChange(of: reader) { _, newValue in
            controller.applyTheme(newValue.theme, reader: newValue)
        }
        .onDisappear {
            store?.flush()
            state.recent.updateProgress(
                path: document.url.standardizedFileURL.path,
                progress: bridge.progress
            )
        }
    }

    // MARK: - 载入

    private func prepare() async {
        bridge.reset()

        do {
            let source = try await EPUBDocumentSource.open(url: document.url)
            self.source = source

            document.title = source.metadata.title.isEmpty
                ? document.url.deletingPathExtension().lastPathComponent
                : source.metadata.title
            document.detail = "\(source.chapters.count) 章"

            bridge.outline = source.outline
            bridge.unitCount = source.chapters.count
            bridge.metadata = source.metadata
            wireDocumentWideProviders(source: source)

            let store = ReadingStateStore(documentPath: document.url.standardizedFileURL.path)
            self.store = store
            wireCallbacks(store: store, source: source)

            // 恢复上次读到的地方
            var startChapter = 0
            var startAnchor = ""
            if let locator = DocumentLocator.parse(storageKey: store.state.locationKey) {
                startChapter = min(max(locator.chapterIndex, 0), source.chapters.count - 1)
                if case .epub(_, let anchor, _) = locator { startAnchor = anchor }
            }

            bridge.currentUnitIndex = startChapter
            controller.load(source: source, startAt: startChapter, anchor: startAnchor)
            // isLoading 交给首次 progress 回调关闭——WebKit 首帧渲染完成才算真的可读
        } catch {
            bridge.isLoading = false
            let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            bridge.loadError = message
            document.loadError = message
        }
    }

    private func wireCallbacks(store: ReadingStateStore, source: EPUBDocumentSource) {
        let bridge = self.bridge
        let state = self.state
        let documentPath = document.url.standardizedFileURL.path
        let progressThrottle = ProgressThrottle()
        let autoAdvanceGate = AutoAdvanceGate()

        controller.onProgress = { [weak controller] chapter, count, chapterProgress, atEnd in
            guard count > 0 else { return }

            bridge.isLoading = false
            bridge.currentUnitIndex = chapter
            bridge.unitCount = count
            bridge.positionLabel = "第 \(chapter + 1) / \(count) 章"

            let overall = (Double(chapter) + chapterProgress) / Double(count)
            bridge.progress = overall

            store.update {
                $0.locationKey = DocumentLocator.epub(chapterIndex: chapter, anchor: "", charOffset: 0).storageKey
                $0.progress = overall
            }

            if progressThrottle.shouldReport(overall) {
                state.recent.updateProgress(path: documentPath, progress: overall)
            }

            // 滚到章末停一下再自动进入下一章。
            // 中间加延迟是为了让「滚到底只是想看看最后一段」的人有时间回滚，不至于被硬拽走。
            if !atEnd {
                autoAdvanceGate.rearm()
            } else if autoAdvanceGate.shouldAdvance(),
                      state.settingsStore.reader.autoAdvanceOnScrollEnd,
                      chapter + 1 < count {
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 650_000_000)
                    controller?.goToNextChapter()
                }
            }
        }

        controller.onSelection = { (selection: ReaderSelection?) in
            // 与 PDF 侧同理：划词条自带 transition，但要有动画事务才会跑。
            withAnimation(DS.Motion.reveal) {
                bridge.selection = selection
            }
        }

        // 搜索走解包后的纯文本，而不是让 WebKit 去 `window.find`：
        // 前者能跨章节一次搜完，并且在后台线程跑得动。
        bridge.performSearch = { query in
            Task { @MainActor in
                bridge.isSearching = true
                await Task.yield()
                let hits = await Task.detached(priority: .userInitiated) {
                    source.search(query, limit: 200)
                }.value
                bridge.searchResults = hits
                bridge.isSearching = false
            }
        }
        bridge.clearSearch = {
            bridge.searchResults = []
            bridge.searchQuery = ""
        }

        bridge.goTo = { [weak controller] locator in controller?.go(to: locator) }
        bridge.goToNextUnit = { [weak controller] in controller?.goToNextChapter() }
        bridge.goToPreviousUnit = { [weak controller] in controller?.goToPreviousChapter() }

        wireAnnotations(controller: controller)

        bridge.revealSearchHit = { [weak controller] index in
            // EPUB 的搜索命中定位就是跳到那一章：章内高亮要等 DOM 就绪，
            // 而 `go(to:)` 是异步导航，这里没有可靠的「加载完成」回执，
            // 硬塞一个延迟去画高亮只会时灵时不灵。跳到位、由读者自己找那一段。
            guard index >= 0, index < bridge.searchResults.count else { return }
            controller?.go(to: bridge.searchResults[index].locator)
        }

        bridge.currentContextProvider = { [weak controller] in
            guard controller != nil else { return ("", .epub(chapterIndex: 0, anchor: "", charOffset: 0)) }
            let chapter = bridge.currentUnitIndex
            let text = source.text(
                around: .epub(chapterIndex: chapter, anchor: "", charOffset: 0),
                radius: 0
            )
            return (text, .epub(chapterIndex: chapter, anchor: "", charOffset: 0))
        }
    }
    // MARK: - 批注

    /// EPUB 批注接的是应用数据目录，不是文件——EPUB 是一份压缩包，
    /// 往里写批注要么改坏原文件、要么读者换阅读器就看不见，都不如本机存一份如实。
    /// 代价要说清楚：换设备/换阅读器看不到这些批注（界面上的说明也这么写）。
    private func wireAnnotations(controller: EPUBController) {
        let store = AnnotationStore(documentPath: document.url.standardizedFileURL.path)

        // 章节加载完成时按章取批注，交给 JS 画高亮
        controller.highlightsProvider = { chapter in
            store.items
                .filter { $0.locator.chapterIndex == chapter && $0.hasHighlight && !$0.quote.isEmpty }
                .map { (id: $0.id, quote: $0.quote) }
        }

        bridge.addHighlight = { note in
            guard let selection = bridge.selection, selection.isUsable else {
                state.showToast("先在正文里划选一段文字", isError: true)
                return
            }
            let item = AnnotationItem(
                id: UUID().uuidString,
                locator: selection.locator,
                quote: selection.text,
                note: note,
                hasHighlight: true,
                createdAt: Date()
            )
            guard store.add(item) else {
                state.showToast("这一处已经标注过了")
                return
            }
            controller.applyHighlights()
            bridge.annotationRevision += 1
            state.showToast(note.isEmpty ? "已高亮" : "已加入批注")
        }

        bridge.addPageNote = { chapterIndex, anchorText, body in
            let locator = DocumentLocator.epub(chapterIndex: chapterIndex, anchor: "", charOffset: 0)
            let trimmedAnchor = anchorText.trimmingCharacters(in: .whitespacesAndNewlines)
            let item = AnnotationItem(
                id: UUID().uuidString,
                locator: locator,
                quote: trimmedAnchor,
                note: body,
                hasHighlight: !trimmedAnchor.isEmpty,
                createdAt: Date()
            )
            guard store.add(item) else {
                state.showToast("这一章已有相同的批注")
                return
            }
            if chapterIndex == controller.currentChapter { controller.applyHighlights() }
            bridge.annotationRevision += 1
            state.showToast("已加入第 \(chapterIndex + 1) 章的批注")
        }

        bridge.annotationsProvider = { store.items }

        bridge.deleteAnnotation = { id in
            guard store.remove(id: id) else { return false }
            controller.removeHighlight(id: id)
            bridge.annotationRevision += 1
            return true
        }
    }

    /// 接通「整本书级别」的两条数据通道：检索与切片。
    /// EPUB 天然以章为单位，直接复用章节边界，不需要像 PDF 那样人为分块。
    private func wireDocumentWideProviders(source: EPUBDocumentSource) {
        let bridge = self.bridge

        bridge.retrieveProvider = { query in
            var seenChapters = Set<Int>()
            var slices: [(label: String, locator: DocumentLocator, text: String)] = []

            for hit in source.search(query, limit: 60) {
                let chapter = hit.locator.chapterIndex
                guard chapter >= 0, chapter < source.chapters.count, !seenChapters.contains(chapter) else { continue }
                seenChapters.insert(chapter)

                let locator = DocumentLocator.epub(chapterIndex: chapter, anchor: "", charOffset: 0)
                let text = source.text(around: locator, radius: 0)
                guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }

                slices.append((
                    label: source.chapters[chapter].displayTitle,
                    locator: locator,
                    text: PromptLibrary.truncate(text, limit: 1500)
                ))
                if slices.count >= 8 { break }
            }
            return slices
        }

        bridge.slicesProvider = {
            source.chapters.map { chapter in
                (
                    label: chapter.displayTitle,
                    text: source.text(
                        around: .epub(chapterIndex: chapter.index, anchor: "", charOffset: 0),
                        radius: 0
                    )
                )
            }
        }

        bridge.unitSnippetProvider = {
            source.chapters.map { chapter in
                (index: chapter.index, text: source.text(
                    around: .epub(chapterIndex: chapter.index, anchor: "", charOffset: 0),
                    radius: 0
                ))
            }
        }

        bridge.sectionTextProvider = { start, end in
            let chapters = source.chapters
            guard !chapters.isEmpty else { return "" }
            let lower = max(0, min(start, end))
            let upper = min(chapters.count - 1, max(start, end))
            guard lower <= upper else { return "" }

            var pieces: [String] = []
            var budget = 12_000

            for chapter in chapters[lower...upper] where budget > 0 {
                let text = source.text(
                    around: .epub(chapterIndex: chapter.index, anchor: "", charOffset: 0),
                    radius: 0
                )
                guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
                pieces.append(text)
                budget -= text.count
                await Task.yield()
            }
            return pieces.joined(separator: "\n")
        }

        bridge.extractFullText = { allowOCR, progress in
            // EPUB 不存在扫描件，文字本来就在解包后的 XHTML 里，没有可识别的对象
            _ = allowOCR

            let chapters = source.chapters
            var report = DocumentTextReport()
            report.totalUnits = chapters.count

            var pieces: [String] = []
            for (offset, chapter) in chapters.enumerated() {
                if Task.isCancelled { break }

                let text = source.text(
                    around: .epub(chapterIndex: chapter.index, anchor: "", charOffset: 0),
                    radius: 0
                )
                .trimmingCharacters(in: .whitespacesAndNewlines)

                if !text.isEmpty {
                    // 带上章节标题：纯文本没有版式，几千字连成一片根本没法读，
                    // 章标题是最省事也最可靠的分段锚点。
                    pieces.append("\(chapter.displayTitle)\n\n\(text)")
                    report.textLayerUnits += 1
                }

                progress(TextExtractionProgress(
                    completed: offset + 1,
                    total: chapters.count,
                    phase: "已处理 \(offset + 1) / \(chapters.count) 章"
                ))
                // 让出一次主线程：整本书的字符串拼接对超大 EPUB 也是可观的开销，
                // 不留空隙的话进度卡片会一直不刷新。
                await Task.yield()
            }

            report.text = pieces.joined(separator: "\n\n")
            return report
        }
    }
}

/// 章末自动续读的开闸器：一次到章末只放行一次，中途回滚则重新武装。
@MainActor
private final class AutoAdvanceGate {
    private var armed = true

    func shouldAdvance() -> Bool {
        guard armed else { return false }
        armed = false
        return true
    }

    func rearm() {
        armed = true
    }
}
