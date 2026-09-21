import AppKit
import PDFKit

/// Standard PDF QuadPoints describe multiple lines without creating multiple comments.
enum PDFAnnotationGeometry {
    // PDFKit drops /NM on serialization on some macOS versions; a custom PDF key survives.
    static let identityKey = PDFAnnotationKey(rawValue: "/LumenID")

    static func rectangles(of annotation: PDFAnnotation) -> [CGRect] {
        guard let points = annotation.quadrilateralPoints, points.count >= 4, points.count % 4 == 0 else {
            return [annotation.bounds]
        }
        return stride(from: 0, to: points.count, by: 4).map { start in
            let quad = points[start..<(start + 4)].map(\.pointValue)
            let xs = quad.map(\.x), ys = quad.map(\.y)
            return CGRect(x: (xs.min() ?? 0) + annotation.bounds.minX,
                          y: (ys.min() ?? 0) + annotation.bounds.minY,
                          width: (xs.max() ?? 0) - (xs.min() ?? 0),
                          height: (ys.max() ?? 0) - (ys.min() ?? 0))
        }
    }

    static func makeHighlight(rectangles: [CGRect], note: String, color: NSColor, author: String) -> PDFAnnotation? {
        let rects = rectangles.filter { $0.width > 0.5 && $0.height > 0.5 }
        guard let first = rects.first else { return nil }
        let bounds = rects.dropFirst().reduce(first) { $0.union($1) }
        let annotation = PDFAnnotation(bounds: bounds, forType: .highlight, withProperties: nil)
        annotation.quadrilateralPoints = rects.flatMap { rect in
            [CGPoint(x: rect.minX, y: rect.maxY), CGPoint(x: rect.maxX, y: rect.maxY),
             CGPoint(x: rect.minX, y: rect.minY), CGPoint(x: rect.maxX, y: rect.minY)]
                .map { NSValue(point: CGPoint(x: $0.x - bounds.minX, y: $0.y - bounds.minY)) }
        }
        annotation.setValue(UUID().uuidString, forAnnotationKey: identityKey)
        annotation.contents = note
        annotation.color = color
        annotation.userName = author
        annotation.modificationDate = Date()
        return annotation
    }

    /// Only join old Lumen fragments with the same gesture timestamp and adjacent lines.
    /// This is a read-time grouping: opening a book never rewrites old annotations.
    static func continuesLegacyGroup(_ upper: PDFAnnotation, _ lower: PDFAnnotation, author: String) -> Bool {
        guard upper.lumenIsMarkup, lower.lumenTypeName == upper.lumenTypeName,
              upper.userName == author, lower.userName == author,
              let date = upper.modificationDate, lower.modificationDate == date,
              upper.contents == lower.contents, upper.color == lower.color,
              upper.value(forAnnotationKey: identityKey) == nil,
              lower.value(forAnnotationKey: identityKey) == nil,
              (upper.quadrilateralPoints?.count ?? 0) <= 4,
              (lower.quadrilateralPoints?.count ?? 0) <= 4 else { return false }
        let a = upper.bounds, b = lower.bounds
        let height = max(a.height, b.height)
        let gap = a.minY - b.maxY
        let overlap = min(a.maxX, b.maxX) - max(a.minX, b.minX)
        return gap >= -height * 0.25 && gap <= height * 0.85
            && overlap > min(a.width, b.width) * 0.2
    }
}
