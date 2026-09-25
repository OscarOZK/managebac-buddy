import SwiftUI
import AppKit

/* ======================================================================
   ① 待办页
   自上而下：大计时卡 → 概览磁贴 → 待办卡网格 → 逾期折叠区
   ====================================================================== */

struct TodoSection: View {
    @ObservedObject var store: DataStore
    @EnvironmentObject var settings: BoardSettings
    @Environment(\.colorScheme) private var scheme
    let now: Date
    var search: String = ""

    @State private var overdueOpen = true   // 自检临时

    private var env: Env { Env(scheme: scheme, settings: settings) }

    private var data: (up: [TaskVM], od: [TaskVM]) {
        var g = store.groups(now: now, settings: settings)
        let q = Search.parse(search)
        if !q.isEmpty {
            func hit(_ t: TaskVM) -> Bool {
                Search.hit(q, [t.title, t.subject, t.fullSubject, t.type, t.kind])
            }
            g = (g.up.filter(hit), g.od.filter(hit))
        }
        // 搜索时不做「最多显示 N 条」的截断，否则好不容易找到的会被切掉
        let limit = Int(settings.taskLimit)
        if limit > 0 && q.isEmpty { g.up = Array(g.up.prefix(limit)) }
        return g
    }

    var body: some View {
        let g = data
        VStack(alignment: .leading, spacing: settings.density.sectionGap) {
            hero
            stats(g)
            list(g)
        }
    }

    /* ---------------- 大计时卡 ---------------- */

