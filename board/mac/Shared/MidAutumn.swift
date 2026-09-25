import SwiftUI
import Foundation

/* ======================================================================
   中秋主题「月圆 · LunaOS」
   ----------------------------------------------------------------------
   这个文件一共五件东西：

     ① MoonFest           —— 主题的取色、可选性（限时闸门）
     ② MoonNightBackdrop  —— 铺在整页底下的矢量月夜：
                              右上角一轮带晕的明月、会动的云气、孔明灯、
                              桂枝、青玉兔、飘落的金桂、远山与檐角
     ③ MoonToy            —— 「能点能拖」这件小事的地基（见下面那一节）
     ④ MidAutumnGrove     —— 侧边栏空档里的一幅小景（月 · 桂 · 玉兔 · 灯笼）
     ⑤ MoonFestNotice     —— 档期内每次启动都会出现的上线提示弹窗

   为什么全部用矢量画、不塞一张照片：
     底纹是**垫在所有卡片下面**的一层，卡片本身是半透明玻璃 —— 照片垫在
     下面，玻璃会把照片的明暗一起折射上来，正文就糊了。矢量可以精确控制
     每一处的对比度，还能跟着深浅色换一整套画法。

   ----------------------------------------------------------------------
   这一轮改了什么（用户的原话：「往右上角加一轮明月…附近有一些动态的云气，
   这些东西图层都在组件和模块的下面，还要加入更多更多更多的中秋元素，
   而且这些元素都是可以互动的，点击和拖拽什么的都要有效果。」）
   ----------------------------------------------------------------------
   ① 月亮挪到**右上角**，并且「朦胧但看得出是月亮」：
      上一版把月亮放在侧栏中段（x=113），理由是「内容区全被卡片占满，
      月亮摆哪儿都压卡片」。结果浅色下月轮与天空几乎同色，只剩一团晕 ——
      用户看到的就是「左侧一片不好看的光」。
      现在的取舍换了方向：**不再靠挪位置躲卡片，而是让月亮就待在右上角**
      （那里本来就是「天」），用「月轮 + 一圈紧贴的亮边 + 月面斑驳 +
      一层柔晕 + 一层大晕」五件套把「这是一轮月亮」说清楚。
      被卡片压住没关系 —— 用户明确要求「图层在组件和模块的下面」。

   ② 不挡卡片的办法变了：**逐元素命中**，而不是整块 `contentShape`。
      上一版给整幅底纹铺了 `contentShape(Rectangle()) + onTapGesture`
      外带 `allowsHitTesting(false)` —— 要么全吃点击（挡住卡片），
      要么全不吃（元素白做）。现在每个可互动元素**只在自己的形状里**接
      手势（`MoonToy` 里的 `.contentShape(Circle()/RoundedRectangle)`），
      于是：点在卡片上 → 卡片收；点在卡片之间的空当、恰好落在月亮/云上
      → 底纹收。两层各管各的，谁也不挡谁。

   ③ 元素扩充 + 全部可互动：明月、云气 ×3、孔明灯 ×3、桂枝、青玉兔。
      各自可点可拖（月只点，它不该被拖走）。

   ④ 云气重做：不再是横贯画面的长条，而是**月亮附近 3~4 团柔光叠出来的
      「一缕云」**，一边横向漂移一边上下呼吸，并且穿月而过。
   ====================================================================== */

enum MoonFest {

    static let paletteID = "moonfest"

    /// 「今天」。离屏自检可以把它挪走，正常运行就是系统时间。
    static var today: Date { PreviewFlags.dateOverride ?? Date() }

    /// 主题此刻是否可选。
    ///
    /// 节令主题的档期集中写在**这一个地方** —— 设置页、引导页、菜单栏面板
    /// 三处列表都走 `Palettes.all`，所以改这里等于三处一起改。
    /// 档期之外的兜底还有一层：`Palettes.by()` 取不到就退回经典，
    /// 保证配置文件里即使留着一个旧值，界面上也不会冒出这个主题。
    static var available: Bool {
        let c = Calendar.current.dateComponents([.year, .month, .day], from: today)
        guard let y = c.year, let m = c.month, let d = c.day else { return false }
        return y == 2026 && m == 9 && d >= 24 && d <= 27
    }

    /* ---------------- 取色 ----------------
       深浅两套是**两个场景**，不是同一套色调明暗：
         浅色 = 「月华」：底色必须亮（界面要长时间读），画的是月光的颜色。
         深色 = 「中秋月夜」：深靛蓝夜空 + 月轮 + 星子，节日真正的正脸。

       选了这套主题就会 `forcesDark`（见 Theme.swift 的 Palette），
       所以真机上看到的基本都是下面那套深靛蓝。 */

    struct Ink {
        let skyTop: Color, skyBottom: Color
        let moonCore: Color, moonGlow: Color
        let star: Color, petal: Color
        let ridge: Color, cloud: Color, eave: Color
        /// 桂叶的绿。桂叶是真的绿，跟木质枝干必须分开 ——
        /// 上一版叶子和枝都用了 `eave`（暖白），结果叶子在深色底上
        /// 成了几道亮白细线，像画面裂了缝。
        let leaf: Color
        /// 枝干（木褐）。
        ///
        /// 上一版枝干直接用了 `eave`（檐角暖白），在深靛蓝夜空上就是
        /// **一根白棍** —— 再怎么写锥度也像拿了根粉笔画面上一划。
        /// 木质必须是「黄褐偏暗、饱和度低」，它才退到画面第二层去。
        let bark: Color, barkLit: Color
        /// 玉兔的毛。
        ///
        /// 上一版兔子用了 `cloud`（(0.64,0.70,0.86) 的蓝灰，那是**云气**
        /// 的颜色），结果在夜空上是一只灰蓝色的老鼠。玉兔要「玉」——
        /// 也就是接近月轮那种冷调的白，比月轮稍暗一档才能在月上不糊。
        let fur: Color
        /// 灯（宫灯红 + 金箍）
        let lamp: Color, lampRing: Color
    }

    static func ink(_ scheme: ColorScheme) -> Ink {
        if scheme == .dark {
            return Ink(skyTop:   Color(.sRGB, red: 0.105, green: 0.140, blue: 0.250),
                       skyBottom: Color(.sRGB, red: 0.030, green: 0.042, blue: 0.085),
                       moonCore: Color(.sRGB, red: 0.995, green: 0.972, blue: 0.890),
                       moonGlow: Color(.sRGB, red: 0.930, green: 0.800, blue: 0.470),
                       star:     Color(.sRGB, red: 0.965, green: 0.930, blue: 0.840),
                       petal:    Color(.sRGB, red: 0.910, green: 0.720, blue: 0.360),
                       ridge:    Color(.sRGB, red: 0.018, green: 0.026, blue: 0.052),
                       cloud:    Color(.sRGB, red: 0.640, green: 0.700, blue: 0.860),
                       eave:     Color(.sRGB, red: 0.965, green: 0.930, blue: 0.840),
                       leaf:     Color(.sRGB, red: 0.330, green: 0.520, blue: 0.300),
                       bark:     Color(.sRGB, red: 0.400, green: 0.320, blue: 0.215),
                       barkLit:  Color(.sRGB, red: 0.585, green: 0.470, blue: 0.310),
                       fur:      Color(.sRGB, red: 0.905, green: 0.925, blue: 0.960),
                       lamp:     Color(.sRGB, red: 0.800, green: 0.250, blue: 0.200),
                       lampRing: Color(.sRGB, red: 0.910, green: 0.740, blue: 0.360))
        }
        return Ink(skyTop:   Color(.sRGB, red: 0.996, green: 0.984, blue: 0.960),
                   skyBottom: Color(.sRGB, red: 0.949, green: 0.902, blue: 0.796),
                   moonCore: Color(.sRGB, red: 1.000, green: 0.995, blue: 0.975),
                   moonGlow: Color(.sRGB, red: 0.945, green: 0.815, blue: 0.470),
                   star:     Color(.sRGB, red: 0.845, green: 0.720, blue: 0.415),
                   petal:    Color(.sRGB, red: 0.870, green: 0.660, blue: 0.290),
                   ridge:    Color(.sRGB, red: 0.706, green: 0.635, blue: 0.520),
                   cloud:    Color(.sRGB, red: 1.000, green: 0.995, blue: 0.980),
                   eave:     Color(.sRGB, red: 0.560, green: 0.480, blue: 0.360),
                   leaf:     Color(.sRGB, red: 0.385, green: 0.575, blue: 0.345),
                   bark:     Color(.sRGB, red: 0.455, green: 0.365, blue: 0.245),
                   barkLit:  Color(.sRGB, red: 0.615, green: 0.505, blue: 0.345),
                   fur:      Color(.sRGB, red: 0.995, green: 0.988, blue: 0.968),
                   lamp:     Color(.sRGB, red: 0.760, green: 0.265, blue: 0.220),
                   lampRing: Color(.sRGB, red: 0.760, green: 0.560, blue: 0.200))
    }
}

/* ======================================================================
   ① 一次「落桂」：点下去的那一点，花瓣从那里散开
   ====================================================================== */

struct MoonBurst: Identifiable {
    let id = UUID()
    let p: CGPoint
    /// 起始时刻（`Date.timeIntervalSinceReferenceDate`，和时间轴同一个基准）
    let t0: Double
    let seed: Int
}

/* ======================================================================
   ② 「能点能拖」这件小事的地基

   这个包装是整个文件里最要紧的一块，因为**「拖动」在 SwiftUI 里有两个
   非常容易踩的坑**，两个都会表现成「拖起来闪跳抽搐」：

   ① 坐标空间：`DragGesture` 默认用 `.local` —— 也就是**手势自己所附的那个
      视图**的坐标系。而这个视图正被 translation 挪走。坐标系跟着自己跑，
      位移就变成自激正反馈：手指动 1pt，视图动 1pt，视图动完坐标系又动
      1pt… 表现出来就是窗口一边抖一边疯跑。
      修法：显式写 `coordinateSpace: .named(space)`，指到**不随元素移动的
      外层视口**（MoonNightBackdrop 在 ZStack 上挂了 `.coordinateSpace`）。

   ② 手位移不能落 `@State`：`@State` 只增不减，松手时 gesture 的 translation
      归零，可 `@State` 里那一份还在 —— 于是「松手瞬间再跳一下」。
      修法：手位移用 `@GestureState`（手势结束**自动归零**），落位才写 `@State`。

   顺带第三个坑：位移**不能套动画**。`withAnimation` 包裹 offset 会让它追着
   手指做缓动，越拖越滞后 —— 那不是「丝滑」，那是「拖拉机」。

   第四个坑：`onTapGesture` 和 `highPriorityGesture(DragGesture)` **别并存**。
   两者同时挂在一个视图上时，高优先的那个会先把事件拿走，轻点有时就传不到
   tap 上 —— 表现是「随机的点了没反应」。所以这里干脆只挂**一个**
   `DragGesture(minimumDistance: 0)`，在 `onEnded` 里按位移大小自己分流：
     位移 < 5pt → 当点击处理
     位移 ≥ 5pt → 当拖动处理
   只有一套事件通路，就不存在两个手势抢事件的余地。

   于是套路固定成四条：
     · `@GestureState live` 管「手指这一下」，手势结束自动归零
     · `@Binding off` 管「松手之后留在哪」
     · 一个手势统管点击与拖动，`dragSlop` 分流
     · 位移一点动画都不套
   ====================================================================== */

private struct MoonToy<C: View>: View {

    /// 命中区形状。云的命中区是一条横长的带（它本来就宽），
    /// 月亮、兔子、桂枝是一个圆/方块 —— 各取所需。
    ///
    /// ★ 关键：命中区**必须**是元素自己的形状，不能是整块容器 ★
    /// 整幅月夜是垫在卡片下面的底纹，一旦它整块吃点击，第一屏的卡片就全废了。
    enum Hit {
        case circle(CGFloat)
        case box(CGFloat, CGFloat)
    }

    /// 「点击」与「拖动」的分界（pt）。手指正常抖动不会越过它。
    private static var dragSlop: CGFloat { 5 }

    /// `MoonNightBackdrop` 挂在 ZStack 上的那个命名坐标空间
    let space: String
    let hit: Hit
    /// 落位（手指离开后元素停在哪儿）。拖动过程中它**不变**，
    /// 变化全在 `live` 里 —— 这是「不闪跳」的另一半。
    @Binding var off: CGSize
    /// 松手后弹回原位？
    ///   云 → 要（它本来就该飘在自己的轨道上，拖走只是个乐子）
    ///   灯 / 兔 → 不要（拖到哪儿就留在哪儿，那更符合直觉）
    var snapBack: Bool = false
    var onTap: () -> Void = {}

    @GestureState private var live: CGSize = .zero
    @State private var down = false

    @ViewBuilder var content: () -> C

    private var cur: CGSize {
        CGSize(width: off.width + live.width, height: off.height + live.height)
    }

    private func far(_ t: CGSize) -> Bool {
        hypot(t.width, t.height) >= Self.dragSlop
    }

