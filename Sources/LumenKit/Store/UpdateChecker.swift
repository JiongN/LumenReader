import Foundation

// MARK: - 语义化版本

/// 拆成主/次/补丁的三元组，支持 `v` 前缀与数值比较。
///
/// 为什么不用 `Comparable` 的标准实现直接包 `String`：GitHub Release 的
/// `tag_name`（`v1.0.0`）和应用自身的 `CFBundleShortVersionString`（`1.0.0`）
/// 开头不同、且字符串比较 `"1.10" > "1.2"` 是错的（按字典序 `9` 在 `2` 之后）。
/// 更新检查的核心就一句话——「服务器上的版本是否真的比本地新」——
/// 这一句必须答对，所以版本号必须拆成数字比较而不是比字符串。
public struct AppVersion: Comparable, Equatable, Sendable {
    public var major: Int
    public var minor: Int
    public var patch: Int

    public init(major: Int, minor: Int, patch: Int) {
        self.major = major
        self.minor = minor
        self.patch = patch
    }

    /// 容错解析：剥掉前导 `v`/`V`，按 `.` 切开，只认数字段；缺位按 0 补。
    /// 解析不出的段不把它当成 0 丢弃——那会让 `1.2.x` 和 `1.2.0` 被当成一回事。
    /// 整段解析失败返回 nil（如 `latest`、`main` 这类 tag）。
    public init?(parsing raw: String) {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.lowercased().hasPrefix("v") { text.removeFirst() }

        let parts = text.split(separator: ".")
        guard parts.count >= 1, parts.count <= 3,
              let major = Int(parts[0]), major >= 0 else { return nil }
        // 缺段补 0；**已出现**的段必须能解析成非负整数，否则整段判解析失败
        // （不能把 `1.2.x` 悄悄当成 `1.2.0`）。
        let minor: Int
        if parts.count > 1 {
            guard let parsed = Int(parts[1]), parsed >= 0 else { return nil }
            minor = parsed
        } else { minor = 0 }
        let patch: Int
        if parts.count > 2 {
            guard let parsed = Int(parts[2]), parsed >= 0 else { return nil }
            patch = parsed
        } else { patch = 0 }

        self.major = major
        self.minor = minor
        self.patch = patch
    }

    public static func < (lhs: AppVersion, rhs: AppVersion) -> Bool {
        if lhs.major != rhs.major { return lhs.major < rhs.major }
        if lhs.minor != rhs.minor { return lhs.minor < rhs.minor }
        return lhs.patch < rhs.patch
    }

    public var display: String { "\(major).\(minor).\(patch)" }
}

// MARK: - 更新信息

/// 从 GitHub Releases 的 `latest` 响应里解出的「可更新的那一版」。
public struct UpdateInfo: Sendable, Equatable {
    public var version: AppVersion
    /// 最新 tag（远程原始写法，如 `v1.1.0`），用于展示与跳转。
    public var tagName: String
    /// Release 页面（网页）地址，用于「去下载」。
    public var htmlURL: String
    /// macOS 分发产物的直链（ZIP/DMG）。没有挂产物时为 nil。
    public var downloadURL: String?
    /// Release 说明（markdown 原文）。
    public var releaseNotes: String

    public init(version: AppVersion, tagName: String, htmlURL: String, downloadURL: String?, releaseNotes: String) {
        self.version = version
        self.tagName = tagName
        self.htmlURL = htmlURL
        self.downloadURL = downloadURL
        self.releaseNotes = releaseNotes
    }
}

// MARK: - 更新检查

/// 免密钥、走 GitHub Releases API 的更新检查。
///
/// 为什么不用 Sparkle：本项目是零依赖 + 纯 SwiftPM + 无 Xcode 的工程，
/// Sparkle 是闭源二进制 framework，需要嵌入 + 维护 appcast.xml + 复杂签名；
/// 对一个「自签 + 免会员、体积优先」的免费工具它属于过度工程。GitHub API 已
/// 免费提供 `releases/latest`，App 里用一个 URLSession 请求就能拿到来版号与直链。
///
/// 为什么要写清这个取舍：这是一条**服务端有能力、但本地刻意不做**的路径，
/// 不写明白，未来的人会以为「漏了自动更新」而再引一遍 Sparkle。
public enum UpdateChecker {

