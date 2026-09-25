//  WatchTheme.swift
//  ManageBac Watch App —— 配色 / 尺寸 / 卡片材质
//  新建文件（菜单栏版 Theme.swift 未改动）。色值与之完全一致，保证两端同一套视觉语言。

import SwiftUI

/* ============================================================
   尺寸

   Apple Watch 屏幕（点）：
     40mm 162×197 ｜ 41mm 176×215 ｜ 44mm 184×224
     45mm 198×242 ｜ 46mm 208×248 ｜ Ultra 49mm 205×251

   基准按 46mm（208pt 宽）算，其它尺寸按比例收放：
   小表盘自动收窄内边距、收紧行高与正文字号，避免文案被挤掉。
   ============================================================ */
enum WatchMetrics {
    /// 真实屏幕宽度（模拟器 = 表盘尺寸；取不到就按 46mm 基准）
    static let screenWidth: CGFloat = {
        #if os(watchOS)
        let w = WKInterfaceDevice.current().screenBounds.width
        return w > 0 ? w : 208
        #else
        return 208
        #endif
    }()

    /// 布局缩放系数：46mm = 1.0，40mm ≈ 0.88（上限 1.0，别在大表盘上放大）
    static let scale: CGFloat = min(1.0, max(0.86, screenWidth / 208))

    /// 文字缩放：比布局缩放温和一些（字号缩太狠会糊）
    static let textScale: CGFloat = min(1.0, max(0.92, 0.72 + 0.28 * scale))

    static let pad: CGFloat = round(8 * scale)
    static let gap: CGFloat = round(8 * scale)
    static let cardRadius: CGFloat = round(13 * scale)
    /// 卡片内左右留白
    static let innerX: CGFloat = round(9 * scale)

    /// 按基准字号收放（48 → 小表盘 44 左右）
    static func fs(_ base: CGFloat) -> CGFloat { (base * textScale * 10).rounded() / 10 }

    /// 按基准尺寸收放（卡片高度、竖条高这类整体尺寸）
    static func box(_ base: CGFloat) -> CGFloat { (base * scale).rounded() }
}

/* 与 app.html / 菜单栏 App 完全同一套色（RGB 分量） */
struct RGB {
    var r: Double, g: Double, b: Double

    init(_ hex: String) {
        var s = hex
        if s.hasPrefix("#") { s.removeFirst() }
        let v = UInt32(s, radix: 16) ?? 0
        r = Double((v >> 16) & 0xff) / 255
        g = Double((v >> 8) & 0xff) / 255
        b = Double(v & 0xff) / 255
    }

    /// 深色模式下往白的方向提亮，保证对比度
    func color(_ scheme: ColorScheme, lift: Double = 0, opacity: Double = 1) -> Color {
        let f = (scheme == .dark) ? lift : 0
        return Color(.sRGB, red: r + (1 - r) * f,
                     green: g + (1 - g) * f,
                     blue: b + (1 - b) * f, opacity: opacity)
    }

    /// 纯色（不随主题提亮），给底纹用
    var color: Color { Color(.sRGB, red: r, green: g, blue: b, opacity: 1) }
}

enum Theme {
    static let accent = RGB("#0071e3")
    static let red    = RGB("#ff3b30")
    static let amber  = RGB("#ff9f0a")
    static let green  = RGB("#34c759")
    static let blue   = RGB("#007aff")
    static let ink    = RGB("#1d1d1f")
    static let ink2   = RGB("#6e6e73")
    static let ink3   = RGB("#86868b")
}

/* ============================================================
   卡片材质：原生液态玻璃（Liquid Glass）

   watchOS 26 的 `.glassEffect` 是系统级玻璃材质：会折射背后的内容、
   边缘自带高光、并跟随手腕倾斜与触控做出反应，比 ultraThinMaterial 更「活」。

   两个必要的逃生口：
     ① 离屏自检（ImageRenderer / 无渲染上下文）画不出玻璃 → MBWATCH_NO_GLASS=1 整体降级；
     ② 视距昏暗（Always-On 抬腕前）时玻璃会闪，此时自动退回普通材质。
   ============================================================ */
enum WatchGlass {
    /// 环境变量一次性读取（每次 body 都读 ProcessInfo 太浪费）
    static let disabled: Bool = {
        let e = ProcessInfo.processInfo.environment
        return e["MBWATCH_NO_GLASS"] == "1" || e["MBW_FLAT"] == "1"
    }()
}

struct WatchCard<S: Shape>: ViewModifier {
    let shape: S
    let tint: Color?
    /// 可点击的卡片（按钮）用交互式玻璃：点下去有真实的高光回应
    var interactive: Bool = false
    /// 个别地方（例如自检出图）想强制走普通材质
    var plain: Bool = false

    /// 环境自带降级信号
    @Environment(\.isLuminanceReduced) private var dimmed

    func body(content: Content) -> some View {
        if WatchGlass.disabled || plain || dimmed {
            content
                .background {
                    if let tint {
                        shape.fill(tint.opacity(0.20))
                            .background(.ultraThinMaterial, in: shape)
                    } else {
                        shape.fill(.ultraThinMaterial)
                    }
                }
                .overlay(shape.stroke((tint ?? Color.white).opacity(tint == nil ? 0.14 : 0.34), lineWidth: 1))
        } else {
            // 玻璃自己会画边缘高光，所以不再叠加描边；着色用 .tint（比材质淡一档，免得发浑）
            content.glassEffect(glass, in: shape)
        }
    }

    private var glass: Glass {
        var g: Glass = .regular
        if interactive { g = g.interactive() }
        if let tint { g = g.tint(tint.opacity(0.62)) }
        return g
    }
}

extension View {
    func watchCard<S: Shape>(_ shape: S, tint: Color? = nil,
                             interactive: Bool = false, plain: Bool = false) -> some View {
        modifier(WatchCard(shape: shape, tint: tint, interactive: interactive, plain: plain))
    }

    /// 小区域列表配色（复用菜单栏的小胶囊样式）
    func pill(_ color: Color, size: CGFloat = 10) -> some View {
        self
            .font(.system(size: WatchMetrics.fs(size), weight: .semibold))
            .monospacedDigit()
            .foregroundStyle(color)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Capsule().fill(color.opacity(0.18)))
            .fixedSize()
    }
}

/* ============================================================
   卡片容器：把相邻的玻璃卡片编成一组

   GlassEffectContainer 让系统把一整屏玻璃当成一个渲染批次，
   滚动时不会一张张重新采样背景 —— 这是「用玻璃也不掉帧」的关键。
   ============================================================ */
struct CardStack<Content: View>: View {
    var spacing: CGFloat = WatchMetrics.gap
    var alignment: HorizontalAlignment = .leading
    @ViewBuilder var content: Content

    var body: some View {
        GlassEffectContainer(spacing: spacing) {
            VStack(alignment: alignment, spacing: spacing) { content }
        }
    }
}

/// 分区小标题（左标题 + 右侧说明）
struct WatchSectionHead: View {
    let title: String
    let right: String?

    init(_ title: String, right: String? = nil) {
        self.title = title
        self.right = right
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            Text(title)
                .font(.system(size: WatchMetrics.fs(12), weight: .semibold))
                .foregroundStyle(.secondary)
            Spacer(minLength: 2)
            if let right, !right.isEmpty {
                Text(right)
                    .font(.system(size: WatchMetrics.fs(10)))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
            }
        }
        .padding(.horizontal, 2)
    }
}
