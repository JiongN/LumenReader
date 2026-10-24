import AppKit
import PDFKit
import SwiftUI
import Testing
import LumenKit
@testable import LumenApp

@Suite("题录首页版式与检索框", .serialized)
@MainActor
struct PaperIdentityTests {
    typealias Line = PaperIdentityExtractor.Line
    private var chineseHeader: [Line] {
        [Line(text: "JOURNAL OF EDUCATIONAL SCIENCES 2026", page: 0, top: 0.04, height: 10),
         Line(text: "DOI:10.16382/j.cnki.2026.06.001", page: 0, top: 0.08, height: 11),
         Line(text: "遵循知识生产的内在逻辑：中国教育学", page: 0, top: 0.14, height: 30),
         Line(text: "自主知识体系的建构与优化", page: 0, top: 0.18, height: 30),
         Line(text: "褚宏启", page: 0, top: 0.24, height: 15),
         Line(text: "（北京师范大学，北京 100875）", page: 0, top: 0.28, height: 12),
         Line(text: "摘 要：这是论文摘要，不是题名，不应与题名混合。", page: 0, top: 0.34, height: 11),
         Line(text: String(repeating: "这是正文不是题名。", count: 8), page: 0, top: 0.7, height: 11)]
    }

    @Test func chineseMultilineTitleBeatsJournalAndBogusMetadata() {
        let misleadingBody = Line(text: "这行第二页正文具有异常的 PDF 字符行高，但它不是题名。", page: 1, top: 0.15, height: 60)
        let result = PaperIdentityExtractor.extract(lines: chineseHeader + [misleadingBody],
            metadata: GraphIdentity(title: "Microsoft Word - manuscript.doc"), filename: "paper")
        #expect(result.identity.title == "遵循知识生产的内在逻辑：中国教育学自主知识体系的建构与优化")
        #expect(result.identity.authors == ["褚宏启"])
        #expect(result.identity.year == 2026)
        #expect(result.identity.doi == "10.16382/j.cnki.2026.06.001")
    }

    @Test func subtitleAndSpacedChineseNameArePreserved() {
        let lines = [Line(text: "中国电化教育 2024.10", page: 0, top: 0.05, height: 10),
            Line(text: "生成式人工智能何以构成教育奇点 *", page: 0, top: 0.13, height: 29),
            Line(text: "——从深度学习到深度理解", page: 0, top: 0.17, height: 25),
            Line(text: "杨 欣", page: 0, top: 0.21, height: 13),
            Line(text: "西南大学 基础教育研究中心，重庆", page: 0, top: 0.24, height: 10),
            Line(text: "摘要：本文探究人工智能何以构成教育奇点。", page: 0, top: 0.28, height: 10)]
        let result = PaperIdentityExtractor.extract(lines: lines, metadata: .init(), filename: "paper - 2024")
        #expect(result.identity.title == "生成式人工智能何以构成教育奇点——从深度学习到深度理解")
        #expect(result.identity.authors == ["杨欣"])
    }

