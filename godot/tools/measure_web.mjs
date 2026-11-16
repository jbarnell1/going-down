// First copied from the client trial on 16 Nov 2026; this file is now edited here (see godot/README.md).
// Measures the browser build: download sizes, first frame on a first visit (a fresh browser profile,
// so nothing cached) at both quality levels, and frame times (vsync-capped and uncapped) standing in
// the clean corridor looking down it. Writes shots/web-metrics.json.
// Usage (server already running): node measure_web.mjs <port>
import { createRequire } from 'node:module';
import { readFileSync, readdirSync, statSync, writeFileSync } from 'node:fs';
import { gzipSync, brotliCompressSync } from 'node:zlib';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const here = dirname(fileURLToPath(import.meta.url));
const require = createRequire(import.meta.url);
const { chromium } = require(resolve(here, '../../node_modules/playwright'));
const port = Number(process.argv[2] ?? 4440);
const web = resolve(here, '../export/web');

const sizes = {};
let raw = 0;
let gz = 0;
let br = 0;
for (const f of readdirSync(web)) {
  const b = readFileSync(join(web, f));
  const g = gzipSync(b, { level: 9 }).length;
  const r = brotliCompressSync(b).length;
  sizes[f] = { raw: b.length, gzip: g, brotli: r };
  raw += b.length;
  gz += g;
  br += r;
}
const mb = (n) => Math.round((n / 1048576) * 10) / 10;
const result = { sizes, totalMB: { raw: mb(raw), gzip: mb(gz), brotli: mb(br) }, firstFrame: {}, frames: {} };
console.log('download MB', JSON.stringify(result.totalMB));

async function load(quality, extra = []) {
  const browser = await chromium.launch({ headless: true, args: ['--use-angle=default', '--enable-gpu', '--ignore-gpu-blocklist', '--autoplay-policy=no-user-gesture-required', ...extra] });
  const page = await browser.newPage({ viewport: { width: 1280, height: 720 } });
  const t0 = Date.now();
  await page.goto(`http://127.0.0.1:${port}/index.html?auto=1&quality=${quality}`);
  await page.waitForFunction(() => window.gdReady === true, null, { timeout: 180000 });
  const ff = await page.evaluate(() => window.gdFirstFrameMs);
  return { browser, page, firstFrameMs: Math.round(ff), wall: Date.now() - t0 };
}
const cmd = (page, c) => page.evaluate((c) => { window.gdCmd(c); return window.gdResult; }, c);

async function frameTimes(page) {
  // Stand in the clean corridor nearest the lift, looking down it (the most lights in view).
  const plan = JSON.parse(await cmd(page, 'plan'));
  const W = plan.width;
  const H = plan.height;
  const d = (sl) => {
    let s = 0;
    let n = 0;
    for (let x = Math.min(sl.x1, sl.x2); x <= Math.max(sl.x1, sl.x2); x++) for (let y = Math.min(sl.y1, sl.y2); y <= Math.max(sl.y1, sl.y2); y++) { const v = plan.liftDist[sl.level * W * H + y * W + x]; if (v >= 0) { s += v; n++; } }
    return s / Math.max(1, n);
  };
  const sl = plan.sightlines.filter((s) => s.level === 0 && s.length >= 6).sort((a, b) => d(a) - d(b))[0];
  await cmd(page, `teleport ${sl.level} ${sl.x1} ${sl.y1}`);
  await page.waitForTimeout(300);
  await cmd(page, `face ${(sl.x2 + 0.5) * 2} ${(sl.y2 + 0.5) * 2}`);
  await page.waitForTimeout(1500);
  await cmd(page, 'resetstats');
  const deltas = await page.evaluate(() => new Promise((done) => {
    const out = [];
    let last = performance.now();
    const end = last + 8000;
    const tick = (t) => { out.push(t - last); last = t; if (t < end) requestAnimationFrame(tick); else done(out); };
    requestAnimationFrame(tick);
  }));
  const stats = JSON.parse(await cmd(page, 'stats'));
  deltas.sort((a, b) => a - b);
  const pct = (p) => Math.round(deltas[Math.min(deltas.length - 1, Math.floor(p * deltas.length))] * 10) / 10;
  return { count: deltas.length, mean: Math.round((deltas.reduce((a, b) => a + b, 0) / deltas.length) * 10) / 10, p50: pct(0.5), p95: pct(0.95), p99: pct(0.99), max: pct(1), engine: stats };
}

for (const q of ['light', 'full']) {
  const runs = [];
  for (let i = 0; i < 2; i++) {
    const r = await load(q);
    runs.push(r.firstFrameMs);
    if (i === 0) {
      result.frames[`${q}-capped`] = await frameTimes(r.page);
      console.log(q, 'capped', JSON.stringify({ ...result.frames[`${q}-capped`], engine: undefined }));
    }
    await r.browser.close();
  }
  result.firstFrame[q] = runs;
  console.log(q, 'first frame (cold) ms', runs.join(', '));
  const u = await load(q, ['--disable-gpu-vsync', '--disable-frame-rate-limit']);
  result.frames[`${q}-uncapped`] = await frameTimes(u.page);
  console.log(q, 'uncapped', JSON.stringify(result.frames[`${q}-uncapped`]));
  await u.browser.close();
}
writeFileSync(resolve(here, '../export/shots/web-metrics.json'), JSON.stringify(result, null, 2));
