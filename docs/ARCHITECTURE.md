# 架构

> 这份文档回答两个问题：**东西在哪**，以及**为什么这样放**。
> 第二问比第一问重要——目录树自己会说话，但「当初为什么不用 NavigationSplitView」
> 这类判断，不写下来下一个人就会再纠结一遍（或者更糟：直接改回去）。

---

## 1. 分层

```
┌───────────────────────────────────────────────────────────────────┐
│  LumenApp（界面层，SwiftUI）                                       │
│                                                                   │
│   RootView ── 窗口外壳：工具栏 / 命令面板 / 跳页 / 沉浸 HUD        │
│     └─ ReaderContainerView ── 三栏布局 + 可拖拽分隔线              │
│          ├─ SidebarColumn      目录 · 智能目录 · 搜索 · 缩略图     │
│          ├─ PDFReaderView / EPUBReaderView                        │
│          └─ AIPanelView                                           │
│                                                                   │
│   AppState ── 全局状态与动作（菜单栏、命令面板、侧栏共用）         │
└───────────────────────────┬───────────────────────────────────────┘
                            │  ReaderBridge（唯一通道）
┌───────────────────────────┴───────────────────────────────────────┐
│  LumenKit（引擎层，无 SwiftUI）                                    │
│                                                                   │
│   Document/    PDF·EPUB 的解析模型、定位符、元数据、全文抽取        │
│   Store/       设置 · 阅读进度 · 最近打开 · 快捷键 · 记忆 · 路径    │
│   AI/          AIProvider 协议 · OpenAI 兼容客户端 · 提示词 · 目录  │
│   OCR/         纯 Vision 框架的逐页识别                            │
└───────────────────────────────────────────────────────────────────┘
```

**分界线是硬的：`LumenKit` 不 import SwiftUI。** 代价是有些便利拿不到（比如直接
在 Store 里发 `@Published`），收益是业务逻辑可以脱离界面被验证——在这台没有屏幕可看的
机器上，这是能不能做客观验证的前提。

---

## 2. 为什么要中间那层 `ReaderBridge`

PDF 和 EPUB 的阅读实现差别极大（PDFKit vs WKWebView），但外框要做的事是一样的：
显示页码、显示目录、搜索、跳转、划词。若让外框直接持有两个控制器，每个调用点都要
`if pdf ... else ...`，而且新增一种格式要动遍所有调用点。

所以定了一组**格式无关的接口**，两种实现各自填：

```
ReaderBridge
├── 状态（视图 → 外壳）
│   selection · positionLabel · progress · outline · searchResults
│   currentUnitIndex · unitCount · metadata · sidebarTab
│   isScannedDocument · ocrRunningPage · isLoading · loadError
│
└── 命令（外壳 → 视图），全部是可选闭包 —— 「这个格式不支持」用 nil 表达，不需要额外枚举
    thumbnailProvider      (Int, CGSize) -> NSImage?          仅 PDF
    retrieveProvider       (String) -> [(label, locator, text)]   关键词检索，用于提问
    slicesProvider         () -> [(label, text)]               全文切片，整本总结用
    unitSnippetProvider    () async -> [(index, text)]         每单元开头，智能目录第一步
    sectionTextProvider    (Int, Int) async -> String          单元区间正文，摘要第二步
    currentContextProvider () -> (String, DocumentLocator)
    ocrTextProvider        (Int) -> String?
    extractFullText        (Bool, progress) async -> Report
    goTo / goToNextUnit / goToPreviousUnit / performSearch / clearSearch
    zoomIn / zoomOut / zoomToFit                               仅 PDF
    requestOCR
```

**为什么全用闭包而不是协议**：闭包可以按格式各自捕获自己的控制器（`[weak controller]`），
不需要为一个「只有 PDF 才有」的方法在 EPUB 那边写一个空实现。可选闭包把
「不支持」这个状态直接编进了类型里。

**注意 `unitSnippetProvider` 与 `slicesProvider` 是刻意分开的两条**：
取样方式正好相反——切片要每段尽可能多的正文（用来总结内容），而识别结构只需要
每页开头那一小截（标题、编号都在页首）。复用的话，一本 300 页的书要把全文读出来
才能给出页首那点信息，白等好几秒。

---

## 3. 三条主要数据流

### 3.1 打开文档

```
AppState.open(url:)
  └─ 校验存在性 → 判定 DocumentKind → RecentDocuments.record → 发布 OpenDocument
       └─ ReaderContainerView 的 .task(id: document.id) 触发
            ├─ chat.bind(to:)           载入这本书的对话存档
            ├─ smartOutline.bind(to:)   载入这本书的智能目录缓存
            └─ PDFReaderView / EPUBReaderView 的 prepare()
                 ├─ bridge.reset()      清掉上一本的残留（否则会串台）
                 ├─ 解析文档、建目录、检测是否扫描件
                 ├─ wireCallbacks()     注册命令闭包
                 └─ wireDocumentWideProviders()  注册整本书级的数据通道
```

**顺序有个坑**：`prepare()` 里会调 `bridge.reset()`，早于它插入的状态会被清掉。
所以自检通道（`applyLaunchDiagnostics`）必须等文档真的装好之后再动手——
否则会得到「浮层没出现」这种假结论。

### 3.2 一次 AI 请求

```
SelectionActionBar / AIPanelView
  └─ AppState.pendingAIRequest = AIRequest(kind:selection:)   ← 「投递」
       └─ AIPanelView 消费后清空
            └─ AIChatModel.submit(...)
                 ├─ 校验配置（isConfigured：云端要有 Key，本地只要模型名）
                 ├─ PromptLibrary.messages(...)    ← 纯函数，好测
                 └─ OpenAICompatibleProvider.stream(...)  → SSE 逐 token
                      └─ 节流合并进气泡（约 25Hz）
```

