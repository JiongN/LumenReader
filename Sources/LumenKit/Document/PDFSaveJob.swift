import Foundation
import AppKit
import PDFKit

public struct PDFAnnotationRecord: Codable, Sendable {
    public var type: String
    public var bounds: CGRect
    public var color: [Double]
    public var points: [CGPoint]
    public var contents: String?
    public var author: String?
    public var modified: Date?
    public var identity: String?
    public var shouldDisplay: Bool
    public var shouldPrint: Bool
    public var icon: Int
    public var archive: Data?
    public var popupBounds: CGRect?
    public init(type: String, bounds: CGRect, color: [Double], points: [CGPoint], contents: String?, author: String?,
                modified: Date?, identity: String?, shouldDisplay: Bool, shouldPrint: Bool, icon: Int,
                archive: Data? = nil, popupBounds: CGRect? = nil) {
        self.type = type; self.bounds = bounds; self.color = color; self.points = points; self.contents = contents
        self.author = author; self.modified = modified; self.identity = identity
        self.shouldDisplay = shouldDisplay; self.shouldPrint = shouldPrint; self.icon = icon
        self.archive = archive
        self.popupBounds = popupBounds
    }

    /// Preserve foreign/custom fields, then apply the current editable values.
    /// PDFKit's keyed archive does not reliably preserve popup placement.
    public func makeAnnotation() throws -> PDFAnnotation {
        guard color.count == 4, color.allSatisfy({ $0.isFinite && (0...1).contains($0) }),
              [bounds.minX, bounds.minY, bounds.width, bounds.height].allSatisfy(\.isFinite),
              bounds.width >= 0, bounds.height >= 0, points.allSatisfy({ $0.x.isFinite && $0.y.isFinite }) else { throw CocoaError(.coderReadCorrupt) }
        let annotation: PDFAnnotation
        if let archive {
            let decoder = try NSKeyedUnarchiver(forReadingFrom: archive)
            decoder.requiresSecureCoding = false
            guard let value = decoder.decodeObject(forKey: NSKeyedArchiveRootObjectKey) as? PDFAnnotation else { throw CocoaError(.coderReadCorrupt) }
            decoder.finishDecoding()
            annotation = value
        } else {
            let subtype = type.hasPrefix("/") ? type : "/" + type
            annotation = PDFAnnotation(bounds: bounds, forType: PDFAnnotationSubtype(rawValue: subtype), withProperties: nil)
        }
        annotation.bounds = bounds
        annotation.color = NSColor(srgbRed: color[0], green: color[1], blue: color[2], alpha: color[3])
        if archive == nil || !points.isEmpty { annotation.quadrilateralPoints = points.map { NSValue(point: $0) } }
        annotation.contents = contents; annotation.userName = author; annotation.modificationDate = modified
        if let identity { annotation.setValue(identity, forAnnotationKey: PDFAnnotationKey(rawValue: "/LumenID")) }
        annotation.shouldDisplay = shouldDisplay; annotation.shouldPrint = shouldPrint
        if type.trimmingCharacters(in: CharacterSet(charactersIn: "/")) == "Text" {
            annotation.iconType = PDFTextAnnotationIconType(rawValue: icon) ?? .note
        }
        if let popupBounds, let popup = annotation.popup {
            guard [popupBounds.minX, popupBounds.minY, popupBounds.width, popupBounds.height].allSatisfy(\.isFinite),
                  popupBounds.width >= 0, popupBounds.height >= 0 else { throw CocoaError(.coderReadCorrupt) }
            popup.bounds = popupBounds
            popup.contents = contents; popup.color = annotation.color; popup.modificationDate = modified
        }
        return annotation
    }
}

public struct PDFSaveJob: Codable, Sendable {
    public struct Page: Codable, Sendable {
        public var index: Int
        public var annotations: [Data]
        public var replacesAll: Bool
        public init(index: Int, annotations: [Data], replacesAll: Bool) {
            self.index = index; self.annotations = annotations; self.replacesAll = replacesAll
        }
    }
    public var inputPath: String
    public var outputPath: String
    public var expectedPages: Int
    public var pages: [Page]
    public var author: String
    public init(inputPath: String, outputPath: String, expectedPages: Int, pages: [Page], author: String) {
        self.inputPath = inputPath; self.outputPath = outputPath; self.expectedPages = expectedPages
        self.pages = pages; self.author = author
    }
}
