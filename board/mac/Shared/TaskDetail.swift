import SwiftUI
import QuickLook

/* ======================================================================
   任务详情单（点待办卡片弹出）

   交互约定（用户钦定）：
     · 卡片上有一个独立的「打开」按钮 —— 只有点它才跳 ManageBac 原网页；
     · 点卡片其余任何地方 → 弹出这份详情单；
     · 详情单是液态玻璃（glassEffect / 系统原生 Liquid Glass）材质；
     · 附件 ≤7MB 由 bridge 预下载到本机，点开用 QuickLook（预览）直接看，
       不落 WPS；超大文件只给网页链接。

   数据来自 bridge 的 /api/task?url=...（无头浏览器抓正文 + 预下载附件，
   结果缓存 6 小时）。第一次打开同一个任务可能有十几秒抓取等待，
   之后毫秒级 —— 所以加载态做成骨架屏而不是转圈。
   ====================================================================== */

struct TaskAttachment: Identifiable {
    let id = UUID()
    let name: String
    let href: String
    let size: Int?
    let downloaded: Bool
    let path: String?
}

@MainActor
final class TaskDetailLoader: ObservableObject {
    enum Phase: Equatable { case loading, loaded, failed(String) }
    @Published var phase: Phase = .loading
    @Published var data: TaskDetailData?

    private var current: Task<Void, Never>?

    func load(url: URL) {
        current?.cancel()
        phase = .loading
        data = nil
        current = Task { [weak self] in
            // 抓详情要开无头浏览器抓页面 + 下附件，可能远超普通接口的 25s
            let cfg = URLSessionConfiguration.ephemeral
            cfg.timeoutIntervalForRequest = 240
            cfg.timeoutIntervalForResource = 300
            let session = URLSession(configuration: cfg)
            do {
                var comps = URLComponents(url: DataStore.base.appendingPathComponent("api/task"),
                                          resolvingAgainstBaseURL: false)!
                comps.queryItems = [URLQueryItem(name: "url", value: url.absoluteString)]
                let (raw, _) = try await session.data(from: comps.url!)
                let obj = (try? JSONSerialization.jsonObject(with: raw)) as? [String: Any] ?? [:]
                guard (obj["ok"] as? Bool) == true else {
                    let err = obj["error"] as? String ?? "抓取失败"
                    await MainActor.run { self?.phase = .failed(err) }
                    return
                }
                let atts = (obj["attachments"] as? [[String: Any]] ?? []).map { a in
                    TaskAttachment(name: a["name"] as? String ?? "附件",
                                   href: a["href"] as? String ?? "",
                                   size: a["size"] as? Int,
                                   downloaded: a["downloaded"] as? Bool ?? false,
                                   path: a["path"] as? String)
                }
                let d = TaskDetailData(
                    title: obj["title"] as? String ?? "",
                    text: obj["text"] as? String ?? "",
                    chips: TaskDetailData.chips(from: obj["meta"] as? [String: Any] ?? [:]),
                    attachments: atts,
                    url: obj["url"] as? String ?? url.absoluteString)
                await MainActor.run {
                    self?.data = d
                    self?.phase = .loaded
                }
            } catch {
                await MainActor.run { self?.phase = .failed("连不上数据服务（bridge 没在跑？）") }
            }
        }
    }
}

struct TaskMetaChip: Identifiable {
    let id = UUID()
    let label: String   // 类型 / 类别 / 状态 / 成绩
    let value: String
}

struct TaskDetailData {
    let title: String
    let text: String
    var chips: [TaskMetaChip] = []
    let attachments: [TaskAttachment]
    let url: String

    /// 把 bridge 抓回的结构化信息（labels/status/grade/points）归类成顶部信息条
    static func chips(from m: [String: Any]) -> [TaskMetaChip] {
        var out: [TaskMetaChip] = []
        let labels = (m["labels"] as? [Any])?.compactMap { $0 as? String } ?? []
        for (i, l) in labels.prefix(2).enumerated() {
            out.append(TaskMetaChip(label: i == 0 ? "类型" : "类别", value: l))
        }
        if let st = m["status"] as? String, !st.isEmpty {
            out.append(TaskMetaChip(label: "状态", value: st))
        }
        let grade = (m["grade"] as? String ?? "").trimmingCharacters(in: .whitespaces)
        let pts = (m["points"] as? String ?? "").trimmingCharacters(in: .whitespaces)
        if !grade.isEmpty || !pts.isEmpty {
            out.append(TaskMetaChip(label: "成绩",
                                    value: [grade, pts].filter { !$0.isEmpty }.joined(separator: " · ")))
        }
        return out
    }
}

