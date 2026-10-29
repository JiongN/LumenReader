import Foundation
import Testing
import LumenKit
@testable import LumenApp

@Suite("智能目录集成", .serialized)
@MainActor
struct SmartOutlineIntegrationTests {
    private let config = AIProviderConfig(name: "mock", baseURL: "http://127.0.0.1:8777/v1", models: ["outline"], selectedModel: "outline")

    private func file() throws -> URL {
        let url = AppPaths.supportRoot.appendingPathComponent("outline-\(UUID().uuidString).pdf")
        try Data("fixture".utf8).write(to: url)
        return url
    }

    private func wait(_ model: SmartOutlineModel) async throws {
        for _ in 0..<200 where model.phase.isWorking { try await Task.sleep(for: .milliseconds(10)) }
        #expect(!model.phase.isWorking)
    }

    @Test func modelCannotOverridePageAndCacheRejectsSameLengthReplacement() async throws {
        let url = try file()
        defer { try? FileManager.default.removeItem(at: url) }
        let source = SmartOutlineSource(candidates: [.init(id: "h", title: "二、原文标题", unitIndex: 3, depth: 0)], unitCount: 9)
        let bridge = ReaderBridge()
        bridge.unitCount = 9
        bridge.outlineSourceProvider = { source }
        var requests = 0
        let model = SmartOutlineModel(complete: { _, _ in requests += 1; return "[{\"id\":\"h\",\"unit\":999,\"title\":\"错误标题\"}]" })
        let doc = OpenDocument(url: url, kind: .pdf)
        model.bind(to: doc)
        model.generate(bridge: bridge, metadata: DocumentMetadata(), config: config)
        try await wait(model)
        #expect(requests == 1)
        #expect(model.outline?.entries.first?.unitIndex == 3)
        #expect(model.outline?.entries.first?.title == "二、原文标题")
        let reloaded = SmartOutlineModel()
        reloaded.bind(to: doc)
        #expect(reloaded.outline == model.outline)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(100)], ofItemAtPath: url.path)
        #expect(!model.validateSource())
        #expect(model.outline == nil)
        reloaded.bind(to: doc)
        #expect(reloaded.outline == nil)
        #expect(FileManager.default.fileExists(atPath: AppPaths.smartOutlineFile(forPath: url.path).path))
    }

    @Test func cancelledOldRequestCannotReplaceNewOutline() async throws {
        let url = try file()
        defer { try? FileManager.default.removeItem(at: url) }
        let bridge = ReaderBridge()
        bridge.unitCount = 2
        bridge.outlineSourceProvider = { .init(candidates: [.init(id: "h", title: "一、真实标题", unitIndex: 1, depth: 0)], unitCount: 2) }
        var calls = 0
        let model = SmartOutlineModel(complete: { _, _ in
            calls += 1
            if calls == 1 { try? await Task.sleep(for: .milliseconds(80)); return "[{\"id\":\"invented\"}]" }
            return "[{\"id\":\"h\"}]"
        })
        model.bind(to: OpenDocument(url: url, kind: .pdf))
        model.generate(bridge: bridge, metadata: DocumentMetadata(), config: config)
        while calls == 0 { try await Task.sleep(for: .milliseconds(5)) }
        model.cancel()
        model.generate(bridge: bridge, metadata: DocumentMetadata(), config: config)
        try await wait(model)
        try await Task.sleep(for: .milliseconds(100))
        #expect(model.phase == .idle)
        #expect(model.outline?.entries.map(\.title) == ["一、真实标题"])
    }

