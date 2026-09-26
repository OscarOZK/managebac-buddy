import AppKit
import WebKit

/* ======================================================================
   内置网页引擎 —— 让「登录」这件事不再依赖别人电脑上装没装浏览器
   ======================================================================

   为什么非做不可
   --------------
   看板的四个集成里，有三个必须有一个**真浏览器**才能登进去：

       ManageBac  自动化填表登录、读登录后的页面、导出时下载文件
       Teams      用户在窗口里登录 → 从 localStorage 取 Graph 令牌
       希悦        用户在窗口里登录、点「导出课表」、把 xlsx 收下来

   以前这三个都靠 CDP 驱动一个**外部的 Chromium**（agent-browser 或
   Chrome for Testing）。实测后果是这样的：作者这台开发机全盘扫不到任何
   Chromium，朋友的机器同样没有。于是四条链路里唯一能用的那个（DeepSeek）
   恰好是唯一不需要浏览器的。

   中间试过「没有就自动下一份 Chrome for Testing」，但那要等 150MB，
   国内还经常只有镜像能通 —— 用户看到的是「一直卡在准备浏览器」。
   而 macOS 自带 Safari 的 WebKit，**一个字节都不用下**。

   所以：把浏览器搬进 App 自己身体里。

   怎么和 Python 那边对接
   ----------------------
   不新增协议、不新开端口。Swift 本来就在轮询 bridge.py 的 8765
   （数据、状态、通知都走它），现在反过来再用同一条通道下发「浏览器指令」：

       Swift  →  GET  /api/webengine/poll     长轮询取一条指令
       Python →  把指令塞进队列，等结果
       Swift  →  POST /api/webengine/result   回传结果

   bridge.py 是 ThreadingTCPServer，Swift 的轮询和 Python 的等待各占一条
   连接，互不阻塞。好处是：整套东西能用 curl 手测，出问题一眼看得见；
   而且 Python 侧不关心引擎是 WebKit 还是 Chromium，换引擎不用改业务代码。

   关于「隐藏」的那点讲究
   ----------------------
   WebKit 会用「窗口在不在屏幕上」来决定要不要给页面的定时器降频。
   把窗口 orderOut 掉确实看不见了，但页面里的 setTimeout 会被压到 1 秒
   一次 —— Teams 这种 SPA 的登录流程会慢到让人以为卡死。
   所以隐藏态不是「藏窗口」，而是 **alphaValue = 0**：
   窗口仍然在屏幕上、WebKit 认为它可见、定时器照常跑，
   但用户看不见、也点不到（ignoresMouseEvents）。
   ====================================================================== */

/// 指令执行结果
struct WEResult {
    var ok: Bool
    var value: Any?
    var error: String

    static func good(_ v: Any? = nil) -> WEResult { WEResult(ok: true, value: v, error: "") }
    static func bad(_ e: String) -> WEResult { WEResult(ok: false, value: nil, error: e) }
}

/// 允许按调用方给的坐标原样摆放的窗口（标准 NSWindow 会把 frame 拽回屏幕里）
final class WEWebWindow: NSWindow {
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        frameRect
    }
}

/// 一个标签页
final class WETab {
    let id: String
    let web: WKWebView
    var lastURL: String = ""
    var lastError: String = ""

    init(id: String, web: WKWebView) {
        self.id = id
        self.web = web
    }
}

/* ======================================================================
   引擎本体
   ====================================================================== */

