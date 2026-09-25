import SwiftUI
import AppKit

/* ======================================================================
   ④ Teams 板块
   数据来自 Microsoft Graph（微软任务 / Outlook 邮件 / 日历 / Teams 频道消息），
   凭据不走应用注册，而是复用「专用浏览器窗口」里你自己登录 Teams 网页版得到的登录态，
   因此不需要管理员批准。
   其中「邮件与频道消息」里的待办由识别引擎自动抽取，所以每条都会标出置信度与依据，
   让用户一眼能分清「这条本来就是任务」还是「这条是我推断出来的」。
   ====================================================================== */

struct TeamsSection: View {
    @ObservedObject var store: DataStore
    @EnvironmentObject var settings: BoardSettings
    @Environment(\.colorScheme) private var scheme
    /// 顶部搜索框的内容。Teams 页要同时搜任务、邮件、日程和 EC 名单。
    var search: String = ""

    @State private var filter: String = "all"
    @State private var showMail: Bool = false
    @State private var showAllTasks: Bool = false

    private var env: Env { Env(scheme: scheme, settings: settings) }
    private var q: Search.Query { Search.parse(search) }

    /* 搜索过滤：一处定义，概览/日程/任务/邮件都复用同一份结果，
       这样「搜索框里显示的命中数」和列表里真正显示的东西永远一致。 */

    private var tasks: [TeamsTaskVM] {
        let all = store.teamsTasks
        guard !q.isEmpty else { return all }
        return all.filter {
            Search.hit(q, [$0.title, $0.course, $0.from, $0.detail,
                           $0.source.label, $0.signals.joined(separator: " ")])
        }
    }

    private var events: [TeamsEventVM] {
        let all = store.teamsEvents
        guard !q.isEmpty else { return all }
        return all.filter { Search.hit(q, [$0.title, $0.location, $0.organizer]) }
    }

    private var mails: [TeamsMailVM] {
        let all = store.teamsMails
        guard !q.isEmpty else { return all }
        return all.filter { Search.hit(q, [$0.subject, $0.from, $0.preview]) }
    }

    /// 搜索时把 EC 名单也当数据源（打同学名字能直接看到他在哪个班）
    private var ecStudentHits: [String] {
        guard !q.isEmpty else { return [] }
        let info = store.teamsEC
        let names = (info?.students ?? []) + (info?.otherGroups ?? [:]).values.flatMap { $0 }
        return names.filter { Search.hit(q, [$0]) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: settings.density.sectionGap) {
            // 只要手里有内容就显示数据视图 —— 哪怕这一刻的登录态没探到。
            // 以前只看 loggedIn，bridge 刚起来令牌缓存是空的，明明磁盘里
            // 存着上次抓到的内容，界面却把用户晾在「去登录」卡片上。
            if store.teams?.loggedIn == true || hasContent {
                staleBanner
                ecBoard
                overview
                agenda
                taskList
                mailBlock
            } else {
                connectCard
            }
        }
        // ★ 以前这里是 `.sheet(item:)` —— 系统模态弹窗 ★
        // 换成「窗口内浮层」，有两个实打实的原因：
        //   ① 液态玻璃描边要有东西可折射。系统 sheet 是独立窗口，玻璃采样到的
        //      基本只有桌面和别的窗口，描边看着是空的；浮层压在待办页上，
        //      折射的是真实的看板内容，玻璃才是活的。
        //   ② 和任务详情单（TaskDetailHost）走同一套浮层约定，样式/关闭行为一致。
        //
        // 后来又踩了个更隐蔽的坑：这个 `.overlay` 是挂在**滚动内容**上的，
        // 所以「居中」居的是整篇长文的中点 —— 任务一多，小窗就掉到视口下方、
        // 被窗口底边切掉一半（用户截图就是）。浮层必须挂在**窗口根部的 ZStack**
        // 上才谈得上居中，所以宿主被搬到了 DashRoot 里（TaskPreviewHost）。
    }

    /// 这一块到底有没有东西可显示（决定走数据视图还是登录引导）
    private var hasContent: Bool {
        let s = store.teamsSection
        return !(s?.tasks ?? []).isEmpty
            || !(s?.mail ?? []).isEmpty
            || !(s?.events ?? []).isEmpty
    }

