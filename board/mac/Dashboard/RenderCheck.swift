import SwiftUI
import AppKit

/* 离屏渲染自检：把看板整页画成 PNG，用来核对布局（不参与交付编译）
   用法：
     render --section todo|classes|grades|settings [--dark] [--w 1260] [--out /tmp/x.png] [--at HH:MM]
     render --live 6 [--section todo]      ← 真运行时核验（见下）
   注意：glassEffect 的子树在 ImageRenderer 里不会绘制，所以这里用 --flat 打开实色兜底，
        只能核对布局与文案，玻璃质感要靠真机看。 */

/// `--burst` 用：把 /tmp/a.png 变成 /tmp/a-03.png（第 3 次采样）
func burstPath(_ out: String, _ idx: Int) -> String {
    let u = URL(fileURLWithPath: out)
    let stem = u.deletingPathExtension().lastPathComponent
    let ext = u.pathExtension.isEmpty ? "png" : u.pathExtension
    return u.deletingLastPathComponent()
        .appendingPathComponent(String(format: "%@-%02d.%@", stem, idx, ext)).path
}

@main
struct RenderCheck {
    static func main() {
        var section = "todo"
        var dark = false
        /// --light：强制浅色。用来专门核对浅色主题（尤其是带 forcesDark 的
        /// 景观主题在浅色下那套备选画法）。
        var forceLight = false
        var out = "/tmp/dash.png"
        var width: CGFloat = 1260
        var flat = true
        var at: String? = nil
        var theme = "system"
        var palette = "standard"
        var density = "comfortable"
        var corner = "regular"
        var teamsMock: String? = nil
        var useScroll = false
        var height: CGFloat? = nil
        var noBackdrop = false
        var panel = false
        /// 让「小看板主题」不跟随看板（试它自己那套亮暗/配色）
        var noFollow = false
        /// 换一份数据来渲染（压力测试长标题 / 空字段用，绝不碰用户真缓存）
        ///
        /// ★ 默认必须是 nil，不能给初值 ★
        /// 这里原来写死 `~/.mbboard/cache.json`。属性初始化跑在**参数解析之前**，
        /// 于是它天然绕过了 `--data`：加了 --data 之后课表、设置、通知都变假了，
        /// 唯独作业列表还在读真缓存 —— 截图里仍然是真实的作业标题和成绩。
        /// 改成 nil、解析完再用数据目录拼，才真正跟 --data 同进退。
        var cachePath: String? = nil
        /// 只导出「学科 × 种类」的通知图标矩阵，然后退出
        var iconDir: String? = nil
        /// --live <秒>：真窗口跑 runloop，逐帧比对（下面有详细说明）
        var liveSecs: Double = 0
        /// --date YYYY-MM-DD：把「今天」挪到某一天（核对限时主题的闸门内外）
        var dateOverride: String? = nil
        /// --moon：强制让中秋上线提示弹窗出现（真设置里可能已经看过）
        var forceMoonNotice = false
        /// --nomoon：反过来，假装用户已经看过（拍不被弹窗遮挡的全页图）
        var forceMoonSeen = false
        /// --burst：live 模式下把每次采样的帧都存下来（<out> 变成名干，
        /// 落成 -00.png / -01.png …），用来看「某个东西是怎么一帧帧动的」
        var burst = false
        /// --data <目录>：把**整个数据目录**指到别处。
        ///
        /// ★ 为什么需要它（只靠 --cache 不够）★
        /// `--cache` 只换掉了「作业/成绩」那一个 JSON。但看板还有别的取数口：
        /// 「接下来的课堂」读 `<数据目录>/timetable.json`、通知读 notify-state、
        /// 设置读 settings.json。拿真数据渲染 README 截图时，作业是假的、
        /// **老师姓名和教室号却是真的** —— 只截一小块就看得出漏了。
        /// 指走整个目录之后，下面每一条取数口一起变成演示数据，
        /// 真实数据从头到尾不参与 README 的生成。
        var dataDir: String? = nil

        var args = Array(CommandLine.arguments.dropFirst())
        func nextVal() -> String { args.isEmpty ? "" : args.removeFirst() }
        while !args.isEmpty {
            let a = args.removeFirst()
            switch a {
            case "--section": section = nextVal()
            case "--out":     out = nextVal()
            case "--w":       width = CGFloat(Double(nextVal()) ?? 1260)
            case "--at":      at = nextVal()
            case "--theme":   theme = nextVal()
            case "--palette": palette = nextVal()
            case "--group":   PreviewFlags.group = nextVal()
            case "--solo":    PreviewFlags.solo = true
            case "--density": density = nextVal()
            case "--corner":  corner = nextVal()
            case "--teams-mock": teamsMock = nextVal()
            case "--search":  PreviewFlags.search = nextVal()
            case "--dark":    dark = true
            case "--light":   forceLight = true
            case "--glass":   flat = false
            case "--scroll":  useScroll = true
            case "--h":       height = CGFloat(Double(nextVal()) ?? 838)
            case "--nobg":    noBackdrop = true
            case "--panel":   panel = true
            case "--quick":   PreviewFlags.quick = true
            case "--clean":   PreviewFlags.clean = true
            case "--onboard": PreviewFlags.onboardStep = Int(nextVal())
            case "--cache":   cachePath = nextVal()
            case "--data":    dataDir = nextVal()
            case "--nofollow": noFollow = true
            case "--ai-authed": PreviewFlags.aiAuthed = true
            case "--chart":   PreviewFlags.chartKey = nextVal()
            case "--date":    dateOverride = nextVal()
            case "--moon":    forceMoonNotice = true
            case "--nomoon":  forceMoonSeen = true
            case "--splash":  PreviewFlags.splashAt = Double(nextVal())
            case "--hello":   PreviewFlags.helloT = Double(nextVal())
            case "--autodrag": PreviewFlags.autoDrag = true
            case "--still":   PreviewFlags.still = true
            case "--drag":
                // --drag 300,140
                let p = nextVal().split(separator: ",")
                if p.count == 2, let a = Double(p[0]), let b = Double(p[1]) {
                    PreviewFlags.dragTo = CGSize(width: a, height: b)
                }
            case "--burst":   burst = true
            case "--preview": PreviewFlags.previewIndex = Int(nextVal()) ?? 0
            case "--detail":  PreviewFlags.detailIndex = Int(nextVal()) ?? 0
            case "--live":    liveSecs = Double(nextVal()) ?? 6
            case "--notify-icons": iconDir = nextVal()
            default: break
            }
        }

        // ★ 必须在**任何** MBBPaths.home 访问之前设好 ★
        // home 是 static let（惰性求值、只算一次）。一旦有人先读了它，
        // 之后再设 overrideDataDir 就完全没作用了 —— 而参数刚解析完正好是
        // 全程序里最早的时机，所以钩子摆在这儿。
        if let d = dataDir {
            MBBPaths.overrideDataDir = d
            print("data dir → \(d)")
        }

        // 缓存的落点。--cache 单独指定时用它，否则跟着数据目录走 ——
        // 这一行必须在上面 --data 之后才求值，早一步就又读回真缓存了。
        let cacheFile = cachePath ?? MBBPaths.home.appendingPathComponent("cache.json").path

        // 通知图标矩阵：跟真机发通知用的是同一套画法（NotifyIcon），
        // 所以这张矩阵图里看到什么样，通知中心里就是什么样。
        if let dir = iconDir {
            NotifyIcon.dumpAll(to: dir)
            print("通知图标已导出 → \(dir)")
            exit(0)
        }

        PreviewFlags.flat = flat
        // 离屏：不挂 WKWebView（画不出来，还会用占位图盖住整屏）
        PreviewFlags.offscreen = true
        // 真机内容区外面套着 ScrollView。自检默认把它拆掉（直接铺开全部内容），
        // 这样能量到「整页有多高」；但拆掉之后就没有弹性兄弟视图来抢高度，
        // 会掩盖「卡片被撑高」这类问题 —— 要复现真机布局就加 --scroll。
        PreviewFlags.noScroll = !useScroll
        PreviewFlags.section = section

        // --date YYYY-MM-DD：把「今天」整块挪走。用来核对限时主题的闸门 ——
        // 同一个 App，改日期就能看到「主题在设置里 / 不在设置里」两种结果。
        var baseDay = Date()
        if let d = dateOverride {
            let f = DateFormatter()
            f.dateFormat = "yyyy-MM-dd"
            f.timeZone = .current
            if let parsed = f.date(from: d) {
                baseDay = parsed
                PreviewFlags.dateOverride = parsed
                print("date override → \(d)")
            } else {
                print("⚠ --date 解析失败：\(d)（要 YYYY-MM-DD）")
            }
        }

        // --at HH:MM 与 --date 可以叠加：前者给时刻，后者给日子。
        if let at {
            let parts = at.split(separator: ":").map { Int($0) ?? 0 }
            var c = Calendar.current.dateComponents([.year, .month, .day], from: baseDay)
            c.hour = parts.first ?? 12
            c.minute = parts.count > 1 ? parts[1] : 0
            PreviewFlags.nowOverride = Calendar.current.date(from: c)
        } else if dateOverride != nil {
            // 只给了日子：把时刻定在 20:00（月夜刚亮起来的那会儿）
            var c = Calendar.current.dateComponents([.year, .month, .day], from: baseDay)
            c.hour = 20; c.minute = 0
            PreviewFlags.nowOverride = Calendar.current.date(from: c)
        }

        let s = BoardSettings.shared
        // 自检只改内存：跑一次渲染不该把用户的设置文件写花
        BoardSettings.readOnly = true
        s.theme = ThemeMode(rawValue: theme) ?? .system
        // 主题（调色板）：离屏渲染时也要真的换过去，否则看到的还是出厂配色
        if s.paletteID != palette { s.paletteID = palette }
        s.density = Density(rawValue: density) ?? .comfortable
        s.corner = CornerStyle(rawValue: corner) ?? .regular
        // 量卡片边界时把底纹照片关掉：照片让像素判定不可靠（卡片和背景都是褐色渐变）
        if noBackdrop { s.themeBackdrop = false }
        // --nofollow：让小看板用自己那套主题（配色取 --palette，亮暗取 --dark）
        if noFollow {
            if panel { BoardSettings.role = .panel }
            s.panelThemeFollow = false
            s.panelPaletteID = palette
            s.activatePaletteOnly()
        }

        let store = DataStore.shared
        if let data = try? Data(contentsOf: URL(fileURLWithPath: cacheFile)),
           let p = try? JSONDecoder().decode(Payload.self, from: data) {
            store.payload = p
            store.lastFetch = Date()
            print("cache ok (\(cacheFile)) tasks=\(p.tasks?.count ?? 0) classes=\(p.classes?.count ?? 0) recent=\(p.recent?.count ?? 0)")
        } else {
            print("cache 读取失败，将渲染空态")
        }

        if let tm = teamsMock,
           let d = try? Data(contentsOf: URL(fileURLWithPath: tm)),
           let e = try? JSONDecoder().decode(TeamsEnvelope.self, from: d) {
            store.teams = e
            print("teams mock: loggedIn=\(e.loggedIn ?? false) tasks=\(e.section?.tasks?.count ?? 0)")
        }

        // --moon / --nomoon：上线提示现在**档期内每次启动都会出现**，
        // 它由 DashRoot 的一个内存态 @State 管着，而自检本身就是一次「启动」，
        // 所以默认就会弹。--nomoon 只是把「本次不看」这一位按住，
        // 方便拍不被遮挡的全页图。
        if forceMoonSeen { PreviewFlags.hideMoonNotice = true }
        if forceMoonNotice { PreviewFlags.hideMoonNotice = false }

        // --preview / --detail：真机要点一下卡片才弹的浮层，离屏点不了，
        // 于是给它们各开一个后门。**这同时也是「小窗是不是相对视口居中」的
        // 检验手段** —— 以前预览挂在滚动内容上，一页长内容就会把小窗顶到
        // 视口外；现在挂在根部，无论第几条都该在正中。
        if let i = PreviewFlags.previewIndex {
            let list = store.teamsTasks
            if list.indices.contains(i) {
                TaskPreviewCenter.shared.task = list[i]
                print("preview 后门 → 第 \(i) 条（共 \(list.count)）")
            } else {
                print("⚠ --preview \(i)：Teams 任务只有 \(list.count) 条（记得配 --teams-mock）")
            }
        }
        if let i = PreviewFlags.detailIndex {
            let g = store.groups(now: PreviewFlags.nowOverride ?? Date(), settings: s)
            let list = g.up + g.od
            if list.indices.contains(i) {
                TaskDetailCenter.shared.open(list[i], width: 580)
                print("detail 后门 → 第 \(i) 条（共 \(list.count)）")
            } else {
                print("⚠ --detail \(i)：待办只有 \(list.count) 条")
            }
        }

        // 深浅色。默认跟着「实际生效的主题」走 —— 「月圆 · LunaOS」自带
        // `forcesDark`（选它就整个 App 深色），所以 `--palette moonfest`
        // 不带任何开关时也该渲染深色的月夜，那才是真机的样子。
        // 想专门看浅色那套「月华」画法，加 `--light` 强制覆盖。
        let scheme: ColorScheme = forceLight ? .light
                                 : (dark || s.palette.forcesDark ? .dark : .light)
        let env0: (BoardSettings) -> Env = { Env(scheme: scheme, settings: $0) }

        // --solo：只画设置页本身，不套 DashRoot。
        // 用来区分「页面自己太宽」还是「外壳的组合方式把它挤出去了」：
        // 外面加一圈红色描边，超出去的像素一眼就能看见。
        // ── 真·运行时核验：定时器到底有没有真的跑起来 ──────────────────────
        //
        // ImageRenderer 是「一帧定生死」：它同步画一次就结束，中间没有任何
        // runloop 时间，所以定时器/动画有没有在工作，从图里完全看不出来。
        // 首页那个大倒计时卡死在 05:34，正是栽在这一类盲区里 —— 代码读起来
        // 毫无问题（`.onReceive(Timer.publish(...))`），只有让它真跑几秒、
        // 对比前后两帧，才会发现数字一动不动。
        //
        // 所以这里另开一条路：把 DashRoot 放进一个**真正的窗口**，跑真 runloop，
        // 每 0.5 秒连拍一张，逐像素比对相邻两帧，报出「变化像素的包围盒」。
        //   时钟在跳 → 每次采样都有一小片像素变化；
        //   时钟卡住 → 包围盒恒为空。
        // 窗口放在屏幕外、alpha=0，用户看不见，但它「在台上」，SwiftUI 才会
        // 真的把 .task 跑起来。
        if liveSecs > 0 {
            PreviewFlags.flat = true
            PreviewFlags.offscreen = true          // 不挂 WKWebView（离屏画不出来）
            PreviewFlags.noScroll = false          // 复现真机的滚动容器
            PreviewFlags.section = section

            let app = NSApplication.shared
            app.setActivationPolicy(.accessory)

            let h: CGFloat = height ?? 838
            // --live 也支持把首启两幕放进真窗口跑（--section splash / hello），
            // 逐帧比对能证明「动画真的在动」，这是 ImageRenderer 一帧定生死
            // 永远证不了的事。
            let liveRoot: AnyView
            switch section {
            case "splash": liveRoot = AnyView(SplashView(onDone: { }).environmentObject(s))
            case "hello":  liveRoot = AnyView(HelloGreeting(onStart: { }).environmentObject(s))
            default:       liveRoot = AnyView(DashRoot(store: store))
            }
            let host = NSHostingView(rootView: AnyView(
                liveRoot
                    .environment(\.colorScheme, scheme)
                    .environment(\.mbRenderMode, true)
                    .frame(width: width, height: h, alignment: .top)
            ))
            host.frame = NSRect(x: 0, y: 0, width: width, height: h)

            let win = NSWindow(contentRect: host.frame, styleMask: [.borderless],
                               backing: .buffered, defer: false)
            win.contentView = host
            win.alphaValue = 0
            win.ignoresMouseEvents = true
            win.setFrameOrigin(NSPoint(x: -4000, y: -4000))
            win.orderFrontRegardless()

            func snap() -> NSBitmapImageRep? {
                guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return nil }
                host.cacheDisplay(in: host.bounds, to: rep)
                return rep
            }

            func savePNG(_ rep: NSBitmapImageRep, _ path: String) {
                guard let tiff = rep.tiffRepresentation,
                      let b = NSBitmapImageRep(data: tiff),
                      let png = b.representation(using: .png, properties: [:]) else { return }
                try? png.write(to: URL(fileURLWithPath: path))
            }

            /// 相邻两帧的差异：返回「变化像素数 + 包围盒（像素坐标）」。
            /// 只比 RGB，不比 alpha，也不比每行末尾的对齐填充 —— 那些不属于内容。
            func diff(_ a: NSBitmapImageRep, _ b: NSBitmapImageRep) -> (Int, CGRect) {
                guard a.pixelsWide == b.pixelsWide, a.pixelsHigh == b.pixelsHigh,
                      let pa = a.bitmapData, let pb = b.bitmapData else { return (0, .zero) }
                let spp = max(1, a.samplesPerPixel)
                let used = a.pixelsWide * spp
                var n = 0
                var minX = Int.max, minY = Int.max, maxX = -1, maxY = -1
                for y in 0..<a.pixelsHigh {
                    let ra = pa.advanced(by: y * a.bytesPerRow)
                    let rb = pb.advanced(by: y * b.bytesPerRow)
                    var x = 0
                    while x < used {
                        if ra[x] != rb[x] || ra[x + 1] != rb[x + 1] || ra[x + 2] != rb[x + 2] {
                            n += 1
                            let px = x / spp
                            if px < minX { minX = px }
                            if px > maxX { maxX = px }
                            if y < minY { minY = y }
                            if y > maxY { maxY = y }
                        }
                        x += spp
                    }
                }
                if maxX < 0 { return (0, .zero) }
                return (n, CGRect(x: minX, y: minY,
                                  width: maxX - minX + 1, height: maxY - minY + 1))
            }

            RunLoop.main.run(until: Date().addingTimeInterval(1.5))   // 先让它画完第一帧
            guard let first = snap() else { print("live: 拿不到首帧"); exit(2) }
            // 自检「快照不是一张空白」：真页面有大量不同字节值，空白页只有一两种。
            var kinds = Set<UInt8>()
            if let p = first.bitmapData {
                for i in stride(from: 0, to: first.bytesPerRow * first.pixelsHigh, by: 97) {
                    kinds.insert(p[i])
                }
            }
            print("live: \(first.pixelsWide)x\(first.pixelsHigh)px 起跑（采样到 \(kinds.count) 种字节值；<3 说明画的是空白）")

            var prev = first
            let t0 = Date()
            var samples = 0, beats = 0
            var firstBeatAt: Double? = nil
            while Date().timeIntervalSince(t0) < liveSecs {
                RunLoop.main.run(until: Date().addingTimeInterval(0.5))
                samples += 1
                guard let cur = snap() else { continue }
                if burst { savePNG(cur, burstPath(out, samples - 1)) }
                let (n, box) = diff(prev, cur)
                prev = cur
                let t = Date().timeIntervalSince(t0)
                if n > 0 {
                    beats += 1
                    if firstBeatAt == nil { firstBeatAt = t }
                    print(String(format: "  t=%4.1fs  变化 %6d 像素  包围盒 x=%d y=%d w=%d h=%d",
                                 t, n, Int(box.minX), Int(box.minY),
                                 Int(box.width), Int(box.height)))
                } else {
                    print(String(format: "  t=%4.1fs  变化      0 像素  ——  这一帧什么都没动", t))
                }
            }
            if let f = snap() { savePNG(f, out) }
            let verdict = beats > 0 ? "定时器在跑" : "★ 定时器没跑（整段时间画面全静止）"
            print("live: \(Int(liveSecs)) 秒 / \(samples) 次采样 → \(beats) 次检出变化，首次变化在 t=\(firstBeatAt.map { String(format: "%.1f", $0) } ?? "—")s —— \(verdict)")
            print("live: 末帧已存 \(out)")
            exit(beats > 0 ? 0 : 3)
        }

