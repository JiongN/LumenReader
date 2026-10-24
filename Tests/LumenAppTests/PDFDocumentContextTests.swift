import AppKit
import CoreText
import CryptoKit
import PDFKit
import Testing
import Synchronization
import LumenKit
@testable import LumenApp

@Suite("PDF 文档上下文缓存", .serialized)
@MainActor
struct PDFDocumentContextTests {
    private func imageDigests(_ page: PDFPage) -> Set<String> {
        var digests = Set<String>()
        func visit(_ dictionary: CGPDFDictionaryRef?, depth: Int) {
            guard depth < 16, let dictionary else { return }
            var resources: CGPDFDictionaryRef?, objects: CGPDFDictionaryRef?
            guard CGPDFDictionaryGetDictionary(dictionary, "Resources", &resources),
                  let resources, CGPDFDictionaryGetDictionary(resources, "XObject", &objects), let objects else { return }
            CGPDFDictionaryApplyBlock(objects, { _, object, _ in
                var stream: CGPDFStreamRef?
                guard CGPDFObjectGetValue(object, .stream, &stream), let stream else { return true }
                guard let attributes = CGPDFStreamGetDictionary(stream) else { return true }
                var subtype: UnsafePointer<CChar>?
                if CGPDFDictionaryGetName(attributes, "Subtype", &subtype), let subtype, String(cString: subtype) == "Image" {
                    var format = CGPDFDataFormat.raw
                    if let data = CGPDFStreamCopyData(stream, &format) {
                        digests.insert(String(describing: SHA256.hash(data: data as Data)))
                    }
                } else { visit(attributes, depth: depth + 1) }
                return true
            }, nil)
        }
        visit(page.pageRef?.dictionary, depth: 0)
        return digests
    }

