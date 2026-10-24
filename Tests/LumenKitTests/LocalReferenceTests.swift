import Foundation
import Testing
@testable import LumenKit

@Suite("本地中文参考文献")
struct LocalReferenceTests {
    private let bibliography = """
    参考文献:
    [1] 岳伟. 教育:主体间双向建构的交往实践活动
    [ J]. 教育研究与实验, 2008(1).
    [2] [7] [9] [10] [ 11] [ 22] [ 24] [ 26] [ 29] [ 30]
    佩特丽莉. 符号语言与倾听——符号伦理学
    视角[ M]. 贾洪伟, 译. 成都: 四 川 大 学 出 版
    社, 2020:2,116,140,20,194,120,188,195,
    15,187.
    [3] 金生鈜. 理解与教育——走向哲学解释学的
    教育哲学导论[ M]. 北京:教育科学出版社,
    1997:58.
    [4] 赵毅衡. 重新定义符号与符号学[ J]. 国际新
    闻界, 2013, 35(6).
    [5] [12] 佩特丽莉, 周劲松. 符号伦理学与责任:
    生命、符号、他者[ J]. 鄱阳湖学刊, 2016(6).
    """

    @Test func combinedNumbersAndSpacedMarkers() throws {
        let entries = LocalReferenceParser.entries(in: bibliography)
        #expect(entries.count == 5)
        #expect(entries.map(\.year) == [2008, 2020, 1997, 2013, 2016])
        let book = try #require(entries.dropFirst().first)
        #expect(book.title == "符号语言与倾听——符号伦理学视角")
        #expect(book.authors == ["佩特丽莉"])
        #expect(book.venue == "四川大学出版社")
        #expect(book.numbers == [2, 7, 9, 10, 11, 22, 24, 26, 29, 30])
        #expect(book.original.contains("[ 30]"))
        #expect(book.original.contains("195,"))
        #expect(entries[3].venue == "国际新闻界")
        #expect(entries[4].authors == ["佩特丽莉", "周劲松"])
        #expect(entries[4].numbers == [5, 12])
    }

    @Test func fullWidthAndOnlineTypesKeepEnglishWords() throws {
        let text = """
        参 考 文 献：
        ［1］ 冯 建 军．他 者 性 教 育：超 越 教 育 的 同 一 性［ J ］．教育研究，2021，42(9)．
        [2] PETRILLI S. Signs and values: For a critique
        of cognitive semiotics[ J]. Journal of Pragmat-
        ics, 1993,20(3).
        [3] 张三. 开放资源[ EB / OL ]. 2024-03-01. https://example.org/1999
        """
        let entries = LocalReferenceParser.entries(in: text)
        #expect(entries.count == 3)
        #expect(entries[0].authors == ["冯建军"])
        #expect(entries[0].title == "他者性教育：超越教育的同一性")
        #expect(entries[1].title == "Signs and values: For a critique of cognitive semiotics")
        #expect(entries[1].venue == "Journal of Pragmatics")
        #expect(entries[2].title == "开放资源")
        #expect(entries[2].year == 2024)
    }

    @Test func yearsNeverComeFromTitlesOrDOIs() {
        let entry = LocalReferenceParser.details(in: "[1] 张三. 2024年的教育[M]. 北京:某出版社, 1997:58. DOI:10.1234/2025.88")
        #expect(entry.title == "2024年的教育")
        #expect(entry.year == 1997)
        #expect(LocalReferenceParser.details(in: "张三. 2024年的教育[J]. DOI:10.1234/2025.88").year == nil)
        #expect(LocalReferenceParser.details(in: "不明作者和年份，不能凭空补全").year == nil)
    }

    @Test func repeatedHeadingDoesNotDiscardEarlierEntriesAndTrailingAbstractIsExcluded() {
        let text = bibliography + """

        16
        参考文献
        [6] 张宛, 李熠煊. 来自教师的变革动力——迈
        克尔·富兰教师核心能力思想探析[J]. 天津市教科院学报, 2023,35(4).
        Understanding Students: The Significance of Ethical
        Symbols and Paths to Implementation
        Abstract: This is not a reference.
        [7] This is also not a reference.
        """
        let entries = LocalReferenceParser.entries(in: text)
        #expect(entries.count == 6)
        #expect(entries.last?.title == "来自教师的变革动力——迈克尔·富兰教师核心能力思想探析")
        #expect(entries.allSatisfy { !$0.citation.contains("Understanding Students") && !$0.citation.contains("Abstract") })
    }

    @Test func noSilentTwentyEntryLimitAndMalformedInputIsBounded() {
        let text = "参考文献\n" + (1...32).map { "[\($0)] 作者. 研究标题\($0)[J]. 教育研究, 2020." }.joined(separator: "\n")
        #expect(LocalReferenceParser.entries(in: text).count == 32)
        #expect(LocalReferenceParser.entries(in: text, limit: 2).count == 2)
        #expect(LocalReferenceParser.entries(in: text, limit: 0).isEmpty)
        #expect(LocalReferenceParser.entries(in: text, limit: -1).isEmpty)
        #expect(LocalReferenceParser.entries(in: "参考文献\n[1] " + String(repeating: "残损题录\n", count: 1_200)).isEmpty)
        #expect(LocalReferenceParser.entries(in: "正文[1]，没有参考文献标题").isEmpty)
    }

