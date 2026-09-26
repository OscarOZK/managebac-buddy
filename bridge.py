#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
ManageBac-Buddy —— 本机桥接服务
- 提供 REST 接口，供桌面上的 HTML 应用、菜单栏 App、**手表 App（WiFi 直连）**调用
- 真实数据通过无界面 Chrome（agent-browser）在同一会话内并行 fetch 获取
- 账号密码在 /api/login 一次性使用，不落盘、不写日志。
  例外：请求里显式带 save=true（看板上的「自动重登」勾选框）时，账号写到
  本机 credentials.json（0600）、密码写进 macOS 钥匙串（service=mbboard-managebac），
  用于掉登录后自动重登。不勾选就什么都不存；POST /api/forget-creds 可随时删除。

监听地址：
  默认 0.0.0.0（局域网可达）—— 手表只连 WiFi 时靠这个直连本机。
  桌面看板走 127.0.0.1，完全不受影响。
  只给本机用（不要手表）：MBBOARD_HOST=127.0.0.1 python3 bridge.py

安全边界（默认就有，不需要配置）：
  ① 无副作用的读接口（/api/ping /api/snapshot /api/data）对局域网开放 —— 手表要用；
  ② 有副作用的接口（登录 / 退出 / 打开课表 / 列网络地址）**只允许本机**访问，
     局域网来的请求一律 403。想在别处也用，设 MBBOARD_TOKEN=随机串 并带上 X-MB-Token。

手表端为什么快：
  /api/ping      —— 锁外、毫秒级，用来探测「哪台机器上的服务活着」；
  /api/snapshot  —— 锁外、毫秒级，直接吐当前内存缓存（正在抓数据也不会被卡住）；
  /api/refresh   —— 锁外，踢一脚后台抓取就返回，绝不阻塞请求线程。
  （原 /api/data 会 with LOCK 排队，抓取一次要 2 分钟，手表 25 秒超时必然失败）
