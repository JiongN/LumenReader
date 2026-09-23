import SwiftUI
import LumenKit

/// 阅读器外壳。
///
/// 布局刻意用 HStack + 显式分隔线而不是 NavigationSplitView：
/// 需要同时控制侧栏、阅读区、AI 面板三栏的宽度与出现动画，且要自定义分隔线的颜色，
/// NavigationSplitView 会强加系统材质与自带的侧栏开关，反而更难收敛视觉。
struct ReaderContainerView: View {

    /// 这个阅读界面所属的标签会话（文档 + bridge + chat + 智能目录）。
    @ObservedObject var session: ReaderSession

    private var document: OpenDocument { session.document }

    @EnvironmentObject private var state: AppState
    /// 宽度直接观察 `SettingsStore` 而不是经由 `AppState` 间接读：
    ///
    /// 拖动 AI 面板分隔线写的是 `settingsStore.ui.aiPanelWidth`，`@Published` 触发的是
    /// **SettingsStore** 的 `objectWillChange`。若只观察 `AppState`，
    /// 「设置变了」这个消息根本传不到这里——拖动手势每帧都在写值、模型每帧都在变，
    /// 布局却纹丝不动，看起来就是「分隔线拖不动」。
    @EnvironmentObject private var settings: SettingsStore

    /// 拖动 AI 面板分隔线期间的**即时**宽度。nil = 没在拖，用设置里的已提交值。
    ///
    /// 存在容器里而不是每帧写回 `SettingsStore`：宽度是 `@Published` 结构体
    /// `AppSettings` 的一个字段，每帧写一次会让所有观察 `SettingsStore` 的视图
    /// 整棵失效——阅读区（PDFKit / WKWebView）与两块 `.regularMaterial` 都在其中，
    /// 表现就是拖动手感抖动。松手时由 `PanelResizeHandle` 提交一次。
    ///
    /// 交由 `LivePanelWidth` 持有并**按显示刷新合并**：指针事件率高于屏幕刷新率
    /// （触控板 90–120Hz、游戏鼠标上千 Hz），每个事件都重排 + 重光栅化是拖动手感抖动的
    /// 直接来源（实测「每帧 3 次指针写入 → 3 次 PDFView 重光栅化」）。详见 `LivePanelWidth`。
    ///
    /// 它**不是**第二份真相源：仅在一个手势期间有效，手势结束立刻置回 nil，
    /// 之后一律读设置。所以「双击复位」这类外部改动照旧实时生效。
    @StateObject private var livePanelWidth = LivePanelWidth(
        coalescesFrames: !LaunchOptions.jankNoCoalesce
    )
    /// 容器（窗口内容区）的可用宽度。面板上限要按它动态收窄。
    @State private var containerWidth: CGFloat = 0

    /// 阅读通道属于**当前标签的会话**：多标签并存时，A 标签的阅读视图不能把回调接到 B 标签的 bridge 上。
    /// 对话模型（chat）则是全局共享的那一份（见 `AppState.chat`），任何标签都通过它访问活动会话。
    private var bridge: ReaderBridge { session.bridge }
    private var chat: AIChatModel { state.chat }

