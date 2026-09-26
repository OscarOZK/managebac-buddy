import Foundation
import Darwin        // removexattr / ENOATTR / errno

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
       MBB_DATA  用户数据   —— ~/Library/Application Support/ManageBac-Buddy/

   另外这里还负责把「换了 Bundle ID」这件事对用户透明：
   WKWebView 的 cookie（灵析 AI 的登录态）是按 Bundle ID 分目录存的，
   只改个标识就会把人踢下线 —— 那不是用户做错了什么，是我们改了目录名。
   ====================================================================== */

enum MBBPaths {

    /// 自检 / 测试时把数据目录指到别处（绝不碰真数据）
    static var overrideDataDir: String? = nil

    /// 分发版的数据目录名 —— 用 App 名，用户在 Finder 里认得出来。
    ///
    /// ★ 这个名字改过一次：`ManageBac 看板 Mac` → `ManageBac-Buddy` ★
    /// 改名绝不能让人丢数据 —— 这个目录里躺着课表、成绩、缓存、三份浏览器
    /// profile 和四个账号的登录态，加起来几百兆。所以下面备了 `oldFolderNames`，
    /// 由 `migrateDataDirIfNeeded()` 在**任何人读 home 之前**整个接过来
    /// （595MB 的目录只做 rename，不复制 —— 复制既慢一倍又占双份磁盘）。
    ///
    /// 原先那个「Mac」后缀的由来，记在这里免得以后有人再踩：Windows 版
    /// （Electron）当年也叫 `ManageBac 看板`，两边撞在同一个目录上，而
    /// Windows 那边留着一份只有 `{"theme":"light"}` 的 settings.json ——
    /// 它会顶掉「不覆盖已有偏好」这条迁移规则，用户的主题、快捷键、
    /// 提醒时间就全都搬不过来了。现在新名字两边都不撞，不用再加后缀。
    static let appFolderName = "ManageBac-Buddy"

    /// 历史上用过的数据目录名，从新到旧。
    /// 只在「新目录还不存在」时按顺序找第一个存在的搬过来。
    static let oldFolderNames = ["ManageBac 看板 Mac", "ManageBac 看板"]

