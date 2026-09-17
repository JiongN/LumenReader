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
    /// 提示词模板编辑器
    @State private var isTemplateEditorVisible = false
    /// Agent 编辑器
    @State private var isAgentEditorVisible = false

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
        .sheet(isPresented: $isTemplateEditorVisible) {
            PromptTemplateEditor()
                .environmentObject(state)
        }
        .sheet(isPresented: $isAgentEditorVisible) {
            AgentEditor()
                .environmentObject(state)
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

    /// composer 行里模型 chip 的**最小槽位宽**（pt）。
    ///
    /// 这不是审美常量，是**可见性下限**。chip 里的文本挂了 `.frame(maxWidth:)` 可截断，
    /// 它的最小宽度因此是 0；而同一行的输入框是 `.layoutPriority(1)`，HStack 于是把
    /// chip 一路压到 0 宽——实测面板里根本看不到模型切换按钮（头部已搬走、底部又没画出来）。
    /// 108 ≈ chip 自然上限（8 前内边距 + 5 圆点 + 4 间距 + 80 文本 + 8 后内边距 = 105）取整；
    /// 300pt 面板下给输入框仍留得下 126pt，占位符不会被裁成残句。
    private static let modelSlotMinWidth: CGFloat = 108

    /// header 行里「模板 / Agent」两枚 chip 的宽度区间（pt）。
    ///
    /// 这两枚原来挂 `.fixedSize()`（不让菜单标题被截断），代价是 header 行在
    /// 300pt 下限下**整体溢出面板右边界**：实测收起按钮被顶到 maxX=1340.2，
    /// 而面板右边界是 1340.0——按钮有一半探到面板外面，看着像「悬在行尾外面」。
    /// 改成可压缩后必须同时给下限：只压缩不设下限，可截断的文本会被压到 0 宽
    /// （模型 chip 那次就是同一个坑），chip 会整个消失。
    private static let headerChipMinWidth: CGFloat = 56
    private static let headerChipMaxWidth: CGFloat = 116

    private var header: some View {
        HStack(spacing: DS.Space.s) {
            // v3 图标迭代：头部不再放 AI 图标。面板里是 chips + 对话，
            // 再摆一个标记属于重复自我介绍；工具栏与侧栏页签上的
            // 环点字形已经足够指认这里是 AI。

            // 这里原来还有一行「AI 阅读」文字标题，现在让位给切换器。
            // 面板默认宽 380pt、用户还能调到 300pt，标题 + 两个 chip 会把整行挤爆；
            // 而 sparkles 图标本身已经说明了这是 AI 面板，标题是纯冗余。
            //
            // 顺序（用户定的）：sparkles → globe（联网开关）→ 模板 → Agent → ⋯ → 收起。
            // globe 从输入框左槽搬到这里、模型 chip 从头部搬到输入框左槽——两者换了位置：
            // 「这一次要不要联网」属于发起的动作，和输入框放一起更顺手；
            // 「用哪个模型」是长期设定，放在头部与模板 / Agent 并列更合逻辑。
            webSearchToggle
            templateMenu
            agentMenu

            Spacer(minLength: 0)

            // 行尾这两枚按「谁都不许被挤走」排序：⋯ 其次、收起最高。
            // 收起按钮是这个面板唯一的鼠标出口（工具栏那枚重复入口已删），
            // 它一旦被左侧挤出可视区，就等于「点掉就再也收不回来」。
            moreMenu
                .layoutPriority(1)
            collapseButton
                .layoutPriority(2)
        }
        .padding(.horizontal, Self.contentInset)
        .frame(height: DS.Size.toolbarHeight)
    }

    /// 面板内的「超长菜单」：总结 / 重新生成 / 记忆 / 导出 / 清空。
    private var moreMenu: some View {
        Menu {
            Button("总结本节") { run(.summarize(scope: .currentUnit)) }
            Button("总结全书") { summarizeWholeDocument() }
            Divider()
            // 「重新生成」是**付费动作**，所以只放在菜单与气泡 footer 里，
            // 不给键盘快捷键：一次误触的代价是一次真实的模型调用。
            Button("重新生成上一条回答") { chat.rerunLast() }
                .disabled(!chat.canRerunLast)
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
        .layoutProbe("aiMoreMenu")
    }

    /// 面板右上角的收起入口——**这是收起面板唯一的鼠标出口**。
    ///
    /// 此前收起 AI 面板只有两个鼠标入口：工具栏那枚 AI 按钮、以及菜单项
    /// 「显示 → 显示/隐藏 AI 面板」。用户在面板里读完一段回答、想把阅读区让出来时，
    /// 眼睛和手都在面板上，却得跑去工具栏找——这就是「右侧边栏无法收起」的可用性根因。
    ///
    /// 工具栏那枚已删（同一个动作的第二个入口），所以这一枚必须**钉死在右上角**：
    /// 它在 header 行里拿最高 layoutPriority，且行内可压缩的 chip 都给了下限宽度，
    /// 300pt 下限下也不会被顶出面板右边界。收起后的唤回走工具栏那枚「仅收起时出现」
    /// 的小入口 + 快捷键，不会「点掉就再也找不到」。
    private var collapseButton: some View {
        Button {
            withAnimation(DS.Motion.panel) { state.isAIPanelVisible = false }
        } label: {
            Image(systemName: "sidebar.trailing")
                .font(DS.Typo.ui(size: 13))
                .foregroundStyle(DS.Palette.textSecondary)
        }
        .buttonStyle(.plain)
        .frame(width: 22, height: DS.Size.toolbarHeight, alignment: .center)
        .help("收起 AI 面板 (\(state.keyBindings.combo(for: .toggleAIPanel)?.display ?? "—"))")
        .accessibilityLabel("收起 AI 面板")
        .layoutProbe("aiCollapse")
    }

    // MARK: - 服务商与提示词

    /// 服务商 / 模型切换。**放在 composer 行的左槽**（本批与联网开关换了位置）。
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

        return Menu {
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
            chip(
                dotColor: configured ? DS.Palette.success : DS.Palette.warning,
                text: modelLabel,
                // 80 而不是 132：让它连上槽位上限（`modelSlotMinWidth` = 108），
                // chip 才不会反过来去挤输入框。完整模型名交给下面的 `.help`。
                maxTextWidth: 80
            )
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        // 不给 layoutPriority（输入框优先拿宽度），但**必须给最小宽度**——
        // 只靠 layoutPriority，可截断的文本会被压到 0 宽，chip 就整个消失了。
        .layoutPriority(0)
        .frame(minWidth: Self.modelSlotMinWidth, alignment: .leading)
        .help(configured
              ? "切换 AI 服务商 / 模型\n当前模型：\(modelLabel)"
              : "尚未配置 AI 服务商，点击开始配置")
    }

    /// 服务商在菜单里的一项。模型多于一个时给二级菜单——
    /// 换服务商十有八九就是为了换模型，这一步不该再让人跑一趟设置页。
    @ViewBuilder
    private func providerMenuEntry(_ provider: AIProviderConfig) -> some View {
        let isActive = state.settingsStore.ai.activeProviderID == provider.id

        if provider.models.count > 1 {
            Menu {
                ForEach(provider.models, id: \.self) { model in
                    Button(model) { activate(provider, model: model) }
                }
            } label: {
                if isActive {
                    Label("\(provider.name)（\(provider.selectedModel)）", systemImage: "checkmark")
                } else {
                    Text("\(provider.name)（\(provider.selectedModel)）")
                }
            }
        } else {
            Button {
                activate(provider)
            } label: {
                if isActive {
                    Label(provider.name, systemImage: "checkmark")
                } else {
                    Text(provider.name)
                }
            }
        }
    }

    /// 提示词模板切换。
    ///
    /// 「默认」放在最前面，而不是让某个预设默认选中：默认行为是经过调校的
    /// （系统提示里逐条堵住了幻觉、客套话、过度概括），套模板是在它之上做加法。
    /// 所以「不加东西」必须是一个一眼看得到、随时回得来的选项。
    private var templateMenu: some View {
        let templates = state.settingsStore.ai.templates
        let activeID = state.settingsStore.ai.activeTemplateID

        return Menu {
            Button {
                state.settingsStore.ai.activeTemplateID = nil
                noteRerunAvailability("已切回默认读法")
            } label: {
                if activeID == nil {
                    Label("默认", systemImage: "checkmark")
                } else {
                    Text("默认")
                }
            }

            Divider()

            ForEach(templates) { template in
                Button {
                    selectTemplate(template)
                } label: {
                    if template.id == activeID {
                        Label(template.name, systemImage: "checkmark")
                    } else {
                        Text(template.name)
                    }
                }
            }

            Divider()

            Button("编辑提示词…") { isTemplateEditorVisible = true }
        } label: {
            chip(dotColor: nil, text: activeTemplateName, icon: "text.badge.checkmark")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        // 不挂 .fixedSize()：那样这一行在 300pt 下限下会整体溢出面板右边界，
        // 把行尾的收起按钮顶出去（实测 maxX=1340.2 > 面板 1340.0）。
        // 改成「可压缩 + 有下限」，超长模板名截断、完整名字交给 .help。
        .frame(minWidth: Self.headerChipMinWidth, maxWidth: Self.headerChipMaxWidth)
        .help("切换提示词模板")
    }

    /// Agent 切换。
    ///
    /// 放在提示词旁边，是因为两者常被同时用到但解决的不是同一件事：
    /// 模板换「读法」（立场与输出形态），Agent 换「谁在读、带什么装备」
    /// （角色、技能、要不要联网）。用户想换苏格拉底式追问时，他要找的是后者。
    private var agentMenu: some View {
        let agents = state.settingsStore.ai.agents
        let activeID = state.settingsStore.ai.activeAgentID
        let active = agents.first { $0.id == activeID }

        return Menu {
            Button {
                state.settingsStore.ai.activeAgentID = nil
                noteRerunAvailability("已改为不用 Agent")
            } label: {
                if activeID == nil {
                    Label("不用 Agent", systemImage: "checkmark")
                } else {
                    Text("不用 Agent")
                }
            }

            Divider()

            ForEach(agents) { agent in
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

            Button("管理 Agent…") { isAgentEditorVisible = true }
        } label: {
            chip(
                dotColor: active?.usesWebSearch == true ? DS.Palette.accent : nil,
                text: active?.name ?? "Agent",
                icon: "person.crop.circle.badge.checkmark"
            )
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        // 同 templateMenu：可压缩 + 有下限，换掉会让 header 行溢出的 .fixedSize()。
        .frame(minWidth: Self.headerChipMinWidth, maxWidth: Self.headerChipMaxWidth)
        .help("切换 Agent：角色、技能与联网检索")
    }

    private var activeTemplateName: String {
        guard let id = state.settingsStore.ai.activeTemplateID,
              let template = state.settingsStore.ai.templates.first(where: { $0.id == id }) else {
            return "默认"
        }
        return template.name
    }

    // MARK: - 切换模型 / 模板 / Agent

    /// 切模板。切换本身已经对**下一次**请求生效（请求时才解析配置），
    /// 但对「当前这条回答」不会自动重跑——那是付费动作，得由用户发起。
    /// 所以切完给一句可操作的提示，而不是让他自己去发现「怎么没变」。
    private func selectTemplate(_ template: PromptTemplate) {
        state.settingsStore.ai.activeTemplateID = template.id
        noteRerunAvailability("已切到模板「\(template.name)」")
    }

    private func selectAgent(_ agent: AgentConfig) {
        state.settingsStore.ai.activeAgentID = agent.id
        noteRerunAvailability("已切到 Agent「\(agent.name)」")
    }

    /// 告诉用户「可以用新配置重跑上一条」。
    ///
    /// 只在**确实有上一条可重跑**时才提示：没有历史请求时弹这句话，
    /// 等于承诺一个点了没反应的按钮。
    private func noteRerunAvailability(_ prefix: String) {
        guard chat.canRerunLast else { return }
        state.showToast("\(prefix)：点「重新生成」可按新配置重跑当前内容")
    }

    /// chip 的统一外形。
    ///
    /// 「状态点」做成可选是有意的：服务商有「配没配好」要表达，模板没有对应状态，
    /// 那就不要挂一个永远亮着的假指示灯——用户会以为它在表示什么。
    ///
    /// - Parameter maxTextWidth: 文本最大宽度；给了就截断（`.truncationMode(.middle)`），
    ///   chip 因此不会无限变宽、挤压同行的其它控件。完整文字交给 `.help`。
    private func chip(
        dotColor: Color?,
        text: String,
        icon: String? = nil,
        maxTextWidth: CGFloat? = nil
    ) -> some View {
        HStack(spacing: 4) {
            if let dotColor {
                Circle().fill(dotColor).frame(width: 5, height: 5)
            }
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
        .padding(.horizontal, DS.Space.s)
        .padding(.vertical, 3)
        .background(Capsule().fill(DS.Palette.surfaceRaised))
        .overlay(Capsule().strokeBorder(DS.Palette.separator, lineWidth: 0.5))
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
        ScrollViewReader { proxy in
            ScrollView {
                if chat.bubbles.isEmpty {
                    emptyState
                } else {
                    LazyVStack(alignment: .leading, spacing: DS.Space.m) {
                        ForEach(chat.bubbles) { bubble in
                            AIBubbleView(
                                bubble: bubble,
                                isStreaming: chat.streamingID == bubble.id,
                                isLast: bubble.id == chat.bubbles.last?.id
                            )
                            .id(bubble.id)
                        }
                        Color.clear.frame(height: 1).id(Self.bottomAnchor)
                    }
                    // 与 header / composer 共用同一个横向内边距，左右对称、内容不贴右边缘。
                    .padding(.horizontal, Self.contentInset)
                    .padding(.vertical, DS.Space.m)
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
                // 左槽现在是模型 chip（本批从头部搬来）；联网开关搬去了头部。
                providerMenu
                    // 几何可外部核对：这一条断言是「模型切换按钮真的画出来了」。
                    .layoutProbe("aiModelChip")

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
                    // 输入框优先拿到宽度：模型 chip 会自截断，输入框不该被它挤压。
                    .layoutPriority(1)
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
        .padding(.horizontal, Self.contentInset)
        .padding(.vertical, DS.Space.m)
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
                .frame(width: 26, height: 26)
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
            一起交给模型，因此每次提问会多花几秒。三个源都是免密钥的公开接口；
            知网、万方、Web of Science 没有可用的公开接口，接不了。

            勾了「联网检索」的 Agent 不需要再开这个——两者满足其一即触发。
            """
        )
        .accessibilityLabel("联网检索文献")
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

    /// 当前选中的提示词模板。`nil` 表示不套模板，走 `PromptLibrary` 的默认行为。
    ///
    /// 每次用 id 去查而不是在切换时缓存一份：模板可能在编辑器里被改名或删掉，
    /// 缓存的话会继续拿着一份已经不存在的旧副本。
    private var activeTemplate: PromptTemplate? {
        guard let id = state.settingsStore.ai.activeTemplateID else { return nil }
        return state.settingsStore.ai.templates.first { $0.id == id }
    }

    /// 当前选中的 Agent。`nil` = 不加角色，走默认助手行为。
    /// 与 activeTemplate 同理，每次按 id 现查，避免拿到已被删除的旧副本。
    private var activeAgent: AgentConfig? {
        guard let id = state.settingsStore.ai.activeAgentID else { return nil }
        return state.settingsStore.ai.agents.first { $0.id == id }
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
            translateTarget: state.settingsStore.ai.translateTarget,
            template: activeTemplate,
            agent: activeAgent,
            webSearchEnabled: state.settingsStore.ai.webSearchEnabled
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
            translateTarget: state.settingsStore.ai.translateTarget,
            template: activeTemplate,
            agent: activeAgent,
            webSearchEnabled: state.settingsStore.ai.webSearchEnabled
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
    /// 是不是最后一条消息。「重新生成」只挂在这条上——
    /// 挂在每条回答上会让人以为它能重跑任意一条，而模型只存了最近一次的快照。
    var isLast: Bool = false

    @EnvironmentObject private var bridge: ReaderBridge
    @EnvironmentObject private var state: AppState
    @EnvironmentObject private var chat: AIChatModel
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
                    // 探针：给 footer 行的实际宽度一个可断言的读数。
                    // 同名的多个探针会互相覆盖、消失时也会误注销，所以只有「最后一条」
                    // （最可能满配：引用编号 + 重新生成 + 复制 + 批注 + 记住）挂正式名字，
                    // 其余挂一个不参与断言的备用名，避免抢占。见 tools/layout_assert.py。
                    footerRow.layoutProbe(isLast ? "aiFooter" : "aiFooter_inactive")
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

    /// 只显示目标编号的引用 chip：`→ 13`。
    ///
    /// 原来画的是 `→ 第 13 页`，一个 chip 就要吃掉近三分之一行宽；面板下限 300pt 时，
    /// 三个 chip 加四个动作按钮挤不下（用户附图里「重新生成」「添加到批注」被压成两行）。
    /// 现在 chip 里只留编号，完整语义（「跳回第 13 页」）放进 `.help`——
    /// 悬停才需要它，而挤不挤是每一帧都要承担的代价。多条引用最多显示 3 个。
    private var citationRow: some View {
        HStack(spacing: DS.Space.xs) {
            ForEach(Array(bubble.citations.prefix(3).enumerated()), id: \.offset) { _, locator in
                Button {
                    bridge.goTo?(locator)
                } label: {
                    Text("→ \(citationNumber(locator))")
                        .font(DS.Typo.ui(size: 10, weight: .medium))
                        .lineLimit(1)
                        .monospacedDigit()
                        .foregroundStyle(DS.Palette.accent)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 3)
                        .background(Capsule().fill(DS.Palette.accentSoft))
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .help(citationHelp(locator))
            }
        }
    }

    /// chip 上的编号（PDF 用页码、EPUB 用章节号，都是 1-based）。
    private func citationNumber(_ locator: DocumentLocator) -> Int {
        switch locator {
        case .pdf(let page, _):        return page + 1
        case .epub(let chapter, _, _): return chapter + 1
        }
    }

    /// chip 的 tooltip：完整语义放这里，不放 chip 上（省宽度）。
    private func citationHelp(_ locator: DocumentLocator) -> String {
        switch locator {
        case .pdf:  return "跳回第 \(citationNumber(locator)) 页"
        case .epub: return "跳到第 \(citationNumber(locator)) 章"
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
                    help: "用当前的模型 / 模板 / Agent 重新生成这条回答，是一次付费请求",
                    tint: chat.canRerunLast ? DS.Palette.accent : DS.Palette.textTertiary,
                    disabled: !chat.canRerunLast,
                    action: { chat.rerunLast() }
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
        let text = bubble.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        state.remember(
            text: text,
            source: state.currentDocumentTitle,
            locatorLabel: bubble.citations.first?.displayLabel() ?? ""
        )
        withAnimation(DS.Motion.quick) { justRemembered = true }
    }

    private func copyAnswer() {
        let text = bubble.text.trimmingCharacters(in: .whitespacesAndNewlines)
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
        let text = bubble.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, let addNote = bridge.addPageNote else {
            state.showToast("当前文档不支持批注", isError: true)
            return
        }

        let locator = bubble.citations.first
        let unitIndex: Int
        switch locator {
        case .pdf(let page, _):      unitIndex = page
        case .epub(let chapter, _, _): unitIndex = chapter
        case nil:                     unitIndex = bridge.currentUnitIndex
        }

        var anchor = ""
        if let selection = bridge.selection, selection.isUsable,
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
