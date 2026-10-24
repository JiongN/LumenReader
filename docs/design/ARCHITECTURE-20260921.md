# 架构

> 这份文档回答两个问题：**东西在哪**，以及**为什么这样放**。
> 第二问比第一问重要——目录树自己会说话，但「当初为什么不用 NavigationSplitView」
> 这类判断，不写下来下一个人就会再纠结一遍（或者更糟：直接改回去）。

---

## 1. 分层

```
┌───────────────────────────────────────────────────────────────────┐
│  LumenApp（界面层，SwiftUI + 少量 AppKit）                        │
│                                                                   │
│   WindowManager ── 窗口的唯一裁决者（NSWindow 显式创建）           │
│     ├─ AppServices ── 进程级单例：设置 / 最近打开 / 快捷键 / 记忆   │
│     └─ 每个窗口一个 AppState（工作区）                             │
│          ├─ TabBar ── 自定义标签栏（一个窗口多份文档）             │
│          ├─ ReaderSession[] ── 每份文档一个会话（保活叠层）        │
│          └─ RootView ── 窗口外壳：工具栏 / 命令面板 / 跳页 / HUD   │
│               └─ ReaderContainerView ── 三栏布局 + 可拖拽分隔线    │
│                    ├─ LeftRail             常驻纵向图标栏（页签）  │
│                    ├─ SidebarColumn        目录·智能·搜索·批注·页面 │
│                    ├─ PDFReaderView / EPUBReaderView              │
│                    └─ AIPanelView                                 │
│                                                                   │
│   AppState ── 窗口级状态与动作（标签集合、面板显隐、沉浸、         │
│              菜单栏、命令面板）；文档级状态用同名计算属性代理到    │
│              当前标签的 ReaderSession                              │
└───────────────────────────┬───────────────────────────────────────┘
                            │  ReaderBridge（唯一通道）
┌───────────────────────────┴───────────────────────────────────────┐
│  LumenKit（引擎层，无 SwiftUI）                                    │
│                                                                   │
│   Document/    PDF·EPUB 的解析模型、定位符、元数据、全文抽取、批注  │
│   Store/       设置 · 阅读进度 · 最近打开 · 快捷键 · 记忆 · 路径    │
│   AI/          AIProvider 协议 · OpenAI 兼容客户端 · 提示词 · 目录  │
│                · Agent 配置 · 联网检索 · 翻译描述/缓存/后备引擎     │
│   OCR/         纯 Vision 框架的逐页识别                            │
└───────────────────────────────────────────────────────────────────┘
```

**分界线是硬的：`LumenKit` 不 import SwiftUI。** 代价是有些便利拿不到（比如直接
在 Store 里发 `@Published`），收益是业务逻辑可以脱离界面被验证——在这台没有屏幕可看的
机器上，这是能不能做客观验证的前提。

Apple `TranslationSession` 只能由 SwiftUI 的 `translationTask` 提供，因此系统翻译会话
留在 `LumenApp/PDFReaderView`；`LumenKit` 只保存语言、引擎描述、缓存和不依赖界面的规则。
这样既保留分层，也避免把有视图生命周期约束的 session 藏进引擎层。

---

### 1.1 PDF 段落对照翻译

```
PDFDocument
  ├─ PDFLineExtractor → PDFParagraphExtractor → PDFParagraph[]
  ├─ TextLayerTrust ── 不可信时 → BookOCR
  └─ PDFTranslationController
       ├─ Apple TranslationSession（默认，LumenApp 持有）
       ├─ MicrosoftTranslator（在线后备）
       ├─ TranslationCache（目标语言 + 稳定段落 id）
       └─ PDFTranslationPane（当前页原文／译文卡片）
```

控制器抽取整本文字并维护段落状态，但界面只显示当前页，因此长文档不会一次创建大量
SwiftUI 卡片。缓存键包含目标语言和稳定段落 id，换语言不会误用旧译文；换书或取消时用
generation 丢弃迟到结果。对照栏位于 PDF 旁边，不覆盖 PDFKit 页面，不拦截文字选择、链接、
搜索和批注，也不把译文写进原文件。

选择独立对照栏源于一次真实界面证伪：页内 overlay 无法为固定版式增加高度，会遮住后续
正文。左右两列独立滚动又会引入同步误差。当前页对照栏保留原页位置与版式，同时把原文和
译文放在同一卡片中，切页后自然更新。

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
│   epubEffectiveColumns   EPUB **实际生效**的栏数（≠设置值：窗口窄于 760pt 会压回单栏）
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

    addHighlight           (String) -> Void      高亮当前选区
    addPageNote            (Int, String, String) 页内锚点批注（页号 / 锚文本 / 正文）
    annotationsProvider    () async -> [AnnotationItem]
    deleteAnnotation       (String) -> Void
    revealSearchHit        (Int) -> Void          定位到第 N 处搜索命中
    annotationRevision     Int                    批注增删后自增，侧栏据此刷新
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

### 3.1 打开文档（进标签，不进新窗口）

```
外部事件（访达打开方式 / Dock / open -a）
  └─ AppDelegate.application(_:open:) → WindowManager.openExternally(urls:)
       └─ 路由到最前面窗口的工作区（没有窗口就先建一个）

AppState.open(url:)
  └─ 校验存在性 → 判定 DocumentKind → RecentDocuments.record
       ├─ 同一路径已在任意窗口打开？→ 切到那个标签并把窗口置前（去重）
       └─ 否则新建 ReaderSession(document:) 加进 sessions 并激活
            └─ SessionHostView 懒挂载（首次切到才挂载，挂过就保活）
                 └─ ReaderContainerView 的 .task(id: document.id) 触发
                      ├─ chat.bind(to:)           载入这本书的对话存档
                      ├─ smartOutline.bind(to:)   载入这本书的智能目录缓存
                      └─ PDFReaderView / EPUBReaderView 的 prepare()
                           ├─ bridge.reset()      清掉上一本的残留（否则会串台）
                           ├─ 解析文档、建目录、检测是否扫描件
                           ├─ wireCallbacks()     注册命令闭包
                           └─ wireDocumentWideProviders()  全书级数据通道
```

**顺序有个坑**：`prepare()` 里会调 `bridge.reset()`，早于它插入的状态会被清掉。
所以自检通道（`applyLaunchDiagnostics`）必须等文档真的装好之后再动手——
否则会得到「浮层没出现」这种假结论。

**冷启动竞态**：从访达带文件冷启动时，odoc 事件可能早于
`applicationDidFinishLaunching` 送达，事件处理会先把窗口建好。
所以 `WindowManager.startup()` 必须先检查「是否已有事件建好的窗口」，
无条件再建一个就会得到「文档窗口 + 空白欢迎窗口」两个窗口。

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

### 3.4 批注（PDF 与 EPUB 走两条完全不同的路）

```
PDF：写回**原文件**
  SelectionActionBar / AIPanelView「添加到批注」
    └─ PDFController.addHighlight(fromCurrentSelection:) / addNote(pageIndex:anchorText:body:)
         ├─ 选区拆行 → 每行一个 PDFAnnotation(.highlight)   ← 贴住文字靠的是每行的 bounds
         ├─ 锚文本定位：selection(of:on:)                   ← 见下面为什么不用 findString
         └─ saveToFile()
              ├─ detachSearchHighlights()   先把搜索临时高亮摘掉
              ├─ doc.dataRepresentation() → data.write(.atomic)
              └─ reattachSearchHighlights() 再放回去

EPUB：写进应用数据目录
  bridge.addHighlight
    └─ EPUBController 注入 JS window.__lumen.highlight(quote)
         └─ 用 <mark class="lumen-hl"> 包裹**引文**（按引文匹配，不按字符偏移 → 抗重排）
              └─ AnnotationStore 落盘到 AppPaths.annotationsFile
```