"""
import gzip
import hashlib
import http.server
from datetime import datetime
from concurrent.futures import ThreadPoolExecutor
import json
import os
import platform
import re
import shutil
import socket
import socketserver
import subprocess
import sys
import threading
import time
import urllib.parse
import urllib.request
import zipfile

HERE = os.path.dirname(os.path.abspath(__file__))
PORT = int(os.environ.get("MBBOARD_PORT", "8765"))
HOST = os.environ.get("MBBOARD_HOST", "0.0.0.0")     # 0.0.0.0 = 局域网可达（手表要）
TOKEN = os.environ.get("MBBOARD_TOKEN", "").strip()  # 留空 = 不校验（有副作用的接口仍限本机）
VERSION = 5                                          # 接口版本：手表端靠它判断对面是新版服务
#   v5 新增：**代码与数据分家**（MBBOARD_DATA）。
#            以前代码和「我的登录态」都堆在同一个目录里，既没法干净地分发，
#            也容易顺手把个人数据打包出去。现在：
#              HERE     = 后端代码（开发机 = ~/.mbboard；分发版 = App 包内 / 安装后的副本）
#              MBB_DATA = 这个用户自己的数据（登录态、缓存、浏览器 profile…）
#            外部工具（agent-browser / Chrome for Testing）也从「写死某个人的路径」
#            改成候选清单 + 可安装，换台机器不再一上来就哑。
#   v4 新增：登录态与数据分离（SESSION / sessionExpired / hasCreds）、
#            可选的本机凭据自动重登、快照指纹纳入登录态
#   v3 新增（手表 V2 会用到，老客户端完全不受影响）：
#     · /api/snapshot 支持 ETag / If-None-Match → 数据没变只回 304，17 KB 正文不过网
#     · 所有 JSON 响应按需 gzip（请求头带 Accept-Encoding: gzip 时）—— 手表与浏览器都会自动解压
# ---------- 代码在哪 / 数据放哪 ----------
# 开发机上 HERE 就是 ~/.mbboard（源码与数据同处一室）；
# 分发版由看板 App 设 MBBOARD_DATA 指向 ~/Library/Application Support 下的用户目录。
MBB_DATA = os.path.abspath(os.path.expanduser(os.environ.get("MBBOARD_DATA") or HERE))
try:
    os.makedirs(MBB_DATA, exist_ok=True)
except Exception:
    pass

# 共享模块目录（teams / seiue / browserfind…）。放在这么靠前的位置，
# 是因为下面「找浏览器」那一段就要 import browserfind —— 原来这行在
# 1200 行开外，早于此处的 import 会直接 ModuleNotFoundError。
SHARED_DIR = os.path.join(HERE, "board", "shared")
if os.path.isdir(SHARED_DIR) and SHARED_DIR not in sys.path:
    sys.path.insert(0, SHARED_DIR)

SESSION_NAME = "mbboard"


def _find_agent_browser():
    """找 agent-browser。绝不写死某个人的家目录 —— 换台机器就找不到。"""
    cands = [os.environ.get("MBBOARD_AB", ""),
             os.path.join(HERE, "bin", "agent-browser"),
             os.path.join(MBB_DATA, "bin", "agent-browser"),
             os.path.expanduser("~/.npm-global/bin/agent-browser"),
             os.path.expanduser("~/.local/bin/agent-browser"),
             "/opt/homebrew/bin/agent-browser",
             "/usr/local/bin/agent-browser"]
    for d in (os.environ.get("PATH") or "").split(os.pathsep):
        if d:
            cands.append(os.path.join(d, "agent-browser"))
    for p in cands:
        if p and os.path.exists(p):
            return p
    return os.path.expanduser("~/.npm-global/bin/agent-browser")   # 兜底：报错里能看见它


AB = _find_agent_browser()


# ---------- 浏览器：统一交给 board/shared/browserfind.py ----------
# 以前这里有一份「宽查找」（扫 /Applications 下的 Chrome/Edge/Brave/Chromium），
# 而 Teams（mssession.py）和希悦（seiue.py）各自另有一份「窄查找」——
# 只认数据目录里我们下载的那一份。两份逻辑不共享，于是出现了最离谱的现场：
#
#     「检查组件」说浏览器就绪（宽查找找到了系统里装好的 Edge），
#     点进去连 Teams / 希悦却报「找不到 Chrome for Testing」（窄查找没找到）。
#
# 而真正的问题在门槛本身：agent-browser 与 CDP 只要一个 **Chromium 内核的
# 可执行文件**，Chrome / Edge / Brave / Arc / Chromium 都能用。用户装过其中
# 任何一个就够，不该再逼他等 150MB 下载（国内还多半下不动）。
# 现在三处共用同一个实现，顺序是：
#     ① 数据目录里我们下过的那一份 → ② 系统里已装的任意 Chromium → ③ 兜底下载。
try:
    import browserfind as _bf
except Exception:                                        # pragma: no cover
    _bf = None


# ---------- 内置网页引擎：浏览器就在 App 身体里，不用任何人装 ----------
# 这一段是「四个账号只有 DeepSeek 登得进去」的**根治**办法。
#
# 原来的死结：ManageBac / Teams / 希悦 都要一个真浏览器，而
#   ① 别人电脑上多半没有 Chromium；
#   ② 我们自动下一份要等 150MB，国内还常常只有镜像通得了。
# 而 macOS 自带 WebKit（Safari 的内核）—— 一个字节都不用下。
#
# 所以 App 自己挂了一个 WKWebView，Python 这边通过这条通道指挥它：
#     Swift  GET  /api/webengine/poll     领活
#     Python 把指令塞进 webengine._QUEUE
#     Swift  POST /api/webengine/result   交答案
# 引擎在线时，下面所有「找浏览器 / 下浏览器」的代码都走不到；
# 不在线（Windows 版、或单独把 bridge.py 拎出来跑）就原样回退到
# agent-browser + Chromium，行为一个字都没变。
try:
    import webengine as we
except Exception:                                        # pragma: no cover
    we = None

if we is not None:
    # ★ 告诉 webengine「你现在跑在 bridge 这个进程里」★
    #   之后它的命令行形态就会直接在内存队列上执行，不再 fork 子进程、
    #   不再经 HTTP 回到自己 —— 详见 board/shared/webengine.py 的 run_cli。
    try:
        we.INPROC = True
    except Exception:                                    # pragma: no cover
        pass


def engine_ready():
    """App 里的内置引擎在不在、能不能干活。"""
    try:
        return bool(we and we.ready())
    except Exception:
        return False


def engine_online():
    """只问「有没有人在轮询」，不真发指令 —— 给界面状态用，毫秒级。"""
    try:
        return bool(we and we.attached())
    except Exception:
        return False


def engine_label():
    if not engine_online():
        return ""
    try:
        v = we.state() or {}
    except Exception:
        v = {}
    return "App 内置浏览器（WebKit，无需安装）"


def _chrome_candidates():
    """兼容旧调用：候选可执行文件清单（越省事越靠前）。"""
    return _bf.candidates() if _bf else []


def chrome_path():
    """现找一遍。**找不到就返回 ""**，不再回退到一个并不存在的硬编码路径 ——
    那正是「用户明明装了浏览器，却被告知找不到」的来源。"""
    return _bf.find() if _bf else ""


def chrome_name():
    """给界面/日志看的一句话：找到的是哪一款浏览器。"""
    return _bf.describe() if _bf else ""


CHROME = ""      # 兼容旧的打印；真值请用 chrome_path()（浏览器可能中途才装好）

# ---------- Chrome for Testing：**兜底方案**，不是唯一方案 ----------
# 顺序见上：先用用户已经装好的浏览器，一个 Chromium 都没有才下这一份。
# 保留它的理由很实在：macOS 上确实存在「一台浏览器都没装」的机器
#（作者这台开发机全盘扫过，除我们自己下的那份之外一个都没有）。
# 另外国内直连 Google 的 CDN 常不通，所以 browserfind 里带了镜像回退。
def chrome_ready():
    """有没有可用的浏览器。

    ★ 内置引擎优先 ★ 引擎在线时这个问题根本不该问外部浏览器 ——
    用户机器上一个 Chromium 都没有也完全没关系。
    """
    if engine_online():
        return True
    return bool(_bf and _bf.ready())


def _install_chrome():
    """下 Chrome for Testing 到 <数据目录>/chrome，返回 (ok, 说明)。"""
    if _bf is None:
        return False, "浏览器查找模块没加载起来"
    return _bf.install()


def ensure_chrome_async():
    """一个可用浏览器都没有就在后台拉一份；已经在拉就不重复拉。

    这是**兜底**：绝大多数机器上系统里已经装着 Chrome / Edge / Brave，
    browserfind 直接就能找到，根本走不到这里。
    """
    if _bf is None:
        return False
    return _bf.prepare_async()


def chrome_state():
    """给 /api/health 和界面看的一句话状态。"""
    # 内置引擎在线：外部浏览器这件事整个不存在了，直接报「已就绪」。
    # 不报的话界面会把用户引去「装一个 Chrome / 等 150MB 下载」—— 全是白费。
    if engine_online():
        return {"ok": True, "path": "app://webengine", "app": "", "busy": False,
                "error": "", "engine": True, "source": "engine",
                "name": "App 内置浏览器（WebKit）", "fix": ""}
    if _bf is None:
        return {"ok": False, "path": "", "app": "", "busy": False, "error": "",
                "engine": False, "source": "none",
                "fix": "浏览器查找模块没加载起来（board/shared/browserfind.py 缺失？）"}
    # ★ 一律补上 engine / source 两个键 ★
    #   browserfind.state() 里没有这两个字段，界面读到的是 undefined ——
    #   「引擎在不在」这件事在引擎离线时必须得到一个**明确的 false**，
    #   而不是「这个键不存在」。差一点点就会写成「关掉引擎那条分支的判断
    #   一直不成立」，表现是状态栏一会儿显示内置浏览器、一会儿又让用户去装 Chrome。
    d = dict(_bf.state() or {})
    d.setdefault("engine", False)
    d.setdefault("source", "external")
    return d


def ensure_browser_ready():
    """三条登录入口统一调这个：**保证有一个浏览器可用**，没有就后台准备。

    以前只有 ManageBac 那条路会触发下载 —— 用户要是跳过了 ManageBac 直接
    去连 Teams，就必然撞上「找不到 Chrome for Testing」，而且屏幕上没有任何
    正在准备的提示。现在 Teams / 希悦 / ManageBac 都从同一个门进来。
    返回 (是否已就绪, 给用户看的一句话)。
    """
    if engine_online():
        return True, ""
    if chrome_ready():
        return True, ""
    ensure_chrome_async()
    st = chrome_state()
    return False, (st.get("fix") or "正在自动准备浏览器（首次约 150MB）…")


SCRAPE_JS = os.path.join(HERE, "scrape.js")          # 老残留，保留只为兼容
SESSION_FILE = os.path.join(MBB_DATA, "session.json")   # 登录 Cookie 持久化（仅本机、0600 权限）
RESTORED = {"done": False}

# ---- 可选的「自动重登」凭据 ----
# Cookie 会过期、浏览器 temp profile 会被系统清掉，掉登录本身是必然事件。
# 只靠 Cookie 的话每次掉线都得人来点一下；这里把账号留在本机文件、密码交给
# macOS 钥匙串（只有本用户读得到），掉登录时自动重登一次。
# 只有看板上勾了「自动重登」才会写；POST /api/forget-creds 可随时清掉。
CREDS_FILE = os.path.join(MBB_DATA, "credentials.json")   # 只存登录名，密码在钥匙串
KEYCHAIN_SERVICE = "mbboard-managebac"
AUTO_LOGIN_MIN_GAP = 900.0    # 自动重登最短间隔（秒）：失败了也别拿密码去撞服务器
# 看板本体：优先读服务目录内的副本（macOS 不允许本进程访问「桌面」，读桌面会报 Operation not permitted）
APP_HTML = os.path.join(HERE, "app.html")
APP_HTML_FALLBACK = os.path.expanduser("~/Desktop/ManageBac看板.html")

# ---------- 学校 ManageBac 地址（可在「设置 → 账号管理」里改） ----------
# 默认值就是本校的地址，同学拿到就能直接用；换学校的人改一处即可。
# 读取优先级：环境变量 MBBOARD_SCHOOL > settings.json 的 schoolURL > 默认值。
DEFAULT_SCHOOL = "https://beijing101.managebac.cn"


def _norm_url(v):
    v = (v or "").strip().rstrip("/")
    if not v:
        return ""
    if not v.startswith(("http://", "https://")):
        v = "https://" + v
    return v


def school_base():
    env = _norm_url(os.environ.get("MBBOARD_SCHOOL", ""))
    if env:
        return env
    try:
        with open(os.path.join(MBB_DATA, "settings.json"), encoding="utf-8") as f:
            v = _norm_url((json.load(f) or {}).get("schoolURL") or "")
        if v:
            return v
    except Exception:
        pass
    return DEFAULT_SCHOOL


def school_host():
    try:
        return urllib.parse.urlparse(school_base()).hostname or "managebac.cn"
    except Exception:
        return "managebac.cn"


def login_url():
    return school_base() + "/login"


def home_url():
    return school_base() + "/student/tasks_and_deadlines"

LOCK = threading.RLock()              # 可重入：处理器和后台线程可能嵌套获取（串行化浏览器操作）
CACHE = {"data": None, "ts": 0.0}
CACHE_TTL = 60.0                      # 每次抓取的间隔（秒）
CACHE_FILE = os.path.join(MBB_DATA, "cache.json")   # 磁盘缓存：服务重启后也能秒回上次数据
REFRESHING = {"on": False, "started_at": 0.0, "gen": 0, "stuck": 0}

# ---------- Teams 板块（Microsoft Graph）----------
# 刻意与 ManageBac 抓取完全解耦：这条路出任何问题，都不该影响主看板。
TEAMS = {"data": None, "ts": 0.0, "fetching": False, "loggingIn": False,
         "error": None, "loginMsg": "", "loginStep": 0,
         # 最后一次**拿到内容**的结果。抓取失败时绝不拿空数据覆盖它，
         # 界面于是一直有东西可看，而不是动不动一片空白。
         "good": None, "goodTs": 0.0, "fails": 0, "stale": False}
TEAMS_TTL = 120.0          # 两分钟一抓：用户在界面上看得到「更新于」，别让数据看着像旧的
TEAMS_MAX_BACKOFF = 8      # 连续失败后刷新间隔最多放宽到 8 倍（16 分钟），别把网络打死
TEAMS_CACHE = os.path.join(MBB_DATA, "teams_cache.json")   # 落盘：bridge 重启后立刻有内容
SHARED_DIR = os.path.join(HERE, "board", "shared")
if os.path.isdir(SHARED_DIR) and SHARED_DIR not in sys.path:
    sys.path.insert(0, SHARED_DIR)
# 最近一次抓取的结果（成功/失败 + 为什么），手表与自检脚本都靠它说清
# 「数据为什么不动」——以前失败了是完全静默的，只能在服务端看日志。
LAST_FETCH = {"at": 0.0, "ok": None, "reason": "", "detail": "", "loggedOut": False}

# 登录态是「会话级」的事实，必须和「数据」分开记。
# 以前只有一个 CACHE，而缓存里的 loggedIn 是抓取那一刻的旧值，于是看板拿着
# 7 小时前的缓存理直气壮地说「已连接 ManageBac」——手表说掉登录、电脑说没事，
# 用户只能看着两个界面互相打脸。现在 SESSION 由每次真实抓取刷新，谁都骗不了谁。
SESSION = {
    "dead": False,      # 当前是否已确认掉登录
    "since": 0.0,       # 从什么时候开始掉的
    "lastOk": 0.0,      # 最近一次确认「还登着」的时刻
    "lastCheck": 0.0,   # 最近一次真实校验登录的时刻
    "autoTried": 0.0,   # 最近一次尝试自动重登的时刻（限流用）
    "autoNote": "",     # 自动重登的结果说明（给人看的）
}

# 掉登录这件事要能挺过重启。
# 否则每次重启服务，SESSION 归零 → 看板又理直气壮地说「已连接」，
# 直到下一次抓取（几十秒）才改口 —— 用户恰好在那几十秒打开页面，就又看到一次打架。
SESSION_STATE_FILE = os.path.join(MBB_DATA, "session_state.json")


def _session_save():
    try:
        with open(SESSION_STATE_FILE, "w", encoding="utf-8") as f:
            json.dump({k: SESSION[k] for k in ("dead", "since", "lastOk", "lastCheck", "autoNote")},
                      f, ensure_ascii=False)
    except Exception:
        pass


def _session_load():
    try:
        with open(SESSION_STATE_FILE, encoding="utf-8") as f:
            d = json.load(f) or {}
        for k in ("dead", "since", "lastOk", "lastCheck", "autoNote"):
            if k in d:
                SESSION[k] = d[k]
        if SESSION["dead"]:
            print("承接上次状态：登录仍处于失效（%s 起）。" % time.strftime(
                "%m-%d %H:%M", time.localtime(SESSION["since"] or time.time())), flush=True)
    except Exception:
        pass


_session_load()

STUCK_AFTER = 300.0   # 一次抓取超过这么久没结束就判为卡住（见 refresh_watchdog）
STUCK_HARD = 2        # 连续卡住这么多次就自动重置浏览器会话（自愈）
LOGOUT_BACKOFF = 600.0  # 登录失效期间，最短这么久才允许再试一次（见 request_refresh）
# 课表 PDF。
# ⚠️ 直接把「桌面」里的文件交给预览会被系统拒绝：预览是本服务拉起的，会继承本服务
# 「没有桌面访问权限」的身份，于是弹「你没有查看它的权限」。所以预览打开的是服务目录
# 内的镜像副本（~/.mbboard 不在 TCC 保护范围内）；有桌面权限时顺手把镜像刷新成最新。
SCHEDULE_SRC = os.path.expanduser("~/Desktop/课表-新版.pdf")
SCHEDULE_NAME = "课表-新版.pdf"
SCHEDULE_STAGE = os.path.join(MBB_DATA, "source", SCHEDULE_NAME)   # 启动器从桌面同步来的中转副本
SCHEDULE_DIR = os.path.join(MBB_DATA, "preview")
SCHEDULE_PNG = os.path.join(SCHEDULE_DIR, "课表-新版.png")     # 给「预览」看的图片（窗口贴合内容，中号）
SCHEDULE_PDF = os.path.join(SCHEDULE_DIR, SCHEDULE_NAME)       # 网页兜底用的 PDF（92% 缩放）
SCHEDULE_META = os.path.join(SCHEDULE_DIR, ".source-meta")     # 源指纹：源变了才重新生成
SCHEDULE_PDF_OLD = os.path.join(MBB_DATA, "schedule.pdf")      # 更早的镜像名，兼容
SCHEDULE_SCALE = 0.92       # PDF 兜底镜像的缩放（网页里整页可见）
# 清晰度：预览是按「点尺寸」开窗口的（点 = 像素 / dpi × 72）。
# 所以 1720px @144dpi = 860 点 → 窗口仍是中号 860x712，但像素密度是 2 倍，
# 在 Retina 屏上正好 1:1 显示（原来 860px@72dpi 等于被放大 2 倍 → 发虚）。
SCHEDULE_PNG_W = 1720       # 像素宽（2×）
SCHEDULE_PNG_DPI = 144      # 像素翻倍的同时把 dpi 也翻倍，窗口尺寸才保持不变
SCHEDULE_HELPER = os.path.join(HERE, "pdfscale")               # 零依赖小工具（系统 CoreGraphics）

def _schedule_sig():
    """源文件指纹（mtime+大小）。服务读不到「桌面」，所以用启动器同步过来的中转副本。"""
    for p in (SCHEDULE_STAGE, SCHEDULE_SRC):
        try:
            st = os.stat(p)
            if st.st_size > 0:
                return "%x_%x" % (int(st.st_mtime), st.st_size)
        except Exception:
            continue
    return ""


def screen_size():
    """主屏逻辑尺寸（交给 pdfscale --screen 拿，无需权限）"""
    try:
        r = subprocess.run([SCHEDULE_HELPER, "--screen"], capture_output=True, text=True, timeout=10)
        w, h = r.stdout.strip().split("x")
        return int(w), int(h)
    except Exception:
        return 1470, 956


def size_preview_window(win_w=860, win_h=712):
    """尽力把「预览」窗口摆成中号并居中。

    尺寸与图片自带的窗口一致（1720px@144dpi = 860 点 → 860x712 含标题栏），
    这样有没有系统授权，看到的窗口都一样大。未授权时返回 False，不影响打开。
    """
    sw, sh = screen_size()
    x = max(0, int((sw - win_w) / 2))
    y = max(24, int((sh - win_h) / 2) - 40)
    script = (
        'tell application "Preview"\n'
        '  if (count of windows) > 0 then\n'
        '    set bounds of front window to {%d, %d, %d, %d}\n'
        '    return "ok"\n'
        '  end if\n'
        '  return "nowindow"\n'
        'end tell' % (x, y, x + win_w, y + win_h)
    )
    try:
        r = subprocess.run(["/usr/bin/osascript", "-e", script],
                           capture_output=True, text=True, timeout=10)
        return r.returncode == 0 and "ok" in (r.stdout or "")
    except Exception:
        return False


def schedule_mirrors():
    """已存在的 PDF 镜像（网页兜底用）"""
    out = []
    if os.path.exists(SCHEDULE_PDF):
        out.append(SCHEDULE_PDF)
    try:
        for name in sorted(os.listdir(SCHEDULE_DIR), reverse=True):
            p = os.path.join(SCHEDULE_DIR, name, SCHEDULE_NAME)
            if os.path.exists(p):
                out.append(p)
    except Exception:
        pass
    out.append(SCHEDULE_PDF_OLD)
    return out


def _schedule_source():
    """找一份能读到的课表源文件（优先中转副本，桌面那份服务通常读不到）"""
    for p in (SCHEDULE_STAGE, SCHEDULE_SRC):
        try:
            if os.path.getsize(p) > 0:
                return p
        except Exception:
            continue
    return None


def build_schedule_images():
    """按源文件生成两份镜像：给「预览」的图片 + 网页兜底的 PDF。源没变就不重做。"""
    sig = _schedule_sig()
    try:
        if (os.path.getsize(SCHEDULE_PNG) > 0 and os.path.getsize(SCHEDULE_PDF) > 0
                and open(SCHEDULE_META, encoding="utf-8").read().strip() == sig):
            return True
    except Exception:
        pass
    try:
        os.makedirs(SCHEDULE_DIR, exist_ok=True)
    except Exception:
        pass
    src = _schedule_source()
    if not src:
        return False
    ok_png = ok_pdf = False
    if os.path.exists(SCHEDULE_HELPER):
        try:
            r = subprocess.run([SCHEDULE_HELPER, "--png", src, SCHEDULE_PNG,
                                str(SCHEDULE_PNG_W), str(SCHEDULE_PNG_DPI)],
                               capture_output=True, text=True, timeout=30)
            ok_png = r.returncode == 0 and os.path.getsize(SCHEDULE_PNG) > 0
        except Exception:
            ok_png = False
        try:
            r = subprocess.run([SCHEDULE_HELPER, src, SCHEDULE_PDF, str(SCHEDULE_SCALE)],
                               capture_output=True, text=True, timeout=30)
            ok_pdf = r.returncode == 0 and os.path.getsize(SCHEDULE_PDF) > 0
        except Exception:
            ok_pdf = False
    if not ok_pdf:                      # 没工具就原样拷一份，至少网页端有东西看
        try:
            with open(src, "rb") as f, open(SCHEDULE_PDF, "wb") as w:
                w.write(f.read())
            ok_pdf = True
        except Exception:
            pass
    if ok_png and ok_pdf:
        try:
            with open(SCHEDULE_META, "w", encoding="utf-8") as f:
                f.write(sig)
        except Exception:
            pass
    return ok_png


def schedule_target():
    """返回交给「预览」打开的文件。

    用图片而不是 PDF：预览给 PDF 的默认窗口是它自己记的大尺寸（实测约屏幕宽的 88%），
    而给图片的窗口按「点尺寸」自动贴合（点 = 像素 / dpi × 72）。于是渲染成
    1720px @144dpi = 860 点，就能稳定拿到「中号窗口 860x712 + 整页可见」，
    同时像素是 2 倍，在 Retina 屏上 1:1 显示，不会像 1 倍图那样被放大而发虚。
    """
    if not build_schedule_images():
        return ""                        # 生成失败 → 调用方退回 PDF 镜像
    if os.path.exists(SCHEDULE_PNG):
        return SCHEDULE_PNG
    return ""


def load_cache():
    """启动时把上次抓到的数据读回来，让页面第一帧就有内容"""
    try:
        with open(CACHE_FILE, encoding="utf-8") as f:
            d = json.load(f)
        if isinstance(d, dict) and d.get("ok"):
            CACHE["data"] = d
            CACHE["ts"] = float(d.get("fetchedAt") or 0)
            print("已载入上次缓存（%d 条任务）。" % len(d.get("tasks") or []), flush=True)
    except Exception:
        pass
    # 顺手把历史上抓错的详情缓存清掉（登录页 / 停在别人页面上的那些）
    try:
        _taskcache_sweep()
    except Exception:
        pass


def save_cache(d):
    try:
        with open(CACHE_FILE, "w", encoding="utf-8") as f:
            json.dump(d, f, ensure_ascii=False)
    except Exception:
        pass


def start_background_refresh():
    """后台静默更新：页面先渲染旧数据，抓完再自动替换

    V2 补了「抓取卡住」的看门狗与失败原因上报。起因是一个真实故障：
    某一次抓取卡在浏览器里不出来，REFRESHING 永远是 True，于是之后每一次
    「踢一脚」都被判成「已经在抓了」，数据从此再也不更新 ——
    而服务本身看起来一切正常（接口都通、进程活着），极难排查。
    """
    if REFRESHING["on"]:
        return
    REFRESHING["on"] = True
    REFRESHING["started_at"] = time.time()
    REFRESHING["gen"] += 1
    my_gen = REFRESHING["gen"]

    def worker():
        try:
            d = _fetch_blocking()
            if isinstance(d, dict):
                LAST_FETCH.update({"at": time.time(), "ok": bool(d.get("ok")),
                                   "reason": d.get("reason") or "",
                                   "detail": (d.get("detail") or "")[:200],
                                   # 「浏览器跑通了、但拿回来是空的」几乎只有一个原因：
                                   # 电脑上的 ManageBac 登录失效了。单独标出来，
                                   # 手表就能直接说「去电脑上重新登录」，而不是含糊的「抓取成功」。
                                   "loggedOut": d.get("loggedIn") is False and not d.get("tasks")})
                if not d.get("ok"):
                    print("后台更新未成功：%s %s" % (LAST_FETCH["reason"] or "-",
                                                  LAST_FETCH["detail"] or ""), flush=True)
                else:
                    REFRESHING["stuck"] = 0      # 抓通了，卡住计数清零
        except Exception as e:  # noqa
            LAST_FETCH.update({"at": time.time(), "ok": False, "reason": "exception",
                               "detail": str(e)[:200]})
            print("后台更新失败：%s" % e, flush=True)
        finally:
            # 只有「还是我这一代」才清标志 —— 被看门狗判卡住后新起的那一轮，
            # 不能被这次迟到的收尾顺手关掉。
            if REFRESHING["gen"] == my_gen:
                REFRESHING["on"] = False
                REFRESHING["started_at"] = 0.0

    threading.Thread(target=worker, daemon=True).start()


def refresh_watchdog():
    """抓取超过 STUCK_AFTER 秒还没结束 → 判为卡住，放开下一次抓取。

    探活接口（ping）每次被调用都会顺手跑一遍，所以手表每 20 秒就在帮我们体检。
    连续卡住两次还会**自动重置浏览器会话** —— 卡住的根因通常是那个无头 Chrome
    已经僵了（比如停在登录页不动），光放开标志位没用，下一次还是会卡在那里。
    """
    if not REFRESHING["on"]:
        return
    t0 = REFRESHING["started_at"] or 0
    if t0 and (time.time() - t0) > STUCK_AFTER:
        print("⚠️ 上一次抓取已经 %.0f 秒没结束，判为卡住，放开下一次抓取。"
              % (time.time() - t0), flush=True)
        REFRESHING["on"] = False
        REFRESHING["started_at"] = 0.0
        REFRESHING["gen"] += 1
        REFRESHING["stuck"] += 1
        LAST_FETCH.update({"at": time.time(), "ok": False, "reason": "stuck",
                           "detail": "上一次抓取超时，已判为卡住", "loggedOut": False})
        if REFRESHING["stuck"] >= STUCK_HARD:
            REFRESHING["stuck"] = 0
            print("⚠️ 连续 %d 次抓取卡住 → 自动重置浏览器会话（下次会重建并恢复登录）"
                  % STUCK_HARD, flush=True)
            threading.Thread(target=_safe_reset_browser, daemon=True).start()


def _safe_reset_browser():
    """在后台线程里重置浏览器（看门狗用，绝不能因为重置失败把服务带崩）。"""
    try:
        reset_browser()
    except Exception as e:  # noqa
        print("重置浏览器失败：%s" % e, flush=True)


# ============================================================
#  手表端（WiFi 直连）要用的三个「锁外」接口
#
#  为什么要单开：/api/data 走 with LOCK，而抓一次数据（无界面 Chrome 开页面 +
#  注入脚本）会持锁 1~4 分钟。手表只要在抓取期间请求就会一直排队，
#  25 秒超时 → 界面上就是「连不上电脑上的看板服务」。
#  下面三个都不碰 LOCK，毫秒级返回，抓取一律丢给后台线程。
# ============================================================

def ping_payload():
    """极速探活：只读几个变量，不做任何 IO。手表用它并发竞速选地址。"""
    refresh_watchdog()          # 手表每 20 秒问一次，顺手体检「是不是卡住了」
    now = time.time()
    d = {"ok": True, "mb": VERSION, "service": "mbboard", "port": PORT,
         "host": socket.gethostname(), "hasData": bool(CACHE["data"]),
         "refreshing": bool(REFRESHING["on"]), "serverTime": round(now, 3)}
    if CACHE["data"]:
        d["age"] = round(max(0.0, now - CACHE["ts"]), 1)
        d["loggedInAtFetch"] = CACHE["data"].get("loggedIn")
    if REFRESHING["on"] and REFRESHING["started_at"]:
        d["refreshingFor"] = round(now - REFRESHING["started_at"], 1)
    if LAST_FETCH["at"]:
        d["lastFetch"] = {"ago": round(now - LAST_FETCH["at"], 1), "ok": LAST_FETCH["ok"],
                          "reason": LAST_FETCH["reason"], "detail": LAST_FETCH["detail"],
                          "loggedOut": bool(LAST_FETCH.get("loggedOut"))}
    d.update(_session_fields())
    if d.get("loggedIn") is None and CACHE["data"]:
        # 还没做过真实校验（刚重启，抓取还没回来）：只能先用旧值顶着，别谎称已知
        d["loggedIn"] = CACHE["data"].get("loggedIn")
    return d


def _session_fields():
    """登录态（会话级事实）—— 跟数据一起发给所有客户端。

    缓存里的 loggedIn 是「抓取那一刻」的旧值，拿它当现在的事实就会撒谎。
    这几个字段由每次真实抓取刷新，看板 / 手表 / 自检脚本共用同一套判断。
    """
    now = time.time()
    return {
        # loggedIn 的语义是「现在还能取到数据吗」，不是「这批旧数据当年是怎么抓来的」。
        # 缓存正文里那个 loggedIn 是抓取那一刻的旧值（可能是 7 小时前），
        # 客户端拿它当事实就会说「已连接 ManageBac」——那正是「电脑说没事、手表说掉线」
        # 的根源。这里统一覆盖成会话级事实；还没校验过就报 None（未知），别硬报 true。
        "loggedIn": (not SESSION["dead"]) if SESSION["lastCheck"] else None,
        "sessionExpired": bool(SESSION["dead"]),
        "sessionSince": round(now - SESSION["since"], 1) if SESSION["dead"] and SESSION["since"] else 0,
        "sessionNote": SESSION["autoNote"],
        "sessionCheckedAt": round(SESSION["lastCheck"], 3) if SESSION["lastCheck"] else 0,
        "hasCreds": has_credentials(),          # 存过凭据 → 掉登录能自动救回来
    }


def _status_fields(now):
    """快照 / 探活里那几个「服务端状态」字段（V2 新增了抓取失败原因）。"""
    d = {"serverTime": round(now, 3), "v": VERSION, "updating": bool(REFRESHING["on"])}
    if REFRESHING["on"] and REFRESHING["started_at"]:
        d["refreshingFor"] = round(now - REFRESHING["started_at"], 1)
    if LAST_FETCH["at"]:
        d["lastFetch"] = {"ago": round(now - LAST_FETCH["at"], 1), "ok": LAST_FETCH["ok"],
                          "reason": LAST_FETCH["reason"], "detail": LAST_FETCH["detail"],
                          "loggedOut": bool(LAST_FETCH.get("loggedOut"))}
    d.update(_session_fields())
    return d


def snapshot():
    """锁外快照：立刻返回当前内存缓存，不抓取、不等锁。

    没有缓存时返回 hasData=false（而不是 404）—— 手表因此能区分
    「服务活着但还没数据」和「服务根本没开」。
    """
    refresh_watchdog()
    now = time.time()
    cached = CACHE["data"]
    if not cached:
        out = {"ok": True, "hasData": False, "age": -1, "stale": True, "tasks": []}
        out.update(_status_fields(now))
        return out
    out = dict(cached)
    out["age"] = round(max(0.0, now - CACHE["ts"]), 1)
    out["hasData"] = True
    out["stale"] = (now - CACHE["ts"]) > CACHE_TTL
    out.update(_status_fields(now))
    return out


def snapshot_etag():
    """快照的内容指纹：只有拿到「新的一批数据」才会变。

    手表带着 If-None-Match 来问，指纹一样就回 304 —— 正文（17 KB）不过网。
    省的不只是流量：服务端也省掉一次 17 KB 的 json.dumps，手表端省一次解析与解码。
    """
    if not CACHE["data"]:
        return ""
    seed = "%d|%d|%d|%d" % (int(CACHE.get("ts") or 0),
                            len(CACHE["data"].get("tasks") or []),
                            len(CACHE["data"].get("recent") or []),
                            VERSION)
    return '"%s"' % hashlib.sha1(seed.encode("utf-8")).hexdigest()[:16]


def request_refresh(max_age=None):
    """踢一脚后台抓取，立刻返回（不等结果）。数据够新就不抓。"""
    refresh_watchdog()
    limit = CACHE_TTL if max_age is None else float(max_age)
    now = time.time()
    if REFRESHING["on"]:
        return {"ok": True, "started": False, "reason": "already",
                "age": round(max(0.0, now - CACHE["ts"]), 1) if CACHE["data"] else -1,
                "refreshingFor": round(now - (REFRESHING["started_at"] or now), 1)}

    # 电脑上的 ManageBac 登录已失效 → 抓一百次也还是空的，但每一次都要把无头
    # Chrome 开起来、等页面加载、注入脚本（几秒到几十秒 CPU）。手表在前台每 20 秒
    # 就踢一脚，等于让这台 Mac 永远在做无用功。所以登录失效期间退避到 10 分钟试一次。
    # max_age <= 0 表示「人在手表上按住刷新」→ 例外放行，好在重新登录后立刻能看到反馈。
    if LAST_FETCH.get("loggedOut") and limit > 0:
        # 存了凭据就能自动重登，那值得勤快点试（5 分钟），早点自愈；
        # 没凭据的话试了也白试，按 10 分钟退避，别烧 CPU。
        backoff = 300.0 if has_credentials() else LOGOUT_BACKOFF
        waited = now - (LAST_FETCH.get("at") or 0.0)
        if waited < backoff:
            return {"ok": True, "started": False, "reason": "needs-login",
                    "age": round(max(0.0, now - CACHE["ts"]), 1) if CACHE["data"] else -1,
                    "retryIn": round(backoff - waited, 1),
                    "lastFetch": LAST_FETCH}

    if CACHE["data"] and (now - CACHE["ts"]) < limit:
        return {"ok": True, "started": False, "reason": "fresh",
                "age": round(now - CACHE["ts"], 1),
                "lastFetch": LAST_FETCH}
    start_background_refresh()
    return {"ok": True, "started": True,
            "age": round(max(0.0, now - CACHE["ts"]), 1) if CACHE["data"] else -1}


# ============================================================
#  云端中转：Mac 不在手表身边时的那条线路
#
#  数据只能由这台 Mac 抓（登录态 + 无界面浏览器都在这儿），但手表经常
#  和它不在同一个网络里（Mac 在家/在包里，手表在学校 WiFi），直连必然失败。
#  所以：Mac 每次抓到数据就推一份到公网上的中转服务（~/.mbboard/relay/），
#  手表在任何网络下都能从中转拿到最新数据。
#
#  配置在 ~/.mbboard/relay.json：{"url": "...", "token": "...", "every": 60}
#  没有这个文件 = 不启用，行为与以前完全一样（本机接口一个都不变）。
# ============================================================

RELAY_FILE = os.path.join(MBB_DATA, "relay.json")
RELAY = {"kind": "relay", "url": "", "token": "", "topic": "",
         "every": 60.0, "gap": 0.0, "on": False}
RELAY_STATE = {"pushes": 0, "fails": 0, "last_push": 0.0, "last_ok": 0.0,
               "last_ts": 0.0, "error": "", "last_id": "", "finger": ""}

# ── ntfy 免费档的额度守卫 ────────────────────────────────────────────
# ntfy.sh 免费档限 **每个 IP 每天 250 条消息**（官方定价页写得很清楚）。
# 原来的心跳是 300 秒一次 = 288 条/天 —— 单靠心跳就会在傍晚把额度用光，
# 之后整条云端线路会被 429 挡掉：手表只能看到旧数据，而且很难看出是为什么。
# 所以这里做三件事：
#   ① 心跳放慢到 15 分钟（relay.json 的 every 可以调）；
#   ② 深夜（00:30–06:30）心跳拉长到 1 小时；
#   ③ 记 24 小时滚动窗口里已推了多少条，逼近上限就自动拉长心跳、最后只推真变化。
QUOTA_FILE = os.path.join(MBB_DATA, "relay-quota.json")
QUOTA_MAX = 220          # 24 小时软上限（留 30 条余量给「数据真的变了」的场景）
QUOTA = {"stamps": []}
QUIET = (23 * 60 + 30, 6 * 60 + 30)   # 深夜 23:30 – 06:30：没人看，心跳放到最慢


def quota_load():
    """启动时把「24 小时内推过哪些时刻」读回来 —— 服务重启不该重置额度。"""
    try:
        with open(QUOTA_FILE, encoding="utf-8") as f:
            raw = json.load(f).get("stamps") or []
        QUOTA["stamps"] = [float(x) for x in raw][-400:]
    except Exception:
        QUOTA["stamps"] = []


def quota_prune():
    cut = time.time() - 86400
    QUOTA["stamps"] = [t for t in QUOTA["stamps"] if t > cut]


def quota_left():
    quota_prune()
    return QUOTA_MAX - len(QUOTA["stamps"])


def quota_note():
    QUOTA["stamps"].append(time.time())
    quota_prune()
    try:
        with open(QUOTA_FILE, "w", encoding="utf-8") as f:
            json.dump({"stamps": QUOTA["stamps"]}, f)
    except Exception:
        pass


def quiet_now(now=None):
    """现在是不是「深夜」——按本机时间算。"""
    lt = time.localtime(now or time.time())
    m = lt.tm_hour * 60 + lt.tm_min
    a, b = QUIET
    return (m >= a) or (m < b)


def relay_mac_meta(snap):
    """给 ntfy 用的「小抄」：只放数字，塞在消息文本里（< 4 KB 就不会变附件）。
    手表先读它，发现 fetchedAt 没变就不去下载 17 KB 的正文 —— 省流量也更快。"""
    return json.dumps({
        "f": int(snap.get("fetchedAt") or 0),          # 数据被 Mac 抓到的时刻
        "p": int(time.time()),                          # Mac 最后在线（= 这次推送）
        "t": len(snap.get("tasks") or []),
        "c": len(snap.get("classes") or []),
        "r": len(snap.get("recent") or []),
        "lg": bool(snap.get("loggedIn", True)),
    }, separators=(",", ":"))


def ntfy_push(snap):
    """把快照推给 ntfy.sh 上的一个随机主题。

    正文 17 KB 超过 ntfy 的 4 KB 消息上限，服务端会自动把它存成**附件**并回一个 URL；
    手表先读消息文本里的小抄，发现数据没换就不下载附件。
    """
    topic = RELAY["topic"]
    body = json.dumps(snap, ensure_ascii=False).encode("utf-8")
    req = urllib.request.Request(
        RELAY["url"] + "/" + urllib.parse.quote(topic), data=body, method="PUT",
        headers={
            "Filename": "snapshot.json",
            "Content-Type": "application/json; charset=utf-8",
            "Message": relay_mac_meta(snap),
        })
    with urllib.request.urlopen(req, timeout=20) as r:
        raw = r.read()
    # ntfy 会把「这次推送生成了哪条消息」回给我们，留着排障用
    try:
        RELAY_STATE["last_id"] = json.loads(raw.decode("utf-8", "ignore")).get("id") or ""
    except Exception:
        RELAY_STATE["last_id"] = ""
    print("ntfy 已推送：%d 字节 → 消息 %s" % (len(body), RELAY_STATE["last_id"] or "?"), flush=True)


def relay_push():
    """把当前快照推给中转（后台线程里跑，失败只记状态、不抛异常）。

    这里有两道「别把好数据覆盖掉」的守卫，都很关键：
      ① 一次都没抓到过数据 → 不推；
      ② **登录失效时不推**。掉登录的那一轮 fetch 会返回
         `loggedIn=false, tasks=[]`，推上去就等于把中转上那份「3 分钟前的完整数据」
         换成「空列表」—— 手表从「显示旧数据」直接变成「什么都没有」。
         宁可让中转继续拿着旧数据，手表那边会如实标出「数据 X 小时前」。
    """
    if not RELAY["on"] or not CACHE["data"]:
        return False
    snap = snapshot()
    if snap.get("loggedIn") is False or not snap.get("hasData"):
        if RELAY_STATE["fails"] == 0:
            print("云端中转暂不推送：本地登录失效，继续保留中转上那份旧数据。", flush=True)
        RELAY_STATE["last_ts"] = CACHE["ts"]     # 别每轮都重复判断
        return False

    # 一定要告诉手表「Mac 此刻还在线」——它是分开算「数据年龄」和「电脑最后在线」的
    snap["macSeenAt"] = round(time.time(), 3)
    snap["via"] = RELAY["kind"]

    # ★ 内容没变就别推 ★
    #   上面那行 macSeenAt 每轮都在变，所以只按「快照不同」判断永远为真 ——
    #   结果是每 5 分钟往中转/ntfy 发一条跟上一轮**一模一样**的消息，
    #   用户手机上就是每 5 分钟响一次、内容还全是旧的，纯骚扰。
    #   现在：内容有实质变化 → 立刻推；没变化 → 只按心跳间隔推一次
    #   （保留「Mac 在线」这个信号，但不再刷屏）。
    finger = hashlib.sha1(
        json.dumps({k: v for k, v in snap.items() if k != "macSeenAt"},
                   sort_keys=True, ensure_ascii=False).encode("utf-8")).hexdigest()
    now0 = time.time()
    changed = finger != RELAY_STATE.get("finger")
    heartbeat = (now0 - RELAY_STATE.get("last_push", 0.0)) > 1800
    if not changed and not heartbeat:
        RELAY_STATE["last_ts"] = CACHE["ts"]
        return False

    try:
        if RELAY["kind"] == "ntfy":
            ntfy_push(snap)
        else:
            url = RELAY["url"] + "/api/push"
            if RELAY["token"]:
                url += "?token=" + urllib.parse.quote(RELAY["token"])
            req = urllib.request.Request(
                url, data=json.dumps(snap, ensure_ascii=False).encode("utf-8"),
                method="POST", headers={"Content-Type": "application/json"})
            with urllib.request.urlopen(req, timeout=12) as r:
                r.read()
    except Exception as e:
        RELAY_STATE["fails"] += 1
        RELAY_STATE["error"] = str(e)[:120]
        if RELAY_STATE["fails"] == 1 or RELAY_STATE["fails"] % 10 == 0:
            print("云端中转推送失败（第 %d 次）：%s" % (RELAY_STATE["fails"], e), flush=True)
        return False
    now = time.time()
    RELAY_STATE["pushes"] += 1
    RELAY_STATE["last_push"] = now
    RELAY_STATE["last_ok"] = now
    RELAY_STATE["last_ts"] = CACHE["ts"]
    RELAY_STATE["finger"] = finger    # 记下这次推的内容，下一轮才有得比
    quota_note()                       # 记一笔，24 小时窗口里还剩下多少条看它
    if RELAY_STATE["fails"]:
        print("云端中转已恢复。", flush=True)
    RELAY_STATE["fails"] = 0
    RELAY_STATE["error"] = ""
    return True


def load_relay():
    """读中转配置。文件不存在就静默关闭 —— 不能因为中转没配就把本机功能弄坏。

    两种 kind：
      · "relay" —— 自建的中转服务（接口和本机桥接一样）；
      · "ntfy"  —— ntfy.sh 公共主题，零账号、立刻可用；topic 就是唯一口令。
    """
    RELAY["on"] = False
    RELAY["kind"] = "relay"
    RELAY["topic"] = ""
    try:
        with open(RELAY_FILE, encoding="utf-8") as f:
            cfg = json.load(f)
    except Exception:
        return
    kind = str(cfg.get("kind") or "relay").strip().lower()
    url = str(cfg.get("url") or "").strip().rstrip("/")
    topic = str(cfg.get("topic") or "").strip()
    if kind == "ntfy":
        url = url or "https://ntfy.sh"
        if not topic:
            print("relay.json 写了 ntfy 但没给 topic，云端线路未启用。", flush=True)
            return
        RELAY["kind"] = "ntfy"
        RELAY["topic"] = topic
        RELAY["url"] = url
        RELAY["token"] = ""
        try:
            # 默认 15 分钟一次心跳（原来 5 分钟 = 288 条/天，会顶破 ntfy 免费档的 250 条）。
            # 详见文件上方 QUOTA 的说明。
            RELAY["every"] = max(120.0, float(cfg.get("every") or 900))
        except Exception:
            RELAY["every"] = 900.0
        try:
            # 两次推送之间至少隔这么久。数据一变就推会很容易触发对方的限流。
            RELAY["gap"] = max(30.0, float(cfg.get("gap") or 420))
        except Exception:
            RELAY["gap"] = 420.0
    else:
        if not url:
            return
        RELAY["url"] = url
        RELAY["token"] = str(cfg.get("token") or "").strip()
        try:
            RELAY["every"] = max(20.0, float(cfg.get("every") or 60))
        except Exception:
            RELAY["every"] = 60.0
        RELAY["gap"] = 0.0
    RELAY["on"] = bool(cfg.get("enabled", True))
    RELAY_STATE["last_ts"] = 0.0


def relay_status():
    now = time.time()
    out = {"on": RELAY["on"], "kind": RELAY["kind"], "url": RELAY["url"],
           "every": RELAY["every"],
           "pushes": RELAY_STATE["pushes"], "fails": RELAY_STATE["fails"],
           "lastPushAgo": round(now - RELAY_STATE["last_push"], 1) if RELAY_STATE["last_push"] else -1,
           "lastId": RELAY_STATE.get("last_id", ""),
           "quotaLeft": quota_left(), "quotaMax": QUOTA_MAX, "quiet": quiet_now(now),
           "error": RELAY_STATE["error"]}
    if RELAY["kind"] == "ntfy":
        # 主题名等于口令，别在状态接口里回显
        out["topic"] = (RELAY["topic"][:6] + "…") if RELAY["topic"] else ""
        out["readUrl"] = RELAY["url"] + "/" + RELAY["topic"] + "/json?poll=1&since=latest"
    return out


def relay_loop():
    """后台线程：抓到新数据立刻推；平时按 every 秒发一次心跳，但要看着额度走。

    心跳不能省 —— 中转靠「最后一次推送时间」告诉手表电脑还在不在线；
    但心跳也不能太勤 —— ntfy 免费档一天只有 250 条（见文件上方 QUOTA 的说明）。
    所以：数据变了立刻推（至少隔 gap），没变就按 every 心跳，
    深夜和额度告急时自动放慢，实在没额度了只推「真的变了」的那几次。
    """
    while True:
        time.sleep(10)
        if not RELAY["on"]:
            continue
        now = time.time()
        if RELAY_STATE["fails"]:
            back = min(300.0, 30.0 * (2 ** min(RELAY_STATE["fails"] - 1, 3)))
            if now - RELAY_STATE["last_ok"] < back:
                continue
        changed = CACHE["ts"] != RELAY_STATE["last_ts"]
        left = quota_left()
        every = RELAY["every"]
        if left <= 60:
            every = max(every, 1800.0)      # 额度告急：心跳改成半小时
        if quiet_now(now):
            every = max(every, 3600.0)      # 深夜：一小时
        gap = RELAY["gap"]
        if left <= 0:
            # 一条余量都没有了：只推「数据真的变了」，且至少隔半小时。
            # 宁可让云端那份旧一点，也不能被限流把整条线路断掉。
            if not changed or (RELAY_STATE["last_push"] and now - RELAY_STATE["last_push"] < 1800):
                continue
            gap = 1800.0
        if gap and RELAY_STATE["last_push"] and (now - RELAY_STATE["last_push"]) < gap:
            continue
        if not changed and (now - RELAY_STATE["last_push"]) < every:
            continue
        relay_push()


def selfheal_loop():
    """断网恢复后的自动补抓（后台常驻，每 5 分钟巡一次）。

    断网期间每次抓取都失败，而失败不会自动触发下一次 —— 过去只能等用户
    打开看板才补抓，于是「登录已失效」横幅和旧数据会一直挂到用户回来点一下。
    这个循环把「自愈」变成无人值守：只要曾连过账号、现在网络回来了、
    数据又旧得不像话，就悄悄补抓一轮（ManageBac + Teams 令牌/数据），
    全程复用静默保活（窗口在屏幕外），用户不会看到任何浏览器窗口。
    """
    while True:
        time.sleep(300)
        try:
            now = time.time()
            online = net_ok()
            if not online:
                continue
            # ① ManageBac：数据超过 10 分钟没更新 → 补抓
            #   （start_background_refresh 自带防重入与看门狗，直接踢即可）
            #
            # ⚠️「压根没数据」和「数据旧了」是两件事，不能混着说。
            #   以前没数据时拿 1e9 当占位值，日志里就打印出
            #   「已旧 16666667 分钟」（1e9 秒 ÷ 60）—— 一个 31 年的数字，
            #   看着像时间戳单位算错了，每次翻日志都得重新怀疑一遍。
            #   现在分开讲，并顺便堵掉一个浪费：用户还没登录时，
            #   以前也会每 5 分钟把无头 Chrome 拉起来白跑一趟。
            if CACHE["data"]:
                mb_age = now - CACHE["ts"]
                if mb_age > 600:
                    print("自愈：ManageBac 数据已旧 %.0f 分钟，自动补抓" % (mb_age / 60),
                          flush=True)
                    start_background_refresh()
            elif has_credentials():
                # 从没抓到过、但磁盘上存着凭据 → 值得自动试一次。
                # 新机器上「刚登录完就再也刷不出来」基本靠这一条自愈。
                print("自愈：ManageBac 还没有数据（凭据在），自动补抓一次", flush=True)
                start_background_refresh()
            # ② Teams：曾登录过但令牌现在取不到 → 静默拉回浏览器并重取令牌
            #   （不调 connect()——那会 show_browser 弹窗口，正是用户不想要的）
            m = teams_module()
            if m and m.ms.has_session():
                st = m.ms.auth_state()
                if not st.get("loggedIn"):
                    try:
                        m.ms.keep_alive()
                        tok = m.ms.token(force=True)
                        print("自愈：Teams 令牌%s" % ("已重新获取" if tok else "仍未取到"),
                              flush=True)
                    except Exception as e:
                        print("自愈：Teams 恢复失败 %s" % e, flush=True)
        except Exception as e:
            print("自愈循环异常：%s" % e, flush=True)


def net_ok():
    """轻量联网探针：DNS 解析 + TCP 连接一次完成，超时 5 秒。"""
    try:
        with socket.create_connection((school_host(), 443), timeout=5):
            return True
    except Exception:
        return False


def local_hostname():
    """.local 主机名（Bonjour）：IP 变了也不用改任何配置 —— 手表端首选它。"""
    try:
        s = subprocess.check_output(["/usr/sbin/scutil", "--get", "LocalHostName"],
                                    text=True, timeout=5).strip()
        if s:
            return s
    except Exception:
        pass
    try:
        return socket.gethostname().split(".")[0]
    except Exception:
        return ""


def lan_urls():
    """本机所有可用于「手表 WiFi 直连」的地址，.local 主机名排第一。

    主机名比 IP 优先：手机会/路由器会给 Mac 换 IP，主机名不会变。
    """
    urls = []
    lh = local_hostname()
    if lh:
        urls.append("http://%s.local:%d" % (lh, PORT))
    ips = []
    try:                                       # 默认路由出口地址（最可能被手表看到的那张网卡）
        s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        s.connect(("10.255.255.255", 1))
        ips.append(s.getsockname()[0])
        s.close()
    except Exception:
        pass
    try:
        for info in socket.getaddrinfo(socket.gethostname(), None, socket.AF_INET):
            ip = info[4][0]
            if ip not in ips:
                ips.append(ip)
    except Exception:
        pass
    for ip in ips:
        if ip.startswith("127.") or ip.startswith("169.254."):
            continue
        u = "http://%s:%d" % (ip, PORT)
        if u not in urls:
            urls.append(u)
    return urls


# 空闲多久自动退出（秒）。看板页面开着时会定期请求，不会触发退出；
# 关闭页面后服务自行消失，不常驻后台。
IDLE_TIMEOUT = float(os.environ.get("MBBOARD_IDLE", "600"))
LAST_ACTIVITY = {"t": time.time()}
# 最近一次「局域网访客」（手表走 WiFi 直连）的请求时间。
# 手表在后台每隔十几分钟才醒一次，很容易踩在服务已经自动退出的空档上；
# 所以只要局域网最近用过，就把空闲上限抬到 30 分钟。
LAST_LAN = {"t": 0.0}
LAN_GRACE = 1800.0


def touch(from_lan=False):
    LAST_ACTIVITY["t"] = time.time()
    if from_lan:
        LAST_LAN["t"] = time.time()


def idle_limit():
    """本次允许的空闲上限（秒）。"""
    if IDLE_TIMEOUT <= 0:
        return 0.0                       # MBBOARD_IDLE=0 → 常驻，不退出
    if RELAY.get("on"):
        # 配了云端中转就一直开着：这个服务不在跑，手表在外网就彻底取不到数据。
        # 空闲退出是「只在本机看看板」时代的优化，和云端线路的目标直接冲突。
        return 0.0
    if time.time() - LAST_LAN["t"] < 900:
        return max(IDLE_TIMEOUT, LAN_GRACE)
    return IDLE_TIMEOUT


def _env():
    e = dict(os.environ)
    ensure_chrome_async()          # 一个浏览器都没有就先在后台准备一份
    p = chrome_path()
    # ★ 只在真的找到时才设这一条 ★
    #   设成空串会让 agent-browser 拿它去当可执行路径，报的错比
    #   「没找到浏览器」难懂得多（"Failed to launch Chrome at :"）。
    #   不设它、让 agent-browser 走自己的发现逻辑，反而更容易成功。
    if p:
        e["AGENT_BROWSER_EXECUTABLE_PATH"] = p
    e["AGENT_BROWSER_SESSION_NAME"] = SESSION_NAME
    # 让 ManageBac 的登录态也落在**数据目录**里。
    # 不设这一条时，agent-browser 会把 cookie 写到 ~/.agent-browser/sessions/，
    # 那是全局位置：既绕过了「代码与数据分家」，也让「清掉数据目录就等于退出登录」
    # 这件事不成立（用户以为删干净了，cookie 还在）。设了它就完全落在自己的目录里，
    # 和 teams-profile / seiue-profile 一个待遇。
    e["AGENT_BROWSER_PROFILE"] = os.path.join(MBB_DATA, "managebac-profile")
    return e


def components():
    """抓取链路上依赖的外部件，各自在不在。

    「为什么读不到数据」以前只能翻日志。现在把这一层摊开：
    缺 agent-browser 还是缺 Chrome，一眼能分清，也给出该怎么装。
    """
    ab_ok = os.path.exists(AB)
    eng = engine_online()
    # ★ 别再让用户去 npm install ★
    #   分发版把 agent-browser 打进了 App 包，启动时会装到数据目录。
    #   对着一个刚下载了 App 的同学说「去装 Node、再去 npm install」，
    #   他十有八九就此放弃了 —— 而这本来完全不需要他做任何事。
    #   内置引擎在线时更是连 agent-browser 都不需要。
    ab_fix = "" if (ab_ok or eng) else _AB_MISSING
    return {
        "agentBrowser": {"ok": ab_ok or eng, "path": AB if not eng else "app://webengine",
                         "fix": ab_fix, "viaEngine": eng},
        "chrome": chrome_state(),
        "python": {"ok": True, "path": sys.executable,
                   "note": "后端只用标准库，任何 Python 3.8+ 都够用"},
        "dataDir": MBB_DATA,
        "codeDir": HERE,
        "school": school_base(),
        "ready": (ab_ok or eng) and chrome_ready(),
    }


def _ab_target(args):
    """现在该由谁去干活。返回完整的 argv。

    ★ 这是「脱离 Chrome」的接缝 ★ bridge.py 里所有浏览器操作用的都是
    agent-browser 的那套命令行（open / eval / wait / cookies / close）。
    board/shared/webengine.py 把那套命令一模一样地实现了一遍，
    只是背后换成 App 内置的 WebKit。所以这里只要换掉「谁来执行」，
    上层十几处业务代码一个字都不用改。

    引擎不在线（Windows 版、或者单独把 bridge.py 拎出来跑）时，
    原样退回 agent-browser + Chromium。
    """
    if engine_online():
        shim = os.path.join(SHARED_DIR, "webengine.py")
        if os.path.exists(shim):
            # ★ 必须用 sys.executable 起它 ★
            #   不能靠 shebang `#!/usr/bin/env python3`：分发版里真正能用的
            #   Python 是包内那一份，PATH 上那个 /usr/bin/python3 只是个壳。
            return [sys.executable, shim] + list(args)
    return [AB, "--session-name", SESSION_NAME] + list(args)


def _ab_env():
    """执行环境。

    ★ 引擎在线时绝不能调 _env() ★ 那个函数里有一句 ensure_chrome_async()，
    会在后台闷头下一个 150MB 的 Chrome for Testing —— 而我们已经有浏览器了。
    用户看到的现象就是「明明能用，风扇却狂转、磁盘莫名其妙少了几百兆」。
    """
    if engine_online():
        return dict(os.environ)
    return _env()


def _ab_raw(args, timeout=180, stdin_data=None):
    """真正执行一次浏览器操作（不做自愈），返回 (returncode, stdout+stderr)"""
    # ★ 引擎在线时在**本进程内**执行，不 fork ★
    #   原来这里一律 fork 一个 webengine.py 子进程，子进程再经 HTTP 回到
    #   本进程的队列上 —— 四跳、两个进程。实测后果很实在：后台 status_loop
    #   探一次状态就 fork 一次，父子两边各自挂几十秒，几条线程叠起来就把
    #   整条链路拖死（抓线程栈时看得清清楚楚：父进程卡在 subprocess.run、
    #   子进程卡在 HTTP 等引擎）。详见 board/shared/webengine.py 的 run_cli。
    if engine_online() and we is not None and hasattr(we, "run_cli"):
        r = we.run_cli(list(args), stdin_data=stdin_data)
        if r is not None:
            return r
    try:
        r = subprocess.run(
            _ab_target(args),
            env=_ab_env(),
            capture_output=True,
            text=True,
            timeout=timeout,
            input=stdin_data,
        )
        return r.returncode, (r.stdout + r.stderr).strip()
    except subprocess.TimeoutExpired:
        return -1, "TIMEOUT"
    except Exception as e:  # noqa
        return -1, str(e)


# 浏览器会话已损坏时的典型报错（后台 Chrome 进程被回收、连接失效等）
BROKEN_SIGNS = (
    "cdp response channel closed",
    "target closed",
    "session closed",
    "browser has disconnected",
    "protocol error",
    "websocket is not open",
    "no such session",
    "connection refused",
    "econnrefused",
    "connect etimedout",
)

_RESET_LOCK = threading.Lock()


def reset_browser():
    """把无头浏览器彻底重建：关掉全部会话 + 清掉残留进程，再让下次调用重新拉起。"""
    with _RESET_LOCK:
        try:
            # 走 _ab_raw 而不是自己 subprocess.run —— 引擎在线时它会就地
            # 在本进程里执行，不必为一个「关掉全部标签」再 fork 一个进程。
            _ab_raw(["close", "--all"], timeout=45)
        except Exception:
            pass
        # ★ 只收「用着我们数据目录」的浏览器，绝不全局 pkill ★
        #   以前这里是 `pkill -f "Google Chrome for Testing"`：既收不掉
        #   换成系统 Chrome / Edge 之后的实例（重置形同虚设），又会在用户
        #   恰好装过 Chrome for Testing 时误伤。现在按 --user-data-dir 精确匹配，
        #   用户平时自己开的那个浏览器（profile 在别处）一根汗毛都不会动。
        try:
            kill_our_browsers(grace=1.0)
        except Exception:
            pass
        time.sleep(0.4)
        RESTORED["done"] = False     # 允许下次 ensure_session 重新注入登录 Cookie
        print("浏览器会话已重置（将自动重建）。", flush=True)


def _our_profile_pattern():
    """匹配「用着我们数据目录的浏览器主进程」。

    ★ 不再写死「Google Chrome for Testing」★
    浏览器现在可能是用户自己装的 Chrome / Edge / Brave / Arc —— 写死那一串
    的后果有两个：① 换成系统浏览器后这段逻辑完全失效（重置、回收孤儿都白做，
       残留进程越攒越多直到顶爆内存）；
       ② 反过来，用户恰好装过 Chrome for Testing 时，一句全局 pkill 会
       把他**自己正在用的**浏览器杀掉。这是绝对不能发生的事。
    所以特征串只保留两段：**任何一个 .app 里的可执行文件** + **我们的 profile 路径**。
    Framework Helper 的进程名里没有 `Contents/MacOS/<exe>` 这一段，所以不会
    重复计数 —— 杀掉主进程，它的渲染/GPU 子进程会跟着一起走。
    """
    esc = re.escape(MBB_DATA.rstrip("/")).replace(" ", "[ ]")
    return r"\.app/Contents/MacOS/[^ \t]+.*--user-data-dir=[" + esc + r"]/"


def our_browser_pids(orphans_only=False):
    """列出「属于本数据目录」的浏览器主进程 PID。

    看板的浏览器 profile（ManageBac / Teams / 希悦）全都建在 MBB_DATA 下面，
    所以拿 `--user-data-dir` 的路径前缀一比，就能确定是我们自己拉起来的 ——
    顺手也避开了误伤用户平时用的那个浏览器（它的 profile 在别处）。

    orphans_only=True 时只留「父进程已经没了、被 launchd(PID 1) 收养」的那些，
    也就是上一条命留下的无主进程。

    为什么用 pgrep 而不是 ps：ps 在受限环境（沙箱）里会被拒「operation not
    permitted」，而这函数必须稳 —— 拿不到进程表就当没孤儿，什么都别做。
    pgrep -P 1 正好直接给出「launchd 收养的进程」，比自己去解析 ppid 更省事。
    """
    pids = _pgrep(["-f", _our_profile_pattern()])
    if orphans_only:
        pids &= _pgrep(["-P", "1"])
    return sorted(pids)


def _pgrep(args):
    """跑一次 pgrep，返回 PID 集合；任何失败都返回空集（宁可什么都不做）。"""
    try:
        out = subprocess.run(["/usr/bin/pgrep"] + args,
                             stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
                             text=True, timeout=15).stdout
    except Exception:
        return set()
    return {int(x) for x in out.split() if x.strip().isdigit()}


def kill_our_browsers(grace=1.5, orphans_only=False):
    """把本数据目录下的浏览器进程请走。返回动过手的个数。

    和 reset_browser() 的区别：那个是「全部 Chrome for Testing 一个不留」，
    用于会话损坏时的暴力重建；这个是「只收我们自己的」，用于正常收尾。
    """
    import signal as _sig
    pids = our_browser_pids(orphans_only=orphans_only)
    if not pids:
        return 0
    for pid in pids:
        try:
            os.kill(pid, _sig.SIGTERM)
        except Exception:
            pass
    if grace:
        time.sleep(grace)
        for pid in our_browser_pids(orphans_only=orphans_only):   # 赖着不走的补一刀
            try:
                os.kill(pid, _sig.SIGKILL)
            except Exception:
                pass
    return len(pids)


def reap_orphan_browsers():
    """回收「上一条命」遗留的浏览器。

    为什么必须有这一步：Chrome 是用 start_new_session 起的 —— 它得比 bridge
    活得久，否则服务一重启，用户正开着登录的那个网页窗口就被一起收走了。
    代价是 **bridge 退出后它们不会被系统回收**：空闲自动退出、App 被退出、
    崩溃后重启，每一次都会攒下一茬。实测机器上攒下过两整套（Teams + 希悦），
    主进程各带十来个 Helper 子进程，白占一两个 GB —— 攒够了就撞上 macOS 的
    per-process memory limit，看板 App 跟一长串 Chrome Helper 一起被系统杀
    掉，也就是用户报的「应用时常闪退」。

    为什么敢全收（而不是只收 ppid=1 的孤儿）：浏览器只由 bridge 拉起，而这里
    是 bridge 的启动路径 —— 走到这一步就说明此刻只有我们一个 bridge，那么任何
    用着我们 profile 的浏览器，其所属的那条命都已经结束了。登录态都在 profile
    里落盘，收掉不会丢任何东西，下次要用时 ensure_browser 会静默拉起来。
    """
    pids = our_browser_pids()
    if not pids:
        return 0
    return kill_our_browsers(grace=1.5)


def ab(args, timeout=180, stdin_data=None):
    """运行 agent-browser；遇到会话损坏的报错自动重建浏览器并重试一次。"""
    rc, out = _ab_raw(args, timeout, stdin_data)
    low = (out or "").lower()
    if rc != 0 and any(s in low for s in BROKEN_SIGNS):
        reset_browser()
        rc, out = _ab_raw(args, timeout, stdin_data)
    return rc, out


def ab_eval(js, timeout=180):
    return ab(["eval", "--stdin"], timeout=timeout, stdin_data=js)


def _json_from(out):
    """agent-browser 打印的是被 JSON 编码的字符串，需要二次解析"""
    out = (out or "").strip()
    if not out:
        return None
    try:
        v = json.loads(out)
        if isinstance(v, str):
            try:
                return json.loads(v)
            except Exception:
                return v
        return v
    except Exception:
        m = re.search(r"\{.*\}|\[.*\]", out, re.DOTALL)
        if m:
            try:
                v = json.loads(m.group(0))
                if isinstance(v, str):
                    v = json.loads(v)
                return v
            except Exception:
                return None
    return None


STATUS_JS = (
    "JSON.stringify({url:location.href,title:document.title,"
    "hasLogin:!!document.querySelector('#session_login'),"
    "hasPwd:!!document.querySelector('input[type=password]'),"
    "hasOut:!!document.querySelector('a[href*=\"/logout\"], a[href*=\"/sign_out\"],"
    " form[action*=\"/logout\"]'),"
    "user:(function(){var e=document.querySelector('.user-name, [data-testid=user-name]');"
    "if(e&&e.innerText&&e.innerText.trim())return e.innerText.trim();"
    "var m=document.body.innerText.match(/Welcome,\\s*([^!\\n]{1,40})!/);return m?m[1].trim():'';})()})"
)


_AB_MISSING = ("本机缺少抓取组件（agent-browser），数据读不出来。"
               "请退出看板（⌘Q）后重新打开 —— 看板启动时会把自带的组件装好；"
               "如果重开还是这样，请重新安装看板。")


def _ab_err_text(out):
    """把 agent-browser / Chrome 吐出来的英文底层报错翻成人能照做的话。

    新用户看不到「Chrome 没装」这件事 —— 他只会看到一句
    Failed to launch Chrome at ...: No such file or directory，
    然后以为软件坏了。这里按最可能的三种原因分流。"""
    s = (out or "").strip()
    low = s.lower()
    if "failed to launch chrome" in low or ("chrome" in low and "no such file" in low):
        # ★ 别再说「去装 Chrome」★
        #   本机已经装着 Chrome / Edge / Brave 任意一款就够用，我们只是没找到；
        #   一款都没有时也会自动准备。用户唯一要做的是再点一次。
        return ("还没有可用的浏览器：点一下「重新校验」，会自动用本机已装的 "
                "Chrome / Edge / Brave，或准备一份（首次约 150MB）。")
    if "enotfound" in low or "getaddrinfo" in low or "econnrefused" in low or "etimedout" in low:
        return "连不上学校网站。确认网络能打开 ManageBac（校园网 / VPN 需不需要开）。"
    if "timed out" in low or "timeout" in low:
        return "抓取超时了，学校网站这次没响应。过一会儿点「重新校验」再试。"
    if "command not found" in low or "no such file" in low:
        return _AB_MISSING
    return s[:200]


def get_status():
    # 这两条前置判断，是把「说不清楚的失败」变成「知道下一步点哪里」。
    if not os.path.exists(AB):
        return {"loggedIn": False, "url": "", "user": "",
                "msg": _AB_MISSING, "reason": _AB_MISSING}
    if not chrome_ready():
        ensure_chrome_async()
        t = (chrome_state().get("fix") or "").strip() or \
            "浏览器还没就绪：正在自动准备（首次约 150MB），装好就能抓取。"
        return {"loggedIn": False, "url": "", "user": "",
                "msg": t, "reason": t, "preparing": True}
    rc, out = ab(["eval", STATUS_JS], timeout=90)
    if rc != 0:
        t = _ab_err_text(out)
        return {"loggedIn": False, "url": "", "user": "", "reason": t, "msg": t}
    d = _json_from(out) or {}
    if not isinstance(d, dict):
        d = {}
    url = d.get("url", "") or ""
    who = (d.get("user", "") or "").strip()
    # ★ 登录判据：别再只看 URL 里有没有 "/student/" ★
    #   原来要同时满足「没有 #session_login」+「URL 含 /student/」。问题是
    #   ManageBac 登录后的落点并不一定在 /student/ 下面（学校首页、通知页、
    #   学期页都在别的前缀下），于是**登录明明成功了却被判成失败**，
    #   界面弹「登录失败，检查账号密码后重试」—— 用户去改密码，越改越乱。
    #   现在只要拿到任一条「登录后的正证据」就算成功：
    #     ① 页面上出现了用户名 / "Welcome, X!"；
    #     ② 页面上有登出链接（只有登进去才有）；
    #     ③ 落在 /student/ 下的页面。
    #   同时保留反向证据（页面上还有登录框 / 密码框 ⇒ 一定没登进去）与
    #   URL 指向登录页，避免「假成功」——用户最恨的两件事就是假失败和假成功。
    has_login = bool(d.get("hasLogin", False)) or bool(d.get("hasPwd", False))
    looks_login_url = any(k in url for k in ("/login", "/sign_in", "/signin", "/auth/"))
    positive = bool(who) or bool(d.get("hasOut", False)) or ("/student/" in url)
    logged = (not has_login) and (not looks_login_url) and positive
    # `reason` 之外再给一份 `msg`：界面两处检查按钮读的是 `msg`（历史命名），
    # 只写 reason 的话这些提示就全被吞掉了 —— 用户只看到一句「未登录」，
    # 而服务端明明已经把「正在下载 Chrome，几分钟后点重新校验」写好了。
    out = {"loggedIn": bool(logged), "url": url, "user": d.get("user", "") or ""}
    out["msg"] = out.get("msg") or ""
    return out


# ── ManageBac 登录态快照 ──────────────────────────────────────────────
# 和上面 Teams 那份同一个理由：`get_status()` 要开浏览器 + 载页面 + 注入脚本
# （内部超时给到 90 秒），而 /api/status 过去是**同步**跑的、还包在全局 LOCK 里 ——
# 后台正好在抓取时锁会被占住两分钟，于是「检查四个账号」必然 20 秒超时，
# 界面报的是「本机服务没起来」，完全指错方向（服务好得很）。
# 现在：后台线程养一份快照，请求读快照即回；要现场探就用 probe=1。
STATUS_SNAP = {"ts": 0.0, "val": None, "busy": False}
STATUS_SNAP_LOCK = threading.Lock()
STATUS_TTL = 15.0


def _status_probe():
    """跑一次真实探测（慢）。只在后台线程或用户明确要求时调用。"""
    try:
        # 和抓取共用一把浏览器锁。放在后台线程里等是**无害**的：
        # 没有哪个界面请求会跟着一起排队（probe=1 有自己的 45 秒上限）。
        with LOCK:
            val = get_status()
    except Exception as e:
        val = {"loggedIn": False, "url": "", "user": "",
               "reason": "%s: %s" % (type(e).__name__, e)}
    if not isinstance(val, dict):
        val = {"loggedIn": False, "url": "", "user": "", "reason": "状态读取失败"}
    val.setdefault("msg", "")
    if val.get("msg") in (None, "") and val.get("reason"):
        val["msg"] = val["reason"]
    # 有没有存过账号密码。界面靠这个决定要不要显示「删除本机保存的密码」——
    # 以前这个字段压根没返回过，于是那个按钮只有「本次会话里刚登录完」才出现，
    # 重启 App 就消失，用户再也撤不掉已存的密码。
    try:
        val["hasCreds"] = bool(has_credentials())
    except Exception:
        val["hasCreds"] = False
    with STATUS_SNAP_LOCK:
        STATUS_SNAP["val"] = val
        STATUS_SNAP["ts"] = time.time()
        STATUS_SNAP["busy"] = False
    return val


def status_cold(probing=False):
    """快照还没出生时（服务刚起的那一两秒）的占位返回。

    仍然带上 `hasCreds` —— 那是纯读文件，不花钱，而且「删除保存的密码」
    这个按钮要靠它，不该因为状态还没探完就消失一下。
    """
    try:
        creds = bool(has_credentials())
    except Exception:
        creds = False
    out = {"loggedIn": False, "url": "", "user": "", "msg": "",
           "reason": "正在检查 ManageBac 登录态…", "warmup": True,
           "hasCreds": creds}
    if probing:
        out["probing"] = True
    return out


def status_snapshot(max_age=STATUS_TTL):
    """给请求用的登录态：立刻返回；过期就踢一脚后台刷新。"""
    with STATUS_SNAP_LOCK:
        v = STATUS_SNAP["val"]
        stale = (v is None) or ((time.time() - STATUS_SNAP["ts"]) > max_age)
        if stale and not STATUS_SNAP["busy"]:
            STATUS_SNAP["busy"] = True
            threading.Thread(target=_status_probe, daemon=True).start()
    if v is not None:
        return v
    return status_cold()


def status_probe_blocking(wait=20.0):
    """现场探一次，最多等 `wait` 秒；没等到就把手上那份先给出去（带 probing 标记）。

    用户点「重新校验」走这条路。等，但**一定有上限** —— 不能让一次点击
    变成一个转不完的圈。没探完也不要紧：后台那份跑完就会落进快照，
    界面隔几秒再问一次就是新的。
    """
    with STATUS_SNAP_LOCK:
        if not STATUS_SNAP["busy"]:
            STATUS_SNAP["busy"] = True
            threading.Thread(target=_status_probe, daemon=True).start()
    deadline = time.time() + wait
    busy, v = True, None
    while True:
        with STATUS_SNAP_LOCK:
            busy = STATUS_SNAP["busy"]
            v = STATUS_SNAP["val"]
        if (not busy and v is not None) or time.time() >= deadline:
            break
        time.sleep(0.3)
    if v is not None:
        out = dict(v)
        if busy:
            out["probing"] = True
        return out
    return status_cold(probing=True)


def status_loop():
    """后台常驻：把 ManageBac 登录态养热（冷启动那 90 秒只花一次）。"""
    while True:
        try:
            with STATUS_SNAP_LOCK:
                if STATUS_SNAP["busy"]:
                    time.sleep(1.0)
                    continue
                STATUS_SNAP["busy"] = True
            _status_probe()
        except Exception:
            pass
        time.sleep(STATUS_TTL)


COOKIE_JS = (
    "(function(){var bs=Array.from(document.querySelectorAll('button'));"
    "var b=bs.find(function(x){return /Accept Only Necessary/i.test(x.innerText||'');})"
    "||bs.find(function(x){return /Allow All/i.test(x.innerText||'');});"
    "if(b){b.click();return 'dismissed';}return 'none';})()"
)


def _already_logged_in():
    """「现在是不是已经登着了」——但对「是」的答案一律现场复核。

    ★ 语义变了，而且是**故意**变的 ★
    以前快照只要还新鲜就直接采信，包括「登着」这个答案。那是假成功的来源：
    快照可能是上一段会话、甚至上一个账号留下的，用户输个错密码照样被告知
    「登录成功」，然后在「数据怎么一直是旧的」上折腾。
    现在：快照里的「否」可以直接用（最坏也就是多走一次真实登录），
    快照里的「是」则一定再用一次现场探测复核。
    """
    with STATUS_SNAP_LOCK:
        v = STATUS_SNAP["val"]
        fresh = isinstance(v, dict) and (time.time() - STATUS_SNAP["ts"]) <= STATUS_TTL
    if fresh and not v.get("loggedIn"):
        return False
    return _verify_logged_in()[0]


def _note_logged_in(url="", who=""):
    """登录成功后立刻把快照刷成「已登录」。

    为什么必须做：快照是后台线程每 15 秒养一份的。登录成功之后如果不等它自然
    刷新，界面紧接着去问「现在登上了吗」读到的还是**旧的「未登录」** ——
    刚登录成功却显示失败，用户会以为密码错了，去反复改密码。
    """
    val = {"loggedIn": True, "url": url, "user": who, "msg": "", "reason": ""}
    try:
        val["hasCreds"] = bool(has_credentials())
    except Exception:
        val["hasCreds"] = False
    with STATUS_SNAP_LOCK:
        STATUS_SNAP["val"] = val
        STATUS_SNAP["ts"] = time.time()
        STATUS_SNAP["busy"] = False


def _verify_logged_in():
    """现场确认一次登录态。返回 (是否登录, 用户名, 说明)。

    ★ 为什么不能再看快照 ★
    原来这里读的是后台养着的那份快照，只要新鲜就直接采信。后果是**假成功**：
    上一段会话（甚至别人的号）留下的快照还在 15 秒窗口里，用户输了个错密码，
    照样被告知「登录成功」。假成功比假失败更坏 —— 用户以为一切正常，
    之后在「数据怎么一直是旧的」上折腾半天。
    现在改成现场探一次。它**不走快照线程**（那会在 /api/login 已持锁时
    自己跟自己抢锁，白等一轮），而是直接在当前线程探。
    """
    try:
        st = get_status()
    except Exception as e:
        return False, "", "%s: %s" % (type(e).__name__, e)
    if st.get("loggedIn"):
        return True, (st.get("user") or ""), ""
    return False, "", (st.get("reason") or st.get("msg") or "")


def login(login_name, password, remember=True):
    """用无界面浏览器完成一次真实登录。

    ⚠️ 本函数**只负责登录**，不碰「要不要记住账号密码」：
    那是 /api/login 处理器按用户勾选（save）决定的事。这里再存一次会有两个后果
    ——① 用户没勾也被存；② 用户打错密码又被「已登录」短路时，错误密码会被写进
    钥匙串，之后自动重登全废。
    """
    # ① 浏览器都没就绪就不要往下走。
    #    往下走只会在 ab() 那里拿到一句底层英文报错（"Failed to launch Chrome
    #    at ...: No such file or directory"），而这时候该告诉用户的是
    #    「正在自动准备浏览器，约 150MB，过几分钟点一次重试」——
    #    两者的下一步动作完全不同。
    ready, hint = ensure_browser_ready()
    if not ready:
        return False, (hint or
                       "正在自动准备浏览器（首次约 150MB），稍等几分钟再点一次「登录」。")

    # ② 再确认是不是已经登着了。**必须现场确认**，不能只看快照：
    #    看快照 → 假成功；不看直接走表单 → 已登录时打开 /login 会被重定向到
    #    看板，页面上没有账号框，脚本返回 NOFORM → 假失败。
    done, who, _ = _verify_logged_in()
    if done:
        _note_logged_in(who=who)
        return True, "登录成功"

    rc, out = ab(["open", login_url()], timeout=120)
    if rc != 0:
        # ★ 这里以前直接把 agent-browser 的英文原始报错吐给用户 ★
        #   典型长这样：
        #     Failed to launch Chrome at /Users/xxx/.mbboard/chrome/...:
        #     No such file or directory
        #   用户完全不知道该做什么。而真正的三种原因（浏览器还没准备好 /
        #   连不上学校网站 / 抓取组件缺失）在屏幕上要给的**下一步动作完全不同**。
        return False, _ab_err_text(out)
    ab(["wait", "2500"], timeout=60)
    ab(["eval", COOKIE_JS], timeout=60)

    payload = json.dumps({"l": login_name, "p": password, "r": bool(remember)})
    js = (
        "(function(){var C=%s;"
        "var u=document.querySelector('#session_login');"
        "var p=document.querySelector('#session_password');"
        "if(!u||!p)return 'NOFORM';"
        "var d=Object.getOwnPropertyDescriptor(window.HTMLInputElement.prototype,'value').set;"
        "function set(el,v){d.call(el,v);el.dispatchEvent(new Event('input',{bubbles:true}));"
        "el.dispatchEvent(new Event('change',{bubbles:true}));}"
        "set(u,C.l);set(p,C.p);"
        "var rm=document.querySelector('#session_remember_me');if(rm){rm.checked=!!C.r;}"
        "var b=document.querySelector('input[name=commit]')||document.querySelector('button[type=submit]');"
        "if(b){b.click();}else{document.querySelector('form').submit();}"
        "return 'SUBMITTED';})()" % payload
    )
    rc, out = ab_eval(js, timeout=90)
    if "SUBMITTED" not in out and "NOFORM" in (out or ""):
        # NOFORM 有两种来源，都不能直接当「登录失败」报给用户：
        #   ① 页面还没加载完（ManageBac 首屏要拉一堆静态资源，2.5 秒不一定够）
        #      —— 等一会儿再注入一次就好；
        #   ② 已经登录着，打开 /login 被直接重定向到看板，页面上当然没有输入框
        #      —— 这时候用户要的「能用」其实已经成立，往下走会去查登录态。
        ab(["wait", "3000"], timeout=60)
        rc, out = ab_eval(js, timeout=90)
    if "SUBMITTED" not in out:
        if "NOFORM" in (out or ""):
            done, who, _ = _verify_logged_in()
            if done:
                _note_logged_in(who=who)
                return True, "登录成功"
            return False, "登录页没有出现账号/密码框。点「检查当前状态」看看，或稍后重试。"
        return False, _ab_err_text(out) or ("提交登录失败：" + (out or "")[:150])

    for _ in range(15):
        time.sleep(2)
        st = get_status()
        if st.get("preparing"):
            # 浏览器还在后台准备（首次约 150MB）。这**不是**账号密码问题，
            # 必须原样告诉用户，否则他会去改密码。
            return False, (st.get("reason") or st.get("msg")
                           or "浏览器还在自动准备，稍等一下再点一次登录")
        if st["loggedIn"]:
            save_cookies()              # 登录成功后立即持久化，之后关浏览器也不会掉线
            RESTORED["done"] = True
            _note_logged_in(st.get("url", ""), st.get("user", ""))
            return True, "登录成功"

    # 走到这里 = 表单提交成功了，但一直没变成「已登录」。
    # ★ 别再一律甩「账号或密码可能有误」★ 网络不通时那句话会把用户引去
    #   反复改密码（实测就是这么发生的）。用最后一次探测的 reason 判断到底是
    #   哪一类失败，能说清就说清。
    try:
        st = get_status()
        why = (st.get("reason") or st.get("msg") or "").strip()
    except Exception:
        why = ""
    if why:
        return False, why
    return False, ("登录没成功：账号或密码可能不对；也可能学校网站这次没响应，"
                   "或需要额外验证（如双重验证）。点「检查当前状态」可以看详情。")


def _fetch_blocking():
    """真正去抓一次（同步）。串行化浏览器操作。"""
    with LOCK:
        return _fetch_once()


GRADETIME_FILE = os.path.join(MBB_DATA, "gradetimes.json")


def _gradetimes_load():
    try:
        with open(GRADETIME_FILE, encoding="utf-8") as f:
            gt = json.load(f)
        return gt if isinstance(gt, dict) else {}
    except Exception:
        return {}


def _gradetimes_save(gt):
    # 防止无限膨胀：超过 900 条时丢掉最老的
    if len(gt) > 900:
        for k in sorted(gt, key=lambda k: gt[k])[: len(gt) - 700]:
            gt.pop(k, None)
    try:
        with open(GRADETIME_FILE, "w", encoding="utf-8") as f:
            json.dump(gt, f, ensure_ascii=False)
    except Exception:
        pass


def _due_ms(w):
    """作业截止时间的毫秒值（ISO 字符串 → ms），解析不了返回 0。"""
    s = w.get("due") or ""
    if not isinstance(s, str) or not s:
        return 0
    try:
        return int(datetime.fromisoformat(s.replace("Z", "+00:00")).timestamp() * 1000)
    except Exception:
        return 0


def stamp_graded_times(d):
    """ManageBac 不提供「老师什么时候批出分」，只能自己留存。

    约定：第一次在某次抓取结果里见到这条已评分作业的时刻，作为出分时间的
    上界记下来（抓取间隔最长几分钟，误差远小于「不知道」）。以作业 URL 为键
    持久化在 gradetimes.json 里，之后每次抓取都回填 gradedAtMs ——
    大看板 / 菜单栏两边拿到的都是同一个时间。最新出分按它从新到旧排。
    """
    try:
        gt = _gradetimes_load()
        now_ms = int(time.time() * 1000)
        items = [w for w in (d.get("recent") or []) if isinstance(w, dict)]
        for c in (d.get("classes") or []):
            if not isinstance(c, dict):
                continue
            if isinstance(c.get("latest"), dict):
                items.append(c["latest"])
            # 学科柱状图要逐条展示，这些明细也得带上出分时间，
            # 否则图里只有分数、看不出「这次是什么时候出的」。
            for it in (c.get("items") or []):
                if isinstance(it, dict):
                    items.append(it)
        changed = False
        for it in items:
            if it.get("score") is None and not (it.get("grade") or "").strip():
                continue        # 没出分的不记
            k = it.get("url") or it.get("title") or ""
            if not k:
                continue
            if k not in gt:
                gt[k] = now_ms
                changed = True
            it["gradedAtMs"] = gt[k]
        if changed:
            _gradetimes_save(gt)
        rec = d.get("recent")
        if isinstance(rec, list):
            rec.sort(key=lambda w: (w.get("gradedAtMs") or 0, _due_ms(w)), reverse=True)
    except Exception as e:  # noqa
        print("出分时间留存失败（不影响抓取）：%s" % e, flush=True)


def _logged_out_payload():
    """「抓到了登录页」时回给客户端的负载。

    注意 ok=True：服务本身是好的（别让客户端以为服务挂了），
    但 loggedIn=False + sessionExpired=True —— 这份东西不能冒充数据。
    """
    d = {"ok": True, "loggedIn": False, "tasks": [], "fetchedAt": time.time(),
         "sessionExpired": True}
    d.update(_session_fields())
    return d


# ---------------- 登录态记账 + 自动重登 ----------------

def mark_session(ok: bool):
    """把这次真实校验的结果记进 SESSION。（唯一写入点，别在别处改。）"""
    now = time.time()
    SESSION["lastCheck"] = now
    if ok:
        if SESSION["dead"]:
            print("登录已恢复（掉线 %d 分钟）。" % int((now - SESSION["since"]) / 60), flush=True)
        SESSION["dead"] = False
        SESSION["since"] = 0.0
        SESSION["lastOk"] = now
        SESSION["autoNote"] = ""
    else:
        if not SESSION["dead"]:
            SESSION["dead"] = True
            # 「什么时候掉的」按**最后一次抓到数据的时刻**算，而不是「本次发现它的时刻」。
            # 掉登录是静默的（服务照旧 ok=true），下次抓取才发现 —— 用发现时刻会把
            # 「已经停了 7.5 小时」说成「已失效 2 分钟」，正好是最误导人的那个数字。
            SESSION["since"] = CACHE["ts"] if (CACHE["data"] and CACHE.get("ts")) else now
            print("确认掉登录（Cookie 还在，是服务端把会话作废了；数据自 %s 起未更新）。"
                  % time.strftime("%m-%d %H:%M", time.localtime(SESSION["since"])), flush=True)
    _session_save()


def keychain_password():
    """从钥匙串取密码；没存过就返回空串。

    ⚠️ 每次都要起一个子进程去问钥匙串（几十毫秒），而 /api/ping 是手表每 20 秒
    打一次的「极速探活」——所以下面 has_credentials() 必须缓存，不能每次现问。
    """
    try:
        r = subprocess.run(
            ["/usr/bin/security", "find-generic-password",
             "-s", KEYCHAIN_SERVICE, "-w"],
            capture_output=True, text=True, timeout=20)
        if r.returncode == 0:
            return (r.stdout or "").strip()
    except Exception:
        pass
    return ""


# 凭据是否可用 —— 缓存 5 分钟。ping 每 20 秒一次，绝不能每次都去敲钥匙串。
_CREDS_CACHE = {"at": 0.0, "login": "", "ok": False}


def _creds_cache_reset():
    _CREDS_CACHE["at"] = 0.0
    _CREDS_CACHE["ok"] = False
    _CREDS_CACHE["login"] = ""


def saved_login_name():
    try:
        with open(CREDS_FILE, encoding="utf-8") as f:
            return (json.load(f) or {}).get("login", "") or ""
    except Exception:
        return ""


def has_credentials(refresh=False):
    """本机是否存了可用的登录凭据（读缓存，不碰钥匙串）。"""
    now = time.time()
    if not refresh and _CREDS_CACHE["at"] and (now - _CREDS_CACHE["at"]) < 300:
        return _CREDS_CACHE["ok"]
    login_name = saved_login_name()
    ok = bool(login_name) and bool(keychain_password())
    _CREDS_CACHE.update({"at": now, "login": login_name, "ok": ok})
    return ok


def save_credentials(login_name, password):
    """账号写文件、密码写钥匙串。失败返回 (False, 原因)。"""
    login_name = (login_name or "").strip()
    if not login_name or not password:
        return False, "账号或密码为空"
    try:
        with open(CREDS_FILE, "w", encoding="utf-8") as f:
            json.dump({"login": login_name, "savedAt": time.time()}, f, ensure_ascii=False)
        os.chmod(CREDS_FILE, 0o600)
    except Exception as e:
        return False, "账号保存失败：%s" % e
    try:
        # -U：已存在就更新，避免重复条目
        r = subprocess.run(
            ["/usr/bin/security", "add-generic-password",
             "-a", login_name, "-s", KEYCHAIN_SERVICE, "-w", password, "-U"],
            capture_output=True, text=True, timeout=20)
        if r.returncode != 0:
            return False, "钥匙串写入失败：" + (r.stderr or r.stdout or "").strip()[:120]
    except Exception as e:
        return False, "钥匙串写入失败：%s" % e
    _creds_cache_reset()
    has_credentials(refresh=True)          # 立刻把缓存填成「有」
    return True, "已保存"


def forget_credentials():
    try:
        os.remove(CREDS_FILE)
    except Exception:
        pass
    try:
        subprocess.run(["/usr/bin/security", "delete-generic-password",
                        "-s", KEYCHAIN_SERVICE], capture_output=True, timeout=20)
    except Exception:
        pass
    _creds_cache_reset()


def try_auto_login(force=False):
    """掉了登录就用本机凭据自动重登一次。返回 (是否成功, 说明)。

    Cookie 会自己过期、temp profile 会被系统清空，所以「掉登录」不是异常，
    是必然发生的事。以前只能等用户来点一下，数据就白停几小时。
    """
    if not has_credentials():
        return False, "没存过凭据（在电脑看板登录时勾「自动重登」即可）"
    now = time.time()
    if not force and (now - SESSION["autoTried"]) < AUTO_LOGIN_MIN_GAP:
        return False, "刚试过，先等等"
    SESSION["autoTried"] = now
    login_name = saved_login_name()
    password = keychain_password()
    print("尝试自动重登（%s）…" % login_name, flush=True)
    ok, msg = login(login_name, password, remember=True)
    SESSION["autoNote"] = ("%s %s" % (time.strftime("%H:%M"), msg)).strip()
    print("自动重登结果：%s" % msg, flush=True)
    return ok, msg


def _fetch_once():
    """一次完整抓取：打开页面 → 校验登录 → 注入抓取脚本 → 取回结果"""
    ensure_session()
    rc, out = ab(["open", home_url()], timeout=150)
    if rc != 0:
        return {"ok": False, "loggedIn": False, "reason": "browser_error", "detail": out[:200]}

    ab(["wait", "1200"], timeout=60)

    # 先看是否掉登录
    st = get_status()
    if not st["loggedIn"] and os.path.exists(SESSION_FILE):
        # 浏览器可能被重建（临时 profile → Cookie 全丢）：用本机保存的凭据自动抢修一次
        ensure_session(force=True)
        ab(["open", home_url()], timeout=150)
        ab(["wait", "1200"], timeout=60)
        st = get_status()
    if not st["loggedIn"]:
        # Cookie 抢修没救回来 → 试试用钥匙串里的凭据真正重登一次（有限流）
        ok, _ = try_auto_login()
        if ok:
            mark_session(True)
            ab(["open", home_url()], timeout=150)
            ab(["wait", "1500"], timeout=60)
            st = get_status()
        if not st["loggedIn"]:
            mark_session(False)
            return _logged_out_payload()
    mark_session(True)

    try:
        js = open(SCRAPE_JS, encoding="utf-8").read()
    except Exception as e:
        return {"ok": False, "loggedIn": True, "reason": "scrape_missing", "detail": str(e)}

    rc, out = ab_eval(js, timeout=240)
    d = _json_from(out)
    if not isinstance(d, dict):
        return {"ok": False, "loggedIn": True, "reason": "parse_error", "detail": (out or "")[:200]}

    if not d.get("ok") and d.get("reason") == "logged_out":
        mark_session(False)
        return _logged_out_payload()

    d["loggedIn"] = True
    d["user"] = st.get("user", "")
    d["fetchedAt"] = time.time()
    d["stale"] = False
    d["updating"] = False
    stamp_graded_times(d)               # 出分时间留存 + 最新出分按它倒序
    CACHE["data"] = d
    CACHE["ts"] = time.time()
    save_cache(d)                       # 落盘，下次开服务秒回
    save_cookies()                      # 顺手刷新本机保存的登录凭据
    return d


def _stale_payload(cached, note=""):
    """把「旧数据 + 登录已失效」如实拼成一份给看板的负载。

    两件事必须同时成立，缺一个用户就会误判：
      · 数据照旧给（别把看板清空，用户还能看昨天的作业）
      · 但必须写明数据是旧的、登录没了 —— 不能让客户端拿缓存里的 loggedIn 当事实
    """
    out = dict(cached)
    out["stale"] = True
    out["updating"] = False                 # 抓不了就是抓不了，别演「正在更新」
    out["loggedIn"] = False
    out["sessionExpired"] = True
    out["sessionSince"] = round(time.time() - SESSION["since"], 1) if SESSION["since"] else 0
    out["sessionNote"] = SESSION["autoNote"]
    out["hasCreds"] = has_credentials()
    if note:
        out["sessionNote"] = note
    return out


def fetch_data(force=False):
    """取数据。

    - 有缓存且够新 → 直接返回
    - 有缓存但过期 → **立刻返回旧数据**，同时后台更新（页面秒开）
    - 无缓存 / force=1（点「刷新」）→ 同步抓取
    """
    now = time.time()
    cached = CACHE["data"]
    age = (now - CACHE["ts"]) if cached else 1e9

    if not force and cached and age < CACHE_TTL:
        return cached

    if not force and cached:
        if SESSION["dead"]:
            # 登录已经没了，后台再抓也是白抓（还会反复开无头浏览器）。如实说。
            return _stale_payload(cached)
        start_background_refresh()
        out = dict(cached)
        out["stale"] = True
        out["updating"] = True
        return out

    if not force:
        # 冷启动（没有任何缓存）也**绝不让人等首抓**。
        # 以前这里同步等 _fetch_blocking()，浏览器一抖就是十几秒起步，
        # 看板一直卡在「正在读取数据…」。现在起后台抓，立刻回一个占位负载，
        # 界面先出骨架，数据几秒后由后台自动补上（客户端见 updating 会轮询）。
        start_background_refresh()
        # ★ 这里的 loggedIn 以前写的是 True —— 那是**谎报**。
        #   冷启动这一刻我们根本不知道用户登没登录（后台正在抓），却告诉前端
        #   「已登录、一切正常」。前端据此把状态标成绿的、给用户一个「数据已就绪」，
        #   而屏幕上只有空课表；更要命的是后台抓取一旦失败（没登录 / 浏览器起不来），
        #   这个假绿会一直挂着，真实原因一个字都传不上去 —— 用户只能得出
        #   「登录失败了但不知道为什么」这个结论。
        #   改成 None（未知），和 /api/snapshot 的处理保持一致：不确定就别猜。
        return {"ok": True, "updating": True, "stale": False,
                "preparing": True, "loggedIn": None,
                "tasks": [], "recent": [], "classes": [], "events": [],
                "fetchedAt": now}

    with LOCK:
        # 排队等锁时可能已经被别人抓好了
        if CACHE["data"] and (time.time() - CACHE["ts"]) < CACHE_TTL:
            return CACHE["data"]
        got = _fetch_blocking()

    # 抓回来是「掉登录」的占位负载：任务列表是空的，直接给看板会把整页清空。
    # 拿旧数据配上诚实的失效说明，比一片空白有用得多。
    if isinstance(got, dict) and got.get("ok") and got.get("loggedIn") is False:
        if cached:
            return _stale_payload(cached, note=got.get("sessionNote", ""))
        got["hasCreds"] = has_credentials()
    return got


def save_cookies():
    """把 ManageBac 的登录 Cookie 存到本机（浏览器关闭后仍可恢复）"""
    if engine_online():
        d = we.cookies_get()
    else:
        rc, out = ab(["cookies", "get", "--json"], timeout=60)
        d = _json_from(out)
    if isinstance(d, dict) and not d.get("cookies"):
        inner = d.get("data")
        if isinstance(inner, (dict, list)):
            d = inner
    if isinstance(d, dict):
        d = d.get("cookies") or d.get("result") or []
    if not isinstance(d, list):
        return 0
    keep = [c for c in d if isinstance(c, dict) and "managebac" in (c.get("domain") or "")]
    if not keep:
        return 0
    try:
        with open(SESSION_FILE, "w", encoding="utf-8") as f:
            json.dump(keep, f, ensure_ascii=False)
        os.chmod(SESSION_FILE, 0o600)
    except Exception:
        return 0
    return len(keep)


def restore_cookies():
    """从本机恢复登录 Cookie"""
    if not os.path.exists(SESSION_FILE):
        return 0
    try:
        arr = json.load(open(SESSION_FILE, encoding="utf-8"))
    except Exception:
        return 0
    if not isinstance(arr, list):
        return 0

    # ★ 内置引擎在线时**一次性**灌进去 ★
    #   下面那条老路是一条 cookie 起一个进程（一次 subprocess + 一次往返），
    #   十几条就是十几秒；而这段代码在冷启动路径上，用户看到的就是
    #   「点了登录，转了半天还没动静」。
    if engine_online():
        batch = []
        for c in arr:
            if not isinstance(c, dict) or not c.get("name"):
                continue
            dom = str(c.get("domain") or "")
            if not dom:
                continue
            d = {"name": str(c["name"]), "value": str(c.get("value") or ""),
                 "domain": dom, "path": str(c.get("path") or "/")}
            if c.get("httpOnly"):
                d["httpOnly"] = True
            if c.get("secure"):
                d["secure"] = True
            try:
                exp = float(c.get("expires") or 0)
            except Exception:
                exp = 0
            if exp > 0:
                d["expires"] = exp
            batch.append(d)
        n = we.cookies_set(batch) if batch else 0
        if n:
            return n
        # 一条都没写成功就往下走老路 —— 让老的报错路径原样把原因带出来

    n = 0
    for c in arr:
        if not isinstance(c, dict):
            continue
        name = c.get("name")
        if not name:
            continue
        args = ["cookies", "set", str(name), str(c.get("value") or "")]
        if c.get("domain"):
            args += ["--domain", str(c["domain"])]
        if c.get("path"):
            args += ["--path", str(c["path"])]
        if c.get("httpOnly"):
            args += ["--httpOnly"]
        if c.get("secure"):
            args += ["--secure"]
        ss = str(c.get("sameSite") or "").capitalize()
        if ss in ("Strict", "Lax", "None"):
            args += ["--sameSite", ss]
        try:
            exp = float(c.get("expires") or 0)
        except Exception:
            exp = 0
        if exp > 0:
            args += ["--expires", str(int(exp))]
        rc, _ = ab(args, timeout=40)
        if rc == 0:
            n += 1
    return n


def ensure_session(force=False):
    """首次使用时，先启动浏览器再把已保存的登录 Cookie 注入回去。

    force=True 用于浏览器被重建（临时 profile → Cookie 全丢）时的自动抢修。
    """
    if RESTORED["done"] and not force:
        return
    RESTORED["done"] = True
    if not os.path.exists(SESSION_FILE):
        return
    ab(["open", login_url()], timeout=120)
    ab(["wait", "1500"], timeout=40)
    n = restore_cookies()
    if n:
        print("已恢复 %d 个登录 Cookie。" % n, flush=True)


# ==========================================================================
# 任务详情（描述 + 附件预下载）
#
# 看板点卡片弹「详情单」用：无头浏览器打开任务页 → 抓标题/正文/附件链接 →
# 把 ≤7MB 的附件下到 ~/.mbboard/files/<任务>/ 里，看板用 QuickLook 直接预览。
# 结果缓存 6 小时 —— 第二次点开同一任务就是毫秒级，也不再有网络等待。
# ==========================================================================

TASKCACHE_DIR = os.path.join(MBB_DATA, "taskcache")
FILES_DIR = os.path.join(MBB_DATA, "files")
TASK_TTL = 6 * 3600          # 详情缓存 6 小时
FILE_MAX = 7 * 1024 * 1024   # 附件预下载上限：7MB（用户指定的数）

# —— 任务详情预取：后台按间隔把「所有待办」的详情+附件提前抓进缓存，
#    这样用户点开任何一张卡都是毫秒级；间隔在设置里可调（0=关）。
PREFETCH = {"interval": 1800.0, "last": 0.0}   # interval 秒；last=上一轮预取的时刻
PREFETCH_FILE = os.path.join(MBB_DATA, "prefetch.json")
PREFETCH_FRESH = TASK_TTL / 2                    # 预取只补「缓存缺失或超过 3 小时」的
PREFETCH_MAX_ROUND = 6                           # 每轮最多抓 6 个，别把浏览器占太久
PREFETCH_IDLE_GUARD = 0                          # 忙则跳过，不与实时抓取抢浏览器


def _prefetch_load():
    try:
        with open(PREFETCH_FILE, encoding="utf-8") as f:
            j = json.load(f)
            iv = float(j.get("interval", 1800.0))
            PREFETCH["interval"] = max(0.0, iv)
    except Exception:
        pass


def _prefetch_save():
    try:
        json.dump({"interval": PREFETCH["interval"]}, open(PREFETCH_FILE, "w", encoding="utf-8"),
                  ensure_ascii=False)
    except Exception:
        pass
# 抓任务详情也走无头浏览器，必须和主抓取互斥。
# 以前这里是**另一把锁** —— 两把锁互不认识，主抓取和详情预取会同时打
# agent-browser，daemon 忙不过来直接报 os error 35（Resource temporarily
# unavailable），主抓取只好重试 5 次，冷启动十几秒就是这么被拖出来的。
# 现在干脆共用主锁，浏览器操作彻底串行：主抓取时预取自动排队让路。
_TASK_LOCK = LOCK

TASK_SCRAPE_JS = """
(function(){
  function txt(el){return ((el&&el.innerText)||'').trim();}
  var main=document.querySelector('#content')||document.querySelector('main')||document.body;
  var h=main.querySelector('h1')||main.querySelector('h2');
  // 附件：href 指向常见文档格式、或站点内文件路径的链接
  var fileRe=/\\.(pdf|docx?|pptx?|xlsx?|zip|png|jpe?g|gif|txt|csv|mp4|mov|key|pages|numbers|heic)(\\?|$)/i;
  var links=[];
  document.querySelectorAll('a[href]').forEach(function(a){
    var href=a.href||'';if(!href||href.indexOf('javascript')===0)return;
    var name=txt(a)||decodeURIComponent((href.split('/').pop()||'').split('?')[0])||'attachment';
    if(fileRe.test(href)||/(\\/files?\\/|\\/submissions\\/.*\\/attachment|download)/i.test(href)){
      links.push({name:name.slice(0,140),href:href});
    }
  });
  var seen={};links=links.filter(function(x){if(seen[x.href])return false;seen[x.href]=1;return true;});
  // —— 结构化信息：任务页顶部的 core-task-show 卡片（日期徽章/标题/类型/类别/截止/成绩/状态）
  //    这一块不属于正文，摘出来单独返回，正文里就不乱了
  var meta={};
  var card=main.querySelector('.core-task-show, .task-show, .short-assignment.section');
  if(card){
    var mt=card.querySelector('.h4.title, .title');
    if(mt)meta.title=txt(mt).slice(0,120);
    var mo=card.querySelector('.date-badge .month'),dy=card.querySelector('.date-badge .day');
    if(mo&&dy)meta.dueShort=txt(mo)+' '+txt(dy);
    var du=card.querySelector('.due-date .due, .due');
    if(du)meta.dueTime=txt(du).slice(0,40);
    var labs=[];card.querySelectorAll('.labels-set .label').forEach(function(e){
      var t=txt(e);if(t&&labs.indexOf(t)<0&&!/^(starts |current unit$)/i.test(t))labs.push(t);});
    if(labs.length)meta.labels=labs.slice(0,3);
    var gr=card.querySelector('.grade');
    if(gr)meta.grade=txt(gr).slice(0,16);
    var pt=card.querySelector('.points');
    if(pt)meta.points=txt(pt).slice(0,30);
    var sm=card.textContent.match(/\b(Not Submitted|Submitted|Pending|Late|Missing|Complete|Incomplete)\b/);
    if(sm)meta.status=sm[1];
  }
  // 计算正文前，把信息条、讨论区、页头导航临时藏起来（注意：正文 .fr-view
  // 也在 .core-task-show 里，所以只能藏卡顶的信息条，不能藏整卡）
  var hidden=[];
  ['.core-task-show .fusion-card-item','.recent-discussions','.f-hero','#layout-hero'].forEach(function(sel){
    document.querySelectorAll(sel).forEach(function(e){
      hidden.push([e,e.style.display]);e.style.display='none';});
  });
  // 正文：专用描述容器按优先级命中即用；都太短才做兜底扫描
  var desc='';
  ['#task_description','#description','.description','.user_content',
   '.submission-description','.task-description','.core-task-details .fr-view',
   '.fr-view'].some(function(s){
    var e=main.querySelector(s);
    if(e){var t=txt(e);if(t.length>=40){desc=t;return true;}}
    return false;
  });
  if(desc.length<40){
    var blocks=main.querySelectorAll('div,p,section');
    var best='';blocks.forEach(function(b){
      if(b.children.length>14)return;              // 跳过纯布局容器
      // display:none（含被祖先藏起）的元素：offsetParent 为 null，
      // 此时 innerText 会退化成 textContent，必须跳过
      if(!b.offsetParent)return;
      // 跳过导航/页头/侧栏之类的容器，它们不是作业说明
      var cls=(typeof b.className==='string'?b.className:'')||'';
      if(/nav|menu|tabs|hero|breadcrumb|footer|sidebar|skip|layout/i.test(cls))return;
      var t=txt(b);if(t.length>best.length&&t.length<8000)best=t;});
    if(best.length>desc.length)desc=best;
  }
  // 界面样板行过滤：ManageBac 页面上的固定按钮/标签/单元信息条不是作业内容
  var BOIL=[/^show (more|less)$/i,/^description$/i,/^task description$/i,/^task details$/i,
    /^dropbox$/i,/no dropbox submissions/i,/^upload submission$/i,
    /^discussions?$/i,/^create discussion$/i,/^view all discussions$/i,
    /^no discussions/i,/no discussions have been added/i,
    /^click on one of the buttons below/i,/^starts w\\d/i,/^current unit$/i,
    /^\\d+\\s*(weeks?|days?|months?|hours?)$/i,/^unit\\b/i,/^add (a )?comment$/i,
    /^comments?$/i,/^leave a comment/i,/^download$/i,/^submit$/i,/^cancel$/i,
    /^loading/i,/^mark as complete$/i,/^back to\\b/i,/^print$/i,/^share$/i,
    /^dashboard$/i,/^calendar$/i,/^notifications?$/i,/^my\\b\\s/i,
    /^details$/i,/^task history$/i,/^created\\b/i,/^task grade scale$/i,
    /^members$/i,/^guides$/i,/^chat bot$/i];
  desc=desc.split('\\n').filter(function(ln){
    var s=ln.trim();
    if(!s)return true;
    for(var i=0;i<BOIL.length;i++){if(BOIL[i].test(s))return false;}
    return true;
  }).join('\\n').replace(/\\n{3,}/g,'\\n\\n').trim();
  // 恢复刚才藏掉的节点
  hidden.forEach(function(p){p[0].style.display=p[1];});
  var pm=location.pathname.match(/\\/core_tasks\\/(\\d+)/);
  return JSON.stringify({
    title:h?txt(h).slice(0,200):'',
    text:desc.slice(0,6000),
    meta:meta,
    attachments:links.slice(0,20),
    pageUrl:location.href,
    probe:{id:pm?pm[1]:'',hasCard:!!card,chars:(desc||'').length,
           title:(meta.title||(h?txt(h):'')).slice(0,140)}
  });
})()
"""


def _task_cache_path(url):
    h = hashlib.md5(url.encode("utf-8")).hexdigest()
    return os.path.join(TASKCACHE_DIR, h + ".json")


# ------------------------------------------------------------------ #
#  探针：抓取前后都用它问一句「浏览器现在到底停在谁的页面上」            #
#                                                                     #
#  这是第 17 轮修的那个 bug 的根子：agent-browser 的 open 返回时，页面   #
#  往往还停在上一次访问的任务页（甚至是登录页）上，过一会儿才跳过来。     #
#  老代码只看返回的那一刻，于是把「上一份作业 / 登录页」的内容当成这个    #
#  任务的详情存进缓存 —— 用户看到的就是：点地理的作业，出来的是音乐的。   #
#  现在任何一次详情抓取都必须先等探针确认 id 对上，才允许抓。            #
# ------------------------------------------------------------------ #

_PROBE_JS = """
(function(){
  var m=location.pathname.match(/\\/core_tasks\\/(\\d+)/);
  var card=document.querySelector('.core-task-show, .task-show, .short-assignment.section, .core-task-details');
  var bodyEl=document.querySelector('#content')||document.body;
  var body=(bodyEl.innerText||'').replace(/\\s+/g,' ').trim();
  var titleEl=(card&&card.querySelector('.h4.title, .title'))||document.querySelector('h1');
  return JSON.stringify({
    href: location.href,
    id: m?m[1]:'',
    login: /^\\/login(\\?|$)/.test(location.pathname) || !!document.querySelector('#session_login'),
    hasCard: !!card,
    chars: body.length,
    title: ((titleEl&&titleEl.innerText)||'').trim().slice(0,140)
  });
})()
"""


def _task_id(url):
    m = re.search(r"/core_tasks/(\d+)", (url or ""))
    return m.group(1) if m else ""


def _browser_probe():
    rc, out = ab_eval(_PROBE_JS, timeout=30)
    d = _json_from(out) if rc == 0 else None
    return d if isinstance(d, dict) else {}


def _wait_task_page(url, tries=16, gap=0.35):
    """一直等到浏览器真的停在目标任务页上。

    返回探针结果。等到 id 对上了、页面也有了主体才算了事；任何时候出现
    登录页就直接把探针交回去（掉登录要抢修会话，不是等就能等的）。
    """
    want = _task_id(url)
    info = {}
    for _ in range(tries):
        info = _browser_probe()
        if info.get("login"):
            return info
        if want and (info.get("id") or "") == want:
            # 任务页是 Turbo 换内容的：地址对了，主体偶尔还差半拍
            if info.get("hasCard") or int(info.get("chars") or 0) >= 60:
                return info
        ab(["wait", str(int(gap * 1000))], timeout=40)
    return info


def _taskcache_sweep():
    """清掉历史遗留的「抓错」缓存（登录页 / 别人的任务 / 老格式）。

    没有探针之前存下来的那些详情，正文可能是登录页、也可能是隔壁作业的；
    不删的话用户点开同一张卡，六小时内看到的都是错的。
    """
    bad = 0
    try:
        names = os.listdir(TASKCACHE_DIR)
    except OSError:
        return 0
    for name in names:
        p = os.path.join(TASKCACHE_DIR, name)
        try:
            d = json.load(open(p, encoding="utf-8"))
        except Exception:
            continue
        if not isinstance(d, dict):
            continue
        text = (d.get("text") or "").lower()
        page = d.get("pageUrl") or ""
        want = _task_id(d.get("url") or "")
        got = _task_id(page)
        poison = ("session_login" in text or "forgot your password" in text
                  or (page and not got)                      # 抓到的不是任务页（多半是登录页）
                  or (page and want and got and got != want)  # 抓到的是别的任务
                  or not d.get("probe"))                      # 老格式：没法自证，宁可重抓
        if poison:
            try:
                os.remove(p)
                bad += 1
            except OSError:
                pass
            # 附件也一样：跟着详情一起删，别留下「张冠李戴」的预览文件
            u0 = d.get("url") or ""
            if u0:
                dest = os.path.join(FILES_DIR, hashlib.md5(u0.encode()).hexdigest()[:12])
                shutil.rmtree(dest, ignore_errors=True)
    if bad:
        print("已清掉 %d 份抓错的任务详情缓存（重新访问时按新规则重抓）。" % bad,
              flush=True)
    return bad


def _mb_cookie_header():
    """把存盘的 ManageBac Cookie 拼成 Cookie 头（下附件时带上）"""
    try:
        arr = json.load(open(SESSION_FILE, encoding="utf-8"))
    except Exception:
        return ""
    parts = ["%s=%s" % (c.get("name"), c.get("value"))
             for c in arr if isinstance(c, dict) and c.get("name")]
    return "; ".join(parts)


def _download_file(href, dest_dir, referer):
    """下载单个附件。≤7MB 存盘返回本地路径；更大只回报大小不下载。"""
    os.makedirs(dest_dir, exist_ok=True)
    name = urllib.parse.unquote((href.split("/")[-1] or "attachment").split("?")[0]) or "attachment"
    name = re.sub(r"[\\/:*?\"<>|]", "_", name)[:120]
    req = urllib.request.Request(href, headers={
        "User-Agent": "Mozilla/5.0 (Macintosh) mbboard/1.0",
        "Referer": referer,
    })
    ck = _mb_cookie_header()
    if ck:
        req.add_header("Cookie", ck)
    tmp = dest_dir + "/.part"
    try:
        with urllib.request.urlopen(req, timeout=60) as r:
            total = r.headers.get("Content-Length")
            try:
                total = int(total) if total else None
            except ValueError:
                total = None
            if total and total > FILE_MAX:
                return {"name": name, "href": href, "size": total, "downloaded": False}
            got = 0
            with open(tmp, "wb") as f:
                while True:
                    chunk = r.read(256 * 1024)
                    if not chunk:
                        break
                    got += len(chunk)
                    if got > FILE_MAX:
                        f.close()
                        os.remove(tmp)
                        return {"name": name, "href": href, "size": None, "downloaded": False}
            os.replace(tmp, os.path.join(dest_dir, name))
            return {"name": name, "href": href, "size": got, "downloaded": True,
                    "path": os.path.join(dest_dir, name)}
    except Exception as e:
        try:
            if os.path.exists(tmp):
                os.remove(tmp)
        except OSError:
            pass
        return {"name": name, "href": href, "size": None, "downloaded": False,
                "error": str(e)[:120]}


def task_detail(url):
    """抓一个任务的详情：标题 / 正文 / 附件（≤7MB 预下载）。

    优先吃缓存；抓取与 fetch_data 共用无头浏览器，用 _TASK_LOCK 串行。
    """
    if not url:
        return {"ok": False, "error": "missing url"}
    if not url.startswith("http"):
        url = school_base() + "/" + url.lstrip("/")
    cp = _task_cache_path(url)
    if os.path.exists(cp):
        try:
            d = json.load(open(cp, encoding="utf-8"))
            if time.time() - d.get("ts", 0) < TASK_TTL:
                return d
        except Exception:
            pass
    with _TASK_LOCK:
        # 双检：排队时可能别人已经抓好了
        if os.path.exists(cp):
            try:
                d = json.load(open(cp, encoding="utf-8"))
                if time.time() - d.get("ts", 0) < TASK_TTL:
                    return d
            except Exception:
                pass
        ensure_session()
        why = "抓取失败（页面结构变了？）"
        d = None
        # 最多 3 轮：「打开 → 等到真的是这个任务页 → 抓」。
        # 一轮不成多半是页面还没跟上，直接重开一次，别把上一页的内容交出去。
        for attempt in range(3):
            rc, out = ab(["open", url], timeout=120)
            if rc != 0:
                why = "打不开任务页：" + out[:150]
                break

            info = _wait_task_page(url)
            if info.get("login"):
                # 停在登录页 = 会话没了。抢修一次（别让用户等六小时后再看还是错的）
                ensure_session(force=True)
                ensure_session()
                why = "登录失效，正在重新会话"
                continue
            if not info.get("id") or info.get("id") != _task_id(url):
                why = "页面没跳到这个任务（还停在 %s）" % _short_tail(info.get("href"))
                continue

            got = _task_scrape_once(url)
            if isinstance(got, dict):
                d = got
                break
            why = "页面还没渲染好"
        if not isinstance(d, dict):
            return {"ok": False, "error": why, "url": url}

        dest = os.path.join(FILES_DIR, hashlib.md5(url.encode()).hexdigest()[:12])
        # 附件并发预下载（最多 4 路），显著缩短多附件任务的等待
        hrefs = []
        for a in (d.get("attachments") or []):
            href = a.get("href") or ""
            if not href:
                continue
            if href.startswith("/"):
                href = school_base() + href
            hrefs.append(href)
        atts = []
        if hrefs:
            with ThreadPoolExecutor(max_workers=min(4, len(hrefs))) as ex:
                atts = list(ex.map(lambda h: _download_file(h, dest, referer=url), hrefs))
        d["attachments"] = atts
        d["ok"] = True
        d["url"] = url
        d["pageUrl"] = url          # 已经验过是这一页，落盘前统一，读到的人不必再猜
        d["ts"] = time.time()
        os.makedirs(TASKCACHE_DIR, exist_ok=True)
        try:
            json.dump(d, open(cp, "w", encoding="utf-8"), ensure_ascii=False)
        except Exception:
            pass
        return d


def _short_tail(u, n=60):
    s = (u or "").strip()
    return ("…" + s[-n:]) if len(s) > n else s


def _task_scrape_once(url):
    """抓一次详情。**先验报案**：抓到的页面必须是这个任务的，否则当没抓到。"""
    ab(["wait", "700"], timeout=60)
    rc, out = ab_eval(TASK_SCRAPE_JS, timeout=90)
    if rc != 0:
        return None
    d = _json_from(out)
    if not isinstance(d, dict):
        return None
    want = _task_id(url)
    probe = d.get("probe") if isinstance(d.get("probe"), dict) else {}
    got = str(probe.get("id") or _task_id(d.get("pageUrl") or ""))
    if want and got and got != want:
        # 抓到的是别人的页面 —— 宁可重来，也绝不能给用户看错的东西
        return None
    return d


# ==========================================================================
# Teams 板块（Microsoft Graph）
# ==========================================================================

_TEAMS_MOD = {"m": None, "err": None}


def teams_module():
    """懒加载 teams.py（放在 board/shared，Mac 与 Windows 共用同一套识别规则）。"""
    if _TEAMS_MOD["m"] is not None:
        return _TEAMS_MOD["m"]
    try:
        if SHARED_DIR not in sys.path:
            sys.path.insert(0, SHARED_DIR)
        import teams as _t
        _TEAMS_MOD["m"] = _t
        _TEAMS_MOD["err"] = None
    except Exception as e:                      # 板块失败不影响主服务
        _TEAMS_MOD["err"] = "%s: %s" % (type(e).__name__, e)
        return None
    return _TEAMS_MOD["m"]


_SEIUE_MOD = {"m": None, "err": None}


def seiue_module():
    """懒加载 seiue.py（希悦课表）。单独一份，坏了也不影响别处。"""
    if _SEIUE_MOD["m"] is not None:
        return _SEIUE_MOD["m"]
    try:
        if SHARED_DIR not in sys.path:
            sys.path.insert(0, SHARED_DIR)
        import seiue as _s
        _SEIUE_MOD["m"] = _s
        _SEIUE_MOD["err"] = None
    except Exception as e:
        _SEIUE_MOD["err"] = "%s: %s" % (type(e).__name__, e)
        return None
    return _SEIUE_MOD["m"]


# 「用户已进场」的一次性开关 —— App 收到用户点「让我们开始吧」之后调
# POST /api/ready 把它翻过来。
#
# ★ 为什么需要它 ★
#   后端是 App 一启动就起来的，比开场动画早得多。而 seiue.py 里那几档
#   「去用户的下载 / 桌面 / 文稿里找课表」的扫描一旦在开场就跑，macOS 会
#   立刻弹「想要访问您的下载文件夹」—— 正好盖在快闪 / hello 上。用户的原话：
#       「这种弹窗都要放到用户点击『让我们开始吧』这个按钮之后，
#         不要影响前面动画的观感」
#   所以用户目录的扫描被上了两道锁：① 只有用户主动触发的接口（同步 /
#   导入课表）才会宽扫；② 宽扫还要等这盏灯亮。灯只亮一次，之后全部放行。
_USER_READY = {"on": False, "logged": False}


def mark_user_ready():
    """App 报「用户已进场」。幂等，重复调只记一次日志。"""
    _USER_READY["on"] = True
    m = seiue_module()
    if m is not None:
        try:
            m.mark_user_ready()
        except Exception:
            pass
    if not _USER_READY["logged"]:
        _USER_READY["logged"] = True
        print("用户已进场：放开用户目录（下载 / 桌面 / 文稿）的扫描。", flush=True)
    return True


def user_ready():
    """用户是否已经进场（seiue 侧另有兜底，见 seiue.user_ready）。"""
    if _USER_READY["on"]:
        return True
    m = seiue_module()
    if m is not None:
        try:
            return bool(m.user_ready())
        except Exception:
            pass
    return False


# ── 登录态快照 ────────────────────────────────────────────────────────
# 为什么非要搞这么一层：`mssession.auth_state()` 在令牌缓存为空时会去
# **现场取令牌** —— 那是一条会重载页面、重试十几次的慢路径（最坏几分钟）。
# 它过去是同步塞在 /api/teams 的处理函数里的，于是这个接口动不动就要
# 十几到几十秒才回包。Swift 端超时 20 秒，冷启动必然吃到超时，日志里就是
# 「teams: 请求失败」—— 板块白屏，而用户明明已经登着。
#
# 现在改成：后台线程按时把登录态刷进快照，请求只读快照、**永不阻塞**。
# 快照最多旧 20 秒，对「显示已登录/未登录」这件事完全够用。
AUTH_SNAP = {"ts": 0.0, "val": None, "busy": False}
AUTH_SNAP_LOCK = threading.Lock()
AUTH_TTL = 20.0          # 快照新鲜期；后台线程按这个节奏自己刷


def _auth_fast():
    """最便宜的一份状态：只问「调试端口活着吗」，绝不碰令牌。"""
    m = teams_module()
    up, port, url = False, 0, ""
    if m is not None:
        try:
            up = bool(m.ms.cdp_up())
            port = int(getattr(m.ms, "PORT", 0) or 0)
            url = getattr(m.ms, "TEAMS_URL", "") or ""
        except Exception:
            up = False
    return {"loggedIn": False, "account": "", "granted": [], "missing": [],
            "browserUp": up, "browserPort": port, "browserUrl": url,
            # ★ engine 也在这里带上 ★
            #   冷启动的头 20 秒界面读的是这一份（快照还没刷出来）。要是不带，
            #   用户开看板的第一眼会看到「去找浏览器」而不是「App 内置浏览器」，
            #   然后 20 秒后自己变过来 —— 一条很容易被当成 bug 的闪烁。
            #   engine_online() 只读一个时间戳，不碰浏览器，放在这里零成本。
            "engine": engine_online(),
            "error": "正在读取登录态…", "tokenExpIn": 0, "warmup": True}


def _auth_refresh_job():
    try:
        m = teams_module()
        st = m.ms.status() if m is not None else _auth_fast()
    except Exception as e:
        st = _auth_fast()
        st["error"] = "%s: %s" % (type(e).__name__, e)
    with AUTH_SNAP_LOCK:
        AUTH_SNAP["val"] = st
        AUTH_SNAP["ts"] = time.time()
        AUTH_SNAP["busy"] = False


def auth_snapshot(max_age=AUTH_TTL):
    """请求侧的登录态：**立刻返回**，绝不等待浏览器或网络。

    过了新鲜期就顺手踢一脚后台刷新，但这次仍然把手上这份（可能有点旧）
    给出去 —— 宁可显示一份 20 秒前的状态，也不要让界面转圈转二十秒。
    """
    with AUTH_SNAP_LOCK:
        v = AUTH_SNAP["val"]
        stale = (v is None) or ((time.time() - AUTH_SNAP["ts"]) > max_age)
        if stale and not AUTH_SNAP["busy"]:
            AUTH_SNAP["busy"] = True
            threading.Thread(target=_auth_refresh_job, daemon=True).start()
    if v is not None:
        return v
    return _auth_fast()      # 快照还没出生（服务刚起的那一秒）


def auth_loop():
    """后台常驻：把登录态一直养热，界面来问基本都能直接命中快照。"""
    while True:
        try:
            with AUTH_SNAP_LOCK:
                if AUTH_SNAP["busy"]:
                    time.sleep(1.0)
                    continue
                AUTH_SNAP["busy"] = True
            _auth_refresh_job()
        except Exception:
            pass
        time.sleep(AUTH_TTL)


def auth_kick():
    """标记快照作废，催它立刻重刷（登录 / 退出之后调用）。"""
    with AUTH_SNAP_LOCK:
        AUTH_SNAP["ts"] = 0.0
        if not AUTH_SNAP["busy"]:
            AUTH_SNAP["busy"] = True
            threading.Thread(target=_auth_refresh_job, daemon=True).start()


def ecroster_module():
    """懒加载 ecroster.py（English Corner 名单）。"""
    if _EC_MOD["m"] is not None:
        return _EC_MOD["m"]
    try:
        if SHARED_DIR not in sys.path:
            sys.path.insert(0, SHARED_DIR)
        import ecroster as _e
        _EC_MOD["m"] = _e
        _EC_MOD["err"] = None
    except Exception as e:
        _EC_MOD["err"] = "%s: %s" % (type(e).__name__, e)
        return None
    return _EC_MOD["m"]


_EC_MOD = {"m": None, "err": None}


def ec_local_pdf():
    """本地已经下好的 EC 名单 PDF 路径 —— 有的话就直接开本地文件，秒开。

    用户要求「提前预下载 EC 名单表单储存起来，做到大小看板都是随点随开」，
    所以这里优先返回本地缓存；没有再回落到 SharePoint 链接。
    """
    m = ecroster_module()
    if not m:
        return None
    try:
        info = m.today()
        p = info.get("localPath") or ""
        if p and os.path.exists(p):
            return p
    except Exception:
        pass
    try:
        d = m.CACHE_DIR
        files = [os.path.join(d, f) for f in os.listdir(d)
                 if f.lower().endswith(".pdf")] if os.path.isdir(d) else []
        return max(files, key=os.path.getmtime) if files else None
    except Exception:
        return None


def ec_prefetch():
    """把 EC 名单提前抓下来（下载 + 解析 + 缓存），供开机预热。"""
    m = ecroster_module()
    if not m:
        return {"ok": False, "error": "ecroster 模块没加载成功"}
    try:
        info = m.today(force=True)
        return {"ok": bool(info.get("ok", True)), "file": info.get("file", ""),
                "hasRoster": info.get("hasRoster", False),
                "localPath": info.get("localPath", ""),
                "status": info.get("status", ""),
                "imIn": info.get("imIn", False)}
    except Exception as e:
        return {"ok": False, "error": "%s: %s" % (type(e).__name__, e)}



def _teams_has_content(d):
    """这一份数据算不算「有内容」。空壳（connected=False 或三路全空）不算。"""
    if not isinstance(d, dict):
        return False
    if not d.get("connected"):
        return False
    return bool(d.get("tasks")) or bool(d.get("mail")) or bool(d.get("events"))


def _teams_save(d):
    """把拿到的内容落盘。bridge 重启、或者第一次打开看板时才有东西可显示，
    不至于在后台抓完之前一直白着。"""
    try:
        json.dump({"ts": time.time(), "data": d},
                  open(TEAMS_CACHE, "w", encoding="utf-8"), ensure_ascii=False)
    except Exception:
        pass


def _teams_load():
    """启动时把上次的内容读回来（可能旧，但比空白强）。"""
    try:
        if not os.path.exists(TEAMS_CACHE):
            return
        obj = json.load(open(TEAMS_CACHE, encoding="utf-8"))
        d = obj.get("data")
        if _teams_has_content(d):
            TEAMS["data"] = d
            TEAMS["good"] = d
            TEAMS["ts"] = float(obj.get("ts") or 0)
            TEAMS["goodTs"] = TEAMS["ts"]
            TEAMS["stale"] = True
    except Exception:
        pass


def teams_refresh(wait=False):
    """刷新 Teams 数据。默认丢到后台，绝不阻塞请求。

    最重要的一条规矩：**失败不能清屏**。
    以前只要令牌取不到（浏览器窗口被关、CDP 抖一下、网络超时），
    build_section 就返回一个空板块，这里又老老实实拿它覆盖上次的好数据，
    于是 Teams 板块会毫无征兆地变白 —— 用户最烦的就是这个。
    现在空结果一律不采纳，界面继续显示最后一次有内容的那份，并标成「快照」。
    """
    def job():
        try:
            m = teams_module()
            if not m:
                TEAMS["error"] = "模块加载失败：" + str(_TEAMS_MOD["err"])
                TEAMS["fails"] = int(TEAMS.get("fails") or 0) + 1
                return
            data = m.build_section()
            if _teams_has_content(data):
                TEAMS["data"] = data
                TEAMS["good"] = data
                TEAMS["goodTs"] = time.time()
                TEAMS["ts"] = time.time()
                TEAMS["fails"] = 0
                TEAMS["stale"] = bool(data.get("snapshot"))
                TEAMS["error"] = None
                _teams_save(data)
            else:
                # 这次没抓到东西：保留旧内容，只把失败记下来
                TEAMS["fails"] = int(TEAMS.get("fails") or 0) + 1
                if not TEAMS.get("data"):
                    TEAMS["data"] = data          # 实在没有旧的可留，只能先认下
                TEAMS["stale"] = True
                TEAMS["error"] = (data or {}).get("reason") or TEAMS.get("error") \
                    or "这一轮没拿到数据（网络或登录态在抖）"
        except Exception as e:
            TEAMS["fails"] = int(TEAMS.get("fails") or 0) + 1
            TEAMS["stale"] = True
            TEAMS["error"] = "%s: %s" % (type(e).__name__, e)
        finally:
            TEAMS["fetching"] = False

    if wait:
        TEAMS["fetching"] = True
        job()
        return TEAMS["data"]
    if TEAMS["fetching"]:
        return TEAMS["data"]
    TEAMS["fetching"] = True
    threading.Thread(target=job, daemon=True).start()
    return TEAMS["data"]


def teams_loop():
    """后台常驻：按固定节奏自己刷一遍，不等界面来问。

    界面每次请求都顺手踢一脚刷新，节奏完全被用户的操作牵着走 ——
    点一下刷一次、切个标签又刷一次。这里改成后台自己按时刷，
    界面来了基本都能直接命中缓存，也就不会撞上「正在抓」的空窗。
    """
    while True:
        try:
            time.sleep(20)
            age = (time.time() - TEAMS["ts"]) if TEAMS["ts"] else None
            if TEAMS.get("fetching"):
                continue
            if age is None or age > teams_ttl():
                teams_refresh()
        except Exception:
            time.sleep(30)


def teams_ttl():
    """刷新间隔：连续失败就退避，别在断网时反复打 Graph。"""
    f = int(TEAMS.get("fails") or 0)
    return TEAMS_TTL * min(2 ** f, TEAMS_MAX_BACKOFF) if f else TEAMS_TTL


def teams_payload():
    """给前端的结构：缓存数据 + 元信息；数据过期就顺手踢一脚后台刷新。"""
    age = (time.time() - TEAMS["ts"]) if TEAMS["ts"] else None
    if not TEAMS["fetching"] and (age is None or age > teams_ttl()):
        teams_refresh()

    m = teams_module()
    if m is None:
        logged, auth = False, _auth_fast()
    else:
        # 只读快照 —— 这一句以前是 `m.ms.status()`（现场取令牌），
        # 正是它把 /api/teams 拖到几十秒、让界面吃到超时的。
        auth = auth_snapshot()
        logged = bool(auth.get("loggedIn"))
        # 浏览器被用户关掉了？只要以前连过，就悄悄把它拉回来（不阻塞本次请求）
        try:
            now = time.time()
            # 冷却：拉一次失败就别每次请求都重试，否则看板每隔几秒叫一次，
            # 浏览器会被反复 Popen，Chrome 把 URL 转交给已有实例 → 标签页越堆越多
            cooling = now - float(TEAMS.get("reviveAt") or 0) < 90
            if (not auth.get("browserUp")) and m.ms.has_session() \
                    and not TEAMS.get("reviving") and not cooling:
                TEAMS["reviving"] = True
                TEAMS["reviveAt"] = now

                def _revive():
                    try:
                        m.ms.keep_alive()      # 静默启动：窗口在屏幕外，不打扰用户
                    except Exception as e:
                        # ★ 别静默 ★ 这里失败 = Teams 板块会一直停在「未连接」，
                        #   而原因是「浏览器起不来」或「找不到浏览器」。用户只看到
                        #   一句「没应答」，日志里却什么都没有 —— 没法查。
                        msg = "Teams 浏览器自动拉回失败：%s: %s" % (type(e).__name__, e)
                        print(msg, flush=True)
                        TEAMS["error"] = msg
                    finally:
                        TEAMS["reviving"] = False
                threading.Thread(target=_revive, daemon=True).start()
        except Exception as e:
            print("Teams 保活检查出错：%s: %s" % (type(e).__name__, e), flush=True)

    # 「已登录」不该只看这一刻的缓存：bridge 刚重启、浏览器还没拉起来时
    # 令牌缓存是空的，但磁盘上明明存着上次抓到的内容 —— 那种情况下也该
    # 显示数据视图，而不是把用户晾在一张「去登录」卡片前（他早就登过了）。
    if not logged and TEAMS.get("good"):
        logged = True

    good_ts = float(TEAMS.get("goodTs") or 0)
    return {
        "ok": True,
        "loggedIn": logged,
        # 当前这份是不是「上次抓到的快照」（这一轮没抓到新的）
        "stale": bool(TEAMS.get("stale")) and bool(TEAMS.get("good")),
        "lastGoodSec": int(time.time() - good_ts) if good_ts else None,
        "fails": int(TEAMS.get("fails") or 0),
        "loggingIn": bool(TEAMS.get("loggingIn")),
        "loginMsg": TEAMS.get("loginMsg") or "",
        "loginStep": int(TEAMS.get("loginStep") or 0),
        "loginUrl": "http://127.0.0.1:8765/go/ms-login",
        "browserUp": bool(auth.get("browserUp")),
        "remoteUrl": auth.get("browserUrl") or "",
        "userCode": "",
        "loginClient": auth.get("account") or "",
        "loginAttempt": 0,
        "loginTotal": 0,
        "tried": [],
        "auth": auth,
        "account": (TEAMS["data"] or {}).get("account", "") or auth.get("account", ""),
        "fetching": bool(TEAMS["fetching"]),
        "error": TEAMS["error"],
        "ageSec": int(age) if age is not None else None,
        "authAvailable": m is not None,
        "section": TEAMS["data"],
    }


def teams_start_login():
    """「连接微软账号」：拉起常驻浏览器并等用户在窗口里登进 Teams。

    这条路不注册应用、不走设备码，因此不会撞上 AADSTS65002 / 管理员审批。
    """
    if TEAMS.get("loggingIn"):
        return {"ok": True, "already": True}
    m = teams_module()
    if m is None:
        return {"ok": False, "error": "Teams 模块加载失败：" + str(_TEAMS_MOD["err"])}
    # ★ Teams 这条入口以前**从不触发**浏览器准备 ★
    #   只有 ManageBac 那条路会调 ensure_chrome_async()。于是用户要是跳过了
    #   ManageBac 直接来连 Teams，就必然撞上「找不到 Chrome for Testing」，
    #   屏幕上还没有任何「正在准备」的提示 —— 看起来就是这功能彻底坏了。
    ready, hint = ensure_browser_ready()
    TEAMS["loggingIn"] = True
    TEAMS["error"] = None
    TEAMS["loginMsg"] = "正在打开登录窗口…" if ready else (hint or "正在准备浏览器…")
    TEAMS["loginStep"] = 0
    if not ready:
        # 还没准备好就**不要**往下走：往下走只会拿到一句底层英文报错。
        TEAMS["loggingIn"] = False
        TEAMS["error"] = TEAMS["loginMsg"]
        return {"ok": False, "preparing": True, "msg": TEAMS["loginMsg"]}

    def progress(msg):
        TEAMS["loginMsg"] = msg
        TEAMS["loginStep"] = int(TEAMS.get("loginStep") or 0) + 1

    def job():
        try:
            r = m.ms.connect(on_progress=progress)
            if r and r.get("ok"):
                TEAMS["loginMsg"] = "已连上微软账号"
                TEAMS["error"] = None
            else:
                TEAMS["error"] = (r or {}).get("error") or "登录未完成"
                TEAMS["loginMsg"] = TEAMS["error"]
        except Exception as e:
            TEAMS["error"] = "%s: %s" % (type(e).__name__, e)
            TEAMS["loginMsg"] = TEAMS["error"]
        finally:
            TEAMS["loggingIn"] = False
            teams_refresh(wait=True)
            auth_kick()          # 刚登完，别让界面还盯着 20 秒前那份「未登录」
    threading.Thread(target=job, daemon=True).start()
    return {"ok": True, "started": True}


def teams_skip_login():
    """保留接口：现在的流程已不需要「换通道」，直接当作取消处理。"""
    TEAMS["loginMsg"] = "已取消"
    return {"ok": True, "note": "当前流程不需要切换通道"}


def prefetch_loop():
    """后台常驻：按可调间隔，把「所有待办」的详情+附件提前抓进缓存。

    目的：用户点开任意一张任务卡都是毫秒级（命中缓存），不用再等开页+渲染。
    · 间隔在设置里调（POST /api/prefetch），0 = 关闭；
    · 每 20 秒醒一次检查是否到点，改设置后最迟 20 秒生效；
    · 只补「缓存缺失或超过 3 小时」的，已新鲜的跳过；
    · 每轮最多抓 PREFETCH_MAX_ROUND 个，且不与实时抓取/用户点开抢浏览器。
    """
    while True:
        time.sleep(20)
        try:
            iv = PREFETCH["interval"]
            if iv <= 0:
                continue
            now = time.time()
            if now - PREFETCH["last"] < iv:
                continue
            data = CACHE.get("data") or {}
            if not data.get("loggedIn"):
                continue
            tasks = data.get("tasks") or []
            if not tasks:
                continue
            PREFETCH["last"] = now
            prefetch_tasks(tasks)
        except Exception as e:
            print("预取轮次异常：%s" % e, flush=True)


def prefetch_tasks(tasks):
    """挑出需要补抓的任务（缓存缺失/过期），串行抓完，最多 PREFETCH_MAX_ROUND 个。"""
    todo = []
    for t in tasks:
        u = (t or {}).get("url") if isinstance(t, dict) else None
        if not u:
            continue
        if u.startswith("/"):
            u = school_base() + u
        cp = _task_cache_path(u)
        fresh = False
        if os.path.exists(cp):
            try:
                d = json.load(open(cp, encoding="utf-8"))
                if time.time() - d.get("ts", 0) < PREFETCH_FRESH:
                    fresh = True
            except Exception:
                pass
        if not fresh:
            todo.append(u)
        if len(todo) >= PREFETCH_MAX_ROUND:
            break
    if not todo:
        return
    print("预取：本轮补抓 %d 个任务详情" % len(todo), flush=True)
    for u in todo:
        # 实时抓取进行中就让路（避免和 fetch 抢同一个浏览器会话）
        if REFRESHING.get("on"):
            time.sleep(2)
        try:
            task_detail(u)
        except Exception as e:
            print("预取失败 %s：%s" % (u, e), flush=True)
        time.sleep(0.8)


class Handler(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    server_version = "MBBoard/1.0"

    # ---------- helpers ----------
    def _cors(self):
        self.send_header("Access-Control-Allow-Origin", "*")
        self.send_header("Access-Control-Allow-Methods", "GET, POST, OPTIONS")
        self.send_header("Access-Control-Allow-Headers", "Content-Type, X-MB-Token")
        self.send_header("Access-Control-Max-Age", "86400")

    # ---------- 访客判定 ----------
    # 服务现在监听 0.0.0.0（手表要走 WiFi 直连），于是有副作用的接口要挡一下：
    # 读接口（ping / snapshot / data / health）对局域网开放，写接口只认本机或带令牌的请求。
    def _trusted(self):
        try:
            peer = self.client_address[0]
        except Exception:
            peer = ""
        if peer in ("127.0.0.1", "::1", "::ffff:127.0.0.1"):
            return True
        if TOKEN and self.headers.get("X-MB-Token", "").strip() == TOKEN:
            return True
        return False

    def _json(self, obj, code=200, etag=None):
        body = json.dumps(obj, ensure_ascii=False).encode("utf-8")
        enc = ""
        # gzip：手表每 20 秒拉一次 17 KB 的快照，压完只剩 ~2 KB。
        # URLSession / 浏览器都会自动解压，客户端一行都不用改。
        # 1 KB 以下的不压 —— 压完反而更大，还白花一次 CPU。
        if len(body) > 1024 and "gzip" in (self.headers.get("Accept-Encoding") or "").lower():
            try:
                body = gzip.compress(body, 5)
                enc = "gzip"
            except Exception:
                pass
        self.send_response(code)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        if enc:
            self.send_header("Content-Encoding", enc)
            self.send_header("Vary", "Accept-Encoding")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        if etag:
            self.send_header("ETag", etag)
        self._cors()
        self.end_headers()
        try:
            self.wfile.write(body)
        except Exception:
            pass

    def _text(self, s, code=200):
        body = s.encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", "text/plain; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self._cors()
        self.end_headers()
        try:
            self.wfile.write(body)
        except Exception:
            pass

    def _gif(self):
        """1x1 透明 GIF，用于 file:// 页面探测服务在线状态"""
        body = b"GIF89a\x01\x00\x01\x00\x80\x00\x00\x00\x00\x00\xff\xff\xff!\xf9\x04\x01\x00\x00\x00\x00,\x00\x00\x00\x00\x01\x00\x01\x00\x00\x02\x02D\x01\x00;"
        self.send_response(200)
        self.send_header("Content-Type", "image/gif")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self._cors()
        self.end_headers()
        try:
            self.wfile.write(body)
        except Exception:
            pass

    def _html(self, s, code=200):
        body = s.encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        try:
            self.wfile.write(body)
        except Exception:
            pass

    def _bytes(self, body, ctype, code=200, inline=True):
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        if inline:
            self.send_header("Content-Disposition", "inline")
        self._cors()
        self.end_headers()
        try:
            self.wfile.write(body)
        except Exception:
            pass

    def do_OPTIONS(self):
        self.send_response(204)
        self.send_header("Content-Length", "0")
        self._cors()
        self.end_headers()

    def handle_one_request(self):
        """把「客户端把连接掐了」这种噪音咽掉。

        手表 V2 的地址竞速是「谁先应答用谁，其余立刻取消」，所以经常会出现
        请求刚发出去就被掐掉的情况（还有小组件被系统提前回收时）。
        BaseHTTPRequestHandler 默认会为每次 RST 打一整段 traceback，
        日志里全是噪音，真正有用的那几行反而找不到了。
        """
        try:
            super().handle_one_request()
        except (ConnectionResetError, BrokenPipeError):
            self.close_connection = True

    # ---------- routes ----------
    def do_GET(self):
        touch(from_lan=not self._trusted())
        path = urllib.parse.urlparse(self.path).path
        qs = urllib.parse.parse_qs(urllib.parse.urlparse(self.path).query)

        # ---- 手表端（WiFi 直连）：三个锁外接口，毫秒级 ----
        if path == "/api/ping":
            return self._json(ping_payload())
        if path == "/api/snapshot":
            # 条件请求：手表带上上次拿到的 ETag，内容没变就只回一个 304。
            # 304 不带正文，也就没有 Content-Length —— HTTP/1.1 下这是合法的。
            tag = snapshot_etag()
            if tag and (self.headers.get("If-None-Match") or "").strip() == tag:
                self.send_response(304)
                self.send_header("ETag", tag)
                self.send_header("Cache-Control", "no-store")
                self._cors()
                self.end_headers()
                return
            return self._json(snapshot(), etag=tag)
        if path == "/api/refresh":
            raw = qs.get("max_age", [""])[0]
            try:
                return self._json(request_refresh(float(raw) if raw else None))
            except ValueError:
                return self._json(request_refresh())
        if path == "/api/ready":
            # 「用户已进场」—— App 在用户点下「让我们开始吧」那一刻调的。
            # 放开用户目录（下载 / 桌面 / 文稿）的扫描闸门：在那之前后端只扫
            # 自己的 EXPORT_DIR，绝不列用户的文件夹 —— 否则 macOS 的
            # 「想要访问您的下载文件夹」授权框会直接盖在开场动画上。
            if not self._trusted():
                return self._json({"ok": False, "error": "forbidden"}, 403)
            mark_user_ready()
            return self._json({"ok": True, "ready": True})
        if path == "/api/net":
            # 会暴露主机名 / 内网地址，只给本机看
            if not self._trusted():
                return self._json({"ok": False, "error": "forbidden"}, 403)
            return self._json({"ok": True, "v": VERSION, "port": PORT,
                               "localHostName": local_hostname(),
                               "urls": lan_urls(),
                               "lanOpen": HOST not in ("127.0.0.1", "localhost"),
                               "relay": relay_status(),
                               "idleTimeout": IDLE_TIMEOUT})

        if path == "/api/relay":
            # 中转状态（含 token，所以只给本机看）
            if not self._trusted():
                return self._json({"ok": False, "error": "forbidden"}, 403)
            d = relay_status()
            d["ok"] = True
            return self._json(d)

        # ---- 内置网页引擎：App 里的浏览器来领活 ----
        # ★ 这是 App ↔ 后端之间**唯一**一条 Python 主动、Swift 被动方向的路 ★
        #   其它接口都是 Swift 问、Python 答。这条反过来：Python 把「打开这个
        #   网址」「执行这段脚本」放进队列，App 拿走、做完、把结果塞回来。
        #   好处是不新增端口、不新增协议，出问题 curl 一下就能看见。
        if path == "/api/webengine/poll":
            if we is None:
                return self._json({"cmd": None, "error": "webengine 模块没加载起来"})
            try:
                wait = float(qs.get("wait", ["20"])[0])
            except (TypeError, ValueError):
                wait = 20.0
            wait = max(0.0, min(60.0, wait))
            # 记「有人在线」必须在**等之前**，而且整个等待期间都算数 ——
            # 引擎空闲时一直挂在这里，不记的话业务侧会以为它不在。
            we.note_poll_start()
            try:
                end = time.time() + wait
                while True:
                    c = we.take_pending()
                    if c:
                        return self._json({"cmd": c})
                    if time.time() >= end:
                        return self._json({"cmd": None})
                    time.sleep(0.05)
            finally:
                we.note_poll_end()

        if path == "/api/webengine/state":
            # 引擎状态（本机调试 + 界面展示）
            if we is None:
                return self._json({"ok": False, "error": "webengine 模块没加载起来"})
            on = we.attached()
            d = {"ok": True, "attached": on, "pending": we.pending_count(),
                 "engine": True}
            if on:
                r = we.state()
                d.update({"tabs": r.get("tabs", 0), "urls": r.get("urls", []),
                          "ready": r.get("ready", False)})
            d["chrome"] = chrome_state()
            return self._json(d)

        if path in ("/", "/api/health"):
            return self._json({"ok": True, "service": "ManageBac-Buddy桥接服务", "port": PORT,
                               "v": VERSION, "hasData": bool(CACHE["data"]),
                               "refreshing": bool(REFRESHING["on"]),
                               "urls": (lan_urls() if self._trusted() else []),
                               "components": components(),
                               "idleTimeout": IDLE_TIMEOUT})
        if path == "/api/ping.gif":
            # 1x1 透明 GIF：供 file:// 页面探测服务是否在线（不受 CORS 限制）
            return self._gif()
        if path in ("/app", "/app/"):
            last = None
            for p in (APP_HTML, APP_HTML_FALLBACK):
                try:
                    with open(p, encoding="utf-8") as f:
                        return self._html(f.read())
                except Exception as e:
                    last = e
            return self._html("<h1>找不到看板文件</h1><p>%s</p>" % last, 500)
        if path == "/schedule.pdf":
            # 课表 PDF：优先服务目录内的镜像（服务读不到桌面），退回桌面原文件
            for p in schedule_mirrors() + (SCHEDULE_SRC,):
                try:
                    with open(p, "rb") as f:
                        return self._bytes(f.read(), "application/pdf")
                except Exception:
                    continue
            return self._json({"ok": False, "error": "schedule pdf not found"}, 404)
        if path == "/api/status":
            # 默认读快照（毫秒级）。`probe=1` = 用户在点「重新校验」，
            # 那就现场探一次，最多等 45 秒，超时把手上的先给出去。
            # ⚠️ 这里**不能**再 `with LOCK`：后台抓取一持锁就是两分钟，
            #    检查按钮会在队列里等到客户端超时，界面报「本机服务没起来」。
            probe = qs.get("probe", ["0"])[0] == "1"
            if probe:
                return self._json(status_probe_blocking(20.0))
            return self._json(status_snapshot())
        if path == "/api/data":
            # 兼容旧调用方（桌面看板 / 菜单栏）。锁在 fetch_data 内部按需获取：
            # 有缓存毫秒级返回、无缓存回占位，都**不等**浏览器；只有真正要抓
            # （force=1）才进锁。以前这里把整个调用包进 LOCK，后台一抓取、
            # 所有请求跟着排队，看板冷启动就这么被拖到十几秒。
            force = qs.get("fresh", ["0"])[0] == "1"
            return self._json(fetch_data(force=force))
        if path == "/api/logout":
            with LOCK:
                ab(["open", school_base() + "/logout"], timeout=60)
                CACHE["data"] = None
            return self._json({"ok": True})
        if path == "/go/ms-login":
            # 「连接微软账号」的落地页：把常驻浏览器的 Teams 页拉起来，用户在那里登录
            url = "https://teams.cloud.microsoft/"
            try:
                m = teams_module()
                if m:
                    url = m.ms.TEAMS_URL

                    def _open_login():
                        try:
                            m.ms.ensure_browser()
                            # 保活启动的窗口停在屏幕外，用户看不到就没法登录 —— 搬回来置前
                            m.ms.show_browser()
                        except Exception as e:
                            # ★ 别静默 ★ 这一步失败 = 用户点了「连接微软账号」之后
                            #   什么也没弹出来，屏幕上一点提示都没有，他只会以为
                            #   「这功能坏了」。把原因写进日志，TEAMS["error"] 也同步，
                            #   界面上的状态行就能说清。
                            msg = "打开微软登录窗口失败：%s: %s" % (type(e).__name__, e)
                            print(msg, flush=True)
                            TEAMS["error"] = msg
                            TEAMS["loginMsg"] = msg
                    threading.Thread(target=_open_login, daemon=True).start()
            except Exception as e:
                print("连接微软账号入口出错：%s: %s" % (type(e).__name__, e), flush=True)
            self.send_response(302)
            self.send_header("Location", url)
            self.send_header("Content-Length", "0")
            self.end_headers()
            return
        if path == "/api/task":
            # 任务详情（看板「详情单」用）：抓正文 + 预下载 ≤7MB 的附件
            u = (qs.get("url", [""])[0] or "").strip()
            if not self._trusted():
                return self._json({"ok": False, "error": "forbidden"}, 403)
            return self._json(task_detail(u))
        if path == "/api/prefetch":
            return self._json({"ok": True,
                               "interval": PREFETCH["interval"],
                               "enabled": PREFETCH["interval"] > 0})
        if path == "/api/teams":
            return self._json(teams_payload())
        if path == "/api/seiue":
            # 希悦：状态 + 已缓存的课表。抓取很轻（读页面），所以直接同步返回。
            m = seiue_module()
            if not m:
                return self._json({"ok": False, "error": _SEIUE_MOD.get("err") or "希悦模块没加载成功"})
            try:
                st = m.status()
                data = m.fetch(force=False)
                return self._json({"ok": True, "status": st, "schedule": data})
            except Exception as e:
                return self._json({"ok": False, "error": "%s: %s" % (type(e).__name__, e)})
        if path == "/api/ec/roster":
            # 本地优先：直接把下好的 PDF 吐出来，前端点「看名单」就是秒开
            p = ec_local_pdf()
            if p:
                try:
                    with open(p, "rb") as f:
                        return self._bytes(f.read(), "application/pdf")
                except Exception as e:
                    return self._json({"ok": False, "error": str(e)}, 500)
            return self._json({"ok": False, "error": "本地还没有 EC 名单",
                               "hint": "POST /api/ec/prefetch 先抓一份"}, 404)
        if path == "/api/teams/refresh":
            if not self._trusted():
                return self._json({"ok": False, "error": "forbidden"}, 403)
            teams_refresh()
            return self._json({"ok": True, "started": True})
        if path == "/api/teams/logout":
            if not self._trusted():
                return self._json({"ok": False, "error": "forbidden"}, 403)
            m = teams_module()
            if m:
                try:
                    m.ms.logout()
                except Exception:
                    pass
            TEAMS.update({"data": None, "ts": 0.0, "error": None})
            auth_kick()
            return self._json({"ok": True})
        return self._json({"ok": False, "error": "not found"}, 404)

    def do_POST(self):
        touch()
        path = urllib.parse.urlparse(self.path).path
        # 有副作用的接口（登录 / 退出 / 打开课表）只允许本机：服务已对局域网开放
        if not self._trusted():
            return self._json({"ok": False, "error": "forbidden",
                               "msg": "该操作只允许在电脑本机执行"}, 403)
        length = int(self.headers.get("Content-Length", 0) or 0)
        raw = self.rfile.read(length).decode("utf-8", "ignore") if length else "{}"
        try:
            data = json.loads(raw)
        except Exception:
            data = {}
        if path == "/api/ready":
            # 同 do_GET 里的说明：这是「用户已进场」的闸门。
            mark_user_ready()
            return self._json({"ok": True, "ready": True})
        if path == "/api/prefetch":
            # 设置任务详情预取间隔（秒；0=关）。只允许本机。
            try:
                iv = float(data.get("interval", 1800.0))
            except (TypeError, ValueError):
                iv = 1800.0
            PREFETCH["interval"] = max(0.0, iv)
            if PREFETCH["interval"] <= 0:
                PREFETCH["last"] = time.time()      # 关闭后重新打开，从此刻起算
            _prefetch_save()
            return self._json({"ok": True, "interval": PREFETCH["interval"],
                               "enabled": PREFETCH["interval"] > 0})
        if path == "/api/teams/login":
            # 拉起浏览器完成微软授权；前端轮询 /api/teams 看结果
            return self._json(teams_start_login())

        # ---- 内置网页引擎（见 do_GET 里 /api/webengine/poll 的说明）----
        if path == "/api/webengine/result":
            if we is None:
                return self._json({"ok": False, "error": "webengine 模块没加载起来"})
            cid = str(data.get("id") or "")
            if not cid:
                return self._json({"ok": False, "error": "缺 id"})
            got = we.deliver(cid, bool(data.get("ok")),
                             data.get("value"), data.get("error") or "")
            # got=False 只说明「这一单已经超时走掉了」，不是错误 ——
            # 界面可能刚好在这一刻退出登录，没必要让它报警。
            return self._json({"ok": True, "matched": bool(got)})

        if path == "/api/webengine/call":
            # webengine.py 被当命令行起起来时走这条（bridge 的 _ab_raw 会 fork）。
            # 本进程内的调用直接用内存队列，不经过这里。
            if we is None:
                return self._json({"ok": False, "error": "webengine 模块没加载起来"})
            op = str(data.get("op") or "")
            args = data.get("args") or {}
            if not op:
                return self._json({"ok": False, "error": "缺 op"})
            if not isinstance(args, dict):
                return self._json({"ok": False, "error": "args 必须是对象"})
            # 每种指令的合理等待上限。eval 要跑页面脚本，给得宽一些；
            # 其余都是毫秒级，卡住就说明引擎出问题了，早点报错比干等有用。
            cap = {"eval": 100.0, "open": 70.0, "cookies_set": 45.0,
                   "cookies_get": 30.0, "clear_data": 65.0}.get(op, 35.0)
            try:
                cap = min(cap, float(data.get("timeout") or cap))
            except (TypeError, ValueError):
                pass
            r = we.call(op, timeout=cap, **args)
            r["ok"] = bool(r.get("ok"))
            return self._json(r)
        if path == "/api/browser/prepare":
            # 界面上的「准备浏览器」：一个 Chromium 都没有时手动踢一脚下载。
            # 三条件入口（ManageBac / Teams / 希悦）已会自动触发，这个接口是
            # 给「我就是想先把它准备好」和出错后重试用的。
            ensure_chrome_async()
            return self._json(dict(chrome_state(), ok=True))
        if path == "/api/seiue/login":
            # 拉起希悦登录窗口（专用配置目录，登录态长期保留）
            # 走 open_home：顺带把窗口摆到屏幕正中 + 把下载目录指到我们认得的地方
            m = seiue_module()
            if not m:
                return self._json({"ok": False, "msg": _SEIUE_MOD.get("err") or "希悦模块没加载成功"})
            # 和 Teams 同一个理由：这条入口以前也不触发浏览器准备。
            ready, hint = ensure_browser_ready()
            if not ready:
                return self._json({"ok": False, "preparing": True,
                                   "msg": hint or "正在准备浏览器…"})
            try:
                r = m.open_home()
            except Exception:
                r = {"ok": bool(m.ensure_browser())}
            return self._json(r)
        if path == "/api/seiue/import":
            # 「识别网页导出的课表」：去找用户刚下载的那张 xlsx，直接变成课表。
            # 用户明确要求这条路：不要让人手动拖文件进来。
            m = seiue_module()
            if not m:
                return self._json({"ok": False, "msg": _SEIUE_MOD.get("err") or "希悦模块没加载成功"})
            # 这是用户自己点的按钮 —— 顺带把「已进场」的闸门也推上去，
            # 免得宽扫被闸门挡住（这条接口本来就不可能出现在开场动画之前）。
            mark_user_ready()
            try:
                p = (data.get("path") or "").strip() or None
                r = m.import_exported(p)
                if r.get("ok"):
                    return self._json(r)
                return self._json({"ok": False,
                                   "msg": r.get("error") or "没找到网页导出的课表"})
            except Exception as e:
                return self._json({"ok": False, "msg": "%s: %s" % (type(e).__name__, e)})
        if path == "/api/seiue/sync":
            # 「立即同步」：先替用户点一遍网页上的「导出」（拿整张表），
            # 不成再退回传统的抓页面。
            m = seiue_module()
            if not m:
                return self._json({"ok": False, "msg": _SEIUE_MOD.get("err") or "希悦模块没加载成功"})
            ready, hint = ensure_browser_ready()
            if not ready:
                return self._json({"ok": False, "preparing": True,
                                   "msg": hint or "正在准备浏览器…"})
            # 用户点的同步 —— 同上，把「已进场」闸门推上去。
            mark_user_ready()
            try:
                r = m.sync_now()
                return self._json(r)
            except Exception as e:
                return self._json({"ok": False, "msg": "%s: %s" % (type(e).__name__, e)})
        if path == "/api/seiue/logout":
            m = seiue_module()
            if m:
                try:
                    m.logout()
                except Exception:
                    pass
            return self._json({"ok": True})
        if path == "/api/ec/prefetch":
            # 开机预热 / 手动预下载 EC 名单
            return self._json(ec_prefetch())
        if path == "/api/teams/skip":
            # 当前这条通道被「需要管理员批准」挡住时，用户点一下换下一个客户端
            return self._json(teams_skip_login())
        if path == "/api/login":
            login_name = (data.get("login") or "").strip()
            password = data.get("password") or ""
            remember = bool(data.get("remember", True))
            save = bool(data.get("save", False))
            if not login_name or not password:
                return self._json({"ok": False, "msg": "请填写账号和密码"})
            with LOCK:
                ok, msg = login(login_name, password, remember)
                if ok:
                    mark_session(True)
                    CACHE["data"] = None
                    CACHE["ts"] = 0
                    try:
                        os.remove(CACHE_FILE)
                    except Exception:
                        pass
            saved = False
            savedMsg = ""
            if ok and save:
                # 显式勾选才存：账号 → credentials.json，密码 → macOS 钥匙串
                saved, savedMsg = save_credentials(login_name, password)
            # 立即清掉本地引用
            password = None
            return self._json({"ok": ok, "msg": msg, "saved": saved, "savedMsg": savedMsg,
                               "hasCreds": has_credentials()})
        if path == "/api/forget-creds":
            forget_credentials()
            return self._json({"ok": True, "hasCreds": False,
                               "msg": "已删除本机保存的账号密码"})
        if path == "/api/auto-login":
            # 手动触发一次自动重登（不勾选也能用；有凭证时才有意义）
            with LOCK:
                ok, msg = try_auto_login(force=True)
                if ok:
                    mark_session(True)
                    CACHE["ts"] = 0
            return self._json({"ok": ok, "msg": msg, "session": _session_fields()})
        if path == "/api/open-schedule":
            # 固定用苹果自带「预览」打开课表（不走系统默认程序，避免被 WPS 接管）。
            # 注意：不能直接开桌面原文件 —— 预览由本服务拉起、继承本服务的身份，
            # 而本服务没有「桌面」权限，系统会弹「你没有查看它的权限」。故开服务目录镜像。
            target = schedule_target()
            errs = []
            for flags in (["-b", "com.apple.Preview"], ["-a", "Preview"]):
                try:
                    r = subprocess.run(["/usr/bin/open"] + flags + [target],
                                       capture_output=True, text=True, timeout=15)
                except Exception as e:  # noqa
                    errs.append(str(e)[:100])
                    continue
                if r.returncode == 0:
                    time.sleep(1.0)
                    sized = size_preview_window()      # 尽力调成中号窗口；未授权则保持系统默认
                    return self._json({"ok": True, "how": "preview",
                                       "file": target, "sized": sized})
                errs.append(((r.stderr or "") + (r.stdout or "")).strip()[:100])
            return self._json({"ok": False, "how": "preview",
                               "file": target, "detail": " / ".join(errs)[:200]})
        if path == "/api/logout":
            with LOCK:
                ab(["open", school_base() + "/logout"], timeout=60)
                CACHE["data"] = None
                CACHE["ts"] = 0
            try:
                os.remove(CACHE_FILE)
            except Exception:
                pass
            return self._json({"ok": True})
        return self._json({"ok": False, "error": "not found"}, 404)

    def log_message(self, *a):
        # 默认不记录请求日志（避免任何凭据进入日志）；置 MBBOARD_LOG=1 时用于排查
        if os.environ.get("MBBOARD_LOG"):
            try:
                with open("/tmp/mbboard.access.log", "a", encoding="utf-8") as f:
                    f.write("%s %s\n" % (time.strftime("%H:%M:%S"), " | ".join(str(x) for x in a[1:])))
            except Exception:
                pass

    def log_error(self, *a):
        pass


