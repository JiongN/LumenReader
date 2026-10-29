import Foundation
import Darwin
import LumenKit

// Wait for normal application termination, including PDF and conversation saves.
// This worker has no UI, elevated privileges, network requests or shell commands.
guard CommandLine.arguments.count == 2 else { exit(64) }
let file = URL(fileURLWithPath: CommandLine.arguments[1])
let workspace = file.deletingLastPathComponent()
var target: URL?
var parentExited = false
func report(_ reason: String, success: Bool) {
    if let data = try? JSONSerialization.data(withJSONObject: ["success": success, "message": reason]) {
        try? data.write(to: workspace.appendingPathComponent("result.json"), options: .atomic)
    }
}
@discardableResult
func reopen(_ app: URL, documents: [String] = []) -> Bool {
    if ProcessInfo.processInfo.environment["LUMEN_UPDATE_NO_RELAUNCH"] == "1" { return true }
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
    var arguments = ["-n", "-a", app.path]
    // Diagnostic updates must restart into their own data directory, too.
    if let root = ProcessInfo.processInfo.environment["LUMEN_TEST_DATA"], !root.isEmpty {
        arguments += ["--env", "LUMEN_TEST_DATA=" + root]
    }
    process.arguments = arguments + documents.filter { FileManager.default.fileExists(atPath: $0) }
    do { try process.run(); process.waitUntilExit(); return process.terminationStatus == 0 }
    catch { return false }
}
do {
    let values = try file.resourceValues(forKeys: [.fileSizeKey, .isSymbolicLinkKey])
    guard values.isSymbolicLink != true, (values.fileSize ?? Int.max) <= 32_768 else { exit(65) }
    let job = try JSONDecoder().decode(PreparedAppUpdate.self, from: Data(contentsOf: file))
    guard job.parentPID > 1, job.parentPID != getpid() else { exit(65) }
    let app = URL(fileURLWithPath: job.targetPath)
    target = app
    try AppUpdatePackage.validateTarget(app)
    try AppUpdatePackage.validateCandidate(URL(fileURLWithPath: job.candidatePath), version: job.version, certificate: job.certificate)
    try Data("ready".utf8).write(to: workspace.appendingPathComponent("ready"), options: .atomic)
    let deadline = Date().addingTimeInterval(300)
    while kill(job.parentPID, 0) == 0 || errno == EPERM {
        guard Date() < deadline else {
            report("应用未退出，更新已取消；原应用未替换", success: false)
            exit(75)
        }
        Thread.sleep(forTimeInterval: 0.15)
    }
    parentExited = true
    _ = try AppUpdatePackage.install(job)
    report("更新完成", success: true)
    if !reopen(app, documents: job.reopenPaths) { report("更新已安装，请手动重新打开 Lumen", success: false) }
    exit(0)
} catch {
    report(error.localizedDescription, success: false)
    if parentExited, let target, FileManager.default.fileExists(atPath: target.path) { reopen(target) }
    exit(74)
}
