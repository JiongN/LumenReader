import AppKit
import Testing
import WebKit
import LumenKit
@testable import LumenApp

@Suite("EPUB 译文排版", .serialized)
@MainActor
struct EPUBTranslationLayoutTests {
    @Test func translationsKeepTheirOwnTypographyAndFlow() async throws {
        for width in [480.0, 1120.0] {
            for size in [15.0, 22.0] {
                let controller = EPUBController(theme: .paper, reader: ReaderSettings())
                let view = controller.webView
                // The fixture is about:blank, not a chapter within the controller's file sandbox.
                view.navigationDelegate = nil
                view.frame = CGRect(x: 0, y: 0, width: width, height: 760)
                let window = NSWindow(contentRect: view.frame, styleMask: [.titled], backing: .buffered, defer: false)
                window.contentView = view
                window.isReleasedWhenClosed = false
                defer { view.stopLoading(); window.close() }
                let capture = ProcessInfo.processInfo.environment["LUMEN_EPUB_LAYOUT_CAPTURE"]
                if capture != nil { window.orderFront(nil) }
                // Deliberately hostile publisher styles, including inherited spacing and fixed heights.
                view.loadHTMLString("""
                <html><head><style>
                body { text-align: justify; text-indent: 3em; word-spacing: 12px; }
                div { font-size: 9px; line-height: 1; margin: 40px; height: 80px; }
                p { margin-bottom: 80px; }
                </style></head><body>
                <p id="original">Many AI literacy frameworks focus on tool use and efficiency. Critical AI literacy also examines the social and ethical implications of these systems.</p>
                <p id="following">Furthermore, education involves judgement, not only the use of tools.</p>
                </body></html>
                """, baseURL: nil)
                var ready = false
                for _ in 0..<150 {
                    try await Task.sleep(for: .milliseconds(20))
                    if (try? await view.evaluateJavaScript("!!window.__lumen && document.readyState === 'complete'")) as? Bool == true {
                        ready = true
                        break
                    }
                }
                try #require(ready)
                let originals = try await controller.prepareParagraphs()
                #expect(originals.count == 2)
                controller.applyTranslationTextSize(size)
                let translation = "许多人工智能素养框架强调工具使用与效率，但批判性人工智能素养还需要考察这些系统的社会与伦理影响。" + String(repeating: "读者应当理解技术的局限，并在具体情境中作出判断。", count: 8) + "\n\n第二段保留原有换段，不与上一段挤在一起。"
                controller.setTranslation(index: 0, text: translation, state: .done)
                controller.flushPendingTranslations()
                let result = try #require(try await view.evaluateJavaScript("""
                (() => {
                  const box = document.querySelector('.lm-tr'), s = getComputedStyle(box);
                  const original = document.getElementById('original'), following = document.getElementById('following');
                  const r = box.getBoundingClientRect(), a = original.getBoundingClientRect(), b = following.getBoundingClientRect();
                  return { size: parseFloat(s.fontSize), line: parseFloat(s.lineHeight),
                    indent: s.textIndent, align: s.textAlign, letters: s.letterSpacing, words: s.wordSpacing,
                    whitespace: s.whiteSpace, breakInside: s.breakInside, weight: s.fontWeight,
                    hanging: s.hangingPunctuation,
                    originalAlign: getComputedStyle(original).textAlign,
                    gapAbove: r.top - a.bottom, gapBelow: b.top - r.bottom,
                    noClip: box.scrollWidth <= box.clientWidth + 1 && box.scrollHeight <= box.clientHeight + 1,
                    dimensions: [box.scrollWidth, box.clientWidth, box.scrollHeight, box.clientHeight],
                    inBounds: r.left >= 0 && r.right <= innerWidth + 1,
                    content: box.textContent };
                })()
                """) as? [String: Any])
                #expect(result["size"] as? Double == size)
                #expect(abs((result["line"] as? Double ?? 0) - size * 1.85) < 0.1)
                #expect(result["indent"] as? String == "0px")
                #expect(result["align"] as? String == "start")
                #expect(result["letters"] as? String == "normal" || result["letters"] as? String == "0px")
                #expect(result["words"] as? String == "0px" || result["words"] as? String == "normal")
                #expect(result["whitespace"] as? String == "pre-line")
                #expect(result["weight"] as? String == "400")
                #expect(result["hanging"] as? String == "none")
                #expect(result["breakInside"] as? String == "auto")
                #expect(result["originalAlign"] as? String == "justify")
                let gapAbove = try #require(result["gapAbove"] as? Double)
                let gapBelow = try #require(result["gapBelow"] as? Double)
                #expect(gapAbove >= size * 0.6 - 1)
                #expect(gapBelow >= size * 1.5 - 1)
                #expect(gapBelow > gapAbove)
                #expect(result["noClip"] as? Bool == true, "width=\(width) size=\(size) dimensions=\(String(describing: result["dimensions"]))")
                #expect(result["inBounds"] as? Bool == true)
                #expect(result["content"] as? String == translation)
                #expect(try await controller.prepareParagraphs() == originals)
                if let capture {
                    let image = try await view.takeSnapshot(configuration: nil)
                    let bitmap = try #require(image.tiffRepresentation.flatMap(NSBitmapImageRep.init(data:)))
                    let png = try #require(bitmap.representation(using: .png, properties: [:]))
                    let folder = URL(fileURLWithPath: capture, isDirectory: true)
                    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                    try png.write(to: folder.appendingPathComponent("epub-\(Int(width))-\(Int(size)).png"))
                }
            }
        }
    }

    @Test func longTranslationFlowsAcrossColumnsInDarkTheme() async throws {
        var reader = ReaderSettings()
        reader.epubDoubleColumn = true
        let view = WKWebView(frame: CGRect(x: 0, y: 0, width: 1120, height: 760))
        defer { view.stopLoading() }
        let css = ReadingTheme.midnight.cssVariables(reader: reader) + ReadingTheme.readerStylesheet
            + EPUBController.translationStylesheet + EPUBLayoutScript.css
        view.loadHTMLString("""
        <html class="lumen-paged" style="--lm-effective-columns:2; --lm-translation-size:22px">
        <head><style>\(css)</style></head><body>
        <p>Original paragraph.</p><div class="lm-tr">\(String(repeating: "技术需要放回具体情境中理解，译文应连续排版而不是被限制在固定高度内。", count: 150))</div>
        </body></html>
        """, baseURL: nil)
        var ready = false
        for _ in 0..<150 {
            try await Task.sleep(for: .milliseconds(20))
            if (try? await view.evaluateJavaScript("document.readyState === 'complete' && !!document.querySelector('.lm-tr')")) as? Bool == true {
                ready = true
                break
            }
        }
        try #require(ready)
        let result = try #require(try await view.evaluateJavaScript("""
        (() => {
          const box = document.querySelector('.lm-tr'), s = getComputedStyle(box);
          const rects = Array.from(box.getClientRects());
          return { fragments: rects.length, widthsFit: rects.every(r => r.width <= 532 && r.width > 100),
            heightsFit: rects.every(r => r.height <= 705), breakInside: s.breakInside,
            color: s.color, line: parseFloat(s.lineHeight), overflow: document.documentElement.scrollWidth > innerWidth };
        })()
        """) as? [String: Any])
        #expect((result["fragments"] as? Int ?? 0) > 2)
        #expect(result["widthsFit"] as? Bool == true)
        #expect(result["heightsFit"] as? Bool == true)
        #expect(result["overflow"] as? Bool == true)
        #expect(result["breakInside"] as? String == "auto")
        #expect(result["color"] as? String == "rgb(213, 216, 214)")
        #expect(abs((result["line"] as? Double ?? 0) - 40.7) < 0.1)
    }
    @Test func translatedParagraphsBeforeAnchorDoNotMoveReadingPosition() async throws {
        let controller = EPUBController(theme: .paper, reader: ReaderSettings())
        let view = controller.webView
        view.navigationDelegate = nil
        view.frame = CGRect(x: 0, y: 0, width: 1000, height: 760)
        let window = NSWindow(contentRect: view.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = view; window.isReleasedWhenClosed = false
        defer { view.stopLoading(); window.close() }
        let before = (0..<18).map { "<p>Earlier paragraph \($0). " + String(repeating: "Original text. ", count: 20) + "</p>" }.joined()
        let after = String(repeating: "<p>Later text for scroll space.</p>", count: 35)
        view.loadHTMLString("<html><body>\(before)<h2 id='chapter'>CHAPTER I</h2><p>The subject of this Essay.</p>\(after)</body></html>", baseURL: nil)
        var ready = false
        for _ in 0..<150 {
            try await Task.sleep(for: .milliseconds(20))
            if (try? await view.evaluateJavaScript("!!window.__lumen && document.readyState === 'complete'")) as? Bool == true { ready = true; break }
        }
        try #require(ready)
        _ = try await controller.prepareParagraphs()
        _ = try await view.evaluateJavaScript("window.__lumen.scrollToAnchor('chapter')")
        try await Task.sleep(for: .milliseconds(80))
        let originalTop = try #require(try await view.evaluateJavaScript("document.getElementById('chapter').getBoundingClientRect().top") as? Double)
        #expect(abs(originalTop) < 2)
        _ = try await view.evaluateJavaScript("window.__lumen.markLoading([0,1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,16,17])")
        let loadingTop = try #require(try await view.evaluateJavaScript("document.getElementById('chapter').getBoundingClientRect().top") as? Double)
        #expect(abs(loadingTop - originalTop) < 2)
        for index in 0..<18 {
            controller.setTranslation(index: index, text: String(repeating: "译文插入后应保留当前章节的位置。", count: 10), state: .done)
        }
        controller.flushPendingTranslations()
        try await Task.sleep(for: .milliseconds(80))
        let translatedTop = try #require(try await view.evaluateJavaScript("document.getElementById('chapter').getBoundingClientRect().top") as? Double)
        #expect(abs(translatedTop - originalTop) < 2)
    }

}
