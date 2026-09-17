import Foundation

// MARK: - 数据模型

/// AI 识别出的一个目录条目。
public struct SmartOutlineEntry: Codable, Sendable, Equatable, Identifiable {

    public var id: String
    /// 章节标题
    public var title: String
    /// 起始位置：PDF 为 0-based 页索引，EPUB 为 0-based 章索引
    public var unitIndex: Int
    /// 层级。0 为顶层，1 为子节，以此类推
    public var depth: Int
    /// 该条目的摘要。
    ///
    /// `nil` 表示**还没有生成**——这是刻意的：摘要按需生成（用户点开某一节才算），
    /// 所以「没有摘要」是一个正常且常见的状态，不是一个待修复的空值。
    public var summary: String?

    public init(
        id: String = UUID().uuidString,
        title: String,
        unitIndex: Int,
        depth: Int = 0,
        summary: String? = nil
    ) {
        self.id = id
        self.title = title
        self.unitIndex = unitIndex
        self.depth = depth
        self.summary = summary
    }
}

/// 一份完整的智能目录。
public struct SmartOutline: Codable, Sendable, Equatable {

    public var entries: [SmartOutlineEntry]
    public var generatedAt: Date
    /// 生成时用的模型名。换了模型之后旧目录未必还合适，界面上要说清是谁生成的。
    public var modelName: String
    /// 生成时文档的总单元数。
    ///
    /// 存下来是为了**过期判定**：同一个文件后来被替换、页数变了，缓存就不能再用，
    /// 否则会出现「目录里的页码指向完全不相干的内容」。
    public var sourceUnitCount: Int

    public init(
        entries: [SmartOutlineEntry],
        generatedAt: Date = Date(),
        modelName: String,
        sourceUnitCount: Int
    ) {
        self.entries = entries
        self.generatedAt = generatedAt
        self.modelName = modelName
        self.sourceUnitCount = sourceUnitCount
    }

    /// 与当前文档是否仍然匹配。
    public func isValid(forUnitCount count: Int) -> Bool {
        !entries.isEmpty && sourceUnitCount == count
    }
}

// MARK: - 采样

public enum SmartOutlineDigest {

    /// 把各单元的开头摘成一段文本喂给模型。
    ///
    /// 为什么只取**开头**而不是全文：章节标题、小节编号几乎都出现在页首，
    /// 开头的信息密度远高于中部。一本书的全文动辄几十万字，全塞进去既贵又慢，
    /// 还会让模型在细节里迷路——而这一步只需要它认出「结构」，不需要读内容。
    ///
    /// 页数很多时按固定步长抽样：密度降下来，但整体结构仍然看得见。
    /// 抽样而不是简单截断前 N 页，是因为文档的章节在后半部分同样密集，
    /// 只给前半本会让模型以为这本书只有一半。
    public static func make(
        snippets: [(index: Int, text: String)],
        unitName: String,
        limitPerUnit: Int = 260,
        maxUnits: Int = 160
    ) -> String {
        guard !snippets.isEmpty else { return "" }

        let picked = sample(snippets, maxUnits: maxUnits)
        var lines: [String] = []

        for item in picked {
            let cleaned = item.text
                .replacingOccurrences(of: "\n", with: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !cleaned.isEmpty else { continue }

            let head = cleaned.count > limitPerUnit
                ? String(cleaned.prefix(limitPerUnit)) + "…"
                : cleaned
            lines.append("第 \(item.index + 1) \(unitName)：\(head)")
        }

        return lines.joined(separator: "\n")
    }

    /// 等步长抽样，并保证首尾一定在内。
    private static func sample(
        _ snippets: [(index: Int, text: String)],
        maxUnits: Int
    ) -> [(index: Int, text: String)] {
        guard snippets.count > maxUnits, maxUnits > 1 else { return snippets }

        let step = Double(snippets.count - 1) / Double(maxUnits - 1)
        var picked: [(index: Int, text: String)] = []
        var lastIndex = -1

        for i in 0..<maxUnits {
            let position = Int((Double(i) * step).rounded())
            guard position != lastIndex, position < snippets.count else { continue }
            lastIndex = position
            picked.append(snippets[position])
        }
        return picked
    }
}

// MARK: - 解析

public enum SmartOutlineParser {

