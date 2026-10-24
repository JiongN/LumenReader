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
    @State private var editing = false
    @State private var showsSources = false
    @State private var editError = ""
    @State private var keyError = ""

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
                Text(showsSetup || model.rootPaper == nil ? "文献信息" : "文献").font(DS.Typo.headline)
                if model.rootPaper != nil && !showsSetup {
                    Text("\(model.visiblePapers.count)")
                        .font(DS.Typo.callout).foregroundStyle(DS.Palette.textSecondary)
                }
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
        .transaction { transaction in
            transaction.animation = nil
            transaction.disablesAnimations = true
        }
        .onAppear {
            sync()
            if LaunchOptions.isAuditRun,
               let raw = LaunchOptions.value(for: "--graph-relation"),
               let relation = GraphRelation(rawValue: raw) {
                model.selectRelation(relation)
            }
        }
        .onChange(of: model.snapshot.identity) { _, _ in sync() }
        .onChange(of: model.suggestedIdentity) { _, identity in
            guard let identity else { return }
            showsSetup = true
            title = identity.title
            authors = identity.authors.joined(separator: ", ")
            year = identity.year.map(String.init) ?? ""
            doi = identity.doi ?? ""
            editing = true
            editError = ""
        }
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
                                .contentShape(Rectangle())
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
                        proxy.scrollTo(id, anchor: .center)
                    }
                }
            }
        }
    }

    private var setupContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DS.Space.xl) {
                identitySection
                Divider()
                matchingSection
                if !model.message.isEmpty {
                    Text(model.message).font(DS.Typo.callout)
                        .foregroundStyle(DS.Palette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                candidateSection("核对匹配", papers: model.candidates) { model.confirm($0); showsSetup = false }
                candidateSection("核对本地引文", papers: model.localCandidates) {
                    model.confirmLocalMatch($0); showsSetup = false
                }
                Divider()
                keySection
            }
            .padding(DS.Space.l)
        }
    }

    private var identitySection: some View {
        VStack(alignment: .leading, spacing: DS.Space.m) {
            HStack(spacing: DS.Space.s) {
                Label("当前论文", systemImage: "doc.text")
                    .font(DS.Typo.caption).foregroundStyle(DS.Palette.textSecondary)
                Spacer()
                Button(editing ? "取消编辑" : "编辑题录", systemImage: editing ? "xmark" : "pencil") {
                    if editing { sync(); model.discardSuggestedIdentity() }
                    editing.toggle()
                    editError = ""
                }.labelStyle(.iconOnly).buttonStyle(.borderless)
                    .help(editing ? "取消编辑" : "编辑题录")
            }
            if editing {
                identityEditor
            } else {
                let identity = model.snapshot.identity
                Text(identity.title.isEmpty ? "尚未识别标题" : identity.title)
                    .font(DS.Typo.ui(size: 17, weight: .semibold))
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                    .accessibilityIdentifier("literature-title")
                if !identity.authors.isEmpty {
                    Text(identity.authors.joined(separator: "、"))
                        .font(DS.Typo.body).foregroundStyle(DS.Palette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                }
                HStack(spacing: DS.Space.s) {
                    if let year = identity.year { Text(String(year)).monospacedDigit() }
                    Text(identity.source)
                }.font(DS.Typo.caption).foregroundStyle(DS.Palette.textSecondary)
                if let value = identity.doi {
                    HStack(alignment: .firstTextBaseline, spacing: DS.Space.s) {
                        Text("DOI").font(DS.Typo.caption).foregroundStyle(DS.Palette.textSecondary)
                        Text(value).font(DS.Typo.callout).textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }

    private var identityEditor: some View {
        VStack(alignment: .leading, spacing: DS.Space.m) {
            editorField("标题") {
                metadataEditor($title, label: "论文标题", height: 112)
            }
            editorField("作者") {
                metadataEditor($authors, label: "论文作者，以逗号分隔", height: 54)
            }
            editorField("年份") {
                TextField("可选", text: $year).accessibilityLabel("论文年份").frame(maxWidth: 100)
            }
            editorField("DOI") {
                TextField("可选", text: $doi).accessibilityLabel("论文 DOI")
            }
            if !editError.isEmpty { Text(editError).font(DS.Typo.callout).foregroundStyle(DS.Palette.warning) }
            Button("保存题录", systemImage: "checkmark") { _ = commitEdits() }
                .buttonStyle(.borderedProminent)
        }.textFieldStyle(.roundedBorder).font(DS.Typo.body)
    }

    private func editorField<Content: View>(_ label: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: DS.Space.xs) {
            Text(label).font(DS.Typo.caption).foregroundStyle(DS.Palette.textSecondary)
            content()
        }
    }

    private func metadataEditor(_ text: Binding<String>, label: String, height: CGFloat) -> some View {
        TextEditor(text: text)
            .font(DS.Typo.body).scrollContentBackground(.hidden)
            .padding(DS.Space.xs).frame(height: height)
            .background(DS.Palette.surfaceRaised, in: RoundedRectangle(cornerRadius: DS.Radius.s))
            .overlay(RoundedRectangle(cornerRadius: DS.Radius.s).strokeBorder(DS.Palette.separator, lineWidth: 1))
            .accessibilityLabel(label)
    }

    private var matchingSection: some View {
        VStack(alignment: .leading, spacing: DS.Space.m) {
            HStack {
                Text("论文匹配").font(DS.Typo.headline)
                Spacer()
                if model.busy { ProgressView().controlSize(.small) }
                Menu("更多操作", systemImage: "ellipsis") {
                    Button("按首页版式重新识别", systemImage: "doc.text.viewfinder") {
                        model.reidentify()
                    }.disabled(model.busy || !model.canIdentifyHeader)
                    Button("Crossref 补充 DOI", systemImage: "link") {
                        guard commitEdits() else { return }; model.findViaCrossref()
                    }.disabled(model.busy || title.isEmpty)
                    Button("AI 识别首页", systemImage: "sparkles") {
                        model.identifyWithAI(config: settings.activeProvider)
                    }.disabled(model.busy || !model.canIdentifyHeader)
                }.labelStyle(.iconOnly).menuStyle(.borderlessButton).menuIndicator(.hidden)
                    .fixedSize().help("论文信息补全")
            }
            Button {
                guard commitEdits() else { return }; model.findCandidates()
            } label: {
                Label("匹配 OpenAlex", systemImage: "magnifyingglass")
                    .frame(maxWidth: .infinity, minHeight: 24)
            }.buttonStyle(.borderedProminent)
                .disabled(model.busy || (title.isEmpty && doi.isEmpty))
            Button {
                guard commitEdits() else { return }
                CNKISearchWindowPresenter.shared.show(for: model, graphRequested: true)
            } label: {
                Label("知网图谱", systemImage: "point.3.connected.trianglepath.dotted")
                    .frame(maxWidth: .infinity, minHeight: 24)
            }.buttonStyle(.bordered).help("自动定位论文图谱，读取参考、被引和相关文献；验证与权限由知网决定")
            Button("知网题录检索", systemImage: "magnifyingglass") {
                CNKISearchWindowPresenter.shared.show(for: model)
            }.buttonStyle(.borderless)
            Button("提取文内参考文献", systemImage: "text.magnifyingglass") {
                guard commitEdits() else { return }; model.extractReferencesFromPDF()
            }.buttonStyle(.borderless).disabled(model.busy)
            if model.rootPaper != nil {
                LabeledContent("起始年份") {
                    TextField("不限", text: $model.yearStart).textFieldStyle(.roundedBorder).frame(width: 80)
                }
                .font(DS.Typo.callout)
            }
        }.disabled(editing)
    }

    @ViewBuilder
    private func candidateSection(_ heading: String, papers: [GraphPaper],
                                  confirm: @escaping (GraphPaper) -> Void) -> some View {
        if !papers.isEmpty {
            VStack(alignment: .leading, spacing: DS.Space.s) {
                Text("\(heading) · \(papers.count) 篇").font(DS.Typo.headline)
                ForEach(papers) { paper in
                    Button { confirm(paper) } label: {
                        HStack(alignment: .top, spacing: DS.Space.s) {
                            VStack(alignment: .leading, spacing: DS.Space.s) {
                                Text(paper.title).font(DS.Typo.body.weight(.medium)).multilineTextAlignment(.leading)
                                Text(paperSubtitle(paper))
                                    .font(DS.Typo.callout).foregroundStyle(DS.Palette.textSecondary)
                                if !paper.venue.isEmpty {
                                    Text(paper.venue).font(DS.Typo.caption).foregroundStyle(DS.Palette.textSecondary)
                                }
                            }.frame(maxWidth: .infinity, alignment: .leading)
                            Image(systemName: "checkmark.circle").foregroundStyle(DS.Palette.accent)
                        }.padding(.vertical, DS.Space.s)
                            .contentShape(Rectangle())
                    }.buttonStyle(.plain)
                    Divider()
                }
            }
        }
    }

    private var keySection: some View {
        DisclosureGroup(isExpanded: $showsSources) {
            VStack(alignment: .leading, spacing: DS.Space.m) {
                Text("OpenAlex API Key").font(DS.Typo.callout.weight(.medium))
                SecureField(hasKey ? "输入新 Key 替换" : "粘贴 API Key", text: $key)
                    .textFieldStyle(.roundedBorder).accessibilityLabel("OpenAlex API Key")
                HStack(spacing: DS.Space.m) {
                    Button("保存 Key", systemImage: "checkmark") {
                        let value = key.trimmingCharacters(in: .whitespacesAndNewlines)
                        if AICredentialStore.save(value, account: "openalex-api") {
                            key = ""; hasKey = true; keyError = ""
                        } else { keyError = "密钥未保存，请检查本机存储权限。" }
                    }.labelStyle(.iconOnly).help("保存 OpenAlex Key")
                        .disabled(key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    if hasKey {
                        Button("删除 Key", systemImage: "trash") {
                            AICredentialStore.delete(account: "openalex-api")
                            hasKey = AICredentialStore.hasKey(account: "openalex-api")
                            keyError = hasKey ? "密钥未删除，请检查本机存储权限。" : ""
                        }.labelStyle(.iconOnly).help("删除 OpenAlex Key")
                    }
                    Spacer()
                    Link("获取 Key", destination: URL(string: "https://openalex.org/settings/api")!)
                }.font(DS.Typo.callout)
                if !keyError.isEmpty { Text(keyError).font(DS.Typo.callout).foregroundStyle(DS.Palette.warning) }
            }.padding(.top, DS.Space.m)
        } label: {
            HStack(spacing: DS.Space.s) {
                Text("数据源").font(DS.Typo.callout.weight(.medium))
                Spacer()
                Text(hasKey ? "OpenAlex · 已配置" : "OpenAlex · 未配置 Key")
                    .font(DS.Typo.caption).foregroundStyle(DS.Palette.textSecondary)
            }
        }
    }

    private func relationTab(_ name: String, relation: GraphRelation) -> some View {
        let selected = model.selectedRelation == relation
        return Button { model.selectRelation(relation) } label: {
            Text(name)
                .font(DS.Typo.callout.weight(.semibold))
                .foregroundStyle(selected ? Color.white : DS.Palette.textSecondary)
                .frame(maxWidth: .infinity, minHeight: 28)
                .background {
                    RoundedRectangle(cornerRadius: DS.Radius.s)
                        .fill(selected ? DS.Palette.accent : DS.Palette.surfaceRaised)
                }
                .contentShape(Rectangle())
        }
            .buttonStyle(.plain)
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

    @discardableResult
    private func commitEdits() -> Bool {
        let cleanYear = year.trimmingCharacters(in: .whitespacesAndNewlines)
        if !cleanYear.isEmpty, Int(cleanYear).map({ (1500...2100).contains($0) }) != true {
            editing = true; editError = "年份应为四位数字，或留空。"; return false
        }
        if !doi.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, GraphIdentity.normalizedDOI(doi) == nil {
            editing = true; editError = "DOI 格式不正确，应以 10. 开头。"; return false
        }
        let draft = GraphIdentity(title: title.trimmingCharacters(in: .whitespacesAndNewlines),
            authors: authors.components(separatedBy: CharacterSet(charactersIn: ",，;；"))
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty },
            year: Int(cleanYear), doi: doi, source: "用户修订")
        let previous = model.snapshot.identity
        if draft.title != previous.title || draft.authors != previous.authors
            || draft.year != previous.year || draft.doi != previous.doi {
            model.updateIdentity(draft)
        }
        editError = ""
        editing = false
        model.suggestedIdentity = nil
        return true
    }
}
