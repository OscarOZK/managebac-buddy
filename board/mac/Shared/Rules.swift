import Foundation
import SwiftUI

/* ======================================================================
   规则层：学科识别 / 配色、截止紧急度分档、时间格式化、课表
   与后端 scrape.js、前端 app.html 保持同一套口径。
   这一层里"可配置"的部分一律从 BoardSettings 读，保证设置真实生效。
   ====================================================================== */

enum Subject {
    /// 兜底色（设置里没覆盖到的学科）
    static let fallback: [String: RGB] = [
        "chinese": RGB("#a96f6b"), "math": RGB("#867a9e"), "ela": RGB("#b58455"),
        "chem": RGB("#6f7c9e"), "phys": RGB("#719070"), "bio": RGB("#5b918a"),
        "geo": RGB("#74889c"), "ids": RGB("#94836f"),
        "history": RGB("#9c7a63"), "politics": RGB("#7a8098"),
    ]

    /* 学科识别。
       教训：原来这套正则只写英文关键词（外加「语文/中文」两个），
       结果 Teams 回来的课程名是中文的「历史」「英语」「生物」「政治」，
       全部认不出来 → 通知图标统统退化成同一个蓝毕业帽，
       用户截图反馈「必须有很明显很明显的学科区分」。
       现在中文名和更多英文写法都进识别表。 */
    private static let slots: [(String, String)] = [
        ("chinese",  "chinese|mandarin|语文|中文|汉语"),
        ("math",     "pre-?calculus|calculus|\\bmath|数学"),
        ("ela",      "english|\\bela\\b|英语|英文"),
        ("chem",     "chem|化学"),
        ("phys",     "physic|物理"),
        ("bio",      "biolog|生物"),
        ("geo",      "geograph|地理"),
        // 注意：IDS 要排在 history 前面，否则 "Big History" 会被历史课抢走
        ("ids",      "\\bIDS\\b|big\\s*history|interdisciplinary|跨学科"),
        ("history",  "history|历史"),
        ("politics", "politic|civic|\\bgovernment\\b|政治|公民|道法"),
    ]

    static let keys = ["chinese", "math", "ela", "chem", "phys", "bio", "geo", "ids",
                       "history", "politics"]

    static let cnLabels: [String: String] = [
        "chinese": "语文", "math": "数学", "ela": "英语", "chem": "化学",
        "phys": "物理", "bio": "生物", "geo": "地理", "ids": "IDS",
        "history": "历史", "politics": "政治",
    ]

    static let enLabels: [String: String] = [
        "chinese": "Chinese", "math": "Math", "ela": "English", "chem": "Chemistry",
        "phys": "Physics", "bio": "Biology", "geo": "Geography", "ids": "IDS",
        "history": "History", "politics": "Politics",
    ]

    /// 学科图标（用户要求：通知上要用学科对应的图标）
    /// 注意：各科图标要「同一类视觉」—— 都是图形，不能混进字形。
    /// 数学原来用 "function"，它渲染出来是 ƒ(x) 的**文字**，
    /// 和旁边的书本/烧瓶/原子摆在一起会显得像漏字了，所以换成 "x.squareroot"。
    static let symbols: [String: String] = [
        "chinese": "character.book.closed.fill",
        "math":    "x.squareroot",
        "ela":     "text.book.closed.fill",
        "chem":    "flask.fill",
        "phys":    "atom",
        "bio":     "leaf.fill",
        "geo":     "globe.asia.australia.fill",
        "ids":     "lightbulb.fill",
        "history": "scroll.fill",
        "politics": "building.columns.fill",
    ]

    static func symbol(_ key: String) -> String { symbols[key] ?? "book.closed.fill" }
    static func symbol(_ raw: String?) -> String { symbol(key(raw ?? "")) }
    /// 认不出学科时用的通用图标
    static let genericSymbol = "graduationcap.fill"

