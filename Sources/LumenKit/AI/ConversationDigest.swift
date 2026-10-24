import Foundation

public struct ConversationDigest: Codable, Sendable, Equatable {
    public var prefixHash: String
    public var messageCount: Int
    public var text: String
    public init(prefixHash: String, messageCount: Int, text: String) {
        self.prefixHash = prefixHash; self.messageCount = messageCount; self.text = text
    }
    public static func hash(_ messages: [AIMessage]) -> String {
        AppPaths.stableHash(messages.map { "\($0.role.rawValue):\($0.content.utf8.count):\($0.content)" }.joined(separator: "\n"))
    }
}
