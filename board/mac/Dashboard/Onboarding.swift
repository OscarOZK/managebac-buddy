import SwiftUI
import AppKit

/* ======================================================================
   首次使用引导

   用户明确要求「优化用户首次登录的各种指引，这个也十分重要」。
   所以这里不是一句"请输入账号"，而是分八步，每一步都：
     · 说清这一步为什么需要它
     · 给实时状态（正在做什么 / 成功 / 失败原因 / 怎么补救）
     · 允许跳过（除了英语名，因为 EC 名单没有替代方案）
     · 可以随时从设置页重跑

   顺序也是按依赖排的：先认识人（英语名）→ 再接数据源 → 最后是外观和提醒。
   ====================================================================== */

struct OnboardingView: View {
    @EnvironmentObject var settings: BoardSettings
    @Environment(\.colorScheme) private var scheme
    /// 灵析 AI 的登录态直接读引擎 —— 引导页不做第二份状态，
    /// 否则「引导里显示已登录、进看板却要重登」这种自相矛盾的事一定会出现。
    @ObservedObject private var ai = AIEngine.shared

    var onFinish: () -> Void

    /// 「通知总开关已经被用户表过态」的标记。见 .task 里那段注释。
    static let notifyAskedKey = "mb.notify.asked"

    @State private var step: OnboardingStep =
        OnboardingStep(rawValue: PreviewFlags.onboardStep ?? 0) ?? .welcome

    // 身份
    @State private var englishName = ""
    @State private var displayName = ""
    @State private var gradeLabel = "G10"

    // ManageBac
    @State private var login = ""
    @State private var password = ""
    @State private var saveCreds = false
    @State private var mbBusy = false
    @State private var mbMsg = ""
    @State private var mbOK = false

    // Teams
    @State private var teamsBusy = false
    @State private var teamsMsg = ""
    @State private var teamsOK = false
    @State private var teamsAccount = ""
    @State private var ecMsg = ""

    // 希悦
    @State private var seiueBusy = false
    @State private var seiueMsg = ""
    @State private var seiueOK = false
    /// 已经识别到的那张导出表叫什么（有值时在状态下面单列一行）
    @State private var seiueFile = ""
    /// 希悦这份登录态还在不在（页面探到，或本地留着上次探到的记录，都算）
    @State private var seiueLogged = false
    /// 自动读取试过一次没有？试过且没成才把「手动识别」那条退路摆出来
    @State private var seiueTried = false

    // 通知
    @State private var askNotify = true
    /// 示例通知的结果提示 —— 点完按钮必须给反馈，不然用户不知道到底发没发出去
    @State private var notifyMsg = ""

    // 灵析 AI
    @State private var aiMsg = ""
    @State private var aiOK = false

    /// 翻页方向：下一步 true、上一步 false。过渡按它决定从哪边滑进来。
    @State private var forward = true
    /// 左侧进度条上的高亮块滑动用
    @Namespace private var railNS

    private var env: Env { Env(scheme: scheme, settings: settings) }

    /// 灵析 AI 的真实登录页什么时候摊在窗口上
    private var aiSite: Bool { ai.showSite }

    private var steps: [OnboardingStep] { OnboardingStep.allCases }
    private var idx: Int { step.rawValue }

    var body: some View {
        ZStack {
            Theme.page(scheme).ignoresSafeArea()
            ThemeBackdrop(scheme: scheme).ignoresSafeArea()

            HStack(spacing: 0) {
                rail
                Divider().overlay(Theme.lineSoft(scheme))
                right
            }

            // 灵析 AI 的网页引擎。引导阶段主窗口里没有 DashRoot，
            // 所以这里也必须挂一份 —— 否则「连接灵析 AI」这一步点登录根本没反应。
            // （离屏自检时不挂：WKWebView 画不出来，占位图会盖住整屏。）
            if !PreviewFlags.offscreen {
                AIBackend()
                    .opacity(aiSite ? 1 : 0)
                    .allowsHitTesting(aiSite)
                    .ignoresSafeArea()
                    .zIndex(8)

                if aiSite {
                    VStack {
                        HStack {
                            Button {
                                AIEngine.shared.showSite = false
                                AIEngine.shared.checkNow()
                            } label: {
                                HStack(spacing: 6) {
                                    Image(systemName: "chevron.left").font(.system(size: 10.5, weight: .bold))
                                    Text(ai.isAuthed ? "收起页面" : "我已登录好了").font(.system(size: 12, weight: .semibold))
                                }
                                .padding(.horizontal, 13).frame(height: 30)
                                .background(.ultraThinMaterial, in: Capsule())
                                .overlay(Capsule().strokeBorder(Color.primary.opacity(0.14)))
                            }
                            .buttonStyle(.plain)
                            Spacer()
                        }
                        Spacer()
                    }
                    .padding(.leading, 268)
                    .padding(.top, 46)
                    .zIndex(9)
                }
            }
        }
        .task {
            englishName = settings.englishName
            displayName = settings.displayName
            gradeLabel = settings.gradeLabel
            // 通知总开关的初始值：**第一次**进引导默认打开（新用户最需要提醒；
            // 不写盘，只在完成那一步才落），之后一律尊重用户已经选过的状态。
            // 只看 settings.notifyEnabled 是不够的：用户上次特意关掉了通知，
            // 重跑一遍向导又会被拨回「开」，那是把他的选择改掉了。
            if UserDefaults.standard.bool(forKey: Self.notifyAskedKey) {
                askNotify = settings.notifyEnabled
            } else {
                askNotify = true
            }
            Bridge.launchIfNeeded()
            // 老用户重跑向导时，ManageBac 本来可能就是登着的 —— 先核一次，
            // 免得第一步就写"未登录"，用户以为掉登录了。
            await checkStatus()
        }
        // Teams / 希悦 是「用户去浏览器登录，这边轮询」；
        // 灵析 AI 也一样是页面登录，所以挂同一条轮询。
        //
        // ★ 用 .task 循环而不是 onReceive(Timer.publish(…)) ★
        // onReceive 的第一个参数每次 body 重算都会重新求值 → 会新建发布者，
        // 只要这个视图的重算频率高于轮询周期，轮询就会被无限推迟、永远不触发。
        // 这类「悄悄不跑了」的毛病极难查（界面不报错，就是不更新），
        // 所以统一改成只启动一次的 .task 循环。
        .task {
            guard !PreviewFlags.offscreen else { return }
            while !Task.isCancelled {
                do { try await Task.sleep(nanoseconds: 2_000_000_000) } catch { return }
                if step == .teams { await pollTeams() }
                if step == .seiue { await pollSeiue() }
                if step == .ai { aiCheck(silent: true) }
            }
        }
    }

    /* ---------------- 左侧进度 ---------------- */

