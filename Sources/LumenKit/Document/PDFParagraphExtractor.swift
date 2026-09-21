import Foundation

/// 把页面文字层给出的行聚类成段落。
///
/// PDF 里**没有「段落」这个概念** —— 文字层只给到行（`page.string` 是整页一团，
/// `selectionsByLine()` 给到行），段落在版面上只是「行距略大 + 末行不顶右边界」而已。
/// 所以这里全部判据都来自几何，不依赖语言：中文段首缩进、英文断词规则各不相同，
/// 但「同段行距均匀、段间行距更大、段末行不满」是两类语言共有的排版事实。
///
/// 已知边界（不要假装解决了）：**多栏版面**。本项目在单栏文档上验证过；
/// 多栏需要先按栏切分再聚类，而本机拿不到可验证的双栏样本，
/// 所以这里不发明一个验不了的栏检测器。详见 `docs/VERIFY.md`。
public enum PDFParagraphExtractor {

    public struct Options: Sendable, Equatable {

        /// 相邻两行的竖直间距超过「行高 × 本系数」时判为换段。
        ///
        /// 0.62 的来历：正常行距下 `gap`（上一行的 `minY` 减这一行的 `maxY`）通常在
        /// 行高的 0.1~0.35 之间（行高含上下留白），段间距往往是 0.8 行高以上。
        /// 0.62 落在这两簇中间。调大到 1.0 会把「段间距不大的紧凑排版」并成一段，
        /// 调到 0.3 则会把正常行距也当成换段。
        public var paragraphGapFactor: CGFloat = 0.62

        /// **窄栏/摘要栏的行距放宽系数**。
        ///
        /// 当某块文本的右端显著小于页面正文右端（如双栏版面的单栏、论文摘要区），
        /// 其行距往往大于正文行距（如 1.5~2.5 倍行高）。此时用正文的 0.62 会把同一段拆碎。
        /// 此因子在检测到「窄栏」时生效，建议 1.5~2.0。
        public var narrowColumnGapFactor: CGFloat = 1.8

        /// 判定为「窄栏」的阈值：块右端 / 页面正文右端 < 本值。
        /// Selwyn 摘要右端 337 / 正文右端 445 ≈ 0.76，双栏单栏通常 0.5~0.6。
        public var narrowColumnWidthRatio: CGFloat = 0.85

        /// 行右端缩进超过「参考宽度 × (1 - 本系数)」时判为**段末短行**。
        ///
        /// 0.80 意为「缩进超过参考宽的 20% 才算短行」。合法的短行通常缩进得远不止 20%
        /// （末行往往只剩半行甚至几个字），而两端对齐的中间行几乎不缩进，所以这个界线很宽。
        /// 段末短行是**很强的**换段信号 —— 尤其在垂直间距被压缩的排版里，
        /// 只靠行距会漏判。
        ///
        /// **参考宽度不是一个，是两个，必须同时满足**（见 `cluster` 里 `previousWasShort`）：
        /// 一是整页正文右边界，二是**本段自己的右边界**。只用前者会把
        /// 「自己就排在窄栏里」的整段逐行拆散 —— 论文标题页的摘要常排成比正文窄的栏
        /// （实测 Selwyn 2025 第 2 页：摘要每行只到 `x=337`、正文到 `445`），
        /// 于是摘要的**每一行**都被判成段末短行、20 行摘要碎成 20 段。
        public var shortLineFactor: CGFloat = 0.80

        /// 距页面上 / 下边小于「页高 × 本系数」的行，若同时够短，判为页眉 / 页脚。
        public var furnitureMarginFactor: CGFloat = 0.055

        /// 页眉 / 页脚还要短于「页宽 × 本系数」。
        ///
        /// 两个条件都要满足才剔除：正文首行也可能紧贴页顶，但那行通常是满行宽的。
        /// 只按位置删会把正文首行一起删掉。
        public var furnitureWidthRatio: CGFloat = 0.62

