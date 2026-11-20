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
//   Fallback A (server on P+6, `ward_place=0 reactor_place=0`): one client rides to floor 6 and must hand over to
//   the old Ward scene ("FLOOR ENTERED ward"; client/ward/review.tscn, inside the game).
//   Fallback B (server on P+8, `reactor_place=0`): one client walks the native Ward, boards, and rides to floor 7.
//   PL3: the old Reactor room is no longer in the game (IP1, the owner: "We don't want the extra packs. It should be
//   fully integrated into the game like everything else."; tests/test_floor_media.gd). A server started with
//   `reactor_place=0` still runs floor 7 by the old overlay's rules, and the game's own answer is the one checked:
//   the screen says the old room is not in this build ("FLOOR MEDIA MISSING reactor") and keeps the player in the
//   room on floor 7. Nothing here reads or mounts a floor pack.
// The two fallbacks run beside the main session (each is mostly waiting for the Ward's lift). Prints `N passed, M
// failed`; exit code 1 on any failure. Headless only: no window opens.
//
// PL2 (what this tool passes or fails on): only that the screens and the host AGREE (the same plan, the same clocks,
// the same events in the same order, the same holders and phases) and that nothing printed a script error. What the
// game does to the crew (catches, downs, a tape not carried out, a crew that did not ride up) is printed as FINDING
// with its numbers and is never a failure. Changes from PL1:
//   - the host sets the Ward's lift return (the live setting ward.lift_minutes, --lift-minutes=, default 1) on its
//     settings panel in the lobby, the way tools/play_settings.mjs does, so a full run takes minutes, not twenty;
//   - every client is polled about ten times a second for its own body against the host's row for it (main.gd
//     `split`) on every floor it walks (5, 6, 7 and the prison): a split above 0.5 m for more than 0.6 s fails;
//   - the Reactor is played as a crew would (see mainSession), with a medic that heals only once the four have
//     moved off;
//   - fallback A walks the old Ward room too (client/ward/review.gd's test walk, ward_handed_walk=1) and checks
//     that the old room hands the run back to the main game;
//   - --quick=1: the main session without the late joiner, and fallback A only (the hotfix chain's step).
//   node godot/tools/play_late.mjs [--port=4740] [--seed=late-1]
//        [--fallback=1] [--main=1] [--lift-minutes=1] [--quick=1] [--save-logs=DIR] [--break=clock|split]
// Ports: P server, P+1..P+3 the main session's test channels, P+6 / P+7 fallback A, P+8 / P+9 fallback B; all
// in 4740-4819. Stops every process it starts, also on failure.
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
const doMain = arg('main', '1') === '1';
const doFallback = arg('fallback', '1') === '1';
/** --save-logs=DIR: every line the main session's server and clients printed, for reading after a failure. */
const saveLogs = arg('save-logs', '');
/** Test only: invert one comparison (the two clocks must differ) to prove the tool can fail. */
const breakClock = arg('break', '') === 'clock';
/** Test only: --break=split counts every split sample as one (the screen-versus-host check must then fail). */
const breakSplit = arg('break', '') === 'split';
/** PL2: the Ward's lift return (the live setting ward.lift_minutes), set by the host's panel before the run starts. */
const liftMinutes = Number(arg('lift-minutes', 1));
/** PL2: --quick=1: the main session and fallback A only (no Cy, no fallback B), for the hotfix chain. */
const quick = arg('quick', '0') === '1';
const godot = process.env.GODOT || join(root, 'tools', 'godot', 'Godot_v4.7.2-stable_win64_console.exe');
if (!existsSync(godot)) throw new Error(`no engine at ${godot}: set GODOT`);
const P = { server: port, A: port + 1, B: port + 2, C: port + 3, fa: port + 6, fa1: port + 7, fb: port + 8, fb1: port + 9 };
for (const p of [...(doMain ? [P.server, P.A, P.B, P.C] : []), ...(doFallback ? [P.fa, P.fa1, P.fb, P.fb1] : [])]) if (!(p >= 4740 && p <= 4819)) throw new Error(`port ${p} is outside 4740-4819`);
if (!(liftMinutes >= 1 && liftMinutes <= 20 && Number.isInteger(liftMinutes))) throw new Error(`--lift-minutes=${liftMinutes}: a whole number from 1 to 20 (the setting's range)`);
const SECRET = 'test-passphrase';

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
  // PL3: once the line is gone (an old Ward scene freed with its channel) a command answers {} at once: a write to a
  // closed socket never calls back, and the command would wait for ever.
  let gone = false;
  sock.on('error', () => { gone = true; while (waiting.length) waiting.shift()('{}'); });
  sock.on('close', () => { gone = true; while (waiting.length) waiting.shift()('{}'); });
  let chain = Promise.resolve();
  const cmd = (c) => { const run = chain.then(() => new Promise((res) => { if (gone || sock.destroyed) { res('{}'); return; } waiting.push(res); try { sock.write(c + '\n'); } catch { res('{}'); } })); chain = run.catch(() => {}); return run; };
  return { sock, cmd };
}

