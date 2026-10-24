import AppKit
import WebKit
import Testing
import LumenKit
@testable import LumenApp

@Suite("知网图谱浏览器与导入", .serialized)
@MainActor
struct CNKIGraphBrowserTests {
    private let article = URL(string: "https://kns.cnki.net/kcms2/article/abstract?filename=ROOT")!
    private let endpoint = URL(string: "https://kns.cnki.net/restapi/citation-api/v1/literature/references")!

    @Test func pageResponseCaptureUsesOnlyObservedAllowlistedData() async throws {
        let model = CNKISearchModel(query:"测试", persistent:false)
        defer { model.close() }
        model.webView.loadHTMLString("<h1>中文论文</h1>", baseURL:article)
        try await ready(model.webView)
        // A response fixture, not a real CNKI request or a cookie transfer.
        _ = try await model.webView.evaluateJavaScript(#"""
        window.fetch = async url => {
          const response = new Response(JSON.stringify({data:{data:[{metadata:[{name:'TI',value:'参考论文'}]}]}}));
          Object.defineProperty(response, 'url', {value:String(url)}); return response;
        };
        true;
        """#)
        _ = try await model.webView.evaluateJavaScript(CNKIGraphScript.capture)
        _ = try await model.webView.evaluateJavaScript("fetch('https://evil.example/restapi/citation-api/v1/literature/references'); fetch('\(endpoint.absoluteString)'); true;")
        var receipt: [String:Any]?
        for _ in 0..<80 where receipt == nil {
            let data = try await model.javaScript(CNKIGraphScript.read, world:.page)
            receipt = (try JSONSerialization.jsonObject(with:data) as? [String:Any])?["receipt"] as? [String:Any]
            if receipt == nil { try await Task.sleep(for:.milliseconds(20)) }
        }
        let response = try #require(receipt)
        #expect(response["endpoint"] as? String == endpoint.absoluteString)
        #expect(response["page"] as? String == article.absoluteString)
        let batch = try CNKIRelationBatch.decode(Data(try #require(response["body"] as? String).utf8), endpoint:endpoint)
        #expect(batch.papers.first?.title == "参考论文")
        let empty = try await model.javaScript(CNKIGraphScript.read, world:.page)
        #expect((try JSONSerialization.jsonObject(with:empty) as? [String:Any])?["receipt"] is NSNull)
    }

    @Test func officialGraphIsFocusedWithoutAnExtraUserClick() async throws {
        let model = CNKISearchModel(query:"测试", persistent:false)
        defer { model.close() }
        model.webView.frame = .init(x:0,y:0,width:800,height:600)
        model.webView.loadHTMLString(#"""
        <h1>中文论文</h1><a href="javascript:void(0)" onclick="window.graphOpened=true">引文网络</a>
        <ul><li data-id="references" onclick="window.referencesClicked=true">参考文献</li>
        <li data-id="citations" onclick="window.citationsClicked=true">引证文献</li></ul>
        """#, baseURL:article)
        try await ready(model.webView)
        let data = try await model.javaScript(CNKIGraphScript.focus, arguments:["relation":"citations"], world:.page)
        #expect((try JSONSerialization.jsonObject(with:data) as? [String:Any])?["found"] as? Bool == true)
        #expect(try await model.webView.evaluateJavaScript("window.graphOpened === true && window.citationsClicked === true && !window.referencesClicked") as? Bool == true)
    }

    @Test func hostilePageStateIsBoundedBeforeCrossingTheWebKitBridge() async throws {
        let model = CNKISearchModel(query:"测试",persistent:false)
        defer { model.close() }
        model.webView.loadHTMLString("<h1>测试论文</h1><meta name='citation_author' content='作者'>",baseURL:article)
        try await ready(model.webView)
        _ = try await model.webView.evaluateJavaScript(#"""
        document.querySelector('meta').content = '字'.repeat(200000);
        window.__lumenRelations = {entries:new Map([['untrusted', {endpoint:location.href,page:location.href,body:'x'.repeat(600000)}]])};
        true;
        """#)
        let data = try await model.javaScript(CNKIGraphScript.read,world:.page)
        let result = try #require(JSONSerialization.jsonObject(with:data) as? [String:Any])
        #expect(data.count < 4096 && result["receipt"] is NSNull)
        #expect((result["authors"] as? [String])?.first?.count == 100)
    }

    @Test func offsiteAndHiddenGraphEntriesAreNotClicked() async throws {
        let model = CNKISearchModel(query:"测试", persistent:false)
        defer { model.close() }
        model.webView.frame = .init(x:0,y:0,width:800,height:600)
        model.webView.loadHTMLString("<a style='display:none' onclick='window.clicked=true'>引文网络</a><a href='https://evil.example/' onclick='window.clicked=true'>引文网络</a>", baseURL:article)
        try await ready(model.webView)
        let hidden = try await model.javaScript(CNKIGraphScript.focus, arguments:["relation":"references"], world:.page)
        #expect((try JSONSerialization.jsonObject(with:hidden) as? [String:Any])?["found"] as? Bool == false)
        model.webView.loadHTMLString("<a onclick='window.clicked=true'>引文网络</a>", baseURL:URL(string:"https://example.org/"))
        try await ready(model.webView)
        let offsite = try await model.javaScript(CNKIGraphScript.focus, arguments:["relation":"references"], world:.page)
        #expect((try JSONSerialization.jsonObject(with:offsite) as? [String:Any])?["found"] as? Bool == false)
    }

    @Test func nativeGraphPreservesDirectionSourceAndCurrentDocument() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
        defer { try? FileManager.default.removeItem(at:directory) }
        let model = LiteratureGraphModel(document:.init(url:directory.appendingPathComponent("book.pdf"),kind:.pdf),storageURL:directory.appendingPathComponent("graph.json"))
        let paper = CNKIPaper(title:"根论文",authors:["张三"],year:2024,journal:"",citations:nil,url:article,query:"")
        model.updateIdentity(paper.identity)
        let body = Data(#"{"data":{"total":3,"data":[{"metadata":[{"name":"TI","value":"邻居论文"},{"name":"AU","value":"李四"},{"name":"YE","value":"2023"}]}]}}"#.utf8)
        let reference = try CNKIRelationBatch.decode(body,endpoint:endpoint)
        let citation = try CNKIRelationBatch.decode(body,endpoint:URL(string:"https://kns.cnki.net/restapi/citation-api/v1/literature/citations")!)
        #expect(model.importCNKI(paper,batches:[reference,citation]))
        let root = try #require(model.snapshot.paperID), neighbor = try #require(reference.papers.first?.id)
        #expect(model.snapshot.edges.contains(GraphEdge(source:root,target:neighbor,relation:.reference,provider:"CNKI")))
        #expect(model.snapshot.edges.contains(GraphEdge(source:neighbor,target:root,relation:.citation,provider:"CNKI")))
        #expect(model.snapshot.edges.allSatisfy { $0.provider == "CNKI" })
        #expect(model.snapshot.identity.cnkiURL == article)
        let before = model.snapshot.papers
        let wrong = CNKIPaper(title:"其他论文",authors:[],year:nil,journal:"",citations:nil,url:article,query:"")
        #expect(!model.importCNKI(wrong,batches:[reference]))
        #expect(model.snapshot.papers == before && model.snapshot.paperID == root)
        let reopened = LiteratureGraphModel(document:.init(url:directory.appendingPathComponent("book.pdf"),kind:.pdf),storageURL:directory.appendingPathComponent("graph.json"))
        #expect(reopened.snapshot.identity.cnkiURL == article && reopened.snapshot.edges == model.snapshot.edges)
        model.cancel()
    }

    @Test func linkedLocalRootRefreshAndCitationsUseCNKIWithoutChangingItsIdentity() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("graph.json")
        var snapshot = LiteratureGraphSnapshot()
        snapshot.identity = .init(title: "已关联中文论文", authors: ["张三"], year: 2024, cnkiURL: article)
        snapshot.paperID = "local:current"
        let root = GraphPaper(id: "local:current", doi: nil, title: snapshot.identity.title, authors: ["张三"], year: 2024,
                              venue: "当前 PDF", abstract: "", openAccessURL: nil, referencedIDs: [], relatedIDs: [], citedByCount: 0)
        var unresolved = root
        unresolved.id = "local:reference:unmatched"
        unresolved.title = "未核对的另一篇引文"
        snapshot.papers = [root, unresolved]
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(snapshot).write(to: file)
        var requests: [GraphPaper?] = []
        let model = LiteratureGraphModel(document: .init(url: directory.appendingPathComponent("book.pdf"), kind: .pdf),
                                        storageURL: file, openCNKI: { requests.append($0) })
        #expect(model.cnkiURL(for: root) == article && model.usesCNKIRelations(for: root))
        #expect(model.cnkiURL(for: unresolved) == nil && !model.usesCNKIRelations(for: unresolved))
        model.selectRelation(.citation)
        #expect(model.message == "被引文献尚未读取。")
        #expect(!model.busy && model.candidates.isEmpty)
        model.refresh()
        model.expand(root, .citation)
        #expect(requests.count == 2 && requests.allSatisfy { $0 == nil })
        model.expand(unresolved, .citation)
        #expect(requests.count == 2)
        #expect(model.snapshot.identity == snapshot.identity && model.snapshot.paperID == root.id)
        var openAlexRoot = root; openAlexRoot.id = "W1"
        #expect(!model.usesCNKIRelations(for: openAlexRoot))
        model.cancel()
    }

    @Test func observedRelationsCompleteTheOneClickWorkflow() async throws {
        var imported: [CNKIRelationBatch] = []
        let paper = CNKIPaper(title:"根论文",authors:[],year:nil,journal:"",citations:nil,url:article,query:"")
        let model = CNKISearchModel(query:paper.title,persistent:false,identity:paper.identity,
            onGraph:{ _, batches in imported = batches; return true },navigation:{ _,_ in })
        defer { model.close() }
        model.loadGraph(paper)
        model.webView.frame = .init(x:0,y:0,width:800,height:600)
        model.webView.loadHTMLString(#"""
        <h1>根论文</h1><ul><li data-id="references">参考文献</li><li data-id="citations">引证文献</li></ul>
        <script>
        for (const relation of ['references','citations']) {
          const endpoint = 'https://kns.cnki.net/restapi/citation-api/v1/literature/' + relation;
          window.__lumenRelations.entries.set(relation, {endpoint, page:location.href,
            body:JSON.stringify({data:{total:1,data:[{metadata:[{name:'TI',value:relation+'论文'}]}]}})});
        }
        </script>
        """#,baseURL:article)
        for _ in 0..<650 where model.busy { try await Task.sleep(for:.milliseconds(20)) }
        #expect(!model.busy && imported.count == 2)
        #expect(Set(imported.map(\.relation)) == [.reference,.citation])
        #expect(model.message.contains("2 条知网关系"))
    }

    @Test func aNewInvalidQueryCancelsOlderGraphWork() async throws {
        var imports = 0
        let model = CNKISearchModel(query:"测试",persistent:false,onGraph:{ _,_ in imports += 1; return true },navigation:{ _,_ in })
        defer { model.close() }
        model.loadGraph(CNKIPaper(title:"测试",authors:[],year:nil,journal:"",citations:nil,url:article,query:""))
        model.query = ""
        model.search()
        try await Task.sleep(for:.milliseconds(50))
        #expect(!model.busy && imports == 0 && model.message.contains("1–160"))
    }

    @Test func verifiedArticleResumesRelationsInPlaceWithoutReloading() async throws {
        var imports: [CNKIRelationBatch] = []
        var navigations = 0
        let paper = CNKIPaper(title: "验证后论文", authors: [], year: nil, journal: "",
                              citations: nil, url: article, query: "")
        let model = CNKISearchModel(query: paper.title, persistent: false, identity: paper.identity,
            onGraph: { _, batches in imports = batches; return true }, navigation: { view, request in
                navigations += 1
                view.loadHTMLString("<p>请完成安全验证</p>", baseURL: request.url)
            })
        defer { model.close() }
        model.webView.frame = .init(x: 0, y: 0, width: 800, height: 600)
        model.loadGraph(paper)
        for _ in 0..<150 where model.busy { try await Task.sleep(for: .milliseconds(20)) }
        #expect(!model.busy && model.message.contains("知网要求人工验证"))
        // A local fixture transition, not an automated website verification.
        model.webView.loadHTMLString(#"""
        <h1>验证后论文</h1><ul><li data-id="references">参考文献</li><li data-id="citations">引证文献</li></ul>
        <script>
        for (const relation of ['references','citations']) {
          window.__lumenRelations.entries.set(relation, {
            endpoint:'https://kns.cnki.net/restapi/citation-api/v1/literature/' + relation,
            page:location.href,
            body:JSON.stringify({data:{total:1,data:[{metadata:[{name:'TI',value:relation+'真实题录格式'}]}]}})
          });
        }
        </script>
        """#, baseURL: article)
        try await ready(model.webView)
        model.readCurrentPage()
        for _ in 0..<650 where model.busy { try await Task.sleep(for: .milliseconds(20)) }
        #expect(!model.busy && navigations == 1)
        #expect(Set(imports.map(\.relation)) == [.reference, .citation])
        #expect(model.message.contains("2 条知网关系"))
    }

    @Test func resumedArticleStillChecksTitleAndStopDoesNotResume() async throws {
        var imports = 0
        var navigations = 0
        let paper = CNKIPaper(title: "目标论文", authors: [], year: nil, journal: "",
                              citations: nil, url: article, query: "")
        let model = CNKISearchModel(query: paper.title, persistent: false, identity: paper.identity,
            onGraph: { _, _ in imports += 1; return true }, navigation: { view, request in
                navigations += 1
                view.loadHTMLString("<p>请完成安全验证</p>", baseURL: request.url)
            })
        defer { model.close() }
        model.loadGraph(paper)
        for _ in 0..<150 where model.busy { try await Task.sleep(for: .milliseconds(20)) }
        model.webView.loadHTMLString("<h1>不相关论文</h1>", baseURL: article)
        try await ready(model.webView)
        model.readCurrentPage()
        for _ in 0..<150 where model.busy { try await Task.sleep(for: .milliseconds(20)) }
        #expect(!model.busy && model.isError && imports == 0 && navigations == 1)
        #expect(model.message.contains("题名"))
        model.stop()
        model.webView.loadHTMLString("<h1>目标论文</h1>", baseURL: article)
        try await ready(model.webView)
        model.readCurrentPage()
        for _ in 0..<100 where model.busy { try await Task.sleep(for: .milliseconds(20)) }
        #expect(!model.busy && imports == 0 && navigations == 1)
        #expect(model.message.contains("没有可读取的检索列表"))
    }

    @Test func closingGraphWorkCancelsWithoutPublishingOrRetainingBrowser() async throws {
        weak var released: CNKISearchModel?
        var imports = 0
        do {
            let model = CNKISearchModel(query:"测试",persistent:false,onGraph:{ _,_ in imports += 1; return true },navigation:{ _,_ in })
            released = model
            model.loadGraph(CNKIPaper(title:"测试",authors:[],year:nil,journal:"",citations:nil,url:article,query:""))
            model.close()
        }
        for _ in 0..<80 where released != nil { try await Task.sleep(for:.milliseconds(20)) }
        #expect(released == nil && imports == 0)
    }

    @Test func anExpiredSavedLinkAutomaticallyRelocatesOnceWithoutImportingTheWrongPaper() async throws {
        var requested: [URL] = []
        var imports = 0
        let identity = GraphIdentity(title:"目标论文",cnkiURL:article)
        let model = CNKISearchModel(query:"旧输入",persistent:false,identity:identity,
            onGraph:{ _,_ in imports += 1; return true },navigation:{ view,request in
                if let url = request.url { requested.append(url) }
                if request.url?.path.contains("/article/") == true {
                    view.loadHTMLString("<h1>旧地址已失效</h1>",baseURL:request.url)
                }
            })
        defer { model.close() }
        model.openGraph()
        for _ in 0..<100 where requested.count < 2 { try await Task.sleep(for:.milliseconds(20)) }
        #expect(requested == [article,CNKISearchModel.home])
        #expect(model.query == identity.title && imports == 0)
        model.stop()
    }

    private func ready(_ view: WKWebView) async throws {
        for _ in 0..<150 {
            if !view.isLoading, (try? await view.evaluateJavaScript("document.readyState")) as? String == "complete" { return }
            try await Task.sleep(for:.milliseconds(20))
        }
        Issue.record("Graph fixture did not finish loading")
    }
}
