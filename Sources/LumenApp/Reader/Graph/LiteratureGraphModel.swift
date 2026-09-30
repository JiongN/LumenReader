import Foundation
import PDFKit
import LumenKit

@MainActor
final class LiteratureGraphModel: ObservableObject {
    @Published private(set) var snapshot: LiteratureGraphSnapshot
    @Published var candidates: [GraphPaper] = []
    @Published var localCandidates: [GraphPaper] = []
    @Published var matchingLocalID: String?
    @Published var selectedID: String?
    @Published var busy = false
    @Published var message = ""
    @Published var openingText = ""
    @Published private(set) var selectedRelation: GraphRelation = .reference
    @Published var yearStart = ""

    private let document: OpenDocument
    private let file: URL
    private var work: Task<Void, Never>?
    private var layoutWork: Task<Void, Never>?
    private var layoutWorker: Task<[String: GraphPosition], Never>?
    private var generation = 0
    private var didPrepare = false

    init(document: OpenDocument) {
        self.document = document
        self.file = AppPaths.documentDirectory(forPath: document.id).appendingPathComponent("literature-graph.json")
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        if let data = try? Data(contentsOf: file),
           let saved = PersistFile.decodeOrBackup(data: data, type: LiteratureGraphSnapshot.self, fileURL: file, decoder: decoder, reason: "literature-graph.json") {
            snapshot = saved
        } else { snapshot = LiteratureGraphSnapshot() }
        selectedID = nil
    }

    var selectedPaper: GraphPaper? { snapshot.papers.first { $0.id == selectedID } }
    var rootPaper: GraphPaper? { snapshot.papers.first { $0.id == snapshot.paperID } }
    var cacheIsFresh: Bool { snapshot.fetchedAt.map { Date().timeIntervalSince($0) < 7 * 86_400 } ?? false }
    var visiblePapers: [GraphPaper] {
        GraphRelationView.papers(in: snapshot, relation: selectedRelation, yearStart: Int(yearStart))
    }

    func selectRelation(_ relation: GraphRelation) {
        selectedRelation = relation
        if let selectedID, !visiblePapers.contains(where: { $0.id == selectedID }) { self.selectedID = nil }
        if message.hasPrefix("本次展示") || message.hasPrefix("图谱已加载") { message = "" }
        guard !busy, let rootPaper else { return }
        let hasRootEdge = snapshot.edges.contains { edge in
            guard edge.relation == relation else { return false }
            switch relation {
            case .reference, .related: return edge.source == rootPaper.id
            case .citation: return edge.target == rootPaper.id
            }
        }
        guard !hasRootEdge else { return }
        if relation == .reference && rootPaper.referencedIDs.isEmpty {
            message = "OpenAlex 未提供这篇论文的参考文献。"
        } else if relation == .related && rootPaper.relatedIDs.isEmpty {
            message = "OpenAlex 未提供这篇论文的主题相关文献。"
        } else {
            expand(rootPaper, relation)
        }
    }

    func prepare(metadata: DocumentMetadata) {
        guard !didPrepare else { return }
        didPrepare = true
        let attrs = try? FileManager.default.attributesOfItem(atPath: document.url.path)
        let size = (attrs?[.size] as? NSNumber)?.int64Value ?? 0
        let modified = attrs?[.modificationDate] as? Date
        let savedStamp = snapshot.documentModified.map { Int64($0.timeIntervalSince1970) }
        let currentStamp = modified.map { Int64($0.timeIntervalSince1970) }
        if snapshot.documentSize != size || savedStamp != currentStamp {
            snapshot = LiteratureGraphSnapshot()
            snapshot.documentSize = size
            snapshot.documentModified = modified
            selectedID = nil
            candidates = []
        }
        if !snapshot.identity.title.isEmpty {
            if snapshot.layoutVersion < 2, !snapshot.papers.isEmpty {
                GraphMerge.add([], edges: [], to: &snapshot)
                recalculateLayout()
            }
            return
        }
        let url = document.url
        let kind = document.kind
        let filename = document.displayTitle
        work = Task { [weak self] in
            guard let self else { return }
            let extracted = await Task.detached(priority: .utility) {
                Self.extract(url: url, kind: kind)
            }.value
            guard !Task.isCancelled else { return }
            self.openingText = extracted.text
            let title = !metadata.title.isEmpty ? metadata.title : (!extracted.title.isEmpty ? extracted.title : filename)
            self.snapshot.identity = GraphIdentity(title: title, authors: !metadata.author.isEmpty ? [metadata.author] : extracted.authors, year: extracted.year, doi: extracted.doi, source: !metadata.title.isEmpty ? "文档属性" : (extracted.title.isEmpty ? "文件名（请核对）" : "首页文字"))
            self.save()
        }
    }

