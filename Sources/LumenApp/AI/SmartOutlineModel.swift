import SwiftUI
import LumenKit

/// AI 智能目录的模型层。
///
/// 与 `AIChatModel` 一样**不持有 `SettingsStore`**：配置在调用时由视图传入，
/// 免得出现「设置页换了服务商、目录还在用旧的」这种双真相源。
/// 它是 `ObservableObject` 而不是普通结构体，因为一次生成要跑好几秒，
/// 中间有取样、请求、逐节摘要三个阶段，界面得能跟着变。
@MainActor
final class SmartOutlineModel: ObservableObject {
    typealias Completion = @MainActor ([AIMessage], AIProviderConfig) async throws -> String
    private let completion: Completion?
    init(complete: Completion? = nil) { completion = complete }

    // MARK: 阶段

    enum Phase: Equatable {
        case idle
        /// 正在跑，附一句给用户看的进度
        case working(String)
        case failed(String)

        var isWorking: Bool {
            if case .working = self { return true }
            return false
        }
    }

    // MARK: 状态

    @Published private(set) var outline: SmartOutline?
    @Published private(set) var phase: Phase = .idle
    /// 正在生成摘要的条目 id。用集合而不是单个布尔：
    /// 用户可能连点几条，界面要能各自转各自的圈。
    @Published private(set) var summarizing: Set<String> = []

    /// 刚生成完摘要、界面应当自动展开的条目 id。
    ///
    /// 放在模型里而不是视图的本地状态里，是因为摘要有两个来源——用户点按钮、
    /// 以及自检/命令面板直接调 `summarize`。判断「哪条该展开」属于业务，
    /// 视图只负责消费。用「投递 + 消费后清空」而不是让模型去指挥视图：
    /// 模型不需要知道此刻有没有侧栏在显示它。
    @Published private(set) var pendingReveal: Set<String> = []

    private var documentPath: String?
    /// 当前文档的单元总数，用于判定缓存是否过期
    private var unitCount = 0
    private var unitName = "页"

    /// 骨架生成任务。与摘要任务分开持有——
    /// 共用一个句柄的话，用户点「摘要」会把生成的句柄顶掉，之后按「取消」就取消不掉生成了。
    private var generationTask: Task<Void, Never>?
    /// 逐条摘要任务，按条目 id 索引，这样每一条都能单独中止。
    private var summaryTasks: [String: Task<Void, Never>] = [:]
    private var summaryTokens: [String: UUID] = [:]

    // MARK: - 绑定文档

    func bind(to document: OpenDocument?, unitName: String = "页") {
        cancelAllWork()
        self.unitName = unitName
        documentPath = document?.url.standardizedFileURL.path
        unitCount = 0
        summarizing = []
        phase = .idle
        outline = nil
        loadCached()
    }

    /// 载入后由阅读视图补一次真实单元数，用来判定缓存是否还对得上当前文档。
    ///
    /// 不能等到生成时才知道单元数：那样的话，一本被替换过的书会先显示一份
    /// **指向错误页码**的旧目录，用户还以为是对的。宁可先判定、先清掉。
    func syncUnitCount(_ count: Int, unitName: String) {
        self.unitName = unitName
        guard count != unitCount else { return }
        unitCount = count

        guard let cached = outline, !cached.isValid(forUnitCount: count) else { return }
        // 只有「文档确实换过了」才丢：count 为 0 是还没加载完，不是文档变了。
        guard count > 0 else { return }
        outline = nil
        persist()
    }

    // MARK: - 第一步：生成目录骨架

