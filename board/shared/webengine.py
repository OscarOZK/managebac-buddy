#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""内置网页引擎 —— Python 侧的客户端 + agent-browser 兼容命令行。

它解决的是什么
--------------
看板有三条链路非要一个「真浏览器」不可：

    ManageBac  填表登录、读登录后的页面、导出时收文件
    Teams      用户在窗口里登录 → 从 localStorage 取 Graph 令牌
    希悦        用户在窗口里登录、点导出、把 xlsx 收下来

以前它们都靠一个**外部 Chromium**（agent-browser / Chrome for Testing）。
问题是：别人电脑上十有八九没有 Chromium，作者这台开发机也没有。
于是四条链路里唯一能用的那个（DeepSeek）恰好是唯一不需要浏览器的。
而「没有就自动下一份」要等 150MB，国内还常常只有镜像通得了。

所以浏览器被搬进了 App 自己身体里（board/mac/Shared/WebEngine.swift，
用 macOS 自带的 WebKit，一个字节都不用下）。这个模块是它在 Python 侧的
代理：对外给出和原来一模一样的能力，让三条业务链路**一行业务代码都不用改**。

怎么走的
--------
完全复用现有的那条 8765 通道，不新增端口、不新增协议：

    Swift   → GET  /api/webengine/poll      长轮询领一条指令（bridge.py 里）
    Python  → 把指令塞进队列（就是本模块的 _QUEUE），等结果
    Swift   → POST /api/webengine/result    交答案

本进程（backend）直接用内存队列；被当成命令行调起来时（bridge.py 的
_ab_raw 会 fork 一个进程）走 HTTP 的 /api/webengine/call。
两条路的语义完全一样。

命令行形态刻意做成 **agent-browser 的兼容层**：
    <python> webengine.py --session-name X open https://… 
    <python> webengine.py --session-name X eval --stdin   （JS 从 stdin 读）
    <python> webengine.py --session-name X wait 2500
    <python> webengine.py --session-name X cookies get --json
    <python> webengine.py --session-name X cookies set k v --domain d …
    <python> webengine.py --session-name X close --all
