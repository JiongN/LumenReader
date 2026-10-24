import Foundation
import LumenKit

enum DocumentSourceVersion {
    static func current(path: String) throws -> String {
        if path.lowercased().hasSuffix(".pdf") {
            return try PDFDocumentContextCache.identity(path: path)
        }
        let attrs = try FileManager.default.attributesOfItem(atPath: path)
        return "epub-1:\(attrs[.size] ?? 0):\((attrs[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0)"
    }

    static func matches(_ citation: DocumentCitation) throws -> Bool {
        try current(path: citation.path) == citation.version
    }
}
