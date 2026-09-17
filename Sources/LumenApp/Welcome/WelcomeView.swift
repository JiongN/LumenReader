import SwiftUI
import LumenKit

struct WelcomeView: View {

    @EnvironmentObject private var state: AppState

    @State private var isTargeted = false
    /// 内容入场：首帧在下方 12pt 处，随后浮到位。
    @State private var hasEntered = false

    private let columns = [GridItem(.adaptive(minimum: 250, maximum: 380), spacing: DS.Space.m)]

    var body: some View {
        ScrollView {
            VStack(spacing: DS.Space.xxl) {
                hero
                actionRow
                if !state.recent.entries.isEmpty {
                    recentSection
                }
            }
            .frame(maxWidth: 860)
            .padding(.horizontal, DS.Space.xxl)
            .padding(.top, DS.Space.xxxl + DS.Space.l)
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
                colors: [DS.Palette.accent.opacity(0.10), .clear],
                center: .init(x: 0.5, y: 0.12),
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

    // MARK: - 主视觉

    private var hero: some View {
        VStack(spacing: DS.Space.l) {
            appGlyph

            VStack(spacing: DS.Space.xs) {
                Text("流明")
                    .font(DS.Typo.display)
                    .foregroundStyle(DS.Palette.textPrimary)
                Text("PDF · EPUB 阅读器，内置 AI 阅读模式")
                    .font(DS.Typo.ui(size: 14))
                    .foregroundStyle(DS.Palette.textSecondary)
            }
        }
    }

    private var appGlyph: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [Color(hex: 0x4F7BFF), Color(hex: 0x2F5BEA)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .shadow(color: Color(hex: 0x2F5BEA).opacity(0.32), radius: 18, y: 8)

            Image(systemName: "book.closed.fill")
                .font(DS.Typo.ui(size: 38, weight: .medium))
                .foregroundStyle(.white)
        }
        .frame(width: 84, height: 84)
    }

    // MARK: - 操作区

    private var actionRow: some View {
        VStack(spacing: DS.Space.m) {
            HStack(spacing: DS.Space.m) {
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

                if let latest = state.recent.entries.first(where: { $0.fileExists }) {
                    Button {
                        state.reopen(latest)
                    } label: {
                        Label("继续阅读「\(latest.displayName)」", systemImage: "clock.arrow.circlepath")
                            .font(DS.Typo.ui(size: 14, weight: .medium))
                            .lineLimit(1)
                            .frame(maxWidth: 320)
                            .frame(height: 34)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                }
            }

            Text("或将 PDF / EPUB 文件拖入此窗口")
                .font(DS.Typo.callout)
                .foregroundStyle(DS.Palette.textTertiary)
        }
    }

    // MARK: - 最近打开

    private var recentSection: some View {
        VStack(alignment: .leading, spacing: DS.Space.m) {
            HStack {
                Text("最近打开")
                    .font(DS.Typo.headline)
                    .foregroundStyle(DS.Palette.textPrimary)
                Spacer()
                Button("清除记录") { state.recent.clear() }
                    .buttonStyle(.plain)
                    .font(DS.Typo.callout)
                    .foregroundStyle(DS.Palette.textTertiary)
            }

            LazyVGrid(columns: columns, spacing: DS.Space.m) {
                ForEach(state.recent.entries.prefix(9)) { entry in
                    RecentCard(entry: entry) { state.reopen(entry) }
                }
            }
        }
        .padding(DS.Space.l)
        .background(
            RoundedRectangle(cornerRadius: DS.Radius.l, style: .continuous)
                .fill(DS.Palette.surfaceRaised.opacity(0.7))
        )
        .overlay(
            RoundedRectangle(cornerRadius: DS.Radius.l, style: .continuous)
                .strokeBorder(DS.Palette.separator, lineWidth: 0.5)
        )
    }
}

// MARK: - 最近项卡片

struct RecentCard: View {

    let entry: RecentEntry
    let action: () -> Void

    @State private var isHovering = false

    private var exists: Bool { entry.fileExists }

    private var kindTint: Color {
        switch entry.kind {
        case .pdf:  return Color(hex: 0xE0533D)
        case .epub: return Color(hex: 0x2FA37A)
        }
    }

    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: DS.Space.m) {
                ZStack {
                    RoundedRectangle(cornerRadius: DS.Radius.s, style: .continuous)
                        .fill(kindTint.opacity(exists ? 0.14 : 0.07))
                    Image(systemName: entry.kind == .pdf ? "doc.richtext" : "book")
                        .font(DS.Typo.ui(size: 15, weight: .medium))
                        .foregroundStyle(exists ? kindTint : DS.Palette.textTertiary)
                }
                .frame(width: 34, height: 34)

                VStack(alignment: .leading, spacing: 4) {
                    Text(entry.displayName)
                        .font(DS.Typo.ui(size: 13, weight: .medium))
                        .foregroundStyle(exists ? DS.Palette.textPrimary : DS.Palette.textTertiary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)

                    HStack(spacing: DS.Space.xs) {
                        Text(entry.kind.displayName)
                            .font(DS.Typo.ui(size: 10, weight: .semibold))
                            .foregroundStyle(kindTint)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1.5)
                            .background(
                                RoundedRectangle(cornerRadius: 4, style: .continuous)
                                    .fill(kindTint.opacity(0.12))
                            )

                        if !exists {
                            Text("文件已移动")
                                .font(DS.Typo.ui(size: 10))
                                .foregroundStyle(DS.Palette.warning)
                        } else if entry.progress > 0.005 {
                            Text("已读 \(Int(entry.progress * 100))%")
                                .font(DS.Typo.ui(size: 10))
                                .foregroundStyle(DS.Palette.textTertiary)
                        }
                    }
                }

                Spacer(minLength: 0)
            }
            .padding(DS.Space.m)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: DS.Radius.m, style: .continuous)
                    .fill(isHovering ? DS.Palette.accentSoft : DS.Palette.surfaceRaised)
            )
            .overlay(
                RoundedRectangle(cornerRadius: DS.Radius.m, style: .continuous)
                    .strokeBorder(isHovering ? DS.Palette.accent.opacity(0.35) : DS.Palette.separator, lineWidth: 0.5)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(DS.Motion.hover) { isHovering = hovering }
        }
        .help(entry.path)
    }
}
