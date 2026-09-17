# Lumen（流明阅读）· 设计文档

> 一个 macOS 原生 PDF / EPUB 阅读器，内置 AI 阅读模式。
> 状态：**待评审**（阶段一产出，经确认后进入开发）

---

## 0. 环境核查结论（本机实测，非推测）

| 项目 | 实测结果 | 影响 |
|---|---|---|
| macOS | 26.6.2 (25G83)，arm64 | 平台基线 |
| Swift | 6.1.2（swift-driver 1.120.5） | 可用 Swift 6 严格并发 |
| Xcode | **未安装**，仅 CommandLineTools | 见 §2 决策 D1 |
| SDK | MacOSX15.5.sdk（CLT 内置） | 部署目标定 macOS 15.0 |
| Homebrew | **未安装** | 本方案不需要 |
| 磁盘可用 | **31 GiB**（Data 卷已用 399 GiB / 93%） | 硬约束，禁用大体积工具链 |
| 网络 | github.com 200 ✅ | 可拉 SwiftPM 依赖 |
| AI 凭据 | 环境变量中**无任何 API key** | 必须做应用内 Keychain 配置 |

**已实测验证的两项关键假设（各写了一个探针）**：

1. **仅 CLT + SwiftPM 能编译 SwiftUI + PDFKit + WebKit** ✅
   `swift build --disable-sandbox` 成功链接并产出 arm64 Mach-O。（注意：必须带 `--disable-sandbox`，否则 CLT 的 SwiftPM 报 `sandbox_apply: Operation not permitted`。）
2. **手工组装 .app bundle 可正常启动** ✅
   写 Info.plist → 放二进制 → `codesign --force --sign -` → `open`，进程正常拉起。

这两条决定了下面的 D1 决策：**不需要装 Xcode**。

---

## 1. 需求确认

### 用户明确要求
- 支持 **PDF 与 EPUB** 两种格式打开与阅读
- **不做文件存储 / 书库管理**，只有"打开本地文件并阅读"
- **流畅度与视觉美观为最高优先级**，参考 UPDF 架构与 Apple 设计风格
- **内置原生 AI 功能模式**，参考本机 OakReader 与 TensorReading 的功能与实现方式
- 先查环境，缺什么依赖由我直接装

### 需求澄清（我的理解，请确认）
| # | 我的理解 | 若与此不符请纠正 |
|---|---|---|
| C1 | "不做书库管理" = 不做导入/分类/标签/元数据抓取，但**记住最近打开文件与阅读进度**是允许的（否则每次重开都丢进度，体验反人类） | |
| C2 | "参考 UPDF 架构" 在技术上指向：**PDFKit 内核 + 原生 SwiftUI 外壳 + 本地 AI 服务层**，而不是 Web 套壳 | |
| C3 | AI 走 **BYOK**（自备 API Key），不绑定任何一家云服务，也不做需要账号体系的远程代理 | |
| C4 | 交付物是一个**可直接双击运行的 .app**，不做 App Store 上架（无 Developer ID 证书，只能 ad-hoc 签名） | |

### 一个必须提出的异议
你此前明确说过「能挂进现有客户端就挂进去，别养第二个界面」，并因此删掉了独立版「阅读工作台」，改成给 Pixcall 写插件。

这次要独立原生 App，**与那条偏好正面冲突**，所以我把它作为必答项列进确认清单（见文末 Q1）。我的技术判断是：这次做原生 App 是合理的——**因为 PDFKit 的渲染性能在插件沙箱里拿不到**，而这正是你列的最高优先级。但决定权在你。

---

## 2. 技术选型（含备选与取舍）

### D1 构建方式：**纯 SwiftPM + CommandLineTools（不装 Xcode）** ⭐推荐

| 方案 | 优点 | 代价 | 结论 |
|---|---|---|---|
| **A. SwiftPM + CLT** | 零额外磁盘占用；已实测可行；OakReader 本身就是 SwiftPM 风格的资源包结构 | 无 Interface Builder、无 SwiftUI Preview、无 Instruments、`xcodebuild archive` 不可用 | ✅ 选它 |
| B. 安装 Xcode | 标准工程、Preview、Instruments、可归档分发 | 下载 ~15 GB + 安装 ~40 GB，而你**只剩 31 GiB**，装完系统会满 | ❌ 磁盘不允许 |
| C. Tauri（抄 TensorReading） | Web 前端做视觉快 | 与"Mac 原生 / Apple 设计风格 / 流畅度最高"三个目标同时相悖；还要装 Rust 工具链 | ❌ 方向错误 |

### D2 渲染引擎（有本机证据支撑，不是猜的）

我从 OakReader 可执行文件的符号表里读到了它的真实选型：