    @Test func authorBylineMarkerIsNotConfusedWithTheDatabaseVendor() {
        let lines = [Line(text: "2024 年第 6 期", page: 0, top: 0.04, height: 10),
            Line(text: "建立一个“人工智能符号学”", page: 0, top: 0.13, height: 30),
            Line(text: "◎赵毅衡", page: 0, top: 0.23, height: 26),
            Line(text: "摘要：人工智能的超速演变正在改变当代文化。", page: 0, top: 0.28, height: 11),
            Line(text: "DOI:10.19290/j.cnki.51-1076/i.2024.06.005", page: 0, top: 0.4, height: 10)]
        let metadata = GraphIdentity(authors: ["CNKI"])
        #expect(PaperIdentityExtractor.extract(lines: lines, metadata: metadata, filename: "paper").identity.authors == ["赵毅衡"])
        #expect(PaperIdentityExtractor.extract(lines: lines.filter { !$0.text.hasPrefix("◎") },
            metadata: metadata, filename: "paper").identity.authors.isEmpty)
    }

    @Test func bodyTextIsNeverUsedAsTheFirstLongLineFallback() {
        let lines = [Line(text: "这是很长的正文，但是没有足够的标题版式信息。", page: 0, top: 0.3, height: 11)]
        let result = PaperIdentityExtractor.extract(lines: lines, metadata: .init(title: "Untitled"), filename: "真实论文标题 - 王某 - 2025")
        #expect(result.identity.title == "真实论文标题")
        #expect(result.identity.source == "文件名回退（请核对）")
        #expect(result.identity.year == 2025)
        let zotero = PaperIdentityExtractor.extract(lines: [], metadata: .init(), filename: "郑航和牛炅 - 2024 - 理解学生：符号伦理意蕴及其实现路径")
        #expect(zotero.identity.title == "理解学生：符号伦理意蕴及其实现路径")
        let brokenDOI = chineseHeader.filter { !$0.text.hasPrefix("DOI") } + [Line(text: "DOI:10.3969/j.issn.1671 2277.2024.04.002", page: 0, top: 0.08, height: 10)]
        #expect(PaperIdentityExtractor.extract(lines: brokenDOI, metadata: .init(), filename: "paper").identity.doi == nil)
    }

    @Test func secondPageTitleAndEnglishWordBoundariesAreKept() {
        let lines = [Line(text: "Publisher Information", page: 0, top: 0.1, height: 18),
            Line(text: "Risk aversion in a", page: 1, top: 0.15, height: 25),
            Line(text: "performativity culture", page: 1, top: 0.19, height: 25),
            Line(text: "Richard Harris", page: 1, top: 0.25, height: 13),
            Line(text: "ABSTRACT Using a qualitative approach to education.", page: 1, top: 0.4, height: 10)]
        let result = PaperIdentityExtractor.extract(lines: lines, metadata: .init(), filename: "paper")
        #expect(result.identity.title == "Risk aversion in a performativity culture")
        #expect(result.identity.authors == ["Richard Harris"])
    }

    @Test func confirmedIdentitiesAreNotAutomaticallyReplaced() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("missing.pdf")
        let store = directory.appendingPathComponent("graph.json")
        let model = LiteratureGraphModel(document: .init(url: file, kind: .pdf), storageURL: store)
        model.prepare(metadata: .init())
        for _ in 0..<50 where model.snapshot.identity.title.isEmpty { try await Task.sleep(for: .milliseconds(10)) }
        let confirmed = GraphIdentity(title: "用户主动核对过的标题", source: "知网题录")
        model.updateIdentity(confirmed)
        let reopened = LiteratureGraphModel(document: .init(url: file, kind: .pdf), storageURL: store)
        var metadata = DocumentMetadata(); metadata.title = "错误的 PDF 元数据"
        reopened.prepare(metadata: metadata)
        try await Task.sleep(for: .milliseconds(30))
        #expect(reopened.snapshot.identity == confirmed)
        let before = try Data(contentsOf: store)
        reopened.reidentify(); reopened.cancel()
        try await Task.sleep(for: .milliseconds(50))
        #expect(reopened.suggestedIdentity == nil)
        #expect(try Data(contentsOf: store) == before)
        reopened.suggestedIdentity = GraphIdentity(title: "未采用的草稿")
        reopened.message = "已生成待核对题录，保存后才替换当前信息。"
        reopened.discardSuggestedIdentity()
        #expect(reopened.suggestedIdentity == nil)
        #expect(reopened.message.isEmpty)
        #expect(reopened.snapshot.identity == confirmed)
        #expect(try Data(contentsOf: store) == before)
    }

    @Test func longMultilineQueryCannotGrowOrWrapTheNativeField() throws {
        _ = NSApplication.shared
        let query = String(repeating: "中文论文题名\n第二行\r\n第三行 ", count: 20)
        let host = NSHostingView(rootView: CNKIQueryField(text: .constant(query), submit: {}).frame(width: 320, height: 28))
        host.frame = .init(x: 0, y: 0, width: 320, height: 28)
        host.layoutSubtreeIfNeeded()
        func field(_ view: NSView) -> NSSearchField? {
            if let field = view as? NSSearchField { return field }
            return view.subviews.lazy.compactMap(field).first
        }
        let native = try #require(field(host))
        #expect(native.stringValue == CNKIPage.normalizedQuery(query))
        #expect(!native.stringValue.contains("\n"))
        #expect(native.cell?.usesSingleLineMode == true && native.cell?.wraps == false)
        #expect(native.frame.height == 28 && native.frame.width <= 320)
    }

    @Test func cancelledLegacyMetadataUpgradeCanRetry() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let document = OpenDocument(url: directory.appendingPathComponent("missing.pdf"), kind: .pdf)
        let store = directory.appendingPathComponent("graph.json")
        let seed = LiteratureGraphModel(document: document, storageURL: store)
        seed.updateIdentity(.init(title: "旧的错误页眉", source: "首页文字"))
        let model = LiteratureGraphModel(document: document, storageURL: store)
        var metadata = DocumentMetadata(); metadata.title = "新的完整论文题名"
        model.prepare(metadata: metadata)
        model.cancel()
        model.prepare(metadata: metadata)
        for _ in 0..<100 where model.snapshot.identity.title != metadata.title { try await Task.sleep(for: .milliseconds(10)) }
        #expect(model.snapshot.identity.title == metadata.title)
        model.cancel()
    }

    @Test func realPaperHeadersReadOnly() async throws {
        guard let root = ProcessInfo.processInfo.environment["LUMEN_HEADER_CORPUS"] else { return }
        let corpus = [("4UI2CZPY", "遵循知识生产的内在逻辑：中国教育学自主知识体系的建构与优化", "褚宏启"),
            ("AE7Y9GC6", "生成式人工智能何以构成教育奇点——从深度学习到深度理解", "杨欣"),
            ("EYK2SHEE", "“师—智—生”三元教学生态中何以坚守育人初心？", "顾小清"),
            ("FMYI2KAT", "智能时代的课堂教学范式转变：人智共融的结构与样态", "武法提"),
            ("LLZIURRD", "理解学生：符号伦理意蕴及其实现路径", "郑航"),
            ("CLSRZXTR", "建立一个“人工智能符号学”", "赵毅衡")]
        var report = "# 本机中文题录只读测试\n\n"
        for (folder, title, author) in corpus {
            let url = try #require(FileManager.default.contentsOfDirectory(at: URL(fileURLWithPath: root).appendingPathComponent(folder), includingPropertiesForKeys: nil).first { $0.pathExtension == "pdf" })
            let before = try FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date
            let start = Date()
            let result = PaperIdentityExtractor.read(url: url, kind: .pdf)
            let elapsed = Date().timeIntervalSince(start)
            report += "- \(folder)：\(result.identity.title)；\(result.identity.authors.joined(separator: "、"))；\(result.identity.year.map(String.init) ?? "未知")；\(String(format: "%.3f", elapsed)) s\n"
            #expect(PaperIdentityExtractor.normalized(result.identity.title) == PaperIdentityExtractor.normalized(title))
            #expect(result.identity.authors.contains(author))
            #expect(try FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date == before)
        }
        if let output = ProcessInfo.processInfo.environment["LUMEN_HEADER_REPORT"] {
            try report.write(toFile: output, atomically: true, encoding: .utf8)
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let folder = URL(fileURLWithPath: root).appendingPathComponent("4UI2CZPY")
        let file = try #require(FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil).first { $0.pathExtension == "pdf" })
        let store = directory.appendingPathComponent("graph.json")
        let model = LiteratureGraphModel(document: .init(url: file, kind: .pdf), storageURL: store)
        let existing = GraphIdentity(title: "保留人工核对的题录", source: "用户修订")
        model.updateIdentity(existing)
        let before = try Data(contentsOf: store)
        model.reidentify()
        for _ in 0..<200 where model.busy { try await Task.sleep(for: .milliseconds(10)) }
        #expect(!model.busy)
        #expect(model.suggestedIdentity?.authors == ["褚宏启"])
        #expect(model.snapshot.identity == existing)
        #expect(try Data(contentsOf: store) == before)
        model.cancel()

        let zhaoFolder = URL(fileURLWithPath: root).appendingPathComponent("CLSRZXTR")
        let zhao = try #require(FileManager.default.contentsOfDirectory(at: zhaoFolder, includingPropertiesForKeys: nil)
            .first { $0.pathExtension == "pdf" })
        let vendorStore = directory.appendingPathComponent("vendor-author.json")
        let seed = LiteratureGraphModel(document: .init(url: zhao, kind: .pdf), storageURL: vendorStore)
        seed.prepare(metadata: .init())
        for _ in 0..<200 where seed.snapshot.identity.title.isEmpty { try await Task.sleep(for: .milliseconds(10)) }
        seed.updateIdentity(.init(title: "建立一个“人工智能符号学”", authors: ["CNKI"], source: "首页版式（请核对）"))
        seed.cancel()
        let reopened = LiteratureGraphModel(document: .init(url: zhao, kind: .pdf), storageURL: vendorStore)
        reopened.prepare(metadata: .init())
        for _ in 0..<200 where reopened.snapshot.identity.authors == ["CNKI"] { try await Task.sleep(for: .milliseconds(10)) }
        #expect(reopened.snapshot.identity.authors == ["赵毅衡"])
        #expect(reopened.snapshot.identity.title == "建立一个“人工智能符号学”")
        reopened.cancel()
    }
}
