// First copied from the client trial on 16 Nov 2026; this file is now edited here (see godot/README.md).
// The scripted playthrough (tools/playthrough.mjs) on the browser build, through the page's test hook
// (window.gdCmd). Chromium runs under its REAL autoplay rules, and the run starts with a real click on
// the picture, as a person's would (under ?auto=1 the click never captures the mouse).
// Usage (server already running on <port>): node play_web.mjs <port> [--query=&quality=full] [--only=first]
import { createRequire } from 'node:module';
import { dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { playthrough } from './playthrough.mjs';

const here = dirname(fileURLToPath(import.meta.url));
const require = createRequire(import.meta.url);
const { chromium } = require(resolve(here, '../../node_modules/playwright'));

const port = Number(process.argv[2] ?? 4440);
const query = (process.argv.find((a) => a.startsWith('--query=')) ?? '--query=').slice(8);
const only = (process.argv.find((a) => a.startsWith('--only=')) ?? '--only=').slice(7);

const browser = await chromium.launch({ headless: true, args: ['--use-angle=default', '--enable-gpu', '--ignore-gpu-blocklist'] });
const page = await browser.newPage({ viewport: { width: 1280, height: 720 } });
const consoleLines = [];
page.on('console', (m) => consoleLines.push(`${m.type()}: ${m.text()}`));
page.on('pageerror', (e) => consoleLines.push(`pageerror: ${e.message}`));
const t0 = Date.now();
await page.goto(`http://127.0.0.1:${port}/index.html?auto=1${query}`);
await page.waitForFunction(() => window.gdReady === true, null, { timeout: 180000 });
const firstFrameMs = await page.evaluate(() => window.gdFirstFrameMs);
console.log(`first frame ${Math.round(firstFrameMs)} ms (page ${Date.now() - t0} ms)`);
await page.mouse.click(640, 360);

await playthrough(
  {
    cmd: (c) => page.evaluate((c) => { window.gdCmd(c); return window.gdResult; }, c),
    screenshot: (path) => page.screenshot({ path }),
    wait: (ms) => page.waitForTimeout(ms),
    close: () => browser.close(),
    consoleLines,
  },
  { shots: resolve(here, '../export/shots'), only, firstFrameMs },
);
