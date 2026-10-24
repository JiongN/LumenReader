import Foundation
import PDFKit
import LumenKit

/// Header-only, local extraction. Never renders pages, starts OCR, or reads the whole paper.
enum PaperIdentityExtractor {
    struct Line: Sendable {
        let text: String
        let page: Int
        let top: Double
        let height: Double
    }

    struct Result: Sendable {
        let identity: GraphIdentity
        let text: String
    }

    static func read(url: URL, kind: DocumentKind, metadata: DocumentMetadata = .init()) -> Result {
        var lines: [Line] = []
        var embedded = GraphIdentity(title: metadata.title, authors: metadata.author.isEmpty ? [] : [metadata.author])
        if kind == .pdf, let document = PDFDocument(url: url) {
            if embedded.title.isEmpty { embedded.title = document.documentAttributes?[PDFDocumentAttribute.titleAttribute] as? String ?? "" }
            if embedded.authors.isEmpty, let author = document.documentAttributes?[PDFDocumentAttribute.authorAttribute] as? String {
                embedded.authors = [author]
            }
            for index in 0..<min(2, document.pageCount) {
                guard !Task.isCancelled, let page = document.page(at: index) else { break }
                let box = page.bounds(for: .mediaBox)
                guard box.height > 0 else { continue }
                for selection in (page.selection(for: box)?.selectionsByLine() ?? []).prefix(200) {
                    let text = clean(selection.string ?? "")
                    let bounds = selection.bounds(for: page)
                    guard !text.isEmpty, bounds.height.isFinite, bounds.height > 0 else { continue }
                    lines.append(Line(text: text, page: index, top: (box.maxY - bounds.maxY) / box.height,
                                      height: bounds.height))
                }
            }
        }
        return extract(lines: lines, metadata: embedded, filename: url.deletingPathExtension().lastPathComponent)
    }

