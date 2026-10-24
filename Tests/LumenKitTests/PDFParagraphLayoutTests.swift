import Foundation
import Testing
@testable import LumenKit

@Suite("PDF 段落边界与边栏")
struct PDFParagraphLayoutTests {
    private func line(_ text: String, page: Int = 0, x: CGFloat = 50,
                      y: CGFloat, width: CGFloat = 300, height: CGFloat = 12) -> PDFTextLine {
        .init(pageIndex: page, text: text, bounds: CGRect(x: x, y: y, width: width, height: height))
    }

    @Test func repeatedSidewaysMarginDoesNotBreakSentence() {
        var lines: [PDFTextLine] = []
        for page in 0..<3 {
            lines += [line("Allowing machines to determine what humans", page: page, y: 550),
                      line("should do crosses a line and", page: page, y: 534),
                      line("should be strictly prohibited.", page: page, y: 518, width: 180),
                      line("A different paragraph starts here.", page: page, x: 60, y: 502)]
            lines.append(line("Publisher access watermark user 2026", page: page, x: 575, y: 120, width: 9, height: 650))
        }
        let sizes = Dictionary(uniqueKeysWithValues: (0..<3).map { ($0, CGSize(width: 600, height: 800)) })
        let paragraphs = PDFParagraphExtractor.paragraphs(from: lines, pageSizes: sizes)
        #expect(paragraphs.count == 6)
        #expect(paragraphs[0].text == "Allowing machines to determine what humans should do crosses a line and should be strictly prohibited.")
        #expect(!paragraphs.contains { $0.text.contains("watermark") })
    }

    @Test func uniqueRotatedNotesRemainSeparateFromBody() {
        let lines = [line("This sentence is", y: 550), line("still continuing.", y: 534),
                     line("a unique diagram label", x: 575, y: 100, width: 9, height: 320),
                     line("continuing on the next page.", page: 1, y: 710)]
        let paragraphs = PDFParagraphExtractor.paragraphs(from: lines,
            pageSizes: [0: CGSize(width: 600, height: 800), 1: CGSize(width: 600, height: 800)])
        #expect(paragraphs.map(\.text) == ["This sentence is still continuing.", "a unique diagram label", "continuing on the next page."])
    }

    @Test func shortMidSentenceLineAndInlineLargerTypeDoNotSplit() {
        let lines = [line("An argument with several clauses continues", y: 550),
                     line("inside", y: 534, width: 80),
                     line("the same sentence with an inline formula", y: 518, height: 18),
                     line("and finishes here.", y: 502, width: 170)]
        let paragraphs = PDFParagraphExtractor.paragraphs(from: lines)
        #expect(paragraphs.count == 1)
        #expect(paragraphs.first?.text.hasSuffix("and finishes here.") == true)
    }

    @Test func realIndentedParagraphsRemainSeparateInRightColumn() {
        let lines = [line("A complete paragraph begins", x: 330, y: 550, width: 220),
                     line("and ends here.", x: 330, y: 534, width: 150),
                     line("Another paragraph begins", x: 340, y: 518, width: 210),
                     line("and also ends here.", x: 330, y: 502, width: 150)]
        let paragraphs = PDFParagraphExtractor.paragraphs(from: lines)
        #expect(paragraphs.count == 2)
    }

    @Test func verticalChineseIsNotTreatedAsLatinWatermark() {
        let lines = (0..<3).map { page in
            line("中文竖排正文不是下载水印应保留", page: page, x: 575, y: 120, width: 12, height: 650)
        }
        let sizes = Dictionary(uniqueKeysWithValues: (0..<3).map { ($0, CGSize(width: 600, height: 800)) })
        #expect(PDFParagraphExtractor.paragraphs(from: lines, pageSizes: sizes).count == 3)
    }

    @Test func shortColumnEndsNearPageEdgeAreNotDeleted() {
        let lines = [line("The sentence reaches", y: 47, width: 220),
                     line("the end.", y: 31, width: 65)]
        let result = PDFParagraphExtractor.paragraphs(from: lines, pageSizes: [0: CGSize(width: 600, height: 800)])
        #expect(result.first?.text == "The sentence reaches the end.")
    }

    @Test func numericHeaderOrnamentsAreRemovedButTableValuesRemain() {
        let lines = [line("· ３５ ·", y: 750, width: 30), line("Chapter body", y: 710),
                     line("12.50", y: 420, width: 30)]
        let result = PDFParagraphExtractor.paragraphs(from: lines, pageSizes: [0: CGSize(width: 600, height: 800)])
        #expect(!result.contains { $0.text.contains("３５") })
        #expect(result.contains { $0.text.contains("12.50") })
    }

    @Test func openLineSpacingDoesNotSplitEveryAbstractLine() {
        let lines = [line("A spacious abstract line", y: 550, width: 420, height: 9),
                     line("continues at a generous spacing", y: 534, width: 420, height: 9),
                     line("and reaches a full sentence.", y: 518, width: 200, height: 9)]
        #expect(PDFParagraphExtractor.paragraphs(from: lines).count == 1)
    }
}
