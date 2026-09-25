//  WatchRules.swift
//  ManageBac Watch App —— 课表 / 学科配色 / 紧急度分档 / 成绩折算
//  从菜单栏版 Rules.swift 原样移植（同一套算法，保证两端结果一致）。
//  新建文件，未修改菜单栏源码。

import Foundation
import SwiftUI

/* ============================================================
   学科：莫兰迪配色（与网页看板 app.html 完全同一套色）
   ============================================================ */
enum Subject {
    static let colors: [String: RGB] = [
        "chinese": RGB("#a96f6b"), "math": RGB("#867a9e"), "ela": RGB("#b58455"),
        "chem":    RGB("#6f7c9e"), "phys": RGB("#719070"), "bio": RGB("#5b918a"),
        "geo":     RGB("#74889c"), "ids":  RGB("#94836f"),
    ]

    /// 槽位识别正则，顺序与后端 scrape.js / 前端 app.html 一致
    private static let slots: [(String, String)] = [
        ("chinese", "chinese|语文|中文"),
        ("math",    "pre-?calculus|calculus|\\bmath"),
        ("ela",     "english"),
        ("chem",    "chem"),
        ("phys",    "physic"),
        ("bio",     "biolog"),
        ("geo",     "geograph"),
        ("ids",     "\\bIDS\\b|big\\s*history"),
    ]

    static func key(_ text: String) -> String {
        for (k, p) in slots where text.range(of: p, options: [.regularExpression, .caseInsensitive]) != nil {
            return k
        }
        return ""
    }

    static func rgb(_ text: String) -> RGB? { colors[key(text)] }

    /// 中文短科目名（与 GPA 板块的 label 完全一致）
    static let cnLabels: [String: String] = [
        "chinese": "语文", "math": "数学", "ela": "英语", "chem": "化学",
        "phys": "物理", "bio": "生物", "geo": "地理", "ids": "IDS",
    ]

    /// 面板上显示的科目名：优先中文短名，识别不出时退回英文精简名
    static func label(_ raw: String?) -> String {
        if let cn = cnLabels[key(raw ?? "")] { return cn }
        return short(raw)
    }

    /// 学科名精简（与 app.html shortSubject 等价）
    static func short(_ raw: String?) -> String {
        var t = raw ?? ""
        func sub(_ pat: String, _ with: String = " ") {
            t = t.replacingOccurrences(of: pat, with: with,
                                       options: [.regularExpression, .caseInsensitive])
        }
        sub("\\(\\s*Grade\\s*\\d+\\s*\\)")
        sub("\\bClass\\s*\\d+\\b")
        sub("\\d+\\s*班[^\\s]*")
        sub("\\s*\\d+(\\s*\\+\\s*\\d+)+\\s*")
        sub("\\s*[A-Z]\\d{2,4}\\s*$")
        t = t.replacingOccurrences(of: "^AP\\s+", with: "",
                                   options: [.regularExpression, .caseInsensitive])
        t = t.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        t = t.trimmingCharacters(in: .whitespaces)
        t = t.replacingOccurrences(of: "\\s+[A-Z]$", with: "", options: .regularExpression)
        t = t.trimmingCharacters(in: .whitespaces)
        return t.isEmpty ? "课程" : t
    }
}

/* ============================================================
   截止紧急度分档：≤26h 红、26–50h 黄、50–74h 蓝、>74h 绿
   ============================================================ */
enum Band {
    case over, urgent, soon, blue, ok

    func color(_ scheme: ColorScheme) -> Color {
        switch self {
        case .over:   return Theme.red.color(scheme, lift: 0.28)
        case .urgent: return Theme.red.color(scheme, lift: 0.16)
        case .soon:   return Theme.amber.color(scheme, lift: 0.10)
        case .blue:   return Theme.blue.color(scheme, lift: 0.16)
        case .ok:     return Theme.green.color(scheme, lift: 0.10)
        }
    }
}

enum Threshold {
    static let urgent = 26.0, soon = 50.0, blue = 74.0
}

