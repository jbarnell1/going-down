// PF1: do the new resident figures (the v2 files, drawn by default) make the game slower than the old ones
// (`figures=old`)? Measures both, floor by floor, on the exported builds in godot/export/ (run
// `npm run godot:export` first), and prints a table and `N passed, M failed` against the budgets below.
//
// Floors (Places.FIXED and HostRules.WARD_DEPTH): 2 the Clinic (the Orderly), 3 the Annex (the Temp), 4 the
// Playroom (the Minder), 5 the Arboretum (the Groundskeeper), 6 the Hanging Ward (the Rigger). Floor 1 is
// the Clinic too and shows the same Orderly as floor 2.
//
// The browser build (export/web, served here on --port): a fresh headless Chromium for every run, so every
// load is a first visit. `?auto=1&quota=0&floor=N` (HostRules.start_depth_by_arg) starts the run on floor N;
// `figures=old` picks the old figures. Measured: the start screen's first frame after the page is opened
// (the whole download, from this PC, so the network itself costs nothing here), then PLAY ALONE to the first
// frame of the run on that floor (the floor and the resident's figure built); then the player is put 4 to 9 m
// from the resident down a clear line and faced at it (`teleport`, `face`, re-aimed every 300 ms), the worst
// frame of the first 1.5 s it is in view (a first sight: shaders and uploads), then every frame's time for
// --seconds with vsync and the frame cap off (requestAnimationFrame deltas: what the page really costs),
// the engine's own `stats` (process frame time, draw calls, primitives, the renderer's memory) and the
// WebAssembly heap. A run counts only if the resident was drawn and inside the view in at least half the
// samples. The Hanging Ward cannot be started directly in the browser (the floor picker is the Windows
// build's, and `floor=` stops at 5), so floor 6 is measured on the Windows build only.
//
// The Windows build (export/windows/GoingDown.exe), headless (no window: the engine's dummy renderer
// draws nothing, so its frame times are the CPU's share only: rules, animation, scene; no GPU work): the
// same floors (`floor=N`; floor 6 through the floor picker, `ui playtest` then `ui 6`), launch to first
// frame of the run, the same standing spot and facing, `stats` over --seconds, and the process's private
// memory (Get-Process). Headless, the engine waits out every frame to at least 6.9 ms (its low-processor
// sleep), so `avg ms` there only says "under 6.9 ms of work a frame"; `max ms` is the informative number.
//
// Download: the five figures' files inside the web build's index.pck (old against new), each compressed
// with brotli as the hub serves it, and the whole pck.
//
// Budgets (PF1; the owner asked that the new figures be the default; the North Star's "Weak laptops" line
// wants a fixed light budget, no real-time shadows and a low internal resolution; G10 "The look, at a smooth
// frame rate" was passed at 30 and 60 Hz). New against old on the same floor, same seed:
//   frame (browser): mean frame time at most 25% above old, or at most 1 ms above (the smaller numbers on
//     this PC are within noise); long frames (over 33 ms: a missed 30 Hz frame, a felt hitch) per 10 s at most
//     25% above old plus two frames in the window (one long frame comes and goes with either
//     figure; the old Groundskeeper body, 8.3 against 1.7 per 10 s, fails it). The 99th percentile and the
//     slowest single frame are printed, not judged: the same handful of 40 ms frames lands either side of the
//     99th percentile as the frame count changes;
//   first sight (browser): the slowest frame of the first 1.5 s with the resident in view at most 100 ms
//     above old (a hitch players would feel as the resident appears);
//   absolute (browser): the mean with the new figure on screen at or under 33.3 ms (30 frames a second), on
//     this PC;
//   load: PLAY ALONE to the run's first frame at most 3 s above old, browser and Windows; the start screen's
//     first frame at most 3 s above old (browser);
//   CPU (Windows, headless): mean process frame time at most 25% or 1 ms above old;
//   download: the five new figures together at most 18 MB (brotli) more than the five old ones (3 s more on
//     a 50 Mbit/s line).
// Usage: node godot/tools/perf_figures.mjs [--port=4880] [--floors=2,3,4,5,6] [--web=1] [--desktop=1]
//          [--seconds=6] [--ratio=1.25] [--only=new|old] [--gpu=hw|soft] [--runs=3]
//   --runs: browser runs per floor and figure (the table shows each number's median).
//   --ratio: the allowed new/old ratio (1.25). Proof the checks can fail: with the Groundskeeper's unthinned
//     body (groundskeeper_v2.glb at a1e82a4) floor 5 failed the long-frame check, 8.3 against 1.7 per 10 s.
// Ports 4880-4899: the web server on --port, the Windows build's test channel on --port+1. Every process
// and browser it starts is stopped.
import { spawn, execFileSync } from 'node:child_process';
import { createRequire } from 'node:module';
import { existsSync, openSync, readSync, closeSync, statSync, writeFileSync, mkdirSync } from 'node:fs';
import { connect } from 'node:net';
import { brotliCompressSync, constants as zc } from 'node:zlib';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const here = dirname(fileURLToPath(import.meta.url));
const project = resolve(here, '..');
const require = createRequire(import.meta.url);
const { chromium } = require('playwright');
const arg = (k, d) => (process.argv.find((a) => a.startsWith(`--${k}=`)) ?? `--${k}=${d}`).split('=')[1];
const port = Number(arg('port', 4880));
const floors = arg('floors', '2,3,4,5,6').split(',').map(Number);
const doWeb = arg('web', '1') === '1';
const doDesktop = arg('desktop', '1') === '1';
const seconds = Number(arg('seconds', 6));
const ratio = Number(arg('ratio', 1.25));
// Browser runs per floor and figure; every number in the table is the median of them (one run's 99th
// percentile swings by 20 ms either way on the Arboretum, old figure or new).
const runs = Math.max(1, Number(arg('runs', 3)));
function medianOf(list) {
  const ok = list.filter((r) => !r.error);
  if (ok.length === 0) return list[0];
  const out = { ...ok[0], runs: ok.length };
  for (const k of Object.keys(ok[0])) {
    if (typeof ok[0][k] !== 'number') continue;
    const v = ok.map((r) => r[k]).filter((x) => typeof x === 'number').sort((a, b) => a - b);
    out[k] = v[Math.floor((v.length - 1) / 2)] * 0.5 + v[Math.ceil((v.length - 1) / 2)] * 0.5;
  }
  out.errors = ok.flatMap((r) => r.errors);
  out.memKeys = ok.every((r) => r.memKeys);
  return out;
}
const only = arg('only', '');
// --gpu=hw: Chromium on this PC's graphics card through ANGLE (Direct3D 11). --gpu=soft: SwiftShader, the
// software rasteriser, where every triangle and pixel costs CPU time: a pessimistic stand-in for a weak
// laptop's built-in graphics (the absolute 30 fps check is skipped there; old against new is what counts).
const gpu = arg('gpu', 'hw');
const GPU_ARGS = gpu === 'soft' ? ['--use-angle=swiftshader', '--enable-unsafe-swiftshader'] : ['--use-angle=default', '--enable-gpu', '--ignore-gpu-blocklist'];
for (const p of [port, port + 1]) if (p < 4880 || p > 4899) throw new Error(`port ${p} is outside 4880-4899`);
const web = join(project, 'export', 'web');
const exe = join(project, 'export', 'windows', 'GoingDown.exe');
const RESIDENT = { 1: 'Orderly', 2: 'Orderly', 3: 'Temp', 4: 'Minder', 5: 'Groundskeeper', 6: 'Rigger' };
const PLACE = { 1: 'clinic', 2: 'clinic', 3: 'annex', 4: 'playroom', 5: 'arboretum', 6: 'ward' };
const figs = only ? [only] : ['old', 'new'];
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const r1 = (v) => (v == null || Number.isNaN(v) ? null : Math.round(v * 10) / 10);
const children = [];
const browsers = [];
process.on('exit', () => { for (const c of children) try { c.kill(); } catch { /* gone */ } });

