import Testing
import Foundation
@testable import LumenKit

@Suite("版本解析与比较")
struct AppVersionTests {
    @Test func parsesSemverWithVariantShapes() {
        #expect(AppVersion(parsing: "1.0.0") == AppVersion(major: 1, minor: 0, patch: 0))
        #expect(AppVersion(parsing: "v1.1.2") == AppVersion(major: 1, minor: 1, patch: 2))
        #expect(AppVersion(parsing: "V2.0") == AppVersion(major: 2, minor: 0, patch: 0))
        #expect(AppVersion(parsing: "3") == AppVersion(major: 3, minor: 0, patch: 0))
        #expect(AppVersion(parsing: "1.2") == AppVersion(major: 1, minor: 2, patch: 0))
        #expect(AppVersion(parsing: " 1.2.3 ") == AppVersion(major: 1, minor: 2, patch: 3))
    }

    @Test func rejectsNonVersionTags() {
        #expect(AppVersion(parsing: "latest") == nil)
        #expect(AppVersion(parsing: "main") == nil)
        #expect(AppVersion(parsing: "") == nil)
        #expect(AppVersion(parsing: "v") == nil)
        #expect(AppVersion(parsing: "1.2.3.4") == nil)   // 超过三段的语义化版本不支持
        #expect(AppVersion(parsing: "abc.0.1") == nil)
        #expect(AppVersion(parsing: "-1.0.0") == nil)
    }

    @Test func comparesNumericallyNotLexically() {
        // 字典序比较会错判：按字符串 "1.10" < "1.2"（'1'=='1','.'=='.','1'<'2'）。
        #expect(AppVersion(major: 1, minor: 10, patch: 0) > AppVersion(major: 1, minor: 2, patch: 0))
        #expect(AppVersion(major: 2, minor: 0, patch: 0) > AppVersion(major: 1, minor: 99, patch: 99))
        #expect(AppVersion(major: 1, minor: 0, patch: 1) > AppVersion(major: 1, minor: 0, patch: 0))
        #expect(AppVersion(major: 1, minor: 0, patch: 0) == AppVersion(major: 1, minor: 0, patch: 0))
    }

    @Test func displayIsCanonical() {
        #expect(AppVersion(major: 1, minor: 0, patch: 0).display == "1.0.0")
    }
}

@Suite("更新判断（纯函数）")
struct UpdateJudgementTests {
    @Test func newerOnlyStrictlyGreater() {
        let local = AppVersion(major: 1, minor: 0, patch: 0)
        #expect(UpdateChecker.isNewer(current: local, latest: AppVersion(major: 1, minor: 0, patch: 1)) == true)
        #expect(UpdateChecker.isNewer(current: local, latest: AppVersion(major: 1, minor: 1, patch: 0)) == true)
        #expect(UpdateChecker.isNewer(current: local, latest: AppVersion(major: 2, minor: 0, patch: 0)) == true)
        // 相同不算新
        #expect(UpdateChecker.isNewer(current: local, latest: AppVersion(major: 1, minor: 0, patch: 0)) == false)
        // 远程更旧不算新（新建仓库误打低版本时不提示）
        #expect(UpdateChecker.isNewer(current: local, latest: AppVersion(major: 0, minor: 9, patch: 9)) == false)
    }
}

@Suite("GitHub Release 解析")
struct UpdateParseTests {

    private func makeRelease(tag: String, draft: Bool = false, prerelease: Bool = false,
                             assets: [String] = ["https://example.com/Lumen-1.1.0.zip"]) -> Data {
        let assetDicts = assets.map { ["browser_download_url": $0] }
        let object: [String: Any] = [
            "tag_name": tag,
            "html_url": "https://github.com/x/y/releases/tag/\(tag)",
            "assets": assetDicts,
            "body": "## 新功能",
            "draft": draft,
            "prerelease": prerelease,
        ]
        // 用 JSONSerialization 构造：手拼 JSON 字符串极易在空 assets / 转义上出错，
        // 而**自检素材本身出错**正是本项目反复踩的坑（测试比被测对象更先坏）。
        return try! JSONSerialization.data(withJSONObject: object)
    }

    let local = AppVersion(major: 1, minor: 0, patch: 0)

    @Test func returnsUpdateWhenRemoteNewer() {
        let outcome = UpdateChecker.parse(data: makeRelease(tag: "v1.1.0"), current: local)
        guard case .updateAvailable(let info) = outcome else {
            Issue.record("期望 updateAvailable，得到 \(outcome)")
            return
        }
        #expect(info.version == AppVersion(major: 1, minor: 1, patch: 0))
        #expect(info.tagName == "v1.1.0")
        #expect(info.downloadURL == "https://example.com/Lumen-1.1.0.zip")
        #expect(info.releaseNotes == "## 新功能")
    }

    @Test func ignoresDraftAndPrerelease() {
        #expect(UpdateChecker.parse(data: makeRelease(tag: "v2.0.0", draft: true), current: local) == .upToDate)
        #expect(UpdateChecker.parse(data: makeRelease(tag: "v2.0.0", prerelease: true), current: local) == .upToDate)
    }

    @Test func ignoresNonVersionTagEvenIfHigherLooking() {
        #expect(UpdateChecker.parse(data: makeRelease(tag: "latest"), current: local) == .upToDate)
    }

    @Test func doesNotFlagSameOrOlder() {
        #expect(UpdateChecker.parse(data: makeRelease(tag: "v1.0.0"), current: local) == .upToDate)
        #expect(UpdateChecker.parse(data: makeRelease(tag: "v0.5.0"), current: local) == .upToDate)
    }

    @Test func fallsBackToHTMLWhenNoDownloadAsset() {
        let outcome = UpdateChecker.parse(
            data: makeRelease(tag: "v1.1.0", assets: []),
            current: local
        )
        guard case .updateAvailable(let info) = outcome else {
            Issue.record("期望 updateAvailable，得到 \(outcome)")
            return
        }
        #expect(info.downloadURL == nil)
        #expect(info.htmlURL == "https://github.com/x/y/releases/tag/v1.1.0")
    }

    @Test func malformedBodyYieldsFailure() {
        #expect(UpdateChecker.parse(data: Data("not json".utf8), current: local) == .failed("无法解析 GitHub 返回的数据"))
    }
}