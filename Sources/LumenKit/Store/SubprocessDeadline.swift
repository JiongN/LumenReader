import Foundation
import Darwin

/// For helpers invoked off the main thread. A process that ignores SIGTERM
/// must not hold its caller (and any serial save queue) indefinitely.
package enum SubprocessDeadline {
    package enum Failure: Error {
        case timedOut
    }

    package static func wait(for process: Process, timeout: TimeInterval, drain: () -> Void = {}) throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(timeout))
        do {
            while process.isRunning {
                try Task.checkCancellation()
                guard ContinuousClock.now < deadline else { throw Failure.timedOut }
                drain()
                Thread.sleep(forTimeInterval: 0.02)
            }
            try Task.checkCancellation()
        } catch {
            if process.isRunning {
                process.terminate()
                waitBriefly(for: process, drain: drain)
                if process.isRunning {
                    kill(process.processIdentifier, SIGKILL)
                    waitBriefly(for: process, drain: drain)
                }
            }
            throw error
        }
    }

    private static func waitBriefly(for process: Process, drain: () -> Void) {
        let deadline = ContinuousClock.now.advanced(by: .seconds(1))
        while process.isRunning && ContinuousClock.now < deadline {
            drain()
            Thread.sleep(forTimeInterval: 0.02)
        }
    }
}
