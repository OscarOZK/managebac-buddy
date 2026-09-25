import SwiftUI
import AppKit
import WebKit
import UniformTypeIdentifiers

/* ======================================================================
   ⑤ 灵析 AI —— 看板里的对话助手

   它和「待办 / Teams / 课程 / 成绩」是同一层的大板块，但形态不一样：
   前面几块是**阅读型**（一屏扫完），这一块是**交互型**。所以它有三条特殊约定：

     ① 不套在外层 ScrollView 里 —— 嵌套滚动会互相抢手势、滚轮会串。
        它自己占满内容区高度，消息区自己滚，输入框永远钉在底部。
     ② 没登录时直接把**真实的登录页**摊在窗口上，登录完自动收起。
        用户不需要知道背后有个「隐藏网页引擎」。
     ③ 配色、圆角、玻璃、密度全部走 Env / Theme —— 和看板其余部分是同一套零件，
        换主题、改圆角、调密度时它跟着一起变，不会像贴上去的外挂。

   实现沿用已验证的三件套：SwiftUI 自绘界面 + opacity 托管的 WKWebView + 注入 JS 双向桥。
   注入脚本是 Resources/ai-inject.js —— **真实文件**，不走 Swift 多行字符串：
   后者会把 JS 里的 \n 变成真换行、把整段脚本撕断，这个坑踩过两次，不再碰。
   ====================================================================== */

/* ---------------- 注入脚本（从 bundle 读，读不到就明确报错，不静默降级） ---------------- */

enum AIInject {
    static let js: String = {
        guard let u = Bundle.main.url(forResource: "ai-inject", withExtension: "js"),
              let s = try? String(contentsOf: u, encoding: .utf8) else {
            Log.write("⚠️ ai-inject.js 没找到 —— 灵析 AI 的网页桥会失效")
            return ""
        }
        return s
    }()
    static var ok: Bool { !js.isEmpty }
}

/* ---------------- 模型 ---------------- */

enum AIRole { case user, assistant }

struct AIMessage: Identifiable {
    let id: UUID
    var role: AIRole
    var text: String
    var at: Date

    init(id: UUID = UUID(), role: AIRole, text: String, at: Date = Date()) {
        self.id = id
        self.role = role
        self.text = text
        self.at = at
    }
}

private struct AIProbe: Decodable {
    let u: String
    let c: Int
    let t: [String]
    let st: Bool
    let ta: String
    let tal: Int
    let ai: Bool
    let fi: Bool
    let tt: String
    let err: String
}

/* ---------------- 引擎 ---------------- */

private let AI_AUTH_FLAG   = "mb.ai.authed"        // 上次已登录 → 下次直接进对话
private let AI_AUTOCLIP    = "mb.ai.autoclip"      // 复制到剪贴板就自动带图
private let AI_PIN_NAME    = "mb.ai.pin.name"      // 固定附件（每次进来必带）
private let AI_PIN_PATH    = "mb.ai.pin.path"

/// 独立版 DeepSeek 聊天 App 钉过的那张图 —— 看板这边第一次进来时继承过来，
/// 免得用户要再钉一次。（没有就什么都不做。）
private let AI_LEGACY_PIN_PATH = ("~/Library/Application Support/DeepSeekNativeChat/pinned.png" as NSString)
    .expandingTildeInPath

final class AIEngine: ObservableObject {
    static let shared = AIEngine()

    /* --- 界面状态 --- */
    @Published var messages: [AIMessage] = []
    @Published var isAuthed = false
    /// 网页引擎已就绪（能收发）。没就绪时输入框禁用。
    @Published var ready = false
    @Published var isSending = false
    @Published var status = "正在连接…"
    @Published var bootHint = "正在恢复上次登录…"
    /// 把真实的 DeepSeek 页面摊到窗口上（登录 / 用户主动要看原站）
    @Published var showSite = false
    @Published var revision = 0
    @Published var pendingFiles: [String] = []
    @Published var autoClipboard: Bool
    @Published var pinnedName: String?
    /// 上次校验登录态的时刻（账号管理页显示用）
    @Published var lastCheck = Date.distantPast
    @Published var online = true

    var webView: WKWebView?

    /* --- 私有 --- */
    private var timer: Timer?
    private var tick = 0
    private var activeId: UUID?
    private var sentText = ""
    private var sentLen = 0
    private var sendConfirmed = false
    private var escalated = false
    private var sendStart = Date()
    private var replyChangedAt = Date()
    private var activeUntil = Date.distantPast
    private var stickyUntil = Date.distantPast

    private var pendingItems: [[String: String]] = []
    private var lastClipChange = -1
    private var clipRejected = Set<Int>()
    private var autoAttachedName: String?

    private var verified = false
    private var verifyStart = Date()
    private var noTokenStreak = 0
    /// 连续读空 token 的次数。只有攒够 logoutStrikes 次才认「掉登录了」，
    /// 免得把 SPA 的瞬时抖动当成用户掉了线（见 refreshAuthSoon 的注释）。
    private var missStreak = 0
    private var pageAlive = false
    private var pageRetries = 0
    private var nextRetryAt = Date().addingTimeInterval(20)
    private var activateObserver: NSObjectProtocol?

    private init() {
        if UserDefaults.standard.object(forKey: AI_AUTOCLIP) != nil {
            autoClipboard = UserDefaults.standard.bool(forKey: AI_AUTOCLIP)
        } else {
            autoClipboard = true
        }
        pinnedName = UserDefaults.standard.string(forKey: AI_PIN_NAME)

        // 继承独立版钉过的那张图（只认文件真的在的那种）
        if pinnedName == nil,
           FileManager.default.fileExists(atPath: AI_LEGACY_PIN_PATH) {
            UserDefaults.standard.set("Clipboard_Screenshot.png", forKey: AI_PIN_NAME)
            UserDefaults.standard.set(AI_LEGACY_PIN_PATH, forKey: AI_PIN_PATH)
            pinnedName = "Clipboard_Screenshot.png"
        }

        // 第一帧就按「上次已登录」渲染对话界面，登录态在背后静默恢复
        if UserDefaults.standard.bool(forKey: AI_AUTH_FLAG) {
            isAuthed = true
            status = "正在恢复会话…"
        }
        // 离屏自检：登录态来自网页里的 token，离屏拿不到，所以显式放开，
        // 否则只能看到「未登录」那一屏 —— 已登录的对话界面就永远量不到。
        if PreviewFlags.aiAuthed {
            isAuthed = true
            ready = true
            status = "离屏自检：假装已就绪"
            bootHint = ""
        }
    }

    /* ---------------- 生命周期 ---------------- */

