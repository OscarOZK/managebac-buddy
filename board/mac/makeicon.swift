import AppKit
import Foundation

/* 用 CoreGraphics 画 macOS 风格圆角方图标（squircle 近似），无需任何设计素材。
   用法：makeicon <输出 .iconset 目录> <emoji> <亮色hex> <暗色hex> */

let args = CommandLine.arguments
guard args.count >= 5 else {
    print("usage: makeicon <iconset-dir> <emoji> <hexTop> <hexBottom>")
    exit(1)
}
let outDir = args[1]
let emoji = args[2]

func rgb(_ hex: String) -> NSColor {
    var s = hex
    if s.hasPrefix("#") { s.removeFirst() }
    let v = UInt32(s, radix: 16) ?? 0
    return NSColor(srgbRed: CGFloat((v >> 16) & 0xff) / 255,
                   green: CGFloat((v >> 8) & 0xff) / 255,
                   blue: CGFloat(v & 0xff) / 255, alpha: 1)
}
let top = rgb(args[3])
let bottom = rgb(args[4])

try? FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)

func draw(size: CGFloat, to path: String) {
    let px = Int(size)
    guard let ctx = CGContext(data: nil, width: px, height: px, bitsPerComponent: 8,
                              bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
    ctx.setShouldAntialias(true)

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)

    let inset = size * 0.078
    let rect = NSRect(x: inset, y: inset, width: size - inset * 2, height: size - inset * 2)
    let radius = rect.width * 0.2237
    let squircle = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)

    // ① 底部投影
    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor(white: 0, alpha: 0.28)
    shadow.shadowBlurRadius = size * 0.045
    shadow.shadowOffset = NSSize(width: 0, height: -size * 0.018)
    shadow.set()
    NSColor(white: 0.1, alpha: 1).setFill()
    squircle.fill()
    NSGraphicsContext.restoreGraphicsState()

    // ② 主渐变
    NSGradient(colors: [top, bottom])!.draw(in: squircle, angle: -90)

    // ③ 顶部高光（玻璃感）
    NSGraphicsContext.saveGraphicsState()
    squircle.addClip()
    let gloss = NSRect(x: rect.minX, y: rect.midY, width: rect.width, height: rect.height / 2)
    NSGradient(colors: [NSColor(white: 1, alpha: 0.34), NSColor(white: 1, alpha: 0)])!
        .draw(in: gloss, angle: -90)
    // 内圈细白边
    let inner = NSBezierPath(roundedRect: rect.insetBy(dx: rect.width * 0.012, dy: rect.width * 0.012),
                             xRadius: radius * 0.97, yRadius: radius * 0.97)
    inner.lineWidth = max(1, size * 0.006)
    NSColor(white: 1, alpha: 0.22).setStroke()
    inner.stroke()
    NSGraphicsContext.restoreGraphicsState()

    // ④ emoji（自带内边距，字号取内容宽的 0.54 视觉最合适）
    let font = NSFont(name: "Apple Color Emoji", size: rect.width * 0.54)
        ?? NSFont.systemFont(ofSize: rect.width * 0.54)
    let attr = NSAttributedString(string: emoji, attributes: [.font: font])
    let s = attr.size()
    attr.draw(at: NSPoint(x: rect.midX - s.width / 2, y: rect.midY - s.height / 2))

    NSGraphicsContext.restoreGraphicsState()

    guard let cg = ctx.makeImage() else { return }
    let rep = NSBitmapImageRep(cgImage: cg)
    if let png = rep.representation(using: .png, properties: [:]) {
        try? png.write(to: URL(fileURLWithPath: path))
    }
}

let specs: [(String, CGFloat)] = [
    ("icon_16x16.png", 16), ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32), ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128), ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256), ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512), ("icon_512x512@2x.png", 1024),
]
for (name, size) in specs {
    draw(size: size, to: "\(outDir)/\(name)")
}
print("iconset ok: \(outDir)")
