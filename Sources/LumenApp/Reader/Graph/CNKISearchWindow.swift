import AppKit
import SwiftUI
import WebKit
import LumenKit

@MainActor
final class CNKISearchWindowPresenter: NSObject, NSWindowDelegate {
    static let shared = CNKISearchWindowPresenter()
    private var window: NSWindow?
    private var search: CNKISearchModel?
    private var owner: ObjectIdentifier?

    func show(for graph: LiteratureGraphModel, graphRequested: Bool = false, paper: GraphPaper? = nil) {
        if owner == ObjectIdentifier(graph), let window, let search {
            window.makeKeyAndOrderFront(nil)
            if let paper, let url = paper.openAccessURL {
                search.loadGraph(CNKIPaper(title: paper.title, authors: paper.authors, year: paper.year,
                    journal: paper.venue, citations: paper.citedByCount, url: url, query: paper.title))
            } else if graphRequested { search.openGraph() }
            return
        }
        window?.close()
        let available = (NSApp.keyWindow?.screen ?? NSScreen.main)?.visibleFrame
            ?? .init(x: 0, y: 0, width: 1440, height: 900)
        let size = CGSize(width: min(1280, available.width * 0.92), height: min(900, available.height * 0.88))
        let window = CNKISearchWindow(contentRect: .init(origin: .zero, size: size),
            styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        let model = CNKISearchModel(query: graph.snapshot.identity.title, persistent: !LaunchOptions.isAuditRun,
            identity: graph.snapshot.identity, onGraph: { [weak graph, weak window] paper, batches in
                let imported = graph?.importCNKI(paper, batches: batches) ?? false
                if imported { DispatchQueue.main.async { [weak window] in window?.close() } }
                return imported
            })
        window.title = "知网 · 文献图谱"
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.contentMinSize = .init(width: min(880, available.width), height: min(520, available.height))
        window.contentView = NSHostingView(rootView: CNKISearchView(model: model,
            currentTitle: graph.snapshot.identity.title) { [weak self, weak graph] paper in
                graph?.updateIdentity(paper.identity)
                self?.window?.close()
            })
        window.setFrameOrigin(.init(x: available.midX - window.frame.width / 2,
                                   y: available.midY - window.frame.height / 2))
        self.window = window
        search = model
        owner = ObjectIdentifier(graph)
        window.makeKeyAndOrderFront(nil)
        if let paper, let url = paper.openAccessURL {
            model.loadGraph(CNKIPaper(title: paper.title, authors: paper.authors, year: paper.year,
                journal: paper.venue, citations: paper.citedByCount, url: url, query: paper.title))
        } else if graphRequested { model.openGraph() }
        else { model.openHome() }
    }

    func windowWillClose(_ notification: Notification) {
        search?.close()
        search = nil
        window = nil
        owner = nil
    }
}

private final class CNKISearchWindow: NSWindow {
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.charactersIgnoringModifiers?.lowercased() == "w",
           event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command {
            performClose(nil)
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}

struct CNKISearchView: View {
    @ObservedObject var model: CNKISearchModel
    let currentTitle: String
    let onUse: (CNKIPaper) -> Void
    @State private var pendingImport: CNKIPaper?

