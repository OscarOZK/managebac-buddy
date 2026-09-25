import SwiftUI
import AppKit

/* ======================================================================
   ③ 成绩页
   GPA 总览（环形）→ 各科明细 → 最新出分
   ====================================================================== */

struct GradesSection: View {
    @ObservedObject var store: DataStore
    @EnvironmentObject var settings: BoardSettings
    @Environment(\.colorScheme) private var scheme
    /// 顶部搜索框的内容：在成绩页用来找课程 / 作业
    var search: String = ""

    private var env: Env { Env(scheme: scheme, settings: settings) }
    private var q: Search.Query { Search.parse(search) }

    var body: some View {
        VStack(alignment: .leading, spacing: settings.density.sectionGap) {
            overview
            classList
            recentGrid
        }
    }

    /* ---------------- 总览 ---------------- */

    private var overview: some View {
        let rows = store.gpaRows(settings: settings)
        let sm = store.gpaSummary
        let pcts = rows.compactMap { $0.pct }
        let best = pcts.max()
        let worst = pcts.min()

        return GlassCard(env: env, radius: Radius.lg, padding: env.space(24)) {
            HStack(alignment: .center, spacing: env.space(30)) {
                ZStack {
                    Donut(env: env, value: (sm.avg ?? 0) / 100, size: 150, line: 14,
                          color: settings.accent)
                    VStack(spacing: 1) {
                        Text(sm.avg.map(fmtPct) ?? "—")
                            .font(.system(size: 28, weight: .bold, design: .rounded))
                            .monospacedDigit()
                            .foregroundStyle(Theme.ink(scheme))
                            .contentTransition(.numericText())
                        Text("总均分")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.secondary)
                    }
                }

                VStack(alignment: .leading, spacing: env.space(14)) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("GPA 总览").font(Typo.title).foregroundStyle(Theme.ink(scheme))
                        Text("\(sm.graded)/\(sm.total) 门已出分 · 按各科 Overall 平均")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }

                    HStack(spacing: env.space(12)) {
                        metricTile("4 分制",
                                   sm.avg.map { to4($0 / 100) } ?? "—",
                                   "满分 4.0", settings.accent, Icons.gauge)
                        metricTile("最高", best.map(fmtPct) ?? "—", "单科最好", Theme.greenDefault, "arrow.up")
                        metricTile("最低", worst.map(fmtPct) ?? "—", "单科最弱", Theme.amberDefault, "arrow.down")
                    }
                }
                Spacer(minLength: 0)
            }
        }
        .appearIn(0)
    }

    private func metricTile(_ title: String, _ value: String, _ sub: String,
                            _ color: RGB, _ icon: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 5) {
                Image(systemName: icon).font(.system(size: 9.5, weight: .bold))
                    .foregroundStyle(color.color(scheme, lift: 0.16))
                Text(title).font(.system(size: 10.5, weight: .medium)).foregroundStyle(.secondary)
            }
            Text(value)
                .font(.system(size: 19, weight: .bold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(Theme.ink(scheme))
            Text(sub).font(.system(size: 10)).foregroundStyle(.tertiary)
        }
        .padding(.horizontal, env.space(13))
        .padding(.vertical, env.space(10))
        .frame(minWidth: 108, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: env.radius(Radius.sm), style: .continuous)
                .fill(Color.primary.opacity(scheme == .dark ? 0.07 : 0.045))
        }
    }

    /* ---------------- 各科明细 ---------------- */

    private var classList: some View {
        let all = store.gpaRows(settings: settings)
        let rows = q.isEmpty ? all : all.filter {
            Search.hit(q, [$0.label, $0.key, $0.grade])
        }
        return VStack(alignment: .leading, spacing: env.space(13)) {
            SectionHeader(title: q.isEmpty ? "各科明细" : "各科明细 · 匹配",
                          subtitle: q.isEmpty ? "点一行查看该课程全部作业"
                                              : "\(rows.count) 门课命中",
                          icon: Icons.grades)

            if rows.isEmpty {
                GlassCard(env: env, radius: Radius.md) {
                    EmptyState(env: env, icon: q.isEmpty ? "chart.bar" : Icons.search,
                               title: q.isEmpty ? "暂无课程数据" : "没有匹配的课程",
                               detail: q.isEmpty ? (store.payload == nil ? "正在读取…" : "尚未抓取到课程列表")
                                                 : "换个关键词试试")
                }
            } else {
                GlassCard(env: env, radius: Radius.lg, padding: env.space(10)) {
                    VStack(spacing: 4) {
                        ForEach(Array(rows.enumerated()), id: \.element.id) { i, r in
                            GradeRow(r: r, rank: i)
                        }
                    }
                }
            }
        }
        .appearIn(1)
    }

    /* ---------------- 最新出分 ---------------- */

    private var recentGrid: some View {
        let all = store.recentWorks(q.isEmpty ? 12 : 120, settings: settings)
        let items = q.isEmpty ? all : all.filter {
            Search.hit(q, [$0.title, $0.label, $0.grade, $0.scoreText])
        }
        return VStack(alignment: .leading, spacing: env.space(13)) {
            SectionHeader(title: q.isEmpty ? "最新出分" : "最新出分 · 匹配",
                          subtitle: items.isEmpty ? "" : "最近 \(items.count) 项",
                          icon: "sparkles")

            if items.isEmpty {
                GlassCard(env: env, radius: Radius.md) {
                    EmptyState(env: env, icon: q.isEmpty ? "tray" : Icons.search,
                               title: q.isEmpty ? "暂无已评分作业" : "没有匹配的作业",
                               detail: q.isEmpty ? "" : "换个关键词试试")
                }
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 208, maximum: 300), spacing: env.space(12))],
                          spacing: env.space(12)) {
                    ForEach(Array(items.enumerated()), id: \.element.id) { i, w in
                        ScoreCard(w: w).appearIn(min(12, i))
                    }
                }
            }
        }
        .appearIn(2)
    }
}

