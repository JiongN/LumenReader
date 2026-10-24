import AppKit
import SwiftUI
import LumenKit

/// One TextKit layout per prose section, retained across streaming completion.
struct NativeAnswerText: NSViewRepresentable {
    var text: String
    var blocks: [MarkdownText.Block]?
    var fontSize: CGFloat
    var textColor: Color
    var accent: Color
    var evidence: [DocumentCitation]
    @Environment(\.openURL) private var openURL

    func makeNSView(context: Context) -> AnswerTextView {
        let view = AnswerTextView()
        view.delegate = context.coordinator
        return view
    }

    func updateNSView(_ view: AnswerTextView, context: Context) {
        context.coordinator.openURL = { openURL($0) }
        view.update(text: text, blocks: blocks, fontSize: fontSize,
                    textColor: NSColor(textColor), accent: NSColor(accent), evidence: evidence)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: AnswerTextView, context: Context) -> CGSize? {
        guard let width = proposal.width, width.isFinite, width > 0 else { return nil }
        return nsView.measuredSize(width: width)
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var openURL: ((URL) -> Void)?
        func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
            guard let url = link as? URL else { return false }
            openURL?(url)
            return true
        }
    }
}

final class AnswerTextView: NSTextView {
    private var source = ""
    private var rich = false
    private var style: Style?
    private var citations: [DocumentCitation] = []
    private var measuredWidth: CGFloat = -1
    private var measuredHeight: CGFloat = 1
    private(set) var measurementCount = 0

    private struct Style: Equatable {
        var size: CGFloat
        var family: String?
        var color: NSColor
        var accent: NSColor
    }

    init() {
        let storage = NSTextStorage()
        let manager = NSLayoutManager()
        let container = NSTextContainer(size: NSSize(width: 300, height: CGFloat.greatestFiniteMagnitude))
        storage.addLayoutManager(manager)
        manager.addTextContainer(container)
        super.init(frame: .zero, textContainer: container)
        container.lineFragmentPadding = 0
        container.widthTracksTextView = true
        container.heightTracksTextView = false
        textContainerInset = .zero
        isEditable = false
        isSelectable = true
        isRichText = true
        importsGraphics = false
        allowsUndo = false
        drawsBackground = false
        isHorizontallyResizable = false
        isVerticallyResizable = false
        usesFontPanel = false
        isAutomaticLinkDetectionEnabled = false
        setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func update(text input: String, blocks: [MarkdownText.Block]?, fontSize: CGFloat,
                textColor: NSColor, accent: NSColor, evidence: [DocumentCitation]) {
        let text = blocks == nil && input.contains("原文")
            ? String(InlineEvidenceLink.render(AttributedString(input), sources: []).characters) : input
        let next = Style(size: fontSize, family: UIFontGate.familyName, color: textColor, accent: accent)
        let isRich = blocks != nil
        guard text != source || rich != isRich || style != next || citations != evidence else { return }
        guard let storage = textStorage else { return }
        let attributes: [NSAttributedString.Key: Any] = [
            .font: UIFontGate.nativeFont(size: fontSize), .foregroundColor: textColor,
            .paragraphStyle: Self.paragraphStyle()
        ]
        // Appending only the suffix preserves completed glyphs and the user's selection.
        if !isRich, !rich, style == next, text.hasPrefix(source) {
            storage.append(NSAttributedString(string: String(text.dropFirst(source.count)), attributes: attributes))
        } else {
            let selection = selectedRange()
            storage.setAttributedString(blocks.map {
                Self.attributed($0, size: fontSize, color: textColor, accent: accent, evidence: evidence)
            } ?? NSAttributedString(string: text, attributes: attributes))
            if selection.location != NSNotFound, NSMaxRange(selection) <= storage.length { setSelectedRange(selection) }
        }
        linkTextAttributes = [.foregroundColor: accent, .underlineStyle: NSUnderlineStyle.single.rawValue]
        source = text
        rich = isRich
        style = next
        citations = evidence
        measuredWidth = -1
        needsDisplay = true
    }

    func measuredSize(width: CGFloat) -> CGSize {
        guard width != measuredWidth else { return .init(width: width, height: measuredHeight) }
        guard let manager = layoutManager, let container = textContainer else { return .init(width: width, height: 1) }
        container.size = .init(width: width, height: .greatestFiniteMagnitude)
        manager.ensureLayout(for: container)
        measuredHeight = max(1, ceil(manager.usedRect(for: container).height))
        measuredWidth = width
        measurementCount += 1
        return .init(width: width, height: measuredHeight)
    }

    private static func paragraphStyle() -> NSMutableParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.lineBreakMode = .byWordWrapping
        style.lineSpacing = 4
        style.paragraphSpacing = 8
        return style
    }

    private static func attributed(_ blocks: [MarkdownText.Block], size: CGFloat,
                                   color: NSColor, accent: NSColor, evidence: [DocumentCitation]) -> NSAttributedString {
        let result = NSMutableAttributedString(string: "")
        for block in blocks {
            let content: AttributedString
            let style = paragraphStyle()
            var weight: NSFont.Weight = .regular
            var pointSize = size
            var marker = ""
            switch block.kind {
            case .heading(let level, let value):
                content = value
                weight = .semibold
                if level <= 2 { pointSize += 1 }
                style.paragraphSpacingBefore = 4
            case .paragraph(let value): content = value
            case .listItem(let label, let depth, let showsMarker, let value):
                content = value
                marker = showsMarker ? label + "\t" : "\t"
                style.firstLineHeadIndent = CGFloat(min(5, max(0, depth - 1))) * 16
                style.headIndent = style.firstLineHeadIndent + max(24, size * CGFloat(label.count) * 0.65 + 8)
                style.tabStops = [NSTextTab(textAlignment: .left, location: style.headIndent)]
            case .table, .code: continue
            }
            if result.length > 0 { result.append(NSAttributedString(string: "\n")) }
            let start = result.length
            if !marker.isEmpty {
                result.append(NSAttributedString(string: marker, attributes: [
                    .font: UIFontGate.nativeFont(size: size, weight: .medium), .foregroundColor: accent
                ]))
            }
            let rendered = InlineEvidenceLink.render(content, sources: evidence)
            for run in rendered.runs {
                let intent = run.inlinePresentationIntent ?? []
                var font = UIFontGate.nativeFont(size: pointSize,
                    weight: intent.contains(.stronglyEmphasized) ? .bold : weight, monospaced: intent.contains(.code))
                if intent.contains(.emphasized) { font = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask) }
                var attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
                if let link = run.link { attributes[.link] = link }
                if intent.contains(.strikethrough) { attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
                result.append(NSAttributedString(string: String(rendered[run.range].characters), attributes: attributes))
            }
            result.addAttribute(.paragraphStyle, value: style, range: .init(location: start, length: result.length - start))
        }
        return result
    }
}
