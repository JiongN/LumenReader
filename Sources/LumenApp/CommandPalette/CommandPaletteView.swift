import SwiftUI
import AppKit
import LumenKit

/// 一条可执行的命令。
struct PaletteCommand: Identifiable {
    let id: String
    let title: String
    /// 右侧提示：通常是快捷键
    let hint: String
    let icon: String
    /// 分组，决定展示顺序
    let group: String
    /// 额外搜索词。中文界面下用拼音首字母是常见期待，但实时转拼音要额外依赖，
    /// 这里用「同义词 + 英文名」覆盖最常见的检索方式。
    let keywords: String
    let isEnabled: Bool
    let run: () -> Void

    init(
        id: String,
        title: String,
        hint: String = "",
        icon: String,
        group: String,
        isEnabled: Bool = true,
        keywords: String = "",
        run: @escaping () -> Void
    ) {
        self.id = id
        self.title = title
        self.hint = hint
        self.icon = icon
        self.group = group
        self.isEnabled = isEnabled
        self.keywords = keywords
        self.run = run
    }

    var searchableText: String {
        keywords.isEmpty ? title : "\(title) \(keywords)"
    }
}

/// ⌘K 命令面板。
///
/// 存在的理由：这个应用的绝大多数能力都藏在「菜单栏」「⋯ 菜单」「划词条」「设置页」
/// 四个地方，用熟了很快，但学的时候要一处处找。给一个入口，输入两三个字就能命中，
/// 顺带也让快捷键变得可发现——右侧始终显示 ⌘⌥S 这类提示，用几次就记住了。
struct CommandPaletteOverlay: View {

    @EnvironmentObject private var state: AppState
    @EnvironmentObject private var bridge: ReaderBridge
    @EnvironmentObject private var chat: AIChatModel
    @EnvironmentObject private var keyBindings: KeyBindingStore
    @Environment(\.openSettings) private var openSettings

    @State private var query: String = ""
    @State private var highlighted: Int = 0
    @FocusState private var isFieldFocused: Bool

    private var results: [PaletteCommand] {
        let all = commands
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !trimmed.isEmpty else {
            return all.filter(\.isEnabled)
        }

        return all
            .compactMap { command -> (PaletteCommand, Int)? in
                guard let score = Self.matchScore(query: trimmed, candidate: command.searchableText) else {
                    return nil
                }
                // 不可用的命令压到后面，但不隐藏——让用户知道「有这个功能，只是现在不能用」
                return (command, score - (command.isEnabled ? 0 : 1000))
            }
            .sorted { lhs, rhs in
                lhs.1 == rhs.1 ? lhs.0.title < rhs.0.title : lhs.1 > rhs.1
            }
            .map(\.0)
    }

    var body: some View {
        ZStack(alignment: .top) {
            // 点击空白处关闭
            Color.black.opacity(0.16)
                .ignoresSafeArea()
                .onTapGesture { dismiss() }
                // 遮罩只淡入：它铺满全屏，跟着缩放会露出窗口边缘。
                .transition(.opacity)

            card
                .padding(.top, 90)
                .onKeyPress(keys: [.upArrow, .downArrow, .escape]) { press in
                    handleKey(press.key)
                }
                // 卡片单独做「淡入 + 从 97% 放大」。锚点取 .top 而不是默认的居中：
                // 面板是从上方落下来的，从顶端展开才和它的位置感一致；
                // 居中缩放会让它看起来像从屏幕中间「弹出来」，和 90pt 的下沉位置打架。
                .transition(.opacity.combined(with: .scale(scale: 0.97, anchor: .top)))
        }
    }

    // MARK: - 卡片

    private var card: some View {
        VStack(spacing: 0) {
            searchField
            Divider()
            resultList
            Divider()
            footerHint
        }
        .frame(width: 520)
        .frame(maxHeight: 420)
        .background(
            RoundedRectangle(cornerRadius: DS.Radius.l, style: .continuous)
                .fill(DS.Palette.surfaceRaised)
                .shadow(color: .black.opacity(0.22), radius: 28, y: 12)
        )
        .overlay(
            RoundedRectangle(cornerRadius: DS.Radius.l, style: .continuous)
                .strokeBorder(DS.Palette.separator, lineWidth: 0.5)
        )
    }

