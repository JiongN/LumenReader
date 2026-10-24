import AppKit
import Combine
import WebKit
import LumenKit

@MainActor
final class CNKISearchModel: NSObject, ObservableObject, WKNavigationDelegate, WKUIDelegate {
    static let home = URL(string: "https://kns.cnki.net/kns8s/")!
    @Published var query: String
    @Published private(set) var papers: [CNKIPaper] = []
    @Published private(set) var busy = false
    @Published private(set) var message = ""
    @Published private(set) var isError = false
    @Published private(set) var history: [String] = []
    @Published private(set) var site = "kns.cnki.net"
    @Published private(set) var canGoBack = false
    @Published private(set) var canGoForward = false
    @Published var selectedID: URL?
    let webView: WKWebView
    private var work: Task<Void, Never>?
    private var generation = UUID()
    private var navigationError: Error?
    private var graphIdentity: GraphIdentity?
    private var currentGraphPaper: CNKIPaper?
    private let identity: GraphIdentity
    private let onGraph: ((CNKIPaper, [CNKIRelationBatch]) -> Bool)?
    private let navigation: ((WKWebView, URLRequest) -> Void)?

    init(query: String, persistent: Bool = true, identity: GraphIdentity? = nil,
         onGraph: ((CNKIPaper, [CNKIRelationBatch]) -> Bool)? = nil,
         navigation: ((WKWebView, URLRequest) -> Void)? = nil) {
        self.query = CNKIPage.normalizedQuery(query)
        self.identity = identity ?? GraphIdentity(title: query)
        self.onGraph = onGraph
        self.navigation = navigation
        let configuration = WKWebViewConfiguration()
        // A dedicated browser session; no Chrome/MCP cookies or EPUB scripts are imported.
        configuration.websiteDataStore = persistent
            ? WKWebsiteDataStore(forIdentifier: UUID(uuidString: "B0B61C14-746A-4A1F-B7CE-FC57E089095B")!) : .nonPersistent()
        webView = WKWebView(frame: .zero, configuration: configuration)
        super.init()
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.allowsBackForwardNavigationGestures = true
        webView.publisher(for: \.canGoBack).removeDuplicates().assign(to: &$canGoBack)
        webView.publisher(for: \.canGoForward).removeDuplicates().assign(to: &$canGoForward)
    }

    func openHome() {
        navigationError = nil
        load(URLRequest(url: Self.home, cachePolicy: .useProtocolCachePolicy, timeoutInterval: 25))
    }

    func search(forGraph: Bool = false) {
        cancel()
        graphIdentity = nil
        currentGraphPaper = nil
        guard let value = CNKIPage.searchQuery(query) else {
            setMessage("请输入 1–160 字的检索词。", error: true)
            return
        }
        graphIdentity = forGraph ? identity : nil
        query = value
        papers = []
        selectedID = nil
        busy = true
        setMessage("正在打开知网检索…")
        let token = generation
        let current = webView.url
        let homeIsReady = !webView.isLoading && current?.host == Self.home.host
            && current?.path.trimmingCharacters(in: CharacterSet(charactersIn: "/")) == "kns8s"
        if !homeIsReady { openHome() }
        else { navigationError = nil }
        work = Task { [weak self] in
            guard let self else { return }
            defer { if self.generation == token { self.busy = false; self.work = nil } }
            do {
                let deadline = ContinuousClock.now.advanced(by: .seconds(25))
                var submitted = false
                var previousPage: CNKIPage?
                while ContinuousClock.now < deadline {
                    try Task.checkCancellation()
                    guard self.generation == token else { return }
                    if let error = self.navigationError { throw error }
                    if !self.webView.isLoading, let url = self.webView.url, CNKIPage.isCNKI(url) {
                        let page: CNKIPage
                        do { page = try await self.readPage(url: url, query: value) }
                        catch SearchError.pageChanged {
                            try await Task.sleep(for: .milliseconds(500))
                            continue
                        } catch {
                            if self.webView.isLoading {
                                try await Task.sleep(for: .milliseconds(500))
                                continue
                            }
                            throw error
                        }
                        try Task.checkCancellation()
                        guard self.generation == token else { return }
                        if page.state == .verificationRequired || page.state == .loginRequired {
                            self.apply(page)
                            return
                        }
                        if !submitted, page.formReady {
                            previousPage = page
                            let data = try await self.javaScript(CNKIDOMScript.submit, arguments: ["query": value])
                            let accepted = try JSONDecoder().decode(Bool.self, from: data)
                            guard accepted else { throw SearchError.formUnavailable }
                            submitted = true
                            self.history.removeAll { $0 == value }
                            self.history.insert(value, at: 0)
                            self.history = Array(self.history.prefix(8))
                            self.setMessage("正在检索“\(value)”…")
                        } else if submitted, let previousPage, page.hasNewResults(comparedTo: previousPage) {
                            self.apply(page)
                            return
                        }
                    }
                    try await Task.sleep(for: .milliseconds(500))
                }
                self.setMessage("未能确认网页结果已更新。请在右侧核对检索词及结果后，点击“读取当前页”。", error: true)
            } catch is CancellationError {
                // A later query owns the UI; the stopped query cannot overwrite it.
            } catch {
                guard !Task.isCancelled, self.generation == token else { return }
                self.setMessage(error.localizedDescription, error: true)
            }
        }
    }

