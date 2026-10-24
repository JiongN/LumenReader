import SwiftUI
import AppKit
import LumenKit

/// AI 侧边面板。
///
/// 引用与原文跳转由当前阅读方式的「原文依据」技能控制。
struct AIPanelView: View {

    private enum QuestionScope: String, CaseIterable, Identifiable {
        case currentUnit
        case wholeDocument
        case compareDocument
        var id: String { rawValue }
        var title: String {
            switch self {
            case .currentUnit: return "当前页/章"
            case .wholeDocument: return "全文"
            case .compareDocument: return "双文档"
            }
        }
        var icon: String {
            switch self {
            case .currentUnit: return "doc.text"
            case .wholeDocument: return "doc.text.magnifyingglass"
            case .compareDocument: return "rectangle.on.rectangle.angled"
            }
        }
    }

    @EnvironmentObject private var state: AppState
    @EnvironmentObject private var bridge: ReaderBridge
    @EnvironmentObject private var chat: AIChatModel
    /// 本面板所属标签的会话：划词请求按标签投递，不能读当前活动标签的代理。
    @EnvironmentObject private var session: ReaderSession
    @EnvironmentObject private var settings: SettingsStore
    @Environment(\.openSettings) private var openSettings

    @State private var transcriptHeight: CGFloat = 600
    /// Agent 编辑器
    @State private var isAgentEditorVisible = LaunchOptions.flag("--reading-mode-editor")
    /// 普通问题默认只读当前页/章；全文与双文档比较必须由用户明确选择。
    @State private var questionScope: QuestionScope = LaunchOptions.aiQuestionScope == "compare"
        ? .compareDocument
        : (LaunchOptions.aiQuestionScope == "whole" ? .wholeDocument : .currentUnit)
    @State private var comparisonSessionID: UUID?
    @State private var didWarnDraftLimit = false
    @State private var chartImage: AIImage?
    @State private var chartPickerVisible = false
    @State private var chartLoading = false
    private static let maxDraftCharacters = 6_000

    var body: some View {
        // 卡顿自检：body 每次求值都记一次。必须写在这里（而不是做成 ViewModifier）——
        // 修饰符对「值相等的节点」会被复用，tick 只在首帧跑一次，计数恒为 0（本轮踩过）。
        let _ = Jank.tick(.aiPanelBody)
        VStack(spacing: 0) {
            header
            conversationScope
            divider
            transcript
            divider
            composer
        }
        .background(DS.Palette.surfaceSunken)
        .onChange(of: session.pendingAIRequest, initial: true) { _, request in
            guard let request else { return }
            consume(request)
            session.pendingAIRequest = nil
        }
        .sheet(isPresented: $isAgentEditorVisible) {
            AgentEditor()
                .environmentObject(state)
        }
        .sheet(isPresented: $chartPickerVisible) {
            if let image = chartImage { ChartRegionPicker(image: image) { runChart($0) } }
        }
    }

    private var divider: some View {
        Rectangle().fill(DS.Palette.separator).frame(height: 1)
    }

    // MARK: - 头部

    /// 面板内三块（header / transcript / composer）统一的横向内边距。
    ///
    /// 14 而不是 `DS.Space.m`（12）：panel 默认 380、下限 300，正文与气泡贴到边缘会显得局促；
    /// 而 16 在 300pt 时又把 footer 行的可用宽度压到 300−32−28=240pt 以下，放不下三个
    /// 引用编号加四个动作按钮。14 是「看着不挤」与「300pt 时 footer 仍放得下」的交点。
    private static let contentInset: CGFloat = 14

    private static let headerIconWidth: CGFloat = 32

    private var header: some View {
        HStack(spacing: DS.Space.xs) {
            webSearchToggle
            HStack(spacing: DS.Space.xs) {
                providerMenu.layoutProbe("aiModelChip")
                agentMenu
            }
            .frame(maxWidth: .infinity)
            conversationMenu
        }
        .padding(.horizontal, Self.contentInset)
        .padding(.vertical, DS.Space.xs)
    }

    /// 全局会话可跨书继续提问；始终明示当前问题读取哪本书。
    /// 会话来源只在不同于当前文档时显示，避免把“会话创建于 A”误读为“现在仍在读 A”。
    private var conversationScope: some View {
        let current = session.document.displayTitle
        let conversation = state.services.conversationStore.activeConversation
        let source = conversation?.sourceDocPath
        let isOtherDocument = source != nil && source != session.document.id
        let origin = conversation?.sourceDocTitle
            ?? source.map { URL(fileURLWithPath: $0).deletingPathExtension().lastPathComponent }
            ?? ""
        let label = isOtherDocument
            ? "当前文档：\(current) · 会话始于：\(origin)"
            : "当前文档：\(current)"

        return HStack(spacing: DS.Space.xs) {
            Text(label)
            .font(.system(size: 11))
            .foregroundStyle(DS.Palette.textSecondary)
            .lineLimit(1)
            .truncationMode(.middle)
            .frame(maxWidth: .infinity, alignment: .leading)
            .help(label)
            PanelTextSizeControl(size: $settings.ui.aiTextSize, label: "AI 回复字号")
            if session.document.id.lowercased().hasSuffix(".pdf") {
                Button {
                    let path = session.document.id, page = bridge.currentUnitIndex
                    let conversationID = chat.store.activeID
                    chartLoading = true
                    Task {
                        defer { chartLoading = false }
                        do {
                            let image = try await PDFPageAssets.shared.image(path: path, pageIndex: page)
                            guard session.document.id == path else { return }
                            chartImage = image; chartPickerVisible = true
                        } catch {
                            if chat.store.activeID == conversationID { chat.appendNotice(error.localizedDescription) }
                        }
                    }
                } label: { Image(systemName: chartLoading ? "hourglass" : "chart.xyaxis.line") }
                .buttonStyle(.plain).help("框选并解读图表").disabled(chartLoading || chat.isStreaming)
            }
        }
        .padding(.horizontal, Self.contentInset)
        .padding(.bottom, DS.Space.xs)
    }

    /// planner 条目 + 「这一项之前要不要画分隔线」。首项之前不画。
    private var aiPanelEntries: [PanelMenuRow] {
        var result: [PanelMenuRow] = []
        var previousSection: Int?
        for entry in ActionEntries.entries(in: .aiPanel) {
            result.append(PanelMenuRow(entry: entry,
                                       showDivider: previousSection.map { $0 != entry.section } ?? false))
            previousSection = entry.section
        }
        return result
    }

    /// 把 planner 里的一条 AI 面板条目翻译成按钮（含可用性）。视图不做归属判断。
    @ViewBuilder
    private func aiPanelButton(_ entry: ActionEntry) -> some View {
        switch entry.id {
        case .summarizeUnit:
            Button(currentUnitSummaryTitle) { run(.summarize(scope: .currentUnit)) }
        case .summarizeAll:
            Button("总结全文") { summarizeWholeDocument() }
        case .rerunLast:
            // 「重新生成」是**付费动作**，所以只放在菜单与气泡 footer 里，
            // 不给键盘快捷键：一次误触的代价是一次真实的模型调用。
            Button(entry.title) { chat.rerunLast(settings: state.settingsStore, memory: state.aiMemoryPayload) }
                .disabled(!chat.canRerunLast)
        case .rememberSelection:
            Button(entry.title) { rememberSelection() }
                .disabled(!hasSelection)
        case .rememberCurrentUnit:
            Button(entry.title) { rememberCurrentUnit() }
                .disabled(bridge.isLoading)
        case .clearChat:
            Button(entry.title) { chat.clear() }
                .disabled(chat.bubbles.isEmpty)
        case .newConversation:
            Button(entry.title) { conversationNew() }
        case .renameConversation:
            Button(entry.title) { conversationRename() }
        case .deleteConversation:
            Button(entry.title) { conversationDelete() }
                .foregroundStyle(DS.Palette.danger)
        case .openAISettings:
            Button(entry.title) {
                openSettings()
                NSApp.activate(ignoringOtherApps: true)
            }
        default:
            // planner 里新增了 AI 面板条目却没在这里补 case：不静默（断言 + 可见兜底），
            // 否则菜单会悄悄少一项——不报错、不崩溃、自检也不会红。
            UnimplementedEntryView(entry: entry)
        }
    }