final class WebEngine: NSObject, WKNavigationDelegate, WKUIDelegate, WKDownloadDelegate,
                       NSWindowDelegate {

    static let shared = WebEngine()

    /// 引擎是否已经初始化过
    private(set) var started = false

    private var config: WKWebViewConfiguration?
    private var window: WEWebWindow?
    private var tabs: [WETab] = []
    private var activeID: String = ""
    private var seq = 0

    /// 下载落点（希悦导出课表等）
    private var downloadDir: String = ""
    private var hidden = true

    private static let frameSize = NSSize(width: 1280, height: 900)

    // ---------------------------------------------------------------- 启动

    /// 建好配置和第一个标签页。必须在主线程调用。
    func start() {
        if started { return }
        started = true

        let c = WKWebViewConfiguration()
        // 持久化数据存储：cookies / localStorage 跨启动保留，
        // 这正是「登录一次之后一直有效」的基础。
        c.websiteDataStore = WKWebsiteDataStore.default()
        c.preferences.javaScriptCanOpenWindowsAutomatically = true
        config = c

        buildWindow()
        _ = newTab(configuration: c)
        hide()

        NSLog("[webengine] 内置引擎已就绪（WebKit %@）", Self.safariVersion())
    }

    /// 让 UA 尽量贴近真实 Safari。
    ///
    /// ★ 不能什么都不设 ★ WKWebView 默认 UA 只有
    ///   `... AppleWebKit/605.1.15 (KHTML, like Gecko)`，
    ///   末尾**没有** `Version/x Safari/605.1.15`。不少站点（含微软几个登录域）
    ///   会 sniff 这一段来判断「是不是真 Safari」，缺了就当成不支持的浏览器。
    static func safariUserAgent() -> String {
        let os = ProcessInfo.processInfo.operatingSystemVersion
        let osTag = "\(os.majorVersion)_\(os.minorVersion)"
        return "Mozilla/5.0 (Macintosh; Intel Mac OS X \(osTag)) "
             + "AppleWebKit/605.1.15 (KHTML, like Gecko) "
             + "Version/\(safariVersion()) Safari/605.1.15"
    }

    /// 问系统要 Safari 的版本号（拿不到就给个合理默认）
    static func safariVersion() -> String {
        let p = "/Applications/Safari.app/Contents/Info.plist"
        if let d = NSDictionary(contentsOfFile: p),
           let v = d["CFBundleShortVersionString"] as? String, !v.isEmpty {
            return v
        }
        return "18.0"
    }

    private func buildWindow() {
        let r = NSRect(x: 0, y: 0, width: Self.frameSize.width, height: Self.frameSize.height)
        let w = WEWebWindow(contentRect: r,
                            styleMask: [.titled, .closable, .resizable, .miniaturizable],
                            backing: .buffered, defer: false)
        w.title = "登录"
        w.isReleasedWhenClosed = false        // 关窗口不能把对象也放掉
        w.hidesOnDeactivate = false
        w.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        w.tabbingMode = .disallowed
        w.delegate = self
        w.contentView = NSView(frame: r)
        window = w
    }

    /// 用户在登录窗口上按 ⌘W：不要真把窗口关掉（关掉就再也没法用它登录了），
    /// 收起来即可 —— 下次需要时 show() 还能原样搬回来。
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        hide()
        return false
    }

    // ------------------------------------------------------------ 标签页

    @discardableResult
    private func newTab(configuration: WKWebViewConfiguration? = nil) -> WETab {
        seq += 1
        let id = "w\(seq)"
        let web = WKWebView(frame: NSRect(origin: .zero, size: Self.frameSize),
                            configuration: configuration ?? config ?? WKWebViewConfiguration())
        web.navigationDelegate = self
        web.uiDelegate = self
        web.allowsBackForwardNavigationGestures = false
        web.customUserAgent = Self.safariUserAgent()
        web.autoresizingMask = [.width, .height]

        let t = WETab(id: id, web: web)
        tabs.append(t)
        window?.contentView?.addSubview(web)
        web.frame = window?.contentView?.bounds ?? NSRect(origin: .zero, size: Self.frameSize)
        activeID = id
        relayout()
        return t
    }

    /// 只显示 activeID 那个标签页
    private func relayout() {
        guard let host = window?.contentView else { return }
        for t in tabs {
            t.web.frame = host.bounds
            t.web.isHidden = (t.id != activeID)
        }
    }

    private func tab(_ id: String?) -> WETab? {
        if let id, let t = tabs.first(where: { $0.id == id }) { return t }
        if activeID.isEmpty { return tabs.first }
        return tabs.first(where: { $0.id == activeID }) ?? tabs.first
    }

    private func tabInfo(_ t: WETab) -> [String: Any] {
        ["id": t.id,
         "url": t.lastURL.isEmpty ? (t.web.url?.absoluteString ?? "") : t.lastURL,
         "title": t.web.title ?? "",
         "active": t.id == activeID,
         "error": t.lastError]
    }

    // ------------------------------------------------------------ 显示控制

    func hide() {
        guard let w = window else { return }
        hidden = true
        w.alphaValue = 0
        w.ignoresMouseEvents = true
        if let s = NSScreen.main {
            let x = max(s.visibleFrame.minX, s.visibleFrame.maxX - Self.frameSize.width - 16)
            let y = s.visibleFrame.minY + 16
            w.setFrameOrigin(NSPoint(x: x, y: y))
        }
        w.orderFront(nil)
    }

    func show(x: CGFloat?, y: CGFloat?, w width: CGFloat?, h height: CGFloat?,
              title: String?, id: String?) {
        guard let w = window else { return }
        if let id, let t = tab(id) { activeID = t.id; relayout() }
        hidden = false
        var f = w.frame
        if let width, width > 240 { f.size.width = width }
        if let height, height > 200 { f.size.height = height }
        if let s = NSScreen.main {
            f.origin.x = x ?? (s.visibleFrame.midX - f.size.width / 2)
            f.origin.y = y ?? (s.visibleFrame.midY - f.size.height / 2)
        }
        w.setFrame(f, display: true)
        if let title { w.title = title }
        w.alphaValue = 1
        w.ignoresMouseEvents = false
        w.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    // ------------------------------------------------------------ 指令入口

    /// 执行一条指令。**结果通过 done 回调交回，绝不阻塞主队列。**
    ///
    /// ★★ 这里为什么必须是异步的（血泪教训）★★
    ///
    /// 原先的写法是「后台线程 → DispatchQueue.main.async → 在 block 里
    /// 同步等 WebKit 回调 → 后台线程拿结果」。看起来天经地义，实际是死锁：
    ///
    ///   · WKWebView 的回调（evaluateJavaScript / httpCookieStore / removeData）
    ///     要**回主队列**才能投递；
    ///   · 我们那个 block 正占着主队列不放（它在等回调）—— 典型自我等待；
    ///   · 更要命的是 WebKit 内部还有一条线：
    ///       com.apple.WebKit.ServicesController → refreshExistingServices
    ///         → dispatch_sync(main queue) → 等主队列排空
    ///     它也在等主队列。
    ///   · 而 libdispatch **禁止主队列重入排空**：主队列正跑着 block 时，
    ///     就算你在这中间去转 NSRunLoop，它也不会再排空新的 block
    ///     （栈上看到的就是 _dispatch_main_queue_drain.cold.6 那条冷路径）。
    ///
    ///   结果：主线程永远卡在 sem.wait 里 → 风火轮 → 只能强制退出。
    ///   踩坑时的 sample（2589 个采样点 100% 同一条链）：
    ///     main-thread → closure #1 in WebEngine.run → perform → evalSync
    ///       → OS_dispatch_semaphore.wait(wallTimeout:)
    ///   而 WebKit 那条线永远停在：
    ///     ServicesController::refreshExistingServices → output_sync
    ///       → __DISPATCH_WAIT_FOR_QUEUE__
    ///   触发条件低到离谱 —— App 一起来，后端就发第一条 eval，
    ///   于是**每台机器每次启动都必中**。
    ///
    ///   正解（就是现在这个形状）：
    ///     · 主线程上只做「发起」，做完**立刻返回**，主队列重新空闲；
    ///     · WebKit 的回调于是能正常回到主队列；
    ///     · 需要等结果的是**后台的通道线程**，它在自己线程上堵着毫无副作用。
    ///
    /// `done` 可能在本函数返回前就被调用（不需要等回调的指令），也可能之后。
    /// 保证恰好调用一次。
    func run(_ op: String, _ args: [String: Any], _ done: @escaping (WEResult) -> Void) {
        if Thread.isMainThread {
            perform(op, args, done)
            return
        }
        DispatchQueue.main.async { self.perform(op, args, done) }
    }

    /// 主线程入口：不需要等回调的指令当场 done，需要等的把 done 交给回调。
    private func perform(_ op: String, _ args: [String: Any],
                         _ done: @escaping (WEResult) -> Void) {
        if !started { start() }
        switch op {

        case "eval":
            guard let t = tab(args["id"] as? String) else {
                return done(.bad("没有可用的标签页"))
            }
            return evalAsync(t, (args["js"] as? String) ?? "", done)

        case "cookies_get":
            return cookiesGet(args, done)

        case "cookies_set":
            return cookiesSet(args, done)

        case "clear_data":
            return clearData(done)

        default:
            done(syncPerform(op, args))
        }
    }

    /// 不需要等 WebKit 回调的指令：在主线程上算完直接给结果。
    private func syncPerform(_ op: String, _ args: [String: Any]) -> WEResult {
        switch op {

        case "ping":
            return .good(["ready": true, "tabs": tabs.count,
                          "webkit": Self.safariVersion()])

        case "open":
            let url = (args["url"] as? String) ?? ""
            guard !url.isEmpty, let u = URL(string: url), u.scheme != nil else {
                return .bad("网址为空或格式不对：\(url)")
            }
            let t: WETab
            if (args["new"] as? Bool) ?? false {
                t = newTab()
            } else if let want = args["id"] as? String,
                      let hit = tabs.first(where: { $0.id == want }) {
                t = hit
                activeID = t.id
                relayout()
            } else if let f = tabs.first {
                t = f
                activeID = t.id
                relayout()
            } else {
                t = newTab()
            }
            t.lastError = ""
            t.web.load(URLRequest(url: u, cachePolicy: .useProtocolCachePolicy,
                                  timeoutInterval: 45))
            return .good(["id": t.id, "url": url])

        case "tabs":
            return .good(["tabs": tabs.map { tabInfo($0) }, "active": activeID,
                          "count": tabs.count])

        case "state":
            return .good(["ready": started, "hidden": hidden, "tabs": tabs.count,
                          "active": activeID,
                          "urls": tabs.map { $0.lastURL }])

        case "close":
            if (args["all"] as? Bool) ?? false {
                for t in tabs { t.web.stopLoading(); t.web.removeFromSuperview() }
                tabs.removeAll()
                activeID = ""
                return .good(["closed": "all"])
            }
            guard let t = tab(args["id"] as? String) else { return .good(["closed": 0]) }
            t.web.stopLoading()
            t.web.removeFromSuperview()
            tabs.removeAll { $0.id == t.id }
            if activeID == t.id { activeID = tabs.first?.id ?? "" }
            relayout()
            return .good(["closed": 1])

        case "reload":
            guard let t = tab(args["id"] as? String) else { return .bad("没有可用的标签页") }
            t.web.reloadFromOrigin()
            return .good(["id": t.id])

        case "show":
            show(x: nil, y: nil, w: nil, h: nil,
                 title: args["title"] as? String, id: args["id"] as? String)
            return .good()

        case "hide":
            hide()
            return .good()

        case "geometry":
            // JSON 里数字都是 Double，CGFloat 要显式转一次
            func cg(_ k: String) -> CGFloat? {
                guard let d = args[k] as? Double else { return nil }
                return CGFloat(d)
            }
            show(x: cg("x"), y: cg("y"), w: cg("w"), h: cg("h"),
                 title: args["title"] as? String, id: args["id"] as? String)
            return .good()

        case "download_dir":
            downloadDir = (args["path"] as? String) ?? ""
            try? FileManager.default.createDirectory(
                atPath: downloadDir, withIntermediateDirectories: true)
            return .good(["path": downloadDir])

        case "click":
            guard let t = tab(args["id"] as? String) else { return .bad("没有可用的标签页") }
            return click(t, x: (args["x"] as? Double) ?? 0, y: (args["y"] as? Double) ?? 0)

        default:
            return .bad("不认识的指令：\(op)")
        }
    }

    // -------------------------------------------------------------- eval

    /// 跑一段页面 JS。**发起后立刻返回，结果走 done。**
    ///
    /// 绝不能在这里等 —— 见 `run(_:_:_:)` 上方那段说明：
    /// 回调要回主队列，而这里就跑在主队列上，等就是死锁。
    ///
    /// ★ 为什么用 callAsyncJavaScript 而不是 evaluateJavaScript ★
    ///
    ///   WebKit 的 `evaluateJavaScript` **不会等 Promise**：脚本返回一个
    ///   Promise 时，它拿到的就是那个 Promise 对象，而这个对象没法桥接给
    ///   ObjC —— 于是直接报错：
    ///       JavaScript execution returned a result of an unsupported type
    ///
    ///   而我们的抓取脚本 `scrape.js` 恰恰是 `(async () => { … })()`：
    ///   它内部要 `await fetch(...)` 把 ManageBac 各页面抓下来。
    ///   在 Chrome/CDP 那条路上这没事 —— agent-browser 的 Runtime.evaluate
    ///   默认带了 `awaitPromise`。换成 WebKit 后这个「默认等 Promise」就没了，
    ///   于是**每次抓取都 parse_error**（后台日志里那一串
    ///   「后台更新未成功：parse_error 页面 JS 出错：… unsupported type」）。
    ///
    ///   `callAsyncJavaScript` 是 WebKit 里**天生会等 Promise** 的那个 API，
    ///   正对 CDP 的 `awaitPromise: true`，所以改用它。
    ///
    ///   它的入参是「一个 async 函数的函数体」，所以我们把原脚本包成
    ///   `return await ( 原脚本 )`。这要求原脚本是**表达式或 IIFE** ——
    ///   我们发出去的 JS 全都是（`document.readyState`、
    ///   `JSON.stringify({…})`、`(function(){…})()`、`(async () => {…})()`），
    ///   唯一的例外是 `location.href="…"; 'go'` 这种**语句列表**。
    ///   语句列表塞进括号是语法错误 —— 而语法错误意味着这段脚本
    ///   **一个字都没执行**，所以此时回退到 `evaluateJavaScript`
    ///   （它能取到语句列表的完成值）重跑一次是安全的：
    ///   不会有副作用被重复执行。
    private func evalAsync(_ t: WETab, _ js: String,
                           _ done: @escaping (WEResult) -> Void) {
        t.web.callAsyncJavaScript("return await (\n\(js)\n)",
                                  arguments: [:], in: nil, in: .page) { result in
            switch result {
            case .success(let v):
                done(.good(Self.jsonSafe(v)))
            case .failure(let e):
                guard Self.isSyntaxError(e) else {
                    return done(.bad("页面 JS 出错：\(e.localizedDescription)"))
                }
                // 语法错误 = 没跑过，回退代价为零（见上面说明）。
                t.web.evaluateJavaScript(js) { value, err in
                    if let err {
                        done(.bad("页面 JS 出错：\(err.localizedDescription)"))
                    } else {
                        done(.good(Self.jsonSafe(value)))
                    }
                }
            }
        }
    }

    /// 是不是「语法错误」。用来判断该不该回退到 evaluateJavaScript。
    private static func isSyntaxError(_ e: Error) -> Bool {
        let ns = e as NSError
        if let m = ns.userInfo["WKJavaScriptExceptionMessage"] as? String,
           m.contains("SyntaxError") {
            return true
        }
        return ns.localizedDescription.contains("SyntaxError")
    }

    /// 把 evaluateJavaScript 的返回值转成 JSON 能编的形态。
    /// 我们的 JS 基本都 `JSON.stringify(...)` 过了，所以大多是字符串；
    /// 为了兼容直接返回对象的写法（CDP 的 returnByValue 就是这样），
    /// 这里也认数组 / 字典 / 数字 / 布尔。
    static func jsonSafe(_ v: Any?) -> Any? {
        guard let v else { return nil }
        switch v {
        case is String, is NSNumber, is NSNull: return v
        case let a as [Any]: return a.map { jsonSafe($0) ?? NSNull() }
        case let d as [String: Any]:
            var o: [String: Any] = [:]
            for (k, x) in d { o[k] = jsonSafe(x) ?? NSNull() }
            return o
        default:
            return String(describing: v)
        }
    }

    // ----------------------------------------------------------- cookies

    private func cookiesGet(_ args: [String: Any],
                            _ done: @escaping (WEResult) -> Void) {
        let store = config?.websiteDataStore ?? WKWebsiteDataStore.default()
        store.httpCookieStore.getAllCookies { cs in
            var list: [[String: Any]] = []
            let want = (args["domain"] as? String) ?? ""
            for c in cs where want.isEmpty || c.domain.contains(want) {
                var d: [String: Any] = [
                    "name": c.name, "value": c.value, "domain": c.domain,
                    "path": c.path, "secure": c.isSecure, "httpOnly": c.isHTTPOnly,
                ]
                if let e = c.expiresDate { d["expires"] = e.timeIntervalSince1970 }
                list.append(d)
            }
            done(.good(["cookies": list, "count": list.count]))
        }
    }

    private func cookiesSet(_ args: [String: Any],
                            _ done: @escaping (WEResult) -> Void) {
        guard let arr = args["cookies"] as? [[String: Any]] else {
            return done(.bad("cookies 参数不是数组"))
        }
        let store = config?.websiteDataStore ?? WKWebsiteDataStore.default()
        var n = 0
        for d in arr {
            guard let name = d["name"] as? String, let value = d["value"] as? String,
                  let domain = d["domain"] as? String else { continue }
            var props: [HTTPCookiePropertyKey: Any] = [
                .name: name, .value: value, .domain: domain,
                .path: (d["path"] as? String) ?? "/",
            ]
            if let e = d["expires"] as? Double, e > 0 {
                props[.expires] = Date(timeIntervalSince1970: e)
            } else {
                // 会话 cookie 也要能跨重启保留
                props[.expires] = Date(timeIntervalSinceNow: 30 * 24 * 3600)
            }
            if (d["secure"] as? Bool) ?? false { props[.secure] = "TRUE" }
            if (d["httpOnly"] as? Bool) ?? false { props[HTTPCookiePropertyKey("HttpOnly")] = "TRUE" }
            guard let c = HTTPCookie(properties: props) else { continue }
            store.httpCookieStore.setCookie(c, completionHandler: nil)
            n += 1
        }
        // 给 WebKit 一点时间落盘，否则紧接着的导航可能读不到刚写的 cookie。
        // 现在主队列是空闲的，asyncAfter 能正常触发，不再需要转运行循环。
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
            done(.good(["set": n]))
        }
    }

    private func clearData(_ done: @escaping (WEResult) -> Void) {
        let store = config?.websiteDataStore ?? WKWebsiteDataStore.default()
        store.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(),
                         modifiedSince: .distantPast) {
            done(.good())
        }
    }

    // --------------------------------------------------------------- 点击

    /// 在页面坐标 (x, y) 上合成一次真实左键点击。
    ///
    /// 走 NSEvent 发给**我们自己的窗口**，不需要「辅助功能」授权
    /// （CGEvent 往别的 App 投递才需要）。
    /// 在页面坐标 (x, y) 上点一次真实鼠标左键。
    ///
    /// ★ 这里接的是**页面坐标**，不是 AppKit 视图坐标 ★
    ///   调用方（seiue.py 的 _real_click）拿到的坐标来自 JS 的
    ///   `getBoundingClientRect()` —— 那是**左上角为原点**的 CSS 像素。
    ///   而 AppKit 的视图坐标系是**左下角为原点**。两者差一个
    ///   `web.bounds.height - y`。这个换算必须在这里做，放在 Python 侧
    ///   就会变成「每次都要记得转」，迟早有人在别处忘了转、点偏一整屏。
    ///
    /// 顺便把标签页切到正在点的那一个：只有可见的 web view 才收得到点击。
    private func click(_ t: WETab, x: Double, y: Double) -> WEResult {
        guard let w = window else { return .bad("没有窗口") }
        if activeID != t.id { activeID = t.id; relayout() }
        let css = NSPoint(x: x, y: t.web.bounds.height - y)
        let inWin = t.web.convert(css, to: nil)
        for kind in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            guard let ev = NSEvent.mouseEvent(
                with: kind, location: inWin, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: w.windowNumber, context: nil,
                eventNumber: 0, clickCount: 1,
                pressure: kind == .leftMouseDown ? 1 : 0)
            else { continue }
            w.sendEvent(ev)
        }
        return .good(["x": x, "y": y])
    }

    // ----------------------------------------------------- WKNavigation

    private func tabFor(_ web: WKWebView) -> WETab? {
        tabs.first { $0.web === web }
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        if let t = tabFor(webView) { t.lastError = "" }
    }

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        if let t = tabFor(webView) {
            t.lastURL = webView.url?.absoluteString ?? t.lastURL
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        if let t = tabFor(webView) {
            t.lastURL = webView.url?.absoluteString ?? t.lastURL
        }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        if let t = tabFor(webView) { t.lastError = error.localizedDescription }
    }

    func webView(_ webView: WKWebView,
                 didFailProvisionalNavigation navigation: WKNavigation!,
                 withError error: Error) {
        if let t = tabFor(webView) { t.lastError = error.localizedDescription }
    }

    /// 页面要开新窗口（登录 SSO 经常这么干）。
    ///
    /// ★ 必须用传进来的 configuration 建 webView ★ 用我们自己的 config 会被
    ///   WebKit 直接判定为非法参数并抛异常。返回的 webView 也必须是**新建**的，
    ///   不能拿现成的标签页去顶。
    /// 一律留在 App 内部 —— 交给系统去开一个真 Safari 窗口的话，登录态就跑到
    /// 那个窗口里，Python 这边什么也拿不到。
    func webView(_ webView: WKWebView,
                 createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction,
                 windowFeatures: WKWindowFeatures) -> WKWebView? {
        guard let u = navigationAction.request.url else { return nil }
        seq += 1
        let web = WKWebView(frame: window?.contentView?.bounds
                                ?? NSRect(origin: .zero, size: Self.frameSize),
                            configuration: configuration)
        web.navigationDelegate = self
        web.uiDelegate = self
        web.customUserAgent = Self.safariUserAgent()
        web.autoresizingMask = [.width, .height]

        let t = WETab(id: "w\(seq)", web: web)
        t.lastURL = u.absoluteString
        tabs.append(t)
        window?.contentView?.addSubview(web)
        activeID = t.id
        relayout()
        web.load(URLRequest(url: u))
        return web
    }

    /// JS 的 alert / confirm 必须有人应答，否则页面会一直卡在那里。
    func webView(_ webView: WKWebView,
                 runJavaScriptAlertPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo,
                 completionHandler: @escaping () -> Void) {
        completionHandler()
    }

    func webView(_ webView: WKWebView,
                 runJavaScriptConfirmPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo,
                 completionHandler: @escaping (Bool) -> Void) {
        completionHandler(true)
    }

    func webView(_ webView: WKWebView,
                 runJavaScriptTextInputPanelWithPrompt prompt: String,
                 defaultText: String?,
                 initiatedByFrame frame: WKFrameInfo,
                 completionHandler: @escaping (String?) -> Void) {
        completionHandler(defaultText ?? "")
    }

    func webView(_ webView: WKWebView,
                 runOpenPanelWith parameters: WKOpenPanelParameters,
                 initiatedByFrame frame: WKFrameInfo,
                 completionHandler: @escaping ([URL]?) -> Void) {
        completionHandler(nil)
    }

    // ------------------------------------------------------------ 下载

    /// WebKit 自己播不了的内容（xlsx / zip / csv…）转成下载。
    func webView(_ webView: WKWebView,
                 decidePolicyFor navigationResponse: WKNavigationResponse,
                 decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
        decisionHandler(navigationResponse.canShowMIMEType ? .allow : .download)
    }

    func webView(_ webView: WKWebView,
                 navigationAction: WKNavigationAction,
                 didBecome download: WKDownload) {
        download.delegate = self
    }

    func webView(_ webView: WKWebView,
                 navigationResponse: WKNavigationResponse,
                 didBecome download: WKDownload) {
        download.delegate = self
    }

    func download(_ download: WKDownload,
                  decideDestinationUsing response: URLResponse,
                  suggestedFilename: String,
                  completionHandler: @escaping (URL?) -> Void) {
        var dir = downloadDir
        if dir.isEmpty { dir = NSTemporaryDirectory() + "mbboard-downloads" }
        try? FileManager.default.createDirectory(atPath: dir,
                                                 withIntermediateDirectories: true)
        let name = suggestedFilename.isEmpty ? "download" : suggestedFilename
        var dest = URL(fileURLWithPath: dir).appendingPathComponent(name)
        // 同名不覆盖：加 -2 / -3 …，和浏览器的习惯一致
        var n = 1
        while FileManager.default.fileExists(atPath: dest.path) {
            n += 1
            let base = (name as NSString).deletingPathExtension
            let ext = (name as NSString).pathExtension
            let alt = ext.isEmpty ? "\(base)-\(n)" : "\(base)-\(n).\(ext)"
            dest = URL(fileURLWithPath: dir).appendingPathComponent(alt)
        }
        completionHandler(dest)
    }

    func downloadDidFinish(_ download: WKDownload) {
        NSLog("[webengine] 下载完成 → %@", download.progress.fileURL?.path ?? "?")
    }

    func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
        NSLog("[webengine] 下载失败：%@", error.localizedDescription)
    }
}

