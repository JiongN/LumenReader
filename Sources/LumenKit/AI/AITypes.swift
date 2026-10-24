import Foundation

public struct AIImage: Sendable, Equatable {
    public var data: Data
    public var mimeType: String
    public var label: String
    public init(data: Data, mimeType: String = "image/jpeg", label: String) {
        self.data = data; self.mimeType = mimeType; self.label = label
    }
}

// MARK: - 消息

public struct AIMessage: Sendable, Equatable {

    public enum Role: String, Sendable {
        case system
        case user
        case assistant
    }

    public let role: Role
    public let content: String
    public let images: [AIImage]

    public init(role: Role, content: String, images: [AIImage] = []) {
        self.role = role
        self.content = content
        self.images = images
    }

    public static func system(_ content: String) -> AIMessage { AIMessage(role: .system, content: content) }
    public static func user(_ content: String) -> AIMessage { AIMessage(role: .user, content: content) }
    public static func assistant(_ content: String) -> AIMessage { AIMessage(role: .assistant, content: content) }
}

// MARK: - 流式事件

public enum AIStreamEvent: Sendable, Equatable {
    /// 正文增量
    case delta(String)
    /// 推理过程增量（DeepSeek-R1 等模型会单独给 reasoning_content）
    case reasoning(String)
    /// 流结束
    case finished(reason: String?)
    case usage(AIUsage)
}

public struct AIUsage: Codable, Sendable, Equatable {
    public var input: Int?
    public var output: Int?
    public var cached: Int?

    public init(input: Int? = nil, output: Int? = nil, cached: Int? = nil) {
        self.input = input; self.output = output; self.cached = cached
    }
}

// MARK: - 错误

public enum AIError: LocalizedError, Equatable {
    case missingAPIKey
    case invalidBaseURL(String)
    case invalidResponse
    case emptyResponse
    case http(status: Int, message: String)
    case preparation(String)
    case answerValidation(String)
    case cancelled
    case streamTimeout(String)
    case responseTooLarge
    case incompleteResponse
    case outputTruncated
    case unsupportedOutput

    public var errorDescription: String? {
        switch self {
        case .missingAPIKey:
            return "尚未配置 API 密钥。请在「设置 → AI」里填入。"
        case .invalidBaseURL:
            return "API 基址不合法。请使用不含用户名、密码、查询参数或片段的 HTTP(S) 地址。"
        case .invalidResponse:
            return "服务端返回了无法解析的响应。"
        case .emptyResponse:
            return "模型没有返回任何内容。"
        case .cancelled:
            return "已取消。"
        case .streamTimeout(let stage):
            return "\(stage)，已停止等待。可重试或换模型；部分回答不进入后续对话。"
        case .responseTooLarge:
            return "模型输出超过安全上限，已停止。请缩小范围或要求更简洁的结果。"
        case .incompleteResponse:
            return "连接在回答完成前关闭。部分回答已保留，但不会用于后续对话。"
        case .outputTruncated:
            return "服务端因长度上限截断了输出（finish_reason=length）。请提高最大输出或缩小回答范围；推理模型的思考也可能占用输出预算。"
        case .unsupportedOutput:
            return "当前接口未接入绘图或工具调用。思维导图请使用专用模式；图片生成暂不支持。"
        case .http(let status, let message):
            return Self.describe(status: status, message: message)
        case .preparation(let message):
            return "全文准备未完成：\(message)"
        case .answerValidation(let message):
            return message
        }
    }

    /// 把 HTTP 状态码翻译成能指导下一步动作的提示，而不是甩一个「请求失败」。
    private static func describe(status: Int, message: String) -> String {
        let detail = Self.extractMessage(from: message)
        let suffix = detail.isEmpty ? "" : "\n\n服务端说明：\(detail)"

        switch status {
        case 401, 403:
            return "密钥被拒绝（HTTP \(status)）。请检查 API Key 是否正确、是否已过期。\(suffix)"
        case 402:
            return "账户余额不足（HTTP 402）。请到服务商控制台充值。\(suffix)"
        case 404:
            return "接口不存在（HTTP 404）。通常是 Base URL 少了或多了 `/v1`，或模型名写错了。\(suffix)"
        case 429:
            return "触发限流（HTTP 429）。稍等片刻再试，或换一个模型。\(suffix)"
        case 500...599:
            return "服务端错误（HTTP \(status)）。这通常是对方的问题，稍后重试。\(suffix)"
        default:
            return "请求失败（HTTP \(status)）。\(suffix)"
        }
    }

    /// 从各家格式不一的错误体里把人类可读的那句话抠出来。
    private static func extractMessage(from body: String) -> String {
        guard let data = body.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return String(body.prefix(300))
        }
        if let error = json["error"] as? [String: Any] {
            if let message = error["message"] as? String { return message }
            if let message = error["msg"] as? String { return message }
        }
        if let message = json["message"] as? String { return message }
        if let message = json["error"] as? String { return message }
        return String(body.prefix(300))
    }
}

// MARK: - Provider 协议

/// 是否已具备发起请求的条件。
///
/// 本地端点（Ollama / LM Studio / vLLM）通常不校验密钥，所以只要求有模型名；
/// 云端服务商则必须有密钥。把这个判断收敛到一处，UI 与请求层就不会各判一套。
public extension AIProviderConfig {
    var isConfigured: Bool {
        guard !selectedModel.trimmingCharacters(in: .whitespaces).isEmpty,
              !baseURL.trimmingCharacters(in: .whitespaces).isEmpty else { return false }
        return isLocalEndpoint || AICredentialStore.hasKey(account: keychainAccount)
    }
}

/// 只依赖这一个协议，未来接 Anthropic / 本地推理都不会波及 UI 与业务层。
public protocol AIProvider: AnyObject {
    var displayName: String { get }
    var modelName: String { get }

    /// 流式对话。返回的流结束即代表这次请求结束。
    func stream(messages: [AIMessage]) -> AsyncThrowingStream<AIStreamEvent, Error>

    /// 拉取模型列表（GET /models）。用于设置页的「从服务端获取」。
    func availableModels() async throws -> [String]
}

public extension AIProvider {

    /// 把流式结果收成一个完整字符串。
    ///
    /// 适合「调用方只关心最终结果」的场景（智能目录、结构化抽取）：
    /// 那些地方不需要打字机效果，逐段拼装反而要额外维护一份缓冲区。
    ///
    /// 推理过程（`reasoning`）**不计入返回正文**——思维链是模型的草稿，
    /// 混进结果里会污染 JSON 解析。
    func completeText(messages: [AIMessage]) async throws -> String {
        var result = ""
        for try await event in stream(messages: messages) {
            switch event {
            case .delta(let text):
                result += text
            case .reasoning:
                continue
            case .finished:
                continue
            case .usage:
                continue
            }
        }
        return result
    }
}
