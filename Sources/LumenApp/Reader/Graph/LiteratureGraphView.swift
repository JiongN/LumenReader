import SwiftUI
import AppKit
import LumenKit

struct LiteratureGraphView: View {
    private enum DragTarget {
        case undecided, canvas, node(String)
    }

    @ObservedObject var model: LiteratureGraphModel
    @EnvironmentObject private var state: AppState
    let onReturn: () -> Void
    @AppStorage("literatureGraph.sizeEncoding") private var sizeEncoding = "citations"
    @AppStorage("literatureGraph.colorEncoding") private var colorEncoding = "year"
    @State private var scale = 1.0
    @State private var pinchStartScale: Double?
    @State private var pinchStartPan = CGSize.zero
    @State private var pan = CGSize.zero
    @State private var dragStart = CGSize.zero
    @State private var dragTarget: DragTarget = .undecided
    @State private var draggedNodeOrigin = CGPoint.zero
    @State private var draggedPositions: [String: CGPoint] = [:]
    @State private var skipNextPositionFit = false
    @State private var canvasSize = CGSize.zero
    @State private var localSearch = ""
    private var visible: [GraphPaper] { model.visiblePapers }
    private var focusedPaper: GraphPaper? { model.selectedPaper ?? model.rootPaper }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            GeometryReader { container in
                if container.size.width >= 700 {
                    HStack(spacing: 0) {
                        canvasArea
                        if let paper = focusedPaper {
                            Divider()
                            detail(paper)
                                .frame(width: min(330, max(275, container.size.width * 0.31)))
                        }
                    }
                } else {
                    VStack(spacing: 0) {
                        canvasArea
                        if let paper = focusedPaper {
                            Divider()
                            detail(paper).frame(height: min(230, container.size.height * 0.38))
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(DS.Palette.surfaceSunken)
        .foregroundStyle(DS.Palette.textPrimary)
        .transaction { transaction in
            transaction.animation = nil
            transaction.disablesAnimations = true
        }
        .onChange(of: model.snapshot.positions) { _, _ in
            if skipNextPositionFit { skipNextPositionFit = false }
            else { fitCanvas() }
        }
        .onChange(of: visible.map(\.id)) { _, _ in fitCanvas() }
        .onAppear { updateLocalSearch() }
        .onChange(of: model.selectedID) { _, _ in updateLocalSearch() }
        .onDisappear {
            draggedPositions = [:]
            dragTarget = .undecided
            pinchStartScale = nil
        }
    }

    private var toolbar: some View {
        HStack(spacing: DS.Space.m) {
            Button("返回原文", systemImage: "arrow.left") { onReturn() }
                .buttonStyle(.bordered)
            VStack(alignment: .leading, spacing: 2) {
                Text("文献图谱").font(DS.Typo.headline)
                if let title = model.rootPaper?.title {
                    Text(title).font(DS.Typo.callout)
                        .foregroundStyle(DS.Palette.textSecondary).lineLimit(1)
                }
            }
            Spacer(minLength: DS.Space.s)
            Button("文献列表", systemImage: "sidebar.left") {
                state.setSidebarVisible(!state.isSidebarVisible)
            }
            .help(state.isSidebarVisible ? "隐藏文献列表" : "显示文献列表")
            Menu {
                Picker("关系", selection: Binding(
                    get: { model.selectedRelation },
                    set: { model.selectRelation($0) })) {
                    Text("参考文献").tag(GraphRelation.reference)
                    Text("被引文献").tag(GraphRelation.citation)
                    Text("主题相关").tag(GraphRelation.related)
                }
            } label: {
                Label("筛选", systemImage: "line.3.horizontal.decrease")
            }
            .fixedSize()
            Menu {
                Picker("节点大小", selection: $sizeEncoding) {
                    Text("按被引量").tag("citations")
                    Text("统一大小").tag("uniform")
                }
                Picker("节点颜色", selection: $colorEncoding) {
                    Text("按发表年份").tag("year")
                    Text("按关系类型").tag("relation")
                }
            } label: {
                Label("显示", systemImage: "paintpalette")
            }
            .fixedSize()
        }
        .font(DS.Typo.body)
        .padding(.horizontal, DS.Space.l)
        .padding(.vertical, DS.Space.m)
    }

    private var canvasArea: some View {
        GeometryReader { geo in
            ZStack {
                DS.Palette.surfaceRaised
                graphCanvas(size: geo.size)
                    .contentShape(Rectangle())
                    .gesture(DragGesture().onChanged { value in
                        updateDrag(value, size: geo.size)
                    }.onEnded { _ in endDrag() })
                    .simultaneousGesture(MagnifyGesture().onChanged { value in
                        if pinchStartScale == nil {
                            endDrag()
                            pinchStartScale = scale
                            pinchStartPan = pan
                        }
                        let anchor = CGPoint(x: value.startAnchor.x * geo.size.width,
                                             y: value.startAnchor.y * geo.size.height)
                        let zoomed = GraphViewport.zoom(scale: pinchStartScale ?? scale,
                            pan: pinchStartPan, factor: value.magnification, anchor: anchor, size: geo.size)
                        scale = zoomed.scale
                        pan = zoomed.pan
                    }.onEnded { _ in
                        dragStart = pan
                        pinchStartScale = nil
                    })
                    .onTapGesture { location in select(at: location, size: geo.size) }
                if model.snapshot.papers.isEmpty {
                    ContentUnavailableView("尚无图谱", systemImage: "point.3.connected.trianglepath.dotted")
                }
            }
            .overlay(alignment: .bottomLeading) { canvasControls.padding(DS.Space.l) }
            .overlay(alignment: .bottomTrailing) { yearLegend.padding(DS.Space.l) }
            .onAppear {
                canvasSize = geo.size
                fitCanvas()
            }
            .onChange(of: geo.size) { _, size in canvasSize = size; fitCanvas() }
        }
        .accessibilityLabel("文献关系图")
    }

    private var canvasControls: some View {
        HStack(spacing: DS.Space.s) {
            Button("缩小", systemImage: "minus") { scale = max(0.005, scale * 0.8) }
                .labelStyle(.iconOnly)
            Text("\(Int(scale * 100))%")
                .font(DS.Typo.callout).monospacedDigit().frame(minWidth: 44)
            Button("放大", systemImage: "plus") { scale = min(3, scale * 1.25) }
                .labelStyle(.iconOnly)
            Divider().frame(height: 16)
            Button("适应画布", systemImage: "arrow.up.left.and.arrow.down.right") { fitCanvas() }
                .labelStyle(.iconOnly).help("适应画布")
        }
        .font(DS.Typo.body)
        .padding(.horizontal, DS.Space.m).padding(.vertical, DS.Space.s)
        .background(DS.Palette.surfaceSunken, in: Capsule())
    }

    @ViewBuilder
    private var yearLegend: some View {
        if colorEncoding == "year" {
            let years = visible.compactMap(\.year)
            if let oldest = years.min(), let newest = years.max(), oldest != newest {
                HStack(spacing: DS.Space.s) {
                    Text(String(oldest))
                    LinearGradient(colors: [Color(hex: 0xA67A59), Color(hex: 0x4B8C85)],
                                   startPoint: .leading, endPoint: .trailing)
                        .frame(width: 86, height: 7).clipShape(Capsule())
                    Text(String(newest))
                }
                .font(DS.Typo.callout).foregroundStyle(DS.Palette.textSecondary)
                .padding(.horizontal, DS.Space.m).padding(.vertical, DS.Space.s)
                .background(DS.Palette.surfaceSunken, in: Capsule())
            }
        }
    }

    private func graphCanvas(size: CGSize) -> some View {
        Canvas { context, _ in
            let points = positions(size: size)
            let visibleIDs = Set(visible.map(\.id))
            let paperByID = Dictionary(model.snapshot.papers.map { ($0.id, $0) },
                                       uniquingKeysWith: { first, _ in first })
            for edge in model.snapshot.edges where visibleIDs.contains(edge.source) && visibleIDs.contains(edge.target) {
                guard enabled(edge.relation), let a = points[edge.source], let b = points[edge.target] else { continue }
                var path = Path()
                path.move(to: a); path.addLine(to: b)
                let emphasized = model.selectedID == edge.source || model.selectedID == edge.target
                let color = emphasized ? DS.Palette.accent.opacity(0.65) : edge.relation == .related
                    ? DS.Palette.textSecondary.opacity(0.27)
                    : DS.Palette.textSecondary.opacity(0.36)
                context.stroke(path, with: .color(color), style: StrokeStyle(
                    lineWidth: emphasized ? 1.9 : (edge.relation == .related ? 0.9 : 1.15),
                    dash: edge.relation == .related ? [3, 5] : []))
                if edge.relation != .related {
                    let angle = atan2(b.y - a.y, b.x - a.x)
                    let targetRadius = paperByID[edge.target].map(nodeRadius) ?? 7
                    let tip = CGPoint(x: b.x - (targetRadius + 3) * cos(angle),
                                      y: b.y - (targetRadius + 3) * sin(angle))
                    var arrow = Path(); arrow.move(to: tip)
                    arrow.addLine(to: CGPoint(x: tip.x - 5 * cos(angle - 0.5), y: tip.y - 5 * sin(angle - 0.5)))
                    arrow.move(to: tip)
                    arrow.addLine(to: CGPoint(x: tip.x - 5 * cos(angle + 0.5), y: tip.y - 5 * sin(angle + 0.5)))
                    context.stroke(arrow, with: .color(DS.Palette.textSecondary.opacity(0.56)), lineWidth: 1)
                }
            }
            for paper in visible {
                guard let point = points[paper.id] else { continue }
                let isRoot = paper.id == model.snapshot.paperID
                let selected = paper.id == model.selectedID
                let radius = nodeRadius(paper)
                if isRoot || selected {
                    let inset: CGFloat = selected ? 7 : 5
                    context.fill(Path(ellipseIn: CGRect(x: point.x - radius - inset, y: point.y - radius - inset,
                                                        width: (radius + inset) * 2, height: (radius + inset) * 2)),
                                 with: .color(DS.Palette.accentSoft))
                }
                context.fill(Path(ellipseIn: CGRect(x: point.x - radius, y: point.y - radius,
                                                    width: radius * 2, height: radius * 2)),
                             with: .color(nodeColor(paper)))
            }
        }
    }

    private func positions(size: CGSize) -> [String: CGPoint] {
        let center = CGPoint(x: size.width / 2 + pan.width, y: size.height / 2 + pan.height)
        var result: [String: CGPoint] = [:]
        for (id, raw) in rawPositions() {
            result[id] = CGPoint(x: center.x + raw.x * scale, y: center.y + raw.y * scale)
        }
        return result
    }

    private func rawPositions() -> [String: CGPoint] {
        var result: [String: CGPoint] = [:]
        for (index, paper) in model.snapshot.papers.enumerated() {
            if let saved = model.snapshot.positions[paper.id] {
                result[paper.id] = CGPoint(x: saved.x, y: saved.y)
            } else {
                let angle = Double(index) * 2.399963229728653
                let radius = sqrt(Double(index)) * 80
                result[paper.id] = CGPoint(x: radius * cos(angle), y: radius * sin(angle))
            }
        }
        result.merge(draggedPositions) { _, dragged in dragged }
        return result
    }

    private func updateDrag(_ value: DragGesture.Value, size: CGSize) {
        guard pinchStartScale == nil else { return }
        if case .undecided = dragTarget {
            if let paper = hitPaper(at: value.startLocation, size: size),
               let origin = rawPositions()[paper.id] {
                dragTarget = .node(paper.id)
                draggedNodeOrigin = origin
                model.selectedID = paper.id
            } else {
                dragTarget = .canvas
            }
        }
        switch dragTarget {
        case .undecided: break
        case .canvas:
            pan = CGSize(width: dragStart.width + value.translation.width,
                         height: dragStart.height + value.translation.height)
        case .node(let id):
            draggedPositions[id] = CGPoint(
                x: draggedNodeOrigin.x + value.translation.width / scale,
                y: draggedNodeOrigin.y + value.translation.height / scale)
        }
    }

    private func endDrag() {
        switch dragTarget {
        case .undecided: break
        case .canvas: dragStart = pan
        case .node(let id):
            if let point = draggedPositions[id] {
                skipNextPositionFit = true
                model.moveNode(id, to: GraphPosition(x: point.x, y: point.y))
            }
            draggedPositions.removeValue(forKey: id)
        }
        dragTarget = .undecided
    }

    private func nodeRadius(_ paper: GraphPaper) -> CGFloat {
        let visualScale = CGFloat(min(1, max(0.45, sqrt(max(0.01, scale)))))
        if sizeEncoding == "uniform" {
            return paper.id == model.snapshot.paperID ? max(9, 12 * visualScale) : max(3.5, 8 * visualScale)
        }
        let maximum = max(1, visible.map(\.citedByCount).max() ?? 1)
        let normalized = log1p(Double(max(0, paper.citedByCount))) / log1p(Double(maximum))
        let radius = 5 + CGFloat(pow(normalized, 0.7)) * 19
        return paper.id == model.snapshot.paperID ? max(9, max(12, radius) * visualScale)
            : max(3.5, radius * visualScale)
    }

    private func nodeColor(_ paper: GraphPaper) -> Color {
        if paper.id == model.snapshot.paperID { return DS.Palette.accent }
        if colorEncoding == "relation" {
            switch model.selectedRelation {
            case .reference: return Color(hex: 0x7B9A83)
            case .citation: return Color(hex: 0xB79778)
            case .related: return Color(hex: 0x789E9A)
            }
        }
        guard let year = paper.year else { return DS.Palette.textSecondary }
        let years = visible.compactMap(\.year)
        let oldest = years.min() ?? year
        let newest = years.max() ?? year
        let fraction = oldest == newest ? 0.5
            : Double(year - oldest) / Double(newest - oldest)
        let dark = ThemePalette.shared.theme.isDark
        let old = dark ? (0.77, 0.62, 0.49) : (0.65, 0.48, 0.35)
        let new = dark ? (0.49, 0.74, 0.70) : (0.30, 0.55, 0.52)
        return Color(.sRGB, red: old.0 + (new.0 - old.0) * fraction,
                     green: old.1 + (new.1 - old.1) * fraction,
                     blue: old.2 + (new.2 - old.2) * fraction)
    }

    private func enabled(_ relation: GraphRelation) -> Bool {
        switch relation {
        case .reference, .citation, .related: model.selectedRelation == relation
        }
    }

    private func fitCanvas() {
        guard canvasSize.width > 200, canvasSize.height > 160 else { return }
        let raw = rawPositions()
        let points = visible.compactMap { raw[$0.id] }
        guard !points.isEmpty else { scale = 1; pan = .zero; dragStart = .zero; return }
        let minX = points.map(\.x).min() ?? 0, maxX = points.map(\.x).max() ?? 0
        let minY = points.map(\.y).min() ?? 0, maxY = points.map(\.y).max() ?? 0
        let width = max(100, canvasSize.width * 0.76)
        // 给固定屏幕尺寸的节点和底部缩放/年份条留空间；窄窗口尤其不能裁掉最外圈。
        let height = max(100, min(canvasSize.height * 0.58, canvasSize.height - 145))
        scale = min(2, max(0.005, min(width / max(1, maxX - minX),
                                      height / max(1, maxY - minY))))
        pan = CGSize(width: -(minX + maxX) / 2 * scale, height: -(minY + maxY) / 2 * scale)
        dragStart = pan
    }

    private func select(at location: CGPoint, size: CGSize) {
        if let match = hitPaper(at: location, size: size) {
            model.selectedID = match.id
        }
    }

    private func hitPaper(at location: CGPoint, size: CGSize) -> GraphPaper? {
        let points = positions(size: size)
        if let match = visible.min(by: { distance(points[$0.id], location) < distance(points[$1.id], location) }),
           distance(points[match.id], location) < max(17, nodeRadius(match) + 5) { return match }
        return nil
    }

    private func updateLocalSearch() {
        if let paper = model.selectedPaper, paper.id.hasPrefix("local:reference:") {
            localSearch = LocalReferenceParser.suggestedTitle(in: paper.title)
        }
    }

    private func distance(_ point: CGPoint?, _ target: CGPoint) -> CGFloat {
        guard let point else { return .infinity }
        return hypot(point.x - target.x, point.y - target.y)
    }

    private func detail(_ paper: GraphPaper) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(paper.id == model.snapshot.paperID ? "起点论文" : "论文详情")
                    .font(DS.Typo.headline)
                Spacer()
                if model.selectedID != nil {
                    Button("返回起点", systemImage: "xmark") { model.selectedID = nil }
                        .labelStyle(.iconOnly).help("返回起点论文")
                }
            }
            .padding(DS.Space.l)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: DS.Space.l) {
                    Text(paper.title)
                        .font(DS.Typo.ui(size: 18, weight: .semibold))
                        .foregroundStyle(DS.Palette.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                    if !paper.authors.isEmpty {
                        Text(paper.authors.joined(separator: "、"))
                            .font(DS.Typo.body).foregroundStyle(DS.Palette.textSecondary)
                    }
                    HStack(spacing: DS.Space.s) {
                        Text(paper.year.map(String.init) ?? "年份不详")
                        if !paper.venue.isEmpty { Text("·"); Text(paper.venue) }
                    }
                    .font(DS.Typo.body).foregroundStyle(DS.Palette.textSecondary)
                    if !paper.id.hasPrefix("local:"), !paper.id.hasPrefix("cnki:") || paper.citedByCount > 0 {
                        HStack(alignment: .firstTextBaseline, spacing: 5) {
                            Text("\(paper.citedByCount)")
                                .font(DS.Typo.ui(size: 22, weight: .semibold))
                            Text(paper.id.hasPrefix("cnki:") ? "次被引 · 知网" : "次被引 · OpenAlex")
                                .font(DS.Typo.body).foregroundStyle(DS.Palette.textSecondary)
                        }
                    }
                    if let doi = paper.doi,
                       let url = URL(string: "https://doi.org/\(doi)") {
                        Link("打开 DOI 页面", destination: url)
                            .font(DS.Typo.body)
                            .help("https://doi.org/\(doi)")
                    }
                    if let url = paper.openAccessURL {
                        Link(paper.id.hasPrefix("cnki:") ? "打开知网题录原页" : "打开开放访问全文", destination: url).font(DS.Typo.body)
                    } else if let url = model.cnkiURL(for: paper) {
                        Link("打开知网题录原页", destination: url).font(DS.Typo.body)
                    }
                    if !paper.abstract.isEmpty {
                        Divider()
                        Text("摘要").font(DS.Typo.headline)
                        Text(paper.abstract).font(DS.Typo.body)
                            .textSelection(.enabled)
                    }
                    if let original = paper.sourceCitation {
                        Divider()
                        Text("原始题录").font(DS.Typo.headline)
                        Text(original).font(DS.Typo.body)
                            .textSelection(.enabled)
                    }
                    Divider()
                    if paper.id.hasPrefix("local:reference:") {
                        TextField("用于匹配的标题", text: $localSearch)
                            .help("本文参考文献 · 题录待核对")
                        Button("查找 OpenAlex 题录") { model.findLocalMatch(paper, query: localSearch) }
                            .disabled(model.busy || (localSearch.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && paper.doi == nil))
                    } else if paper.id.hasPrefix("local:"), !model.usesCNKIRelations(for: paper) {
                        Text("未关联题录")
                            .font(DS.Typo.body).foregroundStyle(DS.Palette.textSecondary)
                    } else {
                        ForEach(GraphRelation.allCases, id: \.self) { relation in
                            Button(relation.title, systemImage: "arrow.up.right") {
                                model.expand(paper, relation)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .disabled(model.busy || model.snapshot.papers.count >= GraphMerge.limit)
                        }
                    }
                    Button("复制标题") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(paper.title, forType: .string)
                    }
                    .font(DS.Typo.body)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(DS.Space.l)
            }
        }
        .background(DS.Palette.surfaceSunken)
    }
}
