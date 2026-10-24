import Foundation

/// 微软翻译（必应在线翻译）的免密钥通道。
///
/// 微软官方的 Translator Text API 要订阅键；必应网页版自己用的那个
/// `/ttranslatev3` 接口是免注册的，代价是凭证要从翻译页的 HTML 里取：
/// 页面里有一组 `params_AbusePreventionHelper = [时间戳, token, 有效期]`，
/// 加上 `IG` / `IID` 两个页面标识，四件套拼起来才能发请求。
///
/// 这是**抓取页面里的运行时参数**，不是逆向私有协议——但正因为如此，
/// 页面结构一变它就会失效。所以它只承担「尽力而为」的翻译：
/// 拿不到凭证就明确报错，由界面提示，绝不静默返回空字符串假装成功。
public actor MicrosoftTranslator {

    // MARK: 错误

    public enum TranslationError: Error, LocalizedError, Equatable {
        /// 页面里取不到凭证（页面结构变了 / 网络不通 / 被反爬拦了）。
        case credentialsUnavailable
        /// 接口返回了非 200。`body` 只留前 120 字符，够定位又不至于刷屏。
        case serverStatus(Int, String)
        case emptyResponse
        case undecodable

        public var errorDescription: String? {
            switch self {
            case .credentialsUnavailable:
                return "取不到微软翻译的访问凭证"
            case .serverStatus(let code, let body):
                return "翻译接口返回 \(code)\(body.isEmpty ? "" : "：\(body)")"
            case .emptyResponse:
                return "翻译接口返回了空结果"
            case .undecodable:
                return "翻译结果无法解析"
            }
        }

        var needsCredentialRefresh: Bool {
            if case .serverStatus(let code, _) = self {
                return [400, 401, 403].contains(code)
            }
            return false
        }
    }

    // MARK: 凭证

    public struct Credentials: Sendable, Equatable {
        /// `params_AbusePreventionHelper` 的第一项（毫秒时间戳，请求里叫 `key`）
        public let key: String
        /// `params_AbusePreventionHelper` 的第二项
        public let token: String
        /// 页面里的 `IG`
        public let ig: String
        /// 页面里的 `IID`（取不到时退回翻译页的固定值）
        public let iid: String
    }

    public static let shared = MicrosoftTranslator()

    private static let pageURL = URL(string: "https://cn.bing.com/translator")!
    private static let endpoint = URL(string: "https://cn.bing.com/ttranslatev3")!
    private static let fallbackIID = "translator.5021"
    private static let browserUA =
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 "
        + "(KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36 Edg/126.0.0.0"

    private let session: URLSession
    private var credentials: Credentials?
    private var credentialsDate: Date = .distantPast
    private var credentialTask: Task<Credentials, Error>?
    private var rateLimitedUntil: Date = .distantPast
    /// 页面给的有效期是 1 小时，这里 40 分钟就换，不在边界上赌。
    private let refreshInterval: TimeInterval = 40 * 60

    public init(session: URLSession = .shared) {
        self.session = session
    }

    // MARK: 翻译

    /// 翻译一段文本。`to` / `from` 用必应的语言标签（`zh-Hans` / `en` / `auto-detect`）。
    ///
    /// Retry once for stale credentials or a transient connection/server failure.
    /// Rate limiting is shared across callers; changing credentials cannot bypass it.
    public func translate(_ text: String, to target: String, from source: String = "auto-detect") async throws -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }

        var refresh = false
        for attempt in 0..<2 {
            try Task.checkCancellation()
            guard Date() >= rateLimitedUntil else { throw TranslationError.serverStatus(429, "") }
            do {
                let credentials = try await currentCredentials(forceRefresh: refresh)
                try Task.checkCancellation()
                return try await perform(trimmed, to: target, from: source, credentials: credentials)
            } catch {
                try Task.checkCancellation()
                guard attempt == 0 else { throw error }
                if let error = error as? TranslationError, error.needsCredentialRefresh {
                    refresh = true
                    continue
                }
                if Self.isTransient(error) {
                    try await Task.sleep(for: .milliseconds(500))
                    continue
                }
                throw error
            }
        }
        throw TranslationError.emptyResponse
    }

    private static func isTransient(_ error: Error) -> Bool {
        if case TranslationError.serverStatus(let status, _) = error {
            return [500, 502, 503, 504].contains(status)
        }
        let ns = error as NSError
        return ns.domain == NSURLErrorDomain && [NSURLErrorTimedOut, NSURLErrorNetworkConnectionLost,
            NSURLErrorCannotConnectToHost].contains(ns.code)
    }

    // MARK: 请求

    private func perform(
        _ text: String,
        to target: String,
        from source: String,
        credentials: Credentials
    ) async throws -> String {
        var components = URLComponents(url: Self.endpoint, resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "isVertical", value: "1"),
            URLQueryItem(name: "IG", value: credentials.ig),
            URLQueryItem(name: "IID", value: credentials.iid)
        ]

        var request = URLRequest(url: components.url ?? Self.endpoint)
        request.timeoutInterval = 20
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue(Self.pageURL.absoluteString, forHTTPHeaderField: "Referer")
        request.setValue(Self.browserUA, forHTTPHeaderField: "User-Agent")

        var form = URLComponents()
        form.queryItems = [
            URLQueryItem(name: "fromLang", value: source),
            URLQueryItem(name: "to", value: target),
            URLQueryItem(name: "text", value: text),
            URLQueryItem(name: "token", value: credentials.token),
            URLQueryItem(name: "key", value: credentials.key)
        ]
        // URLComponents treats '+' as a literal; HTML form decoders treat it as a space.
        request.httpBody = form.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B").data(using: .utf8)

        let (bytes, response) = try await session.bytes(for: request)
        let data = try await BoundedResponseData.read(bytes, response: response, maximum: 1024 * 1024)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status == 429 { recordRateLimit(response) }
        guard status == 200 else {
            let body = String(data: data, encoding: .utf8) ?? ""
            let prefix = String(body.prefix(120))
            throw TranslationError.serverStatus(status, prefix)
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) else { throw TranslationError.undecodable }
        if let failure = json as? [String: Any], let code = failure["statusCode"] as? Int, code != 200 {
            if code == 429 { recordRateLimit(response) }
            throw TranslationError.serverStatus(code, "")
        }
        guard
              let list = json as? [[String: Any]],
              let first = list.first,
              let translations = first["translations"] as? [[String: Any]],
              let text = translations.first?["text"] as? String else {
            throw TranslationError.undecodable
        }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw TranslationError.emptyResponse }
        return text
    }

    private func recordRateLimit(_ response: URLResponse) {
        let header = (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Retry-After")
        let seconds: TimeInterval
        if let header, let value = TimeInterval(header), value.isFinite, value >= 0 {
            seconds = value
        } else if let header {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = TimeZone(secondsFromGMT: 0)
            formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
            seconds = formatter.date(from: header)?.timeIntervalSinceNow ?? 60
        } else { seconds = 60 }
        rateLimitedUntil = max(rateLimitedUntil, Date().addingTimeInterval(max(1, seconds)))
    }

    // MARK: 凭证获取与缓存

    private func currentCredentials(forceRefresh: Bool) async throws -> Credentials {
        let cached = credentials
        let age = Date().timeIntervalSince(credentialsDate)

        if !forceRefresh, let cached, age < refreshInterval { return cached }

        if let credentialTask { return try await credentialTask.value }
        let pending = Task { try await self.fetchCredentials() }
        credentialTask = pending
        defer { credentialTask = nil }
        let fresh = try await pending.value
        credentials = fresh
        credentialsDate = Date()
        return fresh
    }

    private func fetchCredentials() async throws -> Credentials {
        var request = URLRequest(url: Self.pageURL)
        request.timeoutInterval = 20
        request.setValue(Self.browserUA, forHTTPHeaderField: "User-Agent")
        request.setValue("zh-CN,zh;q=0.9,en;q=0.8", forHTTPHeaderField: "Accept-Language")
        request.setValue("text/html,application/xhtml+xml", forHTTPHeaderField: "Accept")

        let (bytes, response) = try await session.bytes(for: request)
        let data = try await BoundedResponseData.read(bytes, response: response, maximum: 8 * 1024 * 1024)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status == 429 { recordRateLimit(response) }
        guard status == 200 else {
            throw TranslationError.serverStatus(status, "")
        }
        let html = String(data: data, encoding: .utf8) ?? String(decoding: data, as: UTF8.self)
        guard let parsed = BingTranslateCredentialsParser.parse(html: html) else {
            throw TranslationError.credentialsUnavailable
        }
        return parsed
    }
}

