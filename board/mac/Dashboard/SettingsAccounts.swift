import SwiftUI
import AppKit

/* ======================================================================
   设置 › 账号管理

   为什么要有这一块：这个 App 一共要连四个地方 ——
     ManageBac（学校）、Microsoft Teams、希悦课表、DeepSeek（灵析 AI）。
   以前它们散落在引导流程、希悦设置、灵析 AI 页三处，用户想「看看哪个掉了」
   得来回找。这里把它们收进一张表：谁连上了、连的是哪个账号、上次什么时候
   校过、掉了怎么重连 —— 一眼看完。

   位置：设置大板块里，紧跟「主题」之后的第一个子板块（用户指定）。

   写这一块时守住三条：
     ① **登录态和数据分开说话**：这里只报「登录成功 / 失败」，不拿缓存里的数据
        当登录证据（否则前端会理直气壮地撒谎 —— 这个坑踩过）。
     ② 每个动作都有**明确的下一步**：失败要说清「该去做什么」，不是只丢一句失败。
     ③ 密码只进钥匙串；勾选才存，不勾就只在这一次用。
   ====================================================================== */

@MainActor
final class AccountsCenter: ObservableObject {
    static let shared = AccountsCenter()

    enum Kind: String, CaseIterable, Identifiable {
        case managebac, teams, seiue, deepseek
        var id: String { rawValue }

        var name: String {
            switch self {
            case .managebac: return "ManageBac"
            case .teams:     return "Microsoft Teams"
            case .seiue:     return "希悦课表"
            case .deepseek:  return "DeepSeek（灵析 AI）"
            }
        }
        var purpose: String {
            switch self {
            case .managebac: return "作业、截止时间、成绩与总评都来自这里"
            case .teams:     return "从任务、邮件、聊天里挑出学习待办"
            case .seiue:     return "整周课表更直观，一周同步一次就够"
            case .deepseek:  return "灵析 AI 的对话能力"
            }
        }
        var icon: String {
            switch self {
            case .managebac: return "graduationcap.fill"
            case .teams:     return Icons.teams
            case .seiue:     return "calendar.badge.clock"
            case .deepseek:  return "sparkles.rectangle.stack.fill"
            }
        }
        /// 登录方式一句话 —— 用户最想知道的就是「要不要输密码」
        var how: String {
            switch self {
            case .managebac: return "账号 + 密码"
            case .teams:     return "在浏览器里登录一次"
            case .seiue:     return "在浏览器里登录一次"
            case .deepseek:  return "在网页上登录一次"
            }
        }
    }

    /* --- 各账号状态 --- */
    @Published var mbLogged = false
    @Published var mbUser = ""
    @Published var hasCreds = false
    @Published var teamsLogged = false
    @Published var teamsAccount = ""
    @Published var seiueLogged = false
    @Published var seiueBrowser = false
    @Published var seiueCourses = 0

    @Published var busy: Kind? = nil
    @Published var line: [Kind: String] = [:]      // 每个账号各自的状态行
    @Published var summary = "点右上「全部检查」看看四个账号现在什么情况"
    @Published var lastCheck: [Kind: Date] = [:]
    @Published var deepseek: Bool = false
    @Published var deepseekReady = false

    @Published var teamsPending = ""      // 浏览器授权进行中的提示（会自动刷新）

    private var poll: Timer?

    private init() {}

    var allOn: Bool {
        mbLogged && teamsLogged && seiueLogged && deepseek
    }

    // MARK: 检查

    func refreshAll(quiet: Bool = false) async {
        if !quiet { summary = "正在检查四个账号…" }
        async let a: Void = checkManageBac(quiet: quiet)
        async let b: Void = checkTeams(quiet: quiet)
        async let c: Void = checkSeiue(quiet: quiet)
        _ = await (a, b, c)
        syncDeepSeek()
        if !quiet {
            let n = [mbLogged, teamsLogged, seiueLogged, deepseek].filter { $0 }.count
            summary = n == 4 ? "四个账号均已连接"
                             : "已连接 \(n)/4 —— 标红的点一下即可连接"
        }
    }