**EPUB 为什么不写回原文件**：EPUB 是 zip 包，写回会破坏其结构与签名，
别家阅读器可能直接打不开。所以存进应用数据目录，并在界面上如实说明——
「看起来存在书里、其实存在别处」是不能接受的设计。侧栏的批注列表两种格式共用同一套交互。

**PDF 为什么不用 `findString` 定位锚文本**：它是**全书**范围的，要先扫完全书再按页号筛；
更关键的是它只认「文档里就是空格」的位置——实测 `findString("知识\n教师")` 命中 1 处，
而 `findString("知识 教师")` 命中 **0** 处。AI 复述的引文十有八九跨了换行，
于是「添加到批注」会静默退回页面便签。改成页内查找（`page.string` 里定 range →
`page.selection(for: NSRange)`）后，实测查锚耗时 **2637µs → 648µs**（2 页文件上 4×）。

**没锚上就不锚**：`selection(of:on:)` 返回 nil 时退回页面右上角的便签图标。
锚不准的批注比没有批注更糟——它会把一段不相干的话标成高亮，用户看到时已经分辨不出是谁标错了。

### 3.5 一次带 Agent 的 AI 请求

```
AIPanelView 的 agentMenu 选定 AgentConfig（角色 + 勾选的技能 id + 温度覆盖 + 是否联网）
  └─ AIChatModel.submit(..., agent:, skills: AISettings.skillLibrary, webSearchEnabled:)
       ├─ 触发条件两路：agent.usesWebSearch || AISettings.webSearchEnabled（输入框上的手动开关）
       │    └─ WebLiteratureSearch.search(query:)   三源并发，各自最多 3 次尝试 + 指数退避
       │         └─ 任一个失败都不影响其余；失败原因进 Outcome.failures
       ├─ agent.temperatureOverride 只在这里盖掉 config.temperature（改的是副本）
       └─ PromptLibrary.messages(..., agent:, skills:, webContext:)
            ├─ system = 默认系统提示 + agent.promptSection(in: skills)   ← 追加，不是替换
            └─ user   = 材料（抬头 → 原文 → 联网结果）→ 要求 → 模板额外要求
```

**技能库必须一路传下去**：Agent 上只有技能 id，全文在 `AISettings.skillLibrary` 里。
`RequestSnapshot` 连技能库一起记，重跑才会用**当时**那份——不记的话重跑结果会和第一次不一样。
`PromptLibrary.systemPrompt` 里有一道兜底日志：传了 agent 却没传 skills 会打一行
`[Lumen][prompt]`，把「系统提示静默变短」变成看得见的一行。

**技能模型（2026-09-21 二改：全局技能库 + 卡片勾选）**：`AgentSkill` 是
`{id, name, instruction}`；技能存在 `AISettings.skillLibrary`（全局一份），
`AgentConfig.skills` 是 **id 数组**。为什么全局而不是每个 Agent 各存一份：技能是**读法**，
不是某个角色的私产——各存一份的话，用户在 A 里调好的技能切到 B 就没了。
**代价认下**：改一条技能，用它的所有 Agent 一起变（这正是「样式」该有的语义），
不能给某个 Agent 留特例。四条硬约束：

- **内置技能的 id 沿用旧枚举的 rawValue**（`"socratic"` 等）。老配置里 `skills` 存的就是这些字符串，
  第一次出现带全文的对象数组也是同一批 id；**改 id 等于让老用户的技能静默消失**。
- **磁盘上的键仍叫 `skills`**，但内容从「技能」变成「技能 id」。解码按
  `[String]` → `[AgentSkill]` → 旧字段 `customSkills` 逐条试，三条来路都要解得出：
  只认一条就是**静默**丢技能（系统提示变短，界面看不出来）。
- **带全文的旧技能由 `AISettings.migrateCarriedSkills` 并进技能库**，认领规则两条：
  库里已有同 id 就跳过；同名（如老配置里自建的「论证链」，带 UUID）认领到内置那条，
  只改引用、不新增——否则技能库里会出现两张同名卡。并完清掉悬空 id。
  Agent 上的 `carriedSkills` 只是**迁移载体**，`CodingKeys` 里没有它，不会被写回磁盘。
  沿用键名（而不是新开 `skillIDs`）就是为了让绝大多数老配置原样读得出来。
- **渲染统一成 `- 【名称】要求`**，空 requirement 的条目不发出去；
  **「列文献」是否生效按 id 判定**，不看名字——用户给技能改个名不该改变行为。

**预设不再按 id 补回**：`AISettings.init(from:)` 只在磁盘上完全没有 `agents` 键时灌预设；
`skillLibrary` 同一条规则（缺键才灌 14 条内置技能，被清空就保持为空）。
用户删掉的 Agent / 技能都不会下次启动自己长回来（编辑器允许删除任意一个，
内置技能另有「恢复内置技能」入口）。产品层面下线的预设登记在
`AgentConfig.retiredPresetIDs`，读盘时按 id 清掉用户那份旧副本
（只删 `presets` 表而漏登记，用户那边的旧 Agent 会一直活着）。**代价已认下**：
以后新增内置预设不会自动出现在老用户那里。

**「自定义指令」已移除（2026-09-21）**：它与技能最后都拼成同一段系统提示，
分两处只会让用户先猜「我这条该写哪儿」。要写整段要求，就新建一条技能。
`AgentConfig.customInstruction` / `promptSection` 里的对应段落 / 编辑器里的输入框
一并删掉；老配置里残留的这个键由容错解码忽略（未知键不影响解码）。

**Agent 与提示词模板的语义刻意不同**：模板给 `systemPrompt` 时是**整段替换**
（换一种读法），而 Agent 是**追加**——默认提示里的防幻觉、要引用、禁客套话
是阅读场景的地基，换一个角色不该把它们拆掉。角色改变的是「谁在读」，不是「能不能编」。

**联网结果必须排在任务要求之前**：它是「可用的材料」，要先于「拿这些材料做什么」出现；
反过来放，模型容易先形成结论再回头挑材料。这条顺序从终值上看不出来（同一条消息、
同样都含这些字），所以 `--agent-report` 专门为此立了一条断言。

**为什么要能容忍单源失败**：三个源是独立的外部服务，任何一个都可能超时或被限流。
一个源挂掉只让覆盖面变小，不该让整个功能不可用——但失败必须如实报出来，
不能让「查不到文献」变成查不出原因的黑盒。

**重试只修瞬时故障**：最多 3 次尝试 + 指数退避（0.8s → 1.6s，封顶 2.4s），
且只对 429 / 408 / 5xx / 超时 / 断连重试。结构性限流（共享配额池那种）重试也修不了，
那种情况要换源——Semantic Scholar 就是这样被判出局的。

---

### 3.6 侧栏：一条常驻图标栏 + 一块可收起的内容面板

```
LeftRail（常驻 52pt，沉浸时隐）        SidebarColumn（可收起，宽 200…420）
 ├─ 目录      ⌘1                        └─ bridge.sidebarTab 决定显示哪一块
 ├─ 智能目录  ⌘2
 ├─ 搜索      ⌘3
 ├─ 批注      ⌘4
 └─ 页面      ⌘5（仅 PDF）
```

点击**未激活**的图标 → 展开内容面板并切到该页签；点击**已激活**的 → 收起内容面板。
两条分支都走 `AppState.revealSidebar` / `isSidebarVisible`，与 ⌘1–⌘5 和菜单项同源，
所以「切页签时若面板收着就一并展开」这条规则只有一份实现。

