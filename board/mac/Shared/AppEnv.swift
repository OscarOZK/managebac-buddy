import Foundation

/* ======================================================================
   学校 ManageBac 地址
   ----------------------------------------------------------------------
   只在这一个地方出现默认值。目的是：同学拿到就能直接用（同校），
   换学校的人在「设置 → 账号管理」里改一处即可，不用碰代码。
   用带锁的静态变量而不是直接读 BoardSettings —— 因为 Notifier 等
   后台线程也要用它拼链接，跨 actor 读设置会引入并发问题。
   ====================================================================== */

enum SchoolURL {
    /// 默认值 = 本校地址。它不是任何人的账号信息，只是「这个看板是给哪所学校做的」。
    static let fallback = "https://beijing101.managebac.cn"

    private static let lock = NSLock()
    private static var _current = fallback

    static var current: String {
        get { lock.lock(); defer { lock.unlock() }; return _current }
        set {
            let v = norm(newValue)
            lock.lock(); _current = v.isEmpty ? fallback : v; lock.unlock()
        }
    }

    /// 补协议、去尾斜杠。用户手输 `xxx.managebac.cn` 也要能用。
    static func norm(_ v: String) -> String {
        var s = v.trimmingCharacters(in: .whitespacesAndNewlines)
        while s.hasSuffix("/") { s.removeLast() }
        if s.isEmpty { return "" }
        if !s.hasPrefix("http://") && !s.hasPrefix("https://") { s = "https://" + s }
        return s
    }
}

/* ======================================================================
   运行环境：数据目录 / 后端位置 / 老版本迁移
   ----------------------------------------------------------------------
   分发给别人的 App 不能假设「谁的电脑上都有个 ~/.mbboard」。
   以前是这个样子：

       · 后端代码在 ~/.mbboard/bridge.py（写死成 /Users/<某个人>/…）
       · 「我的登录态」也堆在同一个目录里（session.json、两份浏览器 profile…）

   于是同一堆文件既当「源码」又当「我的隐私」，既没法干净地分发，
   也容易顺手把个人数据一起打给别人。现在拆成两件事：

       HERE      后端代码   —— 开发机 = ~/.mbboard；分发版 = App 包内的 backend/
       MBB_DATA  用户数据   —— ~/Library/Application Support/ManageBac 看板/

   另外这里还负责把「换了 Bundle ID」这件事对用户透明：
   WKWebView 的 cookie（灵析 AI 的登录态）是按 Bundle ID 分目录存的，
   只改个标识就会把人踢下线 —— 那不是用户做错了什么，是我们改了目录名。
   ====================================================================== */

enum MBBPaths {

    /// 自检 / 测试时把数据目录指到别处（绝不碰真数据）
    static var overrideDataDir: String? = nil

    /// 分发版的数据目录名 —— 就用 App 名，用户在 Finder 里认得出来。
    /// 结尾的「Mac」不是装饰：`~/Library/Application Support/ManageBac 看板`
    /// 已经被 Windows 版（Electron，productName 同名）占用过，里面躺着一份
    /// 只有 `{"theme":"light"}` 的 settings.json。不分开的话，「不覆盖已有偏好」
    /// 这条迁移规则会一路跳过 —— 用户的主题、快捷键、提醒时间全都搬不过来。
    static let appFolderName = "ManageBac 看板 Mac"

