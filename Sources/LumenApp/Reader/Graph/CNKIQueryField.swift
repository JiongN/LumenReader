import AppKit
import SwiftUI
import LumenKit

/// A real single-line field: long/multiline PDF titles scroll horizontally, never change toolbar height.
struct CNKIQueryField: NSViewRepresentable {
    @Binding var text: String
    let submit: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> NSSearchField {
        let field = NSSearchField()
        field.font = UIFontGate.nativeFont(size: 14)
        field.placeholderString = "知网检索词"
        field.setAccessibilityLabel("知网检索词")
        field.cell?.usesSingleLineMode = true
        field.cell?.wraps = false
        field.cell?.isScrollable = true
        field.sendsSearchStringImmediately = false
        field.sendsWholeSearchString = true
        field.delegate = context.coordinator
        field.target = context.coordinator
        field.action = #selector(Coordinator.search(_:))
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return field
    }
    func updateNSView(_ field: NSSearchField, context: Context) {
        context.coordinator.parent = self
        if let editor = field.currentEditor() as? NSTextView, editor.hasMarkedText() { return }
        let value = CNKIPage.normalizedQuery(text)
        if field.stringValue != value { field.stringValue = value }
    }
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSSearchField, context: Context) -> CGSize? {
        .init(width: proposal.width ?? 300, height: 28)
    }
    @MainActor final class Coordinator: NSObject, NSSearchFieldDelegate {
        var parent: CNKIQueryField
        init(_ parent: CNKIQueryField) { self.parent = parent }
        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSSearchField else { return }
            if let editor = field.currentEditor() as? NSTextView, editor.hasMarkedText() { return }
            parent.text = CNKIPage.normalizedQuery(field.stringValue)
        }
        @objc func search(_ sender: NSSearchField) {
            parent.text = CNKIPage.normalizedQuery(sender.stringValue)
            parent.submit()
        }
    }
}
