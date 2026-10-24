import SwiftUI
import LumenKit

struct MindMapView: View {
    let root: MindMapNode
    var expanded = false
    @State private var scale = 1.0
    @State private var pinchStart: Double?
    @State private var scrollPosition = ScrollPosition(point: .zero)

    var body: some View {
        let layout = MindMapLayout(root: root)
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Label("思维导图", systemImage: "point.3.connected.trianglepath.dotted")
                    .font(DS.Typo.ui(size: 11.5, weight: .medium))
                Spacer()
                Button { scale = max(0.15, scale / 1.2) } label: { Image(systemName: "minus.magnifyingglass") }
                    .help("缩小")
                Button { scale = 1 } label: { Text("\(Int(scale * 100))%") }
                    .monospacedDigit().frame(width: 42).help("原始大小")
                Button { scale = min(3, scale * 1.2) } label: { Image(systemName: "plus.magnifyingglass") }
                    .help("放大")
                if expanded {
                    Button { fit(layout, viewport: canvasSize) } label: { Image(systemName: "arrow.up.left.and.down.right.magnifyingglass") }
                        .help("适应窗口")
                }
                if !expanded {
                    Button { MindMapWindowPresenter.shared.show(root: root) } label: { Image(systemName: "arrow.up.left.and.arrow.down.right") }
                        .help("展开思维导图")
                }
            }
            .buttonStyle(.plain)
            .padding(10)
            Divider()
            GeometryReader { viewport in
            ScrollView([.horizontal, .vertical]) {
                ZStack(alignment: .topLeading) {
                    Canvas { context, _ in
                        for edge in layout.edges {
                            let from = CGPoint(x: edge.from.x + 84, y: edge.from.y)
                            let to = CGPoint(x: edge.to.x - 84, y: edge.to.y)
                            var path = Path()
                            path.move(to: from)
                            let mid = (from.x + to.x) / 2
                            path.addCurve(to: to, control1: CGPoint(x: mid, y: from.y), control2: CGPoint(x: mid, y: to.y))
                            context.stroke(path, with: .color(DS.Palette.textTertiary.opacity(0.65)), lineWidth: 1)
                        }
                    }
                    ForEach(layout.items) { item in
                        VStack(alignment: .leading, spacing: 3) {
                            Text(item.node.label)
                                .font(DS.Typo.ui(size: 12, weight: item.depth == 0 ? .semibold : .regular))
                                .lineLimit(3)
                            if let source = item.node.source, !source.isEmpty {
                                Text(source).font(DS.Typo.ui(size: 10)).foregroundStyle(DS.Palette.textSecondary).lineLimit(1)
                            }
                        }
                        .padding(9)
                        .frame(width: MindMapLayout.nodeSize.width, height: MindMapLayout.nodeSize.height, alignment: .leading)
                        .background(item.depth == 0 ? DS.Palette.accentSoft : DS.Palette.surfaceRaised,
                                    in: RoundedRectangle(cornerRadius: 6))
                        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(DS.Palette.separator, lineWidth: 1))
                        .help([item.node.label, item.node.source].compactMap { $0 }.joined(separator: "\n"))
                        .position(item.center)
                    }
                }
                .frame(width: layout.size.width, height: layout.size.height)
                .scaleEffect(scale, anchor: .topLeading)
                .frame(width: layout.size.width * scale, height: layout.size.height * scale, alignment: .topLeading)
            }
            .scrollPosition($scrollPosition)
            .simultaneousGesture(MagnifyGesture().onChanged { value in
                if pinchStart == nil { pinchStart = scale }
                scale = min(3, max(0.15, (pinchStart ?? scale) * value.magnification))
            }.onEnded { _ in pinchStart = nil })
            .onAppear {
                canvasSize = viewport.size
                let rootY = layout.items.first { $0.id == "root" }?.center.y ?? 0
                scrollPosition.scrollTo(point: CGPoint(x: 0, y: max(0, rootY * scale - viewport.size.height / 2)))
                if !expanded, LaunchOptions.flag("--mindmap-window") {
                    MindMapWindowPresenter.shared.showDiagnostic(root: root)
                }
            }
            .onChange(of: viewport.size) { _, size in canvasSize = size }
            }
        }
        .frame(height: expanded ? nil : 300)
        .background(DS.Palette.surfaceSunken)
    }

    @State private var canvasSize = CGSize.zero
    private func fit(_ layout: MindMapLayout, viewport: CGSize) {
        guard viewport.width > 0, viewport.height > 0 else { return }
        scale = max(0.15, min(1, (viewport.width - 20) / layout.size.width, (viewport.height - 20) / layout.size.height))
        scrollPosition.scrollTo(point: .zero)
    }
}
