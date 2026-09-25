import SwiftUI
import AppKit
import WebKit

/* ======================================================================
   跳转网页的行为（用户要求：App 里所有跳转网页相关的地方都能在设置里配）

   三种方式：
     · system  系统默认浏览器（默认）
     · builtin App 内置浏览窗（带地址栏、前进后退，不打断看板）
     · copy    只把链接拷到剪贴板，方便粘到别处
   可以全局设一种，也可以按来源覆盖（ManageBac / Teams / EC / 希悦 / 成绩 …）。
   ====================================================================== */

enum LinkMode: String, CaseIterable, Identifiable {
    case system, builtin, copy
    var id: String { rawValue }
    var label: String {
        switch self {
        case .system:  return "系统浏览器"
        case .builtin: return "内置窗口"
        case .copy:    return "复制链接"
        }
    }
    var icon: String {
        switch self {
        case .system:  return "safari"
        case .builtin: return "macwindow"
        case .copy:    return "doc.on.doc"
        }
    }
    var hint: String {
        switch self {
        case .system:  return "用 Safari / 默认浏览器打开，登录态共用，最省事"
        case .builtin: return "在看板里开一个小窗看，不切换应用"
        case .copy:    return "不打开，只把地址复制到剪贴板"
        }
    }
}

/// 可单独设来源的列表（设置页按这些 key 生成覆盖项）
struct LinkSource: Identifiable {
    let id: String
    let label: String
    let icon: String
    /// 设置页上给用户看的示例，说明这一类链接大概长什么样
    let sample: String

    static let all: [LinkSource] = [
        .init(id: "managebac", label: "ManageBac 作业 / 成绩", icon: "graduationcap.fill",
              sample: "managebac.cn / 作业详情页"),
        .init(id: "teams",     label: "Teams 任务与消息",     icon: Icons.teams,
              sample: "teams.microsoft.com / 频道帖子"),
        .init(id: "ec",        label: "English Corner 名单",  icon: "person.2.fill",
              sample: "SharePoint 上的 EC Roster PDF"),
        .init(id: "seiue",     label: "希悦课表",             icon: "calendar.badge.clock",
              sample: "yly.seiue.com / 课表"),
        .init(id: "mail",      label: "邮件",                 icon: "envelope.fill",
              sample: "Outlook 中的邮件"),
    ]
}

enum LinkOpen {

    @MainActor
    static func go(_ url: URL, source: String, settings: BoardSettings) {
        switch LinkMode(rawValue: settings.linkMode(source)) ?? .system {
        case .system:
            NSWorkspace.shared.open(url)
        case .builtin:
            InAppBrowser.shared.show(url)
        case .copy:
            let pb = NSPasteboard.general
            pb.clearContents()
            pb.setString(url.absoluteString, forType: .string)
            HUD.flash("链接已复制")
        }
    }

    /// 便利重载：只有字符串 URL 时用
    @MainActor
    static func go(_ raw: String?, source: String, settings: BoardSettings) {
        guard let raw, !raw.isEmpty, let u = URL(string: raw) else { return }
        go(u, source: source, settings: settings)
    }
}

/* ---------------- EC 名单 ----------------
   预下载后本地就有一份 PDF，点「看名单」应当秒开，而不是每次都去 SharePoint。
   所以这里优先本地文件，拿不到才回落到网页链接（并且按设置里的跳转方式走）。 */

@MainActor
enum ECRoster {
    static func url(_ info: TeamsEC?) -> URL? {
        guard let info else { return nil }
        if let p = info.localPath, !p.isEmpty, FileManager.default.fileExists(atPath: p) {
            return URL(fileURLWithPath: p)
        }
        if let w = info.webUrl, !w.isEmpty, let u = URL(string: w) { return u }
        return nil
    }

    static func open(_ info: TeamsEC?, settings: BoardSettings) {
        guard let u = url(info) else { return }
        if u.isFileURL {
            NSWorkspace.shared.open(u)
        } else {
            LinkOpen.go(u, source: "ec", settings: settings)
        }
    }

    /// 本地是否已经有那份 PDF
    static func isLocal(_ info: TeamsEC?) -> Bool { url(info)?.isFileURL == true }
}