    func attach(_ wv: WKWebView) {
        guard webView == nil else { return }
        webView = wv
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.6, repeats: true) { [weak self] _ in
            self?.onTick()
        }
        if activateObserver == nil {
            activateObserver = NotificationCenter.default.addObserver(
                forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
            ) { [weak self] _ in
                self?.pollClipboard()
                self?.refreshAuthSoon()
            }
        }
    }

    /// 用户从别处切回来时，顺手再确认一次登录态。
    ///
    /// ★★ 这里以前有个「自己把自己踢下线」的坑，别再改回去 ★★
    ///   旧写法：切回 App 只等 0.7 秒就去读 token，读到空**当场判定掉登录**。
    ///   可 DeepSeek 是个 SPA，刚切回来时页面常常还没 hydrate 完，
    ///   localStorage 里那一瞬读不到东西 —— 一次瞬时抖动就把人踢到登录页。
    ///   用户看到的现象就是「它老是不知道为什么自己就退出登录了」，
    ///   而其实登录态一直好好地存在本机。
    ///
    /// 现在：等久一点、多探一轮，而且**必须连续 3 次**读不到才算真掉线。
    private func refreshAuthSoon() {
        guard webView != nil, !isSending else { return }
        probeSoon([2.0, 6.0])
    }

    /// 在若干时间点各探一次。只要有一次读到了就提前收工。
    private func probeSoon(_ delays: [Double]) {
        for d in delays {
            DispatchQueue.main.asyncAfter(deadline: .now() + d) { [weak self] in
                guard let self, let wv = self.webView, !self.isSending else { return }
                guard self.missStreak > 0 else { return }     // 已经确认在线了，不必再补
                self.probeToken(wv)
            }
        }
    }

    /// 页面（重新）加载完成：把「读空」的计数清零。
    /// 不清的话，上一次页面切换过程中攒下的 strike 会跨页面沿用，
    /// 新页面刚起来就被判掉线 —— 又是一个冤枉人的路径。
    func notePageLoaded() {
        pageAlive = true
        missStreak = 0
    }

    private func onTick() {
        tick += 1
        pollClipboard()
        guard let wv = webView else { return }

        if !verified {
            if tick % 2 == 1 { probeToken(wv) }
            let elapsed = Date().timeIntervalSince(verifyStart)
            if !pageAlive && Date() >= nextRetryAt {
                pageRetries += 1
                nextRetryAt = Date().addingTimeInterval(pageRetries < 3 ? 20 : 60)
                Log.write("灵析AI：页面未就绪 → 第 \(pageRetries) 次重载")
                wv.reload()
            }
            bootHint = pageAlive
                ? "正在恢复上次登录…"
                : "网页引擎还在加载（已重试 \(pageRetries) 次，\(Int(elapsed)) 秒）"
            return
        }
        bootHint = ""

        // 每约 2 分钟轻碰一次登录态。
        // 一是真过期了能早点发现（要连续 3 次才算数，所以不会误伤）；
        // 二是让 DeepSeek 网页自己的续期逻辑有机会跑 —— 一直没人访问的
        // webview 是不会自己续期的，这才是「放几天回来就要重登」的根因。
        if isAuthed && tick % 200 == 0 { probeToken(wv) }

        wv.evaluateJavaScript("window.__dsProbe ? window.__dsProbe() : ''") { [weak self] res, _ in
            guard let self else { return }
            guard let s = res as? String, let d = s.data(using: .utf8),
                  let p = try? JSONDecoder().decode(AIProbe.self, from: d) else { return }
            DispatchQueue.main.async {
                self.online = true
                self.handleProbe(p)
                if self.activeId != nil { self.readReply() }
            }
        }
    }

    // MARK: 登录态

    /// 连续读空多少次才判定「真的掉登录了」。
    /// 为什么是 3 而不是 1：见 refreshAuthSoon 上面那段注释 —— 一次瞬时空读
    /// 在 SPA 里太常见了，拿它当结论就是冤枉用户。
    private let logoutStrikes = 3

    private func probeToken(_ wv: WKWebView) {
        wv.evaluateJavaScript("(typeof window.__dsToken === 'function') ? ('OK:' + window.__dsToken()) : 'NOJS'") { [weak self] res, _ in
            guard let self else { return }
            let s = (res as? String) ?? "NOJS"
            DispatchQueue.main.async {
                if s == "NOJS" { return }              // 页面还在加载 / 没网，继续等，不算 strike
                guard s.hasPrefix("OK:") else { return }
                self.pageAlive = true
                let tok = String(s.dropFirst(3))
                if tok.count > 10 {
                    self.markAuthed()
                } else {
                    self.missStreak += 1
                    if self.isAuthed && self.missStreak >= self.logoutStrikes {
                        self.markLoggedOut("登录已失效，点「去登录」重新登一次")
                    }
                }
            }
        }
    }

    private func markAuthed() {
        let first = !isAuthed
        verified = true
        ready = true
        missStreak = 0
        noTokenStreak = 0
        pageRetries = 0
        isAuthed = true
        showSite = false
        UserDefaults.standard.set(true, forKey: AI_AUTH_FLAG)
        lastCheck = Date()
        online = true
        if first {
            status = "已连接 DeepSeek"
            // 进来自动把「固定附件 / 剪贴板里的图」带上
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
                self?.attachPinnedIfNeeded()
                self?.pollClipboard()
            }
        }
    }

    private func markLoggedOut(_ msg: String) {
        verified = false
        ready = false
        missStreak = 0
        noTokenStreak = 0
        verifyStart = Date()
        UserDefaults.standard.set(false, forKey: AI_AUTH_FLAG)
        isAuthed = false
        lastCheck = Date()
        status = msg
    }

    /// 用户在窗口上完成了登录（或点了「我已登录」）—— 主动验一次
    func checkNow() {
        guard let wv = webView else { status = "网页引擎还没起来"; return }
        status = "正在检查登录…"
        wv.evaluateJavaScript("(typeof window.__dsToken === 'function') ? ('OK:' + window.__dsToken()) : 'NOJS'") { [weak self] r, _ in
            guard let self else { return }
            let s = (r as? String) ?? "NOJS"
            DispatchQueue.main.async {
                if s == "NOJS" {
                    self.status = "页面还没加载好，等两秒再点一次"
                    return
                }
                let tok = String(s.dropFirst(3))
                if tok.count > 10 {
                    self.markAuthed()
                    self.status = "已连接 DeepSeek"
                } else {
                    self.isAuthed = false
                    self.verified = false
                    self.ready = false
                    self.lastCheck = Date()
                    self.status = "还没检测到登录 —— 请在页面上完成登录后点「我已登录好了」"
                }
            }
        }
    }

    /// 「重连」：把网页引擎整个重新加载一遍，再验一次登录态。
    ///
    /// 为什么这一步必须是安全的：登录态（cookie / localStorage）存在本机，
    /// **重载不会掉登录**。所以出问题时的第一反应就该是点它，
    /// 而不是让用户去猜「是不是我账号坏了 / 是不是要重装」。
    func reconnect() {
        guard let wv = webView else {
            status = "网页引擎还没起来，等两秒再点一次"
            return
        }
        verified = false
        noTokenStreak = 0
        pageRetries = 0
        pageAlive = false
        verifyStart = Date()
        nextRetryAt = Date()
        if !isAuthed { showSite = true }        // 没登录就把登录页摊出来，省一步
        status = "正在重新连接…"
        bootHint = "正在重新加载网页引擎…"
        wv.reload()
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.6) { [weak self] in
            self?.checkNow()
        }
    }

    /// 退出登录（清 cookie + localStorage）
    func signOut() {
        guard let wv = webView else { return }
        let js = """
        (function(){
          try{ localStorage.clear(); }catch(e){}
          try{ sessionStorage.clear(); }catch(e){}
          try{
            document.cookie.split(';').forEach(function(c){
              var k = c.split('=')[0].trim();
              document.cookie = k + '=;expires=Thu, 01 Jan 1970 00:00:00 GMT;path=/;domain=.deepseek.com';
            });
          }catch(e){}
          return 'OK';
        })();
        """
        wv.evaluateJavaScript(js) { _, _ in
            DispatchQueue.main.async {
                self.markLoggedOut("已退出登录")
                self.messages = []
                self.showSite = true
                wv.load(URLRequest(url: URL(string: "https://chat.deepseek.com")!))
            }
        }
    }

    /* ---------------- 发送 / 接收 ---------------- */

    func send(_ raw: String) {
        let t = raw.trimmed
        guard !t.isEmpty, ready, !isSending else { return }
        messages.append(AIMessage(role: .user, text: t))
        let aid = UUID()
        messages.append(AIMessage(id: aid, role: .assistant, text: ""))
        activeId = aid
        revision += 1

        isSending = true
        sendConfirmed = false
        escalated = false
        sentText = t
        sentLen = t.utf16.count
        // ★★ 这一组是「先闪出上一个问题的答案」那个 bug 的解药，别再删 ★★
        //   旧写法里 asstSnap 一直是**上一轮**发送前拍的那份快照。本轮 __dsSend
        //   还没回来的这几百毫秒里，onTick 已经在跑 readReply 了 —— 拿上一轮的
        //   快照去页面里比对，上一轮的助手消息当然「不在快照里」，于是被当成本轮
        //   的回复写进刚建出来的空气泡里。用户看到的就是：先闪出上一题的完整答案，
        //   等真正的新答案开始流式输出时又「闪消」换成新的。
        //   现在：本轮开跑先把快照清空并上锁，只有 __dsSend 真的返回了新快照才开锁。
        asstSnap = "[]"
        snapReady = false
        prevReply = messages.last(where: { $0.role == .assistant && !$0.text.isEmpty })?.text ?? ""
        let files = pendingItems
        pendingFiles = []
        pendingItems = []
        autoAttachedName = nil
        sendStart = Date()
        replyChangedAt = Date()
        activeUntil = Date().addingTimeInterval(180)
        status = files.isEmpty ? "发送中…" : "正在把 \(files.count) 个文件发给 DeepSeek…"

        guard let wv = webView else { status = "网页未就绪"; finishTurn(); return }
        if files.isEmpty { dispatchSend(wv, t); return }
        uploadForSend(wv, files) { [weak self] ok in
            guard let self else { return }
            guard ok else { self.status = "附件发送失败，请重试"; self.finishTurn(); return }
            self.after(2.6) { self.dispatchSend(wv, t) }
        }
    }

    private func dispatchSend(_ wv: WKWebView, _ t: String) {
        status = "发送中…"
        // 参数传值而不是把文本拼进脚本：长文本稳，且没有转义风险
        wv.callAsyncJavaScript("return window.__dsSend(text);",
                               arguments: ["text": t], in: nil, in: .page) { [weak self] result in
            guard let self else { return }
            DispatchQueue.main.async {
                guard case .success(let v) = result, let s = v as? String,
                      let d = s.data(using: .utf8),
                      let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else {
                    self.status = "发送异常：拿不到页面返回"
                    self.finishTurn()
                    return
                }
                self.asstSnap = (o["snap"] as? String) ?? "[]"
                self.snapReady = true      // 拿到本轮快照了，readReply 才允许开工
                let ok = (o["ok"] as? String) ?? "?"
                if ok != "ENTER" { self.status = "发送失败：\(ok)"; self.finishTurn() }
            }
        }
    }

    /// 本轮「发送前」页面上的助手消息指纹。必须由本轮的 __dsSend 亲自返回才算数
    /// —— 见 send() 里那段注释。`snapReady` 就是它的门闩。
    private var asstSnap = "[]"
    private var snapReady = false
    /// 上一轮的答案原文。__dsRead 会把它整条跳过：虚拟列表里它一定还在页面上，
    /// 只要漏掉一次判重就会被当成本轮回复。
    private var prevReply = ""

    private func readReply() {
        guard snapReady, let wv = webView, !sentText.isEmpty else { return }
        wv.callAsyncJavaScript("return window.__dsRead(text, snap, prev);",
                               arguments: ["text": sentText, "snap": asstSnap, "prev": prevReply],
                               in: nil, in: .page) { [weak self] result in
            guard let self, case .success(let v) = result, let s = v as? String,
                  let d = s.data(using: .utf8),
                  let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return }
            let reply = (o["reply"] as? String) ?? ""
            DispatchQueue.main.async { self.applyReply(reply) }
        }
    }

    private func applyReply(_ reply: String) {
        guard let aid = activeId, let i = messages.firstIndex(where: { $0.id == aid }) else { return }
        guard !reply.isEmpty else { return }
        // 第二道闸：即便页面那边漏网了，只要内容跟上一轮的答案一字不差，也绝不显示。
        // 宁可这一帧空着（下面还有「正在生成…」的提示），也不要先给人看一遍旧答案。
        if reply == prevReply { return }
        if !sendConfirmed { sendConfirmed = true; escalated = true }

        var changed = false
        if messages[i].text != reply {
            messages[i].text = reply
            changed = true
            revision += 1
            replyChangedAt = Date()
            if !isSending {
                isSending = true
                activeUntil = Date().addingTimeInterval(120)
            }
        }
        if isSending {
            if Date().timeIntervalSince(replyChangedAt) > 1.6 || Date().timeIntervalSince(sendStart) > 180 {
                status = "已回复"
                finishTurn()
            } else {
                status = "正在生成…"
            }
        }
        _ = changed
    }

    private func handleProbe(_ p: AIProbe) {
        if !isSending {
            if activeId != nil && Date() > activeUntil { closeTurn() }
            if p.ai == false && Date() > stickyUntil {
                status = "未找到输入框（页面可能还在加载）"
            } else if p.ai && Date() > stickyUntil && activeId == nil && isAuthed && status != "已连接 DeepSeek" {
                status = "已连接 DeepSeek"
            }
            return
        }
        if !sendConfirmed {
            let stillThere = (p.tal == sentLen) && (p.ta == String(sentText.prefix(120)))
            let cleared = (p.ta != "__NONE__") && !stillThere
            if cleared {
                sendConfirmed = true
                status = "已发送，等待回复…"
            } else if !escalated && Date().timeIntervalSince(sendStart) > 1.5 {
                escalated = true
                status = "改用发送按钮重试…"
                webView?.evaluateJavaScript("window.__dsClickSend ? window.__dsClickSend() : 'NO_HOOK'") { [weak self] r, _ in
                    DispatchQueue.main.async {
                        let v = (r as? String) ?? "?"
                        self?.status = v.hasPrefix("CLICKED") ? "已点发送按钮，等待回复…" : "没找到发送按钮：\(v)"
                    }
                }
            } else if escalated && Date().timeIntervalSince(sendStart) > 6.0 {
                status = "发送失败：消息没进到 DeepSeek"
                finishTurn()
            }
        }
        if sendConfirmed && Date().timeIntervalSince(sendStart) > 90 {
            status = "等了 90 秒没有回复"
            finishTurn()
        }
    }

    private func finishTurn() {
        isSending = false
        activeUntil = Date().addingTimeInterval(45)
        if status != "已回复" && !status.hasPrefix("发送失败") && !status.hasPrefix("等了") {
            status = "已连接 DeepSeek"
        }
    }

    private func closeTurn() {
        activeId = nil
        sentText = ""
        sentLen = 0
        sendConfirmed = false
        escalated = false
    }

    private func after(_ t: Double, _ f: @escaping () -> Void) {
        DispatchQueue.main.asyncAfter(deadline: .now() + t) { f() }
    }

    /* ---------------- 附件 ---------------- */

    func pickFiles() {
        guard ready else { status = "还在连接，稍等一下"; return }
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.prompt = "添加"
        panel.message = "选择要发给灵析 AI 的文件或图片"
        guard panel.runModal() == .OK else { return }
        var items: [[String: String]] = []
        for u in panel.urls {
            guard let d = try? Data(contentsOf: u),
                  let it = makeItem(name: u.lastPathComponent, mime: mimeType(for: u), data: d) else { continue }
            items.append(it)
        }
        addAttachments(items)
    }

    func addAttachments(_ items: [[String: String]]) {
        guard !items.isEmpty else { return }
        pendingItems.append(contentsOf: items)
        pendingFiles = pendingItems.compactMap { $0["name"] }
        status = "已附加 \(pendingFiles.count) 个文件（随下一条消息一起发送）"
        stickyUntil = Date().addingTimeInterval(8)
    }

    func removeAttachment(_ name: String) {
        guard let i = pendingItems.firstIndex(where: { $0["name"] == name }) else { return }
        let wasAuto = (name == autoAttachedName)
        pendingItems.remove(at: i)
        if wasAuto { clipRejected.insert(clipKey); autoAttachedName = nil }
        if name == pinnedName { pinnedName = nil; UserDefaults.standard.removeObject(forKey: AI_PIN_NAME) }
        pendingFiles = pendingItems.compactMap { $0["name"] }
        status = pendingFiles.isEmpty ? "已移除附件，它不会被发出去" : "已移除「\(name)」"
        stickyUntil = Date().addingTimeInterval(6)
    }

    func toggleAutoClipboard() {
        autoClipboard.toggle()
        UserDefaults.standard.set(autoClipboard, forKey: AI_AUTOCLIP)
        status = autoClipboard ? "已开启：一复制图片就自动带上" : "已关闭自动带图"
        stickyUntil = Date().addingTimeInterval(6)
    }

    /* --- 固定附件 --- */

    func togglePin() {
        if pinnedName != nil { unpin(); return }
        if let first = pendingItems.first, let b64 = first["b64"], let d = Data(base64Encoded: b64) {
            pin(name: first["name"] ?? "default.png", data: d)
            return
        }
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.prompt = "钉住"
        panel.message = "选一个文件：以后每次打开这一页都自动带上它"
        guard panel.runModal() == .OK, let u = panel.url, let d = try? Data(contentsOf: u) else { return }
        pin(name: u.lastPathComponent, data: d)
    }

    private func pin(name: String, data: Data) {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ManageBacBoard", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let ext = (name as NSString).pathExtension
        let dst = base.appendingPathComponent("ai-pinned." + (ext.isEmpty ? "bin" : ext))
        do { try data.write(to: dst) } catch {
            status = "钉住失败：\(error.localizedDescription)"; return
        }
        UserDefaults.standard.set(name, forKey: AI_PIN_NAME)
        UserDefaults.standard.set(dst.path, forKey: AI_PIN_PATH)
        pinnedName = name
        status = "已钉住「\(name)」：以后每次进来都自动带上（再点一次取消）"
        stickyUntil = Date().addingTimeInterval(9)
    }

    private func unpin() {
        let p = UserDefaults.standard.string(forKey: AI_PIN_PATH)
        UserDefaults.standard.removeObject(forKey: AI_PIN_NAME)
        UserDefaults.standard.removeObject(forKey: AI_PIN_PATH)
        // 只删本 App 自己拷进来的那份；继承自独立版的原文件不动
        if let p, p.hasPrefix(FileManager.default.urls(for: .applicationSupportDirectory,
                                                       in: .userDomainMask)[0].path) {
            try? FileManager.default.removeItem(atPath: p)
        }
        let old = pinnedName
        pinnedName = nil
        if let o = old, let i = pendingItems.firstIndex(where: { $0["name"] == o }) {
            pendingItems.remove(at: i)
        }
        pendingFiles = pendingItems.compactMap { $0["name"] }
        status = "已取消固定附件"
        stickyUntil = Date().addingTimeInterval(6)
    }

    func attachPinnedIfNeeded() {
        guard isAuthed, ready, !isSending else { return }
        guard let name = pinnedName,
              let path = UserDefaults.standard.string(forKey: AI_PIN_PATH),
              FileManager.default.fileExists(atPath: path),
              let d = try? Data(contentsOf: URL(fileURLWithPath: path)) else { return }
        guard !pendingItems.contains(where: { $0["name"] == name }) else { return }
        guard let it = makeItem(name: name, mime: mimeType(for: URL(fileURLWithPath: path)), data: d) else { return }
        pendingItems.append(it)
        pendingFiles = pendingItems.compactMap { $0["name"] }
        status = "已带上固定附件「\(name)」"
        stickyUntil = Date().addingTimeInterval(8)
    }

    /* --- 剪贴板：只认 changeCount，换图就顶掉上一张 --- */

    private var clipKey: Int { NSPasteboard.general.changeCount }

    private func pollClipboard() {
        guard autoClipboard, isAuthed, ready, !isSending, pinnedName == nil else { return }
        let cc = clipKey
        guard cc != lastClipChange else { return }
        lastClipChange = cc
        guard !clipRejected.contains(cc) else { return }
        guard let (data, name) = clipboardImage() else { return }
        if let old = autoAttachedName, let i = pendingItems.firstIndex(where: { $0["name"] == old }) {
            pendingItems.remove(at: i)
        }
        guard let it = makeItem(name: name, mime: mimeType(for: URL(fileURLWithPath: name)), data: data) else { return }
        pendingItems.append(it)
        autoAttachedName = name
        pendingFiles = pendingItems.compactMap { $0["name"] }
        status = "已带上剪贴板里最新的图"
        stickyUntil = Date().addingTimeInterval(8)
    }

    private func clipboardImage() -> (Data, String)? {
        let pb = NSPasteboard.general
        if let d = pb.data(forType: .png) { return (d, clipName()) }
        if let t = pb.data(forType: .tiff), let img = NSImage(data: t), let png = pngData(img) {
            return (png, clipName())
        }
        if let urls = pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL],
           let u = urls.first {
            let ext = u.pathExtension.lowercased()
            if ["png", "jpg", "jpeg", "heic", "gif", "webp", "tiff", "bmp"].contains(ext),
               let d = try? Data(contentsOf: u) { return (d, u.lastPathComponent) }
        }
        return nil
    }

    private func clipName() -> String {
        let f = DateFormatter()
        f.dateFormat = "HH.mm.ss"
        return "剪贴板截图-\(f.string(from: Date())).png"
    }

    private func pngData(_ img: NSImage) -> Data? {
        guard let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) else { return nil }
        return rep.representation(using: .png, properties: [:])
    }

    private func makeItem(name: String, mime: String, data: Data) -> [String: String]? {
        if data.count > 8_000_000 {
            status = "「\(name)」太大（\(data.count / 1_000_000)MB），单个上限 8MB"
            stickyUntil = Date().addingTimeInterval(8)
            return nil
        }
        let used = pendingItems.reduce(0) { $0 + (($1["b64"]?.count ?? 0) * 3 / 4) }
        if used + data.count > 12_000_000 {
            status = "文件合计太大（上限 12MB）"
            stickyUntil = Date().addingTimeInterval(8)
            return nil
        }
        return ["name": name, "mime": mime, "b64": data.base64EncodedString()]
    }

    private func mimeType(for url: URL) -> String {
        if let t = UTType(filenameExtension: url.pathExtension), let m = t.preferredMIMEType { return m }
        return "application/octet-stream"
    }

    private func uploadForSend(_ wv: WKWebView, _ files: [[String: String]], done: @escaping (Bool) -> Void) {
        guard let jd = try? JSONSerialization.data(withJSONObject: files),
              let jsonStr = String(data: jd, encoding: .utf8) else { done(false); return }
        wv.callAsyncJavaScript("return window.__dsClearFiles ? window.__dsClearFiles() : 'NO_HOOK';",
                               arguments: [:], in: nil, in: .page) { _ in
            wv.callAsyncJavaScript("return window.__dsUploadMulti(items);",
                                   arguments: ["items": jsonStr], in: nil, in: .page) { r in
                DispatchQueue.main.async {
                    if case .success(let v) = r, let s = v as? String, s == "OK" { done(true) }
                    else { done(false) }
                }
            }
        }
    }

    func clearConversation() {
        guard !isSending else { return }
        messages = []
        status = "已清空这一页（DeepSeek 网站上的历史不受影响）"
        stickyUntil = Date().addingTimeInterval(6)
    }

    /// 把一段文本挂成待发附件（「把学习数据一起发」用）。
    ///
    /// 为什么走「附件」而不是把数据拼进提问正文：正文会被 DeepSeek 当聊天记录
    /// 反复携带，几轮下来上下文就爆了；附件只在这一轮上传一次。
    ///
    /// ⚠️ 这里**只挂附件，不替用户提问**。用户明确要求过：点了按钮之后，
    ///    由他自己写要问什么，再连同附件一起发出去。
    @discardableResult
    func attachText(name: String, text: String) -> Bool {
        guard !isSending else {
            status = "正在发送上一条，等一下再点"
            stickyUntil = Date().addingTimeInterval(6)
            return false
        }
        let data = Data(text.utf8)
        // 同名附件替换掉旧的，避免连点两次叠成两份
        if let i = pendingItems.firstIndex(where: { $0["name"] == name }) {
            pendingItems.remove(at: i)
        }
        guard let it = makeItem(name: name, mime: "text/markdown", data: data) else { return false }
        pendingItems.append(it)
        pendingFiles = pendingItems.compactMap { $0["name"] }
        stickyUntil = Date().addingTimeInterval(10)
        return true
    }

    /// 一键：带上一份学习数据 + 直接把问题发出去。
    /// 只给输入框下面那 2×2 里「看你的数据」那两个问题用 ——
    /// 那两句话本身就指明了要看哪份数据，不带附件模型根本答不上来。
    func sendWithPack(name: String, text: String, question: String) {
        guard ready, !isSending else {
            if !ready { status = "网页引擎还没就绪，稍等一下再点" }
            return
        }
        guard attachText(name: name, text: text) else { return }
        send(question)
    }
}

