import Foundation

/// PDF 文字层给出的一行。
///
/// 为什么要有这个中间类型：「把行聚类成段落」是**纯几何 + 纯文本**的判断，
/// 值钱的部分在这里；而「从 PDFPage 把行取出来」必须用 PDFKit。
/// 本项目 `LumenKit` 不依赖 PDFKit（PDFKit 只在界面层用），所以取行留在界面层、
/// 聚类留在引擎层，两边靠这个类型对接 —— 于是聚类算法可以脱离 PDF 文件被断言，
/// 不需要为了测一个阈值去准备一份 500 页的样本。
///
/// 坐标系沿用 PDF 的页面坐标：**原点在左下角，y 越大越靠上**。
/// 这跟屏幕坐标相反，读代码时容易搞反，所以这里显式写清、且所有排序代码都只用
/// `maxY` / `minY` 表达「上 / 下」而不写裸比较。
public struct PDFTextLine: Sendable, Equatable {

    /// 0-based 页索引
    public var pageIndex: Int
    public var text: String
    /// 该行在页面坐标系里的包围盒
    public var bounds: CGRect

    public init(pageIndex: Int, text: String, bounds: CGRect) {
        self.pageIndex = pageIndex
        self.text = text
        self.bounds = bounds
    }

    /// 行高。用包围盒高度而不是取字号：字号要另查字体信息，
    /// 而行高天然就是「相邻行间距」的基准，两者比值才是聚类真正要的判据。
    public var height: CGFloat { bounds.height }
}

/// 一个段落在某一页上的几何片段。跨页续段由多个片段组成，译文只生成一次，
/// 但点击侧栏译文时仍能定位到当前页对应的那一段正文。
public struct PDFParagraphFragment: Sendable, Equatable {
    public var pageIndex: Int
    public var bounds: CGRect

    public init(pageIndex: Int, bounds: CGRect) {
        self.pageIndex = pageIndex
        self.bounds = bounds
    }
}

/// 一段（聚类结果）。
///
/// 逐段翻译的最小有意义单位是**段**而不是行：逐行翻会把一个句子切成几截、
/// 每截都缺主语，译文质量会明显崩掉。这是整个功能要先解决段落的原因。
public struct PDFParagraph: Sendable, Equatable, Identifiable {

    /// 0-based 页索引
    public var pageIndex: Int
    /// 段内各行拼接后的文本（拼接规则见 `PDFParagraphExtractor.joinLines`）
    public var text: String
    /// 本段所有行的并集包围盒
    public var bounds: CGRect
    /// 本段由几行组成
    public var lineCount: Int
    /// 本段第一行在**本页阅读顺序**里的序号（从 0 起）。调试与断言用。
    public var firstLineOrdinal: Int
    /// 文本短于 `PDFParagraphExtractor.Options.minimumBodyLength`。
    ///
    /// 不直接丢弃这类短段：图注、表头、页码都可能落到这里，
    /// 但「看起来短」不足以断定它不是正文。保留 + 打标，让消费方（第二阶段翻译）
    /// 自己决定跳过，并且这个决定是可复核的。
    public var isShort: Bool
    /// 段落在各页上的位置。普通段只有一个，跨页续段至少两个。
    public var fragments: [PDFParagraphFragment]

    public var pageIndices: [Int] { Array(Set(fragments.map(\.pageIndex))).sorted() }
    public var spansPages: Bool { pageIndices.count > 1 }

    public func fragment(on page: Int) -> PDFParagraphFragment? {
        fragments.first { $0.pageIndex == page }
    }

    /// 稳定 id：页号 + 段首位置，四舍五入到整点。
    ///
    /// **刻意不含行数与文本**——它要当译文缓存的键用，而文本会因为拼接规则微调而变化，
    /// 位置才是那份 PDF 里稳定的东西。与批注 `entryID` 同一套口径（页号 + 四舍五入的坐标）。
    public var id: String {
        "p\(pageIndex)-\(Int(bounds.minY.rounded()))x\(Int(bounds.minX.rounded()))"
    }

    public init(pageIndex: Int, text: String, bounds: CGRect,
                lineCount: Int, firstLineOrdinal: Int, isShort: Bool,
                fragments: [PDFParagraphFragment]? = nil) {
        self.pageIndex = pageIndex
        self.text = text
        self.bounds = bounds
        self.lineCount = lineCount
        self.firstLineOrdinal = firstLineOrdinal
        self.isShort = isShort
        self.fragments = fragments ?? [PDFParagraphFragment(pageIndex: pageIndex, bounds: bounds)]
    }
}