    func checkManageBac(quiet: Bool = false) async {
        if busy == nil { if !quiet { line[.managebac] = "正在检查…" } }
        // 用户手动点的时候（!quiet）才现场探；自动/静默轮询读快照，毫秒级。
        guard let d = await Bridge.manageBacStatus(probe: !quiet) else {
            mbLogged = false
            line[.managebac] = "看板没起来 —— 点右上「重连」或重启 App"
            return
        }
        mbLogged = (d["loggedIn"] as? Bool) ?? false
        mbUser = (d["user"] as? String) ?? ""
        hasCreds = (d["hasCreds"] as? Bool) ?? hasCreds
        // 读 msg，读不到退回 reason —— 以前只读 msg，服务端的提示全被吞了。
        let note = Bridge.text(d)
        if !mbLogged, !note.isEmpty { line[.managebac] = note }
        else { line[.managebac] = mbLogged ? "已连接" + (mbUser.isEmpty ? "" : "：\(mbUser)") : "未登录" }
        lastCheck[.managebac] = Date()
    }

    func checkTeams(quiet: Bool = false) async {
        // 45 秒：服务端已把「现场取令牌」挪到后台，正常回包在毫秒级；
        // 留宽只为防浏览器正好在重启这类极端情况。
        guard let d = await Bridge.get("/api/teams", timeout: 45) else {
            line[.teams] = "看板没应答"
            return
        }
        teamsLogged = (d["loggedIn"] as? Bool) ?? false
        teamsAccount = (d["account"] as? String) ?? ""
        let step = (d["loginStep"] as? Int) ?? 0
        let msg = (d["loginMsg"] as? String) ?? ""
        if teamsLogged {
            line[.teams] = "已连接" + (teamsAccount.isEmpty ? "" : "：\(teamsAccount)")
            teamsPending = ""
        } else if step > 0 {
            teamsPending = msg.isEmpty ? "等你在浏览器里登录…" : msg
            line[.teams] = teamsPending
        } else {
            line[.teams] = "未连接 —— 点「打开浏览器登录」，在窗口里登一次即可"
        }
        lastCheck[.teams] = Date()
    }

    func checkSeiue(quiet: Bool = false) async {
        // 60 秒：希悦这一趟可能要走「开浏览器 → 回首页 → 读整张课表」，
        // 冷启动比 Teams 还慢一档；缓存命中时是毫秒级。
        guard let d = await Bridge.get("/api/seiue", timeout: 60) else {
            line[.seiue] = "看板没应答"
            return
        }
        let st = (d["status"] as? [String: Any]) ?? [:]
        let live = (st["loggedIn"] as? Bool) ?? false
        let hasSession = (st["hasSession"] as? Bool) ?? false
        // ★ 只认 live 是这个 bug 的根：浏览器没开着时探不到页面，可登录态
        //   明明还留在电脑上（用户刚在窗口里登过）。于是 App 说「未登录」，
        //   用户说「我明明登录了、课表都看见了」——两边都没错，是判定太窄。
        seiueLogged = live || hasSession
        seiueBrowser = (st["browserUp"] as? Bool) ?? false
        let sch = (d["schedule"] as? [String: Any]) ?? [:]
        let lessons = (sch["lessons"] as? [[String: Any]])?.count ?? 0
        seiueCourses = lessons
        let fromExcel = (sch["source"] as? String) == "excel"
            || (st["fromExcel"] as? Bool) == true
        if seiueLogged {
            if sch["ok"] as? Bool == true {
                line[.seiue] = fromExcel
                    ? "已连接 · 已认出导出的课表（\(lessons) 节）"
                    : "已连接 · 课表 \(lessons) 节"
            } else {
                line[.seiue] = "已登录，点「同步课表」拉一次"
            }
        } else if seiueBrowser {
            line[.seiue] = "登录窗口开着 —— 登完点「同步课表」"
        } else {
            line[.seiue] = "未连接 —— 点「打开希悦登录」，登一次即可"
        }
        lastCheck[.seiue] = Date()
    }

    func syncDeepSeek() {
        let ai = AIEngine.shared
        deepseek = ai.isAuthed
        deepseekReady = ai.ready
        line[.deepseek] = ai.ready ? "已连接 · 可以对话了"
            : (ai.isAuthed ? (ai.bootHint.isEmpty ? "正在连接…" : ai.bootHint)
                           : "未登录 —— 点「去登录」在弹出的页面上登一次")
        if ai.lastCheck > .distantPast { lastCheck[.deepseek] = ai.lastCheck }
    }