/* ======================================================================
   指令通道：从 bridge.py 拉指令 → 执行 → 回结果
   ====================================================================== */

final class WebEngineChannel {

    static let shared = WebEngineChannel()

    private var running = false
    private let lock = NSLock()
    private let base = "http://127.0.0.1:8765"

    /// 后端是否连着（给界面用：「内置引擎在线」）
    private(set) var attached = false
    private(set) var lastError = ""

    func start() {
        lock.lock(); defer { lock.unlock() }
        if running { return }
        running = true
        let t = Thread { [weak self] in self?.loop() }
        t.name = "webengine-channel"
        t.stackSize = 1 << 20
        t.start()
    }

    private func loop() {
        var misses = 0
        while true {
            switch poll(wait: 20) {
            case .cmd(let id, let op, let args):
                misses = 0
                attached = true
                // ★ 等的动作放在**本线程**（后台）★ 见 WebEngine.run 的说明：
                //   主线程只负责发起，绝不在主队列上等回调。
                //   这里堵住自己毫无副作用 —— 通道本来就是一条一条串行处理的。
                let gate = DispatchSemaphore(value: 0)
                var boxed: WEResult?
                WebEngine.shared.run(op, args) { res in
                    boxed = res
                    gate.signal()
                }
                var res = WEResult.bad("引擎执行超时（\(op)）")
                if gate.wait(timeout: .now() + 150) == .success, let r = boxed {
                    res = r
                }
                post(id, res)
            case .none:
                misses = 0
                attached = true
            case .failed(let msg):
                lastError = msg
                attached = false
                // 后端还没起来（App 刚启动时很正常）。退避重试，别在这里空转。
                misses += 1
                let back: Double = misses < 10 ? 0.5 : (misses < 30 ? 1.5 : 3.0)
                Thread.sleep(forTimeInterval: back)
            }
        }
    }

