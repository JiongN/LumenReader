import Foundation

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

/// Agent 的「联网搜索文献」能力。
///
/// 数据源选择是**被约束逼出来的**，不是随手挑的：知网（CNKI）没有公开接口，
/// 抓取违反其服务条款；万方只有需要申请审批的开放平台；Web of Science 是
/// Clarivate 的机构订阅接口，个人拿不到 key。所以这里用三个**免密钥、有公开文档、
/// 长期稳定**的学术数据源：
///
/// - **Crossref**：全球 DOI 注册库，中文期刊凡注册过 DOI 的（相当一部分 CSSCI 期刊）也能查到；
/// - **OpenAlex**：OurResearch 运营的开放学术图谱，为程序化访问设计，明确支持
///   `mailto` 礼貌池，覆盖期刊与会议；
/// - **arXiv**：预印本，教育技术、学习科学领域的很多新工作先出现在这里。
///
/// **Semantic Scholar 被换掉了**，理由是实测而非偏好：它不带 API key 时走共享配额池，
/// 本机连测两次都是 HTTP 429（`curl` 与 `--agent-report` 两条通道都复现），
/// 也就是说它在默认配置下**基本不产出结果**、只贡献一个错误。
/// 「查得到」比「源多一个」重要，所以宁可换成真正可用的那一源。
///
/// 三者都只返回元数据（标题/作者/年份/来源/摘要），回答里引用的是可核查的出处，
/// 而不是模型凭印象写出来的「某某（2019）研究表明」——后者是这类功能最容易翻车的地方。
public enum WebLiteratureSearch {

    /// 各源默认取几条。总数控制在 10 条以内：塞太多会把原文上下文挤掉。
    public static let perSource = 4

    public struct Outcome: Sendable {
        public var hits: [LiteratureHit]
        /// 各源的失败说明（有失败但不是全失败时，仍要把结果给模型，只是提示读者注意）
        public var failures: [String]

        public var isEmpty: Bool { hits.isEmpty }
    }

    /// 并发检索三个源。任何一个源失败都不影响其余结果。
    public static func search(query: String, timeout: TimeInterval = 10) async -> Outcome {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 2 else { return Outcome(hits: [], failures: []) }

        return await withTaskGroup(of: (String, Result<[LiteratureHit], Error>).self) { group in
            group.addTask { ("Crossref", await crossref(trimmed, timeout: timeout)) }
            group.addTask { ("OpenAlex", await openAlex(trimmed, timeout: timeout)) }
            group.addTask { ("arXiv", await arxiv(trimmed, timeout: timeout)) }

            var hits: [LiteratureHit] = []
            var failures: [String] = []
            for await (name, result) in group {
                switch result {
                case .success(let found): hits.append(contentsOf: found)
                case .failure(let error):
                    failures.append("\(name)：\(error.localizedDescription)")
                }
            }

            // 去重：同一篇可能同时被 Crossref 与 Semantic Scholar 返回。
            // 用标题归一化后比对（标点与大小写差异不该被当成两篇）。
            var seen = Set<String>()
            let deduped = hits.filter { hit in
                let key = normalize(hit.title)
                guard !key.isEmpty, !seen.contains(key) else { return false }
                seen.insert(key)
                return true
            }
            return Outcome(hits: deduped, failures: failures)
        }
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
        guard !outcome.isEmpty else { return "" }

        var lines = ["【联网检索到的文献（来自公开学术数据库）】"]
        for (index, hit) in outcome.hits.prefix(10).enumerated() {
            var entry = "\(index + 1). \(hit.title)"
            if !hit.authors.isEmpty { entry += " — \(hit.authors)" }
            if !hit.year.isEmpty { entry += "（\(hit.year)）" }
            if !hit.venue.isEmpty { entry += "，\(hit.venue)" }
            if !hit.identifier.isEmpty { entry += "，\(hit.identifier)" }
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
        // 带上一个可联系的标识是 Crossref 的「礼貌池」要求，能显著降低被限流的概率
        request.setValue("Lumen/1.0 (mailto:reader@example.com)", forHTTPHeaderField: "User-Agent")
        return request
    }

    private static func fetchJSON(_ url: URL, timeout: TimeInterval) async -> Result<Any, Error> {
        do {
            let (data, response) = try await URLSession.shared.data(for: request(url, timeout: timeout))
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                return .failure(SearchError.http(http.statusCode))
            }
            guard let object = try? JSONSerialization.jsonObject(with: data) else {
                return .failure(SearchError.malformed)
            }
            return .success(object)
        } catch {
            return .failure(error)
        }
    }

