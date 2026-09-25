//  MBWidgetViews.swift
//  ManageBac 小组件 —— 8 组界面（每组都按表盘给出的 family 自适应）
//
//  配色 / 分档 / 课表规则全部来自同步文件（WidgetRules / WidgetTheme / WidgetDerive），
//  与手表 App、菜单栏 App、网页看板是同一套口径。

import SwiftUI
import WidgetKit

/* ============================================================
   形态（family）

   MBFamily 的定义在 MBFamily.swift 里（跨平台枚举，见那里的注释）。
   这里只放「把系统给的真实 widgetFamily 翻译成 MBFamily 注入下去」的包装。
   ============================================================ */

/// 把系统给的真实 widgetFamily 翻译成 MBFamily 注入给内容视图
struct MBFamilyInjector<Content: View>: View {
    @Environment(\.widgetFamily) private var wf
    let content: Content
    var body: some View {
        content.environment(\.mbFamily, MBFamily(wf))
    }
}

/* ============================================================
   公共小件
   ============================================================ */

/// 小圆点
struct MBDot: View {
    let color: Color
    var size: CGFloat = 6
    var body: some View {
        Circle().fill(color).frame(width: size, height: size)
    }
}

/// 圆形里的「色点 + 数量」（菜单栏角标同款语言）
struct MBBadge: View {
    let n: Int
    let color: Color
    var darkText: Bool = false
    var size: CGFloat = 18
    var body: some View {
        ZStack {
            Circle().fill(color)
            Text("\(n)")
                .font(.system(size: size * 0.62, weight: .bold))
                .monospacedDigit()
                .foregroundStyle(darkText ? Color.black.opacity(0.82) : .white)
        }
        .frame(width: size, height: size)
    }
}

/// 没取到数 / 空列表
struct MBEmpty: View {
    let text: String
    let icon: String
    var body: some View {
        VStack(spacing: 3) {
            Image(systemName: icon).font(.system(size: 13, weight: .semibold))
            Text(text).font(.system(size: 10.5)).multilineTextAlignment(.center)
        }
        .foregroundStyle(.secondary)
    }
}

/// 小标题行
struct MBHead: View {
    let icon: String
    let title: String
    var trailing: String?
    var tint: Color = .secondary
    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: icon).font(.system(size: 9.5, weight: .semibold))
            Text(title).font(.system(size: 10.5, weight: .semibold))
            Spacer(minLength: 2)
            if let trailing, !trailing.isEmpty {
                Text(trailing).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .foregroundStyle(tint)
    }
}

/// 一行待办（色条 + 科目 + 作业名 + 剩余时间）
struct MBTaskLine: View {
    let t: TaskVM
    let now: Date
    let scheme: ColorScheme
    var showTitle: Bool = true
    var body: some View {
        HStack(spacing: 5) {
            RoundedRectangle(cornerRadius: 1.5)
                .fill(t.band.color(scheme))
                .frame(width: 3, height: 11)
            Text(t.subject)
                .font(.system(size: 11, weight: .semibold))
                .lineLimit(1)
                .fixedSize()
            if showTitle {
                Text(t.title)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 2)
            Text(shortLeft(t, now: now))
                .font(.system(size: 10.5, weight: .semibold))
                .monospacedDigit()
                .foregroundStyle(t.band.color(scheme))
                .lineLimit(1)
                .fixedSize()
        }
    }
}

/// 一行课程（节次 + 起点 + 课名，进行中会高亮）
struct MBClassLine: View {
    let s: Schedule.Slot
    let isNow: Bool
    let scheme: ColorScheme
    var showTime: Bool = true
    var body: some View {
        let c = RGB(s.hex).color(scheme, lift: 0.16)
        HStack(spacing: 5) {
            RoundedRectangle(cornerRadius: 1.5)
                .fill(isNow ? c : (s.isFree ? Color.secondary.opacity(0.35) : c.opacity(0.75)))
                .frame(width: isNow ? 3.5 : 3, height: isNow ? 12 : 11)
            Text(s.span[1] > s.span[0] ? "P\(s.span[0])–\(s.span[1])" : s.pLabel)
                .font(.system(size: 10, weight: .semibold))
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .fixedSize()
            if showTime {
                Text(fmtClock(s.start))
                    .font(.system(size: 10))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .fixedSize()
            }
            Text(s.subject)
                .font(.system(size: 11, weight: isNow ? .bold : .medium))
                .foregroundStyle(isNow ? c : .primary)
                .lineLimit(1)
            Spacer(minLength: 2)
            if isNow {
                Text("进行中")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(c)
                    .fixedSize()
            } else if !s.room.isEmpty {
                Text(s.room).font(.system(size: 9.5)).foregroundStyle(.secondary).lineLimit(1).fixedSize()
            }
        }
    }
}

