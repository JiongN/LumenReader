import Foundation
import Synchronization

public struct AIStreamLimits: Sendable {
    public var idleTimeout: TimeInterval = 90
    public var totalTimeout: TimeInterval = 300
    public var finishGrace: TimeInterval = 2
    public var maxOutputBytes = 128_000
    public var maxReasoningBytes = 64_000
    public var maxWireBytes = 1_000_000

    public init() {}
}

final class AIStreamWatch: Sendable {
    struct State {
        let started = ContinuousClock.now
        var lastActivity = ContinuousClock.now
        var finishedAt: ContinuousClock.Instant?
        var closed = false
    }
    let state = Mutex(State())
    func activity() { state.withLock { $0.lastActivity = .now } }
    func finished() { state.withLock { if $0.finishedAt == nil { $0.finishedAt = .now; $0.lastActivity = .now } } }
    func close() { state.withLock { $0.closed = true } }

    func outcome(limits: AIStreamLimits) -> (closed: Bool, complete: Bool, error: AIError?) {
        state.withLock { value in
            let now = ContinuousClock.now
            if value.closed { return (true, false, nil) }
            if let finished = value.finishedAt, finished.duration(to: now) >= .seconds(limits.finishGrace) {
                return (false, true, nil)
            }
            if value.started.duration(to: now) >= .seconds(limits.totalTimeout) {
                return (false, false, .streamTimeout("请求已达到总时限"))
            }
            if value.lastActivity.duration(to: now) >= .seconds(limits.idleTimeout) {
                return (false, false, .streamTimeout("模型长时间没有返回有效内容"))
            }
            return (false, false, nil)
        }
    }
}
