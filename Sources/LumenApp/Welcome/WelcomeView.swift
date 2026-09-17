import SwiftUI
import PDFKit
import LumenKit

/// 首页 = 画廊。
///
/// 旧版是「居中 hero + 列表卡片」的工具型落地页，首页的重心是软件自己；
/// 新版把重心移交给**内容**：最近打开的文档以真实封面呈现（PDF 渲染第 1 页），
/// 点一下即回到上次读到的位置——打开软件到继续阅读只隔一次点击。
/// 这与 Apple Books / 播客的首页是同一套逻辑：库即首页，内容即入口。
struct WelcomeView: View {

    @EnvironmentObject private var state: AppState

    @State private var isTargeted = false
    /// 内容入场：首帧在下方 12pt 处，随后浮到位。
    @State private var hasEntered = false

    /// 封面渲染缓存（path → 第 1 页位图）。
    @StateObject private var coverStore = CoverStore()

    /// 画廊列宽。172pt 下封面高约 232pt（≈书页比例），
    /// 再小封面上的正文缩略就糊了；再大则一屏放不下 4 列，扫视效率下降。
    private let columns = [GridItem(.adaptive(minimum: 172, maximum: 232), spacing: DS.Space.l)]

    var body: some View {
        ScrollView {
            VStack(spacing: DS.Space.xxl) {
                hero
                actionRow
                if !state.recent.entries.isEmpty {
                    recentSection
                }
            }
            .frame(maxWidth: 1020)
            .padding(.horizontal, DS.Space.xxl)
            .padding(.top, DS.Space.xxl)
            .padding(.bottom, DS.Space.xxxl)
            .frame(maxWidth: .infinity)
        }
        .background(background)
        // 入场：整块内容从下方 12pt 浮到位，而不是直接怼在屏幕上。
        //
        // 只用 offset、不碰 opacity。淡入看着更好，但一旦动画没能触发，透明就等于
        // 把欢迎页整个藏起来——而这个页面是「没打开文档时唯一能看到的东西」。
        // offset 的最坏情况只是位置差 12pt，用户照常能用。
        .offset(y: hasEntered ? 0 : 12)
        .animation(DS.Motion.reveal, value: hasEntered)
        .task {
            // 等一帧再翻状态：和布局同一轮里赋值的话，起始值会被合并掉，
            // SwiftUI 认为没有发生过变化，直接跳到终点——上浮就看不到了。
            try? await Task.sleep(nanoseconds: 30_000_000)
            hasEntered = true
        }
        .overlay(alignment: .top) { if isTargeted { dropIndicator } }
        .dropDestination(for: URL.self) { urls, _ in
            guard let url = urls.first(where: { DocumentKind.from(url: $0) != nil }) ?? urls.first else {
                return false
            }
            state.open(url: url)
            return true
        } isTargeted: { targeted in
            withAnimation(DS.Motion.quick) { isTargeted = targeted }
        }
    }

    // MARK: - 背景

    private var background: some View {
        ZStack {
            DS.Palette.surfaceSunken
            // 一层极淡的强调色辉光，避免纯灰的呆板
            RadialGradient(
                colors: [DS.Palette.accent.opacity(0.08), .clear],
                center: .init(x: 0.5, y: 0.10),
                startRadius: 0,
                endRadius: 620
            )
        }
        .ignoresSafeArea()
    }

    private var dropIndicator: some View {
        RoundedRectangle(cornerRadius: DS.Radius.l, style: .continuous)
            .strokeBorder(DS.Palette.accent, style: StrokeStyle(lineWidth: 2, dash: [7, 5]))
            .background(
                RoundedRectangle(cornerRadius: DS.Radius.l, style: .continuous)
                    .fill(DS.Palette.accentSoft)
            )
            .overlay {
                VStack(spacing: DS.Space.s) {
                    Image(systemName: "arrow.down.doc.fill")
                        .font(DS.Typo.ui(size: 26, weight: .medium))
                    Text("松手即可打开")
                        .font(DS.Typo.headline)
                }
                .foregroundStyle(DS.Palette.accent)
            }
            .padding(DS.Space.l)
            .transition(.opacity.combined(with: .scale(scale: 0.98)))
    }

    // MARK: - 主视觉（克制版）

    /// hero 收缩为 64pt 图标 + 一行标题：画廊首页的主角是封面墙，
    /// 品牌区只要「知道这是谁」就够，不再占半屏。
    private var hero: some View {
        VStack(spacing: DS.Space.m) {
            BrandGlyph(size: 64)

            Text("流明")
                .font(DS.Typo.title)
                .foregroundStyle(DS.Palette.textPrimary)
        }
        .padding(.top, DS.Space.l)
    }

    // MARK: - 操作区