    var body: some View {
        let base = content()
            .offset(cur)
            .scaleEffect(down ? 1.045 : 1)

        return Group {
            switch hit {
            case .circle(let r):
                base.frame(width: r * 2, height: r * 2)
                    .contentShape(Circle())
            case .box(let w, let h):
                base.frame(width: w, height: h)
                    .contentShape(RoundedRectangle(cornerRadius: min(w, h) * 0.42,
                                                   style: .continuous))
            }
        }
        .highPriorityGesture(
            // minimumDistance: 0 而不是 5：阈值挪到 onEnded 里自己判。
            // 用 5 的话，点击要等手势「不成立」才能落到 tap 上，
            // 而 tap 已经和它并存不了了（见文件头第四个坑）。
            DragGesture(minimumDistance: 0, coordinateSpace: .named(space))
                .updating($live) { v, s, _ in
                    // ★ 只有真的在拖（越过阈值）才更新手位移 ★
                    // 不判这一下的话，连「点」也会让元素跟着手指抖 1~2pt，
                    // 高频点上十几次会看出「元素被点得发抖」。
                    guard far(v.translation) else { return }
                    s = v.translation
                }
                .onChanged { v in
                    // 抬起来一点点的「拿起来了」手感。**只动 scale，不动位移**。
                    if far(v.translation), !down {
                        withAnimation(Motion.hover) { down = true }
                    }
                }
                .onEnded { v in
                    withAnimation(Motion.hover) { down = false }
                    guard far(v.translation) else {
                        // 位移没到阈值 —— 这是「点」，不是「拖」
                        onTap()
                        return
                    }
                    if snapBack {
                        withAnimation(.easeInOut(duration: 0.68)) { off = .zero }
                    } else {
                        off = CGSize(width: off.width + v.translation.width,
                                     height: off.height + v.translation.height)
                    }
                }
        )
    }
}

/* ======================================================================
   ③ 矢量月夜底纹
   ====================================================================== */

struct MoonNightBackdrop: View {

    let scheme: ColorScheme
    /// 紧凑版：给提示弹窗内部用 —— 尺寸小、元素减半
    var compact: Bool = false
    /// 要不要接交互。
    ///
    /// 现在**默认开**（上一版默认关）：因为命中已经细化到逐个元素，
    /// 不再需要靠「整块不吃点击」来给卡片让路。
    /// 只有极少数场合想彻底静音时才显式传 false。
    var interactive: Bool = true

    @EnvironmentObject private var settings: BoardSettings

    /// 落桂
    @State private var bursts: [MoonBurst] = []
    /// 月亮亮起（点一下会亮一圈、涨一点点，然后自己回去）
    @State private var moonHot = false

    /// 云：被拖走的位移（松手回弹）+ 被点散的程度
    @State private var cloudOff: [CGSize] = Array(repeating: .zero, count: 4)
    @State private var cloudPuff: [Double] = Array(repeating: 0, count: 4)

    /// 孔明灯：被拖走的位移 + 点亮状态
    @State private var lampOff: [CGSize] = Array(repeating: .zero, count: 4)
    @State private var lampLit: [Bool] = Array(repeating: false, count: 4)

    /// 青玉兔：跳了几下 + 被拖到哪儿
    @State private var hops = 0
    @State private var rabbitOff: CGSize = .zero

    /// 桂枝：摇了一下
    @State private var branchHot = false

    /// 命名坐标空间。所有 `MoonToy` 都指到这里 —— 它挂在最外层的 ZStack 上，
    /// **不随任何元素移动**，所以不会出现「坐标系跟着元素跑」的自激正反馈。
    static let space = "mbboard.moonnight"

    /// 六片叶：三片朝外上、三片朝外下，沿主枝那条弧线交替排布。
    /// 都斜生（没有一片是水平的）—— 水平的叶子看着像飘着的纸片。
    ///
    /// **第一版 wid 给成了 0.048**（≈8pt），叶子细成一根线，远看就是
    /// 画面裂了几道缝 —— 见文件头那段「矢量要有面积」。
    ///
    /// 【第二次返工：长宽比】
    /// 提到 0.094~0.130 之后叶子有面积了，但 `len` 还留着 0.21~0.30
    /// 那么长，算下来是 **4.2:1** 的细长条 —— 像竹叶不像桂叶。
    /// 现在把 len 压到 0.16~0.23、wid 保持 0.135~0.180，
    /// 落到 **2.4:1 ~ 2.8:1**，也就是真实桂叶那个「卵状长椭圆」的比例。
    private static let leaves: [LeafSpec] = [
        .init(len: 0.230, wid: 0.180, deg: -52, x: 0.74, y: 0.11),
        .init(len: 0.200, wid: 0.162, deg:  26, x: 0.80, y: 0.25),
        .init(len: 0.218, wid: 0.172, deg: -64, x: 0.55, y: 0.26),
        .init(len: 0.182, wid: 0.150, deg:  34, x: 0.63, y: 0.41),
        .init(len: 0.205, wid: 0.166, deg: -46, x: 0.36, y: 0.43),
        .init(len: 0.160, wid: 0.135, deg:  40, x: 0.30, y: 0.57),
    ]

    private var paused: Bool { settings.reduceMotion || Motion.reduced || PreviewFlags.still }
    private var starCount: Int { compact ? 14 : 34 }
    private var cloudCount: Int { compact ? 2 : 3 }
    private var lanternCount: Int { compact ? 2 : 3 }
    private var petalCount: Int { compact ? 5 : 14 }

    var body: some View {
        GeometryReader { geo in
            let W = max(1, geo.size.width)
            let H = max(1, geo.size.height)
            let c = MoonFest.ink(scheme)
            let moon = moonPoint(W, H)
            let r = moonRadius(W, H)

            ZStack(alignment: .topLeading) {
                // ── 静态层：天空 + 月晕。放时间轴外面，只有动的东西才逐帧重画。
                sky(c, W, H, moon, r)
                ridge(c, W, H, moon, r)

                // ── 动态层 ──
                TimelineView(.animation(minimumInterval: 1.0 / 20.0, paused: paused)) { ctx in
                    let t = ctx.date.timeIntervalSinceReferenceDate
                    ZStack(alignment: .topLeading) {
                        stars(c, W, H, t)
                        clouds(c, W, H, t)
                        lanterns(c, W, H, t)
                        petals(c, W, H, t)
                        burstLayer(c, t)
                    }
                    .frame(width: W, height: H, alignment: .topLeading)
                }
                .frame(width: W, height: H, alignment: .topLeading)

                // ── 月亮本体。放在动态层之上 —— 云要能「穿月而过」，
                //    所以云在它下面一层；但两者都还在所有卡片之下。
                moonBody(c, W, H, moon, r)
                // ── 桂枝（从右上角斜出来，托着月亮）
                branch(c, W, H)
                // ── 青玉兔（蹲在月亮左下角的一小片云上）
                rabbit(c, W, H)
                // ── 遮月的薄云：放最上层，但它只占月亮周围一小块
                TimelineView(.animation(minimumInterval: 1.0 / 20.0, paused: paused)) { ctx in
                    moonVeil(c, moon, r, ctx.date.timeIntervalSinceReferenceDate)
                }
                .frame(width: W, height: H, alignment: .topLeading)
            }
            .frame(width: W, height: H, alignment: .topLeading)
            .coordinateSpace(name: Self.space)
        }
    }

    /* ---------------- 位置与尺度 ---------------- */

    /// 满月落在哪儿。
    ///
    /// 右上角。这一版不再为了「不压卡片」把月亮塞进侧栏 —— 那样浅色下
    /// 月轮与天空同色，只剩一团晕，用户看到的就是「左侧一片光」，还会
    /// 以为是画坏了。现在的取法是：**月亮就该在右上角的天空里**，
    /// 被半透明玻璃卡片折射上来是正常且好看的，而「不挡功能」交给
    /// 逐元素命中（见 MoonToy）。
    private func moonPoint(_ W: CGFloat, _ H: CGFloat) -> CGPoint {
        compact ? CGPoint(x: W * 0.74, y: H * 0.315)
                : CGPoint(x: W * 0.892, y: H * 0.145)
    }

    /// 月轮半径。
    ///
    /// 用 `min(W, H)` 而不是只取 H：菜单栏小面板那种又窄又高的窗口里，
    /// 只按高度算会让月亮宽出画面。
    ///
    /// 浅色「月华」下收一圈：月轮色 (1.0,0.995,0.975) 与天空 (0.996,0.984,0.960)
    /// 几乎同色，画大了就是一块白斑 —— 靠 `moonBody` 里那圈淡金描边把轮廓拎出来。
    private func moonRadius(_ W: CGFloat, _ H: CGFloat) -> CGFloat {
        if compact { return min(42, max(26, min(W, H) * 0.165)) }
        let m = min(W, H)
        // 上限 84：月亮中心在 H*0.145 处，半径再大上边缘就会被窗口顶边切掉
        // （第一版取 92 + y=0.088，顶部明明白白切掉 16pt）。
        return scheme == .dark ? min(84, max(52, m * 0.118))
                               : min(72, max(46, m * 0.102))
    }

    /* ---------------- 天空 + 月晕 ---------------- */

    @ViewBuilder
    private func sky(_ c: MoonFest.Ink, _ W: CGFloat, _ H: CGFloat,
                     _ moon: CGPoint, _ r: CGFloat) -> some View {
        ZStack {
            LinearGradient(colors: [c.skyTop, c.skyBottom],
                           startPoint: .top, endPoint: .bottom)

            // 最外层大晕：月色洒满右上角那片天。半径给到十几倍月径，
            // 但中心几乎透明 —— 「朦胧」靠它，「能认出是月亮」靠下面几层。
            Circle()
                .fill(RadialGradient(colors: [c.moonGlow.opacity(moonHot ? 0.30 : 0.17),
                                              c.moonGlow.opacity(0)],
                                     center: .center,
                                     startRadius: r * 1.1,
                                     endRadius: r * (moonHot ? 9.0 : 7.4)))
                .frame(width: r * 20, height: r * 20)
                .position(moon)
                .animation(Motion.ease(Motion.Dur.slow), value: moonHot)

            // 中层光晕
            Circle()
                .fill(RadialGradient(colors: [c.moonGlow.opacity(0.24),
                                              c.moonGlow.opacity(0)],
                                     center: .center, startRadius: 0, endRadius: r * 2.8))
                .frame(width: r * 6.2, height: r * 6.2)
                .position(moon)

            // 紧贴月轮的一圈暖光：这一层是把「月晕」和「月轮」缝起来的关键，
            // 少了它，月轮就像一枚贴在雾上的贴纸。
            Circle()
                .fill(RadialGradient(colors: [c.moonGlow.opacity(0.52),
                                              c.moonGlow.opacity(0)],
                                     center: .center,
                                     startRadius: r * 0.94, endRadius: r * 1.85))
                .frame(width: r * 4, height: r * 4)
                .position(moon)
        }
    }

    /* ---------------- 月轮本体（可点） ---------------- */

    /// 月亮只点不拖：一轮月亮被拖走会很怪。
    /// 所以它不套 `MoonToy`，直接一个定了形状的点击区 ——
    /// 命中半径比月轮大 22%，手指擦着边也能点到。
    ///
    /// **「朦胧，但看得出是月亮」** 靠这四层叠出来：
    ///   ① 外缘羽化层：一枚略大、整体模糊的暖白圆 —— 月亮的「毛边」
    ///   ② 月轮：径向渐变，最外 4% 半径里从 72% 淡到 0 —— 边缘不生硬
    ///   ③ 月面暗纹：极度模糊的几块，像云影掠过月面，而不是贴纸上的陨石坑
    ///   ④ 一圈极细的亮边：唯一一处「硬」的笔画，专门负责把轮廓说清楚
    /// 前三层给「朦胧」，第四层给「这是月亮」。少了第四层就是一团雾，
    /// 少了前三层就是一张贴纸 —— 这两个极端用户都已经看过一次了。
    private func moonBody(_ c: MoonFest.Ink, _ W: CGFloat, _ H: CGFloat,
                          _ moon: CGPoint, _ r: CGFloat) -> some View {
        let hitR = r * 1.22
        return ZStack {
            // ① 毛边
            Circle()
                .fill(c.moonCore.opacity(scheme == .dark ? 0.34 : 0.46))
                .frame(width: r * 2.26, height: r * 2.26)
                .blur(radius: r * 0.19)

            // 点一下亮起来的一圈「月华环」
            Circle()
                .strokeBorder(c.moonGlow.opacity(moonHot ? 0.42 : 0.0), lineWidth: 1.3)
                .frame(width: r * 2.72, height: r * 2.72)
                .blur(radius: 1.8)

            // ② 月轮
            Circle()
                .fill(RadialGradient(stops: [
                    .init(color: c.moonCore, location: 0.00),
                    .init(color: c.moonCore, location: 0.64),
                    .init(color: c.moonCore.opacity(0.74), location: 0.86),
                    .init(color: c.moonCore.opacity(0.30), location: 0.96),
                    .init(color: c.moonGlow.opacity(0.0), location: 1.00)
                ], center: UnitPoint(x: 0.41, y: 0.35),
                   startRadius: 0, endRadius: r * 1.05))
                .frame(width: r * 2.10, height: r * 2.10)
                .shadow(color: c.moonGlow.opacity(scheme == .dark ? 0.42 : 0.24),
                        radius: r * 0.9)
                .scaleEffect(moonHot ? 1.035 : 1)

            // ③ 月面暗纹
            MoonMarks(r: r)
                .opacity(scheme == .dark ? 0.16 : 0.09)

            // ④ 轮廓
            Circle()
                .strokeBorder(c.moonGlow.opacity(scheme == .dark ? 0.30 : 0.50),
                              lineWidth: max(0.7, r * 0.020))
                .frame(width: r * 2, height: r * 2)
                .blur(radius: 0.4)
        }
        .animation(Motion.spring(0.5), value: moonHot)
        .frame(width: hitR * 2, height: hitR * 2)
        .contentShape(Circle())
        .onTapGesture { hitMoon(moon) }
        .offset(x: moon.x - hitR, y: moon.y - hitR)
        .allowsHitTesting(interactive)
    }

