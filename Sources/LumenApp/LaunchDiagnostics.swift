import SwiftUI
import AppKit

/// 命令行开关。
///
/// 存在的理由：这台机器没有授予录屏权限，`screencapture` 拿不到画面，而「视觉美观」
/// 又是本项目的第一优先级。所以在应用内部开一条自检通道——由进程自己把主窗口
/// 渲染成 PNG，既不需要任何系统权限，也不依赖外部工具。
///
///   Lumen --open /path/to/book.epub --capture /tmp/shot.png --capture-delay 2.5
///
/// 两个布尔开关也要带值：`--palette 1`（打开命令面板）、`--ocr 1`（自动识别当前页），
/// 用来在没有 UI 自动化权限的环境里验证这两条链路。为什么不能裸写开关，见 `flag(_:)`。
///
enum LaunchOptions {

    static func value(for flag: String) -> String? {
        let args = CommandLine.arguments
        guard let index = args.firstIndex(of: flag), index + 1 < args.count else { return nil }
        let value = args[index + 1]
        return value.hasPrefix("--") ? nil : value
    }

    /// 布尔开关。**必须写成「开关 + 值」的形式**，例如 `--ocr 1`、`--palette 1`。
    ///
    /// 不要用裸开关（`--ocr --capture …`）。原因不在这一层：macOS 会把命令行参数
    /// 注入 `UserDefaults` 的 argument domain，解析器按「-key value」成对消费；
    /// 当一个 `-` 开头的 token 后面紧跟另一个 `-` 开头的 token 时，整条参数序列会被解错，
    /// 症状是 **SwiftUI 的 WindowGroup 根本不创建窗口**（`NSApp.windows` 恒为 0），
    /// 不崩溃、不报错、日志也干净——极难定位。
    ///
    /// 实测对照：
    /// ```
    /// --xyz --capture /tmp/x.png --capture-delay 4   → 启动 1s 后窗口数 0
    /// --xyz 1 --capture /tmp/z.png --capture-delay 4 → 启动 1s 后窗口数 1
    /// ```
    static func flag(_ name: String) -> Bool {
        guard let raw = value(for: name)?.lowercased() else { return false }
        return ["1", "true", "yes", "on"].contains(raw)
    }

    /// 三态开关：没写是 nil，写了 1/0 分别是 true/false。
    ///
    /// 面板可见性这类「默认值本身有讲究」的项必须用三态——用 `flag` 的话，
    /// 不传参数与传 `--sidebar 0` 会得到同一个结果，那就验不了「关掉之后什么样」。
    static func optionalFlag(_ name: String) -> Bool? {
        guard let raw = value(for: name)?.lowercased() else { return nil }
        if ["1", "true", "yes", "on"].contains(raw) { return true }
        if ["0", "false", "no", "off"].contains(raw) { return false }
        return nil
    }

    static var openPath: String? { value(for: "--open") }
    static var capturePath: String? { value(for: "--capture") }
    static var captureDelay: Double { Double(value(for: "--capture-delay") ?? "") ?? 2.5 }
    /// 启动后自动发起一次提问。用于端到端自检 AI 链路。
    static var askPrompt: String? { value(for: "--ask") }
    /// 启动后自动打开命令面板（自检用）：`--palette 1`
    static var opensPalette: Bool { flag("--palette") }
    /// 打开文档后自动对当前页做一次 OCR（自检扫描件链路用）：`--ocr 1`
    static var autoOCR: Bool { flag("--ocr") }
    /// 启动后自动打开「设置」窗口（自检设置页视觉用）：`--settings 1`
    static var opensSettings: Bool { flag("--settings") }
    /// 直接落在指定的设置页签上（自检各页视觉用）：`--settings-tab interface`
    static var settingsTab: String? { value(for: "--settings-tab") }
    /// 打印字体目录统计与断言（自检字体筛选逻辑）：`--font-report 1`
    static var fontReport: Bool { flag("--font-report") }
    /// 启动时先记一条跨会话记忆（自检记忆落盘与提示词注入）：`--remember "我的研究方向是乡村教育"`
    static var rememberText: String? { value(for: "--remember") }

    // MARK: - 布局自检

    /// 初始面板可见性：`--sidebar 0` / `--ai 0`。
    /// 用于核对「三栏全开」「只留阅读区」这类极端布局下有没有控件被挤掉或压住。
    static var initialSidebarVisible: Bool? { optionalFlag("--sidebar") }
    static var initialAIPanelVisible: Bool? { optionalFlag("--ai") }

    /// 启动后把窗口内容区设成指定尺寸：`--window-size 920x620`。
    /// 布局缺陷几乎都藏在最小尺寸下——默认 1340 宽什么都放得下，看不出问题。
    static var windowSize: CGSize? {
        guard let raw = value(for: "--window-size")?.lowercased() else { return nil }
        let parts = raw.split(separator: "x")
        guard parts.count == 2,
              let width = Double(parts[0]),
              let height = Double(parts[1]),
              width > 320, height > 240 else { return nil }
        return CGSize(width: width, height: height)
    }