**为什么把页签从内容面板顶部搬到常驻图标栏**：选择器原本长在内容面板里，
面板一收起，切页签的入口就跟着消失了——鼠标用户在面板收起状态下
只剩工具栏那一个「把整块面板叫回来」的按钮，而他想做的往往只是换个页签。
图标栏常驻之后，「收起内容面板」不再等于「失去导航」。

选中态只在**面板展开时**点亮：面板收起时没有任何页签处于「正在看」的状态，
给一个高亮等于告诉用户「你现在在目录页」，而他其实什么都没在看。

### 3.7 面板宽度：侧栏固定，只有 AI 面板可调

```
拖动中   PanelResizeHandle → 容器 @State liveAIPanelWidth → .frame(width:)   ← 每帧，不写设置
松手     onCommit(live) → SettingsStore.commitAIPanelWidth(_:maxWidth:)
                        → UISettings.aiPanelWidth 的 didSet（第二道钳制闸）
                        → @Published → 布局刷新
```

**侧栏宽度是常量**（`DS.Size.sidebarIdeal` = 248pt），不参与任何可调宽度：
侧栏那一侧的 `PanelResizeHandle` 已经删掉，界面、设置页都没有改它的入口。
侧栏装的是目录 / 搜索结果 / 批注这类结构化列表，宽度该由版式决定；
用户想给正文腾地方，收起整块侧栏即可（图标栏常驻，导航入口不会消失）。
`settings.ui.sidebarWidth` 与 `SettingsStore.commitSidebarWidth` 保留为
**只写不读**的兼容字段——旧 `settings.json` 里有这个键，删掉字段会让那份配置
整份解码失败。

只有 **AI 面板**可调，宽度只有一个真相源（`settings.ui.aiPanelWidth`），
但拖动期间不再每帧写它。原因：`AppSettings` 是 `@Published` 的整个结构体，
每帧写一次会让所有观察 `SettingsStore` 的视图整棵失效——阅读区
（PDFKit / WKWebView）与 `.regularMaterial` 背景都在其中，表现就是分隔线拖起来抖。
改成「本地状态驱动布局 + 松手提交一次」之后，每帧只影响一条 `.frame(width:)`。

`liveAIPanelWidth` 只在手势期间非 nil，手势结束立刻置回 nil，因此**不是**第二份
真相源：双击复位、自检写入这些外部改动照旧实时生效（这条链路由 `--resize-report` 盯着）。

**上限按窗口宽度动态收窄**（`PanelWidthPolicy`）：窗口只有 920pt 时，
AI 面板拉到静态上限会把正文挤没，所以上限 = 窗口宽 − 图标栏 − 侧栏(固定 248)
− 阅读区保底 320pt。拖拽提交与自检断言共用同一条算式——自检若另写一份，
它验的就是一段死代码。

#### 显示宽度 vs 落库宽度：窗口变窄时谁让

上面那条上限**只在拖拽提交那一刻**参与是不够的：窗口被拉小时没有任何一次提交，
落库的旧宽度会原样参与布局。实测 920pt 窗口下阅读区只剩 266pt，再窄一点
图标栏被推到 `x = −97`——切页签的入口直接跑到屏幕外（QA 复现，非构造输入）。

所以钳制再分两层：

```
落库宽度（settings.ui.aiPanelWidth）  ← 只有用户主动拖 / 双击 / 设置页才会变
        │
        ▼ 每次布局都重算（PanelWidthPolicy.resolve，纯函数，不写设置）
显示宽度（panelLayout.*）
        │
        ▼
   .frame(width:)
```

预算的分配顺序：`预算 = 容器宽 − 图标栏 − 侧栏(248 基准) − 分隔线`；
`可用 = 预算 − 阅读区保底`。图标栏、侧栏和 AI 偏好宽度先统一乘以
`windowScale = clamp(windowWidth / 1320, 1, 1.22)`；设置只保存未缩放的基准值，避免在
外接屏和内屏间切换时把显示宽度反复写回、越变越大。

1. AI 面板需求装得进「可用」→ 按需求给；
2. 装不进 → AI 面板足额拿（但不低于自己的下限 300pt），阅读区吸收差额；
3. 阅读区被压到保底（320pt）以下（容器不够宽）→ AI 面板顶住自己的下限
   （300pt），阅读区让位（**降级**，文档里写明）；
4. 最后一道闸：两侧之和不得超过预算。宁可 AI 面板比下限还窄，也不让图标栏
   被顶出屏幕——面板窄是难用，入口消失是不能用。

AI 面板的最小宽度由 `UISettings.PanelWidth.aiRange.lowerBound`（= 300）统一限定：
界面拖拽、`--panel-width` 自检写入、设置解码三条路径过同一道闸。

---

### 3.8 重新生成：换配置重跑同一段内容

```
submit(...)  → 存一份 RequestSnapshot（task / selection / context / config / template /
               agent / webSearchEnabled …足以原样重跑）
rerunLast()  → 从 history 摘掉上一轮那一对 → 用一条新气泡替换旧的 → 同一条 startAnswer
```

三条刻意的取舍：

1. **替换而不是追加**。追加会让气泡序列变成「问、答、答」，而 `finishStreaming`
   是按「最后一个 user + 最后一个 assistant」配对的，两条答会各自和同一个问配成一对。
2. **重跑前先摘掉 history 里那一对**，成功后由 `finishStreaming` 补回来。
   净效果是一对换一对，「只收完整对子」的规则没有被打破——
   否则下一轮模型会看到一个已经被回答过的旧问题，表现正是「答非所问」。
3. 走 `submit` 里同一条 `startAnswer`，所以联网检索、进度文案、可中止（stop）
   与首次请求完全一致。

`summarizeDocument`（总结全文）**不产生快照**：它要么一次问完、要么先逐片 map
再 reduce，重跑时若走 `startAnswer` 会退化成「把上一次的摘要再总结一遍」。
所以那里主动把 `lastRequest` 清掉，界面上也不给这个入口——
给一个点了会给出错误结果的按钮，比不给更糟。

### 3.9 布局探针的生命周期：视图消失必须注销

`layoutProbe("名字")` 把一个 `name → frame` 的字典交给 `LayoutAuditLog`，
`--layout-report 1` / `--resize-report 1` 时统一 dump，供
`tools/layout_assert.py` 做几何断言。

```
onAppear / onChange(frame)  → LayoutAuditLog.record(name, frame)
onDisappear                 → LayoutAuditLog.remove(name)     ← 缺这一句就是「幽灵探针」
```

**为什么必须注销**：探针字典是「当前在版面上」的快照，而不是「历史上出现过」的日志。
少一步注销，视图从版面摘下（收起 AI 面板、切换 PDF/EPUB）后仍会保留最后一帧——
实测收起 AI 面板后仍上报 `aiPanel x=1094.6 w=336.4 maxX=1431.0`，
而窗口内容区宽度只有 1421，maxX 已越界。连带后果是 `layout_assert.py` 里
「收起的面板必须是探针消失」这条规则验的是**死数据**：它读到的永远是那一帧旧值，
恒真、从不报错。

所以「视图消失 → `LayoutAuditLog.frame(named:)` 返回 nil」是这条链路的契约：
调用方把 nil 当成「这一栏不在版面上」，而不是「读到 0 宽还在占位」。
可证伪：注释掉 `onDisappear` 后重跑 `--run-action toggleAIPanel --layout-report 1`，
dump 里立刻重新出现那帧越界的 `aiPanel`。

### 3.10 窗口与标签：一个窗口多份文档，标签可拆成独立窗口

