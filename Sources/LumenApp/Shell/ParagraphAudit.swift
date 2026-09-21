import Foundation
import PDFKit
import LumenKit

/// 段落抽取自检：`--paragraph-report 1`。
///
/// ## 这条通道为什么存在
///
/// PDF 里**没有「段落」这个概念** —— 文字层只给到行。逐段翻译的最小有意义单位却是段
/// （逐行翻会把句子切成几截、每截都缺主语，译文质量会明显崩）。所以「行 → 段」这一层
/// 全靠几何推断，而几何推断的每一处阈值都可能悄悄错掉：错得松了把两段并成一段，
/// 错得紧了把一段切成三截，**两种都只在译文里才看得出来**（译文读起来别扭，
/// 但你没法从译文反推是分段错了）。所以必须在这一层就把读数钉住。
///
/// ## 两类断言
///
/// **一、表驱动（合成行）**：聚类算法是纯几何 + 纯文本的，输入即规格。
/// 每条判据都配一条**反向对照**（只改一个变量，结果必须翻转）——
/// 没有反向对照的断言是恒真的：「段末短行触发换段」如果只测「短行 → 换段」，
/// 那么一个「无脑换段」的实现也能通过。
///
/// **二、真机（打开的文档）**：合成行证明不了「真实版面抽出来对不对」。
/// 第二组把打开的 PDF 抽一遍，报段数、行数分布、**被剔除的行数**（页眉页脚误杀的
/// 直接读数）、以及前后若干段的原文，供人工核对边界。
///
/// ## 诚实边界
///
/// - **多栏版面验不了**：本机拿不到可验证的双栏样本（把用户库里的文档渲染成位图、
///   按列统计墨迹密度，中央剖面均匀、无栏沟 —— 全是单栏）。而 PDFKit 两个原语都不做
///   分栏（见 `PDFLineExtractor` 的注释），所以多栏文档会把左右栏的行混进同一段。
///   这一点如实写在 `docs/VERIFY.md`，不发明一个验不了的栏检测器。
/// - **本通道证明不了「译文读起来对不对」** —— 它只管分段边界。
/// - **它不联网、不写盘、不碰用户的 PDF**（只 `PDFDocument(url:)` 只读打开）。
@MainActor
enum ParagraphAudit {

    /// 页面尺寸用在这个量级。合成用例不需要跟真实文档一致，
    /// 只要「行宽 / 行距 / 页高」三者的**比例**与真实论文同量级即可。
    private static let pageSize = CGSize(width: 600, height: 800)
    private static let bodyLeft: CGFloat = 72
    private static let bodyRight: CGFloat = 528          // 正文宽 456
    private static let bodyWidth = bodyRight - bodyLeft
    private static let lineHeight: CGFloat = 12

    static func run(documentPath: String?) async {
        var passed = 0
        var failures: [String] = []
        func check(_ name: String, _ ok: Bool, _ detail: String = "") {
            if ok { passed += 1 } else { failures.append(name) }
            // 通过时不打 detail：那些数字每条目上面已单独打过一行，
            // 通过时再附一句「（本该如此）」会被误读成失败。
            NSLog("[Lumen][paragraph] \(ok ? "✅" : "❌") \(name)"
                  + (ok || detail.isEmpty ? "" : " —— \(detail)"))
        }
        func report(_ text: String) {
            NSLog("[Lumen][paragraph] \(text)")
        }

        report("=== 一、表驱动：行 → 段 ===")

        assertParagraphBreakByGap(check: check, report: report)
        assertParagraphBreakByShortLine(check: check, report: report)
        assertNarrowBlockNotSplit(check: check, report: report)
        assertNarrowRunDetector(check: check, report: report)
        assertFurniture(check: check, report: report)
        assertRepeatedFurniture(check: check, report: report)
        assertReadingOrder(check: check, report: report)
        assertNoCrossPageMerge(check: check, report: report)
        assertContinuationMerging(check: check, report: report)
        assertLineJoining(check: check, report: report)
        assertParagraphMetadata(check: check, report: report)
        assertDegenerateInputs(check: check, report: report)

        let chinese = PDFParagraph(pageIndex: 0,
                                   text: "这是一段用于验证语言判定的中文段落，它应该被稳定识别。",
                                   bounds: CGRect(x: 72, y: 300, width: 456, height: 48),
                                   lineCount: 2, firstLineOrdinal: 0, isShort: false)
        let english = PDFParagraph(pageIndex: 0,
                                   text: "This paragraph should remain eligible for translation into Chinese.",
                                   bounds: CGRect(x: 72, y: 220, width: 456, height: 48),
                                   lineCount: 2, firstLineOrdinal: 2, isShort: false)
        check("翻译语言：中文原文译为中文时跳过",
              TranslationEligibility.skipReason(for: chinese, target: "zh-Hans") != nil)
        check("翻译语言：英文原文译为中文时保留在队列",
              TranslationEligibility.skipReason(for: english, target: "zh-Hans") == nil)
        let longText = String(repeating: "A complete sentence. ", count: 120)
        let chunks = TranslationTextSplitter.split(longText, limit: 180)
        check("翻译分块：长段在句末分块且不丢内容",
              chunks.count > 1
                && chunks.allSatisfy { $0.count <= 180 }
                && chunks.joined() == longText.trimmingCharacters(in: .whitespacesAndNewlines))

        report("=== 二、真机：打开的文档 ===")
        await assertRealDocument(path: documentPath, check: check, report: report)

        NSLog("[Lumen][paragraph] 自检：通过 \(passed) 项，失败 \(failures.count) 项"
              + (failures.isEmpty ? " ✅" : " ❌ " + failures.joined(separator: "；")))
    }

    // MARK: - 换段判据一：竖直间距

