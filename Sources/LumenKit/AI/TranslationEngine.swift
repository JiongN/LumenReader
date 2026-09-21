import Foundation

/// 一个翻译引擎的自述（设置界面与自检都读它）。
public struct TranslationEngineDescriptor: Sendable, Equatable, Identifiable {

    public let id: String
    public let displayName: String
    /// 是否需要联网。**必须如实写、并且界面上要显示** ——
    /// 用户断网时看到「点了没反应」会以为程序坏了，而这其实是设计的代价。
    public let requiresNetwork: Bool
    /// 一句话说明代价与限制，用于设置界面。
    public let note: String

    public init(id: String, displayName: String, requiresNetwork: Bool, note: String) {
        self.id = id
        self.displayName = displayName
        self.requiresNetwork = requiresNetwork
        self.note = note
    }
}

/// 翻译引擎。
///
/// 抽成协议的目的是**让用户能换**：不同引擎的取舍（免费但抓页面 / 离线但要下载语言包 /
/// 收费但稳）差别很大，写死一个等于替用户做了决定。
public protocol TranslationEngine: Sendable {
    var descriptor: TranslationEngineDescriptor { get }
    func translate(_ text: String, to target: String, from source: String) async throws -> String
}

/// Apple 系统翻译通道的目录描述。真正的 `TranslationSession` 只能由
/// SwiftUI `translationTask` 提供，所以 LumenKit 只保留 id 与说明，不引入 SwiftUI。
public enum AppleSystemTranslation {
    public static let engineID = "apple-system"

    public static let descriptor = TranslationEngineDescriptor(
        id: engineID,
        displayName: "Apple 系统翻译",
        requiresNetwork: false,
        note: "使用 macOS 官方翻译框架；语言包下载后可在本机处理。"
            + "首次使用某个语言对时，系统可能会请求下载语言包。"
    )
}

// MARK: - LLM 翻译与术语表

public struct TranslationGlossaryEntry: Codable, Sendable, Equatable, Identifiable {
    public var id: UUID
    public var source: String
    public var target: String

    public init(id: UUID = UUID(), source: String, target: String) {
        self.id = id
        self.source = source.trimmingCharacters(in: .whitespacesAndNewlines)
        self.target = target.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public var isUsable: Bool { !source.isEmpty && !target.isEmpty }
}

public enum LLMTranslation {
    public static let engineID = "llm-active"
    public static let descriptor = TranslationEngineDescriptor(
        id: engineID,
        displayName: "LLM 翻译",
        requiresNetwork: true,
        note: "使用当前 AI 服务商与模型；能遵守术语表并结合完整段落翻译，会消耗模型额度。"
    )
}

/// 使用用户当前配置的 OpenAI 兼容服务翻译。每次请求只返回译文，避免解释文字混入正文。
public struct LLMTranslationEngine: TranslationEngine {
    public let descriptor = LLMTranslation.descriptor
    private let config: AIProviderConfig
    private let apiKey: String
    private let glossary: [TranslationGlossaryEntry]

    public init(config: AIProviderConfig, apiKey: String,
                glossary: [TranslationGlossaryEntry]) {
        var tuned = config
        tuned.temperature = 0.1
        tuned.maxTokens = max(2048, config.maxTokens)
        self.config = tuned
        self.apiKey = apiKey
        self.glossary = glossary.filter(\.isUsable)
    }

    public func translate(_ text: String, to target: String, from source: String) async throws -> String {
        let targetName = TranslationLanguage.target(for: target).displayName
        let terms = glossary.isEmpty ? "（无）" : glossary
            .map { "- \($0.source) → \($0.target)" }
            .joined(separator: "\n")
        let provider = OpenAICompatibleProvider(config: config, apiKey: apiKey)
        let output = try await provider.completeText(messages: [
            .system("你是严谨的专业翻译。只输出译文，不解释、不概括、不添加标题。保持原段落语义、指代、标点和论证关系。必须遵守术语表。"),
            .user("目标语言：\(targetName)\n术语表：\n\(terms)\n\n待翻译段落：\n\(text)")
        ])
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw AIError.emptyResponse }
        return trimmed
    }
}

