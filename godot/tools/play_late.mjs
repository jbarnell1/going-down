// The late floors over the real network (PL1): the Hanging Ward (floor 6) and the Reactor (floor 7) as normal
// levels, with two headless game clients against the real dedicated server (server/server.tscn) on 127.0.0.1,
// and the fallback switches. Every check compares what the two screens hold (each client's own snapshot, read
// through its test channel: `late`, `state`) and prints PASS or FAIL with the numbers it compared.
//   Main session (server on port P, late floors on, `depth=5 quota=0`): Ann and Bob ride down from the
//   Arboretum. The Ward: the same Ward (seed, houses) on both; Ann walks out, the lift waits while Bob is still
//   in it, leaves once both are clear; the same LIFT RETURNS clock; Ann works a winch and Bob's screen sees the
//   bridge move; Ann's reading near the Rigger is the same on both; both board when the lift returns (about ten
//   minutes: the Ward's own clock, not a setting) and ride on. The Reactor: the same plan and anchors, the power
//   holds and cuts on the same host time for both, the four stir, Ann fetches the fuse while Bob goes to meet the
//   four, a catch puts Bob down, Ann heals him with F held (the host's panel first drops the four back to a crawl,
//   so a two-player crew can survive the heal), power restored, the lift called, the tape carried out, both ride
//   up and arrive in the prison. A third client (Cy) joins after the cut and is compared with Ann.
//   Fallback A (server on P+6, `ward_place=0 reactor_place=0`): one client with the packs rides to floor 6 and
//   must hand over to the old Ward scene ("FLOOR ENTERED ward").
//   Fallback B (server on P+8, `reactor_place=0`): one client walks the native Ward, boards, and on floor 7 must
//   hand over to the old Reactor scene ("FLOOR ENTERED reactor").
// The two fallbacks run beside the main session (each is mostly waiting for the Ward's lift). Prints `N passed, M
// failed`; exit code 1 on any failure. Headless only: no window opens.
//   node godot/tools/play_late.mjs [--port=4740] [--seed=late-1] [--packs=C:/new_game/.local/floor-packs]
//        [--fallback=1] [--main=1]
// Ports: P server, P+1..P+3 the main session's test channels, P+6 / P+7 fallback A, P+8 / P+9 fallback B; all
// in 4740-4759. Packs: --packs, or GD_PACKS_DIR (the private floor packs; never committed). Stops every process
// it starts, also on failure.
import { spawn } from 'node:child_process';
import { existsSync, mkdirSync, writeFileSync } from 'node:fs';
import { connect } from 'node:net';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const here = dirname(fileURLToPath(import.meta.url));
const project = resolve(here, '..');
const root = resolve(project, '..');
const arg = (k, d) => (process.argv.find((a) => a.startsWith(`--${k}=`)) ?? `--${k}=${d}`).split('=').slice(1).join('=');
const port = Number(arg('port', 4740));
const seed = arg('seed', 'late-1');
const packs = arg('packs', process.env.GD_PACKS_DIR || 'C:/new_game/.local/floor-packs');
const doMain = arg('main', '1') === '1';
const doFallback = arg('fallback', '1') === '1';
/** --save-logs=DIR: every line the main session's server and clients printed, for reading after a failure. */
const saveLogs = arg('save-logs', '');
/** Test only: invert one comparison (the two clocks must differ) to prove the tool can fail. */
const breakClock = arg('break', '') === 'clock';
const godot = process.env.GODOT || join(root, 'tools', 'godot', 'Godot_v4.7.2-stable_win64_console.exe');
if (!existsSync(godot)) throw new Error(`no engine at ${godot}: set GODOT`);
const P = { server: port, A: port + 1, B: port + 2, C: port + 3, fa: port + 6, fa1: port + 7, fb: port + 8, fb1: port + 9 };
for (const p of [...(doMain ? [P.server, P.A, P.B, P.C] : []), ...(doFallback ? [P.fa, P.fa1, P.fb, P.fb1] : [])]) if (!(p >= 4740 && p <= 4759)) throw new Error(`port ${p} is outside 4740-4759`);
const SECRET = 'test-passphrase';
const havePacks = existsSync(join(packs, 'WardGroundMedia.pck'));

const procs = new Set();
const cleanup = () => { for (const p of procs) { try { p.kill(); } catch { /* gone */ } } };
process.on('exit', cleanup);
process.on('SIGINT', () => { cleanup(); process.exit(1); });
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const T0 = Date.now();
const log = (s) => console.log(`[${((Date.now() - T0) / 1000).toFixed(0).padStart(4)} s] ${s}`);

function launch(args, opts = {}) {
  const p = spawn(godot, args, { cwd: root, env: { ...process.env, ...(opts.env || {}) }, stdio: ['ignore', 'pipe', 'pipe'] });
  procs.add(p);
  const lines = [];
  const keep = (b) => { for (const l of String(b).split(/\r?\n/)) if (l.trim()) { lines.push(l); if (opts.echo && opts.echo.test(l)) log(`  [${opts.label}] ${l}`); } };
  p.stdout.on('data', keep);
  p.stderr.on('data', keep);
  let exited = false;
  p.on('exit', () => { exited = true; procs.delete(p); });
  return { p, lines, get exited() { return exited; } };
}

async function line(portN, label, isAlive) {
  let sock = null;
  for (let i = 0; i < 400 && !sock && isAlive(); i++) {
    sock = await new Promise((res) => { const s = connect(portN, '127.0.0.1', () => res(s)); s.on('error', () => res(null)); });
    if (!sock) await sleep(150);
  }
  if (!sock) throw new Error(`${label}: no line on ${portN}`);
  let buf = '';
  const waiting = [];
  sock.on('data', (d) => { buf += d; let i; while ((i = buf.indexOf('\n')) >= 0) { const l = buf.slice(0, i); buf = buf.slice(i + 1); waiting.shift()?.(l); } });
  sock.on('error', () => { while (waiting.length) waiting.shift()('{}'); });
  sock.on('close', () => { while (waiting.length) waiting.shift()('{}'); });
  let chain = Promise.resolve();
  const cmd = (c) => { const run = chain.then(() => new Promise((res) => { waiting.push(res); try { sock.write(c + '\n'); } catch { res('{}'); } })); chain = run.catch(() => {}); return run; };
  return { sock, cmd };
}