    private var rail: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                ZStack {
                    RoundedRectangle(cornerRadius: env.radius(11), style: .continuous)
                        .fill(LinearGradient(colors: [settings.accent.color(scheme, lift: 0.22),
                                                      settings.accent.color(scheme, lift: -0.05)],
                                             startPoint: .topLeading, endPoint: .bottomTrailing))
                        .frame(width: 38, height: 38)
                    Text("📂").font(.system(size: 19))
                }
                .shadow(color: settings.accent.color(scheme).opacity(0.30), radius: 9, y: 3)

                Text("ManageBac 看板")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Theme.ink(scheme))
                Text("首次配置向导")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.ink3(scheme))
            }
            .padding(.bottom, env.space(26))

            VStack(alignment: .leading, spacing: 2) {
                ForEach(steps) { s in
                    railItem(s)
                }
            }

            Spacer(minLength: 12)

            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Circle().fill(Theme.greenDefault.color(scheme, lift: 0.10))
                        .frame(width: 6, height: 6)
                    Text("看板已在运行")
                        .font(.system(size: 10.5))
                        .foregroundStyle(Theme.ink3(scheme))
                }
                Text("所有数据只留在你这台电脑上")
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.ink3(scheme).opacity(0.8))
            }
            .padding(.bottom, env.space(18))
        }
        .padding(.horizontal, env.space(20))
        .padding(.top, 34)
        .frame(width: 250)
        .background {
            Rectangle().fill(.ultraThinMaterial)
        }
        .overlay(alignment: .trailing) {
            Rectangle().fill(Theme.lineSoft(scheme)).frame(width: 1)
        }
    }

    private func railItem(_ s: OnboardingStep) -> some View {
        let done = s.rawValue < idx
        let on = s == step
        return Button {
            // 只允许往回看，以及往前一步（不能跳到还没配好的步骤）
            if s.rawValue <= idx + 0 { goStep(s) }
        } label: {
            HStack(spacing: 9) {
                ZStack {
                    Circle()
                        .fill(done ? Theme.greenDefault.color(scheme, lift: 0.10).opacity(0.18)
                                   : (on ? settings.accent.color(scheme).opacity(0.18)
                                         : Color.primary.opacity(0.06)))
                        .frame(width: 22, height: 22)
                    if done {
                        Image(systemName: "checkmark").font(.system(size: 10, weight: .bold))
                            .foregroundStyle(Theme.greenDefault.color(scheme, lift: 0.02))
                    } else {
                        Image(systemName: s.icon).font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(on ? settings.accent.color(scheme, lift: 0.10)
                                                : Theme.ink3(scheme))
                    }
                }
                Text(s.title)
                    .font(.system(size: 12.5, weight: on ? .semibold : .medium))
                    .foregroundStyle(on ? Theme.ink(scheme) : Theme.ink2(scheme))
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .frame(height: 30)
            .contentShape(RoundedRectangle(cornerRadius: env.radius(8), style: .continuous))
            .background {
                if on {
                    RoundedRectangle(cornerRadius: env.radius(8), style: .continuous)
                        .fill(settings.accent.color(scheme).opacity(0.10))
                        // 高亮随进度往下滑，而不是每一步原地闪一下
                        .matchedGeometryEffect(id: "railSel", in: railNS)
                }
            }
        }
        .buttonStyle(.plain)
        .disabled(s.rawValue > idx)
        .opacity(s.rawValue > idx ? 0.55 : 1)
        .animation(Motion.hover, value: on)
    }

    /// 所有换步都走这里：记下方向，再用整页弹簧做推入推出。
    /// 方向感很重要 —— 下一步和上一步如果长得一样，用户就分不清自己在哪。
    private func goStep(_ s: OnboardingStep) {
        guard s != step else { return }
        forward = s.rawValue > step.rawValue
        withAnimation(Motion.page) { step = s }
        // 走到「全部就绪」时把四个账号真查一遍：用户可能中途在别处登过了，
        // 也可能是老用户重跑一遍向导 —— 凭 @State 的旧值下结论会写错清单。
        // 走到 ManageBac 那步同理：老用户本来就是登着的，该一开始就显示「已连接」。
        if s == .managebac { Task { await checkStatus() } }
        if s == .done { Task { await refreshDoneChecklist() } }
    }

    /// 「全部就绪」那张清单的数据来源。查不到就保持原样（宁可少说，不要瞎说）。
    private func refreshDoneChecklist() async {
        aiOK = AIEngine.shared.isAuthed
        await checkStatus()
        await pollTeams()
        await pollSeiue()
    }

    /* ---------------- 右侧内容 ---------------- */

    private var right: some View {
        VStack(alignment: .leading, spacing: 0) {
            // 离屏自检（ImageRenderer）画不出 ScrollView 的内容，会整块空白 ——
            // 加个开关在自检时直接把内容铺开，否则每次核对引导页都像"页面坏了"。
            Group {
                if PreviewFlags.noScroll {
                    page
                } else {
                    ScrollView { page }
                }
            }
            // 换步时整页按方向滑进来 + 淡入。`.id` 顺带把滚动位置拉回顶部。
            .id(step)
            .transition(.pageSlide(forward))
            .clipped()
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            footer
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var page: some View {
        VStack(alignment: .leading, spacing: env.space(22)) {
            header
            content
        }
        .padding(.horizontal, env.space(38))
        .padding(.top, 40)
        .padding(.bottom, env.space(30))
        .frame(maxWidth: 660, alignment: .leading)
        .frame(maxWidth: .infinity, alignment: .center)
    }

    /// 没连上的账号名。完成页的**标题、副标题、清单后面的提示卡**都用它 ——
    /// 三处必须说同一件事。
    ///
    /// 为什么非要抽出来：以前标题是写死的「全部就绪 / 四个账号都检查过了，
    /// 可以开始用了」，而下面那张清单里四个账号全是「未连接（可稍后补）」——
    /// 用户第一眼看到的就是两句话在互相打脸，而且偏偏是在最需要它说清楚的
    /// 那一步：新用户刚配完，最想知道的就是「到底还差什么」。
    private var missingAccounts: [String] {
        [!mbOK ? "ManageBac" : nil, !teamsOK ? "Teams" : nil,
         !seiueOK ? "希悦" : nil, !aiOK ? "灵析 AI（DeepSeek）" : nil].compactMap { $0 }
    }

    private var headerTitle: String {
        guard step == .done else { return step.title }
        return missingAccounts.isEmpty ? "全部就绪" : "基本就绪"
    }

    private var headerSubtitle: String {
        guard step == .done else { return step.subtitle }
        return missingAccounts.isEmpty
            ? "四个账号均已连接"
            : "还有 \(missingAccounts.count) 个账号未连接，不影响使用"
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 10) {
                Image(systemName: step.icon)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(settings.accent.color(scheme, lift: 0.10))
                Text(headerTitle).font(Typo.display)
                    .foregroundStyle(Theme.ink(scheme))
                    .contentTransition(.interpolate)
            }
            Text(headerSubtitle)
                .font(.system(size: 13))
                .foregroundStyle(Theme.ink2(scheme))
                .contentTransition(.interpolate)
        }
    }

    @ViewBuilder
    private var content: some View {
        switch step {
        case .welcome:   welcome
        case .identity:  identity
        case .managebac: managebac
        case .teams:     teams
        case .seiue:     seiue
        case .ai:        aiStep
        case .theme:     themePick
        case .notify:    notifyPick
        case .done:      doneStep
        }
    }

    /* ---- ① 欢迎 ---- */

    /// 欢迎页列出的四件事。抽成常量：文案里的「四件事」按它算，
    /// 以后加一个来源，标题不至于还写着「四件事」。
    private static let welcomeItems: [(String, String, String)] = [
        ("graduationcap.fill", "ManageBac", "作业、截止时间、成绩与总评"),
        (Icons.teams, "Microsoft Teams", "从任务、邮件、聊天里自动挑出学习待办"),
        ("person.2.fill", "English Corner", "今天要不要去、同班都有谁"),
        ("calendar.badge.clock", "希悦课表", "一周同步一次，课表随时看得见"),
        ("sparkles.rectangle.stack.fill", "灵析 AI", "看板里的对话助手，作业成绩课表都能问"),
    ]

    private static let cnNum = ["零", "一", "两", "三", "四", "五", "六", "七", "八", "九"]

    private var welcome: some View {
        VStack(alignment: .leading, spacing: env.space(16)) {
            Text("这个看板把你在学校的\(Self.cnNum[Self.welcomeItems.count])件事收到一个窗口里：")
                .font(.system(size: 14))
                .foregroundStyle(Theme.ink2(scheme))

            ForEach(Self.welcomeItems, id: \.1) { row in
                HStack(spacing: 12) {
                    ZStack {
                        RoundedRectangle(cornerRadius: env.radius(9), style: .continuous)
                            .fill(settings.accent.color(scheme).opacity(0.13))
                            .frame(width: 34, height: 34)
                        Image(systemName: row.0)
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(settings.accent.color(scheme, lift: 0.10))
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text(row.1).font(.system(size: 13.5, weight: .semibold))
                            .foregroundStyle(Theme.ink(scheme))
                        Text(row.2).font(.system(size: 12))
                            .foregroundStyle(Theme.ink2(scheme))
                    }
                    Spacer(minLength: 0)
                }
            }

            callout(icon: "lock.shield.fill",
                    title: "数据不出本机",
                    body: "账号密码只存在系统钥匙串里，"
                       + "看板不会上传任何内容。")
        }
    }

    /* ---- ② 英语名 ---- */

    private var identity: some View {
        VStack(alignment: .leading, spacing: env.space(16)) {
            callout(icon: "exclamationmark.circle.fill",
                    title: "这一项必须填，也只需填一次",
                    body: "老师发的 EC 名单里写的是英语名，所以这里要按英语名匹配。"
                       + "用中文名是找不到你的。"
                       + "用中文名是匹配不上的。")

            fieldBlock(title: "英语名（必填）",
                       hint: "跟老师念的一致，例如 Alex Chen",
                       text: $englishName,
                       placeholder: "Alex Chen")

            HStack(alignment: .top, spacing: env.space(14)) {
                // 用户要求：这两处不要给示例值，空着就好 ——
                // 预填任何具体名字都会让人以为已经填好了，直接跳过。
                fieldBlock(title: "中文名 / 昵称（选填）",
                           hint: "用来在界面上称呼你",
                           text: $displayName,
                           placeholder: "")
                fieldBlock(title: "年级（选填）",
                           hint: "影响课表与班级的显示",
                           text: $gradeLabel,
                           placeholder: "G10")
            }

            if !englishName.trimmed.isEmpty {
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.greenDefault.color(scheme, lift: 0.06))
                    Text("将按「\(englishName.trimmed)」去 EC 名单里找人")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.ink2(scheme))
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, env.space(13))
                .frame(height: 36)
                .card(env.radius(Radius.sm), look: env.look, shadow: false)
            }
        }
    }

    /* ---- ③ ManageBac ---- */

    private var managebac: some View {
        VStack(alignment: .leading, spacing: env.space(16)) {
            Text("用你在学校的 ManageBac 账号登录。密码只留在你这台电脑上，"
                 + "不会发到任何别的地方。")
                .font(.system(size: 13))
                .foregroundStyle(Theme.ink2(scheme))

            // 同样不放示例值：预填任何具体账号都会让人以为已经填过了
            fieldBlock(title: "账号", hint: "通常是学号或邮箱前缀", text: $login,
                       placeholder: "例如 2024xxxxxx 或 name.surname")
            secureBlock(title: "密码", hint: "", text: $password, placeholder: "••••••••")

            HStack(spacing: 10) {
                Toggle(isOn: $saveCreds) {
                    Text("记住账号密码（密码存入 macOS 钥匙串）")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.ink2(scheme))
                }
                .toggleStyle(.checkbox)
                Spacer(minLength: 0)
            }

            statusBanner(mbBusy ? "正在登录…" : mbMsg, ok: mbOK, busy: mbBusy)

            HStack(spacing: 10) {
                Button {
                    Task { await doLogin() }
                } label: {
                    let ready = !mbBusy && !login.trimmed.isEmpty && !password.isEmpty
                    label("登录 ManageBac", icon: "arrow.right.circle.fill",
                          primary: true, enabled: ready)
                }
                .buttonStyle(.plain)
                .disabled(mbBusy || login.trimmed.isEmpty || password.isEmpty)

                Button {
                    Task { await checkStatus() }
                } label: {
                    label("检查当前状态", icon: "arrow.clockwise", primary: false)
                }
                .buttonStyle(.plain)
                .disabled(mbBusy)
            }
        }
    }

    /* ---- ④ Teams ---- */

    private var teams: some View {
        VStack(alignment: .leading, spacing: env.space(16)) {
            Text("点下面的按钮会弹出一个浏览器窗口（在屏幕正中），"
                 + "用学校账号登录一次就行 —— 登录后看板就能读到你的任务、邮件和日程。")
                .font(.system(size: 13))
                .foregroundStyle(Theme.ink2(scheme))

            // Teams 的账号体系本来就是 Microsoft 账号。不先说明的话，用户会
            // 以为「我让你登 Teams，你怎么让我登 Microsoft」——弹出来的页面
            // 标题写着 Microsoft 是正常的，登的仍是同一个学校账号。
            callout(icon: "info.circle",
                    title: "弹出的页面为什么写着 Microsoft",
                    body: "Teams 用的就是学校的 Microsoft 账号 —— 页面标题写着 "
                       + "Microsoft，登进去的仍是同一个学校账号，登完会自动回到 Teams。")

            statusBanner(teamsBusy ? "等你在浏览器里登录…" : teamsMsg,
                         ok: teamsOK, busy: teamsBusy)

            if !teamsAccount.isEmpty {
                keyValueRow("已连接账号", teamsAccount, icon: "person.crop.circle.fill")
            }
            if !ecMsg.isEmpty {
                keyValueRow("English Corner", ecMsg, icon: "person.2.fill")
            }

            HStack(spacing: 10) {
                Button {
                    Task { await startTeams() }
                } label: {
                    label(teamsOK ? "重新连接" : "打开浏览器登录", icon: "safari.fill", primary: true)
                }
                .buttonStyle(.plain)
                .disabled(teamsBusy)

                if !teamsOK {
                    Button {
                        Task { await pollTeams() }
                    } label: {
                        label("我已经登录好了", icon: "checkmark.circle", primary: false)
                    }
                    .buttonStyle(.plain)
                    .disabled(teamsBusy)
                }
            }

            callout(icon: "macwindow",
                    title: "没看到窗口？",
                    body: "它可能被别的窗口压在下面了 —— 用 ⌘Tab 或点一下 Dock 里的 "
                       + "「Google Chrome for Testing」。再点一次「打开浏览器登录」，"
                       + "窗口会被重新摆到屏幕中央。")
        }
    }

    /* ---- ⑤ 希悦 ---- */

    private var seiue: some View {
        VStack(alignment: .leading, spacing: env.space(16)) {
            Text("点「读取课表」就行 —— 看板会自己去网页上把整周课表取回来，"
                 + "你不用碰任何文件。")
                .font(.system(size: 13))
                .foregroundStyle(Theme.ink2(scheme))

            statusBanner(seiueBusy ? "正在读取课表…" : seiueMsg, ok: seiueOK, busy: seiueBusy)

            if !seiueFile.isEmpty {
                keyValueRow("课表文件", seiueFile, icon: "tablecells")
            }

            HStack(spacing: 10) {
                Button {
                    Task { await openSeiue() }
                } label: {
                    label(seiueLogged ? "打开课表页" : "登录希悦",
                          icon: "arrow.up.forward.app", primary: !seiueOK)
                }
                .buttonStyle(.plain)

                Button {
                    Task { await startSeiue() }
                } label: {
                    label(seiueOK ? "重新读取" : "读取课表", icon: "calendar.badge.clock",
                          primary: true)
                }
                .buttonStyle(.plain)
                .disabled(seiueBusy)

                // 只有自动那条路走过一次、并且没成，才把「手动识别」这条退路摆出来。
                // 平时不摆 —— 一屏三个按钮会让人不知道该点哪个。
                if seiueTried && !seiueOK {
                    Button {
                        Task { await importSeiue() }
                    } label: {
                        label("识别导出的课表", icon: "tablecells.badge.ellipsis", primary: false)
                    }
                    .buttonStyle(.plain)
                    .disabled(seiueBusy)
                }
            }
        }
    }

    /* ---- ⑥ 灵析 AI ---- */

    private var aiStep: some View {
        VStack(alignment: .leading, spacing: env.space(16)) {
            Text("灵析 AI 是看板里的对话助手：作业、成绩、课表都能直接问它。"
                 + "不用另外申请账号，也不用付费。")
                .font(.system(size: 13))
                .foregroundStyle(Theme.ink2(scheme))

            // 「登录页上到底该做什么」必须写清楚 —— 让用户对着一个网页发呆是上一版最大的问题
            VStack(alignment: .leading, spacing: 8) {
                Text("点下面的按钮后会弹出登录页，在上面：")
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(Theme.ink(scheme))
                ForEach(["用手机号 / 邮箱 / 微信任意一种登录即可",
                         "登录成功后页面会自动收起，不用手动关",
                         "这台电脑会记住登录，以后打开就能直接用"], id: \.self) { t in
                    HStack(spacing: 7) {
                        Image(systemName: "checkmark").font(.system(size: 9, weight: .bold))
                            .foregroundStyle(Theme.greenDefault.color(scheme, lift: 0.04))
                        Text(t).font(.system(size: 12)).foregroundStyle(Theme.ink2(scheme))
                        Spacer(minLength: 0)
                    }
                }
            }
            .padding(env.space(13))
            .card(env.radius(Radius.md), look: env.look, shadow: false)

            statusBanner(aiOK ? "已连接 DeepSeek —— 这一步完成了"
                              : (aiMsg.isEmpty ? ai.status : aiMsg),
                         ok: aiOK,
                         busy: aiSite && !ai.isAuthed)

            HStack(spacing: 10) {
                Button {
                    AIEngine.shared.showSite = true
                    aiMsg = "登录页已打开，在上面完成登录"
                } label: {
                    label(aiOK ? "重新打开登录页" : "打开登录页", icon: "safari.fill", primary: true)
                }
                .buttonStyle(.plain)

                Button {
                    aiCheck(silent: false)
                } label: {
                    label("我已经登录好了", icon: "checkmark.circle", primary: false)
                }
                .buttonStyle(.plain)

                Button {
                    AIEngine.shared.reconnect()
                    aiMsg = "正在重新加载登录页…"
                } label: {
                    label("重连", icon: "arrow.clockwise", primary: false)
                }
                .buttonStyle(.plain)
            }

            callout(icon: "wrench.and.screwdriver.fill",
                    title: "登录没成功？按这个顺序试",
                    body: "① 点「我已经登录好了」——页面登录完成后需要你确认一下；"
                       + "② 没反应就点「重连」，把登录页整个重新加载一遍"
                 + "（登录状态记在这台电脑上，重载不会掉登录）；"
                 + "③ 再不行就点「打开登录页」重登一次，或者把 App 退掉重开。"
                 + "只要登录页上能正常输入，就没有别的问题。")
        }
    }

    /// silent = 轮询用（只同步引擎状态，不主动点页面）；
    /// 非 silent = 用户点了「我已经登录好了」，主动去页面里验一次 token。
    private func aiCheck(silent: Bool) {
        if silent {
            aiOK = AIEngine.shared.isAuthed
            if aiOK && aiMsg.isEmpty { aiMsg = "已连接 DeepSeek" }
            return
        }
        AIEngine.shared.checkNow()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.1) {
            let on = AIEngine.shared.isAuthed
            aiOK = on
            aiMsg = on ? "已连接 DeepSeek" : "还没检测到登录 —— 确认登录页上已经登录成功，再点一次这个按钮"
        }
    }

    /* ---- ⑦ 主题 ---- */

    private var themePick: some View {
        VStack(alignment: .leading, spacing: env.space(14)) {
            Text("配色会同时作用在大看板和菜单栏小面板上。限时主题的颜色全部取自校园实拍。")
                .font(.system(size: 13))
                .foregroundStyle(Theme.ink2(scheme))

            VStack(spacing: env.space(12)) {
                ForEach(Palettes.all) { p in
                    // 选中态比的是实际生效的 id（见 SettingsSection 里的同款说明）
                    ThemeCard(palette: p, selected: settings.palette.id == p.id) {
                        withAnimation(Motion.spring(0.30)) { settings.paletteID = p.id }
                    }
                }
            }
        }
    }

    /* ---- ⑦ 通知 ---- */

    /// 提醒项目。用户要求「这些通知选项在新手引导页就允许开关调整」，
    /// 所以这里不再是只读的一串对勾，而是**真的开关** —— 拨一下就等于
    /// 改了设置页里对应那一项（两处绑的是同一个 @Published）。
    private struct NotifyRow: Identifiable {
        let id: String
        let icon: String
        let title: String
        let detail: String
        let on: Binding<Bool>
    }

    private var notifyRows: [NotifyRow] {
        [
            NotifyRow(id: "task", icon: "clock.badge.exclamationmark",
                      title: "待办即将到期",
                      detail: settings.notifyTaskRedOnly ? "只提醒「紧急」档" : "红黄蓝三档都提醒",
                      on: $settings.notifyTask),
            NotifyRow(id: "teams", icon: Icons.teams,
                      title: "Teams 里新出现的任务",
                      detail: "从任务、邮件、聊天里挑出来的那些",
                      on: $settings.notifyTeams),
            NotifyRow(id: "event", icon: "calendar.badge.clock",
                      title: "十五分钟内要开始的日程",
                      detail: "下一节课、会议、日程",
                      on: $settings.notifyEvents),
            NotifyRow(id: "ec", icon: "person.2.fill",
                      title: "English Corner",
                      detail: "名单里有你、当天要去时",
                      on: $settings.notifyEC),
            NotifyRow(id: "grade", icon: "chart.bar.fill",
                      title: "新成绩",
                      detail: "老师评完分就提醒",
                      on: $settings.notifyGrades),
            NotifyRow(id: "digest", icon: "sun.horizon.fill",
                      title: "每天早上一条今日汇总",
                      detail: "几点推在设置里改",
                      on: $settings.notifyDigest),
            NotifyRow(id: "mail", icon: "envelope.fill",
                      title: "邮件（默认关）",
                      detail: "邮件量大，容易吵",
                      on: $settings.notifyMail),
        ]
    }

    /// 引导页里的总开关：拨一下立刻生效，不等「完成」那一步。
    private var notifySwitch: Binding<Bool> {
        Binding(get: { askNotify },
                set: { v in
                    withAnimation(Motion.hover) { askNotify = v }
                    settings.notifyEnabled = v
                })
    }

    private var notifyPick: some View {
        VStack(alignment: .leading, spacing: env.space(16)) {
            Text("通知只在本机弹，内容不会上传。下面每一项都能单独关，"
                 + "以后在「设置 › 通知」里也能改。")
                .font(.system(size: 13))
                .foregroundStyle(Theme.ink2(scheme))

            // 不要把文字塞进 Toggle 的 label：macOS 上 Toggle 按「文字 + 开关」
            // 的顺序排，开关会紧跟在最长的文字后面（这次是副标题末尾），
            // 于是停在卡片中间，右边空出一大片。开关单独放、靠 Spacer 顶到右边。
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("开启通知").font(.system(size: 13.5, weight: .semibold))
                        .foregroundStyle(Theme.ink(scheme))
                    Text("首次开启时系统会问一次权限，允许即可")
                        .font(.system(size: 11.5)).foregroundStyle(Theme.ink2(scheme))
                }
                // ⚠️ 这两行必须能换行、不能被压扁：
                //   HStack 里右边那个 Toggle 宽度是固定的，窗口一窄，SwiftUI 默认
                //   会把左边的文字挤到「截断成一行」——用户看到的就是
                //   「首次开启时系统会问一次权…」，一句没说完的话。
                //   fixedSize(horizontal: false, vertical: true) 让它宁可折行；
                //   layoutPriority(1) 保证分配空间时它排在 Spacer 前面。
                .fixedSize(horizontal: false, vertical: true)
                .layoutPriority(1)
                Spacer(minLength: 8)
                Toggle("", isOn: notifySwitch)
                    .toggleStyle(.switch)
                    .labelsHidden()
                    .accessibilityLabel("开启通知")
            }
            .padding(.horizontal, env.space(14))
            .padding(.vertical, env.space(12))
            .card(env.radius(Radius.md), look: env.look)

            if askNotify {
                VStack(alignment: .leading, spacing: 0) {
                    Text("提醒哪些")
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(Theme.ink(scheme))
                        .padding(.bottom, env.space(4))
                    ForEach(Array(notifyRows.enumerated()), id: \.element.id) { i, r in
                        if i > 0 {
                            Rectangle().fill(Theme.lineSoft(scheme)).frame(height: 1)
                                .padding(.leading, 30)
                        }
                        HStack(spacing: 10) {
                            Image(systemName: r.icon)
                                .font(.system(size: 12))
                                .foregroundStyle(settings.accent.color(scheme, lift: 0.10))
                                .frame(width: 20)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(r.title).font(.system(size: 12.5, weight: .medium))
                                    .foregroundStyle(Theme.ink(scheme))
                                if !r.detail.isEmpty {
                                    Text(r.detail).font(.system(size: 11))
                                        .foregroundStyle(Theme.ink3(scheme))
                                }
                            }
                            Spacer(minLength: 8)
                            Toggle("", isOn: r.on)
                                .toggleStyle(.switch)
                                .labelsHidden()
                                .controlSize(.small)
                                .accessibilityLabel(r.title)
                        }
                        .padding(.horizontal, env.space(14))
                        .frame(height: 44)
                    }
                }
                .card(env.radius(Radius.md), look: env.look, shadow: false)

                HStack(spacing: 10) {
                    Button {
                        Notifier.sample(subject: "chem", settings: settings) { ok in
                            notifyMsg = ok
                                ? "已发出。没看到横幅就先看下面那两种可能。"
                                : "没能发出 —— 系统还没允许本应用发通知，看下面第 1 条。"
                        }
                    } label: {
                        label("发一条示例看看样式", icon: "bell.badge.fill", primary: false)
                    }
                    .buttonStyle(.plain)

                    if !notifyMsg.isEmpty {
                        Text(notifyMsg)
                            .font(.system(size: 11.5))
                            .foregroundStyle(Theme.ink2(scheme))
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 0)
                    }
                }

                // 「收不到通知」只可能是这两种情况 + 一键跳系统设置。
                // 和「设置 › 通知」页底部是同一个组件，两处说法完全一致。
                NotifyTroubleCard()
            }
        }
    }

    /* ---- ⑧ 完成 ---- */

    private var doneStep: some View {
        VStack(alignment: .leading, spacing: env.space(16)) {
            Text(missingAccounts.isEmpty
                 ? "四个账号均已连接，以下内容可随时在设置中修改。"
                 : "看板已可使用。未连接的板块在用到时会给出提示，可稍后在设置中补齐。")
                .font(.system(size: 13))
                .foregroundStyle(Theme.ink2(scheme))

            VStack(spacing: 1) {
                checkRow("英语名", englishName.trimmed.isEmpty ? "未填写" : englishName.trimmed,
                         ok: !englishName.trimmed.isEmpty)
                checkRow("ManageBac", mbOK ? "已连接" : "未连接（可稍后补）", ok: mbOK)
                checkRow("Microsoft Teams", teamsOK ? (teamsAccount.isEmpty ? "已连接" : teamsAccount) : "未连接（可稍后补）", ok: teamsOK)
                checkRow("希悦课表", seiueOK ? "已同步" : "未同步（可稍后补）", ok: seiueOK)
                checkRow("灵析 AI", aiOK ? "已连接 DeepSeek" : "未连接（可稍后补）", ok: aiOK)
                checkRow("主题", "\(settings.palette.name) · \(settings.palette.en)", ok: true)
                checkRow("通知", askNotify ? "已开启" : "未开启", ok: askNotify)
            }
            .card(env.radius(Radius.md), look: env.look)

            let missing = missingAccounts
            if !missing.isEmpty {
                callout(icon: "key.fill",
                        title: "还有 \(missing.count) 个账号未连接：\(missing.joined(separator: "、"))",
                        body: "不影响使用 —— 用到对应功能时会给出提示。"
                           + "需要现在补齐，请到「设置 → 主题」下方的「账号管理」，"
                           + "四个账号均可单独登录、退出、重新检查。")
            }

            callout(icon: "key.horizontal.fill",
                    title: "四个账号统一管理",
                    body: "设置页「主题」下方为「账号管理」：ManageBac、Teams、希悦、灵析 AI "
                       + "各自显示连接状态、账号与校验时间，掉线可当场重连。")

            callout(icon: "laptopcomputer.and.iphone",
                    title: "两个入口",
                    body: "菜单栏图标点一下是「小面板」（快速扫一眼、快速设置）；"
                       + "面板底部「展开完整看板」才是大看板。")
        }
    }

    /* ---------------- 底部按钮 ---------------- */

    private var footer: some View {
        HStack(spacing: env.space(10)) {
            if step != .welcome {
                Button {
                    goStep(OnboardingStep(rawValue: max(0, idx - 1)) ?? .welcome)
                } label: {
                    label("上一步", icon: "chevron.left", primary: false)
                }
                .buttonStyle(.plain)
                .transition(.pop)
            }

            Spacer(minLength: 0)

            if step == .identity {
                Text("这一项必填")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.ink3(scheme))
            } else if step.isAccountStep {
                Text("这一步可以跳过，随时能在「设置 → 账号管理」里补")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.ink3(scheme))
            }

            if step != .welcome && step != .done {
                Button { advance(skipping: true) } label: {
                    label("跳过这一步", icon: "arrow.turn.down.right", primary: false)
                }
                .buttonStyle(.plain)
            }

            Button {
                advance(skipping: false)
            } label: {
                label(step == .done ? "开始使用" : "下一步",
                      icon: step == .done ? "checkmark.seal.fill" : "arrow.right",
                      primary: true, enabled: canAdvance)
            }
            .buttonStyle(.plain)
            .disabled(!canAdvance)
        }
        .padding(.horizontal, env.space(38))
        .padding(.vertical, env.space(16))
        .background {
            Rectangle().fill(.ultraThinMaterial)
        }
        .overlay(alignment: .top) {
            Rectangle().fill(Theme.lineSoft(scheme)).frame(height: 1)
        }
    }

    private var canAdvance: Bool {
        if step == .identity { return !englishName.trimmed.isEmpty }
        return true
    }

    private func advance(skipping: Bool) {
        // 每一步离开时把已经填好的东西落盘，中途退出也不丢
        commit()
        if step == .done {
            settings.onboarded = true
            settings.notifyEnabled = askNotify
            UserDefaults.standard.set(true, forKey: Self.notifyAskedKey)
            onFinish()
            return
        }
        goStep(OnboardingStep(rawValue: min(OnboardingStep.allCases.count - 1, idx + 1)) ?? .done)
        if step == .teams { Task { await pollTeams() } }
        if step == .ai { aiCheck(silent: true) }
    }

    private func commit() {
        let n = englishName.trimmed
        if !n.isEmpty, n != settings.englishName {
            settings.englishName = n          // didSet 里会同步给后端
        }
        settings.displayName = displayName
        settings.gradeLabel = gradeLabel
    }

    /* ---------------- 动作 ---------------- */

    private func doLogin() async {
        mbBusy = true; mbOK = false; mbMsg = "正在连接本机服务…"
        Bridge.launchIfNeeded()
        for _ in 0..<20 {
            if await DataStore.shared.healthy() { break }
            try? await Task.sleep(nanoseconds: 400_000_000)
        }
        mbMsg = "正在登录…"
        let r = await Bridge.post("/api/login", [
            "login": login.trimmed, "password": password,
            "remember": true, "save": saveCreds,
        ], timeout: 90)
        mbBusy = false
        mbOK = Bridge.ok(r)
        mbMsg = mbOK
            ? "登录成功" + (saveCreds ? "，账号密码已记住" : "")
            : Bridge.msg(r, "登录失败，检查账号密码后重试")
        if mbOK {
            password = ""
            await DataStore.shared.load(force: true)
            if step == .managebac { advance(skipping: false) }
        }
    }

    private func checkStatus() async {
        Bridge.launchIfNeeded()
        // 引导页是用户**主动**点「检查」——现场探一次。
        // 服务端会先把 15 秒内的快照塞给我们，冷启动没探完就带 probing，
        // 由 manageBacStatus 自动再问两轮，而不是在这里吃 20 秒超时、
        // 误报「本机服务还没起来」（服务其实好得很）。
        guard let d = await Bridge.manageBacStatus(probe: true) else {
            mbMsg = "本机服务还没起来，稍等几秒再点一次"
            return
        }
        let logged = (d["loggedIn"] as? Bool) ?? false
        mbOK = logged
        if logged {
            mbMsg = "已登录：\((d["user"] as? String) ?? "（已登录）")"
        } else {
            // 服务端写的说明比一句「当前未登录」有用得多
            //（比如「正在后台下载 Chrome，几分钟后点重新校验」）。
            mbMsg = Bridge.text(d, "当前未登录")
        }
    }

    private func startTeams() async {
        teamsBusy = true; teamsMsg = "正在打开浏览器…"
        Bridge.launchIfNeeded()
        let r = await Bridge.post("/api/teams/login", [:], timeout: 40)
        teamsMsg = Bridge.ok(r) ? "浏览器已打开，请在窗口里完成登录" : Bridge.msg(r, "打开失败，稍后重试")
    }

    private func pollTeams() async {
        guard let d = await Bridge.get("/api/teams", timeout: 45) else { return }
        let logged = (d["loggedIn"] as? Bool) ?? false
        teamsOK = logged
        teamsBusy = false
        teamsAccount = (d["account"] as? String) ?? ""
        if logged {
            teamsMsg = "已连接"
            if let sec = d["section"] as? [String: Any],
               let ec = sec["ec"] as? [String: Any] {
                let st = (ec["status"] as? String) ?? "none"
                let imIn = (ec["imIn"] as? Bool) ?? false
                let klass = (ec["klass"] as? String) ?? ""
                let who = settings.englishName
                switch st {
                case "today":    ecMsg = imIn ? "今天要去（\(klass) 班）" : "今天有 EC，但名单里没有「\(who)」"
                case "done":     ecMsg = "今天 EC 已结束"
                case "tomorrow": ecMsg = imIn ? "明天要去（\(klass) 班）" : "明天有 EC，名单里没有「\(who)」"
                case "past":     ecMsg = "名单已过期"
                default:         ecMsg = "最近没有 EC"
                }
            }
        } else if !teamsBusy {
            teamsMsg = "还没检测到登录，完成浏览器里的步骤后会自动识别"
        }
    }

    private func startSeiue() async {
        seiueBusy = true; seiueMsg = "正在读取课表…"; seiueTried = true
        Bridge.launchIfNeeded()
        // 后端会先替用户在网页上点一遍「导出」（拿整张表，一节不漏），
        // 不成再退回从页面上抠格子。所以这里只等结果，不预设「需要登录」。
        let r = await Bridge.post("/api/seiue/sync", [:], timeout: 130)
        seiueBusy = false
        seiueOK = Bridge.ok(r)
        if seiueOK {
            let n = (r?["lessons"] as? [[String: Any]])?.count ?? 0
            let fromExcel = (r?["source"] as? String) == "excel"
            seiueFile = ((r?["file"] as? String) ?? "").split(separator: "/").last.map(String.init) ?? ""
            seiueMsg = fromExcel
                ? "已按整张课表读取，共 \(n) 节"
                : "已读取 \(n) 节"
            settings.seiueEnabled = true
            await DataStore.shared.load(force: true)
        } else {
            seiueMsg = Bridge.msg(r, "")
            if seiueMsg.isEmpty || (r?["needsLogin"] as? Bool) == true {
                seiueMsg = "希悦还没登录 —— 点「登录希悦」，在打开的窗口里登一次，再点「读取课表」"
            }
        }
        await pollSeiue()
    }

    /// 「登录希悦」：把希悦窗口摆到屏幕正中（窗口本来可能停在屏幕外），
    /// 并顺手把它的下载目录指到看板认得的地方。
    private func openSeiue() async {
        Bridge.launchIfNeeded()
        seiueMsg = "正在打开课表页…"
        let r = await Bridge.post("/api/seiue/login", [:], timeout: 40)
        if Bridge.ok(r) {
            seiueMsg = "课表页已打开。没登录就在窗口里登一次，然后点「读取课表」"
        } else {
            seiueMsg = Bridge.msg(r, "没能打开课表页，稍后重试")
        }
        await pollSeiue()
    }

    /// 「识别导出的课表」：去下载目录里找刚导出的那张表，直接变成课表。
    /// 这是用户点名要的那条路 —— 不要让人手动拖文件进来。
    private func importSeiue() async {
        seiueBusy = true; seiueMsg = "正在找网页导出的课表…"
        Bridge.launchIfNeeded()
        let r = await Bridge.post("/api/seiue/import", [:], timeout: 60)
        seiueBusy = false
        seiueOK = Bridge.ok(r)
        if seiueOK {
            let n = (r?["lessons"] as? [[String: Any]])?.count ?? 0
            seiueFile = (r?["title"] as? String) ?? ""
            seiueMsg = "已识别这张课表：\(n) 节课"
            settings.seiueEnabled = true
            await DataStore.shared.load(force: true)
        } else {
            seiueMsg = Bridge.msg(r, "没找到导出的课表 —— 在课表页右上角点一次「导出课表」")
        }
    }

    private func pollSeiue() async {
        // 缓存命中是毫秒级；冷启动要开浏览器 + 回首页 + 读整张课表，放宽到 60 秒。
        guard let d = await Bridge.get("/api/seiue", timeout: 60) else { return }
        let st = (d["status"] as? [String: Any]) ?? [:]
        let live = (st["loggedIn"] as? Bool) ?? false
        let hasSession = (st["hasSession"] as? Bool) ?? false
        // ★ 「浏览器没开着」不等于「没登录」：登录态留在电脑上，探不到页面
        //   也该算已连接。上一版只认 live，于是用户明明刚登过、课表都看见了，
        //   引导页还写着「未登录」。
        seiueLogged = live || hasSession
        // 课表在 `schedule.lessons`（一个数组），不是顶层 `courses`。
        let sch = (d["schedule"] as? [String: Any]) ?? [:]
        let lessons = (sch["lessons"] as? [[String: Any]])?.count ?? 0
        let fromExcel = (sch["source"] as? String) == "excel"
        let excelFile = (st["excelFile"] as? String) ?? ""
        if lessons > 0 {
            seiueOK = true
            seiueBusy = false
            if fromExcel {
                seiueFile = excelFile
                seiueMsg = excelFile.isEmpty
                    ? "已按整张课表读取，共 \(lessons) 节"
                    : "已按「\(excelFile)」读取，共 \(lessons) 节"
            } else {
                seiueMsg = "已读取 \(lessons) 节"
            }
        } else if seiueLogged {
            // 登录成功、只是还没拿到课表：这一步**不算失败**。
            seiueOK = !seiueTried
            seiueBusy = false
            if seiueMsg.isEmpty || !seiueTried {
                seiueMsg = "希悦已登录 —— 点「读取课表」"
            }
        } else if (st["browserUp"] as? Bool) == true {
            seiueMsg = "课表页开着 —— 登进去之后点「读取课表」"
        }
    }

    /* ---------------- 小组件 ---------------- */

    private func fieldBlock(title: String, hint: String, text: Binding<String>, placeholder: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(Theme.ink(scheme))
            SoftField(placeholder: placeholder, text: text, scheme: scheme,
                      font: .system(size: 13.5))
                .padding(.horizontal, 11)
                .frame(height: 36)
                .fieldWell(env)
            if !hint.isEmpty {
                Text(hint).font(.system(size: 11))
                    .foregroundStyle(Theme.ink3(scheme))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func secureBlock(title: String, hint: String, text: Binding<String>, placeholder: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(Theme.ink(scheme))
            SoftField(placeholder: placeholder, text: text, scheme: scheme,
                      font: .system(size: 13.5), secure: true)
                .padding(.horizontal, 11)
                .frame(height: 36)
                .fieldWell(env)
        }
    }

    /// 引导页统一按钮样式。
    /// `enabled: false` 时**不要**用「白字 + 强调色底再整体压到 45% 透明」——
    /// 那是两端同时朝背景靠（底变浅、字也变浅），字直接看不见了。
    /// 改成中性底 + 次级字色：一眼看出「还不能点」，但文字仍然读得清。
    private func label(_ t: String, icon: String, primary: Bool, enabled: Bool = true) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon).font(.system(size: 11.5, weight: .semibold))
            Text(t).font(.system(size: 13, weight: .semibold))
        }
        .foregroundStyle(!enabled ? Theme.ink3(scheme)
                                  : (primary ? Color.white : Theme.ink(scheme)))
        .padding(.horizontal, 15)
        .frame(height: 34)
        .background {
            RoundedRectangle(cornerRadius: env.radius(Radius.sm), style: .continuous)
                .fill(!enabled ? Color.primary.opacity(0.10)
                               : (primary ? settings.accent.color(scheme, lift: 0.02)
                                          : Color.primary.opacity(0.07)))
        }
        .contentShape(RoundedRectangle(cornerRadius: env.radius(Radius.sm), style: .continuous))
    }

    private func callout(icon: String, title: String, body: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(settings.accent.color(scheme, lift: 0.10))
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(Theme.ink(scheme))
                Text(body).font(.system(size: 12))
                    .foregroundStyle(Theme.ink2(scheme))
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(env.space(13))
        .background {
            RoundedRectangle(cornerRadius: env.radius(Radius.md), style: .continuous)
                .fill(settings.accent.color(scheme).opacity(0.07))
        }
    }

    @ViewBuilder
    private func statusBanner(_ text: String, ok: Bool, busy: Bool) -> some View {
        if !text.isEmpty {
            HStack(spacing: 8) {
                if busy {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: ok ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(ok ? Theme.greenDefault.color(scheme, lift: 0.04)
                                            : Theme.amberDefault.color(scheme, lift: 0.06))
                }
                Text(text).font(.system(size: 12))
                    .foregroundStyle(Theme.ink2(scheme))
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, env.space(13))
            .padding(.vertical, env.space(9))
            .card(env.radius(Radius.sm), look: env.look, shadow: false)
        }
    }

    private func keyValueRow(_ k: String, _ v: String, icon: String) -> some View {
        HStack(spacing: 9) {
            Image(systemName: icon).font(.system(size: 12))
                .foregroundStyle(settings.accent.color(scheme, lift: 0.10))
            Text(k).font(.system(size: 12)).foregroundStyle(Theme.ink2(scheme))
            Spacer(minLength: 8)
            Text(v).font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Theme.ink(scheme))
        }
        .padding(.horizontal, env.space(13))
        .frame(height: 38)
        .card(env.radius(Radius.sm), look: env.look, shadow: false)
    }

    private func checkRow(_ k: String, _ v: String, ok: Bool) -> some View {
        HStack(spacing: 10) {
            Image(systemName: ok ? "checkmark.circle.fill" : "circle.dashed")
                .font(.system(size: 12.5))
                .foregroundStyle(ok ? Theme.greenDefault.color(scheme, lift: 0.04)
                                    : Theme.ink3(scheme))
            Text(k).font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(Theme.ink(scheme))
                .frame(width: 130, alignment: .leading)
            Text(v).font(.system(size: 12)).foregroundStyle(Theme.ink2(scheme))
            Spacer(minLength: 0)
        }
        .padding(.horizontal, env.space(14))
        .frame(height: 40)
    }
}

