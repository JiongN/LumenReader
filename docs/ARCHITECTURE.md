# 系统架构

本文件描述 2026-09-21 审计后的实现。历史推导与旧测量保存在 [原架构记录](archive/ARCHITECTURE-before-20260921-audit.md)，冲突时以当前源码和本文件为准。

## 分层与所有权

```mermaid
flowchart TD
  W[WindowManager 窗口路由] --> A[AppState 窗口与标签状态]
  A --> R[ReaderSession 每文档一份]
  R --> B[ReaderBridge 格式无关接口]
  B --> P[PDFController / PDFKit]
  B --> E[EPUBController / WKWebView]
  S[AppServices 进程共享] --> C[ConversationStore + AIChatModel]
  S --> T[SettingsStore / 快捷键 / 最近文档]
  C --> K[LumenKit AI 与网络能力]
  E --> D[LumenKit EPUB 解析与缓存]
```

- `LumenKit` 不依赖 SwiftUI，包含文档类型、EPUB、存储、AI 协议、OCR 和纯算法。
- `LumenApp` 管理主线程视图与平台框架桥接；PDFKit 文档和 WKWebView 由各控制器持有。
- `AppState` 是窗口级；`ReaderSession` 是文档级，持有 bridge、智能目录和文档任务。AI 对话是进程级共享，**不属于每个标签**。
- 多标签阅读视图以叠层宿主，但完整 PDFView/WKWebView 只保活最近两个。更早的标签保留会话与落盘位置，再次激活时重建平台视图。关闭标签集中取消文档任务、保存位置和解除 bridge 闭包；迁出为独立窗口不是关闭。

## 主要数据流

1. 打开路径 → WindowManager → AppState 创建/选择标签 → 阅读视图解析 → bridge 发布位置、目录、选区和能力。
2. AI 请求 → 捕获文档与配置快照 → 可选检索 → SSE 流 → 当前消息 → 完成时持久化。停止会同步结束当前消息；取消任务恢复后禁止刷新、清空或结束后继请求。
3. PDF 批注 → PDFKit annotation。小文件按原路径摘除搜索临时高亮、原始颜色序列化并原子写回；≥64 MiB 文件的 Lumen 自有批注按改动页快照，在独立后台 PDFDocument 中串行写入同目录临时文件，验证后原子替换。文档世代号隔离 UI 回调，文件指纹防止覆盖外部改动，退出时等待在途任务；外部来源批注仍走同步路径。
4. EPUB → ZIP 中央目录预检 → 串行解包 → 禁止外部 XML 实体 → 校验包内资源路径 → WebKit 加载。缓存按路径、文件大小和修改时间区分版本；同大小同时间替换仍可能复用旧缓存。
5. EPUB 内链按实际章节匹配，跨章时更新控制器状态再加载锚点；外链只允许显式点击的 HTTP/HTTPS/mailto，禁止远端页面替换正文。正文内容 JavaScript 默认禁用；Lumen 自己注入的用户脚本仍可运行。
6. EPUB 翻译→ WebKit 提取当前章可见段落→过滤空白、无字母和已是目标语言的内容→按设置调用 Apple 系统翻译、Microsoft 或 LLM→按索引将译文紧跟写在对应原文下方。段落识别同时覆盖语义标签与出版商常用的叶级 `div/section/article`；译文合并后批量写入 WebKit。章节、引擎、目标语言或术语表变化时会取消旧任务；标签转入后台时也会立即取消，不与前台 PDF 渲染争抢资源。

## 持久化

| 位置 | 内容 |
| --- | --- |
| `settings.json` | 界面、阅读、模型与 Agent 配置，不含 API 密钥 |
| `credentials/*.key` | 本机密钥，0700/0600 权限，未加密 |
| `conversations.json` | 所有窗口共享的历史与活动会话 |
| `recent.json` / `keybindings.json` / `memory.json` | 最近文档、快捷键、记忆 |
| `docs/<路径哈希>/` | 阅读位置、EPUB 批注、智能目录、翻译缓存 |
| 系统 Cache 目录下 `epub/` | 解包后的 EPUB，可再生 |

缺少兼容字段可回落默认值，正文或消息集合类型错误必须抛出并触发损坏备份，不能默默变空后覆盖。备份改名失败时本进程禁止通过 `PersistFile.write` 覆盖原路径并在启动窗口提示用户检查权限或空间；本次运行的相关改动可能无法保存。路径哈希不是内容标识，移动文件后不会自动找回原路径下的状态。

## UI 与功能入口

`ActionEntries` 统一部分菜单的职责与可用性；`LumenAction` 统一菜单、命令面板和快捷键。磁盘导出归文件菜单，剪贴板操作归复制入口，会话管理归 AI 头部会话菜单。PDF 与 EPUB 的对照翻译共用左侧工具栏的翻译标签，格式弹窗只保留阅读外观。仍须检查真实视图是否绕过规划表手写重复入口。

主题来自 `ReadingTheme` / `DesignTokens`，动画经 `MotionGate`，左右面板拖动按 12Hz 节拍合并即时宽度、结束后保存。分隔线有 12pt 的实际布局命中区，宽度预算会扣除两侧分隔线；PDF 拖动时保留原生 PDFView 的 `autoScales`，按约 83ms 间隔做精确适宽更新，避免逐帧让 PDFKit 重光栅化；松手立即提交最终宽度。面板显隐动画单独钉住倍率。PDF 保持原生 tile 绘制；主题通过固定视口叠层着色，不写入原文件，也不对整个 PDF 阅读面做离屏合成。macOS 26 在载入前关闭 PDFKit 自动文档分析，避免可见页变化触发后台 Vision 识别；应用的手动 OCR 独立保留。该兼容处理使用非公开运行时接口，系统升级必须复验，见 [滚动修复记录](PDF-SCROLL-20260922.md)。左右面板均可拖动，窄窗口优先保留阅读区宽度。

## 工程取舍

SwiftPM 零第三方包依赖，两个产品目标均以 Swift 6 语言模式构建。审计代码与应用同目标编译便于原生框架验证，但会增大维护面；后续可逐步迁入 App 测试目标，不能直接删除仍可运行的诊断工具。烟测要求逐项成功收据，跳过或仅输出前缀不得算通过。大型 PDF 自有批注已隔离后台写回；外部来源批注与多窗口同时编辑同一文件仍需依赖保守同步路径和文件变更保护。
