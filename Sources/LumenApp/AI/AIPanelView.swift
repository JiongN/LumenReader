import SwiftUI
import AppKit
import LumenKit

/// AI 侧边面板。
///
/// 交互的取值取向：所有 AI 动作都是「针对你现在看的这一块」发起的，
/// 回答里必须带得回原文的引用。不做那种浮在半空、跟正文没有锚点的聊天窗口。
struct AIPanelView: View {

    @EnvironmentObject private var state: AppState
    @EnvironmentObject private var bridge: ReaderBridge
    @EnvironmentObject private var chat: AIChatModel
    @Environment(\.openSettings) private var openSettings

    /// 是否跟随最新内容自动滚到底部
    @State private var followTail = true

    var body: some View {
        VStack(spacing: 0) {
            header
            divider
            transcript
            divider
            composer
        }
        .background(.regularMaterial)
        .onChange(of: state.pendingAIRequest) { _, request in
            guard let request else { return }
            consume(request)
            state.pendingAIRequest = nil
        }
    }

    private var divider: some View {
        Rectangle().fill(DS.Palette.separator).frame(height: 1)
    }

    // MARK: - 头部

    private var header: some View {
        HStack(spacing: DS.Space.s) {
            Image(systemName: "sparkles")
                .font(DS.Typo.ui(size: 12.5, weight: .semibold))
                .foregroundStyle(DS.Palette.accent)

            Text("AI 阅读")
                .font(DS.Typo.headline)
                .foregroundStyle(DS.Palette.textPrimary)

            providerChip

            Spacer(minLength: 0)

            Menu {
                Button("总结本节") { run(.summarize(scope: .currentUnit)) }
                Button("总结全书") { summarizeWholeDocument() }
                Divider()
                Button("记住选中内容") { rememberSelection() }
                    .disabled(!hasSelection)
                Button("记住当前这一节") { rememberCurrentUnit() }
                    .disabled(bridge.isLoading)
                Divider()
                Button("导出摘要为 Markdown…") { exportSummary() }
                    .disabled(chat.lastSubstantialAnswer.isEmpty)
                Divider()
                Button("清空对话") { chat.clear() }
                    .disabled(chat.bubbles.isEmpty)
                Button("AI 与阅读设置…") {
                    openSettings()
                    NSApp.activate(ignoringOtherApps: true)
                }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(DS.Typo.ui(size: 13))
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .frame(width: 22)
            .help("更多")
        }
        .padding(.horizontal, DS.Space.m)
        .frame(height: DS.Size.toolbarHeight)
    }

    private var providerChip: some View {
        let config = state.settingsStore.activeProvider
        let configured = config?.isConfigured ?? false

        return Button {
            openSettings()
            NSApp.activate(ignoringOtherApps: true)
        } label: {
            HStack(spacing: 4) {
                Circle()
                    .fill(configured ? DS.Palette.success : DS.Palette.warning)
                    .frame(width: 5, height: 5)
                Text(config.map { $0.selectedModel.isEmpty ? $0.name : $0.selectedModel } ?? "未配置")
                    .font(DS.Typo.ui(size: 10.5, weight: .medium))
                    .lineLimit(1)
            }
            .foregroundStyle(DS.Palette.textSecondary)
            .padding(.horizontal, DS.Space.s)
            .padding(.vertical, 3)
            .background(
                Capsule().fill(DS.Palette.surfaceRaised)
            )
            .overlay(
                Capsule().strokeBorder(DS.Palette.separator, lineWidth: 0.5)
            )
        }
        .buttonStyle(.plain)
        .help(configured ? "点击修改 AI 设置" : "尚未配置 AI 服务商，点击开始配置")
    }

    // MARK: - 对话区

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                if chat.bubbles.isEmpty {
                    emptyState
                } else {
                    LazyVStack(alignment: .leading, spacing: DS.Space.m) {
                        ForEach(chat.bubbles) { bubble in
                            AIBubbleView(bubble: bubble, isStreaming: chat.streamingID == bubble.id)
                                .id(bubble.id)
                        }
                        Color.clear.frame(height: 1).id(Self.bottomAnchor)
                    }
                    .padding(DS.Space.m)
                }
            }
            .onScrollGeometryChange(for: Bool.self) { geometry in
                geometry.contentOffset.y + geometry.containerSize.height >= geometry.contentSize.height - 48
            } action: { _, atBottom in
                followTail = atBottom
            }
            .onChange(of: chat.bubbles.count) { _, _ in
                followTail = true
                scrollToBottom(proxy, animated: true)
            }
            .onChange(of: chat.bubbles.last?.text) { _, _ in
                guard followTail else { return }
                scrollToBottom(proxy, animated: false)
            }
        }
    }

    private static let bottomAnchor = "lumen.ai.bottom"

    private func scrollToBottom(_ proxy: ScrollViewProxy, animated: Bool) {
        if animated {
            withAnimation(DS.Motion.quick) { proxy.scrollTo(Self.bottomAnchor, anchor: .bottom) }
        } else {
            proxy.scrollTo(Self.bottomAnchor, anchor: .bottom)
        }
    }

    // MARK: - 空状态

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: DS.Space.l) {
            VStack(alignment: .leading, spacing: DS.Space.xs) {
                Text("让 AI 帮你读这一页")
                    .font(DS.Typo.ui(size: 13.5, weight: .semibold))
                    .foregroundStyle(DS.Palette.textPrimary)
                Text("选中正文后点浮动条上的按钮，或直接从下面开始。\n没有选中内容时，提问会先在全书中检索相关段落。")
                    .font(DS.Typo.ui(size: 11.5))
                    .foregroundStyle(DS.Palette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(spacing: DS.Space.s) {
                quickAction("解释选中内容", icon: "sparkles", enabled: hasSelection) { run(.explain) }
                quickAction("翻译选中内容", icon: "character.book.closed", enabled: hasSelection) { run(.translate) }
                quickAction("总结本节", icon: "text.append", enabled: true) { run(.summarize(scope: .currentUnit)) }
                quickAction("总结全书", icon: "books.vertical", enabled: bridge.unitCount > 1) { summarizeWholeDocument() }
            }

            if !(state.settingsStore.activeProvider?.isConfigured ?? false) {
                setupCallout
            }
        }
        .padding(DS.Space.m)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var setupCallout: some View {
        VStack(alignment: .leading, spacing: DS.Space.s) {
            HStack(spacing: DS.Space.xs) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(DS.Typo.ui(size: 11))
                    .foregroundStyle(DS.Palette.warning)
                Text("还没有可用的 AI 服务商")
                    .font(DS.Typo.ui(size: 12, weight: .semibold))
                    .foregroundStyle(DS.Palette.textPrimary)
            }
            Text("Lumen 采用 BYOK：密钥只存在你本机的钥匙串里，不经过任何中间服务器。\n支持 DeepSeek、OpenAI、Kimi、智谱、通义，以及本机的 Ollama / LM Studio。")
                .font(DS.Typo.ui(size: 11.5))
                .foregroundStyle(DS.Palette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Button {
                openSettings()
                NSApp.activate(ignoringOtherApps: true)
            } label: {
                Text("打开 AI 设置")
                    .font(DS.Typo.ui(size: 12, weight: .medium))
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .tint(DS.Palette.accent)
        }
        .padding(DS.Space.m)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: DS.Radius.m, style: .continuous)
                .fill(DS.Palette.warning.opacity(0.08))
        )
        .overlay(
            RoundedRectangle(cornerRadius: DS.Radius.m, style: .continuous)
                .strokeBorder(DS.Palette.warning.opacity(0.28), lineWidth: 0.5)
        )
    }

    private func quickAction(
        _ title: String,
        icon: String,
        enabled: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: DS.Space.s) {
                Image(systemName: icon)
                    .font(DS.Typo.ui(size: 12))
                    .frame(width: 16)
                Text(title)
                    .font(DS.Typo.ui(size: 12.5))
                Spacer(minLength: 0)
                Image(systemName: "arrow.up.forward")
                    .font(DS.Typo.ui(size: 9, weight: .semibold))
                    .opacity(0.35)
            }
            .foregroundStyle(enabled ? DS.Palette.textPrimary : DS.Palette.textTertiary)
            .padding(.horizontal, DS.Space.m)
            .padding(.vertical, 9)
            .frame(maxWidth: .infinity)
            .background(
                RoundedRectangle(cornerRadius: DS.Radius.m, style: .continuous)
                    .fill(DS.Palette.surfaceRaised)
            )
            .overlay(
                RoundedRectangle(cornerRadius: DS.Radius.m, style: .continuous)
                    .strokeBorder(DS.Palette.separator, lineWidth: 0.5)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
    }

    // MARK: - 输入区

    private var composer: some View {
        VStack(spacing: DS.Space.s) {
            if let selection = bridge.selection, selection.isUsable {
                selectionChip(selection)
            }

            HStack(alignment: .bottom, spacing: DS.Space.s) {
                TextField("就当前内容提问…", text: $chat.draft, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(DS.Typo.aiBody)
                    .lineLimit(1...6)
                    .padding(.horizontal, DS.Space.m)
                    .padding(.vertical, 9)
                    .background(
                        RoundedRectangle(cornerRadius: DS.Radius.m, style: .continuous)
                            .fill(DS.Palette.surfaceRaised)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: DS.Radius.m, style: .continuous)
                            .strokeBorder(DS.Palette.separator, lineWidth: 0.5)
                    )
                    .onSubmit(sendDraft)

                if chat.isStreaming {
                    Button {
                        chat.stop()
                    } label: {
                        Image(systemName: "stop.circle.fill")
                            .font(DS.Typo.ui(size: 22))
                            .foregroundStyle(DS.Palette.danger)
                    }
                    .buttonStyle(.plain)
                    .help("停止生成")
                } else {
                    Button(action: sendDraft) {
                        Image(systemName: "arrow.up.circle.fill")
                            .font(DS.Typo.ui(size: 22))
                            .foregroundStyle(canSend ? DS.Palette.accent : DS.Palette.textTertiary)
                    }
                    .buttonStyle(.plain)
                    .disabled(!canSend)
                    .help("发送 (↩)")
                }
            }
        }
        .padding(DS.Space.m)
    }

    private var canSend: Bool {
        !chat.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !chat.isStreaming
    }

    private func selectionChip(_ selection: ReaderSelection) -> some View {
        HStack(spacing: DS.Space.s) {
            Image(systemName: "text.quote")
                .font(DS.Typo.ui(size: 10))
                .foregroundStyle(DS.Palette.accent)
            Text(selection.text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(46) + (selection.text.count > 46 ? "…" : ""))
                .font(DS.Typo.ui(size: 11))
                .foregroundStyle(DS.Palette.textSecondary)
                .lineLimit(1)
            Spacer(minLength: 0)
            Button {
                // 同样要动画事务：否则划词条是瞬间消失，和它淡入出场的样子不对称。
                withAnimation(DS.Motion.reveal) { bridge.selection = nil }
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(DS.Typo.ui(size: 11))
                    .foregroundStyle(DS.Palette.textTertiary)
            }
            .buttonStyle(.plain)
            .help("清除选中")
        }
        .padding(.horizontal, DS.Space.s)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: DS.Radius.s, style: .continuous)
                .fill(DS.Palette.accentSoft)
        )
    }

    // MARK: - 动作

    private var hasSelection: Bool {
        bridge.selection?.isUsable ?? false
    }

    private func sendDraft() {
        guard canSend else { return }
        let question = chat.draft.trimmingCharacters(in: .whitespacesAndNewlines)
        let (context, locator, _) = resolveContext(for: .ask(question: question))
        chat.followUp(
            question: question,
            selection: bridge.selection,
            metadata: bridge.metadata,
            locatorLabel: bridge.positionLabel,
            context: context,
            locator: locator,
            config: state.settingsStore.activeProvider,
            memory: state.aiMemoryPayload,
            translateTarget: state.settingsStore.ai.translateTarget
        )
    }

    private func run(_ task: AITask) {
        let (context, locator, _) = resolveContext(for: task)
        chat.submit(
            task: task,
            selection: bridge.selection,
            metadata: bridge.metadata,
            locatorLabel: bridge.positionLabel,
            context: context,
            locator: locator,
            citations: nil,
            config: state.settingsStore.activeProvider,
            memory: state.aiMemoryPayload,
            translateTarget: state.settingsStore.ai.translateTarget
        )
    }

    private func consume(_ request: AIRequest) {
        switch request.kind {
        case .explain:
            run(.explain)
        case .translate:
            run(.translate)
        case .ask:
            run(.ask(question: request.customPrompt.isEmpty ? "这一段是什么意思？" : request.customPrompt))
        case .summarize:
            run(.summarize(scope: .currentUnit))
        case .summarizeAll:
            summarizeWholeDocument()
        case .custom:
            run(.custom(prompt: request.customPrompt))
        }
    }

    /// 决定这次请求要喂给模型什么上下文。
    ///
    /// 三级回退：有选中内容就用选中内容（最准）；没有选中但用户在提问，
    /// 就全书检索出相关段落（把提问从「这一屏」扩到「整本书」）；
    /// 都没有就用当前阅读位置的内容。
    private func resolveContext(for task: AITask) -> (String, DocumentLocator, [DocumentLocator]) {
        if let selection = bridge.selection {
            return (selection.text, selection.locator, [selection.locator])
        }

        if let query = Self.retrievalQuery(for: task), !query.isEmpty,
           let retrieve = bridge.retrieveProvider {
            let slices = retrieve(query)
            if !slices.isEmpty {
                let context = slices
                    .map { "【\($0.label)】\n\($0.text)" }
                    .joined(separator: "\n\n")
                return (context, slices[0].locator, slices.map(\.locator))
            }
        }

        let fallback = bridge.currentContextProvider?() ?? ("", .pdf(page: 0, charOffset: 0))
        return (fallback.0, fallback.1, [fallback.1])
    }

    private static func retrievalQuery(for task: AITask) -> String? {
        switch task {
        case .ask(let question):   return question
        case .custom(let prompt):  return prompt
        case .explain, .translate, .summarize:
            return nil
        }
    }

    private func summarizeWholeDocument() {
        guard let slices = bridge.slicesProvider?(), !slices.isEmpty else {
            return
        }
        chat.summarizeDocument(
            slices: slices,
            metadata: bridge.metadata,
            config: state.settingsStore.activeProvider,
            memory: state.aiMemoryPayload
        )
    }

    // MARK: - 记忆

    private func rememberSelection() {
        guard let selection = bridge.selection, selection.isUsable else { return }
        state.remember(
            text: selection.text,
            source: state.currentDocumentTitle,
            locatorLabel: selection.locator.displayLabel()
        )
    }

    private func rememberCurrentUnit() {
        guard let (text, locator) = bridge.currentContextProvider?() else { return }
        state.remember(
            text: text,
            source: state.currentDocumentTitle,
            locatorLabel: locator.displayLabel()
        )
    }

    // MARK: - 导出

    private func exportSummary() {
        let summary = chat.lastSubstantialAnswer
        guard !summary.isEmpty else { return }
        ExportService.exportSummary(
            documentTitle: state.currentDocumentTitle,
            metadata: bridge.metadata,
            summary: summary,
            transcript: chat.bubbles
        )
    }
}

