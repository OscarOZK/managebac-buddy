//  WidgetRender.swift
//  小组件版式自检：在 Mac 上把每个小组件按表盘实际尺寸离屏渲染成 PNG
//
//  用法（在 ~/.mbboard/watch 下）：
//    swiftc -O -parse-as-library -o /tmp/wrender \
//      ManageBacWatchWidgets/MBWidgetData.swift ManageBacWatchWidgets/MBWidgetViews.swift \
//      ManageBacWatchWidgets/Shared*.swift render/WidgetRender.swift
//    /tmp/wrender out.png
//
//  玻璃/材质在离屏渲染里画不出来，这里只核对版式、字号、颜色与数据是否正确。

import SwiftUI
import WidgetKit
import AppKit

@main
struct WidgetRender {
    @MainActor static func main() async {
        let args = CommandLine.arguments
        let out = args.last.flatMap { $0.hasSuffix(".png") ? $0 : nil } ?? "/tmp/widgets.png"
        let offline = args.contains("--offline")

        // --at HH:MM 把「现在」定住（核对上课 / 课间 / 深夜等场景）
        var pinned: Date?
        if let i = args.firstIndex(of: "--at"), i + 1 < args.count {
            let p = args[i + 1].split(separator: ":").compactMap { Int($0) }
            if let h = p.first {
                var c = Calendar.current.dateComponents([.year, .month, .day], from: Date())
                c.hour = h; c.minute = p.count > 1 ? p[1] : 0; c.second = 0
                pinned = Calendar.current.date(from: c)
            }
        }
        let now = pinned ?? Date()

        let payload = offline ? nil : await MBData.fetch()
        if offline {
            print("离线场景：payload 为 nil（模拟电脑上的看板服务没开）")
        } else if let p = payload {
            print("数据 OK：tasks=\(p.tasks?.count ?? 0) classes=\(p.classes?.count ?? 0) recent=\(p.recent?.count ?? 0)")
        } else {
            print("⚠️ 没取到数据（电脑上的看板服务没开？渲染的是空状态）")
        }
        let e = MBEntry(date: now, payload: payload)

        let rows: [(String, AnyView)] = [
            ("待办清单", AnyView(MBTodoView(e: e))),
            ("待办紧急度", AnyView(MBBandCountView(e: e))),
            ("课堂倒计时", AnyView(MBCountdownView(e: e))),
            ("今日课表", AnyView(MBScheduleView(e: e))),
            ("最新成绩", AnyView(MBScoreView(e: e))),
            ("总均分 GPA", AnyView(MBGPAView(e: e))),
            ("今日概览", AnyView(MBDayView(e: e))),
            ("下一节课", AnyView(MBNextClassView(e: e))),
            ("学习总览 ★", AnyView(MBMixView(e: e))),
            ("课堂速览", AnyView(MBClassFocusView(e: e))),
            ("成绩速览", AnyView(MBGradeMixView(e: e))),
            ("紧迫速览", AnyView(MBUrgentMixView(e: e))),
        ]

        let sheet = VStack(alignment: .leading, spacing: 12) {
            Text("ManageBac 小组件 · 版式自检")
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(.white)
            Text("\(offline ? "离线（无数据）" : "真实数据") · 现在 \(fmtClock(now)) \(dayShort(now))")
                .font(.system(size: 11))
                .foregroundStyle(.white.opacity(0.6))
            HStack(spacing: 10) {
                Text("").frame(width: 64)
                Text("圆形 76").frame(width: 76)
                Text("圆角 172×72").frame(width: 172)
                Text("行内").frame(width: 158)
            }
            .font(.system(size: 10))
            .foregroundStyle(.white.opacity(0.5))

            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                HStack(alignment: .center, spacing: 10) {
                    Text(row.0)
                        .font(.system(size: 11))
                        .foregroundStyle(.white)
                        .frame(width: 64, alignment: .leading)
                    cell(row.1, .circular, CGSize(width: 76, height: 76))
                    cell(row.1, .rectangular, CGSize(width: 172, height: 72))
                    cell(row.1, .inline, CGSize(width: 158, height: 26))
                }
            }
        }
        .padding(16)
        .background(Color.black)

        let r = ImageRenderer(content: sheet)
        r.scale = 2
        guard let img = r.nsImage,
              let tiff = img.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else {
            print("渲染失败"); exit(1)
        }
        try? png.write(to: URL(fileURLWithPath: out))
        print("已写出 \(out)  \(Int(img.size.width))×\(Int(img.size.height))")
    }

    /// 一个格子：注入 family + 固定尺寸 + 模拟表盘底色
    @MainActor static func cell(_ v: AnyView, _ family: MBFamily, _ size: CGSize) -> some View {
        let radius: CGFloat = (family == .circular) ? size.width / 2 : 14
        return v
            .environment(\.mbFamily, family)
            .padding(family == .inline ? 3 : 4)
            .frame(width: size.width, height: size.height)
            .background(Color(white: 0.115))
            .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .stroke(Color.white.opacity(0.10), lineWidth: 0.5)
            )
    }
}
