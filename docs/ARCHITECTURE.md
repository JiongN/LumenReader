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
│          ├─ LeftRail             常驻纵向图标栏（页签入口）        │
│          ├─ SidebarColumn        目录 · 智能 · 搜索 · 批注 · 页面   │
│          ├─ PDFReaderView / EPUBReaderView                        │
│          └─ AIPanelView                                           │
│                                                                   │
│   AppState ── 全局状态与动作（菜单栏、命令面板、侧栏共用）         │
└───────────────────────────┬───────────────────────────────────────┘
                            │  ReaderBridge（唯一通道）
┌───────────────────────────┴───────────────────────────────────────┐
│  LumenKit（引擎层，无 SwiftUI）                                    │
│                                                                   │
│   Document/    PDF·EPUB 的解析模型、定位符、元数据、全文抽取、批注  │
│   Store/       设置 · 阅读进度 · 最近打开 · 快捷键 · 记忆 · 路径    │
│   AI/          AIProvider 协议 · OpenAI 兼容客户端 · 提示词 · 目录  │
│                · Agent 配置 · 联网文献检索                         │
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
AIPanelView 的 agentMenu 选定 AgentConfig（角色 + 技能 + 自定义指令 + 温度覆盖 + 是否联网）
  └─ AIChatModel.submit(..., agent:, webSearchEnabled:)
       ├─ 触发条件两路：agent.usesWebSearch || AISettings.webSearchEnabled（输入框上的手动开关）
       │    └─ WebLiteratureSearch.search(query:)   三源并发，各自最多 3 次尝试 + 指数退避
       │         └─ 任一个失败都不影响其余；失败原因进 Outcome.failures
       ├─ agent.temperatureOverride 只在这里盖掉 config.temperature（改的是副本）
       └─ PromptLibrary.messages(..., agent:, webContext:)
            ├─ system = 默认系统提示 + agent.promptSection   ← 追加，不是替换
            └─ user   = 材料（抬头 → 原文 → 联网结果）→ 要求 → 模板额外要求
```

`promptSection` 内部顺序是固定的：角色设定 → 技能指令 → 自定义指令。
自定义指令排在技能**之后**是刻意的：技能是调好的行为约束，先立规矩；
用户自己的话放在后面，等于「在此之上还要……」。反过来放，长段自定义指令
会把那几条简短的技能要求冲淡。这条顺序由 `--agent-report` 断言钉住。

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

预算的分配顺序：`预算 = 容器宽 − 图标栏 − 侧栏(248) − 分隔线`；
`可用 = 预算 − 阅读区保底`。

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

`summarizeDocument`（总结全书）**不产生快照**：它要么一次问完、要么先逐片 map
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
  annotations.json   **EPUB** 的批注（PDF 的批注写在 PDF 文件自己里面，不走这里）
```

`~/Library/Caches/com.jn.lumen/` 放 EPUB 解包结果——**可随时安全删除**，丢了会重新解包。

路径哈希用 FNV-1a 64 位（`AppPaths.stableHash`）：稳定、跨进程一致、不需要 CryptoKit。

**API Key 不在这里**。只进 Keychain，账户名由 `AIProviderConfig.keychainAccount` 决定。

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
| 重新生成**替换**旧回答而不是追加 | 追加会让气泡变成「问、答、答」，而 history 是按「最后一个 user + 最后一个 assistant」配对的，两条答会各自配成一对——下一轮模型看到一个已经答过的旧问题，表现就是答非所问 |
| 重跑前先从 history 摘掉那一对 | 重跑成功后 `finishStreaming` 会补回来，净效果是一对换一对，「只收完整对子」的规则没被打破 |
| 总结全书不提供「重新生成」 | 它走 map-reduce，重跑会退化成「把上一次的摘要再总结一遍」。给一个点了会给出错误结果的按钮，比不给更糟 |
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
