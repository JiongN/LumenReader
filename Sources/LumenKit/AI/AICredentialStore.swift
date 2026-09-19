import Foundation
import CryptoKit
import Darwin

/// Per-user local storage, intentionally separate from shareable settings.json.
/// Permissions restrict other OS users; this is not encryption at rest.
public final class CredentialFileStore: @unchecked Sendable {
    private let directory: URL
    private let lock = NSLock()
    public init(directory: URL) { self.directory = directory }
    private func file(_ account: String) -> URL {
        let name = SHA256.hash(data: Data(account.utf8)).map { String(format: "%02x", $0) }.joined()
        return directory.appendingPathComponent(name + ".key")
    }
    public func read(account: String) -> String? {
        guard !account.isEmpty else { return nil }
        lock.lock(); defer { lock.unlock() }
        guard let data = try? Data(contentsOf: file(account)), let value = String(data: data, encoding: .utf8), !value.isEmpty else { return nil }
        return value
    }
    @discardableResult public func save(_ value: String, account: String) -> Bool {
        guard !account.isEmpty else { return false }
        lock.lock(); defer { lock.unlock() }
        let destination = file(account)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
            if value.isEmpty {
                if FileManager.default.fileExists(atPath: destination.path) { try FileManager.default.removeItem(at: destination) }
                return true
            }
            let temp = directory.appendingPathComponent(UUID().uuidString + ".tmp")
            let descriptor = Darwin.open(temp.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
            guard descriptor >= 0 else { return false }
            let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
            defer { try? handle.close(); try? FileManager.default.removeItem(at: temp) }
            try handle.write(contentsOf: Data(value.utf8))
            try handle.synchronize()
            return Darwin.rename(temp.path, destination.path) == 0
        } catch { return false }
    }
}

public enum AICredentialStore {
    private static let store = CredentialFileStore(directory: AppPaths.supportRoot.appendingPathComponent("credentials", isDirectory: true))
    public static func read(account: String) -> String? { store.read(account: account) }
    public static func hasKey(account: String) -> Bool { read(account: account) != nil }
    @discardableResult public static func save(_ value: String, account: String) -> Bool { store.save(value, account: account) }
    public static func delete(account: String) { _ = store.save("", account: account) }
    public static func maskedKey(account: String) -> String? { read(account: account).map { "••••••••" + $0.suffix(4) } }
}
