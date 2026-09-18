// 两张同尺寸 PNG 的逐像素对比。
//
// 用途：验证「关掉页面投影 / 页间留白 / 降插值」是否改变了渲染观感。
// 人眼只能看出「变了没有」，看不出「变了多少」；这个工具给出客观数字，
// 人眼再判断「变了的地方算不算退化」。
//
// 用法：
//   swift tools/image_diff.swift <图A> <图B> [阈值=8]
//
// 输出：
//   - 尺寸（不一致直接报错退出：尺寸不同就没法逐像素比）
//   - 差异像素比例（任一通道差值 > 阈值的像素占比）
//   - 最大 / 平均通道差
//   - 差异包围盒
//   - 8×8 网格的差异密度（一眼看出差异集中在画面哪块）

import Foundation
import ImageIO
import CoreGraphics

let args = CommandLine.arguments
guard args.count >= 3 else {
    print("用法：swift tools/image_diff.swift <图A> <图B> [阈值=8]")
    exit(2)
}
let threshold = args.count >= 4 ? (Int(args[3]) ?? 8) : 8

func loadRGBA(_ path: String) -> (w: Int, h: Int, pixels: [UInt8])? {
    let url = URL(fileURLWithPath: path)
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
          let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
        print("无法读取图片：\(path)")
        return nil
    }
    let w = image.width
    let h = image.height
    guard w > 0, h > 0 else { return nil }
    var buffer = [UInt8](repeating: 0, count: w * h * 4)
    let ok = buffer.withUnsafeMutableBytes { raw -> Bool in
        guard let context = CGContext(
            data: raw.baseAddress,
            width: w, height: h,
            bitsPerComponent: 8,
            bytesPerRow: w * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return false }
        context.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        return true
    }
    guard ok else { return nil }
    return (w, h, buffer)
}

guard let a = loadRGBA(args[1]), let b = loadRGBA(args[2]) else {
    exit(1)
}
guard a.w == b.w, a.h == b.h else {
    print("尺寸不一致：A=\(a.w)x\(a.h) B=\(b.w)x\(b.h) —— 无法逐像素比较")
    exit(1)
}

let width = a.w
let height = a.h
let pixelCount = width * height

var differing = 0
var maxDelta = 0
var sumDelta = 0
var minX = width, minY = height, maxX = -1, maxY = -1
let grid = 8
var gridCounts = [Int](repeating: 0, count: grid * grid)
var gridTotals = [Int](repeating: 0, count: grid * grid)

for y in 0..<height {
    let gy = min(grid - 1, y * grid / height)
    for x in 0..<width {
        let gx = min(grid - 1, x * grid / width)
        let cell = gy * grid + gx
        gridTotals[cell] += 1

        let i = (y * width + x) * 4
        let dr = abs(Int(a.pixels[i]) - Int(b.pixels[i]))
        let dg = abs(Int(a.pixels[i + 1]) - Int(b.pixels[i + 1]))
        let db = abs(Int(a.pixels[i + 2]) - Int(b.pixels[i + 2]))
        let delta = max(dr, max(dg, db))
        sumDelta += delta
        if delta > maxDelta { maxDelta = delta }
        if delta > threshold {
            differing += 1
            gridCounts[cell] += 1
            if x < minX { minX = x }
            if y < minY { minY = y }
            if x > maxX { maxX = x }
            if y > maxY { maxY = y }
        }
    }
}

let fraction = Double(differing) / Double(pixelCount) * 100
let meanDelta = Double(sumDelta) / Double(pixelCount)

print("尺寸 \(width)x\(height)，阈值 \(threshold)/255")
print(String(format: "差异像素 %d / %d = %.3f%%   最大通道差 %d   平均通道差 %.3f",
             differing, pixelCount, fraction, maxDelta, meanDelta))
if differing > 0 {
    print("差异包围盒 x=\(minX)…\(maxX) y=\(minY)…\(maxY)（原点在左上）")
    print("8×8 网格差异密度（每格：差异像素占比 %）：")
    for gy in 0..<grid {
        var row: [String] = []
        for gx in 0..<grid {
            let cell = gy * grid + gx
            let total = max(1, gridTotals[cell])
            row.append(String(format: "%5.1f", Double(gridCounts[cell]) / Double(total) * 100))
        }
        print("  " + row.joined(separator: " "))
    }
} else {
    print("逐像素完全一致（阈值 \(threshold) 内）")
}