    // MARK: 动作

    func loginManageBac(_ account: String, _ password: String, save: Bool) async {
        busy = .managebac
        line[.managebac] = "正在登录…（学校站点偶尔慢，最多等 90 秒）"
        Bridge.launchIfNeeded()
        for _ in 0..<20 { if await DataStore.shared.healthy() { break }; try? await Task.sleep(nanoseconds: 400_000_000) }
        let r = await Bridge.post("/api/login", [
            "login": account.trimmed, "password": password, "remember": true, "save": save,
        ], timeout: 110)
        busy = nil
        let ok = Bridge.ok(r)
        mbLogged = ok
        line[.managebac] = ok
            ? "登录成功" + (save ? "，账号密码已存进系统钥匙串" : "")
            : Bridge.msg(r, "登录失败：检查账号密码，或学校站点暂时不通")
        if ok {
            hasCreds = (r?["hasCreds"] as? Bool) ?? hasCreds
            Task { await DataStore.shared.load(force: true) }
        }
        lastCheck[.managebac] = Date()
    }

    func logoutManageBac() async {
        busy = .managebac
        _ = await Bridge.post("/api/logout", [:], timeout: 30)
        busy = nil
        mbLogged = false
        line[.managebac] = "已退出登录"
    }

    func forgetCreds() async {
        _ = await Bridge.post("/api/forget-creds", [:])
        hasCreds = false
        line[.managebac] = "已删除本机保存的账号密码"
    }

    func loginTeams() async {
        busy = .teams
        line[.teams] = "正在打开浏览器…"
        Bridge.launchIfNeeded()
        let r = await Bridge.post("/api/teams/login", [:], timeout: 45)
        busy = nil
        line[.teams] = Bridge.ok(r) ? "浏览器已打开，请在窗口里完成登录（这边会自动识别）"
                                    : Bridge.msg(r, "打开失败，稍后重试")
        startPolling()
        await checkTeams()
    }

    func logoutTeams() async {
        busy = .teams
        _ = await Bridge.post("/api/teams/logout", [:], timeout: 30)
        busy = nil
        teamsLogged = false
        teamsAccount = ""
        line[.teams] = "已退出登录"
    }

    func loginSeiue() async {
        busy = .seiue
        line[.seiue] = "正在打开希悦登录窗口…"
        Bridge.launchIfNeeded()
        let r = await Bridge.post("/api/seiue/login", [:], timeout: 60)
        busy = nil
        line[.seiue] = Bridge.ok(r) ? "登录窗口已打开，登完点「同步课表」"
                                    : Bridge.msg(r, "打开失败：稍后重试")
        startPolling()
        await checkSeiue()
    }

    func syncSeiue() async {
        busy = .seiue
        line[.seiue] = "正在读取课表…（看板会自己去网页上取，最多等 2 分钟）"
        let r = await Bridge.post("/api/seiue/sync", [:], timeout: 130)
        busy = nil
        let ok = Bridge.ok(r)
        if ok { BoardSettings.shared.seiueEnabled = true }
        let n = ((r?["lessons"] as? [[String: Any]])?.count) ?? 0
        let viaExcel = (r?["source"] as? String) == "excel"
        if ok {
            line[.seiue] = viaExcel
                ? "已认出网页导出的课表，共 \(n) 节"
                : "课表已同步，共 \(n) 节"
        } else {
            line[.seiue] = Bridge.msg(r, "没读到课表：先确认希悦窗口里已经登录")
        }
        await checkSeiue()
    }

    func logoutSeiue() async {
        busy = .seiue
        _ = await Bridge.post("/api/seiue/logout", [:], timeout: 30)
        busy = nil
        seiueLogged = false
        line[.seiue] = "已退出登录"
    }

    /// DeepSeek 没有独立的登录接口 —— 直接把真实登录页摊到窗口上
    func loginDeepSeek() {
        AIEngine.shared.showSite = true
        line[.deepseek] = "登录页已打开，登完点左上「我已登录好了」"
        startPolling()
    }