    private func fixture() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("lumen-layout-\(UUID()).pdf")
        var bounds = CGRect(x: 0, y: 0, width: 600, height: 800)
        let context = try #require(CGContext(url as CFURL, mediaBox: &bounds, nil))
        context.beginPDFPage(nil)
        for (x, name) in [(CGFloat(40), "Left"), (CGFloat(320), "Right")] {
            for row in 0..<6 {
                context.textPosition = CGPoint(x: x, y: CGFloat(700 - row * 18))
                let text = NSAttributedString(string: "\(name) paragraph line \(row) continues", attributes: [.font: NSFont.systemFont(ofSize: 12)])
                CTLineDraw(CTLineCreateWithAttributedString(text), context)
            }
        }
        context.endPDFPage(); context.closePDF()
        return url
    }

    @Test func sharedExtractionPersistsAcrossInstancesAndInvalidatesOnFileChange() async throws {
        let url = try fixture()
        defer { try? FileManager.default.removeItem(at: url) }
        let cache = PDFDocumentContextCache()
        async let first = cache.snapshot(path: url.path)
        async let second = cache.snapshot(path: url.path)
        let (a, b) = try await (first, second)
        #expect(await cache.ocrInvocationCount() == 0)
        #expect(a.context == b.context)
        #expect(a.context.text.contains("Left paragraph line 0 continues Left paragraph line 1"))
        #expect(a.context.text.range(of: "Left paragraph line 5")!.lowerBound < a.context.text.range(of: "Right paragraph line 0")!.lowerBound)
        let file = AppPaths.documentDirectory(forPath: url.path).appendingPathComponent("document-context.json")
        let before = try FileManager.default.attributesOfItem(atPath: file.path)[.modificationDate] as? Date
        let restarted = try await PDFDocumentContextCache().snapshot(path: url.path)
        #expect(restarted.context == a.context)
        #expect(try FileManager.default.attributesOfItem(atPath: file.path)[.modificationDate] as? Date == before)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(10)], ofItemAtPath: url.path)
        let changed = try await cache.snapshot(path: url.path)
        #expect(changed.context.version != a.context.version)
    }

    @Test func scannedPageUsesOCRAndPageGeometry() async throws {
        let textURL = try fixture()
        let scanURL = FileManager.default.temporaryDirectory.appendingPathComponent("lumen-scan-\(UUID()).pdf")
        defer { try? FileManager.default.removeItem(at: textURL); try? FileManager.default.removeItem(at: scanURL) }
        let text = try #require(PDFDocument(url: textURL))
        let image = try #require(PDFPageRenderer.render(text.page(at: 0)!, scale: 2))
        let scan = PDFDocument()
        let page = try #require(PDFPage(image: NSImage(cgImage: image, size: CGSize(width: 600, height: 800))))
        page.setBounds(CGRect(x: 0, y: 0, width: 600, height: 800), for: .mediaBox)
        scan.insert(page, at: 0)
        try #require(scan.write(to: scanURL))
        let result = try await PDFDocumentContextCache().snapshot(path: scanURL.path)
        #expect(result.ocrPages == [0])
        #expect(result.context.text.contains("Left paragraph"))
        #expect(result.paragraphs.allSatisfy { $0.bounds.maxX <= 601 && $0.bounds.maxY <= 801 })
    }

    @Test func aNativePageNumberCannotHideTheScannedBody() async throws {
        let textURL = try fixture()
        let scanURL = FileManager.default.temporaryDirectory.appendingPathComponent("lumen-scan-number-\(UUID()).pdf")
        defer { try? FileManager.default.removeItem(at: textURL); try? FileManager.default.removeItem(at: scanURL) }
        let text = try #require(PDFDocument(url: textURL))
        let sourcePage = try #require(text.page(at: 0))
        let image = try #require(PDFPageRenderer.render(sourcePage, scale: 2))
        var box = CGRect(x: 0, y: 0, width: 600, height: 800)
        let writer = try #require(CGContext(scanURL as CFURL, mediaBox: &box, nil))
        writer.beginPDFPage(nil)
        writer.draw(image, in: box)
        writer.textPosition = CGPoint(x: 290, y: 15)
        CTLineDraw(CTLineCreateWithAttributedString(NSAttributedString(string: "7", attributes: [.font: NSFont.systemFont(ofSize: 12)])), writer)
        writer.endPDFPage(); writer.closePDF()
        let page = try #require(PDFDocument(url: scanURL)?.page(at: 0))
        #expect(page.string?.trimmingCharacters(in: .whitespacesAndNewlines) == "7")
        #expect(PDFScanDetector.needsOCR(page, textLayer: page.string ?? ""))
        let cache = PDFDocumentContextCache()
        let result = try await cache.snapshot(path: scanURL.path)
        #expect(await cache.ocrInvocationCount() == 1)
        #expect(result.context.text.contains("Left paragraph"))
    }

    @Test func suppliedMesseriPaperPreservesAbstractGlossaryAndBoxReadingOrder() async throws {
        guard let path = ProcessInfo.processInfo.environment["LUMEN_TEST_PDF"] else { return }
        let snapshot = try await PDFDocumentContextCache.shared.snapshot(path: path)
        #expect(snapshot.context.unitCount == 10)
        #expect(snapshot.ocrPages.isEmpty)
        #expect(await PDFDocumentContextCache.shared.ocrInvocationCount() == 0)
        #expect(snapshot.context.missingUnits.isEmpty)
        let p1 = snapshot.paragraphs.filter { $0.pageIndex == 0 }.map(\.text).joined(separator: "\n\n")
        let p2 = snapshot.paragraphs.filter { $0.pageIndex == 1 }.map(\.text).joined(separator: "\n\n")
        let p3 = snapshot.paragraphs.filter { $0.pageIndex == 2 }.map(\.text).joined(separator: "\n\n")
        #expect(p1.contains("Scientists are enthusiastically imagining ways in which artificial intelligence"))
        #expect(p2.contains("Cognitive diversity means differences in how people think and approach a problem."))
        let cognitive = try #require(p2.range(of: "Cognitive diversity"))
        let illusions = try #require(p2.range(of: "Illusions of understanding"))
        #expect(cognitive.lowerBound < illusions.lowerBound)
        #expect(p3.contains("AI visions as sociotechnical visions"))
        #expect(snapshot.context.text.contains("Oracles"))
        #expect(snapshot.context.text.contains("Surrogates"))
        #expect(snapshot.context.text.contains("Quants"))
        #expect(snapshot.context.text.contains("Arbiters"))
        if let output = ProcessInfo.processInfo.environment["LUMEN_TEST_OUTPUT"] {
            let dir = URL(fileURLWithPath: output)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try snapshot.context.text.write(to: dir.appendingPathComponent("messeri-structured-text.txt"), atomically: true, encoding: .utf8)
            try JSONEncoder().encode(snapshot).write(to: dir.appendingPathComponent("messeri-snapshot.json"), options: .atomic)
        }
        print("MESSERI_CONTEXT paragraphs=\(snapshot.paragraphs.count) chars=\(snapshot.context.text.count) estimatedTokens=\(ContextBudget.estimatedTokens(snapshot.context.text))")
    }

    @Test func oldLayoutIsRebuiltWithoutRunningOCR() async throws {
        let url = try fixture()
        defer { try? FileManager.default.removeItem(at: url) }
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        let version = "layout-10:\(attrs[.size] ?? 0):\((attrs[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0):\((attrs[.creationDate] as? Date)?.timeIntervalSince1970 ?? 0)"
        let paragraph = PDFParagraph(pageIndex: 0, text: "OLD_BROKEN_LAYOUT", bounds: .zero, lineCount: 1, firstLineOrdinal: 0, isShort: false)
        let original = PDFContextSnapshot(context: .init(version: version, path: url.path, evidence: [], unitCount: 1), paragraphs: [paragraph], ocrPages: [])
        let file = AppPaths.documentDirectory(forPath: url.path).appendingPathComponent("document-context.json")
        try JSONEncoder().encode(original).write(to: file, options: .atomic)
        let cache = PDFDocumentContextCache()
        let upgraded = try await cache.snapshot(path: url.path)
        #expect(upgraded.context.version.hasPrefix(PDFDocumentContextCache.parserVersion + ":"))
        #expect(!upgraded.context.text.contains(paragraph.text))
        #expect(upgraded.context.text.contains("Left paragraph line"))
        #expect(await cache.ocrInvocationCount() == 0)
        #expect(upgraded.ocrPages.isEmpty)
    }

    @Test func oldLayoutRetainsUnwrittenOCRCheckpoint() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("lumen-pending-ocr-\(UUID()).pdf")
        let document = PDFDocument(), page = PDFPage()
        page.setBounds(CGRect(x: 0, y: 0, width: 600, height: 800), for: .mediaBox)
        document.insert(page, at: 0)
        #expect(document.write(to: url))
        defer { try? FileManager.default.removeItem(at: url) }
        let version = "layout-10:" + (try PDFDocumentContextCache.fileIdentity(path: url.path))
        let line = PDFTextLine(pageIndex: 0, text: "OCR_CHECKPOINT_MUST_SURVIVE", bounds: CGRect(x: 40, y: 500, width: 400, height: 18))
        var original = PDFContextSnapshot(context: .init(version: version, path: url.path, evidence: [], unitCount: 1), paragraphs: [], ocrPages: [0])
        original.pendingOCRLines = [line]
        let file = AppPaths.documentDirectory(forPath: url.path).appendingPathComponent("document-context.json")
        try JSONEncoder().encode(original).write(to: file, options: .atomic)
        let cache = PDFDocumentContextCache()
        let upgraded = try await cache.snapshot(path: url.path)
        #expect(upgraded.context.text.contains(line.text))
        #expect(await cache.ocrInvocationCount() == 0)
        #expect(upgraded.pendingOCRLines == nil)
    }

    @Test func completedCheckpointPagesSurviveRestartWithoutReprocessing() async throws {
        let url = try fixture()
        defer { try? FileManager.default.removeItem(at: url) }
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        let version = "\(PDFDocumentContextCache.parserVersion):\(attrs[.size] ?? 0):\((attrs[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0):\((attrs[.creationDate] as? Date)?.timeIntervalSince1970 ?? 0)"
        let line = PDFTextLine(pageIndex: 0, text: "OCR_CHECKPOINT_MUST_SURVIVE", bounds: CGRect(x: 40, y: 500, width: 400, height: 18))
        let checkpoint = PDFExtractionCheckpoint(version: version, pageCount: 1,
            pages: [0: .init(lines: [line], size: CGSize(width: 600, height: 800), usedOCR: true, verifyRemaining: true)])
        let file = AppPaths.documentDirectory(forPath: url.path).appendingPathComponent("document-context-progress.json")
        try JSONEncoder().encode(checkpoint).write(to: file, options: .atomic)
        let snapshot = try await PDFDocumentContextCache().snapshot(path: url.path)
        #expect(snapshot.context.text.contains(line.text))
        #expect(snapshot.ocrPages == [0])
        #expect(!FileManager.default.fileExists(atPath: file.path))
        #expect(FileManager.default.fileExists(atPath: file.deletingLastPathComponent().appendingPathComponent("document-context.json").path))
    }

    @Test func realScannedHistorySamplesUseLocalOCR() async throws {
        guard let path = ProcessInfo.processInfo.environment["LUMEN_SCAN_PDF"] else { return }
        let original = try #require(PDFDocument(url: URL(fileURLWithPath: path)))
        let sample = PDFDocument()
        let indices = (Array(10..<16) + Array(100..<103) + Array(200..<203)).filter { $0 < original.pageCount }
        for index in indices {
            if let page = original.page(at: index)?.copy() as? PDFPage { sample.insert(page, at: sample.pageCount) }
        }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("lumen-history-scan-\(UUID()).pdf")
        defer { try? FileManager.default.removeItem(at: url) }
        try #require(sample.write(to: url))
        let beforeBytes = (try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.intValue ?? 0
        let onDisk = try #require(PDFDocument(url: url))
        let imagesBefore = try (0..<onDisk.pageCount).map { index in
            imageDigests(try #require(onDisk.page(at: index)))
        }
        let running = Mutex<Task<PDFContextSnapshot, Error>?>(nil)
        let task = Task {
            try await PDFDocumentContextCache().snapshot(path: url.path, progress: { value in
                if value.completed >= 3 { running.withLock { $0?.cancel() } }
            })
        }
        running.withLock { $0 = task }
        do { _ = try await task.value; Issue.record("Expected OCR cancellation") }
        catch { #expect(error is CancellationError || (error as? AIError) == .cancelled) }
        running.withLock { $0 = nil }
        let checkpointFile = AppPaths.documentDirectory(forPath: url.path).appendingPathComponent("document-context-progress.json")
        let partial = try JSONDecoder().decode(PDFExtractionCheckpoint.self, from: Data(contentsOf: checkpointFile))
        #expect(partial.pages.count >= 3 && partial.pages.count < indices.count)
        let snapshot = try await PDFDocumentContextCache().snapshot(path: url.path)
        #expect(snapshot.context.unitCount == indices.count)
        #expect(snapshot.ocrPages.count == indices.count)
        #expect(snapshot.context.missingUnits.isEmpty)
        #expect(snapshot.context.evidence.count > 3)
        #expect(snapshot.context.extractionNote == nil)
        #expect(snapshot.pendingOCRLines == nil)
        let searchable = try #require(PDFDocument(url: url))
        #expect(PDFSearchableWriter.completedPages(in: searchable).count == indices.count)
        #expect((0..<searchable.pageCount).allSatisfy { !(searchable.page(at: $0)?.string ?? "").isEmpty })
        for index in 0..<searchable.pageCount {
            let page = try #require(searchable.page(at: index))
            #expect(!imagesBefore[index].isEmpty)
            #expect(imageDigests(page) == imagesBefore[index])
        }
        #expect(!FileManager.default.fileExists(atPath: checkpointFile.path))
        if let output = ProcessInfo.processInfo.environment["LUMEN_TEST_OUTPUT"] {
            let directory = URL(fileURLWithPath: output)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: url, to: directory.appendingPathComponent("history-searchable.pdf"))
            for (name, document) in [("before", onDisk), ("after", searchable)] {
                let page = try #require(document.page(at: 0))
                let image = try #require(PDFPageRenderer.render(page, scale: 1))
                let png = try #require(NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]))
                try png.write(to: directory.appendingPathComponent("history-\(name).png"), options: .atomic)
            }
        }
        try FileManager.default.removeItem(at: checkpointFile.deletingLastPathComponent().appendingPathComponent("document-context.json"))
        let restarted = try await PDFDocumentContextCache().snapshot(path: url.path)
        #expect(restarted.ocrPages.isEmpty)
        #expect(restarted.context.missingUnits.isEmpty)
        #expect(restarted.context.text.count > 10_000)
        let afterBytes = (try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.intValue ?? 0
        print("SCAN_REAL originalPages=\(original.pageCount) samplePages=\(indices.count) cancelledCompleted=\(partial.pages.count) resumedChars=\(snapshot.context.text.count) paragraphs=\(snapshot.context.evidence.count) fileBytes=\(beforeBytes)->\(afterBytes)")
    }
}