const SHOW = /FLOOR |WARD REVIEW (READY|STATE|RESULT|CONTACT)|SCRIPT ERROR|test channel/;
async function game(label, testport, args) {
  const g = launch(['--headless', '--path', project, '--', 'auto=1', `testport=${testport}`, ...(havePacks ? [`packs=${packs}`] : []), ...args], { echo: SHOW, label });
  let conn = await line(testport, label, () => !g.exited).catch((e) => { throw new Error(`${e.message} (${g.lines.slice(-5).join(' | ')})`); });
  const c = {
    label, g,
    cmd: (x) => conn.cmd(x),
    state: async () => { try { return JSON.parse(await conn.cmd('state')); } catch { return {}; } },
    late: async () => { try { return JSON.parse(await conn.cmd('late')); } catch { return {}; } },
    /** After a scene hand back the channel is opened again by the new main scene. */
    reconnect: async () => { try { conn.sock.destroy(); } catch { /* */ } conn = await line(testport, label, () => !g.exited); },
    close: async () => { try { conn.sock.write('quit\n'); } catch { /* closed */ } await sleep(500); if (!g.exited) g.p.kill(); try { conn.sock.destroy(); } catch { /* */ } },
  };
  return c;
}

function server(p, label, extra) {
  return launch(['--headless', '--path', project, 'res://server/server.tscn', '--', 'server', `port=${p}`, 'bind=127.0.0.1', `seed=${seed}`, 'stats=30',
    'quota=0', 'watchers=0', 'orientation_campaign=0', 'depth=5', ...extra], { env: { GD_JOIN_SECRET: SECRET }, echo: /TEST:|not started|listening/, label });
}

const results = [];
const check = (name, ok, detail = '') => { results.push({ name, ok: !!ok, detail }); log(`${ok ? 'PASS' : 'FAIL'} ${name}${detail ? ` (${detail})` : ''}`); return !!ok; };
const skip = (name, why) => log(`NOT COVERED ${name} (${why})`);
async function until(fn, pred, ms = 30000, every = 80) {
  const end = Date.now() + ms;
  let v = await fn();
  while (!pred(v) && Date.now() < end) { await sleep(every); v = await fn(); }
  return v;
}
const scr = (s) => s.screen ?? {};
const inGame = (s) => s.phase !== undefined && s.phase !== null;
const J = (x) => JSON.stringify(x);
const r2 = (x) => (typeof x === 'number' ? x.toFixed(2) : String(x));
const flat = (a, b) => Math.hypot(a[0] - b[0], a[2] - b[2]);
const evOf = (l, ty) => (l.events ?? []).filter((e) => e.type === ty);
const clockSecs = (line) => { const m = /LIFT RETURNS IN (\d+):(\d\d)/.exec(line ?? ''); return m ? Number(m[1]) * 60 + Number(m[2]) : NaN; };

/** Both screens read until they report the same host tick (or the closest pair after `tries`). */
async function sameTick(x, y, tries = 60) {
  let best = null;
  for (let i = 0; i < tries; i++) {
    const [a, b] = await Promise.all([x.late(), y.late()]);
    const gap = Math.abs((a.tick ?? 0) - (b.tick ?? 0));
    if (!best || gap < best.gap) best = { a, b, gap };
    if (gap === 0) break;
    await sleep(7);
  }
  return best;
}

/** Joins a client through the start screen; resolves on the lobby. */
async function joinRoom(label, testport, url, name, extra = []) {
  const c = await game(label, testport, [`join=${url}`, `name=${name}`, `pass=${SECRET}`, ...extra]);
  await until(c.state, (s) => scr(s).screen === 'face', 40000);
  await c.cmd('draw done');
  await until(c.state, (s) => scr(s).screen === 'lobby' || inGame(s), 30000);
  return c;
}

/** Plan-floor steps: out of the car, call, board on the given side (play_day.mjs's moves). */
async function stepOut(cs) {
  for (const c of cs) {
    const p = JSON.parse(await c.cmd('plan')).car;
    await c.cmd(`face ${p.doorX - p.inX * 3} ${p.doorZ - p.inZ * 3}`);
    await c.cmd('move 1 0 0 0');
  }
  await sleep(1800);
  for (const c of cs) await c.cmd('stopmove');
}
async function callLift(c, ms = 30000) {
  const pl = JSON.parse(await c.cmd('plan'));
  await c.cmd(`walkto ${pl.landing.level} ${pl.landing.x} ${pl.landing.y} 3`);
  await until(c.state, (s) => s.auto !== 'walking', 30000);
  const car = pl.car;
  await c.cmd(`face ${car.doorX} ${car.doorZ} 2.0`);
  const s = await until(c.state, (x) => x.me?.canCall === true, ms, 150);
  await c.cmd('call');
  return until(c.state, (x) => ['coming', 'arriving', 'boarding'].includes(x.phase), 8000, 60).then((x) => ({ ok: ['coming', 'arriving', 'boarding'].includes(x.phase), canCall: s.me?.canCall, phase: x.phase }));
}
async function board(c, side = 'down') {
  const pl = JSON.parse(await c.cmd('plan'));
  const p = pl.car;
  await c.cmd(`walkto ${pl.landing.level} ${pl.landing.x} ${pl.landing.y} 3`);
  await until(c.state, (s) => s.auto !== 'walking', 30000);
  await c.cmd(`face ${p.doorX + p.inX * 2} ${p.doorZ + p.inZ * 2}`);
  await c.cmd('move 1 0 0 0');
  await until(c.state, (s) => s.me?.aboard === true && Math.abs((s.me.x - p.doorX) * p.inX + (s.me.z - p.doorZ) * p.inZ) > 1.1, 6000, 30);
  await c.cmd(side === 'bank' ? 'move 0 -1 0 0' : 'move 0 1 0 0');
  const s = await until(c.state, (x) => x.me?.side === side, 3000, 30);
  await c.cmd('stopmove');
  return s;
}

