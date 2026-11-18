// The four-slot inventory on screen (docs/floors/skill-tree.md S1, tracker T21a), checked with two real games over the
// real network: a test server (tools/down_server.gd: the home server's room as in the game, findables and the
// inventory on, its resident parked) on 127.0.0.1, and two games (`auto=1`, a test channel each) that join through
// the start screen's own Join, Ann and Bob, on floor 1 (the Clinic).
//   Ann's squares start empty. She searches a drawer holding a carton (the host's fill says which): it shows in
//   slot 1, in her hand, on her screen and in Bob's copy of the host's block. She presses 2 (the hand moves to slot 2)
//   and 1 again, drops it with G (a pickup at her feet, on both screens; her hand empty), sees F  PICK UP JUICE and
//   takes it back with F. G with an empty hand is refused on her screen ("NOTHING IN YOUR HAND."). Bob walks up to
//   her; facing him she gets F  GIVE JUICE TO BOB, presses F, and the carton is in Bob's slot 1, with his line
//   "ANN GAVE YOU A CARTON OF JUICE".
// Pictures in export/shots/inventory/ (windowed runs only): the empty row, one item, a full row (drawn with the test
// channel's `inv demo`: nothing in the game can fill four slots yet), the pickup prompt and the hand-over prompt.
// Prints `N passed, M failed`; exit code 1 on any failure.
//   node godot/tools/play_inventory.mjs [--port=4490] [--seed=inventory-1] [--headless=1]
// Ports 4490-4499 only: the server on port, the games' test channels on port+1 and port+2, the server's control line
// on port+3. With windows, start .local/guard-mouse.ps1 beside it. Every process it starts is stopped.
import { spawn } from 'node:child_process';
import { existsSync, mkdirSync, writeFileSync } from 'node:fs';
import { connect } from 'node:net';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const here = dirname(fileURLToPath(import.meta.url));
const project = resolve(here, '..');
const root = resolve(project, '..');
const arg = (k, d) => (process.argv.find((a) => a.startsWith(`--${k}=`)) ?? `--${k}=${d}`).split('=')[1];
const port = Number(arg('port', 4490));
const seed = arg('seed', 'inventory-1');
const headless = arg('headless', '1') === '1';
const godot = process.env.GODOT || join(root, 'tools', 'godot', 'Godot_v4.7.2-stable_win64_console.exe');
if (!existsSync(godot)) throw new Error(`no engine at ${godot}: set GODOT`);
const testPorts = [port + 1, port + 2];
const ctlPort = port + 3;
for (const p of [port, ...testPorts, ctlPort]) if (!(p >= 4490 && p <= 4499)) throw new Error(`port ${p} is outside 4490-4499`);
const shots = resolve(project, 'export', 'shots', 'inventory');
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
  const cmd = (c) => new Promise((res) => { waiting.push(res); sock.write(c + '\n'); });
  return { sock, cmd };
}

