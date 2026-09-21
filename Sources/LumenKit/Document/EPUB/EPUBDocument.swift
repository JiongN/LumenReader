import Foundation

public enum EPUBError: LocalizedError {
    case extractionFailed(String)
    case missingContainer
    case missingPackage
    case emptySpine
    case unsafePath(String)

    public var errorDescription: String? {
        switch self {
        case .extractionFailed(let detail):
            return "解包 EPUB 失败：\(detail)"
        case .missingContainer:
            return "这不是有效的 EPUB：缺少 META-INF/container.xml。"
        case .missingPackage:
            return "这不是有效的 EPUB：找不到 OPF 包文档，或它无法解析。"
        case .unsafePath(let path):
            return "EPUB 包含越界资源路径：\(path)"
        case .emptySpine:
            return "EPUB 的 spine 为空，没有任何可阅读的章节。"
        }
    }
}

/// 一章（spine 中的一项）。
public struct EPUBChapter: Sendable, Identifiable, Equatable {
    public let id: String
    public let index: Int
    /// 相对于 OPF 所在目录的路径
    public let href: String
    /// 解包后的绝对文件路径
    public let fileURL: URL
    public let mediaType: String
    public let title: String

    public var displayTitle: String {
        title.isEmpty ? "第 \(index + 1) 章" : title
    }
}

/// EPUB 文档源。
///
/// 解包策略：用系统 `ditto` 把 EPUB（本质是 zip）解到缓存目录，而不是自己解析 zip。
/// 这样有两个好处——零第三方依赖；WebKit 能直接用 `loadFileURL` 加载章节 XHTML，
/// 图片、CSS、内嵌字体这些相对资源全部由 WebKit 原生解析，不需要我们拦截资源请求。
public final class EPUBDocumentSource: DocumentSource {

    public let kind: DocumentKind = .epub
    /// 解包根目录
    public let rootURL: URL
    public let opfURL: URL
    public let chapters: [EPUBChapter]
    public let metadata: DocumentMetadata
    public let outline: [OutlineNode]

    /// 章节纯文本缓存。全书检索与 AI 取上下文都会反复读，缓存一次值得。
    private var textCache: [Int: String] = [:]
    private let cacheLock = NSLock()

    // MARK: - 打开

    public static func open(url: URL) async throws -> EPUBDocumentSource {
        let source = url.standardizedFileURL
        let task = Task.detached(priority: .userInitiated) {
            try Task.checkCancellation()
            let attributes = try FileManager.default.attributesOfItem(atPath: source.path)
            let revision = "\(attributes[.size] ?? 0)-\(attributes[.modificationDate] ?? Date.distantPast)"
            let destination = AppPaths.epubExtractionDirectory(forPath: source.path + "|" + revision)
            try extract(epub: source, to: destination)
            try Task.checkCancellation()
            return try EPUBDocumentSource(rootURL: destination)
        }
        return try await withTaskCancellationHandler {
            let result = try await task.value
            try Task.checkCancellation()
            return result
        } onCancel: {
            task.cancel()
        }
    }

    private static let extractionLock = NSLock()

    /// 同一进程内串行解包；以文件大小和修改时间区分缓存版本，避免覆盖仍在阅读的目录。
    private static func extract(epub: URL, to directory: URL) throws {
        extractionLock.lock()
        defer { extractionLock.unlock() }
        try Task.checkCancellation()
        let container = directory.appendingPathComponent("META-INF/container.xml")
        let ready = directory.appendingPathComponent(".lumen-extracted")
        if FileManager.default.fileExists(atPath: ready.path) {
            return
        }

        try EPUBArchiveSafety.validate(epub)
        let manager = FileManager.default
        try? manager.removeItem(at: directory)
        try manager.createDirectory(at: directory, withIntermediateDirectories: true)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["-x", "-k", epub.path, directory.path]

        let errorPipe = Pipe()
        process.standardError = errorPipe
        process.standardOutput = FileHandle.nullDevice

        try process.run()
        let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            let detail = String(data: errorData, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? "ditto 退出码 \(process.terminationStatus)"
            throw EPUBError.extractionFailed(detail.isEmpty ? "ditto 退出码 \(process.terminationStatus)" : detail)
        }

        guard manager.fileExists(atPath: container.path) else {
            throw EPUBError.missingContainer
        }
        _ = try EPUBDocumentSource(rootURL: directory)
        try Data().write(to: ready, options: .atomic)
    }