    // MARK: - 服务商与提示词

    /// 服务商 / 模型切换。放在头部第一行并紧邻联网开关。
    ///
    /// 从「点击跳设置页」改成菜单直选，解决的是一个很实际的摩擦：
    /// 读论文时常要在快模型和强模型之间来回切——随手问一句用便宜的，
    /// 细读论证用贵的。之前每切一次都要离开阅读、进设置、找到那一项、再切回来，
    /// 代价高到用户干脆不切，一直按最贵的那个跑。
    ///
    /// 面板下限 300pt 时模型名容易过长，所以这里**不加 `.fixedSize()`**：
    /// 文本截断（`.truncationMode(.middle)`）把完整名字交给 `.help`，
    /// 输入框因此不会被 chip 挤压。
    private var providerMenu: some View {
        let config = state.settingsStore.activeProvider
        let configured = config?.isConfigured ?? false
        let providers = state.settingsStore.ai.providers
        let modelLabel = config.map { $0.selectedModel.isEmpty ? $0.name : $0.selectedModel } ?? "未配置"

        return HStack(spacing: 4) {
            // 状态点在最左，和 Menu 并排——不能塞进 Menu 的 label 里（见 chipContent）
            statusDot(configured ? DS.Palette.success : DS.Palette.warning)

            Menu {
                if providers.isEmpty {
                    Button("尚未添加服务商") { openSettingsAndActivate() }
                } else {
                    ForEach(providers) { provider in
                        providerMenuEntry(provider)
                    }
                }

                Divider()

                Button("AI 与阅读设置…") { openSettingsAndActivate() }
            } label: {
                chipContent(
                    text: modelLabel,
                    // 限制可见文字宽度，避免长模型名挤掉右侧会话菜单。
                    maxTextWidth: 48
                )
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
        }
        // 胶囊外壳挂在 Menu 外面（挂在 label 里不落色，见 ChipShell 的注释）。
        // 放在 .frame(minWidth:) 之前，胶囊才会贴着内容。
        .modifier(ChipShell(minHeight: 36))
        // 不给 layoutPriority（输入框优先拿宽度），但**必须给最小宽度**——
        // 只靠 layoutPriority，可截断的文本会被压到 0 宽，chip 就整个消失了。
        .layoutPriority(0)
        .frame(minWidth: 0, maxWidth: .infinity)
        .help(configured
              ? "切换 AI 服务商 / 模型\n当前模型：\(modelLabel)"
              : "尚未配置 AI 服务商，点击开始配置")
    }

    /// 切换服务商沿用设置中已选模型，不展开服务商的完整模型目录。
    @ViewBuilder
    private func providerMenuEntry(_ provider: AIProviderConfig) -> some View {
        let isActive = state.settingsStore.ai.activeProviderID == provider.id

        Button {
            activate(provider)
        } label: {
            if isActive {
                Label("\(provider.name)（\(provider.selectedModel)）", systemImage: "checkmark")
            } else {
                Text("\(provider.name)（\(provider.selectedModel)）")
            }
        }
    }

    /// 单一阅读方式：阅读指令、技能与检索配置。
    private var agentMenu: some View {
        let agents = state.settingsStore.ai.agents
        let activeID = state.settingsStore.ai.activeAgentID
        let active = state.settingsStore.ai.activeReadingMode

        return Menu {
                Button {
                    state.settingsStore.ai.activeAgentID = nil
                    noteRerunAvailability("已切回默认阅读方式")
                } label: {
                    if activeID == nil {
                        Label("默认", systemImage: "checkmark")
                    } else {
                        Text("默认")
                    }
                }

                Divider()

                Button {
                    selectAgent(AgentConfig.mindMapMode)
                } label: {
                    Label("思维导图", systemImage: activeID == AgentConfig.mindMapMode.id ? "checkmark" : "point.3.connected.trianglepath.dotted")
                }

                ForEach(agents.filter { $0.id != AgentConfig.mindMapMode.id }) { agent in
                    Button {
                        selectAgent(agent)
                    } label: {
                        // 联网检索是「会走出去的动作」，标在菜单里让人一眼看见自己选的是哪一个
                        let suffix = agent.usesWebSearch ? "（联网）" : ""
                        if agent.id == activeID {
                            Label("\(agent.name)\(suffix)", systemImage: "checkmark")
                        } else {
                            Text("\(agent.name)\(suffix)")
                        }
                    }
                }

                Divider()

                Button("管理阅读方式…") { isAgentEditorVisible = true }
        } label: {
            chipContent(text: active?.name ?? "阅读方式",
                        icon: "person.crop.circle.badge.checkmark",
                        maxTextWidth: 90)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .modifier(ChipShell(minHeight: 36))
        .frame(minWidth: 0, maxWidth: .infinity)
        .help("阅读方式：\(active?.name ?? "默认")")
    }

    /// 头部「会话」切换菜单（全局共享会话之后新增）。
    ///
    /// 放在头部第一行右侧：当前活动会话的标题就是这枚 chip 的标签，
    /// 点开可在「新建会话 / 历史会话（最新在前、当前项带勾选）/ 重命名 / 删除」之间切换。
    ///
    /// 设计取舍（与 templateMenu / agentMenu 一致，见各自注释）：
    /// - 挂 `ChipShell` 兜底底色，标签里的 `.background` 在 borderlessButton 菜单上取不到；
    /// - **不挂** `.fixedSize()`：300pt 下限下整行溢出会把收起按钮顶出面板；改「可压缩 + 下限」，
    ///   超长会话标题截断、完整标题交给 `.help`；
    /// - 永不禁用：即使只有一条空会话，菜单也要能打开（新建 / 重命名 / 删除都还有意义）。
    private var conversationMenu: some View {
        let store = state.services.conversationStore
        let title = store.activeConversation?.displayTitle ?? "会话"
        return Menu {
            // 菜单项完全由 ConversationMenuPlanner 长出（顺序 / 勾选 / 分隔线都交给数据），
            // 自检才能逐条核对（见 ConversationAudit），而不是靠肉眼看原生菜单。
            ForEach(ConversationMenuPlanner.items(store: store, currentDocPath: state.document?.id), id: \.id) { item in
                switch item {
                case .newConversation:
                    Button(ActionEntries.title(of: .newConversation)) { conversationNew() }
                case .divider:
                    Divider()
                case .conversation(let id, let convTitle, let isActive):
                    Button {
                        // 点当前活动项：原地不动（避免一次无意义的 flush + 重载）。
                        guard !isActive else { return }
                        chat.switchTo(id)
                    } label: {
                        if isActive {
                            Label(convTitle, systemImage: "checkmark")
                        } else {
                            Text(convTitle)
                        }
                    }
                case .renameCurrent:
                    Button(ActionEntries.title(of: .renameConversation)) { conversationRename() }
                case .deleteCurrent:
                    Button(ActionEntries.title(of: .deleteConversation)) { conversationDelete() }
                }
            }
            Divider()
            ForEach(aiPanelEntries) { row in
                if row.showDivider { Divider() }
                aiPanelButton(row.entry)
            }
        } label: { compactHeaderIcon("bubble.left.and.text.bubble.right") }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .frame(width: Self.headerIconWidth, height: Self.headerIconWidth)
        .modifier(HeaderIconShell())
        .help("会话：\(title)")
        .layoutProbe("aiConversationMenu")
    }

    // MARK: - 会话管理动作

    /// 依据当前文档开一条全新会话（全局共享，来源记到「当前文档」以便跨文档引用判定）。
    private func conversationNew() {
        _ = chat.newConversation(
            sourcePath: state.document?.id,
            sourceTitle: state.document?.displayTitle
        )
    }

    /// 给当前会话起一个便于识别的名字（留空则回退到自动标题）。
    private func conversationRename() {
        guard chat.store.activeID != nil else { return }
        let current = chat.store.activeConversation?.displayTitle ?? ""
        let alert = NSAlert()
        alert.messageText = "重命名会话"
        alert.informativeText = "给当前会话起一个名字，方便以后在会话菜单里认出它。留空则使用自动标题。"
        alert.alertStyle = .informational
        alert.addButton(withTitle: "确定")
        alert.addButton(withTitle: "取消")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.stringValue = current
        field.placeholderString = "留空则使用自动标题"
        field.bezelStyle = .roundedBezel
        alert.accessoryView = field
        if alert.runModal() == .alertFirstButtonReturn {
            let name = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            chat.renameActive(name.isEmpty ? nil : name)
        }
    }

    /// 删除当前会话（走二次确认，破坏性动作）。
    private func conversationDelete() {
        guard chat.store.activeID != nil else { return }
        state.presentConfirmation(
            title: "删除当前会话",
            message: "这条会话里的全部问答记录将被永久删除，且无法恢复。",
            confirmTitle: "删除",
            isDestructive: true
        ) {
            chat.deleteActive()
        }
    }

    // MARK: - 切换阅读方式

    private func selectAgent(_ agent: AgentConfig) {
        state.settingsStore.ai.activeAgentID = agent.id
        if agent.id == AgentConfig.mindMapMode.id { questionScope = .wholeDocument }
        noteRerunAvailability("已切到「\(agent.name)」")
    }

    /// 告诉用户「可以用新配置重跑上一条」。
    ///
    /// 只在**确实有上一条可重跑**时才提示：没有历史请求时弹这句话，
    /// 等于承诺一个点了没反应的按钮。
    private func noteRerunAvailability(_ prefix: String) {
        guard chat.canRerunLast else { return }
        state.showToast("\(prefix)：点「重新生成」可按新配置重跑当前内容")
    }

    /// 头部单行中的固定宽图标按钮。名称放进 help，避免模板、Agent、会话标题
    /// 在 300pt 面板里互相挤压；模型名是唯一保留文字的高频状态。
    private func compactHeaderIcon(_ systemImage: String,
                                   tint: Color = DS.Palette.textSecondary) -> some View {
        Image(systemName: systemImage)
            .font(DS.Typo.ui(size: 13, weight: .medium))
            .foregroundStyle(tint)
            .frame(width: Self.headerIconWidth, height: Self.headerIconWidth)
            .background(DS.Palette.surfaceRaised,
                        in: RoundedRectangle(cornerRadius: DS.Radius.s, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: DS.Radius.s, style: .continuous)
                .strokeBorder(DS.Palette.separator, lineWidth: 0.5))
    }

    /// chip 的**内容**（图标 + 文本），作为 `Menu` 的 label。
    ///
    /// 里面**不能放自绘 Shape（圆点）、background 或 overlay**：macOS 上
    /// `Menu`（borderlessButton 样式）只保留 label 里的 `Text` 与 `Image`，
    /// 其余一概丢掉。逐点取色验证过两件事——写成 label 的
    /// `.background(Capsule().fill(surfaceRaised))` 取不到任何底色，
    /// `Circle().fill(...)` 状态点也一个像素都取不到。
    /// 所以外壳（ChipShell）与状态点（statusDot）都必须挂在 Menu **外面**。
    ///
    /// - Parameter maxTextWidth: 文本最大宽度；给了就截断（`.truncationMode(.middle)`），
    ///   chip 因此不会无限变宽、挤压同行的其它控件。完整文字交给 `.help`。
    private func chipContent(
        text: String,
        icon: String? = nil,
        maxTextWidth: CGFloat? = nil
    ) -> some View {
        HStack(spacing: 4) {
            if let icon {
                Image(systemName: icon).font(DS.Typo.ui(size: 9.5))
            }
            Text(text)
                .font(DS.Typo.ui(size: 10.5, weight: .medium))
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: maxTextWidth, alignment: .leading)
        }
        .foregroundStyle(DS.Palette.textSecondary)
    }

    /// chip 左侧的状态点（服务商「配没配好」、Agent「要不要联网」）。
    ///
    /// 做成可选是有意的：模板没有对应状态，那就不要挂一个永远亮着的假指示灯——
    /// 用户会以为它在表示什么。传 nil 就整枚不出现。
    ///
    /// 必须放在 `Menu` 外面，理由见 `chipContent`。
    @ViewBuilder
    private func statusDot(_ color: Color?) -> some View {
        if let color {
            Circle().fill(color).frame(width: 5, height: 5)
        }
    }

    /// chip 的胶囊外壳（内边距 + 底色 + 描边）。
    ///
    /// **必须挂在 `Menu` 外面，不能挂在它的 label 里**。实测（--capture-screen 1，
    /// 2x 逐点取色）：写成 label 的 `.background(Capsule().fill(surfaceRaised))`
    /// 时，填充与面板材质背景同为 #F4F4F4，连 0.5pt 描边都取不到——
    /// 「模型切换按钮」在界面上只剩一串裸字，看不出它是可以点的。
    /// 同款写法用在非 Menu 的视图上（气泡头像、页码徽章）是正常的，
    /// 所以这是 Menu（borderlessButton 样式）自己的事，不是颜色的问题。
    struct ChipShell: ViewModifier {
        var minHeight: CGFloat? = 30
        func body(content: Content) -> some View {
            content
                .padding(.horizontal, DS.Space.s)
                .padding(.vertical, 3)
                .frame(minHeight: minHeight)
                .background(DS.Palette.surfaceRaised, in: Capsule())
                .overlay(Capsule().strokeBorder(DS.Palette.separator, lineWidth: 0.5))
        }
    }

    private struct HeaderIconShell: ViewModifier {
        func body(content: Content) -> some View {
            content
                .background(DS.Palette.surfaceRaised,
                            in: RoundedRectangle(cornerRadius: DS.Radius.s, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: DS.Radius.s, style: .continuous)
                    .strokeBorder(DS.Palette.separator, lineWidth: 0.5))
        }
    }

    private func activate(_ provider: AIProviderConfig, model: String? = nil) {
        var updated = provider
        if let model { updated.selectedModel = model }
        state.settingsStore.upsertProvider(updated)
        state.settingsStore.settings.ai.activeProviderID = provider.id
    }

    private func openSettingsAndActivate() {
        openSettings()
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: - 对话区

    private var transcript: some View {
        ScrollView {
            if chat.bubbles.isEmpty {
                emptyState
            } else {
                VStack(alignment: .leading, spacing: DS.Space.m) {
                    ForEach(chat.bubbles) { bubble in
                        TranscriptMessage(id: bubble.id,
                            keepMounted: chat.bubbles.suffix(2).contains(where: { $0.id == bubble.id }),
                            viewportHeight: transcriptHeight) {
                            AIBubbleView(bubble: bubble, isStreaming: chat.streamingID == bubble.id,
                                         isLast: bubble.id == chat.bubbles.last?.id, chat: chat)
                                .equatable()
                        }
                        .background {
                            if LaunchOptions.flag("--transcript-report") {
                                TranscriptScrollAudit(rowID: bubble.id)
                            }
                        }
                    }
                }
                .padding(.horizontal, Self.contentInset)
                .padding(.vertical, DS.Space.m)
                .background(TranscriptScrollFollower(tailID: chat.bubbles.last?.id))
            }
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { transcriptHeight = $0 }
    }

    // MARK: - 空状态

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: DS.Space.l) {
            VStack(alignment: .leading, spacing: DS.Space.xs) {
                Text("让 AI 帮你读这一页")
                    .font(DS.Typo.ui(size: 13.5, weight: .semibold))
                    .foregroundStyle(DS.Palette.textPrimary)
            }

            VStack(spacing: DS.Space.s) {
                // 四张引导卡从 planner 长出：文案取自 `entry.title`，不再在视图里硬编码，
                // 否则改文案时 planner 会静默过期——而它是我们宣称的单一真相源。
                ForEach(ActionEntries.entries(in: .aiPanelGuide)) { entry in
                    guideCard(entry)
                }
            }

            if !(state.settingsStore.activeProvider?.isConfigured ?? false) {
                setupCallout
            }
        }
        .padding(.horizontal, Self.contentInset)
        .padding(.vertical, DS.Space.m)
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

    /// 空状态引导卡：文案取自 planner（`entry.title`），图标 / 可用性 / 动作按 id 翻译。
    /// 这样改文案只动 `ActionEntries` 一处——视图里不再出现那四个中文标题字面量。
    @ViewBuilder
    private func guideCard(_ entry: ActionEntry) -> some View {
        switch entry.id {
        case .guideExplain:
            quickAction(entry.title, icon: "sparkles", enabled: hasSelection) { run(.explain) }
        case .guideTranslate:
            quickAction(entry.title, icon: "character.book.closed", enabled: hasSelection) { run(.translate) }
        case .guideSummarizeUnit:
            quickAction(currentUnitSummaryTitle, icon: "text.append", enabled: true) { run(.summarize(scope: .currentUnit)) }
        case .guideSummarizeAll:
            quickAction("总结全文", icon: "books.vertical", enabled: bridge.unitCount > 1) { summarizeWholeDocument() }
        default:
            // planner 里新增了引导卡条目却没在这里补 case：不静默，走可见兜底 + 断言。
            UnimplementedEntryView(entry: entry)
        }
    }

    // MARK: - 输入区

    private var composer: some View {
        VStack(spacing: DS.Space.s) {
            HStack(alignment: .center, spacing: DS.Space.s) {
                questionScopeMenu

                TextField(questionPlaceholder, text: draftBinding, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(DS.Typo.aiBody)
                    .lineLimit(1...6)
                    .padding(.horizontal, DS.Space.m)
                    .padding(.vertical, 8)
                    .frame(minHeight: 40)
                    .background(
                        RoundedRectangle(cornerRadius: DS.Radius.m, style: .continuous)
                            .fill(DS.Palette.surfaceRaised)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: DS.Radius.m, style: .continuous)
                            .strokeBorder(DS.Palette.separator, lineWidth: 0.5)
                    )
                    // 输入框优先拿到宽度：模型 chip 会自截断，输入框不该被它挤压。
                    .layoutPriority(1)
                    .onSubmit(sendDraft)

                if chat.isStreaming {
                    Button {
                        chat.stop()
                    } label: {
                        Image(systemName: "stop.circle.fill")
                            .font(DS.Typo.ui(size: 24))
                            .frame(width: 40, height: 40)
                            .foregroundStyle(DS.Palette.danger)
                    }
                    .buttonStyle(.plain)
                    .help("停止生成")
                } else {
                    Button(action: sendDraft) {
                        Image(systemName: "arrow.up.circle.fill")
                            .font(DS.Typo.ui(size: 24))
                            .frame(width: 40, height: 40)
                            .foregroundStyle(canSend ? DS.Palette.accent : DS.Palette.textTertiary)
                    }
                    .buttonStyle(.plain)
                    .disabled(!canSend)
                    .help("发送 (↩)")
                }
            }

            if chat.draft.count >= Self.maxDraftCharacters * 4 / 5 {
                Text("\(chat.draft.count)/\(Self.maxDraftCharacters)")
                    .font(DS.Typo.ui(size: 10.5, design: .monospaced))
                    .foregroundStyle(chat.draft.count >= Self.maxDraftCharacters
                        ? DS.Palette.warning : DS.Palette.textTertiary)
                    .monospacedDigit()
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
        }
        .padding(.horizontal, Self.contentInset)
        .padding(.vertical, DS.Space.m)
    }

    private var questionScopeMenu: some View {
        Menu {
            ForEach([QuestionScope.currentUnit, .wholeDocument]) { scope in
                Button {
                    questionScope = scope
                } label: {
                    if questionScope == scope {
                        Label(scope.title, systemImage: "checkmark")
                    } else {
                        Text(scope.title)
                    }
                }
            }
            Divider()
            Section("与已打开文档对照") {
                if comparisonSessions.isEmpty {
                    Text("请先打开另一份文档")
                } else {
                    ForEach(comparisonSessions) { candidate in
                        Button {
                            comparisonSessionID = candidate.id
                            questionScope = .compareDocument
                        } label: {
                            if questionScope == .compareDocument,
                               comparisonSessionID == candidate.id {
                                Label(candidate.title, systemImage: "checkmark")
                            } else {
                                Text(candidate.title)
                            }
                        }
                    }
                }
            }
        } label: {
            chipContent(text: questionScopeTitle, icon: questionScope.icon, maxTextWidth: 78)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .modifier(ChipShell(minHeight: 40))
        .frame(minWidth: 100, maxWidth: 118)
        .layoutPriority(1)
        .help(questionScopeHelp)
    }

    private var questionPlaceholder: String {
        switch questionScope {
        case .currentUnit: return "就当前页/章提问…"
        case .wholeDocument: return "向全文提问…"
        case .compareDocument: return "比较两份文档…"
        }
    }

    private var comparisonSessions: [ReaderSession] {
        state.sessions.filter { $0.id != session.id }
    }

    private var selectedComparisonSession: ReaderSession? {
        if let comparisonSessionID,
           let selected = comparisonSessions.first(where: { $0.id == comparisonSessionID }) {
            return selected
        }
        return comparisonSessions.first
    }

    private var questionScopeTitle: String {
        guard questionScope == .compareDocument else { return questionScope.title }
        guard let title = selectedComparisonSession?.title else { return "双文档" }
        return "对照 · \(title)"
    }

    private var questionScopeHelp: String {
        switch questionScope {
        case .currentUnit:
            return "默认只使用当前页或当前章的内容"
        case .wholeDocument:
            return "依据全文回答；超过模型容量时使用覆盖全文的分层摘要与原文证据"
        case .compareDocument:
            return selectedComparisonSession.map {
                "读取当前文档与「\($0.title)」的全文，回答时区分两份来源"
            } ?? "先打开另一份文档，才能进行双文档比较"
        }
    }

    private var draftBinding: Binding<String> {
        Binding(
            get: { chat.draft },
            set: { value in
                if value.count > Self.maxDraftCharacters {
                    chat.draft = String(value.prefix(Self.maxDraftCharacters))
                    if !didWarnDraftLimit {
                        didWarnDraftLimit = true
                        state.showToast("输入已限制为 6000 字；长材料请放在文档中，再用「全文」提问", requiresAttention: true)
                    }
                } else {
                    chat.draft = value
                    if value.count < Self.maxDraftCharacters { didWarnDraftLimit = false }
                }
            }
        )
    }

    /// 头部的「联网检索」手动开关（本批从输入框左槽搬来）。
    ///
    /// 与 Agent 自己的联网开关是**两个独立条件**（满足其一即检索）：
    /// Agent 那个属于「这个角色定位上就要查文献」，跟着 Agent 走；
    /// 这个属于「我这一次想查」，不改动任何 Agent。
    ///
    /// 图标旁的 help 把**代价**写出来（每次提问多几秒）而不是只写好处：
    /// 它要给三个外部库发请求，用户有权在按下之前知道这一点。
    private var webSearchToggle: some View {
        let isOn = state.settingsStore.ai.webSearchEnabled

        return Button {
            state.settingsStore.ai.webSearchEnabled.toggle()
            state.showToast(
                isOn ? "已关闭本次联网检索" : "已开启联网检索：每次提问会多花几秒"
            )
        } label: {
            Image(systemName: "globe")
                .font(DS.Typo.ui(size: 13, weight: isOn ? .semibold : .regular))
                .foregroundStyle(isOn ? Color.white : DS.Palette.textTertiary)
                .frame(width: 30, height: 30)
                .background(
                    Circle().fill(isOn ? DS.Palette.accent : DS.Palette.surfaceRaised)
                )
                .overlay(
                    Circle().strokeBorder(
                        isOn ? DS.Palette.accent : DS.Palette.separator,
                        lineWidth: 0.5
                    )
                )
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(
            """
            联网检索文献（Crossref · OpenAlex · arXiv）

            开启后每次提问会先查这三个公开学术库，把命中的文献连同 DOI / 编号
            一起交给模型，因此每次提问会多花几秒。当前只接入这三个免密钥来源；
            万方等其他数据源需要单独的应用授权和接口接入。

            阅读方式已启用检索时，无需重复开启。
            """
        )
        .accessibilityLabel("联网检索文献")
    }

    private var canSend: Bool {
        !chat.isStreaming && (!chat.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || activeAgent?.id == AgentConfig.mindMapMode.id)
    }

    // MARK: - 动作

    private var hasSelection: Bool {
        bridge.selection?.isUsable ?? false
    }

    /// 当前选中的提示词模板。`nil` 表示不套模板，走 `PromptLibrary` 的默认行为。
    ///
    /// 每次用 id 去查而不是在切换时缓存一份：模板可能在编辑器里被改名或删掉，
    /// 缓存的话会继续拿着一份已经不存在的旧副本。
    private var activeTemplate: PromptTemplate? {
        nil
    }

    /// 当前选中的 Agent。`nil` = 不加角色，走默认助手行为。
    /// 与 activeTemplate 同理，每次按 id 现查，避免拿到已被删除的旧副本。
    private var activeAgent: AgentConfig? {
        state.settingsStore.ai.activeReadingMode
    }

    private func sendDraft() {
        guard canSend else { return }
        let draft = chat.draft.trimmingCharacters(in: .whitespacesAndNewlines)
        let question = draft.isEmpty ? "请将所提供的文献材料整理为思维导图，突出核心论点、论证关系、证据与限定条件。" : draft
        let (context, locator, citations) = resolveContext(for: .ask(question: question))
        // 双文档模式的 context 已明确包含 A / B 两份材料；若继续传当前选区，PromptLibrary
        // 会按“有选区就只用选区”的规则覆盖 context，比较会悄悄退化成单文档提问。
        // 全局共享会话之后，每次提问都要把「当前文档」记到气泡上，
        // 否则跨文档引用降级（见 ConversationCitationPolicy）无从判定这条回答属于哪本书。
        let sourcePath = state.document?.id
        let sourceTitle = state.document?.displayTitle
        chat.followUp(
            question: question,
            selection: nil,
            metadata: bridge.metadata,
            locatorLabel: bridge.positionLabel,
            context: context,
            locator: locator,
            citations: citations,
            config: state.settingsStore.activeProvider,
            memory: state.aiMemoryPayload,
            translateTarget: state.settingsStore.ai.translateTarget,
            template: activeTemplate,
            agent: activeAgent,
            skills: state.settingsStore.ai.skillLibrary,
            webSearchEnabled: state.settingsStore.ai.webSearchEnabled,
            sourcePath: sourcePath,
            sourceTitle: sourceTitle,
            contextLoader: wholeContextLoader(),
            semantic: semanticConfiguration,
            visionConfig: visualConfiguration,
            imageLoader: chartLoader(question: question)
        )
    }

    private func run(_ task: AITask, selection requestedSelection: ReaderSelection? = nil) {
        let selection = requestedSelection ?? bridge.selection
        let whole: Bool
        switch task {
        case .summarize(.wholeDocument): whole = true
        case .ask, .custom: whole = questionScope == .wholeDocument || questionScope == .compareDocument
        default: whole = false
        }
        let (context, locator, citations) = resolveContext(for: task, selection: selection)
        let sourcePath = state.document?.id
        let sourceTitle = state.document?.displayTitle
        chat.submit(
            task: task,
            selection: whole || task == .summarize(scope: .currentUnit)
                || Self.retrievalQuery(for: task) != nil ? nil : selection,
            metadata: bridge.metadata,
            locatorLabel: bridge.positionLabel,
            context: context,
            locator: locator,
            citations: citations,
            config: state.settingsStore.activeProvider,
            memory: state.aiMemoryPayload,
            translateTarget: state.settingsStore.ai.translateTarget,
            template: activeTemplate,
            agent: activeAgent,
            skills: state.settingsStore.ai.skillLibrary,
            webSearchEnabled: state.settingsStore.ai.webSearchEnabled,
            sourcePath: sourcePath,
            sourceTitle: sourceTitle,
            contextLoader: whole ? wholeContextLoader(force: true, includeComparison: task != .summarize(scope: .wholeDocument)) : nil,
            semantic: semanticConfiguration,
            visionConfig: visualConfiguration,
            imageLoader: chartLoader(question: Self.retrievalQuery(for: task) ?? "")
        )
    }

    private func wholeContextLoader(force: Bool = false, includeComparison: Bool = true) -> (@MainActor () async throws -> [DocumentContext])? {
        guard force || questionScope == .wholeDocument || questionScope == .compareDocument else { return nil }
        let current = bridge.documentContextProvider
        let currentProgress = bridge.documentContextProgressProvider
        let compare = includeComparison && questionScope == .compareDocument
        let other = selectedComparisonSession?.bridge.documentContextProvider
        let otherProgress = selectedComparisonSession?.bridge.documentContextProgressProvider
        return {
            guard let current else { throw AIError.http(status: 400, message: "全文尚未就绪，请等待文档加载") }
            let progress = chat.documentProgressHandler()
            let document: DocumentContext
            if let currentProgress { document = try await currentProgress(progress) }
            else { document = try await current() }
            var documents = [document]
            try Task.checkCancellation()
            if compare {
                guard let other else { throw AIError.http(status: 400, message: "请打开并加载第二份文档") }
                let document: DocumentContext
                if let otherProgress { document = try await otherProgress(progress) }
                else { document = try await other() }
                documents.append(document)
            }
            if settings.ai.documentAI.parsingEnabled {
                for index in documents.indices {
                    documents[index] = try await EnhancedDocumentService.shared.enrich(documents[index],
                        options: settings.ai.documentAI, progress: progress)
                }
            }
            return documents
        }
    }

    private var semanticConfiguration: SemanticIndexConfiguration? {
        let option = settings.ai.documentAI
        guard let provider = settings.ai.providers.first(where: { $0.id == option.embeddingProviderID }),
              !option.embeddingModel.isEmpty else { return nil }
        return .init(provider: provider, model: option.embeddingModel,
            apiKey: AICredentialStore.read(account: provider.keychainAccount) ?? "")
    }

    private var visualConfiguration: AIProviderConfig? {
        settings.visionProvider
    }

    private func runChart(_ image: AIImage) {
        let (context, locator) = bridge.currentContextProvider?() ?? ("", .pdf(page: bridge.currentUnitIndex, charOffset: 0))
        chat.submit(task: .ask(question: "解释图表的内容、变量、主要发现与限制。"), selection: nil,
            metadata: bridge.metadata, locatorLabel: bridge.positionLabel, context: context, locator: locator,
            config: settings.activeProvider, memory: state.aiMemoryPayload, translateTarget: settings.ai.translateTarget,
            agent: activeAgent, skills: settings.ai.skillLibrary, sourcePath: session.document.id,
            visionConfig: visualConfiguration, images: [image])
    }

    private func chartLoader(question: String) -> (@MainActor ([DocumentContext]) async throws -> [AIImage])? {
        guard activeAgent?.skills.contains(AgentSkill.chartID) == true,
              session.document.id.lowercased().hasSuffix(".pdf") else { return nil }
        let path = session.document.id, current = bridge.currentUnitIndex
        return { documents in
            let matching = documents.filter { $0.path == path }.flatMap(\.evidence)
            let hits = DocumentRetrieval(matching).search(question, limit: 4)
            var pages: [Int] = []
            if let expression = try? NSRegularExpression(pattern: "(?i)(?:fig(?:ure)?\\.?|图|table|表)\\s*([0-9]+)"),
               let match = expression.firstMatch(in: question, range: NSRange(question.startIndex..., in: question)),
               let number = Range(match.range(at: 1), in: question) {
                let pattern = "(?i)(?:fig(?:ure)?\\.?|图|table|表)\\s*" + String(question[number]) + "(?![0-9])"
                for source in matching where source.text.range(of: pattern, options: .regularExpression) != nil {
                    if !pages.contains(source.locator.pageIndex) { pages.append(source.locator.pageIndex) }
                }
            }
            for hit in hits where !pages.contains(hit.evidence.locator.pageIndex) { pages.append(hit.evidence.locator.pageIndex) }
            if pages.isEmpty { pages = [current] }
            var images: [AIImage] = []
            for page in pages.prefix(4) { images.append(try await PDFPageAssets.shared.image(path: path, pageIndex: page)) }
            return images
        }
    }

    private func consume(_ request: AIRequest) {
        switch request.kind {
        case .explain:
            run(.explain, selection: request.selection)
        case .translate:
            run(.translate, selection: request.selection)
        case .ask:
            questionScope = .currentUnit
            let question = request.customPrompt.isEmpty ? "这一段是什么意思？" : request.customPrompt
            let focus = request.selection.map { "\n\n【提问焦点】\n" + $0.text } ?? ""
            run(.ask(question: question + focus))
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
    /// 当前页是默认；全文模式才检索当前整本，双文档模式则分别检索两个已打开标签。
    private func resolveContext(for task: AITask, selection: ReaderSelection? = nil) -> (String, DocumentLocator, [DocumentLocator]) {
        // Document-wide requests load their material asynchronously inside the chat task.
        if task == .summarize(scope: .wholeDocument)
            || ((questionScope == .wholeDocument || questionScope == .compareDocument) && Self.retrievalQuery(for: task) != nil) {
            return ("", bridge.selection?.locator ?? .pdf(page: 0, charOffset: 0), [])
        }
        if questionScope == .compareDocument,
           let query = Self.retrievalQuery(for: task), !query.isEmpty,
           let comparison = resolveComparisonContext(query: query) {
            return comparison
        }

        if let selection = selection ?? bridge.selection,
           task == .explain || task == .translate {
            return (selection.text, selection.locator, [selection.locator])
        }

        if questionScope == .wholeDocument,
           let query = Self.retrievalQuery(for: task), !query.isEmpty,
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

    /// 从当前标签和另一个已打开标签各取最相关段落。定位按钮只保留当前文档的命中：
    /// `DocumentLocator` 目前不携带文件身份，若把 B 文档页码挂到 A 文档气泡上，会跳错书。
    /// 两份材料本身始终带文档名和页/章标签，回答仍可核对来源。
    private func resolveComparisonContext(
        query: String
    ) -> (String, DocumentLocator, [DocumentLocator])? {
        guard let other = selectedComparisonSession else {
            state.showToast("请先打开另一份文档，再选择双文档比较", requiresAttention: true)
            return nil
        }

        let currentFallback = bridge.currentContextProvider?()
            ?? ("", DocumentLocator.pdf(page: 0, charOffset: 0))
        let currentHits = bridge.retrieveProvider?(query) ?? []
        let currentText: String
        let currentLocator: DocumentLocator
        let currentCitations: [DocumentLocator]

        if let selection = bridge.selection, selection.isUsable {
            currentText = "【当前选中内容】\n\(selection.text)"
            currentLocator = selection.locator
            currentCitations = [selection.locator]
        } else if !currentHits.isEmpty {
            currentText = currentHits.map { "【\($0.label)】\n\($0.text)" }
                .joined(separator: "\n\n")
            currentLocator = currentHits[0].locator
            currentCitations = currentHits.map(\.locator)
        } else {
            currentText = currentFallback.0
            currentLocator = currentFallback.1
            currentCitations = [currentFallback.1]
        }

        let otherHits = other.bridge.retrieveProvider?(query) ?? []
        let otherFallback = other.bridge.currentContextProvider?()
        let otherText: String
        if !otherHits.isEmpty {
            otherText = otherHits.map { "【\($0.label)】\n\($0.text)" }
                .joined(separator: "\n\n")
        } else {
            otherText = otherFallback?.0 ?? ""
        }

        guard !otherText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            state.showToast("「\(other.title)」尚未完成加载，请先切到该标签一次", requiresAttention: true)
            return nil
        }

        let context = """
        【双文档对照】
        以下材料分别来自两份文档。回答时必须区分 A 与 B 的观点；共同点和差异都要标明来源，不要把两份原文混成同一作者的论述。

        【文档 A：\(session.title)】
        \(currentText)

        【文档 B：\(other.title)】
        \(otherText)
        """
        return (context, currentLocator, currentCitations)
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
        run(.summarize(scope: .wholeDocument))
    }

    private var currentUnitSummaryTitle: String {
        "总结当前\(state.unitName)"
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
}

/// ⋯ 菜单里的一行：planner 条目 + 「是否在其前面画分隔线」。
///
/// 用结构体而不是元组：SwiftUI 的 `ForEach` 需要 `id`，而 key path 指不到元组成员。
private struct PanelMenuRow: Identifiable {
    let entry: ActionEntry
    let showDivider: Bool
    var id: ActionEntryID { entry.id }
}

// MARK: - 单条消息

struct AIBubbleView: View, Equatable {

    let bubble: AIChatModel.Bubble
    let isStreaming: Bool
    /// 是不是最后一条消息。「重新生成」只挂在这条上——
    /// 挂在每条回答上会让人以为它能重跑任意一条，而模型只存了最近一次的快照。
    var isLast: Bool = false
    let chat: AIChatModel

    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.bubble == rhs.bubble && lhs.isStreaming == rhs.isStreaming
            && lhs.isLast == rhs.isLast && lhs.chat === rhs.chat
    }

    @EnvironmentObject private var bridge: ReaderBridge
    @EnvironmentObject private var state: AppState
    @EnvironmentObject private var settings: SettingsStore
    private var textSize: CGFloat { CGFloat(settings.ui.aiTextSize) }
    @State private var showReasoning = false
    @State private var justRemembered = false
    /// 「已复制」「已批注」的短暂确认态。做成按钮上的对勾而不是 toast：
    /// 用户手就在这条消息上，反馈不该跑到屏幕另一头去。
    @State private var justCopied = false
    @State private var justAnnotated = false

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
                .font(DS.Typo.readingPanel(size: textSize))
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
        let visibleText = WholeAnswerCoverage.visibleAnswer(bubble.text)
        let sources = bubble.failed ? [] : bubble.answerEvidence ?? []
        return HStack(alignment: .top, spacing: DS.Space.s) {
            ZStack {
                Circle()
                    .fill(bubble.failed ? DS.Palette.danger.opacity(0.14) : DS.Palette.accentSoft)
                // 补一条描边：`accentSoft` 只有 10% 不透明度，落在面板底色上
                // 边界几乎不可见——用户看到的是「一枚浮在空白里的小图标」，
                // 看不出它是有容器的头像。描边用 separator，不加颜色。
                Circle()
                    .strokeBorder(
                        bubble.failed ? DS.Palette.danger.opacity(0.35) : DS.Palette.separator,
                        lineWidth: 0.5
                    )
                if bubble.failed {
                    // 失败态讲的是「出错了」，不是「这是 AI」，保留三角警示。
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(DS.Typo.ui(size: 9.5, weight: .semibold))
                        .foregroundStyle(DS.Palette.danger)
                } else {
                    // 用环点字形，不用 sparkles：品牌规则禁用 sparkle 表达 AI
                    // 语义（四芒星已是全行业万能符），且它在 9.5pt 下糊成一团。
                    AIIcon(size: 11, color: DS.Palette.accent)
                }
            }
            .frame(width: 20, height: 20)
            .padding(.top, 1)

            VStack(alignment: .leading, spacing: DS.Space.s) {
                if !bubble.reasoning.isEmpty {
                    reasoningDisclosure
                }

                if isStreaming && bubble.expectedMindMap {
                    thinkingIndicator
                } else if bubble.text.isEmpty && isStreaming {
                    thinkingIndicator
                } else if bubble.text.isEmpty && !bubble.progress.isEmpty {
                    Text(bubble.progress)
                        .font(DS.Typo.ui(size: 11.5))
                        .foregroundStyle(DS.Palette.textTertiary)
                } else if !isStreaming, !bubble.failed, let map = MindMapResult.parse(visibleText) {
                    MindMapView(root: map.root)
                    if !map.surroundingText.isEmpty {
                        MarkdownText(text: map.surroundingText, textColor: DS.Palette.textPrimary, fontSize: textSize, evidence: sources)
                            .textSelection(.enabled)
                    }
                } else {
                    if !isStreaming, !bubble.failed, bubble.expectedMindMap {
                        Text("未收到有效导图结构，原回答已保留。")
                            .font(DS.Typo.ui(size: 11)).foregroundStyle(DS.Palette.warning)
                    }
                    MarkdownText(text: String(visibleText.prefix(16_000)),
                        textColor: bubble.failed ? DS.Palette.danger : DS.Palette.textPrimary,
                        fontSize: textSize, evidence: sources, isStreaming: isStreaming)
                    if visibleText.count > 16_000 {
                        Text("预览 · 前 16,000 字").font(DS.Typo.ui(size: 10.5))
                            .foregroundStyle(DS.Palette.textTertiary)
                    }
                }

                if isStreaming && !bubble.text.isEmpty {
                    if !bubble.progress.isEmpty {
                        Text(bubble.progress)
                            .font(DS.Typo.ui(size: 10.5))
                            .foregroundStyle(DS.Palette.textTertiary)
                    }
                }

                if !isStreaming && !bubble.searchCoverage.isEmpty {
                    Text(bubble.searchCoverage).font(DS.Typo.ui(size: 10.5))
                        .foregroundStyle(DS.Palette.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
                if !bubble.text.isEmpty && !isStreaming && !bubble.failed {
                    if !bubble.coverage.isEmpty {
                        Text(bubble.coverage)
                            .font(DS.Typo.ui(size: 10.5))
                            .foregroundStyle(DS.Palette.textTertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if !bubble.historyCoverage.isEmpty {
                        Text(bubble.historyCoverage).font(DS.Typo.ui(size: 10.5))
                            .foregroundStyle(DS.Palette.textTertiary)
                    }
                    if let usage = bubble.usage {
                        Text("Tokens · 输入 \(usage.input.map(String.init) ?? "未知") · 输出 \(usage.output.map(String.init) ?? "未知") · 缓存 \(usage.cached.map(String.init) ?? "未知")\(bubble.usageReports < bubble.requestCount ? "（部分请求）" : "")")
                            .font(DS.Typo.ui(size: 10))
                            .foregroundStyle(DS.Palette.textTertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    } else if let estimate = bubble.estimatedInput {
                        Text("输入约 \(estimate) tokens（估算）· 输出与缓存未知")
                            .font(DS.Typo.ui(size: 10))
                            .foregroundStyle(DS.Palette.textTertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    // 探针：给 footer 行的实际宽度一个可断言的读数。
                    // 同名的多个探针会互相覆盖、消失时也会误注销，所以只有「最后一条」
                    // （最可能满配：引用编号 + 重新生成 + 复制 + 批注 + 记住）挂正式名字，
                    // 其余挂一个不参与断言的备用名，避免抢占。见 tools/layout_assert.py。
                    footerRow.layoutProbe(isLast ? "aiFooter" : "aiFooter_inactive")
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .environment(\.openURL, OpenURLAction { url in
            guard url.scheme == "lumen-evidence" else { return .systemAction }
            guard let source = InlineEvidenceLink.source(for: url, in: sources) else { return .discarded }
            jumpToEvidence(source)
            return .handled
        })
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

    /// 只显示目标编号的引用 chip：`→ 13`。
    ///
    /// 原来画的是 `→ 第 13 页`，一个 chip 就要吃掉近三分之一行宽；面板下限 300pt 时，
    /// 三个 chip 加四个动作按钮挤不下（用户附图里「重新生成」「添加到批注」被压成两行）。
    /// 现在 chip 里只留编号，完整语义（「跳回第 13 页」）放进 `.help`——
    /// 悬停才需要它，而挤不挤是每一帧都要承担的代价。多条引用最多显示 3 个。
    private var citationRow: some View {
        HStack(spacing: DS.Space.xs) {
            if let references = bubble.answerEvidence {
                ForEach(Array(references.prefix(3).enumerated()), id: \.offset) { _, source in
                    Button { jumpToEvidence(source) } label: {
                        Text("[\(source.number ?? 0)] · \(citationNumber(source.locator))")
                            .font(DS.Typo.ui(size: 10, weight: .medium))
                    }
                    .buttonStyle(.borderless)
                    .help("\(URL(fileURLWithPath: source.path).lastPathComponent) · \(source.label)\n\(source.quote ?? "")")
                }
                if references.count > 3 {
                    Menu {
                        ForEach(Array(references.enumerated()), id: \.offset) { _, source in
                            Button("[\(source.number ?? 0)] \(URL(fileURLWithPath: source.path).lastPathComponent) · \(source.label)") {
                                jumpToEvidence(source)
                            }
                        }
                    } label: { Image(systemName: "doc.text.magnifyingglass") }
                    .menuStyle(.borderlessButton)
                    .help("回答的原文依据")
                } else if references.isEmpty && !isStreaming {
                    Image(systemName: "doc.text.magnifyingglass")
                        .foregroundStyle(DS.Palette.textTertiary)
                        .help("本次回答没有提供通过核验的原文引文")
                }
            }
        }
    }

    private func jumpToEvidence(_ source: DocumentCitation) {
        if !state.sessions.contains(where: { $0.document.id == source.path }) {
            state.open(url: URL(fileURLWithPath: source.path))
        }
        guard let target = state.sessions.first(where: { $0.document.id == source.path }) else { return }
        state.activate(target)
        Task { @MainActor in
            for _ in 0..<30 {
                guard state.activeSessionID == target.id else { return }
                if target.bridge.goTo != nil {
                    do {
                        guard try DocumentSourceVersion.matches(source) else {
                            state.showToast("文件已变化，这条旧引用需重新核对", requiresAttention: true)
                            return
                        }
                        guard state.activeSessionID == target.id else { return }
                        if let reveal = target.bridge.revealEvidence { reveal(source) }
                        else { target.bridge.goTo?(source.locator) }
                    } catch { state.showToast("无法核对引用：\(error.localizedDescription)", isError: true) }
                    return
                }
                try? await Task.sleep(for: .milliseconds(100))
            }
            state.showToast("文档尚未加载，请稍后重试引用", requiresAttention: true)
        }
    }

    /// chip 上的编号（PDF 用页码、EPUB 用章节号，都是 1-based）。
    private func citationNumber(_ locator: DocumentLocator) -> Int {
        switch locator {
        case .pdf(let page, _):        return page + 1
        case .epub(let chapter, _, _): return chapter + 1
        }
    }

    /// 引用跳回 + 三个动作 +「记住」。
    ///
    /// **整行左对齐的紧凑组，行尾自然留白**：从前的写法是
    /// `HStack { citationRow; Spacer(minLength: 0); 按钮们 }`，把按钮顶到最右——
    /// 结果引用编号与动作之间被拉开一大段空白，窄面板下按钮反而先被压缩换行。
    /// 现在不放假 Spacer，动作紧挨引用，整行 `.fixedSize()` 防压缩，
    /// 标签一律 `.lineLimit(1)`：宁可整行溢出被裁（有探针盯着），也不换行成两排。
    ///
    /// 「重新生成」是付费动作，所以**不给键盘快捷键**（项目里的既定约定：
    /// 一次误触的代价是一次真实的模型调用）。它也不在流式输出期间出现——
    /// 那时要的是「停止」，两个按钮同时亮着容易按错。
    private var footerRow: some View {
        HStack(spacing: 6) {
            citationRow

            if isLast && bubble.role == .assistant && !isStreaming {
                iconAction(
                    systemImage: "arrow.clockwise",
                    help: "用当前模型与阅读方式重新生成，将发送新请求",
                    tint: chat.canRerunLast ? DS.Palette.accent : DS.Palette.textTertiary,
                    disabled: !chat.canRerunLast,
                    action: { chat.rerunLast(settings: state.settingsStore, memory: state.aiMemoryPayload) }
                )
            }

            iconAction(
                systemImage: justCopied ? "checkmark" : "doc.on.doc",
                help: justCopied ? "已复制" : "复制这条回答的完整内容",
                tint: justCopied ? DS.Palette.success : DS.Palette.textTertiary,
                action: copyAnswer
            )

            iconAction(
                systemImage: justAnnotated ? "checkmark" : "square.and.pencil",
                help: justAnnotated ? "已添加到批注" : "把这条回答写进当前页（PDF）或当前章（EPUB）的批注",
                tint: justAnnotated ? DS.Palette.success : DS.Palette.textTertiary,
                action: annotateAnswer
            )

            rememberAnswerButton
        }
        // 防压缩：不让 HStack 为了塞进可用宽度而把图标 / 文字挤成省略号。
        // 溢出与否由 `aiFooter` 探针盯着（见 tools/layout_assert.py）。
        .fixedSize(horizontal: true, vertical: false)
        .padding(.top, 2)
    }

    /// 纯图标动作按钮（重新生成 / 复制 / 添加到批注）。
    ///
    /// 从「图标 + 文字」的小 chip 收成一枚图标：footer 一行要同时放引用编号、
    /// 三个动作和「记住」，带文字一定会被压成两行或省略号——而用户的直接诉求
    /// 就是「精简，只保留 `13`、`记住` 这类简洁表达」。动作语义交给 `.help`。
    private func iconAction(
        systemImage: String,
        help: String,
        tint: Color,
        disabled: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(DS.Typo.ui(size: 11, weight: .medium))
                .foregroundStyle(tint)
                .frame(width: 20, height: 20)
                .background(
                    RoundedRectangle(cornerRadius: DS.Radius.s, style: .continuous)
                        .fill(DS.Palette.surfaceRaised)
                )
                .contentShape(RoundedRectangle(cornerRadius: DS.Radius.s, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .help(help)
    }

    /// 「记住」按钮：图标 `bookmark` + 文字「记住」（用户点名保留这个词）。
    ///
    /// 与其余三个纯图标动作放在一起时，它是唯一带文字的——因为「记住」这个动作
    /// 不像复制 / 批注那样有公认的图标语义，只放一个书签图标没人猜得出是它。
    /// 「已记住」态也保持单行。
    private var rememberAnswerButton: some View {
        Button {
            rememberAnswer()
        } label: {
            HStack(spacing: 3) {
                Image(systemName: justRemembered ? "checkmark" : "bookmark")
                    .font(DS.Typo.ui(size: 10, weight: .semibold))
                Text(justRemembered ? "已记住" : "记住")
                    .font(DS.Typo.ui(size: 10, weight: .medium))
                    .lineLimit(1)
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

    private func rememberAnswer() {
        let text = WholeAnswerCoverage.visibleAnswer(bubble.text)
        guard !text.isEmpty else { return }
        state.remember(
            text: text,
            source: bubble.sourceDocPath.map { URL(fileURLWithPath: $0).deletingPathExtension().lastPathComponent } ?? "AI 对话",
            locatorLabel: bubble.evidence.first?.label ?? bubble.citations.first?.displayLabel() ?? ""
        )
        withAnimation(DS.Motion.quick) { justRemembered = true }
    }

    private func copyAnswer() {
        let text = WholeAnswerCoverage.visibleAnswer(bubble.text)
        guard !text.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        withAnimation(DS.Motion.quick) { justCopied = true }
        // 一秒半后收回对勾，让按钮回到可再次点击的常态
        Task {
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            withAnimation(DS.Motion.quick) { justCopied = false }
        }
    }

    /// 把整条回答写进书的批注。
    ///
    /// 落点取「这条回答引用的第一处」，拿不到引用就退回读者当前所在的位置——
    /// 一条回答常常横跨好几页，而读者此刻多半正看着最相关的那一页。
    /// 划词还在时把划的那段当锚文本：批注就钉在那句话旁边，而不是飘在页脚。
    private func annotateAnswer() {
        let text = WholeAnswerCoverage.visibleAnswer(bubble.text)
        guard !text.isEmpty, let addNote = bridge.addPageNote else {
            state.showToast("当前文档不支持批注", isError: true)
            return
        }

        guard let currentPath = state.document?.id,
              bubble.sourceDocPath == currentPath || bubble.answerEvidence?.contains(where: { $0.path == currentPath }) == true else {
            state.showToast("请先打开这条回答的来源文档，再添加批注", isError: true)
            return
        }
        let source = bubble.answerEvidence?.first(where: { $0.path == currentPath })
        if let source {
            do {
                guard try DocumentSourceVersion.matches(source) else {
                    state.showToast("文件已变化，请重新核对原文后添加批注", requiresAttention: true)
                    return
                }
            } catch {
                state.showToast("无法核对批注来源：\(error.localizedDescription)", isError: true)
                return
            }
        }
        let locator = source?.locator ?? (bubble.answerEvidence == nil
            ? (bubble.evidence.first(where: { $0.path == currentPath })?.locator ?? bubble.citations.first) : nil)
        let unitIndex: Int
        switch locator {
        case .pdf(let page, _):      unitIndex = page
        case .epub(let chapter, _, _): unitIndex = chapter
        case nil:                     unitIndex = bridge.currentUnitIndex
        }

        var anchor = source?.quote ?? ""
        if anchor.isEmpty, let selection = bridge.selection, selection.isUsable,
           selection.locator.pageIndex == unitIndex || selection.locator.chapterIndex == unitIndex {
            anchor = selection.text
        }

        addNote(unitIndex, anchor, text)
        withAnimation(DS.Motion.quick) { justAnnotated = true }
        Task {
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            withAnimation(DS.Motion.quick) { justAnnotated = false }
        }
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
