import Foundation

public enum WholeAnswerCoverage {
    private struct Report: Codable { var sections: [String] }

    public static func requiresReview(task: AITask, mindMap: Bool) -> Bool {
        switch task {
        case .summarize(.wholeDocument): return true
        case .ask(let question), .custom(let question):
            let text = question.lowercased()
            let local = ["当前页", "当前章", "这一段", "this page", "this chapter"].contains { text.contains($0) }
            if local { return false }
            // Full-document evidence is not an instruction to discuss every chapter.
            let overview = ["概览", "核心论点", "核心观点", "思维导图", "overview", "mind map"].contains { text.contains($0) }
            let summary = ["总结", "概括", "summarize", "summary"].contains { text.contains($0) }
            let global = ["全书", "全文", "整本", "整体", "全局", "这本书", "这篇论文", "whole", "entire", "the book", "the paper"].contains { text.contains($0) }
            return mindMap || overview || (summary && global)
        default: return false
        }
    }

    public static func instruction(ids: [String]) -> String {
        """
        Review every listed section for whole-document answers. Disclose incomplete coverage.
        Section IDs are private protocol metadata. Never print them in prose, headings or citations; use human-readable section titles instead.
        Append: <!-- lumen-coverage: {"sections":\(String(data: try! JSONEncoder().encode(ids), encoding: .utf8)!)} -->
        For whole-book mind maps, add coveredSections to actual main branches; their union must cover this list. That replaces the footer. Never claim whole-book coverage for a single-chapter map.
        """
    }

    public static func validatedAnswer(_ text: String, ids: [String], mindMap: Bool) throws -> String {
        let marker = "<!-- lumen-coverage:"
        let answer: String
        if let start = text.range(of: marker, options: .backwards) {
            guard let end = text[start.upperBound...].range(of: "-->"),
                  text[end.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  let data = String(text[start.upperBound..<end.lowerBound]).data(using: .utf8), data.count <= 16_000,
                  let report = try? JSONDecoder().decode(Report.self, from: data),
                  Set(report.sections) == Set(ids) else { throw failure }
            answer = String(text[..<start.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
        } else {
            guard mindMap else { throw failure }
            answer = text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard !answer.isEmpty else { throw failure }
        if mindMap {
            guard let map = MindMapResult.parse(answer) else { throw failure }
            // Claims must be attached to actual branches, not just a global footer.
            var covered = Set<String>()
            func visit(_ node: MindMapNode) {
                covered.formUnion(node.coveredSections)
                node.children.forEach(visit)
            }
            map.root.children.forEach(visit)
            guard covered == Set(ids) else { throw failure }
        }
        return answer
    }

    /// Hide protocol metadata even for interrupted or invalid responses.
    public static func visibleAnswer(_ text: String) -> String {
        let text = AnswerEvidence.visibleAnswer(text)
        let marker = "<!-- lumen-coverage:"
        guard text.contains(marker) else { return hideSectionAnnotations(text) }
        var answer = text
        while let start = answer.range(of: marker) {
            if let end = answer[start.upperBound...].range(of: "-->") {
                answer.removeSubrange(start.lowerBound..<end.upperBound)
            } else {
                answer.removeSubrange(start.lowerBound..<answer.endIndex)
            }
        }
        while let last = answer.last, last.isWhitespace { answer.removeLast() }
        return hideSectionAnnotations(answer)
    }

    private static let sectionAnnotation = try? NSRegularExpression(pattern:
        #"[（(【\[]\s*D[1-9]\d*S[1-9]\d*(?:F[1-9]\d*)?(?:\s*[,，;；、]\s*D[1-9]\d*S[1-9]\d*(?:F[1-9]\d*)?)*\s*[）)】\]]"#)
    private static let partialSectionAnnotation = try? NSRegularExpression(pattern: #"[（(【\[]\s*D\d+(?:S\d*(?:F\d*)?)?$"#)
    private static let bareSectionID = try? NSRegularExpression(pattern: #"(?<![A-Za-z0-9_])D[1-9]\d*S[1-9]\d*(?:F[1-9]\d*)?(?![A-Za-z0-9_])"#)
    private static let inlineCode = try? NSRegularExpression(pattern: #"(`+)([^`]+)\1"#)

    private static func hideSectionAnnotations(_ source: String) -> String {
        guard source.contains("D") else { return source }
        var fenced = false
        return source.components(separatedBy: "\n").map { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") { fenced.toggle(); return line }
            guard !fenced, !line.hasPrefix("    "), !line.hasPrefix("\t") else { return line }
            func clean(_ text: String) -> String {
                var result = text
                for pattern in [sectionAnnotation, partialSectionAnnotation, bareSectionID].compactMap({ $0 }) {
                    result = pattern.stringByReplacingMatches(in: result, range: NSRange(result.startIndex..., in: result), withTemplate: "")
                }
                return result
            }
            var result = "", cursor = line.startIndex
            for match in inlineCode?.matches(in: line, range: NSRange(line.startIndex..., in: line)) ?? [] {
                guard let span = Range(match.range, in: line), let content = Range(match.range(at: 2), in: line) else { continue }
                result += clean(String(line[cursor..<span.lowerBound]))
                let literal = String(line[content])
                // Standalone protocol labels are not code, but genuine code examples stay intact.
                if !clean(literal).trimmingCharacters(in: .whitespaces).isEmpty { result += line[span] }
                cursor = span.upperBound
            }
            return result + clean(String(line[cursor...]))
        }.joined(separator: "\n")
    }

    private static var failure: AIError {
        .answerValidation("全书回答的范围声明不完整或格式错误，暂不能确认覆盖全部章节。已保留正文，但不进入后续对话；请重新生成。这是本地校验结果，不是服务端错误，也不代表已确认正文遗漏。")
    }
}
