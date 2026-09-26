import SwiftUI
import AppKit

/* ======================================================================
   主题素材（用户要求：两组原图本身也要插入在 App 中）

   每套限时主题带 3 张校园实拍。查找顺序：
     ① App 包内 Resources/Themes/<palette>/<file>   ← 正式交付
     ② <数据目录>/themes/<palette>/<file>          ← 用户想自己换图就放这里
     ③ ~/.mbboard/themes/<palette>/<file>          ← 老开发布局，留着不碍事
   都找不到就返回 nil，界面优雅降级（只显示色板，不显示照片）。
   ====================================================================== */

@MainActor
enum ThemeAssets {

    private static var cache: [String: NSImage] = [:]

    static func url(palette: String, file: String) -> URL? {
        if let u = Bundle.main.resourceURL?
            .appendingPathComponent("Themes/\(palette)/\(file)"),
           FileManager.default.fileExists(atPath: u.path) {
            return u
        }
        // ② 数据目录（分发版就是 ~/Library/Application Support/ManageBac-Buddy/themes）
        let data = MBBPaths.home.appendingPathComponent("themes/\(palette)/\(file)")
        if FileManager.default.fileExists(atPath: data.path) { return data }
        // ③ 老开发布局
        let home = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".mbboard/themes/\(palette)/\(file)")
        if FileManager.default.fileExists(atPath: home.path) { return home }
        return nil
    }

    static func image(palette: String, file: String) -> NSImage? {
        let key = "\(palette)/\(file)"
        if let hit = cache[key] { return hit }
        guard let u = url(palette: palette, file: file),
              let img = NSImage(contentsOf: u) else { return nil }
        cache[key] = img
        return img
    }

    static func images(_ p: Palette) -> [NSImage] {
        p.photos.compactMap { image(palette: p.id, file: $0) }
    }

    /// 主题缩略图：等比裁成方形，用于设置页的主题卡
    static func thumb(_ p: Palette, _ file: String, size: CGFloat) -> NSImage? {
        guard let src = image(palette: p.id, file: file) else { return nil }
        let s = src.size
        guard s.width > 1, s.height > 1 else { return src }
        let side = min(s.width, s.height)
        let crop = NSRect(x: (s.width - side) / 2, y: (s.height - side) / 2,
                          width: side, height: side)
        let out = NSImage(size: NSSize(width: size, height: size))
        out.lockFocus()
        NSGraphicsContext.current?.imageInterpolation = .high
        src.draw(in: NSRect(x: 0, y: 0, width: size, height: size),
                 from: crop, operation: .sourceOver, fraction: 1)
        out.unlockFocus()
        return out
    }

    /// 主题氛围底纹：把第一张原图糊成一层极淡的底，
    /// 只用在限时主题且用户没关掉的时候，保证「所有颜色都来自图片」这一点看得见。
    static func backdrop(_ p: Palette, scheme: ColorScheme) -> NSImage? {
        guard p.isLimited, BoardSettings.shared.themeBackdrop else { return nil }
        guard let src = images(p).first else { return nil }
        return src
    }
}

/// 页面底纹视图。两条路：
///   · `photos` 有图 → 把原图强模糊垫在底下（限时主题）
///   · `drawn == "midautumn"` → 直接画一整套矢量中秋月夜
///
/// 注意这里必须用 GeometryReader 把图**钉死**在容器尺寸上：
/// `.aspectRatio(contentMode: .fill)` 的图片会为了「铺满」而报出比自己容器更大的尺寸，
/// 放在 ZStack 里就会把整个窗口撑宽 —— 表现为设置页右边被切掉、内容整体左移。
/// GeometryReader 只吃提议尺寸、不把子视图尺寸往上传，底纹就永远只是底纹。
struct ThemeBackdrop: View {
    let scheme: ColorScheme
    @EnvironmentObject private var settings: BoardSettings

    var body: some View {
        let p = settings.palette
        if settings.themeBackdrop, p.drawn == "midautumn" {
            // 矢量场景：自己就是一层可交互的月色（点击落桂、点月放大），
            // 所以**不能**加 allowsHitTesting(false)。
            MoonNightBackdrop(scheme: scheme)
        } else if p.isLimited, settings.themeBackdrop,
                  let img = ThemeAssets.image(palette: p.id, file: p.photos.first ?? "") {
            GeometryReader { geo in
                Image(nsImage: img)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: geo.size.width, height: geo.size.height)
                    .clipped()
                    .blur(radius: 34)
                    .overlay(Theme.page(scheme).opacity(scheme == .dark ? 0.55 : 0.42))
            }
            .allowsHitTesting(false)
        }
    }
}

/// 把 NSImage 铺成 SwiftUI 的等比填充（带圆角裁切）
struct AssetImage: View {
    let image: NSImage
    var radius: CGFloat = 12

    var body: some View {
        Image(nsImage: image)
            .resizable()
            .aspectRatio(contentMode: .fill)
            .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
    }
}
