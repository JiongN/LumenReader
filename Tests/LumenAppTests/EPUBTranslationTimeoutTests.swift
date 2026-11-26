import Foundation
import Testing
import LumenKit
@testable import LumenApp

@MainActor
struct EPUBTranslationTimeoutTests {
    @Test func stalledChapterTimesOutAndLateParagraphsCannotReplaceRetry() async throws {
        let controller = EPUBTranslationController(paragraphLoadLimit: .milliseconds(100))
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("epub-translation-\(UUID()).epub").path
        let folder = AppPaths.documentDirectory(forPath: path)
        defer { try? FileManager.default.removeItem(at: folder) }

        let (started, didStart) = AsyncStream<Void>.makeStream()
        var oldReply: CheckedContinuation<[String], Never>?
        let old = "These paragraphs are from the previous chapter."
        let current = "This is the new chapter and the source text should translate."
        var applied: [String] = []

        controller.start(documentPath: path, chapterIndex: 0, target: "zh-Hans",
                         engineID: MicrosoftTranslationEngine.engineID, glossary: [], customEngine: TestEngine(),
                         paragraphs: {
                             await withCheckedContinuation {
                                 oldReply = $0
                                 didStart.yield(())
                                 didStart.finish()
                             }
                         }, markLoading: { _ in }, apply: { _, text, _ in applied.append(text) })
        for await _ in started { break }
        for _ in 0..<100 where controller.isRunning { try await Task.sleep(for: .milliseconds(10)) }
        #expect(!controller.isRunning)
        #expect(controller.errorMessage?.contains("读取 EPUB 正文超时") == true)

        controller.start(documentPath: path, chapterIndex: 1, target: "zh-Hans",
                         engineID: MicrosoftTranslationEngine.engineID, glossary: [], customEngine: TestEngine(),
                         paragraphs: { [current] },
                         markLoading: { _ in }, apply: { _, text, _ in applied.append(text) })
        oldReply?.resume(returning: [old])

        for _ in 0..<100 where controller.isRunning { try await Task.sleep(for: .milliseconds(10)) }
        #expect(applied == [current])
        #expect(controller.completedCount == 1)
        #expect(controller.errorMessage == nil)
    }

    private struct TestEngine: TranslationEngine {
        let descriptor = MicrosoftTranslationEngine().descriptor

        func translate(_ text: String, to target: String, from source: String) async throws -> String {
            text
        }
    }
}