// ---- the download: the figures' files inside index.pck
function pckEntries(file) {
  const fd = openSync(file, 'r');
  const rd = (pos, n) => { const b = Buffer.alloc(n); readSync(fd, b, 0, n, pos); return b; };
  try {
    const h = rd(0, 128);
    if (h.toString('latin1', 0, 4) !== 'GDPC') throw new Error('not a pck');
    const version = h.readUInt32LE(4);
    const flags = h.readUInt32LE(20);
    const fileBase = Number(h.readBigUInt64LE(24));
    let pos = 32;
    if (version >= 3) { pos = Number(h.readBigUInt64LE(32)); } else pos = 32 + 64;
    if (flags & 1) throw new Error('the pck directory is encrypted');
    const count = rd(pos, 4).readUInt32LE(0);
    pos += 4;
    const out = [];
    for (let i = 0; i < count; i++) {
      const len = rd(pos, 4).readUInt32LE(0);
      const path = rd(pos + 4, len).toString('utf8').replace(/\0+$/, '');
      pos += 4 + len;
      const e = rd(pos, 8 + 8 + 16 + 4);
      const off = Number(e.readBigUInt64LE(0));
      out.push({ path, offset: (flags & 2 ? fileBase : 0) + off, size: Number(e.readBigUInt64LE(8)) });
      pos += 36;
    }
    return { entries: out, read: (e) => rd(e.offset, e.size), close: () => closeSync(fd) };
  } catch (err) {
    closeSync(fd);
    throw err;
  }
}
const FILES = {
  Orderly: { old: [/\/orderly\.glb/, /\/orderly_Orderly_atlas/], new: [/\/orderly_v2/] },
  Temp: { old: [/\/temp\.glb/, /\/temp_temp_/], new: [/\/temp_v2/] },
  Minder: { old: [/\/minder\.glb/, /\/minder_Minder_/], new: [/\/minder_v2/] },
  Groundskeeper: { old: [/\/groundskeeper\.glb/, /\/groundskeeper_Groundskeeper/], new: [/\/groundskeeper_v2/] },
  Rigger: { old: [/\/rigger\.glb/], new: [/\/rigger_v2/] },
};
function downloadSizes() {
  const pck = join(web, 'index.pck');
  const res = { pckMB: r1(statSync(pck).size / 1048576), figures: {} };
  const p = pckEntries(pck);
  try {
    for (const [name, sets] of Object.entries(FILES)) {
      res.figures[name] = {};
      for (const k of ['old', 'new']) {
        let raw = 0;
        let br = 0;
        const paths = [];
        for (const e of p.entries) if (sets[k].some((re) => re.test(e.path))) {
          const b = p.read(e);
          raw += b.length;
          br += brotliCompressSync(b, { params: { [zc.BROTLI_PARAM_QUALITY]: 9 } }).length;
          paths.push(e.path);
        }
        res.figures[name][k] = { raw, br, files: paths.length };
      }
    }
  } finally { p.close(); }
  return res;
}

