import SwiftUI
import AppKit

/* 完整看板 App 的位置（底部长条按钮跳过去）
   路径走 $HOME 推导 + 环境变量可覆盖，不写死用户名。 */
let kDashboardApp: String = ProcessInfo.processInfo.environment["MBB_DASHBOARD_APP"]
    ?? (NSHomeDirectory() as NSString).appendingPathComponent("Desktop/APP/ManageBac看板.app")
let kDashboardWeb = "http://127.0.0.1:8765/app"

/// 蓝色玻璃着色（倒计时卡 / 底部展开条）
func accentTint(_ opacity: Double = 0.30) -> Color {
    Color(.sRGB, red: 0.0, green: 0.44, blue: 1.0, opacity: opacity)
}

/* ============================================================
   面板根视图

   自上而下：
   ① 顶栏（📂 ManageBac · 更新时间 · 状态 · ✕）
   ② 大计时卡（放在最上面：上课→距下课；课间→距上课）
   ③ 待办事项（按剩余时间从少到多，带作业名）
   ④ 接下来的课堂（今天/明天整日课程，进行中的课高亮）
   ⑤ 最新成绩（最近出分 8 项，4×2）
   ⑥ GPA 总览（默认折叠，折叠时不显示总均分）
   ⑦ 底部细长「展开」条
   ============================================================ */
