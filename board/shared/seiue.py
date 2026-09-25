#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
希悦（yly.seiue.com）课表抓取
--------------------------------------------------------------------------
沿用和 Teams 完全一样的那套思路，这样用户只需要「登录一次」：

  1. 起一个**专用配置目录**的 Chrome（<数据目录>/seiue-profile，端口按数据目录派生）。
     这个目录与用户的日常浏览器隔离，但登录态会一直存在里面，不用反复登。
  2. 用户在窗口里正常登录希悦 —— 我们不碰密码、不走任何私有接口签名。
  3. 之后从页面里把课表抠出来。

为什么是「从页面里抠」而不是「调接口」：
  希悦的课表接口带着会话签名，逆出来既脆弱又容易失效。而课表本身在页面上是
  一张网格，用**几何位置**认列（周几）和行（第几节）比认接口稳得多。

★ 2026-09 修的一个重要 bug
  旧版拿 `[class*=course]` 之类**关键字选择器**去捞格子，但希悦是
  styled-components 生成的页面 —— class 长这样：`sc-kNjblg gWlwqu`，
  里面根本没有 course/lesson/card 这些字。所以选择器一个都匹配不到，
  表现就是「登录明明成功了，但课表次次是空的」。
  现在改成认希悦自己的测试钩子 `data-test-id="seiue-schedule-container"`
  和 `seiue-schedule-*` 这几个**语义化类名**（它们跟着业务走，不会随样式改版）。

★ 另一个必修项：课表在**首页 `/`** 上
  希悦没有 `/timetable` 这种路由（试过，404）。课表就挂在首页的
  「工作台」里。旧版从不导航，浏览器停在哪就在哪抓 —— 只要用户点进过
  别的页面（比如某个班级），就永远抓不到课表。现在抓之前会先回首页。

