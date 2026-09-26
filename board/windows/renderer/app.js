'use strict';
/* ======================================================================
   ManageBac-Buddy · Windows 渲染层
   与 Mac 端（SwiftUI 版）同一套设计语言与同一套派生规则，
   所以两端看到的排序、分档、配色、文案完全一致。
   ====================================================================== */

/* ---------------- 常量（与 Mac 的 Rules.swift 同源） ---------------- */

const PERIODS = [
  ['P1', '08:00', '08:40'], ['P2', '08:50', '09:30'],
  ['P3', '10:00', '10:40'], ['P4', '10:50', '11:30'],
  ['P5', '11:40', '12:20'], ['P6', '13:50', '14:30'],
  ['P7', '14:45', '15:25'], ['P8', '15:40', '16:20']
];

const PALETTE = {
  calc: '#c355c9', phys: '#79c34a', ids: '#f0913f', eng: '#f0913f',
  pol: '#e8b93a', pe: '#8a7be0', chem: '#7b6ce0', geo: '#8a7be0',
  his: '#6f9ce8', bio: '#3fbfa6', it: '#3f8fe0', chi: '#e8638c',
  guide: '#93a3b8', toefl: '#a884d8', art: '#59c2b0', class_meet: '#e05a5a'
};

/* 1=周一 … 5=周五： [起节, 止节, 科目, 教室, 教师, 形式, 颜色key] */
const WEEK = {
  1: [[1, 1, 'AP 初级微积分', 'E103', '李思远', '走班', 'calc'], [2, 3, '高一年级英语', 'E101', 'Alan Reeve', '走班', 'eng'], [4, 4, '历史', 'E106', '周敏', '本班', 'his'], [5, 5, 'AP 化学', 'E112', '吴静', '走班', 'chem'], [6, 7, '高一年级跨学科学习', 'E103', 'Peter Nolan', '走班', 'ids'], [8, 8, '美术', '美术教室', '郑雅', '课程', 'art']],
  2: [[1, 2, 'AP 初级微积分', 'E103', '李思远', '走班', 'calc'], [3, 3, '自习 / 空档', '', '', '', 'guide'], [4, 5, 'AP 化学', 'E112', '吴静', '走班', 'chem'], [6, 7, '生物', 'E106', '孙琳', '本班', 'bio'], [8, 8, '高一年级语文', 'E107', '冯雪', '走班', 'chi']],
  3: [[1, 2, '物理', 'E107', '陈曦', '走班', 'phys'], [3, 4, 'AP 化学', 'E112', '吴静', '走班', 'chem'], [5, 5, '高一年级英语', 'E101', 'Alan Reeve', '走班', 'eng'], [6, 6, '自习 / 空档', '', '', '', 'guide'], [7, 8, '新托福培训', 'W110', '许晴', '走班', 'toefl']],
  4: [[1, 1, '物理', 'E107', '陈曦', '走班', 'phys'], [2, 2, '政治', 'E107', '高洋', '走班', 'pol'], [3, 3, '体育男', '', '罗毅', '走班', 'pe'], [4, 5, '高一年级英语', 'E101', 'Alan Reeve', '走班', 'eng'], [6, 7, '高一年级语文', 'E107', '冯雪', '走班', 'chi'], [8, 8, '班会', 'E106', '李思远', '本班', 'class_meet']],
  5: [[1, 1, '高一年级跨学科学习', 'E103', 'Peter Nolan', '走班', 'ids'], [2, 2, '体育男', '', '罗毅', '走班', 'pe'], [3, 3, '地理', 'E107', '唐婉', '走班', 'geo'], [4, 4, '生物', 'E106', '孙琳', '本班', 'bio'], [5, 5, '信息技术', '信息技术教室', '秦朗', '课程', 'it'], [6, 6, '升学指导', 'E106', '韩冰', '本班', 'guide'], [7, 8, 'AP 初级微积分', 'E103', '李思远', '走班', 'calc']]
};

const SUBJECT_KEYS = ['chinese', 'math', 'ela', 'chem', 'phys', 'bio', 'geo', 'ids'];
const SUBJECT_CN = { chinese: '语文', math: '数学', ela: '英语', chem: '化学', phys: '物理', bio: '生物', geo: '地理', ids: 'IDS' };
const SUBJECT_EN = { chinese: 'Chinese', math: 'Math', ela: 'English', chem: 'Chemistry', phys: 'Physics', bio: 'Biology', geo: 'Geography', ids: 'IDS' };
const SUBJECT_SLOTS = [
  ['chinese', /chinese|语文|中文/i], ['math', /pre-?calculus|calculus|\bmath/i],
  ['ela', /english/i], ['chem', /chem/i], ['phys', /physic/i],
  ['bio', /biolog/i], ['geo', /geograph/i], ['ids', /\bIDS\b|big\s*history/i]
];

const ACCENTS = [
  ['apple', 'Apple 蓝', '#0071e3'], ['indigo', '靛青', '#5e5ce6'],
  ['teal', '湖水青', '#0f9b8e'], ['coral', '珊瑚', '#e8635a'],
  ['amber', '琥珀', '#c98a1e'], ['graphite', '石墨', '#5a5a5f']
];

const PRESETS = {
  morandi: { chinese: '#a96f6b', math: '#867a9e', ela: '#b58455', chem: '#6f7c9e', phys: '#719070', bio: '#5b918a', geo: '#74889c', ids: '#94836f' },
  vivid: { chinese: '#e8556d', math: '#7b61ff', ela: '#f0932b', chem: '#5468ff', phys: '#2ecc71', bio: '#12b8a6', geo: '#3d9be9', ids: '#c56cf0' },
  deep: { chinese: '#8d5a57', math: '#5f5878', ela: '#8a6440', chem: '#4f5c7e', phys: '#526b52', bio: '#416d68', geo: '#566676', ids: '#6f6255' }
};

const DENSITY_SCALE = { compact: 0.86, comfortable: 1, spacious: 1.18 };
const CORNER_SCALE = { sharp: 0.30, regular: 1, round: 1.45 };

/* ---------------- 小工具 ---------------- */

