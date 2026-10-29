# 验证与发布门槛

更新：2026-10-30。此页记录当前有效检查方法与最新结果；历史故障原因见 [LESSONS](LESSONS.md)，发布方法见 [RELEASING](RELEASING.md)。历史本地截图、测试副本和过程日志不随源码分发。

## 本轮 v1.2.0

| 检查 | 当前结果 |
| --- | --- |
| 改前全量串行回归 | 470 项通过，58.720 秒 |
| 同步、题录、持久化及真实在线专项 | 82 项通过，29.914 秒 |
| 全量串行回归 | 484 项通过，57.675 秒；随后元数据字段删除专项补测通过 |
| 显式原生回答视口 | 此前 480 项全量含该项通过，80.181 秒；最终界面复验待解锁 |
| Zotero 运行时真实文献首次建页与重启 | 已通过；真实附件、属性及多行笔记，原 PDF 字节不变 |
| Zotero 关闭时真实文献首次建页 | PDF 与 EPUB 均通过，分别 0.954 / 0.577 秒 |
| 自动冒烟与主题 | 4 个 PDF 场景通过，正式用户 JSON 不变；5 套首页内部绘制图与对比度检查通过。EPUB 缺布局成功回执，待解锁重测 |
| 真实侧栏、Obsidian 与深链 UI | 锁屏阻塞，待解锁 |
| 真实大 PDF 触控板、内存对照 | 基线包和素材已保留；本轮尚未取得人工反馈，不判通过 |
| 更新组件 | 8 项通过，包含实际签名包核验和 worker 等待/替换/回滚测试；没有运行远端下载测试 |
| 正式包与远端发布 | 本地候选准备中；触控板与 UI 门槛未完成，未发布 GitHub |

本轮本地原始记录位于 `docs/verification/release-20261030/`（不入 Git）。状态和文献页接管前备份位于应用数据目录的 `literature-sync-backups/`，不会打入发布包。最终交付以本表更新后的实际收据为准。

## 日常回归

```bash
swift test --disable-sandbox --jobs 2 --no-parallel
LUMEN_RUN_NATIVE_LAYOUT_TESTS=1 swift test --disable-sandbox --jobs 2 --no-parallel
./build.sh release
python3 tools/run_smoke.py docs/verification/smoke
python3 -m unittest discover -s tools -p 'test_*.py'
git diff --check
```

原生视口测试需桌面解锁。冒烟检查使用合成 PDF/EPUB 和独立 `LUMEN_TEST_DATA`，覆盖最小窗口、主题、批注、对话生命周期、EPUB 布局，并检查正式用户 JSON 未被改动。模拟 AI 仅证明界面与请求协议，不证明真实模型质量。真实服务验证按需明确启用，不反复消耗付费 OCR 或绕过验证码。

同步专项覆盖：初次离线笔记、慢检索不阻塞、自动对账后关联、题录填空和用户编辑保护、多附件、重命名、重复身份、受管边界损坏、Obsidian 改写批注后的备份与恢复、字段冲突、清空正文和暂停后防抖取消。Zotero 本地库只读测试覆盖存储附件、相对/绝对链接、群组库、符号链接、同名不同文件、重复引用、已删除条目、数据库锁定和损坏。持久化覆盖不可读文件、空文件备份、两实例交错编辑与失败回滚。

真实文献只读验证：

```bash
LUMEN_RUN_ZOTERO_LOOKUP=1 LUMEN_LIVE_PDF='/absolute/path/to/paper.pdf' \
  swift test --disable-sandbox --jobs 2 --no-parallel --filter ZoteroLocalLookupLiveTests
# Zotero 正常退出后，关闭在线专属探测，仅验证首次建页：
LUMEN_LIVE_PDF='/absolute/path/to/paper.pdf' \
  swift test --disable-sandbox --jobs 2 --no-parallel \
  --filter ZoteroLocalLookupLiveTests.firstNoteUsesRealMetadataAndPreservesBidirectionalEdits
```

真实测试只在临时笔记目录生成 Markdown；修改 PDF/EPUB 批注须用副本，并核对原件哈希。不要将“接口正常”当作“UI 自动关联完成”。

## PDF 阅读硬门槛

涉及阅读器、全局主题/状态、侧栏或背景任务时，合并和发布前必须用同一代表性大 PDF 对照改前基线及最终候选：

1. 确认只有一个 Lumen 运行进程，记录可执行路径和 `Contents/Resources/lumen-build-stamp`。
2. 用真实触控板完成连续、惯性及快速滚动，检查页面空白；双指缩放、翻页、两侧面板开关与分隔线拖动。
3. 记录空闲与操作峰值内存、稳定性及用户实际感受。同步开启时也要检查后台对账。
4. 任一可感知回退未解决，不发布。静态截图、合成滚动、计时器或计数器为零不能替代真实手势。

`--jank-watch 1` 只被动记录；`--jank-report 1` 和 `--perf-report 1` 是辅助诊断。详见 [面板约束](PDF-PANELS-20260923.md) 与 [滚动约束](PDF-SCROLL-20260922.md)。所有诊断必须设置 `LUMEN_TEST_DATA`；QA 包不得注册正式 URL scheme。

## UI 与深链

五种主题都检查首页、设置、文献笔记和阅读窗口；浅色背景不得残留深色系统控件。强调按钮文字与背景对比度至少 4.5:1。星级、中文输入、多行、双链、外部编辑冲突及读写失败要核对实际落盘。

Obsidian 阅读视图检查二级“批注”、颜色圆点、页码链接；源码模式可显示必要的 `%%` 边界。通过实际点击链接核对返回文件和页码，并用 `NSWorkspace` 查询 `lumen://` 的真实处理包。旧 QA 应用移到废纸篓后仍可能被 Launch Services 选中，须同时注销原路径和废纸篓路径，再注册唯一正式包。

## 全项目健康检查

按 `nj-code-health` 检查错误吞噬、外部输入强解、持久化、重复/死代码、超长文件与分层。当前 LumenKit 没有引入 SwiftUI，没有强制类型转换，也没有 TODO/FIXME/HACK 欠账。本轮移除未采用的原文批注反向合并器和相应试验路径；旧页面样本只留在迁移测试中。

体量最大的文件为 PDFController、AIPanelView、AIChatModel、ReaderContainerView、PDFReaderView、EPUBController、PDFTranslationController、JankAudit、LaunchDiagnostics 和 ParagraphAudit。它们是后续按职责拆分的维护风险；本次不为减少行数改写已验证的 PDF 滚动热路径。静态扫描和回归通过不代表任意文献、模型及系统环境均无故障。

真实应用进程已在隔离目录中自动生成 PDF/EPUB 文献页：真实库附件自动关联，未入库论文副本保持无 Zotero 关联但照常导出；PDF 批注分别3条/7条。重启时外部作者、星级和多行笔记保持，四份正式原文哈希不变。检查文件为 `automatic offline/checks.json`。此过程未打开阅读器，也未调用手动同步；不能替代真实按钮操作。
