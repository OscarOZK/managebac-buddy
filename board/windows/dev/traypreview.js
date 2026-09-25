'use strict';
/* ======================================================================
   托盘角标预览（开发期用）
   把 TrayBadge 画出来的图标落成 PNG（16px），并另存一张 8 倍放大的
   总览图，方便一眼比对三种样式：
       dots   彩色圆点（红/黄/蓝各几项）
       counts 数字角标
       plain  仅图标
   用法：
     env -u ELECTRON_RUN_AS_NODE ./node_modules/.bin/electron dev/traypreview.js
   ====================================================================== */

const { app, BrowserWindow, nativeImage } = require('electron');
const fs = require('fs');
const path = require('path');
const { TrayBadge } = require('../src/tray');

const OUT = process.env.MB_TRAY_OUT || '/tmp/mbwin_tray';
const ACCENT = '#0071e3';

const CASES = [
  ['dots', '红3 黄2 蓝1', 3, 2, 1],
  ['dots', '仅红 1', 1, 0, 0],
  ['dots', '仅蓝 4', 0, 0, 4],
  ['counts', '合计 12', 7, 3, 2],
  ['counts', '合计 3', 2, 1, 0],
  ['plain', '无角标', 0, 0, 0]
];

function sheetHTML(items) {
  const cells = items.map(it => `
    <div class="cell">
      <div class="shot"><img src="${it.url}" alt=""></div>
      <div class="lbl">${it.style}</div>
      <div class="sub">${it.label}</div>
    </div>`).join('');
  return `<!doctype html><meta charset="utf-8"><style>
    body{margin:0;background:#f4f5f8;font:13px/1.4 -apple-system,"PingFang SC","Segoe UI",sans-serif;color:#1d1d1f}
    .wrap{padding:22px 24px 26px}
    h1{margin:0 0 4px;font-size:17px;font-weight:700;letter-spacing:-.02em}
    p{margin:0 0 18px;font-size:12px;color:#6e6e73}
    .row{display:flex;gap:14px;flex-wrap:wrap}
    .cell{background:#fff;border-radius:14px;padding:14px 16px 12px;box-shadow:0 4px 14px -6px rgba(0,0,0,.18);text-align:center;min-width:104px}
    .shot{width:128px;height:128px;display:grid;place-items:center;margin:0 auto 8px;
          background:conic-gradient(from 0deg,#e9ebf0 0 25%,#f6f7fa 0 50%,#e9ebf0 0 75%,#f6f7fa 0);
          background-size:16px 16px;border-radius:10px}
    .shot img{width:128px;height:128px;image-rendering:-webkit-optimize-contrast}
    .lbl{font-weight:700;font-size:13px}
    .sub{font-size:11px;color:#86868b;margin-top:1px}
  </style><div class="wrap">
    <h1>托盘角标 · 16px 放大 8 倍</h1>
    <p>棋盘格背景 = 透明区域；Windows 任务栏与托盘区都是这个尺寸，能看清就够了。</p>
    <div class="row">${cells}</div>
  </div>`;
}

app.whenReady().then(async () => {
  const badge = new TrayBadge();
  fs.mkdirSync(OUT, { recursive: true });

  const items = [];
  for (const [style, label, r, y, b] of CASES) {
    const url = await badge.png(16, ACCENT, r, y, b, style);
    if (!url) { console.log('FAIL', style, label); continue; }
    const buf = Buffer.from(url.split(',')[1], 'base64');
    const img = nativeImage.createFromBuffer(buf);
    const sz = img.getSize();
    const file = path.join(OUT, `${style}_${r}${y}${b}.png`);
    fs.writeFileSync(file, buf);
    console.log(`${file}  ${sz.width}x${sz.height}  ${buf.length}B`);
    items.push({ style, label, url });
  }

  // 8 倍总览图
  const shot = new BrowserWindow({
    width: 900, height: 320, show: false, backgroundColor: '#f4f5f8',
    webPreferences: { contextIsolation: true, nodeIntegration: false }
  });
  await shot.loadURL('data:text/html;charset=utf-8,' + encodeURIComponent(sheetHTML(items)));
  await new Promise(r => setTimeout(r, 600));
  const png = await shot.webContents.capturePage();
  const sheet = path.join(OUT, 'sheet.png');
  fs.writeFileSync(sheet, png.toPNG());
  console.log('SHEET', sheet);

  shot.destroy();
  badge.dispose();
  app.quit();
});
