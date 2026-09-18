# 自检通道手册

> 这台开发机的条件是：**没有视觉通道**（助手看不到截图），但**有录屏权限**，
> **没有辅助功能权限**（拖拽、键盘模拟无法程序化触发）。
>
> 于是「界面看起来对不对」不能靠肉眼，只能把每一类结论翻译成**可以断言的客观信号**。
> 这份文档就是那套翻译规则。新增功能时，请顺手补上对应的验证通道——
> 一个功能如果没法验，它就等于没做完。

---

## 一、五类证据

| 类型 | 适合回答 | 手段 |
| --- | --- | --- |
| **几何断言** | 有没有遮挡 / 重叠 / 被挤出可视区 | 视图自己上报 frame，检查包含与相交关系 |
| **行为回读** | 功能产物（剪贴板、文件、状态）对不对 | 真的读回来比对 |
| **规则实跑** | 表驱动的逻辑（快捷键改绑）对不对 | 把规则喂进实现，断言输出 |
| **真实像素** | 主题 / 材质 / 颜色对不对 | 录屏抓图 + 按比例取色 |
| **桩服务** | AI 链路（提示词、流式、解析）对不对 | 本机桩服务，可重复、不烧钱 |
| **成本计量** | 终值一样但代价差几个数量级的实现，走的是哪条 | 数耗时与系统调用次数（见下） |

一条铁律：**只打终值的日志等于没验**。
「跳转成功」和「本来就在那一页」的终值输出完全相同，所以跳页自检打三段——
跳之前在哪、请求的是第几个、跳之后在哪。

第二条铁律：**终值相同、代价不同的两条路径，必须用耗时或调用次数区分。**
两个最典型的例子：
- 判断「有没有配密钥」可以走属性查询，也可以去解密文。**两者返回的都是同一个 `Bool`**，
  日志一模一样；但后者要走钥匙串授权（`--keychain-report` 里对比「首次 / 再次」耗时与
  「钥匙串调用+N」就是在量这个差）。
- 缩略图渲染可以「复用缓存」也可以「重新绘制」，得靠 `--thumb-report` 打出的跳过明细区分。

顺手记一条探针技巧：一次性探针不必进仓库，放 `/tmp/<名字>/main.swift`，
`xcrun swiftc main.swift -o probe && ./probe` 即可；需要稳定签名身份时才补一句
`codesign -f -s - -i <某个标识符>`。要判断某个钥匙串查询**会不会弹窗**，
给 `LAContext` 设 `interactionNotAllowed = true`——请求会直接失败并返回 `-128 / -25308`，
从而在不打扰用户的前提下拿到结论。

---

## 二、开关全表

所有开关都是应用的启动参数，`dist/Lumen.app/Contents/MacOS/Lumen` 后面直接跟。

### 载入与截图

| 开关 | 用途 |
| --- | --- |
| `--open <路径>` | 启动后打开指定文件 |
| `--capture <png>` | 抓图后**自动退出**（自检的收尾动作，没它进程不会自己结束） |
| `--capture-delay <秒>` | 抓图前的等待（默认 2.5）。窗口没出现会轮询等待，超时 12s 后记日志退出 |
| `--capture-chrome 1` | 从 `NSThemeFrame` 开始画，把标题栏与工具栏也拍进去 |
| `--capture-screen 1` | **改用系统录屏通道**（`screencapture -l`），拿到真实像素。见第三节 |

### 布局 / 面板

| 开关 | 用途 |
| --- | --- |
| `--layout-report 1` | 打印所有 `layoutProbe` 上报的 frame（窗口内容区坐标） |
| `--sidebar 0` / `--ai 0` | 钉住初始面板可见性（三态：不传参 = 按默认） |
| `--window-size 920x620` | 设定窗口内容区尺寸。布局缺陷几乎都藏在最小尺寸下 |
| `--panel-width 300x300` | 设 **AI 面板**宽度。第一个数（侧栏）已废弃、只接受并忽略（侧栏是常量 248pt），第二个数是 AI 面板宽度。越界值走与拖拽同一个钳制闸 |
| `--sidebar-tab thumbnails` | 直接把侧栏钉在某个页签（`outline` / `smartOutline` / `search` / `annotations` / `thumbnails`） |
| `--immersive 1` | 启动即进沉浸模式，走真实入口 `setImmersive` |
| `--demo-selection 1` | 塞一段**拖动来源**的假选区（正常要鼠标划词才能触发，没有辅助功能权限）。浮条应当出现 |
| `--demo-click 1` | 塞一段**单击来源**的假选区（内容与上一条完全相同，只把来源标成单击）。用于证伪「划词条只在拖动时出现」——此时 `selectionBar` 探针应当**缺席** |

### 行为

