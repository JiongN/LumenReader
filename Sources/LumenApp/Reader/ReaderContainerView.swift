import SwiftUI
import LumenKit

/// 阅读器外壳。
///
/// 布局刻意用 HStack + 显式分隔线而不是 NavigationSplitView：
/// 需要同时控制侧栏、阅读区、AI 面板三栏的宽度与出现动画，且要自定义分隔线的颜色，
/// NavigationSplitView 会强加系统材质与自带的侧栏开关，反而更难收敛视觉。
struct ReaderContainerView: View {

    let document: OpenDocument

    @EnvironmentObject private var state: AppState
    /// 通道与对话模型都挂在 AppState 上（菜单栏、命令面板也要用），这里只是取用
    private var bridge: ReaderBridge { state.bridge }
    private var chat: AIChatModel { state.chat }

    var body: some View {
        HStack(spacing: 0) {
            if state.isSidebarVisible {
                SidebarColumn()
                    .frame(width: DS.Size.sidebarIdeal)
                    .layoutProbe("sidebar")
                    .background(.regularMaterial)
                    // 淡入 + 10pt 位移，而不是 `.move(edge: .leading)`：
                    // 整宽滑入会让阅读区看起来被「推」了一下，三栏同时在场时尤其晃眼。
                    .transition(.opacity.combined(with: .offset(x: -10)))
                verticalDivider
            }

            readerSurface
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .layoutProbe("readerSurface")
                // 两条浮层都贴在**阅读区**上，不是贴在整个三栏容器上。
                //
                // 挂在容器上时「右下角」会落进 AI 面板：状态条（页码 + 缩放）正好压住
                // AI 输入框的右半边和发送按钮，既看不见也点不到；划词条的居中位置也会
                // 随 AI 面板的显隐漂移。浮层本来就是给阅读区用的（页码、缩放、划词），
                // 锚在阅读区才是它的语义位置。
                .overlay(alignment: .bottom) { SelectionActionBarLayer() }
                .overlay(alignment: .bottomTrailing) { ReaderStatusLayer() }

            if state.isAIPanelVisible {
                verticalDivider
                AIPanelView()
                    .frame(width: DS.Size.aiPanelIdeal)
                    .layoutProbe("aiPanel")
                    .background(.regularMaterial)
                    .transition(.opacity.combined(with: .offset(x: 10)))
            }
        }
        // environmentObject 必须放在所有 overlay 之后：overlay 会把内容包在修饰过的视图
        // 之外，先注入的话 overlay 里的视图看不到这个环境对象，运行时直接 fatalError。
        .environmentObject(bridge)
        .environmentObject(chat)
        .onChange(of: bridge.metadata) { _, newValue in
            state.documentMetadata = newValue
        }
        .task(id: document.id) {
            chat.bind(to: document)
            state.documentMetadata = bridge.metadata
            await applyLaunchDiagnostics()
        }
    }

    private var verticalDivider: some View {
        Rectangle()
            .fill(DS.Palette.separator)
            .frame(width: 1)
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

    var body: some View {
        if !bridge.isLoading && bridge.loadError == nil && !bridge.positionLabel.isEmpty {
            HStack(spacing: DS.Space.m) {
                ControlChip(text: bridge.positionLabel)

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
