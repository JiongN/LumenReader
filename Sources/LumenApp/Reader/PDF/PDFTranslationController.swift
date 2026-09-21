import Foundation
import Combine
import PDFKit
import LumenKit
import Translation

// MARK: - 段落译文的状态

/// 一个段落的翻译状态。
///
/// 四态**必须互相区分得开**：用户看的是一屏几十个段落，「这条翻好了 / 这条在翻 /
/// 这条失败了 / 这条我压根没打算翻」如果长得一样，那就等于没有状态。
/// 与 `docs/design/mockup-pdf-contrast-translation.html` 里画的那四种视觉一一对应。
public enum ParagraphTranslationState: Equatable, Sendable {
    /// 排队中，还没轮到。
    case pending
    /// 正在翻。
    case translating
    /// 有译文。
    case done(String)
    /// 失败。**带原因** —— 只写「失败」等于让用户去猜是网络、是限流还是程序坏了。
    case failed(String)
    /// 刻意跳过。**也带原因** —— 不写原因的跳过会被当成 bug。
    case skipped(String)

    public var translation: String? {
        if case .done(let text) = self { return text }
        return nil
    }

    public var isSettled: Bool {
        switch self {
        case .done, .failed, .skipped: return true
        case .pending, .translating: return false
        }
    }

    /// 是不是失败态。**必须能被单独问出来** —— 界面要给失败段单独显示「只重试这一段」，
    /// 自检也要按它统计。
    public var isFailed: Bool {
        if case .failed = self { return true }
        return false
    }

    /// 失败的原因（供界面显示与自检核对）。非失败态返回 nil。
    public var failureReason: String? {
        if case .failed(let reason) = self { return reason }
        return nil
    }
}

/// 整份文档的翻译阶段。
public enum PDFTranslationPhase: Equatable, Sendable {
    case idle
    /// 正在抽段落（读文字层；必要时还要评估文字层质量）。
    case preparing
    /// 文字层不可信，正在整本 OCR。`elapsed` 是已经跑掉的秒数。
    case recognizing(OCRProgress)
    case running(done: Int, total: Int)
    case finished
    case cancelled
    case failed(String)

    public struct OCRProgress: Equatable, Sendable {
        public let completed: Int
        public let total: Int
    }

    public var isBusy: Bool {
        switch self {
        case .preparing, .recognizing, .running: return true
        default: return false
        }
    }

    public var isFailure: Bool {
        if case .failed = self { return true }
        return false
    }
}

// MARK: - 纯函数：哪些段落值得翻

/// 决定「这一段要不要送去翻」。
///
/// 抽成纯函数是为了能被表驱动断言 —— 而不是散在编排逻辑里靠肉眼审。
public enum TranslationEligibility {

    /// 返回 nil 表示应该翻；返回字符串表示跳过的原因（这句话会显示给用户）。
    ///
    /// 只做两条判断，都不带猜测成分：
    ///
    /// 1. **一个字母都没有** —— 页码、装饰性符号、公式编号。送过去只会拿回一模一样的东西。
    /// 2. **原文已经是目标语言** —— 中文书上选「译为中文」，翻一遍纯属浪费配额，
    ///    而且必应对同语言输入的行为并不稳定。
    ///
    /// 刻意**不**按 `isShort` 跳过：图注、表头虽然短，但它们是正文的一部分，
    /// 「看起来短」不足以断定不该翻。这条决定权留给用户。
    public static func skipReason(for paragraph: PDFParagraph, target: String) -> String? {
        if !paragraph.text.contains(where: { $0.isLetter }) {
            return "这一段不含文字（页码或装饰）"
        }
        if isAlreadyTargetLanguage(paragraph.text, target: target) {
            return "原文已是目标语言"
        }
        return nil
    }

