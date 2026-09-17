import Foundation
import Combine

/// 一条跨会话记忆。
///
/// 刻意做成「条目」而不是一坨自由文本：一条记忆对应一个事实，能单独删、单独改，
/// 也能带上是哪本书、哪一页来的。整段整段地往提示词里塞自由文本，模型分不清
/// 哪句是背景、哪句是这次的问题，用户也没法清理过时的那半句。
public struct MemoryEntry: Identifiable, Codable, Equatable, Hashable {

    public var id: UUID
    public var text: String
    public var createdAt: Date
    /// 来源标签：文档标题，或「手动添加」
    public var source: String
    /// 可选的定位标签，例如「第 42 页」
    public var locatorLabel: String

    public init(
        id: UUID = UUID(),
        text: String,
        createdAt: Date = Date(),
        source: String = "手动添加",
        locatorLabel: String = ""
    ) {
        self.id = id
        self.text = text
        self.createdAt = createdAt
        self.source = source
        self.locatorLabel = locatorLabel
    }

    /// 单条记忆塞进提示词时最多占多少字符，防止一条超长记忆挤掉别的
    static let maxCharactersPerEntry = 400

    var condensedText: String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > Self.maxCharactersPerEntry else { return trimmed }
        return String(trimmed.prefix(Self.maxCharactersPerEntry)) + "…"
    }

    public var originLabel: String {
        guard !locatorLabel.isEmpty else { return source }
        return "\(source) · \(locatorLabel)"
    }
}

/// 跨会话持久记忆的存储与渲染。
///
/// 为什么不塞进 `AppSettings`：设置那条链路是「改一次存一次」的配置，
/// 记忆是持续增长的资料，混在一起会让 settings.json 越滚越大、diff 也没法看。
/// 单独一个 memory.json，语义清楚，出问题也好单独删。
@MainActor
public final class MemoryStore: ObservableObject {

    @Published public private(set) var entries: [MemoryEntry] = []

    private let fileURL: URL

    /// 注入提示词的总预算。记忆是背景资料，不该喧宾夺主——
    /// 超过这个长度就按时间倒序截断，最近的优先留下。
    ///
    /// 标 `nonisolated`：它是不可变常量，而它被用作 `promptFragment(budget:)` 的默认实参，
    /// 默认实参在调用方上下文求值，可能是非主线程的。
    public nonisolated static let promptBudget = 1_600

    public init(fileURL: URL = AppPaths.memoryFile) {
        self.fileURL = fileURL
        self.entries = Self.load(from: fileURL)
    }

    // MARK: - 增删改

    @discardableResult
    public func add(
        text: String,
        source: String = "手动添加",
        locatorLabel: String = ""
    ) -> MemoryEntry? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        // 完全重复的不再收，避免用户连点几次按钮攒出一堆一样的
        if entries.contains(where: { $0.text == trimmed }) { return nil }

        let entry = MemoryEntry(text: trimmed, source: source, locatorLabel: locatorLabel)
        entries.insert(entry, at: 0)
        save()
        return entry
    }

    public func update(_ entry: MemoryEntry, text: String) {
        guard let index = entries.firstIndex(where: { $0.id == entry.id }) else { return }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            remove(entry)
            return
        }
        entries[index].text = trimmed
        save()
    }

    public func remove(_ entry: MemoryEntry) {
        entries.removeAll { $0.id == entry.id }
        save()
    }

    public func remove(atOffsets offsets: IndexSet) {
        // 倒序删，避免前面的删除把后面的下标挪位。不用 SwiftUI 的
        // `remove(atOffsets:)`——那是 SwiftUI 给集合加的扩展，LumenKit 不该依赖 UI 框架。
        for index in offsets.sorted(by: >) where entries.indices.contains(index) {
            entries.remove(at: index)
        }
        save()
    }

    public func removeAll() {
        entries.removeAll()
        save()
    }

    public var isEmpty: Bool { entries.isEmpty }

    // MARK: - 渲染进提示词

    /// 把记忆渲染成一段可直接拼进系统提示的文本。
    ///
    /// 返回空串表示「没有可发送的记忆」，调用方据此决定要不要带这一段，
    /// 免得模型收到一个空标题下面什么都没有。
    public func promptFragment(budget: Int = MemoryStore.promptBudget) -> String {
        guard !entries.isEmpty, budget > 0 else { return "" }

        var lines: [String] = []
        var used = 0

        // entries 本身就是「新的在前」，按顺序取即可实现「最近的优先留下」
        for entry in entries {
            let line = "- \(entry.condensedText)"
            // +1 是换行符的宽度
            let cost = line.count + 1
            guard used + cost <= budget else { break }
            lines.append(line)
            used += cost
        }

        guard !lines.isEmpty else { return "" }
        return lines.joined(separator: "\n")
    }

    /// 供 UI 显示"已用多少预算"
    public var currentPromptCost: Int {
        promptFragment().count
    }

    // MARK: - 持久化

    private static func load(from url: URL) -> [MemoryEntry] {
        guard let data = try? Data(contentsOf: url), !data.isEmpty else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        // 先用新格式解；解失败再试「纯字符串数组」这种更早的写法，尽量不丢用户的记忆
        if let entries = try? decoder.decode([MemoryEntry].self, from: data) {
            return entries
        }
        if let legacy = try? JSONDecoder().decode([String].self, from: data) {
            return legacy.map { MemoryEntry(text: $0, source: "手动添加") }
        }
        return []
    }

    private func save() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(entries) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}