    /// 自检用：直接设定 AI 面板宽度，`--panel-width 400x300`。
    ///
    /// 和 `--window-size` 一样走 `x` 分隔，但**只有第二个数（AI 面板）生效**：
    /// 侧栏宽度自本批起固定为 248pt、不再从设置读取，第一个数（侧栏）仍被解析
    /// 只为不破坏既有脚本，**不产生任何效果**。
    ///
    /// 值会经过与拖动分隔线相同的钳制，所以故意传越界值（如 `9999x10`）
    /// 就能验证 AI 面板真的被钳到下限 300。
    static var panelWidth: (sidebar: Double, ai: Double)? {
        guard let raw = value(for: "--panel-width")?.lowercased() else { return nil }
        let parts = raw.split(separator: "x")
        guard parts.count == 2,
              let sidebar = Double(parts[0]),
              let ai = Double(parts[1]) else { return nil }
        return (sidebar, ai)
    }

    /// 直接把侧栏钉在某个页签上：`--sidebar-tab thumbnails`。
    /// 缩略图页是懒加载的，只有真正切过去才会渲染，不这样切就永远审不到。
    static var sidebarTab: String? { value(for: "--sidebar-tab") }

    /// 自检用：打开文档后跳到第 N 个单元（**1-based**，与界面输入框一致）。
    ///
    /// 会打印「跳转前 → 请求 → 跳转后」三段，这样才能区分
    /// 「跳成功」和「本来就在那一页」——只打终值的话这两种情况长得一模一样。
    static var jumpToUnit: Int? {
        guard let raw = value(for: "--jump-to") else { return nil }
        return Int(raw)
    }

    /// 塞一段假选区，用来核对划词浮动条的位置（正常要靠鼠标划词才能触发）。
    ///
    /// 注入的选区**标记为拖动来源**（`selectionFromDrag = true`）。理由：划词条现在有一道
    /// 「只在拖动划选时出现」的门（§4），不标来源的话这条自检会注入一个默认来源为「单击」
    /// 的选区，浮条被门挡掉、`layoutProbe("selectionBar")` 不再上报，
    /// 于是 `layout_assert.py` 与既有断言全红——那是自检脚手架没跟上，不是缺陷。
    static var injectsDemoSelection: Bool { flag("--demo-selection") }

    /// 塞一段**「单击来源」**的假选区：`--demo-click 1`。
    ///
    /// 与 `--demo-selection` 成对，用来**证伪**「划词条只在拖动时出现」这道门：
    /// 两者注入的选区内容完全一样，唯一的差别是来源标记（`selectionFromDrag`）。
    /// 断言「`--demo-click 1` 时 `selectionBar` 探针缺席、`--demo-selection 1` 时在场」——
    /// 只要有人把这道门删掉，`--demo-click` 立刻会红，断言抓的就是这个。
    static var injectsDemoClick: Bool { flag("--demo-click") }

    /// 塞一条假的 AI 回答：`--demo-answer 1`。
    ///
    /// 用来核对长文本排版（长 URL / 长代码行 / 长标识符在面板下限宽度下会不会
    /// 横向撑破面板、换行自不自然）。离线自检里模型不会返回任何内容，
    /// 不注入就永远审不到这条路径。内容见 `AIChatModel.demoAnswerText`。
    static var injectsDemoAnswer: Bool { flag("--demo-answer") }

    /// 自检用：启动后直接进入沉浸模式，核对「面板全收 + 正文居中限宽」。
    static var startsImmersive: Bool { flag("--immersive") }

    /// 打印缩略图的渲染/跳过明细：`--thumb-report 1`。
    ///
    /// 用来证明「滚出可视区的页不再被渲染」确实生效——这是缩略图侧栏流畅与否的关键，
    /// 但它是个纯粹的浪费与否问题，不看日志根本分辨不出来（跳过和渲染的外观一样）。
    static var thumbnailReport: Bool { flag("--thumb-report") }

    /// 自检：进入沉浸 N 秒后，**绕过应用逻辑**直接用 AppKit 让窗口退出全屏。
    ///
    /// 存在的理由：`state.setImmersive(false)` 那条路径是应用自己发起的，状态当然对得上。
    /// 真正会坏的是用户从系统那一侧退出全屏（绿灯按钮 / 「显示 → 退出全屏」菜单 / ⌃⌘F），
    /// 那条路径不会经过我们的任何一行代码。这个开关就是来复现它的：
    /// 它只 toggle 窗口、绝不碰 `isImmersive`，于是「回程到底通没通」一眼可辨。
    static var exitFullScreenAfter: Double? {
        guard let raw = value(for: "--exit-fullscreen-after") else { return nil }
        return Double(raw)
    }

    /// 自检：打印可选主题清单与废弃主题的迁移落点：`--theme-report 1`。
    ///
    /// 「纯黑主题已移除」这件事必须可断言，而不是靠读代码相信：它有两个
    /// 很容易只做一半的地方——枚举删了但 `all` 里还留着（界面上还能选到），
    /// 或者 `all` 删了但旧配置解码时掉进 `?? .paper`（把深色用户变成纸白）。
    /// 这条通道把两边都打出来，一眼能看出是哪一半没做。
    static var themeReport: Bool { flag("--theme-report") }

    /// 批注自检：在 /tmp 的副本上跑一遍「高亮 → 页面批注 → 写盘 → 重开核对 → 删除」。
    static var annotateReport: Bool { flag("--annotate-report") }

