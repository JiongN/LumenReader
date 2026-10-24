import AppKit
import SwiftUI
import Testing
import LumenKit
@testable import LumenApp

@Suite("对话实际视口回归", .serialized)
@MainActor
struct TranscriptViewportTests {
    private final class FlippedDocument: NSView {
        override var isFlipped: Bool { true }
    }

    @MainActor
    private final class Samples {
        var rows: [UUID: TranscriptGeometrySample] = [:]
        func record(_ sample: TranscriptGeometrySample) { rows[sample.id] = sample }
    }

    @Test func measuredBoundsFollowGrowthAndClampAfterShrink() {
        let scroll = NSScrollView(frame: .init(x: 0, y: 0, width: 337, height: 600))
        let document = FlippedDocument(frame: .init(x: 0, y: 0, width: 337, height: 1_000))
        scroll.documentView = document
        let follower = TranscriptScrollController()
        follower.attach(to: scroll)
        defer { follower.detach() }
        follower.setTail(UUID())
        follower.reconcile()
        #expect(scroll.contentView.bounds.maxY == document.bounds.maxY)
        document.setFrameSize(.init(width: 337, height: 2_000))
        follower.reconcile()
        #expect(scroll.contentView.bounds.maxY == document.bounds.maxY)
        follower.pause()
        scroll.contentView.scroll(to: .init(x: 0, y: 250))
        document.setFrameSize(.init(width: 337, height: 2_500))
        follower.reconcile()
        #expect(scroll.contentView.bounds.minY == 250)
        document.setFrameSize(.init(width: 337, height: 100))
        follower.reconcile()
        #expect(scroll.contentView.bounds.minY == 0)
        document.setFrameSize(.init(width: 337, height: 2_500))
        follower.setTail(UUID())
        follower.reconcile()
        #expect(scroll.contentView.bounds.maxY == document.bounds.maxY)
    }

    @Test func bottomRespectsOrientationAndShortContent() {
        let bounds = CGRect(x: 0, y: 10, width: 337, height: 1_000)
        #expect(TranscriptScrollController.bottom(document: bounds, viewportHeight: 600, flipped: true) == 410)
        #expect(TranscriptScrollController.bottom(document: bounds, viewportHeight: 600, flipped: false) == 10)
        #expect(TranscriptScrollController.bottom(document: bounds, viewportHeight: 1_200, flipped: true) == 10)
    }

    @Test func boundsOnlyUpwardScrollPausesFollowing() async throws {
        let scroll = NSScrollView(frame: .init(x: 0, y: 0, width: 337, height: 600))
        let document = FlippedDocument(frame: .init(x: 0, y: 0, width: 337, height: 2_000))
        scroll.documentView = document
        let follower = TranscriptScrollController()
        follower.attach(to: scroll)
        defer { follower.detach() }
        follower.setTail(UUID())
        follower.reconcile()
        try await Task.sleep(for: .milliseconds(30))
        scroll.contentView.scroll(to: .init(x: 0, y: 300))
        try await Task.sleep(for: .milliseconds(30))
        #expect(!follower.followsTail)
        document.setFrameSize(.init(width: 337, height: 3_000))
        follower.reconcile()
        #expect(scroll.contentView.bounds.minY == 300)
        scroll.contentView.scroll(to: .init(x: 0, y: 2_400))
        try await Task.sleep(for: .milliseconds(30))
        #expect(follower.followsTail)
    }

