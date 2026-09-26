#!/usr/bin/env node
'use strict'
/*
 * ManageBac-Buddy —— 云端中转（relay）
 * ---------------------------------------------------------------
 * 为什么需要它：
 *   数据的唯一来源是「跑在 Mac 上的桥接服务」（登录态 + 无界面浏览器都在那边）。
 *   手表和 Mac 不在同一个网络时（Mac 在家 / 在包里，手表在学校 WiFi），
 *   局域网直连必然失败，所以需要一台公网可达的机器中转一下：
 *
 *     Mac（抓取）──POST /api/push──▶  本服务  ◀──GET /api/snapshot── 手表
 *
 * 设计要点：
 *   ① 接口形状**刻意与 Mac 上的 bridge.py 完全一致**（/api/ping、/api/snapshot、
 *      /api/refresh），这样手表端只需要多一个候选地址，不需要任何分支逻辑；
 *   ② 只存**最近一份**快照（几十 KB），落一个 JSON 文件，重启不丢；
 *   ③ 全部走 token 校验（query `?token=` 或头 `X-MB-Token`）；
 *   ④ 不做任何抓取 —— 它自己不连 ManageBac，只保管 Mac 推上来的东西。
 *      所以「Mac 最后在线时间」会一起返回，手表据此说清数据到底有多旧。
 */

const http = require('http')
const fs = require('fs')
const path = require('path')
const crypto = require('crypto')

const HERE = __dirname
const PORT = parseInt(process.env.PORT || '3000', 10)
const DATA_DIR = process.env.MB_DATA_DIR || path.join(HERE, 'data')
const DATA_FILE = path.join(DATA_DIR, 'snapshot.json')
const CFG_FILE = path.join(HERE, 'config.json')

function loadConfig() {
  try { return JSON.parse(fs.readFileSync(CFG_FILE, 'utf8')) } catch (e) { return {} }
}
const CFG = loadConfig()
const TOKEN = String(process.env.MB_RELAY_TOKEN || CFG.token || '').trim()
const MAX_BODY = 2 * 1024 * 1024          // 2 MB，正常快照只有几十 KB
const API_VERSION = 2                      // 与 bridge.py 的 VERSION 对齐

const S = {
  snap: null,        // 最近一次收到的完整快照（对象）
  pushedAt: 0,       // 最后一次**收到推送**的时刻（= Mac 最后在线）
  fetchedAt: 0,      // 数据实际被 Mac 抓到的时刻
  pushes: 0,
  bytes: 0,
  startedAt: now(),
}

function now() { return Date.now() / 1000 }

function log(...a) {
  console.log(new Date().toISOString().slice(11, 19), ...a)
}

/* ---------------- 落盘 / 读盘 ---------------- */

function loadFromDisk() {
  try {
    const d = JSON.parse(fs.readFileSync(DATA_FILE, 'utf8'))
    if (d && d.snapshot && typeof d.snapshot === 'object') {
      S.snap = d.snapshot
      S.pushedAt = Number(d.pushedAt) || 0
      S.fetchedAt = Number(d.fetchedAt) || 0
      log(`已载入上次快照：${(S.snap.tasks || []).length} 条待办，推送于 ${ageText(S.pushedAt)}`)
    }
  } catch (e) { /* 首次启动没有文件，正常 */ }
}

function saveToDisk() {
  try {
    fs.mkdirSync(DATA_DIR, { recursive: true })
    const tmp = DATA_FILE + '.tmp'
    fs.writeFileSync(tmp, JSON.stringify({
      pushedAt: S.pushedAt, fetchedAt: S.fetchedAt, snapshot: S.snap,
    }))
    fs.renameSync(tmp, DATA_FILE)
  } catch (e) {
    log('落盘失败：' + e.message)
  }
}

function ageText(t) {
  if (!t) return '从未'
  const s = Math.max(0, Math.round(now() - t))
  if (s < 90) return s + ' 秒前'
  if (s < 5400) return Math.round(s / 60) + ' 分钟前'
  if (s < 172800) return (s / 3600).toFixed(1) + ' 小时前'
  return Math.round(s / 86400) + ' 天前'
}

/* ---------------- 小工具 ---------------- */

function send(res, code, obj, type) {
  const body = typeof obj === 'string' ? obj : JSON.stringify(obj)
  res.writeHead(code, {
    'Content-Type': type || 'application/json; charset=utf-8',
    'Cache-Control': 'no-store',
    'Access-Control-Allow-Origin': '*',
    'Access-Control-Allow-Headers': 'Content-Type, X-MB-Token',
  })
  res.end(body)
}

function tokenOf(req, u) {
  const h = req.headers['x-mb-token']
  if (h) return String(h).trim()
  const q = u.searchParams.get('token')
  return q ? q.trim() : ''
}

