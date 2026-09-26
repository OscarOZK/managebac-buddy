'use strict';
/* ======================================================================
   ManageBac-Buddy · Windows 桌面应用
   主进程：托盘（= Windows 上的「菜单栏」）+ 一个原生窗口 + 独立抓取引擎。
   点开即用：双击 exe → 托盘出现图标；点托盘图标或桌面窗口都能用。
   ====================================================================== */

const { app, BrowserWindow, Tray, Menu, ipcMain, shell, nativeImage } = require('electron');
const path = require('path');
const fs = require('fs');

const { Settings } = require('./src/settings');
const { Engine, BASE } = require('./src/engine');
const { TrayBadge } = require('./src/tray');
const Teams = require('./src/teams');

const isWin = process.platform === 'win32';
const isMac = process.platform === 'darwin';

let settings = null;
let engine = null;
let tray = null;
let badge = null;
let win = null;
let refreshTimer = null;
let tickTimer = null;
let lastBadgeKey = '';

/* ---------------- 单实例 ---------------- */
if (!app.requestSingleInstanceLock()) {
  app.quit();
} else {
  app.on('second-instance', () => { showWindow(); });
}

/* ---------------- 窗口 ---------------- */

/* 窗口尺寸：不写死。Windows 笔记本常见 1366×768 / 1280×720，
   直接用 1280×860 会超出屏幕；这里按屏幕可用区域自适应，并记住上次的大小与位置。 */
function winBoundsFile() { return path.join(app.getPath('userData'), 'window.json'); }

function readWinBounds() {
  try { return JSON.parse(fs.readFileSync(winBoundsFile(), 'utf8')); } catch (_) { return null; }
}
function saveWinBounds(w) {
  try {
    if (!w || w.isDestroyed() || w.isMinimized() || w.isMaximized() || w.isFullScreen()) return;
    fs.writeFileSync(winBoundsFile(), JSON.stringify(w.getBounds()), 'utf8');
  } catch (_) {}
}

function pickWindowSize() {
  let area = { width: 1440, height: 900 };
  try {
    const { screen } = require('electron');
    area = screen.getPrimaryDisplay().workAreaSize;
  } catch (_) {}

  const maxW = Math.max(900, area.width - 60);
  const maxH = Math.max(600, area.height - 80);
  const w = Math.min(1280, maxW);
  const h = Math.min(860, maxH);
  return { width: w, height: h };
}

function createWindow() {
  const saved = readWinBounds();
  const dflt = pickWindowSize();

  const opts = {
    width: (saved && saved.width) || dflt.width,
    height: (saved && saved.height) || dflt.height,
    minWidth: Math.min(1020, dflt.width),
    minHeight: Math.min(660, dflt.height),
    show: false,
    title: 'ManageBac-Buddy',
    autoHideMenuBar: true,
    backgroundColor: '#00000000',
    webPreferences: {
      preload: path.join(__dirname, 'preload.js'),
      contextIsolation: true,
      nodeIntegration: false,
      spellcheck: false
    }
  };
  if (saved && typeof saved.x === 'number' && typeof saved.y === 'number') {
    opts.x = saved.x; opts.y = saved.y;
  }

  if (isWin) {
    // Windows：把原生最小化/最大化/关闭按钮叠在自绘标题栏上（原生窗口控件，位置符合习惯）
    opts.titleBarStyle = 'hidden';
    opts.titleBarOverlay = { color: '#00000000', symbolColor: '#86868b', height: 40 };
    opts.backgroundMaterial = 'mica';       // Win11 的原生材质，视觉上对应 Mac 的液态玻璃
    opts.roundedCorners = true;
  } else if (isMac) {
    opts.titleBarStyle = 'hiddenInset';
    opts.trafficLightPosition = { x: 16, y: 20 };
    opts.vibrancy = 'under-window';
    opts.visualEffectState = 'active';
  }

  const w = new BrowserWindow(opts);
  w.loadFile(path.join(__dirname, 'renderer', 'index.html'));

  w.once('ready-to-show', () => { w.show(); });

  let boundsTimer = null;
  const rememberBounds = () => {
    clearTimeout(boundsTimer);
    boundsTimer = setTimeout(() => saveWinBounds(w), 400);
  };
  w.on('resize', rememberBounds);
  w.on('move', rememberBounds);
  w.on('close', () => { clearTimeout(boundsTimer); saveWinBounds(w); });

  // 外部链接一律交给系统浏览器，窗口内不开新页面
  w.webContents.setWindowOpenHandler(({ url }) => {
    if (/^https?:/.test(url)) shell.openExternal(url);
    return { action: 'deny' };
  });
  w.webContents.on('will-navigate', (e, url) => {
    if (!url.startsWith('file://')) { e.preventDefault(); shell.openExternal(url); }
  });

  w.on('closed', () => { win = null; });
  return w;
}