    private var actionRow: some View {
        VStack(spacing: DS.Space.m) {
            Button {
                state.showOpenPanel()
            } label: {
                Label("打开文档", systemImage: "folder.badge.plus")
                    .font(DS.Typo.ui(size: 14, weight: .medium))
                    .padding(.horizontal, DS.Space.s)
                    .frame(height: 34)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .tint(DS.Palette.accent)
            .keyboardShortcut("o", modifiers: .command)

            Text("或将 PDF / EPUB 文件拖入此窗口")
                .font(DS.Typo.callout)
                .foregroundStyle(DS.Palette.textTertiary)
        }
    }

    // MARK: - 最近打开（画廊）

    private var recentSection: some View {
        VStack(alignment: .leading, spacing: DS.Space.l) {
            HStack(alignment: .firstTextBaseline) {
                Text("最近打开")
                    .font(DS.Typo.ui(size: 17, weight: .semibold))
                    .foregroundStyle(DS.Palette.textPrimary)
                Text("\(existingCount) 本")
                    .font(DS.Typo.callout)
                    .foregroundStyle(DS.Palette.textTertiary)
                Spacer()
                Button("清除记录") { state.recent.clear() }
                    .buttonStyle(.plain)
                    .font(DS.Typo.callout)
                    .foregroundStyle(DS.Palette.textTertiary)
            }
            .padding(.horizontal, 2)

            LazyVGrid(columns: columns, spacing: DS.Space.xl) {
                ForEach(state.recent.entries.prefix(12)) { entry in
                    GalleryCard(
                        entry: entry,
                        cover: coverStore.covers[entry.path]
                    ) {
                        state.reopen(entry)
                    }
                    .task { coverStore.request(entry: entry) }
                }
            }
        }
    }

    private var existingCount: Int {
        state.recent.entries.prefix(12).filter(\.fileExists).count
    }
}

// MARK: - 封面渲染

/// 首页封面的异步渲染与缓存。
///
/// 与阅读侧的 `ThumbnailPane` 同一套纪律：串行队列、只为存在的文件渲染、
/// 一次请求只排一次队。封面只用第 1 页，读一本渲染一张，开销可忽略。
@MainActor
final class CoverStore: ObservableObject {

    @Published private(set) var covers: [String: NSImage] = [:]
    private var pending: Set<String> = []

    private static let queue = DispatchQueue(label: "com.jn.lumen.cover", qos: .utility)

    func request(entry: RecentEntry) {
        let key = entry.path
        guard entry.kind == .pdf,
              entry.fileExists,
              covers[key] == nil,
              !pending.contains(key)
        else { return }
        pending.insert(key)

        let url = entry.url
        // 2 倍尺寸渲染，Retina 下不糊
        let size = CGSize(width: 344, height: 464)

        Self.queue.async {
            let document = PDFDocument(url: url)
            let image = document?.page(at: 0)?.thumbnail(of: size, for: .mediaBox)
            DispatchQueue.main.async {
                self.pending.remove(key)
                if let image { self.covers[key] = image }
            }
        }
    }
}

// MARK: - 画廊卡片

/// 单张封面卡。视觉上就是「一本书立在那里」：
/// 封面占绝对主体、带书页投影，文字信息压到一行标题 + 一根进度细线。
struct GalleryCard: View {

    let entry: RecentEntry
    let cover: NSImage?
    let action: () -> Void

    @State private var isHovering = false

    private var exists: Bool { entry.fileExists }

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: DS.Space.s) {
                coverArt

                Text(entry.displayName)
                    .font(DS.Typo.ui(size: 12, weight: .medium))
                    .foregroundStyle(exists ? DS.Palette.textPrimary : DS.Palette.textTertiary)
                    .lineLimit(1)

                bottomMeta
            }
            .padding(DS.Space.s)
            .background(
                RoundedRectangle(cornerRadius: DS.Radius.l, style: .continuous)
                    .fill(DS.Palette.surfaceRaised.opacity(isHovering ? 1 : 0.6))
            )
            .overlay(
                RoundedRectangle(cornerRadius: DS.Radius.l, style: .continuous)
                    .strokeBorder(
                        isHovering ? DS.Palette.accent.opacity(0.30) : DS.Palette.separator,
                        lineWidth: 0.5
                    )
            )
            // 悬停浮起：卡片级交互是低频动作，值得一个可感知的「拿起来」反馈
            .scaleEffect(isHovering ? 1.02 : 1)
            .shadow(
                color: .black.opacity(isHovering ? 0.14 : 0.05),
                radius: isHovering ? 12 : 5,
                y: isHovering ? 6 : 2
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(DS.Motion.hover) { isHovering = hovering }
        }
        .help(exists ? entry.path : "文件已移动：\(entry.path)")
        .animation(DS.Motion.content, value: cover == nil)
        .animation(DS.Motion.hover, value: isHovering)
        .disabled(!exists)
        .opacity(exists ? 1 : 0.55)
    }

    // MARK: 封面

    private var coverArt: some View {
        ZStack {
            RoundedRectangle(cornerRadius: DS.Radius.m, style: .continuous)
                .fill(DS.Palette.surfaceSunken)

            if let cover {
                Image(nsImage: cover)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .transition(.opacity)
            } else {
                placeholder
            }
        }
        .frame(height: 214)
        .clipShape(RoundedRectangle(cornerRadius: DS.Radius.m, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: DS.Radius.m, style: .continuous)
                .strokeBorder(DS.Palette.separator, lineWidth: 0.5)
        )
    }

    /// PDF 封面尚未渲染好 / EPUB 的占位：类型底色 + 首字，
    /// 不用 spinner——等待是常态（串行渲染），转圈只会显得卡。
    private var placeholder: some View {
        ZStack {
            kindTint.opacity(0.10)
            Text(String(entry.displayName.prefix(1)))
                .font(DS.Typo.ui(size: 40, weight: .light, design: .rounded))
                .foregroundStyle(kindTint.opacity(0.55))
        }
    }

    private var kindTint: Color {
        switch entry.kind {
        case .pdf:  return Color(hex: 0x8A6E5C)
        case .epub: return Color(hex: 0x5C7A6E)
        }
    }

    // MARK: 底部信息

    @ViewBuilder
    private var bottomMeta: some View {
        if !exists {
            Text("文件已移动")
                .font(DS.Typo.caption)
                .foregroundStyle(DS.Palette.warning)
        } else if entry.progress > 0.005 {
            // 进度细线 + 百分比：一根 3pt 的线比一段文字更快被扫到
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(DS.Palette.separator)
                    Capsule()
                        .fill(DS.Palette.accent.opacity(0.75))
                        .frame(width: max(3, proxy.size.width * entry.progress))
                }
            }
            .frame(height: 3)
            .padding(.top, 2)
        } else {
            Text(entry.kind.displayName)
                .font(DS.Typo.caption)
                .foregroundStyle(DS.Palette.textTertiary)
        }
    }
}

