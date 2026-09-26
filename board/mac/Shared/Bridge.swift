import Foundation

/* ======================================================================
   本机桥接服务的轻量客户端
   引导页、设置页要用到一些 DataStore 没包的操作（登录、退出、希悦、刷新），
   统一放这里，避免每个视图自己拼 URLRequest。
   ====================================================================== */

enum Bridge {

    /// 直接写死，避免在非主 actor 上下文里引用 DataStore 的静态属性
    static let base = URL(string: "http://127.0.0.1:8765")!

    /* ------------------------------------------------------------------
       请求失败的「人话翻译」
       ------------------------------------------------------------------
       以前这里是 `try? await session.data(for:)` —— 一切失败都被吞成一个 nil。
       调用方拿不到 nil 的原因，只能一律按最坏假设解释，于是出现两类误报：

         · 后端根本没起来（连不上 8765）→ 界面说「登录失败，检查账号密码后重试」
           ——用户被引去反复改密码，而问题跟他账号一点关系都没有；
         · 后端忙不过来超时 → 界面说「看板没应答」，用户不知道是自己网络问题
           还是 App 坏了。

       现在每次请求都把「为什么失败」记在 lastFail 里（成功则清空），
       msg/text 在没有服务端说明时自动改用这句话。记住它必须在**每一次**
       请求里被赋值 —— 包括成功的那次，否则上一次的失败原因会一直粘着。
       ------------------------------------------------------------------ */
    private static let failLock = NSLock()
    private static var _lastFail = ""

    /// 最近一次请求为什么失败（空字符串 = 最近一次是成功的）。
    static var lastFail: String {
        failLock.lock(); defer { failLock.unlock() }
        return _lastFail
    }

    private static func noteFail(_ s: String) {
        failLock.lock(); _lastFail = s; failLock.unlock()
    }

    /// 把 URLSession 的错误翻译成「用户能照做」的一句话
    private static func humanize(_ e: Error) -> String {
        if let u = e as? URLError {
            switch u.code {
            case .timedOut:
                return "本机服务响应太慢（处理超时）。它可能正忙着抓数据，等十几秒再试一次就好。"
            case .cannotConnectToHost, .cannotFindHost, .networkConnectionLost,
                 .notConnectedToInternet, .dnsLookupFailed:
                return "本机服务没有在运行。请退出看板（⌘Q）再重新打开；如果反复如此，"
                     + "说明这台电脑上缺少看板需要的运行环境，请把这句话截图反馈。"
            default:
                break
            }
        }
        return "本机服务没应答（\(e.localizedDescription)）。"
    }

