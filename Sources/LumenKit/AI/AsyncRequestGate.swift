import Foundation

public actor AsyncRequestGate {
    public static let cloud = AsyncRequestGate(limit: 2)
    private let limit: Int
    private var active = 0
    private var waiters: [(UUID, CheckedContinuation<Void, Error>)] = []
    public init(limit: Int) { self.limit = max(1, limit) }

    public func acquire() async throws {
        try Task.checkCancellation()
        if active < limit { active += 1; return }
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                waiters.append((id, continuation))
                if Task.isCancelled { cancel(id) }
            }
        } onCancel: { Task { await self.cancel(id) } }
    }
    private func cancel(_ id: UUID) {
        if let index = waiters.firstIndex(where: { $0.0 == id }) { waiters.remove(at: index).1.resume(throwing: CancellationError()) }
    }
    public func release() {
        if !waiters.isEmpty { waiters.removeFirst().1.resume() }
        else { active = max(0, active - 1) }
    }
}
