import SwiftUI
import AppKit

/* ======================================================================
   菜单栏面板
   自上而下：顶栏 → 大计时 → 待办 → 接下来的课堂 → 最新成绩 → English Corner
            → 快速设置 → 底部展开条

   ⚠️ 玻璃：每张卡片自己带玻璃（`.card()` / `.glassPane()`），**不要**再套
   `GlassEffectContainer`。容器会把成组卡片的玻璃合并成单独一层并合成到内容之上，
   卡片里的文字就全变成「透过磨砂看」——整片发糊。真机截图已确认：
   同一段 `.card()` 代码，放进容器糊、不放进容器清晰。
   ====================================================================== */

struct PanelView: View {
    @EnvironmentObject var settings: BoardSettings
    @Environment(\.colorScheme) private var scheme

    @ObservedObject private var store: DataStore
    @State private var confirmingQuit = false
    @State private var now = PreviewFlags.nowOverride ?? Date()

    /// 面板现在是自建的 NSPanel（不会自动消失），关闭要显式回调
    var onClose: (() -> Void)? = nil

    // 折叠状态：默认只给「够用的一屏」，想看更多就地铺开，
    // 不用再跳去看板 —— 小组件里也能看到比较全的数据。
    @State private var todoOpen = false
    @State private var overdueOpen = false
    @State private var classOpen = false
    @State private var scoreOpen = false
    /// 快速设置默认收起（用户要求），展开状态跟设置里的偏好走
    @State private var quickOpen = false
    @State private var quickInited = false
    @State private var quickHover = false
    @State private var moreHover = false
    @Namespace private var quickNS

    init(store: DataStore, onClose: (() -> Void)? = nil) {
        _store = ObservedObject(wrappedValue: store)
        self.onClose = onClose
    }

    private func close() { onClose?() }

    private var env: Env { Env(scheme: scheme, settings: settings) }
    private var W: CGFloat { CGFloat(settings.panelWidth) }

    var body: some View {
        VStack(spacing: env.space(10)) {
            header
            content
            bottomBar
        }
        .overlay {
            // 任务详情单（小看板版：宽度按面板自适应）
            TaskDetailHost()
            // 学科柱状图（面板里点学科行也会弹出，用同一套 900 宽的浮层）
            SubjectChartHost()
        }
        .padding(env.space(Space.md))
        .frame(width: W, height: PreviewFlags.fullHeight ? nil : panelHeight)
        // 面板门面：外圈原生液态玻璃描边（零填色、纯折射），内圈毛玻璃主体。
        // 用 `liquidGlassRim` 而不是 `liquidGlassPanel` —— 面板的高宽由 AppKit
        // 窗口精确管着，再往外加 padding 会把内容挤变形。
        // 窗口是 borderless + 非不透明的，所以玻璃折射的是面板背后的真实内容。
        // border 跟设置走（默认 7，就是原效果）——小看板也要能一起调宽窄。
        .liquidGlassRim(env, radius: env.radius(Radius.lg) + 4)
        .task { await store.start() }
        .onAppear {
            if PreviewFlags.nowOverride == nil { now = Date() }
            if !quickInited {
                quickInited = true
                quickOpen = PreviewFlags.quick || settings.panelQuickOpen
                // 面板弹出前就把高度对齐，否则第一帧是矮的、下一帧才长高（会跳一下）
                setQuickExtra(quickOpen, animate: false)
            }
            Task {
                // 面板一露头就抓一次真的：用户要求「数据一定要是真实刷新出来的」
                await store.load()
                await store.loadTeams()
            }
        }
        // 秒针 + 定时抓数据。
        // ★ 原来这两句是 `.onReceive(Timer.publish(every: 1|120, …).autoconnect())` ★
        // onReceive 的第一个参数**每次 body 重算都会重新求值**，而面板里
        // `now` 每秒变一次 → body 每秒重算 → 每秒新建一个 Timer 发布者，
        // 旧订阅刚建立就被替换，永远等不到第一次触发。
        // 结果：面板上的小倒计时同样是死的，120 秒那次抓数据也从来没执行过。
        // 改用 .task 起的循环，只启动一次、随视图消失自动取消。
        .task {
            if PreviewFlags.nowOverride != nil { return }
            while !Task.isCancelled {
                let t = Date()
                now = t
                let frac = t.timeIntervalSince1970.truncatingRemainder(dividingBy: 1)
                do {
                    try await Task.sleep(nanoseconds: UInt64(max(0.05, 1.0 - frac) * 1_000_000_000))
                } catch { return }
            }
        }
        .task {
            if PreviewFlags.offscreen { return }
            while !Task.isCancelled {
                do { try await Task.sleep(nanoseconds: 120_000_000_000) } catch { return }
                await store.load()
            }
        }
    }

    /// 面板总高 = 基准高度 + 快速设置展开的那一块。
    /// 展开的四行不再落到折叠线以下 —— 面板自己往上长，不用用户滚。
    private var panelHeight: CGFloat {
        PanelMetrics.height + (quickOpen ? PanelMetrics.quickExtra : 0)
    }

