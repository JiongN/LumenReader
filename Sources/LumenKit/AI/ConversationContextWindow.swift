import Foundation

public struct ConversationContextWindow: Sendable {
    public var messages: [AIMessage]
    public var omittedTurns: Int
    public var includedTurns: Int { messages.count / 2 }

    /// Keep a contiguous suffix of complete turns. The transcript on disk is
    /// not shortened, and a rejected oversized turn cannot become half a pair.
    public static func select(history: [AIMessage], tokenLimit: Int, maxTurns: Int = 12) -> Self {
        var pairs: [[AIMessage]] = [], pending: AIMessage?
        for message in history {
            if message.role == .user { pending = message }
            else if message.role == .assistant, let question = pending {
                pairs.append([question, message]); pending = nil
            }
        }
        var selected: [[AIMessage]] = [], remaining = max(0, tokenLimit)
        for pair in pairs.suffix(max(0, maxTurns)).reversed() {
            let cost = pair.reduce(16) { $0 + ContextBudget.estimatedTokens($1.content) }
            guard cost <= remaining else { break }
            selected.append(pair); remaining -= cost
        }
        return .init(messages: selected.reversed().flatMap { $0 }, omittedTurns: pairs.count - selected.count)
    }
}
