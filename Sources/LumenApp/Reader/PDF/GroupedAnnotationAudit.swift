import AppKit
import PDFKit

@MainActor enum GroupedAnnotationAudit {
    static func run(sourceURL: URL) async {
        var passed = 0, failed = 0
        func check(_ name: String, _ value: Bool) {
            if value { passed += 1 } else { failed += 1 }
            NSLog("[Lumen][annotation-group] %@ %@", value ? "PASS" : "FAIL", name)
        }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("lumen-group-\(UUID()).pdf")
        do { try FileManager.default.copyItem(at: sourceURL, to: url) }
        catch { check("copy fixture", false); return }
        defer { try? FileManager.default.removeItem(at: url) }
        let controller = PDFController()
        let window = NSWindow(contentRect: CGRect(x: -2000, y: -2000, width: 800, height: 600),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = controller.view
        defer { controller.unload(); window.contentView = nil; window.close() }
        controller.applyAppearance(theme: .warm, brightness: 1)
        guard let doc = controller.load(url: url), let page = doc.page(at: max(0, doc.pageCount - 1)),
              let selection = page.selection(for: NSRange(location: 0, length: min(220, page.numberOfCharacters))) else {
            check("text fixture", false); return
        }
        let marker = "group audit " + UUID().uuidString
        controller.view.setCurrentSelection(selection, animate: false)
        check("multi-line fixture", selection.selectionsByLine().count > 1)
        check("create grouped highlight", controller.addHighlight(fromCurrentSelection: marker))
        let items = await controller.annotationsList().filter { $0.note == marker }
        check("one list item for one selection", items.count == 1)
        let annotations = page.annotations.filter { $0.contents == marker }
        check("one native PDF annotation", annotations.count == 1)
        guard let item = items.first, let annotation = annotations.first else { return }
        check("multiple standard quadrilaterals", (annotation.quadrilateralPoints?.count ?? 0) >= 8)
        let saved = PDFDocument(url: url)?.page(at: doc.index(for: page))?.annotations.filter { $0.contents == marker } ?? []
        check("single highlight survives save", saved.count == 1 && (saved.first?.quadrilateralPoints?.count ?? 0) >= 8)
        check("stable identity after save", saved.first.map { PDFController.entryID($0, pageIndex: doc.index(for: page)) } == item.id)
        var hitID: String?
        controller.onAnnotationTapped = { hitID = $0 }
        controller.didTapAnnotation(annotation)
        check("body hit maps to list identity", hitID == item.id)
        controller.go(to: 0)
        controller.view.autoScales = false
        controller.view.scaleFactor = 1.2
        controller.view.layoutDocumentView()
        try? await Task.sleep(for: .milliseconds(100))
        check("reveal found annotation", controller.revealAnnotation(id: item.id))
        try? await Task.sleep(for: .milliseconds(100))
        let target = controller.view.convert(annotation.bounds, from: page)
        check("reveal target is inside visible viewport", controller.view.bounds.insetBy(dx: 8, dy: 8).intersects(target))
        check("reveal retains manual zoom", abs(controller.view.scaleFactor - 1.2) < 0.001)
        check("edit grouped note", controller.updateNote(id: item.id, body: marker + " edited"))
        check("delete entire group", controller.deleteAnnotation(id: item.id))
        check("group absent after deletion", !page.annotations.contains { $0.contents?.hasPrefix(marker) == true })

        // Old releases stored adjacent lines as separate annotations with one timestamp.
        let stamp = Date(timeIntervalSince1970: 1_700_000_000)
        let oldA = PDFAnnotation(bounds: CGRect(x: 60, y: 500, width: 300, height: 16), forType: .highlight, withProperties: nil)
        let oldB = PDFAnnotation(bounds: CGRect(x: 60, y: 479, width: 280, height: 16), forType: .highlight, withProperties: nil)
        for old in [oldA, oldB] {
            old.userName = "Lumen"; old.modificationDate = stamp
            old.contents = marker; old.color = .systemYellow
            page.addAnnotation(old)
        }
        let legacy = await controller.annotationsList().filter { $0.note == marker }
        check("legacy adjacent fragments are one item", legacy.count == 1)
        check("legacy lower line hit uses same ID", controller.annotationID(for: oldB) == legacy.first?.id)
        if let id = legacy.first?.id {
            check("legacy edit updates all fragments", controller.updateNote(id: id, body: marker + " legacy") && oldA.contents == oldB.contents)
            check("legacy deletion removes all fragments", controller.deleteAnnotation(id: id) && !page.annotations.contains(oldA) && !page.annotations.contains(oldB))
        }
        NSLog("[Lumen][annotation-group] completed passed=%d failed=%d", passed, failed)
    }
}
