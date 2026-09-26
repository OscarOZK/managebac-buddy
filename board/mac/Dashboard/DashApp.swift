import SwiftUI
import AppKit

/* ======================================================================
   ManageBac-Buddy —— 现在是**一个** App（第 18 轮合并）
   ----------------------------------------------------------------------
   以前是主看板 + 菜单栏两个独立的 .app，各跑一个进程。两个进程同时：
     · 各跑一遍 Notifier.evaluate → 同一条消息弹两遍；
     · 各写一遍自己的 notify-state.json → 互相覆盖去重记录 →
       去重失效，同一条旧成绩可以反复重播；
     · 各拉一次 bridge /api/data → 白白多抓一倍。
   合并成一个进程后：一个主窗口 + 一个菜单栏图标，通知只有一个来源。
   ====================================================================== */

// MainWindow（把主窗口唤回来的那把小钥匙）挪去了 Dashboard/MainWindow.swift：
// 离屏渲染自检也要编 MenuBar/Panel.swift，而自检自己带一个 @main，
// 不能和本文件的 @main 同时进一个二进制。「定义」必须放在两边都会编的文件里。

/// 抓住主窗口的 NSWindow，并登记 `openWindow(id:"main")`
private struct MainWindowBridge: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        WindowCatcher()
            .frame(width: 0, height: 0)
            .onAppear { MainWindow.open = { openWindow(id: "main") } }
    }
}

private struct WindowCatcher: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let v = NSView()
        DispatchQueue.main.async { MainWindow.window = v.window }
        return v
    }
    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async { MainWindow.window = nsView.window }
    }
}

@main
struct MBApp: App {
    @NSApplicationDelegateAdaptor(MBLaunch.self) private var launch
    @StateObject private var store = DataStore.shared
    @StateObject private var settings = BoardSettings.shared

    /// 尽一切可能早：迁移老数据、装后端，都得赶在**第一个 WKWebView 建出来之前**
    /// （WebKit 一旦建好新 Bundle ID 的目录，就没法把老 cookie 搬过去了）。
    init() {
        LegacyIdentity.bootstrap()
    }

    var body: some Scene {
        Window("ManageBac-Buddy", id: "main") {
            Group {
                // ★ 开场动画只演一次 ★
                //   快闪 + 彩虹 hello 这两幕，只在**这个安装第一次打开 App**
                //   时演。退出后台再进来 —— 直接就是看板，一帧动画都不放。
                //   想再看一遍：菜单「重新运行首次配置向导」/ 设置页「开始引导」
                //   —— 那两处会把下面两个标记一起清掉，于是完整重演。
                //
                //   两个标记各管一件事，缺一个都有洞：
                //     onboarded   = 新手导览走完了没有 —— **功能**状态，
                //                   决定还要不要接引导（英语名、希悦、主题这些
                //                   没配完的话，光有看板是空壳）。
                //     introPlayed = 这台机器进过开场了没有 —— **演出**状态，
                //                   决定还演不演动画。
                //   只看 onboarded 会漏掉「动画看完了、导览走到一半就退出」
                //   这种夹在中间的状态：那时 onboarded 还是 false，
                //   下次进来**刚看过的动画又从头演一遍** —— 正是用户不要的。
                if settings.onboarded {
                    DashRoot(store: DataStore.shared)
                        .transition(.opacity)
                } else {
                    // 没走完导览。进过开场就直接接上引导（不重播动画），
                    // 没进过就从头演完整两幕。
                    FirstRunFlow(skipGreeting: settings.introPlayed)
                }
            }
            .background(MainWindowBridge())
            .environmentObject(settings)
            .preferredColorScheme(settings.effectiveTheme.scheme)
            .frame(minWidth: 1020, minHeight: 660)
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1260, height: 860)
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(replacing: .newItem) { }
            CommandGroup(after: .toolbar) {
                // 这里的按键不写死：真正的绑定在「设置 → 快捷键」里，
                // 由 Hotkeys 统一分发，菜单只负责给个入口。
                Button("刷新数据（\(settings.keyRefresh.isEmpty ? "未绑定" : Shortcut.display(settings.keyRefresh))）") {
                    Task { await DataStore.shared.load(force: true); await DataStore.shared.loadTeams() }
                }
                Button("刷新 Teams") { Task { await DataStore.shared.loadTeams() } }
                Divider()
                Button("打开 ManageBac 网站") {
                    LinkOpen.go(URL(string: DataStore.manageBac)!,
                                source: "managebac", settings: BoardSettings.shared)
                }
                .keyboardShortcut("o", modifiers: [.command, .shift])
                Divider()
                Button("重新运行首次配置向导") {
                    // 两个标记一起清：onboarded 决定「接回引导」，
                    // introPlayed 决定「开场两幕重演一遍」。
                    // 只清 onboarded 的话，引导会接上、但动画不会演 ——
                    // 而用户要的就是「重走新手导览也会触发」那两段动画。
                    BoardSettings.shared.onboarded = false
                    BoardSettings.shared.introPlayed = false
                }
            }
        }

        // 小看板界面全在 AppKit 的 NSPanel 里，SwiftUI 只需要一个占位 scene
        Settings { EmptyView().frame(width: 0, height: 0) }
    }
}

final class MBLaunch: NSObject, NSApplicationDelegate {
    private var panel: PanelController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        MainActor.assumeIsolated {
            NSApp.setActivationPolicy(.regular)
            NSApp.activate(ignoringOtherApps: true)
            let s = BoardSettings.shared
            s.activatePaletteOnly()
            s.syncECStudent()
            DataStore.shared.begin()

            // 把「这次启动走了哪一支」落一行日志。这两支的差别只体现在
            // 界面上（有没有快闪 + hello），截图看权限、肉眼又要等人盯着，
            // 一行日志是最省事的判据 —— 也方便以后有人反馈"怎么又演动画了"
            // 时直接对上。
            let branch: String
            if s.onboarded { branch = "直进看板（不播任何动画）" }
            else if s.introPlayed { branch = "跳过开场动画，直接接上新手导览" }
            else { branch = "播快闪 + hello（首次进 App）" }
            Log.write("启动：onboarded=\(s.onboarded) introPlayed=\(s.introPlayed) → \(branch)")

            // 内置网页引擎：把浏览器搬进 App 自己身体里。
            // ManageBac / Teams / 希悦 三个集成的登录都靠它，
            // 这样别人电脑上不用装 Chrome，也不用等 150MB 下载。
            WebEngine.shared.start()
            WebEngineChannel.shared.start()

            // 菜单栏图标：和大看板同进程，不再需要另一个 App
            let c = PanelController()
            c.install()
            panel = c
            c.syncAppearance(force: true)
            Appearance.apply(s.theme)
        }
    }

    /// 关掉主窗口 ≠ 退出：菜单栏图标还要继续用（点它可以随时把看板唤回来）。
    /// 真退出走菜单栏面板里的「退出」或 ⌘Q。
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    /// 点 Dock 图标 / 重新双击 App：把窗口唤回来（窗口被关掉时 SwiftUI 不会自己重开）
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { MainActor.assumeIsolated { MainWindow.bring() } }
        return true
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool { true }
}