// ---- where to stand: 4 to 9 m from the resident down a clear line (a sightline through its cell), else any
// walkable cell at that range on its level.
function spotFor(plan, o) {
  const S = 2;
  const ex = Math.floor(o.x / S);
  const ey = Math.floor(o.z / S);
  const lv = o.level ?? 0;
  const cands = [];
  for (const sl of plan.sightlines ?? []) {
    if (sl.level !== lv) continue;
    const onX = sl.x1 === sl.x2 && sl.x1 === ex && ey >= Math.min(sl.y1, sl.y2) && ey <= Math.max(sl.y1, sl.y2);
    const onY = sl.y1 === sl.y2 && sl.y1 === ey && ex >= Math.min(sl.x1, sl.x2) && ex <= Math.max(sl.x1, sl.x2);
    if (!onX && !onY) continue;
    for (let x = Math.min(sl.x1, sl.x2); x <= Math.max(sl.x1, sl.x2); x++) for (let y = Math.min(sl.y1, sl.y2); y <= Math.max(sl.y1, sl.y2); y++) {
      const d = Math.hypot(x - ex, y - ey) * S;
      if (d >= 4 && d <= 9) cands.push({ level: lv, x, y, d, line: true });
    }
  }
  if (cands.length === 0 && plan.liftDist) {
    const W = plan.width;
    const H = plan.height;
    for (let x = 0; x < W; x++) for (let y = 0; y < H; y++) {
      if (plan.liftDist[lv * W * H + y * W + x] < 0) continue;
      const d = Math.hypot(x - ex, y - ey) * S;
      if (d >= 4 && d <= 9) cands.push({ level: lv, x, y, d, line: false });
    }
  }
  cands.sort((a, b) => Math.abs(a.d - 7) - Math.abs(b.d - 7));
  return cands[0] ?? null;
}
const HALF_VIEW = 40; // degrees either side of the centre (the view is 70 degrees tall, about 102 wide at 16:9)
function inView(s) {
  const o = s.orderly;
  if (!o || !o.drawn || !s.me) return false;
  const yaw = s.client.yaw;
  const fx = -Math.sin(yaw);
  const fz = -Math.cos(yaw);
  const dx = o.x - s.me.x;
  const dz = o.z - s.me.z;
  const a = Math.abs(Math.atan2(fx * dz - fz * dx, fx * dx + fz * dz)) * 180 / Math.PI;
  return a < HALF_VIEW && Math.abs((o.level ?? 0) - (s.me.level ?? 0)) === 0;
}
const faceIt = (cmd, s) => cmd(`face ${s.orderly.x} ${s.orderly.z} ${(s.orderly.level ?? 0) * 3.2 + 1.3}`);

