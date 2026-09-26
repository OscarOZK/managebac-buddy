# -*- coding: utf-8 -*-
"""ecroster —— English Corner（EC）今天该不该去。

EC 是学校英语组每天发的名单：一份 PDF（EC Roster M.D.pdf）发在 Teams 的
「ENGLISH CORNER ROSTER」频道里，正文没有内容，名单全在附件表格里，
按班分列（Rutherford / Simon / Planck / Bach / Dickens / Watt）。

所以这里做四件事：
  1. 找到该频道里最新那份 EC Roster；
  2. 下载到本机（同一个文件只下一次，之后直接复用）；
  3. 用 ecparse.py 还原成「班 → 学生」；
  4. 判断目标学生今天是不是要去，以及几点之前有效（当天 14:00）。

数据源仍是复用浏览器登录态拿到的 Graph 令牌（见 mssession），
不需要注册应用、不需要管理员批准。
"""
import json
import os
import re
import shutil
import subprocess
import sys
import threading
import time
import urllib.request

HERE = os.path.dirname(os.path.abspath(__file__))
if HERE not in sys.path:
    sys.path.insert(0, HERE)

import mssession as ms  # noqa: E402

HOME = os.path.expanduser("~")
# 数据目录：App 分发版会把 MBBOARD_DATA 指到 ~/Library/Application Support 下，
# 开发机不设它、继续用 ~/.mbboard —— 两种场景共用同一份代码。
MBB = os.environ.get("MBBOARD_DATA") or os.path.join(HOME, ".mbboard")
CACHE_DIR = os.path.join(MBB, "ec")

TEAM_NAME = "Beijing 101 High School"
CHANNEL_NAME = "ENGLISH CORNER ROSTER"

# 名单文件名：EC Roster 9.21.pdf / EC Roster 9.21 1.pdf
ROSTER_RE = re.compile(r"EC\s*Roster\s*(\d{1,2})[.\-/](\d{1,2})", re.I)
# 名字后面的次数标记
MARK_RE = re.compile(r"\s*[\(\[]\s*(?:L|R|-?\d+)\s*[\)\]]\s*")

# 目标学生：**不写死任何具体的人**。真实英语名一律从设置里取，
# 取不到就返回空串 —— 空串会让「我在不在名单里」显示成「未设置身份」，
# 而不是拿着别人的名字去比对。环境变量 MB_EC_STUDENT 或 ec.json 可覆盖。
DEFAULT_STUDENT = ""
# 当天 EC 的失效时刻（小时）——名单只挂到当天 14:00
DEADLINE_HOUR = 14
EC_WINDOW = "13:00–13:40"
EC_PLACE = "Room E113"

# 进程内缓存
_STATE = {"folder": None, "folder_ts": 0.0, "files": None, "files_ts": 0.0,
          "parsed": {}, "last": None, "last_err": ""}
FOLDER_TTL = 1800.0     # 文件夹位置基本不变
FILES_TTL = 120.0       # 文件列表：两分钟，够新又不至于把 Graph 打爆
BASE_TTL = 300.0        # 名单本身（下载 + 解析）五分钟内不重做
KEEP_FILES = 8          # 本地只留最近几份名单


# --------------------------------------------------------------------------
# 小工具
# --------------------------------------------------------------------------

def _norm(name):
    """把 'Alex Doe (2)' / 'Jamie Roe (L)' 归一成 'alex doe'。"""
    if not name:
        return ""
    s = MARK_RE.sub(" ", name)
    s = re.sub(r"\s*\(\s*[-]?\d+\s*\)", " ", s)
    s = s.replace("’", "'").replace("\u00a0", " ")
    return re.sub(r"\s+", " ", s).strip().lower()