struct PanelView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var scheme

    @ObservedObject private var store: Store
    @State private var confirmingQuit = false
    @State private var gpaOpen = PreviewFlags.gpaExpanded
    @State private var overdueOpen = PreviewFlags.overdueExpanded
    /// 秒级时钟：倒计时 / 「正在上课」高亮都靠它（自检时可由 PreviewFlags 定住）
    @State private var now = PreviewFlags.nowOverride ?? Date()

    /// 正常运行与菜单栏角标共用 Store.shared；离屏渲染自检时注入一个已装好数据的 Store
    init(store: Store) {
        _store = ObservedObject(wrappedValue: store)
    }

    var body: some View {
        VStack(spacing: 10) {
            header
            content
            bottomBar
        }
        .padding(Panel.pad)
        .frame(width: Panel.width, height: PreviewFlags.fullHeight ? nil : Panel.height)
        .task { await store.start() }
        // 每次展开面板都顺手刷新一次（bridge 有 60s 缓存，代价很低）
        .onAppear {
            if PreviewFlags.nowOverride == nil { now = Date() }
            Task { await store.load() }
        }
        .onReceive(Timer.publish(every: 1, on: .main, in: .common).autoconnect()) { t in
            if PreviewFlags.nowOverride == nil { now = t }
        }
        // 面板长期开着时每 5 分钟自动更新一次
        .onReceive(Timer.publish(every: 300, on: .main, in: .common).autoconnect()) { _ in
            Task { await store.load() }
        }
    }

    /* ---------------- ① 顶部 ---------------- */

    private var header: some View {
        HStack(spacing: 10) {
            Text("📂")
                .font(.system(size: 22))
            VStack(alignment: .leading, spacing: 2) {
                Text("ManageBac")
                    .font(.system(size: 15, weight: .semibold))
                Text(store.subtitle)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 6)
            HStack(spacing: 5) {
                Circle()
                    .fill(store.statusColor(scheme))
                    .frame(width: 6, height: 6)
                Text(store.status.text)
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            Button(action: { confirmingQuit = true }) {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.secondary)
                    .frame(width: 26, height: 26)
                    .contentShape(.circle)
            }
            .buttonStyle(.plain)
            .glassSurface(Circle())
            .help("退出菜单栏应用")
        }
    }

    /* ---------------- 中间滚动内容 ---------------- */

    private var content: some View {
        Group {
            if PreviewFlags.noScroll {
                contentStack
            } else {
                ScrollView(.vertical) { contentStack }
                    .scrollIndicators(.automatic)
            }
        }
        .frame(maxHeight: .infinity)
    }

    private var contentStack: some View {
        VStack(alignment: .leading, spacing: 14) {
            topTimerCard(now: now)
            todoSection
            classSection(now: now)
            latestSection
            gpaSection
        }
        .padding(.horizontal, 1)
        .padding(.vertical, 2)
    }

    /* ---------------- ② 最上面的大计时 ---------------- */

    private func topTimerCard(now: Date) -> some View {
        let tt = Schedule.topTimer(now)

        var big = "好好休息"
        var bigSize: CGFloat = 25
        var name = ""
        var where_ = ""
        var detail = ""
        var right = ""
        var tint: Color? = nil

        switch tt {
        case .rest:
            bigSize = 20

        case .inClass(let s):
            big = hms(s.end.timeIntervalSince(now) * 1000)
            name = s.isFree ? "没有安排课程" : s.subject
            right = "\(s.pLabel) \(fmtClock(s.start))–\(fmtClock(s.end))"
            where_ = [s.room, s.teacher, s.mode].filter { !$0.isEmpty }.joined(separator: " · ")
            tint = RGB(s.hex).color(scheme, lift: 0.86,
                                   opacity: scheme == .dark ? 0.22 : 0.30)

        case .breakTime(let n, let since):
            big = hms(n.start.timeIntervalSince(now) * 1000)
            name = n.subject
            right = "\(n.pLabel) \(fmtClock(n.start))–\(fmtClock(n.end))"
            where_ = [n.room, n.teacher, n.mode].filter { !$0.isEmpty }.joined(separator: " · ")
            if let since {
                let gap = n.start.timeIntervalSince(since)
                let passed = now.timeIntervalSince(since)
                detail = "本次休息共 \(Int((gap / 60).rounded())) 分钟 · 已过 \(hms(passed * 1000).suffix(5))"
            }
            tint = accentTint()

        case .studyEnd(let d):
            big = hms(d.timeIntervalSince(now) * 1000)
            name = "晚自习"
            right = "22:30 结束"

        case .studyStart(let d):
            big = hms(d.timeIntervalSince(now) * 1000)
            name = "晚自习"
            right = "18:30 开始"
        }

        return VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(tt.label)
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 4)
                if !right.isEmpty {
                    Text(right)
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(.tertiary)
                        .monospacedDigit()
                }
            }

            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(big)
                    .font(.system(size: bigSize, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(.primary)
                if !name.isEmpty {
                    Text(name)
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1)
                }
                Spacer(minLength: 4)
            }

            if !detail.isEmpty {
                Text(detail)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            if !where_.isEmpty {
                Text(where_)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 13)
        .padding(.vertical, 11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassSurface(RoundedRectangle(cornerRadius: 15), tint: tint)
    }

    /* ---------------- ③ 待办 ---------------- */

    private var todoSection: some View {
        let g = store.groups(now: now)
        return VStack(alignment: .leading, spacing: 7) {
            sectionHead("待办事项",
                       right: "\(g.up.count) 项待完成" + (g.od.isEmpty ? "" : " · \(g.od.count) 项逾期"))

            if g.up.isEmpty && g.od.isEmpty {
                emptyRow(store.payload == nil ? "正在读取…" : "暂无待办")
            } else {
                GlassEffectContainer(spacing: 7) {
                    VStack(spacing: 7) {
                        ForEach(g.up) { t in TaskBar(t: t, scheme: scheme) }
                    }
                }
            }

            if !g.up.isEmpty {
                Text("点任意一条 → 在 ManageBac 中打开")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }

            if !g.od.isEmpty {
                overdueToggle(count: g.od.count)
                if overdueOpen {
                    GlassEffectContainer(spacing: 7) {
                        VStack(spacing: 7) {
                            ForEach(g.od) { t in TaskBar(t: t, scheme: scheme) }
                        }
                    }
                }
            }
        }
    }

    private func overdueToggle(count: Int) -> some View {
        Button(action: {
            withAnimation(.snappy(duration: 0.22)) { overdueOpen.toggle() }
        }) {
            HStack(spacing: 7) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.red.color(scheme, lift: 0.18))
                Text("已逾期 \(count) 项")
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 4)
                Image(systemName: overdueOpen ? "chevron.up" : "chevron.down")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 11)
            .frame(height: 30)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(.rect(cornerRadius: 11))
        }
        .buttonStyle(.plain)
        .glassSurface(RoundedRectangle(cornerRadius: 11))
    }

    /* ---------------- ④ 接下来的课堂（整日） ---------------- */

    private func classSection(now: Date) -> some View {
        let dl = Schedule.dayList(now)
        let cur = Schedule.currentSlot(now)
        let curBlock = cur?.blockId
        // 「现在」横条的位置：插在「已经上完的课」之后，也就是正在进行的那节课的正上方。
        // 只有当前时间落在「第一节课开始之前」或「最后一节课结束之后」才隐藏（那时它没有信息量）。
        let nowIdx: Int? = {
            guard Calendar.current.isDate(dl.day, inSameDayAs: now),
                  let first = dl.list.first, let last = dl.list.last,
                  now >= first.start, now < last.end else { return nil }
            return dl.list.filter { $0.end <= now }.count
        }()
        return VStack(alignment: .leading, spacing: 7) {
            sectionHead("接下来的课堂", right: Schedule.dayCaption(dl.day, now: now))

            GlassEffectContainer(spacing: 6) {
                VStack(spacing: 6) {
                    ForEach(Array(dl.list.enumerated()), id: \.element.id) { i, s in
                        if nowIdx == i { nowBar(now: now, cur: cur) }
                        ClassRow(slot: s, now: now, isNow: curBlock != nil && s.blockId == curBlock)
                    }
                }
            }
        }
    }

    /* 「现在」横条：原生液态玻璃胶囊 + 该课颜色的细描边，标出当前时间落在课表的哪个位置 */
    private func nowBar(now: Date, cur: Schedule.Slot?) -> some View {
        let c = RGB(cur?.hex ?? "#007aff").color(scheme, lift: 0.14)
        return HStack(spacing: 7) {
            Circle()
                .fill(c)
                .frame(width: 6, height: 6)
            Text("现在 \(fmtClock(now))")
                .font(.system(size: 10.5, weight: .bold))
                .monospacedDigit()
                .foregroundStyle(c)
            Text(cur.map { "\($0.subject) · 进行中" } ?? "课间休息")
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer(minLength: 4)
        }
        .padding(.horizontal, 11)
        .frame(height: 24)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassSurface(Capsule(), tint: c.opacity(scheme == .dark ? 0.20 : 0.15))
        .overlay(Capsule().stroke(c.opacity(0.55), lineWidth: 1))
    }

    /* ---------------- ⑤ 最新成绩（最近出分 8 项，4×2） ---------------- */

    private var gridCardW: CGFloat { (Panel.width - 2 * Panel.pad - 3 * 8) / 4 }
    private var gridCardH: CGFloat { 101 }

    private var latestSection: some View {
        let rows = store.recentWorks(8)
        let rowCount = (rows.count + 3) / 4
        return VStack(alignment: .leading, spacing: 7) {
            sectionHead("最新成绩", right: rows.isEmpty ? "" : "最近出分 \(rows.count) 项")

            if rows.isEmpty {
                emptyRow(store.payload == nil ? "正在读取…" : "暂无已评分作业")
            } else {
                GlassEffectContainer(spacing: 8) {
                    VStack(spacing: 8) {
                        ForEach(0..<rowCount, id: \.self) { r in
                            HStack(spacing: 8) {
                                ForEach(0..<4, id: \.self) { c in
                                    let i = r * 4 + c
                                    if i < rows.count {
                                        LatestCard(w: rows[i], scheme: scheme)
                                    } else {
                                        Color.clear
                                            .frame(width: gridCardW, height: gridCardH)
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    /* ---------------- ⑥ GPA 总览 ---------------- */

    private var gpaSection: some View {
        let rows = store.gpaRows()
        let sm = store.gpaSummary
        return VStack(alignment: .leading, spacing: 7) {
            sectionHead("GPA 总览", right: "\(sm.graded)/\(sm.total) 门已出分")

            Button(action: { withAnimation(.snappy(duration: 0.22)) { gpaOpen.toggle() } }) {
                HStack(spacing: 8) {
                    if gpaOpen {
                        Text("总均分")
                            .font(.system(size: 12.5, weight: .medium))
                            .foregroundStyle(.secondary)
                        if let avg = sm.avg {
                            Text(fmtPct(avg))
                                .font(.system(size: 16, weight: .bold, design: .rounded))
                                .monospacedDigit()
                                .foregroundStyle(Theme.accent.color(scheme, lift: 0.22))
                            Text("\(to4(avg / 100)) / 4.0")
                                .font(.system(size: 11.5, weight: .semibold))
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                        } else {
                            Text("暂无成绩").font(.system(size: 12.5)).foregroundStyle(.tertiary)
                        }
                    } else {
                        Text("查看各科分数与 4 分制折算")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 4)
                    HStack(spacing: 4) {
                        Text(gpaOpen ? "收起" : "展开")
                            .font(.system(size: 11, weight: .semibold))
                        Image(systemName: gpaOpen ? "chevron.up" : "chevron.down")
                            .font(.system(size: 9, weight: .bold))
                    }
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 9)
                    .frame(height: 24)
                    .background(Capsule().fill(Color.primary.opacity(0.07)))
                }
                .padding(.horizontal, 13)
                .frame(height: gpaOpen ? 46 : 38)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(.rect(cornerRadius: 13))
            }
            .buttonStyle(.plain)
            .glassSurface(RoundedRectangle(cornerRadius: 13))

            if gpaOpen {
                GlassEffectContainer(spacing: 6) {
                    VStack(spacing: 6) {
                        ForEach(rows) { r in GPARowView(r: r, scheme: scheme) }
                    }
                }
            }
        }
    }

    /* ---------------- ⑦ 底部细长条 / 退出确认（同高，切换不跳） ---------------- */

    private static let barH: CGFloat = 32

    private var bottomBar: some View {
        Group {
            if confirmingQuit { confirmBar } else { expandButton }
        }
        .frame(height: PanelView.barH)
    }

    private var expandButton: some View {
        Button(action: openDashboard) {
            HStack(spacing: 7) {
                Image(systemName: "arrow.up.forward.square")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
                Text("展开完整看板")
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(.primary)
                Spacer(minLength: 4)
                Text("待办 · 课程 · 成绩")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.tertiary)
                Image(systemName: "arrow.up.forward")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(height: PanelView.barH)
            .contentShape(.rect(cornerRadius: 11))
        }
        .buttonStyle(.plain)
        .glassSurface(RoundedRectangle(cornerRadius: 11), tint: accentTint(0.22))
    }

    private var confirmBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.circle.fill")
                .font(.system(size: 12))
                .foregroundStyle(Theme.amber.color(scheme, lift: 0.12))
            Text("确定退出菜单栏应用？")
                .font(.system(size: 12, weight: .semibold))
            Spacer(minLength: 4)
            Button("取消") { confirmingQuit = false }
                .buttonStyle(.plain)
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 10)
                .frame(height: 24)
                .background(Capsule().fill(Color.primary.opacity(0.07)))
            Button("退出") { NSApp.terminate(nil) }
                .buttonStyle(.plain)
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(Theme.red.color(scheme, lift: 0.14))
                .padding(.horizontal, 10)
                .frame(height: 24)
                .background(Capsule().fill(Theme.red.color(scheme, lift: 0.14).opacity(0.13)))
        }
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: PanelView.barH)
        .contentShape(.rect(cornerRadius: 11))
        .glassSurface(RoundedRectangle(cornerRadius: 11))
    }

    /* ---------------- 零件 ---------------- */

    private func sectionHead(_ title: String, right: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(title)
                .font(.system(size: 12.5, weight: .semibold))
            Spacer(minLength: 4)
            Text(right)
                .font(.system(size: 10.5))
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 2)
        .padding(.top, 1)
    }

    private func emptyRow(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 12))
            .foregroundStyle(.tertiary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 13)
            .frame(height: 40)
            .glassSurface(RoundedRectangle(cornerRadius: 13))
    }

    /* ---------------- 动作 ---------------- */

    private func openDashboard() {
        if FileManager.default.fileExists(atPath: kDashboardApp) {
            let cfg = NSWorkspace.OpenConfiguration()
            cfg.activates = true
            NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: kDashboardApp),
                                               configuration: cfg) { _, _ in }
        } else if let web = URL(string: kDashboardWeb) {
            NSWorkspace.shared.open(web)
        }
        dismiss()
    }
}

