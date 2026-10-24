import Foundation
import NaturalLanguage

// MARK: - 文献检索结果

public struct LiteratureHit: Sendable, Equatable {
    public var title: String
    public var authors: String
    public var year: String
    public var venue: String
    /// DOI、arXiv 编号或可访问链接
    public var identifier: String
    public var abstract: String
    /// 来源库名，便于在回答里注明「检索自 Crossref」这类信息
    public var source: String

    public init(title: String, authors: String, year: String, venue: String, identifier: String, abstract: String, source: String) {
        self.title = title
        self.authors = authors
        self.year = year
        self.venue = venue
        self.identifier = identifier
        self.abstract = abstract
        self.source = source
    }
}

// MARK: - 联网文献检索

/// Crossref/OpenAlex/arXiv metadata search, not general web browsing.
/// OpenAlex uses the configured API key; source failures remain visible.
/// Only returned titles, identifiers and abstracts become search evidence.
public enum WebLiteratureSearch {
    private static let networkSession: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 6
        config.timeoutIntervalForResource = 10
        config.waitsForConnectivity = false
        return URLSession(configuration: config)
    }()

    /// 各源默认取几条。总数控制在 10 条以内：塞太多会把原文上下文挤掉。
    public static let perSource = 6

    public struct QueryPlan: Codable, Sendable, Equatable {
        public var query: String
        public var fallbackQuery: String?
        public var nativeQuery: String?

        public init(query: String, fallbackQuery: String? = nil, nativeQuery: String? = nil) {
            self.query = query
            self.fallbackQuery = fallbackQuery
            self.nativeQuery = nativeQuery
        }

        public var queries: [String] {
            var seen = Set<String>()
            return [query, fallbackQuery, nativeQuery].compactMap { value in
                guard let value else { return nil }
                let clean = value.trimmingCharacters(in: .whitespacesAndNewlines)
                guard (2...180).contains(clean.count), !clean.contains("\n"),
                      seen.insert(clean.lowercased()).inserted else { return nil }
                return clean
            }
        }
    }

    public struct Outcome: Sendable {
        public var hits: [LiteratureHit]
        /// 各源的失败说明（有失败但不是全失败时，仍要把结果给模型，只是提示读者注意）
        public var failures: [String]
        public var query: String = ""
        public var cached = false

        public init(hits: [LiteratureHit], failures: [String], query: String = "") {
            self.hits = hits
            self.failures = failures
            self.query = query
        }

        public var isEmpty: Bool { hits.isEmpty }
    }

    /// At most three query variants; only weak initial recall triggers expansion.
    public static func search(plan: QueryPlan, timeout: TimeInterval = 6, openAlexKey: String? = nil,
                              session: URLSession? = nil) async -> Outcome {
        let session = session ?? networkSession
        let queries = plan.queries
        guard let first = queries.first else { return .init(hits: [], failures: []) }
        let key = "\(ObjectIdentifier(session)):\(openAlexKey ?? ""):\(queries.joined(separator: "|"))"
        if var cached = await LiteratureSearchCache.shared.value(for: key) {
            cached.cached = true
            return cached
        }
        var outcome = await search(query: first, timeout: timeout, openAlexKey: openAlexKey, session: session)
        var used = [first]
        if outcome.hits.count < 4, queries.count > 1, !Task.isCancelled {
            // Expand Crossref/OpenAlex only. Long AND expressions on arXiv are
            // unlikely to help, and one slow preprint source must not multiply delay.
            let expanded = await withTaskGroup(of: Outcome.self, returning: [Outcome].self) { group in
                for query in queries.dropFirst() {
                    group.addTask {
                        async let cross = crossref(query, timeout: timeout, session: session)
                        async let alex = openAlex(query, timeout: timeout, apiKey: openAlexKey, session: session)
                        var hits: [LiteratureHit] = []
                        var failures: [String] = []
                        let (crossResult, alexResult) = await (cross, alex)
                        for (name, result) in [("Crossref", crossResult), ("OpenAlex", alexResult)] {
                            switch result {
                            case .success(let values): hits += values
                            case .failure(let error): failures.append("\(name)：\(error.localizedDescription)")
                            }
                        }
                        return .init(hits: ranked(hits, query: query), failures: failures, query: query)
                    }
                }
                var results: [Outcome] = []
                for await result in group { results.append(result) }
                return results.sorted { $0.query < $1.query }
            }
            for result in expanded {
                outcome.hits += result.hits
                outcome.failures += result.failures
                used.append(result.query)
            }
        }
        outcome.hits = Array(deduplicated(outcome.hits).prefix(10))
        outcome.query = used.joined(separator: " / ")
        outcome.failures = Array(Set(outcome.failures)).sorted()
        // Empty failures never become sticky. Partial success gets a shorter TTL
        // and retains source errors in the cached outcome.
        if !Task.isCancelled, !outcome.hits.isEmpty {
            await LiteratureSearchCache.shared.store(outcome, key: key)
        }
        return outcome
    }

    /// 并发检索三个源。任何一个源失败都不影响其余结果。
    public static func search(query: String, timeout: TimeInterval = 6, openAlexKey: String? = nil,
                              session: URLSession? = nil) async -> Outcome {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 2 else { return Outcome(hits: [], failures: []) }

        return await withTaskGroup(of: (String, Result<[LiteratureHit], Error>).self) { group in
            group.addTask { ("Crossref", await crossref(trimmed, timeout: timeout, session: session)) }
            group.addTask { ("OpenAlex", await openAlex(trimmed, timeout: timeout, apiKey: openAlexKey, session: session)) }
            group.addTask { ("arXiv", await arxiv(trimmed, timeout: timeout, session: session)) }

            var hits: [LiteratureHit] = []
            var failures: [String] = []
            for await (name, result) in group {
                switch result {
                case .success(let found): hits.append(contentsOf: found)
                case .failure(let error):
                    failures.append("\(name)：\(error.localizedDescription)")
                }
            }

            // 去重：同一篇可能同时被 Crossref 与 OpenAlex 返回。
            // 用标题归一化后比对（标点与大小写差异不该被当成两篇）。
            return Outcome(hits: ranked(hits, query: trimmed), failures: failures.sorted(), query: trimmed)
        }
    }

    /// A fuzzy catalogue match is not automatically relevant evidence.
    public static func ranked(_ hits: [LiteratureHit], query: String) -> [LiteratureHit] {
        let stops: Set<String> = ["the", "and", "for", "with", "from", "this", "that", "what", "how", "why", "are", "was", "has", "its", "related", "literature", "papers", "research", "studies", "find", "please", "文献", "相关", "研究", "查找"]
        let lower = query.lowercased()
        let terms = words(lower).subtracting(stops)
        guard !terms.isEmpty else { return [] }
        let scored = hits.compactMap { hit -> (LiteratureHit, Int)? in
            let title = hit.title.lowercased()
            let detail = (hit.abstract + " " + hit.authors).lowercased()
            let titleWords = words(title)
            let detailWords = words(detail)
            func matchesTerm(_ term: String, text: String, tokens: Set<String>) -> Bool {
                let cjk = term.unicodeScalars.contains { (0x3400...0x9FFF).contains($0.value) }
                return cjk ? text.contains(term) : tokens.contains(term)
            }
            let titleMatches = terms.filter { matchesTerm($0, text: title, tokens: titleWords) }
            let matches = terms.filter { matchesTerm($0, text: title, tokens: titleWords) || matchesTerm($0, text: detail, tokens: detailWords) }
            guard matches.count >= min(2, terms.count) else { return nil }
            return (hit, titleMatches.count * 3 + matches.count)
        }.sorted {
            if $0.1 != $1.1 { return $0.1 > $1.1 }
            if $0.0.abstract.count != $1.0.abstract.count { return $0.0.abstract.count > $1.0.abstract.count }
            if $0.0.title != $1.0.title { return $0.0.title < $1.0.title }
            return $0.0.source < $1.0.source
        }
        return deduplicated(scored.map(\.0))
    }

    private static func words(_ text: String) -> Set<String> {
        let tokenizer = NLTokenizer(unit: .word)
        tokenizer.string = text
        var terms = Set<String>()
        tokenizer.enumerateTokens(in: text.startIndex..<text.endIndex) { range, _ in
            var term = String(text[range]).lowercased()
            if term.count > 4, term.hasSuffix("s"), !term.hasSuffix("ss"), !term.hasSuffix("us"), !term.hasSuffix("is") {
                term.removeLast()
            }
            if term.count >= 2 { terms.insert(term) }
            return true
        }
        if terms.contains("ai") || (terms.contains("artificial") && terms.contains("intelligence")) {
            terms.subtract(["artificial", "intelligence"])
            terms.insert("ai")
        }
        return terms
    }

    private static func deduplicated(_ hits: [LiteratureHit]) -> [LiteratureHit] {
        var result: [LiteratureHit] = []
        var identifiers: [String: Int] = [:]
        var titles: [String: Int] = [:]
        for hit in hits {
            let title = normalize(hit.title)
            guard !title.isEmpty else { continue }
            let identifier = GraphIdentity.normalizedDOI(hit.identifier) ?? hit.identifier.lowercased()
            if let index = (!identifier.isEmpty ? identifiers[identifier] : nil) ?? titles[title] {
                let sources = Set((result[index].source + " / " + hit.source).components(separatedBy: " / "))
                if hit.abstract.count > result[index].abstract.count { result[index] = hit }
                result[index].source = sources.sorted().joined(separator: " / ")
                if !identifier.isEmpty { identifiers[identifier] = index }
                titles[title] = index
            } else {
                if !identifier.isEmpty { identifiers[identifier] = result.count }
                titles[title] = result.count
                result.append(hit)
            }
        }
        return result
    }

    private static func normalize(_ title: String) -> String {
        title.lowercased()
            .replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "：", with: "")
            .replacingOccurrences(of: ":", with: "")
            .trimmingCharacters(in: CharacterSet(charactersIn: ".。，,"))
    }

    // MARK: - 塞进提示词的形态

    /// 把检索结果渲染成提示词里的一段。
    ///
    /// 写成「可核查的清单」而不是让模型自由发挥：每一条都带出处（DOI / arXiv 编号），
    /// 读者点开就能验证。原文没有、检索也没有的内容，明确要求它别编。
    public static func promptBlock(_ outcome: Outcome) -> String {
        var lines = ["【公开学术数据库检索】", "检索词：\(outcome.query)"]
        if !outcome.failures.isEmpty { lines.append("数据源未完成：\(outcome.failures.joined(separator: "；"))") }
        if outcome.isEmpty {
            lines.append("没有取得通过相关性筛选的文献。不得把无结果解释为不存在相关研究，也不得声称已搜索整个互联网。请依据原文回答并说明检索限制。")
            return lines.joined(separator: "\n")
        }
        for (index, hit) in outcome.hits.prefix(10).enumerated() {
            var entry = "\(index + 1). \(hit.title)"
            if !hit.authors.isEmpty { entry += " — \(hit.authors)" }
            if !hit.year.isEmpty { entry += "（\(hit.year)）" }
            if !hit.venue.isEmpty { entry += "，\(hit.venue)" }
            if !hit.identifier.isEmpty { entry += "，\(hit.identifier)" }
            entry += "，来源：\(hit.source)"
            lines.append(entry)
            if !hit.abstract.isEmpty {
                lines.append("   摘要：\(truncate(hit.abstract, limit: 320))")
            }
        }
        lines.append("")
        lines.append("使用要求：上面这些是真实检索结果，可以直接引用，并注明来源（标题 + 作者 + 年份 + DOI/编号）。")
        lines.append("检索结果里没有的文献，不要凭记忆补写；如果读者问到的东西检索不到，明确说「这次联网没有检索到相关文献」。")
        lines.append("这些文献是用来和本书对读的：指出它们与原文的关系（印证 / 分歧 / 补充），不要另起一段做综述。")
        return lines.joined(separator: "\n")
    }

    private static func truncate(_ text: String, limit: Int) -> String {
        let flat = text.replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return flat.count > limit ? String(flat.prefix(limit)) + "…" : flat
    }

    // MARK: - 请求

    private static func request(_ url: URL, timeout: TimeInterval, accept: String = "application/json") -> URLRequest {
        var request = URLRequest(url: url)
        request.timeoutInterval = timeout
        request.setValue(accept, forHTTPHeaderField: "Accept")
        request.setValue("LumenReader/1.0", forHTTPHeaderField: "User-Agent")
        return request
    }

    private static func fetchJSON(_ url: URL, timeout: TimeInterval, session: URLSession,
                                  apiKey: String? = nil) async -> Result<Any, Error> {
        do {
            var request = request(url, timeout: timeout)
            if let apiKey, !apiKey.isEmpty { request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization") }
            let (bytes, response) = try await session.bytes(for: request, delegate: SameOriginRedirectPolicy())
            defer { bytes.task.cancel() }
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                return .failure(SearchError.http(http.statusCode))
            }
            let data = try await BoundedResponseData.read(bytes, response: response, maximum: BoundedResponseData.literatureLimit)
            guard let object = try? JSONSerialization.jsonObject(with: data) else {
                return .failure(SearchError.malformed)
            }
            return .success(object)
        } catch {
            return .failure(error)
        }
    }

    /// 带指数退避的重试。只重试**暂时性**失败。
    ///
    /// 它修的是「瞬时限流 / 服务端抖一下」这类问题：一次运气不好就让整整一个数据源缺席，
    /// 代价与收益不成比例。
    ///
    /// 它**修不了结构性限流**——那种要靠换源，不靠重试。Semantic Scholar 就是这样退场的：
    /// 不带 key 时走共享配额池，本机连着跑两次都是 429，重试只是白等。
    /// 判断标准很简单：重试后仍然每次都失败的源，说明它需要的不是重试而是 key。
    ///
    /// 为什么是「最多 3 次 + 0.8s→1.6s→封顶 2.4s」而不是更早的「2 次 + 固定 1.2s」：
    /// - 退避**指数增长**才符合限流的恢复节奏：429 通常伴随一个窗口，
    ///   固定间隔要么太短（再撞一次墙）要么太长（白白多等）。
    /// - 首退避定在 0.8s 而不是常见的 1s：三个源并发跑，最慢的那个决定整体耗时，
    ///   而读者是在等一次回答。三次尝试的最坏等待是 0.8 + 1.6 = 2.4s，
    ///   再往上加，等待时间就超过「这次检索值不值」了。
    /// - 2.4s 是**封顶值**而不是第三段的实际时长（第三段按 2 的幂本是 3.2s），
    ///   写在这里是为了把最坏情况钉死，将来调 attempts 时不会失控。
    ///
    /// 重试的定位是「提高命中率」，不是「保证成功」——重试后仍失败就如实报给读者，
    /// 而不是把失败吞掉、让「查不到文献」变成查不出原因的黑盒。
    private static let maxAttempts = 2
    private static let baseBackoff: TimeInterval = 0.8
    private static let maxBackoff: TimeInterval = 2.4

    private static func withRetry<T>(
        attempts: Int = maxAttempts,
        _ operation: () async -> Result<T, Error>
    ) async -> Result<T, Error> {
        var last: Result<T, Error> = .failure(SearchError.malformed)
        for attempt in 0..<max(1, attempts) {
            if Task.isCancelled { return .failure(CancellationError()) }
            last = await operation()
            if case .success = last { return last }
            if case .failure(let error) = last, !isTransient(error) { return last }
            if attempt < attempts - 1 {
                let backoff = min(baseBackoff * pow(2, Double(attempt)), maxBackoff)
                do { try await Task.sleep(for: .seconds(backoff)) }
                catch { return .failure(error) }
            }
        }
        return last
    }

    /// 值不值得再试一次。限流与服务端抖动是暂时的；参数错、格式错再试一百次也一样。
    private static func isTransient(_ error: Error) -> Bool {
        if case SearchError.http(let code) = error {
            return code == 429 || code == 408 || (500..<600).contains(code)
        }
        if let urlError = error as? URLError {
            return [.networkConnectionLost, .cannotConnectToHost]
                .contains(urlError.code)
        }
        return false
    }

    public enum SearchError: LocalizedError {
        case http(Int)
        case malformed

        public var errorDescription: String? {
            switch self {
            case .http(let code): return "服务返回 HTTP \(code)"
            case .malformed:      return "返回内容不是预期的格式"
            }
        }
    }

    // MARK: Crossref

    public static func crossref(_ query: String, timeout: TimeInterval, session: URLSession? = nil) async -> Result<[LiteratureHit], Error> {
        var components = URLComponents(string: "https://api.crossref.org/works")!
        components.queryItems = [
            URLQueryItem(name: "query.bibliographic", value: query),
            URLQueryItem(name: "rows", value: String(perSource)),
            URLQueryItem(name: "select", value: "title,author,issued,container-title,DOI,abstract,type")
        ]
        guard let url = components.url else { return .failure(SearchError.malformed) }

        switch await withRetry({ await fetchJSON(url, timeout: timeout, session: session ?? networkSession) }) {
        case .failure(let error):
            return .failure(error)
        case .success(let object):
            guard let root = object as? [String: Any],
                  let message = root["message"] as? [String: Any],
                  let items = message["items"] as? [[String: Any]] else {
                return .failure(SearchError.malformed)
            }
            let hits: [LiteratureHit] = items.compactMap { item in
                guard let titles = item["title"] as? [String], let title = titles.first,
                      !title.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }

                let authors: String = (item["author"] as? [[String: Any]] ?? []).prefix(3).compactMap { author in
                    let family = author["family"] as? String ?? ""
                    let given = author["given"] as? String ?? ""
                    let name = [family, given].filter { !$0.isEmpty }.joined(separator: " ")
                    return name.isEmpty ? nil : name
                }.joined(separator: "、")

                var year = ""
                if let issued = item["issued"] as? [String: Any],
                   let parts = issued["date-parts"] as? [[Int]],
                   let first = parts.first?.first {
                    year = String(first)
                }

                let venue = (item["container-title"] as? [String])?.first ?? ""
                let doi = item["DOI"] as? String ?? ""
                let abstract = (item["abstract"] as? String ?? "")
                    .replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)

                return LiteratureHit(
                    title: title,
                    authors: authors,
                    year: year,
                    venue: venue,
                    identifier: doi.isEmpty ? "" : "DOI: \(doi)",
                    abstract: String(abstract.prefix(4000)),
                    source: "Crossref"
                )
            }
            return .success(hits)
        }
    }

    // MARK: OpenAlex

    public static func openAlex(_ query: String, timeout: TimeInterval, apiKey: String? = nil,
                                session: URLSession? = nil) async -> Result<[LiteratureHit], Error> {
        var components = URLComponents(string: "https://api.openalex.org/works")!
        components.queryItems = [
            URLQueryItem(name: "search", value: query),
            URLQueryItem(name: "per-page", value: String(perSource)),
            URLQueryItem(name: "select", value: "id,title,publication_year,doi,authorships,primary_location,abstract_inverted_index")
        ]
        guard let url = components.url else { return .failure(SearchError.malformed) }

        switch await withRetry({ await fetchJSON(url, timeout: timeout, session: session ?? networkSession, apiKey: apiKey) }) {
        case .failure(let error):
            return .failure(error)
        case .success(let object):
            guard let root = object as? [String: Any],
                  let items = root["results"] as? [[String: Any]] else {
                return .failure(SearchError.malformed)
            }
            let hits: [LiteratureHit] = items.compactMap { item in
                // OpenAlex 同时给 `display_name` 与 `title`，后者可能为 null（如无题预印本）
                let title = (item["title"] as? String)
                    ?? (item["display_name"] as? String)
                    ?? ""
                guard !title.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }

                let authors = (item["authorships"] as? [[String: Any]] ?? [])
                    .prefix(3)
                    .compactMap { ($0["author"] as? [String: Any])?["display_name"] as? String }
                    .joined(separator: "、")

                let year = (item["publication_year"] as? Int).map(String.init) ?? ""

                // 期刊名藏在 primary_location.source 里，任一层都可能是 null
                var venue = ""
                if let location = item["primary_location"] as? [String: Any],
                   let source = location["source"] as? [String: Any] {
                    venue = source["display_name"] as? String ?? ""
                }

                // OpenAlex 的 doi 是完整 URL 形式（https://doi.org/10.xxx），剥掉前缀更省地方
                var identifier = item["doi"] as? String ?? item["id"] as? String ?? ""
                if let range = identifier.range(of: "doi.org/") {
                    identifier = "DOI: " + identifier[range.upperBound...]
                }

                return LiteratureHit(
                    title: title,
                    authors: authors,
                    year: year,
                    venue: venue,
                    identifier: identifier,
                    abstract: abstractFromInvertedIndex(item["abstract_inverted_index"] as? [String: [Int]]),
                    source: "OpenAlex"
                )
            }
            return .success(hits)
        }
    }

    /// 把 OpenAlex 的摘要**倒排索引**还原成正常语序的句子。
    ///
    /// 它不直接给摘要文本，给的是一张「词 → 出现位置数组」的表（受法律约束的取巧做法：
    /// 只有词与位置，不构成原作品的可读复制）。还原就是按位置把所有词排回去。
    /// 缺这一步的话，这一源就只能提供标题与作者，回答里少了最有用的一段。
    public static func abstractFromInvertedIndex(_ index: [String: [Int]]?) -> String {
        guard let index, !index.isEmpty else { return "" }
        var placed: [(position: Int, word: String)] = []
        for (word, positions) in index {
            for position in positions where (0..<10_000).contains(position) {
                if placed.count >= 10_000 { break }
                placed.append((position, word))
            }
            if placed.count >= 10_000 { break }
        }
        return String(placed.sorted { $0.position < $1.position }
            .map(\.word)
            .joined(separator: " ").prefix(4000))
    }

    // MARK: arXiv（Atom XML）

    public static func arxiv(_ query: String, timeout: TimeInterval, session: URLSession? = nil) async -> Result<[LiteratureHit], Error> {
        var components = URLComponents(string: "https://export.arxiv.org/api/query")!
        components.queryItems = [
            URLQueryItem(name: "search_query", value: arxivExpression(query)),
            URLQueryItem(name: "max_results", value: String(perSource))
        ]
        guard let url = components.url else { return .failure(SearchError.malformed) }

        // arXiv 返回的是 Atom XML，不走 fetchJSON；重试逻辑与另两个源共用
        return await withRetry { () async -> Result<[LiteratureHit], Error> in
            do {
                let (bytes, response) = try await (session ?? networkSession).bytes(
                    for: request(url, timeout: timeout, accept: "application/atom+xml"), delegate: SameOriginRedirectPolicy()
                )
                defer { bytes.task.cancel() }
                if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                    return .failure(SearchError.http(http.statusCode))
                }
                let data = try await BoundedResponseData.read(bytes, response: response, maximum: BoundedResponseData.literatureLimit)
                let parser = ArxivAtomParser()
                let hits = parser.parse(data)
                return parser.isMalformed ? .failure(SearchError.malformed) : .success(hits)
            } catch {
                return .failure(error)
            }
        }
    }

    public static func arxivExpression(_ query: String) -> String {
        query.split(whereSeparator: { !$0.isLetter && !$0.isNumber && $0 != "-" })
            .prefix(10).map { "all:\($0)" }.joined(separator: " AND ")
    }
}

