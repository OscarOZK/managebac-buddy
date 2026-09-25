// 离屏渲染自检：把面板画成 PNG，用来核对布局（玻璃材质不在离屏渲染里出图，故用 flat 模式看骨架）
// 用法：./render [--gpa] [--overdue] [--dark] [--full] [--dump] [--at HH:MM] [--badge 红,黄,蓝] [out.png]
import SwiftUI
import AppKit

@main
struct RenderMain {
    @MainActor
    static func main() {
        let args = CommandLine.arguments
        PreviewFlags.flat = true
        PreviewFlags.noScroll = true
        PreviewFlags.fullHeight = args.contains("--full")
        PreviewFlags.gpaExpanded = args.contains("--gpa")
        PreviewFlags.overdueExpanded = args.contains("--overdue")
        let dark = args.contains("--dark")

        // --at 10:05 → 把「现在」定到今天的 10:05，用来核对上课 / 课间 / 晚自习等状态
        if let i = args.firstIndex(of: "--at"), i + 1 < args.count {
            let p = args[i + 1].split(separator: ":").map { Int($0) ?? 0 }
            let c = Calendar.current.dateComponents([.year, .month, .day], from: Date())
            var cc = c
            cc.hour = p.first ?? 0
            cc.minute = p.count > 1 ? p[1] : 0
            cc.second = 0
            PreviewFlags.nowOverride = Calendar.current.date(from: cc)
        }

        let now = PreviewFlags.nowOverride ?? Date()
        let out = args.last.flatMap { $0.hasSuffix(".png") ? $0 : nil } ?? "/tmp/panel_full.png"

        let store = Store()
        store.loadBlocking()

        // --badge 1,3,2 → 单独把菜单栏角标画出来（放大 8 倍、垫一层模拟菜单栏底）核对
        if let i = args.firstIndex(of: "--badge") {
            let raw = (i + 1 < args.count) ? args[i + 1] : "1,3,2"
            let v = raw.split(separator: ",").map { Int($0.trimmingCharacters(in: .whitespaces)) ?? 0 }
            let img = StatusBadge.image(red: v.count > 0 ? v[0] : 0,
                                       yellow: v.count > 1 ? v[1] : 0,
                                       blue: v.count > 2 ? v[2] : 0)
            let s: CGFloat = 8
            let W = img.size.width * s + 40, H = img.size.height * s + 40
            let bar = dark ? NSColor(white: 0.16, alpha: 1) : NSColor(white: 0.92, alpha: 1)
            let outImg = NSImage(size: NSSize(width: W, height: H))
            outImg.lockFocus()
            bar.setFill()
            NSBezierPath(rect: CGRect(x: 0, y: 0, width: W, height: H)).fill()
            img.draw(in: CGRect(x: 20, y: 20, width: img.size.width * s, height: img.size.height * s))
            outImg.unlockFocus()
            if let tiff = outImg.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
               let png = rep.representation(using: .png, properties: [:]) {
                try? png.write(to: URL(fileURLWithPath: out))
                print("badge \(Int(img.size.width))x\(Int(img.size.height))pt -> \(out)")
            }
            let c = store.bandCounts
            print("真实数量：红 \(c.red) · 黄 \(c.yellow) · 蓝 \(c.blue)  → \(c.tooltip)")
            return
        }

        if args.contains("--dump") {
            let g = store.groups(now: now)
            let name: [Band: String] = [.over: "逾期", .urgent: "红", .soon: "黄", .blue: "蓝", .ok: "绿"]
            print("—— 待完成 (按剩余时间从少到多) ——")
            for t in g.up {
                print("  \(t.subject.padding(toLength: 4, withPad: " ", startingAt: 0))  \(name[t.band] ?? "")  \(t.leftText.padding(toLength: 14, withPad: " ", startingAt: 0)) | \(t.title.prefix(34))")
            }
            print("—— 逾期 ——")
            for t in g.od { print("  \(t.subject)  \(t.leftText)  | \(t.title.prefix(28))") }
            print("—— 最新成绩（前 8） ——")
            for w in store.recentWorks(8) {
                print("  \(w.label)  \(w.dueText.padding(toLength: 12, withPad: " ", startingAt: 0))  \(w.grade ?? "-")  \(w.scoreText.padding(toLength: 14, withPad: " ", startingAt: 0)) | \(w.title.prefix(30))")
            }
            let dl = Schedule.dayList(now)
            print("—— 课堂（\(Schedule.dayCaption(dl.day, now: now))） ——")
            let cur = Schedule.currentSlot(now)?.blockId
            for s in dl.list {
                let dbl = s.span[1] > s.span[0] ? "   ‖连堂双竖条" : ""
                print("  P\(s.span[0])–P\(s.span[1])  \(fmtClock(s.start))–\(fmtClock(s.end))  \(s.subject)\(s.blockId == cur ? "   ← 进行中" : "")\(dbl)")
            }
            let hasDay = Calendar.current.isDate(dl.day, inSameDayAs: now)
            let ni = dl.list.filter { $0.end <= now }.count
            let inSession = hasDay && (dl.list.first.map { now >= $0.start } ?? false)
                            && (dl.list.last.map { now < $0.end } ?? false)
            print("—— 「现在」横条 —— \(inSession ? "显示：插在第 \(ni) 条课程之前" : "隐藏（显示的是今天=\(hasDay)，已上完 \(ni) / \(dl.list.count) 节）")")
            let tt = Schedule.topTimer(now)
            print("—— 顶部计时 —— \(tt.label)")
            print("—— GPA ——")
            for r in store.gpaRows() {
                let p = r.pct.map { fmtPct($0) } ?? "未出分"
                let f = r.pct.map { to4($0 / 100) + "/4.0" } ?? ""
                print("  \(r.label)  \(p)  \(r.grade ?? "")  \(f)")
            }
            let s = store.gpaSummary
            print("均分 \(s.avg.map { fmtPct($0) } ?? "-")  (\(s.avg.map { to4($0 / 100) } ?? "-")/4.0)  \(s.graded)/\(s.total) 门")
            let bc = store.bandCounts
            print("—— 菜单栏角标 —— 红 \(bc.red) · 黄 \(bc.yellow) · 蓝 \(bc.blue)")
        }

        let content = PanelView(store: store)
            .background(dark ? Color(white: 0.12) : Color.white)
            .environment(\.colorScheme, dark ? .dark : .light)

        let r = ImageRenderer(content: content)
        r.scale = 2
        guard let img = r.nsImage, let tiff = img.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else {
            print("render failed")
            return
        }
        try? png.write(to: URL(fileURLWithPath: out))
        print("ok \(Int(img.size.width))x\(Int(img.size.height)) -> \(out)")
        print("任务=\(store.payload?.tasks?.count ?? -1) 课程=\(store.payload?.classes?.count ?? -1) 状态=\(store.status.text)")
    }
}