    private nonisolated static func extract(url: URL, kind: DocumentKind) -> (title: String, authors: [String], year: Int?, doi: String?, text: String) {
        guard kind == .pdf, let doc = PDFDocument(url: url) else { return ("", [], nil, nil, "") }
        var pages: [String] = []
        for index in 0..<min(2, doc.pageCount) {
            guard let page = doc.page(at: index) else { continue }
            var text = page.string ?? ""
            if text.trimmingCharacters(in: .whitespacesAndNewlines).count < 50,
               let image = PDFPageRenderer.render(page, scale: 2),
               let result = try? OCRService.recognize(in: image) { text = result.text }
            pages.append(text)
        }
        let text = pages.joined(separator: "\n")
        let doi = text.range(of: #"10\.\d{4,9}/[-._;()/:A-Z0-9]+"#, options: [.regularExpression, .caseInsensitive]).map { String(text[$0]) }
        let firstLines = (pages.first ?? "").components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        let title = firstLines.prefix(12).first { $0.count >= 12 && $0.count <= 250 && !$0.lowercased().contains("doi") && !$0.lowercased().contains("abstract") } ?? ""
        let yearString = text.range(of: #"(?:19|20)\d{2}"#, options: .regularExpression).map { String(text[$0]) }
        return (title, [], yearString.flatMap(Int.init), doi, String(text.prefix(5000)))
    }

    func updateIdentity(_ identity: GraphIdentity) {
        cancel()
        snapshot.identity = identity
        snapshot.paperID = nil
        snapshot.papers = []
        snapshot.edges = []
        snapshot.positions = [:]
        snapshot.pinnedPositionIDs = []
        candidates = []
        save()
    }

    func findCandidates() {
        cancel()
        busy = true
        message = "正在查找 OpenAlex 文献…"
        let id = snapshot.identity
        let current = generation
        work = Task { [weak self] in
            guard let self else { return }
            do {
                let found = try await OpenAlexGraphClient(apiKey: AICredentialStore.read(account: "openalex-api")).candidates(id)
                guard !Task.isCancelled, current == self.generation else { return }
                self.candidates = found
                self.message = found.isEmpty ? "OpenAlex 未收录匹配文献。可修改标题或 DOI 后重试。" : "请选择并核对当前论文。"
            } catch {
                guard !Task.isCancelled, current == self.generation else { return }
                self.message = error.localizedDescription
            }
            if current == self.generation { self.busy = false }
        }
    }

    func findViaCrossref() {
        guard !snapshot.identity.title.isEmpty else { message = "请先填写标题。"; return }
        cancel()
        busy = true
        message = "正在用 Crossref 补充 DOI…"
        let title = snapshot.identity.title
        let current = generation
        work = Task { [weak self] in
            guard let self else { return }
            let response = await WebLiteratureSearch.crossref(title, timeout: 10)
            guard !Task.isCancelled, current == self.generation else { return }
            switch response {
            case .failure(let error): self.message = "Crossref：\(error.localizedDescription)"
            case .success(let hits):
                let client = OpenAlexGraphClient(apiKey: AICredentialStore.read(account: "openalex-api"))
                var found: [GraphPaper] = []
                for hit in hits {
                    guard let doi = GraphIdentity.normalizedDOI(hit.identifier) else { continue }
                    if let paper = try? await client.work(id: "https://doi.org/\(doi)") { found.append(paper) }
                }
                guard !Task.isCancelled, current == self.generation else { return }
                self.candidates = found
                self.message = found.isEmpty ? "Crossref 找到了元信息，但 OpenAlex 未收录可构图的论文。" : "Crossref 补充 DOI 后找到以下 OpenAlex 论文，请核对。"
            }
            if current == self.generation { self.busy = false }
        }
    }

    func confirm(_ paper: GraphPaper) {
        cancel()
        let localReferences = snapshot.papers.filter { $0.id.hasPrefix("local:reference:") }
        snapshot.paperID = paper.id
        snapshot.papers = [paper]
        snapshot.edges = []
        snapshot.positions = [paper.id: GraphPosition(x: 0, y: 0)]
        snapshot.pinnedPositionIDs = []
        GraphMerge.add(localReferences, edges: localReferences.map {
            GraphEdge(source: paper.id, target: $0.id, relation: .reference, provider: "PDF 参考文献")
        }, to: &snapshot)
        snapshot.fetchedAt = Date()
        selectedID = nil
        candidates = []
        save()
        loadInitial(paper)
    }

    private func loadInitial(_ paper: GraphPaper) {
        cancel()
        busy = true
        message = "正在加载参考和被引文献…"
        let current = generation
        work = Task { [weak self] in
            guard let self else { return }
            let client = OpenAlexGraphClient(apiKey: AICredentialStore.read(account: "openalex-api"))
            for relation in [GraphRelation.reference, .citation] {
                do {
                    let found = try await client.neighbors(of: paper, relation: relation)
                    guard !Task.isCancelled, current == self.generation else { return }
                    let edges = found.map { neighbor in
                        relation == .reference
                            ? GraphEdge(source: paper.id, target: neighbor.id, relation: relation)
                            : GraphEdge(source: neighbor.id, target: paper.id, relation: relation)
                    }
                    GraphMerge.add(found, edges: edges, to: &self.snapshot)
                    self.snapshot.fetchedAt = Date()
                    self.recalculateLayout()
                    self.save()
                } catch {
                    guard !Task.isCancelled, current == self.generation else { return }
                    self.message = "\(relation.title)：\(error.localizedDescription)"
                }
            }
            if current == self.generation {
                self.busy = false
                if self.message.hasPrefix("正在") { self.message = "" }
                if self.selectedRelation == .related { self.selectRelation(.related) }
            }
        }
    }

    func identifyWithAI(config: AIProviderConfig?) {
        guard let config, config.isConfigured else { message = "请先在 AI 设置中配置服务商与模型。"; return }
        guard !openingText.isEmpty else { message = "没有可用于 AI 识别的首页文字。"; return }
        cancel()
        busy = true
        message = "正在识别标题和作者…"
        let current = generation
        let excerpt = String(openingText.prefix(2500))
        work = Task { [weak self] in
            guard let self else { return }
            do {
                let provider = OpenAICompatibleProvider(config: config, apiKey: AICredentialStore.read(account: config.keychainAccount) ?? "")
                let raw = try await provider.completeText(messages: [
                    .system("从论文首页文字提取元信息。仅输出 JSON 对象，字段 title、authors（字符串数组）、year（整数或 null）、doi（字符串或 null）；不猜测缺失内容。"),
                    .user(excerpt)
                ])
                guard !Task.isCancelled, current == self.generation else { return }
                let start = raw.firstIndex(of: "{")
                let end = raw.lastIndex(of: "}")
                guard let start, let end, let data = String(raw[start...end]).data(using: .utf8),
                      let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    self.message = "模型未返回可解析的元信息，请手动修订。"
                    self.busy = false
                    return
                }
                var identity = self.snapshot.identity
                if let title = json["title"] as? String, !title.isEmpty { identity.title = title }
                if let authors = json["authors"] as? [String], !authors.isEmpty { identity.authors = authors }
                if let year = json["year"] as? Int { identity.year = year }
                if let doi = GraphIdentity.normalizedDOI(json["doi"] as? String) { identity.doi = doi }
                identity.source = "AI 建议（请核对）"
                self.snapshot.identity = identity
                self.save()
                self.message = "已填入 AI 识别结果，请核对后查找匹配文献。"
            } catch {
                guard !Task.isCancelled, current == self.generation else { return }
                self.message = error.localizedDescription
            }
            if current == self.generation { self.busy = false }
        }
    }

    func expand(_ paper: GraphPaper, _ relation: GraphRelation) {
        guard !paper.id.hasPrefix("local:") else {
            message = "请先选中这条本地引文，在图谱内查找并核对题录。"
            return
        }
        guard snapshot.papers.count < GraphMerge.limit else { message = "图谱已达 150 篇上限。"; return }
        cancel()
        busy = true
        message = "正在加载\(relation.title)…"
        let current = generation
        work = Task { [weak self] in
            guard let self else { return }
            do {
                let client = OpenAlexGraphClient(apiKey: AICredentialStore.read(account: "openalex-api"))
                let found = try await client.neighbors(of: paper, relation: relation)
                guard !Task.isCancelled, current == self.generation else { return }
                let edges = found.map { neighbor in
                    switch relation {
                    case .reference: GraphEdge(source: paper.id, target: neighbor.id, relation: relation)
                    case .citation: GraphEdge(source: neighbor.id, target: paper.id, relation: relation)
                    case .related: GraphEdge(source: paper.id, target: neighbor.id, relation: relation)
                    }
                }
                GraphMerge.add(found, edges: edges, to: &self.snapshot)
                self.snapshot.fetchedAt = Date()
                self.recalculateLayout()
                self.message = found.isEmpty ? "未找到\(relation.title)。" : ""
                self.save()
            } catch {
                guard !Task.isCancelled, current == self.generation else { return }
                self.message = error.localizedDescription
            }
            if current == self.generation { self.busy = false }
        }
    }

    func findLocalMatch(_ paper: GraphPaper, query: String) {
        guard paper.id.hasPrefix("local:reference:") else { return }
        let title = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty || paper.doi != nil else { message = "请填写用于查找的标题。"; return }
        cancel()
        matchingLocalID = paper.id
        localCandidates = []
        busy = true
        message = "正在匹配本地引文…"
        let current = generation
        work = Task { [weak self] in
            guard let self else { return }
            do {
                let identity = GraphIdentity(title: title, doi: paper.doi, source: "PDF 参考文献")
                let found = try await OpenAlexGraphClient(apiKey: AICredentialStore.read(account: "openalex-api")).candidates(identity)
                guard !Task.isCancelled, current == self.generation else { return }
                self.localCandidates = found
                self.message = found.isEmpty ? "OpenAlex 未找到候选；本地引用关系仍保留。可修改标题重试。" : "请核对候选题录，确认后才能继续扩展该文献。"
            } catch {
                guard !Task.isCancelled, current == self.generation else { return }
                self.message = error.localizedDescription
            }
            if current == self.generation { self.busy = false }
        }
    }

    func confirmLocalMatch(_ paper: GraphPaper) {
        guard let localID = matchingLocalID,
              snapshot.papers.contains(where: { $0.id == localID }) else { return }
        cancel()
        GraphMerge.resolveLocalReference(localID, with: paper, in: &snapshot)
        selectedID = snapshot.papers.first { $0.id == paper.id || (paper.doi != nil && $0.doi == paper.doi) }?.id
        matchingLocalID = nil
        localCandidates = []
        recalculateLayout()
        save()
        message = "已核对本地引文，可在节点详情继续加载关系。"
    }

    func refresh() {
        if let rootPaper, !rootPaper.id.hasPrefix("local:") { expand(rootPaper, selectedRelation) }
        else { findCandidates() }
    }

    func extractReferencesFromPDF() {
        guard document.kind == .pdf else { message = "仅 PDF 支持提取文内参考文献。"; return }
        cancel()
        busy = true
        message = "正在读取末尾的参考文献表…"
        let current = generation
        let url = document.url
        work = Task { [weak self] in
            guard let self else { return }
            let citations = await Task.detached(priority: .utility) {
                Self.localReferences(at: url)
            }.value
            guard !Task.isCancelled, current == self.generation else { return }
            guard !citations.isEmpty else {
                self.message = "末尾未找到可识别的编号参考文献；可修订标题后检索 OpenAlex。"
                self.busy = false
                return
            }
            if self.snapshot.paperID == nil {
                let identity = self.snapshot.identity
                let root = GraphPaper(id: "local:current", doi: identity.doi,
                    title: identity.title.isEmpty ? self.document.displayTitle : identity.title,
                    authors: identity.authors, year: identity.year, venue: "当前 PDF",
                    abstract: "", openAccessURL: nil, referencedIDs: [], relatedIDs: [], citedByCount: 0)
                self.snapshot.paperID = root.id
                self.snapshot.papers = [root]
                self.snapshot.positions = [root.id: GraphPosition(x: 0, y: 0)]
                self.selectedID = nil
            }
            guard let rootID = self.snapshot.paperID else { return }
            let papers = citations.map { citation -> GraphPaper in
                let hash = citation.utf8.reduce(UInt64(14_695_981_039_346_656_037)) {
                    ($0 ^ UInt64($1)) &* 1_099_511_628_211
                }
                return GraphPaper(id: "local:reference:\(String(hash, radix: 16))",
                    doi: LocalReferenceParser.doi(in: citation), title: citation,
                    authors: [], year: nil, venue: "本文参考文献表", abstract: "",
                    openAccessURL: nil, referencedIDs: [], relatedIDs: [], citedByCount: 0)
            }
            GraphMerge.add(papers, edges: papers.map {
                GraphEdge(source: rootID, target: $0.id, relation: .reference, provider: "PDF 参考文献")
            }, to: &self.snapshot)
            self.recalculateLayout()
            self.save()
            self.message = "已从本文参考文献表加入 \(papers.count) 条引文；题录身份仍需核对。"
            self.busy = false
        }
    }

    private nonisolated static func localReferences(at url: URL) -> [String] {
        guard let document = PDFDocument(url: url), document.pageCount > 0 else { return [] }
        let first = max(0, document.pageCount - 12)
        var pages: [String] = []
        for index in first..<document.pageCount {
            if Task.isCancelled { return [] }
            guard let page = document.page(at: index) else { continue }
            var text = page.string ?? ""
            if text.trimmingCharacters(in: .whitespacesAndNewlines).count < 30,
               let image = PDFPageRenderer.render(page, scale: 2),
               let result = try? OCRService.recognize(in: image) { text = result.text }
            pages.append(text)
        }
        return LocalReferenceParser.parse(pages.joined(separator: "\n"))
    }

    func cancel() {
        generation += 1
        work?.cancel()
        layoutWork?.cancel()
        layoutWorker?.cancel()
        work = nil
        layoutWork = nil
        layoutWorker = nil
        busy = false
    }

    func moveNode(_ id: String, to position: GraphPosition) {
        guard snapshot.papers.contains(where: { $0.id == id }),
              position.x.isFinite, position.y.isFinite else { return }
        snapshot.positions[id] = position
        snapshot.pinnedPositionIDs.insert(id)
        save()
    }

    private func recalculateLayout() {
        layoutWork?.cancel()
        layoutWorker?.cancel()
        let papers = snapshot.papers
        let edges = snapshot.edges
        let rootID = snapshot.paperID
        let current = generation
        let worker = Task.detached(priority: .utility) {
            GraphLayout.positions(papers: papers, edges: edges, rootID: rootID)
        }
        layoutWorker = worker
        layoutWork = Task { [weak self] in
            let positions = await worker.value
            guard let self, !Task.isCancelled, current == self.generation else { return }
            var finalPositions = positions
            for id in self.snapshot.pinnedPositionIDs {
                if let pinned = self.snapshot.positions[id], finalPositions[id] != nil {
                    finalPositions[id] = pinned
                }
            }
            self.snapshot.positions = finalPositions
            self.snapshot.layoutVersion = 2
            self.save()
        }
    }

    private func save() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(snapshot) else { return }
        _ = PersistFile.write(data, to: file, label: "literature-graph.json")
    }
}
