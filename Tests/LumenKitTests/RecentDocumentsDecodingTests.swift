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

    @Test("解码失败时不得把已有文件误判为空后回写（防御规则：静默清空是最坏的失败模式）")
    @MainActor
    func corruptFileDoesNotTriggerRewrite() throws {
        let file = try makeTempFile(content: "{ 这不是合法 JSON")
        let store = RecentDocuments(fileURL: file)
        #expect(store.entries.isEmpty, "损坏文件应按空处理")
        // 关键断言：加载失败后 persist 不应立刻把空列表写回去盖掉原始文件
        let raw = try String(contentsOf: file, encoding: .utf8)
        #expect(raw.contains("这不是合法 JSON"), "load 失败不应覆写原文件")
    }
}
