import SwiftUI

struct LiteratureNotesPane: View {
    @EnvironmentObject private var session: ReaderSession
    @ObservedObject private var sync = LiteratureSyncService.shared
    @State private var properties: [LiteraturePageEditor.Property] = []
    @State private var newKey = ""
    @State private var showingNewProperty = false
    @State private var propertiesExpanded = true
    @State private var notes = ""
    @State private var notesBaseline: String?
    @State private var externalNotes: String?
    @State private var hasLoaded = false
    @State private var savingNotes = false
    @State private var changingSync = false
    @State private var error: String?
    @State private var loadError: String?
    @State private var modifiedAt = ""

    private var record: LiteratureSyncService.Record? { sync.record(for: session.document.url.path) }
    private var isSyncing: Bool { sync.enabled && record?.paused == false }
    private var canWrite: Bool { isSyncing && hasLoaded }
    private var notesDirty: Bool { notes != (notesBaseline ?? "") }
    private var visibleProperties: [LiteraturePageEditor.Property] {
        let order = ["标题", "作者", "期刊", "日期", "评价", "总结"]
        return properties.enumerated().filter { $0.element.key != "itemLink" }.sorted {
            let a = order.firstIndex(of: $0.element.key) ?? order.count
            let b = order.firstIndex(of: $1.element.key) ?? order.count
            return a == b ? $0.offset < $1.offset : a < b
        }.map(\.element)
    }
    private var status: String {
        if changingSync { return "正在关联文献页…" }
        if record?.paused == true { return "已关闭当前文献同步" }
        return sync.statuses[session.document.url.standardizedFileURL.path] ?? (record == nil ? "为当前文献开启同步" : "等待同步")
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(DS.Palette.separator)
            GeometryReader { geometry in
            ScrollView {
                VStack(alignment: .leading, spacing: DS.Space.xl) {
                    if let record {
                        propertySection(record)
                        readingSection(record)
                            .frame(height: min(360, max(260, geometry.size.height * 0.42)), alignment: .top)
                    } else {
                        Text("开启同步后，在这里整理文献笔记，也可以随时到 Obsidian 接着写。")
                            .font(DS.Typo.callout).foregroundStyle(DS.Palette.textSecondary)
                            .padding(.vertical, DS.Space.l)
                    }
                    if let message = error ?? loadError {
                        HStack(alignment: .top, spacing: DS.Space.s) {
                            Text(message).font(DS.Typo.caption).foregroundStyle(DS.Palette.danger)
                            Spacer(minLength: 0)
                            Button { self.error = nil; self.loadError = nil } label: { Image(systemName: "xmark") }
                                .buttonStyle(.plain).help("关闭提示")
                        }
                    }
                }
                .padding(DS.Space.m)
                .frame(minHeight: geometry.size.height, alignment: .top)
            }
            }
        }
        .foregroundStyle(DS.Palette.textPrimary)
        .task(id: record?.notePath) {
            hasLoaded = false
            loadError = nil
            if record == nil { properties = []; notes = ""; notesBaseline = nil; externalNotes = nil }
            while !Task.isCancelled {
                if let record { await reload(record) }
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: DS.Space.s) {
            HStack(spacing: DS.Space.s) {
                Text("文献笔记").font(DS.Typo.headline)
                Spacer(minLength: DS.Space.xs)
                Toggle("同步", isOn: Binding(get: { isSyncing }, set: { setSync($0) }))
                    .toggleStyle(.switch).controlSize(.small).font(DS.Typo.caption)
                    .fixedSize().disabled(changingSync)
                    .accessibilityLabel("当前文献同步")
                    .help("控制当前文献是否同步；关闭后保留已有文献页")
                Menu {
                    if let record {
                        Button("立即同步") { Task { await sync.syncNow(recordID: record.id) } }.disabled(!isSyncing)
                    } else {
                        Button("开启同步") { setSync(true) }
                    }
                } label: { Image(systemName: "ellipsis") }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden)
                    .frame(width: DS.Space.l).help("文献笔记操作")
            }
            HStack(spacing: DS.Space.s) {
                if changingSync { ProgressView().controlSize(.mini) }
                Text(status).font(DS.Typo.caption).foregroundStyle(DS.Palette.textSecondary)
                    .lineLimit(1).help(status)
                Spacer(minLength: 0)
                if let record {
                    Button { sync.openNote(for: record.documentPath) } label: {
                        Label("Obsidian", systemImage: "arrow.up.forward.square")
                    }
                    .buttonStyle(.plain).font(DS.Typo.caption).foregroundStyle(DS.Palette.accent)
                    .fixedSize().accessibilityLabel("在 Obsidian 打开")
                }
            }
        }.padding(DS.Space.m)
    }

    private func propertySection(_ record: LiteratureSyncService.Record) -> some View {
        VStack(alignment: .leading, spacing: DS.Space.s) {
            HStack(spacing: DS.Space.s) {
                Button { propertiesExpanded.toggle() } label: {
                    HStack(spacing: DS.Space.xs) {
                        Image(systemName: propertiesExpanded ? "chevron.down" : "chevron.right").font(DS.Typo.caption)
                        Text("文献属性").font(DS.Typo.callout.weight(.semibold))
                    }
                }.buttonStyle(.plain).accessibilityLabel(propertiesExpanded ? "收起文献属性" : "展开文献属性")
                Spacer()
                Button { showingNewProperty.toggle() } label: { Image(systemName: "plus") }
                    .buttonStyle(.plain).foregroundStyle(DS.Palette.textSecondary)
                    .help("添加属性").accessibilityLabel("添加属性").disabled(!canWrite)
            }
            if propertiesExpanded {
                VStack(spacing: 0) {
                    ForEach(visibleProperties, id: \.key) { property in
                        LiteraturePropertyRow(property: property, canWrite: canWrite) { value, expected in
                            await edit(record) { try LiteraturePageEditor.set($0, key: property.key, value: value, expected: expected) }
                        }
                        Divider().overlay(DS.Palette.separator)
                    }
                    HStack(spacing: DS.Space.s) {
                        Text("修改时间").font(DS.Typo.caption).foregroundStyle(DS.Palette.textSecondary)
                            .lineLimit(1).minimumScaleFactor(0.8)
                            .frame(width: 44, alignment: .leading)
                        Text(modifiedAt.isEmpty ? "—" : modifiedAt).font(DS.Typo.body)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }.padding(.vertical, DS.Space.s)
                }
                if showingNewProperty {
                    HStack(spacing: DS.Space.s) {
                        TextField("属性名称", text: $newKey).textFieldStyle(.plain)
                            .font(DS.Typo.callout).onSubmit { addProperty(record) }
                        Button("添加") { addProperty(record) }
                            .buttonStyle(.borderless).disabled(newKey.isEmpty || !canWrite)
                    }.padding(.vertical, DS.Space.xs)
                }
                if let link = properties.first(where: { $0.key == "itemLink" }), let url = URL(string: link.value) {
                    Link(destination: url) { Label("Zotero 文献", systemImage: "link") }
                        .font(DS.Typo.caption).foregroundStyle(DS.Palette.accent)
                        .padding(.top, DS.Space.xs)
                }
            }
        }
    }

    private func readingSection(_ record: LiteratureSyncService.Record) -> some View {
        VStack(alignment: .leading, spacing: DS.Space.s) {
            HStack(spacing: DS.Space.s) {
                Text("阅读笔记").font(DS.Typo.callout.weight(.semibold))
                Spacer(minLength: 0)
                if notesDirty {
                    Button(savingNotes ? "保存中…" : "保存") { saveNotes(record) }
                        .buttonStyle(.borderless).font(DS.Typo.caption)
                        .disabled(!canWrite || savingNotes).accessibilityLabel("保存阅读笔记")
                } else {
                    Text(hasLoaded ? "已保存" : "载入中…").font(DS.Typo.caption).foregroundStyle(DS.Palette.textSecondary)
                }
                Menu {
                    Button("重新载入") { notes = notesBaseline ?? ""; Task { await reload(record) } }
                    Button("清空草稿") { notes = "" }.disabled(notes.isEmpty)
                } label: { Image(systemName: "ellipsis") }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden)
                    .frame(width: DS.Space.l).help("阅读笔记操作")
            }
            LiteratureNotesEditor(text: $notes, isEditable: !savingNotes,
                                  textColor: NSColor(DS.Palette.textPrimary))
                .frame(minHeight: 220, maxHeight: .infinity)
                .overlay(RoundedRectangle(cornerRadius: DS.Radius.s).stroke(DS.Palette.separator, lineWidth: 0.5))
                .overlay(alignment: .topLeading) {
                    if notes.isEmpty {
                        Text("写下你的思考…")
                            .font(DS.Typo.body).foregroundStyle(DS.Palette.textSecondary)
                            .padding(.top, DS.Space.s).padding(.leading, DS.Space.xs)
                            .allowsHitTesting(false).accessibilityHidden(true)
                    }
                }
                .accessibilityLabel("阅读笔记正文")
            if notesDirty && !isSyncing {
                Text("同步已关闭，草稿暂未写入文献页。")
                    .font(DS.Typo.caption).foregroundStyle(DS.Palette.textSecondary)
            }
            if notesDirty && externalNotes != notesBaseline {
                HStack {
                    Text("Obsidian 中有新版本").font(DS.Typo.caption)
                    Button("载入外部版本") { notes = externalNotes ?? ""; notesBaseline = externalNotes }
                        .buttonStyle(.borderless).font(DS.Typo.caption)
                }.foregroundStyle(DS.Palette.warning)
            }
        }.frame(maxHeight: .infinity, alignment: .top)
    }

    private func setSync(_ value: Bool) {
        changingSync = true
        Task {
            await sync.setDocumentSync(value, documentURL: session.document.url)
            changingSync = false
            if let message = sync.error { error = message }
        }
    }
    private func addProperty(_ record: LiteratureSyncService.Record) {
        let key = newKey
        guard !key.isEmpty else { return }
        Task {
            if await edit(record, transform: { try LiteraturePageEditor.set($0, key: key, value: "", expected: nil) }) {
                newKey = ""; showingNewProperty = false
            }
        }
    }
    private func saveNotes(_ record: LiteratureSyncService.Record) {
        let value = notes; let expected = notesBaseline
        savingNotes = true
        Task {
            if await edit(record, transform: { try LiteraturePageEditor.setReadingNotes($0, value: value, expected: expected) }) {
                notesBaseline = value
            }
            savingNotes = false
        }
    }
    private func reload(_ record: LiteratureSyncService.Record) async {
        do {
            let (text, date) = try await Task.detached(priority: .utility) {
                let url = URL(fileURLWithPath: record.notePath)
                return (try String(contentsOf: url, encoding: .utf8),
                        try url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
            }.value
            if let date {
                let formatter = DateFormatter(); formatter.dateFormat = "yyyy-MM-dd HH:mm"
                modifiedAt = formatter.string(from: date)
            }
            guard !Task.isCancelled else { return }
            let loaded = try LiteraturePageEditor.properties(text)
            if properties != loaded { properties = loaded }
            let external = try LiteraturePageEditor.readingNotes(text)
            externalNotes = external
            if notes == (notesBaseline ?? "") { notes = external ?? ""; notesBaseline = external }
            hasLoaded = true
            loadError = nil
        } catch {
            guard !Task.isCancelled else { return }
            // A newly enrolled record can be observed before its first page is
            // committed. The service displays any creation error itself.
            if record.baseline != nil { loadError = error.localizedDescription }
        }
    }
    @discardableResult private func edit(_ record: LiteratureSyncService.Record,
        transform: @escaping @Sendable (String) throws -> String) async -> Bool {
        do {
            guard sync.enabled, sync.record(id: record.id)?.paused == false,
                  ZoteroOneWriterGuard.isSafe(notesDirectory: URL(fileURLWithPath: sync.notesDirectory)) else { throw LiteratureFileError.noteChanged }
            try await sync.files.editPage(url: URL(fileURLWithPath: record.notePath), transform: transform)
            error = nil; await reload(record); return true
        } catch { self.error = "未覆盖文件：" + error.localizedDescription; return false }
    }
}

