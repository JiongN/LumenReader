import SwiftUI
import LumenKit

struct SidebarColumn: View {

    @EnvironmentObject private var bridge: ReaderBridge
    @EnvironmentObject private var state: AppState

    @State private var query: String = ""

    private var availableTabs: [SidebarTab] {
        state.document?.kind == .pdf
            ? [.outline, .smartOutline, .search, .annotations, .thumbnails]
            : [.outline, .smartOutline, .search, .annotations]
    }

    var body: some View {
        VStack(spacing: 0) {
            picker
            Divider().overlay(DS.Palette.separator)

            // 三个页签之间交叉淡入。
            //
            // 目录是稀疏的树、搜索是密集的结果列表、缩略图是满屏图片网格，
            // 三者的「视觉密度」差得很远；硬切时侧栏整块会闪一下，像是重新加载了。
            // 动画由 `picker` 里那句 `withAnimation(DS.Motion.quick)` 提供——
            // 页签切换是轻量操作，用 quick 比用面板那套弹簧更跟手。
            Group {
                switch bridge.sidebarTab {
                case .outline:      outlineList.transition(.opacity)
                case .smartOutline: SmartOutlinePane().transition(.opacity)
                case .search:       searchPane.transition(.opacity)
                case .annotations:  AnnotationsPane().transition(.opacity)
                case .thumbnails:   ThumbnailPane().transition(.opacity)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(.regularMaterial)
    }

    // MARK: - 页签

    private var picker: some View {
        HStack(spacing: 2) {
            ForEach(availableTabs) { tab in
                Button {
                    withAnimation(DS.Motion.quick) { bridge.sidebarTab = tab }
                } label: {
                    HStack(spacing: 3) {
                        Image(systemName: tab.systemImage)
                            .font(DS.Typo.ui(size: 10.5, weight: .medium))
                        Text(tab.title)
                            .font(DS.Typo.ui(size: 11, weight: .medium))
                            // 侧栏可以被拖到 180pt，那时每个页签只剩不到 40pt。
                            // 缩一点字号比截成「智…」强：截断的标签等于没有标签。
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
                    .contentShape(Rectangle())
                    .background(
                        RoundedRectangle(cornerRadius: DS.Radius.s, style: .continuous)
                            .fill(bridge.sidebarTab == tab ? DS.Palette.surfaceRaised : .clear)
                    )
                    .foregroundStyle(bridge.sidebarTab == tab ? DS.Palette.textPrimary : DS.Palette.textSecondary)
                }
                .buttonStyle(.plain)
                .help(tab.fullTitle)
            }
        }
        .padding(3)
        .background(
            RoundedRectangle(cornerRadius: DS.Radius.m, style: .continuous)
                .fill(DS.Palette.surfaceSunken)
        )
        // 页签栏是这次唯一改动版式的控件（3 个页签变 4 个），而它最容易出的问题是
        // 「在窄侧栏里把标签挤成省略号」——那种退化肉眼截图看不出来（模型也没有视觉通道），
        // 但它的宽高比会变。上报实际框，就能拿「宽度 ÷ 页签数」去核每个页签够不够。
        .layoutProbe("sidebarPicker")
        .padding(DS.Space.s)
    }

    // MARK: - 目录

    @ViewBuilder
    private var outlineList: some View {
        if bridge.outline.isEmpty {
            SidebarEmptyState(
                icon: "list.bullet.indent",
                title: "此文档没有目录",
                message: "PDF 未内嵌书签，或 EPUB 缺少 nav 文档。"
            )
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 1) {
                    ForEach(bridge.outline) { node in
                        OutlineRow(node: node)
                    }
                }
                .padding(.vertical, DS.Space.s)
                .padding(.horizontal, DS.Space.xs)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: - 搜索

    private var searchPane: some View {
        VStack(spacing: 0) {
            HStack(spacing: DS.Space.xs) {
                Image(systemName: "magnifyingglass")
                    .font(DS.Typo.ui(size: 11))
                    .foregroundStyle(DS.Palette.textTertiary)
                TextField("在文档内查找", text: $query)
                    .textFieldStyle(.plain)
                    .font(DS.Typo.body)
                    .onSubmit(runSearch)
                if !query.isEmpty {
                    Button {
                        query = ""
                        bridge.clearSearch?()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(DS.Typo.ui(size: 11))
                            .foregroundStyle(DS.Palette.textTertiary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, DS.Space.s)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: DS.Radius.s, style: .continuous)
                    .fill(DS.Palette.surfaceRaised)
            )
            .overlay(
                RoundedRectangle(cornerRadius: DS.Radius.s, style: .continuous)
                    .strokeBorder(DS.Palette.separator, lineWidth: 0.5)
            )
            .padding(DS.Space.s)

            Divider().overlay(DS.Palette.separator)

            if bridge.isSearching {
                VStack(spacing: DS.Space.s) {
                    ProgressView().controlSize(.small)
                    Text("正在查找…")
                        .font(DS.Typo.callout)
                        .foregroundStyle(DS.Palette.textTertiary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if bridge.searchResults.isEmpty {
                SidebarEmptyState(
                    icon: "magnifyingglass",
                    title: query.isEmpty ? "输入关键词开始查找" : "没有匹配结果",
                    message: query.isEmpty ? "回车执行查找。" : "换个词试试，查找不区分大小写。"
                )
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: DS.Space.xs) {
                        Text("\(bridge.searchResults.count) 处匹配")
                            .font(DS.Typo.caption)
                            .foregroundStyle(DS.Palette.textTertiary)
                            .padding(.horizontal, DS.Space.s)
                            .padding(.top, DS.Space.s)

                        // 带上序号：定位要按「第几条命中」走，才能滚到具体那一处，
                        // 而不是只翻到那一页的页顶。
                        ForEach(Array(bridge.searchResults.enumerated()), id: \.element.id) { index, hit in
                            SearchHitRow(hit: hit, index: index)
                        }
                    }
                    .padding(.horizontal, DS.Space.xs)
                    .padding(.bottom, DS.Space.m)
                }
            }
        }
    }

    private func runSearch() {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        bridge.searchQuery = trimmed
        bridge.performSearch?(trimmed)
    }
}

// MARK: - 目录行

struct OutlineRow: View {

    let node: OutlineNode

    @EnvironmentObject private var bridge: ReaderBridge
    @State private var isHovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Button {
                bridge.goTo?(node.locator)
            } label: {
                HStack(spacing: DS.Space.xs) {
                    RoundedRectangle(cornerRadius: 1)
                        .fill(node.depth == 0 ? DS.Palette.accent : DS.Palette.separator)
                        .frame(width: 2, height: node.depth == 0 ? 12 : 8)
                    Text(node.title)
                        .font(DS.Typo.ui(size: node.depth == 0 ? 12.5 : 12, weight: node.depth == 0 ? .medium : .regular))
                        .foregroundStyle(node.depth == 0 ? DS.Palette.textPrimary : DS.Palette.textSecondary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                }
                .padding(.leading, CGFloat(node.depth) * 12 + DS.Space.xs)
                .padding(.trailing, DS.Space.s)
                .padding(.vertical, 5)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
                .background(
                    RoundedRectangle(cornerRadius: DS.Radius.xs, style: .continuous)
                        .fill(isHovering ? DS.Palette.accentSoft : .clear)
                )
            }
            .buttonStyle(.plain)
            .onHover { hovering in
                withAnimation(DS.Motion.hover) { isHovering = hovering }
            }

            ForEach(node.children) { child in
                OutlineRow(node: child)
            }
        }
    }
}

// MARK: - 搜索结果行

struct SearchHitRow: View {

    let hit: SearchHit
    /// 命中在结果列表中的序号，用于把页面滚到具体那一处
    var index: Int = 0

    @EnvironmentObject private var bridge: ReaderBridge
    @State private var isHovering = false

    var body: some View {
        Button {
            if let reveal = bridge.revealSearchHit {
                reveal(index)
            } else {
                bridge.goTo?(hit.locator)
            }
        } label: {
            VStack(alignment: .leading, spacing: 3) {
                Text(hit.locator.displayLabel())
                    .font(DS.Typo.ui(size: 10, weight: .semibold))
                    .foregroundStyle(DS.Palette.accent)
                Text(hit.snippet)
                    .font(DS.Typo.ui(size: 11.5))
                    .foregroundStyle(DS.Palette.textSecondary)
                    .lineLimit(3)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(DS.Space.s)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: DS.Radius.s, style: .continuous)
                    .fill(isHovering ? DS.Palette.accentSoft : .clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(DS.Motion.hover) { isHovering = hovering }
        }
    }
}

// MARK: - 批注页签

/// 全书批注与高亮的清单。
///
/// 数据来自 `bridge.annotationsProvider`，也就是**当前阅读视图的实现**：
/// PDF 从原文件里的 PDFKit 批注扫出来，EPUB 从应用数据目录的 JSON 读出来。
/// 这一层不关心后端是哪种——两种格式的批注在这里汇合成同一套「点进去看、删掉」的交互。
struct AnnotationsPane: View {

    @EnvironmentObject private var bridge: ReaderBridge
    @EnvironmentObject private var state: AppState

    @State private var items: [AnnotationItem] = []
    @State private var isLoading = false

    var body: some View {
        Group {
            if isLoading && items.isEmpty {
                VStack(spacing: DS.Space.s) {
                    ProgressView().controlSize(.small)
                    Text("正在扫描批注…").font(DS.Typo.callout).foregroundStyle(DS.Palette.textTertiary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if items.isEmpty {
                SidebarEmptyState(
                    icon: "square.and.pencil",
                    title: "还没有批注",
                    message: "在正文里划选文字，点浮条上的「高亮」或「批注」即可标记；"
                        + "AI 回答下的「添加到批注」会把整条回复写进当前页。"
                )
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: DS.Space.xs) {
                        Text("\(items.count) 条批注")
                            .font(DS.Typo.caption)
                            .foregroundStyle(DS.Palette.textTertiary)
                            .padding(.horizontal, DS.Space.s)
                            .padding(.top, DS.Space.s)

                        ForEach(items) { item in
                            AnnotationRow(item: item) { deleted in
                                guard deleted else { return }
                                withAnimation(DS.Motion.quick) {
                                    items.removeAll { $0.id == item.id }
                                }
                            }
                        }
                    }
                    .padding(.horizontal, DS.Space.xs)
                    .padding(.bottom, DS.Space.m)
                }
            }
        }
        // 按批注变更计数刷新：无论批注是写进 PDF 还是写进数据目录，
        // 两条路径都会把 `annotationRevision` 加一。
        .task(id: bridge.annotationRevision) { await reload() }
    }

    private func reload() async {
        guard let provider = bridge.annotationsProvider else { items = []; return }
        isLoading = true
        items = await provider()
        isLoading = false
    }
}

struct AnnotationRow: View {

    let item: AnnotationItem
    let onDelete: (Bool) -> Void

    @EnvironmentObject private var bridge: ReaderBridge
    @State private var isHovering = false
    @State private var isDeleting = false

    var body: some View {
        HStack(alignment: .top, spacing: DS.Space.xs) {
            Button {
                bridge.goTo?(item.locator)
            } label: {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 4) {
                        Image(systemName: item.hasHighlight ? "highlighter" : "note.text")
                            .font(DS.Typo.ui(size: 9.5, weight: .semibold))
                        Text(item.locator.displayLabel(chapterTitles: bridge.outline.map(\.title)))
                            .font(DS.Typo.ui(size: 10, weight: .semibold))
                    }
                    .foregroundStyle(DS.Palette.accent)

                    if !item.quote.isEmpty {
                        Text(item.quote)
                            .font(DS.Typo.ui(size: 11))
                            .foregroundStyle(DS.Palette.textTertiary)
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Text(item.preview)
                        .font(DS.Typo.ui(size: 11.5))
                        .foregroundStyle(DS.Palette.textSecondary)
                        .lineLimit(4)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if isHovering {
                Button {
                    delete()
                } label: {
                    Image(systemName: isDeleting ? "clock" : "trash")
                        .font(DS.Typo.ui(size: 10))
                        .foregroundStyle(DS.Palette.danger)
                }
                .buttonStyle(.plain)
                .disabled(isDeleting)
                .help("删除这条批注")
                .transition(.opacity)
            }
        }
        .padding(DS.Space.s)
        .background(
            RoundedRectangle(cornerRadius: DS.Radius.s, style: .continuous)
                .fill(isHovering ? DS.Palette.surfaceRaised : .clear)
        )
        .onHover { hovering in
            withAnimation(DS.Motion.hover) { isHovering = hovering }
        }
    }

    private func delete() {
        isDeleting = true
        Task {
            let ok = await bridge.deleteAnnotation?(item.id) ?? false
            isDeleting = false
            onDelete(ok)
        }
    }
}

// MARK: - 空状态

struct SidebarEmptyState: View {
    let icon: String
    let title: String
    let message: String

    var body: some View {
        VStack(spacing: DS.Space.s) {
            Image(systemName: icon)
                .font(DS.Typo.ui(size: 22))
                .foregroundStyle(DS.Palette.textTertiary)
            Text(title)
                .font(DS.Typo.callout)
                .foregroundStyle(DS.Palette.textSecondary)
            Text(message)
                .font(DS.Typo.ui(size: 11))
                .foregroundStyle(DS.Palette.textTertiary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(DS.Space.xl)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