func bandOf(leftMs: Double?, isOver: Bool) -> Band {
    if isOver { return .over }
    guard let l = leftMs else { return .ok }
    let h = l / 3_600_000
    if h <= Threshold.urgent { return .urgent }
    if h <= Threshold.soon   { return .soon }
    if h <= Threshold.blue   { return .blue }
    return .ok
}

/* ============================================================
   时间工具（与 app.html 同名函数等价）
   ============================================================ */
func humanLeft(_ ms: Double) -> String {
    let s = (ms / 1000).rounded()
    let d = (s / 86400).rounded(.down)
    let h = (s.truncatingRemainder(dividingBy: 86400) / 3600).rounded(.down)
    let m = (s.truncatingRemainder(dividingBy: 3600) / 60).rounded(.down)
    if d > 0 { return "\(Int(d)) 天 \(Int(h)) 小时" }
    if h > 0 { return "\(Int(h)) 小时 \(Int(m)) 分" }
    if m > 0 { return "\(Int(m)) 分钟" }
    return "不到 1 分钟"
}

func hms(_ ms: Double) -> String {
    let t = max(0, (ms / 1000).rounded(.down))
    let h = Int(t / 3600)
    let m = Int(t.truncatingRemainder(dividingBy: 3600) / 60)
    let s = Int(t.truncatingRemainder(dividingBy: 60))
    return String(format: "%02d:%02d:%02d", h, m, s)
}

func fmtClock(_ d: Date) -> String {
    let c = Calendar.current.dateComponents([.hour, .minute], from: d)
    return String(format: "%02d:%02d", c.hour ?? 0, c.minute ?? 0)
}

/* ============================================================
   成绩格式：百分比 & 4 分制折算（与 app.html to4 / fmtPct 等价）
   ============================================================ */
/// 百分数 → "90.35%" / "99.2%" / "78%"（与 app.html fmtPct 完全一致：最多两位小数并去掉多余的 0）
func fmtPct(_ v: Double) -> String {
    let n = (v * 100).rounded() / 100
    var s = String(format: "%.2f", n)
    while s.contains(".") && (s.hasSuffix("0") || s.hasSuffix(".")) {
        s.removeLast()
    }
    return s + "%"
}

/// 占比 → 满分 4 分，保留两位（99.2% → "3.97"）
func to4(_ ratio: Double) -> String {
    String(format: "%.2f", (ratio * 400).rounded() / 100)
}

/* ============================================================
   课表（源自「课表-新版」PDF，与 app.html 中的 WEEK / PERIODS 一致）
   ============================================================ */
enum Schedule {
    struct Period {
        let label: String, start: String, end: String
    }

    static let periods: [Period] = [
        Period(label: "P1", start: "08:00", end: "08:40"),
        Period(label: "P2", start: "08:50", end: "09:30"),
        Period(label: "P3", start: "10:00", end: "10:40"),
        Period(label: "P4", start: "10:50", end: "11:30"),
        Period(label: "P5", start: "11:40", end: "12:20"),
        Period(label: "P6", start: "13:50", end: "14:30"),
        Period(label: "P7", start: "14:45", end: "15:25"),
        Period(label: "P8", start: "15:40", end: "16:20"),
    ]

    /// 课程颜色（对应 PDF 图例）
    static let palette: [String: String] = [
        "calc": "#c355c9", "phys": "#79c34a", "ids": "#f0913f", "eng": "#f0913f",
        "pol": "#e8b93a", "pe": "#8a7be0", "chem": "#7b6ce0", "geo": "#8a7be0",
        "his": "#6f9ce8", "bio": "#3fbfa6", "it": "#3f8fe0", "chi": "#e8638c",
        "guide": "#93a3b8", "toefl": "#a884d8", "art": "#59c2b0", "class_meet": "#e05a5a",
    ]

    struct Block {
        let from: Int, to: Int
        let subject: String, room: String, teacher: String, mode: String, color: String
    }

    static func blk(_ a: Int, _ b: Int, _ s: String, _ room: String,
                    _ t: String, _ mode: String, _ c: String) -> Block {
        Block(from: a, to: b, subject: s, room: room, teacher: t, mode: mode, color: c)
    }