/* ======================================================================
   学科柱状图（点「各科明细」里的一行弹出）

   用户要求（原话）：
     「点进对应的学科之后，不要直接跳转到原网站，而是加入新功能：软件内置的
      柱状图，就类似原网站里这种，但是要比它更加精致好用，这个的形式也是
      弹出一个大窗口，这个窗口也要符合上面说的，加入液态玻璃描边。」

   这里比 ManageBac 原站多做的那几件事（「更精致好用」落在这些地方）：
     · 柱子按**时间顺序**从左到右 —— 学期进程一眼看到，原站是按作业罗列；
     · 等级网格线（A/B/C/D 四条）让「这根柱子算好还是差」不用换算；
     · 一条均分参考线，谁在平均线下面一眼可见；
     · 悬停联动：鼠标在柱子上，右侧图例同步高亮，反之亦然；
     · 柱子和图例都能点，直接开那条作业；
     · 底部等级分布，C 以下的数量直接标红。
   ====================================================================== */

@MainActor
final class SubjectChartCenter: ObservableObject {
    static let shared = SubjectChartCenter()
    @Published var row: GPARowModel?

    func open(_ r: GPARowModel) { withAnimation(Motion.pop) { row = r } }
    func close() { withAnimation(Motion.pop) { row = nil } }
}

/// 挂在窗口根部的柱状图宿主（和 TaskDetailHost 同一套约定）
struct SubjectChartHost: View {
    @ObservedObject private var center = SubjectChartCenter.shared
    @ObservedObject private var store = DataStore.shared
    @EnvironmentObject private var settings: BoardSettings

    var body: some View {
        // GeometryReader 而不是裸 ZStack：弹窗宽度必须跟着窗口走 ——
        // 菜单栏小面板只有 470 宽，写死 900 会被裁掉右边一大半。
        GeometryReader { geo in
            ZStack {
                if let r = center.row {
                    SubjectChartOverlay(row: r,
                                        maxW: geo.size.width,
                                        maxH: geo.size.height) { center.row = nil }
                        .transition(.opacity)
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
        // 离屏自检的后门：真机这一层要点一下学科行才弹出来，而离屏渲染
        // 没法点击 —— 没有这一笔，柱状图在自检图里永远看不见。
        .onAppear {
            guard let key = PreviewFlags.chartKey else { return }
            if let r = store.gpaRows(settings: settings).first(where: { $0.key == key }) {
                center.row = r
            }
        }
    }
}

struct SubjectChartOverlay: View {
    let row: GPARowModel
    /// 可用宽度 / 高度（由宿主从 GeometryReader 传进来）
    var maxW: CGFloat = 1200
    var maxH: CGFloat = 900
    var onClose: () -> Void

    @EnvironmentObject var settings: BoardSettings
    @Environment(\.colorScheme) private var scheme
    @State private var shown = PreviewFlags.offscreen
    @State private var hover: Int?
    /// 排序方式：按时间看进程 / 从低到高找薄弱项 —— 两种都常用，所以做成可切
    @State private var byScore = false

    private var env: Env { Env(scheme: scheme, settings: settings) }
    private var rgb: RGB { Subject.rgb(row.key, settings) }
    private var c: Color { rgb.color(scheme, lift: 0.14) }

    /// 弹窗宽度：想要 900，但不能超过窗口。小面板里它会退成一个窄弹窗，
    /// 这时右侧图例挪到柱子下面（见 panel 里的 `wide` 判断）。
    private var panelW: CGFloat { min(900, max(320, maxW - 72)) }
    /// 宽到能左右并排（柱子 + 图例）吗
    private var wide: Bool { panelW >= 760 }

    /// 只保留「能算得分率」的条目：满分是 0 或缺失的评分项画不出柱子
    private var items: [RecentVM] {
        let base = row.items.filter { $0.pct != nil }
        if byScore { return base.sorted { ($0.pct ?? 0) < ($1.pct ?? 0) } }
        return base
    }

    private var avg: Double? {
        let p = items.compactMap { $0.pct }
        return p.isEmpty ? nil : p.reduce(0, +) / Double(p.count)
    }

    var body: some View {
        // 外壳统一走 FloatingWindow：相对视口居中、顶部可拖、背景径向渐暗。
        FloatingWindow(dim: scheme == .dark ? 0.46 : 0.30,
                       panelRadius: 440,
                       inset: EdgeInsets(top: wide ? 30 : 18, leading: wide ? 30 : 18,
                                         bottom: wide ? 30 : 18, trailing: wide ? 30 : 18),
                       onTapOutside: close) {
            panel
                .scaleEffect(shown ? 1 : 0.96)
                .opacity(shown ? 1 : 0)
                .offset(y: shown ? 0 : 18)
        }
        .onAppear { withAnimation(Motion.pop) { shown = true } }
        .onExitCommand { close() }
    }

    private func close() {
        withAnimation(Motion.pop) { shown = false }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.24) { onClose() }
    }

    /* ---------------- 面板 ---------------- */

    private var panel: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(Theme.lineSoft(scheme))
            if items.isEmpty { empty }
            else if wide {
                HStack(alignment: .top, spacing: env.space(18)) {
                    chartArea
                    legend
                }
                .padding(env.space(22))
            } else {
                // 窄窗口（菜单栏小面板）：左右并排放不下 —— 柱子在上、图例在下。
                // 图例限高，免得把弹窗顶出屏幕。
                VStack(alignment: .leading, spacing: env.space(16)) {
                    chartArea
                    legend
                        .frame(height: min(200, maxH * 0.28))
                }
                .padding(env.space(18))
            }
            Divider().overlay(Theme.lineSoft(scheme))
            footer
        }
        .frame(width: panelW)
        // 高度也跟窗口走：小面板只有 ~700 高，写死 640 会顶出边界。
        .frame(maxHeight: min(640, max(320, maxH - 56)))
        .liquidGlassPanel(env, corner: Radius.lg)
    }

