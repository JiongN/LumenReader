import Foundation
import Testing
import LumenKit

struct WholeAnswerCoverageTests {
    @Test func privateSectionAnnotationsDoNotLeakIntoReadingText() {
        #expect(WholeAnswerCoverage.visibleAnswer("核心贡献（D1S13）：正文。") == "核心贡献：正文。")
        #expect(WholeAnswerCoverage.visibleAnswer("分析 (D1S1, D2S3F2) 与讨论 [D1S14]。") == "分析  与讨论 。")
        #expect(WholeAnswerCoverage.visibleAnswer("正文（D1S") == "正文")
        #expect(WholeAnswerCoverage.visibleAnswer("章节 D1S13：核心观点；`D2S3`。") == "章节 ：核心观点；。")
        #expect(WholeAnswerCoverage.visibleAnswer("代码 `foo(D1S13)` 不能被修改。") == "代码 `foo(D1S13)` 不能被修改。")
        let code = "```mindmap\n{\"coveredSections\":[\"D1S13\"]}\n```"
        #expect(WholeAnswerCoverage.visibleAnswer(code) == code)
        #expect(WholeAnswerCoverage.visibleAnswer("第 13 页（作者观点）和 D1S13Code 都保留。") == "第 13 页（作者观点）和 D1S13Code 都保留。")
    }

    @Test func readableTextDoesNotRequireAnOCRProbe() {
        for text in ["摘要", "Abstract", "3", "Table 1", "正常的中英文正文。Readable text."] {
            #expect(!TextLayerTrust.needsVisualCheck(text))
        }
        #expect(TextLayerTrust.needsVisualCheck(" \n"))
        #expect(TextLayerTrust.needsVisualCheck("文字\u{FFFD}乱码"))
        #expect(TextLayerTrust.hasInvalidEncoding("text\u{0000}"))
        #expect(!TextLayerTrust.hasInvalidEncoding("text\n\tcontinued"))
    }
    @Test func wholeEvidenceDoesNotRequireEveryChapterInALocalAnswer() {
        #expect(!WholeAnswerCoverage.requiresReview(task: .ask(question: "基于全文核对规约符与对象的关系"), mindMap: false))
        #expect(!WholeAnswerCoverage.requiresReview(task: .ask(question: "概括规约符的定义"), mindMap: false))
        #expect(WholeAnswerCoverage.requiresReview(task: .ask(question: "总结这本书"), mindMap: false))
        #expect(WholeAnswerCoverage.requiresReview(task: .summarize(scope: .wholeDocument), mindMap: false))
        #expect(WholeAnswerCoverage.requiresReview(task: .ask(question: "画全书思维导图"), mindMap: true))
        #expect(!WholeAnswerCoverage.requiresReview(task: .ask(question: "this chapter mind map"), mindMap: true))
    }

    @Test func protocolMetadataIsHiddenEvenWhenMalformedOrInterrupted() throws {
        let code = "    print('preserve indentation')\n"
        #expect(WholeAnswerCoverage.visibleAnswer(code) == code)
        #expect(WholeAnswerCoverage.visibleAnswer(code + "<!-- lumen-coverage: {bad} -->") == "    print('preserve indentation')")
        #expect(WholeAnswerCoverage.visibleAnswer("正文\n<!-- lumen-coverage: {bad} -->\n错误") == "正文\n\n错误")
        #expect(WholeAnswerCoverage.visibleAnswer("正文\n<!-- lumen-coverage: {\"sections\":[") == "正文")
        #expect(throws: AIError.self) {
            try WholeAnswerCoverage.validatedAnswer("正文", ids: ["D1S1"], mindMap: false)
        }
        do {
            _ = try WholeAnswerCoverage.validatedAnswer("正文", ids: ["D1S1"], mindMap: false)
        } catch {
            #expect(!error.localizedDescription.contains("HTTP"))
            #expect(!error.localizedDescription.contains("绘图模型"))
        }
    }

    @Test func duplicateValidIDsDoNotFailACompleteDeclaration() throws {
        let value = "正文\n<!-- lumen-coverage: {\"sections\":[\"D1S1\",\"D1S1\",\"D1S2\"]} -->"
        #expect(try WholeAnswerCoverage.validatedAnswer(value, ids: ["D1S1", "D1S2"], mindMap: false) == "正文")
    }
    @Test func rejectsPartialOrInventedCoverageAndStripsValidatedFooter() throws {
        let ids = ["D1S1", "D1S2"]
        for bad in ["answer", "answer\n<!-- lumen-coverage: {\"sections\":[\"D1S1\"]} -->", "answer\n<!-- lumen-coverage: {\"sections\":[\"D1S1\",\"unknown\"]} -->"] {
            #expect(throws: AIError.self) { try WholeAnswerCoverage.validatedAnswer(bad, ids: ids, mindMap: false) }
        }
        let result = try WholeAnswerCoverage.validatedAnswer("answer\n<!-- lumen-coverage: {\"sections\":[\"D1S2\",\"D1S1\"]} -->", ids: ids, mindMap: false)
        #expect(result == "answer")
    }

    @Test func mapCannotClaimFullCoverageWithOnlyOneChapterInItsBranches() throws {
        let footer = "\n<!-- lumen-coverage: {\"sections\":[\"D1S1\",\"D1S2\"]} -->"
        let partial = "```mindmap\n{\"label\":\"book\",\"children\":[{\"label\":\"only chapter one\",\"coveredSections\":[\"D1S1\"]}]}\n```"
        #expect(throws: AIError.self) { try WholeAnswerCoverage.validatedAnswer(partial + footer, ids: ["D1S1", "D1S2"], mindMap: true) }
        let complete = "```mindmap\n{\"label\":\"book\",\"children\":[{\"label\":\"one\",\"coveredSections\":[\"D1S1\"]},{\"label\":\"two\",\"coveredSections\":[\"D1S2\"]}]}\n```"
        #expect(try WholeAnswerCoverage.validatedAnswer(complete + footer, ids: ["D1S1", "D1S2"], mindMap: true) == complete)
        #expect(try WholeAnswerCoverage.validatedAnswer(complete, ids: ["D1S1", "D1S2"], mindMap: true) == complete)
    }
}
