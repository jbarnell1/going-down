// The Playroom tuned from the owner's first play (T15m; sim/seek.gd "T15m"), checked with two real game
// clients over the real network: the test server (tools/hide_server.gd with tuned=1: the home server's room,
// the run starting on the Playroom, floor 4) on 127.0.0.1, and two games (the engine in GODOT on this project,
// `auto=1`, a test channel each) that join through the start screen's own Join. Bob's link has 0.3 s of delay
// each way. From BOTH screens:
//   - on arrival the anger bar shows, empty;
//   - Bob sprints for half a second: no count, the bar about half full, and each screen's bar is the host's number
//     for its snapshot (Ann's and Bob's copies of the same tick agree);
//   - Bob sprints on: the count starts when it is full, with 30 s to hide on both screens (the same t0);
//   - both hide in the ball pit: sat back, the view out kept (the camera down at the balls, a few balls at
//     the edge at most);
//   - while they hide the bell strikes and the numbers are said ("20.", "10."), and the search starts at
//     t0 + 30 with "COMING, READY OR NOT!";
//   - after the 30 s search the bar drains, and is empty 15 s after the count ended;
//   - Ann walks up to the wandering Minder: within 1 m she is grabbed (found, "grab"), no count starts, and
//     she is dragged to the party table (taken, a seat), on both screens.
// Pictures in export/shots/hide_tuned/ (none with --headless=1). Prints `N passed, M failed`; exit code 1 on
// any failure.
//   node godot/tools/play_hide_tuned.mjs [--port=4464] [--seed=hide-54] [--headless=1]
// Ports 4460-4479 only; the games' test channels are on port+1 and port+2. Windowed: start
// .local/guard-mouse.ps1 beside it. Every process it starts is stopped.
import { spawn } from 'node:child_process';
import { existsSync, mkdirSync, readFileSync, writeFileSync } from 'node:fs';
import { connect } from 'node:net';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const here = dirname(fileURLToPath(import.meta.url));
const project = resolve(here, '..');
const root = resolve(project, '..');
const arg = (k, d) => (process.argv.find((a) => a.startsWith(`--${k}=`)) ?? `--${k}=${d}`).split('=')[1];
const port = Number(arg('port', 4464));
const seed = arg('seed', 'hide-54');
const headless = arg('headless', '0') === '1';
const godot = process.env.GODOT || join(root, 'tools', 'godot', 'Godot_v4.7.2-stable_win64_console.exe');
if (!existsSync(godot)) throw new Error(`no engine at ${godot}: set GODOT`);
const testPorts = [port + 1, port + 2];
for (const p of [port, ...testPorts]) if (!(p >= 4460 && p <= 4479)) throw new Error(`port ${p} is outside 4460-4479`);
const shots = resolve(project, 'export', 'shots', 'hide_tuned');
mkdirSync(shots, { recursive: true });
const SECRET = 'test-passphrase';
const url = `ws://127.0.0.1:${port}`;

const procs = new Set();
const cleanup = () => { for (const p of procs) { try { p.kill(); } catch { /* gone */ } } };
process.on('exit', cleanup);
process.on('SIGINT', () => { cleanup(); process.exit(1); });
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

function launch(args, opts = {}) {
  const p = spawn(godot, args, { cwd: root, env: { ...process.env, ...(opts.env || {}) }, stdio: ['ignore', 'pipe', 'pipe'] });
  procs.add(p);
  const lines = [];
  const keep = (b) => { for (const l of String(b).split(/\r?\n/)) if (l.trim()) { lines.push(l); if (opts.echo) console.log(`  [${opts.echo}] ${l}`); } };
  p.stdout.on('data', keep);
  p.stderr.on('data', keep);
  let exited = false;
  p.on('exit', () => { exited = true; procs.delete(p); });
  return { p, lines, get exited() { return exited; } };
}

