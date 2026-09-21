import SwiftUI
import Combine
import LumenKit

/// 一条全局共享的会话。
///
/// 与旧版「每本书各自一份 `chats.json`」不同，现在是**所有文档共用一份会话列表**
/// （落盘在 `conversations.json`，见 `AppPaths.conversationHistoryFile`）。用户可以在
/// AI 面板头部一键开启新会话、随时切回任意历史会话。
///
/// 代价是「这条回答是针对哪本书的」会变模糊，所以：
/// - 逐条 `Bubble` 记下了自己的 `sourceDocPath`（它这次提问来自哪本书）；
/// - 引用跳转由 `ConversationCitationPolicy` 按气泡来源降级，跨书的引用不可点。
struct Conversation: Codable, Identifiable {
    var id: UUID = UUID()
    /// 默认标题：**发起文档的标题**；同一文档的第 2 个及以后会话前面加序号（`2. 书名`）。
    /// 没有文档上下文时回退到时间戳（见 `displayTitle`）。
    /// 迁移进来的旧会话这里会是一条首条提问——那是历史值，不参与序号计数。
    var title: String = ""
    /// 用户手动改的标题，优先级最高；`nil` 表示用默认标题。
    var customTitle: String?
    var createdAt: Date = Date()
    /// 这个会话**首次提问时记下的发起文档路径**；从旧版本迁移来的可能为 nil。
    var sourceDocPath: String?
    var sourceDocTitle: String?
    /// 这一份会话的气泡（已落盘）。注意：`.notice` 类气泡在写入时被过滤掉，不进磁盘。
    var bubbles: [AIChatModel.Bubble] = []

    /// 展示用标题：customTitle > 自动 title > 「对话 MM-dd HH:mm」。
    var displayTitle: String {
        if let c = customTitle, !c.isEmpty { return c }
        if !title.isEmpty { return title }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "MM-dd HH:mm"
        return "对话 " + f.string(from: createdAt)
    }

    /// 从气泡序列里取首条 user 提问，截断到 40 字，作为自动标题。
    static func autoTitle(from bubbles: [AIChatModel.Bubble]) -> String? {
        guard let first = bubbles.first(where: { $0.role == .user }) else { return nil }
        let text = first.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        return text.count > 40 ? String(text.prefix(40)) + "…" : text
    }
}

// 容错解码写在 **extension** 里，不能写进 struct 本体。
//
// 理由是 Swift 的一条硬规则：**只要在类型本体里声明了任何一个初始化器，
// 逐成员初始化器就不再合成**。`init(from:)` 一旦写进本体，`Conversation()`
// 就直接报「missing argument for parameter 'from' in call」——而迁移、自检、
// store 内部到处都在用无参构造。放进 extension 则保留逐成员构造器。
extension Conversation {
    /// 容错解码（README 硬约束第 2 条）：任一键缺失都**不能**让整条会话解码失败——
    /// 那样用户整份对话就没了。每个字段都写成 `(try? decode) ?? 默认值`。
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? c.decode(UUID.self, forKey: .id)) ?? UUID()
        title = (try? c.decode(String.self, forKey: .title)) ?? ""
        customTitle = try? c.decodeIfPresent(String.self, forKey: .customTitle)
        createdAt = (try? c.decode(Date.self, forKey: .createdAt)) ?? Date()
        sourceDocPath = try? c.decodeIfPresent(String.self, forKey: .sourceDocPath)
        sourceDocTitle = try? c.decodeIfPresent(String.self, forKey: .sourceDocTitle)
        bubbles = (try? c.decode([AIChatModel.Bubble].self, forKey: .bubbles)) ?? []
    }
}

/// 落盘包裹结构：顶层加一层，方便将来加字段而不破坏旧文件。
private struct ConversationFile: Codable {
    var version: Int = 1
    var conversations: [Conversation] = []
    var activeID: UUID? = nil

    init(version: Int = 1, conversations: [Conversation] = [], activeID: UUID? = nil) {
        self.version = version
        self.conversations = conversations
        self.activeID = activeID
    }

    /// 容错解码：缺字段时用默认值，绝不因个别键缺失而整文件解码失败。
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = (try? c.decode(Int.self, forKey: .version)) ?? 1
        conversations = (try? c.decode([Conversation].self, forKey: .conversations)) ?? []
        activeID = (try? c.decode(UUID.self, forKey: .activeID)) ?? nil
    }
}

/// 全局会话仓库：进程级单例（挂在 `AppServices` 上），所有窗口共用同一份。
///
/// - 会话清单 + 活动 id 落盘在 `conversations.json`；
/// - `history`（喂给模型的上下文）**只留在内存、不落盘**——载入时由
///   `AIChatModel.rebuildHistory(from:)` 按「只收完整对子」规则从气泡重建，
///   与旧 `loadPersistedChat` 的同一套规则，单一真相源。
@MainActor
final class ConversationStore: ObservableObject {

