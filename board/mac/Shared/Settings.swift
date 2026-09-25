import SwiftUI
import Combine

/* ======================================================================
   共享设置模型 —— 存放在 ~/.mbboard/settings.json
   Mac 的「菜单栏 App」和「看板 App」读写同一份文件，Windows 端也用同一份 schema，
   所以两个系统上的可自定义项完全一致。每一条都真实驱动界面，没有摆设项。
   ====================================================================== */

enum ThemeMode: String, CaseIterable, Codable {
    case system, light, dark
    var label: String {
        switch self {
        case .system: return "跟随系统"
        case .light:  return "浅色"
        case .dark:   return "深色"
        }
    }
    var icon: String {
        switch self {
        case .system: return "circle.lefthalf.filled"
        case .light:  return "sun.max.fill"
        case .dark:   return "moon.fill"
        }
    }
    var scheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light:  return .light
        case .dark:   return .dark
        }
    }
}

enum LabelStyle: String, CaseIterable, Codable {
    case dots, counts, plain
    var label: String {
        switch self {
        case .dots:   return "彩色圆点"
        case .counts: return "数字方块"
        case .plain:  return "仅图标"
        }
    }
}

/// 任务详情预取间隔档位（分钟；0 = 关闭）
enum PrefetchInterval: String, CaseIterable, Codable {
    case off = "0", m15 = "15", m30 = "30", m60 = "60", m120 = "120"
    var label: String {
        switch self {
        case .off:  return "关闭"
        case .m15:  return "15 分"
        case .m30:  return "30 分"
        case .m60:  return "1 小时"
        case .m120: return "2 小时"
        }
    }
}

/// 强调色预设
struct AccentPreset: Identifiable {
    let id: String
    let name: String
    let hex: String
    static let all: [AccentPreset] = [
        .init(id: "apple",  name: "Apple 蓝", hex: "#0071e3"),
        .init(id: "indigo", name: "靛青",     hex: "#5e5ce6"),
        .init(id: "teal",   name: "湖水青",   hex: "#0f9b8e"),
        .init(id: "coral",  name: "珊瑚",     hex: "#e8635a"),
        .init(id: "amber",  name: "琥珀",     hex: "#c98a1e"),
        .init(id: "graphite", name: "石墨",   hex: "#5a5a5f"),
    ]
}

/// 学科配色方案预设
struct SubjectPreset: Identifiable {
    let id: String
    let name: String
    let colors: [String: String]
    static let all: [SubjectPreset] = [
        .init(id: "morandi", name: "莫兰迪（默认）", colors: [
            "chinese": "#a96f6b", "math": "#867a9e", "ela": "#b58455", "chem": "#6f7c9e",
            "phys": "#719070", "bio": "#5b918a", "geo": "#74889c", "ids": "#94836f",
            "history": "#9c7a63", "politics": "#7a8098"]),
        .init(id: "vivid", name: "鲜明", colors: [
            "chinese": "#e8556d", "math": "#7b61ff", "ela": "#f0932b", "chem": "#5468ff",
            "phys": "#2ecc71", "bio": "#12b8a6", "geo": "#3d9be9", "ids": "#c56cf0",
            "history": "#b5651d", "politics": "#5f7d8c"]),
        .init(id: "deep", name: "沉静", colors: [
            "chinese": "#8d5a57", "math": "#5f5878", "ela": "#8a6440", "chem": "#4f5c7e",
            "phys": "#526b52", "bio": "#416d68", "geo": "#566676", "ids": "#6f6255",
            "history": "#6b5544", "politics": "#57606f"]),
    ]
}

@MainActor
final class BoardSettings: ObservableObject {

    static let shared = BoardSettings()

    /* ---------------- 进程角色 ----------------
       大看板与菜单栏小看板是两个独立进程，共用同一份 settings.json。
       「小看板主题」这一组设置只对**面板进程**有效，所以进程得先自报家门：
       菜单栏 App 启动时把它设成 .panel，其余（大看板 / 离屏渲染）保持 .dashboard。 */

    enum Role { case dashboard, panel }
    static var role: Role = .dashboard

    /// 离屏自检用：只改内存、不落盘。
    /// RenderCheck 会为了试不同主题去动 theme / paletteID 这些真设置，
    /// 不关掉写盘的话，跑一次自检就把用户的设置写花了。
    static var readOnly = false

    /// 自检 / 测试用：把设置文件指到别处。
    /// 正常运行时是 nil（就是数据目录下的 settings.json）；
    /// 「恢复新手导览」这种会清空档案的操作，得能在副本上试，不能拿真设置当小白鼠。
    static var fileOverridePath: String? = nil

    static var fileURL: URL {
        if let p = BoardSettings.fileOverridePath { return URL(fileURLWithPath: p) }
        let dir = MBBPaths.home
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("settings.json")
    }

    /* ---------------- ⓪ 使用者档案（首次使用会问，之后可改） ----------------
       这一条很关键：**名字绝不能写死在代码里**。
       EC 名单是按**英语名**匹配的，所以首次启动必须问到真实英语名，
       否则「今天要不要去 English Corner」永远算不对。 */

    @Published var englishName: String = ""      { didSet { save(); syncECStudent() } }
    @Published var displayName: String = ""      { didSet { save() } }
    @Published var gradeLabel: String = "G10"    { didSet { save() } }
    /// 是否走完了首次引导
    @Published var onboarded: Bool = false       { didSet { save() } }

    /* ---------------- 学校 ManageBac 地址 ----------------
       默认值就是本校（见 SchoolURL.fallback）。同学拿到 App 直接能用；
       别的学校的人在这里改一处，不用碰代码。后端每次抓取前也会重读它。 */
    @Published var schoolURL: String = SchoolURL.fallback {
        didSet {
            let v = SchoolURL.norm(schoolURL)
            SchoolURL.current = v
            if v != schoolURL { schoolURL = v; return }   // 回写一次（规范化）
            save()
        }
    }

