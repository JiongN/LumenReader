import SwiftUI

struct TranscriptGeometrySample: Equatable, Sendable {
    var id: UUID
    var rect: CGRect
    var mounted: Bool
    var viewportHeight: CGFloat
}

private struct TranscriptGeometryObserverKey: EnvironmentKey {
    static let defaultValue: (@MainActor @Sendable (TranscriptGeometrySample) -> Void)? = nil
}

extension EnvironmentValues {
    var transcriptGeometryObserver: (@MainActor @Sendable (TranscriptGeometrySample) -> Void)? {
        get { self[TranscriptGeometryObserverKey.self] }
        set { self[TranscriptGeometryObserverKey.self] = newValue }
    }
}

/// Unlike LazyVStack's estimated extent, an offscreen row keeps the exact
/// space it last occupied. New replies cannot evict all visible history rows.
struct TranscriptMessage<Content: View>: View {
    var id: UUID
    var keepMounted: Bool
    var viewportHeight: CGFloat
    @ViewBuilder var content: () -> Content

    @State private var nearViewport = false
    @State private var measuredHeight: CGFloat = 160
    @Environment(\.transcriptGeometryObserver) private var observe

    var body: some View {
        let mounted = keepMounted || nearViewport
        return Group {
            if mounted {
                content()
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height in
                        if height.isFinite && height > 0 { measuredHeight = height }
                    }
            } else {
                Color.clear.frame(height: measuredHeight)
                    .accessibilityHidden(true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onGeometryChange(for: Bool.self) { geometry in
            let rect = geometry.frame(in: .scrollView(axis: .vertical))
            return rect.maxY >= -viewportHeight && rect.minY <= viewportHeight * 2
        } action: { nearViewport = $0 }
        .background {
            if let observe {
                Color.clear.onGeometryChange(for: TranscriptGeometrySample.self) { geometry in
                    .init(id: id, rect: geometry.frame(in: .scrollView(axis: .vertical)),
                          mounted: mounted, viewportHeight: viewportHeight)
                } action: { observe($0) }
            }
        }
        .id(id)
    }
}
