// 生成 Lumen 应用图标（Resources/AppIcon.icns）与 AI 图标 PNG。
//
// 用法：swift tools/make_icons.swift
//
// 设计语言（与 App 内 BrandGlyph 一致）：
// - macOS Big Sur 圆角方形（824×824 / radius 185，居中留边），
//   石板蓝低饱和对角渐变，顶部一抹暖光；
// - 字形 = 摊开的两页书 + 上方一点暖光（「流明」= 光）；
// - AI 图标 = 低饱和蓝紫双星（四芒星），透明底。
//
// 依赖系统自带的 iconutil 合成 .icns。

import AppKit

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let iconsetDir = root.appendingPathComponent("build/icon.iconset")
let resourcesDir = root.appendingPathComponent("Resources")
let aiOutDir = root.appendingPathComponent("build")

try? FileManager.default.createDirectory(at: iconsetDir, withIntermediateDirectories: true)
try? FileManager.default.createDirectory(at: resourcesDir, withIntermediateDirectories: true)
try? FileManager.default.createDirectory(at: aiOutDir, withIntermediateDirectories: true)

// MARK: - 调色（低饱和）

let slateTop = NSColor(srgbRed: 0x45/255.0, green: 0x4F/255.0, blue: 0x6B/255.0, alpha: 1)
let slateBottom = NSColor(srgbRed: 0x2C/255.0, green: 0x33/255.0, blue: 0x46/255.0, alpha: 1)
let paper = NSColor(srgbRed: 0xEFE9/255.0 * 256 / 256, green: 0xE9/255.0 * 256 / 256, blue: 0xDB/255.0 * 256 / 256, alpha: 1)
// 上一行的计算写法可读性差，直接用准确的 srgb 分量：
let paperInk = NSColor(srgbRed: 0xEF/255.0, green: 0xE9/255.0, blue: 0xDB/255.0, alpha: 1)
let paperSoft = NSColor(srgbRed: 0xE9/255.0, green: 0xE3/255.0, blue: 0xD5/255.0, alpha: 1)

let aiTop = NSColor(srgbRed: 0x98/255.0, green: 0xA4/255.0, blue: 0xD6/255.0, alpha: 1)
let aiBottom = NSColor(srgbRed: 0x5C/255.0, green: 0x6B/255.0, blue: 0xA8/255.0, alpha: 1)

// MARK: - 绘制原语

/// 在 1024 画布上以比例坐标画四芒星（控制点收向中心形成内凹）。
func addSparkle(to path: NSBezierPath, cx: CGFloat, cy: CGFloat, r: CGFloat, pinch: CGFloat = 0.16) {
    let p = pinch * r
    path.move(to: NSPoint(x: cx, y: cy - r))
    path.curve(to: NSPoint(x: cx + r, y: cy), controlPoint1: NSPoint(x: cx + p, y: cy - p * 0.35), controlPoint2: NSPoint(x: cx + p, y: cy - p * 0.35))
    path.curve(to: NSPoint(x: cx, y: cy + r), controlPoint1: NSPoint(x: cx + p, y: cy + p * 0.35), controlPoint2: NSPoint(x: cx + p, y: cy + p * 0.35))
    path.curve(to: NSPoint(x: cx - r, y: cy), controlPoint1: NSPoint(x: cx - p, y: cy + p * 0.35), controlPoint2: NSPoint(x: cx - p, y: cy + p * 0.35))
    path.curve(to: NSPoint(x: cx, y: cy - r), controlPoint1: NSPoint(x: cx - p, y: cy - p * 0.35), controlPoint2: NSPoint(x: cx - p, y: cy - p * 0.35))
    path.close()
}

/// 单侧书页：摊开书本的一半（AppKit 坐标，y 向上）。
/// 造型要点：外侧两角微微上翘、书缝处最低——
/// 正面平视一本摊开的书的标准剪影。
/// `side` = -1 画左页，+1 画右页。
func bookPagePath(side: CGFloat) -> NSBezierPath {
    let spineX: CGFloat = 512
    let outerX = spineX + side * 227   // 外缘 x
    let spineTopY: CGFloat = 545       // 书缝处上缘（最低点）
    let outerTopY: CGFloat = 602       // 外角上缘（上翘）
    let spineBottomY: CGFloat = 462    // 书缝处下缘（最低）
    let outerBottomY: CGFloat = 482    // 外角下缘

    let path = NSBezierPath()
    path.move(to: NSPoint(x: spineX, y: spineTopY))
    // 上缘：从书缝向外角，微微上拱（纸面的弧度）
    path.curve(
        to: NSPoint(x: outerX, y: outerTopY),
        controlPoint1: NSPoint(x: spineX + side * 105, y: spineTopY + 52),
        controlPoint2: NSPoint(x: outerX - side * 55, y: outerTopY + 8)
    )
    // 外缘直落
    path.line(to: NSPoint(x: outerX, y: outerBottomY))
    // 下缘收回书缝，微微下沉
    path.curve(
        to: NSPoint(x: spineX, y: spineBottomY),
        controlPoint1: NSPoint(x: outerX - side * 70, y: outerBottomY - 10),
        controlPoint2: NSPoint(x: spineX + side * 110, y: spineBottomY - 6)
    )
    path.close()
    return path
}

// MARK: - App 图标