// MARK: - arXiv Atom 解析

/// 极小的 Atom 解析器：只取 arXiv 返回里我们真正要用的四个字段。
/// 不引第三方 XML 库——为一个 feed 拉一个依赖不划算，而 Atom 结构固定得很。
final class ArxivAtomParser: NSObject, XMLParserDelegate {
    private(set) var isMalformed = false

    private var hits: [LiteratureHit] = []
    private var current: [String: String] = [:]
    private var text = ""
    private var insideEntry = false

    func parse(_ data: Data) -> [LiteratureHit] {
        let parser = XMLParser(data: data)
        parser.delegate = self
        parser.shouldResolveExternalEntities = false
        isMalformed = !parser.parse()
        return hits
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String,
                namespaceURI: String?, qualifiedName: String?, attributes: [String: String]) {
        switch elementName {
        case "entry":
            insideEntry = true
            current = [:]
        case "author" where insideEntry:
            // <author> 里才有 <name>；feed 级别的 <name> 不属于作者。
            current["inAuthor"] = "1"
        default:
            break
        }
        text = ""
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if text.count < 8192 { text += String(string.prefix(8192 - text.count)) }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String,
                namespaceURI: String?, qualifiedName: String?) {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard insideEntry else { return }

        switch elementName {
        case "title":
            // 只在还没有标题时写入：<feed> 也有 title，进入 entry 之后第一个才是论文标题
            if current["title"] == nil { current["title"] = value }
        case "name":
            if current["inAuthor"] != nil {
                let existing = current["authors"] ?? ""
                current["authors"] = existing.isEmpty ? value : existing + "、" + value
                current["inAuthor"] = nil
            }
        case "published":
            if current["year"] == nil, value.count >= 4 {
                current["year"] = String(value.prefix(4))
            }
        case "id":
            if current["id"] == nil { current["id"] = value }
        case "summary":
            if current["summary"] == nil { current["summary"] = value }
        case "entry":
            insideEntry = false
            if hits.count < WebLiteratureSearch.perSource, let title = current["title"], !title.isEmpty {
                hits.append(LiteratureHit(
                    title: title,
                    authors: current["authors"] ?? "",
                    year: current["year"] ?? "",
                    venue: "arXiv",
                    identifier: current["id"] ?? "",
                    abstract: current["summary"] ?? "",
                    source: "arXiv"
                ))
            }
        default:
            break
        }
        text = ""
    }
}

private actor LiteratureSearchCache {
    static let shared = LiteratureSearchCache()
    private var entries: [String: (Date, WebLiteratureSearch.Outcome)] = [:]

    func value(for key: String) -> WebLiteratureSearch.Outcome? {
        entries = entries.filter { Date().timeIntervalSince($0.value.0) < ($0.value.1.failures.isEmpty ? 600 : 60) }
        return entries[key]?.1
    }

    func store(_ outcome: WebLiteratureSearch.Outcome, key: String) {
        if entries.count >= 32, let oldest = entries.min(by: { $0.value.0 < $1.value.0 })?.key {
            entries.removeValue(forKey: oldest)
        }
        entries[key] = (Date(), outcome)
    }
}
