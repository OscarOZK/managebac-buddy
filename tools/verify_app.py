#!/usr/bin/env python3
"""分发版登录链路的出厂体检。

为什么要有这个：这个 App 是要发到别人电脑上的，而登录能不能成，取决于一堆
「本机环境」有没有恰好对上（有没有 Python、有没有浏览器、包内文件被不被隔离、
后端起没起来）。这些条件在开发机上几乎总是对的，在别人机器上却未必 ——
作者朋友的机器上一次挂了三条链路，就是这么来的。

所以这里按「别人机器上可能缺什么」逐个把场景造出来，跑一遍：
  A 包内 Python 能不能跑（分发版最要紧的资产）
  B 换台机器 / 换目录还能不能跑（重定位）
  C 后端能不能起来 + 四条链路的接口是不是活的
  D 冷启动会不会谎报「已登录」（曾经会，用户只见空课表）
  E 没有浏览器时，登录入口给的是不是人话
  F 签名状态（决定下载后能不能打开）

用法：
    python3 tools/verify_app.py [App路径]
默认路径 /Users/oscar/Desktop/ManageBac-Buddy/ManageBac-Buddy.app
"""
import json
import os
import shutil
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.request

APP = sys.argv[1] if len(sys.argv) > 1 else \
    "/Users/oscar/Desktop/ManageBac-Buddy/ManageBac-Buddy.app"
PY = APP + "/Contents/Resources/python/bin/python3"
BK = APP + "/Contents/Resources/backend/bridge.py"

PASS, FAIL, WARN = [], [], []


def ok(name, detail=""):
    PASS.append(name)
    print("  \033[32m✔\033[0m %-46s %s" % (name, detail))


def bad(name, detail=""):
    FAIL.append(name)
    print("  \033[31m✘\033[0m %-46s %s" % (name, detail))


def warn(name, detail=""):
    WARN.append(name)
    print("  \033[33m!\033[0m %-46s %s" % (name, detail))


def head(t):
    print()
    print("─" * 74)
    print(t)
    print("─" * 74)


opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))


def http(port, path, method="GET", body=None, timeout=25):
    req = urllib.request.Request("http://127.0.0.1:%d%s" % (port, path),
                                 method=method, data=body)
    try:
        with opener.open(req, timeout=timeout) as r:
            return r.status, r.read().decode("utf-8", "replace")
    except urllib.error.HTTPError as e:
        return e.code, e.read().decode("utf-8", "replace")
    except Exception as e:
        return None, "%s: %s" % (type(e).__name__, e)


def jhttp(*a, **kw):
    st, b = http(*a, **kw)
    try:
        return st, json.loads(b)
    except Exception:
        return st, {"__raw__": b[:200]}


def start_backend(port, data, chrome=None):
    shutil.rmtree(data, ignore_errors=True)
    os.makedirs(data, exist_ok=True)
    env = dict(os.environ)
    env.update({"MBBOARD_DATA": data, "MBBOARD_PORT": str(port),
                "PYTHONDONTWRITEBYTECODE": "1", "PYTHONIOENCODING": "utf-8",
                "no_proxy": "127.0.0.1,localhost", "NO_PROXY": "127.0.0.1,localhost"})
    # 沙箱里带着 HTTP_PROXY，直连本机端口必须先摘掉
    env.pop("HTTP_PROXY", None)
    env.pop("http_proxy", None)
    if chrome:
        env["MBBOARD_CHROME"] = chrome
    p = subprocess.Popen([PY, BK], env=env,
                         stdout=open(data + "/out.log", "w"), stderr=subprocess.STDOUT)
    for _ in range(80):
        st, _b = http(port, "/api/health", timeout=3)
        if st == 200:
            return p
        time.sleep(0.5)
    return p


def fake_chrome():
    """造一个假的 Chromium 可执行文件。

    browserfind 的候选清单第一位就是 MBBOARD_CHROME，指过去就不会去触发
    190MB 的兜底下载 —— 体检要快，也不该顺手占用户 190MB 磁盘。
    """
    d = tempfile.mkdtemp(prefix="vfy-chrome-")
    f = os.path.join(d, "chrome")
    open(f, "w").write("#!/bin/sh\nexit 0\n")
    os.chmod(f, 0o755)
    return f


# ─────────────────────────── A 包内 Python ───────────────────────────
head("A  包内 Python：分发版最要紧的资产（没有它，四条链路全挂）")
if not os.path.exists(APP):
    bad("App 存在", APP + " 不存在")
    sys.exit(1)
if not os.path.exists(PY):
    bad("包内 Python 存在", PY + " 不存在")
else:
    ok("包内 Python 存在", PY.replace(APP, "…"))
    r = subprocess.run([PY, "-c",
                        "import sys,json,ssl,sqlite3,http.server,urllib.request,"
                        "subprocess,threading,zipfile,hashlib,html.parser,"
                        "http.cookiejar,socket,select;print(sys.version.split()[0])"],
                       capture_output=True, text=True, timeout=30)
    if r.returncode == 0:
        ok("包内 Python 可执行且标准库齐全", "Python " + r.stdout.strip())
    else:
        bad("包内 Python 可执行", (r.stderr or "")[-160:])

