import Foundation
import LumenKit

/// 更新检查自检：`--update-report 1`。
///
/// 验证三个层次（由内而外）：
/// 1. **版本读取**：`AppVersionInfo.semver` 必须能从 Info.plist 解出——AboutPane 的
///    「检查更新」全靠它，解不出整个 UI 不可用。
/// 2. **判定纯函数**：表驱动断言 `UpdateChecker.isNewer` 与 `parse`（与 LumenKit 单测
///    互为印证，但那套跑在测试 target；这里在**产品二进制里**再跑一遍，证明打进
///    dist 的这份代码也判得对）。
/// 3. **真实端到端**：真的请求 GitHub `releases/latest`，打印远程版本与判定。
///    GitHub 是外部服务、可能随时间变化（新发布/断网），所以只打印、不硬断言——
///    但「请求没崩溃、返回了某个合法结果」本身就是有价值的信号。
///
/// 为什么按这个顺序：更新检查这个功能最容易踩的坑是「本地版本号解不出来」和
/// 「版本比较写错」（字典序陷阱），这两样必须可证伪；真实请求是锦上添花。
@MainActor
enum UpdateAudit {

    static func run() {
        guard LaunchOptions.updateReport else { return }

        var passed = 0
        var failures: [String] = []
        func check(_ name: String, _ ok: Bool, _ detail: String = "") {
            if ok { passed += 1 } else { failures.append(name) }
            NSLog("%@", "[Lumen][update] \(ok ? "✅" : "❌") \(name)"
                  + (ok || detail.isEmpty ? "" : " —— \(detail)"))
        }

        // ── ① 版本读取链路 ────────────────────────────────────────────────
        NSLog("%@", "[Lumen][update] 界面版本 = \(AppVersionInfo.display)")
        guard let local = AppVersionInfo.semver else {
            NSLog("[Lumen][update] ❌ 本地版本号解析失败：AppVersionInfo.semver == nil")
            NSLog("%@", "[Lumen][update] 结果：\(passed) 通过 / \(failures.count) 失败：\(failures)")
            return
        }
        check("Info.plist 版本号可解析", true, "本地 \(local.display)")

        // ── ② 判定纯函数（表驱动，可证伪）──────────────────────────────────
        struct Row {
            let name: String
            let local: AppVersion
            let latest: AppVersion
            let expectUpdate: Bool
        }
        let rows: [Row] = [
            Row(name: "1.0.0 → 1.0.1 应为更新", local: .init(1, 0, 0), latest: .init(1, 0, 1), expectUpdate: true),
            Row(name: "1.0.0 → 1.1.0 应为更新", local: .init(1, 0, 0), latest: .init(1, 1, 0), expectUpdate: true),
            Row(name: "1.9.0 → 1.10.0 应为更新(数字比较)", local: .init(1, 9, 0), latest: .init(1, 10, 0), expectUpdate: true),
            Row(name: "1.0.0 → 1.0.0 同版不算更新", local: .init(1, 0, 0), latest: .init(1, 0, 0), expectUpdate: false),
            Row(name: "1.5.0 → 1.0.0 更旧不算更新", local: .init(1, 5, 0), latest: .init(1, 0, 0), expectUpdate: false),
        ]
        for row in rows {
            check(row.name, UpdateChecker.isNewer(current: row.local, latest: row.latest) == row.expectUpdate)
        }

        // parse 端到端：给一段「比本地新的远程 release」，应判定有更新
        do {
            let newer = try releaseJSON(tag: "v9.9.9", appVersion: local)
            if case .updateAvailable(let info) = UpdateChecker.parse(data: newer, current: local) {
                check("远程更新 JSON → 判为 updateAvailable", true, "tag=\(info.tagName) url=\(info.downloadURL ?? "无直链")")
            } else {
                check("远程更新 JSON → 判为 updateAvailable", false, "解析结果不符")
            }
        } catch {
            check("远程更新 JSON → 判为 updateAvailable", false, "构造测试 JSON 失败：\(error)")
        }

        // ── ③ 真实端到端（只打印，不硬断言）───────────────────────────────
        NSLog("%@", "[Lumen][update] 真实请求 GitHub \(UpdateChecker.defaultRepository)…")
        Task {
            let outcome = await UpdateChecker.check(
                repository: UpdateChecker.defaultRepository,
                currentVersion: local
            )
            let description: String
            switch outcome {
            case .upToDate: description = "已是最新"
            case .updateAvailable(let info): description = "有更新 \(info.tagName)（\(info.htmlURL)）"
            case .noRelease: description = "仓库暂无 release"
            case .failed(let reason): description = "失败：\(reason)"
            }
            NSLog("%@", "[Lumen][update] 真实请求结果：\(description)")

            NSLog("%@", "[Lumen][update] 结果汇总：\(passed) 通过 / \(failures.count) 失败：\(failures)")
        }
    }

    /// 构造一段 GitHub release JSON。`appVersion` 只用来算一个安全的"更高版本"。
    private static func releaseJSON(tag: String, appVersion: AppVersion) throws -> Data {
        let url = "https://example.com/Lumen-\(tag).zip"
        let object: [String: Any] = [
            "tag_name": tag,
            "html_url": "https://github.com/x/y/releases/tag/\(tag)",
            "assets": [["browser_download_url": url]],
            "body": "## 更新说明",
            "draft": false,
            "prerelease": false,
        ]
        return try JSONSerialization.data(withJSONObject: object)
    }
}

extension AppVersion {
    init(_ major: Int, _ minor: Int, _ patch: Int) {
        self.init(major: major, minor: minor, patch: patch)
    }
}