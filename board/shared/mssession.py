#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
微软会话层（替代 msauth 的「设备码 / 借客户端」路线）

原理
    Chrome for Testing 用一个**专用配置目录**常驻登录 Teams 网页版。
    网页版内部用 MSAL 把各资源的访问令牌缓存在页面 localStorage 里（含 Graph）。
    本模块通过 CDP 从页面里取出 Graph 令牌，直接调用 Microsoft Graph。

为什么这样做
    · 令牌是用户**在浏览器里正常登录**得到的，不是脚本自己申请的应用，
      因此不触发 AADSTS65002，也**不需要管理员批准**。
    · 令牌由网页版自己续期；过期时重载页面即可重新取到。
    · 纯标准库实现（自带极简 WebSocket 客户端），Mac / Windows 通用。

对外接口
    ensure_browser()      确保浏览器在跑并停在 Teams 页
    token(force=False)    取 Graph 访问令牌（缓存，快过期自动刷新）
    graph(path)           GET 一次 Graph
    graph_paged(path)     自动翻页
    capabilities()        依据令牌实际权限判断哪几条数据源可用
    auth_state()          给界面用的登录态
    reset()               丢弃缓存（退出登录用）
"""

import base64
import json
import os
import signal
import socket
import struct
import subprocess
import sys
import threading
import time
import urllib.error
import urllib.parse
import urllib.request

HOME = os.path.expanduser("~")
# 数据目录：App 分发版会把 MBBOARD_DATA 指到 ~/Library/Application Support 下，
# 开发机不设它、继续用 ~/.mbboard —— 两种场景共用同一份代码。
MBB = os.environ.get("MBBOARD_DATA") or os.path.join(HOME, ".mbboard")
PROFILE = os.path.join(MBB, "teams-profile")


def _debug_port(scope, fallback):
    """把浏览器调试端口跟着**数据目录**派生出来。

    以前这里是写死的 9223。写死的后果很隐蔽：换一个数据目录之后，新进程
    一探端口发现有 Chrome 在听，就直接连上去 —— 连的却是**上一个数据目录**
    的 profile。表现出来就是「明明清空了自己的数据，Teams 却还登着」，
    而老浏览器一被关掉，立刻又变成未登录，怎么查都查不出原因。
    派生之后两份数据天然各用各的端口，互不串门。

    范围取 9400–9799：绕开 9222/9223/9224 这些被各种调试工具默认占用的号。
    """
    try:
        import zlib
        key = os.path.abspath(MBB) + "|" + scope
        return 9400 + (zlib.crc32(key.encode("utf-8")) % 400)
    except Exception:
        return fallback


PORT = _debug_port("teams", 9223)
TEAMS_URL = "https://teams.cloud.microsoft/"
GRAPH = "https://graph.microsoft.com/v1.0"

_MAC_CHROME = os.path.join(MBB, "chrome", "Google Chrome for Testing.app",
                           "Contents", "MacOS", "Google Chrome for Testing")
_WIN_CHROME = os.path.join(MBB, "chrome", "chrome.exe")

TIMEOUT_HTTP = 30

_lock = threading.RLock()
_CACHE = {"token": "", "exp": 0, "scp": "", "upn": "", "at": 0.0}
_LAST_ERR = {"msg": ""}

# 只要曾经登录成功过，就留一个标记；看板据此决定要不要自动把浏览器拉起来
MARKER = os.path.join(MBB, ".teams-session")


def has_session():
    return os.path.exists(MARKER)


def remember_session():
    try:
        os.makedirs(MBB, exist_ok=True)
        with open(MARKER, "w") as f:
            f.write(json.dumps({"upn": _CACHE["upn"], "at": time.time()}))
    except Exception:
        pass


def forget_session():
    try:
        os.remove(MARKER)
    except Exception:
        pass


# ==========================================================================
# 一、极简 WebSocket 客户端（只做 CDP 需要的那点事）
# ==========================================================================

class _WS(object):
    def __init__(self, host, port, path, timeout=20):
        self.buf = b""
        self.s = socket.create_connection((host, port), timeout=timeout)
        self.s.settimeout(timeout)
        key = base64.b64encode(os.urandom(16)).decode()
        req = ("GET %s HTTP/1.1\r\nHost: %s:%d\r\nUpgrade: websocket\r\n"
               "Connection: Upgrade\r\nSec-WebSocket-Key: %s\r\n"
               "Sec-WebSocket-Version: 13\r\n\r\n" % (path, host, port, key))
        self.s.sendall(req.encode())
        while b"\r\n\r\n" not in self.buf:
            chunk = self.s.recv(4096)
            if not chunk:
                raise IOError("CDP 连接被关闭")
            self.buf += chunk
        head, self.buf = self.buf.split(b"\r\n\r\n", 1)
        if b" 101 " not in head.split(b"\r\n")[0]:
            raise IOError("WebSocket 握手失败")

    def _read(self, n):
        while len(self.buf) < n:
            chunk = self.s.recv(max(4096, n - len(self.buf)))
            if not chunk:
                raise IOError("CDP 连接被关闭")
            self.buf += chunk
        out, self.buf = self.buf[:n], self.buf[n:]
        return out

    def send(self, text):
        data = text.encode("utf-8")
        hdr = bytearray([0x81])
        n = len(data)
        if n < 126:
            hdr.append(0x80 | n)
        elif n < 65536:
            hdr.append(0x80 | 126)
            hdr += struct.pack(">H", n)
        else:
            hdr.append(0x80 | 127)
            hdr += struct.pack(">Q", n)
        mask = os.urandom(4)
        hdr += mask
        self.s.sendall(bytes(hdr) + bytes(b ^ mask[i % 4] for i, b in enumerate(data)))

    def recv(self):
        while True:
            b0, b1 = self._read(2)
            op = b0 & 0x0F
            masked = b1 & 0x80
            ln = b1 & 0x7F
            if ln == 126:
                ln = struct.unpack(">H", self._read(2))[0]
            elif ln == 127:
                ln = struct.unpack(">Q", self._read(8))[0]
            mask = self._read(4) if masked else None
            payload = self._read(ln)
            if mask:
                payload = bytes(b ^ mask[i % 4] for i, b in enumerate(payload))
            if op == 0x8:
                raise IOError("WebSocket 已关闭")
            if op in (0x9, 0xA):
                continue
            if op in (0x1, 0x2):
                return payload.decode("utf-8", "replace")

    def close(self):
        try:
            self.s.close()
        except Exception:
            pass


# ==========================================================================
# 二、CDP 小工具
# ==========================================================================

def _http_json(url, timeout=4):
    req = urllib.request.Request(url, headers={"Host": "127.0.0.1:%d" % PORT})
    with urllib.request.urlopen(req, timeout=timeout) as r:
        return json.loads(r.read().decode("utf-8", "replace"))


def cdp_up():
    """调试端口是否活着。"""
    try:
        _http_json("http://127.0.0.1:%d/json/version" % PORT)
        return True
    except Exception:
        return False


def pages():
    try:
        return [t for t in _http_json("http://127.0.0.1:%d/json/list" % PORT)
                if t.get("type") == "page"]
    except Exception:
        return []


def teams_page():
    """优先返回 Teams 页面，没有就返回任意页面。"""
    ps = pages()
    for p in ps:
        if "teams." in (p.get("url") or ""):
            return p
    return ps[0] if ps else None


def _browser_cmd(method, params=None, timeout=8):
    """在**浏览器级** WebSocket 上发一条 CDP 命令（页面级的用 _eval）。

    用来搬窗口位置：Browser.getWindowForTarget / Browser.setWindowBounds /
    Target.activateTarget 都在浏览器域里。走 CDP 而不是 AppleScript，
    是因为 CDP 不需要「自动化控制」系统授权，不会弹权限框。
    """
    try:
        ver = _http_json("http://127.0.0.1:%d/json/version" % PORT)
        wsurl = ver.get("webSocketDebuggerUrl")
    except Exception:
        return None
    if not wsurl:
        return None
    u = urllib.parse.urlparse(wsurl)
    ws = _WS(u.hostname, u.port or PORT, u.path, timeout=timeout)
    try:
        ws.send(json.dumps({"id": 1, "method": method, "params": params or {}}))
        end = time.time() + timeout
        while time.time() < end:
            msg = ws.recv()
            if msg is None:
                break
            try:
                data = json.loads(msg)
            except Exception:
                continue
            if data.get("id") == 1:
                return data.get("result")
        return None
    except Exception:
        return None
    finally:
        ws.close()


def _window_of(page):
    info = _browser_cmd("Browser.getWindowForTarget", {"targetId": page.get("id")})
    return (info or {}).get("windowId")


def _move_window(left, top, width=1200, height=860):
    page = teams_page()
    if not page:
        return False
    wid = _window_of(page)
    if wid is None:
        return False
    _browser_cmd("Browser.setWindowBounds", {
        "windowId": wid,
        "bounds": {"left": left, "top": top, "width": width, "height": height,
                   "windowState": "normal"}})
    return True


# 「用户正在这个窗口上登录」的窗口期。在这段时间里任何后台保活都不许再
# 把窗口藏起来 —— 否则用户刚拉回来的窗口会在几秒内又被最小化，
# 表现就是「点了连接，窗口闪一下就不见了」。
_HOLD = {"until": 0.0}


def hold_window(seconds=1800):
    """声明「接下来这段时间别动这个窗口」。"""
    _HOLD["until"] = time.time() + seconds


def holding():
    return time.time() < _HOLD["until"]


def _screen_size(page):
    """浏览器所在那块屏幕的可用尺寸（减掉菜单栏 / Dock）。

    为什么要问页面要：Chrome 的 setWindowBounds 只接受坐标，不给屏幕尺寸；
    而写死一组坐标在 13 寸和 32 寸屏上完全是两种结果。
    """
    try:
        raw = _eval(page, "JSON.stringify({w: screen.availWidth, h: screen.availHeight})", timeout=6)
        d = json.loads(raw or "{}")
        w, h = int(d.get("w") or 0), int(d.get("h") or 0)
        if w > 400 and h > 300:
            return w, h
    except Exception:
        pass
    return 1440, 900


def _unpark_window(width=1180, height=860, page=None):
    """把窗口搬回屏幕**正中**、恢复 normal 并置前。

    ★ 这里踩过一个很坑的 bug：以前只调一次 setWindowBounds，而且用的是
      写死的 (140,110)。窗口当时是 `minimized` —— 最小化状态下 Chrome 会
      **丢掉** bounds 里的 left/top，只改尺寸，窗口仍旧最小化/仍旧停在
      屏幕外那条 -1160 的老坐标上。用户点完「打开浏览器登录」看到的，
      是一个贴在屏幕最左边、只露一条边的窗口，根本没法在上面登录。
      现在：① 先 normal 再挪、② 位置按真实屏幕尺寸算居中、③ 挪完再
      normal 一次并置前，每一步之间留出 React/AppKit 处理的时间。

    page 必须由调用方给：这个函数有两个使用者（Teams 与希悦），
    各自有各自的页面，写死成 teams_page() 会让希悦那边摆错窗口。
    """
    page = page or teams_page()
    if not page:
        return False
    wid = _window_of(page)
    if wid is None:
        return False
    sw, sh = _screen_size(page)
    left = max(0, int((sw - width) / 2))
    top = max(30, int((sh - height) / 2))
    sw2, sh2 = max(width, min(sw - 20, sw)), max(height, min(sh - 60, sh))

    def _set(state):
        _browser_cmd("Browser.setWindowBounds", {
            "windowId": wid,
            "bounds": {"left": left, "top": top,
                       "width": min(width, sw2), "height": min(height, sh2),
                       "windowState": state}})

    _set("normal")            # ① 必须先脱离 minimized，否则下面的坐标会被忽略
    time.sleep(0.35)
    _set("normal")            # ② 真正落位
    time.sleep(0.35)
    _browser_cmd("Target.activateTarget", {"targetId": page.get("id")})
    hold_window(1800)         # ③ 半小时内保活不许再藏它
    return True


def _park_window():
    """把窗口彻底从桌面消失。

    只用「移到屏幕外」是不够的：macOS 会把窗口坐标夹回来（必须留一条
    在屏内、顶部不得高于菜单栏），实测 -3200,-3200 会被夹成 -1160,33，
    右边永远露一条 ~40px，非常难看。

    所以这里改成 **最小化**（windowState=minimized）：最小化窗口完全
    不占桌面，只在 Dock 里缩成一个小窗。流程：先确保 normal（最小化
    状态下不能改 bounds），挪到远处，再最小化。三步里最后一步才是
    关键，前两步只是兜底（万一某些系统版本不支持直接最小化）。
    """
    page = teams_page()
    if not page:
        return False
    if holding():
        # 用户正在窗口上登录，任何「藏窗口」的调用都直接放弃 —— 见 hold_window
        return False
    wid = _window_of(page)
    if wid is None:
        return False

    def _bounds(params):
        return _browser_cmd("Browser.setWindowBounds", params)

    # ① 若已是最小化，直接视为已隐藏
    info = _browser_cmd("Browser.getWindowForTarget", {"targetId": page.get("id")}) or {}
    if (info.get("bounds") or {}).get("windowState") == "minimized":
        return True
    # ② 挪远（能挪多远挪多远，被夹了也无妨）
    _bounds({"windowId": wid,
             "bounds": {"left": -3200, "top": -3200,
                        "width": 1200, "height": 860,
                        "windowState": "normal"}})
    # ③ 最小化 —— 窗口从桌面彻底消失
    r = _bounds({"windowId": wid, "bounds": {"windowState": "minimized"}})
    return r is not None


def _window_state():
    """当前 Teams 页所在窗口的状态（normal/minimized/...；拿不到返回 None）。"""
    page = teams_page()
    if not page:
        return None
    info = _browser_cmd("Browser.getWindowForTarget", {"targetId": page.get("id")}) or {}
    return (info.get("bounds") or {}).get("windowState")


def _eval(page, expression, timeout=20, await_promise=True):
    """在指定页面里执行 JS，返回其中的值（字符串）。"""
    u = urllib.parse.urlparse(page["webSocketDebuggerUrl"])
    ws = _WS(u.hostname, u.port or PORT, u.path, timeout=timeout)
    try:
        ws.send(json.dumps({
            "id": 1, "method": "Runtime.evaluate",
            "params": {"expression": expression, "returnByValue": True,
                       "awaitPromise": await_promise},
        }))
        end = time.time() + timeout
        while time.time() < end:
            msg = json.loads(ws.recv())
            if msg.get("id") == 1:
                if msg.get("error"):
                    raise IOError(str(msg["error"])[:200])
                res = (msg.get("result") or {}).get("result") or {}
                if (msg.get("result") or {}).get("exceptionDetails"):
                    raise IOError("页面 JS 报错")
                return res.get("value")
        raise IOError("CDP 执行超时")
    finally:
        ws.close()


def _open_url_in_browser(url):
    """让已在运行的浏览器新开一个标签页到指定地址。"""
    target = "http://127.0.0.1:%d/json/new?%s" % (PORT, urllib.parse.quote(url, safe=""))
    for method in ("PUT", "GET"):          # 新版 Chrome 只认 PUT
        try:
            req = urllib.request.Request(target, method=method)
            with urllib.request.urlopen(req, timeout=6) as r:
                r.read()
            return True
        except Exception:
            continue
    return False


# ==========================================================================
# 三、浏览器生命周期
# ==========================================================================

def chrome_path():
    for p in (_MAC_CHROME, _WIN_CHROME):
        if os.path.exists(p):
            return p
    return None


def chrome_app():
    """Chrome for Testing 的 .app 路径（`open -g` 要的是 App，不是二进制）"""
    p = os.path.join(MBB, "chrome", "Google Chrome for Testing.app")
    return p if os.path.exists(p) else None


def _clear_stale_locks():
    """清掉上次异常退出留下的 profile 锁。

    Chrome 用 SingletonLock / SingletonSocket / SingletonCookie 这三个软链
    保证「同一个配置目录只跑一个实例」。进程被强杀（或崩溃）时锁会留在原地，
    新实例启动时先看到锁，以为「已经有一个在跑」，就把自己的启动参数
    转交给那个**并不存在**的实例，然后自己退出。

    表现就是：怎么拉都拉不起来，进程数 0、调试端口不通，
    而 open 命令的返回码还是 0（看着像成功）。实测踩过一次，
    排查起来非常费劲 —— 所以启动前先扫掉这三个软链。
    """
    for n in ("SingletonLock", "SingletonSocket", "SingletonCookie"):
        p = os.path.join(PROFILE, n)
        try:
            if os.path.islink(p) or os.path.exists(p):
                os.remove(p)
        except Exception:
            pass


def _stale_procs():
    """用了这个配置目录、但调试端口不通的残留 Chrome 进程。"""
    try:
        out = subprocess.run(["pgrep", "-f", PROFILE],
                             stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
                             text=True).stdout
        return [int(x) for x in out.split() if x.strip().isdigit()]
    except Exception:
        return []


def launch_browser(url=TEAMS_URL, quiet=False):
    """起一个带专用配置目录的 Chrome。已登录状态会一直保存在这个目录里。

    quiet=True 给保活线程用：窗口直接放到屏幕外，并用 `open -g` 后台拉起
    （不抢焦点）。保活是用户看不见的后台动作，要是把窗口怼到屏幕中间，
    用户正在看板前面坐着，就会觉得「打开看板怎么又弹出 Teams 网页了」。
    """
    exe = chrome_path()
    if not exe:
        _LAST_ERR["msg"] = "找不到 Chrome for Testing"
        return False
    try:
        os.makedirs(PROFILE, exist_ok=True)
    except Exception:
        pass
    # 僵尸残留会让新实例「转交参数后自己退出」，先清干净（详见 _clear_stale_locks）
    if not cdp_up():
        stale = _stale_procs()
        for pid in stale:
            try:
                os.kill(pid, signal.SIGTERM)
            except Exception:
                pass
        if stale:
            time.sleep(2)
        _clear_stale_locks()
    args = [exe,
            "--user-data-dir=" + PROFILE,
            "--remote-debugging-port=%d" % PORT,
            "--no-first-run", "--no-default-browser-check",
            # ★ 这一组是「看板 App 被系统杀掉」的解药，别再删 ★
            #   这个浏览器常年挂在后台（保活 + 自愈 + 抓取），而 Teams 是个
            #   重前端。默认情况下 Chromium 会按 CPU 核数给每个标签页起一套
            #   渲染进程，页数一多内存就顶到 jetsam —— 实测的
            #   JetsamEvent 里，看板 App 和一大串 Chrome Helper 是**同时**
            #   被杀的，用户看到的正是「应用时常闪退」。
            #   这里把渲染进程数和单个渲染进程的堆都封顶：
            #   · renderer-process-limit：最多 2 个渲染进程，同站点会复用；
            #   · max-old-space-size：单个渲染进程的 JS 堆上限；
            #   · 关掉扩展/组件更新/预取这些后台服务，少一堆常驻进程。
            "--renderer-process-limit=2",
            "--js-flags=--max-old-space-size=384",
            "--disable-extensions", "--disable-component-update",
            "--disable-background-networking", "--disable-sync",
            "--no-service-autorun", "--disable-domain-reliability",
            "--disable-features=Translate,MediaRouter,OptimizationHints,"
            "InterestFeedContentSuggestions,CalculateNativeWinOcclusion"]
    if quiet:
        # 屏幕外 + 固定尺寸：既不挡看板，也不会跳出来闪一下
        args += ["--window-position=-3200,-3200", "--window-size=1200,860"]
    args.append(url)
    kwargs = {"stdout": subprocess.DEVNULL, "stderr": subprocess.DEVNULL}
    used_open = False
    try:
        app = chrome_app()
        if quiet and app:
            # open -g（--background）：不把 App 激活到前台
            r = subprocess.run(["open", "-g", "-a", app, "--args"] + args[1:],
                               stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            used_open = (r.returncode == 0)
        if not used_open:
            if os.name == "nt":
                kwargs["creationflags"] = 0x00000008 | 0x00000200
            else:
                kwargs["start_new_session"] = True
            subprocess.Popen(args, **kwargs)
    except Exception as e:
        _LAST_ERR["msg"] = "启动浏览器失败：%s" % e
        return False

    def wait_cdp(secs):
        for _ in range(secs):
            time.sleep(1)
            if cdp_up():
                return True
        return False

    if wait_cdp(10):
        if quiet:
            _park_window()          # 参数万一没吃住，再用 CDP 兜一次
        else:
            _unpark_window()        # 用户要在这里登录 —— 摆到屏幕正中
        return True
    if used_open:
        # open -g 在「同款 App 已经有一个实例在跑」时只会去激活旧实例、
        # 不带我们的参数 —— 那这 10 秒白等了，直接执行二进制把这套参数起起来。
        # （实测就是这么个结果：open 返回 0 但端口不通，兜底 Popen 1 秒后就通）
        try:
            if os.name != "nt":
                kwargs["start_new_session"] = True
            subprocess.Popen(args, **kwargs)
        except Exception:
            pass
        if wait_cdp(20):
            if quiet:
                _park_window()
            else:
                _unpark_window()
            return True
    _LAST_ERR["msg"] = "浏览器起来了但调试端口不通"
    return False


def dedupe_pages():
    """同一个 Teams 页只留一个、登录中间页最多留一个，其余关掉。返回关掉了几个。

    浏览器被反复拉起来时，Chrome 会把「启动参数里那个 URL」转交给**已有实例**，
    于是每拉一次就多开一个「团队」标签页 —— 用户那边曾经堆到 8 个，
    标签栏一整排全是 Teams。保活时顺手清一遍，别让它越堆越多。

    ★ 为什么连登录页也一起收 ★
    `connect()` / 保活发现「当前没有一个 Teams 页」时会再开一个新标签，于是
    用户每点一次「连接」就多一页；而 login.live.com/ppsecure/post.srf、
    AAD 的 /common/login 这类**续页**自己永远不会恢复，就一直挂在那儿。
    每一页都带一整套渲染进程，页数一多内存就顶到 jetsam —— 实测看板 App
    正是因此被 macOS 一起杀掉，用户看到的是「应用时常闪退」。所以两类都收：
    **Teams 页留一个；能用的登录页最多留一个**（用户可能正在上面输密码）；
    卡死的续页交给 show_browser 就地导回首页，不在这里关（关了可能一页不剩）。
    """
    ps = pages()
    teams = [p for p in ps if "teams." in (p.get("url") or "")]
    logins = [p for p in ps if _is_login_page(p.get("url") or "")
              and not _is_dead_login(p.get("url") or "")]
    # 卡死的续页不算「可用登录页」：它占着一个名额却不干正事
    doomed = teams[1:] + logins[1:]
    closed = 0
    for p in doomed:
        if _close_page(p.get("id")):
            closed += 1
    return closed


# 登录半途会停在这么几种「POST 续页」上：它们本身不是一个能操作的登录表单，
# 打开只会看到一句报错（比如「输入 Microsoft 账户的密码。」），用户在上面
# **完全没法登录**。出现这些就说明上一次登录流程被打断在半路，
# 唯一可靠的做法是回 Teams 首页重新走一遍（cookie 还在，多数情况一步就进）。
_DEAD_LOGIN = (
    "post.srf",            # login.live.com/ppsecure/post.srf（旧式 POST 续页）
    "login.live.com",
    "ppsecure",
    "kmsi",
    "convertto",
    # AAD 的「裸」登录端点：用 GET 打开它只会得到
    #   AADSTS900561: The endpoint only accepts POST requests. Received a GET request.
    # 因为这个地址本来只接受 POST（正常流程里由授权页自己 POST 过来）。
    # 用户点登录时窗口就停在这张报错页上，既看不懂也点不动。
    # 注意它**不含** "oauth2" —— 真正的授权页是
    #   login.microsoftonline.com/<tenant>/oauth2/v2.0/authorize?...
    # 所以不会误伤正常登录流程。
    "/common/login",
    "/organizations/login",
    "aadsts",
)


def _is_login_page(url):
    """是不是「微软登录 / 授权」这一族的页面（含各种中间续页）。"""
    return any(k in (url or "") for k in (
        "login.microsoftonline.com", "login.microsoft.com",
        "login.live.com", "login.windows.net",
        "microsoftonline.com", "msftauth",
    ))


def _is_dead_login(url):
    """是不是「卡在半路、自己永远不会恢复」的登录续页。"""
    return any(k in (url or "") for k in _DEAD_LOGIN)


def _close_page(tid):
    """关掉一个标签页。走 CDP；HTTP /json/close 在新版 Chrome 上会假装成功。"""
    r = _browser_cmd("Target.closeTarget", {"targetId": tid})
    if r and r.get("success"):
        return True
    for method in ("PUT", "GET"):
        try:
            req = urllib.request.Request(
                "http://127.0.0.1:%d/json/close/%s" % (PORT, tid), method=method)
            urllib.request.urlopen(req, timeout=4).read()
            return True
        except Exception:
            continue
    return False


def show_browser(page=None, home=None, dead=_DEAD_LOGIN, width=1180, height=860):
    """把专用浏览器窗口从屏幕外搬回屏幕正中并置前，顺带救活卡死的登录页。

    只在用户**主动**点「连接 / 重新登录」时调：保活是静默启动的，
    窗口停在屏幕外，用户根本看不到，也就没法在上面登录。

    dead 的默认值就是 `_DEAD_LOGIN` —— 不能写成 None：本函数唯一的调用点
    （launch_browser 里那句 `show_browser()`）是无参调用，默认值一旦丢了，
    「卡在微软登录续页上时自动救回来」那个功能就悄悄失效了。
    留出这三个参数是为了同一份逻辑别被复制第二遍（希悦有自己的窗口，
    它走 seiue.py 里自己那份）。

    ★ 救回动作是「就地导航」，不是「再开一个标签」★
    以前只挑一个页面看它是不是死页，其余的死页原地留着；而 `connect()`
    发现「没有 Teams 页」时又会新开一个标签 —— 结果是每点一次「连接」，
    标签栏就多一页死页，页数只增不减。每一页都带一整套渲染进程，内存
    很快顶到 jetsam，macOS 就把看板 App 一起杀掉（用户看到的「应用时常
    闪退」就是这么来的）。现在所有死页一次性就地导回首页，再合并成一页。
    """
    target = home or TEAMS_URL
    rescued = False
    for p in pages():
        if dead and _is_dead_login(p.get("url") or ""):
            _eval(p, "location.href=%s; 'go'" % json.dumps(target), timeout=8)
            rescued = True
    if rescued:
        time.sleep(2.5)

    page = page or teams_page()
    if not page:
        return False
    ok = _unpark_window(width=width, height=height, page=page)
    _browser_cmd("Target.activateTarget", {"targetId": page.get("id")})
    dedupe_pages()
    return ok


def ensure_browser(url=None):
    """确保浏览器在跑、并且在 Teams 页上。返回 True/False。

    ⚠️ 这条路是**后台保活**用的，用户看不见 —— 所以这里绝不能调
    show_browser：那会把窗口从屏幕外搬回屏幕正中，用户正在干活时突然
    弹出一个 Teams 窗口。需要导航时只做「就地静默跳转」。
    """
    url = url or TEAMS_URL
    if not cdp_up():
        return launch_browser(url)
    if not pages():
        return launch_browser(url)
    dedupe_pages()
    tp = teams_page()
    if not tp or "teams." not in (tp.get("url") or ""):
        # 当前没有一个可用的 Teams 页：把已有的那个页面导过去，
        # **不要**新开标签 —— 每开一个都多一整套渲染进程。
        if tp:
            _eval(tp, "location.href=%s; 'go'" % json.dumps(url), timeout=8)
            time.sleep(1.5)
        else:
            _open_url_in_browser(url)
            time.sleep(2)
    dedupe_pages()
    return True


# ==========================================================================
# 四、取令牌
# ==========================================================================

_HARVEST_JS = r"""
(async () => {
  const decode = (jwt) => {
    try {
      const p = jwt.split('.')[1].replace(/-/g, '+').replace(/_/g, '/');
      return JSON.parse(atob(p + '==='.slice((p.length + 3) % 4)));
    } catch (e) { return null; }
  };
  const b64 = (s) => {
    s = String(s).replace(/-/g, '+').replace(/_/g, '/');
    const pad = s.length % 4 ? '='.repeat(4 - (s.length % 4)) : '';
    const bin = atob(s + pad);
    const u = new Uint8Array(bin.length);
    for (let i = 0; i < bin.length; i++) u[i] = bin.charCodeAt(i);
    return u;
  };

  const hits = [];
  let upn = '';
  const consider = (tok, who) => {
    const pl = decode(tok);
    if (!pl) return;
    if (!upn && (pl.upn || pl.unique_name || pl.preferred_username)) {
      upn = pl.upn || pl.unique_name || pl.preferred_username;
    }
    if (pl.aud === 'https://graph.microsoft.com') {
      hits.push({ tok: tok, exp: pl.exp, scp: pl.scp || '' });
    }
  };

  // ① 明文扫描：老客户端（以及别的站点）把令牌直接以明文放在 localStorage 里。
  const re = /eyJ[A-Za-z0-9_-]{20,}\.[A-Za-z0-9_-]{20,}\.[A-Za-z0-9_-]{10,}/g;
  for (const store of [localStorage, sessionStorage]) {
    for (let i = 0; i < store.length; i++) {
      let v = '';
      try { v = store.getItem(store.key(i)) || ''; } catch (e) { continue; }
      re.lastIndex = 0;
      let m;
      while ((m = re.exec(v)) !== null) consider(m[0]);
    }
  }

  // ② 新版 Teams（teams.cloud.microsoft）走的是「加密令牌存储」：
  //    每个资源一份 tmp.auth.v1.<uuid>.Token.<资源>，明文槽位 token 通常是空串，
  //    真令牌放在 encryptedToken + iv 里，用页内那把 AES-256-CBC 密钥加密。
  //    密钥本身就在 localStorage 的 ExportedEncryptionKey 条目里（明文 base64）。
  //    不解这一步，harvest 就永远拿不到令牌 —— 表现是 Teams 数据一直陈旧、
  //    日志里反复刷「Teams 令牌仍未取到」，而用户在浏览器里明明已经登进去了。
  if (!hits.length) {
    let key = null;
    try {
      const raw = localStorage.getItem(
        'tmp.auth.v1.GLOBAL.ExportedEncryptionKey.ExportedEncryptionKey');
      const kb64 = JSON.parse(raw).item.exportedKey;
      key = await crypto.subtle.importKey('raw', b64(kb64), {name: 'AES-CBC'},
                                         false, ['decrypt']);
    } catch (e) { key = null; }

    for (let i = 0; i < localStorage.length; i++) {
      const k = localStorage.key(i);
      // 只认 `…Token.<资源>` 这种：末尾的 SKYPE-TOKEN 之类不是令牌条目。
      if (!/auth\.v1/.test(k) || !/\.Token\./.test(k)) continue;
      let it;
      try { it = JSON.parse(localStorage.getItem(k)).item; } catch (e) { continue; }
      if (!it) continue;
      if (!upn && it.webAccount && it.webAccount.profile) {
        const p = it.webAccount.profile;
        upn = p.upn || p.preferred_username || upn;
      }
      let tok = it.token || '';
      if (!tok && it.encryptedToken && it.iv && key) {
        try {
          const pt = await crypto.subtle.decrypt(
            {name: 'AES-CBC', iv: b64(it.iv)}, key, b64(it.encryptedToken));
          tok = new TextDecoder().decode(pt);
        } catch (e) { tok = ''; }
      }
      if (tok) consider(tok);
    }
  }

  hits.sort((a, b) => b.exp - a.exp);
  const best = hits[0];
  return JSON.stringify(best ? { ok: true, upn, tok: best.tok, exp: best.exp, scp: best.scp }
                             : { ok: false, upn });
})()
"""


def harvest(timeout=30):
    """从浏览器页面里取出 Graph 令牌。返回 dict 或 None。

    两条路都要走（见 _HARVEST_JS）：
      ① 明文扫描 —— 老客户端把令牌明文放在 localStorage；
      ② 加密令牌存储 —— 新版 Teams 把令牌 AES-CBC 加密后才落盘，
         密钥也在同一個 localStorage 里，所以能就地解开。
    只做 ① 的话，新版 Teams 永远取不到令牌；只做 ② 的话，
    别的站点（明文）又白跑一趟。
    """
    page = teams_page()
    if not page:
        _LAST_ERR["msg"] = "浏览器里没有可用的页面"
        return None
    try:
        raw = _eval(page, _HARVEST_JS, timeout=timeout)
    except Exception as e:
        _LAST_ERR["msg"] = "取令牌失败：%s" % e
        return None
    try:
        d = json.loads(raw or "{}")
    except Exception:
        d = {}
    if not d.get("ok"):
        _LAST_ERR["msg"] = "页面里没有 Graph 令牌（可能还没登录）"
        return None
    with _lock:
        _CACHE.update({"token": d["tok"], "exp": int(d.get("exp") or 0),
                       "scp": d.get("scp") or "", "upn": d.get("upn") or "",
                       "at": time.time()})
    _LAST_ERR["msg"] = ""
    remember_session()
    return _CACHE["token"]


def _reload_page():
    page = teams_page()
    if not page:
        return
    try:
        u = urllib.parse.urlparse(page["webSocketDebuggerUrl"])
        ws = _WS(u.hostname, u.port or PORT, u.path, timeout=10)
        ws.send(json.dumps({"id": 1, "method": "Page.reload",
                            "params": {"ignoreCache": False}}))
        ws.close()
    except Exception:
        pass


_tok_lock = threading.Lock()
# 令牌还能用多久才值得去换新的。原来是 150 秒——太保守：令牌明明还能用两分钟，
# 程序却认定它「快过期」去重新 harvest，一旦 harvest 抖动失败就返回空令牌，
# 整个 Teams 板块立刻变空白。这里放宽成「快真过期了才换」。
_TOK_SLACK = 30


def token(force=False, allow_reload=True):
    """取 Graph 令牌；只有当令牌**真的快过期**时才重载页面去换。

    Teams 板块频繁空白的根因基本都在这一个函数里，所以这里立了三条规矩：
      · 令牌只要还没过期就继续用，绝不因为「不太够了」就把还能用的丢掉；
      · 换令牌必须串行（一把锁）—— 以前两个后台线程会同时 reload 页面，
        互相把对方刚拿到的令牌冲掉，然后双双返回空；
      · 实在拿不到新的、但旧的还没过期，就返回旧的。返回空会让整个板块空白，
        返回一张「也许只剩几十秒」的旧票，用户什么也感觉不到。
    """
    now = time.time()
    with _lock:
        tok, exp = _CACHE["token"], _CACHE["exp"]
    if tok and not force and exp - _TOK_SLACK > now:
        return tok

    with _tok_lock:
        now = time.time()
        with _lock:
            tok, exp = _CACHE["token"], _CACHE["exp"]
        if tok and not force and exp - _TOK_SLACK > now:
            return tok

        if not cdp_up():
            # 浏览器不在，换不了新票；旧票没过期就先用着
            return tok if (tok and exp > now) else ""

        # CDP 偶发抖动，多试几次基本都能拿到，比直接判死强得多
        t = ""
        for _ in range(3):
            t = harvest()
            if t:
                break
            time.sleep(1.2)

        if not t and allow_reload:
            _reload_page()
            for _ in range(10):
                time.sleep(1.5)
                t = harvest()
                if t:
                    break

        if t:
            return t
        # 拿不到新的：旧的还能用就先用着（空令牌 = 板块空白，代价太大）
        return tok if (tok and exp > now) else ""


def reset():
    with _lock:
        _CACHE.update({"token": "", "exp": 0, "scp": "", "upn": "", "at": 0.0})


def connect(timeout=300, on_progress=None):
    """界面「连接」按钮：拉起浏览器 → 用户在窗口里登进 Teams → 取到令牌即算连上。

    整个过程不需要注册应用、不需要管理员批准：令牌就是用户自己登录换来的。
    """
    def say(m):
        if on_progress:
            try:
                on_progress(m)
            except Exception:
                pass

    if not cdp_up():
        say("正在打开登录窗口…")
        if not launch_browser():
            return {"ok": False, "error": _LAST_ERR["msg"] or "浏览器启动失败"}
    # 先把堆积的标签页收一收：以前这里「看不到 Teams 页就新开一个」，
    # 用户每点一次「连接」就多一页；而 login.live.com/ppsecure、AAD 的
    # /common/login 这类续页永远不会自己恢复，就一直挂着。每页都是一整套
    # 渲染进程，内存顶到 jetsam 时 macOS 会把看板 App 一起杀掉
    #（用户报的「应用时常闪退」）。现在只有「一个页面都没有」才新开。
    dedupe_pages()
    page = teams_page()
    if not page:
        say("正在打开 Teams…")
        _open_url_in_browser(TEAMS_URL)
    # 无论窗口是「刚起来的」还是「本来就在屏幕外跑着的」，都走一次
    # show_browser：摆到屏幕正中 + 把卡死的登录续页就地导回首页 + 合并多余标签。
    show_browser()
    say("请在窗口里用学校账号登录 Teams")

    end = time.time() + timeout
    while time.time() < end:
        t = harvest()
        if t:
            say("已连上")
            return {"ok": True, "account": account(), "scopes": len(scopes())}
        time.sleep(3)
    return {"ok": False, "error": "还没等到登录完成"}


def logout():
    """退出：清掉本地缓存的令牌与「曾登录」标记（浏览器里的登录态保留）。"""
    reset()
    forget_session()
    return True


def keep_alive():
    """后台保活：浏览器被关掉就悄悄拉回来，让看板下次刷新仍能取到数据。

    关键字是**悄悄** —— quiet 启动（窗口在屏幕外）+ 顺手清掉堆积的重复标签页。
    用户不该感觉到后台为了取数据又开了一次浏览器。
    """
    if not has_session():
        return False
    if cdp_up():
        dedupe_pages()
        # 用户在窗口上登录期间**绝对不许**藏窗口：否则他刚把窗口拉回来，
        # 下一次保活就把它又最小化了 —— 看起来就是「窗口自己消失了」。
        if holding():
            return True
        # 兜底：窗口不知被谁恢复成 normal（比如系统更新/用户误点 Dock），
        # 保活时顺手再藏一次 —— 桌面上永远不该看到这个窗口。
        if _window_state() not in (None, "minimized"):
            _park_window()
        return True
    ok = launch_browser(TEAMS_URL, quiet=True)
    if ok:
        dedupe_pages()
    return ok


# ==========================================================================
# 五、Graph 调用
# ==========================================================================

class GraphError(Exception):
    def __init__(self, status, body):
        Exception.__init__(self, "HTTP %s: %s" % (status, str(body)[:200]))
        self.status = status
        self.body = body


def graph(path, retry=True, timeout=TIMEOUT_HTTP):
    """GET 一次 Graph。path 形如 /me/messages?...（也接受完整 URL）。"""
    tok = token()
    if not tok:
        raise GraphError(401, "没有可用令牌")
    url = path if path.startswith("http") else GRAPH + path
    # urllib 不接受 URL 里的空格等字符；Graph 的 OData 查询串里常有空格
    url = (url.replace(" ", "%20").replace("|", "%7C")
              .replace("^", "%5E").replace("{", "%7B").replace("}", "%7D"))
    req = urllib.request.Request(url, headers={
        "Authorization": "Bearer " + tok,
        "Accept": "application/json",
        "User-Agent": "mbboard/1.0",
    })
    try:
        with urllib.request.urlopen(req, timeout=timeout) as r:
            body = r.read().decode("utf-8", "replace")
    except urllib.error.HTTPError as e:
        body = e.read().decode("utf-8", "replace")
        if e.code == 401 and retry:
            token(force=True)
            return graph(path, retry=False, timeout=timeout)
        raise GraphError(e.code, body)
    try:
        return json.loads(body) if body else {}
    except Exception:
        raise GraphError(200, "返回不是 JSON")


def graph_paged(path, limit=200, timeout=TIMEOUT_HTTP):
    """自动跟 @odata.nextLink 翻页，最多 limit 条。"""
    out, url, guard = [], path, 0
    while url and len(out) < limit and guard < 12:
        guard += 1
        d = graph(url, timeout=timeout)
        vals = d.get("value")
        if isinstance(vals, list):
            out.extend(vals)
        else:
            return [d] if d else []
        url = d.get("@odata.nextLink") or ""
    return out[:limit]


# ==========================================================================
# 六、状态与能力
# ==========================================================================

def scopes():
    with _lock:
        scp = _CACHE["scp"]
    if not scp:
        token()
        with _lock:
            scp = _CACHE["scp"]
    return [s for s in scp.split() if s]


def account():
    with _lock:
        return _CACHE["upn"]


def capabilities():
    """依据令牌里**实际存在**的权限，判断哪几条数据源能拉。"""
    s = set(scopes())

    def any_of(*names):
        return any(n in s for n in names)

    return {
        "account": bool(s),
        "mail": any_of("Mail.Read", "Mail.ReadWrite"),
        "calendar": any_of("Calendars.Read", "Calendars.ReadWrite"),
        "todo": any_of("Tasks.Read", "Tasks.ReadWrite"),
        "planner": any_of("Tasks.Read.All", "Group.Read.All"),
        "chat": any_of("Chat.Read", "Chat.ReadBasic", "Chat.ReadWrite"),
        # 频道消息：Teams 网页版自带这个权限，1:1 聊天它不带 Chat.Read
        "channels": any_of("ChannelMessage.Read.All", "ChannelMessage.Read"),
        "teams": any_of("Team.ReadBasic.All", "Group.Read.All"),
    }


def granted_scopes():
    return sorted(scopes())


MISSING_HINT = {
    "chat": "Chat.Read（Teams 网页版不带，需另注册应用或改用页面抓取）",
    "channels": "ChannelMessage.Read.All",
    "mail": "Mail.Read",
    "calendar": "Calendars.Read",
    "todo": "Tasks.Read",
}


def auth_state():
    """给界面用的登录态。"""
    with _lock:
        scp = _CACHE["scp"]
    if not scp and cdp_up():
        token()                     # 进程刚起来时缓存是空的，这里补一次
        with _lock:
            scp = _CACHE["scp"]
    with _lock:
        upn = _CACHE["upn"]
    caps = capabilities() if scp else {}
    granted = sorted(s for s in scp.split() if s)
    missing = [MISSING_HINT[k] for k in ("channels", "mail", "calendar", "todo")
               if caps and not caps.get(k)]
    return {
        "loggedIn": bool(scp),
        "account": upn,
        "granted": granted,
        "missing": missing,
        "browserUp": cdp_up(),
        "browserPort": PORT,
        "browserUrl": TEAMS_URL,
    }


def status():
    """界面「连接」卡片要用的完整状态。"""
    st = auth_state()
    st["error"] = _LAST_ERR["msg"]
    st["tokenExpIn"] = max(0, int(_CACHE["exp"] - time.time()))
    return st


def self_test():
    print("Chrome :", chrome_path() or "(未找到)")
    print("配置目录:", PROFILE)
    print("调试端口:", PORT, "→", "通" if cdp_up() else "不通")
    print("页面    :", [(p.get("title") or "")[:40] for p in pages()][:3])
    t = token()
    print("令牌    :", "已取到" if t else "没有", "| 账号:", account())
    print("权限    :", len(scopes()), "项")
    c = capabilities()
    print("可用数据源:", {k: v for k, v in c.items() if v})
    print("不可用    :", [k for k, v in c.items() if not v])


if __name__ == "__main__":
    cmd = sys.argv[1] if len(sys.argv) > 1 else "test"
    if cmd == "test":
        self_test()
    elif cmd == "open":
        print("浏览器:", ensure_browser())
    elif cmd == "token":
        print(token(force=True) or "(没有令牌)")
    elif cmd == "reset":
        reset()
        print("已清空缓存")
