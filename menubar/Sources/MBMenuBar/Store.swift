import Foundation
import Observation
import SwiftUI

enum Log {
    static let url = URL(fileURLWithPath: "/tmp/mbmenubar.log")

    static func write(_ text: String) {
        let line = "\(ISO8601DateFormatter().string(from: Date()))  \(text)\n"
        guard let data = line.data(using: .utf8) else { return }
        if let h = try? FileHandle(forWritingTo: url) {
            h.seekToEndOfFile()
            h.write(data)
            try? h.close()
        } else {
            try? data.write(to: url)
        }
    }
}

/* 面板上一条待办长条的数据 */
struct TaskVM: Identifiable {
    let id: String
    let title: String
    let subject: String
    let fullSubject: String
    let leftText: String
    let band: Band
    let url: URL
    let isOver: Bool
    let created: Date?
    let due: Date?
}

/* GPA 一行 */
struct GPARow: Identifiable {
    let id: String
    let label: String
    let rgb: RGB
    let pct: Double?
    let grade: String?
    let url: URL?
}

@MainActor
@Observable
final class Store {
    enum Status: Equatable {
        case idle, loading, ok, notLoggedIn, offline(String)

        var text: String {
            switch self {
            case .idle:            return "准备中"
            case .loading:         return "读取中…"
            case .ok:              return "数据已就绪"
            case .notLoggedIn:     return "登录已失效"
            case .offline(let m):  return "本地服务未运行"
            }
        }
    }

    var status: Status = .idle
    var payload: Payload?
    var lastFetch: Date?
    var busy = false

    static let base = URL(string: "http://127.0.0.1:8765")!
    static let manageBac = "https://beijing101.managebac.cn"
    static let dashboard = base.appendingPathComponent("app")

