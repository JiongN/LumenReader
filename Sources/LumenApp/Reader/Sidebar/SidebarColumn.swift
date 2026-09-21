import SwiftUI
import LumenKit

/// 侧栏的**内容面板**。
///
/// 页签选择器已经搬到左侧那条常驻图标栏（`LeftRail`）里了，这里只留内容。
/// 拆分的原因很实际：选择器原本长在面板顶部，面板一收起，切页签的入口就跟着消失了；
/// 图标栏常驻之后，「收起内容面板」不再等于「失去导航」。
struct SidebarColumn: View {

    @EnvironmentObject private var bridge: ReaderBridge
    @EnvironmentObject private var state: AppState

    @State private var query: String = ""

    var body: some View {
        // 卡顿自检：body 每次求值都记一次（不能做成 ViewModifier——见 JankAudit 注释）。
        let _ = Jank.tick(.sidebarBody)
        VStack(spacing: 0) {
            // 页签之间交叉淡入。
            //
            // 目录是稀疏的树、搜索是密集的结果列表、缩略图是满屏图片网格，
            // 三者的「视觉密度」差得很远；硬切时侧栏整块会闪一下，像是重新加载了。
            // 动画由发起切换的那一侧提供（`LeftRail` 的点击、`revealSidebar`）—
            // 页签切换是轻量操作，用 quick 比用面板那套弹簧更跟手。
            // 每个页签挂一个**静态名**探针：`--sidebar-tab-report` 用它证明「内容真的换了」。
            //
            // 只断言 `bridge.sidebarTab` 是不够的（项目里踩过「状态变了但界面没换」这类假绿），
            // 探针**在视图摘下时会注销**（见 `LayoutProbe.onDisappear`），所以
            // 「新页签的探针在位 + 旧页签的探针消失」这一对读数才是真证据。
            //
            // ⚠️ 名字必须**静态**。第一版写成了 `.layoutProbe("sidebarPane_\(bridge.sidebarTab.rawValue)")`，
            // 结果是：页签切换时视图标识不变、`LayoutProbe.body` 只是重算了一个新 `name`，
            // 而 `onAppear` 不会重触发、`onChange(of: frame)` 也不会（frame 没变）——
            // 于是**记录里的名字永远停在切换前那一个**，读数滞后一整步。
            Group {
                switch bridge.sidebarTab {
                case .outline:
                    outlineList
                        .layoutProbe("sidebarPane_outline")
                case .smartOutline:
                    SmartOutlinePane()
                        .layoutProbe("sidebarPane_smartOutline")
                case .search:
                    searchPane
                        .layoutProbe("sidebarPane_search")
                case .annotations:
                    AnnotationsPane()
                        .layoutProbe("sidebarPane_annotations")
                case .thumbnails:
                    ThumbnailPane()
                        .layoutProbe("sidebarPane_thumbnails")
                case .translation:
                    if let controller = bridge.pdfTranslationController {
                        PDFTranslationPane(controller: controller)
                            .layoutProbe("sidebarPane_translation")
                    } else {
                        SidebarEmptyState(
                            icon: "character.book.closed",
                            title: "正在准备翻译",
                            message: "PDF 载入完成后即可使用。"
                        )
                        .layoutProbe("sidebarPane_translation")
                    }
                }
            }
            // 强制「切回同页签」时视图 identity 也变化，否则 SwiftUI 会把该页签内容当成
            // 半挂载幽灵——`onAppear` 不重触发、布局探针不重建（实测踩过：sidebar-tab-report
            // 对默认页签「切走→切回」后 `sidebarPane_outline` 永久缺席）。见
            // `ReaderBridge.sidebarTabRevision` 注释。
            // 注意：这里动的是**视图内容**的 identity，探针名字仍是静态的——
            // 不落入「动态命名探针读数滞后一整步」那个坑。
            .id(bridge.sidebarTabRevision)
            // 交叉淡入从每个内容 cell 移到 Group 外：`.id` 重建整个 Group 时，若 transition
            // 还长在 cell 上，旧内容淡出与新内容淡入重叠，`onAppear` 仍可能被吞；移出来后
            // 整块 Group 淡入淡出，视觉效果一致、探针更可靠。
            .transition(.opacity)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(DS.Palette.surfaceSunken)
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
            VStack(alignment: .leading, spacing: 5) {
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
            .padding(.horizontal, DS.Space.s)
            .padding(.vertical, DS.Space.s)
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
/// 这一层不关心后端是哪种——两种格式的批注在这里汇合成同一套
/// 「点进去定位、就地编辑、新建、删除」的交互。
struct AnnotationsPane: View {

    @EnvironmentObject private var bridge: ReaderBridge
    @EnvironmentObject private var state: AppState

    @State private var items: [AnnotationItem] = []
    @State private var isLoading = false
    /// 正在编辑的批注。编辑态由面板统一持有而不是各行自持：
    /// 「新建」要直接进入编辑态，而新建的行要等刷新后才出现，行内的 @State 接不住。
    @State private var editingID: String?
    /// 「扩到整行」的确认框。它要改用户的 PDF 文件，必须先说清代价再动手。
    @State private var showingNormalizeConfirm = false

    var body: some View {
        Group {
            if isLoading && items.isEmpty {
                VStack(spacing: DS.Space.s) {
                    ProgressView().controlSize(.small)
                    Text("正在扫描批注…").font(DS.Typo.callout).foregroundStyle(DS.Palette.textTertiary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if items.isEmpty {
                emptyState
            } else {
                list
            }
        }
        // 按批注变更计数刷新：无论批注是写进 PDF 还是写进数据目录，
        // 两条路径都会把 `annotationRevision` 加一。
        .task(id: bridge.annotationRevision) { await reload() }
        .confirmationDialog(
            "把 \(truncatedCount) 条高亮的范围扩到整行？",
            isPresented: $showingNormalizeConfirm,
            titleVisibility: .visible
        ) {
            Button("扩到整行并写回 PDF") { normalizeRows() }
            Button("取消", role: .cancel) {}
        } message: {
            Text("只加宽本应用画的高亮（把「只圈住划中的几个字」扩成整行），"
                 + "不改动任何文字，也不碰 Preview / Acrobat 画的批注。"
                 + "会直接写回这个 PDF 文件；文件很大时可能需要一两秒。")
        }
    }

    // MARK: 头部（计数 + 新建）

    private var header: some View {
        HStack(spacing: DS.Space.xs) {
            Text("\(items.count) 条批注")
                .font(DS.Typo.caption)
                .foregroundStyle(DS.Palette.textTertiary)
            Spacer(minLength: 0)
            Button {
                addNote()
            } label: {
                Label("新建批注", systemImage: "plus")
                    .font(DS.Typo.ui(size: 11, weight: .medium))
            }
            .buttonStyle(.plain)
            .foregroundStyle(DS.Palette.accent)
            .help("在当前阅读位置加一条空白批注")
        }
        .padding(.horizontal, DS.Space.s)
        .padding(.vertical, DS.Space.s)
    }

    private var emptyState: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(DS.Palette.separator)
            SidebarEmptyState(
                icon: "square.and.pencil",
                title: "还没有批注",
                message: "在正文里划选文字，点浮条上的「高亮」或「批注」即可标记；"
                    + "点正文里的高亮，这里会定位到对应条目。"
            )
        }
    }

    private var list: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(DS.Palette.separator)

            if truncatedCount > 0 { truncationNotice }

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: DS.Space.xs) {
                        ForEach(items) { item in
                            AnnotationRow(
                                item: item,
                                isFocused: bridge.focusedAnnotationID == item.id,
                                isInEditMode: editingID == item.id,
                                onBeginEdit: { editingID = item.id },
                                onEndEdit: { editingID = nil }
                            )
                            .id(item.id)
                        }
                    }
                    .padding(.horizontal, DS.Space.xs)
                    .padding(.top, DS.Space.xs)
                    .padding(.bottom, DS.Space.m)
                }
                // 正文里点了批注（或刚新建）→ 列表滚到对应行，聚焦环指明是哪一条。
                // 聚焦值会被 reset 清掉，滚动的发起只认「从 nil 变为有值」。
                .onChange(of: bridge.annotationFocusRevision, initial: true) { _, _ in
                    guard let id = bridge.focusedAnnotationID else { return }
                    withAnimation(DS.Motion.quick) { proxy.scrollTo(id, anchor: .center) }
                }
                .onChange(of: items.map(\.id)) { _, _ in
                    if let id = bridge.focusedAnnotationID { proxy.scrollTo(id, anchor: .center) }
                }
            }
        }
    }

