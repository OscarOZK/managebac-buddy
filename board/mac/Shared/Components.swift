import SwiftUI
import AppKit

/* ======================================================================
   通用组件层
   —— 八项美学里 ③ 卡片与组件形态 / ⑤ 动效与交互 的落点
   所有卡片都走 card() 一处，改玻璃强度/圆角档位时全局一致。
   ====================================================================== */

@MainActor
struct Env {
    let scheme: ColorScheme
    let settings: BoardSettings
    /// 走 `settings.uiAccent` 而不是 `settings.accent`：
    /// 小看板（面板进程）在「不跟随看板主题」时要用它自己那套强调色，
    /// 这一层判断收在 BoardSettings.uiAccent 里，所有视图自动一致。
    var accent: RGB { settings.uiAccent }
    var look: GlassLook { settings.look }
    var pretty: Bool { !PreviewFlags.flat }

    func radius(_ base: CGFloat) -> CGFloat { Radius.of(base, settings.corner) }
    func space(_ v: CGFloat) -> CGFloat { v * settings.densityScale }
}

/* ======================================================================
   文本输入的统一外壳
   ----------------------------------------------------------------------
   为什么不直接用 TextField：它的底层是 AppKit 的 NSTextField，
   `ImageRenderer` 画不出来 —— 离屏自检图里会留一整块「黄底红圈禁止」的
   占位。设置页有十来处输入框，整页就没法看了。所以统一走这个壳：
   真机是输入框，自检时是等宽等高的一行静态文字。
   两种形态的字体、颜色、行数都对得上，所以自检图里看到的排版是真的。
   ====================================================================== */

struct SoftField: View {
    var placeholder: String
    @Binding var text: String
    var scheme: ColorScheme
    var font: Font = .system(size: 13)
    var secure: Bool = false
    /// 对应 `TextField(axis: .vertical)`：可以换行变高
    var vertical: Bool = false
    /// 文本靠哪边（设置页里那排数字框是右对齐的）
    var align: Alignment = .leading

    private var ghost: String {
        if text.isEmpty { return placeholder }
        if secure { return String(repeating: "•", count: min(max(text.count, 6), 12)) }
        return text
    }

    var body: some View {
        if PreviewFlags.offscreen {
            Text(ghost)
                .font(font)
                .foregroundStyle(text.isEmpty ? Color.secondary.opacity(0.65)
                                              : Theme.ink(scheme))
                .lineLimit(vertical ? 5 : 1)
                .frame(maxWidth: .infinity, alignment: align)
        } else if secure {
            SecureField(placeholder, text: $text)
                .textFieldStyle(.plain)
                .font(font)
        } else if vertical {
            TextField(placeholder, text: $text, axis: .vertical)
                .textFieldStyle(.plain)
                .font(font)
                .lineLimit(1...5)
        } else {
            TextField(placeholder, text: $text)
                .textFieldStyle(.plain)
                .font(font)
        }
    }
}

/* ---------------- 悬停抬升 + 按下回弹（⑤ 动效） ----------------
   手感三件事，缺一件就会"廉价"：
     · 悬停只抬 2–3pt、放大 1%，多了像在跳；
     · 悬停用纯缓出（0.16s）—— 它要跟手，带弹簧反而显得拖；
     · 按下要"先快后回弹"（0.22s 弹簧），这才像真按到了东西。
   三者分开取 token，所以全应用所有可点卡片的触感是一致的。 */

struct HoverLift: ViewModifier {
    var lift: CGFloat = 3
    var enabled: Bool = true
    @State private var hovering = false
    @State private var pressed = false

    func body(content: Content) -> some View {
        content
            .scaleEffect(pressed ? 0.982 : (hovering && enabled ? 1.010 : 1))
            .offset(y: hovering && enabled && !pressed ? -lift : 0)
            .animation(Motion.hover, value: hovering)
            .animation(Motion.press, value: pressed)
            .onHover { hovering = $0 }
            .simultaneousGesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in if !pressed { pressed = true } }
                    .onEnded { _ in pressed = false }
            )
    }
}

extension View {
    /// 悬停抬升。默认跟着「减弱动态效果」走 —— 开了就整个不动。
    func hoverLift(_ lift: CGFloat = 3, enabled: Bool = true) -> some View {
        modifier(HoverLift(lift: lift, enabled: enabled && !Motion.reduced))
    }
}

/* ---------------- 进场动画：错峰淡入上浮（⑤ 动效） ----------------
   三段一起做才有"对焦"的感觉：位移（从下方 12pt 浮上来）+ 淡入 + 轻微去焦。
   只有淡入会很平，只有位移会很硬，加上那 2.5pt 的模糊才像镜头对上了焦。 */

struct AppearIn: ViewModifier {
    let index: Int
    @State private var shown = false
    /// 离屏渲染（ImageRenderer 不会触发 onAppear）时直接显示，否则整屏会是空白
    @Environment(\.mbRenderMode) private var renderMode

    func body(content: Content) -> some View {
        let visible = renderMode || shown
        return content
            .opacity(visible ? 1 : 0)
            .offset(y: visible ? 0 : 12)
            .blur(radius: visible ? 0 : 2.5)
            .onAppear {
                withAnimation(Motion.reveal?.delay(Motion.stagger(index))) { shown = true }
            }
    }
}

/* ---------------- 离屏渲染开关 ---------------- */

private struct MBRenderModeKey: EnvironmentKey { static let defaultValue = false }

extension EnvironmentValues {
    /// 置为 true 时跳过入场动画（离屏渲染截图用）
    var mbRenderMode: Bool {
        get { self[MBRenderModeKey.self] }
        set { self[MBRenderModeKey.self] = newValue }
    }
}

extension View {
    func appearIn(_ index: Int) -> some View { modifier(AppearIn(index: index)) }
}

/* ---------------- 会转的小图标（真的会停） ----------------
   之前各处写的是 `.rotationEffect(busy ? 360 : 0)` + `.animation(busy ?
   .repeatForever : nil, value: busy)`。这套写法有个坑：repeatForever 一旦启动，
   就算把 busy 变回 false 也停不下来 —— 底部那颗「刷新」箭头会一直空转，
   看起来像永远在加载。用户明确提过这个问题。

   这里换成按「当前时间」算角度：转与不转由 `spinning` 决定，
   不转时整棵 TimelineView 直接不在了，物理上不可能继续转。 */

struct SpinIcon: View {
    var name: String = Icons.refresh
    var size: CGFloat = 10.5
    var weight: Font.Weight = .semibold
    /// 一秒转多少圈
    var turnsPerSecond: Double = 0.85
    var spinning: Bool

    var body: some View {
        if spinning {
            TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { ctx in
                glyph.rotationEffect(.degrees(angle(ctx.date)))
            }
        } else {
            glyph
        }
    }