    /* ---------------- 顶部 ---------------- */

    private var header: some View {
        // 窄窗口（小面板 ~470 宽）下，图标 + 科名 + 三个 chip + 排序 + 打开原站
        // + 关闭 挤在一行会把科名压成「化…」、标题压成「打」。
        // 所以窄的时候拆成两行：第一行只放身份（图标 + 科名 + 关闭），
        // 第二行放数据与操作 —— 每个元素都有地方待着，谁也不用被截断。
        Group {
            if wide { wideHeader } else { narrowHeader }
        }
        .padding(.horizontal, wide ? env.space(22) : env.space(16))
        .padding(.vertical, wide ? env.space(16) : env.space(12))
    }

    private var titleBlock: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(row.label)
                .font(.system(size: wide ? 17 : 15.5, weight: .semibold))
                .foregroundStyle(Theme.ink(scheme))
                .lineLimit(1)
            Text("\(items.count) 次已评分"
                 + (row.itemTotal > items.count ? " · 共 \(row.itemTotal) 条明细" : ""))
                .font(Typo.micro)
                .foregroundStyle(.tertiary)
                .lineLimit(1)
        }
    }

    private var iconBlock: some View {
        ZStack {
            RoundedRectangle(cornerRadius: env.radius(10), style: .continuous)
                .fill(c.opacity(0.18))
                .frame(width: wide ? 38 : 32, height: wide ? 38 : 32)
            Image(systemName: "chart.bar.fill")
                .font(.system(size: wide ? 15 : 13, weight: .semibold))
                .foregroundStyle(c)
        }
    }

    private var closeButton: some View {
        Button { close() } label: {
            Image(systemName: "xmark")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(.secondary)
                .frame(width: 26, height: 26)
                .contentShape(Circle())
                .background(Circle().fill(Color.primary.opacity(0.06)))
        }
        .buttonStyle(.plain)
        .keyboardShortcut(.cancelAction)
        .help("关闭")
    }

    private var wideHeader: some View {
        HStack(alignment: .center, spacing: env.space(14)) {
            iconBlock
            titleBlock
            Spacer(minLength: 0)
            if let p = row.pct {
                HStack(spacing: env.space(12)) {
                    overallChip("Overall", fmtPct(p), c)
                    if let g = row.grade { overallChip("等级", g, bandColor(g)) }
                    overallChip("4 分制", to4(p / 100), Theme.ink3_RGB.color(scheme, lift: 0.12))
                }
                .fixedSize()
            }
            segControl
            openSiteButton(labeled: true)
            closeButton
        }
    }

    private var narrowHeader: some View {
        VStack(alignment: .leading, spacing: env.space(11)) {
            HStack(alignment: .center, spacing: env.space(10)) {
                iconBlock
                titleBlock
                Spacer(minLength: 0)
                closeButton
            }
            HStack(spacing: env.space(10)) {
                if let p = row.pct {
                    HStack(spacing: env.space(9)) {
                        overallChip("Overall", fmtPct(p), c)
                        if let g = row.grade { overallChip("等级", g, bandColor(g)) }
                    }
                    .fixedSize()
                }
                Spacer(minLength: 0)
                segControl
                openSiteButton(labeled: false)
            }
        }
    }

    private var segControl: some View {
        HStack(spacing: 2) {
            seg("按时间", on: !byScore) { byScore = false }
            seg("低→高", on: byScore) { byScore = true }
        }
        .padding(2)
        .background { Capsule().fill(Color.primary.opacity(0.06)) }
        .fixedSize()
    }

    @ViewBuilder
    private func openSiteButton(labeled: Bool) -> some View {
        if let u = row.url {
            Button {
                // 走统一的跳转入口（受「一律使用内置浏览器」控制）
                LinkOpen.go(u, source: "managebac", settings: settings)
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: Icons.open).font(.system(size: 9.5, weight: .bold))
                    if labeled {
                        Text("打开原站").font(.system(size: 11.5, weight: .semibold))
                    }
                }
                .padding(.horizontal, labeled ? env.space(11) : 8)
                .padding(.vertical, env.space(5))
                .background { Capsule().strokeBorder(c.opacity(0.35), lineWidth: 1) }
                .foregroundStyle(c)
            }
            .buttonStyle(.plain)
            .help("去 ManageBac 看这门课的原始页面")
        }
    }

    /// 三个小胶囊（Overall / 等级 / 4 分制）。这里收的是**已经调好的 Color**，
    /// 因为三种来源不同：学科色、bandColor(等级)、ink3 —— 各自该 lift 多少不一样，
    /// 统一在调用点决定，免得函数内再加一层 lift 把它们都拉同一档。
    private func overallChip(_ k: String, _ v: String, _ col: Color) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(k).font(.system(size: 9.5)).foregroundStyle(.tertiary)
            Text(v)
                .font(.system(size: 14, weight: .bold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(col)
        }
    }

    private func seg(_ t: String, on: Bool, _ tap: @escaping () -> Void) -> some View {
        Button { withAnimation(Motion.ease(Motion.Dur.quick)) { tap() } } label: {
            Text(t)
                .font(.system(size: 11, weight: .semibold))
                .lineLimit(1)
                .fixedSize()
                .padding(.horizontal, wide ? 10 : 8).padding(.vertical, 4)
                .background {
                    if on {
                        Capsule().fill(c.opacity(scheme == .dark ? 0.28 : 0.16))
                    }
                }
                .foregroundStyle(on ? c : Color.secondary)
        }
        .buttonStyle(.plain)
    }

    /* ---------------- 图表 ---------------- */

    private var chartArea: some View {
        VStack(alignment: .leading, spacing: env.space(10)) {
            chart
                .frame(height: chartHeight)
            Text(hover.flatMap { i in items.indices.contains(i) ? items[i].title : nil }
                 ?? "鼠标停在柱子上看那一次作业；点柱子或右侧条目直接打开")
                .font(Typo.micro)
                .foregroundStyle(hover == nil
                                 ? AnyShapeStyle(.tertiary)
                                 : AnyShapeStyle(Theme.ink2(scheme)))
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity)
    }

    /// 图表与右侧图例共用同一个高度 —— 两边齐平，也让面板高度可预期。
    /// 窄窗口（小面板）时再降一档：380 的柱子在小面板里会把整块顶出屏幕。
    private var chartHeight: CGFloat { wide ? 380 : 240 }
    /// 柱子底下那行日期的高度。网格线、柱子、标签三层都用它对齐。
    private static let axisH: CGFloat = 17

    /// 纵轴下界：动态取，避免所有人都在 85 分以上时柱子全顶到天花板、看不出差别。
    private var domainLo: Double {
        let p = items.compactMap { $0.pct }.min() ?? 50
        return max(0, min(70, (p / 10).rounded(.down) * 10 - 10))
    }

    private static let gridLevels: [(Double, String)] = [(90, "A"), (80, "B"), (70, "C"), (60, "D")]

    private var chart: some View {
        GeometryReader { geo in
            let W = geo.size.width, H = geo.size.height
            let lo = domainLo
            let n = max(1, items.count)
            let leftPad: CGFloat = 30          // 给纵轴等级字母留的位置
            let gap: CGFloat = n > 30 ? 3 : (n > 16 ? 5 : 8)
            // 柱宽封顶 58：一学期只有三五次评分时，若不封顶柱子会变成
            // 三块巨大的色块 —— 那样既不像柱状图，也看不出「柱子之间在比什么」。
            // 封顶后多余的空间左右平分，柱子居中站成一组。
            let bw = min(58, max(4, (W - leftPad - gap * CGFloat(n - 1)) / CGFloat(n)))
            let used = bw * CGFloat(n) + gap * CGFloat(n - 1)
            let startX = leftPad + max(0, (W - leftPad - used) / 2)

            // 画柱子的区域 = 总高 − 底部日期行。网格线与柱子必须都按这个高度
            // 换算百分比，否则 A/B/C 那几条线会比柱子顶端高出十几像素，
            // 看起来像「85 分的柱子在 A 线上」。
            let barH = H - Self.axisH

            func yy(_ p: Double) -> CGFloat {
                let t = (min(max(p, lo), 100) - lo) / (100 - lo)
                return barH * (1 - CGFloat(t))
            }

            return ZStack(alignment: .topLeading) {
                // ① 等级网格线 + 左侧字母
                ForEach(Self.gridLevels, id: \.0) { g in
                    if g.0 > lo {
                        let y = yy(g.0)
                        Path { p in
                            p.move(to: CGPoint(x: leftPad, y: y))
                            p.addLine(to: CGPoint(x: W, y: y))
                        }
                        .stroke(Color.primary.opacity(0.08),
                                style: StrokeStyle(lineWidth: 1, dash: [3, 4]))
                        Text(g.1)
                            .font(.system(size: 10.5, weight: .bold, design: .rounded))
                            .foregroundStyle(.tertiary)
                            .frame(width: 20, alignment: .trailing)
                            .position(x: 10, y: min(H - 8, max(8, y)))
                    }
                }

                // ② 均分参考线（只画虚线，不写字）。
                //    曾经把「均分 88.6%」钉在线右端，结果 24 次评分时整幅图
                //    几乎没有留白，标签正好压在最高的几根柱子上，糊成一团。
                //    数值改到右侧图例的表头显示（那里宽度充足、谁也不挡），
                //    图里只留这条线本身。
                if let a = avg, a > lo, a < 100 {
                    let y = yy(a)
                    Path { p in
                        p.move(to: CGPoint(x: leftPad, y: y))
                        p.addLine(to: CGPoint(x: W, y: y))
                    }
                    .stroke(c.opacity(0.55),
                            style: StrokeStyle(lineWidth: 1.2, dash: [5, 4]))
                }

                // ③ 柱子
                ForEach(Array(items.enumerated()), id: \.element.id) { i, it in
                    // 柱子密的时候日期标签每根都写就糊成一条黑线（24 次评分时
                    // 实际就是这个效果）。按「相邻标签至少隔 42pt」抽稀 ——
                    // 只在能放下的那几根底下写字，中间留白反而更好读。
                    let step = max(1, Int(ceil(42 / max(1, bw + gap))))
                    chartBar(it, index: i, width: bw, top: yy(it.pct ?? 0), H: H,
                             axis: (i % step == 0) ? axisLabel(it.due) : nil)
                        .offset(x: startX + CGFloat(i) * (bw + gap))
                }
            }
        }
    }

    private func chartBar(_ it: RecentVM, index: Int, width: CGFloat,
                          top: CGFloat, H: CGFloat, axis: String?) -> some View {
        let pct = it.pct ?? 0
        let col = bandColor(it.grade)
        let on = hover == index
        // 底部留一条给日期标签 —— 原站只有右侧图例，鼠标挪过去才知道哪根是哪次；
        // 把「月/日」直接钉在柱子底下，扫一眼就能对上时间轴。
        let labelH = Self.axisH
        let barH = H - labelH
        return VStack(spacing: 0) {
            VStack(spacing: 0) {
                Spacer(minLength: 0)
                ZStack(alignment: .top) {
                    RoundedRectangle(cornerRadius: min(5, width / 2), style: .continuous)
                        .fill(LinearGradient(colors: [col.opacity(0.98), col.opacity(0.48)],
                                             startPoint: .top, endPoint: .bottom))
                    // 顶部一道高光：柱子看起来有厚度，而不是一块色块
                    RoundedRectangle(cornerRadius: min(5, width / 2), style: .continuous)
                        .fill(LinearGradient(colors: [.white.opacity(scheme == .dark ? 0.30 : 0.65),
                                                      .clear],
                                             startPoint: .top, endPoint: .bottom))
                        .frame(height: 5)
                }
                .frame(width: width, height: max(5, barH - top))
                .overlay {
                    RoundedRectangle(cornerRadius: min(5, width / 2), style: .continuous)
                        .strokeBorder(on ? Color.primary.opacity(0.45) : col.opacity(0.0),
                                      lineWidth: 1.2)
                }
                // 悬停时只有柱子在动，下面的日期标签不动 —— 整体缩放会连标签一起抖
                .shadow(color: col.opacity(on ? 0.55 : 0), radius: 7, y: 1)
                .scaleEffect(on ? 1.05 : 1, anchor: .bottom)
                .animation(Motion.ease(Motion.Dur.quick), value: on)
            }
            .frame(width: width, height: barH)
            .contentShape(Rectangle())
            .onHover { h in
                if h { hover = index }
                else if hover == index { hover = nil }
            }
            .onTapGesture { open(it) }

            // 标签可能比柱子宽（例如 12/28）—— 不设宽度上限、fixedSize 让它
            // 以柱子中心为基准自然溢出。抽稀之后左右都留了空位（≥42pt），
            // 相邻标签不会互相压住，也不需要裁剪。
            Text(axis ?? " ")
                .font(Typo.num(9, .medium))
                .foregroundStyle(on ? AnyShapeStyle(col) : AnyShapeStyle(.tertiary))
                .lineLimit(1)
                .fixedSize()
                .frame(height: labelH)
        }
        .frame(width: width, height: H)
        .help("\(it.title)\n\(it.scoreText) · \(it.grade ?? "") · 得分率 \(fmtPct(pct))")
        .accessibilityLabel("\(it.title)，得分率 \(fmtPct(pct))")
    }

    /// X 轴文字：'9/14'。没有截止时间的条目给一个占位点，免得标签行高低不齐。
    private func axisLabel(_ d: Date?) -> String {
        guard let d else { return "·" }
        let c = Calendar.current.dateComponents([.month, .day], from: d)
        return "\(c.month ?? 0)/\(c.day ?? 0)"
    }

    /* ---------------- 右侧图例 ---------------- */

    private var legend: some View {
        VStack(alignment: .leading, spacing: env.space(8)) {
            HStack(spacing: 6) {
                Text(byScore ? "从低到高" : "按时间（旧 → 新）")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 4)
                // 均分线的数值放这里：图里只剩一条虚线，不挡任何柱子，
                // 而数值本身仍然一眼可见。
                if let a = avg {
                    HStack(spacing: 4) {
                        // 一小段虚线样张，跟图里那条线对得上
                        Path { p in
                            p.move(to: .zero)
                            p.addLine(to: CGPoint(x: 14, y: 0))
                        }
                        .stroke(c.opacity(0.7), style: StrokeStyle(lineWidth: 1.2, dash: [4, 3]))
                        .frame(width: 14, height: 1.2)
                        Text("均分 \(fmtPct(a))")
                            .font(Typo.num(10.5, .bold))
                            .foregroundStyle(c)
                    }
                }
            }
            // ⚠️ 高度必须定死。ScrollView 的「自然高度」是不定的：离屏渲染
            //    下它会一路撑开，把整块面板顶到 800 多高（旁边没有弹性兄弟
            //    跟它抢）——柱状图上下各留一大片空白。定死之后两边齐平了。
            //    离屏自检再换成 VStack：ImageRenderer 不画 ScrollView 的内容，
            //    否则图例在自检图里永远是一片空白，行高对不对根本没法核。
            Group {
                if PreviewFlags.offscreen {
                    // frame(alignment: .top) 不能省：VStack 在定高框里默认垂直
                    // 居中，24 条时看起来像「从第 9 条开始」—— 其实是被顶上去了。
                    VStack(spacing: 3) {
                        ForEach(Array(items.enumerated()), id: \.element.id) { i, it in
                            legendRow(it, index: i)
                        }
                    }
                    .frame(maxHeight: .infinity, alignment: .top)
                } else {
                    ScrollView {
                        VStack(spacing: 3) {
                            ForEach(Array(items.enumerated()), id: \.element.id) { i, it in
                                legendRow(it, index: i)
                            }
                        }
                        .padding(.trailing, 2)
                    }
                }
            }
            // 宽布局时和柱子等高、齐平；窄布局时由外层 frame(height:) 管着。
            .frame(height: wide ? chartHeight - 24 : nil)
            // 离屏降级那一支的 VStack 没有滚动，24 条会一路画到面板外面去；
            // 裁掉溢出的部分，自检图里看到的才是真机上能看到的范围。
            .clipped()
        }
        // 宽布局：固定 268 宽（和柱子等高齐平）；窄布局：占满整行。
        // frame(width:) 的实参是 CGFloat?，用 if-else 两套写完更清楚 ——
        // `width: wide ? 268 : nil, maxWidth: wide ? nil : .infinity` 里
        // 那个 268 是 Int 字面量，和 CGFloat? 混在同一个三元里推不出类型。
        .frame(width: wide ? 268 : nil)
        .frame(maxWidth: wide ? 268 : .infinity)
    }

    private func legendRow(_ it: RecentVM, index: Int) -> some View {
        let col = bandColor(it.grade)
        let on = hover == index
        return Button { open(it) } label: {
            HStack(spacing: env.space(9)) {
                // 与柱子同一个色块，靠颜色把两边对起来
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .fill(LinearGradient(colors: [col.opacity(0.98), col.opacity(0.5)],
                                         startPoint: .top, endPoint: .bottom))
                    .frame(width: 9, height: 20)
                VStack(alignment: .leading, spacing: 1) {
                    Text(it.title)
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(Theme.ink(scheme))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text([it.dueText, it.scoreText].filter { !$0.isEmpty }
                            .joined(separator: " · "))
                        .font(Typo.num(9.5, .regular))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
                Spacer(minLength: 4)
                if let g = it.grade {
                    Text(g)
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(rgb.onColor)
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .fill(col.opacity(0.92)))
                }
                Text(it.pct.map(fmtPct) ?? "—")
                    .font(Typo.num(11, .bold))
                    .foregroundStyle(col)
                    .frame(width: 46, alignment: .trailing)
            }
            .padding(.horizontal, env.space(9))
            .padding(.vertical, env.space(6))
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                RoundedRectangle(cornerRadius: env.radius(8), style: .continuous)
                    .fill(on ? col.opacity(scheme == .dark ? 0.20 : 0.12)
                             : Color.primary.opacity(scheme == .dark ? 0.045 : 0.028))
            }
            .contentShape(RoundedRectangle(cornerRadius: env.radius(8), style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { h in
            if h { hover = index }
            else if hover == index { hover = nil }
        }
        .help("\(it.title)\n\(it.dueText) · \(it.grade ?? "") \(it.scoreText)")
    }

    /* ---------------- 空态 / 底部 ---------------- */

    private var empty: some View {
        VStack(spacing: env.space(10)) {
            Image(systemName: "chart.bar")
                .font(.system(size: 30, weight: .light))
                .foregroundStyle(.tertiary)
            Text("这门课还没有可画图的评分")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Theme.ink2(scheme))
            Text("作业列表里没有「得分 / 满分」都齐全的记录。\n可以点右上角「打开原站」去 ManageBac 看看。")
                .font(Typo.micro)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, env.space(60))
    }

    @ViewBuilder
    private var footer: some View {
        let pcts = items.compactMap { $0.pct }
        let hi = pcts.max(), lo = pcts.min()
        let weak = items.filter { ($0.pct ?? 100) < 80 }.count
        // 窄窗口里 5 个统计 + 一行图例说明放不下，会挤到换行、把「柱子高度 = …」
        // 折成两行。窄的时候只留「次数 / 平均 / 80 分以下」三项，说明文字去掉
        // （图例表头已经写了「按时间/均分」，语义没丢）。
        Group {
            if wide {
                HStack(spacing: env.space(16)) {
                    stat("次数", "\(items.count)")
                    stat("平均", avg.map(fmtPct) ?? "—")
                    stat("最高", hi.map(fmtPct) ?? "—")
                    stat("最低", lo.map(fmtPct) ?? "—")
                    stat("80 分以下", "\(weak)", weak > 0 ? Theme.amberDefault : nil)
                    Spacer(minLength: 0)
                    Text("柱子高度 = 得分 / 满分；颜色 = 等级")
                        .font(Typo.micro)
                        .foregroundStyle(.tertiary)
                }
            } else {
                HStack(spacing: env.space(18)) {
                    stat("次数", "\(items.count)")
                    stat("平均", avg.map(fmtPct) ?? "—")
                    stat("80 分以下", "\(weak)", weak > 0 ? Theme.amberDefault : nil)
                    Spacer(minLength: 0)
                }
            }
        }
        .padding(.horizontal, wide ? env.space(22) : env.space(18))
        .padding(.vertical, env.space(13))
    }

    private func stat(_ k: String, _ v: String, _ col: RGB? = nil) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(k).font(.system(size: 9.5)).foregroundStyle(.tertiary)
            Text(v)
                .font(.system(size: 13.5, weight: .bold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle((col ?? Theme.ink3_RGB).color(scheme, lift: 0.12))
        }
    }

    /* ---------------- 工具 ---------------- */

    private func open(_ it: RecentVM) {
        guard let u = it.url else { return }
        LinkOpen.go(u, source: "managebac", settings: settings)
    }

    /// 等级 → 颜色。阈值沿用 ManageBac 那套 A≥90 / B≥80 / C≥70 / D≥60 / F<60，
    /// 和原站柱状图右侧的字母刻度是同一套，所以两边读起来是同一个意思。
    /// 用色沿用 App 里其它成绩的约定（好 = 绿 / 一般 = 琥珀 / 差 = 红），
    /// 不套用股市的涨红跌绿 —— 那是行情语义，成绩板里会读反。
    private func bandColor(_ g: String?) -> Color {
        guard let g, let f = g.first else { return Theme.ink3_RGB.color(scheme, lift: 0.10) }
        switch f {
        case "A": return Theme.greenDefault.color(scheme, lift: 0.10)
        case "B": return settings.accent.color(scheme, lift: 0.10)
        case "C": return Theme.amberDefault.color(scheme, lift: 0.08)
        default:  return Theme.redDefault.color(scheme, lift: 0.06)
        }
    }
}