/* ============================================================
   待办长条：色条 + 学科 + 作业名（正文前段，放不下省略）+ 剩余时间
   ============================================================ */
struct TaskBar: View {
    let t: TaskVM
    let scheme: ColorScheme

    var body: some View {
        let c = t.band.color(scheme)
        Button(action: { NSWorkspace.shared.open(t.url) }) {
            HStack(spacing: 9) {
                Capsule()
                    .fill(c)
                    .frame(width: 3.5, height: 18)
                Text(t.subject)
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .frame(width: 32, alignment: .leading)
                Text(t.title)
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 6)
                Text(t.leftText)
                    .font(.system(size: 11.5, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(c)
                    .lineLimit(1)
                    .fixedSize()
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3.5)
                    .background(Capsule().fill(c.opacity(0.14)))
            }
            .padding(.horizontal, 11)
            .frame(height: 40)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(.rect(cornerRadius: 13))
        }
        .buttonStyle(.plain)
        .glassSurface(RoundedRectangle(cornerRadius: 13))
        .help("\(t.fullSubject)\n\(t.title)\n点击在 ManageBac 中打开")
    }
}

/* ============================================================
   课程行（整日列表；正在进行的课用颜色高亮）
   ============================================================ */
struct ClassRow: View {
    @Environment(\.colorScheme) private var scheme
    let slot: Schedule.Slot
    let now: Date
    var isNow: Bool = false