    /// 原文是否已经是目标语言。
    ///
    /// 只实现中日韩这三条目标语言（它们的字符集与拉丁文不重叠，判得准）。
    /// 英文目标**不判** —— 「这串拉丁字母是英文还是德文」需要语言识别，
    /// 而猜错的代价（把德语当英文跳过，或反过来白翻一遍）比省下的配额更贵。
    public static func isAlreadyTargetLanguage(_ text: String, target: String) -> Bool {
        let isCJKTarget = target.hasPrefix("zh") || target.hasPrefix("ja") || target.hasPrefix("ko")
        guard isCJKTarget else { return false }

        var letters = 0
        var cjk = 0
        for scalar in text.unicodeScalars where CharacterSet.letters.contains(scalar) {
            letters += 1
            if isCJK(scalar) { cjk += 1 }
        }
        guard letters >= 12 else { return false }
        // 0.6 而不是 0.5：中英混排的学术段落里，中文书偶尔引一大段英文原文，
        // 那种段落是**该翻**的（用户看不懂英文才要翻译）。只有整段基本是中文时才跳过。
        return Double(cjk) / Double(letters) >= 0.6
    }

    private static func isCJK(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x2E80...0x2FFF,      // CJK 部首 / 康熙部首（部分 PDF 字体映射到这里）
             0x3040...0x30FF,      // 日文假名
             0x3400...0x4DBF,      // 汉字扩展 A
             0x4E00...0x9FFF,      // 汉字基本区
             0xAC00...0xD7AF,      // 谚文音节
             0xF900...0xFAFF:      // 兼容汉字
            return true
        default:
            return false
        }
    }
}

// MARK: - 纯函数：长段切分

/// 把长段切成引擎能一次吃完的块。
///
/// 必应的单次请求有长度上限，超了会直接报错（而不是截断）。所以切分必须发生在
/// 发请求之前，且**尽量切在句末** —— 从句中切开会让两块各自缺主语，译文质量塌掉，
/// 而这正是「逐行翻」被否掉的那个理由，不能在块这一层又犯一次。
public enum TranslationTextSplitter {

    /// 单块字符上限。留出余量：上限附近的实测值会随接口调整波动，压到 900 更稳。
    public static let defaultLimit = 900

    /// 切分成若干块。返回的块按原顺序拼接后**等于**原文（只多出被吃掉的空白）。
    public static func split(_ text: String, limit: Int = defaultLimit) -> [String] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > limit, limit > 0 else { return trimmed.isEmpty ? [] : [trimmed] }

        var chunks: [String] = []
        var current = ""

        // 先按「句末标点 + 其后空白」切句，再贪心地把句子装进块。
        for sentence in sentences(of: trimmed) {
            if sentence.count > limit {
                // 单句就超限（中文长句很常见，因为中文没有词间空格）：
                // 先把当前块收掉，再对这句硬切。
                if !current.isEmpty { chunks.append(current); current = "" }
                chunks.append(contentsOf: hardSplit(sentence, limit: limit))
                continue
            }
            if current.count + sentence.count > limit {
                chunks.append(current)
                current = sentence
            } else {
                current += sentence
            }
        }
        if !current.isEmpty { chunks.append(current) }
        return chunks.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    /// 按句末标点切，**标点归前一句**。空白一并留在句尾，这样拼接回去不丢空格。
    static func sentences(of text: String) -> [String] {
        let terminators: Set<Character> = ["。", "！", "？", "…", ".", "!", "?", ";", "；"]
        var out: [String] = []
        var current = ""
        var index = text.startIndex

        while index < text.endIndex {
            let ch = text[index]
            current.append(ch)
            if terminators.contains(ch) {
                // 把紧随其后的空白与右引号 / 右括号一并收进本句，
                // 否则它们会掉到下一句开头，拼接时位置就错了。
                var next = text.index(after: index)
                while next < text.endIndex,
                      text[next].isWhitespace || "」』）)\"’”".contains(text[next]) {
                    current.append(text[next])
                    next = text.index(after: next)
                }
                out.append(current)
                current = ""
                index = next
                continue
            }
            index = text.index(after: index)
        }
        if !current.isEmpty { out.append(current) }
        return out
    }

