import AppKit
import SwiftUI

/// Diagnostic only: retain Lumen's PDF controller and window style, but remove
/// the entire SwiftUI reader host and workspace callbacks. Never writes a PDF.
@MainActor
final class PDFWindowProbe {
    private let controller = PDFController()
    private var window: NSWindow?

    func show() {
        guard let path = LaunchOptions.openPath else {
            NSLog("%@", "[Lumen][window-probe] Missing --open path")
            NSApp.terminate(nil)
            return
        }
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1340, height: 860),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false
        )
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.tabbingMode = .disallowed
        window.isRestorable = false
        window.isReleasedWhenClosed = false
        window.title = "PDF 窗口隔离诊断 · 原生承载"
        let host = NSView(frame: NSRect(x: 0, y: 0, width: 1340, height: 860))
        let pdf = controller.view
        pdf.frame = NSRect(x: 0, y: 0, width: 1340, height: 820)
        pdf.autoresizingMask = [.width, .height]
        host.addSubview(pdf)
        if LaunchOptions.value(for: "--pdf-probe-host") == "swiftui" {
            pdf.removeFromSuperview()
            let hosting = NSHostingController(rootView: PDFKitRepresentable(controller: controller))
            hosting.sizingOptions = []
            window.contentViewController = hosting
            window.title = "PDF 窗口隔离诊断 · 最小 SwiftUI 承载"
        } else {
            window.contentView = host
        }
        window.setContentSize(NSSize(width: 1340, height: 860))
        self.window = window
        guard controller.load(url: URL(fileURLWithPath: path)) != nil else {
            NSLog("%@", "[Lumen][window-probe] Cannot open PDF")
            NSApp.terminate(nil)
            return
        }
        window.center()
        window.makeKeyAndOrderFront(nil)
        JankWatch.shared.start { [weak pdf] in pdf }
        NSLog("%@", "[Lumen][window-probe] \(window.title); production PDFController; no workspace callbacks")
    }
}