**窗口由 AppKit 显式创建，不走 SwiftUI `WindowGroup`。** 原因很硬：
`WindowGroup` 对外部文件打开事件的默认处理就是「每份文件开一个新窗口」，
而且没有公开 API 把它改成「进当前窗口的新标签」。改造后 SwiftUI 只保留
`Settings` 一个场景；阅读器窗口是 `NSWindow` + `NSHostingController(RootView)`，
由 `WindowManager` 统一生灭，并把系统原生窗口标签化关掉
（`tabbingMode = .disallowed`，否则窗口菜单会冒出与自定义标签冲突的项）。

状态按三层切开：

```
进程级（AppServices，单例）  设置 / 最近打开 / 快捷键 / 记忆
窗口级（AppState，每窗口一份）标签集合、当前标签、面板显隐、沉浸、alert/toast、命令面板
文档级（ReaderSession，每标签一份） OpenDocument / ReaderBridge / AIChatModel
                              / SmartOutlineModel / 元数据 / pendingAIRequest / busy
```

`AppState` 保留了 `document` / `bridge` / `chat` / `smartOutline` / `busy`
等同名计算属性，一律解析到当前标签的会话——菜单栏、命令面板、浮层这些窗口级
代码因此不用知道标签的存在，60 多个调用点原样工作。

**标签内容保活**：已访问过的标签在 `ZStack` 里叠放，非当前标签
`opacity(0) + allowsHitTesting(false)`，不销毁。切回标签不重新解析 PDF /
重载 WebView，滚动位置、划词、流式回答都还在；代价是后台标签占内存，
标签关闭时视图走 `onDisappear`（阅读进度在这里落盘）。

**当前标签指针必须自洽**。`activeSessionID` 是视图层判断显隐 / 透明度的依据；
标签被关闭或拆走后，若只更新 `activeSession` 而不校正 id，剩下的标签会永远
停在 `opacity(0)`——界面只剩标签栏、正文一片空白。`syncActiveSession()`
负责把失效 id 校正到邻接标签（优先右侧），这是这类「叠层标签」最容易踩的坑。

**「在独立窗口打开」是会话整体迁移**：`WindowManager.detach` 把
`ReaderSession` 从原工作区摘走、交给新窗口的新工作区。对话、智能目录跟着走；
但 PDFView / WKWebView 由 SwiftUI 持有、无法跨窗口搬运，新窗口会重新解析文档，
阅读位置由 `ReadingStateStore` 落盘后自动恢复（实测可恢复到原页 / 原章）。

**外部打开去重**：同一路径已经在任意窗口打开时，不重复开第二份，
直接切到那个标签并把窗口置前。

工具栏上两块面板的开关是对称的一对：左侧 `sidebar.leading`、右侧
`sidebar.trailing`，都始终存在（无文档时禁用）。AI 面板头部不再放第二个
收起按钮——同一个动作在窗口右侧留两个相距不到 30pt 的入口是重复设计。

### 3.11 AI 会话：全局共享一份

**形态**：`ConversationStore` 挂在 `AppServices`（进程级单例），落盘
`conversations.json`。AI 面板头部（Agent 菜单右侧）有一枚会话菜单：
新建 / 切换 / 重命名 / 删除。`ReaderSession` **不再持有 chat**——
`AppState.chat` 与面板里的 `@EnvironmentObject chat` 都指向同一个
`services.activeChat`。

代价如实地写在这里：**所有标签显示同一条活动会话**，切换标签不换会话内容，
在一个标签里新建会话时别的标签面板也会跟着切。用户明确选了这套
（「全局共享」），换来的是不必先打开某本书就能翻历史对话。
正确的代价要靠下面两条守住，否则就是「看着能用、答案是错的」：

1. **逐条气泡记 `sourceDocPath`**（这次提问来自哪本书）。只有记到气泡上，
   「这条回答的引用是不是指向当前这本书」才判得准——一次会话里可能从不同的
   书问过。
2. **跨文档引用降级**：`ConversationCitationPolicy.isActive(...)` 为假时引用按钮
   置灰 + `help` 写明原因（「此引用来自《书名》，切到那本书才能跳转」/「来源未知」）。
   任一路径为 nil 一律判**不可跳**（fail safe）。不做这一步的话，点一下会跳到
   当前书里一个毫无关系的位置——那是事实性错误。

**默认标题 = 发起文档的标题；同一文档的第 2 个及以后会话加序号**（`2. 书名`）。
序号**不占字段**：从同文档已有会话的 `title` 里现算（`ConversationStore.sequence(in:base:)`
按 `base` 后缀精确比对，所以书名本身叫「1. 引言」也不会误判），推进用
「已用过的最大序号 + 1」，删掉中间某条之后新建的不会退回占一个活着的号。
这样落盘格式与逐字段容错解码都不必动。手动重命名（`customTitle`）优先级最高，
且不影响其它会话的序号。

**旧数据一次性迁移**：`chats.json` 反推不出文档路径（FNV-1a 是单向的），
但 `recent.json` 里存着绝对路径——用同一个 `stableHash` 反算就能查回来
（本机实测 12 份里救回 7 份，另外 5 份的来源如实降级为「未知」）。
迁移只在 `conversations.json` 尚不存在时跑一次；**导入成功后把源文件改名为
`chats.json.migrated-<时间戳>` 而不是删掉**，改名失败就这次不导入、下次重试。

**划词请求仍按标签隔离**：`pendingAIRequest` 留在 `ReaderSession`，
由**该标签**的面板消费。显示是共享的，路由不是。

### 3.12 面板显隐：一次过渡 = 一整段「调整中」

展开 / 收起面板时 PDF 会屏闪，根因是动画期间 `PDFView` 宽度**每帧都在变**，
而 `autoScales == true` 会让 PDFKit 每帧重算适宽倍率、丢掉并重栅格化整页瓦片
（页数越多越明显）。拖动分隔线那条路早就躲开了这个坑——`setPanelResizing(true)`
把 `autoScales` 钉住并记下滚动锚点，动完再恢复并补偿位置。

所以面板可见性的**全部 7 个写入点**（工具栏两个按钮、⌘⌥1/⌘⌥2 两个动作、
`revealSidebar`、图标栏点击、命令面板、沉浸模式进出）都收敛到
`AppState` 上的 `setSidebarVisible(_:)` / `setAIPanelVisible(_:)` 等方法，
由它们负责「先通知阅读视图进入调整中 → 改状态 → 等动画走完再退出」。
**通知必须发在改状态之前**：放在 `onChange` 里补通知时状态已经变了、
动画已经跑过一帧，锚点已经漂了。

收尾用 `withAnimation(...) { ... } completion:`（macOS 14+）拿真实完成回调，
不用固定延时猜动画时长。自检通道 `--panel-transition-report`。

---

## 4. 存储布局

`~/Library/Application Support/com.jn.lumen/`

```
settings.json        全部设置（逐字段容错解码）
recent.json          最近打开
memory.json          跨会话记忆
conversations.json   全局共享的 AI 会话列表（见 3.11；**不再按书分**）
keybindings.json     快捷键改绑的**差量**（未改过的动作走默认值，
                     这样以后新增动作时老用户的配置不需要迁移）
docs/<路径哈希>/
  state.json         阅读进度与位置
  chats.json         **旧版**的这本书的 AI 对话：现在只在首次启动时被子一次性迁移，
                     导入后原地改名为 chats.json.migrated-<时间戳>（不删原文件）
  smart-outline.json 这本书的智能目录（含已生成的摘要）
  annotations.json   **EPUB** 的批注（PDF 的批注写在 PDF 文件自己里面，不走这里）
```

