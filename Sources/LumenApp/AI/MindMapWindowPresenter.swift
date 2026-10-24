import AppKit
import SwiftUI
import LumenKit

@MainActor
final class MindMapWindowPresenter: NSObject, NSWindowDelegate {
    static let shared = MindMapWindowPresenter()
    private var windows: [NSWindow] = []
    private var diagnosticOpened = false

    func showDiagnostic(root: MindMapNode) {
        guard !diagnosticOpened else { return }
        diagnosticOpened = true
        show(root: root)
    }

    func show(root: MindMapNode) {
        let screen = NSApp.keyWindow?.screen ?? NSScreen.main
        let available = screen?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
        let size = CGSize(width: available.width * 0.92, height: available.height * 0.90)
        let window = MindMapWindow(contentRect: CGRect(origin: .zero, size: size),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
        window.title = "思维导图"
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.collectionBehavior.insert(.fullScreenPrimary)
        window.contentMinSize = CGSize(width: min(700, available.width), height: min(500, available.height))
        window.contentView = NSHostingView(rootView: MindMapView(root: root, expanded: true))
        window.setFrameOrigin(CGPoint(x: available.midX - window.frame.width / 2, y: available.midY - window.frame.height / 2))
        windows.append(window)
        window.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        windows.removeAll { $0 === window }
    }
}

@MainActor
private final class MindMapWindow: NSWindow {
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.charactersIgnoringModifiers?.lowercased() == "w",
           event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command {
            performClose(nil)
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}