    /// 这两个必须带默认值：`init()` 里要调 `performLegacyMigration()` / `createConversation()`
    /// 这些实例方法，而 Swift 不允许在全部存储属性初始化完成前使用 `self`。
    /// 给上默认值，`self` 从 `init()` 第一行起就是完整可用的。
    @Published private(set) var conversations: [Conversation] = []
    @Published private(set) var activeID: UUID?

    /// history 只留内存：键是会话 id。不落盘。
    private var histories: [UUID: [AIMessage]] = [:]

    // MARK: - 初始化 + 一次性迁移

    init() {
        if let file = Self.loadFile() {
            conversations = file.conversations
            activeID = file.activeID
        } else {
            // 没有 conversations.json：做一次一次性迁移（幂等，只在文件尚不存在时跑）。
            performLegacyMigration()
            if conversations.isEmpty {
                // 没有任何历史数据：起一个空会话，保证 activeID 永远非 nil。
                _ = createConversation(sourcePath: nil, sourceTitle: nil)
            }
            persist()
        }

        // 兜底：任何情况下 activeID 都必须指到一个真实存在的会话。
        if activeID == nil, let first = conversations.first {
            activeID = first.id
        }
    }

    /// 从 `conversations.json` 解码（损坏就备份而不是静默重置）。
    private static func loadFile() -> ConversationFile? {
        let url = AppPaths.conversationHistoryFile
        guard let data = try? Data(contentsOf: url) else { return nil }
        return PersistFile.decodeOrBackup(
            data: data,
            type: ConversationFile.self,
            fileURL: url,
            reason: "conversations.json"
        )
    }

    /// 一次性迁移旧数据：把 `supportRoot/docs/<FNV1a hash>/chats.json` 收进全局会话。
    ///
    /// 目录名是路径的单向哈希，正常情况下反推不出原路径。但 `recent.json` 里存着**绝对路径**，
    /// 用 `AppPaths.stableHash(path)` 重新算哈希去匹配 `docs/` 下的目录名就能反查出原文档——
    /// 实测能救回大约一半（迁移来的会话 `sourceDocPath` 才不是 nil）。
    ///
    /// 幂等：只在 `conversations.json` 尚不存在时调用一次；成功后把源文件改名为
    /// `chats.json.migrated-<yyyyMMddHHmmss>`（改名而非删除，失败就不导入这一份）。
    private func performLegacyMigration() {
        let fm = FileManager.default
        let docsDir = AppPaths.supportRoot.appendingPathComponent("docs", isDirectory: true)
        guard let subdirs = try? fm.contentsOfDirectory(
            at: docsDir,
            includingPropertiesForKeys: [.isDirectoryKey]
        ) else { return }

        // 用 recent.json 反查：hash(绝对路径) → (路径, 展示名)。复用现成的加载器。
        let recent = RecentDocuments()
        var hashToPath: [String: (path: String, title: String)] = [:]
        for entry in recent.entries {
            hashToPath[AppPaths.stableHash(entry.path)] = (entry.path, entry.displayName)
        }

        var imported: [Conversation] = []
        var recovered = 0
        var matched = 0
        var unmatched = 0
        let stamp = Self.migrationStamp()

        for dir in subdirs where (try? dir.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
            let chatFile = dir.appendingPathComponent("chats.json")
            guard fm.fileExists(atPath: chatFile.path) else { continue }

            guard let data = try? Data(contentsOf: chatFile) else { continue }
            // 容错解码旧气泡：缺字段也尽量保留，绝不因一条坏气泡丢掉整本书对话。
            guard let bubbles = PersistFile.decodeOrBackup(
                data: data,
                type: [AIChatModel.Bubble].self,
                fileURL: chatFile,
                reason: "chats.json"
            ) else { continue }

            let dirName = dir.lastPathComponent
            let match = hashToPath[dirName]
            if match != nil { matched += 1 } else { unmatched += 1 }

            // 创建时间取不到就退回修改时间，再退到现在。
            let attrs = try? fm.attributesOfItem(atPath: chatFile.path)
            let created = (attrs?[.creationDate] as? Date)
                ?? (attrs?[.modificationDate] as? Date)
                ?? Date()

            var conv = Conversation()
            conv.createdAt = created
            conv.sourceDocPath = match?.path
            conv.sourceDocTitle = match?.title
            conv.bubbles = bubbles
            conv.title = Conversation.autoTitle(from: bubbles) ?? Self.fallbackTitle(created)

            // 只有成功改名（源文件备份走）才算真正导入；改名失败则这一份不导入，下次可重试。
            let dest = dir.appendingPathComponent("chats.json.migrated-\(stamp)")
            do {
                try fm.moveItem(at: chatFile, to: dest)
                imported.append(conv)
                recovered += 1
            } catch {
                NSLog("[Lumen][conversation] 迁移跳过（改名失败）：\(chatFile.lastPathComponent)：\(error)")
            }
        }

        // 按创建时间升序，activeID 指向最新那条。
        imported.sort { $0.createdAt < $1.createdAt }
        conversations = imported
        activeID = imported.last?.id
        NSLog("[Lumen][conversation] 迁移完成：导入 \(recovered) 份，其中反查到原路径 \(matched) 份，未反查到 \(unmatched) 份")
    }

