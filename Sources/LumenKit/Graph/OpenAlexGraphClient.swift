import Foundation

public enum GraphServiceError: Error, LocalizedError, Sendable {
    case http(Int), malformed, missingIdentity
    public var errorDescription: String? {
        switch self {
        case .http(429): "OpenAlex 请求限流。可在图谱左侧顶部填写 API Key，再刷新图谱；若已配置 Key，请稍后重试。"
        case .http(401), .http(403): "OpenAlex 凭据无效或额度不足。"
        case .http(let code): "OpenAlex 请求失败（HTTP \(code)）。"
        case .malformed: "OpenAlex 返回的数据无法解析。"
        case .missingIdentity: "请先填写论文标题或 DOI。"
        }
    }
}

public struct GraphHTTPResponse: Sendable {
    public var status: Int
    public var data: Data
    public init(status: Int, data: Data) { self.status = status; self.data = data }
}

public struct OpenAlexGraphClient: Sendable {
    public var fetch: @Sendable (URLRequest) async throws -> GraphHTTPResponse
    public var apiKey: String?

    public init(apiKey: String? = nil, fetch: @escaping @Sendable (URLRequest) async throws -> GraphHTTPResponse = { request in
        let (data, response) = try await URLSession.shared.data(for: request)
        return GraphHTTPResponse(status: (response as? HTTPURLResponse)?.statusCode ?? 0, data: data)
    }) {
        self.apiKey = apiKey
        self.fetch = fetch
    }

    public func work(id: String) async throws -> GraphPaper? {
        let short = id.components(separatedBy: "/").last ?? id
        guard short.hasPrefix("W") || id.hasPrefix("https://doi.org/") else { return nil }
        let encoded = id.hasPrefix("https://doi.org/") ? id : short
        guard let url = URL(string: "https://api.openalex.org/works/\(encoded)") else { throw GraphServiceError.malformed }
        do { return try Self.decodePaper(try await request(url)) }
        catch GraphServiceError.http(404) { return nil }
    }

    public func candidates(_ identity: GraphIdentity) async throws -> [GraphPaper] {
        if let doi = identity.doi, let exact = try await work(id: "https://doi.org/\(doi)") { return [exact] }
        guard !identity.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw GraphServiceError.missingIdentity }
        return try await list([URLQueryItem(name: "search", value: identity.title), URLQueryItem(name: "per_page", value: "8")])
            .sorted { Self.score($0, identity) > Self.score($1, identity) }
    }

    public func neighbors(of paper: GraphPaper, relation: GraphRelation, count: Int = 20) async throws -> [GraphPaper] {
        let limit = max(1, min(20, count))
        switch relation {
        case .reference:
            var results: [GraphPaper] = []
            for batch in stride(from: 0, to: min(paper.referencedIDs.count, limit), by: 20) {
                let ids = Array(paper.referencedIDs[batch..<min(batch + 20, paper.referencedIDs.count)])
                    .compactMap { $0.components(separatedBy: "/").last }
                results += try await list([URLQueryItem(name: "filter", value: "openalex:\(ids.joined(separator: "|"))"), URLQueryItem(name: "per_page", value: "20")])
            }
            var order: [String: Int] = [:]
            for (index, id) in paper.referencedIDs.enumerated() where order[id] == nil { order[id] = index }
            return results.sorted { (order[$0.id] ?? Int.max) < (order[$1.id] ?? Int.max) }.prefix(limit).map { $0 }
        case .citation:
            let short = paper.id.components(separatedBy: "/").last ?? paper.id
            return try await list([URLQueryItem(name: "filter", value: "cites:\(short)"), URLQueryItem(name: "sort", value: "publication_date:desc"), URLQueryItem(name: "per_page", value: "\(limit)")])
        case .related:
            let ids = paper.relatedIDs.prefix(limit).compactMap { $0.components(separatedBy: "/").last }
            guard !ids.isEmpty else { return [] }
            let results = try await list([URLQueryItem(name: "filter", value: "openalex:\(ids.joined(separator: "|"))"), URLQueryItem(name: "per_page", value: "\(limit)")])
            var order: [String: Int] = [:]
            for (index, id) in paper.relatedIDs.enumerated() where order[id] == nil { order[id] = index }
            return results.sorted { (order[$0.id] ?? Int.max) < (order[$1.id] ?? Int.max) }
        }
    }

    private func list(_ items: [URLQueryItem]) async throws -> [GraphPaper] {
        var components = URLComponents(string: "https://api.openalex.org/works")!
        components.queryItems = items + [URLQueryItem(name: "select", value: "id,doi,title,authorships,publication_year,primary_location,abstract_inverted_index,open_access,referenced_works,related_works,cited_by_count")]
        let data = try await request(components.url!)
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any], let results = root["results"] as? [[String: Any]] else { throw GraphServiceError.malformed }
        return results.compactMap(Self.paper)
    }

    private func request(_ url: URL) async throws -> Data {
        var request = URLRequest(url: url)
        request.timeoutInterval = 12
        request.setValue("LumenReader/1.0", forHTTPHeaderField: "User-Agent")
        if let apiKey, !apiKey.isEmpty { request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization") }
        for attempt in 0..<3 {
            try Task.checkCancellation()
            let response = try await fetch(request)
            if (200..<300).contains(response.status) { return response.data }
            if response.status != 429 && response.status < 500 { throw GraphServiceError.http(response.status) }
            if attempt == 2 { throw GraphServiceError.http(response.status) }
            try await Task.sleep(for: .milliseconds(800 * (attempt + 1)))
        }
        throw GraphServiceError.malformed
    }

    private static func decodePaper(_ data: Data) throws -> GraphPaper? {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw GraphServiceError.malformed }
        return paper(json)
    }

    private static func paper(_ value: [String: Any]) -> GraphPaper? {
        guard let id = value["id"] as? String, let title = value["title"] as? String, !title.isEmpty else { return nil }
        let authors = (value["authorships"] as? [[String: Any]] ?? []).compactMap { ($0["author"] as? [String: Any])?["display_name"] as? String }
        let venue = ((value["primary_location"] as? [String: Any])?["source"] as? [String: Any])?["display_name"] as? String ?? ""
        let oa = (value["open_access"] as? [String: Any])?["oa_url"] as? String
        let inverted = value["abstract_inverted_index"] as? [String: [Int]] ?? [:]
        let words = inverted.flatMap { word, positions in positions.map { ($0, word) } }.sorted { $0.0 < $1.0 }.map(\.1)
        return GraphPaper(id: id, doi: value["doi"] as? String, title: title, authors: authors, year: value["publication_year"] as? Int, venue: venue, abstract: words.joined(separator: " "), openAccessURL: oa.flatMap(URL.init(string:)), referencedIDs: Array((value["referenced_works"] as? [String] ?? []).prefix(20)), relatedIDs: Array((value["related_works"] as? [String] ?? []).prefix(20)), citedByCount: value["cited_by_count"] as? Int ?? 0)
    }

    private static func score(_ paper: GraphPaper, _ identity: GraphIdentity) -> Int {
        let title = paper.title.lowercased().filter(\.isLetter)
        let wanted = identity.title.lowercased().filter(\.isLetter)
        var score = title == wanted ? 100 : (title.contains(wanted) || wanted.contains(title) ? 30 : 0)
        if identity.authors.contains(where: { author in paper.authors.contains(where: { $0.localizedCaseInsensitiveContains(author) || author.localizedCaseInsensitiveContains($0) }) }) { score += 20 }
        if paper.year == identity.year { score += 10 }
        return score
    }
}