`~/Library/Caches/com.jn.lumen/` 放 EPUB 解包结果——**可随时安全删除**，丢了会重新解包。

路径哈希用 FNV-1a 64 位（`AppPaths.stableHash`）：稳定、跨进程一致、不需要 CryptoKit。

**API Key 不在设置 JSON 中**。通过 `AICredentialStore` 写入 `credentials/`，目录 0700、文件 0600，原子替换。`AIProviderConfig.keychainAccount` 仅保留为兼容账户标识，不再调用 Keychain。文件未加密。

---

## 5. 关键决策记录

| 决策 | 理由 |
| --- | --- |
| 用 `HStack` + 自绘分隔线，不用 `NavigationSplitView` | 要同时控制三栏宽度、出现动画、分隔线颜色。`NavigationSplitView` 会强加系统材质与自带侧栏开关，反而更难收敛视觉 |
| 面板宽度存进设置而不是本地 `@State` | 宽度的唯一真相源就该是配置（它要持久化）。留两份的话，设置页改了宽度、或双击复位，两边就会不同步。**例外**：拖动期间由容器的一份本地 `liveWidth` 驱动布局，松手才提交——每帧写设置会让整棵视图树逐帧失效（见 3.7）。它只在手势期间有效，不是第二份真相源 |
| 拖动分隔线期间不加动画、不写设置 | 加动画会让分隔线「追」鼠标；每帧写设置会让所有观察 `SettingsStore` 的视图（含 PDFKit / WKWebView / 材质背景）逐帧失效，表现为抖动。用增量（起点宽度 + delta）计算 |
| 面板上限按窗口宽度动态收窄 | 920pt 的最小窗口下两侧面板都拉到静态上限会把正文挤没。上限 = 窗口宽 − 图标栏 − 其它面板 − 阅读区保底 320pt |
| 页签入口放常驻图标栏，内容面板可收起 | 选择器长在内容面板顶部时，面板一收起切页签的入口就消失了。图标栏常驻后「收起面板」不再等于「失去导航」，⌘1–⌘5 与图标栏共用 `revealSidebar` 一条实现 |
| 沉浸模式用两个 `Spacer` 而不是给阅读区加 padding | padding 得先知道窗口宽度才能算居中的边距，要套 `GeometryReader`；两个 Spacer 让 `HStack` 自己平分剩余空间，天然居中且宽度变化有动画 |
| 沉浸模式退出时恢复**进入前**的面板可见性 | 「进入时全关、退出时全开」会把本来关着 AI 面板的用户的面板打开——他从没要求过 |
| 缩略图用串行队列 + 可视区判定 | 滚动时数百页渲染任务排队是卡顿的根因。串行 + `VisibleTracker`（`NSLock` 保护）跳过不可见页 |
| 智能目录的「摘要」与「展开」是两个控件 | 「摘要」明摆着要花钱，「展开」是免费的本地操作。把付费动作藏在「展开」里，用户点着点着账单就上去了 |
| 付费动作不给快捷键 | 「生成智能目录」是菜单项但没有快捷键。一次误触的代价是一次真实的模型调用 |
| 全文抽取的两个字符门槛故意不同 | `usableText` 用 24 字符门槛（AI 上下文宁可这页什么都不给，也好过把页码当正文）；「复制全文」默认只要非空就采用（少一格正文比多一个页码严重得多） |
| 菜单项是快捷键生效的前提 | SwiftUI 的 `.keyboardShortcut` 只在菜单项上才全局响应。只在命令面板里有、没有菜单项的动作，用户改了绑定也按不出效果——那属于骗人 |
| 侧栏页签顺序即快捷键编号，新页签**插在中间并顺延**后面的 | 不把「批注」塞到 ⌘5 去保 `⌘4 = 页面` 的旧映射：编号跟着界面顺序走，用户按一次就能建立映射；乱序编号要求他先记住哪一号对应哪一个。这次是 ⌘4 从「页面」变成「批注」——属于**对用户的可见变更**，已在交付说明里标明 |
| PDF 批注写回原文件，EPUB 批注存应用数据目录 | PDFKit 能原子写回且别的阅读器都认；EPUB 是 zip，写回会破坏结构与签名。差异在界面上如实写明，不假装一致 |
| 搜索高亮用**临时** annotation，写盘前先摘除 | 搜索痕迹固化进用户的书是不可逆的污染。数不等于零就是 bug，自检专门盯这一条 |
| 批注类型判断统一走 `lumenTypeName`（去斜杠） | `PDFAnnotationSubtype.highlight.rawValue == "/Highlight"` 带斜杠，而 `annotation.type` 返回 `"Highlight"` 不带——直接比较恒为假。同一个坑还带来第二个错误：`Text` 便签会自动带一个 `Popup` 影子批注，不排除它计数会虚高一倍 |
| 联网检索源要能**被实测淘汰** | Semantic Scholar 在实现完成后被判出局：不带 key 时走共享配额池，本机连测两次都 429，默认配置下它只贡献一个错误。换成 OpenAlex 后命中 8→12 条、失败源 1→0、耗时 4478→3273ms。**重试修不了结构性限流**——那种情况要换源，不是加重试 |
| 配置里预设的 id 写成固定 UUID 字面量 | 用 `UUID()` 会让每次求值得到新 id，「配置里没有 agents 时退回预设」这条路径每轮 id 都不同，用户选中的 Agent 静默丢失 |
| 技能存在**全局技能库**里（`AISettings.skillLibrary`），Agent 只存 id 数组 | 技能是读法，不是某个角色的私产：各存一份的话，用户在 A 里调好的技能切到 B 就没了，只能重写一遍。代价认下——改一条技能，用它的所有 Agent 一起变，不能留特例。磁盘上的键仍叫 `skills`（老配置就是这个键），所以绝大多数老配置原样读得出来 |
| 迁移载体 `carriedSkills` 不进 `CodingKeys` | 它只用来把旧格式的**技能全文**从 Agent 上捎进技能库。写回磁盘就等于全文又存回 Agent 身上，技能库不再是一份来源，两条真相迟早分叉 |
| 旧技能并库时**同名认领**（不只是同 id） | 老配置里「论证链」「术语变化」是用户自建技能（各自带 UUID），而它们现在是内置技能。只按 id 判会新增一条，用户在技能库里看到两张同名卡；只按名字判又会把用户自己写的技能丢掉，所以两条一起用 |
| 「自定义指令」删除而不是保留 | 与技能最后都拼成同一段系统提示，分两处只会让用户先猜「我这条该写哪儿」。要写整段要求就新建一条技能。老配置里残留的键由容错解码忽略 |
| 预设不再按 id 补回，改由 `retiredPresetIDs` 清理下线项 | 「缺哪个预设就补哪个」与「允许删除任意 Agent」并存，会让用户删掉的 Agent 下次启动自己长回来。代价认下：以后新增内置预设不会自动出现在老用户那里。下线清理必须单独登记——只删 `presets` 表，用户磁盘上的旧副本会一直活着 |
| 「列文献」按 id 判定是否发出去，不看名字 | 没开联网时它引用的「检索结果」根本不存在，发出去只会让模型自己编。判定绑名字的话，用户给技能改个名会莫名其妙地改变行为 |
| 重新生成**替换**旧回答而不是追加 | 追加会让气泡变成「问、答、答」，而 history 是按「最后一个 user + 最后一个 assistant」配对的，两条答会各自配成一对——下一轮模型看到一个已经答过的旧问题，表现就是答非所问 |
| 重跑前先从 history 摘掉那一对 | 重跑成功后 `finishStreaming` 会补回来，净效果是一对换一对，「只收完整对子」的规则没被打破 |
| 总结全文不提供「重新生成」 | 它走 map-reduce，重跑会退化成「把上一次的摘要再总结一遍」。给一个点了会给出错误结果的按钮，比不给更糟 |
| 付费动作（含重新生成）不给快捷键 | 一次误触的代价是一次真实的模型调用。它只在菜单项与气泡 footer 里 |
| 联网检索有两路触发条件 | `agent.usesWebSearch`（这个角色定位上就要查，跟着 Agent 走）与输入框上的 `webSearchEnabled`（我这一次想查，不改任何 Agent）。合二为一的话，临时查一次就得去改 Agent 配置，改完往往忘了改回来 |
| 窗口变窄时**只压显示宽度，不动落库值** | 覆写式钳制（窗口一变就把钳制值写回落库）会让用户把窗口拉回去之后宽度永远丢了。落库值只由拖拽 / 双击 / 设置页改动，显示宽度每次布局重算 |
| 面板让位时钉住一侧，而不是两侧等比压缩 | 等比压缩会让「写入 X → 渲染 X」在窄窗口下失效（写 266 只渲染 225），拖到底松手反而更窄。钉住一侧是**不动点**——结果再喂回算式还是同一组值，这是「拖完不弹回」的保证 |
| 图标栏的 x 永远 ≥ 0 | 面板可以窄到难用，切页签的入口不能消失。容器窄到 534pt 以下时（界面到不了）宁可把面板压过下限也要保住它 |
| 联网失败如实上报 + 只重试瞬时故障 | 结构性限流（共享配额池）重试修不了，那种要换源；但「哪个源挂了」必须能让用户在日志里看到，否则「查不到文献」就是个黑盒 |
| 面板宽度只保留拖拽一个入口 | 设置页里再放一份就是同一个值两个入口，改了一个另一个不跟着变——「看起来能用其实不同步」的经典来源 |
| **侧栏宽度固定为常量，只有 AI 面板可调** | 用户明确要求「只限定右侧面板的最小宽度」。侧栏装的是结构化列表，宽度该由版式定；`settings.ui.sidebarWidth` 保留为只写不读的兼容字段（旧配置里有这个键） |
| **布局探针必须在 `onDisappear` 注销自己** | 探针是「当前在版面上」的快照，不是历史日志。不注销就会留下已收起面板的最后一帧（maxX 越界），让「收起的面板必须是探针消失」这条断言验死数据、恒真 |
| **划词条只在拖动划选时出现**（`bridge.selectionFromDrag`） | 单击也会产生 1 字符选区，随手点一下正文就弹浮条属于噪声。PDF 按鼠标按下点与松开点的距离（< 4pt = 单击）判定，EPUB 在 JS 里判同一距离；键盘 / 触摸选择视为有意为之，放行 |
| **右键菜单在系统菜单上追加，不替换** | 命中批注时整份替换会丢掉系统自带的「拷贝 / 查找 / 缩放」。现在一律 `super.menu(for:)` + 追加，OCR 入口无条件加、排在末尾 |
| **右键菜单的判定抽成纯函数**（`PDFContextMenuPlanner.items`） | 右键菜单无法自动化（无辅助功能权限），把「该出现哪些项 / 叫什么文案 / 该不该禁用」抽成纯函数，用表驱动断言验它，视图层只做翻译 |
| **快捷键记录物理键，不记输入法产物** | 录制器拿的是 `charactersIgnoringModifiers`，中文输入法下按 `]` 会得到全角 `】`（U+3011），存进去物理上按不出来——用户「AI 面板快捷键不生效」的根因。录制时全角→半角归一化并拒绝非可键入字符；载入时对旧的坏绑定做一次性迁移 |
| **不可键入的绑定载入时丢弃并回落默认，且打日志** | 静默丢弃会让用户以为是自己改错了却找不到原因。丢弃 / 迁移都要 `NSLog` 说明是哪一个动作 |
| **阅读器窗口用 AppKit 显式创建，不用 `WindowGroup`** | 用户要求「默认一个窗口多标签」，而 `WindowGroup` 对外部打开事件只会开新窗口、且无公开 API 改成进标签。显式 `NSWindow` + `NSHostingController` 后，`application(_:open:)` 统一路由到 `WindowManager`，行为才完全可控；SwiftUI 只留设置场景 |
| **文档级状态抽成 `ReaderSession`，窗口级状态留在 `AppState`** | 多标签的隔离单位是文档：bridge/chat/智能目录必须各走各的，否则后台标签会串对话；而面板显隐、沉浸、命令面板是窗口的事。`AppState` 用同名计算属性代理到当前标签，旧调用点零改动 |
| **标签用 ZStack 保活，而不是切走就销毁** | 重新解析 PDF / 重建 WebView 既慢又丢状态（滚动、划词、流式回答）。叠层隐藏的代价只是内存，且未访问过的标签仍懒挂载、关闭即 `onDisappear` 落盘 |
| **右键菜单提供「在独立窗口打开」，默认不开新窗口** | 多标签是默认形态；独立窗口是用户显式表达「我要并排看两本」时的例外。迁移的单位是整个会话，PDFView 不能跨窗口搬运，位置靠阅读进度存储恢复 |
| **AI 面板开关只留工具栏最右一枚（`sidebar.trailing`）** | 与左侧栏开关对称、始终在固定位置；面板头部再放一枚收起按钮，等于同一动作在窗口右侧留两个入口 |
| **入口归属抽成单一真相源（`ActionEntries`），菜单从它 `ForEach` 长出** | 「导出摘要」曾同时出现在顶栏复制菜单、AI 面板 ⋯ 菜单与菜单栏「文件 > 导出」。这类重复**读代码几乎发现不了**：三处各自看起来都对，只有把三处摊在一起才知道同一动作写了三遍。抽成纯数据后，改一处即为改三处，`--entry-report` 再断言这份数据的性质。**边界**：它断言的是数据的性质，看不见视图里手写的重复入口——唯一性仍要靠 `grep` 触发点 |
| **导出类动作收敛到菜单栏「文件 > 导出」唯一物理入口** | 按**产物去向**划界：剪贴板→顶栏复制菜单、对话区→AI 面板、磁盘文件→文件菜单。复制按钮里塞导出是语义错位（按钮说「复制」却产出文件），⋯ 菜单再放一份则是重复。代价：导出不再能从 AI 面板就近触发，必须去文件菜单——这是刻意的取舍 |
| **复制类保留菜单栏落点（编辑 / 文件菜单），不做唯一化** | 「菜单项是快捷键生效的前提」：删掉菜单项会连带废掉 ⇧⌘C。所以复制类走「顶栏按钮是就近入口、菜单栏是权威层与快捷键载体」，与导出类的唯一化不同。诚实地说，「每个功能只有一处入口」只对导出类成立 |
| **降饱和时保留色相、只压饱和度与提明度** | 诉求是「降低长时间阅读的视觉刺激」，不是「去掉暖意」。压饱和度（×0.60）+ 提明度（+2%）、色相不动，暖调才留得住；同时核算 WCAG 对比度（正文 10.2:1）以免把「柔和」做成「看不清」 |
| **只在自检里生效的启动覆盖必须计入 `isAuditRun`** | `--reading-theme` / `--epub-columns` / `--pdf-original` 是「把阅读状态钉死供取证」的开关。不计入的话，单独传它们时 `WindowManager` 那扇 `if isAuditRun` 的门不开，覆盖**根本不生效**——看起来能单独用的开关实际是哑的，属于「以为设置了、其实没设置」 |
| **面板显隐只有 `AppState` 上的方法一个入口** | 7 个写入点各写各的 `withAnimation { isXxx.toggle() }` 时，屏闪修复（进入/退出「调整中」）必须在 7 处各补一遍，漏一处就是「这块面板还闪」。收敛成方法后「通知 → 改状态 → 等动画完成」只写一次，也才可能被一条断言覆盖 |
| **会话管理条目单列一个入口组（`headerSessionMenu`），不进 `⋯` 菜单** | `⋯` 菜单原先同时渲染了新建/重命名/删除会话，头部会话菜单也渲染一份——**两处都能改同一个状态**，而 `--entry-report` 当时是绿的：它只断言「类别归属的组集合」，查不出「同一动作被两个菜单各渲染一遍」。已拆组并把断言改成精确相等 + 新增「`⋯` 菜单不得含会话项」 |
| **会话标题的序号不额外占字段** | 加字段要连带改落盘格式与容错解码，收益只是一个能现算的整数。改成从 `title` 字符串按 `base` 后缀精确解析（`ConversationStore.sequence(in:base:)`），并专门断言「书名本身叫『1. 引言』时不得误判成序号」——**没有那条断言的字符串解析方案是不可信的** |
| **批注整行化用「整页宽窄带 + 三条守卫」，不用 `selectionForLine(at:)`** | `selectionForLine` 在两栏版面上左栏点与右栏点返回**一模一样**的 bounds（它是按水平带取行、不分栏）；`page.selection(for:)` 也一样——实测把页面按中线劈成两半各探一次，缝宽**恒为 0.0**（它返回的是与矩形相交的整行，横向边界基本被忽略）。按字形逐个走（`characterBounds`）在中文 PDF 上不可靠（字形顺序≠阅读顺序，实测会漏扩或把上一行的字带进来）。最终用整页宽带取整行，再加三条守卫（竖直重叠足够、行高不超片段 1.8 倍、整行必须包住原片段），任一不成立就**保留原样**而不是扩错 |
| **同页多条便签的批注 id 必须消歧** | `entryID` 是「页号 + 原点 + 类型」，注释里断言「同页同原点同类型的两条不存在」——但便签图标固定放在 `(width-44, height-44)`，**同页第二条就撞车**。而列表是 `ForEach(items)`，SwiftUI 撞上重复 id 的行为未定义（实践中会出现卡住/错乱，用户报的「新建批注卡死」很可能就是它）。修法是落点按 30pt 错开 + 同基串追加 `#k`，并让列表/删除/更新/定位**共用同一个枚举源**（分家就会「点删除删错条」） |
| **保存 PDF 的序列化留在主线程** | 实测 `dataRepresentation()` + 原子写：2 页 3ms / 120 页 61ms / 600 页 **540ms**，全部发生在主线程（`PDFOriginalRendering.data(of:)` 是同步的）。搬去后台的障碍是：它靠 **ThreadLocal** 标记「这是序列化路径、别涂主题色」，即 `dataRepresentation()` 会**逐页 draw**，与屏幕 tile 线程并发访问同一个 `PDFDocument`，而 PDFKit 的线程安全没有文档保证；改为「主线程取快照、后台写字节」也解决不了——耗时几乎全在序列化（1MB 文件写盘只占几毫秒）。本轮**没有**改，如实留在这里 |
| **自检里的「文件没被改写」基准必须跨动作取** | 第一版写成 `settingsMD5()` 连调两次再比较——两次之间什么都没发生，永远相等，是一条**恒真断言**（硬约束第 8 条）。现在基准取在自检开始处、末尾比对，并同时盯**用户真实目录**（`AppPaths.realSupportRoot`）：自检模式下 `supportRoot` 已被重定向到临时目录，只盯它等于只证明了「临时目录没被改」 |