        /// 段内两行水平重叠小于「较窄那行宽 × 本系数」时判为换段。
        ///
        /// 挡的是表格、多栏碎块、左右并排的图注这类**同一竖直位置上的两块文字**：
        /// 它们在竖直方向上挨得很近，但水平上不重叠。
        public var minimumHorizontalOverlapFactor: CGFloat = 0.15

        /// 短于此字符数的段落 `isShort` 为真（不丢弃，只打标）。
        public var minimumBodyLength: Int = 24

        public init() {}
    }

    // MARK: - 入口

    /// 聚类。
    ///
    /// - Parameters:
    ///   - lines: 页面文字层给出的行，可跨页、可乱序。
    ///   - pageSizes: 页号 → 页面尺寸。**页眉 / 页脚识别只在拿得到页尺寸时启用**；
    ///     拿不到就不猜（宁可不删，也不要凭一个猜的页高把正文删掉）。
    public static func paragraphs(
        from lines: [PDFTextLine],
        pageSizes: [Int: CGSize] = [:],
        options: Options = Options()
    ) -> [PDFParagraph] {
        // 空行、零面积行一律先剔掉：它们是 PDFKit 对空白区的常见返回，
        // 混进来会凭空撑大包围盒、干扰行距判断。
        let usable = lines.filter {
            !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && $0.bounds.width > 0.5
                && $0.bounds.height > 0.5
        }
        guard !usable.isEmpty else { return [] }

        let repeatedFurniture = repeatedFurnitureFingerprints(
            in: usable,
            pageSizes: pageSizes
        )

        var result: [PDFParagraph] = []
        for page in Set(usable.map(\.pageIndex)).sorted() {
            let ordered = usable
                .filter { $0.pageIndex == page }
                .sorted(by: readingOrder)
            let kept = dropFurniture(ordered, pageSize: pageSizes[page], options: options,
                                     repeatedFingerprints: repeatedFurniture)
            result.append(contentsOf: cluster(kept, options: options))
        }
        return mergeContinuations(result, pageSizes: pageSizes, options: options)
    }

    // MARK: - 阅读顺序

    /// 页面内的阅读顺序：自上而下；同一水平带内自左向右。
    ///
    /// 实现上刻意用「把竖直中心降到 0.5pt 网格再逐级比较」而不是「差值小于容差就当相等」——
    /// 后者不满足严格弱序，Swift 的 `sort(by:)` 在调试配置下会直接崩
    /// （`Fatal error: Sort is not a valid strict weak ordering`）。
    /// 网格化之后就是一条确定的全序键链，不存在这个问题。
    private static func readingOrder(_ a: PDFTextLine, _ b: PDFTextLine) -> Bool {
        let ay = (a.bounds.midY * 2).rounded()
        let by = (b.bounds.midY * 2).rounded()
        if ay != by { return ay > by }                     // y 大者在上，先读
        if a.bounds.minX != b.bounds.minX { return a.bounds.minX < b.bounds.minX }
        if a.bounds.minY != b.bounds.minY { return a.bounds.minY > b.bounds.minY }
        return a.text < b.text                             // 兜底，保证全序
    }

    // MARK: - 页眉 / 页脚 / 元数据

    private static func dropFurniture(
        _ lines: [PDFTextLine],
        pageSize: CGSize?,
        options: Options,
        repeatedFingerprints: Set<String>
    ) -> [PDFTextLine] {
        guard let size = pageSize, size.height > 1, size.width > 1 else { return lines }
        let margin = size.height * options.furnitureMarginFactor

        // 先识别「元数据区块」：首行带期刊墙标的行（引用信息、DOI、ARTICLE HISTORY、
        // KEYWORDS、CONTACT、版权声明、导航链接等）。返回要剔除的行集合。
        // 与页眉页脚不同，这些区块常位于页面中部、行可能很宽，不能只靠贴边+短行判。
        let metadataIndices = detectMetadataBlockIndices(lines, pageSize: size)

        return lines.enumerated().compactMap { index, line -> PDFTextLine? in
            let box = line.bounds
            let nearTop = box.maxY >= size.height - margin
            let nearBottom = box.minY <= margin
            let atPageEdge = nearTop || nearBottom

            let fingerprint = furnitureFingerprint(line.text)
            if repeatedFingerprints.contains(fingerprint) { return nil }
            if metadataIndices.contains(index) { return nil }
            if line.text.trimmingCharacters(in: .whitespacesAndNewlines)
                .allSatisfy({ $0.isNumber || $0.isWhitespace }) { return nil }

            // 贴边 + 够短，才当页眉页脚。第二个条件不能省：
            // 正文里紧贴页顶的满行宽首行也是「贴边」，只按位置删会连正文一起删。
            if atPageEdge {
                return box.width >= size.width * options.furnitureWidthRatio ? line : nil
            }
            return line
        }
    }