class Server(socketserver.ThreadingTCPServer):
    allow_reuse_address = True
    daemon_threads = True


def idle_monitor():
    """长时间无人访问时优雅退出，避免常驻后台。

    手表要「一直能连上」就把 MBBOARD_IDLE 设成 0（常驻不退出）：
    否则手表在后台隔十几分钟才醒一次，会踩在服务已经自动退出的空档上。
    """
    while True:
        time.sleep(20)
        limit = idle_limit()
        if limit > 0 and time.time() - LAST_ACTIVITY["t"] > limit:
            print("空闲 %.0f 分钟，自动退出。" % (IDLE_TIMEOUT / 60), flush=True)
            try:
                ab(["close"], timeout=30)   # 优雅关闭浏览器，确保登录 Cookie 落盘
            except Exception:
                pass
            # ↑ 只关掉 agent-browser 管的那个（ManageBac）。Teams / 希悦那两个
            #   是各自带端口和 profile 起的，ab 管不着 —— 之前就是这么漏下来的。
            #   退出前一并收掉，否则它们会变成孤儿继续吃内存，下次启动再攒一茬。
            try:
                k = kill_our_browsers(grace=1.0)
                if k:
                    print("已关闭 %d 个浏览器进程。" % k, flush=True)
            except Exception:
                pass
            time.sleep(0.5)
            os._exit(0)