    private var hero: some View {
        let tt = Schedule.topTimer(now, settings)
        var big = "好好休息"
        var bigSize: CGFloat = 46
        var name = ""
        var right = ""
        var detail = ""
        var where_ = ""
        var tint: Color? = nil
        var accentRGB = settings.accent
        let caption = tt.label(settings)

        switch tt {
        case .rest:
            bigSize = 38
        case .inClass(let s):
            big = hms(s.end.timeIntervalSince(now) * 1000)
            name = s.isFree ? "没有安排课程" : s.subject
            right = "\(s.pLabel) \(fmtClock(s.start))–\(fmtClock(s.end))"
            where_ = [s.room, s.teacher, s.mode].filter { !$0.isEmpty }.joined(separator: " · ")
            accentRGB = RGB(s.hex)
            tint = accentRGB.color(scheme, lift: 0.86, opacity: scheme == .dark ? 0.20 : 0.26)
        case .breakTime(let n, let since):
            big = hms(n.start.timeIntervalSince(now) * 1000)
            name = n.subject
            right = "\(n.pLabel) \(fmtClock(n.start))–\(fmtClock(n.end))"
            where_ = [n.room, n.teacher, n.mode].filter { !$0.isEmpty }.joined(separator: " · ")
            if let since {
                let gap = n.start.timeIntervalSince(since)
                let passed = now.timeIntervalSince(since)
                detail = "本次休息共 \(Int((gap / 60).rounded())) 分钟 · 已过 \(hms(passed * 1000))"
            }
            accentRGB = settings.accent
            tint = settings.accent.color(scheme, lift: 0.86, opacity: scheme == .dark ? 0.20 : 0.24)
        case .studyEnd(let d):
            big = hms(d.timeIntervalSince(now) * 1000)
            name = "晚自习"
            right = "\(settings.nightEnd) 结束"
            tint = settings.accent.color(scheme, lift: 0.86, opacity: scheme == .dark ? 0.18 : 0.20)
        case .studyStart(let d):
            big = hms(d.timeIntervalSince(now) * 1000)
            name = "晚自习"
            right = "\(settings.nightStart) 开始"
            tint = settings.accent.color(scheme, lift: 0.86, opacity: scheme == .dark ? 0.18 : 0.20)
        }

        return GlassCard(env: env, radius: Radius.lg, tint: tint) {
            VStack(alignment: .leading, spacing: env.space(10)) {
                HStack(spacing: 8) {
                    Image(systemName: Icons.bolt)
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(accentRGB.color(scheme, lift: 0.14))
                    Text(caption)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(accentRGB.color(scheme, lift: 0.14))
                    Spacer(minLength: 8)
                    if !right.isEmpty {
                        Text(right)
                            .font(Typo.num(12, .medium))
                            .foregroundStyle(.secondary)
                    }
                }

                HStack(alignment: .firstTextBaseline, spacing: 14) {
                    Text(big)
                        .font(.system(size: bigSize, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(Theme.ink(scheme))
                        .contentTransition(.numericText(countsDown: true))
                    if !name.isEmpty {
                        Text(name)
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundStyle(Theme.ink(scheme))
                            .lineLimit(1)
                    }
                    Spacer(minLength: 8)
                    Text(fmtClock(now))
                        .font(Typo.num(15, .semibold))
                        .foregroundStyle(.tertiary)
                }

                if !detail.isEmpty || !where_.isEmpty {
                    VStack(alignment: .leading, spacing: 3) {
                        if !detail.isEmpty {
                            Text(detail).font(.system(size: 11.5)).foregroundStyle(.secondary)
                        }
                        if !where_.isEmpty {
                            HStack(spacing: 10) {
                                Label(where_, systemImage: Icons.room)
                                    .font(.system(size: 11.5))
                                    .foregroundStyle(.tertiary)
                            }
                        }
                    }
                }
            }
        }
        .appearIn(0)
    }

    /* ---------------- 概览磁贴 ---------------- */

    private func stats(_ g: (up: [TaskVM], od: [TaskVM])) -> some View {
        let in24 = g.up.filter { ($0.leftMs ?? .greatestFiniteMagnitude) <= 24 * 3_600_000 }.count
        let inWeek = g.up.filter { ($0.leftMs ?? .greatestFiniteMagnitude) <= 7 * 24 * 3_600_000 }.count
        let graded = store.recentWorks(200, settings: settings).count

        let tiles: [(String, String, String, RGB, String)] = [
            ("待完成", "\(g.up.count)", "项", settings.accent, Icons.todo),
            ("24 小时内", "\(in24)", "项", Theme.redDefault, Icons.bolt),
            ("本周内", "\(inWeek)", "项", Theme.amberDefault, Icons.clock),
            ("已出分", "\(graded)", "项", Theme.greenDefault, Icons.grades),
        ]

        return HStack(spacing: env.space(12)) {
            ForEach(Array(tiles.enumerated()), id: \.offset) { idx, t in
                GlassCard(env: env, radius: Radius.md, padding: env.space(14)) {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 6) {
                            Image(systemName: t.4)
                                .font(.system(size: 10, weight: .bold))
                                .foregroundStyle(t.3.color(scheme, lift: 0.16))
                            Text(t.0)
                                .font(.system(size: 11.5, weight: .medium))
                                .foregroundStyle(.secondary)
                            Spacer(minLength: 0)
                        }
                        HStack(alignment: .firstTextBaseline, spacing: 4) {
                            Text(t.1)
                                .font(.system(size: 27, weight: .bold, design: .rounded))
                                .monospacedDigit()
                                .foregroundStyle(Theme.ink(scheme))
                                .contentTransition(.numericText())
                            Text(t.2)
                                .font(.system(size: 11.5))
                                .foregroundStyle(.tertiary)
                        }
                    }
                }
                .appearIn(1 + idx)
            }
        }
    }

    /* ---------------- 待办网格 ---------------- */