const SHOW = /FLOOR |WARD REVIEW (READY|STATE|RESULT|CONTACT)|SCRIPT ERROR|test channel/;
async function game(label, testport, args) {
  const g = launch(['--headless', '--path', project, '--', 'auto=1', `testport=${testport}`, ...args], { echo: SHOW, label });
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

// PL3: `late_archive=memory`: the seed is fixed, and a tape carried out on one run is kept on disk for that seed
// (server/server.gd late_archive_root), so every later run would arrive to an empty table.
function server(p, label, extra) {
  return launch(['--headless', '--path', project, 'res://server/server.tscn', '--', 'server', `port=${p}`, 'bind=127.0.0.1', `seed=${seed}`, 'stats=30',
    'quota=0', 'watchers=0', 'orientation_campaign=0', 'depth=5', 'late_archive=memory', ...extra], { env: { GD_JOIN_SECRET: SECRET }, echo: /TEST:|not started|listening/, label });
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

/** PL2: the host (the first client) sets ward.lift_minutes through its settings panel, as the host does on the night
 * (tools/play_settings.mjs's path: the panel's set, the room's desk, the tune notice); the others' panels must show it. */
async function setLift(host, others, tag) {
  if (liftMinutes === 10) { log(`  ${tag}: ward.lift_minutes left at the game's 10`); return; }
  const sent = await host.cmd(`panel set ward.lift_minutes ${liftMinutes}`);
  const ph = await until(async () => JSON.parse(await host.cmd('panel state')), (p) => p.asked?.['ward.lift_minutes'] === liftMinutes, 8000, 100);
  const po = others ? await until(async () => JSON.parse(await others.cmd('panel state')), (p) => p.asked?.['ward.lift_minutes'] === liftMinutes, 8000, 100) : ph;
  check(`${tag}: the host sets the Ward's lift to ${liftMinutes} min on the settings panel (the room's desk takes it; ${others ? 'the other panel shows it' : 'alone'})`,
    sent === 'sent' && ph.asked?.['ward.lift_minutes'] === liftMinutes && po.asked?.['ward.lift_minutes'] === liftMinutes,
    `"${sent}", asked on the host ${J(ph.asked)}, on the other ${J(po.asked)}`);
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

// ---- PL2: the screen against the host, every sample, on every floor a player walks (main.gd `split`).
// Each client is polled about ten times a second: its own body (what its screen walks) and the host's row for it
// in the newest snapshot. The host's row is a little behind the screen (the input's trip and one tick), so the
// split of a sample is the distance from the host's row to the screen's own path over the last 0.8 s (the trail),
// not to where the screen is now: a host that accepted the steps lies on that path; a host that refused them stays
// put while the path walks away. A split above SPLIT_LIMIT for longer than SPLIT_MOMENT is a failure.
const SPLIT_LIMIT = 0.5;
const SPLIT_MOMENT = 0.6;
const TRAIL_S = 0.8;
const splits = {};
const segDist = (p, a, b) => {
  const dx = b[0] - a[0]; const dz = b[2] - a[2];
  const L = dx * dx + dz * dz;
  const u = L > 1e-9 ? Math.max(0, Math.min(1, ((p[0] - a[0]) * dx + (p[2] - a[2]) * dz) / L)) : 0;
  const q = [a[0] + u * dx, a[1] + u * (b[1] - a[1]), a[2] + u * dz];
  return Math.hypot(p[0] - q[0], p[2] - q[2], (p[1] - q[1]) * 0.5);
};
function startSplit(c) {
  const st = { label: c.label, n: 0, byDepth: {}, trail: [], over: null, long: [], stop: false, done: null, key: '' };
  splits[c.label] = st;
  st.done = (async () => {
    while (!st.stop && !c.g.exited) {
      let s = {};
      try { s = JSON.parse(await c.cmd('split')); } catch { s = {}; }
      const now = Date.now();
      // Not while the car rides (nobody walks; the host has the crew in the car's own frame between floors).
      if (Array.isArray(s.screen) && Array.isArray(s.host) && s.status !== 'out' && s.phase !== 'riding') {
        const key = `${s.depth}/${s.place}/${s.screen[3]}`;
        if (key !== st.key) { st.trail = []; st.over = null; st.key = key; }
        st.trail.push({ t: now, p: s.screen });
        while (st.trail.length > 2 && now - st.trail[0].t > TRAIL_S * 1000) st.trail.shift();
        const raw = Math.hypot(s.host[0] - s.screen[0], s.host[2] - s.screen[2]);
        let d = raw;
        for (let k = 1; k < st.trail.length; k++) d = Math.min(d, segDist(s.host, st.trail[k - 1].p, st.trail[k].p));
        if (s.host[3] !== s.screen[3]) d = Math.max(d, 99);
        if (breakSplit) d = SPLIT_LIMIT + 1;
        st.n++;
        const bd = st.byDepth[s.depth] ??= { n: 0, max: 0, raw: 0, over: 0 };
        bd.n++; bd.max = Math.max(bd.max, d); bd.raw = Math.max(bd.raw, raw);
        if (d > SPLIT_LIMIT) {
          bd.over++;
          const sample = { tick: s.tick, hostNow: s.hostNow, depth: s.depth, place: s.place, phase: s.phase, status: s.status, d: +d.toFixed(2),
            host: s.host.slice(0, 3).map((x) => +Number(x).toFixed(2)), screen: s.screen.slice(0, 3).map((x) => +Number(x).toFixed(2)), seq: s.seq, ackIn: s.ackIn };
          if (!st.over) st.over = { from: now, first: sample, worst: sample, logged: false };
          if (d > st.over.worst.d) st.over.worst = sample;
          if (!st.over.logged && now - st.over.from > SPLIT_MOMENT * 1000) {
            st.over.logged = true;
            st.long.push(st.over);
            log(`  SPLIT ${c.label}: the host's row and the screen more than ${SPLIT_LIMIT} m apart for over ${SPLIT_MOMENT} s: first ${J(st.over.first)}, worst so far ${J(st.over.worst)}`);
          }
        } else if (st.over) {
          if (st.over.logged) st.over.secs = (now - st.over.from) / 1000;
          st.over = null;
        }
      }
      await sleep(90);
    }
  })();
  return st;
}
async function stopSplits() {
  for (const st of Object.values(splits)) st.stop = true;
  await Promise.allSettled(Object.values(splits).map((st) => st.done));
}
function splitChecks() {
  for (const st of Object.values(splits)) {
    const floors = Object.entries(st.byDepth).map(([d, b]) => `floor ${d}: ${b.n} samples, split at most ${b.max.toFixed(2)} m (screen to host now ${b.raw.toFixed(2)} m), ${b.over} over ${SPLIT_LIMIT} m`).join('; ');
    check(`split: ${st.label}'s screen and the host's row for ${st.label} never more than ${SPLIT_LIMIT} m apart for more than ${SPLIT_MOMENT} s`, st.n > 20 && st.long.length === 0,
      `${st.n} samples; ${floors}${st.long.length ? `; ${st.long.length} long splits, the first ${J(st.long[0].first)} worst ${J(st.long[0].worst)}` : ''}`);
  }
}
/** Long splits on a floor so far for one client (the Ward's winch check reads it). */
const longOn = (label, depth) => (splits[label]?.long ?? []).filter((o) => o.first.depth === depth);

// ---- Ward helpers: routes through the Ward walk model the screen walks with (main.gd `wardroute`).
// PL3: every waypoint of the route (0.3 m apart, each a step the walk model takes), at half a walk. A waypoint is
// passed once within 0.2 m or once the walker is nearer the next one than it is to it. PL2 aimed at every second
// waypoint at a full walk and dropped one once within 0.35 m: through the parlour's side door that cut the jamb and
// the walker stuck there (an offline replay of the route on the walk model, seed 183025961, did the same).
const PACE = 0.5;
async function follow(c, route, ms = 60000, gait = '0') {
  const end = Date.now() + ms;
  let i = 0;
  let last = null;
  let stuckSince = Date.now();
  while (i < route.length && Date.now() < end) {
    const s = await c.state();
    if (!s.me) { await sleep(60); continue; }
    const at = [s.me.x, s.me.y, s.me.z];
    while (i < route.length - 1 && (flat(at, route[i]) < 0.2 || flat(at, route[i + 1]) < flat(route[i], route[i + 1]))) i++;
    const w = route[i];
    if (i === route.length - 1 && flat(at, w) < 0.3) break;
    await c.cmd(`face ${w[0]} ${w[2]}`);
    await c.cmd(`move ${PACE} 0 0 ${gait}`);
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
    res = await follow(c, route, ms);
    if (Math.hypot(res.at[0] - x, res.at[2] - z) < radius + 0.4) return { ok: true, ...res, steps: route.length };
  }
  return { ok: false, why: 'stopped short', ...res };
}

// ---- Reactor helpers: the station is a plan floor (2 m cells).
const cellOf = (x, z) => [Math.floor(x / 2), Math.floor(z / 2)];
async function approach(c, x, z, near, gait = '0', ms = 8000) {
  const end = Date.now() + ms;
  let s = await c.state();
  while (s.me && s.me.status === 'ok' && Math.hypot(s.me.x - x, s.me.z - z) > near && Date.now() < end) {
    await c.cmd(`face ${x} ${z}`);
    await c.cmd(gait === 'creep' ? 'move 1 0 0 1' : `move 1 0 ${gait} 0`);
    await sleep(50);
    s = await c.state();
  }
  await c.cmd('stopmove');
  return c.state();
}
async function goTo(c, x, z, near, gait = 'walk') {
  const [cx, cz] = cellOf(x, z);
  await c.cmd(`walkto 0 ${cx} ${cz} ${gait === 'sprint' ? 5 : 3} ${gait}`);
  await until(c.state, (s) => s.auto !== 'walking' || (s.me && Math.hypot(s.me.x - x, s.me.z - z) < near), 30000, 60);
  await c.cmd('stopwalk');
  return approach(c, x, z, near, gait === 'sprint' ? '1' : '0');
}
async function press(c, held = 400) { await c.cmd('use 1'); await sleep(held); await c.cmd('use 0'); }

// ---- PL2: the Reactor played sensibly. The four pursue the nearest standing player they can walk to, at 3.4 m/s
// (a sprint is 5, a walk 3), never into the cable crawl (creep only, 1.2 m/s).
const findings = [];
/** Something the game did to the crew (not a disagreement between the screens): reported, never a failure. */
const finding = (what, detail) => { findings.push({ what, detail }); log(`FINDING ${what} (${detail})`); };
const runners = (l) => (l.reactor?.crew ?? []).filter((b) => b[5] === 'zombie_run');
const nearRun = (l, x, z) => Math.min(Infinity, ...runners(l).map((b) => Math.hypot(b[0] - x, b[2] - z)));
const cellMid = (c) => [c[0] * 2 + 1, c[1] * 2 + 1];
/** While the medic has a client, the main flow leaves it alone. */
async function free(c) { while (c.medic) await sleep(100); }
/** To (x, z) through the plan (the client's own walkto), sprinting while a standing body is within `chased` m or
 * when asked, walking otherwise, or creeping. The last steps straight at it. Stops if this player goes down. */
async function drive(c, x, z, near, { creep = false, sprint = false, chased = 9, ms = 30000 } = {}) {
  await free(c);
  const end = Date.now() + ms;
  const [cx, cz] = cellOf(x, z);
  let gait = '';
  let s = await c.state();
  // PL3: a walk that has not shown as walking yet is not a walk that gave up: allow a few polls (and one more ask)
  // before the last stretch straight at the spot (a straight line from the lift to the tape's table meets walls).
  let idle = 0;
  while (s.me && s.me.status === 'ok' && Math.hypot(s.me.x - x, s.me.z - z) > Math.max(near, 1.6) && Date.now() < end && !c.medic) {
    const l = await c.late();
    const want = creep ? 'creep' : sprint || nearRun(l, s.me.x, s.me.z) < chased ? 'sprint' : 'walk';
    // walkto's 4th number is the pace in m/s, capped by the gait (play_link.gd walk_to): a sprint needs 5.
    if (want !== gait || (s.auto !== 'walking' && idle % 3 === 0)) { await c.cmd(`walkto 0 ${cx} ${cz} ${want === 'sprint' ? 5 : want === 'creep' ? 1.2 : 3} ${want}`); gait = want; }
    await sleep(110);
    s = await c.state();
    if (s.auto === 'walking') idle = 0;
    else if (gait === want && ++idle >= 6) {
      // walkto gave up (a cell it will not path to): the last stretch straight at the spot.
      break;
    }
  }
  await c.cmd('stopwalk');
  if (s.me?.status !== 'ok' || c.medic) return s;
  return approach(c, x, z, near, creep ? 'creep' : sprint ? '1' : '0', 6000);
}
/** Into the crawl by one of its mouths (outside cell, crawl cell) and on to a cell deeper in. */
async function intoCrawl(c, mouth, deep, opts = {}) {
  const o = cellMid(mouth.out);
  const i = cellMid(mouth.in);
  const d = cellMid(deep);
  let s = await drive(c, o[0], o[1], 0.6, opts);
  if (s.me?.status === 'ok') s = await approach(c, i[0], i[1], 0.45, 'creep', 8000);
  if (s.me?.status === 'ok') s = await approach(c, d[0], d[1], 0.5, 'creep', 8000);
  const inCrawl = s.me ? (s.me && cellKeyIn(s.me.x, s.me.z, mouth)) : false;
  return { s, inCrawl };
}
let crawlCells = new Set();
const cellKeyIn = (x, z) => crawlCells.has(cellOf(x, z).join(','));
/** Out of the crawl by a mouth: creep to its crawl cell, then out to the cell beyond. */
async function outOfCrawl(c, mouth) {
  await free(c);
  const i = cellMid(mouth.in);
  const o = cellMid(mouth.out);
  let s = await approach(c, i[0], i[1], 0.45, 'creep', 12000);
  if (s.me?.status === 'ok') s = await approach(c, o[0], o[1], 0.5, 'creep', 6000);
  return s;
}
/** To the landing at a sprint when chased, then in through the doors (board()). */
async function boardRun(c) {
  await free(c);
  const pl = JSON.parse(await c.cmd('plan'));
  const lx = pl.landing.x * 2 + 1;
  const lz = pl.landing.y * 2 + 1;
  const s = await drive(c, lx, lz, 1.0, { chased: 12 });
  if (s.me?.status !== 'ok') return { status: s.me?.status };
  const b = await board(c, 'down');
  return { status: b.me?.status, aboard: b.me?.aboard };
}
/** A background medic: when one player is down and the other on their feet, the other goes to heal them, but only
 * once no standing body is within SAFE m of the downed player (the catcher has moved off); holds F until they are up. */
function startMedic(cs) {
  const SAFE = 9;
  const m = { stop: false, log: [], done: null, hud: false };
  m.done = (async () => {
    while (!m.stop) {
      await sleep(200);
      const ss = await Promise.all(cs.map((c) => c.state()));
      const di = ss.findIndex((s) => s.me?.status === 'down');
      const hi = ss.findIndex((s) => s.me?.status === 'ok');
      if (di < 0) continue;
      const dn = cs[di];
      if (!m.hud) {
        m.hud = true;
        const t0 = Date.now();
        const dv = await until(dn.state, (s) => /^DOWN/.test(s.downs?.hud?.head ?? '') || s.me?.status !== 'down', 3000, 40);
        check('Reactor: the downed player has something to do within seconds (the timer and the line)', /^DOWN/.test(dv.downs?.hud?.head ?? '') && (dv.downs?.hud?.line ?? '') !== '',
          `${dn.label}: "${dv.downs?.hud?.head}" / "${dv.downs?.hud?.line}" / "${dv.downs?.hud?.line2}", ${r2((Date.now() - t0) / 1000)} s after the tool saw the down`);
      }
      if (hi < 0) continue;
      const hl = cs[hi];
      const l = await hl.late();
      const at = ss[di].me;
      const near = nearRun(l, at.x, at.z);
      if (near < SAFE) { continue; }
      hl.medic = true;
      try {
        await hl.cmd('stopwalk');
        m.log.push({ healer: hl.label, downed: dn.label, hostNow: l.hostNow, nearestStanding: +near.toFixed(1) });
        let s = await approach(hl, at.x, at.z, 0.9, '1', 8000);
        if (s.me?.status !== 'ok') continue;
        await hl.cmd(`face ${at.x} ${at.z} 0.2`);
        await hl.cmd('use 1');
        const up = await until(async () => ({ d: await dn.state(), l: await hl.late(), h: await hl.state() }),
          (x) => x.d.me?.status !== 'down' || x.h.me?.status !== 'ok' || nearRun(x.l, at.x, at.z) < 2.5, 6000, 60);
        await hl.cmd('use 0');
        m.log.push({ healed: up.d.me?.status === 'ok', downed: up.d.me?.status, healer: up.h.me?.status, hostNow: up.l.hostNow });
      } finally { hl.medic = false; }
    }
  })();
  return m;
}

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
    await setLift(A, B, 'main');
    startSplit(A);
    startSplit(B);
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
    check(`Ward: the lift is due back ${liftMinutes} min after it left (ward.lift_minutes), the same collectionAt on both`,
      dep[0] && Math.abs(la.ward.collectionAt - dep[0].t - liftMinutes * 60) < 1e-6 && la.ward.collectionAt === lb.ward.collectionAt,
      `departed ${dep[0]?.t}, collectionAt A ${la.ward.collectionAt} B ${lb.ward.collectionAt}: ${r2(la.ward.collectionAt - (dep[0]?.t ?? 0))} s`);
    await sleep(1200);
    const pair = await sameTick(A, B);
    const ca = clockSecs(pair.a.clockLine);
    const cb = clockSecs(pair.b.clockLine);
    const left = pair.a.ward.collectionAt - pair.a.hostNow;
    const sameClock = pair.a.ward.collectionAt === pair.b.ward.collectionAt && Math.abs(ca - cb) <= 1;
    check('Ward: both see the same LIFT RETURNS clock (same collectionAt, lines within a second, read on ticks within one)', breakClock ? !sameClock : sameClock && Math.abs(ca - left) <= 1.5 && pair.gap <= 1,
      `A "${pair.a.clockLine}" B "${pair.b.clockLine}", collectionAt A ${pair.a.ward.collectionAt} B ${pair.b.ward.collectionAt}, host left ${r2(left)} s, ticks ${pair.a.tick}/${pair.b.tick}`);
    if (breakClock || breakSplit) throw new Error('--break: the session stops after the Ward clock check');
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
    const wardLong = longOn('A', 6);
    check('Ward: on the walk to the winch the host accepts Ann\'s steps (her screen and the host\'s row for her stay within 0.5 m)', !wardLong.length && Number.isFinite(reach) && reach <= 1.25,
      wardLong.length ? `split from ${J(wardLong[0].first)}, worst ${J(wardLong[0].worst)}, lift door ${J(door)}; at the switch the host has her ${r2(reach)} m from it` : `host row ${r2(reach)} m from the switch`);
    const bev = [evOf(la, 'ward_bridge').at(-1), evOf(lb, 'ward_bridge').at(-1)];
    check('Ward: Ann works the winch and Bob\'s screen sees the bridge move (block and drawn walk model)', used && lb.ward.bridgeLowered !== before && lb.wardModel.bridgeLowered === lb.ward.bridgeLowered && la.ward.bridgeLowered === lb.ward.bridgeLowered,
      `switch ${used?.k} house ${used?.house}; Bob's bridge ${before} -> ${lb.ward.bridgeLowered} (walk model ${lb.wardModel?.bridgeLowered}), Ann's ${la.ward.bridgeLowered}`);
    check('Ward: the bridge event is the same host time on both', bev[0] && bev[1] && bev[0].t === bev[1].t && bev[0].lowered === bev[1].lowered, `A ${J(bev[0])} B ${J(bev[1])}`);
    // The winch is heard: the Rigger of that house comes. Ann raises the instrument near it.
    la = await until(A.late, (x) => ['searching', 'climbing', 'warning'].includes(x.ward.encounter), 4000, 50);
    const enc = la.ward.encounter;
    await A.cmd('raise 1');
    await until(A.late, (x) => x.ward.encounter === 'searching' || x.ward.encounter === 'idle', 6000, 60);
    await sleep(4000);
    await A.cmd('raise 0');
    // The reading closes when the instrument comes down; wait for its event on both screens.
    await until(A.late, (x) => evOf(x, 'readingClosed').length > 0, 3000, 100);
    await until(B.late, (x) => evOf(x, 'readingClosed').length > 0, 3000, 100);
    [la, lb] = [await A.late(), await B.late()];
    const rA = evOf(la, 'readingClosed');
    const rB = evOf(lb, 'readingClosed');
    const [sa, sb] = [await A.state(), await B.state()];
    // `tapes` in a client's state is that player's own pocket: Ann's holds her reading, Bob's nothing of hers.
    const annSum = rA.filter((e) => e.playerId === la.me).reduce((a, e) => a + e.value, 0);
    if (!rA.length) finding('no reading closed near the Rigger on the Ward', `encounter ${enc} (house ${la.ward.house}), caught ${J(la.ward.caught)}`);
    check('Ward: the readings near the Rigger, the same on both screens (and in Ann\'s own pocket)', J(rA) === J(rB) && Math.abs((sa.tapes?.value ?? 0) - annSum) < 0.01,
      `encounter ${enc} (house ${la.ward.house}); Ann's readings on A ${J(rA.map((e) => [e.playerId, e.value, e.t]))}, on B ${J(rB.map((e) => [e.playerId, e.value, e.t]))}; tapes A ${J(sa.tapes)} B ${J(sb.tapes)}`);
    const caught = [la.ward.caught, lb.ward.caught];
    if (caught[0].length) log(`  caught on the Ward: ${J(caught[0])}`);
    // Back to the parlour beside the lift to wait.
    // Back to the lift. A house whose Rigger is searching holds its door as the arm does (sim/ward/state.gd
    // walk_clear): when there is no way out, wait for the encounter to end and try again.
    let backA = await wardGo(A, door[0] - 0.3, door[2] + 2.2, 30000);
    for (let k = 0; k < 4 && !backA.ok; k++) {
      const lw = await A.late();
      log(`  Ann has no way back yet (${backA.why}): encounter ${lw.ward?.encounter} house ${lw.ward?.house}, doors ${J(lw.ward?.doors)}, caught ${J(lw.ward?.caught)}, bridge ${lw.ward?.bridgeLowered}, lift ${lw.ward?.phase} in ${r2((lw.ward?.collectionAt ?? 0) - (lw.hostNow ?? 0))} s`);
      if (!lw.ward || (lw.ward.caught ?? []).includes(lw.me)) break;
      await until(A.late, (x) => x.ward?.encounter === 'idle' || !x.ward, 20000, 250);
      backA = await wardGo(A, door[0] - 0.3, door[2] + 2.2, 30000);
    }
    if (!backA.ok) {
      const lw = await A.late();
      finding('Ann could not get back to the Ward lift', `encounter ${lw.ward?.encounter} house ${lw.ward?.house}, doors ${J(lw.ward?.doors)}, caught ${J(lw.ward?.caught)}, at ${J([lw.localBody?.x, lw.localBody?.z].map(r2))}, host time ${lw.hostNow}`);
    }
    log(`  Ann back by the lift: ${J({ ok: backA.ok, why: backA.why })}; waiting for the lift (${r2(la.ward.collectionAt - la.hostNow)} s)`);
    // The host's panel (Ann is the host): the Reactor's lights hold the game's 45 s (left as is).
    la = await until(A.late, (x) => x.ward?.phase === 'boarding' || !x.ward, liftMinutes * 60000 + 60000, 500);
    lb = await until(B.late, (x) => x.ward?.phase === 'boarding' || !x.ward, 5000, 50);
    if (!la.ward || !lb.ward) throw Object.assign(new Error(), { stop: true, message: `the Ward was over before Ann was back by the lift (A depth ${la.depth}, B depth ${lb.depth}): the rest of the session cannot run` });
    const ret = [evOf(la, 'ward_returned')[0], evOf(lb, 'ward_returned')[0]];
    check('Ward: the lift returns on the same host time on both', la.ward.phase === 'boarding' && lb.ward.phase === 'boarding' && ret[0] && ret[1] && ret[0].t === ret[1].t && Math.abs(ret[0].t - la.ward.collectionAt) < 1e-6,
      `A ${la.ward.phase} t ${ret[0]?.t}, B ${lb.ward.phase} t ${ret[1]?.t}, collectionAt ${la.ward.collectionAt}, departAt A ${la.ward.departAt} B ${lb.ward.departAt}`);
    const lm = [evOf(la, 'ward_last_minute'), evOf(lb, 'ward_last_minute')];
    check(liftMinutes > 1 ? 'Ward: the one-minute reminder, the same host time on both, a minute before the return' : 'Ward: at a one-minute return there is no separate one-minute reminder (on both)',
      liftMinutes > 1 ? lm[0].length === 1 && J(lm[0]) === J(lm[1]) && Math.abs(lm[0][0].t - (la.ward.collectionAt - 60)) < 1e-6 : lm[0].length === 0 && lm[1].length === 0,
      `A ${J(lm[0])} B ${J(lm[1])}, collectionAt ${la.ward.collectionAt}`);
    const wardOrder = (x) => (x.events ?? []).filter((e) => String(e.type).startsWith('ward_')).map((e) => [e.type, e.t]);
    check('Ward: the same Ward events in the same order on both screens', J(wardOrder(la)) === J(wardOrder(lb)), `A ${J(wardOrder(la))} B ${J(wardOrder(lb))}`);
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
    // PL2: the crew plays it as a crew would. Bob takes the tape off the table at once (it can be taken any time) and
    // waits in the cable crawl (creep only: the four never enter it). Ann starts the hold, waits by the fuse, takes it
    // at the cut, sprints it to the cabinet, calls the lift and goes to ground in the crawl's other end. When the car
    // is in, Bob carries the tape out through the gallery while Ann draws from the hall side. A downed player is
    // healed only once no standing body is near them. What the four do to the crew is reported (FINDING), never a
    // failure: the checks are that the two screens and the host agree.
    const st = la.station;
    const fuse = la.reactor.fuseAt;
    const tape = la.reactor.tapeAt;
    const cab = st.cabinet.at;
    const crawlSet = new Set((st.crawl ?? []).map((c) => `${c[0]},${c[1]}`));
    const mouths = (st.crawl_mouths ?? []).map((m) => {
      const inA = crawlSet.has(`${m[0]},${m[1]}`);
      return { out: inA ? [m[2], m[3]] : [m[0], m[1]], in: inA ? [m[0], m[1]] : [m[2], m[3]] };
    });
    const deeper = (m) => { // a crawl cell next to the mouth's crawl cell, away from the mouth
      for (const [dx, dz] of [[0, -1], [0, 1], [-1, 0], [1, 0]]) {
        const c = [m.in[0] + dx, m.in[1] + dz];
        if (crawlSet.has(`${c[0]},${c[1]}`) && (c[0] !== m.out[0] || c[1] !== m.out[1])) return c;
      }
      return m.in;
    };
    const [hatch, opening] = [mouths[0], mouths[1]];
    const deeper2 = (m) => { const d = deeper(m); return deeper({ in: d, out: m.in }); };
    crawlCells = crawlSet;
    log(`  Reactor plan: tape ${J(tape)}, fuse ${J(fuse)}, cabinet ${J(cab)}, crawl ${crawlSet.size} cells, gallery hatch ${J(hatch)}, hall opening ${J(opening)}`);
    await stepOut([A, B]);
    const land = st.landing;
    const hall = st.hall;
    const hx = land[0] + land[2] / 2;
    const hz = Math.max(hall[1] + 1, land[1] - 3);
    // Bob takes the tape before anything moves.
    const bobTape = (async () => {
      let s = await drive(B, tape[0], tape[2], 1.4);
      for (let k = 0; k < 2 && s.me?.status === 'ok' && Math.hypot(s.me.x - tape[0], s.me.z - tape[2]) > 1.4; k++) s = await drive(B, tape[0], tape[2], 1.4);
      log(`  Bob at the tape's table: ${r2(Math.hypot(s.me?.x - tape[0], s.me?.z - tape[2]))} m from it`);
      for (let k = 0; k < 4 && (await B.late()).reactor?.cassetteHolder !== (await B.late()).me; k++) await press(B, 300);
      return until(B.late, (x) => x.reactor?.cassetteHolder === x.me, 2000, 50);
    })();
    const annIn = drive(A, hx, hz, 0.8);
    const [lt] = await Promise.all([bobTape, annIn]);
    check('Reactor: Bob takes the tape from the table (the same holder on Ann\'s screen)', lt.reactor?.cassetteHolder === lt.me && (await until(A.late, (x) => x.reactor?.cassetteHolder === lt.me, 1500, 50)).reactor?.cassetteHolder === lt.me,
      `holder ${lt.reactor?.cassetteHolder}, Bob ${lt.me}; Bob's screen ${J(lt.localBody)}, the host's row for him ${J(lt.hostBody)} (${r2(Math.hypot((lt.hostBody?.x ?? NaN) - tape[0], (lt.hostBody?.z ?? NaN) - tape[2]))} m from the tape), prompt "${lt.prompt}", collected ${lt.reactor?.collected ?? lt.reactor?.cassette}`);
    // The hold starts when the first player on their feet passes the landing (sim/station_floor.gd step: the event
    // "powerHold" with t and len). PL3: Ann is on her way into the hall by now; should she not be on her feet here (left
    // on the Ward, say) it is Bob's walk to the crawl that starts it, later: wait for it as long as a cut can take.
    [la, lb] = [await until(A.late, (x) => evOf(x, 'powerHold').length > 0, 60000, 100), await until(B.late, (x) => evOf(x, 'powerHold').length > 0, 3000, 100)];
    const hold = [evOf(la, 'powerHold')[0], evOf(lb, 'powerHold')[0]];
    check('Reactor: the lights hold once someone passes the landing, the same host event on both', hold[0] && hold[1] && hold[0].t === hold[1].t && hold[0].len === hold[1].len,
      `A ${J(hold[0])} B ${J(hold[1])}`);
    // Ann to the fuse, Bob into the crawl by the gallery hatch, both before the cut.
    const [fa, bc] = await Promise.all([drive(A, fuse[0], fuse[2], 1.2), intoCrawl(B, hatch, deeper2(hatch))]);
    log(`  before the cut: Ann ${r2(Math.hypot(fa.me?.x - fuse[0], fa.me?.z - fuse[2]))} m from the fuse; Bob in the crawl ${bc.inCrawl} at ${J([bc.s.me?.x, bc.s.me?.z].map(r2))}`);
    [la, lb] = [await until(A.late, (x) => evOf(x, 'powerCut').length > 0, 70000, 60), await until(B.late, (x) => evOf(x, 'powerCut').length > 0, 3000, 50)];
    const cut = [evOf(la, 'powerCut')[0], evOf(lb, 'powerCut')[0]];
    check('Reactor: the power cuts on the same host tick on both, the hold after it started', cut[0] && cut[1] && cut[0].t === cut[1].t && hold[0] && Math.abs(cut[0].t - hold[0].t - hold[0].len) <= 0.051 && la.reactor.power === 1 && lb.reactor.power === 1,
      `cut A t ${cut[0]?.t} B t ${cut[1]?.t}, hold from ${hold[0]?.t} for ${hold[0]?.len} s, power A ${la.reactor.power} B ${lb.reactor.power}`);
    // A third client joins now (not in --quick).
    const cJoin = quick ? Promise.resolve(null) : joinRoom('C', P.C, url, 'Cy').catch((e) => { log(`  Cy could not join: ${e.message}`); return null; });
    if (quick) skip('late joiner (Cy)', '--quick=1 leaves the third client out');
    // Ann takes the fuse at once.
    const annAtCut = (await A.state()).me;
    if (annAtCut?.status !== 'ok') {
      // PL3: what the game did to her (left on the Ward, caught, down) is a finding; the screens still must agree.
      finding('Ann was not on her feet at the cut, so she could not take the fuse', `Ann ${annAtCut?.status} at ${J([annAtCut?.x, annAtCut?.z].map(r2))}`);
      const [ha, hb] = [await A.late(), await B.late()];
      check('Reactor: the fuse holder at the cut is the same on both screens', ha.reactor?.holder === hb.reactor?.holder, `holder A ${ha.reactor?.holder} B ${hb.reactor?.holder}`);
    } else {
      for (let k = 0; k < 6 && (await A.late()).reactor?.holder !== la.me; k++) await press(A, 250);
      const fz = await until(A.late, (x) => x.reactor?.holder === x.me, 1500, 50);
      const fzB = await until(B.late, (x) => x.reactor?.holder === fz.me, 1500, 50);
      check('Reactor: Ann takes the fuse at the cut (the host\'s holder, the same on Bob\'s screen)', fz.reactor?.holder === fz.me && fzB.reactor?.holder === fz.me,
        `holder A ${fz.reactor?.holder} B ${fzB.reactor?.holder}, Ann ${fz.me}, ${r2((fz.hostNow ?? 0) - (cut[0]?.t ?? 0))} s after the cut`);
    }
    [la, lb] = [await until(A.late, (x) => evOf(x, 'stationStir').length > 0, 8000, 50), await until(B.late, (x) => evOf(x, 'stationStir').length > 0, 3000, 50)];
    const stir = [evOf(la, 'stationStir')[0], evOf(lb, 'stationStir')[0]];
    const stands = evOf(la, 'bodyStands');
    check('Reactor: the four stir, the same host event on both, before any of them stands (heard before it reaches anyone)', stir[0] && stir[1] && stir[0].t === stir[1].t && (stands.length === 0 || stands[0].t > stir[0].t),
      `stir A ${J(stir[0])} B ${J(stir[1])}, first stands ${stands[0]?.t}`);
    // To the cabinet at a sprint, and the fuse in.
    const medic = startMedic([A, B]);
    let atCab = await drive(A, cab[0], cab[2], 1.3, { sprint: true });
    for (let k = 0; k < 6 && atCab.me?.status === 'ok' && evOf(await A.late(), 'powerRestored').length === 0; k++) { await press(A, 250); atCab = await A.state(); }
    [la, lb] = [await until(A.late, (x) => evOf(x, 'powerRestored').length > 0, 3000, 50), await B.late()];
    lb = await until(B.late, (x) => evOf(x, 'powerRestored').length > 0 || evOf(la, 'powerRestored').length === 0, 3000, 50);
    const rest = [evOf(la, 'powerRestored')[0], evOf(lb, 'powerRestored')[0]];
    if (rest[0] || rest[1]) {
      check('Reactor: power restored at the cabinet, the same host event on both', rest[0] && rest[1] && rest[0].t === rest[1].t && la.reactor.power === 2 && lb.reactor.power === 2,
        `A ${J(rest[0])} B ${J(rest[1])}, power ${la.reactor.power}/${lb.reactor.power}, ${r2((rest[0]?.t ?? 0) - (cut[0]?.t ?? 0))} s after the cut`);
    } else finding('the power was not restored', `Ann ${atCab.me?.status} at ${J([atCab.me?.x, atCab.me?.z].map(r2))}, ${r2(Math.hypot(atCab.me?.x - cab[0], atCab.me?.z - cab[2]))} m from the cabinet; fuse holder ${la.reactor?.holder}; catches ${J(evOf(la, 'caught').map((e) => [e.playerId, e.t]))}`);
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
    // The call, by whoever is on their feet with the power back (Ann is beside the landing), then to ground.
    let called = { ok: false, why: 'power not restored' };
    if (rest[0]) {
      const caller = (await A.state()).me?.status === 'ok' ? A : B;
      const cs0 = (await caller.state()).me;
      if (cs0 && cellKeyIn(cs0.x, cs0.z)) await outOfCrawl(caller, hatch);
      called = await callLift(caller, 30000).catch((e) => ({ ok: false, why: String(e) }));
      if (called.ok) {
        const pa = (await A.late()).phase;
        const pb = (await B.late()).phase;
        check('Reactor: the lift is called with the power back (the same lift phase on both screens)', ['coming', 'arriving', 'boarding'].includes(pa) && pa === pb,`${caller.label} called; A ${pa} B ${pb}`);
      } else finding('the lift could not be called', J(called));
    }
    // To ground in the crawl by the gallery hatch (beside the switch room), whoever made the call; Bob is deeper in.
    for (const c of [A, B]) {
      const me = (await c.state()).me;
      if (me?.status === 'ok' && !cellKeyIn(me.x, me.z)) {
        const ac = await intoCrawl(c, hatch, deeper(hatch), { sprint: true });
        log(`  ${c.label} to the crawl by the gallery hatch: in ${ac.inCrawl}, status ${ac.s.me?.status}`);
      }
    }
    // Wait for the car (or for the crew to be gone).
    const wait = await until(async () => ({ ...(await A.late()), b: await B.state(), a: await A.state() }),
      (x) => x.phase === 'boarding' || (x.a.me?.status !== 'ok' && x.b.me?.status !== 'ok' && x.a.me?.status !== 'down' && x.b.me?.status !== 'down') || x.depth !== 7, called.ok ? 120000 : 5000, 250);
    log(`  the car: phase ${wait.phase}, Ann ${wait.a.me?.status}, Bob ${wait.b.me?.status}`);
    if (wait.phase === 'boarding') {
      // Bob carries the tape out through the gallery; Ann comes out of the hall side and boards behind him.
      // Ann (nearer the hatch) out first and draws; Bob with the tape behind her.
      const goAnn = (async () => { if ((await A.state()).me?.status !== 'ok') return null; await outOfCrawl(A, hatch); return boardRun(A); })();
      await sleep(1500);
      const goBob = (async () => { if ((await B.state()).me?.status !== 'ok') return null; await outOfCrawl(B, hatch); return boardRun(B); })();
      const [rb, ra] = await Promise.all([goBob, goAnn]);
      log(`  boarding: Bob ${J(rb)}, Ann ${J(ra)}`);
    }
    medic.stop = true;
    await medic.done;
    // Up, or not: both screens must agree on where the run went.
    [la, lb] = [await until(A.late, (x) => x.depth !== 7, wait.phase === 'boarding' ? 90000 : 20000, 200), await until(B.late, (x) => x.depth !== 7, 20000, 100)];
    const ext = [evOf(la, 'tapeExtracted')[0], evOf(lb, 'tapeExtracted')[0]];
    const [fa2, fb2] = [await A.state(), await B.state()];
    check('Reactor: both screens agree where the run went after the Reactor (the same depth on both)', la.depth === lb.depth, `depth A ${la.depth} B ${lb.depth}, phase A ${la.phase} B ${lb.phase}; Ann ${fa2.me?.status} Bob ${fb2.me?.status}`);
    if (la.depth === 0) log(`  FINDING (reported, not a failure): the crew rode up to the prison (Ann ${fa2.me?.status}, Bob ${fb2.me?.status})`);
    else finding('the crew did not ride up from the Reactor', `depth A ${la.depth} B ${lb.depth}, phase ${la.phase}, Ann ${fa2.me?.status} Bob ${fb2.me?.status}`);
    if (ext[0] || ext[1]) {
      check('Reactor: the tape carried out is recorded (the same event on both, the archive has it)', ext[0] && ext[1] && ext[0].t === ext[1].t && la.reactor?.extracted !== false && (la.reactor?.archive?.recovered ?? true) === true,
        `A ${J(ext[0])} B ${J(ext[1])}, extracted ${la.reactor?.extracted}, archive ${J(la.reactor?.archive)}`);
    } else finding('the tape was not carried out', `holder at the end ${la.reactor?.cassetteHolder ?? '(no block)'}; depth ${la.depth}`);
    // The run's catches, downs and heals, in order, on both screens.
    const lateOrder = (x) => (x.events ?? []).filter((e) => ['powerHold', 'powerCut', 'stationStir', 'bodyStands', 'fuseTaken', 'fuseDropped', 'powerRestored', 'tapeTaken', 'tapeDropped', 'tapeExtracted', 'caught', 'downed', 'healed', 'out'].includes(e.type)).map((e) => [e.type, e.t, e.playerId ?? e.seat ?? '']);
    check('Reactor: the same Reactor events in the same order on both screens (stir, stands, fuse, tape, catches, downs, heals)', lateOrder(la).length > 3 && J(lateOrder(la)) === J(lateOrder(lb)),
      `${lateOrder(la).length} events on A, ${lateOrder(lb).length} on B${J(lateOrder(la)) === J(lateOrder(lb)) ? '' : `; A ${J(lateOrder(la))} B ${J(lateOrder(lb))}`}`);
    const catches = evOf(la, 'caught').map((e) => ({ who: e.playerId, t: e.t, afterCut: +(e.t - (cut[0]?.t ?? 0)).toFixed(2) }));
    if (catches.length) finding(`${catches.length} catch(es) on the Reactor`, `${J(catches)}; heals ${J(evOf(la, 'healed').map((e) => [e.playerId, e.t]))}; outs ${J(evOf(la, 'out').map((e) => [e.playerId, e.t]))}; medic ${J(medic.log)}`);
    if (C && (la.depth === 7 || !(fa2.me?.status === 'ok' || fb2.me?.status === 'ok'))) skip('late joiner: Cy admitted at the next stop', `the run did not go on with anyone on their feet (depth ${la.depth}, Ann ${fa2.me?.status}, Bob ${fb2.me?.status})`);
    else if (C) {
      const sc = await until(C.state, inGame, 30000, 200);
      check('late joiner: Cy is admitted at the next stop', inGame(sc), `screen ${scr(sc).screen}, depth ${sc.depth}`);
    }
  } catch (e) {
    if (e?.stop) finding('the main session stopped early', e.message);
    else check('main: the session ran to the end', false, String(e?.stack ?? e));
  } finally {
    await stopSplits();
    splitChecks();
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
/** PL3: a `reactor_place=0` server's floor 7 on a build with no old Reactor room: the screen printed FLOOR MEDIA
 * MISSING (never FLOOR ENTERED: no old room may be swapped in), the main scene is still on its game screen (with the
 * line main.gd floor_media_line puts on it; the old overlay's floor has no level drawn) and this client's newest
 * snapshot is the host's floor 7: it is still in the room. After the old Ward's hand back the main scene opens a new
 * test channel, so the line is opened again when it answers {}. */
async function stillInRoom(c, said) {
  const missing = /FLOOR MEDIA MISSING reactor/.test(said ?? '');
  const entered = c.g.lines.some((x) => /FLOOR ENTERED reactor/.test(x));
  let l = await c.late();
  if (l.depth === undefined) { await c.reconnect().catch(() => {}); l = await until(c.late, (x) => x.depth === 7, 15000, 200); }
  const s = await c.state();
  return { ok: missing && !entered && scr(s).screen === 'game' && l.depth === 7 && !c.g.exited,
    detail: `media missing ${missing}, an old room swapped in ${entered}, screen ${scr(s).screen}, the client's snapshot at depth ${l.depth} phase ${l.phase} (reactor block ${l.reactor ? 'there' : 'none'}), process running ${!c.g.exited}` };
}

async function fallbackA() {
  const url = `ws://127.0.0.1:${P.fa}`;
  const srv = server(P.fa, 'fallbackA', ['ward_place=0', 'reactor_place=0']);
  await until(async () => srv.lines.join('\n'), (t) => t.includes('listening on') || srv.exited, 40000);
  if (!check('fallback A: the server starts with ward_place=0 reactor_place=0', srv.lines.join('\n').includes('listening on'))) return;
  let F = null;
  try {
    F = await joinRoom('F', P.fa1, url, 'Fay', ['ward_handed_walk=1']);
    await setLift(F, null, 'fallback A');
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
    // PL2: the old Ward's test walk (client/ward/review.gd, ward_handed_walk=1 with auto=1): out of the lift, back in
    // when it returns; then the main game takes the room back. PL3: on floor 7 the old Reactor room is not in the game
    // (IP1), so the main game says so and keeps her in the room (main.gd _enter_floor).
    const seen = (re, ms) => until(async () => F.g.lines.find((x) => re.test(x)) ?? null, (x) => x !== null, ms, 250);
    const walk = await seen(/WARD REVIEW TEST WALK/, 5000);
    const away = await seen(/WARD REVIEW STATE .*phase=away/, 30000);
    const m = /collectionAt=([\d.]+)/.exec(away ?? '');
    const boarding = await seen(/WARD REVIEW STATE .*phase=boarding/, liftMinutes * 60000 + 60000);
    const result = await seen(/WARD REVIEW RESULT .*outcome=/, 60000);
    const reactor = await seen(/FLOOR ENTERED reactor|FLOOR MEDIA MISSING reactor/, 90000);
    check('fallback A: Fay walks out of the old Ward\'s lift, it leaves and returns on its clock, she boards',
      walk && away && boarding && /outcome=aboard/.test(result ?? ''), `"${walk}" / "${away}" / "${boarding}" / "${result}"`);
    const stay = await stillInRoom(F, reactor);
    check('fallback A: the old Ward hands the room back to the main game; on floor 7 the old Reactor room is not in this build by design (no packs), so the game says so and keeps Fay in the room (FLOOR MEDIA MISSING reactor, still on floor 7)',
      stay.ok, `"${reactor ?? F.g.lines.filter((x) => /FLOOR/.test(x)).join(' | ')}" (collectionAt ${m?.[1]}); ${stay.detail}`);
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
    G = await joinRoom('G', P.fb1, url, 'Gus');
    await setLift(G, null, 'fallback B');
    const l = await rideToWard([G], 'fallback B');
    const lg = await until(G.late, (x) => x.wardModel, 20000);
    const door = lg.wardModel.liftDoor;
    const out = await wardGo(G, door[0], door[2] + 2.6, 20000);
    const away = await until(G.late, (x) => x.ward?.phase === 'away', 5000, 50);
    check('fallback B: the native Ward on floor 6, Gus walks out, the lift leaves', l.ward?.native === true && out.ok && away.ward?.phase === 'away', `native ${l.ward?.native}, out ${out.ok}, phase ${away.ward?.phase}`);
    await until(G.late, (x) => x.ward?.phase === 'boarding', liftMinutes * 60000 + 60000, 500);
    const back = await wardGo(G, door[0], door[2] - 1.4, 30000);
    const t = Date.now();
    while (Date.now() - t < 150000 && !G.g.lines.some((x) => /FLOOR ENTERED reactor|FLOOR MEDIA MISSING reactor/.test(x))) await sleep(250);
    const said = G.g.lines.find((x) => /FLOOR ENTERED reactor|FLOOR MEDIA MISSING reactor/.test(x));
    const stay = await stillInRoom(G, said);
    check('fallback B: on floor 7 the old Reactor room is not in this build by design (no packs), so the game says so and keeps Gus in the room (FLOOR MEDIA MISSING reactor, still on floor 7)',
      back.ok && stay.ok, `boarded ${back.ok}; "${said ?? G.g.lines.filter((x) => /FLOOR/.test(x)).join(' | ')}"; ${stay.detail}`);
  } catch (e) {
    check('fallback B: ran to the end', false, String(e?.stack ?? e));
  } finally {
    const errors = [...(G?.g.lines ?? []), ...srv.lines].filter((x) => /SCRIPT ERROR|ERROR: .*\.gd/.test(x));
    check('fallback B: no script errors', errors.length === 0, errors.slice(0, 4).join(' | '));
    if (G) await G.close();
    srv.p.kill();
  }
}

log(`seed ${seed}, lift ${liftMinutes} min, ${quick ? 'quick' : 'full'}, no floor packs (everything ships in the game)`);
const jobs = [];
if (doMain) jobs.push(mainSession());
if (doFallback) { jobs.push(fallbackA()); if (!quick) jobs.push(fallbackB()); else skip('fallback B (reactor_place=0)', '--quick=1 runs the main session and fallback A only'); }
await Promise.allSettled(jobs);
await sleep(500);
cleanup();
if (findings.length) {
  console.log(`What the game did to the crew (reported, not failures): ${findings.length}`);
  for (const f of findings) console.log(`  FINDING ${f.what} (${f.detail})`);
}
const failed = results.filter((r) => !r.ok).length;
console.log(`${results.length - failed} passed, ${failed} failed`);
process.exit(failed ? 1 : 0);
