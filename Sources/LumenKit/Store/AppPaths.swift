import Foundation

/// 应用数据目录规划。
///
/// 设计原则：不做书库，所以没有数据库；只有少量 JSON 状态文件 + 按文档路径哈希
/// 分目录的阅读状态。API Key 单独存入当前用户专用的 credentials 目录（目录 0700、文件 0600）。
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
    ///
    /// 自检（带 `-report`）且给了 `LUMEN_TEST_DATA` 时**重定向到临时目录**，
    /// 这样自检怎么折腾都碰不到用户真实数据。
    public static var supportRoot: URL {
        if let directory = ProcessInfo.processInfo.environment["LUMEN_TEST_DATA"],
           CommandLine.arguments.contains(where: { $0.hasSuffix("-report") || $0 == "--capture" }) {
            return ensureDirectory(URL(fileURLWithPath: directory, isDirectory: true))
        }
        return realSupportRoot
    }

    /// **忽略 `LUMEN_TEST_DATA` 重定向**的真实用户目录。
    ///
    /// 给自检用的：「我这一轮有没有碰到用户的真实配置」必须能在重定向生效时也问得出来，
    /// 否则断言只能证明「临时目录没被改」，证明不了最要紧的那件事。
    public static var realSupportRoot: URL {
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

    /// 全局共享的会话清单（落盘在 `conversations.json`）。
    ///
    /// 为什么是**全局一份**而不是像 `chats.json` 那样按文档路径哈希分目录：
    /// 用户明确要求「所有文档共用一份会话列表」——可以在 AI 面板头部一键开启新会话，
    /// 也能随时切回任意历史会话，而不必先打开某本书。代价是「这条回答是针对哪本书的」
    /// 会变模糊，所以引用跳转另用 `ConversationCitationPolicy` 按气泡来源降级处理。
    /// 目录是 `supportRoot` 下的一级文件（不再走 `docs/<hash>/`），避免和按书隔离的旧数据混在一起。
    public static var conversationHistoryFile: URL {
        supportRoot.appendingPathComponent("conversations.json")
    }

    /// AI 智能目录缓存。
    ///
    /// 和对话记录一样跟着文档走（按路径哈希分目录），而不是全局一个池子：
    /// 目录是**这本书**的结构，书被删了缓存也该跟着失效；而路径哈希目录本来
    /// 就是「这本书的私有目录」，放进去天然满足这个语义。
    public static func smartOutlineFile(forPath path: String) -> URL {
        documentDirectory(forPath: path).appendingPathComponent("smart-outline.json")
    }

    /// EPUB 批注存储。PDF 批注写在 PDF 文件自身，不走这里——
    /// 但侧栏的批注列表两种格式共用同一套交互。
    public static func annotationsFile(forPath path: String) -> URL {
        documentDirectory(forPath: path).appendingPathComponent("annotations.json")
    }

    /// 逐段对照翻译的译文缓存。
    ///
    /// 跟着文档走（按路径哈希分目录）而不是全局一个池子：译文是**这本书的**
    /// 段落译文，键是「段落的稳定 id」，换一本书同样的 id 指向完全不同的文字
    /// （id 只含页号与坐标），全局池子会直接把 A 书的译文贴到 B 书上。
    ///
    /// 缓存的意义在必应通道上格外大：它是免密钥的免费通道，**有速率限制**，
    /// 同一本书来回翻两次会白烧掉一倍配额，还可能直接吃 429。
    public static func translationCacheFile(forPath path: String) -> URL {
        documentDirectory(forPath: path).appendingPathComponent("translations.json")
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
