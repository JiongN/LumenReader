import SwiftUI
import LumenKit

struct SidebarColumn: View {

    @EnvironmentObject private var bridge: ReaderBridge
    @EnvironmentObject private var state: AppState

    @State private var query: String = ""

    private var availableTabs: [SidebarTab] {
        state.document?.kind == .pdf
            ? [.outline, .search, .thumbnails]
            : [.outline, .search]
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
                case .outline:    outlineList.transition(.opacity)
                case .search:     searchPane.transition(.opacity)
                case .thumbnails: ThumbnailPane().transition(.opacity)
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
                    HStack(spacing: 5) {
                        Image(systemName: tab.systemImage)
                            .font(DS.Typo.ui(size: 11, weight: .medium))
                        Text(tab.title)
                            .font(DS.Typo.ui(size: 11.5, weight: .medium))
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
            }
        }
        .padding(3)
        .background(
            RoundedRectangle(cornerRadius: DS.Radius.m, style: .continuous)
                .fill(DS.Palette.surfaceSunken)
        )
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

                        ForEach(bridge.searchResults) { hit in
                            SearchHitRow(hit: hit)
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

    @EnvironmentObject private var bridge: ReaderBridge
    @State private var isHovering = false

    var body: some View {
        Button {
            bridge.goTo?(hit.locator)
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
