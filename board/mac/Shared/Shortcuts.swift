import SwiftUI
import AppKit

/* ======================================================================
   快捷键
   —— 用户要求「增加更丰富的可设置项，包括但不限于刷新频率和快捷键」。
   所以快捷键不是写死在代码里的，而是存进 settings.json 的字符串，界面上能改。

   规范串形如 "cmd+shift+r"：
     · 修饰键 cmd / shift / opt / ctrl，顺序随意
     · 主键用字符本身（"r"、"]"、","）或功能键名（"space"、"left"…）
     · 空串 = 不绑定
   ====================================================================== */

struct Shortcut: Equatable {
    var key: String = ""     // 规范化后的主键（小写）
    var cmd = false
    var shift = false
    var opt = false
    var ctrl = false

    /// 解析 "cmd+shift+r"；空串或无法识别返回 nil
    init?(_ raw: String) {
        let parts = raw.lowercased()
            .split(separator: "+")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard !parts.isEmpty else { return nil }

        var k = ""
        for p in parts {
            switch p {
            case "cmd", "command", "⌘":       cmd = true
            case "shift", "⇧":                shift = true
            case "opt", "option", "alt", "⌥": opt = true
            case "ctrl", "control", "⌃":      ctrl = true
            default:                          k = Self.canonKey(p)
            }
        }
        // 只有修饰键、没有主键，是无效组合
        guard !k.isEmpty else { return nil }
        key = k
    }

    /// 把各种写法收敛成一种：空格 → space、方向键 → left/right/up/down
    static func canonKey(_ s: String) -> String {
        switch s {
        case "space", "spacebar", " ":      return "space"
        case "return", "enter", "\r":       return "return"
        case "tab":                         return "tab"
        case "escape", "esc":               return "escape"
        case "delete", "backspace":         return "delete"
        case "←":                            return "left"
        case "→":                            return "right"
        case "↑":                            return "up"
        case "↓":                            return "down"
        default:                            return s
        }
    }

    /// 从一次按键事件里读出一个快捷键；只按了修饰键则返回 nil
    init?(event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard let chars = event.charactersIgnoringModifiers?.lowercased(),
              !chars.isEmpty else { return nil }
        let k = Self.canonKey(chars)
        // 单独的修饰键按下（charactersIgnoringModifiers 会是空或特殊码）
        let mods: Set<String> = ["shift", "control", "option", "command", "capslock", "fn"]
        if mods.contains(k) { return nil }
        key = k
        cmd = flags.contains(.command)
        shift = flags.contains(.shift)
        opt = flags.contains(.option)
        ctrl = flags.contains(.control)
        // 一个修饰键都不带也能绑，但和全局输入冲突的概率太大，这里要求至少一个
        if !cmd && !shift && !opt && !ctrl { return nil }
    }

    /// 规范串，用于保存
    var string: String {
        var out: [String] = []
        if cmd { out.append("cmd") }
        if shift { out.append("shift") }
        if opt { out.append("opt") }
        if ctrl { out.append("ctrl") }
        out.append(key)
        return out.joined(separator: "+")
    }

    /// 界面展示，macOS 习惯顺序：⌃⌥⇧⌘
    var display: String {
        var s = ""
        if ctrl { s += "⌃" }
        if opt { s += "⌥" }
        if shift { s += "⇧" }
        if cmd { s += "⌘" }
        s += Self.prettyKey(key)
        return s
    }

    static func prettyKey(_ k: String) -> String {
        switch k {
        case "space":  return "Space"
        case "return": return "↩"
        case "tab":    return "⇥"
        case "escape": return "⎋"
        case "delete": return "⌫"
        case "left":   return "←"
        case "right":  return "→"
        case "up":     return "↑"
        case "down":   return "↓"
        case ",":      return ","
        default:       return k.uppercased()
        }
    }

