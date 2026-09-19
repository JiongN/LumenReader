import Foundation

/// Pure geometry shared by input handling and regression tests.
public enum PanelDragGeometry {
    public static func width(start: Double, delta: Double, range: ClosedRange<Double>) -> Double {
        guard start.isFinite, delta.isFinite else { return range.lowerBound }
        return min(max(start + delta, range.lowerBound), range.upperBound)
    }
}

public enum ReadingViewportGeometry {
    /// Rectangles are in the same view coordinates; output uses a top-left origin.
    public static func normalized(page: CGRect, visible: CGRect, flipped: Bool) -> CGRect? {
        guard page.width > 0, page.height > 0 else { return nil }
        let intersection = page.intersection(visible)
        guard !intersection.isNull, intersection.width > 0, intersection.height > 0 else { return nil }
        return CGRect(x: (intersection.minX - page.minX) / page.width,
                      y: flipped ? (intersection.minY - page.minY) / page.height : (page.maxY - intersection.maxY) / page.height,
                      width: intersection.width / page.width, height: intersection.height / page.height)
    }
}
