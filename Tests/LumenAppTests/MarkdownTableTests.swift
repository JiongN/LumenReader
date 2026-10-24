import Testing
@testable import LumenApp

@MainActor
struct MarkdownTableTests {
    @Test func tableBetweenParagraphsKeepsRowsAndAlignment() throws {
        let blocks = MarkdownText.parse("""
        原文对照
        | 命题 | 原文 | 页码 |
        | :--- | :---: | ---: |
        | **人工智能** | `encoded in` | 85 |
        | 第二项 | 需要完整保留的长句。 | 106 |

        后续说明
        """)
        #expect(blocks.count == 3)
        guard case .table(let table) = blocks[1].kind else { Issue.record("Missing table"); return }
        #expect(table.header == ["命题", "原文", "页码"])
        #expect(table.alignments == [.leading, .center, .trailing])
        #expect(table.rows == [["**人工智能**", "`encoded in`", "85"], ["第二项", "需要完整保留的长句。", "106"]])
        #expect(blocks.last?.kind == .paragraph("后续说明"))
    }

    @Test func escapedPipesCodeAndMissingCells() {
        let blocks = MarkdownText.parse(#"""
        A | B | C
        --- | --- | ---
        a\|b | `x|y` | ``a`|b``
        short | row
        """#)
        guard case .table(let table) = blocks.first?.kind else { Issue.record("Missing table"); return }
        #expect(table.rows == [["a|b", "`x|y`", "``a`|b``"], ["short", "row", ""]])
    }

    @Test func ordinaryPipesAndFencedCodeAreNotTables() {
        #expect(MarkdownText.parse("A | B\nnot a separator").first?.kind == .paragraph("A | B not a separator"))
        #expect(MarkdownText.parse("```text\nA | B\n--- | ---\n1 | 2\n```").first?.kind == .code("A | B\n--- | ---\n1 | 2"))
        #expect(MarkdownText.parse("A | B\n--- | unfinished").count == 1)
    }

    @Test func malformedRowsAndHugeTablesDoNotLoseContent() {
        let malformed = MarkdownText.parse("A | B\n--- | ---\n1 | 2 | EXTRA")
        #expect(malformed.last?.kind == .paragraph("1 | 2 | EXTRA"))
        let blocks = MarkdownText.parse("A | B\n--- | ---\n" + (0..<205).map { "\($0) | value" }.joined(separator: "\n"))
        guard case .table(let table) = blocks.first?.kind else { Issue.record("Missing table"); return }
        #expect(table.rows.count == 200)
        guard case .paragraph(let remainder) = blocks.last?.kind else { Issue.record("Missing remainder"); return }
        #expect(String(remainder.characters).contains("204 | value"))
    }

    @Test func extraSeparatorCellDoesNotHideOtherwiseValidTable() {
        let blocks = MarkdownText.parse("""
        | Vision | Stage | Limits | Description |
        | --- | --- | --- | --- | --- |
        | Oracle | Study design | Too much literature | Search and summarize |
        | Arbiter | Peer review | Too many papers | Evaluate scientific merit |
        """)
        guard case .table(let table) = blocks.first?.kind else { Issue.record("Valid table rejected due to one extra separator cell"); return }
        #expect(table.header.count == 4)
        #expect(table.alignments.count == 4)
        #expect(table.rows.count == 2)
        #expect(table.rows[1][3] == "Evaluate scientific merit")
    }
}