/** Into the run and down from the Arboretum (floor 5) to the Ward: out, call, board DOWN. */
async function rideToWard(cs, tag) {
  for (const c of cs) await c.cmd('ready');
  for (const c of cs) await until(c.state, inGame, 40000);
  for (const c of cs) await c.cmd('click');
  const a = await until(cs[0].state, (s) => s.phase === 'unloading' && s.client?.doors > 0.95, 40000);
  check(`${tag}: the run starts on the Arboretum (floor 5, server depth=5)`, a.depth === 5, `depth ${a.depth}, place ${a.place}`);
  await stepOut(cs);
  await until(cs[0].state, (s) => s.phase === 'away', 25000, 100);
  const called = await callLift(cs[0], 40000);
  check(`${tag}: the lift is called on floor 5 (quota=0)`, called.ok, J(called));
  await until(cs[0].state, (s) => s.phase === 'boarding', 120000, 200);
  for (const c of cs) await board(c, 'down');
  return until(cs[0].late, (l) => l.depth === 6 && l.ward, 90000, 150);
}

// ---- Ward helpers: routes through the Ward walk model the screen walks with (main.gd `wardroute`).
/** Per client: the first moment its own screen and the host's row for it were more than 0.5 m apart on the Ward. */
const wardSplit = {};
async function follow(c, route, ms = 60000, gait = '0') {
  const end = Date.now() + ms;
  let i = 0;
  let last = null;
  let stuckSince = Date.now();
  let n = 0;
  while (i < route.length && Date.now() < end) {
    const s = await c.state();
    if (!s.me) { await sleep(60); continue; }
    const at = [s.me.x, s.me.y, s.me.z];
    if (n++ % 3 === 0 && !wardSplit[c.label]) {
      const l = await c.late();
      const hb = l.hostBody;
      const lb = l.localBody;
      if (hb && lb && l.ward && Math.hypot(hb.x - lb.x, hb.z - lb.z) > 0.5) {
        wardSplit[c.label] = { tick: l.tick, hostNow: l.hostNow, phase: l.ward.phase, host: [hb.x, hb.y, hb.z].map(r2), screen: [lb.x, lb.y, lb.z].map(r2), door: l.wardModel?.liftDoor };
        log(`  ${c.label}: the host's row and the screen split: ${J(wardSplit[c.label])}`);
      }
    }
    while (i < route.length - 1 && flat(at, route[i]) < 0.35) i++;
    const w = route[i];
    if (i === route.length - 1 && flat(at, w) < 0.3) break;
    await c.cmd(`face ${w[0]} ${w[2]}`);
    await c.cmd(`move 1 0 0 ${gait}`);
    if (last && flat(at, last) > 0.05) stuckSince = Date.now();
    if (Date.now() - stuckSince > 2500) break;
    last = at;
    await sleep(45);
  }
  await c.cmd('stopmove');
  await sleep(150);
  const s = await c.state();
  return { at: [s.me?.x, s.me?.y, s.me?.z], reached: route.length ? flat([s.me?.x, s.me?.y, s.me?.z], route[route.length - 1]) : NaN };
}
async function wardGo(c, x, z, ms = 60000, radius = 0.45) {
  let res = null;
  for (let tries = 0; tries < 3; tries++) {
    const route = JSON.parse(await c.cmd(`wardroute ${x} ${z} ${radius}`));
    if (!route.length) return { ok: false, why: 'no route', reached: NaN };
    const sub = route.filter((_, k) => k % 2 === 0 || k === route.length - 1);
    res = await follow(c, sub, ms);
    if (Math.hypot(res.at[0] - x, res.at[2] - z) < radius + 0.4) return { ok: true, ...res, steps: route.length };
  }
  return { ok: false, why: 'stopped short', ...res };
}

// ---- Reactor helpers: the station is a plan floor (2 m cells).
const cellOf = (x, z) => [Math.floor(x / 2), Math.floor(z / 2)];
async function approach(c, x, z, near, gait = '0', ms = 8000) {
  const end = Date.now() + ms;
  let s = await c.state();
  while (s.me && Math.hypot(s.me.x - x, s.me.z - z) > near && Date.now() < end) {
    await c.cmd(`face ${x} ${z}`);
    await c.cmd(`move 1 0 ${gait} 0`);
    await sleep(50);
    s = await c.state();
  }
  await c.cmd('stopmove');
  return c.state();
}
async function goTo(c, x, z, near, gait = 'walk') {
  const [cx, cz] = cellOf(x, z);
  await c.cmd(`walkto 0 ${cx} ${cz} 3 ${gait}`);
  await until(c.state, (s) => s.auto !== 'walking' || (s.me && Math.hypot(s.me.x - x, s.me.z - z) < near), 30000, 60);
  await c.cmd('stopwalk');
  return approach(c, x, z, near, gait === 'sprint' ? '1' : '0');
}
async function press(c, held = 400) { await c.cmd('use 1'); await sleep(held); await c.cmd('use 0'); }