    /// 发一次请求，顺手把「失败原因」记下来。返回 nil 时 lastFail 一定非空。
    private static func send(_ req: URLRequest) async -> [String: Any]? {
        do {
            let (data, resp) = try await DataStore.session.data(for: req)
            if let http = resp as? HTTPURLResponse, http.statusCode >= 400 {
                noteFail("本机服务返回了错误码 \(http.statusCode)。请退出看板（⌘Q）重新打开。")
                return nil
            }
            guard let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
                noteFail("本机服务的回包看不懂（不是 JSON）。请退出看板（⌘Q）重新打开。")
                return nil
            }
            noteFail("")            // ★ 成功必须清掉上一次的失败原因
            return obj
        } catch {
            noteFail(humanize(error))
            return nil
        }
    }

    /// 拼 URL。
    /// 不能再用 `appendingPathComponent` 带查询串：它会把 `?` 转义成 `%3F`，
    /// `/api/status?probe=1` 于是变成一个叫「status?probe=1」的路径 —— 404。
    private static func url(_ path: String, _ query: [String: String] = [:]) -> URL {
        var c = URLComponents(url: base, resolvingAgainstBaseURL: false) ?? URLComponents()
        c.path = path.hasPrefix("/") ? path : "/" + path
        if !query.isEmpty {
            c.queryItems = query.map { URLQueryItem(name: $0.key, value: $0.value) }
        }
        return c.url ?? base
    }

    @discardableResult
    static func get(_ path: String, timeout: Double = 20,
                    query: [String: String] = [:]) async -> [String: Any]? {
        var req = URLRequest(url: url(path, query))
        req.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        req.timeoutInterval = timeout
        return await send(req)
    }

    @discardableResult
    static func post(_ path: String, _ body: [String: Any] = [:], timeout: Double = 40) async -> [String: Any]? {
        var req = URLRequest(url: url(path))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.timeoutInterval = timeout
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        return await send(req)
    }

    static func ok(_ d: [String: Any]?) -> Bool { (d?["ok"] as? Bool) ?? false }

    static func msg(_ d: [String: Any]?, _ fallback: String = "") -> String {
        if let s = (d?["msg"] as? String) ?? (d?["error"] as? String), !s.isEmpty { return s }
        // d == nil 说明压根没拿到回包 —— 这时「为什么没拿到」比 fallback 有用得多
        if d == nil, !lastFail.isEmpty { return lastFail }
        return fallback
    }

    /// 一条能给用户看的说明：优先 `msg`，再退回 `reason`。
    ///
    /// 服务端两条都写，但历史上接口只给 `reason` 而界面只读 `msg` ——
    /// 于是「正在后台下载 Chrome，几分钟后点重新校验」这类提示一个字都显示不出来，
    /// 用户只看到一句干巴巴的「未登录」，自然不知道该干什么。
    static func text(_ d: [String: Any]?, _ fallback: String = "") -> String {
        for k in ["msg", "reason", "error"] {
            if let s = d?[k] as? String, !s.isEmpty { return s }
        }
        if d == nil, !lastFail.isEmpty { return lastFail }
        return fallback
    }

    /// 查 ManageBac 登录态。
    ///
    /// 服务端默认回一份 15 秒内的快照（毫秒级）；`probe: true` 表示「用户刚点了
    /// 重新校验」，会让它现场探一次、最多等 20 秒。冷启动要开浏览器 + 载页面，
    /// 可能比 20 秒更久 —— 这时服务端会带 `probing: true` 先回一份旧的。
    /// 那就隔 3 秒再问一次，而不是把一个转不完的圈丢给用户。
    static func manageBacStatus(probe: Bool, rounds: Int = 3) async -> [String: Any]? {
        var last: [String: Any]?
        for _ in 0..<(probe ? max(1, rounds) : 1) {
            guard let d = await get("/api/status", timeout: 35,
                                    query: probe ? ["probe": "1"] : [:]) else { return nil }
            last = d
            if !probe || (d["probing"] as? Bool) != true { return d }
            try? await Task.sleep(nanoseconds: 3_000_000_000)
        }
        return last
    }

    /// 等本机服务真的能用。
    ///
    /// 返回值：`nil` = 已就绪；非空字符串 = 给用户看的失败原因。
    ///
    /// 以前引导页是「无脑等 8 秒」（20 × 400ms）就往下发请求 —— 后端要是压根
    /// 起不来（最典型：这台电脑上没有可用的 Python），8 秒之后必然连不上，
    /// 请求失败又被翻译成「登录失败，检查账号密码后重试」。用户于是去改密码，
    /// 而问题跟他账号半点关系都没有。这是「四个账号只有 DeepSeek 登得进去」
    /// 最可能的真身（DeepSeek 走 App 内网页，完全不经过后端）。
    ///
    /// 现在：① 等就绪；② 后端一旦**明确**报出起不来的原因（status == .offline）
    /// 就立刻停，把那句话原样交给用户，不再白等。
    static func waitReady(seconds: Double = 30) async -> String? {
        if await DataStore.shared.healthy() { return nil }
        await MainActor.run { DataStore.shared.launchServicePublic() }

        let steps = Int(max(1, seconds / 0.4))
        for _ in 0..<steps {
            if await DataStore.shared.healthy() { return nil }
            let s = await MainActor.run { DataStore.shared.status }
            if case .offline(let m) = s, !m.isEmpty { return m }
            try? await Task.sleep(nanoseconds: 400_000_000)
        }
        let final = await MainActor.run { DataStore.shared.status }
        if case .offline(let m) = final, !m.isEmpty { return m }
        return "本机服务启动超时。请退出看板（⌘Q）后重新打开再试。"
    }

    /// 不管桥接服务在不在，先尽力拉起来（不关心结果的老调用路径）
    static func launchIfNeeded() {
        Task { @MainActor in
            _ = await waitReady(seconds: 30)
        }
    }

    /// 告诉后端「用户已经进场」（在用户点下「让我们开始吧」那一刻调）。
    ///
    /// ★ 为什么非要有这一句 ★
    ///   后端是 App 一启动就起来的，比开场动画早得多。它有几处会去用户的
    ///   下载 / 桌面 / 文稿里找课表 xlsx，而 macOS 只要被列一次目录就会弹
    ///   「"ManageBac-Buddy" 想要访问您的下载文件夹」的授权框 —— 那个框会
    ///   直接盖在快闪 / hello 上。用户的原话：
    ///       「这种弹窗都要放到用户点击『让我们开始吧』这个按钮之后，
    ///         不要影响前面动画的观感」
    ///   所以在收到这句话之前，后端只扫自己的导出目录（不触发任何授权）。
    ///
    ///   幂等，重复调没有副作用；调失败也不要紧 —— 后端自己还有一道
    ///   两分钟的兜底（见 seiue._READY_FALLBACK_SEC），不会永久卡住。
    static func ready() async {
        _ = await post("/api/ready", [:], timeout: 8)
    }
}