def target_student():
    """目标学生是谁 —— 决定 EC 名单里「我在不在」的是这一行。

    优先级（名字绝不写死在代码里，一律取自用户自己的设置）：
      1. 环境变量 MB_EC_STUDENT（调试用）
      2. <数据目录>/settings.json 里的 englishName —— App 设置页「我的身份」填的
      3. <数据目录>/ec.json 里的 student —— 老配置，兼容
      4. DEFAULT_STUDENT（空串：宁可不判，也不拿别人的名字去比对）
    """
    override = os.environ.get("MB_EC_STUDENT")
    if override:
        return override
    try:
        with open(os.path.join(MBB, "settings.json"), encoding="utf-8") as f:
            v = (json.load(f) or {}).get("englishName") or ""
            v = str(v).strip()
            if v:
                return v
    except Exception:
        pass
    cfg = os.path.join(MBB, "ec.json")
    try:
        with open(cfg, encoding="utf-8") as f:
            v = (json.load(f) or {}).get("student")
            if v:
                return str(v)
    except Exception:
        pass
    return DEFAULT_STUDENT


def parse_name(name):
    """'EC Roster 9.21.pdf' → (9, 21)。"""
    m = ROSTER_RE.search(name or "")
    if not m:
        return None
    try:
        return int(m.group(1)), int(m.group(2))
    except Exception:
        return None


def _has_pymupdf(py):
    """这个解释器能不能 `import pymupdf`。"""
    try:
        r = subprocess.run([py, "-c", "import pymupdf"],
                           capture_output=True, timeout=25)
        return r.returncode == 0
    except Exception:
        return False


_PY = {"probed": False, "path": None}


def _venv_python():
    """返回**真的能 `import pymupdf`** 的解释器；一个都没有就返回 None。

    ★ 这里曾经只看「文件是否存在」就返回，踩了个大坑：
      ~/.mbboard/venv 不存在、/opt/homebrew 和 /usr/local 都没有 python3，
      于是永远选中 /usr/bin/python3（3.9，没有 PyMuPDF），
      EC 名单每次解析都抛 ModuleNotFoundError →
      前端把 ok=false 当成「这块不用显示」→ **整个 English Corner 板块凭空消失**。
      代码一行没删，看起来却像被谁删掉了。
    所以现在必须逐个真的试 import，而不是赌路径存在。结果缓存，避免每次
    解析都重启一遍解释器去探测（每次约 0.2 秒）。
    """
    if _PY["probed"]:
        return _PY["path"]
    _PY["probed"] = True

    cands = []
    env = os.environ.get("MB_EC_PYTHON")
    if env:
        cands.append(env)
    cands += [
        os.path.join(MBB, "venv/bin/python3"),          # 本模块自己装的托管 venv
        os.path.join(HOME, ".mbboard/venv/bin/python3"),  # 开发机自建 venv
        "/opt/homebrew/bin/python3",
        "/usr/local/bin/python3",
        sys.executable,
        "/usr/bin/python3",
    ]
    seen = set()
    for c in cands:
        if not c:
            continue
        try:
            real = os.path.realpath(c)
        except Exception:
            continue
        if real in seen or not os.path.exists(c):
            continue
        seen.add(real)
        if _has_pymupdf(c):
            _PY["path"] = c
            return c
    _PY["path"] = None
    return None


_INSTALL = {"tried": False, "ok": False, "err": "", "busy": False}