function showWindow() {
  if (!win || win.isDestroyed()) {
    win = createWindow();
    return;
  }
  if (win.isMinimized()) win.restore();
  win.show();
  win.focus();
}

function broadcast() {
  if (win && !win.isDestroyed()) {
    engine.get(false).then(st => {
      if (win && !win.isDestroyed()) win.webContents.send('data:changed', st);
      updateTray(st);
    }).catch(() => {});
  }
}

/* ---------------- 托盘 ---------------- */

function bandCounts(state) {
  const s = settings.all;
  const hidden = settings.hiddenList();
  const list = (state && state.tasks) || [];
  const now = Date.now();
  let red = 0, yellow = 0, blue = 0;
  const urgentMs = s.urgentHours * 3600000;
  const soonMs = s.soonHours * 3600000;
  const blueMs = s.blueHours * 3600000;

  for (const t of list) {
    const title = t.title || '';
    if (hidden.some(k => k && title.includes(k))) continue;
    const due = t.due ? Date.parse(t.due) : null;
    const left = due ? due - now : null;
    const isOver = t.view === 'overdue' || (left !== null && left < 0);
    if (isOver) {
      if (s.countOverdue && s.showRed) red++;
      continue;
    }
    if (left === null) continue;
    if (left <= urgentMs) { if (s.showRed) red++; }
    else if (left <= soonMs) { if (s.showYellow) yellow++; }
    else if (left <= blueMs) { if (s.showBlue) blue++; }
  }
  return { red, yellow, blue };
}

async function updateTray(state) {
  if (!tray) return;
  const s = settings.all;
  const c = bandCounts(state);
  const key = `${c.red}|${c.yellow}|${c.blue}|${s.labelStyle}|${s.accentHex}|${s.showRed}${s.showYellow}${s.showBlue}`;
  if (key !== lastBadgeKey) {
    lastBadgeKey = key;
    const img = await badge.image(s.accentHex, c.red, c.yellow, c.blue, s.labelStyle);
    if (img && !img.isEmpty()) tray.setImage(img);
  }

  const parts = [];
  if (s.showRed && c.red > 0) parts.push(`红 ${c.red} 项`);
  if (s.showYellow && c.yellow > 0) parts.push(`黄 ${c.yellow} 项`);
  if (s.showBlue && c.blue > 0) parts.push(`蓝 ${c.blue} 项`);
  const tip = parts.length ? parts.join(' · ') : '暂无红/黄/蓝待办';
  tray.setToolTip('ManageBac-Buddy\n' + tip);

  // Windows：任务栏按钮上的原生叠加角标
  if (isWin && win && !win.isDestroyed()) {
    const total = c.red + c.yellow + c.blue;
    try {
      if (total > 0) {
        const ov = await badge.overlay(total);
        if (ov) win.setOverlayIcon(ov, `${total} 项待办`);
      } else {
        win.setOverlayIcon(null, '');
      }
    } catch (_) {}
  }
}

function createTray() {
  tray = new Tray(nativeImage.createEmpty());
  tray.setToolTip('ManageBac-Buddy');
  refreshTrayMenu();

  // Windows：双击托盘图标直接开窗口
  tray.on('double-click', () => showWindow());
  tray.on('click', () => { if (!isWin) showWindow(); });

  updateTray(engine.snapshot());
}

