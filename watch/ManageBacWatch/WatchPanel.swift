//  WatchPanel.swift
//  ManageBac Watch App —— 手表界面
//  新建文件（菜单栏版 Panel.swift 未改动）。
//
//  自上而下（与菜单栏面板同序）：
//   ① 顶栏（📂 ManageBac · 更新于 · 状态点）
//   ② 大计时卡（上课→距下课；课间→距上课 + 本次休息多久/已过多久）—— 秒级
//   ③ 待办事项（按剩余时间从少到多；色条 + 中文科目 + 作业名 + 剩余时间胶囊；逾期折叠）
//   ④ 接下来的课堂（整日课表；连堂合并且行首双竖条；正在进行的那节高亮；「现在」横条）
//   ⑤ 最新成绩（最近出分 8 项，方块网格）
//   ⑥ GPA 总览（默认折叠；展开才显示总均分）
//   ⑦ 底部刷新 + 状态
//
//  架构：派生数据一律从 WatchVM 取（按分钟+数据版本记忆化，不再每秒重算）；
//        秒级的倒计时由 WatchTimerCard 自己订阅 WatchTick，不牵连整屏。
//        卡片材质全部是 watchOS 26 的原生液态玻璃，见 WatchTheme。
//
//  手表上无法打开网页（没有浏览器），所以待办/成绩都不做点击跳转，
//  交互只保留：逾期展开、GPA 展开、手动刷新。

import SwiftUI

struct WatchRootView: View {
    @Environment(\.colorScheme) private var scheme
    @Environment(\.isLuminanceReduced) private var dimmed
    @ObservedObject var store: WatchStore
    @ObservedObject var vm: WatchVM
    @ObservedObject var tick: WatchTick

    @State private var gpaOpen = WatchDump.gpaExpanded
    @State private var overdueOpen = false
    @State private var refreshing = false

