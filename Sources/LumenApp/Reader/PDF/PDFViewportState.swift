import AppKit
import Combine
import PDFKit
import LumenKit

/// High-frequency geometry has its own publisher, never ReaderBridge.objectWillChange.
@MainActor
final class PDFViewportState: ObservableObject {
    struct Snapshot: Equatable {
        var documentID = UUID()
        var pageRects: [Int: CGRect] = [:]
        var centerPage = 0
        var centerProgress: CGFloat = 0.5
    }
    var onTrackingChange: (() -> Void)?
    var isTracking = false {
        didSet { if isTracking != oldValue { onTrackingChange?() } }
    }
    @Published var snapshot = Snapshot()
    @Published var pageAspects: [CGFloat] = []
}

/// The PDFDocument belongs exclusively to the thumbnail serial queue.
final class PDFThumbnailRenderer: @unchecked Sendable {
    private let url: URL
    private var document: PDFDocument?
    init(url: URL) { self.url = url }
    func render(index: Int, size: CGSize) -> NSImage? {
        if document == nil { document = PDFDocument(url: url) }
        return autoreleasepool { document?.page(at: index)?.thumbnail(of: size, for: .cropBox) }
    }
}
