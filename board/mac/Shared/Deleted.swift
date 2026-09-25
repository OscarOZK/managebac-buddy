import SwiftUI
import AppKit

/* ======================================================================
   已删除的作业（用户钦定的「两次确认 + 可找回」）

   用户原话：
     「已经逾期作业，加删除按钮，在两次确认后删除，删除的作业在设置中可以找回。」

   为什么不做成「真删」：
     ManageBac 上没有「删掉一条作业」这个动作 —— 它只是我们本地读回来的一份
     展示数据。所以「删除」在这里的准确定义是 **本地隐藏**：
       · 待办 / 逾期列表里不再出现（顺带也不会再为它推通知）；
       · 但条目本身记在 <数据目录>/deleted-tasks.json 里，
         设置页「已删除的作业」里能看见、能一键恢复。

   为什么不用 settings.json：
     那份文件是「偏好」，用户点「恢复默认」时会整体重置 —— 顺手把已删除记录
     一起清掉，等于把用户的后悔药扔了。单独一个文件，跟偏好解耦。

   为什么按 id 而不是按标题：
     设置里已有的「隐藏关键词」是子串匹配，用来屏蔽一整类（背诵视频…）；
     这里是精确点掉一条，用 ManageBac 的任务 id 最准 —— 同名作业不会误伤。

   这里**刻意不提供**「彻底删除」：
     记录一旦抹掉，那条作业立刻会回到待办列表里 —— 那不是「彻底删除」，
     是「反悔」。与其放一个名不副实、点了会吓人一跳的按钮，不如只给「恢复」。
   ====================================================================== */

struct DeletedTask: Identifiable, Codable, Equatable {
    var id: String            // ManageBac 侧的任务 id
    var title: String
    var subject: String       // 学科全称（显示用）
    var due: Date?
    var url: String
    var deletedAt: Date
}

@MainActor
final class DeletedTasks: ObservableObject {
    static let shared = DeletedTasks()

    /// 按删除时间倒序（最近删的在最上面 —— 后悔也总是刚删的那条）
    @Published private(set) var list: [DeletedTask] = []

    /// 快速查询用的索引（groups() 每次刷新都要问，不能每次线性扫）
    private var index: Set<String> = []
    private var loaded = false

    private init() {}

    /* ---------------- 查 ---------------- */

    func isDeleted(id: String) -> Bool {
        ensureLoaded()
        return index.contains(id)
    }

    var count: Int { ensureLoaded(); return list.count }

    /* ---------------- 写 ---------------- */

    /// 删除（本地隐藏）。重复删除同一条不会产生第二条记录。
    func remove(_ t: TaskVM) {
        ensureLoaded()
        guard !index.contains(t.id) else { return }
        list.insert(DeletedTask(id: t.id,
                                title: t.title,
                                subject: t.fullSubject.isEmpty ? t.subject : t.fullSubject,
                                due: t.due,
                                url: t.url.absoluteString,
                                deletedAt: Date()), at: 0)
        index.insert(t.id)
        save()
    }

    /// 恢复一条 —— 它下一次刷新就会回到列表里
    func restore(id: String) {
        ensureLoaded()
        guard index.contains(id) else { return }
        list.removeAll { $0.id == id }
        index.remove(id)
        save()
    }

    /// 恢复全部
    func restoreAll() {
        ensureLoaded()
        guard !list.isEmpty else { return }
        list.removeAll()
        index.removeAll()
        save()
    }

    /* ---------------- 持久化 ---------------- */

    private var url: URL { MBBPaths.file("deleted-tasks.json") }

    private func ensureLoaded() {
        guard !loaded else { return }
        loaded = true
        // ⚠️ 编解码策略必须一对：写入用的是 .iso8601，读的时候不写这一行
        //    就会退回默认的「数字时间戳」，整个文件解析失败 → 列表看起来
        //    永远是空的（还查不出错，因为 try? 把异常吞了）。
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        guard let d = try? Data(contentsOf: url),
              let arr = try? dec.decode([DeletedTask].self, from: d) else { return }
        list = arr
        index = Set(arr.map(\.id))
    }

    private func save() {
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        if let d = try? enc.encode(list) {
            try? d.write(to: url, options: .atomic)
        }
    }
}

/* ======================================================================
   删除按钮：两次确认
   ----------------------------------------------------------------------
   第一次点 → 按钮自己变成「确认删除？」（红底描边加重），这一步是可撤销的；
   第二次点 → 弹出系统确认框，白纸黑字写清「可在设置里找回」；
   弹框里再点「删除」才真的删。
   点完 4 秒不动 → 自动缩回初始态（免得「待确认」一直红着，像卡住了）。
   ====================================================================== */

struct TaskDeleteButton: View {
    let task: TaskVM
    /// 紧凑版（卡片角上的小按钮）；非紧凑版用于详情单底栏
    var compact: Bool = false
    /// 删完之后做点什么 —— 详情单用它把自己关掉（那条作业已经不在了，
    /// 留着一张空壳弹窗很怪）
    var onDeleted: (() -> Void)? = nil

    @Environment(\.colorScheme) private var scheme
    @State private var armed = false
    @State private var askAgain = false
    @State private var disarmAt: Date = .distantPast

    private var red: Color { Theme.redDefault.color(scheme, lift: 0.14) }

    var body: some View {
        Button {
            if armed {
                askAgain = true
            } else {
                withAnimation(Motion.ease(Motion.Dur.quick)) { armed = true }
                disarmAt = Date().addingTimeInterval(4)
                let mine = disarmAt
                DispatchQueue.main.asyncAfter(deadline: .now() + 4.1) {
                    // 弹框开着就别收回去了，否则用户点「取消」回来发现按钮已经复位
                    if armed, !askAgain, disarmAt == mine {
                        withAnimation(Motion.ease(Motion.Dur.quick)) { armed = false }
                    }
                }
            }
        } label: {
            HStack(spacing: compact ? 4 : 6) {
                Image(systemName: armed ? Icons.warn : Icons.trash)
                    .font(.system(size: compact ? 10.5 : 11.5, weight: .bold))
                Text(armed ? "确认删除？" : "删除")
                    .font(.system(size: compact ? 10.5 : 11.5, weight: .semibold))
                    .lineLimit(1)
            }
            .foregroundStyle(red)
            .padding(.horizontal, compact ? 9 : 13)
            .frame(height: compact ? 24 : 27)
            .background {
                Capsule().fill(red.opacity(armed ? (scheme == .dark ? 0.30 : 0.18)
                                                  : (scheme == .dark ? 0.14 : 0.08)))
            }
            .overlay {
                Capsule().strokeBorder(red.opacity(armed ? 0.70 : 0.28), lineWidth: 1)
            }
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help(armed ? "再点一次，会弹出确认框" : "从列表里删掉这条逾期作业（可在设置里找回）")
        .accessibilityLabel("删除 \(task.title)")
        .alert("删除这条作业？", isPresented: $askAgain) {
            Button("取消", role: .cancel) {
                withAnimation(Motion.ease(Motion.Dur.quick)) { armed = false }
            }
            Button("删除", role: .destructive) {
                DeletedTasks.shared.remove(task)
                withAnimation(Motion.ease(Motion.Dur.quick)) { armed = false }
                onDeleted?()
            }
        } message: {
            Text("「\(task.title)」会从待办和逾期列表里消失。\n想反悔的话，设置 → 待办 → 已删除的作业 里可以随时恢复。")
        }
    }
}