    func readCurrentPage() {
        if let paper = currentGraphPaper, graphIdentity != nil,
           let url = webView.url, CNKIPage.isCNKI(url) {
            // Keep the verified page and its already observed relation responses.
            readGraph(paper, reload: false)
            return
        }
        cancel()
        guard let url = webView.url, CNKIPage.isCNKI(url) else {
            setMessage("请先在知网页面完成登录并打开检索结果，再读取当前页。", error: true)
            return
        }
        busy = true
        let token = generation
        work = Task { [weak self] in
            guard let self else { return }
            defer { if self.generation == token { self.busy = false; self.work = nil } }
            do {
                let page = try await self.readPage(url: url, query: "")
                guard !Task.isCancelled, self.generation == token else { return }
                self.apply(page)
            } catch {
                guard !Task.isCancelled, self.generation == token else { return }
                self.setMessage(error.localizedDescription, error: true)
            }
        }
    }

    func select(_ paper: CNKIPaper) {
        selectedID = paper.id
        if graphIdentity != nil { loadGraph(paper) }
        else { load(URLRequest(url: paper.url, timeoutInterval: 25)) }
    }

    func openGraph() {
        if let url = identity.cnkiURL.flatMap({ CNKIPage.articleURL($0.absoluteString, relativeTo: $0) }) {
            loadGraph(CNKIPaper(title: identity.title, authors: identity.authors, year: identity.year,
                journal: "", citations: nil, url: url, query: identity.title), relocateIfStale: true)
        } else { query = identity.title; search(forGraph: true) }
    }

    func loadGraph(_ paper: CNKIPaper, relocateIfStale: Bool = false) {
        guard CNKIPage.articleURL(paper.url.absoluteString, relativeTo: paper.url) != nil else { return }
        readGraph(paper, reload: true, relocateIfStale: relocateIfStale)
    }