    /// 同段三行（行距均匀且小）→ 1 段；把**只看这一件事**的第三行拉远 → 2 段。
    ///
    /// 反向对照是「只把第三行的 y 改一次」：两个用例除这一个变量外完全相同，
    /// 所以「1 段 ↔ 2 段」的翻转只能归因于行距判据。
    private static func assertParagraphBreakByGap(
        check: (String, Bool, String) -> Void,
        report: (String) -> Void
    ) {
        let tight = linesOnPage(0, [
            ("a full width line of body text", CGRect(x: bodyLeft, y: 400, width: bodyWidth, height: lineHeight)),
            ("another full width line here", CGRect(x: bodyLeft, y: 384, width: bodyWidth, height: lineHeight)),
            ("a third full width line too", CGRect(x: bodyLeft, y: 368, width: bodyWidth, height: lineHeight))
        ])
        // 同样的三行，只把第三行下移 24pt（行距 4 → 28）
        let loose = linesOnPage(0, [
            ("a full width line of body text", CGRect(x: bodyLeft, y: 400, width: bodyWidth, height: lineHeight)),
            ("another full width line here", CGRect(x: bodyLeft, y: 384, width: bodyWidth, height: lineHeight)),
            ("a third full width line too", CGRect(x: bodyLeft, y: 344, width: bodyWidth, height: lineHeight))
        ])

        let tightParas = PDFParagraphExtractor.paragraphs(from: tight, pageSizes: [0: pageSize])
        let looseParas = PDFParagraphExtractor.paragraphs(from: loose, pageSizes: [0: pageSize])
        report("行距判据：紧凑三行 → \(tightParas.count) 段；第三行拉远 24pt → \(looseParas.count) 段")

        check("行距判据：紧凑三行并成 1 段", tightParas.count == 1,
              "得到 \(tightParas.count) 段")
        check("行距判据：行距拉大后裂成 2 段", looseParas.count == 2,
              "得到 \(looseParas.count) 段")
        check("行距判据：并成 1 段时段内确实有 3 行",
              tightParas.first?.lineCount == 3,
              "行数 = \(tightParas.first?.lineCount ?? -1)")
    }

    // MARK: - 换段判据二：段末短行

    /// 行距**完全均匀**时，只靠「上一行是否短于正文右边界」换段。
    ///
    /// 反向对照：同一组数据里把那个短行改成满行宽 —— 2 段必须变回 1 段。
    /// 这条对照是关键：只测「短行 → 换段」的话，一个无脑换段的实现也会通过。
    private static func assertParagraphBreakByShortLine(
        check: (String, Bool, String) -> Void,
        report: (String) -> Void
    ) {
        // 行距一律 4pt（远小于 0.62 行高），所以唯一的换段信号就是短行
        let withShort = linesOnPage(0, [
            ("first full width line", CGRect(x: bodyLeft, y: 400, width: bodyWidth, height: lineHeight)),
            ("second full width line", CGRect(x: bodyLeft, y: 384, width: bodyWidth, height: lineHeight)),
            // 这一段只剩几个字 → 段末短行
            ("short tail", CGRect(x: bodyLeft, y: 368, width: 120, height: lineHeight)),
            ("next paragraph first line", CGRect(x: bodyLeft, y: 352, width: bodyWidth, height: lineHeight))
        ])
        // 反向对照：只把第三行改满行宽
        let withoutShort = linesOnPage(0, [
            ("first full width line", CGRect(x: bodyLeft, y: 400, width: bodyWidth, height: lineHeight)),
            ("second full width line", CGRect(x: bodyLeft, y: 384, width: bodyWidth, height: lineHeight)),
            ("third full width line", CGRect(x: bodyLeft, y: 368, width: bodyWidth, height: lineHeight)),
            ("next paragraph first line", CGRect(x: bodyLeft, y: 352, width: bodyWidth, height: lineHeight))
        ])

        let shipped = PDFParagraphExtractor.paragraphs(from: withShort, pageSizes: [0: pageSize])
        let control = PDFParagraphExtractor.paragraphs(from: withoutShort, pageSizes: [0: pageSize])
        report("短行判据：末行只剩 120pt 宽（正文宽 \(Int(bodyWidth))pt）→ \(shipped.count) 段；"
               + "把那一行改满行宽 → \(control.count) 段")

        check("短行判据：段末短行处断开（2 段）", shipped.count == 2,
              "得到 \(shipped.count) 段")
        check("短行判据·反向对照：那一行改满行宽后并回 1 段", control.count == 1,
              "得到 \(control.count) 段 —— 若这里不是 1，说明上面那条断言并非由短行判据驱动")
    }

    // MARK: - 换段判据三：窄栏整块不许被拆碎