    func logoutDeepSeek() {
        AIEngine.shared.signOut()
        line[.deepseek] = "已退出登录"
    }

    func checkDeepSeek() {
        AIEngine.shared.checkNow()
        syncDeepSeek()
    }

    /// 本机桥接服务没应答时的一键补救。
    /// ManageBac / Teams / 希悦 全靠它（127.0.0.1:8765），它一挂这三张卡全是红的，
    /// 所以必须有一个「不用懂原理，点一下就好」的入口。
    func reconnectBridge() async {
        busy = .managebac
        line[.managebac] = "正在启动看板…"
        Bridge.launchIfNeeded()
        for _ in 0..<24 {
            if await DataStore.shared.healthy() { break }
            try? await Task.sleep(nanoseconds: 500_000_000)
        }
        busy = nil
        await refreshAll(quiet: true)
        if !mbLogged && teamsLogged == false && !seiueLogged {
            line[.managebac] = "还是连不上 —— 把 App 退掉重开一次"
        }
    }

    // MARK: 浏览器授权 / 希悦窗口开着时，自动刷状态（用户不用手点）

    private func startPolling() {
        guard poll == nil else { return }
        poll = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                await self.checkTeams(quiet: true)
                await self.checkSeiue(quiet: true)
                self.syncDeepSeek()
                if self.teamsLogged && self.seiueLogged {
                    self.poll?.invalidate(); self.poll = nil
                }
            }
        }
    }
}

/* ======================================================================
   界面
   ====================================================================== */

struct AccountsGroup: View {
    @EnvironmentObject var settings: BoardSettings
    @Environment(\.colorScheme) private var scheme

    @ObservedObject private var ac = AccountsCenter.shared
    @ObservedObject private var ai = AIEngine.shared

    @State private var mbAccount = ""
    @State private var mbPassword = ""
    @State private var mbSave = true
    @State private var showReLogin = false
    @State private var revealPw = false

    private var env: Env { Env(scheme: scheme, settings: settings) }

    var body: some View {
        VStack(alignment: .leading, spacing: env.space(13)) {
            HStack(alignment: .firstTextBaseline, spacing: 9) {
                Image(systemName: "person.2.badge.key.fill")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(env.accent.color(scheme, lift: 0.12))
                Text("账号管理").font(.system(size: 20, weight: .bold))
                    .foregroundStyle(Theme.ink(scheme))
                Spacer(minLength: 8)
                Text(ac.summary)
                    .font(.system(size: 11.5))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                Button {
                    Task { await ac.refreshAll() }
                } label: {
                    HStack(spacing: 5) {
                        SpinIcon(spinning: ac.busy != nil).foregroundStyle(Theme.ink(scheme))
                        Text("全部检查").font(.system(size: 11.5, weight: .semibold))
                    }
                    .foregroundStyle(Theme.ink(scheme))
                    .padding(.horizontal, 11).frame(height: 26)
                    .contentShape(RoundedRectangle(cornerRadius: env.radius(Radius.sm), style: .continuous))
                }
                .buttonStyle(.plain)
                .card(env.radius(Radius.sm), look: env.look, shadow: false)
                .help("四个账号一起查一遍当前状态")

                // 本机桥接服务没应答时，三张卡会一起变红 —— 这个按钮就是给那种情况准备的
                Button {
                    Task { await ac.reconnectBridge() }
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "arrow.clockwise").font(.system(size: 10.5, weight: .semibold))
                        Text("重连").font(.system(size: 11.5, weight: .semibold))
                    }
                    .foregroundStyle(Theme.ink(scheme))
                    .padding(.horizontal, 11).frame(height: 26)
                    .contentShape(RoundedRectangle(cornerRadius: env.radius(Radius.sm), style: .continuous))
                }
                .buttonStyle(.plain)
                .card(env.radius(Radius.sm), look: env.look, shadow: false)
                .help("重新启动看板，再查一遍四个账号")
            }
            .padding(.horizontal, 2)

            VStack(spacing: env.space(10)) {
                manageBacCard
                teamsCard
                seiueCard
                deepseekCard
            }

