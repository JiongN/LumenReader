import Testing
@testable import LumenKit

@Suite("长会话上下文窗口")
struct ConversationContextWindowTests {
    @Test func retainsRecentCompleteTurnsAndReportsOmissions() {
        let history = (0..<40).flatMap { [AIMessage.user("q\($0)"), .assistant("a\($0)")] }
        let window = ConversationContextWindow.select(history: history, tokenLimit: 1000)
        #expect(window.includedTurns == 12)
        #expect(window.omittedTurns == 28)
        #expect(window.messages.first?.content == "q28")
        #expect(window.messages.last?.content == "a39")
        #expect(history.count == 80)
    }

    @Test func neverIncludesHalfOrFailedTurnOrSkipsNewestToIncludeOlderOnes() {
        let history: [AIMessage] = [.user("old"), .assistant("old answer"), .user("new"), .assistant(String(repeating: "字", count: 100)), .user("unfinished")]
        let window = ConversationContextWindow.select(history: history, tokenLimit: 50)
        #expect(window.messages.isEmpty)
        #expect(window.omittedTurns == 2)
        let full = ConversationContextWindow.select(history: history, tokenLimit: 1000)
        #expect(full.messages.count == 4)
        #expect(full.messages.last?.role == .assistant)
    }
}
