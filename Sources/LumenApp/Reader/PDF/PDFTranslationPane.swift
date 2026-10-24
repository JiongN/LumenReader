import SwiftUI
import AppKit
import LumenKit

/// PDF 翻译固定在左侧导航中。列表只呈现译文；正文原文仍由 PDFKit 显示，
/// 译文单击定位原文；拖选、双击和复制保持原生文字行为。
struct PDFTranslationPane: View {
    @ObservedObject var controller: PDFTranslationController
    var selectionOnly = false

    @EnvironmentObject private var bridge: ReaderBridge
    @EnvironmentObject private var state: AppState
    @EnvironmentObject private var settings: SettingsStore

    @State private var sourceTerm = ""
    @State private var targetTerm = ""
    @State private var glossaryExpanded = false
    @State private var localError: String?
    @State private var editingRange = false
    @State private var firstPage = "1"
    @State private var lastPage = "1"
    @State private var locatedSelection: (documentID: String, paragraph: PDFParagraph, locator: DocumentLocator)?
    private var selectionMode: Bool {
        get { bridge.selectionTranslationMode }
        nonmutating set { bridge.selectionTranslationMode = newValue }
    }

    private var selectedParagraph: PDFParagraph? {
        guard selectionMode else { return nil }
        guard bridge.selectionFromDrag, let selection = bridge.selection, selection.isUsable else {
            return locatedSelection?.documentID == state.document?.id ? locatedSelection?.paragraph : nil
        }
        let page: Int
        switch selection.locator {
        case .pdf(let index, _): page = index
        case .epub(let index, _, _): page = index
        }
        return PDFParagraph(pageIndex: page, text: selection.text, bounds: .zero,
                            lineCount: 1, firstLineOrdinal: 0, isShort: false)
    }

    private var reader: ReaderSettings { settings.reader }

    /// 全篇段落按页分节。`controller.paragraphs` 已按「页号升序 → 页内阅读顺序」排好，
    /// 这里只负责分组、保持每页内部顺序不变。跨页续段按自己的起始页归入一节（只出现一次）。
    private var pageSections: [(page: Int, paragraphs: [PDFParagraph])] {
        // A service outage is one error, not hundreds of identical paragraph cards.
        // Preserve translations that completed before the queue stopped.
        let visible = controller.phase.isFailure
            ? controller.paragraphs.filter { controller.state(of: $0.id).translation != nil }
            : controller.paragraphs
        let grouped = Dictionary(grouping: visible) { $0.pageIndex }
        return grouped.keys.sorted().map { (page: $0, paragraphs: grouped[$0] ?? []) }
    }
    private var targetName: String {
        TranslationLanguage.target(for: reader.translationTargetLanguage).displayName
    }
    private var isLLM: Bool { reader.translationEngineID == LLMTranslation.engineID }
    private var taskIdentity: String {
        let terms = reader.translationGlossary.map { "\($0.source)=\($0.target)" }.joined(separator: "|")
        let provider = isLLM ? settings.translationProvider.map { "\($0.id)|\($0.baseURL)|\($0.selectedModel)|\($0.temperature)|\($0.maxTokens)" } ?? "" : ""
        let selectionID = selectionMode ? "selection:\(selectedParagraph.map { AppPaths.stableHash($0.text) + $0.id } ?? "empty")" : "pages"
        let parsing = settings.ai.documentAI
        return "\(state.document?.id ?? "")|\(reader.translationEngineID)|\(reader.translationTargetLanguage)|\(terms)|\(provider)|\(String(describing: controller.pageRange))|\(selectionID)|\(parsing.parsingEnabled)|\(parsing.parsingBaseURL)|\(parsing.parsingModel)"
    }

