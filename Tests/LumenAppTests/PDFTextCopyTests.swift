import AppKit
import CoreText
import PDFKit
import Testing
@testable import LumenApp

@Suite("后台 PDF 全文复制", .serialized)
@MainActor
struct PDFTextCopyTests {
    @Test func backgroundReadKeepsPageOrderAndCachedOCRWithoutChangingFile() async throws {
        let url = try fixture(pages: 12)
        defer { try? FileManager.default.removeItem(at: url) }
        let original = try Data(contentsOf: url)
        let cached = [1: "Cached OCR on second page", 3: "Cached OCR on fourth page"]
        var finalProgress: TextExtractionProgress?
        let progress: @MainActor (TextExtractionProgress) -> Void = { finalProgress = $0 }
        let worker = Task.detached {
            await PDFTextCopy.read(url: url, cachedOCR: cached, progress: progress)
        }
        let report = try #require(await worker.value)
        #expect(report.totalUnits == 12 && report.textLayerUnits == 6 && report.ocrUnits == 2)
        #expect(report.missingUnits == 4)
        let pieces = report.text.components(separatedBy: "\n\n")
        #expect(Array(pieces.prefix(4)) == [text(1), "Cached OCR on second page", text(3), "Cached OCR on fourth page"])
        #expect(pieces.last == text(11))
        #expect(finalProgress?.completed == 12)
        #expect(try Data(contentsOf: url) == original)
    }

    @Test func cancellationStopsTheWorkerWithoutReturningPartialText() async throws {
        let url = try fixture(pages: 400)
        defer { try? FileManager.default.removeItem(at: url) }
        var callbacks = 0
        let progress: @MainActor (TextExtractionProgress) -> Void = { _ in callbacks += 1 }
        let worker = Task.detached {
            await PDFTextCopy.read(url: url, cachedOCR: [:], progress: progress)
        }
        await Task.yield()
        worker.cancel()
        let report = await worker.value
        #expect(report == nil)
        #expect(callbacks <= 1)
    }

    @Test func realLargePDFReadDoesNotBlockTheMainQueue() async throws {
        guard let path = ProcessInfo.processInfo.environment["LUMEN_COPY_CORPUS_PDF"] else { return }
        let url = URL(fileURLWithPath: path)
        let before = try FileManager.default.attributesOfItem(atPath: path)[.modificationDate] as? Date
        let meter = MainStallMeter()
        meter.start()
        let start = ContinuousClock.now
        let worker = Task.detached(priority: .userInitiated) {
            await PDFTextCopy.read(url: url, cachedOCR: [:]) { _ in }
        }
        let report = try #require(await worker.value)
        let elapsed = start.duration(to: .now)
        let samples = meter.stop().sorted()
        #expect(report.totalUnits > 300)
        #expect(!report.isEmpty)
        #expect(samples.count > 0)
        #expect(try FileManager.default.attributesOfItem(atPath: path)[.modificationDate] as? Date == before)
        let p95 = samples.isEmpty ? 0 : samples[min(samples.count - 1, Int(Double(samples.count) * 0.95))]
        let result = "Pages=\(report.totalUnits) textLayer=\(report.textLayerUnits) missing=\(report.missingUnits) chars=\(report.text.count) elapsed=\(elapsed) mainSamples=\(samples.count) P95=\(p95)ms max=\(samples.last ?? 0)ms\n"
        print("[PDF copy] \(result)")
        if let output = ProcessInfo.processInfo.environment["LUMEN_COPY_REPORT"] {
            try result.write(toFile: output, atomically: true, encoding: .utf8)
        }
    }

    private func text(_ page: Int) -> String { "Page \(page) complete text with enough native characters" }

    private func fixture(pages: Int) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("copy-worker-\(UUID()).pdf")
        let data = NSMutableData()
        guard let consumer = CGDataConsumer(data: data), let context = CGContext(consumer: consumer, mediaBox: nil, nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        for index in 0..<pages {
            context.beginPDFPage(nil)
            if index.isMultiple(of: 2) {
                let string = NSAttributedString(string: text(index + 1), attributes: [.font: NSFont.systemFont(ofSize: 10)])
                context.textPosition = .init(x: 30, y: 500)
                CTLineDraw(CTLineCreateWithAttributedString(string), context)
            }
            context.endPDFPage()
        }
        context.closePDF()
        try (data as Data).write(to: url)
        return url
    }
}