    private func readGraph(_ paper: CNKIPaper, reload: Bool, relocateIfStale: Bool = false) {
        cancel()
        graphIdentity = identity
        currentGraphPaper = paper
        selectedID = paper.id
        busy = true
        navigationError = nil
        setMessage("正在读取知网关系并定位官网图谱…")
        if reload {
            webView.configuration.userContentController.removeAllUserScripts()
            webView.configuration.userContentController.addUserScript(WKUserScript(source: CNKIGraphScript.capture,
                injectionTime: .atDocumentStart, forMainFrameOnly: true, in: .page))
            load(URLRequest(url: paper.url, timeoutInterval: 20))
        }
        let token = generation
        work = Task { [weak self] in
            guard let self else { return }
            defer { if self.generation == token { self.busy = false; self.work = nil } }
            var batches: [GraphRelation: CNKIRelationBatch] = [:]
            var focused = false
            var officialDestination: URL?
            var relationError: String?
            do {
                let deadline = ContinuousClock.now.advanced(by: .seconds(25))
                var stage = 0
                var nextStage = ContinuousClock.now
                var verifiedURL: URL?
                while ContinuousClock.now < deadline {
                    try Task.checkCancellation()
                    guard self.generation == token else { return }
                    if let error = self.navigationError { throw error }
                    if !self.webView.isLoading, let url = self.webView.url, CNKIPage.isCNKI(url) {
                        if let verifiedURL, verifiedURL != url {
                            if officialDestination == url {
                                self.setMessage("已自动打开该论文的知网图谱；当前页面未导入应用内关系。")
                                return
                            }
                            throw SearchError.pageChanged
                        }
                        let page = try await self.readPage(url: url, query: "")
                        if page.state == .verificationRequired || page.state == .loginRequired { self.apply(page); return }
                        let data = try await self.javaScript(CNKIGraphScript.read, world: .page, limit: 1_100_000)
                        let read = try JSONDecoder().decode(GraphRead.self, from: data)
                        if !read.title.isEmpty {
                            guard CNKIRelationBatch.normalizedTitle(read.title) == CNKIRelationBatch.normalizedTitle(paper.title)
                            else { throw SearchError.wrongArticle }
                            verifiedURL = url
                            if let receipt = read.receipt, receipt.page == url.absoluteString,
                               let endpoint = URL(string: receipt.endpoint) {
                                let body = Data(receipt.body.utf8)
                                let parsed = await Task.detached(priority: .utility) {
                                    Result { try CNKIRelationBatch.decode(body, endpoint: endpoint) }
                                }.value
                                try Task.checkCancellation()
                                guard self.generation == token, self.webView.url == url else { return }
                                switch parsed {
                                case .success(let batch): batches[batch.relation] = batch
                                case .failure(let error): relationError = error.localizedDescription
                                }
                            }
                            if stage < 3 && ContinuousClock.now >= nextStage {
                                let relations = ["references", "citations", "similar"]
                                let result = try await self.javaScript(CNKIGraphScript.focus,
                                    arguments: ["relation": relations[stage], "openGraph": !focused], world: .page)
                                let focus = try JSONDecoder().decode(GraphFocus.self, from: result)
                                focused = focus.found || focused
                                if let destination = focus.destination.flatMap(URL.init(string:)), CNKIPage.isCNKI(destination) {
                                    officialDestination = destination
                                }
                                stage += 1
                                nextStage = ContinuousClock.now.advanced(by: .seconds(3))
                            }
                            if stage == 3, ContinuousClock.now >= nextStage,
                               batches[.reference] != nil, batches[.citation] != nil { break }
                        }
                    }
                    try await Task.sleep(for: .milliseconds(400))
                }
                try Task.checkCancellation()
                guard self.generation == token else { return }
                if relocateIfStale, verifiedURL == nil {
                    self.query = self.identity.title
                    self.search(forGraph: true)
                    return
                }
                if batches.values.contains(where: { !$0.papers.isEmpty }) {
                    let ordered = GraphRelation.allCases.compactMap { batches[$0] }
                    // Only a confirmed title/author/year match can update this document's graph.
                    if self.onGraph?(paper, ordered) == true {
                        let count = ordered.reduce(0) { $0 + $1.papers.count }
                        self.setMessage("已读取 \(count) 条知网关系（当前批次），未加载部分不代表不存在。")
                    } else {
                        self.setMessage("已打开该论文关系；与当前题录不一致，未改写应用内图谱。", error: true)
                    }
                } else {
                    let fallback = focused ? "未取得可导入的关系数据，已自动定位官网图谱入口。"
                        : "未取得关系数据，当前页面也没有可定位的图谱入口；未生成空图谱。"
                    self.setMessage([fallback, relationError].compactMap { $0 }.joined(separator: " "), error: true)
                }
            } catch {
                guard !Task.isCancelled, self.generation == token else { return }
                if relocateIfStale, (error as? SearchError) == .wrongArticle {
                    self.query = self.identity.title
                    self.search(forGraph: true)
                    return
                }
                self.setMessage(error.localizedDescription, error: true)
            }
        }
    }

    func stop() {
        cancel()
        graphIdentity = nil
        currentGraphPaper = nil
        webView.stopLoading()
        setMessage("已停止检索。")
    }

    func close() {
        cancel()
        currentGraphPaper = nil
        webView.stopLoading()
        webView.navigationDelegate = nil
        webView.uiDelegate = nil
        webView.configuration.userContentController.removeAllUserScripts()
    }

    func navigateHistory(backward: Bool) {
        guard backward ? canGoBack : canGoForward else { return }
        cancel()
        graphIdentity = nil
        currentGraphPaper = nil
        navigationError = nil
        setMessage("")
        if backward { webView.goBack() } else { webView.goForward() }
    }

    private func cancel() { generation = UUID(); work?.cancel(); work = nil; busy = false }

    private func load(_ request: URLRequest, in target: WKWebView? = nil) {
        let target = target ?? webView
        if let navigation { navigation(target, request) }
        else { target.load(request) }
    }

    private func readPage(url: URL, query: String) async throws -> CNKIPage {
        let data = try await javaScript(CNKIDOMScript.read)
        guard let current = webView.url, current == url else { throw SearchError.pageChanged }
        return try CNKIPage.decode(data, source: current, query: query)
    }