| 开关 | 用途 |
| --- | --- |
| `--run-action copyFullText` | 按一次指定动作，然后把**剪贴板**回读出来 |
| `--auto-confirm 1` | 自动点掉确认框（配合 `--run-action`，否则验不到确认之后那半条链路） |
| `--jump-to 42` | 跳到第 N 个单元（1-based），打「跳转前 / 请求 / 跳转后」三段 |
| `--thumb-report 1` | 打印缩略图的渲染与跳过明细（证明滚出可视区的页不再渲染） |
| `--perf-report 1` | PDF 浏览性能自检：①连翻 N 页报翻页耗时 p50/p95/max（并跑「带回调 vs 摘回调」两遍，差值=我们这层的每页开销）；②按视口尺寸逐页渲染报**滚动光栅化**耗时；③翻页前后报进程常驻内存（`phys_footprint`）增量；④报滚完全本后**缩略图缓存仍驻留的张数**。断言：翻页/滚动 p95 ≤ 16.7ms、二次遍历内存增量 ≤ 24MB |
| `--perf-pages N` | 性能自检连翻的页数（默认 120；超过文档页数按实际钳制） |
| `--perf-thumbnail-unbounded 1` | **证伪开关**：关掉缩略图缓存的容量上限。重跑 `--perf-report 1`，④ 行的「仍驻留张数」应从上限值（160）回到「等于全本页数」——证明那条上限真的在起作用 |
| `--jank-report 1` | **连续交互卡顿自检**（拖动分隔线 / 触控板滚动）。与 `--perf-report` 量的是**不同的东西**：后者量「单次动作有多慢」，本通道量「连续动作里每一帧要重算多少次」。报两段（滚动、拖动）各自：①主线程停顿 p50/p95/max（60Hz 定时器的迟到量，当掉帧代理）与「>16.7ms 占比」；②**每步重活计数**（`ReaderContainerView.body` / `AIPanelView.body` / 侧栏 body / 缩略图 body / `updateNSView` / `PDFView.layout` / `PDFView.draw` / `onPositionChange`）。滚动用 `CGEvent` 造像素滚动事件投给内部 `NSScrollView`，拖动按真实 `liveWidth` 写入路径走；两段都带「驱动自证」（页码/偏移真的动了、宽度真的扫过区间），没动会明说「读数无效」 |
| `--jank-steps N` | 卡顿自检每段步数（默认 60 ≈ 1 秒 @60Hz）。大文档给足 `--capture-delay`（滚动段要等 PDFView 装好，本通道最多轮询等 10s） |
| `--jank-no-coalesce 1` | **证伪开关**：关掉拖动期宽度写入的「按显示刷新合并」。同一构建重跑 `--jank-report 1`，「每步重活」应从 ~1/步 回到 ~3/步（本机每帧模拟 3 次指针写入）——证明读数变化确实来自合并本身 |
| `--jank-watch 1` | **被动监视**（与 `--jank-report` 相反，不驱动任何东西）：正常启动运行，后台每 2 秒把「主线程停顿 p50/p95/max、>16.7ms 次数、各计数器增量、进程 CPU 增量（并化成**几个核**）、当前页码/滚动偏移」写一行到 `/tmp/lumen-jank-watch.log`，**交给用户用真触控板产生手势**复现（合成事件搓不出连续惯性滚动）。**页号用视口几何换算**（视口中心过 `page(for:nearest:)`），不是 `PDFView.currentPage`——后者要等滚动落定才更新，会让整列卡在 `页=0`。纯读不写设置（`suppressSave`），日志只在 2 秒汇总时落盘，不在绘制路径里写文件。**拖动是可选的**，没拖那段全 0 属于「什么都没做」，不是卡顿 |
| `--jank-scroll-delta N` | 滚动段每步位移（默认 1900 = 饱和点）。把合成驱动加重到接近真机负载用；标定表见第七节 |
| `--jank-scroll-burst N` | 滚动段一步投几个滚轮事件（默认 1，模拟真触控板「一帧一串」）。实测中性，见第七节 |
| `--jank-scroll-zoom X` | 滚动段把 `scaleFactor` 钉在 X（重光栅化的像素 ∝ 倍率²） |
| `--pdf-render-report 1` | **渲染保真自检**：把渲染状态钉死（跳第 1 页 + 适宽倍率）并打印本次三旋钮，配合 `--capture` 得到可逐像素比的两张图。见第七节 |
| `--pdf-render-slim 1` | 切到「瘦身件」渲染（关投影 + 关页间留白）。**默认不开**——实测无收益，见第七节 |
| `--pdf-page-shadows 0\|1` | 单项覆盖：页面投影（PDFKit 默认开）。实测**逐像素无作用**，见第七节 |
| `--pdf-page-breaks 0\|1` | 单项覆盖：页间留白（PDFKit 默认开）。实测关掉**更费 CPU 且改观感**，见第七节 |
| `--pdf-interpolation high\|low\|none` | 单项覆盖：重绘插值质量（PDFKit 只有三档，**没有 medium**）。见第七节 |
| `--annotate-report 1` | 批注自检（15 项）：高亮 → 锚定批注 → 写盘 → 重开核对 → 编辑 → 定位 → 新建 → id 去重 → 删除 |
| `--search-report 1` | 搜索高亮自检：高亮出现、逐条定位、**且不会写进用户的书** |
| `--agent-report 1` | Agent 自检（20 项）：预设稳定性、系统提示拼装顺序、温度覆盖、容错解码、真实联网检索 |
| `--websearch-report 1` | **联网文献检索自检**：逐源跑一遍，记录命中数 / 失败 / 耗时；断言至少一个源命中且总命中 ≥ 3 |
| `--rerun-report 1` | 「重新生成」自检：需配合 `--mock-ai 1`；断言气泡被替换、history 未叠加 |
| `--resize-report 1` | 面板宽度自检（12 项）。**新语义**：写入组 7 项（AI 面板宽度写入后布局跟随、越界钳制、下限钳回、逐帧写入不越界 / 终值 / 布局一致、**侧栏宽度是常量不受设置影响**）+ 窗口缩放组 5 项（最挤时阅读区 ≥ 320pt、图标栏完整在窗内、AI 面板不越右缘、拉宽后回到落库偏好、极窄容器不超出预算）。**窗口尺寸由自检自己控制**，并走一遍「宽 → 最挤 → 再拉宽」 |
| `--ask "问题"` | 启动后自动发起一次提问（端到端跑 AI 链路） |

### AI 与桩服务

| 开关 | 用途 |
| --- | --- |
| `--mock-ai 1` | 把 AI 服务商临时指向 `127.0.0.1:8777`，**只改内存不落盘** |
| `--mock-ai host:port` | 指到别的地址 |
| `--smart-outline 1` | 跑完整的智能目录两步链路，打印条目清单 / 页码落点 / 缓存文件 |
| `--smart-outline-summary N` | 额外对第 N 条（1-based）生成一次摘要 |

### 其它

| 开关 | 用途 |
| --- | --- |
| `--keys-report 1` | 打印快捷键表 + 撞车检查 + 实跑一遍改绑规则（含全角→半角归一化表、载入期迁移、不可键入绑定被丢弃；共 55 项） |
| `--ocr-menu-report 1` | OCR 右键菜单自检：表驱动断言「该出现哪些项 / 叫什么文案 / 该不该禁用」（纯函数 `PDFContextMenuPlanner.items`，16 项） |
| `--keychain-report 1` | 打印钥匙串访问成本与缓存状态（**只读**，不写不删用户钥匙串） |
| `--font-report 1` | 打印字体目录统计与断言 |
| `--palette 1` | 启动后打开命令面板 |
| `--settings 1` / `--settings-tab interface` | 打开设置窗口 / 落在指定页签 |
| `--ocr 1` | 打开文档后对当前页做一次 OCR |
| `--remember "内容"` | 先记一条跨语言记忆（验记忆落盘与提示词注入） |

> ⚠️ **布尔开关必须写成「开关 + 值」**（`--ocr 1`），不要裸写（`--ocr --capture …`）。
> 原因见 `README.md` 的硬约束第 1 条——症状是窗口完全不创建，极难定位。

---

## 三、两条截图通道，用哪条

| | 离屏绘制（默认） | 录屏（`--capture-screen 1`） |
| --- | --- | --- |
| 原理 | `NSView.cacheDisplay` 进程内绘制 | `screencapture -l<windowNumber>` |
| 需要权限 | 不需要 | 屏幕录制 |
| 材质（`.regularMaterial`） | **不可靠** | 真实 |
| 截图范围 | `contentView`（可只截内容区） | 整窗（含标题栏 / 工具栏） |

