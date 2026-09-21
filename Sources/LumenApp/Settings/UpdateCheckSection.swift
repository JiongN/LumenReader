import SwiftUI
import AppKit
import LumenKit

// MARK: - 版本读取

/// 当前应用版本（来自 Info.plist 的 `CFBundleShortVersionString` + `CFBundleVersion`）。
///
/// 抽成独立枚举而不是在视图里直接读 `Bundle.main`：版本号读取要能被自检断言
/// （`--update-report`），而视图层的读取没法自动化验证；也避免「打包的版本 vs
/// 界面里手写的版本」分叉——AboutPane 以前是硬编码 `版本 1.0.0`，改一处忘一处。
enum AppVersionInfo {

    /// 界面展示用的版本串，如 `1.0.0 (build 1)`。
    static var display: String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "未知"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
        return "\(version)（构建 \(build)）"
    }

    /// 引擎层更新判断需要的可比较版本号。解析不出来返回 nil（不应发生，但别崩）。
    static var semver: AppVersion? {
        guard let raw = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String else {
            return nil
        }
        return AppVersion(parsing: raw)
    }
}

// MARK: - 更新检查视图

/// 设置 → 关于 里的「检查更新」区块。
///
/// 交互：点「检查更新」→ 请求 GitHub Releases `latest` → 按结果展示
/// 「有新版本 / 已是最新 / 仓库暂无发布 / 检查失败（断网等）」。
/// 有更新时给出「去下载」按钮（打开浏览器，跳到 Release 页或 ZIP 直链）。
struct UpdateCheckSection: View {

    /// 检查状态机。
    enum Phase: Equatable {
        case idle
        case checking
        case available(UpdateInfo)
        case upToDate
        case noRelease
        case failed(String)
    }

    @State private var phase: Phase = .idle

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.m) {
            HStack {
                Text("更新")
                    .font(DS.Typo.headline)
                Spacer()
                if phase != .checking {
                    Button("检查更新", action: check)
                        .disabled(phase == .checking)
                } else {
                    ProgressView()
                        .controlSize(.small)
                    Text("检查中…")
                        .font(DS.Typo.caption)
                        .foregroundStyle(DS.Palette.textSecondary)
                }
            }

            statusText

            // 有新版本时给出下载入口与说明
            if case .available(let info) = phase {
                HStack(spacing: DS.Space.s) {
                    Button {
                        open(info.downloadURL ?? info.htmlURL)
                    } label: {
                        Label(
                            info.downloadURL != nil ? "下载 \(info.tagName)" : "前往 Release 页",
                            systemImage: "arrow.down.circle"
                        )
                    }
                    .buttonStyle(.borderedProminent)

                    if !info.releaseNotes.isEmpty {
                        DisclosureGroup("更新说明") {
                            Text(info.releaseNotes)
                                .font(DS.Typo.callout)
                                .foregroundStyle(DS.Palette.textSecondary)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .font(DS.Typo.caption)
                    }
                }
            }

            Text("更新检查通过 GitHub Releases 进行，不收集任何数据。"
                 + "没有 Developer ID 公证，请从我们发布的下载页更新，勿信任来路不明的副本。")
                .font(DS.Typo.ui(size: 10))
                .foregroundStyle(DS.Palette.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(DS.Space.l)
        .background(
            RoundedRectangle(cornerRadius: DS.Radius.m, style: .continuous)
                .fill(DS.Palette.surfaceSunken)
        )
    }

    @ViewBuilder
    private var statusText: some View {
        switch phase {
        case .idle:
            Text("尚未检查。点击「检查更新」获取最新版本。")
                .font(DS.Typo.callout)
                .foregroundStyle(DS.Palette.textSecondary)
        case .checking:
            EmptyView()
        case .available(let info):
            Text("发现新版本 \(info.tagName)（当前 \(AppVersionInfo.display)）。")
                .font(DS.Typo.callout)
                .foregroundStyle(DS.Palette.success)
        case .upToDate:
            Text("已是最新版本（\(AppVersionInfo.display)）。")
                .font(DS.Typo.callout)
                .foregroundStyle(DS.Palette.success)
        case .noRelease:
            Text("仓库暂无发布版本。")
                .font(DS.Typo.callout)
                .foregroundStyle(DS.Palette.textSecondary)
        case .failed(let reason):
            Text("检查失败：\(reason)")
                .font(DS.Typo.callout)
                .foregroundStyle(DS.Palette.danger)
        }
    }

    @MainActor
    private func check() {
        guard phase != .checking else { return }
        guard let current = AppVersionInfo.semver else {
            phase = .failed("无法读取本地版本号")
            return
        }
        phase = .checking
        Task { @MainActor in
            let outcome = await UpdateChecker.check(
                repository: UpdateChecker.defaultRepository,
                currentVersion: current
            )
            switch outcome {
            case .upToDate: phase = .upToDate
            case .updateAvailable(let info): phase = .available(info)
            case .noRelease: phase = .noRelease
            case .failed(let reason): phase = .failed(reason)
            }
        }
    }

    private func open(_ urlString: String) {
        if let url = URL(string: urlString) {
            NSWorkspace.shared.open(url)
        }
    }
}