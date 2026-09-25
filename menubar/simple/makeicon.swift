// 生成 AppIcon.iconset（再用 iconutil 转成 .icns）
// 用法: makeicon <输出目录>
// 画一个 macOS 风格圆角方（squircle 近似）+ 📂 emoji + 顶部高光

import AppKit

let outDir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "./AppIcon.iconset"
try? FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)

// 图标集需要的像素尺寸
let entries: [(String, Int)] = [
    ("icon_16x16", 16), ("icon_16x16@2x", 32),
    ("icon_32x32", 32), ("icon_32x32@2x", 64),
    ("icon_128x128", 128), ("icon_128x128@2x", 256),
    ("icon_256x256", 256), ("icon_256x256@2x", 512),
    ("icon_512x512", 512), ("icon_512x512@2x", 1024),
]

func makePNG(_ px: Int) -> Data? {
    let size = CGFloat(px)
    guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil,
                                     pixelsWide: px, pixelsHigh: px,
                                     bitsPerSample: 8, samplesPerPixel: 4,
                                     hasAlpha: true, isPlanar: false,
                                     colorSpaceName: .deviceRGB,
                                     bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
    rep.size = NSSize(width: size, height: size)

    guard let ctx = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = ctx
    ctx.imageInterpolation = .high

    // 内容区：四周留 ~7.5% 边距（macOS 图标惯例）
    let inset = size * 0.075
    let rect = NSRect(x: inset, y: inset, width: size - inset * 2, height: size - inset * 2)
    let radius = rect.width * 0.2237            // Apple squircle 近似半径

    let path = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)

    // 底色：柔和的浅蓝渐变（跟菜单栏 📂 的蓝色呼应）
    if let grad = NSGradient(colors: [
        NSColor(srgbRed: 0.937, green: 0.960, blue: 0.988, alpha: 1.0),
        NSColor(srgbRed: 0.741, green: 0.816, blue: 0.906, alpha: 1.0),
    ]) {
        grad.draw(in: path, angle: -90)
    }

    // 顶部一层白色高光，做出玻璃质感
    if let clip = ctx.cgContext as CGContext? {
        clip.saveGState()
        path.addClip()
        if let hi = NSGradient(colors: [
            NSColor(white: 1.0, alpha: 0.55),
            NSColor(white: 1.0, alpha: 0.0),
        ]) {
            let hiRect = NSRect(x: rect.minX, y: rect.midY,
                                width: rect.width, height: rect.height / 2)
            hi.draw(in: hiRect, angle: -90)
        }
        clip.restoreGState()
    }

    // 细边框
    NSColor(white: 1.0, alpha: 0.5).setStroke()
    path.lineWidth = max(1, size * 0.004)
    path.stroke()

    // 中间的 📂
    let emoji = "📂" as NSString
    let fontSize = rect.width * 0.54
    let font = NSFont(name: "Apple Color Emoji", size: fontSize)
        ?? NSFont.systemFont(ofSize: fontSize)
    let attrs: [NSAttributedString.Key: Any] = [.font: font]
    let sz = emoji.size(withAttributes: attrs)
    let origin = NSPoint(x: rect.midX - sz.width / 2,
                         y: rect.midY - sz.height / 2 + rect.height * 0.01)
    emoji.draw(at: origin, withAttributes: attrs)

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])
}

var ok = 0
for (name, px) in entries {
    guard let data = makePNG(px) else {
        FileHandle.standardError.write("fail \(name)\n".data(using: .utf8)!)
        continue
    }
    let dst = (outDir as NSString).appendingPathComponent("\(name).png")
    try? data.write(to: URL(fileURLWithPath: dst))
    ok += 1
}
print("生成 \(ok)/\(entries.count) 张 → \(outDir)")