**实测对照**（同一界面、同一帧条件，`--capture` 后取色）：

```
离屏：侧栏 #F4F4F4  AI 面板 #F4F4F4  正文页 #FFFFFF
录屏：侧栏 #F0F1F2  AI 面板 #F0F1F2  正文页 #FFFFFF
```

正文页（无材质）两条通道完全一致 —— 这是一组对照，说明采样方法本身没有系统偏差；
而有材质的两块差了约 4/255 并带一点蓝，正是「离屏把材质画成了不透明近白」的表现。

**结论**：验证主题与材质一律走 `--capture-screen 1`；`effectiveAppearance` 与系统色
则由日志给出（截图里的外观可能是假象，日志里的不是）。

```bash
# 取色（按比例，不必关心 1x/2x）
swift tools/sample_pixels.swift /tmp/shot.png 0.10,0.30 0.50,0.50 0.90,0.50
# → 输出 #RRGGBB + 感知亮度 + 「深/浅」判定
```

---

## 四、常见任务的做法

### 验证一个布局改动有没有造成遮挡

```bash
dist/Lumen.app/Contents/MacOS/Lumen --open /tmp/lumen-test/large.pdf \
  --window-size 920x620 --layout-report 1 --capture /tmp/shot.png --capture-delay 5
```

日志里每个 view 的 `x/y/w/h/maxX/maxY` 直接交给断言器，不要靠肉眼看：

```bash
python3 tools/layout_assert.py /tmp/lumen-smoke        # 目录或日志文件都行
```

它会逐条验：探针有没有越出窗口内容区、`maxX` 与 `x+w` 是否自洽、
三块面板有没有横向重叠、面板是否铺满宽度、状态条有没有跑到面板底下，
以及**收起的面板是探针消失还是缩成 0 宽继续占位**
（后者在截图里看不出区别，却会让快捷键落在看不见的控件上）。
预期从日志里的启动参数（`--sidebar 0` / `--ai 1`）推导，不依赖文件名。

> 两条依赖「启动参数」的规则都要靠日志里那行 `启动参数：`，而它的正则**必须带
> `re.MULTILINE`**——这行日志在文件中间，少了这个标志 `search` 恒为 None，
> 规则会**静默地一次都不跑**而输出照样全绿。已修（此前「面板可见性」那条
> 一直是空转的）。同理，沉浸模式下只有 `readerSurface` 一个面板且**刻意居中
> 限宽 880**，按「铺满」判会稳定误报两条，已改成验「居中 + 不超过限宽」。

需要新控件被审到时，在视图上加 `.layoutProbe("名字")`——它只在 `--layout-report 1`
时才挂 `GeometryReader`，正常启动零开销。侧栏那一列现在是**两个**探针：
`sidebarRail`（常驻图标栏，52pt）与 `sidebar`（可收起的内容面板）。
断言器把 `sidebarRail` 也算作面板，所以 `--sidebar 0` 时「最左贴 0」由图标栏承担。

> ⚠️ **布局 dump 是「首次上报后 2 秒」统一打印**，所以 `--capture-delay` 必须留够余量，
> 否则进程会在 dump 之前就退出，日志里一条布局都没有——看起来像"探针没生效"，
> 实际是抢跑。EPUB 走 WebKit，阅读容器出现得比 PDF 晚，实测 `--capture-delay 8` 才稳。
> 判据很简单：日志里没有 `[Lumen][layout] 窗口内容区 …` 就是没 dump 成，不是布局有问题。

### 验证连续交互的卡顿（拖动分隔线 / 触控板滚动）

**先分清两条通道的分工**——它们是互补的，别拿一条的结果去回答另一条的问题：

| 通道 | 量的东西 | 回答的问题 | 典型瓶颈 |
| --- | --- | --- | --- |
| `--perf-report 1` | **单次动作的代价**（一次翻页 / 一次整页光栅化耗时） | 「这一个动作本身有多慢」 | 一次性渲染、解析 |
| `--jank-report 1` | **连续动作里每帧做几遍重活** + 主线程掉帧 | 「连续做这个动作时，每一帧要重算多少次」 | 每帧重排 / 每帧重光栅化 |

用户说「拖动时抖 / 滚动卡」时，`--perf-report` 大概率全绿（单次都不慢），要查的是 `--jank-report`。

```bash
# 拖动 + 滚动两段一起量；窗口要给宽（见下方「窗口宽度」提示）
dist/Lumen.app/Contents/MacOS/Lumen --open /tmp/lumen-test/large.pdf \
  --window-size 1400x900 --sidebar-tab thumbnails --jank-report 1 \
  --capture /tmp/jank.png --capture-delay 40
```

读法：

1. **每步重活**是定位项。拖动段 `PDFView.draw(重绘)=1.0/步` 说明**每个拖动步长都在整页重光栅化**——
   这就是拖动手感的元凶。修复前本机实测：`ReaderContainerView.body=3.02/步  PDFView.layout=2.80/步 PDFView.draw=2.80/步`；
   按显示刷新合并宽度写入后降到 `~1.0–1.3/步`。
2. **主线程停顿**是打分项。`>16.7ms 的采样占比` 从 10% 降到 **0%** 就是可感的手感改善。
3. **进程 CPU 时间增量**是「有没有干活」的旁证，且**与线程无关**（`getrusage` 含所有线程）。
   滚动段尤其要看它：本机实测滚动**主线程停顿 p95≈1.9ms、`PDFView.draw=0`，但进程 CPU 增量 752ms（12.5ms/步）**
   ——重活确实发生了，只是在**后台线程**（PDFKit 分页光栅化）。
4. **驱动自证**必须先绿再读数。滚动段打印「页码 a → b，滚动偏移 x → y ✅ 确实滚了」；
   拖动段打印**「写入 N 次 → 实际应用 M 次（值真的变了）；合并节拍回调 K 次；容器重算 C 次」**——
   注意它证的是**「布局真的发生了」**，不只是「写入发生了」：`实际应用` 是 `LivePanelWidth.value` 真正改变
   （触发一次布局失效）的次数，`容器重算` 是 `ReaderContainerView.body` 真的被求值的次数。
   自证行的判据是分层的，任一不过会明说**「本段读数无效」**并给出是哪一层：
   - `写入 = 0` → 驱动没跑；
   - `应用 = 0` → 写了但一次都没落下来（合并链路断了）；
   - `应用 > 0 但 容器重算 = 0` → AI 面板此刻不参与布局（被收起 / 沉浸），拖动没落到版面；
   - `应用 < 步数一半` → 合并节拍没跟上，读数存疑。

