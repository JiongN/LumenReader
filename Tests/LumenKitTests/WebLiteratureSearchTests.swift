import Testing
import Foundation
import Synchronization
import LumenKit

@Suite(.serialized)
struct WebLiteratureSearchTests {
    private func hit(_ title: String, abstract: String = "", source: String = "Crossref") -> LiteratureHit {
        .init(title: title, authors: "", year: "2024", venue: "", identifier: "", abstract: abstract, source: source)
    }

    @Test func rankingRejectsUnrelatedFuzzyMatchesAndDeduplicates() {
        let hits = [hit("Heart disease treatment"), hit("Artificial intelligence and illusions of understanding"),
            hit("Artificial intelligence and illusions of understanding", source: "OpenAlex"),
            hit("Understanding", abstract: "AI systems can cause illusions of understanding")]
        let results = WebLiteratureSearch.ranked(hits, query: "artificial intelligence illusions understanding")
        #expect(results.count == 2)
        #expect(results.first?.title == "Artificial intelligence and illusions of understanding")
        #expect(!results.contains { $0.title.contains("Heart") })
        #expect(WebLiteratureSearch.ranked(hits, query: "please find related research").isEmpty)
    }

    @Test func arxivTermsAreFieldedAndCannotInjectOperators() {
        #expect(WebLiteratureSearch.arxivExpression("artificial intelligence") == "all:artificial AND all:intelligence")
        #expect(!WebLiteratureSearch.arxivExpression("test\" OR cat:physics").contains("cat:physics"))
    }

    @Test func failuresAndEmptyResultsReachTheModel() {
        let block = WebLiteratureSearch.promptBlock(.init(hits: [], failures: ["OpenAlex：服务返回 HTTP 401"], query: "scientific understanding"))
        #expect(block.contains("401"))
        #expect(block.contains("scientific understanding"))
        #expect(block.contains("不存在相关研究"))
        #expect(block.contains("整个互联网"))
    }

    @Test func wholeWordMatchingDoesNotTreatArtOrAIAsSubstrings() {
        #expect(WebLiteratureSearch.ranked([hit("Heart pain")], query: "art pain").isEmpty)
        #expect(WebLiteratureSearch.ranked([hit("Brain understanding")], query: "AI understanding").isEmpty)
        #expect(WebLiteratureSearch.ranked([hit("Artificial intelligence understanding")], query: "AI understanding").count == 1)
        #expect(WebLiteratureSearch.ranked([hit("AI prediction")], query: "AI understanding").isEmpty)
    }

    @Test func bilingualPlanExpandsRecallAndCachesOnlySuccessfulOutcomes() async throws {
        LiteratureProtocol.requests.withLock { $0 = [] }
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [LiteratureProtocol.self]
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        let plan = WebLiteratureSearch.QueryPlan(query: "scientific understanding illusions", fallbackQuery: "AI understanding", nativeQuery: "理解错觉")
        let outcome = await WebLiteratureSearch.search(plan: plan, openAlexKey: "test-key", session: session)
        #expect(outcome.hits.count == 1)
        #expect(outcome.query.contains("理解错觉"))
        #expect(outcome.hits.first?.abstract.contains("understanding") == true)
        #expect(outcome.hits.first?.source.contains("OpenAlex") == true)
        let requests = LiteratureProtocol.requests.withLock { $0 }
        #expect(requests.count == 7)
        let alex = requests.filter { $0.url?.host == "api.openalex.org" }
        #expect(alex.count == 3)
        #expect(alex.allSatisfy { $0.value(forHTTPHeaderField: "Authorization") == "Bearer test-key" })
        #expect(alex.allSatisfy { $0.url?.absoluteString.contains("test-key") == false })
        let cached = await WebLiteratureSearch.search(plan: plan, openAlexKey: "test-key", session: session)
        #expect(cached.cached)
        #expect(LiteratureProtocol.requests.withLock { $0.count } == 7)
        #expect(WebLiteratureSearch.promptBlock(outcome).contains("来源："))
        let failing = WebLiteratureSearch.QueryPlan(query: "unauthorized topic")
        let failed = await WebLiteratureSearch.search(plan: failing, session: session)
        #expect(!failed.failures.isEmpty)
        let before = LiteratureProtocol.requests.withLock { $0.count }
        let retry = await WebLiteratureSearch.search(plan: failing, session: session)
        #expect(!retry.cached)
        #expect(LiteratureProtocol.requests.withLock { $0.count } == before + 3)
    }

    @Test func queryPlanIsBoundedAndInvalidAlternativesAreIgnored() {
        let plan = WebLiteratureSearch.QueryPlan(query: "AI learning", fallbackQuery: "AI learning", nativeQuery: String(repeating: "x", count: 181))
        #expect(plan.queries == ["AI learning"])
        #expect(WebLiteratureSearch.QueryPlan(query: "a\nb", nativeQuery: "学习").queries == ["学习"])
    }
}

private final class LiteratureProtocol: URLProtocol, @unchecked Sendable {
    static let requests = Mutex<[URLRequest]>([])
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.requests.withLock { $0.append(request) }
        let items = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let query = items.first { $0.name == "search" || $0.name == "query.bibliographic" }?.value ?? ""
        let status = query.contains("unauthorized") ? 401 : 200
        let found = query == "AI understanding" || query == "理解错觉"
        let data: Data
        if request.url?.host == "api.crossref.org" {
            let hits: [[String: Any]] = found ? [["title": ["AI understanding"], "DOI": "10.1234/test"]] : []
            data = try! JSONSerialization.data(withJSONObject: ["message": ["items": hits]])
        } else if request.url?.host == "api.openalex.org" {
            let hits: [[String: Any]] = found ? [["id": "https://openalex.org/W1", "title": "Artificial intelligence understanding", "doi": "https://doi.org/10.1234/test", "abstract_inverted_index": ["AI": [0], "understanding": [1]]]] : []
            data = try! JSONSerialization.data(withJSONObject: ["results": hits])
        } else { data = Data("<?xml version=\"1.0\"?><feed></feed>".utf8) }
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
