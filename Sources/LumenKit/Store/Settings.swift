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
    /// 字号倍率下限。`FontScale.min` 对齐到这里，避免两处各抄一份字面量。
    public static let fontScaleMin: Double = 0.6
    /// 字号倍率上限。`FontScale.max` 对齐到这里，避免两处各抄一份字面量。
    public static let fontScaleMax: Double = 2.4
    /// 字号作用范围说明：只描述事实边界，不依赖任何文档上下文，供多处复用。
    ///
    /// 为何是 `static let` 而非实例字段：它是给界面文案用的常量，不是用户设置；
    /// 加实例字段会进 `CodingKeys`，动到 settings.json 的编码，容易踩到上面的
    /// 容错解码硬约束。纯静态常量不参与编码，安全。
    public static let fontScaleScopeNote = "字号仅对 EPUB 正文生效；PDF 使用文档自带字号，不可调整"
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
    /// 页面外围画布亮度；纸张着色由 pdfOriginalColors 单独控制。
    public var pdfCanvasBrightness: Double = 1.0
    public var pdfOriginalColors: Bool = false
    public var epubDoubleColumn: Bool = false
    /// EPUB 逐段翻译开关。译文显示在每段原文上方。
    public var epubTranslateEnabled: Bool = false
    /// 逐段翻译的目标语言（必应语言标签）。默认 `zh-Hans`。
    public var translationTargetLanguage: String = "zh-Hans"
    /// 逐段翻译用的引擎 id（见 `TranslationEngineCatalog`）。
    ///
    /// 存 id 而不是存枚举：以后加引擎（离线语言包 / 收费 API）时老配置不用迁移，
    /// 认不出来的值会在解码时退回默认。
    public var translationEngineID: String = TranslationEngineCatalog.defaultID
    /// 切换到 LLM 之前正在用的「机器」引擎 id。
    ///
    /// 面板的机器/LLM 分段开关在切成 LLM 前把当前机器引擎记在这里，
    /// 切回「机器翻译」时恢复它 —— 否则 URL 只会回到默认的 Apple 系统翻译，
    /// 用户显式选过的微软翻译会在一次 LLM 往返后被悄悄丢掉。
    /// 不在目录里的值会在解码时退回默认（见容错解码），所以它安全。
    public var translationMachineEngineID: String = AppleSystemTranslation.engineID
    /// PDF 翻译术语表。机器翻译保留这些条目但不承诺采用；LLM 翻译会把它们写进提示词。
    public var translationGlossary: [TranslationGlossaryEntry] = []
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
        self.epubDoubleColumn = (try? container.decode(Bool.self, forKey: .epubDoubleColumn)) ?? false
        self.pdfOriginalColors = (try? container.decode(Bool.self, forKey: .pdfOriginalColors)) ?? false
        self.pdfCanvasBrightness = (try? container.decode(Double.self, forKey: .pdfCanvasBrightness)) ?? 1.0
        self.autoAdvanceOnScrollEnd = (try? container.decode(Bool.self, forKey: .autoAdvanceOnScrollEnd)) ?? true
        self.epubTranslateEnabled = (try? container.decode(Bool.self, forKey: .epubTranslateEnabled)) ?? false
        // 目标语言是字符串：解出来可能不是合法标签（手改过配置的人什么都写得进去），
        // 空串也会让翻译请求白跑一趟，所以这里兜回默认。
        let target = (try? container.decode(String.self, forKey: .translationTargetLanguage)) ?? "zh-Hans"
        self.translationTargetLanguage = target.isEmpty ? "zh-Hans" : target
        // 引擎 id 同理，而且多一层校验：必须**在目录里存在**才认。
        // 直接照抄字符串的话，配置里留着一个已下线的引擎名会让取引擎时落到兜底分支，
        // 而设置界面显示的值与实际用的引擎不一致 —— 那是骗人的。
        self.translationEngineID = TranslationEngineCatalog
            .descriptor(for: try? container.decode(String.self, forKey: .translationEngineID))
            .id
        self.translationMachineEngineID = TranslationEngineCatalog.descriptor(
            for: try? container.decode(String.self, forKey: .translationMachineEngineID)
        ).id
        self.translationGlossary = (try? container.decode([TranslationGlossaryEntry].self,
                                                           forKey: .translationGlossary)) ?? []
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
        self.models = []
        for raw in models {
            let model = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if !model.isEmpty, !self.models.contains(model) { self.models.append(model) }
        }
        self.selectedModel = selectedModel.trimmingCharacters(in: .whitespacesAndNewlines)
        if !self.selectedModel.isEmpty, !self.models.contains(self.selectedModel) {
            self.models.append(self.selectedModel)
        }
        self.temperature = temperature
        self.maxTokens = maxTokens
        self.extendedThinking = extendedThinking
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = (try? container.decode(UUID.self, forKey: .id)) ?? UUID()
        self.name = (try? container.decode(String.self, forKey: .name)) ?? "未命名服务商"
        self.baseURL = (try? container.decode(String.self, forKey: .baseURL)) ?? ""
        let decodedModels = (try? container.decode([String].self, forKey: .models)) ?? []
        self.models = []
        for raw in decodedModels {
            let model = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if !model.isEmpty, !self.models.contains(model) { self.models.append(model) }
        }
        self.selectedModel = ((try? container.decode(String.self, forKey: .selectedModel)) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !self.selectedModel.isEmpty, !self.models.contains(self.selectedModel) {
            self.models.append(self.selectedModel)
        }
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

    /// 可选的 Agent（角色 + 勾选的技能 + 是否联网检索）。首次启动填入内置预设。
    public var agents: [AgentConfig] = AgentConfig.presets
    /// 当前选中的 Agent。`nil` = 不加角色，走默认助手行为。
    public var activeAgentID: String?

    /// 全局技能库：所有 Agent 共用的一份「可选技能」清单。
    ///
    /// 为什么是全局而不是每个 Agent 各存一份：技能是**读法**（「论据回原文」这类规矩），
    /// 不是某个角色的私产。各存一份的话，用户在 A 里调好的技能切到 B 就没了，
    /// 只能重写一遍；而这里改一处，用它的所有 Agent 一起变。
    /// 代价是不能给某个 Agent 留特例——界面上如实写着「改的是共用样式」。
    ///
    /// 首次启动灌入 `AgentSkill.catalog`；用户删掉的内置技能不会自己长回来
    /// （与 `agents` 同一条规则，见下面的解码）。
    public var skillLibrary: [AgentSkill] = AgentSkill.catalog

    /// 输入框上的「联网检索」手动开关。
    ///
    /// 与 `AgentConfig.usesWebSearch` 是**两个独立的触发条件**（满足其一即检索）：
    /// Agent 那个是「这个角色定位上就需要查文献」（属于 Agent 的一部分，跟着 Agent 走），
    /// 这个是「我这一次想查」（属于这一次提问，不改动任何 Agent）。
    /// 合二为一的话，用户想临时查一次就得去改 Agent 配置——而改完往往忘了改回来。
    ///
    /// 默认关：检索要给三个外部库发请求，每次提问多花几秒，
    /// 不该在用户没要求的时候替他付这个代价。
    public var webSearchEnabled: Bool = false

    public init() {}

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        // 逐字段容错解码是项目硬约束（见 docs/AUDIT-code-health-2026-09-17.md 的
        // 「明确不算问题」一节），所以这里保留 `?? []`。
        //
        // 但 providers 的默认值 [] 是唯一一个**危险默认**：它是用户的全部服务商配置，
        // 一旦因为某个字段解码失败被容错成空数组，SettingsStore 下一次保存就会把
        // 「用户把服务商全删了」这个假象写死到磁盘上（密钥还在 Keychain，配置要重录）。
        //
        // 由于 AppSettings.init(from:) 用的是同一套逐字段容错（`try?`），这种失败
        // **不会**让整份文件解码抛错，文件级备份因此抓不到它。所以真正的防护在
        // SettingsStore.load：它比对「磁盘上 providers 有几条」与「解出来有几条」，
        // 发现「磁盘非空、解出为空」就把 settings.json 整份备份掉。这里不再重复实现。
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
        // 只有磁盘上**完全没有 agents 这个键**时才灌预设（首次启动，或该功能上线前的旧配置）。
        //
        // 原先这里是「缺哪个预设就补哪个」，那是为了让新版本增加的内置 Agent 自动出现在
        // 老用户那里。但编辑器现在允许删除**任意** Agent，两套规则并存就会出现
        // 「删掉的 Agent 下次启动自己长回来」——比「新预设不自动出现」糟得多。
        // 取舍已如实写下：以后新增内置预设，老用户需要自己新建一份。
        self.agents = (try? container.decode([AgentConfig].self, forKey: .agents))
            ?? AgentConfig.presets
        // 产品层面下线的预设按稳定 id 清掉：用户磁盘上那份副本不会自己消失，
        // 不清理的话「已经下线的功能」会以旧数据的形态继续活在编辑器里。
        self.agents.removeAll { AgentConfig.retiredPresetIDs.contains($0.id) }

        // 技能库与 agents 同一条规则：只有磁盘上**完全没有**这个键才灌内置技能。
        // 写成「缺哪条内置技能就补哪条」的话，用户删掉的技能下次启动会自己长回来。
        self.skillLibrary = (try? container.decode([AgentSkill].self, forKey: .skillLibrary))
            ?? AgentSkill.catalog
        // 旧配置把技能全文存在 Agent 上（技能库里没有对应条目），这里并进技能库。
        // 不并的话用户自己写的技能会在升级那一刻**静默**消失——系统提示变短，界面看不出来。
        Self.migrateCarriedSkills(library: &self.skillLibrary, agents: &self.agents)

        self.activeAgentID = try? container.decode(String.self, forKey: .activeAgentID)
        // 选中的那个 Agent 被删掉（或被下线清理掉）之后这个 id 会悬空：面板显示「Agent」
        // 却不带勾选，内部状态自相矛盾。退回「不用 Agent」，与编辑器里删除时的处理一致。
        if let id = self.activeAgentID, !self.agents.contains(where: { $0.id == id }) {
            self.activeAgentID = nil
        }
        self.webSearchEnabled = (try? container.decode(Bool.self, forKey: .webSearchEnabled)) ?? false
    }
}

