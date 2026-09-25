'use strict';
/* ======================================================================
   数据引擎（Windows 端 · 独立抓取）

   与 Mac 版的 bridge.py 等价，但完全不依赖 Python / 外部 Chrome：
   直接用一个隐藏的 Electron 窗口（自带 Chromium）去登录并抓取 ManageBac，
   解析脚本与 Mac 版用的是同一个 scrape.js，所以两边的数据结构一模一样。

   Cookie 由 Electron 的 persist 分区自己持久化，关掉再开仍然登着。
   ====================================================================== */

const { BrowserWindow, session } = require('electron');
const fs = require('fs');
const path = require('path');

// 学校 ManageBac 地址：本校默认值，换学校的人改这一行即可（Mac 版可在
// 「设置 → 账号管理」里改，不必碰代码）。
const BASE = 'https://beijing101.managebac.cn';
const LOGIN_URL = BASE + '/login';
const HOME_URL = BASE + '/student/tasks_and_deadlines';
const LOGOUT_URL = BASE + '/logout';
const PARTITION = 'persist:managebac';

const STATUS_JS = `JSON.stringify({
  url: location.href,
  title: document.title,
  hasLogin: !!document.querySelector('#session_login'),
  user: (function(){
    var m = document.body.innerText.match(/Welcome,\\s*([^!\\n]{1,40})!/);
    return m ? m[1].trim() : '';
  })()
})`;

const COOKIE_JS = `(function(){
  var bs = Array.from(document.querySelectorAll('button'));
  var b = bs.find(function(x){ return /Accept Only Necessary/i.test(x.innerText||''); })
       || bs.find(function(x){ return /Allow All/i.test(x.innerText||''); });
  if (b) { b.click(); return 'dismissed'; }
  return 'none';
})()`;

function sleep(ms) { return new Promise(r => setTimeout(r, ms)); }

class Engine {
  constructor(settings) {
    this.settings = settings;
    this.win = null;
    this.cacheFile = path.join(require('electron').app.getPath('userData'), 'cache.json');
    this.cache = null;
    this.cacheTs = 0;
    this.lastFetch = { at: 0, ok: null, reason: '', detail: '' };
    this.busy = false;
    this.sessionDead = false;
    this.sessionNote = '';
    this.since = 0;
    this.autoTried = 0;
    this.CACHE_TTL = 60 * 1000;
    this.loadCache();
  }

  /* ---------------- 缓存 ---------------- */

  loadCache() {
    try {
      const d = JSON.parse(fs.readFileSync(this.cacheFile, 'utf8'));
      if (d && d.ok) { this.cache = d; this.cacheTs = d.__cachedAt || 0; }
    } catch (_) {}
  }

  saveCache(d) {
    try {
      const out = Object.assign({}, d, { __cachedAt: Date.now() });
      fs.writeFileSync(this.cacheFile, JSON.stringify(out), 'utf8');
    } catch (_) {}
  }

  dropCache() {
    this.cache = null; this.cacheTs = 0;
    try { fs.unlinkSync(this.cacheFile); } catch (_) {}
  }

  /* ---------------- 隐藏窗口 ---------------- */

  async ensureWindow(force) {
    if (this.win && !this.win.isDestroyed() && !force) return this.win;
    if (this.win && !this.win.isDestroyed()) {
      try { this.win.destroy(); } catch (_) {}
    }
    this.win = new BrowserWindow({
      show: false,
      width: 1280,
      height: 900,
      webPreferences: {
        partition: PARTITION,
        nodeIntegration: false,
        contextIsolation: true,
        backgroundThrottling: false,
        images: false      // 不加载图片，抓数据快得多
      }
    });
    this.win.on('closed', () => { this.win = null; });
    return this.win;
  }

  async js(code, timeout = 180000) {
    const w = await this.ensureWindow();
    return Promise.race([
      w.webContents.executeJavaScript(code, true),
      new Promise((_, rej) => setTimeout(() => rej(new Error('TIMEOUT')), timeout))
    ]);
  }

