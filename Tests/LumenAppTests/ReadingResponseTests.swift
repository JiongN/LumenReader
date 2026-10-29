import AppKit
import CoreText
import PDFKit
import SwiftUI
import Testing
import LumenKit
@testable import LumenApp

@Suite("阅读响应与标签保活", .serialized)
@MainActor
struct ReadingResponseTests {
    private func fixture(pages: Int = 12) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("reading-response-\(UUID()).pdf")
        var box = CGRect(x: 0, y: 0, width: 600, height: 800)
        let context = try #require(CGContext(url as CFURL, mediaBox: &box, nil))
        for index in 0..<pages {
            context.beginPDFPage(nil)
            let text = NSAttributedString(string: "Source paragraph on page \(index + 1).", attributes: [.font: NSFont.systemFont(ofSize: 14)])
            context.textPosition = CGPoint(x: 50, y: 650)
            CTLineDraw(CTLineCreateWithAttributedString(text), context)
            context.endPDFPage()
        }
        context.closePDF()
        return url
    }

    private func workspace() -> AppState {
        let settings = SettingsStore(fileURL: FileManager.default.temporaryDirectory.appendingPathComponent("reading-settings-\(UUID()).json"))
        settings.suppressSave = true
        return AppState(services: AppServices(settingsStore: settings))
    }

    private func host<V: View>(_ content: V) -> NSWindow {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 1000, height: 700),
                              styleMask: [.titled, .resizable, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: content)
        window.orderFront(nil)
        window.contentView?.layoutSubtreeIfNeeded()
        return window
    }

    @Test func homeRoundTripKeepsLoadedReaderAndItsPosition() async throws {
        let url = try fixture()
        defer { try? FileManager.default.removeItem(at: url) }
        let state = workspace()
        state.isAIPanelVisible = false
        let session = ReaderSession(document: OpenDocument(url: url, kind: .pdf))
        state.add(session)
        let window = host(RootView(state: state).environmentObject(state.settingsStore))
        defer { state.teardown(); window.close() }
        for _ in 0..<100 where session.bridge.isLoading || session.bridge.pdfTranslationController == nil {
            try await Task.sleep(for: .milliseconds(20))
        }
        let original = try #require(session.bridge.pdfTranslationController)
        session.bridge.goTo?(.pdf(page: 5, charOffset: 0))
        #expect(session.bridge.currentUnitIndex == 5)
        state.addHomeTab()
        // Let the welcome transition finish; a shorter wait can return before
        // SwiftUI has actually disposed the outgoing reader and give a false pass.
        try await Task.sleep(for: .milliseconds(700))
        #expect(state.activeSession == nil)
        #expect(session.bridge.pdfTranslationController === original)
        state.activate(session)
        try await Task.sleep(for: .milliseconds(400))
        #expect(session.bridge.pdfTranslationController === original)
        #expect(session.bridge.currentUnitIndex == 5)
        #expect(state.loadedSessionIDs == [session.id])
    }

    @Test func residentReaderLimitStillAppliesAcrossHomeAndClose() {
        let state = workspace()
        let sessions = (0..<7).map { index in
            ReaderSession(document: OpenDocument(url: URL(fileURLWithPath: "/tmp/reading-resident-\(index).pdf"), kind: .pdf))
        }
        defer { state.teardown() }
        for session in sessions {
            state.add(session)
            #expect(state.loadedSessionIDs.count <= 2)
            state.addHomeTab()
            #expect(state.loadedSessionIDs.count <= 2)
        }
        state.activate(sessions[0])
        #expect(state.loadedSessionIDs.count == 2)
        #expect(state.loadedSessionIDs.contains(sessions[0].id))
        state.close(sessions[0])
        #expect(!state.loadedSessionIDs.contains(sessions[0].id))
        #expect(state.activeSession != nil)
    }

    @Test func cachedTranslationsKeepTheirSourceAfterReopen() async throws {
        let temporary = try fixture()
        let url: URL
        if let output = ProcessInfo.processInfo.environment["LUMEN_RESPONSE_FIXTURE"] {
            let root = URL(fileURLWithPath: output, isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            url = root.appendingPathComponent("Response.pdf")
            try FileManager.default.copyItem(at: temporary, to: url)
            try FileManager.default.removeItem(at: temporary)
        } else { url = temporary }
        defer {
            if ProcessInfo.processInfo.environment["LUMEN_RESPONSE_FIXTURE"] == nil {
                try? FileManager.default.removeItem(at: url)
            }
        }
        let controller = PDFTranslationController()
        await controller.prepare(documentPath: url.path, target: "zh-Hans",
                                 engineID: MicrosoftTranslationEngine.engineID, glossary: [])
        #expect(controller.paragraphs.count == 12)
        controller.startAll(engineID: MicrosoftTranslationEngine.engineID, target: "zh-Hans", customEngine: FixtureEngine())
        for _ in 0..<100 where controller.phase != .finished { try await Task.sleep(for: .milliseconds(20)) }
        #expect(controller.doneCount == 12)
        let reopened = PDFTranslationController()
        await reopened.prepare(documentPath: url.path, target: "zh-Hans",
                               engineID: MicrosoftTranslationEngine.engineID, glossary: [])
        #expect(reopened.paragraphs == controller.paragraphs)
        #expect(reopened.doneCount == 12)
        for paragraph in reopened.paragraphs {
            #expect(reopened.state(of: paragraph.id).translation?.contains(paragraph.text) == true)
            #expect(paragraph.fragments.first?.pageIndex == paragraph.pageIndex)
        }
    }

    private struct FixtureEngine: TranslationEngine {
        let descriptor = MicrosoftTranslationEngine().descriptor
        func translate(_ text: String, to target: String, from source: String) async throws -> String {
            "定位测试译文：这段文字用于核对原文跳转，不是在线翻译结果。\n" + text
        }
    }

    @Test(arguments: [ReadingFlowMode.continuous, .paged])
    func paragraphNavigationIsPageLocalAndDoesNotWriteAnnotations(mode: ReadingFlowMode) throws {
        let url = try fixture(pages: 120)
        defer { try? FileManager.default.removeItem(at: url) }
        let original = try Data(contentsOf: url)
        let controller = PDFController()
        controller.apply(flowMode: mode)
        let document = try #require(controller.load(url: url))
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 700, height: 700),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = controller.view
        window.contentView?.layoutSubtreeIfNeeded()
        defer { controller.unload(); window.close() }
        var elapsed: [Double] = []
        for index in [119, 0, 60, 1, 90, 2, 30, 3] {
            let page = try #require(document.page(at: index))
            let selection = try #require(page.selection(for: NSRange(location: 0, length: page.numberOfCharacters)))
            let paragraph = PDFParagraph(pageIndex: index, text: selection.string ?? "", bounds: selection.bounds(for: page),
                                         lineCount: 1, firstLineOrdinal: 0, isShort: false)
            let start = ProcessInfo.processInfo.systemUptime
            controller.revealTranslationParagraph(paragraph, preferredPage: index)
            elapsed.append((ProcessInfo.processInfo.systemUptime - start) * 1000)
            #expect(controller.currentPageIndex == index)
            #expect(controller.view.currentSelection?.string?.contains("page \(index + 1).") == true)
            #expect(!controller.isSelectionFromDrag)
            #expect(page.annotations.isEmpty)
        }
        print("[ReadingResponse] mode=\(mode.rawValue) paragraph-navigation-ms=\(elapsed)")
        #expect(try Data(contentsOf: url) == original)
    }
}