    /* ---------------- 遮月的薄云 ----------------
       一朵只在月亮周围一小块里慢慢横移的柔光云，轻轻盖在月轮前面。
       这是「朦胧」最直接的一笔：月亮有了被云气拂过的层次，
       而不是一枚扣在夜空上的圆片。
       它被**钉在月亮附近**（宽度只有 2.8 倍月径），不往画面别处跑，
       所以不会去糊别的东西，也不会挡到任何可点的元素。 */

    @ViewBuilder
    private func moonVeil(_ c: MoonFest.Ink, _ moon: CGPoint, _ r: CGFloat,
                          _ t: Double) -> some View {
        let vw = r * 3.0
        let vh = r * 0.94
        let travel = CGFloat(sin(t * 0.115)) * r * 0.62
        let thick = 0.55 + 0.45 * sin(t * 0.083 + 1.1)
        let base = (scheme == .dark ? 0.20 : 0.30) * (moonHot ? 0.55 : 1) * thick

        ZStack {
            ForEach(0..<3, id: \.self) { j in
                let w = vw * (0.52 + 0.30 * CGFloat(rnd(j, 81)))
                let h = vh * (0.62 + 0.34 * CGFloat(rnd(j, 82)))
                Circle()
                    .fill(RadialGradient(colors: [c.cloud.opacity(base),
                                                  c.cloud.opacity(0)],
                                         center: .center,
                                         startRadius: 0, endRadius: w * 0.5))
                    .frame(width: w, height: w)
                    .scaleEffect(x: 1, y: h / w)
                    .blur(radius: h * 0.42)
                    .offset(x: vw * (CGFloat(rnd(j, 83)) - 0.5) * 0.7,
                            y: vh * (CGFloat(rnd(j, 84)) - 0.5) * 0.6)
            }
        }
        .frame(width: vw, height: vh)
        .offset(x: moon.x - vw / 2 + travel, y: moon.y - vh / 2)
        .allowsHitTesting(false)
        .animation(Motion.ease(Motion.Dur.slow), value: moonHot)
    }

    /* ---------------- 星子 ---------------- */

    /// 星位是**算出来的**、不是随机的：`rnd(k, salt)` 是个确定性哈希，
    /// 所以每一帧、每一次重画，星星都在原地，只有明暗在呼吸。
    /// 用 `Int.random` 会让整片星空每帧重新洗牌 —— 那是闪烁，不是星光。
    ///
    /// 月亮亮起时（点过它），右上角那一片星子会跟着亮一点 ——
    /// 这是「月明星稀」反过来用：月光涨了，近处的星反倒更清楚。
    @ViewBuilder
    private func stars(_ c: MoonFest.Ink, _ W: CGFloat, _ H: CGFloat, _ t: Double) -> some View {
        ZStack(alignment: .topLeading) {
            ForEach(0..<starCount, id: \.self) { k in
                let x = CGFloat(rnd(k, 1)) * W
                let y = CGFloat(rnd(k, 2)) * H * 0.74
                let s = 0.9 + CGFloat(rnd(k, 3)) * 1.8
                let ph = rnd(k, 4) * 6.283
                let sp = 0.45 + rnd(k, 5) * 1.05
                let tw = 0.5 + 0.5 * sin(t * sp + ph)
                Circle()
                    .fill(c.star.opacity((0.20 + 0.42 * tw) * (scheme == .dark ? 1 : 0.55)))
                    .frame(width: s, height: s)
                    .blur(radius: s > 2 ? 0.7 : 0)
                    .position(x: x, y: y)
            }
        }
        .frame(width: W, height: H, alignment: .topLeading)
    }

    /* ---------------- 云气（可点可拖） ---------------- */

    @ViewBuilder
    private func clouds(_ c: MoonFest.Ink, _ W: CGFloat, _ H: CGFloat, _ t: Double) -> some View {
        ZStack(alignment: .topLeading) {
            ForEach(0..<cloudCount, id: \.self) { k in
                cloudNode(k, c, W, H, t)
            }
        }
        .frame(width: W, height: H, alignment: .topLeading)
    }

    private func cloudNode(_ k: Int, _ c: MoonFest.Ink,
                           _ W: CGFloat, _ H: CGFloat, _ t: Double) -> some View {
        let cw = W * (compact ? 0.44 : 0.32)
        let ch: CGFloat = compact ? 44 : 58
        let speed = 4.2 + rnd(k, 23) * 6.4
        let span = Double(W) + Double(cw)
        // 竖向落点。
        // compact（弹窗里那幅画）刻意从 0.30 起：浮窗顶端 46pt 是「拖窗口」的
        // 顶带（见 FloatingChrome），元素压在顶带里的话，想拖云就会变成拖窗口。
        // 0.30 × 250 = 75pt，云再高也不会爬到 46pt 以上。
        let px = CGFloat(falloff(t * speed / span)) * span - cw / 2
        let base = compact ? (0.30 + 0.28 * Double(k)) : (0.075 + 0.055 * Double(k))
        let py = H * CGFloat(base) + CGFloat(sin(t * 0.19 + rnd(k, 24) * 6.28)) * 5

        return MoonToy(space: Self.space, hit: .box(cw, ch),
                       off: $cloudOff[k], snapBack: true,
                       onTap: { puffCloud(k) }) {
            cloudShape(c, cw, ch, k)
        }
        // 被点散：淡掉 + 糊掉，过一会儿自己聚回来
        .opacity(1 - cloudPuff[k] * 0.92)
        .blur(radius: cloudPuff[k] * 11)
        .offset(x: px, y: py - ch / 2)
        .allowsHitTesting(interactive)
    }

    /// 一朵云 = 4 团柔光叠在一起，比一个椭圆更像「云气」。
    ///
    /// ★ 两处几何细节是踩过坑的，别动 ★
    /// ① 必须是**径向**渐变的圆，不能用 LinearGradient 的胶囊：
    ///    胶囊只有左右两端淡出、上下是两条直边，小尺寸下会变成横贯画面
    ///    的一道硬边亮带。
    /// ② 先画正圆算好渐变，再 `.scaleEffect(x: 1, y: h/w)` 压扁。
    ///    直接给 Ellipse 套 RadialGradient 是不行的 —— 径向半径各向同性，
    ///    而椭圆的上下边缘到中心只有 h/2，渐变会被椭圆的边硬裁掉。
    private func cloudShape(_ c: MoonFest.Ink, _ cw: CGFloat, _ ch: CGFloat,
                            _ k: Int) -> some View {
        ZStack {
            ForEach(0..<4, id: \.self) { j in
                let s = k * 10 + j
                let w = cw * (0.46 + 0.26 * CGFloat(rnd(s, 21)))
                let h = w * (0.30 + 0.14 * CGFloat(rnd(s, 22)))
                let dx = cw * (CGFloat(rnd(s, 23)) - 0.5) * 0.74
                let dy = ch * (CGFloat(rnd(s, 24)) - 0.5) * 0.66
                Circle()
                    .fill(RadialGradient(colors: [c.cloud.opacity(scheme == .dark ? 0.40 : 0.52),
                                                  c.cloud.opacity(0)],
                                         center: .center,
                                         startRadius: 0,
                                         endRadius: w * 0.5))
                    .frame(width: w, height: w)
                    .scaleEffect(x: 1, y: h / w)
                    .blur(radius: h * 0.5)
                    .offset(x: dx, y: dy)
            }
        }
        .frame(width: cw, height: ch)
    }

