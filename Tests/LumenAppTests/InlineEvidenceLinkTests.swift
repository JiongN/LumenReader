import Foundation
import LumenKit
import Testing
@testable import LumenApp

@MainActor
struct InlineEvidenceLinkTests {
    private func source(_ number: Int, locator: DocumentLocator = .pdf(page: 2, charOffset: 0)) -> DocumentCitation {
        var source = DocumentCitation(evidence: .init(id: "p\(number)", path: "/source.pdf", label: "source",
            locator: locator, text: "Evidence from original text."), version: "v1")
        source.number = number
        source.quote = "Evidence from original text."
        return source
    }

    @Test func verifiedMarkersBecomePageOrChapterLinksAndInvalidOnesDisappear() throws {
        let pdf = source(5), epub = source(2, locator: .epub(chapterIndex: 4, anchor: "", charOffset: 0))
        let original = try AttributedString(markdown: "**论断** [原文5][原文2]，未核验[原文9]。",
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))
        let rendered = InlineEvidenceLink.render(original, sources: [pdf, epub])
        #expect(String(rendered.characters) == "论断 [第 3 页][第 5 章]，未核验。")
        #expect(rendered.runs.compactMap(\.link) == [InlineEvidenceLink.url(for: pdf), InlineEvidenceLink.url(for: epub)].compactMap { $0 })
        #expect(rendered.runs.contains { $0.inlinePresentationIntent?.contains(.stronglyEmphasized) == true })
        #expect(String(original.characters).contains("[原文5]"))
        let explicit = try AttributedString(markdown: "[原文5](https://example.org/fake) [原文9](https://example.org/unknown)，比较原文1。")
        let linked = InlineEvidenceLink.render(explicit, sources: [pdf])
        #expect(String(linked.characters) == "[第 3 页] ，比较原文1。")
        #expect(linked.runs.compactMap(\.link) == [InlineEvidenceLink.url(for: pdf)].compactMap { $0 })
    }

    @Test func legacyAndStreamingMarkersDoNotInventLinksAndCodeSamplesRemainLiteral() throws {
        var invalid = source(1); invalid.quote = nil
        let original = try AttributedString(markdown: "旧回答[原文1]，`[原文2]`，其他[原文0][原文 32]。",
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))
        let rendered = InlineEvidenceLink.render(original, sources: [invalid])
        #expect(String(rendered.characters) == "旧回答，[原文2]，其他。")
        #expect(rendered.runs.allSatisfy { $0.link == nil })
        #expect(String(InlineEvidenceLink.render(AttributedString("正在回答[原文1]。"), sources: []).characters) == "正在回答。")
        #expect(String(InlineEvidenceLink.render(AttributedString("正文[原文9999][原文999999999999999999999999]，尾部[原文"), sources: []).characters) == "正文，尾部")
    }

    @Test func navigationAcceptsOnlyExactKnownCitationURLs() throws {
        let sources = [source(1), source(2)]
        let url = try #require(InlineEvidenceLink.url(for: sources[1]))
        #expect(InlineEvidenceLink.source(for: url, in: sources) == sources[1])
        for text in ["lumen-evidence://citation/3", "lumen-evidence://citation/2?path=/other.pdf",
                     "lumen-evidence://citation/2#other", "https://citation/2", "file:///source.pdf"] {
            #expect(InlineEvidenceLink.source(for: try #require(URL(string: text)), in: sources) == nil)
        }
        #expect(InlineEvidenceLink.url(for: source(1, locator: .pdf(page: Int.max, charOffset: 0))) == nil)
        #expect(InlineEvidenceLink.url(for: source(1, locator: .pdf(page: -1, charOffset: 0))) == nil)
    }
}