> ⚠️ **拖动段「每步重活」只有在自证绿的时候才可读**，因为合并把「写入」与「应用」解耦了：一次写入要等
> **下一次合并节拍**才落到布局。驱动跑完后本通道会**先 `flushNow()` 坐实待应用值、再等 3 拍**才取计数。
> 合并节拍是主队列 `DispatchSourceTimer`（60Hz）——不是 `CADisplayLink`：后者的回调由 CoreAnimation 驱动，
> **窗口被遮挡 / 应用非激活 / 屏幕休眠时会一次都不回调**，那时 `pending` 永远等不到应用（拖动期间面板不跟手），
> 自检也会读到一片 0。实测同一份构建、只换文档/窗口就出现 `body=67(1.12/步)` 与 `body=0(0.00/步)` 两个极端——
> 根因就是这个，与文档和窗口宽度都无关（两次 `容器宽` 都是 1400pt）。换定时器后同一命令连跑两次落进同一档
> （A：`76(1.27/步)`/`64(1.07/步)`，B：`62(1.03/步)`/`69(1.15/步)`）。

> ⚠️ **不要把「主线程停顿低」读成「滚动很轻」**。`--jank-report` 的两把尺子（主线程停顿、`PDFView.draw`）
> **都量不到** PDFKit 的分页光栅化：前者只测主线程，后者只在「view 被要求重画」（frame 变化等）时触发，
> 而分页渲染走的是内部文档视图的 **tiled/layer 路径**。只有第 3 行「进程 CPU 时间」看得见它。
> 本通道在检测到「停顿低 + CPU 高」时会显式打一行提醒。
> 触控板**连续惯性滚动**这种重活密集的真实场景，合成事件搓不出来——用 `--jank-watch`（见下）让真机产生手势。

> ⚠️ **同一个动作，`每步重活` 与 `进程 CPU` 看的是两件事，别混着比**。本轮 A（120 页 large.pdf）与
> B（2 页 text.pdf）的 `body/步` 在两档之间几乎相同（~1.0–1.3），但**进程 CPU/步差了近两倍**
> （A 40–52ms、B 22–25ms）——差在 PDFKit 整页光栅化的**页内容**上，与「每帧重排几次」无关。

> ⚠️ **窗口宽度会决定拖动段是否有效**。侧栏可见时 AI 面板上限 = `窗口宽 − 图标栏 − 侧栏(248) − 阅读区保底(320)`；
> 窗口给到最小 920pt 时这个上限正好等于下限 300，拖动区间塌成 `300…300`——每一步写的是同一个宽度，
> 布局根本不重算，重活计数会**假绿成 0**。本通道会显式打印「可用区间仅 0pt…本段读数无效」提醒你加大窗口。
> 滚动段不受影响。

> ⚠️ **本通道怎么量滚动**（踩过的坑）：`PDFView` 自己不处理滚轮，直接把事件投给 `pdfView.scrollWheel` 等于投给一个不接的人，
> 页码与偏移纹丝不动；真正消化滚轮的是它内部的 `NSScrollView`。另外带精确增量的滚动会进入「响应式滚动 / 惯性」，
> PDFKit 的页码变更回调要等滚动**落定**才发——投完事件立刻读计数会全 0，所以要再等一段惯性滑行。

### 用真触控板复现滚动卡顿：`--jank-watch 1`

合成事件复现不了触控板的连续惯性滚动。换成**让用户产生手势**：应用正常启动、正常运行，
后台只挂埋点，每 2 秒把汇总写一行到 `/tmp/lumen-jank-watch.log`。

```bash
# 不驱动、不截图：正常开一本书，用户自己滚 / 拖，交互完 ⌘Q 退出
dist/Lumen.app/Contents/MacOS/Lumen --open /path/to/你的书.pdf --jank-watch 1
# 启动会打一行：[Lumen][jank] jank watch 已开启：日志 → /tmp/lumen-jank-watch.log
cat /tmp/lumen-jank-watch.log
```

日志每行形如：

```
+12.0s 停顿 p50=0.31 p95=8.42 max=58.10 >16.7ms=6/121(5%) | CPU +1840ms (0.9 核) | 页=7 偏移=98421 | body=3 ai=1 side=1 thumbBody=2 update=0 layout=0 draw=0 thumbR=1 pos=1
```

看两件事：**停顿尖峰出现在哪一段（滚动 vs 拖动 / 哪一秒）**，以及**那一段的计数器增量**。
要复现用户报的滚动卡顿，就在日志里找「`>16.7ms` 占比突然升高的那几行、当时 `pos`/`thumbR` 有没有涨、`CPU` 增量多大」。

三个读数要点：
- **`CPU +N ms (M 核)`**：与线程无关（`getrusage` 含所有线程），**后台光栅化只有它看得见**。
  化成「几个核」是为了让「是不是真饱和了」一眼可读——真机那次就是 `≈3 个核`。
- **`页=7`**：是**视口中心**所在页（滚动中即更新），不是 `PDFView.currentPage`（后者要等滚动落定，
  会把这一列卡在 `页=0`，没法把尖峰和位置对上）。
- **拖动段是可选的**。没拖那段所有计数会全 0、像「空闲」——那是「什么都没做」，不是卡顿，忽略即可。

规矩：watch 模式**不改变任何行为**（纯读，`suppressSave=true`，跑前跑后 `settings.json` md5 必须一致）；
埋点本身开销小到不影响读数（计数走锁自增，日志只在 2 秒汇总时落盘，**不在绘制/布局路径里写文件**）。

> 用户实机这次 `--jank-watch` 的读数就是本节开头的那个结论依据：活跃段 CPU ≈3 个核、而本层计数器全 0
> → 卡顿在 PDFKit 渲染管线。据此做的三旋钮单变量证伪见 **第七节**。

### 验证复制类功能

产物在剪贴板，截多少张图都证明不了。

```bash
dist/Lumen.app/Contents/MacOS/Lumen --open /tmp/lumen-test/text.pdf \
  --run-action copyFullText --auto-confirm 1 --capture /tmp/x.png --capture-delay 8
# 日志：[Lumen][clipboard] copyFullText 纯文本 字数=703 预览=第一章 …
```

**必须等长任务结束再 dump**：`run-action` 会轮询到忙碌状态结束，
再加 0.5s 让写剪贴板落定。固定等待会在扫描件上 dump 出「剪贴板还是空的」这种假失败。

### 验证 AI 链路（不烧钱）

```bash
# 终端 A：常驻桩服务
python3 tools/mock_openai_server.py 8777

# 终端 B
dist/Lumen.app/Contents/MacOS/Lumen --open /tmp/lumen-test/large.pdf \
  --mock-ai 1 --smart-outline 1 --smart-outline-summary 2 \
  --sidebar-tab smartOutline --capture /tmp/x.png --capture-delay 18
```

