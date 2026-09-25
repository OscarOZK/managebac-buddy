// 生成 watch App 图标（单张 1024×1024 PNG，Xcode 14+ 单尺寸 AppIcon）
// 用法: makeicon-watch <输出 png 路径>
// 手表图标会被系统裁成圆形，所以整幅满铺、不画圆角。

import AppKit

let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "./icon-1024.png"
let px = 1024
let size = CGFloat(px)

guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil,
                                 pixelsWide: px, pixelsHigh: px,
                                 bitsPerSample: 8, samplesPerPixel: 4,
                                 hasAlpha: true, isPlanar: false,
                                 colorSpaceName: .deviceRGB,
                                 bytesPerRow: 0, bitsPerPixel: 0) else { exit(1) }
rep.size = NSSize(width: size, height: size)

guard let ctx = NSGraphicsContext(bitmapImageRep: rep) else { exit(2) }
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = ctx
ctx.imageInterpolation = .high

let full = NSRect(x: 0, y: 0, width: size, height: size)

// 底色：与菜单栏图标同一套浅蓝渐变
if let g = NSGradient(colors: [
    NSColor(srgbRed: 0.949, green: 0.969, blue: 0.996, alpha: 1.0),
    NSColor(srgbRed: 0.678, green: 0.776, blue: 0.898, alpha: 1.0),
]) {
    g.draw(in: full, angle: -90)
}

// 顶部玻璃高光
if let hi = NSGradient(colors: [NSColor(white: 1, alpha: 0.55),
                                NSColor(white: 1, alpha: 0.0)]) {
    hi.draw(in: NSRect(x: 0, y: size / 2, width: size, height: size / 2), angle: -90)
}

// 中间 📂（缩小到 0.5，保证被圆裁后仍完整）
let emoji = "📂" as NSString
let font = NSFont(name: "Apple Color Emoji", size: size * 0.50)
    ?? NSFont.systemFont(ofSize: size * 0.50)
let attrs: [NSAttributedString.Key: Any] = [.font: font]
let sz = emoji.size(withAttributes: attrs)
emoji.draw(at: NSPoint(x: (size - sz.width) / 2, y: (size - sz.height) / 2), withAttributes: attrs)

NSGraphicsContext.restoreGraphicsState()

guard let data = rep.representation(using: .png, properties: [:]) else { exit(3) }
try data.write(to: URL(fileURLWithPath: out))
print("生成 \(px)×\(px) → \(out)")
