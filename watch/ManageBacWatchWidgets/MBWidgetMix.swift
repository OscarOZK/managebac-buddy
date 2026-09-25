//  MBWidgetMix.swift
//  ManageBac 小组件 —— 综合系列（一屏同时看到「课 / 待办 / 成绩」）
//
//  这一组和前面 8 个「单一主题」小组件不同：一条矩形里塞三个板块，
//  顺序固定为「课（含倒计时）→ 待办 → 最新成绩」，三块都会在每次时间线刷新时更新。
//
//   9. 学习总览   课 + 倒计时 ｜ 最急待办 ｜ 最新成绩        ← 三合一，默认首选
//  10. 课堂速览   倒计时大字 ｜ 接下来两节 ｜ 最急待办
//  11. 成绩速览   最新成绩两条 ｜ 距下课 + 待办数
//  12. 紧迫速览   倒计时 ｜ 最急待办 ｜ 红黄蓝计数 + 最新等级
//
//  版式约束（踩过坑）：
//    · 矩形可用高只有 ~60pt，一律「最多 3 行」，超了会被表盘裁掉；
//    · 矩形可用宽 ~164pt，一行里「中文科目 + 倒计时」就要吃掉一大半，
//      所以第一行不放「正在上/下一节」这类文字标签，改由图标 + 「距下课/距上课」表达；
//    · 圆形复杂功能会裁掉外圈，圆形版式统一塞进 MBCircleBox（宽 56pt）里再排版。

import SwiftUI
import WidgetKit

/* ============================================================
   综合小组件专用小工具
   ============================================================ */

/// 圆形复杂功能的可用区：外接圆里再收一圈，保证三行文字都在圆内
struct MBCircleBox<Content: View>: View {
    var width: CGFloat = 56
    @ViewBuilder var content: Content
    var body: some View {
        VStack(spacing: 1) { content }
            .frame(width: width)
            .multilineTextAlignment(.center)
    }
}

/* ============================================================
   「接下来这节课」：综合小组件共用
   与 App 大计时卡同口径 —— 正在上课就倒计时到下课，否则倒计时到上课。
   ============================================================ */
enum MBMix {
    struct Up {
        let slot: Schedule.Slot
        /// 正在上这一节
        let inClass: Bool
        /// "正在上" / "下一节" / "周一"（圆形与行内用）
        let head: String
        /// "P5 11:40–12:20"
        let when: String
        /// "距下课" / "距上课" / "距周一上课"
        let tail: String
        /// 到目标时刻还有多久："23:41"
        let cd: String
        let target: Date

        /// 科目短名（"AP 初级微积分" → "初级微积分"），窄版面用
        var shortSubject: String { Subject.short(slot.subject) }
    }

    static func up(_ now: Date) -> Up? {
        if let c = Schedule.currentSlot(now) {
            return Up(slot: c, inClass: true, head: "正在上",
                      when: "\(c.pLabel) \(fmtClock(c.start))–\(fmtClock(c.end))",
                      tail: "距下课",
                      cd: mixCD(c.end.timeIntervalSince(now)),
                      target: c.end)
        }
        guard let n = Schedule.upcoming(now, 1).first else { return nil }
        let sameDay = Calendar.current.isDate(n.start, inSameDayAs: now)
        let day = Schedule.dayName(n.start, now: now)
        return Up(slot: n, inClass: false,
                  head: sameDay ? "下一节" : day,
                  when: "\(n.pLabel) \(fmtClock(n.start))–\(fmtClock(n.end))",
                  tail: sameDay ? "距上课" : "距\(day)上课",
                  cd: mixCD(n.start.timeIntervalSince(now)),
                  target: n.start)
    }

    /// 接下来 n 节（不含正在上的那节），压成一行："P7 物 14:45 · P8 生 15:40"
    /// 不在今天的话前面补上「周一」这种标记，免得看不出是隔天。
    static func nextLine(_ now: Date, _ n: Int = 2) -> String? {
        let list = Array(Schedule.upcoming(now, n + 1).filter { $0.start > now }.prefix(n))
        guard let first = list.first else { return nil }
        let sameDay = Calendar.current.isDate(first.start, inSameDayAs: now)
        let head = sameDay ? "" : Schedule.dayName(first.start, now: now) + " "
        return head + list.map { "\($0.pLabel) \(Subject.short($0.subject)) \(fmtClock($0.start))" }
                           .joined(separator: " · ")
    }
}