    /// Resolve encoded relative paths and symlinks before reading any package resource.
    static func resourceURL(_ path: String, relativeTo base: URL, root: URL) throws -> URL {
        let decoded = path.removingPercentEncoding ?? path
        guard !decoded.hasPrefix("/"), !decoded.contains(":") else { throw EPUBError.unsafePath(path) }
        let candidate = base.appendingPathComponent(decoded).standardizedFileURL
        var ancestor = candidate
        while ancestor.path != root.standardizedFileURL.path && ancestor.path != "/" {
            if (try? FileManager.default.destinationOfSymbolicLink(atPath: ancestor.path)) != nil {
                throw EPUBError.unsafePath(path)
            }
            ancestor.deleteLastPathComponent()
        }
        let url = candidate.resolvingSymlinksInPath()
        let boundary = root.standardizedFileURL.resolvingSymlinksInPath().path + "/"
        guard url.path.hasPrefix(boundary) else { throw EPUBError.unsafePath(path) }
        return url
    }

    // MARK: - 解析

    private init(rootURL: URL) throws {
        self.rootURL = rootURL

        // 1. container.xml → OPF 路径
        let containerURL = rootURL.appendingPathComponent("META-INF/container.xml")
        guard let container = try? XMLDocument(contentsOf: containerURL, options: [.nodeLoadExternalEntitiesNever]),
              let rootfile = try? container.nodes(forXPath: "//*[local-name()='rootfile']").first as? XMLElement,
              let opfRelativePath = rootfile.attr("full-path")
        else {
            throw EPUBError.missingContainer
        }

        let opfURL = try Self.resourceURL(opfRelativePath, relativeTo: rootURL, root: rootURL)
        self.opfURL = opfURL
        let opfDirectory = opfURL.deletingLastPathComponent()

        guard let package = try? XMLDocument(contentsOf: opfURL, options: [.nodeLoadExternalEntitiesNever]) else {
            throw EPUBError.missingPackage
        }

        // 2. metadata
        let title = Self.firstString(in: package, xpath: "//*[local-name()='title']") ?? ""
        let creator = Self.firstString(in: package, xpath: "//*[local-name()='creator']") ?? ""
        let subject = Self.firstString(in: package, xpath: "//*[local-name()='subject']") ?? ""

        // 3. manifest
        var manifest: [String: (href: String, mediaType: String, properties: String)] = [:]
        let items = (try? package.nodes(forXPath: "//*[local-name()='manifest']/*[local-name()='item']")) ?? []
        for case let item as XMLElement in items {
            guard let id = item.attr("id"), let href = item.attr("href") else { continue }
            manifest[id] = (
                href: href,
                mediaType: item.attr("media-type") ?? "",
                properties: item.attr("properties") ?? ""
            )
        }

        // 4. spine → 章节顺序
        var chapters: [EPUBChapter] = []
        let itemrefs = (try? package.nodes(forXPath: "//*[local-name()='spine']/*[local-name()='itemref']")) ?? []
        for case let itemref as XMLElement in itemrefs {
            guard let idref = itemref.attr("idref"),
                  let entry = manifest[idref],
                  // 有些 EPUB 会在 spine 里混入非正文资源，跳过它们
                  entry.mediaType.contains("html") || entry.mediaType.isEmpty
            else { continue }

            let fileURL = try Self.resourceURL(entry.href, relativeTo: opfDirectory, root: rootURL)
            guard FileManager.default.fileExists(atPath: fileURL.path) else { continue }

            chapters.append(EPUBChapter(
                id: idref,
                index: chapters.count,
                href: entry.href,
                fileURL: fileURL,
                mediaType: entry.mediaType,
                title: ""
            ))
        }

        guard !chapters.isEmpty else { throw EPUBError.emptySpine }

        // 5. 目录：优先 nav 文档（EPUB 3），退回 NCX（EPUB 2）
        let navHref = manifest.first { $0.value.properties.contains("nav") }?.value.href
        let ncxHref = manifest.first { $0.value.mediaType.contains("dtbncx") }?.value.href

        var titleMap: [String: String] = [:]
        var rawOutline: [(title: String, href: String, depth: Int)] = []

        if let navHref {
            let navURL = try Self.resourceURL(navHref, relativeTo: opfDirectory, root: rootURL)
            (rawOutline, titleMap) = Self.parseNav(navURL, relativeTo: opfDirectory)
        }
        if rawOutline.isEmpty, let ncxHref {
            let ncxURL = try Self.resourceURL(ncxHref, relativeTo: opfDirectory, root: rootURL)
            (rawOutline, titleMap) = Self.parseNCX(ncxURL, relativeTo: opfDirectory)
        }

        // 把拿到的标题补回章节
        chapters = chapters.map { chapter in
            let key = Self.normalizePath(chapter.href)
            let title = titleMap[key] ?? Self.firstHeading(in: chapter.fileURL) ?? ""
            return EPUBChapter(
                id: chapter.id,
                index: chapter.index,
                href: chapter.href,
                fileURL: chapter.fileURL,
                mediaType: chapter.mediaType,
                title: title
            )
        }

        self.chapters = chapters
        self.metadata = DocumentMetadata(
            title: title,
            author: creator,
            subject: subject,
            keywords: "",
            unitCount: chapters.count
        )

        // 目录项 → 通用 DocumentLocator
        self.outline = Self.buildOutline(
            raw: rawOutline,
            chapters: chapters,
            opfDirectory: opfDirectory
        )
    }