    var body: some View {
        let sameDay = Calendar.current.isDate(slot.start, inSameDayAs: now)
        let pr = slot.span[0] == slot.span[1] ? "P\(slot.span[0])" : "P\(slot.span[0])–P\(slot.span[1])"
        let time = "\(fmtClock(slot.start))–\(fmtClock(slot.end))"
        let rgb = RGB(slot.hex)
        let isDouble = slot.span[1] > slot.span[0]      // 连堂（P7–P8）前面画两根竖条
        let barW: CGFloat = isNow ? 5 : 3.5
        let barH: CGFloat = isNow ? 18 : 16

        return HStack(spacing: 8) {
            // 固定 12pt 宽的竖条区，保证后面 P/时间两列在所有行都对齐
            HStack(spacing: 2) {
                Capsule()
                    .fill(rgb.color(scheme, lift: 0.12))
                    .frame(width: barW, height: barH)
                if isDouble {
                    Capsule()
                        .fill(rgb.color(scheme, lift: 0.12))
                        .frame(width: barW, height: barH)
                }
                Spacer(minLength: 0)
            }
            .frame(width: 12)
            Text(pr)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 40, alignment: .leading)
            Text(time)
                .font(.system(size: 10.5))
                .monospacedDigit()
                .foregroundStyle(.tertiary)
                .frame(width: 96, alignment: .leading)
            Text(slot.subject)
                .font(.system(size: 12, weight: isNow ? .semibold : .medium))
                .foregroundStyle(slot.isFree ? Color.secondary : Color.primary)
                .lineLimit(1)
                .layoutPriority(1)
            Spacer(minLength: 4)
            if isNow {
                Text("进行中")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(rgb.color(scheme, lift: 0.16))
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2.5)
                    .background(Capsule().fill(rgb.color(scheme, lift: 0.16).opacity(0.18)))
            } else {
                Text(slot.isFree ? "没有安排课程"
                                 : [slot.room, slot.teacher].filter { !$0.isEmpty }.joined(separator: " · "))
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        }
        .padding(.horizontal, 11)
        .frame(height: 32)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassSurface(RoundedRectangle(cornerRadius: 11),
                      tint: isNow ? rgb.color(scheme, lift: 0.86,
                                              opacity: scheme == .dark ? 0.22 : 0.30) : nil)
        .help(sameDay ? "" : "\(Calendar.current.component(.month, from: slot.start))/\(Calendar.current.component(.day, from: slot.start))")
    }
}