// Stand facing the resident: returns { spot, firstSight, view: [inView samples], s } after the first 1.5 s.
async function standAndFace(d, plan) {
  let s = await d.state();
  const spot = spotFor(plan, s.orderly);
  if (spot) await d.cmd(`teleport ${spot.level} ${spot.x} ${spot.y}`);
  await sleep(400);
  await d.cmd('resetstats');
  s = await d.state();
  await faceIt(d.cmd, s);
  const t = Date.now();
  while (Date.now() - t < 1500) {
    await sleep(250);
    s = await d.state();
    if (s.orderly) await faceIt(d.cmd, s);
  }
  const first = JSON.parse(await d.cmd('stats'));
  return { spot, firstSight: first.max_ms, s };
}
// While `busy` runs, re-aim at the resident every 300 ms and sample whether it is in view.
async function keepFacing(d, busy) {
  let done = false;
  const views = [];
  const loop = (async () => {
    while (!done) {
      const s = await d.state();
      if (s.orderly) { views.push(inView(s)); await faceIt(d.cmd, s); }
      if (s.phase === 'ended' || s.summary?.wiped) views.push(false);
      await sleep(300);
    }
  })();
  const r = await busy;
  done = true;
  await loop;
  return { r, onScreen: views.length ? views.filter(Boolean).length / views.length : 0, samples: views.length };
}

