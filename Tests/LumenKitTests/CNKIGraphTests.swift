import Foundation
import Testing
@testable import LumenKit

@Suite("知网关系数据边界")
struct CNKIGraphTests {
    private let references = URL(string: "https://kns.cnki.net/restapi/citation-api/v1/literature/references")!

    @Test func onlyActualSupportedCNKIEndpointsAreAccepted() {
        #expect(CNKIRelationBatch.relation(for: references) == .reference)
        for value in ["http://kns.cnki.net/restapi/citation-api/v1/literature/references",
                      "https://cnki.net.evil.example/restapi/citation-api/v1/literature/references",
                      "https://kns.cnki.net/restapi/citation-api/v1/literature/coreferences",
                      "https://kns.cnki.net/other/references",
                      "https://user:secret@kns.cnki.net/restapi/citation-api/v1/literature/references"] {
            #expect(CNKIRelationBatch.relation(for: URL(string: value)!) == nil)
        }
    }

    @Test func structuredMetadataAndProvenanceArePreserved() throws {
        let data = Data(#"{"code":200,"data":{"total":75,"data":[{"metadata":[{"name":"TI","value":"中文教育研究"},{"name":"AU","value":"张三；李四"},{"name":"YE","value":2024},{"name":"LY","value":"教育研究"},{"name":"FN","value":"TEST202401001"},{"name":"product","value":"CJFQ"}],"metrics":[{"name":"CTC","value":"8"}]}]}}"#.utf8)
        let batch = try CNKIRelationBatch.decode(data, endpoint: references)
        let paper = try #require(batch.papers.first)
        #expect(batch.relation == .reference && batch.total == 75 && batch.isPartial)
        #expect(paper.authors == ["张三", "李四"] && paper.year == 2024 && paper.citedByCount == 8)
        #expect(paper.id.hasPrefix("cnki:") && paper.referencedIDs.isEmpty)
        #expect(paper.openAccessURL?.host == "kns.cnki.net")
        #expect(paper.openAccessURL?.query?.contains("filename=TEST202401001") == true)
    }

    @Test func errorsAndSchemaChangesCannotPretendToBeZeroCitations() throws {
        for text in [#"{"code":403,"data":{"data":[]}}"#, #"{"success":false,"data":{"data":[]}}"#,
                     #"{"message":"请登录"}"#, #"{"data":{"data":[{"title":"unexpected schema"}]}}"#] {
            #expect(throws: (any Error).self) { try CNKIRelationBatch.decode(Data(text.utf8), endpoint: references) }
        }
        #expect(throws: (any Error).self) { try CNKIRelationBatch.decode(Data(repeating: 32, count: 1_048_577), endpoint: references) }
        let empty = try CNKIRelationBatch.decode(Data(#"{"code":0,"data":{"total":0,"data":[]}}"#.utf8), endpoint: references)
        #expect(empty.papers.isEmpty && empty.total == 0 && !empty.isPartial)
    }

    @Test func deduplicationAndRelationshipLimitsAreBounded() throws {
        let rows = (0..<180).map { index in
            ["metadata": [["name":"TI", "value":"论文\(index / 2)"], ["name":"AU", "value":"张三"]],
             "relations": [["scope":"ZKABSTRACT", "url":"https://evil.example/paper"]]]
        }
        let data = try JSONSerialization.data(withJSONObject: ["data": ["data": rows]])
        let batch = try CNKIRelationBatch.decode(data, endpoint: references)
        #expect(batch.papers.count == 50 && batch.isPartial)
        #expect(batch.papers.allSatisfy { $0.openAccessURL == nil })
        #expect(Set(batch.papers.map(\.id)).count == 50)
    }

    @Test func recommendationsAreNotConvertedIntoCitationEdges() throws {
        let endpoint = URL(string: "https://kns.cnki.net/openapi/usercenter-api/v1/recommend/similar/articles")!
        let data = Data(#"{"data":[{"metadata":[{"name":"CTI","value":"相关论文"},{"name":"CAU","value":"张三"}]}]}"#.utf8)
        let batch = try CNKIRelationBatch.decode(data, endpoint: endpoint)
        #expect(batch.relation == .related && batch.papers.count == 1)
        #expect(batch.papers.first?.referencedIDs.isEmpty == true)
    }

    @Test func ambiguousTitlesCannotBeAutomaticallyAdopted() {
        let url = URL(string:"https://kns.cnki.net/kcms2/article/abstract?filename=TEST")!
        let identity = GraphIdentity(title: "理解学生：符号伦理", authors: ["郑航"], year: 2024)
        let right = CNKIPaper(title:"理解学生:符号伦理", authors:["郑航", "牛炅"], year:2024, journal:"", citations:nil, url:url, query:"")
        let wrong = CNKIPaper(title:right.title, authors:["其他人"], year:2025, journal:"", citations:nil, url:url, query:"")
        #expect(CNKIRelationBatch.uniqueMatch([wrong, right], identity:identity) == right)
        #expect(CNKIRelationBatch.uniqueMatch([right, right], identity:identity) == nil)
        #expect(CNKIRelationBatch.uniqueMatch([wrong], identity:identity) == nil)
    }

    @Test func cnkiLinkSurvivesRestartAndLegacyIdentityStillDecodes() throws {
        let legacy = try JSONDecoder().decode(GraphIdentity.self, from: Data(#"{"title":"旧题录","authors":[],"source":"用户修订"}"#.utf8))
        #expect(legacy.cnkiURL == nil)
        let url = URL(string:"https://kns.cnki.net/kcms2/article/abstract?filename=TEST")!
        let value = GraphIdentity(title:"中文论文", source:"知网题录", cnkiURL:url)
        #expect(try JSONDecoder().decode(GraphIdentity.self, from: JSONEncoder().encode(value)) == value)
        #expect(GraphIdentity(title:"不安全地址", cnkiURL:URL(string:"https://evil.example/paper")).cnkiURL == nil)
    }
}
