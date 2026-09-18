import Foundation
import Testing
@testable import LumenKit

/// 回归测试：`docs/LESSONS.md` #1 的**类级**修法（见 `docs/AUDIT-code-health-2026-09-17.md` P1-1）。
///
/// #1 当年只修了「最近打开」这一个实例（补 iso8601 策略），但同一个坏结构还留在
/// 另外几处：`解码失败 → try? 拿默认（往往是空列表）→ 下一次 persist 把空列表写回磁盘`。
/// 这一组测试锁死类级修复的两个不变量：
/// 1. **损坏的文件不会被销毁**——原文件被改名成 `.corrupt-<时间戳>`，字节原样保留；
/// 2. **内存不被赋成空值后回写**——失败路径不写盘，原路径不再指向那份坏文件。
@Suite("PersistFile：损坏文件的后备与留痕")
struct PersistFileTests {

    private func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("lumen-persistfile-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func write(_ text: String, named name: String, in dir: URL) throws -> URL {
        let file = dir.appendingPathComponent(name)
        try text.write(to: file, atomically: true, encoding: .utf8)
        return file
    }

    private func backups(ofFile file: URL) throws -> [URL] {
        try FileManager.default
            .contentsOfDirectory(at: file.deletingLastPathComponent(),
                                 includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix(file.lastPathComponent + ".corrupt-") }
    }

    @Test("解码成功：返回对象，且不产生任何备份")
    func decodesWithoutBackup() throws {
        let dir = try makeTempDir()
        let file = try write("{\"value\":7}", named: "ok.json", in: dir)

        struct Box: Codable, Equatable { var value: Int }
        let decoded = PersistFile.decodeOrBackup(
            data: try Data(contentsOf: file),
            type: Box.self,
            fileURL: file,
            reason: "ok.json"
        )

        #expect(decoded == Box(value: 7))
        #expect(try backups(ofFile: file).isEmpty, "解码成功不该留下备份")
        #expect(FileManager.default.fileExists(atPath: file.path), "解码成功不该动原文件")
    }

    @Test("解码失败：返回 nil，原文件被改名备份、字节原样保留")
    func decodeFailureBacksUpOriginalBytes() throws {
        let dir = try makeTempDir()
        let original = "{ 这不是合法 JSON"
        let file = try write(original, named: "recent.json", in: dir)

        struct Box: Codable { var value: Int }
        let decoded = PersistFile.decodeOrBackup(
            data: try Data(contentsOf: file),
            type: Box.self,
            fileURL: file,
            reason: "recent.json"
        )

        #expect(decoded == nil, "坏数据必须解出 nil，而不是某种默认值")

        let found = try backups(ofFile: file)
        #expect(found.count == 1, "应当且只生成一份 .corrupt 备份")
        let backup = try #require(found.first)
        #expect(backup.lastPathComponent.hasPrefix("recent.json.corrupt-"),
                "备份名应为 <原名>.corrupt-<时间戳>")
        #expect(try String(contentsOf: backup, encoding: .utf8) == original,
                "备份必须原样保留损坏前的字节，一个字符都不能丢")
        #expect(!FileManager.default.fileExists(atPath: file.path),
                "原文件应已被移走——这样后续保存写的是新文件，绝不会盖掉用户数据")
    }

    @Test("同一秒内两次损坏各自留档，互不覆盖")
    func repeatedBackupsDoNotClobber() throws {
        let dir = try makeTempDir()
        let first = try write("bad-1", named: "x.json", in: dir)
        PersistFile.backupCorrupt(first, reason: "test")

        let second = try write("bad-2", named: "x.json", in: dir)
        PersistFile.backupCorrupt(second, reason: "test")

        let found = try backups(ofFile: second)
        #expect(found.count == 2, "两次损坏应各留一份，不能互相盖掉")
    }

    @Test("写盘失败返回 false（`try?` 的静默失败不再无声）")
    func writeFailureIsReported() throws {
        let bogus = URL(fileURLWithPath: "/lumen-nonexistent-\(UUID().uuidString)/x.json")
        let ok = PersistFile.write(Data("{}".utf8), to: bogus, label: "test")
        #expect(ok == false, "写进不存在的目录必须返回 false 并在日志留痕")
    }

    // MARK: 备份的失败分支（此前没测到的那条路）

    @Test("备份失败（目录不可写 → 改名失败）→ 返回 nil，原文件原地不动、不留半成品")
    func backupFailureReturnsNilAndKeepsOriginal() throws {
        // root 无视文件权限，这条用例在 root 下无法构造失败，跳过（避免伪失败）。
        guard getuid() != 0 else { return }

        let dir = try makeTempDir()
        let original = "{ 坏但还没被移走的数据"
        let file = try write(original, named: "locked.json", in: dir)

        // 把目录设成只读（r-x）：改名（`moveItem`）需要对目录的写权限，于是必然 EACCES，
        // 正好把我们送进 `backupCorrupt` 的 catch 分支。defer 恢复权限，否则临时目录清不掉。
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: dir.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path) }

        let backup = PersistFile.backupCorrupt(file, reason: "test")

        #expect(backup == nil, "改名失败必须返回 nil——不能谎报「已备份」")
        #expect(FileManager.default.fileExists(atPath: file.path),
                "备份失败时原文件必须原地不动，绝不能出现「既没备份成功、原件又没了」")
        #expect(try String(contentsOf: file, encoding: .utf8) == original,
                "失败路径不得改动原文件字节")
        #expect(try backups(ofFile: file).isEmpty, "失败的备份不该留下任何 .corrupt 残留")
    }

    @Test("文件不存在：返回 nil，且不创建任何东西")
    func backupWhenFileMissingReturnsNil() throws {
        let dir = try makeTempDir()
        let missing = dir.appendingPathComponent("never-existed.json")

        let backup = PersistFile.backupCorrupt(missing, reason: "test")

        #expect(backup == nil, "没有文件可备份时必须返回 nil")
        #expect(!FileManager.default.fileExists(atPath: missing.path), "不该凭空造出一个文件")
        #expect(try backups(ofFile: missing).isEmpty, "不该凭空造出一个备份")
    }

    @Test("解码失败但备份也失败：仍返回 nil，且原文件仍在（不谎报、不销毁）")
    func decodeFailureWithFailedBackupLeavesFile() throws {
        guard getuid() != 0 else { return }

        let dir = try makeTempDir()
        let original = "{ 解不出、也移不走"
        let file = try write(original, named: "recent.json", in: dir)
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: dir.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path) }

        struct Box: Codable { var value: Int }
        let decoded = PersistFile.decodeOrBackup(
            data: try Data(contentsOf: file), type: Box.self, fileURL: file, reason: "recent.json"
        )

        #expect(decoded == nil, "坏数据一律解出 nil，与备份成败无关")
        #expect(FileManager.default.fileExists(atPath: file.path),
                "备份失败时原文件还在——调用方据此知道「这次没能留档」")
        #expect(try String(contentsOf: file, encoding: .utf8) == original)
        #expect(try backups(ofFile: file).isEmpty)
    }
}

