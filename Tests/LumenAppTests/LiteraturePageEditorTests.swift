import Foundation
import Testing
@testable import LumenApp

@Suite struct LiteraturePageEditorTests {
    @Test func metadataFillsBlanksUpdatesOwnedFieldsAndPreservesEditsAndDeletions() throws {
        let old = LiteratureZoteroIdentity(library: "library", itemKey: "PARENT01", attachmentKey: "ATTACH01",
                                          title: "旧题名", authors: "旧作者", year: "2024", journal: "旧期刊")
        let new = LiteratureZoteroIdentity(library: "library", itemKey: "PARENT01", attachmentKey: "ATTACH01",
                                          title: "新题名", authors: "新作者", year: "2024-05-06", journal: "新期刊")
        let before = "---\n标题: 旧题名\n作者: 我的作者\n期刊: \"\"\n评价: ★★★☆☆\n总结: 自己的总结\n自定义: [[知识]]\n---\n\n个人正文\n"
        let result = try LiteraturePageEditor.refreshMetadata(before, identity: new, previous: old)
        let fields = try LiteraturePageEditor.properties(result)
        #expect(fields.first { $0.key == "标题" }?.value == "新题名")
        #expect(fields.first { $0.key == "作者" }?.value == "我的作者")
        #expect(fields.first { $0.key == "期刊" }?.value == "新期刊")
        #expect(!fields.contains { $0.key == "日期" })
        #expect(fields.first { $0.key == "评价" }?.value == "★★★☆☆")
        #expect(result.contains("总结: 自己的总结\n自定义: [[知识]]"))
        #expect(result.hasSuffix("个人正文\n"))
        #expect(try LiteraturePageEditor.refreshMetadata(result, identity: new, previous: new) == result)
    }
    @Test func scalarEditsPreserveUnrelatedYAMLAndBody() throws {
        let original = "---\n标签: [阅读, 论文]\n评价: '原评价'\n总结: |\n  第一行\n\n  第二行\nitemLink: zotero://select/library/items/ABCDEFGH\n---\n\n# 原文\n[[链接]]\n"
        let properties = try LiteraturePageEditor.properties(original)
        #expect(properties.first { $0.key == "总结" }?.value == "第一行\n\n第二行")
        #expect(properties.first { $0.key == "标签" }?.editable == false)
        let changed = try LiteraturePageEditor.set(original, key: "评价", value: "新评价\n第二行", expected: properties.first { $0.key == "评价" })
        #expect(changed.contains("标签: [阅读, 论文]"))
        #expect(changed.hasSuffix("# 原文\n[[链接]]\n"))
        #expect(try LiteraturePageEditor.properties(changed).first { $0.key == "评价" }?.value == "新评价\n第二行")
        #expect(throws: LiteratureFileError.noteChanged) {
            try LiteraturePageEditor.set(changed, key: "评价", value: "覆盖", expected: properties.first { $0.key == "评价" })
        }
        let deleted = try LiteraturePageEditor.set(changed, key: "总结", value: nil, expected: properties.first { $0.key == "总结" })
        #expect(!deleted.contains("第一行"))
        #expect(deleted.contains("新评价"))
    }
    @Test func independentChangesMergeAndReadingNotesProtectConcurrentEdits() throws {
        let initial = "---\n评价: \"A\"\n---\n\n## 我的整理\n保留\n"
        let property = try LiteraturePageEditor.properties(initial).first
        let notes = try LiteraturePageEditor.setReadingNotes(initial, value: "阅读感想\n[[概念]]", expected: nil)
        let merged = try LiteraturePageEditor.set(notes, key: "评价", value: "B", expected: property)
        #expect(try LiteraturePageEditor.readingNotes(merged) == "阅读感想\n[[概念]]")
        #expect(throws: LiteratureFileError.noteChanged) {
            try LiteraturePageEditor.setReadingNotes(merged, value: "覆盖", expected: nil)
        }
        #expect(merged.contains("## 我的整理\n保留"))
        let added = try LiteraturePageEditor.set(merged, key: "自定义", value: "值", expected: nil)
        #expect(try LiteraturePageEditor.properties(added).contains { $0.key == "自定义" })
    }
    @Test func propertyCannotReplaceSimilarIndentedContentOrIdentity() throws {
        let text = "---\n总结: |\n  评价: 相同\n评价: 相同\n---\n正文"
        let item = try LiteraturePageEditor.properties(text).first { $0.key == "评价" }
        let changed = try LiteraturePageEditor.set(text, key: "评价", value: "新", expected: item)
        #expect(changed.contains("  评价: 相同\n"))
        #expect(throws: LiteratureNoteError.invalidText) { try LiteraturePageEditor.set(text, key: "itemLink", value: nil, expected: nil) }
    }
    @Test func windowsNewlinesAndActualFileConflictsRemainSafe() async throws {
        let original = "---\r\n评价: 原文\r\n---\r\n正文 [[双链]]"
        let field = try LiteraturePageEditor.properties(original).first
        let changed = try LiteraturePageEditor.set(original, key: "期刊", value: "期刊名", expected: nil)
        #expect(try LiteraturePageEditor.properties(changed).count == 2)
        #expect(changed.hasSuffix("正文 [[双链]]"))
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("note.md")
        let external = try LiteraturePageEditor.set(changed, key: "评价", value: "外部版本", expected: field)
        try external.write(to: url, atomically: true, encoding: .utf8)
        let files = LiteratureNoteFiles(backupDirectory: folder.appendingPathComponent("backups"))
        do {
            try await files.editPage(url: url) { try LiteraturePageEditor.set($0, key: "评价", value: "过期草稿", expected: field) }
            Issue.record("Must refuse a stale field edit")
        } catch { #expect(error as? LiteratureFileError == .noteChanged) }
        #expect(try String(contentsOf: url, encoding: .utf8) == external)
    }

    @Test func readingNotesMoveBeforeHighlightsWithoutRemovingPersonalProse() throws {
        let attachment = "<!-- lumen-attachment:ZG9j:begin -->\n### 附件\n原文\n<!-- lumen-attachment:ZG9j:end -->\n"
        let old = try LiteraturePageEditor.setReadingNotes("## 我的整理\n我的正文 [[双链]]\n" + attachment, value: "笔记\n第二行", expected: nil)
        let arranged = try LiteraturePageEditor.arrangePage(old)
        #expect(!arranged.contains("## 我的整理"))
        #expect(arranged.contains("我的正文 [[双链]]"))
        #expect(arranged.contains(attachment))
        #expect(try LiteraturePageEditor.readingNotes(arranged) == "笔记\n第二行")
        #expect(try #require(arranged.range(of: "## 阅读笔记")).lowerBound < #require(arranged.range(of: "<!-- lumen-attachment:")).lowerBound)
        #expect(try LiteraturePageEditor.arrangePage(arranged).components(separatedBy: "## 阅读笔记").count == 2)
        let empty = try LiteraturePageEditor.arrangePage(attachment)
        #expect(try LiteraturePageEditor.readingNotes(empty) == "")
    }

    @Test func starRatingSupportsEmptyLegacyNumbersAndBoundedDragging() throws {
        #expect(LiteratureRating.value("") == 0)
        #expect(LiteratureRating.value("4") == 4)
        #expect(LiteratureRating.value("★★☆☆☆") == 2)
        #expect(LiteratureRating.value("旧文字评价") == nil)
        #expect(LiteratureRating.text(8) == "★★★★★")
        #expect(LiteratureRating.text(-1) == "☆☆☆☆☆")
        #expect(LiteratureRating.value(at: -20, width: 140) == 0)
        #expect(LiteratureRating.value(at: 80, width: 140) == 3)
        #expect(LiteratureRating.value(at: 180, width: 140) == 5)
        let page = try LiteraturePageEditor.set("", key: "评价", value: LiteratureRating.text(3), expected: nil)
        #expect(try LiteraturePageEditor.properties(page).first?.value == "★★★☆☆")
    }
}