```
PDFViewerRepresentable / PDFViewCoordinator / PresentationPDFView / PDFViewDelegate
PDFViewOpenPDF:forRemoteGoToAction: / PDFViewPerformFind: / PDFViewWillChangeScaleFactor:
WKWebView + WKWebViewConfiguration / WKNavigationAction / WKWindowFeatures
```

即 **PDF 走 PDFKit，EPUB 走 WKWebView**。这与 UPDF 的路线一致（UPDF 用 `UPDFKit.framework` 包 PDFKit），也与我原本的判断吻合，所以直接沿用：

- **PDF → PDFKit `PDFView`**：CATiledLayer 硬件加速、矢量不失真、原生文本选择 / 查找 / 链接跳转 / 批注，比任何自绘方案都快。
- **EPUB → WKWebView + 注入式排版层**：EPUB 本质是 XHTML + CSS，只有 WebKit 能 100% 还原排版、MathML、SVG、嵌入字体。字体 / 行高 / 主题通过 `WKUserScript` 注入 CSS 变量，切换零重载。

### D3 AI 接入：**BYOK，OpenAI 兼容协议为主**

OakReader 的实现（符号表实证）：`AnthropicProvider` / `OpenAIProvider` / `OpenAIResponsesProvider` / `OpenAISTTProvider` / `OpenAITTSProvider` / `ProviderEndpointStore` / `LocalModelDiscovery`，文案里有
> "OpenAI-compatible API base, e.g. `http://localhost:11434/v1`"

而且它读 `OPENAI_API_KEY` / `ANTHROPIC_API_KEY` / `DEEPSEEK_API_KEY` / `GEMINI_API_KEY` 四个环境变量。

对比 TensorReading：它走的是**自家远程代理**（`tensorx.xin/api/proxy/*`、`gemini.tensorx.xin`、`users.token` + `TOKEN_EXPIRED`），AI 能力被账号体系绑住。

**结论：抄 OakReader 的路子，不抄 TensorReading 的。** 一套 OpenAI 兼容协议（`/chat/completions` + SSE 流式）就能覆盖 DeepSeek / OpenAI / Gemini / Kimi / 通义 / Ollama / LM Studio。

### D4 其余依赖（每个都给了退路）

| 需求 | 选择 | 理由 | 退路 |
|---|---|---|---|
| EPUB 解包 | **ZIPFoundation**（SwiftPM） | 小、稳、纯 Swift、无 C 依赖 | 核 `ditto` / 自研 zip reader |
| 扫描版 PDF OCR | **Vision `VNRecognizeTextRequest`** | 系统框架、本地、免费、中文识别好、无需联网 | 可选接云端 OCR |
| 本地语音朗读 | **AVSpeechSynthesizer** | 系统 TTS、离线、零成本 | 云端 ElevenLabs / Fish Audio（对齐 OakReader） |
| 中文分词 / 全文检索 | **NaturalLanguage + 自建倒排索引** | 无第三方依赖 | SQLite FTS5 |
| 本地持久化 | **JSON + Application Support**（按文档路径哈希分目录） | 不引数据库，符合"不做书库" | GRDB/SQLite |
| 数据模型 | 纯 Swift `Codable` + `actor` 隔离 | Swift 6 严格并发 | — |

---

## 3. 架构设计

### 3.1 分层

```
┌──────────────────────────────────────────────┐
│  LumenApp  (SwiftUI, @MainActor 全体)         │
│  ReaderWindow · PDFReaderView · EPUBReaderView│
│  AIPanel · SelectionPopover · VoiceBar        │
│  DesignTokens · Components                    │
└───────────────┬──────────────────────────────┘
                │  只依赖协议，不依赖实现
┌───────────────▼──────────────────────────────┐
│  LumenKit  (核心引擎, 无 UI)                   │
│  ┌────────────┬────────────┬───────────────┐ │
│  │ Document   │ Text       │ AI            │ │
│  │ PDFSource  │ Extractor  │ Provider      │ │
│  │ EPUBSource │ Chapter    │ Session       │ │
│  │ Parser     │ Locator    │ MemoryStore   │ │
│  ├────────────┼────────────┼───────────────┤ │
│  │ TTS        │ OCR        │ Search        │ │
│  │ AVSpeech   │ Vision     │ InvertedIndex │ │
│  │ Remote     │            │               │ │
│  ├────────────┴────────────┴───────────────┤ │
│  │ Store: SettingsStore · ReadingState      │ │
│  └─────────────────────────────────────────┘ │
└──────────────────────────────────────────────┘
```

**为什么分两个 target**：PDFKit / WebKit 都是 `@MainActor` 受限的非 Sendable 类型。把解析、AI、索引放进无 UI 的 `LumenKit`，UI 层就不可能误在后台线程碰 PDFKit；引擎层也能独立跑测试。

### 3.2 统一文档抽象（关键接口）

