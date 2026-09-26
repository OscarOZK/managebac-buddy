/*
 * Teams 板块数据层（Windows / Electron）
 *
 * 与 Mac 端的 board/shared/teams.py 是一对孪生实现：
 *   · 判定逻辑各自用本平台的语言写（那边 Python，这边 JavaScript）
 *   · 规则表（行动词 / 截止词 / 学业词 / 权重）统一读 src/rules.json
 *     该文件由 board/shared/export_rules.py 从 teams.py 导出，保证两端判定一致
 *
 * 只读：绝不回写微软账号里的任何数据。
 */

const https = require('https');
const http = require('http');
const fs = require('fs');
const path = require('path');
const crypto = require('crypto');

let RULES = null;
let TOKEN_FILE = null;
let userDataDir = null;

/* Microsoft 公开客户端 + 第一方客户端兜底链
 *
 * 踩过的坑（别改回去）：早先的权限清单里混了 Group.Read.All 与
 * ChannelMessage.Read.All —— 这两个是「仅管理员可授予」的权限，学校租户会
 * 直接弹「需要管理员批准」，学生账号根本走不过去。现在只要最小可用集。
 *
 * 官方 Graph 客户端若被租户挡住，就自动退到微软第一方应用：它们的权限在
 * 租户开通服务时已由微软预授权，通常不再弹同意页。
 */
const CLIENT_CHAIN = [
  { label: 'Microsoft Graph 命令行工具', id: '14d82eec-204b-4c2f-b7e8-296a70dab67e', allowDefault: false },
  { label: 'Microsoft Office', id: 'd3590ed6-52b3-4102-aeff-aad2292ab01c', allowDefault: true },
  { label: 'Microsoft Outlook', id: '27922004-5251-4030-b22d-91ecd9a37ea4', allowDefault: true },
  { label: 'Microsoft Teams', id: '1fec8e78-bce4-4aaf-ab1b-5451cc387264', allowDefault: true }
];
const AUTHORITY = 'https://login.microsoftonline.com/common';
const GRAPH_DEFAULT = 'https://graph.microsoft.com/.default';
const SCOPES = [
  'openid', 'profile', 'offline_access', 'User.Read',
  'Mail.Read', 'Mail.ReadBasic', 'Calendars.Read',
  'Tasks.Read', 'Chat.Read'
];
const REQUIRED = ['User.Read', 'Mail.Read', 'Calendars.Read', 'Tasks.Read', 'Chat.Read'];
/** 最近一次登录失败详情，给界面显示 */
let lastLogin = { error: '', kind: '', client: '' };

function init(opts) {
  userDataDir = opts.userData;
  TOKEN_FILE = path.join(userDataDir, 'ms_token.json');
  RULES = JSON.parse(fs.readFileSync(path.join(__dirname, 'rules.json'), 'utf8'));
}

/* ==========================================================================
   HTTP
   ========================================================================== */

function request(url, { method = 'GET', headers = {}, body = null } = {}) {
  return new Promise((resolve) => {
    let u;
    try { u = new URL(url); } catch (e) { return resolve({ __error: 'bad_url' }); }
    const mod = u.protocol === 'http:' ? http : https;
    const req = mod.request({
      hostname: u.hostname,
      port: u.port || (u.protocol === 'http:' ? 80 : 443),
      path: u.pathname + u.search,
      method,
      headers
    }, (res) => {
      let raw = '';
      res.on('data', c => { raw += c; });
      res.on('end', () => {
        let j = {};
        try { j = raw.trim() ? JSON.parse(raw) : {}; } catch (e) { j = { __raw: raw.slice(0, 800) }; }
        if (res.statusCode >= 400) j.__http = res.statusCode;
        resolve(j);
      });
    });
    req.on('error', (e) => resolve({ __error: String(e.message || e) }));
    req.setTimeout(30000, () => { req.destroy(); resolve({ __error: 'timeout' }); });
    if (body) req.write(body);
    req.end();
  });
}

function postForm(url, form) {
  const body = Object.entries(form)
    .map(([k, v]) => encodeURIComponent(k) + '=' + encodeURIComponent(v)).join('&');
  return request(url, {
    method: 'POST', body,
    headers: {
      'Content-Type': 'application/x-www-form-urlencoded',
      'Content-Length': Buffer.byteLength(body),
      'Accept': 'application/json'
    }
  });
}

/* ==========================================================================
   令牌
   ========================================================================== */

function loadToken() {
  try { return JSON.parse(fs.readFileSync(TOKEN_FILE, 'utf8')); } catch (e) { return null; }
}

function saveToken(tok) {
  try {
    fs.mkdirSync(path.dirname(TOKEN_FILE), { recursive: true });
    fs.writeFileSync(TOKEN_FILE, JSON.stringify(tok, null, 1));
    fs.chmodSync(TOKEN_FILE, 0o600);
  } catch (e) { /* 忽略：写不进去也不该让看板挂掉 */ }
}

function clearToken() { try { fs.unlinkSync(TOKEN_FILE); } catch (e) { /* 本来就没有 */ } }

