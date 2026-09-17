import AppKit
import Foundation

/// 把截图的一块区域裁出来并放大，用于逐像素核对控件是否重叠/被裁掉。
///
/// 用法：
///   swift tools/crop_image.swift <输入.png> <输出.png> <比例x,比例y,宽,高> [放大倍数]
///
/// 区域用**内容比例**（0…1）而不是像素，是因为自检截图的像素尺寸随窗口大小与屏幕
/// 缩放变化，写死像素的坐标换一台机器就错位了。
func fail(_ message: String) -> Never {
    FileHandle.standardError.write(("用法错误：" + message + "\n").data(using: .utf8)!)
    exit(1)
}

let args = Array(CommandLine.arguments.dropFirst())
guard args.count >= 3 else {
    fail("需要 输入路径 输出路径 区域")
}

let inputPath = args[0]
let outputPath = args[1]
let parts = args[2].split(separator: ",").map(String.init)
guard parts.count == 4,
      let rx = Double(parts[0]), let ry = Double(parts[1]),
      let rw = Double(parts[2]), let rh = Double(parts[3]) else {
    fail("区域要写成 比例x,比例y,宽,高，例如 0.55,0.85,0.45,0.15")
}
let magnification = args.count >= 4 ? (Double(args[3]) ?? 2.0) : 2.0

guard let source = NSImage(contentsOfFile: inputPath),
      let tiff = source.tiffRepresentation,
      let bitmap = NSBitmapImageRep(data: tiff) else {
    fail("读不出 \(inputPath)")
}

let width = CGFloat(bitmap.pixelsWide)
let height = CGFloat(bitmap.pixelsHigh)

let rect = CGRect(
    x: (rx * width).rounded(),
    y: (ry * height).rounded(),
    width: max(1, (rw * width).rounded()),
    height: max(1, (rh * height).rounded())
)

guard let cgSource = bitmap.cgImage,
      let cropped = cgSource.cropping(to: rect) else {
    fail("裁剪失败：区域 \(rect) 超出 \(Int(width))x\(Int(height))")
}

let outWidth = Int(CGFloat(cropped.width) * magnification)
let outHeight = Int(CGFloat(cropped.height) * magnification)

guard let context = CGContext(
    data: nil,
    width: outWidth,
    height: outHeight,
    bitsPerComponent: 8,
    bytesPerRow: 0,
    space: CGColorSpaceCreateDeviceRGB(),
    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
) else { fail("建不出画布") }

context.interpolationQuality = .none
context.draw(cropped, in: CGRect(x: 0, y: 0, width: outWidth, height: outHeight))

guard let output = context.makeImage(),
      let png = NSBitmapImageRep(cgImage: output).representation(using: .png, properties: [:]) else {
    fail("编码 PNG 失败")
}

try? png.write(to: URL(fileURLWithPath: outputPath))
print("已裁剪 \(Int(rect.width))x\(Int(rect.height)) → \(outWidth)x\(outHeight) @\(magnification)×  \(outputPath)")
