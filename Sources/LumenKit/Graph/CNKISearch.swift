import Foundation

public struct CNKIPaper: Identifiable, Equatable, Sendable {
    public var id: URL { url }
    public let title: String
    public let authors: [String]
    public let year: Int?
    public let journal: String
    public let citations: Int?
    public let url: URL
    public let query: String
    public var evidence: String { "metadata_only" }

    public init(title: String, authors: [String], year: Int?, journal: String, citations: Int?, url: URL, query: String) {
        self.title = title; self.authors = authors; self.year = year; self.journal = journal
        self.citations = citations; self.url = url; self.query = query
    }

    public var identity: GraphIdentity {
        GraphIdentity(title: title, authors: authors, year: year, source: "知网题录", cnkiURL: url)
    }
}

public enum CNKIPageState: Equatable, Sendable {
    case results, noResults, verificationRequired, loginRequired, unavailable
}

/// Bounded, untrusted DOM data; never a claim that a paper's full text was obtained.
public struct CNKIPage: Sendable {
    public let state: CNKIPageState
    public let papers: [CNKIPaper]
    public let formReady: Bool
    public static let limit = 20

    public func hasNewResults(comparedTo previous: CNKIPage) -> Bool {
        state != .unavailable && (state != previous.state || papers != previous.papers)
    }

    public static func isCNKI(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "https", url.user == nil, url.password == nil,
              url.port == nil || url.port == 443, let host = url.host?.lowercased() else { return false }
        return host == "cnki.net" || host.hasSuffix(".cnki.net")
    }

    public static func searchQuery(_ value: String) -> String? {
        let query = normalizedQuery(value)
        return !query.isEmpty && query.count <= 160 ? query : nil
    }

    public static func normalizedQuery(_ value: String) -> String { clean(value) }

    public static func secureCNKIURL(_ url: URL) -> URL? {
        guard url.scheme?.lowercased() == "http", url.user == nil, url.password == nil,
              url.port == nil || url.port == 80,
              var parts = URLComponents(url: url, resolvingAgainstBaseURL: true) else { return nil }
        parts.scheme = "https"
        parts.port = nil
        guard let secure = parts.url, isCNKI(secure) else { return nil }
        return secure
    }

    public static func decode(_ data: Data, source: URL, query: String) throws -> CNKIPage {
        guard isCNKI(source), data.count <= 256 * 1024 else { throw ParseError.invalidPage }
        let raw = try JSONDecoder().decode(Payload.self, from: data)
        let formReady = raw.formReady ?? false
        if raw.verification == true { return .init(state: .verificationRequired, papers: [], formReady: formReady) }
        if raw.loginRequired == true { return .init(state: .loginRequired, papers: [], formReady: formReady) }
        var papers: [CNKIPaper] = []
        var seen = Set<String>()
        for row in (raw.papers ?? []).prefix(80) {
            let title = clean(row.title ?? "")
            guard title.count >= 2, title.count <= 1_000, let href = row.url, href.count <= 8_192,
                  let url = articleURL(href, relativeTo: source) else { continue }
            let authors = (row.authors ?? []).prefix(20).map { String(clean($0).prefix(100)) }.filter { !$0.isEmpty }
            let year = (row.year ?? "").range(of: #"\b(?:18|19|20)\d{2}\b"#, options: .regularExpression)
                .flatMap { Int((row.year ?? "")[$0]) }
            let identity = "\(title.lowercased())|\(authors.joined(separator: ","))|\(year.map(String.init) ?? "")"
            guard seen.insert(identity).inserted else { continue }
            let citations = Int(clean(row.citations ?? "").replacingOccurrences(of: ",", with: ""))
            papers.append(CNKIPaper(title: title, authors: authors, year: year,
                journal: String(clean(row.journal ?? "").prefix(300)),
                citations: citations.flatMap { $0 >= 0 ? $0 : nil }, url: url, query: query))
            if papers.count == limit { break }
        }
        let state: CNKIPageState = !papers.isEmpty ? .results : raw.noResults == true ? .noResults : .unavailable
        return .init(state: state, papers: papers, formReady: formReady)
    }

    public static func articleURL(_ value: String, relativeTo source: URL) -> URL? {
        guard value.count <= 8_192 else { return nil }
        guard let resolved = URL(string: value, relativeTo: source)?.absoluteURL,
              var parts = URLComponents(url: resolved,
                                        resolvingAgainstBaseURL: true) else { return nil }
        if let secure = parts.url.flatMap(secureCNKIURL) {
            parts = URLComponents(url: secure, resolvingAgainstBaseURL: true) ?? parts
        }
        parts.fragment = nil
        guard let url = parts.url, isCNKI(url) else { return nil }
        let path = url.path.lowercased()
        guard path.contains("/article/") || path.contains("/kcms/detail")
                || path.contains("/kcms2/article/") else { return nil }
        return url
    }

    private static func clean(_ text: String) -> String {
        text.components(separatedBy: .controlCharacters).joined(separator: " ")
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    private struct Payload: Decodable {
        var formReady: Bool?
        var verification: Bool?
        var loginRequired: Bool?
        var noResults: Bool?
        var papers: [Row]?
    }
    private struct Row: Decodable {
        var title: String?
        var authors: [String]?
        var year: String?
        var journal: String?
        var citations: String?
        var url: String?
    }
    public enum ParseError: Error, LocalizedError {
        case invalidPage
        public var errorDescription: String? { "当前网页不是可读取的知网检索页，或返回内容过大。" }
    }
}
