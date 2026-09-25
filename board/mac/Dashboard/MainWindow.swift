import AppKit

/* ----------------------------------------------------------------------
   菜单栏面板要能唤起主窗口。
   `openWindow` 只在 SwiftUI 视图环境里拿得到，所以主窗口出现时把它存下来，
   面板那边（AppKit 世界）直接调用这个闭包。

   为什么单独一个文件：这东西被**两边**用 ——
     · 正式 App（Dashboard/DashApp.swift 里有 @main）
     · 离屏渲染自检（Dashboard/RenderCheck.swift 里也有 @main）
   两个 @main 不能同时编进一个二进制，而自检又必须能编过 Panel.swift
   （Panel.swift 里点了「打开看板」就调 MainWindow.bring）。
   所以把它从 DashApp.swift 里抽出来，两个构建清单都带上它。
   ---------------------------------------------------------------------- */

@MainActor
enum MainWindow {
    /// 主窗口的弱引用：用户点红叉之后它会变成 nil，那就让 SwiftUI 重开一个
    static weak var window: NSWindow?
    static var open: (() -> Void)?

    static func bring() {
        NSApp.activate(ignoringOtherApps: true)
        if let w = window, w.isVisible {
            w.makeKeyAndOrderFront(nil)
            return
        }
        open?()
    }
}
