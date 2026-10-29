import Foundation
import Testing
import LumenKit
@testable import LumenApp

@Suite struct LiteratureNoteCodecTests {
    private func annotation(_ id: String, _ note: String, quote: String = "原文") -> LiteratureAnnotation {
        LiteratureAnnotation(AnnotationItem(id: id, locator: .pdf(page: 2, charOffset: 0), quote: quote,
                                            note: note, hasHighlight: true, createdAt: .distantPast,
                                            highlightHex: "#FFFF00"))
    }

    private func snapshot(_ items: [LiteratureAnnotation], id: String = "doc-1") -> LiteratureAttachmentSnapshot {
        LiteratureAttachmentSnapshot(documentID: id, title: "附件.pdf", annotations: items)
    }

    private func legacySection(_ snapshot: LiteratureAttachmentSnapshot) throws -> String {
        let begin = LiteratureNoteCodec.attachmentMarker(for: snapshot.documentID)
        let end = begin.replacingOccurrences(of: ":begin", with: ":end")
        var rows = [begin, "### " + snapshot.title]
        for item in snapshot.annotations {
            rows += ["<!-- lumen-annotation:legacy:begin -->", "> " + item.quote, "[第 3 页](lumen://open)"]
            if !item.note.isEmpty { rows.append("**批注**") }
            rows += ["<!-- lumen-note:begin -->", item.note, "<!-- lumen-note:end -->", "<!-- lumen-annotation:end -->"]
        }
        rows.append(end)
        return rows.joined(separator: "\n")
    }

    @Test func authoritativeExportRestoresEditsWithoutTouchingPersonalSections() throws {
        let snap = snapshot([annotation("a", "源正文")])
        let legacy = try (document: "# 文献\n\n" + legacySection(snap), baseline: LiteratureNoteBaseline(snapshot: snap, rendered: legacySection(snap)))
        let personal = try LiteraturePageEditor.setReadingNotes(legacy.document, value: "个人思考\n[[链接]]", expected: nil)
        let damaged = personal.replacingOccurrences(of: "源正文", with: "外部临时修改").replacingOccurrences(of: "<!-- lumen-note:end -->", with: "")
        let exported = try LiteratureNoteCodec.export(document: damaged, snapshot: snap, baseline: legacy.baseline)
        #expect(exported.replacedLocalExport)
        #expect(exported.document.contains("## 批注"))
        #expect(!exported.document.contains("### 附件.pdf"))
        #expect(!exported.document.contains("<!-- lumen-annotation:"))
        #expect(exported.document.contains("color: #FFFF00"))
        #expect(exported.document.contains("> 源正文"))
        #expect(try LiteraturePageEditor.readingNotes(exported.document) == "个人思考\n[[链接]]")
        let again = try LiteratureNoteCodec.export(document: exported.document, snapshot: snap, baseline: exported.baseline)
        #expect(again.document == exported.document)
        #expect(!again.replacedLocalExport)
        let erased = try LiteratureNoteCodec.export(document: personal.components(separatedBy: LiteratureNoteCodec.attachmentMarker(for: snap.documentID))[0], snapshot: snap, baseline: legacy.baseline)
        #expect(erased.document.contains("> 源正文"))
        #expect(erased.replacedLocalExport)
    }

    @Test func sourceWinsAndRepeatedExportsPreserveUserContent() throws {
        let original = "---\nitemLink: zotero://select/library/items/ABCDEFGH\n---\n\n双链 [[研究]]\n"
        let first = try LiteratureNoteCodec.export(document: original, snapshot: snapshot([annotation("a", "A"), annotation("b", "B")]), baseline: nil)
        let edited = first.document.replacingOccurrences(of: "> A\n", with: "> 外部正文\n")
        let second = try LiteratureNoteCodec.export(document: edited, snapshot: snapshot([annotation("a", "Lumen 版本"), annotation("b", "B2")]), baseline: first.baseline)
        #expect(second.replacedLocalExport)
        #expect(second.document.hasPrefix(original))
        #expect(!second.document.contains("外部正文"))
        #expect(second.document.contains("> Lumen 版本"))
        #expect(second.document.contains("> B2"))
        let deleted = try LiteratureNoteCodec.export(document: second.document, snapshot: snapshot([annotation("a", "Lumen 版本")]), baseline: second.baseline)
        #expect(!deleted.document.contains("> B2"))
        let again = try LiteratureNoteCodec.export(document: deleted.document, snapshot: deleted.baseline.snapshot, baseline: deleted.baseline)
        #expect(again.document == deleted.document)
        #expect(!again.replacedLocalExport)
    }