    /// 这一轮没抓到新数据时顶部的说明条。
    ///
    /// 链路抖一下（学校网常见）不该让整块看起来像坏了：内容照旧列在下面，
    /// 只是如实告诉用户「它不是最新的、正在重连」。比一片空白体面得多。
    @ViewBuilder
    private var staleBanner: some View {
        if store.teams?.stale == true {
            let sec = store.teams?.lastGoodSec ?? 0
            let age = sec < 90 ? "刚刚"
                : (sec < 3600 ? "\(max(1, sec / 60)) 分钟前" : "\(sec / 3600) 小时前")
            HStack(spacing: env.space(8)) {
                Image(systemName: "clock.arrow.circlepath")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Theme.amberDefault.color(scheme, lift: 0.06))
                Text("暂时连不上微软，下面是 \(age)读到的内容")
                    .font(Typo.micro)
                    .foregroundStyle(Theme.ink2(scheme))
                Spacer(minLength: 0)
                if store.teams?.fetching == true {
                    ProgressView()
                        .controlSize(.small)
                        .scaleEffect(0.7)
                }
            }
            .padding(.horizontal, env.space(13))
            .padding(.vertical, env.space(9))
            .background {
                RoundedRectangle(cornerRadius: env.radius(Radius.md), style: .continuous)
                    .fill(Theme.amberDefault.color(scheme, lift: 0.10).opacity(0.12))
            }
        }
    }

    /* ---------------- 未连接 ---------------- */

    /// 登录引导面板。
    ///
    /// 现在的做法：程序常驻一个「专用浏览器窗口」，你在里面**正常登录一次 Teams 网页版**，
    /// 程序复用这个登录态去读数据 —— 不注册应用、不走设备码，也就不会撞上
    /// AADSTS65002 或「需要管理员批准」。所以这里只讲清「去那个窗口登录一次」。
    private func browserLoginPanel() -> some View {
        let url = store.teams?.remoteUrl ?? "https://teams.cloud.microsoft/"
        let steps: [(String, String)] = [
            ("1", "弹出的窗口是 Teams 网页版，用你的学校账号登录"),
            ("2", "如果问「保持登录？」，选「是」——以后就不用再登了"),
            ("3", "登进去这张卡片会自动变成数据视图，不用回来点任何按钮"),
        ]
        return VStack(alignment: .leading, spacing: env.space(11)) {
            Text("在打开的窗口里登录一次")
                .font(Typo.sub)
                .foregroundStyle(Theme.ink2(scheme))

            VStack(alignment: .leading, spacing: env.space(7)) {
                ForEach(steps, id: \.0) { n, txt in
                    HStack(alignment: .top, spacing: env.space(9)) {
                        Text(n)
                            .font(.system(size: 10.5, weight: .bold, design: .rounded))
                            .foregroundStyle(.white)
                            .frame(width: 17, height: 17)
                            .background {
                                Circle().fill(settings.accent.color(scheme, lift: 0.06))
                            }
                        Text(txt)
                            .font(Typo.callout)
                            .foregroundStyle(Theme.ink2(scheme))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }

            HStack(spacing: env.space(9)) {
                Button {
                    if !url.isEmpty, let u = URL(string: url) { NSWorkspace.shared.open(u) }
                } label: {
                    Text("重新打开登录窗口")
                        .font(.system(size: 12, weight: .semibold))
                        .padding(.horizontal, env.space(13))
                        .padding(.vertical, env.space(6))
                        .background { Capsule().fill(settings.accent.color(scheme, lift: 0.06)) }
                        .foregroundStyle(.white)
                }
                .buttonStyle(.plain)

                Button {
                    if let u = URL(string: "http://127.0.0.1:8765/go/ms-login") {
                        NSWorkspace.shared.open(u)
                    }
                } label: {
                    Text("让程序再弹一次")
                        .font(.system(size: 12, weight: .semibold))
                        .padding(.horizontal, env.space(13))
                        .padding(.vertical, env.space(6))
                        .background {
                            Capsule().strokeBorder(Theme.ink2(scheme).opacity(0.20), lineWidth: 1)
                        }
                        .foregroundStyle(Theme.ink2(scheme))
                }
                .buttonStyle(.plain)
                Spacer(minLength: 0)
            }

            Text("看板只读，内容跟你自己在浏览器里看到的一致 —— 不会替你发消息，也不会改任何东西。")
                .font(Typo.micro)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, env.space(14))
        .padding(.vertical, env.space(13))
        .background {
            RoundedRectangle(cornerRadius: env.radius(Radius.md), style: .continuous)
                .fill(settings.accent.color(scheme, lift: 0.10).opacity(0.10))
        }
    }

    private var connectCard: some View {
        let logging = store.teams?.loggingIn == true
        let failed = (store.teams?.error != nil) && !logging
        let loginHint = (store.teams?.loginMsg ?? "").trimmingCharacters(in: .whitespacesAndNewlines)

        return GlassCard(env: env, radius: Radius.lg, padding: env.space(26)) {
            VStack(alignment: .leading, spacing: env.space(16)) {
                HStack(spacing: env.space(13)) {
                    ZStack {
                        RoundedRectangle(cornerRadius: env.radius(Radius.sm), style: .continuous)
                            .fill(settings.accent.color(scheme, lift: 0.10).opacity(0.18))
                            .frame(width: 44, height: 44)
                        Image(systemName: Icons.teams)
                            .font(.system(size: 20, weight: .semibold))
                            .foregroundStyle(settings.accent.color(scheme, lift: 0.14))
                    }
                    VStack(alignment: .leading, spacing: 3) {
                        Text(logging
                             ? (loginHint.isEmpty ? "正在等你完成登录…" : loginHint)
                             : "连接微软账号")
                            .font(Typo.headline)
                            .foregroundStyle(Theme.ink(scheme))
                        Text(logging
                             ? "就差一步：在浏览器里点三下就好"
                             : "连一次就好，之后不用重复登录")
                            .font(Typo.sub)
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                }

                Text("这一页读的是你 **Microsoft Teams 与 Outlook** 里的内容：微软任务里的作业、邮件里提到的事（自动转成待办）、Teams 里点名提到你的消息，以及未来两周的日程。\n\n登录在微软自己的页面上完成，密码不经过看板。")
                    .font(Typo.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                if logging {
                    browserLoginPanel()
                }

                if logging, !loginHint.isEmpty {
                    HStack(spacing: 7) {
                        Image(systemName: "arrow.triangle.2.circlepath")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(settings.accent.color(scheme, lift: 0.10))
                        Text(loginHint).font(Typo.micro)
                            .foregroundStyle(Theme.ink2(scheme))
                            .lineLimit(3)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.horizontal, env.space(11))
                    .padding(.vertical, env.space(8))
                    .background {
                        RoundedRectangle(cornerRadius: env.radius(Radius.sm), style: .continuous)
                            .fill(settings.accent.color(scheme).opacity(0.09))
                    }
                }

                if failed, let e = store.teams?.error, e != "not_authenticated" {
                    HStack(alignment: .top, spacing: 7) {
                        Image(systemName: Icons.warn).font(.system(size: 12, weight: .bold))
                            .foregroundStyle(Theme.amberDefault.color(scheme, lift: 0.10))
                            .padding(.top, 1)
                        Text(e).font(Typo.micro).foregroundStyle(Theme.ink2(scheme))
                            .lineLimit(5)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.horizontal, env.space(11))
                    .padding(.vertical, env.space(8))
                    .background {
                        RoundedRectangle(cornerRadius: env.radius(Radius.sm), style: .continuous)
                            .fill(Theme.amberDefault.color(scheme).opacity(0.10))
                    }
                }

                HStack(spacing: env.space(10)) {
                    Button {
                        Task { await store.teamsLogin() }
                    } label: {
                        HStack(spacing: 6) {
                            if logging {
                                ProgressView().controlSize(.small)
                            } else {
                                Image(systemName: Icons.bolt).font(.system(size: 11, weight: .bold))
                            }
                            Text(logging ? "等你完成登录…" : "连接微软账号")
                                .font(.system(size: 12.5, weight: .semibold))
                        }
                        .padding(.horizontal, env.space(15))
                        .padding(.vertical, env.space(8))
                        .background {
                            Capsule().fill(settings.accent.color(scheme, lift: 0.06)
                                .opacity(logging ? 0.5 : 1))
                        }
                        .foregroundStyle(.white)
                    }
                    .buttonStyle(.plain)
                    .disabled(logging)

                    if logging {
                        Button {
                            if let u = URL(string: "http://127.0.0.1:8765/go/ms-login") {
                                NSWorkspace.shared.open(u)
                            }
                        } label: {
                            Text("重新打开登录窗口")
                                .font(.system(size: 12.5, weight: .semibold))
                                .padding(.horizontal, env.space(15))
                                .padding(.vertical, env.space(8))
                                .background {
                                    Capsule().strokeBorder(Theme.ink2(scheme).opacity(0.22),
                                                           lineWidth: 1)
                                }
                                .foregroundStyle(Theme.ink2(scheme))
                        }
                        .buttonStyle(.plain)
                    }

                    Text(logging ? "登录完不用回来点按钮，卡片会自动变成数据"
                                 : "只读你的邮件、日程、任务与频道消息，不会替你做任何操作")
                        .font(Typo.micro)
                        .foregroundStyle(.tertiary)
                    Spacer(minLength: 0)
                }
                .padding(.top, env.space(2))
            }
        }
        .appearIn(0)
    }

    /* ---------------- English Corner 板块 ---------------- */

    /// EC 板块。放在「Teams 学习待办」**上方**：
    /// EC 是当天 13:00 前就得动身的事，比一般待办更急，所以位置也比它高。
    /// 名单来自 Teams「ENGLISH CORNER ROSTER」频道里最新那份 PDF，
    /// 解析出每个班的人名；自己在名单里时才提示「今天要去」。
    @ViewBuilder
    private var ecBoard: some View {
        if let info = store.teamsEC, shouldShowEC(info) {
            let st = info.status ?? "none"
            // 后端说 active 还不够：14:00 一到就当场收掉，不等刷新
            let expired = (info.deadlineMs ?? .greatestFiniteMagnitude)
                < Date().timeIntervalSince1970 * 1000
            let active = info.active == true && !expired
            let imIn = info.imIn == true
            // 缓存还没过期但时间已过 → 显示上直接当成「已结束」
            let eff = (st == "today" && expired) ? "done" : st
            let klass = info.klass ?? ""
            let students = info.students ?? []
            let tint: RGB = active ? Theme.redDefault
                                   : (eff == "tomorrow" ? Theme.amberDefault : settings.accent)
            let place = info.place ?? "Room E113"
            let window = info.window ?? "13:00–13:40"

            let headline: String = {
                switch eff {
                case "today":    return imIn ? "今天要去 English Corner" : "今天有 EC，名单里没有我"
                case "done":     return imIn ? "今天 EC 已结束（你本来在名单里）" : "今天 EC 已结束"
                case "tomorrow": return imIn ? "明天要去 English Corner" : "明天有 EC，名单里没有我"
                case "future":   return "下一场 EC：" + (info.date ?? "")
                case "past":     return "最近一份名单已过期"
                case "error":    return "EC 名单暂时读不到"
                default:         return "今天没有 EC"
                }
            }()

            let statusText: String = {
                switch eff {
                case "today":    return active ? "现在就该去" : "今天"
                case "done":     return "已结束"
                case "tomorrow": return "明天"
                case "future":   return "未到"
                case "past":     return "已过期"
                case "error":    return "读取失败"
                default:         return "无"
                }
            }()

            GlassCard(env: env, radius: Radius.lg, padding: env.space(20)) {
                VStack(alignment: .leading, spacing: env.space(12)) {
                    HStack(spacing: env.space(11)) {
                        ZStack {
                            RoundedRectangle(cornerRadius: env.radius(9), style: .continuous)
                                .fill(tint.color(scheme, lift: 0.10).opacity(0.18))
                                .frame(width: 30, height: 30)
                            Image(systemName: "bubble.left.and.text.bubble.right.fill")
                                .font(.system(size: 12.5, weight: .semibold))
                                .foregroundStyle(tint.color(scheme, lift: 0.14))
                        }
                        Text("English Corner")
                            .font(Typo.headline)
                            .foregroundStyle(Theme.ink(scheme))
                        Pill(env: env, text: statusText, color: tint,
                             icon: active ? "clock.badge.exclamationmark.fill" : "clock")
                        Spacer(minLength: 0)
                        Label("\(window) · \(place)", systemImage: Icons.clock)
                            .font(Typo.micro)
                            .foregroundStyle(.secondary)
                        if let u = ecRosterURL(info) {
                            Button { openRoster(info) } label: {
                                HStack(spacing: 4) {
                                    Image(systemName: u.isFileURL ? "doc.fill" : Icons.open)
                                        .font(.system(size: 9.5, weight: .bold))
                                    Text(u.isFileURL ? "看名单（已存本地）" : "看名单")
                                        .font(.system(size: 11.5, weight: .semibold))
                                }
                                .padding(.horizontal, env.space(11))
                                .padding(.vertical, env.space(5))
                                .background { Capsule().strokeBorder(tint.color(scheme).opacity(0.35), lineWidth: 1) }
                                .foregroundStyle(tint.color(scheme, lift: 0.10))
                            }
                            .buttonStyle(.plain)
                            .help(u.isFileURL ? "打开本地已下载的 EC 名单（秒开）" : "打开最新的 EC 名单 PDF")
                        }
                        Button { Task { await store.teamsRefresh() } } label: {
                            SpinIcon(size: 11, spinning: store.teams?.fetching == true)
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .help("重新读一次名单")
                    }

                    // 一句话结论：要不要去，一眼看到
                    Text(headline)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(active ? tint.color(scheme, lift: 0.04)
                                                : Theme.ink(scheme))
                        .contentTransition(.opacity)

                    if active {
                        Text("这条已经作为待办排在 Teams 学习待办的第一条，"
                             + "\(info.date ?? "今天") 14:00 之后自动消失。")
                            .font(Typo.micro)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    // 名单：搜索时列出命中的同学（跨班），否则列我这个班的全员
                    if !q.isEmpty {
                        if ecStudentHits.isEmpty {
                            Text("名单里没有匹配「\(search.trimmingCharacters(in: .whitespaces))」的同学")
                                .font(Typo.micro).foregroundStyle(.tertiary)
                        } else {
                            VStack(alignment: .leading, spacing: env.space(6)) {
                                Text("名单命中 \(ecStudentHits.count) 人").font(Typo.micro).foregroundStyle(.tertiary)
                                rosterChips(ecStudentHits, tint: tint,
                                            highlight: info.student ?? "", info: info)
                            }
                        }
                    } else if !students.isEmpty {
                        VStack(alignment: .leading, spacing: env.space(6)) {
                            Text("\(klass.isEmpty ? "" : klass + " 班 · ")\(students.count) 人"
                                 + (info.file.map { " · 依据 \($0)" } ?? ""))
                                .font(Typo.micro).foregroundStyle(.tertiary)
                            rosterChips(students, tint: tint,
                                        highlight: info.student ?? "", info: info)
                        }
                    } else if let note = info.note, !note.isEmpty {
                        Text(note).font(Typo.micro).foregroundStyle(.tertiary)
                    }
                }
            }
            .appearIn(0)
        }
    }

    private func shouldShowEC(_ info: TeamsEC) -> Bool {
        // ★★ 只要后端手里有名单，这一块就必须出现 ★★
        // 这里原来第一句是 `if info.ok == false { return false }` ——
        // 于是「PDF 解析组件缺失」这种**局部**故障会把整个 English Corner
        // 板块吞掉（ok=false → 整块不渲染）。用户看到的是「EC 被删了」，
        // 而实际上代码一行没少、名单数据也一直躺在磁盘上。
        // EC 是当天 13:00 前要动身的事，宁可显示「暂时读不到」也不能凭空消失。
        if info.hasRoster == true { return true }
        // 没名单但这一轮确实问过（status = error/none/…）→ 也要说一句，
        // 否则用户不知道是没有 EC、还是没查成功。
        if info.ok == false { return true }
        if (info.status ?? "none") != "none" { return true }
        return info.hasRoster == true
    }

    /// 名单链接：**本地优先**。
    /// 用户要求「提前预下载 EC 名单表单储存起来，做到大小看板都是随点随开」——
    /// 本地已经有那份 PDF 就直接开本地文件（Preview 秒开），
    /// 没有才回落到 SharePoint 链接，并按设置里的跳转方式走。
    private func ecRosterURL(_ info: TeamsEC) -> URL? { ECRoster.url(info) }

    private func openRoster(_ info: TeamsEC) { ECRoster.open(info, settings: settings) }

    /// 本地是否已备好名单
    private func rosterIsLocal(_ info: TeamsEC) -> Bool { ECRoster.isLocal(info) }

    private func klassOf(_ name: String, _ info: TeamsEC) -> String {
        if (info.students ?? []).contains(name) { return info.klass ?? "" }
        for (k, v) in info.otherGroups ?? [:] where v.contains(name) { return k }
        return ""
    }

    /// 人名小胶囊。命中搜索词的人、以及我自己，都会高亮。
    private func rosterChips(_ names: [String], tint: RGB,
                             highlight: String, info: TeamsEC) -> some View {
        let cols = [GridItem(.adaptive(minimum: 104, maximum: 190), spacing: env.space(6))]
        return LazyVGrid(columns: cols, alignment: .leading, spacing: env.space(6)) {
            ForEach(Array(names.enumerated()), id: \.offset) { _, name in
                let me = !highlight.isEmpty && Search.norm(name) == Search.norm(highlight)
                let hit = !q.isEmpty && Search.hit(q, [name])
                let kl = klassOf(name, info)
                HStack(spacing: 5) {
                    if me {
                        Image(systemName: "person.fill.checkmark")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(tint.color(scheme, lift: 0.06))
                    }
                    Text(name)
                        .font(.system(size: 11.5, weight: me ? .bold : .medium))
                        .foregroundStyle(me ? tint.color(scheme, lift: 0.04) : Theme.ink2(scheme))
                        .lineLimit(1)
                    if !kl.isEmpty {
                        Text(kl).font(.system(size: 9.5)).foregroundStyle(.tertiary).lineLimit(1)
                    }
                }
                .padding(.horizontal, env.space(8))
                .padding(.vertical, env.space(4))
                .frame(maxWidth: .infinity, alignment: .leading)
                .background {
                    RoundedRectangle(cornerRadius: env.radius(6), style: .continuous)
                        .fill(hit ? tint.color(scheme).opacity(0.16)
                                  : Color.primary.opacity(scheme == .dark ? 0.07 : 0.045))
                }
                .overlay {
                    if me {
                        RoundedRectangle(cornerRadius: env.radius(6), style: .continuous)
                            .strokeBorder(tint.color(scheme).opacity(0.45), lineWidth: 1)
                    }
                }
            }
        }
    }

    /* ---------------- 概览 ---------------- */

    private var overview: some View {
        let s = store.teamsSection?.stats
        let list = tasks
        let overdue = list.filter { if let d = $0.due { return d < Date() }; return false }.count
        let today = list.filter { if let d = $0.due { return Calendar.current.isDateInToday(d) && d >= Date() }; return false }.count
        let fromMail = list.filter { $0.source == .mail || $0.source == .chat }.count

        return GlassCard(env: env, radius: Radius.lg, padding: env.space(22)) {
            VStack(alignment: .leading, spacing: env.space(15)) {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text("Teams 学习待办").font(Typo.title).foregroundStyle(Theme.ink(scheme))
                    if let acct = store.teams?.account, !acct.isEmpty {
                        Pill(env: env, text: acct.split(separator: "@").first.map(String.init) ?? acct,
                             color: settings.accent, icon: Icons.user)
                    }
                    // 时效性：让人一眼知道这批数据是几分钟前的
                    if let asOf = store.teamsSection?.asOf {
                        Text("更新于 " + relTime(Date(timeIntervalSince1970: asOf / 1000)))
                            .font(Typo.micro)
                            .foregroundStyle(.tertiary)
                    }
                    Spacer(minLength: 0)
                    Button {
                        Task { await store.teamsRefresh() }
                    } label: {
                        SpinIcon(size: 11.5, spinning: store.teams?.fetching == true)
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("立即刷新")
                }

                HStack(spacing: env.space(11)) {
                    tile("待处理", "\(q.isEmpty ? (s?.total ?? list.count) : list.count)",
                         q.isEmpty ? "全部学习待办" : "匹配搜索的学习待办",
                         settings.accent, Icons.todo)
                    tile("已逾期", "\(overdue)", overdue > 0 ? "需要马上处理" : "没有欠账",
                         Theme.redDefault, "exclamationmark.circle.fill")
                    tile("今天到期", "\(today)", today > 0 ? "今天要交" : "今天清空",
                         Theme.amberDefault, Icons.clock)
                    tile("自动提取", "\(fromMail)", "来自邮件与聊天",
                         Theme.greenDefault, Icons.bolt)
                }
            }
        }
        .appearIn(0)
    }

    private func tile(_ title: String, _ value: String, _ sub: String,
                      _ color: RGB, _ icon: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 5) {
                Image(systemName: icon).font(.system(size: 9.5, weight: .bold))
                    .foregroundStyle(color.color(scheme, lift: 0.16))
                Text(title).font(.system(size: 10.5, weight: .medium)).foregroundStyle(.secondary)
            }
            Text(value)
                .font(.system(size: 20, weight: .bold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(Theme.ink(scheme))
                .contentTransition(.numericText())
            Text(sub).font(.system(size: 10)).foregroundStyle(.tertiary)
        }
        .padding(.horizontal, env.space(13))
        .padding(.vertical, env.space(10))
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: env.radius(Radius.sm), style: .continuous)
                .fill(Color.primary.opacity(scheme == .dark ? 0.07 : 0.045))
        }
    }

    /* ---------------- 日程（今天 + 本周） ---------------- */

    @ViewBuilder
    private var agenda: some View {
        let evs = events
        if !evs.isEmpty {
            let today = evs.filter { $0.isToday }
            let next = evs.filter { !$0.isToday }.prefix(6)
            let searching = !q.isEmpty

            GlassCard(env: env, radius: Radius.lg, padding: env.space(20)) {
                VStack(alignment: .leading, spacing: env.space(13)) {
                    head(searching ? "日程（匹配）" : "日程",
                         "\(evs.count) 场", Icons.classes)

                    if searching {
                        // 搜索时不再分「今天 / 接下来」，直接按时间顺序给结果
                        VStack(alignment: .leading, spacing: env.space(7)) {
                            ForEach(Array(evs.prefix(12))) { ev in
                                eventRow(ev, isToday: ev.isToday)
                            }
                        }
                    } else {
                        if !today.isEmpty {
                            VStack(alignment: .leading, spacing: env.space(7)) {
                                Text("今天").font(Typo.micro).foregroundStyle(.tertiary)
                                ForEach(today) { ev in eventRow(ev, isToday: true) }
                            }
                        }
                        if !next.isEmpty {
                            VStack(alignment: .leading, spacing: env.space(7)) {
                                Text("接下来").font(Typo.micro).foregroundStyle(.tertiary)
                                ForEach(Array(next)) { ev in eventRow(ev, isToday: false) }
                            }
                        }
                    }
                }
            }
            .appearIn(1)
        }
    }

    private func eventRow(_ ev: TeamsEventVM, isToday: Bool) -> some View {
        HStack(spacing: env.space(11)) {
            Text(fmtTime(ev.start))
                .font(Typo.num(12.5, .bold))
                .foregroundStyle(isToday ? settings.accent.color(scheme, lift: 0.10) : .secondary)
                .frame(width: 46, alignment: .leading)

            RoundedRectangle(cornerRadius: 2)
                .fill(isToday ? settings.accent.color(scheme, lift: 0.06) : Color.secondary.opacity(0.3))
                .frame(width: 3, height: 26)

            VStack(alignment: .leading, spacing: 2) {
                Text(ev.title).font(Typo.callout).foregroundStyle(Theme.ink(scheme))
                    .lineLimit(1)
                HStack(spacing: 8) {
                    if !ev.location.isEmpty {
                        Label(ev.location, systemImage: Icons.room)
                            .font(Typo.micro).foregroundStyle(.tertiary).lineLimit(1)
                    }
                    if !ev.organizer.isEmpty {
                        Label(ev.organizer, systemImage: Icons.teacher)
                            .font(Typo.micro).foregroundStyle(.tertiary).lineLimit(1)
                    }
                }
            }
            Spacer(minLength: 0)
            if !isToday {
                Text(fmtDayShort(ev.start)).font(Typo.micro).foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, env.space(11))
        .padding(.vertical, env.space(7))
        .background {
            RoundedRectangle(cornerRadius: env.radius(Radius.sm), style: .continuous)
                .fill(Color.primary.opacity(scheme == .dark ? 0.05 : 0.035))
        }
        .hoverLift(2)
    }

    /* ---------------- 任务列表 ---------------- */

    @ViewBuilder
    private var taskList: some View {
        let sorted: [TeamsTaskVM] = {
            let base = tasks.sorted { a, b in
                if a.pinned != b.pinned { return a.pinned }   // EC 那条永远第一
                // 按时间从最新到最旧（用户要求）：任务用创建时间、邮件/聊天用
                // 收到时间，统一存在 created 里；缺了就退回截止时间，再缺沉底。
                let ta = a.created ?? a.due ?? .distantPast
                let tb = b.created ?? b.due ?? .distantPast
                if ta != tb { return ta > tb }
                return a.title < b.title
            }
            guard !q.isEmpty else { return base }
            // 搜索时按相关度排：标题里命中的排最前
            return base.sorted {
                Search.score(q, title: $0.title, fields: [$0.course, $0.from, $0.detail])
                    > Search.score(q, title: $1.title, fields: [$1.course, $1.from, $1.detail])
            }
        }()
        let filtered: [TeamsTaskVM] = {
            switch filter {
            case "urgent": return sorted.filter { t in
                guard let d = t.due else { return false }
                return d < Date() || Calendar.current.isDateInToday(d)
            }
            case "auto":   return sorted.filter { $0.source == .mail || $0.source == .chat }
            default:       return sorted
            }
        }()
        // 搜索中不折叠（用户找东西时不想还被截断）
        let collapsedLimit = 8
        let foldable = q.isEmpty && filtered.count > collapsedLimit
        let items = (foldable && !showAllTasks) ? Array(filtered.prefix(collapsedLimit)) : filtered

        GlassCard(env: env, radius: Radius.lg, padding: env.space(20)) {
            VStack(alignment: .leading, spacing: env.space(13)) {
                HStack(spacing: env.space(10)) {
                    head(q.isEmpty ? "学习任务" : "学习任务 · 匹配",
                         "\(filtered.count) 条", Icons.todo)
                    Spacer(minLength: 0)
                    SegmentedTabs(env: env, items: [
                        SegItem(id: "all", label: "全部"),
                        SegItem(id: "urgent", label: "紧急"),
                        SegItem(id: "auto", label: "自动提取"),
                    ], selection: $filter)
                }

                if items.isEmpty {
                    EmptyState(env: env,
                               icon: q.isEmpty ? Icons.todo : Icons.search,
                               title: q.isEmpty ? "这个筛选下没有任务" : "没有匹配「\(search.trimmingCharacters(in: .whitespaces))」的任务",
                               detail: q.isEmpty ? "换个筛选看看，或者点右上角刷新"
                                                 : "换个关键词，或清空搜索看全部")
                } else {
                    VStack(spacing: env.space(8)) {
                        ForEach(Array(items.enumerated()), id: \.element.id) { idx, t in
                            taskRow(t).appearIn(idx)
                        }
                    }

                    // 装不下就折叠：默认 8 条，需要时一键铺开
                    if foldable {
                        Button {
                            withAnimation(Motion.reveal) { showAllTasks.toggle() }
                        } label: {
                            HStack(spacing: 6) {
                                Image(systemName: "chevron.down.circle.fill")
                                    .font(.system(size: 11, weight: .bold))
                                    .rotationEffect(.degrees(showAllTasks ? 180 : 0))
                                Text(showAllTasks
                                     ? "收起，只看前 \(collapsedLimit) 条"
                                     : "展开其余 \(filtered.count - collapsedLimit) 条")
                                    .font(.system(size: 11.5, weight: .semibold))
                            }
                            .foregroundStyle(settings.accent.color(scheme, lift: 0.08))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, env.space(7))
                            .background {
                                RoundedRectangle(cornerRadius: env.radius(Radius.sm), style: .continuous)
                                    .fill(settings.accent.color(scheme).opacity(0.09))
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .appearIn(2)
    }

    /// 一条任务。
    /// 交互按用户的要求拆开：
    ///   · 点「最右边的那个小按钮」→ 直接跳到原网页
    ///   · 点「其余大部分区域」→ 弹出预览（正文、小文件、表单）
    private func taskRow(_ t: TeamsTaskVM) -> some View {
        let (left, color, over) = dueInfo(t.due)
        let isEC = t.source == .ec
        // EC 那条一定要红：它是当天 14:00 前必须动身的事，不能和一般待办同样颜色
        let tint: RGB = isEC ? Theme.redDefault : color
        let urgentText = isEC ? "今天要去" : left

        return HStack(spacing: env.space(12)) {
            // 左侧色条：一眼看出紧急度
            RoundedRectangle(cornerRadius: 2)
                .fill(tint.color(scheme, lift: 0.06))
                .frame(width: 3, height: 34)

            Button {
                // 走全局单例而不是本页 @State：预览浮层现在挂在窗口根部，
                // 由 TaskPreviewHost 画出来（理由见 TeamsSection 末尾那段注释）。
                TaskPreviewCenter.shared.open(t)
            } label: {
                HStack(spacing: env.space(12)) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(t.title)
                            .font(Typo.callout)
                            .fontWeight(isEC ? .semibold : .medium)
                            .foregroundStyle(isEC ? Theme.redDefault.color(scheme, lift: 0.02)
                                                  : Theme.ink(scheme))
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                        HStack(spacing: 7) {
                            if isEC {
                                Pill(env: env, text: "English Corner", color: Theme.redDefault,
                                     icon: "bubble.left.and.text.bubble.right.fill", bold: true)
                            } else {
                                Pill(env: env, text: t.source.label, color: sourceColor(t.source),
                                     icon: t.source.icon)
                            }
                            if !t.course.isEmpty {
                                Pill(env: env, text: t.course, color: settings.accent, filled: false)
                            }
                            if t.importance == "high" && !isEC {
                                Pill(env: env, text: "重要", color: Theme.redDefault, icon: Icons.star)
                            }
                            if !t.place.isEmpty {
                                Label(t.place, systemImage: Icons.room)
                                    .font(Typo.micro).foregroundStyle(.tertiary).lineLimit(1)
                            }
                            if !t.from.isEmpty {
                                Text(t.from).font(Typo.micro).foregroundStyle(.tertiary).lineLimit(1)
                            }
                        }
                    }

                    Spacer(minLength: 0)

                    VStack(alignment: .trailing, spacing: 3) {
                        Text(urgentText)
                            .font(Typo.num(12.5, .bold))
                            .foregroundStyle(over || isEC ? Theme.redDefault.color(scheme, lift: 0.06)
                                                          : Theme.ink2(scheme))
                        // 自动提取的标出置信度，用户才知道这条是推断出来的
                        if t.source == .mail || t.source == .chat {
                            Text("置信 \(Int(t.confidence * 100))%")
                                .font(Typo.micro)
                                .foregroundStyle(t.confidence >= 0.75
                                                 ? Theme.greenDefault.color(scheme, lift: 0.06)
                                                 : Theme.ink3(scheme))
                        } else if t.hasPreview {
                            Text("点开看详情")
                                .font(Typo.micro)
                                .foregroundStyle(.quaternary)
                        }
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("点一下看详情与附件")

            // 最右：小按钮，打开原网页。
            // ★ 以前这里是 NSWorkspace.shared.open(u) ★
            // 它绕过了设置里的「一律使用内置浏览器」—— 开关打开后这些按钮
            // 照样弹系统浏览器，用户看到的就是「这个设置不起作用」。
            // 规矩：凡是网页链接，一律走 LinkOpen，由设置决定去哪儿。
            if let u = t.url {
                Button { LinkOpen.go(u, source: isEC ? "ec" : "teams", settings: settings) } label: {
                    Image(systemName: Icons.open)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(isEC ? Theme.redDefault.color(scheme, lift: 0.06)
                                              : Color.secondary)
                        .frame(width: 24, height: 24)
                        .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                        .background {
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(Color.primary.opacity(0.055))
                        }
                }
                .buttonStyle(.plain)
                .help("打开原网页（按设置里的跳转方式）")
            }
        }
        .padding(.horizontal, env.space(12))
        .padding(.vertical, env.space(9))
        .background {
            RoundedRectangle(cornerRadius: env.radius(Radius.sm), style: .continuous)
                .fill(isEC
                      ? Theme.redDefault.color(scheme).opacity(scheme == .dark ? 0.16 : 0.085)
                      : Color.primary.opacity(scheme == .dark ? 0.055 : 0.035))
        }
        .overlay {
            if isEC {
                RoundedRectangle(cornerRadius: env.radius(Radius.sm), style: .continuous)
                    .strokeBorder(Theme.redDefault.color(scheme).opacity(0.35), lineWidth: 1)
            }
        }
        .hoverLift(2)
    }

    private func sourceColor(_ s: TeamsSource) -> RGB {
        switch s {
        case .todo:    return settings.accent
        case .planner: return RGB("#5e5ce6")
        case .mail:    return Theme.blueDefault
        case .chat:    return Theme.greenDefault
        case .ec:      return Theme.redDefault
        }
    }

    /* ---------------- 邮件 ---------------- */

    @ViewBuilder
    private var mailBlock: some View {
        let list = mails
        if !list.isEmpty {
            let unread = list.filter { !$0.isRead }
            let cap = q.isEmpty ? 30 : 60
            let shown = showMail ? Array(list.prefix(cap)) : Array(list.prefix(6))

            GlassCard(env: env, radius: Radius.lg, padding: env.space(20)) {
                VStack(alignment: .leading, spacing: env.space(13)) {
                    HStack(spacing: env.space(10)) {
                        head(q.isEmpty ? "近期邮件" : "近期邮件 · 匹配",
                             "\(unread.count) 封未读", "envelope.fill")
                        Spacer(minLength: 0)
                        if list.count > 6 {
                            Button { withAnimation(Motion.reveal) { showMail.toggle() } } label: {
                                Text(showMail ? "收起" : "展开全部 \(list.count)")
                                    .font(Typo.micro)
                                    .foregroundStyle(settings.accent.color(scheme, lift: 0.08))
                                    .contentTransition(.interpolate)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    VStack(spacing: env.space(6)) {
                        ForEach(shown) { m in mailRow(m) }
                    }
                }
            }
            .appearIn(3)
        }
    }

    private func mailRow(_ m: TeamsMailVM) -> some View {
        HStack(spacing: env.space(11)) {
            Circle()
                .fill(m.isRead ? Color.clear : settings.accent.color(scheme, lift: 0.06))
                .frame(width: 6, height: 6)

            VStack(alignment: .leading, spacing: 2) {
                Text(m.subject)
                    .font(Typo.sub)
                    .fontWeight(m.isRead ? .regular : .semibold)
                    .foregroundStyle(Theme.ink(scheme))
                    .lineLimit(1)
                HStack(spacing: 7) {
                    if !m.from.isEmpty {
                        Text(m.from).font(Typo.micro).foregroundStyle(.secondary).lineLimit(1)
                    }
                    if m.important {
                        Pill(env: env, text: "重要", color: Theme.redDefault, icon: Icons.star)
                    }
                    if m.hasAttachments {
                        Image(systemName: "paperclip").font(.system(size: 9.5))
                            .foregroundStyle(.tertiary)
                    }
                }
            }
            Spacer(minLength: 0)
            if let r = m.received {
                Text(relTime(r)).font(Typo.micro).foregroundStyle(.tertiary)
            }
            if let u = m.url {
                Button { LinkOpen.go(u, source: "mail", settings: settings) } label: {
                    Image(systemName: Icons.open).font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .help("打开邮件（按设置里的跳转方式）")
            }
        }
        .padding(.horizontal, env.space(11))
        .padding(.vertical, env.space(7))
        .background {
            RoundedRectangle(cornerRadius: env.radius(Radius.sm), style: .continuous)
                .fill(Color.primary.opacity(scheme == .dark ? 0.05 : 0.03))
        }
        .hoverLift(2)
    }

    /* ---------------- 小工具 ---------------- */

    private func head(_ title: String, _ count: String, _ icon: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(settings.accent.color(scheme, lift: 0.10))
            Text(title).font(Typo.headline).foregroundStyle(Theme.ink(scheme))
            Text(count).font(Typo.micro).foregroundStyle(.tertiary)
        }
    }

    private func dueInfo(_ d: Date?) -> (String, RGB, Bool) {
        guard let d else { return ("无截止", Theme.ink3_RGB, false) }
        let now = Date()
        if d < now { return ("已逾期", Theme.redDefault, true) }
        let cal = Calendar.current
        if cal.isDateInToday(d) {
            let mins = Int(d.timeIntervalSince(now) / 60)
            return (mins < 60 ? "\(mins) 分钟后" : fmtTime(d) + " 截止", Theme.redDefault, false)
        }
        if cal.isDateInTomorrow(d) { return ("明天 " + fmtTime(d), Theme.amberDefault, false) }
        let days = cal.dateComponents([.day], from: cal.startOfDay(for: now),
                                      to: cal.startOfDay(for: d)).day ?? 0
        if days < 7 { return ("\(days) 天后", Theme.amberDefault, false) }
        return (fmtDayShort(d), Theme.ink3_RGB, false)
    }

    private func fmtTime(_ d: Date) -> String {
        let c = Calendar.current.dateComponents([.hour, .minute], from: d)
        return String(format: "%02d:%02d", c.hour ?? 0, c.minute ?? 0)
    }

    private func fmtDayShort(_ d: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.dateFormat = "M月d日"
        return f.string(from: d)
    }

    private func relTime(_ d: Date) -> String {
        let s = Date().timeIntervalSince(d)
        if s < 3600 { return "\(max(1, Int(s / 60))) 分钟前" }
        if s < 86400 { return "\(Int(s / 3600)) 小时前" }
        let days = Int(s / 86400)
        if days < 7 { return "\(days) 天前" }
        return fmtDayShort(d)
    }
}

/* ======================================================================
   任务预览面板
   ----------------------------------------------------------------------
   点任务主体弹出的窗口，要在一个地方看全：
     · 消息正文（可选中复制）
     · 体积不大的附件（点一下直接打开）
     · 内嵌的表单 —— English Corner 那种必须填的当天表单一定要在这里出现
     · 原网页入口
   右侧那个小按钮仍然保留「一键跳原网页」，两条路互不干扰。
   ====================================================================== */

/* ======================================================================
   预览单的中枢 + 挂载点
   ----------------------------------------------------------------------
   和 TaskDetailCenter / TaskDetailHost 同一套约定：页面里只调 open()，
   真正的绘制由挂在**窗口根部 ZStack** 上的 TaskPreviewHost 负责。
   为什么不留在 TeamsSection 内部：那里的 `.overlay` 是挂在滚动内容上的，
   居中会居到「整篇长文的中点」，任务一多小窗就掉到视口外（用户截图的 bug）。
   ====================================================================== */

@MainActor
final class TaskPreviewCenter: ObservableObject {
    static let shared = TaskPreviewCenter()
    @Published var task: TeamsTaskVM?

    func open(_ t: TeamsTaskVM) { withAnimation(Motion.pop) { task = t } }
    func close() { withAnimation(Motion.pop) { task = nil } }
}

/// 挂在窗口根部的预览单宿主。ZStack 里最后一个画 → 永远在内容之上。
struct TaskPreviewHost: View {
    @ObservedObject private var center = TaskPreviewCenter.shared
    @EnvironmentObject private var settings: BoardSettings
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        ZStack {
            if let t = center.task {
                TaskPreviewOverlay(task: t,
                                   env: Env(scheme: scheme, settings: settings)) {
                    center.close()
                }
                .transition(.opacity)
            }
        }
    }
}

struct TaskPreviewOverlay: View {
    let task: TeamsTaskVM
    let env: Env
    /// 关掉浮层（由宿主把 TaskPreviewCenter.shared.task 置回 nil）
    var onClose: () -> Void

    @Environment(\.colorScheme) private var scheme
    /// 进场动画：淡入 + 上浮（离屏初值直接给到位，见 MoonFestNotice 里的说明）
    @State private var shown = PreviewFlags.offscreen

    private var p: TeamsPreview? { task.preview }
    private var body_: String {
        let t = (p?.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? task.detail : t
    }
    private var atts: [TeamsAttachment] { p?.attachments ?? [] }
    private var form: TeamsForm? {
        guard let f = p?.form, (f.url ?? "").isEmpty == false else { return nil }
        return f
    }
    private var web: URL? {
        if let w = p?.webUrl, !w.isEmpty, let u = URL(string: w) { return u }
        if let w = task.url, !w.absoluteString.isEmpty { return w }
        return nil
    }
    private var isEC: Bool { task.source == .ec }
    private var tint: RGB { isEC ? Theme.redDefault : BoardSettings.shared.accent }

    var body: some View {
        // 外壳统一走 FloatingWindow：相对视口居中、顶部可拖、背景径向渐暗。
        FloatingWindow(dim: scheme == .dark ? 0.46 : 0.30,
                       panelRadius: 410,
                       inset: EdgeInsets(top: 28, leading: 28, bottom: 28, trailing: 28),
                       onTapOutside: close) {
            panel
                .scaleEffect(shown ? 1 : 0.96)
                .opacity(shown ? 1 : 0)
                .offset(y: shown ? 0 : 18)
        }
        .onAppear { withAnimation(Motion.pop) { shown = true } }
        .onExitCommand { close() }        // Esc 关闭（macOS 惯例）
    }

    private func close() {
        withAnimation(Motion.pop) { shown = false }
        // 等退场动画播完再摘掉节点，不然看不到动画
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.24) { onClose() }
    }

    private var panel: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().overlay(Theme.lineSoft(scheme))
            ScrollView {
                VStack(alignment: .leading, spacing: env.space(18)) {
                    meta
                    if !body_.isEmpty { bodyBlock }
                    if !atts.isEmpty { attBlock }
                    if let f = form { formBlock(f) }
                    sigBlock
                }
                .padding(env.space(24))
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            Divider().overlay(Theme.lineSoft(scheme))
            footer
        }
        .frame(width: 580)
        // 高度上限扣掉描边宽度，不然总高超出 580
        .frame(maxHeight: 566)
        // 弹窗外壳：外圈原生液态玻璃描边（零填色、纯折射），内圈毛玻璃主体
        .liquidGlassPanel(env, corner: Radius.lg)
    }

    /* ---------------- 顶部 ---------------- */

    private var header: some View {
        HStack(alignment: .top, spacing: env.space(13)) {
            ZStack {
                RoundedRectangle(cornerRadius: env.radius(9), style: .continuous)
                    .fill(tint.color(scheme, lift: 0.10).opacity(0.18))
                    .frame(width: 34, height: 34)
                Image(systemName: isEC ? "bubble.left.and.text.bubble.right.fill" : task.source.icon)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(tint.color(scheme, lift: 0.12))
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(task.title)
                    .font(.system(size: 16.5, weight: .semibold))
                    .foregroundStyle(isEC ? Theme.redDefault.color(scheme, lift: 0.02)
                                          : Theme.ink(scheme))
                    .fixedSize(horizontal: false, vertical: true)
                Text("详细内容")
                    .font(Typo.micro)
                    .foregroundStyle(.tertiary)
            }
            Spacer(minLength: 0)
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
        .padding(.horizontal, env.space(24))
        .padding(.vertical, env.space(18))
    }

    /* ---------------- 元信息 ---------------- */

    private var meta: some View {
        let (left, color, _) = dueOf(task.due)
        return VStack(alignment: .leading, spacing: env.space(9)) {
            HStack(spacing: env.space(8)) {
                Pill(env: env, text: task.source.label, color: sourceTint, icon: task.source.icon)
                if !task.course.isEmpty {
                    Pill(env: env, text: task.course, color: Theme.accentDefault, filled: false)
                }
                Pill(env: env, text: left, color: color, icon: Icons.clock, bold: task.pinned)
                Spacer(minLength: 0)
            }
            if !task.from.isEmpty || !task.place.isEmpty {
                HStack(spacing: env.space(14)) {
                    if !task.from.isEmpty {
                        Label(task.from, systemImage: Icons.teacher)
                            .font(Typo.micro).foregroundStyle(.secondary).lineLimit(2)
                    }
                    if !task.place.isEmpty {
                        Label(task.place, systemImage: Icons.room)
                            .font(Typo.micro).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                }
            }
        }
    }

    private var sourceTint: RGB {
        switch task.source {
        case .todo:    return Theme.accentDefault
        case .planner: return RGB("#5e5ce6")
        case .mail:    return Theme.blueDefault
        case .chat:    return Theme.greenDefault
        case .ec:      return Theme.redDefault
        }
    }

    /* ---------------- 正文 ---------------- */

    private var bodyBlock: some View {
        VStack(alignment: .leading, spacing: env.space(8)) {
            blockTitle("正文", "text.alignleft")
            Text(body_)
                .font(.system(size: 13))
                .foregroundStyle(Theme.ink2(scheme))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(env.space(14))
                .background {
                    RoundedRectangle(cornerRadius: env.radius(Radius.md), style: .continuous)
                        .fill(Color.primary.opacity(scheme == .dark ? 0.06 : 0.04))
                }
        }
    }

    /* ---------------- 附件 ---------------- */

    private var attBlock: some View {
        VStack(alignment: .leading, spacing: env.space(8)) {
            blockTitle("附件 \(atts.count) 个", "paperclip")
            VStack(spacing: env.space(6)) {
                ForEach(atts) { a in
                    Button { openAttachment(a) } label: {
                        HStack(spacing: env.space(11)) {
                            Image(systemName: fileIcon(a.kind))
                                .font(.system(size: 13))
                                .foregroundStyle(tint.color(scheme, lift: 0.08))
                                .frame(width: 20)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(a.name ?? "附件")
                                    .font(Typo.sub)
                                    .foregroundStyle(Theme.ink(scheme))
                                    .lineLimit(1)
                                Text(a.local == true ? "已下载到本机" : "在浏览器中打开")
                                    .font(Typo.micro).foregroundStyle(.tertiary)
                            }
                            Spacer(minLength: 0)
                            Image(systemName: Icons.open)
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(.secondary)
                        }
                        .padding(.horizontal, env.space(12))
                        .padding(.vertical, env.space(9))
                        .contentShape(Rectangle())
                        .background {
                            RoundedRectangle(cornerRadius: env.radius(Radius.sm), style: .continuous)
                                .fill(Color.primary.opacity(scheme == .dark ? 0.055 : 0.035))
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    /* ---------------- 表单（EC 那类必须填的） ---------------- */

    private func formBlock(_ f: TeamsForm) -> some View {
        VStack(alignment: .leading, spacing: env.space(8)) {
            blockTitle("需要填写的表单", "list.bullet.rectangle.portrait")
            HStack(spacing: env.space(12)) {
                Image(systemName: "doc.text.fill")
                    .font(.system(size: 16))
                    .foregroundStyle(.white)
                    .frame(width: 34, height: 34)
                    .background {
                        RoundedRectangle(cornerRadius: env.radius(9), style: .continuous)
                            .fill(Theme.redDefault.color(scheme, lift: 0.06))
                    }
                VStack(alignment: .leading, spacing: 2) {
                    Text(f.title ?? "表单").font(Typo.sub)
                        .foregroundStyle(Theme.ink(scheme)).lineLimit(2)
                    Text("点右侧按钮填写").font(Typo.micro).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                Button {
                    LinkOpen.go(f.url, source: "teams", settings: env.settings)
                } label: {
                    Text("打开表单")
                        .font(.system(size: 12, weight: .semibold))
                        .padding(.horizontal, env.space(13))
                        .padding(.vertical, env.space(7))
                        .background { Capsule().fill(Theme.redDefault.color(scheme, lift: 0.06)) }
                        .foregroundStyle(.white)
                }
                .buttonStyle(.plain)
            }
            .padding(env.space(13))
            .background {
                RoundedRectangle(cornerRadius: env.radius(Radius.md), style: .continuous)
                    .fill(Theme.redDefault.color(scheme).opacity(scheme == .dark ? 0.16 : 0.085))
            }
            .overlay {
                RoundedRectangle(cornerRadius: env.radius(Radius.md), style: .continuous)
                    .strokeBorder(Theme.redDefault.color(scheme).opacity(0.30), lineWidth: 1)
            }
        }
    }

    /* ---------------- 依据 ---------------- */

    @ViewBuilder
    private var sigBlock: some View {
        if !task.signals.isEmpty {
            VStack(alignment: .leading, spacing: env.space(8)) {
                blockTitle("这条是怎么来的", "checkmark.seal")
                HStack(spacing: env.space(7)) {
                    ForEach(task.signals, id: \.self) { s in
                        Pill(env: env, text: s, color: Theme.accentDefault, filled: false)
                    }
                    Spacer(minLength: 0)
                }
            }
        }
    }

    private func blockTitle(_ t: String, _ icon: String) -> some View {
        HStack(spacing: 7) {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(tint.color(scheme, lift: 0.08))
            Text(t).font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
        }
    }

    /* ---------------- 底部 ---------------- */

    private var footer: some View {
        HStack(spacing: env.space(10)) {
            if let web {
                Button { LinkOpen.go(web, source: "teams", settings: env.settings) } label: {
                    HStack(spacing: 6) {
                        Image(systemName: Icons.open).font(.system(size: 11, weight: .bold))
                        Text("打开原网页").font(.system(size: 12.5, weight: .semibold))
                    }
                    .padding(.horizontal, env.space(15))
                    .padding(.vertical, env.space(8))
                    .background { Capsule().fill(Theme.accentDefault.color(scheme, lift: 0.06)) }
                    .foregroundStyle(.white)
                }
                .buttonStyle(.plain)
            }

            if !body_.isEmpty {
                Button {
                    let pb = NSPasteboard.general
                    pb.clearContents()
                    pb.setString(body_, forType: .string)
                } label: {
                    Text("复制正文")
                        .font(.system(size: 12.5, weight: .semibold))
                        .padding(.horizontal, env.space(15))
                        .padding(.vertical, env.space(8))
                        .background {
                            Capsule().strokeBorder(Theme.ink2(scheme).opacity(0.22), lineWidth: 1)
                        }
                        .foregroundStyle(Theme.ink2(scheme))
                }
                .buttonStyle(.plain)
            }

            Spacer(minLength: 0)
            Button { close() } label: {
                Text("完成")
                    .font(.system(size: 12.5, weight: .semibold))
                    .padding(.horizontal, env.space(17))
                    .padding(.vertical, env.space(8))
                    .background { Capsule().fill(Color.primary.opacity(0.085)) }
                    .foregroundStyle(Theme.ink(scheme))
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, env.space(24))
        .padding(.vertical, env.space(16))
    }

    /* ---------------- 工具 ---------------- */

    private func openAttachment(_ a: TeamsAttachment) {
        if a.local == true, let u = a.url, !u.isEmpty {
            // 本地文件（已经下到磁盘的附件）直接用系统打开 —— 这不是网页链接，
            // 交给内置浏览窗反而打不开。
            if FileManager.default.fileExists(atPath: u) {
                NSWorkspace.shared.open(URL(fileURLWithPath: u))
                return
            }
        }
        let s = (a.webUrl?.isEmpty == false ? a.webUrl : a.url) ?? ""
        if !s.isEmpty { LinkOpen.go(s, source: "teams", settings: env.settings) }
    }

    private func fileIcon(_ kind: String?) -> String {
        switch (kind ?? "").lowercased() {
        case "pdf":            return "doc.richtext"
        case "doc", "docx":    return "doc.text"
        case "xls", "xlsx",
             "csv":            return "tablecells"
        case "ppt", "pptx":    return "rectangle.on.rectangle"
        case "img":            return "photo"
        case "zip":            return "archivebox"
        case "link":           return "link"
        default:               return "doc"
        }
    }

    private func dueOf(_ d: Date?) -> (String, RGB, Bool) {
        guard let d else { return ("无截止", Theme.ink3_RGB, false) }
        let now = Date()
        if d < now { return ("已逾期", Theme.redDefault, true) }
        let cal = Calendar.current
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.dateFormat = "M月d日 HH:mm"
        if cal.isDateInToday(d) { return ("今天 " + f.string(from: d).suffix(5), Theme.redDefault, false) }
        if cal.isDateInTomorrow(d) { return ("明天", Theme.amberDefault, false) }
        return (f.string(from: d), Theme.ink3_RGB, false)
    }
}