function storeToken(t, clientId, reqScope) {
  const cur = loadToken() || {};
  const out = {
    access_token: t.access_token,
    refresh_token: t.refresh_token || cur.refresh_token,
    expires_at: Math.floor(Date.now() / 1000) + (t.expires_in || 3600) - 120,
    scope: t.scope || '',
    client_id: clientId || cur.client_id || CLIENT_CHAIN[0].id,
    req_scope: reqScope || cur.req_scope || SCOPES.join(' ')
  };
  Object.keys(out).forEach(k => { if (!out[k]) delete out[k]; });
  saveToken(out);
}

/** 解出 JWT 载荷（不校验签名；只为读自己令牌里的权限） */
function jwtClaims(jwt) {
  try {
    const part = jwt.split('.')[1];
    return JSON.parse(Buffer.from(part, 'base64url').toString('utf8'));
  } catch (e) { return {}; }
}

/** 本次令牌实际拿到的权限 */
function grantedScopes(tok) {
  tok = tok || loadToken() || {};
  if (tok.access_token) {
    const c = jwtClaims(tok.access_token);
    if (c.scp) return Array.from(new Set(c.scp.split(/\s+/))).sort();
  }
  return Array.from(new Set((tok.scope || '').split(/\s+/).filter(Boolean))).sort();
}

/** 按已获权限判断各数据源是否可用 —— 缺权限的直接跳过，不去撞 403 */
function capabilities(tok) {
  const g = new Set(grantedScopes(tok));
  return {
    mail: ['Mail.Read', 'Mail.ReadBasic', 'Mail.ReadWrite'].some(s => g.has(s)),
    calendar: g.has('Calendars.Read') || g.has('Calendars.ReadWrite'),
    todo: g.has('Tasks.Read') || g.has('Tasks.ReadWrite'),
    // Planner 需要 Group.Read.All（管理员专属），学生账号基本拿不到
    planner: g.has('Group.Read.All') || g.has('Group.ReadWrite.All'),
    chat: g.has('Chat.Read') || g.has('Chat.ReadWrite'),
    account: g.has('User.Read')
  };
}

function authState() {
  const tok = loadToken();
  if (!tok) {
    return { loggedIn: false, client: '', granted: [], missing: REQUIRED,
             expired: false, lastError: lastLogin.error || '' };
  }
  const g = grantedScopes(tok);
  const hit = CLIENT_CHAIN.find(c => c.id === tok.client_id);
  return {
    loggedIn: true,
    client: hit ? hit.label : (tok.client_id || ''),
    granted: g,
    missing: REQUIRED.filter(s => !g.includes(s)),
    expired: (tok.expires_at || 0) <= Math.floor(Date.now() / 1000),
    lastError: lastLogin.error || ''
  };
}

/* ==========================================================================
   登录
   ========================================================================== */

let loginState = { on: false, message: '' };

function loginStatus() { return { on: loginState.on, message: loginState.message }; }

/** 把微软的报错翻译成人话（判断该不该继续换下一条通道） */
function kindOf(error, desc) {
  const blob = ((error || '') + ' ' + (desc || '')).toUpperCase();
  if (blob.includes('AADSTS65001') || blob.includes('AADSTS500011')) return ['need_admin', '这个客户端需要管理员批准'];
  if (blob.includes('AADSTS65004')) return ['declined', '授权未获同意（或你点了取消）'];
  if (blob.includes('AADSTS65002')) return ['not_preauth', '该权限组合未被此客户端预授权'];
  if (blob.includes('AADSTS70011')) return ['bad_scope', '权限参数不被接受'];
  if (blob.includes('AADSTS700016')) return ['no_app', '租户中没有这个客户端'];
  if (blob.includes('AADSTS50058')) return ['no_session', '需要重新登录'];
  if (blob.includes('AADSTS53003') || blob.includes('AADSTS53000')) return ['ca_blocked', '被学校条件访问策略拦截'];
  if (error === 'access_denied') return ['declined', '授权未获同意（或你点了取消）'];
  return ['other', String(desc || '').split('\n')[0].slice(0, 200) || '未知错误'];
}

