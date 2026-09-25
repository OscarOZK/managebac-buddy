import SwiftUI
import AppKit
import UserNotifications

/* ======================================================================
   通知系统（用户要求：可自定义程度一定要高）

   能控制的维度：
     · 总开关
     · 待办：是否通知 / 只通知「紧急」档还是所有档 / 到期前多少小时提醒
     · 每日汇总：开关 + 时间
     · 来源：Teams 任务 / 邮件 / 日程 / 新成绩 / English Corner
     · EC 提前多少分钟提醒
     · 学科白名单（留空 = 全部）
     · 免打扰时段
     · 是否带声音
     · 通知上是否挂学科图标

   ======================================================================
   第 18 轮：通知刷屏事故的彻底整改
   ----------------------------------------------------------------------
   用户看到的现象：
     · 同一条消息弹两遍 —— 主看板和菜单栏面板是两个进程，各跑了一遍 evaluate；
     · 每次刷新都冒出一堆「很久以前」的成绩 —— 旧的去重是「6 小时内不重复」，
       时间一过同样的东西又播一遍；而且两个进程还互相覆盖 notify-state.json，
       去重记录经常整段丢失；
     · 一周前的成绩也被当成「新成绩」—— 根本没有「这条消息是不是旧闻」的判断。

   现在的规则（每条都很关键）：
     ① 一个 App：只有一个进程会发通知（另一份从根上没了）。
     ② 永久去重：同一个 key 见过一次就永远不再播（key 里带任务/作业的稳定 id，
        所以「新发生的事」天然是新 key）。
     ③ 旧闻门槛：每条消息都带一个「发生时间」，超过门槛一律只记账、不播报。
        新成绩 4 天 / Teams 任务 3 天 / 未读邮件 7 天。
     ④ 静默播种：第一次运行、或者状态文件丢了、或者 key 规则升级过 ——
        一律只把现状记下来，一条都不补播（否则历史账本会在瞬间全涌出来）。
     ⑤ 同轮合并：一轮里同一类超过 2 条，就合成一条汇总（「🏆 4 条新成绩」），
        不再一条一条轰炸。
     ⑥ 稳定 identifier：通知的 identifier 就是 key，
        万一重复投递，系统会替换那一条，而不是在列表里再堆一条。
     ⑦ 自动清理：投递出去超过 36 小时的通知会被摘掉，最多留 24 条。
     ⑧ 节流 + 只吃成品：evaluate 每 15 秒最多一次，且跳过
        updating/preparing 的半成品包（刚启动时的占位数据不该触发任何通知）。
   ====================================================================== */

/// 一条「值得播报的事」。所有字段都是拼好可直接用的，屏蔽掉各来源的数据差异。
private struct News {
    let key: String            // 稳定标识：同一件事永远同一个 key
    let kind: NotifyKind
    let title: String
    let body: String
    let subject: String        // 决定通知图标用哪一科的颜色/符号
    let url: URL?
    let source: String
    let eventAt: Date?         // 这件事「发生」的时间；nil = 跟未来有关，不用判旧闻
}

@MainActor
enum Notifier {

    private static var askedThisRun = false
    private static var lastEval = Date.distantPast

    /// 状态文件里的「规则版本」。key 的算法或门槛一改就 +1，
    /// 读盘时发现版本不同 → 静默播种一遍，绝不把历史账本补播出来。
    private static let schemaKey = "schema4"

    /* ---------------- 权限 ---------------- */

    static func sync(settings: BoardSettings) {
        guard settings.notifyEnabled else { return }
        guard !askedThisRun else { return }
        askedThisRun = true
        guard inBundle else { return }
        installDelegate()
        UNUserNotificationCenter.current()
            .requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
        // 一次性清账：把历史积压（几十条旧成绩/旧任务）从通知中心里清掉。
        if loadState()["cleaned:backlog"] == nil {
            UNUserNotificationCenter.current().removeAllDeliveredNotifications()
            mark("cleaned:backlog")
        }
    }