/* ============================================================
   综合小组件里复用的一行
   ============================================================ */

/// 第一行：课 + 倒计时（图标区分正在上 / 下一节）
struct MBUpLine: View {
    let up: MBMix.Up
    let now: Date
    let scheme: ColorScheme
    var big: Bool = false
    /// 窄版面（矩形 / 圆形 / 行内）默认用科目短名：
    /// "AP 初级微积分" → "初级微积分"。矩形一行只有 164pt，留着 "AP " 只会把名字挤成 "微…"
    var shortName: Bool = true

    var body: some View {
        let c = RGB(up.slot.hex).color(scheme, lift: 0.16)
        HStack(spacing: 5) {
            Image(systemName: up.inClass ? "play.circle.fill" : "arrow.right.circle.fill")
                .font(.system(size: big ? 11.5 : 10.5, weight: .semibold))
                .foregroundStyle(c)
            Text(shortName ? up.shortSubject : up.slot.subject)
                .font(.system(size: big ? 12.5 : 11.5, weight: .bold))
                .foregroundStyle(c)
                .lineLimit(1)
                .minimumScaleFactor(0.85)
            Spacer(minLength: 3)
            Text(up.tail)
                .font(.system(size: 9.5))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .fixedSize()
            // 系统自己走秒，不用等下一次时间线刷新
            MBCountdown(target: up.target, now: now, size: big ? 15 : 13)
                .fixedSize()
        }
    }
}

/// 最新成绩一行（色点 + 科目 + 作业名 + 分数 + 等级）
struct MBScoreLine: View {
    let r: RecentVM
    let scheme: ColorScheme

    var body: some View {
        let c = r.rgb.color(scheme, lift: 0.16)
        let gc = r.good ? Theme.green.color(scheme, lift: 0.10) : Theme.amber.color(scheme, lift: 0.10)
        HStack(spacing: 5) {
            MBDot(color: c, size: 7)
            Text(r.label)
                .font(.system(size: 11, weight: .semibold))
                .lineLimit(1)
                .fixedSize()
            Text(r.title)
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer(minLength: 2)
            if !r.scoreText.isEmpty {
                Text(r.scoreText)
                    .font(.system(size: 10))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .fixedSize()
            }
            Text(r.grade ?? "—")
                .font(.system(size: 11.5, weight: .bold))
                .foregroundStyle(gc)
                .lineLimit(1)
                .fixedSize()
        }
    }
}

/// 「数据没连上」的统一说法（课表是本地的，不受影响）
struct MBOfflineLine: View {
    var what: String = "待办与成绩"
    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "wifi.slash").font(.system(size: 9, weight: .semibold))
            Text("\(what) 未连上电脑上的看板服务")
                .font(.system(size: 10))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            Spacer(minLength: 0)
        }
        .foregroundStyle(.secondary)
    }
}

/* ============================================================
   9. 学习总览：课 + 倒计时 ｜ 最急待办 ｜ 最新成绩
   —— 一屏看全「接下来上什么 / 最急交什么 / 最近考得怎样」
   ============================================================ */
struct MBMixView: View {
    let e: MBEntry
    @Environment(\.mbFamily) private var family
    @Environment(\.colorScheme) private var scheme

    private var up: MBMix.Up? { MBMix.up(e.date) }
    private var todo: TaskVM? { Derive.groups(e.payload, now: e.date).up.first }
    private var score: RecentVM? { Derive.recentWorks(e.payload, 1).first }

