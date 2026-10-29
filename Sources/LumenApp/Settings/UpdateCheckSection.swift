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

/// Shared by Settings and the app-menu update window.
struct UpdateCheckSection: View {
    @ObservedObject private var updater = AppUpdater.shared

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.m) {
            HStack {
                Text("更新")
                    .font(DS.Typo.headline)
                Spacer()
                if updater.busy {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Button("检查更新") { updater.check() }
                }
            }
            Toggle("自动检查更新", isOn: $updater.automatic)
            statusText
            if case .available(let info) = updater.phase {
                HStack(spacing: DS.Space.s) {
                    if info.installAsset != nil {
                        Button("下载并重启更新") { updater.install(info) }
                            .buttonStyle(.borderedProminent)
                    }
                    Link("发布说明", destination: URL(string: "https://github.com/JiongN/LumenReader/releases")!)
                }
                if info.installAsset == nil {
                    Text("该版本尚无可校验的安装包，请从发布页安装。")
                        .font(DS.Typo.caption).foregroundStyle(DS.Palette.textSecondary)
                }
                if !info.releaseNotes.isEmpty {
                    DisclosureGroup("更新说明") {
                        Text(info.releaseNotes).textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .font(DS.Typo.callout)
                }
            }
            if updater.phase == .preparing {
                Button("取消下载") { updater.cancel() }
            }
            Text("每天检查 GitHub 正式版；更新前核验校验值与签名，保存完成后重启。")
                .font(DS.Typo.caption).foregroundStyle(DS.Palette.textSecondary)
        }
        .padding(DS.Space.l)
        .background(
            RoundedRectangle(cornerRadius: DS.Radius.m, style: .continuous)
                .fill(DS.Palette.surfaceSunken)
        )
    }

    @ViewBuilder
    private var statusText: some View {
        switch updater.phase {
        case .idle:
            Text("当前版本：\(AppVersionInfo.display)")
                .font(DS.Typo.callout)
                .foregroundStyle(DS.Palette.textSecondary)
        case .checking:
            Text("正在检查…")
        case .preparing:
            Text("正在下载并校验更新，完成后将重启…")
        case .restarting:
            Text("正在等待批注与会话保存，随后安装更新…")
        case .available(let info):
            Text("发现新版本 \(info.tagName)（当前 \(AppVersionInfo.display)）。")
                .font(DS.Typo.callout)
                .foregroundStyle(DS.Palette.success)
        case .current:
            Text("已是最新版本（\(AppVersionInfo.display)）。")
                .font(DS.Typo.callout)
                .foregroundStyle(DS.Palette.success)
        case .noRelease:
            Text("仓库暂无发布版本。")
                .font(DS.Typo.callout)
                .foregroundStyle(DS.Palette.textSecondary)
        case .failed(let reason):
            Text("更新未完成：\(reason)")
                .font(DS.Typo.callout)
                .foregroundStyle(DS.Palette.danger)
        }
    }

}