/* ======================================================================
   详情单的中枢 + 挂载点
   ----------------------------------------------------------------------
   ⚠️ 上一版的教训：TodoSection 里 @State detailTask 置位后，**详情单从来没有
   被挂到视图树上**（没有任何 overlay 用它）—— 点卡片看起来就是「没反应」。
   现在改成全局单例：任何地方（大看板卡片 / 小看板行）调 TaskDetailCenter
   的 open()，各窗口根部挂的 TaskDetailHost 负责把它画出来。
   每个进程一个窗口，单例不会串。
   ====================================================================== */

@MainActor
final class TaskDetailCenter: ObservableObject {
    static let shared = TaskDetailCenter()
    @Published var task: TaskVM?
    /// 面板宽度：大看板 580；小看板按窗口宽自适应
    @Published var width: CGFloat = 580

    func open(_ t: TaskVM, width: CGFloat = 580) {
        self.width = max(320, min(580, width))
        withAnimation(Motion.pop) { task = t }
    }

    func close() {
        withAnimation(Motion.pop) { task = nil }
    }
}

/// 挂在窗口根部的详情单宿主。ZStack 里最后一个画 → 永远在内容之上。
struct TaskDetailHost: View {
    @ObservedObject private var center = TaskDetailCenter.shared

    var body: some View {
        ZStack {
            if let t = center.task {
                TaskDetailOverlay(task: t, width: center.width) { center.task = nil }
                .transition(.opacity)
            }
        }
    }
}

/* ======================================================================
   详情单本体
   ====================================================================== */

struct TaskDetailOverlay: View {
    let task: TaskVM
    /// 面板宽度（大看板 580 / 小看板按窗口自适应）
    var width: CGFloat = 580
    var onClose: () -> Void

    @EnvironmentObject var settings: BoardSettings
    @Environment(\.colorScheme) private var scheme
    @StateObject private var loader = TaskDetailLoader()
    @State private var quickLookURL: URL?
    @State private var shown = PreviewFlags.offscreen   // 进场：淡入 + 上浮（离屏自检时直接给到位）

    private var env: Env { Env(scheme: scheme, settings: settings) }

    private var c: Color { task.band.color(scheme, accent: settings.accent) }

    var body: some View {
        // 外壳统一走 FloatingWindow：相对**视口**居中、顶部可拖、背景是跟着
        // 小窗走的径向渐暗（不再是压满全屏的一块黑纱）。
        FloatingWindow(dim: scheme == .dark ? 0.46 : 0.30,
                       panelRadius: 400,
                       inset: EdgeInsets(top: width <= 460 ? 26 : 42,
                                         leading: width <= 460 ? 22 : 46,
                                         bottom: width <= 460 ? 26 : 42,
                                         trailing: width <= 460 ? 22 : 46),
                       onTapOutside: close) {
            panel
                .scaleEffect(shown ? 1 : 0.96)
                .opacity(shown ? 1 : 0)
                .offset(y: shown ? 0 : 18)
        }
        .onAppear {
            loader.load(url: task.url)
            withAnimation(Motion.pop) { shown = true }
        }
        .onExitCommand { close() }        // Esc 关闭（macOS 惯例）
        .quickLookPreview($quickLookURL)
    }

