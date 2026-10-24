import Foundation

public struct DocumentSection: Codable, Sendable, Equatable {
    public var title: String
    public var startUnit: Int
    public var endUnit: Int

    public init(title: String, startUnit: Int, endUnit: Int) {
        self.title = title; self.startUnit = startUnit; self.endUnit = endUnit
    }
}

public struct WholeDocumentPart: Sendable {
    public var id: String
    public var title: String
    public var path: String
    public var version: String
    public var evidence: [DocumentEvidence]
    public var text: String {
        evidence.map { "【\($0.label) · \($0.id)】\n\($0.text)" }.joined(separator: "\n\n")
    }
    public var header: String {
        "【\(id) · \(URL(fileURLWithPath: path).lastPathComponent) · \(title) · \(evidence.first?.label ?? "")–\(evidence.last?.label ?? "")】"
    }
}

public enum WholeDocumentPlan {
    public static func isPageBookmarkList(_ sections: [DocumentSection], unitCount: Int) -> Bool {
        guard sections.count >= max(48, unitCount * 2 / 3) else { return false }
        let numeric = sections.filter {
            $0.endUnit - $0.startUnit <= 1 && $0.title.trimmingCharacters(in: .whitespacesAndNewlines)
                .range(of: "^(第\\s*)?[0-9]+\\s*(页|[pP])?$", options: .regularExpression) != nil
        }.count
        return numeric > sections.count * 2 / 3
    }

    public static func parts(_ documents: [DocumentContext]) -> [WholeDocumentPart] {
        var result: [WholeDocumentPart] = []
        for (docIndex, document) in documents.enumerated() {
            let byUnit = Dictionary(grouping: document.evidence.filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) {
                $0.locator.pageIndex >= 0 ? $0.locator.pageIndex : $0.locator.chapterIndex
            }
            let sourceSections = isPageBookmarkList(document.sections, unitCount: document.unitCount) ? [] : document.sections
            let boundaries = sourceSections.filter {
                $0.startUnit >= 0 && $0.endUnit >= $0.startUnit && $0.endUnit < document.unitCount
            }.sorted { $0.startUnit < $1.startUnit }
            var assigned = Set<Int>()
            var groups: [(String, [Int])] = []
            for section in boundaries {
                let units = (section.startUnit...section.endUnit).filter { byUnit[$0] != nil && !assigned.contains($0) }
                if !units.isEmpty { groups.append((section.title, units)); assigned.formUnion(units) }
            }
            let rest = byUnit.keys.filter { !assigned.contains($0) }.sorted()
            // No PDF outline: retain explicit page bands, never invent chapter titles.
            let width = max(1, (rest.count + 23) / 24)
            for start in stride(from: 0, to: rest.count, by: width) {
                let units = Array(rest[start..<min(start + width, rest.count)])
                groups.append((boundaries.isEmpty ? "页/章段 \(groups.count + 1)" : "其他材料", units))
            }
            groups.sort { ($0.1.first ?? 0) < ($1.1.first ?? 0) }
            for (index, group) in groups.enumerated() {
                result.append(.init(id: "D\(docIndex + 1)S\(index + 1)", title: group.0,
                    path: document.path, version: document.version,
                    evidence: group.1.flatMap { byUnit[$0] ?? [] }))
            }
        }
        return result
    }

    public static func instruction(parts: [WholeDocumentPart]) -> String {
        """
        全文范围清单（程序按原文建立，不是模型推测）：
        \(parts.map(\.header).joined(separator: "\n"))
        以上每段必须在材料中保留，不得把局部摘要称作全书。
        若问题要求全书概览、总结、导图或跨章综合，先依此清单组织全书，再说明章节间关系；不要只扩写某一章或某个案例。导图顶层按主要章节/部分分支。
        若问题只涉及局部，可以聚焦相关内容，但须基于全书判断，不必逐章列举。缺失的原文明确说明，不编造。历史回答不是本轮原文，不得覆盖本轮范围。
        """
    }
}