    private var glyph: some View {
        Image(systemName: name).font(.system(size: size, weight: weight))
    }

    private func angle(_ date: Date) -> Double {
        let t = date.timeIntervalSinceReferenceDate * turnsPerSecond
        return (t - t.rounded(.down)) * 360
    }
}

/* ---------------- 玻璃卡面 ---------------- */

struct GlassCard<Content: View>: View {
    let env: Env
    var radius: CGFloat = Radius.md
    var tint: Color? = nil
    var shadow: Bool = true
    var padding: CGFloat? = nil
    @ViewBuilder var content: () -> Content

    var body: some View {
        let r = env.radius(radius)
        content()
            .padding(padding ?? env.space(Space.md))
            .frame(maxWidth: .infinity, alignment: .leading)
            .card(r, tint: tint, look: env.look, shadow: shadow)
    }
}

/* ---------------- 弹窗外壳：液态玻璃描边 + 毛玻璃主体 ----------------

   用户明确要求（原话）：
     「给所有 APP 里这种弹出的框添加一个液态玻璃描边，一定是 WWDC 25 苹果官方
      发布的新的液态玻璃模组，一定是原生的液态玻璃，特别特别特别透明，完全
      就是折射，不需要有任何的填色效果，完全就是透明的 liquid glass。
      描边里面的部分就是原来的这个大的窗口，采用毛玻璃，要那种不太透底下
      颜色的。所以整体就是一个大的毛玻璃的窗口，里面有内容，然后外面有一层
      liquid glass 描边。」

   所以这一层只做三件事，顺序不能乱：
     ① 外圈 —— 原生液态玻璃（`Glass.clear`）：**零填色**，只折射；
     ② 内圈 —— 毛玻璃主体，而且刻意「糊到不太透」，保证正文读得清；
     ③ 内容 —— 原样放进来，位置尺寸都不动。

   为什么外圈要留 `border` 那么宽：液态玻璃的「描边感」来自它的边缘折射与
   镜面高光（lensing / specular）。如果只做 1pt 的线，那只是普通描线，看不出
   玻璃 —— 必须让玻璃**铺开一小圈**、再拿不透明的毛玻璃把中间盖掉，
   剩下的那一圈才是真的液态玻璃描边。

   ⚠️ 坑（和 CardSurface 那条注释同源）：内圈**必须**用 `.padding(border)`
   缩回来，不能靠 ZStack 叠。ZStack 里的形状是无限弹性的，一旦有父级余量
   它就会吃掉，把弹窗撑成空盒子。这里两个 `.background` 都贴着内容尺寸走，
   尺寸恒等于「内容 + 2×border」。
   ====================================================================== */

struct LiquidGlassPanel<Content: View>: View {
    let env: Env
    /// 圆角（会按设置里的圆角档位缩放）
    var corner: CGFloat = Radius.lg
    /// 液态玻璃描边的宽度。
    /// **`nil` = 跟着「设置 → 外观 → 液态玻璃描边」走**（那里默认 7，就是原效果）。
    var border: CGFloat? = nil
    /// 内圈毛玻璃的「挡色」程度。越大越不透底色（1 = 几乎全挡）。`nil` = 跟设置走
    var bodyOpacity: Double? = nil
    /// 是否投影。`nil` = 跟设置走（默认开）
    var shadow: Bool? = nil
    @ViewBuilder var content: () -> Content

    @Environment(\.colorScheme) private var scheme

    /// 订阅设置本身：用户在外观里拖滑块时，已经开着的弹窗要当帧跟着变，
    /// 而不是「关掉重开才生效」。
    @ObservedObject private var tune = BoardSettings.shared

    var body: some View {
        // 三个「没显式传就跟设置走」的落点。默认值与历史值逐一对齐：
        //   7pt 宽 / 0.94 挡色 / 投影开 —— 所以这一版不会改变任何默认观感。
        let bd = border ?? CGFloat(tune.glassPanelBorder)
        let bo = bodyOpacity ?? tune.glassPanelBody
        let sh = shadow ?? tune.glassPanelShadow
        let rim = max(0, min(1, tune.glassPanelRim))

        let r  = env.radius(corner)
        let ri = max(6, r - bd)
        // 「降低透明度」开着时不能上玻璃（那是无障碍上的硬要求）：
        // 退化成一块实色底 + 一道细边，观感朴素但信息一样不少。
        let solid = PreviewFlags.flat || env.look.useFallback

        content()
            .padding(bd)
            // ① 内圈：毛玻璃主体。
            //    thickMaterial 本身已经「糊」得比较实，再叠一层不透明度很高的
            //    主题底 —— 两层叠上去，背后的内容只剩一层隐约的明暗，
            //    正文的黑字在任何背景上都读得清。用户要的「不太透底下颜色」。
            .background {
                ZStack {
                    if !solid {
                        RoundedRectangle(cornerRadius: ri, style: .continuous)
                            .fill(.thickMaterial)
                    }
                    RoundedRectangle(cornerRadius: ri, style: .continuous)
                        .fill(Theme.cardFill(scheme, strength: solid ? 0 : 1)
                                .opacity(solid ? 1 : bo))
                }
                .padding(bd)
            }
            // ② 外圈：原生液态玻璃。`.clear` 是 WWDC25 里那档「几乎完全透明、
            //    只有折射」的玻璃，**不带任何 tint**（tint 就算填色了）。
            .background {
                if solid {
                    RoundedRectangle(cornerRadius: r, style: .continuous)
                        .fill(Theme.cardFill(scheme, strength: 1))
                } else {
                    Rectangle()
                        .fill(Color.clear)          // 只是给 glassEffect 一个载体
                        .glassEffect(.clear, in: RoundedRectangle(cornerRadius: r, style: .continuous))
                }
            }
            // ③ 玻璃的边缘高光。上面下方那条白渐变就是玻璃「厚度」读出来的地方，
            //    没有它，clear 玻璃在浅色背景上几乎看不见边界。这不是填色，是描边。
            //    `rim` 是它的强度旋钮，默认 1 倍 —— 即原样。
            .overlay {
                RoundedRectangle(cornerRadius: r, style: .continuous)
                    .strokeBorder(
                        LinearGradient(
                            colors: scheme == .dark
                                ? [Color.white.opacity(0.30 * rim), Color.white.opacity(0.05 * rim)]
                                : [Color.white.opacity(0.92 * rim), Color.white.opacity(0.30 * rim)],
                            startPoint: .top, endPoint: .bottom),
                        lineWidth: 0.9)
                    .allowsHitTesting(false)
            }
            .compositingGroup()
            .shadow(color: .black.opacity(sh ? (scheme == .dark ? 0.50 : 0.22) : 0),
                    radius: sh ? 34 : 0, y: sh ? 14 : 0)
    }
}

