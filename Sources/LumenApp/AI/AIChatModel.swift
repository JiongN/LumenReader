import SwiftUI
import LumenKit

/// AI 面板的对话模型。
///
/// 刻意不持有 `SettingsStore`：面板由环境对象驱动，如果模型自己再存一份设置，
/// 就会出现「设置页换了模型、面板还在用旧的」这类双真相源问题。
/// 因此所有配置都在调用时由视图显式传入。
@MainActor
final class AIChatModel: ObservableObject {

    // MARK: 消息模型

    struct Bubble: Identifiable, Codable, Equatable {
        enum Role: String, Codable {
            case user
            case assistant
            /// 系统提示（例如「未配置服务商」），不与模型交互、不入档
            case notice
        }

        var id: UUID = UUID()
        var role: Role
        var text: String
        var reasoning: String = ""
        /// 长任务的阶段性进度，例如「正在读第 3/24 章…」
        var progress: String = ""
        var citations: [DocumentLocator] = []
        var taskTitle: String = ""
        var failed: Bool = false

        static func == (lhs: Bubble, rhs: Bubble) -> Bool {
            lhs.id == rhs.id
                && lhs.text == rhs.text
                && lhs.reasoning == rhs.reasoning
                && lhs.progress == rhs.progress
        }
    }

    // MARK: 状态

    @Published private(set) var bubbles: [Bubble] = []
    @Published var draft: String = ""
    @Published private(set) var isStreaming: Bool = false
    /// 正在流式输出的那条消息 id
    @Published private(set) var streamingID: UUID?

    private var history: [AIMessage] = []
    private var streamTask: Task<Void, Never>?
    private var documentPath: String?

    // 流式输出节流。模型每秒可能吐几十个 token，若每个 token 都写一次 `@Published`，
    // SwiftUI 会在一帧内重排多次，滚动立刻掉帧。这里按约 25Hz 合并刷新，
    // 视觉上仍是逐字出现。
    private var pendingDelta = ""
    private var lastFlush = Date.distantPast
    private let flushInterval: TimeInterval = 0.04

    /// 单次请求直接送进模型的字符预算。超过就走 map-reduce。
    private let directSummaryBudget = 14_000
    /// map 阶段最多分析的切片数，避免一本几百章的书把账单拉爆
    private let maxMapSlices = 30

    // MARK: - 绑定文档

    func bind(to document: OpenDocument?) {
        stop()
        streamTask = nil
        history = []
        bubbles = []
        draft = ""
        pendingDelta = ""
        documentPath = document?.url.standardizedFileURL.path
        loadPersistedChat()
    }

    private func loadPersistedChat() {
        guard let documentPath else { return }
        let url = AppPaths.chatHistoryFile(forPath: documentPath)
        guard let data = try? Data(contentsOf: url),
              let saved = try? JSONDecoder().decode([Bubble].self, from: data) else { return }
        bubbles = saved.filter { $0.role != .notice }

        // 复原历史时只收「一问一答都完整」的对子。
        //
        // 上一轮如果因为网络错误或用户点了停止而失败，存档里就只剩一条 user 消息。
        // 把它单独放进 history，模型会看到一个没人回答的问题，于是在新一轮里
        // 又把那个旧问题答一遍——用户会觉得"我明明问了别的，它却答非所问"。
        var restored: [AIMessage] = []
        var pendingQuestion: String?

        for bubble in saved where bubble.role != .notice {
            switch bubble.role {
            case .user:
                pendingQuestion = bubble.text
            case .assistant:
                guard !bubble.failed,
                      !bubble.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                      let question = pendingQuestion else { continue }
                restored.append(.user(question))
                restored.append(.assistant(bubble.text))
                pendingQuestion = nil
            case .notice:
                break
            }
        }

        history = restored
    }

    private func persistChat() {
        guard let documentPath else { return }
        let url = AppPaths.chatHistoryFile(forPath: documentPath)
        let snapshot = bubbles.filter { $0.role != .notice }
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        try? data.write(to: url, options: .atomic)
    }

    // MARK: - 单轮任务

    func submit(
        task: AITask,
        selection: ReaderSelection?,
        metadata: DocumentMetadata,
        locatorLabel: String,
        context: String,
        locator: DocumentLocator,
        citations: [DocumentLocator]? = nil,
        config: AIProviderConfig?,
        memory: String,
        translateTarget: String,
        template: PromptTemplate? = nil
    ) {
        guard !isStreaming else { return }
        guard let config else {
            appendNotice("还没有配置 AI 服务商。打开「设置 → AI」，从预设里选一个填入 API 密钥，或指向本机的 Ollama。")
            return
        }
        guard config.isConfigured else {
            appendNotice(config.isLocalEndpoint
                ? "「\(config.name)」还没有指定模型。请在「设置 → AI」里填写模型名。"
                : "「\(config.name)」还没有填写 API 密钥。请在「设置 → AI」里补上。")
            return
        }

        bubbles.append(Bubble(
            role: .user,
            text: Self.userDisplayText(task: task, selection: selection),
            taskTitle: task.title
        ))

        var answer = Bubble(role: .assistant, text: "", taskTitle: task.title)
        answer.citations = citations ?? selection.map { [$0.locator] } ?? [locator]
        bubbles.append(answer)
        streamingID = answer.id
        isStreaming = true
        pendingDelta = ""
        lastFlush = Date.distantPast

        let messages = PromptLibrary.messages(
            task: task,
            selection: selection,
            metadata: metadata,
            locatorLabel: locatorLabel,
            context: context,
            memory: memory,
            history: history,
            translateTarget: translateTarget,
            template: template
        )

        streamTask = Task { [weak self] in
            guard let self else { return }
            var failure: String?
            do {
                try await self.streamIntoBubble(messages: messages, config: config)
            } catch {
                if !Task.isCancelled {
                    failure = Self.describe(error)
                }
            }
            self.flushDelta(force: true)
            self.finishStreaming(failure: failure)
        }
    }