    private func close() {
        withAnimation(Motion.pop) { shown = false }
        // 等退场动画播完再摘掉节点，不然看不到动画
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.24) { onClose() }
    }

    /* ---------------- 面板 ---------------- */

    private var panel: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.5)
            ScrollView {
                VStack(alignment: .leading, spacing: env.space(16)) {
                    meta
                    metaChips
                    bodyText
                    attachments
                }
                .padding(.horizontal, env.space(20))
                .padding(.vertical, env.space(16))
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            footer
        }
        .frame(width: width)
        // 高度上限扣掉描边的宽度（desired 620 − 2×7），不然总高会超出 620
        .frame(maxHeight: 606)
        // 弹窗外壳：外圈是原生液态玻璃描边（零填色、纯折射），
        // 内圈是「不太透底色」的毛玻璃主体。见 LiquidGlassPanel。
        // 描边宽度 / 高光 / 挡色 / 投影四项由「设置 → 外观」控制，默认即原效果。
        .liquidGlassPanel(env, corner: Radius.lg)
    }

    /* —— 头部：学科色点 + 标题 + 紧急徽章 + 关闭 —— */

    private var header: some View {
        HStack(alignment: .top, spacing: 10) {
            Circle()
                .fill(Subject.rgb(Subject.key(task.fullSubject), settings)
                    .color(scheme, lift: 0.14))
                .frame(width: 8, height: 8)
                .padding(.top, 6)
            VStack(alignment: .leading, spacing: 5) {
                Text(task.title)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Theme.ink(env.scheme))
                    .fixedSize(horizontal: false, vertical: true)
                Text("\(task.fullSubject.isEmpty ? task.subject : task.fullSubject) · \(task.type.isEmpty ? task.kind : task.type)")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 12)
            // 徽章颜色 = Band 语义色（RGB）：充裕=绿、较急=琥珀、紧急/逾期=红、留意=主题色
            Pill(env: env, text: task.band.name,
                 color: (task.isOver || task.band == .over || task.band == .urgent)
                     ? Theme.redDefault
                     : (task.band == .soon ? Theme.amberDefault
                         : (task.band == .ok ? Theme.greenDefault : settings.accent)),
                 bold: true)
            Button { close() } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.secondary)
                    .frame(width: 26, height: 26)
                    .background(Circle().fill(Color.primary.opacity(0.06)))
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .help("关闭（Esc）")
        }
        .padding(.horizontal, env.space(20))
        .padding(.vertical, env.space(15))
    }

    /* —— 元信息：截止 + 剩余 —— */

    private var meta: some View {
        HStack(spacing: 14) {
            Label(task.due.map(shortDueDate) ?? "未设截止", systemImage: Icons.clock)
                .font(Typo.num(12, .medium))
                .foregroundStyle(.secondary)
            Text(task.leftText)
                .font(Typo.num(12, .bold))
                .monospacedDigit()
                .foregroundStyle(c)
            Spacer()
        }
        .padding(env.space(12))
        .background {
            RoundedRectangle(cornerRadius: env.radius(9), style: .continuous)
                .fill(c.opacity(scheme == .dark ? 0.14 : 0.08))
        }
    }

    /* —— 信息条：任务页的结构化字段（类型/类别/状态/成绩），不是表格，是归类小卡 —— */

    private var metaChips: some View {
        Group {
            if let chips = loader.data?.chips, !chips.isEmpty {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 140), spacing: 8)],
                          alignment: .leading, spacing: 8) {
                    ForEach(chips) { chip in
                        HStack(spacing: 7) {
                            Text(chip.label)
                                .font(.system(size: 10.5, weight: .semibold))
                                .foregroundStyle(.tertiary)
                            Text(chip.value)
                                .font(.system(size: 11.5, weight: .medium))
                                .foregroundStyle(Theme.ink2(env.scheme))
                                .lineLimit(1)
                                .minimumScaleFactor(0.8)
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 11)
                        .padding(.vertical, 8)
                        .background {
                            RoundedRectangle(cornerRadius: env.radius(8), style: .continuous)
                                .fill(Color.primary.opacity(0.045))
                        }
                    }
                }
            }
        }
    }

    /* —— 正文 —— */

    @ViewBuilder
    private var bodyText: some View {
        VStack(alignment: .leading, spacing: env.space(10)) {
            Text("任务说明")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
            switch loader.phase {
            case .loading:
                // 骨架屏：三行渐变的"字条"，比转圈安静
                VStack(alignment: .leading, spacing: 9) {
                    skeletonLine(0.92)
                    skeletonLine(1.0)
                    skeletonLine(0.64)
                }
            case .failed(let msg):
                Text("抓取失败：\(msg)\n可以直接打开原网页查看。")
                    .font(.system(size: 12.5))
                    .foregroundStyle(.secondary)
            case .loaded:
                let t = (loader.data?.text ?? "").isEmpty
                    ? "这个任务页上没有正文说明。"
                    : loader.data!.text
                Text(t)
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.ink2(env.scheme))
                    .lineSpacing(4)
                    .textSelection(.enabled)
            }
        }
    }

    private func skeletonLine(_ w: CGFloat) -> some View {
        Capsule()
            .fill(Color.primary.opacity(0.08))
            .frame(width: 320 * w, height: 11)
    }

    /* —— 附件 —— */

    @ViewBuilder
    private var attachments: some View {
        if loader.phase == .loaded, let atts = loader.data?.attachments, !atts.isEmpty {
            VStack(alignment: .leading, spacing: env.space(10)) {
                Text("附件 \(atts.count) 个")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
                ForEach(atts) { a in attachmentRow(a) }
            }
        }
    }

    private func attachmentRow(_ a: TaskAttachment) -> some View {
        HStack(spacing: 10) {
            Image(systemName: fileIcon(a.name))
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(settings.accent.color(scheme, lift: 0.10))
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 2) {
                Text(a.name)
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(Theme.ink(env.scheme))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(a.downloaded
                     ? (a.size.map { ByteCountFormatter.string(fromByteCount: Int64($0), countStyle: .file) } ?? "已下载")
                     : "文件过大（>\(a.size.map { ByteCountFormatter.string(fromByteCount: Int64($0), countStyle: .file) } ?? "7 MB")）· 在网页中查看")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.tertiary)
            }
            Spacer(minLength: 8)

            if a.downloaded, let p = a.path {
                Button {
                    quickLookURL = URL(fileURLWithPath: p)
                } label: {
                    Label("预览", systemImage: "eye")
                        .font(.system(size: 11, weight: .semibold))
                        .padding(.horizontal, 11)
                        .frame(height: 25)
                        .background(Capsule().fill(settings.accent.color(scheme, lift: 0.86, opacity: 0.16)))
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .help("用 QuickLook 预览（不会打开 WPS）")
            } else {
                if let u = URL(string: a.href) {
                    Button {
                        LinkOpen.go(u, source: "managebac", settings: settings)
                    } label: {
                        Label("网页", systemImage: "arrow.up.forward")
                            .font(.system(size: 11, weight: .semibold))
                            .padding(.horizontal, 11)
                            .frame(height: 25)
                            .background(Capsule().fill(Color.primary.opacity(0.06)))
                            .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(.horizontal, env.space(12))
        .padding(.vertical, env.space(9))
        .background {
            RoundedRectangle(cornerRadius: env.radius(9), style: .continuous)
                .fill(Color.primary.opacity(0.035))
        }
    }

    private func fileIcon(_ name: String) -> String {
        let ext = (name as NSString).pathExtension.lowercased()
        switch ext {
        case "pdf":  return "doc.richtext"
        case "doc", "docx", "pages", "txt", "rtf": return "doc.text"
        case "xls", "xlsx", "numbers", "csv": return "tablecells"
        case "ppt", "pptx", "key": return "slideshow"
        case "png", "jpg", "jpeg", "gif", "heic": return "photo"
        case "mp4", "mov": return "film"
        case "zip": return "doc.zipper"
        default:    return "paperclip"
        }
    }

    /* —— 底栏：原网页入口（次级；主入口是卡片上的「打开」按钮） —— */

    private var footer: some View {
        HStack(spacing: 10) {
            // 逾期才有删除（两次确认，可在设置里找回）。放在最左，
            // 和右边的正动作分开 —— 免得手快点到。
            if task.isOver {
                TaskDeleteButton(task: task) { close() }
            }
            Spacer()
            // ⚠️ 这里只认「这张卡片自己的」URL。以前优先用 loader.data?.url
            // （详情抓取回传的字段），一旦那一页其实抓的是别人的任务，
            // 点「打开原网页」就会跳到别的作业去 —— 第 17 轮用户反馈的那个错。
            if let u = URL(string: task.url.absoluteString),
               u.host != nil, u.scheme != nil {
                Button {
                    LinkOpen.go(u, source: "managebac", settings: settings)
                } label: {
                    Label("打开原网页", systemImage: "arrow.up.forward")
                        .font(.system(size: 11.5, weight: .semibold))
                        .padding(.horizontal, 13)
                        .frame(height: 27)
                        .background(Capsule().fill(Color.primary.opacity(0.06)))
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, env.space(20))
        .padding(.vertical, env.space(12))
    }
}