    public enum ParseError: LocalizedError, Equatable {
        case emptyResponse
        case noJSONArray
        case malformed(String)
        case noUsableEntries

        public var errorDescription: String? {
            switch self {
            case .emptyResponse:
                return "模型没有返回任何内容。"
            case .noJSONArray:
                return "模型的回复里找不到 JSON 数组。"
            case .malformed(let detail):
                return "目录格式解析失败：\(detail)"
            case .noUsableEntries:
                return "模型返回的条目都不在当前文档范围内。"
            }
        }
    }

    /// 模型回复里的一条原始条目。
    private struct RawEntry: Decodable {
        let title: String
        let unit: Int?
        let page: Int?
        let depth: Int?
    }

    /// 把模型的原始回复解析成目录条目。
    ///
    /// 这一步必须**极度宽容**：即便在提示词里反复强调「只输出 JSON」，
    /// 模型仍然经常加上 ```json 围栏、来一句「好的，以下是目录：」、
    /// 或者在数组后面补一段说明。脆弱的解析会让整个功能时灵时不灵，
    /// 而用户看到的只是「生成失败」，完全无从下手。
    public static func parse(_ raw: String, unitCount: Int) throws -> [SmartOutlineEntry] {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw ParseError.emptyResponse }

        guard let jsonText = extractJSONArray(from: trimmed) else {
            throw ParseError.noJSONArray
        }

        let rawEntries: [RawEntry]
        do {
            guard let data = jsonText.data(using: .utf8) else { throw ParseError.malformed("编码异常") }
            rawEntries = try JSONDecoder().decode([RawEntry].self, from: data)
        } catch let error as ParseError {
            throw error
        } catch {
            throw ParseError.malformed(error.localizedDescription)
        }

        guard unitCount > 0 else { throw ParseError.noUsableEntries }

        var entries: [SmartOutlineEntry] = []
        for item in rawEntries {
            let title = item.title.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty else { continue }

            // 兼容 `unit` 与 `page` 两种键名：提示词里写的是 unit，
            // 但模型看到「页」这个概念时很自然会改写成 page。
            guard let oneBased = item.unit ?? item.page else { continue }

            // 越界的条目直接丢掉而不是钳制：钳制会把多个假条目全挤到最后一页，
            // 在目录里堆出一串指向同一位置的重复项，比缺几条难看得多。
            guard oneBased >= 1, oneBased <= unitCount else { continue }

            entries.append(
                SmartOutlineEntry(
                    title: title,
                    unitIndex: oneBased - 1,
                    depth: max(0, min(item.depth ?? 0, 3))
                )
            )
        }

        guard !entries.isEmpty else { throw ParseError.noUsableEntries }

        // 按位置排序，并去掉「同一位置 + 同一标题」的重复项（模型偶尔会把同级条目说两遍）
        entries.sort { lhs, rhs in
            lhs.unitIndex == rhs.unitIndex ? lhs.depth < rhs.depth : lhs.unitIndex < rhs.unitIndex
        }
        var seen = Set<String>()
        entries = entries.filter { entry in
            seen.insert("\(entry.unitIndex)|\(entry.title)").inserted
        }

        return entries
    }

    /// 从一段可能夹带杂物的文本里抠出 JSON 数组。
    ///
    /// 取「第一个 `[` 到最后一个 `]`」而不是配平括号：模型输出一个**数组**是约定，
    /// 只需要处理前后包裹的噪声。配平扫描会多出一堆分支，收益却几乎为零。
    private static func extractJSONArray(from text: String) -> String? {
        guard let start = text.firstIndex(of: "["),
              let end = text.lastIndex(of: "]"),
              start < end else { return nil }
        return String(text[start...end])
    }
}