PDF 和 EPUB 在交互上完全不同，但 AI 功能需要统一的「定位 → 取文本 → 跳转」能力。所以抽象出一个 `DocumentSource` 协议：

```swift
public protocol DocumentSource: AnyObject, Sendable {
    var kind: DocumentKind { get }              // .pdf / .epub
    var metadata: DocumentMetadata { get }
    var outline: [OutlineNode] { get }          // 目录
    var pageCount: Int { get }                  // EPUB 按"章节"计

    func plainText(of locator: DocumentLocator) async throws -> String
    func locator(forRange: TextRange) -> DocumentLocator
    func search(_ query: String) async -> [SearchHit]
}
```

`DocumentLocator` 是 PDF/EPUB 的通用坐标：PDF 是 `(page, charOffset)`，EPUB 是 `(chapterIndex, cssSelectorPath, charOffset)`。AI 回答里的「引用」就是一组 Locator，点击即跳转——这正是 OakReader 的 `oak://cite/` 在做的事。

### 3.3 AI 子系统

```
AIStore(Keychain) ──> AIProvider(协议)
                        ├── OpenAICompatibleProvider   ← 主力（DeepSeek/OpenAI/Gemini/Kimi/Ollama…）
                        ├── AnthropicProvider          ← 可选
                        └── (预留) 其他
                             │
AISession ───────────────────┼──> 对话历史 + 文档上下文 + 引用
  ├── SelectionAsker         │   划词即问
  ├── BookChat               │   全书对话（章节摘要树 + 检索增强）
  ├── Translator             │   段落对照 / 全文
  └── NoteMaker              │   摘要 → Markdown 笔记
MemoryStore ─────────────────┘   跨会话持久记忆（OakReader 的「已保存的记忆」）
```

**上下文策略（决定 AI 回答质量的关键）**：
- 划词问答 → 选中段 + 前后各 1 段 + 文档元数据 + 目录位置
- 全书对话 → 先用本地倒排索引检索相关片段（RAG），把 top-k 片段塞进 prompt，而不是硬塞全书；回答必须带 Locator 引用
- 长文档 > 上下文窗口 → 章节级摘要树（map-reduce）

**降级策略**：无 key 时所有 AI 入口可见但给出引导，不崩溃、不静默失败；断网时本地功能（阅读 / 搜索 / OCR / 本地 TTS）完全可用。

### 3.4 流畅度专项设计（最高优先级，逐条可验收）

| 瓶颈 | 对策 |
|---|---|
| PDF 首屏慢 | 打开即用 `PDFDocument` 的首页 + 相邻页预渲染；缩略图侧栏走 `PDFPage.thumbnail` 后台队列 + 缓存 |
| PDF 大文件卡顿 | `displayMode = .singlePageContinuous` + 关闭 `displaysAsBook`；不一次性取全书文本，按需分页提取并缓存 |
| EPUB 长文档 DOM 爆炸 | **章节级虚拟化**：只保留当前章 ±1 章的 DOM，其余卸载；翻章只替换容器内容，不重建 WKWebView |
| EPUB 主题切换闪烁 | CSS 变量挂在 `:root`，用 `evaluateJavaScript` 改变量值，不 reload |
| AI 流式输出掉帧 | SSE 解析在 `actor` 里跑，UI 侧用 `AsyncStream` + 节流合并（≥16ms 才刷一次），避免每个 token 一次 `@Published` |
| 索引阻塞 | 全文索引在 `.utility` QoS 后台建，进度回报到 UI |
| 启动慢 | 不在启动时建索引 / 不扫盘；`WindowGroup` 延迟挂载重组件 |
| 中文排版 | `text-align: justify; text-justify: inter-ideograph; line-break: strict; hanging-punctuation: allow-end` |

### 3.5 视觉设计（Apple 风格的具体落点）

- 窗口：`NSWindow` 全尺寸内容视图、`titlebarAppearsTransparent`、`toolbarStyle = .unified`、Sidebar 用 `.listStyle(.sidebar)` + `NavigationSplitView`
- 材质：侧栏 / AI 面板用 `Material`（`.sidebar` / `.regularMaterial`）而非硬编码灰
- 排版：SF Pro（正文）/ SF Pro Text（UI），标题用 `.rounded` 设计的粗体；中文回落 PingFang SC
- 阅读区可选主题：纸白 / 暖黄 / 灰绿 / 深夜 / 纯黑（OLED），全部基于语义色 + 动态对比度
- 动效：`matchedGeometryEffect` 做 AI 面板展开；弹簧参数统一收敛到 `DesignTokens`，禁止散落魔数
- 无障碍：全键盘可达（⌘K 命令面板）、`accessibilityLabel` 完整、支持动态字体与"减弱动态效果"

**视觉参考实现**：OakReader 的做法值得抄——阅读区本身极简、所有控制项收进浮动工具条与命令面板，让页面成为唯一主体。