    @MainActor
    init(store: WatchStore? = nil, vm: WatchVM? = nil, tick: WatchTick? = nil) {
        let s = store ?? WatchStore.shared
        _store = ObservedObject(wrappedValue: s)
        _vm = ObservedObject(wrappedValue: vm ?? WatchVM.shared)
        _tick = ObservedObject(wrappedValue: tick ?? WatchTick.shared)
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: WatchMetrics.gap) {
                    header
                    WatchTimerCard(tick: tick, coarseNow: vm.now, scheme: scheme)
                        .id("timer")
                    todoSection.id("todo")
                    classSection.id("class")
                    latestSection.id("latest")
                    gpaSection.id("gpa")
                    footer.id("footer")
                }
                .padding(.horizontal, WatchMetrics.pad)
                .padding(.top, 2)
                .padding(.bottom, 12)
            }
            .background {
                LinearGradient(colors: [Color.black.opacity(scheme == .dark ? 0.0 : 0.05),
                                        Color.black.opacity(scheme == .dark ? 0.0 : 0.10)],
                               startPoint: .top, endPoint: .bottom)
                    .ignoresSafeArea()
            }
            .onAppear {
                vm.start()
                tick.begin(luminanceReduced: dimmed)
                Task {
                    await store.load()
                    vm.refreshIfNeeded(force: true)
                    if WatchDump.isOn { store.dumpSummary(now: vm.now) }
                }
                store.begin()
                WatchDump.applyScroll(proxy)
            }
            // 数据到了就立刻重算，不等心跳（payload.fetchedAt 是服务端盖的时间戳）
            .onChange(of: store.payload?.fetchedAt) { _, _ in vm.refreshIfNeeded() }
            // 抬腕变亮 / 落腕变暗：变暗时停掉秒表，省电也不闪
            .onChange(of: dimmed) { _, d in tick.begin(luminanceReduced: d) }
        }
    }

    /* ---------------- ① 顶栏 ---------------- */

    private var header: some View {
        HStack(spacing: 5) {
            Text("📂").font(.system(size: WatchMetrics.fs(13)))
            Text("ManageBac")
                .font(.system(size: WatchMetrics.fs(12.5), weight: .semibold))
            Spacer(minLength: 3)
            Circle()
                .fill(store.statusColor(scheme))
                .frame(width: 6, height: 6)
            Text(store.subtitle)
                .font(.system(size: WatchMetrics.fs(10)))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .padding(.horizontal, 2)
    }

    /* ---------------- ③ 待办 ---------------- */

    private var todoSection: some View {
        let up = vm.up, od = vm.od
        let bands = vm.bands
        let extra = bands.red + bands.yellow + bands.blue
        return VStack(alignment: .leading, spacing: 5) {
            WatchSectionHead("待办事项",
                             right: "\(up.count) 项待完成"
                                  + (od.isEmpty ? "" : " · \(od.count) 逾期")
                                  + (extra == 0 ? "" : " · 急 \(extra)"))

            if up.isEmpty && od.isEmpty {
                emptyRow(todoEmptyHint)
            } else {
                CardStack(spacing: WatchMetrics.box(5)) {
                    ForEach(up) { t in WatchTaskBar(t: t, scheme: scheme) }
                }
            }

            if !od.isEmpty {
                Button {
                    withAnimation(.snappy(duration: 0.22)) { overdueOpen.toggle() }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: WatchMetrics.fs(9)))
                            .foregroundStyle(Theme.red.color(scheme, lift: 0.18))
                        Text("已逾期 \(od.count) 项")
                            .font(.system(size: WatchMetrics.fs(11), weight: .medium))
                            .foregroundStyle(.secondary)
                        Spacer(minLength: 3)
                        Image(systemName: overdueOpen ? "chevron.up" : "chevron.down")
                            .font(.system(size: WatchMetrics.fs(8), weight: .bold))
                            .foregroundStyle(.tertiary)
                    }
                    .padding(.horizontal, WatchMetrics.innerX)
                    .frame(height: WatchMetrics.box(27))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(.rect(cornerRadius: 10))
                }
                .buttonStyle(.plain)
                .watchCard(RoundedRectangle(cornerRadius: WatchMetrics.cardRadius - 3, style: .continuous),
                           interactive: true)

                if overdueOpen {
                    CardStack(spacing: WatchMetrics.box(5)) {
                        ForEach(od) { t in WatchTaskBar(t: t, scheme: scheme) }
                    }
                }
            }
        }
    }

    /* ---------------- ④ 接下来的课堂（整日） ---------------- */

    private var classSection: some View {
        let dl = vm.day
        let cur = Schedule.currentSlot(vm.now)
        let curBlock = cur?.blockId
        // 「现在」横条插在「已经上完的课」之后（正在进行的那节的正上方）；
        // 只有当前时间落在第一节课之前 / 最后一节课之后才隐藏。
        let nowIdx: Int? = {
            guard Calendar.current.isDate(dl.day, inSameDayAs: vm.now),
                  let first = dl.list.first, let last = dl.list.last,
                  vm.now >= first.start, vm.now < last.end else { return nil }
            return dl.list.filter { $0.end <= vm.now }.count
        }()
        return VStack(alignment: .leading, spacing: 5) {
            WatchSectionHead("接下来的课堂", right: Schedule.dayCaption(dl.day, now: vm.now))

            CardStack(spacing: WatchMetrics.box(5)) {
                ForEach(Array(dl.list.enumerated()), id: \.element.id) { i, s in
                    if nowIdx == i {
                        WatchNowBar(tick: tick, coarseNow: vm.now, cur: cur, scheme: scheme)
                    }
                    WatchClassRow(slot: s,
                                  isNow: curBlock != nil && s.blockId == curBlock,
                                  scheme: scheme)
                }
            }
        }
    }

    /* ---------------- ⑤ 最新成绩（最近出分 8 项） ---------------- */

    private var latestSection: some View {
        let rows = vm.recent
        return VStack(alignment: .leading, spacing: 5) {
            WatchSectionHead("最新成绩", right: rows.isEmpty ? "" : "最近出分 \(rows.count) 项")

            if rows.isEmpty {
                emptyRow(latestEmptyHint)
            } else {
                GlassEffectContainer(spacing: WatchMetrics.box(6)) {
                    LazyVGrid(columns: [GridItem(.flexible(), spacing: WatchMetrics.box(6)),
                                        GridItem(.flexible(), spacing: WatchMetrics.box(6))],
                              spacing: WatchMetrics.box(6)) {
                        ForEach(rows) { w in WatchLatestCard(w: w, scheme: scheme) }
                    }
                }
            }
        }
    }

    /* ---------------- ⑥ GPA 总览（默认折叠） ---------------- */

    private var gpaSection: some View {
        let rows = vm.gpaRows
        let sm = vm.gpa
        return VStack(alignment: .leading, spacing: 5) {
            WatchSectionHead("GPA 总览", right: "\(sm.graded)/\(sm.total) 门已出分")

            Button {
                withAnimation(.snappy(duration: 0.22)) { gpaOpen.toggle() }
            } label: {
                HStack(spacing: 6) {
                    if gpaOpen {
                        if let avg = sm.avg {
                            Text(fmtPct(avg))
                                .font(.system(size: WatchMetrics.fs(14), weight: .bold, design: .rounded))
                                .monospacedDigit()
                                .foregroundStyle(Theme.accent.color(scheme, lift: 0.22))
                                .fixedSize()
                            Text("\(to4(avg / 100)) / 4.0")
                                .font(.system(size: WatchMetrics.fs(10.5), weight: .semibold))
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                                .fixedSize()
                        } else {
                            Text("暂无成绩").font(.system(size: WatchMetrics.fs(11))).foregroundStyle(.tertiary)
                        }
                    } else {
                        Text("查看各科分数与 4 分制折算")
                            .font(.system(size: WatchMetrics.fs(11)))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .minimumScaleFactor(0.75)
                    }
                    Spacer(minLength: 3)
                    HStack(spacing: 3) {
                        Text(gpaOpen ? "收起" : "展开")
                            .font(.system(size: WatchMetrics.fs(10.5), weight: .semibold))
                        Image(systemName: gpaOpen ? "chevron.up" : "chevron.down")
                            .font(.system(size: WatchMetrics.fs(8), weight: .bold))
                    }
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 7)
                    .frame(height: WatchMetrics.box(20))
                    .background(Capsule().fill(Color.primary.opacity(0.09)))
                    .fixedSize()
                }
                .padding(.horizontal, WatchMetrics.innerX)
                .frame(height: WatchMetrics.box(gpaOpen ? 38 : 31))
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(.rect(cornerRadius: 10))
            }
            .buttonStyle(.plain)
            .watchCard(RoundedRectangle(cornerRadius: WatchMetrics.cardRadius - 3, style: .continuous),
                       interactive: true)

            if gpaOpen {
                CardStack(spacing: WatchMetrics.box(4)) {
                    ForEach(rows) { r in WatchGPARow(r: r, scheme: scheme) }
                }
            }
        }
    }

    /* ---------------- ⑦ 底部：刷新 + 状态 ---------------- */

    private var footer: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button {
                Task {
                    refreshing = true
                    await store.load(force: true)
                    vm.refreshIfNeeded(force: true)
                    refreshing = false
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: WatchMetrics.fs(11), weight: .semibold))
                        .foregroundStyle(.secondary)
                    Text(refreshing ? "正在刷新…" : "立即刷新")
                        .font(.system(size: WatchMetrics.fs(11.5), weight: .semibold))
                    Spacer(minLength: 3)
                    Text(store.status.text)
                        .font(.system(size: WatchMetrics.fs(9.5)))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                }
                .padding(.horizontal, WatchMetrics.innerX)
                .frame(height: WatchMetrics.box(29))
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(.rect(cornerRadius: 10))
            }
            .buttonStyle(.plain)
            .watchCard(RoundedRectangle(cornerRadius: WatchMetrics.cardRadius - 3, style: .continuous),
                       tint: Color(.sRGB, red: 0.0, green: 0.44, blue: 1.0, opacity: 0.24),
                       interactive: true)

            Text("数据来自电脑上的 ManageBac 看板桥接服务 · 每 5 分钟自动更新")
                .font(.system(size: WatchMetrics.fs(9)))
                .foregroundStyle(.tertiary)
                .lineLimit(2)
                .padding(.horizontal, 2)
        }
    }

    /* 空状态提示：连不上电脑上的服务时要说清楚，别一直显示「正在读取」 */

    private var isOffline: Bool {
        if case .offline = store.status { return true }
        return false
    }

    private var todoEmptyHint: String {
        if isOffline { return "连不上电脑上的看板服务" }
        return store.payload == nil ? "正在读取…" : "暂无待办"
    }

    private var latestEmptyHint: String {
        if isOffline { return "连不上电脑上的看板服务" }
        return store.payload == nil ? "正在读取…" : "暂无已评分作业"
    }

    private func emptyRow(_ text: String) -> some View {
        Text(text)
            .font(.system(size: WatchMetrics.fs(11)))
            .foregroundStyle(.tertiary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, WatchMetrics.innerX)
            .frame(height: WatchMetrics.box(33))
            .watchCard(RoundedRectangle(cornerRadius: WatchMetrics.cardRadius - 3, style: .continuous))
    }
}
