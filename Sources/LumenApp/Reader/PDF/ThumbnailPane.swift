import SwiftUI
import AppKit
import LumenKit

/// 页面缩略图侧栏（PDF 专用）。
///
/// 缩略图按可视区域懒加载并缓存。`PDFPage.thumbnail(of:for:)` 会触发一次真实渲染，
/// 所以绝不能一次性为几百页全部生成，否则打开文档时就是几秒钟的白屏。
struct ThumbnailPane: View {

    @EnvironmentObject private var bridge: ReaderBridge
    @EnvironmentObject private var state: AppState

    @State private var cache: [Int: NSImage] = [:]
    @State private var pending: Set<Int> = []

    private let thumbnailWidth: CGFloat = 132

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
                                row(index: index)
                                    .id(index)
                                    .onAppear { request(index: index) }
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
    }

    private func row(index: Int) -> some View {
        let isCurrent = index == bridge.currentUnitIndex

        return Button {
            bridge.goTo?(.pdf(page: index, charOffset: 0))
        } label: {
            VStack(spacing: 5) {
                ZStack {
                    RoundedRectangle(cornerRadius: DS.Radius.s, style: .continuous)
                        .fill(DS.Palette.surfaceRaised)

                    if let image = cache[index] {
                        Image(nsImage: image)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .padding(2)
                    } else {
                        ProgressView()
                            .controlSize(.small)
                    }
                }
                .frame(width: thumbnailWidth, height: thumbnailWidth * 1.34)
                .overlay(
                    RoundedRectangle(cornerRadius: DS.Radius.s, style: .continuous)
                        .strokeBorder(
                            isCurrent ? DS.Palette.accent : DS.Palette.separator,
                            lineWidth: isCurrent ? 2 : 0.5
                        )
                )
                .shadow(color: .black.opacity(0.10), radius: 4, y: 1)

                Text("\(index + 1)")
                    .font(DS.Typo.ui(size: 10, weight: isCurrent ? .semibold : .regular))
                    .foregroundStyle(isCurrent ? DS.Palette.accent : DS.Palette.textTertiary)
                    .monospacedDigit()
            }
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("跳到第 \(index + 1) 页")
    }

    /// 只为请求过的页生成缩略图，并做并发去重。
    private func request(index: Int) {
        guard cache[index] == nil, !pending.contains(index) else { return }
        guard let provider = bridge.thumbnailProvider else { return }
        pending.insert(index)

        let size = CGSize(width: thumbnailWidth * 2, height: thumbnailWidth * 1.34 * 2)
        // 缩略图渲染放到后台，避免滚动时主线程被 PDF 渲染卡住
        DispatchQueue.global(qos: .utility).async {
            let image = provider(index, size)
            DispatchQueue.main.async {
                pending.remove(index)
                if let image {
                    cache[index] = image
                }
            }
        }
    }
}