    /// OCR 右键菜单自检：`--ocr-menu-report 1`。
    ///
    /// 存在的理由：右键菜单**没法自动化验证**（本机没有辅助功能权限，合成不出真实右键，
    /// 截图也拍不到原生菜单），所以把「该出现哪些项、该叫什么文案、该不该禁用」抽成
    /// 纯函数 `PDFContextMenuPlanner.items`，在这里做表驱动断言。改错任一处立刻红。
    static var ocrMenuReport: Bool { flag("--ocr-menu-report") }

    /// 面板宽度响应式自检：`--resize-report 1`。
    ///
    /// 存在的理由：拖动分隔线的 bug 恰好落在旧自检的盲区里——`--panel-width` 是在
    /// **视图出现之前**写入宽度的，首帧直接按新值布局，「改了设置 → 布局跟着变」这条
    /// 响应式链路从来没被验过（视图不观察 SettingsStore 时它就是断的，自检照样全绿）。
    /// 这条通道在布局稳定**之后**再写一次宽度（与拖动手势走同一个设置项），
    /// 然后读布局探针实际记录到的 frame，断言它真的变了。
    static var resizeReport: Bool { flag("--resize-report") }

    /// 搜索高亮自检：验证页面高亮出现、定位准确、且**不会**被写进用户的书。
    static var searchReport: Bool { flag("--search-report") }

    /// Agent 自检：打印预设、拼装后的系统提示、以及一次真实的联网文献检索结果。
    static var agentReport: Bool { flag("--agent-report") }

    /// 联网文献检索自检：`--websearch-report 1`。
    ///
    /// **真实联网**跑一次 `WebLiteratureSearch.search`，逐源记录命中数 / 失败 / 耗时，
    /// 断言「至少一个源命中」且「去重后总命中 ≥ 3」。与 `--agent-report` 里那次检索
    /// 分开，是因为它要能单独重跑：三个源都是外部服务，可用性会随时间变
    /// （Semantic Scholar 就是这么被判出局的），而这条通道是发现「某个源挂了」的地方。
    ///
    /// ⚠️ 必须搭配 `--capture` 使用，否则进程不会自己退出（自检的老坑，退出码 137）。
    static var webSearchReport: Bool { flag("--websearch-report") }

    /// 「重新生成」自检：`--rerun-report 1`。
    ///
    /// 需要配合 `--mock-ai 1`（否则要烧真实密钥）：跑一次提问、再 `rerunLast()` 一次，
    /// 断言气泡被**替换**（条数不变）且两次请求体规模一致（history 未被叠加）。
    /// ⚠️ 同样必须与 `--capture` 同用。
    static var rerunReport: Bool { flag("--rerun-report") }

    /// 自检钥匙串访问成本：`--keychain-report 1`。
    ///
    /// 起因是「每重编译一次就疯狂弹钥匙串授权框」。这件事只有一条通道能验：
    /// 存在性判断是走属性通道（不解密，永不弹窗）还是走密文通道（每次解密都要授权）。
    /// 两者都会返回一个 Bool，从终值上看不出区别，差别全在**耗时与钥匙串调用次数**上。
    /// 所以这条通道连打两次并分别计时——第二次的耗时差就是「缓存是否生效」的证据。
    static var keychainReport: Bool { flag("--keychain-report") }

    /// 自检 AI 智能目录：`--smart-outline 1`。
    ///
    /// 这条链路的关键产物（目录条目、页码落点、缓存文件）全都不在可视区域里，
    /// 靠截图什么也证明不了；而且它要真的调一次模型才有结果，没法用假数据绕过。
    /// 所以让进程自己走完全程，把条目清单与「点击条目后到了哪个单元」打出来。
    static var smartOutline: Bool { flag("--smart-outline") }

    /// 配合 `--smart-outline 1`：对第 N 条（1-based）生成一次摘要，验证第二步链路。
    static var smartOutlineSummaryIndex: Int? {
        guard let raw = value(for: "--smart-outline-summary") else { return nil }
        return Int(raw)
    }

    /// 自检用：把 AI 服务商**临时**指向本机的桩服务，不落盘。
    ///
    /// 没有这个开关，任何 AI 链路（智能目录、整本书总结）的自检都会消耗真实密钥，
    /// 于是要么不敢跑、要么跑出来的结果不可复现。`--mock-ai 1` 等价于
    /// `--mock-ai 127.0.0.1:8777`（见 `tools/mock_openai_server.py`）。
    ///
    /// 只改内存里的设置：`suppressSave` 一开，防抖落盘整条路径都短路，
    /// 用户的真实配置与服务商列表不会被这个开关污染。
    static var mockAI: (host: String, port: Int)? {
        guard let raw = value(for: "--mock-ai") else { return nil }
        let lowered = raw.lowercased()
        if ["1", "true", "yes", "on"].contains(lowered) { return ("127.0.0.1", 8777) }

        let parts = raw.split(separator: ":")
        guard parts.count == 2, let port = Int(parts[1]), port > 0, port < 65_536 else { return nil }
        return (String(parts[0]), port)
    }