    /// 兜底硬切。只在「一句话本身就超限」时用到。
    static func hardSplit(_ text: String, limit: Int) -> [String] {
        var out: [String] = []
        var start = text.startIndex
        while start < text.endIndex {
            let end = text.index(start, offsetBy: limit, limitedBy: text.endIndex) ?? text.endIndex
            out.append(String(text[start..<end]))
            start = end
        }
        return out
    }

    /// 拼接译文块。中文之间不加空格，其余加一个空格 —— 否则英文会粘成一长串。
    public static func join(_ pieces: [String], target: String) -> String {
        let isCJKTarget = target.hasPrefix("zh") || target.hasPrefix("ja")
        let separator = isCJKTarget ? "" : " "
        return pieces
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: separator)
    }
}

// MARK: - 后台渲染器

/// 给 OCR 兜底用的**独立** `PDFDocument` 渲染器。
///
/// 为什么另开一份文档而不是复用界面上那份：`PDFDocument` 不是线程安全的，
/// 而界面上的那份**正在被 PDFView 每帧绘制**。同一实例上再开 4 个线程 `page.draw`
/// 是踩未定义行为，而且这类 bug 只在特定文档上偶发、最难查。
/// 另开一份的代价只是多占一份内存，换来的是「后台渲染永远不碰前台正在画的那份」。
actor PDFPageRenderer {

    private let document: PDFDocument?

    init(url: URL) {
        self.document = PDFDocument(url: url)
    }

    var isUsable: Bool { document != nil }

    func image(for pageIndex: Int, scale: CGFloat) -> CGImage? {
        guard let document, let page = document.page(at: pageIndex) else { return nil }
        return Self.render(page, scale: scale)
    }

    /// 把一页画成位图。所有调用都被 actor 串行化 —— 见类型注释。
    static func render(_ page: PDFPage, scale: CGFloat) -> CGImage? {
        let box = page.bounds(for: .mediaBox)
        let width = Int(box.width * scale)
        let height = Int(box.height * scale)
        guard width > 8, height > 8 else { return nil }

        guard let context = CGContext(
            data: nil, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
        ) else { return nil }

        context.setFillColor(gray: 1, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.scaleBy(x: scale, y: scale)
        page.draw(with: .mediaBox, to: context)
        return context.makeImage()
    }
}

// MARK: - 编排层

/// PDF 逐段对照翻译的编排层。
///
/// 它只做四件事，每一件都有明确的边界：
///
/// 1. **取段落** —— 优先读文字层；文字层被 `TextLayerTrust` 判为不可信（或本来就是
///    扫描件）时，走 `BookOCR` 整本识别，用识别结果当文字源。
/// 2. **排队翻** —— 批 4 并发（与 EPUB 侧一致），可中止，已完成的结果**照样落盘**。
/// 3. **缓存** —— 键是段落的稳定 id（页号 + 段首坐标），存在文档自己的目录里。
/// 4. **暴露状态** —— 每个段落四态之一、整份文档一个阶段。界面照着画。
///
/// **它不写回用户的 PDF。** 译文只在这个控制器和数据目录里，由独立的段落对照栏显示。
/// 这条是硬约束，不是「暂时没做」—— 对照阅读不该改动原文文件。
@MainActor
final class PDFTranslationController: ObservableObject {

    // MARK: 对外状态

    /// 抽取出来的段落，按阅读顺序（页号升序 → 页内自上而下）。
    @Published private(set) var paragraphs: [PDFParagraph] = []
    @Published private(set) var states: [String: ParagraphTranslationState] = [:]
    @Published private(set) var phase: PDFTranslationPhase = .idle
    /// 段落对照栏的显示开关。
    @Published var isVisible: Bool = false
    /// 递增即表示 SwiftUI 需要创建/刷新一次系统翻译会话。
    @Published private(set) var appleSessionRequest = 0

    /// 这一轮的**文字来源**，必须如实告诉用户。
    ///
    /// 三种取值：`nil` 表示还没抽；「文字层」表示直接用；「OCR」表示文字层不可信、
    /// 已改用整本识别。用户看到译文时有权知道它来自哪条路 —— 尤其是 OCR 那条，
    /// 识别错误会直接变成译文错误。
    @Published private(set) var sourceNote: String?

    // MARK: 私有

    private var documentPath: String?
    private var targetLanguage = TranslationLanguage.defaultID
    private var cacheScope = TranslationEngineCatalog.defaultID
    private var cache = TranslationCache()
    private var runTask: Task<Void, Never>?
    /// 每次「从头开始」都把它加一，用来丢弃上一轮迟到的结果。
    private var generation = 0
    /// 距上次落盘又攒了几条 —— 攒够 8 条存一次，既不丢已完成的活也不每段都写盘。
    private var pendingSinceSave = 0

    private static let batchSize = 4
    private static let saveEvery = 8

    init() {}

    // MARK: 派生读数（界面与自检都读这些）

    var totalCount: Int { paragraphs.count }

    var doneCount: Int { states.values.filter { $0.translation != nil }.count }

    var failedCount: Int { states.values.filter(\.isFailed).count }

    var skippedCount: Int {
        states.values.filter { if case .skipped = $0 { return true }; return false }.count
    }

    /// 「已定局」的条数：翻好 + 失败 + 跳过。进度条用这个，否则失败的段会让进度永远到不了头。
    var settledCount: Int { states.values.filter(\.isSettled).count }

    func state(of id: String) -> ParagraphTranslationState { states[id] ?? .pending }

    /// 一段的原文在页面上的位置，供排序、定位与后续段落联动使用。
    func paragraph(id: String) -> PDFParagraph? {
        paragraphs.first { $0.id == id }
    }

    // MARK: 准备

    /// 接手一份文档：抽段落、读缓存、把缓存命中填进状态。
    ///
    /// **重复调用同一份文档会重置**（切走再切回来就是这样），但磁盘缓存命中，
    /// 所以不会白烧配额。
    func prepare(documentPath: String, target: String, engineID: String,
                 glossary: [TranslationGlossaryEntry]) async {
        let normalizedTarget = TranslationLanguage.target(for: target).id
        let nextScope = Self.cacheScope(engineID: engineID, glossary: glossary)
        guard self.documentPath != documentPath || targetLanguage != normalizedTarget
                || cacheScope != nextScope || paragraphs.isEmpty else { return }

        cancelRun()
        generation += 1
        self.documentPath = documentPath
        targetLanguage = normalizedTarget
        cacheScope = nextScope
        paragraphs = []
        states = [:]
        sourceNote = nil
        phase = .preparing
        cache = TranslationCache.load(from: AppPaths.translationCacheFile(forPath: documentPath))

        let url = URL(fileURLWithPath: documentPath)
        let extracted = await Self.extractText(with: url)
        guard !Task.isCancelled else { phase = .cancelled; return }

        var lines = extracted.lines
        if extracted.needsOCR {
            // 文字层不可信 —— 走整本 OCR。这一步要几分钟，期间界面显示进度。
            let ocr = await recognizeBook(url: url)
            guard !Task.isCancelled else { phase = .cancelled; return }
            if ocr.hasContent {
                lines = ocr.lines
                sourceNote = "本文件文字层不可信，已改用整本 OCR 识别（\(ocr.pagesProcessed) 页）"
            } else {
                // OCR 也没结果 —— 不能假装成功。
                sourceNote = nil
                phase = .failed("文字层不可读，OCR 也没识别出内容（可能是纯图片页或加密文档）")
                return
            }
        } else if lines.isEmpty {
            sourceNote = nil
            phase = .failed("这份 PDF 抽不出文字（可能是扫描件，或页面全部由图片组成）")
            return
        } else {
            sourceNote = "文字取自 PDF 文字层"
        }

        let all = PDFParagraphExtractor.paragraphs(from: lines, pageSizes: extracted.pageSizes)

        // 先把跳过项定下来，再填缓存命中 —— 顺序反了会让「已跳过」的段落被缓存里的
        // 旧译文盖掉（用户改了目标语言之后就会撞上这种情况）。
        let target = targetLanguage
        var fresh: [String: ParagraphTranslationState] = [:]
        for paragraph in all {
            if let reason = TranslationEligibility.skipReason(for: paragraph, target: target) {
                fresh[paragraph.id] = .skipped(reason)
            } else if let cached = cache.translation(for: cacheKey(paragraph.id, target: target)) {
                fresh[paragraph.id] = .done(cached)
            } else {
                fresh[paragraph.id] = .pending
            }
        }

        paragraphs = all
        states = fresh
        phase = .idle
    }

    /// 抽文字层 + 判可信度。整段在后台跑（大书的主线程待不住）。
    private static func extractText(with url: URL) async -> (lines: [PDFTextLine],
                                                             pageSizes: [Int: CGSize],
                                                             needsOCR: Bool) {
        await Task.detached(priority: .userInitiated) {
            guard let doc = PDFDocument(url: url) else {
                return ([], [:], false)
            }
            let lines = PDFLineExtractor.lines(in: doc)
            let sizes = PDFLineExtractor.pageSizes(in: doc)

            // 判可信度：抽几页当样本，逐页「文字层读数 vs 渲染后 OCR 读数」比一次。
            // 样本页取**正文中段**而不是开头 —— 开头是封面 / 版权页 / 目录，
            // 那几页几乎没有正文，拿它们判会把整本书误判（封面页文字层本来就短）。
            let probe = await samplePages(pageCount: doc.pageCount, count: 3)
            var needsOCR = false
            if lines.isEmpty {
                needsOCR = true          // 一个字的文字层都没有 = 扫描件
            } else if !probe.isEmpty {
                needsOCR = await pageSamplesSayOCRNeeded(pages: probe, doc: doc)
            }
            return (lines, sizes, needsOCR)
        }.value
    }

    /// 采样页号：跳过前 10% 与后 5%（封面、目录、索引），在正文区间里均匀取。
    static func samplePages(pageCount: Int, count: Int) -> [Int] {
        guard pageCount > 0, count > 0 else { return [] }
        let lower = pageCount / 10
        let upper = max(lower, pageCount - pageCount / 20 - 1)
        guard upper > lower else { return [pageCount / 2] }
        let span = upper - lower
        return (0..<count).map { lower + span * $0 / max(1, count - 1) }
    }

    /// 逐页比对。**任一页判为不可信就主张 OCR** —— 一本书里缺 ToUnicode 的往往不是某一页，
    /// 而是某个字体，通常成片出现；宁可多 OCR 一次，也不要拿乱码去翻。
    private static func pageSamplesSayOCRNeeded(pages: [Int], doc: PDFDocument) async -> Bool {
        await Task.detached(priority: .userInitiated) {
            for index in pages {
                guard let page = doc.page(at: index) else { continue }
                let layer = page.string ?? ""
                guard let image = PDFPageRenderer.render(page, scale: 2.0) else { continue }
                guard let result = try? OCRService.recognize(in: image) else { continue }
                let ocr = result.lines.map(\.text).joined(separator: "\n")
                let verdict = TextLayerTrust.assess(textLayer: layer, ocr: ocr).verdict
                if verdict.needsOCR { return true }
            }
            return false
        }.value
    }

    /// 整本 OCR。进度回主线程更新 `phase`。
    private func recognizeBook(url: URL) async -> BookOCR.Outcome {
        let renderer = PDFPageRenderer(url: url)
        let total = await Self.pageCount(of: url)
        let pages = Array(0..<total)

        phase = .recognizing(.init(completed: 0, total: total))
        let outcome = await BookOCR.recognize(
            pages: pages,
            renderer: BookOCR.Renderer { index, scale in
                await renderer.image(for: index, scale: scale)
            },
            progress: { [weak self] progress in
                Task { @MainActor [weak self] in
                    guard let self, self.phase.isBusy else { return }
                    self.phase = .recognizing(.init(completed: progress.completed,
                                                    total: progress.total))
                }
            }
        )
        return outcome
    }

    private static func pageCount(of url: URL) async -> Int {
        await Task.detached(priority: .userInitiated) {
            PDFDocument(url: url)?.pageCount ?? 0
        }.value
    }

    // MARK: 跑

    /// 翻全部还没定局的段落。
    func startAll(engineID: String, target: String,
                  customEngine: (any TranslationEngine)? = nil) {
        guard runTask == nil else { return }
        let queue = paragraphs.filter { !state(of: $0.id).isSettled }
        guard !queue.isEmpty else {
            phase = .finished
            return
        }
        if engineID == AppleSystemTranslation.engineID {
            appleSessionRequest &+= 1
            return
        }
        guard let engine = customEngine ?? TranslationEngineCatalog.engine(for: engineID) else {
            phase = .failed("所选翻译引擎不可用")
            return
        }
        let token = generation
        runTask = Task { [weak self] in
            await self?.run(queue: queue, token: token, engine: engine, target: target)
            await MainActor.run { [weak self] in self?.runTask = nil }
        }
    }

    /// 只重试失败的那些。**不重跑已成功的** —— 失败往往是个别请求撞了限流，
    /// 整篇重来会白烧一遍配额，还可能再撞一次。
    func retryFailed(engineID: String, target: String,
                     customEngine: (any TranslationEngine)? = nil) {
        guard runTask == nil else { return }
        let queue = paragraphs.filter { state(of: $0.id).isFailed }
        guard !queue.isEmpty else { return }
        if engineID == AppleSystemTranslation.engineID {
            appleSessionRequest &+= 1
            return
        }
        guard let engine = customEngine ?? TranslationEngineCatalog.engine(for: engineID) else {
            phase = .failed("所选翻译引擎不可用")
            return
        }
        let token = generation
        runTask = Task { [weak self] in
            await self?.run(queue: queue, token: token, engine: engine, target: target)
            await MainActor.run { [weak self] in self?.runTask = nil }
        }
    }

    /// 中止。已翻好的**留在缓存里**，下次接着用。
    func stop() {
        cancelRun()
        if phase.isBusy { phase = .cancelled }
        persistCache(force: true)
    }

    /// 清掉当前文档的全部译文（含磁盘缓存）。用户换目标语言后想重来时用。
    func resetTranslations() {
        cancelRun()
        cache.removeAll()
        persistCache(force: true)
        let target = targetLanguage
        var fresh: [String: ParagraphTranslationState] = [:]
        for paragraph in paragraphs {
            let reason = TranslationEligibility.skipReason(for: paragraph, target: target)
            fresh[paragraph.id] = reason.map { .skipped($0) } ?? .pending
        }
        states = fresh
        phase = .idle
    }

    private func cancelRun() {
        runTask?.cancel()
        runTask = nil
        // 换一代：上一轮迟到的结果会因为 token 不匹配被丢掉，
        // 不会把「已经废弃的译文」写进新状态。
        generation += 1
    }

    /// 核心：批 4 并发跑队列。
    private func run(queue: [PDFParagraph], token: Int,
                     engine: any TranslationEngine, target: String) async {
        phase = .running(done: settledCount, total: paragraphs.count)

        await withTaskGroup(of: (String, TranslationOutcome).self) { group in
            var next = 0

            @MainActor func submit() {
                guard next < queue.count else { return }
                let paragraph = queue[next]
                next += 1
                states[paragraph.id] = .translating
                let text = paragraph.text
                let id = paragraph.id
                group.addTask {
                    (id, await Self.translate(text: text, engine: engine, target: target))
                }
            }

            for _ in 0..<min(Self.batchSize, queue.count) { submit() }

            for await (id, outcome) in group {
                // token 不匹配 = 这一轮已经被作废（用户切了文档或按了中止）。
                // 照样把 group 抽干（不然 withTaskGroup 不会退出），但一个都不落。
                guard token == generation, !Task.isCancelled else { continue }

                switch outcome {
                case .success(let text):
                    states[id] = .done(text)
                    cache.store(text, for: cacheKey(id, target: target))
                    pendingSinceSave += 1
                    if pendingSinceSave >= Self.saveEvery {
                        persistCache(force: true)
                    }
                case .failure(let reason):
                    states[id] = .failed(reason)
                }

                phase = .running(done: settledCount, total: paragraphs.count)
                submit()
            }
        }

        if token == generation, !Task.isCancelled {
            persistCache(force: true)
            // 一律置 finished（而非保持 running(done:total:)）：
            // `.running` 的 `isBusy` 为 true，若整体跑完还挂在 running 上，
            // 面板会停在「进度 + 停止」，而看不到「N 段失败 + 重试」。
            // 失败项本身留在 `states` 里 —— `failedCount` 归它们管，
            // finished 只负责把 busy 清掉，让失败/重试控件能浮出来。
            phase = .finished
        }
    }

    /// 由 SwiftUI `translationTask` 提供的 Apple 会话。使用官方 batch API，
    /// `clientIdentifier` 把乱序返回的结果稳定地对回段落与分块。
    func runApple(session: TranslationSession, target: String) async {
        guard runTask == nil else { return }
        let queue = paragraphs.filter { !state(of: $0.id).isSettled || state(of: $0.id).isFailed }
        guard !queue.isEmpty else { phase = .finished; return }
        let token = generation
        let normalizedTarget = TranslationLanguage.target(for: target).id

        runTask = Task { [weak self] in
            guard let self else { return }
            await self.runAppleQueue(queue, session: session, token: token, target: normalizedTarget)
            await MainActor.run { [weak self] in self?.runTask = nil }
        }
        await runTask?.value
    }

    private func runAppleQueue(_ queue: [PDFParagraph], session: TranslationSession,
                               token: Int, target: String) async {
        phase = .running(done: settledCount, total: paragraphs.count)

        // 一批不超过 24 个文本块，避免长书一次建立数千个请求对象。
        var requests: [TranslationSession.Request] = []
        var owners: [String: (paragraphID: String, chunkIndex: Int, chunkCount: Int)] = [:]
        var translated: [String: [Int: String]] = [:]

        func flush() async -> Error? {
            guard !requests.isEmpty else { return nil }
            let current = requests
            requests.removeAll(keepingCapacity: true)
            do {
                for try await response in session.translate(batch: current) {
                    guard token == generation, !Task.isCancelled,
                          let clientID = response.clientIdentifier,
                          let owner = owners.removeValue(forKey: clientID) else { continue }
                    translated[owner.paragraphID, default: [:]][owner.chunkIndex] = response.targetText
                    if translated[owner.paragraphID]?.count == owner.chunkCount {
                        let pieces = (0..<owner.chunkCount).compactMap { translated[owner.paragraphID]?[$0] }
                        let joined = TranslationTextSplitter.join(pieces, target: target)
                        guard !joined.isEmpty else {
                            states[owner.paragraphID] = .failed("系统翻译返回了空译文")
                            continue
                        }
                        states[owner.paragraphID] = .done(joined)
                        cache.store(joined, for: cacheKey(owner.paragraphID, target: target))
                        pendingSinceSave += 1
                        translated.removeValue(forKey: owner.paragraphID)
                    }
                    phase = .running(done: settledCount, total: paragraphs.count)
                }
                if pendingSinceSave >= Self.saveEvery { persistCache(force: true) }
                return nil
            } catch {
                return error
            }
        }

        for paragraph in queue {
            guard token == generation, !Task.isCancelled else { break }
            let chunks = TranslationTextSplitter.split(paragraph.text)
            guard !chunks.isEmpty else {
                states[paragraph.id] = .skipped("段落内容为空")
                continue
            }
            states[paragraph.id] = .translating
            for (index, chunk) in chunks.enumerated() {
                let requestID = UUID().uuidString
                owners[requestID] = (paragraph.id, index, chunks.count)
                requests.append(.init(sourceText: chunk, clientIdentifier: requestID))
                if requests.count >= 24, let error = await flush() {
                    let reason = Self.describe(error)
                    for value in owners.values { states[value.paragraphID] = .failed(reason) }
                    requests.removeAll()
                    owners.removeAll()
                }
            }
        }
        if let error = await flush() {
            let reason = Self.describe(error)
            for value in owners.values { states[value.paragraphID] = .failed(reason) }
        }

        guard token == generation, !Task.isCancelled else { return }
        persistCache(force: true)
        phase = .finished
    }

    private enum TranslationOutcome: Sendable {
        case success(String)
        case failure(String)
    }

    /// 翻一段（含长段切分）。**非隔离静态方法** —— 网络请求不该占着主线程。
    private static func translate(text: String, engine: any TranslationEngine, target: String) async -> TranslationOutcome {
        let chunks = TranslationTextSplitter.split(text)
        guard !chunks.isEmpty else { return .success("") }

        var pieces: [String] = []
        for chunk in chunks {
            if Task.isCancelled { return .failure("已中止") }
            do {
                let piece = try await engine.translate(chunk, to: target, from: "auto-detect")
                let trimmed = piece.trimmingCharacters(in: .whitespacesAndNewlines)
                // 空译文**当成失败**：静默接受空串，用户看到的是一块空白译文格，
                // 分不清是「翻完了但没内容」还是「坏了」。这跟项目里那条
                // 「绝不静默返回空字符串假装成功」是同一条规则。
                guard !trimmed.isEmpty else { return .failure("引擎返回了空译文") }
                pieces.append(trimmed)
            } catch {
                return .failure(Self.describe(error))
            }
        }
        return .success(TranslationTextSplitter.join(pieces, target: target))
    }

    /// 把错误翻成人话。用户要判断的是「等一下再试」还是「去改设置」，
    /// 所以原因必须具体到能据此行动。
    static func describe(_ error: Error) -> String {
        if let translation = error as? MicrosoftTranslator.TranslationError {
            switch translation {
            case .credentialsUnavailable:
                return "取不到微软翻译的访问凭证（检查网络，或稍后重试）"
            case .serverStatus(let code, _):
                switch code {
                case 429: return "请求太频繁，被限流了（稍后重试即可）"
                case 400, 401, 403: return "访问凭证被拒绝（稍后重试）"
                default: return "翻译接口返回 \(code)"
                }
            case .emptyResponse:
                return "翻译接口返回空结果"
            case .undecodable:
                return "翻译结果无法解析"
            }
        }
        return error.localizedDescription
    }

    // MARK: 落盘

    private func persistCache(force: Bool) {
        guard force || pendingSinceSave >= Self.saveEvery else { return }
        guard let documentPath else { return }
        pendingSinceSave = 0
        // 缓存是这本书的，必须写进它自己的目录（见 AppPaths.translationCacheFile 的注释）。
        cache.save(to: AppPaths.translationCacheFile(forPath: documentPath))
    }

    private func cacheKey(_ paragraphID: String, target: String) -> String {
        "\(cacheScope)::\(target)::\(paragraphID)"
    }

    /// 缓存必须区分引擎和术语表。否则用户改了术语，界面仍会命中旧译文，
    /// 看起来像“术语表不生效”。FNV-1a 是稳定的跨进程摘要，不使用随机种子的 Hasher。
    private static func cacheScope(engineID: String,
                                   glossary: [TranslationGlossaryEntry]) -> String {
        let payload = glossary.filter(\.isUsable)
            .sorted { $0.source.localizedCaseInsensitiveCompare($1.source) == .orderedAscending }
            .map { "\($0.source)=\($0.target)" }
            .joined(separator: "\u{1F}")
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in payload.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        return "\(TranslationEngineCatalog.descriptor(for: engineID).id)-\(String(hash, radix: 16))"
    }
}
