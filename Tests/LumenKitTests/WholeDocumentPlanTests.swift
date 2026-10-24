import Foundation
import Testing
@testable import LumenKit

struct WholeDocumentPlanTests {
    @Test func sectionsGapsMissingAndDoubleDocumentsNeverLoseEvidence() throws {
        let source = (0..<315).filter { ![20, 154, 312].contains($0) }.map {
            DocumentEvidence(id: "p\($0)", path: "/book.pdf", label: "第 \($0 + 1) 页", locator: .pdf(page: $0, charOffset: 0), text: "text \($0)")
        }
        let document = DocumentContext(version: "v1", path: "/book.pdf", evidence: source, missingUnits: [20, 154, 312], unitCount: 315,
            sections: [.init(title: "第一部分", startUnit: 21, endUnit: 150), .init(title: "第二部分", startUnit: 151, endUnit: 299)])
        let parts = WholeDocumentPlan.parts([document, document])
        #expect(parts.flatMap(\.evidence).count == source.count * 2)
        #expect(Set(parts.map(\.id)).count == parts.count)
        for prefix in ["D1", "D2"] {
            #expect(Set(parts.filter { $0.id.hasPrefix(prefix) }.flatMap(\.evidence).map(\.id)) == Set(source.map(\.id)))
        }
        let fallback = WholeDocumentPlan.parts([.init(version: "v1", path: "/book.pdf", evidence: source, unitCount: 315)])
        #expect(fallback.count == 24)
        #expect(fallback.first?.evidence.first?.locator.pageIndex == 0)
        #expect(fallback.last?.evidence.last?.locator.pageIndex == 314)
        let pageBookmarks = (0..<315).map { DocumentSection(title: String($0 + 1), startUnit: $0, endUnit: $0) }
        #expect(WholeDocumentPlan.isPageBookmarkList(pageBookmarks, unitCount: 315))
        let misleading = WholeDocumentPlan.parts([.init(version: "v1", path: "/book.pdf", evidence: source, unitCount: 315, sections: pageBookmarks)])
        #expect(misleading.count == 24)
        #expect(misleading.flatMap(\.evidence).count == source.count)
    }

    @Test func sectionDigestRejectsLostIdentityEmptyOverlongAndFreeFormSummary() throws {
        #expect(throws: AIError.self) { try SectionDigest.validated("{\"partID\":\"other\",\"summary\":\"abc\"}", expectedID: "D1S1F1", tokenLimit: 64) }
        #expect(throws: AIError.self) { try SectionDigest.validated("{\"partID\":\"D1S1F1\",\"summary\":\"\"}", expectedID: "D1S1F1", tokenLimit: 64) }
        #expect(throws: AIError.self) { try SectionDigest.validated("some chapter only", expectedID: "D1S1F1", tokenLimit: 64) }
        let valid = try SectionDigest.validated("```json\n{\"partID\":\"D1S1F1\",\"summary\":\"第 1 页的主旨\"}\n```", expectedID: "D1S1F1", tokenLimit: 64)
        #expect(valid.partID == "D1S1F1")
    }

    @Test func chunksPreserveEveryCharacterIncludingHugeSingleLines() {
        let source = String(repeating: "中文 text e\u{301} 🙂", count: 3000)
        let chunks = ContextBudget.chunks(source, tokenLimit: 300)
        #expect(chunks.joined() == source)
        #expect(chunks.allSatisfy { ContextBudget.estimatedTokens($0) <= 300 })
    }

    @Test func localBudgetErrorsAreNotPresentedAsProviderHTTPFailures() throws {
        let value = "{\"partID\":\"D1S1F1\",\"summary\":\"" + String(repeating: "证据", count: 80) + "\"}"
        do {
            _ = try SectionDigest.validated(value, expectedID: "D1S1F1", tokenLimit: 192)
            Issue.record("Expected budget failure")
        } catch {
            #expect(error.localizedDescription.contains("全文准备未完成"))
            #expect(!error.localizedDescription.contains("服务端说明"))
        }
        #expect(try SectionDigest.decoded(value, expectedID: "D1S1F1").summary.count == 160)
    }
}