    /// 这次启动是不是**自检**（而不是用户想打开一本书）。
    ///
    /// 判据是「命令行里带自检开关」，不是「带 `--open`」——`--open` 既可以喂给
    /// 自检，也可以只是想从命令行开一本书，两者要分开。
    ///
    /// 存在的理由：自检会把 /tmp 里的测试书写进「最近打开」，把用户真实的阅读
    /// 记录顶下去——跑几次自检之后欢迎页就只剩测试书了。真实用户数据被
    /// 诊断流程改掉，是最难被察觉的一类副作用。
    static var isAuditRun: Bool {
        CommandLine.arguments.contains { argument in
            argument.hasSuffix("-report") || argument == "--capture" || argument == "--mock-ai"
        }
    }

    /// 是否需要在启动后自动截图并退出
    static var shouldCapture: Bool { capturePath != nil }

    /// 打印关键浮层的几何位置：`--layout-report 1`。
    ///
    /// 存在的理由：这台机器读不了截图内容（模型无视觉通道），而「状态条有没有压住
    /// AI 面板」这类问题本质上是一个**坐标包含关系**——状态条的 frame 是否落在阅读区
    /// 的 frame 之内。与其靠肉眼看截图，不如让视图自己把 frame 打出来做断言。
    /// 浮层与阅读区的 frame 都按窗口内容区坐标（`.global`）上报。
    static var layoutReport: Bool { flag("--layout-report") }

    /// PDF 浏览性能自检：`--perf-report 1`。
    ///
    /// 存在的理由：用户报「翻页卡顿」，但「卡」是个主观描述——没有读数就只能凭感觉改，
    /// 改完也不知道有没有变好、甚至可能只是把瓶颈从一个地方挪到另一个。本通道让进程
    /// 自己连翻 N 页，逐页记耗时并报 p50/p95/max，同时报首尾进程内存（`phys_footprint`）
    /// 的增量。它同时是**可证伪**的：会把「带回调」与「摘掉回调」两遍都跑一遍，
    /// 两者之差就是「我们这一层自己的每页开销」——差值接近 0 就说明瓶颈在 PDFKit 里，
    /// 不该往我们这层使劲。
    static var perfReport: Bool { flag("--perf-report") }

    /// 翻页自检要翻多少页：`--perf-pages 120`。默认 120（覆盖测试用的 120 页长文档）。
    /// 文档本身不足这么多页时按实际页数钳制。
    static var perfPageTurns: Int {
        guard let raw = value(for: "--perf-pages"), let n = Int(raw), n > 0 else { return 120 }
        return n
    }

    /// 证伪开关：让缩略图自检**不做** LRU 上限（`--perf-thumbnail-unbounded 1`）。
    ///
    /// 优化本身要能被证伪——关掉它、重新跑一遍，读数必须变差；否则那段优化就是装饰。
    static var perfThumbnailUnbounded: Bool { flag("--perf-thumbnail-unbounded") }

    /// 连续交互卡顿自检：`--jank-report 1`。
    ///
    /// 与 `--perf-report` 分工不同：`--perf-report` 量**单次**渲染/翻页代价（结论是都不慢），
    /// 它覆盖不到「拖动分隔线 / 触控板滚动」这类**连续动作**——那里的卡顿来自
    /// 「每一帧要重算多少次重活」，而不是单次有多慢。本通道用 60Hz 定时器的迟到量
    /// 当掉帧代理，并统计每条热路径每步被重算了几次。
    static var jankReport: Bool { flag("--jank-report") }

    /// 卡顿自检每一段的步数：`--jank-steps 60`。默认 60（约 1 秒 @60Hz 的连续动作）。
    static var jankSteps: Int {
        guard let raw = value(for: "--jank-steps"), let n = Int(raw), n > 0 else { return 60 }
        return n
    }

    /// **证伪开关**：关掉拖动期宽度写入的「按显示刷新合并」：`--jank-no-coalesce 1`。
    ///
    /// 合并打开时，一个显示帧内的多个指针事件只应用一次；关掉之后每次写入都直接落状态。
    /// 同一台机器、同一个驱动下重跑 `--jank-report 1`，「每步重活」应当从 ~1/步 回到
    /// ~3/步（本机每帧模拟 3 次指针写入）——这就证明读数变化确实来自合并本身，
    /// 而不是环境或噪声。
    static var jankNoCoalesce: Bool { flag("--jank-no-coalesce") }

    /// **被动监视**：`--jank-watch 1`。
    ///
    /// 与 `--jank-report` 相反——它**不驱动任何东西**，正常启动、正常运行，只在后台把
    /// 卡顿埋点每 2 秒汇总一行写到 `/tmp/lumen-jank-watch.log`，交给用户用**真触控板**
    /// 产生手势来复现。合成事件复现不了连续惯性滚动，所以把「产生手势」还给人。
    /// 纯读、不写设置（配合 `suppressSave`）。
    static var jankWatch: Bool { flag("--jank-watch") }

    /// 合成滚动每步的像素增量：`--jank-scroll-delta 1900`。默认见 `JankAudit.defaultScrollDelta`。
    ///
    /// 存在的理由：真机触控板滚动的进程 CPU 是合成驱动的好几倍（见 `JankAudit.realMachineCPUPerStepMs`），
    /// 在本地用轻量驱动迭代等于「测不到要优化的那个负载」。调大它可以把每步要光栅化的新区域拉大，
    /// 从而把 CPU/步 顶到真机的量级（实测会饱和，见 VERIFY.md 第七节）。
    static var jankScrollDelta: Int? {
        guard let raw = value(for: "--jank-scroll-delta"), let n = Int(raw), n > 0 else { return nil }
        return n
    }

