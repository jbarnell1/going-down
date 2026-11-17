// The announcer's hints in the real game (docs/floors/announcer-hints.md, AH1), headless on the project
// (no window): PLAY ALONE with the floor quota capped for the test (`auto=1 quota=N`, as play_quota.mjs).
//   1. at the lift before recording anything, call: refused, and the announcer says hint_call_dead;
//   2. record until the quota is met, call again: the car comes, and on its arrival the announcer says
//      hint_board in place of an "arrived" line;
//   3. the announcer's history never has two lines overlapping in time, and every hint started with
//      nothing else playing (its own log).
// The gate keeps hints 30 s apart, so before each press the script waits until 30 s have passed since the
// last hint started (the gate's rule, not a workaround: a hint asked for sooner is refused by design).
// The two-client part of AH1's playthrough (one client left on the landing hears hint_left_you, the
// other hint_left_crew) is not in this script.
// Usage: node godot/tools/play_hints.mjs [--port=4466] [--quota=20]   ($GODOT names the engine)
import { spawn } from 'node:child_process';
import { connect } from 'node:net';
import { dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const here = dirname(fileURLToPath(import.meta.url));
const project = resolve(here, '..');
const arg = (k, d) => (process.argv.find((a) => a.startsWith(`--${k}=`)) ?? `--${k}=${d}`).split('=')[1];
const port = Number(arg('port', 4466));
const cap = Number(arg('quota', 20));
const exe = process.env.GODOT || resolve(project, '..', 'tools', 'godot', 'Godot_v4.7.2-stable_win64_console.exe');
const consoleLines = [];
const game = spawn(exe, ['--headless', '--path', project, '--', 'auto=1', `quota=${cap}`, `testport=${port}`], { cwd: project, stdio: ['ignore', 'pipe', 'pipe'] });
const keep = (b) => { for (const l of b.toString().split(/\r?\n/)) if (l.trim()) consoleLines.push(l); };
game.stdout.on('data', keep);
game.stderr.on('data', keep);
let exited = false;
game.on('exit', () => { exited = true; });

let sock = null;
for (let i = 0; i < 300 && !sock && !exited; i++) {
  sock = await new Promise((res) => {
    const s = connect(port, '127.0.0.1', () => res(s));
    s.on('error', () => res(null));
  });
  if (!sock) await new Promise((r) => setTimeout(r, 150));
}
if (!sock) { console.log('could not reach the game\'s test channel', consoleLines.slice(-10)); game.kill(); process.exit(1); }
let buf = '';
const waiting = [];
sock.on('data', (d) => {
  buf += d.toString();
  let i;
  while ((i = buf.indexOf('\n')) >= 0) {
    const line = buf.slice(0, i);
    buf = buf.slice(i + 1);
    waiting.shift()?.(line);
  }
});
const cmd = (c) => new Promise((res) => { waiting.push(res); sock.write(c + '\n'); });
const wait = (ms) => new Promise((r) => setTimeout(r, ms));
const results = [];
const check = (name, ok, detail = '') => {
  results.push({ name, ok, detail });
  console.log(`${ok ? 'PASS' : 'FAIL'} ${name}${detail ? ` (${detail})` : ''}`);
};
const state = async () => JSON.parse(await cmd('state'));
const until = async (pred, ms = 30000, every = 100) => {
  const end = Date.now() + ms;
  let s = await state();
  while (!pred(s) && Date.now() < end) {
    await wait(every);
    s = await state();
  }
  return s;
};
const walk = async (level, x, y, pace = 6) => {
  await cmd(`walkto ${level} ${x} ${y} ${pace}`);
  await wait(200);
  return until((s) => s.auto !== 'walking', 60000);
};
// Every hint started in the log so far (the log is the newest 60 entries; collected as we go).
const starts = [];
const seen = new Set();
const collect = (s) => {
  for (const e of s.client.hintLog ?? []) {
    const k = `${e.what}|${e.moment}|${e.at}`;
    if (seen.has(k)) continue;
    seen.add(k);
    if (e.what === 'started') starts.push(e);
  }
};
// Waits until the gate's 30 s between hints has passed (the announcer's clock is the engine's ms).
const quietGate = async () => {
  for (;;) {
    const s = await state();
    collect(s);
    const h = s.client.history;
    const lastHint = [...h].reverse().find((x) => x.hint);
    const playing = h.length > 0 && h[h.length - 1].end < 0;
    const now = JSON.parse(await cmd('clock')).ms;
    // A hint still waiting in the queue (asked for, not yet started or expired) comes first.
    const log = s.client.hintLog ?? [];
    const lastAsk = [...log].reverse().find((e) => e.what === 'requested');
    const pending = lastAsk && !log.some((e) => e.at >= lastAsk.at && e.moment === lastAsk.moment && (e.what === 'started' || e.what === 'expired'));
    // hint_job is asked for 6 s after the first doors open: let it come first.
    if (!playing && !pending && now - startedAt > 9000 && (!lastHint || now - lastHint.at > 31000)) return s;
    await wait(500);
  }
};
const spokenAfter = (s, at) => s.client.history.filter((h) => h.at >= at).map((h) => h.id);

// ---- Start: PLAY ALONE, keep the face, wait for the run.
for (let i = 0; i < 200; i++) {
  if ((await cmd('ui alone')) === 'ok') break;
  await wait(100);
}
for (let i = 0; i < 50; i++) {
  if (JSON.parse(await cmd('screen')).screen === 'face') break;
  await wait(100);
}
await cmd('draw done');
let s = await until((s) => s.phase !== undefined, 30000);
await cmd('click');
const plan = JSON.parse(await cmd('plan'));
const car = plan.car;
s = await until((s) => s.phase === 'unloading' && s.client.doors > 0.95, 20000);
const startedAt = JSON.parse(await cmd('clock')).ms;
check('the run has the quota on, capped for the test', s.quota?.host?.needed === cap && s.depth === 1, `quota ${JSON.stringify(s.quota?.host)}`);
check('hints are on in a test run, with no record', s.client.hintsOn === true);

// ---- 1. Out to the landing, then call too early.
await cmd('move 1 0 0 0');
s = await until((s) => !s.me.aboard && Math.hypot(s.me.x - car.doorX, s.me.z - car.doorZ) > 1.6, 5000, 50);
await cmd('stopmove');
s = await until((s) => s.phase === 'away', 20000, 100);
await walk(plan.landing.level, plan.landing.x, plan.landing.y, 6);
s = await state();
await cmd(`face ${s.quota.at[0]} ${s.quota.at[2]} ${s.quota.at[1]}`);
s = await until((s) => s.me.canCall === true, 3000, 50);
s = await quietGate();
const t1 = JSON.parse(await cmd('clock')).ms;
const refused0 = s.events.callRefused ?? 0;
await cmd('call');
s = await until((s) => (s.events.callRefused ?? 0) > refused0, 3000, 30);
s = await until((s) => spokenAfter(s, t1).some((id) => id.startsWith('hint_call_dead_')), 9000, 100);
collect(s);
check('call before the quota: refused, and the announcer says hint_call_dead', spokenAfter(s, t1).some((id) => id.startsWith('hint_call_dead_')),
  `spoken since: ${spokenAfter(s, t1).join(', ') || 'nothing'}; subtitle "${s.client.subtitle}"; log ${JSON.stringify((s.client.hintLog ?? []).slice(-4))}`);

// ---- 2. Record until the quota is met (as play_quota.mjs).
const S = 2;
const es = plan.entityStart;
const along = plan.sightlines
  .filter((sl) => sl.level === es.level && ((sl.x1 === sl.x2 && sl.x1 === es.x && es.y >= Math.min(sl.y1, sl.y2) && es.y <= Math.max(sl.y1, sl.y2)) || (sl.y1 === sl.y2 && sl.y1 === es.y && es.x >= Math.min(sl.x1, sl.x2) && es.x <= Math.max(sl.x1, sl.x2))))
  .sort((a, b) => b.length - a.length)[0];
let spot = null;
if (along) {
  const cells = [];
  for (let x = Math.min(along.x1, along.x2); x <= Math.max(along.x1, along.x2); x++)
    for (let y = Math.min(along.y1, along.y2); y <= Math.max(along.y1, along.y2); y++) cells.push({ x, y, d: Math.hypot(x - es.x, y - es.y) * S });
  spot = cells.filter((c) => c.d <= 10).sort((a, b) => b.d - a.d)[0];
}
let met = null;
for (let round = 0; round < 5 && !met; round++) {
  if (spot && round === 0) await cmd(`teleport ${es.level} ${spot.x} ${spot.y}`);
  await wait(200);
  s = await state();
  await cmd(`face ${s.orderly.x} ${s.orderly.z} ${(s.orderly.pose?.y ?? es.level * 3.2) + 1.4}`);
  s = await until((s) => s.orderly.seeing === true, 3000, 50);
  await wait(800);
  await cmd(`face ${2 * s.me.x - s.orderly.x} ${2 * s.me.z - s.orderly.z}`);
  await cmd('raise 1');
  s = await until((s) => (s.inst?.needle === 'recording' && s.inst.value > 25) || s.orderly.distance < 3.5, 9000, 50);
  await cmd(`face ${s.orderly.x} ${s.orderly.z} ${(s.orderly.pose?.y ?? 0) + 1.3}`);
  s = await until((s) => (s.tapes.count > 0 && s.inst?.needle !== 'recording') || (s.events.quotaMet ?? 0) > 0, 6000, 50);
  await cmd('raise 0');
  s = await until((s) => (s.events.quotaMet ?? 0) > 0, 2500, 50);
  collect(s);
  if ((s.events.quotaMet ?? 0) > 0) met = s;
}
check('recorded: the floor quota is met', met !== null, met ? JSON.stringify(met.quota.host) : 'never met');
if (!met) await finish();

// ---- 3. Call once met: the car comes; on arrival hint_board in place of "arrived". First past the hide
// nearest the lift (its prompt says hint_hide now, not while the car comes), then the call, then into it.
const hide = JSON.parse(await cmd('hides')).filter((h) => h.level === plan.landing.level)
  .sort((p, q) => Math.hypot(p.front[0] - car.doorX, p.front[1] - car.doorZ) - Math.hypot(q.front[0] - car.doorX, q.front[1] - car.doorZ))[0];
// Every wait for the gate is spent inside the hide, where the Orderly cannot take you.
const hideHeard = (s) => (s.client.hintLog ?? []).some((e) => e.moment === 'hint_hide' && e.what === 'started') || starts.some((e) => e.moment === 'hint_hide');
const getIn = async () => {
  await walk(hide.level, Math.floor(hide.front[0] / S), Math.floor(hide.front[1] / S), 9);
  await cmd(`face ${hide.inside[0]} ${hide.inside[1]}`);
  await wait(300);
  await cmd('hide');
  return until((s) => s.mySeek?.phase === 'inside', 4000, 50);
};
const getOut = async () => {
  await cmd('hide');
  return until((s) => (s.mySeek?.phase ?? 'out') === 'out', 4000, 50);
};
if (hide) {
  s = await getIn();
  collect(s);
  s = await quietGate();
  if (!hideHeard(s)) {
    // Out again with the gate quiet: the prompt shows and its hint plays now.
    s = await getOut();
    s = await until((s) => hideHeard(s), 4000, 100);
    collect(s);
    s = await getIn();
    s = await quietGate();
  }
  console.log(`  hide prompt hint: ${JSON.stringify(starts.filter((e) => e.moment === 'hint_hide'))}`);
  s = await getOut();
}
s = await walk(plan.landing.level, plan.landing.x, plan.landing.y, 9);
if (s.client.caught) s = await until((s) => !s.client.noise, 4000);
s = await state();
await cmd(`face ${s.quota.at[0]} ${s.quota.at[2]} ${s.quota.at[1]}`);
s = await until((s) => s.me.canCall === true, 3000, 50);
if (!hide) s = await quietGate();
await cmd('call');
s = await until((s) => s.phase === 'coming', 3000, 50);
check('call once met: the car is coming', s.phase === 'coming');
// The call is loud and the Orderly comes: back into the hide (sim/hiding.gd: safe unless it saw you get
// in) to wait; without one, keep it watched (it holds still while seen).
// Watch it from the hide's front; when the lights go (it cannot see you get in then), get in.
if (hide) await walk(hide.level, Math.floor(hide.front[0] / S), Math.floor(hide.front[1] / S), 9);
await cmd('timescale 2');
const comeEnd = Date.now() + 120000;
s = await state();
while (s.phase === 'coming' && Date.now() < comeEnd) {
  if (hide && s.dark && (s.mySeek?.phase ?? 'out') === 'out') {
    await cmd(`face ${hide.inside[0]} ${hide.inside[1]}`);
    await cmd('hide');
    s = await until((s) => s.mySeek?.phase === 'inside', 3000, 30);
    console.log(`  in the dark, hid in ${hide.kind} ${hide.id}: ${s.mySeek?.phase ?? 'not hidden'}`);
  } else if ((s.mySeek?.phase ?? 'out') === 'out') {
    await cmd(`face ${s.orderly.x} ${s.orderly.z} ${(s.orderly.pose?.y ?? 0) + 1.4}`);
  }
  await wait(30);
  s = await state();
}
await cmd('timescale 1');
check('waiting for the car: still on my feet when it arrives', s.me.status === 'ok' && (s.events.wiped ?? 0) === 0, `status ${s.me.status}, phase ${s.phase}`);
const arrivedAt = JSON.parse(await cmd('clock')).ms;
s = await until((s) => spokenAfter(s, arrivedAt - 500).some((id) => id.startsWith('hint_board_') || id.startsWith('arrived_')), 14000, 100);
collect(s);
const atArrival = spokenAfter(s, arrivedAt - 500);
check('the car arrives: the announcer says hint_board (after "lights" if the blackout was on), and no arrived line', atArrival.some((id) => id.startsWith('hint_board_')) && !atArrival.some((id) => id.startsWith('arrived_')),
  `spoken at the arrival: ${atArrival.join(', ') || 'nothing'}; log ${JSON.stringify((s.client.hintLog ?? []).slice(-4))}`);
await finish();

async function finish() {
  s = await state();
  collect(s);
  const h = s.client.history;
  let overlaps = 0;
  for (let i = 1; i < h.length; i++) if (h[i - 1].end < 0 || h[i].at < h[i - 1].end) overlaps++;
  check('the announcer\'s history: no two lines overlap in time', overlaps === 0, `${h.length} lines: ${h.map((x) => `${x.id}@${x.at}-${x.end}`).join(' ')}`);
  check('every hint started with nothing else playing', starts.length > 0 && starts.every((e) => !e.busy), `${starts.length} hints started: ${starts.map((e) => e.moment).join(', ')}`);
  const errors = consoleLines.filter((l) => /SCRIPT ERROR|ERROR:/.test(l));
  check('no script errors', errors.length === 0, errors.slice(0, 3).join(' | '));
  const failed = results.filter((r) => !r.ok).length;
  console.log(`${results.length - failed}/${results.length} passed`);
  sock.write('quit\n');
  await wait(800);
  if (!exited) game.kill();
  sock.destroy();
  process.exit(failed ? 1 : 0);
}