    /// 带退避的重试。只重试**暂时性**失败，且只再试一次。
    ///
    /// 它修的是「瞬时限流 / 服务端抖一下」这类问题：一次运气不好就让整整一个数据源缺席，
    /// 代价与收益不成比例。
    ///
    /// 它**修不了结构性限流**——那种要靠换源，不靠重试。Semantic Scholar 就是这样退场的：
    /// 不带 key 时走共享配额池，本机连着跑两次都是 429，重试只是白等 1.2s。
    /// 判断标准很简单：重试后仍然每次都失败的源，说明它需要的不是重试而是 key。
    ///
    /// 为什么只重试一次、退避 1.2s：三个源是并发跑的，最慢的那个决定整体耗时。
    /// 读者在等一次回答，不能为了凑齐第三个源让他多等好几秒。
    /// 重试的定位是「提高命中率」，不是「保证成功」——重试后仍失败就如实报给读者，
    /// 而不是把失败吞掉、让「查不到文献」变成查不出原因的黑盒。
    private static func withRetry<T>(
        attempts: Int = 2,
        _ operation: () async -> Result<T, Error>
    ) async -> Result<T, Error> {
        var last: Result<T, Error> = .failure(SearchError.malformed)
        for attempt in 0..<max(1, attempts) {
            last = await operation()
            if case .success = last { return last }
            if case .failure(let error) = last, !isTransient(error) { return last }
            if attempt < attempts - 1 {
                try? await Task.sleep(nanoseconds: 1_200_000_000 * UInt64(attempt + 1))
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
            return [.timedOut, .networkConnectionLost, .cannotConnectToHost, .notConnectedToInternet]
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

    static func crossref(_ query: String, timeout: TimeInterval) async -> Result<[LiteratureHit], Error> {
        var components = URLComponents(string: "https://api.crossref.org/works")!
        components.queryItems = [
            URLQueryItem(name: "query.bibliographic", value: query),
            URLQueryItem(name: "rows", value: String(perSource)),
            URLQueryItem(name: "select", value: "title,author,issued,container-title,DOI,abstract,type")
        ]
        guard let url = components.url else { return .failure(SearchError.malformed) }

        switch await withRetry({ await fetchJSON(url, timeout: timeout) }) {
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
                    abstract: abstract,
                    source: "Crossref"
                )
            }
            return .success(hits)
        }
    }

    // MARK: OpenAlex

    static func openAlex(_ query: String, timeout: TimeInterval) async -> Result<[LiteratureHit], Error> {
        var components = URLComponents(string: "https://api.openalex.org/works")!
        components.queryItems = [
            URLQueryItem(name: "search", value: query),
            URLQueryItem(name: "per-page", value: String(perSource)),
            // 带上邮箱即进入礼貌池，这是 OpenAlex 官方推荐的用法
            URLQueryItem(name: "mailto", value: "reader@example.com"),
            URLQueryItem(name: "select", value: "title,publication_year,doi,authorships,primary_location,abstract_inverted_index")
        ]
        guard let url = components.url else { return .failure(SearchError.malformed) }

        switch await withRetry({ await fetchJSON(url, timeout: timeout) }) {
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
                var identifier = item["doi"] as? String ?? ""
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
            for position in positions { placed.append((position, word)) }
        }
        return placed.sorted { $0.position < $1.position }
            .map(\.word)
            .joined(separator: " ")
    }

    // MARK: arXiv（Atom XML）

    static func arxiv(_ query: String, timeout: TimeInterval) async -> Result<[LiteratureHit], Error> {
        var components = URLComponents(string: "https://export.arxiv.org/api/query")!
        components.queryItems = [
            URLQueryItem(name: "search_query", value: "all:\(query)"),
            URLQueryItem(name: "max_results", value: String(perSource))
        ]
        guard let url = components.url else { return .failure(SearchError.malformed) }

        // arXiv 返回的是 Atom XML，不走 fetchJSON；重试逻辑与另两个源共用
        return await withRetry { () async -> Result<[LiteratureHit], Error> in
            do {
                let (data, response) = try await URLSession.shared.data(
                    for: request(url, timeout: timeout, accept: "application/atom+xml")
                )
                if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                    return .failure(SearchError.http(http.statusCode))
                }
                return .success(ArxivAtomParser().parse(data))
            } catch {
                return .failure(error)
            }
        }
    }
}

// MARK: - arXiv Atom 解析

/// 极小的 Atom 解析器：只取 arXiv 返回里我们真正要用的四个字段。
/// 不引第三方 XML 库——为一个 feed 拉一个依赖不划算，而 Atom 结构固定得很。
final class ArxivAtomParser: NSObject, XMLParserDelegate {

    private var hits: [LiteratureHit] = []
    private var current: [String: String] = [:]
    private var text = ""
    private var insideEntry = false

    func parse(_ data: Data) -> [LiteratureHit] {
        let parser = XMLParser(data: data)
        parser.delegate = self
        parser.parse()
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
        text += string
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
            if let title = current["title"], !title.isEmpty {
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