    /* ---------------- 通知图标专用配色 ----------------
       为什么不直接用看板的学科色：那套是莫兰迪（低饱和、面积小、留白大时耐看），
       可它缩到通知右上角那张 40pt 的小图里就全糊了；试过统一提饱和，
       结果化学 / 英语 / IDS / 历史 / 政治 还是挤在「土色 + 深蓝」两团里 ——
       用户截图反馈「一定一定有强区分」，所以图标改用一套**固定色相环**：
       十科在色相环上均匀铺开（相邻至少 30°），外加各不相同的符号。
       颜色负责「分得开」，符号负责「是哪一科」。 */
    static let iconHues: [String: Double] = [
        "chinese": 358,   // 红
        "history": 25,    // 橙
        "politics": 50,   // 金
        "bio": 130,       // 绿
        "chem": 165,      // 青绿
        "geo": 195,       // 天青
        "ela": 225,       // 蓝
        "phys": 255,      // 靛
        "math": 285,      // 紫
        "ids": 320,       // 品红
    ]

    static let genericIconRGB = RGB("#5b6b8c")

    static func iconRGB(_ key: String) -> RGB {
        guard let h = iconHues[key] else { return genericIconRGB }
        return RGB(hue: h, saturation: 0.70, value: 0.85)
    }

    static func iconRGB(_ raw: String?) -> RGB { iconRGB(key(raw ?? "")) }

    static func key(_ text: String) -> String {
        for (k, p) in slots where text.range(of: p, options: [.regularExpression, .caseInsensitive]) != nil {
            return k
        }
        return ""
    }

    /// 学科色：先查设置里的覆盖，再退回内置
    @MainActor static func rgb(_ key: String, _ settings: BoardSettings) -> RGB {
        if let h = settings.subjectColors[key], !h.isEmpty { return RGB(h) }
        return fallback[key] ?? Theme.ink3_RGB
    }

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

extension Theme {
    static let ink3_RGB = RGB("#86868b")
}

/* ============================================================
   截止紧急度分档：阈值全部来自设置（设置 → 真实生效）
   ============================================================ */

enum Band: String {
    case over, urgent, soon, blue, ok

    var name: String {
        switch self {
        case .over:   return "已逾期"
        case .urgent: return "紧急"
        case .soon:   return "较急"
        case .blue:   return "留意"
        case .ok:     return "充裕"
        }
    }

