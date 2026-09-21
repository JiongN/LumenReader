import Testing
import Foundation
@testable import LumenApp

@Suite("会话数据完整性")
struct ConversationDecodingTests {
    @Test func missingNewFieldsRemainCompatible() throws {
        let value = try JSONDecoder().decode(Conversation.self, from: Data(#"{"title":"旧会话","bubbles":[{"text":"保留原文"}]}"#.utf8))
        #expect(value.bubbles.first?.text == "保留原文")
    }
    @Test func malformedBubbleListMustFailRatherThanBecomeEmpty() {
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(Conversation.self, from: Data(#"{"bubbles":{"text":"不可丢失"}}"#.utf8))
        }
    }
    @Test func malformedTextMustReachBackupBoundary() {
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(Conversation.self, from: Data(#"{"bubbles":[{"text":123}]}"#.utf8))
        }
    }
}