    @Test func missingPagesFailBeforeNetworkAndLegacyCacheIsNotErased() async throws {
        let url = try file()
        defer { try? FileManager.default.removeItem(at: url) }
        let legacy = SmartOutline(entries: [.init(title: "旧目录", unitIndex: 0)], modelName: "old", sourceUnitCount: 2)
        let cache = AppPaths.smartOutlineFile(forPath: url.path)
        let data = try JSONEncoder().encode(legacy)
        try data.write(to: cache)
        var calls = 0
        let model = SmartOutlineModel(complete: { _, _ in calls += 1; return "[]" })
        model.bind(to: OpenDocument(url: url, kind: .pdf))
        #expect(model.outline == nil)
        let bridge = ReaderBridge()
        bridge.unitCount = 2
        bridge.outlineSourceProvider = { .init(candidates: [.init(id: "h", title: "一、绪论", unitIndex: 0, depth: 0)], unitCount: 2, missingUnits: [1]) }
        model.generate(bridge: bridge, metadata: DocumentMetadata(), config: config)
        try await wait(model)
        #expect(calls == 0)
        #expect(model.outline == nil)
        #expect(try Data(contentsOf: cache) == data)
    }

    @Test func realChinesePaperKeepsHeadingsAndPhysicalPageNumbers() async throws {
        guard let path = ProcessInfo.processInfo.environment["LUMEN_CHINESE_OUTLINE_PDF"] else { return }
        let source = try await Task.detached { try PDFSmartOutlineSource.read(url: URL(fileURLWithPath: path), cachedOCR: [:]) }.value
        #expect(source.unitCount == 9)
        #expect(source.missingUnits.isEmpty)
        #expect(!source.candidates.contains { $0.title.hasPrefix("Understanding Students") || $0.title.hasPrefix("Symbols and Paths") })
        for item in source.candidates { print("[Chinese outline] PDF \(item.unitIndex + 1) depth=\(item.depth): \(item.title)") }
        let expected = [("一、理解学生的符号伦理意蕴", 1), ("(一)理解学生是对符号的意义阐释", 1),
                        ("(二)理解学生是对精神生命的价值关怀", 2), ("(三)理解学生是面向他者的责任担当", 2),
                        ("二、教育交往中理解学生之不当", 3), ("(一)忽视符号之于学生个体的“感官意义”差异", 3),
                        ("(二)漠视学生作为符号表达者的“意愿意义”", 4), ("(三)轻视符号活动中“道德意义”显现的复杂性", 4),
                        ("三、教育交往中理解学生的实现路径", 5), ("(一)关怀式倾听", 5),
                        ("(二)负责任回应", 6), ("(三)许可性沉默", 6), ("参考文献:", 7)]
        for (title, page) in expected {
            #expect(source.candidates.contains { SmartOutlineHeadings.normalized($0.title) == SmartOutlineHeadings.normalized(title) && $0.unitIndex == page })
        }
        let selected = source.candidates.filter { candidate in expected.contains {
            SmartOutlineHeadings.normalized($0.0) == SmartOutlineHeadings.normalized(candidate.title)
        }}
        #expect(selected.map(\.unitIndex) == [1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 6, 7])
    }

    @Test func translatedTitleIsNotASectionButChapterAbstractRemains() {
        let page = "Understanding Students: Ethical Symbols\nZHENG Hang, NIU Jiong\nAbstract: Education is a practice."
        #expect(PDFSmartOutlineSource.isTranslatedArticleTitle("Understanding Students: Ethical Symbols", pageText: page))
        #expect(!PDFSmartOutlineSource.isTranslatedArticleTitle("Chapter 2: Understanding Students", pageText: "Chapter 2: Understanding Students\nZHENG Hang\nAbstract: Education."))
        #expect(!PDFSmartOutlineSource.isTranslatedArticleTitle("一、理解学生", pageText: page))
    }

    @Test func clickingParentOnSharedPageDoesNotSelectItsLastChild() {
        let outline = SmartOutline(entries: [.init(id: "parent", title: "三、实现路径", unitIndex: 5),
                                             .init(id: "child", title: "（一）倾听", unitIndex: 5, depth: 1),
                                             .init(id: "next", title: "（二）回应", unitIndex: 6, depth: 1)],
                                   modelName: "test", sourceUnitCount: 9)
        #expect(SmartOutlineModel.activeEntryID(in: outline, unit: 5, selectedID: "parent") == "parent")
        #expect(SmartOutlineModel.activeEntryID(in: outline, unit: 5, selectedID: "child") == "child")
        #expect(SmartOutlineModel.activeEntryID(in: outline, unit: 6, selectedID: "parent") == "next")
    }
}