// MARK: - 品牌字形

/// 首页 hero 用的小号品牌图标。与应用图标（branding/lumen-icon-*.svg）
/// 同一套 v3 线稿：纸底 + 墨线摊开的书 + 一点实心的光。
/// 代码绘制以保证任意尺寸锐利——不直接读 AppIcon.icns：
/// icns 在小尺寸下会走系统缩放，反而发糊。
///
/// v1（填充渐变书页 + 光晕）已废弃：渐变与实心块和全局「细线、单色、留白」
/// 的视觉语言相抵触，且 64pt 下细节拥挤。v3 全部用描边线稿，无渐变无投影。
struct BrandGlyph: View {

    let size: CGFloat

    @Environment(\.colorScheme) private var scheme

    private var plateColor: Color {
        scheme == .dark ? Color(hex: 0x262B33) : Color(hex: 0xF5F2EB)
    }

    private var inkColor: Color {
        scheme == .dark ? Color(hex: 0xEAE4D6) : Color(hex: 0x2F3540)
    }

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.225, style: .continuous)
                .fill(plateColor)

            // 内缘一圈发丝线，给纸面一点「纸的厚度」
            RoundedRectangle(cornerRadius: size * 0.222, style: .continuous)
                .strokeBorder(inkColor.opacity(0.06), lineWidth: max(0.5, size * 0.003))

            bookOutline
                .frame(width: size * 0.39, height: size * 0.16)
                .offset(y: size * 0.14)

            bookOutline
                .frame(width: size * 0.39, height: size * 0.16)
                .scaleEffect(x: -1)
                .offset(y: size * 0.14)

            // 光点
            Circle()
                .fill(inkColor)
                .frame(width: size * 0.053, height: size * 0.053)
                .offset(y: -size * 0.049)
        }
        .frame(width: size, height: size)
    }

    /// 单侧书页线稿（右页；左页由镜像得到）。
    /// 坐标按书页包围盒归一化，与 SVG 母版逐点对应。
    private var bookOutline: some View {
        BookPageOutline()
            .stroke(
                inkColor,
                style: StrokeStyle(
                    lineWidth: size * 0.0156,
                    lineCap: .round,
                    lineJoin: .round
                )
            )
    }
}

/// 右侧书页的描边路径：书缝 → 外角上缘 → 外缘直落 → 下缘收回书缝 → 沿书缝闭合。
private struct BookPageOutline: Shape {

    func path(in rect: CGRect) -> Path {
        var p = Path()
        let w = rect.width
        let h = rect.height

        p.move(to: CGPoint(x: w * 0.5, y: h * 0.329))
        p.addCurve(
            to: CGPoint(x: 0, y: h * 0.085),
            control1: CGPoint(x: w * 0.365, y: h * 0.073),
            control2: CGPoint(x: w * 0.15, y: 0)
        )
        p.addLine(to: CGPoint(x: 0, y: h * 0.756))
        p.addCurve(
            to: CGPoint(x: w * 0.5, y: h),
            control1: CGPoint(x: w * 0.15, y: h * 0.671),
            control2: CGPoint(x: w * 0.365, y: h * 0.744)
        )
        p.closeSubpath()
        return p
    }
}