function refreshTrayMenu() {
  if (!tray) return;
  const s = settings.all;
  const themeItem = (id, label) => ({
    label, type: 'radio', checked: s.theme === id,
    click: () => { settings.patch({ theme: id }); refreshTrayMenu(); broadcastSettings(); }
  });

  tray.setContextMenu(Menu.buildFromTemplate([
    { label: '打开看板', click: () => showWindow() },
    { label: '立即刷新', click: () => { if (win && !win.isDestroyed()) win.webContents.send('ui:refresh'); else engine.get(true).then(() => updateTray(engine.snapshot())); } },
    { type: 'separator' },
    {
      label: '主题',
      submenu: [
        themeItem('system', '跟随系统'),
        themeItem('light', '浅色'),
        themeItem('dark', '深色')
      ]
    },
    {
      label: '待办分档',
      submenu: [
        { label: `红 ≤ ${s.urgentHours} 小时`, enabled: false },
        { label: `黄 ${s.urgentHours}–${s.soonHours} 小时`, enabled: false },
        { label: `蓝 ${s.soonHours}–${s.blueHours} 小时`, enabled: false },
        { type: 'separator' },
        { label: '在设置页里调整…', click: () => { showWindow(); if (win) win.webContents.send('ui:goto', 'settings'); } }
      ]
    },
    {
      label: '角标样式',
      submenu: ['dots', 'counts', 'plain'].map(v => ({
        label: { dots: '彩色圆点', counts: '数字角标', plain: '仅图标' }[v],
        type: 'radio', checked: s.labelStyle === v,
        click: () => { settings.patch({ labelStyle: v }); refreshTrayMenu(); broadcastSettings(); }
      }))
    },
    { type: 'separator' },
    { label: '在浏览器中打开 ManageBac', click: () => shell.openExternal(BASE) },
    { label: '设置文件所在位置', click: () => shell.showItemInFolder(settings.file) },
    { type: 'separator' },
    { label: '退出', click: () => quitApp() }
  ]));
}

function broadcastSettings() {
  if (win && !win.isDestroyed()) win.webContents.send('settings:changed', settings.all);
  const s = settings.all;
  applyLoginItem(s.launchAtLogin);
  scheduleRefresh();
  lastBadgeKey = '';                     // 强制重画角标
  updateTray(engine.snapshot());
}

/* ---------------- 刷新节律 ---------------- */

function scheduleRefresh() {
  if (refreshTimer) clearInterval(refreshTimer);
  const mins = Math.max(1, Number(settings.all.refreshMinutes) || 5);
  refreshTimer = setInterval(() => {
    if (engine.busy) return;
    engine.get(true).then(st => {
      if (win && !win.isDestroyed()) win.webContents.send('data:changed', st);
      updateTray(st);
    }).catch(() => {});
  }, mins * 60 * 1000);
}

function applyLoginItem(on) {
  try {
    app.setLoginItemSettings({ openAtLogin: !!on, openAsHidden: true, args: ['--hidden'] });
  } catch (_) {}
}

/* ---------------- Teams 板块 ---------------- */

let teamsCache = { data: null, ts: 0, fetching: false, error: null, loggingIn: false, loginMsg: '' };
const TEAMS_TTL = 300000;                 // 五分钟抓一次；Graph 有配额，没必要更勤

function teamsRefresh() {
  if (teamsCache.fetching) return;
  teamsCache.fetching = true;
  Teams.buildSection()
    .then((d) => {
      teamsCache.data = d;
      teamsCache.error = d.connected ? null : 'not_authenticated';
      teamsCache.ts = Date.now();
    })
    .catch((e) => { teamsCache.error = String((e && e.message) || e); })
    .finally(() => { teamsCache.fetching = false; });
}

async function teamsSnapshot() {
  const age = teamsCache.ts ? Date.now() - teamsCache.ts : null;
  if (!teamsCache.fetching && (age === null || age > TEAMS_TTL)) teamsRefresh();
  let auth = { loggedIn: false, client: '', granted: [], missing: [] };
  try { auth = Teams.authState(); } catch (_) { /* 板块失效不该拖垮主程序 */ }
  return {
    loggedIn: !!Teams.loadToken(),
    loggingIn: teamsCache.loggingIn,
    loginMsg: (Teams.loginStatus && Teams.loginStatus().message) || teamsCache.loginMsg || '',
    auth,
    account: (teamsCache.data && teamsCache.data.account) || '',
    fetching: teamsCache.fetching,
    error: teamsCache.error,
    ageSec: age === null ? null : Math.floor(age / 1000),
    section: teamsCache.data
  };
}

/* ---------------- IPC ---------------- */

