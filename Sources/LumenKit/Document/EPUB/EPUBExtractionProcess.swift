import Foundation
import Darwin

enum EPUBExtractionProcess {
    /// Poll off the main actor so cancellation also stops ditto, not just its Swift caller.
    static func run(executable: URL, arguments: [String], timeout: TimeInterval = 60) throws {
        try Task.checkCancellation()
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        let pipe = Pipe()
        process.standardError = pipe
        process.standardOutput = FileHandle.nullDevice
        defer {
            try? pipe.fileHandleForReading.close()
            try? pipe.fileHandleForWriting.close()
        }
        let descriptor = pipe.fileHandleForReading.fileDescriptor
        guard fcntl(descriptor, F_SETFL, O_NONBLOCK) != -1 else {
            throw EPUBError.extractionFailed("无法建立解包日志通道")
        }
        try process.run()
        let deadline = ContinuousClock.now.advanced(by: .seconds(timeout))
        var log = Data()
        var buffer = [UInt8](repeating: 0, count: 8192)
        func drain() {
            let count = Darwin.read(descriptor, &buffer, buffer.count)
            if count > 0, log.count < 32_768 {
                log.append(contentsOf: buffer.prefix(min(count, 32_768 - log.count)))
            }
        }
        do {
            while process.isRunning {
                try Task.checkCancellation()
                guard ContinuousClock.now < deadline else {
                    throw EPUBError.extractionFailed("解包超过时限，请检查文件是否损坏")
                }
                drain()
                Thread.sleep(forTimeInterval: 0.02)
            }
            process.waitUntilExit()
            drain()
            try Task.checkCancellation()
        } catch {
            if process.isRunning {
                process.terminate()
                let grace = ContinuousClock.now.advanced(by: .seconds(1))
                while process.isRunning && ContinuousClock.now < grace {
                    drain()
                    Thread.sleep(forTimeInterval: 0.02)
                }
                if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            }
            process.waitUntilExit()
            throw error
        }
        guard process.terminationStatus == 0 else {
            let detail = String(decoding: log, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            throw EPUBError.extractionFailed(detail.isEmpty ? "ditto 退出码 \(process.terminationStatus)" : detail)
        }
    }
}
