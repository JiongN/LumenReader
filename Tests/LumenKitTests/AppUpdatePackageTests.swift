import Foundation
import CryptoKit
import Testing
@testable import LumenKit

@Suite("应用内更新校验与恢复", .serialized)
struct AppUpdatePackageTests {
    private func directory() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("Lumen Update Tests \(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: false)
        return dir
    }

    @Test func rateLimitFallbackOnlyAcceptsPinnedReleaseAndExactChecksum() {
        let good = URL(string: "https://github.com/JiongN/LumenReader/releases/tag/v1.1.2")!
        #expect(UpdateChecker.releaseTag(page: good, repository: "JiongN/LumenReader") == "v1.1.2")
        for url in ["https://github.com/other/LumenReader/releases/tag/v1.1.2",
                    "https://github.com/JiongN/LumenReader/releases/tag/v1.2.0-rc1",
                    "http://github.com/JiongN/LumenReader/releases/tag/v1.1.2",
                    "https://github.com/JiongN/LumenReader/releases/tag/v1.1.2?x=1"] {
            #expect(UpdateChecker.releaseTag(page: URL(string: url)!, repository: "JiongN/LumenReader") == nil)
        }
        let name = "Lumen-v1.1.2-macOS.zip", hash = String(repeating: "a", count: 64)
        #expect(UpdateChecker.checksum(text: "\(hash)  \(name)\n", name: name) == "sha256:" + hash)
        #expect(UpdateChecker.checksum(text: "\(hash)  other.zip", name: name) == nil)
        #expect(UpdateChecker.checksum(text: "bad  \(name)", name: name) == nil)
        #expect(UpdateChecker.checksum(text: "\(hash)  \(name)\n\(hash)  \(name)", name: name) == nil)
    }

    @Test func publicReleaseFallbackFindsActualAssetWhenRequested() async throws {
        guard ProcessInfo.processInfo.environment["LUMEN_UPDATE_LIVE_CHECK"] == "1" else { return }
        let outcome = await UpdateChecker.publicRelease(repository: UpdateChecker.defaultRepository,
                                                        current: AppVersion(major: 1, minor: 0, patch: 0), timeout: 15)
        guard case .updateAvailable(let info) = outcome else {
            Issue.record("正式发布页后备检查：\(outcome)"); return
        }
        #expect(info.installAsset != nil)
    }

    @Test func onlyExpectedRepositoryArchiveWithDigestCanInstall() throws {
        let name = "Lumen-v2.0.0-macOS.zip"
        let url = "https://github.com/JiongN/LumenReader/releases/download/v2.0.0/\(name)"
        let hash = "sha256:" + String(repeating: "a", count: 64)
        func parse(url: String = url, digest: String? = hash, size: Int64 = 20) throws -> UpdateInfo {
            var asset: [String: Any] = ["name": name, "browser_download_url": url, "size": size]
            if let digest { asset["digest"] = digest }
            let data = try JSONSerialization.data(withJSONObject: ["tag_name": "v2.0.0", "html_url": "https://github.com/JiongN/LumenReader/releases/tag/v2.0.0",
                "draft": false, "prerelease": false, "assets": [["name": "other.dmg", "browser_download_url": "https://example.com/other.dmg"], asset]])
            guard case .updateAvailable(let info) = UpdateChecker.parse(data: data, current: AppVersion(major: 1, minor: 0, patch: 0)) else {
                throw AppUpdateError.invalid("测试发布信息未识别")
            }
            return info
        }
        #expect(try parse().installAsset?.digest == hash)
        #expect(try parse().downloadURL == url)
        for bad in [url.replacingOccurrences(of: "https:", with: "http:"),
                    url.replacingOccurrences(of: "github.com", with: "github.com.evil.example"),
                    url.replacingOccurrences(of: "JiongN", with: "someone"), url + "?redirect=1",
                    url.replacingOccurrences(of: "github.com", with: "github.com:8443"),
                    url.replacingOccurrences(of: "v2.0.0/", with: "v2.0.0/../")] {
            #expect(try parse(url: bad).installAsset == nil)
        }
        #expect(try parse(digest: nil).installAsset == nil)
        #expect(try parse(digest: "sha256:bad").installAsset == nil)
        #expect(try parse(size: 0).installAsset == nil)
        #expect(try parse(size: UpdateAsset.maximumBytes + 1).installAsset == nil)
    }

