import Foundation
import Testing
import LumenKit
@testable import LumenApp

@MainActor
struct AppleTranslationTaskTests {
    @Test func onlyInstalledLanguagesCanStartASession() {
        #expect(AppleTranslationFailure.forStatus(.installed) == nil)
        #expect(AppleTranslationFailure.forStatus(.supported) == .languageNotInstalled)
        #expect(AppleTranslationFailure.forStatus(.unsupported) == .unsupported)
    }

    @Test func watchdogTimesOutWithoutWaitingForSystemWork() async throws {
        let clock = ContinuousClock()
        let start = clock.now
        let request = AppleTranslationRequest(source: "en", target: "zh-Hans", inactivityLimit: .milliseconds(30))
        try await request.waitForTimeout()
        #expect(start.duration(to: clock.now) >= .milliseconds(30))
    }

    @Test func stoppingAndRetryingPDFRejectsFailureFromOldSession() async throws {
        let controller = PDFTranslationController()
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("apple-selection-\(UUID()).pdf").path
        let folder = AppPaths.documentDirectory(forPath: path)
        defer { try? FileManager.default.removeItem(at: folder) }
        let paragraph = PDFParagraph(pageIndex: 0, text: "This example shows how a system translates a complete sentence.",
                                     bounds: .zero, lineCount: 1, firstLineOrdinal: 0, isShort: false)
        let engine = AppleSystemTranslation.engineID
        await controller.prepare(documentPath: path, target: "zh-Hans", engineID: engine, glossary: [], selection: paragraph)
        controller.startAll(engineID: engine, target: "zh-Hans")
        let first = try #require(controller.appleRequest)
        #expect(controller.phase.isBusy)

        controller.stop()
        #expect(controller.appleRequest == nil)
        #expect(controller.phase == .cancelled)
        controller.startAll(engineID: engine, target: "zh-Hans")
        let second = try #require(controller.appleRequest)
        #expect(first.id != second.id)
        controller.failApple(.timedOut, request: first)
        #expect(controller.appleRequest === second)
        #expect(controller.phase.isBusy)

        controller.failApple(.languageNotInstalled, request: second)
        #expect(controller.appleRequest == nil)
        #expect(controller.phase == .failed(AppleTranslationFailure.languageNotInstalled.localizedDescription))
    }

    @Test func removingSessionCancelsItsWatchdog() async {
        let request = AppleTranslationRequest(source: "en", target: "zh-Hans")
        let watchdog = Task { try await request.waitForTimeout() }
        watchdog.cancel()
        await #expect(throws: CancellationError.self) { try await watchdog.value }
    }
}