桩服务按提示词分流：
- 含「只输出 JSON」→ 返回一段**故意做脏**的响应（带 markdown 围栏、带客套话、
  夹一条越界条目、夹一条重复条目、混用 `unit`/`page` 键名），用来打解析器的宽容度。
- 其它 → 返回一段中文说明文。

请求体会转储到 `/tmp/lumen-mock-requests.jsonl`，用来核对**提示词里到底送出去了什么**：

```bash
tail -1 /tmp/lumen-mock-requests.jsonl | python3 -m json.tool
```

**`--mock-ai` 只改内存设置**（配 `SettingsStore.suppressSave`），
用户的真实服务商列表不会被污染。可以这样自查：

```bash
md5 -q ~/Library/Application\ Support/com.jn.lumen/settings.json   # 跑前跑后应当相同
```

### 验证批注 / 搜索高亮 / Agent

三条通道都让**进程自己走完全程**，并且断言全部指向**外部可核对的产物**。
全程在 `/tmp` 的副本上做，绝不碰用户的文件。

```bash
# 批注：高亮 → 页面批注 → 写盘 → 重开核对 → 删除（10 项）
dist/Lumen.app/Contents/MacOS/Lumen --open /tmp/lumen-test/text.pdf \
  --annotate-report 1 --capture /tmp/x.png --capture-delay 3

# 搜索高亮：出现 → 逐条定位 → 不叠加 → 保存后重开仍是 0 条（6 项）
dist/Lumen.app/Contents/MacOS/Lumen --open /tmp/lumen-test/text.pdf \
  --search-report 1 --capture /tmp/x.png --capture-delay 4

# Agent：预设 id 稳定、系统提示拼装、真实联网检索（14 项，要联网）
dist/Lumen.app/Contents/MacOS/Lumen --agent-report 1 --capture /tmp/x.png --capture-delay 5

# 面板宽度：12 项。窗口尺寸由自检自己切（宽 → 920pt 最挤 → 再拉宽），
# --window-size 只影响起始尺寸；--capture-delay 要留够 4 次缩放 × 0.9s
dist/Lumen.app/Contents/MacOS/Lumen --open /tmp/lumen-test/large.pdf \
  --window-size 920x620 --resize-report 1 --capture /tmp/x.png --capture-delay 30
# 日志：[Lumen][resize] 自检：通过 12 项，失败 0 项 ✅
```

> ⚠️ `--resize-report` 的写入组（下限钳制、逐帧写入不越界）**要在窄窗口下跑**
> 才有意义：1340pt 时按窗口算出的上限（420）恰好等于静态上限，此时若有人把
> 动态钳制删掉，断言照样全绿——那就退化成恒真断言了。用 `--window-size 1000x700`
> 时上限是 347，与静态上限不同，删掉动态钳制会立刻红 3 项（已实测）。
> 反向的边界也写死了：窗口窄到「可用区间 < 40pt」时「布局跟随」会被**跳过**，
> 而不是写一个和当前值相同的值去骗一个「通过」。
>
> 窗口缩放组反过来：**尺寸由自检自己控制**，并且必须从宽到窄**走一遍真实的缩放**。
> 停在窄窗口上读一次数是不够的——「覆盖式钳制」那种实现（窗口一变就把钳制值
> 写回落库）根本没被触发的机会，⑧⑨ 两条就成了恒真。
> 「最挤状态」= 920pt 且两侧偏好都顶到静态上限（52+2+420+640 = 1114 > 920）；
> 只把侧栏顶满的话总宽仍装得下，图标栏那条（⑦）会退化成恒真。
>
> 六条新断言都做过人为破坏验证：删掉渲染时重算 → ⑤⑥⑦ 红（`图标栏 x=-97`、
> `阅读区 0pt`，与 QA 独立复现的数字一致）；加一个覆盖式写回 → ⑧⑨ 红；
> 删掉最后那道等比压缩的闸 → ⑩ 红。

**为什么这些断言不能停在「函数返回 true」**——三条通道各有一个真实教训：

| 曾经的写法 | 为什么是恒真/误判 | 现在的写法 |
| --- | --- | --- |
| `addHighlight(...) == true` | 只证明代码走到了那一行 | 重新从磁盘 `PDFDocument(url:)` 打开，数批注 |
| 在页高 `midY` 处取一条横带当选区 | 段落只占页面上部，中点落在空白里，取到的是**空选区**（不是 nil，不报错），于是失败被归到「高亮坏了」 | 按**真实字形位置**（`characterBounds`）算横带；并把「选区非空」单独列成一条断言 |
| 搜索词写死成 `"the"` | 测试素材全是中文 → 0 命中 → 报「搜索有命中 ❌」，看起来像搜索坏了 | 取**全书出现最多的字符**当查询词 |
| `searchHighlightCount == hits.count` | 一处命中跨行会被拆成多条高亮（这是**正确**行为）→ 等号会把它判成失败 | 用 `>=`，并把「命中 / 高亮」两个数都打出来 |
| `messages.last` 里 `web 段 in 任务段` | 这条断言本身是对的，**抓出了真 bug**：代码把检索结果追加在任务要求之后，而注释写的是之前 | 保留，并补一条「原文排在检索结果之前」 |

> 判据：一条断言如果在实现明显写错时依然会通过，它就是恒真的，必须重写
> （或写完之后人为让它失败一次）。

**查看批注自检的产物**：`/tmp/lumen-annotate-audit.pdf` 保留在磁盘上，
可以直接用「预览」打开核对高亮的位置与颜色。

---

### 验证 AI 的三条新通道

```bash
# 联网文献检索：真实联网，逐源记录命中数 / 失败 / 耗时
dist/Lumen.app/Contents/MacOS/Lumen --websearch-report 1 --capture /tmp/x.png --capture-delay 14

# 「重新生成」：需要桩服务在跑（终端 A：python3 tools/mock_openai_server.py 8777）
dist/Lumen.app/Contents/MacOS/Lumen --open /tmp/lumen-test/large.pdf \
  --mock-ai 1 --rerun-report 1 --capture /tmp/x.png --capture-delay 14
```

**`--websearch-report` 看的是「取数」本身**（三个源现在通不通、各出几条、耗时多少），
与 `--agent-report` 里那次检索（关心的是结果有没有按正确顺序进提示词）分工不同。
三个源都是外部服务，可用性会随时间变——Semantic Scholar 就是这样被判出局的——
所以这条通道要能随时单独重跑，而不必顺带跑一遍 Agent 拼装。
查询词写死成一个跨库都有存量的学术词组：用冷门词会因为「确实没有文献」而失败，
那是不可判定的失败，只会给自检掺噪声。

