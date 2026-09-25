(async () => {
  const OUT = { ok: false, reason: "", tasks: [], classes: [], ts: Date.now() };

  const get = async (u) => {
    const r = await fetch(u, { credentials: "include" });
    return await r.text();
  };
  const isLogin = (html) =>
    /id="session_login"|signin\.managebac|name="session\[login\]"/.test(html);
  const doc = (html) => new DOMParser().parseFromString(html, "text/html");
  const txt = (s) => (s || "").replace(/\s+/g, " ").trim();

  const MON_SHORT = { Jan: 0, Feb: 1, Mar: 2, Apr: 3, May: 4, Jun: 5, Jul: 6, Aug: 7, Sep: 8, Oct: 9, Nov: 10, Dec: 11 };
  const MON_LONG = { January: 0, February: 1, March: 2, April: 3, May: 4, June: 5, July: 6, August: 7, September: 8, October: 9, November: 10, December: 11 };

  /* ============================================================
     1. 待办任务（Upcoming + Overdue）
     ============================================================ */
  function parseDue(t) {
    const m = /([A-Z][a-z]{2})\s+(\d{1,2}),\s*(\d{1,2}):(\d{2})\s*(AM|PM)/.exec(t || "");
    if (!m) return null;
    const mo = MON_SHORT[m[1]];
    let h = parseInt(m[3], 10) % 12;
    if (m[5] === "PM") h += 12;
    return { mo, d: parseInt(m[2], 10), h, mi: parseInt(m[4], 10) };
  }
  function buildDate(p, baseYear, mode, now) {
    let dt = new Date(baseYear, p.mo, p.d, p.h, p.mi, 0, 0);
    if (mode === "upcoming") {
      if (dt.getTime() < now.getTime() - 24 * 3600 * 1000) dt = new Date(baseYear + 1, p.mo, p.d, p.h, p.mi, 0, 0);
    } else if (dt.getTime() > now.getTime() + 24 * 3600 * 1000) {
      dt = new Date(baseYear - 1, p.mo, p.d, p.h, p.mi, 0, 0);
    }
    return dt;
  }

  const [rawUp, rawOd, homeHtml] = await Promise.all([
    get("/student/tasks_and_deadlines?view=upcoming"),
    get("/student/tasks_and_deadlines?view=overdue"),
    get("/student/home").catch(() => ""),
  ]);

  if (isLogin(rawUp) || isLogin(rawOd)) {
    OUT.reason = "logged_out";
    return JSON.stringify(OUT);
  }

  const now = new Date();
  const items = [];

  [["upcoming", rawUp], ["overdue", rawOd]].forEach(([view, html]) => {
    doc(html).querySelectorAll(".f-task-tile").forEach((tile) => {
      const a = tile.querySelector(".f-tile__title-link");
      if (!a) return;
      const href = a.getAttribute("href") || "";
      const tm = /\/student\/classes\/(\d+)\/core_tasks\/(\d+)/.exec(href);
      if (!tm) return;
      const title = txt(a.textContent);
      const desc = tile.querySelector(".f-tile__description");
      let dueTxt = "", subject = "";
      if (desc) {
        desc.querySelectorAll("span").forEach((s) => {
          const t = txt(s.textContent);
          if (!dueTxt && /[A-Z][a-z]{2}\s+\d{1,2},\s*\d{1,2}:\d{2}\s*(AM|PM)/.test(t)) dueTxt = t;
        });
        const ca = desc.querySelector('a[href^="/student/classes/"]');
        if (ca) subject = txt(ca.textContent);
        if (!dueTxt && /N\/A/.test(desc.textContent || "")) dueTxt = "N/A";
      }
      const badges = [];
      tile.querySelectorAll(".badge-label").forEach((b) => badges.push(txt(b.textContent)));
      let status = "";
      const sc = tile.querySelector(".f-task-score p");
      if (sc) status = txt(sc.textContent);
      const p = parseDue(dueTxt);
      items.push({
        view, title, subject, classId: tm[1], taskId: tm[2], url: href, dueText: dueTxt,
        due: p ? buildDate(p, now.getFullYear(), view, now).toISOString() : null,
        type: badges[0] || "", kind: badges[1] || "", status,
      });
    });
  });

  const seen = new Set();
  const uniq = [];
  for (const it of items) {
    if (seen.has(it.url)) continue;
    seen.add(it.url);
    uniq.push(it);
  }

  /* ============================================================
     2. 课程 → 8 个学科槽位（语/数/英/化/物/生/地/IDS）
     ============================================================ */
  const SLOTS = [
    { key: "chinese", label: "语文", re: /chinese|语文|中文/i },
    { key: "math",    label: "数学", re: /pre-?calculus|calculus|\bmath/i },
    { key: "ela",     label: "英语", re: /english/i },
    { key: "chem",    label: "化学", re: /chem/i },
    { key: "phys",    label: "物理", re: /physic/i },
    { key: "bio",     label: "生物", re: /biolog/i },
    { key: "geo",     label: "地理", re: /geograph/i },
    { key: "ids",     label: "IDS",  re: /\bIDS\b|big\s*history/i },
  ];

  const allClasses = [];
  const seenC = {};
  doc(homeHtml).querySelectorAll('a[href*="/student/classes/"]').forEach((a) => {
    const m = /\/student\/classes\/(\d+)/.exec(a.getAttribute("href") || "");
    if (!m || seenC[m[1]]) return;
    const name = txt(a.textContent);
    if (!name || name.length > 70) return;
    seenC[m[1]] = 1;
    allClasses.push({ classId: m[1], name });
  });

  const picked = [];
  SLOTS.forEach((s) => {
    const hit = allClasses.find(
      (c) => s.re.test(c.name) && !picked.some((p) => p.classId === c.classId)
    );
    if (hit) picked.push({ key: s.key, label: s.label, classId: hit.classId, name: hit.name });
  });

  /* ============================================================
     3. 并发展开：任务详情（发布日期） + 各课 core_tasks 页
     ============================================================ */
  function dueFrom(badge, timeTxt) {
    const mb = /([A-Z][a-z]{2})\w*\s+(\d{1,2})/.exec(badge || "");
    if (!mb) return null;
    const mo = MON_SHORT[mb[1]];
    if (mo === undefined) return null;
    const day = parseInt(mb[2], 10);
    let h = 0, mi = 0;
    const mt = /(\d{1,2}):(\d{2})\s*(AM|PM)/i.exec(timeTxt || "");
    if (mt) {
      h = parseInt(mt[1], 10) % 12;
      if (/PM/i.test(mt[3])) h += 12;
      mi = parseInt(mt[2], 10);
    }
    const n = new Date();
    let d = new Date(n.getFullYear(), mo, day, h, mi, 0, 0);
    if (d.getTime() - n.getTime() > 36 * 3600 * 1000) d = new Date(n.getFullYear() - 1, mo, day, h, mi, 0, 0);
    return d.toISOString();
  }

  function parseClassPage(html) {
    const d = doc(html);
    const overall = { mark: "", pct: null };

    d.querySelectorAll(".list-item").forEach((r) => {
      const cells = r.querySelectorAll(".cell");
      if (cells.length < 2) return;
      if (!/^Overall\b/i.test(txt(cells[0].textContent))) return;
      const raw = txt(cells[1].textContent);            // 形如 "A (99.20%)" / "C (78.00%)" / "-"
      const m = /([A-F][+-]?)\s*\(\s*([\d.]+)\s*%/.exec(raw);
      if (m) {
        overall.mark = m[1];
        overall.pct = parseFloat(m[2]);
      } else {
        const m2 = /([A-F][+-]?)/.exec(raw);
        if (m2) overall.mark = m2[1];
        const m3 = /([\d.]+)\s*%/.exec(raw);
        if (m3) overall.pct = parseFloat(m3[1]);
      }
    });

    // Completed 里所有「已给分」的作业
    const scored = [];
    d.querySelectorAll(".fusion-card-item").forEach((t) => {
      const pts = t.querySelector(".points");
      if (!pts) return;
      const pm = /([\d.]+)\s*\/\s*([\d.]+)/.exec(txt(pts.textContent));
      if (!pm) return;
      const a = t.querySelector(".h4.title a[href]") || t.querySelector("a[href*='/core_tasks/']");
      if (!a) return;
      const badge = txt((t.querySelector(".date-badge .month") || {}).textContent) + " " +
                    txt((t.querySelector(".date-badge .day") || {}).textContent);
      const timeTxt = txt((t.querySelector(".due-date .due") || {}).textContent);
      scored.push({
        title: txt(a.textContent),
        url: a.getAttribute("href") || "",
        grade: txt((t.querySelector(".grade") || {}).textContent),
        score: parseFloat(pm[1]),
        outOf: parseFloat(pm[2]),
        scoreText: pm[1] + " / " + pm[2] + " pts",
        dueText: (badge + " " + timeTxt).replace(/\s+/g, " ").trim(),
        due: dueFrom(badge, timeTxt),
      });
    });
    scored.sort((a, b) => (Date.parse(b.due || 0) || 0) - (Date.parse(a.due || 0) || 0));

    return { overall, latest: scored[0] || null, all: scored.slice(0, 5), items: scored };
  }

  const [detailHtmls, classHtmls] = await Promise.all([
    Promise.all(uniq.map((it) => get(it.url).catch(() => ""))),
    Promise.all(picked.map((p) => get("/student/classes/" + p.classId + "/core_tasks").catch(() => ""))),
  ]);

  uniq.forEach((it, i) => {
    let created = "";
    const d = doc(detailHtmls[i] || "");
    d.querySelectorAll("label").forEach((l) => {
      if (created) return;
      if (/^\s*Created\s*$/.test(l.textContent || "")) {
        created = txt((l.parentElement.textContent || "").replace(/^\s*Created\s*/, "")).replace(/\s+at\s+/i, " ");
      }
    });
    it.createdText = created;
    let ms = null;
    const m = /([A-Z][a-z]+)\s+(\d{1,2}),\s*(\d{4})\s+(\d{1,2}):(\d{2})\s*(AM|PM)/.exec(created);
    if (m) {
      let h = parseInt(m[4], 10) % 12;
      if (m[6] === "PM") h += 12;
      ms = new Date(parseInt(m[3], 10), MON_LONG[m[1]], parseInt(m[2], 10), h, parseInt(m[5], 10), 0, 0).toISOString();
    }
    it.created = ms;
  });

  const parsedAll = picked.map((p, i) =>
    classHtmls[i] ? parseClassPage(classHtmls[i]) : { overall: { mark: "", pct: null }, latest: null, items: [] }
  );

  OUT.classes = picked.map((p, i) => {
    const parsed = parsedAll[i];
    return {
      key: p.key,
      label: p.label,
      classId: p.classId,
      name: p.name,
      url: "/student/classes/" + p.classId + "/core_tasks",
      overall: parsed.overall,
      latest: parsed.latest,
      // 逐条作业明细 —— 看板里的「学科柱状图」靠它画每一根柱子。
      // 上限 60 条：一门课一学期也就几十次评分，再多对图没有意义，
      // 白白把 payload 撑大（这个 JSON 每次刷新都要过一遍网络）。
      items: (parsed.items || []).slice(0, 60),
    };
  });

  /* 最近出分的作业：所有课程里已给分的作业汇总，按截止时间从新到旧（ManageBac
     不提供「出分时间」，用截止时间作为「最近」的排序依据） */
  const recent = [];
  picked.forEach((p, i) => {
    (parsedAll[i].items || []).forEach((it) => {
      recent.push(Object.assign({}, it, { key: p.key, label: p.label, classId: p.classId }));
    });
  });
  recent.sort((a, b) => (Date.parse(b.due || 0) || 0) - (Date.parse(a.due || 0) || 0));
  OUT.recent = recent.slice(0, 16);

  OUT.ok = true;
  OUT.tasks = uniq;
  OUT.counts = {
    upcoming: uniq.filter((x) => x.view === "upcoming").length,
    overdue: uniq.filter((x) => x.view === "overdue").length,
  };
  return JSON.stringify(OUT);
})()