    /// 合成滚动每步投几个滚轮事件：`--jank-scroll-burst 8`（默认 1）。
    ///
    /// 真触控板在一个显示帧里会送来**一串**事件（≈90–120Hz，高于 60Hz 屏幕），而旧驱动
    /// 每帧只投一个。这个开关把一步的总位移**拆成 N 个小事件**在同一帧内投完，
    /// 用来验证「事件串」本身会不会触发 PDFKit 的响应式滚动/预取（实测见 VERIFY.md 第七节）。
    static var jankScrollBurst: Int? {
        guard let raw = value(for: "--jank-scroll-burst"), let n = Int(raw), n > 0 else { return nil }
        return min(n, 64)
    }

    /// 滚动段把 `scaleFactor` 钉在指定值：`--jank-scroll-zoom 2.0`。
    ///
    /// 倍率越大，每帧要重光栅化的页面像素越多——这是把合成驱动推满的另一个手段，
    /// 也用来验证「CPU/步 随倍率怎样变化」（真机在高倍率下更容易卡）。
    static var jankScrollZoom: Double? {
        guard let raw = value(for: "--jank-scroll-zoom"), let n = Double(raw), n > 0 else { return nil }
        return n
    }

    // MARK: - PDF 渲染旋钮（滚动卡顿的优化面）

    /// 页面投影开关：`--pdf-page-shadows 0|1`。不传 = 用默认（开，与改造前一致）。
    static var pdfPageShadows: Bool? { optionalFlag("--pdf-page-shadows") }

    /// 页间留白开关：`--pdf-page-breaks 0|1`。不传 = 用默认（开，与改造前一致）。
    static var pdfPageBreaks: Bool? { optionalFlag("--pdf-page-breaks") }

    /// **一键切到「瘦身件」**：`--pdf-render-slim 1`（关投影 + 关页间留白）。
    /// 单变量对照的「关掉两个」那一格靠它；三个旋钮已被实测证伪，默认**不开**（见 `PDFRenderTuning`）。
    static var pdfRenderSlim: Bool { flag("--pdf-render-slim") }

    /// 渲染保真自检：`--pdf-render-report 1`。
    ///
    /// 把渲染状态钉死（跳到第 1 页 + 适宽倍率）并打印本次采用的三个旋钮，配合 `--capture`
    /// 就能得到「同页同倍率、只有旋钮不同」的可逐像素对比的两张图。见 VERIFY.md 第七节。
    static var pdfRenderReport: Bool { flag("--pdf-render-report") }

    /// 文档装好后自动执行一个动作，然后把剪贴板回读出来：`--run-action copyFullText`。
    ///
    /// 复制这类功能的产出去向是**剪贴板**，不是界面——截多少张图都证明不了
    /// 「剪贴板里真的是全文」。所以让进程自己按一次，再把剪贴板内容打印出来核对。
    /// 取值是 `LumenAction` 的 rawValue。
    static var runAction: String? { value(for: "--run-action") }

    /// 自检时自动点掉确认框（例如扫描件复制全文会先问要不要跑 OCR）。
    /// 只在配合 `--run-action` 时使用，正常启动不生效。
    static var autoConfirms: Bool { flag("--auto-confirm") }

    /// 打印快捷键表并实跑一遍改绑规则：`--keys-report 1`。
    static var keysReport: Bool { flag("--keys-report") }

    /// 连同标题栏与工具栏一起截：`--capture-chrome 1`。
    ///
    /// 默认只截 `contentView`，而 `.windowToolbarStyle(.unified)` 下工具栏属于标题栏视图，
    /// 不在 contentView 里——于是「工具栏上的按钮有没有被挤掉」这件事一直没被审到。
    /// 打开这个开关改为从 `NSThemeFrame` 渲染。
    static var captureIncludesChrome: Bool { flag("--capture-chrome") }

    /// 改用系统录屏通道抓图：`--capture-screen 1`。
    ///
    /// 与默认的 `cacheDisplay` 是两条本质不同的路：
    ///   - `cacheDisplay` 是**离屏绘制**，不需要任何系统权限，但画 `NSVisualEffectView`
    ///     （SwiftUI 的 `.regularMaterial`）时不可靠——材质常常被画成一层不随外观变化的浅色。
    ///   - 录屏通道（`screencapture -l`）抓的是屏幕上**真实的像素**，材质按当前外观真正混合过。
    ///
    /// 也就是说：「材质有没有跟着主题变」这件事，只有走录屏通道才是可信的。
    /// 代价是需要「屏幕录制」权限，且抓到的是整窗（含标题栏与工具栏），不能只截 contentView。
    static var captureViaScreen: Bool { flag("--capture-screen") }
}

// MARK: - 布局探针

