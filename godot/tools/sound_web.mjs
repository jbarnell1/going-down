// First copied from the client trial on 16 Nov 2026; this file is now edited here (see godot/README.md).
// Is the browser build audible? Loads the page under Chromium's REAL autoplay rules (no
// --autoplay-policy flag), clicks the canvas and presses a key like a person would, and measures what
// actually reaches the speakers: every AudioNode connected to an AudioContext's destination is also
// teed into an AnalyserNode, sampled every 100 ms. Passes when a context is running and the peak rises
// above silence while the announcer's first line and the light hum should be playing.
// Usage (server running): node sound_web.mjs <port> [--query=&mute=1]   (mute=1 must FAIL: proof it can)
import { createRequire } from 'node:module';
import { dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const here = dirname(fileURLToPath(import.meta.url));
const require = createRequire(import.meta.url);
const { chromium } = require(resolve(here, '../../node_modules/playwright'));
const port = Number(process.argv[2] ?? 4440);
const query = (process.argv.find((a) => a.startsWith('--query=')) ?? '--query=').slice(8);
const SILENCE_DB = -60;

const browser = await chromium.launch({ headless: true, args: ['--use-angle=default', '--enable-gpu', '--ignore-gpu-blocklist'] });
const page = await browser.newPage({ viewport: { width: 1280, height: 720 } });
const errors = [];
page.on('pageerror', (e) => errors.push(e.message));
page.on('console', (m) => { if (m.type() === 'error') errors.push(m.text()); });
await page.addInitScript(() => {
  const taps = [];
  window.__audio = { taps, contexts: [] };
  const origConnect = AudioNode.prototype.connect;
  AudioNode.prototype.connect = function (dest, ...rest) {
    const r = origConnect.call(this, dest, ...rest);
    try {
      if (dest instanceof AudioDestinationNode) {
        const ctx = dest.context;
        let tap = taps.find((t) => t.ctx === ctx);
        if (!tap) {
          const an = ctx.createAnalyser();
          an.fftSize = 2048;
          tap = { ctx, an, buf: new Float32Array(2048) };
          taps.push(tap);
          window.__audio.contexts.push(ctx);
        }
        origConnect.call(this, tap.an);
      }
    } catch (e) { /* never break the page */ }
    return r;
  };
  // How many sample sources Godot starts (its "Sample" playback path), and how many AudioContexts exist.
  window.__starts = 0;
  const origStart = AudioBufferSourceNode.prototype.start;
  AudioBufferSourceNode.prototype.start = function (...a) { window.__starts++; return origStart.apply(this, a); };
  window.__ctxMade = 0;
  const OrigCtx = window.AudioContext;
  window.AudioContext = function (...a) { window.__ctxMade++; return new OrigCtx(...a); };
  window.AudioContext.prototype = OrigCtx.prototype;
  window.__peak = () => {
    let peak = 0;
    const states = [];
    for (const t of taps) {
      states.push(t.ctx.state);
      t.an.getFloatTimeDomainData(t.buf);
      for (const v of t.buf) peak = Math.max(peak, Math.abs(v));
    }
    return { peak, db: peak > 0 ? 20 * Math.log10(peak) : -Infinity, states, taps: taps.length, sampleStarts: window.__starts, contextsMade: window.__ctxMade };
  };
});
await page.goto(`http://127.0.0.1:${port}/index.html?auto=1${query}`);
await page.waitForFunction(() => window.gdReady === true, null, { timeout: 180000 });
const before = await page.evaluate(() => window.__peak());
// A person's first gestures: a click on the picture, a key.
await page.mouse.click(640, 360);
await page.keyboard.press('KeyW');
await page.waitForTimeout(300);
if (process.argv.includes('--probe')) {
  // Diagnostics: one generated sound and one recorded line, after the gesture.
  await page.evaluate(() => { window.gdCmd('sfx chime'); window.gdCmd('say called'); });
}
let best = -Infinity;
let states = [];
const samples = [];
let voiceBest = -Infinity;
let quietBest = -Infinity;
let sub = '';
for (let i = 0; i < 60; i++) {
  const p = await page.evaluate(() => { const r = window.__peak(); window.gdCmd('state'); r.sub = JSON.parse(window.gdResult).client.subtitle; return r; });
  states = p.states;
  best = Math.max(best, p.db);
  // While a line's subtitle is up the announcer is speaking; otherwise only the hum (and doors) play.
  if (p.sub) { voiceBest = Math.max(voiceBest, p.db); sub = p.sub; } else quietBest = Math.max(quietBest, p.db);
  samples.push(Math.round(p.db));
  await page.waitForTimeout(100);
}
const running = states.includes('running');
const ok = running && voiceBest > SILENCE_DB && quietBest > SILENCE_DB && errors.length === 0;
console.log(`announcer line: ${voiceBest.toFixed(1)} dB peak; without a line (the hum): ${quietBest.toFixed(1)} dB peak`);
const after = await page.evaluate(() => window.__peak());
console.log(JSON.stringify({ before, after: { sampleStarts: after.sampleStarts, contextsMade: after.contextsMade, taps: after.taps }, contexts: states, runningAfterGesture: running, peakDb: Math.round(best * 10) / 10, subtitle: sub, samples: samples.join(' '), errors: errors.slice(0, 5) }, null, 1));
console.log(ok ? 'PASS the browser build is audible after a real gesture' : 'FAIL silent (or no running audio context)');
await browser.close();
process.exit(ok ? 0 : 1);