---

## 6. 已知的边界

- **辅助功能权限未授予**，所以拖拽手势、键盘模拟无法程序化验证。面板宽度这类
  依赖拖拽的功能，验证走的是「直接写设置项」的等效路径。
- **窗口窄到 534pt 以下时阅读区保底 320pt 会失效**（两侧面板让到各自下限，
  正文被压）。这是刻意的降级：面板窄到 150pt 时目录树与输入框都会开始裁字，
  而正文被压只是行长变短。而且这条路径**界面上到不了**——应用声明了
  920pt 的最小窗口宽度，实测脚本把窗口设成 700pt 也会被 SwiftUI 拉回 920，
  所以只有算式层断言（`--resize-report` 第 ⑩ 条）在守着它。
- **助手没有视觉通道**，所有「看起来对不对」的问题都要转成可断言的信号。
  详见 `docs/VERIFY.md`。
- **原生右键菜单无法自动化验证**（无辅助功能权限，合成不出真实右键事件，
  截图也拍不到原生菜单）。OCR 菜单项走的是「纯函数 + 表驱动断言」
  （`--ocr-menu-report 1`），验的是「该出现哪些项、叫什么文案」，
  但「菜单真的弹出来、点下去真的触发」这一段没有被程序化验证过。
- **EPUB 划词门未降级为「文本长度 ≥ 2」**：JS 侧已能记录 mousedown→mouseup
  距离（与 PDF 同一套 4px 阈值），所以走的是真实手势门，不是长度退化。
  但 EPUB 走 WebKit，阅读容器出现比 PDF 晚，自检要留 `--capture-delay 8`。
