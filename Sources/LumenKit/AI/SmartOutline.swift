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
    public var anchor: String?

    public init(
        id: String = UUID().uuidString,
        title: String,
        unitIndex: Int,
        depth: Int = 0,
        summary: String? = nil,
        anchor: String? = nil
    ) {
        self.id = id
        self.title = title
        self.unitIndex = unitIndex
        self.depth = depth
        self.summary = summary
        self.anchor = anchor
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
    public var sourceVersion: String?

    public init(
        entries: [SmartOutlineEntry],
        generatedAt: Date = Date(),
        modelName: String,
        sourceUnitCount: Int,
        sourceVersion: String? = nil
    ) {
        self.entries = entries
        self.generatedAt = generatedAt
        self.modelName = modelName
        self.sourceUnitCount = sourceUnitCount
        self.sourceVersion = sourceVersion
    }

    /// 与当前文档是否仍然匹配。
    public func isValid(forUnitCount count: Int) -> Bool {
        !entries.isEmpty && sourceUnitCount == count && entries.allSatisfy {
            $0.unitIndex >= 0 && $0.unitIndex < count && !$0.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }
}

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
                return "模型没有选出可核验的目录标题。"
            }
        }
    }

}
