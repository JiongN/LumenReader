import AppKit
import UniformTypeIdentifiers
import LumenKit

/// AI 结果的导出。
///
/// 只做 Markdown：阅读笔记的归宿通常是 Obsidian / Logseq 这类纯文本库，
/// 导成 .docx 反而会在中转站里卡住。带上元数据头部与对话附录，
/// 是为了让这份文件在几个月后自己还说得清「这是从哪本书、什么时候、基于哪次对话生成的」。
enum ExportService {

    /// 把整段对话导出成 Markdown（不带摘要，适合留档）。
    @MainActor
    static func exportTranscript(
        documentTitle: String,
        metadata: DocumentMetadata,
        transcript: [AIChatModel.Bubble]
    ) {
        let markdown = buildMarkdown(
            documentTitle: documentTitle,
            metadata: metadata,
            transcript: transcript
        )
        save(markdown, suggestedName: "\(safeFileName(documentTitle)) 对话.md")
    }

    // MARK: - 生成内容

    static func buildMarkdown(
        documentTitle: String,
        metadata: DocumentMetadata,
        transcript: [AIChatModel.Bubble]
    ) -> String {
        var out: [String] = []
        let sources = Array(Set(transcript.flatMap { bubble in
            bubble.evidence.map(\.path) + (bubble.sourceDocPath.map { [$0] } ?? [])
        })).sorted()
        let title = sources.count > 1 ? "多文档对话" : sources.first.map {
            URL(fileURLWithPath: $0).deletingPathExtension().lastPathComponent
        } ?? documentTitle

        out.append("# 《\(title)》对话记录")
        out.append("")

        var facts: [String] = []
        // Current reader metadata may belong to a different document than the conversation.
        if sources.isEmpty {
            if !metadata.author.isEmpty { facts.append("作者：\(metadata.author)") }
            if metadata.unitCount > 0 { facts.append("篇幅：\(metadata.unitCount) 页/章") }
        }
        facts.append("导出时间：\(timestamp())")
        out.append("> " + facts.joined(separator: " ｜ "))
        out.append("")
        if !sources.isEmpty {
            out.append("## 材料来源")
            out.append("")
            out.append(contentsOf: sources.map { "- \($0)" })
            out.append("")
        }

        let dialogue = transcript.filter { $0.role != .notice && !$0.failed }
        if !dialogue.isEmpty {
            out.append("---")
            out.append("")
            out.append("## 对话记录")
            out.append("")

            var turn = 0
            for bubble in dialogue {
                switch bubble.role {
                case .user:
                    turn += 1
                    out.append("### \(turn). 提问")
                    out.append("")
                    out.append(bubble.text)
                    out.append("")
                case .assistant:
                    out.append("**回答**")
                    out.append("")
                    if !bubble.coverage.isEmpty {
                        out.append("_材料覆盖：\(bubble.coverage)_")
                        out.append("")
                    }
                    let verified = bubble.evidence.filter { bubble.text.contains($0.id) }
                    if !verified.isEmpty {
                        out.append("_可核对定位：" + verified.map {
                            "\(URL(fileURLWithPath: $0.path).lastPathComponent) · \($0.label) · \($0.id)"
                        }.joined(separator: "；") + "_")
                        out.append("")
                    }
                    out.append(WholeAnswerCoverage.visibleAnswer(bubble.text))
                    out.append("")
                    if let references = bubble.answerEvidence, !references.isEmpty {
                        for source in references {
                            out.append("[原文\(source.number ?? 0)] \(URL(fileURLWithPath: source.path).lastPathComponent) · \(source.label)")
                            out.append("> \((source.quote ?? "").replacingOccurrences(of: "\n", with: "\n> "))")
                            out.append("")
                        }
                    } else if bubble.answerEvidence == nil && !bubble.citations.isEmpty {
                        let refs = bubble.citations.map { "`\($0.displayLabel())`" }.joined(separator: "、")
                        out.append("_引用：\(refs)_")
                        out.append("")
                    }
                case .notice:
                    break
                }
            }
        }

        return out.joined(separator: "\n")
    }

    private static func timestamp() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter.string(from: Date())
    }

    /// 文件名的兜底清理：标题里出现 `/` 或 `:` 会让保存面板拿到一个非法名字。
    private static func safeFileName(_ raw: String) -> String {
        let cleaned = raw
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? "未命名文档" : cleaned
    }

    // MARK: - 落盘

    @MainActor
    private static func save(_ markdown: String, suggestedName: String) {
        let panel = NSSavePanel()
        panel.title = "导出为 Markdown"
        panel.nameFieldStringValue = suggestedName
        panel.canCreateDirectories = true
        if let md = UTType(filenameExtension: "md") {
            panel.allowedContentTypes = [md]
        }
        panel.allowsOtherFileTypes = true

        guard panel.runModal() == .OK, let url = panel.url else { return }

        do {
            try Data(markdown.utf8).write(to: url, options: .atomic)
            // 写到哪儿了要让人一眼看到：直接选中该文件，比弹一个「已保存」的对话框更省事
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } catch {
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "导出失败"
            alert.informativeText = error.localizedDescription
            alert.addButton(withTitle: "好")
            alert.runModal()
        }
    }
}