    /// 通知中心只在真正的 .app bundle 里可用。
    /// 裸可执行文件（离屏渲染自检 / 命令行工具 / 桥接助手）里调
    /// `UNUserNotificationCenter.current()` 会直接抛 ObjC 异常
    /// `bundleProxyForCurrentProcess is nil`，而且**无法用 do/catch 捕获**，
    /// 进程当场终止。所以所有调用点前面都必须先过这一关。
    private static var inBundle: Bool {
        Bundle.main.bundleIdentifier != nil && Bundle.main.bundleURL.pathExtension == "app"
    }

    /* ---------------- 前台也要弹出来 ----------------
       macOS 对**正处于前台**的 App，默认只把通知塞进通知中心，
       不弹横幅也不响声音。必须在 delegate 里显式要求 .banner/.list。

       UNUserNotificationCenter.delegate 是 weak 的，所以自己留一份强引用。 */

    private static var presenter: ForegroundPresenter?

    private static func installDelegate() {
        guard inBundle else { return }
        if presenter == nil { presenter = ForegroundPresenter() }
        UNUserNotificationCenter.current().delegate = presenter
    }

    private final class ForegroundPresenter: NSObject, UNUserNotificationCenterDelegate {
        func userNotificationCenter(_ center: UNUserNotificationCenter,
                                    willPresent notification: UNNotification,
                                    withCompletionHandler done:
                                        @escaping (UNNotificationPresentationOptions) -> Void) {
            done([.banner, .sound, .list])
        }