    /// 「整段本来就排在比正文窄的栏里」时，不许逐行拆散。
    ///
    /// 这是修掉的一个**真 bug**：Selwyn 2025 第 2 页的摘要排在 `x=[59,337]`
    /// （正文到 `445`），而短行判据原先只看「离**整页**右边界够不够远」，
    /// 于是摘要 20 行的**每一行**都被判成段末短行，一整段碎成 20 个单行段。
    /// 修法是加第二个条件：**同时**短于本段自己的右边界才算短行
    /// （见 `PDFParagraphExtractor` 里 `endsShortOfPage` / `endsShortOfBlock`）。
    ///
    /// ⚠️ **夹具必须让两个条件分道扬镳**，否则这组断言在修复前也是绿的、没有鉴别力。
    /// 所以页面上同时放一条满行宽正文行（把整页右边界拉到 528），窄栏块才 240 宽；
    /// 只放窄栏块是测不出问题的 —— 那样整页右边界本身就是 312，旧实现也不会拆。
    /// 这条「夹具有效性」本身也做成断言（最后一条）。
    private static func assertNarrowBlockNotSplit(
        check: (String, Bool, String) -> Void,
        report: (String) -> Void
    ) {
        let wide = ("a full width body line, page right edge comes from here",
                    CGRect(x: bodyLeft, y: 700, width: bodyWidth, height: lineHeight))
        let narrowWidth: CGFloat = 240
        let narrow: [(String, CGRect)] = [
            ("abstract line one still going", CGRect(x: bodyLeft, y: 600, width: narrowWidth, height: lineHeight)),
            ("abstract line two still going", CGRect(x: bodyLeft, y: 584, width: narrowWidth, height: lineHeight)),
            ("abstract line three ends here", CGRect(x: bodyLeft, y: 568, width: narrowWidth, height: lineHeight))
        ]

        let intact = PDFParagraphExtractor.paragraphs(
            from: linesOnPage(0, [wide] + narrow), pageSizes: [0: pageSize])

        // 反向对照：窄栏块**内部真的出现一个短行**时必须照断 ——
        // 否则「窄栏一律不拆」这种更糟的实现也能让上面那条通过。
        let withInternalShortLine = PDFParagraphExtractor.paragraphs(
            from: linesOnPage(0, [
                wide,
                narrow[0],
                narrow[1],
                ("short", CGRect(x: bodyLeft, y: 568, width: 100, height: lineHeight)),
                ("abstract line four", CGRect(x: bodyLeft, y: 552, width: narrowWidth, height: lineHeight))
            ]), pageSizes: [0: pageSize])

        let options = PDFParagraphExtractor.Options()
        // 夹具自证：这一串确实满足「旧的唯一条件」（离整页右边界 > 正文宽 × 20%）。
        let fixtureHasDiscriminatingPower =
            (bodyWidth - narrowWidth) > bodyWidth * (1 - options.shortLineFactor)
        let narrowBlock = intact.first { $0.bounds.width < bodyWidth * 0.8 }

        report("窄栏：满行宽正文 + \(Int(narrowWidth))pt 宽的三行块（正文宽 \(Int(bodyWidth))pt）"
               + " → \(intact.count) 段，其中窄块 \(narrowBlock?.lineCount ?? -1) 行；"
               + "窄块内插一行 100pt 短行 → \(withInternalShortLine.count) 段")

        check("窄栏：满行宽正文旁的窄栏整块并成 1 段（连同行共 2 段）", intact.count == 2,
              "得到 \(intact.count) 段")
        check("窄栏：那一块是 3 行（没有被逐行拆碎）", narrowBlock?.lineCount == 3,
              "得到 \(narrowBlock?.lineCount ?? -1) 行")
        check("窄栏·反向对照：块内出现真短行时仍然断开（3 段）",
              withInternalShortLine.count == 3,
              "得到 \(withInternalShortLine.count) 段 —— 若不是 3，说明窄块被无条件保护了")
        check("窄栏·反向对照：断裂后新段只含 1 行",
              withInternalShortLine.last?.lineCount == 1,
              "得到 \(withInternalShortLine.last?.lineCount ?? -1) 行")
        check("窄栏·夹具自证：该夹具确实满足旧的单条件判据（否则本组无鉴别力）",
              fixtureHasDiscriminatingPower,
              "窄块右端离整页右边界 \(Int(bodyWidth - narrowWidth))pt ≤ 阈值 \(Int(bodyWidth * (1 - options.shortLineFactor)))pt")
    }

    // MARK: - 「窄栏被逐行拆碎」的指纹检测器

    private struct NarrowRun: Equatable {
        var pageIndex: Int
        var lineCount: Int
        var rightEdge: CGFloat
    }

    /// 在抽取结果里找「窄栏整段被逐行拆碎」的指纹。三件事同时成立才算：
    ///
    /// 1. 同一页上**连续 ≥ `minimumRun` 个单行段**；
    /// 2. 这串的右端几乎对齐（互差 ≤ `tolerance`，默认 3pt）；
    /// 3. 这串离**整页正文右边界**还差得远（> 正文宽 × (1 - shortLineFactor)）。
    ///
    /// 第 3 条不能省：参考文献列表也会连续多行各自成段，但那些行右端**参差**
    /// （第 2 条挡掉），而且通常顶得比窄栏更靠右。剩下的形状就是「一块窄栏被按行切碎」。
    /// 真机上它必须为**空**；检测器本身另有一条人工坏数据的断言证明它是活的
    /// （见 `assertNarrowRunDetector`）。
    private static func narrowRuns(
        in paragraphs: [PDFParagraph],
        pageBodyEdges: [Int: (right: CGFloat, left: CGFloat)],
        options: PDFParagraphExtractor.Options,
        tolerance: CGFloat = 3,
        minimumRun: Int = 3
    ) -> [NarrowRun] {
        var runs: [NarrowRun] = []
        var index = 0
        while index < paragraphs.count {
            let start = paragraphs[index]
            guard start.lineCount == 1 else { index += 1; continue }
            var end = index
            while end + 1 < paragraphs.count {
                let next = paragraphs[end + 1]
                guard next.pageIndex == start.pageIndex,
                      next.lineCount == 1,
                      abs(next.bounds.maxX - start.bounds.maxX) <= tolerance
                else { break }
                end += 1
            }
            if end - index + 1 >= minimumRun, let edges = pageBodyEdges[start.pageIndex] {
                let bodyWidth = edges.right - edges.left
                let farFromPageEdge = bodyWidth > 1
                    && (edges.right - start.bounds.maxX) > bodyWidth * (1 - options.shortLineFactor)
                if farFromPageEdge {
                    runs.append(NarrowRun(pageIndex: start.pageIndex,
                                          lineCount: end - index + 1,
                                          rightEdge: start.bounds.maxX))
                }
            }
            index = end + 1
        }
        return runs
    }