/* ============================================================
   1. 待办清单
   ============================================================ */

struct MBTodoView: View {
    let e: MBEntry
    @Environment(\.mbFamily) private var family
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let g = Derive.groups(e.payload, now: e.date)
        switch family {
        case .circular:
            VStack(spacing: 1) {
                if let t = g.up.first {
                    Text(t.subject).font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(t.band.color(scheme)).lineLimit(1).fixedSize()
                    Text(shortLeft(t, now: e.date))
                        .font(.system(size: 14, weight: .bold, design: .rounded))
                        .monospacedDigit().lineLimit(1).minimumScaleFactor(0.5)
                    Text("共 \(g.up.count) 项").font(.system(size: 9)).foregroundStyle(.secondary)
                } else if !g.od.isEmpty {
                    Text("逾期").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                    Text("\(g.od.count)").font(.system(size: 18, weight: .bold, design: .rounded))
                    Text("项").font(.system(size: 9)).foregroundStyle(.secondary)
                } else {
                    MBEmpty(text: "无待办", icon: "checkmark.circle")
                }
            }
        case .inline:
            Text(inlineText(g))
        default:
            VStack(alignment: .leading, spacing: 2) {
                MBHead(icon: "checklist", title: "待办 \(g.up.count) 项",
                       trailing: g.od.isEmpty ? nil : "逾期 \(g.od.count)")
                if e.failed {
                    MBEmpty(text: "连不上电脑上的看板服务", icon: "wifi.slash")
                } else if g.up.isEmpty {
                    MBEmpty(text: g.od.isEmpty ? "暂无待办" : "只剩逾期的 \(g.od.count) 项", icon: "checkmark.circle")
                } else {
                    ForEach(g.up.prefix(3)) { t in
                        MBTaskLine(t: t, now: e.date, scheme: scheme)
                    }
                }
            }
        }
    }

    private func inlineText(_ g: (up: [TaskVM], od: [TaskVM])) -> String {
        guard let t = g.up.first else {
            return g.od.isEmpty ? "暂无待办" : "待办：\(g.od.count) 项已逾期"
        }
        return "待办 \(g.up.count) 项 · \(t.subject) \(shortLeft(t, now: e.date))"
    }
}

/* ============================================================
   2. 待办紧急度（红 / 黄 / 蓝）
   ============================================================ */

struct MBBandCountView: View {
    let e: MBEntry
    @Environment(\.mbFamily) private var family
    @Environment(\.colorScheme) private var scheme

    private func items() -> [(name: String, n: Int, color: Color, dark: Bool)] {
        let c = Derive.bandCounts(e.payload, now: e.date)
        return [
            ("红", c.red, Theme.red.color(scheme, lift: 0.16), false),
            ("黄", c.yellow, Theme.amber.color(scheme, lift: 0.10), true),
            ("蓝", c.blue, Theme.blue.color(scheme, lift: 0.16), false),
        ].filter { $0.1 > 0 }.map { (name: $0.0, n: $0.1, color: $0.2, dark: $0.3) }
    }

    var body: some View {
        let list = items()
        switch family {
        case .circular:
            VStack(spacing: 3) {
                if list.isEmpty {
                    MBEmpty(text: "无紧急", icon: "checkmark.circle")
                } else {
                    HStack(spacing: 3) {
                        ForEach(list, id: \.name) { it in
                            MBBadge(n: it.n, color: it.color, darkText: it.dark, size: 19)
                        }
                    }
                    Text("待办").font(.system(size: 9)).foregroundStyle(.secondary)
                }
            }
        case .inline:
            Text(list.isEmpty ? "暂无红黄蓝待办"
                              : list.map { "\($0.name) \($0.n)" }.joined(separator: " · "))
        default:
            VStack(alignment: .leading, spacing: 0) {
                MBHead(icon: "circle.grid.3x3.fill", title: "紧急度")
                Spacer(minLength: 2)
                if list.isEmpty {
                    MBEmpty(text: "没有 74 小时内的待办", icon: "checkmark.circle")
                    Spacer(minLength: 0)
                } else {
                    HStack(spacing: 8) {
                        ForEach(list, id: \.name) { it in
                            HStack(spacing: 4) {
                                MBDot(color: it.color, size: 8)
                                Text(it.name).font(.system(size: 10.5)).foregroundStyle(.secondary)
                                Text("\(it.n)")
                                    .font(.system(size: 17, weight: .bold, design: .rounded))
                                    .monospacedDigit()
                                    .foregroundStyle(it.color)
                            }
                        }
                        Spacer(minLength: 0)
                    }
                }
            }
        }
    }
}