    private func puffCloud(_ k: Int) {
        withAnimation(.easeOut(duration: 0.42)) { cloudPuff[k] = 1 }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.7) {
            withAnimation(.easeInOut(duration: 1.6)) { cloudPuff[k] = 0 }
        }
    }

    /* ---------------- 孔明灯（可点可拖） ---------------- */

    @ViewBuilder
    private func lanterns(_ c: MoonFest.Ink, _ W: CGFloat, _ H: CGFloat, _ t: Double) -> some View {
        ZStack(alignment: .topLeading) {
            ForEach(0..<lanternCount, id: \.self) { k in
                lanternNode(k, c, W, H, t)
            }
        }
        .frame(width: W, height: H, alignment: .topLeading)
    }

    private func lanternNode(_ k: Int, _ c: MoonFest.Ink,
                             _ W: CGFloat, _ H: CGFloat, _ t: Double) -> some View {
        let lw: CGFloat = compact ? 26 : 34
        let lh: CGFloat = lw * 1.5
        let boxW = lw * 3.6, boxH = lh * 2.4
        let speed = 0.013 + rnd(k, 41) * 0.011
        // 1 - falloff：从下往上飘
        let climb = 1 - falloff(t * speed + rnd(k, 42))
        let span = H * 0.80 + 130
        let py = CGFloat(climb) * span - 40
        let px0 = compact ? (0.22 + 0.38 * CGFloat(k)) : (0.40 + 0.155 * CGFloat(k))
        let px = W * px0 + CGFloat(sin(t * 0.34 + rnd(k, 43) * 6.28)) * (compact ? 6 : 13)

        return MoonToy(space: Self.space, hit: .box(boxW, boxH),
                       off: $lampOff[k], snapBack: false,
                       onTap: { lightLantern(k, at: CGPoint(x: px, y: py)) }) {
            lanternShape(c, lw, lh, lampLit[k], t, k)
        }
        .offset(x: px - boxW / 2, y: py - boxH / 2)
        .allowsHitTesting(interactive)
    }

    private func lanternShape(_ c: MoonFest.Ink, _ lw: CGFloat, _ lh: CGFloat,
                              _ lit: Bool, _ t: Double, _ k: Int) -> some View {
        let sway = sin(t * 0.55 + rnd(k, 44) * 6.28) * 4.6 + (lit ? sin(t * 3.2) * 5.5 : 0)
        return ZStack {
            // 灯外的暖光
            Circle()
                .fill(RadialGradient(colors: [c.lamp.opacity(lit ? 0.62 : 0.30),
                                              c.lamp.opacity(0)],
                                     center: .center, startRadius: 0, endRadius: lw * 1.6))
                .frame(width: lw * 4, height: lw * 4)

            VStack(spacing: 1) {
                // 灯身
                Capsule()
                    .fill(LinearGradient(colors: [c.lamp.opacity(lit ? 0.99 : 0.88),
                                                  c.lamp.opacity(lit ? 0.82 : 0.62)],
                                         startPoint: .top, endPoint: .bottom))
                    .frame(width: lw, height: lh)
                    .overlay {
                        // 灯骨
                        HStack(spacing: lw * 0.26) {
                            ForEach(0..<3, id: \.self) { _ in
                                Rectangle().fill(c.lampRing.opacity(0.34))
                                    .frame(width: 0.8, height: lh * 0.66)
                            }
                        }
                    }
                    .overlay(alignment: .top) {
                        Capsule().fill(c.lampRing.opacity(0.92))
                            .frame(width: lw * 0.5, height: 2).offset(y: 1.6)
                    }
                    .overlay(alignment: .bottom) {
                        Capsule().fill(c.lampRing.opacity(0.92))
                            .frame(width: lw * 0.5, height: 2).offset(y: -1.6)
                    }
                // 底下那点火
                Circle()
                    .fill(c.lampRing.opacity(lit ? 0.95 : 0.55))
                    .frame(width: lw * 0.22, height: lw * 0.22)
                    .blur(radius: 0.6)
            }
            .shadow(color: c.lamp.opacity(lit ? 0.85 : 0.42), radius: lit ? 20 : 11)
            .rotationEffect(.degrees(sway), anchor: .top)
            .animation(Motion.spring(0.55), value: lit)
        }
    }

    private func lightLantern(_ k: Int, at p: CGPoint) {
        withAnimation(Motion.spring(0.45)) { lampLit[k] = true }
        drop(at: p)
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.2) {
            withAnimation(Motion.spring(0.7)) { lampLit[k] = false }
        }
    }

    /* ---------------- 桂枝（可点可拖） ---------------- */

    private func branch(_ c: MoonFest.Ink, _ W: CGFloat, _ H: CGFloat) -> some View {
        let bw = W * (compact ? 0.42 : 0.30)
        let bh: CGFloat = compact ? 176 : 210
        let cx = compact ? W * 1.01 : W * 0.975
        let cy = compact ? H * 0.72 : H * 0.27

        return MoonToy(space: Self.space, hit: .box(bw, bh),
                       off: $branchOff, snapBack: true,
                       onTap: { shakeBranch(cx - bw * 0.25, cy * 0.92) }) {
            branchShape(c, bw, bh)
                .rotationEffect(.degrees(branchHot ? 3.0 : 0), anchor: .topTrailing)
                .animation(Motion.spring(0.52), value: branchHot)
        }
        .frame(width: bw, height: bh)
        .offset(x: cx - bw, y: cy - bh / 2)
        .allowsHitTesting(interactive)
    }

    @State private var branchOff: CGSize = .zero

    /// 桂枝从右上角斜伸进来，托住月亮。
    ///
    /// 【为什么推倒重画】
    /// 上一版是「一条 2pt 的等宽笔画 + 三片叶子 + 七个圆点」。用户一眼就说
    /// 太廉价 —— 而且说得对。问题不在数量，在**画法的层级**：
    ///   · 等宽笔画没有体积。真实的枝干是根部粗、梢部尖的锥形。
    ///   · 光秃秃的色块不是叶子。叶子要有叶形、有叶脉、有叶柄。
    ///   · 几个小圆点不是桂花。桂花的特点是**成簇**开在叶腋，一朵有瓣有蕊。
    /// 所以这一版三处全换画法，细节一下子多了一个量级。
    ///
    /// 【第二次返工：形态与配色】
    /// 重画之后用户仍然说廉价。逐帧对着看，问题出在三处**不是细节、是骨架**
    /// 的地方 —— 补更多叶子桂花都没用，得先修骨架：
    ///   · **颜色**：枝干用了 `eave`（檐角暖白）。在深靛蓝夜空上那就是一根
    ///     **白粉笔划痕**，而且它横穿画面正中央，像屏幕裂了。改用 `bark`
    ///     木褐，枝才退回第二层去当「枝」。
    ///   · **曲率**：控制点 `b` 几乎落在 `a→c` 的连线上，所以画出来是直线。
    ///     枝必须有明显的弧 —— 现在把 `b` 往右上顶出去（见下面那段注释），
    ///     整根枝成了「从上垂下来、梢部往下坠」的那道弯。
    ///   · **锥度**：`r0=0.0265` 在 210pt 高的画布上是 5.6pt 半径（11pt 粗），
    ///     对一枝细桂来说太肥了，看着像一根棍子。收到 0.0205。
    private func branchShape(_ c: MoonFest.Ink, _ bw: CGFloat, _ bh: CGFloat) -> some View {
        // 主枝的中轴线：一条二次贝塞尔。起点在画面右上角之外，
        // 梢部斜伸到左下 —— 「从画外伸进来一枝」的构图。
        //
        // ★ b 点为什么在 (0.66, 0.02) ★
        //   a→c 的连线中点在 (0.58, 0.34) 附近。b 如果落在那儿，二次贝塞尔
        //   退化成一条直线。现在把 b 往**右上**顶出去 0.32 个高度，
        //   整根枝就成了「根部从右上角垂下来、中段鼓向左上、梢部坠向左下」
        //   的那道弧 —— 也有了这个弧度，月亮才能被枝「托住」而不是被划开。
        let a = CGPoint(x: 1.14, y: -0.07)
        let b = CGPoint(x: 0.66, y: 0.02)
        let c2 = CGPoint(x: 0.02, y: 0.76)

        // 光从右上的月亮来：靠近枝身下缘（背光面）暗，上缘（受光面）亮。
        // 用横向渐变而不是纯色，枝才有「圆」的感觉 —— 一根纯色带永远
        // 看着是一片纸。
        let bark = LinearGradient(
            colors: [c.barkLit.opacity(scheme == .dark ? 0.86 : 0.78),
                     c.bark.opacity(scheme == .dark ? 0.88 : 0.82)],
            startPoint: .top, endPoint: .bottom)

        return ZStack(alignment: .topLeading) {
            /* ── ① 主枝 ─────────────────────────────────────────────
               一根有锥度的枝：沿中轴线取法线，左右各偏一个递减的半径，
               围成一条闭合带，一次填充。根粗梢尖，弯得随便。
               为什么不用「堆一排圆点」（上一版的做法）：那样必须保证
               相邻圆的**直径大于点距**，否则圆与圆之间露缝 —— 表现就是
               一根「念珠」。而梢部直径本来就只有 1pt 量级，要点距也降到
               1pt 就得几百个圆。法线偏移法采样十几个点就够平滑。 */
            TaperedBranch(a: a, b: b, c: c2, r0: 0.0205, r1: 0.0030)
                .fill(bark)
                .frame(width: bw, height: bh)

            /* ── ② 两根从主枝上分出来的小枝 ─────────────────────────
               小枝一律朝**左下**分（远离右上角的月亮那侧）——
               这是树的真实姿态：枝条朝光长，但侧枝是往外张开的。
               两根的曲率给得不一样（一根近乎直、一根明显弯），
               不然两根平行的弯枝会像一对筷子。 */
            ForEach(0..<2, id: \.self) { k in
                let t0 = [0.40, 0.70][k]
                let root = qbez(CGPoint(x: a.x * bw, y: a.y * bh),
                                CGPoint(x: b.x * bw, y: b.y * bh),
                                CGPoint(x: c2.x * bw, y: c2.y * bh), t0)
                TaperedBranch(
                    a: CGPoint(x: root.x / bw, y: root.y / bh),
                    b: CGPoint(x: root.x / bw - [0.11, 0.15][k],
                               y: root.y / bh + [0.07, 0.00][k]),
                    c: CGPoint(x: root.x / bw - [0.18, 0.15][k],
                               y: root.y / bh + [0.15, 0.21][k]),
                    r0: 0.0086, r1: 0.0019, steps: 18)
                .fill(bark)
                .frame(width: bw, height: bh)
            }

            /* ── ③ 叶：六片，革质椭圆带尖，带叶柄与叶脉 ─────────
               一片叶子上三样东西，缺一片叶子就还是「一块绿」：
                 · 叶柄：叶根那端一小截深色短杆，把叶子和枝连起来
                 · 主脉：贯穿全长的一条亮线
                 · 侧脉：从主脉斜向后方的 4 条短线 —— 这是最划算的一笔，
                   4 条 0.5pt 的短线，让叶子看上去是**有厚度、会透光**的
                   组织，而不是一张贴上去的绿色形状。
               侧脉的倾角统一朝叶尖方向偏（+18°），真实叶脉就是这个走向。*/
            ForEach(0..<6, id: \.self) { k in
                let sp = Self.leaves[k]
                let lw = bw * sp.len
                let lh = bh * sp.wid
                ZStack(alignment: .leading) {
                    LeafShape()
                        .fill(LinearGradient(
                            colors: [c.leaf.opacity(scheme == .dark ? 0.90 : 0.82),
                                     c.leaf.opacity(scheme == .dark ? 0.52 : 0.44)],
                            startPoint: .leading, endPoint: .trailing))

                    // 叶柄（在叶身左侧、伸出一点点）
                    Capsule()
                        .fill(c.bark.opacity(scheme == .dark ? 0.80 : 0.72))
                        .frame(width: lw * 0.16, height: max(0.8, lh * 0.075))
                        .offset(x: -lw * 0.10)

                    // 主脉
                    Capsule()
                        .fill(c.leaf.opacity(scheme == .dark ? 0.98 : 0.92))
                        .frame(width: lw * 0.82, height: max(0.7, lh * 0.055))
                        .offset(x: lw * 0.08)

                    // 侧脉：4 条，从主脉斜向叶缘
                    ForEach(0..<4, id: \.self) { j in
                        let u = 0.22 + Double(j) * 0.17
                        let dir: Double = j % 2 == 0 ? -1 : 1
                        Capsule()
                            .fill(c.leaf.opacity(scheme == .dark ? 0.86 : 0.78))
                            .frame(width: lw * 0.20, height: max(0.6, lh * 0.048))
                            .rotationEffect(.degrees(dir * 30))
                            .offset(x: lw * CGFloat(u), y: CGFloat(dir) * lh * 0.17)
                    }
                }
                .frame(width: lw, height: lh)
                .rotationEffect(.degrees(sp.deg))
                .position(x: bw * sp.x, y: bh * sp.y)
            }

            /* ── ④ 金桂：三簇，成簇地开在叶腋处 ─────────────────── */
            ForEach(0..<3, id: \.self) { k in
                osmanthusCluster(c, bh * [0.058, 0.051, 0.044][k], k * 7,
                                 dark: scheme == .dark)
                    .position(x: bw * [0.63, 0.43, 0.24][k],
                              y: bh * [0.36, 0.50, 0.64][k])
            }
        }
        .frame(width: bw, height: bh)
    }


    private func shakeBranch(_ x: CGFloat, _ y: CGFloat) {
        withAnimation(Motion.spring(0.45)) { branchHot = true }
        drop(at: CGPoint(x: x, y: y))
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.85) {
            withAnimation(Motion.spring(0.7)) { branchHot = false }
        }
    }

    /* ---------------- 青玉兔（可点可拖） ---------------- */

    private func rabbit(_ c: MoonFest.Ink, _ W: CGFloat, _ H: CGFloat) -> some View {
        // 兔子本体（含耳朵）的边长。全屏 104pt、弹窗里 88pt。
        let side: CGFloat = compact ? 88 : 104
        let boxW = side * 1.16, boxH = side * 1.10
        let base = compact ? CGPoint(x: W * 0.245, y: H * 0.695)
                           : CGPoint(x: W * 0.778, y: H * 0.165)

        return MoonToy(space: Self.space, hit: .box(boxW, boxH),
                       off: $rabbitOff, snapBack: false,
                       onTap: { hops += 1; drop(at: CGPoint(x: base.x, y: base.y + 14)) }) {
            rabbitGlyph(c, side / 100)
                .offset(y: -abs(sin(Double(hops) * 1.4)) * 6)
                .animation(Motion.spring(0.42), value: hops)
        }
        .frame(width: boxW, height: boxH)
        .offset(x: base.x - boxW / 2, y: base.y - boxH / 2)
        .allowsHitTesting(interactive)
    }

    /// 青玉兔（侧坐，面朝左，抬头看月）。
    ///
    /// 【为什么推倒重画】
    /// 上一版是「几个圆加一个圆角矩形拼出来的」：头一个圆、身子一个横盒子、
    /// 耳朵两根短胶囊。用户评为廉价 —— 而且说得对，拼圆拼不出动物的剪影，
    /// 那种画法无论怎么调参数都像一枚贴纸。
    ///
    /// 这一版的整只兔子由**一条闭合贝塞尔路径**（`RabbitBody`）画出来：
    /// 长耳后倾、额头到鼻尖的下斜面、拱起的脊背、蹲坐的圆臀、收在身下的
    /// 前爪 —— 全在一条轮廓里。轮廓之上再叠六处细节：
    ///   ① 耳内暖色（兔耳的辨识度一半来自这里）
    ///   ② 后腿的分界弧线（画出「蹲」这个姿势）
    ///   ③ 尾巴（球状，比身体亮一档）
    ///   ④ 眼睛（含一枚高光点 —— 没有高光的眼睛是死的）
    ///   ⑤ 鼻尖与三根胡须
    ///   ⑥ 最后一道顶部的边缘光，把白色剪影从深色背景里「托」出来
    ///
    /// `s` = 「100 画布单位 → 多少 pt」。
    ///
    /// 【第二次返工：为什么原来是灰蓝色的一只老鼠】
    /// 剪影画对了，但**毛用了 `cloud`** —— 那是云气的蓝灰 (0.64,0.70,0.86)。
    /// 在一片深靛蓝夜空上，一块蓝灰的剪影读起来不是「白兔趴着」，而是
    /// 「一只灰色的老鼠」。玉兔的「玉」字就是全部重点：它的毛必须是**接近
    /// 月轮那种冷调的白**（现在用 `c.fur`，深色下 (0.91,0.93,0.96)），
    /// 而且要比月轮暗一档 —— 不然它飘到月上就糊成一团。
    ///
    /// 同时把边缘光做**实**：不再是一圈淡描边，而是「上缘一道亮、下缘一道
    /// 更暗的轮廓」，白色剪影才从夜空里被「托」出来，而不是浮在上面。
    private func rabbitGlyph(_ c: MoonFest.Ink, _ s: CGFloat) -> some View {
        let fur = LinearGradient(
            colors: [c.fur.opacity(scheme == .dark ? 1.00 : 1.00),
                     c.fur.opacity(scheme == .dark ? 0.72 : 0.88)],
            startPoint: .top, endPoint: .bottom)
        let rim = c.moonCore.opacity(scheme == .dark ? 0.94 : 0.98)
        let earIn = c.petal.opacity(scheme == .dark ? 0.62 : 0.48)
        let ink = c.ridge.opacity(scheme == .dark ? 0.92 : 0.74)
        let shade = c.cloud.opacity(scheme == .dark ? 0.30 : 0.22)

        return ZStack(alignment: .topLeading) {
            // ① 剪影
            RabbitBody()
                .fill(fur)
                .frame(width: 100 * s, height: 100 * s)

            // ② 下缘的暗轮廓（不是描边，是「身体压出来的一道影」）——
            //    它负责让白兔的屁股和前爪从夜空里分出前后。
            RabbitBody()
                .stroke(shade, lineWidth: 1.6 * s)
                .frame(width: 100 * s, height: 100 * s)
                .blur(radius: 0.9 * s)
                .offset(y: 0.7 * s)

            // ③ 上缘的亮边（月光从右上打下来）
            RabbitBody()
                .stroke(LinearGradient(colors: [rim, rim.opacity(0.0)],
                                       startPoint: .top, endPoint: .bottom),
                        lineWidth: 1.5 * s)
                .frame(width: 100 * s, height: 100 * s)

            // ④ 耳内（暖金）。兔耳的辨识度一半来自这里 ——
            //    上一版用了暗金 `moonGlow` 的 40% 透明，几乎看不见。
            RabbitEarInner()
                .fill(earIn)
                .frame(width: 100 * s, height: 100 * s)

            // ⑤ 后腿分界：从腰侧绕到脚跟的一道弧线。蹲姿的关键一笔 ——
            //    没有它，整只兔子就是一只没长腿的团子。
            Path { p in
                p.move(to: CGPoint(x: 46 * s, y: 66 * s))
                p.addQuadCurve(to: CGPoint(x: 26 * s, y: 95 * s),
                               control: CGPoint(x: 24 * s, y: 78 * s))
            }
            .stroke(ink.opacity(0.26),
                    style: StrokeStyle(lineWidth: 1.0 * s, lineCap: .round))

            // ⑥ 前爪的趾缝：底座右前方一小道弧，把「爪子」从身体里分出来
            Path { p in
                p.move(to: CGPoint(x: 64 * s, y: 93 * s))
                p.addQuadCurve(to: CGPoint(x: 73 * s, y: 84 * s),
                               control: CGPoint(x: 72 * s, y: 90 * s))
            }
            .stroke(ink.opacity(0.20),
                    style: StrokeStyle(lineWidth: 0.9 * s, lineCap: .round))

            // ⑦ 下颌线：把「头」和「胸」分开的一小道弧。
            //    耳朵长在头顶、眼睛画在脸上，但头和身子还是一整块 ——
            //    这一笔是让它读成「一只缩着脖子看月亮的兔子」而不是「团子」。
            Path { p in
                p.move(to: CGPoint(x: 89 * s, y: 60 * s))
                p.addQuadCurve(to: CGPoint(x: 76 * s, y: 67 * s),
                               control: CGPoint(x: 83 * s, y: 66 * s))
            }
            .stroke(ink.opacity(0.17),
                    style: StrokeStyle(lineWidth: 0.9 * s, lineCap: .round))

            // ⑧ 尾巴：球状，比身体再亮一档（月亮正打在那一侧）
            Circle()
                .fill(c.moonCore.opacity(scheme == .dark ? 0.96 : 1.00))
                .frame(width: 15 * s, height: 15 * s)
                .position(x: 7 * s, y: 76 * s)
                .shadow(color: c.moonGlow.opacity(0.38), radius: 4 * s)

            // ⑨ 眼睛（+高光）、眉弓、鼻尖
            Circle().fill(ink).frame(width: 5.2 * s, height: 5.2 * s)
                .position(x: 84 * s, y: 49 * s)
            Circle().fill(.white.opacity(0.95)).frame(width: 1.8 * s, height: 1.8 * s)
                .position(x: 82.6 * s, y: 47.6 * s)
            // 眉弓：眼睛上方一道短弧。兔子的眉弓是它「神情」的全部来源，
            // 少了这一笔，眼睛就是贴在脸上的两颗黑豆。
            Path { p in
                p.move(to: CGPoint(x: 79.5 * s, y: 43.5 * s))
                p.addQuadCurve(to: CGPoint(x: 88.5 * s, y: 44.5 * s),
                               control: CGPoint(x: 84 * s, y: 41 * s))
            }
            .stroke(ink.opacity(0.34),
                    style: StrokeStyle(lineWidth: 1.0 * s, lineCap: .round))
            // 鼻尖：一枚暖色小椭圆，落在轮廓的鼻尖那个点上
            Ellipse().fill(earIn.opacity(0.85)).frame(width: 3.8 * s, height: 2.6 * s)
                .position(x: 95.5 * s, y: 55.5 * s)

            // ⑩ 胡须：三根，从鼻侧向前下方扫出去
            Path { p in
                p.move(to: CGPoint(x: 94 * s, y: 57.5 * s))
                p.addQuadCurve(to: CGPoint(x: 100 * s, y: 61 * s),
                               control: CGPoint(x: 97.5 * s, y: 58.5 * s))
                p.move(to: CGPoint(x: 94 * s, y: 60 * s))
                p.addQuadCurve(to: CGPoint(x: 99.5 * s, y: 65 * s),
                               control: CGPoint(x: 97.5 * s, y: 62 * s))
                p.move(to: CGPoint(x: 93.5 * s, y: 62.5 * s))
                p.addQuadCurve(to: CGPoint(x: 98 * s, y: 68.5 * s),
                               control: CGPoint(x: 96.5 * s, y: 65 * s))
            }
            .stroke(ink.opacity(0.30),
                    style: StrokeStyle(lineWidth: 0.8 * s, lineCap: .round))
        }
        .frame(width: 100 * s, height: 100 * s)
        .shadow(color: c.moonGlow.opacity(0.34), radius: 11)
    }

    /* ---------------- 飘落的金桂 ---------------- */

    @ViewBuilder
    private func petals(_ c: MoonFest.Ink, _ W: CGFloat, _ H: CGFloat, _ t: Double) -> some View {
        ZStack(alignment: .topLeading) {
            ForEach(0..<petalCount, id: \.self) { k in
                let speed = 0.011 + rnd(k, 31) * 0.019
                let x0 = CGFloat(rnd(k, 32)) * W
                let sway = CGFloat(9 + rnd(k, 33) * 26)
                let ph = rnd(k, 34) * 6.283
                let y = CGFloat(falloff(t * speed + rnd(k, 35))) * (H + 70) - 35
                let x = x0 + CGFloat(sin(t * 0.46 + ph)) * sway
                let sz = CGFloat(4.2 + rnd(k, 36) * 3.6)
                PetalShape()
                    .fill(c.petal.opacity(scheme == .dark ? 0.46 : 0.34))
                    .frame(width: sz, height: sz * 1.55)
                    .rotationEffect(.degrees(sin(t * 0.66 + ph) * 46))
                    .position(x: x, y: y)
            }
        }
        .frame(width: W, height: H, alignment: .topLeading)
    }

    /* ---------------- 点下去的那一捧桂 ---------------- */

    @ViewBuilder
    private func burstLayer(_ c: MoonFest.Ink, _ t: Double) -> some View {
        ZStack {
            ForEach(bursts) { b in
                let prog = (t - b.t0) / 1.55
                if prog >= 0, prog <= 1 {
                    let fade = 1 - prog
                    ZStack {
                        ForEach(0..<9, id: \.self) { k in
                            let ang = Double(k) / 9.0 * 6.283 + rnd(b.seed, k) * 0.55
                            let dist = CGFloat(26 + rnd(b.seed, 100 + k) * 62) * CGFloat(prog)
                            let sz = CGFloat(4.4 + rnd(b.seed, 200 + k) * 3.8)
                            PetalShape()
                                .fill(c.petal.opacity(fade * 0.78))
                                .frame(width: sz, height: sz * 1.55)
                                .rotationEffect(.degrees(prog * 420 + rnd(b.seed, 300 + k) * 200))
                                .offset(x: CGFloat(cos(ang)) * dist,
                                        y: CGFloat(sin(ang)) * dist * 0.74 + CGFloat(prog * prog) * 30)
                        }
                        // 一圈慢慢淡开的月华
                        Circle()
                            .strokeBorder(c.moonGlow.opacity(fade * 0.45), lineWidth: 1.1)
                            .frame(width: 20 + CGFloat(prog) * 118,
                                   height: 20 + CGFloat(prog) * 118)
                    }
                    .position(b.p)
                }
            }
        }
    }

    /* ---------------- 远山与檐角 ---------------- */

    @ViewBuilder
    private func ridge(_ c: MoonFest.Ink, _ W: CGFloat, _ H: CGFloat,
                       _ moon: CGPoint, _ r: CGFloat) -> some View {
        ZStack {
            // 月在水面/云海上的倒影：一道很淡的竖向拉长柔光
            Capsule()
                .fill(LinearGradient(colors: [c.moonGlow.opacity(0.15),
                                              c.moonGlow.opacity(0)],
                                     startPoint: .top, endPoint: .bottom))
                .frame(width: r * 1.5, height: H * 0.30)
                .blur(radius: r * 0.55)
                .position(x: moon.x, y: H * 0.985)

            // 远山
            Path { p in
                p.move(to: CGPoint(x: 0, y: H))
                p.addLine(to: CGPoint(x: 0, y: H * 0.905))
                p.addQuadCurve(to: CGPoint(x: W * 0.28, y: H * 0.845),
                               control: CGPoint(x: W * 0.14, y: H * 0.792))
                p.addQuadCurve(to: CGPoint(x: W * 0.56, y: H * 0.912),
                               control: CGPoint(x: W * 0.43, y: H * 0.968))
                p.addQuadCurve(to: CGPoint(x: W * 0.82, y: H * 0.868),
                               control: CGPoint(x: W * 0.70, y: H * 0.802))
                p.addQuadCurve(to: CGPoint(x: W, y: H * 0.918),
                               control: CGPoint(x: W * 0.92, y: H * 0.884))
                p.addLine(to: CGPoint(x: W, y: H))
                p.closeSubpath()
            }
            .fill(c.ridge.opacity(scheme == .dark ? 0.62 : 0.26))
            .blur(radius: 1.6)

            // 中式檐角：一根细线，压在右下角的山脊上。比画一整座楼含蓄得多。
            EavesShape()
                .stroke(c.eave.opacity(scheme == .dark ? 0.20 : 0.16),
                        style: StrokeStyle(lineWidth: 1.2, lineCap: .round))
                .frame(width: min(150, W * 0.16), height: min(50, H * 0.062))
                .position(x: W * 0.885, y: H * 0.905)
        }
    }

    /* ---------------- 点击动作 ---------------- */

    private func hitMoon(_ moon: CGPoint) {
        withAnimation(Motion.spring(0.5)) { moonHot = true }
        drop(at: moon, wide: true)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) {
            withAnimation(Motion.spring(0.75)) { moonHot = false }
        }
    }

    private func drop(at p: CGPoint, wide: Bool = false) {
        let now = Date.timeIntervalSinceReferenceDate
        bursts.append(MoonBurst(p: p, t0: now, seed: Int(now * 1000) & 0xffff))
        let cap = wide ? 5 : 6
        if bursts.count > cap { bursts.removeFirst(bursts.count - cap) }
    }
}

