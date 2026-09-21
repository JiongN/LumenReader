import Foundation
import CoreGraphics

/// 判断一份 PDF 的**文字层可不可信** —— 也就是「能不能直接拿它去翻译」。
///
/// ## 为什么必须有这一层
///
/// 逐段翻译的输入是文字层抽出来的段落。但 PDF 的文字层**不保证是文字**：
///
/// · **扫描件**：整页是一张图，文字层是空的（实测达沃尔《第二人称观点》396 页
///   只有 31 行、301 个字）。
/// · **字体缺 ToUnicode 映射**：页面渲染出来**清晰可读**，但文字层抽出来是
///   一串乱码（实测《怀特海文集》抽出 `英英英英英` / `NXJQx”` / `目英教 XwidrtER英`）。
///   这类书在中文扫描书里非常常见。
///
/// 两种情况下，把文字层送去翻译，结果都是垃圾 —— 而用户看到的是「翻译功能坏了」。
/// 所以取段落之前必须先判一次，不可信就走 OCR 兜底。
///
/// ## 判据：双字组重合率（实测标定，不是拍脑袋的阈值）
///
/// 做法是**拿两次独立读数互相印证**：同一页既读一次文字层，又渲染成位图跑一次 OCR。
/// 两边都归一化成「小写字母 / 数字」（去掉空白与标点 —— OCR 的标点是不可靠的），
/// 再把 OCR 这边的**相邻两字符组**取成集合，量文字层那边有多大比例的字符组能在里面找到。
///
/// 本机实测（`docs/VERIFY-20260921.md` 有完整读数）：
///
/// | 文档 | 文字层 | OCR | 重合率 |
/// |---|---|---|---|
/// | 怀特海（缺 ToUnicode） | 1021 字 | 627 字 | **0.000** |
/// | Selwyn 2025（正常） | 4083 字 | 4088 字 | **0.999** |
///
/// **0.000 对 0.999 的分离度**，中间那一大片空着，所以阈值不需要精调。
///
/// ### 被我否决的候选指标（写下来免得下次再试）
///
/// 「字符种类数 / 字符多样性」**完全区分不出来**：西文本来就只有 ~90 个字符，
/// 多样性天然低。实测 whitehead 106 种（0.001）、selwyn 92 种（0.002）、
/// elgar 141 种（0.000）—— 乱码书反而字符种类最多。别再用它。
public enum TextLayerTrust {

    /// 单页的判定结论。
    public enum Verdict: String, Sendable, Equatable, CaseIterable {
        /// 文字层与 OCR 互相印证，可以直接用文字层。
        case trustworthy
        /// 文字层有内容但**不可信**（典型：字体缺 ToUnicode）→ 必须走 OCR。
        case unusable
        /// 文字层基本是空的（典型：扫描件）→ 必须走 OCR。
        case missing
        /// 样本不足或两次读数都不够长，**判不出来**。
        ///
        /// 这种情况**不主张 OCR**：花几分钟 OCR 整本书，换来一个可能白做的事，
        /// 比「沿用文字层并在界面上说明」更糟。判不出来就说判不出来。
        case undetermined

        /// 是否应该改用 OCR 取文字。
        public var needsOCR: Bool {
            self == .unusable || self == .missing
        }
    }

    /// 一页的评估结果。
    public struct Assessment: Sendable, Equatable {
        public let verdict: Verdict
        /// 双字组重合率（0…1）。`undetermined` 时也可能有值，仅供诊断。
        public let overlap: Double
        /// 归一化后的文字层字符数（只看字母与数字）。
        public let textLayerCharacters: Int
        /// 归一化后的 OCR 字符数。
        public let ocrCharacters: Int

        public var needsOCR: Bool { verdict.needsOCR }
    }

    /// 一页的原始样本：文字层读数 + 同一页的 OCR 读数。
    public struct Sample: Sendable, Equatable {
        public let pageIndex: Int
        public let textLayer: String
        public let ocr: String

        public init(pageIndex: Int, textLayer: String, ocr: String) {
            self.pageIndex = pageIndex
            self.textLayer = textLayer
            self.ocr = ocr
        }
    }

    // MARK: - 阈值

    /// 文字层归一化后短于这个长度，就认为它「基本是空的」。
    ///
    /// 取 12 而不是 1：扉页、版权页、纯图页的文字层可能只有个位数字符，
    /// 拿它判「可信」会让整本书被误判成正常。
    public static let minimumTextLayerCharacters = 12

    /// 判「可信」的下界。实测正常文档在 0.999，取 0.55 留足余量。
    public static let trustworthyOverlap = 0.55

    /// 判「不可信」的上界。实测缺 ToUnicode 的文档在 0.000，取 0.25 留足余量。
    public static let unusableOverlap = 0.25

    /// 两次读数的归一化长度都短于它时，不判（样本太少，判了就是猜）。
    public static let minimumSampleCharacters = 60

    // MARK: - 单页判定

    public static func assess(textLayer: String, ocr: String) -> Assessment {
        let layer = normalized(textLayer)
        let recognized = normalized(ocr)
        let overlap = bigramOverlap(layer, against: recognized)

        // 文字层基本为空 → 扫描件。这一条**不看 OCR**：即使 OCR 也没读出来
        // （整页是插图），结论「文字层不足以支撑翻译」依然成立。
        if layer.count < minimumTextLayerCharacters {
            return Assessment(verdict: .missing,
                              overlap: overlap,
                              textLayerCharacters: layer.count,
                              ocrCharacters: recognized.count)
        }

        // 样本太少不判 —— 拿半行字判整本书，是「看起来有结论」的假结论。
        guard layer.count >= minimumSampleCharacters,
              recognized.count >= minimumSampleCharacters else {
            return Assessment(verdict: .undetermined,
                              overlap: overlap,
                              textLayerCharacters: layer.count,
                              ocrCharacters: recognized.count)
        }

        let verdict: Verdict
        if overlap >= trustworthyOverlap {
            verdict = .trustworthy
        } else if overlap < unusableOverlap {
            verdict = .unusable
        } else {
            verdict = .undetermined
        }
        return Assessment(verdict: verdict,
                          overlap: overlap,
                          textLayerCharacters: layer.count,
                          ocrCharacters: recognized.count)
    }

