// The count on screen (loop/NIGHT-PLAN.md C4, T15e; docs/floors/playarea.md sections 3, 4, 7, 8, 9, 10),
// checked with two real game windows over the real network: a test server (tools/hide_server.gd: the
// home server's room, the run starting on the Playroom, floor 4) on 127.0.0.1, and two game windows (the
// engine in GODOT on this project, small, `auto=1`, a test channel each) that join through the start
// screen's own Join. Bob's link has 0.3 s of delay each way (the client's `delay=`). From BOTH screens:
//   - Bob sprints: both see count 1 start, with the same host t0, started by Bob, "sprint", and STARTED
//     BY: BOB, SPRINTING. on screen; both screens' count dark is full at the same host time (within one
//     snapshot, 0.05 s);
//   - both hide in the ball pit (F, the slow way): each is inside on both screens, sat back, and sees the
//     other drawn inside it;
//   - the bell: the Voice bus peaks once a second through the count (and Master with it: it is heard);
//   - Ann climbs out and stands in its view: she is found by sight at 1.0 s on both screens; the catch
//     fills her screen with its mask; she wakes at the party table in a paper hat;
//   - after the count, Bob walks: the health bar shows, equal to the host's number for that snapshot
//     (Ann's screen's copy of it), falling at the printed rate;
//   - in another hide, peeking, the camera turns only within the gap;
//   - Bob calls the lift: the last count; it ends with the doors open on both screens.
// Pictures in export/shots/hide/. Prints `N passed, M failed`; exit code 1 on any failure.
//   node godot/tools/play_hide.mjs [--port=4470] [--seed=hide-54] [--break=arrival|mute]
//   --break=arrival  both screens time the count from when its event arrived (hidebreak=arrival): the
//                    count-dark check must fail (Bob's link is 0.3 s slower)
//   --break=mute     both screens muted (mute=1): the bell check must fail
// Ports 4460-4479 only; the windows' test channels are on port+1 and port+2. Start .local/guard-mouse.ps1
// beside it. Every process it starts is stopped.
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
const seed = arg('seed', 'hide-54');
const brk = arg('break', '');
const godot = process.env.GODOT || join(root, 'tools', 'godot', 'Godot_v4.7.2-stable_win64_console.exe');
if (!existsSync(godot)) throw new Error(`no engine at ${godot}: set GODOT`);
const testPorts = [port + 1, port + 2];
for (const p of [port, ...testPorts]) if (!(p >= 4460 && p <= 4479)) throw new Error(`port ${p} is outside 4460-4479`);
const shots = resolve(project, 'export', 'shots', 'hide');
mkdirSync(shots, { recursive: true });
const SECRET = 'test-passphrase';
const url = `ws://127.0.0.1:${port}`;
// --headless=1: a dry run of the choreography with no windows (no pictures; the bell reads silent).
const headless = arg('headless', '0') === '1';
const extra = brk === 'arrival' ? ['hidebreak=arrival'] : brk === 'mute' ? ['mute=1'] : [];

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
const row = (s, id) => (s.seek?.players ?? []).find((p) => p.id === id);
const dist = (s, x, z) => Math.hypot(s.me.x - x, s.me.z - z);
const r3 = (x) => (typeof x === 'number' ? x.toFixed(3) : String(x));

/** Moves a player to within `near` metres of (x, z) by facing it and stepping (creep unless told). */
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

// ---- The server, on the Playroom.
const server = launch(['--headless', '--path', project, '-s', 'res://tools/hide_server.gd', '--', `port=${port}`, `seed=${seed}`, 'depth=4'], { env: { GD_JOIN_SECRET: SECRET }, echo: 'server' });
await until(async () => server.lines.join('\n'), (t) => t.includes('listening on') || server.exited, 30000);
if (!server.lines.join('\n').includes('listening on')) { console.log('the server did not start'); process.exit(1); }

