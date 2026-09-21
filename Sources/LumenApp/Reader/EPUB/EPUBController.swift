import SwiftUI
import WebKit
import LumenKit

enum EPUBTranslationError: LocalizedError {
    case pageNotReady

    var errorDescription: String? {
        "章节正文尚未完成载入，请稍后重试。"
    }
}

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

    var onLoadError: ((String) -> Void)?
    var onSelection: ((ReaderSelection?) -> Void)?
    /// 选区的来源是否为「拖动划选」（false = 单击）。
    ///
    /// 与 `onSelection` 分开上报而不是塞进 `ReaderSelection`：来源是**交互属性**、
    /// 不是文本的一部分，模型层不该为它加字段。两条回调在同一轮 runloop 里先后触发，
    /// 视图层用它们一起写 `ReaderBridge.selection / selectionFromDrag`，不会错位。
    var onSelectionSourceChange: ((Bool) -> Void)?
    /// (chapterIndex, chapterCount, 章节内进度 0…1, 是否已到章末)
    var onProgress: ((Int, Int, Double, Bool) -> Void)?
    /// 点中正文里的批注高亮（<mark class="lumen-hl">）时回调，参数是批注条目 id。
    /// 与 PDF 侧的 onAnnotationTapped 对应：两侧 → 侧栏聚焦。
    var onHighlightTapped: ((String) -> Void)?
    /// 实际生效的栏数（1 或 2）与请求栏数。窄窗口下请求的双栏会被压回单栏，
    /// 界面文案要以「生效值」为准，否则会写出「已是单栏却提示切换为单栏」这种反话。
    var onEffectiveColumns: ((_ effective: Int, _ requested: Int) -> Void)?
    /// 一章 DOM 就绪（导航完成、样式与高亮都已重画）。
    ///
    /// 逐段翻译要挂在这上面：换章之后 DOM 是一份新的，之前插的译文块和下标
    /// 标记全没了，必须按新 DOM 重来一遍。
    @Published private(set) var chapterLoadRevision = 0

    /// 取某一章的批注（id + 引文）。由阅读视图提供（批注存在应用数据目录里）。
    ///
    /// 做成闭包而不是让 Controller 持有存储：Controller 只管渲染，
    /// 「批注存在哪里」是视图层的事——PDF 那边批注写在文件里，两条路径的存储完全不同，
    /// 在这里注入一个「取批注」的口子，两边就能共用同一套 JS。
    var highlightsProvider: ((_ chapterIndex: Int) -> [(id: String, quote: String)])?

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

        controller.add(WeakEPUBMessageHandler(self), name: Self.messageHandlerName)
        configureWebView()
        installBaseScript()
        webView.configuration.userContentController.addUserScript(WKUserScript(source: EPUBLayoutScript.javascript, injectionTime: .atDocumentEnd, forMainFrameOnly: true))
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
              if (window.__lumenLayout) window.__lumenLayout.remember();
              var root = document.documentElement;
              for (var key in vars) { root.style.setProperty(key, vars[key]); }
              root.style.backgroundColor = vars['--lm-bg'] || root.style.backgroundColor;
              root.classList.toggle('lumen-dark', !!dark);
              var body = document.body;
              if (body) {
                body.style.backgroundColor = vars['--lm-bg'] || '';
              }
              if (window.__lumenLayout) window.__lumenLayout.apply();
            },
            text: function () { return document.body ? document.body.innerText : ''; },
            scrollToAnchor: function (anchor) {
              if (!anchor) { window.scrollTo(0, 0); return true; }
              var el = document.getElementById(anchor) || document.querySelector('[name="' + anchor + '"]');
              if (el) { el.scrollIntoView({ block: 'start' }); return true; }
              return false;
            },
            scrollTop: function () { window.scrollTo(0, 0); },
            // ── 批注高亮 ──
            //
            // 用「引文匹配」而不是字符偏移：EPUB 重新排版（换字号、换字体会重排）
            // 之后偏移量全部失效，而引文还在。找不到引文就不画——宁可少一个高亮，
            // 也不要在错误的位置划出一条线，那会让读者以为批注挂错了地方。
            highlight: function (id, quote) {
              if (!quote) { return false; }
              var norm = function (s) { return (s || '').replace(/\\s+/g, ' ').trim(); };
              var target = norm(quote);
              if (!target) { return false; }

              var walker = document.createTreeWalker(document.body, NodeFilter.SHOW_TEXT, {
                acceptNode: function (node) {
                  if (!node.nodeValue || !node.nodeValue.trim()) { return NodeFilter.FILTER_REJECT; }
                  var parent = node.parentElement;
                  if (!parent) { return NodeFilter.FILTER_REJECT; }
                  var tag = parent.tagName;
                  if (tag === 'SCRIPT' || tag === 'STYLE' || tag === 'MARK') { return NodeFilter.FILTER_REJECT; }
                  return NodeFilter.FILTER_ACCEPT;
                }
              });

              var nodes = [];
              var combined = '';
              var node;
              while ((node = walker.nextNode())) {
                var piece = norm(node.nodeValue);
                if (!piece) { continue; }
                var start = combined.length;
                combined += (combined ? ' ' : '') + piece;
                nodes.push({ node: node, start: start, end: combined.length });
              }
              var index = combined.indexOf(target);
              if (index < 0) { return false; }
              var endIndex = index + target.length;

              // 收集被覆盖的文本节点，逐个包进 <mark>
              for (var i = 0; i < nodes.length; i++) {
                var entry = nodes[i];
                if (entry.end <= index || entry.start >= endIndex) { continue; }
                var raw = entry.node.nodeValue;
                var offsetInNode = Math.max(0, index - entry.start);
                var lengthInNode = Math.min(raw.length, endIndex - entry.start) - offsetInNode;
                if (lengthInNode <= 0) { continue; }
                try {
                  var range = document.createRange();
                  range.setStart(entry.node, offsetInNode);
                  range.setEnd(entry.node, offsetInNode + lengthInNode);
                  var mark = document.createElement('mark');
                  mark.className = 'lumen-hl';
                  mark.setAttribute('data-lumen-id', id);
                  range.surroundContents(mark);
                } catch (e) {
                  // surroundContents 遇到跨元素边界会抛错；跳过这一段，其余照画
                }
              }
              return true;
            },
            unhighlight: function (id) {
              var marks = document.querySelectorAll('mark.lumen-hl[data-lumen-id="' + id + '"]');
              for (var i = marks.length - 1; i >= 0; i--) {
                var mark = marks[i];
                var parent = mark.parentNode;
                if (!parent) { continue; }
                while (mark.firstChild) { parent.insertBefore(mark.firstChild, mark); }
                parent.removeChild(mark);
                parent.normalize();
              }
              return true;
            },
            clearHighlights: function () {
              var marks = document.querySelectorAll('mark.lumen-hl');
              for (var i = marks.length - 1; i >= 0; i--) {
                var mark = marks[i];
                var parent = mark.parentNode;
                if (!parent) { continue; }
                while (mark.firstChild) { parent.insertBefore(mark.firstChild, mark); }
                parent.removeChild(mark);
                parent.normalize();
              }
              return true;
            },
            scrollToHighlight: function (id) {
              var mark = document.querySelector('mark.lumen-hl[data-lumen-id="' + id + '"]');
              if (mark) { mark.scrollIntoView({ block: 'center' }); return true; }
              return false;
            },
            // ── 逐段翻译 ──
            //
            // 段落的身份用 `data-lm-p`（下标）标记，而不是每次按选择器重算：
            // 插入的译文块本身也是块级元素，重算会把它算进去，下标就会漂移。
            // 标记一次、之后按下标取，才对得上。
            prepareParagraphs: function () {
              // 只取语义块的叶节点。`li` 内常常还有 `p`，父子同时入队会让同一句
              // 被翻两次；表格、图注和 h5/h6 也属于正文，不能无故漏掉。
              var selector = 'p, blockquote, dd, figcaption, td, th, h1, h2, h3, h4, h5, h6, li';
              var els = document.querySelectorAll(selector);
              var out = [];
              for (var i = 0; i < els.length; i++) {
                var el = els[i];
                if (el.classList.contains('lm-tr')) { continue; }
                if (el.matches('li') && el.querySelector('p, blockquote, dl, ol, ul, table')) { continue; }
                if (el.closest('nav, [hidden], [aria-hidden="true"]')) { continue; }
                var t = (el.innerText || el.textContent || '').trim();
                // 太短的段落不值得花一次请求（空段、纯数字页码都会落在这里）
                if (t.length < 2) { continue; }
                el.setAttribute('data-lm-p', String(out.length));
                out.push(t);
              }
              return out;
            },
            markLoading: function (indices) {
              indices = Array.isArray(indices) ? indices : [];
              for (var i = 0; i < indices.length; i++) {
                var el = document.querySelector('[data-lm-p="' + indices[i] + '"]');
                if (!el) { continue; }
                if (!el.parentNode) { continue; }
                var box = document.createElement('div');
                box.className = 'lm-tr lm-tr-loading';
                box.setAttribute('data-lm-for', el.getAttribute('data-lm-p') || '');
                box.textContent = '翻译中…';
                el.parentNode.insertBefore(box, el);
              }
              return indices.length;
            },
            setTranslation: function (index, text, state) {
              var el = document.querySelector('[data-lm-p="' + index + '"]');
              if (!el || !el.parentNode) { return false; }
              var box = el.previousElementSibling;
              if (!box || !box.classList || !box.classList.contains('lm-tr')
                  || box.getAttribute('data-lm-for') !== String(index)) {
                box = document.createElement('div');
                box.className = 'lm-tr';
                box.setAttribute('data-lm-for', String(index));
                el.parentNode.insertBefore(box, el);
              }
              box.textContent = text || '';
              box.classList.toggle('lm-tr-loading', state === 'loading');
              box.classList.toggle('lm-tr-failed', state === 'failed');
              return true;
            },
            clearTranslations: function () {
              var boxes = document.querySelectorAll('.lm-tr');
              for (var i = boxes.length - 1; i >= 0; i--) {
                var b = boxes[i];
                if (b.parentNode) { b.parentNode.removeChild(b); }
              }
              var marked = document.querySelectorAll('[data-lm-p]');
              for (var j = 0; j < marked.length; j++) { marked[j].removeAttribute('data-lm-p'); }
              return true;
            }
          };
          window.addEventListener('scroll', function () {
            if (window.__lumenRaf) { return; }
            window.__lumenRaf = requestAnimationFrame(function () {
              window.__lumenRaf = 0;
              var d = document.documentElement;
              var paged = d.classList.contains('lumen-paged');
              var max = paged ? d.scrollWidth - d.clientWidth : d.scrollHeight - d.clientHeight;
              var position = paged ? d.scrollLeft : d.scrollTop;
              var progress = max > 0 ? position / max : 1;
              window.webkit.messageHandlers.\(Self.messageHandlerName).postMessage({
                type: 'scroll', progress: progress, atEnd: !paged && max > 0 && position >= max - 28
              });
            });
          }, { passive: true });
          // 拖动 / 单击来源判定：与 PDF 侧同一套规则（按下点 → 移动距离 ≥ 4px 才算拖动）。
          // 单击产生的 1 字符选区不该弹出划词条，这道门专门挡它。
          var __lumenDownX = null, __lumenDownY = null, __lumenDragGesture = false;
          var LUMEN_DRAG_MIN = 4;
          document.addEventListener('mousedown', function (e) {
            __lumenDownX = e.clientX; __lumenDownY = e.clientY; __lumenDragGesture = false;
          });
          document.addEventListener('mousemove', function (e) {
            if (__lumenDownX === null) { return; }
            var dx = e.clientX - __lumenDownX, dy = e.clientY - __lumenDownY;
            if (Math.sqrt(dx * dx + dy * dy) >= LUMEN_DRAG_MIN) { __lumenDragGesture = true; }
          });
          function reportSelection(deliberate) {
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
              following: index >= 0 ? full.slice(index + text.length, index + text.length + 900) : '',
              fromDrag: __lumenDragGesture || deliberate === true
            });
          }
          // 键盘框选（shift+方向键）与触摸选择都是**有意为之**的选择，不算单击，放行；
          // 鼠标则按拖动距离判定。deliberate=true 仅这两条路径传。
          document.addEventListener('mouseup', function () { setTimeout(function () { reportSelection(false); }, 0); });
          document.addEventListener('keyup', function () { setTimeout(function () { reportSelection(true); }, 40); });
          document.addEventListener('touchend', function () { setTimeout(function () { reportSelection(true); }, 0); });
          // 点批注高亮 → 上报条目 id（正文 → 侧栏的联动方向）
          document.addEventListener('click', function (e) {
            var node = e.target;
            if (!node || !node.closest) { return; }
            var mark = node.closest('mark.lumen-hl');
            if (!mark) { return; }
            var id = mark.getAttribute('data-lumen-id');
            if (id) {
              window.webkit.messageHandlers.\(Self.messageHandlerName).postMessage({ type: 'highlight', id: id });
            }
          });
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
            + "\n" + EPUBLayoutScript.css
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
    /* 批注高亮。半透明黄底 + 极淡的下划线：既要一眼看见，又不能把正文压得看不清。
       用 background 而不是 border，是因为高亮常跨行，border 会在行间断开。 */
    mark.lumen-hl {
      background: rgba(255, 214, 64, 0.42) !important;
      color: inherit !important;
      border-radius: 2px;
      padding: 0 1px;
    }
    html.lumen-dark mark.lumen-hl {
      background: rgba(255, 214, 64, 0.28) !important;
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
    /* 逐段翻译的译文容器。挂在原段**上方**：对照阅读时视线自上而下是
       「译文 → 原文」，和「先看译文再对原文」的顺序一致；挂在下方则会被
       下一段顶开，读起来像是下一段的引言。左侧一道细竖条是它与正文的分界，
       不吃掉段落本身的层级。 */
    div.lm-tr {
      margin: 0.3em 0 0.55em;
      padding: 0.3em 0.6em;
      border-left: 2px solid var(--lm-accent-soft);
      border-radius: 0 4px 4px 0;
      background: var(--lm-accent-soft);
      font-size: 0.92em;
      line-height: 1.55;
      white-space: normal;
    }
    div.lm-tr-loading {
      font-style: italic;
      opacity: 0.5;
    }
    div.lm-tr-failed {
      opacity: 0.6;
      border-left-color: transparent;
      background: transparent;
      padding-left: 0.62em;
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

        pendingAnchor = anchor
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
        CSSCustomProperties.parse(theme.cssVariables(reader: reader))
    }

    /// 当前章节的纯文本，供 AI 使用。
    func currentChapterText() async -> String {
        await withCheckedContinuation { continuation in
            webView.evaluateJavaScript("window.__lumen ? window.__lumen.text() : ''") { value, _ in
                continuation.resume(returning: (value as? String) ?? "")
            }
        }
    }

    // MARK: - 批注高亮

    var currentChapter: Int { currentChapterIndex }

    /// 把当前章的批注画出来。
    ///
    /// 章节重新加载后必须重画——DOM 是新的一份，之前包裹的 `<mark>` 已经不存在了。
    /// 所以 `didFinish` 里也要调它（见导航代理）。
    func applyHighlights() {
        guard let provider = highlightsProvider else { return }
        for item in provider(currentChapterIndex) {
            let id = Self.jsString(item.id)
            let quote = Self.jsString(item.quote)
            webView.evaluateJavaScript("window.__lumen && window.__lumen.highlight(\(id), \(quote));")
        }
    }

    /// 移除一条高亮。删除批注时立刻反映到页面上，不必重新加载章节。
    func removeHighlight(id: String) {
        webView.evaluateJavaScript("window.__lumen && window.__lumen.unhighlight(\(Self.jsString(id)));")
    }

    /// 滚到某条高亮的位置。已经在本章才会命中；跨章由调用方先跳章。
    func scrollToHighlight(id: String) {
        webView.evaluateJavaScript("window.__lumen && window.__lumen.scrollToHighlight(\(Self.jsString(id)));")
    }

    // MARK: - 逐段翻译

    /// 收集当前章里值得翻译的段落（顺带给每段打上下标标记），返回原文数组。
    func prepareParagraphs() async throws -> [String] {
        try await withCheckedThrowingContinuation { continuation in
            webView.evaluateJavaScript("window.__lumen ? window.__lumen.prepareParagraphs() : null") { value, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                guard let raw = value as? [Any] else {
                    continuation.resume(throwing: EPUBTranslationError.pageNotReady)
                    return
                }
                continuation.resume(returning: raw.compactMap { $0 as? String })
            }
        }
    }

    /// 给每段插一个「翻译中…」占位。一次 JS 调用铺完，不逐段往返——
    /// 一章几十上百段，逐段 `evaluateJavaScript` 光 IPC 就要几百毫秒。
    func markTranslationsLoading(indices: [Int]) {
        guard let data = try? JSONSerialization.data(withJSONObject: indices),
              let json = String(data: data, encoding: .utf8) else { return }
        webView.evaluateJavaScript("window.__lumen && window.__lumen.markLoading(\(json));")
    }

    /// 写入第 `index` 段的译文（或失败态）。
    func setTranslation(index: Int, text: String, state: EPUBTranslationState) {
        let js = "window.__lumen && window.__lumen.setTranslation(\(index), \(Self.jsString(text)), '\(state.rawValue)');"
        webView.evaluateJavaScript(js)
    }

    /// 自检用（`--translate-report 1`）：回读页面里译文块的现状。
    ///
    /// 断言必须指向**外部可核对的产物**：数一数页面里到底有几个译文块、第一段译成了
    /// 什么、它是不是真的挂在原文**上方**——这些都能在 Safari 里手动复核。
    /// 只报「函数返回 true」的自检是自我安慰。
    func translationReport() async -> String {
        await withCheckedContinuation { continuation in
            let js = """
            (function () {
              var boxes = document.querySelectorAll('.lm-tr');
              var first = document.querySelector('[data-lm-p="0"]');
              var prev = first ? first.previousElementSibling : null;
              return {
                boxes: boxes.length,
                failed: document.querySelectorAll('.lm-tr-failed').length,
                loading: document.querySelectorAll('.lm-tr-loading').length,
                aboveOriginal: !!(prev && prev.classList && prev.classList.contains('lm-tr')),
                sample: boxes.length ? String(boxes[0].textContent || '').slice(0, 60) : '',
                original: first ? String(first.innerText || '').slice(0, 60) : ''
              };
            })()
            """
            webView.evaluateJavaScript(js) { value, _ in
                guard let dict = value as? [String: Any] else {
                    continuation.resume(returning: "（页面里读不到译文状态）")
                    return
                }
                continuation.resume(returning:
                    "译文块 \(dict["boxes"] ?? 0) 个 / 失败 \(dict["failed"] ?? 0) / 加载中 \(dict["loading"] ?? 0)"
                    + " / 译文在原文上方=\(dict["aboveOriginal"] ?? false)"
                    + " / 原文=「\(dict["original"] ?? "")」"
                    + " 译文=「\(dict["sample"] ?? "")」"
                )
            }
        }
    }

    /// 清掉全部译文与下标标记。切章节时 DOM 本来就会重建，
    /// 但关掉开关、或在同一章里重译时必须显式清，否则会越叠越多。
    func clearTranslations() {
        webView.evaluateJavaScript("window.__lumen && window.__lumen.clearTranslations();")
    }
}