/* ---------------- 月面斑驳 ----------------
   四块黑斑裁在月轮里，重度模糊之后就是「月海」——
   一眼能看出这不是一枚纯白的圆片。

   ★ 模糊量必须**跟半径成比例、且下限给足** ★
   上一版是 `blur(max(1.2, r * 0.11))`。全屏的月亮 r≈78，得到 8.6pt 的
   模糊，斑点柔柔地化开，是对的；但侧栏小景那颗月亮只有 r≈15，下限
   1.2 生效，8pt 直径的斑点只糊了 1.2pt —— 边界清清楚楚的四个灰圆，
   看着像月面上长了**霉点**。所以下限提到 3.4、系数提到 0.19：
   小月亮下得到 3.4pt（相对于 15pt 的半径已经很糊），
   全屏下得到 14.8pt（比原来更柔，也更像云影）。 */
private struct MoonMarks: View {
    let r: CGFloat

    var body: some View {
        ZStack {
            Circle().fill(.black.opacity(0.85)).frame(width: r * 0.54)
                .offset(x: -r * 0.24, y: -r * 0.28)
            Circle().fill(.black.opacity(0.85)).frame(width: r * 0.34)
                .offset(x: r * 0.31, y: r * 0.09)
            Circle().fill(.black.opacity(0.85)).frame(width: r * 0.25)
                .offset(x: r * 0.03, y: r * 0.44)
            Circle().fill(.black.opacity(0.85)).frame(width: r * 0.18)
                .offset(x: -r * 0.43, y: r * 0.31)
        }
        .frame(width: r * 2, height: r * 2)
        .clipShape(Circle())
        .blur(radius: max(3.4, r * 0.19))
    }
}

/* ---------------- 一片桂花瓣 ---------------- */

struct PetalShape: Shape {
    func path(in r: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: r.midX, y: r.minY))
        p.addQuadCurve(to: CGPoint(x: r.midX, y: r.maxY),
                       control: CGPoint(x: r.maxX, y: r.midY))
        p.addQuadCurve(to: CGPoint(x: r.midX, y: r.minY),
                       control: CGPoint(x: r.minX, y: r.midY))
        p.closeSubpath()
        return p
    }
}

/* ---------------- 中式屋檐剪影 ---------------- */

struct EavesShape: Shape {
    func path(in r: CGRect) -> Path {
        let w = r.width, h = r.height
        var p = Path()
        // 上翘的檐口
        p.move(to: CGPoint(x: 0, y: h * 0.66))
        p.addQuadCurve(to: CGPoint(x: w, y: h * 0.30),
                       control: CGPoint(x: w * 0.52, y: h * 0.60))
        // 檐角的小翘头
        p.addLine(to: CGPoint(x: w * 0.86, y: h * 0.44))
        // 两根柱子
        p.move(to: CGPoint(x: w * 0.30, y: h * 0.62))
        p.addLine(to: CGPoint(x: w * 0.30, y: h))
        p.move(to: CGPoint(x: w * 0.70, y: h * 0.53))
        p.addLine(to: CGPoint(x: w * 0.70, y: h))
        return p
    }
}

/* ======================================================================
   ④ 侧边栏的小景：月 · 桂 · 玉兔 · 灯笼
   ----------------------------------------------------------------------
   位置挑得很保守：侧边栏导航与底部状态条之间那段**本来就是空的**。
   整块地儿不放任何控件，所以在这里放几个能点的东西，永远不会挡住功能。
   四个都能点，玉兔和月亮还能拖。
   ====================================================================== */