    func color(_ scheme: ColorScheme, accent: RGB) -> Color {
        switch self {
        case .over:   return Theme.redDefault.color(scheme, lift: 0.30)
        case .urgent: return Theme.redDefault.color(scheme, lift: 0.16)
        case .soon:   return Theme.amberDefault.color(scheme, lift: 0.10)
        case .blue:   return accent.color(scheme, lift: 0.20)
        case .ok:     return Theme.greenDefault.color(scheme, lift: 0.10)
        }
    }
}

@MainActor func bandOf(leftMs: Double?, isOver: Bool, _ s: BoardSettings) -> Band {
    if isOver { return .over }
    guard let l = leftMs else { return .ok }
    let h = l / 3_600_000
    if h <= s.urgentHours { return .urgent }
    if h <= s.soonHours   { return .soon }
    if h <= s.blueHours   { return .blue }
    return .ok
}

/* ============================================================
   时间工具
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
    if h > 0 { return String(format: "%02d:%02d:%02d", h, m, s) }
    return String(format: "%02d:%02d", m, s)
}

func fmtClock(_ d: Date) -> String {
    let c = Calendar.current.dateComponents([.hour, .minute], from: d)
    return String(format: "%02d:%02d", c.hour ?? 0, c.minute ?? 0)
}

func fmtPct(_ v: Double) -> String {
    // v 已经是百分数（91.75 表示 91.75%）。
    // 统一到一位小数：原来按两位算再削掉末尾的 0，于是同一列里会出现
    // 「99.2% / 91.75% / 78%」三种精度，右对齐后看着参差。
    let s = String(format: "%.1f", (v * 10).rounded() / 10)
    return (s.hasSuffix(".0") ? String(s.dropLast(2)) : s) + "%"
}

func to4(_ ratio: Double) -> String { String(format: "%.2f", (ratio * 400).rounded() / 100) }

/// Date → '9/14 10:20'
func shortDueDate(_ d: Date) -> String {
    let c = Calendar.current.dateComponents([.month, .day, .hour, .minute], from: d)
    return String(format: "%d/%d %02d:%02d", c.month ?? 0, c.day ?? 0, c.hour ?? 0, c.minute ?? 0)
}

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

/* ---------------- 出分时间 ----------------
   ManageBac 不提供「老师什么时候批的分」，bridge 会在第一次见到这条已评分
   作业时打一个时间戳（gradetimes.json 持久留存），之后每次抓取都回填。
   界面上按距今远近挑说法：今天 → 「今天 14:02」，昨天 → 「昨天 20:11」，
   七天内 → 「周三 09:15」，更早 → 「9/18」。 */

private func gradedParts(_ d: Date) -> (mo: Int, day: Int, wd: Int, h: Int, mi: Int, daysAgo: Int) {
    let cal = Calendar.current
    let c = cal.dateComponents([.month, .day, .weekday, .hour, .minute], from: d)
    let startOf = cal.startOfDay(for: d)
    let today0 = cal.startOfDay(for: Date())
    return (c.month ?? 0, c.day ?? 0, c.weekday ?? 0, c.hour ?? 0, c.minute ?? 0,
            cal.dateComponents([.day], from: startOf, to: today0).day ?? 0)
}

/// 大看板用：「今天 14:02 出分」/「昨天 20:11 出分」/「周三 09:15 出分」/「9/18 出分」
func gradedAtText(_ d: Date?) -> String? {
    guard let d else { return nil }
    let p = gradedParts(d)
    let hm = String(format: "%02d:%02d", p.h, p.mi)
    let day: String
    switch p.daysAgo {
    case 0:      day = "今天"
    case 1:      day = "昨天"
    case 2...6:  day = ["周日", "周一", "周二", "周三", "周四", "周五", "周六"][p.wd % 7]
    default:     return String(format: "%d/%d 出分", p.mo, p.day)
    }
    return "\(day) \(hm) 出分"
}

/// 小看板用（省字）：「今天14:02」/「昨天20:11」/「周三09:15」/「9/18」
func gradedAtShort(_ d: Date?) -> String? {
    guard let d else { return nil }
    let p = gradedParts(d)
    let hm = String(format: "%02d:%02d", p.h, p.mi)
    switch p.daysAgo {
    case 0:      return "今天\(hm)"
    case 1:      return "昨天\(hm)"
    case 2...6:  return ["周日", "周一", "周二", "周三", "周四", "周五", "周六"][p.wd % 7] + hm
    default:     return String(format: "%d/%d", p.mo, p.day)
    }
}

/// 「已删除的作业」列表里那条时间戳：「今天 21:03 删除」/「9/18 删除」。
/// 复用 gradedParts 的「距今天数」算法，和周几表也共用一套，免得两处对不上。
func deletedAtText(_ d: Date) -> String {
    let p = gradedParts(d)
    let hm = String(format: "%02d:%02d", p.h, p.mi)
    switch p.daysAgo {
    case 0:      return "今天 \(hm) 删除"
    case 1:      return "昨天 \(hm) 删除"
    case 2...6:  return ["周日", "周一", "周二", "周三", "周四", "周五", "周六"][p.wd % 7] + " \(hm) 删除"
    default:     return String(format: "%d/%d 删除", p.mo, p.day)
    }
}

/* ============================================================
   课表（源自「课表-新版」PDF）
   晚自习 / 起床时间可由设置修改。
   ============================================================ */

enum Schedule {
    struct Period { let label: String, start: String, end: String }

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

    /// 1=周一 … 5=周五
    ///
    /// ⚠️ 这张表**不再写死在源码里**，原因有两层：
    ///
    ///   ① 隐私。原来的表里带着**真实老师的姓名**、教室号和本人选课 ——
    ///      那是「某个人的课表」，不是「一个通用默认值」。源码是要分发出去的
    ///      东西，塞进去等于把这些信息交给每一个拿到 App 的人，不管他是不是
    ///      这个学校的学生。
    ///   ② 正确性。这张表会**当真数据**渲染在「课程」页上（今日课程、本周课表、
    ///      即将上课、上下课倒计时全都读它）。别人装了这个 App，看到的会是
    ///      别人的课表，而且因为它是源码里的常量，还永远刷不掉。
    ///
    /// 现在改成从数据目录读：
    ///     ~/Library/Application Support/ManageBac 看板 Mac/timetable.json
    ///     {"1": [{"from":1,"to":1,"subject":"…","room":"…","teacher":"…",
    ///              "mode":"走班","color":"calc"}, …], "2": […]}
    /// 文件不存在 = 空课表，课程页显示「还没有课表」并引导去同步希悦；
    /// 所有依赖课表的计算都会优雅退化（slots/dayList/upcoming 本来就处理 nil）。
    static var week: [Int: [Block]] { timetable }