**`--rerun-report` 验的是两件在界面上看不出来的事**：气泡是被**替换**的还是被追加的
（截图里长得一样），以及 history 有没有被叠加（症状是「重跑之后模型开始答非所问」）。
它拿两个外部产物当证据：气泡条数不变，以及桩服务收到的两次请求体规模一致
（`/tmp/lumen-mock-requests.jsonl`）。读不到转储文件时如实跳过，不拿空结果充数。

> ⚠️ 两条通道都必须带 `--capture`，否则进程不退出（会挂到超时，退出码 137）。
> 另外 `--rerun-report` 会先 `chat.clear()` 清掉这本书此前的对话——
> 气泡数与请求体规模都拿来做断言，带着上一轮历史进来自检就成了掷骰子。

### 验证缓存与失效判定

智能目录的缓存有效性靠「生成时的单元数 == 当前单元数」判定。直接把缓存改脏再启动：

```bash
# 伪造一份「属于另一本 999 页书」的目录
python3 - <<'PY'
import json, pathlib
p = pathlib.Path("~/Library/Application Support/com.jn.lumen/docs/<哈希>/smart-outline.json").expanduser()
d = json.loads(p.read_text(encoding="utf-8"))
d["sourceUnitCount"] = 999
p.write_text(json.dumps(d, ensure_ascii=False), encoding="utf-8")
PY

# 启动后检查该文件已被清除（否则用户会看到指向错误页码的旧目录）
```

日志里 `绑定后（尚未生成）：缓存条目数=… 与当前文档匹配=…` 是「缓存复用」这条链路的
唯一证据。不记这一条的话，「复用成功」和「每次都重新生成」在日志上长得一模一样，
而后者意味着用户每开一次书就被扣一次钱。

### 验证快捷键

```bash
dist/Lumen.app/Contents/MacOS/Lumen --keys-report 1 --capture /tmp/x.png --capture-delay 3
```

会打印全表、撞车检查、系统保留键占用、改绑规则实跑结果（用临时文件，不碰用户配置）。
新增的 55 项里，与「不可键入的绑定导致失效」直接相关的几条：

- 全角映射表**逐项**实跑（`】→]`、`（→(`、`：→:` …）；
- 归一化拒绝 `é` / emoji / 汉字 / 全角空格；
- 载入期把含 `】` 的文件迁移成 `]`（modifiers 不动）；
- 载入期丢弃不可键入的绑定并回落默认；
- **所有生效绑定的 key 都在可键入集合内**——修正前用户的 `toggleAIPanel = ⌥】` 会让它红；
- `set()` 拒绝不可键入的 key（录制器归一化之后的第二道闸）。

### 验证「划词条只在拖动时出现」与 OCR 右键菜单

```bash
# 拖动来源：浮条应出现
dist/Lumen.app/Contents/MacOS/Lumen --open /tmp/lumen-test/large.pdf \
  --demo-selection 1 --layout-report 1 --capture /tmp/a.png --capture-delay 6
#   日志应有： [Lumen][layout] selectionBar  x=… w=… maxX=…

# 单击来源：浮条应缺席（同一段选区，只把来源标成单击）
dist/Lumen.app/Contents/MacOS/Lumen --open /tmp/lumen-test/large.pdf \
  --demo-click 1 --layout-report 1 --capture /tmp/b.png --capture-delay 6
#   日志应**没有** selectionBar —— 这一条是可证伪的：删掉 selectionFromDrag 这道门，
#   --demo-click 立刻会重新出现浮条

# AI 面板收起后探针必须消失（布局探针生命周期）
dist/Lumen.app/Contents/MacOS/Lumen --open /tmp/lumen-test/large.pdf \
  --run-action toggleAIPanel --layout-report 1 --capture /tmp/c.png --capture-delay 6
#   日志应**没有** aiPanel —— 探针不注销时会留下越界的最后一帧（maxX=1431）

# OCR 右键菜单：菜单本身没法自动化，验的是纯函数判定
dist/Lumen.app/Contents/MacOS/Lumen --ocr-menu-report 1 --capture /tmp/d.png --capture-delay 3
#   日志： [Lumen][ocr-menu] 自检：通过 16 项，失败 0 项 ✅
```

### 自检会留下什么（副作用清单）

跑自检不是零成本的，写清楚免得下一个人把「跑完发现阅读记录变了」当成灵异事件：

| 副作用 | 现状 | 怎么回避 |
| --- | --- | --- |
| **recent.json（最近打开）** | 已修：自检跑不写 | `LaunchOptions.isAuditRun`（命令行里带任一 `--*-report` / `--capture` / `--mock-ai`）时不记最近打开。此前每次自检都会把 /tmp 里的测试书插到列表最前，跑几次就把用户真实记录顶下去了。正常从命令行开一本书照旧记录 |
| **settings.json（偏好）** | 已修：自检跑不落盘 | 各 audit 开头就 `SettingsStore.suppressSave = true`（`--mock-ai` 也是）。验证方式：跑前跑后比对 `md5 ~/Library/Application\ Support/com.jn.lumen/settings.json` |
| **keybindings.json（快捷键）** | **会写一次**（仅当检测到需要迁移 / 丢弃时） | `KeyBindingStore` 载入时逐条校验：全角 key（`】`）→ 半角（`]`）一次性迁移，不可键入的绑定丢弃并回落默认。**这是刻意的修复行为**，不是污染：用户的 `⌥】` 物理上按不出来，迁移后「显示 / 隐藏 AI 面板」才真的能用。文件已合法时不再写 |
| **测试书的 chats.json** | 仍会写（按文档目录存） | `--rerun-report` / `--ask` 会在**被打开的那本书**的 `chats.json` 里留下气泡。对 /tmp 里的测试书无所谓；**拿真实书籍跑 `--ask` 会往它的会话里追加内容**，需要干净的会话就先备份那一本书的 `chats.json` |
| **剪贴板** | 会被覆盖 | `--run-action copyFullText` 之类把结果写进系统剪贴板，跑之前别留着要用的东西 |
| **AI 花费** | 有 | 除 `--agent-report` / `--websearch-report` 的联网检索（免密钥公开库）外，凡是要模型的通道都先加 `--mock-ai 1` |

---

## 五、测试素材

```bash
swift tools/make_test_pdfs.swift /tmp/lumen-test   # text.pdf（有文本层）/ scanned.pdf（无文本层）
python3 tools/make_test_epub.py /tmp/lumen-test    # typography.epub（自带对抗性 CSS）
```

`/tmp/lumen-test/large.pdf` 是 120 页的文档，用于缩略图与长文档性能验证。

---

## 六、这个通道验不了什么

诚实列出边界，免得下一个人以为「日志干净」就等于「没问题」：