    func javaScript(_ script: String, arguments: [String: Any] = [:],
                    world: WKContentWorld = .defaultClient, limit: Int = 256 * 1024) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            webView.callAsyncJavaScript(script, arguments: arguments, in: nil, in: world) { result in
                do {
                    let value = try result.get()
                    guard JSONSerialization.isValidJSONObject(value) || value is NSNumber else {
                        throw CNKIPage.ParseError.invalidPage
                    }
                    let data = try JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed])
                    guard data.count <= limit else { throw CNKIPage.ParseError.invalidPage }
                    continuation.resume(returning: data)
                } catch { continuation.resume(throwing: error) }
            }
        }
    }

    private func apply(_ page: CNKIPage) {
        // Keep the previous result list while a user checks a detail or completes verification.
        switch page.state {
        case .results:
            papers = page.papers
            setMessage("当前结果页 · \(papers.count) 篇题录")
            if let graphIdentity {
                if let paper = CNKIRelationBatch.uniqueMatch(papers, identity: graphIdentity) { loadGraph(paper) }
                else { setMessage("未找到唯一一致的题名、作者和年份；请选择目标论文查看图谱，不自动猜测。", error: true) }
            }
        case .noResults:
            papers = []
            setMessage("当前检索没有结果。可换用另一个关键词单独检索。")
        case .verificationRequired:
            setMessage("知网要求人工验证。请在右侧完成验证后，点击“读取当前页”。", error: true)
        case .loginRequired:
            setMessage("请在右侧登录知网或使用机构入口，再点击“读取当前页”。", error: true)
        case .unavailable:
            setMessage("当前页没有可读取的检索列表；不代表没有相关论文。", error: true)
        }
    }

    private func setMessage(_ text: String, error: Bool = false) { message = text; isError = error }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard webView === self.webView else { return }
        site = webView.url?.host ?? "知网"
        if !busy, webView.url?.path.lowercased().contains("/verify/") == true {
            setMessage("知网要求人工验证。请在右侧完成验证后，点击“读取当前页”。", error: true)
        }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        failed(webView, error: error)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        failed(webView, error: error)
    }

    private func failed(_ view: WKWebView, error: Error) {
        guard view === webView, (error as NSError).code != NSURLErrorCancelled else { return }
        navigationError = error
        if !busy { setMessage(error.localizedDescription, error: true) }
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        guard webView === self.webView else { return }
        stop()
        setMessage("知网页面进程已退出，可重新检索。阅读器未受影响。", error: true)
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void) {
        guard let url = navigationAction.request.url else { decisionHandler(.cancel); return }
        let mainFrame = navigationAction.targetFrame?.isMainFrame ?? true
        let scheme = url.scheme?.lowercased() ?? ""
        guard !navigationAction.shouldPerformDownload else {
            setMessage("下载请在系统浏览器中操作。", error: true)
            decisionHandler(.cancel)
            return
        }
        if mainFrame, let secure = CNKIPage.secureCNKIURL(url) {
            decisionHandler(.cancel)
            var request = navigationAction.request
            request.url = secure
            load(request, in: webView)
            return
        }
        let localFrame = !mainFrame && ["about", "blob", "data"].contains(scheme)
        guard scheme == "https" || url.absoluteString == "about:blank" || localFrame else {
            if mainFrame { setMessage("未打开不安全或不支持的链接，可使用系统浏览器查看原页面。", error: true) }
            decisionHandler(.cancel)
            return
        }
        if navigationAction.targetFrame == nil {
            // Keep target=_blank and window.open inside the existing browser.
            decisionHandler(.cancel)
            load(navigationAction.request)
            return
        }
        decisionHandler(.allow)
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse,
                 decisionHandler: @escaping @MainActor @Sendable (WKNavigationResponsePolicy) -> Void) {
        if navigationResponse.canShowMIMEType { decisionHandler(.allow) }
        else {
            setMessage("此链接是下载文件。请在系统浏览器中操作，尚未下载。", error: true)
            decisionHandler(.cancel)
        }
    }

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        guard navigationAction.targetFrame == nil, !navigationAction.shouldPerformDownload,
              let url = navigationAction.request.url else { return nil }
        var request = navigationAction.request
        if let secure = CNKIPage.secureCNKIURL(url) { request.url = secure }
        guard request.url?.scheme?.lowercased() == "https" else { return nil }
        load(request)
        return nil
    }

    private struct GraphRead: Decodable {
        var title: String
        var receipt: Receipt?
        struct Receipt: Decodable { var endpoint: String; var page: String; var body: String }
    }
    private struct GraphFocus: Decodable { var found: Bool; var destination: String? }

    private enum SearchError: Error, LocalizedError, Equatable {
        case formUnavailable, pageChanged, wrongArticle
        var errorDescription: String? {
            switch self {
            case .formUnavailable: "未找到知网检索表单，请在右侧网页检索后读取结果。"
            case .pageChanged: "页面已切换，请重新读取当前检索页。"
            case .wrongArticle: "知网页面题名与目标论文不一致，没有读取或覆盖当前图谱。可重新检索。"
            }
        }
    }
}
