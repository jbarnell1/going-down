// Ready-up on screen (docs/floors/findables-and-day.md section 2, FD5 and FD6), checked with real game windows
// over the real network: the home server (server/server.tscn, quota=0 so the scripted call works) on
// 127.0.0.1, and game windows (the engine in GODOT on this project, small, `auto=1`, a test channel each) that
// join through the start screen's own Join: Ann (first in the room: the host) and Bob, then Cy mid-floor.
//   1. Both land on Ready-up, not in the car: the controls card and the crew. Under auto=1 no tape plays.
//      Ann presses READY: Bob's list says ANN READY, BOB READING, with Ann as the host. No count, no car.
//   2. Bob presses READY: GOING DOWN IN n on both; neither shows the car before both pressed READY.
//   3. Both show the car within 0.5 s of each other. No controls menu and no voice line in the first 2 s; the
//      welcome starts at least 2 s after this screen first drew the car, and after the other screen did too.
//   4. Cy joins mid-floor: Ready-up with THE CREW IS ON FLOOR 1. YOU JOIN AT THE NEXT STOP. and the crew DOWN
//      THERE. Still reading, then ready, Cy stays out until the car next arrives; then Cy is in the car.
// Pictures in export/shots/ready/: the card with the crew list, the count, both in the car, the late joiner's
// waiting line. Prints `N passed, M failed`; exit code 1 on any failure.
//   node godot/tools/play_ready.mjs [--port=4470] [--seed=ready-1] [--headless=1]
//   --headless=1  a dry run with no windows (no pictures)
// Ports 4460-4479 only: the server on port, the windows' test channels on port+1..port+3. With windows, start
// .local/guard-mouse.ps1 beside it. Every process it starts is stopped.
import { spawn } from 'node:child_process';
import { existsSync, mkdirSync } from 'node:fs';
import { connect } from 'node:net';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const here = dirname(fileURLToPath(import.meta.url));
const project = resolve(here, '..');
const root = resolve(project, '..');
const arg = (k, d) => (process.argv.find((a) => a.startsWith(`--${k}=`)) ?? `--${k}=${d}`).split('=')[1];
const port = Number(arg('port', 4470));
const seed = arg('seed', 'ready-1');
const headless = arg('headless', '0') === '1';
const godot = process.env.GODOT || join(root, 'tools', 'godot', 'Godot_v4.7.2-stable_win64_console.exe');
if (!existsSync(godot)) throw new Error(`no engine at ${godot}: set GODOT`);
const testPorts = [port + 1, port + 2, port + 3];
for (const p of [port, ...testPorts]) if (!(p >= 4460 && p <= 4479)) throw new Error(`port ${p} is outside 4460-4479`);
const shots = resolve(project, 'export', 'shots', 'ready');
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
  // At most 60 s (a refused connection can take seconds on Windows, so count time, not tries).
  const end = Date.now() + 60000;
  for (let i = 0; i < 300 && !sock && isAlive() && Date.now() < end; i++) {
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
const row = (s, name) => (scr(s).people ?? []).find((p) => p[1] === name);
const stateOf = (r) => (!r ? '?' : r[4] ? 'DOWN THERE' : r[2] ? 'READY' : r[3] ? 'WATCHING THE TAPE' : 'READING');
const tapeSeen = new Set();
const watchTape = (label, s) => { if (scr(s).screen === 'tape' || scr(s).tapePlaying) tapeSeen.add(label); return s; };

// ---- The server.
const server = launch(['--headless', '--path', project, 'res://server/server.tscn', '--', 'server', `port=${port}`, 'bind=127.0.0.1', `seed=${seed}`, 'quota=0', 'orientation_campaign=0'], { env: { GD_JOIN_SECRET: SECRET }, echo: 'server' });
await until(async () => server.lines.join('\n'), (t) => t.includes('listening on') || server.exited, 30000);
if (!server.lines.join('\n').includes('listening on')) { console.log('the server did not start'); process.exit(1); }

let A = null;
let B = null;
let C = null;
try {
  A = await game('A', testPorts[0], [`join=${url}`, 'name=Ann', `pass=${SECRET}`], '40,40');
  await until(A.state, (s) => scr(s).screen === 'face', 30000);
  await A.cmd('draw done');
  await until(A.state, (s) => watchTape('A', s) && scr(s).screen === 'lobby' && (scr(s).people ?? []).length >= 1, 30000);
  B = await game('B', testPorts[1], [`join=${url}`, 'name=Bob', `pass=${SECRET}`], '700,40');
  await until(B.state, (s) => scr(s).screen === 'face', 30000);
  await B.cmd('draw done');
  let a = await until(A.state, (s) => watchTape('A', s) && scr(s).screen === 'lobby' && (scr(s).people ?? []).length >= 2, 30000);
  let b = await until(B.state, (s) => watchTape('B', s) && scr(s).screen === 'lobby' && (scr(s).people ?? []).length >= 2, 30000);

  // ---- 1. Ready-up, not the car.
  check('both land on Ready-up (the card and the crew), not in the car', scr(a).screen === 'lobby' && scr(b).screen === 'lobby' && !inGame(a) && !inGame(b)
    && (scr(a).card ?? []).length >= 8, `A ${scr(a).screen}, B ${scr(b).screen}, card rows ${(scr(a).card ?? []).length}`);
  check('under auto=1 the orientation tape never played', tapeSeen.size === 0, `played on ${[...tapeSeen].join(', ')}`);
  check('the first in the room is the host, on both screens', scr(a).host === scr(a).me && scr(b).host === scr(a).me, `host ${scr(a).host}/${scr(b).host}, Ann ${scr(a).me}`);
  await A.cmd('ready');
  b = await until(B.state, (s) => row(s, 'Ann')?.[2] === true, 5000);
  check("Ann presses READY: Bob's list says ANN READY, BOB READING", stateOf(row(b, 'Ann')) === 'READY' && stateOf(row(b, 'Bob')) === 'READING', `Ann ${stateOf(row(b, 'Ann'))}, Bob ${stateOf(row(b, 'Bob'))}`);
  await sleep(400);
  await B.shot('1-ready-up-card-and-crew.png');
  await sleep(1500);
  a = await A.state();
  b = await B.state();
  check('one of two ready: no count and nobody in the car', !inGame(a) && !inGame(b) && scr(a).countLeft < 0 && scr(a).line === '', `A line "${scr(a).line}", countLeft ${scr(a).countLeft}`);

  // ---- 2. Bob ready: the count; nobody in the car before both pressed.
  await B.cmd('ready');
  a = await until(A.state, (s) => /^GOING DOWN IN [1-5]$/.test(scr(s).line ?? ''), 4000, 40);
  b = await B.state();
  check('both ready: GOING DOWN IN n on both screens', /^GOING DOWN IN [1-5]$/.test(scr(a).line) && /^GOING DOWN IN [1-5]$/.test(scr(b).line), `A "${scr(a).line}", B "${scr(b).line}"`);
  await A.shot('2-going-down-in.png');
  // Both screens sampled until each shows the car.
  const entered = {};
  const t0 = Date.now();
  while (Date.now() - t0 < 15000 && (!entered.A || !entered.B)) {
    for (const [c, k] of [[A, 'A'], [B, 'B']]) {
      const s = await c.state();
      if (inGame(s) && !entered[k]) entered[k] = s;
    }
    await sleep(20);
  }
  const waited = (Date.now() - t0) / 1000;
  check('both show the car once the count is done (and not before both pressed READY: step 1)', entered.A && entered.B && waited > 2.5, `A ${!!entered.A}, B ${!!entered.B}, ${waited.toFixed(1)} s after the count showed`);
  const ea = scr(entered.A ?? {}).entry ?? {};
  const eb = scr(entered.B ?? {}).entry ?? {};
  check('both show the car within 0.5 s of each other', Math.abs(ea.enteredUnix - eb.enteredUnix) < 500, `apart ${Math.abs(ea.enteredUnix - eb.enteredUnix).toFixed(0)} ms`);

  // ---- 3. In the car: no menu, no voice in the first 2 s; the welcome after both screens drew the car.
  await A.cmd('click');
  await B.cmd('click');
  a = await until(A.state, (s) => s.phase === 'unloading' && s.client.doors > 0.95, 15000);
  b = await B.state();
  await A.cmd(`face ${b.me.x} ${b.me.z} 1.5`);
  await sleep(500);
  await A.shot('3-both-in-the-car.png');
  a = await until(A.state, (s) => scr(s).entry?.welcomeUnix !== undefined, 8000);
  b = await until(B.state, (s) => scr(s).entry?.welcomeUnix !== undefined, 8000);
  const xa = scr(a).entry;
  const xb = scr(b).entry;
  check('both aboard on floor 1, each seeing the other', a.me.aboard && b.me.aboard && a.depth === 1 && (a.others ?? []).some((o) => o.id === b.me.id), `A aboard ${a.me.aboard}, B aboard ${b.me.aboard}, depth ${a.depth}`);
  check('no controls menu and no voice line in the first 2 s of the run, on either screen', !xa.menuEarly && !xb.menuEarly && !xa.voiceEarly && !xb.voiceEarly && a.client.menu === false,
    `menu ${xa.menuEarly}/${xb.menuEarly}, voice ${xa.voiceEarly}/${xb.voiceEarly}`);
  check('the welcome starts 2 s after each screen first drew the car, and after the other screen drew it too',
    xa.welcomeUnix - xa.carUnix >= 1950 && xb.welcomeUnix - xb.carUnix >= 1950 && xa.welcomeUnix > xb.carUnix && xb.welcomeUnix > xa.carUnix,
    `A ${(xa.welcomeUnix - xa.carUnix).toFixed(0)} ms after its car, B ${(xb.welcomeUnix - xb.carUnix).toFixed(0)} ms; A's welcome ${(xa.welcomeUnix - xb.carUnix).toFixed(0)} ms after B's car`);

  // ---- 4. A late joiner.
  C = await game('C', testPorts[2], [`join=${url}`, 'name=Cy', `pass=${SECRET}`], '370,420');
  await until(C.state, (s) => scr(s).screen === 'face', 30000);
  await C.cmd('draw done');
  let c = await until(C.state, (s) => watchTape('C', s) && scr(s).screen === 'lobby' && /JOIN AT THE NEXT STOP/.test(scr(s).line ?? ''), 30000);
  check('the late joiner gets Ready-up with THE CREW IS ON FLOOR 1. YOU JOIN AT THE NEXT STOP.', scr(c).line === 'THE CREW IS ON FLOOR 1. YOU JOIN AT THE NEXT STOP.' && !inGame(c),
    `"${scr(c).line}", in game ${inGame(c)}`);
  check('and sees the crew down there', stateOf(row(c, 'Ann')) === 'DOWN THERE' && stateOf(row(c, 'Bob')) === 'DOWN THERE' && stateOf(row(c, 'Cy')) === 'READING', `Ann ${stateOf(row(c, 'Ann'))}, Bob ${stateOf(row(c, 'Bob'))}, Cy ${stateOf(row(c, 'Cy'))}`);
  await sleep(400);
  await C.shot('4-late-joiner-waiting.png');
  await sleep(1500);
  c = await C.state();
  check('still reading while the run is on: not dropped in', !inGame(c) && scr(c).screen === 'lobby', `screen ${scr(c).screen}`);
  await C.cmd('ready');
  await sleep(2000);
  c = await C.state();
  check('ready, but no stop yet: still waiting on Ready-up', !inGame(c) && scr(c).screen === 'lobby' && scr(c).ready === true, `screen ${scr(c).screen}, ready ${scr(c).ready}`);
  // Out of the car (it waits while anyone is aboard), then Ann calls it back.
  const plan = JSON.parse(await A.cmd('plan'));
  const car = plan.car;
  for (const g of [A, B]) {
    await g.cmd(`face ${car.doorX - car.inX * 3} ${car.doorZ - car.inZ * 3}`);
    await g.cmd('move 1 0 0 0');
  }
  await sleep(1800);
  for (const g of [A, B]) await g.cmd('stopmove');
  a = await until(A.state, (s) => s.phase === 'away', 20000, 100);
  await A.cmd(`walkto ${plan.landing.level} ${plan.landing.x} ${plan.landing.y} 3`);
  await until(A.state, (s) => s.auto !== 'walking', 20000);
  await A.cmd(`face ${car.doorX} ${car.doorZ} 2.0`);
  a = await until(A.state, (s) => s.me.canCall === true, 20000);
  await A.cmd('call');
  a = await until(A.state, (s) => s.phase === 'coming' || s.phase === 'arriving', 8000, 50);
  check('Ann calls the car', a.phase === 'coming' || a.phase === 'arriving', `phase ${a.phase}, canCall ${a.me.canCall}`);
  const t1 = Date.now();
  while (Date.now() - t1 < 150000) {
    a = await A.state();
    c = await C.state();
    if (inGame(c)) break;
    await sleep(100);
  }
  // The next stop may be the prison (a wipe in the wait sends the crew home): the host admits there too.
  check('the late joiner arrives at the next stop, in the car (not while it was still coming)', inGame(c) && a.phase !== 'coming' && c.me.aboard === true,
    `in game ${inGame(c)}, aboard ${c.me?.aboard}, depth ${c.depth}, Ann's phase just before ${a.phase}, ${((Date.now() - t1) / 1000).toFixed(0)} s after the call`);
  check('under auto=1 no screen ever played the tape', tapeSeen.size === 0, `played on ${[...tapeSeen].join(', ')}`);
} catch (e) {
  check('the playthrough ran to the end', false, e.stack ?? String(e));
} finally {
  for (const c of [A, B, C]) if (c) await c.close();
  server.p.kill();
}
const bad = results.filter((r) => !r.ok).length;
console.log(`${results.length - bad} passed, ${bad} failed`);
process.exit(bad ? 1 : 0);
