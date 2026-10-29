import Foundation
import PDFKit
import AppKit
import LumenKit

enum PDFSmartOutlineSource {
    /// Called from a detached worker; never reads the live PDFView's document.
    static func read(url: URL, cachedOCR: [Int: String]) throws -> SmartOutlineSource {
        guard let document = PDFDocument(url: url) else { throw AIError.invalidResponse }
        var candidates: [SmartOutlineCandidate] = [], missing: [Int] = []
        var runningHeads: [String: Set<Int>] = [:]
        var runningCandidateIDs: Set<String> = []
        for index in 0..<document.pageCount {
            try Task.checkCancellation()
            autoreleasepool {
                guard let page = document.page(at: index) else { missing.append(index); return }
                let size = page.bounds(for: .mediaBox).size
                let extracted = textLines(page: page, pageIndex: index)
                let lines = extracted.lines
                let text = cleanedOutlineText(page.string ?? "")
                if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, let dictionary = page.pageRef?.dictionary {
                    var contents: CGPDFObjectRef?
                    if !CGPDFDictionaryGetObject(dictionary, "Contents", &contents) { return }
                }
                if PDFScanDetector.needsOCR(page, textLayer: text) {
                    if let cached = cachedOCR[index], !cached.isEmpty {
                        for line in cached.components(separatedBy: .newlines) {
                            if let depth = SmartOutlineHeadings.depth(of: line), line.count <= 120 {
                                candidates.append(.init(id: "ocr-\(index)-\(candidates.count)", title: line, unitIndex: index, depth: depth))
                            }
                        }
                    } else { missing.append(index) }
                    return
                }
                if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return }
                for line in lines where line.bounds.maxY > size.height * 0.82 {
                    runningHeads[SmartOutlineHeadings.normalized(line.text), default: []].insert(index)
                }
                let normalizedPage = SmartOutlineHeadings.normalized(text)
                let found = SmartOutlineHeadings.candidates(lines: lines, pageSize: size, emphasized: extracted.emphasized).filter {
                    !isTranslatedArticleTitle($0.title, pageText: text)
                }.sorted {
                    let a = normalizedPage.range(of: String(SmartOutlineHeadings.normalized($0.title).prefix(12)))?.lowerBound ?? normalizedPage.endIndex
                    let b = normalizedPage.range(of: String(SmartOutlineHeadings.normalized($1.title).prefix(12)))?.lowerBound ?? normalizedPage.endIndex
                    return a < b
                }
                for item in found where lines.contains(where: {
                    $0.bounds.maxY > size.height * 0.82 && SmartOutlineHeadings.normalized($0.text) == SmartOutlineHeadings.normalized(item.title)
                }) { runningCandidateIDs.insert(item.id) }
                candidates.append(contentsOf: found)
            }
        }
        let repeated = Set(runningHeads.filter { $0.value.count >= 3 }.map(\.key))
        candidates.removeAll { runningCandidateIDs.contains($0.id) && repeated.contains(SmartOutlineHeadings.normalized($0.title)) }
        return .init(candidates: candidates, unitCount: document.pageCount, missingUnits: missing)
    }

    /// Some embedded fonts emit ETX and other nonprinting separators amongst
    /// otherwise readable text. They are not missing pages. Keep replacement
    /// characters intact so genuinely broken font encodings still require OCR.
    static func cleanedOutlineText(_ text: String) -> String {
        String(text.unicodeScalars.filter {
            $0.value >= 0x20 || [9, 10, 12, 13].contains($0.value)
        })
    }

    static func isTranslatedArticleTitle(_ title: String, pageText: String) -> Bool {
        guard SmartOutlineHeadings.depth(of: title) == nil,
              title.unicodeScalars.filter({ $0.isASCII && CharacterSet.letters.contains($0) }).count > title.count / 2,
              title.range(of: #"^(Chapter|Part|Section)\b"#, options: [.regularExpression, .caseInsensitive]) == nil,
              let abstract = pageText.range(of: #"Abstract\s*[:：]"#, options: [.regularExpression, .caseInsensitive]) else { return false }
        let frontMatter = String(pageText[..<abstract.lowerBound])
        // Chinese journals often append the translated title, romanized authors and
        // abstract after the bibliography. This is not a second body section.
        guard frontMatter.range(of: #"\b[A-Z]{2,}\s+[A-Z][a-z]+"#, options: .regularExpression) != nil else { return false }
        return SmartOutlineHeadings.normalized(frontMatter).contains(String(SmartOutlineHeadings.normalized(title).prefix(12)))
    }

    private static func textLines(page: PDFPage, pageIndex: Int) -> (lines: [PDFTextLine], emphasized: Set<String>) {
        guard let attributed = page.attributedString else { return ([], []) }
        let text = attributed.string
        var lines: [PDFTextLine] = [], bold: [PDFTextLine] = []
        text.enumerateSubstrings(in: text.startIndex..., options: .byLines) { raw, range, _, _ in
            guard let raw else { return }
            let clean = cleanedOutlineText(raw)
            guard !clean.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  !TextLayerTrust.hasInvalidEncoding(clean) else { return }
            let nsRange = NSRange(range, in: text)
            guard let selection = page.selection(for: nsRange) else { return }
            // PDFKit's whole-line bounds may include the following baseline; glyph
            // range selections plus the actual font size avoid that inflated line height.
            let firstRange = NSRange(location: nsRange.location, length: 1)
            let first = page.selection(for: firstRange)?.bounds(for: page) ?? selection.bounds(for: page)
            let font = attributed.attribute(.font, at: nsRange.location, effectiveRange: nil) as? NSFont
            let size = font?.pointSize ?? first.height
            let bounds = selection.bounds(for: page)
            let line = PDFTextLine(pageIndex: pageIndex, text: clean,
                bounds: CGRect(x: first.minX, y: first.maxY - size, width: bounds.width, height: size))
            guard line.height > 0 else { return }
            lines.append(line)
            var boldCharacters = 0
            attributed.enumerateAttribute(.font, in: nsRange) { value, subrange, _ in
                if let font = value as? NSFont, font.fontDescriptor.symbolicTraits.contains(.bold) {
                    boldCharacters += subrange.length
                }
            }
            if boldCharacters * 2 >= nsRange.length { bold.append(line) }
        }
        var repaired: [PDFTextLine] = []
        for line in lines {
            if let previous = repaired.last,
               SmartOutlineHeadings.normalized(previous.text).range(of: "^[一二三四五六七八九十百0-9]+$", options: .regularExpression) != nil,
               line.text.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("、") {
                repaired[repaired.count - 1] = .init(pageIndex: pageIndex, text: previous.text + line.text,
                    bounds: CGRect(x: previous.bounds.minX, y: previous.bounds.minY,
                        width: previous.bounds.union(line.bounds).width, height: max(previous.height, line.height)))
            } else { repaired.append(line) }
        }
        let coalesced = PDFLineExtractor.coalesceFragments(repaired).map { line in
            let height = repaired.filter { line.text.contains($0.text) }.map(\.height).max() ?? line.height
            return PDFTextLine(pageIndex: pageIndex, text: line.text,
                bounds: CGRect(x: line.bounds.minX, y: line.bounds.maxY - height, width: line.bounds.width, height: height))
        }
        let emphasized = Set(coalesced.filter { line in
            bold.contains { $0.bounds.intersects(line.bounds) && $0.bounds.height >= line.height * 0.8 }
        }.map { SmartOutlineHeadings.normalized($0.text) })
        return (coalesced, emphasized)
    }
}
