import SwiftUI
import AppKit

@main
struct MBMenuBarApp: App {
    @NSApplicationDelegateAdaptor(AppLaunch.self) private var launch
    /// 菜单栏角标与面板共用一个 Store（App 级别的 @StateObject，面板关着也保持刷新）
    @StateObject private var store = Store.shared

    var body: some Scene {
        MenuBarExtra {
            PanelView(store: store)
        } label: {
            MenuBarLabel(store: store)
        }
        .menuBarExtraStyle(.window)
    }
}

/// 启动钩子：一开机就把 5 分钟刷新循环跑起来，角标不用等面板打开
final class AppLaunch: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        MainActor.assumeIsolated { Store.shared.begin() }
    }
}

/// 菜单栏上那个东西：📂 + 红/黄/蓝待办数量小圆点，整体圈在一个细圆角框里。
/// 点击框内任何位置都会展开面板（整幅图就是菜单栏项的点击区）。
struct MenuBarLabel: View {
    @ObservedObject var store: Store

    var body: some View {
        let c = store.bandCounts
        Image(nsImage: StatusBadge.image(red: c.red, yellow: c.yellow, blue: c.blue))
            .renderingMode(.original)
            .help(c.tooltip)
            .onAppear { store.begin() }
    }
}
