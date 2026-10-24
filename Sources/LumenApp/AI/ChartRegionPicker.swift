import SwiftUI
import AppKit
import LumenKit
import ImageIO
import UniformTypeIdentifiers

struct ChartRegionPicker: View {
    let image: AIImage
    let accept: (AIImage) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var start: CGPoint?
    @State private var region: CGRect?
    var body: some View {
        VStack(spacing: 12) {
            HStack {
                Text(image.label).lineLimit(1)
                Spacer()
                Button("取消") { dismiss() }
                Button("解读") {
                    if let region, let cropped = Self.cropped(image, region: region) { accept(cropped) }
                    else { accept(image) }
                    dismiss()
                }.keyboardShortcut(.defaultAction)
            }
            if let preview = NSImage(data: image.data) {
                GeometryReader { geometry in
                    let size = fitted(preview.size, in: geometry.size)
                    ZStack(alignment: .topLeading) {
                        Image(nsImage: preview).resizable().frame(width: size.width, height: size.height)
                        if let region {
                            Rectangle().stroke(Color.accentColor, lineWidth: 2)
                                .background(Color.accentColor.opacity(0.12))
                                .frame(width: region.width * size.width, height: region.height * size.height)
                                .offset(x: region.minX * size.width, y: region.minY * size.height)
                        }
                    }
                    .contentShape(Rectangle())
                    .gesture(DragGesture(minimumDistance: 4).onChanged { value in
                        let origin = start ?? value.startLocation
                        start = origin
                        let x1 = min(1, max(0, origin.x / size.width)), y1 = min(1, max(0, origin.y / size.height))
                        let x2 = min(1, max(0, value.location.x / size.width)), y2 = min(1, max(0, value.location.y / size.height))
                        region = CGRect(x: min(x1, x2), y: min(y1, y2), width: abs(x2 - x1), height: abs(y2 - y1))
                    }.onEnded { _ in start = nil })
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }.padding(16).frame(minWidth: 560, idealWidth: 760, minHeight: 500, idealHeight: 800)
    }
    private func fitted(_ image: CGSize, in available: CGSize) -> CGSize {
        let scale = min(available.width / max(1, image.width), available.height / max(1, image.height))
        return CGSize(width: image.width * scale, height: image.height * scale)
    }
    static func cropped(_ source: AIImage, region: CGRect) -> AIImage? {
        guard region.width > 0.01, region.height > 0.01, let provider = CGImageSourceCreateWithData(source.data as CFData, nil),
              let original = CGImageSourceCreateImageAtIndex(provider, 0, nil) else { return nil }
        let rect = CGRect(x: region.minX * Double(original.width), y: region.minY * Double(original.height),
            width: region.width * Double(original.width), height: region.height * Double(original.height)).integral
        guard let cropped = original.cropping(to: rect) else { return nil }
        let bytes = NSMutableData()
        guard let output = CGImageDestinationCreateWithData(bytes, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(output, cropped, [kCGImageDestinationLossyCompressionQuality: 0.9] as CFDictionary)
        guard CGImageDestinationFinalize(output) else { return nil }
        return .init(data: bytes as Data, label: source.label + " · 用户框选区域")
    }
}
