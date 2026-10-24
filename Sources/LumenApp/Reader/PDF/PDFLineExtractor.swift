import Foundation
import PDFKit
import LumenKit

/// 从 PDF 的文字层取出「行」，交给 `PDFParagraphExtractor` 聚类成段落。
///
/// **为什么取行留在界面层**：本项目 `LumenKit` 不依赖 PDFKit（只有界面层 import 它）。
/// 而「把行聚类成段落」的值钱部分全是纯几何判断，不该为了测一个阈值就去准备一份
/// 500 页的样本 —— 所以聚类在引擎层、取行在这里，两边靠 `PDFTextLine` 对接。
///
/// **关于 PDFKit 的两个实测行为**（上一轮取整行时踩出来的，写在这里免得下次再试一遍）：
///
/// 1. `page.selection(for: rect)` **不按矩形做横向裁剪** —— 它返回与矩形相交的**整行**。
///    把页面沿中线劈成左右两半各探一次，两半的 `maxX` / `minX` 差**恒为 0.0**，
///    连已知是两栏的期刊 PDF 也一样。所以「只取左栏」这件事用它做不到。
/// 2. `page.selectionForLine(at:)` **不做分栏判断** —— 两栏版面上左栏点与右栏点返回
///    **一模一样**的 bounds。
///
/// 因此先用 `selectionsByLine()`；宽行再按字符坐标中的显著空隙拆开，
/// 不依赖矩形选择来裁剪左右栏。页内阅读顺序由纯几何聚类器统一决定。
enum PDFLineExtractor {

    /// 逐页取行。
    ///
    /// - Parameter pageRange: 只取这几页（含两端）。`nil` 表示全书。
    ///   逐段翻译按页推进时会用到；整书抽取请传 `nil`。
    /// - Returns: 行数组，按「页号升序」排列；**页内顺序交给聚类器排**（聚类器的
    ///   `readingOrder` 是同一份实现，这里不重复排一次，免得两处规则不一致）。
    static func lines(in document: PDFDocument, pageRange: ClosedRange<Int>? = nil) -> [PDFTextLine] {
        let lower = max(0, pageRange?.lowerBound ?? 0)
        let upper = min(document.pageCount - 1, pageRange?.upperBound ?? document.pageCount - 1)
        guard lower <= upper else { return [] }

        var out: [PDFTextLine] = []
        for index in lower...upper {
            guard let page = document.page(at: index) else { continue }
            out.append(contentsOf: lines(on: page, pageIndex: index))
        }
        return out
    }

    /// 取一页的行。
    ///
    /// 用「整页 mediaBox 的选择」再 `selectionsByLine()`：这是 PDFKit 给出的、
    /// 自带版面条带切分的唯一通道（`page.string` 是整页一团，没有几何）。
    /// `selectionsByLine()` 会顺手把页眉 / 页脚 / 脚注也拆成独立的行 ——
    /// **这不算问题**，剔除它们正是 `PDFParagraphExtractor.dropFurniture` 的职责；
    /// 在这里先删反而会把判断依据（页尺寸、行宽）丢掉。
    static func lines(on page: PDFPage, pageIndex: Int) -> [PDFTextLine] {
        let box = page.bounds(for: .mediaBox)
        guard box.width > 1, box.height > 1 else { return [] }
        // 扫描件没有文字层：selection 会是空选区（不是 nil），下面按文字为空剔掉。
        guard let selection = page.selection(for: box) else { return [] }
        let source = (page.string ?? "") as NSString

        let extracted = selection.selectionsByLine().flatMap { line -> [PDFTextLine] in
            var text = (line.string ?? "").components(separatedBy: .newlines).joined(separator: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return [] }
            // PDFKit may logically dehyphenate a word while splitting its glyphs
            // across two visual selections ("tea" / "chers\nmake"). Only join
            // when the original character range proves there was no separator.
            if line.numberOfTextRanges(on: page) > 0 {
                let range = line.range(at: line.numberOfTextRanges(on: page) - 1, on: page)
                let end = range.location == NSNotFound ? 0 : NSMaxRange(range)
                if end > 0, end < source.length,
                   Self.isLatinLetter(source.character(at: end - 1)), Self.isLatinLetter(source.character(at: end)),
                   text.last?.isLetter == true {
                    text += "-"
                }
            }
            // bounds(for:) 取的是**这一行所在的页**上的矩形。跨页选择的行会给出
            // 这一行自己那页的矩形，所以这里不需要额外判页 —— 但要防它返回空矩形。
            let bounds = line.bounds(for: page)
            guard bounds.width > 0.5, bounds.height > 0.5 else { return [] }
            if bounds.width > box.width * 0.7 {
                let separated = splitAtGutters(line, page: page, pageIndex: pageIndex)
                if separated.count > 1 { return separated }
            }
            return [PDFTextLine(pageIndex: pageIndex, text: text, bounds: bounds)]
        }
        // Whole sideways tables have a shared reading orientation, unlike a marginal watermark.
        let rotated = extracted.filter { $0.bounds.height > $0.bounds.width * 2 && $0.text.count > 4 }
        let isRotatedPage = rotated.count >= 12 && rotated.count > extracted.count / 2
        let oriented = extracted.map { line -> PDFTextLine in
            guard isRotatedPage, line.bounds.height > line.bounds.width || line.bounds.width < 16,
                  line.bounds.minY > box.height * 0.04 else { return line }
            let r = line.bounds
            return .init(pageIndex: pageIndex, text: line.text,
                bounds: CGRect(x: r.minY, y: box.width - r.maxX, width: r.height, height: r.width), sourceBounds: r)
        }
        return coalesceFragments(oriented)
    }