    @Test func brokenBoundariesAndDuplicateIdentitiesNeverOverwriteContent() throws {
        let snap = snapshot([annotation("a", "原值")])
        let first = try LiteratureNoteCodec.export(document: "保留", snapshot: snap, baseline: nil)
        let marker = LiteratureNoteCodec.compactMarker(LiteratureNoteCodec.attachmentMarker(for: snap.documentID))
        for damaged in [first.document.replacingOccurrences(of: marker, with: ""), first.document + first.baseline.rendered] {
            #expect(throws: LiteratureNoteError.malformed) {
                try LiteratureNoteCodec.export(document: damaged, snapshot: snap, baseline: first.baseline)
            }
        }
        #expect(throws: LiteratureNoteError.duplicateAnnotation("")) {
            try LiteratureNoteCodec.export(document: first.document, snapshot: snapshot([annotation("a", "1"),annotation("a", "2")]), baseline: first.baseline)
        }
    }

    @Test func twoAttachmentsShareOneNote() throws {
        let a = try LiteratureNoteCodec.export(document: "# 文章", snapshot: snapshot([annotation("a", "甲")]), baseline: nil)
        let b = try LiteratureNoteCodec.export(document: a.document, snapshot: snapshot([annotation("b", "乙")], id: "doc-2"), baseline: nil)
        let updated = try LiteratureNoteCodec.export(document: b.document, snapshot: snapshot([annotation("a", "新甲")]), baseline: a.baseline)
        #expect(updated.document.contains("新甲"))
        #expect(updated.document.contains("乙"))
        #expect(updated.document.hasPrefix("# 文章"))
    }

    @Test func zoteroMetadataRefreshPreservesAndProtectsOtherContent() throws {
        var identity = LiteratureZoteroIdentity(library: "library", itemKey: "ABCDEFGH", attachmentKey: "ATTACH01",
                                                title: "旧标题", authors: "作者", year: "2024")
        let markers = LiteratureMetadataCodec.render(identity).components(separatedBy: "\n")
        let legacy = markers[0] + "\n## 文献信息\n- 作者：作者\n" + markers[1]
        let document = "---\n自定义: 保留\n---\n\n我的笔记 [[概念]]\n" + legacy
        identity.title = "新标题"
        let second = try LiteratureMetadataCodec.merge(document: document, identity: identity, baseline: legacy)
        #expect(!second.document.contains("## 文献信息"))
        #expect(second.document.contains("自定义: 保留"))
        #expect(second.document.contains("我的笔记 [[概念]]"))
        let edited = document.replacingOccurrences(of: "- 作者：作者", with: "- 作者：自己修改")
        #expect(throws: LiteratureNoteError.changedStructure) {
            try LiteratureMetadataCodec.merge(document: edited, identity: identity, baseline: legacy)
        }
    }

    @Test func emptyHighlightsHaveNoCommentLabelAndLegacySectionsMigrate() throws {
        let snapshot = snapshot([annotation("plain", ""), annotation("with-note", "正文")])
        let rendered = try legacySection(snapshot)
        #expect(rendered.components(separatedBy: "**批注**").count - 1 == 1)
        let legacy = rendered.replacingOccurrences(of: "<!-- lumen-note:begin -->\n\n", with: "**批注**\n<!-- lumen-note:begin -->\n\n")
        let migrated = try LiteratureNoteCodec.export(document: legacy, snapshot: snapshot,
            baseline: .init(snapshot: snapshot, rendered: legacy))
        #expect(!migrated.document.contains("**批注**"))
        #expect(migrated.document.contains("color: #FFFF00"))
    }

    @Test func colorTagsAreRemovedWithoutLosingOriginalAnnotationColor() throws {
        let snapshot = snapshot([annotation("plain", "")])
        let rendered = try legacySection(snapshot)
        #expect(!rendered.contains("#FFFF00"))
        let legacy = rendered.replacingOccurrences(of: ")\n<!-- lumen-note:begin", with: ") · #FFFF00\n<!-- lumen-note:begin")
        #expect(legacy != rendered)
        let migrated = try LiteratureNoteCodec.export(document: legacy, snapshot: snapshot,
            baseline: .init(snapshot: snapshot, rendered: legacy))
        #expect(!migrated.document.contains("**批注**"))
        #expect(migrated.document.contains("color: #FFFF00"))
        #expect(migrated.baseline.snapshot.annotations.first?.color == "#FFFF00")
    }
}
