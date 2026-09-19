import SwiftUI
import AppKit
import LumenKit

struct ThumbnailPane: View {
    @EnvironmentObject private var bridge: ReaderBridge
    @EnvironmentObject private var state: AppState
    @EnvironmentObject private var session: ReaderSession

    var body: some View {
        ThumbnailPaneBody(
            viewport: bridge.viewport,
            bridge: bridge,
            documentID: session.document.id,
            theme: state.settingsStore.reader.theme,
            originalColors: state.settingsStore.reader.pdfOriginalColors,
            annotationRevision: bridge.annotationRevision
        )
    }
}

/// 视口观察者：把「每帧都在变的东西」收敛成几个粗粒度输入，再交给卡片列表。
///
/// 这一层存在的唯一理由是性能。视口的 snapshot 在滚动时**每帧都发布一次**，
/// 而列表只关心「当前是第几页」——把 snapshot 直接喂给列表，等于让整个
/// `LazyVStack` 每帧重排一次（自检读数：滚动时 `ThumbnailPane.body` 4 次/步）。
/// 这里把页号单独取出来，列表那边用 `Equatable` 挡住「输入没变就不重算」。
private struct ThumbnailPaneBody: View {

    @ObservedObject var viewport: PDFViewportState
    let bridge: ReaderBridge
    let documentID: String?
    let theme: ReadingTheme
    let originalColors: Bool
    let annotationRevision: Int

    @State private var currentPage = 0

    var body: some View {
        ThumbnailGrid(
            pageAspects: viewport.pageAspects,
            currentPage: currentPage,
            unitCount: bridge.unitCount,
            documentID: documentID,
            theme: theme,
            originalColors: originalColors,
            annotationRevision: annotationRevision,
            viewport: viewport,
            bridge: bridge
        )
        // 关键：`Equatable` 子视图。父级每帧重算并不贵（只是构造一个值），
        // 真正的开销是子视图的 body；输入不变时这里直接跳过。
        .equatable()
        .onChange(of: viewport.snapshot.centerPage) { _, page in currentPage = page }
        .onAppear { currentPage = viewport.snapshot.centerPage }
    }
}

/// 缩略图卡片列表。
///
/// 尺寸 / 间距 / 圆角 / 选中态按参考样式（docs/images 里的那张）逐像素量出来：
/// 卡片 108pt 宽、圆角 6.5pt、卡片 → 页码 6pt、页码 → 下一张 8pt，
/// 选中态是「卡片外一圈 2.5pt 强调色描边 + 同色柔光」，卡片本体不变色。
private struct ThumbnailGrid: View, Equatable {

    let pageAspects: [CGFloat]
    let currentPage: Int
    let unitCount: Int
    let documentID: String?
    let theme: ReadingTheme
    let originalColors: Bool
    let annotationRevision: Int
    /// 只读：取当前页号做缓存淘汰用。刻意不做 `@ObservedObject`——
    /// 一观察它，每帧的重排就又回来了。
    let viewport: PDFViewportState
    let bridge: ReaderBridge

    @State private var cache = ThumbnailCache(capacity: ThumbnailCache.defaultCapacity)
    @State private var pending: Set<Int> = []
    @State private var generation = UUID()
    @State private var visible = VisibleTracker()
    @State private var scrollPosition = ScrollPosition(y: 0)
    @State private var viewportHeight: CGFloat = 0

    private static let renderQueue = DispatchQueue(label: "com.jn.lumen.thumbnail", qos: .utility)
    private static let pixelScale: CGFloat = 2

    private static let width: CGFloat = DS.Size.thumbnailWidth
    private static var rowPitch: CGFloat {
        DS.Size.thumbnailLabelGap + DS.Size.thumbnailLabelHeight + DS.Size.thumbnailGap
    }

    static func == (lhs: ThumbnailGrid, rhs: ThumbnailGrid) -> Bool {
        lhs.currentPage == rhs.currentPage
            && lhs.unitCount == rhs.unitCount
            && lhs.documentID == rhs.documentID
            && lhs.theme == rhs.theme
            && lhs.originalColors == rhs.originalColors
            && lhs.annotationRevision == rhs.annotationRevision
            && lhs.pageAspects == rhs.pageAspects
    }

    private func height(_ index: Int) -> CGFloat {
        Self.width * (pageAspects.indices.contains(index) ? pageAspects[index] : 1.4)
    }

    var body: some View {
        // 卡顿自检：这一 tick 的数字就是「列表被重排了多少次」。
        // 卡片列表挡住滚动期的无谓重排之后，滚动段这里应当接近 0。
        let _ = Jank.tick(.thumbnailPaneBody)
        ScrollView {
            LazyVStack(spacing: DS.Size.thumbnailGap) {
                ForEach(0..<unitCount, id: \.self) { index in
                    ThumbnailRow(
                        index: index,
                        image: cache[index],
                        isCurrent: index == currentPage,
                        height: height(index),
                        theme: theme,
                        originalColors: originalColors
                    ) {
                        bridge.goTo?(.pdf(page: index, charOffset: 0))
                    }
                    .id(index)
                    .onAppear { visible.insert(index); request(index) }
                    .onDisappear { visible.remove(index) }
                }
            }
            .padding(.vertical, DS.Space.m)
        }
        .scrollPosition($scrollPosition)
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { viewportHeight = $0 }
        // 只在**页号真的变了**时跟随。以前是按滚动进度每帧跟一次：
        // 那不光把每一帧都变成一次列表滚动，视觉上也是「缩略图一直在匀动」，
        // 反而不如「翻过一页，卡片跳一格」看得清。
        .onChange(of: currentPage) { _, page in follow(page) }
        .onChange(of: documentID) { _, _ in reset() }
        .onChange(of: annotationRevision) { _, _ in reset() }
        .onAppear { follow(currentPage) }
    }