这样 bridge.py 里调用 agent-browser 的那些代码（_ab_raw / ab / ab_eval）
一个字都不用动，只要把「AB 指向谁」换掉即可。
"""
import json
import os
import sys
import threading
import time
import urllib.error
import urllib.request
import uuid
from collections import deque

try:
    import netlocal as _netlocal
except Exception:                                        # pragma: no cover
    _netlocal = None

PORT = int(os.environ.get("MBBOARD_PORT") or 8765)
BASE = "http://127.0.0.1:%d" % PORT

# 内置引擎不在线时给用户看的话。故意说清楚「下一步做什么」，
# 因为这句话会一路显示到界面上（bridge 的 _ab_err_text 不做加工时原样透出）。
NOT_ONLINE = ("内置网页引擎还没有就绪。请退出看板（⌘Q）后重新打开；"
              "如果还是这样，说明这次启动没跑起来，请把这句话截图反馈。")

# ---------------------------------------------------------------------------
# 一、指令队列（本进程内）
# ---------------------------------------------------------------------------

_LOCK = threading.RLock()
_QUEUE = deque()            # [{"id","op","args"}]  等待 Swift 取走
_WAIT = {}                  # id -> threading.Event
_RESULT = {}                # id -> {"ok","value","error"}

_INFLIGHT = [0]             # 正在被占用的长轮询连接数
_LAST_SEEN = [0.0]          # 最近一次和 Swift 打上交道的时间

# Swift 空闲时会一直挂在一条长轮询上（wait=20 秒），所以「有没有人在」
# 不能只看时间戳，还要看有没有连接正在挂着。两者取或。
_SEEN_WINDOW = 20.0


def note_poll_start():
    """Swift 开始一次长轮询。"""
    with _LOCK:
        _INFLIGHT[0] += 1
        _LAST_SEEN[0] = time.time()


def note_poll_end():
    with _LOCK:
        _INFLIGHT[0] = max(0, _INFLIGHT[0] - 1)
        _LAST_SEEN[0] = time.time()


def note_deliver():
    with _LOCK:
        _LAST_SEEN[0] = time.time()


def attached():
    """App 里的引擎还在轮询吗？不在就说明这台机器上没有内置引擎
    （典型情况：Windows 版、或者单独把 bridge.py 拎出来跑）。"""
    with _LOCK:
        if _INFLIGHT[0] > 0:
            return True
        return (time.time() - _LAST_SEEN[0]) < _SEEN_WINDOW


def take_pending():
    """Swift 来领活。没有就返回 None。"""
    with _LOCK:
        if not _QUEUE:
            return None
        return _QUEUE.popleft()


def deliver(cid, ok, value=None, error=""):
    """Swift 交答案。"""
    note_deliver()
    with _LOCK:
        ev = _WAIT.pop(cid, None)
        if ev is None:
            # 已经超时走掉了。不要留在 _RESULT 里烂掉。
            return False
        _RESULT[cid] = {"ok": bool(ok), "value": value, "error": error or ""}
    ev.set()
    return True


def pending_count():
    with _LOCK:
        return len(_QUEUE)


# ---------------------------------------------------------------------------
# 一·五、窗口状态（Teams / 希悦 / 看板 共用同一个窗口，必须放这里）
# ---------------------------------------------------------------------------
#
# ★ 为什么这份记账不能各模块自己存一份 ★
#   CDP 时代 Teams 和希悦是**两个独立的浏览器进程**，各自的窗口互不干涉，
#   所以 mssession.py 和 seiue.py 可以各记各的「窗口摆出来了没有」。
#   内置引擎只有一个 App 窗口（WebEngine.swift 里的 `window`），两个模块
#   共用它。如果状态各存一份，就会出现这种事故：
#
#       用户正在窗口里登希悦 → Teams 的后台保活醒来 → 它查自己那份记账
#       发现「窗口是 normal，得藏起来」→ 把用户正在登录的窗口一把藏掉。
#
#   表现就是「登录页刚打开两秒就自己不见了」，而且必然复现、必然难查。
#   所以状态和「别动它」的窗口期统一放在这里，三个模块都问这一份。

_WIN = {"shown": False, "hold_until": 0.0}


def mark_shown(on):
    """记下「窗口现在是不是给用户看了」。"""
    with _LOCK:
        _WIN["shown"] = bool(on)


def shown():
    with _LOCK:
        return bool(_WIN["shown"])


def hold_window(seconds=1800):
    """声明「接下来这段时间别把窗口收起来」。

    用户在登录窗口上操作期间，任何后台保活都不许动它 —— 否则他刚把窗口
    拉回来，下一次保活就把它收走了，看起来就是「窗口自己消失了」。
    """
    with _LOCK:
        _WIN["hold_until"] = time.time() + seconds


def holding():
    with _LOCK:
        return time.time() < _WIN["hold_until"]


def window_state():
    """当前窗口状态。故意用 CDP 那套词（normal / minimized）：
    上层「窗口跑到 normal 了就再藏一次」的判断一个字都不用改。"""
    with _LOCK:
        return "normal" if _WIN["shown"] else "minimized"


def call(op, timeout=60.0, **args):
    """请引擎做一件事，等它做完。返回 {"ok":bool, "value":…, "error":…}。"""
    if not attached():
        return {"ok": False, "offline": True, "error": NOT_ONLINE}

    cid = uuid.uuid4().hex[:12]
    ev = threading.Event()
    with _LOCK:
        _WAIT[cid] = ev
        _QUEUE.append({"id": cid, "op": op, "args": args})

    if not ev.wait(timeout):
        with _LOCK:
            _WAIT.pop(cid, None)
            # 从队列里摘掉，免得 Swift 稍后才执行、把一个没人接的结果塞回来
            for i, c in enumerate(_QUEUE):
                if c["id"] == cid:
                    del _QUEUE[i]
                    break
        return {"ok": False, "timeout": True,
                "error": "内置引擎响应超时（%s，%.0f 秒）" % (op, timeout)}

    with _LOCK:
        return _RESULT.pop(cid, {"ok": False, "error": "结果丢了"})


# ---------------------------------------------------------------------------
# 二、给业务代码用的糖
# ---------------------------------------------------------------------------

def ping(timeout=6.0):
    return call("ping", timeout=timeout)


def ready():
    """引擎在不在、能不能干活。结果缓存 0.5 秒，别在热路径上反复问。"""
    now = time.time()
    with _LOCK:
        if now - _READY_CACHE["at"] < 0.5:
            return _READY_CACHE["ok"]
    if not attached():
        ok = False
    else:
        r = ping()
        ok = bool(r.get("ok"))
    with _LOCK:
        _READY_CACHE.update({"at": time.time(), "ok": ok})
    return ok


_READY_CACHE = {"at": 0.0, "ok": False}


def open_url(url, timeout=60.0, new=False, tab=None):
    a = {"url": url}
    if new:
        a["new"] = True
    if tab:
        a["id"] = tab
    r = call("open", timeout=timeout, **a)
    if not r.get("ok"):
        return None
    v = r.get("value") or {}
    return v.get("id")


def eval_js(js, timeout=90.0, tab=None):
    """执行 JS，返回引擎给的原值（我们页面里的脚本基本都 JSON.stringify 过了）。"""
    a = {"js": js}
    if tab:
        a["id"] = tab
    r = call("eval", timeout=timeout, **a)
    if not r.get("ok"):
        return None
    return r.get("value")


def eval_text(js, timeout=90.0, tab=None):
    """和 eval_js 一样，但保证返回字符串（拿不到就是空串）。"""
    v = eval_js(js, timeout=timeout, tab=tab)
    if v is None:
        return ""
    if isinstance(v, str):
        return v
    try:
        return json.dumps(v, ensure_ascii=False)
    except Exception:
        return str(v)


def eval_json(js, timeout=90.0, tab=None):
    """执行 JS 并把结果当 JSON 解出来（字符串会再解一层）。"""
    v = eval_js(js, timeout=timeout, tab=tab)
    if isinstance(v, str):
        try:
            return json.loads(v)
        except Exception:
            return None
    return v


def tabs(timeout=20.0):
    r = call("tabs", timeout=timeout)
    if not r.get("ok"):
        return []
    return ((r.get("value") or {}).get("tabs")) or []


def close(all=False, tab=None, timeout=25.0):
    a = {}
    if all:
        a["all"] = True
    if tab:
        a["id"] = tab
    return call("close", timeout=timeout, **a).get("ok", False)


def reload(tab=None, timeout=25.0):
    a = {}
    if tab:
        a["id"] = tab
    return call("reload", timeout=timeout, **a).get("ok", False)


def cookies_get(domain="", timeout=25.0):
    r = call("cookies_get", timeout=timeout, domain=domain)
    if not r.get("ok"):
        return []
    return ((r.get("value") or {}).get("cookies")) or []


def cookies_set(cookies, timeout=40.0):
    """cookies 是 [{"name","value","domain","path","secure","httpOnly","expires"}]

    整批一次写进去。原来 bridge 是一条 cookie 起一个进程地灌，
    十几条就要十几秒；现在一次调用搞定。
    """
    r = call("cookies_set", timeout=timeout, cookies=list(cookies))
    if not r.get("ok"):
        return 0
    return int(((r.get("value") or {}).get("set")) or 0)


def geometry(x=None, y=None, w=None, h=None, title=None, tab=None, timeout=25.0):
    a = {}
    for k, v in (("x", x), ("y", y), ("w", w), ("h", h)):
        if v is not None:
            a[k] = v
    if title:
        a["title"] = title
    if tab:
        a["id"] = tab
    return call("geometry", timeout=timeout, **a).get("ok", False)


def show(tab=None, title=None, timeout=25.0):
    a = {}
    if tab:
        a["id"] = tab
    if title:
        a["title"] = title
    ok = bool(call("show", timeout=timeout, **a).get("ok"))
    if ok:
        mark_shown(True)        # 顺手记账，见上面「窗口状态」那一段
    return ok


def hide(timeout=25.0):
    ok = bool(call("hide", timeout=timeout).get("ok"))
    if ok:
        mark_shown(False)
    return ok


def set_download_dir(path, timeout=20.0):
    return call("download_dir", timeout=timeout, path=path).get("ok", False)


def click(x, y, tab=None, timeout=25.0):
    a = {"x": float(x), "y": float(y)}
    if tab:
        a["id"] = tab
    return call("click", timeout=timeout, **a).get("ok", False)


def clear_data(timeout=60.0):
    """把 WebKit 里存的一切清掉（退出登录、切换账号时用）。"""
    return call("clear_data", timeout=timeout).get("ok", False)


def wait_ready(timeout=25.0, tab=None):
    """等页面自己的 document.readyState 到 complete。

    比「睡死 2.5 秒」靠谱：快的时候几百毫秒就回来了，
    慢的时候也不会在页面还没加载完时就往下走。
    """
    end = time.time() + timeout
    last = ""
    while time.time() < end:
        last = eval_text("document.readyState", timeout=max(5.0, end - time.time()),
                         tab=tab) or ""
        if last in ("complete", "interactive"):
            return True
        time.sleep(0.25)
    return False


def state(timeout=20.0):
    r = call("state", timeout=timeout)
    return (r.get("value") or {}) if r.get("ok") else {}


# ---------------------------------------------------------------------------
# 三、命令行：agent-browser 兼容层
# ---------------------------------------------------------------------------

# ★ 本模块是不是跑在 bridge.py 那个进程里 ★
#   bridge.py 导入本模块后会把这一项设成 True。
#
#   为什么需要它：bridge.py 的 _ab_raw 原本**无论引擎在不在线**都 fork 一个
#   `webengine.py` 子进程。引擎在线时这条路的代价大得完全没必要：
#
#       看板 → bridge 主进程 → fork 子进程 → 子进程 POST /api/webengine/call
#            → 回到 bridge 的 HTTP 线程 → 进内存队列 → Swift 领走
#
#   四跳、两个进程 —— 而那个队列本来就在 bridge 主进程的内存里。
#
#   实测代价（在作者机器上抓线程栈时看得很清楚）：后台 status_loop 每探一次
#   状态就 fork 一次；子进程挂在 HTTP 上等引擎、父进程挂在 subprocess.run 上
#   等子进程，双方各自几十秒不放。几条这样的线程一起来，整条链路就被拖住了，
#   用户看到的是「点什么都没反应」。改成本进程内执行之后，这一跳整个消失。
INPROC = False

# 本进程内执行时的串行锁。理由：main() 会把输出写到 sys.stdout，
# 多个线程同时 redirect 会互相串台。而且引擎那边本来就只有一个窗口、
# 一条指令队列 —— 串行才是它真实的能力，假装并发只会让报错更难懂。
_CLI_LOCK = threading.RLock()

# 本进程内执行时喂给 `eval --stdin` 的内容
_STDIN = [None]


def _stdin_text():
    if _STDIN[0] is not None:
        return _STDIN[0]
    try:
        return sys.stdin.read()
    except Exception:
        return ""


def _strip_globals(args):
    """剥掉 agent-browser 的全局开关（--session-name X / --profile Y …）。

    ★ 必须在「判子命令」之前剥 ★ 调用方（bridge.py 的 _ab_target）拼出来的
    命令行永远是 `[webengine.py, --session-name, mbboard, open, …]`，
    子命令不在 args[0]。main() 与 run_cli() 共用这一份，避免两处走偏。
    """
    out = []
    i = 0
    while i < len(args):
        if args[i] in ("--session-name", "--session", "-s", "--profile") and i + 1 < len(args):
            i += 2
            continue
        out.append(args[i])
        i += 1
    return out


def run_cli(argv, stdin_data=None, timeout=None):
    """在**本进程里**跑一次 agent-browser 兼容命令。返回 (rc, 输出文本)。

    不认识的子命令返回 None —— 调用方据此回退到 fork 那条老路。
    这一点是有意留的：将来 agent-browser 多了什么命令，也不会因为我们
    这边不认识就把整条链路弄坏。
    """
    args = _strip_globals(list(argv))
    if not args or args[0] not in ("open", "eval", "wait", "tabs", "reload",
                                   "close", "cookies"):
        return None
    import contextlib
    import io
    with _CLI_LOCK:
        _STDIN[0] = stdin_data
        buf = io.StringIO()
        rc = 0
        try:
            with contextlib.redirect_stdout(buf), contextlib.redirect_stderr(buf):
                rc = main(args) or 0
        except SystemExit as e:
            rc = e.code if isinstance(e.code, int) else 1
        except Exception as e:                              # noqa
            buf.write("%s: %s\n" % (type(e).__name__, e))
            rc = 1
        finally:
            _STDIN[0] = None
    return rc, buf.getvalue().strip()


def _fail(msg, code=1):
    sys.stderr.write(str(msg) + "\n")
    sys.stdout.write(str(msg) + "\n")
    sys.exit(code)


def _emit(value):
    """agent-browser 打印的是「被 JSON 编码的字符串」，调用方要二次解析。
    这里照做：字符串会被再包一层引号，和它的行为一致。"""
    try:
        sys.stdout.write(json.dumps(value, ensure_ascii=False) + "\n")
    except Exception:
        sys.stdout.write(json.dumps(str(value), ensure_ascii=False) + "\n")


def _http_call(op, args, timeout):
    """把一条指令交给引擎。返回 {"ok","value","error"}。

    两种形态：
      · **本进程内**（INPROC=True）—— 队列就在自己内存里，直接 call()；
      · **子进程**（被 bridge.py 的 _ab_raw fork 起来）—— 走 HTTP 回到
        bridge，由它转给 App 里的引擎。

    ★ 走 netlocal 而不是裸 urlopen ★ 装过 VPN / 代理客户端的机器上，
    `HTTP_PROXY` 会被设成某个本地端口，裸 urlopen 会把
    `http://127.0.0.1:8765` 也丢给代理 —— 代理不认识本机地址，
    于是每一次浏览器操作都失败，而报错说的是「连不上本机服务」，
    把用户引去怀疑网络。详见 board/shared/netlocal.py。
    """
    if INPROC:
        # 同进程：不 fork、不走 HTTP，直接用内存队列。
        return call(op, timeout=float(timeout), **args)
    body = json.dumps({"op": op, "args": args}, ensure_ascii=False).encode("utf-8")
    try:
        if _netlocal is not None:
            return _netlocal.post_json(BASE + "/api/webengine/call",
                                       {"op": op, "args": args}, timeout=timeout + 10)
        # 兜底：netlocal 缺失时也绝不走代理
        op_ = urllib.request.build_opener(urllib.request.ProxyHandler({}))
        req = urllib.request.Request(
            BASE + "/api/webengine/call", data=body,
            headers={"Content-Type": "application/json"})
        with op_.open(req, timeout=timeout + 10) as r:
            return json.loads(r.read().decode("utf-8", "replace"))
    except urllib.error.HTTPError as e:
        try:
            return json.loads(e.read().decode("utf-8", "replace"))
        except Exception:
            return {"ok": False, "error": "本机服务返回 HTTP %s" % e.code}
    except Exception as e:
        return {"ok": False, "error": "连不上本机服务：%s" % e}


def main(argv):
    # 全局开关（agent-browser 的调用约定）：--session-name X / --profile Y
    args = _strip_globals(list(argv))

    if not args:
        _fail("用法：webengine.py [--session-name X] open|eval|wait|cookies|close …")

    cmd = args[0]
    rest = args[1:]

    if cmd == "open":
        if not rest:
            _fail("open 需要给一个网址")
        r = _http_call("open", {"url": rest[0]}, 60)
        if not r.get("ok"):
            _fail(r.get("error") or "打开页面失败")
        _emit(r.get("value") or {})
        return 0

    if cmd == "eval":
        if rest[:1] == ["--stdin"] or not rest:
            js = _stdin_text()
        else:
            js = " ".join(rest)
        r = _http_call("eval", {"js": js}, 90)
        if not r.get("ok"):
            _fail(r.get("error") or "执行脚本失败")
        _emit(r.get("value"))
        return 0

    if cmd == "wait":
        ms = 0
        if rest:
            try:
                ms = int(float(rest[0]))
            except Exception:
                ms = 0
        time.sleep(max(0, ms) / 1000.0)
        _emit(True)
        return 0

    if cmd == "tabs":
        r = _http_call("tabs", {}, 20)
        _emit(((r.get("value") or {}).get("tabs")) if r.get("ok") else [])
        return 0

    if cmd == "reload":
        r = _http_call("reload", {}, 25)
        if not r.get("ok"):
            _fail(r.get("error") or "刷新失败")
        _emit(True)
        return 0

    if cmd == "close":
        r = _http_call("close", {"all": "--all" in rest}, 25)
        if not r.get("ok"):
            _fail(r.get("error") or "关闭失败")
        _emit(True)
        return 0

    if cmd == "cookies":
        if not rest:
            _fail("cookies 需要 get 或 set")
        sub = rest[0]
        if sub == "get":
            r = _http_call("cookies_get", {}, 25)
            if not r.get("ok"):
                _fail(r.get("error") or "读 cookie 失败")
            _emit(((r.get("value") or {}).get("cookies")) or [])
            return 0
        if sub == "set":
            a = rest[1:]
            if len(a) < 2:
                _fail("cookies set 需要 name 和 value")
            c = {"name": a[0], "value": a[1], "domain": "", "path": "/"}
            j = 2
            while j < len(a):
                k = a[j]
                if k == "--domain" and j + 1 < len(a):
                    c["domain"] = a[j + 1]; j += 2; continue
                if k == "--path" and j + 1 < len(a):
                    c["path"] = a[j + 1]; j += 2; continue
                if k == "--expires" and j + 1 < len(a):
                    try:
                        c["expires"] = float(a[j + 1])
                    except Exception:
                        pass
                    j += 2; continue
                if k == "--sameSite" and j + 1 < len(a):
                    j += 2; continue
                if k == "--httpOnly":
                    c["httpOnly"] = True; j += 1; continue
                if k == "--secure":
                    c["secure"] = True; j += 1; continue
                j += 1
            if not c["domain"]:
                _fail("cookies set 需要 --domain")
            r = _http_call("cookies_set", {"cookies": [c]}, 40)
            if not r.get("ok"):
                _fail(r.get("error") or "写 cookie 失败")
            _emit(True)
            return 0
        _fail("不认识的 cookies 子命令：%s" % sub)

    _fail("不认识的命令：%s" % cmd)
    return 1


if __name__ == "__main__":
    try:
        sys.exit(main(sys.argv[1:]))
    except SystemExit:
        raise
    except Exception as e:  # noqa
        _fail("%s: %s" % (type(e).__name__, e))
