import Foundation
import CoreGraphics
import ImageIO

// 课表预览辅助工具（零依赖，只用系统 CoreGraphics / ImageIO）
//   pdfscale <src.pdf> <dst.pdf> <scale>     PDF 按比例整体缩放（矢量无损）
//   pdfscale --png <src.pdf> <dst.png> <宽> [dpi]
//       第一页渲染成 PNG。<宽>是像素宽；dpi 决定「点尺寸」＝像素/dpi*72，
//       而「预览」是按点尺寸开窗口的 → 高像素+高 dpi = 中号窗口 + Retina 清晰度。
//   pdfscale --screen                         主屏逻辑尺寸，如 1470x956
//   pdfscale --pagesize <file.pdf>            第一页尺寸，如 841.89x595.28

func fail(_ m: String) -> Never {
    FileHandle.standardError.write((m + "\n").data(using: .utf8)!)
    exit(1)
}

let args = CommandLine.arguments
if args.count >= 2 && args[1] == "--screen" {
    let b = CGDisplayBounds(CGMainDisplayID())
    print("\(Int(b.size.width))x\(Int(b.size.height))")
    exit(0)
}
if args.count >= 3 && args[1] == "--pagesize" {
    guard let doc = CGPDFDocument(URL(fileURLWithPath: args[2]) as CFURL) else { fail("cannot open pdf") }
    guard doc.numberOfPages > 0, let p = doc.page(at: 1) else { fail("no page") }
    let r = p.getBoxRect(.mediaBox)
    print("\(r.width)x\(r.height)")
    exit(0)
}
if args.count >= 5 && args[1] == "--png" {
    let w = Int(Double(args[4]) ?? 0)
    let dpi = args.count >= 6 ? (Double(args[5]) ?? 0) : 0
    guard w > 0 else { fail("bad width") }
    guard let doc = CGPDFDocument(URL(fileURLWithPath: args[2]) as CFURL) else { fail("cannot open src") }
    guard doc.numberOfPages > 0, let page = doc.page(at: 1) else { fail("no page") }
    let r = page.getBoxRect(.mediaBox)
    let h = Int((CGFloat(w) * r.height / r.width).rounded())
    let cs = CGColorSpaceCreateDeviceRGB()
    guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8,
                              bytesPerRow: 0, space: cs,
                              bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else {
        fail("cannot create bitmap")
    }
    ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
    ctx.fill(CGRect(x: 0, y: 0, width: CGFloat(w), height: CGFloat(h)))
    let s = CGFloat(w) / r.width
    ctx.scaleBy(x: s, y: s)
    ctx.drawPDFPage(page)
    guard let img = ctx.makeImage() else { fail("cannot make image") }
    guard let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: args[3]) as CFURL,
                                                     "public.png" as CFString, 1, nil) else {
        fail("cannot write png")
    }
    var props: [CFString: Any] = [:]
    if dpi > 0 {
        props[kCGImagePropertyDPIWidth] = dpi
        props[kCGImagePropertyDPIHeight] = dpi
    }
    CGImageDestinationAddImage(dest, img, props.isEmpty ? nil : (props as CFDictionary))
    guard CGImageDestinationFinalize(dest) else { fail("finalize failed") }
    print("ok \(w)x\(h) @\(dpi > 0 ? Int(dpi) : 72)dpi")
    exit(0)
}
guard args.count >= 4 else { fail("usage: pdfscale src dst scale | --png src dst width [dpi] | --screen | --pagesize file") }
let scale = CGFloat(Double(args[3]) ?? 1.0)
guard scale > 0 else { fail("bad scale") }

guard let doc = CGPDFDocument(URL(fileURLWithPath: args[1]) as CFURL) else { fail("cannot open src") }
var box = CGRect(x: 0, y: 0, width: 800, height: 600)
guard let ctx = CGContext(URL(fileURLWithPath: args[2]) as CFURL, mediaBox: &box, nil) else {
    fail("cannot create dst")
}
for i in 1...doc.numberOfPages {
    guard let page = doc.page(at: i) else { continue }
    let r = page.getBoxRect(.mediaBox)
    var mb = CGRect(x: 0, y: 0, width: r.width * scale, height: r.height * scale)
    let info = [kCGPDFContextMediaBox as String: NSData(bytes: &mb, length: MemoryLayout<CGRect>.size)] as CFDictionary
    ctx.beginPDFPage(info)
    ctx.saveGState()
    ctx.scaleBy(x: scale, y: scale)
    ctx.drawPDFPage(page)
    ctx.restoreGState()
    ctx.endPDFPage()
}
ctx.closePDF()
print("ok pages=\(doc.numberOfPages) scale=\(scale)")