    private func list(_ g: (up: [TaskVM], od: [TaskVM])) -> some View {
        VStack(alignment: .leading, spacing: env.space(14)) {
            SectionHeader(title: "待办事项",
                          subtitle: g.up.isEmpty ? "" : "\(g.up.count) 项待完成 · 点卡片看详情，右下按钮打开原网页",
                          icon: Icons.todo)

            if g.up.isEmpty {
                GlassCard(env: env, radius: Radius.md) {
                    EmptyState(env: env,
                               icon: store.isPreparing ? "hourglass" : "checkmark.seal",
                               title: store.isPreparing ? "正在同步，几秒就好…" : "没有待完成的作业",
                               detail: store.isPreparing ? "数据正在后台读取，好了就自动显示" : "可以安心休息一下")
                }
            } else {
                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: 316, maximum: 460), spacing: env.space(14))],
                    spacing: env.space(14)
                ) {
                    ForEach(Array(g.up.enumerated()), id: \.element.id) { i, t in
                        TaskCard(t: t, now: now)
                            .appearIn(min(10, i))
                    }
                }
            }

            if !g.od.isEmpty {
                overdueBlock(g.od)
            }
        }
    }

    private func overdueBlock(_ od: [TaskVM]) -> some View {
        VStack(alignment: .leading, spacing: env.space(12)) {
            Button {
                withAnimation(Motion.reveal) { overdueOpen.toggle() }
            } label: {
                HStack(spacing: 9) {
                    Image(systemName: Icons.warn)
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.redDefault.color(scheme, lift: 0.18))
                    Text("已逾期 \(od.count) 项")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Theme.ink(scheme))
                    Spacer(minLength: 8)
                    Text(overdueOpen ? "收起" : "展开")
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(.secondary)
                        .contentTransition(.interpolate)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.tertiary)
                        // 转过去而不是换个字：展开这个动作本身就是一段动画
                        .rotationEffect(.degrees(overdueOpen ? 180 : 0))
                }
                .padding(.horizontal, env.space(14))
                .frame(height: env.space(42))
                .contentShape(RoundedRectangle(cornerRadius: env.radius(Radius.md), style: .continuous))
            }
            .buttonStyle(.plain)
            .card(env.radius(Radius.md),
                  tint: Theme.redDefault.color(scheme, lift: 0.86, opacity: scheme == .dark ? 0.12 : 0.10),
                  look: env.look)

            if overdueOpen {
                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: 316, maximum: 460), spacing: env.space(14))],
                    spacing: env.space(14)
                ) {
                    ForEach(od) { t in TaskCard(t: t, now: now) }
                }
                .transition(.reveal)
            }
        }
    }
}

/* ======================================================================
   待办卡
   形态：左色条 + 学科/类型/紧急度徽章 + 标题 + 紧急度进度条 + 截止/剩余
   ====================================================================== */

struct TaskCard: View {
    let t: TaskVM
    let now: Date
    @EnvironmentObject var settings: BoardSettings
    @Environment(\.colorScheme) private var scheme
    @State private var hovering = false

    private var env: Env { Env(scheme: scheme, settings: settings) }

    /// 0…1，越接近 1 越紧迫（用于进度条可视化）
    private var urgency: Double {
        if t.isOver { return 1 }
        guard let l = t.leftMs else { return 0 }
        let full = settings.blueHours * 3_600_000
        return 1 - min(1, max(0, l / full))
    }

