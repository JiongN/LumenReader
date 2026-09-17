import Foundation

/// OpenAI 兼容协议的客户端。
///
/// 一套 `/chat/completions` + SSE 就能覆盖 DeepSeek、OpenAI、Kimi、智谱、通义、
/// 以及本地 Ollama / LM Studio。这也是 OakReader 的做法——它同样以
/// 「OpenAI-compatible API base」为主干，再对个别服务商做特例。
///
/// 刻意只依赖 URLSession：不引第三方 HTTP 库，构建离线可完成，也没有供应链风险。
public final class OpenAICompatibleProvider: AIProvider {

    public let displayName: String
    public let modelName: String

    private let config: AIProviderConfig
    private let apiKey: String
    private let session: URLSession

    public init(config: AIProviderConfig, apiKey: String) {
        self.config = config
        self.apiKey = apiKey
        self.displayName = config.name
        self.modelName = config.selectedModel

        let configuration = URLSessionConfiguration.ephemeral
        // 长回复 + 推理模型可能要想很久，给足时间但不要无限等
        configuration.timeoutIntervalForRequest = 180
        configuration.timeoutIntervalForResource = 900
        configuration.waitsForConnectivity = false
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        self.session = URLSession(configuration: configuration)
    }

    // MARK: - 端点拼装

    /// 宽容地拼出 `/chat/completions`。
    ///
    /// 用户填的 Base URL 五花八门：有的带 `/v1`，有的不带，有的末尾多个斜杠，
    /// 甚至有人直接把完整的 `/chat/completions` 粘进来。这里全部兜住。
    private func endpoint(_ suffix: String) -> URL? {
        var base = config.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !base.isEmpty else { return nil }

        while base.hasSuffix("/") { base.removeLast() }

        if base.hasSuffix("/chat/completions") {
            base = String(base.dropLast("/chat/completions".count))
        }
        if base.hasSuffix("/models") {
            base = String(base.dropLast("/models".count))
        }
        // 常见服务商的域名根路径，补上 /v1
        if let url = URL(string: base), let host = url.host, url.path.isEmpty || url.path == "/" {
            if host.contains("deepseek.com") || host.contains("openai.com") || host.contains("moonshot.cn") {
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
        }
        let model: String
        let messages: [Message]
        let temperature: Double
        let max_tokens: Int
        let stream: Bool
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

            let body = ChatRequest(
                model: config.selectedModel,
                messages: messages.map { ChatRequest.Message(role: $0.role.rawValue, content: $0.content) },
                temperature: config.temperature,
                max_tokens: config.maxTokens,
                stream: true
            )

            var request = authorizedRequest(url: url)
            request.httpMethod = "POST"
            guard let encoded = try? JSONEncoder().encode(body) else {
                continuation.finish(throwing: AIError.invalidResponse)
                return
            }
            request.httpBody = encoded

            let task = Task {
                do {
                    let (bytes, response) = try await session.bytes(for: request)

                    guard let http = response as? HTTPURLResponse else {
                        throw AIError.invalidResponse
                    }

                    guard (200..<300).contains(http.statusCode) else {
                        throw AIError.http(status: http.statusCode, message: try await Self.drain(bytes))
                    }

                    var producedAnything = false

                    for try await line in bytes.lines {
                        if Task.isCancelled { throw AIError.cancelled }
                        guard line.hasPrefix("data:") else { continue }

                        let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
                        if payload.isEmpty { continue }
                        if payload == "[DONE]" { break }

                        guard let data = payload.data(using: .utf8),
                              let chunk = try? JSONDecoder().decode(ChatChunk.self, from: data),
                              let choice = chunk.choices.first else { continue }

                        if let reasoning = choice.delta.reasoning_content, !reasoning.isEmpty {
                            continuation.yield(.reasoning(reasoning))
                        }
                        if let content = choice.delta.content, !content.isEmpty {
                            producedAnything = true
                            continuation.yield(.delta(content))
                        }
                        if let reason = choice.finish_reason, !reason.isEmpty {
                            continuation.yield(.finished(reason: reason))
                        }
                    }

                    if !producedAnything {
                        continuation.yield(.finished(reason: "empty"))
                    }
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish(throwing: AIError.cancelled)
                } catch let error as AIError {
                    continuation.finish(throwing: error)
                } catch {
                    continuation.finish(throwing: Self.translateTransportError(error, base: config.baseURL))
                }
            }

            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// 出错时把 body 读出来，好让用户看到服务端到底说了什么。
    private static func drain(_ bytes: URLSession.AsyncBytes) async throws -> String {
        var text = ""
        for try await line in bytes.lines {
            text += line
            if text.count > 4000 { break }
        }
        return text
    }

    /// 把 URLSession 的传输层错误翻译成能定位问题的中文。
    private static func translateTransportError(_ error: Error, base: String) -> Error {
        let nsError = error as NSError
        guard nsError.domain == NSURLErrorDomain else { return error }

        switch nsError.code {
        case NSURLErrorNotConnectedToInternet:
            return NSError(domain: "Lumen", code: nsError.code, userInfo: [
                NSLocalizedDescriptionKey: "网络不可用。请检查网络连接后重试。"
            ])
        case NSURLErrorCannotFindHost, NSURLErrorCannotConnectToHost:
            return NSError(domain: "Lumen", code: nsError.code, userInfo: [
                NSLocalizedDescriptionKey: "连不上 \(targetDescription(from: base))。请核对地址与端口是否写全，以及服务是否已启动。"
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

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw AIError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else {
            throw AIError.http(status: http.statusCode, message: String(data: data, encoding: .utf8) ?? "")
        }
        let list = try JSONDecoder().decode(ModelList.self, from: data)
        return list.data.map(\.id).sorted()
    }
}

// MARK: - SSE 分片

private struct ChatChunk: Decodable {

    struct Choice: Decodable {
        struct Delta: Decodable {
            let content: String?
            /// DeepSeek-R1 / 部分推理模型把思维链放在这个字段
            let reasoning_content: String?
        }
        let delta: Delta
        let finish_reason: String?
    }

    let choices: [Choice]
}