    private func addNote() {
        Task {
            guard let item = await bridge.addNoteAtCurrentPosition?() else {
                state.showToast("新建批注失败", isError: true)
                return
            }
            await reload()
            bridge.focusedAnnotationID = item.id
            editingID = item.id
        }
    }

    /// 「文件里存的还是半行」的条数。为 0 时整条提示不出现——
    /// 修好之后它自己消失，不需要用户去猜这个入口还有没有用。
    private var truncatedCount: Int { items.filter(\.truncated).count }

    /// 把文件里的半行矩形扩到整行（会改用户的 PDF，所以先弹确认）。
    private func normalizeRows() {
        guard let normalize = bridge.normalizeAnnotationRows else { return }
        let changed = normalize()
        guard changed > 0 else {
            state.showToast("没有需要修正的高亮", isError: true)
            return
        }
        // 清单由 `annotationRevision` 触发重载（写盘成功时已自增），这里只报结果。
        state.showToast("已把 \(changed) 条高亮扩到整行并写回 PDF")
    }

    private func reload() async {
        guard let provider = bridge.annotationsProvider else { items = []; return }
        isLoading = true
        let loaded = await provider()
        guard !Task.isCancelled else { return }
        items = loaded
        isLoading = false
    }

    /// 「文件里的高亮还是半行」的提示条。
    ///
    /// 为什么要露出这件事：列表里的引文**已经**按整行显示（读取侧补算了），
    /// 所以用户看不出文件里存的其实是半行——直到他用系统「预览」打开同一个 PDF。
    /// 与其让这个差异在别处暴露，不如在这里说清并给出唯一的修正入口。
    /// 只在真有这类批注时出现，修完自己消失。
    private var truncationNotice: some View {
        HStack(alignment: .top, spacing: DS.Space.xs) {
            Image(systemName: "exclamationmark.triangle")
                .font(DS.Typo.ui(size: 10, weight: .semibold))
                .foregroundStyle(DS.Palette.warning)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 2) {
                Text("\(truncatedCount) 条高亮只圈住了划中的文字")
                    .font(DS.Typo.ui(size: 10.5, weight: .medium))
                    .foregroundStyle(DS.Palette.textPrimary)
                Text("列表已按整行显示；文件里存的仍是半行")
                    .font(DS.Typo.ui(size: 10))
                    .foregroundStyle(DS.Palette.textTertiary)
            }
            Spacer(minLength: 0)
            Button("扩到整行") { showingNormalizeConfirm = true }
                .buttonStyle(.plain)
                .font(DS.Typo.ui(size: 10.5, weight: .semibold))
                .foregroundStyle(DS.Palette.accent)
                .fixedSize()
                .help("把文件里这些高亮的范围改宽到整行（会写回 PDF）")
        }
        .padding(.horizontal, DS.Space.s)
        .padding(.vertical, DS.Space.xs)
        .background(DS.Palette.accentSoft)
    }
}