    /// 把「要不要多出一块」同步给 AppKit（窗口高度是它管的）
    private func setQuickExtra(_ on: Bool, animate: Bool = true) {
        PanelMetrics.extraHeight = on ? PanelMetrics.quickExtra : 0
        guard animate else { return }
        NotificationCenter.default.post(name: PanelMetrics.resizeNote, object: nil)
    }

    /* ---------------- 顶栏（细状态条） ----------------
       用户要求：状态头一直显示没问题，但别这么高 —— 收成一条窄的，
       并在上面加一个「刷新数据」按钮。 */

    private var header: some View {
        HStack(spacing: env.space(8)) {
            // 应用标记（比原来小一圈）
            ZStack {
                RoundedRectangle(cornerRadius: env.radius(6), style: .continuous)
                    .fill(LinearGradient(colors: [settings.uiAccent.color(scheme, lift: 0.24),
                                                  settings.uiAccent.color(scheme, lift: -0.04)],
                                         startPoint: .topLeading, endPoint: .bottomTrailing))
                    .frame(width: 19, height: 19)
                Image(systemName: "folder.fill")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.95))
            }
            .shadow(color: settings.uiAccent.color(scheme).opacity(0.26), radius: 4, y: 1)

            Text("ManageBac")
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(Theme.ink(scheme))

            Text(store.subtitle)
                .font(.system(size: 10.5))
                .foregroundStyle(Theme.ink3(scheme))
                .lineLimit(1)

            Spacer(minLength: 4)

            // 真实状态：颜色和文案都来自 DataStore 的实际状态，不是摆设
            HStack(spacing: 5) {
                Circle()
                    .fill(store.statusColor(scheme, accent: settings.uiAccent))
                    .frame(width: 6, height: 6)
                    .shadow(color: store.statusColor(scheme, accent: settings.uiAccent).opacity(0.6), radius: 3)
                Text(store.status.text)
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(Theme.ink2(scheme))
                    .lineLimit(1)
            }

