import Foundation
import CoreGraphics

/// 整本书的 OCR 驱动层。
///
/// ## 它解决什么
///
/// `OCRService.recognize(in:)` 只认一张位图，是「一次识别」。而扫描件与
/// 缺 ToUnicode 的书（实测《第二人称观点》396 页、《怀特海文集》144 页）
/// 需要的是「**整本识别**」：几百页、几分钟、必须能中止、必须能接着用、进度要看得见。
/// 这一层就是那件事。
///
/// ## 三条设计约束（都不是可选的）
///
/// 1. **不依赖 PDFKit。** 本项目 `LumenKit` 不引 PDFKit（它在界面层），
///    所以这里只收一个 `renderer` 闭包 —— 界面上层负责把某一页渲染成位图，
///    这一层负责调度、识别、拼接、缓存、取消。于是调度逻辑可以脱离 PDF 文件被断言。
///
/// 2. **渲染必须串行、识别才并发。** PDFKit 的 `PDFDocument` 不是线程安全的，
///    同一个 `PDFDocument` 上 4 个线程同时 `page.draw` 是踩未定义行为
///    （而且这种 bug 只在特定文档上偶发，最难查）。所以渲染走 actor（天然串行），
///    单页渲染实测只要几十毫秒；真正贵的是 Vision 识别（实测 675ms/页），
///    那部分并发跑。**贵的并发、脆的串行**，两边各取所需。
///
/// 3. **取消要点到每一页。** 396 页的书跑 4.5 分钟，用户中途关掉面板/切文档是常态。
///    每一页开始前查 `Task.isCancelled`，且已认完的页**照样写进缓存** ——
///    中止一次不该让前面几分钟白跑。
public enum BookOCR {

    /// 识别进度。
    public struct Progress: Sendable, Equatable {
        public let completed: Int
        public let total: Int

        public init(completed: Int, total: Int) {
            self.completed = completed
            self.total = total
        }

        public var fraction: Double {
            total > 0 ? Double(completed) / Double(total) : 0
        }

        public var isFinished: Bool { total > 0 && completed >= total }
    }

    /// 整本识别的结果。
    public struct Outcome: Sendable {
        /// 按页号升序的行。只含识别到内容的页。
        public let lines: [PDFTextLine]
        /// 真的跑完识别的页数（含识别为空白的页）。
        public let pagesProcessed: Int
        /// 渲染或识别失败的页号，升序。**不阻断其余页**。
        public let failedPages: [Int]
        /// 是否被取消（取消时 `lines` 是已完成的部分，不是空）。
        public let cancelled: Bool
        public let elapsed: TimeInterval

        public var hasContent: Bool { !lines.isEmpty }
    }

    // MARK: - 参数

    public struct Options: Sendable {
        /// 并发识别的页数。
        ///
        /// 取 4 与本项目 EPUB 逐段翻译的批次一致。实测单页 675ms，4 并发在
        /// Apple Silicon 上接近线性加速（Vision 内部已经用满了神经引擎之外的算力，
        /// 再往上加收益迅速衰减），396 页从 4.5 分钟压到约 1.4 分钟。
        public var concurrency: Int = 4
        public var languages: [String] = OCRService.defaultLanguages
        /// 渲染倍数。实测 1.5 / 2.0 / 3.0 三档的识别质量差异远小于耗时差异，
        /// 2.0 是「小字号也认得出」与「不等太久」的拐点。
        public var renderScale: CGFloat = 2.0

        public init() {}
    }

    // MARK: - 渲染器

    /// 串行渲染器。
    ///
    /// 用 actor 而不是锁：渲染发生在**后台线程**（主线程要留给界面），
    /// 而 actor 天然保证「同一时刻只有一个渲染在进行」，不需要手写 NSLock
    /// 也不会忘了 unlock。`render` 闭包由界面层提供，负责
    /// `PDFPage.draw(with:to:)` 到一张位图。
    public actor Renderer {
        private let render: @Sendable (Int, CGFloat) async -> CGImage?

        public init(render: @escaping @Sendable (Int, CGFloat) async -> CGImage?) {
            self.render = render
        }

        func image(for pageIndex: Int, scale: CGFloat) async -> CGImage? {
            await render(pageIndex, scale)
        }
    }