struct MidAutumnGrove: View {

    let env: Env

    @Environment(\.colorScheme) private var scheme
    @State private var hops = 0
    @State private var moonOn = false
    @State private var lampOn = false
    @State private var bursts: [MoonBurst] = []
    @State private var rabbitOff: CGSize = .zero
    @State private var moonOff: CGSize = .zero

    private var c: MoonFest.Ink { MoonFest.ink(scheme) }
    private var paused: Bool { env.settings.reduceMotion || Motion.reduced }

    var body: some View {
        GeometryReader { geo in
            let W = max(1, geo.size.width)
            let H = max(1, geo.size.height)
            ZStack(alignment: .topLeading) {
                sky(W, H)
                TimelineView(.animation(minimumInterval: 1.0 / 20.0, paused: paused)) { ctx in
                    let t = ctx.date.timeIntervalSinceReferenceDate
                    ZStack(alignment: .topLeading) {
                        twinkle(W, H, t)
                        drift(W, H, t)
                        burstLayer(t)
                    }
                    .frame(width: W, height: H, alignment: .topLeading)
                }
                .frame(width: W, height: H, alignment: .topLeading)
                branch(W, H)
                moon(W, H)
                lamp(W, H)
                rabbit(W, H)
            }
            .frame(width: W, height: H, alignment: .topLeading)
            .coordinateSpace(name: MoonNightBackdrop.space)
            .clipShape(RoundedRectangle(cornerRadius: env.radius(Radius.md), style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: env.radius(Radius.md), style: .continuous)
                    .strokeBorder(c.moonGlow.opacity(scheme == .dark ? 0.22 : 0.28), lineWidth: 1)
            }
        }
    }

    /* ---------------- 底 ---------------- */

    private func sky(_ W: CGFloat, _ H: CGFloat) -> some View {
        ZStack {
            LinearGradient(colors: [c.skyTop.opacity(scheme == .dark ? 0.94 : 0.72),
                                    c.skyBottom.opacity(scheme == .dark ? 0.96 : 0.80)],
                           startPoint: .top, endPoint: .bottom)
            // 月亮挪到右上角之后，这片底光也跟着挪 —— 光和月亮不能分家。
            Circle()
                .fill(RadialGradient(colors: [c.moonGlow.opacity(scheme == .dark ? 0.28 : 0.20),
                                              c.moonGlow.opacity(0)],
                                     center: .center, startRadius: 0, endRadius: W * 0.58))
                .frame(width: W * 1.2, height: W * 1.2)
                .position(x: W * 0.78, y: H * 0.22)
        }
    }

    @ViewBuilder
    private func twinkle(_ W: CGFloat, _ H: CGFloat, _ t: Double) -> some View {
        ZStack(alignment: .topLeading) {
            ForEach(0..<12, id: \.self) { k in
                let x = CGFloat(rnd(k, 61)) * W
                let y = CGFloat(rnd(k, 62)) * H * 0.6
                let s = 0.9 + CGFloat(rnd(k, 63)) * 1.3
                let tw = 0.5 + 0.5 * sin(t * (0.6 + rnd(k, 64)) + rnd(k, 65) * 6.28)
                Circle()
                    .fill(c.star.opacity((0.16 + 0.36 * tw) * (scheme == .dark ? 1 : 0.5)))
                    .frame(width: s, height: s)
                    .position(x: x, y: y)
            }
        }
        .frame(width: W, height: H, alignment: .topLeading)
    }

    @ViewBuilder
    private func drift(_ W: CGFloat, _ H: CGFloat, _ t: Double) -> some View {
        ZStack(alignment: .topLeading) {
            ForEach(0..<7, id: \.self) { k in
                let speed = 0.020 + rnd(k, 71) * 0.026
                let x0 = CGFloat(rnd(k, 72)) * W
                let y = CGFloat(falloff(t * speed + rnd(k, 73))) * (H + 26) - 13
                let x = x0 + CGFloat(sin(t * 0.5 + rnd(k, 74) * 6.28)) * 8
                let sz = CGFloat(3.2 + rnd(k, 75) * 2.4)
                PetalShape()
                    .fill(c.petal.opacity(scheme == .dark ? 0.50 : 0.38))
                    .frame(width: sz, height: sz * 1.5)
                    .rotationEffect(.degrees(sin(t * 0.7 + rnd(k, 76) * 6.28) * 40))
                    .position(x: x, y: y)
            }
        }
        .frame(width: W, height: H, alignment: .topLeading)
    }

    @ViewBuilder
    private func burstLayer(_ t: Double) -> some View {
        ZStack {
            ForEach(bursts) { b in
                let prog = (t - b.t0) / 1.35
                if prog >= 0, prog <= 1 {
                    let fade = 1 - prog
                    ZStack {
                        ForEach(0..<7, id: \.self) { k in
                            let ang = Double(k) / 7.0 * 6.283 + rnd(b.seed, k) * 0.5
                            let dist = CGFloat(14 + rnd(b.seed, 40 + k) * 40) * CGFloat(prog)
                            let sz = CGFloat(3.4 + rnd(b.seed, 80 + k) * 3)
                            PetalShape()
                                .fill(c.petal.opacity(fade * 0.8))
                                .frame(width: sz, height: sz * 1.5)
                                .rotationEffect(.degrees(prog * 380 + rnd(b.seed, 120 + k) * 180))
                                .offset(x: CGFloat(cos(ang)) * dist,
                                        y: CGFloat(sin(ang)) * dist * 0.7)
                        }
                        Circle()
                            .strokeBorder(c.moonGlow.opacity(fade * 0.42), lineWidth: 1)
                            .frame(width: 12 + CGFloat(prog) * 64)
                    }
                    .position(b.p)
                }
            }
        }
    }

    private func puff(_ p: CGPoint) {
        let now = Date.timeIntervalSinceReferenceDate
        bursts.append(MoonBurst(p: p, t0: now, seed: Int(now * 1000) & 0xffff))
        if bursts.count > 4 { bursts.removeFirst(bursts.count - 4) }
    }

    /* ---------------- 月（可点可拖） ---------------- */

    private func moon(_ W: CGFloat, _ H: CGFloat) -> some View {
        let r = min(19, W * 0.092)
        let box = r * 2.6
        let cx = W * 0.74, cy = H * 0.245

        return MoonToy(space: MoonNightBackdrop.space, hit: .circle(r * 1.25),
                       off: $moonOff, snapBack: true,
                       onTap: {
                           withAnimation(Motion.spring(0.4)) { moonOn = true }
                           puff(CGPoint(x: cx, y: cy))
                           DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) {
                               withAnimation(Motion.spring(0.7)) { moonOn = false }
                           }
                       }) {
            ZStack {
                Circle()
                    .fill(RadialGradient(colors: [c.moonGlow.opacity(moonOn ? 0.58 : 0.36),
                                                  c.moonGlow.opacity(0)],
                                         center: .center, startRadius: r * 0.6, endRadius: r * 4))
                    .frame(width: r * 8, height: r * 8)
                Circle()
                    .fill(RadialGradient(colors: [c.moonCore, c.moonCore, c.moonGlow.opacity(0.95)],
                                         center: UnitPoint(x: 0.40, y: 0.34),
                                         startRadius: 0, endRadius: r * 1.3))
                    .frame(width: r * 2, height: r * 2)
                    .overlay {
                        Circle().strokeBorder(c.moonGlow.opacity(scheme == .dark ? 0.26 : 0.46),
                                              lineWidth: 0.8)
                    }
                    .shadow(color: c.moonGlow.opacity(0.58), radius: r * 0.7)
                MoonMarks(r: r).opacity(scheme == .dark ? 0.24 : 0.12)
            }
            .scaleEffect(moonOn ? 1.10 : 1)
            .animation(Motion.hover, value: moonOn)
        }
        .frame(width: box, height: box)
        .offset(x: cx - box / 2, y: cy - box / 2)
    }

    /* ---------------- 桂枝 ---------------- */

    /// 小景里的桂枝。
    ///
    /// 【为什么跟主底纹那根不共用一份代码】
    /// 主底纹那根是「从画外斜伸进来、托住月亮」的大枝（210pt 高、六片叶、
    /// 三簇花）；侧栏这块只有 40 来 pt 高，叶片/桂花按比例缩下来就成灰点。
    /// 所以这里尺寸另给，但**画法完全一致**：同样是 `TaperedBranch` 的
    /// 锥形带 + `LeafShape` 带叶脉的叶 + `osmanthusCluster` 成簇的花。
    /// 两处一致的是「画法层级」，不是「像素尺寸」—— 这才是关键。
    ///
    /// 【上一版为什么廉价】
    /// 一根 1.6pt 的暖白 `stroke` + 三片 `c.eave`（暖白）的叶子 + 五个
    /// 小圆点。三个问题一次犯齐：等宽笔画没体积、叶子是白的不像叶子、
    /// 花是圆点不像花。现在三个都换掉。
    private func branch(_ W: CGFloat, _ H: CGFloat) -> some View {
        // 小景里的枝：从左上的月亮往右下斜伸出去，梢部收在画面内。
        let bw = W * 0.72, bh = H * 0.62
        let a = CGPoint(x: 1.06, y: 0.04)
        let b = CGPoint(x: 0.60, y: -0.06)
        let c2 = CGPoint(x: 0.00, y: 0.72)

        let bark = LinearGradient(
            colors: [c.barkLit.opacity(scheme == .dark ? 0.86 : 0.78),
                     c.bark.opacity(scheme == .dark ? 0.88 : 0.82)],
            startPoint: .top, endPoint: .bottom)

        return ZStack(alignment: .topLeading) {
            TaperedBranch(a: a, b: b, c: c2, r0: 0.031, r1: 0.006, steps: 20)
                .fill(bark)
                .frame(width: bw, height: bh)

            // 一根小枝。分叉点先从主枝上算出来 —— 直接把 qbez 内联进
            // TaperedBranch 的参数里会让这条表达式的类型检查爆掉
            // （Swift 的类型推断在长嵌套的 CGPoint 字面量上是指数级的）。
            let fork = qbez(a, b, c2, 0.54)
            TaperedBranch(
                a: fork,
                b: CGPoint(x: fork.x - 0.12, y: fork.y - 0.03),
                c: CGPoint(x: fork.x - 0.19, y: fork.y + 0.17),
                r0: 0.013, r1: 0.003, steps: 14)
            .fill(bark)
            .frame(width: bw, height: bh)

            // 四片叶：带叶柄、主脉、侧脉（跟主底纹同一套画法）
            ForEach(0..<4, id: \.self) { k in
                let sp = Self.groveLeaves[k]
                let lw = bw * sp.len
                let lh = bh * sp.wid
                ZStack(alignment: .leading) {
                    LeafShape()
                        .fill(LinearGradient(
                            colors: [c.leaf.opacity(scheme == .dark ? 0.90 : 0.82),
                                     c.leaf.opacity(scheme == .dark ? 0.52 : 0.44)],
                            startPoint: .leading, endPoint: .trailing))
                    Capsule()
                        .fill(c.bark.opacity(scheme == .dark ? 0.80 : 0.72))
                        .frame(width: lw * 0.16, height: max(0.7, lh * 0.08))
                        .offset(x: -lw * 0.10)
                    Capsule()
                        .fill(c.leaf.opacity(scheme == .dark ? 0.98 : 0.92))
                        .frame(width: lw * 0.82, height: max(0.6, lh * 0.06))
                        .offset(x: lw * 0.08)
                    ForEach(0..<3, id: \.self) { j in
                        let u = 0.26 + Double(j) * 0.21
                        let dir: Double = j % 2 == 0 ? -1 : 1
                        Capsule()
                            .fill(c.leaf.opacity(scheme == .dark ? 0.86 : 0.78))
                            .frame(width: lw * 0.20, height: max(0.5, lh * 0.055))
                            .rotationEffect(.degrees(dir * 30))
                            .offset(x: lw * CGFloat(u), y: CGFloat(dir) * lh * 0.16)
                    }
                }
                .frame(width: lw, height: lh)
                .rotationEffect(.degrees(sp.deg))
                .position(x: bw * sp.x, y: bh * sp.y)
            }

            // 两簇金桂
            ForEach(0..<2, id: \.self) { k in
                osmanthusCluster(c, bh * [0.115, 0.098][k], 40 + k * 7,
                                 dark: scheme == .dark)
                    .position(x: bw * [0.62, 0.30][k], y: bh * [0.24, 0.52][k])
            }
        }
        .frame(width: bw, height: bh)
        .position(x: W * 0.62, y: H * 0.30)
    }

    /// 小景四片叶的规格（比例参照主底纹那张表，长度按小景尺寸重给）。
    private static let groveLeaves: [LeafSpec] = [
        .init(len: 0.42, wid: 0.185, deg: -46, x: 0.68, y: 0.16),
        .init(len: 0.36, wid: 0.166, deg:  30, x: 0.74, y: 0.38),
        .init(len: 0.38, wid: 0.172, deg: -58, x: 0.40, y: 0.44),
        .init(len: 0.32, wid: 0.150, deg:  38, x: 0.20, y: 0.68),
    ]

    /* ---------------- 玉兔（可点可拖） ---------------- */

    /// 侧栏小景里的玉兔。
    ///
    /// 【同一套画法，只是尺寸小】
    /// 上一版这里是「两个胶囊当耳朵 + 圆角矩形当身子 + 两个圆当脑袋和尾巴」
    /// —— 跟主底纹那版是一模一样的拼贴法，所以同样廉价。
    /// 现在直接复用 `RabbitBody` / `RabbitEarInner`：**同一只兔子的同一个
    /// 剪影**，只是缩到 40pt。母题一致，整幅画面的玉兔才像同一只。
    private func rabbit(_ W: CGFloat, _ H: CGFloat) -> some View {
        // 兔子本体（含耳朵）的边长。
        let side: CGFloat = 46
        let boxW = side * 1.16, boxH = side * 1.10
        let cx = W * 0.30, cy = H * 0.76
        let s = side / 100

        let fur = LinearGradient(
            colors: [c.fur.opacity(scheme == .dark ? 1.00 : 1.00),
                     c.fur.opacity(scheme == .dark ? 0.72 : 0.88)],
            startPoint: .top, endPoint: .bottom)
        let rim = c.moonCore.opacity(scheme == .dark ? 0.94 : 0.98)
        let earIn = c.petal.opacity(scheme == .dark ? 0.62 : 0.48)
        let ink = c.ridge.opacity(scheme == .dark ? 0.92 : 0.74)
        let shade = c.cloud.opacity(scheme == .dark ? 0.30 : 0.22)

        return MoonToy(space: MoonNightBackdrop.space, hit: .box(boxW, boxH),
                       off: $rabbitOff, snapBack: false,
                       onTap: { hops += 1; puff(CGPoint(x: cx, y: cy + 10)) }) {
            ZStack(alignment: .topLeading) {
                RabbitBody().fill(fur).frame(width: side, height: side)
                RabbitBody().stroke(shade, lineWidth: 1.1)
                    .frame(width: side, height: side)
                    .blur(radius: 0.7).offset(y: 0.5)
                RabbitBody()
                    .stroke(LinearGradient(colors: [rim, rim.opacity(0)],
                                           startPoint: .top, endPoint: .bottom),
                            lineWidth: 1.0)
                    .frame(width: side, height: side)
                RabbitEarInner().fill(earIn).frame(width: side, height: side)

                // 后腿分界
                Path { p in
                    p.move(to: CGPoint(x: 46 * s, y: 66 * s))
                    p.addQuadCurve(to: CGPoint(x: 26 * s, y: 95 * s),
                                   control: CGPoint(x: 24 * s, y: 78 * s))
                }
                .stroke(ink.opacity(0.26),
                        style: StrokeStyle(lineWidth: 1.0 * s, lineCap: .round))

                // 尾巴
                Circle().fill(c.moonCore.opacity(0.96))
                    .frame(width: 15 * s, height: 15 * s)
                    .position(x: 7 * s, y: 76 * s)
                    .shadow(color: c.moonGlow.opacity(0.34), radius: 3)

                // 眼睛 + 高光 + 眉弓 + 鼻尖
                Circle().fill(ink).frame(width: 5.2 * s, height: 5.2 * s)
                    .position(x: 84 * s, y: 49 * s)
                Circle().fill(.white.opacity(0.95)).frame(width: 1.8 * s, height: 1.8 * s)
                    .position(x: 82.6 * s, y: 47.6 * s)
                Path { p in
                    p.move(to: CGPoint(x: 79.5 * s, y: 43.5 * s))
                    p.addQuadCurve(to: CGPoint(x: 88.5 * s, y: 44.5 * s),
                                   control: CGPoint(x: 84 * s, y: 41 * s))
                }
                .stroke(ink.opacity(0.34),
                        style: StrokeStyle(lineWidth: 1.1 * s, lineCap: .round))
                Ellipse().fill(earIn.opacity(0.85)).frame(width: 3.8 * s, height: 2.6 * s)
                    .position(x: 95.5 * s, y: 55.5 * s)
            }
            .frame(width: side, height: side)
            .shadow(color: c.moonGlow.opacity(0.30), radius: 7)
            .offset(y: -abs(sin(Double(hops) * 1.4)) * 5)
            .animation(Motion.spring(0.42), value: hops)
        }
        .frame(width: boxW, height: boxH)
        .offset(x: cx - boxW / 2, y: cy - boxH / 2)
    }

    /* ---------------- 灯笼 ---------------- */

    private func lamp(_ W: CGFloat, _ H: CGFloat) -> some View {
        let len = H * 0.20
        let bodyH: CGFloat = 19, bodyW: CGFloat = 14
        let total = len + bodyH
        let cx = W * 0.855

        return Button {
            withAnimation(Motion.spring(0.45)) { lampOn.toggle() }
            puff(CGPoint(x: cx, y: len + bodyH))
        } label: {
            VStack(spacing: 0) {
                Rectangle().fill(c.star.opacity(0.22)).frame(width: 1, height: len)
                ZStack {
                    Circle()
                        .fill(RadialGradient(colors: [c.lamp.opacity(lampOn ? 0.5 : 0.26),
                                                      c.lamp.opacity(0)],
                                             center: .center, startRadius: 0, endRadius: bodyW * 1.7))
                        .frame(width: bodyW * 3.6, height: bodyW * 3.6)
                    Capsule()
                        .fill(LinearGradient(colors: [c.lamp.opacity(0.98),
                                                      c.lamp.opacity(0.78)],
                                             startPoint: .top, endPoint: .bottom))
                        .frame(width: bodyW, height: bodyH)
                        .overlay(alignment: .top) {
                            Capsule().fill(c.lampRing.opacity(0.9))
                                .frame(width: bodyW * 0.6, height: 2).offset(y: 1.6)
                        }
                        .overlay(alignment: .bottom) {
                            Capsule().fill(c.lampRing.opacity(0.9))
                                .frame(width: bodyW * 0.6, height: 2).offset(y: -1.6)
                        }
                }
                .frame(width: bodyW + 2, height: bodyH + 2)
            }
            .frame(width: bodyW + 4, alignment: .top)
            .rotationEffect(.degrees(lampOn ? 13 : -5), anchor: .top)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .position(x: cx, y: total / 2)
    }
}

