import Foundation
import Testing
@testable import LumenKit

@Suite("EPUB 解包进程退出", .serialized)
struct EPUBExtractionProcessTests {
    @Test func normalProcessAndFailure() throws {
        try EPUBExtractionProcess.run(executable: URL(fileURLWithPath: "/usr/bin/true"), arguments: [])
        #expect(throws: EPUBError.self) {
            try EPUBExtractionProcess.run(executable: URL(fileURLWithPath: "/usr/bin/false"), arguments: [])
        }
    }

    @Test func timeoutStopsProcess() async {
        let start = ContinuousClock.now
        let task = Task.detached {
            try EPUBExtractionProcess.run(executable: URL(fileURLWithPath: "/bin/sleep"), arguments: ["30"], timeout: 0.1)
        }
        do { try await task.value; Issue.record("Expected timeout") }
        catch { #expect(error is EPUBError) }
        #expect(start.duration(to: .now) < .seconds(3))
    }

    @Test func cancellationStopsProcess() async throws {
        let start = ContinuousClock.now
        let task = Task.detached {
            try EPUBExtractionProcess.run(executable: URL(fileURLWithPath: "/bin/sleep"), arguments: ["30"])
        }
        try await Task.sleep(for: .milliseconds(100))
        task.cancel()
        do { try await task.value; Issue.record("Expected cancellation") }
        catch { #expect(error is CancellationError) }
        #expect(start.duration(to: .now) < .seconds(3))
    }
}