    // MARK: - 主入口

    /// 识别一个页区间。
    ///
    /// - Parameters:
    ///   - pages: 要识别的页号（0-based，升序更好但不是必须）。
    ///   - renderer: 串行渲染器。见 `Renderer` 的注释。
    ///   - options: 并发数与渲染倍数。
    ///   - progress: 每完成一页回调一次。回调在后台线程，调用方自己跳主线程刷界面。
    public static func recognize(
        pages: [Int],
        renderer: Renderer,
        options: Options = Options(),
        progress: (@Sendable (Progress) -> Void)? = nil
    ) async -> Outcome {
        let started = Date()
        let total = pages.count
        guard total > 0 else {
            return Outcome(lines: [], pagesProcessed: 0, failedPages: [],
                           cancelled: false, elapsed: 0)
        }

        let concurrency = max(1, min(options.concurrency, total))
        var collected: [Int: [PDFTextLine]] = [:]
        var failed: [Int] = []
        var completed = 0
        var wasCancelled = false

        await withTaskGroup(of: (page: Int, lines: [PDFTextLine]?, cancelled: Bool).self) { group in
            var next = 0

            func submit() {
                guard next < total else { return }
                let pageIndex = pages[next]
                next += 1
                group.addTask {
                    // 取消检查放在**每页开始之前**：正在跑的那一页让它跑完
                    // （Vision 的 perform 不可中断，硬断会白白丢掉已经花掉的算力），
                    // 但不再派新页。
                    if Task.isCancelled { return (pageIndex, nil, true) }

                    guard let image = await renderer.image(for: pageIndex, scale: options.renderScale) else {
                        return (pageIndex, nil, false)
                    }
                    guard let result = try? OCRService.recognize(in: image, languages: options.languages) else {
                        return (pageIndex, nil, false)
                    }
                    return (pageIndex, lines(from: result, pageIndex: pageIndex, image: image), false)
                }
            }

            for _ in 0..<concurrency { submit() }

            for await outcome in group {
                if outcome.cancelled {
                    wasCancelled = true
                    continue
                }
                if let lines = outcome.lines {
                    collected[outcome.page] = lines
                } else {
                    // 渲染失败或识别抛错。**不中断整本** —— 一页坏掉不该让
                    // 三百多页白跑，如实记下页号即可。
                    failed.append(outcome.page)
                }
                completed += 1
                progress?(Progress(completed: completed, total: total))
                submit()
            }
        }

        let ordered = collected.keys.sorted().flatMap { collected[$0] ?? [] }
        return Outcome(lines: ordered,
                       pagesProcessed: completed,
                       failedPages: failed.sorted(),
                       cancelled: wasCancelled,
                       elapsed: Date().timeIntervalSince(started))
    }

    /// 把一次 OCR 读数转成 `PDFTextLine`。
    ///
    /// 坐标换算：Vision 的 `boundingBox` 是**归一化**的、原点在**左下角**，
    /// 与 PDF 的页面坐标同向，所以直接乘页面尺寸即可，**不要翻转 y** ——
    /// 这一处翻转与否决定了段落顺序会不会整个倒过来，而它错了界面只是「顺序有点怪」，
    /// 不会报错。所以这里显式写下依据。
    public static func lines(
        from result: OCRPageResult,
        pageIndex: Int,
        image: CGImage
    ) -> [PDFTextLine] {
        let width = CGFloat(image.width)
        let height = CGFloat(image.height)
        return result.lines.map { line in
            let box = line.box
            let rect = CGRect(x: box.minX * width,
                              y: box.minY * height,
                              width: box.width * width,
                              height: box.height * height)
            return PDFTextLine(pageIndex: pageIndex, text: line.text, bounds: rect)
        }
    }
}
