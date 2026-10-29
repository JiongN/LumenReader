import Foundation

extension UpdateChecker {
    /// GitHub's public release redirect and checksum asset do not consume REST
    /// API quota. The same bundle signature checks still apply before install.
    static func publicRelease(repository: String, current: AppVersion, timeout: TimeInterval) async -> Outcome {
        do {
            let base = "https://github.com/\(repository)/releases"
            guard repository.range(of: #"^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$"#, options: .regularExpression) != nil,
                  let latestURL = URL(string: base + "/latest") else { return .failed("仓库名非法") }
            var latest = URLRequest(url: latestURL, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: timeout)
            latest.httpMethod = "HEAD"
            let (_, response) = try await URLSession.shared.data(for: latest)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200,
                  let page = http.url, let tag = releaseTag(page: page, repository: repository),
                  let version = AppVersion(parsing: tag) else {
                return .failed("GitHub 发布页暂时无法访问，请稍后重试")
            }
            guard version > current else { return .upToDate }
            let name = "Lumen-\(tag)-macOS.zip"
            guard let download = URL(string: base + "/download/\(tag)/\(name)"),
                  let checksums = URL(string: base + "/download/\(tag)/SHA256SUMS") else { return .failed("发布地址无效") }
            let checksumRequest = URLRequest(url: checksums, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: timeout)
            let (data, checkResponse) = try await URLSession.shared.data(for: checksumRequest)
            guard let checkHTTP = checkResponse as? HTTPURLResponse, checkHTTP.statusCode == 200,
                  data.count <= 8192, let text = String(data: data, encoding: .utf8),
                  let digest = checksum(text: text, name: name) else {
                return .updateAvailable(UpdateInfo(version: version, tagName: tag, htmlURL: page.absoluteString,
                                                  downloadURL: nil, releaseNotes: ""))
            }
            var sizeRequest = URLRequest(url: download, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: timeout)
            sizeRequest.httpMethod = "HEAD"
            let (_, sizeResponse) = try await URLSession.shared.data(for: sizeRequest)
            let size = sizeResponse.expectedContentLength
            let asset: UpdateAsset?
            if let sizeHTTP = sizeResponse as? HTTPURLResponse, sizeHTTP.statusCode == 200,
               size > 0, size <= UpdateAsset.maximumBytes {
                asset = UpdateAsset(url: download, size: size, digest: digest)
            } else { asset = nil }
            return .updateAvailable(UpdateInfo(version: version, tagName: tag, htmlURL: page.absoluteString,
                                              downloadURL: download.absoluteString, releaseNotes: "", installAsset: asset))
        } catch is CancellationError { return .failed("更新检查已取消") }
        catch { return .failed("GitHub 暂时无法访问：\(error.localizedDescription)") }
    }

    static func releaseTag(page: URL, repository: String) -> String? {
        let tag = page.lastPathComponent
        guard page.scheme == "https", page.host == "github.com", page.port == nil,
              page.user == nil, page.password == nil, page.query == nil, page.fragment == nil,
              page.path == "/\(repository)/releases/tag/\(tag)", AppVersion(parsing: tag) != nil else { return nil }
        return tag
    }

    static func checksum(text: String, name: String) -> String? {
        let matches = text.split(whereSeparator: \.isNewline).compactMap { line -> String? in
            let fields = line.split(maxSplits: 1, whereSeparator: \.isWhitespace)
            guard fields.count == 2 else { return nil }
            let file = fields[1].trimmingCharacters(in: .whitespaces)
            guard file == name || file == "*" + name else { return nil }
            let digest = "sha256:" + fields[0]
            return UpdateAsset.validDigest(digest) ? digest : nil
        }
        return matches.count == 1 ? matches[0] : nil
    }
}
