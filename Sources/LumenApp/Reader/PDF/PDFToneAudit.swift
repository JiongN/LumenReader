import AppKit
import PDFKit

/// Real Core Graphics/PDFKit regression checks; never writes the user's source file.
@MainActor enum PDFToneAudit {
    static func run(sourceURL: URL) async {
        var passed = 0, failed = 0
        func check(_ name: String, _ condition: Bool) {
            if condition { passed += 1 } else { failed += 1 }
            NSLog("[Lumen][tone] %@ %@", condition ? "PASS" : "FAIL", name)
        }
        func bitmap(_ page: PDFPage, original: Bool = false) -> CGImage? {
            guard let ctx = CGContext(data: nil, width: 256, height: 256, bitsPerComponent: 8,
                bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
            ctx.setFillColor(CGColor(gray: 1, alpha: 1))
            ctx.fill(CGRect(x: 0, y: 0, width: 256, height: 256))
            let bounds = page.bounds(for: .mediaBox)
            ctx.scaleBy(x: 256 / bounds.width, y: 256 / bounds.height)
            ctx.translateBy(x: -bounds.minX, y: -bounds.minY)
            if original, let page = page as? ReadingPDFPage {
                page.drawOriginal(with: .mediaBox, to: ctx)
            } else { page.draw(with: .mediaBox, to: ctx) }
            return ctx.makeImage()
        }
        func bytes(_ image: CGImage?) -> Data? {
            image?.dataProvider?.data.map { $0 as Data }
        }
        guard let source = PDFDocument(url: sourceURL), let first = source.page(at: 0),
              let original = bytes(bitmap(first)) else { check("fixture", false); return }
        let nativeSaved = PDFDocument(data: source.dataRepresentation()!)!
        let nativeSavedPage = nativeSaved.page(at: 0)!
        let nativeSavedPixels = bytes(bitmap(nativeSavedPage))
        let delegate = ReadingPDFDocumentDelegate()
        let doc = PDFDocument(url: sourceURL)!
        doc.delegate = delegate
        guard let page = doc.page(at: 0) else { return }
        check("native page subclass installed", page is ReadingPDFPage)
        for theme in ReadingTheme.all {
            delegate.tone.update(PDFReadingTone(theme: theme))
            check("\(theme.id) tint is visible", bytes(bitmap(page)) != original)
            check("\(theme.id) OCR uses original pixels", bytes(bitmap(page, original: true)) == original)
            if let data = PDFOriginalRendering.data(of: doc), let saved = PDFDocument(data: data), let savedPage = saved.page(at: 0) {
                check("\(theme.id) serialization preserves original pixels", bytes(bitmap(savedPage)) == nativeSavedPixels)
                check("\(theme.id) serialization preserves text", savedPage.string == nativeSavedPage.string)
            } else { check("\(theme.id) serialization", false) }
        }
        delegate.tone.update(nil)
        check("original toggle restores original pixels", bytes(bitmap(page)) == original)

        // Exercise the actual controller's cache invalidation and document ownership.
        func exerciseController() async -> WeakPDFResources {
            var controller: PDFController? = PDFController()
            let window = NSWindow(contentRect: CGRect(x: -2000, y: -2000, width: 800, height: 600),
                                  styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = controller!.view
            _ = controller!.load(url: sourceURL)
            controller!.view.autoScales = false
            controller!.view.scaleFactor = 1.25
            controller!.view.layoutDocumentView()
            controller!.go(to: min(1, controller!.pageCount - 1))
            try? await Task.sleep(for: .milliseconds(100))
            let pageIndex = controller!.currentPageIndex
            let origin = controller!.view.documentView?.enclosingScrollView?.contentView.bounds.origin
            var selection = controller!.document?.page(at: pageIndex)?.selection(for: NSRange(location: 0, length: 2))
            controller!.view.setCurrentSelection(selection, animate: false)
            for theme in ReadingTheme.all {
                controller!.applyAppearance(theme: theme, brightness: 0.85)
                try? await Task.sleep(for: .milliseconds(50))
                NSLog("[Lumen][tone] anchor expectedPage=%d actualPage=%d scale=%f origin=%@ actual=%@", pageIndex, controller!.currentPageIndex, controller!.view.scaleFactor, String(describing: origin), String(describing: controller!.view.documentView?.enclosingScrollView?.contentView.bounds.origin))
                check("\(theme.id) position and manual zoom retained", controller!.currentPageIndex == pageIndex && abs(controller!.view.scaleFactor - 1.25) < 0.001)
                check("\(theme.id) exact scroll origin retained", controller!.view.documentView?.enclosingScrollView?.contentView.bounds.origin == origin)
                check("\(theme.id) selection retained", controller!.view.currentSelection?.string == selection?.string)
            }
            selection = nil
            let resources = WeakPDFResources(controller: controller!)
            autoreleasepool {
                controller!.unload()
                window.makeFirstResponder(nil)
                window.initialFirstResponder = nil
                window.contentView = nil
                window.close()
                controller = nil
            }
            return resources
        }
        let resources = await exerciseController()
        let releaseStart = Date()
        // PDFKit retires tile jobs asynchronously after detaching a document.
        while Date().timeIntervalSince(releaseStart) < 8,
              resources.view != nil || resources.document != nil {
            try? await Task.sleep(for: .milliseconds(100))
        }
        NSLog("[Lumen][tone] resource release wait=%.3fs", Date().timeIntervalSince(releaseStart))
        check("close releases controller", resources.controller == nil)
        check("close releases PDFView", resources.view == nil)
        check("unload releases document", resources.document == nil)
        NSLog("[Lumen][tone] completed passed=%d failed=%d", passed, failed)
    }
}

@MainActor private final class WeakPDFResources {
    weak var controller: PDFController?
    weak var view: PDFView?
    weak var document: PDFDocument?
    init(controller: PDFController) {
        self.controller = controller
        view = controller.view
        document = controller.document
    }
}