    // MARK: 元数据区块检测

    /// 检测「期刊墙标区块」：首行带强标签、其后是内容行的紧凑文本块。
    ///
    /// 典型分布（实测 Selwyn 2025）：
    /// - 第 1 页（封面/引用页）：ISSN 行、To cite this article 引用块、Full Terms 行
    /// - 第 2 页（文章首页）：ARTICLE HISTORY / KEYWORDS（右栏窄块）、CONTACT、版权行
    ///
    /// 这些区块**首行**几乎总是以大写墙标开头（`ARTICLE HISTORY`、`KEYWORDS`、
    /// `CONTACT`、`To cite this article:`），正文段落里这些词通常出现在句中而不是
    /// 行首占位。所以强标签只匹配「该行**开头**」，避免把正文里提及 "keywords are…"、
    /// "our methods…" 的普通段落误删。
    private static func detectMetadataBlockIndices(
        _ lines: [PDFTextLine],
        pageSize: CGSize
    ) -> Set<Int> {
        var removed: Set<Int> = []
        // 显式类型标注，避免 Dictionary(grouping:) 的类型推断歧义
        let pageEntries: [(offset: Int, element: PDFTextLine)] = Array(lines.enumerated())
        let byPage = Dictionary(grouping: pageEntries, by: { $0.element.pageIndex })
        for (_, pageSorted) in byPage {
            let sorted = pageSorted.sorted { a, b in
                let ay = (a.element.bounds.midY * 2).rounded()
                let by = (b.element.bounds.midY * 2).rounded()
                return ay != by ? ay > by : a.element.bounds.minX < b.element.bounds.minX
            }
            var i = 0
            while i < sorted.count {
                // 找到以墙标开头的行；吞并范围并入 removed。
                // 主循环逐个推进（不用 Set 大小跳步——跨栏/非连续 offset 会让 Set.count
                // 与实际行数不一致，导致跳过未扫描的墙标起点）。
                if let span = metadataSpanStarting(at: i, in: sorted) {
                    removed.formUnion(span)
                }
                i += 1
            }
        }
        return removed
    }

