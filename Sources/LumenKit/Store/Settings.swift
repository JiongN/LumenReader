import Foundation

// MARK: - 阅读主题

public enum ReadingThemeID: String, Codable, CaseIterable, Sendable, Identifiable {
    case paper      // 纸白
    case warm       // 暖黄（护眼）
    case sage       // 灰绿
    case dusk       // 暮蓝
    case midnight   // 深夜
    case oled       // 纯黑（OLED 省电）

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .paper:    return "纸白"
        case .warm:     return "暖黄"
        case .sage:     return "灰绿"
        case .dusk:     return "暮蓝"
        case .midnight: return "深夜"
        case .oled:     return "纯黑"
        }
    }

    /// 是否属于深色系（决定窗口外观、控件对比度基调）
    public var isDark: Bool {
        switch self {
        case .paper, .warm, .sage: return false
        case .dusk, .midnight, .oled: return true
        }
    }
}

// MARK: - 排版

public enum ReadingFontFamily: String, Codable, CaseIterable, Sendable, Identifiable {
    case system     // 系统默认（SF Pro / 苹方）
    case serif      // 宋体 / 新宋
    case rounded    // SF Rounded
    case mono       // 等宽

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .system:  return "系统"
        case .serif:   return "宋体"
        case .rounded: return "圆体"
        case .mono:    return "等宽"
        }
    }
}

public enum ReadingFlowMode: String, Codable, CaseIterable, Sendable, Identifiable {
    case continuous   // 连续滚动
    case paged        // 分页

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .continuous: return "连续滚动"
        case .paged:      return "分页"
        }
    }
}

/// 正文对齐方式。
///
/// 默认两端对齐——中文排版的标准做法。但两端对齐会拉开西文单词间距，
/// 中英混排且有大量长单词时（比如文献综述里的英文作者名），左对齐反而更好读。
public enum ReadingTextAlign: String, Codable, CaseIterable, Sendable, Identifiable {
    case justify   // 两端对齐
    case leading   // 左对齐（西文场景更自然）

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .justify: return "两端对齐"
        case .leading: return "左对齐"
        }
    }

    /// 注入 CSS 的值
    public var cssValue: String {
        switch self {
        case .justify: return "justify"
        case .leading: return "left"
        }
    }
}

// MARK: - 阅读设置

public struct ReaderSettings: Codable, Sendable, Equatable {
    public var themeID: ReadingThemeID = .paper
    /// 字体分组。它决定"没显式挑字体时用哪一类"，同时也是选具体字体时的默认落点。
    public var fontFamily: ReadingFontFamily = .system
    /// 正文具体字体族名（如 `Songti SC`）。nil 表示用 `fontFamily` 分组的预设栈。
    ///
    /// 为什么是"分组 + 具体字体名"两层而不是把 `fontFamily` 直接换成字符串：
    /// 旧版本存的是 `"serif"` 这类分组名，直接改类型会让老用户的设置静默失效。
    /// 两层结构下老数据照常解出分组，新数据多一个可选的具体字体，互不干扰。
    public var readingFontFamilyName: String?
    /// 字号倍率，1.0 = 基准 17pt
    public var fontScale: Double = 1.0
    /// 行高倍数
    public var lineHeight: Double = 1.7
    /// 字距（em）。中文排版 0 或极小正值观感最好，调大主要给西文用。
    public var letterSpacing: Double = 0
    /// 正文对齐方式
    public var textAlign: ReadingTextAlign = .justify
    /// 正文最大宽度（pt），保证长行可读性
    public var contentWidth: Double = 720
    /// 段落间距倍数
    public var paragraphSpacing: Double = 0.6
    /// PDF / EPUB 通用阅读流模式
    public var flowMode: ReadingFlowMode = .continuous
    /// 是否显示缩略图侧栏（PDF）
    public var showThumbnails: Bool = false
    /// PDF 画布亮度。1.0 = 原始；调低可减轻深色环境下白页的刺眼感。
    /// PDF 是固定版式，无法真正反色（会让彩色插图变成负片），所以这里只调画布。
    public var pdfCanvasBrightness: Double = 1.0
    /// EPUB 滚动到章末时自动进入下一章
    public var autoAdvanceOnScrollEnd: Bool = true

