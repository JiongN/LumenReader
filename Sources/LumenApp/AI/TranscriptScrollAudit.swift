import AppKit
import SwiftUI

/// Geometry only; never logs conversation text or enables itself in normal use.
struct TranscriptScrollAudit: NSViewRepresentable {
    var rowID: UUID

    func makeNSView(context: Context) -> Probe {
        let view = Probe()
        view.rowID = rowID
        return view
    }

    func updateNSView(_ view: Probe, context: Context) { view.rowID = rowID }

    final class Probe: NSView {
        var rowID = UUID()
        private var timer: Timer?
        private var previous = ""

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            timer?.invalidate()
            guard window != nil else { return }
            timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.report() }
            }
        }

        private func report() {
            guard let scroll = enclosingScrollView, let document = scroll.documentView else { return }
            let clip = scroll.contentView.bounds
            let row = convert(bounds, to: document)
            let line = String(format: "row=%@ y=%.0f h=%.0f clip=%.0f/%.0f doc=%.0f/%.0f visible=%d",
                String(rowID.uuidString.prefix(8)), row.minY, row.height,
                clip.minY, clip.height, document.bounds.minY, document.bounds.height,
                row.intersects(clip) ? 1 : 0)
            guard line != previous else { return }
            previous = line
            NSLog("%@", "[Lumen][transcript] \(line)")
        }
    }
}