def seiue_watch_loop():
    """盯着「网页导出的课表」：用户一下载完就自动认出来。

    用户的原话是「不要让用户需要拖拽文件到 APP 直接识别」——所以这一步
    必须是自动的，不能只留一个按钮。每 15 秒看一眼**我们自己的导出目录**
    里有没有**新出现或刚改过**的 xlsx，有就解析一次；同一个文件只处理一次
    （靠 mtime+路径 当指纹），所以不会反复读盘、更不会把用户刚改的课表
    改回去。

    ★ 这里只扫 EXPORT_DIR（窄扫），**不碰用户的下载 / 桌面 / 文稿** ★
      网页导出的表本来就是 _set_download_dir 指到 EXPORT_DIR 的，
      窄扫足够认领，功能一点不损。反过来，要是这个每 15 秒的循环去列
      用户的下载夹，macOS 会弹「想要访问您的下载文件夹」授权框 —— 而且
      因为它每 15 秒跑一次，那个框会反复出现在开场动画上。用户明确要求
      「这种弹窗都要放到用户点击『让我们开始吧』之后」。
      用户的下载夹只在**用户自己点**「同步 / 导入课表」时才去找
      （见 seiue._scan_dirs 的 broad 档）。
    """
    last = ""
    last_err = ""
    while True:
        time.sleep(15)
        try:
            m = seiue_module()
            if not m:
                continue
            stamp = m.download_stamp()
            if not stamp or stamp == last:
                continue
            last = stamp                      # 先记账：解析失败也别每 15 秒重来一次
            r = m.import_exported()
            if r.get("ok"):
                print("希悦：已识别网页导出的课表 %s（%d 节）"
                      % (os.path.basename(r.get("file") or ""), len(r.get("lessons") or [])),
                      flush=True)
                # 顺手把课表推给手表/中继，别让它一直显示上一份
                try:
                    relay_push()
                except Exception as e:
                    print("希悦：推送中继失败：%s: %s" % (type(e).__name__, e), flush=True)
            else:
                # 不 ok 也要说话：以前这里一声不吭，用户「导出了课表却没被识别」
                # 只能看到「什么都没发生」。
                print("希悦：认出了新导出的课表文件但没解析成功：%s"
                      % (r.get("msg") or r.get("error") or ""), flush=True)
        except Exception as e:
            # ★ 别静默 ★ 这个循环每 15 秒跑一次，出错时**必须**留下痕迹，
            #   否则「自动识别课表时好时坏」永远查不出来。
            #   但也不能每 15 秒刷一行同样的错 —— 只在错误内容变化时打一行，
            #   第一次出现时一定打。
            msg = "%s: %s" % (type(e).__name__, e)
            if msg != last_err:
                last_err = msg
                print("希悦：自动识别课表这一轮出错（后续同样的错不再重复打印）：%s" % msg,
                      flush=True)


