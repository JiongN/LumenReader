import Foundation

/// OpenAI-compatible chat streaming and model discovery, using URLSession.
// The request configuration is immutable after init; URLSession coordinates
// its own concurrent requests. Streams may outlive the caller's task.
public final class OpenAICompatibleProvider: AIProvider, @unchecked Sendable {

    public let displayName: String
    public let modelName: String

    private let config: AIProviderConfig
    private let apiKey: String
    private let session: URLSession
    private let limits: AIStreamLimits

    public init(config: AIProviderConfig, apiKey: String, session: URLSession? = nil, limits: AIStreamLimits = .init()) {
        self.config = config
        self.apiKey = apiKey
        self.displayName = config.name
        self.modelName = config.selectedModel
        self.limits = limits

        let configuration = URLSessionConfiguration.ephemeral
        // 长回复 + 推理模型可能要想很久，给足时间但不要无限等
        configuration.timeoutIntervalForRequest = limits.idleTimeout
        configuration.timeoutIntervalForResource = limits.totalTimeout
        configuration.waitsForConnectivity = false
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        self.session = session ?? URLSession(configuration: configuration)
    }

    // MARK: - 端点拼装

    /// 宽容地拼出 `/chat/completions`。
    ///
    /// 用户填的 Base URL 五花八门：有的带 `/v1`，有的不带，有的末尾多个斜杠，
    /// 甚至有人直接把完整的 `/chat/completions` 粘进来。这里全部兜住。
    func endpoint(_ suffix: String) -> URL? {
        var base = config.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !base.isEmpty else { return nil }
        guard let components = URLComponents(string: base),
              ["http", "https"].contains(components.scheme?.lowercased() ?? ""),
              let host = components.host, !host.isEmpty,
              components.user == nil, components.password == nil,
              components.query == nil, components.fragment == nil else { return nil }

        while base.hasSuffix("/") { base.removeLast() }

        if base.hasSuffix("/chat/completions") {
            base = String(base.dropLast("/chat/completions".count))
        }
        if base.hasSuffix("/models") {
            base = String(base.dropLast("/models".count))
        }
        // 常见服务商的域名根路径，补上 /v1
        if let url = URL(string: base), let host = url.host, url.path.isEmpty || url.path == "/" {
            if ["deepseek.com", "openai.com", "moonshot.cn"].contains(where: { host == $0 || host.hasSuffix("." + $0) }) {
                base += "/v1"
            }
        }
        return URL(string: base + suffix)
    }

