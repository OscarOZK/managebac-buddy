import SwiftUI
import AppKit
import Combine

/* ======================================================================
   菜单栏面板（第 18 轮：已并入主 App，不再是独立进程）
   ----------------------------------------------------------------------
   为什么不用 MenuBarExtra？
     `.menuBarExtraStyle(.window)` 有一个硬毛病：**只要点到别处它就会自动收起**，
     用户每次都得重新点开一次图标，很烦。
   所以这里自己搭：
     · NSStatusItem 管菜单栏图标（角标跟着数据实时重画）
     · NSPanel（borderless + nonactivating + hidesOnDeactivate=false）管面板，
       它不会因为失去焦点而消失，只有这些情况才会收：
         - 再点一次菜单栏图标
         - 按 Esc
         - 点了「展开完整看板」并跳走
   启动入口在 Dashboard/DashApp.swift 的 MBApp / MBLaunch —— 同一个进程里
   既开主窗口又装这个面板，通知就不会再被两个 App 各发一遍。
   ====================================================================== */

/* ======================================================================
   面板控制器
   ====================================================================== */

@MainActor
final class PanelController: NSObject {
    private var statusItem: NSStatusItem?
    private var panel: NSPanel?
    private var hosting: NSHostingView<AnyView>?
    private var bag = Set<AnyCancellable>()
    private var builtWidth: CGFloat = 0
    /// 建宿主视图时用的主题指纹：变了就重建（色板/亮暗要真正生效）
    private var builtThemeKey = ""
    private var escMonitor: Any?

    /* ---------------- 安装 ---------------- */

    func install() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let b = item.button {
            b.imagePosition = .imageOnly
            b.target = self
            b.action = #selector(togglePanel(_:))
            b.sendAction(on: [.leftMouseUp])
        }
        statusItem = item
        refreshIcon()

