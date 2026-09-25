import SwiftUI
import AppKit

/* ======================================================================
   ② 课程页
   今日时间轴（带「现在」指示）→ 本周课表总览 → 下节课
   ====================================================================== */

struct ClassesSection: View {
    @ObservedObject var store: DataStore
    @EnvironmentObject var settings: BoardSettings
    @Environment(\.colorScheme) private var scheme
    let now: Date
    /// 顶部搜索框的内容：在课程页用来找学科 / 老师 / 教室
    var search: String = ""

    private var env: Env { Env(scheme: scheme, settings: settings) }
    private var q: Search.Query { Search.parse(search) }

    /// 全周命中的课时（用于搜索时的结果卡，也用于把课表里的无关格调淡）
    private var hits: [Schedule.Slot] {
        guard !q.isEmpty else { return [] }
        var out: [Schedule.Slot] = []
        for d in 0...6 { out += Schedule.slots(day: d, on: now) }
        var seen = Set<String>()
        return out.filter { s in
            let hit = Search.hit(q, [s.subject, s.teacher, s.room, s.mode, s.pLabel])
            return hit && seen.insert(s.blockId).inserted     // 一个 block 只留一条
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: settings.density.sectionGap) {
            if !q.isEmpty && Schedule.hasTimetable { matchesCard }
            // ⚠️ 课表内容不再写在源码里（那是某个人的课表，带着真实老师姓名）。
            //    没有 timetable.json 的时候，下面四块**全都是空的** —— 与其摆出
            //    四个「今天的课里没有匹配」这种驴唇不对马嘴的空卡，不如给一张说人话的。
            if Schedule.hasTimetable {
                todayCard
                weekGrid
            } else {
                noTimetableCard
            }
            seiueCard          // 希悦课表：只在启用且抓到东西时出现
            // 「接下来的课」同理：没课表时那句「周末或假期，好好休息」是错的。
            if Schedule.hasTimetable { upcoming }
        }
    }

    /// 一份课表都没有时的空态。
    /// 说清「为什么空」和「怎么补上」，而不是把搜索的那套空态文案搬过来。
    private var noTimetableCard: some View {
        VStack(alignment: .leading, spacing: env.space(13)) {
            SectionHeader(title: "课程安排", subtitle: "还没有课表", icon: Icons.classes)
            GlassCard(env: env, radius: Radius.lg, padding: env.space(18)) {
                VStack(alignment: .leading, spacing: env.space(11)) {
                    HStack(spacing: 9) {
                        Image(systemName: "calendar.badge.plus")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(env.accent.color(scheme, lift: 0.08))
                        Text("这台电脑上还没有导入课表")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(Theme.ink(scheme))
                    }
                    Text("课表是只属于你的东西，所以它不随 App 一起发出去 —— 每台电脑都要自己导一次。下面任选一种：")
                        .font(.system(size: 12.5))
                        .foregroundStyle(Theme.ink2(scheme))
                        .fixedSize(horizontal: false, vertical: true)

                    VStack(alignment: .leading, spacing: env.space(7)) {
                        reasonRow("arrow.triangle.2.circlepath",
                                  "打开「设置 → 希悦课表」，点「立即同步」",
                                  "最快，课名和节次都按希悦的来")
                        reasonRow("calendar.badge.plus",
                                  "先连上 ManageBac，作业里自带的课程安排也能用",
                                  "不用额外操作，登录一次就有")
                    }
                }
            }
        }
        .appearIn(0)
    }

