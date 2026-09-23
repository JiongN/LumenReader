# PDF 快速滚动卡顿定位与修复（2026-09-22）

后续结论见 [2026-09-23 面板与快速滚动修复](PDF-PANELS-20260923.md)：用户已确认面板恢复正常，隔离实时页码发布后快速滚动不再空白。以下保留 9 月 22 日的排查记录与当时状态。

## 当前状态：触控板卡顿尚未验收通过

关闭自动 Vision 分析解决了一个后台负载来源，但用户确认触控板卡顿仍存在，不能称为完整修复。失败实验与采样解释已归档到 [实验记录](archive/PDF-SCROLL-EXPERIMENTS-20260922.md)。

本轮曾移除页码/缩放条、扫描件提示条、沉浸退出按钮的 Material 背景，改为不透明主题色，并取消状态条整体透明度变化。构建 `20260922-222046-9597` 经用户真实触控板验证仍然明显卡顿，同时计时日志仍见 760–910 ms 延迟，不能作为修复保留。

下一项隔离诊断为 `--pdf-window-probe 1 --open <PDF>`：同一二进制保留生产 PDFController 和窗口样式，移除整个 SwiftUI 阅读器承载及工作区回调，直接在原生 NSView 中承载 PDFView。该模式不启动正常工作区，不保存阅读状态，不写原 PDF；它只用于定位，不能替代正式阅读界面。

原生承载已获用户真实触控板反馈“已经流畅”。日志 `docs/verification/scroll-20260922/native-host.log` 中，+26.4 至 +32.4 秒覆盖 8→0→12→14 页，四个窗口的计时延迟最大值约 0.94–1.02 ms。启动/静止段仍有孤立尖峰，不能将整份日志描述成零延迟。这说明生产 PDFController 与该窗口样式的组合可以流畅滚动，但还不能在“完整 SwiftUI 层级”和“工作区状态回调”之间归因。

添加 `--pdf-probe-host swiftui` 可保留同一 PDFController 和相同窗口参数，只将最小原生宿主换成 NSHostingController + PDFKitRepresentable，以继续缩小差异。

用户确认最小 SwiftUI 承载“同样流畅”；不能把问题归因于 NSViewRepresentable 或 SwiftUI 本身。日志保留为 `minimal-swiftui-host.log`。下一项在完整界面临时使用 `--pdf-freeze-status 1 --jank-watch 1`，仅暂停 PDF 页码回调与视口发布；页码暂不跟随滚动是该诊断的预期现象，不是正式功能。

清理了残留 `--pdf-native-surface` 分支；保留原生滚动事件处理。格式弹窗现在直接观察 SettingsStore，防止开关值变化后弹窗仍显示旧的“保持 PDF 原色”状态。

## 定位

环境：macOS 26.6.2，Apple Silicon，Release 构建。素材为用户提供的
《The platformization of primary education in The Netherlands》（Kerssens / van Dijck，2021）。

用户确认原色和主题色都卡顿。此前仅凭高 CPU 和少量 SwiftUI 刷新，将问题归为 PDFKit 光栅化，证据不足。对滚动期间（排除启动阶段）的进程采样发现：

```
PDFView visiblePagesChanged:
  PDFPageAnalyzerV2 analyzePage:withBox:requestTypes:
    VNImageRequestHandler performRequests:
      VNRecognizeDocumentsRequest
```

该自动文档识别还调用表格、表单分析；它由 PDFKit 自动触发，与应用的手动 OCR 按钮无关。主线程同时出现 Core Animation backing-store 同步等待。主题开关不能关闭这条链路。

采样文件：本地 `docs/verification/scroll-20260922/before.sample`。关闭识别后的 `analysis-off.sample` 不再包含上述识别调用栈；该次进程 footprint 为 98.7 MB，开启时为 252.5 MB。这是两个采样时刻的读数，不代表所有文档的内存上界。

## 修改

- 在 PDFView 载入文档前关闭系统自动文档分析；保留原生 PDF 页面渲染、文本层选择、链接和已有批注，以及应用明确触发的 OCR。
- macOS 26 以上使用运行时存在性检查；缺少接口时记录限制并继续正常打开 PDF。
- `--pdf-document-analysis 1` 可重新开启，用于同一构建的对照；该参数归入诊断模式，不保存用户设置。
- 滚动诊断新增 `--jank-roundtrip 1`，每 45 步反向；报告实际移动步数与累计距离，避免停在边界或浮点微小位移被当作有效滚动。

## 兼容性限制

`setDocumentAnalysisEnabled:` 是 PDFKit 当前存在但尚未公开的接口。此修复是针对 macOS 26 的兼容处理，系统升级后必须复测；不能视为 Apple 保证长期兼容的 API。若以后进入 Mac App Store 发布流程，应先替换为公开支持的方案或重新评估发布可接受性。关闭后不再依靠 PDFKit 自动生成的 OCR、表格和表单推断结果；原文件已有文字层、表单和批注不会被删除。

相关问题也有开发者在 [Apple Developer Forums](https://developer.apple.com/forums/thread/841562) 报告；这里只将其作为交叉线索，本次结论以本机采样和对照为依据。

## 验证

测试日志、截图和采样位于本地 `docs/verification/scroll-20260922/`（不入 Git）。