    /// 追问：沿用已有上下文，只补一句新问题。
    func followUp(
        question: String,
        selection: ReaderSelection?,
        metadata: DocumentMetadata,
        locatorLabel: String,
        context: String,
        locator: DocumentLocator,
        citations: [DocumentLocator]? = nil,
        config: AIProviderConfig?,
        memory: String,
        translateTarget: String,
        template: PromptTemplate? = nil
    ) {
        let trimmed = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        draft = ""
        submit(
            task: .ask(question: trimmed),
            selection: selection,
            metadata: metadata,
            locatorLabel: locatorLabel,
            context: context,
            locator: locator,
            citations: citations,
            config: config,
            memory: memory,
            translateTarget: translateTarget,
            template: template
        )
    }

    // MARK: - 整本书总结（map-reduce）

    /// 整本书总结。
    ///
    /// 全文塞得下就一次问完；塞不下就先逐片摘要（map），再用这些摘要做总述（reduce）。
    /// 不做「假装塞得下」——超长上下文要么被服务端截断、要么按 token 计费贵得离谱，
    /// 而且模型对中间部分的注意力本来就会衰减，逐片摘要反而更准。
    func summarizeDocument(
        slices: [(label: String, text: String)],
        metadata: DocumentMetadata,
        config: AIProviderConfig?,
        memory: String
    ) {
        guard !isStreaming else { return }
        guard let config else {
            appendNotice("还没有配置 AI 服务商。")
            return
        }
        guard config.isConfigured else {
            appendNotice("请先在「设置 → AI」里完成服务商配置。")
            return
        }

        bubbles.append(Bubble(role: .user, text: "总结全书", taskTitle: "总结全书"))
        var answer = Bubble(role: .assistant, text: "", taskTitle: "总结全书")
        answer.citations = []
        bubbles.append(answer)
        streamingID = answer.id
        isStreaming = true
        pendingDelta = ""

        let totalCharacters = slices.reduce(0) { $0 + $1.text.count }

        streamTask = Task { [weak self] in
            guard let self else { return }
            var failure: String?

            do {
                if totalCharacters <= self.directSummaryBudget {
                    self.setProgress("正在通读全文…")
                    let messages = PromptLibrary.messages(
                        task: .summarize(scope: .wholeDocument),
                        selection: nil,
                        metadata: metadata,
                        locatorLabel: "",
                        context: self.join(slices),
                        memory: memory,
                        history: []
                    )
                    try await self.streamIntoBubble(messages: messages, config: config)
                } else {
                    let capped = Array(slices.prefix(self.maxMapSlices))
                    var summaries: [String] = []

                    for (index, slice) in capped.enumerated() {
                        if Task.isCancelled { break }
                        self.setProgress("正在读第 \(index + 1)/\(capped.count) 段…")
                        let messages = PromptLibrary.chapterSummaryMessages(
                            text: slice.text,
                            chapterLabel: slice.label,
                            metadata: metadata
                        )
                        let summary = try await self.complete(messages: messages, config: config)
                        if !summary.isEmpty {
                            summaries.append("【\(slice.label)】\n\(summary)")
                        }
                    }

                    guard !Task.isCancelled else {
                        self.setProgress("")
                        self.flushDelta(force: true)
                        self.finishStreaming(failure: nil)
                        return
                    }

                    self.setProgress("正在汇总结论…")
                    var reduceConfig = config
                    reduceConfig.maxTokens = max(config.maxTokens, 3000)

                    let skipped = slices.count - capped.count
                    let note = skipped > 0 ? "\n（另有 \(skipped) 段因篇幅未逐一分析，总述仅基于上述部分。）" : ""
                    let messages = PromptLibrary.messages(
                        task: .summarize(scope: .wholeDocument),
                        selection: nil,
                        metadata: metadata,
                        locatorLabel: "",
                        context: summaries.joined(separator: "\n\n") + note,
                        memory: memory,
                        history: []
                    )
                    try await self.streamIntoBubble(messages: messages, config: reduceConfig)
                }
            } catch {
                if !Task.isCancelled {
                    failure = Self.describe(error)
                }
            }

            self.setProgress("")
            self.flushDelta(force: true)
            self.finishStreaming(failure: failure)
        }
    }

