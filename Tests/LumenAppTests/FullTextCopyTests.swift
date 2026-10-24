import AppKit
import Combine
import Testing
import LumenKit
@testable import LumenApp

@Suite("全文复制进度", .serialized)
@MainActor
struct FullTextCopyTests {
    @Test func quickCopyNeverShowsProgressOrSuccessToast() async throws {
        let state = AppState()
        let session = makeSession()
        let pasteboard = NSPasteboard.withUniqueName()
        defer { session.close(); pasteboard.releaseGlobally() }
        var shown = 0
        let observation = session.$busy.compactMap { $0 }.sink { _ in shown += 1 }
        defer { observation.cancel() }
        session.bridge.extractFullText = { _, progress in
            progress(.init(completed: 1, total: 1, phase: "完成"))
            return .init(text: "Full text", totalUnits: 1, textLayerUnits: 1)
        }
        state.add(session)
        state.copyFullText(to: pasteboard)
        let task = try #require(session.fullTextTask)
        await task.value
        try await Task.sleep(for: .milliseconds(400))
        #expect(pasteboard.string(forType: .string) == "Full text")
        #expect(shown == 0 && session.busy == nil && session.fullTextTask == nil)
        #expect(state.toast == nil)
    }

    @Test func longCopyShowsLatestProgressWithoutPublishingEveryPage() async throws {
        let state = AppState()
        let session = makeSession()
        let pasteboard = NSPasteboard.withUniqueName()
        defer { session.close(); pasteboard.releaseGlobally() }
        let extraction = CopyExtraction()
        session.bridge.extractFullText = { _, progress in await extraction.run(progress) }
        var shown = 0
        let observation = session.$busy.compactMap { $0 }.sink { _ in shown += 1 }
        defer { observation.cancel() }
        state.add(session)
        state.copyFullText(to: pasteboard)
        let task = try #require(session.fullTextTask)
        try await wait { extraction.progress != nil }
        extraction.progress?(.init(completed: 12, total: 1000, phase: "第 12 页"))
        #expect(session.busy == nil)
        try await wait { session.busy != nil }
        #expect(session.busy?.detail == "第 12 页")
        for page in 13...1000 {
            extraction.progress?(.init(completed: page, total: 1000, phase: "第 \(page) 页"))
        }
        #expect(shown <= 2)
        extraction.finish("All pages")
        await task.value
        #expect(session.busy == nil && session.busyCancel == nil)
        #expect(pasteboard.string(forType: .string) == "All pages")
    }

    @Test func closedCopyCannotShowDelayedOverlayOrOverwriteNewerCopy() async throws {
        let state = AppState()
        let first = makeSession(), second = makeSession()
        let pasteboard = NSPasteboard.withUniqueName()
        defer { first.close(); second.close(); pasteboard.releaseGlobally() }
        let old = CopyExtraction()
        first.bridge.extractFullText = { _, progress in await old.run(progress) }
        state.add(first)
        state.copyFullText(to: pasteboard)
        let oldTask = try #require(first.fullTextTask)
        try await wait { old.progress != nil }
        first.close()
        second.bridge.extractFullText = { _, _ in .init(text: "New copy", totalUnits: 1, textLayerUnits: 1) }
        state.add(second)
        state.copyFullText(to: pasteboard)
        let newTask = try #require(second.fullTextTask)
        await newTask.value
        old.progress?(.init(completed: 1, total: 1, phase: "Late progress"))
        old.finish("Old copy")
        await oldTask.value
        try await Task.sleep(for: .milliseconds(400))
        #expect(first.busy == nil && second.busy == nil)
        #expect(pasteboard.string(forType: .string) == "New copy")
    }

    @Test func partialCopyStillWarnsAboutMissingPages() async throws {
        let state = AppState()
        let session = makeSession()
        let pasteboard = NSPasteboard.withUniqueName()
        defer { session.close(); pasteboard.releaseGlobally(); state.dismissToast() }
        session.bridge.extractFullText = { _, _ in .init(text: "Partial", totalUnits: 3, textLayerUnits: 1) }
        state.add(session)
        state.copyFullText(to: pasteboard)
        let task = try #require(session.fullTextTask)
        await task.value
        #expect(pasteboard.string(forType: .string) == "Partial")
        #expect(state.toast != nil)
        #expect(session.busy == nil)
    }

    private func makeSession() -> ReaderSession {
        ReaderSession(document: .init(url: FileManager.default.temporaryDirectory
            .appendingPathComponent("copy-test-\(UUID()).pdf"), kind: .pdf))
    }

    private func wait(_ condition: () -> Bool) async throws {
        for _ in 0..<200 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        Issue.record("Copy state did not settle")
    }
}

@MainActor
private final class CopyExtraction {
    var progress: (@MainActor (TextExtractionProgress) -> Void)?
    private var continuation: CheckedContinuation<DocumentTextReport, Never>?

    func run(_ progress: @escaping @MainActor (TextExtractionProgress) -> Void) async -> DocumentTextReport {
        self.progress = progress
        return await withCheckedContinuation { continuation = $0 }
    }

    func finish(_ text: String) {
        continuation?.resume(returning: .init(text: text, totalUnits: 1, textLayerUnits: 1))
        continuation = nil
    }
}