// ---- the browser build
async function webRun(floor, fig) {
  const browser = await chromium.launch({ headless: true, args: [...GPU_ARGS, '--disable-gpu-vsync', '--disable-frame-rate-limit'] });
  browsers.push(browser);
  try {
    const page = await browser.newPage({ viewport: { width: 1280, height: 720 } });
    const errors = [];
    page.on('pageerror', (e) => errors.push(e.message));
    await page.addInitScript(() => {
      // The WebAssembly heap: capture the module's memory, whichever way the loader makes it.
      window.__mems = [];
      const OrigMem = WebAssembly.Memory;
      WebAssembly.Memory = function (...a) { const m = new OrigMem(...a); window.__mems.push(m); return m; };
      WebAssembly.Memory.prototype = OrigMem.prototype;
      const keep = (r) => { try { const ex = (r.instance ?? r).exports; for (const v of Object.values(ex)) if (v instanceof OrigMem) window.__mems.push(v); } catch { /* not ours */ } return r; };
      const inst = WebAssembly.instantiate;
      WebAssembly.instantiate = (...a) => inst(...a).then(keep);
      if (WebAssembly.instantiateStreaming) { const st = WebAssembly.instantiateStreaming; WebAssembly.instantiateStreaming = (...a) => st(...a).then(keep); }
      window.__heap = () => Math.max(0, ...window.__mems.map((m) => m.buffer.byteLength));
    });
    const t0 = Date.now();
    await page.goto(`http://127.0.0.1:${port}/index.html?auto=1&quota=0&floor=${floor}${fig === 'old' ? '&figures=old' : ''}`);
    await page.waitForFunction(() => window.gdReady === true, null, { timeout: 180000 });
    const startMs = await page.evaluate(() => window.gdFirstFrameMs);
    const pageMs = Date.now() - t0;
    const cmd = (c) => page.evaluate((c) => { window.gdCmd(c); return window.gdResult; }, c);
    const state = async () => { try { return JSON.parse(await cmd('state')); } catch { return {}; } };
    const gl = await page.evaluate(() => {
      const c = document.createElement('canvas').getContext('webgl2');
      const ext = c && c.getExtension('WEBGL_debug_renderer_info');
      return ext ? c.getParameter(ext.UNMASKED_RENDERER_WEBGL) : (c ? c.getParameter(c.RENDERER) : 'no webgl2');
    });
    const t1 = Date.now();
    await cmd('alone');
    let s = {};
    for (let i = 0; i < 1200; i++) {
      s = await state();
      if (s.phase !== undefined && s.depth === floor && s.client?.built === floor) break;
      await sleep(50);
    }
    const floorMs = Date.now() - t1;
    if (s.depth !== floor) return { error: `the run did not reach floor ${floor} (depth ${s.depth})`, gl };
    await sleep(800);
    const plan = JSON.parse(await cmd('plan'));
    const stand = await standAndFace({ cmd, state }, plan);
    await cmd('resetstats');
    const kept = await keepFacing({ cmd, state }, page.evaluate((ms) => new Promise((done) => {
      const out = [];
      let last = performance.now();
      const end = last + ms;
      const tick = (t) => { out.push(t - last); last = t; if (t < end) requestAnimationFrame(tick); else done(out); };
      requestAnimationFrame(tick);
    }), seconds * 1000));
    const deltas = kept.r.slice(1).sort((a, b) => a - b);
    const stats = JSON.parse(await cmd('stats'));
    const heap = await page.evaluate(() => window.__heap());
    const jsHeap = await page.evaluate(() => performance.memory?.usedJSHeapSize ?? 0);
    const pct = (p) => deltas[Math.min(deltas.length - 1, Math.floor(p * deltas.length))];
    return {
      gl, startMs: Math.round(startMs), pageMs, floorMs, firstSight: r1(stand.firstSight), spot: stand.spot,
      frames: deltas.length, mean: r1(deltas.reduce((a, b) => a + b, 0) / deltas.length), p99: r1(pct(0.99)), max: r1(pct(1)), slow: r1(deltas.filter((x) => x > 33.4).length * 10 / seconds),
      engineAvg: r1(stats.avg_ms), engineMax: r1(stats.max_ms), prims: stats.prims, draws: stats.draw_calls,
      texMB: r1(stats.texture_mem / 1048576), vidMB: r1(stats.video_mem / 1048576), memKeys: 'texture_mem' in stats && 'video_mem' in stats,
      heapMB: r1(heap / 1048576), jsHeapMB: r1(jsHeap / 1048576), onScreen: kept.onScreen, samples: kept.samples, errors: errors.slice(0, 3),
    };
  } finally {
    await browser.close();
    browsers.splice(browsers.indexOf(browser), 1);
  }
}