// ======================================================================================================
async function mainSession() {
  const url = `ws://127.0.0.1:${P.server}`;
  const srv = server(P.server, 'server', []);
  await until(async () => srv.lines.join('\n'), (t) => t.includes('listening on') || srv.exited, 40000);
  if (!check('main: the server starts with the late floors on', srv.lines.join('\n').includes('listening on'), srv.lines.slice(-3).join(' | '))) return;
  let A = null; let B = null; let C = null;
  try {
    A = await joinRoom('A', P.A, url, 'Ann');
    B = await joinRoom('B', P.B, url, 'Bob');
    await until(A.state, (s) => (scr(s).people ?? []).length >= 2, 20000);
    let l = await rideToWard([A, B], 'main');
    // ---------------- The Ward.
    let [la, lb] = [await until(A.late, (x) => x.wardModel, 20000), await until(B.late, (x) => x.wardModel, 20000)];
    check('Ward: both screens hold a native Ward block on floor 6 and draw it in the main scene', la.depth === 6 && lb.depth === 6 && la.ward?.native === true && lb.ward?.native === true && la.wardDrawn && lb.wardDrawn,
      `A depth ${la.depth} native ${la.ward?.native} drawn ${la.wardDrawn} media ${la.wardModel?.media}; B depth ${lb.depth} native ${lb.ward?.native} drawn ${lb.wardDrawn} media ${lb.wardModel?.media}`);
    check('Ward: the same seed and the same houses on both', la.ward.seed === lb.ward.seed && la.wardModel.seed === la.ward.seed && J(la.wardModel.layoutHouses) === J(lb.wardModel.layoutHouses) && J(la.wardModel.switches) === J(lb.wardModel.switches),
      `seed A ${la.ward.seed} B ${lb.ward.seed}, run seed ${la.seed}; ${la.wardModel.houses} houses, ${la.wardModel.switches.length} winch switches`);
    const door = la.wardModel.liftDoor;
    check('Ward: the lift waits with the crew in it (unloading on both)', la.ward.phase === 'unloading' && lb.ward.phase === 'unloading', `A ${la.ward.phase}, B ${lb.ward.phase}`);
    // Ann out first; Bob stays in the car.
    const outA = await wardGo(A, door[0] - 0.3, door[2] + 2.6, 20000);
    await sleep(2500);
    [la, lb] = [await A.late(), await B.late()];
    check('Ward: Ann out, Bob still in the car: the lift has not left (both screens)', outA.ok && la.ward.phase === 'unloading' && lb.ward.phase === 'unloading',
      `Ann ${r2(outA.reached)} m from her spot, ${r2(outA.at?.[2] - door[2])} m past the doors; phases A ${la.ward.phase} B ${lb.ward.phase}`);
    const outB = await wardGo(B, door[0] + 0.5, door[2] + 2.6, 20000);
    [la, lb] = [await until(A.late, (x) => x.ward?.phase === 'away', 5000, 50), await until(B.late, (x) => x.ward?.phase === 'away', 5000, 50)];
    check('Ward: both clear: the lift leaves (away on both)', outB.ok && la.ward.phase === 'away' && lb.ward.phase === 'away', `Bob ${r2(outB.at?.[2] - door[2])} m past the doors; A ${la.ward.phase} B ${lb.ward.phase}`);
    const dep = [evOf(la, 'ward_departed')[0], evOf(lb, 'ward_departed')[0]];
    check('Ward: the departure is the same host event on both', dep[0] && dep[1] && dep[0].t === dep[1].t, `A t ${dep[0]?.t}, B t ${dep[1]?.t}`);
    await sleep(1200);
    const pair = await sameTick(A, B);
    const ca = clockSecs(pair.a.clockLine);
    const cb = clockSecs(pair.b.clockLine);
    const left = pair.a.ward.collectionAt - pair.a.hostNow;
    const sameClock = pair.a.ward.collectionAt === pair.b.ward.collectionAt && Math.abs(ca - cb) <= 1;
    check('Ward: both see the same LIFT RETURNS clock (same collectionAt, lines within a second, read on ticks within one)', breakClock ? !sameClock : sameClock && Math.abs(ca - left) <= 1.5 && pair.gap <= 1,
      `A "${pair.a.clockLine}" B "${pair.b.clockLine}", collectionAt A ${pair.a.ward.collectionAt} B ${pair.b.ward.collectionAt}, host left ${r2(left)} s, ticks ${pair.a.tick}/${pair.b.tick}`);
    if (breakClock) throw new Error('--break=clock: the session stops after the broken clock check');
    // The winch: Ann goes to a switch on a house other than the parlour (Bob waits in the parlour).
    const sw = la.wardModel.switches.map((s, k) => ({ ...s, k, d: Math.hypot(s.position[0] - door[0], s.position[2] - door[2]) })).sort((x, y) => (x.house === 0) - (y.house === 0) || x.d - y.d);
    let at = null; let used = null;
    for (const s of sw) {
      at = await wardGo(A, s.position[0], s.position[2], 90000, 0.9);
      log(`  Ann to winch switch ${s.k} (house ${s.house}) at ${J(s.position.map(r2))}: ${J({ ok: at.ok, why: at.why, steps: at.steps, at: at.at?.map(r2) })}`);
      if (at.ok) { used = s; break; }
    }
    lb = await B.late();
    const before = lb.ward?.bridgeLowered;
    let reach = NaN;
    if (used) {
      // The last steps straight at the switch (the host's reach is 1.25 m, height included).
      const sp = used.position;
      let s = await A.state();
      for (let k = 0; k < 40 && Math.hypot(s.me.x - sp[0], s.me.z - sp[2]) > 0.35; k++) {
        await A.cmd(`face ${sp[0]} ${sp[2]}`);
        await A.cmd('move 0.5 0 0 0');
        await sleep(40);
        s = await A.state();
      }
      await A.cmd('stopmove');
      await sleep(300);
      s = await A.state();
      reach = Math.hypot(s.me.x - sp[0], s.me.y - sp[1], s.me.z - sp[2]);
      for (let k = 0; k < 3 && (await B.late()).ward?.bridgeLowered === before; k++) {
        await press(A, 500);
        lb = await until(B.late, (x) => x.ward?.bridgeLowered !== before, 2000, 40);
      }
      const lw = await A.late();
      const hb = lw.hostBody ?? {};
      const hostReach = Math.hypot(hb.x - sp[0], hb.y - sp[1], hb.z - sp[2]);
      log(`  Ann at ${J([s.me.x, s.me.y, s.me.z].map(r2))} (her own screen ${J(lw.localBody)}, the host's row ${J(hb)}: ${r2(hostReach)} m), the switch at ${J(sp.map(r2))}: ${r2(reach)} m (reach 1.25); prompt "${lw.prompt}"; use events ${J(evOf(lw, 'ward_bridge'))}`);
      reach = hostReach;
    }
    la = await A.late();
    check('Ward: on the walk to the winch the host accepts Ann\'s steps (her screen and the host\'s row for her stay within 0.5 m)', !wardSplit.A && Number.isFinite(reach) && reach <= 1.25,
      wardSplit.A ? `split at tick ${wardSplit.A.tick} (host time ${wardSplit.A.hostNow}, phase ${wardSplit.A.phase}): host ${J(wardSplit.A.host)}, her screen ${J(wardSplit.A.screen)}, lift door ${J(wardSplit.A.door)}; at the switch the host has her ${r2(reach)} m from it` : `host row ${r2(reach)} m from the switch`);
    const bev = [evOf(la, 'ward_bridge').at(-1), evOf(lb, 'ward_bridge').at(-1)];
    check('Ward: Ann works the winch and Bob\'s screen sees the bridge move (block and drawn walk model)', used && lb.ward.bridgeLowered !== before && lb.wardModel.bridgeLowered === lb.ward.bridgeLowered && la.ward.bridgeLowered === lb.ward.bridgeLowered,
      `switch ${used?.k} house ${used?.house}; Bob's bridge ${before} -> ${lb.ward.bridgeLowered} (walk model ${lb.wardModel?.bridgeLowered}), Ann's ${la.ward.bridgeLowered}`);
    check('Ward: the bridge event is the same host time on both', bev[0] && bev[1] && bev[0].t === bev[1].t && bev[0].lowered === bev[1].lowered, `A ${J(bev[0])} B ${J(bev[1])}`);
    // The winch is heard: the Rigger of that house comes. Ann raises the instrument near it.
    la = await until(A.late, (x) => ['searching', 'climbing', 'warning'].includes(x.ward.encounter), 4000, 50);
    const enc = la.ward.encounter;
    await A.cmd('raise 1');
    await until(A.late, (x) => x.ward.encounter === 'searching' || x.ward.encounter === 'idle', 6000, 60);
    await sleep(5000);
    await A.cmd('raise 0');
    await sleep(1500);
    [la, lb] = [await A.late(), await B.late()];
    const rA = evOf(la, 'readingClosed');
    const rB = evOf(lb, 'readingClosed');
    const [sa, sb] = [await A.state(), await B.state()];
    check('Ward: a reading near the Rigger, the same amount on both screens', rA.length > 0 && J(rA) === J(rB) && J(sa.tapes) === J(sb.tapes),
      `encounter ${enc} (house ${la.ward.house}); Ann's readings on A ${J(rA.map((e) => [e.playerId, e.value, e.t]))}, on B ${J(rB.map((e) => [e.playerId, e.value, e.t]))}; tapes A ${J(sa.tapes)} B ${J(sb.tapes)}`);
    const caught = [la.ward.caught, lb.ward.caught];
    if (caught[0].length) log(`  caught on the Ward: ${J(caught[0])}`);
    // Back to the parlour beside the lift to wait.
    const backA = await wardGo(A, door[0] - 0.3, door[2] + 2.2, 120000);
    log(`  Ann back by the lift: ${J({ ok: backA.ok, why: backA.why })}; waiting for the lift (${r2(la.ward.collectionAt - la.hostNow)} s)`);
    // The host's panel (Ann is the host): the Reactor's lights hold the game's 45 s (left as is).
    la = await until(A.late, (x) => x.ward?.phase === 'boarding', 700000, 1000);
    lb = await until(B.late, (x) => x.ward?.phase === 'boarding', 5000, 50);
    const ret = [evOf(la, 'ward_returned')[0], evOf(lb, 'ward_returned')[0]];
    check('Ward: the lift returns on the same host time on both', la.ward.phase === 'boarding' && lb.ward.phase === 'boarding' && ret[0] && ret[1] && ret[0].t === ret[1].t && Math.abs(ret[0].t - la.ward.collectionAt) < 1e-6,
      `A ${la.ward.phase} t ${ret[0]?.t}, B ${lb.ward.phase} t ${ret[1]?.t}, collectionAt ${la.ward.collectionAt}, departAt A ${la.ward.departAt} B ${lb.ward.departAt}`);
    const inA = wardGo(A, door[0] - 0.25, door[2] - 1.3, 30000);
    const inB = wardGo(B, door[0] + 0.25, door[2] - 1.9, 30000);
    const [ia, ib] = await Promise.all([inA, inB]);
    [la, lb] = [await until(A.late, (x) => x.ward == null || x.ward.phase === 'departed' || x.depth === 7, 60000, 100), await B.late()];
    const closedA = evOf(la, 'ward_closed')[0];
    const closedB = evOf(lb, 'ward_closed')[0];
    check('Ward: both board, the lift closes with both aboard on both screens', closedA && closedB && closedA.t === closedB.t && J(closedA.boarded?.slice().sort()) === J([la.me, lb.me].sort()),
      `in: Ann ${ia.ok} Bob ${ib.ok}; closed A ${J(closedA)} B ${J(closedB)}`);
    // ---------------- The Reactor.
    [la, lb] = [await until(A.late, (x) => x.depth === 7 && x.reactor && x.station, 90000, 150), await until(B.late, (x) => x.depth === 7 && x.reactor && x.station, 30000, 100)];
    check('Reactor: both ride on to floor 7, a native station drawn by the main game', la.depth === 7 && lb.depth === 7 && la.reactor?.native === true && lb.reactor?.native === true && la.place === 'reactor',
      `A depth ${la.depth} place ${la.place} native ${la.reactor?.native}; B depth ${lb.depth} native ${lb.reactor?.native}`);
    const anch = (x) => ({ seed: x.reactor.seed, fuseAt: x.reactor.fuseAt, tapeAt: x.reactor.tapeAt, seats: x.reactor.seats, station: x.station });
    check('Reactor: the same plan and anchors on both (seed, fuse spot, cabinet, plinth, the four)', J(anch(la)) === J(anch(lb)),
      `seed ${la.reactor.seed}/${lb.reactor.seed}, fuse ${J(la.reactor.fuseAt)}/${J(lb.reactor.fuseAt)}, cabinet ${J(la.station?.cabinet?.at)}, bodies ${J((la.station?.bodies ?? []).map((b) => b.at))}`);
    const pr = await sameTick(A, B);
    check('Reactor: the four lie in the same poses on both (same tick)', pr.gap === 0 && J(pr.a.reactor.crew) === J(pr.b.reactor.crew) && la.reactor.power === 0, `ticks ${pr.a.tick}/${pr.b.tick}, power ${la.reactor.power}`);
    // Both walk past the landing into the hall: the hold starts.
    await stepOut([A, B]);
    const land = la.station.landing;
    const hall = la.station.hall;
    const hx = land[0] + land[2] / 2;
    const hz = Math.max(hall[1] + 1, land[1] - 3);
    await Promise.all([goTo(A, hx - 1, hz, 0.8), goTo(B, hx + 1, hz, 0.8)]);
    [la, lb] = [await until(A.late, (x) => evOf(x, 'powerHold').length > 0, 10000, 100), await until(B.late, (x) => evOf(x, 'powerHold').length > 0, 3000, 100)];
    const hold = [evOf(la, 'powerHold')[0], evOf(lb, 'powerHold')[0]];
    check('Reactor: the lights hold once someone passes the landing, the same host event on both', hold[0] && hold[1] && hold[0].t === hold[1].t && hold[0].len === hold[1].len,
      `A ${J(hold[0])} B ${J(hold[1])}`);
    [la, lb] = [await until(A.late, (x) => evOf(x, 'powerCut').length > 0, 70000, 100), await until(B.late, (x) => evOf(x, 'powerCut').length > 0, 3000, 50)];
    const cut = [evOf(la, 'powerCut')[0], evOf(lb, 'powerCut')[0]];
    check('Reactor: the power cuts on the same host tick on both, the hold after it started', cut[0] && cut[1] && cut[0].t === cut[1].t && hold[0] && Math.abs(cut[0].t - hold[0].t - hold[0].len) <= 0.051 && la.reactor.power === 1 && lb.reactor.power === 1,
      `cut A t ${cut[0]?.t} B t ${cut[1]?.t}, hold from ${hold[0]?.t} for ${hold[0]?.len} s, power A ${la.reactor.power} B ${lb.reactor.power}`);
    // A third client joins now.
    const cJoin = joinRoom('C', P.C, url, 'Cy').catch((e) => { log(`  Cy could not join: ${e.message}`); return null; });
    [la, lb] = [await until(A.late, (x) => evOf(x, 'stationStir').length > 0, 8000, 50), await until(B.late, (x) => evOf(x, 'stationStir').length > 0, 3000, 50)];
    const stir = [evOf(la, 'stationStir')[0], evOf(lb, 'stationStir')[0]];
    const stands = evOf(la, 'bodyStands');
    check('Reactor: the four stir, the same host event on both, before any of them stands (heard before it reaches anyone)', stir[0] && stir[1] && stir[0].t === stir[1].t && (stands.length === 0 || stands[0].t > stir[0].t),
      `stir A ${J(stir[0])} B ${J(stir[1])}, first stands ${stands[0]?.t}`);
    // Ann goes for the fuse; Bob goes to meet the four.
    const fuse = la.reactor.fuseAt;
    const annFuse = (async () => {
      const s = await goTo(A, fuse[0], fuse[2], 1.6, 'sprint');
      await press(A, 300);
      return { s, l: await until(A.late, (x) => x.reactor.holder === x.me, 1500, 50) };
    })();
    const bobMeets = (async () => {
      const end = Date.now() + 40000;
      let s = await B.state();
      while (s.me?.status === 'ok' && Date.now() < end) {
        const l = await B.late();
        const run = (l.reactor?.crew ?? []).filter((c) => c[5] === 'zombie_run');
        const pool = run.length ? run : (l.reactor?.crew ?? []);
        const near = pool.sort((p, q) => Math.hypot(p[0] - s.me.x, p[2] - s.me.z) - Math.hypot(q[0] - s.me.x, q[2] - s.me.z))[0];
        if (near) { await B.cmd(`face ${near[0]} ${near[2]}`); await B.cmd(Math.hypot(near[0] - s.me.x, near[2] - s.me.z) > 0.6 ? 'move 1 0 0 0' : 'stopmove'); }
        await sleep(60);
        s = await B.state();
      }
      await B.cmd('stopmove');
      return s;
    })();
    const [fz, bs] = await Promise.all([annFuse, bobMeets]);
    check('Reactor: Ann takes the fuse (the host\'s holder, the same on Bob\'s screen)', fz.l.reactor.holder === fz.l.me && (await B.late()).reactor.holder === fz.l.me,
      `holder ${fz.l.reactor.holder}, Ann ${fz.l.me}, ${r2(Math.hypot(fz.s.me?.x - fuse[0], fz.s.me?.z - fuse[2]))} m from the fuse when she pressed F`);
    // Whoever is down, the other heals.
    let sa2 = await A.state();
    let sb2 = await B.state();
    const downed = sb2.me?.status === 'down' ? [B, A, sb2] : sa2.me?.status === 'down' ? [A, B, sa2] : null;
    check('Reactor: a catch puts a player down (the host\'s status on both screens)', downed !== null,
      `Ann ${sa2.me?.status}, Bob ${sb2.me?.status}; catches A ${J(evOf(await A.late(), 'caught').map((e) => e.playerId))}`);
    if (downed) {
      const [dn, hl, ds] = downed;
      const victimId = ds.me.id;
      // The host's panel at once: the four drop back to a crawl (which catches nobody) so two players can survive
      // the heal (a live setting the host has on the night; the rules are not changed).
      const tuned = await A.cmd('panel set reactor.crawl_time 30');
      const tuned2 = await A.cmd('panel set reactor.run_speed 1.5');
      log(`  the host's panel: crawl_time 30 -> ${tuned}, run_speed 1.5 -> ${tuned2}`);
      const screenCheck = (async () => {
        const dt0 = Date.now();
        const dv = await until(dn.state, (s) => /^DOWN/.test(s.downs?.hud?.head ?? ''), 3000, 40);
        const headAfter = (Date.now() - dt0) / 1000;
        check('Reactor: the downed player has something to do within seconds (the timer and the line)', /^DOWN/.test(dv.downs?.hud?.head ?? '') && (dv.downs?.hud?.line ?? '') !== '',
          `"${dv.downs?.hud?.head}" / "${dv.downs?.hud?.line}" / "${dv.downs?.hud?.line2}", the timer up ${r2(headAfter)} s after the tool saw the catch`);
      })();
      const hs = await hl.state();
      const o = (hs.others ?? []).find((x) => x.id === victimId);
      if (o) {
        await goTo(hl, o.x, o.z, 0.9, 'sprint');
        await hl.cmd(`face ${o.x} ${o.z} 0.2`);
        await hl.cmd('use 1');
        const mid = await until(dn.state, (s) => /IS HELPING YOU UP/.test(s.downs?.hud?.line ?? '') || s.me?.status !== 'down', 3000, 40);
        const up = await until(dn.state, (s) => s.me?.status !== 'down', 8000, 50);
        await hl.cmd('use 0');
        const hev = [evOf(await A.late(), 'healed'), evOf(await B.late(), 'healed')];
        check('Reactor: the other heals them with F held (the downed screen says so; back on their feet; same healed event on both)', up.me?.status === 'ok' && hev[0].length > 0 && J(hev[0]) === J(hev[1]),
          `line while held "${mid.downs?.hud?.line}", status after ${up.me?.status}, healed A ${J(hev[0].map((e) => e.t))} B ${J(hev[1].map((e) => e.t))}`);
      } else check('Reactor: the healer sees the downed player', false, `no figure ${victimId}`);
      await screenCheck;
    }
    // Ann (or whoever holds the fuse) installs it.
    la = await A.late();
    const holderC = la.reactor.holder === la.me ? A : la.reactor.holder === (await B.late()).me ? B : null;
    if (!holderC) {
      // Dropped by a catch: Ann picks it up again.
      const f2 = la.reactor.fuseAt;
      await goTo(A, f2[0], f2[2], 1.6, 'sprint');
      await press(A, 300);
    }
    const hc = holderC ?? A;
    const cab = la.station.cabinet.at;
    await goTo(hc, cab[0], cab[2], 1.5, 'sprint');
    await press(hc, 300);
    [la, lb] = [await until(A.late, (x) => evOf(x, 'powerRestored').length > 0, 4000, 50), await until(B.late, (x) => evOf(x, 'powerRestored').length > 0, 3000, 50)];
    const rest = [evOf(la, 'powerRestored')[0], evOf(lb, 'powerRestored')[0]];
    check('Reactor: power restored at the cabinet, the same host event on both', rest[0] && rest[1] && rest[0].t === rest[1].t && la.reactor.power === 2 && lb.reactor.power === 2,
      `A ${J(rest[0])} B ${J(rest[1])}, power ${la.reactor.power}/${lb.reactor.power}`);
    // Cy, joined after the cut.
    C = await cJoin;
    if (C) {
      const lc = await C.late();
      const sc = await C.state();
      const pc = await sameTick(A, C, 30);
      const sameAll = pc.a.reactor && pc.b.reactor && pc.a.reactor.power === pc.b.reactor.power && pc.a.reactor.holder === pc.b.reactor.holder && J(pc.a.reactor.crew) === J(pc.b.reactor.crew);
      check('late joiner: Cy, joined after the cut, sees the same power state, fuse holder and bodies as Ann', sameAll,
        `Cy screen ${scr(sc).screen} "${scr(sc).line}", Cy's block ${lc.reactor ? `power ${lc.reactor.power} holder ${lc.reactor.holder}` : J(lc).slice(0, 120)}; ticks Ann ${pc.a.tick} Cy ${pc.b.tick}`);
    }
    // The tape: Bob takes it from the table; the lift is called; both ride up.
    la = await A.late();
    const tape = la.reactor.tapeAt;
    // Bob, or Ann if Bob is out.
    const taker = (await B.state()).me?.status === 'ok' ? B : A;
    const other2 = taker === B ? A : B;
    await goTo(taker, tape[0], tape[2], 1.5, 'sprint');
    await press(taker, 300);
    const lt = await until(taker.late, (x) => x.reactor?.cassetteHolder === x.me, 2000, 50);
    check(`Reactor: ${taker.label === 'B' ? 'Bob' : 'Ann (Bob is out)'} takes the tape (the same holder on the other screen)`, lt.reactor?.cassetteHolder === lt.me && (await other2.late()).reactor?.cassetteHolder === lt.me,
      `holder ${lt.reactor?.cassetteHolder}, taker ${lt.me}`);
    const called = await callLift(A, 60000);
    if (!called.ok) {
      const d = await A.late();
      const sA = await A.state();
      const sB = await B.state();
      log(`  call refused: depth ${d.depth} phase ${d.phase}, power ${d.reactor?.power}, Ann ${sA.me?.status} Bob ${sB.me?.status}, last events ${J((d.events ?? []).slice(-10).map((e) => [e.type, e.t, e.playerId]))}`);
    }
    check('Reactor: with the power back the lift can be called', called.ok, J(called));
    await until(A.state, (s) => s.phase === 'boarding', 120000, 200);
    await Promise.all([board(A, 'down'), board(B, 'down')]);
    [la, lb] = [await until(A.late, (x) => x.depth === 0, 120000, 200), await until(B.late, (x) => x.depth === 0, 20000, 100)];
    const ext = [evOf(la, 'tapeExtracted')[0], evOf(lb, 'tapeExtracted')[0]];
    check('Reactor: both ride up and arrive in the prison', la.depth === 0 && lb.depth === 0, `depth A ${la.depth} B ${lb.depth}`);
    check('Reactor: the tape carried out is recorded (the same event on both, the archive has it)', ext[0] && ext[1] && ext[0].t === ext[1].t && la.reactor?.extracted === true && la.reactor?.archive?.recovered === true,
      `A ${J(ext[0])} B ${J(ext[1])}, extracted ${la.reactor?.extracted}, archive ${J(la.reactor?.archive)}`);
    if (C) {
      const sc = await until(C.state, inGame, 30000, 200);
      check('late joiner: Cy is admitted at the next stop', inGame(sc), `screen ${scr(sc).screen}, depth ${sc.depth}`);
    }
  } catch (e) {
    check('main: the session ran to the end', false, String(e?.stack ?? e));
  } finally {
    const errors = [...(A?.g.lines ?? []), ...(B?.g.lines ?? []), ...(C?.g.lines ?? []), ...srv.lines].filter((x) => /SCRIPT ERROR|ERROR: .*\.gd/.test(x));
    check('main: no script errors on the server or the clients', errors.length === 0, errors.slice(0, 4).join(' | '));
    if (saveLogs) {
      mkdirSync(saveLogs, { recursive: true });
      writeFileSync(join(saveLogs, `main-server-${port}.log`), srv.lines.join('\n'));
      for (const c of [A, B, C]) if (c) writeFileSync(join(saveLogs, `main-${c.label}-${port}.log`), c.g.lines.join('\n'));
    }
    for (const c of [A, B, C]) if (c) await c.close();
    srv.p.kill();
  }
}

