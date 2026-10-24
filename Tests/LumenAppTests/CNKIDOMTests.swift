import AppKit
import WebKit
import Testing
import LumenKit
@testable import LumenApp

@Suite("知网可见表单", .serialized)
@MainActor
struct CNKIDOMTests {
    @Test func visibleFormSubmissionAndRowsAreParsedWithoutExecutingQueryText() async throws {
        _ = NSApplication.shared
        let model = CNKISearchModel(query: "课堂沉默", persistent: false)
        let view = model.webView
        view.frame = .init(x: 0, y: 0, width: 800, height: 600)
        defer { model.close() }
        let source = CNKISearchModel.home
        view.loadHTMLString(#"""
        <input id="txt_search"><button class="search-btn" onclick="document.getElementById('submitted').textContent=document.getElementById('txt_search').value">检索</button>
        <p id="submitted"></p><div style="display:none" class="captcha-box">请输入验证码</div>
        <table class="result-table-list"><tbody><tr>
        <td class="name"><a class="fz14" href="/kcms2/article/abstract?filename=TEST001">课堂沉默研究</a></td>
        <td class="author"><a>张三</a><a>李四</a></td><td class="source">教育研究</td>
        <td class="date">2026-01-12</td><td class="quote">8</td>
        </tr></tbody></table>
        """#, baseURL: source)
        try await ready(view)
        let query = "');window.injected=true;//"
        let submission = try await model.javaScript(CNKIDOMScript.submit, arguments: ["query": query])
        #expect(try JSONDecoder().decode(Bool.self, from: submission))
        #expect(try await view.evaluateJavaScript("document.getElementById('submitted').textContent") as? String == query)
        #expect(try await view.evaluateJavaScript("window.injected === undefined") as? Bool == true)
        let data = try await model.javaScript(CNKIDOMScript.read)
        let page = try CNKIPage.decode(data, source: source, query: query)
        #expect(page.state == .results)
        #expect(page.papers.first?.authors == ["张三", "李四"])
        #expect(page.papers.first?.year == 2026)
        #expect(page.papers.first?.citations == 8)
    }

    @Test func visibleVerificationAndOffSitePagesCannotBeReadAsResults() async throws {
        let model = CNKISearchModel(query: "测试", persistent: false)
        defer { model.close() }
        model.webView.frame = .init(x: 0, y: 0, width: 800, height: 600)
        model.webView.loadHTMLString("<p>请完成安全验证</p><p>未检索到文献</p>", baseURL: CNKISearchModel.home)
        try await ready(model.webView)
        let data = try await model.javaScript(CNKIDOMScript.read)
        #expect(try CNKIPage.decode(data, source: CNKISearchModel.home, query: "测试").state == .verificationRequired)
        model.webView.loadHTMLString("<input id='txt_search'><button class='search-btn'>检索</button>",
                                     baseURL: URL(string: "https://library.example/"))
        try await ready(model.webView)
        let submission = try await model.javaScript(CNKIDOMScript.submit, arguments: ["query": "测试"])
        #expect(try !JSONDecoder().decode(Bool.self, from: submission))
    }

    @Test func stoppingReadCannotPublishLateResults() async throws {
        _ = NSApplication.shared
        let model = CNKISearchModel(query: "课堂沉默", persistent: false)
        model.webView.loadHTMLString("<p>未检索到相关文献</p>", baseURL: CNKISearchModel.home)
        try await ready(model.webView)
        model.readCurrentPage()
        model.stop()
        try await Task.sleep(for: .milliseconds(100))
        #expect(model.message == "已停止检索。" && !model.busy && model.papers.isEmpty)
        model.close()
    }

    @Test func closedBrowserReleasesItsModelEvenDuringARead() async throws {
        weak var released: CNKISearchModel?
        do {
            let model = CNKISearchModel(query: "课堂沉默", persistent: false)
            released = model
            model.webView.loadHTMLString("<p>未检索到相关文献</p>", baseURL: CNKISearchModel.home)
            try await ready(model.webView)
            model.readCurrentPage()
            model.close()
        }
        for _ in 0..<50 where released != nil { try await Task.sleep(for: .milliseconds(20)) }
        #expect(released == nil)
    }

    @Test func newTabLinksStayInTheExistingBrowserAndPreserveSecureNavigation() async throws {
        _ = NSApplication.shared
        var requests: [URLRequest] = []
        var targets: [WKWebView] = []
        let model = CNKISearchModel(query: "测试", persistent: false, navigation: { view, request in
            targets.append(view)
            requests.append(request)
        })
        defer { model.close() }
        let view = model.webView
        view.configuration.preferences.javaScriptCanOpenWindowsAutomatically = true
        view.loadHTMLString("""
        <a id="detail" target="_blank" href="https://kns.cnki.net/kcms2/article/abstract?filename=FIXTURE">详情</a>
        <a id="legacy" target="_blank" href="http://kns.cnki.net/kcms2/article/abstract?filename=LEGACY">旧链接</a>
        <a id="unsafe" target="_blank" href="http://example.org/not-secure">非安全页面</a>
        """, baseURL: CNKISearchModel.home)
        try await ready(view)
        let windows = Set(NSApp.windows.map(\.windowNumber))
        try await view.evaluateJavaScript("document.getElementById('detail').click()")
        try await wait { requests.count == 1 }
        #expect(requests.first?.url?.absoluteString == "https://kns.cnki.net/kcms2/article/abstract?filename=FIXTURE")
        #expect(targets.allSatisfy { $0 === view })
        #expect(Set(NSApp.windows.map(\.windowNumber)) == windows)
        try await view.evaluateJavaScript("document.getElementById('legacy').click()")
        try await wait { requests.count == 2 }
        #expect(requests.last?.url?.scheme == "https")
        try await view.evaluateJavaScript("document.getElementById('unsafe').click()")
        try await wait { model.isError }
        #expect(requests.count == 2)
        try await view.evaluateJavaScript("window.open('https://kns.cnki.net/kcms2/article/abstract?filename=SCRIPT', '_blank'); void(0)")
        try await wait { requests.count == 3 }
        #expect(targets.allSatisfy { $0 === view })
        #expect(Set(NSApp.windows.map(\.windowNumber)) == windows)
    }

    @Test func unavailableHistoryCannotNavigateOrClearTheCurrentPage() async throws {
        let model = CNKISearchModel(query: "测试", persistent: false)
        defer { model.close() }
        let view = model.webView
        view.loadHTMLString("<p>题录</p>", baseURL: CNKISearchModel.home)
        try await ready(view)
        #expect(!model.canGoBack && !model.canGoForward)
        let url = view.url
        model.navigateHistory(backward: true)
        model.navigateHistory(backward: false)
        #expect(view.url == url)
        #expect(!model.busy)
        #expect(model.canGoBack == view.canGoBack && model.canGoForward == view.canGoForward)
    }

    private func wait(_ condition: () -> Bool) async throws {
        for _ in 0..<150 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        Issue.record("Browser state did not settle")
    }

    private func ready(_ view: WKWebView) async throws {
        for _ in 0..<150 {
            if !view.isLoading, (try? await view.evaluateJavaScript("document.readyState")) as? String == "complete" { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        Issue.record("Fixture did not finish loading")
    }
}