    public static func assess(_ sample: Sample) -> Assessment {
        assess(textLayer: sample.textLayer, ocr: sample.ocr)
    }

    // MARK: - 整本判定

    /// 整本的结论。
    public struct DocumentAssessment: Sendable, Equatable {
        public let verdict: Verdict
        /// 各页的明细，按页号升序。界面上的「为什么这么判」用它。
        public let pages: [(pageIndex: Int, assessment: Assessment)]

        /// 决定用哪条路取文字。
        public var needsOCR: Bool { verdict.needsOCR }

        /// 判定用到的页数（页数太少时要如实说明）。
        public var sampledPageCount: Int { pages.count }

        public static func == (lhs: DocumentAssessment, rhs: DocumentAssessment) -> Bool {
            lhs.verdict == rhs.verdict
                && lhs.pages.count == rhs.pages.count
                && zip(lhs.pages, rhs.pages).allSatisfy { $0.0 == $1.0 && $0.1 == $1.1 }
        }
    }

    /// 把若干页的样本汇总成一个整本结论。
    ///
    /// 规则：**只看判出了结果的页**（`trustworthy` / `unusable` / `missing`），
    /// 数多的那一边赢；两边一样多时取**更需要 OCR** 的那个（宁可多干一点，
    /// 也不要拿乱码去翻译）。一页都没判出来时如实返回 `undetermined`。
    ///
    /// 为什么不取平均重合率：页与页之间差异极大（一页扉页能拖垮整本均值），
    /// 而**分类投票**的每一票都是「这一页能不能用」这个真问题。
    public static func assessDocument(_ samples: [Sample]) -> DocumentAssessment {
        var detail: [(pageIndex: Int, assessment: Assessment)] = []
        var tally: [Verdict: Int] = [:]

        for sample in samples.sorted(by: { $0.pageIndex < $1.pageIndex }) {
            let result = assess(sample)
            detail.append((sample.pageIndex, result))
            tally[result.verdict, default: 0] += 1
        }

        func count(_ verdict: Verdict) -> Int { tally[verdict] ?? 0 }

        let missing = count(.missing)
        let unusable = count(.unusable)
        let trustworthy = count(.trustworthy)

        let verdict: Verdict
        if trustworthy == 0 && unusable == 0 && missing == 0 {
            verdict = .undetermined
        } else if trustworthy + unusable + missing == missing {
            // 每一页都判成「文字层基本为空」→ 整本扫描件
            verdict = .missing
        } else if unusable > trustworthy {
            verdict = .unusable
        } else if trustworthy > unusable {
            verdict = .trustworthy
        } else {
            // 平票：取更需要 OCR 的那个
            verdict = .unusable
        }

        return DocumentAssessment(verdict: verdict, pages: detail)
    }

    // MARK: - 度量

    /// 归一化：只留字母与数字，转小写。
    ///
    /// 去掉空白与标点是刻意的 —— OCR 的标点（中英文标点混淆、连字符、引号方向）
    /// 与文字层几乎不可能一致，留着它们会把正常文档的重合率压到阈值以下。
    /// 汉字落在 `isLetter` 里，中英混排不需要特判。
    public static func normalized(_ text: String) -> String {
        var out = ""
        out.reserveCapacity(text.count)
        for character in text.lowercased() where character.isLetter || character.isNumber {
            out.append(character)
        }
        return out
    }

    /// `text` 的相邻两字符组有多少比例能在 `reference` 里找到。
    ///
    /// 用**双字组集合**而不是整串比对：OCR 与文字层不可能逐字一致
    /// （断行位置、连字符、个别误识都会差），但「大部分相邻字对都在」这件事
    /// 对同一段真实的文字是成立的、对乱码是不成立的。
    public static func bigramOverlap(_ text: String, against reference: String) -> Double {
        let lhs = Array(text)
        let rhs = Array(reference)
        guard lhs.count >= 2, rhs.count >= 2 else { return 0 }

        var pool = Set<String>()
        pool.reserveCapacity(rhs.count)
        for index in 0..<(rhs.count - 1) {
            pool.insert(String(rhs[index...index + 1]))
        }

        var hit = 0
        for index in 0..<(lhs.count - 1) where pool.contains(String(lhs[index...index + 1])) {
            hit += 1
        }
        return Double(hit) / Double(lhs.count - 1)
    }

    /// 从若干页里挑出**最值得判定的那几页**。
    ///
    /// 挑法：跳过开头（封面 / 目录页常无文字），从全书 8% 处起等距取样。
    /// 判定只需要 3~5 页 —— 每页 OCR 要 0.7~2.3 秒（实测 2 倍渲染），
    /// 为了判定去 OCR 全书是荒唐的。
    public static func samplePages(pageCount: Int, wanted: Int = 4) -> [Int] {
        guard pageCount > 0, wanted > 0 else { return [] }
        guard pageCount > wanted else { return Array(0..<pageCount) }

        let start = max(0, Int(Double(pageCount) * 0.08))
        let usable = pageCount - start
        guard usable > wanted else { return Array(start..<pageCount) }

        let stride = max(1, usable / wanted)
        var out: [Int] = []
        var index = start
        while out.count < wanted && index < pageCount {
            out.append(index)
            index += stride
        }
        return out
    }
}