# ─────────────────────────── B 重定位 ───────────────────────────
head("B  重定位：换台机器 / 换个目录还能不能跑")
tmp = tempfile.mkdtemp(prefix="vfy-reloc-")
dstapp = os.path.join(tmp, "ManageBac-Buddy.app")
subprocess.run(["cp", "-R", APP, dstapp], check=False)
py2 = dstapp + "/Contents/Resources/python/bin/python3"
if not os.path.exists(py2):
    bad("复制后的 App 仍带包内 Python")
else:
    r = subprocess.run([py2, "-c", "import sys,sqlite3,ssl;print(sys.prefix)"],
                       capture_output=True, text=True, timeout=30)
    if r.returncode == 0 and r.stdout.strip().startswith(tmp):
        ok("包内 Python 可重定位（sys.prefix 跟随位置）", r.stdout.strip().replace(tmp, "…"))
    elif r.returncode == 0:
        warn("包内 Python 可跑，但 sys.prefix 没跟着挪", r.stdout.strip())
    else:
        bad("重定位后的包内 Python 可跑", (r.stderr or "")[-160:])

# ─────────────────────────── C 后端 + 四条链路 ───────────────────────────
head("C  后端启动 + 四条链路接口")
fc = fake_chrome()
port = 18901
proc = start_backend(port, "/tmp/vfy_data_c", chrome=fc)
st, h = jhttp(port, "/api/health")
if st != 200:
    bad("后端起来并应答 /api/health", str(h)[:160])
else:
    ok("后端起来并应答 /api/health")
    comp = h.get("components") or {}
    pypath = (comp.get("python") or {}).get("path", "")
    if pypath == PY:
        ok("后端用的是包内 Python", pypath.replace(APP, "…"))
    else:
        bad("后端用的是包内 Python", "实际：" + str(pypath))
    if (comp.get("agentBrowser") or {}).get("ok"):
        ok("agent-browser 就绪")
    else:
        bad("agent-browser 就绪", str(comp.get("agentBrowser"))[:120])

    for path in ["/api/status", "/api/data", "/api/teams", "/api/seiue",
                 "/api/snapshot", "/api/ping", "/api/net"]:
        st, d = jhttp(port, path)
        if st == 200:
            ok("接口存活 " + path)
        else:
            bad("接口存活 " + path, "HTTP " + str(st) + " " + str(d)[:100])

# ─────────────────────────── D 冷启动不谎报 ───────────────────────────
head("D  冷启动：不能把「还没抓到」说成「已登录」")
st, d = jhttp(port, "/api/data")
st2, s = jhttp(port, "/api/status")
if d.get("loggedIn") is True and s.get("loggedIn") is False:
    bad("冷启动占位不谎报已登录",
        "/api/data 说 True 而 /api/status 说 False —— 前端会显示「已就绪 + 空课表」")
elif d.get("loggedIn") is True:
    bad("冷启动占位不谎报已登录", "/api/data 直接说 True")
else:
    ok("冷启动占位不谎报已登录",
       "data.loggedIn=%r  status.loggedIn=%r" % (d.get("loggedIn"), s.get("loggedIn")))
if d.get("updating") is True or d.get("preparing") is True:
    ok("冷启动带「正在准备」标志", "updating=%r preparing=%r" % (d.get("updating"), d.get("preparing")))
proc.kill()

# ─────────────────────────── E 无浏览器 ───────────────────────────
head("E  没装任何浏览器时：登录入口给的是不是人话")
port2 = 18902
proc2 = start_backend(port2, "/tmp/vfy_data_e", chrome=None)
for path in ["/api/teams/login", "/api/seiue/login"]:
    st, d = jhttp(port2, path, method="POST", body=b"{}", timeout=30)
    msg = d.get("msg") or d.get("error") or ""
    if d.get("preparing") is True and msg:
        ok("无浏览器时 " + path + " 给「正在准备」", msg[:70])
    elif "Chrome" in msg or "chrome" in msg or "No such file" in msg:
        bad("无浏览器时 " + path + " 的提示文案", "把底层英文报错透出来了：" + msg[:80])
    else:
        warn("无浏览器时 " + path + " 的提示文案", msg[:80] or str(d)[:80])
proc2.kill()
# 后台可能已经开始下载，清理干净
shutil.rmtree("/tmp/vfy_data_e/chrome", ignore_errors=True)

# ─────────────────────────── F 签名 ───────────────────────────
head("F  签名状态（决定朋友下载后能不能打开）")
r = subprocess.run(["codesign", "--verify", "--deep", "--verbose=2", APP],
                   capture_output=True, text=True)
if "valid on disk" in (r.stderr + r.stdout):
    ok("codesign 自校验通过")
else:
    bad("codesign 自校验", (r.stderr or r.stdout)[-160:])
r = subprocess.run(["spctl", "-a", "-t", "exec", APP], capture_output=True, text=True)
blob = (r.stderr + r.stdout)
if "accepted" in blob:
    ok("Gatekeeper 放行")
else:
    warn("Gatekeeper 未放行（ad-hoc 签名的必然结果）",
         "用户需要右键→打开，或跑 xattr -dr com.apple.quarantine <App>")

# ─────────────────────────── 汇总 ───────────────────────────
head("汇总")
print("  通过 %d   警告 %d   失败 %d" % (len(PASS), len(WARN), len(FAIL)))
for n in FAIL:
    print("    \033[31m✘\033[0m " + n)
for n in WARN:
    print("    \033[33m!\033[0m " + n)
shutil.rmtree(tmp, ignore_errors=True)
shutil.rmtree(fc[:fc.rfind("/")], ignore_errors=True)
sys.exit(1 if FAIL else 0)
