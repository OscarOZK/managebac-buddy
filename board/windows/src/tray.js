'use strict';
/* ======================================================================
   系统托盘图标（Windows 端的「菜单栏」）
   做法：用一个隐藏窗口里的 <canvas> 画好，再取回 PNG 交给 nativeImage。
   这样红/黄/蓝的彩色角标不会被系统染成单色（和 Mac 端同一套思路）。

   Windows 与 macOS 的差异处理：
     · 托盘小图标按 DPI 缩放，所以同时给 1x(16) 和 2x(32) 两份表示
     · 额外提供「任务栏叠加图标」(setOverlayIcon)，这是 Windows 原生习惯，
       窗口最小化时也能看到红色角标
   ====================================================================== */

const { BrowserWindow, nativeImage } = require('electron');

const PAGE = `<!doctype html><meta charset="utf-8"><body style="margin:0">
<canvas id="c"></canvas>
<script>
function rr(ctx, x, y, w, h, r) {
  ctx.beginPath();
  ctx.moveTo(x + r, y);
  ctx.arcTo(x + w, y, x + w, y + h, r);
  ctx.arcTo(x + w, y + h, x, y + h, r);
  ctx.arcTo(x, y + h, x, y, r);
  ctx.arcTo(x, y, x + w, y, r);
  ctx.closePath();
}
function draw(size, accent, red, yellow, blue, style) {
  var c = document.getElementById('c');
  c.width = size; c.height = size;
  var ctx = c.getContext('2d');
  ctx.clearRect(0, 0, size, size);
  ctx.imageSmoothingEnabled = true;
  var s = size / 16;                       // 以 16pt 为设计基准

  var total = red + yellow + blue;
  var hasBadge = (style !== 'plain') && total > 0;

  // ① 主体：三条圆角横杠（代表看板列表）。有角标时收窄，给右下角腾位置。
  var x0 = 1.8 * s;
  var barH = 2.3 * s, gap = 1.9 * s;
  var widths = hasBadge ? [8.4, 7.4, 6.4] : [11.4, 9.8, 8.2];
  var totalH = 3 * barH + 2 * gap;
  var y0 = (size - totalH) / 2;

  ctx.fillStyle = accent;
  [1.0, 0.78, 0.56].forEach(function (a, i) {
    ctx.globalAlpha = a;
    rr(ctx, x0, y0 + i * (barH + gap), widths[i] * s, barH, barH / 2);
    ctx.fill();
  });
  ctx.globalAlpha = 1;

  if (!hasBadge) return c.toDataURL('image/png');

  if (style === 'counts') {
    // 数字角标。16px 托盘图标里两位数字必然糊成一团，所以只画一位：
    // 1–9 表示合计，超过 9 一律画 9（=「9 或更多」）。精确数字看悬浮提示与托盘菜单。
    var d = 6.9 * s, cx = 12.4 * s, cy = 12.4 * s;
    var txt = total > 9 ? '9' : String(total);
    ctx.beginPath(); ctx.arc(cx, cy, d / 2, 0, Math.PI * 2);
    ctx.fillStyle = '#ff3b30'; ctx.fill();
    ctx.lineWidth = Math.max(1, 1.0 * s); ctx.strokeStyle = '#ffffff'; ctx.stroke();
    var fs = 5.6 * s;
    ctx.font = '700 ' + fs + 'px "Segoe UI", "Helvetica Neue", system-ui, sans-serif';
    ctx.fillStyle = '#fff';
    ctx.textAlign = 'center'; ctx.textBaseline = 'middle';
    ctx.fillText(txt, cx, cy + 0.25 * s);
    return c.toDataURL('image/png');
  }

  // dots：右侧一列红/黄/蓝小圆（一眼看出三档各有几项）
  var dots = [];
  if (red > 0) dots.push('#ff3b30');
  if (yellow > 0) dots.push('#ffcc00');
  if (blue > 0) dots.push('#007aff');
  var r = 2.1 * s, cxx = 13.5 * s;
  var step = 4.3 * s;
  var startY = size / 2 - step * (dots.length - 1) / 2;
  dots.forEach(function (col, i) {
    ctx.beginPath();
    ctx.arc(cxx, startY + i * step, r, 0, Math.PI * 2);
    ctx.fillStyle = col; ctx.fill();
    ctx.lineWidth = Math.max(0.8, 0.9 * s); ctx.strokeStyle = '#fff'; ctx.stroke();
  });
  return c.toDataURL('image/png');
}
</script>
</body>`;

class TrayBadge {
  constructor() {
    this.win = null;
    this.ready = false;
  }

  async ensure() {
    if (this.win && !this.win.isDestroyed()) return;
    this.win = new BrowserWindow({
      show: false,
      width: 64, height: 64,
      webPreferences: { offscreen: false, contextIsolation: true, nodeIntegration: false }
    });
    await this.win.loadURL('data:text/html;charset=utf-8,' + encodeURIComponent(PAGE));
    this.ready = true;
  }

  async png(size, accent, red, yellow, blue, style) {
    try {
      await this.ensure();
      if (!this.win || this.win.isDestroyed()) return null;
      const url = await this.win.webContents.executeJavaScript(
        `draw(${size}, ${JSON.stringify(accent)}, ${red}, ${yellow}, ${blue}, ${JSON.stringify(style)})`,
        true);
      return url;
    } catch (_) {
      return null;
    }
  }

  /** 同时给 1x/2x 两份表示，高 DPI 下不糊 */
  async image(accent, red, yellow, blue, style) {
    const [u1, u2] = await Promise.all([
      this.png(16, accent, red, yellow, blue, style),
      this.png(32, accent, red, yellow, blue, style)
    ]);
    if (!u1) return nativeImage.createEmpty();
    const img = nativeImage.createEmpty();
    try {
      img.addRepresentation({ scaleFactor: 1, buffer: Buffer.from(u1.split(',')[1], 'base64') });
      if (u2) img.addRepresentation({ scaleFactor: 2, buffer: Buffer.from(u2.split(',')[1], 'base64') });
    } catch (_) {}
    return img;
  }

  /** Windows 任务栏叠加图标：小红圈 + 数字 */
  async overlay(count) {
    const url = await this.png(32, '#ffffff', count > 0 ? 1 : 0, 0, 0, 'counts');
    if (!url) return null;
    const img = nativeImage.createFromDataURL(url);
    return img.isEmpty() ? null : img.resize({ width: 16, height: 16 });
  }

  dispose() {
    if (this.win && !this.win.isDestroyed()) { try { this.win.destroy(); } catch (_) {} }
    this.win = null;
  }
}

module.exports = { TrayBadge };