    @Test func repeatedLayoutBoundsAdjustmentsDoNotLookLikeAReaderScrollingUp() async throws {
        let scroll = NSScrollView(frame: .init(x: 0, y: 0, width: 337, height: 600))
        let document = FlippedDocument(frame: .init(x: 0, y: 0, width: 337, height: 2_000))
        scroll.documentView = document
        let follower = TranscriptScrollController()
        follower.attach(to: scroll)
        defer { follower.detach() }
        follower.setTail(UUID())
        follower.reconcile()
        try await Task.sleep(for: .milliseconds(30))
        document.setFrameSize(.init(width: 337, height: 1_800))
        NotificationCenter.default.post(name: NSView.frameDidChangeNotification, object: document)
        scroll.contentView.scroll(to: .init(x: 0, y: 1_100))
        scroll.contentView.scroll(to: .init(x: 0, y: 1_050))
        #expect(follower.followsTail)
        follower.reconcile()
        #expect(scroll.contentView.bounds.maxY == document.bounds.maxY)
        try await Task.sleep(for: .milliseconds(30))
        scroll.contentView.scroll(to: .init(x: 0, y: 300))
        #expect(!follower.followsTail)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["LUMEN_RUN_NATIVE_LAYOUT_TESTS"] == "1"), arguments: [15.0, 24.0])
    func consecutiveAnswersKeepARealRowInTheViewport(fontSize: Double) async throws {
        _ = NSApplication.shared
        let settings = SettingsStore(fileURL: FileManager.default.temporaryDirectory.appendingPathComponent("transcript-layout-\(UUID()).json"))
        settings.suppressSave = true
        settings.ui.aiTextSize = fontSize
        let state = AppState(services: AppServices(settingsStore: settings))
        let session = ReaderSession(document: OpenDocument(url: URL(fileURLWithPath: "/tmp/layout-only.pdf"), kind: .pdf))
        state.add(session)
        let chat = state.chat
        chat.newConversation(sourcePath: nil, sourceTitle: "Layout only")
        chat.seedDemoAnswer()
        let samples = Samples()
        let root = AIPanelView()
            .environmentObject(state).environmentObject(session)
            .environmentObject(session.bridge).environmentObject(chat).environmentObject(settings)
            .environment(\.transcriptGeometryObserver, { sample in samples.record(sample) })
        let host = NSHostingView(rootView: root)
        let window = NSWindow(contentRect: .init(x: 0, y: 0, width: fontSize > 20 ? 300 : 337, height: 790),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        window.orderFront(nil)
        defer { window.orderOut(nil); window.contentView = nil; session.close() }

        func settle() async throws {
            host.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(180))
        }
        func checkVisible(_ phase: String, tail: UUID) {
            let visible = samples.rows.values.filter { $0.mounted && $0.rect.maxY > 0 && $0.rect.minY < $0.viewportHeight }
            #expect(!visible.isEmpty, "No mounted message in viewport: \(phase)")
            #expect(visible.contains { $0.id == tail }, "Tail outside viewport: \(phase), \(String(describing: samples.rows[tail]))")
            if let row = samples.rows[tail], row.rect.height > row.viewportHeight {
                #expect(abs(row.rect.maxY - row.viewportHeight) <= 16, "Tail not followed: \(phase), \(row)")
            }
        }
        try await settle()
        for round in 1...3 {
            chat.beginFakeStream()
            let tail = try #require(chat.streamingID)
            try await settle()
            checkVisible("round \(round), waiting", tail: tail)
            for index in 1...12 {
                chat.appendFakeDelta("\(index). " + String(repeating: "这是连续追问的布局回归，历史回答不能消失。", count: 12) + "\n\n")
                try await settle()
                checkVisible("round \(round), chunk \(index)", tail: tail)
            }
            chat.endFakeStream()
            try await settle()
            checkVisible("round \(round), Markdown completed", tail: tail)
        }
        window.setContentSize(.init(width: 480, height: 620))
        try await settle()
        checkVisible("resize", tail: try #require(chat.bubbles.last?.id))
        chat.beginFakeStream()
        chat.appendFakeDelta("停止后也保留已返回的内容。")
        try await settle()
        let stopped = try #require(chat.streamingID)
        chat.stop()
        try await settle()
        checkVisible("stopped", tail: stopped)
        let mounted = samples.rows.values.filter(\.mounted)
        #expect(mounted.count < chat.bubbles.count, "Offscreen history was not virtualized")
    }
}
