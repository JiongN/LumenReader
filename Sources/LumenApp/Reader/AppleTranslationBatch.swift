import Foundation
@preconcurrency import Translation

/// A rejected batch must not discard unrelated paragraphs. Retry only unresolved
/// items once, and never accept a missing or empty response as a completed chunk.
@MainActor
enum AppleTranslationBatch {
    enum ResponseError: Error, LocalizedError {
        case incomplete
        case empty
        var errorDescription: String? {
            switch self {
            case .incomplete: return "Apple 系统翻译未返回该文本块，请重试。"
            case .empty: return "Apple 系统翻译返回了空译文，请重试。"
            }
        }
    }

    static func run(
        _ requests: [TranslationSession.Request],
        batch: @MainActor ([TranslationSession.Request]) async throws -> [TranslationSession.Response],
        single: @MainActor (String) async throws -> String
    ) async throws -> [String: Result<String, Error>] {
        try Task.checkCancellation()
        var results: [String: Result<String, Error>] = [:]
        var batchError: Error?
        do {
            let responses = try await batch(requests)
            try Task.checkCancellation()
            let expected = Set(requests.compactMap(\.clientIdentifier))
            for response in responses {
                guard let id = response.clientIdentifier, expected.contains(id) else { continue }
                let text = response.targetText.trimmingCharacters(in: .whitespacesAndNewlines)
                if !text.isEmpty { results[id] = .success(text) }
            }
        } catch {
            try Task.checkCancellation()
            batchError = error
        }

        for request in requests {
            try Task.checkCancellation()
            guard let id = request.clientIdentifier, results[id] == nil else { continue }
            if let error = batchError, stopsQueue(error) {
                results[id] = .failure(error)
                continue
            }
            do {
                let text = try await single(request.sourceText).trimmingCharacters(in: .whitespacesAndNewlines)
                try Task.checkCancellation()
                results[id] = text.isEmpty ? .failure(ResponseError.empty) : .success(text)
            } catch {
                try Task.checkCancellation()
                results[id] = .failure(error)
                if stopsQueue(error) { batchError = error }
            }
        }
        return results
    }

    static func stopsQueue(_ error: Error) -> Bool {
        switch error {
        case TranslationError.unsupportedSourceLanguage,
             TranslationError.unsupportedTargetLanguage,
             TranslationError.unsupportedLanguagePairing:
            return true
        default:
            let ns = error as NSError
            return ns.domain == NSURLErrorDomain || error is CancellationError
        }
    }
}
