import SwiftUI

/* 面板尺寸：本机屏幕 1470×956、可用高 838（减去菜单栏与 Dock）。
   内容变多后加高到 740，尽量少滚动；不再追求「占屏 1/6」。 */
enum Panel {
    static let width: CGFloat = 460
    static let height: CGFloat = 740
    /// 内容区左右内边距（与根视图一致，网格卡片宽度要用它算）
    static let pad: CGFloat = 16
}

/* 渲染预览模式开关（仅供命令行 --render 自测用，正常运行时全是 false） */
enum PreviewFlags {
    static var flat = false
    static var gpaExpanded = false
    static var overdueExpanded = false
    /// ScrollView 在 ImageRenderer 里不出内容 → 自检时换成普通 VStack
    static var noScroll = false
    /// 自检时放开高度，把整份内容一次性画出来（正常运行时 false，固定 460×700）
    static var fullHeight = false
    /// 自检时把「现在」定到某个时刻（正常运行时 nil），用来核对上课/课间/晚自习等状态
    static var nowOverride: Date? = nil
}

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

/* MARK: - 液态玻璃 / 预览降级 */

struct GlassSurface<S: Shape>: ViewModifier {
    let shape: S
    let tint: Color?

    func body(content: Content) -> some View {
        if PreviewFlags.flat {
            content
                .background(shape.fill(Color.black.opacity(0.06)))
                .overlay(shape.stroke(Color.black.opacity(0.16), lineWidth: 1))
        } else {
            content.glassEffect(tint.map { Glass.regular.tint($0) } ?? .regular, in: shape)
        }
    }
}

extension View {
    func glassSurface<S: Shape>(_ shape: S, tint: Color? = nil) -> some View {
        modifier(GlassSurface(shape: shape, tint: tint))
    }
}