struct GradeRow: View {
    let r: GPARowModel
    var rank: Int = 0
    @EnvironmentObject var settings: BoardSettings
    @Environment(\.colorScheme) private var scheme
    @State private var hovering = false

    private var env: Env { Env(scheme: scheme, settings: settings) }

    var body: some View {
        let rgb = Subject.rgb(r.key, settings)
        let c = rgb.color(scheme, lift: 0.14)

        Button {
            // 用户要求：「点进对应的学科之后，不要直接跳转到原网站，而是加入新功能：
            //            软件内置的柱状图」。原站入口留在弹窗右上角那颗「打开原站」。
            SubjectChartCenter.shared.open(r)
        } label: {
            HStack(spacing: env.space(12)) {
                Circle()
                    .fill(c)
                    .frame(width: 8, height: 8)
                Text(r.label)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.ink(scheme))
                    .frame(width: 48, alignment: .leading)

                if let p = r.pct {
                    MiniBar(env: env, value: p / 100, color: rgb, height: 6)
                        .frame(maxWidth: .infinity)
                    Text(fmtPct(p))
                        .font(Typo.num(14, .bold))
                        .foregroundStyle(c)
                        .frame(width: 74, alignment: .trailing)
                    Text(r.grade ?? "")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(rgb.onColor)
                        .frame(width: 30)
                        .padding(.vertical, 3)
                        .background(RoundedRectangle(cornerRadius: env.radius(7), style: .continuous)
                            .fill(c.opacity(0.92)))
                    Text("\(to4(p / 100)) / 4.0")
                        .font(Typo.num(12, .medium))
                        .foregroundStyle(.secondary)
                        .frame(width: 72, alignment: .trailing)
                } else {
                    Spacer(minLength: 0)
                    Text("未出分")
                        .font(.system(size: 12))
                        .foregroundStyle(.tertiary)
                        .frame(width: 260, alignment: .trailing)
                }
            }
            .padding(.horizontal, env.space(12))
            .frame(height: env.space(settings.density.rowHeight - 2))
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                RoundedRectangle(cornerRadius: env.radius(Radius.sm), style: .continuous)
                    .fill(hovering
                          ? rgb.color(scheme, lift: 0.86, opacity: scheme == .dark ? 0.16 : 0.10)
                          : (scheme == .dark ? Color.white.opacity(0.035) : Color.white.opacity(0.5)))
            }
            .contentShape(RoundedRectangle(cornerRadius: env.radius(Radius.sm), style: .continuous))
        }
        .buttonStyle(.plain)
        .hoverLift(1.5)
        .onHover { hovering = $0 }
        .help("点击查看 \(r.label) 的柱状图（每次作业一根柱子）")
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(r.label)，\(r.pct.map(fmtPct) ?? "未出分")\(r.grade.map { "，等级 \($0)" } ?? "")")
    }
}

