import Foundation
import Testing
import LumenKit
@testable import LumenApp

@Suite("图谱身份识别取消", .serialized)
@MainActor
struct GraphCancellationTests {
    @Test func changingPaperClearsOldLocalCandidatesAndSelection() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let document = OpenDocument(url: directory.appendingPathComponent("missing.pdf"), kind: .pdf)
        let model = LiteratureGraphModel(document: document, storageURL: directory.appendingPathComponent("graph.json"))
        model.selectedID = "local:old"
        model.updateIdentity(GraphIdentity(title: "新的知网题录", authors: ["张三"], year: 2026, source: "知网题录"))
        #expect(model.selectedID == nil && model.matchingLocalID == nil)
        #expect(model.candidates.isEmpty && model.localCandidates.isEmpty)
        #expect(model.snapshot.papers.isEmpty && model.snapshot.paperID == nil)
    }

    @Test func cancelledPreparationCanRetryWithoutOldResultWinning() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let document = OpenDocument(url: directory.appendingPathComponent("missing.pdf"), kind: .pdf)
        let model = LiteratureGraphModel(document: document, storageURL: directory.appendingPathComponent("graph.json"))
        var old = DocumentMetadata()
        old.title = "cancelled identity"
        model.prepare(metadata: old)
        model.cancel()
        try await Task.sleep(for: .milliseconds(30))
        #expect(model.snapshot.identity.title.isEmpty)
        var fresh = DocumentMetadata()
        fresh.title = "fresh identity"
        model.prepare(metadata: fresh)
        for _ in 0..<50 where model.snapshot.identity.title.isEmpty {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(model.snapshot.identity.title == "fresh identity")
        let saved = LiteratureGraphModel(document: document, storageURL: directory.appendingPathComponent("graph.json"))
        #expect(saved.snapshot.identity.title == "fresh identity")
        model.cancel()
    }
}
