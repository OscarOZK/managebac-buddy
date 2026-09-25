//  WatchStore.swift
//  ManageBac Watch App —— 从 Mac 上的桥接服务取数（http://127.0.0.1:8765/api/data）
//  新建文件（菜单栏版 Store.swift 未改动）。
//
//  与菜单栏版的差异（watchOS 限制）：
//   ① watchOS 没有 Process —— 手表端无法拉起 Mac 上的 bridge.py，
//      服务没跑时只能提示「请在 Mac 上打开看板」；
//   ② 日志不写文件，直接 print（用 simctl launch --console 能看到）；
//   ③ 服务地址可配置：真机（手表脱离 Mac）时把桥接地址改成 Mac 的局域网 IP。

import Foundation
import SwiftUI
import Combine
import os

/// 日志：手表上 print 没人看得见，统一走 os_log（Console.app 里按子系统过滤）
/// 子系统 cn.oscar.ManageBacWatch ｜ 取法：log show --predicate 'subsystem == "cn.oscar.ManageBacWatch"'
enum WatchLog {
    private static let logger = Logger(subsystem: "cn.oscar.ManageBacWatch", category: "data")

    static func write(_ text: String) {
        logger.info("\(text, privacy: .public)")
        if ProcessInfo.processInfo.environment["MBWATCH_DUMP"] == "1" { print(text) }
    }

    /// 自检输出（多行）：走 os_log 的 default 级别，方便 log show 捞
    static func dump(_ text: String) {
        logger.notice("\(text, privacy: .public)")
        if ProcessInfo.processInfo.environment["MBWATCH_DUMP"] == "1" { print(text) }
    }
}

/* 服务地址：默认本机。真机改法见 WatchConfig */
enum WatchConfig {
    static let key = "MBWatchBridgeBase"
    /// 默认地址。在 Apple Watch 模拟器上，127.0.0.1 就是这台 Mac。
    static let fallback = "http://127.0.0.1:8765"

    static var base: URL {
        let s = UserDefaults.standard.string(forKey: key) ?? fallback
        return URL(string: s) ?? URL(string: fallback)!
    }
}

/* 待办 / GPA / 最新成绩的视图模型与派生算法都在 WatchDerive.swift 里（与 widget 共用同一份） */

@MainActor
final class WatchStore: ObservableObject {
    enum Status: Equatable {
        case idle, loading, ok, notLoggedIn, offline(String)

        var text: String {
            switch self {
            case .idle:            return "准备中"
            case .loading:         return "读取中…"
            case .ok:              return "数据已就绪"
            case .notLoggedIn:     return "登录已失效"
            case .offline:         return "电脑上的看板服务没开"
            }
        }
    }

    @Published var status: Status = .idle
    @Published var payload: Payload?
    @Published var lastFetch: Date?
    @Published var busy = false

    static let shared = WatchStore()
    private var looping = false

