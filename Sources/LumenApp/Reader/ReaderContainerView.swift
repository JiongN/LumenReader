import SwiftUI
import LumenKit

/// 阅读器外壳。
///
/// 布局刻意用 HStack + 显式分隔线而不是 NavigationSplitView：
/// 需要同时控制侧栏、阅读区、AI 面板三栏的宽度与出现动画，且要自定义分隔线的颜色，
/// NavigationSplitView 会强加系统材质与自带的侧栏开关，反而更难收敛视觉。
struct ReaderContainerView: View {

    let document: OpenDocument

    /// 沉浸模式下正文的最大宽度。
    ///
    /// 880 是个折中：纯文字排版讲舒适行长，660 左右更好读，但 PDF 是**整页渲染**，
    /// 限到 660 会让 A4 页面缩得字迹发虚。880 在两者之间——PDF 仍能看清，
    /// EPUB 的行长也比全屏时舒服得多。
    private static let immersiveMaxWidth: CGFloat = 880

    @EnvironmentObject private var state: AppState
    /// 通道与对话模型都挂在 AppState 上（菜单栏、命令面板也要用），这里只是取用
    private var bridge: ReaderBridge { state.bridge }
    private var chat: AIChatModel { state.chat }

    var body: some View {
        HStack(spacing: 0) {
            if state.isSidebarVisible {
                SidebarColumn()
                    // 宽度取自设置（可拖拽、可持久化），不再用固定常量
                    .frame(width: state.settingsStore.ui.sidebarWidth)
                    .layoutProbe("sidebar")
                    .background(.regularMaterial)
                    // 淡入 + 10pt 位移，而不是 `.move(edge: .leading)`：
                    // 整宽滑入会让阅读区看起来被「推」了一下，三栏同时在场时尤其晃眼。
                    .transition(.opacity.combined(with: .offset(x: -10)))

                PanelResizeHandle(
                    width: sidebarWidth,
                    range: UISettings.PanelWidth.sidebarRange,
                    defaultWidth: UISettings.PanelWidth.sidebarDefault,
                    panelIsLeading: true
                )
            }

            // 沉浸模式：两侧各加一个 Spacer 把正文挤到中间并限宽。
            //
            // 用 Spacer 而不是给 readerSurface 加 padding：padding 需要先知道窗口宽度
            // 才能算出「居中所需要的边距」，那就得套一层 GeometryReader，反而更绕；
            // 两个 Spacer 让 HStack 自己把剩余空间平分，天然居中，且宽度变化有动画。
            //
            // 限宽对两种文档都成立：PDF 的 PDFView 会自动按新宽度缩放（这正是「舒适行宽」），
            // EPUB 的 WebView 则重新排版，行长更短、更易读。
            HStack(spacing: 0) {
                if state.isImmersive { Spacer(minLength: 0) }

                readerSurface
                    .frame(
                        maxWidth: state.isImmersive ? Self.immersiveMaxWidth : .infinity,
                        maxHeight: .infinity
                    )
                    .layoutProbe("readerSurface")
                    // 两条浮层都贴在**阅读区**上，不是贴在整个三栏容器上。
                    //
                    // 挂在容器上时「右下角」会落进 AI 面板：状态条（页码 + 缩放）正好压住
                    // AI 输入框的右半边和发送按钮，既看不见也点不到；划词条的居中位置也会
                    // 随 AI 面板的显隐漂移。浮层本来就是给阅读区用的（页码、缩放、划词），
                    // 锚在阅读区才是它的语义位置。
                    .overlay(alignment: .bottom) { SelectionActionBarLayer() }
                    // 沉浸时收起状态条：页码已经在底部 HUD 上显示，再留一条属于重复信息，
                    // 而沉浸模式要的恰恰是「屏幕上只有正文」。
                    .overlay(alignment: .bottomTrailing) { ReaderStatusLayer() }

                if state.isImmersive { Spacer(minLength: 0) }
            }

            if state.isAIPanelVisible {
                PanelResizeHandle(
                    width: aiPanelWidth,
                    range: UISettings.PanelWidth.aiRange,
                    defaultWidth: UISettings.PanelWidth.aiDefault,
                    panelIsLeading: false
                )

                AIPanelView()
                    .frame(width: state.settingsStore.ui.aiPanelWidth)
                    .layoutProbe("aiPanel")
                    .background(.regularMaterial)
                    .transition(.opacity.combined(with: .offset(x: 10)))
            }
        }
        // environmentObject 必须放在所有 overlay 之后：overlay 会把内容包在修饰过的视图
        // 之外，先注入的话 overlay 里的视图看不到这个环境对象，运行时直接 fatalError。
        .environmentObject(bridge)
        .environmentObject(chat)
        .environmentObject(state.smartOutline)
        .onChange(of: bridge.metadata) { _, newValue in
            state.documentMetadata = newValue
        }
        // 单元数由阅读视图异步报上来（PDF 要等文档解析完）。智能目录拿它判定
        // 缓存是否还对得上当前文档——一本被替换过的书必须先把旧目录清掉，
        // 否则用户看到的是一份指向错误页码的目录，比没有更糟。
        .onChange(of: bridge.unitCount) { _, newValue in
            state.smartOutline.syncUnitCount(newValue, unitName: state.unitName)
        }
        .task(id: document.id) {
            chat.bind(to: document)
            state.smartOutline.bind(to: document, unitName: state.unitName)
            state.documentMetadata = bridge.metadata
            await applyLaunchDiagnostics()
        }
    }

