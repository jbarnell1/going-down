// The day quota on screen and in voice (FD3; docs/floors/findables-and-day.md section 1, "Where it is shown"
// and "The lines"), checked with two real game clients over the real network: a test server
// (tools/day_server.gd: the home server's room with days, the floor quota and the day lock on as in the game,
// its resident parked, the crew's recording done by the check through a control line) on 127.0.0.1, and two
// game clients (the engine in GODOT on this project, small, `auto=1`, a test channel each), Ann and Bob, who
// join through the start screen's own Join.
//   1. Floor 1. The crew records less than the day quota. Every sampled frame of both clients: the HUD's corner
//      line, the lift monitor's rows and the BANK paint are the host's numbers (the host's own day block at the
//      tick the frame was drawn from). Both vote BANK: the vote is refused, the car rides down, a bank_refused
//      line plays with its caption EARNED N OF Q.
//   2. Floor 2. The crew records the rest: a day_met line with its caption, the HUD line turns MET, the paint
//      amber, the monitor BANK OPEN. Both vote BANK: banked, home.
//   3. Home: the call panel reads CLOSED UNTIL MORNING once the car is shut; the day board gives today's result.
// Pictures in export/shots/day/ (windows only): the monitor with BANK LOCKED, the HUD's corner line, the monitor
// with BANK OPEN, the prison's day board. Prints `N passed, M failed`; exit code 1 on any failure.
//   node godot/tools/play_day.mjs [--port=4470] [--seed=day-1] [--headless=1]
// Ports 4460-4479 only: the server on port, the clients' test channels on port+1 and port+2, the server's
// control line on port+3. With windows, start .local/guard-mouse.ps1 beside it. Every process it starts is stopped.
import { spawn } from 'node:child_process';
import { existsSync, mkdirSync, writeFileSync } from 'node:fs';
import { connect } from 'node:net';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const here = dirname(fileURLToPath(import.meta.url));
const project = resolve(here, '..');
const root = resolve(project, '..');
const arg = (k, d) => (process.argv.find((a) => a.startsWith(`--${k}=`)) ?? `--${k}=${d}`).split('=')[1];
const port = Number(arg('port', 4470));
const seed = arg('seed', 'day-1');
const headless = arg('headless', '0') === '1';
const godot = process.env.GODOT || join(root, 'tools', 'godot', 'Godot_v4.7.2-stable_win64_console.exe');
if (!existsSync(godot)) throw new Error(`no engine at ${godot}: set GODOT`);
const testPorts = [port + 1, port + 2];
const ctlPort = port + 3;
for (const p of [port, ...testPorts, ctlPort]) if (!(p >= 4460 && p <= 4479)) throw new Error(`port ${p} is outside 4460-4479`);
const shots = resolve(project, 'export', 'shots', 'day');
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

async function line(portN, label, isAlive) {
  let sock = null;
  for (let i = 0; i < 300 && !sock && isAlive(); i++) {
    sock = await new Promise((res) => { const s = connect(portN, '127.0.0.1', () => res(s)); s.on('error', () => res(null)); });
    if (!sock) await sleep(150);
  }
  if (!sock) throw new Error(`${label}: no line on ${portN}`);
  let buf = '';
  const waiting = [];
  sock.on('data', (d) => { buf += d; let i; while ((i = buf.indexOf('\n')) >= 0) { const l = buf.slice(0, i); buf = buf.slice(i + 1); waiting.shift()?.(l); } });
  // One command at a time on a line: the sampler and the script share it.
  let chain = Promise.resolve();
  const cmd = (c) => { const run = chain.then(() => new Promise((res) => { waiting.push(res); sock.write(c + '\n'); })); chain = run.catch(() => {}); return run; };
  return { sock, cmd };
}

