import AppKit
import Testing
@testable import LumenApp

@Suite("译文点击与选择", .serialized)
@MainActor
struct TranslationTextTests {
    @Test func onlyAnUnmodifiedSingleClickWithoutSelectionNavigates() {
        #expect(TranslationTextView.isNavigationClick(clickCount: 1, selectedLength: 0, distance: 0, modifiers: []))
        #expect(!TranslationTextView.isNavigationClick(clickCount: 2, selectedLength: 0, distance: 0, modifiers: []))
        #expect(!TranslationTextView.isNavigationClick(clickCount: 1, selectedLength: 4, distance: 1, modifiers: []))
        #expect(!TranslationTextView.isNavigationClick(clickCount: 1, selectedLength: 0, distance: 10, modifiers: []))
        #expect(!TranslationTextView.isNavigationClick(clickCount: 1, selectedLength: 0, distance: 0, modifiers: .shift))
    }

    @Test func longTranslationResizesWithoutLosingSelection() {
        _ = NSApplication.shared
        let view = TranslationTextView()
        let text = String(repeating: String(repeating: "这是可以选择和复制的完整译文。", count: 5) + "\n", count: 100)
        view.update(text: text, size: 16, color: .textColor)
        let narrow = view.measuredSize(width: 280)
        #expect(narrow.height > 1_000)
        #expect(view.measuredSize(width: 500).height < narrow.height)
        view.setSelectedRange(.init(location: 2, length: 8))
        view.update(text: text, size: 22, color: .textColor)
        #expect(view.selectedRange() == NSRange(location: 2, length: 8))
        #expect(view.measuredSize(width: 280).height > narrow.height)
        #expect(view.isSelectable && !view.isEditable)
    }
}