    // MARK: - 面板宽度

    /// 面板宽度的双向绑定。
    ///
    /// 直通 `settingsStore.ui` 而不是先存一份本地 `@State`：宽度的唯一真相源就该是配置
    /// （它要持久化）。本地再留一份的话，设置页改了宽度、或者双击复位，两边就会不同步，
    /// 表现为"拖完没反应，重启才生效"这类难查的毛病。
    private var sidebarWidth: Binding<Double> {
        Binding(
            get: { state.settingsStore.ui.sidebarWidth },
            set: { state.settingsStore.ui.sidebarWidth = $0 }
        )
    }

    private var aiPanelWidth: Binding<Double> {
        Binding(
            get: { state.settingsStore.ui.aiPanelWidth },
            set: { state.settingsStore.ui.aiPanelWidth = $0 }
        )
    }

    @ViewBuilder
    private var readerSurface: some View {
        let reader = state.settingsStore.reader
        let theme = reader.theme

        switch document.kind {
        case .pdf:
            PDFReaderView(document: document, theme: theme, reader: reader)
        case .epub:
            EPUBReaderView(document: document, theme: theme, reader: reader)
        }
    }

    /// 自检通道：把侧栏钉在指定页签、塞一段假选区。
    ///
    /// 必须等文档真的装好之后再动手——阅读视图在 `prepare()` 里会调 `bridge.reset()`，
    /// 早于它插入的状态会被清掉，自检就会得到「浮层没出现」这种假结论。
    private func applyLaunchDiagnostics() async {
        let needsWork = LaunchOptions.sidebarTab != nil
            || LaunchOptions.injectsDemoSelection
            || LaunchOptions.runAction != nil
            || LaunchOptions.jumpToUnit != nil
            || LaunchOptions.smartOutline
        guard needsWork else { return }

        try? await Task.sleep(nanoseconds: 1_000_000_000)

        if let raw = LaunchOptions.sidebarTab, let tab = SidebarTab(rawValue: raw) {
            bridge.sidebarTab = tab
        }

        if LaunchOptions.injectsDemoSelection {
            bridge.selection = ReaderSelection(
                text: "文化资本的传递并不经过市场，而是在家庭日常中完成。",
                locator: .pdf(page: 0, charOffset: 0)
            )
        }

        if let raw = LaunchOptions.runAction {
            await runLaunchAction(raw)
        }

        if let target = LaunchOptions.jumpToUnit {
            await runLaunchJump(target)
        }

        if LaunchOptions.smartOutline {
            await runSmartOutlineAudit()
        }
    }