extension View {
    /// 把一块内容做成「液态玻璃描边 + 毛玻璃主体」的弹窗。
    ///
    /// 三个尺寸/观感参数留 `nil` 就跟着设置走（见 LiquidGlassPanel 的说明）。
    func liquidGlassPanel(_ env: Env,
                          corner: CGFloat = Radius.lg,
                          border: CGFloat? = nil,
                          bodyOpacity: Double? = nil,
                          shadow: Bool? = nil) -> some View {
        LiquidGlassPanel(env: env, corner: corner, border: border,
                         bodyOpacity: bodyOpacity, shadow: shadow) { self }
    }

    /// 同上，但**不改变布局尺寸** —— 描边画在既有边界的内侧。
    ///
    /// 给那些尺寸被外部精确定死的面板用（比如菜单栏那块 NSPanel：
    /// 它的高宽由 AppKit 窗口管着，外面再包一层 padding 会把内容挤变形）。
    ///
    /// 描边宽度 / 高光 / 挡色三项和 `liquidGlassPanel` 共用同一组设置，
    /// 所以「设置 → 外观」里拖一下，大看板的弹窗和小看板的面板会一起变。
    /// 这里直接读单例而不是 `@ObservedObject`：调用方（PanelView / 各弹窗）
    /// 自己已经订阅了 settings，设置一变它们的 body 就重算，跟着就取到新值。
    func liquidGlassRim(_ env: Env,
                        radius: CGFloat,
                        border: CGFloat? = nil,
                        bodyOpacity: Double? = nil) -> some View {
        let s = BoardSettings.shared
        let bd = border ?? CGFloat(s.glassPanelBorder)
        let bo = bodyOpacity ?? s.glassPanelBody
        let rim = max(0, min(1, s.glassPanelRim))
        let solid = PreviewFlags.flat || env.look.useFallback
        let outer = RoundedRectangle(cornerRadius: radius, style: .continuous)
        let inner = RoundedRectangle(cornerRadius: max(6, radius - bd), style: .continuous)
        return self
            .background {
                ZStack {
                    // ① 外圈：原生液态玻璃，零填色、纯折射
                    if !solid {
                        outer.fill(Color.clear).glassEffect(.clear, in: outer)
                    }
                    // ② 内圈：毛玻璃主体，缩进 border 把中间的玻璃盖掉
                    if !solid {
                        inner.fill(.thickMaterial).padding(bd)
                    }
                    inner
                        .fill(Theme.cardFill(env.scheme, strength: solid ? 0 : 1)
                                .opacity(solid ? 1 : bo))
                        .padding(bd)
                }
            }
            .overlay {
                outer.strokeBorder(
                    LinearGradient(
                        colors: env.scheme == .dark
                            ? [Color.white.opacity(0.30 * rim), Color.white.opacity(0.05 * rim)]
                            : [Color.white.opacity(0.92 * rim), Color.white.opacity(0.30 * rim)],
                        startPoint: .top, endPoint: .bottom),
                    lineWidth: 0.9)
                .allowsHitTesting(false)
            }
            .compositingGroup()
    }
}

/* ---------------- 小胶囊 ---------------- */

struct Pill: View {
    let env: Env
    let text: String
    var color: RGB = Theme.ink3_RGB
    var filled: Bool = true
    var icon: String? = nil
    var bold: Bool = false

    var body: some View {
        let c = color.color(env.scheme, lift: 0.16)
        HStack(spacing: 4) {
            if let icon {
                Image(systemName: icon).font(.system(size: 9.5, weight: .bold))
            }
            Text(text)
                .font(.system(size: 11, weight: bold ? .bold : .semibold))
                .monospacedDigit()
        }
        .foregroundStyle(filled ? c : .secondary)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Capsule().fill(filled ? c.opacity(env.scheme == .dark ? 0.22 : 0.14)
                                          : Color.primary.opacity(0.06)))
        .fixedSize()
        .accessibilityLabel(text)
    }
}

/* ---------------- 迷你进度条（紧急度可视化） ---------------- */

struct MiniBar: View {
    let env: Env
    /// 0…1
    let value: Double
    var color: RGB
    var height: CGFloat = 4

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(env.scheme == .dark ? 0.12 : 0.07))
                Capsule()
                    .fill(LinearGradient(colors: [color.color(env.scheme, lift: 0.24),
                                                  color.color(env.scheme, lift: 0.06)],
                                         startPoint: .leading, endPoint: .trailing))
                    // 最小宽度不能太小：value 接近 0 时（比如「还有 13 天才到期」
                    // 的任务）原来只有 3pt 宽，配上圆头就是一个孤零零的小点，
                    // 看着像脏像素 / 渲染残渣，而不像「进度条刚开始」。
                    // 给到和高度相当的一小段，它才读得出是一个 nub。
                    .frame(width: max(height + 2, geo.size.width * min(1, max(0, value))))
            }
        }
        .frame(height: height)
        .accessibilityHidden(true)
    }
}

/* ======================================================================
   输入框的统一「内凹」外壳
   ----------------------------------------------------------------------
   为什么值得抽出来：这个 App 有三处自己画的输入框 —— 设置页上半部分、
   设置 → 账号管理、首次引导。它们各写了一份，而且样式并不一样：
   账号管理和引导页用的是 `.card(...)`，和它所在的卡片是**同一种面**
   （同填充、同描边），于是白底卡片上的输入框几乎看不出来 —— 放大截图里
   只剩一个若隐若现的圆角框，用户会以为那是装饰、而不是可以打字的地方。
   圆角也各写各的（8 / 11 / 11）。

   现在统一成一种：比卡面深一档的底 + 一条浅边，深浅色各自反向。
   ====================================================================== */
extension View {
    func fieldWell(_ env: Env, radius: CGFloat = Radius.sm) -> some View {
        let r = RoundedRectangle(cornerRadius: env.radius(radius), style: .continuous)
        return self
            .background {
                r.fill(Color.primary.opacity(env.scheme == .dark ? 0.11 : 0.055))
            }
            .overlay {
                r.strokeBorder(Theme.lineSoft(env.scheme), lineWidth: 0.8)
                    .allowsHitTesting(false)
            }
    }
}

/* ---------------- 环形进度（GPA 用） ---------------- */

struct Donut: View {
    let env: Env
    let value: Double          // 0…1
    var size: CGFloat = 132
    var line: CGFloat = 13
    var color: RGB

