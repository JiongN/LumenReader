import Foundation
import Testing
import LumenKit
@testable import LumenApp

@Suite("划词翻译", .serialized)
@MainActor
struct SelectedTranslationTests {
    @Test func visualLineWrapsDoNotBecomeTranslationBoundaries() {
        let source = """
        The paper concludes by considering the need to challenge
        ongoing industry and
        policy claims around the labour-saving benefits of
        artificial intelligence
        in education, and instead focus on the ways in which
        these
        technologies are dependent on the hidden labour of
        humans to co-
        produce the illusion of automation.
        """
        let result = TranslationTextSplitter.selectionText(source)
        #expect(result == "The paper concludes by considering the need to challenge ongoing industry and policy claims around the labour-saving benefits of artificial intelligence in education, and instead focus on the ways in which these technologies are dependent on the hidden labour of humans to coproduce the illusion of automation.")
        #expect(!result.contains("\n"))
        #expect(TranslationTextSplitter.split(result) == [result])
    }

    @Test func selectionKeepsParagraphsAndAllText() {
        #expect(TranslationTextSplitter.selectionText("中文跨行\r\n不能断句。\r\n\r\nNext para\r\ngraph ends here.")
            == "中文跨行不能断句。\n\nNext para graph ends here.")
        #expect(TranslationTextSplitter.selectionText("inter\u{00AD}\nnational") == "international")
        #expect(TranslationTextSplitter.selectionText("Name\tValue\nA\t1") == "Name\tValue\n\nA\t1")
        let long = String(repeating: "A complete sentence with all words intact.\n", count: 100)
        let result = TranslationTextSplitter.selectionText(long)
        #expect(TranslationTextSplitter.split(result).joined() == result)
        #expect(result.hasSuffix("all words intact."))
    }

    @Test func engineReceivesContinuousSelectionAndCacheSurvivesRestart() async throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("selected-lines-\(UUID()).pdf").path
        try Data("fixture".utf8).write(to: URL(fileURLWithPath: path))
        let folder = AppPaths.documentDirectory(forPath: path)
        defer { try? FileManager.default.removeItem(atPath: path); try? FileManager.default.removeItem(at: folder) }
        let paragraph = PDFParagraph(pageIndex: 0, text: "This sentence\ncontinues to its final word.", bounds: .zero, lineCount: 1, firstLineOrdinal: 0, isShort: false)
        let controller = PDFTranslationController()
        await controller.prepare(documentPath: path, target: "zh-Hans", engineID: MicrosoftTranslationEngine.engineID, glossary: [], selection: paragraph)
        #expect(controller.paragraphs.first?.text == "This sentence continues to its final word.")
        controller.startAll(engineID: MicrosoftTranslationEngine.engineID, target: "zh-Hans", customEngine: SelectionEngine())
        for _ in 0..<100 where controller.phase != .finished { try await Task.sleep(for: .milliseconds(10)) }
        #expect(controller.state(of: paragraph.id).translation == "Translated: This sentence continues to its final word.")
        let reopened = PDFTranslationController()
        await reopened.prepare(documentPath: path, target: "zh-Hans", engineID: MicrosoftTranslationEngine.engineID, glossary: [], selection: paragraph)
        #expect(reopened.doneCount == 1)
        #expect(reopened.state(of: paragraph.id).translation == "Translated: This sentence continues to its final word.")
    }

    @Test func selectionModeIsSharedAndResetWithReader() {
        let bridge = ReaderBridge()
        #expect(!bridge.selectionTranslationMode)
        bridge.beginSelectionTranslation()
        #expect(bridge.selectionTranslationMode)
        bridge.reset()
        #expect(!bridge.selectionTranslationMode)
        #expect(bridge.selectedTextTranslationController.paragraphs.isEmpty)
    }
    @Test func lateCancelledResponseDoesNotReplaceNewSelection() async throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("selected-cancel-\(UUID()).pdf").path
        try Data("fixture".utf8).write(to: URL(fileURLWithPath: path))
        let folder = AppPaths.documentDirectory(forPath: path)
        defer { try? FileManager.default.removeItem(atPath: path); try? FileManager.default.removeItem(at: folder) }
        let old = PDFParagraph(pageIndex: 0, text: "Old selection", bounds: .zero, lineCount: 1, firstLineOrdinal: 0, isShort: false)
        var new = old
        new.text = "New selection"
        let engine = DelayedSelectionEngine()
        let controller = PDFTranslationController()
        await controller.prepare(documentPath: path, target: "zh-Hans", engineID: MicrosoftTranslationEngine.engineID, glossary: [], selection: old)
        controller.startAll(engineID: MicrosoftTranslationEngine.engineID, target: "zh-Hans", customEngine: engine)
        for _ in 0..<100 where !(await engine.hasStarted) { try await Task.sleep(for: .milliseconds(10)) }
        #expect(await engine.hasStarted)
        controller.stop()
        await controller.prepare(documentPath: path, target: "zh-Hans", engineID: MicrosoftTranslationEngine.engineID, glossary: [], selection: new)
        controller.startAll(engineID: MicrosoftTranslationEngine.engineID, target: "zh-Hans", customEngine: SelectionEngine())
        await engine.complete()
        for _ in 0..<100 where controller.phase != .finished { try await Task.sleep(for: .milliseconds(10)) }
        #expect(controller.paragraphs == [new])
        #expect(controller.state(of: new.id).translation == "Translated: New selection")
        #expect(controller.phase == .finished)
    }

    @Test func selectionDoesNotExtractDocumentAndCacheSurvivesRestart() async throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("selected-\(UUID()).pdf").path
        // Deliberately not a PDF: selection mode must not open or OCR it.
        try Data("fixture".utf8).write(to: URL(fileURLWithPath: path))
        let folder = AppPaths.documentDirectory(forPath: path)
        defer { try? FileManager.default.removeItem(atPath: path); try? FileManager.default.removeItem(at: folder) }
        let paragraph = PDFParagraph(pageIndex: 2, text: "Understanding scientific evidence.", bounds: .zero, lineCount: 1, firstLineOrdinal: 0, isShort: false)
        let controller = PDFTranslationController()
        await controller.prepare(documentPath: path, target: "zh-Hans", engineID: MicrosoftTranslationEngine.engineID, glossary: [], selection: paragraph)
        #expect(controller.paragraphs == [paragraph])
        #expect(controller.phase == .idle)
        controller.startAll(engineID: MicrosoftTranslationEngine.engineID, target: "zh-Hans", customEngine: SelectionEngine())
        for _ in 0..<100 where controller.phase != .finished { try await Task.sleep(for: .milliseconds(10)) }
        #expect(controller.doneCount == 1)
        #expect(!FileManager.default.fileExists(atPath: folder.appendingPathComponent("document-context.json").path))
        let reopened = PDFTranslationController()
        await reopened.prepare(documentPath: path, target: "zh-Hans", engineID: MicrosoftTranslationEngine.engineID, glossary: [], selection: paragraph)
        #expect(reopened.doneCount == 1)
        var different = paragraph
        different.text = "A different word."
        await reopened.prepare(documentPath: path, target: "zh-Hans", engineID: MicrosoftTranslationEngine.engineID, glossary: [], selection: different)
        #expect(reopened.doneCount == 0)
        reopened.clearSelection()
        #expect(reopened.paragraphs.isEmpty)
    }
}

private struct SelectionEngine: TranslationEngine {
    let descriptor = MicrosoftTranslationEngine().descriptor
    func translate(_ text: String, to target: String, from source: String) async throws -> String { "Translated: \(text)" }
}

private actor DelayedSelectionEngine: TranslationEngine {
    nonisolated let descriptor = MicrosoftTranslationEngine().descriptor
    private var continuation: CheckedContinuation<String, Never>?
    var hasStarted: Bool { continuation != nil }
    func translate(_ text: String, to target: String, from source: String) async throws -> String {
        await withCheckedContinuation { continuation = $0 }
    }
    func complete() {
        continuation?.resume(returning: "Late old response")
        continuation = nil
    }
}