    private func join(_ slices: [(label: String, text: String)]) -> String {
        slices.map { "【\($0.label)】\n\($0.text)" }.joined(separator: "\n\n")
    }

    // MARK: - 控制

    func stop() {
        streamTask?.cancel()
        streamTask = nil
        flushDelta(force: true)
        finishStreaming(failure: nil)
    }

    func clear() {
        stop()
        bubbles = []
        history = []
        persistChat()
    }

    /// 最近一条「有实质内容」的 AI 回答。导出摘要时用它，
    /// 避免用户刚点了「记住」之类的按钮就把提示语气泡当成摘要导出去。
    var lastSubstantialAnswer: String {
        for bubble in bubbles.reversed() where bubble.role == .assistant {
            let text = bubble.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !bubble.failed, text.count >= 40 else { continue }
            return text
        }
        return ""
    }

    // MARK: - 底层请求

    private func makeProvider(_ config: AIProviderConfig) -> OpenAICompatibleProvider {
        OpenAICompatibleProvider(
            config: config,
            apiKey: AIKeychain.read(account: config.keychainAccount) ?? ""
        )
    }

    /// 把流式增量写进当前气泡。
    private func streamIntoBubble(messages: [AIMessage], config: AIProviderConfig) async throws {
        let provider = makeProvider(config)
        for try await event in provider.stream(messages: messages) {
            if Task.isCancelled { break }
            switch event {
            case .delta(let text):      appendDelta(text)
            case .reasoning(let text):  appendReasoning(text)
            case .finished:             break
            }
        }
        flushDelta(force: true)
    }

    /// 一次性取回完整回复（map 阶段用，不需要逐字展示）。
    private func complete(messages: [AIMessage], config: AIProviderConfig) async throws -> String {
        let provider = makeProvider(config)
        var output = ""
        for try await event in provider.stream(messages: messages) {
            if Task.isCancelled { break }
            if case .delta(let text) = event { output += text }
        }
        return output.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func describe(_ error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }

    // MARK: - 流式写入

    private func appendDelta(_ text: String) {
        pendingDelta += text
        if Date().timeIntervalSince(lastFlush) >= flushInterval {
            flushDelta(force: false)
            lastFlush = Date()
        }
    }

    private func flushDelta(force: Bool) {
        guard !pendingDelta.isEmpty else { return }
        guard let id = streamingID,
              let index = bubbles.firstIndex(where: { $0.id == id }) else {
            pendingDelta = ""
            return
        }
        bubbles[index].text += pendingDelta
        pendingDelta = ""
        if force { lastFlush = Date() }
    }

    private func appendReasoning(_ text: String) {
        guard let id = streamingID,
              let index = bubbles.firstIndex(where: { $0.id == id }) else { return }
        bubbles[index].reasoning += text
    }

    private func setProgress(_ text: String) {
        guard let id = streamingID,
              let index = bubbles.firstIndex(where: { $0.id == id }) else { return }
        bubbles[index].progress = text
    }

    private func finishStreaming(failure: String?) {
        isStreaming = false
        streamingID = nil

        guard let lastIndex = bubbles.indices.last, bubbles[lastIndex].role == .assistant else { return }

        if let failure {
            bubbles[lastIndex].failed = true
            // 已经吐出来的部分不要丢——用户可能只想看已有的那半段
            let prefix = bubbles[lastIndex].text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "" : "\n\n"
            bubbles[lastIndex].text += prefix + "⚠️ " + failure
        } else if bubbles[lastIndex].text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            bubbles[lastIndex].failed = true
            bubbles[lastIndex].text = "模型返回了空内容。可以换一个模型再试，或缩短选中范围。"
        } else {
            if let lastUser = bubbles.last(where: { $0.role == .user }) {
                history.append(.user(lastUser.text))
            }
            history.append(.assistant(bubbles[lastIndex].text))
            if history.count > 12 { history.removeFirst(history.count - 12) }
        }

        persistChat()
    }

    private func appendNotice(_ text: String) {
        bubbles.append(Bubble(role: .notice, text: text))
    }

    // MARK: - 展示文本

    private static func userDisplayText(task: AITask, selection: ReaderSelection?) -> String {
        let quoted: String = {
            guard let selection else { return "" }
            let text = selection.text.trimmingCharacters(in: .whitespacesAndNewlines)
            let clipped = text.count > 90 ? String(text.prefix(90)) + "…" : text
            return "「\(clipped)」"
        }()

        switch task {
        case .explain:
            return selection == nil ? "解释这一节的内容" : "解释 \(quoted)"
        case .translate:
            return selection == nil ? "翻译这一节" : "翻译 \(quoted)"
        case .ask(let question):
            return question
        case .summarize(.currentUnit):
            return "总结本节"
        case .summarize(.wholeDocument):
            return "总结全书"
        case .custom(let prompt):
            return prompt
        }
    }
}