    /// 1=周一 … 5=周五
    static let week: [Int: [Block]] = [
        1: [blk(1, 1, "AP 初级微积分", "E103", "李思远", "走班", "calc"),
            blk(2, 3, "高一年级英语", "E101", "Alan Reeve", "走班", "eng"),
            blk(4, 4, "历史", "E106", "周敏", "本班", "his"),
            blk(5, 5, "AP 化学", "E112", "吴静", "走班", "chem"),
            blk(6, 7, "高一年级跨学科学习", "E103", "Peter Nolan", "走班", "ids"),
            blk(8, 8, "美术", "美术教室", "郑雅", "课程", "art")],
        2: [blk(1, 2, "AP 初级微积分", "E103", "李思远", "走班", "calc"),
            blk(3, 3, "自习 / 空档", "", "", "", "guide"),
            blk(4, 5, "AP 化学", "E112", "吴静", "走班", "chem"),
            blk(6, 7, "生物", "E106", "孙琳", "本班", "bio"),
            blk(8, 8, "高一年级语文", "E107", "冯雪", "走班", "chi")],
        3: [blk(1, 2, "物理", "E107", "陈曦", "走班", "phys"),
            blk(3, 4, "AP 化学", "E112", "吴静", "走班", "chem"),
            blk(5, 5, "高一年级英语", "E101", "Alan Reeve", "走班", "eng"),
            blk(6, 6, "自习 / 空档", "", "", "", "guide"),
            blk(7, 8, "新托福培训", "W110", "许晴", "走班", "toefl")],
        4: [blk(1, 1, "物理", "E107", "陈曦", "走班", "phys"),
            blk(2, 2, "政治", "E107", "高洋", "走班", "pol"),
            blk(3, 3, "体育男", "", "罗毅", "走班", "pe"),
            blk(4, 5, "高一年级英语", "E101", "Alan Reeve", "走班", "eng"),
            blk(6, 7, "高一年级语文", "E107", "冯雪", "走班", "chi"),
            blk(8, 8, "班会", "E106", "李思远", "本班", "class_meet")],
        5: [blk(1, 1, "高一年级跨学科学习", "E103", "Peter Nolan", "走班", "ids"),
            blk(2, 2, "体育男", "", "罗毅", "走班", "pe"),
            blk(3, 3, "地理", "E107", "唐婉", "走班", "geo"),
            blk(4, 4, "生物", "E106", "孙琳", "本班", "bio"),
            blk(5, 5, "信息技术", "信息技术教室", "秦朗", "课程", "it"),
            blk(6, 6, "升学指导", "E106", "韩冰", "本班", "guide"),
            blk(7, 8, "AP 初级微积分", "E103", "李思远", "走班", "calc")],
    ]

    static let nightStart = "18:30"
    static let nightEnd = "22:30"
    static let wake = "06:00"

    struct Slot: Identifiable {
        let id: String
        let blockId: String
        let dayIdx: Int
        let period: Int
        let pLabel: String
        let start: Date
        var end: Date
        let subject: String
        let room: String
        let teacher: String
        let mode: String
        let hex: String
        let isFree: Bool
        let first: Bool
        let last: Bool
        let span: [Int]
        var to: Int

        var color: Color { RGB(hex).color(.light) }
    }

    static func hm(_ str: String, _ base: Date) -> Date {
        let p = str.split(separator: ":").map { Int($0) ?? 0 }
        var c = Calendar.current.dateComponents([.year, .month, .day], from: base)
        c.hour = p.first ?? 0
        c.minute = p.count > 1 ? p[1] : 0
        c.second = 0
        return Calendar.current.date(from: c) ?? base
    }

    static func minutes(_ str: String) -> Int {
        let p = str.split(separator: ":").map { Int($0) ?? 0 }
        return (p.first ?? 0) * 60 + (p.count > 1 ? p[1] : 0)
    }

    /// JS 的 getDay()：0=周日 … 6=周六
    static func jsDay(_ d: Date) -> Int { Calendar.current.component(.weekday, from: d) - 1 }

