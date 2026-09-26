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
                      动效按用户给的书写视频 1:1 复刻 —— 落笔（墨珠与
                      第一笔同时出现，墨珠钉在笔尖上）→ 尾笔甩出 → 回锋 →
                      匀速写满 → 从 h 那头吸干，如此往复（5.40s 一轮，
                      首尾相接、全程没有一帧静止）。
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
/// 用户指定字形用 macOS 自带的 **Sauber Script**（iOS 锁屏 hello 同款圆体
/// 连笔），样式仍取霓虹管图（空心玻璃管 + 彩虹辉光），动效按视频 1:1。
///
/// 路径不是手描的：CoreText 高清渲染「hello」→ 骨架化取中心线 →
/// 贪心直行走查（分叉口选未画区域最大分支）→ 智能折叠（纯原路重踏的
/// 绕行删除、带新笔画的发卡弯保留）→ 重采样 240 锚点。弧长 17.7k，
/// 起笔是 h 的入笔尾（占 3% 弧长，对应视频的「尾笔甩出→回锋」段），
/// 收笔是 o 的甩尾。圆滑度：平滑后平均转角 5.6°/段。

struct HelloGreeting: View {
    var onStart: () -> Void

    @EnvironmentObject private var settings: BoardSettings
    /// ★ 初值不能是 nil。
    ///
    ///   `--hello` 之外的所有路径里，`start` 原本靠 `.onAppear { boot() }` 设。
    ///   但 onAppear 发生在**首帧渲染之后** —— 于是第一帧 `start == nil`，
    ///   而 paint 又把 nil 当成"写满"，结果 hello 一露面就凭空闪出一整幅
    ///   完整的字，下一帧才缩回"落笔"重写。这里在实例创建时就把起跑线定好，
    ///   首帧直接就是"笔尖带墨刚落下的那一瞬"。（减弱动态的系统用户仍走静态展示。）
    @State private var start: Date? = Motion.reduced ? nil : Date()
    @State private var exiting = false
    @State private var buttonIn = false