/** 浏览器授权：一次调用 = 一次尝试（指定客户端与权限集） */
function webLogin(opts = {}) {
  const clientId = opts.clientId || CLIENT_CHAIN[0].id;
  const scopes = opts.scopes || SCOPES;
  const label = opts.label || (CLIENT_CHAIN.find(c => c.id === clientId) || {}).label || clientId;
  const first = !!opts.first;
  const timeoutMs = opts.timeoutMs || 90000;
  return new Promise((resolve) => {
    let redirectUri = '';
    const state = crypto.randomBytes(16).toString('hex');
    const verifier = crypto.randomBytes(48).toString('base64url');
    const challenge = crypto.createHash('sha256').update(verifier).digest('base64url');

    const server = http.createServer((req, res) => {
      let q;
      try { q = new URL(req.url, 'http://127.0.0.1').searchParams; } catch (e) { q = null; }
      if (!q || (!q.get('code') && !q.get('error'))) {
        res.writeHead(204); res.end(); return;
      }
      const ok = !!q.get('code');
      const html = pageHtml(ok, q.get('error_description') || q.get('error') || '');
      res.writeHead(200, { 'Content-Type': 'text/html; charset=utf-8' });
      res.end(html);
      done({ code: q.get('code'), error: q.get('error'),
             desc: q.get('error_description'), state: q.get('state') });
    });

    let settled = false;
    function done(payload) {
      if (settled) return;
      settled = true;
      try { server.close(); } catch (e) { /* 已关 */ }
      finish(payload);
    }

    async function finish(payload) {
      loginState = { on: false, message: '' };
      if (payload && payload.error) {
        const [kind, why] = kindOf(payload.error, payload.desc);
        return resolve({ ok: false, kind, error: why, client: label });
      }
      if (!payload) return resolve({ ok: false, kind: 'timeout', error: '等待授权超时', client: label });
      if (payload.state !== state) return resolve({ ok: false, kind: 'other', error: 'state 校验不通过', client: label });
      const t = await postForm(AUTHORITY + '/oauth2/v2.0/token', {
        grant_type: 'authorization_code',
        client_id: clientId,
        code: payload.code,
        redirect_uri: redirectUri,
        code_verifier: verifier,
        scope: scopes.join(' ')
      });
      if (!t.access_token) {
        const [kind, why] = kindOf(t.error, t.error_description);
        return resolve({ ok: false, kind, error: why, client: label });
      }
      storeToken(t, clientId, scopes.join(' '));
      resolve({ ok: true, client: label });
    }

    server.listen(0, '127.0.0.1', async () => {
      const port = server.address().port;
      redirectUri = 'http://localhost:' + port + '/callback';
      const params = {
        client_id: clientId,
        response_type: 'code',
        redirect_uri: redirectUri,
        response_mode: 'query',
        scope: scopes.join(' '),
        state,
        code_challenge: challenge,
        code_challenge_method: 'S256'
      };
      // 第一次让用户挑账号；之后复用浏览器里已有会话，不再重复打断
      if (first) params.prompt = 'select_account';
      const authUrl = AUTHORITY + '/oauth2/v2.0/authorize?' + new URLSearchParams(params).toString();

      loginState = { on: true, message: '已打开浏览器（' + label + '），请在页面里选择学校账号登录' };
      lastAuthUrl = authUrl;
      try {
        const { shell } = require('electron');
        await shell.openExternal(authUrl);
      } catch (e) { /* 打不开就靠前端把链接显示给用户 */ }

      setTimeout(() => done(null), timeoutMs);
    });
  });
}

let lastAuthUrl = '';

/**
 * 通道链：依次尝试候选客户端，第一条走通的就收工。
 * onProgress(msg) 每步回调一次，方便界面显示进度。
 */
async function loginChain(opts = {}) {
  const onProgress = opts.onProgress || (() => {});
  const attempts = [];
  for (const c of CLIENT_CHAIN) {
    attempts.push({ label: c.label, clientId: c.id, scopes: SCOPES, tag: '标准权限' });
    if (c.allowDefault) {
      attempts.push({ label: c.label, clientId: c.id,
                      scopes: [GRAPH_DEFAULT, 'openid', 'profile', 'offline_access'],
                      tag: '预授权权限' });
    }
  }
  const list = attempts.slice(0, 5);
  lastLogin = { error: '', kind: '', client: '' };

  for (let i = 0; i < list.length; i++) {
    const a = list[i];
    onProgress('正在通过「' + a.label + '」连接微软（' + (i + 1) + '/' + list.length + '，' + a.tag + '）…');
    const r = await webLogin({
      clientId: a.clientId, scopes: a.scopes, label: a.label,
      first: i === 0, timeoutMs: opts.timeoutMs || 90000
    });
    if (r.ok) {
      lastLogin = { error: '', kind: '', client: a.label };
      onProgress('已连上微软账号（' + a.label + '）');
      return r;
    }
    lastLogin = { error: r.error || '登录未完成', kind: r.kind || '', client: a.label };
    if (r.kind === 'timeout') {
      onProgress('等待超时，已停止尝试。');
      return { ok: false, error: '等待授权超时（没有人完成登录）', kind: 'timeout' };
    }
    onProgress('「' + a.label + '」没走通（' + (r.error || '') + '），换下一条通道…');
  }
  lastLogin.error = '学校租户不允许学生自行授权，需要 IT 管理员批准后才能连接。';
  onProgress('全部通道都被挡住了：需要学校管理员批准。');
  return { ok: false, error: lastLogin.error, kind: 'need_admin' };
}

function pageHtml(ok, detail) {
  return '<!doctype html><meta charset="utf-8"><title>' + (ok ? '登录成功' : '登录未完成') + '</title>'
    + '<style>html,body{height:100%;margin:0}body{display:grid;place-items:center;background:#f5f5f7;'
    + 'font:16px/1.6 "Segoe UI","Microsoft YaHei",sans-serif;color:#1d1d1f}'
    + '.c{background:#fff;border-radius:18px;padding:40px 52px;text-align:center;max-width:560px;'
    + 'box-shadow:0 12px 40px rgba(0,0,0,.10)}.t{font-size:40px;line-height:1;margin-bottom:14px}'
    + 'h1{font-size:20px;margin:0 0 6px}p{margin:0;color:#6e6e73;font-size:14px;word-break:break-all}'
    + '</style><div class="c"><div class="t">' + (ok ? '&#10003;' : '&#9888;') + '</div>'
    + '<h1>' + (ok ? '登录成功' : '登录未完成') + '</h1>'
    + '<p>' + (ok ? '已连上 ManageBac-Buddy，这个窗口可以关掉了。' : detail) + '</p></div>';
}

