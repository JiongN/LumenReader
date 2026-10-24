import Foundation
import Testing
@testable import LumenKit

@Suite("分栏与全文上下文")
struct DocumentContextTests {
    @Test func columnsDoNotInterleaveAndSpanningHeadingDividesBands() {
        var lines: [PDFTextLine] = []
        for row in 0..<4 {
            for (x, name) in [(CGFloat(40), "L"), (CGFloat(320), "R")] {
                lines.append(.init(pageIndex: 0, text: "\(name)\(row)",
                    bounds: CGRect(x: x, y: CGFloat(700 - row * 14), width: 230, height: 10)))
            }
        }
        lines.append(.init(pageIndex: 0, text: "Full width heading", bounds: CGRect(x: 40, y: 610, width: 510, height: 20)))
        for row in 0..<4 {
            for (x, name) in [(CGFloat(40), "A"), (CGFloat(320), "B")] {
                lines.append(.init(pageIndex: 0, text: "\(name)\(row)",
                    bounds: CGRect(x: x, y: CGFloat(570 - row * 14), width: 230, height: 10)))
            }
        }
        let ordered = PDFParagraphExtractor.columnRegions(lines.reversed()).flatMap { $0 }.map(\.text)
        #expect(ordered == ["L0", "L1", "L2", "L3", "R0", "R1", "R2", "R3", "Full width heading", "A0", "A1", "A2", "A3", "B0", "B1", "B2", "B3"])
    }

    @Test func abstractAndHeadingsAreNeverRemovedAsMetadata() {
        let lines = [
            PDFTextLine(pageIndex: 0, text: "ABSTRACT", bounds: CGRect(x: 40, y: 500, width: 120, height: 14)),
            PDFTextLine(pageIndex: 0, text: "Scientists imagine AI improving research.", bounds: CGRect(x: 40, y: 475, width: 300, height: 12)),
            PDFTextLine(pageIndex: 0, text: "INTRODUCTION", bounds: CGRect(x: 40, y: 440, width: 160, height: 14))
        ]
        let text = PDFParagraphExtractor.paragraphs(from: lines, pageSizes: [0: CGSize(width: 600, height: 800)]).map(\.text).joined()
        #expect(text.contains("ABSTRACT"))
        #expect(text.contains("Scientists imagine"))
        #expect(text.contains("INTRODUCTION"))
    }

    @Test func fullTextIsPresentExactlyOnceAndStableBeforeHistory() {
        let text = "BEGIN " + String(repeating: "body ", count: 4000) + " MIDDLE " + String(repeating: "end ", count: 4000) + " END"
        let first = PromptLibrary.messages(task: .ask(question: "核心观点？"), selection: nil,
            metadata: .init(), locatorLabel: "全文", context: text, memory: "")
        let next = PromptLibrary.messages(task: .ask(question: "继续解释"), selection: nil,
            metadata: .init(), locatorLabel: "全文", context: text, memory: "", history: [.user("之前的问题"), .assistant("之前的回答")])
        #expect(first[0] == next[0])
        #expect(first[1] == next[1])
        #expect(next.filter { $0.content.contains("MIDDLE") }.count == 1)
        #expect(next[1].content.contains(text))
        #expect(next.last?.content.contains("继续解释") == true)
    }

    @Test func chunksCoverAllTextAndRespectBudget() {
        let text = (0..<100).map { "PAGE\($0): " + String(repeating: "理解机制 ", count: 20) }.joined(separator: "\n")
        let chunks = ContextBudget.chunks(text, tokenLimit: 512)
        #expect(chunks.count > 1)
        for index in 0..<100 { #expect(chunks.joined().contains("PAGE\(index):")) }
        #expect(chunks.allSatisfy { ContextBudget.estimatedTokens($0) <= 512 })
        let longChinese = ContextBudget.chunks(String(repeating: "理解", count: 1200), tokenLimit: 256)
        #expect(longChinese.allSatisfy { ContextBudget.estimatedTokens($0) <= 256 })
    }

    @Test func legacyProviderDefaultsAndConfiguredCapacityRoundTrip() throws {
        var provider = try JSONDecoder().decode(AIProviderConfig.self, from: Data(#"{"name":"old"}"#.utf8))
        #expect(provider.contextWindow == 32_768)
        provider.contextWindow = 128_000
        let restored = try JSONDecoder().decode(AIProviderConfig.self, from: JSONEncoder().encode(provider))
        #expect(restored.contextWindow == 128_000)
        #expect(ContextBudget.inputLimit(restored) < 128_000 - restored.maxTokens)
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(AIProviderConfig.self, from: Data(#"{"contextWindow":"broken"}"#.utf8))
        }
    }
}