    /// 检测器自己也得能被证伪 —— 否则真机上「0 处」可能只是它从来不报警。
    ///
    /// 三条：人工坏数据必须报警；右端参差必须不报警；连续段数不足 3 必须不报警。
    /// 第三条的阈值不是随手定的：用户那份 Selwyn 2025 的摘要**正是**被切成
    /// 20 个右端对齐在 `x=337` 的单行段，`minimumRun = 3` 远低于 20。
    private static func assertNarrowRunDetector(
        check: (String, Bool, String) -> Void,
        report: (String) -> Void
    ) {
        // 复刻坏数据：4 个单行段、右端全在 337（Selwyn 摘要的形状）
        let broken = (0..<4).map { i in
            PDFParagraph(pageIndex: 0, text: "abstract line \(i)",
                         bounds: CGRect(x: 59, y: 300 - CGFloat(i) * 14, width: 278, height: lineHeight),
                         lineCount: 1, firstLineOrdinal: i, isShort: false)
        }
        // 反向对照一：同样 4 段，但右端参差（参考文献的形状）→ 不许报警
        let ragged = (0..<4).map { i in
            PDFParagraph(pageIndex: 0, text: "reference entry \(i)",
                         bounds: CGRect(x: 72, y: 300 - CGFloat(i) * 14,
                                        width: 200 + CGFloat(i) * 40, height: lineHeight),
                         lineCount: 1, firstLineOrdinal: i, isShort: false)
        }
        // 反向对照二：只有 2 个连续单行段 → 不许报警
        let tooShort = Array(broken.prefix(2))

        let options = PDFParagraphExtractor.Options()
        let edges: [Int: (right: CGFloat, left: CGFloat)] = [0: (right: 445, left: 48)]
        let brokenRuns = narrowRuns(in: broken, pageBodyEdges: edges, options: options)
        let raggedRuns = narrowRuns(in: ragged, pageBodyEdges: edges, options: options)
        let shortRuns = narrowRuns(in: tooShort, pageBodyEdges: edges, options: options)

        report("指纹检测器：4 个右端对齐在 337pt 的单行段 → \(brokenRuns.count) 处报警；"
               + "4 个右端参差的段 → \(raggedRuns.count) 处；"
               + "只有 2 个连续单行段 → \(shortRuns.count) 处")

        check("指纹检测器：对「窄栏被拆碎」的坏数据报警", brokenRuns.count == 1,
              "得到 \(brokenRuns.count) 处")
        check("指纹检测器·反向对照：右端参差时不报警（参考文献形状）", raggedRuns.isEmpty,
              "得到 \(raggedRuns.count) 处")
        check("指纹检测器·反向对照：连续段数不足 3 时不报警（阈值真的在起作用）",
              shortRuns.isEmpty, "得到 \(shortRuns.count) 处")
    }

    // MARK: - 页眉 / 页脚

    /// 两个条件都要满足才剔除（贴边 **且** 够短）；拿不到页尺寸就**不猜**。
    ///
    /// 三条断言互为对照：
    /// - 贴边 + 短 → 剔除（这是功能本身）
    /// - 贴边 + 满行宽 → **保留**（防「只按位置删」把正文首行一起删）
    /// - 不传页尺寸 → 贴边短行也**保留**（防「拿一个猜的页高去删正文」）
    private static func assertFurniture(
        check: (String, Bool, String) -> Void,
        report: (String) -> Void
    ) {
        let headerY = pageSize.height - 30          // 贴顶（margin = 800 × 0.055 = 44）
        let footerY: CGFloat = 20                   // 贴底

        let fixture = linesOnPage(0, [
            ("Journal of Something Vol 12", CGRect(x: 220, y: headerY, width: 160, height: 10)),
            ("body first line", CGRect(x: bodyLeft, y: 400, width: bodyWidth, height: lineHeight)),
            ("body second line", CGRect(x: bodyLeft, y: 384, width: bodyWidth, height: lineHeight)),
            ("page 42", CGRect(x: 280, y: footerY, width: 40, height: 10))
        ])
        // 反向对照：页眉位置的文字是**满行宽**
        let wideHeader = linesOnPage(0, [
            ("a full width first line of body text", CGRect(x: bodyLeft, y: headerY, width: bodyWidth, height: 10)),
            ("body second line", CGRect(x: bodyLeft, y: 400, width: bodyWidth, height: lineHeight)),
            ("body third line", CGRect(x: bodyLeft, y: 384, width: bodyWidth, height: lineHeight))
        ])

        let withSizes = PDFParagraphExtractor.paragraphs(from: fixture, pageSizes: [0: pageSize])
        let withoutSizes = PDFParagraphExtractor.paragraphs(from: fixture)
        let control = PDFParagraphExtractor.paragraphs(from: wideHeader, pageSizes: [0: pageSize])

        let keptLines = withSizes.reduce(0) { $0 + $1.lineCount }
        let keptWithoutSizes = withoutSizes.reduce(0) { $0 + $1.lineCount }
        let controlLines = control.reduce(0) { $0 + $1.lineCount }
        report("页眉页脚：4 行（2 正文 + 页眉 + 页脚）→ 有页尺寸时留下 \(keptLines) 行；"
               + "不传页尺寸时留下 \(keptWithoutSizes) 行；满行宽的贴顶行留下 \(controlLines) 行")

        check("页眉页脚：贴边且短的两行被剔除（只留 2 行正文）", keptLines == 2,
              "留下 \(keptLines) 行")
        check("页眉页脚：不传页尺寸时一行都不删（不猜）", keptWithoutSizes == 4,
              "留下 \(keptWithoutSizes) 行")
        check("页眉页脚·反向对照：贴顶但满行宽的行必须保留",
              controlLines == 3,
              "留下 \(controlLines) 行 —— 若这里不是 3，说明剔除是「只按位置」而不是「贴边且短」")
    }