**为什么用「投递 + 消费」而不是直接调面板方法**：阅读区和 AI 面板之间因此不需要
互相持有引用。弹出面板、切页签这些副作用也就不用写在阅读区里。

**为什么流式要节流**：模型每秒可能吐几十个 token，每个 token 写一次 `@Published`
会让 SwiftUI 在一帧内重排多次，滚动立刻掉帧。合并到约 25Hz 后视觉上仍是逐字出现。

### 3.3 智能目录（两步走）

```
第一步：生成骨架（一次请求）
  bridge.unitSnippetProvider()         每单元开头 ~260 字
    └─ SmartOutlineDigest.make(...)    超 160 单元时等步长抽样（首尾必取）
         └─ PromptLibrary.smartOutlineMessages(...)   「只输出 JSON」
              └─ provider.completeText(...)           非流式，只要最终结果
                   └─ SmartOutlineParser.parse(...)   宽容解析
                        └─ SmartOutline 落盘

第二步：单节摘要（用户点哪条算哪条）
  bridge.sectionTextProvider(start, end)     区间 = 本条到「下一条之前」
    └─ PromptLibrary.entrySummaryMessages(...)
         └─ 写回该条目的 summary 并落盘
```

**为什么拆两步**：一本 300 页的书若要求「目录 + 每节摘要」一次输出，输出长度会直接
顶到 `max_tokens`，中途任何一处失败都得整本重来——白花的钱是实打实的。骨架只有几十行，
生成快、失败代价小。

**解析器为什么必须极度宽容**：即便提示词里反复强调「只输出 JSON」，模型仍然经常加上
```json 围栏、来一句「好的，以下是目录：」、或在数组后补一段说明。脆弱的解析会让这个
功能时灵时不灵，而用户看到的只是「生成失败」，完全无从下手。
`SmartOutlineParser.extractJSONArray` 取「第一个 `[` 到最后一个 `]`」，不做配平扫描。

**越界条目为什么扔掉而不是钳制**：钳制会把多个假条目全挤到最后一页，在目录里堆出
一串指向同一位置的重复项，比缺几条难看得多。

---

## 4. 存储布局

`~/Library/Application Support/com.jn.lumen/`

```
settings.json        全部设置（逐字段容错解码）
recent.json          最近打开
memory.json          跨会话记忆
keybindings.json     快捷键改绑的**差量**（未改过的动作走默认值，
                     这样以后新增动作时老用户的配置不需要迁移）
docs/<路径哈希>/
  state.json         阅读进度与位置
  chats.json         这本书的 AI 对话
  smart-outline.json 这本书的智能目录（含已生成的摘要）
```

`~/Library/Caches/com.jn.lumen/` 放 EPUB 解包结果——**可随时安全删除**，丢了会重新解包。

路径哈希用 FNV-1a 64 位（`AppPaths.stableHash`）：稳定、跨进程一致、不需要 CryptoKit。

**API Key 不在这里**。只进 Keychain，账户名由 `AIProviderConfig.keychainAccount` 决定。

---

## 5. 关键决策记录

| 决策 | 理由 |
| --- | --- |
| 用 `HStack` + 自绘分隔线，不用 `NavigationSplitView` | 要同时控制三栏宽度、出现动画、分隔线颜色。`NavigationSplitView` 会强加系统材质与自带侧栏开关，反而更难收敛视觉 |
| 面板宽度存进设置而不是本地 `@State` | 宽度的唯一真相源就该是配置（它要持久化）。留两份的话，设置页改了宽度、或双击复位，两边就会不同步 |
| 拖动分隔线期间不加动画 | 用增量（起点宽度 + delta）计算。加了动画会让分隔线「追」鼠标 |
| 沉浸模式用两个 `Spacer` 而不是给阅读区加 padding | padding 得先知道窗口宽度才能算居中的边距，要套 `GeometryReader`；两个 Spacer 让 `HStack` 自己平分剩余空间，天然居中且宽度变化有动画 |
| 沉浸模式退出时恢复**进入前**的面板可见性 | 「进入时全关、退出时全开」会把本来关着 AI 面板的用户的面板打开——他从没要求过 |
| 缩略图用串行队列 + 可视区判定 | 滚动时数百页渲染任务排队是卡顿的根因。串行 + `VisibleTracker`（`NSLock` 保护）跳过不可见页 |
| 智能目录的「摘要」与「展开」是两个控件 | 「摘要」明摆着要花钱，「展开」是免费的本地操作。把付费动作藏在「展开」里，用户点着点着账单就上去了 |
| 付费动作不给快捷键 | 「生成智能目录」是菜单项但没有快捷键。一次误触的代价是一次真实的模型调用 |
| 全文抽取的两个字符门槛故意不同 | `usableText` 用 24 字符门槛（AI 上下文宁可这页什么都不给，也好过把页码当正文）；「复制全文」默认只要非空就采用（少一格正文比多一个页码严重得多） |
| 菜单项是快捷键生效的前提 | SwiftUI 的 `.keyboardShortcut` 只在菜单项上才全局响应。只在命令面板里有、没有菜单项的动作，用户改了绑定也按不出效果——那属于骗人 |

---

## 6. 已知的边界

- **辅助功能权限未授予**，所以拖拽手势、键盘模拟无法程序化验证。面板宽度这类
  依赖拖拽的功能，验证走的是「直接写设置项」的等效路径。
- **助手没有视觉通道**，所有「看起来对不对」的问题都要转成可断言的信号。
  详见 `docs/VERIFY.md`。
- OCR 走纯 Vision 框架，没有引入第三方识别库；扫描件的识别质量取决于源图质量。
