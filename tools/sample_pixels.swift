// 截图取色。用于客观验证视觉改动（主题对比度、材质深浅），代替肉眼判断。
//
// 用法：
//   swift tools/sample_pixels.swift <图片> <x比例,y比例> [<x比例,y比例> ...]
//   swift tools/sample_pixels.swift /tmp/shot.png 0.05,0.5 0.42,0.5
//
// 坐标用比例（0…1）而不是像素，这样不必关心截图是 1x 还是 2x。

import Foundation
import AppKit

let arguments = CommandLine.arguments
guard arguments.count >= 3 else {
    print("用法：swift tools/sample_pixels.swift <图片> <x比例,y比例> ...")
    exit(1)
}

let imagePath = arguments[1]
guard let image = NSImage(contentsOfFile: imagePath),
      let rep = NSBitmapImageRep(data: image.tiffRepresentation ?? Data()) else {
    print("无法读取图片：\(imagePath)")
    exit(1)
}

let width = rep.pixelsWide
let height = rep.pixelsHigh
print("\(imagePath)  \(width)x\(height)")

for argument in arguments.dropFirst(2) {
    let parts = argument.split(separator: ",").compactMap { Double($0) }
    guard parts.count == 2 else {
        print("跳过无效坐标：\(argument)")
        continue
    }

    let x = min(width - 1, max(0, Int(parts[0] * Double(width))))
    let y = min(height - 1, max(0, Int(parts[1] * Double(height))))

    guard let color = rep.colorAt(x: x, y: y) else {
        print("  (\(argument)) 取色失败")
        continue
    }

    let srgb = color.usingColorSpace(.sRGB) ?? color
    let r = Int((srgb.redComponent * 255).rounded())
    let g = Int((srgb.greenComponent * 255).rounded())
    let b = Int((srgb.blueComponent * 255).rounded())
    // 感知亮度，用于判断"这是深底还是浅底"
    let luma = (0.2126 * Double(r) + 0.7152 * Double(g) + 0.0722 * Double(b)) / 255

    print(String(
        format: "  比例 %@  → 像素(%d,%d)  #%02X%02X%02X  亮度 %.2f  %@",
        argument, x, y, r, g, b, luma, luma > 0.5 ? "浅" : "深"
    ))
}
