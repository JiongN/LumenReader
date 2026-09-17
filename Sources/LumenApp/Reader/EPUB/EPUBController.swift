import SwiftUI
import WebKit
import LumenKit

/// EPUB 的 WebKit 外壳。
///
/// 章节 XHTML 由 `loadFileURL` 直接加载，图片 / 内嵌字体 / 自带 CSS 交给 WebKit 原生解析；
/// 我们只做三件事——在最外层包一层可换肤的样式层、把选区与滚动上报给 Swift、
/// 接收来自工具栏的跳转命令。
@MainActor
final class EPUBController: NSObject, ObservableObject {

    let webView: WKWebView

    private var source: EPUBDocumentSource?
    private var currentChapterIndex = 0
    private var isLoadingChapter = false
    /// 待跳转的锚点。导航是异步的，所以要在发起加载时记下来，等 didFinish 再执行。
    private var pendingAnchor: String = ""

    var onSelection: ((ReaderSelection?) -> Void)?
    /// (chapterIndex, chapterCount, 章节内进度 0…1, 是否已到章末)
    var onProgress: ((Int, Int, Double, Bool) -> Void)?

    private var theme: ReadingTheme
    private var reader: ReaderSettings

    init(theme: ReadingTheme, reader: ReaderSettings) {
        self.theme = theme
        self.reader = reader

        let configuration = WKWebViewConfiguration()
        configuration.suppressesIncrementalRendering = false
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true

        let controller = WKUserContentController()
        configuration.userContentController = controller

        self.webView = WKWebView(frame: .zero, configuration: configuration)

        super.init()

        controller.add(self, name: Self.messageHandlerName)
        configureWebView()
        installBaseScript()
    }

    private static let messageHandlerName = "lumen"

    private func configureWebView() {
        webView.navigationDelegate = self
        // 阅读区不需要弹性回弹带来的「拉出一条白边」效果
        webView.allowsBackForwardNavigationGestures = false
        webView.allowsMagnification = false
        webView.enclosingScrollView?.drawsBackground = false
        webView.setValue(false, forKey: "drawsBackground")
    }

    // MARK: - 样式注入

    /// 在文档解析前就把样式和底色塞进去，避免默认白底闪一下。
    ///
    /// 主题与排版参数全部走 CSS 变量，切换时只改变量值，不需要重新加载文档，
    /// 所以换主题是逐帧生效、不闪烁的。
    private func installBaseScript() {
        let css = Self.baseCSS(theme: theme, reader: reader)
        let darkClass = theme.isDark ? "true" : "false"

        let source = """
        (function () {
          var css = `\(css)`;
          function apply() {
            var root = document.documentElement;
            root.style.backgroundColor = getComputedStyle(root).getPropertyValue('--lm-bg') || '#ffffff';
            var existing = document.getElementById('lumen-style');
            if (existing) { existing.textContent = css; }
            else {
              var style = document.createElement('style');
              style.id = 'lumen-style';
              style.textContent = css;
              (document.head || root).appendChild(style);
            }
            root.classList.toggle('lumen-dark', \(darkClass));
          }
          apply();
          if (!document.head) {
            document.addEventListener('DOMContentLoaded', apply, { once: true });
          }
          window.__lumen = {
            setVars: function (vars, dark) {
              var root = document.documentElement;
              for (var key in vars) { root.style.setProperty(key, vars[key]); }
              root.style.backgroundColor = vars['--lm-bg'] || root.style.backgroundColor;
              root.classList.toggle('lumen-dark', !!dark);
              var body = document.body;
              if (body) {
                body.style.backgroundColor = vars['--lm-bg'] || '';
              }
            },
            text: function () { return document.body ? document.body.innerText : ''; },
            scrollToAnchor: function (anchor) {
              if (!anchor) { window.scrollTo(0, 0); return true; }
              var el = document.getElementById(anchor) || document.querySelector('[name="' + anchor + '"]');
              if (el) { el.scrollIntoView({ block: 'start' }); return true; }
              return false;
            },
            scrollTop: function () { window.scrollTo(0, 0); }
          };
          window.addEventListener('scroll', function () {
            if (window.__lumenRaf) { return; }
            window.__lumenRaf = requestAnimationFrame(function () {
              window.__lumenRaf = 0;
              var d = document.documentElement;
              var max = d.scrollHeight - d.clientHeight;
              var progress = max > 0 ? d.scrollTop / max : 1;
              window.webkit.messageHandlers.\(Self.messageHandlerName).postMessage({
                type: 'scroll', progress: progress, atEnd: max > 0 && d.scrollTop >= max - 28
              });
            });
          }, { passive: true });
          function reportSelection() {
            var sel = window.getSelection();
            if (!sel || sel.isCollapsed || sel.rangeCount === 0) {
              window.webkit.messageHandlers.\(Self.messageHandlerName).postMessage({ type: 'selection', empty: true });
              return;
            }
            var text = sel.toString();
            if (!text || text.trim().length < 2) {
              window.webkit.messageHandlers.\(Self.messageHandlerName).postMessage({ type: 'selection', empty: true });
              return;
            }
            var range = sel.getRangeAt(0);
            var node = range.startContainer;
            var block = node.nodeType === 1 ? node : node.parentElement;
            while (block && block !== document.body) {
              var display = getComputedStyle(block).display;
              if (display !== 'inline') { break; }
              block = block.parentElement;
            }
            var full = block ? (block.innerText || block.textContent || '') : text;
            var index = full.indexOf(text);
            window.webkit.messageHandlers.\(Self.messageHandlerName).postMessage({
              type: 'selection',
              text: text,
              offset: index < 0 ? 0 : index,
              preceding: index > 0 ? full.slice(Math.max(0, index - 900), index) : '',
              following: index >= 0 ? full.slice(index + text.length, index + text.length + 900) : ''
            });
          }
          document.addEventListener('mouseup', function () { setTimeout(reportSelection, 0); });
          document.addEventListener('keyup', function () { setTimeout(reportSelection, 40); });
          document.addEventListener('touchend', function () { setTimeout(reportSelection, 0); });
        })();
        """

        webView.configuration.userContentController.addUserScript(
            WKUserScript(source: source, injectionTime: .atDocumentStart, forMainFrameOnly: true)
        )
    }