    var body: some View {
        ZStack {
            Circle()
                .stroke(Color.primary.opacity(env.scheme == .dark ? 0.10 : 0.07),
                        style: StrokeStyle(lineWidth: line, lineCap: .round))
            Circle()
                .trim(from: 0, to: min(1, max(0.001, value)))
                .stroke(
                    AngularGradient(
                        colors: [color.color(env.scheme, lift: 0.30),
                                 color.color(env.scheme, lift: 0.0)],
                        center: .center, startAngle: .degrees(-90), endAngle: .degrees(270)),
                    style: StrokeStyle(lineWidth: line, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .shadow(color: color.color(env.scheme, lift: 0.1).opacity(0.35), radius: 5, y: 1)
        }
        .frame(width: size, height: size)
        .animation(Motion.spring(0.7), value: value)
        .accessibilityHidden(true)
    }
}

/* ---------------- 分段控件（自绘，风格统一） ----------------
   选中胶囊用 matchedGeometryEffect 在选项之间**滑过去**，而不是原地闪现。
   这是整个界面里最高频的交互之一，滑一下和闪一下的差别非常大：
   前者让你知道"从哪来的"，后者只告诉你"现在是哪个"。 */

struct SegItem: Identifiable {
    let id: String
    let label: String
    var icon: String? = nil
}

struct SegmentedTabs: View {
    let env: Env
    let items: [SegItem]
    @Binding var selection: String

    @Namespace private var ns
    @State private var hovered: String?

    var body: some View {
        HStack(spacing: 3) {
            ForEach(items) { it in
                let on = selection == it.id
                Button {
                    withAnimation(Motion.select) { selection = it.id }
                } label: {
                    HStack(spacing: 5) {
                        if let i = it.icon {
                            Image(systemName: i).font(.system(size: 10.5, weight: .semibold))
                        }
                        Text(it.label).font(.system(size: 11.5, weight: on ? .semibold : .medium))
                    }
                    .foregroundStyle(on ? Theme.ink(env.scheme) : Color.secondary)
                    .padding(.horizontal, 10)
                    .frame(height: 24)
                    .background {
                        if on {
                            RoundedRectangle(cornerRadius: env.radius(7), style: .continuous)
                                .fill(env.scheme == .dark ? Color.white.opacity(0.16) : Color.white)
                                .shadow(color: .black.opacity(0.10), radius: 3, y: 1)
                                // 同一时刻只有一块是"亮"的，所以统一用 seg 这个 id，
                                // 切换时 SwiftUI 会把它从旧位置补间到新位置
                                .matchedGeometryEffect(id: "seg", in: ns)
                        } else if hovered == it.id {
                            RoundedRectangle(cornerRadius: env.radius(7), style: .continuous)
                                .fill(Color.primary.opacity(env.scheme == .dark ? 0.07 : 0.04))
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .onHover { hovered = $0 ? it.id : (hovered == it.id ? nil : hovered) }
                .animation(Motion.hover, value: hovered)
                .accessibilityAddTraits(on ? [.isSelected] : [])
            }
        }
        .padding(3)
        .background(
            RoundedRectangle(cornerRadius: env.radius(10), style: .continuous)
                .fill(Color.primary.opacity(env.scheme == .dark ? 0.10 : 0.055))
        )
        .accessibilityElement(children: .contain)
    }
}

/* ---------------- 开关行（自绘玻璃开关） ----------------
   旋钮位置不去 animate 数值，而是直接换 ZStack 的对齐方式 —— SwiftUI 会把它
   当成布局变化补间，比自己算 offset 更顺、也不需要额外状态。
   悬停时整个开关放大 4%：这是"可点"的暗示，不做的话鼠标移上去毫无反馈。 */

struct GlassToggle: View {
    let env: Env
    @Binding var on: Bool
    @State private var hovering = false

    var body: some View {
        Button {
            withAnimation(Motion.select) { on.toggle() }
        } label: {
            ZStack(alignment: on ? .trailing : .leading) {
                Capsule()
                    .fill(on ? env.accent.color(env.scheme, lift: 0.12)
                             : Color.primary.opacity(env.scheme == .dark ? 0.18 : 0.12))
                    .frame(width: 40, height: 24)
                Circle()
                    .fill(Color.white)
                    .frame(width: 19, height: 19)
                    .shadow(color: .black.opacity(0.18), radius: 2.5, y: 1)
                    .padding(.horizontal, 2.5)
            }
            .scaleEffect(hovering ? 1.045 : 1)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(Motion.hover, value: hovering)
        .help(on ? "已开启，点击关闭" : "已关闭，点击开启")
        .accessibilityAddTraits(on ? [.isSelected] : [])
    }
}

/* ---------------- 自绘玻璃滑块 ----------------
   不用原生 NSSlider：一是原生控件的强调色不受我们控制、跟强调色设置对不上，
   二是自绘才能做悬停放大、拖拽高亮和数值气泡，观感与本应用其余部分一致。 */

struct GlassSlider: View {
    let env: Env
    @Binding var value: Double
    var range: ClosedRange<Double>
    var step: Double = 1
    var color: RGB? = nil
    /// 轨道的宽度（不包含右侧读数）
    var width: CGFloat = 190
    /// 静止时也把当前数值显示在右侧。
    /// 以前只在拖动时弹气泡，松手就没了 —— 于是「紧急阈值」到底是多少小时，
    /// 不拖一下就永远看不见。小看板的紧凑行不需要，传 false 关掉。
    var showValue: Bool = true
    var valueLabel: (Double) -> String = { String(format: "%.0f", $0) }

    @State private var dragging = false
    @State private var hovering = false

    private var c: RGB { color ?? env.accent }

    var body: some View {
        HStack(spacing: 10) {
            track
            if showValue {
                Text(valueLabel(value))
                    .font(Typo.num(11.5, .semibold))
                    .foregroundStyle(Theme.ink2(env.scheme))
                    .fixedSize(horizontal: true, vertical: false)
                    .frame(minWidth: 46, alignment: .trailing)
            }
        }
        .fixedSize(horizontal: true, vertical: false)
        .help(valueLabel(value))
        .accessibilityElement()
        .accessibilityLabel("数值")
        .accessibilityValue(valueLabel(value))
        .accessibilityAdjustableAction { dir in
            switch dir {
            case .increment: value = min(range.upperBound, value + step)
            case .decrement: value = max(range.lowerBound, value - step)
            default: break
            }
        }
    }

    private var track: some View {
        let span = max(0.0001, range.upperBound - range.lowerBound)
        let frac = min(1, max(0, (value - range.lowerBound) / span))

        return GeometryReader { geo in
            let w = geo.size.width
            let r: CGFloat = dragging ? 10.5 : (hovering ? 9.5 : 8.5)
            let cx = min(w - r, max(r, w * frac))

            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.primary.opacity(env.scheme == .dark ? 0.15 : 0.09))
                    .frame(height: 7)

                Capsule()
                    .fill(LinearGradient(
                        colors: [c.color(env.scheme, lift: 0.26), c.color(env.scheme, lift: 0.02)],
                        startPoint: .leading, endPoint: .trailing))
                    .frame(width: max(7, w * frac), height: 7)

                Circle()
                    .fill(Color.white)
                    .frame(width: r * 2 - 2, height: r * 2 - 2)
                    .overlay(Circle().strokeBorder(c.color(env.scheme, lift: 0.10).opacity(0.45), lineWidth: 1))
                    .shadow(color: .black.opacity(dragging ? 0.28 : 0.18),
                            radius: dragging ? 6 : 3.5, y: 1)
                    // 拖动时在旋钮外围加一圈学科色光晕，让人明确"现在控制的是它"
                    .shadow(color: c.color(env.scheme).opacity(dragging ? 0.45 : 0), radius: 7)
                    .offset(x: cx - r + 1)
                    .animation(Motion.press, value: dragging)
                    .animation(Motion.hover, value: hovering)

                if dragging {
                    Text(valueLabel(value))
                        .font(Typo.num(10.5, .bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 7).padding(.vertical, 3)
                        .background(Capsule().fill(c.color(env.scheme, lift: -0.02)))
                        .shadow(color: .black.opacity(0.22), radius: 4, y: 2)
                        .fixedSize()
                        .offset(x: min(max(0, cx - 24), w - 48), y: -26)
                        .transition(.pop)
                }
            }
            .frame(height: 24)
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { g in
                        dragging = true
                        let f = min(1, max(0, g.location.x / w))
                        let raw = range.lowerBound + f * span
                        let snapped = (raw / step).rounded() * step
                        let v = min(range.upperBound, max(range.lowerBound, snapped))
                        if v != value { value = v }
                    }
                    .onEnded { _ in dragging = false }
            )
        }
        .frame(width: width, height: 24)
    }
}

/* ---------------- 取色色块：替代 SwiftUI 的 ColorPicker ----------------
   ColorPicker 在 macOS 上画的是系统「色井」，它**不服从 .frame 约束**：
   不管声明 20 / 24 / 30pt 宽，都会画成 ~48×31pt，并且以声明框为中心居中。
   于是左右各溢出 ~12pt：
     · 设置页「单科颜色」声明 24pt → 右边缘正好压在学科名上，
       「语文」的「语」被色井盖掉一半（用户截图指出）；
     · 「强调色」声明 30pt → 吃掉左边「自定义」9pt；
     · 面板快速设置声明 20pt → 盖住旁边色板圆点。
   自己画就不受这个气：尺寸、圆角、描边全由我们定，点击开原生取色板。 */

@MainActor
final class ColorPanelBridge: NSObject {
    static let shared = ColorPanelBridge()
    private var sink: ((NSColor) -> Void)?

    /// NSColorPanel 是全局单例，target/action 只有一份 —— 每次打开重设，
    /// 后点的色块接管回调（符合直觉：当前动的就是它）。
    func open(_ initial: Color, sink: @escaping (NSColor) -> Void) {
        self.sink = sink
        let p = NSColorPanel.shared
        p.setTarget(self)
        p.setAction(#selector(colorChanged(_:)))
        p.isContinuous = true
        p.showsAlpha = false
        if let c = NSColor(initial).usingColorSpace(.sRGB) { p.color = c }
        p.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: false)
    }

    @objc private func colorChanged(_ sender: NSColorPanel) {
        sink?(sender.color)
    }
}

/// 自绘色块。`hex` 是当前值，改动通过 `pick` 回传新的十六进制串。
struct ColorSwatch: View {
    let env: Env
    var hex: String
    var width: CGFloat = 24
    var height: CGFloat = 18
    var corner: CGFloat = 5
    var pick: (String) -> Void

    @State private var hovering = false

    private var rgb: RGB { RGB(hex) }

    var body: some View {
        Button {
            ColorPanelBridge.shared.open(rgb.color) { ns in
                if let h = Color(nsColor: ns).hexString { pick(h) }
            }
        } label: {
            RoundedRectangle(cornerRadius: corner, style: .continuous)
                .fill(rgb.color(env.scheme, lift: 0.06))
                .overlay {
                    RoundedRectangle(cornerRadius: corner, style: .continuous)
                        .strokeBorder(Color.primary.opacity(hovering ? 0.30 : 0.16), lineWidth: 1)
                }
                .overlay {
                    // 悬停时外面再描一圈白，暗示「这个可以点」
                    RoundedRectangle(cornerRadius: corner, style: .continuous)
                        .strokeBorder(Color.white.opacity(hovering ? 0.85 : 0), lineWidth: 1.4)
                        .padding(-1.4)
                }
                .frame(width: width, height: height)
                .scaleEffect(hovering ? 1.07 : 1)
                .animation(Motion.snappy(0.16), value: hovering)
                .contentShape(RoundedRectangle(cornerRadius: corner, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help("点开系统取色板 · 当前 \(hex.uppercased())")
        .accessibilityLabel("取色")
        .accessibilityValue(hex)
    }
}

/* ---------------- 设置项外壳 ---------------- */

struct SettingRow<Content: View>: View {
    let env: Env
    let title: String
    var detail: String = ""
    @ViewBuilder var control: () -> Content

    var body: some View {
        HStack(alignment: .center, spacing: env.space(14)) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 13.5, weight: .medium))
                    .foregroundStyle(Theme.ink(env.scheme))
                if !detail.isEmpty {
                    Text(detail)
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: env.space(10))
            control()
        }
        .padding(.horizontal, env.space(Space.md))
        .padding(.vertical, env.space(9))
        .frame(minHeight: env.space(44))
    }
}

/* ---------------- 空态 ---------------- */

struct EmptyState: View {
    let env: Env
    let icon: String
    let title: String
    var detail: String = ""

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 26, weight: .light))
                .foregroundStyle(.tertiary)
            Text(title)
                .font(.system(size: 13.5, weight: .medium))
                .foregroundStyle(.secondary)
            if !detail.isEmpty {
                Text(detail).font(.system(size: 11.5)).foregroundStyle(.tertiary)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, env.space(34))
    }
}

/* ---------------- 课程行 ---------------- */

struct ClassRowView: View {
    let slot: Schedule.Slot
    let now: Date
    var isNow: Bool = false
    /// 这一行的右半边被「现在」玻璃条盖住了。
    /// 盖住时不再画教室/老师 —— 它们已经被挪到那条上去了，两边都画就成了重影。
    var covered: Bool = false