    // MARK: - 目录解析

    static func navigationHref(_ href: String, from document: URL, relativeTo base: URL) -> String {
        guard let resolved = URL(string: href, relativeTo: document)?.absoluteURL else { return href }
        let prefix = base.standardizedFileURL.path + "/"
        let path = resolved.standardizedFileURL.path
        guard path.hasPrefix(prefix) else { return href }
        return String(path.dropFirst(prefix.count)) + (resolved.fragment.map { "#" + $0 } ?? "")
    }

    private static func parseNav(_ url: URL, relativeTo base: URL) -> ([(String, String, Int)], [String: String]) {
        guard let document = try? XMLDocument(contentsOf: url, options: [.nodeLoadExternalEntitiesNever]) else { return ([], [:]) }

        // 优先取 epub:type="toc" 的 nav，没有就取第一个 nav
        let navs = (try? document.nodes(forXPath: "//*[local-name()='nav']")) ?? []
        let toc = navs.compactMap { $0 as? XMLElement }.first { element in
            (element.attributes ?? []).contains { $0.localName == "type" && ($0.stringValue ?? "").contains("toc") }
        } ?? navs.compactMap { $0 as? XMLElement }.first

        guard let toc else { return ([], [:]) }

        var entries: [(String, String, Int)] = []
        var titleMap: [String: String] = [:]

        func walk(_ list: XMLElement, depth: Int) {
            guard depth < 8 else { return }
            let children = (try? list.nodes(forXPath: "*[local-name()='li']")) ?? []
            for case let li as XMLElement in children {
                if let anchor = (try? li.nodes(forXPath: "*[local-name()='a']").first) as? XMLElement,
                   let href = anchor.attr("href") {
                    let title = (anchor.stringValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                    let resolved = navigationHref(href, from: url, relativeTo: base)
                    entries.append((title, resolved, depth))
                    let path = normalizePath(resolved.components(separatedBy: "#").first ?? resolved)
                    if !title.isEmpty { titleMap[path] = title }
                }
                if let nested = (try? li.nodes(forXPath: "*[local-name()='ol']").first) as? XMLElement {
                    walk(nested, depth: depth + 1)
                }
            }
        }

        if let list = (try? toc.nodes(forXPath: "*[local-name()='ol']").first) as? XMLElement {
            walk(list, depth: 0)
        }

        return (entries, titleMap)
    }

    private static func parseNCX(_ url: URL, relativeTo base: URL) -> ([(String, String, Int)], [String: String]) {
        guard let document = try? XMLDocument(contentsOf: url, options: [.nodeLoadExternalEntitiesNever]) else { return ([], [:]) }

        var entries: [(String, String, Int)] = []
        var titleMap: [String: String] = [:]

        func walk(_ element: XMLElement, depth: Int) {
            guard depth < 8 else { return }
            let points = (try? element.nodes(forXPath: "*[local-name()='navPoint']")) ?? []
            for case let point as XMLElement in points {
                let title = ((try? point.nodes(forXPath: "*[local-name()='navLabel']/*[local-name()='text']").first) as? XMLElement)?
                    .stringValue?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                if let src = ((try? point.nodes(forXPath: "*[local-name()='content']").first) as? XMLElement)?.attr("src") {
                    let resolved = navigationHref(src, from: url, relativeTo: base)
                    entries.append((title, resolved, depth))
                    let path = normalizePath(resolved.components(separatedBy: "#").first ?? resolved)
                    if !title.isEmpty { titleMap[path] = title }
                }
                walk(point, depth: depth + 1)
            }
        }

        if let root = ((try? document.nodes(forXPath: "//*[local-name()='navMap']").first) as? XMLElement) {
            walk(root, depth: 0)
        }
        return (entries, titleMap)
    }

    private static func buildOutline(
        raw: [(title: String, href: String, depth: Int)],
        chapters: [EPUBChapter],
        opfDirectory: URL
    ) -> [OutlineNode] {
        guard !raw.isEmpty else {
            // 没有 nav 也没有 NCX：退化成按章节顺序的平铺目录
            return chapters.map {
                OutlineNode(title: $0.displayTitle, locator: .epub(chapterIndex: $0.index, anchor: "", charOffset: 0))
            }
        }

        // href → chapterIndex
        var indexByPath: [String: Int] = [:]
        for chapter in chapters {
            indexByPath[normalizePath(chapter.href)] = chapter.index
        }

        var nodes: [OutlineNode] = []
        var cursor = 0
        // 从最浅的一层开始递归，这样即使目录整体从 depth=1 起算也能正确成树
        let baseDepth = raw.map(\.depth).min() ?? 0
        nodes = buildTree(
            raw: raw,
            cursor: &cursor,
            depth: baseDepth,
            indexByPath: indexByPath
        )
        return nodes
    }

    /// 用递归下降把「前序遍历 + 深度」的扁平列表还原成树。
    ///
    /// nav / NCX 天然是前序展开的，深度只保证「子一定比父深」，不保证连续，
    /// 所以判断父子关系的依据是「下一个深度是否大于当前节点深度」，而不是等于 +1。
    private static func buildTree(
        raw: [(title: String, href: String, depth: Int)],
        cursor: inout Int,
        depth: Int,
        indexByPath: [String: Int]
    ) -> [OutlineNode] {
        var nodes: [OutlineNode] = []

        while cursor < raw.count {
            let entry = raw[cursor]
            guard entry.depth >= depth else { break }

            cursor += 1

            let pieces = entry.href.components(separatedBy: "#")
            let pathPart = pieces.first ?? entry.href
            let anchor = pieces.count > 1 ? pieces[1] : ""
            let children = buildTree(raw: raw, cursor: &cursor,
                                     depth: entry.depth + 1, indexByPath: indexByPath)
            guard let chapterIndex = indexByPath[normalizePath(pathPart)] else {
                nodes.append(contentsOf: children)
                continue
            }
            let title = entry.title.isEmpty ? "第 \(chapterIndex + 1) 章" : entry.title
            nodes.append(OutlineNode(
                title: title,
                locator: .epub(chapterIndex: chapterIndex,
                               anchor: anchor.removingPercentEncoding ?? anchor, charOffset: 0),
                children: children, depth: depth
            ))
        }

        return nodes
    }

    // MARK: - 文本提取

    private func plainText(chapterIndex: Int) -> String {
        cacheLock.lock()
        if let cached = textCache[chapterIndex] {
            cacheLock.unlock()
            return cached
        }
        cacheLock.unlock()

        guard chapterIndex >= 0, chapterIndex < chapters.count else { return "" }
        guard let html = Self.loadString(chapters[chapterIndex].fileURL) else { return "" }

        let text = Self.htmlToPlainText(html)

        cacheLock.lock()
        textCache[chapterIndex] = text
        cacheLock.unlock()
        return text
    }

    /// 轻量 HTML → 纯文本。只服务于检索与 AI 上下文，不追求完美还原。
    static func htmlToPlainText(_ html: String) -> String {
        var text = html

        // 去掉不产生正文内容的元素
        for pattern in ["<script[^>]*>[\\s\\S]*?</script>",
                        "<style[^>]*>[\\s\\S]*?</style>",
                        "<head[^>]*>[\\s\\S]*?</head>",
                        "<!--[\\s\\S]*?-->"] {
            text = text.replacingOccurrences(of: pattern, with: " ", options: .regularExpression)
        }

        // 块级标签与换行标记转换行，避免段落粘连
        let blockTags = ["p", "div", "br", "li", "tr", "h1", "h2", "h3", "h4", "h5", "h6",
                         "blockquote", "section", "article", "figure", "figcaption", "td", "th", "hr"]
        for tag in blockTags {
            text = text.replacingOccurrences(
                of: "</?\(tag)\\b[^>]*>",
                with: "\n",
                options: [.regularExpression, .caseInsensitive]
            )
        }

        // 其余标签直接剥掉
        text = text.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)

        text = decodeEntities(text)

        // 收敛空白
        text = text.replacingOccurrences(of: "[ \\t\\x{00A0}]+", with: " ", options: .regularExpression)
        text = text.replacingOccurrences(of: " *\\n *", with: "\n", options: .regularExpression)
        text = text.replacingOccurrences(of: "\\n{3,}", with: "\n\n", options: .regularExpression)

        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func decodeEntities(_ input: String) -> String {
        let named: [String: String] = [
            "&nbsp;": " ", "&amp;": "&", "&lt;": "<", "&gt;": ">",
            "&quot;": "\"", "&apos;": "'", "&mdash;": "—", "&ndash;": "–",
            "&hellip;": "…", "&ldquo;": "\u{201C}", "&rdquo;": "\u{201D}",
            "&lsquo;": "\u{2018}", "&rsquo;": "\u{2019}", "&middot;": "·",
            "&times;": "×", "&laquo;": "«", "&raquo;": "»"
        ]
        var result = input
        for (entity, replacement) in named {
            result = result.replacingOccurrences(of: entity, with: replacement)
        }
        // 数字实体 &#123; / &#x1F600;
        if result.contains("&#") {
            let regex = try? NSRegularExpression(pattern: "&#x?([0-9A-Fa-f]+);")
            let ns = result as NSString
            var output = ""
            var cursor = 0
            let matches = regex?.matches(in: result, range: NSRange(location: 0, length: ns.length)) ?? []
            for match in matches {
                output += ns.substring(with: NSRange(location: cursor, length: match.range.location - cursor))
                let body = ns.substring(with: match.range).dropFirst(2).dropLast()
                let isHex = body.hasPrefix("x") || body.hasPrefix("X")
                let digits = isHex ? String(body.dropFirst()) : String(body)
                if let value = UInt32(digits, radix: isHex ? 16 : 10), let scalar = Unicode.Scalar(value) {
                    output.unicodeScalars.append(scalar)
                } else {
                    output += ns.substring(with: match.range)
                }
                cursor = match.range.location + match.range.length
            }
            output += ns.substring(from: cursor)
            result = output
        }
        return result
    }

    /// 读文本并处理编码：多数 EPUB 是 UTF-8，但老书常见 GBK / Latin-1，
    /// 按 UTF-8 强读会拿到空串或乱码，所以退回系统编码探测。
    static func loadString(_ url: URL) -> String? {
        if let utf8 = try? String(contentsOf: url, encoding: .utf8), !utf8.isEmpty {
            return utf8
        }
        var usedEncoding: UInt = 0
        if let detected = try? NSString(contentsOf: url, usedEncoding: &usedEncoding) {
            return detected as String
        }
        return try? String(contentsOf: url, encoding: .isoLatin1)
    }

    /// 取章节里的第一个 h1–h6 作为兜底标题。
    private static func firstHeading(in url: URL) -> String? {
        guard let html = loadString(url),
              let range = html.range(of: "<h[1-6][^>]*>[\\s\\S]{0,200}?</h[1-6]>", options: .regularExpression)
        else {
            return nil
        }
        let text = htmlToPlainText(String(html[range])).trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty || text.count > 120 ? nil : text
    }

    static func normalizePath(_ path: String) -> String {
        var value = path
        if let decoded = value.removingPercentEncoding { value = decoded }
        while value.hasPrefix("./") { value.removeFirst(2) }
        return value
    }

    // MARK: - DocumentSource

    public func text(around locator: DocumentLocator, radius: Int) -> String {
        let index = locator.chapterIndex
        guard index >= 0 else { return "" }
        let lower = max(0, index - radius)
        let upper = min(chapters.count - 1, index + radius)
        guard lower <= upper else { return "" }
        return (lower...upper).map { plainText(chapterIndex: $0) }.joined(separator: "\n\n")
    }

    public func fullText() -> String {
        (0..<chapters.count).map { plainText(chapterIndex: $0) }.joined(separator: "\n\n")
    }

    public func search(_ query: String, limit: Int) -> [SearchHit] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return [] }

