import Foundation

/// 应用数据目录规划。
///
/// 设计原则：不做书库，所以没有数据库；只有少量 JSON 状态文件 + 按文档路径哈希
/// 分目录的阅读状态。API Key 不落盘，只进 Keychain。
public enum AppPaths {

    public static let bundleIdentifier = "com.jn.lumen"

    @discardableResult
    private static func ensureDirectory(_ url: URL) -> URL {
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private static var applicationSupportBase: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
    }

    private static var cachesBase: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
    }

    /// ~/Library/Application Support/com.jn.lumen
    public static var supportRoot: URL {
        ensureDirectory(applicationSupportBase.appendingPathComponent(bundleIdentifier, isDirectory: true))
    }

    /// ~/Library/Caches/com.jn.lumen（可随时安全删除）
    public static var cacheRoot: URL {
        ensureDirectory(cachesBase.appendingPathComponent(bundleIdentifier, isDirectory: true))
    }

    public static var settingsFile: URL { supportRoot.appendingPathComponent("settings.json") }
    public static var recentFile: URL { supportRoot.appendingPathComponent("recent.json") }
    public static var memoryFile: URL { supportRoot.appendingPathComponent("memory.json") }
    /// 用户自定义快捷键。单独一个文件而不是塞进 settings.json：
    /// 它是"一套完整的方案"，用户可能想整份备份或换掉，混在大设置里做不到。
    public static var keyBindingsFile: URL { supportRoot.appendingPathComponent("keybindings.json") }

    /// 单本文档的状态目录。
    public static func documentDirectory(forPath path: String) -> URL {
        ensureDirectory(
            supportRoot
                .appendingPathComponent("docs", isDirectory: true)
                .appendingPathComponent(stableHash(path), isDirectory: true)
        )
    }

    public static func readingStateFile(forPath path: String) -> URL {
        documentDirectory(forPath: path).appendingPathComponent("state.json")
    }

    public static func chatHistoryFile(forPath path: String) -> URL {
        documentDirectory(forPath: path).appendingPathComponent("chats.json")
    }

    /// EPUB 解包后的临时目录（缓存在磁盘，可随时清理）。
    public static func epubExtractionDirectory(forPath path: String) -> URL {
        ensureDirectory(
            cacheRoot
                .appendingPathComponent("epub", isDirectory: true)
                .appendingPathComponent(stableHash(path), isDirectory: true)
        )
    }

    /// 用 FNV-1a 64 位做路径哈希。稳定、跨进程一致、无需 CryptoKit。
    public static func stableHash(_ string: String) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in string.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3
        }
        return String(hash, radix: 16)
    }
}
