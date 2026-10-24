import Foundation
import PDFKit

/// Owns a separate PDFKit document; the live reader never crosses executors.
enum PDFTextCopy {
    static func read(url: URL, cachedOCR: [Int: String],
                     progress: @escaping @MainActor (TextExtractionProgress) -> Void) async -> DocumentTextReport? {
        guard !Task.isCancelled, let document = PDFDocument(url: url) else { return nil }
        let total = document.pageCount
        let threshold = PDFScanDetector.isScanned(document) ? 24 : 1
        var report = DocumentTextReport(totalUnits: total)
        var pieces: [String] = []
        pieces.reserveCapacity(total)
        var lastUpdate = ContinuousClock.now
        for index in 0..<total {
            guard !Task.isCancelled else { return nil }
            let raw = autoreleasepool {
                (document.page(at: index)?.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            }
            if raw.count >= threshold {
                pieces.append(raw)
                report.textLayerUnits += 1
            } else if let cached = cachedOCR[index]?.trimmingCharacters(in: .whitespacesAndNewlines), !cached.isEmpty {
                pieces.append(cached)
                report.ocrUnits += 1
            }
            if index + 1 == total || lastUpdate.duration(to: .now) >= .milliseconds(100) {
                lastUpdate = .now
                await progress(.init(completed: index + 1, total: total, phase: "已处理 \(index + 1) / \(total) 页"))
            }
        }
        guard !Task.isCancelled else { return nil }
        report.text = pieces.joined(separator: "\n\n")
        return report
    }
}