def _install_pdf_env():
    """本机没有任何解释器带 PyMuPDF 时，自己建一个托管 venv 并装上。

    只在后台线程里跑，**绝不阻塞界面请求**：装一次（约 5 秒，含下载），
    装好后下次刷新就能正常解析。装不上也不影响任何别的功能 ——
    已经解析过的名单照样能用（见 _adopt_side_cache）。
    """
    if _INSTALL["tried"]:
        return _INSTALL["ok"]
    _INSTALL["tried"] = True
    base = None
    for c in ["/opt/homebrew/bin/python3", "/usr/local/bin/python3",
              sys.executable, "/usr/bin/python3",
              os.path.join(MBB, "venv/bin/python3")]:
        if c and os.path.exists(c):
            base = c
            break
    if not base:
        _INSTALL["err"] = "找不到可用的 python3"
        return False
    vdir = os.path.join(MBB, "venv")
    py = os.path.join(vdir, "bin/python3")
    try:
        if not os.path.exists(py):
            r = subprocess.run([base, "-m", "venv", vdir],
                               capture_output=True, timeout=240)
            if r.returncode != 0 or not os.path.exists(py):
                _INSTALL["err"] = "创建 venv 失败：" + \
                    (r.stderr or b"").decode("utf-8", "replace")[-200:]
                return False
        r = subprocess.run([py, "-m", "pip", "install", "--quiet",
                            "--disable-pip-version-check", "pymupdf"],
                           capture_output=True, timeout=420)
        if r.returncode != 0:
            _INSTALL["err"] = (r.stderr or b"").decode("utf-8", "replace")[-300:]
            return False
        _INSTALL["ok"] = _has_pymupdf(py)
        if _INSTALL["ok"]:
            # 探测结果作废，让它重新走一遍候选列表（这次能选中新 venv）
            _PY["probed"] = False
            _PY["path"] = None
            # 顺手把「解析失败」的缓存也清掉：不然界面要等 TTL 到期
            # （最多 5 分钟）才会重试，用户会以为一直没好。
            _STATE.pop("base", None)
            _STATE["base_ts"] = 0.0
            # 把那几个因为缺组件而解析失败的条目剔掉，它们下次会真正重解析
            for p in _STATE.get("failed_paths", []):
                _STATE["parsed"].pop(p, None)
            _STATE["failed_paths"] = []
        return _INSTALL["ok"]
    except Exception as e:
        _INSTALL["err"] = "%s: %s" % (type(e).__name__, e)
        return False


def _kickoff_pdf_env_install():
    """在后台把解析组件装好 —— 请求线程不等它。"""
    if _INSTALL["tried"] or _INSTALL["busy"]:
        return
    _INSTALL["busy"] = True
    threading.Thread(target=_install_pdf_env, daemon=True).start()


# 换了数据目录之后，老目录里可能还留着已经解析好的名单结果。
# 这些结果没必要重算（一份 4MB 的 PDF 解析要几十秒），直接搬过来用。
LEGACY_EC_DIRS = [os.path.join(HOME, ".mbboard", "ec")]


def _adopt_side_cache(path):
    """同目录没有 .json 解析缓存时，去老数据目录里找一份同名副本搬过来。

    背景：App 分发版把数据目录从 ~/.mbboard 挪到了
    ~/Library/Application Support/ManageBac-Buddy/，
    于是历史解析结果全留在了老地方 —— 在新目录里看起来「名单读不出来了」。
    实际上数据一直都在，只是没跟着搬家。
    """
    side = path + ".json"
    try:
        if os.path.exists(side):
            return side
    except Exception:
        return None
    name = os.path.basename(path) + ".json"
    try:
        size = os.path.getsize(path)
    except OSError:
        return None
    for d in LEGACY_EC_DIRS:
        src = os.path.join(d, name)
        old_pdf = os.path.join(d, os.path.basename(path))
        try:
            if not os.path.exists(src) or os.path.abspath(src) == os.path.abspath(side):
                continue
            # 凭什么认定这份老解析结果对新位置的文件同样有效？
            #   · 老目录里还留着同一份 PDF（同名同字节数）→ 就是搬家时原样拷过来的，
            #     内容没变、只是 mtime 变新了，解析结果当然可以复用；
            #     （★ 一开始我拿 mtime 比大小，直接漏判：搬过来的 PDF mtime 更新，
            #      看起来像「文件改了」）
            #   · 并且那份 .json 不比它所对应的 PDF 旧。
            if os.path.exists(old_pdf):
                if os.path.getsize(old_pdf) != size:
                    continue        # 内容不一样，不能复用
                if os.path.getmtime(src) < os.path.getmtime(old_pdf):
                    continue        # 解析结果是旧版本的，不可信
            elif os.path.getmtime(src) < os.path.getmtime(path):
                continue
            os.makedirs(os.path.dirname(side), exist_ok=True)
            shutil.copyfile(src, side)
            # 让新副本看起来「和源 PDF 同时代」，下次命中 mtime 判断也顺
            try:
                os.utime(side, (os.path.getmtime(path), os.path.getmtime(path)))
            except Exception:
                pass
            return side
        except Exception:
            continue
    return None