  async open(url, timeout = 120000) {
    const w = await this.ensureWindow();
    await Promise.race([
      w.loadURL(url),
      new Promise((_, rej) => setTimeout(() => rej(new Error('LOAD_TIMEOUT')), timeout))
    ]);
    await sleep(1200);
  }

  async status() {
    try {
      const raw = await this.js(STATUS_JS, 30000);
      const d = JSON.parse(raw || '{}');
      const url = d.url || '';
      const logged = !d.hasLogin && !url.includes('/login') && url.includes('/student/');
      return { loggedIn: !!logged, url, user: d.user || '' };
    } catch (e) {
      return { loggedIn: false, url: '', user: '', error: String(e.message || e) };
    }
  }

  /* ---------------- 登录 ---------------- */

  async login(login, password, remember = true) {
    try {
      await this.open(LOGIN_URL);
      await sleep(1200);
      await this.js(COOKIE_JS, 20000).catch(() => {});

      const payload = JSON.stringify({ l: login, p: password, r: !!remember });
      const code = `(function(){
        var C = ${payload};
        var u = document.querySelector('#session_login');
        var p = document.querySelector('#session_password');
        if (!u || !p) return 'NOFORM';
        var d = Object.getOwnPropertyDescriptor(window.HTMLInputElement.prototype, 'value').set;
        function set(el, v) {
          d.call(el, v);
          el.dispatchEvent(new Event('input', { bubbles: true }));
          el.dispatchEvent(new Event('change', { bubbles: true }));
        }
        set(u, C.l); set(p, C.p);
        var rm = document.querySelector('#session_remember_me');
        if (rm) rm.checked = !!C.r;
        var b = document.querySelector('input[name=commit]') || document.querySelector('button[type=submit]');
        if (b) b.click(); else document.querySelector('form').submit();
        return 'SUBMITTED';
      })()`;

      const r = await this.js(code, 60000);
      if (String(r).indexOf('SUBMITTED') < 0) {
        return { ok: false, msg: '没能提交登录表单（页面结构可能变了）' };
      }

      for (let i = 0; i < 14; i++) {
        await sleep(2000);
        const st = await this.status();
        if (st.loggedIn) {
          this.sessionDead = false;
          this.dropCache();
          return { ok: true, msg: '登录成功', user: st.user };
        }
      }
      return { ok: false, msg: '登录未成功：账号或密码可能有误，或需要额外验证' };
    } catch (e) {
      return { ok: false, msg: '登录出错：' + String(e.message || e) };
    }
  }

  /* 打开一个可见窗口让用户自己登录（有验证码/二次验证时走这条路） */
  openLoginWindow() {
    const w = new BrowserWindow({
      width: 1080, height: 780, title: '登录 ManageBac',
      autoHideMenuBar: true,
      webPreferences: { partition: PARTITION, nodeIntegration: false, contextIsolation: true }
    });
    w.loadURL(LOGIN_URL);
    return w;
  }

  async logout() {
    try { await this.open(LOGOUT_URL); } catch (_) {}
    this.dropCache();
    this.sessionDead = true;
    this.since = Date.now();
    return { ok: true };
  }

  /* ---------------- 抓取 ---------------- */