    static func slots(day: Int, on date: Date) -> [Slot] {
        guard let blocks = week[day] else { return [] }
        var out: [Slot] = []
        for (i, b) in blocks.enumerated() {
            guard b.from <= b.to else { continue }
            for p in b.from...b.to {
                let per = periods[p - 1]
                out.append(Slot(
                    id: "\(day)-\(i)-\(p)", blockId: "\(day)-\(i)", dayIdx: day,
                    period: p, pLabel: per.label,
                    start: hm(per.start, date), end: hm(per.end, date),
                    subject: b.subject, room: b.room, teacher: b.teacher,
                    mode: b.mode, hex: palette[b.color] ?? "#0071e3",
                    isFree: b.subject.contains("自习"),
                    first: p == b.from, last: p == b.to,
                    span: [b.from, b.to], to: p))
            }
        }
        return out
    }

    static func upcoming(_ now: Date, _ n: Int = 4) -> [Slot] {
        var out: [Slot] = []
        var d = now
        var guardCount = 0
        while out.count < n && guardCount < 14 {
            let day = jsDay(d)
            if week[day] != nil {
                for s in slots(day: day, on: d) where s.start > now { out.append(s) }
            }
            d = Calendar.current.date(byAdding: .day, value: 1, to: d) ?? d.addingTimeInterval(86400)
            guardCount += 1
        }
        return Array(out.prefix(n))
    }

    static func currentSlot(_ now: Date) -> Slot? {
        slots(day: jsDay(now), on: now).first { now >= $0.start && now < $0.end }
    }

    /// 把同一天的连堂（同一 blockId 的连续节次）合并成一条，便于整日列表展示
    static func merge(_ list: [Slot]) -> [Slot] {
        var out: [Slot] = []
        for s in list {
            if var last = out.last, last.blockId == s.blockId {
                last.to = s.period
                last.end = s.end
                out[out.count - 1] = last
                continue
            }
            var copy = s
            copy.to = s.period
            out.append(copy)
        }
        return out
    }

    /// 下一天有课的日子（周末 / 假期自动跳过）
    static func nextSchoolDay(after now: Date) -> (day: Date, list: [Slot]) {
        let cal = Calendar.current
        var d = cal.startOfDay(for: now)
        for _ in 0..<14 {
            d = cal.date(byAdding: .day, value: 1, to: d) ?? d.addingTimeInterval(86400)
            let raw = slots(day: jsDay(d), on: d)
            if !raw.isEmpty { return (d, merge(raw)) }
        }
        return (d, [])
    }

    /// 「接下来的课堂」要整日展示的课程：
    /// - 第一节课之前 → 今天全部课程
    /// - 最后一节课之后 → 下一天有课的日子
    /// - 白天进行中 → 今天全部课程（第一节到最后一节）
    static func dayList(_ now: Date) -> (day: Date, list: [Slot]) {
        let today = Calendar.current.startOfDay(for: now)
        let raw = slots(day: jsDay(now), on: now)
        if let first = raw.first, now < first.start { return (today, merge(raw)) }
        if let last = raw.last, now >= last.end {
            let n = nextSchoolDay(after: now)
            return (n.day, n.list)
        }
        if !raw.isEmpty { return (today, merge(raw)) }
        let n = nextSchoolDay(after: now)
        return (n.day, n.list)
    }

    /// 「今天 / 明天 / 后天 / 周X」
    static func dayName(_ d: Date, now: Date = Date()) -> String {
        let cal = Calendar.current
        let a = cal.startOfDay(for: now), b = cal.startOfDay(for: d)
        let diff = cal.dateComponents([.day], from: a, to: b).day ?? 0
        switch diff {
        case 0:  return "今天"
        case 1:  return "明天"
        case 2:  return "后天"
        default: return ["周日", "周一", "周二", "周三", "周四", "周五", "周六"][max(0, min(6, jsDay(d)))]
        }
    }

