import AppKit
import Combine
import PDFKit
import LumenKit

/// Geometry is published only after native scrolling settles.
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
    /// This channel updates the native page label only, never the SwiftUI tree.
    private(set) var livePageIndex = 0
    let livePageChanges = PassthroughSubject<Int, Never>()

    func updateLivePage(_ index: Int) {
        guard livePageIndex != index else { return }
        livePageIndex = index
        livePageChanges.send(index)
    }
    /// 只在视口连续变化期间为 true。缩略图用它把新渲染延后到手势停稳，
    /// 避免 PDFKit 正文 tile 与缩略图在同一段滚动中争抢 CPU / PDF 解析资源。
    private(set) var isActivelyScrolling = false
    @Published private(set) var scrollSettledRevision = 0

    func setActivelyScrolling(_ value: Bool) {
        guard isActivelyScrolling != value else { return }
        isActivelyScrolling = value
        if !value { scrollSettledRevision &+= 1 }
    }
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