    var hasProfile: Bool {
        !englishName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
    /// 界面上的称呼：没填中文名就用英语名，再不行给个中性称呼
    var greeting: String {
        let d = displayName.trimmingCharacters(in: .whitespaces)
        if !d.isEmpty { return d }
        let e = englishName.trimmingCharacters(in: .whitespaces)
        if !e.isEmpty { return String(e.split(separator: " ").first ?? "") }
        return "同学"
    }

    /// 把英语名同步给后端（EC 名单靠它找人）
    func syncECStudent() {
        let name = englishName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        let dir = MBBPaths.home
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let f = dir.appendingPathComponent("ec.json")
        var d: [String: Any] = [:]
        if let raw = try? Data(contentsOf: f),
           let old = try? JSONSerialization.jsonObject(with: raw) as? [String: Any] { d = old }
        d["student"] = name
        if let out = try? JSONSerialization.data(withJSONObject: d, options: [.prettyPrinted]) {
            try? out.write(to: f, options: .atomic)
        }
    }

    /* ---------------- ① 外观与主题 ---------------- */

    /// 当前调色板 id：standard / emberglow / verdant
    @Published var paletteID: String = "standard" {
        didSet {
            guard !loading else { return }
            applyPalette()
            // 换主题也可能改变「实际生效的深浅色」（`forcesDark` 的主题会强制深色），
            // 所以这里必须跟着刷一遍 AppKit 的 appearance —— 只写 `didSet` 在
            // `theme` 上是不够的，那样「换成月圆」不会把窗口变暗。
            Appearance.apply(effectiveTheme)
            save()
        }
    }
    /// 用主题原图铺一层极淡的氛围底纹（只对限时主题有意义）
    @Published var themeBackdrop: Bool = true     { didSet { save() } }

    @Published var theme: ThemeMode = .system            { didSet { save(); Appearance.apply(effectiveTheme) } }
    @Published var density: Density = .comfortable       { didSet { save() } }
    @Published var corner: CornerStyle = .regular        { didSet { save() } }
    /// 液态玻璃强度 0…1（0 = 纯色卡面）
    @Published var glassStrength: Double = 1.0           { didSet { save() } }

    /* --- 弹窗那圈液态玻璃描边的可调项 ---
       用户明确表扬过这圈描边，同时要求「加入一些可调整选项，但千万不要破坏
       默认的原效果」。所以：下面四个的默认值**就是**原来写死的那套数值
       （7pt / 1.0 / 0.94 / 投影开），全新装的 App 与改这版之前长得一模一样，
       改滑块才有变化。 */

    /// 描边宽度（pt）。液态玻璃的「边框感」来自这圈铺开的折射，7 是原值
    @Published var glassPanelBorder: Double = 7.0        { didSet { save() } }
    /// 描边顶部那圈白色高光的强度 0…1（1 = 原效果，0 = 完全不要高光）
    @Published var glassPanelRim: Double = 1.0           { didSet { save() } }
    /// 内圈毛玻璃的挡色程度 0.55…1（越大越不透底色；0.94 = 原效果）
    @Published var glassPanelBody: Double = 0.94         { didSet { save() } }
    /// 弹窗是否投影
    @Published var glassPanelShadow: Bool = true         { didSet { save() } }
    /// 浮窗能不能拖。用户要「整个最上边那部分都能按住拖」，同时又要一个开关 ——
    /// 关掉之后浮窗就钉死在视口正中（有些人就是不喜欢手滑把窗口带跑偏）。
    @Published var panelDrag: Bool = true                { didSet { save() } }
    /// 全局字号缩放 0.85…1.25
    @Published var fontScale: Double = 1.0               { didSet { save() } }
    /// 强制减弱动效（系统已开「减弱动态效果」时自动等效为 true）
    @Published var reduceMotion: Bool = false            { didSet { save(); Motion.setReduceFlag(reduceMotion) } }
    /// 动效档位：normal / breathe / vivid —— 用户在设置里可切
    @Published var motionStyle: Motion.MotionStyle = .breathe { didSet { save(); Motion.setStyle(motionStyle) } }
    /// 降低透明度：玻璃退化为实色，字更清楚
    @Published var reduceTransparency: Bool = false      { didSet { save() } }
    /// 水墨印章（雅/壹/贰/叁/肆/伍 那些汉字小印）：默认关，想要雅趣再开
    @Published var showSeals: Bool = false               { didSet { save() } }

    /* ---------------- ② 强调色与学科配色 ---------------- */

    @Published var accentHex: String = "#0071e3"         { didSet { save() } }
    @Published var subjectColors: [String: String] = SubjectPreset.all[0].colors { didSet { save() } }
    @Published var subjectPresetID: String = "morandi"   { didSet { save() } }

    /* ---------------- ③ 待办紧急度阈值（小时） ---------------- */

    @Published var urgentHours: Double = 26              { didSet { save() } }
    @Published var soonHours: Double = 50                { didSet { save() } }
    @Published var blueHours: Double = 74                { didSet { save() } }
    /// 看板「待办」里不显示的关键词（一行一个）
    @Published var hiddenKeywords: String = "背诵视频"    { didSet { save() } }
    /// 是否把逾期项算进紧凑计数
    @Published var countOverdue: Bool = false            { didSet { save() } }

    /* ---------------- ④ 刷新与启动 ---------------- */

    @Published var refreshMinutes: Double = 5            { didSet { save() } }
    @Published var prefetchMinutes: Double = 30          { didSet { save(); if !loading { pushPrefetch() } } }
    @Published var launchAtLogin: Bool = false           { didSet { save() } }
    /// 菜单栏 / 托盘上显示哪些档位
    @Published var showRed: Bool = true                  { didSet { save() } }
    @Published var showYellow: Bool = true               { didSet { save() } }
    @Published var showBlue: Bool = true                 { didSet { save() } }
    @Published var labelStyle: LabelStyle = .dots        { didSet { save() } }
    /// 菜单栏面板宽度
    @Published var panelWidth: Double = 470              { didSet { save() } }

    /* ---------------- ⑤ 作息与看板 ---------------- */

    @Published var wakeTime: String = "06:00"            { didSet { save() } }
    @Published var nightStart: String = "18:30"          { didSet { save() } }
    @Published var nightEnd: String = "22:30"            { didSet { save() } }
    @Published var dashboardSection: String = "todo"      { didSet { save() } }
    /// 「跳到某一页」的一次性请求：菜单栏小面板点某一项时用。
    /// **刻意不持久化**（save() 不会写它，load() 也不读），用完就清掉 ——
    /// 它表达的是「这一次去那一页」，不是「以后都停在那页」。
    @Published var jumpToSection: DashSection? = nil
    @Published var showFooterHints: Bool = true          { didSet { save() } }
    /// 看板里每页最多显示多少条待办（0 = 不限）
    @Published var taskLimit: Double = 0                 { didSet { save() } }

    /* ---------------- ⑥ 通知 ----------------
       可自定义程度按用户要求做到很细：分来源、分学科、分紧急度、还有免打扰时段。 */

    @Published var notifyEnabled: Bool = false        { didSet { save(); Notifier.sync(settings: self) } }
    /// 待办到期提醒
    @Published var notifyTask: Bool = true            { didSet { save() } }
    /// 只有「紧急」档才提醒（免得被黄蓝档刷屏）
    @Published var notifyTaskRedOnly: Bool = true     { didSet { save() } }
    /// 到期前多少小时提醒
    @Published var notifyLeadHours: Double = 2        { didSet { save() } }
    /// 每天早上的汇总（几点推一条「今天有什么」）
    @Published var notifyDigest: Bool = true          { didSet { save() } }
    @Published var notifyDigestAt: String = "07:00"   { didSet { save() } }
    /// 分来源
    @Published var notifyTeams: Bool = true           { didSet { save() } }
    @Published var notifyMail: Bool = false           { didSet { save() } }
    @Published var notifyEvents: Bool = true          { didSet { save() } }
    @Published var notifyGrades: Bool = true          { didSet { save() } }
    @Published var notifyEC: Bool = true              { didSet { save() } }
    /// EC 提前多少分钟提醒
    @Published var notifyECLead: Double = 30          { didSet { save() } }
    /// 只通知这些学科（空数组 = 全部）
    @Published var notifySubjects: [String] = []      { didSet { save() } }
    /// 免打扰时段
    @Published var notifyQuietOn: Bool = true         { didSet { save() } }
    @Published var notifyQuietFrom: String = "22:30"  { didSet { save() } }
    @Published var notifyQuietTo: String = "06:30"    { didSet { save() } }
    @Published var notifySound: Bool = true           { didSet { save() } }
    /// 通知上挂学科图标（用学科色 + 学科符号）
    @Published var notifySubjectIcon: Bool = true     { didSet { save() } }

    /* ---------------- ⑦ 打开链接的方式 ----------------
       用户要求：App 里所有跳转网页相关的都可以在设置里配。 */

    /// 全局默认：system（系统浏览器）/ builtin（App 内置浏览窗）/ copy（只复制链接）
    @Published var linkTarget: String = "system"      { didSet { save() } }
    /// 按来源单独覆盖，key: managebac / teams / ec / seiue / grade / mail
    @Published var linkOverrides: [String: String] = [:] { didSet { save() } }
    /// 一律用内置浏览窗打开（覆盖上面的默认与按来源设置）—— 用户觉得内置窗好用，想要个一键开关
    @Published var linkAllBuiltin: Bool = false       { didSet { save() } }

    /* ---------------- ⑧ 小看板（菜单栏面板）自定义 ---------------- */

    /// 小看板主题是否跟随大看板（配色 + 深浅色一起跟）—— 默认跟随
    @Published var panelThemeFollow: Bool = true      { didSet { save() } }
    /// 不跟随时，小看板自己的深浅色
    @Published var panelThemeMode: String = "system"  { didSet { save() } }
    /// 不跟随时，小看板自己的调色板
    @Published var panelPaletteID: String = "standard" { didSet { save() } }
    /// 不跟随时，小看板自己的强调色（留空 = 跟着 panelPaletteID 的出厂强调色）。
    /// 以前面板里那个自绘取色块写的是 accentHex —— 那是**大看板**的强调色，
    /// 面板进程里根本不读它：取色在面板上毫无反应，却把大看板改了色。
    @Published var panelAccentHex: String = ""        { didSet { save() } }

    @Published var panelShowTimer: Bool = true        { didSet { save() } }
    @Published var panelShowTodo: Bool = true         { didSet { save() } }
    @Published var panelShowClass: Bool = true        { didSet { save() } }
    @Published var panelShowScore: Bool = true        { didSet { save() } }
    @Published var panelShowEC: Bool = true           { didSet { save() } }
    @Published var panelShowQuick: Bool = true        { didSet { save() } }
    /// 快速设置默认展开（默认收起，用户要求的）
    @Published var panelQuickOpen: Bool = false       { didSet { save() } }
    /// 待办在面板里显示几条（折叠前的数量）
    @Published var panelTodoRows: Double = 5          { didSet { save() } }
    /// 成绩一排几个（默认 4）
    @Published var panelScoreCols: Double = 4         { didSet { save() } }
    /// 面板整体高度
    @Published var panelHeight: Double = 660          { didSet { save() } }
    /// 面板里隐藏已逾期区块
    @Published var panelHideOverdue: Bool = false     { didSet { save() } }

    /* ---------------- ⑨ 刷新（分对象更细） ---------------- */

    /// Teams 轮询间隔（秒）—— 服务端有 TTL，问勤也不会打爆 Graph
    @Published var refreshTeamsSec: Double = 90       { didSet { save() } }
    /// 只在看板/面板可见时刷新（省电）
    @Published var refreshWhenVisibleOnly: Bool = true { didSet { save() } }

    /* ---------------- ⑩ 希悦（SEIUE）课表 ---------------- */

    @Published var seiueEnabled: Bool = false         { didSet { save() } }
    /// 一周抓一次
    @Published var seiueRefreshDays: Double = 7       { didSet { save() } }
    /// 用希悦课表覆盖/补充 ManageBac 的课表
    @Published var seiueForSchedule: Bool = true      { didSet { save() } }
    /// 希悦账号（邮箱 / 手机号）—— 密码不落盘，只交给系统钥匙串
    @Published var seiueAccount: String = ""          { didSet { save() } }
    @Published var seiueLastSync: Double = 0          { didSet { save() } }
    /// 「自动接上课表」只做一次。用户在浏览器里登过希悦、电脑上留着登录态时，
    /// 开机探测到课表就替他把这一项打开；他之后手动关掉，就不再自作主张。
    @Published var seiueAutoV2: Bool = false          { didSet { save() } }

    /* ---------------- ⑪ 快捷键（全部可改） ----------------
       存成 "cmd+shift+r" 这种规范串；空串 = 不绑定。
       解析与展示都走 Shortcut 那一处，改完立刻生效。 */

    @Published var keyRefresh: String = "cmd+r"           { didSet { save() } }
    @Published var keySearch: String = "cmd+f"            { didSet { save() } }
    @Published var keyNextSection: String = "cmd+]"       { didSet { save() } }
    @Published var keyPrevSection: String = "cmd+["       { didSet { save() } }
    @Published var keyTogglePanel: String = "cmd+shift+m" { didSet { save() } }
    @Published var keyToggleTheme: String = "cmd+shift+d" { didSet { save() } }
    @Published var keyOpenSettings: String = "cmd+,"      { didSet { save() } }

    /* 每个分区一个直达键 —— 用户要求「点这个快捷键之后直接跳转到对应的板块」。
       默认用 ⌘1–⌘5：这是 macOS 里「切到第 N 个标签页」的通用约定，
       不用学，几个指头的位置也最顺手。
       ⚠️ 新增板块时要一起加：以前只有 ⌘1–⌘4，后来加了「灵析 AI」板块
          却没补 ⌘5，设置页「跳到板块」那行就变成只列四个 —— 用户会以为
          灵析 AI 没有快捷键，或者干脆以为它不算一个板块。 */
    @Published var keySectionTodo: String = "cmd+1"       { didSet { save() } }
    @Published var keySectionTeams: String = "cmd+2"      { didSet { save() } }
    @Published var keySectionClasses: String = "cmd+3"    { didSet { save() } }
    @Published var keySectionGrades: String = "cmd+4"     { didSet { save() } }
    @Published var keySectionAI: String = "cmd+5"         { didSet { save() } }

    /* ---------------- 派生 ---------------- */

    var accent: RGB { RGB(accentHex) }

    /* 小看板主题：默认整套跟随大看板；用户也可以让面板走自己的一套 */

    /// 小看板实际使用的深浅色
    var panelTheme: ThemeMode {
        guard !panelThemeFollow else { return effectiveTheme }
        return ThemeMode(rawValue: panelThemeMode) ?? .system
    }

    /// 小看板实际使用的调色板
    var panelPalette: Palette {
        panelThemeFollow ? palette : Palettes.by(panelPaletteID)
    }

    /// 界面该用的深浅色。
    /// 第 18 轮合并成单 App 之后，「小看板独立主题」这条分支去掉了：
    /// 主窗口和菜单栏面板在同一个进程里，全局色板只能有一套，
    /// 谁也不可能一边亮一边暗。这里统一跟着看板主题走。
    ///
    /// **但是**：景观主题（「月圆 · LunaOS」）自带 `forcesDark` —— 选了它就
    /// 强制深色。这是用户明确要的「切换到月圆主题，整个 APP 就自动切换成深色」。
    /// 关键在于**不去改 `theme` 本身**：用户原来选的「跟随系统 / 浅色」原封不动
    /// 存着，换回别的主题看一眼就恢复原样 —— 不然「切一次主题」就会偷偷
    /// 把用户的偏好永久改掉。
    var effectiveTheme: ThemeMode { palette.forcesDark ? .dark : theme }

    /// 界面该用的强调色（同上：就一套）
    var uiAccent: RGB { accent }

    var densityScale: CGFloat { Density(rawValue: density.rawValue)?.scale ?? 1.0 }

    var look: GlassLook {
        GlassLook(strength: reduceTransparency ? 0 : glassStrength, reduceTransparency: reduceTransparency)
    }

    func subject(_ key: String, fallback: RGB) -> RGB {
        if let h = subjectColors[key] { return RGB(h) }
        return fallback
    }

    var hiddenList: [String] {
        hiddenKeywords.split(whereSeparator: { $0 == "\n" || $0 == "," || $0 == "，" })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    /// 把「任务详情预取间隔」推给桥接服务（后台预取线程按它跑；0 = 关）
    func pushPrefetch() {
        let seconds = Int(max(0, prefetchMinutes) * 60)
        Task {
            _ = await Bridge.post("/api/prefetch", ["interval": seconds])
        }
    }

    /// 阈值自动纠正：必须严格递增，否则分档会塌掉
    func normalizeThresholds() {
        let a = max(1, min(urgentHours, 200))
        let b = max(a + 1, min(soonHours, 400))
        let c = max(b + 1, min(blueHours, 800))
        if a != urgentHours { urgentHours = a }
        if b != soonHours { soonHours = b }
        if c != blueHours { blueHours = c }
    }

    func applySubjectPreset(_ id: String) {
        guard let p = SubjectPreset.all.first(where: { $0.id == id }) else { return }
        subjectPresetID = id
        subjectColors = p.colors
    }

    /* ---------------- 主题（调色板） ---------------- */

    var palette: Palette { Palettes.by(paletteID) }

    /// 换主题：把调色板激活到全局，并把强调色 / 学科色一并带过去。
    /// 之后用户仍可单独微调强调色与某一科的颜色（微调后 paletteID 不变，
    /// 但 accentHex / subjectColors 已经是用户自己的值了）。
    func applyPalette() {
        let p = Palettes.by(paletteID)
        ThemeRuntime.activate(p)
        accentHex = p.accent
        subjectColors = p.subjects
        subjectPresetID = p.isLimited ? "主题·\(p.name)" : "morandi"
    }

    /// 只激活、不覆盖用户自定义（读盘 / 启动时用）
    func activatePaletteOnly() {
        ThemeRuntime.activate(palette)
    }

    /// 打开某个来源的链接时用哪种方式，先看「一律内置」，再看单独覆盖，再看全局默认
    func linkMode(_ source: String) -> String {
        if linkAllBuiltin { return "builtin" }
        return linkOverrides[source] ?? linkTarget
    }

    /* ---------------- 读写 ---------------- */

    private var loading = false
    private var saving = false
    /// 自己最近一次写盘的字节；用来把「监听到的自己的写入」认出来
    private var lastWritten: Data?

    private struct Blob: Codable {
        var v: Int = 1

        // ⓪ 使用者档案
        var englishName: String? = nil
        var displayName: String? = nil
        var gradeLabel: String? = nil
        var onboarded: Bool? = nil

        // ① 外观与主题
        var paletteID: String? = nil
        var themeBackdrop: Bool? = nil
        var theme: String? = nil
        var density: String? = nil
        var corner: String? = nil
        var glassStrength: Double? = nil
        var glassPanelBorder: Double? = nil
        var glassPanelRim: Double? = nil
        var glassPanelBody: Double? = nil
        var glassPanelShadow: Bool? = nil
        var panelDrag: Bool? = nil
        var fontScale: Double? = nil
        var reduceMotion: Bool? = nil
        var motionStyle: String? = nil
        var reduceTransparency: Bool? = nil

        // ② 色彩
        var accentHex: String? = nil
        var subjectColors: [String: String]? = nil
        var subjectPresetID: String? = nil

        // ③ 待办阈值
        var urgentHours: Double? = nil
        var soonHours: Double? = nil
        var blueHours: Double? = nil
        var hiddenKeywords: String? = nil
        var countOverdue: Bool? = nil

        // ④ 刷新与启动
        var refreshMinutes: Double? = nil
        var prefetchMinutes: Double? = nil
        var refreshTeamsSec: Double? = nil
        var refreshWhenVisibleOnly: Bool? = nil
        var launchAtLogin: Bool? = nil
        var showRed: Bool? = nil
        var showYellow: Bool? = nil
        var showBlue: Bool? = nil
        var labelStyle: String? = nil

        // ⑤ 看板与作息
        var panelWidth: Double? = nil
        var wakeTime: String? = nil
        var nightStart: String? = nil
        var nightEnd: String? = nil
        var dashboardSection: String? = nil

        var showFooterHints: Bool? = nil
        var taskLimit: Double? = nil

        // ⑥ 通知
        var notifyEnabled: Bool? = nil
        var notifyTask: Bool? = nil
        var notifyTaskRedOnly: Bool? = nil
        var notifyLeadHours: Double? = nil
        var notifyDigest: Bool? = nil
        var notifyDigestAt: String? = nil
        var notifyTeams: Bool? = nil
        var notifyMail: Bool? = nil
        var notifyEvents: Bool? = nil
        var notifyGrades: Bool? = nil
        var notifyEC: Bool? = nil
        var notifyECLead: Double? = nil
        var notifySubjects: [String]? = nil
        var notifyQuietOn: Bool? = nil
        var notifyQuietFrom: String? = nil
        var notifyQuietTo: String? = nil
        var notifySound: Bool? = nil
        var notifySubjectIcon: Bool? = nil

        // ⑦ 链接打开方式
        var linkTarget: String? = nil
        var linkOverrides: [String: String]? = nil
        var linkAllBuiltin: Bool? = nil

        /// 学校 ManageBac 地址。默认值在 SchoolURL.fallback 里（集中一处），
        /// 换学校改这里就行，不用碰代码。别校的人也不会看到本校地址被写死。
        var schoolURL: String? = nil

        // ⑧ 小看板自定义
        var panelThemeFollow: Bool? = nil
        var panelThemeMode: String? = nil
        var panelPaletteID: String? = nil
        var panelAccentHex: String? = nil
        var panelShowTimer: Bool? = nil
        var panelShowTodo: Bool? = nil
        var panelShowClass: Bool? = nil
        var panelShowScore: Bool? = nil
        var panelShowEC: Bool? = nil
        var panelShowQuick: Bool? = nil
        var panelQuickOpen: Bool? = nil
        var panelTodoRows: Double? = nil
        var panelScoreCols: Double? = nil
        var panelHeight: Double? = nil
        var panelHideOverdue: Bool? = nil

        // ⑩ 希悦
        var seiueEnabled: Bool? = nil
        var seiueRefreshDays: Double? = nil
        var seiueForSchedule: Bool? = nil
        var seiueAccount: String? = nil
        var seiueLastSync: Double? = nil
        var seiueAutoV2: Bool? = nil

        // ⑪ 快捷键
        var keyRefresh: String? = nil
        var keySearch: String? = nil
        var keyNextSection: String? = nil
        var keyPrevSection: String? = nil
        var keyTogglePanel: String? = nil
        var keyToggleTheme: String? = nil
        var keyOpenSettings: String? = nil
        var keySectionTodo: String? = nil
        var keySectionTeams: String? = nil
        var keySectionClasses: String? = nil
        var keySectionGrades: String? = nil
        var keySectionAI: String? = nil
    }

    private init() {
        load()
        startWatching()
    }

    /// 把档案里的英语名同步给后端；顺带保证 EC 名单能立刻按新名字重算
    private func propagateProfile() {
        activatePaletteOnly()
        Motion.setStyle(motionStyle)
        Motion.setReduceFlag(reduceMotion)
        syncECStudent()
    }

    func load() {
        loading = true
        /// 载入过程中发现需要回写的校正（载入期间 save() 是被按住的，得等它放开）
        var fixups = false
        defer {
            loading = false
            normalizeThresholds()
            propagateProfile()
            Appearance.apply(effectiveTheme)
            if fixups { save() }
        }
        guard let data = try? Data(contentsOf: BoardSettings.fileURL),
              let b = try? JSONDecoder().decode(Blob.self, from: data) else { return }

        // ⓪ 档案
        if let v = b.englishName { englishName = v }
        if let v = b.displayName { displayName = v }
        if let v = b.gradeLabel { gradeLabel = v }
        if let v = b.onboarded { onboarded = v }
        // ① 外观与主题
        if let v = b.paletteID { paletteID = v }
        if let v = b.themeBackdrop { themeBackdrop = v }
        if let v = b.theme, let x = ThemeMode(rawValue: v) { theme = x }
        if let v = b.density, let x = Density(rawValue: v) { density = x }
        if let v = b.corner, let x = CornerStyle(rawValue: v) { corner = x }
        if let v = b.glassStrength { glassStrength = v }
        if let v = b.glassPanelBorder { glassPanelBorder = v }
        if let v = b.glassPanelRim { glassPanelRim = v }
        if let v = b.glassPanelBody { glassPanelBody = v }
        if let v = b.glassPanelShadow { glassPanelShadow = v }
        if let v = b.panelDrag { panelDrag = v }
        if let v = b.fontScale { fontScale = v }
        if let v = b.reduceMotion { reduceMotion = v }
        if let v = b.motionStyle, let x = Motion.MotionStyle(rawValue: v) { motionStyle = x }
        if let v = b.reduceTransparency { reduceTransparency = v }
        // ② 色彩
        if let v = b.accentHex { accentHex = v }
        if let v = b.subjectColors { subjectColors = v }
        if let v = b.subjectPresetID { subjectPresetID = v }
        // ③ 阈值
        if let v = b.urgentHours { urgentHours = v }
        if let v = b.soonHours { soonHours = v }
        if let v = b.blueHours { blueHours = v }
        if let v = b.hiddenKeywords { hiddenKeywords = v }
        if let v = b.countOverdue { countOverdue = v }
        // ④ 刷新与启动
        if let v = b.refreshMinutes { refreshMinutes = v }
        if let v = b.prefetchMinutes { prefetchMinutes = v }
        if let v = b.refreshTeamsSec { refreshTeamsSec = v }
        if let v = b.refreshWhenVisibleOnly { refreshWhenVisibleOnly = v }
        if let v = b.launchAtLogin { launchAtLogin = v }
        if let v = b.showRed { showRed = v }
        if let v = b.showYellow { showYellow = v }
        if let v = b.showBlue { showBlue = v }
        if let v = b.labelStyle, let x = LabelStyle(rawValue: v) { labelStyle = x }
        // ⑤ 看板与作息
        if let v = b.panelWidth { panelWidth = v }
        if let v = b.wakeTime { wakeTime = v }
        if let v = b.nightStart { nightStart = v }
        if let v = b.nightEnd { nightEnd = v }
        if let v = b.dashboardSection { dashboardSection = v }
        // ★ 一次性校正：菜单栏小面板以前点哪一项就往这里写哪一项
        //   （见 MenuBar/Panel.swift 的 openDashboard），于是「默认停在哪一页」
        //   会悄悄变成「最后一次在小面板里点开的页」——用户看到的就是
        //   「每次进去都落在设置页」。那处写入已经去掉，这里再把已经写坏的值
        //   扶回「待办」。标记位放 UserDefaults、不放 settings.json：
        //   settings.json 会被主窗口和小面板两边各自整份覆写，标记位放进去
        //   会被后写的那一份抹掉，于是每次开机都重新「扶」一次 —— 用户手动
        //   把默认页改成别的，下次开机又被打回「待办」。
        let navKey = "mb.nav.defaultV2"
        if !UserDefaults.standard.bool(forKey: navKey) {
            dashboardSection = DashSection.todo.rawValue
            UserDefaults.standard.set(true, forKey: navKey)
            fixups = true
        }
        if let v = b.showFooterHints { showFooterHints = v }
        if let v = b.taskLimit { taskLimit = v }
        // ⑥ 通知
        if let v = b.notifyEnabled { notifyEnabled = v }
        if let v = b.notifyTask { notifyTask = v }
        if let v = b.notifyTaskRedOnly { notifyTaskRedOnly = v }
        if let v = b.notifyLeadHours { notifyLeadHours = v }
        if let v = b.notifyDigest { notifyDigest = v }
        if let v = b.notifyDigestAt { notifyDigestAt = v }
        if let v = b.notifyTeams { notifyTeams = v }
        if let v = b.notifyMail { notifyMail = v }
        if let v = b.notifyEvents { notifyEvents = v }
        if let v = b.notifyGrades { notifyGrades = v }
        if let v = b.notifyEC { notifyEC = v }
        if let v = b.notifyECLead { notifyECLead = v }
        if let v = b.notifySubjects { notifySubjects = v }
        if let v = b.notifyQuietOn { notifyQuietOn = v }
        if let v = b.notifyQuietFrom { notifyQuietFrom = v }
        if let v = b.notifyQuietTo { notifyQuietTo = v }
        if let v = b.notifySound { notifySound = v }
        if let v = b.notifySubjectIcon { notifySubjectIcon = v }
        // ⑦ 链接
        if let v = b.linkTarget { linkTarget = v }
        if let v = b.linkOverrides { linkOverrides = v }
        if let v = b.linkAllBuiltin { linkAllBuiltin = v }
        // ⑦.5 学校地址（空值不动，避免旧设置把默认值抹掉）
        if let v = b.schoolURL, !v.isEmpty { schoolURL = v }
        // ⑧ 小看板
        if let v = b.panelThemeFollow { panelThemeFollow = v }
        if let v = b.panelThemeMode { panelThemeMode = v }
        if let v = b.panelPaletteID { panelPaletteID = v }
        if let v = b.panelAccentHex { panelAccentHex = v }
        if let v = b.panelShowTimer { panelShowTimer = v }
        if let v = b.panelShowTodo { panelShowTodo = v }
        if let v = b.panelShowClass { panelShowClass = v }
        if let v = b.panelShowScore { panelShowScore = v }
        if let v = b.panelShowEC { panelShowEC = v }
        if let v = b.panelShowQuick { panelShowQuick = v }
        if let v = b.panelQuickOpen { panelQuickOpen = v }
        if let v = b.panelTodoRows { panelTodoRows = v }
        if let v = b.panelScoreCols { panelScoreCols = v }
        if let v = b.panelHeight { panelHeight = v }
        if let v = b.panelHideOverdue { panelHideOverdue = v }
        // ⑩ 希悦
        if let v = b.seiueEnabled { seiueEnabled = v }
        if let v = b.seiueRefreshDays { seiueRefreshDays = v }
        if let v = b.seiueForSchedule { seiueForSchedule = v }
        if let v = b.seiueAccount { seiueAccount = v }
        if let v = b.seiueLastSync { seiueLastSync = v }
        if let v = b.seiueAutoV2 { seiueAutoV2 = v }
        // ⑪ 快捷键
        if let v = b.keyRefresh { keyRefresh = v }
        if let v = b.keySearch { keySearch = v }
        if let v = b.keyNextSection { keyNextSection = v }
        if let v = b.keyPrevSection { keyPrevSection = v }
        if let v = b.keyTogglePanel { keyTogglePanel = v }
        if let v = b.keyToggleTheme { keyToggleTheme = v }
        if let v = b.keyOpenSettings { keyOpenSettings = v }
        if let v = b.keySectionTodo { keySectionTodo = v }
        if let v = b.keySectionTeams { keySectionTeams = v }
        if let v = b.keySectionClasses { keySectionClasses = v }
        if let v = b.keySectionGrades { keySectionGrades = v }
        if let v = b.keySectionAI { keySectionAI = v }
    }

    func save() {
        guard !loading, !saving, !BoardSettings.readOnly else { return }
        saving = true
        defer { saving = false }

        var b = Blob()
        // ⓪ 档案
        b.englishName = englishName; b.displayName = displayName
        b.gradeLabel = gradeLabel; b.onboarded = onboarded
        // ① 外观与主题
        b.paletteID = paletteID; b.themeBackdrop = themeBackdrop
        b.theme = theme.rawValue; b.density = density.rawValue; b.corner = corner.rawValue
        b.glassStrength = glassStrength; b.fontScale = fontScale
        b.glassPanelBorder = glassPanelBorder; b.glassPanelRim = glassPanelRim
        b.glassPanelBody = glassPanelBody; b.glassPanelShadow = glassPanelShadow
        b.panelDrag = panelDrag
        b.reduceMotion = reduceMotion; b.reduceTransparency = reduceTransparency
        // ② 色彩
        b.accentHex = accentHex; b.subjectColors = subjectColors; b.subjectPresetID = subjectPresetID
        // ③ 阈值
        b.urgentHours = urgentHours; b.soonHours = soonHours; b.blueHours = blueHours
        b.hiddenKeywords = hiddenKeywords; b.countOverdue = countOverdue
        // ④ 刷新与启动
        b.refreshMinutes = refreshMinutes; b.prefetchMinutes = prefetchMinutes
        b.refreshTeamsSec = refreshTeamsSec
        b.refreshWhenVisibleOnly = refreshWhenVisibleOnly
        b.launchAtLogin = launchAtLogin
        b.showRed = showRed; b.showYellow = showYellow; b.showBlue = showBlue
        b.labelStyle = labelStyle.rawValue
        // ⑤ 看板与作息
        b.panelWidth = panelWidth
        b.wakeTime = wakeTime; b.nightStart = nightStart; b.nightEnd = nightEnd
        b.dashboardSection = dashboardSection; b.showFooterHints = showFooterHints
        b.taskLimit = taskLimit
        // ⑥ 通知
        b.notifyEnabled = notifyEnabled; b.notifyTask = notifyTask
        b.notifyTaskRedOnly = notifyTaskRedOnly; b.notifyLeadHours = notifyLeadHours
        b.notifyDigest = notifyDigest; b.notifyDigestAt = notifyDigestAt
        b.notifyTeams = notifyTeams; b.notifyMail = notifyMail
        b.notifyEvents = notifyEvents; b.notifyGrades = notifyGrades
        b.notifyEC = notifyEC; b.notifyECLead = notifyECLead
        b.notifySubjects = notifySubjects
        b.notifyQuietOn = notifyQuietOn; b.notifyQuietFrom = notifyQuietFrom
        b.notifyQuietTo = notifyQuietTo; b.notifySound = notifySound
        b.notifySubjectIcon = notifySubjectIcon
        // ⑦ 链接
        b.linkTarget = linkTarget; b.linkOverrides = linkOverrides
        b.linkAllBuiltin = linkAllBuiltin
        b.schoolURL = schoolURL
        // ⑧ 小看板
        b.panelThemeFollow = panelThemeFollow
        b.panelThemeMode = panelThemeMode
        b.panelPaletteID = panelPaletteID
        b.panelAccentHex = panelAccentHex
        b.panelShowTimer = panelShowTimer; b.panelShowTodo = panelShowTodo
        b.panelShowClass = panelShowClass; b.panelShowScore = panelShowScore
        b.panelShowEC = panelShowEC; b.panelShowQuick = panelShowQuick
        b.panelQuickOpen = panelQuickOpen; b.panelTodoRows = panelTodoRows
        b.panelScoreCols = panelScoreCols; b.panelHeight = panelHeight
        b.panelHideOverdue = panelHideOverdue
        // ⑩ 希悦
        b.seiueEnabled = seiueEnabled; b.seiueRefreshDays = seiueRefreshDays
        b.seiueForSchedule = seiueForSchedule
        b.seiueAccount = seiueAccount; b.seiueLastSync = seiueLastSync
        b.seiueAutoV2 = seiueAutoV2
        // ⑪ 快捷键
        b.keyRefresh = keyRefresh; b.keySearch = keySearch
        b.keyNextSection = keyNextSection; b.keyPrevSection = keyPrevSection
        b.keyTogglePanel = keyTogglePanel; b.keyToggleTheme = keyToggleTheme
        b.keyOpenSettings = keyOpenSettings
        b.keySectionTodo = keySectionTodo; b.keySectionTeams = keySectionTeams
        b.keySectionClasses = keySectionClasses; b.keySectionGrades = keySectionGrades
        b.keySectionAI = keySectionAI

        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? enc.encode(b) {
            lastWritten = data          // 先记下来，免得被自己的文件监听当成「外部改动」
            try? data.write(to: BoardSettings.fileURL, options: .atomic)
            // 权限收紧：里面有作息、隐藏词等个人偏好，不该被别的用户读到
            try? FileManager.default.setAttributes([.posixPermissions: 0o600],
                                                   ofItemAtPath: BoardSettings.fileURL.path)
            lastStamp = fileStamp()     // 记下自己的指纹，轮询不会把它当成外部改动
        }
    }

    /* ---------------- 跨进程同步 ----------------
       两个 App（大看板 / 菜单栏小看板）是独立进程，却共用同一份设置文件。
       以前各改各的内存副本：大看板换了主题，小看板要等自己重启才会变 ——
       用户看到的「小看板主题不跟随」就是这个原因。

       两条腿一起走：
         · 目录监听（kqueue）：文件被「原子替换 / 新建」时立刻知道；
         · 2 秒轮询 stat：兜住「就地覆写」这种 kqueue 在目录上不一定报的事件。
           （实测 macOS 上 python/编辑器就地写文件，目录 fd 收不到 NOTE_WRITE，
           所以只有监听是不够的。轮询只是读一次 mtime+size，开销可忽略。）
       自己做过的写入用字节比对排除，避免自激循环。 */

    private var dirWatcher: DispatchSourceFileSystemObject?
    private var watchFD: Int32 = -1
    private var pendingReload: DispatchWorkItem?
    private var pollTimer: Timer?
    /// 上次见到的「文件指纹」：mtime + 字节数
    private var lastStamp: String = ""

    private func fileStamp() -> String {
        let a = try? FileManager.default.attributesOfItem(atPath: BoardSettings.fileURL.path)
        let m = (a?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        let s = (a?[.size] as? Int) ?? 0
        return "\(m)|\(s)"
    }

    private func startWatching() {
        lastStamp = fileStamp()

        // ① 定时兜底
        if pollTimer == nil {
            pollTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.pollForExternalChange() }
            }
        }

        // ② 目录监听：盯「目录」而不是文件本身，因为原子写是「写临时文件 + rename」，
        //    盯文件会跟丢。
        guard dirWatcher == nil else { return }
        let dir = BoardSettings.fileURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let fd = open(dir.path, O_EVTONLY)
        guard fd >= 0 else {
            Log.write("settings 目录监听挂不上（fd<0），只靠轮询")
            return
        }
        watchFD = fd
        let src = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .rename, .delete, .attrib],
            queue: .main)
        src.setEventHandler { [weak self] in self?.scheduleReload() }
        src.setCancelHandler { [weak self] in
            guard let self, self.watchFD >= 0 else { return }
            close(self.watchFD)
            self.watchFD = -1
        }
        src.resume()
        dirWatcher = src
    }

    private func pollForExternalChange() {
        let st = fileStamp()
        guard st != lastStamp else { return }
        lastStamp = st
        reloadFromDisk()
    }

    /// 监听会连续触发多次，合并成一次重读
    private func scheduleReload() {
        pendingReload?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.reloadFromDisk() }
        pendingReload = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: work)
    }

    private func reloadFromDisk() {
        guard let data = try? Data(contentsOf: BoardSettings.fileURL) else { return }
        if let mine = lastWritten, mine == data { return }   // 自己写的，忽略
        lastWritten = data
        let who = BoardSettings.role == .panel ? "小看板" : "大看板"
        Log.write("settings 被另一个进程改过 → \(who)重读")
        load()      // loading 期间不回写；结束时自动重新激活调色板与外观
        Log.write("  ↳ \(who)：主题=\(effectiveTheme.rawValue) 生效调色板=\(ThemeRuntime.palette.id) accent=\(uiAccent.hex)")
    }

    /// 面板进程换主题时用：重新读一遍文件以外的收尾动作
    func refreshThemeForThisProcess() {
        activatePaletteOnly()
        Appearance.apply(effectiveTheme)
    }

    /// 恢复默认：保留身份与登录相关的东西（档案、开机自启），其余全回到出厂。
    func resetAll() {
        let keep = launchAtLogin
        let keepName = englishName, keepDisplay = displayName, keepGrade = gradeLabel
        let keepOnboarded = onboarded
        loading = true
        paletteID = "standard"; themeBackdrop = true
        theme = .system; density = .comfortable; corner = .regular
        glassStrength = 1.0; fontScale = 1.0
        // 描边四项 + 拖动开关回到「原来那套」默认值
        glassPanelBorder = 7.0; glassPanelRim = 1.0
        glassPanelBody = 0.94; glassPanelShadow = true; panelDrag = true
        reduceMotion = false; motionStyle = .breathe; reduceTransparency = false
        showSeals = false
        accentHex = Palettes.standard.accent
        subjectPresetID = "morandi"; subjectColors = Palettes.standard.subjects
        urgentHours = 26; soonHours = 50; blueHours = 74
        hiddenKeywords = "背诵视频"; countOverdue = false
        refreshMinutes = 5; prefetchMinutes = 30; refreshTeamsSec = 90; refreshWhenVisibleOnly = true
        launchAtLogin = keep
        showRed = true; showYellow = true; showBlue = true
        labelStyle = .dots; panelWidth = 470
        wakeTime = "06:00"; nightStart = "18:30"; nightEnd = "22:30"
        // 「打开看板停在哪一页」不跟着重置：它不是外观偏好，而是用户的使用习惯。
        // 以前 resetAll 把它扣回「待办」，于是每次重跑一遍向导、或点一次
        // 「恢复默认」，用户精心选的那一页就没了，开局又掉回待办。
        showFooterHints = true; taskLimit = 0
        // 通知
        notifyEnabled = false; notifyTask = true; notifyTaskRedOnly = true
        notifyLeadHours = 2; notifyDigest = true; notifyDigestAt = "07:00"
        notifyTeams = true; notifyMail = false; notifyEvents = true
        notifyGrades = true; notifyEC = true; notifyECLead = 30
        notifySubjects = []; notifyQuietOn = true
        notifyQuietFrom = "22:30"; notifyQuietTo = "06:30"
        notifySound = true; notifySubjectIcon = true
        // 链接
        linkTarget = "system"; linkOverrides = [:]; linkAllBuiltin = false
        // 小看板
        panelThemeFollow = true; panelThemeMode = "system"; panelPaletteID = "standard"
        panelAccentHex = ""
        panelShowTimer = true; panelShowTodo = true; panelShowClass = true
        panelShowScore = true; panelShowEC = true; panelShowQuick = true
        panelQuickOpen = false; panelTodoRows = 5; panelScoreCols = 4
        panelHeight = 660; panelHideOverdue = false
        // 希悦
        seiueEnabled = false; seiueRefreshDays = 7; seiueForSchedule = true
        seiueAccount = ""; seiueLastSync = 0
        // 「恢复默认」也把「自动接上课表」的名额还回去：用户按下这个按钮的意思
        // 就是「回到第一次用的样子」，那开机时就该再自动认一次课表。
        seiueAutoV2 = false
        // 快捷键
        keyRefresh = "cmd+r"; keySearch = "cmd+f"
        keyNextSection = "cmd+]"; keyPrevSection = "cmd+["
        keyTogglePanel = "cmd+shift+m"; keyToggleTheme = "cmd+shift+d"
        keyOpenSettings = "cmd+,"
        keySectionTodo = "cmd+1"; keySectionTeams = "cmd+2"
        keySectionClasses = "cmd+3"; keySectionGrades = "cmd+4"; keySectionAI = "cmd+5"
        // 档案原样保留
        englishName = keepName; displayName = keepDisplay
        gradeLabel = keepGrade; onboarded = keepOnboarded
        // 「默认停在哪一页」也回出厂：这一项和别的项一样受「恢复默认」影响，
        // 并顺手还回一次性校正名额（标记存在 UserDefaults 里）。
        // 两件事必须一起做 —— 只还名额、不在这里改值的话，用户按完「恢复默认」
        // 当下看到的是旧页，下次开机才突然变成「待办」，像是自己变了。
        dashboardSection = DashSection.todo.rawValue
        UserDefaults.standard.removeObject(forKey: "mb.nav.defaultV2")
        loading = false
        applyPalette()
        save()
    }

    /* ---------------- 恢复新手导览 ----------------
       用户要的「从头重置一遍」：设置回到出厂 **连身份档案一起清掉**，
       然后立刻回到第一屏重新走一遍引导。
       与 resetAll() 的区别：resetAll 保留档案（它只是"恢复默认外观"），
       这里是彻底的第一次使用状态。
       开机自启保留 —— 那是对系统的注册（LaunchAgent），
       在设置里悄悄摘掉会让「引导时选的开机自启」跟系统状态对不上。 */

    func resetForOnboarding() {
        resetAll()                       // 其余全部回出厂（含小看板主题）
        loading = true
        englishName = ""                 // 清档案：引导会重新问
        displayName = ""
        gradeLabel = "G10"
        onboarded = false                // 回到引导
        loading = false
        save()
        clearECStudent()
    }

    /// 把 EC 名单里记着的学生名清掉，否则新档案生效前会按旧名字算 EC
    private func clearECStudent() {
        // 必须走数据目录。这里以前写死 ~/.mbboard/ec.json —— 而**后端读的是
        // <数据目录>/ec.json**，于是改名字这件事在看板上看着做了、实际一点没生效，
        // EC 名单还会按旧名字判断「你在不在里面」。（ec.json 也在启动迁移的清单里，
        // 两边各写一份只会更乱。）
        let f = MBBPaths.home.appendingPathComponent("ec.json")
        guard let raw = try? Data(contentsOf: f),
              var d = try? JSONSerialization.jsonObject(with: raw) as? [String: Any] else { return }
        d["student"] = ""
        if let out = try? JSONSerialization.data(withJSONObject: d, options: [.prettyPrinted]) {
            try? out.write(to: f, options: .atomic)
        }
    }
}
