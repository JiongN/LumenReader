import Foundation
import Testing
@testable import LumenApp

@Suite("后台会话保存", .serialized)
@MainActor
struct ConversationPersistenceTests {
    @Test func rapidUpdatesKeepNewestSnapshotAndReadBarrier() {
        let store = ConversationStore()
        let id = store.createConversation(sourcePath: nil, sourceTitle: "Persistence test")
        for index in 0..<100 {
            store.rename(id: id, "Revision \(index)")
        }
        let restored = ConversationStore()
        #expect(restored.conversations.first(where: { $0.id == id })?.customTitle == "Revision 99")
        store.delete(id: id)
        store.persist(wait: true)
    }

    @Test func explicitFlushPreservesLargeBubbles() {
        let store = ConversationStore()
        let id = store.createConversation(sourcePath: nil, sourceTitle: "Snapshot test")
        let text = String(repeating: "Large conversation evidence. ", count: 10_000)
        store.replaceContent(id: id, bubbles: [.init(role: .user, text: text)], history: [])
        store.persist(wait: true)
        let restored = ConversationStore()
        #expect(restored.conversations.first(where: { $0.id == id })?.bubbles.first?.text == text)
        store.delete(id: id)
        store.persist(wait: true)
    }
}
