// First copied from the client trial on 16 Nov 2026; this file is now edited here (see godot/README.md).
// Is the browser build audible? Loads the page under Chromium's REAL autoplay rules (no
// --autoplay-policy flag), clicks the canvas and presses a key like a person would, and measures what
// actually reaches the speakers: every AudioNode connected to an AudioContext's destination is also
// teed into an AnalyserNode, sampled every 100 ms. Passes when a context is running and the peak rises
// above silence while the announcer's first line and the light hum should be playing.
// Then the recorded sounds one group at a time (`sfx solo`): the Orderly's trolley is heard while the
// rules say it moves unseen and silent while it is seen and frozen; the tubes' hum is heard on a lit
// floor, ducks under the voice, and is silent in every blink and the blackout; the emergency drone is
// heard in the blackout.
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
// The click lands on PLAY ALONE; the draw-your-face step follows, and Enter keeps the face shown.
await page.waitForTimeout(500);
await page.keyboard.press('Enter');
await page.waitForTimeout(500);
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
const audible = running && voiceBest > SILENCE_DB && quietBest > SILENCE_DB && errors.length === 0;
console.log(`announcer line: ${voiceBest.toFixed(1)} dB peak; without a line (the hum): ${quietBest.toFixed(1)} dB peak`);
const after = await page.evaluate(() => window.__peak());
console.log(JSON.stringify({ before, after: { sampleStarts: after.sampleStarts, contextsMade: after.contextsMade, taps: after.taps }, contexts: states, runningAfterGesture: running, peakDb: Math.round(best * 10) / 10, subtitle: sub, samples: samples.join(' '), errors: errors.slice(0, 5) }, null, 1));
console.log(audible ? 'PASS the browser build is audible after a real gesture' : 'FAIL silent (or no running audio context)');

