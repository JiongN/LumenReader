import AppKit
import LumenKit
import PDFKit

/// Immutable colors prepared on the main thread, consumed by PDFKit tile workers.
struct PDFReadingTone: Equatable, Sendable {
    let red: ReadingToneChannel
    let green: ReadingToneChannel
    let blue: ReadingToneChannel

    init(theme: ReadingTheme) {
        let ink = NSColor(hex: theme.textHex).usingColorSpace(.sRGB) ?? .black
        let paper = NSColor(hex: theme.backgroundHex).usingColorSpace(.sRGB) ?? .white
        red = ReadingToneChannel(ink: ink.redComponent, paper: paper.redComponent)
        green = ReadingToneChannel(ink: ink.greenComponent, paper: paper.greenComponent)
        blue = ReadingToneChannel(ink: ink.blueComponent, paper: paper.blueComponent)
    }

    /// Operates on the current opaque tile, never on the scrolling layer hierarchy.
    func paint(in context: CGContext) {
        context.saveGState()
        defer { context.restoreGState() }
        let rect = context.boundingBoxOfClipPath
        guard !rect.isEmpty, !rect.isInfinite else { return }
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        func fill(_ mode: CGBlendMode, _ r: Double, _ g: Double, _ b: Double) {
            context.setBlendMode(mode)
            context.setFillColor(CGColor(colorSpace: space, components: [r, g, b, 1])!)
            context.fill(rect)
        }
        if red.inverted || green.inverted || blue.inverted {
            fill(.difference, red.inverted ? 1 : 0, green.inverted ? 1 : 0, blue.inverted ? 1 : 0)
        }
        fill(.multiply, red.multiply, green.multiply, blue.multiply)
        fill(.screen, red.screen, green.screen, blue.screen)
    }

    func applying(to image: NSImage) -> NSImage {
        guard let source = image.cgImage(forProposedRect: nil, context: nil, hints: nil),
              let context = CGContext(data: nil, width: source.width, height: source.height,
                bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return image }
        context.draw(source, in: CGRect(x: 0, y: 0, width: source.width, height: source.height))
        paint(in: context)
        guard let result = context.makeImage() else { return image }
        return NSImage(cgImage: result, size: image.size)
    }

}

/// PDFKit can render tiles concurrently. No SwiftUI/AppKit state is read by a worker.
final class PDFReadingToneState: @unchecked Sendable {
    private let lock = NSLock()
    private var value: PDFReadingTone?
    var snapshot: PDFReadingTone? {
        lock.lock(); defer { lock.unlock() }
        return value
    }
    @discardableResult
    func update(_ tone: PDFReadingTone?) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard value != tone else { return false }
        value = tone
        return true
    }
}

/// Use the supported PDFPage hook: contemporary PDFKit tile workers bypass PDFView.draw(page:).
final class ReadingPDFDocumentDelegate: NSObject, PDFDocumentDelegate {
    let tone = PDFReadingToneState()
    func classForPage() -> AnyClass { ReadingPDFPage.self }
}

final class ReadingPDFPage: PDFPage {
    override func draw(with box: PDFDisplayBox, to context: CGContext) {
        let tone = PDFOriginalRendering.isActive ? nil
            : (document?.delegate as? ReadingPDFDocumentDelegate)?.tone.snapshot
        super.draw(with: box, to: context)
        tone?.paint(in: context)
    }

    func drawOriginal(with box: PDFDisplayBox, to context: CGContext) {
        super.draw(with: box, to: context)
    }
}

/// PDFKit serializes custom pages by drawing them. Suppress display-only paint on
/// the synchronous serialization thread; concurrent screen tiles keep their tone.
enum PDFOriginalRendering {
    private static let key = "com.jn.lumen.pdf.original-rendering"
    static var isActive: Bool { Thread.current.threadDictionary[key] as? Bool == true }
    static func data(of document: PDFDocument) -> Data? {
        let dictionary = Thread.current.threadDictionary
        let previous = dictionary[key]
        dictionary[key] = true
        defer {
            if let previous { dictionary[key] = previous }
            else { dictionary.removeObject(forKey: key) }
        }
        return document.dataRepresentation()
    }
}
