import Foundation
import PDFKit
import Testing
import LumenKit
@testable import LumenApp

@Suite("PDF 参考文献版式回归", .serialized)
struct LocalReferenceExtractionTests {
    @Test @MainActor func relationChangeClearsStaleReferenceCount() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("graph.json")
        var graph = LiteratureGraphSnapshot()
        graph.paperID = "local:current"
        graph.papers = [GraphPaper(id: "local:current", doi: nil, title: "当前论文", authors: [], year: nil,
                                  venue: "", abstract: "", openAccessURL: nil, referencedIDs: [], relatedIDs: [], citedByCount: 0),
                       GraphPaper(id: "cnki:related", doi: nil, title: "真实相关论文", authors: [], year: nil,
                                  venue: "", abstract: "", openAccessURL: nil, referencedIDs: [], relatedIDs: [], citedByCount: 0)]
        graph.edges = [.init(source: "local:current", target: "cnki:related", relation: .related, provider: "CNKI")]
        try JSONEncoder().encode(graph).write(to: file)
        let model = LiteratureGraphModel(document: .init(url: directory.appendingPathComponent("paper.pdf"), kind: .pdf), storageURL: file)
        model.message = "参考文献表识别 21 条，图中保留 21 条；本地题录仍需核对。"
        model.selectRelation(.related)
        #expect(model.message.isEmpty)
        #expect(model.visiblePapers.count == 2)
        #expect(!model.busy)
    }

    @Test @MainActor func legacyMetadataUpgradeIsDeferredAndCancellationCannotOverwrite() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("paper.pdf")
        try Data().write(to: url)
        let store = directory.appendingPathComponent("graph.json")
        var graph = LiteratureGraphSnapshot()
        graph.identity = .init(title: "人工核对的论文", source: "人工修订")
        graph.documentModified = try FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date
        let raw = "[1] 王五. 中文知识图谱研究[ J]. 图书情报工作, 2023."
        graph.papers = [GraphPaper(id: "local:reference:old", doi: nil, title: raw, authors: [], year: nil,
                                  venue: "本文参考文献表", abstract: "", openAccessURL: nil, referencedIDs: [], relatedIDs: [], citedByCount: 0)]
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        let original = try encoder.encode(graph)
        try original.write(to: store)
        let model = LiteratureGraphModel(document: .init(url: url, kind: .pdf), storageURL: store)
        #expect(model.snapshot.papers.first?.title == raw)
        model.prepare(metadata: .init())
        model.cancel()
        try await Task.sleep(for: .milliseconds(30))
        #expect(model.snapshot.papers.first?.title == raw)
        model.prepare(metadata: .init())
        for _ in 0..<100 where model.snapshot.papers.first?.sourceCitation == nil { try await Task.sleep(for: .milliseconds(10)) }
        #expect(model.snapshot.papers.first?.title == "中文知识图谱研究")
        #expect(model.snapshot.papers.first?.year == 2023)
        #expect(model.snapshot.identity == graph.identity)
        #expect(try Data(contentsOf: store) == original)
        model.cancel()
    }

    @Test func realChineseBibliographyReadOnly() throws {
        guard let root = ProcessInfo.processInfo.environment["LUMEN_REFERENCE_CORPUS"] else { return }
        let folder = URL(fileURLWithPath: root).appendingPathComponent("LLZIURRD")
        let url = try #require(FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil).first { $0.pathExtension == "pdf" })
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        let start = Date()
        let entries = PDFReferenceExtractor.entries(at: url)
        #expect(entries.count == 21)
        #expect(entries.allSatisfy { $0.year != nil && !$0.authors.isEmpty })
        #expect(Set(entries.flatMap(\.numbers)) == Set(1...32))
        #expect(entries.first { $0.numbers.contains(2) }?.year == 2020)
        #expect(entries.first { $0.numbers.contains(3) }?.year == 1997)
        #expect(entries.first { $0.numbers.contains(4) }?.title == "重新定义符号与符号学")
        #expect(entries.first { $0.numbers.contains(28) }?.title.contains("迈克尔·富兰教师核心能力思想探析") == true)
        #expect(entries.first { $0.numbers.contains(31) }?.authors == ["冯建军"])
        #expect(entries.last?.numbers == [32])
        #expect(entries.allSatisfy { !$0.citation.contains("Abstract") && !$0.citation.contains("责任编辑") && !$0.citation.contains("意义共相即") })
        #expect(try FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date == attributes[.modificationDate] as? Date)
        if let output = ProcessInfo.processInfo.environment["LUMEN_REFERENCE_REPORT"] {
            let report = entries.map { "\($0.numbers)\t\($0.title)\t\($0.authors.joined(separator: "、"))\t\($0.year.map(String.init) ?? "未知")\t\($0.venue)\n\($0.original)" }.joined(separator: "\n\n")
            try report.write(toFile: output, atomically: true, encoding: .utf8)
        }
        print("REFERENCE_CORPUS LLZIURRD entries=\(entries.count) seconds=\(Date().timeIntervalSince(start))")
    }
}
