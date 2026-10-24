import Foundation
import LumenKit

actor EnhancedDocumentService {
    static let shared = EnhancedDocumentService()
    private let parserOverride: MistralDocumentParser?
    private var paused: [String: (until: Date, reason: String)] = [:]

    init(parser: MistralDocumentParser? = nil) { parserOverride = parser }
    /// Single local worker; each accepted page is an independent durable checkpoint.
    func enrich(_ document: DocumentContext, options: DocumentAIOptions,
                allowedPages: Set<Int>? = nil,
                layoutPages: Set<Int> = [],
                progress: @escaping @Sendable (DocumentExtractionProgress) -> Void) async throws -> DocumentContext {
        guard options.parsingEnabled, document.path.lowercased().hasSuffix(".pdf") else { return document }
        let byPage = Dictionary(grouping: document.evidence) { $0.locator.pageIndex }
        let missing = Set(document.missingUnits)
        let candidates = (0..<document.unitCount).filter { page in
            guard allowedPages?.contains(page) != false else { return false }
            let text = (byPage[page] ?? []).map(\.text).joined()
            // Captions, tables and short readable pages are not OCR failures.
            // Native extraction records genuinely missing pages explicitly.
            return layoutPages.contains(page) || missing.contains(page) || TextLayerTrust.hasInvalidEncoding(text)
        }
        guard !candidates.isEmpty else { return document }
        let key = AICredentialStore.read(account: "mistral-document-ocr") ?? ""
        guard parserOverride != nil || !key.isEmpty else {
            var result = document
            result.extractionNote = "增强解析未配置密钥，已使用本机提取文字"
            return result
        }
        let parser = parserOverride ?? MistralDocumentParser(client: .init(baseURL: options.parsingBaseURL, apiKey: key), model: options.parsingModel)
        let serviceKey = AppPaths.stableHash(options.parsingBaseURL + options.parsingModel + key)
        var result = document
        var failures: [Int] = []
        var completed = 0
        var serviceFailure: String?
        let directory = AppPaths.documentDirectory(forPath: document.path).appendingPathComponent("enhanced", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        // A native layout fix must not invalidate an already-paid cloud page.
        let fileVersion = try PDFDocumentContextCache.fileIdentity(path: document.path)
        for (offset, page) in candidates.enumerated() {
            try Task.checkCancellation()
            do {
            let cacheKey = AppPaths.stableHash("enhanced-3:\(fileVersion):\(options.parsingBaseURL):\(options.parsingModel):\(page)")
            let url = directory.appendingPathComponent(cacheKey + ".json")
            let parsed: MistralDocumentParser.Page
            if let data = try? Data(contentsOf: url) {
                do {
                    parsed = try JSONDecoder().decode(MistralDocumentParser.Page.self, from: data)
                    guard parsed.pageIndex == page else { throw AIError.invalidResponse }
                } catch {
                    try? FileManager.default.moveItem(at: url, to: url.appendingPathExtension("corrupt-" + UUID().uuidString))
                    throw AIError.preparation("增强解析缓存损坏，原件已保留；重试可重新取得该页。")
                }
            } else {
                if let pause = paused[serviceKey], pause.until > Date() {
                    throw AIError.preparation(pause.reason)
                }
                let image = try await PDFPageAssets.shared.image(path: document.path, pageIndex: page)
                parsed = try await parser.parse(image: image, pageIndex: page)
                try Task.checkCancellation()
                guard try DocumentSourceVersion.current(path: document.path) == document.version else { throw AIError.preparation("解析期间文件已变化，请重新读取。") }
                try JSONEncoder().encode(parsed).write(to: url, options: .atomic)
            }
            let body = parsed.blocks.filter { $0.kind != .header && $0.kind != .footer && !$0.text.isEmpty }
            if !body.isEmpty {
                let crossesBoundary = document.evidence.contains { source in
                    (source.pdfFragments?.count ?? 0) > 1 && source.pdfFragments?.contains(where: { $0.pageIndex == page }) == true
                }
                if !crossesBoundary { result.evidence.removeAll { $0.locator.pageIndex == page } }
                result.evidence.append(contentsOf: body.filter { !crossesBoundary || $0.kind == .table }.map {
                    .init(id: $0.id, path: document.path, label: "第 \(page + 1) 页", locator: .pdf(page: page, charOffset: 0), text: $0.text)
                })
                result.missingUnits.removeAll { $0 == page }
            }
            result.blocks.removeAll { $0.pageIndex == page }
            result.blocks.append(contentsOf: parsed.blocks)
            completed += 1
            } catch {
                try Task.checkCancellation()
                guard try DocumentSourceVersion.current(path: document.path) == document.version else { throw AIError.preparation("文件版本已变化，请重新读取。") }
                if (error as? URLError)?.code == .cancelled { throw CancellationError() }
                if let cooldown = Self.serviceCooldown(for: error) {
                    let reason = error.localizedDescription
                    serviceFailure = reason
                    if paused.count > 8 { paused.removeAll() }
                    paused[serviceKey] = (Date().addingTimeInterval(cooldown), reason)
                    failures.append(contentsOf: candidates[offset...].map { $0 + 1 })
                    break
                }
                if let pause = paused[serviceKey], pause.until > Date() {
                    serviceFailure = pause.reason
                    failures.append(contentsOf: candidates[offset...].map { $0 + 1 })
                    break
                }
                failures.append(page + 1)
            }
            progress(.init(completed: offset + 1, total: candidates.count, recognizing: false, phase: "云端增强解析"))
        }
        result.evidence.sort { $0.locator.pageIndex < $1.locator.pageIndex }
        guard try DocumentSourceVersion.current(path: document.path) == document.version else { throw AIError.preparation("文件版本已变化，请重新读取。") }
        result.extractionNote = "增强解析 \(completed)/\(candidates.count) 页 · \(options.parsingModel) · 费用未知"
            + (failures.isEmpty ? "" : " · 未完成页：" + failures.map(String.init).joined(separator: ","))
            + (serviceFailure.map { " · 已使用本机提取文字。\($0)" } ?? "")
        return result
    }

    private static func serviceCooldown(for error: Error) -> TimeInterval? {
        if case AIError.http(let status, _) = error {
            return [400, 401, 402, 403, 404, 422].contains(status) ? 300 : 60
        }
        if error is URLError { return 60 }
        return nil
    }
}