    static let session: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        c.timeoutIntervalForRequest = 25
        return URLSession(configuration: c)
    }()

    /* ---------------- 生命周期 ---------------- */

    /// 启动后台循环：立刻取一次，之后每 5 分钟一次（与菜单栏 App 同频）
    func begin() {
        guard !looping else { return }
        looping = true
        Task { @MainActor in
            await load()
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 300_000_000_000)
                await load()
            }
        }
    }

    func load(force: Bool = false) async {
        if busy { return }
        busy = true
        if payload == nil { status = .loading }
        WatchLog.write("load start (force=\(force))")

        do {
            let p = try await fetchPayload()
            apply(p)
            WatchLog.write("load ok tasks=\(p.tasks?.count ?? 0) classes=\(p.classes?.count ?? 0) recent=\(p.recent?.count ?? 0) updating=\(p.updating ?? false)")
            if p.updating == true { await waitForFresh() }
        } catch {
            status = .offline(error.localizedDescription)
            WatchLog.write("load fail: \(error.localizedDescription)")
        }
        busy = false
    }

    private func apply(_ p: Payload) {
        payload = p
        lastFetch = Date()
        status = (p.loggedIn == false) ? .notLoggedIn : .ok
    }

    private func fetchPayload() async throws -> Payload {
        var req = URLRequest(url: WatchConfig.base.appendingPathComponent("api/data"))
        req.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        let (data, resp) = try await WatchStore.session.data(for: req)
        if let http = resp as? HTTPURLResponse, http.statusCode >= 400 {
            throw URLError(.badServerResponse)
        }
        return try JSONDecoder().decode(Payload.self, from: data)
    }

    /// 服务端先回了缓存、正在后台抓新数据 → 等它抓完替换
    private func waitForFresh() async {
        for _ in 0..<24 {
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            if let p = try? await fetchPayload(), p.updating != true {
                apply(p)
                WatchLog.write("fresh data arrived")
                return
            }
        }
    }

    func healthCheck() async -> Bool {
        var req = URLRequest(url: WatchConfig.base.appendingPathComponent("api/health"))
        req.timeoutInterval = 2
        guard let (_, resp) = try? await WatchStore.session.data(for: req) else { return false }
        return (resp as? HTTPURLResponse)?.statusCode == 200
    }

    /* ---------------- 派生数据 ---------------- */

    var subtitle: String {
        if payload?.updating == true { return "正在更新…" }
        if let f = lastFetch {
            let c = Calendar.current.dateComponents([.hour, .minute], from: f)
            return String(format: "更新于 %02d:%02d", c.hour ?? 0, c.minute ?? 0)
        }
        return status.text
    }

    func statusColor(_ scheme: ColorScheme) -> Color {
        switch status {
        case .ok:                 return Theme.green.color(scheme, lift: 0.1)
        case .loading, .idle:     return Theme.amber.color(scheme, lift: 0.1)
        case .notLoggedIn:        return Theme.amber.color(scheme, lift: 0.1)
        case .offline:            return Theme.red.color(scheme, lift: 0.16)
        }
    }

    static func parse(_ s: String?) -> Date? { Derive.parse(s) }

    func groups(now: Date = Date()) -> (up: [TaskVM], od: [TaskVM]) {
        Derive.groups(payload, now: now)
    }

    /// 红 / 黄 / 蓝 三档各有几项（口径与菜单栏角标一致：逾期不计、绿档不计）
    var bandCounts: (red: Int, yellow: Int, blue: Int) { Derive.bandCounts(payload) }

    /// 最新出分的作业（服务端按截止时间从新到旧排好，这里取前 n 条）
    func recentWorks(_ n: Int = 8) -> [RecentVM] { Derive.recentWorks(payload, n) }

    func gpaRows() -> [GPARowModel] { Derive.gpaRows(payload) }

    var gpaSummary: (graded: Int, total: Int, avg: Double?) { Derive.gpaSummary(payload) }

    /* ---------------- 自检：把派生数据打印出来（MBWATCH_DUMP=1 启动时） ---------------- */

    func dumpSummary(now: Date = Date()) {
        let g = groups(now: now)
        WatchLog.dump("========== ManageBac Watch 数据自检 ==========")
        WatchLog.dump("服务状态: \(status.text)   更新于: \(subtitle)")
        WatchLog.dump("—— 待办（按剩余时间从少到多，共 \(g.up.count) 条）——")
        for t in g.up {
            let n: String
            switch t.band {
            case .urgent: n = "红"
            case .soon:   n = "黄"
            case .blue:   n = "蓝"
            case .ok:     n = "绿"
            case .over:   n = "逾期"
            }
            WatchLog.dump("  \(t.subject.padding(toLength: 4, withPad: " ", startingAt: 0)) [\(n)] \(t.leftText.padding(toLength: 16, withPad: " ", startingAt: 0)) | \(t.title.prefix(30))")
        }
        WatchLog.dump("—— 逾期（\(g.od.count) 条）——")
        for t in g.od { WatchLog.dump("  \(t.subject)  \(t.leftText)  | \(t.title.prefix(26))") }
        let c = bandCounts
        WatchLog.dump("—— 角标口径 —— 红 \(c.red) · 黄 \(c.yellow) · 蓝 \(c.blue)")
        WatchLog.dump("—— 最新成绩（前 8，按截止时间从新到旧）——")
        for w in recentWorks(8) {
            WatchLog.dump("  \(w.label.padding(toLength: 4, withPad: " ", startingAt: 0)) \(w.dueText.padding(toLength: 12, withPad: " ", startingAt: 0)) \(String(w.grade ?? "-").padding(toLength: 3, withPad: " ", startingAt: 0)) \(w.scoreText.padding(toLength: 14, withPad: " ", startingAt: 0)) | \(w.title.prefix(26))")
        }
        let dl = Schedule.dayList(now)
        WatchLog.dump("—— 课堂（\(Schedule.dayCaption(dl.day, now: now))）——")
        let cur = Schedule.currentSlot(now)?.blockId
        for s in dl.list {
            let two = s.span[1] > s.span[0] ? "‖" : " "
            WatchLog.dump("  \(two) P\(s.span[0])–P\(s.span[1])  \(fmtClock(s.start))–\(fmtClock(s.end))  \(s.subject)\(s.blockId == cur ? "   ← 进行中" : "")")
        }
        WatchLog.dump("—— 顶部计时 —— \(Schedule.topTimer(now).label)")
        WatchLog.dump("—— GPA ——")
        for r in gpaRows() {
            let p = r.pct.map { fmtPct($0) } ?? "未出分"
            let f = r.pct.map { to4($0 / 100) + "/4.0" } ?? ""
            WatchLog.dump("  \(r.label.padding(toLength: 4, withPad: " ", startingAt: 0)) \(p.padding(toLength: 8, withPad: " ", startingAt: 0)) \(String(r.grade ?? "").padding(toLength: 3, withPad: " ", startingAt: 0)) \(f)")
        }
        let s = gpaSummary
        WatchLog.dump("均分 \(s.avg.map { fmtPct($0) } ?? "-")  (\(s.avg.map { to4($0 / 100) } ?? "-")/4.0)  \(s.graded)/\(s.total) 门")
        WatchLog.dump("=============================================")
    }
}
