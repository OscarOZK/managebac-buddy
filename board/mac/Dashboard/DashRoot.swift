import SwiftUI
import AppKit

/* ======================================================================
   ManageBac-Buddy · 主窗口
   自定义骨架（不用 NavigationSplitView），为的是让液态玻璃完全贯穿：
     左：玻璃侧边栏（分区导航 + 状态）
     右：内容区（分区标题 + 滚动内容）
   ====================================================================== */

import SwiftUI
import AppKit


/* ---------------- 根视图 ---------------- */

struct DashRoot: View {
    @ObservedObject var store: DataStore
    @ObservedObject private var ai = AIEngine.shared
    @EnvironmentObject var settings: BoardSettings
    @Environment(\.colorScheme) private var scheme

    @State private var section: DashSection = .todo
    @State private var appliedDefault = false
    @State private var now = PreviewFlags.nowOverride ?? Date()
    @State private var search = PreviewFlags.search
    @State private var appeared = false
    /// 「本次运行已经关掉月圆上线提示」。
    /// 刻意只活在内存里（不落 settings.json）：档期内的**每一次启动**都要重新弹，
    /// 见 body 里那段注释。
    @State private var moonNoticeClosed = false
    /// 换分区的方向：true = 往后翻，false = 往前翻。
    /// 交给过渡决定内容从左边还是右边滑进来 —— 方向感是"优雅"的一半。
    @State private var forward = true
    @FocusState private var searchFocused: Bool

    /// 侧边栏悬停的分区（只有没选中的项才画悬停底）
    @State private var hovering: DashSection?

    /// 侧边栏选中块在选项之间滑动用的命名空间
    @Namespace private var navNS

    private var env: Env { Env(scheme: scheme, settings: settings) }

    /// 灵析 AI 的网页引擎什么时候该露面。
    ///
    /// 只有一种情况：用户主动点「原站 / 去登录」。
    /// 以前还有一条「人在灵析 AI 页但没登录就自动摊开登录页」——
    /// 那正是用户抱怨的「页面里也没有相关显示和跳转按钮」：
    /// 一进板块就被整个 DeepSeek 网站盖住，看不到状态，也没有明确的回到看板的路。
    /// 现在未登录时由 AISection 自己渲染一张状态卡（含「去登录」按钮）。
    private var aiSiteOn: Bool { ai.showSite }

    /// 统一的搜索查询对象：全应用一套归一化 / 别名 / 多词 AND 规则
    private var query: Search.Query { Search.parse(search) }

