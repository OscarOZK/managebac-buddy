import Foundation

/* 本机服务返回的 JSON 结构（与 bridge.py / app.html / Windows 端对齐） */

struct Payload: Decodable {
    var ok: Bool?
    var reason: String?
    var error: String?
    var offline: Bool?
    var tasks: [TaskItem]?
    var classes: [ClassItem]?
    var recent: [RecentWork]?
    var counts: Counts?
    var loggedIn: Bool?
    var user: String?
    var fetchedAt: Double?
    var stale: Bool?
    var updating: Bool?
    /// 服务端还没有任何数据、正在首抓（占位负载标记）
    var preparing: Bool?
    var sessionExpired: Bool?
    var sessionSince: Double?
    var sessionNote: String?
    var hasCreds: Bool?
}

struct Counts: Decodable {
    var upcoming: Int?
    var overdue: Int?
}

struct TaskItem: Decodable, Identifiable {
    var view: String?
    var title: String?
    var subject: String?
    var classId: String?
    var taskId: String?
    var url: String?
    var dueText: String?
    var due: String?
    var type: String?
    var kind: String?
    var status: String?
    var created: String?
    var createdText: String?

    var id: String { taskId ?? url ?? title ?? UUID().uuidString }
}

struct Overall: Decodable {
    var mark: String?
    var pct: Double?
}

struct LatestWork: Decodable {
    var title: String?
    var url: String?
    var grade: String?
    var score: Double?
    var outOf: Double?
    var scoreText: String?
    var dueText: String?
    var due: String?
    /// 出分时间（bridge 自己留存的首次见到时刻，ManageBac 不提供）
    var gradedAtMs: Double?
}

struct RecentWork: Decodable, Identifiable {
    var key: String?
    var label: String?
    var classId: String?
    var title: String?
    var url: String?
    var grade: String?
    var score: Double?
    var outOf: Double?
    var scoreText: String?
    var dueText: String?
    var due: String?
    /// 出分时间（bridge 自己留存的首次见到时刻，ManageBac 不提供）
    var gradedAtMs: Double?

    var id: String { (url ?? title ?? "") + (due ?? "") }
}

struct ClassItem: Decodable, Identifiable {
    var key: String?
    var label: String?
    var classId: String?
    var name: String?
    var url: String?
    var overall: Overall?
    var latest: LatestWork?
    /// 这门课逐条已评分的作业（学科柱状图的数据源；抓取端最多给 60 条）
    var items: [LatestWork]?

    var id: String { classId ?? url ?? label ?? UUID().uuidString }
}

/* ---------------- 视图模型 ---------------- */

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
    let kind: String
    let type: String
    /// 剩下多少毫秒（负 = 已过期）
    let leftMs: Double?
}

struct RecentVM: Identifiable {
    let id: String
    let label: String
    let key: String
    let title: String
    let due: Date?
    let dueText: String
    let grade: String?
    let scoreText: String
    let scoreNum: Double?
    let scoreOutOf: Double?
    let url: URL?
    let good: Bool
    /// 老师批出分的时间（bridge 留存；没有则回落到截止时间）
    let gradedAt: Date?

    /// 排序键：出分时间优先，没有就用截止时间 —— 列表按它从新到旧
    var gradedSort: Date { gradedAt ?? due ?? .distantPast }

    /// 得分率（0…100）。柱状图的柱高就是它。
    /// 只在「满分 > 0」时才算得出来 —— 满分是 0 的评分项（附加分之类）当分母没有意义。
    var pct: Double? {
        guard let s = scoreNum, let o = scoreOutOf, o > 0 else { return nil }
        return min(120, max(0, s / o * 100))
    }
}

struct GPARowModel: Identifiable {
    let id: String
    let label: String
    let key: String
    let pct: Double?
    let grade: String?
    let url: URL?
    let latest: RecentVM?
    /// 这门课逐条已评分的作业，**按截止时间从旧到新**（柱状图从左到右就是学期进程）。
    /// 点开学科时用它画柱状图，不再跳原网站。
    var items: [RecentVM] = []
    /// 抓取端给到的总数（可能多于 items.count，因为那边封了 60 条上限）
    var itemTotal: Int = 0
}

/* ---------------- Teams 板块（Microsoft Graph）---------------- */

struct TeamsEnvelope: Decodable {
    var ok: Bool?
    var loggedIn: Bool?
    var loggingIn: Bool?
    var loginMsg: String?
    var loginStep: Int?
    /// 设备码：界面上要大字显示，让用户去 microsoft.com/devicelogin 输入
    var userCode: String?
    /// 已预填好设备码的登录页地址，点一下就能直接进
    var remoteUrl: String?
    var loginUrl: String?
    var loginClient: String?
    var loginAttempt: Int?
    var loginTotal: Int?
    var tried: [String]?
    var account: String?
    var fetching: Bool?
    var error: String?
    var ageSec: Int?
    var authAvailable: Bool?
    /// 当前这份是「上次抓到的快照」（这一轮没抓到新的）
    var stale: Bool?
    /// 快照已经过去多少秒
    var lastGoodSec: Int?
    /// 连续失败次数（>0 说明链路在抖，界面给出更明确的说法）
    var fails: Int?
    var auth: TeamsAuth?
    var section: TeamsData?
}