    private static func baseCSS(theme: ReadingTheme, reader: ReaderSettings) -> String {
        theme.cssVariables(reader: reader)
            + "\n"
            + ReadingTheme.readerStylesheet
            + "\n"
            + extras
    }

    /// EPUB 特有的覆盖层。
    ///
    /// 电子书几乎都会在自带 CSS 里写 `body { background: #fff }`，甚至直接写在 style 属性上，
    /// 所以底色必须用 `!important` 压过去，否则深色主题下会出现白底黑字。
    /// 正文颜色只在深色主题下强制——浅色主题保留出版社原本的配色（章节标题的颜色是有信息量的）。
    private static let extras = """
    html, body {
      background: var(--lm-bg) !important;
      background-color: var(--lm-bg) !important;
    }
    html.lumen-dark body, html.lumen-dark p, html.lumen-dark div, html.lumen-dark span,
    html.lumen-dark li, html.lumen-dark td, html.lumen-dark th, html.lumen-dark dd,
    html.lumen-dark dt, html.lumen-dark blockquote, html.lumen-dark figcaption,
    html.lumen-dark h1, html.lumen-dark h2, html.lumen-dark h3,
    html.lumen-dark h4, html.lumen-dark h5, html.lumen-dark h6 {
      color: var(--lm-text) !important;
    }
    /* 清除出版社留下的浅色底块，否则深色主题下会浮出白色方块 */
    div, section, article, main, aside, header, footer, nav, figure, table, tr, td, th {
      background-color: transparent !important;
    }
    /* 覆盖 EPUB 自带的固定宽度与居中容器，交给我们的版心控制 */
    body > div, body > section {
      max-width: 100% !important;
      width: auto !important;
    }
    img { border-radius: 3px; }
    """
}

// MARK: - 载入与导航

extension EPUBController {

    func load(source: EPUBDocumentSource, startAt chapterIndex: Int, anchor: String) {
        self.source = source
        currentChapterIndex = min(max(chapterIndex, 0), source.chapters.count - 1)
        loadCurrentChapter(anchor: anchor)
    }

    var chapterCount: Int { source?.chapters.count ?? 0 }

    var chapterTitles: [String] { source?.chapters.map(\.displayTitle) ?? [] }

    func go(to locator: DocumentLocator) {
        guard let source else { return }
        let target = min(max(locator.chapterIndex, 0), source.chapters.count - 1)
        var anchor = ""
        if case .epub(_, let value, _) = locator { anchor = value }
        loadCurrentChapter(index: target, anchor: anchor)
    }

    func goToNextChapter() {
        guard let source, currentChapterIndex + 1 < source.chapters.count else { return }
        loadCurrentChapter(index: currentChapterIndex + 1, anchor: "")
    }

    func goToPreviousChapter() {
        guard currentChapterIndex > 0 else { return }
        loadCurrentChapter(index: currentChapterIndex - 1, anchor: "")
    }

    private func loadCurrentChapter(anchor: String = "") {
        loadCurrentChapter(index: currentChapterIndex, anchor: anchor)
    }