function tokenOK(got) {
  if (!TOKEN) return false                      // 没配 token 就一律拒绝，别裸奔
  const a = Buffer.from(got)
  const b = Buffer.from(TOKEN)
  if (a.length !== b.length) return false
  try { return crypto.timingSafeEqual(a, b) } catch (e) { return false }
}

/* 与 bridge.py 的 ping_payload() 形状对齐 */
function pingPayload() {
  const t = now()
  return {
    ok: true, mb: API_VERSION, v: 1, service: 'mbboard-relay', via: 'relay',
    port: PORT, host: 'relay',
    hasData: !!S.snap,
    age: S.snap ? round1(Math.max(0, t - (S.fetchedAt || S.pushedAt))) : -1,
    refreshing: false,
    loggedIn: S.snap ? S.snap.loggedIn : undefined,
    macSeenAt: S.pushedAt,
    macAgo: S.pushedAt ? round1(Math.max(0, t - S.pushedAt)) : -1,
    serverTime: round3(t),
  }
}

/* 与 bridge.py 的 snapshot() 形状对齐 */
function snapshotPayload() {
  const t = now()
  const base = {
    ok: true, hasData: false, age: -1, stale: true, updating: false,
    tasks: [], serverTime: round3(t), v: API_VERSION, via: 'relay',
    macSeenAt: S.pushedAt,
    pushedAt: S.pushedAt,
  }
  if (!S.snap) return base
  const out = Object.assign({}, S.snap)
  // 用**数据被抓到的时刻**算年龄：这才是手表上「数据 X 分钟前」的正解。
  // （pushedAt 只是「Mac 最后一次联系我们」，两者要分开说。）
  const ref = S.fetchedAt || S.pushedAt
  out.age = round1(Math.max(0, t - ref))
  out.hasData = true
  out.stale = out.age > 900
  out.updating = false
  out.serverTime = round3(t)
  out.v = API_VERSION
  out.via = 'relay'
  out.macSeenAt = S.pushedAt
  out.pushedAt = S.pushedAt
  return out
}

function round1(x) { return Math.round(x * 10) / 10 }
function round3(x) { return Math.round(x * 1000) / 1000 }

/* ---------------- 状态页（不需要 token，也不暴露成绩） ---------------- */

const PAGE = `<!DOCTYPE html><html lang="zh-CN"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>ManageBac-Buddy · 云端中转</title>
<style>
 :root{color-scheme:light dark}
 body{margin:0;font:15px/1.7 -apple-system,"PingFang SC",system-ui,sans-serif;
      background:#f5f5f7;color:#1d1d1f;display:flex;justify-content:center;padding:48px 20px}
 .card{background:#fff;border-radius:18px;padding:28px 30px;max-width:560px;width:100%;
       box-shadow:0 1px 3px rgba(0,0,0,.08),0 12px 32px rgba(0,0,0,.06)}
 h1{margin:0 0 4px;font-size:19px;letter-spacing:.2px}
 .sub{color:#86868b;font-size:13px;margin-bottom:22px}
 table{width:100%;border-collapse:collapse;font-size:14px}
 td{padding:9px 0;border-bottom:1px solid #f0f0f2;vertical-align:top}
 td:first-child{color:#86868b;width:42%}
 td:last-child{font-variant-numeric:tabular-nums}
 .dot{display:inline-block;width:8px;height:8px;border-radius:50%;margin-right:7px}
 .ok{background:#34c759}.warn{background:#ff9f0a}.bad{background:#ff3b30}
 .foot{margin-top:22px;color:#86868b;font-size:12px}
 @media (prefers-color-scheme:dark){body{background:#000;color:#f5f5f7}
   .card{background:#1c1c1e}td{border-color:#2c2c2e}}
</style></head><body><div class="card">
<h1>ManageBac-Buddy · 云端中转</h1>
<div class="sub">Mac 推上来的最新一份数据就存在这里，手表在任何网络下都能取到。</div>
<table id="t"></table>
<div class="foot">本页不显示任何成绩 / 待办内容，只报状态。</div>
</div><script>
function fb(s){const n=Math.round(s);if(n<90)return n+" 秒前";
 if(n<5400)return Math.round(n/60)+" 分钟前";
 if(n<172800)return (n/3600).toFixed(1)+" 小时前";return Math.round(n/86400)+" 天前"}
async function tick(){
  try{
    const r=await fetch("api/status",{cache:"no-store"});const d=await r.json();
    const cls=d.freshness==="ok"?"ok":(d.freshness==="warn"?"warn":"bad");
    document.getElementById("t").innerHTML=
     "<tr><td>数据</td><td><span class='dot "+cls+"'></span>"+
       (d.hasData?("有，"+fb(d.age)+"抓的"):"暂无")+"</td></tr>"+
     "<tr><td>电脑最后在线</td><td>"+(d.macSeenAt?fb(d.macAgo):"从未")+"</td></tr>"+
     "<tr><td>内容</td><td>"+d.tasks+" 条待办 · "+d.classes+" 门课 · "+d.recent+" 项成绩</td></tr>"+
     "<tr><td>收到推送</td><td>"+d.pushes+" 次 · "+d.bytes+" KB</td></tr>"+
     "<tr><td>服务运行</td><td>"+fb(d.uptime)+"</td></tr>";
  }catch(e){document.getElementById("t").innerHTML="<tr><td>状态</td><td>读取失败</td></tr>"}
}
tick();setInterval(tick,5000);
</script></body></html>`