async function deviceLogin(onCode) {
  const clientId = CLIENT_CHAIN[0].id;
  const r = await postForm(AUTHORITY + '/oauth2/v2.0/devicecode', {
    client_id: clientId, scope: SCOPES.join(' ')
  });
  if (!r.device_code) return { ok: false, error: r.error_description || 'devicecode_failed' };
  if (onCode) onCode({ url: r.verification_uri, code: r.user_code });

  const interval = (r.interval || 5) * 1000;
  const deadline = Date.now() + (r.expires_in || 900) * 1000;
  while (Date.now() < deadline) {
    await sleep(interval);
    const t = await postForm(AUTHORITY + '/oauth2/v2.0/token', {
      grant_type: 'urn:ietf:params:oauth:grant-type:device_code',
      client_id: clientId, device_code: r.device_code
    });
    if (t.access_token) { storeToken(t, clientId, SCOPES.join(' ')); return { ok: true }; }
    if (t.error === 'authorization_pending') continue;
    if (t.error === 'slow_down') continue;
    const [, why] = kindOf(t.error, t.error_description);
    lastLogin = { error: why, kind: kindOf(t.error, t.error_description)[0], client: CLIENT_CHAIN[0].label };
    return { ok: false, error: why };
  }
  return { ok: false, error: 'expired' };
}

const sleep = ms => new Promise(r => setTimeout(r, ms));

async function getToken() {
  const tok = loadToken();
  if (!tok) return null;
  if (tok.expires_at > Math.floor(Date.now() / 1000) && tok.access_token) return tok.access_token;
  if (!tok.refresh_token) return null;
  const clientId = tok.client_id || CLIENT_CHAIN[0].id;
  const t = await postForm(AUTHORITY + '/oauth2/v2.0/token', {
    grant_type: 'refresh_token', client_id: clientId,
    refresh_token: tok.refresh_token, scope: tok.req_scope || SCOPES.join(' ')
  });
  if (t.access_token) { storeToken(t, clientId, tok.req_scope); return t.access_token; }
  // 续期失败（改密码 / 被吊销）：清掉，交给界面提示重新连接
  try { clearToken(); } catch (e) { /* 本来就没了 */ }
  return null;
}

/* ==========================================================================
   Graph
   ========================================================================== */

async function graph(pathOrUrl, token) {
  token = token || await getToken();
  if (!token) return { __error: 'not_authenticated' };
  const url = pathOrUrl.startsWith('http')
    ? pathOrUrl : 'https://graph.microsoft.com/v1.0' + pathOrUrl;
  let r = await request(url, { headers: { Authorization: 'Bearer ' + token } });
  if (r.__http === 401) {
    const t2 = await getToken();
    if (t2 && t2 !== token) {
      r = await request(url, { headers: { Authorization: 'Bearer ' + t2 } });
    }
  }
  return r;
}

async function graphPaged(pathOrUrl, limit = 200) {
  const out = [];
  let url = pathOrUrl.startsWith('http')
    ? pathOrUrl : 'https://graph.microsoft.com/v1.0' + pathOrUrl;
  let token = await getToken();
  if (!token) return out;
  while (url && out.length < limit) {
    const r = await request(url, { headers: { Authorization: 'Bearer ' + token } });
    if (r.__http === 401) {
      token = await getToken();
      if (!token) break;
      continue;
    }
    (r.value || []).forEach(v => out.push(v));
    url = r['@odata.nextLink'];
  }
  return out.slice(0, limit);
}

/* ==========================================================================
   识别引擎（与 Python 端逐条对齐）
   ========================================================================== */

function re(pattern, flags) {
  try { return new RegExp(pattern, flags || 'i'); } catch (e) { return null; }
}

function score(text, table) {
  let total = 0;
  const hits = [];
  for (const [pat, w] of table) {
    if (!w) continue;
    const r = re(pat);
    if (r && r.test(text)) { total += w; hits.push(pat); }
  }
  return [total, hits];
}