private struct LiteraturePropertyRow: View {
    let property: LiteraturePageEditor.Property
    let canWrite: Bool
    let save: (String?, LiteraturePageEditor.Property) async -> Bool
    @State private var draft: String
    @State private var baseline: LiteraturePageEditor.Property
    @State private var saving = false
    @FocusState private var focused: Bool
    private var dirty: Bool { draft != baseline.value }

    init(property: LiteraturePageEditor.Property, canWrite: Bool, save: @escaping (String?, LiteraturePageEditor.Property) async -> Bool) {
        self.property = property; self.canWrite = canWrite; self.save = save
        _draft = State(initialValue: property.value); _baseline = State(initialValue: property)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.xs) {
            HStack(alignment: .firstTextBaseline, spacing: DS.Space.s) {
                Text(property.key).font(DS.Typo.caption).foregroundStyle(DS.Palette.textSecondary)
                    .frame(width: 44, alignment: .leading).lineLimit(2)
                if property.editable {
                    if property.key == "评价" {
                        LiteratureStarRating(value: Binding(get: { LiteratureRating.value(draft) ?? 0 },
                            set: { draft = LiteratureRating.text($0) }))
                        Spacer(minLength: 0)
                    } else {
                        TextField("未填写", text: $draft, axis: .vertical)
                            .textFieldStyle(.plain).font(DS.Typo.body).lineLimit(1...6)
                            .focused($focused).onSubmit { commit() }
                            .accessibilityLabel(property.key)
                    }
                    if dirty {
                        Button { commit() } label: { Image(systemName: "checkmark") }
                            .buttonStyle(.plain).foregroundStyle(DS.Palette.accent)
                            .disabled(!canWrite || saving).help("保存" + property.key)
                            .accessibilityLabel("保存" + property.key)
                    }
                    Menu {
                        if property.key == "评价" {
                            Button("清除星级") { draft = LiteratureRating.text(0) }
                        }
                        Button("载入外部版本") { draft = property.value; baseline = property }
                        Button("删除属性", role: .destructive) { let expected = baseline; Task { _ = await save(nil, expected) } }
                            .disabled(!canWrite)
                    } label: { Image(systemName: "ellipsis") }
                        .menuStyle(.borderlessButton).menuIndicator(.hidden)
                        .frame(width: DS.Space.l).help(property.key + "操作")
                        .accessibilityLabel(property.key + "操作")
                } else {
                    Text(property.value).font(DS.Typo.body).lineLimit(4).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .disabled(saving)
            if property.key == "评价", LiteratureRating.value(draft) == nil {
                Text("原评价：" + draft).font(DS.Typo.caption).textSelection(.enabled)
            }
            if dirty && property != baseline {
                Text("外部版本已变化，保存前请先核对。")
                    .font(DS.Typo.caption).foregroundStyle(DS.Palette.warning)
            }
        }
        .padding(.vertical, DS.Space.s)
        .overlay(alignment: .bottom) {
            if focused { DS.Palette.accent.frame(height: 1) }
        }
        .onChange(of: property) { _, value in
            if draft == baseline.value { draft = value.value; baseline = value }
        }
    }
    private func commit() {
        guard dirty, canWrite, !saving else { return }
        let value = draft; let expected = baseline
        saving = true
        Task {
            if await save(value, expected) {
                let encoder = JSONEncoder(); encoder.outputFormatting = .withoutEscapingSlashes
                let raw = property.key + ": " + String(decoding: (try? encoder.encode(value)) ?? Data(), as: UTF8.self)
                baseline = .init(key: property.key, value: value, raw: raw, editable: true)
            }
            saving = false
        }
    }
}

private struct LiteratureStarRating: View {
    @Binding var value: Int
    private let width = DS.Space.l * 5
    var body: some View {
        HStack(spacing: 0) {
            ForEach(1...5, id: \.self) { star in
                Button { value = star } label: {
                    Image(systemName: star <= value ? "star.fill" : "star")
                        .foregroundStyle(DS.Palette.rating).font(DS.Typo.body)
                        .frame(width: DS.Space.l, height: DS.Space.xl)
                }
                .buttonStyle(.plain).accessibilityLabel("评价 \(star) 星")
                .accessibilityValue(star <= value ? "已选" : "未选")
            }
        }
        .contentShape(Rectangle())
        .simultaneousGesture(DragGesture(minimumDistance: 2, coordinateSpace: .local)
            .onChanged { value = LiteratureRating.value(at: $0.location.x, width: width) }
            .onEnded { value = LiteratureRating.value(at: $0.location.x, width: width) })
        .help("点击或拖动选择星级，点勾号保存")
    }
}