    @EnvironmentObject var settings: BoardSettings
    @Environment(\.colorScheme) private var scheme
    @State private var hovering = false

    private var env: Env { Env(scheme: scheme, settings: settings) }

    var body: some View {
        let pr = slot.span[0] == slot.span[1] ? "P\(slot.span[0])" : "P\(slot.span[0])–P\(slot.span[1])"
        let time = "\(fmtClock(slot.start))–\(fmtClock(slot.end))"
        let rgb = RGB(slot.hex)
        let isDouble = slot.span[1] > slot.span[0]
        let barW: CGFloat = isNow ? 5 : 3.5
        let barH: CGFloat = isNow ? 20 : 17

        return HStack(spacing: 10) {
            HStack(spacing: 2) {
                Capsule().fill(rgb.color(scheme, lift: 0.12)).frame(width: barW, height: barH)
                if isDouble {
                    Capsule().fill(rgb.color(scheme, lift: 0.12)).frame(width: barW, height: barH)
                }
                Spacer(minLength: 0)
            }
            .frame(width: 14)

            Text(pr)
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 46, alignment: .leading)

            Text(time)
                .font(Typo.num(11, .medium))
                .foregroundStyle(.tertiary)
                .frame(width: 104, alignment: .leading)

            Text(slot.subject)
                .font(.system(size: 13, weight: isNow ? .semibold : .medium))
                .foregroundStyle(slot.isFree ? Color.secondary : Theme.ink(scheme))
                .lineLimit(1)
                .layoutPriority(1)

            Spacer(minLength: 8)

            if !covered {
                Text(slot.isFree ? "没有安排课程"
                     : [slot.room, slot.teacher, slot.mode].filter { !$0.isEmpty }.joined(separator: " · "))
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        }
        .padding(.horizontal, env.space(11))
        .frame(height: env.space(settings.density.rowHeight - 4))
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: env.radius(Radius.sm), style: .continuous)
                .fill(isNow
                      ? rgb.color(scheme, lift: 0.86, opacity: scheme == .dark ? 0.20 : 0.16)
                      : (scheme == .dark ? Color.white.opacity(0.035) : Color.white.opacity(0.55)))
        }
        .overlay {
            RoundedRectangle(cornerRadius: env.radius(Radius.sm), style: .continuous)
                .strokeBorder(isNow ? rgb.color(scheme, lift: 0.2).opacity(0.45) : Theme.lineSoft(scheme),
                              lineWidth: 0.8)
        }
        .overlay {
            // 行不抬升（一整列一起抬会很乱），只加一层极淡的底色表示"鼠标在这"
            if hovering && !isNow {
                RoundedRectangle(cornerRadius: env.radius(Radius.sm), style: .continuous)
                    .fill(Color.primary.opacity(scheme == .dark ? 0.05 : 0.035))
                    .allowsHitTesting(false)
            }
        }
        .onHover { hovering = $0 }
        .animation(Motion.hover, value: hovering)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(pr) \(time) \(slot.subject)\(isNow ? "，进行中" : "")")
    }
}