    var body: some View {
        switch family {
        case .circular:
            let u = up
            let t = todo
            MBCircleBox {
                if let u {
                    MBCountdown(target: u.target, now: e.date, size: 15)
                        .minimumScaleFactor(0.45)
                    Text(u.tail).font(.system(size: 9)).foregroundStyle(.secondary)
                        .lineLimit(1).minimumScaleFactor(0.7)
                } else {
                    Image(systemName: "calendar.badge.minus").font(.system(size: 14))
                    Text("今天没课").font(.system(size: 9)).foregroundStyle(.secondary)
                        .lineLimit(1).minimumScaleFactor(0.7)
                }
                Text(circleTail(t))
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(circleTint(t))
                    .lineLimit(1).minimumScaleFactor(0.6)
            }
        case .corner:
            #if os(watchOS)
            Text(up?.cd ?? "—")
                .font(.system(size: 13, weight: .bold, design: .rounded))
                .monospacedDigit()
                .widgetLabel { Text(cornerTail) }
            #else
            Text(up?.cd ?? "—")
                .font(.system(size: 13, weight: .bold, design: .rounded))
                .monospacedDigit()
            #endif
        case .inline:
            Text(inline)
        default:
            VStack(alignment: .leading, spacing: 3) {
                if let u = up {
                    MBUpLine(up: u, now: e.date, scheme: scheme)
                } else {
                    Text("今天没有课了").font(.system(size: 11)).foregroundStyle(.secondary)
                }
                if e.failed {
                    MBOfflineLine()
                } else if let t = todo {
                    MBTaskLine(t: t, now: e.date, scheme: scheme)
                } else {
                    Text("暂无待办").font(.system(size: 10.5)).foregroundStyle(.secondary)
                }
                if e.failed {
                    Text("—").font(.system(size: 10.5)).foregroundStyle(.tertiary)
                } else if let s = score {
                    MBScoreLine(r: s, scheme: scheme)
                } else {
                    Text("暂无已评分作业").font(.system(size: 10.5)).foregroundStyle(.secondary)
                }
            }
        }
    }

    /// 圆形的第三行：待办 + 最新等级（都很短，塞得进圆里）
    private func circleTail(_ t: TaskVM?) -> String {
        if e.failed { return "未连上" }
        var parts: [String] = []
        if let t { parts.append("待办 " + shortLeft(t, now: e.date)) } else { parts.append("无待办") }
        if let g = score?.grade { parts.append(g) }
        return parts.joined(separator: " · ")
    }

    private func circleTint(_ t: TaskVM?) -> Color {
        if e.failed { return .secondary }
        if let t { return t.band.color(scheme) }
        return Theme.green.color(scheme, lift: 0.10)
    }

    private var cornerTail: String {
        var parts: [String] = []
        if let u = up { parts.append(u.shortSubject) }
        parts.append(e.failed ? "待办 —" : "待办 \(todo == nil ? 0 : 1)")
        if let g = score?.grade { parts.append(g) }
        return parts.joined(separator: " · ")
    }

    private var inline: String {
        var parts: [String] = []
        if let u = up { parts.append("\(u.tail) \(u.cd) \(u.shortSubject)") }
        else { parts.append("今天没课了") }
        if e.failed {
            parts.append("待办 —")
        } else if let t = todo {
            parts.append("待办 \(t.subject) \(shortLeft(t, now: e.date))")
        }
        if let s = score, let g = s.grade { parts.append("\(s.label) \(g)") }
        return parts.joined(separator: " · ")
    }
}

/* ============================================================
   10. 课堂速览：倒计时大字 ｜ 接下来两节 ｜ 最急待办
   ============================================================ */
struct MBClassFocusView: View {
    let e: MBEntry
    @Environment(\.mbFamily) private var family
    @Environment(\.colorScheme) private var scheme

    private var up: MBMix.Up? { MBMix.up(e.date) }
    private var todo: TaskVM? { Derive.groups(e.payload, now: e.date).up.first }

    var body: some View {
        switch family {
        case .circular:
            MBCircleBox {
                if let u = up {
                    MBCountdown(target: u.target, now: e.date, size: 14)
                        .minimumScaleFactor(0.45)
                    Text(u.shortSubject)
                        .font(.system(size: 9.5, weight: .semibold))
                        .foregroundStyle(RGB(u.slot.hex).color(scheme, lift: 0.16))
                        .lineLimit(1).minimumScaleFactor(0.5)
                    Text(u.tail).font(.system(size: 9)).foregroundStyle(.secondary)
                        .lineLimit(1).minimumScaleFactor(0.7)
                } else {
                    Image(systemName: "calendar.badge.minus").font(.system(size: 14))
                    Text("今天没课").font(.system(size: 9)).foregroundStyle(.secondary)
                }
            }
        case .inline:
            if let u = up {
                Text("\(u.head) \(u.shortSubject) \(u.tail) \(u.cd)")
            } else {
                Text("今天没有课了")
            }
        default:
            VStack(alignment: .leading, spacing: 3) {
                if let u = up {
                    // 用常规字号：big 会把科目名挤成「微…」，矩形里不值得
                    MBUpLine(up: u, now: e.date, scheme: scheme)
                } else {
                    Text("今天没有课了").font(.system(size: 11)).foregroundStyle(.secondary)
                }
                if let line = MBMix.nextLine(e.date, 2) {
                    HStack(spacing: 4) {
                        Image(systemName: "calendar").font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(.secondary)
                        Text(line)
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .minimumScaleFactor(0.75)
                        Spacer(minLength: 0)
                    }
                }
                if e.failed {
                    MBOfflineLine(what: "待办")
                } else if let t = todo {
                    MBTaskLine(t: t, now: e.date, scheme: scheme)
                } else {
                    Text("暂无待办").font(.system(size: 10.5)).foregroundStyle(.secondary)
                }
            }
        }
    }
}

