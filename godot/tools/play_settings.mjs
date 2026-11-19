// Live settings end to end (docs/floors/live-settings.md LS2, LS3, LS7): the home server itself
// (server/server.tscn, with `settings=` a file in a fresh temporary folder and `quota=0`) on 127.0.0.1, and two
// game windows (the engine in GODOT on this project, small, `auto=1`, a test channel each) that join through the
// start screen's own Join: Ann first (the host), then Bob.
//   1. In the lobby, Ann's panel (F8) is live and Bob's is read-only: its top line names the host and every
//      arrow is grey; Bob's own panel never sends.
//   2. Ann sets ORDERLY HUNT SPEED to 3.60: both screens show the same notice, word for word, and both panels
//      show * 3.60 M/S WAS 3.80.
//   3. Bob sends a change anyway (a raw "tune" from his connection): the server refuses it, nothing changes, and
//      his connection stays open.
//   4. Ann makes the lift's wait short (SECONDS A FLOOR 7, FEWEST 2, MOST 3): the server's file holds all four
//      changes and nothing else; the history has one line a change.
//   5. A run: both clients have the server's list in force; Ann steps out and calls the car: the indicator starts
//      2 or 3 floors away (the game's own is 6 to 12) and the car arrives within the new wait.
//   6. The server is stopped and started again on the same file: Ann joins again, her panel has the four
//      changes and the join line says so; a run's first snapshot carries them.
// Pictures (only with windows, --headless=0) in export/shots/settings/: Ann's live panel, Bob's read-only panel,
// and the notice over Bob's game. Prints `N passed, M failed`; exit code 1 on any failure.
//   node godot/tools/play_settings.mjs [--port=4444] [--seed=ls-1] [--headless=1]
// Ports 4440-4449 only: the server on port, the windows' test channels on port+1 and port+2. Start
// .local/guard-mouse.ps1 beside a windowed run. Every process it starts is stopped.
import { spawn } from 'node:child_process';
import { existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync } from 'node:fs';
import { connect } from 'node:net';
import { tmpdir } from 'node:os';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const here = dirname(fileURLToPath(import.meta.url));
const project = resolve(here, '..');
const root = resolve(project, '..');
const arg = (k, d) => (process.argv.find((a) => a.startsWith(`--${k}=`)) ?? `--${k}=${d}`).split('=')[1];
const port = Number(arg('port', 4444));
const seed = arg('seed', 'ls-1');
const headless = arg('headless', '1') === '1';
const godot = process.env.GODOT || join(root, 'tools', 'godot', 'Godot_v4.7.2-stable_win64_console.exe');
if (!existsSync(godot)) throw new Error(`no engine at ${godot}: set GODOT`);
const testPorts = [port + 1, port + 2];
for (const p of [port, ...testPorts]) if (!(p >= 4440 && p <= 4449)) throw new Error(`port ${p} is outside 4440-4449`);
const shots = resolve(project, 'export', 'shots', 'settings');
mkdirSync(shots, { recursive: true });
const SECRET = 'test-passphrase';
const url = `ws://127.0.0.1:${port}`;
const dir = mkdtempSync(join(tmpdir(), 'gd-settings-'));
const file = join(dir, 'settings.json');

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
  const cmd = (c) => new Promise((res) => { waiting.push(res); sock.write(c + '\n'); });
  return { sock, cmd };
}

