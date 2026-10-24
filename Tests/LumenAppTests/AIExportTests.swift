import Foundation
import Testing
import LumenKit
@testable import LumenApp

@Suite("AI 导出来源")
@MainActor
struct AIExportTests {
    @Test func legacyAnswerDoesNotExportInternalCoverageMetadata() {
        let answer = AIChatModel.Bubble(role: .assistant,
            text: "保留的正文\n<!-- lumen-coverage: {bad} -->\n范围未验证")
        let exported = ExportService.buildMarkdown(documentTitle: "Book", metadata: .init(), transcript: [answer])
        #expect(exported.contains("保留的正文"))
        #expect(exported.contains("范围未验证"))
        #expect(!exported.contains("lumen-coverage"))
    }
    @Test func exportDoesNotRelabelOldAnswerAsCurrentDocument() {
        var answer = AIChatModel.Bubble(role: .assistant, text: "依据 p0-50x40 的论述。")
        answer.sourceDocPath = "/papers/Original.pdf"
        answer.coverage = "全文 · 10 页/章"
        answer.evidence = [.init(evidence: .init(id: "p0-50x40", path: "/papers/Original.pdf", label: "第 1 页",
            locator: .pdf(page: 0, charOffset: 0), text: "source"), version: "v1")]
        let exported = ExportService.buildMarkdown(documentTitle: "Unrelated", metadata: .init(title: "Unrelated", author: "Wrong Author"),
            transcript: [answer])
        #expect(exported.contains("《Original》"))
        #expect(!exported.contains("Wrong Author"))
        #expect(exported.contains("/papers/Original.pdf"))
        #expect(exported.contains("第 1 页 · p0-50x40"))
        #expect(exported.contains(answer.coverage))
        #expect(exported.contains("# 《Original》对话记录"))
        #expect(!exported.contains("## 摘要"))
        #expect(ActionEntries.entries(in: .fileExport).map(\.id) == [.exportTranscript])
        #expect(LumenAction.allCases.filter { $0.rawValue.hasPrefix("export") } == [.exportTranscript])
    }
}