    private func authorizedRequest(url: URL) -> URLRequest {
        var request = URLRequest(url: url)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        if !apiKey.isEmpty {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
        return request
    }

    // MARK: - 请求体

    private struct ChatRequest: Encodable {
        struct Message: Encodable {
            let role: String
            let content: String
            var images: [AIImage] = []
            enum CodingKeys: String, CodingKey { case role, content }
            func encode(to encoder: Encoder) throws {
                var container = encoder.container(keyedBy: CodingKeys.self)
                try container.encode(role, forKey: .role)
                if images.isEmpty { try container.encode(content, forKey: .content); return }
                struct Part: Encodable {
                    struct ImageURL: Encodable { var url: String; var detail = "high" }
                    var type: String
                    var text: String?
                    var image_url: ImageURL?
                }
                var parts = [Part(type: "text", text: content, image_url: nil)]
                for image in images {
                    parts.append(.init(type: "text", text: image.label, image_url: nil))
                    parts.append(.init(type: "image_url", text: nil,
                        image_url: .init(url: "data:\(image.mimeType);base64," + image.data.base64EncodedString())))
                }
                try container.encode(parts, forKey: .content)
            }
        }
        let model: String
        let messages: [Message]
        let temperature: Double
        let max_tokens: Int
        let stream: Bool
        var stream_options: [String: Bool]? = nil
        var thinking: [String: String]? = nil
    }

    // MARK: - 流式对话

    public func stream(messages: [AIMessage]) -> AsyncThrowingStream<AIStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            guard let url = endpoint("/chat/completions") else {
                continuation.finish(throwing: AIError.invalidBaseURL(config.baseURL))
                return
            }
            if apiKey.isEmpty && !config.isLocalEndpoint {
                continuation.finish(throwing: AIError.missingAPIKey)
                return
            }
            let images = messages.flatMap(\.images)
            guard images.count <= 4, images.allSatisfy({ !$0.data.isEmpty && $0.data.count <= 2 * 1024 * 1024 && ["image/jpeg", "image/png"].contains($0.mimeType) }) else {
                continuation.finish(throwing: AIError.preparation("图表图片为空或超过单轮 4 张／每张 2 MiB 上限。"))
                return
            }

            let body = ChatRequest(
                model: config.selectedModel,
                messages: messages.map { ChatRequest.Message(role: $0.role.rawValue, content: $0.content, images: $0.images) },
                temperature: config.temperature,
                max_tokens: config.maxTokens,
                stream: true,
                stream_options: URL(string: config.baseURL)?.host == "api.openai.com" ? ["include_usage": true] : nil,
                thinking: config.deepSeekThinking
            )

            var request = authorizedRequest(url: url)
            request.httpMethod = "POST"
            guard let encoded = try? JSONEncoder().encode(body) else {
                continuation.finish(throwing: AIError.invalidResponse)
                return
            }
            request.httpBody = encoded

            let watch = AIStreamWatch()
            let task = Task.detached { [self, request] in
                defer { watch.close() }
                do {
                    try await AsyncRequestGate.cloud.acquire()
                    defer { Task { await AsyncRequestGate.cloud.release() } }
                    try Task.checkCancellation()
                    let (bytes, response) = try await session.bytes(for: request, delegate: SameOriginRedirectPolicy())
                    defer { bytes.task.cancel() }

                    guard let http = response as? HTTPURLResponse else {
                        throw AIError.invalidResponse
                    }

                    guard (200..<300).contains(http.statusCode) else {
                        throw AIError.http(status: http.statusCode, message: try await Self.drain(bytes))
                    }

                    var producedAnything = false
                    var terminal = false
                    var outputBytes = 0, reasoningBytes = 0

                    for try await line in BoundedResponseLines(bytes: bytes, maxLineBytes: 256_000, maxBytes: limits.maxWireBytes) {
                        if Task.isCancelled { throw AIError.cancelled }
                        guard line.hasPrefix("data:") else { continue }

                        let payload = line.dropFirst(5).trimmingCharacters(in: .whitespacesAndNewlines)
                        if payload.isEmpty { continue }
                        if payload == "[DONE]" { terminal = true; break }

                        guard let data = payload.data(using: .utf8),
                              let chunk = try? JSONDecoder().decode(ChatChunk.self, from: data) else { continue }
                        if chunk.error != nil { throw AIError.http(status: 200, message: payload) }
                        if let usage = chunk.usage {
                            continuation.yield(.usage(AIUsage(input: usage.prompt_tokens, output: usage.completion_tokens,
                                cached: usage.prompt_tokens_details?.cached_tokens ?? usage.prompt_cache_hit_tokens)))
                        }
                        guard let choice = chunk.choices?.first else { continue }

                        if let reasoning = choice.delta.reasoning_content, !reasoning.isEmpty {
                            reasoningBytes += reasoning.utf8.count
                            guard reasoningBytes <= limits.maxReasoningBytes else { throw AIError.responseTooLarge }
                            watch.activity()
                            continuation.yield(.reasoning(reasoning))
                        }
                        if let content = choice.delta.content, !content.isEmpty {
                            outputBytes += content.utf8.count
                            guard outputBytes <= limits.maxOutputBytes else { throw AIError.responseTooLarge }
                            watch.activity()
                            producedAnything = true
                            continuation.yield(.delta(content))
                        }
                        if let reason = choice.finish_reason, !reason.isEmpty {
                            if reason == "length" { throw AIError.outputTruncated }
                            if reason == "tool_calls" || reason == "function_call" || reason == "content_filter" { throw AIError.unsupportedOutput }
                            terminal = true
                            watch.finished()
                            continuation.yield(.finished(reason: reason))
                        }
                    }

                    guard terminal || !producedAnything else { throw AIError.incompleteResponse }

                    if !producedAnything {
                        continuation.yield(.finished(reason: "empty"))
                    }
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish(throwing: AIError.cancelled)
                } catch let error as AIError {
                    continuation.finish(throwing: error)
                } catch {
                    continuation.finish(throwing: Self.translateTransportError(error, config: config))
                }
            }
            // Heartbeats do not reset this clock; a finish frame gets a short
            // grace period for usage, not an unbounded wait for socket closure.
            let watchdog = Task {
                let interval = max(0.01, min(0.25, limits.idleTimeout / 5, limits.finishGrace / 5))
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(interval))
                    guard !Task.isCancelled else { return }
                    let outcome = watch.outcome(limits: limits)
                    if outcome.closed { return }
                    if outcome.complete || outcome.error != nil {
                        continuation.finish(throwing: outcome.error)
                        task.cancel()
                        return
                    }
                }
            }
            continuation.onTermination = { _ in task.cancel(); watchdog.cancel() }
        }
    }

    /// 出错时把 body 读出来，好让用户看到服务端到底说了什么。
    private static func drain(_ bytes: URLSession.AsyncBytes) async throws -> String {
        var text = ""
        for try await line in BoundedResponseLines(bytes: bytes, maxLineBytes: 16_000, maxBytes: 32_000) {
            text += line
            if text.count > 4000 { break }
        }
        return text
    }

    /// 把 URLSession 的传输层错误翻译成能定位问题的中文。
    ///
    /// 「连不上某某地址」这条如果只报地址，用户是定位不到的：他不知道应用当前
    /// 用的是哪个服务商。而读到这条提示的人，多半已经忘了自己在设置里选的是哪一项
    /// （尤其那些列表里躺着好几个服务商的用户）。所以这里把**服务商名**一并带上，
    /// 并对本机地址额外点一句——「127.0.0.1 连不上」最常见的成因就是
    /// 那个本地服务（Ollama / LM Studio / 自检桩服务）根本没启动。
    private static func translateTransportError(_ error: Error, config: AIProviderConfig) -> Error {
        let base = config.baseURL
        let nsError = error as NSError
        guard nsError.domain == NSURLErrorDomain else { return error }

        switch nsError.code {
        case NSURLErrorNotConnectedToInternet:
            return NSError(domain: "Lumen", code: nsError.code, userInfo: [
                NSLocalizedDescriptionKey: "网络不可用。请检查网络连接后重试。"
            ])
        case NSURLErrorCannotFindHost, NSURLErrorCannotConnectToHost:
            var message = "连不上 \(targetDescription(from: base))"
                + "（当前服务商：\(config.name)）。"
                + "请核对地址与端口是否写全，以及服务是否已启动。"
            if config.isLocalEndpoint {
                message += "\n\n这是一个本机地址。它需要本机有服务在监听——"
                    + "若是 Ollama / LM Studio，先把它启动；"
                    + "若你并不想用本机服务，到「设置 → AI」换一个服务商。"
            }
            return NSError(domain: "Lumen", code: nsError.code, userInfo: [
                NSLocalizedDescriptionKey: message
            ])
        case NSURLErrorTimedOut:
            return NSError(domain: "Lumen", code: nsError.code, userInfo: [
                NSLocalizedDescriptionKey: "请求超时。模型可能在思考很久，或网络太慢。可以换一个更快的模型。"
            ])
        case NSURLErrorSecureConnectionFailed, NSURLErrorServerCertificateUntrusted:
            return NSError(domain: "Lumen", code: nsError.code, userInfo: [
                NSLocalizedDescriptionKey: "TLS 握手失败。若在自建网关后面，请检查证书。"
            ])
        default:
            return error
        }
    }

    /// 把地址渲染成「host:port」。
    ///
    /// 只报 host 是不够的：同一个主机上端口写错是最常见的一类问题，
    /// 而端口恰恰是错误信息里最该出现的那一段。
    private static func targetDescription(from base: String) -> String {
        guard let url = URL(string: base), let host = url.host, !host.isEmpty else { return base }
        if let port = url.port { return "\(host):\(port)" }
        // 没写端口时把默认端口补上，省得用户以为是"没写所以不生效"
        if url.scheme?.lowercased() == "https" { return "\(host):443" }
        if url.scheme?.lowercased() == "http" { return "\(host):80" }
        return host
    }

    // MARK: - 模型列表

    private struct ModelList: Decodable {
        struct Entry: Decodable { let id: String }
        let data: [Entry]
    }

    public func availableModels() async throws -> [String] {
        guard let url = endpoint("/models") else {
            throw AIError.invalidBaseURL(config.baseURL)
        }
        var request = authorizedRequest(url: url)
        request.httpMethod = "GET"

        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = min(20, limits.idleTimeout)
        let (bytes, response) = try await session.bytes(for: request, delegate: SameOriginRedirectPolicy())
        defer { bytes.task.cancel() }
        guard let http = response as? HTTPURLResponse else { throw AIError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else {
            throw AIError.http(status: http.statusCode, message: try await Self.drain(bytes))
        }
        let data = try await BoundedResponseData.read(bytes, response: response, maximum: BoundedResponseData.modelListLimit)
        let list = try JSONDecoder().decode(ModelList.self, from: data)
        return list.data.map(\.id).sorted()
    }
}

// MARK: - SSE 分片

private struct ChatChunk: Decodable {
    struct ServiceError: Decodable { var message: String? }
    var error: ServiceError?

    struct Usage: Decodable {
        struct Details: Decodable { var cached_tokens: Int? }
        var prompt_tokens: Int?
        var completion_tokens: Int?
        var prompt_cache_hit_tokens: Int?
        var prompt_tokens_details: Details?
    }
    var usage: Usage?

    struct Choice: Decodable {
        struct Delta: Decodable {
            let content: String?
            /// DeepSeek-R1 / 部分推理模型把思维链放在这个字段
            let reasoning_content: String?
        }
        let delta: Delta
        let finish_reason: String?
    }

    let choices: [Choice]?
}
