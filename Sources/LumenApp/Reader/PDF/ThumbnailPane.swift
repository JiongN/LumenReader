import SwiftUI
import AppKit
import LumenKit

struct ThumbnailPane: View {
    @EnvironmentObject private var bridge: ReaderBridge
    @EnvironmentObject private var state: AppState
    @EnvironmentObject private var session: ReaderSession
    var body: some View {
        ThumbnailList(viewport: bridge.viewport, bridge: bridge, documentID: session.document.id,
                      theme: state.settingsStore.reader.theme,
                      originalColors: state.settingsStore.reader.pdfOriginalColors)
    }
}

private struct ThumbnailList: View {
    @ObservedObject var viewport: PDFViewportState
    let bridge: ReaderBridge
    let documentID: String?
    let theme: ReadingTheme
    let originalColors: Bool
    @State private var cache = ThumbnailCache(capacity: ThumbnailCache.defaultCapacity)
    @State private var pending: Set<Int> = []
    @State private var generation = UUID()
    @State private var visible = VisibleTracker()
    @State private var scrollPosition = ScrollPosition(y: 0)
    @State private var viewportHeight: CGFloat = 0
    @State private var manuallyScrolling = false
    private let width: CGFloat = 132
    private static let renderQueue = DispatchQueue(label: "com.jn.lumen.thumbnail", qos: .utility)

    private func aspect(_ index: Int) -> CGFloat {
        viewport.pageAspects.indices.contains(index) ? viewport.pageAspects[index] : 1.4
    }

    var body: some View {
        let _ = Jank.tick(.thumbnailPaneBody)
        ScrollView {
            LazyVStack(spacing: 12) {
                ForEach(0..<bridge.unitCount, id: \.self) { index in
                    ThumbnailRow(index: index, image: cache[index], isCurrent: index == viewport.snapshot.centerPage,
                                 width: width, aspect: aspect(index), visibleRect: viewport.snapshot.pageRects[index],
                                 theme: theme, originalColors: originalColors) {
                        manuallyScrolling = false
                        bridge.goTo?(.pdf(page: index, charOffset: 0))
                    }
                    .id(index)
                    .onAppear { visible.insert(index); request(index) }
                    .onDisappear { visible.remove(index) }
                }
            }
            .padding(.vertical, 12)
        }
        .scrollPosition($scrollPosition)
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { viewportHeight = $0 }
        .onScrollPhaseChange { _, phase in
            manuallyScrolling = phase == .tracking || phase == .interacting || phase == .decelerating
        }
        .onChange(of: viewport.snapshot) { _, snapshot in
            guard !manuallyScrolling else { return }
            follow(snapshot)
        }
        .onChange(of: documentID) { _, _ in reset() }
        .onChange(of: viewport.snapshot.documentID) { _, _ in reset() }
        .onChange(of: bridge.annotationRevision) { _, _ in reset() }
        .onAppear { follow(viewport.snapshot) }
    }

    private func follow(_ snapshot: PDFViewportState.Snapshot) {
        let page = min(max(0, snapshot.centerPage), max(0, bridge.unitCount - 1))
        let preceding = (0..<page).reduce(CGFloat(12)) { $0 + width * aspect($1) + 36 }
        let target = max(0, preceding + width * aspect(page) * snapshot.centerProgress - viewportHeight / 2)
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) { scrollPosition.scrollTo(y: target) }
    }

    private func reset() {
        generation = UUID()
        cache.removeAll()
        pending.removeAll()
        for index in visible.snapshot() { request(index) }
    }

    private func request(_ index: Int) {
        guard cache[index] == nil, !pending.contains(index), let provider = bridge.thumbnailProvider else { return }
        pending.insert(index)
        let requestGeneration = generation
        let tracker = visible
        let size = CGSize(width: width * 2, height: width * aspect(index) * 2)
        Self.renderQueue.async {
            guard tracker.contains(index) else {
                DispatchQueue.main.async {
                    if generation == requestGeneration { pending.remove(index) }
                }
                return
            }
            Jank.tick(.thumbnailRender)
            let image = provider(index, size)
            DispatchQueue.main.async {
                guard generation == requestGeneration else { return }
                pending.remove(index)
                if let image { cache.store(image, at: index, current: viewport.snapshot.centerPage) }
            }
        }
    }
}

private final class VisibleTracker: @unchecked Sendable {
    private let lock = NSLock()
    private var indices: Set<Int> = []
    func insert(_ index: Int) { lock.lock(); defer { lock.unlock() }; indices.insert(index) }
    func remove(_ index: Int) { lock.lock(); defer { lock.unlock() }; indices.remove(index) }
    func contains(_ index: Int) -> Bool { lock.lock(); defer { lock.unlock() }; return indices.contains(index) }
    func snapshot() -> Set<Int> { lock.lock(); defer { lock.unlock() }; return indices }
}

