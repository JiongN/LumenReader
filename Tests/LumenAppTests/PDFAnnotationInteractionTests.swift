import AppKit
import PDFKit
import CoreText
import Testing
import LumenKit
@testable import LumenApp

@Suite("PDF 批注交互回归", .serialized)
@MainActor
struct PDFAnnotationInteractionTests {
    @Test func contextMenuDoesNotCreateSelectionAndPreservesKeyboardSelection() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("right-click-\(UUID()).pdf")
        defer { try? FileManager.default.removeItem(at: url) }
        var bounds = CGRect(x: 0, y: 0, width: 400, height: 300)
        let context = try #require(CGContext(url as CFURL, mediaBox: &bounds, nil))
        context.beginPDFPage(nil)
        context.textPosition = CGPoint(x: 40, y: 200)
        CTLineDraw(CTLineCreateWithAttributedString(NSAttributedString(string: "Selected passage for context menu",
            attributes: [.font: NSFont.systemFont(ofSize: 18)])), context)
        context.endPDFPage()
        context.closePDF()
        let controller = PDFController()
        defer { controller.unload() }
        let document = try #require(controller.load(url: url))
        let page = try #require(document.page(at: 0))
        let view = controller.view
        view.frame = bounds
        let rightClick = try #require(NSEvent.mouseEvent(with: .rightMouseDown,
            location: NSPoint(x: 80, y: 200), modifierFlags: [], timestamp: 0,
            windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 0))
        #expect(view.menu(for: rightClick) != nil)
        #expect(view.currentSelection == nil)
        #expect(!view.isUserSelection)
        #expect(!view.isBuildingContextMenu)
        let selected = try #require(page.selection(for: NSRange(location: 0, length: 8)))
        view.setCurrentSelection(selected, animate: false)
        let keyboard = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero,
            modifierFlags: [.command], timestamp: 0, windowNumber: 0, context: nil,
            characters: "a", charactersIgnoringModifiers: "a", isARepeat: false, keyCode: 0))
        view.keyDown(with: keyboard)
        #expect(view.isUserSelection)
        let intentionalText = try #require(view.currentSelection?.string)
        #expect(view.menu(for: rightClick) != nil)
        #expect(view.currentSelection?.string == intentionalText)
        #expect(view.isUserSelection)
        controller.clearInteraction()
        #expect(view.menu(for: rightClick) != nil)
        #expect(view.currentSelection == nil)

        let storedBounds = selected.bounds(for: page)
        let legacyPartialMark = PDFAnnotation(bounds: storedBounds, forType: .highlight, withProperties: nil)
        legacyPartialMark.userName = "Lumen"
        page.addAnnotation(legacyPartialMark)
        let item = try #require(await controller.annotationsList().first)
        #expect(item.quote == selected.string)
        #expect(!item.truncated)
        #expect(legacyPartialMark.bounds == storedBounds)
    }

    @Test func contextSelectionCreatesHighlightAndBlankContextCreatesNote() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("context-selection-\(UUID()).pdf")
        defer { try? FileManager.default.removeItem(at: url) }
        var bounds = CGRect(x: 0, y: 0, width: 400, height: 300)
        let context = try #require(CGContext(url as CFURL, mediaBox: &bounds, nil))
        context.beginPDFPage(nil)
        context.textPosition = CGPoint(x: 40, y: 200)
        let text = NSAttributedString(string: "Selected passage for comment", attributes: [.font: NSFont.systemFont(ofSize: 18)])
        CTLineDraw(CTLineCreateWithAttributedString(text), context)
        context.endPDFPage()
        context.closePDF()
        let controller = PDFController()
        defer { controller.unload() }
        let doc = try #require(controller.load(url: url))
        let page = try #require(doc.page(at: 0))
        let selection = try #require(page.selection(for: NSRange(location: 0, length: 8)))
        #expect(controller.addContextAnnotation(pageIndex: 0, selection: selection, body: "selected comment"))
        #expect(page.annotations.filter { $0.lumenTypeName == "Highlight" }.count == 1)
        #expect(page.annotations.first { $0.lumenTypeName == "Highlight" }?.contents == "selected comment")
        #expect(page.annotations.filter { $0.lumenTypeName == "Text" }.isEmpty)
        controller.view.setCurrentSelection(selection, animate: false)
        #expect(controller.addContextAnnotation(pageIndex: 0, selection: nil, body: "page note"))
        #expect(page.annotations.filter { $0.lumenTypeName == "Highlight" }.count == 1)
        #expect(page.annotations.first { $0.lumenTypeName == "Text" }?.contents == "page note")
        try await waitForSave(controller)
        let reopened = try #require(PDFDocument(url: url))
        #expect(reopened.page(at: 0)?.annotations.filter { PDFController.isListableAnnotation($0) }.count == 2)
    }

    nonisolated private static func isWorkerThread() -> Bool { !Thread.isMainThread }

    @Test func objectiveCAnnotationDelegateIsSafeOnConcurrentWorkers() async throws {
        let source = PDFDocument()
        for _ in 0..<12 {
            let page = PDFPage()
            for type in [PDFAnnotationSubtype.highlight, .underline, .text, .ink] {
                let mark = PDFAnnotation(bounds: CGRect(x: 10, y: 30, width: 60, height: 15),
                    forType: type, withProperties: nil)
                mark.userName = "Lumen"
                mark.contents = "Worker callback regression"
                page.addAnnotation(mark)
            }
            source.insert(page, at: source.pageCount)
        }
        let data = try #require(source.dataRepresentation())
        let delegate = PDFAnnotationDecodingDelegate()
        let completed = await withTaskGroup(of: Bool.self, returning: Int.self) { group in
            for _ in 0..<6 {
                group.addTask {
                    guard Self.isWorkerThread() else { return false }
                    // Invoke the Objective-C protocol witness, matching PDFKit's
                    // dispatch rather than only a direct Swift call.
                    let callback: any PDFDocumentDelegate = delegate
                    guard callback.class?(forAnnotationType: "/Highlight") === RoundedHighlightAnnotation.self,
                          callback.class?(forAnnotationType: "Text") === PDFAnnotation.self,
                          callback.class?(forAnnotationType: "Unknown") === PDFAnnotation.self else { return false }
                    for _ in 0..<12 {
                        guard let doc = PDFDocument(data: data) else { return false }
                        doc.delegate = delegate
                        for index in 0..<doc.pageCount {
                            guard let marks = doc.page(at: index)?.annotations,
                                  marks.contains(where: { $0 is RoundedHighlightAnnotation }),
                                  marks.contains(where: { $0.lumenTypeName == "Text" }) else { return false }
                        }
                    }
                    return true
                }
            }
            var count = 0
            for await passed in group { if passed { count += 1 } }
            return count
        }
        #expect(completed == 6)
    }

    @Test func pageLayoutAndScrollPreferenceAreIndependent() {
        let controller = PDFController()
        defer { controller.unload() }
        controller.setPageLayout(twoPages: true)
        #expect(controller.view.displayMode == .twoUpContinuous)
        controller.apply(flowMode: .paged)
        #expect(controller.view.displayMode == .twoUp)
        controller.setPageLayout(twoPages: false)
        #expect(controller.view.displayMode == .singlePage)
        controller.apply(flowMode: .continuous)
        #expect(controller.view.displayMode == .singlePageContinuous)
    }

    @Test func contextNoteUsesRequestedPageRatherThanCurrentPage() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("context-note-\(UUID()).pdf")
        defer { try? FileManager.default.removeItem(at: url) }
        let document = PDFDocument()
        document.insert(PDFPage(), at: 0)
        document.insert(PDFPage(), at: 1)
        try #require(document.write(to: url))
        let controller = PDFController()
        defer { controller.unload() }
        let loaded = try #require(controller.load(url: url))
        let item = try #require(controller.addPageNoteAtCurrentPosition(pageIndex: 1))
        #expect(item.locator == .pdf(page: 1, charOffset: 0))
        #expect(loaded.page(at: 0)?.annotations.isEmpty == true)
        try await waitForSave(controller)
        let savedNotes = PDFDocument(url: url)?.page(at: 1)?.annotations
            .filter { PDFController.isListableAnnotation($0) }
        #expect(savedNotes?.count == 1)
    }

    @Test func sizingMenuItemsAreRemovedWithoutRemovingTextActions() {
        for title in ["自动调整大小", "放大", "缩小", "实际大小", "Zoom In", "Actual Size"] {
            #expect(PDFContextMenuPlanner.isSizingItem(title: title, action: ""))
        }
        #expect(PDFContextMenuPlanner.isSizingItem(title: "Localized zoom", action: "zoomIn:"))
        #expect(!PDFContextMenuPlanner.isSizingItem(title: "拷贝", action: "copy:"))
        #expect(!PDFContextMenuPlanner.isSizingItem(title: "移除高亮", action: "deleteHitAnnotation:"))
    }

    @Test func chosenColorIsRenderedWithoutHueOrSaturationRemapping() throws {
        let annotation = try #require(PDFAnnotationGeometry.makeHighlight(
            rectangles: [CGRect(x: 10, y: 10, width: 50, height: 20)],
            note: "", color: NSColor(srgbRed: 0.3, green: 0.5, blue: 0.2, alpha: 1), author: "Lumen"))
        let context = try #require(CGContext(data: nil, width: 80, height: 40, bitsPerComponent: 8,
            bytesPerRow: 320, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        annotation.draw(with: .mediaBox, in: context)
        let pixels = try #require(context.data).assumingMemoryBound(to: UInt8.self)
        #expect(abs(Int(pixels[(20 * 80 + 30) * 4 + 1]) - 128) <= 1)
        #expect(abs(Int(pixels[(20 * 80 + 30) * 4]) - 77) <= 1)
        #expect(annotation.color.usingColorSpace(.sRGB)?.greenComponent == 0.5)
    }

    @Test func hitUsesLinesRatherThanMultiLineBoundingBox() throws {
        let page = PDFPage()
        let annotation = try #require(PDFAnnotationGeometry.makeHighlight(
            rectangles: [CGRect(x: 20, y: 80, width: 100, height: 12),
                         CGRect(x: 20, y: 50, width: 60, height: 12)],
            note: "", color: .yellow, author: "Lumen"))
        page.addAnnotation(annotation)
        #expect(PDFAnnotationGeometry.hit(on: page, at: CGPoint(x: 30, y: 85)) === annotation)
        #expect(PDFAnnotationGeometry.hit(on: page, at: CGPoint(x: 30, y: 73)) == nil)
        #expect(PDFAnnotationGeometry.hit(on: page, at: CGPoint(x: 100, y: 55)) == nil)
        annotation.shouldDisplay = false
        #expect(PDFAnnotationGeometry.hit(on: page, at: CGPoint(x: 30, y: 85)) == nil)
    }

    @Test func notificationCannotOpenToolbarAndDeletionSurvivesReopen() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("annotation-\(UUID()).pdf")
        defer { try? FileManager.default.removeItem(at: url) }
        let source = PDFDocument()
        let page = PDFPage()
        let annotation = try #require(PDFAnnotationGeometry.makeHighlight(
            rectangles: [CGRect(x: 20, y: 80, width: 100, height: 12),
                         CGRect(x: 20, y: 50, width: 60, height: 12)],
            note: "comment", color: .yellow, author: "Lumen"))
        page.addAnnotation(annotation)
        source.insert(page, at: 0)
        try #require(source.write(to: url))
        let delegate = PDFAnnotationDecodingDelegate()
        // PDFKit also asks the document delegate from its annotation worker.
        let decodedOnWorker = await Task.detached {
            let workerDocument = PDFDocument(url: url)
            workerDocument?.delegate = delegate
            return workerDocument?.page(at: 0)?.annotations.first is RoundedHighlightAnnotation
        }.value
        #expect(decodedOnWorker)
        let controller = PDFController()
        defer { controller.unload() }
        let loaded = try #require(controller.load(url: url))
        let savedAnnotation = try #require(loaded.page(at: 0)?.annotations.first)
        #expect(savedAnnotation is RoundedHighlightAnnotation)
        var taps = 0
        controller.onAnnotationTapped = { _ in taps += 1 }
        NotificationCenter.default.post(name: .PDFViewAnnotationHit, object: controller.view,
                                         userInfo: ["PDFAnnotationHitKey": savedAnnotation])
        #expect(taps == 0)
        controller.didTapAnnotation(savedAnnotation)
        #expect(taps == 1)
        #expect((savedAnnotation as? RoundedHighlightAnnotation)?.nativeShouldDisplay == true)
        #expect(PDFDocument(url: url)?.page(at: 0)?.annotations.first?.shouldDisplay == true)
        #expect(controller.delete(annotation: savedAnnotation))
        #expect(loaded.page(at: 0)?.annotations.isEmpty == true)
        try await waitForSave(controller)
        #expect(PDFDocument(url: url)?.page(at: 0)?.annotations.isEmpty == true)
    }

    @Test func roundedAppearanceLeavesCornerClear() throws {
        let annotation = try #require(PDFAnnotationGeometry.makeHighlight(
            rectangles: [CGRect(x: 10, y: 10, width: 50, height: 20)],
            note: "", color: NSColor(calibratedRed: 1, green: 0.7, blue: 0.2, alpha: 0.82), author: "Lumen"))
        let context = try #require(CGContext(data: nil, width: 80, height: 40, bitsPerComponent: 8,
            bytesPerRow: 320, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        annotation.draw(with: .mediaBox, in: context)
        let pixels = try #require(context.data).assumingMemoryBound(to: UInt8.self)
        #expect(pixels[(10 * 80 + 10) * 4 + 3] < pixels[(20 * 80 + 30) * 4 + 3])
        #expect(pixels[(20 * 80 + 30) * 4 + 3] > 180)
    }

    @Test func savedRoundedHighlightRemainsVisibleInOtherReaders() throws {
        let document = PDFDocument()
        let page = PDFPage()
        let bounds = CGRect(x: 0, y: 0, width: 80, height: 40)
        page.setBounds(bounds, for: .mediaBox)
        page.setBounds(bounds, for: .cropBox)
        let annotation = try #require(PDFAnnotationGeometry.makeHighlight(
            rectangles: [CGRect(x: 10, y: 10, width: 50, height: 20)],
            note: "comment", color: .systemYellow, author: "Lumen"))
        page.addAnnotation(annotation)
        document.insert(page, at: 0)
        let data = try #require(document.dataRepresentation())
        let reopened = try #require(PDFDocument(data: data))
        let savedPage = try #require(reopened.page(at: 0))
        let saved = try #require(savedPage.annotations.first)
        #expect(saved.shouldDisplay)
        #expect(saved.lumenTypeName == "Highlight")
        #expect(saved.contents == "comment")
        let context = try #require(CGContext(data: nil, width: 80, height: 40, bitsPerComponent: 8,
            bytesPerRow: 320, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(NSColor.white.cgColor)
        context.fill(bounds)
        savedPage.draw(with: .mediaBox, to: context)
        let pixels = try #require(context.data).assumingMemoryBound(to: UInt8.self)
        #expect(pixels[(10 * 80 + 10) * 4 + 2] > 240)
        #expect(pixels[(20 * 80 + 30) * 4 + 2] < 200)
    }

    private func waitForSave(_ controller: PDFController) async throws {
        for _ in 0..<500 {
            if controller.pendingSaveCount == 0 { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        Issue.record("PDF 保存未结束")
    }

    @Test func sequentialNoteEditsAndDeletionSurviveAtomicReplacement() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("sequential-notes-\(UUID()).pdf")
        defer { try? FileManager.default.removeItem(at: url) }
        let original = PDFDocument()
        original.insert(PDFPage(), at: 0)
        try #require(original.write(to: url))
        let controller = PDFController()
        defer { controller.unload() }
        _ = try #require(controller.load(url: url, attachToView: false))
        #expect(controller.addNote(pageIndex: 0, anchorText: "", body: "A"))
        #expect(controller.addNote(pageIndex: 0, anchorText: "", body: "B"))
        try await waitForSave(controller)
        let firstRead = try #require(PDFDocument(url: url))
        #expect(PDFAnnotationRelationships.logicalAnnotations(on: try #require(firstRead.page(at: 0))).count == 2)
        let rows = await controller.annotationsList()
        let a = try #require(rows.first { $0.note == "A" })
        let b = try #require(rows.first { $0.note == "B" })
        #expect(controller.updateNote(id: a.id, body: "A edited"))
        try await waitForSave(controller)
        let secondRead = try #require(PDFDocument(url: url))
        #expect(secondRead.page(at: 0)?.annotations.contains { $0.contents == "A edited" } == true)
        #expect(controller.deleteAnnotation(id: b.id))
        try await waitForSave(controller)
        let afterDelete = try #require(PDFDocument(url: url))
        let fromBytes = try #require(PDFDocument(data: Data(contentsOf: url)))
        #expect(PDFAnnotationRelationships.logicalAnnotations(on: try #require(afterDelete.page(at: 0))).map(\.contents) == ["A edited"])
        #expect(fromBytes.page(at: 0)?.annotations.allSatisfy { $0.contents == "A edited" } == true)
        // Holding a previous reader must not change the final persisted snapshot.
        #expect(firstRead.pageCount == 1 && secondRead.pageCount == 1)
    }

    @Test func foreignTextNoteEditsKeepOtherAnnotationsAndDoNotAccumulatePopupBodies() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("foreign-note-\(UUID()).pdf")
        defer { try? FileManager.default.removeItem(at: url) }
        let original = PDFDocument(), page = PDFPage()
        let note = PDFAnnotation(bounds: .init(x: 50, y: 50, width: 24, height: 24), forType: .text, withProperties: nil)
        note.userName = "Other reader"; note.contents = "Original foreign note"; note.modificationDate = Date()
        page.addAnnotation(note)
        let other = PDFAnnotation(bounds: .init(x: 150, y: 150, width: 100, height: 20), forType: .highlight, withProperties: nil)
        other.userName = "Other reader"; other.contents = "Keep this highlight"; other.color = .blue
        page.addAnnotation(other)
        original.insert(page, at: 0)
        try #require(original.write(to: url))
        let controller = PDFController()
        defer { controller.unload() }
        _ = try #require(controller.load(url: url, attachToView: false))
        let rows = await controller.annotationsList()
        let item = try #require(rows.first { $0.note == "Original foreign note" })
        var receipts: [Bool] = []
        controller.onFileSaved = { ok, _ in receipts.append(ok) }
        #expect(controller.updateNote(id: item.id, body: "Edited foreign note"))
        try await waitForSave(controller)
        let afterEdit = try #require(PDFDocument(url: url)?.page(at: 0))
        #expect(afterEdit.annotations.contains { $0.contents == "Edited foreign note" })
        #expect(!afterEdit.annotations.contains { $0.contents == "Original foreign note" })
        #expect(controller.deleteAnnotation(id: item.id))
        try await waitForSave(controller)
        let afterDelete = try #require(PDFDocument(url: url)?.page(at: 0))
        #expect(afterDelete.annotations.map(\.contents) == ["Keep this highlight"])
        #expect(receipts == [true, true])
    }

    @Test func unrelatedAndAmbiguousOrphanPopupsAreNeverRemoved() {
        let page = PDFPage()
        let note = PDFAnnotation(bounds: .init(x: 50, y: 50, width: 24, height: 24), forType: .text, withProperties: nil)
        note.userName = "Lumen"; note.contents = "Same text"; note.modificationDate = Date()
        page.addAnnotation(note)
        for _ in 0..<2 {
            let popup = PDFAnnotation(bounds: .init(x: 78, y: 78, width: 72, height: 36), forType: .popup, withProperties: nil)
            popup.contents = note.contents; popup.modificationDate = note.modificationDate; popup.color = note.color
            page.addAnnotation(popup)
        }
        PDFAnnotationRelationships.remove([note], from: page)
        #expect(page.annotations.count == 2)
    }

    @Test func rapidRecolorCoalescesAndPreservesForeignAnnotationsAndReopenedColor() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("recolor-\(UUID()).pdf")
        defer { try? FileManager.default.removeItem(at: url) }
        let source = PDFDocument()
        for _ in 0..<300 { source.insert(PDFPage(), at: source.pageCount) }
        let page = try #require(source.page(at: 240))
        let mark = try #require(PDFAnnotationGeometry.makeHighlight(rectangles: [CGRect(x: 10, y: 10, width: 100, height: 20)], note: "AI answer", color: .yellow, author: "Lumen"))
        page.addAnnotation(mark)
        let foreign = PDFAnnotation(bounds: CGRect(x: 10, y: 80, width: 30, height: 20), forType: .highlight, withProperties: nil)
        foreign.userName = "Other reader"
        foreign.color = .blue
        page.addAnnotation(foreign)
        try #require(source.write(to: url))
        let controller = PDFController()
        defer { controller.unload() }
        let loaded = try #require(controller.load(url: url))
        let marks = try #require(loaded.page(at: 240)?.annotations)
        let ownID = try #require(controller.annotationID(for: marks.first { $0.userName == "Lumen" }!))
        #expect(await controller.annotationsList().first { $0.id == ownID }?.highlightHex != nil)
        var saves = 0
        controller.onFileSaved = { ok, _ in if ok { saves += 1 } }
        for swatch in HighlightSwatches.all { #expect(controller.updateHighlightColor(id: ownID, hex: swatch.hex)) }
        #expect(await controller.annotationsList().first { $0.id == ownID }?.highlightHex == "#FFA45B")
        #expect(controller.pendingSaveCount > 0)
        try await waitForSave(controller)
        #expect(saves == 1)
        let saved = try #require(PDFDocument(url: url)?.page(at: 240)?.annotations)
        #expect(PDFController.hexString(from: saved.first { $0.userName == "Lumen" }?.color) == "#FFA45B")
        #expect(PDFController.hexString(from: saved.first { $0.userName == "Other reader" }?.color) == PDFController.hexString(from: foreign.color))
        let foreignID = try #require(controller.annotationID(for: marks.first { $0.userName == "Other reader" }!))
        #expect(controller.updateHighlightColor(id: foreignID, hex: "#64C9F2"))
        try await waitForSave(controller)
        #expect(PDFController.hexString(from: PDFDocument(url: url)?.page(at: 240)?.annotations.first { $0.userName == "Other reader" }?.color) == "#64C9F2")
    }

    @Test func navigationAndProgrammaticSelectionCannotReuseOldGesture() throws {
        let controller = PDFController()
        defer { controller.unload() }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("navigation-\(UUID()).pdf")
        defer { try? FileManager.default.removeItem(at: url) }
        let document = PDFDocument()
        document.insert(PDFPage(), at: 0)
        document.insert(PDFPage(), at: 1)
        try #require(document.write(to: url))
        _ = try #require(controller.load(url: url))
        var cleared = 0
        controller.onAnnotationInteractionCleared = { cleared += 1 }
        controller.go(to: 1)
        #expect(cleared == 1)
        #expect(!controller.isSelectionFromDrag)
        #expect(controller.view.currentSelection == nil)
        // Scroll callbacks without any selection must not publish workspace changes.
        var selections = 0
        controller.onSelectionChange = { _ in selections += 1 }
        for _ in 0..<20 { controller.clearInteraction() }
        #expect(selections == 0)
    }
}
