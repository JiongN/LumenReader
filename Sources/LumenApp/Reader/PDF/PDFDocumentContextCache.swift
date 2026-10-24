import Foundation
import PDFKit
import LumenKit

struct PDFContextSnapshot: Codable, Sendable {
    private enum CodingKeys: String, CodingKey { case context, paragraphs, ocrPages, pendingOCRLines }
    var context: DocumentContext
    var paragraphs: [PDFParagraph]
    var ocrPages: [Int]
    var pendingOCRLines: [PDFTextLine]?

    init(context: DocumentContext, paragraphs: [PDFParagraph], ocrPages: [Int]) {
        self.context = context; self.paragraphs = paragraphs; self.ocrPages = ocrPages
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        context = try c.decode(DocumentContext.self, forKey: .context)
        paragraphs = try c.decode([PDFParagraph].self, forKey: .paragraphs)
        ocrPages = try c.decode([Int].self, forKey: .ocrPages)
        pendingOCRLines = try c.decodeIfPresent([PDFTextLine].self, forKey: .pendingOCRLines)
        if context.evidence.isEmpty {
            context.evidence = paragraphs.map {
                DocumentEvidence(id: $0.id, path: context.path, label: $0.pageLabel,
                    locator: .pdf(page: $0.pageIndex, charOffset: 0), text: $0.text, pdfFragments: $0.fragments)
            }
        }
        if context.blocks.isEmpty {
            context.blocks = paragraphs.enumerated().map { index, p in
                .init(id: p.id, kind: .paragraph, pageIndex: p.pageIndex, order: index, text: "", parser: "native")
            }
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        var compact = context
        compact.evidence = [] // Text is already stored in paragraphs.
        // Native block metadata contains no duplicate body text; preserve coordinates.
        try c.encode(compact, forKey: .context)
        try c.encode(paragraphs, forKey: .paragraphs)
        try c.encode(ocrPages, forKey: .ocrPages)
        try c.encodeIfPresent(pendingOCRLines, forKey: .pendingOCRLines)
    }
}

/// One serial worker owns private PDFDocuments. Concurrent consumers share a task.
actor PDFDocumentContextCache {
    static let shared = PDFDocumentContextCache()
    static let parserVersion = "layout-12"
    private var pending: [String: Task<PDFContextSnapshot, Error>] = [:]
    private var recent: [String: PDFContextSnapshot] = [:]
    private var waiters: [String: Set<UUID>] = [:]
    private let worker = PDFContextWorker()

    private var progressHandlers: [String: [UUID: @Sendable (DocumentExtractionProgress) -> Void]] = [:]
    private var latestProgress: [String: DocumentExtractionProgress] = [:]
    private var lastProgressDelivery: [String: Date] = [:]

    func recognizePage(path: String, index: Int) async throws -> OCRPageResult {
        try await worker.recognizePage(path: path, index: index)
    }

    func ocrInvocationCount() async -> Int { await worker.ocrInvocationCount }

    static func identity(path: String) throws -> String {
        "\(parserVersion):\(try fileIdentity(path: path))"
    }

    static func fileIdentity(path: String) throws -> String {
        let attrs = try FileManager.default.attributesOfItem(atPath: path)
        return "\(attrs[.size] ?? 0):\((attrs[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0):\((attrs[.creationDate] as? Date)?.timeIntervalSince1970 ?? 0)"
    }

    func snapshot(path: String, pageRange: ClosedRange<Int>? = nil,
                  progress: (@Sendable (DocumentExtractionProgress) -> Void)? = nil) async throws -> PDFContextSnapshot {
        let identity = try Self.identity(path: path)
        let suffix = pageRange.map { "-range-\($0.lowerBound)-\($0.upperBound)" } ?? ""
        let key = path + identity + suffix
        if let value = recent[key], value.pendingOCRLines == nil { return value }
        if let pageRange, let full = recent[path + identity], full.pendingOCRLines == nil,
           Self.canSubset(full, range: pageRange) {
            return try Self.subset(full, range: pageRange)
        }
        let waiter = UUID()
        waiters[key, default: []].insert(waiter)
        if let progress {
            progressHandlers[key, default: [:]][waiter] = progress
            if let latest = latestProgress[key] { progress(latest) }
        }
        let file = AppPaths.documentDirectory(forPath: path).appendingPathComponent("document-context\(suffix).json")
        let worker = self.worker
        let task = pending[key] ?? Task {
            try await worker.load(path: path, identity: identity, file: file, pageRange: pageRange) { value in
                Task { await self.publishProgress(value, key: key) }
            }
        }
        pending[key] = task
        defer { release(key: key, waiter: waiter) }
        let value = try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            Task { await self.release(key: key, waiter: waiter) }
        }
        try Task.checkCancellation()
        let bytes = value.paragraphs.reduce(0) { $0 + $1.text.utf8.count }
        let retainedBytes = recent.values.reduce(0) { result, snapshot in
            result + snapshot.paragraphs.reduce(0) { $0 + $1.text.utf8.count }
        }
        if recent.count >= 2 || retainedBytes + bytes > 32_000_000 { recent.removeAll() }
        if bytes <= 32_000_000 { recent[path + value.context.version + suffix] = value }
        return value
    }

