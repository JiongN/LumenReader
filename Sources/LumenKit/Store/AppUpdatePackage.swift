import Foundation
import Security
import CryptoKit

public struct PreparedAppUpdate: Codable, Sendable {
    public let candidatePath: String
    public let targetPath: String
    public let version: String
    public let originalBuild: String
    public let certificate: String
    public let parentPID: Int32
    public var reopenPaths: [String] = []
}

/// Work is called from a detached task or the update worker, never a reader callback.
public enum AppUpdatePackage {
    public static let bundleIdentifier = "com.jn.lumen"

    public static func prepare(info: UpdateInfo, target: URL) async throws -> (PreparedAppUpdate, URL) {
        guard let asset = info.installAsset,
              UpdateAsset.trustedURL(asset.url, tag: info.tagName, name: "Lumen-\(info.tagName)-macOS.zip") else {
            throw AppUpdateError.invalid("该版本缺少可校验的安装包，请查看发布页")
        }
        try validateTarget(target)
        let original = try metadata(target)
        guard let current = AppVersion(parsing: original.version), info.version > current else {
            throw AppUpdateError.invalid("该版本不高于当前版本，未替换应用")
        }
        let certificate = try signingCertificate(target)
        let workspace = FileManager.default.temporaryDirectory.appendingPathComponent("Lumen Update \(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: false,
                                               attributes: [.posixPermissions: 0o700])
        do {
            var request = URLRequest(url: asset.url)
            request.timeoutInterval = 120
            request.setValue("Lumen-Updater", forHTTPHeaderField: "User-Agent")
            let (download, response) = try await URLSession.shared.download(for: request)
            defer { try? FileManager.default.removeItem(at: download) }
            guard let http = response as? HTTPURLResponse, http.statusCode == 200,
                  let final = http.url, final.scheme == "https",
                  ["github.com", "release-assets.githubusercontent.com", "objects.githubusercontent.com"].contains(final.host ?? "") else {
                throw AppUpdateError.invalid("GitHub 下载失败或重定向不受信任")
            }
            try Task.checkCancellation()
            let archive = workspace.appendingPathComponent("update.zip")
            try FileManager.default.moveItem(at: download, to: archive)
            try asset.verify(file: archive)
            // Same bounded ZIP preflight as EPUB: no traversal, symlinks, special
            // files, encryption, duplicate paths or >512 MiB expanded content.
            do { try EPUBArchiveSafety.validate(archive) }
            catch { throw AppUpdateError.invalid("更新包结构异常，未解包") }
            let unpacked = workspace.appendingPathComponent("unpacked", isDirectory: true)
            try FileManager.default.createDirectory(at: unpacked, withIntermediateDirectories: false)
            try EPUBExtractionProcess.run(executable: URL(fileURLWithPath: "/usr/bin/ditto"),
                                           arguments: ["-x", "-k", archive.path, unpacked.path])
            let candidate = unpacked.appendingPathComponent("Lumen.app", isDirectory: true)
            try validateCandidate(candidate, version: info.version.display, certificate: certificate)
            let job = PreparedAppUpdate(candidatePath: candidate.path, targetPath: target.path,
                                        version: info.version.display, originalBuild: original.build,
                                        certificate: certificate, parentPID: ProcessInfo.processInfo.processIdentifier)
            return (job, workspace)
        } catch {
            try? FileManager.default.removeItem(at: workspace)
            throw error
        }
    }