/* ---------------- 主题卡（设置页与引导页共用） ---------------- */

struct ThemeCard: View {
    let palette: Palette
    var selected: Bool
    var compact: Bool = false
    var action: () -> Void

    @EnvironmentObject private var settings: BoardSettings
    @Environment(\.colorScheme) private var scheme

    private var env: Env { Env(scheme: scheme, settings: settings) }

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: compact ? 8 : env.space(12)) {
                HStack(spacing: 10) {
                    Text(palette.name)
                        .font(.system(size: compact ? 13.5 : 16, weight: .semibold))
                        .foregroundStyle(Theme.ink(scheme))
                    Text(palette.en)
                        .font(.system(size: compact ? 10.5 : 11.5, weight: .medium, design: .rounded))
                        .foregroundStyle(Theme.ink3(scheme))
                    Spacer(minLength: 6)
                    if palette.isLimited {
                        Text("限时")
                            .font(.system(size: 9.5, weight: .bold))
                            .foregroundStyle(Theme.accentText(scheme))
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(Capsule().fill(RGB(palette.accent).color(scheme).opacity(0.15)))
                    }
                    Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(selected ? Theme.accentText(scheme) : Theme.ink3(scheme))
                }

                if !compact {
                    Text(palette.tagline)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Theme.ink2(scheme))
                }

                // 照片：限时主题展示三张实拍，配色就是从这些照片里取的
                if palette.isLimited {
                    HStack(spacing: 6) {
                        ForEach(palette.photos, id: \.self) { f in
                            if let img = ThemeAssets.thumb(palette, f, size: compact ? 56 : 108) {
                                Image(nsImage: img)
                                    .resizable()
                                    .aspectRatio(contentMode: .fill)
                                    .frame(width: compact ? 56 : 108, height: compact ? 44 : 72)
                                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                                    .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
                                        .strokeBorder(Theme.line(scheme), lineWidth: 0.8))
                            }
                        }
                        Spacer(minLength: 0)
                    }
                }

                // 色板：一眼看到这套主题到底长什么样。
                // 和设置页一样铺满整行 —— 固定 24×18 的小方块只占左边一小截，
                // 右边空着，看着像没排满，而且同一个主题在引导页和设置页长得不一样。
                // 每套主题里都有一两个接近纯白的槽（卡片底/描边用的中性色），
                // 不加描边的话在浅色底上会「消失」，看着像少了几个色块。
                HStack(spacing: 3) {
                    ForEach(Array(palette.bandHexes.enumerated()), id: \.offset) { _, hx in
                        RoundedRectangle(cornerRadius: 3, style: .continuous)
                            .fill(RGB(hx).color(scheme, lift: 0.08))
                            .frame(maxWidth: .infinity)
                            .frame(height: compact ? 12 : 15)
                            .overlay {
                                RoundedRectangle(cornerRadius: 3, style: .continuous)
                                    .strokeBorder(Color.primary.opacity(0.16), lineWidth: 0.6)
                            }
                    }
                }

                if !compact && !palette.intro.isEmpty {
                    Text(palette.intro)
                        .font(.system(size: 11.5))
                        .foregroundStyle(Theme.ink2(scheme))
                        .fixedSize(horizontal: false, vertical: true)
                        .lineSpacing(2)
                }
            }
            .padding(env.space(compact ? 11 : 16))
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(RoundedRectangle(cornerRadius: env.radius(Radius.md), style: .continuous))
        }
        .buttonStyle(.plain)
        .card(env.radius(Radius.md),
              tint: selected ? RGB(palette.accent).color(scheme, lift: 0.86,
                                                         opacity: scheme == .dark ? 0.14 : 0.10) : nil,
              look: env.look)
        .overlay {
            RoundedRectangle(cornerRadius: env.radius(Radius.md) + 0.5, style: .continuous)
                .strokeBorder(RGB(palette.accent).color(scheme).opacity(selected ? 0.55 : 0),
                              lineWidth: 1.6)
                .allowsHitTesting(false)
        }
    }
}

extension Palette {
    /// 色板条用的代表色（都取自实拍取样）
    var swatches: [String] {
        [accent, pageTop, pageBottom, card, ink2, urgent, notice, calm]
    }

    /// 铺满卡片宽度的色带：#强调色 + 四档紧急度 + 面/底/侧栏三个中性色 + 学科八色。
    /// 设置页与引导页共用同一份，同一个主题在两处看起来才一致。
    var bandHexes: [String] {
        [accent, urgent, soon, notice, calm, pageTop, card, sidebar]
        + Subject.keys.compactMap { subjects[$0] }
    }
}
