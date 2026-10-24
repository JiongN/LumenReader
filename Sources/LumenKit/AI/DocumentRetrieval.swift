import Foundation
import NaturalLanguage

/// Immutable per-request lexical index. Coordinates and identities always belong
/// to the source block; excerpts never acquire an invented locator.
public struct DocumentRetrieval: Sendable {
    public struct Hit: Sendable {
        public var evidence: DocumentEvidence
        public var score: Double
        public init(evidence: DocumentEvidence, score: Double) { self.evidence = evidence; self.score = score }
    }
    private let evidence: [DocumentEvidence]
    private let tokens: [[String]]
    private let frequency: [String: Int]
    private let averageLength: Double

    public init(_ evidence: [DocumentEvidence]) {
        self.evidence = evidence
        tokens = evidence.map { Self.terms($0.label + " " + $0.text) }
        var frequency: [String: Int] = [:]
        for words in tokens { for term in Set(words) { frequency[term, default: 0] += 1 } }
        self.frequency = frequency
        averageLength = max(1, Double(tokens.reduce(0) { $0 + $1.count }) / Double(max(1, tokens.count)))
    }

    public static func terms(_ text: String) -> [String] {
        let value = text.lowercased()
        let tokenizer = NLTokenizer(unit: .word)
        tokenizer.string = value
        var result: [String] = []
        let ignored: Set<String> = ["the", "and", "of", "to", "in", "is", "are", "this", "that", "what", "how", "please", "全文", "全书", "总结", "解释", "请"]
        tokenizer.enumerateTokens(in: value.startIndex..<value.endIndex) { range, _ in
            let word = String(value[range])
            if !ignored.contains(word), word.unicodeScalars.contains(where: CharacterSet.alphanumerics.contains) {
                result.append(word)
            }
            return true
        }
        return result
    }

    public func search(_ query: String, limit: Int = 32) -> [Hit] {
        let terms = Set(Self.terms(query))
        var hits: [Hit] = []
        for index in evidence.indices {
            let counts = Dictionary(tokens[index].map { ($0, 1) }, uniquingKeysWith: +)
            let length = Double(tokens[index].count)
            let score = terms.reduce(0.0) { sum, term in
                let count = Double(counts[term] ?? 0)
                guard count > 0 else { return sum }
                let df = Double(frequency[term] ?? 0)
                let idf = log(1 + (Double(evidence.count) - df + 0.5) / (df + 0.5))
                return sum + idf * count * 2.2 / (count + 1.2 * (0.25 + 0.75 * length / averageLength))
            }
            if score > 0 { hits.append(.init(evidence: evidence[index], score: score)) }
        }
        return Array(hits.sorted { $0.score == $1.score ? $0.evidence.citationID < $1.evidence.citationID : $0.score > $1.score }.prefix(max(0, limit)))
    }

    /// Sentence-aware windows centered on matches, including matches near the end.
    public static func excerpt(_ source: DocumentEvidence, query: String, tokenLimit: Int) -> DocumentEvidence {
        guard ContextBudget.estimatedTokens(source.text) > tokenLimit else { return source }
        let tokenizer = NLTokenizer(unit: .sentence)
        tokenizer.string = source.text
        var sentences: [String] = []
        tokenizer.enumerateTokens(in: source.text.startIndex..<source.text.endIndex) { range, _ in
            sentences.append(String(source.text[range])); return true
        }
        let terms = Set(Self.terms(query))
        let scores = sentences.map { Set(Self.terms($0)).intersection(terms).count }
        let best = scores.indices.max { scores[$0] < scores[$1] } ?? 0
        var result = source
        if let sentence = sentences.indices.contains(best) ? sentences[best] : nil,
           ContextBudget.estimatedTokens(sentence) <= tokenLimit {
            var start = best, end = best
            while start > 0 || end + 1 < sentences.count {
                let nextStart = max(0, start - 1), nextEnd = min(sentences.count - 1, end + 1)
                let text = sentences[nextStart...nextEnd].joined()
                guard ContextBudget.estimatedTokens(text) <= tokenLimit else { break }
                start = nextStart; end = nextEnd
            }
            result.text = sentences[start...end].joined()
        } else {
            // A malformed PDF may have one very long sentence. Split once and
            // choose the matching chunk, rather than always choosing its prefix.
            let chunks = ContextBudget.chunks(source.text, tokenLimit: max(32, tokenLimit))
            result.text = chunks.max {
                Set(Self.terms($0)).intersection(terms).count < Set(Self.terms($1)).intersection(terms).count
            } ?? ""
        }
        return result
    }

    public func neighbors(of source: DocumentEvidence) -> [DocumentEvidence] {
        guard let index = evidence.firstIndex(where: { $0.citationID == source.citationID }) else { return [] }
        return [index - 1, index + 1].compactMap { candidate in
            guard evidence.indices.contains(candidate), evidence[candidate].path == source.path else { return nil }
            return evidence[candidate]
        }
    }
}