    static func dayCaption(_ d: Date, now: Date = Date()) -> String {
        let c = Calendar.current.dateComponents([.month, .day], from: d)
        return "\(dayName(d, now: now)) \(c.month ?? 0)月\(c.day ?? 0)日 " +
               ["周日", "周一", "周二", "周三", "周四", "周五", "周六"][max(0, min(6, jsDay(d)))]
    }

    /* ---------------- 面板最顶上那块大计时 ---------------- */

    enum TopTimer {
        /// 22:30–06:00，纯休息
        case rest
        /// 正在上课 → 显示还有多久下课
        case inClass(Slot)
        /// 课间 / 午休 → 显示还有多久上课（since = 上次下课时间，nil 表示还没上过课）
        case breakTime(next: Slot, since: Date?)
        /// 晚自习前 / 后
        case studyEnd(Date)
        case studyStart(Date)

        var label: String {
            switch self {
            case .rest:              return "现在是休息时间"
            case .inClass(let s):    return s.isFree ? "空闲时段 · 距离结束" : "正在上课 · 距离下课"
            case .breakTime(let n, let since):
                guard let since else { return "距离第一节课" }
                let gap = n.start.timeIntervalSince(since) / 60
                let h = Calendar.current.component(.hour, from: since)
                if gap >= 50 { return (h >= 11 && h <= 14) ? "午休 · 距离上课" : "大课间 · 距离上课" }
                return "课间休息 · 距离上课"
            case .studyEnd:          return "距离晚自习结束"
            case .studyStart:        return "距离晚自习开始"
            }
        }

        var isRest: Bool { if case .rest = self { return true }; return false }
    }

    static func topTimer(_ now: Date) -> TopTimer {
        let t = Calendar.current.component(.hour, from: now) * 60
              + Calendar.current.component(.minute, from: now)
        if t >= minutes(nightEnd) || t < minutes(wake) { return .rest }
        if t >= minutes(nightStart) && t < minutes(nightEnd) {
            return .studyEnd(hm(nightEnd, now))
        }
        let raw = slots(day: jsDay(now), on: now)
        if let cur = raw.first(where: { now >= $0.start && now < $0.end }) {
            return .inClass(cur)
        }
        if let next = raw.first(where: { $0.start > now }) {
            let prev = raw.last(where: { $0.end <= now })
            return .breakTime(next: next, since: prev?.end)
        }
        if !raw.isEmpty && t < minutes(nightStart) {
            return .studyStart(hm(nightStart, now))
        }
        if let nxt = upcoming(now, 1).first { return .breakTime(next: nxt, since: nil) }
        return .rest
    }
}

/* ============================================================
   日期显示
   ============================================================ */

/// 截止时间短格式：'Sep 14 Monday at 10:20 AM' → '9/14 10:20'
func shortDue(_ s: String?) -> String {
    guard let s, !s.isEmpty else { return "" }
    let pat = "([A-Z][a-z]{2})[a-z]*\\s+(\\d{1,2})(?:\\s+\\w+)?\\s+at\\s+(\\d{1,2}):(\\d{2})\\s*([AaPp][Mm])"
    guard let re = try? NSRegularExpression(pattern: pat),
          let m = re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) else { return s }
    func g(_ i: Int) -> String {
        guard let r = Range(m.range(at: i), in: s) else { return "" }
        return String(s[r])
    }
    let months = ["Jan": 1, "Feb": 2, "Mar": 3, "Apr": 4, "May": 5, "Jun": 6,
                  "Jul": 7, "Aug": 8, "Sep": 9, "Oct": 10, "Nov": 11, "Dec": 12]
    let mo = months[g(1)] ?? 0
    var h = (Int(g(3)) ?? 0) % 12
    if g(5).uppercased() == "PM" { h += 12 }
    return String(format: "%d/%d %02d:%@", mo, Int(g(2)) ?? 0, h, g(4))
}

/// Date → '9/14 10:20'
func shortDueDate(_ d: Date) -> String {
    let c = Calendar.current.dateComponents([.month, .day, .hour, .minute], from: d)
    return String(format: "%d/%d %02d:%02d", c.month ?? 0, c.day ?? 0, c.hour ?? 0, c.minute ?? 0)
}