    /// 从 `index` 起，若该行首以「强墙标」开头，则把该行起连续文本行一并标记剔除。
    /// 返回被标记的索引段；不是墙标则返回 nil。
    private static func metadataSpanStarting(
        at index: Int,
        in entries: [(offset: Int, element: PDFTextLine)]
    ) -> Set<Int>? {
        let head = entries[index].element
        let raw = head.text.trimmingCharacters(in: .whitespaces)
        // 大小写敏感匹配墙标 —— 期刊墙标是大写/标题式词，正文/夹具里的同词是小写。
        guard isConfidentMetadataLabel(raw) else { return nil }

        var removed = Set<Int>()

        // 标签行自身的处理分两种情况：
        // · 纯标签类墙标（ABSTRACT、RESEARCH/ORIGINAL/REVIEW ARTICLE）→ **只剔标签行**，
        //   其后的正文/摘要内容必须保留。摘要、正文标题是有阅读价值的内容，不能跟
        //   KEYWORDS 一样整块删。
        // · 其余墙标（KEYWORDS / CONTACT / ARTICLE HISTORY / 引用块 / 边栏）→ 整块删除。
        let lower = raw.lowercased()
        let isArticleTypeLabel = ["research article", "original article", "review article"]
            .contains { lower.hasPrefix($0) }
        let dropLineOnly = lower == "abstract" || lower == "abstract:"
            || isArticleTypeLabel
        if dropLineOnly {
            removed.insert(entries[index].offset)
            return removed
        }

        // 墙标块的内容行竖直上紧邻、水平上与墙标重叠。但**双栏布局会把另一栏的行夹在
        // 中间**（Sorted 按 y 网格，左右栏 y 交错），线性 `j += 1` 推两格就撞上错栏行、
        // 跨栏保护触发 break，本栏后续内容漏吞。因此这里**跳跃搜索**：在页内所有行里
        // 找「竖直紧邻且水平重叠」的下一行，允许跳过被另一栏插入的行。
        let colLeft = entries[index].element.bounds.minX
        let colRight = entries[index].element.bounds.maxX
        let colWidth = max(colRight - colLeft, 1)
        let refHeight = max(entries[index].element.bounds.height, 1)
        let wallMidY = entries[index].element.bounds.midY

        // 若墙标行自身带完整内容（不以冒号/纯标签结尾），只剔墙标行自己，
        // 不向后吞（避免吞掉下面的正文标题）。
        guard wallLabelEndsOpen(head.text) else {
            return [entries[index].offset]
        }

        // 候选：墙标行下方、水平重叠的行。entries 已带 offset，不能 enumerated()
        //（enumerated 会再包一层使 tuple 类型错乱）。按竖直紧邻（midY 大者先）排。
        let wallOffset = entries[index].offset
        let candidates = entries.filter { e in
            guard e.offset != wallOffset else { return false }
            let overlapX = min(colRight, e.element.bounds.maxX)
                - max(colLeft, e.element.bounds.minX)
            guard overlapX >= colWidth * 0.5 else { return false }
            return e.element.bounds.midY < wallMidY
        }.sorted { a, b in
            a.element.bounds.midY > b.element.bounds.midY
        }

        // 从墙标行正下方开始，沿竖直紧邻连续往下吞；遇墙标行、竖直跳变过大则停。
        removed.insert(wallOffset)
        var cursor = wallMidY
        for pick in candidates {
            let c = pick.element
            guard c.bounds.midY < cursor else { continue }
            // 下一个墙标行 → 停（交给主循环单独处理）
            if isConfidentMetadataLabel(c.text.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)) { break }
            // 竖直跳变过大（>2.5 倍行高）→ 进入下一个不相干块，停
            let yGap = cursor - c.bounds.midY
            if yGap > c.bounds.height * 2.5 || yGap > refHeight * 2.5 { break }
            removed.insert(pick.offset)
            cursor = c.bounds.midY
        }
        return removed
    }

    /// 墙标行是否「标签结束、内容在下一行」，从而允许向后吞并内容行。
    ///
    /// 三种情况算开放：
    /// 1. 以冒号/破折号结尾（内容在下一行）；
    /// 2. 整行就是一个纯墙标（如独占一行的 "ABSTRACT"）；
    /// 3. 属于「引用/链接块墙标」——这类墙标行自身往往带上引用内容而不以冒号结尾
    ///    （如 "To cite this article: Neil Selwyn, …, When the prompting stops…"），
    ///    **整块引用必须连标题一起剔除**，所以一旦命中就无脑向后吞。
    private static func wallLabelEndsOpen(_ text: String) -> Bool {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let last = t.last else { return true }
        if last == ":" || last == "—" || last == "–" { return true }
        // 引用/链接块墙标：命中即整块剔除（含其后的引用正文）
        let citationBlockLabels = [
            "to cite this article", "to link to this article", "full terms",
            "how to cite", "article views", "view related articles",
            "view crossmark", "citing articles", "view citing articles",
            "submit your article", "published online"
        ]
        let lower = t.lowercased()
        if citationBlockLabels.contains(where: { lower.hasPrefix($0) }) { return true }
        // 纯墙标（独占一行）
        let bareLabels = [
            "abstract", "article history", "keywords", "key words", "contact",
            "corresponding author", "license", "open access", "copyright",
            "introduction", "methods", "results", "discussion", "conclusion",
            "research article", "original article"
        ]
        return bareLabels.contains(lower)
    }

    /// 判断行首是否为「可信的期刊墙标」。**大小写敏感**：真实墙标是全大写或标题式大写，
    /// 而正文段落里提及这些词时是小写 —— 这两者必须分开，否则「abstract line one…」
    /// 这类普通正文会被误删（表驱动回归曾因此挂掉）。
    private static func isConfidentMetadataLabel(_ head: String) -> Bool {
        // 全大写的强墙标（期刊固定区块标题）
        let allCapsLabels = [
            "ABSTRACT", "ARTICLE HISTORY", "KEYWORDS", "CONTACT",
            "RESEARCH ARTICLE", "ORIGINAL ARTICLE", "REVIEW ARTICLE",
            "OPEN ACCESS", "LICENSE", "COPYRIGHT", "CITED BY",
            "ARTICLE INFO", "ASSOCIATE EDITOR", "HANDLING EDITOR",
            "PUBLISHED ONLINE", "RECEIVED", "ACCEPTED", "DOI",
            "HOW TO CITE", "SUBMIT YOUR ARTICLE"
        ]
        if allCapsLabels.contains(where: { head.hasPrefix($0) }) {
            return true
        }
        // 标题式大小写的引导短语（期刊封面/引用块固定文案）
        let titleCaseLabels = [
            "To cite this article", "Full Terms", "Journal homepage",
            "ISSN", "View related articles", "View Crossmark data",
            "View Crossmark", "Article views", "Citing articles",
            "View citing articles", "How to Cite", "This is an Open Access",
            "Corresponding Author", "Disclosure Statement", "Funding",
            "Notes on Contributors",
            "Published online", "Submit your article",
            "Volume", "Issue", "Article Metrics", "Skip to main content",
            "Received", "Accepted"
        ]
        if titleCaseLabels.contains(where: { head.hasPrefix($0) }) {
            return true
        }
        return false
    }

    /// 页眉页脚有时很宽，也可能离页边超过 5%。先在整本书的上下 12% 区域里找重复文本，
    /// 三页以上且至少两页重复才删除，避免把两页短文中相同的小标题误删。
    private static func repeatedFurnitureFingerprints(
        in lines: [PDFTextLine],
        pageSizes: [Int: CGSize]
    ) -> Set<String> {
        let pageCount = Set(lines.map(\.pageIndex)).count
        guard pageCount >= 3 else { return [] }
        var pagesByFingerprint: [String: Set<Int>] = [:]
        for line in lines {
            guard let size = pageSizes[line.pageIndex], size.height > 1 else { continue }
            let nearEdge = line.bounds.maxY >= size.height * 0.88 || line.bounds.minY <= size.height * 0.12
            guard nearEdge else { continue }
            let fingerprint = furnitureFingerprint(line.text)
            guard fingerprint.count >= 3 else { continue }
            pagesByFingerprint[fingerprint, default: []].insert(line.pageIndex)
        }
        return Set(pagesByFingerprint.compactMap { key, pages in pages.count >= 2 ? key : nil })
    }

    private static func furnitureFingerprint(_ text: String) -> String {
        text.lowercased().unicodeScalars.compactMap { scalar -> Character? in
            if CharacterSet.letters.contains(scalar) { return Character(String(scalar)) }
            return nil
        }.map(String.init).joined()
    }

    // MARK: - 聚类

    private static func cluster(_ lines: [PDFTextLine], options: Options) -> [PDFParagraph] {
        guard !lines.isEmpty else { return [] }

        // 正文右边界：取本页所有行右端的 90 分位而不是最大值。
        // 用最大值会被一条异常长行（比如超宽的表头）拉出去，导致所有正常行都被判成短行。
        let rightEdge = percentile(lines.map { $0.bounds.maxX }, 0.9)
        let bodyWidth = rightEdge - (lines.map { $0.bounds.minX }.min() ?? 0)

        var paragraphs: [PDFParagraph] = []
        var current: [PDFTextLine] = []
        var currentStartOrdinal = 0
        /// 本段（`current`）已见的最右端。每开新段要跟着重置。
        var blockRightEdge: CGFloat = 0

        func flush() {
            guard !current.isEmpty else { return }
            paragraphs.append(makeParagraph(current, startOrdinal: currentStartOrdinal, options: options))
            current.removeAll()
            blockRightEdge = 0
        }

        /// 当前块是否为窄栏：块右端显著小于页面正文右端。
        func isNarrowBlock() -> Bool {
            guard bodyWidth > 1, blockRightEdge > 1 else { return false }
            return blockRightEdge < rightEdge * options.narrowColumnWidthRatio
        }

        /// 当前适用的行距因子：窄栏用宽松因子，否则用正常因子。
        func currentGapFactor() -> CGFloat {
            isNarrowBlock() ? options.narrowColumnGapFactor : options.paragraphGapFactor
        }

        for (ordinal, line) in lines.enumerated() {
            guard let previous = current.last else {
                current = [line]
                currentStartOrdinal = ordinal
                blockRightEdge = line.bounds.maxX
                continue
            }

            let gap = previous.bounds.minY - line.bounds.maxY          // >0 表示两行之间有缝
            let referenceHeight = max(previous.bounds.height, line.bounds.height)
            let overlap = min(previous.bounds.maxX, line.bounds.maxX)
                        - max(previous.bounds.minX, line.bounds.minX)
            let narrower = min(previous.bounds.width, line.bounds.width)

            let gapTooLarge = gap > referenceHeight * currentGapFactor()
            let noOverlap = overlap < narrower * options.minimumHorizontalOverlapFactor
            // 短行判据要**两个参考宽度同时满足**才成立：
            //
            // · `endsShortOfPage`：这一行相对整页正文右边界短了吗 —— 抓的是普通段落末行。
            // · `endsShortOfBlock`：这一行相对**本段自己的**右边界短了吗 ——
            //   排除「整段本来就排在窄栏里」的情形。
            //
            // 为什么两个都要：只用整页右边界时，任何**自己就比正文窄**的段落
            // （典型是标题页的摘要、以及双栏页里某一栏的整段）会连中招 ——
            // 实测 Selwyn 2025 第 2 页的摘要 20 行只到 `x=337`、正文到 `445`，
            // 每行都被判成段末短行，一整段摘要碎成 20 个单行段。
            // 反过来只用段内右边界也不行：那些「段内最宽的那一行」永远不触发，
            // 用文字排出的表格（ID 列 11~26pt 宽、描述列 115~362pt 宽）会整片粘成一坨。
            // 两个都要求，才既能留住表格行、又不拆散窄栏整段。
            let endsShortOfPage = bodyWidth > 1
                && (rightEdge - previous.bounds.maxX) > bodyWidth * (1 - options.shortLineFactor)
            let endsShortOfBlock = blockRightEdge > 1
                && (blockRightEdge - previous.bounds.maxX) > blockRightEdge * (1 - options.shortLineFactor)
            let relativeWidth = bodyWidth > 1 ? previous.bounds.width / bodyWidth : 1
            let previousWasShort = endsShortOfPage && endsShortOfBlock
                && (endsSentence(previous.text) || relativeWidth < 0.55)

            if gapTooLarge || noOverlap || previousWasShort {
                flush()
                current = [line]
                currentStartOrdinal = ordinal
                blockRightEdge = line.bounds.maxX
            } else {
                current.append(line)
                blockRightEdge = max(blockRightEdge, line.bounds.maxX)
            }
        }
        flush()
        return paragraphs
    }

    // MARK: - 续段合并

    /// PDF 的换页不是语义边界。若上一块没有句末标点、下一块明显以小写词继续，
    /// 则在同页误切和跨页处都合回一个翻译单元；几何片段仍分别保留用于正文联动。
    private static func mergeContinuations(
        _ input: [PDFParagraph],
        pageSizes: [Int: CGSize],
        options: Options
    ) -> [PDFParagraph] {
        guard var current = input.first else { return [] }
        var result: [PDFParagraph] = []
        for next in input.dropFirst() {
            if shouldMerge(current, next, pageSizes: pageSizes, options: options) {
                current.text = join(current.text, next.text)
                current.lineCount += next.lineCount
                current.isShort = current.text.count < options.minimumBodyLength
                current.fragments.append(contentsOf: next.fragments)
            } else {
                result.append(current)
                current = next
            }
        }
        result.append(current)
        return result
    }

    private static func shouldMerge(
        _ previous: PDFParagraph,
        _ next: PDFParagraph,
        pageSizes: [Int: CGSize],
        options: Options
    ) -> Bool {
        let previousPage = previous.fragments.last?.pageIndex ?? previous.pageIndex
        let adjacentPage = next.pageIndex == previousPage || next.pageIndex == previousPage + 1
        guard adjacentPage, !endsSentence(previous.text), let first = next.text.first else { return false }

        let beginsAsContinuation = first.isLowercase
            || ",.;:)]}，。；：、）】》".contains(first)
        if next.pageIndex != previousPage {
            guard let previousSize = pageSizes[previousPage],
                  let nextSize = pageSizes[next.pageIndex],
                  previousSize.height > 1, nextSize.height > 1,
                  let previousFragment = previous.fragments.last,
                  let nextFragment = next.fragments.first
            else { return false }

            // 跨页续段必须同时触到上一页正文底部与下一页正文顶部。仅凭“没有句号”
            // 会把下一页标题并进正文；仅凭下一段小写开头也会误伤页顶图注。
            // 20% / 80% 留出常见页边距，但排除页面中部两个互不相干的文本块。
            let reachesBottom = previousFragment.bounds.minY <= previousSize.height * 0.20
            let startsAtTop = nextFragment.bounds.maxY >= nextSize.height * 0.80
            return reachesBottom && startsAtTop
                && (beginsAsContinuation || (!previous.isShort && next.lineCount > 1))
        }
        let trailing = previous.text.trimmingCharacters(in: .whitespacesAndNewlines).last
        let signalsContinuation = trailing.map { ",;:，；：—–-".contains($0) } ?? false
        guard beginsAsContinuation, signalsContinuation,
              let previousFragment = previous.fragments.last,
              let nextFragment = next.fragments.first
        else { return false }

        // 同页只修复“短末行判据”造成的误切。真实段间距与左右并排文本仍必须分开：
        // 前者由竖直间距挡住，后者由水平重叠挡住。
        let gap = previousFragment.bounds.minY - nextFragment.bounds.maxY
        let previousLineHeight = previousFragment.bounds.height / CGFloat(max(previous.lineCount, 1))
        let nextLineHeight = nextFragment.bounds.height / CGFloat(max(next.lineCount, 1))
        let referenceHeight = max(previousLineHeight, nextLineHeight)
        let overlap = min(previousFragment.bounds.maxX, nextFragment.bounds.maxX)
            - max(previousFragment.bounds.minX, nextFragment.bounds.minX)
        let narrower = min(previousFragment.bounds.width, nextFragment.bounds.width)

        // 自适应行距因子：若两段都在窄栏（右端显著小于页面右端），用宽松因子。
        // 需要页面尺寸来算 rightEdge；拿不到则退回正常因子。
        var gapFactor = options.paragraphGapFactor
        if let pageSize = pageSizes[previousPage], pageSize.width > 1 {
            let prevRight = previousFragment.bounds.maxX
            let nextRight = nextFragment.bounds.maxX
            let pageRightEdge = pageSize.width * 0.95 // 粗略估计
            let narrowThreshold = pageRightEdge * options.narrowColumnWidthRatio
            if prevRight < narrowThreshold && nextRight < narrowThreshold {
                gapFactor = options.narrowColumnGapFactor
            }
        }
        return gap <= referenceHeight * gapFactor
            && overlap >= narrower * options.minimumHorizontalOverlapFactor
    }

    private static func endsSentence(_ text: String) -> Bool {
        guard let last = text.trimmingCharacters(in: .whitespacesAndNewlines).last else { return true }
        // 分号与冒号通常仍在展开同一句、同一条列举，不能把它们当作翻译单元的
        // 结束；截图里的 “education; interoperability; / strong …” 正是因此被碎切。
        return ".!?。！？".contains(last)
    }

    private static func makeParagraph(
        _ lines: [PDFTextLine],
        startOrdinal: Int,
        options: Options
    ) -> PDFParagraph {
        let text = joinLines(lines.map(\.text))
        let bounds = lines.dropFirst().reduce(lines[0].bounds) { $0.union($1.bounds) }
        return PDFParagraph(
            pageIndex: lines[0].pageIndex,
            text: text,
            bounds: bounds,
            lineCount: lines.count,
            firstLineOrdinal: startOrdinal,
            isShort: text.count < options.minimumBodyLength
        )
    }

    // MARK: - 行拼接

    /// 把同一段内的多行接成一段文本。
    public static func joinLines(_ lines: [String]) -> String {
        var out = ""
        for raw in lines {
            let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty else { continue }
            out = out.isEmpty ? line : join(out, line)
        }
        return out
    }

    /// 接两行。三条规则按优先级走：
    ///
    /// 1. 上一行以 ASCII 连字符结尾、且再往前一个字符是字母 → 那是英文跨行断词，
    ///    去掉连字符直接拼（`inter-` + `national` → `international`）。
    ///    加空格会拼出 `inter- national`，那是错的。
    /// 2. 接缝两侧都是中日韩文字 → 直接拼，不加空格（中文换行不留空格，
    ///    加了会在正文里凭空多出一堆空隙）。
    /// 3. 其余情况加一个空格（拉丁字母之间、以及「中文 + 英文」的交界）。
    public static func join(_ head: String, _ tail: String) -> String {
        guard !head.isEmpty else { return tail }
        guard !tail.isEmpty else { return head }

        if let last = head.last, last == "-", head.count >= 2 {
            let before = head[head.index(head.endIndex, offsetBy: -2)]
            if before.isLetter, before.isASCII {
                return String(head.dropLast()) + tail
            }
        }

        if let left = head.last, let right = tail.first,
           isCJK(left.unicodeScalars.first), isCJK(right.unicodeScalars.first) {
            return head + tail
        }

        return head + " " + tail
    }

    /// 中日韩文字（含日文假名与全角标点）。用来决定拼接时要不要补空格。
    private static func isCJK(_ scalar: Unicode.Scalar?) -> Bool {
        guard let scalar else { return false }
        switch scalar.value {
        case 0x2E80...0x2EFF,     // CJK 部首补充
             0x3000...0x303F,     // CJK 标点（、。「」等）
             0x3040...0x30FF,     // 日文平假名 / 片假名
             0x3400...0x4DBF,     // CJK 扩展 A
             0x4E00...0x9FFF,     // CJK 基本区
             0xF900...0xFAFF,     // 兼容表意文字
             0xFF00...0xFFEF:     // 全角字符
            return true
        default:
            return false
        }
    }

    // MARK: - 小工具

    /// `values` 的 `p` 分位（`p` ∈ [0,1]）。空数组返回 0。
    /// 自写而不排序后取中位：分位要能取 0.9，中位数不够用。
    private static func percentile(_ values: [CGFloat], _ p: Double) -> CGFloat {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        let index = Int((Double(sorted.count - 1) * min(max(p, 0), 1)).rounded())
        return sorted[min(max(index, 0), sorted.count - 1)]
    }
}
