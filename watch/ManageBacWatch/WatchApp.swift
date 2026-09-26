//  WatchApp.swift
//  ManageBac Watch App —— 入口
//  新建文件（菜单栏版 App.swift 未改动）。
//
//  这是一个「独立 watch App」（watch-only，不需要 iPhone 配套 App）。
//  数据来自这台 Mac 上跑着的 ManageBac-Buddy桥接服务（http://127.0.0.1:8765）。
//
//  调试用环境变量（只在命令行启动时有意义）：
//    MBWATCH_DUMP=1        启动后把派生数据（待办排序/课堂/最新成绩/GPA）打印到控制台
//    MBWATCH_DUMP_AT=09:45 把「现在」定在今天的这个时刻，用来核对上课/课间/横条位置
//    MBWATCH_SCROLL_TO=gpa 启动后自动滚到某个分区（timer/todo/class/latest/gpa/footer），用于截图核对

import SwiftUI

enum WatchDump {
    static var isOn: Bool {
        ProcessInfo.processInfo.environment["MBWATCH_DUMP"] == "1"
    }

    /// 定住「现在」（自检用），格式 "HH:MM"
    static var pinnedNow: Date? {
        guard let s = ProcessInfo.processInfo.environment["MBWATCH_DUMP_AT"], !s.isEmpty else { return nil }
        let p = s.split(separator: ":").compactMap { Int($0) }
        guard let h = p.first else { return nil }
        var c = Calendar.current.dateComponents([.year, .month, .day], from: Date())
        c.hour = h
        c.minute = p.count > 1 ? p[1] : 0
        c.second = 0
        return Calendar.current.date(from: c)
    }

    /// 自检时自动滚动到指定分区
    static var scrollTarget: String? {
        ProcessInfo.processInfo.environment["MBWATCH_SCROLL_TO"]
    }

    /// 自检时让 GPA 一进来就是展开的（手表上没法用命令点按钮）
    static var gpaExpanded: Bool {
        ProcessInfo.processInfo.environment["MBWATCH_GPA"] == "1"
    }

    static func applyScroll(_ proxy: ScrollViewProxy) {
        guard let t = scrollTarget, !t.isEmpty else { return }
        // 数据到达后内容高度会变，滚一次可能被冲掉 → 多滚几次
        for delay in [1.2, 3.0, 5.0] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                // "bottom" = 滚到底（看 GPA 与底部条），其余按分区顶部对齐
                if t == "bottom" { proxy.scrollTo("footer", anchor: .bottom) }
                else { proxy.scrollTo(t, anchor: .top) }
            }
        }
    }
}

@main
struct ManageBacWatchApp: App {
    @StateObject private var store = WatchStore.shared

    var body: some Scene {
        WindowGroup {
            WatchRootView(store: store)
        }
    }
}