    public init() {}

    /// 容错解码：任何字段缺失都退回默认值。
    ///
    /// 这条不能省——应用升级后新增字段是常态，如果旧的 settings.json 因为缺一个键
    /// 就整份解码失败，用户所有偏好会被静默重置，而且不会有任何提示。
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.themeID = (try? container.decode(ReadingThemeID.self, forKey: .themeID)) ?? .paper
        self.fontFamily = (try? container.decode(ReadingFontFamily.self, forKey: .fontFamily)) ?? .system
        // 没有显式挑字体是合法状态，所以这里允许解出 nil
        self.readingFontFamilyName = try? container.decode(String.self, forKey: .readingFontFamilyName)
        self.fontScale = (try? container.decode(Double.self, forKey: .fontScale)) ?? 1.0
        self.lineHeight = (try? container.decode(Double.self, forKey: .lineHeight)) ?? 1.7
        self.letterSpacing = (try? container.decode(Double.self, forKey: .letterSpacing)) ?? 0
        self.textAlign = (try? container.decode(ReadingTextAlign.self, forKey: .textAlign)) ?? .justify
        self.contentWidth = (try? container.decode(Double.self, forKey: .contentWidth)) ?? 720
        self.paragraphSpacing = (try? container.decode(Double.self, forKey: .paragraphSpacing)) ?? 0.6
        self.flowMode = (try? container.decode(ReadingFlowMode.self, forKey: .flowMode)) ?? .continuous
        self.showThumbnails = (try? container.decode(Bool.self, forKey: .showThumbnails)) ?? false
        self.pdfCanvasBrightness = (try? container.decode(Double.self, forKey: .pdfCanvasBrightness)) ?? 1.0
        self.autoAdvanceOnScrollEnd = (try? container.decode(Bool.self, forKey: .autoAdvanceOnScrollEnd)) ?? true
    }
}

// MARK: - AI

public struct AIProviderConfig: Codable, Sendable, Equatable, Identifiable {
    public var id: UUID
    public var name: String
    /// OpenAI 兼容的 API 基址，例如 https://api.deepseek.com/v1
    public var baseURL: String
    /// 可用模型列表
    public var models: [String]
    public var selectedModel: String
    public var temperature: Double
    public var maxTokens: Int
    /// 是否启用「扩展思考」（模型支持时透传 reasoning 相关参数）
    public var extendedThinking: Bool

    public init(
        id: UUID = UUID(),
        name: String,
        baseURL: String,
        models: [String],
        selectedModel: String,
        temperature: Double = 0.7,
        maxTokens: Int = 2048,
        extendedThinking: Bool = false
    ) {
        self.id = id
        self.name = name
        self.baseURL = baseURL
        self.models = models
        self.selectedModel = selectedModel
        self.temperature = temperature
        self.maxTokens = maxTokens
        self.extendedThinking = extendedThinking
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = (try? container.decode(UUID.self, forKey: .id)) ?? UUID()
        self.name = (try? container.decode(String.self, forKey: .name)) ?? "未命名服务商"
        self.baseURL = (try? container.decode(String.self, forKey: .baseURL)) ?? ""
        self.models = (try? container.decode([String].self, forKey: .models)) ?? []
        self.selectedModel = (try? container.decode(String.self, forKey: .selectedModel)) ?? ""
        self.temperature = (try? container.decode(Double.self, forKey: .temperature)) ?? 0.7
        self.maxTokens = (try? container.decode(Int.self, forKey: .maxTokens)) ?? 2048
        self.extendedThinking = (try? container.decode(Bool.self, forKey: .extendedThinking)) ?? false
    }

    /// Keychain 里的账号名。
    public var keychainAccount: String { id.uuidString }