    /// 老版本（以及本机开发布局）的数据目录
    static var legacyDir: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".mbboard", isDirectory: true)
    }

    /// ~/Library/Application Support/ManageBac 看板
    static var supportDir: URL {
        let base = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support", isDirectory: true)
        return base.appendingPathComponent(appFolderName, isDirectory: true)
    }

    /// App 包内自带的后端（分发版才会有）
    static var bundledBackendDir: URL? {
        guard let r = Bundle.main.resourceURL else { return nil }
        let d = r.appendingPathComponent("backend", isDirectory: true)
        let f = d.appendingPathComponent("bridge.py")
        return FileManager.default.fileExists(atPath: f.path) ? d : nil
    }

    /// App 包内自带的命令行工具（agent-browser，抓取要用）
    static var bundledToolsDir: URL? {
        guard let r = Bundle.main.resourceURL else { return nil }
        let d = r.appendingPathComponent("tools", isDirectory: true)
        return FileManager.default.fileExists(atPath: d.path) ? d : nil
    }

    /// 运行时工具的落点：<数据目录>/bin/agent-browser
    static var binDir: URL { home.appendingPathComponent("bin", isDirectory: true) }
    static var agentBrowser: URL { binDir.appendingPathComponent("agent-browser") }

    /// 这台机器该用哪个架构的 agent-browser。
    /// 包里 arm64 / x64 各带一份，取当前架构那个 —— 拿错了会直接被系统拒绝执行。
    static var agentBrowserArchName: String {
        var info = utsname()
        uname(&info)
        let machine = withUnsafeBytes(of: &info.machine) { raw -> String in
            guard let p = raw.baseAddress?.assumingMemoryBound(to: CChar.self) else { return "" }
            return String(cString: p)
        }
        return machine == "arm64" ? "agent-browser-darwin-arm64" : "agent-browser-darwin-x64"
    }

    /// 用户数据目录：settings.json / session.json / 抓取缓存 / 两份浏览器 profile 都落这里
    static let home: URL = {
        let fm = FileManager.default
        if let o = MBBPaths.overrideDataDir { return URL(fileURLWithPath: o) }

        // ① 分发版：包内带后端 → 用 Application Support（干净、可预期）
        if MBBPaths.bundledBackendDir != nil { return MBBPaths.supportDir }
        // ② 之前装过
        let installed = MBBPaths.supportDir.appendingPathComponent("backend/bridge.py")
        if fm.fileExists(atPath: installed.path) { return MBBPaths.supportDir }
        // ③ 开发布局：~/.mbboard 里就躺着 bridge.py（本机开发时不用折腾）
        let dev = MBBPaths.legacyDir.appendingPathComponent("bridge.py")
        if fm.fileExists(atPath: dev.path) { return MBBPaths.legacyDir }
        // ④ 全新机器
        return MBBPaths.supportDir
    }()

    static var backendDir: URL { home.appendingPathComponent("backend", isDirectory: true) }
    static var bridgeScript: URL { backendDir.appendingPathComponent("bridge.py") }

    static func file(_ name: String) -> URL { home.appendingPathComponent(name) }

    static func ensureDirs() {
        let fm = FileManager.default
        for d in [home, backendDir, binDir,
                  home.appendingPathComponent("chrome", isDirectory: true),
                  home.appendingPathComponent("taskcache", isDirectory: true)] {
            try? fm.createDirectory(at: d, withIntermediateDirectories: true)
        }
    }

    /// 把包内的 agent-browser 装到数据目录。
    ///
    /// 这一步的意义是把「新用户要先有 Node、再 npm install」这条路彻底删掉：
    /// agent-browser 是自包含的 Rust 二进制，拷过来就能跑。
    /// 本来就已经装过（系统里有一份）的用户不受影响 —— 后端自己会优先用它。
    /// 返回是否就位。
    @discardableResult
    static func installToolsIfNeeded() -> Bool {
        let fm = FileManager.default
        guard let tools = bundledToolsDir else {
            // 开发布局 / 本机已经有 ：只要系统里能找到就算了
            return fm.isExecutableFile(atPath: agentBrowser.path) || agentBrowserExistsAnywhere()
        }
        let src = tools.appendingPathComponent(agentBrowserArchName)
        guard fm.fileExists(atPath: src.path) else {
            Log.write("包内没有 \(agentBrowserArchName)，跳过工具安装")
            return agentBrowserExistsAnywhere()
        }

        let attrs = try? fm.attributesOfItem(atPath: src.path)
        let size = (attrs?[.size] as? NSNumber)?.intValue ?? 0
        let mtime = (attrs?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        let stamp = "\(size)-\(Int(mtime))"
        let stampFile = binDir.appendingPathComponent(".agent-browser.stamp")

        // 装过同一份就跳过：这东西 10MB，每次启动都拷一遍是在磨 SSD
        if (try? String(contentsOf: stampFile, encoding: .utf8)) == stamp,
           fm.isExecutableFile(atPath: agentBrowser.path) {
            return true
        }

        do {
            try fm.createDirectory(at: binDir, withIntermediateDirectories: true)
            try? fm.removeItem(at: agentBrowser)
            try fm.copyItem(at: src, to: agentBrowser)
            try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: agentBrowser.path)
            // 从 App 包里拷出来的文件可能带 quarantine，不清会被拦
            let x = Process()
            x.executableURL = URL(fileURLWithPath: "/usr/bin/xattr")
            x.arguments = ["-dr", "com.apple.quarantine", binDir.path]
            try? x.run(); x.waitUntilExit()
            try? stamp.write(to: stampFile, atomically: true, encoding: .utf8)
            Log.write("已安装 agent-browser → \(agentBrowser.path)")
            return true
        } catch {
            Log.write("安装 agent-browser 失败：\(error.localizedDescription)")
            return agentBrowserExistsAnywhere()
        }
    }

    /// 系统里（npm 全局 / homebrew / 数据目录）有没有现成的 agent-browser
    static func agentBrowserExistsAnywhere() -> Bool {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser.path
        let cands = ["\(home)/.npm-global/bin/agent-browser",
                     "/opt/homebrew/bin/agent-browser",
                     "/usr/local/bin/agent-browser"]
        if cands.contains(where: { fm.isExecutableFile(atPath: $0) }) { return true }
        if let path = ProcessInfo.processInfo.environment["PATH"] {
            for d in path.split(separator: ":") {
                if fm.isExecutableFile(atPath: "\(d)/agent-browser") { return true }
            }
        }
        return false
    }

    /// 后端指纹：整棵目录里所有文件的「相对路径 + 大小 + 修改时间」揉成一个串。
    /// 任何一个后端文件动了，这个串就变 —— 单看 bridge.py 会漏掉 mssession.py、
    /// seiue.py 这类同版本一起发布的文件（踩过坑，见下）。
    private static func backendFingerprint(of dir: URL) -> String? {
        let fm = FileManager.default
        guard let en = fm.enumerator(at: dir, includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey],
                                     options: [.skipsHiddenFiles]) else { return nil }
        var rows: [String] = []
        let root = dir.standardizedFileURL.path
        for case let f as URL in en {
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: f.path, isDirectory: &isDir), !isDir.boolValue else { continue }
            let a = try? fm.attributesOfItem(atPath: f.path)
            let size = (a?[.size] as? NSNumber)?.intValue ?? 0
            let mt = (a?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
            var rel = f.standardizedFileURL.path
            if rel.hasPrefix(root) { rel = String(rel.dropFirst(root.count)) }
            rows.append("\(rel)|\(size)|\(Int(mt))")
        }
        // 目录遍历顺序不保证稳定 → 排序后拼接，指纹才可复现
        rows.sort()
        let joined = rows.joined(separator: "\n")
        // ⚠️ 不要用 String.hashValue —— Swift 的 hashValue 带「每进程随机种子」，
        //    同一个串在两次启动里结果不同，指纹就永远对不上、每次启动都白拷一遍。
        //    这里用 FNV-1a 自己算，跨进程稳定。
        var h: UInt64 = 0xcbf29ce484222325
        for b in joined.utf8 {
            h ^= UInt64(b)
            h = h &* 0x100000001b3
        }
        return String(h, radix: 36)
    }

    /// 把 App 包内的后端装到用户数据目录（内容变了才重装）。
    /// 返回是否成功就位。
    @discardableResult
    static func installBackendIfNeeded() -> Bool {
        let fm = FileManager.default
        guard let src = bundledBackendDir else {
            // 没有随包后端：开发布局就直接用现成的
            return fm.fileExists(atPath: bridgeScript.path)
        }
        // 指纹：包内**整棵后端目录**里所有文件的「相对路径 + 大小 + 修改时间」。
        //
        // 这里踩过坑：早先只看 bridge.py 一个文件，结果改了 board/shared/mssession.py
        // 之后 App 启动时指纹一模一样 → 认为「没变」→ 不重装 → 用户跑的还是旧后端，
        // 修好的问题原样复现。后端从来是「整体一个版本」，指纹就必须覆盖整棵树。
        let stamp = backendFingerprint(of: src) ?? "0"
        let stampFile = backendDir.appendingPathComponent(".installed")

        if (try? String(contentsOf: stampFile, encoding: .utf8)) == stamp,
           fm.fileExists(atPath: bridgeScript.path) {
            return true
        }

        do {
            try fm.createDirectory(at: backendDir, withIntermediateDirectories: true)
            // 整棵替换：后端是整体版本，不做逐文件增量 —— 少一类「新旧混用」的怪问题
            if fm.fileExists(atPath: backendDir.path) {
                for item in (try? fm.contentsOfDirectory(at: backendDir,
                                                         includingPropertiesForKeys: nil)) ?? [] {
                    try? fm.removeItem(at: item)
                }
            }
            for item in (try? fm.contentsOfDirectory(at: src, includingPropertiesForKeys: nil)) ?? [] {
                try? fm.copyItem(at: item, to: backendDir.appendingPathComponent(item.lastPathComponent))
            }
            try? stamp.write(to: stampFile, atomically: true, encoding: .utf8)
            Log.write("已安装后端 → \(backendDir.path)（\(stamp)）")
            return fm.fileExists(atPath: bridgeScript.path)
        } catch {
            Log.write("安装后端失败：\(error.localizedDescription)")
            return false
        }
    }
}