    static func subset(_ full: PDFContextSnapshot, range: ClosedRange<Int>) throws -> PDFContextSnapshot {
        guard range.lowerBound >= 0, range.upperBound < full.context.unitCount else { throw AIError.invalidResponse }
        var result = full
        result.paragraphs = full.paragraphs.filter { paragraph in
            paragraph.fragments.allSatisfy { range.contains($0.pageIndex) }
        }
        let ids = Set(result.paragraphs.map(\.id))
        result.context.evidence = full.context.evidence.filter { ids.contains($0.id) }
        result.context.missingUnits = Array(Set(full.context.missingUnits).union((0..<full.context.unitCount).filter { !range.contains($0) })).sorted()
        result.ocrPages = full.ocrPages.filter { range.contains($0) }
        return result
    }

    static func canSubset(_ full: PDFContextSnapshot, range: ClosedRange<Int>) -> Bool {
        !full.paragraphs.contains { paragraph in
            paragraph.pageIndices.contains(where: range.contains) && !paragraph.pageIndices.allSatisfy(range.contains)
        }
    }

    private func release(key: String, waiter: UUID) {
        waiters[key]?.remove(waiter)
        progressHandlers[key]?[waiter] = nil
        if waiters[key]?.isEmpty == true {
            pending[key]?.cancel()
            pending[key] = nil
            waiters[key] = nil
            progressHandlers[key] = nil
            latestProgress[key] = nil
            lastProgressDelivery[key] = nil
        }
    }

    private func publishProgress(_ value: DocumentExtractionProgress, key: String) {
        guard pending[key] != nil else { return }
        latestProgress[key] = value
        let now = Date()
        guard value.completed == value.total || now.timeIntervalSince(lastProgressDelivery[key] ?? .distantPast) >= 0.15 else { return }
        lastProgressDelivery[key] = now
        progressHandlers[key]?.values.forEach { $0(value) }
    }
}

struct PDFExtractionCheckpoint: Codable {
    struct Page: Codable {
        var lines: [PDFTextLine]
        var size: CGSize
        var usedOCR: Bool
        var verifyRemaining: Bool
    }
    var version: String
    var pageCount: Int
    var pages: [Int: Page]
}