// ---- the Windows build, headless
async function desktopRun(floor, fig) {
  const tp = port + 1;
  const args = ['--headless', '--', 'auto=1', 'quota=0', `testport=${tp}`];
  if (floor <= 5) args.push(`floor=${floor}`);
  if (fig === 'old') args.push('figures=old');
  const t0 = Date.now();
  const game = spawn(exe, args, { cwd: dirname(exe), stdio: ['ignore', 'pipe', 'pipe'] });
  children.push(game);
  const lines = [];
  const keep = (b) => { for (const l of b.toString().split(/\r?\n/)) if (l.trim()) lines.push(l); };
  game.stdout.on('data', keep);
  game.stderr.on('data', keep);
  let exited = false;
  game.on('exit', () => { exited = true; });
  try {
    let sock = null;
    for (let i = 0; i < 400 && !sock && !exited; i++) {
      sock = await new Promise((res) => { const so = connect(tp, '127.0.0.1', () => res(so)); so.on('error', () => res(null)); });
      if (!sock) await sleep(100);
    }
    if (!sock) return { error: `no test channel (${lines.slice(-3).join(' | ')})` };
    let buf = '';
    const waiting = [];
    sock.on('data', (dd) => { buf += dd.toString(); let i; while ((i = buf.indexOf('\n')) >= 0) { const l = buf.slice(0, i); buf = buf.slice(i + 1); waiting.shift()?.(l); } });
    const cmd = (c) => new Promise((res) => { waiting.push(res); sock.write(c + '\n'); });
    const state = async () => { try { return JSON.parse(await cmd('state')); } catch { return {}; } };
    for (let i = 0; i < 300; i++) { const sc = JSON.parse(await cmd('screen')); if (sc.screen === 'title') break; await sleep(100); }
    const titleMs = Date.now() - t0;
    const t1 = Date.now();
    if (floor <= 5) await cmd('alone');
    else { await cmd('ui playtest'); await sleep(200); await cmd(`ui ${floor}`); }
    let s = {};
    let ward = {};
    for (let i = 0; i < 1200; i++) {
      if (floor <= 5) {
        s = await state();
        if (s.phase !== undefined && s.depth === floor && s.client?.built === floor) break;
      } else {
        try { ward = JSON.parse(await cmd('late')); } catch { ward = {}; }
        if (ward.wardDrawn && ward.depth === floor) break;
      }
      await sleep(50);
    }
    const floorMs = Date.now() - t1;
    if (floor <= 5 ? s.depth !== floor : !(ward.wardDrawn && ward.depth === floor)) return { error: `did not reach floor ${floor}` };
    await sleep(800);
    let onScreen = null;
    let firstSight = null;
    if (floor <= 5) {
      const plan = JSON.parse(await cmd('plan'));
      const stand = await standAndFace({ cmd, state }, plan);
      firstSight = stand.firstSight;
      await cmd('resetstats');
      const kept = await keepFacing({ cmd, state }, sleep(seconds * 1000));
      onScreen = kept.onScreen;
    } else {
      await cmd('resetstats');
      await sleep(seconds * 1000);
    }
    const stats = JSON.parse(await cmd('stats'));
    let privMB = null;
    try { privMB = r1(Number(execFileSync('powershell', ['-NoProfile', '-Command', `(Get-Process -Id ${game.pid}).PrivateMemorySize64`]).toString().trim()) / 1048576); } catch { /* unread */ }
    const errs = lines.filter((l) => /SCRIPT ERROR|ERROR:/.test(l)).slice(0, 3);
    sock.destroy();
    return { titleMs, floorMs, firstSight: r1(firstSight), avg: r1(stats.avg_ms), max: r1(stats.max_ms), fps: stats.fps, privMB, onScreen, errors: errs, renderer: stats.renderer };
  } finally {
    game.kill();
    for (let i = 0; i < 50 && !exited; i++) await sleep(100);
  }
}

// ---- run everything
const results = { web: {}, desktop: {}, download: null, budgets: { ratio, frameSlackMs: 1, firstSightSlackMs: 100, loadSlackMs: 3000, absMeanMs: 33.3, downloadMB: 18 } };
const checks = [];
const check = (name, ok, detail) => { checks.push(ok); console.log(`${ok ? 'PASS' : 'FAIL'} ${name} (${detail})`); };
const within = (n, o, slack) => n <= o * ratio || n - o <= slack;

if (doWeb && !existsSync(join(web, 'index.pck'))) throw new Error('no web export: run npm run godot:export first');
if (doDesktop && !existsSync(exe)) throw new Error('no Windows export: run npm run godot:export first');