    var body: some View {
        VStack(spacing: 0) {
            controls
            Divider()
            content
        }
        .background(DS.Palette.surfaceSunken)
        .task(id: taskIdentity) { await prepareAndStart(reset: false) }
        .onDisappear { controller.stop() }
        .onChange(of: selectionMode) { _, enabled in if !enabled { locatedSelection = nil } }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("PDF 段落翻译")
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: DS.Space.s) {
            HStack(spacing: DS.Space.s) {
                Picker("翻译引擎", selection: engineMode) {
                    Text("机器翻译").tag(false)
                    Text("LLM").tag(true)
                }
                .pickerStyle(.segmented)
                .labelsHidden()

                Menu {
                    ForEach(TranslationLanguage.targets) { language in
                        Button(language.displayName) {
                            settings.reader.translationTargetLanguage = language.id
                        }
                    }
                } label: {
                    Text(targetName)
                        .font(DS.Typo.ui(size: 11, weight: .medium))
                        .lineLimit(1)
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help("目标语言")
            }

            HStack(spacing: DS.Space.s) {
                if isLLM {
                    TranslationModelMenu()
                } else {
                    Menu {
                        machineEngineButton(AppleSystemTranslation.descriptor)
                        machineEngineButton(MicrosoftTranslationEngine().descriptor)
                    } label: {
                        Label(machineEngineName, systemImage: "gearshape.2")
                            .lineLimit(1)
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                    .help("翻译引擎")
                }
                Spacer(minLength: 4)
                phaseControls
            }
            .font(DS.Typo.ui(size: 11.5, weight: .medium))
            .foregroundStyle(DS.Palette.textSecondary)

            HStack(spacing: DS.Space.s) {
                Menu {
                    if !selectionOnly {
                    Button("全部页") { selectionMode = false; controller.pageRange = nil; editingRange = false }
                    Button("当前页") {
                        selectionMode = false
                        let page = bridge.currentUnitIndex
                        firstPage = String(page + 1); lastPage = firstPage
                        controller.pageRange = page...page; editingRange = false
                    }
                    Button("自选页码…") {
                        firstPage = String((controller.pageRange?.lowerBound ?? bridge.currentUnitIndex) + 1)
                        lastPage = String((controller.pageRange?.upperBound ?? max(0, bridge.unitCount - 1)) + 1)
                        editingRange = true
                    }
                    Divider()
                    } else {
                        Button("逐段翻译") { selectionMode = false }
                    }
                    Button("划词译") { selectionMode = true; editingRange = false }
                } label: {
                    Text(selectionMode ? "划词译" : controller.pageRange.map { "第 \($0.lowerBound + 1)–\($0.upperBound + 1) 页" } ?? "全部页")
                        .lineLimit(1)
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help("翻译范围")
                Spacer(minLength: 0)
                PanelTextSizeControl(size: $settings.ui.translationTextSize, label: "译文字号")
            }
            .font(DS.Typo.ui(size: 11.5))
            if editingRange {
                HStack(spacing: DS.Space.s) {
                    TextField("起始页", text: $firstPage).accessibilityLabel("翻译起始 PDF 页码")
                    Text("–")
                    TextField("结束页", text: $lastPage).accessibilityLabel("翻译结束 PDF 页码")
                    Button { applyPageRange() } label: { Image(systemName: "checkmark") }
                        .help("应用翻译页码范围")
                }
                .textFieldStyle(.roundedBorder)
                .onSubmit { applyPageRange() }
            }

            DisclosureGroup(isExpanded: $glossaryExpanded) {
                glossaryEditor
            } label: {
                Label("术语表 · \(reader.translationGlossary.count)", systemImage: "character.book.closed")
                    .font(DS.Typo.ui(size: 11.5, weight: .semibold))
            }
            .tint(DS.Palette.accent)
            .help("LLM 使用指定术语；机器翻译不保证采用指定译法")
            if let localError {
                Text(localError)
                    .font(DS.Typo.ui(size: 10.5))
                    .foregroundStyle(DS.Palette.warning)
            }
            if let note = controller.sourceNote, note != "文字取自 PDF 文字层", note != "划词" {
                Text(note)
                    .font(DS.Typo.ui(size: 10.5))
                    .foregroundStyle(DS.Palette.textSecondary)
                    .textSelection(.enabled)
            }
        }
        .padding(DS.Space.m)
    }

    private var engineMode: Binding<Bool> {
        Binding(
            get: { isLLM },
            set: { useLLM in
                if useLLM {
                    // 记住进入 LLM 前正在用的机器引擎，切回「机器翻译」时恢复它。
                    // 不做这一步，切回就硬编码回 Apple 系统翻译 —— 用户显式选过的
                    // 微软翻译会在一次 LLM 往返后被悄悄丢掉。
                    if !isLLM, reader.translationEngineID != LLMTranslation.engineID {
                        settings.reader.translationMachineEngineID = reader.translationEngineID
                    }
                    settings.reader.translationEngineID = LLMTranslation.engineID
                } else {
                    settings.reader.translationEngineID = TranslationEngineCatalog
                        .descriptor(for: reader.translationMachineEngineID).id
                }
            }
        )
    }

    private func applyPageRange() {
        guard let start = Int(firstPage), let end = Int(lastPage),
              start >= 1, end >= start, end <= bridge.unitCount else {
            localError = "页码范围须在 1–\(bridge.unitCount) 内，且起始页不大于结束页。"
            return
        }
        localError = nil
        selectionMode = false
        controller.pageRange = (start - 1)...(end - 1)
        editingRange = false
    }

    @ViewBuilder
    private func machineEngineButton(_ descriptor: TranslationEngineDescriptor) -> some View {
        Button {
            settings.reader.translationEngineID = descriptor.id
            // 机器引擎的选择同样记进「切 LLM 后恢复」的字段，保证往返不丢。
            settings.reader.translationMachineEngineID = descriptor.id
        } label: {
            if reader.translationEngineID == descriptor.id {
                Label(descriptor.displayName, systemImage: "checkmark")
            } else {
                Text(descriptor.displayName)
            }
        }
    }

    private var machineEngineName: String {
        TranslationEngineCatalog.descriptor(for: reader.translationEngineID).displayName
    }

    @ViewBuilder
    private var phaseControls: some View {
        if controller.phase.isBusy {
            ProgressView().controlSize(.small)
            Button("停止") { controller.stop() }.buttonStyle(.plain)
        } else if controller.unfinishedCount > 0 && controller.phase.isFailure {
            Text("未完成 \(controller.unfinishedCount)")
                .foregroundStyle(DS.Palette.warning)
            Button("重试") { retryFailed() }.buttonStyle(.plain)
        } else if controller.failedCount > 0 {
            Text("失败 \(controller.failedCount)")
                .foregroundStyle(DS.Palette.warning)
            Button("重试") { retryFailed() }.buttonStyle(.plain)
        } else if controller.totalCount > 0 {
            Text("\(controller.settledCount)/\(controller.totalCount)")
                .monospacedDigit()
            Button {
                Task { await prepareAndStart(reset: true) }
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.plain)
            .help("重新翻译")
        }
    }

    private var glossaryEditor: some View {
        VStack(alignment: .leading, spacing: DS.Space.s) {
            HStack(spacing: 5) {
                TextField("原词", text: $sourceTerm)
                Image(systemName: "arrow.right")
                    .foregroundStyle(DS.Palette.textTertiary)
                TextField("指定译法", text: $targetTerm)
                Button(action: addTerm) { Image(systemName: "plus.circle.fill") }
                    .buttonStyle(.plain)
                    .disabled(sourceTerm.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                              || targetTerm.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .textFieldStyle(.roundedBorder)
            .font(DS.Typo.ui(size: 11))

            ForEach(reader.translationGlossary) { entry in
                HStack(spacing: 5) {
                    Text(entry.source).lineLimit(1)
                    Image(systemName: "arrow.right")
                        .font(DS.Typo.ui(size: 9))
                        .foregroundStyle(DS.Palette.textTertiary)
                    Text(entry.target).lineLimit(1)
                    Spacer(minLength: 2)
                    Button {
                        settings.reader.translationGlossary.removeAll { $0.id == entry.id }
                    } label: { Image(systemName: "xmark") }
                    .buttonStyle(.plain)
                }
                .font(DS.Typo.ui(size: 10.5))
            }
        }
        .padding(.top, DS.Space.xs)
    }

    @ViewBuilder
    private var content: some View {
        if controller.phase == .preparing || (controller.paragraphs.isEmpty && controller.phase.isBusy) {
            sidebarState("正在分析段落…", icon: "text.magnifyingglass", showsProgress: true)
        } else if case .recognizing(let progress) = controller.phase {
            sidebarState("正在 OCR · \(progress.completed)/\(progress.total)",
                         icon: "text.viewfinder", showsProgress: true)
        } else if case .failed(let reason) = controller.phase, controller.doneCount == 0 {
            sidebarState(reason, icon: "exclamationmark.triangle", showsProgress: false)
        } else if controller.paragraphs.isEmpty {
            sidebarState(selectionMode ? "尚未选中文字" : "这篇文档抽不出可翻译段落", icon: "text.cursor", showsProgress: false)
        } else {
            ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: DS.Space.m) {
                    if case .failed(let reason) = controller.phase {
                        Label(reason, systemImage: "exclamationmark.triangle")
                            .font(DS.Typo.ui(size: 12))
                            .foregroundStyle(DS.Palette.warning)
                    }
                    ForEach(pageSections, id: \.page) { section in
                        VStack(alignment: .leading, spacing: DS.Space.s) {
                            Text("第 \(section.page + 1) \(selectionOnly ? "章" : "页")")
                                .font(DS.Typo.ui(size: 10.5, weight: .semibold))
                                .foregroundStyle(DS.Palette.textTertiary)
                            ForEach(section.paragraphs) { paragraph in translationRow(paragraph) }
                        }
                        .id(section.page)
                    }
                }
                .padding(DS.Space.m)
            }
            .task {
                // Only align when opening the pane; never chase live scrolling.
                await Task.yield()
                let currentPage = LaunchOptions.jumpToUnit.map { max(0, $0 - 1) } ?? bridge.currentUnitIndex
                if let page = pageSections.last(where: { $0.page <= currentPage })?.page ?? pageSections.first?.page {
                    proxy.scrollTo(page, anchor: .top)
                }
            }
            }
        }
    }

    private func translationRow(_ paragraph: PDFParagraph) -> some View {
            VStack(alignment: .leading, spacing: DS.Space.xs) {
                if selectionMode {
                    Text(paragraph.text)
                        .font(DS.Typo.readingPanel(size: CGFloat(settings.ui.translationTextSize)))
                        .foregroundStyle(DS.Palette.textSecondary)
                        .textSelection(.enabled)
                    Divider()
                }
                if paragraph.kind == .table {
                    Label("表格", systemImage: "tablecells")
                        .font(DS.Typo.ui(size: 9.5, weight: .semibold))
                        .foregroundStyle(DS.Palette.textSecondary)
                }
                if paragraph.spansPages {
                    Text("跨页 · \(paragraph.pageIndices.map { String($0 + 1) }.joined(separator: "–"))")
                        .font(DS.Typo.ui(size: 9.5, weight: .semibold))
                        .foregroundStyle(DS.Palette.accent)
                }
                translationState(controller.state(of: paragraph.id), paragraph: paragraph)
                HStack(spacing: DS.Space.s) {
                    Spacer(minLength: 0)
                    if let text = controller.state(of: paragraph.id).translation {
                        Button { copyTranslation(text) } label: { Image(systemName: "doc.on.doc") }
                            .help("复制译文")
                    }
                }
                .buttonStyle(.borderless)
                .font(DS.Typo.ui(size: 11))
            }
            .padding(DS.Space.s)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                RoundedRectangle(cornerRadius: DS.Radius.m, style: .continuous)
                    .fill(DS.Palette.surfaceRaised)
                    .onTapGesture { reveal(paragraph) }
            }
            .overlay(RoundedRectangle(cornerRadius: DS.Radius.m, style: .continuous)
                .strokeBorder(DS.Palette.separator, lineWidth: 0.5))
            .contextMenu {
                if let text = controller.state(of: paragraph.id).translation {
                    Button("复制译文") { copyTranslation(text) }
                }
            }
    }

