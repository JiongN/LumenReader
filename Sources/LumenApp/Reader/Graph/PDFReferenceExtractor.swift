import Foundation
import PDFKit
import LumenKit

enum PDFReferenceExtractor {
    static func entries(at url: URL) -> [LocalReferenceParser.Entry] {
        guard let document = PDFDocument(url: url), document.pageCount > 0 else { return [] }
        var pages: [(lines: [PDFTextLine], size: CGRect, fallback: String?)] = []
        var foundHeading = false
        for index in max(0, document.pageCount - 12)..<document.pageCount {
            if Task.isCancelled { return [] }
            let extracted: (lines: [PDFTextLine], size: CGRect, fallback: String?)? = autoreleasepool {
                guard let page = document.page(at: index) else { return nil }
                let native = page.string ?? ""
                let box = page.bounds(for: .mediaBox)
                if native.trimmingCharacters(in: .whitespacesAndNewlines).count < 30 {
                    guard let image = PDFPageRenderer.render(page, scale: 2),
                          let result = try? OCRService.recognize(in: image) else { return nil }
                    return ([], box, result.text)
                }
                if !foundHeading && !native.components(separatedBy: .newlines).contains(where: LocalReferenceParser.isHeading) {
                    return nil
                }
                return (PDFLineExtractor.lines(on: page, pageIndex: index), box, nil)
            }
            guard let extracted else { continue }
            let texts = extracted.fallback.map { $0.components(separatedBy: .newlines) } ?? extracted.lines.map(\.text)
            foundHeading = foundHeading || texts.contains(where: LocalReferenceParser.isHeading)
            if foundHeading { pages.append(extracted) }
        }
        var headerCounts: [String: Int] = [:]
        for page in pages {
            let headers = Set(page.lines.filter { $0.bounds.midY > page.size.maxY - page.size.height * 0.18 }.map(\.text))
            for text in headers where !LocalReferenceParser.isHeading(text) { headerCounts[text, default: 0] += 1 }
        }
        let ordered = pages.map { page -> String in
            if let fallback = page.fallback { return fallback }
            // A footnote after the last column must not interrupt a citation continuing next page.
            let notes = page.lines.filter {
                $0.bounds.midY < page.size.minY + page.size.height * 0.2
                    && $0.text.range(of: #"^[①-⑳]"#, options: .regularExpression) != nil
            }
            let content = page.lines.filter { line in
                if line.bounds.midY > page.size.maxY - page.size.height * 0.18, headerCounts[line.text, default: 0] > 1 { return false }
                if notes.contains(where: { note in
                    let overlap = min(note.bounds.maxX, line.bounds.maxX) - max(note.bounds.minX, line.bounds.minX)
                    return line.bounds.maxY <= note.bounds.maxY + 1 && overlap > min(note.bounds.width, line.bounds.width) * 0.5
                }) { return false }
                let compact = line.text.filter { !$0.isWhitespace }
                if compact.count <= 4, compact.allSatisfy(\.isNumber),
                   line.bounds.midY < page.size.minY + page.size.height * 0.12 { return false }
                return true
            }
            return PDFParagraphExtractor.columnRegions(content).flatMap { $0.map(\.text) }.joined(separator: "\n")
        }
        return LocalReferenceParser.entries(in: ordered.joined(separator: "\n"))
    }
}