/* ---------------- 原生液态玻璃外壳（AppKit 侧） ----------------

   上面 `LiquidGlassPanel` 管的是 SwiftUI 浮层；这里是给**独立窗口**用的版本。

   为什么不用同一个：SwiftUI 的 `.glassEffect` 只能折射同一个窗口里的内容。
   InAppBrowser / HUD 这类有自己的 NSWindow，玻璃必须由 AppKit 来提供 ——
   也就是 macOS 26 的原生 `NSGlassEffectView`。
   `style = .clear` 就是 WWDC25 那档「完全透明、只有折射、不带任何填色」的玻璃。

   结构（和 SwiftUI 版一一对应）：
     NSGlassEffectView(.clear)   ← 外圈：液态玻璃描边
       └ 毛玻璃主体（缩进 border，把中间的玻璃盖掉）
         └ 内容
   ====================================================================== */

@MainActor
enum GlassShell {

    /// 把 SwiftUI 内容包成「液态玻璃描边 + 毛玻璃主体」，可直接当 window.contentView。
    static func wrap<V: View>(_ content: V, corner: CGFloat, border: CGFloat = 7) -> NSView {
        let glass = NSGlassEffectView()
        glass.style = .clear                    // ★ 全透明 / 纯折射 / 零填色 ★
        glass.cornerRadius = corner
        glass.wantsLayer = true

        let host = NSHostingView(rootView: Inner(content: content,
                                                  corner: corner,
                                                  border: border))
        host.translatesAutoresizingMaskIntoConstraints = false
        host.wantsLayer = true
        host.layer?.backgroundColor = .clear    // 自己不能有一层底色，否则盖掉玻璃

        glass.contentView = host
        if let cv = glass.contentView {
            cv.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                cv.leadingAnchor.constraint(equalTo: glass.leadingAnchor),
                cv.trailingAnchor.constraint(equalTo: glass.trailingAnchor),
                cv.topAnchor.constraint(equalTo: glass.topAnchor),
                cv.bottomAnchor.constraint(equalTo: glass.bottomAnchor),
            ])
        }
        return glass
    }

    /// 供程序化窗口使用的便利版：直接把窗口的门面换成玻璃壳。
    /// 必须同时把窗口设成非不透明，否则玻璃底下是不透明的窗口底，折射不出来。
    static func apply<V: View>(to window: NSWindow, corner: CGFloat, content: V,
                               border: CGFloat = 7) {
        window.isOpaque = false
        window.backgroundColor = .clear
        window.contentView = wrap(content, corner: corner, border: border)
    }

    private struct Inner<C: View>: View {
        let content: C
        let corner: CGFloat
        let border: CGFloat
        @Environment(\.colorScheme) private var scheme

        var body: some View {
            let ri = max(6, corner - border)
            ZStack {
                // 内圈：毛玻璃主体 —— 用户要的「不太透底下颜色」，
                // thickMaterial + 高不透明度主题底，两层叠上去正文才稳。
                RoundedRectangle(cornerRadius: ri, style: .continuous)
                    .fill(.thickMaterial)
                    .padding(border)
                RoundedRectangle(cornerRadius: ri, style: .continuous)
                    .fill(Theme.cardFill(scheme, strength: 1).opacity(0.94))
                    .padding(border)
                content
                    .padding(border)
            }
            // 玻璃厚度：上边一道亮线、下边淡出。不是填色，是描边。
            .overlay {
                RoundedRectangle(cornerRadius: corner, style: .continuous)
                    .strokeBorder(
                        LinearGradient(
                            colors: scheme == .dark
                                ? [Color.white.opacity(0.30), Color.white.opacity(0.05)]
                                : [Color.white.opacity(0.90), Color.white.opacity(0.26)],
                            startPoint: .top, endPoint: .bottom),
                        lineWidth: 0.9)
                    .allowsHitTesting(false)
            }
        }
    }
}

/* ---------------- 内置浏览窗 ---------------- */

@MainActor
final class InAppBrowser: NSObject, WKNavigationDelegate, NSWindowDelegate {
    static let shared = InAppBrowser()

    private var window: NSWindow?
    private var web: WKWebView?
    private var bar: NSTextField?
    private var spinner: NSProgressIndicator?
    private var back: NSButton?
    private var fwd: NSButton?

