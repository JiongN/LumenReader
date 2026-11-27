import AppKit
import CoreText
import PDFKit
import Testing
import WebKit
import LumenKit
@testable import LumenApp

@Suite(.serialized)
@MainActor
struct OutlineNavigationTests {
    @Test(arguments: [ReadingFlowMode.continuous, .paged])
    func pdfBookmarksAndAIHeadingsLandInTheirOwnColumns(mode: ReadingFlowMode) async throws {
        _ = NSApplication.shared
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("outline-\(UUID()).pdf")
        defer { try? FileManager.default.removeItem(at: url) }
        var media = CGRect(x: 0, y: 0, width: 1000, height: 1000)
        let context = try #require(CGContext(url as CFURL, mediaBox: &media, nil))
        for _ in 0..<2 {
            context.beginPDFPage(nil)
            for (title, point) in [
                ("1. Left heading", CGPoint(x: 65, y: 830)),
                ("2. Right heading", CGPoint(x: 610, y: 360)),
            ] {
                context.textPosition = point
                CTLineDraw(CTLineCreateWithAttributedString(NSAttributedString(string: title,
                   attributes: [.font: NSFont(name: "Helvetica-Bold", size: 20) ?? NSFont.systemFont(ofSize: 20)])), context)
            }
            for (x, y) in [(65, 795), (610, 325)] {
                for line in 0..<4 {
                    context.textPosition = CGPoint(x: x, y: y - line * 18)
                    CTLineDraw(CTLineCreateWithAttributedString(NSAttributedString(
                        string: "This is the body text beneath this heading.",
                        attributes: [.font: NSFont(name: "Helvetica", size: 12) ?? NSFont.systemFont(ofSize: 12)])), context)
                }
            }
            context.endPDFPage()
        }
        context.closePDF()
        let source = try #require(PDFDocument(url: url))
        let page = try #require(source.page(at: 1))
        let root = PDFOutline()
        let group = PDFOutline()
        group.label = "Group without a destination"
        root.insertChild(group, at: 0)
        let left = PDFOutline()
        left.label = "Left"
        left.destination = PDFDestination(page: page, at: CGPoint(x: 55, y: 855))
        group.insertChild(left, at: 0)
        let right = PDFOutline()
        right.label = "Right"
        right.action = PDFActionGoTo(destination: PDFDestination(page: page, at: CGPoint(x: 600, y: 385)))
        root.insertChild(right, at: 1)
        source.outlineRoot = root
        #expect(source.write(to: url))

        let controller = PDFController()
        controller.view.frame = CGRect(x: 0, y: 0, width: 430, height: 350)
        let window = NSWindow(contentRect: controller.view.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = controller.view
        defer { controller.unload(); window.close() }
        let loaded = try #require(controller.load(url: url))
        controller.apply(flowMode: mode)
        controller.view.autoScales = false
        controller.view.scaleFactor = 1
        controller.view.layoutSubtreeIfNeeded()
        let nodes = PDFController.buildOutline(from: try #require(loaded.outlineRoot), document: loaded, depth: 0)
        #expect(nodes.map(\.title) == ["Left", "Right"])
        let candidates = try PDFSmartOutlineSource.read(url: url, cachedOCR: [:]).candidates
        let heading = try #require(candidates.first { $0.unitIndex == 1 && $0.title.contains("Right heading") })
        guard case .pdfHeading(let headingBounds) = heading.position else {
            Issue.record("Missing bounds on the AI heading")
            return
        }
        #expect(headingBounds.minX > 550)
        let chosen = try SmartOutlineHeadings.selectedEntries("[{\"id\":\"\(heading.id)\",\"page\":1}]", candidates: candidates)
        #expect(chosen.first?.position == heading.position)
        #expect(chosen.first?.unitIndex == 1)
        let rightNode = try #require(nodes.last)
        guard case .pdfDestination(let point) = rightNode.position else {
            Issue.record("Missing destination from PDF GoTo action")
            return
        }
        #expect(abs(point.x - 600) < 1)
        let targetPage = try #require(loaded.page(at: 1))
        controller.go(to: rightNode.locator.pageIndex, position: rightNode.position)
        #expect(controller.currentPageIndex == 1)
        let rightPoint = controller.view.convert(CGPoint(x: 630, y: 365), from: targetPage)
        #expect(controller.view.visibleRect.insetBy(dx: -3, dy: -3).contains(rightPoint))

        let leftNode = try #require(nodes.first)
        controller.go(to: leftNode.locator.pageIndex, position: leftNode.position)
        let leftPoint = controller.view.convert(CGPoint(x: 80, y: 835), from: targetPage)
        #expect(controller.view.visibleRect.insetBy(dx: -3, dy: -3).contains(leftPoint))
        #expect(!controller.view.visibleRect.contains(controller.view.convert(headingBounds, from: targetPage).origin))

        controller.go(to: heading.unitIndex, position: heading.position)
        let headingOnScreen = controller.view.convert(headingBounds, from: targetPage)
        #expect(controller.view.visibleRect.intersects(headingOnScreen))
        #expect(abs(controller.view.scaleFactor - 1) < 0.001)
    }

    @Test(arguments: [0, 1, 2])
    func epubTOCAndAIHeadingsReachActualText(columns: Int) async throws {
        _ = NSApplication.shared
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("outline-\(UUID())")
        let book = folder.appendingPathComponent("book")
        defer { try? FileManager.default.removeItem(at: folder) }
        let files = [
            "META-INF/container.xml": #"<container><rootfiles><rootfile full-path="OPS/book.opf"/></rootfiles></container>"#,
            "OPS/book.opf": #"<package><metadata><title>Navigation test</title></metadata><manifest><item id="toc" href="Nav/contents.xhtml" properties="nav" media-type="application/xhtml+xml"/><item id="a" href="../Text/start.xhtml" media-type="application/xhtml+xml"/><item id="b" href="../Text/chapter%20%23%202.xhtml" media-type="application/xhtml+xml"/></manifest><spine><itemref idref="a"/><itemref idref="b"/></spine></package>"#,
            "OPS/Nav/contents.xhtml": #"<html><body><nav><ol><li><a href="../../Text/start.xhtml">First</a></li><li><a href="../../Text/chapter%20%23%202.xhtml#part%3A%E4%B8%80%2520%23tail">Escaped target</a></li></ol></nav></body></html>"#,
            "Text/start.xhtml": #"<html xmlns="http://www.w3.org/1999/xhtml"><body><h1 id="start">Start</h1></body></html>"#,
            "Text/chapter # 2.xhtml":
                #"<html xmlns="http://www.w3.org/1999/xhtml"><body><h1 id="begin">Second chapter</h1>"#
                + String(repeating: "<p>" + String(repeating: "Content before the destination. ", count: 24) + "</p>", count: 18)
                + #"<h2 id="part:一%20#tail">Escaped target</h2><p>The original text directly after the first anchor.</p>"#
                + String(repeating: "<p>" + String(repeating: "More text for a later spread. ", count: 26) + "</p>", count: 18)
                + #"<a name="quote&quot;anchor"></a><h2>Heading without an identifier</h2><p>Visible at the second destination.</p>"#
                + String(repeating: "<p>Following paragraph.</p>", count: 40) + "</body></html>"
        ]
        for (name, text) in files {
            let url = book.appendingPathComponent(name)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(text.utf8).write(to: url)
        }
        let archive = folder.appendingPathComponent("sample.epub")
        try SubprocessDeadline.wait(for: try archiveEPUB(book, to: archive), timeout: 10)
        let source = try await EPUBDocumentSource.open(url: archive)
        defer { try? FileManager.default.removeItem(at: source.rootURL) }
        let target = try #require(source.outline.first { $0.title == "Escaped target" })
        #expect(target.locator == .epub(chapterIndex: 1, anchor: "part:一%20#tail", charOffset: 0))
        let aiSource = try source.smartOutlineSource()
        let candidate = try #require(aiSource.candidates.first { $0.title == "Heading without an identifier" })

        var reader = ReaderSettings()
        reader.epubDoubleColumn = columns == 2
        reader.flowMode = columns == 0 ? .continuous : .paged
        let controller = EPUBController(theme: .paper, reader: reader)
        let view = controller.webView
        view.frame = CGRect(x: 0, y: 0, width: 1000, height: 620)
        let window = NSWindow(contentRect: view.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = view
        window.isReleasedWhenClosed = false
        defer { view.stopLoading(); window.close() }
        var navigationErrors = [String]()
        controller.onNavigationError = { navigationErrors.append($0) }
        controller.load(source: source, startAt: 0, anchor: "start")
        try await waitUntilVisible("document.getElementById('start')", view: view)
        controller.go(to: target.locator)
        try await waitUntilVisible("document.getElementById('part:一%20#tail')", view: view)
        let revision = controller.chapterLoadRevision
        #expect((try await view.evaluateJavaScript("document.documentElement.classList.contains('lumen-paged')") as? Bool) == (columns != 0))
        controller.go(to: .epub(chapterIndex: candidate.unitIndex, anchor: "", charOffset: 0), outlinePosition: candidate.position)
        try await waitUntilVisible("document.querySelectorAll('h2')[1]", view: view)
        #expect(controller.chapterLoadRevision == revision)
        _ = try await controller.prepareParagraphs()
        _ = try await view.evaluateJavaScript("window.__lumen.markLoading([0,1,2,3,4,5,6,7,8,9,10]);")
        try await waitUntilVisible("document.querySelectorAll('h2')[1]", view: view)

        controller.go(to: .epub(chapterIndex: 0, anchor: "start", charOffset: 0))
        controller.go(to: target.locator)
        controller.go(to: .epub(chapterIndex: 1, anchor: "quote\"anchor", charOffset: 0))
        try await waitUntilVisible("document.querySelectorAll('h2')[1]", view: view)
        #expect(controller.currentChapter == 1)
        #expect(navigationErrors.isEmpty)

        controller.revealText("The original text directly after the first anchor.", at: target.locator)
        try await waitUntilVisible("document.getElementById('part:一%20#tail').nextElementSibling", view: view)
        #expect((try await view.evaluateJavaScript("String(window.getSelection())") as? String) == "The original text directly after the first anchor.")
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["LUMEN_REAL_OUTLINE_EPUB"] != nil))
    func realBookTOCWithAnchorsInBothLayouts() async throws {
        let path = try #require(ProcessInfo.processInfo.environment["LUMEN_REAL_OUTLINE_EPUB"])
        let fixture = FileManager.default.temporaryDirectory.appendingPathComponent("real-outline-\(UUID()).epub")
        try FileManager.default.copyItem(at: URL(fileURLWithPath: path), to: fixture)
        defer { try? FileManager.default.removeItem(at: fixture) }
        let source = try await EPUBDocumentSource.open(url: fixture)
        defer { try? FileManager.default.removeItem(at: source.rootURL) }
        let targets = source.outline.flatMap(\.flattened).filter { node in
            if case .epub(_, let anchor, _) = node.locator { return !anchor.isEmpty }
            return false
        }
        let limit = min(12, targets.count)
        try #require(limit > 0)
        for columns in [false, true] {
            var reader = ReaderSettings()
            reader.epubDoubleColumn = columns
            let controller = EPUBController(theme: .paper, reader: reader)
            let view = controller.webView
            view.frame = CGRect(x: 0, y: 0, width: 1000, height: 620)
            let window = NSWindow(contentRect: view.frame, styleMask: [.titled], backing: .buffered, defer: false)
            window.contentView = view
            window.isReleasedWhenClosed = false
            defer { view.stopLoading(); window.close() }
            controller.load(source: source, startAt: 0, anchor: "")
            for node in targets.prefix(limit) {
                guard case .epub(let chapter, let anchor, _) = node.locator else { continue }
                controller.go(to: node.locator)
                let id = EPUBController.jsString(anchor)
                let lookup = "document.getElementById(\(id)) || Array.from(document.querySelectorAll('[name]')).find(e => e.getAttribute('name') === \(id))"
                try await waitUntilVisible(lookup, view: view)
                #expect(controller.currentChapter == chapter)
            }
            print("Real EPUB anchored TOC entries read: \(limit); double column: \(columns)")
        }
    }

    private func archiveEPUB(_ book: URL, to url: URL) throws -> Process {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["-c", "-k", book.path, url.path]
        try process.run()
        return process
    }

    private func waitUntilVisible(_ element: String, view: WKWebView) async throws {
        let script = """
            (() => {
              const node = \(element), r = node?.getBoundingClientRect();
              return !!window.__lumen && !!r && r.bottom > 0 && r.top < innerHeight
                && r.right > 0 && r.left < innerWidth;
            })()
            """
        for _ in 0..<150 {
            if (try? await view.evaluateJavaScript(script)) as? Bool == true { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        let geometry = try? await view.evaluateJavaScript("""
            JSON.stringify({ target: (\(element))?.getBoundingClientRect(), scrollX, scrollY, innerWidth, innerHeight,
                width: document.documentElement.scrollWidth, height: document.documentElement.scrollHeight,
                columnCount: getComputedStyle(document.body).columnCount, columnWidth: getComputedStyle(document.body).columnWidth })
            """) as? String
        Issue.record("Target not in viewport: \(element), \(geometry ?? "no geometry")")
    }
}