    static let session: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        // 关掉系统代理，否则 127.0.0.1 可能被代理拦掉
        c.connectionProxyDictionary = [
            "HTTPEnable": 0, "HTTPProxy": "", "HTTPPort": 0,
            "HTTPSEnable": 0, "HTTPSProxy": "", "HTTPSPort": 0,
            "ProxyAutoConfigEnable": 0, "SOCKSEnable": 0,
        ]
        c.timeoutIntervalForRequest = 25
        return URLSession(configuration: c)
    }()

    /* ---------------- 生命周期 ---------------- */

    func start() async {
        if payload == nil { await load() }
    }

    func load(force: Bool = false) async {
        if busy { return }
        busy = true
        if payload == nil { status = .loading }
        Log.write("load start (force=\(force))")

        if !(await healthy()) {
            Log.write("service down → 拉起 bridge.py")
            launchService()
            for _ in 0..<24 {
                if await healthy() { break }
                try? await Task.sleep(nanoseconds: 500_000_000)
            }
        }

        do {
            let p = try await fetchPayload()
            apply(p)
            Log.write("load ok tasks=\(p.tasks?.count ?? 0) classes=\(p.classes?.count ?? 0) updating=\(p.updating ?? false)")
            if p.updating == true { await waitForFresh() }
        } catch {
            status = .offline(error.localizedDescription)
            Log.write("load fail: \(error.localizedDescription)")
        }
        busy = false
    }

    private func apply(_ p: Payload) {
        payload = p
        lastFetch = Date()
        status = (p.loggedIn == false) ? .notLoggedIn : .ok
    }

    private func fetchPayload() async throws -> Payload {
        var req = URLRequest(url: Store.base.appendingPathComponent("api/data"))
        req.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        let (data, resp) = try await Store.session.data(for: req)
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
                Log.write("fresh data arrived")
                return
            }
        }
    }

    private func healthy() async -> Bool {
        var req = URLRequest(url: Store.base.appendingPathComponent("api/health"))
        req.timeoutInterval = 2
        guard let (_, resp) = try? await Store.session.data(for: req) else { return false }
        return (resp as? HTTPURLResponse)?.statusCode == 200
    }

    /// 只拉数据、不等待（预览渲染用）
    func loadBlocking() {
        let sem = DispatchSemaphore(value: 0)
        var got: Payload?
        var req = URLRequest(url: Store.base.appendingPathComponent("api/data"))
        req.timeoutInterval = 30
        Store.session.dataTask(with: req) { data, _, _ in
            if let data { got = try? JSONDecoder().decode(Payload.self, from: data) }
            sem.signal()
        }.resume()
        _ = sem.wait(timeout: .now() + 35)
        if let g = got { apply(g) }
    }

    /* ---------------- 找 Python ----------------
       不写死某个用户名下的绝对路径（那样别人 clone 下来直接跑不起来，
       而且会把用户名泄进仓库）。按「环境变量 → WorkBuddy 托管 → 系统」三级找。 */

    private static func findPython() -> String {
        let fm = FileManager.default
        var candidates: [String] = []
        if let managed = fm.homeDirectoryForCurrentUser
            .appendingPathComponent(".workbuddy/binaries/python/envs/default/bin/python").path as String? {
            candidates.append(managed)
        }
        // WorkBuddy 托管的多版本目录：~/.workbuddy/binaries/python/versions/*/bin/python3
        let versions = fm.homeDirectoryForCurrentUser
            .appendingPathComponent(".workbuddy/binaries/python/versions")
        if let list = try? fm.contentsOfDirectory(atPath: versions.path) {
            for v in list.sorted().reversed() {
                candidates.append(versions.appendingPathComponent(v)
                    .appendingPathComponent("bin/python3").path)
            }
        }
        candidates.append("/opt/homebrew/bin/python3")
        candidates.append("/usr/local/bin/python3")
        candidates.append("/usr/bin/python3")
        return candidates.first { fm.isExecutableFile(atPath: $0) } ?? "/usr/bin/python3"
    }

    /* ---------------- 拉起本机服务 ---------------- */

    private func launchService() {
        // 路径一律走 $HOME 推导，不写死用户名 —— 别人 clone 下来也能跑。
        let py = ProcessInfo.processInfo.environment["MBB_PYTHON"]
            ?? Self.findPython()
        let bridge = (ProcessInfo.processInfo.environment["MBB_HOME"]
            ?? (NSHomeDirectory() as NSString).appendingPathComponent(".mbboard"))
            + "/bridge.py"
        guard FileManager.default.isExecutableFile(atPath: py),
              FileManager.default.fileExists(atPath: bridge) else {
            Log.write("launch skipped: python/bridge 不存在")
            return
        }
        let logPath = "/tmp/mbboard.log"
        if !FileManager.default.fileExists(atPath: logPath) {
            FileManager.default.createFile(atPath: logPath, contents: nil)
        }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: py)
        p.arguments = [bridge]
        var env = ProcessInfo.processInfo.environment
        env["MBBOARD_IDLE"] = "600"
        p.environment = env
        if let h = FileHandle(forWritingAtPath: logPath) {
            p.standardOutput = h
            p.standardError = h
        }
        do {
            try p.run()
            Log.write("bridge.py 已启动 pid=\(p.processIdentifier)")
        } catch {
            Log.write("bridge.py 启动失败: \(error.localizedDescription)")
        }
    }

    /* ---------------- 派生数据 ---------------- */

    var subtitle: String {
        switch status {
        case .ok, .notLoggedIn:
            if let f = lastFetch {
                let c = Calendar.current.dateComponents([.hour, .minute], from: f)
                return "更新于 \(String(format: "%02d:%02d", c.hour ?? 0, c.minute ?? 0))"
            }
            return status.text
        default:
            return status.text
        }
    }

    func statusColor(_ scheme: ColorScheme) -> Color {
        switch status {
        case .ok:          return Theme.green.color(scheme, lift: 0.1)
        case .loading, .idle: return Theme.amber.color(scheme, lift: 0.1)
        case .notLoggedIn: return Theme.amber.color(scheme, lift: 0.1)
        case .offline:     return Theme.red.color(scheme, lift: 0.16)
        }
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

    func groups(now: Date = Date()) -> (up: [TaskVM], od: [TaskVM]) {
        guard let list = payload?.tasks else { return ([], []) }
        let nowMs = now.timeIntervalSince1970 * 1000
        var up: [TaskVM] = []
        var od: [TaskVM] = []

        for t in list {
            let title = t.title ?? ""
            if title.contains("背诵视频") { continue }

            let due = Store.parse(t.due)
            let created = Store.parse(t.created)
            let leftMs = due.map { $0.timeIntervalSince1970 * 1000 - nowMs }
            let isOver = (t.view == "overdue") || (leftMs.map { $0 < 0 } ?? false)

            let leftText: String
            if isOver {
                leftText = due.map { "已逾期 " + humanLeft(nowMs - $0.timeIntervalSince1970 * 1000) } ?? "已逾期"
            } else {
                leftText = leftMs.map { "剩 " + humanLeft($0) } ?? "未设置截止"
            }

            let raw = t.url ?? ""
            guard let url = URL(string: Store.manageBac + raw) else { continue }

            let vm = TaskVM(
                id: t.id, title: title,
                subject: Subject.short(t.subject), fullSubject: t.subject ?? "",
                leftText: leftText, band: bandOf(leftMs: leftMs, isOver: isOver),
                url: url, isOver: isOver, created: created, due: due)

            if isOver { od.append(vm) } else { up.append(vm) }
        }

        up.sort { ($0.created?.timeIntervalSince1970 ?? 0) > ($1.created?.timeIntervalSince1970 ?? 0) }
        od.sort { ($0.due?.timeIntervalSince1970 ?? 0) > ($1.due?.timeIntervalSince1970 ?? 0) }
        return (up, od)
    }

    func gpaRows() -> [GPARow] {
        let list = payload?.classes ?? []
        return list.map { c in
            let key = c.key ?? Subject.key(c.label ?? "")
            let rgb = Subject.colors[key] ?? Theme.ink3
            let href = c.url.map { Store.manageBac + $0 }
            return GPARow(id: c.id,
                          label: c.label ?? "—",
                          rgb: rgb,
                          pct: c.overall?.pct,
                          grade: c.overall?.mark,
                          url: href.flatMap { URL(string: $0) })
        }
    }

    var gpaSummary: (graded: Int, total: Int, avg: Double?) {
        let rows = gpaRows()
        let graded = rows.compactMap { $0.pct }
        let avg = graded.isEmpty ? nil : graded.reduce(0, +) / Double(graded.count)
        return (graded.count, rows.count, avg)
    }
}