async function game(label, testport, args, pos) {
  const g = launch([...(headless ? ['--headless'] : []), '--path', project, '--resolution', '960x540', '--position', pos, '--', 'auto=1', `testport=${testport}`, ...args]);
  const { sock, cmd } = await line(testport, label, () => !g.exited).catch((e) => { throw new Error(`${e.message} (${g.lines.slice(-5).join(' | ')})`); });
  const state = async () => JSON.parse(await cmd('state'));
  const panel = async () => JSON.parse(await cmd('panel state'));
  const shot = async (name) => { if (headless) return; const r = await cmd(`shot ${join(shots, name)}`); console.log(`  shot ${join(shots, name)} (${label}) ${r}`); };
  const close = async () => { try { sock.write('quit\n'); } catch { /* closed */ } await sleep(600); if (!g.exited) g.p.kill(); sock.destroy(); };
  return { label, g, cmd, state, panel, shot, close };
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
const row = (p, id) => (p.rows ?? []).find((r) => r.id === id);

function startServer() {
  const s = launch(['--headless', '--path', project, 'res://server/server.tscn', '--', 'server', `port=${port}`, 'bind=127.0.0.1', `seed=${seed}`, 'quota=0', 'orientation_campaign=0', `settings=${file}`],
    { env: { GD_JOIN_SECRET: SECRET }, echo: 'server' });
  return s;
}

async function joinGame(label, testport, name, pos) {
  const c = await game(label, testport, [`join=${url}`, `name=${name}`, `pass=${SECRET}`], pos);
  await until(c.state, (s) => scr(s).screen === 'face', 30000);
  await c.cmd('draw done');
  return c;
}

async function callCar(c) {
  // Out of the car onto the landing, then face the call panel and press F (as tools/play_quota.mjs).
  await c.cmd('move 1 0 0 0');
  const plan = JSON.parse(await c.cmd('plan'));
  const car = plan.car;
  await until(c.state, (s) => !s.me.aboard && Math.hypot(s.me.x - car.doorX, s.me.z - car.doorZ) > 1.6, 6000, 50);
  await c.cmd('stopmove');
  await until(c.state, (s) => s.phase === 'away', 20000, 100);
  let s = await c.state();
  const at = s.quota.at;
  for (let i = 0; i < 40 && !s.me.canCall; i++) {
    await c.cmd(`face ${at[0]} ${at[2]} ${at[1]}`);
    if (Math.hypot(s.me.x - at[0], s.me.z - at[2]) > 1.0) { await c.cmd('move 1 0 0 1'); await sleep(120); await c.cmd('stopmove'); }
    await sleep(60);
    s = await c.state();
  }
  if (!s.me.canCall) console.log(`  could not reach the call panel: me ${JSON.stringify(s.me)}, at ${JSON.stringify(at)}, phase ${s.phase}`);
  await c.cmd('call');
  return until(c.state, (s) => s.call != null, 4000, 50);
}

let server = startServer();
await until(async () => server.lines.join('\n'), (t) => t.includes('listening on') || server.exited, 30000);
if (!server.lines.join('\n').includes('listening on')) { console.log('the server did not start'); process.exit(1); }

let A = null;
let B = null;
const notice = 'ANN SET ORDERLY HUNT SPEED 3.80 > 3.60 M/S';
try {
  A = await joinGame('A', testPorts[0], 'Ann', '40,40');
  await until(A.state, (s) => scr(s).screen === 'lobby', 30000);
  B = await joinGame('B', testPorts[1], 'Bob', '1000,40');
  await until(A.state, (s) => scr(s).screen === 'lobby' && (scr(s).people ?? []).length >= 2, 30000);
  await until(B.state, (s) => scr(s).screen === 'lobby' && (scr(s).people ?? []).length >= 2, 30000);

  // 1. Who may change them.
  await A.cmd('panel open');
  await B.cmd('panel open');
  let pa = await until(A.panel, (p) => p.host === true, 5000);
  let pb = await B.panel();
  check('Ann, first in, has the live panel', pa.host === true && pa.top === 'HOST SETTINGS' && pa.saved.startsWith('NOT SAVED') === false, `top "${pa.top}", saved "${pa.saved}"`);
  check('Bob\'s panel is read-only: the top line names the host, every arrow grey', pb.host === false && pb.top === 'ONLY THE HOST CAN CHANGE THESE. HOST: ANN'
    && pb.rows.length > 0 && pb.rows.every((r) => !r.minus && !r.plus), `top "${pb.top}", ${pb.rows.filter((r) => r.minus || r.plus).length} live arrows`);
  check('the panel\'s rows are the registry\'s wired rows (player speeds would be last)', pa.rows.length >= 11 && pa.rows[0].id === 'orderly.speed' && pa.sections[0].title === "TONIGHT'S CHANGES",
    `${pa.rows.length} rows, first ${pa.rows[0]?.id}, sections ${pa.sections.map((s) => s.id).join(' ')}`);
  check('Bob\'s own panel never sends', (await B.cmd('panel set orderly.speed 2.5')) === 'not the host');

  // 2. The host's change: the same notice and the same row on both screens.
  await A.cmd('panel select orderly');
  await A.cmd('panel set orderly.speed 3.6');
  pa = await until(A.panel, (p) => p.notice !== '', 5000, 30);
  pb = await until(B.panel, (p) => p.notice !== '', 5000, 30);
  check('both screens show the notice, word for word', pa.notice === notice && pb.notice === notice, `"${pa.notice}" / "${pb.notice}"`);
  await sleep(300);
  await B.cmd('panel select orderly');
  await A.shot('1-host-panel.png');
  await B.shot('2-read-only-panel.png');
  pa = await A.panel();
  pb = await B.panel();
  const ra = row(pa, 'orderly.speed');
  const rb = row(pb, 'orderly.speed');
  check('both panels show * 3.60 M/S WAS 3.80', ra?.value === '* 3.60 M/S' && ra?.was === 'WAS 3.80' && rb?.value === ra?.value && rb?.was === ra?.was, `${JSON.stringify(ra)} / ${JSON.stringify(rb)}`);

  // 3. Bob sends one anyway.
  await B.cmd('panel forceset orderly.speed 2.5');
  pb = await until(B.panel, (p) => p.flash !== '', 4000, 30);
  check('the server refuses Bob\'s change, and says why on his panel', pb.flash === 'ONLY THE HOST CAN CHANGE THESE', `flash "${pb.flash}"`);
  pa = await A.panel();
  check('nothing changed, and Bob is still connected', pa.asked['orderly.speed'] === 3.6 && scr(await B.state()).screen === 'lobby', JSON.stringify(pa.asked));

  // 4. The lift's wait, and the file.
  await A.cmd('panel set lift.floor_time 7');
  await A.cmd('panel set lift.floors_min 2');
  await A.cmd('panel set lift.floors_max 3');
  pa = await until(A.panel, (p) => Object.keys(p.asked).length === 4, 5000);
  await sleep(300);
  const saved = JSON.parse(readFileSync(file, 'utf8'));
  const want = { 'lift.floor_time': 7, 'lift.floors_max': 3, 'lift.floors_min': 2, 'orderly.speed': 3.6 };
  const sorted = (o) => JSON.stringify(Object.fromEntries(Object.entries(o).sort()));
  check('the server\'s file holds the four changes and nothing else', sorted(saved.set) === sorted(want) && saved.by === 'Ann', JSON.stringify(saved));
  const hist = readFileSync(file + '.log', 'utf8').trim().split('\n');
  check('the history has one line a change', hist.length === 4, `${hist.length} lines`);
  await A.cmd('panel close');
  await B.cmd('panel close');

  // 5. A run: in force, and the car comes from 2 or 3 floors away.
  // Ready-up: the run starts for both after the 5 s count.
  await A.cmd('ready');
  await B.cmd('ready');
  let a = await until(A.state, inGame, 30000);
  await until(B.state, inGame, 30000);
  await A.cmd('click');
  pa = await until(A.panel, (p) => p.runRev > 0, 5000);
  pb = await until(B.panel, (p) => p.runRev > 0, 5000);
  check('both clients have the server\'s list in force in the run', sorted(pa.inForce) === sorted(want) && sorted(pb.inForce) === sorted(want), `${sorted(pa.inForce)} / ${sorted(pb.inForce)}`);
  a = await until(A.state, (s) => s.phase === 'unloading' && s.client.doors > 0.95, 30000);
  // Bob steps out too (the car stays open until the crew is out), a little to the side.
  await B.cmd('click');
  await B.cmd('move 1 0.4 0 0');
  await sleep(900);
  await B.cmd('stopmove');
  a = await callCar(A);
  const floors = a.call?.floors;
  const calledAt = a.t;
  check('the car starts 2 or 3 floors away (the game\'s own: 6 to 12)', floors === 2 || floors === 3, `call ${JSON.stringify(a.call)}`);
  a = await until(A.state, (s) => s.doorsOpen === true && s.phase === 'boarding', 40000, 100);
  const waited = a.t - calledAt;
  check('the car arrives within the new wait (15 to 26 s)', a.phase === 'boarding' && waited >= 14 && waited <= 27, `${waited.toFixed(1)} s`);
  if (!headless) {
    await A.cmd('panel set lift.floor_time 7.5');
    await sleep(500);
    await B.shot('3-notice-over-the-game.png');
    await A.cmd('panel set lift.floor_time 7');
    await sleep(300);
  }
  await A.close();
  await B.close();
  A = null;
  B = null;

  // 6. A restarted server on the same file.
  server.p.kill();
  await until(async () => server.exited, (e) => e, 5000, 100);
  await sleep(500);
  server = startServer();
  await until(async () => server.lines.join('\n'), (t) => t.includes('listening on') || server.exited, 30000);
  check('the restarted server reads the file', server.lines.some((l) => l.includes('live settings:') && l.includes('4 changed')), server.lines.find((l) => l.includes('live settings')) ?? 'no line');
  A = await joinGame('A', testPorts[0], 'Ann', '40,40');
  await until(A.state, (s) => scr(s).screen === 'lobby', 30000);
  await A.cmd('panel open');
  pa = await until(A.panel, (p) => Object.keys(p.asked).length === 4, 5000);
  check('its list reaches a joiner, with the join line', sorted(pa.asked) === sorted(want) && pa.notice === '4 SETTINGS ARE CHANGED TONIGHT. F8 TO SEE.', `${sorted(pa.asked)}, notice "${pa.notice}"`);
  await A.cmd('panel close');
  await A.cmd('ready');
  await until(A.state, inGame, 30000);
  pa = await until(A.panel, (p) => p.runRev > 0, 5000);
  check('a run on the restarted server has them in force', sorted(pa.inForce) === sorted(want), sorted(pa.inForce));
} catch (e) {
  check('the check ran to the end', false, String(e?.stack ?? e));
} finally {
  for (const c of [A, B]) if (c) await c.close();
  server.p.kill();
  await sleep(300);
  rmSync(dir, { recursive: true, force: true });
}
const failed = results.filter((r) => !r.ok).length;
console.log(`${results.length - failed} passed, ${failed} failed`);
process.exit(failed ? 1 : 0);