def main():
    load_cache()
    load_relay()
    quota_load()
    _teams_load()          # 先把上次抓到的 Teams 内容读回来，别让板块开局是白的
    # 开局先把上一条命留下的孤儿浏览器收掉：它们白占着内存，攒多了会把
    # 看板 App 一起拖进 Jetsam（= 用户看到的「应用时常闪退」）。
    try:
        n = reap_orphan_browsers()
        if n:
            print("已回收 %d 个上次遗留的浏览器进程。" % n, flush=True)
    except Exception:
        pass
    print("ManageBac-Buddy桥接服务已启动： http://127.0.0.1:%d" % PORT, flush=True)
    if HOST in ("127.0.0.1", "localhost"):
        print("⚠️ 只监听本机（MBBOARD_HOST=%s）：手表走 WiFi 连不上，改成 0.0.0.0" % HOST, flush=True)
    else:
        print("手表 WiFi 直连地址（在手表 App 里会自动探测，一般不用手填）：", flush=True)
        for u in lan_urls():
            print("   %s" % u, flush=True)
    if RELAY["on"]:
        print("云端中转已启用：%s（抓完即推，平时每 %.0f 秒心跳；"
              "24 小时额度还剩 %d 条）" % (RELAY["url"], RELAY["every"], quota_left()),
              flush=True)
        threading.Thread(target=relay_loop, daemon=True).start()
    else:
        print("云端中转未启用（缺 %s）；手表只有在同一 WiFi 下才连得上。" % RELAY_FILE, flush=True)
    print("浏览器: %s" % (chrome_path() or "(还没找到，将在需要时自动准备)"), flush=True)
    if IDLE_TIMEOUT <= 0:
        print("常驻模式：不因空闲退出（MBBOARD_IDLE=0）。", flush=True)
    elif RELAY["on"]:
        print("常驻模式：云端中转开着，不停机（否则手表在外网会取不到数据）。", flush=True)
    else:
        print("空闲 %.0f 分钟后自动退出。" % (IDLE_TIMEOUT / 60), flush=True)
    threading.Thread(target=idle_monitor, daemon=True).start()
    threading.Thread(target=selfheal_loop, daemon=True).start()
    threading.Thread(target=auth_loop, daemon=True).start()
    threading.Thread(target=status_loop, daemon=True).start()
    threading.Thread(target=teams_loop, daemon=True).start()
    threading.Thread(target=seiue_watch_loop, daemon=True).start()
    _prefetch_load()
    threading.Thread(target=prefetch_loop, daemon=True).start()
    print("任务详情预取：每 %.0f 分钟一轮（0=关，设置里可调）。" % (PREFETCH["interval"] / 60),
          flush=True)
    with Server((HOST, PORT), Handler) as httpd:
        httpd.serve_forever()


if __name__ == "__main__":
    main()