  async fetchOnce() {
    const scrape = fs.readFileSync(path.join(__dirname, 'scrape.js'), 'utf8');

    await this.open(HOME_URL);

    let st = await this.status();
    if (!st.loggedIn) {
      const ok = await this.tryAutoLogin();
      if (ok) {
        await this.open(HOME_URL);
        st = await this.status();
      }
      if (!st.loggedIn) {
        this.sessionDead = true;
        if (!this.since) this.since = Date.now();
        this.lastFetch = { at: Date.now(), ok: false, reason: 'logged_out', detail: '' };
        return {
          ok: true, loggedIn: false, tasks: [], sessionExpired: true,
          sessionSince: this.since ? Math.round((Date.now() - this.since) / 1000) : 0,
          sessionNote: this.sessionNote, hasCreds: this.settings.hasCreds(),
          fetchedAt: Date.now() / 1000
        };
      }
    }
    this.sessionDead = false;
    this.since = 0;

    const raw = await this.js(scrape, 300000);
    let d = raw;
    if (typeof d === 'string') {
      try { d = JSON.parse(d); } catch (_) { d = null; }
    }
    if (!d || typeof d !== 'object') {
      this.lastFetch = { at: Date.now(), ok: false, reason: 'parse_error', detail: String(raw).slice(0, 200) };
      return { ok: false, loggedIn: true, reason: 'parse_error', detail: String(raw).slice(0, 200) };
    }
    if (!d.ok && d.reason === 'logged_out') {
      this.sessionDead = true;
      this.lastFetch = { at: Date.now(), ok: false, reason: 'logged_out', detail: '' };
      return {
        ok: true, loggedIn: false, tasks: [], sessionExpired: true,
        sessionSince: 0, sessionNote: this.sessionNote, hasCreds: this.settings.hasCreds(),
        fetchedAt: Date.now() / 1000
      };
    }

    d.loggedIn = true;
    d.user = st.user || '';
    d.fetchedAt = Date.now() / 1000;
    d.stale = false;
    d.updating = false;
    d.hasCreds = this.settings.hasCreds();

    this.cache = d;
    this.cacheTs = Date.now();
    this.saveCache(d);
    this.lastFetch = { at: Date.now(), ok: true, reason: '', detail: '' };
    return d;
  }

  async tryAutoLogin() {
    if (Date.now() - this.autoTried < 15 * 60 * 1000) return false;
    this.autoTried = Date.now();
    const c = this.settings.readCreds();
    if (!c) { this.sessionNote = ''; return false; }
    const r = await this.login(c.login, c.password, true);
    this.sessionNote = r.ok ? '已自动重新登录' : ('自动重登失败：' + r.msg);
    return !!r.ok;
  }

  /* 对外统一入口：有新鲜缓存直接给；过期先给旧的、后台更新 */
  async get(force = false) {
    const age = this.cache ? (Date.now() - this.cacheTs) : Infinity;

    if (!force && this.cache && age < this.CACHE_TTL) return this.withMeta(this.cache);

    if (!force && this.cache) {
      if (this.sessionDead) return this.withMeta(this.cache, { stale: true, updating: false, loggedIn: false });
      this.refreshInBackground();
      return this.withMeta(this.cache, { stale: true, updating: true });
    }

    if (this.busy) {
      // 已经有人在抓了：先把手上的给出，或者等它
      if (this.cache) return this.withMeta(this.cache, { stale: true, updating: true });
    }

    this.busy = true;
    try {
      const got = await this.fetchOnce();
      if (got && got.loggedIn === false && this.cache) {
        return this.withMeta(this.cache, { stale: true, loggedIn: false, sessionExpired: true });
      }
      return this.withMeta(got);
    } catch (e) {
      this.lastFetch = { at: Date.now(), ok: false, reason: 'error', detail: String(e.message || e) };
      if (this.cache) return this.withMeta(this.cache, { stale: true, updating: false });
      return { ok: false, error: String(e.message || e), loggedIn: false, tasks: [] };
    } finally {
      this.busy = false;
    }
  }

  refreshInBackground() {
    if (this.busy) return;
    this.busy = true;
    this.fetchOnce()
      .catch(() => {})
      .finally(() => { this.busy = false; if (this.onUpdate) this.onUpdate(); });
  }

  withMeta(d, over) {
    if (!d) return d;
    const out = Object.assign({}, d);
    out.updating = false;
    out.stale = false;
    out.hasCreds = this.settings.hasCreds();
    if (this.sessionDead) {
      out.loggedIn = false;
      out.sessionExpired = true;
      out.sessionNote = this.sessionNote;
      out.sessionSince = this.since ? Math.round((Date.now() - this.since) / 1000) : 0;
    }
    return Object.assign(out, over || {});
  }

  snapshot() {
    if (!this.cache) return null;
    return this.withMeta(this.cache, this.sessionDead
      ? { stale: true, loggedIn: false, sessionExpired: true }
      : {});
  }

  dispose() {
    if (this.win && !this.win.isDestroyed()) { try { this.win.destroy(); } catch (_) {} }
    this.win = null;
  }
}

module.exports = { Engine, BASE, HOME_URL, LOGIN_URL, PARTITION };
