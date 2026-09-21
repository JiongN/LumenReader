import SwiftUI
import LumenKit

// MARK: - Bubble 的容错解码

/// `Bubble` 的容错解码必须写在 **extension** 里，不能写进 struct 本体。
///
/// 这不是风格问题，是 Swift 的硬规则：**类型本体里只要声明了任何一个初始化器，
/// 逐成员初始化器就不再合成**。`init(from:)` 一旦写进 `Bubble` 本体，全仓所有
/// `Bubble(role:text:…)` 立刻报「missing argument for parameter 'from' in call」
/// —— 本轮真的这么踩了一次，62 个编译错误全部由这一处级联而来。
/// 放进 extension 则保留逐成员构造器，`CodingKeys` 与 `encode(to:)` 照常合成。
///
/// 之所以要容错解码（README 硬约束第 2 条）：**数组里只要有一个气泡缺字段，
/// 整条 `[Bubble]` 就会解码失败、用户整本对话全丢**。所以每个字段都写成
/// `(try? decode) ?? 默认值`，任一键缺失都不影响其余气泡。
extension AIChatModel.Bubble {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? c.decode(UUID.self, forKey: .id)) ?? UUID()
        role = (try? c.decode(Role.self, forKey: .role)) ?? .user
        text = try c.decodeIfPresent(String.self, forKey: .text) ?? ""
        reasoning = try c.decodeIfPresent(String.self, forKey: .reasoning) ?? ""
        progress = (try? c.decode(String.self, forKey: .progress)) ?? ""
        citations = (try? c.decode([DocumentLocator].self, forKey: .citations)) ?? []
        taskTitle = (try? c.decode(String.self, forKey: .taskTitle)) ?? ""
        failed = (try? c.decode(Bool.self, forKey: .failed)) ?? false
        sourceDocPath = try? c.decodeIfPresent(String.self, forKey: .sourceDocPath)
    }
}

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
        /// 这条气泡是由「哪一份文档」的提问产生的。
        ///
        /// 全局共享会话之后，一条回答的引用很可能指向**另一本书**——光看回答本身分不出。
        /// 把来源记到**每一条气泡**上，才能在 `citationRow` 精确判断「这个引用是不是指向当前这本书」，
        /// 决定引用按钮能不能点（见 `ConversationCitationPolicy`）。`nil` 表示来源未知
        /// （比如从旧版本迁移来的会话、或是一段没有文档上下文的整书总结）。
        var sourceDocPath: String?

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

    /// 一次请求的完整参数快照。
    ///
    /// 存在的理由很具体：用户在 AI 面板上换了模型 / 模板 / Agent 之后，
    /// 想对**当前同一段内容**立刻看到效果，只能重新划词再问一遍——
    /// 而划的那段可能已经滚走了。记下参数就能原样重跑（见 `rerunLast`）。
    ///
    /// 字段刻意按「足够重跑」而非「尽量少」来选：少记一个（比如 `context`）
    /// 就会出现「重跑出来的回答和第一次不一样，因为给模型的材料变了」——
    /// 那正是这个功能最容易被认为坏了的地方。
    struct RequestSnapshot {
        var task: AITask
        var selection: ReaderSelection?
        var metadata: DocumentMetadata
        var locatorLabel: String
        var context: String
        var locator: DocumentLocator
        var citations: [DocumentLocator]
        var config: AIProviderConfig
        var memory: String
        var translateTarget: String
        var template: PromptTemplate?
        var agent: AgentConfig?
        /// 请求发生时的那份技能库。Agent 上只存技能 id，回放时要靠**当时**这一份
        /// 才知道技能要求是什么——不记的话，重跑出来的回答会和第一次不一样。
        var skills: [AgentSkill] = []
        /// 输入框上的「联网检索」手动开关
        var webSearchEnabled: Bool
    }

    /// 最近一次请求的快照。`nil` 表示没有可重跑的请求。
    private var lastRequest: RequestSnapshot?

    /// 能不能重跑上一条。流式输出期间禁用——重跑也是一次真实请求，
    /// 两条请求同时飞会互相抢同一个气泡。
    var canRerunLast: Bool { lastRequest != nil && !isStreaming }

    /// 喂给下一轮的历史消息条数。**应当恒为偶数**（只收完整的「问—答」对子）。
    ///
    /// 暴露给自检用：`--rerun-report` 靠它断言「重跑没有把 history 叠成两份」——
    /// 那正是「重跑之后模型开始答非所问」的根因，而它在界面上完全看不出来。
    var historyMessageCount: Int { history.count }

    private var history: [AIMessage] = []
    private var streamTask: Task<Void, Never>?

    /// 全局共享的会话仓库。本模型是「活动会话控制器」：
    /// `bubbles` 是活动会话的内存活副本（流式期间每 40ms 改一次，不能直接从 store 算，
    /// 否则每秒 25 次写盘），只有落到几个固定「落盘点」时才会写穿 `store`。
    let store: ConversationStore

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

    // MARK: - 初始化

    init(store: ConversationStore) {
        self.store = store
    }

    // MARK: - 活动会话控制

    /// 从 `store` 载入当前活动会话的 `bubbles` + `history`，并清掉草稿等瞬时状态。
    ///
    /// 取代了原 `bind(to:)` 的载入职责——全局共享会话之后不再「按文档绑定」，
    /// 而是在切换活动会话 / 新建会话后从这里把对应的那一份拉进来。
    func showActiveConversation() {
        let conv = store.activeConversation
        bubbles = conv?.bubbles ?? []
        // 载入时按「只收完整对子」规则从气泡重建 history（见 `rebuildHistory`）。
        history = Self.rebuildHistory(from: bubbles)
        draft = ""
        pendingDelta = ""
        lastRequest = nil
        streamingID = nil
        isStreaming = false
    }

    /// 开启一个全新会话：先 flush 当前（写盘），再建、切过去、载入空副本。
    /// 返回新会话 id，供自检回读。
    @discardableResult
    func newConversation(sourcePath: String?, sourceTitle: String?) -> UUID {
        flushActiveToStore()
        let id = store.createConversation(sourcePath: sourcePath, sourceTitle: sourceTitle)
        store.setActive(id)
        showActiveConversation()
        return id
    }

    /// 切到指定历史会话：先 flush 当前，再切。
    func switchTo(_ id: UUID) {
        guard store.conversation(id: id) != nil else { return }
        flushActiveToStore()
        store.setActive(id)
        showActiveConversation()
    }

    /// 只清当前会话的内容，会话本身留在列表里。
    func clearActive() {
        stop()
        bubbles = []
        history = []
        lastRequest = nil
        pendingDelta = ""
        draft = ""
        flushActiveToStore()
    }

    /// 删除当前会话（删除项走二次确认，见 AIPanelView / ActionEntries）。
    func deleteActive() {
        guard let id = store.activeID else { return }
        flushActiveToStore()
        store.delete(id: id)
        showActiveConversation()
    }

    /// 重命名当前会话（`nil` 表示清除自定义标题、回退到自动标题）。
    func renameActive(_ title: String?) {
        guard let id = store.activeID else { return }
        store.rename(id: id, title)
    }

    /// 这条引用在当前文档里能不能跳（跨文档引用降级，正确性红线）。
    ///
    /// 直接调纯函数 `ConversationCitationPolicy`（便于自检表驱动断言）。
    /// 这里不传气泡级来源（传 `nil`），只用会话的出身文档判定——
    /// 适用于「整个活动会话」粒度的查询。
    func isCitationActive(_ locator: DocumentLocator, currentDocPath: String?) -> Bool {
        let conv = store.activeConversation
        return ConversationCitationPolicy.isActive(
            locator: locator,
            bubbleDocPath: nil,
            conversationDocPath: conv?.sourceDocPath,
            currentDocPath: currentDocPath
        )
    }

    /// 气泡 footer 引用编号按钮用：带上这条气泡自己的来源文档路径，
    /// 比会话级判定更精确（一次会话里可能从不同书问过，逐条气泡的出处才准）。
    func isCitationActive(
        _ locator: DocumentLocator,
        bubbleDocPath: String?,
        currentDocPath: String?
    ) -> Bool {
        let conv = store.activeConversation
        return ConversationCitationPolicy.isActive(
            locator: locator,
            bubbleDocPath: bubbleDocPath,
            conversationDocPath: conv?.sourceDocPath,
            currentDocPath: currentDocPath
        )
    }

    /// 把当前内存里的气泡 + history 写穿到 store（并落盘）。
    ///
    /// **不变量**：只有这几个「落盘点」会调用它——`submit`（用户气泡已追加后）、
    /// `finishStreaming`、`stop`、`clearActive`、`deleteActive`、`switchTo`、`newConversation`。
    /// 流式过程中（每 40ms 一次的 `appendDelta`）**绝不**调用它，否则会变成每秒 25 次写盘。
    private func flushActiveToStore() {
        guard let id = store.activeID else { return }
        store.replaceContent(id: id, bubbles: bubbles, history: history)
    }

    /// 复原历史时只收「一问一答都完整」的对子。
    ///
    /// 上一轮如果因为网络错误或用户点了停止而失败，存档里就只剩一条 user 消息。
    /// 把它单独放进 history，模型会看到一个没人回答的问题，于是在新一轮里
    /// 又把那个旧问题答一遍——用户会觉得"我明明问了别的，它却答非所问"。
    ///
    /// `AIChatModel` 与 `ConversationStore` 共用**同一份**实现：迁移旧 `chats.json` 与
    /// 载入活动会话都走这里，不抄两遍，避免两处规则慢慢漂移。
    static func rebuildHistory(from bubbles: [AIChatModel.Bubble]) -> [AIMessage] {
        var restored: [AIMessage] = []
        var pendingQuestion: String?

        for bubble in bubbles where bubble.role != .notice {
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

        return restored
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
        template: PromptTemplate? = nil,
        agent: AgentConfig? = nil,
        skills: [AgentSkill] = [],
        webSearchEnabled: Bool = false,
        sourcePath: String? = nil,
        sourceTitle: String? = nil
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

        let snapshot = RequestSnapshot(
            task: task,
            selection: selection,
            metadata: metadata,
            locatorLabel: locatorLabel,
            context: context,
            locator: locator,
            citations: citations ?? selection.map { [$0.locator] } ?? [locator],
            config: config,
            memory: memory,
            translateTarget: translateTarget,
            template: template,
            agent: agent,
            skills: skills,
            webSearchEnabled: webSearchEnabled
        )
        lastRequest = snapshot

        // ⚠️ 这里是 `citations` 的默认值解析点：重跑时必须沿用第一次算出来的引用，
        // 否则「重新生成」之后引用会变（第一次带选区、重跑时选区已经没了）。
        var userBubble = Bubble(
            role: .user,
            text: Self.userDisplayText(task: task, selection: selection),
            taskTitle: task.title
        )
        // 把发起文档路径记到这条气泡上：跨文档引用降级依赖它精确判定
        // 「这个引用是不是指向当前这本书」（见 `ConversationCitationPolicy`）。
        userBubble.sourceDocPath = sourcePath
        bubbles.append(userBubble)

        // 会话本身的 sourceDocPath 只在第一次提问时记下（它的「出身」文档）；
        // 之后即使切到别的书问，会话的出身也保持不变——逐条气泡的 sourceDocPath 才记录每次提问的真实出处。
        if let path = sourcePath, let id = store.activeID,
           store.conversation(id: id)?.sourceDocPath == nil {
            store.setSourceDocPath(id: id, path: path, title: sourceTitle)
        }

        // 落盘点：用户气泡已追加，写穿 store（含自动标题更新）。
        flushActiveToStore()
        startAnswer(snapshot)
    }

    /// 重跑上一条请求（换模型 / 模板 / Agent 之后对**同一段内容**再看一次）。
    ///
    /// 三条刻意的取舍：
    ///
    /// 1. **替换而不是追加**上一条回答。追加会让气泡序列变成「问、答、答」，
    ///    而 `finishStreaming` 是按「最后一个 user + 最后一个 assistant」配对的，
    ///    两条答会各自和同一个问配成一对，history 里于是出现重复的一问。
    /// 2. **重跑前先把上一轮那一对从 history 里摘掉**，重跑成功后再由
    ///    `finishStreaming` 补回来。净效果是一对换一对，history 的
    ///    「只收完整对子」这条规则没有被打破。
    /// 3. 走的是 `submit` 里同一条 `startAnswer`，因此联网检索、进度文案、
    ///    可中止（stop）这些行为与首次请求完全一致。
    func rerunLast() {
        guard let snapshot = lastRequest, !isStreaming else { return }
        guard snapshot.config.isConfigured else {
            appendNotice("「\(snapshot.config.name)」当前不可用。请先在「设置 → AI」里完成配置。")
            return
        }

        // 摘掉上一轮那一对（顺序不能反：先答后问）
        if history.last?.role == .assistant { history.removeLast() }
        if let lastUser = bubbles.last(where: { $0.role == .user })?.text,
           history.last?.role == .user, history.last?.content == lastUser {
            history.removeLast()
        }

        // 用一条**新的**回答替换旧的：文本、推理、进度、失败标记都要是干净的，
        // 否则用户会在新答案下面看到上一次的「⚠️ 请求超时」。
        if let lastIndex = bubbles.indices.last, bubbles[lastIndex].role == .assistant {
            bubbles.remove(at: lastIndex)
        }

        startAnswer(snapshot)
    }

    /// 建一条 assistant 气泡并开始请求。`submit` 与 `rerunLast` 共用。
    private func startAnswer(_ snapshot: RequestSnapshot) {
        var answer = Bubble(role: .assistant, text: "", taskTitle: snapshot.task.title)
        answer.citations = snapshot.citations
        // 把「提问出自哪份文档」传递到回答气泡上：回答里的引用应当按提问时的那本书判定
        // 能否跳回（见 `ConversationCitationPolicy`）。否则一份会话里从不同书问过之后，
        // 会按会话「出身」文档误判，把本可跳的引用关掉、或把该关的放过去。
        answer.sourceDocPath = bubbles.last(where: { $0.role == .user })?.sourceDocPath
            ?? store.activeConversation?.sourceDocPath
        bubbles.append(answer)
        streamingID = answer.id
        isStreaming = true
        pendingDelta = ""
        lastFlush = Date.distantPast

        // 消息构造挪进 Task：开了联网检索的 Agent 要先等检索回来，
        // 而那几秒里界面不该是「正在思考…」——那是模型在想的措辞，
        // 用户该看到的是「正在联网检索文献…」，否则会以为卡住了。
        streamTask = Task { [weak self] in
            guard let self, !Task.isCancelled else { return }

            var webContext = ""
            // 触发条件两路：Agent 自带「要查文献」，或输入框上的手动开关。
            if snapshot.agent?.usesWebSearch == true || snapshot.webSearchEnabled {
                let query = Self.webSearchQuery(task: snapshot.task, selection: snapshot.selection, metadata: snapshot.metadata)
                if !query.isEmpty {
                    self.setProgress("正在联网检索文献…")
                    let outcome = await WebLiteratureSearch.search(query: query)
                    guard !Task.isCancelled else { return }
                    webContext = WebLiteratureSearch.promptBlock(outcome)
                    if outcome.isEmpty {
                        self.setProgress("这次联网没有检索到文献，改为只依据原文回答")
                    } else {
                        self.setProgress("已检索到 \(outcome.hits.count) 篇文献，正在阅读…")
                    }
                    if !outcome.failures.isEmpty {
                        NSLog("%@", "[Lumen] 文献检索部分失败：\(outcome.failures.joined(separator: "；"))")
                    }
                }
            }

            let messages = PromptLibrary.messages(
                task: snapshot.task,
                selection: snapshot.selection,
                metadata: snapshot.metadata,
                locatorLabel: snapshot.locatorLabel,
                context: snapshot.context,
                memory: snapshot.memory,
                history: history,
                translateTarget: snapshot.translateTarget,
                template: snapshot.template,
                agent: snapshot.agent,
                skills: snapshot.skills,
                webContext: webContext
            )

            self.setProgress("")
            var failure: String?
            do {
                try await self.streamIntoBubble(messages: messages, config: self.effectiveConfig(for: snapshot))
            } catch {
                if !Task.isCancelled {
                    failure = Self.describe(error)
                }
            }
            guard !Task.isCancelled else { return }
            self.flushDelta(force: true)
            self.finishStreaming(failure: failure)
        }
    }

    /// 这次请求实际使用的服务商配置：Agent 带了温度覆盖时按它改一份副本。
    ///
    /// 改的是**副本**而不是 `config` 本身：快照里存的是设置里的那一份，
    /// 直接改它会把用户的服务商设置一起改掉——那是「换了个 Agent，结果
    /// 设置页里的温度也变了」这种最难解释的不一致。
    ///
    /// 不标 `private` 是为了让 `--agent-report` 能直接喂参数进去断言
    /// （温度有没有生效，在这台没有视觉通道的机器上只能这样验）。
    func effectiveConfig(for snapshot: RequestSnapshot) -> AIProviderConfig {
        guard let override = snapshot.agent?.temperatureOverride else { return snapshot.config }
        var config = snapshot.config
        config.temperature = min(
            max(override, AgentConfig.temperatureRange.lowerBound),
            AgentConfig.temperatureRange.upperBound
        )
        return config
    }

    /// 联网检索用的查询词。
    ///
    /// 取「读者真正在问的那句话」：有划词时用划的词（他关心的是这一段），
    /// 没有划词时用提问本身，再退到书名 + 当前页的定位标签。
    /// 不把整页正文丢进去——学术库按关键词匹配，一页几百字反而检索不到东西。
    static func webSearchQuery(task: AITask, selection: ReaderSelection?, metadata: DocumentMetadata) -> String {
        if case .ask(let question) = task {
            let trimmed = question.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return PromptLibrary.truncate(trimmed, limit: 120) }
        }
        if let selection, selection.isUsable {
            return PromptLibrary.truncate(selection.text, limit: 120)
        }
        return metadata.title.trimmingCharacters(in: .whitespacesAndNewlines)
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
        template: PromptTemplate? = nil,
        agent: AgentConfig? = nil,
        skills: [AgentSkill] = [],
        webSearchEnabled: Bool = false,
        sourcePath: String? = nil,
        sourceTitle: String? = nil
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
            template: template,
            agent: agent,
            skills: skills,
            webSearchEnabled: webSearchEnabled,
            sourcePath: sourcePath,
            sourceTitle: sourceTitle
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

        bubbles.append(Bubble(role: .user, text: "总结全文", taskTitle: "总结全文"))
        var answer = Bubble(role: .assistant, text: "", taskTitle: "总结全文")
        answer.citations = []
        bubbles.append(answer)
        streamingID = answer.id
        isStreaming = true
        pendingDelta = ""

        // 整本书总结不走 `submit`，也就没有可原样重跑的快照：
        // 它要么一次问完、要么先逐片 map 再 reduce（取决于篇幅），
        // 重跑时若走 `startAnswer` 会退化成「把上一次的摘要再总结一遍」——
        // 那不是用户要的「重新生成」。所以这里清掉，界面上也不给这个入口。
        lastRequest = nil

        let totalCharacters = slices.reduce(0) { $0 + $1.text.count }

        streamTask = Task { [weak self] in
            guard let self, !Task.isCancelled else { return }
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
                    let capped = Self.balancedSummarySlices(slices, limit: self.maxMapSlices)
                    var summaries: [String] = []

                    for (index, slice) in capped.enumerated() {
                        try Task.checkCancellation()
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

                    guard !Task.isCancelled else { return }

                    self.setProgress("正在汇总结论…")
                    var reduceConfig = config
                    reduceConfig.maxTokens = max(config.maxTokens, 3000)

                    let messages = PromptLibrary.messages(
                        task: .summarize(scope: .wholeDocument),
                        selection: nil,
                        metadata: metadata,
                        locatorLabel: "",
                        context: summaries.joined(separator: "\n\n"),
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

            guard !Task.isCancelled else { return }
            self.setProgress("")
            self.flushDelta(force: true)
            self.finishStreaming(failure: failure)
        }
    }

    private func join(_ slices: [(label: String, text: String)]) -> String {
        slices.map { "【\($0.label)】\n\($0.text)" }.joined(separator: "\n\n")
    }

    /// 超长文档不再截掉第 31 段以后内容；将相邻切片均衡并组，保证首尾与中部都覆盖。
    private static func balancedSummarySlices(
        _ slices: [(label: String, text: String)],
        limit: Int
    ) -> [(label: String, text: String)] {
        guard slices.count > limit, limit > 0 else { return slices }
        return SummarySlicePlanner.ranges(itemCount: slices.count, maximumGroups: limit).map { range in
            let group = Array(slices[range])
            let label = group.count == 1
                ? group[0].label
                : "\(group.first!.label) – \(group.last!.label)"
            let perSlice = SummarySlicePlanner.characterBudget(
                itemCount: group.count,
                total: 8_500
            )
            let text = group.map {
                "【\($0.label)】\n" + PromptLibrary.truncate($0.text, limit: perSlice)
            }.joined(separator: "\n\n")
            return (label, text)
        }
    }

    // MARK: - 控制

    func stop() {
        streamTask?.cancel()
        streamTask = nil
        flushDelta(force: true)
        finishStreaming(failure: nil)
    }

    /// 清除当前会话内容（旧名，保留作兼容别名）。
    ///
    /// 语义已收窄为「只清内容、会话仍留在列表里」，与 ActionEntries 里的
    /// 「清空当前会话」文案一致——不再像旧 `clearChat` 那样「清空对话」让人误以为整个会话没了。
    func clear() {
        clearActive()
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
            apiKey: AICredentialStore.read(account: config.keychainAccount) ?? ""
        )
    }

    /// 把流式增量写进当前气泡。
    private func streamIntoBubble(messages: [AIMessage], config: AIProviderConfig) async throws {
        try Task.checkCancellation()
        let provider = makeProvider(config)
        for try await event in provider.stream(messages: messages) {
            try Task.checkCancellation()
            switch event {
            case .delta(let text):      appendDelta(text)
            case .reasoning(let text):  appendReasoning(text)
            case .finished:             break
            }
        }
        try Task.checkCancellation()
        flushDelta(force: true)
    }

    /// 一次性取回完整回复（map 阶段用，不需要逐字展示）。
    private func complete(messages: [AIMessage], config: AIProviderConfig) async throws -> String {
        try Task.checkCancellation()
        let provider = makeProvider(config)
        var output = ""
        for try await event in provider.stream(messages: messages) {
            try Task.checkCancellation()
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

        // 落盘点：回答完成（成功或失败）后写穿 store。流式过程中不在此，见 `flushActiveToStore` 注释。
        flushActiveToStore()
    }

    private func appendNotice(_ text: String) {
        bubbles.append(Bubble(role: .notice, text: text))
    }

    // MARK: - 自检注入

    /// 自检专用：塞一条**假的 AI 回答**（`--demo-answer 1`）。
    ///
    /// 存在的理由：长 URL / 长代码行会不会横向撑破面板，只有真有这种内容才看得出来，
    /// 而自检跑在离线环境里、模型根本不会返回任何东西。注入的内容刻意挑三种
    /// 「不好断行」的形态各一份：
    /// - 一条 120+ 字符、没有任何空格的 URL；
    /// - 一行 180+ 字符的代码；
    /// - 一个 100 字符的连续标识符。
    /// 三者都不许把面板撑宽——URL 与标识符靠 `Text` 的字符级断行，代码行走
    /// 自己的横向滚动区（`MarkdownText` 的 `.code` 分支）。
    func seedDemoAnswer() {
        bubbles = [
            Bubble(role: .user, text: "这篇论文的复现材料在哪？把关键实现也贴一下。"),
            Bubble(role: .assistant, text: Self.demoAnswerText)
        ]
        // 跟着滚到底部：注入后应当停在最后一条上（followTail 的默认行为），
        // 这样截图一定能拍到注入内容，而不是停在旧位置。
        draft = ""
    }

    static let demoAnswerText = """
    ## 复现材料

    - 论文主页（长 URL，无空格，不许撑破面板）：
      https://openreview.net/forum?id=AbCdEf1234567890AbCdEf1234567890&referrer=%5Bthe%20profile%20of%20a%20user%5D%28%2Fprofile%3Fid%3D~Some_Authors1%29
    - 数据集标识符（100 字符连续 token）：
      dataset_v3_final_augmented_2026_09_17_baseline_reproduction_without_curriculum_learning_shard_00042

    关键实现（一行 180+ 字符，走横向滚动，不许撑破面板）：

    ```python
    def reproduce(model, dataset, seed=42, temperature=0.7, top_p=0.95, max_new_tokens=2048, batch_size=8, gradient_accumulation_steps=4, use_flash_attention_2=True):
        return model.generate(dataset, seed=seed, temperature=temperature, top_p=top_p, batch_size=batch_size)
    ```

    第 3 步的说明也刻意写长一点：这一段是普通段落，用来核对中文长句在面板
    下限宽度下的换行是否自然、有没有出现「一个字一行」的挤换行。
    """

    // MARK: - 展示文本

    // MARK: - 自检专用（不变量验证）

    /// 自检专用：在不走真实网络的前提下造出「流式进行中」的状态。
    ///
    /// 起一个空的 assistant 气泡并标记 streaming，使后续 `appendFakeDelta` 有落点。
    /// 用途：验证「流式期间不写盘」这条不变量（见 `ConversationAudit`）。
    func beginFakeStream() {
        guard streamingID == nil else { return }
        let bubble = Bubble(role: .assistant, text: "", taskTitle: "自检")
        bubbles.append(bubble)
        streamingID = bubble.id
        isStreaming = true
        pendingDelta = ""
        lastFlush = Date.distantPast
    }

    /// 自检专用：模拟一次流式增量（只进内存 `pendingDelta`，**不写盘**）。
    func appendFakeDelta(_ text: String) {
        appendDelta(text)
    }

    /// 自检专用：结束假流式，走与真实 `finishStreaming` 同一条落盘路径。
    func endFakeStream() {
        flushDelta(force: true)
        finishStreaming(failure: nil)
    }

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
            return "总结当前页/章"
        case .summarize(.wholeDocument):
            return "总结全文"
        case .custom(let prompt):
            return prompt
        }
    }
}