抓取频率：由 TTL 控制（默认 1 小时）。读页面很轻，不值得缓存太久 ——
课表是按「周」渲染的，缓存一周会把上周的格子一直显示下去。
"""

import json
import os
import re
import subprocess
import threading
import time
import urllib.parse
import urllib.request

HOME = os.path.expanduser("~")
# 数据目录：App 分发版会把 MBBOARD_DATA 指到 ~/Library/Application Support 下，
# 开发机不设它、继续用 ~/.mbboard —— 两种场景共用同一份代码。
MBB = os.environ.get("MBBOARD_DATA") or os.path.join(HOME, ".mbboard")
PROFILE = os.path.join(MBB, "seiue-profile")


def _debug_port(scope, fallback):
    """调试端口跟着数据目录派生。理由同 mssession.py 里那份：
    写死端口会让新数据目录「捡到」上一个目录的 Chrome（连同它的登录态），
    于是清空数据也不掉登录、老浏览器一关又突然掉，非常难查。"""
    try:
        import zlib
        key = os.path.abspath(MBB) + "|" + scope
        return 9400 + (zlib.crc32(key.encode("utf-8")) % 400)
    except Exception:
        return fallback


PORT = _debug_port("seiue", 9224)
SITE = "https://yly.seiue.com"
HOME_URL = "https://yly.seiue.com/"
LOGIN_URL = HOME_URL

_MAC_CHROME = os.path.join(MBB, "chrome", "Google Chrome for Testing.app",
                           "Contents", "MacOS", "Google Chrome for Testing")
_WIN_CHROME = os.path.join(MBB, "chrome", "chrome.exe")

# 一小时抓一次。课表按周渲染，缓存太久会把上一周一直显示下去。
TTL = 3600

_lock = threading.RLock()
_CACHE = {"data": None, "ts": 0.0, "error": None}
_MARKER = os.path.join(MBB, ".seiue-session")


# ==========================================================================
# 一、极简 CDP 客户端（只用到三件事：列页面、执行 JS、开标签页）
# ==========================================================================

class _WS(object):
    """够用的 WebSocket 文本帧客户端。不引第三方库，省得装依赖。"""

    def __init__(self, host, port, path, timeout=20):
        import socket
        import struct
        self.timeout = timeout
        self.sock = socket.create_connection((host, port), timeout=timeout)
        key = "dGhlIHNhbXBsZSBub25jZQ=="
        req = ("GET %s HTTP/1.1\r\nHost: %s:%d\r\nUpgrade: websocket\r\n"
               "Connection: Upgrade\r\nSec-WebSocket-Key: %s\r\n"
               "Sec-WebSocket-Version: 13\r\n\r\n" % (path, host, port, key))
        self.sock.sendall(req.encode())
        buf = b""
        while b"\r\n\r\n" not in buf:
            chunk = self.sock.recv(4096)
            if not chunk:
                break
            buf += chunk
        self.buf = buf.split(b"\r\n\r\n", 1)[1] if b"\r\n\r\n" in buf else b""
        self._struct = struct

    def send(self, text):
        payload = text.encode("utf-8")
        n = len(payload)
        header = bytearray([0x81])
        if n < 126:
            header.append(0x80 | n)
        elif n < 65536:
            header.append(0x80 | 126)
            header += self._struct.pack(">H", n)
        else:
            header.append(0x80 | 127)
            header += self._struct.pack(">Q", n)
        mask = os.urandom(4)
        header += mask
        masked = bytes(b ^ mask[i % 4] for i, b in enumerate(payload))
        self.sock.sendall(bytes(header) + masked)

    def _read(self, n):
        out = self.buf
        while len(out) < n:
            chunk = self.sock.recv(max(4096, n - len(out)))
            if not chunk:
                raise IOError("websocket closed")
            out += chunk
        self.buf = out[n:]
        return out[:n]

    def recv(self):
        while True:
            head = self._read(2)
            opcode = head[0] & 0x0F
            length = head[1] & 0x7F
            if length == 126:
                length = self._struct.unpack(">H", self._read(2))[0]
            elif length == 127:
                length = self._struct.unpack(">Q", self._read(8))[0]
            data = self._read(length)
            if opcode == 0x1:
                return data.decode("utf-8", "replace")
            if opcode == 0x8:
                raise IOError("websocket closed by peer")
            # ping / pong / binary 一律跳过

    def close(self):
        try:
            self.sock.close()
        except Exception:
            pass


def _http_json(url, timeout=4):
    req = urllib.request.Request(url, headers={"Host": "127.0.0.1:%d" % PORT})
    with urllib.request.urlopen(req, timeout=timeout) as r:
        return json.loads(r.read().decode("utf-8", "replace"))


def cdp_up():
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


def seiue_page():
    ps = pages()
    for p in ps:
        if "seiue.com" in (p.get("url") or ""):
            return p
    return ps[0] if ps else None


def _eval(page, expression, timeout=25):
    u = urllib.parse.urlparse(page["webSocketDebuggerUrl"])
    ws = _WS(u.hostname, u.port or PORT, u.path, timeout=timeout)
    try:
        ws.send(json.dumps({
            "id": 1, "method": "Runtime.evaluate",
            "params": {"expression": expression, "returnByValue": True,
                       "awaitPromise": True},
        }))
        end = time.time() + timeout
        while time.time() < end:
            msg = json.loads(ws.recv())
            if msg.get("id") == 1:
                if msg.get("error"):
                    raise IOError(str(msg["error"])[:200])
                res = (msg.get("result") or {})
                if res.get("exceptionDetails"):
                    raise IOError("页面 JS 报错")
                return (res.get("result") or {}).get("value")
        raise IOError("CDP 执行超时")
    finally:
        ws.close()


def _page_cmd(page, method, params=None, timeout=12):
    """页面级的任意 CDP 命令（Input.* / Page.* 这类不属于 Runtime 的）。

    ★ 为什么非得有它：点「导出课表」那个按钮时，`el.click()` 和
      `dispatchEvent(new MouseEvent(...))` **都不管用** —— 希悦那个按钮上挂着
      的是 antd 的合成事件链，纯 JS 派发的点击进不去。只有走 CDP 的
      `Input.dispatchMouseEvent`（浏览器层面的真实鼠标事件）才点得动。
    """
    try:
        u = urllib.parse.urlparse(page["webSocketDebuggerUrl"])
    except Exception:
        return None
    try:
        ws = _WS(u.hostname, u.port or PORT, u.path, timeout=timeout)
    except Exception:
        return None
    try:
        ws.send(json.dumps({"id": 1, "method": method, "params": params or {}}))
        end = time.time() + timeout
        while time.time() < end:
            try:
                data = json.loads(ws.recv())
            except Exception:
                continue
            if data.get("id") == 1:
                return data.get("result")
        return None
    except Exception:
        return None
    finally:
        ws.close()


def _real_click(page, x, y):
    """在页面坐标 (x, y) 上按下并松开一次真实鼠标左键。"""
    for t in ("mouseMoved", "mousePressed", "mouseReleased"):
        p = {"type": t, "x": float(x), "y": float(y), "button": "left", "clickCount": 1}
        if t == "mouseMoved":
            p.pop("button")
            p.pop("clickCount")
        _page_cmd(page, "Input.dispatchMouseEvent", p, timeout=8)
        time.sleep(0.06)
    return True


def _open_tab(url):
    target = "http://127.0.0.1:%d/json/new?%s" % (PORT, urllib.parse.quote(url, safe=""))
    for method in ("PUT", "GET"):
        try:
            req = urllib.request.Request(target, method=method)
            with urllib.request.urlopen(req, timeout=6) as r:
                r.read()
            return True
        except Exception:
            continue
    return False


# ==========================================================================
# 二、浏览器生命周期
# ==========================================================================

def chrome_path():
    for p in (_MAC_CHROME, _WIN_CHROME):
        if os.path.exists(p):
            return p
    return None


def _clear_stale_locks():
    """清掉上次异常退出留下的 profile 锁。

    Chrome 用 SingletonLock / SingletonSocket / SingletonCookie 这三个软链
    保证「同一个配置目录只跑一个实例」。进程被强杀（或崩溃）时锁会留在原地，
    新实例一启动就以为「已经有一个在跑」，把自己的启动参数转交给那个
    **并不存在**的实例，然后自己退出 —— 表现就是「怎么拉都拉不起来」，
    进程数 0、调试端口不通，而返回码还是 0（看着像成功）。

    ★ 这套逻辑 mssession.py（Teams）里一直有，seiue.py 里没有。
      漏掉它的后果就是希悦在**任何**留过残留进程的机器上永远起不来，
      用户看到的却是「我明明登录进去了，数据次次抓失败」——
      因为坏的是「起浏览器」，谁都想不到要去查那里。
    """
    for n in ("SingletonLock", "SingletonSocket", "SingletonCookie"):
        p = os.path.join(PROFILE, n)
        try:
            if os.path.islink(p) or os.path.exists(p):
                os.remove(p)
        except Exception:
            pass


def _stale_procs():
    """用了这个配置目录的残留 Chrome 进程。

    注意：这里**不区分**它监听哪个端口。Chrome 对一个 user-data-dir 只允许
    单实例，所以只要还有进程占着这个目录，我们就一定起不来新的 ——
    哪怕是「上一个版本用固定端口起的那个」。登录态都在 profile 里落盘，
    请走它们不会丢任何东西。
    """
    try:
        out = subprocess.run(["pgrep", "-f", "user-data-dir=" + PROFILE],
                             stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
                             text=True).stdout
        return [int(x) for x in out.split() if x.strip().isdigit()]
    except Exception:
        return []


def _reclaim_profile():
    """把占着 profile 的旧浏览器请走，为新的腾地方。返回是否动过手。"""
    import signal as _sig
    pids = _stale_procs()
    if not pids:
        return False
    for pid in pids:
        try:
            os.kill(pid, _sig.SIGTERM)
        except Exception:
            pass
    time.sleep(2)
    for pid in _stale_procs():          # 赖着不走的再来一下
        try:
            os.kill(pid, _sig.SIGKILL)
        except Exception:
            pass
    time.sleep(0.6)
    _clear_stale_locks()
    return True


def launch_browser(url=None):
    if cdp_up():
        if url:
            _open_tab(url)
        return True
    exe = chrome_path()
    if not exe:
        _CACHE["error"] = "找不到 Chrome for Testing"
        return False
    try:
        os.makedirs(PROFILE, exist_ok=True)
    except Exception:
        pass
    # 启动前先扫掉残留：僵尸实例会让新实例「转交参数后自己退出」（见 _clear_stale_locks）
    if _reclaim_profile():
        _CACHE["error"] = ""
    else:
        _clear_stale_locks()
    args = [exe,
            "--remote-debugging-port=%d" % PORT,
            "--user-data-dir=%s" % PROFILE,
            "--no-first-run", "--no-default-browser-check",
            # ★ 和 mssession 那份同样的理由：这是**第二个**常驻 Chrome 实例 ★
            #   看板一共挂着两套浏览器（Teams 一套、希悦一套），每套默认都会
            #   按 CPU 核数给每个标签页起一套渲染进程。两套加起来很容易把内存
            #   顶到 jetsam —— 实测的 JetsamEvent 里，看板 App 是跟一大串
            #   Chrome Helper 一起被系统杀掉的（用户报的「应用时常闪退」）。
            #   这里同样把渲染进程数和 JS 堆封顶，并关掉用不上的后台服务。
            "--renderer-process-limit=2",
            "--js-flags=--max-old-space-size=384",
            "--disable-extensions", "--disable-component-update",
            "--disable-background-networking", "--disable-sync",
            "--no-service-autorun", "--disable-domain-reliability",
            "--disable-features=Translate,MediaRouter,OptimizationHints,"
            "InterestFeedContentSuggestions,CalculateNativeWinOcclusion",
            "--window-size=1280,900"]
    if url:
        args.append(url)
    try:
        kwargs = {}
        if os.name == "nt":
            kwargs["creationflags"] = 0x00000008      # DETACHED_PROCESS
        else:
            kwargs["start_new_session"] = True
        subprocess.Popen(args, stdout=subprocess.DEVNULL,
                         stderr=subprocess.DEVNULL, **kwargs)
        for _ in range(40):
            if cdp_up():
                return True
            time.sleep(0.25)
        # 还是没起来：多半是启动过程中又被谁抢了 profile，再收一次重试
        if _reclaim_profile():
            subprocess.Popen(args, stdout=subprocess.DEVNULL,
                             stderr=subprocess.DEVNULL, **kwargs)
            for _ in range(40):
                if cdp_up():
                    return True
                time.sleep(0.25)
        _CACHE["error"] = "浏览器没能起来（调试端口 %d 不通）" % PORT
    except Exception as e:
        _CACHE["error"] = str(e)
    return False


def ensure_browser(url=None):
    url = url or LOGIN_URL
    if cdp_up():
        # ★ 已经有一个希悦页面了，就**别再开一个**。
        #   以前这里是无条件 `_open_tab(url)`，于是每调一次多一个标签
        #   （「打开希悦登录」点两下就是三个一模一样的工作台）。
        #   而 `seiue_page()` 取的是 ps[0] —— 抓取会随机落到一个刚开、
        #   还没渲染完的标签上，表现就是课表「这次有下次没有」。
        #   这类「标签越堆越多」的坑 Teams 那边早防住了（见 dedupe_pages），
        #   希悦这边一直漏着。
        cur = seiue_page()
        if cur and "seiue.com" in (cur.get("url") or ""):
            if url.rstrip("/") != (cur.get("url") or "").rstrip("/"):
                try:
                    _eval(cur, "location.href=%s; 'go'" % json.dumps(url))
                except Exception:
                    _open_tab(url)
            return True
        _open_tab(url)
        return True
    return launch_browser(url)


def show_browser():
    """把希悦窗口搬回屏幕**正中**并置前。

    和 Teams 那边同一个道理：用户主动点「打开课表页 / 去登录」时，
    窗口必须真的在他眼前，而不是贴在屏幕外只露一条边。
    """
    page = seiue_page()
    if not page:
        return False
    _set_download_dir()                       # 顺手把导出目录指到我们认得的地方
    return _unpark_window(page, width=1280, height=900)


# ==========================================================================
# 二·五、「识别网页导出的课表 Excel」
# --------------------------------------------------------------------------
# 用户的原话：课表页右上角有「导出课表」，点了会下一个 xlsx；
# 希望 App 直接认这个表，不要让人手动拖文件进来。
#
# 为什么这条路比从页面上抠格子更值得做：
#   ① 页面一页只画得下 6~7 行，第 8 节课得滚动才看得见 —— 抠格子天生会漏；
#      导出的表是**整张**课表，节次一节不少。
#   ② 表里连教室、老师、周次（每周[1-20]）都写全了，抠格子只能拿到一行文本。
#   ③ 不依赖任何 DOM 结构，希悦改版也不会失效。
#
# 所以：xlsx 认得出来就用它；认不出来（还没导出过）再退回抠格子。
# ==========================================================================

EXPORT_DIR = os.path.join(MBB, "seiue-downloads")

# 会去找的地方：App 自己下载的目录 + 用户日常的下载/桌面。
# 名字不要求统一（各校导出名不一样），认的是**表的内容**。
_SCAN_DIRS = [
    EXPORT_DIR,
    os.path.join(HOME, "Downloads"),
    os.path.join(HOME, "Desktop"),
    os.path.join(HOME, "Documents"),
]

# 只认这么新的表。太老的（去年那学期）不该再被当成当前课表。
_XLSX_MAX_AGE = 200 * 24 * 3600


def _browser_cmd(method, params=None, timeout=8):
    """浏览器级的 CDP 调用（窗口坐标、下载行为这类不属于某个页面的命令）。"""
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
            try:
                data = json.loads(ws.recv())
            except Exception:
                continue
            if data.get("id") == 1:
                return data.get("result")
        return None
    except Exception:
        return None
    finally:
        ws.close()


def _set_download_dir():
    """把浏览器的下载目录指到我们自己的文件夹。

    这样用户点「导出课表」时，文件直接落在 <数据目录>/seiue-downloads，
    我们一定能看到它（不用去猜用户把他的下载目录改到哪了）。
    顺带允许下载 —— 自动化浏览器默认是「不落盘」的。
    """
    try:
        os.makedirs(EXPORT_DIR, exist_ok=True)
    except Exception:
        return False
    ok = False
    for method, params in (
        ("Browser.setDownloadBehavior",
         {"behavior": "allow", "downloadPath": EXPORT_DIR, "eventsEnabled": True}),
        ("Page.setDownloadBehavior",
         {"behavior": "allow", "downloadPath": EXPORT_DIR}),
    ):
        try:
            if _browser_cmd(method, params) is not None:
                ok = True
        except Exception:
            pass
    return ok


def _screen_size(page):
    try:
        raw = _eval(page, "JSON.stringify({w: screen.availWidth, h: screen.availHeight})",
                    timeout=6)
        d = json.loads(raw or "{}")
        w, h = int(d.get("w") or 0), int(d.get("h") or 0)
        if w > 400 and h > 300:
            return w, h
    except Exception:
        pass
    return 1440, 900


def _unpark_window(page, width=1280, height=900):
    """搬回屏幕正中 + 恢复 normal + 置前。

    ★ 只调一次 setWindowBounds 是**不够**的：窗口处于 minimized 时，
      Chrome 会忽略 bounds 里的 left/top —— 于是窗口一直停在屏幕外那条
      老坐标上（实测 -1160,33：屏幕上只露出右边一条边），
      用户看到的正是「窗口跑到屏幕特别靠左、只露出来一个边边」。
    """
    info = _browser_cmd("Browser.getWindowForTarget", {"targetId": page.get("id")}) or {}
    wid = info.get("windowId")
    if wid is None:
        return False
    sw, sh = _screen_size(page)
    left = max(0, int((sw - width) / 2))
    top = max(30, int((sh - height) / 2))
    w = min(width, max(720, sw - 40))
    h = min(height, max(540, sh - 80))

    def _set():
        _browser_cmd("Browser.setWindowBounds", {
            "windowId": wid,
            "bounds": {"left": left, "top": top, "width": w, "height": h,
                       "windowState": "normal"}})

    _set()
    time.sleep(0.35)
    _set()
    time.sleep(0.35)
    _browser_cmd("Target.activateTarget", {"targetId": page.get("id")})
    return True


# ---------------- xlsx 解析（只用标准库：xlsx 就是一堆 XML 打的 zip） ----------------

def _xlsx_rows(path):
    """把第一张工作表读成「行 → {列号: 文本}」。

    不引 openpyxl：分发版要能在任何一台机器上跑，多一个依赖就多一个
    「在他电脑上装不上」的理由。xlsx 本身是 zip + XML，标准库足够。
    """
    import zipfile
    import xml.etree.ElementTree as ET
    NS = "{http://schemas.openxmlformats.org/spreadsheetml/2006/main}"
    z = zipfile.ZipFile(path)
    shared = []
    try:
        root = ET.fromstring(z.read("xl/sharedStrings.xml"))
        for si in root.findall(NS + "si"):
            shared.append("".join(t.text or "" for t in si.iter(NS + "t")))
    except Exception:
        pass
    sheet = None
    for name in z.namelist():
        if name.startswith("xl/worksheets/sheet") and name.endswith(".xml"):
            sheet = name
            break
    if not sheet:
        return []
    root = ET.fromstring(z.read(sheet))
    rows = []
    for row in root.iter(NS + "row"):
        cells = {}
        for c in row.findall(NS + "c"):
            ref = c.get("r") or ""
            col = "".join(ch for ch in ref if ch.isalpha())
            if not col:
                continue
            t = c.get("t")
            v = c.find(NS + "v")
            isv = c.find(NS + "is")
            val = None
            if t == "s" and v is not None:
                try:
                    val = shared[int(v.text)]
                except Exception:
                    val = None
            elif t == "inlineStr" and isv is not None:
                val = "".join(x.text or "" for x in isv.iter(NS + "t"))
            elif v is not None:
                val = v.text
            if val:
                cells[col] = val
        rows.append(cells)
    return rows


def _col_index(name):
    n = 0
    for ch in name.upper():
        n = n * 26 + (ord(ch) - 64)
    return n - 1        # A → 0


_DAY_CN = ["周一", "周二", "周三", "周四", "周五", "周六", "周日"]


def _day_name(raw):
    s = (raw or "").strip()
    m = {"一": 0, "二": 1, "三": 2, "四": 3, "五": 4, "六": 5, "日": 6, "天": 6}
    for k in ("星期", "周", "禮拜", "礼拜"):
        if s.startswith(k) and len(s) > len(k):
            ch = s[len(k)]
            if ch in m:
                return m[ch]
    for k, v in m.items():
        if k in s:
            return v
    return -1


def _clean_cell(s):
    return " ".join((s or "").replace("\r", "\n").split())


def parse_schedule_xlsx(path):
    """把导出的课表 xlsx 变成和网页抓取**完全同构**的结果。

    表长这样（希悦导出）：
        A1  张明 的课表
        B2 星期一  C2 星期二 …          ← 列 = 周几
        A3  P1 \\n 08:00 - 08:40          ← 行 = 节次
        B3  AP 初级微积分 \\n Grade 10 3班 E103 李思远 \\n 08:00-08:40 每周[1-20]
    换成通用说法：第一行/第一列任意位置都可能，认的是「一行里出现 星期X」和
    「一列里出现 P<数字>」，所以别的学校导出的表只要形状一样就都认。
    """
    try:
        rows = _xlsx_rows(path)
    except Exception as e:
        return {"ok": False, "error": "打不开这个表：%s" % e,
                "days": [], "periods": [], "lessons": []}

    # ① 找表头行：一行里至少有 5 个「星期X」
    head_i, head_cols = -1, {}
    for i, r in enumerate(rows[:12]):
        cols = {}
        for col, v in r.items():
            d = _day_name(v)
            if d >= 0:
                cols[col] = d
        if len(cols) >= 5:
            head_i, head_cols = i, cols
            break
    if head_i < 0:
        return {"ok": False, "error": "这张表里没有找到「星期…」表头，可能不是课表",
                "days": [], "periods": [], "lessons": []}

    # ② 表头那行往下，第一列是节次（P1 / 第1节 / 1）
    days = [_DAY_CN[i] for i in range(7)]
    periods, lessons = [], []
    import re as _re
    for r in rows[head_i + 1:]:
        first = ""
        for col in sorted(r.keys(), key=_col_index):
            if _col_index(col) < min(_col_index(c) for c in head_cols):
                first = r[col]
                break
        if not first:
            continue
        per = _clean_cell(first)
        m = _re.match(r"^(P\d+)\s*(\d{1,2}:\d{2}\s*[-–~至]\s*\d{1,2}:\d{2})?", per)
        if not m:
            m2 = _re.match(r"^第?\s*(\d+)\s*节", per)
            if not m2:
                continue
            label = "P%s" % _order_label(m2.group(1))
            tm = ""
        else:
            label = m.group(1)
            tm = (m.group(2) or "").replace(" ", "")
        pidx = len(periods)
        periods.append((label + " " + tm).strip())
        for col, day in head_cols.items():
            cell = r.get(col)
            if not cell:
                continue
            lines = [x.strip() for x in cell.split("\n") if x.strip()]
            if not lines:
                continue
            name = lines[0]
            extra = lines[1:]
            text = _clean_cell(cell)
            lessons.append({
                "day": _DAY_CN[day],
                "dayIndex": day,
                "period": periods[pidx],
                "periodIndex": pidx,
                "text": text,
                "name": name,
                "extra": extra,
            })
    if not lessons:
        return {"ok": False, "error": "这张表是空的（没有解析出任何一节课）",
                "days": days, "periods": periods, "lessons": []}
    return {"ok": True, "error": "",
            "days": days, "periods": periods, "lessons": lessons,
            "columns": len(head_cols), "rows": len(periods), "tables": 1,
            "href": "file://" + path, "title": os.path.basename(path),
            "source": "excel", "file": path}


def _order_label(n):
    try:
        return str(int(n))
    except Exception:
        return str(n)


def _list_candidates():
    """候选文件（只 stat，不解析）：[(mtime, path)]，新的在前。"""
    now = time.time()
    cands, seen = [], set()
    for d in _SCAN_DIRS:
        try:
            if not os.path.isdir(d):
                continue
            for fn in os.listdir(d):
                if not fn.lower().endswith(".xlsx"):
                    continue
                if fn.startswith("~$") or fn.startswith("."):
                    continue
                p = os.path.join(d, fn)
                if p in seen:
                    continue
                try:
                    st = os.stat(p)
                except Exception:
                    continue
                if st.st_size < 1024 or st.st_size > 4_000_000:
                    continue
                if now - st.st_mtime > _XLSX_MAX_AGE:
                    continue
                seen.add(p)
                cands.append((st.st_mtime, p))
        except Exception:
            continue
    cands.sort(reverse=True)
    return cands


def newest_candidate():
    """最近改动过的那张候选表（不解析内容）—— 给后台线程做「有没有新变化」用。"""
    c = _list_candidates()
    return c[0] if c else None


def download_stamp():
    c = newest_candidate()
    if not c:
        return ""
    return "%s|%d" % (c[1], int(c[0]))


def find_exported_xlsx():
    """在几个「用户会放下载文件」的地方找最新的课表表。

    认的是**内容**不是文件名：名字带不带学校名、有没有空格都无所谓，
    只要解析出来是一张课表就算。太老的（超过 _XLSX_MAX_AGE）跳过。
    """
    for _, p in _list_candidates()[:12]:
        try:
            d = parse_schedule_xlsx(p)
        except Exception:
            continue
        if d.get("ok"):
            return d
    return None


def import_exported(path=None):
    """把（找到的）导出表吃进来，并落成课表缓存。"""
    d = parse_schedule_xlsx(path) if path else find_exported_xlsx()
    if not d or not d.get("ok"):
        return {"ok": False,
                "error": (d or {}).get("error")
                         or "还没找到课表文件 —— 在课表页右上角点「导出」，"
                            "弹出的小窗里选「Excel」再点「确定」，下好之后这里会自动认出来",
                "days": [], "periods": [], "lessons": []}
    d["ts"] = time.time()
    with _lock:
        _CACHE["data"] = d
        _CACHE["ts"] = time.time()
        _CACHE["error"] = None
        _CACHE["src"] = "excel"
    try:
        write_timetable_json(d)
    except Exception:
        pass
    return d


# ---------------- 自动点「导出」 ----------------
# 用户原话：「不要让用户需要拖拽文件到 APP，直接识别」。
# 所以干脆连「让用户自己去点导出」都省掉 —— 我们替他点。
#
# ★ 这一步的坑（踩过才知道）：
#   ① 表头里有**两个** UploadFile 图标。左边那个 visible + pointer-events:auto
#      才是「导出」，右边那个是 hidden + pointer-events:none（学校自己排的备用位）。
#      按 DOM 顺序取第一个会点到那个点不动的 —— 于是「点了毫无反应」。
#   ② `el.click()` / `dispatchEvent(new MouseEvent('click'))` **都点不动**它
#      （antd 的合成事件链不认纯 JS 派发的点击），必须走 CDP 的
#      `Input.dispatchMouseEvent`（真·浏览器鼠标事件）。
#   ③ 点完不是直接下载，而是弹一个「导出课程」小窗，要再点「确定」才下。

_EXPORT_BTN_JS = r"""
(() => {
  const out = [];
  const cands = document.querySelectorAll('[data-test-id="UploadFile"]');
  for (let i = 0; i < cands.length; i++) {
    const it = cands[i];
    const b = it.closest('button') || it;
    const r = b.getBoundingClientRect();
    const cs = getComputedStyle(b);
    if (r.width < 4 || r.height < 4) continue;
    if (cs.visibility === 'hidden' || cs.display === 'none') continue;
    if (cs.pointerEvents === 'none') continue;
    out.push({x: Math.round(r.x + r.width / 2), y: Math.round(r.y + r.height / 2)});
  }
  return JSON.stringify(out);
})()
"""

# 读一眼当前的小窗。希悦在这一串流程里会弹**两个**窗：
#   ① 「导出课程」——选格式（Excel/PDF）和信息项，点「确定」
#   ② 「准备完毕，正在下载…」——里面有一个可点的文件名（自动下载被浏览器
#      拦掉时的兜底入口），点它才会真的落盘
# 这一步踩过的坑：只看 ①，点完 ① 之后 ② 盖在上面，下一次再点图标就
# 永远弹不出 ① 了 —— 表现是「第一次成功、之后次次失败」。
_MODAL_JS = r"""
(() => {
  const ms = Array.from(document.querySelectorAll('.ant-modal-content'));
  const out = {kind: '', excel: null, all: null, ok: null, cancel: null,
               close: null, file: null, fileAt: null};
  // ★ 按钮文字里可能夹着空格（实测「关 闭」就是「关」「空」「闭」），
  //   直接 === '关闭' 永远匹配不上 —— 先把空白全去掉再比。
  function norm(s) { return ((s || '') + '').replace(/\s+/g, ''); }
  function center(el) {
    if (!el) return null;
    const r = el.getBoundingClientRect();
    if (r.width < 2 || r.height < 2) return null;
    return {x: Math.round(r.x + r.width / 2), y: Math.round(r.y + r.height / 2)};
  }
  function pick(list, label) {
    return Array.from(list).filter(e => norm(e.innerText) === label)[0];
  }
  for (let i = ms.length - 1; i >= 0; i--) {
    const m = ms[i];
    const text = (m.innerText || '') + '';
    if (text.indexOf('准备完毕') >= 0 || text.indexOf('正在下载') >= 0) {
      out.kind = 'done';
      out.close = center(pick(m.querySelectorAll('button'), '关闭'));
      const tip = Array.from(m.querySelectorAll('.ant-typography'))
        .filter(e => norm(e.innerText).length > 4)[0];
      if (tip) { out.fileAt = center(tip); out.file = norm(tip.innerText); }
      return JSON.stringify(out);
    }
    if (text.indexOf('导出') >= 0) {
      out.kind = 'config';
      function box(label) {
        const bs = Array.from(m.querySelectorAll('.ant-checkbox-wrapper'));
        for (let j = 0; j < bs.length; j++) {
          if (norm(bs[j].innerText) === label) {
            return {checked: String(bs[j].className).indexOf('checked') >= 0,
                    at: center(bs[j])};
          }
        }
        return null;
      }
      out.excel = box('Excel');
      out.all = box('全选');
      out.ok = center(pick(m.querySelectorAll('button'), '确定'));
      out.cancel = center(pick(m.querySelectorAll('button'), '取消'));
      return JSON.stringify(out);
    }
    // 认不出来的窗（比如「关于」）：先把它关掉，免得挡住后面所有点击
    out.kind = 'other';
    out.close = center(pick(m.querySelectorAll('button'), '关闭'))
             || center(pick(m.querySelectorAll('.ant-modal-close'), ''));
    return JSON.stringify(out);
  }
  return JSON.stringify(out);
})()
"""


def _modal(page):
    try:
        return json.loads(_eval(page, _MODAL_JS, timeout=8) or "{}")
    except Exception:
        return {}


def _dismiss_modals(page, rounds=3):
    """把页面上残留的小窗收掉 —— 手工点过一次导出之后，下一个「准备完毕」
    窗会一直挂着，不关掉的话后续任何点击都落在遮罩上（点什么都不动）。"""
    for _ in range(rounds):
        m = _modal(page)
        if m.get("kind") == "config":
            at = m.get("cancel") or m.get("close")
            if not at:
                return
            _real_click(page, at["x"], at["y"])
        elif m.get("kind") in ("done", "other"):
            at = m.get("close")
            if not at:
                return
            _real_click(page, at["x"], at["y"])
        else:
            return
        time.sleep(0.5)


def _xlsx_before():
    """记一下现在有哪些 xlsx（名字+大小），好认出「新下下来的那一个」。"""
    seen = set()
    for d in _SCAN_DIRS:
        try:
            for fn in os.listdir(d):
                if fn.lower().endswith(".xlsx") and not fn.startswith("~$"):
                    seen.add(os.path.join(d, fn))
        except Exception:
            continue
    return seen


def _newest_xlsx(before):
    cands = []
    for d in _SCAN_DIRS:
        try:
            for fn in os.listdir(d):
                if not fn.lower().endswith(".xlsx") or fn.startswith("~$"):
                    continue
                p = os.path.join(d, fn)
                if p in before:
                    continue
                try:
                    st = os.stat(p)
                except Exception:
                    continue
                cands.append((st.st_mtime, p))
        except Exception:
            continue
    cands.sort(reverse=True)
    return cands[0][1] if cands else None


def export_via_page(timeout=50.0):
    """替用户把「导出课表」点一遍，然后吃掉下下来的那张表。

    返回 (新文件路径 or None, 说明文字)。不抛异常 —— 这条路走不通时，
    上层会退回「扫 Downloads」和「抠格子」，用户不该看到一个红叉。
    """
    if not cdp_up():
        return None, "希悦的浏览器没开着"
    p = seiue_page()
    if not p:
        return None, "没有可用的希悦页面"
    try:
        _set_download_dir()
    except Exception:
        pass

    # 先把残留的小窗收掉（否则后面所有点击都会落在遮罩上，看着像「点不动」）
    try:
        _dismiss_modals(p)
    except Exception:
        pass

    # 确保停在首页，且课表容器已经渲染出来（导出按钮在它的表头里）
    _navigate_home(p, timeout=12.0)
    btn = None
    end = time.time() + 12
    while time.time() < end:
        try:
            arr = json.loads(_eval(p, _EXPORT_BTN_JS, timeout=8) or "[]")
        except Exception:
            arr = []
        if arr:
            btn = arr[0]
            break
        time.sleep(0.6)
    if not btn:
        return None, "页面上没找到「导出」按钮"

    before = _xlsx_before()
    _real_click(p, btn["x"], btn["y"])

    # 等「导出课程」配置窗
    plan = {}
    end = time.time() + 8
    while time.time() < end:
        plan = _modal(p)
        if plan.get("kind") == "config":
            break
        time.sleep(0.4)
    if plan.get("kind") != "config":
        return None, "点了导出但没弹出选择窗口"
    time.sleep(0.4)

    # 配置窗里：确保选中 Excel → 勾上「全选」→ 确定
    ex = plan.get("excel")
    if ex and ex.get("at") and not ex.get("checked"):
        _real_click(p, ex["at"]["x"], ex["at"]["y"])
        time.sleep(0.4)
    plan = _modal(p)
    allb = plan.get("all")
    if allb and allb.get("at") and not allb.get("checked"):
        _real_click(p, allb["at"]["x"], allb["at"]["y"])
        time.sleep(0.4)
    plan = _modal(p)
    ok = plan.get("ok")
    if not ok:
        return None, "导出窗口里没找到「确定」"
    _real_click(p, ok["x"], ok["y"])

    # 等文件落盘。Chrome 先写 .crdownload，写完才改名。
    # 有的环境下浏览器不自动落盘，得点一下「准备完毕」窗里那个文件名才会真的下载
    # —— 所以先给它 4 秒自己下，没动静再点。**不能一看到窗就点**：那样
    # 自动下载 + 手动点会各下一份，用户的「下载」文件夹里立刻多一个同名副本。
    end = time.time() + timeout
    seen_at = None
    clicked_link = False

    def _ready():
        got = _newest_xlsx(before)
        if not got:
            return None
        return None if os.path.exists(got + ".crdownload") else got

    while time.time() < end:
        got = _ready()
        if got:
            time.sleep(0.5)              # 给它一点时间写完整
            if _ready():
                return got, ""
        m = _modal(p)
        if m.get("kind") == "done" and m.get("fileAt"):
            if seen_at is None:
                seen_at = time.time()
            elif not clicked_link and time.time() - seen_at > 4.0:
                _real_click(p, m["fileAt"]["x"], m["fileAt"]["y"])
                clicked_link = True
        time.sleep(0.6)
    return None, "点了导出，但没等到文件"


def _adopt(path):
    """把「我们刚替用户下下来的那张表」搬进 <数据目录>/seiue-downloads。

    为什么要搬：希悦给文件起的是「张明 2026-2027 上学期 学生课表.xlsx」这种
    名字，重下一次就是「… (1).xlsx」「… (2).xlsx」。连点几次同步，用户的
    「下载」文件夹就被我们塞满了一堆同内容的副本 —— 那是很讨厌的事。
    搬过来之后统一叫「课表.xlsx」，每次覆盖，用户的下载夹保持原样。

    只搬**这一次导出产生的那一个文件**，绝不碰用户自己的别的下载件。
    """
    try:
        if os.path.dirname(os.path.abspath(path)) == os.path.abspath(EXPORT_DIR):
            return path
        os.makedirs(EXPORT_DIR, exist_ok=True)
        dst = os.path.join(EXPORT_DIR, "课表.xlsx")
        try:
            if os.path.exists(dst):
                os.remove(dst)
        except Exception:
            pass
        os.replace(path, dst)
        return dst
    except Exception:
        return path


def export_and_import():
    """点导出 → 吃表 → 落成课表缓存。失败就返回 ok=False（上层会退别的路）。"""
    path, why = export_via_page()
    if not path:
        return {"ok": False, "error": why, "days": [], "periods": [], "lessons": []}
    path = _adopt(path)
    d = parse_schedule_xlsx(path)
    if not d.get("ok"):
        return d
    d["ts"] = time.time()
    with _lock:
        _CACHE.update({"data": d, "ts": time.time(), "error": None, "src": "excel"})
    try:
        write_timetable_json(d)
    except Exception:
        pass
    return d


# 希悦导出的课表 → 课程页用的「周课表模板」（timetable.json）。
# 相邻的同一门课合并成一段（P1-P2 连堂就写成一个 from=1,to=2 的块），
# 这样课程页那一周看起来是「一段一段的课」，而不是一格一格散着。
_SUBJECT_COLOR = [
    ("calc", ("微积分", "数学", "Calculus", "Math")),
    ("eng", ("英语", "ELA", "English", "托福")),
    ("chem", ("化学", "Chem")),
    ("phys", ("物理", "Phys")),
    ("bio", ("生物", "Bio")),
    ("chinese", ("语文", "Chinese")),
    ("his", ("历史", "History", "政治", "政", "地理史")),
    ("geo", ("地理", "Geo")),
    ("ids", ("跨学科", "信息技术", "计算机", "CS")),
    ("art", ("美术", "音乐", "艺术")),
    ("pe", ("体育", "PE")),
]


def _subject_color(name):
    for key, words in _SUBJECT_COLOR:
        for w in words:
            if w.lower() in (name or "").lower():
                return key
    return "guide"


def write_timetable_json(sched):
    """把解析出来的课表写成 timetable.json（1=周一 … 7=周日）。

    这一份是「课程」页真正渲染的那张周表。以前它只能从 DOM 抠，
    一页看不见的课就丢了；现在直接用导出表，一节不漏。
    """
    lessons = sched.get("lessons") or []
    if not lessons:
        return False
    by_day = {}
    for l in lessons:
        by_day.setdefault(int(l.get("dayIndex") or 0), []).append(l)
    out = {}
    for day, lst in by_day.items():
        lst.sort(key=lambda x: int(x.get("periodIndex") or 0))
        blocks = []
        for l in lst:
            name = (l.get("name") or "").strip()
            ex = list(l.get("extra") or [])
            # 第一行备注是「班级 教室 老师」，第二行是「时间 周次」——
            # 老师只在第一行里找，别去第二行（那里全是数字，「每周[1-20]」会被误当成人名）。
            note = ex[0] if ex else ""
            room = ""
            room_m = re.search(r"\b([A-Z]{1,2}\d{2,4}|[^\s]{2,10}教室)\b", note)
            if room_m:
                room = room_m.group(1)
            # 老师：从末尾往前收「连续不含数字的词」。
            # "Grade 10 跨学科学习3班 E103 Peter Nolan" → Peter Nolan
            # "Grade 10 21班 E106"（没有老师）→ 空
            toks = [t for t in note.split() if t]
            tail = []
            for t in reversed(toks):
                if any(ch.isdigit() for ch in t) or t in ("Grade", "年级"):
                    break
                if t == room or any(k in t for k in ("教室", "实验室", "楼", "馆", "室")):
                    break
                tail.insert(0, t)
            teacher = " ".join(tail)
            if len(teacher) > 16:
                teacher = tail[-1] if tail else ""
            mode = "走班" if "班" in note else "课程"
            p = int(l.get("periodIndex") or 0) + 1
            if blocks and blocks[-1]["subject"] == name and blocks[-1]["to"] == p - 1 \
                    and blocks[-1]["teacher"] == teacher:
                blocks[-1]["to"] = p
            else:
                blocks.append({"from": p, "to": p, "subject": name, "room": room,
                               "teacher": teacher, "mode": mode,
                               "color": _subject_color(name)})
        out[str(day + 1)] = blocks
    if not out:
        return False
    dst = os.path.join(MBB, "timetable.json")
    tmp = dst + ".tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump(out, f, ensure_ascii=False, indent=2)
    os.replace(tmp, dst)
    return True


# ==========================================================================
# 三、登录状态
# ==========================================================================

# 只要页面上没有登录框、且不在登录页，就认为已经登进去了。
# 这里刻意不做更激进的判断 —— 希悦的会话是 HttpOnly cookie，从 JS 里读不到。
_PROBE = r"""
(() => {
  const hasPwd = !!document.querySelector('input[type=password]');
  const href = location.href;
  const onLogin = /login|signin|auth/i.test(href);
  const body = (document.body ? document.body.innerText : "").slice(0, 4000);
  const looksLogin = /登录|账号|密码|sign in/i.test(body) && hasPwd;
  const ready = !!document.querySelector('[data-test-id="seiue-schedule-container"]')
             || !!document.querySelector('.seiue-schedule-container');
  return JSON.stringify({href, hasPwd, onLogin, looksLogin, ready,
                         title: document.title, bodyLen: body.length});
})()
"""


def _close_tab(target_id):
    if not target_id:
        return False
    target = "http://127.0.0.1:%d/json/close/%s" % (PORT, target_id)
    for method in ("PUT", "GET"):
        try:
            req = urllib.request.Request(target, method=method)
            with urllib.request.urlopen(req, timeout=6) as r:
                r.read()
            return True
        except Exception:
            continue
    return False


def dedupe_pages(keep=1):
    """同址标签只留 `keep` 个，其余关掉。返回关掉了几个。

    为什么要专门做这件事：`ensure_browser` 以前每被调一次就 `_open_tab` 一次，
    「打开希悦登录」点两下就是三个一模一样的工作台；而 `seiue_page()` 取 ps[0]，
    抓取于是会随机落到一个刚开、还没渲染完的标签上 —— 用户看到的就是
    「课表这次有下次没有」。这个坑 Teams 那边早踩过并防住了。
    """
    ps = [p for p in pages() if "seiue.com" in (p.get("url") or "")]
    if len(ps) <= keep:
        return 0
    # 优先留「已经渲染出课表容器」的那个 —— 它就是能出数据的那一个
    best = None
    for p in ps:
        try:
            st = json.loads(_eval(p, _PROBE, timeout=5) or "{}")
        except Exception:
            st = {}
        if st.get("ready"):
            best = p
            break
    if best is None:
        best = ps[0]
    n = 0
    for p in ps:
        if p.get("id") == best.get("id"):
            continue
        if _close_tab(p.get("id")):
            n += 1
    if n:
        time.sleep(0.6)
    return n


def _page_state(timeout=25):
    """读一眼当前页面状态。timeout 是单次 CDP 调用的上限。"""
    if not cdp_up():
        return {}
    p = seiue_page()
    if not p:
        return {}
    try:
        return json.loads(_eval(p, _PROBE, timeout=timeout) or "{}")
    except Exception:
        return {}


def probe():
    """看一眼当前页面：有没有登录框、在不在首页、课表容器在不在。"""
    return _page_state(25)


def logged_in(fast=False):
    # fast=True 给「等页面就绪」的轮询用：一轮最多 6 秒，轮询才转得动。
    # 否则一次 probe 内部就有 25 秒上限，几十轮叠起来能拖十来分钟。
    info = _page_state(6 if fast else 25)
    if not info:
        return False
    if info.get("hasPwd") or info.get("onLogin") or info.get("looksLogin"):
        return False
    try:
        with open(_MARKER, "w") as f:
            f.write(str(time.time()))
    except Exception:
        pass
    return True


def has_session():
    return os.path.exists(_MARKER)


def forget_session():
    try:
        os.remove(_MARKER)
    except Exception:
        pass
    _CACHE.update({"data": None, "ts": 0.0})


def logout():
    forget_session()


# ==========================================================================
# 四、把课表从页面上抠下来
# ==========================================================================

# 为什么不再用「关键字选择器」：
#   希悦是 styled-components，class 是 `sc-kNjblg gWlwqu` 这种哈希，
#   里面 **不含** course / lesson / card 任何业务词 —— 按关键字捞必然落空。
#   希悦自己留了稳定的测试钩子（data-test-id）和语义类名（seiue-schedule-*），
#   这些是跟着业务走的，改配色/改样式不会动它们，所以用它们来定位。
_EXTRACT = r"""
(() => {
  const out = {href: location.href, title: document.title, ready: false,
               err: "", days: [], periods: [], events: []};
  const box = document.querySelector('[data-test-id="seiue-schedule-container"]')
           || document.querySelector('.seiue-schedule-container');
  if (!box) {
    out.err = "页面上没有课表容器（可能不在首页，或者没登录）";
    return JSON.stringify(out);
  }

  // ① 星期条：item-0..6 → [日期, 周X]
  const bar = [];
  box.querySelectorAll('[data-test-id^="seiue-schedule-container-weekday-bar-item-"]')
     .forEach(e => {
    const i = parseInt((e.getAttribute("data-test-id") || "").split("-").pop(), 10);
    if (!(i >= 0)) return;
    const r = e.getBoundingClientRect();
    const ts = (e.innerText || "").split("\n").map(x => x.trim()).filter(Boolean);
    const rec = {i: i, date: ts[0] || "",
                 label: ts.find(t => /周|星期/.test(t)) || "",
                 x: Math.round(r.left), w: Math.round(r.width)};
    bar[i] = rec;
    out.days[i] = rec.label || rec.date || ("第" + (i + 1) + "列");
  });
  const barOk = bar.filter(Boolean).length === 7;

  // ② 节次：左侧时间轴（每行形如「P1 08:00 - 08:40」）
  const lv = box.querySelector(".seiue-schedule-lesson-view");
  if (lv) {
    lv.querySelectorAll(":scope > *").forEach(row => {
      const t = (row.innerText || "").replace(/\s+/g, " ").trim();
      if (!t) return;
      const tm = /(\d{1,2}:\d{2})\s*[-–~至]\s*(\d{1,2}:\d{2})/.exec(t);
      const pm = /^(P\d+)/.exec(t);
      out.periods.push({
        label: pm ? pm[1] : "",
        time: tm ? (tm[1] + "-" + tm[2]) : "",
        text: t.slice(0, 60)
      });
    });
  }

  // ③ 日历网格里的每一节课
  const cal = box.querySelector(".seiue-schedule-week-calendar");
  if (cal) {
    const cb = cal.getBoundingClientRect();
    const colW = cb.width / 7;
    cal.querySelectorAll(".seiue-schedule__event-title").forEach(h => {
      const card = h.closest("div[style]") || h.parentElement;
      if (!card) return;
      const r = card.getBoundingClientRect();
      const cx = r.left + r.width / 2;

      // 认周几：优先拿星期条比，条子不全时退回「七等分」几何
      let day = -1;
      if (barOk) {
        for (let k = 0; k < 7; k++) {
          const b = bar[k];
          if (!b) continue;
          if (cx >= b.x - 2 && cx < b.x + b.w + 2) { day = k; break; }
        }
      }
      if (day < 0 && colW > 0) day = Math.round((r.left - cb.left) / colW);
      if (day < 0) day = 0;
      if (day > 6) day = 6;

      const lines = (card.innerText || "").split("\n").map(x => x.trim()).filter(Boolean);
      const tmLine = lines.find(x => /\d{1,2}:\d{2}\s*[-–~至]\s*\d{1,2}:\d{2}/.test(x)) || "";
      const tmNorm = (tmLine.match(/(\d{1,2}:\d{2})\s*[-–~至]\s*(\d{1,2}:\d{2})/) || []);
      out.events.push({
        title: (h.innerText || "").trim(),
        color: h.getAttribute("color") || "",
        dayIndex: day,
        time: tmNorm.length === 3 ? (tmNorm[1] + "-" + tmNorm[2]) : "",
        info: lines.filter(x => x !== tmLine).slice(1),
        top: Math.round(r.top - cb.top),
        height: Math.round(r.height)
      });
    });
  }

  out.ready = true;
  return JSON.stringify(out);
})()
"""


def _navigate_home(page, timeout=14.0):
    """确保页面停在希悦首页 —— 课表就挂在那里。"""
    info = probe()
    if info.get("ready") and "seiue.com" in (info.get("href") or ""):
        return True
    href = info.get("href") or ""
    needs_go = not (href.rstrip("/") == SITE or href.rstrip("/") == SITE)
    if needs_go:
        try:
            _eval(page, "location.href=%s; 'go'" % json.dumps(HOME_URL))
        except Exception:
            pass
    end = time.time() + timeout
    while time.time() < end:
        time.sleep(0.6)
        try:
            cur = seiue_page()
            if not cur:
                continue
            raw = _eval(cur, _EXTRACT, timeout=12)
            d = json.loads(raw or "{}")
            if d.get("ready"):
                return True
        except Exception:
            continue
    return False


def normalize(raw):
    """把抓来的东西整理成「周几 × 第几节」的结构。

    输出契约（Swift 那边的 SeiueSchedule 就是按这个解的）：
      {ok, error, days[], periods[], lessons[{day,dayIndex,period,periodIndex,
       text,name,extra[]}], columns, rows, tables, href, title}
    """
    events = raw.get("events") or []
    days = raw.get("days") or []
    periods = raw.get("periods") or []

    if not events:
        return {"ok": False, "error": raw.get("err") or "课表页还没打开（在希悦首页才行）",
                "days": days, "periods": [p.get("text") or p.get("label") or "" for p in periods],
                "lessons": [], "columns": len(days), "rows": len(periods),
                "tables": 0, "href": raw.get("href", ""), "title": raw.get("title", "")}

    # 节次展示用「P3 10:00-10:40」这种，一眼能对上教室门口的作息表
    per_label = []
    per_time = {}
    for i, p in enumerate(periods):
        lbl = (p.get("label") or "").strip()
        tm = (p.get("time") or "").strip()
        per_label.append((lbl + " " + tm).strip() if (lbl or tm) else ("第%d节" % (i + 1)))
        if tm:
            per_time[tm] = i

    # 时间串兜底：节次行没抓全时，用时间直接算序号
    def period_index(time_str, fallback):
        if time_str and time_str in per_time:
            return per_time[time_str]
        return fallback

    # 先按 (周几, 时间) 排个序，让界面里每列从上到下就是一天的顺序
    def sort_key(e):
        return (e.get("dayIndex", 0), e.get("top", 0))

    lessons = []
    used = set()
    for k, e in enumerate(sorted(events, key=sort_key)):
        di = int(e.get("dayIndex", 0) or 0)
        di = 0 if di < 0 else (6 if di > 6 else di)
        # 兜底序号：同一列内第几个
        fallback = len([1 for x in lessons if x["dayIndex"] == di])
        pi = period_index(e.get("time", ""), fallback)
        name = (e.get("title") or "").strip() or "—"
        extra = [x for x in (e.get("info") or []) if x and x != name]
        label = per_label[pi] if 0 <= pi < len(per_label) else ("第%d节" % (pi + 1))

        key = (di, pi, name)
        # 同一个格子被重复渲染（希悦会叠一层导出用的副本）时只留一条
        if key in used:
            continue
        used.add(key)

        lessons.append({
            "day": days[di] if 0 <= di < len(days) else ("第%d列" % (di + 1)),
            "dayIndex": di,
            "period": label,
            "periodIndex": pi,
            "text": " ".join([name] + extra),
            "name": name,
            "extra": extra,
        })

    return {"ok": True, "error": "",
            "days": [d or ("第%d列" % (i + 1)) for i, d in enumerate(days)],
            "periods": per_label,
            "lessons": lessons,
            "columns": len(days), "rows": len(per_label),
            "tables": 1, "href": raw.get("href", ""), "title": raw.get("title", "")}


def fetch(force=False, timeout=60):
    """抓一次课表。结果按 TTL 缓存。

    优先级：**网页导出的 xlsx** > 从页面上抠格子。
    理由见上半部分「识别网页导出的课表 Excel」：抠格子天生会漏掉
    一屏之外的第 8 节课，而导出表是整张的。

    ★ 一个真实的坑：这个 TTL 缓存曾经把 xlsx 通道整个盖住 ——
      先用抠格子填上缓存（只有 8 节），用户随后导出了 Excel（9 节），
      但一小时内再来问，命中的还是那份旧的抠格子结果，界面看着像
      「它根本没认我的表」。所以现在「有没有导出表」这一条**排在 TTL 前面**：
      表在那儿就用表，缓存只用来省掉「每次都去抠格子」。
    """
    # ① 有没有「网页导出的课表」——有就直接用，不受 TTL 影响。
    try:
        cached_src = (_CACHE.get("data") or {}).get("source")
        if force or cached_src != "excel":
            imported = import_exported()
            if imported and imported.get("ok"):
                imported["loggedIn"] = True
                return imported
    except Exception as e:
        _CACHE["error"] = "读导出的课表失败：%s" % e

    with _lock:
        if not force and _CACHE["data"] and time.time() - _CACHE["ts"] < TTL:
            return _CACHE["data"]

        if not cdp_up():
            d = {"ok": False, "error": "希悦浏览器还没起来", "loggedIn": False,
                 "days": [], "periods": [], "lessons": []}
            return d
        # 先把同址的重复标签收掉，保证下面读到的就是「那一个」页面
        try:
            dedupe_pages()
        except Exception:
            pass
        p = seiue_page()
        if not p:
            d = {"ok": False, "error": "没有可用的希悦页面", "loggedIn": False,
                 "days": [], "periods": [], "lessons": []}
            return d

        info = probe()
        if info.get("hasPwd") or info.get("onLogin") or info.get("looksLogin"):
            d = {"ok": False, "error": "希悦还没登录", "loggedIn": False,
                 "days": [], "periods": [], "lessons": []}
            return d

        # ★ 关键：课表在首页，先回首页再读
        if not _navigate_home(p, timeout=min(14.0, max(6.0, timeout * 0.4))):
            d = {"ok": False, "error": "没能打开希悦首页（课表在那里）",
                 "loggedIn": logged_in(), "days": [], "periods": [], "lessons": []}
            _CACHE["error"] = d["error"]
            return d

        # 读页面的那一刻，课表可能还在渲染（刚导航过来时尤其常见）。
        # 以前读一次是空就认输 —— 用户看到「页面上没找到课表格子」，
        # 可过两秒再点一下又有。现在给它一小段自我修复的时间。
        raw, last_err = {}, ""
        for attempt in range(6):
            try:
                p = seiue_page() or p
                raw = json.loads(_eval(p, _EXTRACT, timeout=timeout) or "{}")
                last_err = raw.get("err") or ""
            except Exception as e:
                raw, last_err = {}, "读取页面失败：%s" % e
            if raw.get("events"):
                last_err = ""
                break
            if attempt < 5:
                time.sleep(1.0)

        res = normalize(raw)
        if last_err and not res.get("ok"):
            res["error"] = last_err
        res["loggedIn"] = True
        res["ts"] = int(time.time() * 1000)
        if res.get("ok"):
            _CACHE.update({"data": res, "ts": time.time(), "error": None})
        else:
            _CACHE["error"] = res.get("error")
        return res


def status():
    # 只读页面**一次**。以前这里是 `probe()` 加 `logged_in()`，而 logged_in()
    # 内部又 probe 一遍 —— 每次请求白跑两趟 CDP。看板每切一次分区就问一次，
    # 一秒钟能问出好几趟来。
    up = cdp_up()
    info = _page_state(10) if up else {}
    logged = False
    if info and not (info.get("hasPwd") or info.get("onLogin") or info.get("looksLogin")):
        logged = True
        try:
            with open(_MARKER, "w") as f:
                f.write(str(time.time()))
        except Exception:
            pass
    return {
        "ok": True,
        "browserUp": up,
        "loggedIn": logged,
        "hasSession": has_session(),
        "chrome": bool(chrome_path()),
        "cached": bool(_CACHE["data"]),
        "cachedAt": int(_CACHE["ts"] * 1000) if _CACHE["ts"] else 0,
        "error": _CACHE.get("error") or "",
        # xlsx 这条通道：让界面能直接说「已识别网页导出的课表」
        "fromExcel": bool((_CACHE.get("data") or {}).get("source") == "excel"),
        "excelFile": os.path.basename((_CACHE.get("data") or {}).get("file") or ""),
        # 告诉前端「人已经在首页、课表容器也在」，排错时一眼看出卡在哪
        "onHome": bool(info.get("ready")),
        "href": info.get("href") or "",
    }


def connect(budget=75.0):
    """给「立即同步」用：确保浏览器起来并停在首页，然后抓一次。

    ⚠️ 这里以前是「循环 30 次，每次 probe + 睡 0.5 秒」—— 看着像 15 秒封顶，
    其实**没有时间上限**：probe 内部的 CDP 调用自己的超时就有 25 秒，
    页面卡住时一轮就是 25 秒，30 轮叠起来能拖到十几分钟。而前端只等 120 秒，
    表现就是「点了同步，转圈转到超时」。现在按**墙钟时间**收口。
    """
    ensure_browser(HOME_URL)
    end = time.time() + budget
    while time.time() < end:
        if logged_in(fast=True):
            return fetch(force=True)
        time.sleep(0.8)
    if not logged_in():
        return {"ok": False, "needsLogin": True,
                "msg": "请在打开的窗口里登录希悦，登录后会自动同步"}
    return fetch(force=True)


def sync_now(budget=70.0):
    """「立即同步」的入口：**先替用户把「导出」点一遍**，不行再退回抓页面。

    为什么要抢这一步：导出表是整张课表（连第 9 节和上课周都写全了），
    而页面上一次只画得下 6~7 行。用户的原话是「不要让用户需要拖拽文件到
    App，直接识别」—— 那就再进一步：连「自己去点导出」都不用他做。
    """
    try:
        ensure_browser(HOME_URL)
    except Exception:
        pass
    if logged_in(fast=True):
        d = export_and_import()
        if d.get("ok"):
            return d
    r = connect(budget=budget)
    return r


def open_home():
    """把希悦窗口调到首页并**摆到屏幕正中**（用户点「打开课表页」时用）。

    顺便把下载目录指到 <数据目录>/seiue-downloads：用户在窗口里点
    「导出课表」时，文件会直接落进我们能看见的地方，随后自动被认出来。
    """
    ok = ensure_browser(HOME_URL)
    time.sleep(0.8)
    try:
        dedupe_pages()          # 点两下就多一个标签，顺手收掉
    except Exception:
        pass
    show_browser()
    return {"ok": bool(ok), "loggedIn": logged_in(fast=True) if ok else False}


if __name__ == "__main__":
    import sys
    cmd = sys.argv[1] if len(sys.argv) > 1 else "status"
    if cmd == "status":
        print(json.dumps(status(), ensure_ascii=False, indent=2))
    elif cmd == "login":
        print(json.dumps({"ok": ensure_browser(HOME_URL)}, ensure_ascii=False))
    elif cmd == "fetch":
        print(json.dumps(fetch(force=True), ensure_ascii=False)[:4000])
    else:
        print("用法：seiue.py [status|login|fetch]")
