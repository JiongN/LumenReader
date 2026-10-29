import Foundation
import CryptoKit

public struct UpdateAsset: Sendable, Equatable {
    public static let maximumBytes: Int64 = 128 * 1024 * 1024
    public let url: URL
    public let size: Int64
    public let digest: String

    public init(url: URL, size: Int64, digest: String) {
        self.url = url; self.size = size; self.digest = digest
    }

    public static func validDigest(_ value: String) -> Bool {
        value.hasPrefix("sha256:") && value.count == 71
            && value.dropFirst(7).utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }

    public static func trustedURL(_ url: URL, repository: String = UpdateChecker.defaultRepository,
                                  tag: String, name: String) -> Bool {
        url.scheme == "https" && url.host == "github.com" && url.user == nil && url.password == nil
            && url.port == nil && url.query == nil && url.fragment == nil
            && url.path == "/\(repository)/releases/download/\(tag)/\(name)"
    }

    /// Hash in bounded buffers; downloading a release never holds its archive in RAM.
    public func verify(file: URL) throws {
        guard Self.validDigest(digest), size > 0, size <= Self.maximumBytes,
              try file.resourceValues(forKeys: [.fileSizeKey]).fileSize == Int(size) else {
            throw AppUpdateError.invalid("更新包大小不符")
        }
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var hash = SHA256()
        while let data = try handle.read(upToCount: 256 * 1024), !data.isEmpty {
            try Task.checkCancellation()
            hash.update(data: data)
        }
        let actual = hash.finalize().map { String(format: "%02x", $0) }.joined()
        guard "sha256:" + actual == digest else { throw AppUpdateError.invalid("更新包校验失败，请重新下载") }
    }
}

public enum AppUpdateError: LocalizedError {
    case invalid(String)
    public var errorDescription: String? {
        switch self { case .invalid(let reason): return reason }
    }
}