    private func follow(_ page: Int) {
        guard unitCount > 0, viewportHeight > 0 else { return }
        let clamped = min(max(0, page), unitCount - 1)
        var offset: CGFloat = DS.Space.m
        for index in 0..<clamped { offset += height(index) + Self.rowPitch }
        let target = max(0, offset + height(clamped) / 2 - viewportHeight / 2)
        withAnimation(DS.Motion.quick) { scrollPosition.scrollTo(y: target) }
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
        let size = CGSize(width: Self.width * Self.pixelScale, height: height(index) * Self.pixelScale)
        Self.renderQueue.async {
            // 排队期间用户可能已经滚过去了：可见性在**渲染前**再问一次，
            // 转过头已经不在视口里的页就不必再画。
            guard tracker.contains(index) else {
                DispatchQueue.main.async {
                    if generation == requestGeneration { pending.remove(index) }
                }
                return
            }
            Jank.tick(.thumbnailRender)
            var image = provider(index, size)
            // 必须把图的 `size` 从「像素」改回「点」。
            //
            // `PDFPage.thumbnail(of:)` 返回的 NSImage，`size` 就是请求时给的那个值。
            // 我们为了清晰是按 2 倍像素去要的（216×302），于是这张图在 SwiftUI 里的
            // 固有尺寸就是 216×302 **点**——整整比卡片大一圈，撑破 frame 往邻居身上叠。
            // 这正是「缩略图尺寸过大 / 显示异常」的来路。
            //
            // 同一个 NSImage 里既有 2 倍像素、又把 size 说成 1 倍点数，正是 Retina
            // 图片的标准表达：绘制时按点数布局、按像素取清晰版本。
            if let rendered = image {
                rendered.size = NSSize(
                    width: size.width / Self.pixelScale,
                    height: size.height / Self.pixelScale
                )
                image = rendered
            }
            DispatchQueue.main.async {
                guard generation == requestGeneration else { return }
                pending.remove(index)
                if let image { cache.store(image, at: index, current: currentPage) }
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
    let height: CGFloat
    let theme: ReadingTheme
    let originalColors: Bool
    let onTap: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: onTap) {
            VStack(spacing: DS.Size.thumbnailLabelGap) {
                card.frame(width: DS.Size.thumbnailWidth, height: height)
                pageNumber.frame(height: DS.Size.thumbnailLabelHeight)
            }
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(DS.Motion.hover) { isHovering = hovering }
        }
        .help("跳到第 \(index + 1) 页")
        // 选中态（描边 + 徽章）走弹性过渡：翻页时环是「长」出来的，不是硬切。
        .animation(DS.Motion.quick, value: isCurrent)
        // 图片由 nil 变有值的那一刻淡入；和选中态分开两个 value，
        // 否则翻页时的选中反馈会被图片加载的节奏拖慢。
        .animation(DS.Motion.content, value: image == nil)
    }

    // MARK: 缩略图主体

    /// 当前页 = 卡片外一圈 2.5pt 强调色描边 + 同色柔光。
    ///
    /// 光是描边只有 2pt，在整栏缩略图里扫过去容易漏；一圈低透明度的柔光把
    /// 「选中」从一条线升格为一块面，视野边缘也能定位到。
    /// 卡片本体**不上色**：底色一变，页面内容的对比度就跟着变，
    /// 等于让读者在选中的那一张上看不清内容。
    private var card: some View {
        ZStack {
            RoundedRectangle(cornerRadius: DS.Radius.thumbnail, style: .continuous)
                .fill(DS.Palette.surfaceRaised)

            if let image {
                ThemedThumbnailImage(image: image, theme: theme, original: originalColors)
                    .clipShape(RoundedRectangle(cornerRadius: DS.Radius.thumbnail, style: .continuous))
                    .transition(.opacity)
            } else {
                skeleton
            }
        }
        .overlay(
            RoundedRectangle(cornerRadius: DS.Radius.thumbnail, style: .continuous)
                .strokeBorder(borderColor, lineWidth: isCurrent ? 2.5 : 0.5)
        )
        .shadow(color: isCurrent ? DS.Palette.accent.opacity(0.32) : Color.clear, radius: 7)
        .shadow(color: .black.opacity(0.06), radius: 2, y: 1)
        // 几何自检用：卡片的实际框（宽 108、高按页面比例），交给 layout_assert 断言。
        .layoutProbe("thumbnailCard")
    }

    // MARK: 页码

    /// 当前页的页码升级为实心徽章：数字落在胶囊里，是滚动联动时唯一需要
    /// 「看清」的信息；其余页保持裸数字，视觉重量全部让给当前页。
    @ViewBuilder
    private var pageNumber: some View {
        if isCurrent {
            Text("\(index + 1)")
                .font(DS.Typo.ui(size: 10, weight: .semibold))
                .foregroundStyle(theme.isDark ? theme.background : Color.white)
                .padding(.horizontal, 8)
                .padding(.vertical, 2.5)
                .background(Capsule().fill(DS.Palette.accent))
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
        RoundedRectangle(cornerRadius: DS.Radius.xs, style: .continuous)
            .fill(DS.Palette.surfaceSunken)
            .padding(2)
            .overlay(
                Image(systemName: "doc.text")
                    .font(DS.Typo.ui(size: 16))
                    .foregroundStyle(DS.Palette.textTertiary.opacity(0.3))
            )
    }
}
