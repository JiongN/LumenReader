import Foundation

/// Enforce limits before collecting an entire newline-less server frame.
struct BoundedResponseLines<Bytes: AsyncSequence>: AsyncSequence where Bytes.Element == UInt8 {
    typealias Element = String
    let bytes: Bytes
    let maxLineBytes: Int
    let maxBytes: Int

    struct AsyncIterator: AsyncIteratorProtocol {
        var iterator: Bytes.AsyncIterator
        let maxLineBytes: Int
        var remaining: Int
        mutating func next() async throws -> String? {
            var line: [UInt8] = []
            while let byte = try await iterator.next() {
                remaining -= 1
                guard remaining >= 0 else { throw AIError.responseTooLarge }
                if byte == 10 { return String(decoding: line, as: UTF8.self) }
                line.append(byte)
                guard line.count <= maxLineBytes else { throw AIError.responseTooLarge }
            }
            return line.isEmpty ? nil : String(decoding: line, as: UTF8.self)
        }
    }

    func makeAsyncIterator() -> AsyncIterator {
        .init(iterator: bytes.makeAsyncIterator(), maxLineBytes: maxLineBytes, remaining: maxBytes)
    }
}