    private func reasonRow(_ icon: String, _ title: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(env.accent.color(scheme, lift: 0.10))
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(Theme.ink(scheme))
                    .fixedSize(horizontal: false, vertical: true)
                Text(detail)
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                    .lineLimit(2)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 0)
        }
    }

    /* ---------------- 希悦课表 ----------------
       希悦的课表在网页上是张网格，后端按几何位置把「周几 × 第几节」抠了出来。
       这里只负责老老实实把它摆出来 —— 不跟 ManageBac 的课表混在一起，
       免得两边打起来（课名、节次的叫法都不太一样）。 */

    @ViewBuilder
    private var seiueCard: some View {
        if settings.seiueEnabled {
            let sc = store.seiue?.schedule
            let days = (sc?.days ?? []).filter { !$0.isEmpty }
            let lessons = sc?.lessons ?? []
            GlassCard(env: env, radius: Radius.lg, padding: env.space(18)) {
                VStack(alignment: .leading, spacing: env.space(13)) {
                    SectionHeader(title: "希悦课表",
                                  subtitle: seiueSubtitle(sc, lessons.count),
                                  icon: "calendar.badge.clock")

                    if lessons.isEmpty {
                        seiueEmpty(sc)
                    } else {
                        seiueGrid(days: days, lessons: lessons)
                        if let t = sc?.ts {
                            Text("同步于 \(fmtStamp(t))")
                                .font(Typo.micro).foregroundStyle(.tertiary)
                        }
                    }
                }
            }
            .appearIn(3)
        }
    }

    private func seiueSubtitle(_ sc: SeiueSchedule?, _ n: Int) -> String {
        if sc?.loggedIn != true { return "还没登录" }
        if n == 0 { return sc?.error?.isEmpty == false ? "读取失败" : "没读到课表" }
        return "\(n) 节 · 希悦"
    }

    @ViewBuilder
    private func seiueEmpty(_ sc: SeiueSchedule?) -> some View {
        VStack(alignment: .leading, spacing: env.space(9)) {
            Text(sc?.error?.isEmpty == false ? (sc!.error!) : "还没读到希悦课表，点下面的按钮同步一次")
                .font(Typo.sub).foregroundStyle(.secondary)
            HStack(spacing: env.space(9)) {
                Button {
                    Task {
                        await Bridge.post("/api/seiue/login")
                        await store.loadSeiue()
                    }
                } label: {
                    Text("打开希悦登录")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(env.accent.color(scheme, lift: 0.06))
                        .padding(.horizontal, 12).frame(height: 27)
                        .contentShape(RoundedRectangle(cornerRadius: env.radius(8), style: .continuous))
                        .background {
                            RoundedRectangle(cornerRadius: env.radius(8), style: .continuous)
                                .fill(env.accent.color(scheme).opacity(0.13))
                        }
                }
                .buttonStyle(.plain)
                Button {
                    Task {
                        await Bridge.post("/api/seiue/sync", [:], timeout: 120)
                        await store.loadSeiue()
                    }
                } label: {
                    Text("我已登录，立即同步")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Theme.ink(scheme))
                        .padding(.horizontal, 12).frame(height: 27)
                        .contentShape(RoundedRectangle(cornerRadius: env.radius(8), style: .continuous))
                        .background {
                            RoundedRectangle(cornerRadius: env.radius(8), style: .continuous)
                                .fill(Color.primary.opacity(scheme == .dark ? 0.12 : 0.06))
                        }
                }
                .buttonStyle(.plain)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// 按「列 = 周几」摆出来。列头就是希悦页面上抓到的表头文字。
    private func seiueGrid(days: [String], lessons: [SeiueLesson]) -> some View {
        let cols = max(1, min(days.count, 7))
        let heads = days.isEmpty
            ? (0..<cols).map { "第\($0 + 1)列" }
            : Array(days.prefix(cols))
        return VStack(spacing: env.space(6)) {
            HStack(spacing: env.space(6)) {
                ForEach(Array(heads.enumerated()), id: \.offset) { i, d in
                    Text(d)
                        .font(Typo.micro)
                        .foregroundStyle(Theme.ink2(scheme))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 4)
                        .background {
                            RoundedRectangle(cornerRadius: env.radius(6), style: .continuous)
                                .fill(Color.primary.opacity(scheme == .dark ? 0.09 : 0.05))
                        }
                }
            }
            HStack(alignment: .top, spacing: env.space(6)) {
                ForEach(0..<cols, id: \.self) { i in
                    let col = lessons.filter { ($0.dayIndex ?? -1) == i }
                        .sorted { ($0.periodIndex ?? 0) < ($1.periodIndex ?? 0) }
                    VStack(spacing: env.space(6)) {
                        ForEach(col) { l in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(l.name ?? "—")
                                    .font(.system(size: 11.5, weight: .semibold))
                                    .foregroundStyle(Theme.ink(scheme))
                                    .lineLimit(2)
                                    .fixedSize(horizontal: false, vertical: true)
                                if !l.note.isEmpty {
                                    Text(l.note)
                                        .font(.system(size: 10))
                                        .foregroundStyle(.tertiary)
                                        .lineLimit(1)
                                }
                                if let p = l.period, !p.isEmpty {
                                    Text(p)
                                        .font(.system(size: 9.5, weight: .medium))
                                        .foregroundStyle(Theme.ink3(scheme))
                                        .lineLimit(1)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 8).padding(.vertical, 7)
                            .background {
                                RoundedRectangle(cornerRadius: env.radius(8), style: .continuous)
                                    .fill(scheme == .dark ? Color.white.opacity(0.055) : Color.white.opacity(0.60))
                            }
                            .overlay {
                                RoundedRectangle(cornerRadius: env.radius(8), style: .continuous)
                                    .strokeBorder(Theme.lineSoft(scheme), lineWidth: 0.7)
                            }
                        }
                        if col.isEmpty {
                            Text("—")
                                .font(Typo.micro).foregroundStyle(.quaternary)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 10)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .top)
                }
            }
        }
    }

    private func fmtStamp(_ ms: Double) -> String {
        let f = DateFormatter()
        f.dateFormat = "M月d日 HH:mm"
        return f.string(from: Date(timeIntervalSince1970: ms / 1000))
    }

    /* ---------------- 搜索命中（只在搜索时出现） ---------------- */

    private var matchesCard: some View {
        let list = hits
        let names = ["周日", "周一", "周二", "周三", "周四", "周五", "周六"]
        return GlassCard(env: env, radius: Radius.lg, padding: env.space(18)) {
            VStack(alignment: .leading, spacing: env.space(11)) {
                SectionHeader(title: "课程匹配",
                              subtitle: list.isEmpty
                                        ? "没有学科 / 老师 / 教室匹配「\(search.trimmingCharacters(in: .whitespaces))」"
                                        : "\(list.count) 节",
                              icon: Icons.search)
                if !list.isEmpty {
                    VStack(spacing: env.space(6)) {
                        ForEach(Array(list.prefix(20))) { s in
                            HStack(spacing: env.space(11)) {
                                RoundedRectangle(cornerRadius: 2)
                                    .fill(RGB(s.hex).color(scheme, lift: 0.10))
                                    .frame(width: 3, height: 26)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(s.subject)
                                        .font(Typo.callout).fontWeight(.medium)
                                        .foregroundStyle(Theme.ink(scheme))
                                        .lineLimit(1)
                                    HStack(spacing: 7) {
                                        Text("\(names[min(max(s.dayIdx, 0), 6)]) P\(s.span.first ?? s.period)–P\(s.span.last ?? s.period) · \(fmtClock(s.start))–\(fmtClock(s.end))")
                                            .font(Typo.micro).foregroundStyle(.secondary)
                                        if !s.teacher.isEmpty {
                                            Text(s.teacher).font(Typo.micro).foregroundStyle(.tertiary).lineLimit(1)
                                        }
                                    }
                                }
                                Spacer(minLength: 0)
                                if !s.room.isEmpty {
                                    Pill(env: env, text: s.room, color: RGB(s.hex), filled: false)
                                }
                            }
                            .padding(.horizontal, env.space(11))
                            .padding(.vertical, env.space(7))
                            .background {
                                RoundedRectangle(cornerRadius: env.radius(Radius.sm), style: .continuous)
                                    .fill(Color.primary.opacity(scheme == .dark ? 0.055 : 0.035))
                            }
                        }
                    }
                }
            }
        }
        .appearIn(0)
    }

    /* ---------------- 今日（或下次有课那天） ---------------- */

    private var todayCard: some View {
        let dl = Schedule.dayList(now)
        let cur = Schedule.currentSlot(now)
        let curBlock = cur?.blockId
        let shown = q.isEmpty ? dl.list : dl.list.filter {
            Search.hit(q, [$0.subject, $0.teacher, $0.room, $0.mode, $0.pLabel])
        }
        let nowIdx: Int? = q.isEmpty ? {
            guard Calendar.current.isDate(dl.day, inSameDayAs: now),
                  let first = dl.list.first, let last = dl.list.last,
                  now >= first.start, now < last.end else { return nil }
            return dl.list.filter { $0.end <= now }.count
        }() : nil
        // 正在上的那节课是否出现在这份列表里（搜索时可能被过滤掉）
        let inList = curBlock != nil && shown.contains { $0.blockId == curBlock }

        return VStack(alignment: .leading, spacing: env.space(13)) {
            SectionHeader(title: q.isEmpty ? "课程安排" : "课程安排 · 匹配",
                          subtitle: Schedule.dayCaption(dl.day, now: now),
                          icon: Icons.classes)

            GlassCard(env: env, radius: Radius.lg, padding: env.space(10)) {
                if shown.isEmpty {
                    EmptyState(env: env, icon: Icons.search,
                               title: "今天的课里没有匹配",
                               detail: "换个关键词，或清空搜索看全天")
                } else {
                    VStack(spacing: env.space(4)) {
                        ForEach(Array(shown.enumerated()), id: \.element.id) { i, s in
                            let inSession = inList && s.blockId == curBlock
                            // 课间（没有"正在上的那节课"）时：把「现在」玻璃条叠在
                            // 这一行**上沿**、卡在两节课之间的缝上 —— 图层在课表之上、
                            // 不占行高，不把课程往下推。
                            ClassRowView(slot: s, now: now, isNow: inSession, covered: inSession)
                                .overlay(alignment: inSession ? .center : .top) {
                                    if inSession {
                                        NowIndicator(env: env, cur: cur, now: now, withRoom: true)
                                            .transition(.pop)
                                    } else if !inList, nowIdx == i {
                                        NowIndicator(env: env, cur: cur, now: now)
                                            .offset(y: -(env.space(4) / 2 + 9))
                                            .transition(.pop)
                                    }
                                }
                        }
                    }
                    .animation(Motion.pop, value: curBlock)
                    .animation(Motion.pop, value: nowIdx)
                }
            }
        }
        .appearIn(0)
    }

    /* ---------------- 本周课表网格 ---------------- */

    private var weekGrid: some View {
        VStack(alignment: .leading, spacing: env.space(13)) {
            SectionHeader(title: "本周课表", subtitle: "周一 – 周五 · P1 – P8", icon: "square.grid.3x3.fill")

            GlassCard(env: env, radius: Radius.lg, padding: env.space(14)) {
                VStack(spacing: 5) {
                    HStack(spacing: 5) {
                        Text("").frame(width: 34)
                        ForEach(1...5, id: \.self) { d in
                            Text(["周一", "周二", "周三", "周四", "周五"][d - 1])
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(isToday(d) ? settings.accent.color(scheme, lift: 0.14) : .secondary)
                                .frame(maxWidth: .infinity)
                        }
                    }

                    ForEach(Array(Schedule.periods.enumerated()), id: \.offset) { pi, per in
                        HStack(spacing: 5) {
                            VStack(alignment: .trailing, spacing: 1) {
                                Text(per.label)
                                    .font(.system(size: 9.5, weight: .bold))
                                    .foregroundStyle(.secondary)
                                Text(per.start)
                                    .font(.system(size: 8, weight: .medium))
                                    .monospacedDigit()
                                    .foregroundStyle(.tertiary)
                            }
                            .frame(width: 34, alignment: .trailing)

                            ForEach(1...5, id: \.self) { d in
                                weekCell(day: d, period: pi + 1)
                            }
                        }
                    }
                }
            }

            legend
        }
        .appearIn(1)
    }

    private func isToday(_ d: Int) -> Bool { Schedule.jsDay(now) == d }

    private func weekCell(day: Int, period: Int) -> some View {
        let blocks = Schedule.week[day] ?? []
        let blk = blocks.first { period >= $0.from && period <= $0.to }
        let isStart = blk.map { $0.from == period } ?? false
        let isEnd = blk.map { $0.to == period } ?? false
        let isNowCell = isToday(day) && Schedule.minutes(fmtClock(now)) >= Schedule.minutes(Schedule.periods[period - 1].start)
            && Schedule.minutes(fmtClock(now)) < Schedule.minutes(Schedule.periods[period - 1].end)
        let free = blk?.subject.contains("自习") ?? false
        let rgb = blk.map { RGB(Schedule.palette[$0.color] ?? "#0071e3") }
        let match = weekCellMatches(blk)

        return Group {
            if let blk, let rgb {
                let c = free ? Theme.ink3_RGB : rgb
                VStack(alignment: .leading, spacing: 1) {
                    if isStart {
                        Text(blk.subject)
                            .font(.system(size: 9.5, weight: .semibold))
                            .foregroundStyle(free ? Color.secondary : c.onColor)
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                        if !blk.room.isEmpty {
                            Text(blk.room)
                                .font(.system(size: 8, weight: .medium))
                                .foregroundStyle((free ? Color.secondary : c.onColor).opacity(0.75))
                                .lineLimit(1)
                        }
                    }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 5)
                .padding(.vertical, 4)
                .frame(maxWidth: .infinity, minHeight: env.space(30), alignment: .topLeading)
                .background {
                    RoundedRectangle(cornerRadius: env.radius(7), style: .continuous)
                        .fill(c.color(scheme, lift: scheme == .dark ? 0.10 : 0.0)
                            .opacity(free ? 0.14 : (isStart ? 0.92 : 0.78)))
                }
                .overlay {
                    RoundedRectangle(cornerRadius: env.radius(7), style: .continuous)
                        .strokeBorder(isNowCell ? settings.accent.color(scheme, lift: 0.10) : .clear, lineWidth: 2)
                }
                .help("\(blk.subject) · P\(blk.from)–P\(blk.to)\n\([blk.room, blk.teacher, blk.mode].filter { !$0.isEmpty }.joined(separator: " · "))")
            } else {
                RoundedRectangle(cornerRadius: env.radius(7), style: .continuous)
                    .fill(Color.primary.opacity(scheme == .dark ? 0.045 : 0.028))
                    .frame(maxWidth: .infinity, minHeight: env.space(30))
            }
        }
        // 搜索时把无关的格子压暗，命中的保持原样 —— 一眼就能在整周课表里定位
        .opacity(match ? (isEnd ? 1 : 0.94) : 0.22)
        .saturation(match ? 1 : 0.2)
    }

    /// 当前格子是否命中搜索（没在搜索 / 空格子都算命中，不做压暗）
    private func weekCellMatches(_ blk: Schedule.Block?) -> Bool {
        guard !q.isEmpty else { return true }
        guard let blk else { return true }
        return Search.hit(q, [blk.subject, blk.room, blk.teacher, blk.mode])
    }

    private var legend: some View {
        let seen: [(String, String)] = {
            var out: [(String, String)] = []
            var used = Set<String>()
            for d in 1...5 {
                for b in (Schedule.week[d] ?? []) where !used.contains(b.subject) {
                    used.insert(b.subject)
                    out.append((b.subject, Schedule.palette[b.color] ?? "#0071e3"))
                }
            }
            return out
        }()
        return FlowRow(spacing: 8, lineSpacing: 8) {
            ForEach(Array(seen.enumerated()), id: \.offset) { _, kv in
                HStack(spacing: 5) {
                    RoundedRectangle(cornerRadius: 2.5)
                        .fill(RGB(kv.1).color(scheme, lift: scheme == .dark ? 0.12 : 0))
                        .frame(width: 10, height: 10)
                    Text(kv.0)
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    /* ---------------- 接下来的课 ---------------- */

    private var upcoming: some View {
        let all = Schedule.upcoming(now, 5)
        let list = q.isEmpty ? all : all.filter {
            Search.hit(q, [$0.subject, $0.teacher, $0.room, $0.mode, $0.pLabel])
        }
        return VStack(alignment: .leading, spacing: env.space(13)) {
            SectionHeader(title: q.isEmpty ? "接下来" : "接下来 · 匹配",
                          subtitle: list.isEmpty ? "" : "最近 \(list.count) 节",
                          icon: "arrow.right.circle.fill")

            if list.isEmpty {
                GlassCard(env: env, radius: Radius.md) {
                    EmptyState(env: env, icon: "calendar.badge.exclamationmark",
                               title: q.isEmpty ? "接下来没有排课" : "接下来的课里没有匹配",
                               detail: q.isEmpty ? "周末或假期，好好休息" : "换个关键词试试")
                }
            } else {
                HStack(spacing: env.space(12)) {
                    ForEach(Array(list.enumerated()), id: \.element.id) { i, s in
                        GlassCard(env: env, radius: Radius.md, padding: env.space(13)) {
                            VStack(alignment: .leading, spacing: 5) {
                                HStack(spacing: 5) {
                                    Circle().fill(RGB(s.hex).color(scheme, lift: 0.12))
                                        .frame(width: 6, height: 6)
                                    Text("\(i == 0 ? "下一节" : Schedule.dayName(s.start, now: now))")
                                        .font(.system(size: 10.5, weight: .semibold))
                                        .foregroundStyle(.secondary)
                                    Spacer(minLength: 0)
                                }
                                Text(s.subject)
                                    .font(.system(size: 13, weight: .semibold))
                                    .foregroundStyle(Theme.ink(scheme))
                                    .lineLimit(2)
                                    .fixedSize(horizontal: false, vertical: true)
                                Spacer(minLength: 2)
                                Text("\(s.pLabel) · \(fmtClock(s.start))–\(fmtClock(s.end))")
                                    .font(Typo.num(10.5, .medium))
                                    .foregroundStyle(.tertiary)
                                if !s.room.isEmpty {
                                    Text(s.room).font(.system(size: 10)).foregroundStyle(.tertiary)
                                }
                            }
                            .frame(height: env.space(94), alignment: .top)
                        }
                        .appearIn(i + 2)
                    }
                }
            }
        }
    }
}
