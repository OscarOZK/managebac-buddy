//  WatchVM.swift
//  ManageBac Watch App —— 面板状态（架构中枢）
//  新建文件（菜单栏版 Store/Panel 未改动）。
//
//  为什么要有这一层：
//   ① 派生数据别每秒重算。待办的 ISO 时间解析、GPA 汇总、整日课表都是「分钟级」信息，
//      原来面板每 1 秒整体重评一次 body，等于每秒把 ISO8601DateFormatter 跑几十遍 —— 手表上很费电。
//      现在按「分钟 + 数据版本」做指纹，指纹没变就直接复用上次结果。
//   ② 秒级的东西只喂给秒级的视图。倒计时每秒都在动，但它只出现在大计时卡里，
//      所以单开一个 WatchTick 让那张卡自己订阅；整屏其余部分按 10 秒心跳走。
//   ③ 变暗（Always-On、抬腕前）时不跑秒表：屏幕都暗了，秒针没意义，还费电。
//
//  派生算法本身仍写在 WatchDerive.swift（与小组件共用同一份），这里只管「什么时候算」。

import Foundation
import SwiftUI

/* ============================================================
   秒级时钟：只喂给「大计时卡」和「现在横条」
   用 Task 循环而不是 Combine Timer —— 与 WatchStore 的取数循环同一套写法，
   整条链路都在主线程上，不牵扯跨线程跳转。
   ============================================================ */
@MainActor
final class WatchTick: ObservableObject {
    static let shared = WatchTick()

    @Published private(set) var now: Date
    private var loop: Task<Void, Never>?

    private init() {
        now = WatchDump.pinnedNow ?? Date()
    }

    /// 只在屏幕亮着（非变暗）时跑秒表
    func begin(luminanceReduced: Bool) {
        stop()
        guard !luminanceReduced, WatchDump.pinnedNow == nil else { return }
        loop = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                self?.now = Date()
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }
    }

    func stop() {
        loop?.cancel()
        loop = nil
    }
}

/* ============================================================
   面板视图模型：派生数据 + 面板级心跳（10 秒）
   ============================================================ */
@MainActor
final class WatchVM: ObservableObject {
    static let shared = WatchVM(store: .shared)

    /// 面板级「现在」：10 秒一跳（分钟级信息足够准，比原来每秒重算省 10 倍）
    @Published private(set) var now: Date
    /// 待完成（按剩余时间从少到多）
    @Published private(set) var up: [TaskVM] = []
    /// 逾期（最近刚逾期在前）
    @Published private(set) var od: [TaskVM] = []
    /// 红 / 黄 / 蓝（口径与菜单栏角标一致）
    @Published private(set) var bands: (red: Int, yellow: Int, blue: Int) = (0, 0, 0)
    /// 最新成绩（最多 8 格）
    @Published private(set) var recent: [RecentVM] = []
    @Published private(set) var gpaRows: [GPARowModel] = []
    @Published private(set) var gpa: (graded: Int, total: Int, avg: Double?) = (0, 0, nil)
    /// 整日课表（连堂已合并）
    @Published private(set) var day: (day: Date, list: [Schedule.Slot]) = (Date(), [])
    /// 自检：重算了几次（MBWATCH_DUMP=1 时打日志）
    @Published private(set) var rebuilds = 0

    let store: WatchStore
    private var stamp = ""
    private var loop: Task<Void, Never>?

    init(store: WatchStore) {
        self.store = store
        self.now = WatchDump.pinnedNow ?? Date()
    }

    /* ---------------- 生命周期 ---------------- */

    /// 立刻算一次，然后每 10 秒一跳
    func start() {
        refreshIfNeeded(force: true)
        guard loop == nil, WatchDump.pinnedNow == nil else { return }
        loop = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 10_000_000_000)
                guard let self else { return }
                self.now = Date()
                self.refreshIfNeeded()
            }
        }
    }

    /// 10 秒心跳（视图里也直接调它，用于「抽屉打开」这类需要立刻对齐的时刻）
    func beat(_ t: Date) {
        guard WatchDump.pinnedNow == nil else { return }
        now = t
        refreshIfNeeded()
    }

    func recentWorks(_ n: Int) -> [RecentVM] { Array(recent.prefix(n)) }

    /* ---------------- 指纹 & 重算 ---------------- */

    /// 指纹：分钟 + 服务端数据版本 + 各类条目数 + 连接状态。
    /// 全都没变 → 结果一定一样，直接复用，不再解析一遍时间戳。
    private var key: String {
        let p = store.payload
        let minute = Int(now.timeIntervalSince1970 / 60)
        return "\(minute)|\(p?.fetchedAt ?? -1)|\(p?.tasks?.count ?? -1)|"
             + "\(p?.classes?.count ?? -1)|\(p?.recent?.count ?? -1)|\(store.status)"
    }

    func refreshIfNeeded(force: Bool = false) {
        let k = key
        guard force || k != stamp else { return }
        stamp = k
        rebuild()
    }

    private func rebuild() {
        let p = store.payload

        let g = Derive.groups(p, now: now)
        up = g.up
        od = g.od

        // 红黄蓝三档直接在这一趟里数完，不再让 Derive 把待办重算一遍
        var r = 0, y = 0, b = 0
        for t in g.up {
            switch t.band {
            case .urgent: r += 1
            case .soon:   y += 1
            case .blue:   b += 1
            default:      break
            }
        }
        bands = (r, y, b)

        recent  = Derive.recentWorks(p, 8)
        gpaRows = Derive.gpaRows(p)
        gpa     = Derive.gpaSummary(p)
        day     = Schedule.dayList(now)

        rebuilds += 1
        if WatchDump.isOn {
            WatchLog.write("VM 重算 #\(rebuilds) · 待办 \(up.count)/逾期 \(od.count) · "
                         + "成绩 \(recent.count) · 课表 \(day.list.count) 节")
        }
    }
}