    var body: some View {
        ZStack {
            Theme.page(scheme).ignoresSafeArea()
            // 限时主题才有的氛围底纹：把校园实拍糊一层垫在底下
            ThemeBackdrop(scheme: scheme).ignoresSafeArea()

            HStack(spacing: 0) {
                sidebar
                Divider().overlay(Theme.lineSoft(scheme))
                content
            }

            // 灵析 AI 的网页引擎。全局只挂一次（切分区、切设置都不重建），
            // 隐藏时 opacity 0 且不接收点击 —— 它只在两种情况下露面：
            //   ① 用户在灵析 AI 页但还没登录；② 用户主动点「原站」。
            //
            // 离屏自检时整块不挂：WKWebView 是 NSViewRepresentable，
            // ImageRenderer 画不出来，会画成一张黄底红圈占位图盖住整屏。
            if !PreviewFlags.offscreen {
                AIBackend()
                    .opacity(aiSiteOn ? 1 : 0)
                    .allowsHitTesting(aiSiteOn)
                    .ignoresSafeArea()
                    .zIndex(8)

                if aiSiteOn {
                    VStack {
                        HStack {
                            Button {
                                AIEngine.shared.showSite = false
                                AIEngine.shared.checkNow()
                            } label: {
                                HStack(spacing: 6) {
                                    Image(systemName: "chevron.left").font(.system(size: 10.5, weight: .bold))
                                    Text(ai.isAuthed ? "回到灵析 AI" : "我已登录好了")
                                        .font(.system(size: 12, weight: .semibold))
                                }
                                .padding(.horizontal, 13).frame(height: 30)
                                .background(.ultraThinMaterial, in: Capsule())
                                .overlay(Capsule().strokeBorder(Color.primary.opacity(0.14)))
                            }
                            .buttonStyle(.plain)
                            .help("收起网页，回到看板里的对话界面")
                            Spacer()
                        }
                        Spacer()
                    }
                    .padding(.leading, 244)
                    .padding(.top, 46)
                    .zIndex(9)
                }
            }

            // 任务详情单宿主：永远浮在最上层（上一版就是少了这一笔，
            // detailTask 置了位却没人画 —— 点卡片「没反应」的根因）
            TaskDetailHost()

            // 学科柱状图宿主：点「各科明细」里的一行会置位 SubjectChartCenter.shared.row，
            // 同样必须有一个常驻的宿主把它画出来，否则就是「点了没反应」。
            SubjectChartHost()

            // Teams 任务预览宿主。★ 必须挂在**窗口根部的 ZStack** 上 ★
            // 以前它挂在 TeamsSection 的滚动内容里，于是「居中」居的是整篇长文
            // 的中点：任务一多，小窗就掉到视口下方、被窗口底边切掉一半。
            // 挂到这里之后，不管被点的卡片在哪儿，小窗永远在视口正中。
            TaskPreviewHost()

            // 中秋「月圆 · LunaOS」的上线提示。放最上面一层 —— 它是「新主题来了」
            // 这件事唯一的告知入口。
            //
            // 三个条件缺一不可：
            //   · MoonFest.available —— 主题本身在可用的日子里（见 MidAutumn.swift
            //     的时间闸门，不在日子上时连主题卡都不会出现在设置里）；
            //   · 本次运行还没关过它。★ 注意这个「还没关过」是**内存态**（下面的
            //     @State），不是 settings.json 里的持久标记 —— 用户明确要求
            //     「无论第一次启动还是关掉 App 再启动，只要在这段时间里都要弹」。
            //     写进设置文件就成了「只弹一次」，正是要避免的。
            //   · 离屏自检的 --nomoon 开关。
            if MoonFest.available && !PreviewFlags.hideMoonNotice && !moonNoticeClosed {
                MoonFestNotice(onClose: { moonNoticeClosed = true })
                    .transition(.opacity)
            }
        }
        .task { await store.start() }
        .onAppear {
            if PreviewFlags.nowOverride == nil { now = Date() }
            if !appliedDefault {
                appliedDefault = true
                // 菜单栏小面板点过来的「这一次去那一页」优先 —— 但它不改默认值
                if let jump = settings.jumpToSection {
                    section = jump
                    settings.jumpToSection = nil
                } else {
                    let want = PreviewFlags.section.isEmpty ? settings.dashboardSection : PreviewFlags.section
                    if let raw = DashSection(rawValue: want) { section = raw }
                }
            }
            appeared = true
            bindHotkeys()
            Hotkeys.install()
        }
        .onReceive(settings.$jumpToSection) { want in
            // 主窗口已经开着时，小面板点一下就当场跳过去
            guard let want else { return }
            settings.jumpToSection = nil
            go(want)
        }
        .onReceive(settings.objectWillChange) { _ in
            // 设置一改就重绑：快捷键改完立刻生效，不用重启
            DispatchQueue.main.async { bindHotkeys() }
        }
        // 两参数写法：旧版 `onChange(of:perform:)` 在 macOS 14 起已弃用，
        // 编译一次就报一次警告，留着会淹没真正有用的告警。
        .onChange(of: section) { _, s in
            // 离开灵析 AI 就把原站收起来，否则它会一直盖在别的分区上
            if s != .ai { AIEngine.shared.showSite = false }
        }
        // ★ 秒针：首页那个大倒计时靠它走 ★
        //
        // 原来这里是：
        //   .onReceive(Timer.publish(every: 1, on: .main, in: .common).autoconnect()) { … }
        // 看起来没问题，其实是这个「大时钟卡住不动」的根因：
        // `onReceive` 的第一个参数**每次 body 重算都会重新求值**。而这个视图
        // 恰好每秒都在重算（now 变 → body 重算 → 又建一个全新的 Timer 发布者
        // → 刚建立的订阅当场被替换）。新的订阅永远等不到它的第一次触发就被
        // 下一次重建顶掉了，于是 05:34 这种数字会一直钉在那里。
        // 用 .task 起的循环只在视图出现时启动一次、随视图消失自动取消，
        // 没有任何「每次重算都重建」的机会。
        .task {
            await secondTick()
        }
        // 定时拉 Teams。
        // 同样不能用 onReceive(Timer.publish(...))，理由和上面一模一样 ——
        // 120 秒的定时器在这个每秒重算的视图里永远等不到第一次触发，
        // 也就是说 Teams 数据平时其实**只在手动刷新时才更新**。
        .task {
            if PreviewFlags.offscreen { return }
            while !Task.isCancelled {
                do { try await Task.sleep(nanoseconds: 120_000_000_000) } catch { return }
                await store.loadTeams()
            }
        }
        // 注意：这里**不要**把当前分区回写进 settings。
        // 之前每次切分区都写一次 dashboardSection，于是「打开看板时停在哪一页」
        // 这个设置永远等于最后一次点的分区（停在设置页 → 下次开机进设置页）。
        // 用户要求「打开看板默认进待办」：设置项是唯一权威，默认值就是 todo。
        .background(WindowConfigurator())
    }

