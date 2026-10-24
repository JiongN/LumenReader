import Foundation
import Testing
import LumenKit
@testable import LumenApp

@MainActor
struct CompactEvidenceStorageTests {
    @Test func conversationDeduplicatesEvidenceAndRestoresOldAndNewFormats() throws {
        let citations = (0..<300).map { index in
            DocumentCitation(evidence: .init(id: "p\(index)", path: "/book.pdf", label: "第 \(index + 1) 页", locator: .pdf(page: index, charOffset: 0), text: "source"), version: "v1")
        }
        var conversation = Conversation()
        conversation.bubbles = (0..<20).map { _ in
            var bubble = AIChatModel.Bubble(role: .assistant, text: "answer")
            bubble.evidence = citations
            return bubble
        }
        let encoder = JSONEncoder()
        let before = try encoder.encode(conversation.bubbles)
        let compact = try encoder.encode(conversation)
        #expect(compact.count < before.count / 5)
        let restored = try JSONDecoder().decode(Conversation.self, from: compact)
        #expect(restored.bubbles.allSatisfy { $0.evidence == citations })
        let legacy: [String: Any] = ["bubbles": try JSONSerialization.jsonObject(with: encoder.encode(conversation.bubbles))]
        let old = try JSONSerialization.data(withJSONObject: legacy)
        #expect(try JSONDecoder().decode(Conversation.self, from: old).bubbles.first?.evidence == citations)
        var corrupted = try JSONSerialization.jsonObject(with: compact) as! [String: Any]
        corrupted["evidenceCatalog"] = [:]
        #expect(throws: (any Error).self) { try JSONDecoder().decode(Conversation.self, from: JSONSerialization.data(withJSONObject: corrupted)) }
    }

    @Test func pdfSnapshotStoresOriginalTextOnlyOnceAndRebuildsEvidence() throws {
        let paragraph = PDFParagraph(pageIndex: 0, text: "UNIQUE_ORIGINAL_TEXT", bounds: .zero, lineCount: 1, firstLineOrdinal: 0, isShort: false)
        let context = DocumentContext(version: "v", path: "/a.pdf", evidence: [.init(id: paragraph.id, path: "/a.pdf", label: "第 1 页", locator: .pdf(page: 0, charOffset: 0), text: paragraph.text, pdfFragments: paragraph.fragments)], unitCount: 1)
        let data = try JSONEncoder().encode(PDFContextSnapshot(context: context, paragraphs: [paragraph], ocrPages: []))
        #expect(String(decoding: data, as: UTF8.self).components(separatedBy: paragraph.text).count == 2)
        #expect(try JSONDecoder().decode(PDFContextSnapshot.self, from: data).context.evidence == context.evidence)
    }

    @Test func realPeirceCachePlanningIncludesBeginningMiddleAndEndWithoutNetwork() async throws {
        guard let path = ProcessInfo.processInfo.environment["LUMEN_REAL_CACHE"] else { return }
        let url = URL(fileURLWithPath: path)
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        let original = try Data(contentsOf: url)
        let cached = try JSONDecoder().decode(PDFContextSnapshot.self, from: original)
        let parts = WholeDocumentPlan.parts([cached.context])
        #expect(parts.flatMap(\.evidence).count == cached.context.evidence.count)
        #expect(parts.first?.evidence.first?.locator.pageIndex == 0)
        #expect(parts.last?.evidence.last?.locator.pageIndex == cached.context.unitCount - 1)
        #expect(parts.contains { $0.evidence.contains { $0.locator.pageIndex == 99 } })
        let compact = try JSONEncoder().encode(cached)
        #expect(compact.count <= original.count)
        #expect(try JSONDecoder().decode(PDFContextSnapshot.self, from: compact).context.evidence == cached.context.evidence)
        print("[WholeBookStorage] PDF cache bytes before=\(original.count) after=\(compact.count) parts=\(parts.count) evidence=\(cached.context.evidence.count)")
        guard AppPaths.supportRoot != AppPaths.realSupportRoot else { return }
        let isolated = AppPaths.documentDirectory(forPath: cached.context.path).appendingPathComponent("document-context.json")
        try original.write(to: isolated, options: .atomic)
        let start = Date()
        let upgraded = try await PDFDocumentContextCache().snapshot(path: cached.context.path)
        #expect(upgraded.context.evidence == cached.context.evidence)
        #expect(upgraded.paragraphs == cached.paragraphs)
        print("[WholeBookUpgrade] pages=\(upgraded.context.unitCount) outlineSections=\(upgraded.context.sections.count) elapsedMs=\(Int(Date().timeIntervalSince(start) * 1000))")
    }
}