// ======================================================================================================
async function fallbackA() {
  const url = `ws://127.0.0.1:${P.fa}`;
  const srv = server(P.fa, 'fallbackA', ['ward_place=0', 'reactor_place=0']);
  await until(async () => srv.lines.join('\n'), (t) => t.includes('listening on') || srv.exited, 40000);
  if (!check('fallback A: the server starts with ward_place=0 reactor_place=0', srv.lines.join('\n').includes('listening on'))) return;
  let F = null;
  try {
    if (!havePacks) { check('fallback A: the floor packs are there', false, `none in ${packs}`); return; }
    F = await joinRoom('F', P.fa1, url, 'Fay');
    await F.cmd('ready');
    await until(F.state, inGame, 40000);
    await F.cmd('click');
    await until(F.state, (s) => s.phase === 'unloading' && s.client?.doors > 0.95, 40000);
    await stepOut([F]);
    await until(F.state, (s) => s.phase === 'away', 25000, 100);
    const called = await callLift(F, 40000);
    await until(F.state, (s) => s.phase === 'boarding', 120000, 200);
    await board(F, 'down');
    const t = Date.now();
    while (Date.now() - t < 120000 && !F.g.lines.some((x) => /FLOOR ENTERED ward|FLOOR MEDIA MISSING/.test(x))) await sleep(200);
    await sleep(3000);
    const entered = F.g.lines.find((x) => /FLOOR ENTERED ward/.test(x));
    const ready = F.g.lines.find((x) => /WARD REVIEW READY/.test(x));
    check('fallback A: floor 6 hands over to the old Ward scene (FLOOR ENTERED ward), which joins the same room', called.ok && entered && ready && /playing=true/.test(ready),
      `call ${J(called)}; "${entered ?? 'no FLOOR ENTERED'}"; "${ready ?? 'no WARD REVIEW READY'}"`);
    check('fallback A: no native Ward drawn in the main scene', !F.g.lines.some((x) => /FLOOR NATIVE ward/.test(x)), F.g.lines.filter((x) => /FLOOR NATIVE/.test(x)).join(' | '));
    skip('fallback A: the old Ward handing back', 'the old Ward scene reads only the keyboard once handed a room, so a headless client cannot walk out of its lift and the lift never leaves');
  } catch (e) {
    check('fallback A: ran to the end', false, String(e?.stack ?? e));
  } finally {
    const errors = [...(F?.g.lines ?? []), ...srv.lines].filter((x) => /SCRIPT ERROR|ERROR: .*\.gd/.test(x));
    check('fallback A: no script errors', errors.length === 0, errors.slice(0, 4).join(' | '));
    if (F) await F.close();
    srv.p.kill();
  }
}