/* ============================================================
   3. 课堂倒计时
   ============================================================ */

struct MBCountdownView: View {
    let e: MBEntry
    @Environment(\.mbFamily) private var family
    @Environment(\.colorScheme) private var scheme

    private var timer: Schedule.TopTimer { Schedule.topTimer(e.date) }

    private var target: Date? {
        switch timer {
        case .inClass(let s):                 return s.end
        case .breakTime(let n, _):            return n.start
        case .studyEnd(let d), .studyStart(let d): return d
        case .rest:                           return nil
        }
    }

    private var shortLabel: String {
        switch timer {
        case .inClass:     return "下课"
        case .breakTime:   return "上课"
        case .studyEnd:    return "晚自习结束"
        case .studyStart:  return "晚自习开始"
        case .rest:        return "休息"
        }
    }

    /// 行内（表盘一行文字）用的更短的说法
    private var inlineLabel: String {
        switch timer {
        case .inClass:     return "距下课"
        case .breakTime:   return "距上课"
        case .studyEnd:    return "距晚自习结束"
        case .studyStart:  return "距晚自习开始"
        case .rest:        return "休息中"
        }
    }

    private var detail: String {
        switch timer {
        case .inClass(let s), .breakTime(let s, _):
            return s.room.isEmpty ? s.subject : "\(s.subject) · \(s.room)"
        case .studyEnd, .studyStart:
            return "晚自习"
        case .rest:
            return "22:30–06:00"
        }
    }

    private var cd: String? {
        guard let t = target else { return nil }
        return shortCountdown(t.timeIntervalSince(e.date))
    }

    /// 会自己走秒的倒计时（没有目标时刻就是休息中）
    @ViewBuilder
    private var live: some View {
        if let t = target {
            MBCountdown(target: t, now: e.date, size: 13).minimumScaleFactor(0.5)
        } else {
            Text("休息").font(.system(size: 13, weight: .bold, design: .rounded))
        }
    }

    var body: some View {
        switch family {
        case .circular:
            VStack(spacing: 1) {
                if target != nil {
                    MBCountdown(target: target!, now: e.date, size: 15).minimumScaleFactor(0.45)
                    Text(shortLabel).font(.system(size: 9.5, weight: .semibold)).foregroundStyle(.secondary)
                } else {
                    Image(systemName: "moon.zzz.fill").font(.system(size: 16))
                    Text("休息").font(.system(size: 10)).foregroundStyle(.secondary)
                }
            }
        case .corner:
            // widgetLabel 是 watchOS 专有 API（表盘角标要文字标签）；自检工具在 macOS 上渲染，走降级分支
            #if os(watchOS)
            live.widgetLabel { Text("\(shortLabel) · \(detail)") }
            #else
            live
            #endif
        case .inline:
            Text(cd.map { "\(inlineLabel) \($0)" } ?? inlineLabel)
        default:
            VStack(alignment: .leading, spacing: 1) {
                MBHead(icon: "timer", title: timer.label)
                if let t = target {
                    MBCountdown(target: t, now: e.date, size: 26).minimumScaleFactor(0.5)
                    Text(detail).font(.system(size: 10.5)).foregroundStyle(.secondary).lineLimit(1)
                } else {
                    Spacer(minLength: 0)
                    MBEmpty(text: "现在是休息时间", icon: "moon.zzz.fill")
                    Spacer(minLength: 0)
                }
            }
        }
    }
}

/* ============================================================
   4. 今日课表
   ============================================================ */