// MARK: - 技能库迁移

extension AISettings {

    /// 把 Agent 上捎出来的旧技能定义并进技能库。
    ///
    /// 两条规则都不是可选的：
    /// ① **同名的认领到库里那条**。老配置里「论证链」「术语变化」是用户自建技能
    ///    （各自带一个 UUID），而它们现在是内置技能；不认领的话技能库里会出现两张
    ///    同名卡片，用户看到的是「怎么有两个论证链」。
    /// ② 只有「库里既没有这个 id、也没有这个名字」才新增一项。只按 id 判定的话，
    ///    用户自己写的技能会被静默丢掉——它在库里没有对应条目。
    ///
    /// 认领是全局的：两个 Agent 各自攒了一份同名的「论证链」也会归到同一条上，
    /// 同名不同义的技能本来就该合并。
    static func migrateCarriedSkills(library: inout [AgentSkill], agents: inout [AgentConfig]) {
        var remap: [String: String] = [:]

        for index in agents.indices {
            for definition in agents[index].carriedSkills {
                if library.contains(where: { $0.id == definition.id }) { continue }
                if !definition.name.isEmpty,
                   let match = library.first(where: { $0.name == definition.name }) {
                    remap[definition.id] = match.id
                    continue
                }
                library.append(definition)
            }
        }

        let known = Set(library.map(\.id))
        for index in agents.indices {
            // 认领之后可能撞出重复（Agent 同时勾着新旧两个 id），去重但保序；
            // 库里没有的 id 是悬空引用，界面上会显示成一张勾不掉的空卡，一并清掉。
            var seen = Set<String>()
            agents[index].skills = agents[index].skills
                .map { remap[$0] ?? $0 }
                .filter { seen.insert($0).inserted && known.contains($0) }
            agents[index].carriedSkills = []
        }
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

    /// 侧栏宽度（pt）。**兼容字段，只写不读。**
    ///
    /// 侧栏宽度自本批起固定为 `DS.Size.sidebarIdeal`（248pt）：侧栏装的是目录 /
    /// 搜索结果 / 批注这类结构化列表，宽度由版式而非用户决定，界面上也不再给它
    /// 拖拽入口（只留 AI 面板那条分隔线）。这个字段**保留只为三件事**：
    ///
    /// 1. **旧 `settings.json` 仍能解码**——直接删字段会让旧配置命中「整份解码失败
    ///    就退回默认值」的兜底，把用户其它偏好一起清掉，那是硬约束第 2 条；
    /// 2. 旧版本写下的值仍然读得出来（便于将来真要恢复时迁移）；
    /// 3. `--panel-width` 的旧两段式写法仍被接受（第一个数解析但不生效）。
    ///
    /// 布局层（`PanelWidthPolicy`）**已经不再读它**。写入仍然经过钳制，
    /// 这样用户手改 `settings.json` 塞个 5000 进来也不会在别处以意想不到的方式被读到。
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
    /// **侧栏现在固定 248pt**（`sidebarDefault` / `DS.Size.sidebarIdeal`），
    /// `sidebarRange` 只服务于「兼容字段的钳制」——界面上已经没有拖侧栏的入口了，
    /// 所以它不再参与任何一次布局换算。
    ///
    /// AI 面板下限本批从 280 提到 **300**：footer 行（引用编号 + 四个动作按钮）
    /// 在 300pt 时刚好放平，280pt 会把「添加到批注」压成两行。这是用户明确的诉求
    /// （「限定其最小宽度」），拖拽、自检、`--panel-width` 三条写入路径共用这道闸。
    public enum PanelWidth {
        public static let sidebarDefault: Double = 248
        public static let aiDefault: Double = 380
        public static let sidebarRange: ClosedRange<Double> = 200...420
        public static let aiRange: ClosedRange<Double> = 300...640

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

        // 注：上限**随窗口宽度收窄**的算式不在这里，在 LumenApp 的
        // `PanelWidthPolicy.resolve`——它要减掉图标栏、分隔线，还要决定
        // 两侧谁让位，这些都属于版面策略而不是配置项的合法区间。
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
