import Foundation
import Testing
@testable import LumenApp

@Suite("翻译长段切块")
struct TranslationTextSplitterTests {
    @Test func tableChunksKeepRowsAndAllCells() {
        let source = (1...30).map { "Teacher\tX\($0)\tA long cell about collaboration and its evidence." }.joined(separator: "\n")
        let chunks = TranslationTextSplitter.split(source, limit: 200, preservingLines: true)
        #expect(chunks.count > 1)
        #expect(chunks.allSatisfy { $0.count <= 200 })
        #expect(chunks.joined() == source)
        #expect(chunks.dropLast().allSatisfy { $0.hasSuffix("\n") })
    }
    @Test @MainActor func backgroundSplitRejectsCancelledWork() async throws {
        let text = String(repeating: "A complete sentence. ", count: 100)
        let result = try await TranslationTextSplitter.splitInBackground(text)
        #expect(result == TranslationTextSplitter.split(text))
        let task = Task { try await TranslationTextSplitter.splitInBackground(text) }
        task.cancel()
        do {
            _ = try await task.value
            Issue.record("取消的切块任务不应返回材料")
        } catch {
            #expect(error is CancellationError)
        }
    }

    @Test func sentenceTokenizerKeepsAbbreviationsAndDecimals() {
        let text = "Dr. Smith measured 3.14 units in the U.S. study. Another sentence follows."
        let sentences = TranslationTextSplitter.sentences(of: text)
        #expect(sentences.joined() == text)
        #expect(sentences.contains { $0.contains("Dr. Smith") && $0.contains("3.14") && $0.contains("U.S. study.") }, "\(sentences)")
    }

    @Test func completeSentencesPackWithinLimit() {
        let sentence = "This is a complete sentence with evidence. "
        let text = String(repeating: sentence, count: 50).trimmingCharacters(in: .whitespacesAndNewlines)
        let chunks = TranslationTextSplitter.split(text, limit: 100)
        #expect(chunks.joined() == text)
        #expect(chunks.allSatisfy { $0.count <= 100 && $0.trimmingCharacters(in: .whitespaces).hasSuffix(".") })
    }

    @Test func oversizedSentenceSplitsAtWordsAndRetainsText() {
        let text = String(repeating: "extraordinary evidence ", count: 100)
        let chunks = TranslationTextSplitter.split(text, limit: 55)
        #expect(chunks.joined() == text.trimmingCharacters(in: .whitespacesAndNewlines))
        #expect(chunks.allSatisfy { $0.count <= 55 })
        #expect(chunks.dropLast().allSatisfy { $0.last?.isWhitespace == true })
    }

    @Test func chineseQuotesAndLongClausesRemainLossless() {
        let text = "他说：“这是一个完整句子。”这是第二句话！" + String(repeating: "很长的中文内容，仍然需要保留所有文字；", count: 30)
        let chunks = TranslationTextSplitter.split(text, limit: 70)
        #expect(chunks.joined() == text)
        #expect(chunks.allSatisfy { $0.count <= 70 })
        #expect(!chunks.contains { $0.hasPrefix("”") })
    }
}