/* ======================================================================
   换了 Bundle ID 之后，把老身份下的东西接过来
   ----------------------------------------------------------------------
   为什么必须做：WKWebView 的 cookie / localStorage 是按 Bundle ID 分目录存的。
   改标识 = 灵析 AI 当场掉登录，而用户根本不知道发生了什么 ——
   他只会觉得「这软件老是自己退登录」。这不是用户的问题，是我们的问题。
   只对「老目录在、新目录还没建」的情况生效；别人的机器上老目录不存在，纯空操作。
   ====================================================================== */

enum LegacyIdentity {

    /// 老 Bundle ID 名单。
    ///
    /// ⚠️ 这里**故意不写死在源码里**。历史上用过的那个标识里带着开发者的名字，
    ///    而这份源码是要给出去的 —— 任何个人标识都不该出现在里面。
    ///    改成从数据目录读一份可选名单：
    ///      ~/Library/Application Support/ManageBac 看板 Mac/legacy-identities.json
    ///      ["com.example.oldbundleid"]
    ///    文件不存在 = 空名单 = 下面两个迁移函数全是空操作（别人机器上本来
    ///    也没有老目录，行为完全一致）。
    static var oldIDs: [String] {
        let url = MBBPaths.home.appendingPathComponent("legacy-identities.json")
        guard let d = try? Data(contentsOf: url),
              let list = try? JSONDecoder().decode([String].self, from: d) else { return [] }
        return list.filter { !$0.isEmpty }
    }

