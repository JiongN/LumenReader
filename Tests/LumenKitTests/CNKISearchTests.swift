import Foundation
import Testing
@testable import LumenKit

@Suite("知网题录边界")
struct CNKISearchTests {
    private let source = URL(string: "https://kns.cnki.net/kns8s/")!

    @Test func boundedMetadataIsNotFullTextOrOpenAlexIdentity() throws {
        let row: [String: Any] = ["title": " 教师觉察与课堂沉默 ", "authors": ["张三", "李四"],
            "year": "2026-08-01", "journal": " 教育研究 ", "citations": "1,203",
            "url": "/kcms2/article/abstract?filename=TEST202601001&dbcode=CJFD"]
        let data = try JSONSerialization.data(withJSONObject: ["formReady": true, "papers": Array(repeating: row, count: 5)])
        let page = try CNKIPage.decode(data, source: source, query: "教师觉察")
        #expect(page.state == .results && page.formReady)
        let paper = try #require(page.papers.first)
        #expect(page.papers.count == 1)
        #expect(paper.title == "教师觉察与课堂沉默" && paper.authors == ["张三", "李四"])
        #expect(paper.year == 2026 && paper.citations == 1203)
        #expect(paper.evidence == "metadata_only" && paper.query == "教师觉察")
        #expect(paper.identity.source == "知网题录" && paper.identity.doi == nil)
        #expect(paper.id.host == "kns.cnki.net")
    }

    @Test func captchaLoginAndUnknownPageAreNotZeroHits() throws {
        for (json, state) in [
            (#"{"verification":true,"noResults":true}"#, CNKIPageState.verificationRequired),
            (#"{"loginRequired":true}"#, .loginRequired),
            (#"{}"#, .unavailable),
            (#"{"noResults":true}"#, .noResults)
        ] {
            let page = try CNKIPage.decode(Data(json.utf8), source: source, query: "沉默")
            #expect(page.state == state && page.papers.isEmpty)
        }
    }

    @Test func linksAreRestrictedToCNKIPaperPages() throws {
        let links = ["javascript:alert(1)", "file:///tmp/private", "https://cnki.net.evil.example/article/123",
            "https://evil.example/kcms2/article/abstract", "https://name:password@kns.cnki.net/article/1",
            "https://kns.cnki.net:8443/article/1", "https://kns.cnki.net/login", "",
            "http://kns.cnki.net/kcms/detail/detail.aspx?filename=VALID"]
        let data = try JSONSerialization.data(withJSONObject: ["papers": links.enumerated().map {
            ["title": "论文\($0.offset)", "url": $0.element]
        }])
        let page = try CNKIPage.decode(data, source: source, query: "词")
        #expect(page.papers.count == 1)
        #expect(page.papers.first?.url.scheme == "https")
        #expect(throws: CNKIPage.ParseError.self) {
            try CNKIPage.decode(data, source: URL(string: "https://library.example/")!, query: "词")
        }
    }

    @Test func resultAndResponseSizesAreBounded() throws {
        let data = try JSONSerialization.data(withJSONObject: ["papers": (0..<80).map {
            ["title": "论文 \($0)", "url": "https://kns.cnki.net/article/\($0)"]
        }])
        #expect(try CNKIPage.decode(data, source: source, query: "词").papers.count == 20)
        #expect(throws: CNKIPage.ParseError.self) {
            try CNKIPage.decode(Data(repeating: 32, count: 256 * 1024 + 1), source: source, query: "词")
        }
        #expect(CNKIPage.searchQuery(" \n单一关键词\t ") == "单一关键词")
        #expect(CNKIPage.searchQuery("\n ") == nil)
        #expect(CNKIPage.searchQuery(String(repeating: "a", count: 161)) == nil)
    }

    @Test func legacyCNKILinksUpgradeWithoutRelaxingTLSOrOtherOrigins() {
        let legacy = URL(string: "http://kns.cnki.net:80/kns8s/?x=1")!
        #expect(CNKIPage.secureCNKIURL(legacy)?.absoluteString == "https://kns.cnki.net/kns8s/?x=1")
        for value in ["http://library.example/", "http://cnki.net.evil.example/", "http://kns.cnki.net:8888/",
                      "http://name:password@kns.cnki.net/", "file:///tmp/private"] {
            #expect(CNKIPage.secureCNKIURL(URL(string: value)!) == nil)
        }
    }

    @Test func unchangedResultsOrOnlyAChangedFormCannotFinishANewQuery() throws {
        let row: [String: Any] = ["title": "旧的检索结果", "url": "https://kns.cnki.net/article/1"]
        func page(_ rows: [[String: Any]], form: Bool, noResults: Bool = false) throws -> CNKIPage {
            let data = try JSONSerialization.data(withJSONObject: ["papers": rows, "formReady": form, "noResults": noResults])
            return try CNKIPage.decode(data, source: source, query: "新的检索词")
        }
        let old = try page([row], form: true)
        #expect(try !page([row], form: true).hasNewResults(comparedTo: old))
        #expect(try !page([row], form: false).hasNewResults(comparedTo: old))
        #expect(try !page([], form: true).hasNewResults(comparedTo: old))
        #expect(try page([], form: true, noResults: true).hasNewResults(comparedTo: old))
        let fresh = try page([["title": "新的检索结果", "url": "https://kns.cnki.net/article/2"]], form: true)
        #expect(fresh.hasNewResults(comparedTo: old))
        let noHits = try page([], form: true, noResults: true)
        #expect(!noHits.hasNewResults(comparedTo: noHits))
    }
}