// ---- The recorded sounds, one at a time (`sfx solo <group>` lets only that group sound and hushes the
// announcer), measured at the speakers against what the rules say at that moment.
const checks = [];
const check = (name, ok, detail) => { checks.push(ok); console.log(`${ok ? 'PASS' : 'FAIL'} ${name} (${detail})`); };
const cmd = (c) => page.evaluate((c) => { window.gdCmd(c); return window.gdResult; }, c);
const sample = async () => page.evaluate(() => { const r = window.__peak(); window.gdCmd('state'); return { db: r.db, s: JSON.parse(window.gdResult) }; });
const LOUD = -60;   // heard
const QUIET = -70;  // silent
let st = (await sample()).s;
if (audible && st.orderly) {
  await cmd('sfx solo approach');
  const plan = JSON.parse(await cmd('plan'));
  const es = plan.entityStart;
  // Down the Orderly's own sightline, about 10 m off (as tools/playthrough.mjs does).
  const along = plan.sightlines.filter((sl) => sl.level === es.level && ((sl.x1 === sl.x2 && sl.x1 === es.x && es.y >= Math.min(sl.y1, sl.y2) && es.y <= Math.max(sl.y1, sl.y2)) || (sl.y1 === sl.y2 && sl.y1 === es.y && es.x >= Math.min(sl.x1, sl.x2) && es.x <= Math.max(sl.x1, sl.x2)))).sort((a, b) => b.length - a.length)[0];
  let spot = null;
  if (along) {
    const cells = [];
    for (let x = Math.min(along.x1, along.x2); x <= Math.max(along.x1, along.x2); x++) for (let y = Math.min(along.y1, along.y2); y <= Math.max(along.y1, along.y2); y++) cells.push({ x, y, d: Math.hypot(x - es.x, y - es.y) * 2 });
    spot = cells.filter((c) => c.d <= 10).sort((a, b) => b.d - a.d)[0];
  }
  if (spot) await cmd(`teleport ${es.level} ${spot.x} ${spot.y}`);
  const ex = (es.x + 0.5) * 2;
  const ez = (es.y + 0.5) * 2;
  await cmd(`face ${ex} ${ez} ${es.level * 3.2 + 1.4}`);
  const trace = [];
  const take = async (n) => { for (let i = 0; i < n; i++) { const p = await sample(); trace.push({ db: p.db, moving: p.s.orderly.moving && !p.s.orderly.held && !p.s.orderly.seeing, held: p.s.orderly.held || p.s.orderly.seeing, d: p.s.orderly.distance, g: p.s.orderly.squeak.gain }); await page.waitForTimeout(100); } };
  await take(25);                       // watched: frozen, and silent
  st = (await sample()).s;
  await cmd(`face ${2 * st.me.x - ex} ${2 * st.me.z - ez}`);
  for (let i = 0; i < 100; i++) {       // turned away: it comes on, heard
    await take(1);
    if (trace[trace.length - 1].d < 3.5) break;
  }
  st = (await sample()).s;
  await cmd(`face ${st.orderly.x} ${st.orderly.z} ${(st.orderly.pose?.y ?? 0) + 1.3}`);
  await take(20);                       // looked back: frozen again, silent
  // A loud sample while the Orderly was held on this and the sample before (the sound's own 100 ms
  // of latency allowed) is the trolley heard while it is seen.
  let whileSeen = 0;
  let worst = -Infinity;
  for (let i = 1; i < trace.length; i++) if (trace[i].held && trace[i - 1].held && trace[i].db > QUIET) { whileSeen++; worst = Math.max(worst, trace[i].db); }
  const heard = trace.filter((t) => t.moving && t.db > LOUD).length;
  const seenN = trace.filter((t) => t.held).length;
  check('the trolley is heard while the Orderly moves unseen', heard >= 5, `${heard} loud samples of ${trace.filter((t) => t.moving).length} while it moved unseen, peak ${Math.max(...trace.filter((t) => t.moving).map((t) => t.db)).toFixed(1)} dB`);
  check('the trolley is silent while the Orderly is seen and frozen', seenN >= 20 && whileSeen === 0, `${seenN} seen samples, ${whileSeen} not silent${whileSeen ? ` (loudest ${worst.toFixed(1)} dB)` : ''}`);
  console.log(`  trolley trace: ${trace.map((t) => `${t.held ? 'S' : t.moving ? 'M' : '.'}${Math.max(-99, Math.round(t.db))}`).join(' ')}`);

  // The hum: heard on a lit floor, ducking under the voice (the bus fader, in the browser too).
  await cmd('sfx solo hum');
  const landing = plan.landing;
  await cmd(`teleport ${landing.level} ${landing.x} ${landing.y}`);
  await page.waitForTimeout(600);
  const level = async (n) => { let m = -Infinity; for (let i = 0; i < n; i++) { m = Math.max(m, (await sample()).db); await page.waitForTimeout(100); } return m; };
  const humLit = await level(10);
  await cmd('sfx duck 1');
  await page.waitForTimeout(700);
  const humDucked = await level(10);
  await cmd('sfx duck -');
  check('the hum is heard on a lit floor', humLit > LOUD, `${humLit.toFixed(1)} dB peak`);
  check('the hum ducks under the voice (about 6 dB)', humLit - humDucked >= 4, `${humLit.toFixed(1)} -> ${humDucked.toFixed(1)} dB`);
  // Call the lift and ride out the blinks and the blackout: lit, the hum; dark, nothing.
  await cmd(`face ${plan.car.doorX} ${plan.car.doorZ} 2.0`);
  await page.waitForTimeout(300);
  await cmd('call');
  await cmd('timescale 2');
  const lights = [];
  let droneHeard = -Infinity;
  for (let i = 0; i < 600; i++) {
    const p = await sample();
    const s = p.s;
    if (s.blackout && s.client.emergency >= 1 && droneHeard === -Infinity) {
      await cmd('sfx solo drone');
      await page.waitForTimeout(400);
      droneHeard = Math.max(-200, (await sample()).db, (await sample()).db);
      await cmd('sfx solo hum');
    }
    lights.push({ db: p.db, dark: s.dark, lit: !s.dark && !s.warn, blackout: s.blackout });
    if (s.phase !== 'coming' && i > 20) break;
    await page.waitForTimeout(100);
  }
  await cmd('timescale 1');
  let darkLoud = 0;
  let darkN = 0;
  let litHeard = 0;
  let litN = 0;
  for (let i = 2; i < lights.length; i++) {
    if (lights[i].dark && lights[i - 1].dark && lights[i - 2].dark) { darkN++; if (lights[i].db > QUIET) darkLoud++; }
    if (lights[i].lit && lights[i - 1].lit && lights[i - 2].lit) { litN++; if (lights[i].db > LOUD) litHeard++; }
  }
  const sawBlackout = lights.some((l) => l.blackout);
  check('the hum is silent in every blink and the blackout', darkN >= 10 && sawBlackout && darkLoud === 0, `${darkN} dark samples (blackout seen: ${sawBlackout}), ${darkLoud} not silent`);
  check('the hum comes back with the lights', litN >= 10 && litHeard >= litN * 0.9, `${litHeard} of ${litN} lit samples heard`);
  check('the emergency lighting drone is heard in the blackout', droneHeard > LOUD, `${droneHeard.toFixed(1)} dB peak`);
  const sounds = JSON.parse(await cmd('sfx state'));
  console.log(`  recordings loaded: ${sounds.recorded.length} one-shot groups; loops recorded: ${Object.entries(sounds.loops).filter(([, v]) => v.recorded).map(([k]) => k).join(', ')}`);
  console.log(`  hum trace: ${lights.map((l) => `${l.dark ? 'D' : l.lit ? 'L' : 'w'}${Math.max(-99, Math.round(l.db))}`).join(' ')}`);
  await cmd('sfx solo -');
} else {
  check('the recorded sounds could be measured', false, audible ? 'no run on the page' : 'the page is silent');
}
const ok = audible && checks.every(Boolean);
console.log(ok ? 'PASS the recorded sounds play where and when they should' : 'FAIL');
await browser.close();
process.exit(ok ? 0 : 1);