/* ---------------- 一片叶子的规格 ----------------
   桂枝上的叶子一共十片（主底纹六片、侧栏小景四片），每片记五个数。
   放在**文件层**而不是塞进 `MoonNightBackdrop`：两处都要用同一张表，
   而且 `MidAutumnGrove` 是另一个 struct —— 嵌套在别处的类型在这里取不到。 */

struct LeafSpec {
    /// 叶长，相对容器宽
    var len: CGFloat
    /// 叶宽，相对容器高
    var wid: CGFloat
    /// 旋转角
    var deg: Double
    /// 位置，相对容器宽
    var x: CGFloat
    /// 位置，相对容器高
    var y: CGFloat
}

/* ---------------- 一枚桂叶 ----------------
   革质**长椭圆带尖**的两段贝塞尔闭合：上缘一条、下缘一条，
   两端收到一个尖。中间最宽处给 0.44 倍高度。

   【为什么不用单条二次贝塞尔拼】
   上一版是「两段 quad 拼」出来的，画出来两端是**钝的圆头** ——
   圆头 + 细长身体 = 竹叶 / 柳叶，一眼不是桂叶。桂叶的特征恰恰是
   「两端都收成尖，中间鼓、边缘略翻卷」。用 cubic 的两条控制点
   分别靠近两端，就同时拿到「中间鼓」和「两端尖」。

   `LeafShape()` 只负责**叶身**。叶柄是画叶子的那个 ZStack 里另外
   补的一根短胶囊（见 branchShape 的 ③），因为叶柄要跟叶脉同色、
   跟叶身异色，塞进 Shape 里反而不好控。 */

struct LeafShape: Shape {
    func path(in r: CGRect) -> Path {
        let w = r.width, h = r.height
        let x0 = r.minX, x1 = r.maxX, my = r.midY
        var p = Path()
        p.move(to: CGPoint(x: x0, y: my))                         // 叶柄端
        p.addCurve(to: CGPoint(x: x1, y: my),                     // 叶尖
                   control1: CGPoint(x: x0 + w * 0.20, y: my - h * 0.46),
                   control2: CGPoint(x: x0 + w * 0.86, y: my - h * 0.42))
        p.addCurve(to: CGPoint(x: x0, y: my),
                   control1: CGPoint(x: x0 + w * 0.86, y: my + h * 0.42),
                   control2: CGPoint(x: x0 + w * 0.20, y: my + h * 0.46))
        p.closeSubpath()
        return p
    }
}

/* ---------------- 有锥度的枝条 ----------------
   沿一条二次贝塞尔中轴线，在每个采样点上算**单位法线**，左右各偏一个
   线性衰减的半径，两侧的点围成一条闭合带，一次 `fill` 出来。
   效果就是「一根根粗梢尖、可以随便弯的枝」。

   【为什么不用「堆一排圆点」】
   上一版就是那么画的，结果整根枝是一串念珠。根因是个硬约束：
   圆点法必须保证**相邻圆的直径大于点距**，否则圆与圆之间露缝。
   而枝的梢部直径本来就只有 1pt 量级 —— 要点距也压到 1pt，
   弧长 300pt 就得排三百个圆。法线偏移法没有这个矛盾：
   点距再大也只是折线粗一点，不会有缝。
   （采样 26 段、最大直径 11pt 时，折线的每段弦高偏差 < 0.03pt，
   肉眼绝对看不出是折线。）

   坐标一律用**归一化**值（相对 rect 的宽高），这样同一个 Shape
   可以被任意尺寸套用 —— 弹窗里 176pt 高、全屏 210pt 高，一套代码。 */

struct TaperedBranch: Shape {
    /// 中轴线：起点 / 控制点 / 终点，归一化
    let a: CGPoint, b: CGPoint, c: CGPoint
    /// 根部半径 / 梢部半径，**相对 rect 高度**
    let r0: CGFloat, r1: CGFloat
    var steps: Int = 26

    func path(in rect: CGRect) -> Path {
        let W = rect.width, H = rect.height
        let A = CGPoint(x: rect.minX + a.x * W, y: rect.minY + a.y * H)
        let B = CGPoint(x: rect.minX + b.x * W, y: rect.minY + b.y * H)
        let C = CGPoint(x: rect.minX + c.x * W, y: rect.minY + c.y * H)

        var left: [CGPoint] = []
        var right: [CGPoint] = []
        left.reserveCapacity(steps + 1)
        right.reserveCapacity(steps + 1)

        for k in 0...steps {
            let t = Double(k) / Double(steps)
            let q = qbez(A, B, C, t)
            // 二次贝塞尔的导数 —— 也就是切线方向
            let dx = 2 * (1 - t) * (B.x - A.x) + 2 * t * (C.x - B.x)
            let dy = 2 * (1 - t) * (B.y - A.y) + 2 * t * (C.y - B.y)
            let len = max(0.0001, hypot(dx, dy))
            // 单位法线：切线转 90°
            let nx = -dy / len, ny = dx / len
            let r = H * (r0 * (1 - t) + r1 * t)
            left.append(CGPoint(x: q.x + nx * r, y: q.y + ny * r))
            right.append(CGPoint(x: q.x - nx * r, y: q.y - ny * r))
        }

        var p = Path()
        p.move(to: left[0])
        for pt in left.dropFirst() { p.addLine(to: pt) }
        // 沿右侧反向回来，梢部自然收成一个尖（两侧最后一点之间那段就是尖）
        for pt in right.reversed() { p.addLine(to: pt) }
        p.closeSubpath()
        return p
    }
}

/* ---------------- 玉兔的剪影 ----------------
   100×100 的归一化画布，**面朝右**、侧坐、抬头。

   ★ 为什么面朝右 ★
   月亮在右上角。上一版兔子朝左 —— 也就是**背对着月亮**坐着。
   单看兔子没问题，放进整幅画面就露了：一只背对光源的动物，气质上
   是「沮丧 / 离开」。同样的轮廓镜像一下，立刻变成「望着月亮」。

   整只兔子（含两只后倾的长耳）是**一条**闭合路径 —— 这是它不像贴纸的
   关键：拼圆拼出来的动物，无论怎么调都是「一堆圆」，而不是一个姿态。

   轮廓上的拐点，每个都对应一个具体的解剖特征：
     鼻尖 → 口鼻上缘 → 眉弓 → 前耳前缘 → 前耳尖 → 前耳后缘 → 耳间浅凹
     → 后耳前缘 → 后耳尖 → 后耳后缘 → 后脑 → 脊背 → 圆臀 → 臀下缘
     → 底座 → 前爪 → 胸口 → 喉 → 下巴 → 回到鼻尖
   耳根画在 x≈45…70 这一带（头部的正上方），而不是长在身体中央 ——
   耳朵的落点错了，整只动物就会读成「一只长耳朵的猪」。 */

