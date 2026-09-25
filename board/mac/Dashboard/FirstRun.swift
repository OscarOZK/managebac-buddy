import SwiftUI
import AppKit

/* ======================================================================
   首启三幕：快闪动画 → 彩虹 hello → 新手导览
   ----------------------------------------------------------------------
   用户刚下载 App、第一次打开时，在引导页**之前**先看到的整段演出。
   分三幕，幕与幕之间不硬切：

     第一幕 · 快闪    约 4.0s。逐帧复刻 kimi 品牌动画的分镜节奏
                      （用户原话：「除了文字以外完全一样」）：
                      空白 → 手写体 → 打字机体 → 斜体 → 淡影残字 →
                      乱码快闪 → 从左到右逐字锁定 → 「MB BUDDY」定版。
                      文本换成 MB Buddy；视频里 kimi 定版是大写 KIMI，
                      所以这里定版也用大写 —— 手写阶段仍是品牌原样
                      「MB Buddy」。
     第二幕 · hello   彩虹辉光连笔「hello」反复书写，模拟苹果新设备
                      开机的那一笔（用户原话：「一定要和苹果那个一模一样」）。
                      写满停一拍，再从笔迹起端抽走，循环往复。
                      写完第一遍时，下方浮出「让我们开始吧」。
     第三幕 · 引导    点按钮 → hello 上浮散场 → 导览第一屏浮入。

   实现纪律（都踩过坑）：
     · 第一幕**不是视频**，也不是逐帧贴图 —— 是纯 SwiftUI、每一帧都是
       t 的纯函数。这样 ImageRenderer 冻结在任意 t 都能出与真机一致的
       静帧（--splash <秒>），乱码用 tick 序号做随机种子，同一 tick
       里重渲染多少次字形都不变。
     · 第三幕的进场动画挂在 OnboardingView 外面这一层，不去改
       Onboarding.swift —— 引导页自己还有八步翻页逻辑，别去搅它。
     · 尊重「减弱动态效果」：直接从 hello 的写满状态开始，快闪整段跳过。
   ====================================================================== */

// MARK: - 时间轴（逐帧对齐原片：3.51s @ 24fps 的关键帧挪到秒）

private enum TL {
    /// 空白段（原片 1–4 帧）
    static let blankEnd   = 0.17
    // 字体走马灯。六个风格叠在同一位置，各自按 (出现,开始退,退净) 三点显隐，
    // 相邻两段有约 0.04–0.08s 的交叉淡化 —— 原片就是这种「换字形」而不是硬切。
    static let a: (Double, Double, Double) = (0.17, 0.29, 0.40)   // 手写签名
    static let b: (Double, Double, Double) = (0.34, 0.46, 0.56)   // 打字机体
    static let c: (Double, Double, Double) = (0.48, 0.56, 0.66)   // 衬线斜体
    static let d: (Double, Double, Double) = (0.58, 0.62, 0.74)   // 细衬线
    static let e: (Double, Double, Double) = (0.70, 0.74, 0.88)   // 淡影花体
    static let f: (Double, Double, Double) = (0.86, 0.92, 1.06)   // 残字斜体
    /// 乱码段起点（原片 26 帧起）
    static let scrambleStart = 1.06
    /// 乱码换字周期。原片每 3 帧（0.125s）换一组，快闪感就是这么来的
    static let tick = 0.125
    /// 收敛：从左到右逐字锁定（原片 52–59 帧约 0.3s 收完）
    static let lockStart = 2.46
    static let lockStep  = 0.045
    static let lockSnap  = 0.12
    /// 定版后的散场：上浮 + 发虚 + 淡出，衔接第二幕
    static let exitStart = 3.60
    static let total     = 4.00
}

// MARK: - 墨色与底色