    private func copyTranslation(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    @ViewBuilder
    private func translationState(_ value: ParagraphTranslationState, paragraph: PDFParagraph) -> some View {
        switch value {
        case .done(let text):
            TranslationText(text: text, size: CGFloat(settings.ui.translationTextSize),
                            color: DS.Palette.textPrimary) { reveal(paragraph) }
                .id("\(state.document?.id ?? "")|\(paragraph.id)")
        case .translating:
            Label("翻译中…", systemImage: "ellipsis").foregroundStyle(DS.Palette.textSecondary)
        case .failed(let reason):
            Label(reason, systemImage: "exclamationmark.circle").foregroundStyle(DS.Palette.warning)
        case .skipped(let reason):
            Text(reason).foregroundStyle(DS.Palette.textTertiary)
        case .pending:
            Text("等待翻译…").foregroundStyle(DS.Palette.textTertiary)
        }
    }

    private func reveal(_ paragraph: PDFParagraph) {
        let page = paragraph.fragments.first?.pageIndex ?? paragraph.pageIndex
        if selectionMode, let selection = selectedParagraph, let documentID = state.document?.id,
           let locator = bridge.selection?.locator ?? locatedSelection?.locator {
            locatedSelection = (documentID, selection, locator)
        }
        if let reveal = bridge.revealTranslationParagraph { reveal(paragraph, page) }
        else if let locator = locatedSelection?.locator { bridge.goTo?(locator) }
    }

    private func sidebarState(_ text: String, icon: String, showsProgress: Bool) -> some View {
        VStack(spacing: DS.Space.s) {
            if showsProgress { ProgressView().controlSize(.small) }
            Image(systemName: icon)
                .font(DS.Typo.ui(size: 20))
                .foregroundStyle(DS.Palette.textTertiary)
            Text(text)
                .font(DS.Typo.ui(size: 11.5))
                .foregroundStyle(DS.Palette.textSecondary)
                .multilineTextAlignment(.center)
        }
        .padding(DS.Space.l)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func addTerm() {
        let entry = TranslationGlossaryEntry(source: sourceTerm, target: targetTerm)
        guard entry.isUsable else { return }
        settings.reader.translationGlossary.removeAll {
            $0.source.caseInsensitiveCompare(entry.source) == .orderedSame
        }
        settings.reader.translationGlossary.append(entry)
        sourceTerm = ""
        targetTerm = ""
    }

    private func prepareAndStart(reset: Bool) async {
        guard let path = state.document?.url.standardizedFileURL.path else { return }
        let selection = selectedParagraph
        if selectionMode {
            controller.stop()
            guard selection != nil else { controller.clearSelection(); return }
            do { try await Task.sleep(for: .milliseconds(300)) } catch { return }
        }
        guard !Task.isCancelled else { return }
        localError = nil
        controller.isVisible = true
        if reset { controller.resetTranslations() }
        await controller.prepare(documentPath: path,
                                 target: reader.translationTargetLanguage,
                                 engineID: reader.translationEngineID,
                                 glossary: reader.translationGlossary,
                                 provider: settings.translationProvider, selection: selection,
                                 parsingOptions: settings.ai.documentAI, force: reset)
        guard !Task.isCancelled, !controller.phase.isFailure, controller.phase != .cancelled else { return }
        startAll()
    }

    private func startAll() {
        if isLLM, !(settings.translationProvider?.isConfigured ?? false) {
            localError = "请先在“设置 → AI”中添加服务商与模型。"
            return
        }
        controller.startAll(engineID: reader.translationEngineID,
                            target: reader.translationTargetLanguage,
                            customEngine: makeCustomEngine())
    }

    private func retryFailed() {
        controller.retryFailed(engineID: reader.translationEngineID,
                               target: reader.translationTargetLanguage,
                               customEngine: makeCustomEngine())
    }

    private func makeCustomEngine() -> (any TranslationEngine)? {
        settings.configuredTranslationEngine
    }
}
