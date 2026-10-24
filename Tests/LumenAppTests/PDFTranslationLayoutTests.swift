import Foundation
import PDFKit
import Testing
import LumenKit
@testable import LumenApp

@Suite("翻译段落版面回归")
struct PDFTranslationLayoutTests {
    private actor RequestLog {
        var texts: [String] = []
        func append(_ text: String) { texts.append(text) }
    }

    private struct RecordingEngine: TranslationEngine {
        let log: RequestLog
        var descriptor: TranslationEngineDescriptor { MicrosoftTranslationEngine().descriptor }
        func translate(_ text: String, to target: String, from source: String) async throws -> String {
            await log.append(text)
            return "[测试占位译文] " + text
        }
    }

    @Test @MainActor func preparedTranslationKeepsOneCardPerOriginalParagraph() async throws {
        guard let path = ProcessInfo.processInfo.environment["LUMEN_HUMAN_PDF"] else { return }
        let controller = PDFTranslationController()
        let engineID = MicrosoftTranslationEngine.engineID
        await controller.prepare(documentPath: path, target: "zh-Hans", engineID: engineID, glossary: [])
        let body = try #require(controller.paragraphs.first { $0.text.hasPrefix("Although this use") })
        let log = RequestLog()
        controller.resetTranslations()
        controller.startAll(engineID: engineID, target: "zh-Hans", customEngine: RecordingEngine(log: log))
        let deadline = Date().addingTimeInterval(20)
        while controller.phase != .finished, !controller.phase.isFailure, Date() < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        if controller.phase != .finished { controller.stop() }
        #expect(controller.phase == .finished)
        let translation = try #require(controller.state(of: body.id).translation)
        #expect(translation.hasSuffix("should be strictly prohibited."))
        #expect(controller.paragraphs.filter { $0.text.hasPrefix("Although this use") }.count == 1)
        let requests = await log.texts
        #expect(!requests.isEmpty)
        #expect(requests.allSatisfy { $0.count <= TranslationTextSplitter.defaultLimit && !$0.contains("Downloaded from") })
    }

    @Test func suppliedHumanInTheLoopKeepsBodyParagraphsIntact() throws {
        guard let path = ProcessInfo.processInfo.environment["LUMEN_HUMAN_PDF"] else { return }
        let document = try #require(PDFDocument(url: URL(fileURLWithPath: path)))
        let lines = PDFLineExtractor.lines(in: document)
        let paragraphs = PDFParagraphExtractor.paragraphs(from: lines, pageSizes: PDFLineExtractor.pageSizes(in: document))
        if let output = ProcessInfo.processInfo.environment["LUMEN_TEST_OUTPUT"] {
            let directory = URL(fileURLWithPath: output)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(lines).write(to: directory.appendingPathComponent("human-lines.json"), options: .atomic)
            try encoder.encode(paragraphs).write(to: directory.appendingPathComponent("human-paragraphs.json"), options: .atomic)
        }
        let body = try #require(paragraphs.first { $0.text.hasPrefix("Although this use") })
        #expect(body.text.contains("should be strictly prohibited."))
        #expect(!body.text.contains("Downloaded from"))
        #expect(!paragraphs.contains { $0.text.contains("Downloaded from academic.oup.com") })
        #expect(body.lineCount == 19)
        #expect(paragraphs.contains { $0.text.hasPrefix("This attempt to ring-") && $0.text.hasSuffix("as useful and safe as it can be.") })
    }
}