// MARK: - 凭证解析

/// 从必应翻译页的 HTML 里取出四件套。
///
/// 单独成一个类型是为了能被单测直接喂一段 HTML——这条解析是整个功能里
/// 最脆弱的一环（页面一改就断），不能只在联网时才能验。
public enum BingTranslateCredentialsParser {

    public static func parse(html: String) -> MicrosoftTranslator.Credentials? {
        // params_AbusePreventionHelper = [1789835014974,"M3pf81...",3600000];
        guard let pair = capture(html, pattern: #"params_AbusePreventionHelper\s*=\s*\[\s*(\d+)\s*,\s*"([^"]+)""#, groups: [1, 2]),
              pair.count == 2 else { return nil }
        let key = pair[0]
        let token = pair[1]
        // 页面里 IG 这个键**不带引号**（`...,RTL:false,IG:"351E..."`），
        // 所以这里不能写成 `"IG"`——照 JSON 的样子去写会一条都匹配不到。
        guard let ig = capture(html, pattern: #"IG\s*:\s*"([^"]+)""#, groups: [1])?.first else { return nil }
        let iid = capture(html, pattern: #"_iid\s*=\s*"([^"]+)""#, groups: [1])?.first ?? "translator.5021"
        return MicrosoftTranslator.Credentials(key: key, token: token, ig: ig, iid: iid)
    }

    private static func capture(_ text: String, pattern: String, groups: [Int]) -> [String]? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        guard let match = regex.firstMatch(in: text, options: [], range: range) else { return nil }
        var out: [String] = []
        for group in groups where group < match.numberOfRanges {
            guard let r = Range(match.range(at: group), in: text) else { return nil }
            out.append(String(text[r]))
        }
        return out
    }
}
