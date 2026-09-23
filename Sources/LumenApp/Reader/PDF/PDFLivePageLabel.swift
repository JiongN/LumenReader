import AppKit
import Combine
import SwiftUI

/// Keep live page feedback out of SwiftUI's animated numeric-text and workspace
/// publication paths. A fixed-size native label redraws only its own contents.
struct PDFLivePageLabel: NSViewRepresentable {
    let viewport: PDFViewportState
    let pageCount: Int
    let color: NSColor

    func makeNSView(context: Context) -> LabelView {
        let label = LabelView()
        label.wantsLayer = true
        return label
    }

    func updateNSView(_ label: LabelView, context: Context) {
        label.count = pageCount
        label.textColor = color
        label.pageIndex = viewport.livePageIndex
        if context.coordinator.viewport !== viewport {
            context.coordinator.viewport = viewport
            context.coordinator.subscription = viewport.livePageChanges.sink { [weak label] index in
                label?.pageIndex = index
            }
        }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: LabelView, context: Context) -> CGSize? {
        let text = "第 \(pageCount) / \(pageCount) 页" as NSString
        return CGSize(width: ceil(text.size(withAttributes: [.font: LabelView.labelFont]).width) + 2, height: 16)
    }

    func makeCoordinator() -> Coordinator { Coordinator() }
    final class Coordinator {
        weak var viewport: PDFViewportState?
        var subscription: AnyCancellable?
    }

    final class LabelView: NSView {
        static let labelFont = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        var count = 0 { didSet { if count != oldValue { needsDisplay = true } } }
        var pageIndex = 0 {
            didSet {
                guard oldValue != pageIndex else { return }
                needsDisplay = true
                setAccessibilityLabel(text)
            }
        }
        var textColor = NSColor.secondaryLabelColor { didSet { needsDisplay = true } }
        private var text: String { "第 \(min(pageIndex + 1, max(1, count))) / \(count) 页" }
        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)
            setAccessibilityElement(true)
            setAccessibilityRole(.staticText)
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func draw(_ dirtyRect: NSRect) {
            let attributes: [NSAttributedString.Key: Any] = [.font: Self.labelFont, .foregroundColor: textColor]
            let size = (text as NSString).size(withAttributes: attributes)
            (text as NSString).draw(at: CGPoint(x: (bounds.width - size.width) / 2,
                                               y: (bounds.height - size.height) / 2), withAttributes: attributes)
        }
    }
}
