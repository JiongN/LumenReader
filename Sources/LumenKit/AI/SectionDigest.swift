import Foundation

public struct SectionDigest: Codable, Sendable {
    public var partID: String
    public var summary: String

    public init(partID: String, summary: String) {
        self.partID = partID; self.summary = summary
    }

    public static func validated(_ output: String, expectedID: String, tokenLimit: Int) throws -> SectionDigest {
        let value = try decoded(output, expectedID: expectedID)
        let cost = ContextBudget.estimatedTokens(value.summary)
        guard cost <= tokenLimit else {
            throw AIError.preparation("单段摘要超出本地分配预算（估算 \(cost)/\(tokenLimit) token），没有删掉其他章节。可提高设置中的模型上下文容量后重试；这不是服务商返回的 HTTP 错误。")
        }
        return value
    }

    public static func decoded(_ output: String, expectedID: String) throws -> SectionDigest {
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        let json: String
        if trimmed.hasPrefix("```"), let newline = trimmed.firstIndex(of: "\n"), let end = trimmed.range(of: "```", options: .backwards), end.lowerBound > newline {
            json = String(trimmed[trimmed.index(after: newline)..<end.lowerBound])
        } else { json = trimmed }
        guard let data = json.data(using: .utf8), data.count <= 32_000,
              let value = try? JSONDecoder().decode(SectionDigest.self, from: data) else {
            throw AIError.preparation("章节摘要 JSON 格式不合法，未将局部内容冒充全文。")
        }
        guard value.partID == expectedID, !value.summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw AIError.preparation("章节摘要丢失范围或内容（预期 \(expectedID)），未将局部内容冒充全文。")
        }
        return value
    }
}
