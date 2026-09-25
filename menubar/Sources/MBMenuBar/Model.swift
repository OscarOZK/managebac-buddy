import Foundation

/* 本机服务返回的 JSON 结构（与 bridge.py / app.html 对齐） */
struct Payload: Decodable {
    var ok: Bool?
    var reason: String?
    var error: String?
    var offline: Bool?
    var tasks: [TaskItem]?
    var classes: [ClassItem]?
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
