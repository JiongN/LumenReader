import AppKit
import SwiftUI

@MainActor
enum WindowChrome {
    static func toggleFit(_ window: NSWindow, previousFrame: inout NSRect?) {
        guard let desktop = window.screen?.visibleFrame else { return }
        let fitted = abs(window.frame.width - desktop.width) < 2
            && abs(window.frame.height - desktop.height) < 2
            && abs(window.frame.minX - desktop.minX) < 2
            && abs(window.frame.minY - desktop.minY) < 2
        if fitted, let previousFrame {
            window.setFrame(constrained(previousFrame, to: desktop), display: true)
        } else if !fitted {
            previousFrame = window.frame
            window.setFrame(desktop, display: true)
        }
        alignTrafficLights(window)
    }

    static func constrained(_ frame: NSRect, to desktop: NSRect) -> NSRect {
        var result = frame
        result.size.width = min(frame.width, desktop.width)
        result.size.height = min(frame.height, desktop.height)
        result.origin.x = min(max(frame.minX, desktop.minX), desktop.maxX - result.width)
        result.origin.y = min(max(frame.minY, desktop.minY), desktop.maxY - result.height)
        return result
    }

    static func alignTrafficLights(_ window: NSWindow) {
        guard let content = window.contentView else { return }
        let center = NSPoint(x: 0, y: content.isFlipped ? TabBar.height / 2 : content.bounds.maxY - TabBar.height / 2)
        for type: NSWindow.ButtonType in [.closeButton, .miniaturizeButton, .zoomButton] {
            guard let button = window.standardWindowButton(type), let parent = button.superview else { continue }
            let target = parent.convert(center, from: content).y
            button.setFrameOrigin(NSPoint(x: button.frame.minX, y: target - button.frame.height / 2))
        }
    }
}

/// Only empty titlebar areas receive these events; tab and toolbar controls keep theirs.
struct TitlebarDragArea: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { DragView() }
    func updateNSView(_ nsView: NSView, context: Context) {}

    private final class DragView: NSView {
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
        override func mouseDown(with event: NSEvent) {
            guard let window else { return }
            if event.clickCount == 2 {
                (window.windowController as? LumenWindowController)?.toggleFitToDesktop()
            } else {
                window.performDrag(with: event)
            }
        }
    }
}
