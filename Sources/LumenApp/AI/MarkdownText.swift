import SwiftUI
import LumenKit

/// 轻量 Markdown 渲染。
///
/// Foundation parses Markdown off the main thread. Prose shares one native
/// layout per section; wide tables and code keep their horizontal scrollers.
struct MarkdownText: View {

    let text: String
    var textColor: Color = DS.Palette.textPrimary
    var accent: Color = DS.Palette.accent
    var fontSize: CGFloat = 14.5
    var evidence: [DocumentCitation] = []
    var isStreaming: Bool
    @State private var parsed: [Block]?
    @State private var parsedSource: String?

    init(text: String, textColor: Color = DS.Palette.textPrimary,
         accent: Color = DS.Palette.accent, fontSize: CGFloat = 14.5,
         evidence: [DocumentCitation] = [], isStreaming: Bool = false) {
        self.text = text
        self.textColor = textColor
        self.accent = accent
        self.fontSize = fontSize
        self.evidence = evidence
        self.isStreaming = isStreaming
        let cached = isStreaming ? nil : Self.parsedCache.object(forKey: text as NSString)?.blocks
        _parsed = State(initialValue: cached)
        _parsedSource = State(initialValue: cached == nil ? nil : text)
    }

    private final class CachedBlocks {
        let blocks: [Block]
        init(_ blocks: [Block]) { self.blocks = blocks }
    }

    private static let parsedCache: NSCache<NSString, CachedBlocks> = {
        let cache = NSCache<NSString, CachedBlocks>()
        cache.countLimit = 24
        cache.totalCostLimit = 8 * 1024 * 1024
        return cache
    }()