    /// 每秒把 `now` 推到当前时刻 —— 一切倒计时的唯一时间源。
    ///
    /// 对齐到「整秒边界」再唤醒：如果只 sleep 1 秒，就会有肉眼可见的抖动
    /// （有时 0.1 秒后跳、有时要等 0.9 秒），读起来不像一个精准倒计时。
    private func secondTick() async {
        if PreviewFlags.nowOverride != nil { return }   // 离屏自检：时间冻结
        while !Task.isCancelled {
            let t = Date()
            now = t
            let frac = t.timeIntervalSince1970.truncatingRemainder(dividingBy: 1)
            let wait = max(0.05, 1.0 - frac)
            do {
                try await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
            } catch {
                return          // 视图消失 → 任务取消 → 正常退出
            }
        }
    }

    /* ---------------- 快捷键 ----------------
       全部走设置里那些可改的绑定，没有写死的组合键。 */

    private func bindHotkeys() {
        Hotkeys.bind("dash.refresh", settings.keyRefresh) {
            Task { await store.load(force: true); await store.loadTeams() }
        }
        Hotkeys.bind("dash.search", settings.keySearch) {
            withAnimation(Motion.ease(Motion.Dur.quick)) { searchFocused = true }
        }
        Hotkeys.bind("dash.next", settings.keyNextSection) { step(1) }
        Hotkeys.bind("dash.prev", settings.keyPrevSection) { step(-1) }
        Hotkeys.bind("dash.todo", settings.keySectionTodo) { go(.todo) }
        Hotkeys.bind("dash.teams", settings.keySectionTeams) { go(.teams) }
        Hotkeys.bind("dash.classes", settings.keySectionClasses) { go(.classes) }
        Hotkeys.bind("dash.grades", settings.keySectionGrades) { go(.grades) }
        Hotkeys.bind("dash.ai", settings.keySectionAI) { go(.ai) }
        Hotkeys.bind("dash.settings", settings.keyOpenSettings) { go(.settings) }
        Hotkeys.bind("dash.theme", settings.keyToggleTheme) {
            // 注意：景观主题（月圆 · LunaOS）会强制深色，这时按了看不出变化 ——
            // 但这个切换照写不误：它记的是**用户自己的偏好**，等换回别的主题
            // 立刻就生效。反过来「按一下就把主题换掉」才是真的破坏用户设置。
            withAnimation(Motion.ease(Motion.Dur.base)) {
                settings.theme = (settings.theme == .dark) ? .light : .dark
            }
        }
    }

    /// 换到指定分区。方向按分区在侧边栏里的先后算 ——
    /// 点「成绩」跳到「待办」时内容应该从左边回来，而不是永远从右边进。
    private func go(_ s: DashSection) {
        guard s != section else { return }
        let all = DashSection.allCases
        let from = all.firstIndex(of: section) ?? 0
        let to = all.firstIndex(of: s) ?? 0
        forward = to > from
        withAnimation(Motion.page) { section = s }
    }

