import AppKit

/* ============================================================
   菜单栏角标（真实驱动：设置里改「显示哪些档位 / 标签样式」立刻生效）

   三种样式：
     · dots   彩色圆点 + 数字（默认）
     · counts 数字方块（更克制，适合浅色菜单栏）
     · plain  仅 📂，不带任何数字
   ============================================================ */
enum StatusBadge {
    static let height: CGFloat = 20
    static let padX: CGFloat = 4
    static let boxRadius: CGFloat = 6
    static let folderSize: CGFloat = 13
    static let dotD: CGFloat = 12.5
    static let dotGap: CGFloat = 2.5
    static let gapFolderDots: CGFloat = 3.5

    struct Dot {
        let color: NSColor
        let text: NSColor
        let n: Int
    }

    @MainActor static func dots(red: Int, yellow: Int, blue: Int, _ s: BoardSettings) -> [Dot] {
        var out: [Dot] = []
        if s.showRed, red > 0 {
            out.append(Dot(color: NSColor(srgbRed: 1.00, green: 0.231, blue: 0.188, alpha: 1),
                           text: .white, n: red))
        }
        if s.showYellow, yellow > 0 {
            out.append(Dot(color: NSColor(srgbRed: 1.00, green: 0.800, blue: 0.000, alpha: 1),
                           text: NSColor(white: 0.06, alpha: 1), n: yellow))
        }
        if s.showBlue, blue > 0 {
            out.append(Dot(color: NSColor(srgbRed: 0.00, green: 0.478, blue: 1.000, alpha: 1),
                           text: .white, n: blue))
        }
        return out
    }

    @MainActor static func image(red: Int, yellow: Int, blue: Int, _ s: BoardSettings) -> NSImage {
        let style = s.labelStyle
        let ds = style == .plain ? [] : dots(red: red, yellow: yellow, blue: blue, s)

        let folder = NSAttributedString(string: "📂", attributes: [.font: NSFont.systemFont(ofSize: folderSize)])
        let folderW = (folder.size().width).rounded(.up)

        let dotW: CGFloat = style == .counts ? 14 : dotD
        let dotsW = ds.isEmpty ? 0 : CGFloat(ds.count) * dotW + CGFloat(ds.count - 1) * dotGap
        let w = padX + folderW + (ds.isEmpty ? 0 : gapFolderDots + dotsW) + padX
        let h = height

        let scale: CGFloat = 2
        let pw = Int((w * scale).rounded()), ph = Int((h * scale).rounded())
        guard let ctx = CGContext(data: nil, width: pw, height: ph, bitsPerComponent: 8,
                                  bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            return NSImage(size: NSSize(width: w, height: h))
        }
        ctx.scaleBy(x: scale, y: scale)
        ctx.setShouldAntialias(true)

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
        paint(size: NSSize(width: w, height: h), folder: folder, folderW: folderW,
              dots: ds, style: style)
        NSGraphicsContext.restoreGraphicsState()

        let img: NSImage
        if let cg = ctx.makeImage() {
            img = NSImage(size: NSSize(width: w, height: h))
            img.addRepresentation(NSBitmapImageRep(cgImage: cg))
        } else {
            img = NSImage(size: NSSize(width: w, height: h))
        }
        img.isTemplate = false
        return img
    }

    private static func paint(size: NSSize, folder: NSAttributedString,
                              folderW: CGFloat, dots: [Dot], style: LabelStyle) {
        let w = size.width, h = size.height

        if style == .dots {
            // 细圆角框：整幅图就是点击区，框里任何位置点击都会展开面板
            let stroke = darkMode() ? NSColor(white: 1, alpha: 0.42) : NSColor(white: 0, alpha: 0.26)
            let box = CGRect(x: 0.5, y: 0.5, width: w - 1, height: h - 1)
            let path = CGPath(roundedRect: box, cornerWidth: boxRadius, cornerHeight: boxRadius, transform: nil)
            stroke.setStroke()
            let p = NSBezierPath(cgPath: path)
            p.lineWidth = 1
            p.stroke()
        }

        let fs = folder.size()
        folder.draw(at: NSPoint(x: padX + (folderW - fs.width) / 2, y: (h - fs.height) / 2))

        var x = padX + folderW + (dots.isEmpty ? 0 : gapFolderDots)
        for d in dots {
            let cy = h / 2
            let dw: CGFloat = style == .counts ? 14 : dotD
            let dh: CGFloat = style == .counts ? 13 : dotD
            let rect = CGRect(x: x, y: cy - dh / 2, width: dw, height: dh)
            let radius: CGFloat = 4

            let path = CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
            d.color.setFill()
            NSBezierPath(cgPath: path).fill()

            if style == .counts {
                // 方块上压一条更亮的顶边，有点玻璃的厚度感
                NSColor(white: 1, alpha: 0.22).setFill()
                NSBezierPath(cgPath: CGPath(roundedRect: CGRect(x: rect.minX, y: rect.maxY - 4,
                                                                width: rect.width, height: 4),
                                            cornerWidth: 3, cornerHeight: 3, transform: nil)).fill()
            }

            var size: CGFloat = style == .counts ? 9 : 9.5
            var attr = number("\(d.n)", size: size, color: d.text)
            while attr.size().width > dw - 3.6 && size > 5.5 {
                size -= 0.5
                attr = number("\(d.n)", size: size, color: d.text)
            }
            let ts = attr.size()
            attr.draw(at: NSPoint(x: x + (dw - ts.width) / 2, y: cy - ts.height / 2))
            x += dw + dotGap
        }
    }

    private static func number(_ s: String, size: CGFloat, color: NSColor) -> NSAttributedString {
        NSAttributedString(string: s, attributes: [
            .font: NSFont.systemFont(ofSize: size, weight: .bold),
            .foregroundColor: color,
        ])
    }

    static func darkMode() -> Bool {
        (UserDefaults.standard.string(forKey: "AppleInterfaceStyle") ?? "")
            .lowercased().contains("dark")
    }
}
