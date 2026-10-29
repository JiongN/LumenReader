import AppKit
import SwiftUI

/// A completed single click locates the source without delaying native selection.
struct TranslationText: NSViewRepresentable {
    var text: String
    var size: CGFloat
    var color: Color
    var locate: () -> Void

    func makeNSView(context: Context) -> TranslationTextView { TranslationTextView() }

    func updateNSView(_ view: TranslationTextView, context: Context) {
        view.locate = locate
        view.update(text: text, size: size, color: NSColor(color))
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: TranslationTextView, context: Context) -> CGSize? {
        guard let width = proposal.width, width.isFinite, width > 0 else { return nil }
        return nsView.measuredSize(width: width)
    }
}

final class TranslationTextView: NSTextView {
    var locate: (() -> Void)?
    private var measuredWidth: CGFloat = -1
    private var measuredHeight: CGFloat = 1
    private var renderedText = ""
    private var renderedFont: NSFont?
    private var renderedColor: NSColor?

    init() {
        let storage = NSTextStorage()
        let manager = NSLayoutManager()
        let container = NSTextContainer(size: .init(width: 300, height: CGFloat.greatestFiniteMagnitude))
        storage.addLayoutManager(manager)
        manager.addTextContainer(container)
        super.init(frame: .zero, textContainer: container)
        container.lineFragmentPadding = 0
        container.widthTracksTextView = true
        textContainerInset = .zero
        isEditable = false
        isSelectable = true
        isRichText = false
        drawsBackground = false
        importsGraphics = false
        allowsUndo = false
        isHorizontallyResizable = false
        isVerticallyResizable = false
        setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        setAccessibilityCustomActions([NSAccessibilityCustomAction(name: "定位原文", handler: { [weak self] in
            guard let self, self.locate != nil else { return false }
            self.locate?()
            return true
        })])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func update(text: String, size: CGFloat, color: NSColor) {
        let nextFont = UIFontGate.nativeFont(size: size)
        guard renderedText != text || renderedFont != nextFont || renderedColor != color else { return }
        let selection = selectedRange()
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byWordWrapping
        paragraph.lineSpacing = 3
        textStorage?.setAttributedString(NSAttributedString(string: text, attributes: [
            .font: nextFont, .foregroundColor: color, .paragraphStyle: paragraph
        ]))
        font = nextFont
        textColor = color
        if NSMaxRange(selection) <= (text as NSString).length { setSelectedRange(selection) }
        measuredWidth = -1
        renderedText = text
        renderedFont = nextFont
        renderedColor = color
        needsDisplay = true
    }

    func measuredSize(width: CGFloat) -> CGSize {
        if width != measuredWidth, let manager = layoutManager, let container = textContainer {
            container.size = .init(width: width, height: .greatestFiniteMagnitude)
            manager.ensureLayout(for: container)
            measuredHeight = max(1, ceil(manager.usedRect(for: container).height))
            measuredWidth = width
        }
        return .init(width: width, height: measuredHeight)
    }

    override func mouseDown(with event: NSEvent) {
        let start = event.locationInWindow
        super.mouseDown(with: event)
        // Use the event's coordinates, not the global pointer (which may be on another window).
        let current = NSApp.currentEvent
        let end = current?.window === window ? current?.locationInWindow ?? start : start
        completeClick(clickCount: event.clickCount, distance: hypot(end.x - start.x, end.y - start.y),
                      modifiers: event.modifierFlags)
    }

    func completeClick(clickCount: Int, distance: CGFloat, modifiers: NSEvent.ModifierFlags) {
        guard window != nil,
              Self.isNavigationClick(clickCount: clickCount, selectedLength: selectedRange().length,
                                     distance: distance, modifiers: modifiers) else { return }
        // The first click may locate the paragraph; a second click still selects
        // the word in this NSTextView. Never steal its first responder or defer a
        // navigation that could fire after the user has switched tabs.
        locate?()
    }

    static func isNavigationClick(clickCount: Int, selectedLength: Int, distance: CGFloat,
                                  modifiers: NSEvent.ModifierFlags) -> Bool {
        clickCount == 1 && selectedLength == 0 && distance <= 4
            && modifiers.intersection([.shift, .command, .option, .control]).isEmpty
    }
}
