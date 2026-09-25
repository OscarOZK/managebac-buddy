#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
Teams 板块数据层（Mac / Windows 通用）

职责
  1. 从 Microsoft Graph 拉取与「学习 / 活动」相关的数据：
       · Microsoft To Do 任务   /me/todo/lists/{id}/tasks
       · Planner 任务           /me/planner/tasks
       · Outlook 邮件           /me/messages
       · Teams 聊天消息         /me/chats（需要 Chat.Read）
       · 日历事件               /me/calendarView
  2. 把邮件与消息里的「要做的事」自动抽成一条条 Task（全自动，无人工确认）
  3. 输出统一的 teams 板块 JSON，供 Mac / Windows 两端直接渲染

设计原则
  · 只读：绝不回写微软账号里的任何数据
  · 纯标准库：Windows 上开箱即跑
  · 抽取规则可解释：每条任务都带 signals，界面上能告诉用户「为什么它成了任务」
"""

import json
import os
import re
import sys
import time
from concurrent.futures import ThreadPoolExecutor
from datetime import datetime, timedelta, timezone

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import mssession as ms  # noqa: E402  浏览器会话层（取代旧的 msauth 设备码流程）

CST = timezone(timedelta(hours=8))

# 频道消息的进程内缓存：看板会频繁轮询，没必要每次都把 Graph 打一遍。
# 数值调小是有意的 —— 用户要「时效性要强」，两分半足够挡住轮询风暴，
# 又不会让新消息在界面上压太久。
_MSG_CACHE = {"ts": 0.0, "data": []}
MSG_TTL = 120

# English Corner 名单模块（懒加载：它自己会去下载并解析 PDF，
# 万一出问题也绝不能连累其他数据源）
_EC = {"m": None, "err": None, "data": None, "ts": 0.0}
EC_TTL = 120.0

# 上一次「拉成功」的各路结果。
# 网络抖一下（Graph 超时在学校网太常见了）不该让列表在界面上凭空消失：
# 这一路失败、又没拿到任何新东西时，就把上次的结果原样交出去，
# 由上层标成「快照」，用户看到的还是内容，而不是一片空白。
_LAST = {"tasks": [], "mail": [], "events": [], "ts": 0.0}


class NotAuthenticated(Exception):
    """拿不到 Graph 令牌 —— 表示「这次没抓成」，不是「账号里没有数据」。

    这两件事以前被混成同一个「空板块」返回，上层拿到就覆盖掉好数据，
    于是 Teams 板块会毫无征兆地变空白。现在单独抛出来，由上层决定怎么兜。
    """


def ec_module():
    if _EC["m"] is not None:
        return _EC["m"]
    try:
        import ecroster as _e
        _EC["m"] = _e
        _EC["err"] = None
    except Exception as e:
        _EC["err"] = "%s: %s" % (type(e).__name__, e)
        return None
    return _EC["m"]


def ec_info(force=False):
    """今天的 English Corner 状态（带进程内缓存）。"""
    if not force and _EC["data"] is not None and time.time() - _EC["ts"] < EC_TTL:
        return _EC["data"]
    m = ec_module()
    if m is None:
        return {"ok": False, "status": "error", "error": "EC 模块加载失败：" + str(_EC["err"]),
                "imIn": False, "students": [], "student": ""}
    try:
        d = m.today(force=force)
    except Exception as e:
        d = {"ok": False, "status": "error", "error": "%s: %s" % (type(e).__name__, e),
             "imIn": False, "students": [], "student": ""}
    d["note"] = m.status_note(d)
    _EC["data"] = d
    _EC["ts"] = time.time()
    return d



# ==========================================================================
# 一、邮件 / 消息 → 任务：识别规则
# ==========================================================================

# 每类信号权重不同。命中越多、越关键，越可能是「真任务」。
ACTION_PATTERNS = [
    (r"\bplease\b", 2.0), (r"\bkindly\b", 1.8), (r"\breminder\b", 1.6),
    (r"\baction required\b", 2.6), (r"\brequired\b", 1.4), (r"\byou (?:must|need to|should)\b", 2.2),
    (r"\bsubmit\b", 2.4), (r"\bcomplete\b", 2.0), (r"\bfinish\b", 1.8),
    (r"\breview\b", 1.6), (r"\bprepare\b", 1.8), (r"\bpracti[cs]e\b", 1.5),
    (r"\bread\b", 1.3), (r"\bsign\b", 1.8), (r"\breturn\b", 1.5),
    (r"\bconfirm\b", 1.8), (r"\bregister\b", 1.8), (r"\brespond\b", 1.7), (r"\breply\b", 1.6),
    (r"\bbring\b", 1.5), (r"\bhand in\b", 2.4), (r"\bhandin\b", 2.4), (r"\bupload\b", 2.0),
    (r"\bdownload\b", 1.4), (r"\bcheck\b", 1.2), (r"\bfill (?:in|out)\b", 2.2),
    (r"\bparticipate\b", 1.4), (r"\battend\b", 1.7), (r"\bjoin\b", 1.3),
    (r"\bpay\b", 1.6), (r"\bbook\b", 1.6), (r"\bchoose\b", 1.2), (r"\bselect\b", 1.2),
    # 中文
    (r"请", 2.0), (r"務必|务必", 2.2), (r"需要", 1.6), (r"记得", 1.8),
    (r"提交", 2.4), (r"上交|交上", 2.4), (r"完成", 2.0), (r"做完", 1.8),
    (r"准备|准備", 1.8), (r"预习|預習", 2.0), (r"复习|複習|温习", 2.0),
    (r"签字|簽字|签名|簽名", 2.0), (r"回复|回覆|答复|答覆", 1.9),
    (r"填写|填寫", 2.2), (r"上传|上傳", 2.2), (r"下载|下載", 1.4),
    (r"确认|確認", 1.8), (r"报名|報名", 2.0), (r"登记|登記", 1.8),
    (r"参加|參加", 1.7), (r"出席", 1.7), (r"核对|核對", 1.7),
    (r"阅读|閱讀", 1.4), (r"背诵|背誦", 1.9), (r"整理", 1.3),
    (r"携带|攜帶", 1.7), (r"带上", 1.6),
]

DEADLINE_PATTERNS = [
    (r"\bdue\b", 2.6), (r"\bdeadline\b", 2.8), (r"\bby\s+\w+day\b", 2.2),
    (r"\bno later than\b", 2.6), (r"\bat the latest\b", 2.4),
    (r"\bbefore\b", 1.8), (r"\buntil\b", 1.5), (r"\bend of\b", 1.6),
    (r"截止", 2.8), (r"截至", 2.4), (r"期限", 2.4), (r"最晚|最迟|最遲", 2.6),
    (r"之前", 2.0), (r"以前", 1.6), (r"前完成", 2.4), (r"前提交", 2.4),
    (r"当天|當天", 1.4), (r"今晚", 2.0), (r"今晚前", 2.6),
]

ACADEMIC_PATTERNS = [
    (r"\bhomework\b", 2.2), (r"\bassignment\b", 2.2), (r"\bworksheet\b", 2.0),
    (r"\bquiz\b", 2.0), (r"\btest\b", 1.7), (r"\bexam\b", 2.0), (r"\bmidterm\b", 2.2),
    (r"\bfinal\b", 1.6), (r"\bproject\b", 1.8), (r"\bessay\b", 1.8),
    (r"\breport\b", 1.5), (r"\blab\b", 1.6), (r"\bpresentation\b", 1.8),
    (r"\breading\b", 1.4), (r"\bportfolio\b", 1.6), (r"\brevision\b", 1.6),
    (r"\bcc[a-z]*\b", 0),  # 占位，避免误伤
    (r"作业|作業", 2.2), (r"练习|練習", 1.9), (r"习题|習題", 2.0),
    (r"测验|測驗", 2.0), (r"考试|考試", 2.0), (r"月考", 2.2), (r"期中", 2.2), (r"期末", 2.2),
    (r"小测|小測", 2.0), (r"单元测|單元測", 2.0), (r"实验报告|實驗報告", 2.0),
    (r"论文|論文", 1.8), (r"报告|報告", 1.6), (r"演示|展示|演讲|演講", 1.7),
    (r"背诵|背誦", 1.9), (r"默写|默寫", 2.0), (r"作文", 1.8),
    (r"预习|預習", 2.0), (r"复习|複習", 2.0), (r"错题|錯題", 1.8),
    (r"课程|課程", 1.2), (r"课堂|課堂", 1.2), (r"课本|課本", 1.3),
    (r"活动|活動", 1.6), (r"社团|社團", 1.6), (r"运动会|運動會", 1.6),
    (r"家长会|家長會", 1.8), (r"班会|班會", 1.6), (r"升旗", 1.6), (r"值日", 1.8),
    (r"讲座|講座", 1.6), (r"竞赛|競賽|比赛|比賽", 1.7), (r"支教", 1.4),
    (r"志愿者|志願者", 1.6), (r"募捐|捐赠|捐贈", 1.5),
]

# 明显是「通知」而非「待办」的，扣分
NOISE_PATTERNS = [
    (r"\bunsubscribe\b", -3.0), (r"\bnewsletter\b", -2.4),
    (r"\bno-?reply\b", -1.2), (r"\bdo not reply\b", -2.0),
    (r"\bout of office\b", -3.0), (r"\bauto-?repl(?:y|ied)\b", -3.0),
    (r"\breceipt\b", -1.6), (r"\bconfirmation of\b", -1.0),
    (r"自动回复|自動回覆", -3.0), (r"退订|退訂", -3.0), (r"无需回复|無需回覆", -1.4),
    (r"放假通知", -0.6),
]


def _score(text, patterns):
    """返回（总分，命中的信号名列表）"""
    total = 0.0
    hits = []
    for pat, w in patterns:
        if w == 0:
            continue
        if re.search(pat, text, re.I):
            total += w
            hits.append(pat)
    return total, hits


def _confidence(score, lo=0.45, hi=0.97, base=3.2, span=11.0):
    """
    把原始得分映射成 0–1 的可读置信度。
    base 是判定门槛：刚过线 ≈ lo，堆满信号 ≈ hi。
    """
    if score <= base:
        return round(lo, 2)
    v = lo + (score - base) / span * (hi - lo)
    return round(max(lo, min(hi, v)), 2)


def strip_html(s):
    if not s:
        return ""
    s = re.sub(r"(?is)<(script|style)[^>]*>.*?</\1>", " ", s)
    s = re.sub(r"(?is)<br\s*/?>", "\n", s)
    s = re.sub(r"(?is)</(p|div|tr|li|h[1-6])>", "\n", s)
    s = re.sub(r"<[^>]+>", " ", s)
    s = (s.replace("&nbsp;", " ").replace("&amp;", "&").replace("&lt;", "<")
          .replace("&gt;", ">").replace("&quot;", '"').replace("&#39;", "'"))
    s = re.sub(r"[ \t\u00a0]+", " ", s)
    s = re.sub(r"\n{3,}", "\n\n", s)
    return s.strip()


# ---------------------------- 日期解析 ------------------------------------

WEEKDAY_CN = {"一": 0, "二": 1, "三": 2, "四": 3, "五": 4, "六": 5, "日": 6, "天": 6}
WEEKDAY_EN = {"monday": 0, "tuesday": 1, "wednesday": 2, "thursday": 3,
              "friday": 4, "saturday": 5, "sunday": 6, "mon": 0, "tue": 1,
              "wed": 2, "thu": 3, "fri": 4, "sat": 5, "sun": 6}
MONTH_EN = {"jan": 1, "feb": 2, "mar": 3, "apr": 4, "may": 5, "jun": 6, "jul": 7,
            "aug": 8, "sep": 9, "sept": 9, "oct": 10, "nov": 11, "dec": 12}


def parse_due(text, now=None):
    """
    从文本里找截止时间，返回 (毫秒时间戳 或 None, 命中的原文片段 或 None)。
    只认「明确指向未来」的时间，避免把历史邮件里的旧日期误判成截止。
    """
    now = now or datetime.now(CST)
    if not text:
        return None, None
    t = " " + text + " "

    def mk(y, mo, d, hh=23, mm=59):
        try:
            return datetime(y, mo, d, hh, mm, tzinfo=CST)
        except ValueError:
            return None

    def future(dt):
        return dt if dt and dt.date() >= (now - timedelta(days=1)).date() else None

    # ① 中文绝对日期：9月25日 / 9月25号
    for m in re.finditer(r"(\d{1,2})\s*月\s*(\d{1,2})\s*[日号]", t):
        mo, d = int(m.group(1)), int(m.group(2))
        dt = mk(now.year, mo, d) or mk(now.year + 1, mo, d)
        if dt and dt.date() < (now - timedelta(days=180)).date():
            dt = mk(now.year + 1, mo, d)
        if future(dt):
            return int(dt.timestamp() * 1000), m.group(0)

    # ② 英文月名：Sep 25 / September 25
    for m in re.finditer(r"\b([A-Za-z]{3,9})\.?\s+(\d{1,2})(?:st|nd|rd|th)?\b", t):
        mo = MONTH_EN.get(m.group(1).lower()[:4]) or MONTH_EN.get(m.group(1).lower()[:3])
        if not mo:
            continue
        d = int(m.group(2))
        dt = mk(now.year, mo, d) or mk(now.year + 1, mo, d)
        if future(dt):
            return int(dt.timestamp() * 1000), m.group(0)

    # ③ 纯数字日期：2026-09-25 / 9/25 / 25/9
    for m in re.finditer(r"\b(\d{4})[-/.](\d{1,2})[-/.](\d{1,2})\b", t):
        dt = mk(int(m.group(1)), int(m.group(2)), int(m.group(3)))
        if future(dt):
            return int(dt.timestamp() * 1000), m.group(0)
    for m in re.finditer(r"\b(\d{1,2})/(\d{1,2})\b", t):
        a, b = int(m.group(1)), int(m.group(2))
        dt = mk(now.year, a, b) or mk(now.year + 1, a, b)
        if future(dt):
            return int(dt.timestamp() * 1000), m.group(0)

    # ④ 星期 —— 必须排在「下周」之前，否则「下周一」会被当成「下周」的周五
    m = re.search(r"(下{0,1})(?:周|週|星期|礼拜|禮拜)([一二三四五六日天])", t)
    if m:
        nxt = bool(m.group(1))
        wd = WEEKDAY_CN[m.group(2)]
        days = (wd - now.weekday()) % 7
        if nxt:
            days += 7 if days else 7
        elif days == 0:
            days = 7
        dt = (now + timedelta(days=days)).replace(hour=23, minute=59)
        return int(dt.timestamp() * 1000), m.group(0)

    m = re.search(r"\b(?:next\s+)?(monday|tuesday|wednesday|thursday|friday|saturday|sunday|"
                  r"mon|tue|wed|thu|fri|sat|sun)\b", t, re.I)
    if m:
        nxt = "next" in m.group(0).lower()
        days = (WEEKDAY_EN[m.group(1).lower()] - now.weekday()) % 7
        if nxt and days == 0:
            days = 7
        elif days == 0:
            days = 7
        dt = (now + timedelta(days=days)).replace(hour=23, minute=59)
        return int(dt.timestamp() * 1000), m.group(0)

    # ⑤ 相对日（放在星期之后：先认「下周一」，剩下的「下周」才落到这里的周五）
    rel = [
        (r"大后天", 3), (r"后天|後天", 2),
        (r"\bday after tomorrow\b", 2), (r"明天|明日|\btomorrow\b", 1),
        (r"今天|今日|\btoday\b", 0),
    ]
    for pat, off in rel:
        m = re.search(pat, t, re.I)
        if m:
            dt = (now + timedelta(days=off)).replace(hour=23, minute=59)
            return int(dt.timestamp() * 1000), m.group(0)

    m = re.search(r"\bthis week\b|本周|这周|這周", t, re.I)
    if m:
        days = (4 - now.weekday()) % 7          # 本周五
        dt = (now + timedelta(days=days)).replace(hour=23, minute=59)
        if dt < now:
            dt += timedelta(days=7)
        return int(dt.timestamp() * 1000), m.group(0)

    m = re.search(r"\bnext week\b|下周|下週", t, re.I)
    if m:
        days = (4 - now.weekday()) % 7 + 7      # 下周五
        dt = (now + timedelta(days=days)).replace(hour=23, minute=59)
        return int(dt.timestamp() * 1000), m.group(0)

    return None, None


# ---------------------------- 标题提炼 ------------------------------------

_LEAD_NOISE = re.compile(
    r"^\s*(?:re|fwd|fw|回复|回覆|答复|转发|轉發|RE|FW)\s*[:：]\s*", re.I)
_MULTI_PREFIX = re.compile(
    r"^((?:(?:re|fwd|fw|回复|回覆|答复|转发|轉發)\s*[:：]\s*)+)", re.I)


def clean_subject(sub):
    s = (sub or "").strip()
    prev = None
    while prev != s:
        prev = s
        s = _LEAD_NOISE.sub("", s).strip()
    return s or "(无主题)"


def make_title(subject, body):
    """优先用主题；主题没信息量时，从正文第一句里挑。"""
    s = clean_subject(subject)
    if len(s) >= 4 and not re.fullmatch(r"[\W_]+", s):
        return s[:70]
    body = strip_html(body)
    for line in body.split("\n"):
        line = line.strip()
        if 6 <= len(line) <= 70 and not re.match(r"^(hi|hello|dear|各位|大家好|尊敬)", line, re.I):
            return line[:70]
    return s[:70]


def guess_course(text):
    """从文本里猜学科，用于看板上归类。"""
    table = [
        ("数学", r"数学|數學|math|algebra|geometry|calculus|三角函数|几何|代数|微积分"),
        ("物理", r"物理|physics|\bphys\b"),
        ("化学", r"化学|化學|chem"),
        ("生物", r"生物|biology|\bbio\b"),
        ("语文", r"语文|語文|chinese|作文|文言文|阅读感悟"),
        ("英语", r"英语|英語|english|\beng\b|雅思|托福|词汇"),
        ("历史", r"历史|歷史|history"),
        ("地理", r"地理|geography|geo\b"),
        ("政治", r"政治|道法|思想品德|civics"),
        ("计算机", r"信息|計算機|计算机|computer|\bcs\b|编程|程式|python"),
        ("体育", r"体育|體育|\bpe\b|运动|跑步|篮球|足球"),
        ("音乐", r"音乐|音樂|music|合唱"),
        ("美术", r"美术|美術|art|绘画|书法"),
        ("心理", r"心理|psych"),
    ]
    for name, pat in table:
        if re.search(pat, text, re.I):
            return name
    return ""


# ---------------------------- 预览（点开一条任务看原文） --------------------

# 附件列表里只列小于这个体积的：再大的东西在预览面板里也给不出有用信息，
# 徒增展开时的等待。
ATT_MAX = 12 * 1024 * 1024

_EXT_KIND = {
    "pdf": "pdf", "png": "image", "jpg": "image", "jpeg": "image", "gif": "image",
    "webp": "image", "heic": "image",
    "doc": "doc", "docx": "doc", "rtf": "doc",
    "xls": "sheet", "xlsx": "sheet", "csv": "sheet",
    "ppt": "deck", "pptx": "deck",
    "zip": "archive", "rar": "archive", "7z": "archive",
    "one": "note", "mp4": "video", "mov": "video", "mp3": "audio", "m4a": "audio",
}


def _file_kind(name):
    ext = (name or "").rsplit(".", 1)[-1].lower() if "." in (name or "") else ""
    return _EXT_KIND.get(ext, "file")


def _looks_like_forms(content_type, content):
    ct = (content_type or "").lower()
    c = (content or "").lower()
    return ("forms" in ct) or ("forms.office." in c) or (ct == "application/vnd.microsoft.card.adaptive" and "form" in c)


def msg_attachments(msg):
    """从 Teams 消息的 attachments 里挑出「真文件」，供预览面板展示。

    Teams 的 attachments 里混着大量装饰性卡片（公告横幅、自适应卡片），
    它们没有可下载的地址，列出来只会让用户困惑，所以按「有没有 URL」筛掉。
    """
    out = []
    for a in (msg.get("attachments") or []):
        ct = (a.get("contentType") or "").lower()
        if _looks_like_forms(ct, a.get("content") or ""):
            continue                      # 表单单独走 msg_form()
        url = a.get("contentUrl") or ""
        name = (a.get("name") or "").strip()
        if not url:
            continue                      # 装饰性卡片：没有真实地址
        if ct.startswith("application/vnd.microsoft.teams.messaging"):
            continue
        if not name:
            name = url.split("?")[0].rstrip("/").rsplit("/", 1)[-1]
            try:
                from urllib.parse import unquote
                name = unquote(name)
            except Exception:
                pass
        out.append({
            "name": name or "附件",
            "url": url,
            "kind": _file_kind(name),
            "webUrl": url,
            "size": 0,
            "local": False,
        })
    return out


def msg_form(msg):
    """Teams 消息里内嵌的 Microsoft Forms 卡片 → 可点的表单入口。

    EC 那类「必须填的表」常以 Forms 卡片发在频道里，用户的要求是
    预览里必须能看到它，所以这里单独解析出标题和填写地址。
    """
    for a in (msg.get("attachments") or []):
        ct = (a.get("contentType") or "").lower()
        content = a.get("content") or ""
        if not _looks_like_forms(ct, content):
            continue
        title, url = "", ""
        try:
            j = json.loads(content)
            title = j.get("title") or ""
            inner = j.get("content") or {}
            if isinstance(inner, dict):
                title = title or inner.get("title") or ""
                acts = inner.get("actions") or j.get("potentialAction") or []
                if isinstance(acts, dict):
                    acts = [acts]
                for act in acts:
                    if isinstance(act, dict) and act.get("targets"):
                        t0 = act["targets"][0]
                        url = t0.get("uri") or t0.get("url") or url
        except Exception:
            pass
        if not url:
            m = re.search(r"https://forms\.office\.[a-z.]+/[^\s\"'\\)]+", content)
            if m:
                url = m.group(0)
        url = url or (a.get("contentUrl") or "")
        if not url:
            continue
        return {"title": title.strip() or "需要填写的表单", "url": url}
    # 兜底：正文 HTML 里直接贴了 Forms 链接（很常见，比如 EC 当天要填的那张表）
    body = ((msg.get("body") or {}).get("content") or "")
    if body:
        m = re.search(r"https://forms\.(?:office|cloud)\.[a-z.]+/[^\s\"'<>)\]]+",
                      body, re.I)
        if m:
            return {"title": "消息里附带的表单", "url": m.group(0)}
    return None


def make_preview(text="", sender="", when_ms=None, web_url="",
                 attachments=None, form=None, place=""):
    """统一的任务预览结构：正文 + 文件 + 表单 + 跳转。"""
    atts = [a for a in (attachments or []) if (a.get("size") or 0) <= ATT_MAX]
    return {
        "text": (text or "").strip()[:4000],
        "from": sender or "",
        "whenMs": when_ms,
        "webUrl": web_url or "",
        "place": place or "",
        "attachments": atts[:12],
        "form": form,
    }


# ---------------------------- 邮件 → 任务 --------------------------------

def mail_to_task(msg, now=None):
    """
    一封邮件 → 一条任务，或 None（判定为不值得提醒）。
    全自动，直接进列表（按用户选择）。
    """
    now = now or datetime.now(CST)
    subject = msg.get("subject") or ""
    body_preview = msg.get("bodyPreview") or ""
    body = ""
    if isinstance(msg.get("body"), dict):
        body = strip_html(msg["body"].get("content", ""))
    blob = " ".join([subject, subject, body_preview, body[:2500]])

    odd, o_hits = _score(blob, ACTION_PATTERNS)
    dld, d_hits = _score(blob, DEADLINE_PATTERNS)
    acd, a_hits = _score(blob, ACADEMIC_PATTERNS)
    nd, n_hits = _score(blob, NOISE_PATTERNS)

    score = 0.0
    signals = []
    if odd > 0:
        score += odd * 1.0
        signals.append("行动要求")
    if acd > 0:
        score += acd * 1.15
        signals.append("学习/活动")
    if dld > 0:
        score += dld * 1.0
        signals.append("截止时间")
    if nd < 0:
        score += nd
        signals.append("疑似通知")

    imp = (msg.get("importance") or "").lower()
    if imp == "high":
        score += 1.8
        signals.append("邮件标记重要")
    if msg.get("flag", {}).get("flagStatus") == "flagged":
        score += 1.5
        signals.append("已加旗标")
    if msg.get("isRead") is False:
        score += 0.4

    # 学术词 + 行动/截止 同时出现 ⇒ 强烈是任务
    if acd > 0 and (odd > 0 or dld > 0):
        score += 2.2
        signals.append("学务要求")

    if score < 3.2:
        return None

    due_ms, due_txt = parse_due(blob, now)

    sender = ""
    try:
        addr = msg["from"]["emailAddress"]
        sender = addr.get("name") or addr.get("address") or ""
    except Exception:
        pass

    received = msg.get("receivedDateTime")
    recv_ms = None
    if received:
        try:
            recv_ms = int(datetime.fromisoformat(received.replace("Z", "+00:00"))
                          .timestamp() * 1000)
        except Exception:
            pass

    title = make_title(subject, body or body_preview)
    course = guess_course(title + " " + blob[:600])

    return {
        "id": "mail:" + str(msg.get("id") or hash(title)),
        "source": "mail",
        "title": title,
        "course": course,
        "detail": (body_preview or "")[:220],
        "dueMs": due_ms,
        "dueText": due_txt or "",
        "createdMs": recv_ms,
        "importance": "high" if imp == "high" else "normal",
        "status": "completed" if msg.get("isRead") and False else "notStarted",
        "from": sender,
        "webUrl": msg.get("webLink") or "",
        "confidence": _confidence(score),
        "signals": signals,
        "isRead": bool(msg.get("isRead")),
        "preview": make_preview(
            text=body or body_preview,
            sender=sender,
            when_ms=recv_ms,
            web_url=msg.get("webLink") or "",
            attachments=mail_attachments(msg),
            form=None),
    }


def mail_attachments(msg):
    """邮件的附件清单（正文里的内嵌图不算）。

    附件本身没有直链，要下载得走 /me/messages/{id}/attachments/{aid}/$value，
    所以这里给出的是「本机桥接的下载地址」，前端点一下即可拿到文件。
    """
    out = []
    mid = msg.get("id") or ""
    for a in (msg.get("_atts") or []):
        if a.get("isInline"):
            continue
        aid = a.get("id") or ""
        name = a.get("name") or "附件"
        from urllib.parse import quote
        dl = ("http://127.0.0.1:8765/api/teams/att?mid=%s&aid=%s&name=%s"
              % (quote(str(mid)), quote(str(aid)), quote(name))) if mid and aid else ""
        out.append({
            "name": name,
            "url": dl,
            "kind": _file_kind(name),
            "webUrl": msg.get("webLink") or "",
            "size": a.get("size") or 0,
            "local": False,
        })
    return out


def _attach_mail_files(mails, limit=8):
    """给最近几封带附件的邮件补上附件清单（并发；失败静默，不影响主流程）。"""
    target = [m for m in mails if m.get("hasAttachments") and m.get("id")][:limit]
    if not target:
        return

    def one(m):
        try:
            r = ms.graph("/me/messages/%s/attachments"
                         "?$select=id,name,size,contentType,isInline" % m["id"], timeout=15)
            m["_atts"] = r.get("value") or []
        except Exception:
            m["_atts"] = []

    try:
        with ThreadPoolExecutor(max_workers=min(6, len(target))) as ex:
            list(ex.map(one, target))
    except Exception:
        pass



# ==========================================================================
# 二、Graph 取数
# ==========================================================================

def fetch_todo(limit=60):
    """Microsoft To Do —— Teams 里「Tasks」应用显示的个人任务来源。"""
    out = []
    lists = ms.graph_paged("/me/todo/lists?$top=50", limit=20)
    for lst in lists:
        lid = lst.get("id")
        if not lid:
            continue
        lname = lst.get("displayName") or "任务"
        tasks = ms.graph_paged(
            "/me/todo/lists/%s/tasks?$top=100" % lid, limit=limit)
        for t in tasks:
            if (t.get("status") or "") == "completed":
                continue
            due = (t.get("dueDateTime") or {}).get("dateTime")
            due_ms = None
            if due:
                try:
                    due_ms = int(datetime.fromisoformat(
                        due.split(".")[0]).replace(tzinfo=CST).timestamp() * 1000)
                except Exception:
                    pass
            out.append({
                "id": "todo:" + str(t.get("id")),
                "source": "todo",
                "title": (t.get("title") or "").strip() or "(无标题)",
                "course": guess_course(lname + " " + (t.get("title") or "")),
                "detail": strip_html((t.get("body") or {}).get("content", ""))[:220],
                "dueMs": due_ms,
                "dueText": "",
                "createdMs": None,
                "importance": "high" if (t.get("importance") or "") == "high" else "normal",
                "status": t.get("status") or "notStarted",
                "from": lname,
                "webUrl": "",
                "confidence": 1.0,
                "signals": ["微软任务"],
            })
    return out


def fetch_planner(limit=60):
    """Planner —— 班级/项目指派的任务。学生租户经常不放行，失败就静默跳过。"""
    out = []
    tasks = ms.graph_paged("/me/planner/tasks?$top=100", limit=limit)
    if not tasks:
        return out
    plans = {}
    for t in tasks:
        pid = t.get("planId")
        if pid and pid not in plans:
            p = ms.graph("/planner/plans/" + pid)
            plans[pid] = p.get("title") or ""
    for t in tasks:
        if t.get("percentComplete") == 100:
            continue
        due = t.get("dueDateTime")
        due_ms = None
        if due:
            try:
                due_ms = int(datetime.fromisoformat(due.replace("Z", "+00:00"))
                             .timestamp() * 1000)
            except Exception:
                pass
        pname = plans.get(t.get("planId")) or ""
        out.append({
            "id": "planner:" + str(t.get("id")),
            "source": "planner",
            "title": (t.get("title") or "").strip() or "(无标题)",
            "course": guess_course(pname + " " + (t.get("title") or "")),
            "detail": "",
            "dueMs": due_ms,
            "dueText": "",
            "createdMs": None,
            "importance": "high" if (t.get("priority") or 5) <= 3 else "normal",
            "status": "completed" if t.get("percentComplete") == 100 else "notStarted",
            "from": pname,
            "webUrl": "",
            "confidence": 1.0,
            "signals": ["Planner 任务"],
        })
    return out


def fetch_mail(top=60, days=21):
    """近几周的收件箱邮件。"""
    since = (datetime.now(timezone.utc) - timedelta(days=days)).strftime("%Y-%m-%dT%H:%M:%SZ")
    q = ("/me/mailFolders/inbox/messages?$top=%d"
         "&$select=id,subject,bodyPreview,body,from,receivedDateTime,isRead,"
         "importance,flag,webLink,hasAttachments"
         "&$filter=receivedDateTime ge %s&$orderby=receivedDateTime desc" % (top, since))
    return ms.graph_paged(q, limit=top)


def fetch_chats(limit=40):
    """1:1 / 群聊消息 —— 需要 Chat.Read。Teams 网页版不带这个权限，
    所以只有「用户自建应用」路线才用得上；不可用时调用方直接跳过。"""
    out = []
    chats = ms.graph_paged("/me/chats?$top=30&$expand=members", limit=30)
    for c in chats[:12]:
        cid = c.get("id")
        if not cid:
            continue
        msgs = ms.graph_paged(
            "/me/chats/%s/messages?$top=25" % cid, limit=25)
        for m in msgs:
            m["_where"] = (c.get("topic") or c.get("chatType") or "聊天")
            out.append(m)
            if len(out) >= limit:
                return out
    return out


def fetch_channel_messages(limit=80, per_channel=8, teams_max=6, channels_max=3,
                           budget=75, days=45, force=False):
    """Teams 频道消息 —— 网页版自带的 ChannelMessage.Read.All，一定能拿到。

    性能与新鲜度是这里的两个硬约束：
      · 频道/消息并发拉取，并有整体时间预算（budget 秒），超预算就用已拿到的部分；
      · 只保留最近 days 天内的消息，避免把去年的公告也算成「待办」；
      · 结果在进程内缓存 MSG_TTL 秒，避免看板频繁刷新时反复打 Graph。
    """
    now = time.time()
    if not force and _MSG_CACHE["data"] and now - _MSG_CACHE["ts"] < MSG_TTL:
        return _MSG_CACHE["data"]

    deadline = now + budget
    since = (datetime.now(timezone.utc) - timedelta(days=days)).strftime("%Y-%m-%dT%H:%M:%SZ")
    out = []

    def recent(m):
        c = m.get("createdDateTime") or ""
        return (not c) or c >= since

    try:
        teams = ms.graph_paged("/me/joinedTeams", limit=teams_max, timeout=15)[:teams_max]
    except Exception as e:
        print("[!] 团队列表失败：%s" % e, file=sys.stderr)
        return []

    # 第一层并发：每个团队的频道
    def chans_of(t):
        if time.time() > deadline:
            return t, []
        try:
            cs = ms.graph_paged("/teams/%s/channels" % t.get("id"),
                                limit=channels_max, timeout=15)
            return t, cs[:channels_max]
        except Exception:
            return t, []

    jobs = []
    try:
        with ThreadPoolExecutor(max_workers=4) as ex:
            for t, cs in ex.map(chans_of, teams):
                for c in cs:
                    if c.get("id"):
                        jobs.append((t, c))
    except Exception as e:
        print("[!] 频道列表并发失败：%s" % e, file=sys.stderr)

    # 第二层并发：每个频道的最近消息
    def msgs_of(job):
        t, c = job
        if time.time() > deadline:
            return []
        try:
            msgs = ms.graph_paged(
                "/teams/%s/channels/%s/messages?$top=%d"
                % (t.get("id"), c.get("id"), per_channel),
                limit=per_channel, timeout=15)
        except Exception as e:
            print("[!] 频道消息失败(%s/%s)：%s"
                  % (t.get("displayName"), c.get("displayName"), e), file=sys.stderr)
            return []
        got = []
        for m in msgs:
            if not recent(m):
                continue
            m["_team"] = t.get("displayName") or ""
            m["_channel"] = c.get("displayName") or ""
            got.append(m)
        return got

    if jobs:
        try:
            with ThreadPoolExecutor(max_workers=6) as ex:
                for got in ex.map(msgs_of, jobs):
                    out.extend(got)
        except Exception as e:
            print("[!] 频道消息并发失败：%s" % e, file=sys.stderr)

    # 新的排前面，只留 limit 条
    out.sort(key=lambda m: m.get("createdDateTime") or "", reverse=True)
    out = out[:limit]

    _MSG_CACHE["data"] = out
    _MSG_CACHE["ts"] = time.time()
    return out


def fetch_calendar(days=14):
    """未来两周的日历事件。"""
    t0 = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    t1 = (datetime.now(timezone.utc) + timedelta(days=days)).strftime("%Y-%m-%dT%H:%M:%SZ")
    q = ("/me/calendarView?startDateTime=%s&endDateTime=%s&$top=100"
         "&$select=id,subject,start,end,location,organizer,webLink,isAllDay,bodyPreview"
         "&$orderby=start/dateTime" % (t0, t1))
    return ms.graph_paged(q, limit=100)


# ==========================================================================
# 三、消息 → 任务
# ==========================================================================

CHAT_NOISE = re.compile(
    r"^(ok|okay|好的|好|嗯|收到|谢谢|謝謝|thanks|thank you|thx|"
    r"👍|👌|😂|哈哈+|\+1)[\s！。.]*$", re.I)


def chat_to_task(m, now=None):
    """聊天消息 → 任务。只认「明确指向收件人」且带行动/截止信号的。"""
    now = now or datetime.now(CST)
    body = strip_html((m.get("body") or {}).get("content", ""))
    if not body or len(body) < 8:
        return None
    if CHAT_NOISE.match(body.strip()):
        return None
    # 只保留提到「你」或直接 @ 的
    mentions = m.get("mentions") or []
    addressed = bool(mentions) or re.search(r"@|你|您|同学|同學", body)

    odd, _ = _score(body, ACTION_PATTERNS)
    dld, _ = _score(body, DEADLINE_PATTERNS)
    acd, _ = _score(body, ACADEMIC_PATTERNS)
    score = odd + dld * 1.1 + acd * 1.1
    if addressed:
        score += 1.6
    if score < 4.4:
        return None

    due_ms, due_txt = parse_due(body, now)
    sender = ""
    try:
        frm = m.get("from") or {}
        if isinstance(frm.get("user"), dict):
            sender = frm["user"].get("displayName") or ""
        elif isinstance(frm.get("application"), dict):
            sender = frm["application"].get("displayName") or ""
    except Exception:
        pass
    where = m.get("_where") or ""
    if not where and m.get("_team"):
        where = m["_team"] + (" / " + m["_channel"] if m.get("_channel") else "")
    if where:
        sender = (sender + " · " + where) if sender else where
    when = m.get("createdDateTime")
    created = None
    if when:
        try:
            created = int(datetime.fromisoformat(when.replace("Z", "+00:00"))
                          .timestamp() * 1000)
        except Exception:
            pass

    sig = []
    if odd:
        sig.append("行动要求")
    if acd:
        sig.append("学习/活动")
    if dld:
        sig.append("截止时间")
    if addressed:
        sig.append("点名提到你")

    return {
        "id": "chat:" + str(m.get("id")),
        "source": "chat",
        "title": body.strip().split("\n")[0][:70],
        "course": guess_course(body[:400]),
        "detail": body[:220],
        "dueMs": due_ms,
        "dueText": due_txt or "",
        "createdMs": created,
        "importance": "normal",
        "status": "notStarted",
        "from": sender,
        "webUrl": m.get("webUrl") or "https://teams.microsoft.com",
        "confidence": _confidence(score, lo=0.42, hi=0.93),
        "signals": sig,
        "preview": make_preview(
            text=body,
            sender=sender,
            when_ms=created,
            web_url=m.get("webUrl") or "",
            attachments=msg_attachments(m),
            form=msg_form(m)),
    }


# ==========================================================================
# 四、汇总成板块
# ==========================================================================

def build_section(now=None, include_mail=True, include_chat=True, include_calendar=True):
    """汇总成板块。

    稳定性约定 —— Teams 板块以前频繁空白，就是这三条没守住：
      · 拿不到令牌要**抛 NotAuthenticated**，而不是返回一个空板块。返回空板块
        会让上层拿它覆盖掉上一次的好数据，界面于是毫无征兆地变白；
      · 四路数据源（任务 / 邮件 / 消息 / 日历）**并发**拉取。原来串行时三个
        30 秒超时能叠成一分钟，这段时间里看板就是空的；
      · 某一路失败又什么都没拿到，就**沿用上一次成功的结果**（_LAST）并标记
        snapshot。让用户看到「稍旧的内容」，永远好过看到一片空白。
    """
    now = now or datetime.now(CST)
    try:
        tok = ms.token()
    except Exception as e:
        raise NotAuthenticated("取令牌出错：%s" % e)
    if not tok:
        raise NotAuthenticated("not_authenticated")

    caps = ms.capabilities()
    degraded = []

    # ---------- 四路数据源 ----------
    def _todo():
        out = []
        srcs = [fetch_todo] if caps.get("todo") else []
        # Planner 需要 Group.Read.All（管理员专属），学生账号基本拿不到，拿不到就不试
        if caps.get("planner"):
            srcs.append(fetch_planner)
        for fn in srcs:
            try:
                out.extend(fn())
            except Exception as e:
                print("[!] %s 失败：%s" % (fn.__name__, e), file=sys.stderr)
        return out

    def _mail():
        if not (include_mail and caps.get("mail")):
            return [], []
        mails = fetch_mail()
        _attach_mail_files(mails)          # 顺带补上附件清单，供预览面板用
        ts = []
        for m in mails:
            try:
                t = mail_to_task(m, now)
            except Exception:
                t = None
            if t:
                ts.append(t)
        return mails, ts

    def _chat():
        if not include_chat:
            return [], []
        # 首选频道消息（网页版自带权限，一定能拉）；
        # 1:1 聊天需要 Chat.Read，只有自建应用路线才有，拿得到就一并合进来。
        pool = []
        if caps.get("channels"):
            try:
                pool = fetch_channel_messages()
            except Exception as e:
                print("[!] 频道消息拉取失败：%s" % e, file=sys.stderr)
        if caps.get("chat"):
            try:
                pool = pool + fetch_chats()
            except Exception as e:
                print("[!] 聊天拉取失败：%s" % e, file=sys.stderr)
        ts = []
        for m in pool:
            try:
                t = chat_to_task(m, now)
            except Exception as e:
                print("[!] 消息解析失败：%s" % e, file=sys.stderr)
                continue
            if t:
                ts.append(t)
        return pool, ts

    def _cal():
        if not (include_calendar and caps.get("calendar")):
            return []
        out = []
        for e in fetch_calendar():
            if e.get("isAllDay"):
                continue
            st = (e.get("start") or {}).get("dateTime")
            en = (e.get("end") or {}).get("dateTime")
            if not st:
                continue

            def _to_ms(x):
                try:
                    return int(datetime.fromisoformat(x.split(".")[0])
                               .replace(tzinfo=CST).timestamp() * 1000)
                except Exception:
                    return None
            out.append({
                "id": "cal:" + str(e.get("id")),
                "title": (e.get("subject") or "").strip() or "(无标题)",
                "startMs": _to_ms(st), "endMs": _to_ms(en) if en else None,
                "location": ((e.get("location") or {}).get("displayName") or ""),
                "organizer": (((e.get("organizer") or {}).get("emailAddress") or {})
                              .get("name") or ""),
                "webUrl": e.get("webLink") or "",
            })
        return out

    def _wrap(name, fn, fallback):
        """单路失败只记一笔，绝不让整块崩掉。"""
        try:
            return fn()
        except Exception as e:
            print("[!] %s 拉取失败：%s" % (name, e), file=sys.stderr)
            degraded.append(name)
            return fallback

    with ThreadPoolExecutor(max_workers=4) as ex:
        f_todo = ex.submit(_wrap, "todo", _todo, [])
        f_mail = ex.submit(_wrap, "mail", _mail, ([], []))
        f_chat = ex.submit(_wrap, "chat", _chat, ([], []))
        f_cal = ex.submit(_wrap, "calendar", _cal, [])
        tasks = f_todo.result()
        mails, mail_tasks = f_mail.result()
        msg_pool, chat_tasks = f_chat.result()
        events = f_cal.result()

    # 成功的那几路，把结果留作「下次失败时的底」
    if "todo" not in degraded and tasks:
        _LAST["tasks"] = tasks
    if "mail" not in degraded and mails:
        _LAST["mail"] = mails
    if "calendar" not in degraded and events:
        _LAST["events"] = events
    if _LAST["tasks"] or _LAST["mail"] or _LAST["events"]:
        _LAST["ts"] = time.time()

    # 这一路空手而归 → 交出上次的结果（界面标「快照」，但不是空白）
    snapshot = False
    if not tasks and _LAST["tasks"]:
        tasks, snapshot = _LAST["tasks"], True
    if not mails and _LAST["mail"]:
        mails, snapshot = _LAST["mail"], True
        mail_tasks = []
        for m in mails:
            try:
                t = mail_to_task(m, now)
            except Exception:
                t = None
            if t:
                mail_tasks.append(t)
    if not events and _LAST["events"]:
        events, snapshot = _LAST["events"], True

    # 去重：同一件事可能既是邮件又是聊天里的，按标题近似合并
    allt = tasks + mail_tasks + chat_tasks
    seen, uniq = {}, []
    for t in allt:
        key = re.sub(r"[\s\W]+", "", (t["title"] or "").lower())[:24]
        if key and key in seen:
            keep = seen[key]
            if not keep.get("dueMs") and t.get("dueMs"):
                keep["dueMs"] = t["dueMs"]
                keep["dueText"] = t["dueText"]
            keep.setdefault("alsoFrom", []).append(t["source"])
            continue
        if key:
            seen[key] = t
        uniq.append(t)

    # English Corner：名单里有自己就插一条「去 English Corner」。
    # 只在当天 14:00 之前挂（用户的要求），并且永远排在最前面。
    ec = ec_info()
    ec_task = None
    try:
        m_ec = ec_module()
        if m_ec and ec.get("active"):
            ec_task = m_ec.task_of(ec)
    except Exception as e:
        print("[!] EC 任务生成失败：%s" % e, file=sys.stderr)
    if ec_task:
        # 频道里那条「EC resumes tomorrow…」也会被抽成任务，避免同一件事出现两次
        uniq = [t for t in uniq
                if not (t.get("source") == "chat"
                        and "english corner" in (t.get("title") or "").lower())]
        uniq.insert(0, ec_task)

    # pin（如 EC）最前 → 有截止的按时间 → 没截止的按标题
    uniq.sort(key=lambda t: (not t.get("pin"), t.get("dueMs") is None,
                             t.get("dueMs") or 0))

    day0 = now.replace(hour=0, minute=0, second=0, microsecond=0)
    end_today = int((day0 + timedelta(days=1)).timestamp() * 1000)
    end_week = int((day0 + timedelta(days=7)).timestamp() * 1000)
    now_ms = int(now.timestamp() * 1000)

    stats = {
        "total": len(uniq),
        "overdue": sum(1 for t in uniq if t.get("dueMs") and t["dueMs"] < now_ms),
        "today": sum(1 for t in uniq if t.get("dueMs") and now_ms <= t["dueMs"] < end_today),
        "week": sum(1 for t in uniq if t.get("dueMs") and end_today <= t["dueMs"] < end_week),
        "noDue": sum(1 for t in uniq if not t.get("dueMs")),
        "fromMail": len(mail_tasks),
        "fromChat": len(chat_tasks),
        "ec": 1 if ec_task else 0,
        "unreadMail": sum(1 for m in mails if m.get("isRead") is False),
        "events": len(events),
        "scannedMessages": len(msg_pool),
    }

    acct = ""
    if caps.get("account"):
        try:
            me = ms.graph("/me?$select=displayName,userPrincipalName")
            acct = me.get("userPrincipalName") or me.get("displayName") or ""
        except Exception:
            pass

    return {
        "connected": True,
        "account": acct,
        "caps": caps,                 # 哪几条数据源可用（由实际拿到的权限决定）
        "granted": ms.granted_scopes(),
        "asOf": int(time.time() * 1000),
        # 这一次有哪些数据源没拉到（界面用来提示「部分数据可能稍旧」）
        "degraded": degraded,
        "snapshot": snapshot,
        "stats": stats,
        "ec": ec,
        "tasks": uniq,
        "mail": [{
            "id": m.get("id"),
            "subject": clean_subject(m.get("subject")),
            "from": (((m.get("from") or {}).get("emailAddress") or {}).get("name") or ""),
            "receivedMs": None,
            "isRead": bool(m.get("isRead")),
            "importance": m.get("importance") or "normal",
            "hasAttachments": bool(m.get("hasAttachments")),
            "webUrl": m.get("webLink") or "",
            "preview": (m.get("bodyPreview") or "")[:160],
        } for m in mails],
        "events": events,
    }


if __name__ == "__main__":
    cmd = sys.argv[1] if len(sys.argv) > 1 else "section"
    if cmd == "section":
        s = build_section()
        print(json.dumps({k: (v if k != "tasks" else v[:6])
                          for k, v in s.items()}, ensure_ascii=False, indent=2)[:5000])
    elif cmd == "due":
        for probe in ["Please submit by Sep 25", "请在9月25日前提交", "下周一交作业",
                      "due tomorrow", "deadline: 2026-10-08", "本周五之前", "next Friday"]:
            ms, txt = parse_due(probe)
            human = datetime.fromtimestamp(ms / 1000, CST).strftime("%Y-%m-%d %H:%M") if ms else "—"
            print("%-28s → %-18s (%s)" % (probe, human, txt))
    elif cmd == "mail":
        # 用本地造的数据自测抽取规则
        samples = [
            {"subject": "数学作业：第三章习题",
             "bodyPreview": "请在9月25日前完成第三章习题1-15，拍照上传至Teams作业区。", "isRead": False},
            {"subject": "下周月考安排",
             "bodyPreview": "下周三进行物理月考，范围是第一章到第四章，请提前复习。", "isRead": False},
            {"subject": "Newsletter - September",
             "bodyPreview": "This is our monthly newsletter. Unsubscribe here.", "isRead": True},
            {"subject": "关于运动会报名",
             "bodyPreview": "秋季运动会报名截止时间为本周五，请填写报名表并交给体育委员。", "isRead": False},
            {"subject": "Re: 学生会会议",
             "bodyPreview": "明天的会议改到下午4点，请准时参加。", "isRead": False},
            {"subject": "Your order receipt",
             "bodyPreview": "Thank you for your purchase. Do not reply.", "isRead": True},
        ]
        for s in samples:
            t = mail_to_task(s)
            mark = "✓ 任务" if t else "· 忽略"
            extra = ("  [%s] 截止=%s 学科=%s 置信=%.2f" % (
                t["title"][:28], t["dueText"] or "—", t["course"] or "—", t["confidence"])) if t else ""
            print("%-6s %-34s%s" % (mark, s["subject"][:34], extra))