/* ============================================================
   11. 成绩速览：最新成绩两条 ｜ 距下课 + 待办数
   ============================================================ */
struct MBGradeMixView: View {
    let e: MBEntry
    @Environment(\.mbFamily) private var family
    @Environment(\.colorScheme) private var scheme

    private var rows: [RecentVM] { Derive.recentWorks(e.payload, 2) }
    private var up: MBMix.Up? { MBMix.up(e.date) }
    private var upCount: Int { Derive.groups(e.payload, now: e.date).up.count }

    var body: some View {
        switch family {
        case .circular:
            if let r = rows.first {
                MBCircleBox {
                    Text(r.grade ?? "—")
                        .font(.system(size: 19, weight: .bold, design: .rounded))
                        .foregroundStyle(r.good ? Theme.green.color(scheme, lift: 0.10)
                                                : Theme.amber.color(scheme, lift: 0.10))
                        .lineLimit(1).minimumScaleFactor(0.5)
                    Text(r.label)
                        .font(.system(size: 9.5)).foregroundStyle(.secondary)
                        .lineLimit(1)
                    if let u = up {
                        HStack(spacing: 2) {
                            Text(u.tail).font(.system(size: 9)).foregroundStyle(.secondary)
                            MBCountdown(target: u.target, now: e.date, size: 9.5).lineLimit(1)
                        }
                        .minimumScaleFactor(0.6)
                    } else {
                        Text("待办 \(upCount)")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
            } else {
                MBEmpty(text: "暂无成绩", icon: "chart.bar")
            }
        case .inline:
            if let r = rows.first {
                Text("最新 \(r.label) \(r.grade ?? "") \(r.scoreText) · 待办 \(upCount) 项")
            } else {
                Text("暂无最新成绩")
            }
        default:
            VStack(alignment: .leading, spacing: 3) {
                if e.failed {
                    MBOfflineLine(what: "成绩")
                } else if rows.isEmpty {
                    MBEmpty(text: "暂无已评分作业", icon: "chart.bar")
                } else {
                    ForEach(rows) { r in MBScoreLine(r: r, scheme: scheme) }
                }
                footer
            }
        }
    }

    /// 底部一行：距下课 / 距上课 + 待办数
    private var footer: some View {
        HStack(spacing: 5) {
            Image(systemName: "timer").font(.system(size: 9.5, weight: .semibold))
                .foregroundStyle(.secondary)
            if let u = up {
                HStack(spacing: 3) {
                    Text(u.tail).font(.system(size: 10)).foregroundStyle(.secondary)
                    MBCountdown(target: u.target, now: e.date, size: 10.5)
                }
                .foregroundStyle(RGB(u.slot.hex).color(scheme, lift: 0.16))
                .fixedSize()
            } else {
                Text("今天没有课了").font(.system(size: 10.5)).foregroundStyle(.secondary)
            }
            Spacer(minLength: 2)
            Text(e.failed ? "待办 —" : "待办 \(upCount) 项")
                .font(.system(size: 10.5, weight: .semibold))
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .fixedSize()
        }
    }
}

/* ============================================================
   12. 紧迫速览：倒计时 ｜ 最急待办 ｜ 红黄蓝计数 + 最新等级
   ============================================================ */
struct MBUrgentMixView: View {
    let e: MBEntry
    @Environment(\.mbFamily) private var family
    @Environment(\.colorScheme) private var scheme

    private var up: MBMix.Up? { MBMix.up(e.date) }
    private var groups: (up: [TaskVM], od: [TaskVM]) { Derive.groups(e.payload, now: e.date) }
    private var score: RecentVM? { Derive.recentWorks(e.payload, 1).first }

    private var counts: [(name: String, n: Int, color: Color, dark: Bool)] {
        let c = Derive.bandCounts(e.payload, now: e.date)
        return [
            ("红", c.red, Theme.red.color(scheme, lift: 0.16), false),
            ("黄", c.yellow, Theme.amber.color(scheme, lift: 0.10), true),
            ("蓝", c.blue, Theme.blue.color(scheme, lift: 0.16), false),
        ].filter { $0.1 > 0 }.map { (name: $0.0, n: $0.1, color: $0.2, dark: $0.3) }
    }

    var body: some View {
        switch family {
        case .circular:
            let list = counts
            MBCircleBox {
                if let u = up {
                    MBCountdown(target: u.target, now: e.date, size: 14)
                        .minimumScaleFactor(0.45)
                    Text(u.tail).font(.system(size: 9)).foregroundStyle(.secondary)
                        .lineLimit(1).minimumScaleFactor(0.7)
                } else {
                    Image(systemName: "moon.zzz.fill").font(.system(size: 14))
                }
                if list.isEmpty {
                    Text("无红黄蓝").font(.system(size: 9)).foregroundStyle(.secondary)
                        .lineLimit(1).minimumScaleFactor(0.7)
                } else {
                    HStack(spacing: 2) {
                        ForEach(list, id: \.name) { it in
                            MBBadge(n: it.n, color: it.color, darkText: it.dark, size: 15)
                        }
                    }
                }
            }
        case .corner:
            #if os(watchOS)
            Text(up?.cd ?? "—")
                .font(.system(size: 13, weight: .bold, design: .rounded))
                .monospacedDigit()
                .widgetLabel { Text(cornerTail) }
            #else
            Text(up?.cd ?? "—")
                .font(.system(size: 13, weight: .bold, design: .rounded))
                .monospacedDigit()
            #endif
        case .inline:
            Text(inline)
        default:
            VStack(alignment: .leading, spacing: 3) {
                if let u = up {
                    MBUpLine(up: u, now: e.date, scheme: scheme)
                } else {
                    Text("今天没有课了").font(.system(size: 11)).foregroundStyle(.secondary)
                }
                if e.failed {
                    MBOfflineLine(what: "待办")
                } else if let t = groups.up.first {
                    MBTaskLine(t: t, now: e.date, scheme: scheme)
                } else {
                    Text("暂无待办").font(.system(size: 10.5)).foregroundStyle(.secondary)
                }
                HStack(spacing: 6) {
                    ForEach(counts, id: \.name) { it in
                        HStack(spacing: 3) {
                            MBDot(color: it.color, size: 7)
                            Text("\(it.n)")
                                .font(.system(size: 10.5, weight: .bold))
                                .monospacedDigit()
                                .foregroundStyle(it.color)
                        }
                    }
                    if counts.isEmpty {
                        Text("74 小时内无到期待办")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 2)
                    if let s = score, let g = s.grade {
                        Text("\(s.label) \(g)")
                            .font(.system(size: 10.5, weight: .bold))
                            .foregroundStyle(s.good ? Theme.green.color(scheme, lift: 0.10)
                                                    : Theme.amber.color(scheme, lift: 0.10))
                            .lineLimit(1)
                            .fixedSize()
                    }
                }
            }
        }
    }

    private var cornerTail: String {
        let list = counts
        var parts: [String] = []
        if let u = up { parts.append(u.shortSubject) }
        if list.isEmpty { parts.append("无红黄蓝") }
        else { parts.append(list.map { "\($0.name)\($0.n)" }.joined(separator: " ")) }
        if let g = score?.grade { parts.append(g) }
        return parts.joined(separator: " · ")
    }

    private var inline: String {
        var parts: [String] = []
        if let u = up { parts.append("\(u.tail) \(u.cd)") }
        let list = counts
        parts.append(list.isEmpty ? "无红黄蓝" : list.map { "\($0.name)\($0.n)" }.joined(separator: " "))
        if let g = score?.grade { parts.append("最新 \(g)") }
        return parts.joined(separator: " · ")
    }
}