// MARK: - WKNavigationDelegate

extension EPUBController: WKNavigationDelegate {

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        isLoadingChapter = false
        applyTheme(theme, reader: reader)
        if !pendingAnchor.isEmpty {
            let anchor = pendingAnchor
            pendingAnchor = ""
            webView.evaluateJavaScript("window.__lumen && window.__lumen.scrollToAnchor(\(Self.jsString(anchor)));")
        } else {
            webView.evaluateJavaScript("window.__lumen && window.__lumen.scrollTop();")
        }
        // 章节是新 DOM，批注高亮必须重画一遍（上一次包裹的 <mark> 已随旧文档消失）
        applyHighlights()
        if LaunchOptions.flag("--epub-layout-report") {
            Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 800_000_000)
                guard let self else { return }
                await EPUBLayoutAudit.run(webView: self.webView)
            }
        }
        onProgress?(currentChapterIndex, chapterCount, 0, false)
        // 放在最后：翻译要按「已经上好样式、画好高亮」的 DOM 来取段落。
        chapterLoadRevision &+= 1
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        reportLoadFailure(error)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        reportLoadFailure(error)
    }

    private func reportLoadFailure(_ error: Error) {
        guard (error as NSError).code != NSURLErrorCancelled else { return }
        isLoadingChapter = false
        onLoadError?(error.localizedDescription)
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        isLoadingChapter = false
        onLoadError?("阅读进程已停止，请重新打开当前章节。")
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
            guard let source,
                  url.standardizedFileURL.resolvingSymlinksInPath().path.hasPrefix(
                    source.rootURL.standardizedFileURL.resolvingSymlinksInPath().path + "/"
                  ) else {
                decisionHandler(.cancel)
                return
            }
            if navigationAction.navigationType == .linkActivated {
                // Cross-chapter links must update chapter state before scrolling to their anchor.
                let path = url.standardizedFileURL.resolvingSymlinksInPath().path
                if let chapter = source.chapters.first(where: { $0.fileURL.path == path }) {
                    let anchor = url.fragment?.removingPercentEncoding ?? url.fragment ?? ""
                    if chapter.index != currentChapterIndex {
                        loadCurrentChapter(index: chapter.index, anchor: anchor)
                    } else if !anchor.isEmpty {
                        webView.evaluateJavaScript("window.__lumen && window.__lumen.scrollToAnchor(\(Self.jsString(anchor)));")
                    }
                }
                decisionHandler(.cancel)
                return
            }
            decisionHandler(.allow)
            return
        }

        if navigationAction.navigationType == .linkActivated,
           ["https", "http", "mailto"].contains(url.scheme?.lowercased() ?? "") {
            NSWorkspace.shared.open(url)
        }
        decisionHandler(.cancel)
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
            // 来源标记先于选区上报：视图层据此决定划词条显不显示，两者要在同一轮
            // runloop 里都到位，否则会先闪一下浮条再被门收掉。
            let fromDrag = body["fromDrag"] as? Bool ?? false
            if body["empty"] as? Bool == true {
                onSelectionSourceChange?(false)
                onSelection?(nil)
                return
            }
            guard let text = body["text"] as? String, !text.isEmpty else {
                onSelectionSourceChange?(false)
                onSelection?(nil)
                return
            }
            let offset = body["offset"] as? Int ?? 0
            onSelectionSourceChange?(fromDrag)
            onSelection?(ReaderSelection(
                text: text,
                locator: .epub(chapterIndex: currentChapterIndex, anchor: "", charOffset: offset),
                precedingContext: body["preceding"] as? String ?? "",
                followingContext: body["following"] as? String ?? ""
            ))

        case "turnChapter":
            guard !isLoadingChapter else { return }
            if (body["direction"] as? Int ?? 1) > 0 { goToNextChapter() }
            else { goToPreviousChapter() }

        case "scroll":
            let progress = body["progress"] as? Double ?? 0
            let atEnd = body["atEnd"] as? Bool ?? false
            onProgress?(currentChapterIndex, chapterCount, progress, atEnd)

        case "highlight":
            if let id = body["id"] as? String, !id.isEmpty {
                onHighlightTapped?(id)
            }

        case "columns":
            let effective = max(1, body["effective"] as? Int ?? 1)
            let requested = max(1, body["requested"] as? Int ?? effective)
            onEffectiveColumns?(effective, requested)

        default:
            break
        }
    }
}

/// WKUserContentController retains handlers; the proxy breaks its cycle with EPUBController.
private final class WeakEPUBMessageHandler: NSObject, WKScriptMessageHandler {
    weak var target: EPUBController?
    init(_ target: EPUBController) { self.target = target }
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        target?.userContentController(userContentController, didReceive: message)
    }
}