/// 把视图在窗口内容区里的 frame 打出来，用于断言浮层的落位。
///
/// 只在 `--layout-report 1` / `--resize-report 1` 时才有额外包装；正常启动时
/// `body(content)` 原样返回，不留任何 GeometryReader 开销。所有上报都攒着，
/// 等布局稳定后统一 dump——逐帧打印会被动画过程中的中间值淹没，看不出最终落点。
///
/// **视图消失时必须注销自己**（`onDisappear` → `LayoutAuditLog.remove`）。
/// 这曾经是一个真缺陷：探针把一个 `name → frame` 的字典存起来、dump 时全量打印，
/// 视图消失时不注销，于是已收起的 AI 面板仍上报最后一帧——`maxX` 甚至越出窗口
/// 内容区（实测 1431 > 1421）。连带后果是 `tools/layout_assert.py` 那条
/// 「收起的面板必须是探针消失」的规则验的是**死数据**，恒真、从不报错。
struct LayoutProbe: ViewModifier {
    let name: String

    func body(content: Content) -> some View {
        if LaunchOptions.layoutReport || LaunchOptions.resizeReport {
            content.background(
                GeometryReader { proxy in
                    let frame = proxy.frame(in: .global)
                    Color.clear
                        .onAppear { LayoutAuditLog.shared.record(name, frame) }
                        .onChange(of: frame) { _, new in LayoutAuditLog.shared.record(name, new) }
                        // 视图从版面上摘下（面板收起 / 切换格式）时注销，
                        // 否则 dump 里会留着它的最后一帧——那是「幽灵探针」。
                        .onDisappear { LayoutAuditLog.shared.remove(name) }
                }
            )
        } else {
            content
        }
    }
}

extension View {
    /// 在窗口内容区坐标系里上报这个视图的 frame：`--layout-report 1` 时打印。
    func layoutProbe(_ name: String) -> some View {
        modifier(LayoutProbe(name: name))
    }
}

@MainActor
final class LayoutAuditLog {

    static let shared = LayoutAuditLog()

    private var frames: [String: CGRect] = [:]
    private var dumpScheduled = false

    /// 读回某个探针最近记录的 frame。`--resize-report` 用它断言「宽度写入后布局真的变了」。
    /// 视图已消失时返回 nil——调用方必须把 nil 当成「这一栏不在版面上」，
    /// 而不是「读到 0 宽还在占位」。
    func frame(named name: String) -> CGRect? { frames[name] }

    /// 从第一次上报起算，2s 后统一打印。演示选区要等文档装好才注入，
    /// 所以划词条的首次上报会晚于状态条，用一个稍长的窗口把两者都收进来。
    func record(_ name: String, _ frame: CGRect) {
        guard LaunchOptions.layoutReport || LaunchOptions.resizeReport else { return }
        frames[name] = frame

        guard !dumpScheduled else { return }
        dumpScheduled = true
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            // 只有 --layout-report 才统一打印；--resize-report 只要「读得到」，
            // 打印反而会把它的断言输出淹没。
            if LaunchOptions.layoutReport { self.dump() }
        }
    }

    /// 视图消失时注销探针。与 `record` 成对——少了这一步，dump 里就会出现
    /// 已经不在版面上的视图的最后一帧，断言随之退化成验死数据。
    func remove(_ name: String) {
        frames.removeValue(forKey: name)
    }

    private func dump() {
        let content = NSApp.windows
            .first { $0.isVisible && ($0.contentView?.bounds.height ?? 0) > 100 }?
            .contentView?.bounds.size ?? .zero

        NSLog("[Lumen][layout] 窗口内容区 \(Int(content.width))x\(Int(content.height))，共上报 \(frames.count) 项")
        for (name, frame) in frames.sorted(by: { $0.key < $1.key }) {
            NSLog(
                String(
                    format: "[Lumen][layout] %@  x=%6.1f y=%6.1f w=%6.1f h=%6.1f  maxX=%6.1f maxY=%6.1f",
                    name, frame.minX, frame.minY, frame.width, frame.height, frame.maxX, frame.maxY
                )
            )
        }
    }
}

// MARK: - 剪贴板自检

/// 复制类功能的验证出口。
///
/// 「复制全文」和「复制文件」的最终产物都在剪贴板上，界面只给一句提示。
/// 所以在自检模式下把剪贴板的类型清单和内容摘要打出来——这是唯一能证明
/// 「复制出来的确实是全文 / 确实是一个文件 URL」的手段。
@MainActor
enum ClipboardAudit {

    static func dump(_ label: String) {
        let pasteboard = NSPasteboard.general
        let types = (pasteboard.types ?? []).map(\.rawValue).sorted()
        NSLog("[Lumen][clipboard] \(label) 类型=[\(types.joined(separator: ", "))]")

        if let string = pasteboard.string(forType: .string) {
            let oneLine = string
                .replacingOccurrences(of: "\n", with: "⏎")
                .replacingOccurrences(of: "\r", with: "")
            NSLog("[Lumen][clipboard] \(label) 纯文本 字数=\(string.count) 预览=\(String(oneLine.prefix(160)))")
        } else {
            NSLog("[Lumen][clipboard] \(label) 无纯文本")
        }

        let urls = (pasteboard.readObjects(forClasses: [NSURL.self]) as? [URL]) ?? []
        if urls.isEmpty {
            NSLog("[Lumen][clipboard] \(label) 无文件 URL")
        } else {
            NSLog("[Lumen][clipboard] \(label) 文件 URL=\(urls.map(\.path).joined(separator: " , "))")
        }
    }
}

enum WindowCapture {

