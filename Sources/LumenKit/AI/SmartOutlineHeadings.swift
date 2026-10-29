import Foundation

/// IDs are the only model-editable part of an outline. Titles and locations stay local.
public struct SmartOutlineCandidate: Sendable, Equatable, Codable {
    public var id: String
    public var title: String
    public var unitIndex: Int
    public var depth: Int
    public var anchor: String?

    public init(id: String, title: String, unitIndex: Int, depth: Int, anchor: String? = nil) {
        self.id = id; self.title = title; self.unitIndex = unitIndex; self.depth = depth; self.anchor = anchor
    }

    public var entry: SmartOutlineEntry {
        .init(title: title, unitIndex: unitIndex, depth: depth, anchor: anchor)
    }
}

public struct SmartOutlineSource: Sendable {
    public var candidates: [SmartOutlineCandidate]
    public var unitCount: Int
    public var missingUnits: [Int]
    public init(candidates: [SmartOutlineCandidate], unitCount: Int, missingUnits: [Int] = []) {
        self.candidates = candidates; self.unitCount = unitCount; self.missingUnits = missingUnits
    }
}

public enum SmartOutlineHeadings {
    public static func normalized(_ text: String) -> String {
        text.precomposedStringWithCompatibilityMapping.filter { !$0.isWhitespace }
    }

