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
     第二幕 · hello   空心霓虹彩虹「hello」反复书写：样式取用户给的
                      霓虹管字形图（空心玻璃管 + 彩虹辉光 + 波浪尾笔），
                      动效按用户给的书写视频 1:1 复刻 —— 墨点先在起笔处
                      涨起来 → 尾笔甩出 → 回锋 → 匀速写满 → 驻留 →
                      从 h 那头吸干 → 空一拍，如此往复（6.02s 一轮）。
                      快闪一播完，下方就浮出液态玻璃「让我们开始吧」。
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

// MARK: - ② 空心霓虹 hello（逐帧复刻视频笔顺）+ 液态玻璃开始按钮

/// 第二幕的笔顺来源（务必先读）：
/// 用户给了两份素材 —— 一张空心彩虹霓虹「hello」的样式图，和一段
/// 6.02s 的书写动画视频。要求：**样式**取图（空心玻璃管 + 彩虹辉光），
/// **书写/擦除的动效**按视频 1:1 复刻。
///
/// 下面的单笔画路径不是手描的，是从视频里**逐帧追踪笔尖**算出来的：
///   · 每帧取「新增墨迹」的骨架片段（t_first 标定每个像素首次出现的帧）；
///   · 片段按时间顺序链接，交界处用骨架 Dijkstra 寻路；
///   · 最后对视频笔画掩码做 EDT 验收 —— 路径居中（平均 EDT 16.6/管半宽~45），
///     对真实笔迹的覆盖率 95%。笔顺、交叉、回锋全部是视频里真实的写法。
/// 起笔多出的 4 个锚点是样式图里那条波浪尾笔（视频的入笔没有尾巴，
/// 图里有 —— 按图的字形补上，映射到同一坐标系）。

struct HelloGreeting: View {
    var onStart: () -> Void

    @EnvironmentObject private var settings: BoardSettings
    @State private var start: Date? = nil
    @State private var exiting = false
    @State private var buttonIn = false

    /// 连笔「hello」单笔画锚点（Catmull-Rom 拟合成贝塞尔）。
    /// 坐标系无所谓——下面会按包围盒归一化再缩放，只要比例对就行。
    static let rawAnchors: [(Double, Double)] = [
            (14, 393),
            (52, 418),
            (98, 451),
            (126, 415),

            (124, 360),
            (166, 344),
            (187, 305),
            (209, 268),

            (249, 247),
            (266, 206),
            (283, 164),
            (291, 120),

            (278, 78),
            (237, 76),
            (212, 113),
            (201, 157),

            (194, 201),
            (190, 246),
            (191, 291),
            (177, 333),

            (170, 378),
            (165, 422),
            (168, 400),
            (171, 355),

            (185, 312),
            (203, 272),
            (244, 252),
            (287, 255),

            (307, 293),
            (307, 338),
            (305, 383),
            (326, 420),

            (368, 425),
            (412, 415),
            (454, 398),
            (489, 371),

            (517, 336),
            (526, 292),
            (509, 252),
            (466, 245),

            (434, 275),
            (420, 318),
            (422, 362),
            (444, 399),

            (480, 423),
            (525, 428),
            (567, 415),
            (607, 394),

            (641, 368),
            (655, 328),
            (690, 301),
            (712, 261),

            (729, 219),
            (741, 176),
            (747, 132),
            (742, 87),

            (706, 69),
            (675, 99),
            (658, 141),
            (647, 185),

            (640, 229),
            (637, 274),
            (639, 319),
            (641, 364),

            (658, 404),
            (697, 426),
            (741, 424),
            (782, 405),

            (820, 382),
            (829, 338),
            (863, 310),
            (887, 272),

            (905, 231),
            (920, 189),
            (930, 145),
            (930, 100),

            (903, 69),
            (864, 89),
            (844, 129),
            (833, 173),

            (825, 217),
            (820, 262),
            (820, 307),
            (826, 351),

            (834, 394),
            (869, 420),
            (914, 422),
            (956, 406),

            (992, 380),
            (1006, 338),
            (1020, 295),
            (1048, 260),

            (1089, 243),
            (1132, 255),
            (1155, 291),
            (1153, 336),

            (1141, 379)
    ]

