import Foundation
import SwiftUI
import Combine

enum Log {
    static let url = URL(fileURLWithPath: "/tmp/mbboard-mac.log")
    static func write(_ text: String) {
        let line = "\(ISO8601DateFormatter().string(from: Date()))  \(text)\n"
        guard let data = line.data(using: .utf8) else { return }
        if let h = try? FileHandle(forWritingTo: url) {
            h.seekToEndOfFile(); h.write(data); try? h.close()
        } else {
            try? data.write(to: url)
        }
    }
}

@MainActor
final class DataStore: ObservableObject {

    enum Status: Equatable {
        case idle, loading, ok, notLoggedIn, offline(String)

        var text: String {
            switch self {
            case .idle:        return "准备中"
            case .loading:     return "读取中…"
            case .ok:          return "数据已就绪"
            case .notLoggedIn: return "登录已失效"
            // ★ 这里必须把具体原因带出去 ★
            //   `.offline` 是带着一句话构造出来的（「没找到 Python 3 …」之类），
            //   而以前 text 把它扔掉、只回一句「看板没在运行」——
            //   于是用户看到的永远是同一句废话，真正的原因只躺在日志里。
            //   分发出去的 App 里没有人会去翻日志，原因必须在屏幕上。
            case .offline(let m): return m.isEmpty ? "看板没在运行" : m
            }
        }
    }

    @Published var status: Status = .idle
    @Published var payload: Payload?
    @Published var lastFetch: Date?
    @Published var busy = false
    @Published var teams: TeamsEnvelope?
    /// 希悦课表（独立链路，连不上不影响别处）
    @Published var seiue: SeiueEnvelope?

    static let shared = DataStore()

    static let base = URL(string: "http://127.0.0.1:8765")!

    /// 学校 ManageBac 地址 —— 由设置决定（默认值集中在 SchoolURL.fallback）。
    /// 换学校不用改代码：设置 → 账号管理 → 学校地址。
    static var manageBac: String { SchoolURL.current }