async function fallbackB() {
  const url = `ws://127.0.0.1:${P.fb}`;
  const srv = server(P.fb, 'fallbackB', ['reactor_place=0']);
  await until(async () => srv.lines.join('\n'), (t) => t.includes('listening on') || srv.exited, 40000);
  if (!check('fallback B: the server starts with reactor_place=0', srv.lines.join('\n').includes('listening on'))) return;
  let G = null;
  try {
    if (!havePacks) { check('fallback B: the floor packs are there', false, `none in ${packs}`); return; }
    G = await joinRoom('G', P.fb1, url, 'Gus');
    const l = await rideToWard([G], 'fallback B');
    const lg = await until(G.late, (x) => x.wardModel, 20000);
    const door = lg.wardModel.liftDoor;
    const out = await wardGo(G, door[0], door[2] + 2.6, 20000);
    const away = await until(G.late, (x) => x.ward?.phase === 'away', 5000, 50);
    check('fallback B: the native Ward on floor 6, Gus walks out, the lift leaves', l.ward?.native === true && out.ok && away.ward?.phase === 'away', `native ${l.ward?.native}, out ${out.ok}, phase ${away.ward?.phase}`);
    await until(G.late, (x) => x.ward?.phase === 'boarding', 700000, 1000);
    const back = await wardGo(G, door[0], door[2] - 1.4, 30000);
    const t = Date.now();
    while (Date.now() - t < 150000 && !G.g.lines.some((x) => /FLOOR ENTERED reactor|FLOOR MEDIA MISSING reactor/.test(x))) await sleep(250);
    const entered = G.g.lines.find((x) => /FLOOR ENTERED reactor/.test(x));
    check('fallback B: floor 7 hands over to the old Reactor scene (FLOOR ENTERED reactor)', back.ok && entered, `boarded ${back.ok}; "${entered ?? G.g.lines.filter((x) => /FLOOR/.test(x)).join(' | ')}"`);
    skip('fallback B: the old Reactor handing back', 'the old Reactor scene has no test channel; a headless client cannot fetch its fuse');
  } catch (e) {
    check('fallback B: ran to the end', false, String(e?.stack ?? e));
  } finally {
    const errors = [...(G?.g.lines ?? []), ...srv.lines].filter((x) => /SCRIPT ERROR|ERROR: .*\.gd/.test(x));
    check('fallback B: no script errors', errors.length === 0, errors.slice(0, 4).join(' | '));
    if (G) await G.close();
    srv.p.kill();
  }
}

log(`seed ${seed}, packs ${havePacks ? packs : 'none (the Ward drawn without media)'}`);
const jobs = [];
if (doMain) jobs.push(mainSession());
if (doFallback) { jobs.push(fallbackA()); jobs.push(fallbackB()); }
await Promise.allSettled(jobs);
await sleep(500);
cleanup();
const failed = results.filter((r) => !r.ok).length;
console.log(`${results.length - failed} passed, ${failed} failed`);
process.exit(failed ? 1 : 0);