def _download(url, dest, timeout=90):
    req = urllib.request.Request(url, headers={"User-Agent": "mbboard/1.0"})
    with urllib.request.urlopen(req, timeout=timeout) as r, open(dest, "wb") as f:
        while True:
            chunk = r.read(262144)
            if not chunk:
                break
            f.write(chunk)


# --------------------------------------------------------------------------
# Graph 侧：找到最新名单
# --------------------------------------------------------------------------

def _team_id():
    for t in ms.graph_paged("/me/joinedTeams", limit=20, timeout=15):
        if (t.get("displayName") or "").strip() == TEAM_NAME:
            return t.get("id")
    return None


def _channel_id(tid):
    for c in ms.graph_paged("/teams/%s/channels" % tid, limit=30, timeout=15):
        if (c.get("displayName") or "").strip().upper() == CHANNEL_NAME.upper():
            return c.get("id")
    return None


def _folder():
    """EC 频道的文件目录（driveId + itemId）。"""
    now = time.time()
    if _STATE["folder"] and now - _STATE["folder_ts"] < FOLDER_TTL:
        return _STATE["folder"]
    tid = _team_id()
    if not tid:
        raise RuntimeError("找不到团队：%s" % TEAM_NAME)
    cid = _channel_id(tid)
    if not cid:
        raise RuntimeError("找不到频道：%s" % CHANNEL_NAME)
    ff = ms.graph("/teams/%s/channels/%s/filesFolder" % (tid, cid))
    ref = ff.get("parentReference") or {}
    folder = {
        "drive": ref.get("driveId") or "",
        "item": ff.get("id") or "",
        "teamId": tid,
        "channelId": cid,
    }
    if not folder["drive"] or not folder["item"]:
        raise RuntimeError("拿不到频道文件目录")
    _STATE["folder"] = folder
    _STATE["folder_ts"] = now
    return folder


def list_rosters(force=False):
    """最近几份 EC 名单（按修改时间倒序）。"""
    now = time.time()
    if not force and _STATE["files"] and now - _STATE["files_ts"] < FILES_TTL:
        return _STATE["files"]
    f = _folder()
    q = ("/drives/%s/items/%s/children?$top=20"
         "&$orderby=lastModifiedDateTime desc"
         "&$select=id,name,size,lastModifiedDateTime,webUrl,file"
         % (f["drive"], f["item"]))
    r = ms.graph(q)
    out = []
    for it in (r.get("value") or []):
        nm = it.get("name") or ""
        if not ROSTER_RE.search(nm):
            continue
        d = parse_name(nm)
        if not d:
            continue
        out.append({
            "id": it.get("id"),
            "name": nm,
            "size": it.get("size") or 0,
            "modified": it.get("lastModifiedDateTime") or "",
            "webUrl": it.get("webUrl") or "",
            "month": d[0], "day": d[1],
        })
    _STATE["files"] = out
    _STATE["files_ts"] = now
    return out


def download(meta, force=False):
    """把名单 PDF 落到本机缓存，返回本地路径。同一个文件只下一次。"""
    os.makedirs(CACHE_DIR, exist_ok=True)
    safe = re.sub(r"[^\w.\- ]+", "_", meta["name"]).strip()
    path = os.path.join(CACHE_DIR, safe)
    size = int(meta.get("size") or 0)
    if not force and os.path.exists(path) and (not size or os.path.getsize(path) == size):
        return path
    f = _folder()
    raw = ms.graph("/drives/%s/items/%s?$select=@microsoft.graph.downloadUrl"
                   % (f["drive"], meta["id"]))
    url = raw.get("@microsoft.graph.downloadUrl")
    if not url:
        raise RuntimeError("没有下载地址")
    _download(url, path)
    _prune()
    return path


def _prune():
    """本地只留最近 KEEP_FILES 份，别让 4MB×N 堆着。"""
    try:
        files = [os.path.join(CACHE_DIR, x) for x in os.listdir(CACHE_DIR)]
        files = [f for f in files if ROSTER_RE.search(os.path.basename(f))]
        files.sort(key=lambda p: os.path.getmtime(p), reverse=True)
        for p in files[KEEP_FILES:]:
            try:
                os.remove(p)
                j = p + ".json"
                if os.path.exists(j):
                    os.remove(j)
            except Exception:
                pass
    except Exception:
        pass


