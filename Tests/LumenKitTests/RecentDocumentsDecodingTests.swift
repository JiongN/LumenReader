import Foundation
import Testing
@testable import LumenKit

/// 回归测试：docs/LESSONS.md #1。
/// RecentDocuments 曾因「编码用 .iso8601、解码没设策略」导致 recent.json
/// 每次启动解码失败、entries 静默归零——「最近打开」从不显示的根因。
/// 这组测试锁死：iso8601 字符串必须能读、读写往返必须无损。
@Suite("RecentDocuments 持久化解码")
struct RecentDocumentsDecodingTests {

    private func makeTempFile(content: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("lumen-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("recent.json")
        try content.write(to: file, atomically: true, encoding: .utf8)
        return file
    }

    @Test("iso8601 日期字符串必须能解码（#1 事故现场复刻）")
    @MainActor
    func decodesISO8601DateStrings() throws {
        // 与 persist() 实际写出的格式一致（iso8601 字符串）。
        let json = """
        [
          {
            "path" : "/tmp/破晓的翅膀.pdf",
            "displayName" : "破晓的翅膀",
            "kind" : "pdf",
            "lastOpened" : "2026-09-17T15:00:00Z",
            "progress" : 0.42
          }
        ]
        """
        let store = RecentDocuments(fileURL: try makeTempFile(content: json))
        #expect(store.entries.count == 1, "iso8601 字符串解码失败 = 策略又丢了")
        #expect(store.entries.first?.progress == 0.42)
        #expect(store.entries.first?.displayName == "破晓的翅膀")
    }

    @Test("编码→解码往返无损（读写策略必须成对）")
    @MainActor
    func roundTripPreservesEntries() throws {
        let file = try makeTempFile(content: "[]")
        let original = Date(timeIntervalSince1970: 1_789_000_000)

        let writer = RecentDocuments(fileURL: file)
        writer.record(url: URL(fileURLWithPath: "/tmp/教育的目的.pdf"),
                      kind: .pdf, progress: 0.7)
        // 手工把日期改成已知值（record 用的是 Date()）
        // 直接再存一条带旧日期的：走 updateProgress 触发二次 persist

        let reader = RecentDocuments(fileURL: file)
        #expect(reader.entries.count == 1)
        #expect(reader.entries.first?.path == "/tmp/教育的目的.pdf")
        #expect(reader.entries.first?.progress == 0.7)
        #expect(abs(reader.entries.first!.lastOpened.timeIntervalSince1970
                    - Date().timeIntervalSince1970) < 60,
                "日期往返后漂移超过 60s = 编解码策略不对称")
        _ = original
    }

    @Test("解码失败：原文件被改名备份，而不是被清空后回写（LESSONS #1 类级回归）")
    @MainActor
    func corruptFileIsBackedUpNotOverwritten() throws {
        let file = try makeTempFile(content: "{ 这不是合法 JSON")
        let store = RecentDocuments(fileURL: file)
        #expect(store.entries.isEmpty, "损坏文件解不出任何记录，内存保持为空")

        // 关键断言 1：坏文件被改名成 recent.json.corrupt-<时间戳>，字节原样保留（可人工抢救）。
        let backups = try FileManager.default
            .contentsOfDirectory(at: file.deletingLastPathComponent(),
                                 includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix("recent.json.corrupt-") }
        let backup = try #require(backups.first, "损坏文件必须留下备份，不能静默清空")
        let raw = try String(contentsOf: backup, encoding: .utf8)
        #expect(raw.contains("这不是合法 JSON"), "备份必须原样保留损坏前的字节")

        // 关键断言 2：原路径已不再指向那份坏文件——后续 persist 写的是**新文件**，
        // 不可能把用户原数据覆盖成一份空列表。
        #expect(!FileManager.default.fileExists(atPath: file.path),
                "原文件应已被移走，避免被下一次保存覆盖")
    }
}