    /// 自检：跑一遍智能目录的两步链路，并把结果落成可核对的日志。
    ///
    /// 为什么必须走完整流程而不是只验解析器：解析器在单元测试里能造输入，但
    /// 「每页开头取出来的到底是什么」「模型看到之后给出的是不是真的落在这本书的页数范围内」
    /// 「点击条目之后画面到底滚没滚」这三件事，只有真的跑一遍才知道。
    private func runSmartOutlineAudit() async {
        let path = document.url.standardizedFileURL.path
        let cacheFile = AppPaths.smartOutlineFile(forPath: path)

        NSLog("[Lumen][outline] 生成前：缓存文件存在=\(FileManager.default.fileExists(atPath: cacheFile.path))"
            + " 单元数=\(bridge.unitCount) 单元名=\(state.unitName)")

        // 绑定时从磁盘载入了什么，是「缓存复用」这条链路的唯一证据。
        // 不记这一条的话，「复用成功」和「每次都重新生成」在日志上长得一模一样，
        // 而后者意味着用户每开一次书就被扣一次钱。
        let loaded = state.smartOutline.outline
        NSLog("[Lumen][outline] 绑定后（尚未生成）：缓存条目数=\(loaded?.entries.count ?? -1)"
            + " 缓存记录单元数=\(loaded?.sourceUnitCount ?? -1)"
            + " 与当前文档匹配=\(loaded.map { $0.isValid(forUnitCount: bridge.unitCount) } ?? false)")

        state.generateSmartOutline()

        // 轮询到不再「正在跑」。首次生成要走一次真实的模型请求，给足时间但不要无限等。
        let deadline = Date().addingTimeInterval(180)
        while state.smartOutline.phase.isWorking, Date() < deadline {
            try? await Task.sleep(nanoseconds: 300_000_000)
        }
        // 让出一点时间给落盘与界面动画落定
        try? await Task.sleep(nanoseconds: 500_000_000)

        switch state.smartOutline.phase {
        case .failed(let message):
            NSLog("[Lumen][outline] 生成失败：\(message)")
        case .working:
            NSLog("[Lumen][outline] 生成超时（180s）")
        case .idle:
            break
        }

        guard let outline = state.smartOutline.outline else {
            NSLog("[Lumen][outline] 没有产出目录，自检结束")
            return
        }

        NSLog("[Lumen][outline] 条目数=\(outline.entries.count) 记录单元数=\(outline.sourceUnitCount)"
            + " 模型=\(outline.modelName)")
        for entry in outline.entries.prefix(15) {
            let indent = String(repeating: "·", count: max(0, entry.depth))
            NSLog("[Lumen][outline]   \(indent)「\(entry.title)」→ 单元 \(entry.unitIndex + 1)"
                + " 摘要字数=\(entry.summary?.count ?? 0)")
        }

        let size = (try? FileManager.default.attributesOfItem(atPath: cacheFile.path))?[.size] as? Int
        NSLog("[Lumen][outline] 缓存文件 \(cacheFile.path) 大小=\(size.map(String.init) ?? "无")")

        // 点击条目的闭环：跳到最后一条，核对确实落到了它指向的位置。
        // 用最后一条是因为它在书的后半段——如果实现里有什么「只在前几页打转」的问题，
        // 拿第一条验会被掩盖。
        if let last = outline.entries.last {
            NSLog("[Lumen][outline] 跳转前：\(bridge.positionLabel)")
            let landed = state.jump(toUnit: last.unitIndex)
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            NSLog("[Lumen][outline] 点「\(last.title)」→ 解析为 0-based \(landed.map(String.init) ?? "nil")"
                + "，跳转后：\(bridge.positionLabel)")
        }

        // 第二步：单节摘要。
        if let number = LaunchOptions.smartOutlineSummaryIndex,
           number >= 1, outline.entries.indices.contains(number - 1) {
            let entry = outline.entries[number - 1]
            NSLog("[Lumen][outline] 请求第 \(number) 条的摘要：「\(entry.title)」")
            state.smartOutline.summarize(
                entry: entry,
                bridge: bridge,
                metadata: bridge.metadata,
                config: state.settingsStore.activeProvider
            )

            let summaryDeadline = Date().addingTimeInterval(120)
            // 等的是 `summarizing` 而不是 `phase`：摘要是逐条并行的，
            // 它不参与「骨架生成」那条 phase 状态机。等错了对象会立刻退出循环，
            // 然后在请求还在飞的时候读到一个空摘要——那看起来就像功能坏了。
            while state.smartOutline.summarizing.contains(entry.id), Date() < summaryDeadline {
                try? await Task.sleep(nanoseconds: 300_000_000)
            }
            try? await Task.sleep(nanoseconds: 400_000_000)

            if case .failed(let message) = state.smartOutline.phase {
                NSLog("[Lumen][outline] 摘要失败：\(message)")
            }
            let after = state.smartOutline.outline?.entries.first(where: { $0.id == entry.id })
            NSLog("[Lumen][outline] 摘要结果 字数=\(after?.summary?.count ?? 0)"
                + " 内容=\(after?.summary?.replacingOccurrences(of: "\n", with: "⏎").prefix(200).description ?? "nil")")
        }
    }