- **审美**。间距是 8 还是 10、圆角是否统一——这些只有人能判断。
  自检能保证的是「没有遮挡、没有裁切、对比度达标、主题生效」。
- **拖拽手势本身**。辅助功能权限未授予，程序化触发不了鼠标拖拽。
  面板宽度走的是「直接写设置项」的等效路径，触及了同一条计算链路，
  但**「按下鼠标时命中区域对不对」这一段没有被验证过**。
- **动效的观感**。`MotionGate` 能证明「时长参数按设置生效」，
  但「看起来丝不丝滑」需要人看。
- **真实服务商的兼容性**。桩服务只覆盖 OpenAI 兼容协议的**标准形态**，
  各家服务商对 `reasoning_content`、`max_tokens` 等字段的细微差异不在覆盖范围内。
- **系统授权框「弹没弹」**。`screencapture` 抓的是自己那个窗口，
  系统弹窗不在其中，截图里看不见。所以跟系统授权有关的结论只能靠间接信号：
  用 `LAContext.interactionNotAllowed = true` 的探针把「会弹窗」转成「返回 -128」，
  或看 `--keychain-report` 的耗时与钥匙串调用次数。
- **「重编译后首次用到密钥」那一次授权**。这是 ad-hoc 签名的地板，不是缺陷：
  login 钥匙串的 ACL 认 CDHash，而 `./build.sh` 每次产出新 CDHash。
  试过并已排除的三条路见 `docs/ISSUES-2026-09-17.md` 第 8 节
  （数据保护钥匙串缺 entitlement、补 entitlement 被 SIGKILL、本机无签名身份）。
  **自签证书「Lumen Dev」把这一条从「每次重编译」降成「切换身份那一次」**，
  但仍不能断言「永不弹窗」——那要求签发一个受系统信任的开发者身份，本机做不到。
- **批注在真实拖拽下的行为**。自检里的选区是程序构造的（按字形位置算横带），
  它走通了「选区 → 高亮 → 写盘」的同一条代码路径，但
  **「用户按下鼠标拖过两行时选区长什么样」没有被验证过**，理由同拖拽手势。
- **EPUB 批注「写回原文件」**。EPUB 是压缩包，写回会破坏其结构与签名，
  所以它存进应用数据目录（`AppPaths.annotationsFile`）。自检只验了
  PDF 那条「写回原文件」的路径；EPUB 那条只验了高亮能画上、能重绘。
- **联网检索的质量**。自检能证明「三个源各返回了结果、每条都带可核查的出处、
  失败会如实报出来」，但**「这些文献是否真的回答了读者的问题」验不了**——
  那需要读文献，属于人的判断。
- **检索源的长期可用性**。`--agent-report` 每次跑的是**当下的**网络状态。
  Semantic Scholar 就是这样被判出局的：连测两次都 429。
  一个源今天通不代表下个月通，所以这条通道要定期重跑。

---

## 七、滚动卡顿：三旋钮单变量证伪与保真对比

用户实机 `--jank-watch`（2 秒一窗）把滚动卡顿定位在 **PDFKit 渲染管线**：活跃段进程 CPU 在 2 秒里烧掉
5.9–6.8 秒（≈3 个核），而我们这层所有 SwiftUI 计数器（`body/ai/side/thumbBody/update/layout/draw/thumbR`）
**全是 0 或个位数**。这一节记录：①把合成驱动加重到能复现该负载、②对 PDFKit 三个旋钮做单变量证伪、
③改渲染后的保真对比。

> **结论先放这里**：三个旋钮都省不下 CPU，瓶颈是 **PDFKit 内部整页光栅化**。渲染默认**维持原样**。

### 7.1 先把合成驱动加重到接近真机

`--jank-report` 的滚动段用合成滚轮事件驱动内部 `NSScrollView`。旧的 `--jank-scroll-delta 30` 太轻
——每步只有 ~10ms CPU、比真机轻 5 倍，在它上面迭代等于测不到要优化的负载。标定（`large.pdf`、60 步、取 `CPU ms/步`）：

| `--jank-scroll-delta` | CPU ms/步 | 说明 |
| --- | --- | --- |
| 30 | 10.2 | 旧默认，太轻 |
| 120 | 13.7 | |
| 240 | 14.0 | |
| 480 | 15.7 | |
| 960 | 18.6 | |
| **1900** | **22.8** | ≈ 适宽倍率下一整页高度（842pt × 2.27），**饱和点**，现为默认 |
| 3800 | 22.4 | 已不再增长（白滚） |

读数随 delta **次线性增长并很快饱和**（1900 ≈ 3800）。驱动强度会被自证行报出来：

```
[Lumen][jank] 滚动驱动强度：CPU 17.7ms/步；真机触控板实测 ≈ 53.5ms/帧（2 秒烧 5.9–6.8s / 120 帧）。本次为真机的 0.33×。
```

**诚实交代：本机合成驱动最多只到真机的 ~0.42–0.51×。** 真机基线 53.5ms/帧取自用户实机那次，
但那一对窗口与并发的基准跑有重叠、**峰值可能被争抢放大**。所以「与真机的倍数」当**参考**不当验收线。
加重到饱和后仍够不到，正说明合成事件搓不出真机触控板那种连续惯性负载——这也是当初要做
`--jank-watch` 让真机出手的原因。

另外两个强度旋钮：`--jank-scroll-zoom 2.0`（高倍率要重光栅化的像素 ∝ 倍率²）不显著；
`--jank-scroll-burst N`（把一步位移拆成 N 个事件，模拟真触控板「一帧一串」）**中性**——
burst 1/4/16 的 CPU/步 基本无差。这是个有用的否定结论：PDFKit 的响应式滚动预取不是靠「事件串」触发的。

> ⚠️ 短文档 + 大 delta 会几步滚到底，之后每步「撞底不动」、几乎不产生重活，把 `CPU/步` 稀释得像
> 「变轻了」。驱动会数出连续无位移的步数并告警；这时换更大文档或调小 delta。

### 7.2 三旋钮单变量：交错重跑，取中位数

`--jank-report 1 --jank-steps 120`，`large.pdf`，delta 1900、burst 1。**交错重跑 3 轮（round-robin）**
是为了让每个配置经历相同的机器状态，否则「后跑的更热」会被误读成「某旋钮更省」。每配置 3 次的 CPU ms/步：

