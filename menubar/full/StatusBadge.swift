import AppKit

/* ============================================================
   菜单栏角标

   图像 = 细圆角框内：[📂] + 红/黄/蓝三颗小圆点（每颗里是数量）
   · 颜色与展开面板里「待办事项」的框一一对应：红=≤26h、黄=26–50h、蓝=50–74h
   · 某档数量为 0 → 该圆点不画（绿档永远不画，逾期也不上状态栏）
   · 整幅图就是菜单栏项的点击区域，所以「框里任何位置点击都会展开」
   · 必须 isTemplate = false，否则菜单栏会把整幅图染成单色、看不出红黄蓝
   ============================================================ */
enum StatusBadge {
    static let height: CGFloat = 20
    static let padX: CGFloat = 4
    static let boxRadius: CGFloat = 6
    static let folderSize: CGFloat = 13
    static let dotD: CGFloat = 12.5
    static let dotGap: CGFloat = 2
    static let gapFolderDots: CGFloat = 3

    struct Dot {
        let color: NSColor
        let text: NSColor
        let n: Int
    }

    /* 红 = 紧急(≤26h) + 逾期；黄 = 26–50h；蓝 = 50–74h */
    static func dots(red: Int, yellow: Int, blue: Int) -> [Dot] {
        var out: [Dot] = []
        if red > 0 {
            out.append(Dot(color: NSColor(srgbRed: 1.00, green: 0.231, blue: 0.188, alpha: 1),
                           text: .white, n: red))
        }
        if yellow > 0 {
            out.append(Dot(color: NSColor(srgbRed: 1.00, green: 0.800, blue: 0.000, alpha: 1),
                           text: NSColor(white: 0.08, alpha: 1), n: yellow))
        }
        if blue > 0 {
            out.append(Dot(color: NSColor(srgbRed: 0.00, green: 0.478, blue: 1.000, alpha: 1),
                           text: .white, n: blue))
        }
        return out
    }

    static func image(red: Int, yellow: Int, blue: Int) -> NSImage {
        let ds = dots(red: red, yellow: yellow, blue: blue)

        let folder = NSAttributedString(string: "📂", attributes: [.font: NSFont.systemFont(ofSize: folderSize)])
        let folderW = (folder.size().width).rounded(.up)

        let dotsW = ds.isEmpty ? 0 : CGFloat(ds.count) * dotD + CGFloat(ds.count - 1) * dotGap
        let w = padX + folderW + (ds.isEmpty ? 0 : gapFolderDots + dotsW) + padX
        let h = height

        let scale: CGFloat = 2
        let pw = Int((w * scale).rounded()), ph = Int((h * scale).rounded())
        let cs = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(data: nil, width: pw, height: ph, bitsPerComponent: 8,
                                  bytesPerRow: 0, space: cs,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            return NSImage(size: NSSize(width: w, height: h))
        }
        ctx.scaleBy(x: scale, y: scale)
        ctx.setShouldAntialias(true)
        ctx.setAllowsAntialiasing(true)

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
        paint(size: NSSize(width: w, height: h), folder: folder, folderW: folderW, dots: ds)
        NSGraphicsContext.restoreGraphicsState()

        let img: NSImage
        if let cg = ctx.makeImage() {
            img = NSImage(size: NSSize(width: w, height: h))
            img.addRepresentation(NSBitmapImageRep(cgImage: cg))
        } else {
            img = NSImage(size: NSSize(width: w, height: h))
        }
        img.isTemplate = false          // 关键：保留彩色
        return img
    }

    /* 画在点坐标系里，原点在左下角（AppKit 习惯） */
    private static func paint(size: NSSize, folder: NSAttributedString, folderW: CGFloat, dots: [Dot]) {
        let w = size.width, h = size.height

        // ① 细圆角框（半像素内缩，1pt 线正好压住像素中心）
        let stroke = darkMode()
            ? NSColor(white: 1, alpha: 0.42)
            : NSColor(white: 0, alpha: 0.26)
        let box = CGRect(x: 0.5, y: 0.5, width: w - 1, height: h - 1)
        let path = CGPath(roundedRect: box, cornerWidth: boxRadius, cornerHeight: boxRadius, transform: nil)
        stroke.setStroke()
        let p = NSBezierPath(cgPath: path)
        p.lineWidth = 1
        p.stroke()

        // ② 📂
        let fs = folder.size()
        folder.draw(at: NSPoint(x: padX + (folderW - fs.width) / 2, y: (h - fs.height) / 2))

        // ③ 圆点 + 数字
        var x = padX + folderW + (dots.isEmpty ? 0 : gapFolderDots)
        for d in dots {
            let n = d.n
            let cy = h / 2
            d.color.setFill()
            NSBezierPath(ovalIn: CGRect(x: x, y: cy - dotD / 2, width: dotD, height: dotD)).fill()

            var size: CGFloat = 9.5
            var attr = number("\(n)", size: size, color: d.text)
            while attr.size().width > dotD - 3.6 && size > 6 {
                size -= 0.5
                attr = number("\(n)", size: size, color: d.text)
            }
            let ts = attr.size()
            attr.draw(at: NSPoint(x: x + (dotD - ts.width) / 2, y: cy - ts.height / 2))
            x += dotD + dotGap
        }
    }

    private static func number(_ s: String, size: CGFloat, color: NSColor) -> NSAttributedString {
        NSAttributedString(string: s, attributes: [
            .font: NSFont.systemFont(ofSize: size, weight: .bold),
            .foregroundColor: color,
        ])
    }

    /// 菜单栏在深色模式下底子是暗的，框线要跟着反过来
    static func darkMode() -> Bool {
        (UserDefaults.standard.string(forKey: "AppleInterfaceStyle") ?? "")
            .lowercased().contains("dark")
    }
}
