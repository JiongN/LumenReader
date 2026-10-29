import AppKit
import Testing
import WebKit
import LumenKit
@testable import LumenApp

@Suite("EPUB 高亮原始字符定位", .serialized)
@MainActor
struct EPUBHighlightTests {
    @Test func wholeSentenceIncludesFirstWordAndPreservesInlineFormatting() async throws {
        let controller = EPUBController(theme: .paper, reader: ReaderSettings())
        let view = controller.webView
        view.navigationDelegate = nil
        view.frame = CGRect(x: 0, y: 0, width: 640, height: 600)
        let window = NSWindow(contentRect: view.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = view
        window.isReleasedWhenClosed = false
        defer { view.stopLoading(); window.close() }
        view.loadHTMLString("""
        <html><body><h1>Earlier heading</h1><p id="p">
          By  defining governance as <em>efforts</em> to bring about <a href="#next">change</a>,<br>
          have formal authority over others. In an organization.</p>
        <p id="next">中文<strong>词语</strong>没有额外空格。😀 Start.</p>
        <div class="lm-tr">This translated sentence must not be annotated.</div></body></html>
        """, baseURL: nil)
        var ready = false
        for _ in 0..<150 {
            try await Task.sleep(for: .milliseconds(20))
            if (try? await view.evaluateJavaScript("!!window.__lumen && document.readyState === 'complete'")) as? Bool == true {
                ready = true; break
            }
        }
        try #require(ready)
        let result = try #require(try await view.evaluateJavaScript(#"""
        (() => {
          const norm = s => s.replace(/\s+/g,' ').trim();
          const before = document.getElementById('p').textContent;
          const quote = 'By defining governance as efforts to bring about change, have formal authority over others.';
          const ok = __lumen.highlight('sentence', quote, '#FFD000');
          __lumen.highlight('sentence', quote, '#FFD000');
          const marks = document.querySelectorAll('#p mark.lumen-hl');
          const marked = marks[0];
          const initial = {ok, count: marks.length, text: marked ? norm(marked.textContent) : '',
            exactDOM: document.getElementById('p').textContent === before,
            italic: !!document.querySelector('#p mark em'), link: !!document.querySelector('#p mark a')};
          initial.chinese = __lumen.highlight('chinese', '中文词语没有额外空格。😀', '#00FF00');
          initial.chineseText = document.querySelector('#next mark')?.textContent;
          initial.translation = __lumen.highlight('translation', 'This translated sentence must not be annotated.', '#FFD000');
          __lumen.recolorHighlight('sentence', '#FF0000');
          initial.color = marked.style.getPropertyValue('--lm-highlight-rgb');
          __lumen.unhighlight('sentence');
          initial.removed = document.querySelectorAll('#p mark').length === 0
            && document.getElementById('p').textContent === before && !!document.querySelector('#p em');
          return initial;
        })()
        """#) as? [String: Any])
        #expect(result["ok"] as? Bool == true)
        #expect(result["count"] as? Int == 1)
        #expect(result["text"] as? String == "By defining governance as efforts to bring about change, have formal authority over others.")
        #expect(result["exactDOM"] as? Bool == true)
        #expect(result["italic"] as? Bool == true)
        #expect(result["link"] as? Bool == true)
        #expect(result["chinese"] as? Bool == true)
        #expect(result["chineseText"] as? String == "中文词语没有额外空格。😀")
        #expect(result["translation"] as? Bool == false)
        #expect(result["color"] as? String == "255, 0, 0")
        #expect(result["removed"] as? Bool == true)
        let paragraphs = try #require(try await view.evaluateJavaScript(#"""
        (() => {
          __lumen.clearHighlights();
          const a = document.getElementById('p'), b = document.getElementById('next');
          const text = a.textContent + '\n' + b.textContent;
          const ok = __lumen.highlight('cross-paragraph', text, '#FFD000');
          return {ok, count: document.querySelectorAll('mark.lumen-hl').length,
            first: a.querySelector('mark')?.textContent.trim().startsWith('By'),
            last: b.querySelector('mark')?.textContent.endsWith('Start.')};
        })()
        """#) as? [String: Any])
        #expect(paragraphs["ok"] as? Bool == true)
        #expect(paragraphs["count"] as? Int == 2)
        #expect(paragraphs["first"] as? Bool == true)
        #expect(paragraphs["last"] as? Bool == true)
        if let path = ProcessInfo.processInfo.environment["LUMEN_HIGHLIGHT_CAPTURE"] {
            let image = try await view.takeSnapshot(configuration: nil)
            let bitmap = try #require(image.tiffRepresentation.flatMap(NSBitmapImageRep.init(data:)))
            let png = try #require(bitmap.representation(using: .png, properties: [:]))
            try png.write(to: URL(fileURLWithPath: path))
        }
    }
}