/* ======================================================================
   学习数据打包 —— 把本地已有的数据转成 Markdown 附件
   ----------------------------------------------------------------------
   这些数据本来就在本机（Mac 上的看板自己抓的），不用再问一遍网站。
   全部**只读**：只是把已有的东西序列化成文本，不会回写任何账号。
   ====================================================================== */

@MainActor
enum AIStudyPack {

    enum Kind: String, CaseIterable, Identifiable {
        case todo, grades, teams, seiue, all
        var id: String { rawValue }

        var label: String {
            switch self {
            case .todo:   return "作业待办"
            case .grades: return "成绩"
            case .teams:  return "Teams 待办"
            case .seiue:  return "希悦课表"
            case .all:    return "全部学习数据"
            }
        }
        var icon: String {
            switch self {
            case .todo:   return "checklist"
            case .grades: return "chart.bar.doc.horizontal"
            case .teams:  return "checkmark.bubble"
            case .seiue:  return "calendar"
            case .all:    return "shippingbox"
            }
        }
        /// 点一下之后自动发出去的提问 —— 不然「带上附件」还得用户自己想问什么
        var question: String {
            switch self {
            case .todo:
                return "这是我 ManageBac 上的作业清单（见附件）。按「最该先做」帮我排个顺序，说明理由；顺便标出时间上打架的地方。"
            case .grades:
                return "这是我各科的作业与出分记录（见附件）。帮我看看哪几科在往下走、哪几科稳住了，并给出下一步最值得花时间的地方。"
            case .teams:
                return "这是我 Teams 里的学习待办与邮件（见附件）。帮我挑出真正要紧的，哪些可以直接忽略，并整理成一份今天的行动清单。"
            case .seiue:
                return "这是我本周的课表（见附件）。帮我找出空档时间，安排一份可执行的复习计划，注意别把午休和晚自习排满。"
            case .all:
                return "这是我目前全部的学习数据（见附件：作业、成绩、Teams 待办、课表）。请整体看一遍，告诉我最该优先处理的三件事，以及为什么。"
            }
        }
    }

