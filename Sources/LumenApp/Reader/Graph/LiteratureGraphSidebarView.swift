import SwiftUI
import LumenKit

struct LiteratureGraphSidebarView: View {
    @ObservedObject var model: LiteratureGraphModel
    @EnvironmentObject private var settings: SettingsStore
    @State private var showsSetup = false
    @State private var query = ""
    @State private var title = ""
    @State private var authors = ""
    @State private var year = ""
    @State private var doi = ""
    @State private var key = ""
    @State private var hasKey = false

    private var listedPapers: [GraphPaper] {
        let value = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return model.visiblePapers }
        return model.visiblePapers.filter {
            $0.title.localizedCaseInsensitiveContains(value)
                || $0.authors.contains(where: { $0.localizedCaseInsensitiveContains(value) })
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: DS.Space.s) {
                Text("文献").font(DS.Typo.title)
                Text("\(model.visiblePapers.count)")
                    .font(DS.Typo.callout).foregroundStyle(DS.Palette.textSecondary)
                Spacer()
                if model.rootPaper != nil {
                    Button(showsSetup ? "返回列表" : "识别与数据源",
                           systemImage: showsSetup ? "list.bullet" : "slider.horizontal.3") {
                        showsSetup.toggle()
                    }
                    .labelStyle(.iconOnly)
                    .help(showsSetup ? "返回文献列表" : "论文识别与数据源")
                }
            }
            .padding(.horizontal, DS.Space.l).padding(.vertical, DS.Space.m)
            Divider()

