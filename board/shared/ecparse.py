# -*- coding: utf-8 -*-
"""ecparse —— 把 EC Roster PDF 还原成「班 → 学生名单」。

必须用能正确处理 PDF 表格的引擎：EC 名单是教务处用 Word 表格排的，
按班分列，一行里可能横跨多个班的格子。用「读文本流」的方式还原会把
不同班的人混在一起（PDFKit 的字符坐标在这份文件上还会整体错位），
所以这里直接用 PyMuPDF 的表格识别，按单元格取文本。

本脚本由 ecroster.py 通过托管 venv 里的解释器以子进程方式调用，
输出一行 JSON 到 stdout：

    {"caption": "ENGLISH CORNER ROSTER: Tomorrow, Monday 9/21",
     "report_date": "9/21",
     "groups": [{"klass": "Group A", "students": ["Alex Doe", ...]}, ...]}

用法：python ecparse.py <file.pdf>
"""
import json
import re
import sys

import pymupdf

# 名字后面的 "(2)"、"(L)"、"(-1)" 是 EC 次数/迟到/已服务的标记，不是名字的一部分
MARK = re.compile(r"\s*[\(\[]\s*[-]?\d+\s*[\)\]]\s*$")
MARK_LOOSE = re.compile(r"\s*[\(\[]\s*(?:L|R|-?\d+)\s*[\)\]]\s*")
DATE_RE = re.compile(r"(\d{1,2})\s*/\s*(\d{1,2})")

# 班名长这样：单个或多个单词、首字母大写、不含数字
CLASSY = re.compile(r"^[A-Z][A-Za-z\u00C0-\u024F'’\-]*(?:\s+[A-Z][A-Za-z\u00C0-\u024F'’\-]*)*$")


def clean_name(raw):
    """去掉次数/迟到标记，压平空白。"""
    if not raw:
        return ""
    s = raw.replace("\n", " ").replace("\u00a0", " ")
    s = MARK_LOOSE.sub(" ", s)
    s = MARK.sub("", s)
    s = re.sub(r"\s+", " ", s).strip()
    # 有的格子会把标记留在中间，再扫一遍
    s = re.sub(r"\s+\(\s*[-]?\d+\s*\)", "", s).strip()
    return s


def is_class_header(cells):
    """整行都是「像班名」的短词 → 这是表头行。"""
    vals = [c for c in cells if c and c.strip()]
    if len(vals) < 2:
        return False
    for c in vals:
        t = c.replace("\n", " ").strip()
        if not t or not CLASSY.match(t) or len(t) > 18:
            return False
        if re.search(r"\d", t):
            return False
    return True


def merge_header(cells):
    """表头可能把 'Blue House' 拆成两格；把相邻的短词合并成班名。

    合并规则：如果某个格子不是「独立存在的班名」（即与相邻格子合并后
    长度仍然 ≤ 18），就先合并 —— 但我们无法确知哪两个该并，
    所以这里只在「合并后能与数据列数对齐」时才合并，否则原样返回。
    """
    vals = [(i, (c or "").replace("\n", " ").strip()) for i, c in enumerate(cells)]
    vals = [(i, v) for i, v in vals if v]
    return vals


def extract_page(page):
    """返回 [{"klass":..., "students":[...]}, ...]（按表格里出现的顺序）。"""
    out = []
    try:
        tables = page.find_tables().tables
    except Exception:
        return out
    for t in tables:
        try:
            rows = t.extract()
        except Exception:
            continue
        if not rows or len(rows) < 2:
            continue
        header = rows[0] or []
        if not is_class_header(header):
            continue

        body = [r for r in rows[1:] if r]
        if not body:
            continue

        # 表头格数 vs 数据列数：相等时一一对应；
        # 不等（PDF 把班名拆格）时退化到「按列取」，第一列可能并到前一列，
        # 但对「找到目标学生所在列」这件事没有影响。
        ncols = max(len(r) for r in body)
        hcells = [(i, (c or "").replace("\n", " ").strip())
                  for i, c in enumerate(header)]
        hcells = [(i, v) for i, v in hcells if v]
        if len(hcells) == ncols:
            klass_of = {i: v for i, v in hcells}
        else:
            # 表头被拆：把格子在数据列上均匀铺开，宁可班名不准，
            # 也不能把学生的归属搞错（学生会按列取）。
            klass_of = {}
            for k, (i, v) in enumerate(hcells):
                klass_of[min(i, ncols - 1)] = v
            # 相邻两格拼回一个班名（'Blue' + 'House'）
            if len(hcells) == ncols + 1 and ncols >= 2:
                merged = {}
                idx = 0
                for i, v in hcells:
                    if idx == 0 and len(hcells) > 1:
                        merged[0] = v + " " + hcells[1][1]
                        idx = 1
                        continue
                    if idx >= 1:
                        merged[min(idx, ncols - 1)] = v
                    idx += 1
                klass_of = merged

        for ci in range(ncols):
            students = []
            for r in body:
                if ci < len(r):
                    nm = clean_name(r[ci])
                    if nm and len(nm) <= 32 and not is_class_header([nm]):
                        students.append(nm)
            if students:
                out.append({"klass": klass_of.get(ci, ""), "students": students})
    return out


def main():
    path = sys.argv[1]
    doc = pymupdf.open(path)
    caption = ""
    report_date = ""
    groups = []
    for pno in range(doc.page_count):
        page = doc[pno]
        text = page.get_text()
        if not caption:
            for line in text.splitlines():
                if "ENGLISH CORNER ROSTER" in line.upper():
                    caption = line.strip()
                    m = DATE_RE.search(caption)
                    if m:
                        report_date = "%s/%s" % (m.group(1), m.group(2))
                    break
        if not report_date:
            m = DATE_RE.search(text)
            if m:
                report_date = "%s/%s" % (m.group(1), m.group(2))
        groups.extend(extract_page(page))
    print(json.dumps({"caption": caption, "report_date": report_date,
                      "groups": groups}, ensure_ascii=False))


if __name__ == "__main__":
    main()
