import Foundation
import Testing
import LumenKit
@testable import LumenApp

@Suite("已配置服务复杂 PDF 实测", .serialized)
@MainActor
struct LiveComplexPDFTests {
    @Test func harrisEnhancedTranslation() async throws {
        guard let output = ProcessInfo.processInfo.environment["LUMEN_HARRIS_LIVE_OUTPUT"],
              let root = ProcessInfo.processInfo.environment["LUMEN_ZOTERO_CORPUS"] else { return }
        let directory = URL(fileURLWithPath: output)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let real = AppPaths.realSupportRoot
        let settings = try JSONDecoder().decode(AppSettings.self, from: Data(contentsOf: real.appendingPathComponent("settings.json")))
        let credentials = CredentialFileStore(directory: real.appendingPathComponent("credentials"))
        var options = settings.ai.documentAI
        options.parsingEnabled = true // This isolated, explicitly enabled live test processes one page only.
        let key = try #require(credentials.read(account: "mistral-document-ocr"))
        let folder = URL(fileURLWithPath: root).appendingPathComponent("UZAHDDK9")
        let file = try #require(FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil).first { $0.pathExtension.lowercased() == "pdf" })
        let cache = PDFDocumentContextCache()
        let snapshot = try await cache.snapshot(path: file.path, pageRange: 1...1)
        let parser = MistralDocumentParser(client: .init(baseURL: options.parsingBaseURL, apiKey: key), model: options.parsingModel)
        let material = PDFTranslationMaterial(service: EnhancedDocumentService(parser: parser))
        let start = Date()
        let result = try await material.prepare(snapshot, options: options, pageRange: 1...1)
        try JSONEncoder().encode(result.paragraphs).write(to: directory.appendingPathComponent("harris-translation-material.json"))
        var report = "# Harris 2021：物理第 2 页\n\n解析：\(result.note ?? "native")\n耗时：\(Date().timeIntervalSince(start)) s\n"
        try report.write(to: directory.appendingPathComponent("harris-live.md"), atomically: true, encoding: .utf8)
        let abstract = try #require(result.paragraphs.first { $0.text.contains("Using the notion of risk aversion") })
        #expect(abstract.text.contains("students’ experience of the curriculum."))
        #expect(!abstract.text.contains("Risk taking;"))
        #expect(await cache.ocrInvocationCount() == 0)
        let config = try #require(settings.ai.translationProvider(for: settings.reader))
        let translation = try await LLMTranslationEngine(config: config,
            apiKey: credentials.read(account: config.keychainAccount) ?? "", glossary: settings.reader.translationGlossary)
            .translate(abstract.text, to: "zh-Hans", from: "en")
        #expect(!translation.isEmpty)
        report += "\n翻译模型：\(config.selectedModel)\n\n## 原文\n\n\(abstract.text)\n\n## 译文\n\n\(translation)\n"
        try report.write(to: directory.appendingPathComponent("harris-live.md"), atomically: true, encoding: .utf8)
        print("HARRIS \(result.note ?? "native") · translation=\(translation.count) chars")
        #expect(result.note?.contains("增强解析 1/1 页") == true)
    }

    @Test func nativeComplexPDFTranslation() async throws {
        guard let output = ProcessInfo.processInfo.environment["LUMEN_LIVE_COMPLEX_OUTPUT"],
              let root = ProcessInfo.processInfo.environment["LUMEN_ZOTERO_CORPUS"] else { return }
        let real = AppPaths.realSupportRoot
        let settings = try JSONDecoder().decode(AppSettings.self, from: Data(contentsOf: real.appendingPathComponent("settings.json")))
        let config = try #require(settings.ai.translationProvider(for: settings.reader))
        let key = CredentialFileStore(directory: real.appendingPathComponent("credentials")).read(account: config.keychainAccount) ?? ""
        let folder = URL(fileURLWithPath: root).appendingPathComponent("WP8N3WSH")
        let file = try #require(FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil).first { $0.pathExtension.lowercased() == "pdf" })
        let snapshot = try await PDFDocumentContextCache.shared.snapshot(path: file.path)
        let abstract = try #require(snapshot.paragraphs.first { $0.text.hasPrefix("Scientists are enthusiastically imagining") })
        let body = try #require(snapshot.paragraphs.first { $0.pageIndex == 4 && $0.text.contains("Oracles") })
        var report = "# 本机复杂 PDF 提取＋配置翻译模型\n\n模型：\(config.selectedModel)，\(snapshot.context.unitCount) 页，\(snapshot.paragraphs.count) 段。\n"
        for source in [abstract, body] {
            let start = Date()
            let text = try await LLMTranslationEngine(config: config, apiKey: key, glossary: settings.reader.translationGlossary)
                .translate(source.text, to: "zh-Hans", from: "en")
            #expect(!text.isEmpty)
            report += "\n## 第 \(source.pageIndex + 1) 页\n\n原文：\n\(source.text)\n\n译文：\n\(text)\n\n耗时：\(String(format: "%.1f", Date().timeIntervalSince(start))) s\n"
            try report.write(to: URL(fileURLWithPath: output).appendingPathComponent("native-translation.md"), atomically: true, encoding: .utf8)
        }
    }