async function game(label, testport, args, pos) {
  const g = launch([...(headless ? ['--headless'] : []), '--path', project, '--resolution', '640x360', '--position', pos, '--', 'auto=1', `testport=${testport}`, ...args]);
  let sock = null;
  for (let i = 0; i < 300 && !sock && !g.exited; i++) {
    sock = await new Promise((res) => { const s = connect(testport, '127.0.0.1', () => res(s)); s.on('error', () => res(null)); });
    if (!sock) await sleep(150);
  }
  if (!sock) throw new Error(`${label}: no test channel (${g.lines.slice(-5).join(' | ')})`);
  let buf = '';
  const waiting = [];
  sock.on('data', (d) => { buf += d; let i; while ((i = buf.indexOf('\n')) >= 0) { const l = buf.slice(0, i); buf = buf.slice(i + 1); waiting.shift()?.(l); } });
  const cmd = (c) => new Promise((res) => { waiting.push(res); sock.write(c + '\n'); });
  const state = async () => JSON.parse(await cmd('state'));
  const shot = async (name) => { if (headless) return; const r = await cmd(`shot ${join(shots, name)}`); console.log(`  shot ${join(shots, name)} (${label}) ${r}`); };
  const close = async () => { try { sock.write('quit\n'); } catch { /* closed */ } await sleep(600); if (!g.exited) g.p.kill(); sock.destroy(); };
  return { label, g, cmd, state, shot, close };
}

const results = [];
const check = (name, ok, detail = '') => { results.push({ name, ok, detail }); console.log(`${ok ? 'PASS' : 'FAIL'} ${name}${detail ? ` (${detail})` : ''}`); };
async function until(fn, pred, ms = 30000, every = 60) {
  const end = Date.now() + ms;
  let v = await fn();
  while (!pred(v) && Date.now() < end) { await sleep(every); v = await fn(); }
  return v;
}
const scr = (s) => s.screen ?? {};
const inGame = (s) => s.phase !== undefined;
const dist = (s, x, z) => Math.hypot(s.me.x - x, s.me.z - z);
const r3 = (x) => (typeof x === 'number' ? x.toFixed(3) : String(x));
/** The host's anger at snapshot time t in a screen's history, or undefined. */
const angerAt = (s, t) => (s.seekHist ?? []).find((h) => h[0] === t)?.[2];

async function approach(c, x, z, near = 0.45, gait = 'creep', ms = 12000) {
  const end = Date.now() + ms;
  let s = await c.state();
  while (dist(s, x, z) > near && Date.now() < end) {
    await c.cmd(`face ${x} ${z}`);
    await c.cmd(gait === 'creep' ? 'move 1 0 0 1' : gait === 'sprint' ? 'move 1 0 1 0' : 'move 1 0 0 0');
    await sleep(dist(s, x, z) < 1.0 ? 40 : 80);
    s = await c.state();
  }
  await c.cmd('stopmove');
  await sleep(120);
  return c.state();
}
async function walkCell(c, x, z, pace, gait) {
  await c.cmd(`walkto 0 ${Math.floor(x / 2)} ${Math.floor(z / 2)} ${pace} ${gait}`);
  await sleep(150);
  return until(c.state, (s) => s.auto !== 'walking', 40000);
}

const server = launch(['--headless', '--path', project, '-s', 'res://tools/hide_server.gd', '--', `port=${port}`, `seed=${seed}`, 'depth=4', 'tuned=1'], { env: { GD_JOIN_SECRET: SECRET }, echo: 'server' });
await until(async () => server.lines.join('\n'), (t) => t.includes('listening on') || server.exited, 30000);
if (!server.lines.join('\n').includes('listening on')) { console.log('the server did not start'); process.exit(1); }