/* ======================================================================
   「现在」指示条 + 会呼吸的小圆点
   ----------------------------------------------------------------------
   用户要求（原话）：「这个杠杠需要做得特别窄…特别扁的一个，可以在课的中间，
   表示正在上这节课，它的图层是在课表之上的，而且是 liquid glass 材质。」

   所以它**不是列表里的一员** —— 不占一行、不把课程往下推，而是一条很扁的
   玻璃胶囊，叠在正在上的那节课行里、垂直居中。它按内容自己定宽（不是铺满
   整行），所以看着就是"浮在课表上面的一小块牌子"，而不是"又多了一行"。

   ⚠️ 踩过的坑：第一版做成了铺满整行的长条，于是玻璃底下的课程行文字和条上
   的文字**两层叠着**，糊成一团。现在两个做法避开它：
     · 条本身按内容定宽，只占中间这一小块；
     · 正在上的那行不再画它自己的教室/老师（这些信息挪到条上，一个字都没少）。
   ====================================================================== */

struct NowIndicator: View {
    let env: Env
    let cur: Schedule.Slot?
    let now: Date
    var compact: Bool = false
    /// 要不要把教室 / 老师也带在条上。
    /// 叠在课程行里时为 true —— 因为那一行自己的右侧信息被这条盖住了，得补回来。
    var withRoom: Bool = false

    private var rgb: RGB { RGB(cur?.hex ?? env.accent.hex) }

    private var title: String {
        guard let cur else { return "课间休息" }
        return cur.isFree ? "空闲时段" : cur.subject
    }

    private var room: String? {
        guard withRoom, let cur else { return nil }
        let r = [cur.room, cur.teacher].filter { !$0.isEmpty }.joined(separator: " · ")
        return r.isEmpty ? nil : r
    }

    var body: some View {
        let c = rgb.color(env.scheme, lift: env.scheme == .dark ? 0.24 : 0.06)
        let h: CGFloat = compact ? 16 : 18
        let sub = env.scheme == .dark ? Color.white.opacity(0.74) : Color.black.opacity(0.56)

        return HStack(spacing: compact ? 6 : 8) {
            PulsingDot(color: c, size: compact ? 5 : 6)

            Text("现在 \(fmtClock(now))")
                .font(Typo.num(compact ? 10 : 11, .bold))
                .foregroundStyle(c)
                .fixedSize()

            // 课程名后压一枚朱砂「今」字小印 —— 让"现在"不只是文字，是盖的章。
            // 课程名是英文时空隙不够，印自动缩小；compact 模式直接跳过（空间太挤）。
            if !compact {
                InkSeal(char: "今", size: 11, env: env)
                    .accessibilityHidden(true)
                    .fixedSize()
            }

            Text(title)
                .font(.system(size: compact ? 10 : 11.5, weight: .medium))
                .foregroundStyle(sub)
                .lineLimit(1)

            if let room {
                Text(room)
                    .font(.system(size: 10.5))
                    .foregroundStyle(sub.opacity(0.8))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            if let cur {
                Text(hms(cur.end.timeIntervalSince(now) * 1000) + " 后下课")
                    .font(Typo.num(compact ? 9.5 : 10.5, .semibold))
                    .foregroundStyle(c.opacity(0.95))
                    .fixedSize()
            }
        }
        .padding(.horizontal, compact ? 9 : 11)
        .frame(height: h)
        // 关键：按内容定宽。不要它铺满整行 —— 铺满了就不是"浮在课表上"，是"又一行"。
        .frame(maxWidth: compact ? 400 : 540)
        .background {
            // 液态玻璃：形状交给 Capsule，颜色留给 Glass 的 tint —— 这个顺序
            // 和 CardSurface 里一致（fill(Color.clear) 只是给 glassEffect 一个载体）
            if PreviewFlags.flat || env.look.useFallback {
                Capsule().fill(c.opacity(env.scheme == .dark ? 0.24 : 0.16))
            } else {
                Capsule()
                    .fill(Color.clear)
                    .glassEffect(env.look.variant.tint(c.opacity(0.30)), in: Capsule())
            }
        }
        .overlay {
            // 描边分两层：先一道学科色的细框（让人一眼看出"这是正在上的课"），
            // 再叠一道上亮下暗的白渐变（玻璃厚度）。用户明确要求"给这块液态玻璃加描边"。
            Capsule().strokeBorder(c.opacity(0.55), lineWidth: 1.1)
            Capsule().strokeBorder(
                LinearGradient(colors: [Color.white.opacity(env.scheme == .dark ? 0.30 : 0.90),
                                        Color.white.opacity(0.04)],
                               startPoint: .top, endPoint: .bottom),
                lineWidth: 0.8)
        }
        .shadow(color: .black.opacity(env.scheme == .dark ? 0.34 : 0.16), radius: 7, y: 2)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("现在 \(fmtClock(now))，\(cur.map { $0.subject } ?? "课间休息")")
    }
}

/// 会呼吸的小圆点 —— 表示「这是活的、此刻正在进行」。
///
/// 用 TimelineView 按时间算半径/光晕，和 SpinIcon 同一套思路：
/// 关了动效时整棵 TimelineView 直接不存在，物理上不可能还在动。
/// （不能用 `withAnimation(.repeatForever)` —— 那个一旦启动就停不下来，
///   之前刷新键一直空转就是这么来的。）
struct PulsingDot: View {
    var color: Color
    var size: CGFloat = 6

