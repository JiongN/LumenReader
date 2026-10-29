import Foundation
import Testing
@testable import LumenKit

@Suite("智能目录原文绑定")
struct SmartOutlineHeadingTests {
    @Test func pageMiddleHeadingIsNotReplacedByRunningHeadOrTruncated() throws {
        let title = "二、教育交往中理解学生之不当及其深层原因与教育实践反思"
        let lines = [
            PDFTextLine(pageIndex: 3, text: "理解学生：符号伦理意蕴及其实现路径", bounds: CGRect(x: 30, y: 780, width: 300, height: 12)),
            PDFTextLine(pageIndex: 3, text: String(repeating: "普通正文", count: 30), bounds: CGRect(x: 30, y: 600, width: 300, height: 12)),
            PDFTextLine(pageIndex: 3, text: title, bounds: CGRect(x: 30, y: 300, width: 300, height: 15)),
            PDFTextLine(pageIndex: 3, text: "参考文献", bounds: CGRect(x: 30, y: 100, width: 100, height: 14))
        ]
        let candidates = SmartOutlineHeadings.candidates(lines: lines, pageSize: CGSize(width: 600, height: 800))
        #expect(candidates.map(\.title) == [title, "参考文献"])
        let chosen = try SmartOutlineHeadings.selectedEntries("[{\"id\":\"p3-0\",\"title\":\"模型改写\",\"unit\":99}]", candidates: candidates)
        #expect(chosen.count == 1)
        #expect(chosen[0].title == title)
        #expect(chosen[0].unitIndex == 3)
    }

    @Test func hallucinatedIDsAreRejectedAndSelectionKeepsSourceOrder() throws {
        let candidates = [SmartOutlineCandidate(id: "a", title: "一、问题", unitIndex: 4, depth: 0),
                          .init(id: "b", title: "（一）原因", unitIndex: 4, depth: 1)]
        #expect(throws: (any Error).self) { try SmartOutlineHeadings.selectedEntries("[{\"id\":\"fake\"}]", candidates: candidates) }
        #expect(try SmartOutlineHeadings.selectedEntries("好的```json\n[{\"id\":\"b\"},{\"id\":\"a\"},{\"id\":\"a\"}]\n```", candidates: candidates).map(\.title) == ["一、问题", "（一）原因"])
        #expect(try SmartOutlineHeadings.selectedEntries("[]", candidates: candidates).isEmpty)
    }

    @Test func everyHeadingIsBatchedWithoutSamplingAwayBookMiddle() {
        let all = (0..<450).map { SmartOutlineCandidate(id: "h\($0)", title: "第\($0 + 1)节 可靠定位与标题完整性", unitIndex: $0, depth: 0) }
        let batches = SmartOutlineHeadings.batches(all, tokenLimit: 600)
        #expect(batches.count > 1)
        #expect(batches.flatMap { $0 } == all)
        #expect(SmartOutlineHeadings.depth(of: "一 、 理解学生") == 0)
        #expect(SmartOutlineHeadings.depth(of: "（二）价值关怀") == 1)
        #expect(SmartOutlineHeadings.depth(of: "1. Introduction") == 0)
        #expect(SmartOutlineHeadings.depth(of: "1.2.3 Deep section") == 2)
    }
}
