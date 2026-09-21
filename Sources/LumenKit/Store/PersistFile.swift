import Foundation

/// 持久化文件的「坏了别硬扛」工具箱。
///
/// 这一类缺陷共用一个坏结构——它是 `docs/LESSONS.md` #1 的**类级**版本，
/// 而 #1 当时只修了「最近打开」这一个实例：
///
/// ```swift
/// entries = (try? decoder.decode([Entry].self, from: data)) ?? []   // 解码失败 → 静默拿空
/// …（用户继续操作）…
/// persist()                                                        // 把空列表写回磁盘
/// ```
///
/// 解码失败本身并不可怕，可怕的是它**无声无息**，随后被下一次保存坐实：
/// 用户的文件被一份「合法但空」的新文件替换，且没有任何线索可查。
///
/// 这里封死这一类坑，做法有两条：
///
/// 1. ``decodeOrBackup(data:type:fileURL:decoder:reason:)`` —— 解码失败就把原文件
///    **改名**成 `<name>.corrupt-<时间戳>`，并把失败报进日志；调用方拿到 `nil` 时
///    **保持内存值不动**。原文件既然已经被移走，后续任何 `persist()` 写的都是
///    **新文件**，用户旧数据仍躺在备份里，可以人工抢救。
/// 2. ``write(_:to:label:)`` —— 原子写盘失败不再静默（`try? data.write` → 一行日志）。
///    写失败本身用户未必立刻发现，但至少要留下可查的线索。
public enum PersistFile {

    // MARK: - 解码：失败即备份

    /// 解码；成功返回值，失败把原文件改名备份（并 NSLog）并返回 `nil`。
    ///
    /// - Parameters:
    ///   - data: 已经读出来的字节。**必须**是调用方按同一份文件读出的内容——
    ///     备份是把 `fileURL` 指向的文件移走，若 `data` 与它不同源，备份就没有意义。
    ///   - type: 期望解码成的类型。
    ///   - fileURL: 数据来源文件。解码失败时会被改名备份。
    ///   - decoder: 已配置好策略（日期等）的解码器；`dateDecodingStrategy` 必须与
    ///     写盘侧成对，否则每一次都会走「失败 → 备份」这条路径。
    ///   - reason: 写进日志的原因标签，便于在 Console 里定位是哪份文件。
    /// - Returns: 解码成功的对象；失败为 `nil`（此时原文件已被备份）。
    @discardableResult
    public static func decodeOrBackup<T: Decodable>(
        data: Data,
        type: T.Type,
        fileURL: URL,
        decoder: JSONDecoder = JSONDecoder(),
        reason: String = ""
    ) -> T? {
        do {
            return try decoder.decode(type, from: data)
        } catch {
            let label = reason.isEmpty ? "\(type)" : reason
            NSLog("%@", "[Lumen][persist] 解码失败：\(fileURL.lastPathComponent)（\(label)）：\(error)")
            backupCorrupt(fileURL, reason: label)
            return nil
        }
    }

    /// 把一份「已判定为损坏」的文件改名备份。
    ///
    /// 用「改名」而不是「复制」是有意的：改名之后原路径就空了，下一次
    /// `persist()` 只能写到新文件，**不可能**再覆盖用户的原数据。复制则留着
    /// 原文件在原地，很容易被下一次保存顺手盖掉——备份就成了摆设。
    ///
    /// - Returns: 备份后的文件 URL；原文件不存在或改名失败时为 `nil`。
    @discardableResult
    public static func backupCorrupt(_ fileURL: URL, reason: String) -> URL? {
        let fm = FileManager.default
        guard fm.fileExists(atPath: fileURL.path) else {
            NSLog("%@", "[Lumen][persist] 解码失败但没有文件可备份：\(fileURL.lastPathComponent)（\(reason)）")
            return nil
        }

        let destination = uniqueBackupURL(for: fileURL, stamp: timestamp())
        do {
            try fm.moveItem(at: fileURL, to: destination)
            NSLog("%@", "[Lumen][persist] 原文件已备份：\(fileURL.lastPathComponent) → \(destination.lastPathComponent)（\(reason)）")
            return destination
        } catch {
            NSLog("%@", "[Lumen][persist] 备份失败：\(fileURL.lastPathComponent)：\(error)（\(reason)）")
            return nil
        }
    }

    // MARK: - 编码：失败必须留痕

    /// 原子写盘；失败时 NSLog（而不是静默吞掉）。
    ///
    /// `try? data.write(...)` 的失败完全不抛给任何人——阅读进度丢一次用户未必发现，
    /// 但「丢失后没有任何线索可查」是可以避免的。这里只把失败记下来，不改变控制流：
    /// 写盘失败不该让正在进行的用户操作崩掉，但必须能在日志里查到。
    ///
    /// - Returns: 是否写成功。
    @discardableResult
    public static func write(_ data: Data, to fileURL: URL, label: String) -> Bool {
        do {
            try data.write(to: fileURL, options: .atomic)
            return true
        } catch {
            NSLog("%@", "[Lumen][persist] 写盘失败：\(fileURL.lastPathComponent)（\(label)）：\(error)")
            return false
        }
    }

    // MARK: - 内部

    /// `yyyyMMdd-HHmmss`（POSIX 固定时区无关），用于备份文件名后缀。
    private static func timestamp(_ date: Date = Date()) -> String {
        let formatter = DateFormatter()
        // 固定 locale/format：不这样做的话，在非公历日历的系统上会写出意料之外的名字。
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: date)
    }

    /// 同一秒内重复损坏（例如启动时连读两次）也要各自留档，避免互相覆盖。
    private static func uniqueBackupURL(for fileURL: URL, stamp: String) -> URL {
        let fm = FileManager.default
        var candidate = fileURL.appendingPathExtension("corrupt-\(stamp)")
        var attempt = 1
        while fm.fileExists(atPath: candidate.path) {
            candidate = fileURL.appendingPathExtension("corrupt-\(stamp)-\(attempt)")
            attempt += 1
        }
        return candidate
    }
}
