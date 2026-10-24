import AppKit
import CoreText
import PDFKit
import LumenKit

/// OCR is grafted onto native PDF content, never onto a screenshot of the page.
enum PDFSearchableWriter {
    static let didWrite = Notification.Name("LumenSearchablePDFDidWrite")
    private static let markerPrefix = "LumenOCR1:"

    struct Page: Sendable {
        var index: Int
        var lines: [PDFTextLine]
    }

    enum WriteError: LocalizedError {
        case protected, signed, invalidPage, write, changed, brokenText
        case verify(String)
        var errorDescription: String? {
            switch self {
            case .protected: "PDF 受保护或无写入权限，OCR 结果已保留在本机"
            case .signed: "PDF 含数字签名，无法自动写入文字层，OCR 结果已保留在本机"
            case .invalidPage: "PDF 页面已变化，未替换原文件"
            case .write: "无法写入可搜索 PDF，请检查磁盘空间和文件权限；OCR 结果已保留"
            case .verify(let detail): "可搜索 PDF 校验失败（\(detail)），未替换原文件；OCR 结果已保留"
            case .changed: "PDF 在识别期间发生变化，未替换原文件，请重试"
            case .brokenText: "PDF 原有文字层异常，已使用本机 OCR；自动写回暂不支持此类文件"
            }
        }
    }

    static func completedPages(in document: PDFDocument) -> Set<Int> {
        let keywords = document.documentAttributes?[PDFDocumentAttribute.keywordsAttribute] as? [String] ?? []
        return Set(keywords.filter { $0.hasPrefix(markerPrefix) }.flatMap {
            $0.dropFirst(markerPrefix.count).split(separator: ",").compactMap { Int($0) }
        }.filter { $0 >= 0 && $0 < document.pageCount })
    }

    /// Vision boxes are mapped back through the rendering transform, including
    /// nonzero media origins and 90/270 degree rotations.
    static func recognize(_ page: PDFPage, index: Int) throws -> (OCRPageResult, [PDFTextLine]) {
        guard let reference = page.pageRef else { throw OCRError.renderFailure }
        let media = reference.getBoxRect(.mediaBox)
        let rotated = abs(page.rotation % 180) == 90
        let size = rotated ? CGSize(width: media.height, height: media.width) : media.size
        let scale: CGFloat = min(2, 4096 / max(size.width, size.height))
        let width = Int(ceil(size.width * scale)), height = Int(ceil(size.height * scale))
        guard width > 8, height > 8, width <= 8192, height <= 8192,
              let bitmap = CGContext(data: nil, width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue) else { throw OCRError.renderFailure }
        let display = CGRect(origin: .zero, size: size)
        let transform = reference.getDrawingTransform(.mediaBox, rect: display, rotate: 0, preserveAspectRatio: true)
        bitmap.setFillColor(gray: 1, alpha: 1)
        bitmap.fill(CGRect(x: 0, y: 0, width: width, height: height))
        bitmap.scaleBy(x: CGFloat(width) / size.width, y: CGFloat(height) / size.height)
        bitmap.concatenate(transform)
        bitmap.drawPDFPage(reference)
        guard let image = bitmap.makeImage() else { throw OCRError.renderFailure }
        let result = try OCRService.recognize(in: image)
        let inverse = transform.inverted()
        let lines = result.lines.map { line in
            let r = line.box
            let displayed = CGRect(x: r.minX * size.width, y: r.minY * size.height,
                                   width: r.width * size.width, height: r.height * size.height)
            return PDFTextLine(pageIndex: index, text: line.text, bounds: displayed.applying(inverse))
        }
        return (result, lines)
    }