    /// Catmull-Rom → 三次贝塞尔，与路径提取脚本完全同参（tension /6）。
    static let helloPath: Path = {
        let pts = rawAnchors.map { CGPoint(x: $0.0, y: $0.1) }
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

    static let pathBounds = helloPath.boundingRect
    static let normalizedPath = helloPath.applying(
        CGAffineTransform(translationX: -pathBounds.minX, y: -pathBounds.minY))

    /// 尾笔（波浪尾巴 + 回锋）占整条路径弧长的比例 —— 书写分段时间用
    static let tailFrac = 0.0455

    /// 霓虹图沿路径采样出的彩虹：紫尾 → 橙红 h → 蓝 e → 玫红 l1 →
    /// 橙黄 l2 → 青蓝 o → 紫甩尾。手动提亮到浅底上也有荧光感。
    private static let rainbow = LinearGradient(
        colors: [
            Color(red: 0.69, green: 0.29, blue: 0.93),   // 紫 · 尾
            Color(red: 0.91, green: 0.36, blue: 0.23),   // 橙红 · h 上冲
            Color(red: 0.94, green: 0.54, blue: 0.24),   // 橙 · h 环顶
            Color(red: 0.89, green: 0.42, blue: 0.68),   // 粉紫 · 肩
            Color(red: 0.36, green: 0.55, blue: 0.95),   // 蓝 · e
            Color(red: 0.48, green: 0.42, blue: 0.94),   // 蓝紫 · e 出
            Color(red: 0.84, green: 0.31, blue: 0.49),   // 玫红 · l1
            Color(red: 0.91, green: 0.51, blue: 0.25),   // 橙 · l1 底
            Color(red: 0.60, green: 0.33, blue: 0.91),   // 紫 · l1→l2
            Color(red: 0.94, green: 0.60, blue: 0.27),   // 橙黄 · l2
            Color(red: 0.35, green: 0.66, blue: 0.95),   // 天蓝 · o 入
            Color(red: 0.31, green: 0.75, blue: 0.97),   // 青蓝 · o 碗
            Color(red: 0.49, green: 0.42, blue: 0.94),   // 蓝紫 · 收口
            Color(red: 0.66, green: 0.35, blue: 0.93),   // 紫 · 甩尾
        ],
        startPoint: .leading, endPoint: .trailing)

    // MARK: 视频时间轴（原片 6.02s 一轮，逐段对齐）
    private enum Cyc {
        static let dotEnd    = 0.62   // 墨点在起笔处涨起来
        static let tailEnd   = 0.92   // 尾笔向左下甩出
        static let retraceEnd = 1.12  // 回锋（沿尾笔原路收回，笔迹不变）
        static let writeEnd  = 2.55   // 主体写完（匀速，与原片一致）
        static let holdEnd   = 4.45   // 写满驻留
        static let eraseEnd  = 5.82   // 从 h 那头吸走（easeInOut）
        static let total     = 6.02   // 空一小拍，回到墨点
    }

    var body: some View {
        GeometryReader { geo in
            ZStack {
                RadialGradient(colors: [FirstRunInk.bgCenter, FirstRunInk.bgEdge],
                               center: .center, startRadius: 80, endRadius: 900)
                    .ignoresSafeArea()
                VStack(spacing: 0) {
                    Spacer(minLength: 0)
                    hello(size: CGSize(width: geo.size.width - 110,
                                       height: geo.size.height * 0.44))
                    Spacer(minLength: 0)
                    startButton
                    Spacer().frame(height: geo.size.height * 0.15)
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .onAppear { boot() }
    }

    // MARK: 时间 → 笔迹进度（全部是 t 的纯函数，冻帧自检的前提）

    /// 书写进度：0 = 未落笔，1 = 写满
    private func progress(_ t: Double) -> Double {
        let f = Self.tailFrac
        if t < Cyc.dotEnd { return 0 }
        if t < Cyc.tailEnd {                                  // 尾笔甩出
            let k = (t - Cyc.dotEnd) / (Cyc.tailEnd - Cyc.dotEnd)
            return f * easeOut(k)
        }
        if t < Cyc.retraceEnd { return f }                    // 回锋：笔画不动
        if t < Cyc.writeEnd {                                 // 主体匀速书写
            return f + (1 - f) * (t - Cyc.retraceEnd) / (Cyc.writeEnd - Cyc.retraceEnd)
        }
        return 1
    }

    /// 擦除进度：0 = 不擦，1 = 从起笔端吸干
    private func erase(_ t: Double) -> Double {
        guard t > Cyc.holdEnd else { return 0 }
        return easeInOut(min(1, (t - Cyc.holdEnd) / (Cyc.eraseEnd - Cyc.holdEnd)))
    }

    /// 墨点：起笔处先涨出一颗墨滴（原片 0.05–0.65s），落笔后收进笔画里
    @ViewBuilder
    private func inkDot(_ t: Double, width w: CGFloat) -> some View {
        let appear = min(1, max(0, (t - 0.05) / (Cyc.dotEnd - 0.05)))
        let sink = min(1, max(0, (t - Cyc.dotEnd) / 0.14))
        let k = (1 - sink) * easeOutBack(appear)
        if k > 0.01 {
            Circle()
                .fill(Self.rainbow)
                .frame(width: w * 0.9, height: w * 0.9)
                .blur(radius: w * 0.16)
                .scaleEffect(k)
                .opacity(0.85 * (1 - sink))
        }
    }

    /// 空心霓虹管：宽晕 → 中晕 → 玻璃管体（正片叠底，交叠处像玻璃一样
    /// 变深）→ 亮芯。亮芯把管芯「掏空」，浅底上读出图里那种玻璃管质感。
    private func hello(size: CGSize) -> some View {
        let bb = Self.pathBounds
        let k = max(0.1, min(size.width / bb.width, size.height / bb.height))
        let w = max(6, size.width * 0.032)                    // 管径随窗口缩放
        return TimelineView(.animation) { ctx in
            // 冻结自检（--hello <0…1>）：helloT 直接给定循环相位
            let t: Double
            if let ht = PreviewFlags.helloT {
                t = ht * Cyc.total
            } else {
                t = start.map { ctx.date.timeIntervalSince($0).truncatingRemainder(dividingBy: Cyc.total) } ?? 0
            }
            let p = progress(t), e = erase(t)
            let trimmed = Self.normalizedPath
                .applying(CGAffineTransform(scaleX: k, y: k))
                .trimmedPath(from: min(e, p), to: max(e, p))
            return ZStack {
                tube(trimmed, width: w * 2.6, blur: 20, opacity: 0.26, blend: .normal)
                tube(trimmed, width: w * 1.55, blur: 8, opacity: 0.40, blend: .normal)
                tube(trimmed, width: w, blur: 0, opacity: 0.72, blend: .multiply)
                tube(trimmed, width: w * 0.42, blur: 0, opacity: 0.55, blend: .normal,
                     fill: Color(red: 1.0, green: 0.99, blue: 0.95))
            }
            .overlay(
                // 墨点画在路径起笔处（裁剪坐标系 (14,393) 归一化后的位置）
                inkDot(t, width: w)
                    .position(x: (14 - bb.minX) * k, y: (393 - bb.minY) * k)
                    .allowsHitTesting(false)
            )
            .frame(width: bb.width * k, height: bb.height * k)
        }
        .scaleEffect(exiting ? 0.94 : 1)
        .blur(radius: exiting ? 8 : 0)
        .offset(y: exiting ? -26 : 0)
        .opacity(exiting ? 0 : 1)
    }

    private func tube(_ path: Path, width: CGFloat, blur: CGFloat, opacity: Double,
                      blend: BlendMode, fill: Color? = nil) -> some View {
        Group {
            if let fill {
                path.stroke(fill, style: StrokeStyle(lineWidth: width, lineCap: .round, lineJoin: .round))
            } else {
                path.stroke(Self.rainbow, style: StrokeStyle(lineWidth: width, lineCap: .round, lineJoin: .round))
            }
        }
        .blur(radius: blur)
        .opacity(opacity)
        .blendMode(blend)
    }

    // MARK: 液态玻璃按钮 —— 快闪一播完就在下方浮起， hello 循环全程在场

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
                .foregroundColor(.primary.opacity(0.85))
                .padding(.horizontal, 36)
                .padding(.vertical, 13)
                .background(Capsule().fill(.ultraThinMaterial))
                .overlay(
                    Capsule().strokeBorder(
                        LinearGradient(colors: [.white.opacity(0.9), .white.opacity(0.12)],
                                       startPoint: .top, endPoint: .bottom),
                        lineWidth: 1)
                )
                .shadow(color: .black.opacity(0.10), radius: 12, y: 4)
                .shadow(color: .white.opacity(0.65), radius: 0.5, y: 0.5)
        }
        .buttonStyle(.plain)
        .scaleEffect(exiting ? 0.96 : 1)
        .offset(y: exiting ? 18 : 0)
        .opacity(exiting ? 0 : (buttonIn ? 1 : 0))
        .disabled(exiting)
    }

    // MARK: 起停

    private func boot() {
        // 冻结模式（离屏自检）：--hello <0…1> 给的是循环相位，按钮直接在场
        if PreviewFlags.helloT != nil {
            buttonIn = true
            return
        }
        if settings.reduceMotion || Motion.reduced {
            start = nil
            buttonIn = true
            return
        }
        start = Date()
        Task {
            try? await Task.sleep(nanoseconds: 400_000_000)
            withAnimation(.easeOut(duration: 0.6)) { buttonIn = true }
        }
    }

    // MARK: 缓动

    private func easeOut(_ k: Double) -> Double { 1 - (1 - k) * (1 - k) }
    private func easeInOut(_ k: Double) -> Double { k * k * (3 - 2 * k) }
    private func easeOutBack(_ k: Double) -> Double {
        let c = 1.70158
        let x = k - 1
        return 1 + (c + 1) * x * x * x + c * x * x
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