let A = null;
let B = null;
try {
  A = await game('A', testPorts[0], [`join=${url}`, 'name=Ann', `pass=${SECRET}`, ...extra], '40,40');
  B = await game('B', testPorts[1], [`join=${url}`, 'name=Bob', `pass=${SECRET}`, 'delay=0.3', ...extra], '700,40');
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
  check('the run starts on the Playroom for both (floor 4)', a.place === 'playroom' && b.place === 'playroom' && a.depth === 4 && b.depth === 4 && a.seek && b.seek,
    `A ${a.place} depth ${a.depth}, B ${b.place} depth ${b.depth}, seed ${a.seed}`);
  const plan = JSON.parse(await A.cmd('plan'));
  const hides = JSON.parse(await A.cmd('hides'));
  const lx = (plan.landing.x + 0.5) * 2;
  const lz = (plan.landing.y + 0.5) * 2;
  const pits = hides.filter((h) => h.kind === 'pit' && h.level === 0).sort((p, q) => Math.hypot(p.front[0] - lx, p.front[1] - lz) - Math.hypot(q.front[0] - lx, q.front[1] - lz));
  const pit = pits[0];
  console.log(`  the ball pit: hide ${pit.id}, zone ${pit.zone}, front ${pit.front}, inside ${pit.inside}`);
  const other = hides.filter((h) => h.zone === pit.zone && h.id !== pit.id && h.kind !== 'pit')[0] ?? hides.filter((h) => h.kind !== 'pit' && h.level === 0).sort((p, q) => Math.hypot(p.front[0] - pit.front[0], p.front[1] - pit.front[1]) - Math.hypot(q.front[0] - pit.front[0], q.front[1] - pit.front[1]))[0];

  // ---- 1. Out of the car and over to the ball pit, creeping (silent). Nothing has started a count.
  for (const c of [A, B]) {
    await c.cmd('move 1 0 0 1');
  }
  await sleep(1800);
  await A.cmd('stopmove');
  await B.cmd('stopmove');
  await Promise.all([walkCell(A, pit.front[0], pit.front[1], 1.1, 'creep'), walkCell(B, pit.front[0], pit.front[1], 1.1, 'creep')]);
  a = await approach(A, pit.front[0] + 0.3, pit.front[1]);
  b = await approach(B, pit.front[0] - 0.3, pit.front[1]);
  check('creeping over to the ball pit started no count', a.seek.n === 0 && b.seek.n === 0, `count number on A ${a.seek.n}, on B ${b.seek.n}; A ${r3(dist(a, ...pit.front))} m, B ${r3(dist(b, ...pit.front))} m from its front`);
  await A.cmd(`face ${lx} ${lz} 1.4`);

  // ---- 2. Bob sprints, for a moment.
  await B.cmd('move 0 1 1 0');
  await sleep(160);
  await B.cmd('stopmove');
  a = await until(A.state, (s) => s.countEvent?.n === 1, 6000, 20);
  b = await until(B.state, (s) => s.countEvent?.n === 1, 6000, 20);
  const evA = a.countEvent ?? {};
  const evB = b.countEvent ?? {};
  check('one sprint starts the count: both screens have it, the same host t0, started by Bob, sprinting', evA.n === 1 && evB.n === 1 && evA.t0 === evB.t0 && evA.by === idB && evB.by === idB && evA.why === 'sprint',
    `A: n ${evA.n} t0 ${r3(evA.t0)} by ${evA.by} why ${evA.why}; B: n ${evB.n} t0 ${r3(evB.t0)} by ${evB.by} why ${evB.why}`);
  // The lights going: a picture as the banks go.
  a = await until(A.state, (s) => s.hide.dark >= 0.25, 4000, 15);
  await A.shot('01-hide-the-lights-going.png');
  check('HIDE, and who started it, on both screens', /BOB, SPRINTING/.test(a.hud.countBy) && /^HIDE/.test(a.hud.countText) && a.captions.includes('HIDE.')
    && /BOB, SPRINTING/.test((await B.state()).hud.countBy), `A shows "${a.hud.countText}" / "${a.hud.countBy}", dark ${a.hide.dark}; captions ${a.captions.join(' ')}`);
  // Both get in (F, the slow way): during the 6 s nothing counts.
  b = await approach(B, pit.front[0], pit.front[1], 0.6);
  await A.cmd('hide');
  await B.cmd('hide');
  a = await until(A.state, (s) => s.hide.darkFullAt?.['1'] !== undefined, 4000, 20);
  b = await until(B.state, (s) => s.hide.darkFullAt?.['1'] !== undefined, 4000, 20);
  const fullA = a.hide.darkFullAt?.['1'];
  const fullB = b.hide.darkFullAt?.['1'];
  check('count dark is full at the same host time on both screens (within one snapshot), with 0.3 s more delay on Bob\'s link',
    fullA !== undefined && fullB !== undefined && Math.abs(fullA - fullB) <= 0.05,
    `full dark at host ${r3(fullA)} on A, ${r3(fullB)} on B (${r3(Math.abs(fullA - fullB))} s apart); first seen at ${r3(a.hide.seenAt?.['1'])} on A, ${r3(b.hide.seenAt?.['1'])} on B; t0 ${r3(evA.t0)}`);
  a = await until(A.state, (s) => s.mySeek?.phase === 'inside', 5000);
  b = await until(B.state, (s) => s.mySeek?.phase === 'inside', 5000);
  const inA = row(b, idA);
  const inB = row(a, idB);
  check('both are in the ball pit, on both screens', a.mySeek?.phase === 'inside' && b.mySeek?.phase === 'inside' && a.mySeek.hide === pit.id && b.mySeek.hide === pit.id && inA?.hide === pit.id && inB?.hide === pit.id,
    `A ${a.mySeek?.phase} in ${a.mySeek?.hide}, B ${b.mySeek?.phase} in ${b.mySeek?.hide}`);
  await sleep(500);
  a = await A.state();
  b = await B.state();
  const figB = (a.others ?? []).find((o) => o.id === idB);
  const figA = (b.others ?? []).find((o) => o.id === idA);
  const inPit = (f) => f && f.drawn && f.hide === pit.id && Math.hypot(f.at[0] - pit.inside[0], f.at[2] - pit.inside[1]) < 0.9 && f.at[1] < -0.3 && f.clip === 'sneak';
  check('each sees the other drawn in the ball pit (crouched, sunk to the balls, beside them)', inPit(figB) && inPit(figA),
    `on A: Bob at ${figB?.at?.map(r3)} drawn ${figB?.drawn} clip ${figB?.clip}; on B: Ann at ${figA?.at?.map(r3)} drawn ${figA?.drawn} clip ${figA?.clip}; the pit at ${pit.inside}`);
  check('sat back: the camera low in the pit, the dark inside drawn', a.hide.overlay === 'sat' && a.hideCam?.peek === false && a.camPos[1] - a.me.y < 0.45,
    `overlay ${a.hide.overlay} (${a.hide.overlayKind}), eye ${r3(a.camPos[1] - a.me.y)} m`);
  await A.shot('02-sat-back-in-the-ball-pit.png');
  await A.cmd('peek 1');
  await sleep(400);
  await A.shot('02b-ann-peeks-sees-bob-in-the-pit.png');
  await A.cmd('peek 0');

  // ---- 3. The count: the bell once a second (on Bob's screen, a quiet stretch with no number said).
  const tS = evA.t0 + 6;
  b = await until(B.state, (s) => s.hostNow >= tS + 2.6, 12000, 50);
  await B.cmd('peaklog on');
  // Meanwhile Ann climbs out and stands in its view.
  a = await until(A.state, (s) => s.hostNow >= tS + 0.2, 8000, 30);
  await A.cmd('hide');
  a = await until(A.state, (s) => s.mySeek?.phase === 'out', 4000, 30);
  await sleep(5500);
  await B.cmd('peaklog off');
  const log = JSON.parse(await B.cmd('peaklog get'));
  const onsets = (k) => {
    const out = [];
    for (let i = 3; i < log.length; i++) {
      const before = Math.min(log[i - 1][k], log[i - 2][k], log[i - 3][k]);
      if (log[i][k] > -45 && log[i][k] - before >= 9 && (out.length === 0 || log[i][0] - out[out.length - 1] > 0.4)) out.push(log[i][0]);
    }
    return out;
  };
  const vOn = onsets(2);
  const gaps = vOn.slice(1).map((t, i) => t - vOn[i]);
  const loud = vOn.map((t) => { const r = log.find((x) => x[0] >= t); return r ? r[3] : -200; });
  check('the bell: the Voice bus peaks once a second through the count, and Master with it (it is heard)',
    vOn.length >= 4 && gaps.every((g) => g > 0.8 && g < 1.2) && loud.every((m) => m > -60),
    `${vOn.length} strokes in ${log.length ? r3(log[log.length - 1][0] - log[0][0]) : 0} s, gaps ${gaps.map(r3).join(' ')} s; Master at each ${loud.map((m) => m.toFixed(1)).join(' ')} dB`);

  // ---- 4. Ann in its view: found by sight at 1.0 s on both screens. Bob peeks at it coming.
  let bobPeekShot = false;
  let foundA = null;
  let foundB = null;
  let catchShot = false;
  let steer = 0;
  const t4 = Date.now();
  while (Date.now() - t4 < 32000) {
    a = await A.state();
    b = await B.state();
    const ra = row(a, idA);
    const rb = row(b, idA);
    if (!foundA && ra && ra.status !== 'ok') foundA = { ...ra };
    if (!foundB && rb && rb.status !== 'ok') foundB = { ...rb };
    if (foundA && foundB && a.mySeek?.status === 'taken') break;
    if (a.mySeek?.status === 'found' && !catchShot && a.hide.catch > 0.7) { catchShot = true; await A.shot('05-found-the-mask-fills-the-screen.png'); }
    const o = b.orderly;
    if (!bobPeekShot && b.mySeek?.phase === 'inside' && o.pose && o.distance < 12 && o.distance > 7) {
      await B.cmd('peek 1');
      await B.cmd(`face ${o.x} ${o.z} ${o.pose.y + 1.5}`);
      await sleep(250);
      const bb = await B.state();
      if (bb.mySeek?.peek && (bb.mySeek?.gap ?? 0) < 0.8) { await B.shot('03-peeking-the-minders-mask.png'); bobPeekShot = true; }
      await B.cmd('peek 0');
    }
    // Ann stands in its view: if it is far off and has not seen her, she goes to stand in front of it,
    // 6.5 m off; once it comes for her she backs away at its own pace, facing it, so it is its sight that
    // finds her and not its touch.
    if (a.mySeek?.status === 'ok' && a.mySeek?.phase === 'out' && a.orderly.pose) {
      const o2 = a.orderly;
      if (o2.distance < 5.0) {
        await A.cmd(`face ${o2.x} ${o2.z} ${o2.pose.y + 1.4}`);
        await A.cmd('move -1 0 0 0');
      } else if (Date.now() - t4 > 6000 && (a.mySeek?.sight ?? 0) === 0) {
        const y = o2.pose.yaw;
        const fx = o2.x - Math.sin(y) * 6.5;
        const fz = o2.z - Math.cos(y) * 6.5;
        if (Date.now() - steer > 400) { steer = Date.now(); await A.cmd(`face ${fx} ${fz}`); await A.cmd(dist(a, fx, fz) > 0.8 ? 'move 1 0 0 0' : 'stopmove'); }
      } else {
        await A.cmd('stopmove');
        await A.cmd(`face ${o2.x} ${o2.z} ${o2.pose.y + 1.4}`);
      }
    }
    await sleep(40);
  }
  await A.cmd('stopmove');
  check('Ann, standing in its view, is found by sight at 1.0 s on both screens', foundA && foundB && foundA.status === 'found' && foundB.status === 'found' && Math.abs(foundA.sight - 1) <= 0.06 && Math.abs(foundB.sight - 1) <= 0.06,
    `on A: ${foundA?.status} at sight ${r3(foundA?.sight)}; on B: ${foundB?.status} at sight ${r3(foundB?.sight)}`);
  a = await A.state();
  b = await B.state();
  check('FOUND YOU, ANN! on both screens', a.captions.includes('FOUND YOU, ANN!') && b.captions.includes('FOUND YOU, ANN!'), `A: ${a.captions.slice(-4).join(' / ')}; B: ${b.captions.slice(-4).join(' / ')}`);
  check('the catch: her screen filled with its mask', catchShot, `catch ${a.hide.catch}`);
  check('Bob peeked at it coming, its mask in view, and was not found', bobPeekShot && b.mySeek?.status === 'ok', `Bob ${b.mySeek?.status}, gap ${b.mySeek?.gap}`);
  a = await until(A.state, (s) => s.mySeek?.status === 'taken', 15000);
  await sleep(1500);
  a = await A.state();
  b = await B.state();
  const annOnB = (b.others ?? []).find((o) => o.id === idA);
  check('Ann is taken: at the party table, in a paper hat, watching (and Bob\'s screen draws her hat)', a.mySeek?.status === 'taken' && a.mySeek.seat >= 0 && a.hide.hat && annOnB?.hat === true && b.hide.hats.includes(idA),
    `seat ${a.mySeek?.seat}, own hat ${a.hide.hat}, on Bob's screen hat ${annOnB?.hat}`);
  await A.shot('06-the-party-table.png');

  // ---- 5. The count ends; Bob climbs out and walks: the health bar, the host's number, the rates.
  b = await until(B.state, (s) => s.hide.phase === 'over' && s.seek.ended >= 1, 40000, 100);
  check('the count ends on Bob\'s screen: ALL DONE!, the lights back', b.captions.includes('ALL DONE!') && b.mySeek?.status === 'ok', `ended ${b.seek.ended}, Bob ${b.mySeek?.status}, captions ${b.captions.slice(-3).join(' / ')}`);
  await B.cmd('hide');
  b = await until(B.state, (s) => s.mySeek?.phase === 'out', 4000);
  const h0 = b.mySeek.health;
  await B.cmd(`face ${lx} ${lz}`);
  await B.cmd('move 1 0 0 0');
  await sleep(2200);
  b = await B.state();
  await B.cmd('stopmove');
  // The same snapshot on Ann's screen: the host's number for Bob at that tick (her screen keeps the last few).
  const hist = (await A.state()).seekHist ?? [];
  const same = hist.find((h) => h[0] === b.t);
  const hostNum = same ? same[1][idB] : undefined;
  check('the health bar shows after the count, and is the host\'s number (Bob\'s own snapshot, and Ann\'s copy of the same tick)',
    b.hud.health >= 0 && b.hud.health === b.mySeek.health && hostNum !== undefined && Math.abs(hostNum - b.hud.health) < 0.011 && /WALK -3\/S/.test(b.hud.rates),
    `bar ${b.hud.health}, Bob's snapshot ${b.mySeek.health}, Ann's copy of tick ${r3(b.t)} ${hostNum ?? 'not in her last snapshots'}; rates "${b.hud.rates}"`);
  check('walking drains it at the printed rate (3 a second)', h0 - b.hud.health > 3 && h0 - b.hud.health < 8, `${h0} to ${b.hud.health} over about 2 s of walking`);
  await B.cmd(`face ${pit.inside[0]} ${pit.inside[1]} 0.6`);
  await sleep(300);
  await B.shot('04-the-health-bar.png');

  // ---- 6. Peeking from a hide with a narrow gap: the camera turns only within the gap.
  b = await walkCell(B, other.front[0], other.front[1], 1.1, 'creep');
  b = await approach(B, other.front[0], other.front[1], 0.5);
  await B.cmd('hide');
  b = await until(B.state, (s) => s.mySeek?.phase === 'inside', 5000);
  await B.cmd('peek 1');
  b = await until(B.state, (s) => s.mySeek?.peek === true, 3000, 50);
  const gy = b.hideCam?.gapYaw ?? 0;
  await B.cmd(`look ${((gy + 2.6) * 180) / Math.PI} 0`);
  await sleep(300);
  b = await B.state();
  const rel = Math.atan2(Math.sin(b.client.yaw - gy), Math.cos(b.client.yaw - gy));
  check(`peeking from the ${other.kind}, the camera turns only within its gap`, b.mySeek?.peek === true && b.hideCam?.peek === true && Math.abs(rel) <= (b.hideCam?.gapHalf ?? 0) + 1e-3 && b.hide.overlay === 'peek',
    `asked for ${r3(2.6)} rad off the gap, drawn ${r3(rel)} rad (gap half ${r3(b.hideCam?.gapHalf)}), peek ${b.mySeek?.peek}, overlay ${b.hide.overlay}`);
  await B.shot('07-peeking-through-the-gap.png');
  await B.cmd('peek 0');
  await B.cmd('hide');
  b = await until(B.state, (s) => s.mySeek?.phase === 'out', 4000);

  // ---- 7. The last count: Bob calls the lift, hides again; it ends with the doors open on both.
  b = await walkCell(B, lx, lz, 1.1, 'creep');
  await B.cmd(`face ${plan.car.doorX} ${plan.car.doorZ} 1.6`);
  b = await approach(B, plan.car.doorX - plan.car.inX * 1.0, plan.car.doorZ - plan.car.inZ * 1.0, 0.4);
  b = await until(B.state, (s) => s.me.canCall === true, 6000);
  await B.cmd('call');
  b = await until(B.state, (s) => s.countEvent?.n === 2, 6000, 30);
  a = await until(A.state, (s) => s.countEvent?.n === 2, 6000, 30);
  check('the call starts the last count on both screens', b.countEvent?.last === true && a.countEvent?.last === true && b.countEvent?.t0 === a.countEvent?.t0 && b.phase === 'coming',
    `B: n ${b.countEvent?.n} last ${b.countEvent?.last} why ${b.countEvent?.why}, phase ${b.phase}; A: last ${a.countEvent?.last}`);
  b = await walkCell(B, pit.front[0], pit.front[1], 5, 'sprint');
  b = await approach(B, pit.front[0], pit.front[1], 0.6, 'walk');
  await B.cmd('hide');
  b = await until(B.state, (s) => s.mySeek?.phase === 'inside', 5000);
  const tl = b.countEvent.t0 + 6 + b.countEvent.len;
  a = await until(A.state, (s) => s.doorsOpen === true && s.phase === 'boarding', 70000, 200);
  b = await until(B.state, (s) => s.doorsOpen === true && s.phase === 'boarding', 5000, 100);
  check('the last count ends with the doors open, on both screens', a.doorsOpen && b.doorsOpen && a.hostNow >= tl - 0.1 && b.mySeek?.status === 'ok',
    `A ${a.phase} doors ${a.doorsOpen} at host ${r3(a.hostNow)} (the count ended at ${r3(tl)}); B ${b.phase} doors ${b.doorsOpen}, Bob ${b.mySeek?.status}`);
  writeFileSync(join(shots, 'play_hide.json'), JSON.stringify({ results, seed, brk }, null, 2));
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