            refreshButton
            iconButton(Icons.settings, help: "打开看板 App 的设置页") { openDashboard(section: .settings) }
            iconButton(confirmingQuit ? "xmark.circle.fill" : Icons.quit,
                       help: "退出菜单栏应用") {
                if confirmingQuit { NSApp.terminate(nil) } else { confirmingQuit = true }
            }
        }
        .padding(.horizontal, env.space(9))
        .frame(height: 30)
        .card(env.radius(Radius.sm), look: env.look, shadow: false)
    }

    /// 「刷新数据」：真的去抓一次，不是重画界面
    private var refreshButton: some View {
        Button {
            Task {
                await store.load(force: true)
                await store.loadTeams()
            }
        } label: {
            HStack(spacing: 4) {
                if store.busy || store.teams?.fetching == true {
                    ProgressView().controlSize(.mini).scaleEffect(0.7)
                } else {
                    Image(systemName: Icons.refresh)
                        .font(.system(size: 9.5, weight: .bold))
                }
                Text("刷新数据")
                    .font(.system(size: 10.5, weight: .semibold))
            }
            .foregroundStyle(settings.uiAccent.color(scheme, lift: 0.10))
            .padding(.horizontal, 8)
            .frame(height: 22)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .background(Capsule().fill(settings.uiAccent.color(scheme).opacity(0.13)))
        .help("立即重新抓取一次（数据、Teams、EC 名单）")
        .accessibilityLabel("刷新数据")
    }

    private func iconButton(_ icon: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(Theme.ink2(scheme))
                .frame(width: 22, height: 22)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .card(Circle(), look: env.look, shadow: false)
        .help(help)
        .accessibilityLabel(help)
    }

    /* ---------------- 内容 ---------------- */

    private var content: some View {
        Group {
            if PreviewFlags.noScroll {
                stack
            } else {
                // ScrollViewReader 是给「快速设置展开」用的：
                // 即使面板已经长高，矮屏幕上也可能还剩一截在折叠线以下，
                // 展开后主动滚到它 —— 用户不该去猜"到底展开了没有"。
                ScrollViewReader { proxy in
                    ScrollView(.vertical) { stack }
                        .onChange(of: quickOpen) { _, open in
                            guard open else { return }
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
                                withAnimation(Motion.reveal) {
                                    proxy.scrollTo("quick", anchor: .bottom)
                                }
                            }
                        }
                }
            }
        }
        .frame(maxHeight: .infinity)
    }

    private var stack: some View {
        VStack(alignment: .leading, spacing: env.space(12)) {
            if settings.panelShowTimer { topTimerCard.appearIn(0) }
            if settings.panelShowTodo  { todoSection.appearIn(1) }
            if settings.panelShowClass { classSection.appearIn(2) }
            if settings.panelShowScore { latestSection.appearIn(3) }
            // 用户要求：English Corner 与快速设置换位置 —— EC 提上来，
            // 快速设置沉到最底部并默认收起（它只是偶尔调一下的东西）。
            if settings.panelShowEC    { ecSection.appearIn(4) }
            if settings.panelShowQuick { quickSettings }
        }
        // 这里不能再加水平内边距：卡片宽度是按面板整宽算的，
        // 多出 1pt 就会让最后一张换行（成绩从「四个一排」变成两排）。
        .padding(.vertical, 2)
    }

    /// 「显示更多 / 收起」通用小按钮 —— 取代原来那句「展开完整看板查看」
    private func moreButton(_ title: String, _ open: Binding<Bool>, _ closedLabel: String) -> some View {
        Button {
            withAnimation(Motion.reveal) { open.wrappedValue.toggle() }
        } label: {
            HStack(spacing: 5) {
                // 箭头是「转过去」而不是「换个字」，所以展开/收起本身就是一段动画
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .bold))
                    .rotationEffect(.degrees(open.wrappedValue ? 180 : 0))
                Text(open.wrappedValue ? "收起" : closedLabel)
                    .font(.system(size: 10.5, weight: .semibold))
                Spacer(minLength: 0)
                Text(title).font(.system(size: 10)).foregroundStyle(.tertiary)
            }
            .foregroundStyle(env.accent.color(scheme, lift: 0.08))
            .padding(.horizontal, env.space(10))
            .frame(height: 24)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(RoundedRectangle(cornerRadius: env.radius(Radius.sm), style: .continuous))
            .background {
                RoundedRectangle(cornerRadius: env.radius(Radius.sm), style: .continuous)
                    .fill(env.accent.color(scheme).opacity(moreHover ? 0.16 : 0.09))
            }
        }
        .buttonStyle(.plain)
        .onHover { moreHover = $0 }
        .animation(Motion.hover, value: moreHover)
    }

    /* ---------------- 大计时 ---------------- */

    private var topTimerCard: some View {
        let tt = Schedule.topTimer(now, settings)
        var big = "好好休息"
        var bigSize: CGFloat = 27
        var name = ""
        var right = ""
        var detail = ""
        var where_ = ""
        var tint: Color? = nil
        var rgb = settings.accent

        switch tt {
        case .rest:
            bigSize = 21
        case .inClass(let s):
            big = hms(s.end.timeIntervalSince(now) * 1000)
            name = s.isFree ? "没有安排课程" : s.subject
            right = "\(s.pLabel) \(fmtClock(s.start))–\(fmtClock(s.end))"
            where_ = [s.room, s.teacher, s.mode].filter { !$0.isEmpty }.joined(separator: " · ")
            rgb = RGB(s.hex)
            tint = rgb.color(scheme, lift: 0.86, opacity: scheme == .dark ? 0.20 : 0.26)
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
            tint = rgb.color(scheme, lift: 0.86, opacity: scheme == .dark ? 0.18 : 0.22)
        case .studyEnd(let d):
            big = hms(d.timeIntervalSince(now) * 1000)
            name = "晚自习"
            right = "\(settings.nightEnd) 结束"
            tint = rgb.color(scheme, lift: 0.86, opacity: scheme == .dark ? 0.16 : 0.18)
        case .studyStart(let d):
            big = hms(d.timeIntervalSince(now) * 1000)
            name = "晚自习"
            right = "\(settings.nightStart) 开始"
            tint = rgb.color(scheme, lift: 0.86, opacity: scheme == .dark ? 0.16 : 0.18)
        }

        return VStack(alignment: .leading, spacing: env.space(6)) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: Icons.bolt).font(.system(size: 10, weight: .bold))
                    .foregroundStyle(rgb.color(scheme, lift: 0.14))
                Text(tt.label(settings))
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(rgb.color(scheme, lift: 0.14))
                Spacer(minLength: 4)
                if !right.isEmpty {
                    Text(right).font(Typo.num(10.5, .medium)).foregroundStyle(.tertiary)
                }
            }
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(big)
                    .font(.system(size: bigSize, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(Theme.ink(scheme))
                    .contentTransition(.numericText(countsDown: true))
                if !name.isEmpty {
                    Text(name).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                }
                Spacer(minLength: 4)
            }
            if !detail.isEmpty {
                Text(detail).font(.system(size: 10.5)).foregroundStyle(.secondary).lineLimit(1)
            }
            if !where_.isEmpty {
                Text(where_).font(.system(size: 10.5)).foregroundStyle(.tertiary).lineLimit(1)
            }
        }
        .padding(.horizontal, env.space(13))
        .padding(.vertical, env.space(11))
        .frame(maxWidth: .infinity, alignment: .leading)
        .card(env.radius(Radius.lg), tint: tint, look: env.look)
    }

    /* ---------------- 待办 ---------------- */

    private var todoSection: some View {
        let g = store.groups(now: now, settings: settings)
        let cap = todoOpen ? 14 : 5
        let up = Array(g.up.prefix(cap))
        return VStack(alignment: .leading, spacing: env.space(7)) {
            head("待办事项", right: "\(g.up.count) 项待完成" + (g.od.isEmpty ? "" : " · \(g.od.count) 项逾期"))

            if up.isEmpty && g.od.isEmpty {
                emptyRow(store.isPreparing ? "正在同步…" : "暂无待办")
            } else {
                if !up.isEmpty {
                    // ⚠️ 这里**绝对不要**套 GlassEffectContainer。
                    // 容器会把这一组卡片的玻璃合并成单独一层，并且合成在内容**之上**，
                    // 于是每行文字都成了「透过磨砂玻璃看」——整片发糊、对比度掉一半。
                    // 真机截图已验证：容器内的 .card() 行糊、容器外的 .card() 行清晰。
                    VStack(spacing: env.space(7)) {
                        ForEach(up) { t in MiniTaskBar(t: t) }
                    }
                }
                // 装不下就折叠，想看就就地铺开（不再叫用户去看板里看）
                if g.up.count > 5 {
                    moreButton("共 \(g.up.count) 项", $todoOpen,
                               "展开其余 \(g.up.count - 5) 项")
                }
            }

            if !g.od.isEmpty {
                Button {
                    withAnimation(Motion.reveal) { overdueOpen.toggle() }
                } label: {
                    HStack(spacing: 7) {
                        Image(systemName: Icons.warn).font(.system(size: 10))
                            .foregroundStyle(Theme.redDefault.color(scheme, lift: 0.18))
                        Text("已逾期 \(g.od.count) 项")
                            .font(.system(size: 11.5, weight: .medium)).foregroundStyle(.secondary)
                        Spacer(minLength: 4)
                        Image(systemName: "chevron.down")
                            .font(.system(size: 9, weight: .bold)).foregroundStyle(.tertiary)
                            .rotationEffect(.degrees(overdueOpen ? 180 : 0))
                    }
                    .padding(.horizontal, env.space(11))
                    .frame(height: 30)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(RoundedRectangle(cornerRadius: env.radius(Radius.sm), style: .continuous))
                }
                .buttonStyle(.plain)
                .card(env.radius(Radius.sm), tint: Theme.redDefault.color(scheme, lift: 0.86,
                        opacity: scheme == .dark ? 0.10 : 0.08), look: env.look, shadow: false)

                if overdueOpen {
                    VStack(spacing: env.space(6)) {
                        ForEach(Array(g.od.prefix(10))) { t in MiniTaskBar(t: t) }
                    }
                    .transition(.reveal)

                    if g.od.count > 10 {
                        Text("另有 \(g.od.count - 10) 项未列出")
                            .font(.system(size: 10)).foregroundStyle(.tertiary).padding(.leading, 2)
                    }
                }
            }
        }
    }

    /* ---------------- 接下来的课堂 ---------------- */

    private var classSection: some View {
        let dl = Schedule.dayList(now)
        let cur = Schedule.currentSlot(now)
        let curBlock = cur?.blockId
        let nowIdx: Int? = {
            guard Calendar.current.isDate(dl.day, inSameDayAs: now),
                  let first = dl.list.first, let last = dl.list.last,
                  now >= first.start, now < last.end else { return nil }
            return dl.list.filter { $0.end <= now }.count
        }()
        let show = Array(dl.list.enumerated()).suffix(from: max(0, (nowIdx ?? 0) - 1))
            .prefix(classOpen ? 12 : 5)
        let showIdx = (nowIdx ?? 0) > 1 ? (nowIdx! - 1) : 0
        let rest = dl.list.count - show.count - showIdx

        return VStack(alignment: .leading, spacing: env.space(7)) {
            head("接下来的课堂", right: Schedule.dayCaption(dl.day, now: now))

            VStack(spacing: env.space(6)) {
                ForEach(Array(show), id: \.element.id) { pair in
                    let inSession = curBlock != nil && pair.element.blockId == curBlock
                    // 课间（没有正在上的课）时：把「现在」玻璃条叠在两节课之间的缝上，
                    // 图层在课表之上、不占行高 —— 夹在两行之间浮着。
                    if let idx = nowIdx, idx == pair.offset, !inSession {
                        ClassRowView(slot: pair.element, now: now, isNow: false)
                            .overlay(alignment: .top) {
                                NowIndicator(env: env, cur: cur, now: now, compact: true)
                                    .offset(y: -(env.space(6) / 2 + 9))
                                    .transition(.pop)
                            }
                    } else {
                        // 上课中：玻璃条叠在行内居中（image2 那种），行右侧信息挪上条
                        ClassRowView(slot: pair.element, now: now,
                                     isNow: inSession, covered: inSession)
                            .overlay(alignment: .center) {
                                if inSession {
                                    NowIndicator(env: env, cur: cur, now: now, compact: true, withRoom: true)
                                        .transition(.pop)
                                }
                            }
                    }
                }
            }
            .animation(Motion.pop, value: nowIdx)
            if showIdx > 0 {
                Text("上面已略过 \(showIdx) 节").font(.system(size: 10))
                    .foregroundStyle(.tertiary).padding(.leading, 2)
            }
            if rest > 0 || classOpen {
                moreButton("今天还有 \(max(0, rest)) 节", $classOpen, "展开今天全部课程")
            }
        }
    }

    /* ---------------- 最新成绩 ---------------- */

    private var latestSection: some View {
        let cap = scoreOpen ? 8 : 4
        let rows = store.recentWorks(cap, settings: settings)
        let total = store.recentWorks(60, settings: settings).count
        return VStack(alignment: .leading, spacing: env.space(7)) {
            head("最新成绩", right: rows.isEmpty ? "" : "最近 \(rows.count) 项")

            if rows.isEmpty {
                emptyRow(store.isPreparing ? "正在同步…" : "暂无已评分作业")
            } else {
                let gap = env.space(8)
                let cols = min(rows.count, 4)
                let cardW = (W - 2 * Space.md - CGFloat(cols - 1) * gap) / CGFloat(cols)
                FlowRow(spacing: gap, lineSpacing: gap) {
                    ForEach(rows) { w in MiniScoreCard(w: w, width: cardW) }
                }
                if total > 4 {
                    moreButton("共 \(total) 项", $scoreOpen,
                               scoreOpen ? "" : "展开更多成绩")
                }
            }
        }
    }

    /* ---------------- English Corner ---------------- */

    /// 今天有没有 EC、我要不要去、同班有谁。
    /// 用户明确要求放在面板最下面 —— 它不是主线，但每天都会扫一眼。
    @ViewBuilder
    private var ecSection: some View {
        if let info = store.teamsEC, info.ok != false,
           (info.status ?? "none") != "none" || info.hasRoster == true {
            let st = info.status ?? "none"
            let active = info.active == true
            let imIn = info.imIn == true
            let klass = info.klass ?? ""
            let names = info.students ?? []
            let tint: RGB = active ? Theme.redDefault
                                   : (st == "tomorrow" ? Theme.amberDefault : settings.uiAccent)
            let line: String = {
                switch st {
                case "today":    return imIn ? "今天要去（\(klass) 班）" : "今天有 EC，不在名单"
                case "done":     return "今天 EC 已结束"
                case "tomorrow": return imIn ? "明天要去（\(klass) 班）" : "明天有 EC，不在名单"
                case "future":   return "下一场 \(info.date ?? "")"
                case "past":     return "名单已过期"
                case "error":    return "名单读不到"
                default:         return "今天没有 EC"
                }
            }()

            VStack(alignment: .leading, spacing: env.space(7)) {
                head("English Corner", right: "\(info.window ?? "13:00–13:40") · \(info.place ?? "Room E113")")

                HStack(spacing: env.space(9)) {
                    ZStack {
                        Circle().fill(tint.color(scheme).opacity(0.16)).frame(width: 26, height: 26)
                        Image(systemName: imIn ? "person.fill.checkmark" : "bubble.left.and.text.bubble.right.fill")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(tint.color(scheme, lift: 0.10))
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text(line)
                            .font(.system(size: 12.5, weight: .semibold))
                            .foregroundStyle(active ? tint.color(scheme, lift: 0.04)
                                                    : Theme.ink(scheme))
                            .lineLimit(1)
                        if imIn && !names.isEmpty {
                            Text(names.prefix(4).joined(separator: "、")
                                 + (names.count > 4 ? " 等 \(names.count) 人" : ""))
                                .font(.system(size: 10)).foregroundStyle(.tertiary).lineLimit(1)
                        } else if info.hasRoster == true {
                            Text("最新名单 \(info.file ?? "")")
                                .font(.system(size: 10)).foregroundStyle(.tertiary).lineLimit(1)
                        }
                    }
                    Spacer(minLength: 4)
                    if let u = ECRoster.url(info) {
                        Button { ECRoster.open(info, settings: settings) } label: {
                            Image(systemName: u.isFileURL ? "doc.fill" : Icons.open)
                                .font(.system(size: 10.5, weight: .semibold))
                                .foregroundStyle(.secondary)
                                .frame(width: 24, height: 24)
                                .contentShape(Circle())
                        }
                        .buttonStyle(.plain)
                        .help(u.isFileURL ? "打开本地已下载的名单（秒开）" : "打开 EC 名单")
                    }
                }
                .padding(.horizontal, env.space(11))
                .frame(height: 46)
                .frame(maxWidth: .infinity, alignment: .leading)
                .card(env.radius(Radius.sm),
                      tint: tint.color(scheme, lift: 0.86, opacity: scheme == .dark ? 0.13 : 0.10),
                      look: env.look, shadow: false)
            }
        }
    }

    /* ---------------- 快速设置（默认收起，点标题展开） ----------------
       用户反馈：这一块「设置、动画、弹出、上下滑动都特别难用」。原来的做法是
       标题行 + 下面挂一个 glassPane，展开用 `.move(edge: .top)`；问题有三：
         ① 展开出来的四行落在折叠线以下，面板高度却写死 —— 看着像"点了没反应"；
         ② `.move(edge: .top)` 在 ScrollView 里会把下面的内容整体顶一下；
         ③ 收起时右边那串摘要「跟随大看板 · 跟随系统 · 舒适 · 经典 · 玻璃 100%」
            太长，窄面板里挤成一团。
       现在的做法：
         ① 整块是**一张**卡（标题 + 可展开的正文），用 .reveal 过渡；
         ② 展开时面板窗口自己往上长高（见 PanelMetrics.quickExtra），不用滚；
         ③ 摘要换成一排小图标：跟随/独立 · 深浅色 · 配色点 · 密度 · 玻璃。 */

    @ViewBuilder
    private var quickSettings: some View {
        VStack(spacing: 0) {
            Button { toggleQuick() } label: { quickHeader }
                .buttonStyle(.plain)
                .onHover { quickHover = $0 }

            if quickOpen {
                Rectangle().fill(Theme.lineSoft(scheme)).frame(height: 1)
                    .padding(.horizontal, env.space(10))

                VStack(spacing: env.space(7)) {
                    // 这里以前有一行「跟随大看板 / 小看板独立」的开关。
                    // 合并成单 App 后两块界面同进程、共用一套全局色板，
                    // 独立的第二套主题已无意义，整行去掉（设置页也不再出现）。
                    quickRow("主题") {
                        SegmentedTabs(env: env,
                                      items: ThemeMode.allCases.map {
                                          SegItem(id: $0.rawValue, label: $0.label, icon: $0.icon) },
                                      selection: themeModeBinding)
                    }
                    quickRow("密度") {
                        SegmentedTabs(env: env,
                                      items: Density.allCases.map {
                                          SegItem(id: $0.rawValue, label: $0.label) },
                                      selection: Binding(
                                        get: { settings.density.rawValue },
                                        set: { settings.density = Density(rawValue: $0) ?? .comfortable }))
                    }
                    quickRow("主题色") {
                        HStack(spacing: 7) {
                            ForEach(Palettes.all) { p in
                                Button {
                                    withAnimation(Motion.select) { paletteTarget = p.id }
                                } label: {
                                    ZStack {
                                        Circle().fill(RGB(p.accent).color).frame(width: 18, height: 18)
                                        if settings.palette.id == p.id {
                                            Circle().strokeBorder(Color.white, lineWidth: 1.8)
                                                .frame(width: 12, height: 12)
                                                .matchedGeometryEffect(id: "qPal", in: quickNS)
                                        }
                                    }
                                    .contentShape(Circle())
                                }
                                .buttonStyle(.plain)
                                .help("\(p.name) · \(p.en)")
                            }
                            // 主题色微调：改的就是看板那一份强调色（只有一套）
                            ColorSwatch(env: env, hex: settings.accent.hex,
                                        width: 26, height: 18, corner: 5) { h in
                                withAnimation(Motion.select) { settings.accentHex = h }
                            }
                            Spacer(minLength: 0)
                        }
                    }
                    quickRow("玻璃") {
                        GlassSlider(env: env, value: $settings.glassStrength,
                                    range: 0...1, step: 0.05,
                                    width: max(110, W - 2 * Space.md - 46 - 9 - 22),
                                    showValue: false,
                                    valueLabel: { String(format: "%.0f%%", $0 * 100) })
                    }

                    HStack(spacing: 5) {
                        Image(systemName: "info.circle")
                            .font(.system(size: 9, weight: .semibold))
                        Text("更多选项在「设置」页")
                            .font(.system(size: 10))
                        Spacer(minLength: 0)
                    }
                    .foregroundStyle(Theme.ink3(scheme))
                    .padding(.horizontal, env.space(11))
                    .padding(.top, 2)
                }
                .padding(.vertical, env.space(10))
                .transition(.reveal)
            }
        }
        .card(env.radius(Radius.sm), look: env.look, shadow: false)
        .id("quick")
        // 高度变化 + 内容浮现都用同一个弹簧，才像一块东西在展开
        .animation(Motion.reveal, value: quickOpen)
    }

    private func toggleQuick() {
        withAnimation(Motion.reveal) { quickOpen = !quickOpen }
        setQuickExtra(quickOpen)
    }

    private var quickHeader: some View {
        HStack(spacing: 7) {
            Image(systemName: "slider.horizontal.3")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(settings.uiAccent.color(scheme, lift: 0.10))

            Text("快速设置")
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(Theme.ink(scheme))

            Spacer(minLength: 6)

            if !quickOpen { summaryChips.transition(.opacity) }

            Image(systemName: "chevron.down")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(Theme.ink3(scheme))
                // 箭头转 180° 比换成 chevron.up 好：是"转过去"而不是"换个字"
                .rotationEffect(.degrees(quickOpen ? 180 : 0))
        }
        .padding(.horizontal, env.space(11))
        .frame(height: 34)
        .background {
            if quickHover {
                RoundedRectangle(cornerRadius: env.radius(Radius.sm), style: .continuous)
                    .fill(env.accent.color(scheme).opacity(scheme == .dark ? 0.07 : 0.05))
            }
        }
        .contentShape(RoundedRectangle(cornerRadius: env.radius(Radius.sm), style: .continuous))
    }

    /// 收起时的一排小摘要。原来是一整句「跟随大看板 · 跟随系统 · 舒适 · 经典 · 玻璃 100%」，
    /// 在 470pt 宽的面板里挤成一团。换成图标 + 极短文字：一眼扫完，不占地方。
    private var summaryChips: some View {
        HStack(spacing: 6) {
            Image(systemName: "link")
                .font(.system(size: 8.5, weight: .bold))
            Image(systemName: settings.theme.icon)
                .font(.system(size: 9, weight: .semibold))
            Circle()
                .fill(settings.uiAccent.color(scheme, lift: 0.06))
                .frame(width: 7, height: 7)
            Text(settings.density.label)
            Text(String(format: "%.0f%%", settings.glassStrength * 100))
                .monospacedDigit()
        }
        .font(.system(size: 9.5, weight: .medium))
        .foregroundStyle(Theme.ink3(scheme))
        .lineLimit(1)
        .fixedSize(horizontal: true, vertical: false)
        .help(summaryLine)
    }

    /// 完整摘要挪到 tooltip 里，信息没丢，只是不再占版面
    private var summaryLine: String {
        "\(settings.theme.label) · \(settings.density.label) "
             + "· \(settings.palette.name) · 玻璃 \(Int(settings.glassStrength * 100))%"
    }

    /* ---------------- 面板里的主题控件改的是谁 ----------------
       合并成单 App 后只有一套主题：面板里调亮暗/主题色 = 调看板的。
       （以前那种「小看板自己一套」的分支随合并一起去掉了。） */

    private var themeModeBinding: Binding<String> {
        Binding(get: { settings.theme.rawValue },
                set: { settings.theme = ThemeMode(rawValue: $0) ?? .system })
    }

    private var paletteTarget: String {
        get { settings.palette.id }
        nonmutating set {
            // 换配色时清掉自定义强调色，否则「选了新配色却没变」
            settings.accentHex = Palettes.by(newValue).accent
            settings.paletteID = newValue
            settings.applyPalette()
        }
    }

    private func quickRow<C: View>(_ label: String, @ViewBuilder content: () -> C) -> some View {
        HStack(spacing: env.space(9)) {
            Text(label).font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(Theme.ink2(scheme))
                .frame(width: 38, alignment: .leading)
            content()
            Spacer(minLength: 0)
        }
        .padding(.horizontal, env.space(9))
    }

    /* ---------------- 底部 ---------------- */

    private static let barH: CGFloat = 34

    private var bottomBar: some View {
        Group {
            if confirmingQuit {
                confirmBar.transition(.pop)
            } else {
                expandButton.transition(.pop)
            }
        }
        .frame(height: PanelView.barH)
        .animation(Motion.pop, value: confirmingQuit)
    }

    private var expandButton: some View {
        Button { openDashboard(section: nil) } label: {
            HStack(spacing: 7) {
                Image(systemName: Icons.open)
                    .font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
                Text("展开完整看板")
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(Theme.ink(scheme))
                Spacer(minLength: 4)
                // 别写死：分区加一个（比如 Teams）就会和实际对不上
                Text(DashSection.allCases.map(\.title).joined(separator: " · "))
                    .font(.system(size: 10.5)).foregroundStyle(.tertiary)
                    .lineLimit(1)
                Image(systemName: "arrow.up.forward")
                    .font(.system(size: 10, weight: .bold)).foregroundStyle(.secondary)
            }
            .padding(.horizontal, env.space(12))
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(height: PanelView.barH)
            .contentShape(RoundedRectangle(cornerRadius: env.radius(Radius.sm), style: .continuous))
        }
        .buttonStyle(.plain)
        .card(env.radius(Radius.sm),
              tint: env.accent.color(scheme, lift: 0.86, opacity: scheme == .dark ? 0.20 : 0.20),
              look: env.look)
    }

    private var confirmBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.circle.fill")
                .font(.system(size: 12))
                .foregroundStyle(Theme.amberDefault.color(scheme, lift: 0.12))
            Text("确定退出整个 App？")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Theme.ink(scheme))
            Spacer(minLength: 4)
            Button("取消") { confirmingQuit = false }
                .buttonStyle(.plain)
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 10).frame(height: 24)
                .background(Capsule().fill(Color.primary.opacity(0.07)))
            Button("退出") { NSApp.terminate(nil) }
                .buttonStyle(.plain)
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(Theme.redDefault.color(scheme, lift: 0.14))
                .padding(.horizontal, 10).frame(height: 24)
                .background(Capsule().fill(Theme.redDefault.color(scheme, lift: 0.14).opacity(0.14)))
        }
        .padding(.horizontal, env.space(12))
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: PanelView.barH)
        .card(env.radius(Radius.sm), look: env.look)
    }

    /* ---------------- 零件 ---------------- */

    private func head(_ title: String, right: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(title).font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(Theme.ink(scheme))
            Spacer(minLength: 4)
            Text(right).font(.system(size: 10.5)).foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 2)
        .padding(.top, 1)
    }

    private func emptyRow(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 12)).foregroundStyle(.tertiary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, env.space(13))
            .frame(height: 40)
            .card(env.radius(Radius.sm), look: env.look, shadow: false)
    }

    /* ---------------- 动作 ---------------- */

    private func openDashboard(section: DashSection?) {
        // ★ 这里以前是 `settings.dashboardSection = section.rawValue`。
        //   于是「打开看板时停在哪一页」这个设置被小面板的每一次点击悄悄改写：
        //   在菜单栏里点过一次「设置」，从此每次开 App 都落在设置页。
        //   现在改成**一次性跳转请求**：本次跳到那一页，但不动默认值。
        if let section { settings.jumpToSection = section }
        // 合并成一个 App 之后，主窗口就在同一个进程里 —— 直接把它唤到面前，
        // 不再去 launch 另一个 .app（那正是「两个 App 各弹一遍通知」的老毛病）。
        MainWindow.bring()
        if section == nil { close() }
    }
}

