'use strict';
/* ======================================================================
   设置（Windows 端）
   与 Mac 版 **同一份 schema**：~/.mbboard/settings.json ↔ %APPDATA%/…/settings.json
   两端字段名完全一致，所以同一套自定义在两边行为相同。
   ====================================================================== */

const fs = require('fs');
const path = require('path');
const { app, safeStorage } = require('electron');

const DEFAULTS = {
  v: 1,
  theme: 'system',            // system | light | dark
  density: 'comfortable',     // compact | comfortable | spacious
  corner: 'regular',          // sharp | regular | round
  glassStrength: 1.0,
  fontScale: 1.0,
  reduceMotion: false,
  reduceTransparency: false,
  accentHex: '#0071e3',
  subjectPresetID: 'morandi',
  subjectColors: {
    chinese: '#a96f6b', math: '#867a9e', ela: '#b58455', chem: '#6f7c9e',
    phys: '#719070', bio: '#5b918a', geo: '#74889c', ids: '#94836f'
  },
  urgentHours: 26,
  soonHours: 50,
  blueHours: 74,
  hiddenKeywords: '背诵视频',
  countOverdue: false,
  refreshMinutes: 5,
  launchAtLogin: false,
  showRed: true,
  showYellow: true,
  showBlue: true,
  labelStyle: 'dots',         // dots | counts | plain
  panelWidth: 470,
  wakeTime: '06:00',
  nightStart: '18:30',
  nightEnd: '22:30',
  dashboardSection: 'todo',
  showFooterHints: true,
  taskLimit: 0
};

const PRESETS = {
  morandi: {
    chinese: '#a96f6b', math: '#867a9e', ela: '#b58455', chem: '#6f7c9e',
    phys: '#719070', bio: '#5b918a', geo: '#74889c', ids: '#94836f'
  },
  vivid: {
    chinese: '#e8556d', math: '#7b61ff', ela: '#f0932b', chem: '#5468ff',
    phys: '#2ecc71', bio: '#12b8a6', geo: '#3d9be9', ids: '#c56cf0'
  },
  deep: {
    chinese: '#8d5a57', math: '#5f5878', ela: '#8a6440', chem: '#4f5c7e',
    phys: '#526b52', bio: '#416d68', geo: '#566676', ids: '#6f6255'
  }
};

class Settings {
  constructor() {
    this.file = path.join(app.getPath('userData'), 'settings.json');
    this.credsFile = path.join(app.getPath('userData'), 'credentials.bin');
    this.data = Object.assign({}, DEFAULTS);
    this.load();
  }

  load() {
    try {
      const raw = JSON.parse(fs.readFileSync(this.file, 'utf8'));
      this.data = Object.assign({}, DEFAULTS, raw);
      if (!this.data.subjectColors || !Object.keys(this.data.subjectColors).length) {
        this.data.subjectColors = Object.assign({}, DEFAULTS.subjectColors);
      }
    } catch (_) { /* 首次运行：用默认值 */ }
    this.normalize();
  }

  save() {
    try {
      fs.mkdirSync(path.dirname(this.file), { recursive: true });
      fs.writeFileSync(this.file, JSON.stringify(this.data, null, 2), 'utf8');
    } catch (_) { /* 忽略写失败 */ }
  }

  get all() { return this.data; }

  patch(partial) {
    Object.assign(this.data, partial || {});
    this.normalize();
    this.save();
    return this.data;
  }

  reset() {
    const keep = this.data.launchAtLogin;
    this.data = Object.assign({}, DEFAULTS, { launchAtLogin: keep });
    this.save();
    return this.data;
  }

  applyPreset(id) {
    if (!PRESETS[id]) return this.data;
    this.data.subjectPresetID = id;
    this.data.subjectColors = Object.assign({}, PRESETS[id]);
    this.save();
    return this.data;
  }

  /* 阈值必须严格递增，否则分档会塌掉 */
  normalize() {
    const d = this.data;
    d.urgentHours = Math.max(1, Math.min(200, Number(d.urgentHours) || 26));
    d.soonHours = Math.max(d.urgentHours + 1, Math.min(400, Number(d.soonHours) || 50));
    d.blueHours = Math.max(d.soonHours + 1, Math.min(800, Number(d.blueHours) || 74));
    d.glassStrength = Math.max(0, Math.min(1, Number(d.glassStrength)));
    d.fontScale = Math.max(0.85, Math.min(1.25, Number(d.fontScale) || 1));
    d.refreshMinutes = Math.max(1, Math.min(120, Number(d.refreshMinutes) || 5));
    d.taskLimit = Math.max(0, Math.min(200, Number(d.taskLimit) || 0));
    d.panelWidth = Math.max(380, Math.min(720, Number(d.panelWidth) || 470));
  }

  hiddenList() {
    return String(this.data.hiddenKeywords || '')
      .split(/[\n,，]/).map(s => s.trim()).filter(Boolean);
  }

  /* ---------------- 登录凭据：Windows 上用 DPAPI 加密后落盘 ---------------- */

  saveCreds(login, password) {
    try {
      if (!safeStorage.isEncryptionAvailable()) return false;
      const blob = safeStorage.encryptString(JSON.stringify({ login, password }));
      fs.mkdirSync(path.dirname(this.credsFile), { recursive: true });
      fs.writeFileSync(this.credsFile, blob);
      return true;
    } catch (_) { return false; }
  }

  readCreds() {
    try {
      if (!fs.existsSync(this.credsFile)) return null;
      const blob = fs.readFileSync(this.credsFile);
      const txt = safeStorage.decryptString(blob);
      const o = JSON.parse(txt);
      if (o && o.login && o.password) return o;
    } catch (_) { /* 换机器/换用户后解不开，按没有处理 */ }
    return null;
  }

  hasCreds() { return fs.existsSync(this.credsFile); }

  forgetCreds() {
    try { fs.unlinkSync(this.credsFile); } catch (_) {}
  }
}

module.exports = { Settings, DEFAULTS, PRESETS };
