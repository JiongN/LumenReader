import SwiftUI

/// 轻量 Markdown 渲染。
///
/// 没有引第三方 Markdown 库，因为 AI 回复需要的排版其实很窄——段落、项目符号、
/// 粗体斜体、行内代码、代码块——而完整实现（如 swift-markdown）遇到流式输出中
/// 「尚未闭合的 `**` 或 ` ``` `」时容易整段解析失败，恰恰是流式场景最不能接受的。
/// 这里对未闭合标记一律按普通文本处理，边吐边渲染始终稳定。
struct MarkdownText: View {

    let text: String
    var textColor: Color = DS.Palette.textPrimary
    var accent: Color = DS.Palette.accent

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.s) {
            ForEach(Self.parse(text)) { block in
                view(for: block)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func view(for block: Block) -> some View {
        switch block.kind {
        case .heading(let level, let content):
            Text(inline(content))
                .font(DS.Typo.ui(size: level <= 2 ? 14.5 : 13.5, weight: .semibold))
                .foregroundStyle(textColor)
                .padding(.top, DS.Space.xxs)

        case .paragraph(let content):
            Text(inline(content))
                .font(DS.Typo.aiBody)
                .foregroundStyle(textColor)
                .lineSpacing(4)
                .fixedSize(horizontal: false, vertical: true)

        case .bullets(let items):
            VStack(alignment: .leading, spacing: DS.Space.xs) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    HStack(alignment: .firstTextBaseline, spacing: DS.Space.s) {
                        Circle()
                            .fill(accent.opacity(0.55))
                            .frame(width: 4, height: 4)
                            .padding(.top, 6)
                        Text(inline(item))
                            .font(DS.Typo.aiBody)
                            .foregroundStyle(textColor)
                            .lineSpacing(4)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }

        case .numbered(let items):
            VStack(alignment: .leading, spacing: DS.Space.xs) {
                ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                    HStack(alignment: .firstTextBaseline, spacing: DS.Space.s) {
                        Text("\(index + 1).")
                            .font(DS.Typo.ui(size: 12, weight: .semibold, design: .rounded))
                            .foregroundStyle(accent)
                            .frame(minWidth: 15, alignment: .trailing)
                        Text(inline(item))
                            .font(DS.Typo.aiBody)
                            .foregroundStyle(textColor)
                            .lineSpacing(4)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }

        case .code(let content):
            ScrollView(.horizontal, showsIndicators: false) {
                Text(content)
                    .font(DS.Typo.ui(size: 11.5, design: .monospaced))
                    .foregroundStyle(textColor)
                    .textSelection(.enabled)
                    .padding(DS.Space.s)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: DS.Radius.s, style: .continuous)
                    .fill(DS.Palette.surfaceSunken)
            )
        }
    }

    private func inline(_ source: String) -> AttributedString {
        (try? AttributedString(
            markdown: source,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        )) ?? AttributedString(source)
    }

    // MARK: - 解析

    struct Block: Identifiable {
        enum Kind: Equatable {
            case heading(Int, String)
            case paragraph(String)
            case bullets([String])
            case numbered([String])
            case code(String)
        }
        let id: Int
        let kind: Kind
    }

    static func parse(_ text: String) -> [Block] {
        var blocks: [Block] = []
        var counter = 0
        var paragraph: [String] = []
        var bullets: [String] = []
        var numbered: [String] = []
        var codeLines: [String] = []
        var inCode = false

        func nextID() -> Int {
            counter += 1
            return counter
        }

        func flushParagraph() {
            guard !paragraph.isEmpty else { return }
            let joined = joinParagraph(paragraph)
            if !joined.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                blocks.append(Block(id: nextID(), kind: .paragraph(joined)))
            }
            paragraph = []
        }

        func flushBullets() {
            guard !bullets.isEmpty else { return }
            blocks.append(Block(id: nextID(), kind: .bullets(bullets)))
            bullets = []
        }

        func flushNumbered() {
            guard !numbered.isEmpty else { return }
            blocks.append(Block(id: nextID(), kind: .numbered(numbered)))
            numbered = []
        }

        func flushCode() {
            guard !codeLines.isEmpty else { return }
            blocks.append(Block(id: nextID(), kind: .code(codeLines.joined(separator: "\n"))))
            codeLines = []
        }

        for rawLine in text.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)

            if line.hasPrefix("```") {
                if inCode {
                    flushCode()
                    inCode = false
                } else {
                    flushParagraph(); flushBullets(); flushNumbered()
                    inCode = true
                }
                continue
            }

            if inCode {
                codeLines.append(rawLine)
                continue
            }

            if line.isEmpty {
                flushParagraph(); flushBullets(); flushNumbered()
                continue
            }

            if let match = headingLevel(line) {
                flushParagraph(); flushBullets(); flushNumbered()
                blocks.append(Block(id: nextID(), kind: .heading(match.level, match.content)))
                continue
            }

            if line.hasPrefix("- ") || line.hasPrefix("* ") || line.hasPrefix("• ") {
                flushParagraph(); flushNumbered()
                bullets.append(String(line.dropFirst(2)))
                continue
            }

            if let content = numberedContent(line) {
                flushParagraph(); flushBullets()
                numbered.append(content)
                continue
            }

            flushBullets(); flushNumbered()
            paragraph.append(line)
        }

        // 流式输出时的收尾：代码块未闭合也照常渲染，不要把它吞掉
        if inCode { flushCode() }
        flushParagraph(); flushBullets(); flushNumbered()

        return blocks
    }

    private static func headingLevel(_ line: String) -> (level: Int, content: String)? {
        guard line.hasPrefix("#") else { return nil }
        let hashes = line.prefix { $0 == "#" }
        guard hashes.count <= 6 else { return nil }
        let content = line.dropFirst(hashes.count).trimmingCharacters(in: .whitespaces)
        guard !content.isEmpty else { return nil }
        return (hashes.count, content)
    }

    private static func numberedContent(_ line: String) -> String? {
        guard let dot = line.firstIndex(of: "."),
              dot > line.startIndex,
              line[line.startIndex..<dot].allSatisfy(\.isNumber) else { return nil }
        let rest = line[line.index(after: dot)...].trimmingCharacters(in: .whitespaces)
        return rest.isEmpty ? nil : rest
    }

    /// 合并同一个段落里的多行。
    /// 中文之间不插空格，否则会出现「这是 一句 中文」这种断字；拉丁文字之间补空格。
    private static func joinParagraph(_ lines: [String]) -> String {
        var result = ""
        for line in lines {
            guard let last = result.last, let first = line.first else {
                result += line
                continue
            }
            if isCJK(last) && isCJK(first) {
                result += line
            } else {
                result += " " + line
            }
        }
        return result
    }

    private static func isCJK(_ character: Character) -> Bool {
        guard let scalar = character.unicodeScalars.first else { return false }
        switch scalar.value {
        case 0x3000...0x303F,   // CJK 标点
             0x3400...0x4DBF,   // 扩展 A
             0x4E00...0x9FFF,   // 基本区
             0xF900...0xFAFF,   // 兼容表意
             0xFF00...0xFFEF:   // 全角
            return true
        default:
            return false
        }
    }
}