/* ---------------- 路由 ---------------- */

const server = http.createServer((req, res) => {
  const u = new URL(req.url, 'http://x')
  const p = u.pathname.replace(/\/+$/, '') || '/'

  if (req.method === 'OPTIONS') return send(res, 204, {})
  if (p === '/' ) return send(res, 200, PAGE, 'text/html; charset=utf-8')
  if (p === '/api/health') return send(res, 200, { ok: true, service: 'mbboard-relay' })

  // 状态页专用：不带 token，但也**不含任何内容字段**
  if (p === '/api/status') {
    const t = now()
    const age = S.snap ? Math.max(0, t - (S.fetchedAt || S.pushedAt)) : -1
    return send(res, 200, {
      ok: true, hasData: !!S.snap, age: round1(age),
      freshness: !S.snap ? 'bad' : (age < 900 ? 'ok' : (age < 6 * 3600 ? 'warn' : 'bad')),
      macSeenAt: S.pushedAt, macAgo: S.pushedAt ? round1(Math.max(0, t - S.pushedAt)) : -1,
      tasks: (S.snap && (S.snap.tasks || []).length) || 0,
      classes: (S.snap && (S.snap.classes || []).length) || 0,
      recent: (S.snap && (S.snap.recent || []).length) || 0,
      pushes: S.pushes, bytes: Math.round(S.bytes / 1024),
      uptime: round1(t - S.startedAt),
    })
  }

  // ---- 下面全部要 token ----
  if (p.startsWith('/api/')) {
    const bad = tokenOK(tokenOf(req, u))
    if (p === '/api/push') {
      if (req.method !== 'POST') return send(res, 405, { ok: false, error: 'method' })
      if (!bad) return send(res, 401, { ok: false, error: 'bad_token' })
      return readBody(req, res, (raw) => {
        let d
        try { d = JSON.parse(raw.toString('utf8')) } catch (e) {
          return send(res, 400, { ok: false, error: 'bad_json' })
        }
        if (!d || typeof d !== 'object' || !Array.isArray(d.tasks)) {
          return send(res, 400, { ok: false, error: 'bad_payload' })
        }
        S.snap = d
        S.pushedAt = now()
        S.fetchedAt = Number(d.fetchedAt) || S.pushedAt
        S.pushes++
        S.bytes = raw.length
        saveToDisk()
        log(`收到推送：${d.tasks.length} 条待办，${Math.round(raw.length / 1024)} KB，` +
            `loggedIn=${d.loggedIn}`)
        return send(res, 200, { ok: true, pushedAt: S.pushedAt, tasks: d.tasks.length })
      })
    }
    if (!bad) return send(res, 401, { ok: false, error: 'bad_token' })
    if (p === '/api/ping') return send(res, 200, pingPayload())
    if (p === '/api/snapshot') return send(res, 200, snapshotPayload())
    if (p === '/api/refresh') {
      // 中转自己不抓数据，所以这里是空操作 —— 告诉手表别等。
      return send(res, 200, {
        ok: true, started: false, reason: 'relay',
        age: S.snap ? round1(Math.max(0, now() - (S.fetchedAt || S.pushedAt))) : -1,
      })
    }
    return send(res, 404, { ok: false, error: 'not_found' })
  }

  return send(res, 404, { ok: false, error: 'not_found' })
})

function readBody(req, res, cb) {
  const chunks = []
  let n = 0
  req.on('data', (c) => {
    n += c.length
    if (n > MAX_BODY) { req.destroy(); return send(res, 413, { ok: false, error: 'too_large' }) }
    chunks.push(c)
  })
  req.on('end', () => cb(Buffer.concat(chunks)))
  req.on('error', () => send(res, 400, { ok: false, error: 'read_error' }))
}

loadFromDisk()
server.listen(PORT, '0.0.0.0', () => {
  log(`云端中转已启动：0.0.0.0:${PORT}`)
  log(`token: ${TOKEN ? '已配置（' + TOKEN.length + ' 位）' : '⚠️ 未配置 —— 所有接口会返回 401'}`)
  log(`数据文件：${DATA_FILE}`)
})
