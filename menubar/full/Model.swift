import Foundation

/* 本机服务返回的 JSON 结构（与 bridge.py / app.html 对齐） */
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
}

/* 最近出分的作业（跨课程汇总，服务端按截止时间从新到旧排好序） */
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

    var id: String { classId ?? url ?? label ?? UUID().uuidString }
}
