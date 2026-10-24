import PDFKit
import AppKit

/// Popup annotations are children of notes, not independent note snapshots.
public enum PDFAnnotationRelationships {
    public static func logicalAnnotations(on page: PDFPage) -> [PDFAnnotation] {
        let annotations = page.annotations
        let linked = Set(annotations.flatMap { children(of: $0, in: annotations) }.map(ObjectIdentifier.init))
        return annotations.filter { !linked.contains(ObjectIdentifier($0)) }
    }

    public static func remove(_ annotations: [PDFAnnotation], from page: PDFPage) {
        // PDFKit does not consistently remove an associated popup with its parent.
        let all = page.annotations
        for annotation in annotations {
            for popup in children(of: annotation, in: all) { page.removeAnnotation(popup) }
            page.removeAnnotation(annotation)
        }
    }

    public static func setContents(_ contents: String, for annotation: PDFAnnotation, on page: PDFPage) {
        for popup in children(of: annotation, in: page.annotations) { popup.contents = contents }
        annotation.contents = contents
    }

    public static func popupBounds(for annotation: PDFAnnotation, on page: PDFPage) -> CGRect? {
        children(of: annotation, in: page.annotations).first?.bounds
    }

    private static func children(of note: PDFAnnotation, in annotations: [PDFAnnotation]) -> [PDFAnnotation] {
        guard note.type?.trimmingCharacters(in: CharacterSet(charactersIn: "/")) != "Popup" else { return [] }
        if note.value(forAnnotationKey: .popup) != nil, let popup = note.popup,
           annotations.contains(where: { $0 === popup }) { return [popup] }
        // PDFKit can persist its automatic note popup without /Parent, leaving
        // popup getters pointing at a different synthesized object. Match only
        // its exact generated geometry and metadata, and only when unique.
        guard note.type?.trimmingCharacters(in: CharacterSet(charactersIn: "/")) == "Text",
              let date = note.modificationDate, let contents = note.contents,
              let color = note.color.usingColorSpace(.sRGB) else { return [] }
        let expected = CGRect(x: note.bounds.minX + 28, y: note.bounds.minY + 28,
                              width: note.bounds.width * 3, height: note.bounds.height * 1.5)
        let matches = annotations.filter { popup in
            guard popup.type?.trimmingCharacters(in: CharacterSet(charactersIn: "/")) == "Popup",
                  popup.value(forAnnotationKey: .parent) == nil, popup.userName == nil,
                  popup.contents == contents, popup.modificationDate == date,
                  popup.color.usingColorSpace(.sRGB) == color else { return false }
            return abs(popup.bounds.minX - expected.minX) < 0.1 && abs(popup.bounds.minY - expected.minY) < 0.1
                && abs(popup.bounds.width - expected.width) < 0.1 && abs(popup.bounds.height - expected.height) < 0.1
        }
        return matches.count == 1 ? matches : []
    }
}
