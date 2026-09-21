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
/// 两条合起来的后果：**多栏版面只能整行整行地取，无法按栏切分**。所以下面的
/// `lines(in:)` 在单栏文档上是准确的，多栏文档上会把左右栏的行混在一条里。
/// 这一点如实写在这里、也写进 `docs/VERIFY.md`，不假装解决了。
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

        return selection.selectionsByLine().compactMap { line in
            let text = (line.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }
            // bounds(for:) 取的是**这一行所在的页**上的矩形。跨页选择的行会给出
            // 这一行自己那页的矩形，所以这里不需要额外判页 —— 但要防它返回空矩形。
            let bounds = line.bounds(for: page)
            guard bounds.width > 0.5, bounds.height > 0.5 else { return nil }
            return PDFTextLine(pageIndex: pageIndex, text: text, bounds: bounds)
        }
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