    /// 附件文件名：带日期，避免历史记录里几份「作业」分不清
    static func fileName(_ k: Kind) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return "学习数据-\(k.label)-\(f.string(from: Date())).md"
    }

    static func markdown(_ k: Kind) -> String {
        switch k {
        case .todo:   return todo()
        case .grades: return grades()
        case .teams:  return teams()
        case .seiue:  return seiue()
        case .all:
            return [header("全部学习数据"), todo(), grades(), teams(), seiue()]
                .joined(separator: "\n\n---\n\n")
        }
    }

    /* ---------------- 各段 ---------------- */

    private static func header(_ title: String) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm"
        return "# \(title)\n\n生成时间：\(f.string(from: Date()))\n"
    }

    private static func todo() -> String {
        let s = DataStore.shared
        var out = header("ManageBac 作业与截止时间")
        guard let p = s.payload else { return out + "\n（还没读到数据，先去「待办」页刷新一次）\n" }
        let tasks = p.tasks ?? []
        out += "\n共 \(tasks.count) 条未完成。\n"
        if let c = p.counts, let up = c.upcoming, let od = c.overdue {
            out += "其中逾期 \(od) 条、即将到期 \(up) 条。\n"
        }
        out += "\n| 学科 | 作业 | 截止 | 类型 | 状态 |\n|---|---|---|---|---|\n"
        for t in tasks.prefix(120) {
            let cells = [t.subject, t.title, t.dueText ?? t.due, t.type ?? t.kind, t.status]
                .map { mdCell($0) }
            out += "| " + cells.joined(separator: " | ") + " |\n"
        }
        if tasks.count > 120 { out += "\n（只列出前 120 条，其余略）\n" }
        return out
    }

    private static func grades() -> String {
        let s = DataStore.shared
        var out = header("ManageBac 成绩")
        let classes = s.payload?.classes ?? []
        let recent = s.payload?.recent ?? []
        if classes.isEmpty && recent.isEmpty {
            return out + "\n（还没读到成绩数据，先去「成绩」页刷新一次）\n"
        }
        if !classes.isEmpty {
            out += "\n## 各科总评\n\n| 学科 | 总评 | 最新作业 |\n|---|---|---|\n"
            for c in classes {
                let overall: String = {
                    if let m = c.overall?.mark, !m.isEmpty { return m }
                    if let p = c.overall?.pct { return fmt(p) + "%" }
                    return ""
                }()
                let latest = c.latest?.title ?? ""
                out += "| " + [mdCell(c.label ?? c.name), mdCell(overall), mdCell(latest)]
                    .joined(separator: " | ") + " |\n"
            }
        }
        if !recent.isEmpty {
            out += "\n## 最近出分\n\n| 学科 | 作业 | 得分 | 出分 |\n|---|---|---|---|\n"
            for r in recent.prefix(80) {
                let score: String = r.scoreText ?? {
                    () -> String? in
                    if let a = r.score, let b = r.outOf { return "\(fmt(a))/\(fmt(b))" }
                    return r.grade
                }() ?? ""
                out += "| " + [mdCell(r.label), mdCell(r.title), mdCell(score), mdCell(r.dueText)]
                    .joined(separator: " | ") + " |\n"
            }
        }
        return out
    }

    private static func teams() -> String {
        let s = DataStore.shared
        var out = header("Microsoft Teams 学习待办")
        if let d = s.teams?.section, d.connected == true {
            let tasks = d.tasks ?? []
            out += "\n共 \(tasks.count) 条。\n"
            if let st = d.stats, let u = st.unreadMail, u > 0 { out += "未读邮件 \(u) 封。\n" }
            if !tasks.isEmpty {
                out += "\n| 标题 | 来源 | 课程 | 截止 |\n|---|---|---|---|\n"
                for t in tasks.prefix(120) {
                    out += "| " + [mdCell(t.title), mdCell(t.source), mdCell(t.course),
                                   mdCell(t.dueText ?? t.place)].joined(separator: " | ") + " |\n"
                }
            }
            let mail = d.mail ?? []
            if !mail.isEmpty {
                out += "\n## 邮件\n\n| 主题 | 发件人 | 时间 | 未读 |\n|---|---|---|---|\n"
                for m in mail.prefix(40) {
                    let when = m.receivedMs.map { fmtDate(Date(timeIntervalSince1970: $0 / 1000)) } ?? ""
                    out += "| " + [mdCell(m.subject), mdCell(m.from), mdCell(when),
                                   (m.isRead == false ? "是" : "")].joined(separator: " | ") + " |\n"
                }
            }
        } else {
            out += "\n（Teams 还没连上，先去「Teams」页连接一次微软账号）\n"
        }
        out += ecBlock()
        return out
    }

    /// English Corner：这一段是为了让「我最近有没有漏掉 English Corner？下次是哪天？」
    /// 这种问题真的拿到名单、日期、时段和「我在不在名单里」，而不是让模型自己猜。
    private static func ecBlock() -> String {
        let s = DataStore.shared
        guard let ec = s.teamsEC else {
            return "\n## English Corner\n\n（还没读到 EC 名单，去「Teams」页同步一次）\n"
        }
        let st = ec.status ?? "none"
        let expired = (ec.deadlineMs ?? .greatestFiniteMagnitude)
            < Date().timeIntervalSince1970 * 1000
        let eff = (st == "today" && expired) ? "done" : st
        let imIn = ec.imIn == true
        let students = ec.students ?? []

        let headline: String = {
            switch eff {
            case "today":    return imIn ? "今天要去 English Corner" : "今天有 EC，名单里没有我"
            case "done":     return imIn ? "今天 EC 已结束（本来在名单里）" : "今天 EC 已结束"
            case "tomorrow": return imIn ? "明天要去 English Corner" : "明天有 EC，名单里没有我"
            case "future":   return "下一场 EC：" + (ec.date ?? "")
            case "past":     return "最近一份名单已过期"
            case "error":    return "EC 名单暂时读不到"
            default:         return "今天没有 EC"
            }
        }()

        var out = "\n## English Corner\n\n"
        out += "- 状态：\(headline)\n"
        out += "- 我在名单里：\(imIn ? "在" : "不在")\n"
        if let d = ec.date, !d.isEmpty { out += "- 日期：\(d)\n" }
        if let w = ec.window, !w.isEmpty { out += "- 时段：\(w)\n" }
        if let p = ec.place, !p.isEmpty { out += "- 地点：\(p)\n" }
        if let k = ec.klass, !k.isEmpty { out += "- 组别：\(k)\n" }
        if let c = ec.caption, !c.isEmpty { out += "- 说明：\(c)\n" }
        if let n = ec.note, !n.isEmpty { out += "- 备注：\(n)\n" }
        if !students.isEmpty {
            out += "- 本次名单（\(students.count) 人）：\(students.joined(separator: "、"))\n"
        }
        if let others = ec.otherGroups, !others.isEmpty {
            for (g, list) in others.sorted(by: { $0.key < $1.key }) where !list.isEmpty {
                out += "- \(g) 组名单：\(list.joined(separator: "、"))\n"
            }
        }
        return out
    }

    private static func seiue() -> String {
        let s = DataStore.shared
        var out = header("希悦课表（本周）")
        guard let sch = s.seiue?.schedule, sch.ok == true else {
            return out + "\n（还没同步到希悦课表，先去「课程」页同步一次）\n"
        }
        let days = sch.days ?? []
        let lessons = sch.lessons ?? []
        if days.isEmpty || lessons.isEmpty {
            return out + "\n（课表是空的：可能还没登录希悦，或者这周没有排课）\n"
        }
        out += "\n| 星期 | 节次 | 课程 | 备注 |\n|---|---|---|---|\n"
        for l in lessons {
            let note = (l.extra ?? []).joined(separator: " ")
            out += "| " + [mdCell(l.day), mdCell(l.period), mdCell(l.name), mdCell(note)]
                .joined(separator: " | ") + " |\n"
        }
        return out
    }

    /* ---------------- 小工具 ---------------- */

    /// Markdown 表格里的竖线必须转义，否则一条 "A | B" 会把表格撑坏
    private static func mdCell(_ v: String?) -> String {
        (v ?? "").replacingOccurrences(of: "|", with: "\\|")
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func fmt(_ d: Double) -> String {
        d == d.rounded() ? String(Int(d)) : String(format: "%.1f", d)
    }

    private static func fmtDate(_ d: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "MM-dd HH:mm"
        return f.string(from: d)
    }
}

