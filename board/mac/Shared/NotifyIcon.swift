import AppKit
import SwiftUI

/* ======================================================================
   通知图标

   一条通知要在**两个维度**上被一眼认出来：

     · 学科     → 图标底色 + 中间那个大符号（十科十色十符号）
     · 事项种类 → 右下角的小圆角标 + 标题最前面的 emoji

   用户截图反馈：「必须有很明显很明显的学科和事项种类的区分用图标，
   一定一定有强区分」。之前只有学科一个维度，而且底色是 16% 透明的淡色
   配同色符号，缩到通知右上角那张小图里几乎全一样；再加上学科识别
   认不出中文课程名（「历史」「英语」「生物」「政治」全落空），
   结果十几条通知清一色同一个蓝毕业帽。

   现在：实心学科色底 + 白色学科符号 + 右下角种类角标，
   标题第一行还带种类 emoji —— 颜色、主符号、角标、文字四重区分。
   ====================================================================== */

/// 事项种类。跟「学科」是正交的两个维度。
enum NotifyKind: String, CaseIterable {
    case task, teams, invite, mail, event, grade, ec, digest, sample

    /// 标题前缀。通知横幅第一行开头的那个字，最抢眼的位置。
    var emoji: String {
        switch self {
        case .task:   return "⏰"
        case .teams:  return "📌"
        case .invite: return "👥"
        case .mail:   return "✉️"
        case .event:  return "📅"
        case .grade:  return "🏆"
        case .ec:     return "🗣️"
        case .digest: return "☀️"
        case .sample: return "🧪"
        }
    }

    /// 图标右下角角标里的符号
    var badge: String {
        switch self {
        case .task:   return "clock.fill"
        case .teams:  return "checklist"
        case .invite: return "person.2.fill"
        case .mail:   return "envelope.fill"
        case .event:  return "calendar"
        case .grade:  return "trophy.fill"
        case .ec:     return "bubble.left.and.bubble.right.fill"
        case .digest: return "sun.max.fill"
        case .sample: return "sparkles"
        }
    }

    var name: String {
        switch self {
        case .task:   return "待办到期"
        case .teams:  return "团队任务"
        case .invite: return "团队邀请"
        case .mail:   return "新邮件"
        case .event:  return "日程提醒"
        case .grade:  return "新成绩"
        case .ec:     return "English Corner"
        case .digest: return "每日汇总"
        case .sample: return "示例"
        }
    }
}

@MainActor
enum NotifyIcon {

    /// 缓存文件名：学科 + 种类 + 图标底色。任一变化都会重新画一张。
    static func key(subject raw: String?, kind: NotifyKind) -> String {
        let k = Subject.key(raw ?? "")
        let name = k.isEmpty ? "generic" : k
        return "\(name)-\(kind.rawValue)-\(Subject.iconRGB(k).hex)"
    }

    /// 通知缩略图：学科色实心底 + 白色学科符号 + 右下角种类角标
    static func image(subject raw: String?, kind: NotifyKind) -> NSImage {
        let k = Subject.key(raw ?? "")
        let base = Subject.iconRGB(k)
        let symbol = k.isEmpty ? Subject.genericSymbol : Subject.symbol(k)

        let S: CGFloat = 128
        let img = NSImage(size: CGSize(width: S, height: S))
        img.lockFocus()
        if let ctx = NSGraphicsContext.current {
            ctx.imageInterpolation = .high

            let rect = NSRect(x: 0, y: 0, width: S, height: S)
            let path = NSBezierPath(roundedRect: rect, xRadius: 30, yRadius: 30)
            // 上亮下暗一点点：小图里有个方向感，不至于像一块死色片
            let top = NSColor(srgbRed: min(1, base.r * 1.12),
                              green: min(1, base.g * 1.12),
                              blue: min(1, base.b * 1.12), alpha: 1)
            let bot = NSColor(srgbRed: base.r * 0.86, green: base.g * 0.86,
                              blue: base.b * 0.86, alpha: 1)
            NSGradient(starting: top, ending: bot)?.draw(in: path, angle: -90)

            // 中间的大符号：纯白，粗体
            if let sym = tinted(symbol, point: 56, weight: .bold, color: .white) {
                let w = sym.size.width, h = sym.size.height
                sym.draw(in: NSRect(x: 60 - w / 2, y: 74 - h / 2, width: w, height: h))
            }

            // 右下角种类角标：白圆 + 学科色符号
            let d: CGFloat = 46
            let cx: CGFloat = 100, cy: CGFloat = 28
            let badgeRect = NSRect(x: cx - d / 2, y: cy - d / 2, width: d, height: d)
            NSColor.white.setFill()
            NSBezierPath(ovalIn: badgeRect).fill()
            if let bs = tinted(kind.badge, point: 22, weight: .bold,
                               color: NSColor(srgbRed: base.r, green: base.g, blue: base.b, alpha: 1)) {
                let w = bs.size.width, h = bs.size.height
                bs.draw(in: NSRect(x: cx - w / 2, y: cy - h / 2, width: w, height: h))
            }
        }
        img.unlockFocus()
        return img
    }

    static func png(_ img: NSImage) -> Data? {
        guard let tiff = img.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff) else { return nil }
        return rep.representation(using: .png, properties: [:])
    }

    /// 把 SF Symbol 渲染成单一颜色（源覆盖 + sourceIn 上色）
    private static func tinted(_ name: String, point: CGFloat,
                               weight: NSFont.Weight, color: NSColor) -> NSImage? {
        guard let base = NSImage(systemSymbolName: name, accessibilityDescription: nil),
              let sized = base.withSymbolConfiguration(
                NSImage.SymbolConfiguration(pointSize: point, weight: weight)) else { return nil }
        let out = NSImage(size: sized.size)
        out.lockFocus()
        color.set()
        sized.draw(at: .zero, from: .zero, operation: .sourceOver, fraction: 1)
        NSRect(origin: .zero, size: sized.size).fill(using: .sourceIn)
        out.unlockFocus()
        return out
    }

    /// 自检用：把「全部学科 × 全部种类」导出成 PNG，好一眼看出区分度够不够
    static func dumpAll(to dir: String) {
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        for k in Subject.keys + [""] {
            let raw = k.isEmpty ? "其他" : (Subject.cnLabels[k] ?? k)
            for kind in NotifyKind.allCases {
                let n = "\(k.isEmpty ? "generic" : k)__\(kind.rawValue).png"
                guard let d = png(image(subject: raw, kind: kind)) else { continue }
                try? d.write(to: URL(fileURLWithPath: dir + "/" + n))
            }
        }
    }
}