        var hits: [SearchHit] = []
        for index in 0..<chapters.count {
            let text = plainText(chapterIndex: index)
            guard !text.isEmpty else { continue }

            var searchStart = text.startIndex
            while hits.count < limit,
                  let range = text.range(of: needle, options: [.caseInsensitive], range: searchStart..<text.endIndex) {
                let offset = text.distance(from: text.startIndex, to: range.lowerBound)
                hits.append(SearchHit(
                    snippet: Self.snippet(text, around: offset, length: needle.count),
                    locator: .epub(chapterIndex: index, anchor: "", charOffset: offset),
                    range: offset..<(offset + needle.count)
                ))
                searchStart = range.upperBound
            }
            if hits.count >= limit { break }
        }
        return hits
    }

    private static func snippet(_ text: String, around offset: Int, length: Int, radius: Int = 44) -> String {
        let lower = max(0, offset - radius)
        let upper = min(text.count, offset + length + radius)
        let start = text.index(text.startIndex, offsetBy: lower)
        let end = text.index(text.startIndex, offsetBy: upper)
        let prefix = lower == 0 ? "" : "…"
        let suffix = upper == text.count ? "" : "…"
        return prefix + text[start..<end].replacingOccurrences(of: "\n", with: " ") + suffix
    }
}

// MARK: - XML 便利

extension XMLElement {
    /// 按名字取属性，同时兼容带命名空间前缀的属性（如 epub:type）。
    func attr(_ name: String) -> String? {
        if let direct = attribute(forName: name)?.stringValue { return direct }
        return attributes?.first { $0.localName == name }?.stringValue
    }
}

extension EPUBDocumentSource {
    static func firstString(in document: XMLDocument, xpath: String) -> String? {
        guard let node = (try? document.nodes(forXPath: xpath).first) as? XMLElement else { return nil }
        let value = (node.stringValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }
}