async function game(label, testport, args, pos) {
  const g = launch([...(headless ? ['--headless'] : []), '--path', project, '--resolution', '960x540', '--position', pos, '--', 'auto=1', `testport=${testport}`, ...args]);
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
const dist = (s, x, z) => Math.hypot(s.me.x - x, s.me.z - z);
const bag = (s, id) => (s.inv?.host?.bags ?? []).find((b) => b.playerId === id);
const slotsOf = (s, id) => JSON.stringify(bag(s, id)?.slots ?? null);
const EMPTY = JSON.stringify([['', 0], ['', 0], ['', 0], ['', 0]]);
const ONE = JSON.stringify([['juice', 1], ['', 0], ['', 0], ['', 0]]);

async function approach(c, x, z, near, ms = 12000) {
  const end = Date.now() + ms;
  let s = await c.state();
  while (dist(s, x, z) > near && Date.now() < end) {
    await c.cmd(`face ${x} ${z}`);
    await c.cmd(dist(s, x, z) < 0.6 ? 'move 1 0 0 1' : 'move 1 0 0 0');
    await sleep(dist(s, x, z) < 0.6 ? 30 : 70);
    await c.cmd('stopmove');
    s = await c.state();
  }
  await c.cmd('stopmove');
  await sleep(150);
  return c.state();
}

async function goTo(c, p) {
  const [L, cx, cy] = p.cell;
  await c.cmd(`walkto ${L} ${cx} ${cy} 3`);
  await until(c.state, (s) => s.auto !== 'walking', 60000, 150);
  await approach(c, p.stand[0], p.stand[1], 0.1);
  await c.cmd(`face ${p.x} ${p.z} 0.6`);
  await sleep(300);
  return c.state();
}

const server = launch(['--headless', '--path', project, '-s', 'res://tools/down_server.gd', '--', `port=${port}`, `ctl=${ctlPort}`, `seed=${seed}`], { env: { GD_JOIN_SECRET: SECRET } });
await until(async () => server.lines.join('\n'), (t) => t.includes('listening on') || server.exited, 30000);
if (!server.lines.join('\n').includes('listening on')) { console.log(`the server did not start: ${server.lines.slice(-5).join(' | ')}`); process.exit(1); }
const ctl = await line(ctlPort, 'server control', () => !server.exited);
const host = async (c) => JSON.parse(await ctl.cmd(c));

let A = null;
let B = null;
try {
  A = await game('A', testPorts[0], [`join=${url}`, 'name=Ann', `pass=${SECRET}`], '20,40');
  B = await game('B', testPorts[1], [`join=${url}`, 'name=Bob', `pass=${SECRET}`], '990,40');
  for (const c of [A, B]) {
    await until(c.state, (s) => scr(s).screen === 'face', 30000);
    await c.cmd('draw done');
  }
  await until(A.state, (s) => scr(s).screen === 'lobby' && (scr(s).people ?? []).length >= 2, 30000);
  await until(B.state, (s) => scr(s).screen === 'lobby' && (scr(s).people ?? []).length >= 2, 30000);
  await A.cmd('ready');
  await B.cmd('ready');
  let a = await until(A.state, inGame, 30000);
  await until(B.state, inGame, 30000);
  await A.cmd('click');
  await B.cmd('click');
  a = await until(A.state, (s) => s.phase === 'unloading' && s.client.doors > 0.95 && s.find?.host && s.inv?.host, 30000);
  const idA = a.me.id;
  let b = await B.state();
  const idB = b.me.id;
  check('the run has the inventory on: four empty squares on both screens', slotsOf(a, idA) === EMPTY && slotsOf(b, idB) === EMPTY && a.inv.view.on && JSON.stringify(a.inv.view.slots) === EMPTY,
    `Ann ${slotsOf(a, idA)}, Bob ${slotsOf(b, idB)}, view ${JSON.stringify(a.inv.view)}`);
  await A.shot('1-empty-row.png');

  // A carton, by searching.
  const fin = await host('finds');
  const pieces = JSON.parse(await A.cmd('pieces'));
  const carton = pieces.filter((p) => fin.contents[String(p.id)]?.what === 'juice').sort((p, q) => fin.contents[String(p.id)].steps - fin.contents[String(q.id)].steps)[0];
  if (!carton) throw new Error('no carton on this floor');
  for (const c of [A, B]) await c.cmd('move 1 0 0 0');
  await sleep(1600);
  for (const c of [A, B]) await c.cmd('stopmove');
  a = await goTo(A, carton);
  await A.cmd('search careful');
  a = await until(A.state, (s) => slotsOf(s, idA) === ONE, 8000, 60);
  await A.cmd('search off');
  check('a carton found by searching is in slot 1, in the hand', slotsOf(a, idA) === ONE && bag(a, idA).sel === 0 && a.inv.view.inHand === 'A CARTON OF JUICE',
    `host ${slotsOf(a, idA)}, sel ${bag(a, idA)?.sel}, hand "${a.inv.view.inHand}"`);
  b = await until(B.state, (s) => slotsOf(s, idA) === ONE, 3000);
  check('Bob\'s screen has the same: Ann carries the carton', slotsOf(b, idA) === ONE, slotsOf(b, idA));
  await sleep(300);
  await A.shot('2-one-item.png');

  // Keys 1 to 4: the hand moves.
  await A.cmd('inv key 2');
  a = await until(A.state, (s) => bag(s, idA)?.sel === 1, 3000);
  check('2 puts slot 2 in the hand (the host says so)', bag(a, idA)?.sel === 1 && a.inv.view.inHand === '', `sel ${bag(a, idA)?.sel}`);
  await A.cmd('inv key 1');
  a = await until(A.state, (s) => bag(s, idA)?.sel === 0, 3000);
  check('1 puts it back', bag(a, idA)?.sel === 0, `sel ${bag(a, idA)?.sel}`);

  // G drops it; F takes it back.
  await A.cmd('inv key g');
  a = await until(A.state, (s) => (s.inv.host.pickups ?? []).length === 1 && slotsOf(s, idA) === EMPTY, 3000);
  const pk = a.inv.host.pickups[0];
  check('G drops it at her feet: a pickup, her hand empty', pk?.item === 'juice' && slotsOf(a, idA) === EMPTY && Math.hypot(pk.at.x - a.me.x, pk.at.z - a.me.z) < 0.6,
    `pickups ${JSON.stringify(a.inv.host.pickups)}, slots ${slotsOf(a, idA)}`);
  b = await until(B.state, (s) => (s.inv.host.pickups ?? []).length === 1, 3000);
  check('Bob\'s screen has the pickup too', (b.inv.host.pickups ?? []).length === 1 && b.inv.host.pickups[0].id === pk.id, JSON.stringify(b.inv.host.pickups));
  a = await until(A.state, (s) => s.inv.hudPrompt === 'F  PICK UP JUICE', 2000);
  check('standing on it: F  PICK UP JUICE', a.inv.hudPrompt === 'F  PICK UP JUICE', `prompt "${a.inv.hudPrompt}"`);
  await A.shot('4-pickup-prompt.png');
  const f1 = JSON.parse(await A.cmd('inv key f'));
  a = await until(A.state, (s) => slotsOf(s, idA) === ONE && (s.inv.host.pickups ?? []).length === 0, 3000);
  check('F takes it back', f1.ok && slotsOf(a, idA) === ONE && a.inv.host.pickups.length === 0, `key ${JSON.stringify(f1.ok)}, slots ${slotsOf(a, idA)}`);
  // A refusal: drop with the hand on an empty slot.
  await A.cmd('inv key 3');
  await until(A.state, (s) => bag(s, idA)?.sel === 2, 3000);
  await A.cmd('inv key g');
  a = await until(A.state, (s) => s.inv.view.message !== '', 3000, 30);
  check('G with nothing in hand: the host refuses, her screen says so', a.inv.view.message === 'NOTHING IN YOUR HAND.' && slotsOf(a, idA) === ONE, `message "${a.inv.view.message}"`);
  await A.cmd('inv key 1');
  await until(A.state, (s) => bag(s, idA)?.sel === 0, 3000);

  // The hand-over: Bob walks up to Ann, she faces him and presses F.
  a = await A.state();
  await B.cmd(`walkto ${a.me.cell.level} ${a.me.cell.x} ${a.me.cell.y} 3`);
  await until(B.state, (s) => s.auto !== 'walking', 60000, 150);
  b = await approach(B, a.me.x, a.me.z, 0.9);
  await A.cmd(`face ${b.me.x} ${b.me.z}`);
  a = await until(A.state, (s) => s.inv.hudPrompt === 'F  GIVE JUICE TO BOB', 3000);
  check('facing Bob within reach: F  GIVE JUICE TO BOB', a.inv.hudPrompt === 'F  GIVE JUICE TO BOB', `prompt "${a.inv.hudPrompt}", ${dist(a, b.me.x, b.me.z).toFixed(2)} m`);
  await A.shot('5-give-prompt.png');
  const f2 = JSON.parse(await A.cmd('inv key f'));
  b = await until(B.state, (s) => slotsOf(s, idB) === ONE, 3000);
  a = await until(A.state, (s) => slotsOf(s, idA) === EMPTY, 3000);
  check('F hands it over: Bob holds it, Ann does not', f2.ok && slotsOf(b, idB) === ONE && slotsOf(a, idA) === EMPTY, `Bob ${slotsOf(b, idB)}, Ann ${slotsOf(a, idA)}`);
  check('Bob is told who gave it', b.inv.view.message === 'ANN GAVE YOU A CARTON OF JUICE', `"${b.inv.view.message}"`);
  await B.shot('6-bob-holds-it.png');

  // A full row, drawn (nothing in the game can fill four slots yet).
  await A.cmd('inv demo 1 juice:1,badge:1,juice:1,badge:1');
  await sleep(300);
  a = await A.state();
  check('the demo row draws four squares', a.inv.view.demo === true, JSON.stringify(a.inv.view));
  await A.shot('3-full-row.png');
  await A.cmd('inv demo off');

  const errors = [...A.g.lines, ...B.g.lines, ...server.lines].filter((l) => /SCRIPT ERROR|ERROR: .*\.gd/.test(l));
  check('no script errors', errors.length === 0, errors.slice(0, 3).join(' | '));
  writeFileSync(join(shots, 'play_inventory.json'), JSON.stringify({ results, seed }, null, 2));
} catch (e) {
  check('the session ran to the end', false, String(e?.stack ?? e));
} finally {
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