    /// 这个事件是不是按下了本快捷键
    func matches(_ e: NSEvent) -> Bool {
        let flags = e.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard let chars = e.charactersIgnoringModifiers?.lowercased() else { return false }
        return Self.canonKey(chars) == key
            && flags.contains(.command) == cmd
            && flags.contains(.shift) == shift
            && flags.contains(.option) == opt
            && flags.contains(.control) == ctrl
    }

    /// 展示用：把 "cmd+r" 变成 "⌘R"；空串给一个占位
    static func display(_ raw: String, empty: String = "未设置") -> String {
        Shortcut(raw)?.display ?? empty
    }
}

/* ---------------- 全局热键分发 ----------------
   两个 App 各自装一个本地监听：窗口在前台时才响应，不抢系统全局快捷键，
   所以不会和别的应用打架。绑定用字符串 id 覆盖式登记，改完重绑即可。 */

@MainActor
enum Hotkeys {
    private static var monitor: Any?
    private static var handlers: [String: (Shortcut, () -> Void)] = [:]

    static func install() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { e in
            // 正在输入框里打字时不要抢
            if let responder = NSApp.keyWindow?.firstResponder,
               responder is NSTextView || responder is NSTextField { return e }
            for (_, pair) in handlers where pair.0.matches(e) {
                pair.1()
                return nil
            }
            return e
        }
    }

    static func unbindAll() { handlers.removeAll() }

    static func bind(_ id: String, _ raw: String, _ fn: @escaping () -> Void) {
        guard let sc = Shortcut(raw) else { handlers.removeValue(forKey: id); return }
        handlers[id] = (sc, fn)
    }

    /// 展示用：某个 id 当前的按键
    static func display(_ raw: String) -> String { Shortcut.display(raw) }
}

/* ---------------- 快捷键输入框 ----------------
   点一下进入「录制」，再按一次组合键就绑定上；Esc 取消，⌫ 清除绑定。
   用局部事件监听而不是 SwiftUI 的按键，是因为要拿到真实的修饰键组合。 */

struct ShortcutField: View {
    let env: Env
    @Binding var value: String
    var width: CGFloat = 96

    @State private var recording = false
    @State private var monitor: Any?
    @State private var hovering = false

    var body: some View {
        Button { recording ? stop() : start() } label: {
            HStack(spacing: 5) {
                if recording {
                    Circle().fill(env.accent.color(env.scheme, lift: 0.10))
                        .frame(width: 6, height: 6)
                        .opacity(0.9)
                    Text("按下组合键…")
                        .font(.system(size: 11.5, weight: .semibold))
                } else {
                    Text(Shortcut.display(value, empty: "未设置"))
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                }
            }
            .foregroundStyle(recording ? env.accent.color(env.scheme, lift: 0.06)
                                       : Theme.ink(env.scheme))
            .padding(.horizontal, 10)
            .frame(minWidth: width, minHeight: 26)
            .contentShape(RoundedRectangle(cornerRadius: env.radius(8), style: .continuous))
        }
        .buttonStyle(.plain)
        .card(env.radius(Radius.sm),
              tint: recording
                    ? env.accent.color(env.scheme, lift: 0.86, opacity: env.scheme == .dark ? 0.18 : 0.14)
                    : (hovering ? env.accent.color(env.scheme, lift: 0.9,
                                                   opacity: env.scheme == .dark ? 0.10 : 0.07) : nil),
              look: env.look, shadow: false)
        .onHover { hovering = $0 }
        .help(recording ? "按 Esc 取消，按 ⌫ 清除绑定" : "点击后按下想要的组合键")
        .onDisappear { stop() }
    }

    private func start() {
        guard monitor == nil else { return }
        recording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { e in
            // Esc 取消
            if e.keyCode == 53 { stop(); return nil }
            // ⌫ 清除绑定
            if e.keyCode == 51 { value = ""; stop(); return nil }
            if let sc = Shortcut(event: e) {
                value = sc.string
                stop()
            }
            return nil   // 录制期间吞掉按键，免得同时触发别的操作
        }
    }

    private func stop() {
        recording = false
        if let m = monitor { NSEvent.removeMonitor(m); monitor = nil }
    }
}
