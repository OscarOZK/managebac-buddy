//  WatchCards.swift
//  ManageBac Watch App —— 面板上的各类卡片
//  新建文件（从 WatchPanel.swift 里拆出来，菜单栏版未受影响）。
//
//  拆开的原因：卡片是「重评频率不同」的几组视图 ——
//    · WatchTimerCard / WatchNowBar  —— 秒级（倒计时、现在时间）
//    · WatchTaskBar / WatchClassRow / WatchLatestCard / WatchGPARow —— 分钟级
//  分开之后秒级的刷新只波及它自己，不会带着一整列表重新算。
//
//  材质：全部走 WatchTheme 的原生液态玻璃（WatchCard）。可点的卡片传 interactive: true。

import SwiftUI

/* ============================================================
   ① 大计时卡（秒级）
   上课 → 距下课；课间 → 距上课 + 本次休息多久/已过多久；
   第一节课前 → 距第一节课；晚自习；22:30–06:00 → 好好休息
   ============================================================ */
struct WatchTimerCard: View {
    @ObservedObject var tick: WatchTick
    /// 变暗（Always-On）时用面板的粗粒度时间，不跑秒表
    let coarseNow: Date
    let scheme: ColorScheme

    @Environment(\.isLuminanceReduced) private var dimmed
    private var now: Date { dimmed ? coarseNow : tick.now }