    static let session: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        c.connectionProxyDictionary = [
            "HTTPEnable": 0, "HTTPProxy": "", "HTTPPort": 0,
            "HTTPSEnable": 0, "HTTPSProxy": "", "HTTPSPort": 0,
            "ProxyAutoConfigEnable": 0, "SOCKSEnable": 0,
        ]
        c.timeoutIntervalForRequest = 25
        return URLSession(configuration: c)
    }()

    private var looping = false

    /* ---------------- 生命周期 ---------------- */

    func begin() {
        guard !looping else { return }
        looping = true
        Task { @MainActor in
            await load()
            // 开机就把 EC 名单预下载好 —— 之后大小看板点「看名单」都是秒开本地 PDF，
            // 不用等 SharePoint。用户要求「提前预下载」。
            Task.detached { await Bridge.post("/api/ec/prefetch", [:], timeout: 180) }
            // 希悦：只要电脑上还留着希悦的登录态，就顺手看一眼有没有课表 ——
            // 不能只在「用户手动打开过开关」时才看。用户明明已经在浏览器里登进
            // 希悦、课表也看得见了，App 却因为开关是关的就一直不显示，这正是
            // 他上次报的那个问题。查到课表就自动把这一项打开（只自动开一次，
            // 之后用户手动关掉就不会再被改回去）。
            await loadSeiue(autoEnable: true)
            // 两条节奏分开跑：
            //   · Teams：默认 90 秒问一次（设置里可调）。服务端有自己的 TTL，
            //     够新就直接回缓存，所以问得勤不会打爆 Graph。
            //   · ManageBac 主体：按用户设置的分钟数（抓一次要开无头浏览器，比较重）。
            var sinceMain: Double = 0
            var sinceTeams: Double = 90      // 启动时刚刚 load 过，先等一个周期再问
            let step: Double = 15
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(step * 1_000_000_000))
                sinceMain += step
                sinceTeams += step

                // 「只在可见时刷新」：两个窗口都收起来就暂停轮询，省电也省 Graph 配额；
                // 一旦有窗口露出来，下面会立刻补一次。
                let s = BoardSettings.shared
                let visible = NSApp.windows.contains { $0.isVisible && $0.alphaValue > 0.01 }
                if s.refreshWhenVisibleOnly && !visible {
                    wasIdle = true
                    continue
                }
                if wasIdle {
                    wasIdle = false
                    sinceTeams = 0
                    await loadTeams()
                    continue
                }

                if sinceTeams >= max(30, s.refreshTeamsSec) {
                    sinceTeams = 0
                    await loadTeams()
                }

                let m = max(1.0, s.refreshMinutes)
                if sinceMain >= m * 60 {
                    sinceMain = 0
                    sinceTeams = 0
                    await load()
                    await loadTeams()
                }
            }
        }
    }

    /// 刚刚从「没有窗口」恢复过来
    private var wasIdle = false

    /// 给视图层用：把服务拉起来（引导页 / 设置页要点「拉一次」）
    func launchServicePublic() { launchService() }

    func start() async { if payload == nil { await load() } }

    func load(force: Bool = false) async {
        if busy { return }
        busy = true
        if payload == nil { status = .loading }

        if !(await healthy()) {
            Log.write("服务未运行 → 拉起 bridge.py")
            launchService()
            for _ in 0..<24 {
                if await healthy() { break }
                try? await Task.sleep(nanoseconds: 500_000_000)
            }
        }

        Task { await loadTeams() }          // 与主数据并发，互不拖累

        do {
            let p = try await fetchPayload()
            apply(p)
            if p.updating == true { await waitForFresh() }
        } catch {
            status = .offline(error.localizedDescription)
            Log.write("load fail: \(error.localizedDescription)")
        }
        busy = false
    }

    /// 把一份负载落成界面状态。
    ///
    /// `loggedIn` 是**三态**，不是两态：
    ///   `false` → 明确取不到数据（掉登录）
    ///   `true`  → 明确能取到
    ///   `nil`   → 还不知道。冷启动的占位负载就是这样：后台正在抓，这会儿谁也不知道
    ///
    /// ★ 以前这里只判「== false」，于是 nil 和 true 一起落进 `.ok`。再叠上占位
    ///   负载里那句写死的 loggedIn=true，结果就是「还没抓到」被显示成「数据已就绪」，
    ///   而屏幕上一片空白；后台抓取一旦失败，这个假绿会永远挂着，
    ///   用户只能看到「什么都没有」，永远等不到那句真正的原因。
    private func apply(_ p: Payload) {
        payload = p
        lastFetch = Date()
        switch p.loggedIn {
        case .some(false): status = .notLoggedIn
        case .some(true):  status = .ok
        case .none:        status = .loading      // 未定，不敢说「已就绪」
        }
        Notifier.evaluate(store: self, settings: BoardSettings.shared)
    }

    private func fetchPayload() async throws -> Payload {
        var req = URLRequest(url: DataStore.base.appendingPathComponent("api/data"))
        req.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        let (data, resp) = try await DataStore.session.data(for: req)
        if let http = resp as? HTTPURLResponse, http.statusCode >= 400 { throw URLError(.badServerResponse) }
        return try JSONDecoder().decode(Payload.self, from: data)
    }

    private func waitForFresh() async {
        for _ in 0..<24 {
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            if let p = try? await fetchPayload(), p.updating != true { apply(p); return }
        }
        // ★ 36 秒没等到就**不要静默放弃**。
        //   以前这里直接 return，界面停在哪算哪；而它通常停在「还没确定」上，
        //   用户盯着一片空数据，既没有错也没有解释。补问一次 /api/status ——
        //   它给的是**当下**的登录判定（不是缓存里的旧值），足够给出结论。
        await refreshStatusOnly()
    }

    /// 只问一次「现在到底登没登上」。
    ///
    /// 为什么用 /api/status 而不是 /api/data：数据那条路可能正卡在后台抓取上，
    /// 它会一直回占位负载；而 status 是当场探测的结论，不掺缓存。
    /// 拿不到明确结论（还是 nil）就什么都不动 —— 宁可维持「读取中」，也不猜。
    private func refreshStatusOnly() async {
        var req = URLRequest(url: DataStore.base.appendingPathComponent("api/status"))
        req.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        guard let (data, _) = try? await DataStore.session.data(for: req),
              let d = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let logged = d["loggedIn"] as? Bool
        else { return }
        status = logged ? .ok : .notLoggedIn
        Log.write("首抓超时，按 /api/status 判定 loggedIn=\(logged)：\(d["reason"] ?? "")")
    }

    /// 服务在不在，而且**是不是我们这一份**。
    ///
    /// 光看 HTTP 200 不够：本机可能还跑着一个从老位置（~/.mbboard）拉起来的旧服务，
    /// 于是 App 一直跟它说话、数据目录一直是老的 —— 表面上「能用」，
    /// 实际上装的是上一版，而且登录态还是旧目录里那一份。
    /// 所以顺手比一下服务自报的 dataDir 与 codeDir。
    func healthy() async -> Bool {
        var req = URLRequest(url: DataStore.base.appendingPathComponent("/api/health"))
        req.timeoutInterval = 2
        req.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        guard let (data, resp) = try? await DataStore.session.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200,
              let d = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              (d["ok"] as? Bool) == true else { return false }

        // 没有 components 的是 v4 及更早的服务 —— 不是我们要的那一份
        guard let c = d["components"] as? [String: Any],
              let dir = c["dataDir"] as? String, !dir.isEmpty else { return false }
        let mine = URL(fileURLWithPath: dir).standardizedFileURL.path
        let want = MBBPaths.home.standardizedFileURL.path
        if mine != want {
            Log.write("端口上跑的不是这一份服务（数据目录 \(mine)，期望 \(want)）")
        }
        return mine == want
    }

    /// 把不是我们这一份的 bridge 进程清掉 —— 它占着 8765，会挡住新服务。
    private func stopStaleBridge() {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
        p.arguments = ["-f", "bridge.py"]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try? p.run()
        p.waitUntilExit()
        Thread.sleep(forTimeInterval: 0.7)
    }

    /// 同步抓一次（离屏渲染自检用）
    func loadBlocking() {
        let sem = DispatchSemaphore(value: 0)
        var got: Payload?
        var req = URLRequest(url: DataStore.base.appendingPathComponent("api/data"))
        req.timeoutInterval = 30
        DataStore.session.dataTask(with: req) { data, _, _ in
            if let data { got = try? JSONDecoder().decode(Payload.self, from: data) }
            sem.signal()
        }.resume()
        _ = sem.wait(timeout: .now() + 35)
        if let g = got { apply(g) }
    }

    /* ---------------- Teams 板块 ---------------- */

    /// Teams 板块是独立链路：它挂了也绝不让主看板卡住，所以单独发车。
    func loadTeams() async {
        var req = URLRequest(url: DataStore.base.appendingPathComponent("api/teams"))
        req.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        // 40 秒。服务端早已把「现场取令牌」挪到后台线程，正常回包在 1 秒内；
        // 这里留宽只是防极端情况（浏览器正好在重启、机器刚睡醒）。
        // 这条曾经是 20 秒 —— 而当时服务端冷启动要 19~40 秒才回包，
        // 于是首屏必定超时、Teams 板块整块不出现，日志里只有一句
        // 「teams: 请求失败」，什么都没说清。别再收窄它。
        req.timeoutInterval = 40
        do {
            let (data, resp) = try await DataStore.session.data(for: req)
            guard (resp as? HTTPURLResponse)?.statusCode == 200 else {
                Log.write("teams: 服务端返回 \((resp as? HTTPURLResponse)?.statusCode ?? -1)")
                return
            }
            if let e = try? JSONDecoder().decode(TeamsEnvelope.self, from: data) {
                // 桥接端偶尔会回一个「还没抓到」的空包（刚重启、正在抓、链路抖）。
                // 这种包要是直接盖上来，界面立刻一片空白 —— 而用户明明几秒前还看得见内容。
                // 所以：空包一律不覆盖，沿用手里这份，只更新状态字段。
                teams = Self.mergeTeams(old: teams, new: e)
                Notifier.evaluate(store: self, settings: BoardSettings.shared)
            } else {
                Log.write("teams: 返回内容解析失败")
            }
        } catch {
            // 超时/断连都落到这里。这不算错误状态 —— 沿用手里这份就行，
            // 但必须把原因写进日志，否则「板块偶尔少一块」根本无从查起。
            Log.write("teams: 请求失败（\(error.localizedDescription)）")
        }
    }

    /// 用新包更新 Teams 状态，但**不允许把已有内容抹成空**。
    private static func mergeTeams(old: TeamsEnvelope?, new: TeamsEnvelope) -> TeamsEnvelope {
        guard let old, let oldSec = old.section else { return new }
        let newEmpty = (new.section?.tasks ?? []).isEmpty
            && (new.section?.mail ?? []).isEmpty
            && (new.section?.events ?? []).isEmpty
        let oldEmpty = (oldSec.tasks ?? []).isEmpty
            && (oldSec.mail ?? []).isEmpty
            && (oldSec.events ?? []).isEmpty
        guard newEmpty, !oldEmpty else { return new }
        var merged = new
        merged.section = oldSec
        merged.stale = true
        return merged
    }

    /* ---------------- 希悦课表 ----------------
       和 Teams 一样是独立链路：希悦连不上绝不影响主看板。 */

    func loadSeiue(autoEnable: Bool = false) async {
        let s = BoardSettings.shared
        // 平时（用户没开这一项时）不进这里；只有开机时那次带 autoEnable 的探测会。
        guard s.seiueEnabled || autoEnable else { return }
        var req = URLRequest(url: DataStore.base.appendingPathComponent("api/seiue"))
        req.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        // 60 秒：希悦这一趟可能要「开浏览器 → 回首页 → 读整张课表」，
        // 冷启动时比 Teams 还慢一档。缓存命中时是毫秒级，所以放宽不伤日常。
        req.timeoutInterval = 60
        do {
            let (data, resp) = try await DataStore.session.data(for: req)
            guard (resp as? HTTPURLResponse)?.statusCode == 200 else {
                Log.write("seiue: 服务端返回 \((resp as? HTTPURLResponse)?.statusCode ?? -1)")
                return
            }
            if let e = try? JSONDecoder().decode(SeiueEnvelope.self, from: data) {
                seiue = e
                // 拿到课表了、而用户从没手动表过态 → 直接替他把课表接上。
                // 用 seiueAutoV2 记住「这次自动开过」，以后他手动关掉就不再自作主张。
                let n = e.schedule?.lessons?.count ?? 0
                if autoEnable, n > 0, !s.seiueEnabled, !s.seiueAutoV2 {
                    s.seiueAutoV2 = true
                    s.seiueEnabled = true
                    Log.write("希悦：读到 \(n) 节课，自动接上课表")
                }
            } else {
                Log.write("seiue: 返回内容解析失败")
            }
        } catch {
            Log.write("seiue: 请求失败（\(error.localizedDescription)）")
        }
    }

    /// 拉起微软授权（服务端会打开浏览器，前端轮询 teams 看结果）
    func teamsLogin() async {
        var req = URLRequest(url: DataStore.base.appendingPathComponent("api/teams/login"))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = "{}".data(using: .utf8)
        req.timeoutInterval = 15
        _ = try? await DataStore.session.data(for: req)
        for _ in 0..<240 {                      // 后端最多试 5 条通道，这里给 8 分钟窗口
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            await loadTeams()
            if teams?.loggedIn == true { break }
            if teams?.loggingIn != true { break }
        }
        await loadTeams()
    }

    /// 当前这条通道被「需要管理员批准」挡住时，客户端没法自动知道，得由用户点一下换下一条
    func teamsSkip() async {
        var req = URLRequest(url: DataStore.base.appendingPathComponent("api/teams/skip"))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = "{}".data(using: .utf8)
        req.timeoutInterval = 15
        _ = try? await DataStore.session.data(for: req)
        await loadTeams()
    }

    func teamsLogout() async {
        var req = URLRequest(url: DataStore.base.appendingPathComponent("api/teams/logout"))
        req.httpMethod = "POST"
        _ = try? await DataStore.session.data(for: req)
        teams = nil
        await loadTeams()
    }

    func teamsRefresh() async {
        var req = URLRequest(url: DataStore.base.appendingPathComponent("api/teams/refresh"))
        req.httpMethod = "POST"
        _ = try? await DataStore.session.data(for: req)
        for _ in 0..<30 {
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            await loadTeams()
            if teams?.fetching != true { break }
        }
    }

    /* ---------------- Teams 视图模型 ---------------- */

    var teamsSection: TeamsData? { teams?.section }

    /// 主看板是否还在等首抓：没拿到 payload，或拿到的是「正在准备」占位负载。
    /// 界面据此显示同步骨架，而不是把「没有作业」或一片空白摆在用户面前。
    var isPreparing: Bool {
        guard let p = payload else { return true }
        return p.preparing == true
            || (p.updating == true && (p.tasks ?? []).isEmpty)
    }

    /// English Corner 状态（今天要不要去、同班名单）
    var teamsEC: TeamsEC? { teamsSection?.ec }

    /// 「今天还得去 EC」现在是否还成立 —— 后端算过一遍，这里再按 deadline 兜一遍。
    /// 好处是 14:00 一到，界面立刻收掉，不用等下一次刷新（缓存 TTL 有 120 秒）。
    var teamsECActiveNow: Bool {
        guard let e = teamsEC, e.active == true else { return false }
        guard let d = e.deadlineMs else { return true }
        return Date().timeIntervalSince1970 * 1000 < d
    }

    var teamsTasks: [TeamsTaskVM] {
        guard let list = teamsSection?.tasks else { return [] }
        let nowMs = Date().timeIntervalSince1970 * 1000
        return list.compactMap { t in
            // EC 那条只挂到当天 14:00：到点后即使缓存还没过期也直接收掉
            if t.pin == true, let d = t.dueMs, d < nowMs { return nil }
            return TeamsTaskVM(
                id: t.id,
                title: t.title ?? "(无标题)",
                source: TeamsSource(rawValue: t.source ?? "") ?? .todo,
                course: t.course ?? "",
                detail: t.detail ?? "",
                from: t.from ?? "",
                due: t.dueMs.map { Date(timeIntervalSince1970: $0 / 1000) },
                dueText: t.dueText ?? "",
                created: t.createdMs.map { Date(timeIntervalSince1970: $0 / 1000) },
                confidence: t.confidence ?? 1.0,
                signals: t.signals ?? [],
                importance: t.importance ?? "normal",
                url: (t.webUrl?.isEmpty == false) ? URL(string: t.webUrl!) : nil,
                preview: t.preview,
                pinned: t.pin ?? false,
                place: t.place ?? "")
        }
    }

    var teamsEvents: [TeamsEventVM] {
        guard let list = teamsSection?.events else { return [] }
        let cal = Calendar.current
        return list.compactMap { e in
            guard let s = e.startMs else { return nil }
            let d = Date(timeIntervalSince1970: s / 1000)
            return TeamsEventVM(
                id: e.id,
                title: e.title ?? "(无标题)",
                start: d,
                end: e.endMs.map { Date(timeIntervalSince1970: $0 / 1000) },
                location: e.location ?? "",
                organizer: e.organizer ?? "",
                url: (e.webUrl?.isEmpty == false) ? URL(string: e.webUrl!) : nil,
                isToday: cal.isDateInToday(d))
        }
    }

    var teamsMails: [TeamsMailVM] {
        guard let list = teamsSection?.mail else { return [] }
        return list.map { m in
            TeamsMailVM(
                id: m.id,
                subject: m.subject ?? "(无主题)",
                from: m.from ?? "",
                received: m.receivedMs.map { Date(timeIntervalSince1970: $0 / 1000) },
                isRead: m.isRead ?? true,
                important: (m.importance ?? "") == "high",
                hasAttachments: m.hasAttachments ?? false,
                preview: m.preview ?? "",
                url: (m.webUrl?.isEmpty == false) ? URL(string: m.webUrl!) : nil)
        }
    }

    /// 这个 python3 是不是真的能跑。
    ///
    /// ★ 为什么不能只看 isExecutableFile ★
    /// macOS（Catalina 之后）在每一台机器上都放着 /usr/bin/python3，但它只是
    /// 一层壳：真正干活的是「Xcode 命令行工具」里的那份。没装命令行工具的机器上
    /// 跑它会弹出系统弹窗「要安装命令行开发者工具吗？」，然后退出 —— 一点也不
    /// 「可执行」。而我们原来恰恰用最后兜底的 /usr/bin/python3 + isExecutableFile
    /// 判断，于是「找到了 python3」被当成「python3 能用」，后端静悄悄地起不来，
    /// 屏幕上只剩下「看板没应答」。这就是朋友那台机器上全线失败的样子。
    ///
    /// 所以：① 对 /usr/bin/python3 先在文件系统层面确认它背后的真身存在（避免
    /// 弹出那个吓人的系统弹窗）；② 其余候选真跑一次 `-V`，并且加硬超时。
    private func usablePython(_ path: String) -> Bool {
        guard FileManager.default.isExecutableFile(atPath: path) else { return false }

        // ① /usr/bin/python3 只是壳：真身在命令行工具里
        if path == "/usr/bin/python3" {
            let real = ["/Library/Developer/CommandLineTools/usr/bin/python3",
                        "/Applications/Xcode.app/Contents/Developer/usr/bin/python3"]
            guard real.contains(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
                Log.write("跳过 /usr/bin/python3：它只是一层壳，本机没装命令行工具")
                return false
            }
        }

        // ② 真跑一次，确认能执行、版本够（后端要 ≥3.8）
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = ["-c", "import sys; raise SystemExit(0 if sys.version_info >= (3, 8) else 9)"]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        let done = DispatchSemaphore(value: 0)
        p.terminationHandler = { _ in done.signal() }
        do { try p.run() } catch {
            Log.write("python3 候选 \(path) 起不来：\(error.localizedDescription)")
            return false
        }
        // 硬超时：壳程序会挂着等用户点弹窗，不设超时 App 就卡在启动画面
        if done.wait(timeout: .now() + 8) == .timedOut {
            p.terminate()
            Log.write("python3 候选 \(path) 8 秒没回应，跳过")
            return false
        }
        if p.terminationStatus != 0 {
            Log.write("python3 候选 \(path) 退出码 \(p.terminationStatus)，跳过")
            return false
        }
        return true
    }

    /// 顺手把本地数据服务拉起来。
    ///
    /// 三件事跟以前不一样，都是为了「换台电脑也能跑」：
    ///   ① 后端从「写死 ~/.mbboard/bridge.py」改成——先用 App 包内自带的那份
    ///      （已装到 Application Support），实在没有才退回老目录；
    ///   ② 显式把 MBBOARD_DATA 传给后端，让它的登录态/缓存落在用户自己的
    ///      数据目录里，而不是代码目录里；
    ///   ③ Python 解释器按候选清单找，不再绑定某台机器上某个路径。
    ///
    /// ★ 第 ④ 条是本轮加的：清单里现在**第一位是 App 包内自带的 Python**。
    ///   理由很直白 —— 要求「学生电脑上恰好装了 python3」是过分的要求，
    ///   而这是「四个账号全部登不进去」的最大单一原因。自带一份，
    ///   这一整类失败就彻底不存在了。
    private func launchService() {
        let bridge = MBBPaths.bridgeScript.path
        guard FileManager.default.fileExists(atPath: bridge) else {
            Log.write("找不到 bridge.py：\(bridge)")
            status = .offline("看板后台文件缺失（找不到 bridge.py）。请重新安装看板。")
            return
        }

        let home = NSHomeDirectory()
        // 后端只依赖 Python 标准库（http.server / urllib / subprocess），
        // 所以任何一个 ≥3.8 的 python3 都够用，不需要 pip 装东西。
        //
        // 顺序：★ App 包内自带的运行时（分发版一定有）★ → 用户数据目录里自带的
        //      → Homebrew（Apple 芯片 / Intel）→ PATH 里随便哪个
        //      → 最后才是系统的 /usr/bin/python3（它可能只是一层壳，见 usablePython）
        var candidates: [String] = []
        if let bundled = MBBPaths.bundledPython { candidates.append(bundled.path) }
        candidates += [
            "\(MBBPaths.home.path)/venv/bin/python3",
            "\(home)/.mbboard/venv/bin/python3",
            "/opt/homebrew/bin/python3",
            "/usr/local/bin/python3",
            "/usr/bin/python3"
        ]
        candidates += (ProcessInfo.processInfo.environment["PATH"] ?? "")
            .split(separator: ":").map { "\($0)/python3" }

        var py: String?
        // 去重，避免同一个解释器被跑好几遍（每次要起一个进程）
        var seen = Set<String>()
        for c in candidates where seen.insert(c).inserted {
            if usablePython(c) { py = c; break }

            // 轮到「包内自带的那份」且它跑不起来时，先别急着往下试别的解释器 ——
            // 它多半是被 com.apple.quarantine 拦了（清标记是另一条路径，见
            // prepareBundledPython）。把运行时整份搬到数据目录，从那儿再执行一次。
            // 这是最后一道保险：走到这一步说明连自带运行环境都用不了，
            // 不救一下用户就只能看到「找不到可用的 Python」。
            if let bundled = MBBPaths.bundledPython, c == bundled.path,
               let moved = MBBPaths.relocateBundledPython(), usablePython(moved) {
                Log.write("包内 Python 不可用，改用重定位后的副本：\(moved)")
                py = moved
                break
            }
        }

        guard let py else {
            // 这条提示要能照做：不是「环境有问题」，而是「怎么办」。
            // 正常情况下走不到这里 —— 分发版包里自带 Python。
            Log.write("找不到可用的 python3（候选 \(candidates.count) 个全部不可用）")
            status = .offline("这台电脑上找不到可用的 Python 运行环境，看板后台起不来。"
                              + "请重新安装看板（安装包里自带运行环境），或把这句话截图反馈。")
            return
        }

        let logPath = MBBPaths.file("bridge.log").path
        if !FileManager.default.fileExists(atPath: logPath) {
            FileManager.default.createFile(atPath: logPath, contents: nil)
        }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: py)
        p.arguments = [bridge]
        var env = ProcessInfo.processInfo.environment
        env["MBBOARD_IDLE"] = "600"
        // 关键：代码与数据分家。后端据此把 session.json / 抓取缓存 / 浏览器
        // profile 全部写到用户数据目录，绝不写回 App 包或源码目录。
        env["MBBOARD_DATA"] = MBBPaths.home.path
        env["MBBOARD_SCHOOL"] = SchoolURL.current
        p.environment = env
        if let h = FileHandle(forWritingAtPath: logPath) {
            // ★ 一定要先把文件截断到 0 再交出去 ★
            //   FileHandle(forWritingAtPath:) 只负责「打开来写」，**不截断**，
            //   而且位置从 0 开始 —— 于是新一版 bridge 的日志会从头上盖过去，
            //   旧日志比新的长时，尾巴上那截旧内容就原样留着。结果就是打开
            //   bridge.log 会看到「前半段是这次启动、后半段是上一次的报错」，
            //   夹杂一行被覆写掉一半的乱码行 —— 排查时极容易被带偏，把早就
            //   修掉的问题当成刚发生的新问题。
            try? h.truncate(atOffset: 0)
            p.standardOutput = h; p.standardError = h
        }
        do {
            stopStaleBridge()          // 先让出 8765：旧服务占着的话新服务起不来
            try p.run()
            Log.write("已拉起 bridge.py，解释器：\(py)，数据目录：\(MBBPaths.home.path)")
        } catch {
            Log.write("拉起 bridge.py 失败：\(error.localizedDescription)")
        }
    }

    /* ---------------- 展示辅助 ---------------- */

    var subtitle: String {
        if payload?.updating == true { return "正在更新…" }
        if let f = lastFetch {
            let c = Calendar.current.dateComponents([.hour, .minute], from: f)
            return "更新于 \(String(format: "%02d:%02d", c.hour ?? 0, c.minute ?? 0))"
        }
        return status.text
    }

    func statusColor(_ scheme: ColorScheme, accent: RGB) -> Color {
        switch status {
        case .ok:              return Theme.greenDefault.color(scheme, lift: 0.10)
        case .loading, .idle:  return Theme.amberDefault.color(scheme, lift: 0.10)
        case .notLoggedIn:     return Theme.amberDefault.color(scheme, lift: 0.10)
        case .offline:         return Theme.redDefault.color(scheme, lift: 0.16)
        }
    }

    var sessionHint: String? {
        guard let p = payload else { return nil }
        if p.sessionExpired == true && p.stale == true {
            let n = p.sessionNote ?? ""
            return n.isEmpty ? "登录已失效，下面显示的是上次抓到的数据" : n
        }
        return nil
    }

    static func parse(_ s: String?) -> Date? {
        guard let s, !s.isEmpty else { return nil }
        if let d = isoFrac.date(from: s) { return d }
        if let d = iso.date(from: s) { return d }
        return nil
    }

    private static let isoFrac: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    /* ---------------- 派生数据 ---------------- */

    func groups(now: Date = Date(), settings raw: BoardSettings? = nil) -> (up: [TaskVM], od: [TaskVM]) {
        let settings = raw ?? .shared
        guard let list = payload?.tasks else { return ([], []) }
        let nowMs = now.timeIntervalSince1970 * 1000
        let hidden = settings.hiddenList
        var up: [TaskVM] = []
        var od: [TaskVM] = []

        for t in list {
            let title = t.title ?? ""
            if hidden.contains(where: { !$0.isEmpty && title.contains($0) }) { continue }
            // 用户手动删掉的（逾期常见）—— 按 id 精确跳过。
            // 放在这里而不是各个视图里：待办页、菜单栏小面板、通知都从
            // groups() 取数据，一处过滤等于全都过滤 —— 尤其通知，
            // 删掉的作业不该再弹提醒。
            if DeletedTasks.shared.isDeleted(id: t.id) { continue }

            let due = DataStore.parse(t.due)
            let created = DataStore.parse(t.created)
            let leftMs = due.map { $0.timeIntervalSince1970 * 1000 - nowMs }
            let isOver = (t.view == "overdue") || (leftMs.map { $0 < 0 } ?? false)

            let leftText: String
            if isOver {
                leftText = due.map { "已逾期 " + humanLeft(nowMs - $0.timeIntervalSince1970 * 1000) } ?? "已逾期"
            } else {
                leftText = leftMs.map { "剩 " + humanLeft($0) } ?? "未设截止"
            }

            let raw = t.url ?? ""
            guard let url = URL(string: DataStore.manageBac + raw) else { continue }

            let vm = TaskVM(id: t.id, title: title,
                            subject: Subject.label(t.subject),
                            fullSubject: t.subject ?? "",
                            leftText: leftText,
                            band: bandOf(leftMs: leftMs, isOver: isOver, settings),
                            url: url, isOver: isOver, created: created, due: due,
                            kind: t.kind ?? "", type: t.type ?? "",
                            leftMs: leftMs)
            if isOver { od.append(vm) } else { up.append(vm) }
        }

        up.sort { a, b in
            let x = a.due?.timeIntervalSince1970 ?? .greatestFiniteMagnitude
            let y = b.due?.timeIntervalSince1970 ?? .greatestFiniteMagnitude
            if x == y { return a.subject < b.subject }
            return x < y
        }
        od.sort { ($0.due?.timeIntervalSince1970 ?? 0) > ($1.due?.timeIntervalSince1970 ?? 0) }
        return (up, od)
    }

    struct BandCounts {
        var red = 0, yellow = 0, blue = 0
        var isEmpty: Bool { red == 0 && yellow == 0 && blue == 0 }

        @MainActor func tooltip(_ s: BoardSettings) -> String {
            var parts: [String] = []
            if s.showRed, red > 0       { parts.append("红 \(red) 项") }
            if s.showYellow, yellow > 0 { parts.append("黄 \(yellow) 项") }
            if s.showBlue, blue > 0     { parts.append("蓝 \(blue) 项") }
            return parts.isEmpty ? "暂无红/黄/蓝待办" : parts.joined(separator: " · ")
        }
    }

    func bandCounts(settings raw: BoardSettings? = nil) -> BandCounts {
        let settings = raw ?? .shared
        var c = BandCounts()
        var list = groups(settings: settings).up
        if settings.countOverdue { list += groups(settings: settings).od }
        for t in list {
            switch t.band {
            case .urgent: c.red += 1
            case .soon:   c.yellow += 1
            case .blue:   c.blue += 1
            default:      break
            }
        }
        return c
    }

    func recentWorks(_ n: Int = 8, settings raw: BoardSettings? = nil) -> [RecentVM] {
        // `settings` 现在用不到：出分卡一律按「出分时间」从新到旧排，不受主题/密度影响。
        // 参数保留是因为 gpaRows 会把它透传下来 —— 将来排序规则要吃偏好时，接口不用改。
        _ = raw
        guard let list = payload?.recent else { return [] }
        let vms = list.map { w in
            let key = w.key ?? Subject.key(w.label ?? "")
            let g = (w.grade ?? "").trimmingCharacters(in: .whitespaces)
            let href = w.url.map { DataStore.manageBac + $0 }
            let due = DataStore.parse(w.due)
            let graded = (w.gradedAtMs ?? 0) > 0
                ? Date(timeIntervalSince1970: w.gradedAtMs! / 1000) : nil
            return RecentVM(
                id: w.id, label: w.label ?? "—", key: key,
                title: (w.title ?? "").isEmpty ? "作业" : (w.title ?? ""),
                due: due,
                dueText: due.map(shortDueDate) ?? shortDue(w.dueText),
                grade: g.isEmpty ? nil : g,
                scoreText: w.scoreText ?? "",
                scoreNum: w.score, scoreOutOf: w.outOf,
                url: href.flatMap { URL(string: $0) },
                good: !(g.hasPrefix("C") || g.hasPrefix("D") || g.hasPrefix("F")),
                gradedAt: graded)
        }
        // 按出分时间从新到旧（bridge 已经排过一次，这里兜底：老缓存 / 手改数据也稳）
        return Array(vms.sorted { $0.gradedSort > $1.gradedSort }.prefix(n))
    }

    func gpaRows(settings raw: BoardSettings? = nil) -> [GPARowModel] {
        let settings = raw ?? .shared
        let list = payload?.classes ?? []
        let recent = recentWorks(64, settings: settings)
        return list.map { c in
            let key = c.key ?? Subject.key(c.label ?? "")
            let href = c.url.map { DataStore.manageBac + $0 }
            let latestVM: RecentVM? = {
                guard let l = c.latest else { return nil }
                let g = (l.grade ?? "").trimmingCharacters(in: .whitespaces)
                return RecentVM(id: l.url ?? l.title ?? UUID().uuidString, label: c.label ?? "—", key: key,
                                title: l.title ?? "" , due: DataStore.parse(l.due),
                                dueText: shortDue(l.dueText) ,
                                grade: g.isEmpty ? nil : g,
                                scoreText: l.scoreText ?? "",
                                scoreNum: l.score, scoreOutOf: l.outOf,
                                url: l.url.map { DataStore.manageBac + $0 }.flatMap { URL(string: $0) },
                                good: !(g.hasPrefix("C") || g.hasPrefix("D") || g.hasPrefix("F")),
                                gradedAt: (l.gradedAtMs ?? 0) > 0
                                    ? Date(timeIntervalSince1970: l.gradedAtMs! / 1000) : nil)
            }()
            // 逐条作业 → 柱状图的数据。
            // 按截止时间**从旧到新**排：柱状图从左到右就是这一学期的进程，
            // 一眼能看出「最近是不是越来越稳」。
            var items: [RecentVM] = (c.items ?? []).map { l in
                let g = (l.grade ?? "").trimmingCharacters(in: .whitespaces)
                return RecentVM(id: l.url ?? l.title ?? UUID().uuidString,
                                label: c.label ?? "—", key: key,
                                title: (l.title ?? "").isEmpty ? "作业" : (l.title ?? ""),
                                due: DataStore.parse(l.due),
                                dueText: shortDue(l.dueText),
                                grade: g.isEmpty ? nil : g,
                                scoreText: l.scoreText ?? "",
                                scoreNum: l.score, scoreOutOf: l.outOf,
                                url: l.url.map { DataStore.manageBac + $0 }
                                     .flatMap { URL(string: $0) },
                                good: !(g.hasPrefix("C") || g.hasPrefix("D") || g.hasPrefix("F")),
                                gradedAt: (l.gradedAtMs ?? 0) > 0
                                    ? Date(timeIntervalSince1970: l.gradedAtMs! / 1000) : nil)
            }
            .sorted { ($0.due?.timeIntervalSince1970 ?? 0) < ($1.due?.timeIntervalSince1970 ?? 0) }

            // 兜底：老缓存（或抓取端还没跟上新版 scrape.js）里没有逐条 items，
            // 这时从「最新出分」里挑同一学科的条目顶上 —— 条数少一些，
            // 但总好过点开一个空弹窗。抓取端一刷新，真正的 items 就接管了。
            if items.isEmpty {
                items = recent.filter { $0.key == key }
                    .sorted { ($0.due?.timeIntervalSince1970 ?? 0) < ($1.due?.timeIntervalSince1970 ?? 0) }
            }

            return GPARowModel(id: c.id, label: c.label ?? "—", key: key,
                               pct: c.overall?.pct, grade: c.overall?.mark,
                               url: href.flatMap { URL(string: $0) }, latest: latestVM,
                               items: items, itemTotal: (c.items ?? []).count)
        }
    }

    var gpaSummary: (graded: Int, total: Int, avg: Double?) {
        let rows = gpaRows()
        let graded = rows.compactMap { $0.pct }
        let avg = graded.isEmpty ? nil : graded.reduce(0, +) / Double(graded.count)
        return (graded.count, rows.count, avg)
    }

    /// 全部已出分的作业（成绩页用）
    func allGraded(settings raw: BoardSettings? = nil) -> [RecentVM] {
        let settings = raw ?? .shared
        return recentWorks(40, settings: settings)
    }
}
