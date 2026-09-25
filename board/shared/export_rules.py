#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
把 teams.py 里的识别规则导出成 rules.json。

为什么要有这一步：Mac 端用 Python 跑识别，Windows 端用 JavaScript 跑。
两边的**判定逻辑**各自实现（各自贴合本平台），但**规则表**必须同源 ——
否则今天在 Mac 上调好一个词，Windows 上还是旧的，两边结果对不上。

所以规则表以 teams.py 为唯一真源，改完跑一次本脚本，两端同时生效。
"""

import json
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)

import teams  # noqa: E402

OUT = os.path.normpath(os.path.join(HERE, "..", "windows", "src", "rules.json"))


def main():
    rules = {
        "_note": "由 board/shared/export_rules.py 从 teams.py 自动导出，请勿手改",
        "action": teams.ACTION_PATTERNS,
        "deadline": teams.DEADLINE_PATTERNS,
        "academic": teams.ACADEMIC_PATTERNS,
        "noise": teams.NOISE_PATTERNS,
        "courseTable": [
            ["数学", r"数学|數學|math|algebra|geometry|calculus|三角函数|几何|代数|微积分"],
            ["物理", r"物理|physics|\bphys\b"],
            ["化学", r"化学|化學|chem"],
            ["生物", r"生物|biology|\bbio\b"],
            ["语文", r"语文|語文|chinese|作文|文言文|阅读感悟"],
            ["英语", r"英语|英語|english|\beng\b|雅思|托福|词汇"],
            ["历史", r"历史|歷史|history"],
            ["地理", r"地理|geography|geo\b"],
            ["政治", r"政治|道法|思想品德|civics"],
            ["计算机", r"信息|計算機|计算机|computer|\bcs\b|编程|程式|python"],
            ["体育", r"体育|體育|\bpe\b|运动|跑步|篮球|足球"],
            ["音乐", r"音乐|音樂|music|合唱"],
            ["美术", r"美术|美術|art|绘画|书法"],
            ["心理", r"心理|psych"],
        ],
        # 打分权重：两端必须一致，否则同一封邮件在 Mac 上是任务、在 Windows 上不是
        "weights": {
            "action": 1.0,
            "academic": 1.15,
            "deadline": 1.0,
            "bothBonus": 2.2,
            "highImportance": 1.8,
            "flagged": 1.5,
            "unread": 0.4,
            "mailThreshold": 3.2,
            "chatAction": 1.0,
            "chatDeadline": 1.1,
            "chatAcademic": 1.1,
            "chatAddressed": 1.6,
            "chatThreshold": 4.4,
            "confLo": 0.45,
            "confHi": 0.97,
            "confBase": 3.2,
            "confSpan": 11.0,
            "chatConfLo": 0.42,
            "chatConfHi": 0.93,
            "chatConfBase": 3.2,
            "chatConfSpan": 11.0,
        },
        "leadNoise": r"^\s*(?:re|fwd|fw|回复|回覆|答复|转发|轉發)\s*[:：]\s*",
        "chatNoise": r"^(ok|okay|好的|好|嗯|收到|谢谢|謝謝|thanks|thank you|thx|👍|👌|😂|哈哈+|\+1)[\s！。.]*$",
        "weekdayCN": teams.WEEKDAY_CN,
        "weekdayEN": teams.WEEKDAY_EN,
        "monthEN": teams.MONTH_EN,
    }

    os.makedirs(os.path.dirname(OUT), exist_ok=True)
    with open(OUT, "w", encoding="utf-8") as f:
        json.dump(rules, f, ensure_ascii=False, indent=1)

    n = (len(rules["action"]) + len(rules["deadline"])
         + len(rules["academic"]) + len(rules["noise"]))
    print("已导出 → %s" % OUT)
    print("  行动词 %d · 截止词 %d · 学业词 %d · 噪音词 %d · 学科 %d"
          % (len(rules["action"]), len(rules["deadline"]),
             len(rules["academic"]), len(rules["noise"]),
             len(rules["courseTable"])))
    try:
        print("  大小 %.1f KB" % (os.path.getsize(OUT) / 1024.0))
    except OSError:
        pass


if __name__ == "__main__":
    main()