    /// 把主窗口内容渲染成 PNG。
    ///
    /// 两条通道，由 `--capture-screen 1` 选择：
    ///
    /// - **离屏绘制**（默认，`cacheDisplay`）：进程内绘制，不需要任何系统权限。
    ///   缺点是画不准 `NSVisualEffectView`（SwiftUI 的 `.regularMaterial`）。
    /// - **系统录屏**（`screencapture -l<windowNumber>`）：抓到的是屏幕上真实的像素，
    ///   材质是真的混合过的。验证主题 / 材质必须用这条。
    @MainActor
    @discardableResult
    static func captureMainWindow(to path: String) -> Bool {
        // 先抓挂在主窗口上的 sheet（如果有）。sheet 是独立的 NSWindow，
        // 父窗口的 cacheDisplay 里不会有它，所以必须单独抓一张。
        let sheet = attachedSheet()
        if let sheet, let data = render(sheet) {
            write(data, to: suffixed(path, with: "sheet"))
        }

        guard let window = mainWindow(excluding: sheet) else {
            logWindowInventory()
            NSLog("[Lumen] 截图失败：找不到可用的主窗口")
            return false
        }

        logAppearance(of: window)

        // 顺手把「设置」窗口单独拍一张。设置窗口是独立的 NSWindow（不是 sheet），
        // 主窗口的 cacheDisplay 里不会有它，而设置页的视觉又必须看到它才算验证过。
        if let other = otherVisibleWindow(excluding: [sheet, window].compactMap { $0 }),
           let otherData = render(other) {
            _ = write(otherData, to: suffixed(path, with: "settings"))
        }

        if LaunchOptions.captureViaScreen {
            if screenCapture(window, to: path) { return true }
            // 录屏通道失败（多半是没给权限）时退回离屏绘制，而不是交一张空图。
            // 但要把话说清楚：退回之后的图验证不了材质，别让人误以为已经验过了。
            NSLog("[Lumen] 录屏通道不可用，已退回离屏绘制；这张图不能用来判断材质与主题")
        }

        guard let data = render(window) else {
            logWindowInventory()
            NSLog("[Lumen] 截图失败：主窗口无法离屏绘制")
            return false
        }
        return write(data, to: path)
    }

    /// 用系统录屏通道抓整个窗口。
    ///
    /// 走 `screencapture` 子进程而不是 `CGWindowListCreateImage`：后者从 macOS 14 起
    /// 被标记为弃用（替代品 ScreenCaptureKit 的接入成本高得多），
    /// 而这里要的只是「拿到一张真实像素的图」，命令行工具已经够用且不带弃用警告。
    @MainActor
    private static func screenCapture(_ window: NSWindow, to path: String) -> Bool {
        // -x 不播放快门声；-o 去掉窗口阴影——阴影会让图片比窗口大一圈，
        // 而后续取色是按比例定位的，多出来的那一圈会让每个采样点整体偏移。
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        process.arguments = ["-x", "-o", "-l\(window.windowNumber)", path]

        let pipe = Pipe()
        process.standardError = pipe
        process.standardOutput = pipe

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            NSLog("[Lumen] 录屏通道启动失败：\(error.localizedDescription)")
            return false
        }

        let message = String(
            data: pipe.fileHandleForReading.readDataToEndOfFile(),
            encoding: .utf8
        )?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        guard process.terminationStatus == 0,
              let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              data.count > 1024 else {
            NSLog("[Lumen] 录屏通道失败（状态 \(process.terminationStatus)）\(message)")
            return false
        }