| 配置 | r1 | r2 | r3 | **中位** | 相对基线 |
| --- | --- | --- | --- | --- | --- |
| 基线（投影开 / 留白开 / high） | 17.7 | 17.6 | 18.0 | **17.7** | — |
| `--pdf-page-shadows 0`（关投影） | 19.1 | 17.7 | 21.1 | 19.1 | 无收益（量在噪声内） |
| `--pdf-page-breaks 0`（关页间留白） | 19.0 | 18.9 | 18.7 | 18.9 | **更费 ~1ms** |
| `--pdf-interpolation none`（插值 none） | 17.9 | 17.1 | 17.2 | 17.2 | 略低 ~0.4ms（噪声内） |
| `--pdf-render-slim 1`（关投影 + 关留白） | 21.2 | 19.9 | 18.6 | 19.9 | **更费 ~2ms** |

读法：

- **没有任何一个旋钮把 CPU/步 降下来。** 差异全在 ±1.5ms 噪声内，且方向与「关掉更省」的预期相反。
- **关页间留白反而更费**（三轮均高于基线的三轮，不是噪声）。机制讲得通：页挨页贴在一起后，
  同样 1900px 的一步会跨过更多页，每步要光栅化的页内容更多。
- 关投影那一格方差偏大（17.7–21.1），中位 19.1 不可靠；结合 7.3 的保真结果（逐像素一致），判定它只是噪声。
- `none` 比 `high` 低约 0.4ms，在噪声内；**不值得为它牺牲正文笔画的锐度**。

> 复跑脚本在 `/tmp`（不进仓库）：交错跑 5 个配置各 3 轮，把每轮「渲染旋钮」与「驱动强度」两行汇总成表。

### 7.3 保真：改前改后同页同倍率逐像素比

`--pdf-render-report 1` 把渲染状态钉死（跳第 1 页 + `scaleFactorForSizeToFit`），再由 `--capture` 截图；
两张图交 `tools/image_diff.swift` 出「差异像素比例 / 最大通道差 / 8×8 网格差异密度」的客观读数。

```bash
BIN=dist/Lumen.app/Contents/MacOS/Lumen
# 基线（默认）、噪声地板（再跑一次基线）、只关投影、只关页间留白
$BIN --open /tmp/lumen-test/large.pdf --window-size 1400x900 --sidebar 0 --ai 0 \
     --pdf-render-report 1 --capture /tmp/r-base.png --capture-delay 8
$BIN --open /tmp/lumen-test/large.pdf --window-size 1400x900 --sidebar 0 --ai 0 \
     --pdf-render-report 1 --capture /tmp/r-base2.png --capture-delay 8
$BIN --open /tmp/lumen-test/large.pdf --window-size 1400x900 --sidebar 0 --ai 0 \
     --pdf-page-shadows 0 --pdf-render-report 1 --capture /tmp/r-noshadow.png --capture-delay 8
$BIN --open /tmp/lumen-test/large.pdf --window-size 1400x900 --sidebar 0 --ai 0 \
     --pdf-page-breaks 0 --pdf-render-report 1 --capture /tmp/r-nobreak.png --capture-delay 14
swift tools/image_diff.swift /tmp/r-base.png /tmp/r-base2.png
```

| 对比 | 差异像素 | 结论 |
| --- | --- | --- |
| 基线 vs 基线（**噪声地板**） | **0.000%** | 该工具精确到像素，非零即真差异 |
| 基线 vs 关投影 | **0.000%** | **逐像素完全一致**——这个开关在本配置（连续单页 + 适宽）下根本不起作用 |
| 基线 vs 关页间留白 | 17.5% | 页面整体上移约 22px、页间分隔消失（**观感变了**） |

两个坑：①**先做噪声地板**，同配置两次必须 0.000%，否则任何差异都不能归因给旋钮；
②**关页间留白的组合重排更慢更不稳**——`--capture-delay 8` 时抓到过「第 5 页 + 残缺拼贴」的中间态，
`--capture-delay 14` 才落定成同一张图。这本身也是「不该关它」的理由之一。

### 7.4 结论与决定

- **三个旋钮都省不下 CPU。** 瓶颈是 PDFKit 内部的整页光栅化 / 合成，不是这几个开关。
- **默认维持原样**（`PDFRenderTuning.baseline` = PDFKit 默认 + `.high`，与改造前**逐像素一致**）。
  旋钮 + 开关保留下来，作为「已证伪」的证据与日后换文档 / 换机器的复跑对照——**不是一个待生效的优化**。
- 想真正压滚动卡顿，方向应转到 **PDFKit 的预渲染范围 / 连续模式行为**，而不是这几个旋钮。

### 7.5 动态插值方案（评估：不做）

「滚动中降到 `.low`、停下后切回 `.high`」：

1. **收益微乎其微**：`none` 也只比 `high` 低 ~0.4ms，在噪声内。
2. **触发时机不可靠**：`PDFView` 没有「滚动开始 / 结束」通知，停顿判定只能靠 `NSScrollView` 的
   `boundsDidChange` + 定时器去猜；猜错就是「滚动途中字变糊 / 停下迟迟不恢复清晰」，比慢更刺眼。
3. **破坏「所见即所存」**：停下后立刻截屏 / 复制为图片，可能拿到低档渲染。

真要压最后一截，优先级应是「限制连续模式下的预渲染范围」。

---

## 八、构建产物新鲜度：读数异常先查这里

**症状**：某个自检通道的读数突然不对劲（比如新加的功能在日志里完全没出现），
先别怀疑代码——**先确认跑的是不是刚构建出来的那个 app**。

历史事故（见 `docs/LESSONS.md` #9）：`build.sh` 原先用 `rm -rf dist/Lumen.app` 清旧产物再重建，
本机的 safe-delete 守卫按「一次删除的内容文件数」拦下（一个 `.app` 有上百个文件 > 阈值 50），
`rm` 返回非零 → `set -e` 中断 → **构建没跑完、dist 还是旧的**。此时再跑自检，
日志里其实是**上一个版本**的行为，看起来却像「新功能没生效 / 改动没作用」。

现在 `build.sh`：① 组装到暂存目录、成功后 `mv` 换入（不再 `rm` 一个 `.app`）；
② 换入**前后**各校验一次「构建标记」。构建成功后最后一行会打印：

```
✅ 构建完成：.../dist/Lumen.app（7.4M），构建标记 20260918-102656-71298
```

排查两步：

```bash
# 1) dist 里是不是本次构建（应等于上面那行打印的标记）：
cat dist/Lumen.app/Contents/Resources/lumen-build-stamp
# 2) 直接问二进制里有没有你要验的那段代码——比翻构建日志更直接：
grep -c "<新功能里某条日志的字样>" dist/Lumen.app/Contents/MacOS/Lumen
```

构建失败（编译错、或产物新鲜度自检不过）时脚本会**非零退出**并明确报「dist 未更新」，
且**旧产物原封不动**——不会再出现「命令报错、dist 却被换成半个 app」这种状态。
