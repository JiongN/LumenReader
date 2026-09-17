import Foundation

// MARK: - 通用定位符

/// PDF 与 EPUB 的通用坐标。
///
/// AI 回答里的「引用」就是一组 Locator，点击即可跳回原文——这是把 AI 能力和
/// 阅读器真正缝合起来的关键，而不是让 AI 输出一段无法追溯的文字。
public enum DocumentLocator: Codable, Sendable, Equatable, Hashable {
    /// page 为 0-based 页索引
    case pdf(page: Int, charOffset: Int)
    /// chapterIndex 为 spine 中的序号；anchor 为可选的 CSS 选择器或元素 id
    case epub(chapterIndex: Int, anchor: String, charOffset: Int)

    public var pageIndex: Int {
        if case .pdf(let page, _) = self { return page }
        return -1
    }

    public var chapterIndex: Int {
        if case .epub(let index, _, _) = self { return index }
        return -1
    }

    /// 展示给用户的短标签，例如「第 42 页」或「第 3 章」。
    public func displayLabel(chapterTitles: [String] = []) -> String {
        switch self {
        case .pdf(let page, _):
            return "第 \(page + 1) 页"
        case .epub(let chapterIndex, _, _):
            if chapterIndex < chapterTitles.count, !chapterTitles[chapterIndex].isEmpty {
                return chapterTitles[chapterIndex]
            }
            return "第 \(chapterIndex + 1) 章"
        }
    }

    /// 用于跨会话存取的稳定字符串形式。
    public var storageKey: String {
        switch self {
        case .pdf(let page, let offset):
            return "pdf:\(page):\(offset)"
        case .epub(let chapter, let anchor, let offset):
            return "epub:\(chapter):\(anchor):\(offset)"
        }
    }

    public static func parse(storageKey: String) -> DocumentLocator? {
        let parts = storageKey.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
        guard parts.count >= 3 else { return nil }
        switch parts[0] {
        case "pdf":
            guard let page = Int(parts[1]), let offset = Int(parts[2]) else { return nil }
            return .pdf(page: page, charOffset: offset)
        case "epub":
            guard parts.count >= 4, let chapter = Int(parts[1]), let offset = Int(parts[3]) else { return nil }
            return .epub(chapterIndex: chapter, anchor: parts[2], charOffset: offset)
        default:
            return nil
        }
    }
}

// MARK: - 选区

/// 用户在阅读区选中的文本，是 AI 功能的输入单元。
public struct ReaderSelection: Sendable, Equatable {
    public var text: String
    public var locator: DocumentLocator
    /// 选区前后各一段的上下文，用于提升 AI 判断质量
    public var precedingContext: String
    public var followingContext: String

    public init(
        text: String,
        locator: DocumentLocator,
        precedingContext: String = "",
        followingContext: String = ""
    ) {
        self.text = text
        self.locator = locator
        self.precedingContext = precedingContext
        self.followingContext = followingContext
    }

    public var isUsable: Bool {
        text.trimmingCharacters(in: .whitespacesAndNewlines).count >= 2
    }

    /// 供 prompt 使用的紧凑上下文块。
    public func contextBlock(limit: Int = 1200) -> String {
        var pieces: [String] = []
        if !precedingContext.isEmpty { pieces.append("【上文】\n" + precedingContext.suffix(limit)) }
        pieces.append("【选中内容】\n" + text)
        if !followingContext.isEmpty { pieces.append("【下文】\n" + followingContext.prefix(limit)) }
        return pieces.joined(separator: "\n\n")
    }
}

// MARK: - 搜索结果

public struct SearchHit: Identifiable, Sendable, Equatable {
    public let id = UUID()
    public var snippet: String
    public var locator: DocumentLocator
    /// 用于高亮的范围（PDF 为页内字符区间，EPUB 为章节内字符区间）
    public var range: Range<Int>
    /// 匹配位置的相对权重，用于排序
    public var score: Double

    public init(snippet: String, locator: DocumentLocator, range: Range<Int>, score: Double = 1) {
        self.snippet = snippet
        self.locator = locator
        self.range = range
        self.score = score
    }
}

// MARK: - 目录

public struct OutlineNode: Identifiable, Sendable, Equatable {
    public let id: UUID
    public var title: String
    public var locator: DocumentLocator
    public var children: [OutlineNode]
    public var depth: Int

    public init(id: UUID = UUID(), title: String, locator: DocumentLocator, children: [OutlineNode] = [], depth: Int = 0) {
        self.id = id
        self.title = title
        self.locator = locator
        self.children = children
        self.depth = depth
    }

    /// 扁平化，方便在 List 里展开显示
    public var flattened: [OutlineNode] {
        [self] + children.flatMap { $0.flattened }
    }
}

// MARK: - 元数据

public struct DocumentMetadata: Sendable, Equatable {
    public var title: String
    public var author: String
    public var subject: String
    public var keywords: String
    /// 页数（EPUB 按章节数计）
    public var unitCount: Int

    public init(title: String = "", author: String = "", subject: String = "", keywords: String = "", unitCount: Int = 0) {
        self.title = title
        self.author = author
        self.subject = subject
        self.keywords = keywords
        self.unitCount = unitCount
    }

    /// 作为 AI 上下文的文档抬头。
    public var promptHeader: String {
        var lines: [String] = []
        if !title.isEmpty { lines.append("书名：\(title)") }
        if !author.isEmpty { lines.append("作者：\(author)") }
        return lines.joined(separator: "\n")
    }
}

// MARK: - 文档源协议

/// PDF 与 EPUB 统一抽象。AI 与检索层只依赖这个协议，不关心底层是 PDFKit 还是 WebKit。
public protocol DocumentSource: AnyObject {
    var kind: DocumentKind { get }
    var metadata: DocumentMetadata { get }
    var outline: [OutlineNode] { get }

    /// 取某个定位符附近的纯文本
    func text(around locator: DocumentLocator, radius: Int) -> String

    /// 全文纯文本（可能很慢，调用方负责放到后台）
    func fullText() -> String

    /// 关键词检索
    func search(_ query: String, limit: Int) -> [SearchHit]
}

public extension DocumentSource {
    func text(around locator: DocumentLocator) -> String {
        text(around: locator, radius: 1)
    }
}