if (doWeb) {
  results.download = downloadSizes();
  const server = spawn(process.execPath, [join(here, 'serve.mjs'), web, String(port)], { stdio: ['ignore', 'pipe', 'pipe'] });
  children.push(server);
  await new Promise((res) => server.stdout.once('data', res));
  try {
    for (const f of floors.filter((x) => x <= 5)) {
      results.web[f] = {};
      for (const fig of figs) {
        const got = [];
        for (let i = 0; i < runs; i++) {
          let r = await webRun(f, fig);
          if (!r.error && r.onScreen < 0.5) { console.log(`  web floor ${f} ${fig}: resident in view ${Math.round(r.onScreen * 100)}%, once more`); r = await webRun(f, fig); }
          console.log(`  web floor ${f} ${fig} run ${i + 1}: ${JSON.stringify(r)}`);
          got.push(r);
        }
        const r = medianOf(got);
        results.web[f][fig] = r;
        console.log(`  web floor ${f} ${fig}: ${JSON.stringify(r)}`);
      }
    }
  } finally {
    server.kill();
  }
}
if (doDesktop) {
  for (const f of floors) {
    results.desktop[f] = {};
    for (const fig of figs) {
      let r = await desktopRun(f, fig);
      if (!r.error && r.onScreen != null && r.onScreen < 0.5) { console.log(`  desktop floor ${f} ${fig}: resident in view ${Math.round(r.onScreen * 100)}%, once more`); r = await desktopRun(f, fig); }
      results.desktop[f][fig] = r;
      console.log(`  desktop floor ${f} ${fig}: ${JSON.stringify(r)}`);
    }
  }
}

// ---- the table
const pad = (v, n) => String(typeof v === 'number' ? r1(v) : (v ?? '-')).padStart(n);
const gl = Object.values(results.web).flatMap((x) => Object.values(x)).find((r) => r.gl)?.gl;
if (doWeb) {
  console.log(`\nBROWSER (headless Chromium; WebGL renderer: ${gl}; vsync and frame cap off; ${seconds} s with the resident in view)`);
  console.log('floor resident       fig | start ms  run ms | mean ms  p99 ms  worst  long/10s | 1st sight | engine avg | prims   draws | tex MB  wasm MB | in view');
  for (const f of Object.keys(results.web)) for (const fig of figs) {
    const r = results.web[f][fig];
    if (r.error) { console.log(`${pad(f, 5)} ${RESIDENT[f].padEnd(14)} ${fig.padStart(3)} | ${r.error}`); continue; }
    console.log(`${pad(f, 5)} ${RESIDENT[f].padEnd(14)} ${fig.padStart(3)} | ${pad(r.startMs, 8)} ${pad(r.floorMs, 7)} | ${pad(r.mean, 7)} ${pad(r.p99, 7)} ${pad(r.max, 6)} ${pad(r.slow, 9)} | ${pad(r.firstSight, 9)} | ${pad(r.engineAvg, 10)} | ${pad(r.prims, 7)} ${pad(r.draws, 6)} | ${pad(r.texMB, 6)} ${pad(r.heapMB, 8)} | ${pad(Math.round(r.onScreen * 100) + '%', 7)}`);
  }
  const d = results.download;
  console.log(`\nDOWNLOAD (index.pck ${d.pckMB} MB raw; figure files compressed with brotli as served)`);
  for (const [n, v] of Object.entries(d.figures)) console.log(`  ${n.padEnd(14)} old ${r1(v.old.br / 1048576)} MB (${v.old.files} files)   new ${r1(v.new.br / 1048576)} MB (${v.new.files} files)`);
}
if (doDesktop) {
  console.log(`\nWINDOWS BUILD, headless (dummy renderer: CPU only, nothing drawn; ${seconds} s)`);
  console.log('floor resident       fig | title ms  run ms | avg ms  max ms | 1st sight | private MB | in view');
  for (const f of Object.keys(results.desktop)) for (const fig of figs) {
    const r = results.desktop[f][fig];
    if (r.error) { console.log(`${pad(f, 5)} ${RESIDENT[f].padEnd(14)} ${fig.padStart(3)} | ${r.error}`); continue; }
    console.log(`${pad(f, 5)} ${RESIDENT[f].padEnd(14)} ${fig.padStart(3)} | ${pad(r.titleMs, 8)} ${pad(r.floorMs, 7)} | ${pad(r.avg, 6)} ${pad(r.max, 7)} | ${pad(r.firstSight, 9)} | ${pad(r.privMB, 10)} | ${r.onScreen == null ? '    n/a' : pad(Math.round(r.onScreen * 100) + '%', 7)}`);
  }
}
console.log('');