    /// 分区前后翻页，到头就绕回去
    private func step(_ d: Int) {
        let all = DashSection.allCases
        guard let i = all.firstIndex(of: section) else { return }
        let n = (i + d + all.count) % all.count
        forward = d > 0
        withAnimation(Motion.page) { section = all[n] }
    }

    /* ---------------- 侧边栏 ---------------- */

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            // 顶部留给红绿灯 + 标题 —— 加一抹朱砂印 + 短竖线，让侧边栏从顶就
            // 有"中式水墨"的味道，但只在宣纸主题下明显，其他主题走淡墨。
            HStack(spacing: 9) {
                ZStack {
                    RoundedRectangle(cornerRadius: env.radius(9), style: .continuous)
                        .fill(LinearGradient(colors: [env.accent.color(scheme, lift: 0.22),
                                                      env.accent.color(scheme, lift: -0.05)],
                                             startPoint: .topLeading, endPoint: .bottomTrailing))
                        .frame(width: 30, height: 30)
                    Text("📂").font(.system(size: 15))
                }
                .shadow(color: env.accent.color(scheme).opacity(0.30), radius: 7, y: 2)

                VStack(alignment: .leading, spacing: 1) {
                    Text("ManageBac")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Theme.ink(scheme))
                    HStack(spacing: 5) {
                        Text("看板")
                            .font(.system(size: 10.5))
                            .foregroundStyle(.tertiary)
                        // 「今日」朱砂小印 —— 宣纸主题下用朱砂，其他主题下用淡墨
                        InkSeal(char: "雅", size: 11, env: env)
                            .accessibilityHidden(true)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, env.space(14))
            .padding(.top, 30)
            .padding(.bottom, env.space(16))
            // 顶部这块是纯展示，正好拿来当拖拽区：拖动它可以移动窗口
            .overlay { WindowDragArea() }
            .help("拖动这里可以移动窗口")

            VStack(spacing: 3) {
                ForEach(DashSection.allCases) { s in
                    navItem(s)
                }
            }
            .padding(.horizontal, 9)

            Spacer(minLength: 10)

            // 中秋小景。为什么落在这儿：侧栏这一段是全 App 唯一「不放任何控件」
            // 的空档 —— 上面是导航、下面是状态栏，中间本来是纯留白。
            // 节日元素只塞在这里，才谈得上「不影响功能、不挡模块和按钮」。
            // 里面有四样可点的东西：玉兔（跳一下并落一串金桂）、月亮（放大）、
            // 灯笼（点亮并摆动），空处点一下也会落桂。
            if settings.palette.drawn == "midautumn" {
                MidAutumnGrove(env: env)
                    .frame(height: 158)
                    .padding(.horizontal, 13)
                    .padding(.bottom, env.space(10))
                    .transition(.opacity)
            }

            statusFooter
                .padding(.horizontal, 13)
                .padding(.bottom, env.space(14))
        }
        .frame(width: 226)
        .background {
            // 侧边栏整块走原生液态玻璃；关掉透明效果时退化成实色
            if PreviewFlags.flat || settings.reduceTransparency {
                Color.white.opacity(scheme == .dark ? 0.045 : 0.55)
            } else {
                Rectangle().fill(.ultraThinMaterial)
            }
        }
        .overlay(alignment: .trailing) {
            Rectangle().fill(Theme.lineSoft(scheme)).frame(width: 1)
        }
    }

    private func navItem(_ s: DashSection) -> some View {
        let on = section == s
        return Button {
            go(s)
        } label: {
            HStack(spacing: 9) {
                // SF Symbol 图标
                Image(systemName: s.icon)
                    .font(.system(size: 13, weight: .semibold))
                    .frame(width: 18)
                    .foregroundStyle(on ? env.accent.color(scheme, lift: 0.14) : .secondary)

                Text(s.title)
                    .font(.system(size: 13.5, weight: on ? .semibold : .medium))
                    .foregroundStyle(on ? Theme.ink(scheme) : Color.secondary)

                // 选中 / 悬停时，右侧浮一枚迷你朱砂印 —— 平时不显示，
                // 出现有过渡；朱砂在宣纸主题下最浓，其他主题退化为淡朱。
                if on || hovering == s {
                    InkSeal(char: s.seal, size: 12, env: env)
                        .transition(.scale(scale: 0.6).combined(with: .opacity))
                }

                Spacer(minLength: 0)

                if s == .todo {
                    let c = store.bandCounts(settings: settings)
                    let n = c.red + c.yellow + c.blue
                    if n > 0 {
                        Text("\(n)")
                            .font(.system(size: 10.5, weight: .bold))
                            .monospacedDigit()
                            .foregroundStyle(.white)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Capsule().fill(Theme.redDefault.color(scheme, lift: 0.06)))
                            .contentTransition(.numericText())
                    }
                }
            }
            .padding(.horizontal, 10)
            .frame(height: env.space(35))
            .contentShape(RoundedRectangle(cornerRadius: env.radius(9), style: .continuous))
            .background {
                if on {
                    // matchedGeometryEffect：整块白色高亮从上一个分区**滑**到当前分区。
                    // 这是侧边栏里最有"分量"的一次位移，比高亮原地闪现耐看得多。
                    RoundedRectangle(cornerRadius: env.radius(9), style: .continuous)
                        .fill(env.scheme == .dark ? Color.white.opacity(0.11) : Color.white.opacity(0.92))
                        .shadow(color: .black.opacity(0.10), radius: 4, y: 1.5)
                        .matchedGeometryEffect(id: "navSel", in: navNS)
                } else if hovering == s {
                    RoundedRectangle(cornerRadius: env.radius(9), style: .continuous)
                        .fill(Color.primary.opacity(env.scheme == .dark ? 0.06 : 0.04))
                }
            }
            .overlay(alignment: .leading) {
                if on {
                    Capsule().fill(env.accent.color(scheme, lift: 0.14))
                        .frame(width: 3, height: 16)
                        .offset(x: -6)
                        .matchedGeometryEffect(id: "navBar", in: navNS)
                }
            }
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 ? s : (hovering == s ? nil : hovering) }
        .animation(Motion.hover, value: hovering)
        .help(s.tagline)
        .accessibilityLabel(s.title)
        .accessibilityAddTraits(on ? [.isSelected] : [])
    }

    private var statusFooter: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 6) {
                Circle()
                    .fill(store.statusColor(scheme, accent: settings.accent))
                    .frame(width: 6.5, height: 6.5)
                    .shadow(color: store.statusColor(scheme, accent: settings.accent).opacity(0.6), radius: 3)
                Text(store.status.text)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
            }
            HStack(spacing: 6) {
                Image(systemName: Icons.clock).font(.system(size: 9.5))
                Text(store.subtitle).font(.system(size: 10.5))
                Spacer(minLength: 0)
            }
            .foregroundStyle(.tertiary)

            HStack(spacing: 6) {
                Button {
                    Task { await store.load(force: true) }
                } label: {
                    HStack(spacing: 5) {
                        SpinIcon(spinning: store.busy)
                            .foregroundStyle(store.busy ? settings.accent.color(scheme, lift: 0.06)
                                                         : Theme.ink(scheme))
                        Text(store.busy ? "抓取中" : "刷新")
                            .font(.system(size: 11, weight: .semibold))
                    }
                    .foregroundStyle(Theme.ink(scheme))
                    .frame(maxWidth: .infinity)
                    .frame(height: 28)
                    .contentShape(RoundedRectangle(cornerRadius: env.radius(8), style: .continuous))
                }
                .buttonStyle(.plain)
                .card(env.radius(Radius.sm), look: env.look, shadow: false)
                .help("立即重新抓取（⌘R）")

                Button {
                    // 走统一的 LinkOpen：这里以前是裸的 NSWorkspace.shared.open，
                    // 于是「一律使用内置浏览器」对这颗按钮无效。
                    LinkOpen.go(DataStore.manageBac, source: "managebac", settings: settings)
                } label: {
                    Image(systemName: Icons.open)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 30, height: 28)
                        .contentShape(RoundedRectangle(cornerRadius: env.radius(8), style: .continuous))
                }
                .buttonStyle(.plain)
                .card(env.radius(Radius.sm), look: env.look, shadow: false)
                .help("在浏览器中打开 ManageBac")
            }
        }
    }

    /* ---------------- 内容区 ---------------- */

    private var sections: some View {
        VStack(alignment: .leading, spacing: settings.density.sectionGap) {
            switch section {
            case .todo:     TodoSection(store: store, now: now, search: search)
            case .teams:    TeamsSection(store: store, search: search)
            case .classes:  ClassesSection(store: store, now: now, search: search)
            case .grades:   GradesSection(store: store, search: search)
            case .ai:       AISection()
            case .settings: SettingsSection()
            }
        }
        .padding(.horizontal, env.space(Space.xxl))
        .padding(.top, env.space(8))
        .padding(.bottom, env.space(48))
        .frame(maxWidth: 1180, alignment: .leading)
        .frame(maxWidth: .infinity, alignment: .center)
    }

    private var content: some View {
        VStack(spacing: 0) {
            header
            // 设置页的「实时预览」固定在滚动区之外 ——
            // 用户要求它始终在设置最上方，滚到哪都看得见，所以不能塞进 ScrollView。
            if section == .settings {
                SettingsPreviewStrip()
                    .padding(.horizontal, env.space(Space.xxl))
                    .padding(.bottom, env.space(6))
                    .transition(.reveal)
            }
            // 这里必须是 .top：ZStack 默认居中，内容比容器矮的时候（比如 Teams
            // 还没登录、只有一张连接卡）整块会被推到垂直中间 —— 标题和搜索框
            // 却还在顶上，看起来就像页面「塌下去了」。顶对齐之后，
            // 不管内容多高、有没有外层 ScrollView，第一行永远贴着标题。
            ZStack(alignment: .topLeading) {
                if section == .ai {
                    // 交互型分区：自己占满高度、自己滚。
                    // 套进外层 ScrollView 会和外层抢滚轮，而且输入框没法钉在底部。
                    AISection()
                } else if PreviewFlags.noScroll {
                    sections
                } else {
                    // 每个分区一棵自己的 ScrollView，`.id` 换掉它之后滚动位置
                    // 自然回到顶部（新分区从第一屏开始，符合预期）。
                    ScrollView(.vertical) {
                        sections
                    }
                    .scrollIndicators(.automatic)
                }
            }
            .id(section)
            // 方向感知的推入推出：往后翻从右边进来，往前翻从左边回来。
            // 直接用 .move(edge:) 会把 1100pt 宽的内容整幅推过屏幕，很吵；
            // 这里只走 30pt + 淡入 + 0.988 缩放，看得见方向但不晃眼。
            .transition(.pageSlide(forward))
        }
        // 位移过程中旧视图会往左溢出到侧边栏那边去，裁掉才干净
        .clipped()
        // alignment 必须是 .top：`.frame(maxHeight:)` 默认把内容**垂直居中**，
        // 于是「内容比窗口矮」的分区（Teams 没登录时只有一张卡）会整页往下掉，
        // 而侧边栏还钉在顶上，看着像页面塌了一半。内容够高时两者没有区别。
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var header: some View {
        HStack(alignment: .center, spacing: env.space(14)) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 9) {
                    Text(section.title).font(Typo.display)
                        .foregroundStyle(Theme.ink(scheme))
                        // 标题与副标题用插值过渡：换分区时字会「化」过去，
                        // 而不是硬切。副标题也会跟着淡出淡入。
                        .contentTransition(.interpolate)
                    if section == .todo, !settings.hiddenList.isEmpty {
                        Text("已隐藏 \(settings.hiddenList.count) 个关键词")
                            .font(.system(size: 10.5, weight: .medium))
                            .foregroundStyle(.tertiary)
                            .padding(.horizontal, 7).padding(.vertical, 3)
                            .background(Capsule().fill(Color.primary.opacity(0.055)))
                    }
                }
                Text(section.tagline)
                    .font(.system(size: 12.5))
                    .foregroundStyle(.secondary)
                    .contentTransition(.interpolate)
            }
            Spacer(minLength: env.space(12))

            if section != .settings && section != .ai {
                searchBox
                    .transition(.pop)
            }

            if let hint = store.sessionHint {
                Pill(env: env, text: "登录已失效", color: Theme.amberDefault, icon: Icons.warn, bold: true)
                    .help(hint)
            }
        }
        .padding(.horizontal, env.space(Space.xxl))
        .padding(.top, 22)
        .padding(.bottom, env.space(18))
        .frame(maxWidth: 1180)
        .frame(maxWidth: .infinity)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Theme.lineSoft(scheme)).frame(height: 1)
                .padding(.horizontal, env.space(Space.xxl))
        }
    }

    private var searchBox: some View {
        let q = query
        let n = hitCount
        return HStack(spacing: 7) {
            Image(systemName: Icons.search)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(q.isEmpty ? Color.secondary.opacity(0.7)
                                           : settings.accent.color(scheme, lift: 0.08))
            if PreviewFlags.offscreen {
                // 自检时用静态文本顶替输入框：SwiftUI 的 TextField 底层是 NSTextField，
                // ImageRenderer 画不出来，会留一块黄底占位 —— 整条工具栏就看不清了。
                Text(search.isEmpty ? searchPlaceholder : search)
                    .font(.system(size: 12.5))
                    .foregroundStyle(search.isEmpty ? Color.secondary.opacity(0.65)
                                                    : Theme.ink(scheme))
                    .lineLimit(1)
                    .frame(width: 176, alignment: .leading)
            } else {
                TextField(searchPlaceholder, text: $search)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12.5))
                    .focused($searchFocused)
                    .frame(width: 176)
                    .onSubmit { searchFocused = false }
            }

            if q.isEmpty {
                Text("⌘F")
                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                    .foregroundStyle(.quaternary)
                    .padding(.horizontal, 5).padding(.vertical, 1.5)
                    .background(Capsule().fill(Color.primary.opacity(0.06)))
            } else {
                if let n {
                    Text("\(n)")
                        .font(Typo.num(10.5, .bold))
                        .monospacedDigit()
                        .foregroundStyle(n == 0 ? Theme.redDefault.color(scheme, lift: 0.04)
                                               : settings.accent.color(scheme, lift: 0.04))
                        .padding(.horizontal, 6).padding(.vertical, 1.5)
                        .background(Capsule().fill(
                            (n == 0 ? Theme.redDefault.color(scheme) : settings.accent.color(scheme))
                                .opacity(0.14)))
                        .help(n == 0 ? "没有匹配结果" : "\(n) 条匹配")
                }
                Button {
                    withAnimation(Motion.ease(Motion.Dur.instant)) { search = "" }
                    searchFocused = false
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .help("清空搜索（Esc）")
            }
        }
        .padding(.horizontal, 11)
        .frame(height: 32)
        .card(env.radius(Radius.sm), look: env.look, shadow: false)
        .overlay {
            RoundedRectangle(cornerRadius: env.radius(Radius.sm) + 0.5, style: .continuous)
                .strokeBorder(settings.accent.color(scheme, lift: 0.10)
                    .opacity(searchFocused ? 0.60 : 0), lineWidth: 1.5)
                .allowsHitTesting(false)
        }
        .onExitCommand { search = ""; searchFocused = false }
        .background {
            // ⌘F 聚焦搜索框：隐藏按钮挂快捷键，比 onKeyPress 稳
            Button("") { searchFocused = true }
                .keyboardShortcut("f", modifiers: .command)
                .opacity(0)
                .frame(width: 0, height: 0)
                .accessibilityHidden(true)
        }
        .animation(Motion.hover, value: searchFocused)
    }

    private var searchPlaceholder: String {
        switch section {
        case .todo:     return "搜索作业或学科"
        case .teams:    return "搜索任务 / 邮件 / 日程"
        case .classes:  return "搜索学科 / 老师 / 教室"
        case .grades:   return "搜索课程或作业"
        case .ai:       return "搜索"
        case .settings: return "搜索"
        }
    }

    /// 当前板块下命中多少条 —— 搜索框右侧实时显示，让人一眼确认搜索真的在工作
    private var hitCount: Int? {
        let q = query
        guard !q.isEmpty else { return nil }
        switch section {
        case .todo:
            let g = store.groups(now: now, settings: settings)
            return (g.up + g.od).filter {
                Search.hit(q, [$0.title, $0.subject, $0.fullSubject, $0.type, $0.kind])
            }.count

        case .teams:
            let t = store.teamsTasks.filter {
                Search.hit(q, [$0.title, $0.course, $0.from, $0.detail,
                              $0.source.label, $0.signals.joined(separator: " ")])
            }.count
            let m = store.teamsMails.filter {
                Search.hit(q, [$0.subject, $0.from, $0.preview])
            }.count
            let e = store.teamsEvents.filter {
                Search.hit(q, [$0.title, $0.location, $0.organizer])
            }.count
            return t + m + e

        case .classes:
            let dl = Schedule.dayList(now)
            let week = (0...6).flatMap { Schedule.slots(day: $0, on: now) }
            return (dl.list + week).filter {
                Search.hit(q, [$0.subject, $0.teacher, $0.room, $0.mode, $0.pLabel])
            }.count

        case .grades:
            let rows = store.gpaRows(settings: settings).filter {
                Search.hit(q, [$0.label, $0.key, $0.grade])
            }.count
            let works = store.recentWorks(60, settings: settings).filter {
                Search.hit(q, [$0.title, $0.label, $0.grade, $0.scoreText])
            }.count
            return rows + works

        case .settings:
            return nil

        case .ai:
            return nil
        }
    }
}