    /// 新 Bundle ID（跟着 Info.plist 走）
    static var newID: String { Bundle.main.bundleIdentifier ?? "" }

    /// 必须在**创建任何 WKWebView 之前**调用，否则 WebKit 可能已经建好新目录了。
    static func migrateWebDataIfNeeded() {
        let fm = FileManager.default
        let new = newID
        let olds = oldIDs
        guard !new.isEmpty, !olds.isEmpty, !olds.contains(new) else { return }
        let lib = fm.homeDirectoryForCurrentUser.appendingPathComponent("Library", isDirectory: true)

        // ① 目录型：WebKit = localStorage / IndexedDB，Cookies = cookie 库，Caches = 缓存
        for sub in ["WebKit", "Cookies", "Caches"] {
            for old in olds {
                let a = lib.appendingPathComponent(sub).appendingPathComponent(old)
                let b = lib.appendingPathComponent(sub).appendingPathComponent(new)
                guard fm.fileExists(atPath: a.path),
                      !fm.fileExists(atPath: b.path) else { continue }
                if (try? fm.copyItem(at: a, to: b)) != nil {
                    Log.write("已迁移 \(sub)/\(old) → \(new)")
                }
            }
        }

        // ② 文件型：HTTPStorages 里躺着的是 `<bundleID>.binarycookies` 这种**单个文件**，
        //    不是同名目录。只按目录去找，一条都匹配不上 —— 结果就是 localStorage
        //    搬过来了、cookie 没搬，登录态卡在「一半」：页面看着像登着，
        //    刷新一下又要重新登。这一条就是灵析 AI 反复掉登录的其中一环。
        let hs = lib.appendingPathComponent("HTTPStorages", isDirectory: true)
        for old in olds {
            for suffix in ["", ".binarycookies"] {
                let a = hs.appendingPathComponent(old + suffix)
                let b = hs.appendingPathComponent(new + suffix)
                guard fm.fileExists(atPath: a.path),
                      !fm.fileExists(atPath: b.path) else { continue }
                if (try? fm.copyItem(at: a, to: b)) != nil {
                    Log.write("已迁移 HTTPStorages/\(old)\(suffix) → \(new)\(suffix)")
                }
            }
        }
    }

