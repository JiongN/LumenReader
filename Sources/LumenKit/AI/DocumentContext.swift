import Foundation

public struct DocumentExtractionProgress: Sendable {
    public var completed: Int
    public var total: Int
    public var recognizing: Bool
    public var phase: String?
    public init(completed: Int, total: Int, recognizing: Bool, phase: String? = nil) {
        self.completed = completed; self.total = total; self.recognizing = recognizing
        self.phase = phase
    }
}

public struct DocumentEvidence: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var path: String
    public var label: String
    public var locator: DocumentLocator
    public var text: String
    public var pdfFragments: [PDFParagraphFragment]?
    public var citationID: String { AppPaths.stableHash(path) + ":" + id }

    public init(id: String, path: String, label: String, locator: DocumentLocator, text: String,
                pdfFragments: [PDFParagraphFragment]? = nil) {
        self.id = id; self.path = path; self.label = label; self.locator = locator; self.text = text
        self.pdfFragments = pdfFragments
    }
}

public struct DocumentContext: Codable, Sendable, Equatable {
    public var version: String
    public var path: String
    public var evidence: [DocumentEvidence]
    public var missingUnits: [Int]
    public var unitCount: Int
    public var sections: [DocumentSection]
    public var extractionNote: String?
    public var blocks: [DocumentBlock] = []

    public init(version: String, path: String, evidence: [DocumentEvidence], missingUnits: [Int] = [], unitCount: Int, sections: [DocumentSection] = []) {
        self.version = version; self.path = path; self.evidence = evidence
        self.missingUnits = missingUnits; self.unitCount = unitCount
        self.sections = sections
        blocks = evidence.enumerated().map { offset, item in
            let kind: DocumentBlock.Kind = item.label.localizedCaseInsensitiveContains("table") || item.label.localizedCaseInsensitiveContains("表格")
                ? .table : .paragraph
            return .init(id: item.id, kind: kind, pageIndex: item.locator.pageIndex, order: offset,
                text: "", parser: "native")
        }
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decode(String.self, forKey: .version)
        path = try c.decode(String.self, forKey: .path)
        evidence = try c.decode([DocumentEvidence].self, forKey: .evidence)
        missingUnits = try c.decodeIfPresent([Int].self, forKey: .missingUnits) ?? []
        unitCount = try c.decode(Int.self, forKey: .unitCount)
        sections = try c.decodeIfPresent([DocumentSection].self, forKey: .sections) ?? []
        extractionNote = try c.decodeIfPresent(String.self, forKey: .extractionNote)
        blocks = try c.decodeIfPresent([DocumentBlock].self, forKey: .blocks) ?? []
    }

    public var text: String {
        evidence.map { "【\($0.label) · 原文ID=\($0.citationID)】\n\($0.text)" }.joined(separator: "\n\n")
    }

    public var coverage: String {
        let range = missingUnits.isEmpty ? "全文 · \(unitCount) 页/章" : "部分全文 · \(missingUnits.count) 页/章未取得文字"
        return extractionNote.map { range + " · " + $0 } ?? range
    }
}

public enum ContextBudget {
    /// Conservative estimate for mixed academic text; actual usage comes from the provider.
    public static func estimatedTokens(_ text: String) -> Int {
        var ascii = 0, other = 0
        for scalar in text.unicodeScalars {
            if scalar.isASCII { ascii += 1 } else { other += 1 }
        }
        return (ascii + 2) / 3 + other * 2
    }

    public static func inputLimit(_ config: AIProviderConfig) -> Int {
        let capacity = min(config.contextWindow, config.publishedContextWindow ?? config.contextWindow)
        return max(512, capacity - config.maxTokens - max(1024, capacity / 10))
    }

    public static func chunks(_ text: String, tokenLimit: Int) -> [String] {
        var chunks: [String] = [], current = "", tokens = 0
        // Linear traversal also bounds huge single-line EPUB paragraphs.
        let limit = max(1, tokenLimit) * 3
        for character in text {
            let cost = character.unicodeScalars.reduce(0) { $0 + ($1.isASCII ? 1 : 6) }
            if tokens + cost > limit, !current.isEmpty {
                chunks.append(current); current = ""; tokens = 0
            }
            current.append(character); tokens += cost
        }
        if !current.isEmpty { chunks.append(current) }
        return chunks
    }
}