/* ---------------- 网页引擎（全局挂一次，切分区不重建） ---------------- */

struct AIBackend: NSViewRepresentable {
    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> WKWebView {
        let uc = WKUserContentController()
        if AIInject.ok {
            uc.addUserScript(WKUserScript(source: AIInject.js,
                                          injectionTime: .atDocumentStart,
                                          forMainFrameOnly: false))
        }
        let config = WKWebViewConfiguration()
        config.userContentController = uc
        config.preferences.javaScriptCanOpenWindowsAutomatically = true
        config.websiteDataStore = WKWebsiteDataStore.default()   // cookie / localStorage 落盘

        let wv = WKWebView(frame: .zero, configuration: config)
        wv.navigationDelegate = context.coordinator
        wv.uiDelegate = context.coordinator
        wv.customUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15"
        wv.load(URLRequest(url: URL(string: "https://chat.deepseek.com")!))
        DispatchQueue.main.async { AIEngine.shared.attach(wv) }
        return wv
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {}

    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            // 新页面起来了：把「读空」的计数清零，否则上一次切换攒下的 strike
            // 会跨页面沿用，新页面刚加载就被判掉线。
            AIEngine.shared.notePageLoaded()
            // 兜底：钩子万一缺席就重新注入（脚本自带幂等守卫）
            webView.evaluateJavaScript("typeof window.__dsDiag") { r, _ in
                if ((r as? String) ?? "?") == "undefined", AIInject.ok {
                    Log.write("灵析AI：钩子缺席 → 重新注入")
                    webView.evaluateJavaScript(AIInject.js) { _, _ in }
                }
            }
        }
        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            Log.write("灵析AI：didFail \(error.localizedDescription)")
        }
        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            Log.write("灵析AI：didFailProvisional \(error.localizedDescription)")
        }
        func webView(_ webView: WKWebView,
                     createWebViewWith configuration: WKWebViewConfiguration,
                     for navigationAction: WKNavigationAction,
                     windowFeatures: WKWindowFeatures) -> WKWebView? {
            if navigationAction.targetFrame == nil { webView.load(navigationAction.request) }
            return nil
        }
    }
}

/* ======================================================================
   板块界面
   ====================================================================== */