struct MBScheduleView: View {
    let e: MBEntry
    @Environment(\.mbFamily) private var family
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let dl = Schedule.dayList(e.date)
        let cur = Schedule.currentSlot(e.date)?.blockId
        switch family {
        case .circular:
            let done = dl.list.filter { $0.end <= e.date }.count
            VStack(spacing: 0) {
                Text("\(min(done + 1, dl.list.count))/\(dl.list.count)")
                    .font(.system(size: 16, weight: .bold, design: .rounded))
                    .monospacedDigit().lineLimit(1).minimumScaleFactor(0.5)
                Text("节").font(.system(size: 9)).foregroundStyle(.secondary)
                if let nxt = dl.list.first(where: { $0.start > e.date }) ?? dl.list.first {
                    Text(nxt.subject).font(.system(size: 9)).foregroundStyle(.secondary)
                        .lineLimit(1).minimumScaleFactor(0.7)
                }
            }
        case .inline:
            if let nxt = dl.list.first(where: { $0.start > e.date }) {
                Text("\(Schedule.dayName(dl.day, now: e.date)) \(fmtClock(nxt.start)) \(nxt.subject)")
            } else {
                Text("\(Schedule.dayName(dl.day, now: e.date))共 \(dl.list.count) 节课")
            }
        default:
            VStack(alignment: .leading, spacing: 2) {
                MBHead(icon: "calendar", title: Schedule.dayName(dl.day, now: e.date),
                       trailing: dayShort(dl.day))
                if dl.list.isEmpty {
                    MBEmpty(text: "这天没有课", icon: "calendar.badge.minus")
                } else {
                    // 课表是本地内置数据，服务没开也照样能显示
                    let shown = pick(dl.list, now: e.date)
                    ForEach(shown) { s in
                        MBClassLine(s: s, isNow: cur != nil && s.blockId == cur, scheme: scheme)
                    }
                }
            }
        }
    }

    /// 优先显示「正在上的 + 接下来两节」，其余情况从头显示三节
    private func pick(_ list: [Schedule.Slot], now: Date) -> [Schedule.Slot] {
        if let i = list.firstIndex(where: { $0.end > now }) {
            return Array(list[i ..< min(i + 3, list.count)])
        }
        return Array(list.prefix(3))
    }
}

/* ============================================================
   5. 最新成绩
   ============================================================ */

struct MBScoreView: View {
    let e: MBEntry
    @Environment(\.mbFamily) private var family
    @Environment(\.colorScheme) private var scheme

    private var rows: [RecentVM] { Derive.recentWorks(e.payload, 3) }

    private func gradeColor(_ r: RecentVM) -> Color {
        r.good ? Theme.green.color(scheme, lift: 0.10) : Theme.amber.color(scheme, lift: 0.10)
    }

    var body: some View {
        let list = rows
        switch family {
        case .circular:
            if let r = list.first {
                VStack(spacing: 0) {
                    Text(r.grade ?? "—")
                        .font(.system(size: 20, weight: .bold, design: .rounded))
                        .foregroundStyle(gradeColor(r))
                        .lineLimit(1).minimumScaleFactor(0.5)
                    Text(r.scoreText).font(.system(size: 9.5)).monospacedDigit()
                        .foregroundStyle(.secondary).lineLimit(1).minimumScaleFactor(0.6)
                    Text(r.label).font(.system(size: 9)).foregroundStyle(.secondary).lineLimit(1)
                }
            } else {
                MBEmpty(text: "暂无成绩", icon: "chart.bar")
            }
        case .inline:
            if let r = list.first {
                Text("最新成绩 \(r.label) \(r.grade ?? "") \(r.scoreText)")
            } else {
                Text("暂无最新成绩")
            }
        default:
            VStack(alignment: .leading, spacing: 3) {
                MBHead(icon: "chart.bar.fill", title: "最新成绩",
                       trailing: list.first.map { $0.dueText })
                if e.failed {
                    MBEmpty(text: "连不上电脑上的看板服务", icon: "wifi.slash")
                } else if list.isEmpty {
                    MBEmpty(text: "暂无已评分作业", icon: "chart.bar")
                } else {
                    ForEach(list.prefix(2)) { r in
                        HStack(spacing: 5) {
                            MBDot(color: r.rgb.color(scheme, lift: 0.16), size: 7)
                            Text(r.label).font(.system(size: 11, weight: .semibold)).lineLimit(1).fixedSize()
                            Text(r.title).font(.system(size: 10.5)).foregroundStyle(.secondary).lineLimit(1)
                            Spacer(minLength: 2)
                            Text(r.scoreText).font(.system(size: 10)).monospacedDigit()
                                .foregroundStyle(.secondary).lineLimit(1).fixedSize()
                            Text(r.grade ?? "—")
                                .font(.system(size: 11.5, weight: .bold))
                                .foregroundStyle(gradeColor(r))
                                .lineLimit(1).fixedSize()
                        }
                    }
                }
            }
        }
    }
}

