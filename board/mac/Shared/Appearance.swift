import SwiftUI
import AppKit

/* ======================================================================
   深浅色主题
   ----------------------------------------------------------------------
   之前只写了 `.preferredColorScheme(...)`，它只改 SwiftUI 的 environment。
   而「液态玻璃」、材质、窗口底色、红绿灯这些是 AppKit 画的，它们看的是
   `NSApp.appearance`，所以切主题时看起来「完全没反应」。

   这里把两者绑在一起：切主题 = 同时改 NSApp.appearance + 所有已开窗口的
   appearance。之后新建的窗口会自动继承 NSApp.appearance。
   ====================================================================== */

enum Appearance {

    /// 把主题真正落到 AppKit 上
    @MainActor
    static func apply(_ mode: ThemeMode) {
        let appearance: NSAppearance? = {
            switch mode {
            case .system: return nil                      // nil = 跟随系统
            case .light:  return NSAppearance(named: .aqua)
            case .dark:   return NSAppearance(named: .darkAqua)
            }
        }()
        // 用 NSApplication.shared 拿到实例，避免启动早期 NSApp 还是 nil 时踩空
        let app = NSApplication.shared
        app.appearance = appearance
        for w in app.windows { w.appearance = appearance }
    }

    /// 窗口刚建出来时补一刀（新窗口不一定继承到）
    @MainActor
    static func applyToWindow(_ w: NSWindow, _ mode: ThemeMode) {
        switch mode {
        case .system: w.appearance = nil
        case .light:  w.appearance = NSAppearance(named: .aqua)
        case .dark:   w.appearance = NSAppearance(named: .darkAqua)
        }
    }
}

/// 看板 App 自己的位置。以前写死成某个人的桌面路径 —— 换台机器就指到空气里。
let kDashboardApp = Bundle.main.bundlePath

/// 菜单栏面板的尺寸约定：PanelController 显示前会按当前屏幕高度写入
enum PanelMetrics {
    static var height: CGFloat = 740
    static var width: CGFloat = 420

    /* 快速设置展开时，面板本身往上长高一块。
       用户反馈「快速设置…上下滑动特别难用」——根因是面板高度是写死的，
       展开出来的四行全落在折叠线以下，得自己往下滚才看得见，点了像没反应。
       让面板跟着长高，内容就不用滚了；收起时再缩回去。 */
    static let quickExtra: CGFloat = 158
    /// 当前是否要多出这一块（由 PanelView 在展开/收起时写入）
    static var extraHeight: CGFloat = 0
    /// 面板要改高度了（本进程内通知，SwiftUI 写、PanelController 读）
    static let resizeNote = Notification.Name("mbboard.panel.resize")
}