function registerIpc() {
  try { Teams.init({ userData: app.getPath('userData') }); } catch (_) { /* 板块失效不该拖垮主程序 */ }
  ipcMain.handle('app:bootstrap', async () => ({
    platform: process.platform,
    version: app.getVersion(),
    settings: settings.all,
    state: await engine.get(false),
    teams: await teamsSnapshot(),
    busy: engine.busy,
    lastFetch: engine.lastFetch,
    userData: app.getPath('userData')
  }));

  ipcMain.handle('teams:get', async () => teamsSnapshot());

  ipcMain.handle('teams:refresh', async () => {
    teamsCache.ts = 0;
    teamsRefresh();
    return { ok: true };
  });

  ipcMain.handle('teams:login', async () => {
    if (teamsCache.loggingIn) return { ok: true, already: true };
    teamsCache.loggingIn = true;
    teamsCache.error = null;
    // 依次尝试候选客户端：官方 Graph 客户端不行就退到微软第一方应用
    Teams.loginChain({ onProgress: (msg) => { teamsCache.loginMsg = msg; } })
      .then((r) => { if (!r || !r.ok) teamsCache.error = (r && r.error) || 'login_failed'; })
      .catch((e) => { teamsCache.error = String((e && e.message) || e); })
      .finally(() => { teamsCache.loggingIn = false; teamsCache.ts = 0; teamsRefresh(); });
    return { ok: true, started: true };
  });

  ipcMain.handle('teams:logout', async () => {
    try { Teams.clearToken(); } catch (_) { /* 本来就没有 */ }
    teamsCache = { data: null, ts: 0, fetching: false, error: null, loggingIn: false };
    return { ok: true };
  });

  ipcMain.handle('data:get', async (_e, force) => {
    const st = await engine.get(!!force);
    updateTray(st);
    return { state: st, lastFetch: engine.lastFetch, busy: engine.busy };
  });

  ipcMain.handle('auth:login', async (_e, p) => {
    const r = await engine.login(p.login, p.password, p.remember !== false);
    let saved = false;
    if (r.ok && p.save) saved = settings.saveCreds(p.login, p.password);
    engine.autoTried = Date.now();
    if (r.ok) {
      const st = await engine.get(true);
      if (win && !win.isDestroyed()) win.webContents.send('data:changed', st);
      updateTray(st);
    }
    return Object.assign({}, r, { saved, hasCreds: settings.hasCreds() });
  });

  ipcMain.handle('auth:logout', async () => {
    await engine.logout();
    lastBadgeKey = ''; updateTray(engine.snapshot());
    return { ok: true };
  });

  ipcMain.handle('auth:forget', async () => {
    settings.forgetCreds();
    return { ok: true, hasCreds: false };
  });

  ipcMain.handle('auth:openWindow', async () => { engine.openLoginWindow(); return { ok: true }; });

  ipcMain.handle('settings:set', async (_e, partial) => {
    settings.patch(partial);
    refreshTrayMenu();
    broadcastSettings();
    return settings.all;
  });

  ipcMain.handle('settings:reset', async () => {
    settings.reset();
    refreshTrayMenu();
    broadcastSettings();
    return settings.all;
  });

  ipcMain.handle('settings:preset', async (_e, id) => {
    settings.applyPreset(id);
    broadcastSettings();
    return settings.all;
  });

  ipcMain.handle('shell:open', async (_e, url) => {
    if (/^https?:/.test(url)) shell.openExternal(url);
    return { ok: true };
  });

  ipcMain.handle('shell:reveal', async () => { shell.showItemInFolder(settings.file); return { ok: true }; });

  ipcMain.handle('win:min', () => { if (win) win.minimize(); });
  ipcMain.handle('win:max', () => { if (win) { win.isMaximized() ? win.unmaximize() : win.maximize(); } });
  ipcMain.handle('win:close', () => { if (win) win.close(); });
  ipcMain.handle('app:quit', () => quitApp());
  ipcMain.handle('app:relaunch', () => { app.relaunch(); quitApp(); });
}

function quitApp() {
  try { engine.dispose(); } catch (_) {}
  try { badge.dispose(); } catch (_) {}
  app.isQuitting = true;
  app.quit();
}

/* ---------------- 生命周期 ---------------- */

app.on('window-all-closed', (e) => {
  // 托盘应用：关掉窗口不等于退出
  if (!app.isQuitting) e.preventDefault && e.preventDefault();
});