let A = null;
let B = null;
try {
  A = await game('A', testPorts[0], [`join=${url}`, 'name=Ann', `pass=${SECRET}`], '40,40');
  B = await game('B', testPorts[1], [`join=${url}`, 'name=Bob', `pass=${SECRET}`, 'delay=0.3'], '700,40');
  for (const c of [A, B]) {
    await until(c.state, (s) => scr(s).screen === 'face', 30000);
    await c.cmd('draw done');
  }
  await until(A.state, (s) => scr(s).screen === 'lobby' && (scr(s).people ?? []).length >= 2, 30000);
  await until(B.state, (s) => scr(s).screen === 'lobby' && (scr(s).people ?? []).length >= 2, 30000);
  // Ready-up (server/room.gd, FD5/FD6): both press READY on the controls card; the run starts for both
  // after the 5 s count.
  await A.cmd('ready');
  await B.cmd('ready');
  let a = await until(A.state, inGame, 30000);
  let b = await until(B.state, inGame, 30000);
  await A.cmd('click');
  await B.cmd('click');
  a = await until(A.state, (s) => s.phase === 'unloading' && s.client.doors > 0.95, 30000);
  b = await until(B.state, (s) => s.phase === 'unloading' || s.phase === 'away', 30000);
  const idA = a.me.id;
  const idB = b.me.id;
  const plan = JSON.parse(await A.cmd('plan'));
  const hides = JSON.parse(await A.cmd('hides'));
  const lx = (plan.landing.x + 0.5) * 2;
  const lz = (plan.landing.y + 0.5) * 2;
  const pit = hides.filter((h) => h.kind === 'pit' && h.level === 0).sort((p, q) => Math.hypot(p.front[0] - lx, p.front[1] - lz) - Math.hypot(q.front[0] - lx, q.front[1] - lz))[0];

  // ---- 1. On the Playroom: the anger bar, empty, on both.
  a = await until(A.state, (s) => s.hud.anger >= 0, 5000);
  b = await until(B.state, (s) => s.hud.anger >= 0, 5000);
  check('the run starts on the tuned Playroom: the anger bar shows, empty, on both screens', a.place === 'playroom' && b.place === 'playroom' && a.hud.anger === 0 && b.hud.anger === 0 && /SPRINT 1 S/.test(a.hud.angerRates),
    `A ${a.place} anger ${a.hud.anger} "${a.hud.angerRates}", B ${b.place} anger ${b.hud.anger}`);

  // ---- 2. Out of the car, creeping (no angrier); in the lobby (no squeaky tiles) Bob sprints for half a second:
  // no count, the bar part full, the host's number.
  for (const c of [A, B]) await c.cmd('move 1 0 0 1');
  await sleep(1800);
  await A.cmd('stopmove');
  await B.cmd('stopmove');
  a = await A.state();
  check('creeping out of the car made it no angrier', a.seek.n === 0 && a.seek.anger === 0, `count ${a.seek.n}, anger ${a.seek.anger}`);
  await B.cmd('move 0 1 1 0');
  await sleep(250);
  await B.cmd('move 0 -1 1 0');
  await sleep(250);
  await B.cmd('stopmove');
  await sleep(700);
  a = await A.state();
  b = await B.state();
  const common = (a.seekHist ?? []).map((h) => h[0]).filter((t) => angerAt(b, t) !== undefined && t > 0).slice(-1)[0];
  check('half a second of sprint (a whole second fills it since PT1): no count, the bar part full, each screen the host\'s number, the same tick the same on both',
    a.seek.n === 0 && a.hud.anger > 0.2 && a.hud.anger < 0.8 && Math.abs(a.hud.anger - a.seek.anger) < 1e-9 && Math.abs(b.hud.anger - b.seek.anger) < 1e-9
      && common !== undefined && angerAt(a, common) === angerAt(b, common),
    `A bar ${r3(a.hud.anger)} (snapshot ${r3(a.seek.anger)}), B bar ${r3(b.hud.anger)}; tick ${r3(common)}: A ${r3(angerAt(a, common))}, B ${r3(angerAt(b, common))}`);
  await A.cmd(`face ${lx} ${lz} 1.4`);
  await sleep(200);
  await A.shot('01-the-anger-bar-part-full.png');

  // ---- 3. Bob sprints on: the count when it is full, 30 s to hide, the same t0 on both.
  for (let k = 0; k < 8; k++) {
    await B.cmd(k % 2 === 0 ? 'move 0 1 1 0' : 'move 0 -1 1 0');
    a = await until(A.state, (s) => s.countEvent?.n === 1, 500, 30);
    if (a.countEvent?.n === 1) break;
  }
  await B.cmd('stopmove');
  b = await until(B.state, (s) => s.countEvent?.n === 1, 6000, 30);
  const ev = a.countEvent ?? {};
  check('the count starts when the bar is full: 30 s to hide on both screens, the same t0, started by Bob sprinting',
    ev.hide === 30 && b.countEvent?.hide === 30 && ev.t0 === b.countEvent?.t0 && ev.by === idB && ev.why === 'sprint' && ev.len === 30,
    `A ${JSON.stringify(ev)}; B hide ${b.countEvent?.hide} t0 ${r3(b.countEvent?.t0)}`);
  a = await until(A.state, (s) => s.hud.anger === 1 && /^HIDE/.test(s.hud.countText), 3000);
  check('the bar is full and the screen says HIDE', a.hud.anger === 1 && /^HIDE\s+(30|29|28)/.test(a.hud.countText), `bar ${a.hud.anger}, "${a.hud.countText}"`);

  // ---- 4. Both run to the ball pit (sprinting is free while they hide) and get in: sat back with the view out.
  await Promise.all([walkCell(A, pit.front[0], pit.front[1], 5, 'sprint'), walkCell(B, pit.front[0], pit.front[1], 5, 'sprint')]);
  a = await approach(A, pit.front[0] + 0.3, pit.front[1], 0.45, 'walk');
  b = await approach(B, pit.front[0] - 0.3, pit.front[1], 0.45, 'walk');
  await A.cmd('hide');
  await B.cmd('hide');
  a = await until(A.state, (s) => s.mySeek?.phase === 'inside', 5000);
  b = await until(B.state, (s) => s.mySeek?.phase === 'inside', 5000);
  await sleep(600);
  a = await A.state();
  const eye = a.camPos[1] - a.me.y;
  check('sat back in the ball pit: the view out kept, the camera down at the balls', a.hide.overlay === 'sat' && a.hide.viewOut === true && a.hideCam?.peek === false && eye > 0.36 && eye < 0.47,
    `overlay ${a.hide.overlay} (${a.hide.overlayKind}), view out ${a.hide.viewOut}, eye ${r3(eye)} m`);
  // Looking out over the balls, away from Bob beside her in the pit.
  const bobAt = (a.others ?? []).find((o) => o.id === idB)?.at;
  const away = bobAt ? Math.atan2(-(a.me.x - bobAt[0]), -(a.me.z - bobAt[2])) : Math.atan2(-(lx - a.me.x), -(lz - a.me.z));
  await A.cmd(`look ${(away * 180) / Math.PI} 0`);
  await sleep(400);
  await A.shot('02-sat-back-in-the-ball-pit.png');

  // ---- 5. While they hide: the bell, the numbers; then the search.
  const t0 = ev.t0;
  b = await until(B.state, (s) => s.hostNow >= t0 + 21.2, 30000, 100);
  check('the numbers are said while they hide: 20 with 10 s to go... (the bell strikes through it)', b.captions.includes('20.') && (b.hide.strokes ?? []).filter((x) => x[0] === 1).length >= 15 && b.hide.phase === 'hide',
    `captions ${b.captions.slice(-4).join(' / ')}; strokes ${(b.hide.strokes ?? []).length}; phase ${b.hide.phase}`);
  b = await until(B.state, (s) => s.hostNow >= t0 + 30.6, 15000, 80);
  a = await A.state();
  check('ten to one before the search, then COMING, READY OR NOT! at t0 + 30 and IT IS SEARCHING on both',
    b.captions.includes('10.') && b.captions.includes('1.') && b.captions.includes('COMING, READY OR NOT!') && b.hide.phase === 'seek' && /IT IS SEARCHING/.test(b.hud.countText) && /IT IS SEARCHING/.test(a.hud.countText),
    `B: ${b.captions.slice(-5).join(' / ')}; "${b.hud.countText}"; A "${a.hud.countText}"`);
  await A.shot('03-searching-seen-from-the-ball-pit.png');

  // ---- 6. The search ends; the bar drains to empty over 15 s.
  b = await until(B.state, (s) => s.seek.ended >= 1, 45000, 200);
  const tEnd = b.seek.calmUntil - 15;
  b = await until(B.state, (s) => s.hostNow >= tEnd + 7.5, 12000, 80);
  check('after the count the bar drains (about half way 7.5 s after)', b.hud.anger > 0.35 && b.hud.anger < 0.65, `bar ${r3(b.hud.anger)} at ${r3(b.hostNow - tEnd)} s after the end`);
  b = await until(B.state, (s) => s.hud.anger === 0 || s.hostNow >= tEnd + 17, 12000, 80);
  // The bar is the snapshot's number: it reaches 0 within a snapshot and the interpolation delay of 15 s.
  check('and is empty 15 s after the count ended', b.hud.anger === 0 && b.hostNow >= tEnd + 14.5 && b.hostNow <= tEnd + 16, `bar ${r3(b.hud.anger)} at ${r3(b.hostNow - tEnd)} s after the end`);

  // ---- 7. One of them (whoever the search left) walks up to it outside a count: grabbed within 1 m,
  // dragged to the party table, no count.
  a = await A.state();
  const [G, W] = a.mySeek?.status === 'ok' ? [A, B] : [B, A];
  const idG = G === A ? idA : idB;
  await G.cmd('hide');
  let g = await until(G.state, (s) => s.mySeek?.phase === 'out', 4000);
  let grabbed = null;
  const t7 = Date.now();
  while (Date.now() - t7 < 60000) {
    g = await G.state();
    if (g.mySeek?.status !== 'ok') { grabbed = g; break; }
    // Walking (never a noise) to it: along the floor while far, straight at it once close.
    const o = g.orderly;
    if (typeof o.x === 'number') {
      if (o.distance > 3) {
        await G.cmd(`walkto ${o.level ?? 0} ${Math.floor(o.x / 2)} ${Math.floor(o.z / 2)} 3 walk`);
        await sleep(300);
      } else {
        await G.cmd(`face ${o.x} ${o.z}`);
        await G.cmd('move 1 0 0 0');
        await sleep(50);
      }
    } else {
      await sleep(100);
    }
  }
  await G.cmd('stopmove');
  // The other screen (one of them 0.3 s further behind): the same, once its snapshots get there.
  let w = await until(W.state, (s) => (s.seek?.players ?? []).find((p) => p.id === idG)?.status !== 'ok', 3000, 50);
  const rowG = (w.seek?.players ?? []).find((p) => p.id === idG);
  check(`${G.label === 'A' ? 'Ann' : 'Bob'}, walking up to it outside a count, is grabbed within 1 m, on both screens, and no count starts`,
    grabbed && grabbed.mySeek.status === 'found' && rowG && rowG.status !== 'ok' && !w.seek.counting && w.seek.n === 1,
    `${grabbed?.mySeek?.status} at ${r3(grabbed?.orderly?.distance)} m; on the other screen ${rowG?.status}; counting ${w.seek.counting}, counts ${w.seek.n}`);
  // The grab has its own line (one of grab_1..3, client/announcer.gd say_grab), never "Found you", on both screens.
  {
    const grabLines = JSON.parse(readFileSync(join(project, 'assets', 'voice', 'manifest.json'), 'utf8')).lines.filter((l) => l.moment === 'grab').map((l) => l.plain);
    const gs = await G.state();
    const ws = await W.state();
    const lastG = gs.captions.at(-1) ?? '';
    const lastW = ws.captions.at(-1) ?? '';
    check('the grab says its own line on both screens (not "Found you")', grabLines.length === 3 && grabLines.includes(lastG) && grabLines.includes(lastW) && !gs.captions.some((c) => /^FOUND YOU/.test(c)),
      `grabbed screen "${lastG}", other screen "${lastW}"`);
  }
  g = await until(G.state, (s) => s.orderly?.mode === 'drag' || s.mySeek?.status === 'taken', 4000, 50);
  await G.shot('04-grabbed-and-dragged.png');
  g = await until(G.state, (s) => s.mySeek?.status === 'taken', 65000, 200);
  w = await until(W.state, (s) => (s.seek?.players ?? []).find((p) => p.id === idG)?.status === 'taken', 3000, 50);
  check('dragged to the party table: taken, seated, on both screens', g.mySeek?.status === 'taken' && g.mySeek.seat >= 0 && (w.seek?.players ?? []).find((p) => p.id === idG)?.status === 'taken',
    `${g.mySeek?.status} seat ${g.mySeek?.seat}`);
  await G.shot('05-at-the-party-table.png');
  writeFileSync(join(shots, 'play_hide_tuned.json'), JSON.stringify({ results, seed, headless }, null, 2));
} catch (e) {
  check('the session ran to the end', false, String(e?.stack ?? e));
} finally {
  if (A) await A.close();
  if (B) await B.close();
  server.p.kill();
  await sleep(300);
  cleanup();
}
const failed = results.filter((r) => !r.ok).length;
console.log(`${results.length - failed} passed, ${failed} failed`);
process.exit(failed ? 1 : 0);