// MARK: - 微软（必应免密钥通道）

/// 微软翻译。走必应网页版那个免注册接口，不需要密钥，也不需要下载语言包。
public struct MicrosoftTranslationEngine: TranslationEngine {

    public static let engineID = "microsoft-bing"

    public let descriptor = TranslationEngineDescriptor(
        id: MicrosoftTranslationEngine.engineID,
        displayName: "微软翻译",
        requiresNetwork: true,
        note: "免费、无需密钥，也不需要下载语言包。"
            + "代价：必须联网；凭证是从必应翻译页的运行时参数里取出来的，页面改版时可能失效（届时会明确报错，不会静默返回空译文）。"
    )

    private let translator: MicrosoftTranslator

    public init(translator: MicrosoftTranslator = .shared) {
        self.translator = translator
    }

    public func translate(_ text: String, to target: String, from source: String) async throws -> String {
        try await translator.translate(text, to: target, from: source)
    }
}

// MARK: - 引擎目录

/// 可选引擎的目录，以及「用户存的 id → 一个一定可用的引擎」的解析。
public enum TranslationEngineCatalog {

    /// 全部可选引擎，顺序即设置界面里的顺序。
    public static let all: [TranslationEngineDescriptor] = [
        AppleSystemTranslation.descriptor,
        MicrosoftTranslationEngine().descriptor,
        LLMTranslation.descriptor
    ]

    public static var defaultID: String { AppleSystemTranslation.engineID }

    /// 解析引擎描述符。
    ///
    /// **认不出来就退回默认，而不是报错。** `settings.json` 是纯文本：用户手改过、
    /// 或者旧版本写过某个已经下线的引擎名，都可能让它变成一个不存在的 id。
    /// 这时报错的后果是用户看到「翻译坏了」，而真实原因是配置里有个陌生字符串 ——
    /// 静默退回默认更有用，代价只是用户发现自己选的引擎变了（设置界面会显示当前值）。
    public static func descriptor(for id: String?) -> TranslationEngineDescriptor {
        guard let id, !id.isEmpty else { return all[0] }
        return all.first { $0.id == id } ?? all[0]
    }

    /// 取可直接在 LumenKit 调用的引擎。Apple 通道需要 SwiftUI 会话，因此返回 nil。
    public static func engine(for id: String?) -> (any TranslationEngine)? {
        switch descriptor(for: id).id {
        case MicrosoftTranslationEngine.engineID:
            return MicrosoftTranslationEngine()
        default:
            return nil
        }
    }
}

// MARK: - 目标语言

/// 逐段翻译的目标语言。
///
/// 用必应的语言标签（`zh-Hans` / `en` / `ja` …）而不是自造枚举：
/// 标签直接进请求，中间少一层映射就少一处能写错的地方。
public enum TranslationLanguage {

    public struct Option: Sendable, Equatable, Identifiable {
        public let id: String
        public let displayName: String
    }

    public static let targets: [Option] = [
        Option(id: "zh-Hans", displayName: "简体中文"),
        Option(id: "zh-Hant", displayName: "繁體中文"),
        Option(id: "en", displayName: "英语"),
        Option(id: "ja", displayName: "日语"),
        Option(id: "ko", displayName: "韩语")
    ]

    public static var defaultID: String { "zh-Hans" }

    /// 与 `descriptor(for:)` 同一套思路：认不出来 / 空串一律退回默认。
    /// 空串不能放过去 —— 它会让翻译请求白跑一趟再失败。
    public static func target(for id: String?) -> Option {
        guard let id, !id.isEmpty else { return targets[0] }
        return targets.first { $0.id == id } ?? targets[0]
    }
}