    var body: some View {
        // 卡顿自检：三栏整棵树每次重排都会走到这里。必须写在 body 里而不是做成 ViewModifier——
        // 修饰符对「值相等的节点」会被复用，tick 只在首帧跑一次，计数恒为 0（本轮踩过）。
        let _ = Jank.tick(.containerBody)
        HStack(spacing: 0) {
            // 图标栏常驻（沉浸模式除外）：内容面板可以收起，切页签的入口不能跟着消失。
            if !state.isImmersive {
                // 图标栏由 `SidebarRail` 转一层：它自己观察 `bridge`，这样
                // 「只切页签、别的什么都没变」时高亮能跟上（详见 `SidebarRail` 的注释）。
                // 探针仍叫 `sidebarRail`，几何断言不受影响。
                SidebarRail(
                    tabs: SidebarTab.available(for: document.kind),
                    isExpanded: state.isSidebarVisible,
                    layoutScale: layoutScale,
                    onSelect: selectSidebarTab
                )
                .frame(width: railWidth)
                .layoutProbe("sidebarRail")
                .background(DS.Palette.surfaceSunken)
                .transition(.opacity.combined(with: .offset(x: -10)))
            }

            if state.isSidebarVisible && !state.isImmersive {
                SidebarColumn()
                    // 宽度**固定**（DS.Size.sidebarIdeal = 248pt），不再从设置读取，
                    // 也不再挂拖拽分隔线。侧栏装的是目录 / 搜索结果 / 批注这类结构化列表，
                    // 宽度该由版式决定；用户想腾出阅读区空间，收起整块面板即可。
                    .frame(width: sidebarWidth)
                    .layoutProbe("sidebar")
                    .background(DS.Palette.surfaceSunken)
                    // 淡入 + 10pt 位移，而不是 `.move(edge: .leading)`：
                    // 整宽滑入会让阅读区看起来被「推」了一下，三栏同时在场时尤其晃眼。
                    .transition(.opacity.combined(with: .offset(x: -10)))
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


                readerSurface
                    .frame(
                        maxWidth: .infinity,
                        maxHeight: .infinity
                    )
                    .layoutProbe("readerSurface")
                    // 两条浮层都贴在**阅读区**上，不是贴在整个三栏容器上。
                    //
                    // 挂在容器上时「右下角」会落进 AI 面板：状态条（页码 + 缩放）正好压住
                    // AI 输入框的右半边和发送按钮，既看不见也点不到；划词条的居中位置也会
                    // 随 AI 面板的显隐漂移。浮层本来就是给阅读区用的（页码、缩放、划词），
                    // 锚在阅读区才是它的语义位置。
                    // 划词条在沉浸模式下同样保留：沉浸只是收起面板，不是收起「选中文字后能做的事」。
                    .overlay(alignment: .bottom) {
                        if !LaunchOptions.pdfBareOverlays { SelectionActionBarLayer() }
                    }
                    // 沉浸时收起状态条：页码已经在底部 HUD 上显示，再留一条属于重复信息，
                    // 而沉浸模式要的恰恰是「屏幕上只有正文」。
                    .overlay(alignment: .bottomTrailing) {
                        if !LaunchOptions.pdfBareOverlays { ReaderStatusLayer() }
                    }


            }

            if state.isAIPanelVisible && !state.isImmersive {
                PanelResizeHandle(
                    committedWidth: aiPanelWidth,
                    liveWidth: liveWidthBinding,
                    range: aiPanelRange,
                    defaultWidth: UISettings.PanelWidth.aiDefault * Double(layoutScale),
                    panelIsLeading: false,
                    onCommit: { value in
                        let scale = Double(layoutScale)
                        settings.commitAIPanelWidth(value / scale, maxWidth: aiPanelCap / scale)
                    },
                    onDragStateChange: { bridge.setPanelWidthDragging?($0) }
                )

                AIPanelView()
                    .frame(width: aiPanelWidth)
                    .layoutProbe("aiPanel")
                    .background(DS.Palette.surfaceSunken)
                    .transition(.opacity.combined(with: .offset(x: 10)))
            }
        }
        .layoutProbe("readerHStack")
        // 量窗口内容区宽度。用 background 而不是把 HStack 包进 GeometryReader：
        // GeometryReader 会参与布局并把「谁决定宽度」这件事搅进来，
        // 而这里只是想读一个数，不该反过来影响布局。
        .background {
            GeometryReader { proxy in
                Color.clear
                    .onAppear { containerWidth = proxy.size.width }
                    .onChange(of: proxy.size.width) { _, width in containerWidth = width }
            }
        }
        // environmentObject 必须放在所有 overlay 之后：overlay 会把内容包在修饰过的视图
        // 之外，先注入的话 overlay 里的视图看不到这个环境对象，运行时直接 fatalError。
        // 这里统一注入**本会话**的对象（SessionHostView 也注了一份，这里再注保证
        // overlay 子树同样拿到的是本标签而不是当前活动标签的通道）。
        .environmentObject(session)
        .environmentObject(bridge)
        .environmentObject(chat)
        .environmentObject(session.smartOutline)
        .onChange(of: bridge.metadata) { _, newValue in
            session.documentMetadata = newValue
        }
        // 单元数由阅读视图异步报上来（PDF 要等文档解析完）。智能目录拿它判定
        // 缓存是否还对得上当前文档——一本被替换过的书必须先把旧目录清掉，
        // 否则用户看到的是一份指向错误页码的目录，比没有更糟。
        .onChange(of: bridge.unitCount) { _, newValue in
            session.smartOutline.syncUnitCount(newValue, unitName: state.unitName)
        }
        .task(id: document.id) {
            session.documentMetadata = bridge.metadata
            await applyLaunchDiagnostics()
        }
    }

    // MARK: - 面板宽度

    /// 侧栏与 AI 面板当前是否真的在版面上（沉浸模式下都被收走）。
    private var sidebarIsVisible: Bool { state.isSidebarVisible && !state.isImmersive }
    private var aiPanelIsVisible: Bool { state.isAIPanelVisible && !state.isImmersive }

    /// AI 面板用户这一刻「想要」的宽度：拖动中用即时值，否则用落库值。
    /// 普通窗口保持现有密度；外接大屏上的宽窗口按比例放大两侧栏。
    private var layoutScale: CGFloat { DS.Size.windowScale(for: containerWidth) }
    private var railWidth: CGFloat { LeftRail.width * layoutScale }

    /// 分隔线用的即时宽度绑定。读的是**已应用**值；写走 `LivePanelWidth.submit`，
    /// 由它按显示刷新合并（不是在绑定这层直接落状态，否则合并就白做了）。
    private var liveWidthBinding: Binding<Double?> {
        Binding(
            get: { self.livePanelWidth.value },
            set: { self.livePanelWidth.submit($0) }
        )
    }

    /// 三栏此刻的显示宽度。
    ///
    /// **侧栏是常量，AI 面板按需分配**：侧栏宽度固定 248pt（不再读设置、
    /// 也没有拖拽入口），AI 面板拿「剩下但不超过它自己要的、且不低于下限 300pt」，
    /// 阅读区低于保底 320pt 时由 AI 面板顶住下限、阅读区让位。
    ///
    /// 落库值只是「用户想要多少」，本轮布局能给多少要按当前容器宽度重算：
    /// 窗口被拉小之后不会有任何一次拖拽提交，若不重算，旧宽度会原样参与布局——
    /// 窄窗口下阅读区被挤没、图标栏被推到屏幕外。重算**不写回设置**：
    /// 落库值仍然只由拖拽 / 双击改动，窗口拉回原尺寸偏好自动回来。
    private var panelLayout: PanelLayout {
        PanelWidthPolicy.resolve(
            containerWidth: containerWidth,
            showsRail: !state.isImmersive,
            sidebarVisible: sidebarIsVisible,
            aiPanelPreferred: aiPanelIsVisible
                ? (livePanelWidth.value.map { $0 / Double(layoutScale) } ?? settings.ui.aiPanelWidth)
                : nil
        )
    }