    private static func isLatinLetter(_ code: unichar) -> Bool {
        (65...90).contains(code) || (97...122).contains(code)
    }

    static func coalesceFragments(_ lines: [PDFTextLine]) -> [PDFTextLine] {
        let sorted = lines.sorted {
            let a = ($0.bounds.midY * 0.5).rounded(), b = ($1.bounds.midY * 0.5).rounded()
            return a == b ? $0.bounds.minX < $1.bounds.minX : a > b
        }
        var result: [PDFTextLine] = []
        for line in sorted {
            if let index = result.indices.last, result[index].pageIndex == line.pageIndex {
                let previous = result[index]
                let overlap = min(previous.bounds.maxY, line.bounds.maxY) - max(previous.bounds.minY, line.bounds.minY)
                let gap = line.bounds.minX - previous.bounds.maxX
                let height = min(previous.height, line.height)
                if overlap >= height * 0.5, gap >= -height * 0.5, gap <= max(3, height * 0.8),
                   abs(previous.bounds.midY - line.bounds.midY) < height * 0.5 {
                    result[index].text += " " + line.text
                    result[index].bounds = previous.bounds.union(line.bounds)
                    if previous.sourceBounds != nil || line.sourceBounds != nil {
                        result[index].sourceBounds = (previous.sourceBounds ?? previous.bounds).union(line.sourceBounds ?? line.bounds)
                    }
                    continue
                }
            }
            result.append(line)
        }
        return result
    }

    private static func splitAtGutters(_ selection: PDFSelection, page: PDFPage, pageIndex: Int) -> [PDFTextLine] {
        let source = (page.string ?? "") as NSString
        var parts: [PDFTextLine] = [], text = "", bounds = CGRect.null
        var previous: CGRect?
        func flush() {
            let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !cleaned.isEmpty, !bounds.isNull {
                parts.append(PDFTextLine(pageIndex: pageIndex, text: cleaned, bounds: bounds))
            }
            text = ""; bounds = .null; previous = nil
        }
        for rangeIndex in 0..<selection.numberOfTextRanges(on: page) {
            let range = selection.range(at: rangeIndex, on: page)
            guard range.location != NSNotFound, NSMaxRange(range) <= source.length else { continue }
            for index in range.location..<NSMaxRange(range) {
                let glyph = page.characterBounds(at: index)
                let character = source.substring(with: NSRange(location: index, length: 1))
                if glyph.width > 0, glyph.height > 0 {
                    if let previous, glyph.minX - previous.maxX > max(24, previous.height * 2.5) { flush() }
                    bounds = bounds.union(glyph)
                    previous = glyph
                }
                text += character
            }
        }
        flush()
        return parts
    }

    /// 页号 → 页面尺寸。
    ///
    /// 传给聚类器用来识别页眉 / 页脚。**取不到就别传**：聚类器在缺页尺寸时
    /// 会跳过页眉页脚剔除（宁可不删，也不要凭一个猜的页高把正文删掉），
    /// 所以这里不要塞 0 或估算值充数。
    static func pageSizes(in document: PDFDocument, pageRange: ClosedRange<Int>? = nil) -> [Int: CGSize] {
        let lower = max(0, pageRange?.lowerBound ?? 0)
        let upper = min(document.pageCount - 1, pageRange?.upperBound ?? document.pageCount - 1)
        guard lower <= upper else { return [:] }

        var out: [Int: CGSize] = [:]
        for index in lower...upper {
            guard let page = document.page(at: index) else { continue }
            let box = page.bounds(for: .mediaBox)
            guard box.width > 1, box.height > 1 else { continue }
            out[index] = box.size
        }
        return out
    }

    /// 把整份文档抽成段落。第二阶段的翻译就吃这个。
    ///
    /// 扫描件（无文字层）会返回空数组 —— 调用方必须把「空」和「还没抽」区分开，
    /// 否则用户会看到「翻译了但一个字都没有」。
    static func paragraphs(
        in document: PDFDocument,
        pageRange: ClosedRange<Int>? = nil,
        options: PDFParagraphExtractor.Options = .init()
    ) -> [PDFParagraph] {
        PDFParagraphExtractor.paragraphs(
            from: lines(in: document, pageRange: pageRange),
            pageSizes: pageSizes(in: document, pageRange: pageRange),
            options: options
        )
    }
}
