//  MBWidgetData.swift
//  ManageBac 小组件（watchOS）—— 取数、时间线
//
//  小组件是独立进程，拿不到 App 里的对象，所以自己请求一次本机桥接服务；
//  「现在」一律用 entry.date，保证同一条时间线里倒计时/课表状态自洽。

import Foundation
import SwiftUI
import WidgetKit
import os

/// 小组件侧日志（排查「小组件不刷新」时很有用）：
///   xcrun simctl spawn <设备> log show --last 5m \
///     --predicate 'subsystem == "cn.oscar.ManageBacWatch.widgets"'
enum MBLog {
    private static let logger = Logger(subsystem: "cn.oscar.ManageBacWatch.widgets", category: "data")
    static func write(_ text: String) { logger.info("\(text, privacy: .public)") }
}

/* 时间线里的一条：payload 为 nil 表示这次没取到数（电脑上的看板服务没开） */
struct MBEntry: TimelineEntry {
    let date: Date
    let payload: Payload?
    var failed: Bool { payload == nil }
}

/* 进程内缓存：系统要「编辑态预览」时用得上，顺带少发一次请求 */
enum MBCache {
    static var payload: Payload?
    static var at: Date?
}

enum MBData {
    /// 与 App 同一个地址（Apple Watch 模拟器上 127.0.0.1 就是这台 Mac）
    static let base = "http://127.0.0.1:8765"
    /// 一条 entry 覆盖 5 分钟，一次给 6 条（半小时），之后系统再来要新的
    static let step: Double = 300
    static let count = 6

    private static let session: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        c.timeoutIntervalForRequest = 6
        return URLSession(configuration: c)
    }()

    static func fetch() async -> Payload? {
        guard let url = URL(string: base + "/api/data") else { return nil }
        var req = URLRequest(url: url)
        req.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        do {
            let (data, resp) = try await session.data(for: req)
            if let h = resp as? HTTPURLResponse, h.statusCode >= 400 {
                MBLog.write("取数失败：HTTP \(h.statusCode)")
                return nil
            }
            let p = try JSONDecoder().decode(Payload.self, from: data)
            MBLog.write("取数 ok tasks=\(p.tasks?.count ?? 0) classes=\(p.classes?.count ?? 0) recent=\(p.recent?.count ?? 0) updating=\(p.updating ?? false)")
            return p
        } catch {
            MBLog.write("取数失败：\(error.localizedDescription)")
            return nil
        }
    }

    /// 服务端先回缓存、正在后台抓新数据时，等它一次
    static func load() async -> Payload? {
        var p = await fetch()
        if p?.updating == true {
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            if let fresh = await fetch(), fresh.updating != true { p = fresh }
        }
        MBCache.payload = p
        MBCache.at = Date()
        return p
    }

    static func timeline(_ p: Payload?, now: Date = Date()) -> Timeline<MBEntry> {
        let entries = (0 ..< count).map { i in
            MBEntry(date: now.addingTimeInterval(Double(i) * step), payload: p)
        }
        return Timeline(entries: entries, policy: .atEnd)
    }
}

/// 所有小组件共用同一个 provider（要的数据完全一样，没必要各写一份）
struct MBProvider: TimelineProvider {
    func placeholder(in context: Context) -> MBEntry {
        MBEntry(date: Date(), payload: MBCache.payload)
    }

    func getSnapshot(in context: Context, completion: @escaping (MBEntry) -> Void) {
        completion(MBEntry(date: Date(), payload: MBCache.payload))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<MBEntry>) -> Void) {
        Task {
            let p = await MBData.load()
            completion(MBData.timeline(p))
        }
    }
}

/* ============================================================
   小组件里常用的小工具（都跟 App 端同一口径）
   ============================================================ */

/// 剩余时间短写："1天21h" / "5h" / "42m"
func shortLeft(_ t: TaskVM, now: Date) -> String {
    if t.isOver { return "逾期" }
    guard let due = t.due else { return "—" }
    let ms = due.timeIntervalSince(now) * 1000
    if ms < 0 { return "逾期" }
    let h = ms / 3_600_000
    if h >= 24 { return "\(Int(h / 24))天\(Int(h.truncatingRemainder(dividingBy: 24)))h" }
    if h >= 1 { return "\(Int(h))h" }
    return "\(max(1, Int((ms / 60_000).rounded())))m"
}

/// 倒计时短写：>=1 小时 "1:23:45"，否则 "23:45"
func shortCountdown(_ interval: TimeInterval) -> String {
    let s = max(0, Int(interval.rounded()))
    let h = s / 3600, m = (s % 3600) / 60, sec = s % 60
    if h > 0 { return String(format: "%d:%02d:%02d", h, m, sec) }
    return String(format: "%02d:%02d", m, sec)
}

/// 综合小组件用的倒计时短写：长时段不写秒（"3天2h" / "14h"），
/// 短时段才写 "23:41" —— 矩形一行只有 164pt，"14:32:11" 会把课名挤没。
func mixCD(_ interval: TimeInterval) -> String {
    let s = max(0, interval)
    if s >= 24 * 3600 { return "\(Int(s / 86400))天\(Int(s.truncatingRemainder(dividingBy: 86400) / 3600))h" }
    if s >= 6 * 3600 { return "\(Int((s / 3600).rounded()))h" }
    return shortCountdown(s)
}

/* ============================================================
   会自己走的倒计时

   WidgetKit 里 `Text(timerInterval:)` 由系统逐秒刷新，**不需要新的时间线条目** ——
   所以小组件上的倒计时是真会动的。用静态字符串写的话，
   要等下一次时间线刷新（这里 5 分钟）才会变，表盘上就成了"冻住的数字"。

   超过 6 小时的（例如"距周一上课"）不值得让系统逐秒渲染，退回静态短写。
   ============================================================ */
struct MBCountdown: View {
    let target: Date
    let now: Date
    var size: CGFloat = 13
    var weight: Font.Weight = .bold

    var body: some View {
        let iv = target.timeIntervalSince(now)
        Group {
            // 只有「这条时间线就是现在」时才交给系统走秒：
            // 版式自检会把「现在」定在别的时刻（甚至别的一天），而系统计时器永远按真实时钟走，
            // 硬用它只会画出 0:00 —— 这种情况退回静态短写。
            if iv > 0, iv < 6 * 3600, abs(now.timeIntervalSinceNow) < 90 {
                Text(timerInterval: now ... target, countsDown: true)
            } else {
                Text(iv <= 0 ? "00:00" : mixCD(iv))
            }
        }
        .font(.system(size: size, weight: weight, design: .rounded))
        .monospacedDigit()
        .lineLimit(1)
    }
}

/// 倒计时到的时间点 → "14:20"
func clockOf(_ d: Date) -> String { fmtClock(d) }

/// 日期短写："9/18 周五"（小组件横向空间紧）
func dayShort(_ d: Date) -> String {
    let c = Calendar.current.dateComponents([.month, .day], from: d)
    let w = ["周日", "周一", "周二", "周三", "周四", "周五", "周六"][max(0, min(6, Schedule.jsDay(d)))]
    return "\(c.month ?? 0)/\(c.day ?? 0) \(w)"
}