/* ============================================================
   6. GPA
   ============================================================ */

struct MBGPAView: View {
    let e: MBEntry
    @Environment(\.mbFamily) private var family
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let s = Derive.gpaSummary(e.payload)
        let avg = s.avg
        switch family {
        case .circular:
            VStack(spacing: 0) {
                Text(avg.map { fmtPct($0) } ?? "—")
                    .font(.system(size: 15, weight: .bold, design: .rounded))
                    .monospacedDigit().lineLimit(1).minimumScaleFactor(0.4)
                if let a = avg {
                    Text(to4(a / 100) + "/4.0").font(.system(size: 9.5)).monospacedDigit().foregroundStyle(.secondary)
                } else {
                    Text("未出分").font(.system(size: 9.5)).foregroundStyle(.secondary)
                }
            }
        case .corner:
            #if os(watchOS)
            Text(avg.map { to4($0 / 100) } ?? "—")
                .font(.system(size: 13, weight: .bold, design: .rounded))
                .monospacedDigit()
                .widgetLabel {
                    Text(avg.map { fmtPct($0) } ?? "GPA 未出分")
                }
            #else
            Text(avg.map { to4($0 / 100) } ?? "—")
                .font(.system(size: 13, weight: .bold, design: .rounded))
                .monospacedDigit()
            #endif
        case .inline:
            Text(avg.map { "均分 \(fmtPct($0)) · \(to4($0 / 100))/4.0" } ?? "暂无 GPA")
        default:
            VStack(alignment: .leading, spacing: 2) {
                MBHead(icon: "graduationcap.fill", title: "总均分",
                       trailing: "\(s.graded)/\(s.total) 门")
                Spacer(minLength: 0)
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(avg.map { fmtPct($0) } ?? "—")
                        .font(.system(size: 24, weight: .bold, design: .rounded))
                        .monospacedDigit().lineLimit(1).minimumScaleFactor(0.5)
                    if let a = avg {
                        Text(to4(a / 100) + "/4.0")
                            .font(.system(size: 12, weight: .semibold))
                            .monospacedDigit()
                            .foregroundStyle(Theme.blue.color(scheme, lift: 0.16))
                    }
                }
                Spacer(minLength: 0)
                if e.failed {
                    Text("连不上电脑上的看板服务").font(.system(size: 9.5)).foregroundStyle(.secondary)
                } else if s.graded == 0 {
                    Text("还没有出分的科目").font(.system(size: 9.5)).foregroundStyle(.secondary)
                } else {
                    Text("按各科 Overall 百分比平均 · 4 分制为线性折算")
                        .font(.system(size: 9)).foregroundStyle(.secondary).lineLimit(1)
                }
            }
        }
    }
}

/* ============================================================
   7. 今日概览
   ============================================================ */

struct MBDayView: View {
    let e: MBEntry
    @Environment(\.mbFamily) private var family
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let dl = Schedule.dayList(e.date)
        let g = Derive.groups(e.payload, now: e.date)
        let cur = Schedule.currentSlot(e.date)
        let nxt = dl.list.first { $0.start > e.date }