- OCR 走纯 Vision 框架，没有引入第三方识别库；扫描件的识别质量取决于源图质量。
- **标签右键菜单与菜单条目没有逐条做 GUI 自动化**（无辅助功能权限）。
  窗口路由、多标签、拆独立窗口走的是真实 LaunchServices 打开事件 +
  `--detach-after` 自检通道（截图验证：两份文件进同一窗口、拆出后两个窗口
  各自正确渲染、会话状态随标签迁移）；右键菜单本身的弹出与点击未程序化验证。
- **后台保活标签占内存**：每份打开过的文档的 PDFView / WebView 都留在叠层里。
  关闭标签即释放；目前没有「超过 N 个标签自动卸载后台标签」的策略。
- **批注整行化在「分栏版面」上没有被验证过**：`selectionForLine` / `selection(for:)`
  都不分栏（见 §5 对应决策），所以整页宽窄带在两栏 PDF 上可能把相邻栏一起框进来。
  判断版面的正确办法是把页渲染成位图、按列统计墨迹密度找栏沟；用这个办法测了
  本机库里的文档，**全都是单栏**（中央 30% 区域密度 64~84，峰值 170~240，剖面均匀，
  没有接近 0 的竖带），所以**本机拿不到可验证的双栏样本**。
  按项目铁律「没法验的功能等于没做完」，**没有**发明一个验不了的分栏检测器。
  将来遇到真的双栏 PDF，这里是第一个要找补的地方。
- **「新建批注卡死」没有被确定性复现**：能测到的是 `saveToFile` 在主线程上的
  耗时随页数增长（600 页 ≈ 540ms，见 §5），能推断的是同页便签 id 撞车会让
  `ForEach` 踩未定义行为，两者都已处理（前者如实记录未改，后者修掉并有断言）。
  但**没有**一次可重复的复现路径，所以这条只能算「最可能的机制已消除」。