    private enum PollOutcome {
        case cmd(String, String, [String: Any])
        case none
        case failed(String)
    }

    private func poll(wait: Int) -> PollOutcome {
        guard let u = URL(string: "\(base)/api/webengine/poll?wait=\(wait)") else {
            return .failed("URL 拼装失败")
        }
        var req = URLRequest(url: u)
        req.timeoutInterval = Double(wait) + 15
        req.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData

        let sem = DispatchSemaphore(value: 0)
        var out = PollOutcome.failed("请求没有完成")
        URLSession.shared.dataTask(with: req) { data, resp, err in
            defer { sem.signal() }
            if let err {
                let code = (err as? URLError)?.code
                out = .failed(code == .timedOut ? "轮询超时" : err.localizedDescription)
                return
            }
            guard let http = resp as? HTTPURLResponse, http.statusCode == 200,
                  let data,
                  let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            else {
                out = .failed("后端回包异常（HTTP \((resp as? HTTPURLResponse)?.statusCode ?? -1)）")
                return
            }
            guard let cmd = obj["cmd"] as? [String: Any],
                  let id = cmd["id"] as? String,
                  let op = cmd["op"] as? String else {
                out = .none
                return
            }
            out = .cmd(id, op, (cmd["args"] as? [String: Any]) ?? [:])
        }.resume()

        _ = sem.wait(timeout: .now() + Double(wait) + 25)
        return out
    }

    private func post(_ id: String, _ res: WEResult) {
        guard let u = URL(string: "\(base)/api/webengine/result") else { return }
        var body: [String: Any] = ["id": id, "ok": res.ok]
        if let v = res.value { body["value"] = v }
        if !res.error.isEmpty { body["error"] = res.error }

        var req = URLRequest(url: u)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.timeoutInterval = 30
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)

        let sem = DispatchSemaphore(value: 0)
        URLSession.shared.dataTask(with: req) { _, _, _ in sem.signal() }.resume()
        _ = sem.wait(timeout: .now() + 20)
    }
}
