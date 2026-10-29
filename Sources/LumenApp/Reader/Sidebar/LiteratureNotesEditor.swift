import SwiftUI
import AppKit

/// A transparent native editor with overlay scrolling. SwiftUI TextEditor keeps
/// a legacy scroller gutter when macOS is set to always show scroll bars.
struct LiteratureNotesEditor: NSViewRepresentable {
    @Binding var text: String
    var isEditable: Bool
    var textColor: NSColor

    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> NSScrollView {
        let scroll = Self.makeScrollView(delegate: context.coordinator)
        apply(to: scroll)
        return scroll
    }
    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.parent = self
        apply(to: scroll)
    }
    static func makeScrollView(delegate: NSTextViewDelegate) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.contentView.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        let editor = NSTextView()
        editor.drawsBackground = false
        editor.isRichText = false
        editor.allowsUndo = true
        editor.isVerticallyResizable = true
        editor.isHorizontallyResizable = false
        editor.autoresizingMask = [.width]
        editor.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        editor.textContainer?.widthTracksTextView = true
        editor.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        editor.textContainer?.lineFragmentPadding = 0
        editor.textContainerInset = NSSize(width: DS.Space.xs, height: DS.Space.s)
        editor.isAutomaticQuoteSubstitutionEnabled = false
        editor.isAutomaticDashSubstitutionEnabled = false
        editor.setAccessibilityLabel("阅读笔记正文")
        editor.delegate = delegate
        scroll.documentView = editor
        return scroll
    }
    func apply(to scroll: NSScrollView) {
        guard let editor = scroll.documentView as? NSTextView else { return }
        if editor.string != text && !editor.hasMarkedText() {
            let ranges = editor.selectedRanges.map(\.rangeValue)
            editor.string = text
            let length = (text as NSString).length
            editor.selectedRanges = ranges.map { range in
                let start = min(range.location, length)
                return NSValue(range: NSRange(location: start, length: min(range.length, length - start)))
            }
        }
        editor.isEditable = isEditable
        editor.font = DS.Typo.nativeBody
        editor.textColor = textColor
        editor.insertionPointColor = textColor
    }
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: LiteratureNotesEditor
        init(_ parent: LiteratureNotesEditor) { self.parent = parent }
        func textDidChange(_ notification: Notification) {
            guard let editor = notification.object as? NSTextView else { return }
            parent.text = editor.string
        }
    }
}
