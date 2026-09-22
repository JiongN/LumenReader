import AppKit
import Combine
import PDFKit
import Testing
@testable import LumenApp

@Suite("PDF 滚动状态发布", .serialized)
@MainActor
struct PDFScrollPublicationTests {
    private func fixture() throws -> (PDFController, PDFViewportState, URL) {
        _ = NSApplication.shared
        let document = PDFDocument()
        for index in 0..<3 {
            let page = PDFPage()
            page.setBounds(CGRect(x: 0, y: 0, width: 600, height: 800), for: .mediaBox)
            document.insert(page, at: index)
        }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".pdf")
        try #require(document.write(to: url))
        let controller = PDFController()
        controller.view.frame = CGRect(x: 0, y: 0, width: 600, height: 400)
        try #require(controller.load(url: url) != nil)
        let state = PDFViewportState()
        controller.connectViewport(state)
        controller.flushPendingReadingPosition()
        return (controller, state, url)
    }

    @Test func continuousNotificationsDoNotPublishUntilIdle() async throws {
        let (controller, state, url) = try fixture()
        defer { controller.unload(); try? FileManager.default.removeItem(at: url) }
        let initialRevision = state.scrollSettledRevision
        var changes = 0
        let token = state.objectWillChange.sink { changes += 1 }
        defer { token.cancel() }
        // The sequence lasts longer than the idle interval, but no individual
        // gap does. A throttle (instead of a debounce) would fail this assertion.
        for _ in 0..<5 {
            NotificationCenter.default.post(name: .PDFViewPageChanged, object: controller.view)
            try await Task.sleep(nanoseconds: 70_000_000)
            #expect(changes == 0)
        }
        #expect(state.isActivelyScrolling)
        try await Task.sleep(nanoseconds: 350_000_000)
        #expect(!state.isActivelyScrolling)
        #expect(state.scrollSettledRevision == initialRevision + 1)
        #expect(changes == 1)
    }

    @Test func unloadCancelsPendingPublication() async throws {
        let (controller, state, url) = try fixture()
        defer { try? FileManager.default.removeItem(at: url) }
        NotificationCenter.default.post(name: .PDFViewPageChanged, object: controller.view)
        controller.unload()
        let revisionAfterUnload = state.scrollSettledRevision
        try await Task.sleep(nanoseconds: 350_000_000)
        #expect(state.scrollSettledRevision == revisionAfterUnload)
        #expect(controller.document == nil)
    }
}