struct RabbitBody: Shape {
    func path(in r: CGRect) -> Path {
        let w = r.width / 100, h = r.height / 100
        func P(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: r.minX + x * w, y: r.minY + y * h)
        }
        var p = Path()
        p.move(to: P(96, 54))                                    // 鼻尖
        p.addQuadCurve(to: P(80, 41), control: P(90, 45))        // 口鼻上缘 → 眉弓
        p.addQuadCurve(to: P(70, 33), control: P(75, 36))        // 眉弓 → 前耳前缘
        p.addQuadCurve(to: P(78, 4),  control: P(76, 20))        // 前耳前缘 → 耳尖
        p.addQuadCurve(to: P(61, 30), control: P(66, 12))        // 前耳后缘 → 耳根
        p.addQuadCurve(to: P(57, 31), control: P(59, 33))        // 耳间浅凹
        p.addQuadCurve(to: P(60, 3),  control: P(55, 14))        // 后耳前缘 → 耳尖
        p.addQuadCurve(to: P(43, 33), control: P(44, 12))        // 后耳后缘 → 后脑
        p.addQuadCurve(to: P(22, 43), control: P(33, 36))        // 后脑 → 脊
        p.addQuadCurve(to: P(5, 68),  control: P(8, 50))         // 拱背 → 臀
        p.addQuadCurve(to: P(12, 93), control: P(-2, 88))        // 臀下缘 → 尾根
        p.addQuadCurve(to: P(52, 97), control: P(30, 99))        // 底座后半
        p.addQuadCurve(to: P(72, 90), control: P(63, 96))        // 底座前半 → 前爪
        p.addQuadCurve(to: P(80, 78), control: P(79, 86))        // 胸口
        p.addQuadCurve(to: P(90, 63), control: P(88, 72))        // 喉 → 下巴
        p.addQuadCurve(to: P(96, 54), control: P(95, 58))        // 下巴 → 鼻尖
        p.closeSubpath()
        return p
    }
}

/// 两只耳朵的内侧（暖色）。单独一片路径，因为要跟剪影的耳朵严格对齐 ——
/// 用胶囊去凑对不上，会露在耳朵外面。
///
/// 内侧**不到耳尖**：真实兔耳的软骨在靠近尖端那一小截是收尖的，
/// 内侧色块留出 8~11 个单位的白边，耳朵才有「厚度」。
struct RabbitEarInner: Shape {
    func path(in r: CGRect) -> Path {
        let w = r.width / 100, h = r.height / 100
        func P(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: r.minX + x * w, y: r.minY + y * h)
        }
        var p = Path()
        // 前耳（靠鼻侧）
        p.move(to: P(71.0, 32))
        p.addQuadCurve(to: P(77.0, 11), control: P(76.0, 22))
        p.addQuadCurve(to: P(66.5, 31.5), control: P(70.0, 22))
        p.closeSubpath()
        // 后耳
        p.move(to: P(56.5, 32))
        p.addQuadCurve(to: P(58.8, 10), control: P(57.0, 21))
        p.addQuadCurve(to: P(49.5, 33.0), control: P(53.0, 22))
        p.closeSubpath()
        return p
    }
}

/* ---------------- 二次贝塞尔取点 ----------------
   画枝干用（见 MoonNightBackdrop.branchShape）：沿中轴线采样一串点，
   在每点上放一个宽度递减的圆，就得到一根有锥度的枝。

   为什么放在文件层而不是某个视图的私有方法：主底纹和侧栏小景两处都要画
   枝，各写一份迟早会出现「两处曲率不一致」这种只有肉眼才看得出的偏差。 */

func qbez(_ a: CGPoint, _ b: CGPoint, _ c: CGPoint, _ t: Double) -> CGPoint {
    let u = 1 - t
    return CGPoint(x: u * u * a.x + 2 * u * t * b.x + t * t * c.x,
                   y: u * u * a.y + 2 * u * t * b.y + t * t * c.y)
}

/* ======================================================================
   ⑤ 上线提示弹窗
   ----------------------------------------------------------------------
   玻璃面板，面板里就是那幅月夜 —— 所以它一眼就能说明「换上之后长什么样」。
   默认主题不受影响：不点那个按钮，什么都不会变。

   **档期内每次启动都会出现**，不是「只看一次」。
   所以「本次运行已经关掉它」这件事只能记在内存里（由 DashRoot 的
   `@State` 持有），不能落进 settings.json —— 落了就成了「只弹一次」。
   ====================================================================== */

struct MoonFestNotice: View {

    /// 关闭时通知外面（DashRoot 把「本次运行已看过」记在内存里）
    var onClose: () -> Void = {}

    @EnvironmentObject var settings: BoardSettings
    @Environment(\.colorScheme) private var scheme
    /// 进场动画：淡入 + 上浮。
    /// 初值带上 `offscreen`：ImageRenderer 只画一帧、而且不保证触发 onAppear，
    /// 初值 false 的话离屏那张验收图会是一块看不见的透明 —— 白跑一趟。
    @State private var shown = PreviewFlags.offscreen

    private var env: Env { Env(scheme: scheme, settings: settings) }
    private var c: MoonFest.Ink { MoonFest.ink(scheme) }

    var body: some View {
        FloatingWindow(dim: scheme == .dark ? 0.46 : 0.30,
                       panelRadius: 360,
                       inset: EdgeInsets(top: 30, leading: 30, bottom: 30, trailing: 30),
                       onTapOutside: dismiss) {
            panel
                .scaleEffect(shown ? 1 : 0.955)
                .opacity(shown ? 1 : 0)
                .offset(y: shown ? 0 : 20)
        }
        .onAppear { withAnimation(Motion.pop) { shown = true } }
        .onExitCommand { dismiss() }
    }

    private func dismiss() {
        withAnimation(Motion.pop) { shown = false }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.24) { onClose() }
    }

    private var panel: some View {
        VStack(spacing: 0) {
            art
            text
            buttons
        }
        .frame(width: 588)
        .liquidGlassPanel(env, corner: Radius.lg)
    }

    /* 面板里的月夜：裁成圆角、压一层纱，保证字压在上面也读得清。
       这块是**可以点**的 —— 点月亮会亮一圈、点云会散、点灯会亮、兔子能拖。
       敢开交互的原因同上：整片区域全是装饰，而且命中已经细化到逐个元素。 */
    private var art: some View {
        ZStack {
            MoonNightBackdrop(scheme: scheme, compact: true, interactive: true)
            LinearGradient(colors: [Color.black.opacity(scheme == .dark ? 0.06 : 0.0),
                                    Color.black.opacity(scheme == .dark ? 0.34 : 0.10)],
                           startPoint: .top, endPoint: .bottom)
                // 这层纱必须让开点击，否则它自己就把下面所有元素的点按吃掉。
                .allowsHitTesting(false)
        }
        .frame(height: 250)
        .clipShape(UnevenRoundedRectangle(topLeadingRadius: env.radius(Radius.lg) - 7,
                                          bottomLeadingRadius: 0,
                                          bottomTrailingRadius: 0,
                                          topTrailingRadius: env.radius(Radius.lg) - 7,
                                          style: .continuous))
    }

    /* ---------------- 文案 ----------------
       这一整段是用户指定的固定文案，一字不改：
         第一行做强调标题，第二行做正文。
       除此之外面板里不再有多余的自造宣传语。 */
    private var text: some View {
        VStack(alignment: .leading, spacing: env.space(11)) {
            HStack(spacing: 7) {
                Image(systemName: "moon.stars.fill")
                    .font(.system(size: 12.5, weight: .semibold))
                Text("月圆 限定主题已上线✨")
                    .font(.system(size: 19, weight: .bold))
                    .tracking(0.3)
            }
            .foregroundStyle(c.moonGlow)

            Text("今夜月明人尽望，不知秋思落谁家。LunaOS限时开放，内置多款可互动中秋元素，月色、桂影与玉兔装点你的看板，沉浸式感受中秋夜色，千万别错过这次节日专属体验！")
                .font(.system(size: 13))
                .foregroundStyle(Theme.ink2(scheme))
                .lineSpacing(5)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, env.space(26))
        .padding(.top, env.space(20))
        .padding(.bottom, env.space(18))
    }

    private var buttons: some View {
        HStack(spacing: env.space(10)) {
            Button {
                withAnimation(Motion.spring(0.45)) { settings.paletteID = MoonFest.paletteID }
                dismiss()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "moon.fill").font(.system(size: 11.5, weight: .bold))
                    Text("换上月圆").font(.system(size: 13, weight: .semibold))
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 18).frame(height: 32)
                .background {
                    Capsule().fill(LinearGradient(colors: [c.moonGlow.opacity(0.98),
                                                          c.moonGlow.opacity(0.80)],
                                                 startPoint: .top, endPoint: .bottom))
                }
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)

            Button { dismiss() } label: {
                // 文案是「暂不更换」而不是「还用经典」：每个人的当前主题都不一样
                // （这台机器上就是「宣纸」），说「还用经典」等于替他改了一次主题，
                // 而这里按下去其实什么都不会发生 —— 得让文案如实描述这个行为。
                Text("暂不更换")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Theme.ink2(scheme))
                    .padding(.horizontal, 16).frame(height: 32)
                    .background(Capsule().fill(Color.primary.opacity(0.06)))
                    .contentShape(Capsule())
            }
            .buttonStyle(.plain)

            Spacer(minLength: 0)
        }
        .padding(.horizontal, env.space(26))
        .padding(.bottom, env.space(22))
    }
}

/* ---------------- 确定性伪随机 ----------------
   星位 / 花瓣初相这些都靠它。必须是**纯函数**：同一组 (i, salt) 永远同一个值。
   换成 Int.random 的话，每一帧重画都会重新洗牌 —— 星星会疯闪、花瓣会瞬移。 */

func rnd(_ i: Int, _ salt: Int) -> Double {
    var x = UInt64(truncatingIfNeeded: i) &* 6364136223846793005
    x = x &+ UInt64(truncatingIfNeeded: salt) &* 1442695040888963407
    x = x &+ 0x9E3779B97F4A7C15
    x ^= x >> 33
    x = x &* 0xFF51AFD7ED558CCD
    x ^= x >> 33
    x = x &* 0xC4CEB9FE1A85EC53
    x ^= x >> 33
    return Double(x % 1_000_003) / 1_000_003.0
}

/// 把时间轴折成 0…1 的循环相位（花瓣飘落、云飘、灯上升都靠它）。
///
/// 全局函数而不是某个视图的私有方法：主底纹和侧栏小景**都要用**，
/// 各写一份迟早会出现「两处节奏对不上」这种只有肉眼才看得出的偏差。
func falloff(_ t: Double) -> Double {
    let m = t.truncatingRemainder(dividingBy: 1)
    return m < 0 ? m + 1 : m
}

/* ---------------- 桂花 ----------------
   一簇 + 一朵。放在**文件层**（而不是 `MoonNightBackdrop` 的私有方法）：
   主底纹与侧栏小景两处都要画花，一处大一处小，但必须是**同一套画法**
   —— 不然同一幅画面里会出现两种花。

   多出来的 `dark` 参数是唯一的妥协：这两个函数离开视图之后就拿不到
   `@Environment(\.colorScheme)` 了，深浅两套透明度只能由调用方传进来。 */

/// 一簇桂花：6 朵小花挤在一起，外围直径约 2.1 倍单花。
///
/// 单朵花的尺寸按容器高给（而不是宽）：枝可以很宽也可以很窄，
/// 但花的绝对大小应当是稳定的，不然窄画面里会挤成一片糊。
///
/// 【为什么是 6 朵、且挤得更紧】
/// 上一版是 5 朵、散布在 ±0.85s 的范围里。因为花瓣之间有缝，
/// 散开之后整簇就读成了**一朵一朵的星形**，而不是「一蓬花」。
/// 桂花的花序本来就是**密簇**：几十朵小花挤在叶腋那一小块。
/// 所以数量加到 6、散布收到 ±0.62s，视觉上就黏成一蓬了。
func osmanthusCluster(_ c: MoonFest.Ink, _ s: CGFloat, _ salt: Int, dark: Bool) -> some View {
    ZStack {
        ForEach(0..<6, id: \.self) { j in
            osmanthusBloom(c, s * (0.80 + 0.30 * CGFloat(rnd(salt + j, 91))), dark: dark)
                .offset(x: s * CGFloat(rnd(salt + j, 92) - 0.5) * 1.24,
                        y: s * CGFloat(rnd(salt + j, 93) - 0.5) * 1.24)
        }
    }
    .frame(width: s * 2.3, height: s * 2.3)
}

/// 一朵桂花：四瓣围一圈，中间一枚花蕊。
///
/// 花瓣的排法：先 `offset(y: -s*0.22)` 让花瓣离开中心，
/// **再** `.rotationEffect` 绕整朵花的中心转 j·90°。
/// 这个顺序不能反 —— 反过来（先转再偏）偏移量本身也会被转，
/// 四片花瓣会叠在同一个位置，看着就是一朵普通的花而不是桂花。
///
/// 【为什么上一版像「+」号 / 海星】
/// 花瓣给的是 0.48 宽 × 0.82 高的**细长**椭圆，偏移又有 0.30 ——
/// 四片之间留出一大块空白，形状就读成了四根尖刺。
/// 现在把花瓣做**宽、做圆**（0.74 × 0.80，几乎是圆的），
/// 偏移收到 0.22，四片在中心互相压住 —— 那个十字形的对称
/// 还在（所以仍然是桂花），但已经没有尖角了。
func osmanthusBloom(_ c: MoonFest.Ink, _ s: CGFloat, dark: Bool) -> some View {
    ZStack {
        ForEach(0..<4, id: \.self) { j in
            Ellipse()
                .fill(c.petal.opacity(dark ? 0.94 : 0.84))
                .frame(width: s * 0.74, height: s * 0.80)
                .offset(y: -s * 0.22)
                .rotationEffect(.degrees(Double(j) * 90 + 14))
        }
        Circle()
            .fill(c.lampRing.opacity(0.95))
            .frame(width: s * 0.24, height: s * 0.24)
    }
    .frame(width: s, height: s)
}
