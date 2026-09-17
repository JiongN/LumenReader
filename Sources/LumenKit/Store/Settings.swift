import Foundation

// MARK: - 阅读主题

public enum ReadingThemeID: String, Codable, CaseIterable, Sendable, Identifiable {
    case paper      // 纸白
    case warm       // 暖黄（护眼）
    case sage       // 灰绿
    case dusk       // 暮蓝
    case midnight   // 深夜
    /// 已废弃：纯黑（OLED）。
    ///
    /// 保留这个 case **只为让旧配置能解码**。直接删掉的话，`themeID: "oled"` 会解码失败，
    /// 容错解码把它兜成 `.paper` —— 一个深色用户下次打开会发现自己被换成了纸白，
    /// 这是最糟的降级方向。迁移在下面 `migrated` 里做：解到它就落到 `.midnight`
    /// （六个主题里与纯黑观感最接近的那个）。
    /// 它已经不在 `ReadingTheme.all` 里，所以界面上选不到。
    case oled

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .paper:    return "纸白"
        case .warm:     return "暖黄"
        case .sage:     return "灰绿"
        case .dusk:     return "暮蓝"
        case .midnight: return "深夜"
        case .oled:     return "深夜"
        }
    }

    /// 是否属于深色系（决定窗口外观、控件对比度基调）
    public var isDark: Bool {
        switch self {
        case .paper, .warm, .sage: return false
        case .dusk, .midnight, .oled: return true
        }
    }

    /// 废弃主题的落点。
    ///
    /// 做成属性而不是散在各处判断：`ReadingTheme.theme(for:)` 与设置解码都要用它，
    /// 分头写同样一条 `== .oled ? .midnight : self` 迟早会漏掉一处，
    /// 而漏掉的那一处表现是「某些入口选下去变纸白」——最难查的一类不一致。
    public var migrated: ReadingThemeID {
        switch self {
        case .oled:  return .midnight
        default:     return self
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
        // `.migrated` 负责把已废弃的纯黑主题落到深夜，见 `ReadingThemeID.migrated`
        self.themeID = ((try? container.decode(ReadingThemeID.self, forKey: .themeID)) ?? .paper).migrated
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

/// 可切换的提示词模板。
///
/// 为什么做成「模板」而不是给用户一个空白的 system prompt 输入框：
/// 能改系统提示的用户是少数，多数人只是想要「换个角度读」——
/// 「通俗解释一遍」「帮我挑论证漏洞」。模板把这两类需求都接住了：
/// 内置模板开箱可用，自定义模板留给愿意自己写的人。
///
/// `systemPrompt` 与 `instruction` 分开，是因为它们进模型的位置不同：
/// 前者替换系统提示（决定模型的身份与总原则），后者追加在用户消息末尾
/// （决定这一次要什么）。合成一个字段的话，「只想改要求、不想动系统提示」
/// 就做不到。
public struct PromptTemplate: Codable, Sendable, Equatable, Identifiable {

    public var id: UUID
    public var name: String
    /// 替换默认系统提示。空串表示沿用 `PromptLibrary.systemPrompt`。
    public var systemPrompt: String
    /// 追加在用户消息末尾的「要求」段。空串表示用该任务自带的默认要求。
    public var instruction: String
    /// 内置模板不可删除（可以改，`resetTemplates` 能还原）。
    public var isBuiltIn: Bool

    public init(
        id: UUID = UUID(),
        name: String,
        systemPrompt: String = "",
        instruction: String = "",
        isBuiltIn: Bool = false
    ) {
        self.id = id
        self.name = name
        self.systemPrompt = systemPrompt
        self.instruction = instruction
        self.isBuiltIn = isBuiltIn
    }

    /// 容错解码。理由同其余设置结构：旧配置缺字段不能让整份设置解码失败。
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = (try? container.decode(UUID.self, forKey: .id)) ?? UUID()
        self.name = (try? container.decode(String.self, forKey: .name)) ?? "未命名模板"
        self.systemPrompt = (try? container.decode(String.self, forKey: .systemPrompt)) ?? ""
        self.instruction = (try? container.decode(String.self, forKey: .instruction)) ?? ""
        self.isBuiltIn = (try? container.decode(Bool.self, forKey: .isBuiltIn)) ?? false
    }

    /// 内置模板。
    ///
    /// 每个都针对一类真实的读法，而不是「简洁 / 详细」这种没法定夺的形容词：
    /// 读者要能一眼判断「这个模板是不是我要的那种读法」。
    ///
    /// **id 是写死的，不是 `UUID()`。** 这很重要：`presets` 是个计算属性，
    /// 每次取都会新建一批对象，若 id 随机，那么「配置里没有 templates 时用预设」
    /// 这条路径每次启动都会得到一组全新的 id——用户上一轮选中的模板在下一轮就找不到了。
    /// 写死之后，内置模板的身份是稳定的，也能被测试与自检直接引用。
    public static var presets: [PromptTemplate] {
        [
            PromptTemplate(
                id: UUID(uuidString: "1B0E7A10-0001-4000-8000-4C554D454E01")!,
                name: "严谨学术解读",
                instruction: "请严格依据原文作答，凡属你的推断都要显式标注「推断」。",
                isBuiltIn: true
            ),
            PromptTemplate(
                id: UUID(uuidString: "1B0E7A10-0002-4000-8000-4C554D454E02")!,
                name: "通俗解释",
                instruction: """
                请用日常语言解释，假设读者没有该领域的背景。\
                专业术语第一次出现时必须用一句大白话说明。不要为了通俗而牺牲准确性。
                """,
                isBuiltIn: true
            ),
            PromptTemplate(
                id: UUID(uuidString: "1B0E7A10-0003-4000-8000-4C554D454E03")!,
                name: "批判性审读",
                instruction: """
                请以审稿人视角检视这段内容：它依赖了哪些未言明的前提？\
                论证在哪一步跳了？有没有反例或竞争性解释？\
                先指出最值得质疑的一点，再列其余问题。
                """,
                isBuiltIn: true
            ),
            PromptTemplate(
                id: UUID(uuidString: "1B0E7A10-0004-4000-8000-4C554D454E04")!,
                name: "概念与术语抽取",
                instruction: """
                请抽取这段内容里的核心概念与术语。每个概念给出：原文用词、\
                作者在此处的界定（若原文未界定就写明「原文未界定」，不要自己补）、\
                以及它与其他概念的关系。
                """,
                isBuiltIn: true
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

    /// 可选的提示词模板。首次启动填入内置预设。
    public var templates: [PromptTemplate] = PromptTemplate.presets
    /// 当前选中的模板。`nil` = 不套模板，走 `PromptLibrary` 的默认行为。
    ///
    /// 用 nil 而不是「默认选中第一个预设」：默认行为经过调校（系统提示里逐条堵住了
    /// 幻觉、客套话、过度概括），套上任何模板都是在它之上做加法。
    /// 让「不加东西」成为默认，用户的现状就不会被这次改动悄悄改变。
    public var activeTemplateID: UUID?

    /// 可选的 Agent（角色 + 技能 + 是否联网检索）。首次启动填入内置预设。
    public var agents: [AgentConfig] = AgentConfig.presets
    /// 当前选中的 Agent。`nil` = 不加角色，走默认助手行为。
    public var activeAgentID: String?

    public init() {}

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.providers = (try? container.decode([AIProviderConfig].self, forKey: .providers)) ?? []
        // 没有激活的服务商是合法状态（用户可能全删了），所以这里允许解出 nil
        self.activeProviderID = try? container.decode(UUID.self, forKey: .activeProviderID)
        self.persistentMemory = (try? container.decode(String.self, forKey: .persistentMemory)) ?? ""
        self.streaming = (try? container.decode(Bool.self, forKey: .streaming)) ?? true
        self.translateTarget = (try? container.decode(String.self, forKey: .translateTarget)) ?? "简体中文"
        // 旧配置里没有这些键。templates/agents 缺失时补上预设（否则老用户看不到任何模板或角色，
        // 会以为功能坏了），两个 active* 缺失时保持 nil（即默认行为）。
        self.templates = (try? container.decode([PromptTemplate].self, forKey: .templates))
            ?? PromptTemplate.presets
        self.activeTemplateID = try? container.decode(UUID.self, forKey: .activeTemplateID)
        self.agents = (try? container.decode([AgentConfig].self, forKey: .agents))
            ?? AgentConfig.presets
        self.activeAgentID = try? container.decode(String.self, forKey: .activeAgentID)
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
    ///
    /// 钳制放在**属性这一层**而不是各写入点：拖拽手势、双击复位、自检通道、
    /// 将来的任何新入口，写进来的值都过同一道闸。此前钳制散在调用方，
    /// 漏掉一处（比如直接 `store.ui.sidebarWidth = 2000`）就会把阅读区挤没。
    /// didSet 里重赋值会再触发一次 didSet，第二次值已合法、不再写，不会成环。
    public var sidebarWidth: Double = PanelWidth.sidebarDefault {
        didSet {
            let clamped = PanelWidth.clampSidebar(sidebarWidth)
            if clamped != sidebarWidth { sidebarWidth = clamped }
        }
    }
    /// AI 面板宽度（pt）。同上。
    public var aiPanelWidth: Double = PanelWidth.aiDefault {
        didSet {
            let clamped = PanelWidth.clampAI(aiPanelWidth)
            if clamped != aiPanelWidth { aiPanelWidth = clamped }
        }
    }

    /// 面板宽度的允许范围。
    ///
    /// 上下限不是装饰：太窄会把行内的图标和文字裁掉（而且 SwiftUI 不会报错，
    /// 只是安静地切掉），太宽则阅读区被挤到不可用。手改 settings.json 塞个 5000
    /// 进来就能把界面搞成一片空白，所以解码时必须钳制。
    ///
    /// 侧栏下限 200 而不是更早的 180：页签选择器搬进 `LeftRail` 之后，
    /// 内容面板不再需要为「五个页签平分」留位置，而 180 已经窄到
    /// 搜索结果行的三行摘要会被裁掉两行。
    public enum PanelWidth {
        public static let sidebarDefault: Double = 248
        public static let aiDefault: Double = 380
        public static let sidebarRange: ClosedRange<Double> = 200...420
        public static let aiRange: ClosedRange<Double> = 280...640

        /// 阅读区至少要留这么宽（pt）。面板**上限**会按窗口宽度动态收窄到这个边界为止。
        ///
        /// 只按 `upperBound` 定死是不够的：920pt 的最小窗口下两侧面板全开到上限
        /// 会把正文整个挤没。上限是「最多能给多少」，得看窗口还剩多少。
        public static let minimumReaderWidth: Double = 320

        public static func clampSidebar(_ value: Double) -> Double {
            clampSidebar(value, maxWidth: sidebarRange.upperBound)
        }

        public static func clampAI(_ value: Double) -> Double {
            clampAI(value, maxWidth: aiRange.upperBound)
        }

        /// 带**动态上限**的钳制。拖动分隔线时由 `PanelWidthPolicy` 按当前窗口宽度算上限。
        ///
        /// 上限先与 `upperBound` 取小、再与下限取大，是为了让窗口极窄时算式仍然
        /// 给出一个落在范围内的值（`min`/`max` 的顺序写反的话会得到 200...150 这种
        /// 倒挂区间，之后的钳制行为就不可预测了）。
        public static func clampSidebar(_ value: Double, maxWidth: Double) -> Double {
            clamp(value, range: sidebarRange, fallback: sidebarDefault, maxWidth: maxWidth)
        }

        public static func clampAI(_ value: Double, maxWidth: Double) -> Double {
            clamp(value, range: aiRange, fallback: aiDefault, maxWidth: maxWidth)
        }

        /// 侧栏在给定窗口条件下的可用上限：`窗口宽 − 已被占掉的部分 − 阅读区保底`。
        public static func sidebarMaxWidth(containerWidth: Double, reserved: Double) -> Double {
            max(min(sidebarRange.upperBound, containerWidth - reserved - minimumReaderWidth),
                sidebarRange.lowerBound)
        }

        /// AI 面板的可用上限，同理。
        public static func aiMaxWidth(containerWidth: Double, reserved: Double) -> Double {
            max(min(aiRange.upperBound, containerWidth - reserved - minimumReaderWidth),
                aiRange.lowerBound)
        }

        private static func clamp(
            _ value: Double,
            range: ClosedRange<Double>,
            fallback: Double,
            maxWidth: Double
        ) -> Double {
            guard value.isFinite else { return fallback }
            let upper = max(min(range.upperBound, maxWidth), range.lowerBound)
            return min(max(value, range.lowerBound), upper)
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