// ---- the checks
if (doWeb) {
  for (const f of Object.keys(results.web)) {
    const o = results.web[f].old;
    const n = results.web[f].new;
    const tag = `browser floor ${f} (${RESIDENT[f]})`;
    if (!o || !n) continue;
    if (o.error || n.error) { check(`${tag}: both runs reached the floor`, false, `${o.error ?? ''} ${n.error ?? ''}`); continue; }
    check(`${tag}: the resident was in view while measured`, o.onScreen >= 0.5 && n.onScreen >= 0.5, `old ${Math.round(o.onScreen * 100)}%, new ${Math.round(n.onScreen * 100)}%`);
    check(`${tag}: mean frame time`, within(n.mean, o.mean, 1), `new ${n.mean} ms, old ${o.mean} ms`);
    check(`${tag}: long frames (over 33 ms) per 10 s`, n.slow <= o.slow * ratio + 20 / seconds, `new ${n.slow}, old ${o.slow}; 99th percentile new ${n.p99} ms, old ${o.p99} ms`);
    check(`${tag}: first sight`, n.firstSight - o.firstSight <= 100, `new ${n.firstSight} ms, old ${o.firstSight} ms`);
    if (gpu !== 'soft') check(`${tag}: 30 frames a second with the new figure in view`, n.mean <= 33.3, `${n.mean} ms`);
    check(`${tag}: PLAY ALONE to the run`, n.floorMs - o.floorMs <= 3000, `new ${n.floorMs} ms, old ${o.floorMs} ms`);
    check(`${tag}: start screen`, n.startMs - o.startMs <= 3000, `new ${n.startMs} ms, old ${o.startMs} ms`);
    check(`${tag}: the renderer's memory is read`, n.memKeys && n.texMB > 0, `texture ${n.texMB} MB, video ${n.vidMB} MB`);
    check(`${tag}: no page errors`, n.errors.length === 0 && o.errors.length === 0, `${[...n.errors, ...o.errors].join(' | ') || 'none'}`);
  }
  const d = results.download;
  const add = Object.values(d.figures).reduce((a, v) => a + v.new.br - v.old.br, 0) / 1048576;
  check('download: the new figures against the old', add <= 18 && Object.values(d.figures).every((v) => v.new.files > 0 && v.old.files > 0), `${r1(add)} MB more (brotli), every figure's files found`);
}
if (doDesktop) {
  for (const f of Object.keys(results.desktop)) {
    const o = results.desktop[f].old;
    const n = results.desktop[f].new;
    const tag = `Windows floor ${f} (${RESIDENT[f]})`;
    if (!o || !n) continue;
    if (o.error || n.error) { check(`${tag}: both runs reached the floor`, false, `${o.error ?? ''} ${n.error ?? ''}`); continue; }
    check(`${tag}: mean CPU frame time`, within(n.avg, o.avg, 1), `new ${n.avg} ms, old ${o.avg} ms`);
    check(`${tag}: launch to the run`, n.floorMs - o.floorMs <= 3000, `new ${n.floorMs} ms, old ${o.floorMs} ms`);
    check(`${tag}: no script errors`, n.errors.length === 0 && o.errors.length === 0, `${[...n.errors, ...o.errors].join(' | ') || 'none'}`);
  }
}
mkdirSync(join(project, 'export', 'shots'), { recursive: true });
writeFileSync(join(project, 'export', 'shots', 'perf-figures.json'), JSON.stringify(results, null, 2));
const passed = checks.filter(Boolean).length;
console.log(`perf_figures: ${passed} passed, ${checks.length - passed} failed`);
process.exit(checks.length - passed === 0 && checks.length > 0 ? 0 : 1);