    func show(_ url: URL) {
        if window == nil { build() }
        guard let w = window, let web else { return }
        bar?.stringValue = url.absoluteString
        web.load(URLRequest(url: url))
        w.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func build() {
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1040, height: 720),
                         styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                         backing: .buffered, defer: false)
        w.title = "内置浏览窗"
        w.titlebarAppearsTransparent = true
        w.isReleasedWhenClosed = false
        w.delegate = self
        w.center()

        let root = NSView()

        let barView = NSView()
        barView.translatesAutoresizingMaskIntoConstraints = false

        func tool(_ sym: String, _ sel: Selector) -> NSButton {
            let b = NSButton(image: NSImage(systemSymbolName: sym, accessibilityDescription: nil) ?? NSImage(),
                             target: self, action: sel)
            b.isBordered = false
            b.bezelStyle = .regularSquare
            b.imageScaling = .scaleProportionallyDown
            b.translatesAutoresizingMaskIntoConstraints = false
            b.widthAnchor.constraint(equalToConstant: 26).isActive = true
            return b
        }
        let bBack = tool("chevron.left", #selector(goBack))
        let bFwd  = tool("chevron.right", #selector(goForward))
        let bOpen = tool("arrow.up.forward.app", #selector(openExternal))
        let bCopy = tool("doc.on.doc", #selector(copyLink))
        back = bBack; fwd = bFwd

        let field = NSTextField()
        field.isBezeled = true
        field.bezelStyle = .roundedBezel
        field.font = .systemFont(ofSize: 12)
        field.translatesAutoresizingMaskIntoConstraints = false
        field.target = self
        field.action = #selector(barSubmit)
        bar = field

        let sp = NSProgressIndicator()
        sp.style = .spinning
        sp.controlSize = .small
        sp.isDisplayedWhenStopped = false
        sp.translatesAutoresizingMaskIntoConstraints = false
        spinner = sp

        for v in [bBack, bFwd, bOpen, bCopy, field, sp] { barView.addSubview(v) }
        barView.addSubview(sp)

        let cfg = WKWebViewConfiguration()
        cfg.websiteDataStore = .default()          // 与系统浏览器共用一套 cookie，登录态能沿用
        let web = WKWebView(frame: .zero, configuration: cfg)
        web.translatesAutoresizingMaskIntoConstraints = false
        web.navigationDelegate = self
        web.allowsBackForwardNavigationGestures = true
        self.web = web

        root.addSubview(barView)
        root.addSubview(web)

        NSLayoutConstraint.activate([
            barView.topAnchor.constraint(equalTo: root.topAnchor, constant: 30),
            barView.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 12),
            barView.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -12),
            barView.heightAnchor.constraint(equalToConstant: 28),

            bBack.leadingAnchor.constraint(equalTo: barView.leadingAnchor),
            bBack.centerYAnchor.constraint(equalTo: barView.centerYAnchor),
            bFwd.leadingAnchor.constraint(equalTo: bBack.trailingAnchor, constant: 4),
            bFwd.centerYAnchor.constraint(equalTo: barView.centerYAnchor),

            field.leadingAnchor.constraint(equalTo: bFwd.trailingAnchor, constant: 8),
            field.centerYAnchor.constraint(equalTo: barView.centerYAnchor),
            field.heightAnchor.constraint(equalToConstant: 24),

            sp.leadingAnchor.constraint(equalTo: field.trailingAnchor, constant: 6),
            sp.centerYAnchor.constraint(equalTo: barView.centerYAnchor),

            bCopy.leadingAnchor.constraint(equalTo: sp.trailingAnchor, constant: 6),
            bCopy.centerYAnchor.constraint(equalTo: barView.centerYAnchor),
            bOpen.leadingAnchor.constraint(equalTo: bCopy.trailingAnchor, constant: 4),
            bOpen.centerYAnchor.constraint(equalTo: barView.centerYAnchor),
            bOpen.trailingAnchor.constraint(equalTo: barView.trailingAnchor),

            web.topAnchor.constraint(equalTo: barView.bottomAnchor, constant: 8),
            web.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            web.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            web.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])

        // 窗口门面：外圈原生液态玻璃（NSGlassEffectView .clear：零填色、纯折射），
        // 内圈毛玻璃主体 —— 内容和上面搭好的工具条 + 网页一模一样，只是外面
        // 多了一层玻璃描边。用户要求「所有弹出的框都加液态玻璃描边」。
        // ⚠️ 必须同时把窗口设成非不透明：不然玻璃底下是一层不透明的窗口底，
        //    折射不出来，看着就是一块死灰。
        w.isOpaque = false
        w.backgroundColor = .clear
        w.contentView = GlassShell.wrap(
            AppKitHost(view: root).frame(maxWidth: .infinity, maxHeight: .infinity),
            corner: 20, border: 6)

        window = w
    }

    @objc private func goBack() { web?.goBack() }
    @objc private func goForward() { web?.goForward() }
    @objc private func openExternal() {
        if let u = web?.url { NSWorkspace.shared.open(u) }
    }
    @objc private func copyLink() {
        if let u = web?.url {
            let pb = NSPasteboard.general
            pb.clearContents(); pb.setString(u.absoluteString, forType: .string)
            HUD.flash("链接已复制")
        }
    }
    @objc private func barSubmit() {
        guard var s = bar?.stringValue.trimmingCharacters(in: .whitespaces), !s.isEmpty else { return }
        if !s.contains("://") { s = "https://" + s }
        if let u = URL(string: s) { web?.load(URLRequest(url: u)) }
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        spinner?.startAnimation(nil)
    }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        spinner?.stopAnimation(nil)
        if let u = webView.url { bar?.stringValue = u.absoluteString }
        back?.isEnabled = webView.canGoBack
        fwd?.isEnabled = webView.canGoForward
    }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        spinner?.stopAnimation(nil)
    }
}