        /// 点击通知 → 打开对应原网站。
        /// 跳转方式和「看板里点卡片」共用同一套设置（系统浏览器 / 内置窗口 / 复制链接），
        /// 来源也走同一个映射（managebac / teams / mail / ec），所以用户改一处、两处一起变。
        func userNotificationCenter(_ center: UNUserNotificationCenter,
                                    didReceive response: UNNotificationResponse,
                                    withCompletionHandler done: @escaping () -> Void) {
            let info = response.notification.request.content.userInfo
            let raw = (info["url"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let source = (info["source"] as? String) ?? "managebac"
            if !raw.isEmpty, let u = URL(string: raw) {
                Task { @MainActor in
                    LinkOpen.go(u, source: source, settings: BoardSettings.shared)
                }
            }
            done()
        }
    }

    /// 跳到系统「通知」设置里**本 App 那一页** —— 用户被系统静音时能自己救回来。
    ///
    /// ★ 必须带 `?id=<bundle id>` ★
    /// 只写 `...Notifications-Settings.extension` 只会把「通知」这个总页面
    /// 打开，左侧还停在列表上，用户还得自己在一长串 App 里找「ManageBac 看板」——
    /// 而他要解决的本来就是「这个 App 的通知没开」，多这一趟纯属添堵。
    /// 带上 id 之后系统会直接定位到本 App 的那一页（macOS 13+ 支持）。
    static func openSystemSettings() {
        let bid = Bundle.main.bundleIdentifier ?? "com.mbboard.dashboard"
        // 带 ?id= 的两种 pane 名都试：新系统用 extension 式标识，老系统用
        // com.apple.preference.notifications —— 系统自带的「地图」App 就是后者
        // 加 ?id= 定位到自己的那一页的。带 id 的排前面，裸的总页只做兜底。
        for s in ["x-apple.systempreferences:com.apple.Notifications-Settings.extension?id=" + bid,
                  "x-apple.systempreferences:com.apple.preference.notifications?id=" + bid,
                  "x-apple.systempreferences:com.apple.Notifications-Settings.extension"] {
            if let u = URL(string: s), NSWorkspace.shared.open(u) { return }
        }
        if let u = URL(string: "x-apple.systempreferences:com.apple.preference.notifications") {
            NSWorkspace.shared.open(u)
        }
    }

    /// 跳到系统「专注模式」设置 —— 「收不到通知」的第二种可能就在那里。
    /// 用户被勿扰模式吃掉通知时，光看通知设置是看不出来的。
    static func openFocusSettings() {
        for s in ["x-apple.systempreferences:com.apple.Focus-Settings.extension",
                  "x-apple.systempreferences:com.apple.preference.focus",
                  "x-apple.systempreferences:com.apple.DoNotDisturb"] {
            if let u = URL(string: s), NSWorkspace.shared.open(u) { return }
        }
    }

    /// 手动清空通知中心里已投递的通知（设置页那个「清空已投递通知」按钮）。
    /// 自动清理也在跑：超过 36 小时的会被摘掉，最多留 24 条。
    static func clearDelivered() {
        guard inBundle else { return }
        UNUserNotificationCenter.current().removeAllDeliveredNotifications()
        Log.write("通知：已清空通知中心里已投递的通知")
    }

    /* ---------------- 去重状态（存在 <数据目录>/notify-state.json） ----------------
       [key: 首次见到的时刻]。key 见过就永远不再播；播种过的类别记在 "seed:<类别>"。

       ⚠️ 路径必须走 MBBPaths.home，**不能**写死 ~/.mbboard：
         分发版的数据目录是 ~/Library/Application Support/ManageBac 看板 Mac/，
         而且启动时会把老目录里的 notify-state.json 迁过来。这里要是继续写老目录，
         迁移就白做了，而且 App 会一直在别人的家目录里留垃圾。 */
    private static var stateURL: URL {
        MBBPaths.home.appendingPathComponent("notify-state.json")
    }

    private static func loadState() -> [String: Double] {
        guard let d = try? Data(contentsOf: stateURL),
              let m = try? JSONDecoder().decode([String: Double].self, from: d) else { return [:] }
        return m
    }

    private static func saveState(_ m: [String: Double]) {
        // 不再按时间截断成 800 条 —— 截断就意味着「老的 key 被忘掉」，
        // 下次刷新又当成新的播一遍。这里按字典序稳定保留全部（键都很短，
        // 一年也就几千条，文件仍然是几十 KB 量级）。
        if let d = try? JSONEncoder().encode(m) {
            try? d.write(to: stateURL, options: .atomic)
        }
    }

    /// 只记录、不发送
    private static func mark(_ key: String) {
        var m = loadState()
        m[key] = Date().timeIntervalSince1970
        saveState(m)
    }

    /// 某类通知是否已建立「基线」
    private static func seeded(_ cat: String) -> Bool {
        loadState()["seed:\(cat)"] != nil
    }

    private static func markSeeded(_ cat: String) {
        mark("seed:\(cat)")
    }

    /// 规则升级：key 算法/门槛一改，旧的「见过」记录就不再可靠。
    /// 处理方式是**把所有类别打回未播种状态**，让它们各自重新静默记账一遍
    /// （老 key 保留 —— 多留记录只会更安全；历史一条都不补播）。
    private static func migrateIfNeeded() {
        var m = loadState()
        guard m[schemaKey] == nil else { return }
        for k in m.keys.filter({ $0.hasPrefix("seed:") }) { m[k] = nil }
        m[schemaKey] = Date().timeIntervalSince1970
        saveState(m)
        Log.write("通知：规则升级到 \(schemaKey)，各类别重建基线（历史一条都不补播）")
    }

    /* ---------------- 免打扰 ---------------- */

    private static func minutes(_ s: String) -> Int {
        let p = s.split(separator: ":").compactMap { Int($0) }
        return (p.first ?? 0) * 60 + (p.count > 1 ? p[1] : 0)
    }

    static func inQuietHours(_ settings: BoardSettings, now: Date = Date()) -> Bool {
        guard settings.notifyQuietOn else { return false }
        let cal = Calendar.current
        let cur = cal.component(.hour, from: now) * 60 + cal.component(.minute, from: now)
        let a = minutes(settings.notifyQuietFrom), b = minutes(settings.notifyQuietTo)
        if a == b { return false }
        return a < b ? (cur >= a && cur < b) : (cur >= a || cur < b)
    }

    /* ---------------- 学科白名单 ---------------- */

    private static func subjectAllowed(_ raw: String?, _ settings: BoardSettings) -> Bool {
        guard !settings.notifySubjects.isEmpty else { return true }
        let k = Subject.key(raw ?? "")
        return !k.isEmpty && settings.notifySubjects.contains(k)
    }

    /* ---------------- 主入口 ---------------- */

    /// 每次刷新完数据后调一次，由它决定要不要弹通知
    static func evaluate(store: DataStore, settings: BoardSettings) {
        guard settings.notifyEnabled else { return }

        // 半成品数据不评估：
        //   · payload 还没到（loadTeams 会和主数据并发，它可能先来）——
        //     这时候 store 里是空的，评估出来的「0 条现状」会污染基线；
        //   · 冷启动占位 / 正在后台更新 —— 列表是残缺的，播出去全是噪音。
        guard let p = store.payload else { return }
        if p.updating == true || p.preparing == true { return }

        // 节流：一次刷新链路里 apply() 可能被调好几次（轮询新数据），
        // 15 秒内只认真评估一次。
        let now = Date()
        guard now.timeIntervalSince(lastEval) >= 15 else { return }
        lastEval = now
        migrateIfNeeded()

        if !inQuietHours(settings, now: now) {
            pendingTasks(store: store, settings: settings, now: now)
            teamsNews(store: store, settings: settings, now: now)
            mailNews(store: store, settings: settings, now: now)
            upcomingEvents(store: store, settings: settings, now: now)
            newGrades(store: store, settings: settings, now: now)
            ecReminder(store: store, settings: settings, now: now)
        }
        digest(settings: settings, now: now)
        pruneDelivered()
    }

    /* ---------------- 播报闸门 ----------------
       所有类别都走这里，规则只有一份：
         · 没建立基线 → 全部只记账（静默播种）
         · 见过的 key → 跳过
         · 发生时间超过 maxAge → 只记账（旧闻）
         · 剩下的：1–2 条各发各的，≥3 条合成一条汇总
       ⚠️ 状态文件在发送前就写盘（宁可少播，不可重播）。 */
    private static func flush(_ items: [News], category: String, settings: BoardSettings,
                              maxAge: TimeInterval, now: Date) {
        let ts = now.timeIntervalSince1970
        var m = loadState()

        // ① 首次运行 / 状态丢失 / 规则升级：只记现状，一条都不补播
        if !seeded(category) {
            for it in items { m[it.key] = ts }
            m["seed:\(category)"] = ts
            saveState(m)
            Log.write("通知：\(category) 建立基线（\(items.count) 条现状只记账不播）")
            return
        }

        // ② 去重 + 旧闻门槛
        var fresh: [News] = []
        var skippedOld = 0
        for it in items {
            if m[it.key] != nil { continue }
            if let e = it.eventAt, now.timeIntervalSince(e) > maxAge {
                m[it.key] = ts            // 旧闻：记账，不播
                skippedOld += 1
                continue
            }
            fresh.append(it)
            m[it.key] = ts
        }
        saveState(m)
        if skippedOld > 0 { Log.write("通知：\(category) 跳过 \(skippedOld) 条旧闻") }
        guard !fresh.isEmpty else { return }
        Log.write("通知：\(category) 播报 \(fresh.count) 条")

        // ③ 少则各发各的，多则合并成一条（避免刷新后一屏十几条）
        if fresh.count <= 2 {
            for it in fresh { post(it, settings: settings) }
        } else {
            let head = fresh[0]
            let names = fresh.prefix(3).map(\.body).joined(separator: "；")
            let more = fresh.count > 3 ? " 等 \(fresh.count) 条" : ""
            post(News(key: "\(category)-batch:\(Int(ts))",
                      kind: head.kind,
                      title: "\(fresh.count) 条\(categoryName(head.kind))",
                      body: names + more,
                      subject: head.subject,
                      url: head.url,
                      source: head.source,
                      eventAt: now),
                 settings: settings)
        }
    }

    private static func categoryName(_ k: NotifyKind) -> String {
        switch k {
        case .grade: return "新成绩"
        case .task:  return "到期提醒"
        case .teams, .invite: return "Teams 新任务"
        case .mail:  return "新邮件"
        case .event: return "日程提醒"
        case .ec:    return "English Corner 提醒"
        default:     return "新消息"
        }
    }

    /* ---------------- 分类规则 ---------------- */

    private static func pendingTasks(store: DataStore, settings: BoardSettings, now: Date) {
        guard settings.notifyTask else { return }
        let g = store.groups(now: now, settings: settings)
        let lead = settings.notifyLeadHours * 3600
        var out: [News] = []
        for t in g.up {
            guard let left = t.leftMs, left > 0, left <= lead * 1000 else { continue }
            guard subjectAllowed(t.fullSubject.isEmpty ? t.subject : t.fullSubject, settings) else { continue }
            if settings.notifyTaskRedOnly, t.band != .urgent, t.band != .over { continue }
            let mins = Int(left / 60000)
            let when = mins >= 60 ? "\(mins / 60) 小时 \(mins % 60) 分" : "\(mins) 分钟"
            // key 带截止时间：老师改了 deadline 就是新的一件事，值得再提醒一次
            let dueTag = Int(t.due?.timeIntervalSince1970 ?? 0)
            out.append(News(key: "task:\(t.id)|\(dueTag)",
                            kind: .task,
                            title: "\(t.subject) · 还有 \(when)",
                            body: t.title,
                            subject: t.fullSubject.isEmpty ? t.subject : t.fullSubject,
                            url: t.url, source: "managebac",
                            eventAt: nil))          // 未来事件，不受旧闻门槛影响
        }
        flush(out, category: "待办", settings: settings, maxAge: .infinity, now: now)
    }

    private static func teamsNews(store: DataStore, settings: BoardSettings, now: Date) {
        guard settings.notifyTeams else { return }
        var out: [News] = []
        for t in store.teamsTasks where t.pinned != true {
            guard subjectAllowed(t.course.isEmpty ? t.title : t.course, settings) else { continue }
            // 「你被加入某团队」和「老师发了新任务」是两件完全不同的事，
            // 以前混在同一个图标里根本看不出来。标题能认出来就单独分一类。
            let inv = inviteWord(t.title)
            let lab = t.course.isEmpty ? "" : Subject.label(t.course)
            let head = inv ? "团队邀请" : "Teams 新任务"
            out.append(News(key: "teams:\(t.id)",
                            kind: inv ? .invite : .teams,
                            title: lab.isEmpty ? head : "\(head) · \(lab)",
                            body: t.title,
                            subject: t.course.isEmpty ? t.title : t.course,
                            url: t.url, source: "teams",
                            eventAt: t.created))
        }
        flush(out, category: "Teams 任务", settings: settings, maxAge: 3 * 86400, now: now)
    }

    /// 标题里出现这些字样，说明是「你已被加入团队」这类系统通知
    private static func inviteWord(_ s: String) -> Bool {
        let low = s.lowercased()
        let pats = ["added you to", "you have been added", "added to a class team",
                    "added to the team", "you've been added", "被添加", "已被加入", "被加入"]
        return pats.contains { low.contains($0) }
    }

    private static func mailNews(store: DataStore, settings: BoardSettings, now: Date) {
        guard settings.notifyMail else { return }
        var out: [News] = []
        for m in store.teamsMails where m.isRead != true {
            out.append(News(key: "mail:\(m.id)",
                            kind: .mail,
                            title: "新邮件 · \(m.from)",
                            body: m.subject,
                            subject: m.subject,
                            url: m.url, source: "mail",
                            eventAt: m.received))
        }
        // 一周前的未读邮件不算新闻（多半是你一直没点开的旧邮件）
        flush(out, category: "邮件", settings: settings, maxAge: 7 * 86400, now: now)
    }

    private static func upcomingEvents(store: DataStore, settings: BoardSettings, now: Date) {
        guard settings.notifyEvents else { return }
        var out: [News] = []
        for e in store.teamsEvents where e.isToday {
            let left = e.start.timeIntervalSince(now)
            guard left > 0, left <= 900 else { continue }
            out.append(News(key: "event:\(e.id)",
                            kind: .event,
                            title: "\(Int(left / 60)) 分钟后 · \(e.start.formatted(date: .omitted, time: .shortened))",
                            body: e.title + (e.location.isEmpty ? "" : " @ \(e.location)"),
                            subject: e.title,
                            url: e.url, source: "teams",
                            eventAt: nil))
        }
        flush(out, category: "日程", settings: settings, maxAge: .infinity, now: now)
    }

    private static func newGrades(store: DataStore, settings: BoardSettings, now: Date) {
        guard settings.notifyGrades else { return }
        var out: [News] = []
        for w in store.recentWorks(12, settings: settings) {
            guard subjectAllowed(w.label, settings) else { continue }
            // key 只认「作业 + 分数」：分数变了（重批）算新消息，
            // 但 bridge 每次重算截止日期不会造成重复播报（那正是以前刷屏的来源之一）。
            let tag = (w.url?.absoluteString ?? w.title) + "|" + (w.grade ?? "") + "|" + w.scoreText
            out.append(News(key: "grade:\(tag)",
                            kind: .grade,
                            title: "出新成绩 · \(w.label)",
                            body: "\(w.title) — \(w.grade ?? "") \(w.scoreText)",
                            subject: w.label,
                            url: w.url, source: "managebac",
                            // bridge 记的「第一次见到这个分数」的时刻；老数据没有就退回截止时间
                            eventAt: w.gradedAt ?? w.due))
        }
        // 四天以前出的分不再当新闻（用户明确要求：一周前的旧成绩别再冒出来）
        flush(out, category: "成绩", settings: settings, maxAge: 4 * 86400, now: now)
    }

    private static let dayFmt: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    private static func ecReminder(store: DataStore, settings: BoardSettings, now: Date) {
        guard settings.notifyEC, store.teamsECActiveNow, let ec = store.teamsEC else { return }
        let klass = ec.klass ?? ""
        // key 必须带日期：EC 每天都要去，用固定 key 就变成「一辈子只提醒一次」。
        let day = ec.date ?? dayFmt.string(from: now)
        flush([News(key: "ec:\(day)",
                    kind: .ec,
                    title: "今天要去 English Corner",
                    body: "\(klass) 班 · \(ec.window ?? "13:00–13:40") · \(ec.place ?? "Room E113")",
                    subject: "英语",
                    url: ec.webUrl.flatMap { URL(string: $0) }, source: "ec",
                    eventAt: nil)],
              category: "EC", settings: settings, maxAge: .infinity, now: now)
    }

    private static func digest(settings: BoardSettings, now: Date) {
        guard settings.notifyDigest else { return }
        let cal = Calendar.current
        let cur = cal.component(.hour, from: now) * 60 + cal.component(.minute, from: now)
        guard cur >= minutes(settings.notifyDigestAt), cur < minutes(settings.notifyDigestAt) + 10 else { return }
        let day = dayFmt.string(from: now)
        var m = loadState()
        let key = "digest:\(day)"
        if m[key] == nil {
            m[key] = now.timeIntervalSince1970
            saveState(m)
            let store = DataStore.shared
            let g = store.groups(now: now, settings: settings)
            let cls = Schedule.dayList(now).list.filter { !$0.isFree }
            var lines: [String] = []
            if !g.up.isEmpty { lines.append("待办 \(g.up.count) 项（紧急 \(g.up.filter { $0.band == .urgent }.count) 项）") }
            if !cls.isEmpty { lines.append("今天 \(cls.count) 节课") }
            if let ec = store.teamsEC, ec.status == "today", ec.imIn == true {
                lines.append("要去 EC（\(ec.klass ?? "")）")
            }
            post(News(key: key, kind: .digest,
                      title: "早上好，今天的安排",
                      body: lines.isEmpty ? "今天暂无安排，轻松一点。" : lines.joined(separator: " · "),
                      subject: "",
                      url: URL(string: DataStore.manageBac), source: "managebac",
                      eventAt: nil),
                 settings: settings)
        }
    }

    /* ---------------- 发送 ---------------- */

    /// 标题第一行统一由这里拼：`种类 emoji + 文案`。
    /// 列表里十几条通知堆在一起时，最左边那个 emoji 是最快能扫到的区分点。
    ///
    /// identifier 直接用 key：万一同一件事被投递两次，系统会**替换**那一条，
    /// 而不是在通知中心里再堆一条（用户抱怨的「堆一大堆」就是被这个治住的）。
    private static func post(_ n: News, settings: BoardSettings) {
        guard inBundle else { return }          // 裸进程里发通知会直接崩，见 inBundle 注释
        // 自检开关：MBBOARD_NOTIFY_DRYRUN=1 时只记日志、不真发。
        // 用来验证「该播的会不会播、不该播的会不会安静」，而不打扰使用者。
        if ProcessInfo.processInfo.environment["MBBOARD_NOTIFY_DRYRUN"] == "1" {
            Log.write("通知：[试运行] 本应发出 → \(n.kind.emoji) \(n.title) — \(n.body)")
            return
        }
        let content = UNMutableNotificationContent()
        content.title = "\(n.kind.emoji) \(n.title)"
        content.body = n.body
        content.sound = settings.notifySound ? .default : nil
        if settings.notifySubjectIcon, let att = iconAttachment(n.subject, n.kind) {
            content.attachments = [att]
        }
        var ui: [AnyHashable: Any] = [:]
        if let url = n.url, !url.absoluteString.isEmpty { ui["url"] = url.absoluteString }
        if !n.source.isEmpty { ui["source"] = n.source }
        if !ui.isEmpty { content.userInfo = ui }
        let req = UNNotificationRequest(identifier: n.key, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(req, withCompletionHandler: nil)
    }

    /// 通知中心打扫：投递超过 36 小时的摘掉，最多留 24 条。
    /// 用户不需要在通知中心里翻一周前的作业提醒。
    private static func pruneDelivered() {
        guard inBundle else { return }
        let center = UNUserNotificationCenter.current()
        center.getDeliveredNotifications { list in
            let cutoff = Date().addingTimeInterval(-36 * 3600)
            var old = list.filter { $0.date < cutoff }.map(\.request.identifier)
            // 剩下的按时间倒序，超出的尾巴也一并摘掉
            let recent = list.filter { $0.date >= cutoff }.sorted { $0.date > $1.date }
            if recent.count > 24 { old += recent.dropFirst(24).map(\.request.identifier) }
            if !old.isEmpty { center.removeDeliveredNotifications(withIdentifiers: old) }
        }
    }

    /// 把「学科 × 种类」图标画成一张小 PNG 当通知缩略图。
    /// 画法与缓存键都在 NotifyIcon 里，离屏自检导出的是同一份图，
    /// 所以「自检里看到的样子」就是「真机上收到的样子」。
    private static func iconAttachment(_ subject: String,
                                       _ kind: NotifyKind) -> UNNotificationAttachment? {
        let key = NotifyIcon.key(subject: subject, kind: kind)
        // 图标也落在数据目录里（同 stateURL：别再写死 ~/.mbboard）
        let dir = MBBPaths.home.appendingPathComponent("notify", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("\(key).png")

        if !FileManager.default.fileExists(atPath: file.path) {
            guard let png = NotifyIcon.png(NotifyIcon.image(subject: subject,
                                                           kind: kind)) else { return nil }
            try? png.write(to: file)
        }
        return try? UNNotificationAttachment(identifier: key, url: file, options: nil)
    }

    /* ---------------- 自检用 ---------------- */

    /// 立刻发一条示例通知，用来在设置页确认「图标 / 声音 / 权限」都通。
    static func sample(subject key: String, settings: BoardSettings,
                       completion: ((Bool) -> Void)? = nil) {
        guard inBundle else { completion?(false); return }
        installDelegate()
        let cn = Subject.cnLabels[key] ?? "化学"
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .sound, .badge]) { granted, _ in
            Task { @MainActor in
                guard granted else { completion?(false); return }
                // 绕过学科白名单与总开关，示例永远发得出来。
                post(News(key: "sample:\(Int(Date().timeIntervalSince1970))",
                          kind: .sample,
                          title: "示例通知 · \(cn)",
                          body: "这是「\(cn)」的通知样式：左下角是学科色和学科图标，右下角小圆是事项种类。",
                          subject: cn,
                          url: URL(string: DataStore.manageBac), source: "managebac",
                          eventAt: nil),
                     settings: settings)
                completion?(true)
            }
        }
    }
}
