import AppKit
import Testing
import LumenKit
@testable import LumenApp

@Suite("生成期间阅读回归", .serialized)
@MainActor
struct AIStreamingRegressionTests {
    @Test func documentTabAndHomeChangesKeepGlobalAnswerAlive() {
        let settings = SettingsStore(fileURL: FileManager.default.temporaryDirectory.appendingPathComponent("stream-tabs-\(UUID()).json"))
        settings.suppressSave = true
        let services = AppServices(settingsStore: settings)
        let state = AppState(services: services)
        let first = ReaderSession(document: OpenDocument(url: URL(fileURLWithPath: "/tmp/stream-first.pdf"), kind: .pdf))
        let second = ReaderSession(document: OpenDocument(url: URL(fileURLWithPath: "/tmp/stream-second.pdf"), kind: .pdf))
        state.add(first)
        let chat = services.activeChat
        chat.newConversation(sourcePath: first.document.id, sourceTitle: "First")
        chat.beginFakeStream()
        let answer = chat.streamingID
        chat.appendFakeDelta("开始回答。\n\n")
        state.add(second)
        #expect(chat.isStreaming)
        #expect(chat.streamingID == answer)
        state.activate(first)
        state.addHomeTab()
        #expect(chat.isStreaming)
        state.activate(second)
        chat.appendFakeDelta("切换标签后继续回答。")
        chat.endFakeStream()
        #expect(chat.bubbles.last?.text == "开始回答。\n\n切换标签后继续回答。")
        #expect(chat.store.activeConversation?.sourceDocPath == first.document.id)
        first.close(); second.close()
    }

    @Test func completedStreamingParagraphsStayStableWithoutLosingText() {
        _ = NSApplication.shared
        let text = "中文与 English 保持原句。\n\n第二段\n换行仍保留。\n\n"
        let view = AnswerTextView()
        func update(_ value: String) {
            view.update(text: value, blocks: nil, fontSize: 15, textColor: .textColor, accent: .linkColor, evidence: [])
        }
        update(text)
        view.setSelectedRange(.init(location: 0, length: 2))
        let storage = view.textStorage
        update(text + "第三段继续生成")
        #expect(view.textStorage === storage)
        #expect(view.selectedRange() == .init(location: 0, length: 2))
        #expect(view.string == text + "第三段继续生成")
    }

    @Test func previousCompletedAnswerRemainsUnchangedThroughoutNextStream() {
        let store = ConversationStore()
        let chat = AIChatModel(store: store)
        chat.newConversation(sourcePath: nil, sourceTitle: "History stream regression")
        chat.seedDemoAnswer()
        let completed = chat.bubbles
        chat.beginFakeStream()
        chat.appendFakeDelta("新一轮回答开始。")
        #expect(Array(chat.bubbles.dropLast()) == completed)
        #expect(chat.streamingID != completed.last?.id)
        chat.appendFakeDelta("继续生成，不改变上一轮的表格与原文。")
        #expect(Array(chat.bubbles.dropLast()) == completed)
        chat.endFakeStream()
        #expect(Array(chat.bubbles.dropLast()) == completed)
    }

    @Test func settledBubbleEqualityIncludesEvidenceFailureAndUsage() {
        let original = AIChatModel.Bubble(role: .assistant, text: "answer")
        var changed = original
        changed.failed = true
        #expect(changed != original)
        changed = original; changed.coverage = "完整原文"
        #expect(changed != original)
        changed = original; changed.usage = .init(input: 10, output: 2)
        #expect(changed != original)
    }
}
