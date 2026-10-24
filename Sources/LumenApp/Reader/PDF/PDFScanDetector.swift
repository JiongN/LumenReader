import Foundation
import PDFKit
import LumenKit

/// Text-layer probe shared by opening and full-text extraction. The caller owns
/// the PDFDocument and must keep it on one executor for the duration of a scan.
enum PDFScanDetector {
    static func needsOCR(_ page: PDFPage, textLayer: String) -> Bool {
        if TextLayerTrust.needsVisualCheck(textLayer) { return true }
        // A native page number does not make an image-only scan readable.
        // Inspect resources only for near-empty layers; never rasterize to classify.
        guard textLayer.prefix(80).filter({ $0.isLetter || $0.isNumber }).count < 24,
              let reference = page.pageRef else { return false }
        let box = page.bounds(for: .mediaBox)
        guard box.width > 0, box.height > 0 else { return false }
        func hasPageImage(_ dictionary: CGPDFDictionaryRef?, depth: Int) -> Bool {
            guard depth < 4, let dictionary else { return false }
            var resources: CGPDFDictionaryRef?, objects: CGPDFDictionaryRef?
            guard CGPDFDictionaryGetDictionary(dictionary, "Resources", &resources), let resources,
                  CGPDFDictionaryGetDictionary(resources, "XObject", &objects), let objects else { return false }
            var found = false, visited = 0
            CGPDFDictionaryApplyBlock(objects, { _, object, _ in
                visited += 1
                guard visited <= 128 else { return false }
                var stream: CGPDFStreamRef?
                guard CGPDFObjectGetValue(object, .stream, &stream), let stream,
                      let attributes = CGPDFStreamGetDictionary(stream) else { return true }
                var subtype: UnsafePointer<CChar>?
                if CGPDFDictionaryGetName(attributes, "Subtype", &subtype), let subtype, String(cString: subtype) == "Image" {
                    var width = 0, height = 0
                    if CGPDFDictionaryGetInteger(attributes, "Width", &width),
                       CGPDFDictionaryGetInteger(attributes, "Height", &height), width >= 400, height >= 400 {
                        let ratio = (Double(width) / Double(height)) / (box.width / box.height)
                        found = (0.85...1.18).contains(ratio) || (0.85...1.18).contains(1 / ratio)
                    }
                } else { found = hasPageImage(attributes, depth: depth + 1) }
                return !found
            }, nil)
            return found
        }
        return hasPageImage(reference.dictionary, depth: 0)
    }

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
