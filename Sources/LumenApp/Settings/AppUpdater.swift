import AppKit
import SwiftUI
import LumenKit

/// Only settings/the update window observe this object, never the reader workspace.
@MainActor
final class AppUpdater: ObservableObject {
    static let shared = AppUpdater()
    @Published private(set) var phase: Phase = .idle
    @Published var automatic: Bool {
        didSet { defaults.set(automatic, forKey: "automaticUpdateChecks") }
    }
    enum Phase: Equatable {
        case idle, checking, current, noRelease, preparing, restarting
        case available(UpdateInfo)
        case failed(String)
    }
    private let defaults: UserDefaults
    private var operation: Task<Void, Never>?
    private var startupTask: Task<Void, Never>?
    private var window: NSWindow?
    private var worker: Process?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.automatic = defaults.object(forKey: "automaticUpdateChecks") as? Bool ?? true
    }

    var busy: Bool { [.checking, .preparing, .restarting].contains(phase) }

    func scheduleBackgroundCheck() {
        guard startupTask == nil, !LaunchOptions.isAuditRun,
              ProcessInfo.processInfo.environment["LUMEN_TEST_DATA"] == nil else { return }
        consumePreviousResult()
        startupTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(15))
            while !Task.isCancelled {
                guard let self else { return }
                let last = self.defaults.object(forKey: "lastUpdateCheck") as? Date ?? .distantPast
                if self.automatic && Date().timeIntervalSince(last) >= 86_400 { self.check(automatic: true) }
                try? await Task.sleep(for: .seconds(21_600))
            }
        }
    }

    func showAndCheck() {
        showWindow()
        check()
    }

    func check(automatic: Bool = false) {
        guard !busy else { return }
        guard let current = AppVersionInfo.semver else { phase = .failed("无法读取应用版本"); return }
        phase = .checking
        operation = Task { [weak self] in
            let outcome = await UpdateChecker.check(currentVersion: current)
            guard !Task.isCancelled, let self else { return }
            self.defaults.set(Date(), forKey: "lastUpdateCheck")
            switch outcome {
            case .upToDate: self.phase = .current
            case .noRelease: self.phase = .noRelease
            case .failed(let reason): self.phase = .failed(reason)
            case .updateAvailable(let info):
                self.phase = .available(info)
                if automatic { self.showWindow() }
            }
            self.operation = nil
        }
    }

    func cancel() {
        guard phase == .preparing else { return }
        operation?.cancel()
    }

    func install(_ info: UpdateInfo) {
        guard !busy else { return }
        let otherInstances = NSRunningApplication.runningApplications(withBundleIdentifier: AppUpdatePackage.bundleIdentifier)
            .filter { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier && $0.bundleURL == Bundle.main.bundleURL }
        guard otherInstances.isEmpty else { phase = .failed("请先关闭其他 Lumen 实例，再进行更新"); return }
        phase = .preparing
        let target = Bundle.main.bundleURL
        operation = Task { [weak self] in
            let preparation = Task.detached(priority: .utility) { try await AppUpdatePackage.prepare(info: info, target: target) }
            do {
                var (job, workspace) = try await withTaskCancellationHandler {
                    try await preparation.value
                } onCancel: { preparation.cancel() }
                guard let self else { try? FileManager.default.removeItem(at: workspace); return }
                do {
                    try Task.checkCancellation()
                    let windows = WindowManager.shared
                    let activePath = windows.activeWorkspace?.document?.url.path
                    var paths = Array(Set(windows.workspaces.flatMap { $0.sessions.map { $0.document.url.path } })).sorted()
                    if let activePath { paths.removeAll { $0 == activePath }; paths.append(activePath) }
                    job.reopenPaths = paths
                    try await self.startWorker(job, workspace: workspace)
                    self.phase = .restarting
                    NSApp.terminate(nil)
                } catch {
                    try? FileManager.default.removeItem(at: workspace)
                    throw error
                }
            } catch {
                self?.phase = Task.isCancelled ? .available(info) : .failed(error.localizedDescription)
            }
            self?.operation = nil
        }
    }

    private func startWorker(_ job: PreparedAppUpdate, workspace: URL) async throws {
        let executable = Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/LumenUpdateWorker")
        guard FileManager.default.isExecutableFile(atPath: executable.path) else {
            throw AppUpdateError.invalid("应用缺少更新组件，请重新安装完整版本")
        }
        let file = workspace.appendingPathComponent("job.json")
        try JSONEncoder().encode(job).write(to: file, options: .atomic)
        let process = Process()
        process.executableURL = executable
        process.arguments = [file.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        worker = process
        do {
            for _ in 0..<100 {
                try Task.checkCancellation()
                if FileManager.default.fileExists(atPath: workspace.appendingPathComponent("ready").path) {
                    defaults.set(workspace.path, forKey: "pendingUpdateWorkspace")
                    return
                }
                if !process.isRunning { break }
                try await Task.sleep(for: .milliseconds(100))
            }
            throw AppUpdateError.invalid("更新组件未就绪，应用未退出")
        } catch {
            if process.isRunning { process.terminate() }
            worker = nil
            throw error
        }
    }

    private func showWindow() {
        if let window { window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true); return }
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 540, height: 340),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Lumen 更新"
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: ScrollView { UpdateCheckSection().padding() })
        window.center()
        window.makeKeyAndOrderFront(nil)
        self.window = window
    }

    private func consumePreviousResult() {
        guard let path = defaults.string(forKey: "pendingUpdateWorkspace") else { return }
        let workspace = URL(fileURLWithPath: path)
        guard workspace.deletingLastPathComponent().standardizedFileURL == FileManager.default.temporaryDirectory.standardizedFileURL,
              workspace.lastPathComponent.hasPrefix("Lumen Update ") else {
            defaults.removeObject(forKey: "pendingUpdateWorkspace"); return
        }
        let result = workspace.appendingPathComponent("result.json")
        guard let data = try? Data(contentsOf: result), let info = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        defaults.removeObject(forKey: "pendingUpdateWorkspace")
        if info["success"] as? Bool == true { try? FileManager.default.removeItem(at: workspace) }
        else {
            phase = .failed(info["message"] as? String ?? "更新未完成，保留原应用")
            showWindow()
        }
    }
}