    var body: some View {
        let c = t.band.color(scheme, accent: settings.accent)
        let subjectRGB = Subject.rgb(Subject.key(t.fullSubject), settings)

        Button {
            // 点卡片主体 → 弹液态玻璃详情单（挂在窗口根部的 TaskDetailHost 画）
            TaskDetailCenter.shared.open(t)
        } label: {
            HStack(spacing: 0) {
                Capsule()
                    .fill(LinearGradient(colors: [c, c.opacity(0.55)],
                                         startPoint: .top, endPoint: .bottom))
                    .frame(width: 4)
                    .padding(.vertical, 12)
                    .padding(.leading, 3)

                VStack(alignment: .leading, spacing: env.space(9)) {
                    HStack(spacing: 7) {
                        Circle()
                            .fill(subjectRGB.color(scheme, lift: 0.14))
                            .frame(width: 7, height: 7)
                        Text(t.subject)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(subjectRGB.color(scheme, lift: 0.12))
                            .lineLimit(1)
                            .truncationMode(.tail)
                            // 长科名（Cross-Disciplinary Studies）不设上限的话会顶满，
                            // 把右边的 kind 挤成贴住、看不出是两个字段
                            .frame(maxWidth: 150, alignment: .leading)
                        if !t.kind.isEmpty {
                            // 加个中点分隔：否则「科名」和「类型」挨在一起读成一句话
                            Text("·")
                                .font(.system(size: 10, weight: .medium))
                                .foregroundStyle(.quaternary)
                            Text(t.kind)
                                .font(.system(size: 10, weight: .medium))
                                .foregroundStyle(.tertiary)
                                .lineLimit(1)
                                .truncationMode(.tail)
                                .layoutPriority(-1)
                        }
                        Spacer(minLength: 6)
                        Pill(env: env, text: t.band.name, color: t.isOver ? Theme.redDefault
                                 : (t.band == .urgent ? Theme.redDefault
                                    : (t.band == .soon ? Theme.amberDefault : settings.accent)),
                             bold: true)
                    }

                    Text(t.title)
                        .font(.system(size: 14.5, weight: .semibold))
                        .foregroundStyle(Theme.ink(scheme))
                        .lineLimit(3)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    Spacer(minLength: 2)

                    MiniBar(env: env, value: urgency, color: t.isOver ? Theme.redDefault
                            : (t.band == .urgent ? Theme.redDefault
                               : (t.band == .soon ? Theme.amberDefault : settings.accent)))

                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        HStack(spacing: 5) {
                            Image(systemName: Icons.clock).font(.system(size: 9.5))
                            Text(t.due.map(shortDueDate) ?? "未设截止")
                                .font(Typo.num(11.5, .medium))
                        }
                        .foregroundStyle(.tertiary)
                        Spacer(minLength: 6)
                        Text(t.leftText)
                            .font(.system(size: 12, weight: .bold))
                            .monospacedDigit()
                            .foregroundStyle(c)

                        // 逾期作业：给一个删除入口（两次确认，可在设置里找回）。
                        // 只给逾期的 —— 未到期的还能做，摆个删除在旁边是诱惑。
                        if t.isOver {
                            TaskDeleteButton(task: t, compact: true)
                        }

                        // 独立的「打开」按钮 —— 只有点它才跳 ManageBac 原网页；
                        // 点卡片其余任何地方都是弹详情单。
                        // 用户要求做得大一些：加高加宽、字大一号、悬停整块上色。
                        Button {
                            LinkOpen.go(t.url, source: "managebac", settings: settings)
                        } label: {
                            HStack(spacing: 6) {
                                Image(systemName: "arrow.up.forward")
                                    .font(.system(size: 12, weight: .bold))
                                Text("打开网页")
                                    .font(.system(size: 12.5, weight: .bold))
                            }
                            .foregroundStyle(hovering ? Color.white : c)
                            .padding(.horizontal, 16)
                            .frame(height: 32)
                            .background {
                                Capsule().fill(hovering ? c : c.opacity(0.12))
                            }
                            .contentShape(Capsule())
                        }
                        .buttonStyle(.plain)
                        .animation(Motion.hover, value: hovering)
                        .help("在 ManageBac 中打开原网页")
                        .accessibilityLabel("在 ManageBac 中打开")
                    }
                }
                .padding(.horizontal, env.space(13))
                .padding(.vertical, env.space(12))
            }
            .frame(height: env.space(156), alignment: .top)
            .contentShape(RoundedRectangle(cornerRadius: env.radius(Radius.md), style: .continuous))
        }
        .buttonStyle(.plain)
        .card(env.radius(Radius.md),
              tint: hovering ? c.opacity(scheme == .dark ? 0.16 : 0.10) : nil,
              look: env.look)
        .hoverLift(3)
        .onHover { hovering = $0 }
        .help("\(t.fullSubject)\n\(t.title)\n\(t.due.map(shortDueDate) ?? "未设截止") · \(t.leftText)\n点卡片看详情；「打开」跳原网页")
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(t.subject) \(t.title)，\(t.leftText)")
        .accessibilityHint("点卡片看详情，右下「打开」跳原网页")
    }
}