    /// 生成目录骨架。
    ///
    /// 从原文绑定的候选中选择结构。**不生成摘要**——
    /// 一本 300 页的书若要求「目录 + 每节摘要」一次输出，长度会直接顶到 max_tokens，
    /// 中途任何一处失败都得整本重来。摘要等用户真的点开某一节再算。
    func generate(
        bridge: ReaderBridge,
        metadata: DocumentMetadata,
        config: AIProviderConfig?
    ) {
        guard !phase.isWorking else { return }

        guard let config else {
            phase = .failed("还没有配置 AI 服务商。打开「设置 → AI」选一个填入 API 密钥。")
            return
        }
        guard config.isConfigured else {
            phase = .failed(config.isLocalEndpoint
                ? "「\(config.name)」还没有指定模型。请在「设置 → AI」里填写模型名。"
                : "「\(config.name)」还没有填写 API 密钥。请在「设置 → AI」里补上。")
            return
        }
        guard let sourceProvider = bridge.outlineSourceProvider, let path = documentPath,
              let version = Self.cacheVersion(path: path) else {
            phase = .failed("当前文档还不支持提取内容。")
            return
        }

        cancelAllWork()
        phase = .working("正在读取文档…")

        generationTask = Task { [weak self] in
            guard let self else { return }

            do {
                let source = try await sourceProvider()
                try Task.checkCancellation()
                guard source.missingUnits.isEmpty else {
                    throw NSError(domain: "SmartOutline", code: 1, userInfo: [NSLocalizedDescriptionKey:
                        "有 \(source.missingUnits.count) 页未取得正文，请先完成文字识别后再生成目录。"])
                }
                guard source.unitCount > 0, !source.candidates.isEmpty else {
                    throw NSError(domain: "SmartOutline", code: 2, userInfo: [NSLocalizedDescriptionKey:
                        "没有找到可核验的章节标题。不会按正文主题虚构目录。"])
                }
                let candidates = source.candidates.filter { $0.unitIndex >= 0 && $0.unitIndex < source.unitCount }
                let batches = SmartOutlineHeadings.batches(candidates, tokenLimit: ContextBudget.inputLimit(config) - 1400,
                    maxCandidates: max(1, config.maxTokens / 20))
                var entries: [SmartOutlineEntry] = []
                for (index, batch) in batches.enumerated() {
                    try Task.checkCancellation()
                    self.phase = .working("正在核对标题 \(index + 1)/\(batches.count)…")
                    let messages = PromptLibrary.smartOutlineMessages(metadata: metadata, candidates: batch, unitName: self.unitName)
                    guard messages.reduce(0, { $0 + ContextBudget.estimatedTokens($1.content) }) <= ContextBudget.inputLimit(config) else {
                        throw NSError(domain: "SmartOutline", code: 4, userInfo: [NSLocalizedDescriptionKey: "当前模型的输入预算不足以核对标题，请提高上下文预算。"])
                    }
                    let raw = try await self.complete(messages: messages, config: config)
                    try Task.checkCancellation()
                    entries += try SmartOutlineHeadings.selectedEntries(raw, candidates: batch)
                }
                guard !entries.isEmpty else { throw SmartOutlineParser.ParseError.noUsableEntries }
                guard Self.cacheVersion(path: path) == version else {
                    throw NSError(domain: "SmartOutline", code: 3, userInfo: [NSLocalizedDescriptionKey: "文件已发生变化，请重新生成目录。"])
                }
                self.unitCount = source.unitCount
                self.outline = SmartOutline(
                    entries: entries,
                    modelName: config.selectedModel,
                    sourceUnitCount: source.unitCount,
                    sourceVersion: version
                )
                self.phase = .idle
                self.persist()
            } catch {
                guard !Task.isCancelled else { return }
                self.phase = .failed(Self.describe(error))
            }
        }
    }

    // MARK: - 第二步：为单节生成摘要