    var body: some View {
        if Motion.reduced {
            core(1, glow: 0.75)
        } else {
            TimelineView(.animation(minimumInterval: 1.0 / 20.0)) { ctx in
                // 周期由 Motion.motionStyle 决定：breathe 2.6s、normal 1.6s、vivid 1.1s。
                // 关键是用 ctx.date 而非 .repeatForever —— reduced 时整棵 TimelineView
                // 不存在，物理上不可能还在动。
                let dur: Double = Motion.motionStyle == .breathe ? 2.6
                    : (Motion.motionStyle == .vivid ? 1.1 : 1.6)
                let t = ctx.date.timeIntervalSinceReferenceDate
                let p = (sin(t * 2 * .pi / dur) + 1) / 2
                core(1 + 0.30 * p, glow: 0.80 - 0.50 * p)
            }
        }
    }

    private func core(_ scale: CGFloat, glow: Double) -> some View {
        Circle()
            .fill(color)
            .frame(width: size, height: size)
            .scaleEffect(scale)
            .shadow(color: color.opacity(glow), radius: 3.5)
            .frame(width: size + 3, height: size + 3)   // 给放大留出位置，免得被裁
    }
}

/* ======================================================================
   水墨丹青 · 印章 InkSeal
   ----------------------------------------------------------------------
   一枚朱砂方印 —— 圆角矩形（不是直角，"篆"在纸上是软的）+ 一字朱文 + 略微旋转 + 上沿极淡高光。

   印文默认是「壹 / 贰 / 叁 / 肆 / 今 / 雅 / 简 / 阅」，分别对应各分区 / 各主题
   / 各状态。印文是中文字，**一定要用 SF 系统字里能 fallback 到中文的字体**
   —— `STKaiti`（楷体） macOS 自带，做印文最合气质；找不到时退到 `PingFang`。
   即使 fallback 到 PingFang，仍然比用 `system` 渲染英文看着有"印"的感觉。

   印章的尺寸 / 颜色可独立控制，但**朱砂红 + 米黄文字**永远是默认配色 —
   用户原话「中式水墨丹青」。其他主题下退化为烟朱，保留「印章」的形状
   但不喧宾夺主（红霞 / 绿意 / 经典主题里如果硬塞朱砂会跳出来）。
   ====================================================================== */
struct InkSeal: View {
    /// 印文（默认「壹」）
    var char: String = "壹"
    /// 边长（pt）
    var size: CGFloat = 16
    var env: Env

    /// 是否为宣纸主题 —— 决定印的饱和度
    private var isRicePaper: Bool { ThemeRuntime.palette.id == "xuanzhi" }

    private var fillColor: Color {
        let strong = RGB("#b5483a")         // 朱砂
        let muted  = RGB("#8a3a30")         // 烟朱
        let c = isRicePaper ? strong : muted
        return c.color(env.scheme, lift: env.scheme == .dark ? 0.08 : 0.0, opacity: 0.94)
    }

    private var textColor: Color {
        RGB(isRicePaper ? "#f8f0da" : "#f2e8d0")
            .color(env.scheme, lift: env.scheme == .dark ? 0.0 : 0.05)
    }

    @ViewBuilder
    var body: some View {
        // 设置里关掉印章（默认关）就整个不渲染 —— 所有 InkSeal 使用点自动生效。
        if env.settings.showSeals {
            sealBody
        }
    }

    private var sealBody: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.16, style: .continuous)
                .fill(fillColor)
            // 上沿一道极淡白，做出"印章泥稍微凸起的反光"
            RoundedRectangle(cornerRadius: size * 0.16, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [Color.white.opacity(env.scheme == .dark ? 0.18 : 0.22),
                                 Color.white.opacity(0)],
                        startPoint: .top, endPoint: .center))
                .blendMode(.overlay)
                .allowsHitTesting(false)
            // 印文 —— 楷体优先，找不到时退到 PingFang
            Text(char)
                .font(.custom("STKaiti", size: size * 0.78, relativeTo: .body)
                      .weight(.bold))
                .foregroundStyle(textColor)
                .minimumScaleFactor(0.6)
                .lineLimit(1)
        }
        .frame(width: size, height: size)
        .overlay {
            RoundedRectangle(cornerRadius: size * 0.16, style: .continuous)
                .strokeBorder(Color.black.opacity(env.scheme == .dark ? 0.18 : 0.10),
                              lineWidth: 0.7)
        }
        .rotationEffect(.degrees(1.6))
        .shadow(color: fillColor.opacity(env.scheme == .dark ? 0.18 : 0.22),
                radius: 2, x: 0, y: 1)
        .accessibilityLabel("印·\(char)")
    }
}

/// 朱砂短竖线 —— 给小节标题做"印章感"用。粗细 1.6、高 18，上下各空 2pt。
struct CinnabarTick: View {
    var height: CGFloat = 18
    var width: CGFloat = 1.6
    var env: Env

    var body: some View {
        // 顶部稍深、底部稍浅 —— 像真的印泥往纸里渗
        RoundedRectangle(cornerRadius: width / 2, style: .continuous)
            .fill(
                LinearGradient(colors: [
                    RGB("#b5483a").color(env.scheme).opacity(env.scheme == .dark ? 0.85 : 0.92),
                    RGB("#b5483a").color(env.scheme).opacity(env.scheme == .dark ? 0.45 : 0.55)
                ], startPoint: .top, endPoint: .bottom))
            .frame(width: width, height: height)
    }
}