/* ---------------- 首次引导的步骤定义 ---------------- */

enum OnboardingStep: Int, CaseIterable, Identifiable {
    case welcome, identity, managebac, teams, seiue, ai, theme, notify, done
    var id: Int { rawValue }

    var title: String {
        switch self {
        case .welcome:   return "欢迎使用"
        case .identity:  return "先认识一下你"
        case .managebac: return "连接 ManageBac"
        case .teams:     return "连接 Microsoft Teams"
        case .seiue:     return "导入希悦课表"
        case .ai:        return "连接灵析 AI"
        case .theme:     return "挑一个主题"
        case .notify:    return "要不要提醒你"
        // ⚠️ 这里**不要**写「全部就绪」这种带结论的词。
        //    左侧进度条和右侧大标题会同时出现在一屏上，而大标题是按实际
        //    情况算的（账号没连齐就说「基本就绪」）。这一项恒为「全部就绪」
        //    的时候，屏幕上就是左边一个绿勾写着"全部就绪"、右边大字写着
        //    "基本就绪" —— 自己打自己。步骤名只描述"第几步"，结论交给标题。
        case .done:      return "完成"
        }
    }

    var subtitle: String {
        switch self {
        case .welcome:   return "十分钟配好，之后打开就能用"
        case .identity:  return "你的英语名是查 English Corner 名单的唯一依据"
        case .managebac: return "作业、成绩、课表都来自这里"
        case .teams:     return "从 Teams 的任务、邮件、聊天里自动挑出学习待办"
        case .seiue:     return "希悦的课表最直观，一周同步一次就够"
        case .ai:        return "看板里的对话助手，登录一次就能用"
        case .theme:     return "配色整体换掉，大小看板一起变"
        case .notify:    return "什么时候提醒、提醒什么，都由你定"
        case .done:      return "四个账号均已检查"
        }
    }

    var icon: String {
        switch self {
        case .welcome:   return "hand.wave.fill"
        case .identity:  return "person.text.rectangle.fill"
        case .managebac: return "graduationcap.fill"
        case .teams:     return Icons.teams
        case .seiue:     return "calendar.badge.clock"
        case .ai:        return "sparkles.rectangle.stack.fill"
        case .theme:     return "paintpalette.fill"
        case .notify:    return "bell.badge.fill"
        case .done:      return "checkmark.seal.fill"
        }
    }

    /// 是否属于「要登录的账号」那几步 —— 这几步统一显示「可以跳过」的提示，
    /// 并且会在完成页汇总成一张账号清单。
    var isAccountStep: Bool {
        switch self {
        case .managebac, .teams, .seiue, .ai: return true
        default: return false
        }
    }
}