const $ = (s, r = document) => r.querySelector(s);
const $$ = (s, r = document) => Array.from(r.querySelectorAll(s));
const pad2 = n => String(n).padStart(2, '0');
const esc = s => String(s == null ? '' : s).replace(/[&<>"']/g, c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
/* 内联图标：恒带 .ic 基类，保证有确定尺寸（裸 SVG 会被浏览器按 300×150 默认值撑开，
   进而把栅格列顶宽、内容溢出窗口——这是排版上最常见的坑，务必保留这个类） */
const ico = (n, cls = '') => `<svg class="ic ${cls}" aria-hidden="true"><use href="#i-${n}"/></svg>`;
const clamp = (v, a, b) => Math.min(b, Math.max(a, v));

function h(tag, attrs = {}, html) {
  const e = document.createElement(tag);
  for (const k in attrs) {
    if (k === 'class') e.className = attrs[k];
    else if (k === 'style') e.setAttribute('style', attrs[k]);
    else if (k.startsWith('on') && typeof attrs[k] === 'function') e.addEventListener(k.slice(2), attrs[k]);
    else e.setAttribute(k, attrs[k]);
  }
  if (html != null) e.innerHTML = html;
  return e;
}

function hexToRgb(hex) {
  let s = String(hex || '').replace('#', '');
  if (s.length === 3) s = s.split('').map(c => c + c).join('');
  const v = parseInt(s, 16) || 0;
  return [(v >> 16) & 255, (v >> 8) & 255, v & 255];
}
function rgba(hex, a) { const [r, g, b] = hexToRgb(hex); return `rgba(${r},${g},${b},${a})`; }
/** 深色模式往白的方向提亮，保证对比度（与 Mac 的 RGB.color(scheme, lift:) 等价） */
function lift(hex, amount) {
  if (!amount) return hex;
  const [r, g, b] = hexToRgb(hex);
  const m = c => Math.round(c + (255 - c) * amount);
  return `rgb(${m(r)},${m(g)},${m(b)})`;
}
function lum(hex) {
  const [r, g, b] = hexToRgb(hex).map(c => {
    const v = c / 255;
    return v <= 0.03928 ? v / 12.92 : Math.pow((v + 0.055) / 1.055, 2.4);
  });
  return 0.2126 * r + 0.7152 * g + 0.0722 * b;
}
const onColor = hex => (lum(hex) > 0.55 ? 'rgba(0,0,0,.82)' : '#fff');

/* ---------------- 时间与格式 ---------------- */

function humanLeft(ms) {
  const s = Math.round(ms / 1000);
  const d = Math.floor(s / 86400), h = Math.floor((s % 86400) / 3600), m = Math.floor((s % 3600) / 60);
  if (d > 0) return `${d} 天 ${h} 小时`;
  if (h > 0) return `${h} 小时 ${m} 分`;
  if (m > 0) return `${m} 分钟`;
  return '不到 1 分钟';
}
function hms(ms) {
  const t = Math.max(0, Math.floor(ms / 1000));
  const h = Math.floor(t / 3600), m = Math.floor((t % 3600) / 60), s = t % 60;
  return h > 0 ? `${pad2(h)}:${pad2(m)}:${pad2(s)}` : `${pad2(m)}:${pad2(s)}`;
}
const fmtClock = d => pad2(d.getHours()) + ':' + pad2(d.getMinutes());
const fmtPct = v => { const n = Math.round(v * 100) / 100; return n + '%'; };
const to4 = v => (Math.round(v * 400) / 100).toFixed(2);
const shortDueDate = d => `${d.getMonth() + 1}/${d.getDate()} ${pad2(d.getHours())}:${pad2(d.getMinutes())}`;

function shiftColor(hex, scheme) { return scheme === 'dark' ? lift(hex, 0.18) : hex; }

/* 学科识别与精简（与 app.html / Rules.swift 等价） */
function subjectKey(text) {
  const t = String(text || '');
  for (const [k, re] of SUBJECT_SLOTS) if (re.test(t)) return k;
  return '';
}
function subjectShort(raw) {
  let t = String(raw || '');
  t = t.replace(/\(\s*Grade\s*\d+\s*\)/gi, ' ')
       .replace(/\bClass\s*\d+\b/gi, ' ')
       .replace(/\d+\s*班[^\s]*/g, ' ')
       .replace(/\s*\d+(\s*\+\s*\d+)+\s*/g, ' ')
       .replace(/\s*[A-Z]\d{2,4}\s*$/g, ' ')
       .replace(/^AP\s+/i, ' ')
       .replace(/\s+/g, ' ')
       .trim()
       .replace(/\s+[A-Z]$/g, '')
       .trim();
  return t || '课程';
}
function subjectLabel(raw) { const k = subjectKey(raw); return k ? SUBJECT_CN[k] : subjectShort(raw); }
function subjectColor(key, settings, scheme) {
  const hex = (settings.subjectColors && settings.subjectColors[key]) || '#86868b';
  return scheme === 'dark' ? lift(hex, 0.14) : hex;
}

/* ---------------- 课表 ---------------- */

const jsDay = d => d.getDay();
function hm(str, base) {
  const [a, b] = str.split(':').map(Number);
  const d = new Date(base); d.setHours(a, b || 0, 0, 0); return d;
}
function slotsOf(day, date) {
  const blocks = WEEK[day]; if (!blocks) return [];
  const out = [];
  blocks.forEach((b, i) => {
    for (let p = b[0]; p <= b[1]; p++) {
      const per = PERIODS[p - 1];
      out.push({
        id: `${day}-${i}-${p}`, blockId: `${day}-${i}`, dayIdx: day, period: p, pLabel: per[0],
        start: hm(per[1], date), end: hm(per[2], date),
        subject: b[2], room: b[3], teacher: b[4], mode: b[5],
        hex: PALETTE[b[6]] || '#0071e3', isFree: b[2].indexOf('自习') >= 0,
        span: [b[0], b[1]]
      });
    }
  });
  return out;
}
function mergeSlots(list) {
  const out = [];
  for (const s of list) {
    const last = out[out.length - 1];
    if (last && last.blockId === s.blockId) { last.end = s.end; out[out.length - 1] = last; continue; }
    out.push(Object.assign({}, s));
  }
  return out;
}
function nextSchoolDay(after) {
  let d = new Date(after); d.setHours(0, 0, 0, 0);
  for (let i = 0; i < 16; i++) {
    d = new Date(d.getTime() + 86400000);
    const raw = slotsOf(jsDay(d), d);
    if (raw.length) return { day: d, list: mergeSlots(raw) };
  }
  return { day: d, list: [] };
}
function dayList(now) {
  const today = new Date(now); today.setHours(0, 0, 0, 0);
  const raw = slotsOf(jsDay(now), now);
  if (raw.length && now < raw[0].start) return { day: today, list: mergeSlots(raw) };
  if (raw.length && now >= raw[raw.length - 1].end) { const n = nextSchoolDay(now); return n; }
  if (raw.length) return { day: today, list: mergeSlots(raw) };
  return nextSchoolDay(now);
}
const currentSlot = now => slotsOf(jsDay(now), now).find(s => now >= s.start && now < s.end) || null;
function upcoming(now, n = 5) {
  const out = []; let d = now, guard = 0;
  while (out.length < n && guard < 16) {
    const day = jsDay(d);
    if (WEEK[day]) for (const s of slotsOf(day, d)) if (s.start > now) out.push(s);
    d = new Date(d.getTime() + 86400000); guard++;
  }
  return out.slice(0, n);
}
function dayName(d, now) {
  const a = new Date(now); a.setHours(0, 0, 0, 0);
  const b = new Date(d); b.setHours(0, 0, 0, 0);
  const diff = Math.round((b - a) / 86400000);
  if (diff === 0) return '今天';
  if (diff === 1) return '明天';
  if (diff === 2) return '后天';
  return ['周日', '周一', '周二', '周三', '周四', '周五', '周六'][jsDay(d)];
}
const dayCaption = (d, now) => `${dayName(d, now)} · ${d.getMonth() + 1}月${d.getDate()}日 · ${['周日','周一','周二','周三','周四','周五','周六'][jsDay(d)]}`;
const toMin = str => { const [a, b] = str.split(':').map(Number); return a * 60 + (b || 0); };

function topTimer(now, s) {
  const t = now.getHours() * 60 + now.getMinutes();
  if (t >= toMin(s.nightEnd) || t < toMin(s.wakeTime)) return { kind: 'rest' };
  if (t >= toMin(s.nightStart) && t < toMin(s.nightEnd)) return { kind: 'studyEnd', at: hm(s.nightEnd, now) };
  const raw = slotsOf(jsDay(now), now);
  const cur = raw.find(x => now >= x.start && now < x.end);
  if (cur) return { kind: 'inClass', slot: cur };
  const next = raw.find(x => x.start > now);
  if (next) {
    const prev = raw.filter(x => x.end <= now).pop();
    return { kind: 'break', next, since: prev ? prev.end : null };
  }
  if (raw.length && t < toMin(s.nightStart)) return { kind: 'studyStart', at: hm(s.nightStart, now) };
  const nxt = upcoming(now, 1)[0];
  if (nxt) return { kind: 'break', next: nxt, since: null };
  return { kind: 'rest' };
}

function timerLabel(tt) {
  switch (tt.kind) {
    case 'rest': return '现在是休息时间';
    case 'inClass': return tt.slot.isFree ? '空闲时段 · 距离结束' : '正在上课 · 距离下课';
    case 'break': {
      if (!tt.since) return '距离第一节课';
      const gap = (tt.next.start - tt.since) / 60000;
      const hh = tt.since.getHours();
      if (gap >= 50) return (hh >= 11 && hh <= 14) ? '午休 · 距离上课' : '大课间 · 距离上课';
      return '课间休息 · 距离上课';
    }
    case 'studyEnd': return '距离晚自习结束';
    case 'studyStart': return '距离晚自习开始';
  }
  return '';
}

/* ---------------- 待办派生 ---------------- */

function bandOf(leftMs, isOver, s) {
  if (isOver) return 'over';
  if (leftMs == null) return 'ok';
  const h = leftMs / 3600000;
  if (h <= s.urgentHours) return 'urgent';
  if (h <= s.soonHours) return 'soon';
  if (h <= s.blueHours) return 'blue';
  return 'ok';
}
const BAND_NAME = { over: '已逾期', urgent: '紧急', soon: '较急', blue: '留意', ok: '充裕' };
function bandColor(band, settings, scheme) {
  switch (band) {
    case 'over': return shiftColor('#ff3b30', scheme);
    case 'urgent': return shiftColor('#ff3b30', scheme);
    case 'soon': return shiftColor('#ff9f0a', scheme);
    case 'blue': return settings.accentHex;
    default: return shiftColor('#34c759', scheme);
  }
}

function groups(now, settings) {
  const tasks = (state.data && state.data.tasks) || [];
  const hidden = hiddenList(settings);
  const nowMs = now.getTime();
  const up = [], od = [];
  for (const t of tasks) {
    const title = t.title || '';
    if (hidden.some(k => k && title.indexOf(k) >= 0)) continue;
    const due = t.due ? new Date(t.due) : null;
    const leftMs = due ? due.getTime() - nowMs : null;
    const isOver = t.view === 'overdue' || (leftMs != null && leftMs < 0);
    const leftText = isOver
      ? (due ? '已逾期 ' + humanLeft(nowMs - due.getTime()) : '已逾期')
      : (leftMs != null ? '剩 ' + humanLeft(leftMs) : '未设截止');
    const url = MB + (t.url || '');
    const vm = {
      id: t.taskId || t.url || title, title,
      subject: subjectLabel(t.subject), fullSubject: t.subject || '',
      leftText, band: bandOf(leftMs, isOver, settings), url, isOver,
      due, created: t.created ? new Date(t.created) : null,
      kind: t.kind || '', type: t.type || '', leftMs
    };
    (isOver ? od : up).push(vm);
  }
  up.sort((a, b) => {
    const x = a.due ? a.due.getTime() : Infinity, y = b.due ? b.due.getTime() : Infinity;
    return x === y ? (a.subject < b.subject ? -1 : 1) : x - y;
  });
  od.sort((a, b) => (b.due ? b.due.getTime() : 0) - (a.due ? a.due.getTime() : 0));
  return { up, od };
}

function bandCounts(settings) {
  const s = settings || state.settings;
  const g = groups(new Date(), s);
  let list = g.up.slice();
  if (s.countOverdue) list = list.concat(g.od);
  const c = { red: 0, yellow: 0, blue: 0 };
  for (const t of list) {
    if (t.band === 'urgent' && s.showRed) c.red++;
    else if (t.band === 'soon' && s.showYellow) c.yellow++;
    else if (t.band === 'blue' && s.showBlue) c.blue++;
  }
  return c;
}

function hiddenList(settings) {
  return String(settings.hiddenKeywords || '').split(/[\n,，]/).map(x => x.trim()).filter(Boolean);
}

function recentWorks(n, settings) {
  const list = (state.data && state.data.recent) || [];
  return list.slice(0, n).map(w => {
    const key = w.key || subjectKey(w.label || '');
    const g = String(w.grade || '').trim();
    return {
      id: (w.url || w.title || '') + (w.due || ''),
      label: w.label || '—', key,
      title: (w.title || '') || '作业',
      due: w.due ? new Date(w.due) : null,
      dueText: w.due ? shortDueDate(new Date(w.due)) : (w.dueText || ''),
      grade: g || null, scoreText: w.scoreText || '',
      score: w.score, outOf: w.outOf,
      url: w.url ? MB + w.url : null,
      good: !(g.startsWith('C') || g.startsWith('D') || g.startsWith('F'))
    };
  });
}

function gpaRows(settings) {
  const list = (state.data && state.data.classes) || [];
  return list.map(c => ({
    id: c.classId || c.url || c.label,
    label: c.label || '—',
    key: c.key || subjectKey(c.label || ''),
    pct: c.overall ? c.overall.pct : null,
    grade: c.overall ? c.overall.mark : null,
    url: c.url ? MB + c.url : null
  }));
}

/* ======================================================================
   全局状态
   ====================================================================== */
// 学校 ManageBac 地址（与 src/engine.js 保持一致，属可改的默认值）
const MB = 'https://beijing101.managebac.cn';
const state = {
  settings: null,
  data: null,
  lastFetch: null,
  busy: false,
  section: 'todo',
  search: '',
  overdueOpen: false,
  now: new Date(),
  scheme: 'light',
  platform: 'win32',
  navTouched: false,
  teams: null,
  teamsFilter: 'all',
  teamsMailAll: false,
};

/* ---------------- 设置 → CSS 变量（真实生效） ---------------- */

function effectiveScheme(s) {
  if (s.theme === 'dark') return 'dark';
  if (s.theme === 'light') return 'light';
  return window.matchMedia('(prefers-color-scheme: dark)').matches ? 'dark' : 'light';
}

function applySettings() {
  const s = state.settings;
  const root = document.documentElement;
  const scheme = effectiveScheme(s);
  state.scheme = scheme;

  document.body.dataset.theme = scheme;
  document.body.dataset.transparency = s.reduceTransparency ? 'off' : 'on';
  const sysReduce = window.matchMedia('(prefers-reduced-motion: reduce)').matches;
  document.body.dataset.motion = (s.reduceMotion || sysReduce) ? 'off' : 'on';
  document.body.dataset.win = String(state.platform === 'win32');
  document.body.dataset.mac = String(state.platform === 'darwin');

  root.style.setProperty('--den', DENSITY_SCALE[s.density] || 1);
  root.style.setProperty('--rs', CORNER_SCALE[s.corner] || 1);
  root.style.setProperty('--glass', s.reduceTransparency ? 0 : s.glassStrength);
  root.style.setProperty('--fscale', s.fontScale);
  root.style.setProperty('--accent', s.accentHex);
  root.style.setProperty('--side-w', Math.round(200 + (s.panelWidth - 380) * 0.12) + 'px');
}

/* ======================================================================
   组件
   ====================================================================== */

function seg(items, value, onChange) {
  const wrap = h('div', { class: 'seg', role: 'group' });
  items.forEach(it => {
    const b = h('button', {
      type: 'button',
      'aria-pressed': String(it.id === value),
      title: it.label
    }, (it.icon ? ico(it.icon) : '') + '<span>' + esc(it.label) + '</span>');
    b.onclick = () => onChange(it.id);
    wrap.appendChild(b);
  });
  return wrap;
}

function toggle(value, onChange) {
  const b = h('button', { class: 'toggle', type: 'button', 'aria-pressed': String(!!value), role: 'switch' });
  b.onclick = () => onChange(!value);
  return b;
}

function slider(value, min, max, step, color, onChange, fmt) {
  const wrap = h('div', { class: 'slider' });
  const track = h('div', { class: 'track' });
  const fill = h('div', { class: 'fill' });
  const knob = h('div', { class: 'knob' });
  const bubble = h('div', { class: 'bubble' });
  wrap.append(track, fill, knob, bubble);

  let cur = value, drag = false;
  const label = fmt || (v => String(v));

  function paint() {
    const w = wrap.clientWidth || 190;
    const f = (cur - min) / (max - min);
    const cx = clamp(w * f, 8.5, w - 8.5);
    fill.style.width = Math.max(7, w * f) + 'px';
    fill.style.background = `linear-gradient(90deg, ${lift(color, 0.26)}, ${lift(color, 0.02)})`;
    knob.style.left = (cx - 8.5) + 'px';
    bubble.style.left = clamp(cx - 24, 0, w - 48) + 'px';
    bubble.textContent = label(cur);
    bubble.style.background = color;
    bubble.style.opacity = drag ? '1' : '0';
  }

  function setFromX(x) {
    const w = wrap.clientWidth || 190;
    const f = clamp(x / w, 0, 1);
    const raw = min + f * (max - min);
    cur = clamp(Math.round(raw / step) * step, min, max);
    onChange(cur); paint();
  }

  wrap.addEventListener('pointerdown', e => {
    drag = true; wrap.setPointerCapture(e.pointerId);
    setFromX(e.offsetX);
  });
  wrap.addEventListener('pointermove', e => { if (drag) setFromX(e.offsetX); });
  wrap.addEventListener('pointerup', e => {
    drag = false; wrap.releasePointerCapture(e.pointerId); paint();
  });
  wrap.addEventListener('keydown', e => {
    if (e.key === 'ArrowLeft' || e.key === 'ArrowDown') { cur = clamp(cur - step, min, max); onChange(cur); paint(); e.preventDefault(); }
    if (e.key === 'ArrowRight' || e.key === 'ArrowUp') { cur = clamp(cur + step, min, max); onChange(cur); paint(); e.preventDefault(); }
  });
  wrap.tabIndex = 0;
  wrap.setAttribute('role', 'slider');
  wrap.setAttribute('aria-valuemin', min);
  wrap.setAttribute('aria-valuemax', max);
  wrap.setAttribute('aria-valuenow', cur);
  wrap.setAttribute('aria-valuetext', label(cur));

  requestAnimationFrame(paint);
  window.addEventListener('resize', paint);
  return wrap;
}

function pill(text, hex, opts = {}) {
  const c = opts.scheme === 'dark' ? lift(hex, 0.16) : hex;
  const bg = opts.solid ? c : rgba(hex, opts.scheme === 'dark' ? 0.22 : 0.14);
  return `<span class="pill" style="color:${opts.solid ? onColor(hex) : c};background:${bg}">
    ${opts.icon ? ico(opts.icon) : ''}${esc(text)}</span>`;
}

function bar(value, hex, hgt = 4) {
  const pct = clamp(value, 0, 1) * 100;
  return `<div class="bar" style="height:${hgt}px"><i style="width:${Math.max(2, pct)}%;background:linear-gradient(90deg,${lift(hex,0.24)},${hex})"></i></div>`;
}

async function setSetting(partial) {
  const s = await window.mb.setSettings(partial);
  state.settings = s;
  applySettings();
  render();
}

/* ======================================================================
   侧边栏 / 顶栏
   ====================================================================== */

const SECTIONS = [
  { id: 'todo', title: '待办', icon: 'todo', tagline: '按剩余时间排序，越急越靠前' },
  { id: 'teams', title: 'Teams', icon: 'teams', tagline: '微软任务、邮件与聊天里提取出的学习待办' },
  { id: 'classes', title: '课程', icon: 'classes', tagline: '整日课表与本周全览' },
  { id: 'grades', title: '成绩', icon: 'grades', tagline: '各科总评、4 分制折算与最新出分' },
  { id: 'settings', title: '设置', icon: 'settings', tagline: '外观、配色、阈值、刷新 —— 改完立即生效' }
];

function renderSide() {
  const s = state.settings;
  const c = bandCounts(s);
  const total = c.red + c.yellow + c.blue;
  const st = state.data || {};
  const statusText = !state.data ? '准备中'
    : (state.busy ? '读取中…' : (st.loggedIn === false ? '登录已失效' : '数据已就绪'));
  const dotCls = !state.data || state.busy ? 'warn' : (st.loggedIn === false ? 'warn' : '');

  const side = $('#side');
  side.innerHTML = `
    <div class="brand">
      <div class="logo">📂</div>
      <div>
        <h1>ManageBac</h1>
        <div class="sub">看板</div>
      </div>
    </div>
    <nav class="nav">
      ${SECTIONS.map(x => `
        <button type="button" data-nav="${x.id}" aria-current="${state.section === x.id}">
          ${ico(x.icon)}<span>${x.title}</span>
          ${x.id === 'todo' && total > 0 ? `<span class="badge">${total}</span>` : ''}
        </button>`).join('')}
    </nav>
    <div class="side-foot">
      <div class="status"><span class="dot ${dotCls}"></span><span>${esc(statusText)}</span></div>
      <div class="updated">${ico('clock')}<span>${esc(state.lastFetch ? '更新于 ' + fmtClock(state.lastFetch) : statusText)}</span></div>
      <div class="row">
        <button class="btn" id="btnRefresh" style="flex:1;justify-content:center">${ico('refresh')}<span>刷新</span></button>
        <button class="btn" id="btnSite" title="在浏览器中打开 ManageBac">${ico('open')}</button>
      </div>
    </div>`;

  $$('[data-nav]', side).forEach(b => {
    b.onclick = () => { state.navTouched = true; state.section = b.dataset.nav; state.search = ''; render(); $('#scroll').scrollTop = 0; };
  });
  $('#btnRefresh').onclick = () => refresh(true);
  $('#btnSite').onclick = () => window.mb.open(MB);
}

function renderHead() {
  const sec = SECTIONS.find(x => x.id === state.section);
  const s = state.settings;
  const hiddenCount = hiddenList(s).length;
  const expired = state.data && state.data.sessionExpired;

  const head = $('#head');
  head.innerHTML = `
    <div class="titles">
      <h2>${sec.title}</h2>
      <p>${sec.tagline}${state.section === 'todo' && hiddenCount ? ` · 已隐藏 ${hiddenCount} 个关键词` : ''}</p>
    </div>
    <div class="grow"></div>
    ${state.section !== 'settings' ? `
      <div class="search">${ico('search')}<input id="q" placeholder="搜索作业或学科" value="${esc(state.search)}"></div>` : ''}
    ${expired ? pill('登录已失效', '#ff9f0a', { icon: 'warn', scheme: state.scheme }) : ''}`;

  const q = $('#q');
  if (q) {
    q.oninput = () => { state.search = q.value; renderSections(); };
  }
}

/* ======================================================================
   ① 待办
   ====================================================================== */

function heroCard() {
  const s = state.settings, now = state.now, scheme = state.scheme;
  const tt = topTimer(now, s);
  let big = '好好休息', bigSize = 46, name = '', right = '', detail = '', where = '';
  let rgb = s.accentHex, tinted = false;

  if (tt.kind === 'rest') { bigSize = 38; }
  else if (tt.kind === 'inClass') {
    const x = tt.slot;
    big = hms(x.end - now); name = x.isFree ? '没有安排课程' : x.subject;
    right = `${x.pLabel} ${fmtClock(x.start)}–${fmtClock(x.end)}`;
    where = [x.room, x.teacher, x.mode].filter(Boolean).join(' · ');
    rgb = x.hex; tinted = true;
  } else if (tt.kind === 'break') {
    const n = tt.next;
    big = hms(n.start - now); name = n.subject;
    right = `${n.pLabel} ${fmtClock(n.start)}–${fmtClock(n.end)}`;
    where = [n.room, n.teacher, n.mode].filter(Boolean).join(' · ');
    if (tt.since) {
      const gap = n.start - tt.since, passed = now - tt.since;
      detail = `本次休息共 ${Math.round(gap / 60000)} 分钟 · 已过 ${hms(passed)}`;
    }
    rgb = s.accentHex; tinted = true;
  } else if (tt.kind === 'studyEnd') {
    big = hms(tt.at - now); name = '晚自习'; right = `${s.nightEnd} 结束`;
    rgb = s.accentHex; tinted = true;
  } else {
    big = hms(tt.at - now); name = '晚自习'; right = `${s.nightStart} 开始`;
    rgb = s.accentHex; tinted = true;
  }

  const c = scheme === 'dark' ? lift(rgb, 0.14) : rgb;
  return `
    <div class="card pad rise" style="${tinted ? `background:${rgba(rgb, scheme === 'dark' ? 0.18 : 0.20)};` : ''}">
      <div style="display:flex;align-items:center;gap:8px">
        <span style="color:${c};display:flex">${ico('bolt')}</span>
        <b style="font-size:var(--fs-sub);color:${c}">${esc(timerLabel(tt))}</b>
        <span style="flex:1"></span>
        ${right ? `<span style="font-size:var(--fs-sub);color:var(--ink-2);font-variant-numeric:tabular-nums">${esc(right)}</span>` : ''}
      </div>
      <div style="display:flex;align-items:baseline;gap:14px;margin-top:${tinted ? 14 : 12}px">
        <span style="font-size:${bigSize}px;font-weight:700;letter-spacing:-.02em;font-variant-numeric:tabular-nums">${esc(big)}</span>
        ${name ? `<span style="font-size:var(--fs-head);font-weight:600">${esc(name)}</span>` : ''}
        <span style="flex:1"></span>
        <span style="font-size:var(--fs-body);font-weight:600;color:var(--ink-3);font-variant-numeric:tabular-nums">${fmtClock(now)}</span>
      </div>
      ${(detail || where) ? `<div style="margin-top:10px;display:flex;flex-direction:column;gap:3px">
        ${detail ? `<span style="font-size:var(--fs-cap);color:var(--ink-2)">${esc(detail)}</span>` : ''}
        ${where ? `<span style="font-size:var(--fs-cap);color:var(--ink-3);display:flex;align-items:center;gap:5px">${ico('mappin')}${esc(where)}</span>` : ''}
      </div>` : ''}
    </div>`;
}

function statsRow(g) {
  const s = state.settings;
  const graded = recentWorks(200, s).length;
  const in24 = g.up.filter(t => (t.leftMs ?? Infinity) <= 86400000).length;
  const inWeek = g.up.filter(t => (t.leftMs ?? Infinity) <= 7 * 86400000).length;
  const tiles = [
    ['待完成', g.up.length, '项', s.accentHex, 'todo'],
    ['24 小时内', in24, '项', '#ff3b30', 'bolt'],
    ['本周内', inWeek, '项', '#ff9f0a', 'clock'],
    ['已出分', graded, '项', '#34c759', 'grades']
  ];
  return `<div class="grid-stats">
    ${tiles.map((t, i) => `
      <div class="card pad rise" style="animation-delay:${40 + i * 35}ms">
        <div style="display:flex;align-items:center;gap:6px;font-size:var(--fs-cap);color:var(--ink-2)">
          <span style="color:${t[3]};display:flex">${ico(t[4])}</span>${t[0]}
        </div>
        <div style="display:flex;align-items:baseline;gap:4px;margin-top:6px">
          <span style="font-size:27px;font-weight:700;letter-spacing:-.02em;font-variant-numeric:tabular-nums">${t[1]}</span>
          <span style="font-size:var(--fs-cap);color:var(--ink-3)">${t[2]}</span>
        </div>
      </div>`).join('')}
  </div>`;
}

function taskCard(t) {
  const s = state.settings, scheme = state.scheme;
  const c = bandColor(t.band, s, scheme);
  const sk = subjectKey(t.fullSubject);
  const sc = subjectColor(sk, s, scheme);
  const urgency = t.isOver ? 1 : (t.leftMs == null ? 0 : 1 - clamp(t.leftMs / (s.blueHours * 3600000), 0, 1));

  return `
    <div class="card lift task" data-url="${esc(t.url)}" title="${esc(t.fullSubject + '\n' + t.title + '\n' + (t.due ? shortDueDate(t.due) : '未设截止') + ' · ' + t.leftText)}">
      <div class="spine" style="background:linear-gradient(180deg,${c},${rgba(c, 0.55)})"></div>
      <div class="body">
        <div class="top">
          <span class="subj" style="color:${sc}"><em style="background:${sc}"></em><span>${esc(t.subject)}</span></span>
          ${t.kind ? `<span class="kind">${esc(t.kind)}</span>` : ''}
          <span class="grow"></span>
          ${pill(BAND_NAME[t.band], t.band === 'ok' ? '#34c759' : (t.band === 'blue' ? s.accentHex : (t.band === 'soon' ? '#ff9f0a' : '#ff3b30')), { scheme })}
        </div>
        <h4>${esc(t.title)}</h4>
        <div class="spacer"></div>
        ${bar(urgency, t.band === 'ok' ? '#34c759' : (t.band === 'blue' ? s.accentHex : (t.band === 'soon' ? '#ff9f0a' : '#ff3b30')))}
        <div class="foot">
          <span class="due">${ico('clock')}${esc(t.due ? shortDueDate(t.due) : '未设截止')}</span>
          <span class="left" style="color:${c}">${esc(t.leftText)}</span>
        </div>
      </div>
    </div>`;
}

function renderTodo() {
  const s = state.settings;
  let g = groups(state.now, s);
  const q = state.search.trim().toLowerCase();
  if (q) {
    const hit = t => (t.title + ' ' + t.fullSubject + ' ' + t.subject).toLowerCase().indexOf(q) >= 0;
    g = { up: g.up.filter(hit), od: g.od.filter(hit) };
  }
  const limit = Number(s.taskLimit) || 0;
  if (limit > 0) g.up = g.up.slice(0, limit);

  const head = (title, sub, icon) => `
    <div class="section-head">${ico(icon)}<h3>${esc(title)}</h3><span class="count">${esc(sub)}</span></div>`;

  let html = heroCard() + statsRow(g);

  html += `<section>${head('待办事项', g.up.length ? `${g.up.length} 项待完成 · 点任意一张在浏览器中打开` : '', 'todo')}`;
  if (!g.up.length) {
    html += `<div class="card">${emptyBlock(state.data ? '没有待完成的作业' : '正在读取数据…', state.data ? '可以安心休息一下' : '首次抓取大约需要十几秒', state.data ? 'check' : 'clock')}</div>`;
  } else {
    html += `<div class="grid-tasks">${g.up.map(taskCard).join('')}</div>`;
  }
  html += `</section>`;

  if (g.od.length) {
    html += `<section>
      <button class="card" id="odToggle" style="width:100%;display:flex;align-items:center;gap:9px;padding:0 var(--sp-md);height:calc(42px * var(--den));background:${rgba('#ff3b30', state.scheme === 'dark' ? 0.12 : 0.08)}">
        <span style="color:var(--red);display:flex">${ico('warn')}</span>
        <b style="font-size:var(--fs-call)">已逾期 ${g.od.length} 项</b>
        <span style="flex:1"></span>
        <span style="font-size:var(--fs-sub);color:var(--ink-2)">${state.overdueOpen ? '收起' : '展开'}</span>
      </button>
      ${state.overdueOpen ? `<div class="grid-tasks" style="margin-top:var(--sp-sm)">${g.od.map(taskCard).join('')}</div>` : ''}
    </section>`;
  }
  return html;
}

function emptyBlock(title, detail, icon) {
  return `<div class="empty">${ico(icon || 'info')}<div>${esc(title)}</div>${detail ? `<small>${esc(detail)}</small>` : ''}</div>`;
}

/* ======================================================================
   ② 课程
   ====================================================================== */

function renderClasses() {
  const now = state.now, s = state.settings, scheme = state.scheme;
  const dl = dayList(now);
  const cur = currentSlot(now);
  const curBlock = cur ? cur.blockId : null;
  const nowIdx = (() => {
    if (dl.day.getDate() !== now.getDate() || dl.day.getMonth() !== now.getMonth()) return null;
    const first = dl.list[0], last = dl.list[dl.list.length - 1];
    if (!first || now < first.start || now >= last.end) return null;
    return dl.list.filter(x => x.end <= now).length;
  })();

  const head = (title, sub, icon) => `
    <div class="section-head">${ico(icon)}<h3>${esc(title)}</h3><span class="count">${esc(sub)}</span></div>`;

  let html = `<section>${head('课程安排', dayCaption(dl.day, now), 'classes')}
    <div class="card class-list">`;

  dl.list.forEach((x, i) => {
    if (nowIdx === i) {
      const cc = cur ? cur.hex : s.accentHex;
      html += `<div class="nowbar" style="background:${rgba(cc, scheme === 'dark' ? 0.20 : 0.13)};box-shadow:inset 0 0 0 1px ${rgba(cc, 0.5)}">
        <span class="d" style="background:${cc}"></span>
        <b style="color:${scheme === 'dark' ? lift(cc, 0.14) : cc}">现在 ${fmtClock(now)}</b>
        <span>${esc(cur ? cur.subject + ' · 进行中' : '课间休息')}</span>
        ${cur ? `<span class="r" style="color:${scheme === 'dark' ? lift(cc, 0.14) : cc}">${hms(cur.end - now)} 后下课</span>` : ''}
      </div>`;
    }
    const isNow = curBlock && x.blockId === curBlock;
    const rgb = x.hex;
    const spineH = isNow ? 20 : 17, spineW = isNow ? 5 : 3.5;
    const pr = x.span[0] === x.span[1] ? 'P' + x.span[0] : `P${x.span[0]}–P${x.span[1]}`;
    html += `<div class="class-row${isNow ? ' now' : ''}" style="${isNow ? `background:${rgba(rgb, scheme === 'dark' ? 0.20 : 0.16)};box-shadow:inset 0 0 0 1px ${rgba(rgb, 0.45)}` : ''}">
      <span class="spines">
        <i style="height:${spineH}px;background:${scheme === 'dark' ? lift(rgb, 0.12) : rgb};width:${spineW}px"></i>
        ${x.span[1] > x.span[0] ? `<i style="height:${spineH}px;background:${scheme === 'dark' ? lift(rgb, 0.12) : rgb};width:${spineW}px"></i>` : ''}
      </span>
      <span class="p">${pr}</span>
      <span class="t">${fmtClock(x.start)}–${fmtClock(x.end)}</span>
      <span class="s" style="${x.isFree ? 'color:var(--ink-2)' : ''}">${esc(x.subject)}</span>
      ${isNow ? pill('进行中', rgb, { scheme, solid: true })
              : `<span class="r">${esc(x.isFree ? '没有安排课程' : [x.room, x.teacher, x.mode].filter(Boolean).join(' · '))}</span>`}
    </div>`;
  });
  html += `</div></section>`;

  /* 本周网格 */
  html += `<section>${head('本周课表', '周一 – 周五 · P1 – P8', 'grid')}
    <div class="card week">
      <div class="week-row week-head"><span></span>${[1,2,3,4,5].map(d => `<span class="${jsDay(now) === d ? 'today' : ''}">${['周一','周二','周三','周四','周五'][d-1]}</span>`).join('')}</div>`;
  PERIODS.forEach((per, pi) => {
    html += `<div class="week-row"><div class="week-lbl"><b>${per[0]}</b><em>${per[1]}</em></div>`;
    for (let d = 1; d <= 5; d++) {
      const blk = (WEEK[d] || []).find(b => pi + 1 >= b[0] && pi + 1 <= b[1]);
      if (!blk) { html += `<div class="cell blank"></div>`; continue; }
      const isStart = blk[0] === pi + 1;
      const free = blk[2].indexOf('自习') >= 0;
      const rgb = PALETTE[blk[6]] || '#0071e3';
      const isNowCell = jsDay(now) === d && toMin(fmtClock(now)) >= toMin(per[1]) && toMin(fmtClock(now)) < toMin(per[2]);
      const fg = free ? 'var(--ink-2)' : onColor(rgb);
      const bg = free ? 'var(--sunken)' : rgba(rgb, isStart ? 0.92 : 0.78);
      html += `<div class="cell" style="background:${bg};color:${fg};${isNowCell ? `box-shadow:0 0 0 2px ${s.accentHex}` : ''}"
        title="${esc(`${blk[2]} · P${blk[0]}–P${blk[1]}\n${[blk[3], blk[4], blk[5]].filter(Boolean).join(' · ')}`)}">
        ${isStart ? `<b>${esc(blk[2])}</b>${blk[3] ? `<em>${esc(blk[3])}</em>` : ''}` : ''}
      </div>`;
    }
    html += `</div>`;
  });

  const seen = [];
  for (let d = 1; d <= 5; d++) for (const b of (WEEK[d] || [])) if (!seen.some(x => x[0] === b[2])) seen.push([b[2], PALETTE[b[6]]]);
  html += `<div class="legend">${seen.map(x => `<span><i style="background:${x[1]}"></i>${esc(x[0])}</span>`).join('')}</div>
    </div></section>`;

  /* 接下来 */
  const up = upcoming(now, 5);
  html += `<section>${head('接下来', up.length ? '最近 5 节' : '', 'clock')}`;
  if (!up.length) {
    html += `<div class="card">${emptyBlock('接下来没有排课', '周末或假期，好好休息', 'check')}</div>`;
  } else {
    html += `<div class="upcoming">${up.map((x, i) => `
      <div class="card rise" style="animation-delay:${80 + i * 40}ms">
        <h5><i style="background:${x.hex}"></i>${i === 0 ? '下一节' : dayName(x.start, now)}</h5>
        <div class="n">${esc(x.subject)}</div>
        <div style="flex:1"></div>
        <div class="m">${x.pLabel} · ${fmtClock(x.start)}–${fmtClock(x.end)}</div>
        ${x.room ? `<div class="m">${esc(x.room)}</div>` : ''}
      </div>`).join('')}</div>`;
  }
  html += `</section>`;
  return html;
}

/* ======================================================================
   ③ 成绩
   ====================================================================== */

function renderGrades() {
  const s = state.settings, scheme = state.scheme;
  const rows = gpaRows(s);
  const pcts = rows.map(r => r.pct).filter(v => v != null);
  const avg = pcts.length ? pcts.reduce((a, b) => a + b, 0) / pcts.length : null;
  const best = pcts.length ? Math.max(...pcts) : null;
  const worst = pcts.length ? Math.min(...pcts) : null;
  const recent = recentWorks(12, s);

  const head = (title, sub, icon) => `
    <div class="section-head">${ico(icon)}<h3>${esc(title)}</h3><span class="count">${esc(sub)}</span></div>`;

  const R = 62, C = 2 * Math.PI * R;
  const frac = avg == null ? 0 : clamp(avg / 100, 0, 1);

  let html = `<section>
    <div class="card rise">
      <div class="gpa-wrap">
        <div class="donut">
          <svg width="150" height="150" viewBox="0 0 150 150">
            <circle cx="75" cy="75" r="${R}" fill="none" stroke="var(--track)" stroke-width="14"/>
            <circle cx="75" cy="75" r="${R}" fill="none" stroke="${s.accentHex}" stroke-width="14"
                    stroke-linecap="round" stroke-dasharray="${C}" stroke-dashoffset="${C * (1 - frac)}"/>
          </svg>
          <div class="mid"><b>${avg == null ? '—' : fmtPct(avg)}</b><span>总均分</span></div>
        </div>
        <div style="display:flex;flex-direction:column;gap:var(--sp-md)">
          <div>
            <h3 style="margin:0;font-size:var(--fs-title);font-weight:700;letter-spacing:-.028em">GPA 总览</h3>
            <p style="margin:4px 0 0;font-size:var(--fs-sub);color:var(--ink-2)">${pcts.length}/${rows.length} 门已出分 · 按各科 Overall 平均</p>
          </div>
          <div class="metrics">
            <div class="metric"><i>${ico('gauge')}4 分制</i><b>${avg == null ? '—' : to4(avg / 100)}</b><em>满分 4.0</em></div>
            <div class="metric"><i style="color:var(--green)">${ico('up')}最高</i><b>${best == null ? '—' : fmtPct(best)}</b><em>单科最好</em></div>
            <div class="metric"><i style="color:var(--amber)">${ico('down')}最低</i><b>${worst == null ? '—' : fmtPct(worst)}</b><em>单科最弱</em></div>
          </div>
        </div>
      </div>
    </div>
  </section>`;

  html += `<section>${head('各科明细', '点一行查看该课程全部作业', 'grades')}`;
  if (!rows.length) {
    html += `<div class="card">${emptyBlock('暂无课程数据', state.data ? '尚未抓取到课程列表' : '正在读取…', 'grades')}</div>`;
  } else {
    html += `<div class="card grades">${rows.map(r => {
      const c = subjectColor(r.key, s, scheme);
      return `<div class="grade-row" data-url="${esc(r.url || '')}">
        <span class="d" style="background:${c}"></span>
        <span class="lbl">${esc(r.label)}</span>
        ${r.pct == null
          ? `<span class="none">未出分</span>`
          : `${bar(r.pct / 100, (s.subjectColors && s.subjectColors[r.key]) || '#86868b', 6)}
             <span class="pct" style="color:${c}">${fmtPct(r.pct)}</span>
             <span class="mk" style="background:${rgba((s.subjectColors && s.subjectColors[r.key]) || '#86868b', 0.92)};color:${onColor((s.subjectColors && s.subjectColors[r.key]) || '#86868b')}">${esc(r.grade || '')}</span>
             <span class="g4">${to4(r.pct / 100)} / 4.0</span>`}
      </div>`;
    }).join('')}</div>`;
  }
  html += `</section>`;

  html += `<section>${head('最新出分', recent.length ? `最近 ${recent.length} 项` : '', 'sparkle')}`;
  if (!recent.length) {
    html += `<div class="card">${emptyBlock('暂无已评分作业', '', 'info')}</div>`;
  } else {
    html += `<div class="grid-scores">${recent.map((w, i) => {
      const c = subjectColor(w.key, s, scheme);
      const scoreC = w.good ? (scheme === 'dark' ? lift('#34c759', 0.12) : '#34c759') : (scheme === 'dark' ? lift('#ff9f0a', 0.12) : '#c98a1e');
      return `<div class="card lift score rise" data-url="${esc(w.url || '')}" style="animation-delay:${60 + i * 30}ms">
        <div class="top" style="color:${c}"><i style="background:${c}"></i><span>${esc(w.label)}</span>${w.grade ? `<span class="g" style="color:${scoreC}">${esc(w.grade)}</span>` : ''}</div>
        <h5>${esc(w.title)}</h5>
        <div style="flex:1"></div>
        ${(w.score != null && w.outOf) ? bar(w.score / w.outOf, w.good ? '#34c759' : '#ff9f0a') : ''}
        <div class="foot">
          <b>${esc(w.scoreText)}</b>
          <span>${esc(w.dueText)}</span>
        </div>
      </div>`;
    }).join('')}</div>`;
  }
  html += `</section>`;
  return html;
}

/* ======================================================================
   ④ 设置（每一项都真实写回并立即生效）
   ====================================================================== */

function srow(title, detail, ctl) {
  const row = h('div', { class: 'srow' });
  row.appendChild(h('div', { class: 'txt' }, `<b>${esc(title)}</b>${detail ? `<span>${esc(detail)}</span>` : ''}`));
  const c = h('div', { class: 'ctl' });
  if (ctl) c.appendChild(ctl);
  row.appendChild(c);
  return row;
}

function sgroup(title, icon, note, rows) {
  const g = h('div', { class: 'sgroup' });
  g.appendChild(h('header', {}, `${ico(icon)}<h3>${esc(title)}</h3><span class="note">${esc(note || '')}</span>`));
  const body = h('div', { class: 'body card' });
  rows.forEach(r => body.appendChild(r));
  g.appendChild(body);
  return g;
}

/* ======================================================================
   Teams 板块（Microsoft Graph）
   与 Mac 端 DashTeams.swift 对应：概览 → 日程 → 任务 → 邮件
   邮件与聊天里的事项由识别引擎自动抽取，所以每条会标出置信度与依据。
   ====================================================================== */

const TEAMS_SRC = {
  todo:    { label: '微软任务', icon: 'todo',    color: null },
  planner: { label: 'Planner', icon: 'planner', color: '#5e5ce6' },
  mail:    { label: '邮件',    icon: 'mail',    color: '#007aff' },
  chat:    { label: '聊天',    icon: 'chat',    color: '#34c759' }
};

function tfTime(ms) {
  const d = new Date(ms), p = n => String(n).padStart(2, '0');
  return `${p(d.getHours())}:${p(d.getMinutes())}`;
}
function tfDay(ms) {
  const d = new Date(ms);
  return `${d.getMonth() + 1}月${d.getDate()}日`;
}
function tfRel(ms) {
  const s = (Date.now() - ms) / 1000;
  if (s < 3600) return `${Math.max(1, Math.floor(s / 60))} 分钟前`;
  if (s < 86400) return `${Math.floor(s / 3600)} 小时前`;
  const dd = Math.floor(s / 86400);
  return dd < 7 ? `${dd} 天前` : tfDay(ms);
}
function tfIsToday(ms) {
  const d = new Date(ms), n = new Date();
  return d.getFullYear() === n.getFullYear() && d.getMonth() === n.getMonth() && d.getDate() === n.getDate();
}
/** 截止状态 → [文案, 颜色变量, 是否逾期] */
function tfDue(ms) {
  if (ms == null) return ['无截止', 'var(--ink-3)', false];
  const now = Date.now();
  if (ms < now) return ['已逾期', 'var(--red)', true];
  const d = new Date(ms);
  const todayEnd = new Date(); todayEnd.setHours(23, 59, 59, 999);
  if (ms <= todayEnd.getTime()) {
    const mins = Math.round((ms - now) / 60000);
    return [mins < 60 ? `${mins} 分钟后` : `${tfTime(ms)} 截止`, 'var(--red)', false];
  }
  const tmr = new Date(); tmr.setDate(tmr.getDate() + 1); tmr.setHours(23, 59, 59, 999);
  if (ms <= tmr.getTime()) return ['明天 ' + tfTime(ms), 'var(--amber)', false];
  const days = Math.round((new Date(ms).setHours(0,0,0,0) - new Date().setHours(0,0,0,0)) / 86400000);
  if (days < 7) return [`${days} 天后`, 'var(--amber)', false];
  return [tfDay(ms), 'var(--ink-3)', false];
}

function renderTeams() {
  const s = state.settings;
  const t = state.teams || {};
  const srcColor = k => (TEAMS_SRC[k] && TEAMS_SRC[k].color) || s.accentHex;

  /* ---------- 未连接 ---------- */
  if (!t.loggedIn) {
    const logging = !!t.loggingIn;
    const failed = !!t.error && !logging;
    return [`<section>
      <div class="card rise">
        <div class="connect">
          <div class="cico">${ico('teams')}</div>
          <div class="ctxt">
            <h3>${logging ? esc(t.loginMsg || '正在等待你完成授权…') : '连接微软账号'}</h3>
            <p>连一次就好，之后凭据会自动续期，不用重复登录</p>
          </div>
        </div>
        <p class="cdesc">连上之后，这一页会把和 <b>学习、活动</b> 有关的东西集中到一处：微软任务里的作业、Outlook 邮件里提到的事（自动转成待办）、Teams 聊天里点名提到你的消息，以及未来两周的日程。</p>
        ${failed ? `<div class="cwarn">${ico('warn')}<span>${esc(t.error === 'not_authenticated' ? '尚未授权' : t.error)}</span></div>` : ''}
        <div class="cact">
          <button type="button" class="btn primary" id="tLogin" ${logging ? 'disabled' : ''}>
            ${logging ? ico('refresh') + '等待授权中…' : ico('bolt') + '连接微软账号'}
          </button>
          <span class="hint">会打开浏览器让你选账号，本机不保存密码</span>
        </div>
      </div>
    </section>`];
  }

  const sec = t.section || {};
  const tasks = (sec.tasks || []).slice().sort((a, b) => {
    const ax = a.dueMs == null, bx = b.dueMs == null;
    if (ax !== bx) return ax ? 1 : -1;
    return (a.dueMs || 0) - (b.dueMs || 0);
  });
  const events = sec.events || [];
  const mails = sec.mail || [];

  const now = Date.now();
  const overdue = tasks.filter(x => x.dueMs && x.dueMs < now).length;
  const todayEnd = new Date(); todayEnd.setHours(23, 59, 59, 999);
  const today = tasks.filter(x => x.dueMs && x.dueMs >= now && x.dueMs <= todayEnd.getTime()).length;
  const auto = tasks.filter(x => x.source === 'mail' || x.source === 'chat').length;

  const head = (title, sub, icon) =>
    `<div class="section-head">${ico(icon)}<h3>${esc(title)}</h3><span class="count">${esc(sub)}</span></div>`;

  let html = '';

  /* ---------- 概览 ---------- */
  html += `<section>
    <div class="card rise">
      <div class="tl-head">
        <h2>Teams 学习待办</h2>
        ${t.account ? `<span class="pill" style="color:${s.accentHex}">${ico('user')}${esc(t.account.split('@')[0])}</span>` : ''}
        <span class="grow"></span>
        ${t.fetching ? `<span class="hint">同步中…</span>` : (t.ageSec != null ? `<span class="hint">${t.ageSec < 60 ? '刚刚更新' : Math.floor(t.ageSec / 60) + ' 分钟前更新'}</span>` : '')}
        <button type="button" class="iconbtn" id="tRefresh" title="立即刷新">${ico('refresh')}</button>
      </div>
      <div class="metrics" style="margin-top:var(--sp-md)">
        <div class="metric"><i style="color:${s.accentHex}">${ico('todo')}待处理</i><b>${tasks.length}</b><em>全部学习待办</em></div>
        <div class="metric"><i style="color:var(--red)">${ico('warn')}已逾期</i><b>${overdue}</b><em>${overdue > 0 ? '需要马上处理' : '没有欠账'}</em></div>
        <div class="metric"><i style="color:var(--amber)">${ico('clock')}今天到期</i><b>${today}</b><em>${today > 0 ? '今天要交' : '今天清空'}</em></div>
        <div class="metric"><i style="color:var(--green)">${ico('bolt')}自动提取</i><b>${auto}</b><em>来自邮件与聊天</em></div>
      </div>
    </div>
  </section>`;

  /* ---------- 日程 ---------- */
  if (events.length) {
    const todayEv = events.filter(e => e.startMs && tfIsToday(e.startMs));
    const nextEv = events.filter(e => e.startMs && !tfIsToday(e.startMs)).slice(0, 6);
    const evRow = (e, isToday) => `
      <div class="evrow">
        <span class="evt ${isToday ? 'on' : ''}">${tfTime(e.startMs)}</span>
        <i class="evbar ${isToday ? 'on' : ''}"></i>
        <div class="evmain">
          <h4>${esc(e.title)}</h4>
          <div class="evmeta">
            ${e.location ? `<span>${ico('cal')}${esc(e.location)}</span>` : ''}
            ${e.organizer ? `<span>${ico('user')}${esc(e.organizer)}</span>` : ''}
          </div>
        </div>
        ${isToday ? '' : `<span class="evday">${tfDay(e.startMs)}</span>`}
      </div>`;
    html += `<section>
      ${head('日程', events.length + ' 场', 'cal')}
      <div class="card rise">
        ${todayEv.length ? `<div class="evgrp">今天</div>${todayEv.map(e => evRow(e, true)).join('')}` : ''}
        ${nextEv.length ? `<div class="evgrp">接下来</div>${nextEv.map(e => evRow(e, false)).join('')}` : ''}
      </div>
    </section>`;
  }

  /* ---------- 任务 ---------- */
  const f = state.teamsFilter || 'all';
  const shown = f === 'urgent'
    ? tasks.filter(x => x.dueMs && x.dueMs <= todayEnd.getTime())
    : f === 'auto'
      ? tasks.filter(x => x.source === 'mail' || x.source === 'chat')
      : tasks;

  const taskRow = x => {
    const [txt, col, over] = tfDue(x.dueMs);
    const src = TEAMS_SRC[x.source] || TEAMS_SRC.todo;
    const auto = x.source === 'mail' || x.source === 'chat';
    return `<div class="trow" ${x.webUrl ? `data-url="${esc(x.webUrl)}"` : ''}>
      <i class="tspine" style="background:${col}"></i>
      <div class="tmain">
        <h4>${esc(x.title)}</h4>
        <div class="tmeta">
          <span class="pill" style="color:${srcColor(x.source)}">${ico(src.icon)}${esc(src.label)}</span>
          ${x.course ? `<span class="pill ghost">${esc(x.course)}</span>` : ''}
          ${x.importance === 'high' ? `<span class="pill" style="color:var(--red)">${ico('bolt')}重要</span>` : ''}
          ${x.from ? `<span class="tfrom">${esc(x.from)}</span>` : ''}
        </div>
      </div>
      <div class="tright">
        <span class="tdue" style="color:${over ? 'var(--red)' : 'var(--ink-2)'}">${esc(txt)}</span>
        ${auto ? `<span class="tconf ${x.confidence >= 0.75 ? 'ok' : ''}">置信 ${Math.round((x.confidence || 0) * 100)}%</span>` : ''}
      </div>
      ${x.webUrl ? `<span class="topen">${ico('open')}</span>` : ''}
    </div>`;
  };

  html += `<section>
    <div class="section-head">
      ${ico('todo')}<h3>学习任务</h3><span class="count">${shown.length} 条</span>
      <span class="grow"></span>
      <div class="seg">
        ${[['all', '全部'], ['urgent', '紧急'], ['auto', '自动提取']].map(([id, lb]) =>
          `<button type="button" data-tfilter="${id}" aria-pressed="${f === id}">${lb}</button>`).join('')}
      </div>
    </div>
    <div class="card rise">
      ${shown.length ? shown.map(taskRow).join('')
        : emptyBlock('这个筛选下没有任务', '换个筛选看看，或者点右上角刷新', 'todo')}
    </div>
  </section>`;

  /* ---------- 邮件 ---------- */
  if (mails.length) {
    const unread = mails.filter(m => !m.isRead).length;
    const all = !!state.teamsMailAll;
    const list = all ? mails.slice(0, 30) : mails.slice(0, 6);
    html += `<section>
      <div class="section-head">
        ${ico('mail')}<h3>近期邮件</h3><span class="count">${unread} 封未读</span>
        <span class="grow"></span>
        ${mails.length > 6 ? `<button type="button" class="linkbtn" id="tMailMore">${all ? '收起' : '展开全部 ' + mails.length}</button>` : ''}
      </div>
      <div class="card rise">
        ${list.map(m => `
          <div class="mrow" ${m.webUrl ? `data-url="${esc(m.webUrl)}"` : ''}>
            <i class="mdot ${m.isRead ? '' : 'on'}"></i>
            <div class="mmain">
              <h4 class="${m.isRead ? '' : 'unread'}">${esc(m.subject)}</h4>
              <div class="mmeta">
                ${m.from ? `<span>${esc(m.from)}</span>` : ''}
                ${m.importance === 'high' ? `<span class="pill" style="color:var(--red)">${ico('bolt')}重要</span>` : ''}
                ${m.hasAttachments ? `<span class="mclip">${ico('folder')}</span>` : ''}
              </div>
            </div>
            ${m.receivedMs ? `<span class="mtime">${tfRel(m.receivedMs)}</span>` : ''}
            ${m.webUrl ? `<span class="topen">${ico('open')}</span>` : ''}
          </div>`).join('')}
      </div>
    </section>`;
  }

  if (!tasks.length && !mails.length && !events.length) {
    html += `<section><div class="card">${emptyBlock('没有拿到学习相关内容',
      '账号已连上，但学校租户可能没有开放邮件 / 任务权限；聊天与 Planner 权限通常更严', 'teams')}</div></section>`;
  }

  return [html];
}

/** 绑定 Teams 板块里的交互（点击 / 筛选 / 登录） */
function bindTeams(box) {
  const lg = $('#tLogin', box);
  if (lg) lg.onclick = async () => {
    lg.disabled = true;
    lg.innerHTML = ico('refresh') + '等待授权中…';
    await window.mb.teamsLogin();
    pollTeams();
  };
  const rf = $('#tRefresh', box);
  if (rf) rf.onclick = async () => {
    rf.classList.add('spin');
    await window.mb.teamsRefresh();
    pollTeams();
  };
  $$('[data-tfilter]', box).forEach(b => b.onclick = () => {
    state.teamsFilter = b.dataset.tfilter;
    renderSections();
  });
  const mm = $('#tMailMore', box);
  if (mm) mm.onclick = () => { state.teamsMailAll = !state.teamsMailAll; renderSections(); };
}

let teamsPollTimer = null;
function pollTeams() {
  if (teamsPollTimer) clearInterval(teamsPollTimer);
  let n = 0;
  teamsPollTimer = setInterval(async () => {
    n += 1;
    try {
      const snap = await window.mb.teams();
      state.teams = snap;
      renderSide(); renderSections();
      const busy = snap.loggingIn || snap.fetching;
      if (!busy || n > 300) { clearInterval(teamsPollTimer); teamsPollTimer = null; }
    } catch (_) {
      clearInterval(teamsPollTimer); teamsPollTimer = null;
    }
  }, 2000);
}

function renderSettings() {
  const s = state.settings;
  const wrap = h('div', { style: 'display:flex;flex-direction:column;gap:var(--sp-2xl)' });

  /* --- 实时预览 --- */
  const prevWrap = h('div', { class: 'sgroup' });
  prevWrap.appendChild(h('header', {}, `${ico('eye')}<h3>实时预览</h3><span class="note">改任何一项都会立刻反映在这里、托盘和看板上</span>`));
  const prev = h('div', { class: 'preview-row' });
  prev.appendChild(h('div', { class: 'card', style: 'padding:13px' }, `
    <div class="task" style="height:auto;flex-direction:column">
      <div class="top">
        <span class="subj" style="color:${subjectColor('chem', s, state.scheme)}"><em style="background:${subjectColor('chem', s, state.scheme)}"></em><span>化学</span></span>
        <span class="grow"></span>${pill('紧急', '#ff3b30', { scheme: state.scheme })}
      </div>
      <h4 style="margin:8px 0 0">实验报告 · 酸碱滴定</h4>
      <div style="height:12px"></div>
      ${bar(0.82, '#ff3b30')}
      <div class="foot" style="margin-top:8px"><span class="due">${ico('clock')}9/21 10:00</span><span class="left" style="color:${shiftColor('#ff3b30', state.scheme)}">剩 3 小时 12 分</span></div>
    </div>`));
  prev.appendChild(h('div', { class: 'card', style: 'padding:var(--sp-md);display:flex;flex-direction:column;gap:10px' },
    ['chinese', 'math', 'phys'].map(k => `
      <div style="display:flex;align-items:center;gap:9px">
        <span style="width:40px;font-size:var(--fs-sub);font-weight:600">${SUBJECT_CN[k]}</span>
        <div style="flex:1">${bar(k === 'chinese' ? 0.93 : (k === 'math' ? 0.88 : 0.79), (s.subjectColors && s.subjectColors[k]) || '#86868b', 5)}</div>
        <span style="width:42px;text-align:right;font-size:var(--fs-cap);font-weight:700;color:${subjectColor(k, s, state.scheme)}">${k === 'chinese' ? 93 : (k === 'math' ? 88 : 79)}%</span>
      </div>`).join('') +
    `<div style="flex:1"></div>
     <div style="display:flex;gap:var(--sp-xs);flex-wrap:wrap">
      ${pill('密度 ' + ({ compact: '紧凑', comfortable: '舒适', spacious: '宽松' }[s.density]), s.accentHex, { scheme: state.scheme })}
      ${pill('圆角 ' + ({ sharp: '直角', regular: '标准', round: '圆润' }[s.corner]), s.accentHex, { scheme: state.scheme })}
      ${pill('玻璃 ' + Math.round(s.glassStrength * 100) + '%', s.accentHex, { scheme: state.scheme })}
     </div>`));
  prevWrap.appendChild(prev);
  wrap.appendChild(prevWrap);

  /* --- 外观与主题 --- */
  wrap.appendChild(sgroup('外观与主题', 'palette', '主题、密度、圆角与玻璃强度', [
    srow('主题模式', '浅色 / 深色 / 跟随系统',
      seg([{ id: 'system', label: '跟随系统', icon: 'auto' }, { id: 'light', label: '浅色', icon: 'sun' }, { id: 'dark', label: '深色', icon: 'moon' }],
        s.theme, v => setSetting({ theme: v }))),
    srow('界面密度', '影响全部行高与间距',
      seg([{ id: 'compact', label: '紧凑' }, { id: 'comfortable', label: '舒适' }, { id: 'spacious', label: '宽松' }],
        s.density, v => setSetting({ density: v }))),
    srow('圆角风格', '卡片与按钮的圆润程度',
      seg([{ id: 'sharp', label: '直角' }, { id: 'regular', label: '标准' }, { id: 'round', label: '圆润' }],
        s.corner, v => setSetting({ corner: v }))),
    srow('液态玻璃强度', `${Math.round(s.glassStrength * 100)}% —— 拉到 0 会退化成纯色卡面`,
      slider(s.glassStrength, 0, 1, 0.05, s.accentHex, v => setSetting({ glassStrength: v }), v => Math.round(v * 100) + '%')),
    srow('字号缩放', Math.round(s.fontScale * 100) + '%',
      slider(s.fontScale, 0.85, 1.25, 0.05, s.accentHex, v => setSetting({ fontScale: v }), v => Math.round(v * 100) + '%')),
    srow('减弱动效', '关闭悬停抬升、进场动画与过渡',
      toggle(s.reduceMotion, v => setSetting({ reduceMotion: v }))),
    srow('降低透明度', '玻璃退化为实色，字更清楚（无障碍）',
      toggle(s.reduceTransparency, v => setSetting({ reduceTransparency: v })))
  ]));

  /* --- 色彩 --- */
  const sw = h('div', { class: 'swatches' });
  ACCENTS.forEach(([id, name, hex]) => {
    const b = h('button', { class: 'swatch', type: 'button', title: name, 'aria-pressed': String(s.accentHex.toLowerCase() === hex.toLowerCase()), style: `background:${hex};color:${hex}` });
    b.onclick = () => setSetting({ accentHex: hex });
    sw.appendChild(b);
  });
  const picker = h('input', { type: 'color', value: s.accentHex, title: '自定义强调色' });
  picker.oninput = () => setSetting({ accentHex: picker.value });
  sw.appendChild(picker);

  const subjRows = SUBJECT_KEYS.map(k => {
    const row = h('div', { class: 'subj-row' });
    const hex = (s.subjectColors && s.subjectColors[k]) || '#86868b';
    row.appendChild(h('span', { class: 'd', style: `background:${hex}` }));
    row.appendChild(h('span', { class: 'cn' }, SUBJECT_CN[k]));
    row.appendChild(h('span', { class: 'en' }, SUBJECT_EN[k]));
    row.appendChild(h('span', { class: 'hex' }, hex.toUpperCase()));
    const pk = h('input', { type: 'color', value: hex, title: '自定义该学科的颜色' });
    pk.oninput = () => {
      const colors = Object.assign({}, state.settings.subjectColors);
      colors[k] = pk.value;
      setSetting({ subjectPresetID: 'custom', subjectColors: colors });
    };
    row.appendChild(pk);
    return row;
  });

  const colorBody = h('div', { class: 'body card' });
  colorBody.appendChild(srow('强调色', '当前 ' + s.accentHex.toUpperCase(), sw));
  colorBody.appendChild(srow('学科配色方案', '整体切一套，也可逐科微调',
    seg([{ id: 'morandi', label: '莫兰迪（默认）' }, { id: 'vivid', label: '鲜明' }, { id: 'deep', label: '沉静' }],
      s.subjectPresetID, async v => {
        const next = await window.mb.applyPreset(v);
        state.settings = next; applySettings(); render();
      })));
  subjRows.forEach(r => colorBody.appendChild(r));
  const colorGroup = h('div', { class: 'sgroup' });
  colorGroup.appendChild(h('header', {}, `${ico('palette')}<h3>强调色与学科配色</h3><span class="note">强调色影响按钮、选中态、进度条；学科色影响待办色条与成绩行</span>`));
  colorGroup.appendChild(colorBody);
  wrap.appendChild(colorGroup);

  /* --- 阈值 --- */
  const total = Math.max(s.blueHours * 1.35, 1);
  const bandPreview = h('div', { class: 'band-preview' }, `
    <div class="rail">
      ${[[s.urgentHours / total, '#ff3b30'], [(s.soonHours - s.urgentHours) / total, '#ff9f0a'],
         [(s.blueHours - s.soonHours) / total, s.accentHex], [Math.max(0, 1 - s.blueHours / total), '#34c759']]
        .map(([f, c]) => `<i style="flex:${Math.max(0.02, f)};background:${c}"></i>`).join('')}
    </div>
    <div class="keys">
      ${[['紧急', '#ff3b30'], ['较急', '#ff9f0a'], ['留意', s.accentHex], ['充裕', '#34c759']]
        .map(([t, c]) => `<span><i style="background:${c}"></i>${t}</span>`).join('')}
      <span class="end">0 → ${Math.round(s.blueHours)} 小时+</span>
    </div>`);

  const ta = h('textarea', { spellcheck: 'false' });
  ta.value = s.hiddenKeywords;
  ta.onchange = () => setSetting({ hiddenKeywords: ta.value });
  const kwRow = h('div', { style: 'padding:var(--sp-sm) var(--sp-md);display:flex;flex-direction:column;gap:6px' });
  kwRow.appendChild(h('div', { class: 'txt' }, `<b>不显示的关键词</b><span>每行一个，标题里包含这些词的作业会被过滤掉（当前 ${hiddenList(s).length} 个）</span>`));
  kwRow.appendChild(ta);

  const todoBody = h('div', { class: 'body card' });
  todoBody.appendChild(bandPreview);
  todoBody.appendChild(srow('红色 · 紧急', `剩余时间 ≤ ${Math.round(s.urgentHours)} 小时`,
    slider(s.urgentHours, 1, 120, 1, '#ff3b30', v => setSetting({ urgentHours: v }), v => Math.round(v) + ' 小时')));
  todoBody.appendChild(srow('黄色 · 较急', `${Math.round(s.urgentHours)} – ${Math.round(s.soonHours)} 小时`,
    slider(s.soonHours, 2, 240, 1, '#ff9f0a', v => setSetting({ soonHours: v }), v => Math.round(v) + ' 小时')));
  todoBody.appendChild(srow('蓝色 · 留意', `${Math.round(s.soonHours)} – ${Math.round(s.blueHours)} 小时 · 超过则为绿色`,
    slider(s.blueHours, 3, 400, 1, s.accentHex, v => setSetting({ blueHours: v }), v => Math.round(v) + ' 小时')));
  todoBody.appendChild(kwRow);
  todoBody.appendChild(srow('逾期项计入角标', '默认不计（逾期不进托盘角标），开启后会算进红色数字',
    toggle(s.countOverdue, v => setSetting({ countOverdue: v }))));
  const todoGroup = h('div', { class: 'sgroup' });
  todoGroup.appendChild(h('header', {}, `${ico('timer')}<h3>待办紧急度阈值</h3><span class="note">这四档颜色同时决定待办卡的色条、托盘角标和排序</span>`));
  todoGroup.appendChild(todoBody);
  wrap.appendChild(todoGroup);

  /* --- 刷新与启动 --- */
  const chips = h('div', { style: 'display:flex;gap:var(--sp-sm)' });
  [['红', 'showRed', '#ff3b30'], ['黄', 'showYellow', '#ff9f0a'], ['蓝', 'showBlue', s.accentHex]].forEach(([lb, key, hex]) => {
    const on = !!s[key];
    const b = h('button', { class: 'pill', type: 'button', style: `color:${on ? hex : 'var(--ink-3)'};background:${on ? rgba(hex, 0.15) : 'var(--hit)'};box-shadow:inset 0 0 0 1px ${on ? rgba(hex, 0.4) : 'transparent'}` },
      `<i style="width:8px;height:8px;border-radius:50%;background:${on ? hex : 'var(--ink-3)'};display:inline-block"></i>${lb}`);
    b.onclick = () => setSetting({ [key]: !on });
    chips.appendChild(b);
  });

  wrap.appendChild(sgroup('刷新与启动', 'refresh', '抓取一次的代价较高，间隔建议不低于 3 分钟', [
    srow('自动刷新间隔', `每 ${Math.round(s.refreshMinutes)} 分钟抓一次`,
      slider(s.refreshMinutes, 1, 60, 1, s.accentHex, v => setSetting({ refreshMinutes: v }), v => Math.round(v) + ' 分')),
    srow('开机自动启动', '登录 Windows 后自动启动托盘图标',
      toggle(s.launchAtLogin, v => setSetting({ launchAtLogin: v }))),
    srow('角标样式', '托盘图标上数字的画法',
      seg([{ id: 'dots', label: '彩色圆点' }, { id: 'counts', label: '数字角标' }, { id: 'plain', label: '仅图标' }],
        s.labelStyle, v => setSetting({ labelStyle: v }))),
    srow('角标显示哪些档位', '关掉的档位不参与计数', chips),
    srow('面板宽度', `${Math.round(s.panelWidth)} px（影响侧边栏宽度与紧凑布局）`,
      slider(s.panelWidth, 380, 620, 10, s.accentHex, v => setSetting({ panelWidth: v }), v => Math.round(v) + ' px'))
  ]));

  /* --- 作息 --- */
  const timeField = (key) => {
    const i = h('input', { class: 'timefield', value: s[key], maxlength: 5, title: '24 小时制，例如 06:00' });
    i.onchange = () => {
      if (/^\d{1,2}:\d{2}$/.test(i.value)) setSetting({ [key]: i.value });
      else { i.value = state.settings[key]; }
    };
    return i;
  };
  wrap.appendChild(sgroup('作息时间', 'clock', '决定大计时卡在什么时候说「休息」「晚自习」', [
    srow('起床时间', '在此之前算深夜休息', timeField('wakeTime')),
    srow('晚自习开始', '计时卡切换到「距离晚自习结束」', timeField('nightStart')),
    srow('晚自习结束', '之后进入深夜休息', timeField('nightEnd'))
  ]));

  /* --- 看板偏好 --- */
  wrap.appendChild(sgroup('看板偏好', 'grid', '打开看板时先看哪一页、列表多长', [
    srow('默认打开分区', '下次打开看板直接到这一页',
      seg(SECTIONS.map(x => ({ id: x.id, label: x.title, icon: x.icon })), s.dashboardSection,
        v => setSetting({ dashboardSection: v }))),
    srow('待办显示条数', Number(s.taskLimit) === 0 ? '不限（显示全部）' : `只显示最近 ${Math.round(s.taskLimit)} 条`,
      slider(s.taskLimit, 0, 80, 1, s.accentHex, v => setSetting({ taskLimit: v }), v => Number(v) === 0 ? '不限' : Math.round(v) + ' 条')),
    srow('显示操作提示', '卡片网格上方的「点任意一张…」提示',
      toggle(s.showFooterHints, v => setSetting({ showFooterHints: v })))
  ]));

  /* --- 账号与配置 --- */
  const btnReveal = h('button', { class: 'btn' }, `${ico('folder')}<span>设置文件所在位置</span>`);
  btnReveal.onclick = () => window.mb.revealSettings();
  const btnLogout = h('button', { class: 'btn danger' }, `<span>退出登录</span>`);
  btnLogout.onclick = async () => { await window.mb.logout(); state.data = null; refresh(true); };
  const btnForget = h('button', { class: 'btn danger' }, `<span>删除本机保存的账号密码</span>`);
  btnForget.onclick = async () => { await window.mb.forgetCreds(); render(); };
  const btnReset = h('button', { class: 'btn danger' }, `${ico('refresh')}<span>恢复默认设置</span>`);
  btnReset.onclick = async () => {
    const next = await window.mb.resetSettings();
    state.settings = next; applySettings(); render();
  };
  const accRow = h('div', { class: 'srow' });
  accRow.appendChild(h('div', { class: 'txt' }, `<b>账号与数据</b><span>${(state.data && state.data.user) ? '当前登录：' + esc(state.data.user) : '当前状态：' + (state.data && state.data.loggedIn === false ? '未登录' : '已连接')} · 密码用 Windows DPAPI 加密保存在本机</span>`));
  const accCtl = h('div', { class: 'ctl', style: 'gap:var(--sp-xs)' });
  accCtl.append(btnLogout, btnForget);
  accRow.appendChild(accCtl);
  const cfgRow = h('div', { class: 'srow' });
  cfgRow.appendChild(h('div', { class: 'txt' }, `<b>配置文件</b><span>设置保存在应用数据目录，Mac 版读同一份结构</span>`));
  const cfgCtl = h('div', { class: 'ctl', style: 'gap:var(--sp-xs)' });
  cfgCtl.append(btnReveal, btnReset);
  cfgRow.appendChild(cfgCtl);
  const accBody = h('div', { class: 'body card' });
  accBody.append(accRow, cfgRow);
  const accGroup = h('div', { class: 'sgroup' });
  accGroup.appendChild(h('header', {}, `${ico('user')}<h3>账号与配置</h3><span class="note">修改即时保存</span>`));
  accGroup.appendChild(accBody);
  wrap.appendChild(accGroup);

  return wrap;
}

/* ======================================================================
   渲染调度
   ====================================================================== */

function render() {
  const side = $('#side');
  const scrollTop = $('#scroll').scrollTop;
  renderSide();
  renderHead();
  renderSections();
  $('#scroll').scrollTop = scrollTop;
}

function renderSections() {
  const box = $('#sections');
  $('#head').querySelector('.titles') &&
    ($('#head').querySelector('.titles p').innerHTML =
      (SECTIONS.find(x => x.id === state.section).tagline) +
      (state.section === 'todo' && hiddenList(state.settings).length
        ? ` · 已隐藏 ${hiddenList(state.settings).length} 个关键词` : ''));

  let node;
  if (state.section === 'teams') node = h('div', { style: 'display:flex;flex-direction:column;gap:var(--sp-2xl)' }, renderTeams());
  else if (state.section === 'todo') node = h('div', { style: 'display:flex;flex-direction:column;gap:var(--sp-2xl)' }, renderTodo());
  else if (state.section === 'classes') node = h('div', { style: 'display:flex;flex-direction:column;gap:var(--sp-2xl)' }, renderClasses());
  else if (state.section === 'grades') node = h('div', { style: 'display:flex;flex-direction:column;gap:var(--sp-2xl)' }, renderGrades());
  else node = renderSettings();

  box.replaceChildren(node);

  // 点击行为：待办卡 / 成绩行 → 浏览器打开；逾期折叠
  $$('[data-url]', box).forEach(el => {
    el.onclick = () => { const u = el.dataset.url; if (u) window.mb.open(u); };
  });
  const od = $('#odToggle', box);
  if (od) od.onclick = () => { state.overdueOpen = !state.overdueOpen; renderSections(); };

  if (state.section === 'teams') bindTeams(box);
}

/* ======================================================================
   数据与 IPC
   ====================================================================== */

async function refresh(force) {
  state.busy = true; renderSide();
  try {
    const r = await window.mb.getData(!!force);
    state.data = r.state; state.lastFetch = new Date();
  } catch (_) {}
  state.busy = false;
  render();
  // Teams 是独立链路：单独拿，慢一点也不会让主看板等着
  try {
    state.teams = await window.mb.teams();
    if (state.section === 'teams') renderSections();
    if (state.teams && (state.teams.fetching || state.teams.loggingIn)) pollTeams();
  } catch (_) {}
}

function showLogin(reason) {
  const ov = $('#overlay');
  const hint = $('#loginHint');
  hint.textContent = reason === 'expired'
    ? '登录已失效。重新登录后即可继续读取最新的作业与成绩。'
    : '看板需要一次登录才能读取你的作业与成绩。登录信息只在这台电脑上用于抓取，密码可选地加密保存在本机。';
  const s = state.settings;
  $('#fSave').checked = true;
  ov.hidden = false;
}

function hideLogin() { $('#overlay').hidden = true; }

async function doLogin() {
  const login = $('#fLogin').value.trim();
  const password = $('#fPass').value;
  const save = $('#fSave').checked;
  const msg = $('#loginMsg');
  if (!login || !password) { msg.className = 'msg err'; msg.textContent = '请填写账号和密码'; return; }
  msg.className = 'msg'; msg.textContent = '正在登录…';
  $('#btnLogin').disabled = true;
  const r = await window.mb.login({ login, password, remember: true, save });
  $('#fPass').value = '';
  $('#btnLogin').disabled = false;
  if (r.ok) {
    msg.className = 'msg ok';
    msg.textContent = '登录成功' + (r.saved ? '（账号密码已加密保存在本机）' : '');
    hideLogin();
    await refresh(true);
  } else {
    msg.className = 'msg err';
    msg.textContent = r.msg || '登录失败';
  }
}

async function boot() {
  const b = await window.mb.bootstrap();
  state.settings = b.settings;
  state.data = b.state;
  state.teams = b.teams || null;
  state.platform = b.platform;
  // 只有用户还没自己切过分区时，才用设置里的「默认分区」覆盖
  if (!state.navTouched) state.section = b.settings.dashboardSection || 'todo';
  state.lastFetch = new Date();

  applySettings();
  render();

  if (!state.data || state.data.loggedIn === false) {
    showLogin(state.data && state.data.sessionExpired ? 'expired' : 'first');
  }

  window.mb.onData(d => {
    state.data = d;
    state.busy = false;
    state.lastFetch = new Date();
    render();
    if (d && d.loggedIn === false && !state.data.__asked) {
      state.data.__asked = true;
      showLogin('expired');
    }
  });
  window.mb.onSettings(s => { state.settings = s; applySettings(); render(); });
  window.mb.onTick(() => { state.now = new Date(); renderSections(); });
  window.mb.onRefresh(() => refresh(true));
  window.mb.onGoto(sec => { state.navTouched = true; state.section = sec; render(); });
}

window.addEventListener('DOMContentLoaded', () => {
  $('#btnLogin').onclick = doLogin;
  $('#btnBrowser').onclick = () => window.mb.openLoginWindow();
  $('#fPass').addEventListener('keydown', e => { if (e.key === 'Enter') doLogin(); });
  $('#fLogin').addEventListener('keydown', e => { if (e.key === 'Enter') $('#fPass').focus(); });
  document.addEventListener('keydown', e => {
    if (e.key === 'Escape') hideLogin();
    if ((e.metaKey || e.ctrlKey) && e.key.toLowerCase() === 'r') { e.preventDefault(); refresh(true); }
    if ((e.metaKey || e.ctrlKey) && ['1', '2', '3', '4'].includes(e.key)) {
      e.preventDefault();
      state.navTouched = true;
      state.section = SECTIONS[Number(e.key) - 1].id;
      render();
    }
  });
  setInterval(() => { state.now = new Date(); if (state.section !== 'settings') renderSections(); }, 1000);
  boot();
});