private enum FirstRunInk {
    /// 文字近黑（Apple 墨色）
    static let text = Color(red: 0.11, green: 0.11, blue: 0.12)
    /// 背景：一丁点儿偏米黄的纯白（用户指定的底色）。
    /// 中心更亮、四角略暖，避免大面积死白显得像没加载完。
    static let bgCenter = Color(red: 0.996, green: 0.992, blue: 0.980)
    static let bgEdge   = Color(red: 0.969, green: 0.960, blue: 0.933)
}

// MARK: - ① 快闪动画

struct SplashView: View {
    var onDone: () -> Void

    @State private var start: Date? = nil
    @State private var done = false

    /// 六种字形风格（名字、字号、透明度峰值）。字号微差是刻意的：
    /// 原片各阶段的「kimi」大小并不完全相等，手写体最大。
    private static let styles: [(font: String, size: CGFloat, peak: Double, text: String)] = [
        ("SnellRoundhand-Bold",        100, 1.00, "MB Buddy"),
        ("AmericanTypewriter-Bold",     76, 1.00, "MB Buddy"),
        ("Didot-Italic",                82, 1.00, "MB Buddy"),
        ("BodoniSvtyTwoOSITCTT-Book",   80, 0.90, "MB Buddy"),
        ("SavoyeLetPlain",              94, 0.50, "MB Buddy"),
        ("BodoniSvtyTwoOSITCTT-BookIt", 78, 0.35, "MB Buddy"),
    ]
    /// 乱码字符池 —— 从原片帧里认出来的那一类符号：花色、几何、数学、
    /// 括线，掺几个本词字母（原片乱码里也时不时蹦出 K 和 i）。
    private static let glyphPool = Array("♥♠♦♣●◆◇○▲△▼■□)]]([{〈〉#=≠*⁄÷¥§ΞΔΘΛΣΨΩЖФ4679ⅩKMBUDY")