    private static func fallbackTitle(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "MM-dd HH:mm"
        return "对话 " + f.string(from: date)
    }

    /// 判断一个标题是不是「对话 MM-dd HH:mm」这种**时间戳兜底值**。
    ///
    /// 只用来决定「该不该把标题升级成文档标题」，所以宁可保守：形状必须完全对得上，
    /// 用户手动改过的、或迁移带进来的提问标题都不会被误判。
    static func isFallbackTitle(_ title: String) -> Bool {
        let prefix = "对话 "          // 「对」「话」+ 一个空格
        let shape = "MM-dd HH:mm"
        return title.hasPrefix(prefix) && title.count == prefix.count + shape.count
    }

    /// 从一条会话的 `title` 里解析出它在**同一文档**里的序号。
    ///
    /// `base` 是书名。形状只有两种算数：`base` → 1（第一个会话不带号）、`"3. base"` → 3。
    /// 其余（迁移带进来的提问标题、用户改过的、别的书的）一律返回 `nil`，不参与计数。
    ///
    /// **为什么按 `base` 后缀精确比对、而不是「取开头的数字」**：文件名本身可能就叫
    /// `1. 引言.pdf`，书名就是「1. 引言」。只认「去掉 `base` 后缀后剩下的那段才允许是
    /// `N.`」就不会把书名里的数字当成序号——这一条有断言守着（见 ConversationAudit）。
    static func sequence(in title: String, base: String) -> Int? {
        guard title.hasSuffix(base) else { return nil }
        let head = title.dropLast(base.count).trimmingCharacters(in: .whitespaces)
        if head.isEmpty { return 1 }
        guard head.hasSuffix(".") else { return nil }
        return Int(head.dropLast())
    }