    static func write(url: URL, pages: [Page], expected: PDFLargeAnnotationSave.Fingerprint) throws -> PDFLargeAnnotationSave.Fingerprint {
        try Task.checkCancellation()
        guard try PDFLargeAnnotationSave.fingerprint(of: url) == expected else { throw WriteError.changed }
        guard let document = PDFDocument(url: url) else { throw WriteError.invalidPage }
        guard !document.isEncrypted, document.allowsDocumentChanges,
              FileManager.default.isWritableFile(atPath: url.path) else { throw WriteError.protected }
        for index in 0..<document.pageCount {
            if document.page(at: index)?.annotations.contains(where: { $0.widgetFieldType == .signature }) == true {
                throw WriteError.signed
            }
        }
        let originalCount = document.pageCount
        let originalIndices = Dictionary(uniqueKeysWithValues: (0..<originalCount).compactMap { index in
            document.page(at: index).map { (ObjectIdentifier($0), index) }
        })
        var completed = completedPages(in: document)
        let updates = pages.filter { !completed.contains($0.index) }
        guard !updates.isEmpty else { return expected }

        // Destinations refer to PDFPage instances and must be rebound after replacement.
        var rebind: [() -> Void] = []
        func remember(_ destination: PDFDestination?, apply: @escaping (PDFDestination) -> Void) {
            guard let destination, let page = destination.page else { return }
            let index = originalIndices[ObjectIdentifier(page)] ?? document.index(for: page)
            if index != NSNotFound {
                rebind.append {
                    guard let replacement = document.page(at: index) else { return }
                    let updated = PDFDestination(page: replacement, at: destination.point)
                    updated.zoom = destination.zoom
                    apply(updated)
                }
            }
        }
        func visit(_ outline: PDFOutline) {
            remember(outline.destination) { outline.destination = $0 }
            if let action = outline.action as? PDFActionGoTo {
                remember(action.destination) { action.destination = $0 }
            }
            for index in 0..<outline.numberOfChildren {
                if let child = outline.child(at: index) { visit(child) }
            }
        }
        if let root = document.outlineRoot { visit(root) }
        for index in 0..<originalCount {
            document.page(at: index)?.annotations.forEach { annotation in
                if let action = annotation.action as? PDFActionGoTo { remember(action.destination) { action.destination = $0 } }
            }
        }
        let contentUpdates = updates.filter { !$0.lines.isEmpty }
        let sources: [(PDFPage, [PDFTextLine])] = try contentUpdates.map { update in
            guard let source = document.page(at: update.index) else { throw WriteError.invalidPage }
            guard TextLayerTrust.normalized(source.string ?? "").count < 12 else { throw WriteError.brokenText }
            return (source, update.lines)
        }
        // One PDF context shares font subsets across the entire batch.
        let rendered = try searchableDocument(sources: sources)
        defer { withExtendedLifetime(rendered) {} }
        for (ordinal, update) in contentUpdates.enumerated() {
            try Task.checkCancellation()
            guard let replacement = rendered.page(at: ordinal) else { throw WriteError.invalidPage }
            document.removePage(at: update.index)
            document.insert(replacement, at: update.index)
            replacement.annotations.forEach { annotation in
                if let action = annotation.action as? PDFActionGoTo { remember(action.destination) { action.destination = $0 } }
            }
        }
        completed.formUnion(updates.map(\.index))
        rebind.forEach { $0() }
        var attributes = document.documentAttributes ?? [:]
        var keywords = attributes[PDFDocumentAttribute.keywordsAttribute] as? [String] ?? []
        keywords.removeAll { $0.hasPrefix(markerPrefix) }
        keywords.append(markerPrefix + completed.sorted().map(String.init).joined(separator: ","))
        attributes[PDFDocumentAttribute.keywordsAttribute] = keywords
        document.documentAttributes = attributes

        let temporary = url.deletingLastPathComponent().appendingPathComponent(".\(url.lastPathComponent).lumen-ocr-\(UUID()).tmp")
        defer { try? FileManager.default.removeItem(at: temporary) }
        guard document.write(to: temporary) else { throw WriteError.write }
        try Task.checkCancellation()
        guard let check = PDFDocument(url: temporary), check.pageCount == originalCount else { throw WriteError.verify("页数") }
        guard completedPages(in: check).isSuperset(of: completed) else { throw WriteError.verify("识别状态") }
        for update in updates {
            guard let page = check.page(at: update.index), let old = document.page(at: update.index),
                  page.rotation == old.rotation, page.bounds(for: .mediaBox) == old.bounds(for: .mediaBox),
                  page.annotations.count == old.annotations.count else { throw WriteError.verify("页面几何或批注") }
            let read = TextLayerTrust.normalized(page.string ?? "")
            guard update.lines.allSatisfy({ read.contains(TextLayerTrust.normalized($0.text)) }) else { throw WriteError.verify("文字不可读取") }
        }
        try Task.checkCancellation()
        return try PDFFileReplacement.commit(temporary: temporary, to: url, expected: expected)
    }