        NSLog("[Lumen] 截图已写入 \(path)（录屏通道，真实像素；窗口 \(Int(window.frame.width))x\(Int(window.frame.height))）")
        return true
    }

    /// 除主窗口与 sheet 之外的另一个可见窗口——目前只可能是「设置」。
    @MainActor
    private static func otherVisibleWindow(excluding excluded: [NSWindow]) -> NSWindow? {
        NSApp.windows.first { candidate in
            candidate.isVisible
                && candidate.sheetParent == nil
                && !excluded.contains { $0 === candidate }
                && (candidate.contentView?.bounds.height ?? 0) > 100
        }
    }

    /// 打印窗口的真实外观与系统色解析结果。
    ///
    /// 为什么需要：`cacheDisplay` 渲染 `NSVisualEffectView`（SwiftUI 的 `.regularMaterial`）
    /// 时并不可靠——材质在离屏位图里常常被画成一层不随外观变化的浅色。于是「截图里侧栏是
    /// 浅色」既可能是主题真的没生效，也可能只是截图手段的假象。把 `effectiveAppearance`
    /// 和按该外观解析出的系统色打出来，就能把这两件事彻底分开。
    @MainActor
    private static func logAppearance(of window: NSWindow) {
        let effective = window.effectiveAppearance
        let isDark = effective.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua

        var resolved = ""
        effective.performAsCurrentDrawingAppearance {
            let names: [(String, NSColor)] = [
                ("windowBackground", .windowBackgroundColor),
                ("label", .labelColor),
                ("controlBackground", .controlBackgroundColor)
            ]
            resolved = names.map { name, color in
                let rgb = color.usingColorSpace(.sRGB) ?? color
                return "\(name)=#\(hex(rgb))"
            }.joined(separator: " ")
        }

        NSLog(
            "[Lumen] 窗口外观：app=\(NSApp.appearance?.name.rawValue ?? "nil") "
                + "window=\(window.appearance?.name.rawValue ?? "nil") "
                + "effective=\(effective.name.rawValue) 判定=\(isDark ? "深色" : "浅色") \(resolved)"
        )

        let inventory = NSApp.windows.map { candidate in
            let mark = candidate === window ? "★" : " "
            return "\(mark)\(type(of: candidate)) "
                + "appearance=\(candidate.appearance?.name.rawValue ?? "nil") "
                + "visible=\(candidate.isVisible) "
                + "sheetParent=\(candidate.sheetParent != nil) "
                + "frame=\(Int(candidate.frame.width))x\(Int(candidate.frame.height))"
        }
        NSLog("[Lumen] 窗口清单（★=被截图的那个）共 \(NSApp.windows.count) 个：\n\(inventory.joined(separator: "\n"))")
    }

    private static func hex(_ color: NSColor) -> String {
        String(
            format: "%02X%02X%02X",
            Int(round(color.redComponent * 255)),
            Int(round(color.greenComponent * 255)),
            Int(round(color.blueComponent * 255))
        )
    }

    /// 截图失败时把窗口清单打出来。没有录屏权限的机器上，这是唯一能看清
    /// 「为什么抓不到窗口」的手段。
    @MainActor
    private static func logWindowInventory() {
        let lines = NSApp.windows.map { window in
            let size = window.contentView?.bounds.size ?? .zero
            return "  class=\(type(of: window)) visible=\(window.isVisible) "
                + "sheetParent=\(window.sheetParent != nil) key=\(window.isKeyWindow) "
                + "frame=\(Int(window.frame.width))x\(Int(window.frame.height)) "
                + "content=\(Int(size.width))x\(Int(size.height))"
        }
        NSLog("[Lumen] 当前窗口共 \(NSApp.windows.count) 个：\n\(lines.joined(separator: "\n"))")
    }

    private static func render(_ window: NSWindow) -> Data? {
        // 默认只画 contentView。带上 `--capture-chrome 1` 时从 theme frame 开始画，
        // 这样标题栏与工具栏（含左侧的面板开关、中间的标题、右侧的按钮）也会进画面。
        let target = (LaunchOptions.captureIncludesChrome ? window.contentView?.superview : nil)
            ?? window.contentView
        guard let view = target, view.bounds.width > 1, view.bounds.height > 1,
              let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return nil }
        view.cacheDisplay(in: view.bounds, to: rep)
        return rep.representation(using: .png, properties: [:])
    }

    @discardableResult
    private static func write(_ data: Data, to path: String) -> Bool {
        do {
            try data.write(to: URL(fileURLWithPath: path))
            NSLog("[Lumen] 截图已写入 \(path)")
            return true
        } catch {
            NSLog("[Lumen] 截图写入失败：\(error)")
            return false
        }
    }

    /// /tmp/a.png → /tmp/a.sheet.png
    private static func suffixed(_ path: String, with tag: String) -> String {
        let url = URL(fileURLWithPath: path)
        let base = url.deletingPathExtension().lastPathComponent
        let ext = url.pathExtension.isEmpty ? "png" : url.pathExtension
        return url.deletingLastPathComponent()
            .appendingPathComponent("\(base).\(tag).\(ext)")
            .path
    }

    private static func attachedSheet() -> NSWindow? {
        NSApp.windows.first { $0.sheetParent != nil && $0.isVisible }
    }

    private static func mainWindow(excluding excluded: NSWindow?) -> NSWindow? {
        let candidates = NSApp.windows.filter { window in
            window !== excluded
                && window.isVisible
                && window.contentView != nil
                && window.contentView!.bounds.height > 100
        }
        return candidates.max { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height }
    }

    /// 启动后延时截图并退出，用于自动化自检。
    ///
    /// 做成「轮询到窗口出现为止」而不是一次性 `asyncAfter`：实测发现从命令行直接
    /// 启动二进制时，SwiftUI 的 WindowGroup 有概率不创建窗口（同一条命令跑两次，
    /// 一次有窗口一次没有），此时一次性截图会直接失败，把验证结果变成掷骰子。
    @MainActor
    static func scheduleCaptureIfRequested() {
        guard let path = LaunchOptions.capturePath else { return }

        let minimumDelay = max(LaunchOptions.captureDelay, 0.5)
        // 窗口迟迟不出现时不要无限等，否则自检会挂住整个构建流程
        let giveUpAfter = minimumDelay + 12

        Task { @MainActor in
            let start = Date()
            while true {
                let elapsed = Date().timeIntervalSince(start)

                if elapsed >= minimumDelay, hasCapturableWindow() {
                    captureMainWindow(to: path)
                    NSApp.terminate(nil)
                    return
                }

                if elapsed >= giveUpAfter {
                    logWindowInventory()
                    NSLog("[Lumen] 截图超时：\(Int(giveUpAfter))s 内没有等到可用窗口")
                    NSApp.terminate(nil)
                    return
                }

                try? await Task.sleep(nanoseconds: 250_000_000)
            }
        }
    }

    @MainActor
    private static func hasCapturableWindow() -> Bool {
        NSApp.windows.contains { $0.isVisible && ($0.contentView?.bounds.height ?? 0) > 100 }
    }
}