# --------------------------------------------------------------------------
# 解析
# --------------------------------------------------------------------------

def parse(path):
    """解析名单 PDF（结果按文件 mtime 缓存），返回 {caption, report_date, groups}。

    两级缓存：进程内 dict + 同目录的 .json。后者是关键 —— 桥接服务重启、
    或者 ecroster 被当作 CLI 单独跑，都不必再起一次子进程解析，
    省掉每次约 1.5 秒。
    """
    try:
        stamp = os.path.getmtime(path)
    except OSError:
        return {}
    hit = _STATE["parsed"].get(path)
    if hit and hit.get("_mtime") == stamp:
        return hit

    side = path + ".json"
    if not os.path.exists(side):
        # 新数据目录里没有解析缓存 → 先去老目录搬一份（不重算）
        side = _adopt_side_cache(path) or side
    try:
        if os.path.exists(side) and os.path.getmtime(side) >= stamp:
            with open(side, encoding="utf-8") as f:
                data = json.load(f)
            data["_mtime"] = stamp
            _STATE["parsed"][path] = data
            return data
    except Exception:
        pass

    script = os.path.join(HERE, "ecparse.py")
    py = _venv_python()
    if not py:
        # 没有任何解释器带 PyMuPDF：说清原因（而不是抛一句看不懂的 traceback），
        # 并顺手在后台把组件装好 —— 用户不用做任何事，下次刷新就正常了。
        _STATE["last_err"] = "missing_pymupdf"
        fp = _STATE.setdefault("failed_paths", [])
        if path not in fp:
            fp.append(path)
        _kickoff_pdf_env_install()
        data = {"_mtime": stamp}
        _STATE["parsed"][path] = data
        return data
    try:
        r = subprocess.run([py, script, path], capture_output=True, timeout=120)
        out = (r.stdout or b"").decode("utf-8", "replace").strip()
        # 只取最后一行 JSON（前面可能有引擎的提示信息）
        line = out.splitlines()[-1] if out else ""
        data = json.loads(line) if line.startswith("{") else {}
        if not data and r.stderr:
            _STATE["last_err"] = (r.stderr or b"").decode("utf-8", "replace")[-300:]
    except Exception as e:
        _STATE["last_err"] = "%s: %s" % (type(e).__name__, e)
        data = {}
    data["_mtime"] = stamp
    _STATE["parsed"][path] = data
    if data.get("groups"):
        _STATE["last_err"] = ""      # 成功了就把上次的错误标记清掉，别留个假警报
        try:
            with open(path + ".json", "w", encoding="utf-8") as f:
                json.dump({k: v for k, v in data.items() if not k.startswith("_")},
                          f, ensure_ascii=False)
        except Exception:
            pass
    return data


def groups_of(parsed):
    """{班名: [学生]}，班名为空或重复的丢掉。"""
    out = {}
    for g in (parsed.get("groups") or []):
        k = (g.get("klass") or "").strip()
        if not k or k in out:
            continue
        out[k] = g.get("students") or []
    return out


def find_student(groups, who):
    """返回 (班名, 名单)。学生可能同名不同班，取第一个命中的。

    匹配由严到宽，三级：
      1. 全名归一后完全相同           Alex Chen  == Alex Chen
      2. 词集相同（忽略词序/中间名）   Chen Alex  == Alex Chen
      3. 姓相同 + 首字母相同          Alex C.    == Alex Chen
    真实姓名里常有中间名、姓名顺序不同，所以留这两级兜底。
    """
    want = _norm(who)
    if not want:
        return "", []
    wtoks = [t for t in want.split() if t]

    def toks(name):
        return [t for t in _norm(name).split() if t]

    soft = None
    for k, names in groups.items():
        for n in names:
            ntoks = toks(n)
            if _norm(n) == want:
                return k, names
            if soft is None and wtoks and set(ntoks) == set(wtoks):
                soft = (k, names)
    if soft:
        return soft
    if len(wtoks) >= 2:
        for k, names in groups.items():
            for n in names:
                ntoks = toks(n)
                if len(ntoks) >= 2 and ntoks[-1] == wtoks[-1] \
                        and ntoks[0][:1] == wtoks[0][:1]:
                    return k, names
    return "", []


