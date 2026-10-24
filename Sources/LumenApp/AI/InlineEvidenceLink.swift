import Foundation
import LumenKit

enum InlineEvidenceLink {
    private static let marker = try? NSRegularExpression(pattern: #"\[原文\s*([0-9]*)(?:\]|$)|原文([0-9]+)"#)

    static func url(for source: DocumentCitation) -> URL? {
        guard let number = source.number, (1...32).contains(number),
              let quote = source.quote, (8...500).contains(quote.count),
              !source.path.isEmpty, !source.version.isEmpty else { return nil }
        switch source.locator {
        case .pdf(let page, _): guard page >= 0, page < Int.max else { return nil }
        case .epub(let chapter, _, _): guard chapter >= 0, chapter < Int.max else { return nil }
        }
        return URL(string: "lumen-evidence://citation/\(number)")
    }

    static func source(for url: URL, in sources: [DocumentCitation]) -> DocumentCitation? {
        sources.first { Self.url(for: $0) == url }
    }

    static func render(_ original: AttributedString, sources: [DocumentCitation]) -> AttributedString {
        let text = String(original.characters)
        guard let marker, text.contains("原文") else { return original }
        var result = original
        for match in marker.matches(in: text, range: NSRange(text.startIndex..., in: text)).reversed() {
            let bracketed = match.range(at: 1).location != NSNotFound
            guard let range = Range(match.range, in: text),
                  let numberRange = Range(match.range(at: bracketed ? 1 : 2), in: text),
                  let start = AttributedString.Index(range.lowerBound, within: result),
                  let end = AttributedString.Index(range.upperBound, within: result) else { continue }
            let target = start..<end
            // A literal marker in an inline code sample is not a document citation.
            guard !result[target].runs.contains(where: { $0.inlinePresentationIntent?.contains(.code) == true }) else { continue }
            // Markdown can consume the brackets of [原文N](url); replace that label,
            // but do not remove an ordinary prose mention of 原文N.
            guard bracketed || result[target].runs.allSatisfy({ $0.link != nil }) else { continue }
            var replacement = AttributedString("")
            if let number = Int(text[numberRange]),
               let source = sources.first(where: { $0.number == number }), let url = url(for: source) {
                switch source.locator {
                case .pdf(let page, _): replacement = AttributedString("[第 \(page + 1) 页]")
                case .epub(let chapter, _, _): replacement = AttributedString("[第 \(chapter + 1) 章]")
                }
                replacement.link = url
            }
            result.replaceSubrange(target, with: replacement)
        }
        return result
    }
}