- **`saveToFile` 仍在主线程上同步做整份序列化 —— 这是本轮明确记录、刻意未改的一处。**
  把耗时拆开量过之后，「挪到后台队列」这个直觉是**错的**：

  | 文档 | `dataRepresentation()` | 原子写 `write(to:options:.atomic)` |
  | --- | --- | --- |
  | 2 页 / 51 KB | 3 ms | 1 ms |
  | 120 页 / 263 KB | 61 ms | 1 ms |
  | 600 页 / 961 KB | **539 ms** | **2 ms** |

  耗时 **99.6% 在序列化**，写盘只占 2ms——**只把写盘移出主线程等于什么都没做**，
  必须把 `dataRepresentation()` 本身挪走。而它挪不动，因为被两件事绑在一起：

  1. **搜索临时高亮必须在序列化期间保持「已摘除」状态。** `detachSearchHighlights()`
     改的是 `PDFDocument` 上**共享的** `page.annotations`，与主线程正在绘制的同一份对象。
     今天这个窗口是 540ms 但主线程冻着、所以看不见；一旦挪到后台，这 540ms 里
     搜索高亮会**在屏幕上闪烁消失再出现**——把「不可见的卡顿」换成「可见的闪动」，
     不是改进。唯一干净的做法是「序列化时用的是一份不共享的快照」，那是所有权设计问题，
     不是队列问题。
  2. **`PDFOriginalRendering` 靠 `ThreadLocal` 标记序列化路径**（不许涂主题色）。
     它本身跨线程是安全的（每个线程各有一份标记），但前提是**整段序列化发生在同一个后台线程内**，
     不能拆成两步跨线程。

  所以这一条留到独立的一轮做，起点是上面这两条约束，而不是「加个 DispatchQueue」。
  取值提醒：用户手上的书在 396~661 页区间，即**每存一次批注界面僵约 0.35~0.6 秒**。
- **`/tmp/lumen-*` 下有若干验证用临时副本**（真实数据目录的快照），
  跑自检时用 `LUMEN_TEST_DATA` 指过去。它们不是应用的一部分，可随时删除。


## 2026-09-20 滚动与生命周期维护

- `ReadingPDFDocumentDelegate.classForPage` 提供 `ReadingPDFPage`，在 PDFKit 原生 tile 的 `draw(with:to:)` 内先调用 super，再用 Core Graphics 着色。结果由 PDFKit 缓存，滚动本身不做整屏着色。`PDFReadingToneState` 用锁传递不可变通道快照，后台不读 SwiftUI 状态；`ReadingToneChannel` 负责黑白端点和中间色。保留原生选择、搜索、批注、触控板惯性和分辨率。
- 不再向 `PDFView.documentView.contentFilters` 写 Core Image，也不使用 SwiftUI 整屏 blend/compositingGroup。缩略图由独立文档串行绘制后一次着色，缓存成品位图；主题/文档/批注版本变更使旧请求失效，渲染前先检查版本和可见性。
- 主题切换时重新绑定同一 PDFDocument 清除原生 tile 缓存，保留页码、选区、倍率与精确滚动坐标；等 PDFKit 初始布局完成后恢复坐标。画布亮度变化不重建 tile。
- 自定义 PDFPage 绘制也会进入序列化。`PDFOriginalRendering.data(of:)` 只在当前同步保存线程抑制色调，不改共享主题，避免同时渲染的页面闪成原色。OCR 显式调用 `drawOriginal`。写盘前仍移除搜索临时高亮，原子保存后恢复。颜色与文字回归以原生 PDFKit 序列化结果为对照（原生保存也可能规范化空白）。
- `PDFViewportState.isTracking` 由缩略图面板的生命周期开关；面板隐藏时不调度每帧可视矩形计算。首次显示重新获取位置。高频几何仍不经过 ReaderBridge 的全局状态发布。
- `ReaderSession.close()` 集中停止完整文本任务、AI 流式输出、智能目录与逐段摘要，调用 `bridge.closeReader` 保存位置并停止 EPUB 翻译/WebKit 载入，然后清空桥接闭包。关闭窗口、关闭其他标签走同一入口；`withdraw` 仅迁移会话，不销毁它。
- AI 绑定只在创建 ReaderSession 时进行。阅读视图再次挂载不重读对话、不清空草稿。
- EPUB 章节就绪通知改为 `chapterLoadRevision` 发布，避免 Controller → 闭包 → SwiftUI StateObject → Controller 的循环引用。解析后检查任务取消，已关闭的页面不会继续安装回调。
- 删除无人调用的 AIKeychain / KeychainAudit、旧 hud-reveal 与 keychain-report 入口。保留仍被使用的 PDF 渲染对照通道，旧实验结果保存在验证文档中。


## 2026-09-20 主题与入口维护（同日第二批）

> 与上面「滚动与生命周期维护」是**同一天的两批改动**，各自独立提交，不要混作一批。

- **暖黄主题降饱和**：`ReadingTheme.warm` 改为 `bg #F8F3EB / surface #EDE8DE / text #3E3A34 /
  secondary #766D61 / accent #857360`（色相不变、饱和度 ×0.60、明度 +2%）。只动色值，
  布局、CSS 结构、另外四套主题一字未改；PDF 阅读底衬与 EPUB 的 CSS 变量都从这一处取色，
  所以阅读区与外壳同步生效。
- **入口归属单一真相源落地**：新增 `Sources/LumenApp/Shell/ActionEntries.swift`（纯数据规划表）
  与 `Sources/LumenApp/Shell/EntryAudit.swift`（`--entry-report 1`，10 项）。
  顶栏复制菜单、AI 面板 ⋯ 菜单、菜单栏「文件 > 导出」、AI 面板空状态引导卡**四处**都改为
  从规划表 `ForEach` 渲染；视图只做「entry → 控件」的翻译，不再各自判断「谁属于哪儿」。
  漏补 case 不再静默：`UnimplementedEntryView` 在 DEBUG 下断言、Release 下渲染可见兜底项。
- **菜单项的禁用态从手写条件改为 `LumenAction.isEnabled`**：原先各菜单自己写
  `.disabled(...)`，重构后统一走动作自己的可用性判定，避免「菜单里是灰的、命令面板里点了没反应」。
  请特别注意：**这轮没有丢任何禁用条件**（菜单级的 `.disabled(state.document == nil)`
  与 ⋯ 菜单四项的禁用条件都逐条核对过）。
- **`--theme-report 1` 从「打印主题清单」扩成带断言的自检**（11 项）：新增饱和度与 WCAG 对比度读数，
  并断言「暖黄降饱和生效」「另四套等于改动前原值」「弃用主题的迁移落点」。
  实现移到 `Sources/LumenApp/Design/ThemeAudit.swift`，不再内联在 `LumenApp.swift` 里。
- **`LumenAction.exportTranscript`（默认 ⇧⌘T）**：导出对话记录从「菜单里的临时 Button」提升为
  可改绑动作，与摘要导出对称（命令面板可见、可在设置页改绑）。原本候选的 ⇧⌘J 被弃用——
  它与 `KeyBindingsAudit.verifyRules` 里当作「空闲组合」的测试夹具冲突。
- 新增的两个审计文件的 `NSLog` 一律用显式占位符（`%@`/`%d`）：把插值字符串直接当格式串，
  一旦文案里出现 `%` 整行会被 printf 截断。

## 2026-09-21 批注与覆盖层边界

PDFAnnotationGeometry 集中处理标准 QuadPoints、/LumenID 持久身份和历史碎片判定；PDFController 将一个逻辑条目映射到一个或多个历史成员，所有编辑、删除、点击共享该映射。ReaderBridge 的 annotationFocusRevision 支持重复点击同一条目也触发左栏定位。新批注同页多行使用一个 PDFAnnotation，跨页分别存储。

PageJumpPanel 显式接收 AppState 与 ReaderBridge；RootView 的环境注入包住全部覆盖层，避免覆盖层缺失 EnvironmentObject 触发运行时断言。验证详见 VERIFY-20260921.md。
