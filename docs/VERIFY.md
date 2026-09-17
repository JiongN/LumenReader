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
| `--panel-width 400x300` | 直接设左右面板宽度（侧栏 x AI 面板）。走的是和拖拽**同一个设置项** |
| `--sidebar-tab thumbnails` | 直接把侧栏钉在某个页签（`outline` / `smartOutline` / `search` / `thumbnails`） |
| `--immersive 1` | 启动即进沉浸模式，走真实入口 `setImmersive` |
| `--demo-selection 1` | 塞一段假选区（正常要鼠标划词才能触发，没有辅助功能权限） |

### 行为

| 开关 | 用途 |
| --- | --- |
| `--run-action copyFullText` | 按一次指定动作，然后把**剪贴板**回读出来 |
| `--auto-confirm 1` | 自动点掉确认框（配合 `--run-action`，否则验不到确认之后那半条链路） |
| `--jump-to 42` | 跳到第 N 个单元（1-based），打「跳转前 / 请求 / 跳转后」三段 |
| `--thumb-report 1` | 打印缩略图的渲染与跳过明细（证明滚出可视区的页不再渲染） |
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
| `--keys-report 1` | 打印快捷键表 + 撞车检查 + 实跑一遍改绑规则 |
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

需要新控件被审到时，在视图上加 `.layoutProbe("名字")`——它只在 `--layout-report 1`
时才挂 `GeometryReader`，正常启动零开销。

> ⚠️ **布局 dump 是「首次上报后 2 秒」统一打印**，所以 `--capture-delay` 必须留够余量，
> 否则进程会在 dump 之前就退出，日志里一条布局都没有——看起来像"探针没生效"，
> 实际是抢跑。EPUB 走 WebKit，阅读容器出现得比 PDF 晚，实测 `--capture-delay 8` 才稳。
> 判据很简单：日志里没有 `[Lumen][layout] 窗口内容区 …` 就是没 dump 成，不是布局有问题。

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