app.whenReady().then(async () => {
  settings = new Settings();
  engine = new Engine(settings);
  badge = new TrayBadge();

  Menu.setApplicationMenu(null);
  registerIpc();
  createTray();
  win = createWindow();

  applyLoginItem(settings.all.launchAtLogin);
  scheduleRefresh();

  // 首屏数据：先给缓存（秒开），再后台抓新的
  engine.onUpdate = () => {
    if (win && !win.isDestroyed()) win.webContents.send('data:changed', engine.snapshot());
    updateTray(engine.snapshot());
  };
  engine.get(false).then(st => {
    if (win && !win.isDestroyed()) win.webContents.send('data:changed', st);
    updateTray(st);
  }).catch(() => {});

  // 每 30 秒把托盘角标与窗口状态对齐一次（倒计时、剩余时间会走动）
  tickTimer = setInterval(() => {
    const st = engine.snapshot();
    if (st) updateTray(st);
    if (win && !win.isDestroyed()) win.webContents.send('ui:tick', Date.now());
  }, 30000);

  // 首启若未登录，直接把窗口端到用户面前
  setTimeout(async () => {
    const st = engine.snapshot();
    if (!st || st.loggedIn === false) showWindow();
  }, 2500);

  // 开发期自检：MB_CAPTURE=<png路径> 时渲染完把窗口截图落盘后退出（正式运行不受影响）
  //   MB_GOTO=<分区id>  截图前切到某个分区（todo/classes/grades/settings）
  //   MB_SCROLL=<px>    截图前把内容区滚到指定位置
  //   MB_PROBE=<json>   额外导出布局实测数据，用来查溢出/对齐
  if (process.env.MB_CAPTURE) {
    const wait = Number(process.env.MB_CAPTURE_DELAY || 6000);
    setTimeout(async () => {
      try {
        if (win && !win.isDestroyed()) {
          const wc = win.webContents;
          if (process.env.MB_SIZE) {
            const [sw, sh] = String(process.env.MB_SIZE).split('x').map(Number);
            if (sw && sh) { win.setSize(sw, sh); await new Promise(r => setTimeout(r, 1200)); }
          }
          if (process.env.MB_GOTO) {
            const want = process.env.MB_GOTO;
            const got = await wc.executeJavaScript(`(function(){
              var b = document.querySelector('.nav button[data-nav="${want}"]');
              if (!b) return 'NO_BUTTON';
              b.click();
              var cur = document.querySelector('.nav button[aria-current="true"]');
              return cur ? (cur.getAttribute('data-nav') || '?') : 'NONE';
            })()`, true).catch(e => 'ERR ' + String(e.message || e));
            console.log('GOTO', want, '->', got);
            await new Promise(r => setTimeout(r, 1400));
          }
          if (process.env.MB_SCROLL) {
            await wc.executeJavaScript(
              `(function(){var s=document.querySelector('.scroll'); if(s) s.scrollTop=${Number(process.env.MB_SCROLL)}; return true;})()`,
              true).catch(() => {});
            await new Promise(r => setTimeout(r, 700));
          }
          const img = await wc.capturePage();
          fs.writeFileSync(process.env.MB_CAPTURE, img.toPNG());
          console.log('CAPTURED', process.env.MB_CAPTURE);
          if (process.env.MB_PROBE) {
            const probe = await wc.executeJavaScript(`(function(){
              const r = (el) => el ? {w: Math.round(el.getBoundingClientRect().width), l: Math.round(el.getBoundingClientRect().left), r: Math.round(el.getBoundingClientRect().right)} : null;
              const out = { win: { innerW: innerWidth, innerH: innerHeight, docScrollW: document.documentElement.scrollWidth } };
              for (const sel of ['#app','.shell','.side','.main','.head','.scroll','.sections','.grid-tasks','.grid-scores','.upcoming','.week-row','.card','.task','.search','.head .titles','.section-head','.section-head .count','.seg','.slider','.srow']) {
                const el = document.querySelector(sel);
                out[sel] = r(el);
                if (el) out[sel].scrollW = el.scrollWidth;
              }
              const gt = document.querySelector('.grid-tasks');
              if (gt) out.taskCols = getComputedStyle(gt).gridTemplateColumns;
              const gs = document.querySelector('.grid-scores');
              if (gs) out.scoreCols = getComputedStyle(gs).gridTemplateColumns;
              const over = [];
              document.querySelectorAll('#app *').forEach(el => {
                const b = el.getBoundingClientRect();
                if (b.right > innerWidth + 1 || b.left < -1) over.push((el.className||el.tagName)+' @'+Math.round(b.left)+'..'+Math.round(b.right));
              });
              out.overflowing = over.slice(0, 14);
              return JSON.stringify(out, null, 1);
            })()`, true);
            fs.writeFileSync(process.env.MB_PROBE, probe);
            console.log('PROBED', process.env.MB_PROBE);
          }
        }
      } catch (e) { console.log('CAPTURE_FAIL', String(e.message || e)); }
      quitApp();
    }, wait);
  }
});

app.on('before-quit', () => { app.isQuitting = true; });
app.on('activate', () => showWindow());
