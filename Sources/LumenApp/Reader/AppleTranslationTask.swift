import SwiftUI
@preconcurrency import Translation

/// Each request gets its own SwiftUI host. Removing it invalidates the system
/// session without changing the identity of the PDF or EPUB reader.
@MainActor
final class AppleTranslationRequest: Identifiable {
    let id = UUID()
    let source: Locale.Language
    let target: Locale.Language
    let targetID: String
    private var deadline = ContinuousClock.now
    private let inactivityLimit: Duration

    init(source: String, target: String, inactivityLimit: Duration = .seconds(30)) {
        self.source = Locale.Language(identifier: source)
        self.target = Locale.Language(identifier: target)
        self.targetID = target
        self.inactivityLimit = inactivityLimit
        recordProgress()
    }

    func recordProgress() {
        deadline = .now.advanced(by: inactivityLimit)
    }

    func waitForTimeout() async throws {
        let clock = ContinuousClock()
        // The watchdog is independent of the system call, which may ignore cancellation.
        while clock.now < deadline {
            try await clock.sleep(until: deadline)
        }
        try Task.checkCancellation()
    }
}

enum AppleTranslationFailure: LocalizedError {
    case languageNotInstalled
    case unsupported
    case timedOut

    static func forStatus(_ status: LanguageAvailability.Status) -> Self? {
        switch status {
        case .installed: nil
        case .supported: .languageNotInstalled
        case .unsupported: .unsupported
        @unknown default: .unsupported
        }
    }

    var errorDescription: String? {
        switch self {
        case .languageNotInstalled:
            return "这组 Apple 翻译语言尚未安装。可改用其他翻译引擎，或在 macOS 中手动安装语言。"
        case .unsupported:
            return "Apple 不支持这组翻译语言，请换用其他翻译引擎。"
        case .timedOut:
            return "Apple 系统翻译长时间无响应，已停止。可重试或更换翻译引擎。"
        }
    }
}

struct AppleTranslationTask: View {
    let request: AppleTranslationRequest
    let translate: @MainActor (TranslationSession) async -> Void
    let fail: @MainActor (AppleTranslationFailure) -> Void
    @State private var configuration: TranslationSession.Configuration?

    @ViewBuilder
    static func forPDFController(_ controller: PDFTranslationController) -> some View {
        if let request = controller.appleRequest {
            AppleTranslationTask(request: request) { session in
                await controller.runApple(session: session, request: request)
            } fail: { error in
                controller.failApple(error, request: request)
            }
            .id(request.id)
        }
    }

    var body: some View {
        Color.clear
            .allowsHitTesting(false)
            .accessibilityHidden(true)
            .task {
                let status = await LanguageAvailability().status(from: request.source, to: request.target)
                guard !Task.isCancelled else { return }
                if let failure = AppleTranslationFailure.forStatus(status) {
                    fail(failure)
                    return
                }
                request.recordProgress()
                configuration = .init(source: request.source, target: request.target)
            }
            .translationTask(configuration) { session in
                await translate(session)
            }
            .task {
                do {
                    try await request.waitForTimeout()
                    fail(.timedOut)
                } catch {
                    // Removing this host cancels its watchdog.
                }
            }
    }
}
