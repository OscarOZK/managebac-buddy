#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
生成一份**完全虚构**的演示数据（docs/demo-cache.json）。

为什么要有这个东西
------------------
README 需要截图，但直接拿使用者的 cache.json 去渲染会把他真实的作业标题、
教师姓名、班级编号、成绩一起截进去 —— 而 GitHub 上的图片是删不干净的
（fork、缓存、爬虫都会留档）。

所以截图流程固定为：
    python3 tools/make-demo-cache.py       # 1. 造一份假数据
    bash  tools/shoot-readme.sh            # 2. 用假数据渲染截图
真实缓存**从头到尾不参与** README 的生成。

数据全部是编的：虚构的科目名、虚构的作业标题、虚构的成绩。
学科 key 取自应用本身的配色表（bio/chem/chinese/ela/geo/ids/math/phys），
否则主题色对不上、截图会灰掉。
"""

import calendar
import json
import os
import time

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
OUT = os.path.join(ROOT, "docs", "demo-cache.json")
# 整个数据目录的落点。`--data docs/demo-data` 一次把四条取数口全换掉。
DATA = os.path.join(ROOT, "docs", "demo-data")

# 虚构的「今天」：固定成 2026-09-25 20:00，让截图里的倒计时看起来合理
NOW = 1790300000.0


def iso(days_from_now, hour, minute=0):
    """生成一个 ISO 时间串。days_from_now 可正可负。"""
    t = time.gmtime(NOW + days_from_now * 86400)
    y, mo, d = t.tm_year, t.tm_mon, t.tm_mday
    return f"{y:04d}-{mo:02d}-{d:02d}T{hour:02d}:{minute:02d}:00.000Z"


def human(days_from_now, hour, minute=0):
    """生成 dueText。刻意用英文缩写，跟 ManageBac 的显示风格一致。"""
    months = ["Jan", "Feb", "Mar", "Apr", "May", "Jun",
              "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]
    t = time.gmtime(NOW + days_from_now * 86400)
    ampm = "AM" if hour < 12 else "PM"
    h12 = hour % 12 or 12
    return f"{months[t.tm_mon - 1]} {t.tm_mday}, {h12}:{minute:02d} {ampm}"


# --------------------------------------------------------------------------
#  科目：八个虚构科目。classId 是编的，绝不用真实数字。
# --------------------------------------------------------------------------
SUBJECTS = [
    # key,      label,  完整科目名（不含班级编号）,        classId（虚构）
    ("math",    "数学", "Mathematics (Grade 10)",          "90000001"),
    ("phys",    "物理", "Physics (Grade 10)",              "90000002"),
    ("chem",    "化学", "Chemistry (Grade 10)",            "90000003"),
    ("bio",     "生物", "Biology (Grade 10)",              "90000004"),
    ("chinese", "语文", "Chinese Language Arts (Grade 10)", "90000005"),
    ("ela",     "英语", "English Language Arts (Grade 10)", "90000006"),
    ("geo",     "地理", "Geography (Grade 10)",            "90000007"),
    ("ids",     "综合", "Interdisciplinary Studies (Grade 10)", "90000008"),
]

# --------------------------------------------------------------------------
#  作业：标题一律是编的通用题型名，没有一道题来自真实作业。
# --------------------------------------------------------------------------
TASKS = [
    # subject_key, 标题,                              天数, 时, 分, type,        kind
    ("math",    "Quadratic Functions — Practice Set",      0, 22,  0, "Formative", "Homework"),
    ("chem",    "Lab Report: Reaction Rates",              1, 17, 30, "Summative", "Homework"),
    ("bio",     "Cell Structure Diagram",                  1, 23, 59, "Formative", "Homework"),
    ("ela",     "The Great Gatsby — Essay Outline",        2, 17, 30, "Summative", "Homework"),
    ("phys",    "Free Body Diagrams Worksheet",            2, 23, 59, "Formative", "Homework"),
    ("chinese", "古诗文默写与赏析",                          3, 17, 30, "Formative", "Homework"),
    ("geo",     "Plate Tectonics Poster",                  3, 23, 59, "Summative", "Homework"),
    ("ids",     "Group Project: Sustainable Campus",       4, 17, 30, "Summative", "Homework"),
    ("math",    "Trigonometry Quiz",                       5, 14, 35, "Summative", "Quiz"),
    ("ela",     "Vocabulary Quiz 4",                       6, 14, 35, "Formative", "Quiz"),
    ("chem",    "Periodic Trends — Reading Notes",         7, 23, 59, "Formative", "Homework"),
    ("phys",    "Projectile Motion Problem Set",           8, 23, 59, "Formative", "Homework"),
    ("bio",     "Photosynthesis Lab Prep",                 9, 17, 30, "Formative", "Homework"),
    ("geo",     "Climate Data Interpretation",            10, 23, 59, "Formative", "Homework"),
    # 两条已逾期
    ("chinese", "现代文阅读训练",                             -1, 17, 30, "Formative", "Homework"),
    ("ids",     "课堂参与记录",                              -2, 23, 59, "Formative", "participation"),
]

# --------------------------------------------------------------------------
#  成绩：全部虚构，且刻意拉开档次（好让 GPA 环、学科配色都看得出来）
# --------------------------------------------------------------------------
GRADES = [
    # subject_key, 标题,                                 grade, score, outOf
    ("math",    "Unit 2 Test: Functions",                 "A",  94, 100),
    ("phys",    "Kinematics Quiz 1",                      "A-", 89, 100),
    ("chem",    "Stoichiometry Worksheet",                "A",  96, 100),
    ("bio",     "Ecology Field Notes",                    "B+", 86, 100),
    ("chinese", "现代文阅读训练",                           "A",  92, 100),
    ("ela",     "Comparative Essay",                      "A-", 88, 100),
    ("geo",     "Map Skills Assessment",                  "A",  95, 100),
    ("ids",     "Research Proposal",                      "B+", 87, 100),
]

GRADE_PCT = {"A": 95.0, "A-": 88.0, "B+": 85.0, "B": 80.0}


def build():
    tasks = []
    for (sk, title, dd, hh, mm, typ, kind) in TASKS:
        subj = next(s for s in SUBJECTS if s[0] == sk)
        cid = subj[3]
        tid = f"8000{abs(hash(title)) % 100000:05d}"
        tasks.append({
            "view": "overdue" if dd < 0 else "upcoming",
            "title": title,
            "subject": subj[2],
            "classId": cid,
            "taskId": tid,
            "url": f"/student/classes/{cid}/core_tasks/{tid}",
            "dueText": human(dd, hh, mm),
            "due": iso(dd, hh, mm),
            "type": typ,
            "kind": kind,
            "status": "",
            "createdText": human(-9, 14, 41),
            "created": iso(-9, 14, 41),
        })

    recent = []
    classes = []
    for (sk, label, name, cid) in SUBJECTS:
        mine = [g for g in GRADES if g[0] == sk]
        if not mine:
            continue
        gk, gtitle, grade, score, outof = mine[0]
        latest = {
            "title": gtitle,
            "url": f"/student/classes/{cid}/core_tasks/7000{abs(hash(gtitle)) % 100000:05d}",
            "grade": grade,
            "score": score,
            "outOf": outof,
            "scoreText": f"{score} / {outof} pts",
            "dueText": human(-3, 17, 30),
            "due": iso(-3, 17, 30),
            "gradedAtMs": int((NOW - 3 * 86400) * 1000),
        }
        avg = GRADE_PCT[grade]
        classes.append({
            "key": sk,
            "label": label,
            "classId": cid,
            "name": name,
            "url": f"/student/classes/{cid}/core_tasks",
            "overall": {"mark": grade, "pct": avg},
            "latest": latest,
        })
        recent.append({
            "title": gtitle,
            "url": latest["url"],
            "grade": grade,
            "score": score,
            "outOf": outof,
            "scoreText": latest["scoreText"],
            "dueText": latest["dueText"],
            "due": latest["due"],
            "key": sk,
            "label": label,
            "classId": cid,
            "gradedAtMs": latest["gradedAtMs"],
        })

    recent.sort(key=lambda r: r["gradedAtMs"], reverse=True)

    return {
        "ok": True,
        "reason": "",
        "tasks": tasks,
        "classes": classes,
        "ts": int(NOW * 1000),
        "recent": recent,
        "counts": {
            "upcoming": sum(1 for t in tasks if t["view"] == "upcoming"),
            "overdue": sum(1 for t in tasks if t["view"] == "overdue"),
        },
        "loggedIn": True,
        # 刻意留空：使用者的名字不属于演示数据，也不该出现在截图里
        "user": "",
        "fetchedAt": NOW,
        "stale": False,
        "updating": False,
    }


# --------------------------------------------------------------------------
#  课表：真实课表里有老师姓名和教室号，是全套数据里**最容易漏**的一处。
#  只换 cache.json 的话，作业是假的、老师名字是真的 —— 截一小块就看得出来。
#  from/to 是第几节（1 起算），走班/行政班照旧。
# --------------------------------------------------------------------------
TIMETABLE = {
    "1": [("math",    "Pre-Calculus",        "A201", "Ms. Rivera",   "走班", 1, 1),
          ("ela",     "English Language Arts", "A105", "Mr. Dawson",  "走班", 2, 3),
          ("geo",     "Geography",           "A310", "Mr. Okafor",   "走班", 4, 4),
          ("phys",    "Physics",             "B204", "Dr. Lindqvist", "走班", 5, 5),
          ("chinese", "语文",                 "A108", "李老师",        "走班", 6, 6)],
    "2": [("chem",    "Chemistry",           "B101", "Ms. Haddad",   "走班", 1, 2),
          ("math",    "Pre-Calculus",        "A201", "Ms. Rivera",   "走班", 3, 4),
          ("ids",     "Interdisciplinary",   "C002", "Mr. Bennett",  "走班", 5, 5)],
    "3": [("bio",     "Biology",             "B303", "Dr. Nakamura", "走班", 1, 2),
          ("ela",     "English Language Arts", "A105", "Mr. Dawson",  "走班", 3, 4),
          ("phys",    "Physics",             "B204", "Dr. Lindqvist", "走班", 5, 6)],
    "4": [("math",    "Pre-Calculus",        "A201", "Ms. Rivera",   "走班", 1, 1),
          ("chem",    "Chemistry",           "B101", "Ms. Haddad",   "走班", 2, 3),
          ("geo",     "Geography",           "A310", "Mr. Okafor",   "走班", 4, 5),
          ("chinese", "语文",                 "A108", "李老师",        "走班", 6, 6)],
    "5": [("bio",     "Biology",             "B303", "Dr. Nakamura", "走班", 1, 1),
          ("ela",     "English Language Arts", "A105", "Mr. Dawson",  "走班", 2, 2),
          ("ids",     "Interdisciplinary",   "C002", "Mr. Bennett",  "走班", 3, 4),
          ("phys",    "Physics",             "B204", "Dr. Lindqvist", "走班", 5, 5)],
}


def build_timetable():
    out = {}
    for day, rows in TIMETABLE.items():
        out[day] = [{
            "from": f, "to": t,
            "subject": subj, "room": room, "teacher": teacher,
            "mode": mode, "color": key,
        } for (key, subj, room, teacher, mode, f, t) in rows]
    return out


# --------------------------------------------------------------------------
#  设置：只放「主题 / 配色」这类共同项。真实 settings.json 里的
#  hiddenKeywords（个人屏蔽词）、accentHex 都是使用者自己的偏好，不带进截图。
# --------------------------------------------------------------------------
def build_settings():
    return {
        "v": 1,
        "theme": "system",
        "subjectPresetID": "主题·绿意",
        "accentHex": "#636d21",
        "subjectColors": {
            "bio": "#58753b", "chem": "#5f6b7a", "chinese": "#8e8554",
            "ela": "#b9c21d", "geo": "#7a999c", "ids": "#48501e",
            "math": "#637474", "phys": "#4b6b3a",
        },
        "fontScale": 1.0,
        "density": "comfortable",
        "corner": "regular",
        # 演示用的「今天」是周五，正课日 → 界面里会走满课表那套排版
        "refreshMinutes": 5,
        "nightStart": "18:30",
        "nightEnd": "22:30",
        "wakeTime": "06:00",
        "blueHours": 78,
        "soonHours": 50,
        "urgentHours": 26,
        "showRed": True, "showYellow": True, "showBlue": True,
        "countOverdue": False,
        "taskLimit": 0,
        "hiddenKeywords": "",
        "launchAtLogin": False,
        "reduceMotion": False,
        "reduceTransparency": False,
        "glassStrength": 0.8,
        "panelWidth": 480,
        "showFooterHints": True,
        "labelStyle": "dots",
        "dashboardSection": "tasks",

        # ⑥ 通知 —— 这一块必须**打开**，否则设置页里通知那一区是折叠的，
        #    截图就只剩一个孤零零的开关，完全看不出「可自定义程度很高」。
        "notifyEnabled": True,
        "notifyTask": True,
        "notifyTaskRedOnly": False,   # 打开「所有档都提醒」，让三档阈值那几行也在图里
        "notifyLeadHours": 2,
        "notifyDigest": True,
        "notifyDigestAt": "07:00",
        "notifyTeams": True,
        "notifyMail": True,
        "notifyEvents": True,
        "notifyGrades": True,
        "notifyEC": True,
        "notifyECLead": 30,
        "notifySubjects": [],
        "notifyQuietOn": True,
        "notifyQuietFrom": "22:30",
        "notifyQuietTo": "06:30",
        "notifySound": True,
        "notifySubjectIcon": True,
    }


# --------------------------------------------------------------------------
#  通知去重状态：真实文件里全是「https://beijing101.managebac.cn/...」，
#  光是一个 host 就把学校名字漏了。演示版用 demo.invalid 这个保留域名
#  （RFC 2606 保证它永远不会被注册，也就不可能是任何真实学校的地址）。
# --------------------------------------------------------------------------
def build_notify_state():
    st = {}
    for i, (sk, title, dd, hh, mm, typ, kind) in enumerate(TASKS[:4]):
        st[f"task:{sk}:{i}"] = int(NOW) - i * 3600
    for i, (sk, label, name, cid) in enumerate(SUBJECTS):
        st[f"seed:{sk}"] = int(NOW) - i * 600
    return st


# --------------------------------------------------------------------------
#  Teams（微软待办 / 邮件 / 日历 / English Corner）
#  合作方是微软，数据结构比 ManageBac 那边厚；但泄漏点是一样的 ——
#  课程名、发件人、会议组织者、登录邮箱，这四处都会带出真实姓名。
#  所以课程一律用虚构代号，账号统一挂 example 域名（IANA 保留，永不属于任何人）。
# --------------------------------------------------------------------------
def day_ms(days, hour, minute=0):
    """把「某天某时」换算成毫秒时间戳，基准仍然是 NOW。"""
    t = time.gmtime(NOW + days * 86400)
    return calendar.timegm((t.tm_year, t.tm_mon, t.tm_mday,
                            hour, minute, 0, 0, 0, 0)) * 1000


TEAMS_TASKS = [
    # source,      标题,                                        课程,              天数, 时, 分, importance, 来源人
    ("todo",   "Finish lab safety worksheet",        "Chemistry 10B",   0, 21, 30, "high",   "Ms. Haddad"),
    ("todo",   "Read Chapter 7, take notes",         "Biology 10A",     1, 22,  0, "normal", "Dr. Nakamura"),
    ("planner", "Poster draft — plate tectonics",     "Geography 10C",   2, 17,  0, "normal", "Mr. Okafor"),
    ("mail",   "Submit field trip permission slip",  "Grade 10 Office", 1, 16,  0, "high",   "Grade 10 Office"),
    ("mail",   "Peer review: comparative essay",     "English 10A",     3, 20,  0, "normal", "Mr. Dawson"),
    ("chat",   "Confirm group roles for IDS project", "IDS 10",         2, 12, 30, "normal", "Project Group"),
    ("todo",   "Review quadratic practice set",      "Pre-Calculus 10B", 4, 19,  0, "normal", "Ms. Rivera"),
    # 已逾期一条，好让「逾期」那套配色也出现在图里
    ("todo",   "Correct quiz and resubmit",          "Physics 10A",    -1, 22,  0, "high",   "Dr. Lindqvist"),
]

TEAMS_MAIL = [
    ("Grades published for Unit 2",         "Pre-Calculus 10B", 0, 15, 20, False),
    ("Lab coats needed for Thursday",       "Chemistry 10B",    0, 11,  5, False),
    ("Reminder: portfolio due Friday",      "English 10A",      1,  9, 40, True),
    ("Buses leave at 7:15 for the museum",  "Grade 10 Office",  2, 16, 55, True),
]

TEAMS_EVENTS = [
    ("Grade 10 Assembly",          "Auditorium",       1,  8,  0, "Grade 10 Office"),
    ("Chemistry Lab — Titration",  "B101",             1, 13, 30, "Ms. Haddad"),
    ("Parent–Teacher Conference",  "Main Building",    5,  9,  0, "School Office"),
]

TEAMS_EC = ["Alex Chen", "Bea Torres", "Chris Novak", "Dana Ito", "Eli Rahman",
            "Fay Mensah", "Gus Lindgren", "Hana Sato", "Ivan Petrov"]


def build_teams():
    def task(i, row):
        (src, title, course, dd, hh, mm, imp, who) = row
        due = day_ms(dd, hh, mm)
        return {
            "id": f"t{i:03d}",
            "source": src,
            "title": title,
            "course": course,
            "detail": "",
            "dueMs": due,
            "dueText": "",
            "createdMs": day_ms(-6, 10, 0),
            "importance": imp,
            "status": "",
            "from": who,
            "webUrl": "",
            "confidence": 0.9,
            "signals": [],
            "alsoFrom": [],
            "preview": {
                "text": f"{title} — 这是演示数据。",
                "from": who,
                "whenMs": day_ms(-1, 14, 0),
                "webUrl": "",
                "place": "",
                "attachments": [],
                "form": None,
            },
            "pin": False,
            "kind": "homework",
            "place": "",
        }

    tasks = [task(i, r) for i, r in enumerate(TEAMS_TASKS)]

    mail = []
    for i, (subj, frm, dd, hh, mm, unread) in enumerate(TEAMS_MAIL):
        mail.append({
            "id": f"m{i:03d}",
            "subject": subj,
            "from": frm,
            "receivedMs": day_ms(dd, hh, mm),
            "isRead": not unread,
            "importance": "high" if unread else "normal",
            "hasAttachments": i % 2 == 0,
            "webUrl": "",
            "preview": "这是演示数据，用于 README 截图。",
        })

    events = []
    for i, (title, loc, dd, hh, mm, who) in enumerate(TEAMS_EVENTS):
        start = day_ms(dd, hh, mm)
        events.append({
            "id": f"e{i:03d}",
            "title": title,
            "startMs": start,
            "endMs": start + 45 * 60 * 1000,
            "location": loc,
            "organizer": who,
            "webUrl": "",
        })

    overdue = sum(1 for t in tasks if (t["dueMs"] or 0) < NOW * 1000)
    return {
        "ok": True,
        "loggedIn": True,
        "account": "student@school.example",
        "auth": {"loggedIn": True, "client": "demo", "granted": [], "missing": []},
        "section": {
            "connected": True,
            "reason": "",
            "account": "student@school.example",
            "caps": {"mail": True, "calendar": True, "todo": True,
                     "planner": True, "chat": True, "account": True},
            # 毫秒：界面是 Date(timeIntervalSince1970: asOf / 1000) 读的。
            # 给成秒的话会掉回 1970 年，页头显示「更新于 1月22日」。
            "asOf": NOW * 1000,
            "stats": {
                "total": len(tasks),
                "overdue": overdue,
                "today": 1,
                "week": len(tasks) - overdue,
                "noDue": 0,
                "fromMail": 2,
                "fromChat": 1,
                "unreadMail": sum(1 for m in mail if not m["isRead"]),
                "events": len(events),
                "scannedMessages": 42,
                "ec": 1,
            },
            "tasks": tasks,
            "mail": mail,
            "events": events,
            "degraded": [],
            "snapshot": False,
            "ec": {
                "ok": True,
                "status": "today",
                "note": "今天有 English Corner",
                "hasRoster": True,
                "isToday": True,
                "imIn": True,
                "klass": "Grade 10",
                "students": TEAMS_EC,
                "otherGroups": {},
                "caption": "演示名单",
                "place": "Room 205",
                "window": "16:30 – 17:10",
                "deadlineMs": day_ms(0, 16, 30),
                "dateMs": day_ms(0, 16, 30),
                "date": "2026-09-25",
                "student": "",
                "active": True,
            },
        },
    }


def write_json(path, obj):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w", encoding="utf-8") as f:
        json.dump(obj, f, ensure_ascii=False, indent=2)
    print(f"✓ {path}")


if __name__ == "__main__":
    data = build()
    write_json(OUT, data)
    print(f"  tasks={len(data['tasks'])} classes={len(data['classes'])} "
          f"recent={len(data['recent'])}")

    # 整个数据目录：截图统一走 `--data docs/demo-data`，
    # 作业、课表、通知、设置四条取数口一起变成虚构数据。
    write_json(os.path.join(DATA, "cache.json"), data)
    write_json(os.path.join(DATA, "timetable.json"), build_timetable())
    write_json(os.path.join(DATA, "settings.json"), build_settings())
    write_json(os.path.join(DATA, "notify-state.json"), build_notify_state())
    write_json(os.path.join(DATA, "teams-mock.json"), build_teams())
    print("  全部为虚构数据（科目名、作业标题、成绩、教师、教室、课程、发件人均非真实）")