    private func loadCurrentChapter(index: Int, anchor: String) {
        guard let source, index >= 0, index < source.chapters.count else { return }
        currentChapterIndex = index
        isLoadingChapter = true

        let chapter = source.chapters[index]
        // 允许访问整个解包目录，这样 ../images/ 这类相对资源才能被加载
        webView.loadFileURL(chapter.fileURL, allowingReadAccessTo: source.rootURL)

        if !anchor.isEmpty {
            pendingAnchor = anchor
        }
    }

    func applyTheme(_ theme: ReadingTheme, reader: ReaderSettings) {
        self.theme = theme
        self.reader = reader

        let variables = Self.variableDictionary(theme: theme, reader: reader)
        guard let data = try? JSONSerialization.data(withJSONObject: variables),
              let json = String(data: data, encoding: .utf8) else { return }

        let dark = theme.isDark ? "true" : "false"
        webView.evaluateJavaScript("window.__lumen && window.__lumen.setVars(\(json), \(dark));")
    }

    /// 把 `cssVariables` 里的 `--name: value;` 解析成字典。
    ///
    /// 之所以不在 Swift 侧直接拼 JSON，是因为 CSS 变量表本身已经有一份定义，
    /// 复制一份到 Swift 会形成两个真相源，改主题时容易只改一处。
    private static func variableDictionary(theme: ReadingTheme, reader: ReaderSettings) -> [String: String] {
        var result: [String: String] = [:]
        let block = theme.cssVariables(reader: reader)
        for line in block.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("--"), trimmed.hasSuffix(";") else { continue }
            let body = trimmed.dropFirst().dropLast()
            guard let separator = body.firstIndex(of: ":") else { continue }
            let key = "--" + body[body.startIndex..<separator].trimmingCharacters(in: .whitespaces)
            let value = body[body.index(after: separator)...].trimmingCharacters(in: .whitespaces)
            result[key] = value
        }
        return result
    }

    /// 当前章节的纯文本，供 AI 使用。
    func currentChapterText() async -> String {
        await withCheckedContinuation { continuation in
            webView.evaluateJavaScript("window.__lumen ? window.__lumen.text() : ''") { value, _ in
                continuation.resume(returning: (value as? String) ?? "")
            }
        }
    }
}

// MARK: - WKNavigationDelegate

extension EPUBController: WKNavigationDelegate {

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        isLoadingChapter = false
        if !pendingAnchor.isEmpty {
            let anchor = pendingAnchor
            pendingAnchor = ""
            webView.evaluateJavaScript("window.__lumen && window.__lumen.scrollToAnchor(\(Self.jsString(anchor)));")
        } else {
            webView.evaluateJavaScript("window.__lumen && window.__lumen.scrollTop();")
        }
        onProgress?(currentChapterIndex, chapterCount, 0, false)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        isLoadingChapter = false
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        isLoadingChapter = false
    }

    /// 正文里的链接默认在应用内处理：同一本书内的锚点跳转继续在阅读区内完成，
    /// 外部链接交给系统浏览器，避免阅读区被外部页面顶掉。
    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
    ) {
        guard let url = navigationAction.request.url else {
            decisionHandler(.allow)
            return
        }

        if url.isFileURL {
            if navigationAction.navigationType == .linkActivated, let fragment = url.fragment {
                webView.evaluateJavaScript("window.__lumen && window.__lumen.scrollToAnchor(\(Self.jsString(fragment)));")
                decisionHandler(.cancel)
                return
            }
            decisionHandler(.allow)
            return
        }

        if navigationAction.navigationType == .linkActivated {
            NSWorkspace.shared.open(url)
            decisionHandler(.cancel)
            return
        }

        decisionHandler(.allow)
    }

    private static func jsString(_ value: String) -> String {
        let escaped = value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "'", with: "\\'")
            .replacingOccurrences(of: "\n", with: " ")
        return "'\(escaped)'"
    }
}

// MARK: - WKScriptMessageHandler

extension EPUBController: WKScriptMessageHandler {

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any],
              let type = body["type"] as? String else { return }

        switch type {
        case "selection":
            if body["empty"] as? Bool == true {
                onSelection?(nil)
                return
            }
            guard let text = body["text"] as? String, !text.isEmpty else {
                onSelection?(nil)
                return
            }
            let offset = body["offset"] as? Int ?? 0
            onSelection?(ReaderSelection(
                text: text,
                locator: .epub(chapterIndex: currentChapterIndex, anchor: "", charOffset: offset),
                precedingContext: body["preceding"] as? String ?? "",
                followingContext: body["following"] as? String ?? ""
            ))

        case "scroll":
            let progress = body["progress"] as? Double ?? 0
            let atEnd = body["atEnd"] as? Bool ?? false
            onProgress?(currentChapterIndex, chapterCount, progress, atEnd)

        default:
            break
        }
    }
}
