import AppKit
import Testing
@testable import LumenApp

@Suite("窗口顶栏", .serialized)
@MainActor
struct WindowChromeTests {
    @Test func restoreClampsBothDimensionsOnDifferentScreens() {
        let desktop = NSRect(x: -1920, y: 40, width: 1600, height: 850)
        let result = WindowChrome.constrained(NSRect(x: 40, y: -20, width: 2000, height: 1000), to: desktop)
        #expect(result == desktop)
        let small = WindowChrome.constrained(NSRect(x: 50, y: 100, width: 940, height: 640), to: desktop)
        #expect(desktop.contains(small))
        #expect(small.size == NSSize(width: 940, height: 640))
    }

    @Test func trafficLightsAlignWithFixedHeightTitlebar() throws {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 940, height: 700),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        WindowChrome.alignTrafficLights(window)
        let content = try #require(window.contentView)
        for type: NSWindow.ButtonType in [.closeButton, .miniaturizeButton, .zoomButton] {
            let button = try #require(window.standardWindowButton(type))
            let rect = button.convert(button.bounds, to: content)
            let distance = content.isFlipped ? rect.midY : content.bounds.maxY - rect.midY
            #expect(abs(distance - TabBar.height / 2) < 0.5)
        }
    }
}