private actor PDFContextWorker {
    private var lastPrune = Date.distantPast
    private(set) var ocrInvocationCount = 0
    func load(path: String, identity: String, file: URL, pageRange: ClosedRange<Int>? = nil,
              progress: @Sendable (DocumentExtractionProgress) -> Void) async throws -> PDFContextSnapshot {
        if Date().timeIntervalSince(lastPrune) > 300 {
            lastPrune = Date()
            let directory = AppPaths.supportRoot.appendingPathComponent("docs", isDirectory: true)
            let folders = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
            RegenerableCachePolicy.prune(files: folders.flatMap { folder in
                ((try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? [])
                    .filter { $0.lastPathComponent.hasPrefix("document-context") && $0.pathExtension == "json" }
            },
                maximumBytes: 128_000_000, maximumAge: 30 * 86400,
                keeping: [file, file.deletingLastPathComponent().appendingPathComponent("document-context-progress.json")])
        }
        var reusableOCRLines: [PDFTextLine]?
        if let data = try? Data(contentsOf: file) {
            if let cached = try? JSONDecoder().decode(PDFContextSnapshot.self, from: data) {
                if cached.context.version == identity {
                    return try await finishCached(cached, path: path, file: file, progress: progress)
                }
                // Old paragraph geometry must be rebuilt after layout fixes.
                // Retain unfinished OCR lines, which can be reclustered without
                // recognizing the same scan again, only for the unchanged file.
                if cached.context.version.hasSuffix(":" + (try PDFDocumentContextCache.fileIdentity(path: path))) {
                    reusableOCRLines = cached.pendingOCRLines
                }
            } else {
                try FileManager.default.moveItem(at: file,
                    to: file.appendingPathExtension("corrupt-\(UUID().uuidString)"))
            }
        }
        guard let doc = PDFDocument(url: URL(fileURLWithPath: path)), !doc.isLocked else {
            throw AIError.invalidResponse
        }
        let range = pageRange ?? 0...max(0, doc.pageCount - 1)
        guard doc.pageCount > 0, range.lowerBound >= 0, range.upperBound < doc.pageCount else {
            throw AIError.invalidResponse
        }
        if pageRange != nil {
            let fullFile = file.deletingLastPathComponent().appendingPathComponent("document-context.json")
            if let data = try? Data(contentsOf: fullFile),
               let full = try? JSONDecoder().decode(PDFContextSnapshot.self, from: data),
               full.context.version == identity, full.pendingOCRLines == nil,
               PDFDocumentContextCache.canSubset(full, range: range) {
                return try PDFDocumentContextCache.subset(full, range: range)
            }
        }
        let selectedPages = Array(range)
        let alreadyRecognized = PDFSearchableWriter.completedPages(in: doc)
        let checkpointFile = file.deletingLastPathComponent().appendingPathComponent("document-context-progress.json")
        var checkpoint = PDFExtractionCheckpoint(version: identity, pageCount: doc.pageCount, pages: [:])
        if let data = try? Data(contentsOf: checkpointFile),
           let previous = try? JSONDecoder().decode(PDFExtractionCheckpoint.self, from: data),
           previous.version == identity, previous.pageCount == doc.pageCount {
            checkpoint = previous
        }
        for (index, lines) in Dictionary(grouping: reusableOCRLines ?? [], by: \.pageIndex)
            where range.contains(index) && checkpoint.pages[index] == nil {
            if let page = doc.page(at: index) {
                checkpoint.pages[index] = .init(lines: lines, size: page.bounds(for: .mediaBox).size,
                    usedOCR: true, verifyRemaining: false)
            }
        }
        var finished = false
        func saveCheckpoint() {
            guard checkpoint.pages.values.contains(where: { $0.usedOCR || $0.verifyRemaining }),
                  let data = try? JSONEncoder().encode(checkpoint) else { return }
            try? data.write(to: checkpointFile, options: .atomic)
        }
        // Save already completed pages even when cancellation stops the next page.
        defer { if !finished { saveCheckpoint() } }
        var lines: [PDFTextLine] = [], sizes: [Int: CGSize] = [:], ocrPages: [Int] = []
        var missing = (0..<doc.pageCount).filter { !range.contains($0) }
        var verifyRemaining = false
        for (ordinal, index) in selectedPages.enumerated() {
            try Task.checkCancellation()
            if let cached = checkpoint.pages[index] {
                sizes[index] = cached.size
                lines.append(contentsOf: cached.lines)
                if cached.usedOCR { ocrPages.append(index) }
                if cached.lines.isEmpty { missing.append(index) }
                verifyRemaining = verifyRemaining || cached.verifyRemaining
                progress(.init(completed: ordinal + 1, total: selectedPages.count, recognizing: cached.usedOCR))
                continue
            }
            guard let page = doc.page(at: index) else { missing.append(index); continue }
            let box = page.bounds(for: .mediaBox)
            sizes[index] = box.size
            let layer = page.string ?? ""
            var pageLines = autoreleasepool { PDFLineExtractor.lines(on: page, pageIndex: index) }
            let sparse = PDFScanDetector.needsOCR(page, textLayer: layer)
            var usedOCR = false
            progress(.init(completed: ordinal, total: selectedPages.count, recognizing: sparse || verifyRemaining))
            if !alreadyRecognized.contains(index), sparse || verifyRemaining {
                ocrInvocationCount += 1
                let recognition = autoreleasepool { try? PDFSearchableWriter.recognize(page, index: index) }
                let recognized = recognition?.0
                if let recognized {
                    let text = recognized.lines.map(\.text).joined(separator: "\n")
                    let assessment = TextLayerTrust.assess(textLayer: layer, ocr: text)
                    if assessment.verdict == .unusable { verifyRemaining = true }
                    if assessment.needsOCR {
                        pageLines = recognition?.1 ?? []
                        ocrPages.append(index)
                        usedOCR = true
                    }
                }
            }
            if pageLines.isEmpty { missing.append(index) }
            lines.append(contentsOf: pageLines)
            if usedOCR || verifyRemaining || !checkpoint.pages.isEmpty {
                checkpoint.pages[index] = .init(lines: pageLines, size: box.size, usedOCR: usedOCR, verifyRemaining: verifyRemaining)
            }
            if (index + 1).isMultiple(of: 10) { saveCheckpoint() }
            progress(.init(completed: ordinal + 1, total: selectedPages.count, recognizing: usedOCR))
        }
        try Task.checkCancellation()
        let paragraphs = PDFParagraphExtractor.paragraphs(from: lines, pageSizes: sizes)
        let evidence = paragraphs.map { p in
            DocumentEvidence(id: p.id, path: path, label: p.pageLabel,
                locator: .pdf(page: p.pageIndex, charOffset: 0), text: p.text, pdfFragments: p.fragments)
        }
        let sections = Self.sections(doc)
        var value = PDFContextSnapshot(context: .init(version: identity, path: path, evidence: evidence,
            missingUnits: missing, unitCount: doc.pageCount, sections: sections), paragraphs: paragraphs, ocrPages: ocrPages)
        value.context.blocks = paragraphs.enumerated().map { offset, p in
            let bounds: DocumentBlock.Bounds?
            if let size = sizes[p.pageIndex], size.width > 0, size.height > 0 {
                bounds = .init(x: Double(p.bounds.minX / size.width), y: 1.0 - Double(p.bounds.maxY / size.height),
                    width: Double(p.bounds.width / size.width), height: Double(p.bounds.height / size.height))
            } else { bounds = nil }
            let caption = p.text.range(of: "^(?i:figure|fig\\.|table|图|表)\\s*[0-9一二三四五六七八九十]+", options: .regularExpression) != nil
            return .init(id: p.id, kind: caption ? .caption : .paragraph, pageIndex: p.pageIndex,
                order: offset, text: "", bounds: bounds, parser: PDFDocumentContextCache.parserVersion,
                printedPage: doc.page(at: p.pageIndex)?.label)
        }
        let attrs = try FileManager.default.attributesOfItem(atPath: path)
        let current = "\(PDFDocumentContextCache.parserVersion):\(attrs[.size] ?? 0):\((attrs[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0):\((attrs[.creationDate] as? Date)?.timeIntervalSince1970 ?? 0)"
        guard current == identity else { throw AIError.cancelled }
        try Task.checkCancellation()
        let ocrSet = Set(ocrPages)
        if !ocrPages.isEmpty { value.pendingOCRLines = lines.filter { ocrSet.contains($0.pageIndex) } }
        // Cache before writing, so a full OCR pass survives a permissions or disk failure.
        if let data = try? JSONEncoder().encode(value) { try data.write(to: file, options: .atomic) }
        if !ocrPages.isEmpty { progress(.init(completed: doc.pageCount, total: doc.pageCount, recognizing: false, phase: "保存可搜索 PDF")) }
        value = try await persist(value, path: path, file: file)
        finished = true
        if pageRange == nil { try? FileManager.default.removeItem(at: checkpointFile) }
        else {
            checkpoint.version = value.context.version
            saveCheckpoint()
        }
        return value
    }

    private func finishCached(_ original: PDFContextSnapshot, path: String, file: URL,
                              progress: @Sendable (DocumentExtractionProgress) -> Void) async throws -> PDFContextSnapshot {
        guard !original.ocrPages.isEmpty else { return original }
        var value = original
        if value.pendingOCRLines == nil {
            guard let doc = PDFDocument(url: URL(fileURLWithPath: path)) else { throw AIError.invalidResponse }
            let complete = PDFSearchableWriter.completedPages(in: doc)
            let remaining = value.ocrPages.filter { !complete.contains($0) }
            guard !remaining.isEmpty else { return value }
            var lines: [PDFTextLine] = []
            for (ordinal, index) in remaining.enumerated() {
                try Task.checkCancellation()
                progress(.init(completed: ordinal, total: remaining.count, recognizing: true))
                guard let page = doc.page(at: index) else { throw PDFSearchableWriter.WriteError.invalidPage }
                ocrInvocationCount += 1
                lines += try autoreleasepool { try PDFSearchableWriter.recognize(page, index: index).1 }
            }
            value.ocrPages = remaining
            value.pendingOCRLines = lines
            try JSONEncoder().encode(value).write(to: file, options: .atomic)
        }
        progress(.init(completed: value.context.unitCount, total: value.context.unitCount, recognizing: false, phase: "保存可搜索 PDF"))
        return try await persist(value, path: path, file: file)
    }

    private func persist(_ original: PDFContextSnapshot, path: String, file: URL) async throws -> PDFContextSnapshot {
        guard let lines = original.pendingOCRLines else { return original }
        try Task.checkCancellation()
        guard try PDFDocumentContextCache.identity(path: path) == original.context.version else { throw PDFSearchableWriter.WriteError.changed }
        let url = URL(fileURLWithPath: path)
        let fingerprint = try PDFLargeAnnotationSave.fingerprint(of: url)
        let grouped = Dictionary(grouping: lines, by: \.pageIndex)
        let pages = original.ocrPages.map { PDFSearchableWriter.Page(index: $0, lines: grouped[$0] ?? []) }
        await MainActor.run { PDFPendingSaves.begin() }
        var value = original
        do {
            let written = try PDFSearchableWriter.write(url: url, pages: pages, expected: fingerprint)
            value.context.version = try PDFDocumentContextCache.identity(path: path)
            value.context.extractionNote = nil
            value.pendingOCRLines = nil
            if written != fingerprint {
                await MainActor.run {
                    NotificationCenter.default.post(name: PDFSearchableWriter.didWrite, object: path,
                        userInfo: ["previousFingerprint": fingerprint, "fingerprint": written])
                }
            }
        } catch is CancellationError {
            await MainActor.run { PDFPendingSaves.end() }
            throw CancellationError()
        } catch {
            value.context.extractionNote = "文字层未写回：\(error.localizedDescription)"
        }
        await MainActor.run { PDFPendingSaves.end() }
        try JSONEncoder().encode(value).write(to: file, options: .atomic)
        return value
    }

    func recognizePage(path: String, index: Int) async throws -> OCRPageResult {
        let url = URL(fileURLWithPath: path)
        let fingerprint = try PDFLargeAnnotationSave.fingerprint(of: url)
        guard let doc = PDFDocument(url: url), let page = doc.page(at: index) else { throw OCRError.renderFailure }
        func restoredResult(_ lines: [PDFTextLine]) -> OCRPageResult {
            let box = page.bounds(for: .mediaBox)
            return .init(text: lines.map(\.text).joined(separator: "\n"), lines: lines.map {
                .init(text: $0.text, confidence: 1,
                      box: CGRect(x: ($0.bounds.minX - box.minX) / box.width, y: ($0.bounds.minY - box.minY) / box.height,
                                  width: $0.bounds.width / box.width, height: $0.bounds.height / box.height))
            }, confidenceIsKnown: false)
        }
        if PDFSearchableWriter.completedPages(in: doc).contains(index) {
            return restoredResult(PDFLineExtractor.lines(on: page, pageIndex: index))
        }
        let checkpointFile = AppPaths.documentDirectory(forPath: path).appendingPathComponent("document-context-progress.json")
        let version = try PDFDocumentContextCache.identity(path: path)
        var checkpoint = PDFExtractionCheckpoint(version: version, pageCount: doc.pageCount, pages: [:])
        if let bytes = try? Data(contentsOf: checkpointFile),
           let previous = try? JSONDecoder().decode(PDFExtractionCheckpoint.self, from: bytes), previous.version == version {
            checkpoint = previous
        }
        let result: OCRPageResult
        let lines: [PDFTextLine]
        if let saved = checkpoint.pages[index], saved.usedOCR {
            lines = saved.lines
            result = restoredResult(lines)
        } else {
            ocrInvocationCount += 1
            (result, lines) = try autoreleasepool { try PDFSearchableWriter.recognize(page, index: index) }
        }
        try Task.checkCancellation()
        checkpoint.pages[index] = .init(lines: lines, size: page.bounds(for: .mediaBox).size, usedOCR: true, verifyRemaining: false)
        try JSONEncoder().encode(checkpoint).write(to: checkpointFile, options: .atomic)
        await MainActor.run { PDFPendingSaves.begin() }
        do {
            let written = try PDFSearchableWriter.write(url: url, pages: [.init(index: index, lines: lines)], expected: fingerprint)
            checkpoint.version = try PDFDocumentContextCache.identity(path: path)
            try JSONEncoder().encode(checkpoint).write(to: checkpointFile, options: .atomic)
            await MainActor.run {
                NotificationCenter.default.post(name: PDFSearchableWriter.didWrite, object: path,
                    userInfo: ["previousFingerprint": fingerprint, "fingerprint": written])
                PDFPendingSaves.end()
            }
        } catch {
            await MainActor.run { PDFPendingSaves.end() }
            throw error
        }
        return result
    }

    static func sections(_ document: PDFDocument) -> [DocumentSection] {
        guard let root = document.outlineRoot else { return [] }
        var starts: [(String, Int)] = []
        func collect(_ parent: PDFOutline, depth: Int) {
            guard depth < 8 else { return }
            for index in 0..<parent.numberOfChildren {
                guard let child = parent.child(at: index) else { continue }
                let destination = child.destination ?? (child.action as? PDFActionGoTo)?.destination
                if let page = destination?.page {
                    let unit = document.index(for: page)
                    if unit != NSNotFound, unit < document.pageCount {
                        starts.append((child.label ?? "章节", unit))
                    }
                } else { collect(child, depth: depth + 1) }
            }
        }
        var parent = root
        var depth = 0
        while parent.numberOfChildren == 1, let child = parent.child(at: 0), child.numberOfChildren > 1, depth < 8 {
            parent = child; depth += 1
        }
        collect(parent, depth: depth)
        starts.sort { $0.1 < $1.1 }
        var seen = Set<Int>()
        starts = starts.filter { seen.insert($0.1).inserted }
        let sections: [DocumentSection] = starts.enumerated().map { index, item in
            .init(title: item.0, startUnit: item.1,
                endUnit: index + 1 < starts.count ? starts[index + 1].1 - 1 : document.pageCount - 1)
        }
        return WholeDocumentPlan.isPageBookmarkList(sections, unitCount: document.pageCount) ? [] : sections
    }
}
