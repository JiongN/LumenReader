import Foundation

/// Initial note creation waits briefly for known metadata. An exhaustive scan
/// of a large library continues in the background and is reused by reconciliation.
@MainActor final class LiteratureLookupTasks {
    typealias Outcome = Result<LiteratureZoteroIdentity, any Error>
    private var tasks: [String: Task<Outcome, Never>] = [:]

    private final class FirstResult {
        private var continuation: CheckedContinuation<Outcome?, Never>?
        init(_ continuation: CheckedContinuation<Outcome?, Never>) { self.continuation = continuation }
        func finish(_ value: Outcome?) {
            guard let continuation else { return }
            self.continuation = nil
            continuation.resume(returning: value)
        }
    }

    func lookup(_ url: URL, initial: Bool,
                resolve: @escaping @Sendable (URL) async throws -> LiteratureZoteroIdentity) async throws -> LiteratureZoteroIdentity? {
        let key = url.standardizedFileURL.path
        let task: Task<Outcome, Never>
        if let existing = tasks[key] { task = existing }
        else {
            task = Task {
                do { return .success(try await resolve(url)) }
                catch { return .failure(error) }
            }
            tasks[key] = task
        }
        let result: Outcome?
        if initial {
            result = await withCheckedContinuation { continuation in
                let first = FirstResult(continuation)
                Task { first.finish(await task.value) }
                Task {
                    try? await Task.sleep(for: .milliseconds(750))
                    first.finish(nil)
                }
            }
        } else { result = await task.value }
        guard let result else { return nil }
        tasks.removeValue(forKey: key)
        return try result.get()
    }

    func cancel() {
        for task in tasks.values { task.cancel() }
        tasks.removeAll()
    }
}