# --------------------------------------------------------------------------
# 对外主入口
# --------------------------------------------------------------------------

def _base(now, force=False):
    """重活（查文件、下载、解析）的结果缓存 —— 和当前时刻无关的那部分。

    分开缓存的原因是：状态（今天/明天/已过）随时钟变，得每次重算；
    但下载 + 解析一份 4MB 名单要几十秒，绝不能每次刷新都做一遍。
    """
    cached = _STATE.get("base")
    if not force and cached and time.time() - _STATE.get("base_ts", 0) < BASE_TTL:
        return cached

    out = {"ok": True, "error": "", "hasRoster": False, "file": "", "webUrl": "",
           "localPath": "", "caption": "", "groups": {}, "month": 0, "day": 0,
           "modified": "", "student": target_student()}
    try:
        files = list_rosters(force=force)
    except Exception as e:
        out["ok"] = False
        out["error"] = "%s: %s" % (type(e).__name__, e)
        return out
    if not files:
        return out

    latest = files[0]
    out.update({"hasRoster": True, "file": latest["name"], "webUrl": latest["webUrl"],
                "month": latest["month"], "day": latest["day"],
                "modified": latest.get("modified") or ""})
    try:
        out["localPath"] = download(latest, force=False)
    except Exception as e:
        out["ok"] = False
        out["error"] = "下载名单失败：%s" % e
        return out

    parsed = parse(out["localPath"])
    if not parsed or not parsed.get("groups"):
        out["ok"] = False
        err = _STATE["last_err"]
        if err == "missing_pymupdf":
            out["error"] = ("名单解析组件正在自动准备（首次需要几秒），"
                            "稍等片刻点右上角的刷新即可")
        else:
            out["error"] = err or "名单解析失败"
        # ★ 失败结果也要缓存 ★
        # 以前这里直接 return、不写缓存，于是每次刷新都重新走一遍
        # 「查 Graph → 下载 4MB PDF → 起子进程解析」，本来就慢，失败时更慢，
        # 界面看着像卡死。TTL 内不再重试，用户点「重新读一次」(force) 才重跑。
        _STATE["base"] = out
        _STATE["base_ts"] = time.time()
        return out
    out["caption"] = parsed.get("caption") or ""
    out["groups"] = groups_of(parsed)

    _STATE["base"] = out
    _STATE["base_ts"] = time.time()
    return out


def today(now=None, force=False):
    """给界面的 EC 状态。

    status: today（今天的名单，还没到 14:00）/ done（今天的名单，已过 14:00）
            tomorrow / past / future / none / error
    active: 现在是否应该挂「去 English Corner」这条待办
    """
    from datetime import datetime, timedelta, timezone
    CST = timezone(timedelta(hours=8))
    now = now or datetime.now(CST)

    b = _base(now, force=force)
    out = {
        "ok": b.get("ok", True), "status": "none", "hasRoster": b.get("hasRoster", False),
        "isToday": False, "active": False, "imIn": False, "klass": "",
        "students": [], "otherGroups": {}, "caption": b.get("caption", ""),
        "file": b.get("file", ""), "webUrl": b.get("webUrl", ""),
        "localPath": b.get("localPath", ""), "place": EC_PLACE, "window": EC_WINDOW,
        "deadlineMs": None, "dateMs": None, "date": "", "student": b.get("student"),
        "error": b.get("error", ""),
    }
    if not out["hasRoster"]:
        if not out["ok"]:
            out["status"] = "error"
        return out
    if not out["ok"]:
        out["status"] = "error"
        return out

    klass, names = find_student(b["groups"], out["student"])
    out["imIn"] = bool(klass)
    out["klass"] = klass
    out["students"] = names
    out["otherGroups"] = {k: v for k, v in b["groups"].items() if k != klass}

    year = now.year
    try:
        year = datetime.fromisoformat((b.get("modified") or "").replace("Z", "+00:00")).year
    except Exception:
        pass
    try:
        d = datetime(year, b["month"], b["day"], DEADLINE_HOUR, 0, tzinfo=CST)
    except (ValueError, TypeError):
        out["status"] = "error"
        out["error"] = "名单日期不合法"
        return out

    out["deadlineMs"] = int(d.timestamp() * 1000)
    out["dateMs"] = int(d.replace(hour=0, minute=0).timestamp() * 1000)
    out["date"] = d.strftime("%Y-%m-%d")

    if d.date() == now.date():
        out["isToday"] = True
        out["status"] = "today" if now < d else "done"
    elif (d.date() - now.date()).days == 1:
        out["status"] = "tomorrow"
    elif d.date() < now.date():
        out["status"] = "past"
    else:
        out["status"] = "future"

    out["active"] = bool(out["imIn"] and out["status"] == "today")
    _STATE["last"] = out
    return out