/// 登录通道信息：用的哪个客户端、实际拿到哪些权限、缺哪些
struct TeamsAuth: Decodable {
    var loggedIn: Bool?
    var client: String?
    var granted: [String]?
    var missing: [String]?
    var expired: Bool?
    var lastError: String?
}

struct TeamsCaps: Decodable {
    var mail: Bool?
    var calendar: Bool?
    var todo: Bool?
    var planner: Bool?
    var chat: Bool?
    var account: Bool?
}

struct TeamsData: Decodable {
    var connected: Bool?
    var reason: String?
    var account: String?
    var caps: TeamsCaps?
    var granted: [String]?
    var asOf: Double?
    var stats: TeamsStats?
    var tasks: [TeamsTask]?
    var mail: [TeamsMail]?
    var events: [TeamsEvent]?
    /// 这一轮有哪些数据源没拉到（todo / mail / chat / calendar）
    var degraded: [String]?
    /// 内容里混了上一次的结果（这一轮没抓到新的），界面据此提示「快照」
    var snapshot: Bool?
    /// English Corner 状态（名单 / 我今天要不要去）
    var ec: TeamsEC?
}

/* ---------------- English Corner ---------------- */

/// 今天有没有 EC、我要不要去、同班同学有谁
struct TeamsEC: Decodable {
    var ok: Bool?
    /// today（今天要去，还没到点）/ done（今天已过点）/ tomorrow / past / future / none / error
    var status: String?
    var note: String?
    var hasRoster: Bool?
    var isToday: Bool?
    /// 名单里有没有我
    var imIn: Bool?
    var klass: String?
    var students: [String]?
    var otherGroups: [String: [String]]?
    var caption: String?
    var file: String?
    var webUrl: String?
    var localPath: String?
    var place: String?
    var window: String?
    var deadlineMs: Double?
    var dateMs: Double?
    var date: String?
    var student: String?
    var error: String?
    /// 是否要挂「去 English Corner」这条任务
    var active: Bool?
}

struct TeamsStats: Decodable {
    var total: Int?
    var overdue: Int?
    var today: Int?
    var week: Int?
    var noDue: Int?
    var fromMail: Int?
    var fromChat: Int?
    var unreadMail: Int?
    var events: Int?
    var scannedMessages: Int?
    var ec: Int?
}

struct TeamsTask: Decodable, Identifiable {
    var id: String
    var source: String?
    var title: String?
    var course: String?
    var detail: String?
    var dueMs: Double?
    var dueText: String?
    var createdMs: Double?
    var importance: String?
    var status: String?
    var from: String?
    var webUrl: String?
    var confidence: Double?
    var signals: [String]?
    var alsoFrom: [String]?
    /// 预览用：正文全文 + 附件 + 表单 + 跳转
    var preview: TeamsPreview?
    /// EC 那条任务会带这个标记，界面上单独标色
    var pin: Bool?
    var kind: String?
    var place: String?
}

struct TeamsPreview: Decodable {
    var text: String?
    var from: String?
    var whenMs: Double?
    var webUrl: String?
    var place: String?
    var attachments: [TeamsAttachment]?
    var form: TeamsForm?
}

struct TeamsAttachment: Decodable, Identifiable {
    var name: String?
    var url: String?
    var kind: String?
    var webUrl: String?
    var size: Double?
    var local: Bool?
    var id: String { (url ?? "") + "|" + (name ?? "") }
}

struct TeamsForm: Decodable {
    var title: String?
    var url: String?
}

struct TeamsMail: Decodable, Identifiable {
    var id: String
    var subject: String?
    var from: String?
    var receivedMs: Double?
    var isRead: Bool?
    var importance: String?
    var hasAttachments: Bool?
    var webUrl: String?
    var preview: String?
}

struct TeamsEvent: Decodable, Identifiable {
    var id: String
    var title: String?
    var startMs: Double?
    var endMs: Double?
    var location: String?
    var organizer: String?
    var webUrl: String?
}

/* 渲染用视图模型 */

enum TeamsSource: String {
    case todo, planner, mail, chat, ec

    var label: String {
        switch self {
        case .todo:    return "微软任务"
        case .planner: return "Planner"
        case .mail:    return "邮件"
        case .chat:    return "聊天"
        case .ec:      return "EC"
        }
    }