    /// 本地端点（Ollama / LM Studio / vLLM）通常不校验密钥，允许留空。
    public var isLocalEndpoint: Bool {
        guard let host = URL(string: baseURL)?.host?.lowercased() else { return false }
        return host == "localhost" || host == "127.0.0.1" || host == "::1" || host.hasSuffix(".local")
    }

    /// 常见服务商预设，降低配置成本。
    public static var presets: [AIProviderConfig] {
        [
            AIProviderConfig(
                name: "DeepSeek",
                baseURL: "https://api.deepseek.com/v1",
                models: ["deepseek-chat", "deepseek-reasoner"],
                selectedModel: "deepseek-chat"
            ),
            AIProviderConfig(
                name: "OpenAI",
                baseURL: "https://api.openai.com/v1",
                models: ["gpt-4o", "gpt-4o-mini", "gpt-4.1"],
                selectedModel: "gpt-4o-mini"
            ),
            AIProviderConfig(
                name: "Kimi（月之暗面）",
                baseURL: "https://api.moonshot.cn/v1",
                models: ["moonshot-v1-8k", "moonshot-v1-32k", "moonshot-v1-128k"],
                selectedModel: "moonshot-v1-32k"
            ),
            AIProviderConfig(
                name: "智谱 GLM",
                baseURL: "https://open.bigmodel.cn/api/paas/v4",
                models: ["glm-4-plus", "glm-4-flash"],
                selectedModel: "glm-4-plus"
            ),
            AIProviderConfig(
                name: "通义千问",
                baseURL: "https://dashscope.aliyuncs.com/compatible-mode/v1",
                models: ["qwen-plus", "qwen-max", "qwen-turbo"],
                selectedModel: "qwen-plus"
            ),
            AIProviderConfig(
                name: "本地（Ollama / LM Studio）",
                baseURL: "http://localhost:11434/v1",
                models: ["qwen2.5:7b", "llama3.1:8b"],
                selectedModel: "qwen2.5:7b"
            )
        ]
    }
}

public struct AISettings: Codable, Sendable, Equatable {
    public var providers: [AIProviderConfig] = []
    public var activeProviderID: UUID?
    /// 持久记忆：跨会话提供给模型的稳定偏好。
    /// 对应 OakReader 的「已保存的记忆」——让模型不必每次重新了解你是谁、在读什么。
    public var persistentMemory: String = ""
    /// 流式输出开关
    public var streaming: Bool = true
    /// 翻译目标语言
    public var translateTarget: String = "简体中文"

    public init() {}

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.providers = (try? container.decode([AIProviderConfig].self, forKey: .providers)) ?? []
        // 没有激活的服务商是合法状态（用户可能全删了），所以这里允许解出 nil
        self.activeProviderID = try? container.decode(UUID.self, forKey: .activeProviderID)
        self.persistentMemory = (try? container.decode(String.self, forKey: .persistentMemory)) ?? ""
        self.streaming = (try? container.decode(Bool.self, forKey: .streaming)) ?? true
        self.translateTarget = (try? container.decode(String.self, forKey: .translateTarget)) ?? "简体中文"
    }
}

// MARK: - 界面

/// 动效速度档。
///
/// 为什么是「档位」而不是一根滑杆：动效时长不适合无级调节——0.9× 和 1.05× 的差别没人感觉得到，
/// 只会让设置项显得难以理解。三档的语义分别是"别耽误我"、"正常"、"慢一点看得清"。
public enum MotionSpeed: String, Codable, CaseIterable, Sendable, Identifiable {
    case compact    // 0.7×
    case standard   // 1.0×
    case relaxed    // 1.4×

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .compact:  return "紧凑"
        case .standard: return "标准"
        case .relaxed:  return "舒缓"
        }
    }

    /// 时长倍率。注意是乘在时长上：倍率越大越慢。
    public var timeScale: Double {
        switch self {
        case .compact:  return 0.7
        case .standard: return 1.0
        case .relaxed:  return 1.4
        }
    }
}

