import SwiftUI
import AppKit
import LumenKit

/// 页面缩略图侧栏（PDF 专用）。
///
/// 缩略图是**真渲染**——`PDFPage.thumbnail(of:for:)` 会完整走一遍 PDF 绘制管线，
/// 不是取一张现成的小图。所以这里必须同时成立两件事：
/// 只为真的要看的页渲染，以及**别让已经滚过去的页继续占着资源渲染**。
/// 后者是滚动卡顿的真正来源：快速拖过 300 页，等于排了 300 次真实绘制。
struct ThumbnailPane: View {

    @EnvironmentObject private var bridge: ReaderBridge
    @EnvironmentObject private var state: AppState

    @State private var cache: [Int: NSImage] = [:]
    @State private var pending: Set<Int> = []
    /// 当前真正落在可视区里的页。修掉卡顿靠的就是它。
    @State private var visible = VisibleTracker()

    private let thumbnailWidth: CGFloat = 132
    /// 缩略图比例。略高于 A4（1.414）留出边距，页与页之间的观感更齐。
    private let thumbnailAspect: CGFloat = 1.34

    /// 串行队列渲染。
    ///
    /// 刻意不用并发：缩略图渲染是 CPU/GPU 密集操作，几路并发只会互相抢资源，
    /// 还会和主线程的画面合成争带宽——表现就是滚动时掉帧。
    /// 「串行 + 不可见就跳过」的实际吞吐反而更高。
    private static let renderQueue = DispatchQueue(label: "com.jn.lumen.thumbnail", qos: .utility)

    var body: some View {
        Group {
            if bridge.unitCount == 0 {
                SidebarEmptyState(
                    icon: "square.grid.2x2",
                    title: "没有可显示的页面",
                    message: "文档尚未解析完成。"
                )
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: DS.Space.m) {
                            ForEach(0..<bridge.unitCount, id: \.self) { index in
                                ThumbnailRow(
                                    index: index,
                                    image: cache[index],
                                    isCurrent: index == bridge.currentUnitIndex,
                                    width: thumbnailWidth,
                                    aspect: thumbnailAspect
                                ) {
                                    bridge.goTo?(.pdf(page: index, charOffset: 0))
                                }
                                .id(index)
                                .onAppear {
                                    visible.insert(index)
                                    request(index: index)
                                }
                                // 滚出可视区就登记移除：这正是让「路过的页」能被跳过、
                                // 也让 cache 之外的内存不会被无限占住的依据。
                                .onDisappear { visible.remove(index) }
                            }
                        }
                        .padding(.vertical, DS.Space.m)
                    }
                    .onChange(of: bridge.currentUnitIndex) { _, newValue in
                        withAnimation(DS.Motion.quick) {
                            proxy.scrollTo(newValue, anchor: .center)
                        }
                    }
                }
            }
        }
        .onChange(of: state.document?.id) { _, _ in
            // 换文档必须清空。索引一样但内容完全不同，
            // 留着旧缓存会出现「第 3 页的缩略图是上一本书的内容」这种灵异现象。
            cache.removeAll()
            pending.removeAll()
        }
    }

    /// 为某一页排队渲染缩略图。
    private func request(index: Int) {
        guard cache[index] == nil, !pending.contains(index) else { return }
        guard let provider = bridge.thumbnailProvider else { return }
        pending.insert(index)

        // 2 倍尺寸喂进去，Retina 下才不会糊
        let size = CGSize(width: thumbnailWidth * 2, height: thumbnailWidth * thumbnailAspect * 2)

        Self.renderQueue.async {
            // 排到队时这一页很可能早就滚过去了。这里必须再确认一次可见性：
            // 少了这一步，用户快速滑过 300 页就会实打实地渲染 300 张缩略图，
            // 队列被一堆没人看的图占满，新进入视口的页反而要排很久——越滚越卡。
            guard visible.contains(index) else {
                if LaunchOptions.thumbnailReport {
                    NSLog("[Lumen][thumb] 跳过第 \(index + 1) 页（排队期间已滚出可视区）")
                }
                DispatchQueue.main.async { pending.remove(index) }
                return
            }

            if LaunchOptions.thumbnailReport {
                NSLog("[Lumen][thumb] 渲染第 \(index + 1) 页")
            }
            let image = provider(index, size)
            DispatchQueue.main.async {
                pending.remove(index)
                if let image { cache[index] = image }
            }
        }
    }
}

// MARK: - 可视区登记

/// 记录「此刻哪些页真的在可视区里」。
///
/// 用 class + `NSLock` 而不是 `@State var visible: Set<Int>`：读取它的是后台渲染队列，
/// 后台线程直接读 SwiftUI 的 `@State` 既拿不到最新快照，也是实打实的数据竞争。
private final class VisibleTracker: @unchecked Sendable {

    private let lock = NSLock()
    private var indices: Set<Int> = []

    func insert(_ index: Int) {
        lock.lock(); defer { lock.unlock() }
        indices.insert(index)
    }

    func remove(_ index: Int) {
        lock.lock(); defer { lock.unlock() }
        indices.remove(index)
    }

    func contains(_ index: Int) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return indices.contains(index)
    }
}

// MARK: - 单行

private struct ThumbnailRow: View {

    let index: Int
    let image: NSImage?
    let isCurrent: Bool
    let width: CGFloat
    let aspect: CGFloat
    let onTap: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: onTap) {
            VStack(spacing: 5) {
                ZStack {
                    RoundedRectangle(cornerRadius: DS.Radius.s, style: .continuous)
                        .fill(DS.Palette.surfaceRaised)

                    if let image {
                        Image(nsImage: image)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .padding(2)
                            // 淡入而不是硬闪：缩略图是逐个渲染出来的，
                            // 硬切会让侧栏看起来一直在"跳"。
                            .transition(.opacity)
                    } else {
                        skeleton
                    }
                }
                .frame(width: width, height: width * aspect)
                .overlay(
                    RoundedRectangle(cornerRadius: DS.Radius.s, style: .continuous)
                        .strokeBorder(borderColor, lineWidth: isCurrent ? 2 : 0.5)
                )
                .shadow(
                    color: .black.opacity(isCurrent ? 0.16 : 0.08),
                    radius: isCurrent ? 6 : 3,
                    y: 1
                )
                // 当前页微微放大：一像素级的差别，但扫视时能立刻定位到读到哪儿
                .scaleEffect(isCurrent ? 1.015 : 1)

                Text("\(index + 1)")
                    .font(DS.Typo.ui(size: 10, weight: isCurrent ? .semibold : .regular))
                    .foregroundStyle(isCurrent ? DS.Palette.accent : DS.Palette.textTertiary)
                    .monospacedDigit()
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
        .animation(DS.Motion.quick, value: isCurrent)
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