    /// 宽页眉不能只靠“短于页面 62%”识别；连续页面重复出现才是更可靠的证据。
    private static func assertRepeatedFurniture(
        check: (String, Bool, String) -> Void,
        report: (String) -> Void
    ) {
        var fixture: [PDFTextLine] = []
        for page in 0..<3 {
            fixture += linesOnPage(page, [
                ("Journal of Education — \(page + 1)",
                 CGRect(x: bodyLeft, y: 744, width: bodyWidth, height: lineHeight)),
                ("A complete body sentence on page \(page + 1).",
                 CGRect(x: bodyLeft, y: 410, width: bodyWidth, height: lineHeight))
            ])
        }
        let sizes = Dictionary(uniqueKeysWithValues: (0..<3).map { ($0, pageSize) })
        let paragraphs = PDFParagraphExtractor.paragraphs(from: fixture, pageSizes: sizes)
        let text = paragraphs.map(\.text).joined(separator: " ")
        report("重复页眉：3 页相同宽页眉 + 3 行正文 → \(paragraphs.count) 段")
        check("重复页眉：带变化页码的宽页眉被指纹识别并剔除",
              paragraphs.count == 3 && !text.contains("Journal"),
              "结果：\(text)")
        check("重复页眉·反向对照：正文全部保留",
              (1...3).allSatisfy { text.contains("page \($0)") },
              "结果：\(text)")
    }

    // MARK: - 阅读顺序

    /// 乱序输入 → 输出按阅读顺序（自上而下；同一水平带内自左向右）。
    ///
    /// 断言打在**几何位置**上而不是 `firstLineOrdinal` ——
    /// 后者是「按排序后的下标」填的，无论怎么排都递增，拿它断言恒真。
    private static func assertReadingOrder(
        check: (String, Bool, String) -> Void,
        report: (String) -> Void
    ) {
        // 故意打乱传入顺序
        let scrambled = linesOnPage(0, [
            ("left block at same height", CGRect(x: bodyLeft, y: 300, width: 120, height: lineHeight)),
            ("top paragraph", CGRect(x: bodyLeft, y: 600, width: bodyWidth, height: lineHeight)),
            ("bottom paragraph", CGRect(x: bodyLeft, y: 160, width: bodyWidth, height: lineHeight)),
            ("right block at same height", CGRect(x: 340, y: 300, width: 188, height: lineHeight))
        ])
        let paras = PDFParagraphExtractor.paragraphs(from: scrambled, pageSizes: [0: pageSize])
        report("阅读顺序：4 行乱序输入 → \(paras.count) 段，"
               + paras.map { "y=\(Int($0.bounds.maxY))x=\(Int($0.bounds.minX))" }.joined(separator: " → "))

        // 自上而下：连续的段，上边界必须单调不增
        var descending = true
        for i in 1..<max(paras.count, 1) where paras[i].bounds.maxY > paras[i - 1].bounds.maxY + 0.5 {
            descending = false
        }
        check("阅读顺序：段自上而下排列", descending,
              paras.map { String(format: "%.0f", $0.bounds.maxY) }.joined(separator: " > "))

        // 同一水平带左右两块应分成两段，且左在前
        let band = paras.filter { $0.bounds.minY < 312 && $0.bounds.maxY > 300 }
        let leftFirst = band.count == 2 && band[0].bounds.minX < band[1].bounds.minX
        check("阅读顺序：同一水平带左右两块分成两段且左在前", leftFirst,
              band.map { "x=\(Int($0.bounds.minX))" }.joined(separator: " / "))

        // 竖直位置排在最前的段必须是最上面那一段（文本可核对）
        let topIsFirst = paras.first?.text.contains("top paragraph") == true
        check("阅读顺序：最上面那段排在最前", topIsFirst,
              "首段文本 = 「\(paras.first?.text.prefix(28) ?? "")」")
    }

    // MARK: - 跨页

    /// 页面中部的两块文本不能因为页码相邻就误并；真正触及页底 / 页顶的续段另测。
    private static func assertNoCrossPageMerge(
        check: (String, Bool, String) -> Void,
        report: (String) -> Void
    ) {
        // 两页各一行，位置**完全相同**（几何上最容易被误并的情况）
        let fixture = [
            PDFTextLine(pageIndex: 0, text: "tail of page one", bounds: CGRect(x: bodyLeft, y: 200, width: bodyWidth, height: lineHeight)),
            PDFTextLine(pageIndex: 1, text: "head of page two", bounds: CGRect(x: bodyLeft, y: 200, width: bodyWidth, height: lineHeight))
        ]
        let paras = PDFParagraphExtractor.paragraphs(from: fixture, pageSizes: [0: pageSize, 1: pageSize])
        report("跨页：两页各一行、几何位置相同 → \(paras.count) 段，页号 "
               + paras.map { String($0.pageIndex) }.joined(separator: ","))

        check("跨页：不会跨页并成一段", paras.count == 2, "得到 \(paras.count) 段")
        check("跨页：两段的页号分别是 0 / 1", paras.map(\.pageIndex) == [0, 1],
              "得到 \(paras.map(\.pageIndex))")
    }