/* ---------------- 简易流式布局（图例换行用） ---------------- */

struct FlowRow: Layout {
    var spacing: CGFloat = 8
    var lineSpacing: CGFloat = 8

    /// 换行判定的容差。
    ///
    /// 这个值不是随手加的：卡片宽度是按 `(容器宽 - 间距) / 列数` 算出来的，
    /// 理论上正好铺满；但子视图会带 0.5pt 的对齐误差，外层再有个 1pt 内边距，
    /// 累加起来第 4 张就会「刚好超出 1.5pt」而被挤到第二行 —— 四个一排变成两排。
    /// 给 1.5pt 容差后，预算内的最后一张一定留在本行。
    private static let epsilon: CGFloat = 1.5

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxW = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, lineH: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            if x + s.width > maxW + Self.epsilon && x > 0 {
                x = 0; y += lineH + lineSpacing; lineH = 0
            }
            x += s.width + spacing
            lineH = max(lineH, s.height)
        }
        return CGSize(width: maxW == .infinity ? x : maxW, height: y + lineH)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, lineH: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            if x + s.width > bounds.maxX + Self.epsilon && x > bounds.minX {
                x = bounds.minX; y += lineH + lineSpacing; lineH = 0
            }
            v.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(s))
            x += s.width + spacing
            lineH = max(lineH, s.height)
        }
    }
}

/* ---------------- 分区 ---------------- */

enum DashSection: String, CaseIterable, Identifiable {
    case todo, teams, classes, grades, ai, settings

    var id: String { rawValue }

    var title: String {
        switch self {
        case .todo:     return "待办"
        case .teams:    return "Teams"
        case .classes:  return "课程"
        case .grades:   return "成绩"
        case .ai:       return "灵析AI"
        case .settings: return "设置"
        }
    }

    var icon: String {
        switch self {
        case .todo:     return Icons.todo
        case .teams:    return Icons.teams
        case .classes:  return Icons.classes
        case .grades:   return Icons.grades
        case .ai:       return Icons.ai
        case .settings: return Icons.settings
        }
    }

    /// 侧边栏 / 大标题旁的朱砂印文。
    /// 取每个分区一字，凑成一组类似「壹 / 贰 / 叁 / 肆 / 伍」的索引。
    /// 水墨丹青细节：宣纸主题下印是朱砂；其他主题下退化为淡朱（见 InkSeal 实现）。
    var seal: String {
        switch self {
        case .todo:     return "壹"
        case .teams:    return "贰"
        case .classes:  return "叁"
        case .grades:   return "肆"
        case .ai:       return "伍"
        case .settings: return "陆"
        }
    }

    var tagline: String {
        switch self {
        case .todo:     return "按剩余时间排序，越急越靠前"
        case .teams:    return "微软任务、邮件与聊天里提取出的学习待办"
        case .classes:  return "整日课表与本周全览"
        case .grades:   return "各科总评、4 分制折算与最新出分"
        case .ai:       return "直接把作业、成绩、课表丢给它问"
        case .settings: return "外观、配色、阈值、刷新 —— 改完立即生效"
        }
    }
}


/* ======================================================================
   「收不到通知」的两种可能
   ----------------------------------------------------------------------
   用户的要求：通知这一页最底下要把「为什么收不到」写清楚，而且**两种可能
   都要说**（① 系统里没允许本 App 发通知 ② Mac 开了勿扰 / 专注模式），
   第一种还要给一个按钮一步跳到「系统设置 › 通知 › ManageBac-Buddy」。

   引导页和设置页共用这一个视图 —— 两处说法必须一字不差，
   分开写迟早会说成两件事，用户就更不知道该修哪个了。
   ====================================================================== */

struct NotifyTroubleCard: View {
    @EnvironmentObject private var settings: BoardSettings
    @Environment(\.colorScheme) private var scheme
    private var env: Env { Env(scheme: scheme, settings: settings) }

    var body: some View {
        VStack(alignment: .leading, spacing: env.space(10)) {
            HStack(spacing: 7) {
                Image(systemName: "bell.slash.fill")
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(env.accent.color(scheme))
                Text("收不到通知？只可能是这两种情况")
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(Theme.ink(scheme))
                Spacer(minLength: 0)
            }

            reason(
                no: "1",
                title: "系统里没允许 ManageBac-Buddy发通知",
                body: "在「系统设置 › 通知 › ManageBac-Buddy」里，「允许通知」这一项要是关着的，"
                    + "本页怎么开都不会弹出。",
                action: ("打开系统通知设置", { Notifier.openSystemSettings() })
            )

            reason(
                no: "2",
                title: "Mac 开着「勿扰模式 / 专注模式」",
                body: "打开控制中心，看「专注模式」是不是亮着。亮着的话通知会被系统收走，"
                    + "不会显示横幅；关掉它，或者把「ManageBac-Buddy」加进允许列表。",
                action: ("打开专注模式设置", { Notifier.openFocusSettings() })
            )

            Text("两种都排除了还是没有？点下面「发一条示例」—— 能发出就说明通道没问题，"
                 + "只是这段时间确实没有需要提醒的事。")
                .font(.system(size: 11))
                .foregroundStyle(Theme.ink3(scheme))
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(env.space(13))
        .background {
            RoundedRectangle(cornerRadius: env.radius(Radius.md), style: .continuous)
                .fill(env.accent.color(scheme).opacity(0.07))
        }
    }

    private func reason(no: String, title: String, body: String,
                        action: (String, () -> Void)?) -> some View {
        HStack(alignment: .top, spacing: 9) {
            Text(no)
                .font(.system(size: 10, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
                .frame(width: 16, height: 16)
                .background(Circle().fill(env.accent.color(scheme, lift: 0.02)))
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.ink(scheme))
                    .fixedSize(horizontal: false, vertical: true)
                Text(body).font(.system(size: 11.5))
                    .foregroundStyle(Theme.ink2(scheme))
                    .fixedSize(horizontal: false, vertical: true)
                if let a = action {
                    Button(action: a.1) {
                        HStack(spacing: 5) {
                            Image(systemName: "arrow.up.forward.app.fill")
                                .font(.system(size: 9.5, weight: .semibold))
                            Text(a.0).font(.system(size: 11.5, weight: .semibold))
                        }
                        .foregroundStyle(Theme.ink(scheme))
                        .padding(.horizontal, 11).frame(height: 26)
                        .contentShape(RoundedRectangle(cornerRadius: env.radius(Radius.sm),
                                                       style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .card(env.radius(Radius.sm), look: env.look, shadow: false)
                    .padding(.top, 2)
                }
            }
            Spacer(minLength: 0)
        }
    }
}