### 3.6 AI 功能清单（参考两个应用的实测功能，分级）

**两个参考应用的实际 AI 能力（从二进制与数据库实证）**

OakReader：AI 服务商多选 + 持久记忆 + 语义搜索 + 扩展思考(reasoning) + 摘要生成 + 元数据提取 + 全文索引 + ElevenLabs/Fish Audio/OpenAI 三套 TTS + 语音朗读 + `oak://cite/` 引用跳转 + 可编辑的 `VOICE.md` 文风文件

TensorReading：DeepSeek 推理对话 + 文/图翻译 + Gemini 处理 PDF + 百度 OCR + 文献知识图谱(`kg_graph`) + PDF 图表抽取(`extract_pdf_figures`) + 文献发现(Semantic Scholar / OpenAlex / Unpaywall) + 自动成文 + 本地 HTTP API(端口 23120)

**Lumen 的功能分级**

| 级别 | 功能 |
|---|---|
| **M 必须有** | 划词即问（解释/追问）、AI 对话面板、段落翻译、AI 服务商与 Key 配置（Keychain）、流式输出、引用跳转回原文 |
| **S 应该有** | 全书对话（RAG + 引用）、TTS 朗读（划词 + 连续，本地引擎）、扫描版 PDF 的 OCR 文本层、AI 摘要导出 Markdown、跨会话持久记忆、⌘K 命令面板 |
| **C 可以有** | 语义搜索（嵌入向量）、双栏对照翻译、批注/高亮 + 笔记、KaTeX 公式、多标签页 |

**不做的**（远超范围，明确排除）：书库管理、元数据抓取、文献发现、知识图谱、博客生成、云同步、账号体系。

---

## 4. 数据模型

```
~/Library/Application Support/com.jn.lumen/
├── settings.json                     # 全局偏好（主题、排版、AI 服务商配置*）
├── recent.json                       # 最近打开（仅路径 + 时间 + 进度）
├── memory.json                       # 跨会话 AI 记忆
└── docs/<sha256(路径)>/
    ├── state.json                    # 阅读位置、缩放、主题覆盖
    ├── annotations.json              # 高亮 / 批注 / 笔记（C 级功能）
    └── chats.json                    # 该书的历史对话
```

*API Key **不落这些文件**，只进 Keychain（service = `com.jn.lumen.ai`，account = 服务商 id）。
按路径哈希而非文件名分目录，避免同名文件互相覆盖。

---

## 5. 验收标准

| 维度 | 指标 |
|---|---|
| 启动 | 冷启动 < 1.5 s |
| PDF | 100 MB / 500 页文档，首屏 < 1 s；连续滚动稳定 60 fps（`CADisplayLink` 采样验证） |
| EPUB | 翻章无白闪、无重排跳动；主题切换 < 1 帧 |
| 内存 | 打开 300 MB PDF 常驻 < 500 MB |
| AI | 首 token 延迟 = 网络延迟（无额外阻塞）；流式输出期间滚动不掉帧 |
| 降级 | 无 key / 断网 / 损坏文件 → 全部优雅处理，绝不崩溃 |
| 体积 | 产物 .app < 50 MB（构建缓存除外，需提示用户 `.build` 会占 1–2 GB） |

---

## 6. 风险预演（"上线后最可能挂哪"）

| 风险 | 概率 | 对策 |
|---|---|---|
| Swift 6 严格并发 vs PDFKit/WebKit 非 Sendable 类型 | **高** | 所有 PDFKit 调用锁在 `@MainActor`；解析结果转成自己定义的 `Sendable` DTO 后再跨隔离域 |
| WKWebView 超大章节滚动卡顿 | 中 | 章节虚拟化 + 分块渲染；实测 >2000 DOM 节点即触发 |
| `swift build` 首次编译慢（实测 ~58 s） | 确定 | 增量构建；发布用 `-c release` |
| 磁盘只剩 31 GiB | **高** | 产物 < 50 MB；`.build` 缓存需在 TASK 里显式提示并给清理脚本 |
| 无 Developer ID，只能 ad-hoc 签名 | 确定 | 首启可能需右键打开；不承诺公证/上架 |
| SwiftPM 沙箱报错 | 确定 | 构建脚本统一带 `--disable-sandbox` |
| 依赖拉取失败 | 中 | ZIPFoundation 是唯一外部依赖，可退化为系统 `ditto` 解包 |

---

## 7. 待你确认的决策项

- **Q1** 方向：确认做独立原生 App？（与"别养第二个界面"偏好冲突）
- **Q2** 构建：走 A 方案（SwiftPM + CLT，不装 Xcode）？
- **Q3** AI 功能范围：M 级 / M+S / M+S+C
- **Q4** AI 接入：BYOK OpenAI 兼容 / 只要本地模型 / 两者都要

确认后产出 `TASK.md` 并进入开发。