/* ---------------- 出分卡 ---------------- */

struct ScoreCard: View {
    let w: RecentVM
    @EnvironmentObject var settings: BoardSettings
    @Environment(\.colorScheme) private var scheme
    @State private var hovering = false

    private var env: Env { Env(scheme: scheme, settings: settings) }

    var body: some View {
        let rgb = Subject.rgb(w.key, settings)
        let c = rgb.color(scheme, lift: 0.16)
        let scoreColor = w.good ? Theme.greenDefault.color(scheme, lift: 0.12)
                                : Theme.amberDefault.color(scheme, lift: 0.12)

        Button {
            // 出分卡也是跳转点，同样收编到统一入口 —— 否则「一律使用内置浏览器」
            // 在这里会被绕过，用户点了还是弹系统浏览器。
            if let u = w.url { LinkOpen.go(u, source: "managebac", settings: settings) }
        } label: {
            VStack(alignment: .leading, spacing: env.space(7)) {
                HStack(spacing: 6) {
                    Circle().fill(c).frame(width: 6.5, height: 6.5)
                    Text(w.label)
                        .font(.system(size: 10.5, weight: .bold))
                        .foregroundStyle(c)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    if let g = w.grade {
                        Text(g)
                            .font(.system(size: 10.5, weight: .bold))
                            .foregroundStyle(scoreColor)
                    }
                }

                Text(w.title)
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(Theme.ink(scheme))
                    .lineLimit(3)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)

                Spacer(minLength: 2)

                if let s = w.scoreNum, let o = w.scoreOutOf, o > 0 {
                    MiniBar(env: env, value: s / o, color: w.good ? Theme.greenDefault : Theme.amberDefault)
                }

                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(w.scoreText)
                        .font(Typo.num(12.5, .bold))
                        .foregroundStyle(Theme.ink(scheme))
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                    Spacer(minLength: 4)
                    // 批改时间（bridge 留存；没有就落到截止时间）—— 用户要求每张出分卡都标
                    Text(gradedAtText(w.gradedAt) ?? w.dueText)
                        .font(Typo.num(10, .medium))
                        .foregroundStyle(w.gradedAt != nil ? scoreColor : Color.secondary)
                        .lineLimit(1)
                }
            }
            .padding(env.space(13))
            .frame(height: env.space(150), alignment: .topLeading)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(RoundedRectangle(cornerRadius: env.radius(Radius.md), style: .continuous))
        }
        .buttonStyle(.plain)
        .card(env.radius(Radius.md),
              tint: hovering ? c.opacity(scheme == .dark ? 0.16 : 0.09) : nil,
              look: env.look)
        .hoverLift(3)
        .onHover { hovering = $0 }
        .help("\(w.label) · \(w.title)\n\(w.dueText) · \(w.grade ?? "") \(w.scoreText)\n出分：\(gradedAtText(w.gradedAt) ?? "未知")\n点击在 ManageBac 中打开")
    }
}