    static func searchablePage(source: PDFPage, lines: [PDFTextLine]) throws -> PDFPage {
        guard let page = try searchableDocument(sources: [(source, lines)]).page(at: 0) else { throw WriteError.invalidPage }
        return page
    }

    private static func searchableDocument(sources: [(PDFPage, [PDFTextLine])]) throws -> PDFDocument {
        guard !sources.isEmpty else { return PDFDocument() }
        let bytes = NSMutableData()
        guard let consumer = CGDataConsumer(data: bytes), let context = CGContext(consumer: consumer, mediaBox: nil, nil) else {
            throw WriteError.write
        }
        let font = NSFont(name: "ArialUnicodeMS", size: 12) ?? NSFont(name: "PingFangSC-Regular", size: 12) ?? NSFont.systemFont(ofSize: 12)
        for (source, lines) in sources {
            try Task.checkCancellation()
            guard let reference = source.pageRef else { throw WriteError.invalidPage }
            var media = reference.getBoxRect(.mediaBox)
            let box = NSData(bytes: &media, length: MemoryLayout<CGRect>.size)
            context.beginPDFPage([kCGPDFContextMediaBox as String: box] as CFDictionary)
            context.drawPDFPage(reference)
            for line in lines {
                let text = CTLineCreateWithAttributedString(NSAttributedString(string: line.text,
                    attributes: [.font: font]))
                var ascent: CGFloat = 0, descent: CGFloat = 0
                let width = CGFloat(CTLineGetTypographicBounds(text, &ascent, &descent, nil))
                guard width > 0, ascent + descent > 0, line.bounds.width > 0, line.bounds.height > 0 else { continue }
                context.saveGState()
                context.translateBy(x: line.bounds.minX, y: line.bounds.minY)
                context.scaleBy(x: line.bounds.width / width, y: line.bounds.height / (ascent + descent))
                context.textMatrix = .identity
                context.textPosition = CGPoint(x: 0, y: descent)
                context.setTextDrawingMode(.invisible)
                CGPDFContextBeginTag(context, .span, [CGPDFTagProperty.actualText: line.text] as CFDictionary)
                CTLineDraw(text, context)
                CGPDFContextEndTag(context)
                context.restoreGState()
            }
            context.endPDFPage()
        }
        context.closePDF()
        guard let document = PDFDocument(data: bytes as Data) else { throw WriteError.write }
        for (index, item) in sources.enumerated() {
            let source = item.0
            guard let page = document.page(at: index) else { throw WriteError.invalidPage }
            page.rotation = source.rotation
            for box in [PDFDisplayBox.mediaBox, .cropBox, .bleedBox, .trimBox, .artBox] {
                page.setBounds(source.bounds(for: box), for: box)
            }
            for annotation in source.annotations {
                guard let copy = annotation.copy() as? PDFAnnotation else { throw WriteError.verify("批注复制") }
                page.addAnnotation(copy)
            }
        }
        return document
    }
}

/// The last fingerprint check and atomic replacement are shared by OCR and
/// annotation writers, so neither can commit over the other's newer revision.
enum PDFFileReplacement {
    private static let lock = NSLock()
    static func commit(temporary: URL, to url: URL, expected: PDFLargeAnnotationSave.Fingerprint) throws -> PDFLargeAnnotationSave.Fingerprint {
        lock.lock()
        defer { lock.unlock() }
        var coordinationError: NSError?
        var result: Result<PDFLargeAnnotationSave.Fingerprint, Error>?
        NSFileCoordinator().coordinate(writingItemAt: url, options: .forReplacing, error: &coordinationError) { target in
            result = Result {
                try Task.checkCancellation()
                guard try PDFLargeAnnotationSave.fingerprint(of: target) == expected else { throw PDFSearchableWriter.WriteError.changed }
                _ = try FileManager.default.replaceItemAt(target, withItemAt: temporary)
                return try PDFLargeAnnotationSave.fingerprint(of: target)
            }
        }
        if let coordinationError { throw coordinationError }
        guard let result else { throw PDFSearchableWriter.WriteError.write }
        return try result.get()
    }
}
