import Foundation

/* ======================================================================
   本机桥接服务的轻量客户端
   引导页、设置页要用到一些 DataStore 没包的操作（登录、退出、希悦、刷新），
   统一放这里，避免每个视图自己拼 URLRequest。
   ====================================================================== */

enum Bridge {

    /// 直接写死，避免在非主 actor 上下文里引用 DataStore 的静态属性
    static let base = URL(string: "http://127.0.0.1:8765")!

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
        guard let (data, _) = try? await DataStore.session.data(for: req) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    @discardableResult
    static func post(_ path: String, _ body: [String: Any] = [:], timeout: Double = 40) async -> [String: Any]? {
        var req = URLRequest(url: url(path))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.timeoutInterval = timeout
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        guard let (data, _) = try? await DataStore.session.data(for: req) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    static func ok(_ d: [String: Any]?) -> Bool { (d?["ok"] as? Bool) ?? false }
    static func msg(_ d: [String: Any]?, _ fallback: String = "") -> String {
        (d?["msg"] as? String) ?? (d?["error"] as? String) ?? fallback
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

    /// 不管桥接服务在不在，先尽力拉起来
    static func launchIfNeeded() {
        Task { @MainActor in
            if await DataStore.shared.healthy() { return }
            DataStore.shared.launchServicePublic()
            for _ in 0..<24 {
                if await DataStore.shared.healthy() { return }
                try? await Task.sleep(nanoseconds: 500_000_000)
            }
        }
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