/* ============================================================
   面板内的小件（都比看板里的紧凑一档）
   ============================================================ */

struct MiniTaskBar: View {
    let t: TaskVM
    @EnvironmentObject var settings: BoardSettings
    @Environment(\.colorScheme) private var scheme

    private var env: Env { Env(scheme: scheme, settings: settings) }

    var body: some View {
        let c = t.band.color(scheme, accent: settings.uiAccent)
        Button {
            // 点行 → 液态玻璃详情单（宽度按面板自适应）
            TaskDetailCenter.shared.open(t, width: CGFloat(settings.panelWidth) - 56)
        } label: {
            HStack(spacing: 9) {
                HStack(spacing: 2) {
                    Capsule().fill(c).frame(width: 3.5, height: 18)
                    Spacer(minLength: 0)
                }
                .frame(width: 12)

                // 主次不能颠倒：**作业名**才是要干的事，科目只是个归类。
                // 这里以前是「科目 12.5 medium + 主色 ink」配「作业名 11.5 secondary」——
                // 于是「地理」比「Geologic Poster」显眼，一眼扫过去满屏都是科目，
                // 真正要做的事反而灰掉了。现在对齐主看板卡片：
                // 科目用小一号的学科色，作业名用主色。
                Text(t.subject)
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(Subject.rgb(Subject.key(t.fullSubject), settings)
                                        .color(scheme, lift: 0.12))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    // 以前这里是 .frame(width: 34)：中文两字刚好，英文科名
                    // （Grammar / Grade 10…）直接变成「Gra…」。
                    // 改成内容自适应 + minWidth 36（中文两字兜底）。
                    // 但只有下限不行：极端的长科名（Cross-Disciplinary Studies）
                    // 会一路吃掉整行，把右边的作业标题压到贴住/看不见 ——
                    // 所以再加一个上限，超了就自己截断，标题永远有位置。
                    .frame(minWidth: 36, maxWidth: 92, alignment: .leading)

                Text(t.title)
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(Theme.ink(scheme))
                    .lineLimit(1)
                    .truncationMode(.tail)

                Spacer(minLength: 6)

                // 独立「打开」按钮：只有点它才跳原网页，点行其余地方弹详情单
                Button {
                    LinkOpen.go(t.url, source: "managebac", settings: settings)
                } label: {
                    Image(systemName: "arrow.up.forward")
                        .font(.system(size: 10.5, weight: .bold))
                        .foregroundStyle(c)
                        .frame(width: 30, height: 26)
                        .background(Capsule().fill(c.opacity(0.13)))
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .help("在 ManageBac 中打开原网页")

                Text(t.leftText)
                    .font(.system(size: 11, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(c)
                    .lineLimit(1)
                    .fixedSize()
                    .padding(.horizontal, 8).padding(.vertical, 3.5)
                    .background(Capsule().fill(c.opacity(0.15)))
            }
            .padding(.horizontal, env.space(11))
            .frame(height: 40)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(RoundedRectangle(cornerRadius: env.radius(Radius.sm), style: .continuous))
        }
        .buttonStyle(.plain)
        .card(env.radius(Radius.sm), look: env.look, shadow: false)
        .help("\(t.fullSubject)\n\(t.title)\n\(t.leftText)\n点击在 ManageBac 中打开")
        .accessibilityLabel("\(t.subject) \(t.title)，\(t.leftText)")
    }
}

struct MiniScoreCard: View {
    let w: RecentVM
    var width: CGFloat
    @EnvironmentObject var settings: BoardSettings
    @Environment(\.colorScheme) private var scheme

    private var env: Env { Env(scheme: scheme, settings: settings) }

    var body: some View {
        let rgb = Subject.rgb(w.key, settings)
        let c = rgb.color(scheme, lift: 0.16)
        Button {
            if let u = w.url { LinkOpen.go(u, source: "managebac", settings: settings) }
        } label: {
            VStack(alignment: .leading, spacing: 3) {
                Text(w.label)
                    .font(.system(size: 9.5, weight: .bold))
                    .foregroundStyle(c).lineLimit(1)
                Text(w.title)
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(Theme.ink(scheme))
                    .lineLimit(3)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                if let s = w.scoreNum, let o = w.scoreOutOf, o > 0 {
                    MiniBar(env: env, value: s / o,
                            color: w.good ? Theme.greenDefault : Theme.amberDefault, height: 3)
                }
                Text(w.scoreText)
                    .font(.system(size: 10, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(w.good ? Theme.greenDefault.color(scheme, lift: 0.10)
                                            : Theme.amberDefault.color(scheme, lift: 0.10))
                    .lineLimit(1).minimumScaleFactor(0.75)
                // 出分时间（bridge 留存；没有就落到截止时间）
                Text(gradedAtShort(w.gradedAt) ?? w.dueText)
                    .font(.system(size: 8.5, weight: .medium))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1).minimumScaleFactor(0.7)
            }
            .padding(.horizontal, 9).padding(.vertical, 8)
            .frame(width: width, height: 108, alignment: .topLeading)
            .contentShape(RoundedRectangle(cornerRadius: env.radius(Radius.sm), style: .continuous))
        }
        .buttonStyle(.plain)
        .card(env.radius(Radius.sm), look: env.look, shadow: false)
        .help("\(w.label) · \(w.title)\n\(w.dueText) · \(w.grade ?? "") \(w.scoreText)\n出分：\(gradedAtText(w.gradedAt) ?? "未知")")
    }
}