    /// 自检：跳页并核对结果。
    ///
    /// 三段都打：跳之前在哪、请求的是第几个、跳之后在哪。
    /// 只打最后一段的话，「跳成功了」和「本来就在这一页」输出完全相同，
    /// 等于没验。
    private func runLaunchJump(_ target: Int) async {
        NSLog("[Lumen][jump] 跳转前：\(bridge.positionLabel)（共 \(bridge.unitCount) 个单元）")

        let landed = state.jump(toUnit: target - 1)

        // 等视图真的滚过去：PDF 的 goTo 是异步的，立刻读会拿到旧值
        try? await Task.sleep(nanoseconds: 900_000_000)

        NSLog(
            "[Lumen][jump] 请求第 \(target) 个 → 解析为 0-based \(landed.map(String.init) ?? "nil")"
                + "，跳转后：\(bridge.positionLabel)"
        )
    }

    /// 自检通道：按一次指定动作，然后把剪贴板回读出来。
    ///
    /// 为什么要等：`copyFullText` 是异步的（扫描件还要逐页跑 OCR），
    /// 而 `run` 是同步返回的——不等待就会在剪贴板还没写进去时去 dump，
    /// 得到的「剪贴板是空的」将是假象而不是真 bug。
    private func runLaunchAction(_ raw: String) async {
        guard let action = LumenAction(rawValue: raw) else {
            NSLog("[Lumen][action] 未知动作：\(raw)")
            return
        }

        NSLog("[Lumen][action] 自检执行 \(raw)")
        action.run(state)

        // 轮询到忙碌状态结束，而不是死等一个固定时长：扫描件要逐页 OCR，
        // 页数不同耗时差好几倍。固定等待要么白白拖慢文本件，要么在扫描件上
        // 于半途 dump 出「剪贴板还是空的」这种假失败。
        let deadline = Date().addingTimeInterval(120)
        while state.busy != nil, Date() < deadline {
            try? await Task.sleep(nanoseconds: 300_000_000)
        }
        // 再让出一点时间给写剪贴板和 toast 落定
        try? await Task.sleep(nanoseconds: 500_000_000)

        ClipboardAudit.dump(raw)
    }
}

// MARK: - 右上角状态（页码 / 缩放）

struct ReaderStatusLayer: View {

    @EnvironmentObject private var bridge: ReaderBridge
    @EnvironmentObject private var state: AppState

    @State private var isHovering = false
    /// 页码那块的悬停态。与整条状态条的 `isHovering` 分开：
    /// 整条只是整体透明度微调，页码悬停要变色以暗示「可点」。
    @State private var isJumpHovering = false

    var body: some View {
        // 沉浸时不显示：页码已由底部 HUD 承担，这里再来一条就是重复信息，
        // 而沉浸模式要的正是「屏幕上只剩正文」。
        if !state.isImmersive,
           !bridge.isLoading, bridge.loadError == nil, !bridge.positionLabel.isEmpty {
            HStack(spacing: DS.Space.m) {
                // 页码本身做成入口：用户想跳页时的第一反应就是「点那个页码」。
                // 悬停变强调色，否则没人会想到它是能点的。
                Button {
                    withAnimation(DS.Motion.palette) { state.isPageJumpVisible = true }
                } label: {
                    ControlChip(text: bridge.positionLabel)
                        .foregroundStyle(isJumpHovering ? DS.Palette.accent : DS.Palette.textSecondary)
                }
                .buttonStyle(.plain)
                .onHover { hovering in
                    withAnimation(DS.Motion.hover) { isJumpHovering = hovering }
                }
                .help("点击跳转到指定\(documentIsPDF ? "页" : "章")（⌘G）")

                if documentIsPDF {
                    Divider().frame(height: 14)
                    Button {
                        bridge.zoomOut?()
                    } label: {
                        Image(systemName: "minus.magnifyingglass")
                    }
                    .buttonStyle(.plain)
                    .help("缩小")

                    Button {
                        bridge.zoomToFit?()
                    } label: {
                        Image(systemName: "arrow.left.and.right.square")
                    }
                    .buttonStyle(.plain)
                    .help("适合宽度")

                    Button {
                        bridge.zoomIn?()
                    } label: {
                        Image(systemName: "plus.magnifyingglass")
                    }
                    .buttonStyle(.plain)
                    .help("放大")
                }
            }
            .font(DS.Typo.ui(size: 11.5, weight: .medium))
            .foregroundStyle(DS.Palette.textSecondary)
            .padding(.horizontal, DS.Space.m)
            .padding(.vertical, 7)
            .background(
                Capsule(style: .continuous)
                    .fill(.regularMaterial)
                    .overlay(Capsule(style: .continuous).strokeBorder(DS.Palette.separator, lineWidth: 0.5))
            )
            .shadow(color: .black.opacity(0.10), radius: 10, y: 3)
            // 探针挂在 shadow 之后、外层 padding 之前：测的是胶囊本身的框，
            // 不含那 16pt 内边距，和「有没有压到别的东西」直接可比。
            .layoutProbe("statusChip")
            .padding(DS.Space.l)
            .opacity(isHovering ? 1 : 0.92)
            .onHover { hovering in
                withAnimation(DS.Motion.hover) { isHovering = hovering }
            }
        }
    }

