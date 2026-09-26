#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""任意 Chromium 内核浏览器：**找** + **兜底准备**。

为什么非要有这个模块
--------------------
分发出去之后，朋友那边的现场是这样的：

    ManageBac 登录失败 / Teams「找不到 Chrome for Testing」/
    希悦「没能打开课表页」/ 提示「看板没应答」

而唯一登录成功的那个集成（DeepSeek）恰好是**唯一不经过 Python 后端**的。
也就是说，问题几乎不在某个爬虫脚本里，而在「后端能不能起来 + 它能不能
找到一个浏览器」这两件最外层的事上。

这个模块只解决第二件：浏览器。

原来错在哪
----------
① 只认我们自己下载的那一份。Teams（mssession.py）和希悦（seiue.py）各自
   只查一条窄路径：

       <数据目录>/chrome/Google Chrome for Testing.app/Contents/MacOS/...

   ——用户机器上只要没被我们下载过，两条链路就**必然**报
   「找不到 Chrome for Testing」。而 bridge.py 里另有一份宽查找
   （扫 /Applications 下的 Chrome / Edge / Brave / Chromium）。两套逻辑
   不共享，于是出现了最离谱的现场：

       「检查组件」说浏览器就绪（宽查找找到了系统里的 Edge），
       点进去连 Teams / 希悦却报「找不到 Chrome for Testing」（窄查找没找到）。

② 门槛本身就是多余的。agent-browser 和 CDP 只需要一个 **Chromium 内核的
   可执行文件** —— Chrome、Edge、Brave、Arc、Chromium、Vivaldi 都能用。
   用户在官网装过其中任何一个，就完全够用，不该再逼他等 150MB 下载。

所以顺序改成：
    ① 环境变量显式指定（调试用）
    ② 数据目录里我们自己下过的那一份（最可控，也最可能带着 session）
    ③ 系统里**已经装了**的任意 Chromium 内核浏览器（用户零操作）
    ④ 一个都没有 → 后台下一份 Chrome for Testing 兜底