    public static func validateTarget(_ target: URL) throws {
        let values = try target.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey])
        guard target.isFileURL, target.pathExtension == "app", target.path == target.standardizedFileURL.path,
              values.isSymbolicLink != true, values.isDirectory == true,
              !target.path.hasPrefix("/Volumes/"), !target.path.contains("/AppTranslocation/"),
              FileManager.default.isWritableFile(atPath: target.deletingLastPathComponent().path) else {
            throw AppUpdateError.invalid("当前应用位置不可更新，请先移入可写的「应用程序」目录")
        }
    }

    public static func validateCandidate(_ candidate: URL, version: String, certificate: String) throws {
        let info = try metadata(candidate)
        guard info.version == version, info.identifier == bundleIdentifier,
              info.executable == "Lumen", !certificate.isEmpty else {
            throw AppUpdateError.invalid("安装包的应用标识或版本不符")
        }
        guard let minimum = AppVersion(parsing: info.minimumOS) else { throw AppUpdateError.invalid("安装包的系统要求无效") }
        let os = ProcessInfo.processInfo.operatingSystemVersion
        guard AppVersion(major: os.majorVersion, minor: os.minorVersion, patch: os.patchVersion) >= minimum else {
            throw AppUpdateError.invalid("新版需要 macOS \(minimum.display) 或更高版本")
        }
        guard try signingCertificate(candidate) == certificate else {
            throw AppUpdateError.invalid("新版签名与当前应用不一致，未安装")
        }
        #if arch(arm64)
        let architecture = "arm64"
        #else
        let architecture = "x86_64"
        #endif
        do {
            try EPUBExtractionProcess.run(executable: URL(fileURLWithPath: "/usr/bin/lipo"),
                                           arguments: [candidate.appendingPathComponent("Contents/MacOS/Lumen").path, "-verify_arch", architecture], timeout: 10)
        } catch { throw AppUpdateError.invalid("新版安装包不支持这台 Mac 的处理器") }
    }

    public static func install(_ job: PreparedAppUpdate) throws -> URL {
        let target = URL(fileURLWithPath: job.targetPath), candidate = URL(fileURLWithPath: job.candidatePath)
        try validateTarget(target)
        let original = try metadata(target)
        guard original.build == job.originalBuild, original.identifier == bundleIdentifier,
              let current = AppVersion(parsing: original.version), let next = AppVersion(parsing: job.version), next > current,
              try signingCertificate(target) == job.certificate else {
            throw AppUpdateError.invalid("当前应用已变化，更新已取消，请重新检查")
        }
        return try commit(candidate: candidate, target: target) { url in
            try validateCandidate(url, version: job.version, certificate: job.certificate)
        }
    }

    /// Stage on the destination volume before the two short renames. Keep the
    /// previous app as a recoverable backup; rollback if replacement fails.
    static func commit(candidate: URL, target: URL, validate: (URL) throws -> Void,
                       move: (URL, URL) throws -> Void = { try FileManager.default.moveItem(at: $0, to: $1) }) throws -> URL {
        let parent = target.deletingLastPathComponent(), token = UUID().uuidString
        let incoming = parent.appendingPathComponent(".Lumen Incoming \(token).app")
        let backup = parent.appendingPathComponent(".Lumen Previous \(token).app")
        defer { try? FileManager.default.removeItem(at: incoming) }
        try FileManager.default.copyItem(at: candidate, to: incoming)
        try validate(incoming)
        try Task.checkCancellation()
        try move(target, backup)
        do { try move(incoming, target) }
        catch {
            do { try FileManager.default.moveItem(at: backup, to: target) }
            catch { throw AppUpdateError.invalid("安装与恢复失败，旧版仍保留在 \(backup.path)") }
            throw AppUpdateError.invalid("安装失败，已恢复原应用")
        }
        return backup
    }

    public static func signingCertificate(_ app: URL) throws -> String {
        var code: SecStaticCode?
        let flags = SecCSFlags(rawValue: kSecCSStrictValidate | kSecCSCheckAllArchitectures | kSecCSCheckNestedCode)
        guard SecStaticCodeCreateWithPath(app as CFURL, [], &code) == errSecSuccess, let code,
              SecStaticCodeCheckValidity(code, flags, nil) == errSecSuccess else {
            throw AppUpdateError.invalid("应用代码签名校验失败")
        }
        var dictionary: CFDictionary?
        guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &dictionary) == errSecSuccess,
              let info = dictionary as? [String: Any],
              let certificates = info[kSecCodeInfoCertificates as String] as? [SecCertificate],
              let first = certificates.first else {
            throw AppUpdateError.invalid("当前签名没有稳定证书，不能安全自动更新，请使用发布页安装")
        }
        return SHA256.hash(data: SecCertificateCopyData(first) as Data).map { String(format: "%02x", $0) }.joined()
    }

    private static func metadata(_ app: URL) throws -> (identifier: String, version: String, build: String, executable: String, minimumOS: String) {
        let data = try Data(contentsOf: app.appendingPathComponent("Contents/Info.plist"))
        guard let info = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let identifier = info["CFBundleIdentifier"] as? String,
              let version = info["CFBundleShortVersionString"] as? String,
              let build = info["CFBundleVersion"] as? String,
              let executable = info["CFBundleExecutable"] as? String else {
            throw AppUpdateError.invalid("安装包缺少应用信息")
        }
        return (identifier, version, build, executable, info["LSMinimumSystemVersion"] as? String ?? "15.0")
    }
}