        // 数据或设置一变，菜单栏角标跟着重画
        DataStore.shared.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.refreshIcon() }
            .store(in: &bag)
        BoardSettings.shared.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                // 主题相关（大看板那边改的也会经由设置文件同步过来）：
                // 重新激活调色板 + 跟随窗口 appearance，必要时重建宿主视图
                self?.syncAppearance()
                self?.refreshIcon()
                self?.resizeIfNeeded()
            }
            .store(in: &bag)

        // 兜底：定时重画一次，防止漏掉某次变化
        Timer.publish(every: 30, on: .main, in: .common).autoconnect()
            .sink { [weak self] _ in self?.refreshIcon() }
            .store(in: &bag)

        // 快速设置展开 / 收起时，面板要跟着长高 / 缩回去。
        // 面板底边锚在菜单栏图标下方，所以长高的部分全往上顶 —— 视觉上像
        // 从图标那里"抽"出来一截，比让用户自己滚自然得多。
        NotificationCenter.default.publisher(for: PanelMetrics.resizeNote)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.applyExtraHeight() }
            .store(in: &bag)

        // Esc 收起面板。面板是非激活式的，SwiftUI 的键盘快捷键不一定会到，
        // 所以直接挂一个本地事件监听 —— 只有面板可见时才吃这个按键。
        escMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in
            guard let self, self.panel?.isVisible == true, e.keyCode == 53 else { return e }
            self.hide()
            return nil
        }
    }

    private func refreshIcon() {
        let s = BoardSettings.shared
        let c = DataStore.shared.bandCounts(settings: s)
        let img = StatusBadge.image(red: c.red, yellow: c.yellow, blue: c.blue, s)
        img.isTemplate = false
        statusItem?.button?.image = img
        statusItem?.button?.toolTip = c.tooltip(s)
    }

    /* ---------------- 面板 ---------------- */

    private func makePanel() -> NSPanel {
        PanelMetrics.height = desiredHeight()
        PanelMetrics.width = CGFloat(BoardSettings.shared.panelWidth)
        builtWidth = PanelMetrics.width

        let p = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: PanelMetrics.width, height: totalHeight()),
            styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
            backing: .buffered,
            defer: false)
        p.isFloatingPanel = true
        p.level = .statusBar
        p.hidesOnDeactivate = false            // ← 关键：切到别的 App 也不收
        p.becomesKeyOnlyIfNeeded = true
        p.isMovableByWindowBackground = false
        p.worksWhenModal = true
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        p.backgroundColor = .clear
        p.isOpaque = false
        p.hasShadow = true
        p.animationBehavior = .utilityWindow
        p.isReleasedWhenClosed = false
        p.contentView = makeHost()
        return p
    }

    private func makeHost() -> NSHostingView<AnyView> {
        let s = BoardSettings.shared
        let root = AnyView(
            PanelView(store: DataStore.shared, onClose: { [weak self] in self?.hide() })
                .environmentObject(s)
                // 合并成一个 App 后不再有「小看板独立主题」：
                // 面板和主窗口共用同一套亮暗/调色板（否则同一个进程里
                // 全局色板会被两边来回抢，谁都不知道自己该是什么颜色）。
                .preferredColorScheme(s.effectiveTheme.scheme)
        )
        let host = NSHostingView(rootView: root)
        host.frame = NSRect(x: 0, y: 0, width: PanelMetrics.width, height: PanelMetrics.height)
        // 窗口被拉高/拉矮时宿主视图要跟着变，否则面板会长出一块空白
        host.autoresizingMask = [.width, .height]
        hosting = host
        builtThemeKey = themeKey()
        return host
    }

    /// 主题指纹：亮暗 / 调色板任一变化都要重建
    private func themeKey() -> String {
        let s = BoardSettings.shared
        return "\(s.theme.rawValue)|\(s.palette.id)"
    }

    /// 主题变了就把外观落到 AppKit 上，并重建宿主视图。
    /// 只有主题指纹真的变了才动 —— 这个函数会在每次设置变化时被调用（拖滑块也在内），
    /// 不能每次都重建视图、重设外观。
    func syncAppearance(force: Bool = false) {
        let s = BoardSettings.shared
        let key = themeKey()
        let changed = force || key != builtThemeKey
        let mode = s.theme
        if changed {
            s.activatePaletteOnly()                   // 激活对应调色板
            Appearance.apply(mode)
            builtThemeKey = key
        }
        if let p = panel {
            Appearance.applyToWindow(p, mode)
            if changed {
                p.contentView = makeHost()
                p.setContentSize(NSSize(width: p.frame.width, height: PanelMetrics.height))
            }
        }
    }

    /// 面板高度：优先用用户设置，再被屏幕高度兜住（上下各留一点余地）
    private func desiredHeight() -> CGFloat {
        let vis = (NSScreen.main?.visibleFrame.height ?? 900)
        let want = CGFloat(BoardSettings.shared.panelHeight)
        return max(320, min(want, vis - 70))
    }

    /// 实际窗口高度 = 基准高度 + 快速设置展开的那一块（同样被屏幕兜住）
    private func totalHeight() -> CGFloat {
        let vis = (currentScreen()?.visibleFrame.height ?? NSScreen.main?.visibleFrame.height ?? 900)
        return max(320, min(desiredHeight() + PanelMetrics.extraHeight, vis - 70))
    }

    /// 快速设置展开时把面板长高一块。
    /// 底边不动（`origin.y` 往上补差值），所以视觉上是往上"长"，
    /// 不会把面板整个往上跳一格。
    private func applyExtraHeight() {
        guard let p = panel else { return }
        let want = totalHeight()
        guard abs(want - p.frame.height) > 0.5 else { return }
        // 面板还没显示时只改尺寸，不做动画（免得在屏幕角落闪一下）
        guard p.isVisible else {
            p.setContentSize(NSSize(width: p.frame.width, height: want))
            return
        }
        var f = p.frame
        f.origin.y += f.height - want
        f.size.height = want
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.30
            // 和 SwiftUI 那边的 Motion.reveal（0.34s 弹簧）节奏对齐：
            // 用同一条缓出曲线，窗口和内容才像一起长出来的
            ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.22, 0.9, 0.32, 1)
            p.animator().setFrame(f, display: true)
        }
    }

    private func resizeIfNeeded() {
        guard let p = panel else { return }
        let want = CGFloat(BoardSettings.shared.panelWidth)
        if want != builtWidth {
            PanelMetrics.height = desiredHeight()
            PanelMetrics.width = want
            builtWidth = want
            p.contentView = makeHost()
        }
        // 高度可能因为「快速设置展开」或用户改了面板高度而变化
        applyExtraHeight()
    }

    private func currentScreen() -> NSScreen? {
        statusItem?.button?.window?.screen ?? NSScreen.main
    }

    func show() {
        // 每次都先把主题对齐一次：面板可能已经开着好几天了
        syncAppearance()
        if panel == nil { panel = makePanel() }
        guard let p = panel,
              let b = statusItem?.button,
              let bWin = b.window,
              let screen = currentScreen() else { return }

        Appearance.applyToWindow(p, BoardSettings.shared.theme)

        let btn = bWin.convertToScreen(b.convert(b.bounds, to: nil))
        var x = btn.midX - p.frame.width / 2
        x = min(max(x, screen.visibleFrame.minX + 8),
                screen.visibleFrame.maxX - p.frame.width - 8)
        let y = btn.minY - p.frame.height - 6
        p.setFrameOrigin(NSPoint(x: x, y: y))
        p.orderFrontRegardless()
        p.makeKey()
    }

    func hide() {
        panel?.orderOut(nil)
    }

    @objc private func togglePanel(_ sender: Any?) {
        if let p = panel, p.isVisible { hide() } else { show() }
    }
}