    private var selected: CNKIPaper? { model.papers.first { $0.id == model.selectedID } }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: DS.Space.m) {
                CNKIQueryField(text: $model.query) { model.search() }
                    .frame(height: 28)
                if !model.history.isEmpty {
                    Menu("检索记录", systemImage: "clock.arrow.circlepath") {
                        ForEach(model.history, id: \.self) { value in
                            Button(value) { model.query = value; model.search() }
                        }
                    }.menuStyle(.borderlessButton).fixedSize().labelStyle(.iconOnly).help("最近检索词")
                }
                Button(model.busy ? "停止检索" : "检索", systemImage: model.busy ? "stop.fill" : "arrow.right") {
                    if model.busy { model.stop() } else { model.search() }
                }.labelStyle(.iconOnly).help(model.busy ? "停止检索" : "检索知网")
                    .keyboardShortcut(.return, modifiers: .command)
            }
            .padding(.horizontal, DS.Space.l).padding(.vertical, DS.Space.m)
            Divider()
            HSplitView {
                results.frame(minWidth: 280, idealWidth: 330, maxWidth: 440)
                VStack(spacing: 0) {
                    HStack(spacing: DS.Space.m) {
                        Button("后退", systemImage: "chevron.left") { model.navigateHistory(backward: true) }
                            .labelStyle(.iconOnly).help("后退").disabled(!model.canGoBack)
                        Button("前进", systemImage: "chevron.right") { model.navigateHistory(backward: false) }
                            .labelStyle(.iconOnly).help("前进").disabled(!model.canGoForward)
                        Label(model.site, systemImage: "globe").font(DS.Typo.callout).lineLimit(1)
                        Spacer(minLength: DS.Space.s)
                        Button("读取当前页", systemImage: "arrow.down.document") { model.readCurrentPage() }
                            .disabled(model.busy).help("读取当前网页的题录或论文关系；不下载全文")
                        Button("在浏览器中打开", systemImage: "safari") {
                            if let url = model.webView.url, url.scheme == "https" { NSWorkspace.shared.open(url) }
                        }.labelStyle(.iconOnly).help("在系统浏览器中打开当前网页")
                    }.padding(DS.Space.m)
                    Divider()
                    CNKIWebView(webView: model.webView)
                }.frame(minWidth: 460, maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(DS.Palette.surfaceSunken)
        .tint(DS.Palette.accent)
        .onChange(of: model.selectedID) { _, _ in pendingImport = nil }
    }

    private var results: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("知网题录").font(DS.Typo.headline)
                Text("\(model.papers.count)").font(DS.Typo.callout).foregroundStyle(DS.Palette.textSecondary)
                Spacer()
                if model.busy { ProgressView().controlSize(.small) }
            }.padding(DS.Space.l)
            if !model.message.isEmpty {
                Text(model.message).font(DS.Typo.callout)
                    .foregroundStyle(model.isError ? DS.Palette.warning : DS.Palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, DS.Space.l).padding(.bottom, DS.Space.m)
            }
            Divider()
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(model.papers) { paper in
                        Button { model.select(paper) } label: {
                            VStack(alignment: .leading, spacing: DS.Space.s) {
                                Text(paper.title).font(DS.Typo.body.weight(.medium)).lineLimit(4)
                                    .foregroundStyle(DS.Palette.textPrimary)
                                Text([paper.authors.prefix(3).joined(separator: "、"), paper.year.map(String.init) ?? ""]
                                    .filter { !$0.isEmpty }.joined(separator: " · "))
                                    .font(DS.Typo.callout).foregroundStyle(DS.Palette.textSecondary)
                                if !paper.journal.isEmpty {
                                    Text(paper.journal).font(DS.Typo.callout).foregroundStyle(DS.Palette.textSecondary)
                                }
                            }
                            .multilineTextAlignment(.leading).frame(maxWidth: .infinity, alignment: .leading)
                            .padding(DS.Space.l)
                            .background(model.selectedID == paper.id ? DS.Palette.accentSoft : .clear)
                            .contentShape(Rectangle())
                        }.buttonStyle(.plain).accessibilityAddTraits(model.selectedID == paper.id ? [.isSelected] : [])
                        Divider().padding(.horizontal, DS.Space.l)
                    }
                }
            }
            Divider()
            VStack(alignment: .leading, spacing: DS.Space.s) {
                if let paper = pendingImport {
                    Text("替换当前题录？").font(DS.Typo.headline)
                    Text(paper.title).font(DS.Typo.body).fixedSize(horizontal: false, vertical: true)
                    Text("重建图谱匹配，原文和批注不变。")
                        .font(DS.Typo.callout).foregroundStyle(DS.Palette.textSecondary)
                        .help("当前题录：\(currentTitle)")
                    HStack {
                        Button("取消") { pendingImport = nil }
                        Spacer()
                        Button("确认采用") { pendingImport = nil; onUse(paper) }
                            .buttonStyle(.borderedProminent)
                    }
                } else {
                    HStack {
                        Button("查看图谱", systemImage: "point.3.connected.trianglepath.dotted") {
                            if let selected { model.loadGraph(selected) }
                        }.disabled(selected == nil || model.busy).help("自动定位官网图谱，并读取可用关系到应用内")
                        Spacer(minLength: DS.Space.xs)
                        Button("采用题录") { pendingImport = selected }.disabled(selected == nil)
                    }
                }
            }.padding(DS.Space.m)
                .help("仅取得题录和可用关系，未读取全文")
        }
    }
}

private struct CNKIWebView: NSViewRepresentable {
    let webView: WKWebView
    func makeNSView(context: Context) -> WKWebView { webView }
    func updateNSView(_ nsView: WKWebView, context: Context) {}
}