    @Test func configuredOCRModelCatalog() async throws {
        guard let output = ProcessInfo.processInfo.environment["LUMEN_LIVE_COMPLEX_OUTPUT"] else { return }
        let real = AppPaths.realSupportRoot
        let settings = try JSONDecoder().decode(AppSettings.self, from: Data(contentsOf: real.appendingPathComponent("settings.json")))
        let credentials = CredentialFileStore(directory: real.appendingPathComponent("credentials"))
        let key = try #require(credentials.read(account: "mistral-document-ocr"))
        let config = AIProviderConfig(name: "Configured OCR", baseURL: settings.ai.documentAI.parsingBaseURL, models: [], selectedModel: settings.ai.documentAI.parsingModel)
        let models = try await OpenAICompatibleProvider(config: config, apiKey: key).availableModels()
        let ocr = models.filter { $0.localizedCaseInsensitiveContains("ocr") }
        let report = "配置模型：\(config.selectedModel)\n可用 OCR 模型：\(ocr.joined(separator: ", "))\n"
        try report.write(to: URL(fileURLWithPath: output).appendingPathComponent("ocr-model-catalog.txt"), atomically: true, encoding: .utf8)
        #expect(models.contains(config.selectedModel))
    }

    @Test func configuredOCRAndTranslation() async throws {
        guard let output = ProcessInfo.processInfo.environment["LUMEN_LIVE_COMPLEX_OUTPUT"],
              let root = ProcessInfo.processInfo.environment["LUMEN_ZOTERO_CORPUS"] else { return }
        let directory = URL(fileURLWithPath: output)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let real = AppPaths.realSupportRoot
        let settings = try JSONDecoder().decode(AppSettings.self, from: Data(contentsOf: real.appendingPathComponent("settings.json")))
        let credentials = CredentialFileStore(directory: real.appendingPathComponent("credentials"))
        let options = settings.ai.documentAI
        let key = try #require(credentials.read(account: "mistral-document-ocr"))
        let parser = MistralDocumentParser(client: .init(baseURL: options.parsingBaseURL, apiKey: key), model: options.parsingModel)
        var report = "# 复杂 PDF 实测\n\nOCR 模型：\(options.parsingModel)\n"
        var texts: [String] = []
        for (storage, page) in [("WP8N3WSH", 1), ("WP8N3WSH", 4), ("3DATXAFX", 6)] {
            let folder = URL(fileURLWithPath: root).appendingPathComponent(storage)
            let file = try #require(FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil).first { $0.pathExtension.lowercased() == "pdf" })
            let start = Date()
            let image = try await PDFPageAssets.shared.image(path: file.path, pageIndex: page)
            do {
                let result = try await parser.parse(image: image, pageIndex: page)
                #expect(!result.markdown.isEmpty)
                let data = try JSONEncoder().encode(result)
                try data.write(to: directory.appendingPathComponent("\(storage)-p\(page + 1).json"), options: .atomic)
                report += "\n\(storage) 第 \(page + 1) 页：\(result.markdown.count) 字符、\(result.blocks.count) 块、表格 \(result.blocks.filter { $0.kind == .table }.count)、有坐标 \(result.blocks.filter { $0.bounds != nil }.count)、耗时 \(String(format: "%.1f", Date().timeIntervalSince(start))) s\n"
                texts.append(result.markdown)
            } catch {
                report += "\nOCR 失败：\(error.localizedDescription)\n"
                try report.write(to: directory.appendingPathComponent("report.md"), atomically: true, encoding: .utf8)
                throw error
            }
            try report.write(to: directory.appendingPathComponent("report.md"), atomically: true, encoding: .utf8)
        }
        if let config = settings.ai.translationProvider(for: settings.reader), let text = texts.first {
            let translation = try await LLMTranslationEngine(config: config,
                apiKey: credentials.read(account: config.keychainAccount) ?? "", glossary: settings.reader.translationGlossary)
                .translate(String(text.prefix(6000)), to: "zh-Hans", from: "en")
            #expect(!translation.isEmpty)
            try translation.write(to: directory.appendingPathComponent("translated-page.md"), atomically: true, encoding: .utf8)
            report += "\n翻译模型：\(config.selectedModel)，译文 \(translation.count) 字符。\n"
            try report.write(to: directory.appendingPathComponent("report.md"), atomically: true, encoding: .utf8)
        }
    }
}
