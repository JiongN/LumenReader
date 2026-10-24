import Foundation

/// Local bibliographic fields are search hints, not verified database identities.
public enum LocalReferenceParser {
    public struct Entry: Sendable, Equatable {
        public var original: String
        public var citation: String
        public var numbers: [Int]
        public var title: String
        public var authors: [String]
        public var year: Int?
        public var venue: String
        public var doi: String?
    }

    private static let numbered = #"^(?:(?:[\[［]\s*\d{1,3}\s*[\]］]\s*)+|\d{1,3}[.、．]\s*)"#
    private static let documentType = #"[\[［]\s*(?:EB|DB|CP|[JMNCDRSZAG])\s*(?:/\s*(?:OL|CD|DK|MT))?\s*[\]］]"#

    public static func isHeading(_ line: String) -> Bool {
        let compact = line.replacingOccurrences(of: #"\s+"#, with: "", options: .regularExpression)
        return compact.range(of: #"^(?:参考文献|主要参考文献|References|Bibliography)(?:\(References\)|（References）)?[:：]?$"#,
                             options: [.regularExpression, .caseInsensitive]) != nil
    }

    public static func parse(_ text: String, limit: Int = 149) -> [String] {
        entries(in: text, limit: limit).map(\.citation)
    }

    public static func entries(in text: String, limit: Int = 149) -> [Entry] {
        guard limit > 0 else { return [] }
        let lines = text.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        guard let heading = lines.firstIndex(where: isHeading) else { return [] }
        var entries: [Entry] = []
        var current = ""
        func flush() {
            let entry = details(in: current)
            if entry.citation.count >= 8, !entries.contains(where: { $0.citation == entry.citation }) {
                entries.append(entry)
            }
            current = ""
        }
        for line in lines.dropFirst(heading + 1) {
            if line.count > 4_096 { current = ""; continue }
            if line.isEmpty || isHeading(line) { continue }
            if line.range(of: #"^(?:致谢|附录|作者简介|基金项目|责任编辑|Acknowledg(?:e)?ments?|Abstract|Key\s*words)\s*[:：]?"#,
                          options: [.regularExpression, .caseInsensitive]) != nil { break }
            if line.range(of: numbered, options: .regularExpression) != nil {
                // Several numbers can wrap onto the next line before their shared citation.
                if !details(in: current).citation.isEmpty { flush() }
                if entries.count >= limit { break }
                current += (current.isEmpty ? "" : " ") + line
            } else if !current.isEmpty {
                if line.range(of: #"^\d{1,4}$"#, options: .regularExpression) != nil { continue }
                let complete = current.range(of: documentType, options: .regularExpression) != nil
                    && details(in: current).year != nil
                    && current.range(of: #"[.。．]\s*$"#, options: .regularExpression) != nil
                if complete && line.range(of: #"^(?:doi\s*:|https?://(?:dx\.)?doi\.org/)"#,
                                          options: [.regularExpression, .caseInsensitive]) == nil {
                    flush()
                } else if current.count + line.count <= 4_096 {
                    current += "\n" + line
                } else {
                    // Do not turn a truncated or unbounded fragment into an apparent citation.
                    current = ""
                }
            }
        }
        if entries.count < limit { flush() }
        return Array(entries.prefix(limit))
    }

    public static func details(in citation: String) -> Entry {
        let original = citation.trimmingCharacters(in: .whitespacesAndNewlines)
        let prefix = original.range(of: numbered, options: .regularExpression)
        let labels = prefix.map { String(original[$0]) } ?? ""
        let numbers = labels.components(separatedBy: CharacterSet.decimalDigits.inverted).compactMap(Int.init)
        let body = prefix.map { String(original[$0.upperBound...]) } ?? original
        let normalized = normalize(body)
        let typeRange = normalized.range(of: documentType, options: [.regularExpression, .caseInsensitive])
        var title = normalized, authors: [String] = [], venue = ""
        let tail = typeRange.map { String(normalized[$0.upperBound...]) } ?? normalized
        // Publication years are searched after the type marker, never in a title or DOI.
        let publication = tail.replacingOccurrences(of: #"(?i)(?:https?://\S+|(?:doi\s*:\s*)?10\.\d{4,9}/\S+)"#,
                                                    with: "", options: .regularExpression)
        let yearRange = publication.range(of: #"(?<!\d)(?:1[5-9]\d{2}|20\d{2}|2100)(?!\d)"#, options: .regularExpression)
        let year = yearRange.flatMap { Int(publication[$0]) }
        if let typeRange {
            let head = String(normalized[..<typeRange.lowerBound])
            if let separator = head.range(of: #"[.．。]\s*"#, options: .regularExpression) {
                let names = String(head[..<separator.lowerBound])
                let candidate = String(head[separator.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
                if !candidate.isEmpty, names.count <= 160 {
                    title = candidate
                    authors = names.components(separatedBy: CharacterSet(charactersIn: ",，、;；"))
                        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
                }
            }
            if let yearRange {
                var source = String(publication[..<yearRange.lowerBound])
                    .trimmingCharacters(in: CharacterSet(charactersIn: " .．。,，;；:"))
                let type = String(normalized[typeRange]).uppercased()
                if type.contains("M"), let colon = source.range(of: #"[:：]"#, options: .regularExpression) {
                    source = String(source[colon.upperBound...])
                }
                venue = source.trimmingCharacters(in: CharacterSet(charactersIn: " .．。,，;；:"))
            }
        }
        return Entry(original: original, citation: normalized, numbers: numbers, title: title,
                     authors: authors, year: year, venue: venue, doi: doi(in: normalized))
    }

    public static func doi(in citation: String) -> String? {
        let range = citation.range(of: #"10\.\d{4,9}/[-._;()/:A-Z0-9]+"#,
                                   options: [.regularExpression, .caseInsensitive])
        return GraphIdentity.normalizedDOI(range.map { String(citation[$0]) })
    }

    public static func suggestedTitle(in citation: String) -> String { details(in: citation).title }

    private static func normalize(_ text: String) -> String {
        text.replacingOccurrences(of: #"([A-Za-z])-\s*\n\s*([a-z])"#, with: "$1$2", options: .regularExpression)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"(?:—\s*){2,}"#, with: "——", options: .regularExpression)
            .replacingOccurrences(of: #"(?<=\p{Han}) +(?=\p{Han})"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"[\[［]\s*((?:EB|DB|CP|[JMNCDRSZAG])(?:\s*/\s*(?:OL|CD|DK|MT))?)\s*[\]］]"#,
                                  with: "[$1]", options: [.regularExpression, .caseInsensitive])
            .replacingOccurrences(of: #"(?<=[“‘]) +| +(?=[”’])"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
