//  本文件由 sync-shared.sh 从 ManageBacWatch/WatchDerive.swift 自动同步，请勿手改。

//  WatchDerive.swift
//  ManageBac —— 派生数据（待办分组/排序、紧急度计数、最新成绩、GPA）
//
//  从 WatchStore.swift 里抽出来，单独一个文件：
//  这样 watchOS 的 widget extension（在 ManageBacWatchWidgets/ 里）能用**同一份代码**算出
//  与 App 完全一致的结果（widget 是独立进程，不能共享 App 的内存对象，但可以共享源码）。
//  build.sh 会把本文件同步成 ManageBacWatchWidgets/WidgetDerive.swift。
//
//  纯函数，无 UI 依赖，可在任意进程/平台上跑。

import Foundation

/* 面板上一条待办长条的数据 */
struct TaskVM: Identifiable {
    let id: String
    let title: String
    let subject: String
    let fullSubject: String
    let leftText: String
    let band: Band
    let isOver: Bool
    let created: Date?
    let due: Date?
}

/* GPA 一行 */
struct GPARowModel: Identifiable {
    let id: String
    let label: String
    let rgb: RGB
    let pct: Double?
    let grade: String?
}

/* 「最新成绩」里的一格 */
struct RecentVM: Identifiable {
    let id: String
    let label: String
    let rgb: RGB
    let title: String
    let due: Date?
    let dueText: String
    let grade: String?
    let scoreText: String
    let good: Bool
}

enum Derive {

    /* ---------------- 时间解析 ---------------- */

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

    /* ---------------- 待办 ---------------- */

    /// 待完成（按剩余时间从少到多） + 逾期（最近刚逾期在前）
    static func groups(_ payload: Payload?, now: Date = Date()) -> (up: [TaskVM], od: [TaskVM]) {
        guard let list = payload?.tasks else { return ([], []) }
        let nowMs = now.timeIntervalSince1970 * 1000
        var up: [TaskVM] = []
        var od: [TaskVM] = []

        for t in list {
            let title = t.title ?? ""
            if title.contains("背诵视频") { continue }   // 用户要求：语文背诵视频不显示

            let due = parse(t.due)
            let created = parse(t.created)
            let leftMs = due.map { $0.timeIntervalSince1970 * 1000 - nowMs }
            let isOver = (t.view == "overdue") || (leftMs.map { $0 < 0 } ?? false)

            let leftText: String
            if isOver {
                leftText = due.map { "已逾期 " + humanLeft(nowMs - $0.timeIntervalSince1970 * 1000) } ?? "已逾期"
            } else {
                leftText = leftMs.map { "剩 " + humanLeft($0) } ?? "未设置截止"
            }

            let vm = TaskVM(
                id: t.id, title: title,
                subject: Subject.label(t.subject), fullSubject: t.subject ?? "",
                leftText: leftText, band: bandOf(leftMs: leftMs, isOver: isOver),
                isOver: isOver, created: created, due: due)

            if isOver { od.append(vm) } else { up.append(vm) }
        }

        // 待完成：按剩余时间从少到多（越急越靠上）
        up.sort { a, b in
            let x = a.due?.timeIntervalSince1970 ?? .greatestFiniteMagnitude
            let y = b.due?.timeIntervalSince1970 ?? .greatestFiniteMagnitude
            if x == y { return a.subject < b.subject }
            return x < y
        }
        // 逾期：最近刚逾期的排前面
        od.sort { ($0.due?.timeIntervalSince1970 ?? 0) > ($1.due?.timeIntervalSince1970 ?? 0) }
        return (up, od)
    }

    /// 红 / 黄 / 蓝 三档各有几项（口径与菜单栏角标一致：逾期不计、绿档不计）
    static func bandCounts(_ payload: Payload?, now: Date = Date()) -> (red: Int, yellow: Int, blue: Int) {
        var r = 0, y = 0, b = 0
        for t in groups(payload, now: now).up {
            switch t.band {
            case .urgent: r += 1
            case .soon:   y += 1
            case .blue:   b += 1
            default:      break
            }
        }
        return (r, y, b)
    }

    /* ---------------- 最新成绩 ---------------- */

    /// 最新出分的作业（服务端按截止时间从新到旧排好，这里取前 n 条）
    static func recentWorks(_ payload: Payload?, _ n: Int = 8) -> [RecentVM] {
        guard let list = payload?.recent else { return [] }
        return list.prefix(n).map { w in
            let key = w.key ?? Subject.key(w.label ?? "")
            let rgb = Subject.colors[key] ?? Theme.ink3
            let g = (w.grade ?? "").trimmingCharacters(in: .whitespaces)
            let due = parse(w.due)
            return RecentVM(
                id: w.id,
                label: w.label ?? "—",
                rgb: rgb,
                title: (w.title ?? "").isEmpty ? "作业" : (w.title ?? ""),
                due: due,
                dueText: due.map(shortDueDate) ?? shortDue(w.dueText),
                grade: g.isEmpty ? nil : g,
                scoreText: w.scoreText ?? "",
                good: !(g.hasPrefix("C") || g.hasPrefix("D") || g.hasPrefix("F")))
        }
    }

    /* ---------------- GPA ---------------- */

    static func gpaRows(_ payload: Payload?) -> [GPARowModel] {
        let list = payload?.classes ?? []
        return list.map { c in
            let key = c.key ?? Subject.key(c.label ?? "")
            let rgb = Subject.colors[key] ?? Theme.ink3
            return GPARowModel(id: c.id,
                               label: c.label ?? "—",
                               rgb: rgb,
                               pct: c.overall?.pct,
                               grade: c.overall?.mark)
        }
    }

    static func gpaSummary(_ payload: Payload?) -> (graded: Int, total: Int, avg: Double?) {
        let rows = gpaRows(payload)
        let graded = rows.compactMap { $0.pct }
        let avg = graded.isEmpty ? nil : graded.reduce(0, +) / Double(graded.count)
        return (graded.count, rows.count, avg)
    }
}
