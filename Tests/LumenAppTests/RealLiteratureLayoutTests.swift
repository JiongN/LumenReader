import Foundation
import PDFKit
import Testing
import LumenKit
@testable import LumenApp

@Suite("真实文献版面回归", .serialized)
struct RealLiteratureLayoutTests {
    @Test func harrisAbstractSidebar() async throws {
        guard let root = ProcessInfo.processInfo.environment["LUMEN_ZOTERO_CORPUS"] else { return }
        let source = URL(fileURLWithPath: root).appendingPathComponent("UZAHDDK9")
        let path = try #require(FileManager.default.contentsOfDirectory(at: source, includingPropertiesForKeys: nil)
            .first { $0.pathExtension.lowercased() == "pdf" })
        let document = try #require(PDFDocument(url: path))
        let lines = PDFLineExtractor.lines(in: document, pageRange: 1...1)
        let cache = PDFDocumentContextCache()
        let snapshot = try await cache.snapshot(path: path.path, pageRange: 1...1)
        if let output = ProcessInfo.processInfo.environment["LUMEN_CORPUS_OUTPUT"] {
            let directory = URL(fileURLWithPath: output)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try JSONEncoder().encode(lines).write(to: directory.appendingPathComponent("harris-lines.json"))
            try JSONEncoder().encode(snapshot).write(to: directory.appendingPathComponent("harris-snapshot.json"))
            try (document.page(at: 1)?.string ?? "").write(to: directory.appendingPathComponent("harris-native.txt"), atomically: true, encoding: .utf8)
        }
        let abstract = try #require(snapshot.paragraphs.first { $0.text.contains("Using the notion of risk aversion") })
        #expect(abstract.text.contains("students’ experience of the curriculum."))
        #expect(abstract.text.contains("decisions teachers make"))
        #expect(abstract.text.contains("Five key categories were identified"))
        #expect(abstract.text.contains("approach to curriculum change"))
        #expect(!abstract.text.contains("\n"))
        #expect(!abstract.text.contains("Risk taking;"))
        #expect(snapshot.paragraphs.contains { $0.text.contains("Risk taking;") && $0.text.contains("curriculum construction") })
        #expect(await cache.ocrInvocationCount() == 0)
        #expect(PDFTranslationMaterial.complexPages(snapshot.paragraphs).contains(1))
        let whole = try await cache.snapshot(path: path.path)
        #expect(try await TranslationSourceResolver().resolve(texts: whole.paragraphs.map(\.text)) == "en")
    }

    @Test func zoteroCorpus() async throws {
        guard let root = ProcessInfo.processInfo.environment["LUMEN_ZOTERO_CORPUS"],
              let output = ProcessInfo.processInfo.environment["LUMEN_CORPUS_OUTPUT"] else { return }
        let directory = URL(fileURLWithPath: output)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for key in ["WP8N3WSH", "DLXGQBEU", "3DATXAFX", "J45XJZY4", "QNHFHAPW"] {
            let source = URL(fileURLWithPath: root).appendingPathComponent(key)
            let path = try #require(FileManager.default.contentsOfDirectory(at: source, includingPropertiesForKeys: nil)
                .first { $0.pathExtension.lowercased() == "pdf" })
            let snapshot = try await PDFDocumentContextCache().snapshot(path: path.path)
            #expect(snapshot.context.missingUnits.isEmpty)
            #expect(snapshot.paragraphs.count > 10)
            if key == "3DATXAFX" {
                let abstract = try #require(snapshot.paragraphs.first { $0.text.hasPrefix("The integrating AI") })
                #expect(abstract.lineCount == 15)
                #expect(abstract.text.hasSuffix("promoting the effective integration of AI into teaching and learning."))
                #expect(!snapshot.context.text.contains("1234567890"))
                let first = try #require(snapshot.paragraphs.first { $0.text.hasPrefix("First, teachers establish") })
                #expect(first.text.contains("teaching expertise and collaboration skills"))
                #expect(first.text.hasSuffix("during this process."))
                #expect(!first.text.contains("Fig. 1"))
                let table = try #require(snapshot.paragraphs.first { $0.pageIndex == 6 && $0.kind == .table })
                #expect(table.text.contains("Teacher\tX1\tGuiding"))
                #expect(table.text.contains("Supporting technology\tX9"))
                #expect(table.bounds.width < table.bounds.height)
                #expect(snapshot.paragraphs.filter { $0.pageIndex == 7 && $0.kind == .table }.allSatisfy { !$0.text.contains("Results") })
                #expect(snapshot.context.text.contains("and learning, knowledge exploration, video learning, teaching and"))
            }
            if key == "J45XJZY4" {
                let abstract = try #require(snapshot.paragraphs.first { $0.text.hasPrefix("摘 要") })
                #expect(abstract.lineCount == 5)
                let theory = try #require(snapshot.paragraphs.first { $0.pageIndex == 2 && $0.text.contains("开始以跨学科") })
                #expect(theory.text.contains("学术研究形式发展。 ① 通过跨学科的发展以及国际学会"))
                #expect(!snapshot.paragraphs.contains { $0.text.hasPrefix("４３") || $0.text == "５３" || $0.text == "·" })
            }
            if key == "QNHFHAPW" {
                let table = try #require(snapshot.paragraphs.first { $0.pageIndex == 2 && $0.kind == .table })
                #expect(table.text.contains("Chen and Huang"))
                #expect(table.text.contains("Controlled variable"))
            }
            let doc = try #require(PDFDocument(url: path))
            let lines = PDFLineExtractor.lines(in: doc)
            try JSONEncoder().encode(lines).write(to: directory.appendingPathComponent(key + "-lines.json"))
            try JSONEncoder().encode(snapshot).write(to: directory.appendingPathComponent(key + "-snapshot.json"))
            let text = snapshot.paragraphs.map { "[p\($0.pageIndex + 1) lines=\($0.lineCount)] \($0.text)" }.joined(separator: "\n\n")
            try text.write(to: directory.appendingPathComponent(key + ".txt"), atomically: true, encoding: .utf8)
            print("CORPUS \(key) pages=\(doc.pageCount) lines=\(lines.count) paragraphs=\(snapshot.paragraphs.count) chars=\(snapshot.context.text.count) ocr=\(snapshot.ocrPages)")
        }
    }

    @Test func baselineFragmentsJoinWithoutJoiningSeparateColumns() {
        let lines: [PDFTextLine] = [
            .init(pageIndex: 0, text: "一句正文", bounds: CGRect(x: 40, y: 550, width: 100, height: 12)),
            .init(pageIndex: 0, text: "① 后半句话。", bounds: CGRect(x: 137, y: 551, width: 100, height: 11)),
            .init(pageIndex: 0, text: "右栏另一句。", bounds: CGRect(x: 280, y: 550, width: 200, height: 12))
        ]
        let result = PDFLineExtractor.coalesceFragments(lines)
        #expect(result.count == 2)
        #expect(result[0].text == "一句正文 ① 后半句话。")
        #expect(result[1].text == "右栏另一句。")
    }

    @Test func asymmetricSidebarBeyondCentralGridDoesNotSplitProse() throws {
        var lines = (0..<16).map { index in
            PDFTextLine(pageIndex: 0, text: index == 15 ? "the end of the abstract." : "Connected prose continues on the next visual line",
                bounds: CGRect(x: 60, y: 495 - index * 10, width: 277, height: 9))
        }
        let keywords = ["KEYWORDS", "Risk taking; risk aversion;", "teachers’ decision-making;", "curriculum construction"]
        lines += keywords.enumerated().map { index, text in
            PDFTextLine(pageIndex: 0, text: text, bounds: CGRect(x: 355, y: 505 - index * 9, width: 82, height: 8))
        }
        let result = PDFParagraphExtractor.paragraphs(from: lines)
        #expect(result.count == 2)
        #expect(result[0].lineCount == 16)
        #expect(result[0].text.hasSuffix("the end of the abstract."))
        #expect(result[1].text == keywords.joined(separator: " "))
    }
}