③ 的发现方式不只靠硬编码路径：macOS 上再用 LaunchServices（mdfind 按
bundle id 问系统）扫一遍。浏览器不一定装在 /Applications —— 有的在
~/Applications，有的被改过名字，硬编码路径都会漏。
"""
import json
import os
import platform
import re
import shutil
import subprocess
import sys
import threading
import time
import urllib.request
import zipfile

HOME = os.path.expanduser("~")
DATA_DIR = os.path.abspath(os.path.expanduser(
    os.environ.get("MBBOARD_DATA") or os.path.join(HOME, ".mbboard")))

# ---------- 我们自己下载的那一份的落点 ----------
CHROME_DIR = os.path.join(DATA_DIR, "chrome")
DOWNLOADED = {
    "darwin": [
        os.path.join(CHROME_DIR, "Google Chrome for Testing.app",
                     "Contents", "MacOS", "Google Chrome for Testing"),
        os.path.join(CHROME_DIR, "Google Chrome.app",
                     "Contents", "MacOS", "Google Chrome"),
    ],
    "win32": [os.path.join(CHROME_DIR, "chrome.exe")],
    "linux": [
        os.path.join(CHROME_DIR, "chrome-linux64", "chrome"),
        os.path.join(CHROME_DIR, "chrome", "chrome"),
    ],
}

# ---------- macOS：已知的 Chromium 内核浏览器 ----------
# (bundle id, .app 目录名) —— 目录名只是给「不看 mdfind」时的快速路径用，
# 真正的可执行文件名一律从 Info.plist 的 CFBundleExecutable 读，
# 这样改过名/本地化过的安装（比如「Microsoft Edge Beta」）也不会漏。
_MAC_BROWSERS = [
    ("com.google.Chrome", "Google Chrome.app"),
    ("com.google.Chrome.canary", "Google Chrome Canary.app"),
    ("com.google.Chrome.beta", "Google Chrome Beta.app"),
    ("com.google.Chrome.dev", "Google Chrome Dev.app"),
    ("com.microsoft.edgemac", "Microsoft Edge.app"),
    ("com.microsoft.edgemac.Beta", "Microsoft Edge Beta.app"),
    ("com.microsoft.edgemac.Dev", "Microsoft Edge Dev.app"),
    ("com.brave.Browser", "Brave Browser.app"),
    ("com.brave.Browser.beta", "Brave Browser Beta.app"),
    ("org.chromium.Chromium", "Chromium.app"),
    ("company.thebrowser.Browser", "Arc.app"),
    ("com.vivaldi.Vivaldi", "Vivaldi.app"),
    ("com.operasoftware.Opera", "Opera.app"),
    ("com.operasoftware.OperaGX", "Opera GX.app"),
    ("com.yandex.desktop.yandex-browser", "Yandex.app"),
    ("com.pushplaylabs.sidekick", "Sidekick.app"),
    ("ru.yandex.desktop.yandex-browser", "Yandex.app"),
    ("com.qihoo.360browser", "360Browser.app"),
    ("com.sigma.browser", "sigma.app"),
]

_APP_DIRS = [
    "/Applications",
    os.path.join(HOME, "Applications"),
    "/Applications/Utilities",
    os.path.join(CHROME_DIR),          # 我们自己下载的那一份也按普通 .app 找
]

# ---------- Windows / Linux ----------
_OTHER = {
    "win32": [
        r"C:\Program Files\Google\Chrome\Application\chrome.exe",
        r"C:\Program Files (x86)\Google\Chrome\Application\chrome.exe",
        r"C:\Program Files (x86)\Microsoft\Edge\Application\msedge.exe",
        r"C:\Program Files\Microsoft\Edge\Application\msedge.exe",
        os.path.join(os.environ.get("LOCALAPPDATA", ""),
                     r"Google\Chrome\Application\chrome.exe"),
    ],
    "linux": [
        "/usr/bin/google-chrome", "/usr/bin/google-chrome-stable",
        "/usr/bin/chromium", "/usr/bin/chromium-browser",
        "/usr/bin/microsoft-edge", "/snap/bin/chromium",
        "/opt/google/chrome/chrome",
    ],
}

_LOCK = threading.RLock()
_FIND_CACHE = {"at": 0.0, "path": "", "ttl": 20.0}


# ==========================================================================
# 一、查找
# ==========================================================================

def _plist_str(plist, key):
    try:
        out = subprocess.run(
            ["/usr/libexec/PlistBuddy", "-c", "Print :" + key, plist],
            stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
            timeout=5, text=True).stdout.strip()
        return out
    except Exception:
        return ""


def _exe_of_app(app_path):
    """从 .app 里取出真正的可执行文件路径。

    必须读 CFBundleExecutable，不能拼目录名：Edge 的目录叫
    「Microsoft Edge.app」而二进制叫 msedge；Brave 的目录叫
    「Brave Browser.app」而二进制叫「Brave Browser」；本地化或改过
    名字的安装更是完全对不上。读错了的后果是「明明装了浏览器却说没有」。
    """
    if not app_path.endswith(".app") or not os.path.isdir(app_path):
        return ""
    exe = _plist_str(os.path.join(app_path, "Contents", "Info.plist"),
                     "CFBundleExecutable")
    if exe:
        p = os.path.join(app_path, "Contents", "MacOS", exe)
        if os.path.exists(p) and os.access(p, os.X_OK):
            return p
    # 退化：Contents/MacOS 下第一个可执行文件
    macos = os.path.join(app_path, "Contents", "MacOS")
    try:
        for n in sorted(os.listdir(macos)):
            p = os.path.join(macos, n)
            if os.path.isfile(p) and os.access(p, os.X_OK):
                return p
    except Exception:
        pass
    return ""


def _mdfind_apps():
    """用 LaunchServices 反查：这台机器上到底装了哪些浏览器。

    硬编码路径只能覆盖「装在 /Applications 且没改名」的情况。
    mdfind 是问系统索引，用户装在哪、叫什么名字都问得出来。
    索引可能被关掉（部分机器 mdworker 被禁用），所以它只是**补充**，
    失败了静默跳过 —— 绝不因为一个可选优化把主流程拖慢。
    """
    ids = [b for b, _ in _MAC_BROWSERS] + [
        "com.google.Chrome.helper",        # 有的版本只索引到 helper
    ]
    cond = " || ".join("kMDItemCFBundleIdentifier == '%s'" % i for i in ids)
    try:
        out = subprocess.run(["/usr/bin/mdfind", cond],
                             stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
                             timeout=6, text=True).stdout
    except Exception:
        return []
    found = []
    for line in out.splitlines():
        p = line.strip()
        if p.endswith(".app") and os.path.isdir(p):
            found.append(p)
    return found


def _system_app_candidates():
    """系统里已安装的浏览器可执行文件，按「越可能被用户用着越靠前」排。"""
    out = []
    if sys.platform != "darwin":
        return out
    seen = set()

    def take(app_path):
        if not app_path or app_path in seen:
            return
        seen.add(app_path)
        exe = _exe_of_app(app_path)
        if exe:
            out.append(exe)

    for app in _mdfind_apps():
        take(app)
    for d in _APP_DIRS:
        for _, name in _MAC_BROWSERS:
            take(os.path.join(d, name))
    return out


def candidates():
    """候选可执行文件，越省事越靠前。"""
    out = []
    env = (os.environ.get("MBBOARD_CHROME") or "").strip()
    if env:
        out.append(os.path.expanduser(env))
    out += DOWNLOADED.get(sys.platform, [])
    out += _system_app_candidates()
    out += _OTHER.get(sys.platform, [])
    return out


def find(force=False):
    """找到就返回路径，找不到返回 ""。

    带 20 秒缓存：抓取链路上每个请求都可能问一次，而 mdfind 要起进程。
    但**下载完成后必须能立刻看到**，所以缓存只缓存「找到的结果」，
    并且 `prepare_async()` 成功后主动失效缓存。
    """
    with _LOCK:
        if (not force and _FIND_CACHE["path"]
                and time.time() - _FIND_CACHE["at"] < _FIND_CACHE["ttl"]):
            return _FIND_CACHE["path"]
    for p in candidates():
        if p and os.path.exists(p):
            with _LOCK:
                _FIND_CACHE.update({"path": p, "at": time.time()})
            return p
    with _LOCK:
        _FIND_CACHE["path"] = ""
    return ""


def app_bundle():
    """找到的那个浏览器的 .app 路径（macOS 的 `open -g -a` 要的是 App，不是二进制）。

    找不到就返回 ""。调用方不要回退到硬编码的「Chrome for Testing」路径 ——
    那正是「用户明明装了浏览器，却说找不到」的来源。
    """
    p = find()
    if not p:
        return ""
    # .../Foo.app/Contents/MacOS/Foo → .../Foo.app
    parts = p.split(os.sep)
    for i in range(len(parts) - 1, -1, -1):
        if parts[i].endswith(".app"):
            return os.sep.join(parts[:i + 1])
    return ""


def ready():
    return bool(find())


def describe():
    """给界面/日志用的一句话。"""
    p = find()
    if not p:
        return ""
    app = app_bundle()
    if app:
        return os.path.basename(app)
    return os.path.basename(p)


# ==========================================================================
# 二、兜底准备：一个都没有就自己下一份
# ==========================================================================
# 为什么保留这条路：macOS 上确实存在「一台浏览器都没装」的机器
#（作者这台开发机就是这样：全盘 mdfind 扫不到任何 Chromium）。
# 但它是**最后一条路**，不是第一条 —— 能复用用户已经装好的就别让他等下载。
CHROME_JSON = os.environ.get(
    "MBBOARD_CHROME_JSON",
    "https://googlechromelabs.github.io/chrome-for-testing/"
    "last-known-good-versions-with-downloads.json")
CHROME_JSON_MIRRORS = []

# ★ 实测更正（这一条很关键）★
#   原来这里写的是：
#     https://registry.npmmirror.com/-/binary/chrome-for-testing/
#     last-known-good-versions-with-downloads.json
#   而它 **404** —— npmmirror 只镜像了「按版本分目录」的二进制，没有官方那份
#   汇总 JSON。于是「官方拿不到就换镜像」这条路其实是死的：
#   googlechromelabs.github.io 是 GitHub Pages，国内经常连不上，
#   一旦连不上就判定「拿不到版本清单」→ 浏览器永远准备不出来 →
#   四条登录链路全废。而兜底下载本来就只在「用户机器上一个 Chromium 都没有」
#   时才会用到，那正是最需要它可靠的时候。
#
#   现在的三级兜底：
#     ① 官方 JSON（带完整下载地址）
#     ② npmmirror 的**目录列表**（这个接口本身返回 JSON，2500+ 个版本目录）
#        —— 自己挑一个正式版、自己拼下载地址
#     ③ ①②都拿不到时，用一个写死的已知可用版本号拼镜像地址
MIRROR_BASE = "https://registry.npmmirror.com/-/binary/chrome-for-testing/"
MIRROR_LIST = MIRROR_BASE
# 2026-09 在镜像上实测存在（154.0.8037.57，HEAD 返回 200 / 182MB）
CHROME_FALLBACK_VERSION = "154.0.8037.57"

_VER_RE = re.compile(r"^\d+\.\d+\.\d+\.\d+$")


def _vkey(v):
    try:
        return tuple(int(x) for x in v.split("."))
    except Exception:
        return (0,)


def _mirror_pick_version():
    """从 npmmirror 的目录列表里挑一个能用的正式版号。

    列表里 Stable / Beta / Dev / Canary 混在一起。四段版本号里**最后一段为 0**
    是 Dev / Canary 的特征（如 156.0.8075.0）；正式版最后一段都不为 0
    （如 154.0.8037.57）。取「最后一段不为 0 的最大版本」—— 不保证恰好是
    最新的 Stable，但一定是一个能用的正式 Chromium，对 CDP 来说完全等价。
    """
    try:
        with _open_url(MIRROR_LIST, timeout=25) as r:
            items = json.loads(r.read().decode("utf-8", "replace"))
    except Exception:
        return ""
    best = ""
    for it in items or []:
        if not isinstance(it, dict) or it.get("type") != "dir":
            continue
        n = (it.get("name") or "").rstrip("/")
        if not _VER_RE.match(n) or n.split(".")[3] == "0":
            continue
        if _vkey(n) > _vkey(best):
            best = n
    return best


def _download_urls(tag):
    """按优先级给出下载地址候选。返回 (地址列表, 版本说明)。"""
    version, official = "", ""
    # ① 官方 JSON
    for url in [CHROME_JSON] + CHROME_JSON_MIRRORS:
        try:
            with _open_url(url, timeout=20) as r:
                d = json.loads(r.read().decode("utf-8", "replace"))
            st = (d.get("channels") or {}).get("Stable") or {}
            version = st.get("version") or ""
            items = ((st.get("downloads") or {}).get("chrome")) or []
            official = next((i.get("url") for i in items
                             if i.get("platform") == tag), "") or ""
            if version:
                break
        except Exception:
            continue

    # ② / ③ 镜像
    note = ""
    if not version:
        version = _mirror_pick_version()
        note = "（用镜像的版本目录）" if version else "（用内置的兜底版本）"
    if not version:
        version = CHROME_FALLBACK_VERSION

    # ★ 镜像排在官方前面 ★
    #   npmmirror 的 binary 镜像目录布局和官方一致，实测国内是唯一稳定的路径，
    #   而官方 storage.googleapis.com 在国内经常直接连不上（连不上时 urllib 会
    #   一路卡到超时，用户看到的就是「一直卡在准备浏览器」）。
    urls = ["%s%s/%s/chrome-%s.zip" % (MIRROR_BASE, version, tag, tag)]
    if official:
        urls.append(official)
    return urls, version + note


STATE = {"busy": False, "error": "", "msg": "", "done": False, "started": 0.0}
STATE_LOCK = threading.Lock()


def _platform_tag():
    if sys.platform == "darwin":
        return "mac-arm64" if platform.machine() in ("arm64", "aarch64") else "mac-x64"
    if sys.platform == "win32":
        return "win64" if sys.maxsize > 2 ** 32 else "win32"
    return "linux64"


def _open_url(url, timeout=30):
    """直连优先，失败再走系统代理。

    为什么直连优先：不少机器上配着一个根本没在跑的代理（或者只对特定域名
    生效），urllib 默认会闷头去撞它，一路卡满超时 —— 看起来就像「下载死了」。
    """
    req = urllib.request.Request(url, headers={"User-Agent": "mbboard/1.0"})
    last = None
    for opener in (urllib.request.build_opener(urllib.request.ProxyHandler({})),
                   urllib.request.build_opener()):
        try:
            return opener.open(req, timeout=timeout)
        except Exception as e:
            last = e
    raise last


def _fetch(url, dest, timeout=900):
    with _open_url(url, timeout=timeout) as r, open(dest, "wb") as f:
        while True:
            chunk = r.read(262144)
            if not chunk:
                break
            f.write(chunk)


def _meta():
    """兼容旧调用：只要版本清单。拿不到就抛。"""
    last = None
    for url in [CHROME_JSON] + CHROME_JSON_MIRRORS:
        try:
            with _open_url(url, timeout=20) as r:
                return json.loads(r.read().decode("utf-8", "replace")), url
        except Exception as e:
            last = e
    # 官方不通就退回镜像自拼一个「准清单」，形状和官方一致，调用方不用改
    v = _mirror_pick_version() or CHROME_FALLBACK_VERSION
    tag = _platform_tag()
    return {"channels": {"Stable": {
        "version": v,
        "downloads": {"chrome": [{
            "platform": tag,
            "url": "%s%s/%s/chrome-%s.zip" % (MIRROR_BASE, v, tag, tag)}]}}}}, MIRROR_BASE


def install():
    """下载 Chrome for Testing 到 <数据目录>/chrome，返回 (ok, 说明)。

    下载地址有多条候选（镜像优先，见 _download_urls），逐个试 ——
    只试第一条的话，一旦那条恰好不通就整件事失败了，而用户看到的是
    「一直卡在准备浏览器」。
    """
    tag = _platform_tag()
    try:
        urls, ver = _download_urls(tag)
        if not urls:
            return False, "拿不到 %s 的下载地址" % tag

        os.makedirs(CHROME_DIR, exist_ok=True)
        zpath = os.path.join(CHROME_DIR, "chrome-for-testing.zip")
        errs = []
        for url in urls:
            try:
                _fetch(url, zpath)
                if os.path.getsize(zpath) < 1024:
                    raise IOError("下载到的文件太小，多半不是安装包")
                break
            except Exception as e:
                errs.append("%s → %s: %s" % (url.split("/")[2], type(e).__name__, e))
                try:
                    os.remove(zpath)
                except Exception:
                    pass
        else:
            return False, "下载失败（%s）" % ("；".join(errs)[:300])

        with zipfile.ZipFile(zpath) as z:
            z.extractall(CHROME_DIR)
        try:
            os.remove(zpath)
        except Exception:
            pass

        # zip 里多一层 chrome-<tag>/，挪平到 chrome/ 下
        inner = os.path.join(CHROME_DIR, "chrome-" + tag)
        if os.path.isdir(inner):
            for item in os.listdir(inner):
                src, dst = os.path.join(inner, item), os.path.join(CHROME_DIR, item)
                if not os.path.exists(dst):
                    shutil.move(src, dst)
            shutil.rmtree(inner, ignore_errors=True)

        # 可执行位 + 摘 quarantine（只动我们下的这份，用户自己的浏览器不碰）
        for item in os.listdir(CHROME_DIR):
            p = os.path.join(CHROME_DIR, item)
            if item.endswith(".app"):
                p = _exe_of_app(p) or p
            try:
                if os.path.isfile(p):
                    os.chmod(p, 0o755)
            except Exception:
                pass
        if sys.platform == "darwin":
            for item in os.listdir(CHROME_DIR):
                if item.endswith(".app"):
                    subprocess.run(["/usr/bin/xattr", "-dr", "com.apple.quarantine",
                                    os.path.join(CHROME_DIR, item)],
                                   stdout=subprocess.DEVNULL,
                                   stderr=subprocess.DEVNULL)
        with _LOCK:
            _FIND_CACHE["path"] = ""       # 让下一次 find() 重新扫
        if not find(force=True):
            return False, "解压完了却没找到可执行文件"
        return True, find()
    except Exception as e:
        return False, "%s: %s" % (type(e).__name__, e)


def prepare_async():
    """一个都没有就在后台拉一份。已经在拉就不重复拉。绝不阻塞调用方。"""
    if ready():
        return False
    with STATE_LOCK:
        if STATE["busy"]:
            return False
        STATE.update({"busy": True, "started": time.time(), "error": ""})

    def work():
        print("本机没有 Chromium 内核浏览器，开始下载 Chrome for Testing"
              "（约 150MB）…", flush=True)
        ok, msg = install()
        with STATE_LOCK:
            STATE.update({"busy": False, "done": ok, "msg": msg,
                          "error": "" if ok else msg})
        print("Chrome for Testing %s：%s" % ("就绪" if ok else "下载失败", msg),
              flush=True)

    threading.Thread(target=work, daemon=True).start()
    return True


def state():
    """给 /api/health 和界面看的一句话状态。"""
    p = find()
    if p:
        app = app_bundle()
        return {"ok": True, "path": p, "app": app, "busy": False, "error": "",
                "source": "downloaded" if CHROME_DIR in p else "system",
                "name": os.path.basename(app) if app else os.path.basename(p),
                "fix": ""}
    with STATE_LOCK:
        busy, err = STATE["busy"], STATE["error"]
        started = STATE["started"]
    if busy:
        el = int(max(0, time.time() - started))
        return {"ok": False, "path": "", "app": "", "busy": True, "error": "",
                "elapsed": el,
                "fix": "正在自动准备浏览器（首次约 150MB），已用 %d 秒，装好就能抓取" % el}
    if err:
        return {"ok": False, "path": "", "app": "", "busy": False, "error": err,
                "fix": "自动下载失败（%s）。也可以自己装一个 Chrome / Edge / "
                       "Brave 任意一款，装完点「重新校验」即可。" % err}
    return {"ok": False, "path": "", "app": "", "busy": False, "error": "",
            "fix": "本机还没装 Chromium 内核的浏览器。点「重新校验」会自动准备一份，"
                   "或者自己装 Chrome / Edge / Brave 任意一款。"}


if __name__ == "__main__":
    print("数据目录 :", DATA_DIR)
    print("已找到   :", find(force=True) or "(无)")
    print("来源     :", (app_bundle() or "(无)"))
    print("候选清单 :")
    for c in candidates():
        print("   %s  %s" % ("✔" if os.path.exists(c) else "·", c))