    static func extract(lines input: [Line], metadata: GraphIdentity, filename: String) -> Result {
        let lines = input.prefix(400).filter { $0.top.isFinite && $0.height.isFinite && $0.height > 0 }
            .sorted { $0.page == $1.page ? $0.top < $1.top : $0.page < $1.page }
        let text = String(lines.map(\.text).joined(separator: "\n").prefix(24_000))
        let structuredHeaderPage = lines.first { isAbstract($0.text) }?.page
        var best: (title: String, end: Int, score: Double)?
        for index in lines.indices {
            let line = lines[index]
            guard structuredHeaderPage == nil || line.page == structuredHeaderPage else { continue }
            let pageLines = lines.filter { $0.page == line.page }
            let abstractTop = pageLines.first { isAbstract($0.text) }?.top ?? 0.60
            guard line.top >= 0.035, line.top < min(0.60, abstractTop), plausibleTitle(line.text) else { continue }
            let bodyHeights = pageLines.filter { $0.top >= 0.25 && $0.text.count >= 12 }.map(\.height).sorted()
            let bodyHeight = bodyHeights.isEmpty ? line.height : bodyHeights[(bodyHeights.count - 1) / 2]
            let prominence = line.height / max(1, bodyHeight)
            guard prominence >= 1.18 else { continue }
            var title = titleText(line.text), end = index
            for next in lines.indices.dropFirst(index + 1).prefix(3) {
                let following = lines[next], previous = lines[end]
                guard following.page == line.page, following.top < abstractTop,
                      following.top - previous.top > 0.005, following.top - previous.top < 0.08,
                      following.height >= line.height * 0.75, following.height <= line.height * 1.30,
                      plausibleTitle(following.text), title.count + following.text.count < 240 else { break }
                title += joiner(title, following.text) + titleText(following.text)
                end = next
            }
            let score = prominence * 4 + min(2, Double(title.count) / 20) - line.top - Double(line.page) * 0.8
            if best.map({ score > $0.score }) ?? true { best = (title, end, score) }
        }
        let visible = normalized(text)
        let metadataTitle = titleText(metadata.title)
        let title: String
        let source: String
        if let best {
            title = best.title; source = "首页版式（请核对）"
        } else if plausibleTitle(metadataTitle), visible.contains(normalized(metadataTitle)) || lines.isEmpty && !metadataTitle.isEmpty {
            title = metadataTitle; source = "文档属性（请核对）"
        } else {
            let parts = filename.components(separatedBy: " - ")
            let authorFirst = parts.count >= 3 && parts[1].range(of: #"^(?:19|20)\d{2}$"#, options: .regularExpression) != nil
            title = titleText(authorFirst ? parts.dropFirst(2).joined(separator: " - ") : parts.first ?? filename)
            source = "文件名回退（请核对）"
        }
        var authors: [String] = []
        if let best {
            let titleLine = lines[best.end]
            for line in lines.dropFirst(best.end + 1).prefix(4) {
                guard line.page == titleLine.page, line.top - titleLine.top < 0.15, !isAbstract(line.text) else { break }
                let markedByline = line.text.first.map { "◎○●■□◆◇".contains($0) } ?? false
                if line.height < titleLine.height * (markedByline ? 1 : 0.8),
                   let found = authorNames(line.text) { authors = found; break }
            }
        }
        if authors.isEmpty {
            authors = metadata.authors.filter {
                !isVendorAuthor($0)
                    && (lines.isEmpty || visible.contains(normalized($0)))
            }
        }
        let header = lines.filter { $0.top < 0.60 }.map(\.text).joined(separator: "\n")
        let doiLines = lines.filter { $0.page == (structuredHeaderPage ?? 0) && $0.text.lowercased().contains("doi") }
        let doiText = doiLines.map(\.text).joined(separator: "\n")
        let doi = doiText.range(of: #"10\.\d{4,9}/[-._;()/:A-Z0-9]+"#, options: [.regularExpression, .caseInsensitive])
            .flatMap { range -> String? in
                // A missing glyph can split an identifier (e.g. ISSN digits). Do not return its prefix as a DOI.
                let tail = doiText[range.upperBound...].prefix { $0 != "\n" }
                if tail.first?.isWhitespace == true, tail.drop(while: \.isWhitespace).first?.isNumber == true { return nil }
                return String(doiText[range])
            }
        let yearText = filename.range(of: #"\b(?:19|20)\d{2}\b"#, options: .regularExpression).map { String(filename[$0]) }
            ?? header.range(of: #"\b(?:19|20)\d{2}\b"#, options: .regularExpression).map { String(header[$0]) }
        return Result(identity: GraphIdentity(title: title, authors: authors, year: yearText.flatMap(Int.init),
                                             doi: doi ?? metadata.doi, source: source), text: text)
    }

    static func normalized(_ value: String) -> String {
        value.lowercased().filter { $0.isLetter || $0.isNumber }
    }

    static func isVendorAuthor(_ value: String) -> Bool {
        ["cnki", "中国知网", "adobe", "microsoft"].contains(normalized(value))
    }

    private static func isAbstract(_ value: String) -> Bool {
        let text = clean(value).replacingOccurrences(of: " ", with: "").lowercased()
            .trimmingCharacters(in: CharacterSet(charactersIn: "[【(（"))
        return text.hasPrefix("摘要") || text.hasPrefix("abstract") || text.hasPrefix("关键词") || text.hasPrefix("keywords")
    }

    private static func plausibleTitle(_ value: String) -> Bool {
        let text = clean(value), lower = text.lowercased()
        guard (4...240).contains(text.count), !isAbstract(text), !text.hasSuffix(".pdf"),
              text.filter(\.isLetter).count >= 4 else { return false }
        let labels = ["doi", "http", "journal", "issn", "cnki", "收稿", "基金", "文章编号", "中图分类", "作者简介", "版权所有", "引用：", "引用:", "to cite", "to link", "downloaded", "untitled", "microsoft word", "document", "学报", "总第"]
        return !labels.contains(where: lower.contains)
    }

    private static func authorNames(_ value: String) -> [String]? {
        var text = clean(value).trimmingCharacters(in: CharacterSet(charactersIn: "◎○●■□◆◇"))
            .trimmingCharacters(in: .whitespaces)
        guard text.count < 140, !text.contains(where: { "（(。:：@/".contains($0) }),
              !["大学", "学院", "研究院", "研究中心", "university", "school", "institute", "department", "摘要"].contains(where: text.lowercased().contains) else { return nil }
        text = text.replacingOccurrences(of: #"[\d*†‡¹²³⁴⁵⁶⁷⁸⁹]+"#, with: "", options: .regularExpression)
        let chinese = text.unicodeScalars.contains { (0x4E00...0x9FFF).contains($0.value) }
        let names: [String]
        if chinese {
            let groups = text.components(separatedBy: CharacterSet(charactersIn: ",，、;；")).filter { !$0.isEmpty }
            let words = text.split(whereSeparator: \.isWhitespace).map(String.init)
            if groups.count > 1 { names = groups.map { $0.filter { !$0.isWhitespace } } }
            else { names = words.count <= 3 && words.allSatisfy({ $0.count == 1 }) ? [words.joined()] : words }
            guard !names.isEmpty, names.count <= 12,
                  names.allSatisfy({ (2...4).contains($0.count) && $0.unicodeScalars.allSatisfy { (0x4E00...0x9FFF).contains($0.value) } }) else { return nil }
        } else {
            names = text.replacingOccurrences(of: " and ", with: ",").components(separatedBy: ",").map(clean).filter { !$0.isEmpty }
            guard !names.isEmpty, names.count <= 12, names.allSatisfy({ (2...6).contains($0.split(separator: " ").count) }) else { return nil }
        }
        return names
    }

    private static func clean(_ value: String) -> String { value.split(whereSeparator: \.isWhitespace).joined(separator: " ") }
    private static func titleText(_ value: String) -> String {
        clean(value).replacingOccurrences(of: #"(?<=[\p{Han}])\s+(?=[\p{Han}])"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: " *†‡¹²³⁴⁵⁶⁷⁸⁹"))
    }
    private static func joiner(_ left: String, _ right: String) -> String {
        guard let a = left.unicodeScalars.last, let b = right.unicodeScalars.first else { return "" }
        return (0x4E00...0x9FFF).contains(a.value) || (0x4E00...0x9FFF).contains(b.value) || right.hasPrefix("—") ? "" : " "
    }
}