// MARK: 批注行

/// 一条批注的卡片。信息**纵向**排列：定位 → 引文 → 批注正文，每层独立一行——
/// 批注面板经常被拖到 200pt 上下的宽度，横向塞两列会互相挤压成省略号；
/// 纵向排列后每层都能占满整行宽，行数换可读性是划算的。
/// 编辑、删除收进悬停出现的头部操作区，平时不占空间。
struct AnnotationRow: View {

    let item: AnnotationItem
    /// 正文刚点中这条批注（或刚新建）时的聚焦态：描边 + 淡色底
    let isFocused: Bool
    let isInEditMode: Bool
    let onBeginEdit: () -> Void
    let onEndEdit: () -> Void

    @EnvironmentObject private var bridge: ReaderBridge
    @State private var isHovering = false
    @State private var isDeleting = false
    @State private var isSaving = false
    @State private var draft: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.xs) {
            // 定位行：类型标识 + 所在位置，悬停时右端浮出操作按钮
            HStack(spacing: 4) {
                // 类型标识：高亮用**与页面一致的色块**，便签用图标 + 「便签」二字。
                //
                // 为什么不用原来的「换个 SF Symbol」了事：高亮和便签都是一条批注，
                // 只有图标差异时，用户看不出「清单里这条对应页面上哪一块颜色」，
                // 也容易把便签误读成高亮。色块 + 文字是最省空间的消歧方式。
                if item.hasHighlight {
                    Circle()
                        .fill(highlightColor)
                        .frame(width: 9, height: 9)
                        .overlay(Circle().strokeBorder(DS.Palette.separator, lineWidth: 0.5))
                        .help(item.highlightHex.map { "高亮 · \($0)" } ?? "高亮")
                        .accessibilityLabel("高亮")
                } else {
                    Image(systemName: "note.text")
                        .font(DS.Typo.ui(size: 9.5, weight: .semibold))
                        .accessibilityLabel("便签")
                    Text("便签")
                        .font(DS.Typo.ui(size: 9.5, weight: .semibold))
                        .foregroundStyle(DS.Palette.textTertiary)
                }
                Text(item.locator.displayLabel(chapterTitles: bridge.outline.map(\.title)))
                    .font(DS.Typo.ui(size: 10, weight: .semibold))
                    .lineLimit(1)
                Spacer(minLength: 0)
                if isHovering && !isInEditMode {
                    HoverActionButton(systemImage: "pencil", help: "编辑批注", role: .normal) {
                        draft = item.note
                        onBeginEdit()
                    }
                    HoverActionButton(systemImage: isDeleting ? "clock" : "trash",
                                       help: "删除这条批注", role: .danger) {
                        delete()
                    }
                }
            }
            .foregroundStyle(DS.Palette.accent)

            // 引文（划了哪段原文）。有高亮的批注才可能有引文。
            if !item.quote.isEmpty {
                Text(item.quote)
                    .font(DS.Typo.ui(size: 11))
                    .foregroundStyle(DS.Palette.textTertiary)
                    .lineLimit(3)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
            }

            // 批注正文 / 编辑器
            if isInEditMode {
                VStack(alignment: .leading, spacing: DS.Space.xs) {
                    TextEditor(text: $draft)
                        .font(DS.Typo.ui(size: 11.5))
                        .frame(minHeight: 56, maxHeight: 120)
                        .scrollContentBackground(.hidden)
                        .padding(4)
                        .background(
                            RoundedRectangle(cornerRadius: DS.Radius.xs, style: .continuous)
                                .fill(DS.Palette.surfaceSunken)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: DS.Radius.xs, style: .continuous)
                                .strokeBorder(DS.Palette.separator, lineWidth: 0.5)
                        )
                    HStack(spacing: DS.Space.s) {
                        Button {
                            save()
                        } label: {
                            Text(isSaving ? "保存中…" : "保存")
                                .font(DS.Typo.ui(size: 11, weight: .medium))
                                .padding(.horizontal, 10)
                                .padding(.vertical, 3)
                                .background(
                                    Capsule().fill(DS.Palette.accent)
                                )
                                .foregroundStyle(Color.white)
                        }
                        .buttonStyle(.plain)
                        .disabled(isSaving)

                        Button("取消") { onEndEdit() }
                            .font(DS.Typo.ui(size: 11))
                            .buttonStyle(.plain)
                            .foregroundStyle(DS.Palette.textSecondary)
                    }
                }
            } else if !item.note.isEmpty {
                Text(item.note)
                    .font(DS.Typo.ui(size: 11.5))
                    .foregroundStyle(DS.Palette.textSecondary)
                    .lineLimit(6)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, DS.Space.s)
        .padding(.vertical, DS.Space.s + 2)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: DS.Radius.s, style: .continuous)
                .fill(cardColor)
        )
        .overlay(
            RoundedRectangle(cornerRadius: DS.Radius.s, style: .continuous)
                .strokeBorder(isFocused ? DS.Palette.accent.opacity(0.55) : .clear, lineWidth: 1)
        )
        .contentShape(RoundedRectangle(cornerRadius: DS.Radius.s, style: .continuous))
        .onTapGesture {
            // 点击卡片 = 正文里定位到这一处（翻页 + 滚到位置 + 划线类选中原文）
            bridge.focusAnnotation(item.id)
            bridge.revealAnnotation?(item.id)
        }
        .onHover { hovering in
            withAnimation(DS.Motion.hover) { isHovering = hovering }
        }
    }

    /// 高亮色块的填充色。
    ///
    /// 从 `#RRGGBB` 解析；拿不到（PDF 没设色、外来批注、EPUB）就回退到主题强调色——
    /// 宁可颜色不准也不要一个看不见的空白格子。
    private var highlightColor: Color {
        guard let hex = item.highlightHex else { return DS.Palette.accent }
        return Color(hexString: hex) ?? DS.Palette.accent
    }

    private var cardColor: Color {
        if isFocused { return DS.Palette.accentSoft }
        if isHovering { return DS.Palette.surfaceRaised }
        return .clear
    }

    private func save() {
        isSaving = true
        let note = draft
        Task {
            let ok = await bridge.updateAnnotationNote?(item.id, note) ?? false
            isSaving = false
            if ok {
                onEndEdit()
            } else {
                // 保存失败时留在编辑态，草稿不丢——关掉等于让用户重打一遍
            }
        }
    }

    private func delete() {
        isDeleting = true
        Task {
            let ok = await bridge.deleteAnnotation?(item.id) ?? false
            isDeleting = false
            if ok {
                // 列表按 annotationRevision 刷新，这里只处理本地即时反馈
            }
        }
    }
}

/// 卡片头部的悬停小按钮。图标 + 语义色，悬停给反馈。
private struct HoverActionButton: View {

    let systemImage: String
    let help: String
    let role: Role
    let action: () -> Void

    enum Role { case normal, danger }

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(DS.Typo.ui(size: 10))
                .foregroundStyle(role == .danger ? DS.Palette.danger : DS.Palette.textSecondary)
                .padding(3)
                .background(
                    RoundedRectangle(cornerRadius: DS.Radius.xs, style: .continuous)
                        .fill(isHovered ? DS.Palette.surfaceSunken : .clear)
                )
        }
        .buttonStyle(.plain)
        .help(help)
        .onHover { isHovered = $0 }
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