    var icon: String {
        switch self {
        case .todo:    return "checkmark.square.fill"
        case .planner: return "square.stack.3d.up.fill"
        case .mail:    return "envelope.fill"
        case .chat:    return "bubble.left.fill"
        case .ec:      return "bubble.left.and.text.bubble.right.fill"
        }
    }

    /// 「有多像一份作业」——数字越小越像，列表里排越前、越不会被折叠掉。
    /// 用户的原话是「最像作业 / Task 的放前面直接显示、剩余折叠」，
    /// 所以这里给来源定一个权重：真作业（微软任务 / Planner）> 邮件里的事 > 聊天里被点到。
    /// EC 单列（本来就有 pinned，永远第一）。
    var taskRank: Int {
        switch self {
        case .ec:      return 0
        case .todo,
             .planner: return 1
        case .mail:    return 2
        case .chat:    return 3
        }
    }
}

struct TeamsTaskVM: Identifiable {
    let id: String
    let title: String
    let source: TeamsSource
    let course: String
    let detail: String
    let from: String
    let due: Date?
    let dueText: String
    /// 任务/邮件/聊天的时间（创建或收到）——列表按它从最新到最旧排
    let created: Date?
    let confidence: Double
    let signals: [String]
    let importance: String
    let url: URL?
    /// 预览面板要用的东西：正文全文、附件、表单
    let preview: TeamsPreview?
    /// 置顶（EC 那条）
    let pinned: Bool
    let place: String

    /// 有预览内容才值得弹预览面板
    var hasPreview: Bool {
        if let p = preview {
            if !(p.text ?? "").isEmpty { return true }
            if !(p.attachments ?? []).isEmpty { return true }
            if p.form?.url?.isEmpty == false { return true }
        }
        return !detail.isEmpty
    }
}

struct TeamsEventVM: Identifiable {
    let id: String
    let title: String
    let start: Date
    let end: Date?
    let location: String
    let organizer: String
    let url: URL?
    let isToday: Bool
}

struct TeamsMailVM: Identifiable {
    let id: String
    let subject: String
    let from: String
    let received: Date?
    let isRead: Bool
    let important: Bool
    let hasAttachments: Bool
    let preview: String
    let url: URL?
}

/* ======================================================================
   希悦（SEIUE）课表
   —— 后端 seiue.py 从网页上把课表网格抠出来后，整理成「周几 × 第几节」。
   这里只做解码 + 一点点展示便利，不含任何抓取逻辑。
   ====================================================================== */

struct SeiueStatus: Decodable {
    var browserUp: Bool?
    var loggedIn: Bool?
    var hasSession: Bool?
    var chrome: Bool?
    var cached: Bool?
    var cachedAt: Double?
    var error: String?
    /// 这次读到的课表是不是来自「网页上导出的那张 Excel」
    var fromExcel: Bool?
    /// 那张 Excel 的文件名（界面用来告诉用户「已经认出哪个文件」）
    var excelFile: String?
    /// 页面已经停在首页、课表容器也渲染出来了
    var onHome: Bool?
    var href: String?

    /// 「连接上了」的判定：页面探到登录 → 算；探不到但本地留着登录态
    /// （上次探到过）→ 也算。用户的原话是「我明明已经登录了、也能看到课表了，
    /// App 里还显示未登录」—— 问题就出在只认第一种：浏览器没开着时探不到，
    /// 于是明明有登录态也判成未登录。
    var connected: Bool { loggedIn == true || hasSession == true }

    /// 只认「浏览器开着且已登录」——要区分时用这个
    var live: Bool { loggedIn == true }
}

struct SeiueLesson: Decodable, Identifiable {
    var day: String?
    var dayIndex: Int?
    var period: String?
    var periodIndex: Int?
    var text: String?
    var name: String?
    var extra: [String]?

    var id: String { "\(dayIndex ?? -1)-\(periodIndex ?? -1)-\(name ?? "")-\(text ?? "")" }
    /// 备注行（老师 / 教室 …）
    var note: String { (extra ?? []).joined(separator: " · ") }
    /// 课名可能被截断，这里保留原文，界面上再判断
    var isTruncated: Bool { (name ?? "").contains("…") || (name ?? "").contains("...") }
}

struct SeiueSchedule: Decodable {
    var ok: Bool?
    var error: String?
    var loggedIn: Bool?
    var days: [String]?
    var periods: [String]?
    var lessons: [SeiueLesson]?
    var columns: Int?
    var rows: Int?
    var tables: Int?
    var href: String?
    var title: String?
    var ts: Double?
    /// "excel" = 来自网页导出的那张表；空 = 从页面上抠的格子
    var source: String?
    var file: String?

    var fromExcel: Bool { source == "excel" }
    var excelName: String {
        (file ?? "").split(separator: "/").last.map(String.init) ?? ""
    }
}

struct SeiueEnvelope: Decodable {
    var ok: Bool?
    var error: String?
    var status: SeiueStatus?
    var schedule: SeiueSchedule?
}