/// 把已经搭好的 AppKit 视图树（工具条 + WKWebView）搬进 SwiftUI，
/// 好让它能套上 `GlassShell` 那层液态玻璃外壳。
/// 用 NSViewRepresentable 而不是把网页改用 SwiftUI 重写：网页引擎必须是
/// 真 NSView，重写反而会把它关进一个更别扭的容器里。
private struct AppKitHost: NSViewRepresentable {
    let view: NSView
    func makeNSView(context: Context) -> NSView {
        view.removeFromSuperview()      // 保证只有一个父视图
        return view
    }
    func updateNSView(_ nsView: NSView, context: Context) {}
}

/* ---------------- 一闪而过的提示 ---------------- */
@MainActor
enum HUD {
    private static var panel: NSPanel?

    static func flash(_ text: String, symbol: String? = nil) {
        panel?.close()
        // 一闪而过的提示也用同一套外壳：外圈原生液态玻璃描边、内圈毛玻璃。
        // 尺寸要把描边那圈算进去，不然文字会贴到玻璃边上。
        let host = GlassShell.wrap(HUDView(text: text, symbol: symbol),
                                   corner: 16, border: 6)
        host.frame = NSRect(x: 0, y: 0, width: 272, height: 68)

        let p = NSPanel(contentRect: host.frame,
                        styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.level = .floating
        p.ignoresMouseEvents = true
        p.hasShadow = false
        p.contentView = host

        if let screen = NSScreen.main {
            let f = screen.visibleFrame
            p.setFrameOrigin(NSPoint(x: f.midX - 136, y: f.maxY - 136))
        }
        p.alphaValue = 0
        p.orderFront(nil)
        panel = p

        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.16
            p.animator().alphaValue = 1
        } completionHandler: {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.35) {
                NSAnimationContext.runAnimationGroup { ctx in
                    ctx.duration = 0.28
                    p.animator().alphaValue = 0
                } completionHandler: {
                    // 这里必须显式回主线程：`panel` 是 @MainActor 上的静态属性，
                    // 而 NSAnimationContext 的 completionHandler 并没有被编译器
                    // 保证在主线程调用（严格并发下这就是一个数据竞争）。
                    // 外面那层 DispatchQueue.main 只管到动画的启动，管不到这里。
                    DispatchQueue.main.async {
                        p.close()
                        if panel === p { panel = nil }
                    }
                }
            }
        }
    }
}

private struct HUDView: View {
    let text: String
    var symbol: String?
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: symbol ?? "checkmark.circle.fill")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Theme.accentText(scheme))
            Text(text)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Theme.ink(scheme))
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
        // 底色现在由 GlassShell（外圈液态玻璃 + 内圈毛玻璃）提供，
        // 这里只留一点极其克制的边光，让文字在任何背景上都跳出来。
        .shadow(color: .black.opacity(0.28), radius: 4, y: 1)
        .fixedSize()
    }
}