async function game(label, testport, args, pos) {
  const g = launch([...(headless ? ['--headless'] : []), '--path', project, '--resolution', '640x360', '--position', pos, '--', 'auto=1', `testport=${testport}`, ...args]);
  const { sock, cmd } = await line(testport, label, () => !g.exited).catch((e) => { throw new Error(`${e.message} (${g.lines.slice(-5).join(' | ')})`); });
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
const dl = (s) => s.dayLock ?? {};

// ---- The server.
const server = launch(['--headless', '--path', project, '-s', 'res://tools/day_server.gd', '--', `port=${port}`, `ctl=${ctlPort}`, `seed=${seed}`], { env: { GD_JOIN_SECRET: SECRET }, echo: 'server' });
await until(async () => server.lines.join('\n'), (t) => t.includes('listening on') || server.exited, 30000);
if (!server.lines.join('\n').includes('listening on')) { console.log('the server did not start'); process.exit(1); }
const ctl = await line(ctlPort, 'server control', () => !server.exited);
const host = async (c) => JSON.parse(await ctl.cmd(c));

// ---- The sampler: every frame it reads, on both clients, what the screen shows against the host.
const samples = { frames: 0, locked: 0, open: 0, paint: 0, mismatches: [] };
let sampling = false;
/** Every caption with a fact (EARNED N OF Q) Ann's screen showed, in order. */
const captions = [];
async function sampleOnce(c) {
  const s = await c.state();
  const d = dl(s);
  const sub = d.subtitle ?? '';
  if (c.label === 'A' && sub.includes('EARNED') && captions[captions.length - 1] !== sub) captions.push(sub);
  const v = d.view ?? {};
  if (!d.host || !v.seen || v.hud === '' || d.viewTick < 0) return;
  const h = await host(`dayat ${d.viewTick}`);
  if (!h.ok) return;
  const hd = h.day;
  samples.frames++;
  if (hd.locked) samples.locked++; else samples.open++;
  const wantHud = `DAY ${hd.earned}/${hd.quota}${hd.locked ? '' : ' MET'}`;
  const wantRow2 = hd.locked ? `BANK LOCKED. ${hd.quota - hd.earned} TO GO.` : `BANK OPEN. ABOARD ${hd.aboard}. EACH GETS ${hd.each}.`;
  const bad = [];
  if (v.hud !== wantHud) bad.push(`hud "${v.hud}" want "${wantHud}"`);
  if (d.hudLine !== v.hud) bad.push(`drawn "${d.hudLine}" view "${v.hud}"`);
  if ((v.rows ?? [])[0] !== `DAY ${hd.day}. EARNED ${hd.earned} OF ${hd.quota}.` || (v.rows ?? [])[1] !== wantRow2) bad.push(`rows ${JSON.stringify(v.rows)} want row 2 "${wantRow2}"`);
  if (v.locked !== hd.locked) bad.push(`paint locked ${v.locked}, host ${hd.locked}`);
  if (d.bankLocked !== v.locked) bad.push(`lift paint ${d.bankLocked}, view ${v.locked}`);
  if (JSON.stringify(d.monitor) !== JSON.stringify(v.rows)) bad.push(`lift monitor ${JSON.stringify(d.monitor)} view ${JSON.stringify(v.rows)}`);
  samples.paint++;
  if (bad.length) samples.mismatches.push(`${c.label} tick ${d.viewTick}: ${bad.join('; ')}`);
}
async function sampler(clients) {
  sampling = true;
  while (sampling) {
    for (const c of clients) { try { await sampleOnce(c); } catch { /* a closing client */ } }
    await sleep(120);
  }
}

let A = null;
let B = null;
let samplerDone = null;
try {
  A = await game('A', testPorts[0], [`join=${url}`, 'name=Ann', `pass=${SECRET}`], '40,40');
  B = await game('B', testPorts[1], [`join=${url}`, 'name=Bob', `pass=${SECRET}`], '700,40');
  for (const c of [A, B]) {
    await until(c.state, (s) => scr(s).screen === 'face', 30000);
    await c.cmd('draw done');
  }
  await until(A.state, (s) => scr(s).screen === 'lobby' && (scr(s).people ?? []).length >= 2, 30000);
  await until(B.state, (s) => scr(s).screen === 'lobby' && (scr(s).people ?? []).length >= 2, 30000);
  await A.cmd('start');
  await until(A.state, inGame, 30000);
  await until(B.state, inGame, 30000);
  await A.cmd('click');
  await B.cmd('click');
  let a = await until(A.state, (s) => s.phase === 'unloading' && s.client.doors > 0.95, 30000);
  const info0 = await host('info');
  check('the run has the day lock on (the host\'s day block carries earned, locked)', info0.lock === true && info0.day && info0.day.locked === true && info0.day.earned === 0,
    `lock ${info0.lock}, day ${JSON.stringify(info0.day && { earned: info0.day.earned, quota: info0.day.quota, locked: info0.day.locked })}`);
  samplerDone = sampler([A, B]);
  const plan = JSON.parse(await A.cmd('plan'));
  const car = plan.car;

  /** Both step out of the car and wait for it to leave; Ann calls it once the crew has recorded `n`. */
  async function stepOut() {
    for (const c of [A, B]) {
      const p = JSON.parse(await c.cmd('plan')).car;
      await c.cmd(`face ${p.doorX - p.inX * 3} ${p.doorZ - p.inZ * 3}`);
      await c.cmd('move 1 0 0 0');
    }
    await sleep(1800);
    for (const c of [A, B]) await c.cmd('stopmove');
  }
  async function callFrom(n) {
    await stepOut();
    await until(A.state, (s) => s.phase === 'away', 20000, 100);
    const r = await host(`earn ${n}`);
    const pl = JSON.parse(await A.cmd('plan'));
    await A.cmd(`walkto ${pl.landing.level} ${pl.landing.x} ${pl.landing.y} 3`);
    await until(A.state, (s) => s.auto !== 'walking', 30000);
    await until(A.state, (s) => s.me.canCall === true, 4000);
    await A.cmd('call');
    await until(A.state, (s) => s.phase === 'coming', 5000);
    return r;
  }
  /** One client walks into the car and onto BANK. */
  async function board(c) {
    const pl = JSON.parse(await c.cmd('plan'));
    const p = pl.car;
    await c.cmd(`walkto ${pl.landing.level} ${pl.landing.x} ${pl.landing.y} 3`);
    await until(c.state, (s) => s.auto !== 'walking', 30000);
    await c.cmd(`face ${p.doorX + p.inX * 2} ${p.doorZ + p.inZ * 2}`);
    await c.cmd('move 1 0 0 0');
    await until(c.state, (s) => s.me.aboard === true && Math.abs((s.me.x - p.doorX) * p.inX + (s.me.z - p.doorZ) * p.inZ) > 1.1, 5000, 30);
    await c.cmd('move 0 -1 0 0');
    const s = await until(c.state, (x) => x.me.side === 'bank', 3000, 30);
    await c.cmd('stopmove');
    return s;
  }
  /** Ann looks at the day monitor from where she stands. */
  async function lookAtMonitor(c) {
    const s = await c.state();
    const m = dl(s).monitorAt;
    await c.cmd(`face ${m[0]} ${m[2]} ${m[1]}`);
    await sleep(500);
  }

  // ---- 1. Floor 1: short of the day quota.
  const e1 = await callFrom(500);
  check('1. recorded 500: the floor quota met, the day not', e1.ok && e1.earned === 500 && e1.quota > 500, JSON.stringify(e1));
  a = await until(A.state, (s) => s.phase === 'boarding', 90000, 200);
  await board(A);
  await board(B);
  await lookAtMonitor(A);
  a = await A.state();
  check('boarding, short: the monitor says BANK LOCKED with what is left, the paint reads LOCKED', (dl(a).monitor ?? [])[1] === `BANK LOCKED. ${e1.quota - 500} TO GO.` && dl(a).bankLocked === true && (dl(a).monitor ?? []).length === 3,
    `${JSON.stringify(dl(a).monitor)}, paint locked ${dl(a).bankLocked}`);
  check('the HUD\'s corner line: DAY 500/Q, not met', dl(a).hudLine === `DAY 500/${e1.quota}` && dl(a).hudMet === false, `"${dl(a).hudLine}"`);
  await A.shot('1-monitor-bank-locked.png');
  await A.cmd(`look ${(Math.atan2(car.inX, car.inZ) * 180) / Math.PI + 180} 0`);
  await sleep(300);
  await A.shot('2-hud-corner-line.png');
  // The bell: refused, the car rides down; the line and its caption.
  let caption = '';
  a = await until(A.state, (s) => { const t = dl(s).subtitle ?? ''; if (t.includes('EARNED')) caption = t; return (s.events.bankRefused ?? 0) >= 1 && caption !== ''; }, 40000, 60);
  const b1 = await B.state();
  check('1. BANK refused: both clients got the host\'s bankRefused, the car rides down', (a.events.bankRefused ?? 0) === 1 && (b1.events.bankRefused ?? 0) === 1 && (a.events.banked ?? 0) === 0,
    `refused A ${a.events.bankRefused} B ${b1.events.bankRefused}, banked ${a.events.banked ?? 0}`);
  const said1 = (dl(a).said ?? []).filter((h) => h.moment === 'bank_refused');
  check('a bank_refused line plays, with its caption EARNED 500 OF Q', said1.length === 1 && caption.endsWith(`\nEARNED 500 OF ${e1.quota}`), `${JSON.stringify(said1.map((h) => h.id))}, caption "${caption.replace('\n', ' / ')}"`);
  a = await until(A.state, (s) => s.depth === 2 && s.phase === 'unloading', 30000, 200);
  check('the car went down: floor 2', a.depth === 2, `depth ${a.depth}, phase ${a.phase}`);

  // ---- 2. Floor 2: the rest of the day.
  const e2 = await callFrom(e1.quota);
  check('2. recorded the rest: the day is earned', e2.ok && e2.earned >= e2.quota, JSON.stringify(e2));
  const metCap = `\nEARNED ${e2.earned} OF ${e2.quota}`;
  a = await until(A.state, (s) => (s.events.dayMet ?? 0) >= 1 && (dl(s).said ?? []).some((h) => h.moment === 'day_met') && captions.some((x) => x.endsWith(metCap)), 30000, 100);
  check('dayMet: a day_met line with its caption', (a.events.dayMet ?? 0) === 1 && (dl(a).said ?? []).some((h) => h.moment === 'day_met') && captions.some((x) => x.endsWith(metCap)),
    `dayMet ${a.events.dayMet}, said ${JSON.stringify((dl(a).said ?? []).map((h) => h.id))}, captions ${JSON.stringify(captions)}`);
  check('the HUD line turns MET (amber)', dl(a).hudLine === `DAY ${e2.earned}/${e2.quota} MET` && dl(a).hudMet === true, `"${dl(a).hudLine}"`);
  a = await until(A.state, (s) => s.phase === 'boarding', 90000, 200);
  await board(A);
  await board(B);
  await lookAtMonitor(A);
  a = await A.state();
  check('boarding, met: BANK OPEN with what is aboard, the paint amber', (dl(a).monitor ?? [])[1]?.startsWith('BANK OPEN. ABOARD ') && dl(a).bankLocked === false, `${JSON.stringify(dl(a).monitor)}, paint locked ${dl(a).bankLocked}`);
  await A.shot('3-monitor-bank-open.png');
  a = await until(A.state, (s) => (s.events.banked ?? 0) >= 1, 40000, 100);
  check('2. BANK: banked, the car rides up', (a.events.banked ?? 0) === 1, `banked ${a.events.banked}`);

  // ---- 3. Home.
  a = await until(A.state, (s) => s.depth === 0 && s.phase === 'unloading', 30000, 200);
  await stepOut();
  a = await until(A.state, (s) => s.phase === 'night', 20000, 100);
  check('3. home for the night: the call panel reads CLOSED UNTIL MORNING', a.quota?.panel === 'CLOSED UNTIL MORNING' && dl(a).view?.closed === 'CLOSED UNTIL MORNING', `panel "${a.quota?.panel}"`);
  check('the day board: today\'s result, tomorrow\'s quota, the misses', (a.client.dayBoard ?? [])[1] === 'TODAY MADE' && /^TOMORROW OWES \d+$/.test((a.client.dayBoard ?? [])[2] ?? '') && (a.client.dayBoard ?? [])[3] === 'MISSES 0 OF 3',
    JSON.stringify(a.client.dayBoard));
  await A.cmd('walkto 0 4 8 3');
  await until(A.state, (s) => s.auto !== 'walking', 30000);
  await A.cmd('face 9 18 1.7');
  await sleep(600);
  await A.shot('4-prison-day-board.png');
  sampling = false;
  await samplerDone;
  check('every sampled frame of both clients: the HUD line, the monitor and the BANK paint are the host\'s numbers', samples.mismatches.length === 0 && samples.frames > 40 && samples.locked > 5 && samples.open > 5,
    `${samples.frames} frames (${samples.locked} locked, ${samples.open} open); ${samples.mismatches.slice(0, 3).join(' | ')}`);
  const errors = [...A.g.lines, ...B.g.lines, ...server.lines].filter((l) => /SCRIPT ERROR|ERROR: .*\.gd/.test(l));
  check('no script errors', errors.length === 0, errors.slice(0, 3).join(' | '));
  writeFileSync(join(shots, 'play_day.json'), JSON.stringify({ results, seed, samples: { ...samples, mismatches: samples.mismatches.slice(0, 20) } }, null, 2));
} catch (e) {
  check('the session ran to the end', false, String(e?.stack ?? e));
} finally {
  sampling = false;
  if (samplerDone) await samplerDone.catch(() => {});
  if (A) await A.close();
  if (B) await B.close();
  ctl.sock.destroy();
  server.p.kill();
  await sleep(300);
  cleanup();
}
const failed = results.filter((r) => !r.ok).length;
console.log(`${results.length - failed} passed, ${failed} failed`);
process.exit(failed ? 1 : 0);