    /// 侧栏**当前应当显示**的宽度。固定值——侧栏不再接受任何宽度输入。
    private var sidebarWidth: Double {
        panelLayout.sidebar ?? UISettings.PanelWidth.sidebarDefault * Double(layoutScale)
    }

    private var aiPanelWidth: Double {
        panelLayout.aiPanel ?? UISettings.PanelWidth.aiDefault * Double(layoutScale)
    }

    private var aiPanelRange: ClosedRange<Double> {
        (UISettings.PanelWidth.aiRange.lowerBound * Double(layoutScale))...aiPanelCap
    }

    private var aiPanelCap: Double {
        PanelWidthPolicy.aiCap(
            containerWidth: containerWidth,
            showsRail: !state.isImmersive,
            sidebarVisible: sidebarIsVisible
        )
    }

    /// 点图标栏：点已激活的那一格 = 收起内容面板；点别的 = 展开并切过去。
    ///
    /// 两个方向共用 `revealSidebar`（⌘1–⌘5 与菜单项也走它），
    /// 所以「切到某页签时若面板收起要一并展开」这条规则只有一份实现。
    private func selectSidebarTab(_ tab: SidebarTab) {
        if state.isSidebarVisible && bridge.sidebarTab == tab {
            state.setSidebarVisible(false)
        } else {
            state.revealSidebar(tab: tab)
        }
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
        // 多标签 / 多窗口下，每个标签挂载都会跑到这里；自检在一个进程里只允许跑一次，
        // 否则后开的标签会重复注入假选区、重复跑智能目录与卡顿自检。
        guard ReaderContainerDiagnostics.beginOnce() else { return }

        // 侧栏页签**先**钉住，再跑后面的自检。
        //
        // 顺序很重要：卡顿自检的滚动阶段要量的正是「位置回调每帧重建缩略图/批注侧栏」
        // 这条链路（team-lead 的假设之一）。若等滚动跑完才切页签，量到的就是「侧栏收起时」
        // 的滚动——恰好绕开了最可能存在的那条重活路径，读数会假绿。
        if let raw = LaunchOptions.sidebarTab, let tab = SidebarTab(rawValue: raw) {
            bridge.sidebarTab = tab
        }

        // 页签切换是一次 SwiftUI 状态变更，要让侧栏（缩略图面板）真的挂载起来，
        // 得先还它一个 runloop 周期；否则滚动阶段量的是「侧栏还没出现」的窗口。
        if LaunchOptions.jankReport {
            try? await Task.sleep(nanoseconds: 800_000_000)
        }

        // 面板宽度响应式自检：等布局稳定后写一次宽度，断言布局真的跟着变。
        // 必须挂在这里（文档装好、视图出现之后）——启动早期写入测不到响应式链路。
        if LaunchOptions.resizeReport {
            await ResizeAudit.run(state: state)
        }

        // 被动监视（`--jank-watch`）：**不驱动任何东西**，只挂上埋点、每 2 秒把汇总落一行
        // 到 `/tmp/lumen-jank-watch.log`，交给用户用真触控板产生手势复现。与 `--jank-report`
        // 相反：这个是「用户产生手势、我们只记录」，专门用来复现合成事件搓不出来的连续惯性滚动。
        if LaunchOptions.jankWatch {
            // 闭包**惰性**读 bridge：本函数可能在子视图（PDFReaderView）把 provider 装上之前就跑，
            // 此刻直接取 `bridge.jankScrollSurface` 会拿到 nil 并永久固化。
            JankWatch.shared.start(surface: { bridge.jankScrollSurface?() })
        }

        // 连续交互卡顿自检：驱动真实的滚动 / 拖动，量主线程停顿与每步重活（`--jank-report 1`）。
        // 挂在这里（文档装好、视图出现之后）——启动早期驱动测不到「装好之后的手感」。
        if LaunchOptions.jankReport {
            // 拖动段的**环境自证**：拖动是「把即时宽度写成版面」的链路，只有 AI 面板在版面上
            // 时它才成立。把此刻的三栏状态与可用区间打出来——否则同一份构建换文档/窗口后
            // 读数突变时，无法判断是「时序」还是「面板根本没在版面上」（本轮踩过）。
            NSLog("%@", "[Lumen][jank] 拖动环境：AI面板可见=\(state.isAIPanelVisible)"
                + " 侧栏可见=\(state.isSidebarVisible) 沉浸=\(state.isImmersive)"
                + " 容器宽=\(Int(containerWidth))pt AI面板实宽=\(Int(aiPanelWidth))pt"
                + " 拖动区间=\(Int(aiPanelRange.lowerBound))…\(Int(aiPanelRange.upperBound))pt")
            await JankAudit.run(
                // 惰性读：PDFView 由子视图持有、异步装好，直接取值可能拿到 nil。
                scrollSurface: { bridge.jankScrollSurface?() },
                // 把即时宽度这份**可观察对象**整体交给自检，而不是只给一个 `Set` 闭包：
                // 自检要能读到「写入次数 / 实际应用次数 / 显示刷新回调次数」，用来把
                // 「没写」「写了没应用」分开（否则拖动段计数恒 0 时无法判断是不是没等到刷新）。
                liveWidth: livePanelWidth,
                committedWidth: aiPanelWidth,
                range: aiPanelRange,
                steps: LaunchOptions.jankSteps
            )
        }

        // 「重新生成」自检：需要文档装好（上下文来自 bridge），所以挂在这里
        if LaunchOptions.rerunReport {
            await RerunAudit.run(session: session, state: state)
        }

        // 面板展开 / 收起过渡自检（`--panel-transition-report 1`）。
        // 同样必须挂在文档装好、PDF 控制器已接上桥之后——早期跑会拿到空桥的 nil 探针。
        if LaunchOptions.panelTransitionReport {
            await PanelTransitionAudit.run(state: state)
        }

        // 面板收起 / 展开的**卡顿**自检（`--panel-frame-report 1`）：量代价，不是验机制。
        // 同样挂在文档装好之后；与 `--panel-transition-report` 可同时跑，互不依赖。
        if LaunchOptions.panelFrameReport {
            await PanelFrameAudit.run(state: state)
        }

        // 侧栏页签切换自检（`--sidebar-tab-report 1`）。必须在这里跑：
        // 它要调的是 `selectSidebarTab(_:)`——图标栏 `onSelect` 接的就是它，
        // 而它是本类型的私有方法，只有这里够得着。绕到 `revealSidebar` 去验等于换了一条路。
        if LaunchOptions.sidebarTabReport {
            await runSidebarTabAudit()
        }

        // 段落抽取自检（`--paragraph-report 1`）。放在这里而不是更早：
        // 真机那组要读到 `session.document` 已经绑好的路径；但合成行那组不依赖文档，
        // 所以就算没打开文档，前面那组照跑（`documentPath` 传 nil 即可）。
        if LaunchOptions.paragraphReport {
            await ParagraphAudit.run(documentPath: session.document.url.path)
        }

        // PDF 翻译面板自检（`--translation-report 1`）。必须在这里：
        // 覆盖「机器/LLM 切换」的字段语义、「点击译文定位正文」的真机跳转、
        // 以及 `sidebarPane_translation` 的布局探针；需要文档装好、桥接上。
        if LaunchOptions.translationPanelReport {
            await TranslationPanelAudit.run(
                documentPath: session.document.url.path,
                bridge: bridge,
                state: state,
                settings: settings
            )
        }

        let needsWork = LaunchOptions.sidebarTab != nil
            || LaunchOptions.injectsDemoSelection
            || LaunchOptions.injectsDemoClick
            || LaunchOptions.injectsDemoAnswer
            || LaunchOptions.runAction != nil
            || LaunchOptions.jumpToUnit != nil
            || LaunchOptions.smartOutline
            || LaunchOptions.exitFullScreenAfter != nil
            || LaunchOptions.jankReport
        guard needsWork else { return }

        try? await Task.sleep(nanoseconds: 1_000_000_000)

        if LaunchOptions.injectsDemoSelection {
            // 拖动来源：浮条应当出现。这里显式标 true，是为了让这条自检在「只拖动才弹」
            // 这道门之后仍然能看见浮条——不标的话它会被门挡掉，自检红得没有意义。
            bridge.selection = ReaderSelection(
                text: "文化资本的传递并不经过市场，而是在家庭日常中完成。",
                locator: .pdf(page: 0, charOffset: 0)
            )
            bridge.selectionFromDrag = true
        }

        if LaunchOptions.injectsDemoClick {
            // 单击来源：内容与上面完全相同，唯独来源是「单击」——用来证伪那道门。
            // 若有人把门删了，这条注入会让浮条出现，`--demo-click` 的「探针缺席」断言立刻红。
            bridge.selection = ReaderSelection(
                text: "文化资本的传递并不经过市场，而是在家庭日常中完成。",
                locator: .pdf(page: 0, charOffset: 0)
            )
            bridge.selectionFromDrag = false
        }

        if LaunchOptions.injectsDemoAnswer {
            // 长文本排版自检：注入一条含长 URL / 长代码行 / 长标识符的假回答。
            // 注入后等一拍再截图，让「跟随到底部」的滚动落定。
            state.chat.seedDemoAnswer()
            try? await Task.sleep(nanoseconds: 600_000_000)
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

        if let delay = LaunchOptions.exitFullScreenAfter {
            await runImmersiveExitAudit(after: delay)
        }
    }

    /// 自检：侧栏页签切换（`--sidebar-tab-report 1`）。
    ///
    /// **存在的理由**：用户报「左栏图标栏里无论点哪一项，侧栏都不切换」。
    /// 排查已排除掉一批：图标栏 `LeftRail.railButton` 传的就是被点的那一格；
    /// `SidebarTab.available(for:)` / `switch bridge.sidebarTab` 的分支对照没错；
    /// `--run-action showThumbnails`（走 `state.revealSidebar`）**能让侧栏真的换页签**
    /// —— 也就是说「切换函数」是通的，「发起点击」那侧才是嫌疑。
    ///
    /// 所以本通道**直接调 `selectSidebarTab(_:)`**（图标栏 `onSelect` 接的就是它），
    /// 并盯三件事：
    ///
    /// | # | 断言 | 防的是什么 |
    /// | - | ---- | ---------- |
    /// | ① | 点击写入的目标通道与图标栏读取的通道是**同一个对象** | 写入落到另一个 bridge（静默失效，不报错） |
    /// | ② | 走完点击路径后 `bridge.sidebarTab` 等于被点的页签 | 点击根本没到按钮 / 传错页签 |
    /// | ③ | 该页签的**面板探针在位、其余页签的探针已注销** | 「状态变了但界面没换」这类假绿 |
    ///
    /// 外加两条：点已激活的那一格 = 收起面板；以及一个**反向对照**给 ① 证伪。
    private func runSidebarTabAudit() async {
        // 等文档装好、侧栏挂载完成
        try? await Task.sleep(nanoseconds: 1_500_000_000)

        var passed = 0
        var failures: [String] = []
        func check(_ name: String, _ ok: Bool, _ detail: String = "") {
            if ok { passed += 1 } else { failures.append(name) }
            NSLog("%@", "[Lumen][sidebar-tab] \(ok ? "✅" : "❌") \(name)"
                  + (ok || detail.isEmpty ? "" : " —— \(detail)"))
        }

        let tabs = SidebarTab.available(for: document.kind)
        NSLog("%@", "[Lumen][sidebar-tab] 本文档可用页签：\(tabs.map(\.rawValue).joined(separator: ", "))"
              + "；当前 bridge.sidebarTab=\(bridge.sidebarTab.rawValue)"
              + "；侧栏可见=\(state.isSidebarVisible)")

        // ── ① 通道身份 ──
        //
        // 这是本通道最重要的一条：图标栏的选中态读 `bridge.sidebarTab`（本标签的通道），
        // 而 `selectSidebarTab` → `state.revealSidebar` 写的是 `state.bridge`
        // （= `activeSession?.bridge ?? idleBridge`）。两者一旦不是同一个对象，
        // 点下去既不报错、也不见效 —— 正好是用户描述的现象。
        check("点击写入的通道与图标栏读取的通道是同一个对象",
              state.bridge === bridge,
              "state.bridge 与 session.bridge 不是同一个对象"
                  + "（activeSession \(state.activeSession?.id.uuidString.prefix(8) ?? "nil")"
                  + " vs session \(session.id.uuidString.prefix(8))，homeTab=\(state.homeTabIsActive)）")

        // ── ②③ 逐页签走真实点击路径 ──
        for tab in tabs {
            // 先保证面板展开（收起时点击的语义是「展开并切过去」）
            if !state.isSidebarVisible { state.setSidebarVisible(true, animated: false) }
            // 先切到「另一个」页签，保证这次点击是一次**真实的变更**而不是空操作。
            // 少了这一步，断言可能因为「本来就停在这个页签」而恒真。
            if let other = tabs.first(where: { $0 != tab }), bridge.sidebarTab == tab {
                state.revealSidebar(tab: other)
                try? await Task.sleep(nanoseconds: 250_000_000)
            }

            selectSidebarTab(tab)
            try? await Task.sleep(nanoseconds: 450_000_000)

            check("点「\(tab.fullTitle)」后通道页签已切换",
                  bridge.sidebarTab == tab,
                  "期望 \(tab.rawValue)，实际 \(bridge.sidebarTab.rawValue)")

            let mine = LayoutAuditLog.shared.frame(named: "sidebarPane_\(tab.rawValue)")
            let others = tabs.filter { $0 != tab }
                .compactMap { t -> String? in
                    LayoutAuditLog.shared.frame(named: "sidebarPane_\(t.rawValue)") != nil ? t.rawValue : nil
                }
            check("点「\(tab.fullTitle)」后该页签的面板真的挂载了（探针在位）",
                  mine != nil,
                  "sidebarPane_\(tab.rawValue) 探针缺席 —— 通道变了但内容没换")
            check("点「\(tab.fullTitle)」后其余页签的面板已摘下（反向对照，防恒真）",
                  others.isEmpty,
                  "仍在上报的其它页签探针：\(others.joined(separator: ", "))")
        }

        // ── 点已激活的那一格 = 收起面板 ──
        if let first = tabs.first {
            if !state.isSidebarVisible { state.setSidebarVisible(true, animated: false) }
            state.revealSidebar(tab: first)
            try? await Task.sleep(nanoseconds: 250_000_000)
            selectSidebarTab(first)
            try? await Task.sleep(nanoseconds: 500_000_000)
            check("点已激活的那一格 = 收起面板",
                  state.isSidebarVisible == false,
                  "isSidebarVisible 仍为 \(state.isSidebarVisible)")
            state.setSidebarVisible(true, animated: false)
            try? await Task.sleep(nanoseconds: 300_000_000)
        }

        // ── ④ 反向对照：把「通道身份」这条断言证伪 ──
        //
        // 期望 `state.bridge !== bridge` —— 若真出现这种情况，① 会红。
        // 本组证明 ① 不是恒真：先记下当前是否同源，再从「主页标签」绕一圈回来，
        // 看 `activate(_:)` 有没有把 homeTabIsActive 清掉。
        let homeWasActive = state.homeTabIsActive
        state.addHomeTab()
        try? await Task.sleep(nanoseconds: 500_000_000)
        let bridgeWhileHome = state.bridge
        let homeTabShowsNilSession = state.activeSession == nil
        state.activate(session)
        try? await Task.sleep(nanoseconds: 700_000_000)
        NSLog("%@", "[Lumen][sidebar-tab] 主页标签往返：homeTabIsActive \(homeWasActive) → \(state.homeTabIsActive)"
              + "；主页期间 activeSession 是否为 nil=\(homeTabShowsNilSession)"
              + "；回来后 state.bridge 与 session.bridge 同源=\(state.bridge === bridge)")
        check("从主页标签切回文档标签后 homeTabIsActive 被清掉",
              state.homeTabIsActive == false,
              "仍为 true —— activate(_:) 没清这个开关，此后 state.bridge 会一直解析成"
                  + "空通道，图标栏点击与 ⌘1–⌘5 全部静默失效")
        check("反向对照：主页标签期间 state.bridge 与文档标签的通道不是同一个对象（证明①非恒真）",
              bridgeWhileHome !== bridge,
              "主页期间两者竟然同源 —— 说明 ① 可能是恒真的，本通道的因果链需要重查")

        // 收尾：恢复到一个干净的阅读态
        state.closeHomeTab()
        state.setSidebarVisible(true, animated: false)

        // ── ⑤ 图标栏**跟着重绘**了吗（用户报的「图标不跟帖」的正面断言）──
        //
        // 上面 ②③ 只盯住「通道里的值变了、内容换了」，**盯不住图标栏自己的高亮**：
        // 那枚高亮读的是 `bridge.sidebarTab`，若读它的视图没观察 `bridge`，
        // 值变了它也不会重绘——内容换了、图标停在原地，正是用户截图里的样子。
        //
        // 所以这里直接数「图标栏 body 被求值了几次」（`Jank.tick(.sidebarRailBody)`，
        // 由 `--sidebar-tab-report` 打开计数）。做法：**只写 bridge、不碰 AppState**，
        // 这样除了「图标栏观察了 bridge」之外没有任何理由让它重绘。
        //
        // 基线取两次并比对空闲期增量：窗口/布局自身也可能带来重绘，把空闲期的
        // 自然增量一并打出来，读数被污染时一眼能看出来，而不是让断言侥幸通过。
        try? await Task.sleep(nanoseconds: 600_000_000)
        let target = tabs.first(where: { $0 != bridge.sidebarTab }) ?? tabs[0]
        let idleStart = JankTally.shared.snapshot()[.sidebarRailBody] ?? 0
        try? await Task.sleep(nanoseconds: 300_000_000)
        let idleEnd = JankTally.shared.snapshot()[.sidebarRailBody] ?? 0
        bridge.sidebarTab = target
        try? await Task.sleep(nanoseconds: 450_000_000)
        let afterWrite = JankTally.shared.snapshot()[.sidebarRailBody] ?? 0
        NSLog("%@", "[Lumen][sidebar-tab] 图标栏 body 求值：空闲基线 \(idleEnd)"
              + "（此前 300ms 自然增量 \(idleEnd - idleStart)）"
              + " → 只写 bridge.sidebarTab=\(target.rawValue) 之后 \(afterWrite)"
              + "（增量 \(afterWrite - idleEnd)）")
        check("只改 bridge.sidebarTab（不碰 AppState）也会让图标栏重绘",
              afterWrite - idleEnd >= 1,
              "图标栏没有跟着 bridge 重绘 —— 它的选中态读的是 bridge.sidebarTab，"
                  + "却不观察 bridge，于是「内容换页签、图标不跟帖」")

        NSLog("%@", "[Lumen][sidebar-tab] 自检：通过 \(passed) 项，失败 \(failures.count) 项"
              + (failures.isEmpty ? " ✅" : " ❌ " + failures.joined(separator: "；")))
    }

    /// 自检：验证「从系统那一侧退出全屏」能把沉浸状态带回来。
    ///
    /// 这条链路此前是断的——全仓库没有任何地方监听 `didExitFullScreen`，
    /// 于是用户从绿灯按钮 / 系统菜单退出全屏后，`isImmersive` 永远停在 true，
    /// 表现为「退出 zoom 后回不到正常页面」，外加「工具栏不见了」
    /// （工具栏被 `.toolbar(.hidden, for: .windowToolbar)` 锁住了）。
    ///
    /// 验收标准很硬：模拟退出全屏之后，`isImmersive` 必须是 false，
    /// 且侧栏与 AI 面板回到**进入沉浸之前各自的可见性**。
    private func runImmersiveExitAudit(after delay: Double) async {
        try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))