/* ============================================================
   最新成绩：正方形圆角方块（科目 / 作业名 / 截止 / 等级 + 分数）
   ============================================================ */
struct LatestCard: View {
    let w: RecentVM
    let scheme: ColorScheme

    var body: some View {
        let c = w.rgb.color(scheme, lift: 0.18)
        let scoreColor = w.good ? Theme.green.color(scheme, lift: 0.10)
                                : Theme.amber.color(scheme, lift: 0.10)

        Button(action: { if let u = w.url { NSWorkspace.shared.open(u) } }) {
            VStack(alignment: .leading, spacing: 3) {
                Text(w.label)
                    .font(.system(size: 9.5, weight: .bold))
                    .foregroundStyle(c)
                    .lineLimit(1)

                Text(w.title)
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(3)
                    .multilineTextAlignment(.leading)
                    .truncationMode(.tail)
                    .fixedSize(horizontal: false, vertical: true)

                Spacer(minLength: 0)

                Text(w.dueText)
                    .font(.system(size: 9))
                    .monospacedDigit()
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)

                HStack(spacing: 3) {
                    if let g = w.grade {
                        Text(g)
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(scoreColor)
                    }
                    Text(w.scoreText)
                        .font(.system(size: 10, weight: .semibold))
                        .monospacedDigit()
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                }
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 8)
            .frame(width: (Panel.width - 2 * Panel.pad - 24) / 4, height: 101, alignment: .topLeading)
            .contentShape(.rect(cornerRadius: 13))
        }
        .buttonStyle(.plain)
        .glassSurface(RoundedRectangle(cornerRadius: 13))
        .help("\(w.label) · \(w.title)\n\(w.dueText) · \(w.grade ?? "") \(w.scoreText)\n点击在 ManageBac 中打开")
    }
}