    /// 分发的 GitHub 仓库。repo 名要带 owner（`JiongN/LumenReader`）。
    ///
    /// 不从 Info.plist 读：打包进 bundle 的 plist 改起来要重编译，而仓库名是
    /// 一旦定下就不该动的常量，写死在这里更省事、也少一个配置漂移的可能。
    public static let defaultRepository = "JiongN/LumenReader"

    /// 检查结果。可判等（`== .upToDate`）以便测试断言。
    public enum Outcome: Sendable, Equatable {
        /// 无 release，或远程版本不高过本地。
        case upToDate
        /// 远程有更高版本。
        case updateAvailable(UpdateInfo)
        /// 仓库还没有任何 release（`latest` 返回 404）。
        case noRelease
        /// 请求失败（断网 / 非 2xx / 解析失败）。reason 给一句人能看懂的说明。
        case failed(String)
    }

    /// 纯比较函数：**服务器版本是否严格高于本地版本**。
    ///
    /// 抽成独立静态函数是为了让自检能做**纯函数表驱动断言**（项目硬规矩：
    /// 能断言的功能才算做完）。"严格高于"是刻意选的语义——同版本不该提示更新，
    /// 服务器返回比本地还旧的版本（如新建仓库误打低版本）也不该提示。
    public static func isNewer(current: AppVersion, latest: AppVersion) -> Bool {
        latest > current
    }

    /// 请求 GitHub `releases/latest` 并给出更新判定。
    ///
    /// - Parameters:
    ///   - repository: `owner/name`。默认 `JiongN/LumenReader`。
    ///   - currentVersion: 本地版本号（应用自身的 CFBundleShortVersionString）。
    ///   - timeout: 请求超时。更新检查是锦上添花，不该让用户等。
    public static func check(
        repository: String = defaultRepository,
        currentVersion: AppVersion,
        timeout: TimeInterval = 8
    ) async -> Outcome {
        guard let url = URL(string: "https://api.github.com/repos/\(repository)/releases/latest") else {
            return .failed("仓库名非法")
        }

        var request = URLRequest(url: url)
        request.timeoutInterval = timeout
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("Lumen/1.0", forHTTPHeaderField: "User-Agent")

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            return .failed("网络请求失败：\(error.localizedDescription)")
        }

        guard let http = response as? HTTPURLResponse else {
            return .failed("响应不是 HTTP")
        }

        // 404 说明仓库还没有 release——这是"没有可更新内容"，不是错误。
        if http.statusCode == 404 {
            return .noRelease
        }
        guard (200..<300).contains(http.statusCode) else {
            return .failed("GitHub 返回状态码 \(http.statusCode)")
        }

        return parse(data: data, current: currentVersion)
    }

    /// 解析 GitHub release JSON 并与本地版本比较。可测：喂一段 JSON 字节即可。
    public static func parse(data: Data, current currentVersion: AppVersion) -> Outcome {
        let decoder = JSONDecoder()
        guard let release = try? decoder.decode(GitHubRelease.self, from: data) else {
            return .failed("无法解析 GitHub 返回的数据")
        }
        // 草稿 / 预发布不该提示普通用户更新。
        if release.draft || release.prerelease {
            return .upToDate
        }
        guard let remote = AppVersion(parsing: release.tagName) else {
            return .upToDate  // tag 不是可比较的版本，不提示
        }
        guard isNewer(current: currentVersion, latest: remote) else {
            return .upToDate
        }

        let download = release.assets
            .map(\.browserDownloadURL)
            .filter { $0.hasSuffix(".zip") || $0.hasSuffix(".dmg") }
            .first
        let info = UpdateInfo(
            version: remote,
            tagName: release.tagName,
            htmlURL: release.htmlURL,
            downloadURL: download,
            releaseNotes: release.body ?? ""
        )
        return .updateAvailable(info)
    }
}

// MARK: - GitHub API 解码模型

/// GitHub Releases API 里 `releases/latest` 返回的一小部分字段。
/// 只解我们需要的，不要整份 JSON。
private struct GitHubRelease: Decodable {
    let tagName: String
    let htmlURL: String
    let assets: [Asset]
    let body: String?
    let draft: Bool
    let prerelease: Bool

    struct Asset: Decodable {
        let browserDownloadURL: String

        enum CodingKeys: String, CodingKey {
            case browserDownloadURL = "browser_download_url"
        }
    }

    enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case htmlURL = "html_url"
        case assets
        case body
        case draft
        case prerelease
    }
}