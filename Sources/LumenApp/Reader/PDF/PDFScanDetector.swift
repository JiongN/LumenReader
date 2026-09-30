import Foundation
import PDFKit

/// Text-layer probe shared by opening and full-text extraction. The caller owns
/// the PDFDocument and must keep it on one executor for the duration of a scan.
enum PDFScanDetector {
    static func isScanned(_ document: PDFDocument, samples: Int = 8) -> Bool {
        guard document.pageCount > 0 else { return false }
        let step = max(1, document.pageCount / max(samples, 1))
        var checked = 0
        var empty = 0
        var index = 0
        while index < document.pageCount && checked < samples && !Task.isCancelled {
            checked += 1
            let text = document.page(at: index)?.string ?? ""
            if text.trimmingCharacters(in: .whitespacesAndNewlines).count < 24 {
                empty += 1
            }
            index += step
        }
        guard checked > 0 else { return false }
        return Double(empty) / Double(checked) >= 0.6
    }
}