    /// 为一条目录项生成摘要并缓存。
    func summarize(
        entry: SmartOutlineEntry,
        bridge: ReaderBridge,
        metadata: DocumentMetadata,
        config: AIProviderConfig?
    ) {
        guard let current = outline else { return }
        guard validateSource() else { return }
        guard !summarizing.contains(entry.id) else { return }
        guard let index = current.entries.firstIndex(where: { $0.id == entry.id }) else { return }

        // 已经有摘要就别再花钱问一遍——除非用户是主动「重新生成」。
        if let existing = current.entries[index].summary, !existing.isEmpty { return }

        guard let config, config.isConfigured else {
            phase = .failed("AI 服务商未配置，无法生成摘要。")
            return
        }
        guard let sectionProvider = bridge.sectionTextProvider else {
            // 静默返回过一次，结果是界面上「点了摘要，什么都没发生」——
            // 这种沉默是最难查的一类缺陷，所以哪怕原因很边缘也要说出来。
            phase = .failed("当前文档不支持按节提取正文，无法生成摘要。")
            return
        }

        // 这一节的范围 = 本条的位置 到 下一条之前。
        // 用「下一条」而不是「固定页数」是因为目录本身就是分节结果，
        // 它的边界信息比任何启发式都准。
        let start = current.entries[index].unitIndex
        let nextStart = current.entries.indices.contains(index + 1)
            ? current.entries[index + 1].unitIndex
            : nil
        let end = max(start, (nextStart ?? unitCount) - 1)

        summarizing.insert(entry.id)
        let token = UUID()
        summaryTokens[entry.id] = token

        summaryTasks[entry.id] = Task { [weak self] in
            guard let self else { return }

            // 不管从哪条路径退出，条目都得从「正在生成」里摘掉——
            // 漏掉任何一个分支，那条行上的转圈就会永远转下去。
            defer { self.finishSummarizing(entry.id, token: token) }

            let text = await sectionProvider(start, end)
            guard !Task.isCancelled else { return }

            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                self.phase = .failed("「\(entry.title)」这一段没有可用于摘要的文本。")
                return
            }

            let locatorLabel = "第 \(start + 1)–\(end + 1) \(self.unitName)"

            let messages = PromptLibrary.entrySummaryMessages(
                metadata: metadata,
                entryTitle: entry.title,
                locatorLabel: locatorLabel,
                text: text
            )

            do {
                let summary = try await self.complete(messages: messages, config: config)
                guard !Task.isCancelled, self.validateSource() else { return }

                let cleaned = Self.cleanSummary(summary)
                if cleaned.isEmpty {
                    self.phase = .failed("模型没有返回摘要内容。")
                } else if let idx = self.outline?.entries.firstIndex(where: { $0.id == entry.id }) {
                    self.outline?.entries[idx].summary = cleaned
                    self.pendingReveal.insert(entry.id)
                    self.persist()
                }
            } catch {
                guard !Task.isCancelled else { return }
                self.phase = .failed(Self.describe(error))
            }
        }
    }

    /// 中止某一条的摘要生成。
    ///
    /// 单条摘要也要能取消：这是一次**要花钱**的请求，用户点了才发现选错条目时，
    /// 只能干等它跑完是不合理的（关掉侧栏也没用，任务还在跑）。
    func cancelSummary(id: String) {
        summaryTasks[id]?.cancel()
        finishSummarizing(id)
    }

    private func finishSummarizing(_ id: String, token: UUID? = nil) {
        if let token, summaryTokens[id] != token { return }
        summaryTasks.removeValue(forKey: id)
        summaryTokens.removeValue(forKey: id)
        summarizing.remove(id)
    }

    /// 中止骨架生成（工具栏「取消」走这里）。
    func cancel() {
        generationTask?.cancel()
        generationTask = nil
        if phase.isWorking { phase = .idle }
    }

    /// 中止全部在跑的任务。切文档、丢弃目录时用——
    /// 那时旧文档的摘要即使跑完也写不到任何地方去，白白花钱。
    func cancelAllWork() {
        generationTask?.cancel()
        generationTask = nil
        for (_, task) in summaryTasks { task.cancel() }
        summaryTasks = [:]
        summaryTokens = [:]
        summarizing = []
        pendingReveal = []
        if phase.isWorking { phase = .idle }
    }

    func clearFailure() {
        if case .failed = phase { phase = .idle }
    }

    func validateSource() -> Bool {
        guard let documentPath, let outline else { return false }
        guard outline.sourceVersion == Self.cacheVersion(path: documentPath) else {
            cancelAllWork()
            self.outline = nil
            phase = .failed("文件已发生变化，请重新生成目录。")
            return false
        }
        return true
    }

    static func activeEntryID(in outline: SmartOutline, unit: Int, selectedID: String?) -> String? {
        if let selected = outline.entries.first(where: { $0.id == selectedID && $0.unitIndex == unit }) {
            return selected.id
        }
        return outline.entries.last { $0.unitIndex <= unit }?.id
    }

    /// 取走「该自动展开」的条目；取过一次之后不再返回。
    func consumePendingReveal() -> Set<String> {
        let taken = pendingReveal
        pendingReveal = []
        return taken
    }

    /// 丢弃这份目录（含磁盘缓存）。换文档后重来用。
    func discard() {
        cancelAllWork()
        outline = nil
        phase = .idle
        persist()
    }

    // MARK: - 缓存

    private func loadCached() {
        guard let documentPath else { return }
        let url = AppPaths.smartOutlineFile(forPath: documentPath)
        guard let data = try? Data(contentsOf: url),
              let cached = try? JSONDecoder().decode(SmartOutline.self, from: data) else { return }
        guard cached.sourceVersion == Self.cacheVersion(path: documentPath), cached.sourceVersion != nil,
              cached.isValid(forUnitCount: cached.sourceUnitCount) else {
            phase = .failed("旧目录尚未核对原文位置，请重新生成。")
            return
        }
        outline = cached
        // 先按缓存里的单元数记下来：等阅读视图报上真实单元数后再校正一次。
        unitCount = cached.sourceUnitCount
    }

    private func persist() {
        guard let documentPath else { return }
        let url = AppPaths.smartOutlineFile(forPath: documentPath)
        guard let outline else {
            try? FileManager.default.removeItem(at: url)
            return
        }
        guard let data = try? JSONEncoder().encode(outline) else { return }
        PersistFile.write(data, to: url, label: "smart-outline.json")
    }

    // MARK: - 工具

    private static func cacheVersion(path: String) -> String? {
        (try? DocumentSourceVersion.current(path: path)).map { "outline-headings-3:" + $0 }
    }

    private func complete(messages: [AIMessage], config: AIProviderConfig) async throws -> String {
        if let completion { return try await completion(messages, config) }
        let provider = OpenAICompatibleProvider(config: config,
            apiKey: AICredentialStore.read(account: config.keychainAccount) ?? "")
        return try await provider.completeText(messages: messages)
    }

    /// 摘要是要贴在侧栏里给眼睛看的，模型却很爱在前后加一句「好的，以下是摘要：」。
    /// 在这里清掉，而不是指望提示词——提示词已经要求过了，它不听只能兜住。
    private static func cleanSummary(_ raw: String) -> String {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)

        let boilerplate = [
            "好的，以下是摘要：", "好的，以下是这一节的摘要：", "以下是摘要：",
            "摘要如下：", "摘要：", "这一节的摘要如下："
        ]
        for prefix in boilerplate where text.hasPrefix(prefix) {
            text = String(text.dropFirst(prefix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
            break
        }

        return text
    }

    private static func describe(_ error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }
}