    /// 同页的排版误切与真正跨页的连续句都应恢复成一个翻译单元；句号和页面几何
    /// 各配一个反向对照，防止演变成“把相邻内容无脑粘起来”。
    private static func assertContinuationMerging(
        check: (String, Bool, String) -> Void,
        report: (String) -> Void
    ) {
        let samePage = linesOnPage(0, [
            ("environments in primary schools in The Netherlands are traditionally;",
             CGRect(x: bodyLeft, y: 500, width: 220, height: lineHeight)),
            ("education; interoperability;",
             CGRect(x: bodyLeft, y: 484, width: 180, height: lineHeight)),
            ("strong public-school systems, where platformization has substantially",
             CGRect(x: bodyLeft, y: 468, width: bodyWidth, height: lineHeight))
        ])
        let same = PDFParagraphExtractor.paragraphs(from: samePage, pageSizes: [0: pageSize])

        let crossing = [
            PDFTextLine(pageIndex: 0, text: "The argument continues without a final",
                        bounds: CGRect(x: bodyLeft, y: 70, width: bodyWidth, height: lineHeight)),
            PDFTextLine(pageIndex: 1, text: "punctuation mark on the following page",
                        bounds: CGRect(x: bodyLeft, y: 724, width: bodyWidth, height: lineHeight)),
            PDFTextLine(pageIndex: 1, text: "and remains one coherent paragraph.",
                        bounds: CGRect(x: bodyLeft, y: 708, width: bodyWidth, height: lineHeight))
        ]
        let crossed = PDFParagraphExtractor.paragraphs(
            from: crossing, pageSizes: [0: pageSize, 1: pageSize]
        )

        var terminal = crossing
        terminal[0].text += "."
        let terminalResult = PDFParagraphExtractor.paragraphs(
            from: terminal, pageSizes: [0: pageSize, 1: pageSize]
        )

        report("续段：同页截图形状 → \(same.count) 段；页底接页顶 → \(crossed.count) 段 / \(crossed.first?.fragments.count ?? 0) 片；句号对照 → \(terminalResult.count) 段")
        check("续段：分号后的同页小写内容合回同一翻译单元",
              same.count == 1 && same.first?.lineCount == 3,
              "得到 \(same.count) 段")
        check("续段：页底与下一页页顶的连续句跨页合并",
              crossed.count == 1 && crossed.first?.pageIndices == [0, 1],
              "得到 \(crossed.count) 段，页码 \(crossed.first?.pageIndices ?? [])")
        check("续段：跨页段保留两页几何片段供正文联动",
              crossed.first?.fragments.count == 2,
              "得到 \(crossed.first?.fragments.count ?? 0) 个片段")
        check("续段·反向对照：上一页以句号结束时不跨页合并",
              terminalResult.count == 2,
              "得到 \(terminalResult.count) 段")
    }

    // MARK: - 行拼接

    /// 三条拼接规则各一条断言 + 一条反向对照（英文断词的反向是「不该去掉的连字符」）。
    private static func assertLineJoining(
        check: (String, Bool, String) -> Void,
        report: (String) -> Void
    ) {
        let hyphen = PDFParagraphExtractor.join("inter-", "national")
        let cjk = PDFParagraphExtractor.join("这是一段中文", "继续写下去")
        let latin = PDFParagraphExtractor.join("hello", "world")
        // 反向对照：连字符前不是 ASCII 字母时，它不是英文断词，不该被吃掉
        let dashNotBreak = PDFParagraphExtractor.join("2019-", "2020")
        report("拼接：「inter-」+「national」→「\(hyphen)」；"
               + "「2019-」+「2020」→「\(dashNotBreak)」；"
               + "中文接中文 →「\(cjk)」；英文接英文 →「\(latin)」")

        check("拼接：英文跨行断词去掉连字符", hyphen == "international", "得到「\(hyphen)」")
        check("拼接·反向对照：数字后的连字符不被吃掉", dashNotBreak == "2019- 2020",
              "得到「\(dashNotBreak)」")
        check("拼接：中日韩文字之间不插空格", cjk == "这是一段中文继续写下去", "得到「\(cjk)」")
        check("拼接：拉丁字母之间插一个空格", latin == "hello world", "得到「\(latin)」")
    }

    // MARK: - 段落元数据

    private static func assertParagraphMetadata(
        check: (String, Bool, String) -> Void,
        report: (String) -> Void
    ) {
        let long = "a full width text line long enough to exceed the short-paragraph threshold"
        let fixture = linesOnPage(0, [
            (long, CGRect(x: bodyLeft, y: 400, width: bodyWidth, height: lineHeight)),
            ("tiny", CGRect(x: bodyLeft, y: 200, width: bodyWidth, height: lineHeight))
        ])
        let paras = PDFParagraphExtractor.paragraphs(from: fixture, pageSizes: [0: pageSize])
        report("元数据：长段 isShort=\(paras.first?.isShort.description ?? "-")、"
               + "短段 isShort=\(paras.last?.isShort.description ?? "-")；"
               + "长段字符数 \(paras.first?.text.count ?? -1)")

        check("元数据：字符数够多的段标 isShort=false",
              paras.first?.isShort == false, "得到 \(String(describing: paras.first?.isShort))")
        check("元数据：字符数不足的段标 isShort=true（不丢弃，只打标）",
              paras.last?.isShort == true, "得到 \(String(describing: paras.last?.isShort))")
        check("元数据：短段没有被丢掉", paras.count == 2, "得到 \(paras.count) 段")

        // id 稳定性：同一输入抽两次，id 必须一致（它要当译文缓存的键）
        let again = PDFParagraphExtractor.paragraphs(from: fixture, pageSizes: [0: pageSize])
        check("元数据：同输入两次抽取的 id 完全一致",
              paras.map(\.id) == again.map(\.id),
              "\(paras.map(\.id)) vs \(again.map(\.id))")
        // id 可区分：位置不同必须不同 id
        check("元数据：位置不同的段 id 不同",
              Set(paras.map(\.id)).count == paras.count,
              "\(paras.map(\.id))")
    }

    // MARK: - 退化输入

    private static func assertDegenerateInputs(
        check: (String, Bool, String) -> Void,
        report: (String) -> Void
    ) {
        let empty = PDFParagraphExtractor.paragraphs(from: [])
        let blank = linesOnPage(0, [
            ("   ", CGRect(x: bodyLeft, y: 400, width: bodyWidth, height: lineHeight)),
            ("real line", CGRect(x: bodyLeft, y: 384, width: bodyWidth, height: lineHeight)),
            ("zero area", CGRect(x: bodyLeft, y: 368, width: 0, height: 0))
        ])
        let blankParas = PDFParagraphExtractor.paragraphs(from: blank, pageSizes: [0: pageSize])
        let kept = blankParas.reduce(0) { $0 + $1.lineCount }
        report("退化输入：空数组 → \(empty.count) 段；含空白行与零面积行的 3 行 → 留下 \(kept) 行")

        check("退化输入：空数组返回空（不崩）", empty.isEmpty, "得到 \(empty.count) 段")
        check("退化输入：空白行与零面积行被剔掉，只留 1 行", kept == 1, "留下 \(kept) 行")
    }