            HStack(spacing: 8) {
                Image(systemName: "lock.shield.fill").font(.system(size: 11))
                    .foregroundStyle(env.accent.color(scheme, lift: 0.10))
                Text("勾选「记住」才会存进 macOS 钥匙串，"
                     + "不勾就只在这一次登录里用一下。")
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.ink2(scheme))
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 3)
        }
        .appearIn(0)
        .task { await ac.refreshAll(quiet: true) }
        // 灵析 AI 的登录态在别的页面变化，这里跟着走（只读，不发请求）。
        // 同上：用 .task 循环，不用 onReceive(Timer.publish(…))。
        .task {
            guard !PreviewFlags.offscreen else { return }
            while !Task.isCancelled {
                do { try await Task.sleep(nanoseconds: 4_000_000_000) } catch { return }
                ac.syncDeepSeek()
            }
        }
    }

    /* ---------------- 通用零件 ---------------- */

    @ViewBuilder
    private func statusChip(_ k: AccountsCenter.Kind, ok: Bool, mid: Bool = false) -> some View {
        if ac.busy == k {
            Pill(env: env, text: "处理中", color: Theme.amberDefault, icon: "clock", bold: true)
        } else if ok {
            Pill(env: env, text: "已连接", color: Theme.greenDefault, icon: "checkmark.circle.fill", bold: true)
        } else if mid {
            Pill(env: env, text: "等待中", color: Theme.amberDefault, icon: "hourglass", bold: true)
        } else {
            Pill(env: env, text: "未连接", color: Theme.ink3_RGB, icon: "circle.dashed", bold: true)
        }
    }

    private func cardHead(_ k: AccountsCenter.Kind, ok: Bool, mid: Bool = false,
                          account: String = "") -> some View {
        HStack(spacing: env.space(11)) {
            ZStack {
                RoundedRectangle(cornerRadius: env.radius(9), style: .continuous)
                    .fill(env.accent.color(scheme).opacity(ok ? 0.15 : 0.08))
                    .frame(width: 34, height: 34)
                Image(systemName: k.icon)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(ok ? env.accent.color(scheme, lift: 0.10) : Theme.ink3(scheme))
            }
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 7) {
                    Text(k.name).font(.system(size: 13.5, weight: .semibold))
                        .foregroundStyle(Theme.ink(scheme))
                    Text(k.how)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(Theme.ink3(scheme))
                        .padding(.horizontal, 6).padding(.vertical, 1.5)
                        .background(Capsule().fill(Color.primary.opacity(0.06)))
                }
                Text(account.isEmpty ? k.purpose : "\(k.purpose) · 当前：\(account)")
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.ink2(scheme))
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: env.space(10))
            statusChip(k, ok: ok, mid: mid)
        }
    }

    /// 状态行 + 上次校验时间：让「这个状态是什么时候看的」变得可查
    private func footLine(_ k: AccountsCenter.Kind) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "info.circle").font(.system(size: 10))
            Text(ac.line[k] ?? "还没检查")
                .font(.system(size: 11))
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 6)
            if let t = ac.lastCheck[k] {
                Text(rel(t)).font(.system(size: 10)).foregroundStyle(.tertiary)
            }
        }
        .foregroundStyle(Theme.ink2(scheme))
    }

    private func rel(_ d: Date) -> String {
        let s = Int(Date().timeIntervalSince(d))
        if s < 10 { return "刚刚校验" }
        if s < 60 { return "\(s) 秒前校验" }
        if s < 3600 { return "\(s / 60) 分钟前校验" }
        return "\(s / 3600) 小时前校验"
    }

    private func act(_ title: String, icon: String, primary: Bool = false,
                     enabled: Bool = true, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: icon).font(.system(size: 10.5, weight: .semibold))
                Text(title).font(.system(size: 12, weight: .semibold))
            }
            .foregroundStyle(!enabled ? Theme.ink3(scheme) : (primary ? .white : Theme.ink(scheme)))
            .padding(.horizontal, 13).frame(height: 28)
            .background {
                RoundedRectangle(cornerRadius: env.radius(Radius.sm), style: .continuous)
                    .fill(!enabled ? Color.primary.opacity(0.08)
                                   : (primary ? env.accent.color(scheme, lift: 0.02)
                                              : Color.primary.opacity(0.07)))
            }
            .contentShape(RoundedRectangle(cornerRadius: env.radius(Radius.sm), style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
    }

    private func fieldRow(_ title: String, hint: String, text: Binding<String>,
                          placeholder: String, secure: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(title).font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(Theme.ink(scheme))
                Text(hint).font(.system(size: 10.5)).foregroundStyle(Theme.ink3(scheme))
                Spacer(minLength: 0)
            }
            SoftField(placeholder: placeholder, text: text, scheme: scheme,
                      font: .system(size: 13), secure: secure && !revealPw)
            .padding(.horizontal, 10)
            .frame(height: 32)
            // 输入框得**读起来像输入框**（原来这里是 `.card(...)`，和卡片同一种面，
            // 白底上基本看不出来）。统一走 fieldWell，见 Components.swift。
            .fieldWell(env)
        }
    }

    /* ---------------- ① ManageBac ---------------- */

    private var manageBacCard: some View {
        VStack(alignment: .leading, spacing: env.space(11)) {
            cardHead(.managebac, ok: ac.mbLogged, account: ac.mbUser)

            footLine(.managebac)

            // 学校地址：本机服务是启动时通过 MBBOARD_SCHOOL 读到它的，
            // 所以改完不一定立刻生效 —— 旁边那个「应用」按钮会重启一次本机服务。
            HStack(alignment: .bottom, spacing: env.space(8)) {
                fieldRow("学校地址", hint: "填你学校 ManageBac 的网址；不是 101 就改这一行",
                         text: $settings.schoolURL, placeholder: SchoolURL.fallback)
                act("应用", icon: "arrow.clockwise", enabled: ac.busy == nil) {
                    Task { await ac.reconnectBridge() }
                }
                .help("重启看板，让新地址生效，然后重查四个账号")
            }

            if !ac.mbLogged || showReLogin {
                // 占位符不能再留空：空的 TextField 就是一个空框，
                // 用户看不出「学号」还是「邮箱」还是「完整邮箱」。
                fieldRow("账号", hint: "通常是学号或邮箱前缀", text: $mbAccount,
                         placeholder: "例如 2024xxxxxx 或 name.surname")
                fieldRow("密码", hint: "", text: $mbPassword, placeholder: "••••••••", secure: true)

                HStack(spacing: 9) {
                    Toggle(isOn: $mbSave) {
                        Text("记住账号密码（存进 macOS 钥匙串）").font(.system(size: 11.5))
                            .foregroundStyle(Theme.ink2(scheme))
                    }
                    .toggleStyle(.checkbox)
                    Button {
                        revealPw.toggle()
                    } label: {
                        Image(systemName: revealPw ? "eye.slash" : "eye")
                            .font(.system(size: 11))
                            .foregroundStyle(Theme.ink3(scheme))
                    }
                    .buttonStyle(.plain)
                    .help("显示 / 隐藏密码")
                    Spacer(minLength: 0)
                }
            }

            HStack(spacing: env.space(8)) {
                if ac.mbLogged && !showReLogin {
                    act("重新登录", icon: "arrow.triangle.2.circlepath") { showReLogin = true }
                    act("退出登录", icon: Icons.logout) { Task { await ac.logoutManageBac() } }
                } else {
                    act(ac.mbLogged ? "登录" : "登录 ManageBac",
                        icon: "arrow.right.circle.fill", primary: true,
                        enabled: !mbAccount.trimmed.isEmpty && !mbPassword.isEmpty && ac.busy == nil) {
                        Task {
                            await ac.loginManageBac(mbAccount, mbPassword, save: mbSave)
                            if ac.mbLogged { mbPassword = ""; showReLogin = false }
                        }
                    }
                    if ac.mbLogged { act("取消", icon: "xmark") { showReLogin = false } }
                }

                if ac.hasCreds {
                    act("删除本机保存的密码", icon: "key.slash") { Task { await ac.forgetCreds() } }
                }
                Spacer(minLength: 0)
            }
        }
        .padding(env.space(14))
        .card(env.radius(Radius.md), look: env.look)
    }

    /* ---------------- ② Teams ---------------- */

    private var teamsCard: some View {
        VStack(alignment: .leading, spacing: env.space(11)) {
            cardHead(.teams, ok: ac.teamsLogged, mid: !ac.teamsLogged && !ac.teamsPending.isEmpty,
                     account: ac.teamsAccount)
            footLine(.teams)

            HStack(spacing: env.space(8)) {
                act(ac.teamsLogged ? "重新授权" : "打开浏览器登录", icon: "safari.fill", primary: true) {
                    Task { await ac.loginTeams() }
                }
                if !ac.teamsLogged {
                    act("我已经登录好了", icon: "checkmark.circle") { Task { await ac.checkTeams() } }
                } else {
                    act("退出登录", icon: Icons.logout) { Task { await ac.logoutTeams() } }
                }
                Spacer(minLength: 0)
            }
        }
        .padding(env.space(14))
        .card(env.radius(Radius.md), look: env.look)
    }

    /* ---------------- ③ 希悦 ---------------- */

    private var seiueCard: some View {
        VStack(alignment: .leading, spacing: env.space(11)) {
            cardHead(.seiue, ok: ac.seiueLogged, mid: ac.seiueBrowser && !ac.seiueLogged)
            footLine(.seiue)

            if ac.seiueLogged {
                HStack(spacing: env.space(8)) {
                    act("同步课表", icon: "arrow.triangle.2.circlepath", primary: true) {
                        Task { await ac.syncSeiue() }
                    }
                    act("退出登录", icon: Icons.logout) { Task { await ac.logoutSeiue() } }
                    Toggle(isOn: $settings.seiueEnabled) {
                        Text("用希悦课表覆盖课程页").font(.system(size: 11.5))
                            .foregroundStyle(Theme.ink2(scheme))
                    }
                    .toggleStyle(.checkbox)
                    Spacer(minLength: 0)
                }
            } else {
                HStack(spacing: env.space(8)) {
                    act("打开希悦登录", icon: "calendar.badge.clock", primary: true) {
                        Task { await ac.loginSeiue() }
                    }
                    act("同步课表", icon: "arrow.triangle.2.circlepath", enabled: ac.busy == nil) {
                        Task { await ac.syncSeiue() }
                    }
                    Spacer(minLength: 0)
                }
            }
        }
        .padding(env.space(14))
        .card(env.radius(Radius.md), look: env.look)
    }

    /* ---------------- ④ DeepSeek ---------------- */

    private var deepseekCard: some View {
        VStack(alignment: .leading, spacing: env.space(11)) {
            cardHead(.deepseek, ok: ac.deepseek)
            footLine(.deepseek)

            HStack(spacing: env.space(8)) {
                if ac.deepseek {
                    act("去灵析 AI 聊聊", icon: Icons.ai, primary: true) {
                        settings.dashboardSection = DashSection.ai.rawValue
                    }
                    act("重连", icon: "arrow.clockwise") {
                        AIEngine.shared.reconnect()
                        ac.checkDeepSeek()
                    }
                    act("重新登录", icon: "arrow.triangle.2.circlepath") { ac.loginDeepSeek() }
                    act("退出登录", icon: Icons.logout) { ac.logoutDeepSeek() }
                } else {
                    act("去登录", icon: "safari.fill", primary: true) { ac.loginDeepSeek() }
                    act("重连", icon: "arrow.clockwise") {
                        AIEngine.shared.reconnect()
                        ac.checkDeepSeek()
                    }
                    act("检查登录状态", icon: "arrow.clockwise") { ac.checkDeepSeek() }
                }
                Spacer(minLength: 0)
            }

            HStack(spacing: 7) {
                Image(systemName: "lightbulb.fill").font(.system(size: 10))
                    .foregroundStyle(env.accent.color(scheme, lift: 0.10))
                Text("登录一次就好，以后再打开会自动记住。"
                     + "点「去登录」时登录页会盖在窗口上，登完点左上角按钮收起即可。")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.ink2(scheme))
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, env.space(11))
            .padding(.vertical, env.space(8))
            .background {
                RoundedRectangle(cornerRadius: env.radius(Radius.sm), style: .continuous)
                    .fill(env.accent.color(scheme).opacity(0.07))
            }
        }
        .padding(env.space(14))
        .card(env.radius(Radius.md), look: env.look)
    }
}