private struct ThemedThumbnailImage: NSViewRepresentable {
    let image: NSImage
    let theme: ReadingTheme
    let original: Bool
    final class Coordinator {
        var theme: ReadingTheme?
        var original: Bool?
    }
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> NSImageView {
        let view = NSImageView()
        view.imageScaling = .scaleProportionallyUpOrDown
        view.wantsLayer = true
        return view
    }
    func updateNSView(_ view: NSImageView, context: Context) {
        if view.image !== image { view.image = image }
        if context.coordinator.theme != theme || context.coordinator.original != original {
            context.coordinator.theme = theme
            context.coordinator.original = original
            view.contentFilters = original ? [] : PDFReadingAppearance.filter(theme: theme).map { [$0] } ?? []
        }
    }
}

private struct ThumbnailRow: View {

    let index: Int
    let image: NSImage?
    let isCurrent: Bool
    let width: CGFloat
    let aspect: CGFloat
    let visibleRect: CGRect?
    let theme: ReadingTheme
    let originalColors: Bool
    let onTap: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: onTap) {
            VStack(spacing: 6) {
                thumbnail
                    .frame(width: width, height: width * aspect)

                pageNumber.frame(height: 18)
            }
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(DS.Motion.hover) { isHovering = hovering }
        }
        .help("跳到第 \(index + 1) 页")
        // 图片由 nil 变有值的那一刻做淡入；选中态单独用更快的节奏，
        // 两者用同一个 value 会让翻页时的选中反馈被图片加载拖慢。
        .animation(DS.Motion.content, value: image == nil)
        .transaction { $0.animation = nil }
    }

    // MARK: 缩略图主体

    /// 当前页 = 强调色描边 + 外圈柔光晕。光是描边只有 2pt，
    /// 在整栏缩略图里扫过去容易漏；一圈低透明度的光晕把「选中」
    /// 从一条线升格为一块面，视野边缘也能定位到。
    private var thumbnail: some View {
        ZStack {
            RoundedRectangle(cornerRadius: DS.Radius.s, style: .continuous)
                .fill(DS.Palette.surfaceRaised)

            if let image {
                ThemedThumbnailImage(image: image, theme: theme, original: originalColors)
                    .padding(2)
                    // 淡入而不是硬闪：缩略图是逐个渲染出来的，
                    // 硬切会让侧栏看起来一直在"跳"。
                    .transition(.opacity)
            } else {
                skeleton
            }
        }
        .overlay {
            if let rect = visibleRect {
                GeometryReader { proxy in
                    Rectangle()
                        .fill(theme.accent.opacity(0.08))
                        .overlay(Rectangle().stroke(theme.accent, lineWidth: 1))
                        .frame(width: max(0, proxy.size.width - 4) * rect.width,
                               height: max(0, proxy.size.height - 4) * rect.height)
                        .offset(x: 2 + (proxy.size.width - 4) * rect.minX,
                                y: 2 + (proxy.size.height - 4) * rect.minY)
                }
                .allowsHitTesting(false)
            }
        }
        .overlay(
            RoundedRectangle(cornerRadius: DS.Radius.s, style: .continuous)
                .strokeBorder(borderColor, lineWidth: isCurrent ? 2 : 0.5)
        )
        .background(
            RoundedRectangle(cornerRadius: DS.Radius.m, style: .continuous)
                .fill(isCurrent ? DS.Palette.accentSoft : .clear)
                .padding(-5)
        )
        .shadow(
            color: .black.opacity(0.06),
            radius: 2,
            y: 1
        )
    }

    // MARK: 页码

    /// 当前页的页码升级为实心徽章（参考用户提供的联动样式截图）：
    /// 数字落在胶囊里，是滚动联动时唯一需要「看清」的信息；
    /// 其余页保持裸数字，视觉重量全部让给当前页。
    @ViewBuilder
    private var pageNumber: some View {
        if isCurrent {
            Text("\(index + 1)")
                .font(DS.Typo.ui(size: 10, weight: .semibold))
                .foregroundStyle(theme.isDark ? theme.background : Color.white)
                .padding(.horizontal, 8)
                .padding(.vertical, 2.5)
                .background(
                    Capsule().fill(DS.Palette.accent)
                )
                .monospacedDigit()
                .transition(.scale(scale: 0.8).combined(with: .opacity))
        } else {
            Text("\(index + 1)")
                .font(DS.Typo.ui(size: 10, weight: .regular))
                .foregroundStyle(isHovering ? DS.Palette.textSecondary : DS.Palette.textTertiary)
                .monospacedDigit()
        }
    }

    private var borderColor: Color {
        if isCurrent { return DS.Palette.accent }
        if isHovering { return DS.Palette.accent.opacity(0.5) }
        return DS.Palette.separator
    }

    /// 还没渲染出来时的占位。
    ///
    /// 不用 `ProgressView`：转圈意味着「正在算」，而这里大多数时候只是在排队，
    /// 一圈圈转着会让人以为卡住了。一块安静的骨架更像是「内容马上就来」。
    private var skeleton: some View {
        RoundedRectangle(cornerRadius: 2, style: .continuous)
            .fill(DS.Palette.surfaceSunken)
            .padding(2)
            .overlay(
                Image(systemName: "doc.text")
                    .font(DS.Typo.ui(size: 16))
                    .foregroundStyle(DS.Palette.textTertiary.opacity(0.3))
            )
    }
}
