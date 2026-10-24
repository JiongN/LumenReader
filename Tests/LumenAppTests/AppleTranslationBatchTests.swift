import Foundation
import Testing
import Translation
@testable import LumenApp

@Suite("Apple translation failure isolation")
@MainActor
struct AppleTranslationBatchTests {
    private let requests = ["a", "b", "c"].map {
        TranslationSession.Request(sourceText: $0, clientIdentifier: $0)
    }

    private func response(_ id: String?, _ text: String) -> TranslationSession.Response {
        .init(sourceLanguage: .init(identifier: "en"), targetLanguage: .init(identifier: "zh-Hans"),
              sourceText: "source", targetText: text, clientIdentifier: id)
    }

    @Test func rejectedBatchRetriesEachItemAndKeepsSuccessfulNeighbours() async throws {
        var calls: [String] = []
        let results = try await AppleTranslationBatch.run(requests, batch: { _ in
            throw TranslationError.internalError
        }, single: { text in
            calls.append(text)
            if text == "b" { throw TranslationError.nothingToTranslate }
            return "translated-\(text)"
        })
        #expect(calls == ["a", "b", "c"])
        #expect(try results["a"]?.get() == "translated-a")
        #expect(try results["c"]?.get() == "translated-c")
        if case .failure = results["b"] {} else { Issue.record("Rejected item was accepted") }
    }

    @Test func missingEmptyAndUnidentifiedResponsesCannotProducePartialSuccess() async throws {
        var calls: [String] = []
        let results = try await AppleTranslationBatch.run(requests, batch: { _ in
            [response("a", "valid"), response("b", " \n"), response(nil, "unknown"), response("other", "foreign")]
        }, single: { text in calls.append(text); return text == "b" ? "" : "recovered" })
        #expect(calls == ["b", "c"])
        #expect(try results["a"]?.get() == "valid")
        #expect(try results["c"]?.get() == "recovered")
        #expect(results["other"] == nil)
        if case .failure = results["b"] {} else { Issue.record("Empty chunk was accepted") }
    }

    @Test func unsupportedLanguagesDoNotTriggerPerItemRetryStorm() async throws {
        var calls = 0
        let results = try await AppleTranslationBatch.run(requests, batch: { _ in
            throw TranslationError.unsupportedLanguagePairing
        }, single: { _ in calls += 1; return "unexpected" })
        #expect(calls == 0)
        #expect(results.count == 3)
        #expect(PDFTranslationController.describe(TranslationError.unableToIdentifyLanguage).contains("语言"))
        #expect(PDFTranslationController.describe(TranslationError.internalError).contains("Apple"))
    }

    @Test func cancellationCannotReturnResultsOrStartFallback() async {
        let pending = Task {
            try await AppleTranslationBatch.run(requests, batch: { _ in
                try await Task.sleep(for: .seconds(10))
                return []
            }, single: { _ in Issue.record("Cancelled fallback ran"); return "unexpected" })
        }
        pending.cancel()
        do { _ = try await pending.value; Issue.record("Cancellation was ignored") }
        catch { #expect(error is CancellationError) }
    }

    @Test func fallbackServiceFailureStopsRemainingRequests() async throws {
        var calls: [String] = []
        let results = try await AppleTranslationBatch.run(requests, batch: { _ in [] }, single: { text in
            calls.append(text)
            throw URLError(.notConnectedToInternet)
        })
        #expect(calls == ["a"])
        #expect(results.count == 3)
    }
}