struct AISection: View {
    @ObservedObject private var ai = AIEngine.shared
    @EnvironmentObject var settings: BoardSettings
    @Environment(\.colorScheme) private var scheme

    @State private var input = ""
    @FocusState private var focused: Bool

    /// 输入框下面那 2×2 的问题。每次进入灵析 AI 板块重新摇一次，
    /// 两个「看真实数据」+ 两个「学科知识」—— 固定不变的话，用户第二次就不看了。
    @State private var picks: [QuickQ] = []

    /// 已经为哪一条提问滚过位。用来保证「一条提问只滚一次」：
    /// 滚完就记下来，之后同一条提问的回答再怎么长都不再动页面。
    @State private var anchoredAsk: UUID?

    private var env: Env { Env(scheme: scheme, settings: settings) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            topBar
            dataBar
            messagesArea
            if !ai.pendingFiles.isEmpty { attachmentsBar }
            composer
            quickGrid
        }
        .padding(.horizontal, env.space(Space.xxl))
        .padding(.top, env.space(12))
        .padding(.bottom, env.space(14))
        // maxHeight 必须挂在**这一层**。写成 `.frame(maxWidth: 1180)` 再单独
        // `.frame(maxHeight: .infinity)` 的话：中间那层高度是内容决定的，
        // 外层再怎么撑满也只是把一个「矮盒子」居中摆着 —— 结果是中间那块
        // 对话区撑不开（只占内容高度），底下空一大截，问题按钮也浮在半空。
        .frame(maxWidth: 1180, maxHeight: .infinity)
        .frame(maxWidth: .infinity)
        .onAppear { rollQuickQuestions() }
    }

    /* ---------------- 顶条：状态 + 动作 ---------------- */

    private var topBar: some View {
        HStack(spacing: env.space(10)) {
            // 头像方块：和侧边栏顶部那个是同一套做法（渐变 + 投影 + emoji）
            ZStack {
                RoundedRectangle(cornerRadius: env.radius(10), style: .continuous)
                    .fill(LinearGradient(colors: [env.accent.color(scheme, lift: 0.22),
                                                  env.accent.color(scheme, lift: -0.05)],
                                         startPoint: .topLeading, endPoint: .bottomTrailing))
                    .frame(width: 32, height: 32)
                Text("✦").font(.system(size: 16, weight: .bold))
                    .foregroundStyle(.white)
            }
            .shadow(color: env.accent.color(scheme).opacity(0.30), radius: 7, y: 2)

            VStack(alignment: .leading, spacing: 1) {
                Text("灵析 AI").font(.system(size: 13.5, weight: .semibold))
                    .foregroundStyle(Theme.ink(scheme))
                HStack(spacing: 5) {
                    Circle()
                        .fill(ai.ready ? Theme.greenDefault.color(scheme, lift: 0.10)
                                       : (ai.isAuthed ? Theme.amberDefault.color(scheme, lift: 0.10)
                                                      : Theme.redDefault.color(scheme, lift: 0.16)))
                        .frame(width: 6, height: 6)
                    Text(ai.ready ? "DeepSeek · 已就绪"
                                  : (ai.isAuthed ? (ai.bootHint.isEmpty ? "连接中…" : ai.bootHint)
                                                 : "未登录"))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            // 状态入口常驻：没登录时这里是**最显眼**的那个按钮。
            // 以前不登录就直接把 DeepSeek 网页盖满整个窗口，用户既看不到状态，
            // 也没有「回到看板」以外的任何出路 —— 这一条是这次专门修的。
            if !ai.isAuthed {
                Button { ai.showSite = true } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "person.badge.key.fill")
                            .font(.system(size: 10.5, weight: .semibold))
                        Text("去登录 DeepSeek").font(.system(size: 11.5, weight: .semibold))
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 11).frame(height: 26)
                    .background {
                        RoundedRectangle(cornerRadius: env.radius(Radius.sm), style: .continuous)
                            .fill(env.accent.color(scheme, lift: 0.02))
                    }
                    .contentShape(RoundedRectangle(cornerRadius: env.radius(Radius.sm), style: .continuous))
                }
                .buttonStyle(.plain)
                .help("打开 DeepSeek 登录页；登录一次就会长期记住")
            } else {
                // 已登录时给一个「还剩多久验过一次」的安心提示，不占地方
                HStack(spacing: 4) {
                    Image(systemName: "checkmark.shield.fill")
                        .font(.system(size: 10, weight: .semibold))
                    Text("登录已记住").font(.system(size: 11, weight: .medium))
                }
                .foregroundStyle(Theme.greenDefault.color(scheme, lift: 0.06))
                .padding(.horizontal, 9).frame(height: 26)
                .card(env.radius(Radius.sm), look: env.look, shadow: false)
                .help("登录信息存在这台电脑上，关掉 App 也不会掉")
            }

            Spacer(minLength: env.space(10))

            toolButton(ai.autoClipboard ? "剪贴板带图 开" : "剪贴板带图 关",
                       icon: "doc.on.clipboard") { ai.toggleAutoClipboard() }
                .help("开启后：往剪贴板复制一张图，这里就自动带上它（永远跟最新那张同步）")

            toolButton(ai.pinnedName == nil ? "固定附件" : "已钉：" + String((ai.pinnedName ?? "").prefix(8)),
                       icon: "pin.fill", on: ai.pinnedName != nil) { ai.togglePin() }
                .help("钉住一个文件：以后每次进这一页都自动带上它（再点一次取消）")

            toolButton("清空", icon: "eraser") { ai.clearConversation() }
                .help("只清空这一页的显示；DeepSeek 网站上的历史记录不受影响")

            // 出问题时的第一反应按钮。登录态存在本机，重载不会掉登录。
            toolButton("重连", icon: "arrow.clockwise") { ai.reconnect() }
                .help("重新加载对话页面，然后再检查一次登录。"
                      + "登录是记在这台电脑上的，重载不会掉登录")

            toolButton("原站", icon: "safari") { ai.showSite = true }
                .help("打开 DeepSeek 网页（看历史记录用）")

            // 「退出登录」按用户要求撤掉了：它紧挨着「原站」，误点一下就要重新登录，
            // 而重新登录正是这个板块最容易出问题的一步。真要退出，
            // 去「设置 → 账号管理 → 灵析 AI」里操作。
        }
        .padding(.horizontal, env.space(13))
        .padding(.vertical, env.space(9))
        .card(env.radius(Radius.md), look: env.look)
        .padding(.bottom, env.space(9))
    }

    /* ---------------- 数据条：把学习数据打包发过去 ---------------- */

    private var dataBar: some View {
        HStack(spacing: env.space(7)) {
            HStack(spacing: 5) {
                Image(systemName: "square.and.arrow.up.on.square")
                    .font(.system(size: 10.5, weight: .semibold))
                Text("把学习数据挂到聊天框").font(.system(size: 11, weight: .semibold))
            }
            .foregroundStyle(Theme.ink2(scheme))
            .padding(.trailing, 2)

            ForEach(AIStudyPack.Kind.allCases) { k in
                Button { attachPack(k) } label: {
                    HStack(spacing: 4) {
                        Image(systemName: k.icon).font(.system(size: 10, weight: .semibold))
                        Text(k.label).font(.system(size: 11, weight: .medium)).lineLimit(1)
                    }
                    .foregroundStyle(ai.ready ? Theme.ink(scheme) : Theme.ink3(scheme))
                    .padding(.horizontal, 9).frame(height: 24)
                    .contentShape(RoundedRectangle(cornerRadius: env.radius(Radius.sm), style: .continuous))
                }
                .buttonStyle(.plain)
                .card(env.radius(Radius.sm),
                      tint: k == .all
                        ? env.accent.color(scheme, lift: 0.88, opacity: scheme == .dark ? 0.18 : 0.14)
                        : nil,
                      look: env.look, shadow: false)
                .help("把\(k.label)整理成一份附件挂到聊天框；接下来你想问什么，自己写就行")
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, env.space(13))
        .padding(.vertical, env.space(7))
        .card(env.radius(Radius.md), look: env.look, shadow: false)
        .padding(.bottom, env.space(9))
    }

    /// 点一下数据按钮 = 把那份数据**挂到聊天框**，不替用户提问。
    /// 用户的原话：挂上去之后由他自己写文本，再连同附件一起发。
    private func attachPack(_ k: AIStudyPack.Kind) {
        guard ai.ready else {
            ai.status = "网页引擎还没就绪，稍等一下再点"
            return
        }
        if ai.attachText(name: AIStudyPack.fileName(k), text: AIStudyPack.markdown(k)) {
            ai.status = "已把「\(k.label)」挂到聊天框 —— 写一句话，点发送就会连它一起发过去"
        }
    }

    private func toolButton(_ title: String, icon: String, on: Bool = false,
                            action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: icon).font(.system(size: 10, weight: .semibold))
                Text(title).font(.system(size: 11, weight: .medium)).lineLimit(1)
            }
            .foregroundStyle(on ? env.accent.color(scheme, lift: 0.06) : Theme.ink2(scheme))
            .padding(.horizontal, 10)
            .frame(height: 26)
            .contentShape(RoundedRectangle(cornerRadius: env.radius(Radius.sm), style: .continuous))
        }
        .buttonStyle(.plain)
        .card(env.radius(Radius.sm),
              tint: on ? env.accent.color(scheme, lift: 0.86, opacity: scheme == .dark ? 0.16 : 0.12) : nil,
              look: env.look, shadow: false)
    }

    /* ---------------- 消息区 ---------------- */

    private var messagesArea: some View {
        ZStack {
            if ai.messages.isEmpty { emptyHero } else { messageList }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .card(env.radius(Radius.lg), look: env.look)
        .padding(.bottom, env.space(11))
    }

    private var messageList: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical) {
                LazyVStack(alignment: .leading, spacing: env.space(14)) {
                    ForEach(ai.messages) { m in
                        AIBubble(msg: m, env: env, scheme: scheme,
                                 generating: ai.isSending && m.id == ai.messages.last?.id)
                            .id(m.id)
                    }
                }
                .padding(.horizontal, env.space(16))
                .padding(.vertical, env.space(16))
            }
            // 两参数写法（macOS 14 起旧版已弃用，见 DashRoot 里同款说明）
            //
            // ★ 这里**只滚一次**，而且滚的是「提问」不是「回答」★
            //   以前是每来一个流式分片就 scrollTo(最后一条, anchor: .bottom)——
            //   页面被一路拽着往下跑，用户想回头看上面刚问的那句话，屏幕一直在动，
            //   长回答根本没法读。
            //   现在：一条新提问出现时，把它顶到可视区**最上面**（anchor: .top）就停手；
            //   同一条提问的回答往下长多少都不再滚，要看下面用户自己滚鼠标。
            //   revision 在每次流式更新时都会变，所以必须用 anchoredAsk 记住
            //   「这条提问已经滚过了」，否则等于没改。
            .onChange(of: ai.revision) { _, _ in
                guard let ask = ai.messages.last(where: { $0.role == .user })?.id,
                      ask != anchoredAsk else { return }
                anchoredAsk = ask
                withAnimation(Motion.ease(Motion.Dur.quick)) {
                    proxy.scrollTo(ask, anchor: .top)
                }
            }
            .overlay(alignment: .bottom) {
                if ai.isSending {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.mini).scaleEffect(0.7)
                        Text("正在生成…").font(.system(size: 11)).foregroundStyle(.secondary)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, env.space(18))
                    .padding(.bottom, env.space(8))
                    .allowsHitTesting(false)
                }
            }
        }
    }

    /// 空态：不放一句冷冰冰的「暂无消息」，直接给可点的起手式。
    /// 首屏有东西可点，产品感就出来了。
    private var emptyHero: some View {
        VStack(spacing: env.space(14)) {
            ZStack {
                Circle()
                    .fill(env.accent.color(scheme).opacity(0.12))
                    .frame(width: 62, height: 62)
                Text("✦").font(.system(size: 26, weight: .bold))
                    .foregroundStyle(env.accent.color(scheme, lift: 0.10))
            }
            VStack(spacing: 5) {
                Text(ai.isAuthed ? "灵析 AI 就在这一页" : "登录一次，之后就在这一页问答")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Theme.ink(scheme))
                Text(ai.isAuthed
                     ? "下面四个问题点一个就能发；也可以把截图拖进剪贴板、或按 📎 选文件"
                     : "点上面的「原站」会弹出 DeepSeek 登录页，登完自动回到这里")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.ink2(scheme))
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }

            // ⚠️ 这里以前还有一排三个小胶囊（「今天有什么要交的？」…）。别再放回来：
            //    输入框下面已经有 2×2 的问题库（用户指定的形态），再叠一排同功能的小
            //    按钮、加上输入框左边那句「不知道问什么？点一个试试」，一屏之内就有
            //    三处在说同一句话 —— 用户反而不知道该点哪个。
            //    空态只负责说明「这是什么、去哪点」，能点的地方只留一处。
            if !ai.isAuthed {
                Button { ai.showSite = true } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "safari.fill").font(.system(size: 11.5, weight: .semibold))
                        Text("去登录 DeepSeek").font(.system(size: 13, weight: .semibold))
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 16).frame(height: 34)
                    .background {
                        RoundedRectangle(cornerRadius: env.radius(Radius.sm), style: .continuous)
                            .fill(env.accent.color(scheme, lift: 0.02))
                    }
                    .contentShape(RoundedRectangle(cornerRadius: env.radius(Radius.sm), style: .continuous))
                }
                .buttonStyle(.plain)
                .padding(.top, 2)
            }
        }
        .padding(env.space(28))
    }

    /* ---------------- 附件条 ---------------- */

    private var attachmentsBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: env.space(7)) {
                ForEach(ai.pendingFiles, id: \.self) { name in
                    HStack(spacing: 6) {
                        Image(systemName: "doc.fill").font(.system(size: 9.5))
                            .foregroundStyle(env.accent.color(scheme, lift: 0.06))
                        Text(name).font(.system(size: 11)).lineLimit(1)
                            .foregroundStyle(Theme.ink(scheme))
                        Button { ai.removeAttachment(name) } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 11))
                                .foregroundStyle(Theme.ink3(scheme))
                        }
                        .buttonStyle(.plain)
                        .help("不发送这个文件")
                    }
                    .padding(.horizontal, 10).padding(.vertical, 5)
                    .card(env.radius(Radius.sm), look: env.look, shadow: false)
                }
            }
            .padding(.horizontal, 2)
        }
        .padding(.bottom, env.space(8))
    }

    /* ---------------- 输入条 ---------------- */

    private var composer: some View {
        VStack(alignment: .leading, spacing: env.space(7)) {
            HStack(alignment: .bottom, spacing: env.space(9)) {
                Button { ai.pickFiles() } label: {
                    Image(systemName: "paperclip")
                        .font(.system(size: 13.5, weight: .semibold))
                        .foregroundStyle(Theme.ink2(scheme))
                        .frame(width: 38, height: 40)
                        .contentShape(RoundedRectangle(cornerRadius: env.radius(Radius.sm), style: .continuous))
                }
                .buttonStyle(.plain)
                .card(env.radius(Radius.sm), look: env.look, shadow: false)
                .help("添加文件 / 图片")

                if PreviewFlags.offscreen {
                    // 自检时用静态文本顶替输入框：TextField 底层是 NSTextField，
                    // ImageRenderer 画不出来，会留一块黄底占位。
                    Text(input.isEmpty ? "问点什么…（⏎ 发送，⇧⏎ 换行）" : input)
                        .font(.system(size: 13.5))
                        .foregroundStyle(input.isEmpty ? Color.secondary.opacity(0.70)
                                                       : Theme.ink(scheme))
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 11)
                        .fieldTint(env, focused: focused)
                } else {
                    TextField("问点什么…（⏎ 发送，⇧⏎ 换行）", text: $input, axis: .vertical)
                        .textFieldStyle(.plain)
                        .font(.system(size: 13.5))
                        .lineLimit(1...5)
                        .focused($focused)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 11)
                        .fieldTint(env, focused: focused)
                        .onSubmit { submit() }
                }

                Button { submit() } label: {
                    Image(systemName: "arrow.up")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(canSend ? .white : Theme.ink3(scheme))
                        .frame(width: 40, height: 40)
                        .background {
                            RoundedRectangle(cornerRadius: env.radius(Radius.sm), style: .continuous)
                                .fill(canSend ? env.accent.color(scheme, lift: 0.02)
                                              : Color.primary.opacity(0.08))
                        }
                        .contentShape(RoundedRectangle(cornerRadius: env.radius(Radius.sm), style: .continuous))
                }
                .buttonStyle(.plain)
                .disabled(!canSend)
                .help("发送（⏎）")
            }

            HStack(spacing: 6) {
                Image(systemName: ai.isSending ? "ellipsis.bubble" : "info.circle")
                    .font(.system(size: 10))
                Text(ai.status).font(.system(size: 11)).lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 0)
                if !ai.pendingFiles.isEmpty {
                    Text("\(ai.pendingFiles.count) 个附件待发")
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(env.accent.color(scheme, lift: 0.06))
                }
            }
            .foregroundStyle(.secondary)
            .padding(.horizontal, 3)
        }
    }

    private var canSend: Bool {
        ai.ready && !ai.isSending && !input.trimmed.isEmpty
    }

    private func submit() {
        let t = input
        guard !t.trimmed.isEmpty, canSend else { return }
        input = ""
        ai.send(t)
    }

    /* ---------------- 输入框下面的 2×2 问题 ---------------- */

    private var quickGrid: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "wand.and.stars").font(.system(size: 10))
                Text("不知道问什么？点一个试试").font(.system(size: 10.5))
                Spacer(minLength: 0)
                Button { rollQuickQuestions() } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.triangle.2.circlepath")
                            .font(.system(size: 9.5, weight: .semibold))
                        Text("换一批").font(.system(size: 10.5, weight: .medium))
                    }
                    .foregroundStyle(Theme.ink3(scheme))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("再摇四个不一样的问题")
            }
            .foregroundStyle(.tertiary)
            .padding(.horizontal, 3)
            .padding(.top, env.space(9))
            .padding(.bottom, env.space(6))

            // 2×2。为什么是网格而不是一排：这四个问题本身就分两类
            // （上面两个看你的真实数据，下面两个是学科知识），
            // 摆成两行正好让人一眼看出「上面问我的事，下面问学科」。
            VStack(spacing: env.space(7)) {
                ForEach(0..<2, id: \.self) { row in
                    // 一行里的两个按钮必须**等高**。做法是让「问题文字」那块占固定两行高，
                    // 而不是给按钮加 maxHeight：maxHeight 会把按钮拉满整条剩余高度，
                    // 两行之间被撑开一百多像素，看着像散了架。
                    HStack(alignment: .top, spacing: env.space(7)) {
                        ForEach(0..<2, id: \.self) { col in
                            questionCard(index: row * 2 + col)
                        }
                    }
                }
            }
            // 网格按自己的理想高度画，绝不参与外层的高度分配。
            // 少了这一句，窗口拉高时多余的高度有可能被摊到这里，
            // 第二行按钮就被拉长成一大块。
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func questionCard(index: Int) -> some View {
        let q = index < picks.count ? picks[index] : QuickQ(text: "", pack: nil)
        let text = q.text
        let isData = index < 2
        return Button {
            guard !text.isEmpty else { return }
            guard ai.ready else {
                ai.status = "网页引擎还没就绪，稍等一下再点"
                return
            }
            if let k = q.pack {
                // 「看你的数据」这一类问题必须**同时把数据喂过去** ——
                // 不然模型根本不知道我的 ELA 成绩是多少、English Corner 有没有漏。
                ai.sendWithPack(name: AIStudyPack.fileName(k),
                                text: AIStudyPack.markdown(k),
                                question: text)
            } else {
                ai.send(text)
            }
        } label: {
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 5) {
                    Image(systemName: isData ? "chart.line.uptrend.xyaxis" : "books.vertical.fill")
                        .font(.system(size: 9.5, weight: .semibold))
                    Text(isData ? "看你的数据" : "学科知识")
                        .font(.system(size: 9.5, weight: .semibold))
                    Spacer(minLength: 0)
                    // 这一类会连带一份附件发出去了，先在角上说清楚，免得用户以为
                    // 「它怎么知道我成绩的」或者「怎么突然多了个附件」
                    if q.pack != nil {
                        Image(systemName: "paperclip")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(Theme.ink3(scheme))
                    }
                }
                .foregroundStyle(isData ? env.accent.color(scheme, lift: 0.06)
                                        : Theme.ink3(scheme))

                Text(text.isEmpty ? "　" : text)
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(ai.ready ? Theme.ink(scheme) : Theme.ink3(scheme))
                    .multilineTextAlignment(.leading)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                    // 固定两行的高度：一个问题一行、另一个两行时，两个卡片依然一样高，
                    // 同一行的上边缘才是齐的。
                    .frame(maxWidth: .infinity, minHeight: 32, alignment: .topLeading)
            }
            .padding(.horizontal, 11)
            .padding(.vertical, 9)
            .frame(maxWidth: .infinity, minHeight: 58, alignment: .topLeading)
            .contentShape(RoundedRectangle(cornerRadius: env.radius(Radius.sm), style: .continuous))
        }
        .buttonStyle(.plain)
        .card(env.radius(Radius.sm), look: env.look, shadow: false)
        .help(q.pack == nil ? text : "\(text)（会连同一份\(q.pack!.label)一起发出）")
    }

    /// 摇四个：上排两个「看真实数据」，下排两个「学科知识」。
    private func rollQuickQuestions() {
        picks = Array(Self.dataQuestions.shuffled().prefix(2))
              + Self.subjectQuestions.shuffled().prefix(2).map { QuickQ(text: $0, pack: nil) }
    }

    /// 一个问题 + 它需要的那份数据。pack = nil 表示纯学科问题、不用带附件。
    private struct QuickQ {
        let text: String
        let pack: AIStudyPack.Kind?
    }

    /// 上排：都要求模型**真的去看**已经带进来的数据，答案才跟自己的处境有关。
    /// 既然问题本身就点名了要看哪份数据，点它的时候就必须把那份数据一起发过去 ——
    /// 否则模型只能凭空编。
    private static let dataQuestions: [QuickQ] = [
        QuickQ(text: "我最近有没有漏掉 English Corner？下次是哪天？", pack: .teams),
        QuickQ(text: "对照我的课表和作业，这周哪几天会特别赶？", pack: .all),
        QuickQ(text: "我该怎么提高我的 ELA 成绩？先看数据再给建议。", pack: .grades),
        QuickQ(text: "最近哪几科在掉？掉的原因可能是什么？", pack: .grades),
        QuickQ(text: "今天剩下这段时间，最值得先做哪一件事？", pack: .todo),
        QuickQ(text: "我这周的作业量分布均匀吗？哪里会堆在一起？", pack: .todo),
        QuickQ(text: "有没有哪份作业已经逾期但我还没注意到的？", pack: .todo),
        QuickQ(text: "把我的 Teams 待办按「今天不做会出事」排个序。", pack: .teams),
    ]

    /// 下排：纯学科问题。故意用 AP / 高中范围的表达，
    /// 并且要求「讲清楚为什么」，而不是只给结论。
    private static let subjectQuestions = [
        "帮我详细讲解电负性的化学含义",
        "如何绘制四次函数图像",
        "解释一下牛顿第三定律为什么不是「抵消」",
        "求导的链式法则到底在做什么？给个直觉解释",
        "为什么 ATP 被称为能量货币？",
        "用向量讲清楚点积的几何意义",
        "化学平衡移动的勒夏特列原理怎么用？",
        "什么是特征值与特征向量，直观地讲",
    ]
}