    var body: some View {
        GeometryReader { geo in
            ZStack {
                background
                if let frozen = PreviewFlags.splashAt {
                    content(t: frozen)
                } else {
                    TimelineView(.animation) { ctx in
                        let t = start.map { ctx.date.timeIntervalSince($0) } ?? 0
                        content(t: t)
                    }
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .onAppear {
            // 冻结模式（离屏自检）不计时、不回调 —— 静帧就是一切。
            guard PreviewFlags.splashAt == nil else { return }
            start = Date()
            Task { [onDone] in
                try? await Task.sleep(nanoseconds: UInt64(TL.total * 1_000_000_000))
                onDone()
            }
        }
    }

    private var background: some View {
        RadialGradient(colors: [FirstRunInk.bgCenter, FirstRunInk.bgEdge],
                       center: .center, startRadius: 80, endRadius: 900)
            .ignoresSafeArea()
    }

    // MARK: 内容 = t 的纯函数

    @ViewBuilder
    private func content(t: Double) -> some View {
        let exit = exitK(t)          // 0→1，散场进度
        Group {
            if t < TL.scrambleStart {
                typography(t: t)
            } else {
                scramble(t: t)
            }
        }
        .scaleEffect(1 + 0.06 * exit)
        .blur(radius: 10 * exit)
        .offset(y: -16 * exit)
        .opacity(1 - exit)
    }

    /// 走马灯：六个风格全部常驻叠放，只按时间轴调各自的透明度。
    @ViewBuilder
    private func typography(t: Double) -> some View {
        ZStack {
            ForEach(0..<Self.styles.count, id: \.self) { i in
                let s = Self.styles[i]
                let win = [TL.a, TL.b, TL.c, TL.d, TL.e, TL.f][i]
                styledText(s)
                    .opacity(trapezoid(t, win.0, win.1, win.2, peak: s.peak))
            }
        }
    }

    private func styledText(_ s: (font: String, size: CGFloat, peak: Double, text: String)) -> some View {
        Text(s.text)
            .font(.custom(s.font, size: s.size))
            .kerning(1.2)
            .foregroundStyle(FirstRunInk.text)
            .fixedSize()
    }

    /// 乱码 → 收敛 → 定版。槽位宽度按定版字形的每字符实宽布置，
    /// 这样「乱码字形换成定版字母」的那一刻布局纹丝不动 ——
    /// 原片里乱码块的整体宽度也与最终 KIMI 几乎一致。
    @ViewBuilder
    private func scramble(t: Double) -> some View {
        let slots = Self.slots
        let tick = Int((t - TL.scrambleStart) / TL.tick)
        HStack(spacing: 0) {
            ForEach(0..<slots.count, id: \.self) { i in
                let lock = TL.lockStart + Double(i) * TL.lockStep
                let snap = min(1, max(0, (t - lock) / TL.lockSnap))
                ZStack {
                    // 定版字母：锁定的瞬间从 1.18 缩回 1 并浮现（snap 缓动）
                    if slots[i].ch != " " {
                        Text(String(slots[i].ch))
                            .font(.custom("Futura-Bold", size: 74))
                            .foregroundStyle(FirstRunInk.text)
                            .scaleEffect(1.18 - 0.18 * smooth(snap))
                            .opacity(smooth(snap))
                    }
                    // 锁定前：本 tick 的乱码字形
                    if snap < 1, slots[i].ch != " " {
                        glyph(i: i, tick: tick)
                            .opacity(1 - smooth(snap))
                    }
                }
                .frame(width: slots[i].width, height: 96)
            }
        }
        .fixedSize()
    }

    /// 一个乱码槽位：字体、字形、字号、基线抖动全部由 (slot, tick) 种子决定，
    /// 同一 tick 内重复渲染结果一致（ImageRenderer 冻帧的前提）。
    private func glyph(i: Int, tick: Int) -> some View {
        var rng = SeededGenerator(seed: UInt64(tick) &* 6_364_136_223_846_793_005 &+ UInt64(i) &* 1_111_111)
        let fonts = ["Futura-Bold", "TimesNewRomanPS-BoldMT", "AmericanTypewriter-Bold",
                     "Didot-Bold", "CourierNewPS-BoldMT"]
        let fname = fonts[Int(rng.next() % UInt64(fonts.count))]
        let ch = Self.glyphPool[Int(rng.next() % UInt64(Self.glyphPool.count))]
        let size = 64.0 + Double(rng.next() % 1000) / 1000.0 * 20.0   // 64–84
        let dy = Double(rng.next() % 1000) / 1000.0 * 8.0 - 4.0       // ±4
        return Text(String(ch))
            .font(.custom(fname, size: size))
            .foregroundStyle(FirstRunInk.text)
            .fixedSize()
            .offset(y: dy)
    }

    // MARK: 定版字形的每字符宽度（App 启动后算一次，缓存进静态）

    private static let finalWord = "MB BUDDY"
    private static let slots: [(ch: Character, width: CGFloat)] = {
        let f = NSFont(name: "Futura-Bold", size: 74)
            ?? NSFont.boldSystemFont(ofSize: 74)
        return finalWord.map { c in
            let w = (NSAttributedString(string: String(c), attributes: [.font: f])
                .size()).width
            return (c, w + 2.5)     // +2.5 ≈ tracking，别让字母贴死
        }
    }()

    // MARK: 缓动

    /// 散场进度 0→1（smoothstep 缓一下，比线性优雅）
    private func exitK(_ t: Double) -> Double {
        guard t > TL.exitStart else { return 0 }
        return smooth(min(1, (t - TL.exitStart) / (TL.total - TL.exitStart)))
    }
    private func smooth(_ k: Double) -> Double { k * k * (3 - 2 * k) }

    /// 梯形显隐：rise 快速浮现 → 平顶保持 → 从 off 到 gone 线性淡出。
    /// 原片的字形切换就是这种「渐显-保持-渐隐」的交叉，不是硬切。
    private func trapezoid(_ t: Double, _ on: Double, _ off: Double, _ gone: Double,
                           rise: Double = 0.045, peak: Double = 1) -> Double {
        guard t > on, t < gone else { return 0 }
        if t < on + rise { return peak * (t - on) / rise }
        if t < off { return peak }
        return peak * max(0, 1 - (t - off) / (gone - off))
    }
}

/// 可复现的伪随机（SplitMix64）。乱码必须同 tick 同结果，
/// SystemClock 随机数在 ImageRenderer 冻帧时会前后不一致。
private struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed &* 0x9E3779B97F4A7C15 &+ 0x9E3779B9 }
    mutating func next() -> UInt64 {
        state = state &+ 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
}

// MARK: - ② 彩虹 hello（循环书写）+ 开始按钮

struct HelloGreeting: View {
    var onStart: () -> Void

    /// 书写进度：0 = 未落笔，1 = 一整笔写完
    @State private var progress: Double = 0
    /// 擦除进度：0 = 不擦，1 = 整笔从头抽干（trim 起点 0→1）
    @State private var erase: Double = 0
    @State private var buttonShown = false
    @State private var exiting = false
    @EnvironmentObject private var settings: BoardSettings

    /// 连笔「hello」的单笔画路径（笔顺：h→e→l→l→o→甩尾），
    /// 锚点用 Catmull-Rom 拟合成贝塞尔 —— 逐版对着渲染稿调出来的。
    static let helloPath: Path = {
        let raw: [(Double, Double)] = [
            // h：入笔 → 上冲到顶 → 收笔落下 → 拱肩 → 出锋
            (150, 408), (205, 290), (232, 148),
            (224, 152), (210, 280), (176, 402),
            (196, 392), (250, 300), (292, 264),
            (336, 292), (356, 392), (374, 394), (386, 368),
            // e：上冲到顶，逆时针小环，沿基线出
            (412, 325), (434, 282),
            (408, 266), (384, 294),
            (390, 348), (424, 388),
            (452, 390), (472, 366),
            // l1：顶部圆回折，竖笔落基线交叉，U 形出锋
            (492, 330), (518, 220), (544, 152),
            (532, 142), (506, 250), (486, 396),
            (508, 410), (532, 378),
            // l2
            (556, 320), (580, 215), (604, 150),
            (592, 141), (566, 250), (546, 396),
            (568, 410), (594, 376),
            // o：陡直入笔升到顶点，碗部逆时针绕整圆，收口甩尾
            (620, 352), (655, 320), (692, 290), (716, 268),
            (688, 282), (672, 318), (678, 358), (714, 390),
            (762, 384), (786, 344), (782, 298), (746, 270),
            (768, 320), (772, 368),
            (798, 398), (832, 404), (860, 384), (872, 352),
        ]
        let pts = raw.map { CGPoint(x: $0.0, y: $0.1) }
        var p = Path()
        guard let first = pts.first else { return p }
        p.move(to: first)
        for i in 0..<pts.count - 1 {
            let p0 = i > 0 ? pts[i - 1] : pts[i]
            let p1 = pts[i], p2 = pts[i + 1]
            let p3 = i + 2 < pts.count ? pts[i + 2] : pts[i + 1]
            let c1 = CGPoint(x: p1.x + (p2.x - p0.x) / 6, y: p1.y + (p2.y - p0.y) / 6)
            let c2 = CGPoint(x: p2.x - (p3.x - p1.x) / 6, y: p2.y - (p3.y - p1.y) / 6)
            p.addCurve(to: p2, control1: c1, control2: c2)
        }
        return p
    }()

    /// 归一化后的路径（左上角对齐原点）与包围盒 —— 缩放布置用
    static let pathBounds = helloPath.boundingRect
    static let normalizedPath = helloPath.applying(
        CGAffineTransform(translationX: -pathBounds.minX, y: -pathBounds.minY))

    /// 苹果彩虹。位置渐变：写到哪里，哪里就是那个位置的色相 ——
    /// 和真机 hello「h 是暖红、o 是紫」的观感一致。
    private static let rainbow = LinearGradient(
        colors: [
            Color(red: 1.00, green: 0.23, blue: 0.19),   // #FF3B30
            Color(red: 1.00, green: 0.58, blue: 0.00),   // #FF9500
            Color(red: 1.00, green: 0.80, blue: 0.00),   // #FFCC00
            Color(red: 0.20, green: 0.78, blue: 0.35),   // #34C759
            Color(red: 0.20, green: 0.68, blue: 0.90),   // #32ADE6
            Color(red: 0.69, green: 0.32, blue: 0.87),   // #AF52DE
        ],
        startPoint: .leading, endPoint: .trailing)

    var body: some View {
        GeometryReader { geo in
            ZStack {
                RadialGradient(colors: [FirstRunInk.bgCenter, FirstRunInk.bgEdge],
                               center: .center, startRadius: 80, endRadius: 900)
                    .ignoresSafeArea()

                VStack(spacing: 0) {
                    Spacer(minLength: 0)
                    hello(size: CGSize(width: geo.size.width - 120,
                                       height: geo.size.height * 0.42))
                    Spacer(minLength: 0)
                    startButton
                    Spacer().frame(height: geo.size.height * 0.16)
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .onAppear { boot() }
    }

    /// 三层描边叠出「发光体」：宽晕 → 中晕 → 锐芯。
    /// 单层 blur 看起来像描边，多层由内到外递减才有辉光的体积感。
    /// 路径按可用空间等比缩放，线宽跟着缩放 —— 窗口多大，字就多大。
    private func hello(size: CGSize) -> some View {
        let bb = Self.pathBounds
        let k = max(0.1, min(size.width / bb.width, size.height / bb.height))
        let trimmed = Self.normalizedPath
            .applying(CGAffineTransform(scaleX: k, y: k))
            .trimmedPath(from: min(erase, progress), to: max(erase, progress))
        return ZStack {
            strokeLayer(trimmed, width: 22 * k, blur: 16, opacity: 0.42)
            strokeLayer(trimmed, width: 14 * k, blur: 7,  opacity: 0.55)
            strokeLayer(trimmed, width: 8 * k,  blur: 0.8, opacity: 1)
        }
        .frame(width: bb.width * k, height: bb.height * k)
        .scaleEffect(exiting ? 0.94 : 1)
        .blur(radius: exiting ? 8 : 0)
        .offset(y: exiting ? -26 : 0)
        .opacity(exiting ? 0 : 1)
    }

    private func strokeLayer(_ path: Path, width: CGFloat, blur: CGFloat, opacity: Double) -> some View {
        path
            .stroke(Self.rainbow, style: StrokeStyle(lineWidth: width, lineCap: .round, lineJoin: .round))
            .blur(radius: blur)
            .opacity(opacity)
    }

    private var startButton: some View {
        Button {
            guard !exiting else { return }
            exiting = true
            Task { [onStart] in
                try? await Task.sleep(nanoseconds: 520_000_000)
                onStart()
            }
        } label: {
            Text("让我们开始吧")
                .font(.system(size: 16, weight: .semibold))
                .foregroundColor(.white)
                .padding(.horizontal, 36)
                .padding(.vertical, 13)
                .background(
                    Capsule().fill(LinearGradient(
                        colors: [Color(red: 0.24, green: 0.58, blue: 0.96),
                                 Color(red: 0.04, green: 0.37, blue: 0.82)],
                        startPoint: .top, endPoint: .bottom))
                )
                .shadow(color: Color(red: 0.04, green: 0.37, blue: 0.82).opacity(0.35),
                        radius: 14, y: 5)
        }
        .buttonStyle(.plain)
        .scaleEffect(exiting ? 0.96 : 1)
        .offset(y: exiting ? 18 : 0)
        .opacity(exiting ? 0 : (buttonShown ? 1 : 0))
        .disabled(exiting)
    }

    // MARK: 循环状态机

    /// 首写 2.0s → 停 1.2s → 擦 0.7s → 顿 0.35s → 再写，一直循环。
    /// 写满第一遍时按钮浮出 —— 用户要看的说明一个字都不用给。
    private func boot() {
        // 冻结模式（离屏自检）：进度定死在 --hello 给的值，按钮直接在场。
        if let t = PreviewFlags.helloT {
            progress = t
            buttonShown = true
            return
        }
        if settings.reduceMotion || Motion.reduced {
            progress = 1
            buttonShown = true
            return
        }
        Task { await loop() }
    }

    private func loop() async {
        await write()
        await MainActor.run { buttonShown = true }
        while !Task.isCancelled {
            try? await Task.sleep(nanoseconds: 1_200_000_000)   // 停一拍，让辉光喘口气
            await unwrite()                                      // 从 h 那头抽走
            try? await Task.sleep(nanoseconds: 350_000_000)
            await write()
        }
    }

    private func write() async {
        await MainActor.run {
            withAnimation(.timingCurve(0.35, 0, 0.45, 1, duration: 2.0)) {
                erase = 0
                progress = 1
            }
        }
        try? await Task.sleep(nanoseconds: 2_000_000_000)
    }

    /// 擦除：trim 起点 0→1，笔迹像被墨水从开头抽走那样缩短 ——
    /// 比整体淡出更有「pen 提起来收回墨水」的手感。
    /// 擦完无动画归零，下一笔干净开始。
    private func unwrite() async {
        await MainActor.run {
            withAnimation(.timingCurve(0.4, 0, 0.6, 1, duration: 0.7)) {
                erase = 1
            }
        }
        try? await Task.sleep(nanoseconds: 700_000_000)
        await MainActor.run {
            var t = Transaction()
            t.disablesAnimations = true
            withTransaction(t) { erase = 0; progress = 0 }
        }
    }
}

// MARK: - 三幕串场

struct FirstRunFlow: View {
    /// 传入导览页的构造闭包（避免这里直接持有 OnboardingView 的全部状态）
    var onboarding: OnboardingView

    @EnvironmentObject private var settings: BoardSettings
    @State private var stage: Stage
    /// 第三幕进场：blur + 缩放 + 透明度三件套一起缓过来
    @State private var enterOnboard = false

    enum Stage { case splash, hello, onboard }

    init(onboarding: OnboardingView) {
        self.onboarding = onboarding
        // 初始幕直接算好，别等 onAppear 再改 —— 否则「减弱动态」的用户
        // 会先闪到一帧快闪画面。Motion.reduced 是静态可读的，init 里就能判。
        _stage = State(initialValue: Motion.reduced ? .hello : .splash)
    }
    /// 快闪只在真·第一次启动播。引导页可以从设置里重跑（onboarded=false），
    /// 那种时候就不必再看一遍演出 —— 落一个标记区分这两种「没完成引导」。
    static let seenKey = "mb.splash.seen"

    var body: some View {
        ZStack {
            switch stage {
            case .splash:
                // 尊重「减弱动态效果」：整段快闪跳过，直接落到 hello 静态。
                SplashView {
                    stage = .hello
                }
                .transition(.opacity)

            case .hello:
                HelloGreeting {
                    UserDefaults.standard.set(true, forKey: Self.seenKey)
                    stage = .onboard
                }

            case .onboard:
                onboarding
                    .opacity(enterOnboard ? 1 : 0)
                    .scaleEffect(enterOnboard ? 1 : 0.96)
                    .blur(radius: enterOnboard ? 0 : 10)
                    .onAppear {
                        withAnimation(.spring(response: 0.65, dampingFraction: 0.92).delay(0.05)) {
                            enterOnboard = true
                        }
                    }
            }
        }
    }
}