function stripHtml(s) {
  if (!s) return '';
  return String(s)
    .replace(/<(script|style)[^>]*>[\s\S]*?<\/\1>/gi, ' ')
    .replace(/<br\s*\/?>/gi, '\n')
    .replace(/<\/(p|div|tr|li|h[1-6])>/gi, '\n')
    .replace(/<[^>]+>/g, ' ')
    .replace(/&nbsp;/g, ' ').replace(/&amp;/g, '&').replace(/&lt;/g, '<')
    .replace(/&gt;/g, '>').replace(/&quot;/g, '"').replace(/&#39;/g, "'")
    .replace(/[ \t\u00a0]+/g, ' ')
    .replace(/\n{3,}/g, '\n\n')
    .trim();
}

function confidence(score, lo, hi, base, span) {
  if (score <= base) return Math.round(lo * 100) / 100;
  const v = lo + (score - base) / span * (hi - lo);
  return Math.round(Math.max(lo, Math.min(hi, v)) * 100) / 100;
}

/* ---- 日期解析 ---- */

const WD_CN = { '一': 1, '二': 2, '三': 3, '四': 4, '五': 5, '六': 6, '日': 0, '天': 0 };
const WD_EN = { monday: 1, tuesday: 2, wednesday: 3, thursday: 4, friday: 5, saturday: 6, sunday: 0,
                mon: 1, tue: 2, wed: 3, thu: 4, fri: 5, sat: 6, sun: 0 };
const MON_EN = { jan: 1, feb: 2, mar: 3, apr: 4, may: 5, jun: 6, jul: 7,
                 aug: 8, sep: 9, sept: 9, oct: 10, nov: 11, dec: 12 };

function mk(y, mo, d) {
  const dt = new Date(y, mo - 1, d, 23, 59, 0, 0);
  if (dt.getFullYear() !== y || dt.getMonth() !== mo - 1 || dt.getDate() !== d) return null;
  return dt;
}

function parseDue(text, now) {
  now = now || new Date();
  if (!text) return [null, null];
  const t = ' ' + text + ' ';

  const today0 = new Date(now.getFullYear(), now.getMonth(), now.getDate());
  const future = dt => (dt && dt.getTime() >= today0.getTime() - 86400000) ? dt : null;

  let m;

  // ① 中文绝对日期：9月25日
  for (const g of t.matchAll(/(\d{1,2})\s*月\s*(\d{1,2})\s*[日号]/g)) {
    const mo = +g[1], d = +g[2];
    let dt = mk(now.getFullYear(), mo, d);
    if (dt && dt.getTime() < today0.getTime() - 180 * 86400000) dt = mk(now.getFullYear() + 1, mo, d);
    if (!dt) dt = mk(now.getFullYear() + 1, mo, d);
    if (future(dt)) return [dt.getTime(), g[0]];
  }

  // ② 英文月名：Sep 25
  for (const g of t.matchAll(/\b([A-Za-z]{3,9})\.?\s+(\d{1,2})(?:st|nd|rd|th)?\b/g)) {
    const key = g[1].toLowerCase();
    const mo = MON_EN[key.slice(0, 4)] || MON_EN[key.slice(0, 3)];
    if (!mo) continue;
    const dt = future(mk(now.getFullYear(), mo, +g[2])) || mk(now.getFullYear() + 1, mo, +g[2]);
    if (future(dt)) return [dt.getTime(), g[0]];
  }

  // ③ 数字日期
  for (const g of t.matchAll(/\b(\d{4})[-/.](\d{1,2})[-/.](\d{1,2})\b/g)) {
    const dt = mk(+g[1], +g[2], +g[3]);
    if (future(dt)) return [dt.getTime(), g[0]];
  }
  for (const g of t.matchAll(/\b(\d{1,2})\/(\d{1,2})\b/g)) {
    let dt = mk(now.getFullYear(), +g[1], +g[2]);
    if (!future(dt)) dt = mk(now.getFullYear() + 1, +g[1], +g[2]);
    if (future(dt)) return [dt.getTime(), g[0]];
  }

  // ④ 星期（必须排在「下周」之前，否则「下周一」会被吃成「下周」的周五）
  m = t.match(/(下?)(?:周|週|星期|礼拜|禮拜)([一二三四五六日天])/);
  if (m) {
    const next = m[1] === '下';
    const wd = WD_CN[m[2]];
    let days = (wd - now.getDay() + 7) % 7;
    if (next) days += 7;
    else if (days === 0) days = 7;
    const dt = new Date(now.getFullYear(), now.getMonth(), now.getDate() + days, 23, 59);
    return [dt.getTime(), m[0]];
  }
  m = t.match(/\b(next\s+)?(monday|tuesday|wednesday|thursday|friday|saturday|sunday|mon|tue|wed|thu|fri|sat|sun)\b/i);
  if (m) {
    let days = (WD_EN[m[2].toLowerCase()] - now.getDay() + 7) % 7;
    if (days === 0) days = 7;
    const dt = new Date(now.getFullYear(), now.getMonth(), now.getDate() + days, 23, 59);
    return [dt.getTime(), m[0]];
  }

  // ⑤ 相对日
  const rel = [[/大后天/, 3], [/后天|後天/, 2], [/\bday after tomorrow\b/i, 2],
               [/明天|明日|\btomorrow\b/i, 1], [/今天|今日|\btoday\b/i, 0]];
  for (const [r, off] of rel) {
    const g = t.match(r);
    if (g) {
      const dt = new Date(now.getFullYear(), now.getMonth(), now.getDate() + off, 23, 59);
      return [dt.getTime(), g[0]];
    }
  }

  m = t.match(/\bthis week\b|本周|这周|這周/i);
  if (m) {
    let days = (5 - now.getDay() + 7) % 7;
    let dt = new Date(now.getFullYear(), now.getMonth(), now.getDate() + days, 23, 59);
    if (dt.getTime() < now.getTime()) dt = new Date(dt.getTime() + 7 * 86400000);
    return [dt.getTime(), m[0]];
  }
  m = t.match(/\bnext week\b|下周|下週/i);
  if (m) {
    const days = ((5 - now.getDay() + 7) % 7) + 7;
    const dt = new Date(now.getFullYear(), now.getMonth(), now.getDate() + days, 23, 59);
    return [dt.getTime(), m[0]];
  }

  return [null, null];
}

/* ---- 标题与学科 ---- */

function cleanSubject(sub) {
  let s = String(sub || '').trim();
  const lead = re(RULES.leadNoise);
  let prev = null;
  while (prev !== s) { prev = s; s = s.replace(lead, '').trim(); }
  return s || '(无主题)';
}

function makeTitle(subject, body) {
  const s = cleanSubject(subject);
  // 注意：JS 的 \W 只认 ASCII，中文会被当成「非单词字符」，
  // 所以这里必须用 Unicode 属性类判断「是否含有字母或数字」。
  if (s.length >= 4 && /[\p{L}\p{N}]/u.test(s)) return s.slice(0, 70);
  const b = stripHtml(body);
  for (const line of b.split('\n')) {
    const t = line.trim();
    if (t.length >= 6 && t.length <= 70 && !/^(hi|hello|dear|各位|大家好|尊敬)/i.test(t)) {
      return t.slice(0, 70);
    }
  }
  return s.slice(0, 70);
}

function guessCourse(text) {
  for (const [name, pat] of RULES.courseTable) {
    const r = re(pat);
    if (r && r.test(text)) return name;
  }
  return '';
}

/* ---- 邮件 → 任务 ---- */

function mailToTask(msg, now) {
  now = now || new Date();
  const W = RULES.weights;
  const subject = msg.subject || '';
  const preview = msg.bodyPreview || '';
  const body = (msg.body && msg.body.content) ? stripHtml(msg.body.content) : '';
  const blob = [subject, subject, preview, body.slice(0, 2500)].join(' ');

  const [odd] = score(blob, RULES.action);
  const [dld] = score(blob, RULES.deadline);
  const [acd] = score(blob, RULES.academic);
  const [nd] = score(blob, RULES.noise);

  let s = 0;
  const signals = [];
  if (odd > 0) { s += odd * W.action; signals.push('行动要求'); }
  if (acd > 0) { s += acd * W.academic; signals.push('学习/活动'); }
  if (dld > 0) { s += dld * W.deadline; signals.push('截止时间'); }
  if (nd < 0) { s += nd; signals.push('疑似通知'); }

  const imp = String(msg.importance || '').toLowerCase();
  if (imp === 'high') { s += W.highImportance; signals.push('邮件标记重要'); }
  if (msg.flag && msg.flag.flagStatus === 'flagged') { s += W.flagged; signals.push('已加旗标'); }
  if (msg.isRead === false) s += W.unread;

  if (acd > 0 && (odd > 0 || dld > 0)) { s += W.bothBonus; signals.push('学务要求'); }

  if (s < W.mailThreshold) return null;

  const [dueMs, dueTxt] = parseDue(blob, now);
  const from = (msg.from && msg.from.emailAddress)
    ? (msg.from.emailAddress.name || msg.from.emailAddress.address || '') : '';
  let createdMs = null;
  if (msg.receivedDateTime) {
    const d = new Date(msg.receivedDateTime);
    if (!isNaN(d)) createdMs = d.getTime();
  }

  return {
    id: 'mail:' + (msg.id || Math.random().toString(36).slice(2)),
    source: 'mail',
    title: makeTitle(subject, body || preview),
    course: guessCourse(makeTitle(subject, body || preview) + ' ' + blob.slice(0, 600)),
    detail: preview.slice(0, 220),
    dueMs, dueText: dueTxt || '', createdMs,
    importance: imp === 'high' ? 'high' : 'normal',
    status: 'notStarted',
    from, webUrl: msg.webLink || '',
    confidence: confidence(s, W.confLo, W.confHi, W.confBase, W.confSpan),
    signals,
    isRead: !!msg.isRead
  };
}

/* ---- 聊天 → 任务 ---- */

function chatToTask(m, now) {
  now = now || new Date();
  const W = RULES.weights;
  const body = stripHtml((m.body && m.body.content) || '');
  if (!body || body.length < 8) return null;
  const noise = re(RULES.chatNoise);
  if (noise && noise.test(body.trim())) return null;

  const mentions = m.mentions || [];
  const addressed = mentions.length > 0 || /@|你|您|同学|同學/.test(body);

  const [odd] = score(body, RULES.action);
  const [dld] = score(body, RULES.deadline);
  const [acd] = score(body, RULES.academic);
  let s = odd * W.chatAction + dld * W.chatDeadline + acd * W.chatAcademic;
  if (addressed) s += W.chatAddressed;
  if (s < W.chatThreshold) return null;

  const [dueMs, dueTxt] = parseDue(body, now);
  let from = '';
  try {
    if (m.from && m.from.user && m.from.user.displayName) from = m.from.user.displayName;
  } catch (e) { /* 无发件人信息 */ }

  let createdMs = null;
  if (m.createdDateTime) {
    const d = new Date(m.createdDateTime);
    if (!isNaN(d)) createdMs = d.getTime();
  }

  const sig = [];
  if (odd) sig.push('行动要求');
  if (acd) sig.push('学习/活动');
  if (dld) sig.push('截止时间');
  if (addressed) sig.push('点名提到你');

  return {
    id: 'chat:' + (m.id || Math.random().toString(36).slice(2)),
    source: 'chat',
    title: body.trim().split('\n')[0].slice(0, 70),
    course: guessCourse(body.slice(0, 400)),
    detail: body.slice(0, 220),
    dueMs, dueText: dueTxt || '', createdMs,
    importance: 'normal', status: 'notStarted',
    from, webUrl: 'https://teams.microsoft.com',
    confidence: confidence(s, W.chatConfLo, W.chatConfHi, W.chatBase || W.confBase, W.chatConfSpan),
    signals: sig
  };
}

/* ==========================================================================
   取数
   ========================================================================== */

async function fetchTodo(limit = 60) {
  const out = [];
  const lists = await graphPaged('/me/todo/lists?$top=50', 20);
  for (const lst of lists) {
    if (!lst.id) continue;
    const lname = lst.displayName || '任务';
    const tasks = await graphPaged('/me/todo/lists/' + lst.id + '/tasks?$top=100', limit);
    for (const t of tasks) {
      if ((t.status || '') === 'completed') continue;
      let dueMs = null;
      if (t.dueDateTime && t.dueDateTime.dateTime) {
        const d = new Date(t.dueDateTime.dateTime);
        if (!isNaN(d)) dueMs = d.getTime();
      }
      const title = (t.title || '').trim() || '(无标题)';
      out.push({
        id: 'todo:' + t.id, source: 'todo', title,
        course: guessCourse(lname + ' ' + title),
        detail: stripHtml((t.body && t.body.content) || '').slice(0, 220),
        dueMs, dueText: '', createdMs: null,
        importance: (t.importance || '') === 'high' ? 'high' : 'normal',
        status: t.status || 'notStarted', from: lname, webUrl: '',
        confidence: 1, signals: ['微软任务']
      });
    }
  }
  return out;
}

async function fetchPlanner(limit = 60) {
  const out = [];
  const tasks = await graphPaged('/me/planner/tasks?$top=100', limit);
  if (!tasks.length) return out;
  const plans = {};
  for (const t of tasks) {
    if (t.planId && !(t.planId in plans)) {
      const p = await graph('/planner/plans/' + t.planId);
      plans[t.planId] = p.title || '';
    }
  }
  for (const t of tasks) {
    if (t.percentComplete === 100) continue;
    let dueMs = null;
    if (t.dueDateTime) {
      const d = new Date(t.dueDateTime);
      if (!isNaN(d)) dueMs = d.getTime();
    }
    const pname = plans[t.planId] || '';
    const title = (t.title || '').trim() || '(无标题)';
    out.push({
      id: 'planner:' + t.id, source: 'planner', title,
      course: guessCourse(pname + ' ' + title),
      detail: '', dueMs, dueText: '', createdMs: null,
      importance: (t.priority || 5) <= 3 ? 'high' : 'normal',
      status: 'notStarted', from: pname, webUrl: '',
      confidence: 1, signals: ['Planner 任务']
    });
  }
  return out;
}

async function fetchMail(top = 60, days = 21) {
  const since = new Date(Date.now() - days * 86400000).toISOString().replace(/\.\d+Z$/, 'Z');
  const sel = 'id,subject,bodyPreview,body,from,receivedDateTime,isRead,importance,flag,webLink,hasAttachments';
  const q = '/me/mailFolders/inbox/messages?$top=' + top
    + '&$select=' + sel
    + '&$filter=receivedDateTime ge ' + since
    + '&$orderby=receivedDateTime desc';
  return graphPaged(q, top);
}

async function fetchChats(limit = 40) {
  const out = [];
  const chats = await graphPaged('/me/chats?$top=30&$expand=members', 30);
  for (const c of chats.slice(0, 12)) {
    if (!c.id) continue;
    const msgs = await graphPaged('/me/chats/' + c.id + '/messages?$top=25', 25);
    for (const m of msgs) {
      out.push(m);
      if (out.length >= limit) return out;
    }
  }
  return out;
}

async function fetchCalendar(days = 14) {
  const t0 = new Date().toISOString();
  const t1 = new Date(Date.now() + days * 86400000).toISOString();
  const q = '/me/calendarView?startDateTime=' + t0 + '&endDateTime=' + t1 + '&$top=100'
    + '&$select=id,subject,start,end,location,organizer,webLink,isAllDay,bodyPreview'
    + '&$orderby=start/dateTime';
  return graphPaged(q, 100);
}

/* ==========================================================================
   汇总
   ========================================================================== */

async function buildSection(opts = {}) {
  const now = new Date();
  const token = await getToken();
  if (!token) {
    return { connected: false, reason: 'not_authenticated', tasks: [], mail: [],
             events: [], stats: {}, asOf: Date.now() };
  }

  // 按实际拿到的权限决定拉哪些源：缺权限的直接跳过，不去撞 403
  const caps = capabilities();

  let tasks = [];
  const taskSrcs = [];
  if (caps.todo) taskSrcs.push(fetchTodo);
  // Planner 需要 Group.Read.All（管理员专属），拿不到就不试
  if (caps.planner) taskSrcs.push(fetchPlanner);
  for (const fn of taskSrcs) {
    try { tasks = tasks.concat(await fn()); }
    catch (e) { /* 单个来源失败不影响其他来源 */ }
  }

  let mails = [], mailTasks = [], chatTasks = [], events = [];
  if (opts.includeMail !== false && caps.mail) {
    try {
      mails = await fetchMail();
      for (const m of mails) {
        const t = mailToTask(m, now);
        if (t) mailTasks.push(t);
      }
    } catch (e) { /* 同上 */ }
  }
  if (opts.includeChat !== false && caps.chat) {
    try {
      for (const m of await fetchChats()) {
        const t = chatToTask(m, now);
        if (t) chatTasks.push(t);
      }
    } catch (e) { /* 同上 */ }
  }
  if (opts.includeCalendar !== false && caps.calendar) {
    try {
      for (const e of await fetchCalendar()) {
        if (e.isAllDay) continue;
        const st = e.start && e.start.dateTime;
        if (!st) continue;
        const en = e.end && e.end.dateTime;
        const toMs = x => { const d = new Date(x); return isNaN(d) ? null : d.getTime(); };
        events.push({
          id: 'cal:' + e.id,
          title: (e.subject || '').trim() || '(无标题)',
          startMs: toMs(st), endMs: en ? toMs(en) : null,
          location: (e.location && e.location.displayName) || '',
          organizer: (e.organizer && e.organizer.emailAddress && e.organizer.emailAddress.name) || '',
          webUrl: e.webLink || ''
        });
      }
    } catch (e) { /* 同上 */ }
  }

  // 去重：同一件事既在邮件里又在聊天里，合并成一条
  const all = tasks.concat(mailTasks, chatTasks);
  const seen = {};
  const uniq = [];
  for (const t of all) {
    // 同上：不能用 \W，否则中文标题会被清空、去重直接失效
    const key = (t.title || '').toLowerCase()
      .replace(/[\s\p{P}\p{S}]+/gu, '').slice(0, 24);
    if (key && seen[key]) {
      const keep = seen[key];
      if (!keep.dueMs && t.dueMs) { keep.dueMs = t.dueMs; keep.dueText = t.dueText; }
      keep.alsoFrom = (keep.alsoFrom || []).concat(t.source);
      continue;
    }
    if (key) seen[key] = t;
    uniq.push(t);
  }
  uniq.sort((a, b) => {
    const ax = a.dueMs == null, bx = b.dueMs == null;
    if (ax !== bx) return ax ? 1 : -1;
    return (a.dueMs || 0) - (b.dueMs || 0);
  });

  const d0 = new Date(now.getFullYear(), now.getMonth(), now.getDate());
  const endToday = d0.getTime() + 86400000;
  const endWeek = d0.getTime() + 7 * 86400000;
  const nowMs = now.getTime();

  const stats = {
    total: uniq.length,
    overdue: uniq.filter(t => t.dueMs && t.dueMs < nowMs).length,
    today: uniq.filter(t => t.dueMs && t.dueMs >= nowMs && t.dueMs < endToday).length,
    week: uniq.filter(t => t.dueMs && t.dueMs >= endToday && t.dueMs < endWeek).length,
    noDue: uniq.filter(t => !t.dueMs).length,
    fromMail: mailTasks.length,
    fromChat: chatTasks.length,
    unreadMail: mails.filter(m => m.isRead === false).length,
    events: events.length
  };

  let account = '';
  if (caps.account) {
    try {
      const me = await graph('/me?$select=displayName,userPrincipalName');
      account = me.userPrincipalName || me.displayName || '';
    } catch (e) { /* 拿不到就算了，界面不显示账号而已 */ }
  }

  return {
    connected: true, account, caps, granted: grantedScopes(), asOf: Date.now(),
    stats, tasks: uniq, events,
    mail: mails.map(m => ({
      id: m.id,
      subject: cleanSubject(m.subject),
      from: (m.from && m.from.emailAddress && m.from.emailAddress.name) || '',
      receivedMs: m.receivedDateTime ? new Date(m.receivedDateTime).getTime() : null,
      isRead: !!m.isRead,
      importance: m.importance || 'normal',
      hasAttachments: !!m.hasAttachments,
      webUrl: m.webLink || '',
      preview: (m.bodyPreview || '').slice(0, 160)
    }))
  };
}

module.exports = {
  init, loginStatus, webLogin, loginChain, deviceLogin, clearToken, loadToken,
  authState, capabilities, grantedScopes, kindOf, getLoginUrl: () => lastAuthUrl,
  buildSection, mailToTask, chatToTask, parseDue, cleanSubject, guessCourse
};