@Suite("损坏存储的解码后备（三个持久化调用点）")
struct CorruptStoreRecoveryTests {

    private func makeTempFile(content: String, name: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("lumen-store-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent(name)
        try content.write(to: file, atomically: true, encoding: .utf8)
        return file
    }

    private func backups(nearFile file: URL) throws -> [URL] {
        try FileManager.default
            .contentsOfDirectory(at: file.deletingLastPathComponent(),
                                 includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.contains(".corrupt-") }
    }

    @Test("RecentDocuments：坏 recent.json → 备份生成、内存不归零成「写死的空」")
    @MainActor
    func recentDocumentsCorruptFileIsBackedUp() throws {
        let file = try makeTempFile(content: "{ 这不是合法 JSON", name: "recent.json")
        let store = RecentDocuments(fileURL: file)

        #expect(store.entries.isEmpty, "坏文件解不出记录，内存保持空")
        let found = try backups(nearFile: file)
        #expect(found.count == 1, "坏 recent.json 必须留下备份，不能静默清空")
        #expect(!FileManager.default.fileExists(atPath: file.path),
                "原文件应已移走；后续 persist 写新文件，不会把用户记录盖成空列表")
    }

    @Test("MemoryStore：旧「纯字符串数组」格式必须被当成有效文件，不得误备份")
    @MainActor
    func memoryStoreLegacyFormatIsNotBackedUp() throws {
        let file = try makeTempFile(content: "[\"记忆甲\",\"记忆乙\"]", name: "memory.json")
        let store = MemoryStore(fileURL: file)

        #expect(store.entries.count == 2, "旧格式应当仍能读出来")
        #expect(try backups(nearFile: file).isEmpty,
                "旧格式解得出就是有效文件——不能因为「不是新格式」就判它损坏")
    }

    @Test("MemoryStore：新老两种都解不出 → 备份生成")
    @MainActor
    func memoryStoreGarbageIsBackedUp() throws {
        let file = try makeTempFile(content: "{ 这不是 JSON 也不是字符串数组", name: "memory.json")
        let store = MemoryStore(fileURL: file)

        #expect(store.entries.isEmpty)
        #expect(try backups(nearFile: file).count == 1, "两种格式都解不出才算真损坏，应留备份")
    }

    @Test("ReadingStateStore：坏进度文件 → 备份生成，状态退回默认")
    @MainActor
    func readingStateCorruptFileIsBackedUp() throws {
        // AppPaths.readingStateFile 是按文档路径派生的，测试直接构造同构文件：
        // 用一个真实临时文档路径让 store 自己算出文件位置。
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("lumen-rs-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let docPath = dir.appendingPathComponent("book.pdf").path
        let stateFile = AppPaths.readingStateFile(forPath: docPath)

        try FileManager.default.createDirectory(at: stateFile.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try "{ 坏掉的进度".write(to: stateFile, atomically: true, encoding: .utf8)

        let store = ReadingStateStore(documentPath: docPath)
        #expect(store.state.progress == 0, "坏文件应退回默认状态")
        #expect(try backups(nearFile: stateFile).count == 1, "坏进度文件必须留备份")
    }

    @Test("Settings：磁盘列着服务商、解出来为空 → settings.json 必须备份")
    @MainActor
    func settingsLostProvidersTriggersBackup() throws {
        // `[42]`：providers 是数组，但元素不是对象 → `[AIProviderConfig]` 整体解码失败，
        // 被逐字段容错吞成空数组。这正是「用户的服务商配置被静默抹掉」的现场。
        let file = try makeTempFile(
            content: #"{"ai":{"providers":[42]},"reader":{},"ui":{}}"#,
            name: "settings.json"
        )
        let store = SettingsStore(fileURL: file)

        #expect(store.settings.ai.providers.isEmpty, "坏 providers 解出为空是预期")
        #expect(try backups(nearFile: file).count == 1,
                "磁盘上明明有服务商、解出却为空 = 解码坏了，必须备份 settings.json")
    }

    @Test("Settings：合法的空 providers 不得被误判为损坏")
    @MainActor
    func settingsEmptyProvidersIsNotCorrupt() throws {
        let file = try makeTempFile(
            content: #"{"ai":{"providers":[]},"reader":{},"ui":{}}"#,
            name: "settings.json"
        )
        _ = SettingsStore(fileURL: file)

        #expect(try backups(nearFile: file).isEmpty,
                "用户真的没配服务商（空数组）是合法状态，不该备份")
    }

    /// 「备份失败之后，调用方还会不会 persist？会不会把原件盖掉？」
    ///
    /// 结论：**不会丢数据**——但这是「备份」与「写盘」共用**同目录 rename** 语义的**推论**，
    /// 不是代码里的显式守卫。本条把这条推论钉成断言，免得将来有人把 `PersistFile.write`
    /// 从 `.atomic` 换成非原子写（那时备份失败 + 直写成功就会真的覆盖原件，而没人拦）。
    @Test("备份失败后紧接着一次保存：写盘被同一道权限拦下，损坏原件字节不被覆盖")
    @MainActor
    func saveAfterFailedBackupKeepsOriginal() throws {
        guard getuid() != 0 else { return }

        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("lumen-store-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("recent.json")
        let original = "{ 坏但必须留住——备份与写盘都发生在同一目录里"
        try original.write(to: file, atomically: true, encoding: .utf8)

        // 目录只读（r-x）：改名备份与「临时文件 + rename」的原子写都要求目录写权限，
        // 于是两者被**同一道权限**一起拦下。defer 恢复，否则临时目录清不掉。
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: dir.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path) }

        let store = RecentDocuments(fileURL: file)
        #expect(store.entries.isEmpty, "坏文件解不出记录")
        #expect(try backups(nearFile: file).isEmpty, "备份失败不该留下 .corrupt 残留")

        // 用户随后随手打开一本书就会走到这里（record → persist）。
        store.record(url: URL(fileURLWithPath: "/tmp/whatever.pdf"), kind: .pdf)

        #expect(FileManager.default.fileExists(atPath: file.path))
        #expect(try String(contentsOf: file, encoding: .utf8) == original,
                """
                备份失败时写盘必须同样失败（两者同目录 rename），损坏原件字节原样保留。\
                这条一旦变红，说明写盘路径不再与备份共享权限语义——那才是真正的「丢了数据」。
                """)
    }

    @Test("键路径断言：编码后的服务商在 ai.providers（保配置守卫赖以成立的键名）")
    func encodedProvidersLiveAtAIDotProviders() throws {
        var settings = AppSettings()
        settings.ai.providers = [
            AIProviderConfig(name: "测试", baseURL: "https://example.com/v1",
                             models: ["m"], selectedModel: "m")
        ]
        let data = try JSONEncoder().encode(settings)
        let root = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let ai = try #require(root["ai"] as? [String: Any])
        let providers = try #require(ai["providers"] as? [Any])

        #expect(providers.count == 1, """
            `SettingsStore.providersLookLost` 走的是 ai.providers 这条硬编码键路径；\
            键名一旦改动，这条断言先红，守卫不会悄无声息地失效
            """)
    }
}
