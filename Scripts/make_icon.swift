// App 图标生成脚本（与 BWBrandMark 同一设计语言：暖橙渐变圆角方 + 白色声波 + 分析弧线）
// 用法：swift Scripts/make_icon.swift <输出目录>
import AppKit
import CoreGraphics

let outDir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "build/icon"
try? FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)

func drawIcon(size: CGFloat) -> NSImage {
    let image = NSImage(size: NSSize(width: size, height: size))
    image.lockFocus()
    guard let ctx = NSGraphicsContext.current?.cgContext else { fatalError("no ctx") }

    // macOS 图标网格：留边约 10%，圆角约 22.5%
    let inset = size * 0.10
    let rect = CGRect(x: inset, y: inset, width: size - inset * 2, height: size - inset * 2)
    let radius = rect.width * 0.225
    let rounded = CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)

    // 底：暖橙渐变（左上亮 → 右下深）
    ctx.saveGState()
    ctx.addPath(rounded)
    ctx.clip()
    let colors = [
        CGColor(srgbRed: 1.00, green: 0.56, blue: 0.20, alpha: 1),
        CGColor(srgbRed: 0.93, green: 0.35, blue: 0.07, alpha: 1)
    ] as CFArray
    let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
                              colors: colors, locations: [0, 1])!
    ctx.drawLinearGradient(gradient,
                           start: CGPoint(x: rect.minX, y: rect.maxY),
                           end: CGPoint(x: rect.maxX, y: rect.minY),
                           options: [])

    // 高光：顶部轻微提亮增加质感
    let glossColors = [
        CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.18),
        CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.0)
    ] as CFArray
    let gloss = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
                           colors: glossColors, locations: [0, 1])!
    ctx.drawLinearGradient(gloss,
                           start: CGPoint(x: rect.midX, y: rect.maxY),
                           end: CGPoint(x: rect.midX, y: rect.midY),
                           options: [])

    // 中央声波：5 根白色圆头竖条（与 BWBrandMark 一致）
    let barHeights: [CGFloat] = [0.30, 0.55, 0.82, 0.55, 0.30]
    let barWidth = rect.width * 0.072
    let gap = rect.width * 0.062
    let totalWidth = barWidth * CGFloat(barHeights.count) + gap * CGFloat(barHeights.count - 1)
    var x = rect.midX - totalWidth / 2
    ctx.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
    for h in barHeights {
        let barHeight = rect.height * h * 0.52
        let barRect = CGRect(x: x, y: rect.midY - barHeight / 2, width: barWidth, height: barHeight)
        ctx.addPath(CGPath(roundedRect: barRect, cornerWidth: barWidth / 2,
                           cornerHeight: barWidth / 2, transform: nil))
        ctx.fillPath()
        x += barWidth + gap
    }

    // 分析弧线：声波上方一道白色弧 + 端点圆点，示意「录音 → 洞察」
    let arcRadius = rect.width * 0.30
    let arcCenter = CGPoint(x: rect.midX, y: rect.midY)
    ctx.setStrokeColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.85))
    ctx.setLineWidth(rect.width * 0.030)
    ctx.setLineCap(.round)
    ctx.addArc(center: arcCenter, radius: arcRadius,
               startAngle: .pi * 0.62, endAngle: .pi * 0.38, clockwise: true)
    ctx.strokePath()
    let dotAngle = CGFloat.pi * 0.38
    let dot = CGPoint(x: arcCenter.x + arcRadius * cos(dotAngle),
                      y: arcCenter.y + arcRadius * sin(dotAngle))
    ctx.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
    ctx.fillEllipse(in: CGRect(x: dot.x - rect.width * 0.032, y: dot.y - rect.width * 0.032,
                               width: rect.width * 0.064, height: rect.width * 0.064))

    ctx.restoreGState()
    image.unlockFocus()
    return image
}

func writePNG(_ image: NSImage, pixels: Int, to path: String) {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                               isPlanar: false, colorSpaceName: .calibratedRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = NSSize(width: pixels, height: pixels)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    image.draw(in: NSRect(x: 0, y: 0, width: pixels, height: pixels),
               from: .zero, operation: .copy, fraction: 1.0)
    NSGraphicsContext.restoreGraphicsState()
    let data = rep.representation(using: .png, properties: [:])!
    try! data.write(to: URL(fileURLWithPath: path))
}

// iconset 全尺寸
let sizes: [(name: String, px: Int)] = [
    ("icon_16x16", 16), ("icon_16x16@2x", 32),
    ("icon_32x32", 32), ("icon_32x32@2x", 64),
    ("icon_128x128", 128), ("icon_128x128@2x", 256),
    ("icon_256x256", 256), ("icon_256x256@2x", 512),
    ("icon_512x512", 512), ("icon_512x512@2x", 1024)
]
let iconsetPath = "\(outDir)/AppIcon.iconset"
try? FileManager.default.removeItem(atPath: iconsetPath)
try! FileManager.default.createDirectory(atPath: iconsetPath, withIntermediateDirectories: true)
for (name, px) in sizes {
    let img = drawIcon(size: CGFloat(px))
    writePNG(img, pixels: px, to: "\(iconsetPath)/\(name).png")
}
print("iconset 已生成：\(iconsetPath)")