/* ---------------- 气泡 ---------------- */

private struct AIBubble: View {
    let msg: AIMessage
    let env: Env
    let scheme: ColorScheme
    var generating: Bool = false

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            if msg.role == .user { Spacer(minLength: 60) }

            VStack(alignment: msg.role == .user ? .trailing : .leading, spacing: 5) {
                Text(msg.text.isEmpty ? (generating ? "…" : "") : msg.text)
                    .font(.system(size: 13.5))
                    .foregroundStyle(msg.role == .user ? .white : Theme.ink(scheme))
                    .textSelection(.enabled)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, env.space(13))
                    .padding(.vertical, env.space(10))
                    .background {
                        if msg.role == .user {
                            RoundedRectangle(cornerRadius: env.radius(Radius.md), style: .continuous)
                                .fill(LinearGradient(colors: [env.accent.color(scheme, lift: 0.08),
                                                              env.accent.color(scheme, lift: -0.06)],
                                                     startPoint: .topLeading, endPoint: .bottomTrailing))
                        }
                    }
                    .card2(msg.role == .assistant, env: env)

                if generating && !msg.text.isEmpty {
                    Text("生成中…").font(.system(size: 10)).foregroundStyle(.tertiary)
                        .padding(.horizontal, 3)
                }
            }

            if msg.role == .assistant { Spacer(minLength: 60) }
        }
    }
}