        switch family {
        case .circular:
            VStack(spacing: 0) {
                Text("\(dl.list.count)")
                    .font(.system(size: 18, weight: .bold, design: .rounded))
                    .monospacedDigit().lineLimit(1)
                Text("节课").font(.system(size: 9)).foregroundStyle(.secondary)
                Text("待办 \(g.up.count)").font(.system(size: 9)).foregroundStyle(.secondary)
            }
        case .inline:
            Text("\(Schedule.dayName(dl.day, now: e.date)) \(dl.list.count) 节课 · 待办 \(g.up.count) 项")
        default:
            VStack(alignment: .leading, spacing: 2) {
                MBHead(icon: "sun.max.fill", title: "\(Schedule.dayName(dl.day, now: e.date))概览",
                       trailing: e.failed ? "\(dl.list.count) 节课" : "\(dl.list.count) 节课 · 待办 \(g.up.count)")
                // 课表是本地内置数据，服务没开也照样显示；待办才依赖网络
                if let c = cur {
                    HStack(spacing: 5) {
                        MBDot(color: RGB(c.hex).color(scheme, lift: 0.16), size: 7)
                        Text("正在上").font(.system(size: 10.5)).foregroundStyle(.secondary)
                        // 窄行：用短科目名，别被倒计时挤成「AP 初级微…」
                        Text(Subject.short(c.subject)).font(.system(size: 11, weight: .bold)).lineLimit(1)
                        Spacer(minLength: 2)
                        MBCountdown(target: c.end, now: e.date, size: 10.5).fixedSize()
                    }
                } else if let n = nxt {
                    HStack(spacing: 5) {
                        MBDot(color: RGB(n.hex).color(scheme, lift: 0.16), size: 7)
                        Text("下一节").font(.system(size: 10.5)).foregroundStyle(.secondary)
                        Text(Subject.short(n.subject)).font(.system(size: 11, weight: .bold)).lineLimit(1)
                        Spacer(minLength: 2)
                        Text("\(fmtClock(n.start)) 开始")
                            .font(.system(size: 10.5)).monospacedDigit().foregroundStyle(.secondary).fixedSize()
                    }
                } else {
                    Text("今天没有课了").font(.system(size: 10.5)).foregroundStyle(.secondary)
                }
                if e.failed {
                    Text("待办数据未连上").font(.system(size: 10.5)).foregroundStyle(.secondary)
                } else if let t = g.up.first {
                    MBTaskLine(t: t, now: e.date, scheme: scheme)
                } else {
                    Text(g.od.isEmpty ? "暂无待办" : "逾期待办 \(g.od.count) 项")
                        .font(.system(size: 10.5)).foregroundStyle(.secondary)
                }
            }
        }
    }
}

/* ============================================================
   8. 下一节课
   ============================================================ */

struct MBNextClassView: View {
    let e: MBEntry
    @Environment(\.mbFamily) private var family
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let dl = Schedule.dayList(e.date)
        let cur = Schedule.currentSlot(e.date)
        let nxt = dl.list.first { $0.start > e.date } ?? Schedule.upcoming(e.date, 1).first

        switch family {
        case .circular:
            if let c = cur {
                VStack(spacing: 0) {
                    MBCountdown(target: c.end, now: e.date, size: 14).minimumScaleFactor(0.45)
                    Text("下课").font(.system(size: 9.5)).foregroundStyle(.secondary)
                }
            } else if let n = nxt {
                VStack(spacing: 0) {
                    MBCountdown(target: n.start, now: e.date, size: 14).minimumScaleFactor(0.45)
                    Text("上课").font(.system(size: 9.5)).foregroundStyle(.secondary)
                }
            } else {
                MBEmpty(text: "无课", icon: "calendar")
            }
        case .inline:
            if let c = cur {
                Text("\(c.subject) 距下课 \(shortCountdown(c.end.timeIntervalSince(e.date)))")
            } else if let n = nxt {
                Text("\(fmtClock(n.start)) \(n.subject)")
            } else {
                Text("今天没有课了")
            }
        default:
            VStack(alignment: .leading, spacing: 2) {
                // 标题行右侧的倒计时交给系统自己走秒（静态字符串会「冻」到下次刷新）
                HStack(spacing: 4) {
                    Image(systemName: cur != nil ? "play.circle.fill" : "arrow.right.circle.fill")
                        .font(.system(size: 9.5, weight: .semibold))
                    Text(cur != nil ? "正在上课" : "下一节课")
                        .font(.system(size: 10.5, weight: .semibold))
                    Spacer(minLength: 2)
                    if let t = cur?.end ?? nxt?.start {
                        MBCountdown(target: t, now: e.date, size: 10.5)
                    }
                }
                .foregroundStyle(.secondary)
                // 课表是本地内置数据，服务没开也能显示
                if let s = cur ?? nxt {
                    Text(s.subject)
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(RGB(s.hex).color(scheme, lift: 0.16))
                        .lineLimit(1).minimumScaleFactor(0.7)
                    HStack(spacing: 6) {
                        Text("\(fmtClock(s.start))–\(fmtClock(s.end))")
                            .font(.system(size: 10.5)).monospacedDigit().foregroundStyle(.secondary)
                        if !s.room.isEmpty {
                            Text(s.room).font(.system(size: 10.5)).foregroundStyle(.secondary)
                        }
                        if !s.teacher.isEmpty {
                            Text(s.teacher).font(.system(size: 10.5)).foregroundStyle(.secondary)
                        }
                    }
                    .lineLimit(1).minimumScaleFactor(0.8)
                } else {
                    MBEmpty(text: "今天没有课了", icon: "calendar.badge.minus")
                }
            }
        }
    }
}
