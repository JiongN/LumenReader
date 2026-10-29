import Foundation

// MARK: - 批注条目

/// 一条批注的统一表示，供侧栏「批注」页签跨格式展示。
///
/// PDF 的批注本体写在 PDF 文件里（PDFKit annotation），这个结构只是列表投影；
/// EPUB 没有可以写回的「原文件」，批注本体就存在本应用的数据目录里，
/// 由 `AnnotationStore` 持有——两种格式在这个结构上汇合成同一种列表交互。
public struct AnnotationItem: Identifiable, Sendable, Equatable, Codable {
    /// 稳定 id。PDF 用「页号 + 批注原点 + 类型」（同基串的第 k 条再追加 `#k`）——
    /// 刻意不含时间戳，原因见 `PDFController.entryID` 的注释；EPUB 用生成时的 UUID。
    public var id: String
    /// 批注挂在哪里（PDF 为页，EPUB 为章）
    public var locator: DocumentLocator
    /// 划线原文（EPUB 高亮的引文；PDF 高亮批注里也存一份摘要）
    public var quote: String
    /// 批注正文
    public var note: String
    /// 是否带页面内高亮（PDF 高亮批注与 EPUB 高亮为 true；纯页面便签为 false）
    public var hasHighlight: Bool
    /// 创建时间
    public var createdAt: Date
    /// 标注颜色，形如 `#RRGGBB`。
    ///
    /// PDF 与 EPUB 高亮都使用它：颜色与正文标记一致，列表里据此显示色块，
    /// 让人一眼对上「清单里这条 = 页面上那块」。取不到颜色（PDF 未设色 / EPUB 批注）时为 nil，
    /// 调用方回退到主题强调色。
    ///
    /// EPUB 旧存档没有这个可选字段，解码后按默认黄色显示。
    public var highlightHex: String?
    /// 旧修复诊断的兼容字段。局部高亮合法，不再按整行宽度标为截断。
    public var truncated: Bool

    public init(id: String, locator: DocumentLocator, quote: String, note: String,
                hasHighlight: Bool, createdAt: Date, highlightHex: String? = nil,
                truncated: Bool = false) {
        self.id = id
        self.locator = locator
        self.quote = quote
        self.note = note
        self.hasHighlight = hasHighlight
        self.createdAt = createdAt
        self.highlightHex = highlightHex
        self.truncated = truncated
    }

    /// 列表里的预览行：有正文显正文，否则显划线原文。
    public var preview: String {
        let note = note.trimmingCharacters(in: .whitespacesAndNewlines)
        if !note.isEmpty { return note }
        return quote.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: - EPUB 批注存储

/// EPUB 批注的落盘模型。EPUB 没有「原文件可写回」，
/// 批注存在应用数据目录、按书路径哈希分目录（与阅读状态同一套语义）。
struct AnnotationArchive: Codable {
    var items: [StoredAnnotation] = []

}

/// 存储形态（与展示形态分开：展示形态引用 DocumentLocator，存储用 storageKey）。
struct StoredAnnotation: Codable, Equatable {
    var id: String
    var locatorKey: String
    var quote: String
    var note: String
    var hasHighlight: Bool
    var createdAt: Date
    var highlightHex: String?
}

/// 一本书的 EPUB 批注集合。读写都在主线程（批注量小，JSON 体积 KB 级）。
public final class AnnotationStore {
    public let fileURL: URL
    private var archive: AnnotationArchive
    private var expectedData: Data?
    private var canWrite = true

    public init(documentPath: String) {
        self.fileURL = AppPaths.annotationsFile(forPath: documentPath)
        self.archive = AnnotationArchive()
        if FileManager.default.fileExists(atPath: fileURL.path) {
            do {
                let data = try Data(contentsOf: fileURL)
                archive = PersistFile.decodeOrBackup(data: data, type: AnnotationArchive.self,
                    fileURL: fileURL, reason: "EPUB annotations.json") ?? AnnotationArchive()
                // A corrupt file may have been moved aside by recovery.
                expectedData = FileManager.default.fileExists(atPath: fileURL.path) ? data : nil
            } catch {
                canWrite = false
                NSLog("%@", "[Lumen][annotations] 无法读取批注，已禁止覆盖：\(error.localizedDescription)")
            }
        }
    }

    public var items: [AnnotationItem] {
        archive.items.compactMap { stored in
            guard let locator = DocumentLocator.parse(storageKey: stored.locatorKey) else { return nil }
            return AnnotationItem(
                id: stored.id,
                locator: locator,
                quote: stored.quote,
                note: stored.note,
                hasHighlight: stored.hasHighlight,
                createdAt: stored.createdAt,
                highlightHex: stored.highlightHex
            )
        }
    }

    @discardableResult
    public func add(_ item: AnnotationItem) -> Bool {
        // 同一引文 + 同一章不重复入库：双击按钮不该产生两条一模一样的高亮
        let trimmedQuote = item.quote.trimmingCharacters(in: .whitespacesAndNewlines)
        if archive.items.contains(where: {
            $0.locatorKey == item.locator.storageKey
                && $0.quote.trimmingCharacters(in: .whitespacesAndNewlines) == trimmedQuote
        }) {
            return false
        }
        archive.items.append(StoredAnnotation(
            id: item.id,
            locatorKey: item.locator.storageKey,
            quote: item.quote,
            note: item.note,
            hasHighlight: item.hasHighlight,
            createdAt: item.createdAt,
            highlightHex: item.highlightHex
        ))
        guard flush() else {
            archive.items.removeLast()
            return false
        }
        return true
    }

    /// 更新批注正文。找不到返回 false。
    @discardableResult
    public func updateNote(id: String, note: String) -> Bool {
        guard let index = archive.items.firstIndex(where: { $0.id == id }) else { return false }
        let previous = archive.items[index].note
        archive.items[index].note = note
        guard flush() else {
            archive.items[index].note = previous
            return false
        }
        return true
    }

    @discardableResult
    public func updateHighlightColor(id: String, hex: String) -> Bool {
        guard hex.range(of: "^#[0-9A-Fa-f]{6}$", options: .regularExpression) != nil,
              let index = archive.items.firstIndex(where: { $0.id == id && $0.hasHighlight }) else { return false }
        let previous = archive.items[index].highlightHex
        archive.items[index].highlightHex = hex.uppercased()
        guard flush() else {
            archive.items[index].highlightHex = previous
            return false
        }
        return true
    }

    @discardableResult
    public func remove(id: String) -> Bool {
        let previous = archive.items
        archive.items.removeAll { $0.id == id }
        guard archive.items.count != previous.count else { return false }
        guard flush() else {
            archive.items = previous
            return false
        }
        return true
    }

    @discardableResult
    public func flush() -> Bool {
        guard canWrite, let data = try? JSONEncoder().encode(archive) else { return false }
        let coordinator = NSFileCoordinator()
        var coordinationError: NSError?
        var saved = false
        coordinator.coordinate(writingItemAt: fileURL, options: .forReplacing, error: &coordinationError) { url in
            do {
                let current = FileManager.default.fileExists(atPath: url.path) ? try Data(contentsOf: url) : nil
                guard current == expectedData else {
                    NSLog("%@", "[Lumen][annotations] 批注已被其他窗口或进程修改，未覆盖。")
                    return
                }
                saved = PersistFile.write(data, to: url, label: "annotations.json")
            } catch { NSLog("%@", "[Lumen][annotations] 写入前检查失败：\(error.localizedDescription)") }
        }
        guard coordinationError == nil, saved else { return false }
        expectedData = data
        return true
    }
}