private extension View {
    /// 助手气泡走玻璃卡；用户气泡已经是实色渐变，不再叠玻璃。
    @ViewBuilder
    func card2(_ on: Bool, env: Env) -> some View {
        if on {
            self.card(env.radius(Radius.md), look: env.look, shadow: false)
                .overlay {
                    RoundedRectangle(cornerRadius: env.radius(Radius.md) + 0.5, style: .continuous)
                        .strokeBorder(Theme.lineSoft(env.scheme), lineWidth: 1)
                        .allowsHitTesting(false)
                }
        } else {
            self
        }
    }

    /// 输入框的「浅色填充 + 浅色描边」外壳。
    ///
    /// 用户的要求：比周围大一点，但别大到夸张；底色和描边都要**很浅**，
    /// 目的是在满屏白卡里一眼认出「这里是能打字的地方」。
    /// 第一版用了 8.5% 填充 —— 在近白的卡面上几乎看不出来，等于没画；
    /// 这里提到 14%（浅色）/ 22%（深色），描边 42%、聚焦 72%。
    /// 注意**不能**用 `.card(...)`：那是和所有卡片同一套白底，
    /// 放在一排白卡中间等于没画。
    func fieldTint(_ env: Env, focused: Bool) -> some View {
        let scheme = env.scheme
        let base = env.accent.color(scheme)
        return self
            .background {
                RoundedRectangle(cornerRadius: env.radius(Radius.md), style: .continuous)
                    .fill(base.opacity(scheme == .dark ? 0.22 : 0.14))
            }
            .overlay {
                RoundedRectangle(cornerRadius: env.radius(Radius.md) + 0.5, style: .continuous)
                    .strokeBorder(base.opacity(focused ? 0.72 : 0.42), lineWidth: 1.4)
                    .allowsHitTesting(false)
            }
    }
}