    /// `yyyyMMddHHmmss`（POSIX 固定时区），用于迁移源文件改名后缀。
    private static func migrationStamp(_ date: Date = Date()) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyyMMddHHmmss"
        return f.string(from: date)
    }

    // MARK: - 查询

    var activeConversation: Conversation? {
        guard let id = activeID else { return nil }
        return conversations.first { $0.id == id }
    }

    func conversation(id: UUID) -> Conversation? {
        conversations.first { $0.id == id }
    }

    // MARK: - 默认标题

    /// 为一条新会话算出默认标题。
    ///
    /// 规则（用户指定）：**默认用发起文档的标题**；同一文档的第 2 个及以后会话前面加序号
    /// （`2. 书名`、`3. 书名`……），第一个不加——第一个加了反而像版本号。
    /// 没有文档标题时回退到时间戳。
    ///
    /// **序号不额外占字段**，而是从同文档已有会话的 `title` 字符串里现算（见 `sequence`）。
    /// 解析是精确的（要求 `base` 后缀完全吻合），所以不会把「书名里带数字」误判成序号，
    /// 也就不需要给 `conversations.json` 加新键——容错解码那套（README 硬约束第 2 条）
    /// 与落盘格式都保持原样。
    ///
    /// 推进用「**已用过的最大序号 + 1**」而不是「会话条数 + 1」：删掉中间某条之后，
    /// 下一个新建的不会退回去占一个仍然活着的号。
    func defaultTitle(sourcePath: String?, sourceTitle: String?, excluding: UUID? = nil) -> String {
        let base = sourceTitle?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !base.isEmpty else { return Self.fallbackTitle(Date()) }
        guard let path = sourcePath else { return base }   // 没有文档路径就只给书名，不编号
        let sameDoc = conversations.filter { $0.sourceDocPath == path && $0.id != excluding }
        guard !sameDoc.isEmpty else { return base }        // 该文档的第一条：不加序号
        var maxSeq = 1                                     // 第一条不带号，占位 1
        for c in sameDoc {
            if let n = Self.sequence(in: c.title, base: base) { maxSeq = max(maxSeq, n) }
        }
        return "\(maxSeq + 1). \(base)"
    }

    // MARK: - 变更

    /// 新建会话（空内容），返回新 id。
    @discardableResult
    func createConversation(sourcePath: String?, sourceTitle: String?) -> UUID {
        var conv = Conversation()
        conv.sourceDocPath = sourcePath
        conv.sourceDocTitle = sourceTitle
        conv.title = defaultTitle(sourcePath: sourcePath, sourceTitle: sourceTitle)
        conversations.append(conv)
        persist()
        return conv.id
    }

    func setActive(_ id: UUID) {
        guard conversations.contains(where: { $0.id == id }) else { return }
        activeID = id
        persist()
    }

    /// 用活动模型的内存副本替换某会话的内容并落盘。
    ///
    /// `history` **只留内存**（写进 `histories`，不进 `conversations.json`）——
    /// 载入时统一由 `AIChatModel.rebuildHistory(from:)` 从气泡重建，单一真相源。
    /// `.notice` 气泡不入盘（它们是临时的 UI 提示，不该被当成正经对话存档）。
    func replaceContent(id: UUID, bubbles: [AIChatModel.Bubble], history: [AIMessage]) {
        guard let index = conversations.firstIndex(where: { $0.id == id }) else { return }
        let clean = bubbles.filter { $0.role != .notice }
        conversations[index].bubbles = clean
        // 标题**不在这里**从首条提问生成：默认标题是「文档标题 + 序号」，在会话创建
        // （或出身文档第一次确定）时就定好了。写回答时再改标题，会让用户看着列表里
        // 一条会话的名字在提问之后突然变掉。首条提问只作为**迁移旧数据**的回退（见 performLegacyMigration）。
        histories[id] = history
        persist()
    }

    /// 只清内容，会话留在列表里。
    func clearContent(id: UUID) {
        guard let index = conversations.firstIndex(where: { $0.id == id }) else { return }
        conversations[index].bubbles = []
        histories[id] = []
        persist()
    }

    /// 删除会话；删后 active 落到相邻一条（数组里相邻），列表空了则新建一个空会话。
    func delete(id: UUID) {
        guard let index = conversations.firstIndex(where: { $0.id == id }) else { return }
        conversations.remove(at: index)
        histories[id] = nil

        if conversations.isEmpty {
            // 永远保留至少一个会话，避免 activeID 变 nil 让界面失去挂载点。
            //
            // 补上的这一条**必须同时接管 activeID**：否则 activeID 仍指向刚被删掉的那个
            // id（悬空），`activeConversation` 返回 nil，面板会显示成空状态——
            // 「删掉最后一个会话」本该等价于「回到一个新会话」。这条由
            // `--conversation-report` 的不变量断言抓出来过。
            let fresh = createConversation(sourcePath: nil, sourceTitle: nil)
            activeID = fresh
            persist()
            return
        }

        if activeID == id {
            // 落到相邻那条（优先右侧，没有则左侧）。
            let neighborIndex = min(index, conversations.count - 1)
            activeID = conversations[neighborIndex].id
        }
        persist()
    }

    /// 重命名（`nil` 表示清除自定义标题、回到自动标题）。
    func rename(id: UUID, _ title: String?) {
        guard let index = conversations.firstIndex(where: { $0.id == id }) else { return }
        let trimmed = title?.trimmingCharacters(in: .whitespacesAndNewlines)
        conversations[index].customTitle = (trimmed?.isEmpty ?? true) ? nil : trimmed
        persist()
    }

    /// 补上会话的出身文档（首条提问时记下；已有则不覆盖）。
    func setSourceDocPath(id: UUID, path: String, title: String?) {
        guard let index = conversations.firstIndex(where: { $0.id == id }) else { return }
        let firstTime = conversations[index].sourceDocPath == nil
        if firstTime { conversations[index].sourceDocPath = path }
        if conversations[index].sourceDocTitle == nil, let title {
            conversations[index].sourceDocTitle = title
        }

        // 出身文档**第一次**确定下来、且标题还停在时间戳兜底值时，升级成文档标题（含序号）。
        // 典型场景：用户在主页标签开了会话（那时还没有文档），随后打开一本书提问。
        // 只动兜底值——手动重命名、迁移带进来的提问标题都不覆盖。
        if firstTime, conversations[index].customTitle == nil {
            let current = conversations[index].title
            if current.isEmpty || Self.isFallbackTitle(current) {
                conversations[index].title = defaultTitle(
                    sourcePath: path,
                    sourceTitle: title ?? conversations[index].sourceDocTitle,
                    excluding: id
                )
            }
        }
        persist()
    }

    // MARK: - 落盘

    /// 原子写 `conversations.json`。
    func persist() {
        let file = ConversationFile(
            version: 1,
            conversations: conversations,
            activeID: activeID
        )
        guard let data = try? JSONEncoder().encode(file) else { return }
        PersistFile.write(data, to: AppPaths.conversationHistoryFile, label: "conversations.json")
    }
}