    var body: some View {
        let tt = Schedule.topTimer(now)
        var big = "好好休息"
        var bigSize: CGFloat = 30
        var name = ""
        var right = ""
        var detail = ""
        var tint: Color? = nil

        switch tt {
        case .rest:
            bigSize = 22

        case .inClass(let s):
            big = hms(s.end.timeIntervalSince(now) * 1000)
            name = s.isFree ? "没有安排课程" : s.subject
            right = "\(s.pLabel) \(fmtClock(s.start))–\(fmtClock(s.end))"
            tint = RGB(s.hex).color(scheme, lift: 0.86,
                                    opacity: scheme == .dark ? 0.24 : 0.34)

        case .breakTime(let n, let since):
            big = hms(n.start.timeIntervalSince(now) * 1000)
            name = n.subject
            right = "\(n.pLabel) \(fmtClock(n.start))–\(fmtClock(n.end))"
            if let since {
                let gap = n.start.timeIntervalSince(since)
                let passed = now.timeIntervalSince(since)
                let h = Calendar.current.component(.hour, from: since)
                let head = gap / 60 >= 50 ? ((h >= 11 && h <= 14) ? "午休" : "大课间") : "课间"
                detail = "\(head)共 \(Int((gap / 60).rounded())) 分钟 · 已过 \(hms(passed * 1000).suffix(5))"
            }
            tint = Color(.sRGB, red: 0.0, green: 0.44, blue: 1.0, opacity: 0.30)

        case .studyEnd(let d):
            big = hms(d.timeIntervalSince(now) * 1000)
            name = "晚自习"
            right = "22:30 结束"

        case .studyStart(let d):
            big = hms(d.timeIntervalSince(now) * 1000)
            name = "晚自习"
            right = "18:30 开始"
        }

        return VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(tt.label)
                    .font(.system(size: WatchMetrics.fs(10), weight: .medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer(minLength: 2)
                if !right.isEmpty {
                    Text(right)
                        .font(.system(size: WatchMetrics.fs(9.5), weight: .medium))
                        .monospacedDigit()
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                        .fixedSize()
                }
            }
            Text(big)
                .font(.system(size: WatchMetrics.fs(bigSize), weight: .bold, design: .rounded))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.6)
                .contentTransition(.numericText(countsDown: true))
            if !name.isEmpty {
                Text(name)
                    .font(.system(size: WatchMetrics.fs(11.5), weight: .semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
            if !detail.isEmpty {
                Text(detail)
                    .font(.system(size: WatchMetrics.fs(9.5)))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
        }
        .padding(.horizontal, WatchMetrics.innerX)
        .padding(.vertical, WatchMetrics.box(9))
        .frame(maxWidth: .infinity, alignment: .leading)
        .watchCard(RoundedRectangle(cornerRadius: WatchMetrics.cardRadius + 2, style: .continuous),
                   tint: tint)
    }
}

/* ============================================================
   ② 「现在」横条：描边玻璃，标出「现在」落在课表的哪个位置（秒级）
   ============================================================ */
struct WatchNowBar: View {
    @ObservedObject var tick: WatchTick
    let coarseNow: Date
    let cur: Schedule.Slot?
    let scheme: ColorScheme

    @Environment(\.isLuminanceReduced) private var dimmed
    private var now: Date { dimmed ? coarseNow : tick.now }

    var body: some View {
        let c = RGB(cur?.hex ?? "#007aff").color(scheme, lift: 0.14)
        return HStack(spacing: 5) {
            Circle().fill(c).frame(width: 5, height: 5)
            Text("现在 \(fmtClock(now))")
                .font(.system(size: WatchMetrics.fs(10), weight: .bold))
                .monospacedDigit()
                .foregroundStyle(c)
                .fixedSize()
            Text(cur.map { "\($0.subject) · 进行中" } ?? "课间休息")
                .font(.system(size: WatchMetrics.fs(10)))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Spacer(minLength: 2)
        }
        .padding(.horizontal, WatchMetrics.innerX)
        .frame(height: WatchMetrics.box(23))
        .frame(maxWidth: .infinity, alignment: .leading)
        .watchCard(Capsule(), tint: c.opacity(0.30))
        .overlay(Capsule().stroke(c.opacity(0.60), lineWidth: 1))
    }
}

/* ============================================================
   ③ 待办：色条 + 中文科目 + 剩余时间胶囊（上行）/ 作业名（下行，尾截断）
   手表只有 208pt 宽，一行塞不下三样，所以作业名另起一行。
   ============================================================ */
struct WatchTaskBar: View {
    let t: TaskVM
    let scheme: ColorScheme

    var body: some View {
        let c = t.band.color(scheme)
        HStack(spacing: 7) {
            Capsule()
                .fill(c)
                .frame(width: 3.5, height: WatchMetrics.box(30))
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 4) {
                    Text(t.subject)
                        .font(.system(size: WatchMetrics.fs(12), weight: .semibold))
                        .lineLimit(1)
                        .fixedSize()
                    Spacer(minLength: 2)
                    Text(t.leftText)
                        .pill(c)
                }
                Text(t.title)
                    .font(.system(size: WatchMetrics.fs(10.5)))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        }
        .padding(.horizontal, WatchMetrics.innerX - 1)
        .padding(.vertical, WatchMetrics.box(5))
        .frame(maxWidth: .infinity, alignment: .leading)
        .watchCard(RoundedRectangle(cornerRadius: WatchMetrics.cardRadius - 2, style: .continuous))
    }
}

/* ============================================================
   ④ 课程行：竖条区（连堂画两根）+ 节次 + 学科 / 时间 · 教室
   ============================================================ */
struct WatchClassRow: View {
    let slot: Schedule.Slot
    var isNow: Bool = false
    let scheme: ColorScheme

    var body: some View {
        let pr = slot.span[0] == slot.span[1] ? "P\(slot.span[0])" : "P\(slot.span[0])–P\(slot.span[1])"
        let time = "\(fmtClock(slot.start))–\(fmtClock(slot.end))"
        let rgb = RGB(slot.hex)
        let isDouble = slot.span[1] > slot.span[0]      // 连堂 → 行首两根竖条
        let barW: CGFloat = isNow ? 4.5 : 3.2
        let barH: CGFloat = isNow ? 20 : 17
        let where_ = slot.isFree ? "没有安排课程"
                                : [slot.room, slot.teacher].filter { !$0.isEmpty }.joined(separator: " · ")

        return HStack(spacing: 7) {
            // 固定 10pt 竖条区，保证 P/时间两列在所有行都对齐
            HStack(spacing: 2) {
                Capsule().fill(rgb.color(scheme, lift: 0.12)).frame(width: barW, height: WatchMetrics.box(barH))
                if isDouble {
                    Capsule().fill(rgb.color(scheme, lift: 0.12)).frame(width: barW, height: WatchMetrics.box(barH))
                }
                Spacer(minLength: 0)
            }
            .frame(width: 10)

            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 5) {
                    Text(pr)
                        .font(.system(size: WatchMetrics.fs(9.5), weight: .semibold))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .fixedSize()
                    Text(slot.subject)
                        .font(.system(size: WatchMetrics.fs(11.5), weight: isNow ? .semibold : .medium))
                        .foregroundStyle(slot.isFree ? Color.secondary : Color.primary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                HStack(spacing: 5) {
                    Text(time)
                        .font(.system(size: WatchMetrics.fs(9.5)))
                        .monospacedDigit()
                        .foregroundStyle(.tertiary)
                        .fixedSize()
                    if isNow {
                        Text("进行中")
                            .font(.system(size: WatchMetrics.fs(9), weight: .bold))
                            .foregroundStyle(rgb.color(scheme, lift: 0.16))
                            .lineLimit(1)
                            .fixedSize()
                    } else {
                        Text(where_)
                            .font(.system(size: WatchMetrics.fs(9.5)))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, WatchMetrics.innerX - 1)
        .padding(.vertical, WatchMetrics.box(5))
        .frame(maxWidth: .infinity, alignment: .leading)
        .watchCard(RoundedRectangle(cornerRadius: WatchMetrics.cardRadius - 2, style: .continuous),
                   tint: isNow ? RGB(slot.hex).color(scheme, lift: 0.86,
                                                    opacity: scheme == .dark ? 0.24 : 0.34) : nil)
    }
}

/* ============================================================
   ⑤ 最新成绩方块：科目 + 等级（上行）/ 作业名 / 截止 + 分数
   ============================================================ */
struct WatchLatestCard: View {
    let w: RecentVM
    let scheme: ColorScheme

    var body: some View {
        let c = w.rgb.color(scheme, lift: 0.18)
        let scoreColor = w.good ? Theme.green.color(scheme, lift: 0.10)
                                : Theme.amber.color(scheme, lift: 0.10)

        return VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 3) {
                Text(w.label)
                    .font(.system(size: WatchMetrics.fs(9.5), weight: .bold))
                    .foregroundStyle(c)
                    .lineLimit(1)
                    .fixedSize()
                Spacer(minLength: 2)
                if let g = w.grade {
                    Text(g)
                        .font(.system(size: WatchMetrics.fs(10.5), weight: .bold))
                        .foregroundStyle(scoreColor)
                        .fixedSize()
                }
            }

            Text(w.title)
                .font(.system(size: WatchMetrics.fs(10), weight: .semibold))
                .foregroundStyle(.primary)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
                .truncationMode(.tail)
                .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: 0)

            Text(w.dueText)
                .font(.system(size: WatchMetrics.fs(8.5)))
                .monospacedDigit()
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)

            Text(w.scoreText)
                .font(.system(size: WatchMetrics.fs(10), weight: .semibold))
                .monospacedDigit()
                .foregroundStyle(.primary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .padding(.horizontal, WatchMetrics.innerX - 1)
        .padding(.vertical, WatchMetrics.box(7))
        .frame(height: WatchMetrics.box(92), alignment: .topLeading)
        .frame(maxWidth: .infinity, alignment: .leading)
        .watchCard(RoundedRectangle(cornerRadius: WatchMetrics.cardRadius - 1, style: .continuous))
    }
}

/* ============================================================
   ⑥ GPA 单科：色点 + 中文名 + 百分比 + 等级 + 4 分制（无柱状图）
   ============================================================ */
struct WatchGPARow: View {
    let r: GPARowModel
    let scheme: ColorScheme

    var body: some View {
        let c = r.rgb.color(scheme, lift: 0.18)
        return HStack(spacing: 6) {
            Circle().fill(c).frame(width: 6, height: 6)
            Text(r.label)
                .font(.system(size: WatchMetrics.fs(11.5), weight: .medium))
                .frame(width: 30, alignment: .leading)
                .lineLimit(1)
                .fixedSize()
            Spacer(minLength: 2)
            if let p = r.pct {
                Text(fmtPct(p))
                    .font(.system(size: WatchMetrics.fs(11.5), weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(c)
                    .lineLimit(1)
                    .fixedSize()
                Text(r.grade ?? "")
                    .font(.system(size: WatchMetrics.fs(9.5), weight: .bold))
                    .foregroundStyle(.secondary)
                    .frame(minWidth: 17)
                    .padding(.vertical, 1.5)
                    .padding(.horizontal, 4)
                    .background(Capsule().fill(c.opacity(0.16)))
                    .fixedSize()
                Text("\(to4(p / 100))/4")
                    .font(.system(size: WatchMetrics.fs(9.5), weight: .medium))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .frame(width: 40, alignment: .trailing)
                    .fixedSize()
            } else {
                Text("未出分")
                    .font(.system(size: WatchMetrics.fs(10.5)))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, WatchMetrics.innerX)
        .frame(height: WatchMetrics.box(28))
        .frame(maxWidth: .infinity, alignment: .leading)
        .watchCard(RoundedRectangle(cornerRadius: WatchMetrics.cardRadius - 3, style: .continuous))
    }
}
