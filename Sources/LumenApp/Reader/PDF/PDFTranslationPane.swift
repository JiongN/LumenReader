import SwiftUI
import LumenKit

/// PDF 翻译固定在左侧导航中。列表只呈现译文；正文原文仍由 PDFKit 显示，
/// 点击译文会定位并选中对应原段，避免双语卡片重复占用窄侧栏。
struct PDFTranslationPane: View {
    @ObservedObject var controller: PDFTranslationController

    @EnvironmentObject private var bridge: ReaderBridge
    @EnvironmentObject private var state: AppState
    @EnvironmentObject private var settings: SettingsStore

    @State private var sourceTerm = ""
    @State private var targetTerm = ""
    @State private var glossaryExpanded = false
    @State private var localError: String?

    private var reader: ReaderSettings { settings.reader }

    /// 全篇段落按页分节。`controller.paragraphs` 已按「页号升序 → 页内阅读顺序」排好，
    /// 这里只负责分组、保持每页内部顺序不变。跨页续段按自己的起始页归入一节（只出现一次）。
    private var pageSections: [(page: Int, paragraphs: [PDFParagraph])] {
        let grouped = Dictionary(grouping: controller.paragraphs) { $0.pageIndex }
        return grouped.keys.sorted().map { (page: $0, paragraphs: grouped[$0] ?? []) }
    }
    private var targetName: String {
        TranslationLanguage.target(for: reader.translationTargetLanguage).displayName
    }
    private var isLLM: Bool { reader.translationEngineID == LLMTranslation.engineID }
    private var taskIdentity: String {
        let terms = reader.translationGlossary.map { "\($0.source)=\($0.target)" }.joined(separator: "|")
        return "\(reader.translationEngineID)|\(reader.translationTargetLanguage)|\(terms)"
    }

    var body: some View {
        VStack(spacing: 0) {
            controls
            Divider()
            content
        }
        .background(DS.Palette.surfaceSunken)
        .task(id: taskIdentity) { await prepareAndStart(reset: false) }
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
                .frame(width: 62)
            }

            HStack(spacing: DS.Space.s) {
                if isLLM {
                    Label(llmModelName, systemImage: "sparkles")
                        .lineLimit(1)
                        .help("使用当前 AI 服务商与模型")
                } else {
                    Menu {
                        machineEngineButton(AppleSystemTranslation.descriptor)
                        machineEngineButton(MicrosoftTranslationEngine().descriptor)
                    } label: {
                        Label(machineEngineName, systemImage: "gearshape.2")
                            .lineLimit(1)
                    }
                    .menuStyle(.borderlessButton)
                }
                Spacer(minLength: 4)
                phaseControls
            }
            .font(DS.Typo.ui(size: 11.5, weight: .medium))
            .foregroundStyle(DS.Palette.textSecondary)

            DisclosureGroup(isExpanded: $glossaryExpanded) {
                glossaryEditor
            } label: {
                Label("术语表 · \(reader.translationGlossary.count)", systemImage: "character.book.closed")
                    .font(DS.Typo.ui(size: 11.5, weight: .semibold))
            }
            .tint(DS.Palette.accent)

            if !isLLM, !reader.translationGlossary.isEmpty {
                Text("术语表由 LLM 严格执行；系统与微软翻译不保证采用指定译法。")
                    .font(DS.Typo.ui(size: 10.5))
                    .foregroundStyle(DS.Palette.textTertiary)
            }
            if let localError {
                Text(localError)
                    .font(DS.Typo.ui(size: 10.5))
                    .foregroundStyle(DS.Palette.warning)
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

    private var llmModelName: String {
        guard let provider = settings.activeProvider, provider.isConfigured else { return "未配置 AI" }
        return provider.selectedModel.isEmpty ? provider.name : provider.selectedModel
    }

    @ViewBuilder
    private var phaseControls: some View {
        if controller.phase.isBusy {
            ProgressView().controlSize(.small)
            Button("停止") { controller.stop() }.buttonStyle(.plain)
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
        } else if case .failed(let reason) = controller.phase {
            sidebarState(reason, icon: "exclamationmark.triangle", showsProgress: false)
        } else if controller.paragraphs.isEmpty {
            sidebarState("这篇文档抽不出可翻译段落", icon: "checkmark.circle", showsProgress: false)
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: DS.Space.m) {
                    HStack {
                        Text("全篇译文 · 上下滚动查看")
                            .font(DS.Typo.ui(size: 11.5, weight: .semibold))
                        Spacer()
                        Text("点击译文定位原文")
                            .font(DS.Typo.ui(size: 10))
                            .foregroundStyle(DS.Palette.textTertiary)
                    }
                    ForEach(pageSections, id: \.page) { section in
                        VStack(alignment: .leading, spacing: DS.Space.s) {
                            Text("第 \(section.page + 1) 页")
                                .font(DS.Typo.ui(size: 10.5, weight: .semibold))
                                .foregroundStyle(DS.Palette.textTertiary)
                            ForEach(section.paragraphs) { paragraph in translationRow(paragraph) }
                        }
                    }
                }
                .padding(DS.Space.m)
            }
        }
    }

    private func translationRow(_ paragraph: PDFParagraph) -> some View {
        Button {
            // 定位到该段自己的页（起始片段页），而不是当前主文档停在哪一页。
            // 全篇译文可上下滚动，行内不再有「当前页」的概念，必须按段定位。
            let page = paragraph.fragments.first?.pageIndex ?? paragraph.pageIndex
            bridge.revealTranslationParagraph?(paragraph, page)
        } label: {
            VStack(alignment: .leading, spacing: DS.Space.xs) {
                if paragraph.spansPages {
                    Text("跨页 · \(paragraph.pageIndices.map { String($0 + 1) }.joined(separator: "–"))")
                        .font(DS.Typo.ui(size: 9.5, weight: .semibold))
                        .foregroundStyle(DS.Palette.accent)
                }
                translationState(controller.state(of: paragraph.id))
            }
            .padding(DS.Space.s)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(DS.Palette.surfaceRaised,
                        in: RoundedRectangle(cornerRadius: DS.Radius.m, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: DS.Radius.m, style: .continuous)
                .strokeBorder(DS.Palette.separator, lineWidth: 0.5))
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func translationState(_ value: ParagraphTranslationState) -> some View {
        switch value {
        case .done(let text):
            Text(text)
                .font(DS.Typo.ui(size: 12.5))
                .foregroundStyle(DS.Palette.textPrimary)
                .multilineTextAlignment(.leading)
                .textSelection(.enabled)
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
        localError = nil
        controller.isVisible = true
        if reset { controller.resetTranslations() }
        await controller.prepare(documentPath: path,
                                 target: reader.translationTargetLanguage,
                                 engineID: reader.translationEngineID,
                                 glossary: reader.translationGlossary)
        guard !controller.phase.isFailure else { return }
        startAll()
    }

    private func startAll() {
        if isLLM, !(settings.activeProvider?.isConfigured ?? false) {
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
        guard isLLM, let config = settings.activeProvider else { return nil }
        return LLMTranslationEngine(
            config: config,
            apiKey: AICredentialStore.read(account: config.keychainAccount) ?? "",
            glossary: reader.translationGlossary
        )
    }
}