    @Test func corruptedOrTruncatedDownloadNeverPasses() throws {
        let dir = try directory(); defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("archive.zip"), bytes = Data("complete package".utf8)
        try bytes.write(to: file)
        let hash = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        let asset = UpdateAsset(url: URL(string: "https://github.com")!, size: Int64(bytes.count), digest: "sha256:" + hash)
        try asset.verify(file: file)
        try Data("complete packagX".utf8).write(to: file)
        #expect(throws: (any Error).self) { try asset.verify(file: file) }
        try Data("short".utf8).write(to: file)
        #expect(throws: (any Error).self) { try asset.verify(file: file) }
    }

    @Test func replacementFailureRollsBackAndValidationFailureDoesNotMoveOriginal() throws {
        let dir = try directory(); defer { try? FileManager.default.removeItem(at: dir) }
        let target = dir.appendingPathComponent("Lumen.app"), candidate = dir.appendingPathComponent("New.app")
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false)
        try FileManager.default.createDirectory(at: candidate, withIntermediateDirectories: false)
        try Data("old".utf8).write(to: target.appendingPathComponent("version"))
        try Data("new".utf8).write(to: candidate.appendingPathComponent("version"))
        #expect(throws: (any Error).self) {
            _ = try AppUpdatePackage.commit(candidate: candidate, target: target, validate: { _ in throw CocoaError(.fileReadCorruptFile) })
        }
        #expect(try Data(contentsOf: target.appendingPathComponent("version")) == Data("old".utf8))
        #expect(throws: (any Error).self) {
            _ = try AppUpdatePackage.commit(candidate: candidate, target: target, validate: { _ in }, move: { from, to in
                if from.lastPathComponent.hasPrefix(".Lumen Incoming") { throw CocoaError(.fileWriteNoPermission) }
                try FileManager.default.moveItem(at: from, to: to)
            })
        }
        #expect(try Data(contentsOf: target.appendingPathComponent("version")) == Data("old".utf8))
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path).sorted() == ["Lumen.app", "New.app"])
        let backup = try AppUpdatePackage.commit(candidate: candidate, target: target, validate: { _ in })
        #expect(try Data(contentsOf: backup.appendingPathComponent("version")) == Data("old".utf8))
        #expect(try Data(contentsOf: target.appendingPathComponent("version")) == Data("new".utf8))
    }

    @Test func validatesActualSignedLocalBundleWhenProvided() throws {
        guard let path = ProcessInfo.processInfo.environment["LUMEN_UPDATE_TEST_APP"] else { return }
        let app = URL(fileURLWithPath: path)
        let version = try #require(Bundle(url: app)?.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String)
        let certificate = try AppUpdatePackage.signingCertificate(app)
        #expect(certificate.count == 64)
        try AppUpdatePackage.validateTarget(app)
        try AppUpdatePackage.validateCandidate(app, version: version, certificate: certificate)
        #expect(throws: (any Error).self) { try AppUpdatePackage.validateCandidate(app, version: "2.0.0", certificate: certificate) }
        #expect(throws: (any Error).self) { try AppUpdatePackage.validateCandidate(app, version: version, certificate: "other") }
    }

    @Test func workerWaitsForParentThenReplacesAnIsolatedSignedFixture() throws {
        guard let workerPath = ProcessInfo.processInfo.environment["LUMEN_UPDATE_TEST_WORKER"] else { return }
        let dir = try directory(); defer { try? FileManager.default.removeItem(at: dir) }
        let target = try signedFixture(in: dir, name: "Lumen.app", version: "1.0.0", build: "1")
        let candidate = try signedFixture(in: dir, name: "Candidate.app", version: "2.0.0", build: "2")
        let parent = Process()
        parent.executableURL = URL(fileURLWithPath: "/bin/sleep")
        parent.arguments = ["3"]
        try parent.run()
        defer { if parent.isRunning { parent.terminate() }; parent.waitUntilExit() }
        let job = PreparedAppUpdate(candidatePath: candidate.path, targetPath: target.path, version: "2.0.0",
                                    originalBuild: "1", certificate: try AppUpdatePackage.signingCertificate(target), parentPID: parent.processIdentifier)
        let file = dir.appendingPathComponent("job.json")
        try JSONEncoder().encode(job).write(to: file)
        let worker = Process()
        worker.executableURL = URL(fileURLWithPath: workerPath)
        worker.arguments = [file.path]
        worker.environment = ProcessInfo.processInfo.environment.merging(["LUMEN_UPDATE_NO_RELAUNCH": "1"]) { _, new in new }
        worker.standardError = FileHandle.nullDevice
        try worker.run()
        defer { if worker.isRunning { worker.terminate() }; worker.waitUntilExit() }
        let ready = dir.appendingPathComponent("ready")
        let deadline = Date().addingTimeInterval(15)
        while !FileManager.default.fileExists(atPath: ready.path), worker.isRunning, Date() < deadline { Thread.sleep(forTimeInterval: 0.03) }
        let diagnostic = (try? String(contentsOf: dir.appendingPathComponent("result.json"), encoding: .utf8)) ?? "no result"
        try #require(FileManager.default.fileExists(atPath: ready.path), "worker: \(diagnostic)")
        #expect(try plistVersion(target) == "1.0.0", "旧进程退出前禁止替换")
        parent.waitUntilExit()
        while worker.isRunning, Date() < deadline { Thread.sleep(forTimeInterval: 0.03) }
        try #require(!worker.isRunning)
        #expect(worker.terminationStatus == 0)
        #expect(try plistVersion(target) == "2.0.0")
        let backups = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil).filter { $0.lastPathComponent.hasPrefix(".Lumen Previous") }
        #expect(backups.count == 1)
        if let backup = backups.first { #expect(try plistVersion(backup) == "1.0.0") }
        let result = try JSONSerialization.jsonObject(with: Data(contentsOf: dir.appendingPathComponent("result.json"))) as? [String: Any]
        #expect(result?["success"] as? Bool == true)
    }

    @Test func downloadsAndPreparesActualGitHubReleaseWhenRequested() async throws {
        guard let release = ProcessInfo.processInfo.environment["LUMEN_UPDATE_LIVE_RELEASE"] else { return }
        let dir = try directory(); defer { try? FileManager.default.removeItem(at: dir) }
        let target = try signedFixture(in: dir, name: "Lumen.app", version: "1.0.0", build: "1")
        let data = try Data(contentsOf: URL(fileURLWithPath: release))
        guard case .updateAvailable(let info) = UpdateChecker.parse(data: data, current: AppVersion(major: 1, minor: 0, patch: 0)) else {
            throw AppUpdateError.invalid("没有可验证的正式版")
        }
        let (job, workspace) = try await AppUpdatePackage.prepare(info: info, target: target)
        defer { try? FileManager.default.removeItem(at: workspace) }
        #expect(job.version == info.version.display)
        #expect(FileManager.default.fileExists(atPath: job.candidatePath))
        #expect(try plistVersion(target) == "1.0.0", "真实下载仅验收准备，不安装到用户应用")
    }

    private func signedFixture(in folder: URL, name: String, version: String, build: String) throws -> URL {
        let app = folder.appendingPathComponent(name), contents = app.appendingPathComponent("Contents")
        let macOS = contents.appendingPathComponent("MacOS")
        try FileManager.default.createDirectory(at: macOS, withIntermediateDirectories: true)
        // System tools may be arm64e-only; use an actual arm64 build, as shipped.
        let environment = ProcessInfo.processInfo.environment
        let payload = try #require(environment["LUMEN_UPDATE_TEST_WORKER"]
            ?? environment["LUMEN_UPDATE_TEST_APP"].map { $0 + "/Contents/MacOS/Lumen" })
        try FileManager.default.copyItem(at: URL(fileURLWithPath: payload), to: macOS.appendingPathComponent("Lumen"))
        let data = try PropertyListSerialization.data(fromPropertyList: ["CFBundleIdentifier": "com.jn.lumen",
            "CFBundleExecutable": "Lumen", "CFBundleShortVersionString": version, "CFBundleVersion": build,
            "LSMinimumSystemVersion": "15.0", "CFBundlePackageType": "APPL"], format: .xml, options: 0)
        try data.write(to: contents.appendingPathComponent("Info.plist"))
        let sign = Process()
        sign.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        sign.arguments = ["--force", "--sign", "Lumen Dev", "--timestamp=none", app.path]
        sign.standardError = FileHandle.nullDevice
        try sign.run(); sign.waitUntilExit()
        try #require(sign.terminationStatus == 0)
        return app
    }

    private func plistVersion(_ app: URL) throws -> String? {
        let data = try Data(contentsOf: app.appendingPathComponent("Contents/Info.plist"))
        return (try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])?["CFBundleShortVersionString"] as? String
    }
}
