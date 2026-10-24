import Foundation
import PDFKit
import AppKit
import Testing
import LumenKit
@testable import LumenApp

@Suite("文档智能集成", .serialized)
@MainActor
struct DocumentIntelligenceIntegrationTests {
    @Test func hierarchyKeepsAllLeavesAndReusesDurableNodes() async throws {
        let path = "/hierarchy-\(UUID().uuidString).pdf"
        let context = DocumentContext(version: "one", path: path, evidence: (0..<40).map { index in
            .init(id: "p\(index)", path: path, label: "第 \(index + 1) 页", locator: .pdf(page: index, charOffset: 0),
                text: String(repeating: "Source \(index) has qualified evidence and limitations. ", count: 200))
        }, unitCount: 40, sections: (0..<40).map { .init(title: "Section \($0)", startUnit: $0, endUnit: $0) })
        var ids: [String] = []
        let config = AIProviderConfig(name: "mock", baseURL: "http://localhost", models: ["one"], selectedModel: "one", maxTokens: 512, contextWindow: 16384)
        let planner = DocumentMaterialPlanner(complete: { messages, _ in
            let system = messages[0].content
            let expression = try NSRegularExpression(pattern: "\\\"partID\\\":\\\"([^\\\"]+)\\\"")
            let match = try #require(expression.firstMatch(in: system, range: NSRange(system.startIndex..., in: system)))
            let range = try #require(Range(match.range(at: 1), in: system))
            let id = String(system[range]); ids.append(id)
            let result = SectionDigest(partID: id, summary: String(repeating: "Evidence and limitations. ", count: 30))
            return String(decoding: try JSONEncoder().encode(result), as: UTF8.self)
        }, progress: { _ in })
        let first = try await planner.prepare(documents: [context], original: context.text, query: "", review: true,
            allowance: 5000, config: config)
        #expect(first.requiredSections.count == 40)
        #expect(Set(ids.filter { $0.hasPrefix("D1S") }).count == 40)
        #expect(ids.contains { $0.hasPrefix("L") })
        #expect(first.coverage.contains("40/40"))
        #expect(ContextBudget.estimatedTokens(first.text) <= 5000)
        let calls = ids.count
        let second = try await planner.prepare(documents: [context], original: context.text, query: "", review: true,
            allowance: 5000, config: config)
        #expect(ids.count == calls)
        #expect(second.text == first.text)
    }

    @Test func lightweightAnnotationsKeepQuadsColorAndIdentity() throws {
        let document = PDFDocument()
        let page = PDFPage()
        document.insert(page, at: 0)
        let annotation = try #require(PDFAnnotationGeometry.makeHighlight(rectangles: [CGRect(x: 30, y: 500, width: 190, height: 16), CGRect(x: 30, y: 480, width: 100, height: 16)],
            note: "note", color: NSColor(srgbRed: 0.2, green: 0.8, blue: 0.4, alpha: 0.45), author: PDFController.annotationAuthor))
        page.addAnnotation(annotation)
        let snapshot = try PDFLargeAnnotationSave.capture(document: document, pages: [0])
        let record = try JSONDecoder().decode(PDFAnnotationRecord.self, from: #require(snapshot.first?.annotations.first))
        let recovered = try PDFLargeAnnotationSave.annotation(from: record)
        #expect(recovered.contents == "note")
        #expect(recovered.quadrilateralPoints?.count == 8)
        #expect(recovered.value(forAnnotationKey: PDFAnnotationGeometry.identityKey) as? String == record.identity)
        #expect(abs((recovered.color.usingColorSpace(.sRGB)?.greenComponent ?? 0) - 0.8) < 0.001)
        #expect(record.shouldDisplay)
    }

    @Test func helperWritesAnnotationToIsolatedPDFCopy() throws {
        let root = AppPaths.supportRoot.appendingPathComponent("helper-roundtrip-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("fixture.pdf")
        let source = PDFDocument(), page = PDFPage()
        source.insert(page, at: 0)
        #expect(source.write(to: url))
        let live = try #require(PDFDocument(url: url))
        let highlight = try #require(PDFAnnotationGeometry.makeHighlight(rectangles: [CGRect(x: 24, y: 250, width: 140, height: 18)],
            note: "helper test", color: NSColor(srgbRed: 0.15, green: 0.65, blue: 0.35, alpha: 0.5), author: PDFController.annotationAuthor))
        live.page(at: 0)?.addAnnotation(highlight)
        let pageSnapshot = try PDFLargeAnnotationSave.capture(document: live, pages: [0])
        let fingerprint = try PDFLargeAnnotationSave.fingerprint(of: url)
        _ = try PDFLargeAnnotationSave.writeWithHelper(url: url, expectedPages: 1, pages: pageSnapshot, expected: fingerprint)
        let saved = try #require(PDFDocument(url: url)?.page(at: 0)?.annotations.first(where: { $0.userName == PDFController.annotationAuthor }))
        #expect(saved.contents == "helper test")
        #expect(saved.quadrilateralPoints?.count == 4)
        #expect(abs((saved.color.usingColorSpace(.sRGB)?.greenComponent ?? 0) - 0.65) < 0.01)
    }

    @Test func conversationDigestSurvivesRestartAndRejectsEditedPrefix() throws {
        let source = [AIMessage.user("用户要求 A"), .assistant("答复 A")]
        let digest = ConversationDigest(prefixHash: ConversationDigest.hash(source), messageCount: 2, text: "用户要求 A")
        let store = ConversationStore()
        let id = store.createConversation(sourcePath: nil, sourceTitle: nil)
        store.updateContext(id: id, digest: digest)
        let data = try JSONEncoder().encode(#require(store.conversation(id: id)))
        let restored = try JSONDecoder().decode(Conversation.self, from: data)
        #expect(restored.digest == digest)
        #expect(digest.prefixHash != ConversationDigest.hash([.user("改为 B"), .assistant("答复 A")]))
    }

    @Test func tableSpansDoNotBecomeFalseColumns() throws {
        let cells = try #require(StructuredTable.cells(html: "<table><tr><th rowspan=\"2\">Group</th><th>Value</th></tr><tr><td>17</td></tr></table>"))
        #expect(cells.count == 3)
        #expect(cells[0].rowSpan == 2)
        #expect(cells[2].column == 1)
        #expect(cells[2].text == "17")
        #expect(StructuredTable.cells(html: "<!DOCTYPE x [<!ENTITY x SYSTEM 'file:///etc/passwd'>]><table><tr><td>&x;</td></tr></table>") == nil)
    }
}