        NSLog("%@", "[Lumen][immersive] 模拟前：isImmersive=\(state.isImmersive)"
            + " 侧栏=\(state.isSidebarVisible) AI面板=\(state.isAIPanelVisible)")

        state.simulateSystemExitFullScreen()

        // 等系统退出全屏的动画跑完、通知送达（跨 Space 动画约 0.5s，留足余量）
        try? await Task.sleep(nanoseconds: 1_500_000_000)

        NSLog("%@", "[Lumen][immersive] 模拟后：isImmersive=\(state.isImmersive)"
            + " 侧栏=\(state.isSidebarVisible) AI面板=\(state.isAIPanelVisible)")
    }

    /// 自检：跑一遍智能目录的两步链路，并把结果落成可核对的日志。
    ///
    /// 为什么必须走完整流程而不是只验解析器：解析器在单元测试里能造输入，但
    /// 「每页开头取出来的到底是什么」「模型看到之后给出的是不是真的落在这本书的页数范围内」
    /// 「点击条目之后画面到底滚没滚」这三件事，只有真的跑一遍才知道。
    private func runSmartOutlineAudit() async {
        let path = document.url.standardizedFileURL.path
        let cacheFile = AppPaths.smartOutlineFile(forPath: path)

        NSLog("%@", "[Lumen][outline] 生成前：缓存文件存在=\(FileManager.default.fileExists(atPath: cacheFile.path))"
            + " 单元数=\(bridge.unitCount) 单元名=\(state.unitName)")

        // 绑定时从磁盘载入了什么，是「缓存复用」这条链路的唯一证据。
        // 不记这一条的话，「复用成功」和「每次都重新生成」在日志上长得一模一样，
        // 而后者意味着用户每开一次书就被扣一次钱。
        let loaded = state.smartOutline.outline
        NSLog("%@", "[Lumen][outline] 绑定后（尚未生成）：缓存条目数=\(loaded?.entries.count ?? -1)"
            + " 缓存记录单元数=\(loaded?.sourceUnitCount ?? -1)"
            + " 与当前文档匹配=\(loaded.map { $0.isValid(forUnitCount: bridge.unitCount) } ?? false)")

        state.revealSidebar(tab: .smartOutline)
        session.smartOutline.generate(
            bridge: bridge,
            metadata: bridge.metadata,
            config: state.settingsStore.activeProvider
        )

        // 轮询到不再「正在跑」。首次生成要走一次真实的模型请求，给足时间但不要无限等。
        let deadline = Date().addingTimeInterval(180)
        while session.smartOutline.phase.isWorking, Date() < deadline {
            try? await Task.sleep(nanoseconds: 300_000_000)
        }
        // 让出一点时间给落盘与界面动画落定
        try? await Task.sleep(nanoseconds: 500_000_000)

        switch session.smartOutline.phase {
        case .failed(let message):
            NSLog("%@", "[Lumen][outline] 生成失败：\(message)")
        case .working:
            NSLog("[Lumen][outline] 生成超时（180s）")
        case .idle:
            break
        }

        guard let outline = session.smartOutline.outline else {
            NSLog("[Lumen][outline] 没有产出目录，自检结束")
            return
        }

        NSLog("%@", "[Lumen][outline] 条目数=\(outline.entries.count) 记录单元数=\(outline.sourceUnitCount)"
            + " 模型=\(outline.modelName)")
        for entry in outline.entries.prefix(15) {
            let indent = String(repeating: "·", count: max(0, entry.depth))
            NSLog("%@", "[Lumen][outline]   \(indent)「\(entry.title)」→ 单元 \(entry.unitIndex + 1)"
                + " 摘要字数=\(entry.summary?.count ?? 0)")
        }

        let size = (try? FileManager.default.attributesOfItem(atPath: cacheFile.path))?[.size] as? Int
        NSLog("%@", "[Lumen][outline] 缓存文件 \(cacheFile.path) 大小=\(size.map(String.init) ?? "无")")

        // 点击条目的闭环：跳到一条**离当前位置最远**的条目，核对确实落到了它指向的位置。
        //
        // 为什么不固定跳第一条或最后一条：那样很容易撞上「本来就在那儿」——
        // 三段日志会退化成两个相同的值，等于没验。挑离当前位置最远的那条，
        // 除非整本书只有一个单元，否则跳转前后必然不同。
        let current = bridge.currentUnitIndex
        if let target = outline.entries.max(by: {
            abs($0.unitIndex - current) < abs($1.unitIndex - current)
        }) {
            NSLog("%@", "[Lumen][outline] 跳转前：\(bridge.positionLabel)（当前单元 \(current)）")
            let landed = state.jump(toUnit: target.unitIndex)
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            NSLog("%@", "[Lumen][outline] 点「\(target.title)」（目标单元 \(target.unitIndex + 1)）"
                + "→ 解析为 0-based \(landed.map(String.init) ?? "nil")"
                + "，跳转后：\(bridge.positionLabel)")
        }

        // 第二步：单节摘要。
        if let number = LaunchOptions.smartOutlineSummaryIndex,
           number >= 1, outline.entries.indices.contains(number - 1) {
            let entry = outline.entries[number - 1]
            NSLog("%@", "[Lumen][outline] 请求第 \(number) 条的摘要：「\(entry.title)」")
            session.smartOutline.summarize(
                entry: entry,
                bridge: bridge,
                metadata: bridge.metadata,
                config: state.settingsStore.activeProvider
            )

            let summaryDeadline = Date().addingTimeInterval(120)
            // 等的是 `summarizing` 而不是 `phase`：摘要是逐条并行的，
            // 它不参与「骨架生成」那条 phase 状态机。等错了对象会立刻退出循环，
            // 然后在请求还在飞的时候读到一个空摘要——那看起来就像功能坏了。
            while session.smartOutline.summarizing.contains(entry.id), Date() < summaryDeadline {
                try? await Task.sleep(nanoseconds: 300_000_000)
            }
            try? await Task.sleep(nanoseconds: 400_000_000)

            if case .failed(let message) = session.smartOutline.phase {
                NSLog("%@", "[Lumen][outline] 摘要失败：\(message)")
            }
            let after = session.smartOutline.outline?.entries.first(where: { $0.id == entry.id })
            NSLog("%@", "[Lumen][outline] 摘要结果 字数=\(after?.summary?.count ?? 0)"
                + " 内容=\(after?.summary?.replacingOccurrences(of: "\n", with: "⏎").prefix(200).description ?? "nil")")
        }
    }

    /// 自检：跳页并核对结果。
    ///
    /// 三段都打：跳之前在哪、请求的是第几个、跳之后在哪。
    /// 只打最后一段的话，「跳成功了」和「本来就在这一页」输出完全相同，
    /// 等于没验。
    private func runLaunchJump(_ target: Int) async {
        NSLog("%@", "[Lumen][jump] 跳转前：\(bridge.positionLabel)（共 \(bridge.unitCount) 个单元）")

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
            NSLog("%@", "[Lumen][action] 未知动作：\(raw)")
            return
        }

        NSLog("%@", "[Lumen][action] 自检执行 \(raw)")
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
    @EnvironmentObject private var session: ReaderSession

    @State private var isHovering = false
    /// 页码那块的悬停态。与整条状态条的 `isHovering` 分开：
    /// 整条只是整体透明度微调，页码悬停要变色以暗示「可点」。
    @State private var isJumpHovering = false

    var body: some View {
        // 沉浸模式下页码与缩放照常在场（右上角只有退出按钮，页码不重复），
        // 只在文档没准备好 / 加载失败 / 还没有位置信息时收起。
        if !bridge.isLoading, bridge.loadError == nil, !bridge.positionLabel.isEmpty {
            HStack(spacing: DS.Space.m) {
                // 页码本身做成入口：用户想跳页时的第一反应就是「点那个页码」。
                // 悬停变强调色，否则没人会想到它是能点的。
                Button {
                    withAnimation(DS.Motion.palette) { state.isPageJumpVisible = true }
                } label: {
                    if documentIsPDF {
                        PDFLivePageLabel(viewport: bridge.viewport, pageCount: bridge.unitCount,
                                         color: NSColor(isJumpHovering ? DS.Palette.accent : DS.Palette.textSecondary))
                    } else {
                        ControlChip(text: bridge.positionLabel)
                            .foregroundStyle(isJumpHovering ? DS.Palette.accent : DS.Palette.textSecondary)
                    }
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
        session.document.kind == .pdf
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
///
/// **只在拖动划选时出现**（见 `ReaderBridge.selectionFromDrag`）：单击产生的 1 字符选区
/// 不该把它叫出来。
struct SelectionActionBarLayer: View {

    @EnvironmentObject private var bridge: ReaderBridge
    @EnvironmentObject private var state: AppState

    var body: some View {
        // **只在拖动划选时出现**。`selectionFromDrag` 是新加的门：单击也会产生
        // 一个 1 字符选区，没有这道门的话随手点一下正文就会弹出浮条（用户明确否掉了这种）。
        if let selection = bridge.selection, selection.isUsable, bridge.selectionFromDrag {
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
    @EnvironmentObject private var session: ReaderSession

    /// 批注输入态。做成同一条浮层里就地展开，而不是弹出一个 sheet：
    /// 手刚划完词，视线在原文上，弹窗把注意力拉走会让「批的是哪句」这件事变模糊。
    @State private var isNoteEditing = false
    @State private var noteText = ""
    @FocusState private var isNoteFocused: Bool

    var body: some View {
        VStack(spacing: DS.Space.xs) {
            if isNoteEditing { noteEditor }
            buttonRow
        }
        .background(
            Capsule(style: .continuous)
                .fill(.thickMaterial)
                .overlay(Capsule(style: .continuous).strokeBorder(DS.Palette.separator, lineWidth: 0.5))
        )
        .shadow(color: .black.opacity(0.18), radius: 16, y: 6)
        // 展开输入条时不重排布局：整条浮层本来就锚在底部中央
        .animation(DS.Motion.reveal, value: isNoteEditing)
    }

    private var buttonRow: some View {
        HStack(spacing: DS.Space.xs) {
            if isNoteEditing {
                Label("批注", systemImage: "square.and.pencil")
                    .font(DS.Typo.caption)
                    .foregroundStyle(DS.Palette.accent)
                    .padding(.horizontal, DS.Space.s)
                    .labelStyle(.titleAndIcon)
            } else {
                Label("\(selection.text.count) 字", systemImage: "text.quote")
                    .font(DS.Typo.caption)
                    .foregroundStyle(DS.Palette.textTertiary)
                    .padding(.horizontal, DS.Space.s)
                    .labelStyle(.titleAndIcon)

                Divider().frame(height: 16)

                // 高亮与批注是「留在书里」的动作，排在 AI 三件套之前：
                // 划词的瞬间最清楚自己要标哪句，等 AI 回答完再回来找就找不着了。
                actionButton("高亮", icon: "highlighter") { highlight() }
                actionButton("批注", icon: "square.and.pencil") { startNote() }
            }

            Divider().frame(height: 16)

            actionButton("解释", icon: "sparkles") { trigger(.explain) }
            actionButton("翻译", icon: "character.book.closed") { trigger(.translate) }
            actionButton("追问", icon: "bubble.left.and.text.bubble.right") { trigger(.ask) }
        }
        // 防压缩：整条浮层锚在底部中央、内容宽度本来就固定，没有 `.fixedSize()` 时
        // 父级会把最右那一项（追问）压成省略号——实测「追问 → …」。
        // 这是「文字被渲染成 …」的定义级缺陷，加一行把它钉死。
        .fixedSize()
        .padding(.horizontal, DS.Space.s)
        .padding(.vertical, DS.Space.xs)
    }

    private var noteEditor: some View {
        HStack(spacing: DS.Space.xs) {
            TextField("写下你的批注…", text: $noteText, axis: .vertical)
                .textFieldStyle(.plain)
                .font(DS.Typo.body)
                .lineLimit(2...4)
                .frame(minWidth: 260, maxWidth: 360)
                .focused($isNoteFocused)
                .onSubmit(commitNote)

            Button("取消") {
                withAnimation { isNoteEditing = false }
                noteText = ""
            }
            .controlSize(.small)
            .buttonStyle(.plain)
            .foregroundStyle(DS.Palette.textTertiary)

            Button("保存批注") { commitNote() }
                .controlSize(.small)
                .buttonStyle(.borderedProminent)
                .tint(DS.Palette.accent)
        }
        .padding(.horizontal, DS.Space.s)
        .padding(.vertical, DS.Space.xs)
    }

    // MARK: 动作

    private func highlight() {
        bridge.addHighlight?("")
    }

    private func startNote() {
        noteText = ""
        withAnimation { isNoteEditing = true }
        isNoteFocused = true
    }

    private func commitNote() {
        bridge.addHighlight?(noteText)
        noteText = ""
        withAnimation { isNoteEditing = false }
    }

    /// 投递请求前先把 AI 面板露出来——否则用户点了按钮却看不到任何反馈。
    private func trigger(_ kind: AIRequest.Kind) {
        if !state.isAIPanelVisible {
            withAnimation(DS.Motion.panel) { state.isAIPanelVisible = true }
        }
        session.pendingAIRequest = AIRequest(kind: kind, selection: selection)
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


/// 阅读视图自检的进程级闸门：多标签 / 多窗口下每个标签挂载都会跑
/// `applyLaunchDiagnostics`，自检只允许在首个标签上跑一次。
@MainActor
enum ReaderContainerDiagnostics {
    private static var didRun = false

    /// 返回是否允许本次执行（首个调用者拿到 true，之后全部 false）。
    static func beginOnce() -> Bool {
        if didRun { return false }
        didRun = true
        return true
    }
}