def status_note(info):
    """一句人话，给菜单栏小板块用。"""
    who = info.get("student") or ""
    st = info.get("status")
    if st == "today":
        if info.get("imIn"):
            return "今天要去 EC（%s 班）" % info.get("klass")
        return "今天有 EC，但名单里没有 %s" % who
    if st == "done":
        return "今天 EC 已结束"
    if st == "tomorrow":
        if info.get("imIn"):
            return "明天要去 EC（%s 班）" % info.get("klass")
        return "明天有 EC，名单里没有 %s" % who
    if st == "past":
        return "最近一份名单已过期"
    if st == "error":
        # 有具体原因就把原因交出去（那句已经是给人看的中文），
        # 别统一糊成「暂时读不到」——「为什么读不到」才是用户要的。
        err = (info.get("error") or "").strip()
        if err and len(err) <= 120 and "Traceback" not in err:
            return err
        return "EC 名单暂时读不到"
    return "今天没有 EC"


def task_of(info):
    """把「今天要去 EC」变成一条待办；不需要就返回 None。"""
    if not info.get("active"):
        return None
    klass = info.get("klass") or ""
    title = "去 English Corner"
    if klass:
        title += "（%s 班）" % klass
    return {
        "id": "ec:" + (info.get("date") or ""),
        "source": "ec",
        "title": title,
        "course": "英语",
        "detail": "EC %s · %s" % (info.get("window") or EC_WINDOW, info.get("place") or EC_PLACE),
        "dueMs": info.get("deadlineMs"),
        "dueText": "%d:00 前" % DEADLINE_HOUR,
        "createdMs": None,
        "importance": "high",
        "status": "notStarted",
        "from": "Emerson Miller · English Corner Roster",
        "webUrl": info.get("webUrl") or "",
        "confidence": 1.0,
        "signals": ["English Corner 名单"],
        "pin": True,
        "preview": {
            "text": ("English Corner 今天有你的名字。\n时间：%s\n地点：%s\n名单：%s"
                     % (info.get("window") or EC_WINDOW,
                        info.get("place") or EC_PLACE,
                        info.get("file") or "")),
            "from": "English Corner Roster",
            "whenMs": info.get("dateMs"),
            "webUrl": info.get("webUrl") or "",
            "attachments": [{
                "name": info.get("file") or "EC Roster",
                "kind": "pdf",
                "url": info.get("localPath") or "",
                "webUrl": info.get("webUrl") or "",
                "size": 0,
                "local": True,
            }] if info.get("file") else [],
            "form": None,
        },
    }


if __name__ == "__main__":
    cmd = sys.argv[1] if len(sys.argv) > 1 else "info"
    if cmd == "info":
        info = today(force="--force" in sys.argv)
        print(json.dumps(info, ensure_ascii=False, indent=2)[:4000])
        print("\n→", status_note(info))
        t = task_of(info)
        print("→ 任务:", json.dumps(t, ensure_ascii=False)[:400] if t else "（今天没有）")
    elif cmd == "files":
        for f in list_rosters(force=True):
            print(" ", f["modified"], "|", f["name"], "|", f["size"])
