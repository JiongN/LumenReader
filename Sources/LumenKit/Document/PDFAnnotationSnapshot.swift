import Foundation
import AppKit
import PDFKit

/// Read-only PDF snapshot used in the isolated worker. Ordering and IDs match
/// the reader's annotation list; no PDFKit objects leave this process.
public enum PDFAnnotationSnapshot {
    private static let identityKey = PDFAnnotationKey(rawValue: "/LumenID")
    private static func type(_ annotation: PDFAnnotation) -> String {
        (annotation.type ?? "").trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }
    private static func markup(_ annotation: PDFAnnotation) -> Bool {
        ["Highlight", "Underline", "StrikeOut", "Squiggly"].contains(type(annotation))
    }
    private static func listable(_ annotation: PDFAnnotation) -> Bool {
        annotation.userName != "LumenSearch" && (markup(annotation) || ["Text", "FreeText"].contains(type(annotation)))
    }
    private static func rectangles(_ annotation: PDFAnnotation) -> [CGRect] {
        guard let points = annotation.quadrilateralPoints, points.count >= 4, points.count % 4 == 0 else { return [annotation.bounds] }
        return stride(from: 0, to: points.count, by: 4).map { i in
            let quad = points[i..<(i + 4)].map(\.pointValue)
            let xs = quad.map(\.x), ys = quad.map(\.y)
            return CGRect(x: (xs.min() ?? 0) + annotation.bounds.minX, y: (ys.min() ?? 0) + annotation.bounds.minY,
                          width: (xs.max() ?? 0) - (xs.min() ?? 0), height: (ys.max() ?? 0) - (ys.min() ?? 0))
        }
    }
    private static func continues(_ upper: PDFAnnotation, _ lower: PDFAnnotation) -> Bool {
        guard markup(upper), type(lower) == type(upper), upper.userName == "Lumen", lower.userName == "Lumen",
              let date = upper.modificationDate, lower.modificationDate == date,
              upper.contents == lower.contents, upper.color == lower.color,
              upper.value(forAnnotationKey: identityKey) == nil, lower.value(forAnnotationKey: identityKey) == nil,
              (upper.quadrilateralPoints?.count ?? 0) <= 4, (lower.quadrilateralPoints?.count ?? 0) <= 4 else { return false }
        let a = upper.bounds, b = lower.bounds, height = max(a.height, b.height)
        let gap = a.minY - b.maxY, overlap = min(a.maxX, b.maxX) - max(a.minX, b.minX)
        return gap >= -height * 0.25 && gap <= height * 0.85 && overlap > min(a.width, b.width) * 0.2
    }
    private static func id(_ annotation: PDFAnnotation, page: Int) -> String {
        if let identity = annotation.value(forAnnotationKey: identityKey) as? String { return "\(page)-lumen-\(identity)" }
        let origin = annotation.bounds.origin
        return "\(page)-\(Int(origin.x.rounded()))x\(Int(origin.y.rounded()))-\(type(annotation))"
    }
    private static func color(_ annotation: PDFAnnotation) -> String? {
        guard let c = annotation.color.usingColorSpace(.sRGB) else { return nil }
        return String(format: "#%02X%02X%02X", Int((c.redComponent * 255).rounded()),
                      Int((c.greenComponent * 255).rounded()), Int((c.blueComponent * 255).rounded()))
    }

    public static func read(url: URL) throws -> [AnnotationItem] {
        guard let document = PDFDocument(url: url), !document.isLocked else { throw CocoaError(.fileReadCorruptFile) }
        var items: [AnnotationItem] = []
        for pageIndex in 0..<document.pageCount {
            try autoreleasepool {
                guard let page = document.page(at: pageIndex) else { throw CocoaError(.fileReadCorruptFile) }
                let candidates = page.annotations.filter(listable).sorted {
                    if abs($0.bounds.maxY - $1.bounds.maxY) > 0.5 { return $0.bounds.maxY > $1.bounds.maxY }
                    return $0.bounds.minX < $1.bounds.minX
                }
                var groups: [[PDFAnnotation]] = []
                for annotation in candidates {
                    if let last = groups.last?.last, continues(last, annotation) { groups[groups.count - 1].append(annotation) }
                    else { groups.append([annotation]) }
                }
                var seen: [String: Int] = [:]
                var rows: [(item: AnnotationItem, y: CGFloat, x: CGFloat)] = []
                for group in groups {
                    guard let first = group.first else { continue }
                    let base = id(first, page: pageIndex), count = (seen[base] ?? 0) + 1
                    seen[base] = count
                    let identifier = count == 1 ? base : "\(base)#\(count)"
                    let rect = group.dropFirst().reduce(first.bounds) { $0.union($1.bounds) }
                    var quote = markup(first) ? group.flatMap(rectangles).compactMap { page.selection(for: $0)?.string }.joined(separator: "\n") : ""
                    if quote.isEmpty && type(first) == "FreeText" { quote = first.contents ?? "" }
                    let item = AnnotationItem(id: identifier, locator: .pdf(page: pageIndex, charOffset: 0),
                        quote: quote, note: first.contents ?? "", hasHighlight: markup(first),
                        createdAt: first.modificationDate ?? .distantPast, highlightHex: markup(first) ? color(first) : nil)
                    rows.append((item, rect.origin.y, rect.origin.x))
                }
                rows.sort { abs($0.y - $1.y) > 0.5 ? $0.y > $1.y : $0.x < $1.x }
                items.append(contentsOf: rows.map(\.item))
            }
        }
        return items
    }
}
