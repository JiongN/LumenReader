import Foundation
import NaturalLanguage
import PDFKit

/// Resolve from connected prose once, not from each short heading/table cell.
/// Private PDF access and language recognition stay off the reading thread.
actor TranslationSourceResolver {
    static let shared = TranslationSourceResolver()

    func resolve(texts: [String], pdfPath: String? = nil, pageIndex: Int? = nil) throws -> String? {
        try Task.checkCancellation()
        if let language = Self.proseLanguage(texts) { return language }
        if let pdfPath, let pageIndex {
            let language: String? = autoreleasepool {
                guard let document = PDFDocument(url: URL(fileURLWithPath: pdfPath)) else { return nil }
                // Selection mode never needs a whole-book extraction just to identify a word.
                let indices = [pageIndex, pageIndex + 1, pageIndex - 1].filter { $0 >= 0 && $0 < document.pageCount }
                for index in indices {
                    if let text = document.page(at: index)?.string,
                       let language = Self.proseLanguage([String(text.prefix(6000))]) { return language }
                }
                return nil
            }
            if let language { return language }
        }
        return Self.detect(String(texts.prefix(8).joined(separator: "\n").prefix(1000)), minimumLetters: 2, threshold: 0.85)
    }

    private static func proseLanguage(_ texts: [String]) -> String? {
        // NL hypotheses are not reliable for a large concatenation of unrelated
        // PDF metadata/prose. Vote on bounded, substantial paragraphs instead.
        let samples = texts.prefix(80).map { String($0.prefix(1000)) }
            .filter { $0.filter(\.isLetter).count >= 24 }
            .sorted { $0.count > $1.count }.prefix(8)
        var votes: [String: Int] = [:]
        var total = 0
        for sample in samples {
            let weight = sample.filter(\.isLetter).count
            total += weight
            if let language = detect(sample, minimumLetters: 24) { votes[language, default: 0] += weight }
        }
        let ranked = votes.sorted { $0.value > $1.value }
        guard total > 0, let best = ranked.first,
              Double(best.value) / Double(total) >= 0.6,
              Double(best.value - (ranked.dropFirst().first?.value ?? 0)) / Double(total) >= 0.2 else { return nil }
        return best.key
    }

    private static func detect(_ text: String, minimumLetters: Int, threshold: Double = 0.6) -> String? {
        guard text.filter(\.isLetter).count >= minimumLetters else { return nil }
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(text)
        let hypotheses = recognizer.languageHypotheses(withMaximum: 2).sorted { $0.value > $1.value }
        guard let best = hypotheses.first, best.key != .undetermined, best.value >= threshold,
              best.value - (hypotheses.dropFirst().first?.value ?? 0) >= 0.2 else { return nil }
        return best.key.rawValue
    }
}