// MARK: - 单条消息

struct AIBubbleView: View {

    let bubble: AIChatModel.Bubble
    let isStreaming: Bool

    @EnvironmentObject private var bridge: ReaderBridge
    @EnvironmentObject private var state: AppState
    @State private var showReasoning = false
    @State private var justRemembered = false

    var body: some View {
        switch bubble.role {
        case .user:      userBubble
        case .assistant: assistantBubble
        case .notice:    noticeBubble
        }
    }

    // MARK: 用户

    private var userBubble: some View {
        VStack(alignment: .trailing, spacing: DS.Space.xs) {
            Text(bubble.text)
                .font(DS.Typo.aiBody)
                .foregroundStyle(DS.Palette.textPrimary)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, DS.Space.m)
                .padding(.vertical, DS.Space.s)
                .background(
                    RoundedRectangle(cornerRadius: DS.Radius.m, style: .continuous)
                        .fill(DS.Palette.accentSoft)
                )
                .textSelection(.enabled)
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
    }

    // MARK: AI

    private var assistantBubble: some View {
        HStack(alignment: .top, spacing: DS.Space.s) {
            ZStack {
                Circle()
                    .fill(bubble.failed ? DS.Palette.danger.opacity(0.14) : DS.Palette.accentSoft)
                Image(systemName: bubble.failed ? "exclamationmark.triangle.fill" : "sparkles")
                    .font(DS.Typo.ui(size: 9.5, weight: .semibold))
                    .foregroundStyle(bubble.failed ? DS.Palette.danger : DS.Palette.accent)
            }
            .frame(width: 20, height: 20)
            .padding(.top, 1)

            VStack(alignment: .leading, spacing: DS.Space.s) {
                if !bubble.reasoning.isEmpty {
                    reasoningDisclosure
                }

                if bubble.text.isEmpty && isStreaming {
                    thinkingIndicator
                } else if bubble.text.isEmpty && !bubble.progress.isEmpty {
                    Text(bubble.progress)
                        .font(DS.Typo.ui(size: 11.5))
                        .foregroundStyle(DS.Palette.textTertiary)
                } else {
                    MarkdownText(
                        text: bubble.text,
                        textColor: bubble.failed ? DS.Palette.danger : DS.Palette.textPrimary
                    )
                    .textSelection(.enabled)
                }

                if isStreaming && !bubble.text.isEmpty {
                    if !bubble.progress.isEmpty {
                        Text(bubble.progress)
                            .font(DS.Typo.ui(size: 10.5))
                            .foregroundStyle(DS.Palette.textTertiary)
                    }
                }

                if !bubble.text.isEmpty && !isStreaming && !bubble.failed {
                    footerRow
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var reasoningDisclosure: some View {
        VStack(alignment: .leading, spacing: DS.Space.xs) {
            Button {
                withAnimation(DS.Motion.quick) { showReasoning.toggle() }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: showReasoning ? "chevron.down" : "chevron.right")
                        .font(DS.Typo.ui(size: 8, weight: .bold))
                    Text("思考过程")
                        .font(DS.Typo.ui(size: 10.5, weight: .medium))
                }
                .foregroundStyle(DS.Palette.textTertiary)
            }
            .buttonStyle(.plain)

            if showReasoning {
                Text(bubble.reasoning)
                    .font(DS.Typo.ui(size: 11, design: .monospaced))
                    .foregroundStyle(DS.Palette.textTertiary)
                    .lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(DS.Space.s)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        RoundedRectangle(cornerRadius: DS.Radius.s, style: .continuous)
                            .fill(DS.Palette.surfaceSunken)
                    )
                    .textSelection(.enabled)
            }
        }
    }

    private var thinkingIndicator: some View {
        HStack(spacing: 5) {
            ProgressView().controlSize(.small)
            Text(bubble.progress.isEmpty ? "正在思考…" : bubble.progress)
                .font(DS.Typo.ui(size: 11.5))
                .foregroundStyle(DS.Palette.textTertiary)
        }
    }

    private var citationRow: some View {
        HStack(spacing: DS.Space.xs) {
            ForEach(Array(bubble.citations.prefix(4).enumerated()), id: \.offset) { _, locator in
                Button {
                    bridge.goTo?(locator)
                } label: {
                    HStack(spacing: 3) {
                        Image(systemName: "arrow.turn.down.right")
                            .font(DS.Typo.ui(size: 7.5, weight: .bold))
                        Text(locator.displayLabel())
                            .font(DS.Typo.ui(size: 10, weight: .medium))
                    }
                    .foregroundStyle(DS.Palette.accent)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(
                        Capsule().fill(DS.Palette.accentSoft)
                    )
                }
                .buttonStyle(.plain)
                .help("跳回原文")
            }
        }
    }

    /// 引用跳回 + 「记住这条」。
    ///
    /// 「记住」放在这里而不是让用户去设置页手打：真正值得记的往往是模型刚刚
    /// 说清楚的那句结论，离开这一屏就想不起来要记了。
    private var footerRow: some View {
        HStack(spacing: DS.Space.xs) {
            citationRow

            Spacer(minLength: 0)

            Button {
                rememberAnswer()
            } label: {
                HStack(spacing: 3) {
                    Image(systemName: justRemembered ? "checkmark" : "bookmark")
                        .font(DS.Typo.ui(size: 9, weight: .semibold))
                    Text(justRemembered ? "已记住" : "记住")
                        .font(DS.Typo.ui(size: 10, weight: .medium))
                }
                .foregroundStyle(justRemembered ? DS.Palette.success : DS.Palette.textTertiary)
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(
                    Capsule().fill(justRemembered ? DS.Palette.success.opacity(0.14) : DS.Palette.surfaceRaised)
                )
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .help("把这条回答记入跨会话记忆，之后在任何文档里提问都会带上它")
        }
    }

    private func rememberAnswer() {
        let text = bubble.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        state.remember(
            text: text,
            source: state.currentDocumentTitle,
            locatorLabel: bubble.citations.first?.displayLabel() ?? ""
        )
        withAnimation(DS.Motion.quick) { justRemembered = true }
    }

    // MARK: 提示

    private var noticeBubble: some View {
        HStack(alignment: .top, spacing: DS.Space.s) {
            Image(systemName: "info.circle.fill")
                .font(DS.Typo.ui(size: 11))
                .foregroundStyle(DS.Palette.warning)
                .padding(.top, 1)
            Text(bubble.text)
                .font(DS.Typo.ui(size: 11.5))
                .foregroundStyle(DS.Palette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(DS.Space.m)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: DS.Radius.m, style: .continuous)
                .fill(DS.Palette.warning.opacity(0.09))
        )
    }
}
