import Foundation
import Testing
@testable import LumenApp

@MainActor
struct MarkdownListTests {
    @Test func blankLinesAndRepeatedOneMarkersRemainOneOrderedList() {
        let blocks = MarkdownText.parse("1. 第一项\n\n1. 第二项\n\n1. 第三项")
        #expect(blocks.count == 3)
        for (index, block) in blocks.enumerated() {
            guard case .listItem(let marker, let depth, let shown, _) = block.kind else {
                Issue.record("Missing ordered item"); continue
            }
            #expect(marker == "\(index + 1).")
            #expect(depth == 1 && shown)
        }
        #expect(MarkdownText.parse("• 甲\n\n• 乙").count == 2)
    }

    @Test func nestedListsAndContinuationParagraphsDoNotRestartParentNumbering() {
        let blocks = MarkdownText.parse("""
        3. **第一项**

           同一项的第二段

           - 子项甲
           - 子项乙

        4. 第二项

        ## 新列表
        1. 新的第一项
        """)
        #expect(blocks.count == 7)
        let markers = blocks.compactMap { block -> String? in
            guard case .listItem(let marker, let depth, let shown, _) = block.kind else { return nil }
            return "\(depth):\(shown ? marker : "continuation")"
        }
        #expect(markers == ["1:3.", "1:continuation", "2:•", "2:•", "1:4.", "1:1."])
        guard case .listItem(_, _, _, let first) = blocks.first?.kind else { return }
        #expect(first.runs.contains { $0.inlinePresentationIntent?.contains(.stronglyEmphasized) == true })
    }

    @Test func decimalsPlainParagraphsAndChineseSoftBreaksStayText() {
        #expect(MarkdownText.parse("3.14 是圆周率").first?.kind == .paragraph("3.14 是圆周率"))
        #expect(MarkdownText.parse("中文第一行\n继续第二行").first?.kind == .paragraph("中文第一行继续第二行"))
        #expect(MarkdownText.parse("English first\nsecond").first?.kind == .paragraph("English first second"))
        #expect(MarkdownText.parse("````\n1. literal\n\n2. literal\n````").first?.kind == .code("1. literal\n\n2. literal"))
    }
}