    /// 老版本（以及本机开发布局）的数据目录
    static var legacyDir: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".mbboard", isDirectory: true)
    }

    /// 数据目录改名迁移。**必须在任何人读 `home` 之前跑**（见下面 `home` 的
    /// 初始化块，它是唯一入口）。
    ///
    /// 用 `moveItem` 而不是 `copyItem`：Teams 那份 profile 一家就占 513MB，
    /// 复制要等半天、还白占一份磁盘。目录改名在同卷上是原子的，瞬间完成。
    /// 万一 move 失败（跨卷 / 权限），退回复制 —— 慢，但至少不丢。
    static func migrateDataDirIfNeeded() {
        let fm = FileManager.default
        let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fm.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support", isDirectory: true)
        let dest = base.appendingPathComponent(appFolderName, isDirectory: true)
        guard !fm.fileExists(atPath: dest.path) else { return }
        for name in oldFolderNames {
            let src = base.appendingPathComponent(name, isDirectory: true)
            guard fm.fileExists(atPath: src.path) else { continue }
            if (try? fm.moveItem(at: src, to: dest)) != nil {
                Log.write("数据目录已改名：\(name) → \(appFolderName)（整体搬移，未复制）")
                return
            }
            if (try? fm.copyItem(at: src, to: dest)) != nil {
                Log.write("数据目录已改名：\(name) → \(appFolderName)（move 失败，退回复制；老目录保留）")
                return
            }
            Log.write("⚠️ 数据目录改名失败：\(name) → \(appFolderName)")
        }
    }

    /// ~/Library/Application Support/ManageBac-Buddy
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

    /// ★ App 包内自带的 Python 运行时 ★
    ///
    /// 为什么非带不可：看板的数据全部来自本机的 Python 桥接服务，而没有带它
    /// 的时候，我们只能指望「用户电脑上恰好有个能用的 python3」。实测这一条
    /// 在普通 Mac 上根本不成立 —— macOS 自带的 /usr/bin/python3 只是一层壳，
    /// 没装 Xcode 命令行工具就跑不起来（还弹系统弹窗）。结果就是后台静默起不来，
    /// 四个账号全部登不进去，而屏幕上只写着「看板没应答」。
    ///
    /// 用的是 python-build-standalone 的 install_only 包，解包后是自带标准库、
    /// 可重定位、不依赖系统任何东西的一份完整运行时。后端只用标准库，
    /// 所以不需要 pip、不需要网络。
    ///
    /// 目录布局（两种都认，兼容以后换发行版）：
    ///     <App>/Contents/Resources/python/bin/python3
    ///     <App>/Contents/Resources/python/python/bin/python3
    static var bundledPython: URL? {
        guard let r = Bundle.main.resourceURL else { return nil }
        let d = r.appendingPathComponent("python", isDirectory: true)
        for rel in ["bin/python3", "python/bin/python3"] {
            let f = d.appendingPathComponent(rel)
            if FileManager.default.isExecutableFile(atPath: f.path) { return f }
        }
        return nil
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

        // ★ 数据目录改名迁移挂在这一句上，而不是挂在 bootstrap() 里 ★
        //   `home` 是个 lazy static：谁先读它，这个块就先跑。而读它的地方
        //   不止 bootstrap()（legacy-identities.json、WebKit 建目录都会读）。
        //   挂在唯一入口上，顺序就不可能被绕过去；挂在 bootstrap() 里，
        //   则要看「有没有人抢在它前面先读了 home」—— 那种 bug 只在
        //   某些启动路径上出现，最难查。
        MBBPaths.migrateDataDirIfNeeded()

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
            // 从 App 包里拷出来的文件带 quarantine，不清会被系统拒绝执行。
            // 和包内 Python 用同一套清理（见 stripQuarantine），别各写一份。
            let (n, failed) = stripQuarantine(under: binDir)
            if !failed.isEmpty {
                Log.write("agent-browser 有 \(failed.count)/\(n) 个文件没清掉隔离标记")
            }
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

    /// 把包内 Python 运行时的「下载隔离」标记清掉。
    ///
    /// 为什么必须做：App 是以「下载来的文件」身份落到用户机器上的，整包带
    /// com.apple.quarantine。我们直接在包内执行 python（以及它加载的 .so），
    /// 被隔离的二进制会被系统拒绝执行 —— 表现是「后台起不来」，而且报错
    /// 藏在子进程里，屏幕上什么都看不到。
    ///
    /// 只做一次：用数据目录里的一个标记文件记住清过了。
    ///
    /// 实现上改过一版。原来是一句 `/usr/bin/xattr -dr com.apple.quarantine <root>`，
    /// 两个毛病：
    ///   ① **慢且重** —— 为遍历上千个文件单开一个进程；
    ///   ② **失败不可见** —— 返回码被丢掉，只在日志里留一句。而这一步失败的后果
    ///      特别隐蔽：包内 python 起不来 → 后台连不上 → 用户屏幕上显示
    ///      「这台电脑上找不到可用的 Python 运行环境」，我们却完全不知道是
    ///      因为隔离标记没清掉。
    /// 现在直接调 removexattr(2)：一次系统调用，不 fork，并把「处理了几个 / 失败
    /// 在哪几个」都落到日志里，真出问题一眼能看出来。
    static func prepareBundledPython() {
        guard let exe = bundledPython else { return }
        let root = exe.deletingLastPathComponent().deletingLastPathComponent()
        let fm = FileManager.default
        let stamp = binDir.appendingPathComponent(".python.dequarantined")
        // 标记里存运行时根目录：换了新的 App 位置（比如从下载文件夹挪到应用程序）
        // 就要重新清一遍。
        if (try? String(contentsOf: stamp, encoding: .utf8)) == root.path,
           fm.fileExists(atPath: stamp.path) { return }

        let (n, failed) = stripQuarantine(under: root)
        try? fm.createDirectory(at: binDir, withIntermediateDirectories: true)

        // 还有文件没清掉就退回子进程再试一遍 —— 慢，但这会儿没别的招了。
        //
        // 判据是 `!ok` 而不是 `n == 0`。区别很要紧：实测过一种情况是「文件全都
        // 遍历到了、removexattr 却一律 EPERM」，此时 n 很大、failed 也是满的，
        // 但确实是**一个都没清成**。写成 n == 0 的话这种局面会直接跳过回退，
        // 然后我们就会带着一个「假成功」的标记继续往下跑。
        var ok = failed.isEmpty
        if !ok {
            Log.write("removexattr 有 \(failed.count)/\(n) 个没清掉，回退 /usr/bin/xattr 子进程")
            let x = Process()
            x.executableURL = URL(fileURLWithPath: "/usr/bin/xattr")
            x.arguments = ["-dr", "com.apple.quarantine", root.path]
            x.standardOutput = FileHandle.nullDevice
            x.standardError = FileHandle.nullDevice
            if (try? x.run()) != nil {
                x.waitUntilExit()
                ok = x.terminationStatus == 0
            }
            Log.write("回退 xattr 子进程：\(ok ? "成功" : "仍失败（rc=\(x.terminationStatus)）")")
        }

        // 只有确认真清干净了才落标记；否则下次启动会再试一遍 ——
        // 落了一个假的标记就等于把这个坑永远埋起来了。
        if ok {
            try? root.path.write(to: stamp, atomically: true, encoding: .utf8)
            Log.write("已清除包内 Python 的隔离标记：\(root.path)（处理 \(n) 个文件）")
        } else {
            Log.write("⚠️ 包内 Python 有 \(failed.count) 个文件没清掉隔离标记，"
                      + "前几个：\(failed.prefix(3).joined(separator: "、"))")
        }
    }

    /// POSIX realpath(3)：把路径里的符号链接（含 /tmp、/var 这类顶层链接）全部解析掉。
    ///
    /// 为什么不用 `URL.resolvingSymlinksInPath()`：实测它在 macOS 上不解析 /tmp
    /// 这类链接（返回的还是 /tmp/…），而 FileManager.enumerator 返回的却是
    /// /private/tmp/…。做「相对路径」计算时两边必须同一个表示形式，否则前缀匹配
    /// 会静默失效。
    static func realPath(_ p: String) -> String {
        guard let r = p.withCString({ realpath($0, nil) }) else { return p }
        defer { free(r) }
        return String(cString: r)
    }

    /// 递归清掉 root 下所有文件的 com.apple.quarantine。
    ///
    /// 返回 (动过的文件数, 没清掉的文件相对路径)。用 removexattr(2) 而不是
    /// /usr/bin/xattr：后者要 fork 一个进程去遍历上千个条目，前者是一次系统调用。
    ///
    /// 顺带一提 —— 真正会被 Gatekeeper 拦的只有 Mach-O（包内 python 运行时里
    /// 一共 5 个：bin/python3.12、lib/libpython3.12.dylib、lib/thread2.8.9/…
    /// 和两个 .so），其余 1500 多个 .py 文件清了也是白清。这里不做过滤是为了
    /// 少一个可能漏的地方，代价只有几毫秒。
    static func stripQuarantine(under root: URL) -> (Int, [String]) {
        let fm = FileManager.default
        guard let walk = fm.enumerator(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [],
            errorHandler: { _, _ in true }        // 单个条目读不动就跳过，别整趟中断
        ) else { return (0, []) }

        var n = 0
        var failed: [String] = []
        for case let f as URL in walk {
            if (try? f.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true { continue }
            n += 1
            let cleaned = f.withUnsafeFileSystemRepresentation { p -> Bool in
                guard let p else { return false }
                if removexattr(p, "com.apple.quarantine", 0) == 0 { return true }
                // ENOATTR = 本来就没这个标记，属于正常情况，不算失败
                return errno == ENOATTR
            }
            if !cleaned {
                failed.append(f.path.replacingOccurrences(of: root.path + "/", with: ""))
            }
        }
        return (n, failed)
    }

    /// 包内 Python 真的执行不了时的**最后一道保险**：把整份运行时搬到数据目录，
    /// 从那儿执行。
    ///
    /// 什么时候会用到：`com.apple.quarantine` 没清掉，包内那份被系统拒绝执行。
    /// 清标记是标准做法且通常有效，但「通常有效」和「一定有效」之间隔着一整类
    /// 用户 —— 而这一类用户看到的是「找不到可用的 Python」，然后就再也用不了了。
    ///
    /// 为什么搬一份就能绕开：quarantine 是挂在文件上的扩展属性，而这里是
    /// 「读进内存 → 写到新文件」，新文件不带任何继承来的标记。
    /// ★ 这一点和 `cp -R` 有本质差别：cp 会把 xattr 一起复制过去，搬了也白搬。
    ///
    /// 只在包内那份跑不起来时才走这条路（要写 40MB 左右），不是启动的常规动作。
    /// 返回可执行的路径，失败给 nil。
    static func relocateBundledPython() -> String? {
        guard let exe = bundledPython else { return nil }
        // 基准路径必须是 realpath。
        // 实测结论：FileManager.enumerator 返回的是**解析过符号链接**的路径
        //（/tmp 会变成 /private/tmp），而 URL.resolvingSymlinksInPath() 在 macOS 上
        // **并不解析** /tmp、/var 这类顶层链接。两边对不上，下面按前缀算相对路径
        // 就会全部落空（表现为「重写 0 个文件」，而且一声不响）。
        // 所以这里用权威的 POSIX realpath(3)。
        let srcPath = MBBPaths.realPath(exe.deletingLastPathComponent()
                                           .deletingLastPathComponent().path)
        let fm = FileManager.default
        let dst = binDir.appendingPathComponent("python", isDirectory: true)
        let dstExe = dst.appendingPathComponent("bin/python3")

        // 以前搬过就直接用，别每次都重写 40MB。
        //
        // 这里不需要给副本记「版本指纹」：调用方是「包内那份先试，能用就用它；
        // 不能用才来搬」，所以只要包内恢复正常，就再也不会走到这个副本。
        // 副本唯一会被用到的情况是「包内那份一直执行不了」，此时旧副本正是我们要的。
        if fm.isExecutableFile(atPath: dstExe.path) { return dstExe.path }

        try? fm.createDirectory(at: dst, withIntermediateDirectories: true)
        guard let walk = fm.enumerator(
            at: URL(fileURLWithPath: srcPath), includingPropertiesForKeys: [.isDirectoryKey],
            options: [], errorHandler: { _, _ in true }
        ) else { return nil }

        var n = 0
        for case let f as URL in walk {
            // ★ 用 hasPrefix 守一道，**绝不要**用 replacingOccurrences 算相对路径：
            //   后者是部分匹配，当前缀对不上时会悄悄算出个完全错误的路径。
            //   实测踩过 —— 源在 /tmp 下时，产物全落到了 .../python/privatebin/ 里，
            //   而因为是「写成功了」，一点报错都没有。
            guard f.path.hasPrefix(srcPath + "/") else { continue }
            let rel = String(f.path.dropFirst(srcPath.count + 1))
            let out = dst.appendingPathComponent(rel)

            // 符号链接（bin/python3 → python3.12 之类）照原样重建，放在最前面判断。
            // 注意目标多半是相对的，所以原样搬运目标字符串，不要解析成绝对路径。
            //
            // ★ 必须先建父目录。枚举是深度优先、同级顺序不保证，`bin/python3`
            //   完全可能排在 `bin/` 这个目录条目之前；少了这一步 createSymbolicLink
            //   会因为「父目录不存在」默默失败，最后搬出来的运行时缺了 bin/python3
            //   —— 而那个链接恰恰是调用方要用的入口，症状是「python3 doesn't exist」。
            //   （这个坑同样是实测出来的：静态看代码一切正常。）
            if let link = try? fm.destinationOfSymbolicLink(atPath: f.path) {
                try? fm.createDirectory(at: out.deletingLastPathComponent(),
                                       withIntermediateDirectories: true)
                try? fm.removeItem(at: out)
                try? fm.createSymbolicLink(atPath: out.path, withDestinationPath: link)
                continue
            }

            let attrs = try? fm.attributesOfItem(atPath: f.path)
            if (attrs?[.type] as? FileAttributeType) == .typeDirectory {
                try? fm.createDirectory(at: out, withIntermediateDirectories: true)
                continue
            }
            guard let data = try? Data(contentsOf: f) else { continue }
            try? fm.createDirectory(at: out.deletingLastPathComponent(),
                                   withIntermediateDirectories: true)
            // 写到新文件 = 丢掉源文件的 xattr，这正是我们要的
            if (try? data.write(to: out)) != nil {
                if let perm = (attrs?[.posixPermissions] as? NSNumber)?.intValue {
                    try? fm.setAttributes([.posixPermissions: perm], ofItemAtPath: out.path)
                }
                n += 1
            }
        }

        if fm.isExecutableFile(atPath: dstExe.path) {
            Log.write("已把包内 Python 重定位到数据目录（\(n) 个文件）→ \(dst.path)")
            return dstExe.path
        }
        Log.write("重定位包内 Python 失败：\(dstExe.path) 不可执行")
        return nil
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

    /// 源码里认下的老 Bundle ID。
    ///
    /// 上面那段注释说的是「**带个人标识的**老 ID 不许写进源码」—— 这条依然成立，
    /// 所以历史上那个 `com.oscar.mbboard.*` 永远不会出现在这里，只从数据目录的
    /// `legacy-identities.json` 读。
    ///
    /// 但这个列表本身是另一回事：v3.5 全面改名时，**正在用的**那个 ID
    /// （`com.mbboard.dashboard`）变成了「老 ID」，而它不含任何个人信息 ——
    /// 它本来就在 Info.plist 里公开着，Notifier 还拿它当兜底默认值。
    /// 这种 ID 写进源码没有隐私问题，反过来还有个实打实的好处：
    /// **改名的那个版本自己就知道要接谁的数据**，不必指望用户手上恰好有一份
    /// 迁移名单。用户从 v3.0 直接升到 v3.5 时，四个账号的 Cookie 就能跟着过来，
    /// 而不是「升级完发现全掉线了」。
    static let knownOldIDs = ["com.mbboard.dashboard"]

    /// 老 Bundle ID 名单 = 源码里认下的 + 数据目录里那份可选名单。
    ///
    /// `~/Library/Application Support/ManageBac-Buddy/legacy-identities.json`
    ///     ["com.example.oldbundleid"]
    /// 文件不存在 = 只有源码那一条 = 空操作（别人机器上本来也没有老目录，
    /// 行为完全一致）。
    static var oldIDs: [String] {
        let url = MBBPaths.home.appendingPathComponent("legacy-identities.json")
        let extra: [String]
        if let d = try? Data(contentsOf: url),
           let list = try? JSONDecoder().decode([String].self, from: d) {
            extra = list
        } else {
            extra = []
        }
        return (knownOldIDs + extra).filter { !$0.isEmpty }
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
        MBBPaths.prepareBundledPython()       // 包内 Python 运行时（去隔离标记）
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
