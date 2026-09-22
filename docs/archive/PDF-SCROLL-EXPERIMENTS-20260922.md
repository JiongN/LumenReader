# PDF 触控板实验归档（2026-09-22）

用户反馈：触控板和惯性滚动卡顿，滚动条拖动正常。以下为用户提供的实验汇总；不是现行功能或性能承诺。

| 实验 | 用户提供的结果 | 当前处理 |
| --- | --- | --- |
| 修改系统私有滚动类 IMP，退出响应式滚动 | 崩溃 | 不保留 |
| 蒙层 drawingGroup 位图化 | 最大停顿 763/798/863 ms | 不保留 |
| 合并滚轮事件、自管滚动 | 最大停顿 749/866/868 ms | 不保留 |
| 去掉 PDF 外层 opacity/compositingGroup | 最大停顿 750/747/882/867 ms | 移除残留 native-surface 分支 |
| 移除阅读区外层常驻 Material 背景 | 用户实测仍明显卡顿；日志仍见 760–910 ms | 不作为有效修复 |

前四项没有移除阅读区外层常驻控件的 Material 背景；第五项补测仍失败，不再沿这一候选反复调整。

本机留存 `/tmp/lumen-focus2.sample`：主线程共有 37277 个样本，其中一个 backing-store 同步等待分支包含 3785 个样本。这是累计采样数，不是 3785 次调用，也不能由此确定单次等待 743–883 ms。计时器最长延迟与调用栈累计采样需要时间关联才能归因。

`/tmp/lumen-preview.sample` 也包含 `_NSScrollingConcurrentMainThreadSynchronizer`，没有采到 `wait_for_synchronize`。因此并发滚动同步器本身并不是足以判错的条件；应查 Lumen 中需要更新并等待的具体图层。

RenderBox 在这些堆栈中由 SwiftUI CGDrawingLayer 调用，不是 EPUB/WebKit 存在的证据。主线程等待事件的样本不能计为忙碌 CPU。

旧整块/仅蒙层合成实验曾存在 `pdf-flat-surface` 参数缺少 `--` 的错误；未证明开关实际生效的历史对照不参与结论。