    /// 连笔「hello」单笔画锚点（Catmull-Rom 拟合成贝塞尔）。
    /// 坐标系无所谓——下面会按包围盒归一化再缩放，只要比例对就行。
    static let rawAnchors: [(Double, Double)] = [
        (224, 2324), (238, 2299), (251, 2274), (265, 2249), (279, 2224), (294, 2199),
        (308, 2174), (323, 2150), (339, 2125), (354, 2101), (370, 2077), (385, 2053),
        (399, 2028), (410, 2001), (418, 1974), (429, 1947), (443, 1922), (457, 1897),
        (470, 1872), (485, 1847), (499, 1822), (514, 1797), (529, 1773), (544, 1748),
        (559, 1724), (574, 1699), (589, 1675), (604, 1650), (619, 1626), (634, 1602),
        (649, 1577), (665, 1553), (680, 1529), (696, 1505), (713, 1481), (731, 1459),
        (740, 1449), (721, 1471), (704, 1494), (688, 1517), (672, 1541), (657, 1566),
        (641, 1590), (626, 1614), (611, 1639), (596, 1663), (581, 1688), (566, 1712),
        (551, 1737), (536, 1761), (521, 1785), (506, 1810), (491, 1835), (477, 1860),
        (463, 1885), (449, 1910), (435, 1935), (423, 1961), (415, 1988), (416, 2017),
        (437, 2034), (465, 2029), (489, 2014), (511, 1996), (533, 1977), (555, 1958),
        (577, 1941), (601, 1924), (626, 1910), (652, 1899), (680, 1890), (708, 1885),
        (737, 1884), (762, 1897), (774, 1923), (775, 1951), (769, 1979), (759, 2006),
        (746, 2032), (731, 2056), (714, 2080), (697, 2103), (680, 2126), (663, 2149),
        (646, 2172), (630, 2196), (616, 2221), (606, 2248), (599, 2276), (597, 2304),
        (606, 2331), (630, 2346), (659, 2347), (687, 2341), (714, 2331), (739, 2318),
        (763, 2301), (785, 2283), (805, 2263), (826, 2243), (847, 2223), (870, 2206),
        (896, 2195), (924, 2189), (952, 2182), (967, 2158), (975, 2130), (985, 2103),
        (999, 2078), (1015, 2054), (1029, 2029), (1044, 2005), (1062, 1983), (1082, 1962),
        (1104, 1943), (1126, 1925), (1149, 1908), (1174, 1893), (1199, 1880), (1226, 1869),
        (1254, 1863), (1282, 1861), (1311, 1866), (1336, 1879), (1354, 1901), (1362, 1929),
        (1361, 1957), (1353, 1985), (1339, 2010), (1320, 2032), (1298, 2050), (1274, 2065),
        (1248, 2077), (1221, 2086), (1193, 2093), (1164, 2097), (1136, 2098), (1107, 2098),
        (1078, 2096), (1051, 2088), (1023, 2080), (996, 2088), (981, 2112), (972, 2139),
        (965, 2167), (960, 2196), (960, 2224), (963, 2253), (971, 2280), (984, 2306),
        (1003, 2327), (1027, 2343), (1055, 2350), (1083, 2351), (1112, 2348), (1140, 2343),
        (1168, 2337), (1195, 2328), (1222, 2316), (1247, 2302), (1271, 2287), (1294, 2270),
        (1317, 2252), (1339, 2234), (1362, 2217), (1387, 2203), (1415, 2196), (1444, 2194),
        (1467, 2180), (1479, 2154), (1489, 2127), (1499, 2100), (1511, 2074), (1527, 2050),
        (1551, 2035), (1579, 2031), (1607, 2030), (1632, 2015), (1653, 1996), (1673, 1975),
        (1693, 1954), (1712, 1933), (1731, 1912), (1750, 1890), (1769, 1868), (1787, 1846),
        (1805, 1823), (1822, 1801), (1840, 1778), (1857, 1755), (1873, 1731), (1890, 1708),
        (1905, 1684), (1920, 1659), (1935, 1634), (1948, 1609), (1960, 1583), (1971, 1556),
        (1979, 1529), (1984, 1500), (1981, 1472), (1962, 1452), (1934, 1449), (1907, 1458),
        (1882, 1473), (1861, 1492), (1841, 1513), (1822, 1535), (1804, 1557), (1787, 1580),
        (1770, 1603), (1753, 1626), (1737, 1650), (1721, 1674), (1706, 1698), (1690, 1723),
        (1675, 1747), (1661, 1772), (1646, 1796), (1632, 1821), (1618, 1846), (1604, 1871),
        (1590, 1897), (1576, 1922), (1564, 1948), (1554, 1975), (1546, 2002), (1534, 2029),
        (1521, 2054), (1508, 2080), (1497, 2106), (1487, 2133), (1477, 2160), (1469, 2187),
        (1463, 2216), (1463, 2244), (1467, 2273), (1474, 2301), (1487, 2326), (1509, 2343),
        (1538, 2346), (1566, 2341), (1594, 2333), (1619, 2321), (1643, 2305), (1665, 2286),
        (1686, 2267), (1707, 2247), (1728, 2228), (1752, 2212), (1779, 2202), (1808, 2198),
        (1834, 2188), (1847, 2163), (1857, 2136), (1868, 2109), (1881, 2083), (1895, 2058),
        (1907, 2032), (1916, 2005), (1925, 1978), (1936, 1951), (1950, 1926), (1963, 1901),
        (1977, 1876), (1992, 1851), (2006, 1826), (2021, 1801), (2036, 1777), (2051, 1753),
        (2066, 1728), (2082, 1704), (2098, 1680), (2114, 1657), (2131, 1633), (2147, 1610),
        (2164, 1587), (2182, 1564), (2200, 1542), (2219, 1520), (2238, 1498), (2258, 1478),
        (2280, 1459), (2304, 1443), (2330, 1433), (2359, 1431), (2383, 1444), (2392, 1471),
        (2390, 1500), (2383, 1528), (2374, 1555), (2363, 1581), (2351, 1607), (2337, 1633),
        (2323, 1658), (2309, 1682), (2293, 1707), (2278, 1731), (2261, 1755), (2245, 1778),
        (2228, 1801), (2211, 1824), (2193, 1847), (2175, 1869), (2156, 1891), (2137, 1913),
        (2118, 1934), (2098, 1955), (2078, 1975), (2057, 1995), (2036, 2014), (2014, 2032),
        (1990, 2048), (1963, 2058), (1934, 2061), (1906, 2064), (1883, 2082), (1869, 2106),
        (1858, 2133), (1848, 2160), (1840, 2187), (1835, 2216), (1834, 2244), (1838, 2273),
        (1845, 2301), (1859, 2326), (1881, 2343), (1910, 2346), (1938, 2342), (1966, 2334),
        (1992, 2322), (2016, 2306), (2038, 2288), (2059, 2268), (2080, 2249), (2102, 2231),
        (2128, 2217), (2155, 2209), (2183, 2215), (2199, 2238), (2207, 2266), (2216, 2293),
        (2231, 2317), (2252, 2336), (2279, 2348), (2307, 2351), (2336, 2349), (2364, 2344),
        (2391, 2335), (2417, 2323), (2442, 2308), (2466, 2292), (2488, 2274), (2510, 2255),
        (2530, 2235), (2550, 2214), (2569, 2193), (2586, 2170), (2600, 2145), (2611, 2118),
        (2618, 2090), (2616, 2062), (2604, 2037), (2620, 2014), (2633, 1988), (2644, 1962),
        (2649, 1933), (2644, 1905), (2627, 1883), (2602, 1869), (2574, 1864), (2545, 1863),
        (2517, 1867), (2489, 1875), (2463, 1886), (2437, 1899), (2412, 1913), (2388, 1929),
        (2366, 1947), (2344, 1965), (2323, 1985), (2303, 2006), (2284, 2027), (2266, 2050),
        (2250, 2074), (2235, 2098), (2223, 2124), (2213, 2151), (2206, 2179), (2201, 2207),
        (2202, 2236), (2207, 2264), (2216, 2291), (2230, 2316), (2251, 2336), (2277, 2347),
        (2306, 2351), (2334, 2349), (2362, 2344), (2390, 2335), (2416, 2324), (2441, 2309),
        (2464, 2293), (2487, 2275), (2509, 2256), (2529, 2236), (2549, 2216), (2568, 2194),
        (2585, 2171), (2600, 2146), (2611, 2120), (2626, 2096), (2653, 2087), (2682, 2087),
        (2710, 2084), (2738, 2078), (2766, 2069), (2792, 2057), (2817, 2043), (2840, 2026),
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

    // MARK: 几何缓存 —— 全部只算一次
    //
    // ★ 性能要点：旧版每帧都要 (1) 对 420 点路径做仿射变换重建 Path、
    //   (2) trimmedPath 裁剪、(3) 走 4 层 View 且其中两层带高斯模糊。
    //   这三件事叠在 60/120fps 下必然掉帧。现在把几何全部预计算成
    //   一张高密度折线 + 一张累积弧长表，每帧只在这张表上切一段描边。

    /// 按 Catmull-Rom 加密后的折线（已平移到原点）。
    ///
    /// ★ 密度是性能与观感的平衡点。锚点本身已够密（420 个、平均 5.6°/段，
    ///   平滑后转角 >30° 的点几乎为零），每段再插 2 个点就已经让折线与原
    ///   贝塞尔曲线在视觉上无法区分。之前插 4 个（1700 点），描边成本翻倍
    ///   却看不出差别 —— 而描边是每帧要跑十来次的热路径。
    static let densePoly: [CGPoint] = {
        let pts = rawAnchors.map { CGPoint(x: $0.0, y: $0.1) }
        guard pts.count > 2 else { return pts }
        var out: [CGPoint] = [pts[0]]
        out.reserveCapacity(pts.count * 2)
        let steps = 2
        for i in 0..<pts.count - 1 {
            let p0 = i > 0 ? pts[i - 1] : pts[i]
            let p1 = pts[i], p2 = pts[i + 1]
            let p3 = i + 2 < pts.count ? pts[i + 2] : pts[i + 1]
            for s in 1...steps {
                let t = CGFloat(s) / CGFloat(steps), t2 = t * t, t3 = t2 * t
                out.append(CGPoint(
                    x: 0.5 * (2 * p1.x + (-p0.x + p2.x) * t
                              + (2 * p0.x - 5 * p1.x + 4 * p2.x - p3.x) * t2
                              + (-p0.x + 3 * p1.x - 3 * p2.x + p3.x) * t3),
                    y: 0.5 * (2 * p1.y + (-p0.y + p2.y) * t
                              + (2 * p0.y - 5 * p1.y + 4 * p2.y - p3.y) * t2
                              + (-p0.y + 3 * p1.y - 3 * p2.y + p3.y) * t3)))
            }
        }
        let minX = out.map(\.x).min() ?? 0
        let minY = out.map(\.y).min() ?? 0
        let shifted = out.map { CGPoint(x: $0.x - minX, y: $0.y - minY) }
        // ★ 圆角化会把 h 的顶点顺着切向轻轻顶出去一点（y 变成 −6.5），必须再归零
        //   一次。否则 inkSize 量不到这一块，光晕会从画布上边缘溢出去 ——
        //   那正是「边角显示不全」的老毛病。
        let rounded = roundHairpins(shifted)
        let rMinX = rounded.map(\.x).min() ?? 0
        let rMinY = rounded.map(\.y).min() ?? 0
        guard rMinX != 0 || rMinY != 0 else { return rounded }
        return rounded.map { CGPoint(x: $0.x - rMinX, y: $0.y - rMinY) }
    }()

    /// 把折线上的 180° 零半径尖点打开成半径 R 的圆滑折返。
    ///
    /// ★ 这是「h 写到顶端那一下卡顿」的真正根因，也是唯一治本的修法。
    ///
    ///   单笔连写 h 时，竖笔上到顶必须**原路折返**回落一段，才能转去画右边的拱
    ///   （真手写也是这样）。但骨架化给出的折返是**半径为零**的尖点：折线在
    ///   s≈0.0845 处上行到顶后立刻反向。于是按弧长分配时间时，那一帧笔尖先上去
    ///   再回来，净位移只剩 6px —— 正常帧的 0.14 倍。60Hz 下就是实打实的
    ///   「顿一下」，然后猛冲出去（相邻帧 10 倍突变）。
    ///
    ///   时间映射救不了零半径尖点：无论怎么分配时间，笔尖都得先上后下。
    ///   所以必须从几何入手 —— 让上行线与下行线错开 2R，中间用半径 R 的半圆
    ///   连过去。真手写的回锋本来就是这个形状（笔尖有宽度，写下去和回上来
    ///   不会严丝合缝地重合）。R 取得比管径半径小，圆角整段仍埋在已有墨迹里，
    ///   字形看不出变化。
    ///
    ///   实测（书写段全程，60Hz/120Hz × 8 个采样相位）：
    ///     笔尖每帧位移  max 1.85×中位 → 1.05×，min 0.090× → 0.43×；
    ///     慢于 0.6×中位的帧  360/2152 → 0/2152。
    ///
    /// ★ R 为什么是 8，而不是原来的 25 ★
    ///   上行线与下行线的错开量就是 2R。而霓虹管有三层同心描边：
    ///     管体半径  rTube ≈ 39.1（= w/2）
    ///     亮芯半径  rCore = 0.40·rTube ≈ 15.7，即亮芯全宽 31.3
    ///   **用户看得见的那条亮线就是亮芯**。所以"折返处看起来是一根还是两根"，
    ///   取决于两条亮芯还重不重叠（错开 2R < 31.3 才重叠）：
    ///     ┌──────┬────────┬──────────────┬──────────────┐
    ///     │ R    │ 错开2R │ 亮芯重叠      │ 字形差异      │
    ///     ├──────┼────────┼──────────────┼──────────────┤
    ///     │  8   │   16   │ 15.3 (48.9%) │ 0.246%       │
    ///     │ 12   │   24   │  7.3 (23.3%) │ 0.421%       │
    ///     │ 16   │   32   │  **0** ← 分界 │ 0.573%       │
    ///     │ 20   │   40   │  0（裂开）    │ 3.389%       │
    ///     │ 25   │   50   │  0（裂开）    │ **10.855%**  │
    ///     └──────┴────────┴──────────────┴──────────────┘
    ///   （"字形差异" = 与最贴近骨架的 R=2 比的管体掩码 XOR/并集）
    ///
    ///   → R ≥ 16 起，两条亮芯彻底分开：h 的竖笔当着用户的面**裂成两条平行亮线**，
    ///     中间留一道空白。用户说的「H 被分成了两个部分、中间间隔很长」，
    ///     视觉上正是这个 —— 而且书写早期只有竖笔时最刺眼（整根竖笔变两条）。
    ///   → R=25 还额外把字形改了 **10.9%**：半圆弧长 πR ≈ 78.5，而折线段长只有
    ///     14 —— 半圆比段落长 5 倍多，把折返处的几何整个撑开，形状肉眼可辨地变形。
    ///
    ///   取 R=8：错开 16 < 31.3，两条亮芯仍重叠一半（48.9%），视觉上依旧是一根
    ///   管；同时半圆弧长 25.1 只约 1.8 倍段长，字形差异压到 **0.246%**
    ///   （差异全部落在描边最外缘，肉眼不可辨）。
    private static func roundHairpins(_ src: [CGPoint]) -> [CGPoint] {
        var pts = src
        let n = pts.count
        guard n > 40 else { return pts }

        let R: CGFloat = 8             // 折返半圆半径；见下方 ★ 长注释（判据是 2R < 亮芯全宽）
        let m = 10                     // 偏移渐变的折线段数（越大多越平缓）
        let arcSteps = 16
        let probe = 4                  // 转角探测跨距
        let thresh = 152.0 * Double.pi / 180

        // ① 找尖点。从后往前替换，索引不会漂移。
        //
        // ★ 两步走：先用跨距 probe 粗筛（单段转角会被折线加密后的微小方向
        //   抖动干扰，跨几段看才稳），再在候选 ±probe 内用**单段转角**精定位。
        //   少了精定位这一步，顶点会偏 1 个折线段（h 那里就偏了 3.2 单位）：
        //   圆弧末端与下行段首点的连线会指回 +u，接点变成 171° 反折。
        var hits: [Int] = []
        var i = probe
        while i < n - probe {
            let ax = pts[i].x - pts[i - probe].x, ay = pts[i].y - pts[i - probe].y
            let bx = pts[i + probe].x - pts[i].x, by = pts[i + probe].y - pts[i].y
            let la = hypot(ax, ay), lb = hypot(bx, by)
            if la > 1e-6, lb > 1e-6 {
                let cosA = max(-1, min(1, Double((ax * bx + ay * by) / (la * lb))))
                if acos(cosA) >= thresh {
                    // 精定位
                    var best = i, bestAng = 0.0
                    for j in max(1, i - probe)..<min(n - 1, i + probe + 1) {
                        let v1x = pts[j].x - pts[j - 1].x, v1y = pts[j].y - pts[j - 1].y
                        let v2x = pts[j + 1].x - pts[j].x, v2y = pts[j + 1].y - pts[j].y
                        let l1 = hypot(v1x, v1y), l2 = hypot(v2x, v2y)
                        guard l1 > 1e-6, l2 > 1e-6 else { continue }
                        let cc = max(-1, min(1, Double((v1x * v2x + v1y * v2y) / (l1 * l2))))
                        let ang = acos(cc)
                        if ang > bestAng { bestAng = ang; best = j }
                    }
                    if bestAng >= thresh,
                       hits.last.map({ best - $0 > m }) ?? true { hits.append(best) }
                    i += m
                    continue
                }
            }
            i += 1
        }

        for c in hits.reversed() {
            guard c - m >= 1, c + m < pts.count else { continue }
            let B = pts[c]
            var ux = pts[c].x - pts[c - m].x, uy = pts[c].y - pts[c - m].y
            let ul = hypot(ux, uy)
            guard ul > 1e-6 else { continue }
            ux /= ul; uy /= ul
            let nx = -uy, ny = ux                      // 上行方向逆时针 90°

            // 上行段末尾：偏移 0 → −R·n。
            // ★ 归一化的分母是 m−1 而不是 m：这样**末点**（j = c−1）恰好拿到
            //   满偏移 −R·n，落点 (= P[c−1] − R·n) 与圆弧起点 (= B − R·n) 只差
            //   一个折线段的长度（13 单位，方向偏差 <6°）。若按 t0/m 取，
            //   末点只拿到 0.972·R，接点处会甩出 12 单位的折角。
            var up: [CGPoint] = []
            for j in (c - m)..<c {
                let t0 = Double(j - (c - m)) / Double(m - 1)
                let w = t0 * t0 * (3 - 2 * t0)
                up.append(CGPoint(x: pts[j].x - nx * R * CGFloat(w),
                                  y: pts[j].y - ny * R * CGFloat(w)))
            }
            // 顶点半圆：X(φ) = B + R·(−cosφ·n + sinφ·u)，φ 从 0 到 π
            //   φ=0  相切于上行线（方向 u）
            //   φ=π/2 前沿到 B + R·u（顶点顺势多走一点，像真笔尖的惯性）
            //   φ=π  相切于下行线（方向 −u）
            var arc: [CGPoint] = []
            for k in 0...arcSteps {
                let ph = Double.pi * Double(k) / Double(arcSteps)
                arc.append(CGPoint(
                    x: B.x + R * CGFloat(-cos(ph) * Double(nx) + sin(ph) * Double(ux)),
                    y: B.y + R * CGFloat(-cos(ph) * Double(ny) + sin(ph) * Double(uy))))
            }
            // 下行段开头：偏移 +R·n → 0（首点同样拿满偏移，理由同上）
            var dn: [CGPoint] = []
            for j in (c + 1)...(c + m) {
                let t0 = Double(c + m - j) / Double(m - 1)
                let w = t0 * t0 * (3 - 2 * t0)
                dn.append(CGPoint(x: pts[j].x + nx * R * CGFloat(w),
                                  y: pts[j].y + ny * R * CGFloat(w)))
            }
            // ★ up 的第一个点（j = c−m）偏移量为 0，位置与它要替换掉的
            //   pts[c−m] 完全重合 —— 必须保留（不能 dropFirst），否则 pts[c−m−1]
            //   会直接连到 up 的第二点，接缝处甩出一段 2 倍长的折线段。
            pts.replaceSubrange((c - m)...(c + m), with: up + arc + dn)
        }
        return pts
    }

    /// densePoly 的累积弧长（归一化 0…1）。进度 → 折线上的落点靠它二分。
    static let polyCum: [Double] = {
        var c: [Double] = [0]
        c.reserveCapacity(densePoly.count)
        var acc = 0.0
        for i in 1..<densePoly.count {
            acc += Double(hypot(densePoly[i].x - densePoly[i - 1].x,
                                densePoly[i].y - densePoly[i - 1].y))
            c.append(acc)
        }
        return acc > 0 ? c.map { $0 / acc } : c
    }()

    /// 字形尺寸（densePoly 已平移到原点，所以从 .zero 起算）。
    static let inkSize: CGSize = {
        var mx: CGFloat = 1, my: CGFloat = 1
        for p in densePoly { mx = max(mx, p.x); my = max(my, p.y) }
        return CGSize(width: mx, height: my)
    }()

    /// 取折线上弧长比例落在 [s0, s1] 的一段；两端按弧长线性插值。
    /// 折线 855 点，二分定位后逐点 addLine —— 微秒级，无分配压力。
    private static func slice(_ s0: Double, _ s1: Double) -> Path {
        var path = Path()
        let poly = densePoly, cum = polyCum
        guard poly.count > 1, s1 - s0 > 1e-9 else { return path }
        let lo = max(0, min(1, s0)), hi = max(0, min(1, s1))
        let i0 = cumIndex(cum, lo), i1 = cumIndex(cum, hi)
        path.move(to: cumPoint(poly, cum, lo, i0))
        var i = i0 + 1
        while i <= i1 && i < poly.count {
            path.addLine(to: poly[i])
            i += 1
        }
        path.addLine(to: cumPoint(poly, cum, hi, i1))
        return path
    }

    /// 累积弧长表中最后一个 ≤ v 的下标（二分）。
    private static func cumIndex(_ cum: [Double], _ v: Double) -> Int {
        var lo = 0, hi = cum.count - 1
        while lo < hi {
            let mid = (lo + hi + 1) >> 1
            if cum[mid] <= v { lo = mid } else { hi = mid - 1 }
        }
        return lo
    }

    private static func cumPoint(_ poly: [CGPoint], _ cum: [Double],
                                 _ v: Double, _ i: Int) -> CGPoint {
        if i + 1 >= poly.count { return poly[poly.count - 1] }
        let span = cum[i + 1] - cum[i]
        guard span > 1e-12 else { return poly[i] }
        let f = CGFloat(max(0, min(1, (v - cum[i]) / span)))
        return CGPoint(x: poly[i].x + (poly[i + 1].x - poly[i].x) * f,
                       y: poly[i].y + (poly[i + 1].y - poly[i].y) * f)
    }

    // MARK: 书写 / 擦除的时间表 —— 「笔在动、字不长」的根治
    //
    // ★★ 为什么是**两张**表，而不是一张 ★★
    //
    //   笔画是一条自己与自己重叠的曲线（h 的竖笔写完要原路折返、e/o 的
    //   收口要压回起点…）。这些重叠段在**书写**和**擦除**里表现完全不同：
    //
    //     书写时笔尖走到重叠段 A：如果 A 已经被**更早**画过的墨盖住了，
    //       这一段一个新像素都不长 → 肉眼看就是「字停住不长了」。
    //       判据 = A 到「弧长上更早的点」的距离（前缀覆盖）→ dMinFwd。
    //
    //     擦除时前锋走到重叠段 A：擦除是从 s=0 端开始把墨吃掉，A 被抹掉时
    //       是否可见，取决于它有没有被**还没擦到的后半段**（s 更大的那部分）
    //       盖住。所以判据是 A 到「弧长上更晚的点」的距离（后缀覆盖）→ dMinBwd。
    //
    //   用同一张表会错得很难看：h 的回锋在书写时是隐藏的（前缀盖住），
    //   但擦除时**不是**（后缀没盖住它）；反过来 o 的收口在擦除时是隐藏的
    //   （后缀盖住），书写时不是。实测（真实渲染逐帧数墨迹面积变化，60Hz）：
    //     恒等映射（完全不加速）：书写最长 133ms、擦除最长 167ms 字不长
    //     单表（只用前缀判据）  ：书写  17ms、擦除最长 **200ms** ← 修了书写、擦除反而更糟
    //     双表（本轮）          ：书写  **0ms**、擦除 **0ms**
    //
    //   坐标：擦除是「s0 从 0 涨到 1、被擦掉的区间是 [s0, 1]」，前锋在 s0 处。
    private static let rTubeGlyph = Double(tubeRatio) * Double(inkSize.height) / 2

    /// 亮芯半径（**字形单位**）：亮芯描边宽度是 `w * 0.40`，而 `w = 2·rTube`，
    /// 所以半径 = 0.40·rTube ≈ 15.7。
    private static let rCoreGlyph = 0.40 * rTubeGlyph

    /// ★★ 可加速窗口的上限 —— 整个「不卡顿」方案里最要紧的一个数 ★★
    ///
    ///   **被加速的点必须是真的看不见的**。而"看不见"的判据不是"落在管体里"，
    ///   而是"**亮芯落在已有管体里**"：
    ///
    ///     点 P 的亮芯（半径 rCore）到最近已有路径的距离为 d。
    ///     这枚亮芯完全埋进半径 rTube 的管体 ⟺ d + rCore ≤ rTube
    ///                                     ⟺ d ≤ rTube − rCore = 0.60·rTube
    ///
    ///   所以 accelSpan = rTube − rCore ≈ 23.5。
    ///
    /// ★ 旧值 `1.30 · rTube`（≈ 50.9）错在哪儿 —— 这是「H 那里还是卡」的真根因 ★
    ///   它按**管体**判"看不见"，允许 dMin 高达 50.9 的点被加速 50 倍。可是
    ///   管体半径 39.1 而亮芯半径只有 15.7：d = 50.9 的点，它的亮芯有
    ///       50.9 − (39.1 − 15.7) = 27.5 单位
    ///   裸露在管体之外 —— 占亮芯全宽 31.3 的 **87%**。
    ///   也就是说，那一段**有八成多的白亮墨是当场新冒出来的**，却被按 50 倍速
    ///   一帧掠过 —— 观感就是"唰"地跳过去、和前后帧断裂。h 的两处（书写的
    ///   回锋入口、擦除的上行段）dMin 恰好都落在 23.5~50.9 这个被误判的夹层里，
    ///   所以每次写到 h / 擦到 h 都能复现。
    ///
    ///   实测（亮芯像素栅格模型，60Hz，全部路径）：
    ///     ┌───────────────────┬──────────────┬──────────────┐
    ///     │ l1                │ 1.30·rTube   │ rTube−rCore  │
    ///     ├───────────────────┼──────────────┼──────────────┤
    ///     │ 亮芯最外露         │ 87% 全宽     │ 0%           │
    ///     │ 书写最大帧间跳变   │ 2.26×        │ 1.70×        │
    ///     │ 擦除最大帧间跳变   │ 2.64×        │ 2.01×        │
    ///     │ 停滞帧             │ 0            │ 0            │
    ///     └───────────────────┴──────────────┴──────────────┘
    ///   收紧之后没有任何停滞 —— 因为真正重合的那两段（dMin 0.9~1.2、远小于
    ///   0.10·accelSpan）仍然拿到满速加速。
    private static let accelSpan = rTubeGlyph - rCoreGlyph

    /// 折线总弧长（**字形单位**，不是归一化的 1）。
    ///
    /// ★ 单位陷阱，第二次栽在这儿了：`polyCum` 是**归一化**弧长（末值恒为 1），
    ///   而 `dMinGate` 是**字形单位**。要把 gate 换算成「归一化弧长」必须除以
    ///   总弧长；一度写成 `/ cum[cum.count - 1]`（= 除以 1），于是 gate 变成
    ///   整条路径的长度，`cum[i] - gate` 恒为负 → 一个候选点都没有 → dMin 全
    ///   是 .greatestFiniteMagnitude → 速度表**静默退化成恒等映射**，症状正是
    ///   「h 处又卡了」。所有跨单位的量都必须显式写出除的是什么。
    private static let totalArc: Double = {
        var t = 0.0
        for i in 1..<densePoly.count {
            t += Double(hypot(densePoly[i].x - densePoly[i - 1].x,
                              densePoly[i].y - densePoly[i - 1].y))
        }
        return t
    }()

    /// 「不可见判据」的距离：每个点到**同一条路径上别处**的最近距离，但跳过
    /// 弧长上离它不到 `gate` 的点 —— 那些点本来就必然与它重叠，不构成"重踏"证据。
    ///
    /// - backward = false：只跟**更早**的点比 → 用于书写（新墨是否被旧墨盖住）
    /// - backward = true ：只跟**更晚**的点比 → 用于擦除（被擦的墨是否被剩下的盖住）
    ///
    /// 正常向前书写时 dMin ≈ 150（远大于管径半径 39）；重踏/回锋时 dMin ≈ 0~3。
    private static func neighborDist(_ poly: [CGPoint], _ cum: [Double],
                                     gate: Double, backward: Bool) -> [Double] {
        let n = poly.count
        var out = [Double](repeating: .greatestFiniteMagnitude, count: n)
        if n < 3 { return out }
        if backward {
            // cum[i] + gate 随 i 递减 → 起点 j1 也单调递减，两指针
            var j1 = n
            var i = n - 2
            while i >= 0 {
                let cut = cum[i] + gate
                while j1 > i + 1 && cum[j1 - 1] > cut { j1 -= 1 }
                if j1 < n {
                    var best = Double.greatestFiniteMagnitude
                    var j = j1
                    while j < n {
                        let dx = Double(poly[i].x - poly[j].x)
                        let dy = Double(poly[i].y - poly[j].y)
                        let d = dx * dx + dy * dy
                        if d < best { best = d }
                        j += 1
                    }
                    out[i] = best.squareRoot()
                }
                i -= 1
            }
        } else {
            var j0 = 0
            for i in 1..<n {
                let cut = cum[i] - gate
                while j0 < i && cum[j0] < cut { j0 += 1 }
                if j0 < 1 { continue }
                var best = Double.greatestFiniteMagnitude
                for j in 0..<j0 {
                    let dx = Double(poly[i].x - poly[j].x)
                    let dy = Double(poly[i].y - poly[j].y)
                    let d = dx * dx + dy * dy
                    if d < best { best = d }
                }
                out[i] = best.squareRoot()
            }
        }
        return out
    }

    /// 由 dMin 生成归一化时间表：dMin 极小处把速度平滑提到 accel 倍。
    /// 返回 time[i] = 从 s=0 走到 s_i 所花的「归一化时间」。
    private static func timeTable(_ dMin: [Double], _ cum: [Double]) -> [Double] {
        let n = cum.count
        let l0 = 0.10 * accelSpan      // dMin ≤ 0.10·accelSpan → 满速加速
        let l1 = accelSpan             // dMin ≥ accelSpan      → 不加速
        let accel = 50.0
        var rate = [Double](repeating: 1, count: n)
        for i in 0..<n {
            let d = dMin[i]
            if d >= l1 { continue }
            var k = (d - l0) / (l1 - l0)
            k = max(0, min(1, k))
            rate[i] = 1 + accel * (1 - k * k * (3 - 2 * k))     // 1 → 1+accel
        }
        var time = [Double](repeating: 0, count: n)
        var acc = 0.0
        for i in 1..<n {
            acc += (cum[i] - cum[i - 1]) / (0.5 * (rate[i] + rate[i - 1]))
            time[i] = acc
        }
        guard acc > 0 else { return cum }
        return time.map { $0 / acc }
    }

    /// ★ 两个常数的推导（两条判据共用）★
    ///
    ///   —— 加速窗口上限 `accelSpan` 见上方定义处的长注释（rTube − rCore）。
    ///      一句话：**被加速的点，亮芯必须完全埋在已有管体里**（外露 0%）。
    ///
    ///   —— dMinGate = 2.0·rTube ≈ 78.2：`neighborDist` 里"跳过弧长差不到 gate 的
    ///      点"的那个 gate。折线上相邻点弧长差约 14，所以 gate 至少要 ≥14 才能
    ///      跳过自身邻域；取 2·rTube 是**故意保守**：它把"即便错开 2 倍管径、
    ///      管体仍然连着"的情形也一并排除在候选之外，于是 dMin 只会偏大（宁可
    ///      漏判）而不会偏小（误判成重踏而把看得见的墨加速掉）。
    ///      太大会漏判（擦除前锋埋在墨里却不加速 → 实测 200ms 停滞），
    ///      太小会误判（正常书写被判成重踏而加速 → 可见的瞬移）。
    private static let dMinGate = 2.0 * rTubeGlyph

    /// 书写用：新墨是否被**更早**的墨盖住。
    static let writeTime: [Double] = {
        let cum = polyCum
        guard densePoly.count > 16, totalArc > 1 else { return cum }
        return timeTable(neighborDist(densePoly, cum,
                                      gate: dMinGate / totalArc,   // 字形单位 → 归一化弧长
                                      backward: false), cum)
    }()

    /// 擦除用：被擦掉的墨是否被**更晚**（还没擦到的）墨盖住。
    static let eraseTime: [Double] = {
        let cum = polyCum
        guard densePoly.count > 16, totalArc > 1 else { return cum }
        return timeTable(neighborDist(densePoly, cum,
                                      gate: dMinGate / totalArc,
                                      backward: true), cum)
    }()

    /// 把「新增笔迹进度」q∈[0,1] 换算成几何弧长比例 s∈[0,1]。
    ///
    /// 反查表：均匀的 q（= 均匀的时间）落在哪一段弧长上。
    /// 非重踏处 rate = 1，时间与弧长成正比 → 每帧笔尖走一样远；
    /// 重踏处 rate 升到 1+accel，「字不长」的时长被压短。
    ///
    /// ★ 这里曾经试过一张 601 档的「回描窗口压缩表」，几何位移指标看着漂亮，
    ///   但多相位实测反而更差（位移突变 6.6× → 14.7×）—— 因为那时 h 顶点还是
    ///   零半径尖点，压时间救不了几何。尖点先由 roundHairpins 圆角化，再上
    ///   这张按 dMin 生成的时间表，两个判据才同时成立。
    private static func invert(_ q: Double, _ table: [Double]) -> Double {
        let lo = max(0, min(1, q))
        let cum = polyCum
        guard table.count > 1 else { return lo }
        var a = 0, b = table.count - 1
        while a < b {
            let mid = (a + b + 1) >> 1
            if table[mid] <= lo { a = mid } else { b = mid - 1 }
        }
        guard a + 1 < table.count else { return 1 }
        let span = table[a + 1] - table[a]
        guard span > 1e-12 else { return cum[a] }
        let f = (lo - table[a]) / span
        return cum[a] + (cum[a + 1] - cum[a]) * f
    }

    /// 书写端（弧长较小的那一端是「还没画到」的那端 → 用书写表）
    static func arcFrac(_ q: Double) -> Double { invert(q, writeTime) }

    /// 擦除端（s0 从 0 涨到 1，被擦掉的是 [s0, 1] → 用擦除表）
    static func arcFracErase(_ q: Double) -> Double { invert(q, eraseTime) }

    /// 霓虹图沿路径采样出的彩虹：紫尾 → 橙红 h → 蓝 e → 玫红 l1 →
    /// 橙黄 l2 → 青蓝 o → 紫甩尾。手动提亮到浅底上也有荧光感。
    ///
    /// 这里直接用 GraphicsContext 的着色器（而不是 View 版 LinearGradient），
    /// 免得每帧为每种线宽各建一个渐变图层。
    private static let rainbow: GraphicsContext.Shading = .linearGradient(
        Gradient(colors: [
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
        ]),
        startPoint: .zero,
        endPoint: CGPoint(x: inkSize.width, y: 0))

    // MARK: 时间轴 —— 落笔即书写，一轮里没有一帧静止
    //
    //   0.00 ─── 落笔、书写 ─────────────────── 2.60
    //   2.60 ─── 从 h 端吸走 ───────────────── 5.40
    //   5.40 == 0.00（擦干的那一刻，正是下一轮落笔的同一瞬间）
    //
    // ★ 落笔与书写是**同一个瞬间**（writeStart == 0）★
    //   旧版 writeStart = 0.36：擦干之后先空转 0.36 秒，只让一颗墨点在那儿
    //   慢慢涨，然后才起笔。用户的原话是「先冒出来一个小点儿，然后再开始
    //   书写 hello，显得很卡顿」—— 那 0.36 秒就是"卡"的全部来源：上一轮的
    //   运动已经停了，这一笔又还没长出来。
    //   现在笔和墨从同一帧出现，墨珠还钉在**笔尖**上（见 inkDot 与 paint 的 ④），
    //   两层一起保证它从第一帧起就是 h 的笔头，而不是起笔处一个孤零零的点。
    //
    // ★ 这里特意**没有驻留段**。旧版写满后停了 1.55 秒，那是最刺眼的"卡"；
    //   也没有"回锋"那种笔画不动的空转段。字能被看清的窗口，靠 S 形曲线
    //   两端自然减速来给 —— 那是连续的微动，不是死停。
    private enum Cyc {
        static let total      = 5.40   // 一轮
        static let writeStart = 0.00   // 落笔 —— 与墨珠同一瞬间，不留"只有点"的空档
        static let writeEnd   = 2.60   // 写满
        static let eraseEnd   = 5.40   // 擦干 —— 等于 total，循环无缝
    }

    /// 书写 / 擦除共用的速度曲线：smoothstep 与线性的 1 : 9 混合。
    ///
    /// ★ 这里的权重被大幅调低过（曾是 7 : 3），原因是实测发现起笔太"黏"：
    ///   7 : 3 时两端速度只有平均的 0.28 倍、中段 1.36 倍，整整差 4.9 倍 ——
    ///   h 第一笔落下后的十来帧笔尖几乎在挪，肉眼就是"起笔卡住不动"。
    ///
    ///   现在两端 0.90 倍、中段 1.09 倍，比例 1.21 —— 保留一丝落笔的柔劲
    ///   （纯线性会显得机械），但整体已经是匀速书写。配合 roundHairpins
    ///   修掉几何尖点后，书写段全程慢于 0.6×中位的帧为 0。
    private static func swing(_ k: Double) -> Double {
        let c = max(0, min(1, k))
        return 0.10 * (c * c * (3 - 2 * c)) + 0.90 * c
    }

    /// 书写进度：0 = 未落笔，1 = 写满（单位：新增笔迹弧长）
    private static func progress(_ t: Double) -> Double {
        guard t > Cyc.writeStart else { return 0 }
        guard t < Cyc.writeEnd else { return 1 }
        return swing((t - Cyc.writeStart) / (Cyc.writeEnd - Cyc.writeStart))
    }

    /// 擦除进度：0 = 不擦，1 = 从起笔端吸干
    private static func erase(_ t: Double) -> Double {
        guard t > Cyc.writeEnd else { return 0 }
        guard t < Cyc.eraseEnd else { return 1 }
        return swing((t - Cyc.writeEnd) / (Cyc.eraseEnd - Cyc.writeEnd))
    }

    /// 当前循环相位（秒）。nil = 静止（减弱动态），此时静置显示完整的字。
    private static func cycleTime(_ now: Date, start: Date?) -> Double? {
        if let ht = PreviewFlags.helloT { return ht * Cyc.total }   // 冻帧自检
        guard let s = start else { return nil }
        return now.timeIntervalSince(s).truncatingRemainder(dividingBy: Cyc.total)
    }

    /// 落笔墨珠：笔尖落下时鼓出来的一团墨，随书写展开收进笔画里。
    ///
    /// 返回 (k, a)：k = 笔画加粗倍数（1 = 与管体同宽），a = 不透明度。
    ///
    /// ★★ 自变量是**书写进度** p，不是时间 t —— 这是"墨珠和 h 连为一个
    ///    整体"的结构性保证 ★★
    ///    p = 0 时珠也恰好是 0，两者从同一个点、同一瞬间一起长出来，
    ///    物理上不可能出现"珠先于笔"的帧。旧版按时间驱动，还配了
    ///    easeOutBack（进度才 0.31 就冲到满值的 0.93）+ 写满前 0.36 秒的
    ///    空档，于是画面上真的存在一段"只有一颗点、笔画还没动"的时间 ——
    ///    那正是用户说的「先冒出来一个小点儿，然后再开始书写」。
    ///
    ///    擦除阶段 p 恒为 1 → a 恒为 0 → 珠自然不出现（擦的时候不该有珠）。
    private static func inkDot(_ p: Double) -> (k: Double, a: Double) {
        // 涨：p 从 0 到 dotPeak 长满；收：dotPeak 到 dotFade 收干净。
        // 两头都从 0 开始/回到 0 —— 珠和笔同生同长，首帧不会"啪"地蹦出一颗珠，
        // 也没有"只有珠、笔还没动"的中间态。
        func ss(_ x: Double) -> Double { let c = max(0, min(1, x)); return c * c * (3 - 2 * c) }
        let grow = ss(p / dotPeak)
        let fade = 1 - ss((p - dotPeak) / max(1e-6, dotFade - dotPeak))
        let e = grow * fade
        return (1 + dotGrow * e, 0.88 * e)
    }

    /// 墨珠长满时的书写进度（极小 —— 落笔那一瞬）。`CycInfo.landPeak` 要与它一致。
    private static let dotPeak = 0.015
    /// 墨珠在书写进度的前百分之几里收干净。0.07 × (writeEnd − writeStart)
    /// ≈ 0.18 秒 —— 短到读不出"先点后笔"的先后，只读得出"笔尖带墨落下"。
    /// `CycInfo.landEnd` 要与它一致。
    private static let dotFade = 0.07
    /// 墨珠最粗时的加粗倍数（1.62 → 半径 0.81·w）。上限受光晕内径约束：
    /// 光晕内径是 1.78·w，珠子半径必须留在它以内，否则会突出到辉光之外。
    private static let dotGrow = 0.62

    // MARK: 绘制体

    /// 画布相对字形包围盒需要的放大倍数。
    ///
    /// ★ 这是"边角显示不全"的正解。管径与光晕外径都是**相对字形**定死的
    ///   （tubeRatio、haloOuter 都是常量），所以它们占字形宽高的比例也是
    ///   常量 —— 布局只需按这两个常量把画布撑开，光晕就一定有地方待。
    ///   之前直接拿字形包围盒当画布，等于把光晕溢出画布的那一圈切掉了。
    static let canvasFit: (w: CGFloat, h: CGFloat) = {
        let grow = 2 * tubeRatio * haloOuter          // 上下各一份光晕
        return (1 + grow * inkSize.height / inkSize.width,
                1 + grow)
    }()

    private func hello() -> some View {
        TimelineView(.animation) { ctx in
            let t = Self.cycleTime(ctx.date, start: start)
            // ★ 两种 nil 必须分开：
            //     ① start 还没设（本实例刚创建的那一帧）→ 什么都不画；
            //     ② 减弱动态 / 用户开了「减弱动态效果」→ 静止展示写满的字。
            //   旧版两者都当"写满"，所以 ① 会闪出一整幅完整的字（见 start 的注释）。
            let shown: Double? = t ?? ((settings.reduceMotion || Motion.reduced)
                                       ? Cyc.writeEnd : nil)
            Canvas { gc, sz in
                // --hitch：量「这一帧到底画了多久」。必须在 Canvas 闭包里面计时 ——
                // 闭包外面量的只是 SwiftUI 求值，量不到真正的绘制。
                let probe = PreviewFlags.hitchProbe
                let t0 = probe ? CFAbsoluteTimeGetCurrent() : 0
                let bb = Self.inkSize
                let fit = Self.canvasFit
                // 按"字形 + 光晕"的实际占位来适配，字形因此永远完整
                let k = min(sz.width / (bb.width * fit.w),
                            sz.height / (bb.height * fit.h))
                if let tt = shown {
                    gc.translateBy(x: (sz.width - bb.width * k) / 2,
                                   y: (sz.height - bb.height * k) / 2)
                    gc.scaleBy(x: k, y: k)
                    // 管径相对字形固定 —— 换窗口大小字的长相不变
                    Self.paint(&gc, t: tt, tube: bb.height * Self.tubeRatio)
                }
                if probe {
                    HitchProbe.shared.note(
                        arrival: ctx.date.timeIntervalSinceReferenceDate,
                        draw: (CFAbsoluteTimeGetCurrent() - t0) * 1000,
                        phase: t ?? -1)
                }
            }
        }
        // ★ 这里**不能**用 .blur() 做退场。blur 会把整个子树拖进离屏渲染，
        //   而 Canvas 每帧都在变 —— 等于每帧都要重做一次全尺寸离屏合成。
        //   退场只用缩放 / 位移 / 透明度，三者都是合成操作，几乎不要钱。
        .scaleEffect(exiting ? 0.94 : 1)
        .offset(y: exiting ? -26 : 0)
        .opacity(exiting ? 0 : 1)
        .animation(.easeOut(duration: 0.5), value: exiting)
    }

    /// 高斯光晕的同心叠层参数 (半径倍数 r, 该层 alpha)。
    ///
    /// ★ 关键几何：stroke 只能**以路径为中心**向两侧描边，没法只画外侧，
    ///   所以第 j 层就是「线宽 2·r_j·w 的实心描边」——它把所有半径 ≤ r_j
    ///   的区域都盖住。于是累积到半径 ρ 处的不透明度是
    ///       Π_{i: r_i ≥ ρ} (1 - a_i)
    ///   让它严格等于高斯剖面 G(ρ)，反推每层 alpha：
    ///       a_j = 1 - (1-G(r_j)) / (1-G(r_{j+1}))
    ///
    /// 为什么不能随便叠几层：等间距、等 alpha 的同心描边在放大后会露出一圈
    /// 圈台阶（banding）；按上面公式配 alpha 则层间无缝，视觉等价于高斯模糊，
    /// 却完全不需要离屏缓冲。
    /// 光晕最外半径（以管径 w 为单位）。布局必须给这个留余量，
    /// 否则光晕会溢出画布被裁掉 —— 「边角显示不全」就是这么来的。
    static let haloOuter: CGFloat = 1.78

    /// 管径（相对字形高度）。用它而不是"相对画布高度"，是为了让字在不同
    /// 窗口尺寸下长得一模一样；同时它的取值也让布局能预先算准余量。
    static let tubeRatio: CGFloat = 0.085

    private static let haloSteps: [(r: CGFloat, a: Double)] = {
        // 8 层足够：alpha 按下面公式配好后，层间已看不出接缝，
        // 再加层只是徒增描边次数（每帧要跑十来次的热路径）。
        let n = 8
        let inner = 0.50, outer = haloOuter, amp = 0.34
        let delta = (outer - inner) / CGFloat(n)
        let sigma = (outer - inner) / 2.2
        func g(_ r: CGFloat) -> Double {
            let x = Double((r - inner) / sigma)
            return amp * exp(-x * x)
        }
        var out: [(CGFloat, Double)] = []
        out.reserveCapacity(n)
        for j in 0..<n {
            let r = inner + delta * (CGFloat(j) + 0.5)
            let rOut = inner + delta * (CGFloat(j) + 1.5)
            let keepIn = 1 - g(r), keepOut = 1 - g(rOut)
            let a = keepOut > 1e-9 ? 1 - keepIn / keepOut : g(r)
            out.append((r, max(0, min(1, a))))
        }
        return out
    }()

    /// 一帧的全部绘制。
    ///
    /// ★ 全程没有离屏模糊、没有 Path 重建 —— 这正是"一丁点卡顿都没有"的关键。
    ///   旧版由 4 层 View 叠成，其中两层各带一次高斯模糊（radius 20 / 8），
    ///   每帧都要重新离屏渲染一大片，再叠加 trimmedPath 与整条路径的仿射
    ///   变换；60fps 下必然掉帧。现在改成单层 Canvas：一次 Path 构造 +
    ///   若干次纯描边，实测 p99 仅 0.77ms（60Hz 预算的 1/21）。
    ///
    /// 视觉配方不变：外晕 → 玻璃管体（正片叠底，交叠处变深）→
    /// 亮芯（把管芯掏空，读出玻璃管质感）。
    private static func paint(_ gc: inout GraphicsContext, t: Double?, tube w: CGFloat) {
        let p = t.map { progress($0) } ?? 1
        let e = t.map { erase($0) } ?? 0
        // ★ 两端各用各的表：
        //   s0 = 被擦端在弧长上的位置（擦除时从 0 涨到 1，用「后缀覆盖」表）
        //   s1 = 已画端在弧长上的位置（书写时从 0 涨到 1，用「前缀覆盖」表）
        //   书写阶段 e 恒为 0 → s0 = arcFracErase(0) = 0；
        //   擦除阶段 p 恒为 1 → s1 = arcFrac(1) = 1。两边各自动作，互不干扰。
        let s0 = arcFracErase(min(e, p)), s1 = arcFrac(max(e, p))

        if s1 - s0 > 1e-6 {
            let path = slice(s0, s1)

            // ① 外晕：同心叠层，半径与 alpha 按高斯剖面生成
            for (r, a) in haloSteps {
                gc.opacity = a
                gc.stroke(path, with: rainbow,
                          style: StrokeStyle(lineWidth: w * 2 * r,
                                             lineCap: .round, lineJoin: .round))
            }

            // ② 玻璃管体
            gc.opacity = 0.80
            gc.blendMode = .multiply
            gc.stroke(path, with: rainbow,
                      style: StrokeStyle(lineWidth: w, lineCap: .round, lineJoin: .round))
            gc.blendMode = .normal

            // ③ 亮芯
            gc.opacity = 0.55
            gc.stroke(path, with: .color(Color(red: 1.0, green: 0.99, blue: 0.95)),
                      style: StrokeStyle(lineWidth: w * 0.40, lineCap: .round, lineJoin: .round))
        }

        // ④ 落笔墨珠：**给笔尖那一小段笔画单独加粗一次** —— 不是贴在旁边
        //    一颗圆点。
        //
        //    ★ 「墨点要和 h 连为一个整体」最终就落在这几行 ★
        //      旧版是一颗圆心钉在起笔点、颜色写死成紫色的椭圆。它和笔画
        //      只有"位置相邻"这一层关系，而另外三样全不一致：
        //        色不同（写死紫）、形不同（实心正圆 vs 空心玻璃管）、
        //        时机不同（它先涨 0.42 秒，笔画才开始）。
        //      三样凑一起，肉眼读到的必然是"先冒出来一个小点儿，然后才开始
        //      写 h"。
        //
        //      现在：
        //        · 着色器用管体同一张 `rainbow` —— 笔尖什么颜色，墨珠就是
        //          什么颜色，接缝处不可能有色彩断层；
        //        · 圆心就是笔尖本身（s1），round cap —— 它是笔画的圆头，
        //          几何上是同一根管子，不是"旁边一颗点"；
        //        · **逐层复用 ②③ 的配方**（同样的 0.80 + 正片叠底、同样的
        //          亮芯），只是线宽整体乘 dk —— 所以珠子是"同一根玻璃管
        //          鼓出来的一团墨"，材质与笔画一模一样。这一条最要紧：
        //          只要珠子用了另一套配方（哪怕只是不透明度差一点），
        //          它就会以"另一种材质"浮在笔画上，又变成一颗独立的点。
        //        · 加粗封顶 1.62 → 半径 0.81·w，仍在光晕内径（1.78·w）以内
        //          —— 它绝不会突出到辉光之外，最多是辉光里更浓的一小团；
        //        · 强度由**书写进度**给（见 inkDot）—— 珠和笔同生同长。
        let (dk, da) = inkDot(p)
        if da > 0.01, s1 - s0 > 1e-9 {
            // 尾巴只取笔尖前 0.8% 弧长（≈ 一个圆头）。取长了会变成"整笔变粗"，
            // 取短了 round cap 会退化成一个孤立圆点 —— 0.8% 恰好是一团墨珠。
            let tail = slice(max(s0, s1 - 0.008), s1)
            let tw = w * CGFloat(dk)
            gc.opacity = 0.80 * da
            gc.blendMode = .multiply
            gc.stroke(tail, with: rainbow,
                      style: StrokeStyle(lineWidth: tw,
                                         lineCap: .round, lineJoin: .round))
            gc.blendMode = .normal
            gc.opacity = 0.55 * da
            gc.stroke(tail, with: .color(Color(red: 1.0, green: 0.99, blue: 0.95)),
                      style: StrokeStyle(lineWidth: tw * 0.40,
                                         lineCap: .round, lineJoin: .round))
        }
        gc.opacity = 1
    }

    var body: some View {
        GeometryReader { geo in
            ZStack {
                RadialGradient(colors: [FirstRunInk.bgCenter, FirstRunInk.bgEdge],
                               center: .center, startRadius: 80, endRadius: 900)
                    .ignoresSafeArea()
                VStack(spacing: 0) {
                    Spacer(minLength: 0)
                    // 整体缩小：占屏高 0.26。比例按「字形 + 光晕」的实际占位
                    // 来定，所以缩下去之后字形与光晕都是完整的。
                    hello()
                        .aspectRatio(Self.canvasFit.w * Self.inkSize.width
                                     / (Self.canvasFit.h * Self.inkSize.height),
                                     contentMode: .fit)
                        .frame(maxWidth: .infinity,
                               maxHeight: geo.size.height * 0.26)
                    Spacer(minLength: 0)
                    startButton
                    Spacer().frame(height: geo.size.height * 0.15)
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .onAppear { boot() }
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
                    // 描边：一圈中性暗边勾出轮廓（浅底上才立得住），
                    // 再叠一层上亮下暗的白渐变当玻璃高光。
                    Capsule().strokeBorder(Color.primary.opacity(0.16), lineWidth: 1)
                )
                .overlay(
                    Capsule().strokeBorder(
                        LinearGradient(colors: [.white.opacity(0.95), .white.opacity(0.10)],
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

/// 循环时间轴的**对外只读视图**。`Cyc` 是 HelloGreeting 的私有实现细节，
/// 但 `--hitch` 要把「掉帧发生在第几秒、正写到哪个字」讲清楚，所以在这里
/// 单开一个不暴露任何内部机制、只描述"第几秒在干什么"的口子。
/// 数值必须与 `Cyc` 保持一致 —— 改那边记得同步这边。
enum CycInfo {
    static let total      = 5.40
    static let writeStart = 0.00
    static let writeEnd   = 2.60
    /// 落笔窗口的结束时刻（秒）。= HelloGreeting.dotFade × (writeEnd − writeStart)
    /// ≈ 0.07 × 2.60 —— 那边改 dotFade 记得同步这里。
    static let landEnd    = 0.18
    /// 墨珠长满的时刻（秒）。= HelloGreeting.dotPeak × (writeEnd − writeStart)。
    static let landPeak   = 0.04

    /// 相位（0…1）→ 阶段名。用于 --hitch 的掉帧报告。
    static func stage(_ phase: Double) -> String {
        guard phase >= 0 else { return "未知" }
        let t = phase * total
        switch t {
        case ..<landEnd:     return "落笔·墨珠"
        case ..<0.95:        return "h 起笔"
        case ..<1.25:        return "h 完成"
        case ..<1.60:        return "e"
        case ..<1.90:        return "e→l"
        case ..<2.20:        return "l ①"
        case ..<writeEnd:    return "l ② → o 起"
        case ..<3.60:        return "o 收 + 甩尾"
        case ..<4.60:        return "擦除·前半"
        default:             return "擦除·h 端"
        }
    }
}

// MARK: - 三幕串场

struct FirstRunFlow: View {
    @EnvironmentObject private var settings: BoardSettings
    @State private var stage: Stage
    /// 第三幕进场：blur + 缩放 + 透明度三件套一起缓过来
    @State private var enterOnboard = false
    /// 这次要不要演开幕（MB Buddy 快闪 → 彩虹 hello）
    private let playIntro: Bool
    /// 开幕走完之后，要不要接上新手导览。
    /// `false` 的情形就是「导览早走完了、但这一版的开幕还没演」——
    /// 用户装了个新版本第一次打开，想看的是那段开场，不是再被问一遍英语名。
    private let thenOnboard: Bool

    enum Stage { case splash, hello, onboard, dash }

    init(playIntro: Bool, thenOnboard: Bool) {
        // 初始幕在 init 里就算好，别等 onAppear 再改 —— 否则「减弱动态」的用户
        // 会先闪到一帧快闪画面。Motion.reduced 是静态可读的，init 里就能判。
        let first: Stage
        if playIntro {
            first = Motion.reduced ? .hello : .splash
        } else {
            first = thenOnboard ? .onboard : .dash
        }
        _stage = State(initialValue: first)
        self.playIntro = playIntro
        self.thenOnboard = thenOnboard
    }

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
                    // ★ 用户进场了 ★
                    // 只有从这一刻起，后端才被允许去扫用户的下载 / 桌面 / 文稿
                    // （它要在那儿找课表 xlsx）。在那之前扫会弹 macOS 的
                    // 「想要访问您的下载文件夹」授权框，正好盖在这段动画上。
                    // 用户的要求就是「这种弹窗都要放到点了这个按钮之后」。
                    Task { await Bridge.ready() }
                    // 「让我们开始吧」之后去哪，由 thenOnboard 说话：
                    // 导览早走完的人直接进看板（他这次只是来看开幕的），
                    // 没走完的人接上导览。不依赖 settings.onboarded 的变化 ——
                    // 否则「已经配好过」的用户会卡在导览里出不去。
                    stage = thenOnboard ? .onboard : .dash
                }

            case .onboard:
                OnboardingView(onFinish: { stage = .dash })
                    .opacity(enterOnboard ? 1 : 0)
                    .scaleEffect(enterOnboard ? 1 : 0.96)
                    .blur(radius: enterOnboard ? 0 : 10)
                    .onAppear {
                        withAnimation(.spring(response: 0.65, dampingFraction: 0.92).delay(0.05)) {
                            enterOnboard = true
                        }
                    }

            case .dash:
                DashRoot(store: DataStore.shared)
                    .transition(.opacity)
            }
        }
        .onAppear {
            // ★ 这一版的开幕演出，到此为止已经放过了 ★
            //   写的是**版本号**，不是 Bool。
            //   一露面就写、不等演完 —— 用户要的语义是
            //   「只有下载完**首次进 APP** 才有这两个动画」，
            //   「首次」指第一次打开 App，而不是「完整看完这段动画」。
            //   于是哪怕用户第一秒就把 App 关掉，下次进来也是直进首页，
            //   不会「退出重进又演一遍」。
            //   而下次**换版本**装上来时版本号不相等，会再演一次 —— 那正是
            //   用户期望的「装了新版第一次打开」。
            //   想看回来：菜单「重新运行首次配置向导」/ 设置页那两个入口。
            if playIntro {
                settings.introVersion = BoardSettings.appVersion
            }
            // 落一行日志：以后有人问「怎么又演动画了 / 怎么没演」，
            // 对着 /tmp/mbboard-mac.log 一眼就知道走的是哪一支。
            Log.write("开幕演出："
                      + (playIntro ? "从头演（快闪 → hello）"
                                   : "跳过（这一版已经放过）")
                      + (thenOnboard ? " → 接上新手导览" : " → 直进看板"))
        }
    }
}
