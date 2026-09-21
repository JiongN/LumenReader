import Foundation

/// 逐段对照翻译的译文缓存。
///
/// **为什么必须有缓存**：系统翻译与联网引擎都不应重复处理同一段。
/// 同一本书往下翻、往上翻、关掉再打开，段落会反复出现在屏幕上 ——
/// 每次都重新请求等于白烧配额，还可能直接吃 429 让整本书翻不动。
///
/// **为什么键是「段落 id」而不是「原文哈希」**：段落 id 是「页号 + 段首坐标」，
/// 它在同一份 PDF 里稳定，且**不需要保留原文**就能命中。用原文做键要额外存一份
/// 全文（体积大、且原文可能被上游的抽取规则微调而全体失配）。
/// 代价是：抽取规则若改变段落边界，旧译文会全部作废 —— 这是可接受的，
/// 因为那时段落本身就换了，旧译文贴上去反而错位。
///
/// **为什么跟着文档走**：id 只含页号与坐标，A 书的 `p3-120x72` 与 B 书的
/// 同名 id 指向完全无关的两段文字。全局一个池子会把 A 书的译文贴到 B 书上。
/// 所以落点是 `docs/<路径哈希>/translations.json`（见 `AppPaths.translationCacheFile`）。
///
/// **容错解码是硬约束**（README 硬约束第 2 条）：缓存是「有了更好、没有也能跑」的
/// 东西，绝不能因为一条记录缺字段就让整份缓存作废、更不能崩。
public struct TranslationCache: Sendable, Equatable {

    /// 落盘结构。顶层包一层 `version`，将来加字段时老文件还能读。
    ///
    /// `fileprivate` 而不是 `private`：容错解码的 `init(from:)` 必须写在
    /// **extension** 里（理由见文末），而 `extension TranslationCache.File` 是
    /// 对 `File` 本身的扩展、不在 `TranslationCache` 的声明内，拿不到 `private`。
    /// 也不能写进类型体内 —— 那样逐成员初始化器 `File(version:entries:)` 就不再合成。
    fileprivate struct File: Codable {
        var version: Int = 1
        var entries: [String: String] = [:]
    }

    /// 段落 id → 译文。
    ///
    /// 只存**成功**的译文：失败与「跳过」不进缓存。
    /// 否则用户重试时会被缓存直接挡回来，永远看不到新结果。
    private var entries: [String: String]

    public init() {
        self.entries = [:]
    }

    public var count: Int { entries.count }

    public var isEmpty: Bool { entries.isEmpty }

    /// 取一条译文。取不到返回 nil（**不要**用空串表示未命中，
    /// 空串是「引擎真的返回了空」这个异常状态，两者在界面上要区分）。
    public func translation(for id: String) -> String? {
        guard let value = entries[id] else { return nil }
        return value.isEmpty ? nil : value
    }

    public mutating func store(_ translation: String, for id: String) {
        let trimmed = translation.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        entries[id] = trimmed
    }

    public mutating func remove(_ id: String) {
        entries.removeValue(forKey: id)
    }

    public mutating func removeAll() {
        entries.removeAll()
    }

    // MARK: - 落盘

    /// 从磁盘读。文件不存在返回空缓存（**不是错误** —— 第一次翻译本来就没有）。
    /// 文件损坏走 `PersistFile.decodeOrBackup` 备份而不是静默重置。
    public static func load(from url: URL) -> TranslationCache {
        var cache = TranslationCache()
        // 先读字节再交给 decodeOrBackup：备份是「把 url 指向的文件移走」，
        // 若这里再让它自己去读，就多了一次可能失败且与判断不同源的 I/O。
        guard let data = try? Data(contentsOf: url) else { return cache }
        guard let file = PersistFile.decodeOrBackup(
            data: data, type: File.self, fileURL: url, reason: "译文缓存"
        ) else {
            return cache
        }
        cache.entries = file.entries.filter {
            !$0.value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        return cache
    }

    /// 原子写。空缓存**删掉文件**而不是写一个空壳 ——
    /// 一个 `{"version":1,"entries":{}}` 会让用户以为「有缓存但一条都没有」。
    public func save(to url: URL) {
        if entries.isEmpty {
            try? FileManager.default.removeItem(at: url)
            return
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(File(version: 1, entries: entries)) else {
            // 编码失败是「这份结构自己有问题」，不是磁盘问题。不能静默：
            // 缓存写不进去会让用户以为「翻译又跑了一遍」，实际是每段都重发。
            NSLog("%@", "[Lumen][translate] 译文缓存编码失败，本次未写盘（\(entries.count) 条）")
            return
        }
        PersistFile.write(data, to: url, label: "译文缓存")
    }
}

// MARK: - 容错解码

/// `File` 的容错解码：任一键缺失都不能让整份缓存作废。
///
/// Swift 合成的 `Codable` **不会**在键缺失时使用属性默认值，它会直接抛错。
/// 所以这里手写 `init(from:)`，每个字段都写成 `(try? decode) ?? 默认值`。
///
/// 注意：写在 **extension** 里而不是类型体内 —— 类型体内只要声明了任何初始化器，
/// 逐成员初始化器就不再合成，而 `File(version:entries:)` 是上面 `save` 在用的。
extension TranslationCache.File {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = (try? c.decode(Int.self, forKey: .version)) ?? 1
        // 值是 String：解不出来就丢掉**这一条**，不丢整份。
        if let raw = try? c.decode([String: String].self, forKey: .entries) {
            entries = raw
        } else if let loose = try? c.decode([String: String?].self, forKey: .entries) {
            entries = loose.compactMapValues { $0 }
        } else {
            entries = [:]
        }
    }
}