    public static func depth(of text: String) -> Int? {
        let text = normalized(text)
        let chinese = "一二三四五六七八九十百千万零〇两"
        if text.range(of: "^第[\(chinese)0-9]+[章节篇部卷编]", options: .regularExpression) != nil { return 0 }
        if text.range(of: "^[\(chinese)]+[、.．]", options: .regularExpression) != nil { return 0 }
        if text.range(of: "^[(（][\(chinese)]+[)）]", options: .regularExpression) != nil { return 1 }
        if text.range(of: #"^\d{1,2}(?:\.\d{1,2})*(?:[、.．]|(?=[\p{Han}A-Za-z]))"#, options: .regularExpression) != nil,
           let number = text.range(of: #"^\d{1,2}(?:\.\d{1,2})*"#, options: .regularExpression) {
            return min(3, text[number].filter { $0 == "." }.count)
        }
        if ["引言", "绪论", "前言", "结语", "结论", "讨论", "参考文献", "致谢", "introduction", "conclusion", "conclusions", "references", "discussion", "methods", "results", "acknowledgments", "acknowledgements"].contains(text.trimmingCharacters(in: CharacterSet(charactersIn: ":：")).lowercased()) { return 0 }
        return nil
    }

    /// Examine the entire page, not just its opening paragraph. Geometry keeps wrapped
    /// heading continuations separate from the following body or the other column.
    public static func candidates(lines: [PDFTextLine], pageSize: CGSize, emphasized: Set<String> = []) -> [SmartOutlineCandidate] {
        let usable = lines.filter {
            $0.bounds.minY > pageSize.height * 0.045 && $0.bounds.maxY < pageSize.height * 0.95
                && !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        let bodyLines = usable.filter { normalized($0.text).count >= 16 }.map(\.height).sorted()
        let bodyHeight = bodyLines.isEmpty ? 12 : bodyLines[bodyLines.count / 2]
        var result: [SmartOutlineCandidate] = []
        for line in usable {
            var title = line.text.trimmingCharacters(in: .whitespacesAndNewlines)
            let plain = normalized(title)
            guard plain.count >= 3, plain.count <= 120,
                  plain.range(of: #"[。；;]|\.\.\.|…{2,}|[·.]{3,}\d+$"#, options: .regularExpression) == nil else { continue }
            let explicitDepth = depth(of: title)
            // An unnumbered heading needs a typographic signal. Repeated running heads
            // are removed across pages by the PDF reader before they reach the model.
            let capitals = isolatedCapitalHeading(line, among: usable, bodyHeight: bodyHeight)
            guard explicitDepth != nil || capitals || ((emphasized.contains(plain) || line.height >= bodyHeight * 1.18) && plain.count <= 80) else { continue }
            var previous = line
            for _ in 0..<3 {
                let following = usable.filter {
                    $0.bounds.maxY <= previous.bounds.minY + 2 && abs($0.bounds.minX - previous.bounds.minX) < bodyHeight * 2.8
                }.sorted { $0.bounds.maxY > $1.bounds.maxY }.first
                guard let next = following, depth(of: next.text) == nil,
                      previous.bounds.minY - next.bounds.maxY < line.height * 1.1,
                      abs(next.height - line.height) < line.height * 0.12,
                      (emphasized.contains(normalized(next.text)) || next.height >= bodyHeight * 1.08
                        || (explicitDepth != nil && (normalized(next.text).count <= 10 || next.bounds.minX < line.bounds.minX - bodyHeight)
                            && next.text.range(of: "[。；;，,：:]", options: .regularExpression) == nil)),
                      normalized(next.text).count < 60 else { break }
                title += " " + next.text.trimmingCharacters(in: .whitespacesAndNewlines)
                previous = next
            }
            // CJK extraction commonly inserts visual spaces between every glyph.
            title = title.replacingOccurrences(of: #"(?<=[\p{Han}“‘「『])\s+(?=[\p{Han}、：:，,“”「」])|(?<=[”’」』）)])\s+(?=\p{Han})|(?<=[、（(])\s+|\s+(?=[）)])"#,
                with: "", options: .regularExpression)
            if result.contains(where: { normalized($0.title).contains(plain) }) { continue }
            result.append(.init(id: "p\(line.pageIndex)-\(result.count)", title: title,
                unitIndex: line.pageIndex, depth: explicitDepth ?? 0))
        }
        return result
    }

    /// Small capitals can be *smaller* than body text, especially after OCR.
    /// Treat them as candidates only when a multiword phrase has its own line
    /// and vertical whitespace. The model still only chooses verified IDs.
    private static func isolatedCapitalHeading(_ line: PDFTextLine, among lines: [PDFTextLine], bodyHeight: CGFloat) -> Bool {
        let text = line.text.trimmingCharacters(in: .whitespacesAndNewlines)
        let letters = text.unicodeScalars.filter { CharacterSet.letters.contains($0) }
        guard text.split(whereSeparator: \.isWhitespace).count >= 2,
              (8...80).contains(letters.count),
              letters.allSatisfy({ $0.isASCII && CharacterSet.uppercaseLetters.contains($0) }),
              text.range(of: #"[.!?;:,。；：]"#, options: .regularExpression) == nil else { return false }
        let aligned = lines.filter {
            $0 != line && abs($0.bounds.minX - line.bounds.minX) < bodyHeight * 3
        }
        let above = aligned.filter { $0.bounds.minY >= line.bounds.maxY }
            .map { $0.bounds.minY - line.bounds.maxY }.min() ?? bodyHeight
        let below = aligned.filter { $0.bounds.maxY <= line.bounds.minY }
            .map { line.bounds.minY - $0.bounds.maxY }.min() ?? bodyHeight
        return above >= bodyHeight * 0.6 && below >= bodyHeight * 0.5
    }

    public static func batches(_ candidates: [SmartOutlineCandidate], tokenLimit: Int, maxCandidates: Int = 80) -> [[SmartOutlineCandidate]] {
        var result: [[SmartOutlineCandidate]] = [], current: [SmartOutlineCandidate] = [], cost = 0
        for candidate in candidates {
            let next = ContextBudget.estimatedTokens(candidate.title) + 48
            if !current.isEmpty && (cost + next > max(256, tokenLimit) || current.count >= max(1, min(80, maxCandidates))) {
                result.append(current); current = []; cost = 0
            }
            current.append(candidate); cost += next
        }
        if !current.isEmpty { result.append(current) }
        return result
    }

    public static func selectedEntries(_ raw: String, candidates: [SmartOutlineCandidate]) throws -> [SmartOutlineEntry] {
        // The provider may wrap JSON in a code fence, but may not substitute page numbers.
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let start = text.firstIndex(of: "["), let end = text.lastIndex(of: "]"), start < end else { throw SmartOutlineParser.ParseError.noJSONArray }
        struct Selection: Decodable { let id: String }
        let selected = try JSONDecoder().decode([Selection].self, from: Data(text[start...end].utf8))
        let ids = Set(selected.map(\.id))
        let known = Set(candidates.map(\.id))
        guard ids.isSubset(of: known) else { throw SmartOutlineParser.ParseError.malformed("返回了未知标题编号") }
        return candidates.filter { ids.contains($0.id) }.map(\.entry)
    }
}