public struct UISettings: Codable, Sendable, Equatable {
    /// 关闭后所有动效时长归零
    public var animationsEnabled: Bool = true
    public var motionSpeed: MotionSpeed = .standard
    /// 是否尊重系统「减弱动态效果」。默认尊重——这是 HIG 要求。
    public var respectsSystemReduceMotion: Bool = true
    /// 界面字体族名。nil = 系统默认（SF Pro / 苹方）。
    ///
    /// 只管外壳：侧栏、AI 面板、设置页、菜单。**阅读正文的字体在 `ReaderSettings` 里**，
    /// 两者分设是因为需求正好相反——界面字体重在"看着顺眼、信息密度高"，
    /// 正文字体重在"长时间阅读不累"，同一个人对这两件事的偏好经常不一样。
    public var uiFontFamilyName: String?

    /// 侧栏宽度（pt）。拖动分隔线调节，双击复位。
    ///
    /// 存进配置而不是只放内存：面板宽度属于「调一次就长期沿用」的偏好，
    /// 每次开新文档都弹回默认值会逼用户反复调同一个东西。
    public var sidebarWidth: Double = PanelWidth.sidebarDefault
    /// AI 面板宽度（pt）。同上。
    public var aiPanelWidth: Double = PanelWidth.aiDefault

    /// 面板宽度的允许范围。
    ///
    /// 上下限不是装饰：太窄会把行内的图标和文字裁掉（而且 SwiftUI 不会报错，
    /// 只是安静地切掉），太宽则阅读区被挤到不可用。手改 settings.json 塞个 5000
    /// 进来就能把界面搞成一片空白，所以解码时必须钳制。
    public enum PanelWidth {
        public static let sidebarDefault: Double = 248
        public static let aiDefault: Double = 380
        public static let sidebarRange: ClosedRange<Double> = 180...420
        public static let aiRange: ClosedRange<Double> = 280...640

        public static func clampSidebar(_ value: Double) -> Double {
            guard value.isFinite else { return sidebarDefault }
            return min(max(value, sidebarRange.lowerBound), sidebarRange.upperBound)
        }

        public static func clampAI(_ value: Double) -> Double {
            guard value.isFinite else { return aiDefault }
            return min(max(value, aiRange.lowerBound), aiRange.upperBound)
        }
    }

    public init() {}

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.animationsEnabled = (try? container.decode(Bool.self, forKey: .animationsEnabled)) ?? true
        self.motionSpeed = (try? container.decode(MotionSpeed.self, forKey: .motionSpeed)) ?? .standard
        self.respectsSystemReduceMotion =
            (try? container.decode(Bool.self, forKey: .respectsSystemReduceMotion)) ?? true
        self.uiFontFamilyName = try? container.decode(String.self, forKey: .uiFontFamilyName)
        self.sidebarWidth = PanelWidth.clampSidebar(
            (try? container.decode(Double.self, forKey: .sidebarWidth)) ?? PanelWidth.sidebarDefault
        )
        self.aiPanelWidth = PanelWidth.clampAI(
            (try? container.decode(Double.self, forKey: .aiPanelWidth)) ?? PanelWidth.aiDefault
        )
    }
}

// MARK: - 全局设置

public struct AppSettings: Codable, Sendable, Equatable {
    public var reader = ReaderSettings()
    public var ai = AISettings()
    public var ui = UISettings()
    /// 首次启动是否已展示引导
    public var hasCompletedOnboarding: Bool = false

    public init() {}

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.reader = (try? container.decode(ReaderSettings.self, forKey: .reader)) ?? ReaderSettings()
        self.ai = (try? container.decode(AISettings.self, forKey: .ai)) ?? AISettings()
        self.ui = (try? container.decode(UISettings.self, forKey: .ui)) ?? UISettings()
        self.hasCompletedOnboarding = (try? container.decode(Bool.self, forKey: .hasCompletedOnboarding)) ?? false
    }
}
