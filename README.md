# LumenReader（流明）

macOS 原生阅读器：**PDF + EPUB + 自接 AI**。纯 Swift / SwiftUI，无 Xcode 依赖，
无 Electron，无云端。

定位不是「又一个阅读器」，而是**给做研究的人用的阅读工具**：把「读懂一篇文献」这件事
拆成可被机器帮上的几步——结构化目录、逐节摘要、划词解释、整本总结、跨会话记忆——
并且这些 AI 能力全部走**用户自己的** OpenAI 兼容端点（BYOK），不经过任何中间服务。

```
┌──────────────┬───────────────────────────┬──────────────┐
│   侧栏       │        阅读区             │   AI 面板    │
│ 目录/智能目录 │   PDF（PDFKit）/ EPUB     │  对话/摘要   │
│ 搜索/缩略图  │   （WKWebView）           │              │
│ ← 可拖拽 →   │                           │ ← 可拖拽 →   │
└──────────────┴───────────────────────────┴──────────────┘
```

**AI 智能目录** —— 让 AI 读一遍每页开头，推断出章节结构；摘要在点开某一节时才生成。

![AI 智能目录](docs/images/smart-outline.png)

**沉浸模式**（`⌃⌘F`）—— 收起两侧面板与工具栏，正文限宽居中，底部留一条自动隐现的控制条。

![沉浸模式](docs/images/immersive.png)

---

## 30 秒上手

```bash
./build.sh              # 编译 + 组装 dist/Lumen.app + ad-hoc 签名
./build.sh release      # Release 构建
./build.sh debug run    # 编译并启动
```

首次跑之前需要知道的一件事：**`swift build` 必须带 `--disable-sandbox`**。
CommandLineTools 自带的 SwiftPM 在沙箱里编译 `Package.swift` 会报 `sandbox_apply` 失败，
而这个项目不含任何网络依赖，关掉沙箱没有任何风险。`build.sh` 已经带上了。

打开一本书：

```bash
dist/Lumen.app/Contents/MacOS/Lumen --open /path/to/book.pdf
```

配置 AI：应用内「设置 → AI」，从预设里选一家（DeepSeek / OpenAI / Kimi / 智谱 / 通义…）
填入 API Key，或者指向本机的 Ollama / LM Studio。**API Key 只进 Keychain，不落盘、不进日志。**

---

## 目录导航

| 路径 | 是什么 |
| --- | --- |
| `Sources/LumenKit/` | **引擎层**。解析、存储、AI 协议、提示词。不依赖 SwiftUI，可单独测试 |
| `Sources/LumenApp/` | **界面层**。SwiftUI 视图、窗口外壳、设置页 |
| `tools/` | 自检工具：桩服务、测试素材生成、截图取色 |
| `docs/ARCHITECTURE.md` | 模块地图、数据流、关键设计决策及理由 |
| `docs/VERIFY.md` | **自检通道手册**。这台机器上「怎么证明改动是对的」全在这里 |
| `docs/PROGRESS.md` | 批次进度、已完成 / 待办清单 |
| `docs/design/` | 两轮设计稿（`DESIGN.md` 第一轮、`DESIGN-v2.md` 第二轮） |

### 引擎层 / 界面层的分界线在哪

一句话：**`LumenKit` 不知道 SwiftUI 存在**。

- 界面层不直接碰 PDFKit —— 通过 `PDFController` / `EPUBController` 两个包装。
- 阅读区与外框通过 `ReaderBridge` 通信（唯一的通道，双向各走一半）。
- AI 调用只依赖 `AIProvider` 协议，换服务商不波及界面。

这样分层不是为了「架构好看」，而是为了**能在没有屏幕的机器上验证**：
业务逻辑只要不在 View 里，就可以用命令行走一遍并断言结果。

---

## 硬约束（踩过的坑，务必遵守）

这几条都是实测撞出来的，违反其中任何一条都会得到一个「不崩溃、不报错、但结果莫名其妙」
的状态——那是最难查的一类问题。

1. **布尔启动开关必须带值**：写 `--ocr 1`，不要写裸的 `--ocr`。
   macOS 会把命令行参数注入 `UserDefaults` 的 argument domain，裸开关后面紧跟另一个
   `-` 开头的 token 时整条参数序列会被解错，症状是 **SwiftUI 的 WindowGroup 完全不创建
   窗口**（0 窗口、不崩溃、日志干净）。详见 `LaunchDiagnostics.swift` 里 `flag(_:)` 的注释。

2. **设置解码必须逐字段容错**：`ReaderSettings` / `AISettings` / `UISettings` / `AppSettings`
   的每个字段都写成 `(try? container.decode(X.self, forKey:)) ?? 默认值`。
   否则旧 `settings.json` 缺一个键就整份解码失败，**用户的偏好被静默重置成默认值**。

3. **不要与 SwiftUI 争 `NSWindow.appearance`**：设完会被抹回 `nil`。
   要改外观就设 `NSApp.appearance`。

4. **`cacheDisplay` 渲染 `.regularMaterial` 不可靠**：离屏绘制会把材质画成一层
   不随外观变化的近白色。要判断材质 / 主题，走录屏通道（`--capture-screen 1`）
   或读日志里的 `effectiveAppearance`。详见 `docs/VERIFY.md`。

5. **给用户看的设置项若只是部分生效，属于欺骗性设计**：要么做全，要么在界面上写清边界。

6. **`.alert` 里放不了输入框**：SwiftUI macOS 的 alert actions 会忽略 `TextField`。
   需要输入就走自建卡片（见 `PageJumpPanel.swift`）。

---

## 验证这件事，为什么值得单开一份文档

开发这台机器的条件是：**没有屏幕可看**（助手无视觉通道），但**有录屏权限**。

所以「看起来对不对」不能靠肉眼，只能靠可断言的客观信号：

- 几何断言 —— 视图自己上报 frame，检查包含 / 重叠关系（`--layout-report 1`）
- 行为回读 —— 功能产物（剪贴板、磁盘文件、日志）真的读回来核对（`--run-action`）
- 规则实跑 —— 把规则喂进实现，断言输出（`--keys-report 1`）
- 真实像素 —— 录屏抓图 + 按比例取色，判深浅（`--capture-screen` + `tools/sample_pixels.swift`）
- 桩服务 —— AI 链路走本机桩服务，可重复、不烧钱（`tools/mock_openai_server.py`）

**完整手册在 [`docs/VERIFY.md`](docs/VERIFY.md)**，新增功能时请顺手补上对应的验证通道。
