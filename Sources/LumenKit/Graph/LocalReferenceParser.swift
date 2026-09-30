import Foundation

/// 从论文自身的参考文献表提取条目。这里只确认「本文列出了这条引文」，
/// 不把未核对的题录文本冒充数据库中已识别的论文。
public enum LocalReferenceParser {
    public static func parse(_ text: String, limit: Int = 20) -> [String] {
        let lines = text.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        guard let heading = lines.indices.last(where: { index in
            lines[index].range(of: #"^(参考文献|References|Bibliography)[:：]?$"#,
                               options: [.regularExpression, .caseInsensitive]) != nil
        }) else { return [] }

        var entries: [String] = []
        var current = ""
        func flush() {
            let value = current.trimmingCharacters(in: .whitespacesAndNewlines)
            if value.count >= 8 && !entries.contains(value) { entries.append(value) }
            current = ""
        }
        for line in lines.dropFirst(heading + 1) {
            if line.isEmpty { continue }
            if line.range(of: #"^(致谢|附录|作者简介|基金项目|Acknowledg(e)?ments?)[:：]?$"#,
                          options: [.regularExpression, .caseInsensitive]) != nil { break }
            if let marker = line.range(of: #"^(\[\d{1,3}\]|［\d{1,3}］|\d{1,3}[.、．])\s*"#,
                                       options: .regularExpression) {
                flush()
                current = String(line[marker.upperBound...])
            } else if !current.isEmpty && current.count < 600 {
                current += " " + line
            }
            if entries.count >= limit { break }
        }
        if entries.count < limit { flush() }
        return Array(entries.prefix(limit))
    }

    public static func doi(in citation: String) -> String? {
        let range = citation.range(of: #"10\.\d{4,9}/[-._;()/:A-Z0-9]+"#,
                                   options: [.regularExpression, .caseInsensitive])
        return GraphIdentity.normalizedDOI(range.map { String(citation[$0]) })
    }

    /// 给本地引文的人工核对提供搜索起点；原始题录始终保留。
    public static func suggestedTitle(in citation: String) -> String {
        let pattern = #"[.．。]\s*([^\[［。．]{4,200}?)\s*(?:\[[A-Za-z]\]|［[A-Za-z]］)"#
        if let range = citation.range(of: pattern, options: .regularExpression) {
            let fragment = String(citation[range])
            if let start = fragment.firstIndex(where: { ".．。".contains($0) }),
               let marker = fragment.range(of: #"\[[A-Za-z]\]|［[A-Za-z]］"#, options: .regularExpression) {
                return String(fragment[fragment.index(after: start)..<marker.lowerBound])
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        return citation
    }
}