    var body: some View {
        let ready = !isStreaming && parsedSource == text
        let sections = ready ? Self.sections(parsed ?? []) : [Section(id: 0, kind: .prose([]))]
        VStack(alignment: .leading, spacing: DS.Space.s) {
            ForEach(sections) { section in
                switch section.kind {
                case .prose(let blocks):
                    NativeAnswerText(text: text, blocks: ready ? blocks : nil, fontSize: fontSize,
                        textColor: textColor, accent: accent, evidence: evidence)
                        .frame(maxWidth: .infinity, alignment: .leading)
                case .code(let content): codeView(content)
                case .table(let table): tableView(table)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .tint(accent)
        .task(id: isStreaming ? nil : text) {
            guard !isStreaming else { return }
            let source = text
            if parsedSource == source, parsed != nil { return }
            if let cached = Self.parsedCache.object(forKey: source as NSString) {
                parsed = cached.blocks
                parsedSource = source
                return
            }
            let blocks = await Task.detached(priority: .utility) { Self.parse(source) }.value
            guard !Task.isCancelled else { return }
            Self.parsedCache.setObject(CachedBlocks(blocks), forKey: source as NSString,
                                       cost: source.utf8.count * 3)
            parsed = blocks
            parsedSource = source
        }
    }

    struct Section: Identifiable {
        enum Kind { case prose([Block]), code(String), table(Table) }
        var id: Int
        var kind: Kind
    }

    static func sections(_ blocks: [Block]) -> [Section] {
        var result: [Section] = [], prose: [Block] = []
        func flush() {
            guard !prose.isEmpty else { return }
            result.append(.init(id: result.count, kind: .prose(prose)))
            prose = []
        }
        for block in blocks {
            switch block.kind {
            case .code(let code): flush(); result.append(.init(id: result.count, kind: .code(code)))
            case .table(let table): flush(); result.append(.init(id: result.count, kind: .table(table)))
            default: prose.append(block)
            }
        }
        flush()
        return result
    }

    private func codeView(_ content: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            ScrollView(.horizontal, showsIndicators: false) {
                Text(String(content.prefix(8000)))
                    .font(DS.Typo.readingPanel(size: max(11, fontSize - 2), design: .monospaced))
                    .foregroundStyle(textColor)
                    .textSelection(.enabled)
                    .frame(maxWidth: 1000, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(DS.Space.s)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: DS.Radius.s, style: .continuous)
                    .fill(DS.Palette.surfaceSunken)
            )
            if content.count > 8000 {
                Text("代码预览 · 前 8,000 字")
                    .font(DS.Typo.ui(size: 10.5)).foregroundStyle(DS.Palette.textTertiary)
            }
        }
    }

    private func tableView(_ table: Table) -> some View {
            ScrollView(.horizontal) {
                VStack(alignment: .leading, spacing: 0) {
                    tableRow(table.header, alignments: table.alignments, header: true)
                        .background(DS.Palette.surfaceSunken)
                    ForEach(Array(table.rows.enumerated()), id: \.offset) { _, row in
                        Divider()
                        tableRow(row, alignments: table.alignments, header: false)
                    }
                }
                .fixedSize(horizontal: true, vertical: false)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func tableRow(_ cells: [String], alignments: [Table.ColumnAlignment], header: Bool) -> some View {
        HStack(alignment: .top, spacing: 0) {
            ForEach(cells.indices, id: \.self) { index in
                let alignment = alignments[index]
                Text(inline(cells[index]))
                    .font(DS.Typo.readingPanel(size: fontSize))
                    .fontWeight(header ? .semibold : .regular)
                    .foregroundStyle(textColor)
                    .multilineTextAlignment(alignment == .center ? .center : alignment == .trailing ? .trailing : .leading)
                    .frame(width: 160, alignment: alignment == .center ? .center : alignment == .trailing ? .trailing : .leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(8)
            }
        }
    }

    private func inline(_ source: String) -> AttributedString {
        let value = (try? AttributedString(
            markdown: source,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        )) ?? AttributedString(source)
        return InlineEvidenceLink.render(value, sources: evidence)
    }

    // MARK: - 解析

    struct Table: Equatable, Sendable {
        enum ColumnAlignment: Equatable, Sendable { case leading, center, trailing }
        var header: [String]
        var alignments: [ColumnAlignment]
        var rows: [[String]]
    }

    struct Block: Identifiable, Sendable {
        enum Kind: Equatable, Sendable {
            case heading(Int, AttributedString)
            case paragraph(AttributedString)
            case listItem(marker: String, depth: Int, showsMarker: Bool, content: AttributedString)
            case code(String)
            case table(Table)
        }
        let id: Int
        let kind: Kind
    }

    nonisolated static func parse(_ text: String) -> [Block] {
        var blocks: [Block] = []
        var counter = 0
        var markup: [String] = []
        var codeLines: [String] = []
        var inCode = false

        func nextID() -> Int {
            counter += 1
            return counter
        }

        func flushMarkup() {
            guard !markup.isEmpty else { return }
            for kind in markupBlocks(markup.joined(separator: "\n")) {
                blocks.append(Block(id: nextID(), kind: kind))
            }
            markup = []
        }

        func flushCode() {
            guard !codeLines.isEmpty else { return }
            blocks.append(Block(id: nextID(), kind: .code(codeLines.joined(separator: "\n"))))
            codeLines = []
        }

        let lines = text.components(separatedBy: .newlines)
        var lineIndex = 0
        while lineIndex < lines.count {
            let rawLine = lines[lineIndex]
            lineIndex += 1
            let line = rawLine.trimmingCharacters(in: .whitespaces)

            if line.hasPrefix("```") {
                if inCode {
                    flushCode()
                    inCode = false
                } else {
                    flushMarkup()
                    inCode = true
                }
                continue
            }

            if inCode {
                codeLines.append(rawLine)
                continue
            }

            if lineIndex < lines.count, let header = tableCells(line), (2...12).contains(header.count),
               let parsedAlignments = tableAlignments(lines[lineIndex]),
               parsedAlignments.count == header.count || parsedAlignments.count == header.count + 1 {
                flushMarkup()
                lineIndex += 1
                let alignments = Array(parsedAlignments.prefix(header.count))
                var rows: [[String]] = []
                while lineIndex < lines.count, rows.count < 200,
                      let cells = tableCells(lines[lineIndex]), cells.count <= header.count {
                    rows.append(cells + Array(repeating: "", count: header.count - cells.count))
                    lineIndex += 1
                }
                blocks.append(Block(id: nextID(), kind: .table(Table(header: header, alignments: alignments, rows: rows))))
                continue
            }

            if line.hasPrefix("• ") {
                markup.append(String(rawLine.prefix(while: \.isWhitespace)) + "- " + line.dropFirst(2))
            } else { markup.append(rawLine) }
        }

        // 流式输出时的收尾：代码块未闭合也照常渲染，不要把它吞掉
        if inCode { flushCode() }
        flushMarkup()

        return blocks
    }

    nonisolated private static func tableAlignments(_ line: String) -> [Table.ColumnAlignment]? {
        guard let cells = tableCells(line) else { return nil }
        var result: [Table.ColumnAlignment] = []
        for cell in cells {
            var dashes = cell[...]
            if dashes.first == ":" { dashes = dashes.dropFirst() }
            if dashes.last == ":" { dashes = dashes.dropLast() }
            guard dashes.count >= 3, dashes.allSatisfy({ $0 == "-" }) else { return nil }
            result.append(cell.hasSuffix(":") ? (cell.hasPrefix(":") ? .center : .trailing) : .leading)
        }
        return result
    }

    nonisolated private static func tableCells(_ line: String) -> [String]? {
        let characters = Array(line.trimmingCharacters(in: .whitespaces))
        var cells: [String] = [], cell = "", index = 0, codeDelimiter = 0
        var escaped = false
        while index < characters.count {
            let character = characters[index]
            index += 1
            if escaped {
                if character == "|" { cell.removeLast() }
                cell.append(character); escaped = false
            } else if character == "\\" {
                cell.append(character); escaped = true
            } else if character == "`" {
                var count = 1
                while index < characters.count && characters[index] == "`" { count += 1; index += 1 }
                if codeDelimiter == 0 { codeDelimiter = count }
                else if codeDelimiter == count { codeDelimiter = 0 }
                cell += String(repeating: "`", count: count)
            } else if character == "|" && codeDelimiter == 0 {
                cells.append(cell); cell = ""
            } else { cell.append(character) }
        }
        guard !cells.isEmpty else { return nil }
        cells.append(cell)
        if characters.first == "|", cells.first == "" { cells.removeFirst() }
        if characters.last == "|", cells.last == "" { cells.removeLast() }
        return cells.map { $0.trimmingCharacters(in: .whitespaces) }
    }

    nonisolated private static func markupBlocks(_ source: String) -> [Block.Kind] {
        guard var parsed = try? AttributedString(markdown: source) else {
            return [.paragraph(AttributedString(source))]
        }
        // Foundation keeps soft line breaks as spaces; do not split CJK words.
        for run in Array(parsed.runs).reversed() where run.inlinePresentationIntent?.contains(.softBreak) == true {
            let range = run.range
            let before = range.lowerBound > parsed.startIndex ? parsed.characters[parsed.characters.index(before: range.lowerBound)] : nil
            let after = range.upperBound < parsed.endIndex ? parsed.characters[range.upperBound] : nil
            if let before, let after, isCJK(before), isCJK(after) {
                parsed.replaceSubrange(range, with: AttributedString(""))
            } else {
                let remaining = run.inlinePresentationIntent?.subtracting(.softBreak)
                parsed[range].inlinePresentationIntent = remaining?.isEmpty == true ? nil : remaining
            }
        }
        var groups: [(intent: PresentationIntent?, content: AttributedString)] = []
        for run in parsed.runs {
            let intent = run.presentationIntent
            var content = AttributedString(parsed[run.range])
            content.presentationIntent = nil
            if let last = groups.last, last.intent == intent {
                groups[groups.count - 1].content.append(content)
            } else { groups.append((intent, content)) }
        }
        var seenItems = Set<Int>()
        return groups.map { group in
            let components = group.intent?.components ?? []
            let depth = components.filter { $0.kind == .orderedList || $0.kind == .unorderedList }.count
            if let index = components.firstIndex(where: { if case .listItem = $0.kind { return true }; return false }),
               case .listItem(let ordinal) = components[index].kind {
                let ordered = components.dropFirst(index + 1).first?.kind == .orderedList
                return .listItem(marker: ordered ? "\(ordinal)." : "•", depth: depth,
                                 showsMarker: seenItems.insert(components[index].identity).inserted, content: group.content)
            }
            if case .header(let level) = components.first?.kind {
                return .heading(level, group.content)
            }
            return .paragraph(group.content)
        }
    }

    nonisolated private static func isCJK(_ character: Character) -> Bool {
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
