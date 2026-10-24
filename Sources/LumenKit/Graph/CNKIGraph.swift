import Foundation
import CryptoKit

/// Only relationships actually returned by a CNKI article page; no inferred citations.
public struct CNKIRelationBatch: Sendable {
    public let relation: GraphRelation
    public let papers: [GraphPaper]
    public let total: Int?
    public let isPartial: Bool
    public static let limit = 50

    public static func relation(for url: URL) -> GraphRelation? {
        guard CNKIPage.isCNKI(url) else { return nil }
        switch url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/")) {
        case "restapi/citation-api/v1/literature/references": return .reference
        case "restapi/citation-api/v1/literature/citations": return .citation
        case "openapi/usercenter-api/v1/recommend/similar/articles": return .related
        default: return nil
        }
    }

    public static func decode(_ data: Data, endpoint: URL) throws -> CNKIRelationBatch {
        guard data.count <= 1_048_576, let relation = relation(for: endpoint),
              let raw = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              raw["success"] as? Bool != false else { throw ParseError.invalidResponse }
        if let code = raw["code"] {
            guard ["0", "200", "0000"].contains(string(code)) else { throw ParseError.invalidResponse }
        }
        let container = raw["data"] as? [String: Any]
        let rows = relation == .related ? raw["data"] as? [[String: Any]] : container?["data"] as? [[String: Any]]
        guard let rows else { throw ParseError.invalidResponse }
        let total = integer(container?["total"] ?? container?["totalCount"])
        var papers: [GraphPaper] = []
        var seen = Set<String>()
        for row in rows.prefix(200) {
            let fields = row["metadata"] as? [[String: Any]] ?? []
            var metadata: [String: String] = [:]
            for field in fields.prefix(100) {
                let name = string(field["name"])
                if name.count <= 40 { metadata[name] = String(string(field["value"]).prefix(8_192)) }
            }
            let title = clean(metadata["TI"] ?? metadata["CTI"] ?? "")
            guard (2...1_000).contains(title.count), !normalizedTitle(title).isEmpty else { continue }
            let authorRows = row["authors"] as? [[String: Any]] ?? []
            var authors = authorRows.prefix(20).map { clean(string($0["name"])) }.filter { !$0.isEmpty }
            if authors.isEmpty {
                authors = (metadata["AU"] ?? metadata["CAU"] ?? "")
                    .components(separatedBy: CharacterSet(charactersIn: ";；、"))
                    .map(clean).filter { !$0.isEmpty }
            }
            authors = authors.prefix(20).map { String($0.prefix(100)) }
            var url: URL?
            for link in (row["relations"] as? [[String: Any]] ?? []).prefix(30)
            where string(link["scope"]) == "ZKABSTRACT" {
                url = CNKIPage.articleURL(string(link["url"]), relativeTo: endpoint)
                if url != nil { break }
            }
            if url == nil, let filename = metadata["FN"], !filename.isEmpty, filename.count <= 200 {
                var parts = URLComponents(string: "https://kns.cnki.net/kcms2/article/abstract")
                parts?.queryItems = [URLQueryItem(name: "filename", value: filename),
                                     URLQueryItem(name: "product", value: metadata["product"] ?? "")]
                url = parts?.url
            }
            let year = integer(metadata["YE"]).flatMap { (1800...2199).contains($0) ? $0 : nil }
            let key = normalizedTitle(title) + "|" + authors.joined(separator: ",") + "|" + (year.map(String.init) ?? "")
            guard seen.insert(key).inserted else { continue }
            var citations = integer(metadata["CF"] ?? metadata["CTC"])
            for metric in (row["metrics"] as? [[String: Any]] ?? []).prefix(30)
            where string(metric["name"]) == "CTC" { citations = integer(metric["value"]) }
            papers.append(GraphPaper(id: identifier(title: title, authors: authors, year: year), doi: metadata["DOI"], title: title,
                authors: authors, year: year, venue: String(clean(metadata["LY"] ?? metadata["JN"] ?? "").prefix(300)),
                abstract: "", openAccessURL: url, referencedIDs: [], relatedIDs: [], citedByCount: citations ?? 0))
            if papers.count == limit { break }
        }
        guard rows.isEmpty || !papers.isEmpty else { throw ParseError.invalidResponse }
        return CNKIRelationBatch(relation: relation, papers: papers, total: total,
            isPartial: papers.count < (total ?? rows.count) || rows.count > limit)
    }

    public static func normalizedTitle(_ title: String) -> String {
        title.lowercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }.map(String.init).joined()
    }

    public static func identifier(title: String, authors: [String], year: Int?) -> String {
        let key = normalizedTitle(title) + "|" + authors.joined(separator: ",") + "|" + (year.map(String.init) ?? "")
        return "cnki:" + SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// Never silently choose a same-title paper with conflicting author/year data.
    public static func uniqueMatch(_ papers: [CNKIPaper], identity: GraphIdentity) -> CNKIPaper? {
        let matches = papers.filter {
            normalizedTitle($0.title) == normalizedTitle(identity.title)
                && (identity.year == nil || $0.year == identity.year)
                && (identity.authors.isEmpty || !Set(identity.authors.map(normalizedTitle))
                    .isDisjoint(with: Set($0.authors.map(normalizedTitle))))
        }
        return matches.count == 1 ? matches.first : nil
    }

    private static func clean(_ value: String) -> String { CNKIPage.normalizedQuery(value) }
    private static func string(_ value: Any?) -> String {
        if let value = value as? String { return value }
        if let value = value as? NSNumber { return value.stringValue }
        return ""
    }
    private static func integer(_ value: Any?) -> Int? {
        Int(string(value).replacingOccurrences(of: ",", with: "")).flatMap { $0 >= 0 ? $0 : nil }
    }
    public enum ParseError: Error, LocalizedError {
        case invalidResponse
        public var errorDescription: String? { "知网未返回有效关系数据；没有将错误或空权限响应当作零篇文献。" }
    }
}

extension CNKIPaper {
    public var graphPaper: GraphPaper {
        GraphPaper(id: CNKIRelationBatch.identifier(title: title, authors: authors, year: year),
            doi: nil, title: title, authors: authors, year: year, venue: journal, abstract: "",
            openAccessURL: url, referencedIDs: [], relatedIDs: [], citedByCount: citations ?? 0)
    }
}