/* ============================================================
   GPA 单科一行（无柱状图；4 分制必留）
   ============================================================ */
struct GPARowView: View {
    let r: GPARowModel
    let scheme: ColorScheme

    var body: some View {
        Button(action: { if let u = r.url { NSWorkspace.shared.open(u) } }) {
            HStack(spacing: 8) {
                Circle()
                    .fill(r.rgb.color(scheme, lift: 0.18))
                    .frame(width: 7, height: 7)
                Text(r.label)
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(.primary)
                    .frame(width: 34, alignment: .leading)
                Spacer(minLength: 4)
                if let p = r.pct {
                    Text(fmtPct(p))
                        .font(.system(size: 12.5, weight: .semibold))
                        .monospacedDigit()
                        .foregroundStyle(r.rgb.color(scheme, lift: 0.18))
                    Text(r.grade ?? "")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.secondary)
                        .frame(minWidth: 20)
                        .padding(.vertical, 2)
                        .padding(.horizontal, 5)
                        .background(Capsule().fill(r.rgb.color(scheme, lift: 0.18).opacity(0.15)))
                    Text("\(to4(p / 100)) / 4.0")
                        .font(.system(size: 10.5, weight: .medium))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .frame(width: 58, alignment: .trailing)
                } else {
                    Text("未出分")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                        .frame(width: 128, alignment: .trailing)
                }
            }
            .padding(.horizontal, 11)
            .frame(height: 32)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(.rect(cornerRadius: 11))
        }
        .buttonStyle(.plain)
        .glassSurface(RoundedRectangle(cornerRadius: 11))
        .help("点击查看该课程的 core tasks")
    }
}

/* 类型别名，避免与视图同名冲突 */
typealias GPARow_Data = GPARowModel