    @Test func legacySnapshotUpgradesOnlyGeneratedUnresolvedMetadata() throws {
        var graph = LiteratureGraphSnapshot()
        let raw = LocalReferenceParser.entries(in: bibliography)[1].original
        graph.papers = [paper("local:reference:old", title: raw), paper("cnki:confirmed", title: "人工核对的题名")]
        graph.paperID = "cnki:confirmed"
        graph.positions["local:reference:old"] = .init(x: 14, y: 21)
        let oldJSON = try JSONEncoder().encode(graph)
        var legacy = try #require(JSONSerialization.jsonObject(with: oldJSON) as? [String: Any])
        var rows = try #require(legacy["papers"] as? [[String: Any]])
        for index in rows.indices { rows[index].removeValue(forKey: "sourceCitation") }
        legacy["papers"] = rows
        var restored = try JSONDecoder().decode(LiteratureGraphSnapshot.self, from: JSONSerialization.data(withJSONObject: legacy))
        GraphMerge.upgradeLocalReferenceMetadata(in: &restored)
        #expect(restored.papers[0].title == "符号语言与倾听——符号伦理学视角")
        #expect(restored.papers[0].year == 2020)
        #expect(restored.papers[0].sourceCitation == raw)
        #expect(restored.papers[1] == graph.papers[1])
        #expect(restored.positions == graph.positions)
        #expect(restored.paperID == graph.paperID)
    }

    @Test func reextractIsIdempotentAndPreservesConfirmedNodesAndPositions() throws {
        let entries = LocalReferenceParser.entries(in: bibliography)
        var graph = LiteratureGraphSnapshot()
        graph.paperID = "root"
        graph.papers = [paper("root", title: "当前论文")]
        #expect(GraphMerge.refreshLocalReferences(entries, rootID: "root", in: &graph) == 5)
        let local = try #require(graph.papers.first { $0.title == entries[0].title })
        graph.positions[local.id] = .init(x: 12, y: 20)
        graph.pinnedPositionIDs.insert(local.id)
        GraphMerge.resolveLocalReference(local.id, with: paper("W1", title: local.title, year: local.year), in: &graph)
        #expect(graph.papers.first { $0.id == "W1" }?.sourceCitation == entries[0].original)
        let count = graph.papers.count
        #expect(GraphMerge.refreshLocalReferences(entries, rootID: "root", in: &graph) == 5)
        #expect(graph.papers.count == count)
        #expect(graph.papers.contains { $0.id == "W1" })
        #expect(!graph.papers.contains { $0.id == local.id })
        #expect(graph.positions["W1"] == .init(x: 12, y: 20))
        #expect(graph.pinnedPositionIDs.contains("W1"))
        #expect(graph.edges.count == 5)
    }

    @Test func reextractionKeepsBibliographyOrderEvenWhenAnOldTitleWasCorrupted() {
        let entries = LocalReferenceParser.entries(in: bibliography)
        var graph = LiteratureGraphSnapshot()
        graph.papers = [paper("root", title: "当前论文"), paper("unrelated", title: "相关论文")]
        GraphMerge.refreshLocalReferences(entries, rootID: "root", in: &graph)
        let previousID = graph.papers[3].id
        let id = "local:reference:legacy-corrupt"
        graph.papers[3].id = id
        graph.edges = graph.edges.map {
            GraphEdge(source: $0.source, target: $0.target == previousID ? id : $0.target,
                      relation: $0.relation, provider: $0.provider)
        }
        graph.papers[3].title = "页眉混进原来的条目"
        graph.papers[3].sourceCitation = nil
        GraphMerge.refreshLocalReferences(entries, rootID: "root", in: &graph)
        #expect(!graph.papers.contains { $0.id == id })
        #expect(graph.papers.filter { $0.id.hasPrefix("local:reference:") }.map(\.title) == entries.map(\.title))
        #expect(graph.papers[1].id == "unrelated")
    }

    @Test func existingDOIAliasCountsAsALoadedReference() {
        var graph = LiteratureGraphSnapshot()
        var remote = paper("W1", title: "已核对的远端文献")
        remote.doi = "10.1234/reference"
        graph.papers = [paper("root", title: "当前论文"), remote]
        let entries = LocalReferenceParser.entries(in: "参考文献\n[1] 张三. 引用的论文[J]. 期刊, 2024. DOI:10.1234/reference")
        #expect(GraphMerge.refreshLocalReferences(entries, rootID: "root", in: &graph) == 1)
        #expect(graph.papers.count == 2)
        #expect(graph.edges.first?.target == "W1")
    }

    @Test func fullGraphRefreshDoesNotRepeatMetadataParsingForEveryPair() {
        let text = "参考文献\n" + (1...149).map { "[\($0)] 作者\($0). 中文研究标题\($0)[J]. 教育研究, 2020." }.joined(separator: "\n")
        let entries = LocalReferenceParser.entries(in: text)
        var graph = LiteratureGraphSnapshot()
        graph.papers = [paper("root", title: "当前论文")]
        GraphMerge.refreshLocalReferences(entries, rootID: "root", in: &graph)
        let start = ContinuousClock.now
        #expect(GraphMerge.refreshLocalReferences(entries, rootID: "root", in: &graph) == 149)
        print("REFERENCE_MERGE repeated149=\(ContinuousClock.now - start)")
        #expect(graph.papers.count == 150)
        #expect(graph.papers.dropFirst().map(\.title) == entries.map(\.title))
    }

    private func paper(_ id: String, title: String, year: Int? = nil) -> GraphPaper {
        GraphPaper(id: id, doi: nil, title: title, authors: [], year: year, venue: "", abstract: "",
                   openAccessURL: nil, referencedIDs: [], relatedIDs: [], citedByCount: 0)
    }
}