    /// 把老身份下的偏好设置接过来（主题、快捷键、开关……全在这里）。
    /// 用 UserDefaults(suiteName:) 直接读老域，比搬 plist 文件可靠 —— 后者对本次
    /// 启动无效（框架早在 main 之前就把偏好读进内存了）。
    static func migrateDefaultsIfNeeded() {
        let new = newID
        let olds = oldIDs
        guard !new.isEmpty, !olds.isEmpty, !olds.contains(new) else { return }
        let std = UserDefaults.standard
        for old in olds {
            let doneKey = "mb.migrated.from.\(old)"
            if std.bool(forKey: doneKey) { continue }
            if let src = UserDefaults(suiteName: old) {
                for (k, v) in src.dictionaryRepresentation() {
                    // 系统自留的键不动，其余只补空缺（用户在新身份下改过的不覆盖）
                    if k.hasPrefix("NS") || k.hasPrefix("Apple") { continue }
                    if std.object(forKey: k) == nil { std.set(v, forKey: k) }
                }
            }
            std.set(true, forKey: doneKey)
            Log.write("已迁移偏好设置：\(old) → \(new)")
        }
    }

    /// 启动时按顺序做一遍。越早越好（WebView 之前）。
    static func bootstrap() {
        migrateDefaultsIfNeeded()
        migrateWebDataIfNeeded()
        MBBPaths.ensureDirs()
        migrateLegacyStateIfNeeded()
        MBBPaths.installToolsIfNeeded()      // 抓取工具（agent-browser）
        MBBPaths.installBackendIfNeeded()
    }

    /// 把老目录（~/.mbboard）里的**偏好**接过来，**登录态一律不接**。
    ///
    /// 这个区分就是整件事的重点：
    ///   · 偏好（主题 / 快捷键 / 提醒设置 / 作息）—— 用户的心血，搬过来；
    ///   · 登录态（cookie、凭据、浏览器 profile）—— 属于「我的账号」，
    ///     不搬，这样拿到的就是一份干净的、必须自己重新登录的版本。
    /// 只在老目录存在、且新目录里还没有这些文件时动手；别人的机器上纯空操作。
    static func migrateLegacyStateIfNeeded() {
        let fm = FileManager.default
        let home = MBBPaths.home
        let old = MBBPaths.legacyDir
        guard home.path != old.path,
              fm.fileExists(atPath: old.appendingPathComponent("bridge.py").path) else { return }

        // 只搬「偏好」，一个字都不多搬
        let prefFiles = ["settings.json", "gradetimes.json", "relay.json",
                         "relay-quota.json", "prefetch.json", "ec.json", "notify-state.json"]
        var moved: [String] = []
        for name in prefFiles {
            let a = old.appendingPathComponent(name)
            let b = home.appendingPathComponent(name)
            guard fm.fileExists(atPath: a.path),
                  !fm.fileExists(atPath: b.path) else { continue }
            if (try? fm.copyItem(at: a, to: b)) != nil { moved.append(name) }
        }

        // Chrome 是个 300+ MB 的浏览器本体，不是个人数据 —— 复制太浪费，直接挂软链。
        // 目标没了就把断链清掉，让 bridge 自己再下一个。
        let chromeOld = old.appendingPathComponent("chrome")
        let chromeNew = home.appendingPathComponent("chrome")
        if fm.fileExists(atPath: chromeOld.path) {
            let ok = (try? fm.destinationOfSymbolicLink(atPath: chromeNew.path)).map {
                fm.fileExists(atPath: $0)
            } ?? false
            if !ok {
                try? fm.removeItem(at: chromeNew)
                try? fm.createSymbolicLink(at: chromeNew, withDestinationURL: chromeOld)
                moved.append("chrome(软链)")
            }
        }

        if !moved.isEmpty {
            Log.write("已从老目录继承偏好：\(moved.joined(separator: ", "))"
                      + "（登录态一律不继承，需要重新登录）")
        }
    }
}