func drawAppIcon(size: CGFloat) -> NSImage {
    let image = NSImage(size: NSSize(width: size, height: size))
    image.lockFocusFlipped(false)

    let s = size / 1024.0

    // 1. Big Sur 圆角方形底板：824×824，圆角 185，居中
    let plateRect = CGRect(x: 100 * s, y: 100 * s, width: 824 * s, height: 824 * s)
    let plate = NSBezierPath(roundedRect: plateRect, xRadius: 185 * s, yRadius: 185 * s)
    NSColor.clear.setFill()
    NSBezierPath(rect: CGRect(origin: .zero, size: image.size)).fill()

    NSGradient(starting: slateTop, ending: slateBottom)?
        .draw(in: plate, angle: -60)
    plate.fill()

    // 2. 顶部暖光（径向，叠在渐变上，裁剪进底板）
    if let ctx = NSGraphicsContext.current?.cgContext {
        ctx.saveGState()
        plate.addClip()
        let glowCenter = CGPoint(x: plateRect.midX, y: plateRect.maxY - 190 * s)
        let colors = [NSColor(srgbRed: 0xEF/255, green: 0xE9/255, blue: 0xDB/255, alpha: 0.16).cgColor,
                      NSColor(srgbRed: 0xEF/255, green: 0xE9/255, blue: 0xDB/255, alpha: 0).cgColor] as CFArray
        if let grad = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 1]) {
            ctx.drawRadialGradient(grad,
                                   startCenter: glowCenter, startRadius: 0,
                                   endCenter: glowCenter, endRadius: 430 * s,
                                   options: [])
        }
        ctx.restoreGState()
    }

    // 3. 字形：光点 + 摊开书页
    // 光晕（径向渐变往外淡出；NSGradient.draw 只有线性，必须走 CGContext）
    let orbY: CGFloat = 764 * s
    if let ctx = NSGraphicsContext.current?.cgContext {
        ctx.saveGState()
        ctx.addEllipse(in: CGRect(x: 512 * s - 150 * s, y: orbY - 150 * s, width: 300 * s, height: 300 * s))
        ctx.clip()
        let colors = [paperInk.withAlphaComponent(0.38).cgColor, paperInk.withAlphaComponent(0).cgColor] as CFArray
        if let grad = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 1]) {
            ctx.drawRadialGradient(grad,
                                   startCenter: CGPoint(x: 512 * s, y: orbY), startRadius: 0,
                                   endCenter: CGPoint(x: 512 * s, y: orbY), endRadius: 150 * s,
                                   options: [])
        }
        ctx.restoreGState()
    }
    // 光点本体
    let orb = NSBezierPath(ovalIn: CGRect(x: 512 * s - 42 * s, y: orbY - 42 * s, width: 84 * s, height: 84 * s))
    paperInk.setFill()
    orb.fill()

    // 书页（左暗右亮，制造翻开的光影）
    paperSoft.setFill()
    bookPagePath(side: -1).fill()
    paperInk.setFill()
    bookPagePath(side: 1).fill()

    // 4. 内缘高光，让底板有一点「釉面」
    let inner = NSBezierPath(roundedRect: plateRect.insetBy(dx: 2.5 * s, dy: 2.5 * s), xRadius: 183 * s, yRadius: 183 * s)
    inner.lineWidth = 3 * s
    NSColor.white.withAlphaComponent(0.10).setStroke()
    inner.stroke()

    image.unlockFocus()
    return image
}

// MARK: - AI 图标（透明底双星）

func drawAIIcon(size: CGFloat) -> NSImage {
    let image = NSImage(size: NSSize(width: size, height: size))
    image.lockFocusFlipped(false)

    let s = size / 1024.0
    let path = NSBezierPath()
    // 主星：中心略偏左下
    addSparkle(to: path, cx: 430 * s, cy: 400 * s, r: 330 * s, pinch: 0.17)
    // 辅星：右上
    addSparkle(to: path, cx: 790 * s, cy: 760 * s, r: 130 * s, pinch: 0.20)

    NSGradient(starting: aiTop, ending: aiBottom)?.draw(in: path, angle: -60)

    image.unlockFocus()
    return image
}

// MARK: - 导出

func writePNG(_ image: NSImage, pixelSize: Int, to url: URL) throws {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: pixelSize, pixelsHigh: pixelSize,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
    )!
    rep.size = NSSize(width: pixelSize, height: pixelSize)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    image.draw(in: NSRect(x: 0, y: 0, width: pixelSize, height: pixelSize))
    NSGraphicsContext.restoreGraphicsState()
    let data = rep.representation(using: .png, properties: [:])!
    try data.write(to: url)
}

let appIcon = drawAppIcon(size: 1024)
let iconsetScales: [(String, Int)] = [
    ("icon_16x16.png", 16),
    ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32),
    ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128),
    ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256),
    ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512),
    ("icon_512x512@2x.png", 1024),
]
for (name, px) in iconsetScales {
    try writePNG(appIcon, pixelSize: px, to: iconsetDir.appendingPathComponent(name))
}

let aiIcon = drawAIIcon(size: 1024)
try writePNG(aiIcon, pixelSize: 1024, to: aiOutDir.appendingPathComponent("LumenAI-icon-1024.png"))
try writePNG(aiIcon, pixelSize: 512, to: aiOutDir.appendingPathComponent("LumenAI-icon-512.png"))
try writePNG(appIcon, pixelSize: 512, to: aiOutDir.appendingPathComponent("Lumen-icon-512.png"))

print("✅ 图标已生成：build/icon.iconset、build/LumenAI-icon-*.png、build/Lumen-icon-512.png")