    private var searchField: some View {
        HStack(spacing: DS.Space.s) {
            Image(systemName: "command")
                .font(DS.Typo.ui(size: 13, weight: .medium))
                .foregroundStyle(DS.Palette.textTertiary)

            TextField("输入命令，例如「主题」「导出」「批注」", text: $query)
                .textFieldStyle(.plain)
                .font(DS.Typo.ui(size: 14))
                .focused($isFieldFocused)
                .onSubmit { runHighlighted() }

            if !query.isEmpty {
                Button {
                    query = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(DS.Typo.ui(size: 12))
                        .foregroundStyle(DS.Palette.textTertiary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, DS.Space.l)
        .frame(height: 50)
        .onAppear { isFieldFocused = true }
    }

    private var resultList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 1) {
                    if results.isEmpty {
                        Text("没有匹配的命令")
                            .font(DS.Typo.ui(size: 12.5))
                            .foregroundStyle(DS.Palette.textTertiary)
                            .padding(DS.Space.l)
                            .frame(maxWidth: .infinity, alignment: .center)
                    } else {
                        ForEach(Array(results.enumerated()), id: \.element.id) { index, command in
                            commandRow(command, isHighlighted: index == highlighted)
                                .id(index)
                                .onTapGesture {
                                    highlighted = index
                                    runHighlighted()
                                }
                        }
                    }
                }
                .padding(.vertical, DS.Space.xs)
            }
            .onChange(of: highlighted) { _, index in
                withAnimation(DS.Motion.quick) { proxy.scrollTo(index, anchor: .center) }
            }
        }
        .frame(maxHeight: .infinity)
    }

    private func commandRow(_ command: PaletteCommand, isHighlighted: Bool) -> some View {
        HStack(spacing: DS.Space.s) {
            Image(systemName: command.icon)
                .font(DS.Typo.ui(size: 12))
                .frame(width: 18)
                .foregroundStyle(command.isEnabled ? DS.Palette.accent : DS.Palette.textTertiary)

            VStack(alignment: .leading, spacing: 0) {
                Text(command.title)
                    .font(DS.Typo.ui(size: 13))
                    .foregroundStyle(command.isEnabled ? DS.Palette.textPrimary : DS.Palette.textTertiary)
                if !command.group.isEmpty {
                    Text(command.group)
                        .font(DS.Typo.ui(size: 9.5))
                        .foregroundStyle(DS.Palette.textTertiary)
                }
            }

            Spacer(minLength: DS.Space.s)

            if !command.hint.isEmpty {
                Text(command.hint)
                    .font(DS.Typo.ui(size: 10.5, design: .rounded))
                    .foregroundStyle(DS.Palette.textTertiary)
            }
        }
        .padding(.horizontal, DS.Space.l)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: DS.Radius.s, style: .continuous)
                .fill(isHighlighted ? DS.Palette.accentSoft : .clear)
                .padding(.horizontal, DS.Space.xs)
        )
        .contentShape(Rectangle())
    }

    private var footerHint: some View {
        HStack(spacing: DS.Space.m) {
            keyHint("↑↓", "选择")
            keyHint("↩", "执行")
            keyHint("esc", "关闭")
            Spacer(minLength: 0)
            Text("\(results.count) 项")
                .font(DS.Typo.ui(size: 10.5))
                .foregroundStyle(DS.Palette.textTertiary)
        }
        .padding(.horizontal, DS.Space.l)
        .frame(height: 34)
    }

    private func keyHint(_ key: String, _ label: String) -> some View {
        HStack(spacing: 3) {
            Text(key)
                .font(DS.Typo.ui(size: 10, weight: .medium, design: .rounded))
                .padding(.horizontal, 4)
                .padding(.vertical, 1)
                .background(
                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .fill(DS.Palette.surfaceSunken)
                )
                .foregroundStyle(DS.Palette.textSecondary)
            Text(label)
                .font(DS.Typo.ui(size: 10.5))
                .foregroundStyle(DS.Palette.textTertiary)
        }
    }

    // MARK: - 键盘

    /// 方向键与 esc 交给 onKeyPress；回车走 TextField 的 onSubmit，
    /// 免得两套机制同时响应一次按键。
    private func handleKey(_ key: KeyEquivalent) -> KeyPress.Result {
        switch key {
        case .upArrow:
            moveHighlight(by: -1)
            return .handled
        case .downArrow:
            moveHighlight(by: 1)
            return .handled
        case .escape:
            dismiss()
            return .handled
        default:
            return .ignored
        }
    }

    private func moveHighlight(by delta: Int) {
        let count = results.count
        guard count > 0 else { return }
        highlighted = (highlighted + delta + count) % count
    }

    private func runHighlighted() {
        guard highlighted >= 0, highlighted < results.count else { return }
        let command = results[highlighted]
        guard command.isEnabled else { return }
        dismiss()
        // 让面板先收起来再执行：像「打开面板」这类命令会紧接着改动画状态，
        // 同一次 runloop 里做会让两个 transition 抢同一帧。
        DispatchQueue.main.async { command.run() }
    }

    private func dismiss() {
        // 和打开用同一个令牌：打开是弹簧、关闭是缓出的话，关的那一下会显得"塌"。
        withAnimation(DS.Motion.palette) { state.isCommandPaletteVisible = false }
    }

    // MARK: - 命令表

    /// 命令表。
    ///
    /// 「可改绑动作」这一大块直接由 `LumenAction` 生成，不手写：标题、可用性、
    /// 快捷键提示全部取自同一处，所以改完绑定之后，菜单栏、这里、设置页显示的
    /// 永远是同一个组合——手写最容易出的错就是三处慢慢对不上。
    private var commands: [PaletteCommand] {
        let reader = state.settingsStore.reader
        let isPDF = state.document?.kind == .pdf

        var items: [PaletteCommand] = []

        for action in LumenAction.allCases where action != .commandPalette {
            items.append(PaletteCommand(
                id: "action.\(action.rawValue)",
                title: paletteTitle(action),
                hint: keyBindings.combo(for: action)?.display ?? "",
                icon: paletteIcon(action),
                group: action.group.title,
                isEnabled: action.isEnabled(in: state),
                keywords: action.keywords
            ) { action.run(state) })
        }

        // 主题（不是「动作」，没有快捷键，所以留在这里）
        for theme in ReadingThemeID.allCases {
            items.append(PaletteCommand(
                id: "theme.\(theme.rawValue)",
                title: "主题：\(theme.displayName)",
                hint: reader.themeID == theme ? "当前" : "",
                icon: theme.isDark ? "moon.stars" : "sun.max",
                group: "外观",
                keywords: "theme 主题 \(theme.rawValue)"
            ) {
                state.settingsStore.reader.themeID = theme
            })
        }

        items.append(PaletteCommand(
            id: "read.flow",
            title: reader.flowMode == .continuous ? "切换到分页模式" : "切换到连续滚动",
            icon: "rectangle.split.3x1",
            group: "翻页与侧栏",
            isEnabled: state.document != nil,
            keywords: "flow 阅读模式 滚动 分页"
        ) {
            state.settingsStore.reader.flowMode = reader.flowMode == .continuous ? .paged : .continuous
        })

        if isPDF {
            items.append(PaletteCommand(
                id: "zoom.fit", title: "适合宽度", icon: "arrow.left.and.right.square",
                group: "翻页与侧栏", isEnabled: state.document != nil,
                keywords: "zoom fit 缩放"
            ) { bridge.zoomToFit?() })
        }

        // AI
        let hasSelection = bridge.selection?.isUsable ?? false

        items.append(PaletteCommand(
            id: "ai.explain", title: "解释选中内容", icon: "sparkles", group: "AI",
            isEnabled: state.document != nil && hasSelection, keywords: "explain 解释"
        ) { deliver(.explain) })

        items.append(PaletteCommand(
            id: "ai.translate", title: "翻译选中内容", icon: "character.book.closed", group: "AI",
            isEnabled: state.document != nil && hasSelection, keywords: "translate 翻译"
        ) { deliver(.translate) })

        items.append(PaletteCommand(
            id: "ai.summarizeUnit", title: "总结本节", icon: "text.append", group: "AI",
            isEnabled: state.document != nil, keywords: "summarize 总结"
        ) { deliver(.summarize) })

        items.append(PaletteCommand(
            id: "ai.summarizeAll", title: "总结全书", icon: "book.closed", group: "AI",
            isEnabled: state.document != nil && bridge.slicesProvider != nil,
            keywords: "summarize whole 整本"
        ) { deliver(.summarizeAll) })

        // 智能目录的两个动作分开列：一个是「让 AI 重新读一遍」（要花钱、要等），
        // 一个是「把侧栏切过去看看」。合成一条的话，只想看看的人会不小心触发一次生成。
        items.append(PaletteCommand(
            id: "ai.smartOutline.generate",
            title: state.smartOutline.outline == nil ? "生成 AI 智能目录" : "重新生成 AI 智能目录",
            icon: "sparkles.rectangle.stack", group: "AI",
            isEnabled: state.document != nil
                && bridge.unitSnippetProvider != nil
                && !state.smartOutline.phase.isWorking,
            keywords: "smart outline ai 智能目录 结构 章节 生成"
        ) { state.generateSmartOutline() })

        items.append(PaletteCommand(
            id: "ai.smartOutline.show", title: "查看 AI 智能目录", icon: "sidebar.left", group: "AI",
            isEnabled: state.document != nil && state.smartOutline.outline != nil,
            keywords: "smart outline 智能目录 查看 侧栏"
        ) { state.revealSidebar(tab: .smartOutline) })

        items.append(PaletteCommand(
            id: "ai.rememberSelection", title: "记住选中内容", icon: "bookmark", group: "AI",
            isEnabled: hasSelection, keywords: "memory remember 记忆"
        ) {
            guard let selection = bridge.selection, selection.isUsable else { return }
            state.remember(
                text: selection.text,
                source: state.currentDocumentTitle,
                locatorLabel: selection.locator.displayLabel()
            )
        })

        items.append(PaletteCommand(
            id: "ai.clear", title: "清空当前对话", icon: "trash", group: "AI",
            isEnabled: !chat.bubbles.isEmpty
        ) { chat.clear() })

        // OCR —— 只在扫描件上出现，否则是个永远点不动的菜单项
        if isPDF, bridge.isScannedDocument {
            items.append(PaletteCommand(
                id: "ocr.page", title: "识别本页文字（OCR）", icon: "text.viewfinder", group: "扫描件",
                isEnabled: bridge.ocrRunningPage == nil, keywords: "ocr 识别 扫描"
            ) { bridge.requestOCR?(bridge.currentUnitIndex) })
        }

        items.append(PaletteCommand(
            id: "app.settings", title: "打开设置…", hint: "⌘,", icon: "gearshape", group: "应用",
            keywords: "settings preference 偏好"
        ) {
            openSettings()
            NSApp.activate(ignoringOtherApps: true)
        })

        return items
    }

    /// 一部分动作的标题要随当前状态变（「隐藏侧栏」/「显示侧栏」）。
    private func paletteTitle(_ action: LumenAction) -> String {
        let isPDF = state.document?.kind == .pdf

        switch action {
        case .toggleSidebar:
            return state.isSidebarVisible ? "隐藏侧栏" : "显示侧栏"
        case .toggleAIPanel:
            return state.isAIPanelVisible ? "隐藏 AI 面板" : "显示 AI 面板"
        case .nextUnit:
            return isPDF ? "下一页" : "下一章"
        case .previousUnit:
            return isPDF ? "上一页" : "上一章"
        case .copyFullText:
            return state.document?.kind == .epub ? "复制全书为纯文本" : "复制全文为纯文本"
        default:
            return action.title
        }
    }

    private func paletteIcon(_ action: LumenAction) -> String {
        switch action {
        case .openDocument:   return "folder"
        case .openMostRecent: return "clock.arrow.circlepath"
        case .closeDocument:  return "xmark.rectangle"
        case .copyFullText:   return "doc.on.doc"
        case .copyFile:       return "doc.on.clipboard"
        case .toggleSidebar:  return "sidebar.leading"
        case .toggleAIPanel:  return "sparkles.rectangle.stack"
        case .toggleImmersive: return "arrow.up.left.and.arrow.down.right"
        case .commandPalette: return "command"
        case .nextUnit:       return "chevron.down"
        case .previousUnit:   return "chevron.up"
        case .goToPage:       return "number.square"
        case .showOutline:    return "list.bullet.indent"
        case .showSmartOutline: return "sparkles.rectangle.stack"
        case .showSearch:     return "magnifyingglass"
        case .showThumbnails: return "square.grid.2x2"
        case .fontIncrease:   return "textformat.size.larger"
        case .fontDecrease:   return "textformat.size.smaller"
        case .exportSummary:  return "square.and.arrow.up"
        }
    }

    /// 把动作交给 AI 面板执行。
    ///
    /// 走和划词浮动条同一条「投递 + 消费」通道：命令面板不去直接调 AIChatModel，
    /// 免得绕过面板里的上下文组装逻辑（全书检索、引用收集都长在那儿）。
    private func deliver(_ kind: AIRequest.Kind) {
        if !state.isAIPanelVisible {
            withAnimation(DS.Motion.panel) { state.isAIPanelVisible = true }
        }
        state.pendingAIRequest = AIRequest(kind: kind, selection: bridge.selection)
    }

    // MARK: - 匹配

    /// 子序列打分：字符顺序对得上就算命中，「导出」能匹配「导出摘要为 Markdown」。
    /// 连续命中、词首命中、前缀命中额外加分，让最相关的那条浮到第一行。
    static func matchScore(query: String, candidate: String) -> Int? {
        let needle = Array(query.lowercased())
        let haystack = Array(candidate.lowercased())
        guard !needle.isEmpty else { return 0 }
        guard haystack.count >= needle.count else { return nil }

        var score = 0
        var needleIndex = 0
        var streak = 0
        var lastMatchIndex = -1

        for (index, character) in haystack.enumerated() {
            guard needleIndex < needle.count else { break }
            guard character == needle[needleIndex] else {
                streak = 0
                continue
            }

            streak += 1
            score += 10 + streak * 5
            if index == lastMatchIndex + 1 { score += 6 }
            if index == 0 { score += 15 }
            lastMatchIndex = index
            needleIndex += 1
        }

        guard needleIndex == needle.count else { return nil }

        let lowered = candidate.lowercased()
        let trimmedQuery = query.lowercased()
        if lowered.hasPrefix(trimmedQuery) { score += 60 }
        if lowered.contains(trimmedQuery) { score += 30 }

        return score
    }
}