/* ---------------- 窗口细节：透明标题栏 + 记忆尺寸 ---------------- */

/// 离屏自检时同样退化成 `Color.clear`：它挂在 `.background` 上不参与布局，
/// 但 ImageRenderer 依然会为它画一张占位图。
struct WindowConfigurator: View {
    var body: some View {
        if PreviewFlags.offscreen {
            Color.clear
        } else {
            WindowConfigRepresentable()
        }
    }
}

private struct WindowConfigRepresentable: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let v = NSView()
        DispatchQueue.main.async {
            guard let w = v.window else { return }
            w.titlebarAppearsTransparent = true
            w.titleVisibility = .hidden
            // 关键：**不要**让「窗口背景可拖动」。
            // 打开它时，AppKit 会把在自定义控件（如玻璃滑块）上的拖拽当成拖窗口，
            // 于是调滑块的同时整个窗口跟着跑。窗口照旧可以由顶部标题栏区域拖动，
            // 侧边栏顶部另加了一块明确的拖拽区（见 WindowDragArea）。
            w.isMovableByWindowBackground = false
            w.backgroundColor = .clear
            w.isOpaque = false
            w.tabbingMode = .disallowed
        }
        return v
    }
    func updateNSView(_ nsView: NSView, context: Context) {}
}

/// 一块「拖这里可以移动窗口」的区域。
///
/// 关掉 `isMovableByWindowBackground` 之后，窗口需要别的地方能拖：
/// 这个视图直接把鼠标事件交给 `NSWindow.performDrag`，只在自己这一块生效，
/// 不会像窗口背景拖动那样把滑块、按钮之类的拖拽也一起吃掉。
///
/// 离屏自检时退化成 `Color.clear`：ImageRenderer 画不了 AppKit 视图，
/// 会把这一整块画成「黄底红圈禁止」的占位图 —— 侧边栏顶部于是全被盖住，
/// 自检图就没法看了。功能上两种写法完全等价（自检里不需要拖窗口）。
struct WindowDragArea: View {
    var body: some View {
        if PreviewFlags.offscreen {
            Color.clear
        } else {
            DragRepresentable()
        }
    }
}

private struct DragRepresentable: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { DragView() }
    func updateNSView(_ nsView: NSView, context: Context) {}

    private final class DragView: NSView {
        override var mouseDownCanMoveWindow: Bool { true }

        override func mouseDown(with event: NSEvent) {
            window?.performDrag(with: event)
        }

        // 双击顶部按系统偏好缩放窗口，符合 macOS 习惯
        override func mouseUp(with event: NSEvent) {
            if event.clickCount == 2 {
                window?.performZoom(nil)
            } else {
                super.mouseUp(with: event)
            }
        }
    }
}
