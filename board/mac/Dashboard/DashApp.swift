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

/* ======================================================================
   这次启动走哪一支 —— **启动时算一次，之后冻结**
   ----------------------------------------------------------------------
   判据只有一条：`introVersion`（演过开幕演出的那个版本号）是不是等于
   **当前版本号**。不是「演过没有」。

   为什么必须带版本号，而不是一个 Bool —— 这是用户报过的那只 bug：
     用户在用 3.0，导览早走完了（onboarded=true），3.0 的开幕也早演过了。
     装了 3.5、第一次打开 —— 若演出状态只是个 Bool，它早就是 true，
     于是**新版第一次打开一帧动画都不放**。而用户期待的正相反。

   还有一层：这个决定必须**冻结**。因为 FirstRunFlow 一露面就会写
   introVersion，若让 body 直接读 settings 现算，那一写就会触发重绘，
   SwiftUI 当场把正在演第一帧的 Flow 换成看板 —— 动画夭折在半路。
   ====================================================================== */
@MainActor
enum LaunchPlan: Equatable {
    case dashboard      // 直进看板，一帧动画都不放
    case fullIntro      // 从头演（快闪 → hello），演完接上新手导览
    case onboardOnly    // 这一版的开幕演过了、导览没走完 → 直接接上导览
    case introOnly      // 只重演开幕，不碰导览状态

    /// ★ 唯一的判据在这里 ★
    static func decide(_ s: BoardSettings) -> LaunchPlan {
        // 拿不到版本号（Info.plist 里没有）时不能算「看过」——
        // 那会把「从没演过」误判成「这一版演过了」，恰好是最不该出的错。
        let seen = !BoardSettings.appVersion.isEmpty
                && s.introVersion == BoardSettings.appVersion
        if !seen {
            // 这一版的开幕还没放过 → 先演两幕。
            // 导览走完了的人只看这段开场（别再被问一遍英语名），
            // 没走完的人接着往下走引导。
            return s.onboarded ? .introOnly : .fullIntro
        }
        // 这一版已经演过了：导览没走完就接上，走完了就直进看板。
        return s.onboarded ? .dashboard : .onboardOnly
    }

    /// 启动日志用的一句话（写在 /tmp/mbboard-mac.log）
    var logLine: String {
        switch self {
        case .dashboard:   return "直进看板（不播任何动画）"
        case .fullIntro:   return "播快闪 + hello（这一版还没放过）→ 接上新手导览"
        case .introOnly:   return "播快闪 + hello（这一版第一次打开）→ 直进看板"
        case .onboardOnly: return "跳过开幕，直接接上新手导览"
        }
    }

    /// 这一支要不要演开幕
    var playsIntro: Bool { self == .fullIntro || self == .introOnly }
    /// 这一支要不要接新手导览
    var thenOnboard: Bool { self == .fullIntro || self == .onboardOnly }

    /// 启动那一刻冻结下来的那一个。MBLaunch 落日志时读它 ——
    /// 免得「日志里算一遍、界面里又算一遍」，两边哪天真走岔了，
    /// 日志就成了假证词。
    static var frozen: LaunchPlan = .dashboard
}

@main
struct MBApp: App {
    @NSApplicationDelegateAdaptor(MBLaunch.self) private var launch
    @StateObject private var store = DataStore.shared
    @StateObject private var settings = BoardSettings.shared

    /// 冻结的启动分流。用 @State（不是 let）是因为设置页那两个
    /// 「重走一遍」入口要能当场把它换掉 —— 见下面的 onChange。
    @State private var plan: LaunchPlan
    /// 每次「重走一遍」自增一次，用来换掉整棵子树的 identity。
    /// 没有它的话，第二次点「再看一次开幕」时 plan 没变化，
    /// SwiftUI 不会重建 FirstRunFlow，按钮看起来就是坏的。
    @State private var tick = 0

    /// 尽一切可能早：迁移老数据、装后端，都得赶在**第一个 WKWebView 建出来之前**
    /// （WebKit 一旦建好新 Bundle ID 的目录，就没法把老 cookie 搬过去了）。
    init() {
        LegacyIdentity.bootstrap()
        // 真机自检后门。正常运行时这个环境变量根本不存在，
        // autoRestart 保持 nil，界面上没有任何入口能写它（见 PreviewFlags）。
        PreviewFlags.autoRestart = ProcessInfo.processInfo.environment["MBB_AUTO_RESTART"]
        // 分流在这里定死。BoardSettings() 的 init 里就调了 load()，
        // 所以此刻读到的已经是磁盘上的真值。
        let p = LaunchPlan.decide(BoardSettings.shared)
        LaunchPlan.frozen = p
        _plan = State(initialValue: p)
    }