    private var documentIsPDF: Bool {
        state.document?.kind == .pdf
    }
}

struct ControlChip: View {
    let text: String
    var body: some View {
        Text(text)
            .monospacedDigit()
            // 翻页时让数字自己滚上去，而不是整块文字硬跳一下。
            // `positionLabel` 形如「第 12 / 340 页」，是中文与数字混排：`numericText`
            // 会把其中的数字段当作要滚动的部分，其余字符照常——真遇到无法拆分的串，
            // 它自己会退化成一次淡入，不会出错。
            .contentTransition(.numericText())
            .animation(DS.Motion.quick, value: text)
    }
}

// MARK: - 划词浮动条

/// 划词后从底部中央升起的操作条。
///
/// 没有做成跟随选区的浮动气泡：PDF 里把选区矩形换算成窗口坐标要跨 PDFKit / AppKit / SwiftUI
/// 三层坐标系，缩放与滚动时极易错位；EPUB 里虽然能用 JS 拿到 rect，但两者行为就不一致了。
/// 固定在底部中央既稳定又不会遮挡正在读的那一行。
struct SelectionActionBarLayer: View {

    @EnvironmentObject private var bridge: ReaderBridge
    @EnvironmentObject private var state: AppState

    var body: some View {
        if let selection = bridge.selection, selection.isUsable {
            SelectionActionBar(selection: selection)
                // 76 而不是默认的 32：阅读区右下角常驻一条状态条（页码 + 缩放），
                // 它从底边起占到约 64pt。划词条按 32 起算会正好压在它上面——实测
                // 「追问」按钮被状态条盖住一半。抬高到与状态条完全错开。
                .padding(.bottom, 76)
                // 打在 padding 之后：报的是划词条最终落点（含那段抬升），
                // 这样和状态条的框能直接比出有没有重叠。
                .layoutProbe("selectionBar")
                .transition(.opacity.combined(with: .offset(y: 10)))
        }
    }
}

struct SelectionActionBar: View {

    let selection: ReaderSelection

    @EnvironmentObject private var bridge: ReaderBridge
    @EnvironmentObject private var state: AppState

    var body: some View {
        HStack(spacing: DS.Space.xs) {
            Label("\(selection.text.count) 字", systemImage: "text.quote")
                .font(DS.Typo.caption)
                .foregroundStyle(DS.Palette.textTertiary)
                .padding(.horizontal, DS.Space.s)
                .labelStyle(.titleAndIcon)

            Divider().frame(height: 16)

            actionButton("解释", icon: "sparkles") { trigger(.explain) }
            actionButton("翻译", icon: "character.book.closed") { trigger(.translate) }
            actionButton("追问", icon: "bubble.left.and.text.bubble.right") { trigger(.ask) }
        }
        .padding(.horizontal, DS.Space.s)
        .padding(.vertical, DS.Space.xs)
        .background(
            Capsule(style: .continuous)
                .fill(.thickMaterial)
                .overlay(Capsule(style: .continuous).strokeBorder(DS.Palette.separator, lineWidth: 0.5))
        )
        .shadow(color: .black.opacity(0.18), radius: 16, y: 6)
    }

    /// 投递请求前先把 AI 面板露出来——否则用户点了按钮却看不到任何反馈。
    private func trigger(_ kind: AIRequest.Kind) {
        if !state.isAIPanelVisible {
            withAnimation(DS.Motion.panel) { state.isAIPanelVisible = true }
        }
        state.pendingAIRequest = AIRequest(kind: kind, selection: selection)
    }

    private func actionButton(_ title: String, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: icon)
                .font(DS.Typo.ui(size: 12, weight: .medium))
                .padding(.horizontal, DS.Space.s)
                .padding(.vertical, 5)
                .contentShape(Rectangle())
        }
        .buttonStyle(SelectionBarButtonStyle())
    }
}

struct SelectionBarButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(DS.Palette.textPrimary)
            .background(
                RoundedRectangle(cornerRadius: DS.Radius.s, style: .continuous)
                    .fill(configuration.isPressed ? DS.Palette.accentSoft : .clear)
            )
    }
}
