import AppKit
import SwiftUI
import Testing
@testable import LumenApp

@Suite @MainActor struct LiteratureNotesEditorTests {
    @Test func nativeEditorPreservesMultilineInputAndClampsExternalSelection() throws {
        var value = "阅读😀\n第二行"
        let editor = LiteratureNotesEditor(text: Binding(get: { value }, set: { value = $0 }),
            isEditable: true, textColor: .labelColor)
        let coordinator = editor.makeCoordinator()
        let scroll = LiteratureNotesEditor.makeScrollView(delegate: coordinator)
        scroll.frame = NSRect(x: 0, y: 0, width: 240, height: 220)
        editor.apply(to: scroll)
        let native = try #require(scroll.documentView as? NSTextView)
        #expect(!scroll.drawsBackground && !scroll.contentView.drawsBackground && !native.drawsBackground)
        #expect(scroll.scrollerStyle == .overlay)
        #expect(native.string == value)
        native.insertText("\n中文批注", replacementRange: NSRange(location: (value as NSString).length, length: 0))
        #expect(value == "阅读😀\n第二行\n中文批注")
        native.setSelectedRange(NSRange(location: (value as NSString).length, length: 0))
        value = "新"
        editor.apply(to: scroll)
        #expect(native.string == "新")
        #expect(native.selectedRange().location <= 1)
    }

    @Test func externalRefreshDoesNotInterruptMarkedChineseInput() throws {
        var value = "笔记"
        let editor = LiteratureNotesEditor(text: Binding(get: { value }, set: { value = $0 }),
            isEditable: true, textColor: .labelColor)
        let coordinator = editor.makeCoordinator()
        let scroll = LiteratureNotesEditor.makeScrollView(delegate: coordinator)
        editor.apply(to: scroll)
        let native = try #require(scroll.documentView as? NSTextView)
        native.setMarkedText("pin", selectedRange: NSRange(location: 3, length: 0),
            replacementRange: NSRange(location: 2, length: 0))
        #expect(native.hasMarkedText())
        let composing = native.string
        value = "外部版本"
        editor.apply(to: scroll)
        #expect(native.string == composing)
        native.unmarkText()
        #expect(!native.hasMarkedText())
        // Committing composition updates the binding. An explicit external
        // reload after that commit may replace it normally.
        value = "外部版本"
        editor.apply(to: scroll)
        #expect(native.string == "外部版本")
    }
}