    var body: some Scene {
        Window("ManageBac-Buddy", id: "main") {
            Group {
                // ★ 开幕演出只演一次 —— 但「一次」是按**版本**算的 ★
                //   MB Buddy 快闪 + 彩虹 hello 这两幕，在
                //     · 这个版本第一次打开（不管是刚下载，还是从旧版升上来）
                //     · 用户主动重走新手导览
                //   这两种时候各演一遍。退出后台再进来 —— 直进看板，一帧不放。
                //   判据与理由见 LaunchPlan 的注释。
                switch plan {
                case .dashboard:
                    DashRoot(store: DataStore.shared)
                        .transition(.opacity)
                // 其余三支都由 FirstRunFlow 扛，差别只在两个开关：
                //   playsIntro  —— 演不演快闪 + hello
                //   thenOnboard —— 演完（或跳过）之后接不接新手导览
                // 具体哪一支对应哪种组合，见上面 decide() 的注释。
                case .fullIntro, .introOnly, .onboardOnly:
                    FirstRunFlow(playIntro: plan.playsIntro,
                                 thenOnboard: plan.thenOnboard)
                }
            }
            .id(tick)
            .background(MainWindowBridge())
            .environmentObject(settings)
            .preferredColorScheme(settings.effectiveTheme.scheme)
            .frame(minWidth: 1020, minHeight: 660)
            // ★ 设置页 / 菜单里那两个「重走一遍」入口 ★
            //   启动分流是冻结的，光改 onboarded / introVersion 界面不会动，
            //   所以那两处另外投一枚 flowRestart 信号过来。
            //   为什么不去监听 onboarded / introVersion 了事：因为 FirstRunFlow
            //   自己就会写 introVersion，监听它等于把刚演第一帧的 Flow 判成
            //   「演过了」当场换掉。只认「人主动点的」这一路。
            .onChange(of: settings.flowRestart) { _, want in
                guard let want else { return }
                switch want.kind {
                case .fullGuide:
                    plan = .fullIntro
                case .introOnly:
                    // 还没走完导览的人，重看开幕之后顺势接回导览，别让他掉进看板
                    plan = BoardSettings.shared.onboarded ? .introOnly : .fullIntro
                }
                tick &+= 1
            }
            // 真机自检后门：正常运行时 PreviewFlags.autoRestart 是 nil，这里什么都不做。
            // 它投下的是与设置页「重走一遍」按钮**完全相同**的那枚信号，
            // 下游走同一条路 —— 于是「按钮点了没反应」能在无人点击的机器上被验到。
            .onAppear {
                switch PreviewFlags.autoRestart {
                case "full":  BoardSettings.shared.requestFlowRestart(.fullGuide)
                case "intro": BoardSettings.shared.requestFlowRestart(.introOnly)
                default:      break
                }
            }
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
                    // 三个一起动：
                    //   onboarded   → 决定「接回新手导览」
                    //   introVersion→ 清空 = 开幕重演（清它比清 Bool 更干净，
                    //                 空串永远不等于当前版本号）
                    //   flowRestart → 把上面两件事告诉 MBApp，当场换幕
                    // 只清 onboarded 的话引导会接上、但动画不演 ——
                    // 而用户要的就是「重走新手导览也会触发」那两段动画。
                    BoardSettings.shared.onboarded = false
                    BoardSettings.shared.introVersion = ""
                    BoardSettings.shared.requestFlowRestart(.fullGuide)
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

            // 把「这次启动走了哪一支」落一行日志。这几支的差别只体现在
            // 界面上（有没有快闪 + hello），截图看权限、肉眼又要等人盯着，
            // 一行日志是最省事的判据 —— 也方便以后有人反馈"怎么又演动画了"
            // 时直接对上。
            //
            // 打印 LaunchPlan.frozen（启动时冻结的那一个），不是现算一遍 ——
            // 现算的话哪天和界面走岔了，日志就成了假证词。
            // 版本号一起打出来：这是「该不该演」的唯一判据，
            // 报告「没演 / 又演了」时第一眼要看的就是这两个字符串相不相等。
            Log.write("启动：onboarded=\(s.onboarded) 演过版本=\"\(s.introVersion)\" "
                      + "当前版本=\"\(BoardSettings.appVersion)\" → \(LaunchPlan.frozen.logLine)")

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