            if model.rootPaper != nil && !showsSetup {
                listContent
            } else {
                setupContent
            }
        }
        .background(DS.Palette.surfaceSunken)
        .tint(DS.Palette.accent)
        .onAppear {
            sync()
            if LaunchOptions.isAuditRun,
               let raw = LaunchOptions.value(for: "--graph-relation"),
               let relation = GraphRelation(rawValue: raw) {
                model.selectRelation(relation)
            }
        }
        .onChange(of: model.snapshot.identity) { _, _ in sync() }
        .onChange(of: model.localCandidates.count) { _, count in
            if count > 0 { showsSetup = true }
        }
        .onChange(of: model.candidates.count) { _, count in
            if count > 0 { showsSetup = true }
        }
    }

    private var listContent: some View {
        VStack(spacing: 0) {
            HStack(spacing: DS.Space.xs) {
                relationTab("参考", relation: .reference)
                relationTab("被引", relation: .citation)
                relationTab("相关", relation: .related)
            }
            .padding(.horizontal, DS.Space.m).padding(.top, DS.Space.m)
            HStack(spacing: DS.Space.s) {
                TextField("搜索图中文献", text: $query)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityLabel("搜索图中文献")
                Button("刷新图谱", systemImage: "arrow.clockwise") { model.refresh() }
                    .labelStyle(.iconOnly).help("刷新图谱")
                    .disabled(model.busy)
            }
            .padding(DS.Space.m)
            if !model.message.isEmpty {
                Text(model.message)
                    .font(DS.Typo.callout)
                    .foregroundStyle(DS.Palette.textSecondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, DS.Space.l)
                    .padding(.bottom, DS.Space.s)
            }
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(listedPapers) { paper in
                            Button { model.selectedID = paper.id } label: {
                                HStack(alignment: .top, spacing: DS.Space.s) {
                                    RoundedRectangle(cornerRadius: 2)
                                        .fill(paper.id == model.selectedID ? DS.Palette.accent : .clear)
                                        .frame(width: 3)
                                    VStack(alignment: .leading, spacing: 5) {
                                        if paper.id == model.snapshot.paperID {
                                            Text("当前论文")
                                                .font(DS.Typo.callout.weight(.semibold))
                                                .foregroundStyle(DS.Palette.accent)
                                        }
                                        Text(paper.title)
                                            .font(DS.Typo.body)
                                            .foregroundStyle(DS.Palette.textPrimary)
                                            .lineLimit(3)
                                            .multilineTextAlignment(.leading)
                                        Text(paperSubtitle(paper))
                                            .font(DS.Typo.callout)
                                            .foregroundStyle(DS.Palette.textSecondary)
                                            .lineLimit(1)
                                    }
                                    Spacer(minLength: 0)
                                }
                                .padding(.horizontal, DS.Space.m)
                                .padding(.vertical, DS.Space.m)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(paper.id == model.selectedID ? DS.Palette.accentSoft : .clear)
                            }
                            .buttonStyle(.plain)
                            .help(paper.title)
                            .accessibilityAddTraits(paper.id == model.selectedID ? [.isSelected] : [])
                            .id(paper.id)
                            Divider().padding(.leading, DS.Space.xl)
                        }
                    }
                }
                .onChange(of: model.selectedID) { _, id in
                    guard let id else { return }
                    if !listedPapers.contains(where: { $0.id == id }) { query = "" }
                    DispatchQueue.main.async {
                        withAnimation(DS.Motion.quick) { proxy.scrollTo(id, anchor: .center) }
                    }
                }
            }
            Divider()
            HStack {
                Text("已展示 \(model.visiblePapers.count) 篇")
                Spacer()
                Text("最多 \(GraphMerge.limit) 篇")
            }
            .font(DS.Typo.callout)
            .foregroundStyle(DS.Palette.textSecondary)
            .padding(.horizontal, DS.Space.l).padding(.vertical, DS.Space.s)
        }
    }

    private var setupContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DS.Space.l) {
                identitySection
                if model.busy { ProgressView().controlSize(.small) }
                if !model.message.isEmpty {
                    Text(model.message).font(DS.Typo.body)
                        .foregroundStyle(DS.Palette.textSecondary)
                }
                candidateSection("核对匹配", papers: model.candidates) { model.confirm($0); showsSetup = false }
                candidateSection("核对本地引文", papers: model.localCandidates) {
                    model.confirmLocalMatch($0); showsSetup = false
                }
                keySection
            }
            .padding(DS.Space.l)
        }
    }

    private var identitySection: some View {
        VStack(alignment: .leading, spacing: DS.Space.s) {
            HStack {
                Text("当前论文").font(DS.Typo.headline)
                Spacer()
                Text(model.snapshot.identity.source)
                    .font(DS.Typo.callout).foregroundStyle(DS.Palette.textSecondary)
            }
            TextField("论文标题", text: $title).accessibilityLabel("论文标题")
            TextField("作者，以逗号分隔", text: $authors).accessibilityLabel("论文作者")
            HStack {
                TextField("年份", text: $year).frame(width: 65)
                TextField("DOI（可选）", text: $doi)
            }
            Button("保存修订") { commitEdits() }
            Button("查找 OpenAlex 论文") { commitEdits(); model.findCandidates() }
                .buttonStyle(.borderedProminent).tint(DS.Palette.accent)
                .disabled(model.busy || (title.isEmpty && doi.isEmpty))
            HStack {
                Button("用 Crossref 补 DOI") { commitEdits(); model.findViaCrossref() }
                    .disabled(model.busy || title.isEmpty)
                Button("提取文内引文") { commitEdits(); model.extractReferencesFromPDF() }
                    .disabled(model.busy)
            }
            Button("AI 识别首页") { model.identifyWithAI(config: settings.activeProvider) }
                .disabled(model.busy || model.openingText.isEmpty)
                .help("仅发送首页文字前 2500 字符，匹配结果仍需核对")
            if model.rootPaper != nil {
                HStack {
                    Text("起始年份").font(DS.Typo.body)
                    TextField("不限", text: $model.yearStart).frame(width: 70)
                }
            }
        }
    }

    @ViewBuilder
    private func candidateSection(_ heading: String, papers: [GraphPaper],
                                  confirm: @escaping (GraphPaper) -> Void) -> some View {
        if !papers.isEmpty {
            VStack(alignment: .leading, spacing: DS.Space.s) {
                Text("\(heading) · \(papers.count) 篇").font(DS.Typo.headline)
                ForEach(papers) { paper in
                    Button { confirm(paper) } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(paper.title).font(DS.Typo.body).multilineTextAlignment(.leading)
                            Text(paperSubtitle(paper))
                                .font(DS.Typo.callout).foregroundStyle(DS.Palette.textSecondary)
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }.buttonStyle(.plain)
                    Divider()
                }
            }
        }
    }

    private var keySection: some View {
        VStack(alignment: .leading, spacing: DS.Space.s) {
            Text("OpenAlex API Key").font(DS.Typo.headline)
            Text(hasKey ? "已配置" : "限流时可填写免费 Key")
                .font(DS.Typo.callout).foregroundStyle(DS.Palette.textSecondary)
            SecureField(hasKey ? "输入新 Key 替换" : "粘贴 API Key", text: $key)
                .accessibilityLabel("OpenAlex API Key")
            HStack {
                Button("保存 Key") {
                    let value = key.trimmingCharacters(in: .whitespacesAndNewlines)
                    if AICredentialStore.save(value, account: "openalex-api") {
                        key = ""; hasKey = true
                    }
                }.disabled(key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                if hasKey {
                    Button("删除 Key") {
                        AICredentialStore.delete(account: "openalex-api")
                        hasKey = false
                    }
                }
                Spacer()
                Link("获取 Key", destination: URL(string: "https://openalex.org/settings/api")!)
            }
            .font(DS.Typo.callout)
        }
    }

    private func relationTab(_ name: String, relation: GraphRelation) -> some View {
        let selected = model.selectedRelation == relation
        return Button(name) { model.selectRelation(relation) }
            .buttonStyle(.plain)
            .font(DS.Typo.callout.weight(.semibold))
            .foregroundStyle(selected ? Color.white : DS.Palette.textSecondary)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity)
            .background {
                RoundedRectangle(cornerRadius: DS.Radius.s)
                    .fill(selected ? DS.Palette.accent : DS.Palette.surfaceRaised)
            }
            .accessibilityValue(selected ? "已选中" : "未选中")
    }

    private func paperSubtitle(_ paper: GraphPaper) -> String {
        let names = paper.authors.prefix(2).joined(separator: "、")
        let year = paper.year.map(String.init) ?? "年份不详"
        return names.isEmpty ? year : "\(names) · \(year)"
    }

    private func sync() {
        hasKey = AICredentialStore.hasKey(account: "openalex-api")
        let identity = model.snapshot.identity
        title = identity.title
        authors = identity.authors.joined(separator: ", ")
        year = identity.year.map(String.init) ?? ""
        doi = identity.doi ?? ""
    }

    private func commitEdits() {
        let draft = GraphIdentity(title: title.trimmingCharacters(in: .whitespacesAndNewlines),
            authors: authors.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) },
            year: Int(year), doi: doi, source: "用户修订")
        let previous = model.snapshot.identity
        if draft.title != previous.title || draft.authors != previous.authors
            || draft.year != previous.year || draft.doi != previous.doi {
            model.updateIdentity(draft)
        }
    }
}