    private static let timetable: [Int: [Block]] = loadTimetable()

    private struct RawBlock: Decodable {
        var from: Int
        var to: Int
        var subject: String
        var room: String = ""
        var teacher: String = ""
        var mode: String = ""
        var color: String = ""
    }

    private static func loadTimetable() -> [Int: [Block]] {
        let url = MBBPaths.home.appendingPathComponent("timetable.json")
        guard let data = try? Data(contentsOf: url),
              let raw = try? JSONDecoder().decode([String: [RawBlock]].self, from: data)
        else { return [:] }
        var out: [Int: [Block]] = [:]
        for (key, list) in raw {
            guard let day = Int(key) else { continue }
            out[day] = list.map {
                Block(from: $0.from, to: $0.to, subject: $0.subject, room: $0.room,
                      teacher: $0.teacher, mode: $0.mode, color: $0.color)
            }
        }
        return out
    }

    /// 课表是不是压根没导进来 —— 课程页据此区分「没课表」和「搜不到」两种空。
    static var hasTimetable: Bool { !timetable.isEmpty }


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

        var color: Color { RGB(hex).color }
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
        while out.count < n && guardCount < 16 {
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

    static func nextSchoolDay(after now: Date) -> (day: Date, list: [Slot]) {
        let cal = Calendar.current
        var d = cal.startOfDay(for: now)
        for _ in 0..<16 {
            d = cal.date(byAdding: .day, value: 1, to: d) ?? d.addingTimeInterval(86400)
            let raw = slots(day: jsDay(d), on: d)
            if !raw.isEmpty { return (d, merge(raw)) }
        }
        return (d, [])
    }

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
        return "\(dayName(d, now: now)) · \(c.month ?? 0)月\(c.day ?? 0)日 · " +
               ["周日", "周一", "周二", "周三", "周四", "周五", "周六"][max(0, min(6, jsDay(d)))]
    }

    /* ---------------- 顶部大计时 ---------------- */

    enum TopTimer {
        case rest
        case inClass(Slot)
        case breakTime(next: Slot, since: Date?)
        case studyEnd(Date)
        case studyStart(Date)

        var isRest: Bool { if case .rest = self { return true }; return false }

        func label(_ s: BoardSettings) -> String {
            switch self {
            case .rest:
                return "现在是休息时间"
            case .inClass(let x):
                return x.isFree ? "空闲时段 · 距离结束" : "正在上课 · 距离下课"
            case .breakTime(let n, let since):
                guard let since else { return "距离第一节课" }
                let gap = n.start.timeIntervalSince(since) / 60
                let h = Calendar.current.component(.hour, from: since)
                if gap >= 50 { return (h >= 11 && h <= 14) ? "午休 · 距离上课" : "大课间 · 距离上课" }
                return "课间休息 · 距离上课"
            case .studyEnd:   return "距离晚自习结束"
            case .studyStart: return "距离晚自习开始"
            }
        }
    }

    @MainActor static func topTimer(_ now: Date, _ s: BoardSettings) -> TopTimer {
        let t = Calendar.current.component(.hour, from: now) * 60
              + Calendar.current.component(.minute, from: now)
        if t >= minutes(s.nightEnd) || t < minutes(s.wakeTime) { return .rest }
        if t >= minutes(s.nightStart) && t < minutes(s.nightEnd) {
            return .studyEnd(hm(s.nightEnd, now))
        }
        let raw = slots(day: jsDay(now), on: now)
        if let cur = raw.first(where: { now >= $0.start && now < $0.end }) { return .inClass(cur) }
        if let next = raw.first(where: { $0.start > now }) {
            let prev = raw.last(where: { $0.end <= now })
            return .breakTime(next: next, since: prev?.end)
        }
        if !raw.isEmpty && t < minutes(s.nightStart) { return .studyStart(hm(s.nightStart, now)) }
        if let nxt = upcoming(now, 1).first { return .breakTime(next: nxt, since: nil) }
        return .rest
    }
}
