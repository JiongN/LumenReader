import Foundation
import PDFKit
import ImageIO
import UniformTypeIdentifiers
import LumenKit

/// One private document per operation; no reference to the live PDFView.
actor PDFPageAssets {
    static let shared = PDFPageAssets()
    func image(path: String, pageIndex: Int, bounds: DocumentBlock.Bounds? = nil) throws -> AIImage {
        try Task.checkCancellation()
        let before = try DocumentSourceVersion.current(path: path)
        return try autoreleasepool {
            guard let document = CGPDFDocument(URL(fileURLWithPath: path) as CFURL),
                  pageIndex >= 0, let page = document.page(at: pageIndex + 1) else { throw AIError.preparation("无法读取图表所在页面。") }
            let box = page.getBoxRect(.cropBox)
            let rotated = abs(page.rotationAngle) % 180 == 90
            let size = rotated ? CGSize(width: box.height, height: box.width) : box.size
            let scale = min(1800 / max(1, size.width), 2600 / max(1, size.height))
            let width = max(1, Int(size.width * scale)), height = max(1, Int(size.height * scale))
            guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { throw AIError.invalidResponse }
            let target = CGRect(x: 0, y: 0, width: width, height: height)
            context.setFillColor(CGColor(gray: 1, alpha: 1)); context.fill(target)
            context.concatenate(page.getDrawingTransform(.cropBox, rect: target, rotate: 0, preserveAspectRatio: true))
            context.drawPDFPage(page)
            guard var image = context.makeImage() else { throw AIError.invalidResponse }
            if let bounds, bounds.isValid {
                let crop = CGRect(x: bounds.x * Double(width), y: bounds.y * Double(height),
                    width: bounds.width * Double(width), height: bounds.height * Double(height)).integral
                guard let cropped = image.cropping(to: crop) else { throw AIError.invalidResponse }
                image = cropped
            }
            let output = NSMutableData()
            guard let destination = CGImageDestinationCreateWithData(output, UTType.jpeg.identifier as CFString, 1, nil) else { throw AIError.invalidResponse }
            CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.82] as CFDictionary)
            guard CGImageDestinationFinalize(destination), output.length <= 2 * 1024 * 1024 else { throw AIError.responseTooLarge }
            guard try DocumentSourceVersion.current(path: path) == before else { throw AIError.preparation("读取图表期间文件已变化，请重试。") }
            return AIImage(data: output as Data, label: "\(URL(fileURLWithPath: path).lastPathComponent) · 第 \(pageIndex + 1) 页" + (bounds == nil ? "（整页图像）" : "（区域图像）"))
        }
    }
}
