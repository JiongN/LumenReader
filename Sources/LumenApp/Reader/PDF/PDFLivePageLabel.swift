import AppKit
import SwiftUI

/// Subscribe only this small label to live page changes. Publishing them through
/// ReaderBridge would invalidate the entire reading workspace while scrolling.
struct PDFLivePageLabel: View {
    let viewport: PDFViewportState
    let pageCount: Int
    let color: NSColor

    @State private var pageIndex = 0

    var body: some View {
        Text("第 \(min(pageIndex + 1, max(1, pageCount))) / \(pageCount) 页")
            .font(.system(size: 12))
            .monospacedDigit()
            .foregroundStyle(Color(nsColor: color))
            .frame(width: labelWidth, height: 16)
            .onReceive(viewport.livePageChanges) { pageIndex = $0 }
            .task(id: ObjectIdentifier(viewport)) { pageIndex = viewport.livePageIndex }
    }

    private var labelWidth: CGFloat {
        let text = "第 \(pageCount) / \(pageCount) 页" as NSString
        let font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        return ceil(text.size(withAttributes: [.font: font]).width) + 2
    }
}