        let view: AnyView
        if PreviewFlags.solo {
            view = AnyView(
                SettingsSection()
                    .environmentObject(s)
                    .environment(\.colorScheme, scheme)
                    .environment(\.mbRenderMode, true)
                    .padding(env0(s).space(16))
                    .frame(width: width, alignment: .leading)
                    // --solo 不套 DashRoot，也就没有 Theme.page 背景。深色模式下
                    // 标题是浅色字画在默认白底上 → 整屏「看不见字」，会被误判成 bug。
                    .background(Theme.page(scheme))
                    .background(Color.green.opacity(PreviewFlags.clean ? 0 : 0.18))
                    .overlay(Rectangle().strokeBorder(Color.red.opacity(PreviewFlags.clean ? 0 : 1),
                                                     lineWidth: 2))
            )
        } else if section == "onboard" {
            // 引导页：八步逐屏核对
            view = AnyView(
                OnboardingView(onFinish: { })
                    .environmentObject(s)
                    .environment(\.colorScheme, scheme)
                    .environment(\.mbRenderMode, true)
                    .frame(width: width, height: height, alignment: .top)
            )
        } else if section == "splash" {
            // 首启快闪动画：配 --splash <秒> 冻在任意一帧逐张核对分镜
            view = AnyView(
                SplashView(onDone: { })
                    .environmentObject(s)
                    .frame(width: width, height: height ?? 838, alignment: .center)
            )
        } else if section == "hello" {
            // 彩虹 hello：配 --hello <0…1> 冻在某个书写进度
            view = AnyView(
                HelloGreeting(onStart: { })
                    .environmentObject(s)
                    .frame(width: width, height: height ?? 838, alignment: .center)
            )
        } else if panel {
            // --panel：把菜单栏小面板整块画出来（离屏只能看布局/文案，玻璃质感看不到）
            view = AnyView(
                PanelView(store: store)
                    .environmentObject(s)
                    .environment(\.colorScheme, scheme)
                    .environment(\.mbRenderMode, true)
                    .frame(width: CGFloat(s.panelWidth),
                           height: height ?? CGFloat(s.panelHeight),
                           alignment: .top)
                    .background(Theme.cardFill(scheme, strength: 1))
            )
        } else {
            view = AnyView(
                DashRoot(store: store)
                    .environmentObject(s)
                    .environment(\.colorScheme, scheme)
                    // 关掉进场动画：ImageRenderer 不保证触发 onAppear，
                    // 不关的话带 .appearIn 的区块会渲染成一片空白，量出来的宽度全是错的。
                    .environment(\.mbRenderMode, true)
                    .frame(width: width, height: height, alignment: .top)
            )
        }

        let r = ImageRenderer(content: view)
        r.scale = 2
        r.proposedSize = ProposedViewSize(width: width, height: height)

        guard let img = r.nsImage,
              let tiff = img.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else {
            print("render failed")
            return
        }
        try? png.write(to: URL(fileURLWithPath: out))
        print("ok \(Int(img.size.width))x\(Int(img.size.height)) → \(out)")
    }
}
