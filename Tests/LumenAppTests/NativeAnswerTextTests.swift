import AppKit
import SwiftUI
import Testing
import LumenKit
@testable import LumenApp

@Suite("原生回答排版", .serialized)
@MainActor
struct NativeAnswerTextTests {
    @Test func widthAndContentChangesInvalidateOnlyTheNeededMeasurement() {
        _ = NSApplication.shared
        let view = AnswerTextView()
        let text = String(repeating: "回答需要完整显示，不能被截断。English text.\n\n", count: 80)
        view.update(text: text, blocks: nil, fontSize: 15, textColor: .textColor, accent: .linkColor, evidence: [])
        let size = view.measuredSize(width: 280)
        #expect(size.height > 1_000 && size.height.isFinite)
        for _ in 0..<50 { #expect(view.measuredSize(width: 280) == size) }
        #expect(view.measurementCount == 1)
        #expect(view.measuredSize(width: 480).height < size.height)
        #expect(view.measurementCount == 2)
        view.update(text: text + "新增尾句。", blocks: nil, fontSize: 15, textColor: .textColor, accent: .linkColor, evidence: [])
        #expect(view.measuredSize(width: 280).height >= size.height)
        #expect(view.measurementCount == 3)
        #expect(view.string.hasSuffix("新增尾句。"))
    }

    @Test func completionKeepsTextStorageAndRendersListsStylesAndVerifiedLinks() throws {
        _ = NSApplication.shared
        let text = "# 标题\n\n1. **第一条** [原文1]\n2. *第二条* 与 `code`。\n\n正文和 [网站](https://example.com)。"
        let view = AnswerTextView()
        view.update(text: text, blocks: nil, fontSize: 17, textColor: .textColor, accent: .linkColor, evidence: [])
        let storage = try #require(view.textStorage)
        var source = DocumentCitation(evidence: .init(id: "p3", path: "/tmp/source.pdf", label: "第 3 页",
            locator: .pdf(page: 2, charOffset: 0), text: "这是八个字以上的有效引文。"), version: "v1")
        source.quote = "这是八个字以上的有效引文。"
        source.number = 1
        view.update(text: text, blocks: MarkdownText.parse(text), fontSize: 17, textColor: .textColor,
                    accent: .linkColor, evidence: [source])
        #expect(view.textStorage === storage)
        #expect(view.string.contains("1.\t第一条 [第 3 页]"))
        #expect(view.string.contains("2.\t第二条"))
        #expect(!view.string.contains("**"))
        let quote = (view.string as NSString).range(of: "[第 3 页]")
        #expect(storage.attribute(.link, at: quote.location, effectiveRange: nil) as? URL == InlineEvidenceLink.url(for: source))
        let website = (view.string as NSString).range(of: "网站")
        #expect(storage.attribute(.link, at: website.location, effectiveRange: nil) as? URL == URL(string: "https://example.com"))
        let first = (view.string as NSString).range(of: "第一条")
        let font = try #require(storage.attribute(.font, at: first.location, effectiveRange: nil) as? NSFont)
        #expect(font.pointSize == 17)
        #expect(NSFontManager.shared.traits(of: font).contains(.boldFontMask))
    }

    @Test func tablesAndCodeDoNotCreateOneNativeViewPerParagraph() {
        let text = String(repeating: "普通正文。\n\n", count: 80)
            + "| A | B |\n| --- | --- |\n| 1 | 2 |\n\n后续正文。\n\n```swift\nprint(1)\n```"
        let sections = MarkdownText.sections(MarkdownText.parse(text))
        #expect(sections.count == 4)
        #expect(sections.first?.id == 0)
        if case .prose(let blocks) = sections[0].kind { #expect(blocks.count == 80) }
        else { Issue.record("Expected one grouped prose section") }
        if case .table(let table) = sections[1].kind { #expect(table.rows == [["1", "2"]]) }
        else { Issue.record("Table scroller must remain separate") }
    }

    @Test func streamingCannotShowUnverifiedEvidenceMarkers() {
        _ = NSApplication.shared
        let view = AnswerTextView()
        view.update(text: "观点[原文1]，后续内容[原文", blocks: nil, fontSize: 15,
                    textColor: .textColor, accent: .linkColor, evidence: [])
        #expect(view.string == "观点，后续内容")
        view.update(text: "观点[原文1]，后续内容[原文2]。", blocks: nil, fontSize: 15,
                    textColor: .textColor, accent: .linkColor, evidence: [])
        #expect(view.string == "观点，后续内容。")
    }
}
