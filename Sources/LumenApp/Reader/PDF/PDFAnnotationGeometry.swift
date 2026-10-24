import AppKit
import PDFKit

/// Standard PDF QuadPoints describe multiple lines without creating multiple comments.
enum PDFAnnotationGeometry {
    @MainActor
    static func hit(on page: PDFPage, at point: CGPoint) -> PDFAnnotation? {
        page.annotations.reversed().first {
            PDFController.isListableAnnotation($0) && (($0 as? RoundedHighlightAnnotation)?.nativeShouldDisplay ?? $0.shouldDisplay)
                && rectangles(of: $0).contains { $0.contains(point) }
        }
    }
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
        let rects = compactHighlightRows(rectangles)
        guard let first = rects.first else { return nil }
        let bounds = rects.dropFirst().reduce(first) { $0.union($1) }
        let annotation = RoundedHighlightAnnotation(bounds: bounds, forType: .highlight, withProperties: nil)
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

    static func setRectangles(_ rectangles: [CGRect], on annotation: PDFAnnotation) {
        guard let first = rectangles.first else { return }
        let bounds = rectangles.dropFirst().reduce(first) { $0.union($1) }
        annotation.bounds = bounds
        annotation.quadrilateralPoints = rectangles.flatMap { rect in
            [CGPoint(x: rect.minX, y: rect.maxY), CGPoint(x: rect.maxX, y: rect.maxY),
             CGPoint(x: rect.minX, y: rect.minY), CGPoint(x: rect.maxX, y: rect.minY)]
                .map { NSValue(point: CGPoint(x: $0.x - bounds.minX, y: $0.y - bounds.minY)) }
        }
    }

    /// PDFKit 的逐行选区在部分 PDF 中包含整段行距，导致相邻高亮连成色块。
    /// 仅收窄同列相邻行的高亮 QuadPoints；PDF 的字形和原始排版完全不动。
    static func compactHighlightRows(_ rectangles: [CGRect]) -> [CGRect] {
        let rows = rectangles.filter { $0.width > 0.5 && $0.height > 0.5 }
        return rows.map { row in
            let nearest = rows.filter { other in
                guard other != row else { return false }
                let overlap = min(row.maxX, other.maxX) - max(row.minX, other.minX)
                return overlap > min(row.width, other.width) * 0.2
            }.map { abs(row.midY - $0.midY) }.filter { $0 > 1 }.min()
            guard let nearest, row.height > nearest * 0.84 else { return row }
            let height = nearest * 0.84
            return CGRect(x: row.minX, y: row.midY - height / 2, width: row.width, height: height)
        }
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

/// Keep standard Highlight/QuadPoints for PDF interoperability, with a local
/// rounded appearance. Foreign annotations retain their original renderer.
final class RoundedHighlightAnnotation: PDFAnnotation {
    var usesRoundedAppearance: Bool { userName == "Lumen" && lumenTypeName == "Highlight" }
    var nativeShouldDisplay: Bool { super.shouldDisplay }
    // Keep the persisted flags intact. PDFView's optimized markup layer ignores
    // custom drawing, so our page overlay displays these marks instead.
    override var shouldDisplay: Bool {
        get { usesRoundedAppearance ? false : super.shouldDisplay }
        set { super.shouldDisplay = newValue }
    }
    override func draw(with box: PDFDisplayBox, in context: CGContext) {
        guard userName == "Lumen", lumenTypeName == "Highlight" else {
            super.draw(with: box, in: context)
            return
        }
        context.saveGState()
        context.setBlendMode(.multiply)
        let rgb = color.usingColorSpace(.sRGB) ?? color
        context.setFillColor(rgb.cgColor)
        for rect in PDFAnnotationGeometry.rectangles(of: self) {
            let radius = min(3, rect.height * 0.2)
            context.addPath(CGPath(roundedRect: rect, cornerWidth: radius,
                                   cornerHeight: radius, transform: nil))
        }
        context.fillPath()
        context.restoreGState()
    }
}

/// PDFKit decodes annotations on textExtractionQueue and other worker queues.
/// Keep this delegate stateless and outside MainActor: Objective-C protocol
/// dispatch must never acquire a UI executor merely to choose a class.
final class PDFAnnotationDecodingDelegate: NSObject, PDFDocumentDelegate, @unchecked Sendable {
    func `class`(forAnnotationType annotationType: String) -> AnyClass {
        if annotationType.trimmingCharacters(in: CharacterSet(charactersIn: "/")) == "Highlight" {
            return RoundedHighlightAnnotation.self
        }
        return PDFAnnotation.self
    }
}

/// Page overlays are AppKit views, managed separately on the main thread.
@MainActor
final class HighlightAppearanceDelegate: NSObject, @preconcurrency PDFPageOverlayViewProvider {
    private let overlays = NSHashTable<RoundedHighlightOverlay>.weakObjects()

    func pdfView(_ view: PDFView, overlayViewFor page: PDFPage) -> NSView? {
        let overlay = RoundedHighlightOverlay(page: page)
        overlays.add(overlay)
        return overlay
    }

    func refresh() {
        for overlay in overlays.allObjects { overlay.needsDisplay = true }
    }
}

/// PDFKit scales and retains this static page view with its native page cache.
/// No SwiftUI publication or geometry work runs for individual scroll frames.
private final class RoundedHighlightOverlay: NSView {
    private weak var page: PDFPage?

    init(page: PDFPage) {
        self.page = page
        super.init(frame: page.bounds(for: .cropBox))
        wantsLayer = true
        layer?.compositingFilter = "multiplyBlendMode"
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        guard let page, let context = NSGraphicsContext.current?.cgContext else { return }
        let crop = page.bounds(for: .cropBox)
        context.saveGState()
        context.scaleBy(x: bounds.width / max(1, crop.width), y: bounds.height / max(1, crop.height))
        context.translateBy(x: -crop.minX, y: -crop.minY)
        for case let annotation as RoundedHighlightAnnotation in page.annotations
            where annotation.usesRoundedAppearance && annotation.nativeShouldDisplay {
            annotation.draw(with: .cropBox, in: context)
        }
        context.restoreGState()
    }
}
