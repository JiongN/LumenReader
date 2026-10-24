import Foundation

public struct SemanticIndexConfiguration: Sendable {
    public var provider: AIProviderConfig
    public var model: String
    public var apiKey: String
    public init(provider: AIProviderConfig, model: String, apiKey: String) {
        self.provider = provider; self.model = model; self.apiKey = apiKey
    }
}

/// Shared bounded transport for non-streaming document services.
public struct DocumentAIClient: Sendable {
    public var baseURL: String
    public var apiKey: String
    private let session: URLSession
    public init(baseURL: String, apiKey: String, session: URLSession? = nil) {
        self.baseURL = baseURL; self.apiKey = apiKey
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 90
        configuration.timeoutIntervalForResource = 180
        configuration.waitsForConnectivity = false
        self.session = session ?? URLSession(configuration: configuration)
    }

    public func post<Body: Encodable & Sendable, Response: Decodable & Sendable>(_ suffix: String, body: Body,
            response: Response.Type, limit: Int = 8 * 1024 * 1024, headers: [String: String] = [:]) async throws -> Response {
        guard let components = URLComponents(string: baseURL), let host = components.host, !host.isEmpty,
              ["https", "http"].contains(components.scheme?.lowercased() ?? ""),
              components.user == nil, components.password == nil, components.query == nil, components.fragment == nil,
              let url = URL(string: baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + suffix) else { throw AIError.invalidBaseURL("") }
        let local = host == "localhost" || host == "127.0.0.1" || host == "::1"
        guard local || !apiKey.isEmpty else { throw AIError.missingAPIKey }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if !apiKey.isEmpty, headers.keys.allSatisfy({ $0.caseInsensitiveCompare("Authorization") != .orderedSame }) {
            request.setValue("Bearer " + apiKey, forHTTPHeaderField: "Authorization")
        }
        for (name, value) in headers {
            if name.caseInsensitiveCompare("Authorization") == .orderedSame, value.isEmpty {
                request.setValue(nil, forHTTPHeaderField: name)
            } else { request.setValue(value, forHTTPHeaderField: name) }
        }
        let encoded = try JSONEncoder().encode(body)
        guard encoded.count <= 24 * 1024 * 1024 else { throw AIError.responseTooLarge }
        request.httpBody = encoded
        try await AsyncRequestGate.cloud.acquire()
        defer { Task { await AsyncRequestGate.cloud.release() } }
        try Task.checkCancellation()
        let (bytes, reply) = try await session.bytes(for: request, delegate: SameOriginRedirectPolicy())
        let data = try await BoundedResponseData.read(bytes, response: reply, maximum: limit)
        guard let http = reply as? HTTPURLResponse else { throw AIError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else {
            throw AIError.http(status: http.statusCode, message: Self.failureMessage(data, status: http.statusCode))
        }
        try Task.checkCancellation()
        return try JSONDecoder().decode(Response.self, from: data)
    }

    static func failureMessage(_ data: Data, status: Int) -> String {
        // Classify known errors without echoing document data, keys or arbitrary server text.
        let body = String(decoding: data.prefix(16_000), as: UTF8.self).lowercased()
        if body.contains("service tier capacity") || body.contains("insufficient_quota") || body.contains("insufficient credits") {
            return "该账号的服务层级或可用额度不足，请在服务商控制台核对该模型的配额和计费状态；未自动重试。"
        }
        switch status {
        case 401: return "解析密钥无效或已失效，请检查所选服务商的密钥。"
        case 402: return "服务商要求可用余额或已启用计费，请检查账号额度。"
        case 403: return "该账号没有访问所选模型或接口的权限。"
        case 429: return "服务商限制了请求频率或模型容量，已暂停后续云端请求；未自动重试。"
        case 400, 404, 422: return "服务商拒绝了模型名称或请求参数，请核对 OCR 模型与接口版本；未自动重试。"
        default: return "文档服务请求失败；未自动重试收费请求。"
        }
    }

    public func embeddings(_ inputs: [String], model: String) async throws -> [[Double]] {
        struct Body: Encodable, Sendable { var model: String; var input: [String] }
        struct Response: Decodable, Sendable {
            struct Item: Decodable, Sendable { var index: Int; var embedding: [Double] }
            var data: [Item]
        }
        guard !inputs.isEmpty, inputs.count <= 32, !model.isEmpty else { throw AIError.invalidResponse }
        let response = try await post("/embeddings", body: Body(model: model, input: inputs), response: Response.self)
        let sorted = response.data.sorted { $0.index < $1.index }
        guard sorted.map(\.index) == Array(inputs.indices), let dimension = sorted.first?.embedding.count,
              (1...8192).contains(dimension), sorted.allSatisfy({ $0.embedding.count == dimension && $0.embedding.allSatisfy(\.isFinite) }) else {
            throw AIError.invalidResponse
        }
        return sorted.map(\.embedding)
    }

    public static func cosine(_ left: [Double], _ right: [Double]) -> Double {
        guard left.count == right.count, !left.isEmpty else { return 0 }
        let dot = zip(left, right).reduce(0) { $0 + $1.0 * $1.1 }
        let norm = sqrt(left.reduce(0) { $0 + $1 * $1 } * right.reduce(0) { $0 + $1 * $1 })
        return norm > 0 ? dot / norm : 0
    }
}