    // MARK: - 真机

    /// 在**打开的这份文档**上抽一遍。
    ///
    /// 这一组的价值在「真机读数」而不是「断言过硬」：分段对不对是判读问题，
    /// 最终要人看原文核对，所以这里把段数、行数分布、**被剔除的行数**、
    /// 以及若干段的原文都打出来。断言只钉住几条不该被违反的不变量
    /// （段不为空、段序自上而下、覆盖率不能塌）。
    private static func assertRealDocument(
        path: String?,
        check: (String, Bool, String) -> Void,
        report: (String) -> Void
    ) async {
        guard let path, let document = PDFDocument(url: URL(fileURLWithPath: path)) else {
            report("⚠️ 没有可用的文档（请用 --open 打开一份 PDF）；真机那组**未执行**，不计入通过")
            return
        }
        let name = URL(fileURLWithPath: path).lastPathComponent
        let rawLines = PDFLineExtractor.lines(in: document)
        guard !rawLines.isEmpty else {
            // 扫描件没有文字层。这**不是失败**，是这条通道对它不适用 ——
            // 如实报「跳过」，不能混进通过计数里充数。
            report("⚠️ \(name)：文字层为空（扫描件？）→ 真机那组跳过，不计入通过")
            return
        }

        let paragraphs = PDFParagraphExtractor.paragraphs(
            from: rawLines,
            pageSizes: PDFLineExtractor.pageSizes(in: document)
        )
        let kept = paragraphs.reduce(0) { $0 + $1.lineCount }
        let dropped = rawLines.count - kept
        let rawChars = rawLines.reduce(0) { $0 + $1.text.count }
        let paraChars = paragraphs.reduce(0) { $0 + $1.text.count }
        let shortCount = paragraphs.filter(\.isShort).count
        let ratio = rawChars > 0 ? Double(paraChars) / Double(rawChars) : 0

        report("文档：\(name)（\(document.pageCount) 页）")
        report("  文字层 \(rawLines.count) 行 / \(rawChars) 字  →  \(paragraphs.count) 段 / \(kept) 行 / \(paraChars) 字")
        report(String(format: "  被剔除 %d 行（%.1f%%）· 短段 %d 条（%.1f%%）· 字符覆盖率 %.1f%%",
                      dropped, Double(dropped) / Double(rawLines.count) * 100,
                      shortCount, Double(shortCount) / Double(max(paragraphs.count, 1)) * 100,
                      ratio * 100))

        // 行数分布：单行段占比太高说明「段间判据过敏」，每段行数很大说明「判据太钝」。
        var histogram: [Int: Int] = [:]
        for p in paragraphs { histogram[min(p.lineCount, 8), default: 0] += 1 }
        let hist = (1...8).map { "\($0)行:\(histogram[$0] ?? 0)" }.joined(separator: " ")
        report("  段行数分布（8 表示 8+）：\(hist)")

        // ── 诊断：单行段集中在哪些页 ──
        // 短行判据是「上一行的右端离**正文右边界**超过 20% 就断段」。它对**两端对齐**的
        // 正文是准的；对**左对齐、右端参差**的正文，只要某行的右端恰好短过这条线就会误断。
        // 这里把逐页的命中数打出来，好区分「判据过敏」和「这份文档本来就多短段」——
        // 若无此读数，看到「59% 是单行段」只能靠猜。
        var stats: [(page: Int, lines: Int, paras: Int, single: Int, shortHits: Int, threshold: CGFloat)] = []
        for page in Set(rawLines.map(\.pageIndex)).sorted() {
            let onPage = rawLines.filter { $0.pageIndex == page }
            guard !onPage.isEmpty else { continue }
            let pageParas = paragraphs.filter { $0.pageIndex == page }
            let edges = onPage.map { $0.bounds.maxX }.sorted()
            let rightEdge = edges[min(edges.count - 1, Int(Double(edges.count) * 0.9))]
            let leftMin = onPage.map { $0.bounds.minX }.min() ?? 0
            let bodyWidth = rightEdge - leftMin
            let threshold = rightEdge - bodyWidth * 0.2
            let hits = onPage.filter { $0.bounds.maxX < threshold }.count
            stats.append((page, onPage.count, pageParas.count,
                          pageParas.filter { $0.lineCount == 1 }.count, hits, threshold))
        }
        let worst = stats.sorted {
            Double($0.single) / Double(max($0.paras, 1)) > Double($1.single) / Double(max($1.paras, 1))
        }.prefix(5)
        report("  ── 诊断：单行段最多的 5 页 ──")
        for s in worst {
            report(String(format: "    p%-3d 行%-3d → 段%-3d（单行 %-3d，%.0f%%）· 右端短于 %.0fpt 的行 %d/%d",
                          s.page + 1, s.lines, s.paras, s.single,
                          Double(s.single) / Double(max(s.paras, 1)) * 100,
                          s.threshold, s.shortHits, s.lines))
        }
        if let worstPage = worst.first {
            let singles = paragraphs.filter { $0.pageIndex == worstPage.page && $0.lineCount == 1 }
            report("    ── 第 \(worstPage.page + 1) 页单行段原文（前 8 条，看是标题还是正文被误断）──")
            for p in singles.prefix(8) {
                report("      x=[\(Int(p.bounds.minX)),\(Int(p.bounds.maxX))] w=\(Int(p.bounds.width)) 「\(p.text.prefix(38))」")
            }
        }

        check("真机：抽出了段落", !paragraphs.isEmpty, "得到 0 段")
        check("真机：每段的文本都非空",
              paragraphs.allSatisfy { !$0.text.isEmpty },
              "有 \(paragraphs.filter(\.text.isEmpty).count) 段为空")
        // 注：`check` 在这里是**以闭包形式传进来**的，闭包的形态是 (String, Bool, String) -> Void，
        // 拿不到 `run` 里那个 `detail = ""` 默认值，所以两参调用必须显式补一个空串。
        check("真机：每段至少一行", paragraphs.allSatisfy { $0.lineCount >= 1 }, "")

        // 位置型断言：同一页内，段与段之间自上而下。
        //
        // 这条不是形式主义：段落**输出顺序**就是英文侧「堆叠式对照」里译文块的插入位置。
        // 顺序错了，译文块会插到不属于它的地方 —— 而且界面上看起来「有结果」，不会报错。
        // 所以失败时必须把违规页号与坐标打出来（只报「顺序不对」没法定位）。
        // 容差 3pt：行盒（行高）本身会因上下标、内联图形而互相轻微咬合，
        // 1~2pt 的交叠是排版常态、不构成乱序。超过这个量级才算真问题。
        let orderTolerance: CGFloat = 3
        var orderViolations: [String] = []
        var orderOverlaps: [String] = []
        for page in Set(paragraphs.map(\.pageIndex)).sorted() {
            let onPage = paragraphs.filter { $0.pageIndex == page }
            for i in 1..<max(onPage.count, 1) {
                let previous = onPage[i - 1]
                let current = onPage[i]
                // PDF 原点在左下角：y 越大越靠上。后出的段若比前一段还靠上，
                // 说明它的阅读顺序排晚了（译文块会插错位置）。
                let rise = current.bounds.maxY - previous.bounds.maxY
                guard rise > 0.5 else { continue }
                let detail = String(
                    format: "p%d 第 %d 段 y=[%.0f,%.0f] x=[%.0f,%.0f]「%@」高过上一段 y=[%.0f,%.0f]「%@」%.0fpt",
                    page + 1, i + 1,
                    current.bounds.minY, current.bounds.maxY,
                    current.bounds.minX, current.bounds.maxX,
                    String(current.text.prefix(18)) as NSString,
                    previous.bounds.minY, previous.bounds.maxY,
                    String(previous.text.prefix(18)) as NSString,
                    rise)
                if rise > orderTolerance {
                    if orderViolations.count < 6 { orderViolations.append(detail) }
                } else if orderOverlaps.count < 6 {
                    orderOverlaps.append(detail)
                }
            }
        }
        if !orderOverlaps.isEmpty {
            report("  同页轻微咬合（≤\(Int(orderTolerance))pt，判为排版常态）：\(orderOverlaps.count) 处")
            for item in orderOverlaps { report("    · \(item)") }
        }
        check("真机：同一页内段落自上而下排列（容差 \(Int(orderTolerance))pt）",
              orderViolations.isEmpty,
              orderViolations.joined(separator: "；"))

        // 覆盖率不能塌：低了说明页眉页脚剔除把正文一起删了。
        // 阈值给得松（0.6），因为段落拼接会吃掉断词连字符、丢掉行尾空白，
        // 所以它本来就略小于 1；但「误杀正文」会让它掉到远低于 0.6。
        check(String(format: "真机：字符覆盖率 ≥ 60%%（实测 %.1f%%）", ratio * 100),
              ratio >= 0.6,
              ratio < 0.6 ? "只有 \(Int(ratio * 100))%，页眉页脚判据可能误杀了正文" : "")

        // 段数不该超过行数（否则是凭空造段）
        check("真机：段数不超过行数", paragraphs.count <= rawLines.count,
              "\(paragraphs.count) 段 / \(rawLines.count) 行")

        // ── 「窄栏被逐行拆碎」指纹检测器：真机必须为空 ──
        var pageEdges: [Int: (right: CGFloat, left: CGFloat)] = [:]
        for page in Set(rawLines.map(\.pageIndex)) {
            let onPage = rawLines.filter { $0.pageIndex == page }
            guard !onPage.isEmpty else { continue }
            let rights = onPage.map { $0.bounds.maxX }.sorted()
            let right = rights[min(rights.count - 1, Int(Double(rights.count) * 0.9))]
            pageEdges[page] = (right: right, left: onPage.map { $0.bounds.minX }.min() ?? 0)
        }
        let extractorOptions = PDFParagraphExtractor.Options()
        let runs = narrowRuns(in: paragraphs, pageBodyEdges: pageEdges, options: extractorOptions)
        report("  窄栏指纹检测器：真机命中 \(runs.count) 处"
               + (runs.isEmpty ? "" : runs.map { " · p\($0.pageIndex + 1) \($0.lineCount) 行右端 \(Int($0.rightEdge))pt" }.joined()))
        check("真机：没有「窄栏整块被逐行拆碎」的指纹", runs.isEmpty,
              runs.map { "p\($0.pageIndex + 1) 连续 \($0.lineCount) 个右端对齐在 \(Int($0.rightEdge))pt 的单行段" }.joined(separator: "；"))

        // 抽样打原文供人工核对：取中间一页整页的段
        let samplePage = document.pageCount / 2
        let onSample = paragraphs.filter { $0.pageIndex == samplePage }
        if !onSample.isEmpty {
            report("  ── 抽样：第 \(samplePage + 1) 页共 \(onSample.count) 段 ──")
            for (i, p) in onSample.prefix(6).enumerated() {
                let head = p.text.prefix(64)
                report("  [\(i + 1)] \(p.lineCount) 行 · \(p.bounds.width.rounded())×\(p.bounds.height.rounded())pt"
                       + " · 「\(head)\(p.text.count > 64 ? "…" : "")」")
            }
        }
    }

    // MARK: - 夹具

    private static func linesOnPage(_ pageIndex: Int, _ items: [(String, CGRect)]) -> [PDFTextLine] {
        items.map { PDFTextLine(pageIndex: pageIndex, text: $0.0, bounds: $0.1) }
    }
}

extension LaunchOptions {
    /// 段落抽取自检开关。以 `-report` 结尾 → `isAuditRun` 自动成立、
    /// `suppressSave` 自动开、数据目录切临时（若设了 `LUMEN_TEST_DATA`）。
    static var paragraphReport: Bool { flag("--paragraph-report") }
}
