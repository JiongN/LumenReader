import SwiftUI
import AppKit
import LumenKit

// MARK: - 全文抽取的数据形状

/// 一次全文抽取的结果与来源构成。
///
/// 为什么要记来源：扫描件复制出来的文本必然带 OCR 错字，提示里应当说清
/// 「这段文字是识别来的」，而不是让用户以为原文就是错的。
struct DocumentTextReport {
    var text: String = ""
    /// 文档总页数（EPUB 为章数），用来算「有几页没拿到」
    var totalUnits: Int = 0
    /// 有文本层可用的页数
    var textLayerUnits: Int = 0
    /// 靠 OCR 拿到的页数
    var ocrUnits: Int = 0

    var isEmpty: Bool { text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    var usedOCR: Bool { ocrUnits > 0 }
    /// 既没有文本层、也没有识别结果的页数
    var missingUnits: Int { max(0, totalUnits - textLayerUnits - ocrUnits) }
}

/// 抽取进度。
struct TextExtractionProgress {
    var completed: Int
    var total: Int
    /// 正在做什么，例如「正在识别第 12 / 300 页」
    var phase: String
}

// MARK: - 复制

extension AppState {

    /// 复制全文为纯文本。
    ///
    /// 扫描件会先问一句再用 OCR 补齐：一本 300 页的扫描书逐页识别要几分钟，
    /// 这个决定必须由用户来做，而不是点一下「复制」就静默跑上几分钟。
    func copyFullText() {
        guard let document else {
            showToast("还没有打开文档", isError: true)
            return
        }
        guard bridge.extractFullText != nil else {
            showToast("文档还在解析，稍后再试", isError: true)
            return
        }
        guard fullTextTask == nil else { return }

        if bridge.isScannedDocument {
            presentConfirmation(
                title: "这本 \(document.kind.displayName) 是扫描版",
                message: """
                它没有文本层，复制全文需要先逐页做文字识别。
                识别在本机完成，不联网；按当前速度大约需要 \(Self.spellOut(seconds: estimatedOCRSeconds))。\
                识别结果会缓存，之后再复制就很快。
                """,
                confirmTitle: "识别并复制"
            ) { [weak self] in
                self?.runFullTextExtraction(allowOCR: true)
            }
            return
        }

        runFullTextExtraction(allowOCR: false)
    }

    /// 把当前文档的原文件放进剪贴板，可在访达里直接粘贴。
    func copyDocumentFileToPasteboard() {
        guard let document else {
            showToast("还没有打开文档", isError: true)
            return
        }
        let url = document.url
        guard FileManager.default.fileExists(atPath: url.path) else {
            presentAlert(
                title: "文件不在了",
                message: "找不到 \(url.path)\n\n它可能已被移动或删除，所以无法复制。"
            )
            return
        }

        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        // 写 NSURL 而不是自己拼 NSFilenamesPboardType 字符串：AppKit 会同时写入
        // public.file-url 与旧的 plist 形式，访达、终端、第三方拖放目标都认。
        if pasteboard.writeObjects([url as NSURL]) {
            showToast("已复制「\(url.lastPathComponent)」，可在访达中粘贴")
        } else {
            showToast("复制文件失败", isError: true)
        }
    }

    private func runFullTextExtraction(allowOCR: Bool) {
        guard let extract = bridge.extractFullText, let document else { return }

        let title = allowOCR ? "识别并复制全文" : "提取全文"
        busy = BusyState(title: title, detail: "准备中…", progress: 0)

        let task = Task { @MainActor [weak self] in
            guard let self else { return }

            let report = await extract(allowOCR) { progress in
                self.busy = BusyState(
                    title: title,
                    detail: progress.phase,
                    progress: progress.total > 0
                        ? Double(progress.completed) / Double(progress.total)
                        : nil
                )
            }

            // 先收掉进度卡片，再决定是报成功还是报错——否则 alert 会和卡片叠在一起
            self.fullTextTask = nil
            self.busy = nil
            self.busyCancel = nil

            guard !Task.isCancelled else { return }
            self.deliver(report: report, documentTitle: document.displayTitle)
        }

        fullTextTask = task
        busyCancel = { [weak self] in
            task.cancel()
            Task { @MainActor in
                self?.fullTextTask = nil
                self?.busy = nil
                self?.busyCancel = nil
                self?.showToast("已取消全文提取")
            }
        }
    }

    private func deliver(report: DocumentTextReport, documentTitle: String) {
        guard !report.isEmpty else {
            presentAlert(
                title: "没有可复制的正文",
                message: """
                「\(documentTitle)」里没有提取到任何文字。

                如果这是一本扫描件，可以先用阅读区顶部的「识别本页文字」，
                或从 AI 面板发起整书总结——它们都会把识别结果缓存下来。
                """
            )
            return
        }

        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(report.text, forType: .string)

        showToast(ToastText.fullText(report))
    }

    /// 扫描件的耗时预估。按每页 1.6 秒算（实测 2 倍图 + `.accurate` 的典型值）。
    var estimatedOCRSeconds: Int {
        Int(Double(max(bridge.unitCount, 1)) * 1.6)
    }

    /// 把秒数说成人话。不给假精度：用户要的是量级，不是 287 秒。
    static func spellOut(seconds: Int) -> String {
        if seconds < 60 { return "\(max(seconds, 5)) 秒" }
        let minutes = Int((Double(seconds) / 60).rounded(.up))
        return "\(minutes) 分钟"
    }
}

/// 轻提示文案集中在一处，便于统一核对语气与信息量。
enum ToastText {

    static func fullText(_ report: DocumentTextReport) -> String {
        var parts: [String] = ["已复制全文"]

        if report.usedOCR {
            parts.append("其中 \(report.ocrUnits) 页来自文字识别，可能含错字")
        }
        if report.missingUnits > 0 {
            parts.append("有 \(report.missingUnits) 页没有文字")
        }
        parts.append("共 \(report.text.count.formatted()) 字")

        return parts.joined(separator: " · ")
    }
}
