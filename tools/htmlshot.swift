/* ======================================================================
   htmlshot —— 把本地 HTML 渲染成 PNG（macOS 原生 WebKit 版）

   为什么不用 Chrome headless：
     本机上 Chrome for Testing 一跑截图就被 SIGTERM 掉
     （GPU process exited unexpectedly: exit_code=6 / Failed to initialize sandbox），
     --disable-gpu、--no-sandbox、--headless=old 都试过，一律 137。
     而 WKWebView 走的是系统自带的 WebKit，不依赖外部二进制、不需要 GPU 进程，
     在受限环境里反而稳。

   用法：
     swiftc -O -o htmlshot htmlshot.swift
     ./htmlshot <input.html> <output.png> [width] [scale]

   width 默认 1240（CSS 像素），scale 默认 2（= Retina 2 倍图）。
   高度不用给 —— 渲染完先问一句 document 的真实高度，再按整页出图，
   免得手工试高度试到天亮。

   两个必须等的地方：
     ① didFinish 只代表 DOM 就绪，<img> 可能还在解码 —— 再等一小会；
     ② 用 evaluateJavaScript 量高度是异步的，回调里才能 resize，
        否则拿到的是初始 frame 高度（等于截断）。
   ====================================================================== */

import Cocoa
import WebKit

final class Shot: NSObject, WKNavigationDelegate {
    let web: WKWebView
    let out: URL
    let scale: CGFloat
    var width: CGFloat

    init(width: CGFloat, scale: CGFloat, out: URL, base: URL) {
        self.width = width
        self.scale = scale
        self.out = out
        let cfg = WKWebViewConfiguration()
        cfg.suppressesIncrementalRendering = false
        self.web = WKWebView(frame: NSRect(x: 0, y: 0, width: width, height: 100), configuration: cfg)
        super.init()
        self.web.navigationDelegate = self
    }

    func load(_ url: URL) {
        web.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        // 图片解码再给一点时间；本地文件很快，0.6s 足够
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) { self.measure() }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        FileHandle.standardError.write("load failed: \(error)\n".data(using: .utf8)!)
        exit(1)
    }

    func measure() {
        // ★ 关键：先把 frame 高度塌到最小再量 ★
        //   document.scrollHeight 至少等于 viewport 高度 —— viewport 是 600 时，
        //   一个只有 220px 高的下载横幅也会被量成 600，出来的图下方一大片空白。
        //   （踩过：guide.html 因为本身就超过 600 所以没暴露，download.html 一量就现形。）
        //   塌成 60 之后，量出来的就纯粹是内容高度了。
        web.frame = NSRect(x: 0, y: 0, width: width, height: 60)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            let js = "Math.max(document.body.scrollHeight, document.documentElement.scrollHeight,"
                   + " document.body.getBoundingClientRect().height)"
            self.web.evaluateJavaScript(js) { v, _ in
                var h: CGFloat = 600
                if let n = v as? NSNumber { h = CGFloat(truncating: n) }
                self.shoot(height: ceil(h))
            }
        }
    }

    func shoot(height: CGFloat) {
        // 高度设成整页，宽度锁死 —— 布局不会被窗口尺寸带偏
        web.frame = NSRect(x: 0, y: 0, width: width, height: height)
        // 布局需要一次 runloop 才生效，量完直接拍会拍到旧高度
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            let cfg = WKSnapshotConfiguration()
            cfg.rect = NSRect(x: 0, y: 0, width: self.width, height: height)
            // snapshotWidth 是「成图宽度」，单位是**点**；真正的像素数还要再乘屏幕的
            // backingScaleFactor（Retina 上是 2）。所以想拿 2 倍图，这里要填 CSS 宽本身。
            // 踩过两次坑：填 scale(2) 得到 4×2 像素；填 width*scale 得到 4 倍图（4960px）。
            // 除以 backingScale 后不管接的是不是 Retina 屏，出来的像素数都锁定为 width*scale。
            let backing = self.web.window?.backingScaleFactor ?? 2
            cfg.snapshotWidth = NSNumber(value: Double(self.width * self.scale) / Double(backing))
            self.web.takeSnapshot(with: cfg) { img, err in
                guard let img = img,
                      let tiff = img.tiffRepresentation,
                      let rep = NSBitmapImageRep(data: tiff),
                      let png = rep.representation(using: .png, properties: [:]) else {
                    FileHandle.standardError.write("snapshot failed: \(String(describing: err))\n".data(using: .utf8)!)
                    exit(2)
                }
                do {
                    try png.write(to: self.out)
                    print("✔ \(self.out.path)  \(Int(self.width))×\(Int(height)) @\(Int(self.scale))x")
                    print("  实际像素 \(rep.pixelsWide)×\(rep.pixelsHigh)")
                } catch {
                    FileHandle.standardError.write("write failed: \(error)\n".data(using: .utf8)!)
                    exit(3)
                }
                exit(0)
            }
        }
    }
}

let args = CommandLine.arguments
guard args.count >= 3 else {
    print("用法: htmlshot <input.html> <output.png> [width] [scale]")
    exit(64)
}
let inURL = URL(fileURLWithPath: args[1])
let outURL = URL(fileURLWithPath: args[2])
let w = args.count > 3 ? CGFloat(Double(args[3]) ?? 1240) : 1240
let s = args.count > 4 ? CGFloat(Double(args[4]) ?? 2) : 2

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
// 离屏窗口：WKWebView 放进窗口里渲染结果最接近真机
let win = NSWindow(contentRect: NSRect(x: -4000, y: -4000, width: w, height: 600),
                   styleMask: [.borderless], backing: .buffered, defer: false)
let shot = Shot(width: w, scale: s, out: outURL, base: inURL.deletingLastPathComponent())
win.contentView = shot.web
win.orderBack(nil)
shot.load(inURL)
app.run()
