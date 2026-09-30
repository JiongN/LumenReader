import Foundation
import Testing
@testable import LumenKit

@Suite("文献图谱身份、关系与接口")
struct LiteratureGraphTests {
    private func paper(_ id: String, doi: String? = nil) -> GraphPaper {
        GraphPaper(id: "https://openalex.org/\(id)", doi: doi, title: id, authors: [], year: 2024, venue: "", abstract: "", openAccessURL: nil, referencedIDs: [], relatedIDs: [], citedByCount: 0)
    }

    @Test("DOI 规范化且不会把无效字符串当 DOI")
    func doiNormalization() {
        #expect(GraphIdentity.normalizedDOI(" HTTPS://DOI.ORG/10.1234/ABC. ") == "10.1234/abc")
        #expect(GraphIdentity.normalizedDOI("article-123") == nil)
    }

    @Test("缓存日期往返一致，缺字段可默认，坏字段须报错")
    func snapshotCoding() throws {
        var snapshot = LiteratureGraphSnapshot()
        snapshot.fetchedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let restored = try decoder.decode(LiteratureGraphSnapshot.self, from: encoder.encode(snapshot))
        #expect(restored.fetchedAt == snapshot.fetchedAt)
        #expect(try decoder.decode(LiteratureGraphSnapshot.self, from: Data("{}".utf8)).papers.isEmpty)
        #expect(try decoder.decode(LiteratureGraphSnapshot.self, from: Data("{}".utf8)).pinnedPositionIDs.isEmpty)
        #expect(try decoder.decode(LiteratureGraphSnapshot.self, from: Data("{}".utf8)).layoutVersion == 0)
        #expect(throws: Error.self) {
            _ = try decoder.decode(LiteratureGraphSnapshot.self, from: Data(#"{"papers":"corrupt"}"#.utf8))
        }
    }

    @Test("手动节点位置随图谱缓存保存，确认本地引文后转移固定位置")
    func pinnedNodePosition() throws {
        var snapshot = LiteratureGraphSnapshot()
        let localID = "local:reference:a"
        snapshot.papers = [GraphPaper(id: localID, doi: nil, title: "中文文献", authors: [], year: nil,
            venue: "", abstract: "", openAccessURL: nil, referencedIDs: [], relatedIDs: [], citedByCount: 0)]
        snapshot.positions[localID] = GraphPosition(x: 240, y: -135)
        snapshot.pinnedPositionIDs.insert(localID)
        let restored = try JSONDecoder().decode(LiteratureGraphSnapshot.self, from: JSONEncoder().encode(snapshot))
        #expect(restored.positions[localID] == GraphPosition(x: 240, y: -135))
        #expect(restored.pinnedPositionIDs.contains(localID))
        let remote = paper("W99")
        GraphMerge.resolveLocalReference(localID, with: remote, in: &snapshot)
        #expect(snapshot.positions[remote.id] == GraphPosition(x: 240, y: -135))
        #expect(snapshot.pinnedPositionIDs == [remote.id])
    }

    @Test("按 OpenAlex ID 和 DOI 去重，方向不同的引用仍各自保留")
    func mergeAndDirection() {
        var snapshot = LiteratureGraphSnapshot()
        let a = paper("W1", doi: "10.1234/a")
        let b = paper("W2")
        let duplicate = paper("W3", doi: "https://doi.org/10.1234/A")
        GraphMerge.add([a, b, duplicate], edges: [GraphEdge(source: b.id, target: duplicate.id, relation: .citation)], to: &snapshot)
        #expect(snapshot.papers.count == 2)
        #expect(snapshot.edges.first?.source == b.id)
        #expect(snapshot.edges.first?.target == a.id)
    }

    @Test("已加载论文之间的 OpenAlex 参考文献形成引用边，主题相关关系不冒充引用")
    func knownCrossLinks() {
        var snapshot = LiteratureGraphSnapshot()
        var citing = paper("W11")
        let cited = paper("W12")
        citing.referencedIDs = [cited.id]
        GraphMerge.add([citing, cited], edges: [], to: &snapshot)
        #expect(snapshot.edges == [GraphEdge(source: citing.id, target: cited.id,
            relation: .reference, provider: "OpenAlex referenced_works")])
        GraphMerge.add([], edges: [GraphEdge(source: citing.id, target: cited.id, relation: .related)],
            to: &snapshot)
        #expect(snapshot.edges.count == 2)
    }

    @Test("150 篇图谱布局稳定、有限且根节点固定")
    func boundedLayout() {
        let papers = (0..<150).map { paper("W\($0)") }
        let edges = (1..<150).map { GraphEdge(source: papers[$0].id, target: papers[0].id, relation: .citation) }
        let first = GraphLayout.positions(papers: papers, edges: edges, rootID: papers[0].id)
        let second = GraphLayout.positions(papers: papers, edges: edges, rootID: papers[0].id)
        #expect(first == second)
        #expect(first.count == 150)
        #expect(first[papers[0].id] == GraphPosition(x: 0, y: 0))
        #expect(first.values.allSatisfy { $0.x.isFinite && $0.y.isFinite })
    }

    @Test("布局把参考与施引文献分到起点两侧")
    func temporalSides() {
        let root = paper("W1")
        let prior = paper("W2")
        let later = paper("W3")
        let result = GraphLayout.positions(papers: [root, prior, later], edges: [
            GraphEdge(source: root.id, target: prior.id, relation: .reference),
            GraphEdge(source: later.id, target: root.id, relation: .citation)
        ], rootID: root.id)
        #expect((result[prior.id]?.x ?? 0) < 0)
        #expect((result[later.id]?.x ?? 0) > 0)
    }

    @Test("关系页按当前论文和方向筛选，跨连线不会让三个列表相同")
    func relationViews() {
        let root = paper("W1")
        let reference = paper("W2")
        let citation = paper("W3")
        let related = paper("W4")
        let nextReference = paper("W5")
        var snapshot = LiteratureGraphSnapshot()
        snapshot.paperID = root.id
        snapshot.papers = [root, reference, citation, related, nextReference]
        snapshot.edges = [
            GraphEdge(source: root.id, target: reference.id, relation: .reference),
            GraphEdge(source: citation.id, target: root.id, relation: .citation),
            GraphEdge(source: citation.id, target: root.id, relation: .reference,
                      provider: "OpenAlex referenced_works"),
            GraphEdge(source: root.id, target: related.id, relation: .related),
            GraphEdge(source: reference.id, target: nextReference.id, relation: .reference)
        ]
        #expect(GraphRelationView.papers(in: snapshot, relation: .reference).map(\.id)
                == [root.id, reference.id, nextReference.id])
        #expect(GraphRelationView.papers(in: snapshot, relation: .citation).map(\.id)
                == [root.id, citation.id])
        #expect(GraphRelationView.papers(in: snapshot, relation: .related).map(\.id)
                == [root.id, related.id])
    }

    @Test("反向引用使用 cites 查询，结果按接口返回解析")
    func citationLookup() async throws {
        let sample = """
        {"results":[{"id":"https://openalex.org/W9","title":"后续论文","authorships":[],"publication_year":2025,"referenced_works":["https://openalex.org/W1"]}]}
        """
        let client = OpenAlexGraphClient { request in
            let filter = request.url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false) }?.queryItems?.first { $0.name == "filter" }?.value
            #expect(filter == "cites:W1")
            let sort = request.url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false) }?.queryItems?.first { $0.name == "sort" }?.value
            #expect(sort == "publication_date:desc")
            return GraphHTTPResponse(status: 200, data: Data(sample.utf8))
        }
        let results = try await client.neighbors(of: paper("W1"), relation: .citation)
        #expect(results.count == 1)
        #expect(results[0].referencedIDs == ["https://openalex.org/W1"])
    }

    @Test("同标题候选按作者排序，中文标题原样传入")
    func candidateDisambiguation() async throws {
        let sample = """
        {"results":[
          {"id":"https://openalex.org/W1","title":"教育研究","authorships":[{"author":{"display_name":"李明"}}]},
          {"id":"https://openalex.org/W2","title":"教育研究","authorships":[{"author":{"display_name":"张华"}}]}
        ]}
        """
        let client = OpenAlexGraphClient { request in
            let search = request.url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false) }?.queryItems?.first { $0.name == "search" }?.value
            #expect(search == "教育研究")
            return GraphHTTPResponse(status: 200, data: Data(sample.utf8))
        }
        let candidates = try await client.candidates(GraphIdentity(title: "教育研究", authors: ["张华"]))
        #expect(candidates.map(\.id) == ["https://openalex.org/W2", "https://openalex.org/W1"])
    }

    @Test("限流两次后成功，且不会无限重试")
    func retry429() async throws {
        actor Counter {
            var count = 0
            func next() -> Int { count += 1; return count }
            func value() -> Int { count }
        }
        let counter = Counter()
        let client = OpenAlexGraphClient { _ in
            let number = await counter.next()
            return GraphHTTPResponse(status: number < 3 ? 429 : 200, data: Data(#"{"results":[]}"#.utf8))
        }
        _ = try await client.candidates(GraphIdentity(title: "test"))
        #expect(await counter.value() == 3)
    }

    @Test("图谱请求把独立 OpenAlex Key 作为 Bearer 发送")
    func openAlexKeyHeader() async throws {
        let client = OpenAlexGraphClient(apiKey: "test-key") { request in
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer test-key")
            return GraphHTTPResponse(status: 200, data: Data(#"{"results":[]}"#.utf8))
        }
        _ = try await client.candidates(GraphIdentity(title: "中文研究"))
    }

    @Test("中文编号参考文献只从参考文献表提取，止于附录")
    func localChineseReferences() {
        let text = """
        摘要
        本文有[1]这样的正文引文。
        参考文献
        [1] 张三，李四. 教育技术与学习分析[J]. 教育研究，2024.
        ［2］ 王五．中文知识图谱研究［J］．图书情报工作，2023.
        附录
        [3] 不应出现
        """
        let parsed = LocalReferenceParser.parse(text)
        #expect(parsed.count == 2)
        #expect(parsed[0].contains("教育技术与学习分析"))
        #expect(parsed[1].contains("中文知识图谱"))
        #expect(LocalReferenceParser.parse("正文里有[1]，但没有文后书目。").isEmpty)
        #expect(LocalReferenceParser.doi(in: "DOI: 10.1234/ABC. ") == "10.1234/abc")
        #expect(LocalReferenceParser.suggestedTitle(in: parsed[0]) == "教育技术与学习分析")
        #expect(LocalReferenceParser.suggestedTitle(in: parsed[1]) == "中文知识图谱研究")
    }

    @Test("本地中文引文确认后保留 PDF 引用方向和来源，重复 DOI 不产生双节点")
    func resolveLocalCitation() {
        var snapshot = LiteratureGraphSnapshot()
        let root = paper("W1")
        let matched = paper("W2", doi: "10.1234/chinese")
        let local = GraphPaper(id: "local:reference:a", doi: nil, title: "张三. 中文研究[J].",
                               authors: [], year: nil, venue: "PDF", abstract: "", openAccessURL: nil,
                               referencedIDs: [], relatedIDs: [], citedByCount: 0)
        snapshot.papers = [root, local, matched]
        snapshot.edges = [GraphEdge(source: root.id, target: local.id, relation: .reference, provider: "PDF 参考文献")]
        GraphMerge.resolveLocalReference(local.id, with: matched, in: &snapshot)
        #expect(snapshot.papers.count == 2)
        #expect(snapshot.edges == [GraphEdge(source: root.id, target: matched.id, relation: .reference, provider: "PDF 参考文献")])
    }

    @Test("未核对的本地 DOI 不吞掉 OpenAlex 已识别节点")
    func localDOIDoesNotMaskRemotePaper() {
        var snapshot = LiteratureGraphSnapshot()
        let local = GraphPaper(id: "local:reference:b", doi: "10.1234/same", title: "原始题录",
                               authors: [], year: nil, venue: "PDF", abstract: "", openAccessURL: nil,
                               referencedIDs: [], relatedIDs: [], citedByCount: 0)
        let remote = paper("W3", doi: "10.1234/same")
        GraphMerge.add([local], edges: [], to: &snapshot)
        GraphMerge.add([remote], edges: [], to: &snapshot)
        #expect(snapshot.papers.map(\.id) == [local.id, remote.id])
        GraphMerge.resolveLocalReference(local.id, with: remote, in: &snapshot)
        #expect(snapshot.papers.map(\.id) == [remote.id])
    }
}
