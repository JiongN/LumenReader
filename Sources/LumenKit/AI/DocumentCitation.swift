import Foundation

public struct DocumentCitation: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var path: String
    public var version: String
    public var label: String
    public var locator: DocumentLocator
    public var quote: String?
    public var number: Int?
    public var pdfFragments: [PDFParagraphFragment]?

    public init(evidence: DocumentEvidence, version: String) {
        id = evidence.id; path = evidence.path; self.version = version
        label = evidence.label; locator = evidence.locator
        pdfFragments = evidence.pdfFragments
    }
}

/// Only exact quotations from material sent in this request become navigation targets.
public enum AnswerEvidence {
    private struct Report: Decodable { var citations: [Reference] }
    private struct Reference: Decodable { var number: Int; var id: String; var quote: String }
    public static let marker = "<!-- lumen-evidence:"
    public static let instruction = """
    Ground document-related claims with [原文N]. Append:
    <!-- lumen-evidence: {"citations":[{"number":1,"id":"原文ID","quote":"verbatim 8–500-char excerpt"}]} -->
    Copy paragraph 原文ID, never D1S/section headers. Quote one supplied original, not summaries or added headings. Unavailable: empty citations, no invention. Footer outside code/maps and before lumen-coverage.
    """

    public static func resolve(_ text: String, documents: [DocumentContext],
                               supplied: [DocumentEvidence]) -> (answer: String, citations: [DocumentCitation]) {
        guard let start = text.range(of: marker) else { return (text, []) }
        let answer = visibleAnswer(text)
        guard let end = text[start.upperBound...].range(of: "-->"),
              let data = String(text[start.upperBound..<end.lowerBound]).data(using: .utf8), data.count <= 40_000,
              let report = try? JSONDecoder().decode(Report.self, from: data) else { return (answer, []) }
        let catalog = Dictionary(supplied.map { ($0.citationID, $0) }, uniquingKeysWith: { first, _ in first })
        let parts = WholeDocumentPlan.parts(documents)
        let scopes = Dictionary(parts.flatMap { part in
            [(part.id, part.evidence), (String(part.header.dropFirst().dropLast()), part.evidence)]
        }, uniquingKeysWith: { first, _ in first })
        var seen = Set<Int>(), citations: [DocumentCitation] = []
        for ref in report.citations.prefix(32) {
            guard (1...32).contains(ref.number), !seen.contains(ref.number),
                  answer.contains("[原文\(ref.number)]"), (8...500).contains(ref.quote.count) else { continue }
            let quote = normalized(ref.quote)
            guard quote.count >= 8 else { continue }
            let referenceID = ref.id.hasPrefix("COPY ") ? String(ref.id.dropFirst(5)) : ref.id
            let source: DocumentEvidence?
            if let exact = catalog[referenceID] {
                source = normalized(exact.text).contains(quote) ? exact : nil
            } else if let section = scopes[referenceID] {
                // Some providers return a supplied section header as the ID.
                // Recover only a unique quote from originals actually sent.
                let matches = section.lazy.compactMap { catalog[$0.citationID] }
                    .filter { normalized($0.text).contains(quote) }.prefix(2)
                source = matches.count == 1 ? matches.first : nil
            } else { source = nil }
            guard let source,
                  let document = documents.first(where: { $0.path == source.path }) else { continue }
            var citation = DocumentCitation(evidence: source, version: document.version)
            citation.quote = ref.quote; citation.number = ref.number
            citations.append(citation); seen.insert(ref.number)
        }
        return (answer, citations)
    }

    public static func visibleAnswer(_ text: String) -> String {
        guard text.contains(marker) else { return text }
        var answer = text
        while let start = answer.range(of: marker) {
            let end = answer[start.upperBound...].range(of: "-->")?.upperBound ?? answer.endIndex
            answer.removeSubrange(start.lowerBound..<end)
        }
        return answer.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func normalized(_ text: String) -> String {
        text.replacingOccurrences(of: "\u{00AD}", with: "")
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
}
