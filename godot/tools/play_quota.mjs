// The floor quota on screen (North Star C9; T5r), played on the Windows build like play_desktop.mjs, with
// the quota ON: `auto=1 quota=N` (test-only: every floor's quota capped at N credits, net/host_rules.gd
// quota_cap_by_arg, so one or two readings meet it). Alone on floor 1:
//   1. at the lift before recording anything, the call panel reads RECORDED 0 OF N (the host's quota
//      block), and so does the line under the prompt;
//   2. call: refused ("callRefused"), the car does not come, the panel and the line flash NOT YET: 0 OF N
//      in red, and the buzz is heard (UI bus);
//   3. read the Orderly until the host says the quota is met ("quotaMet" once): the panel reads QUOTA MET.
//      CALL THE CAR. and the announcer says a quota line (Voice bus);
//   4. call again: accepted ("called"), the car comes; wait it out, board on DOWN and ride to floor 2,
//      where the panel starts again at RECORDED 0 OF N although the tape recorded on floor 1 is still held.
// On every state read the panel's words must be the host's quota block's (or the refusal's flash).
// Pictures (export/shots/quota/): the panel before the quota is met, the NOT YET flash, the panel once met.
// Usage: node godot/tools/play_quota.mjs [--port=4462] [--quota=20] [--editor | --headless]
//   --headless is --editor with no window (so no mouse grab); the pictures are not taken.
//   --editor runs the engine on the project ($GODOT) instead of export/windows/GoingDown.exe.
// Start .local/guard-mouse.ps1 beside it. Exit code 0 only if every check passes.
import { spawn } from 'node:child_process';
import { existsSync, mkdirSync, writeFileSync } from 'node:fs';
import { connect } from 'node:net';
import { dirname, join, resolve } from 'node:path';
import { orderlyCell, watchSpots } from './orderly_spot.mjs';
import { getIn as carefulGetIn, getOut, hideForTheWait } from './careful.mjs';
import { fileURLToPath } from 'node:url';

const here = dirname(fileURLToPath(import.meta.url));
const project = resolve(here, '..');
const arg = (k, d) => (process.argv.find((a) => a.startsWith(`--${k}=`)) ?? `--${k}=${d}`).split('=')[1];
const port = Number(arg('port', 4462));
const cap = Number(arg('quota', 20));
const headless = process.argv.includes('--headless'); // the engine on the project with no window (pictures are then empty)
const editor = headless || process.argv.includes('--editor');
const shots = resolve(project, 'export/shots/quota');
mkdirSync(shots, { recursive: true });

let exe;
let pre = [];
let cwd;
if (editor) {
  exe = process.env.GODOT || resolve(project, '..', 'tools', 'godot', 'Godot_v4.7.2-stable_win64_console.exe');
  pre = [...(headless ? ['--headless'] : []), '--path', project];
  cwd = project;
} else {
  cwd = resolve(project, 'export/windows');
  exe = join(cwd, 'GoingDown.exe');
  if (!existsSync(exe)) { console.log(`no build at ${exe}: run node godot/tools/godot.mjs export, or pass --editor`); process.exit(1); }
}
const consoleLines = [];
const game = spawn(exe, [...pre, '--resolution', '960x540', '--position', '40,40', '--', 'auto=1', `quota=${cap}`, 'quality=full', `testport=${port}`], { cwd, stdio: ['ignore', 'pipe', 'pipe'] });
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
const pictures = [];
const shot = async (name) => {
  const file = join(shots, `${name}.png`);
  await cmd(`shot ${file}`);
  pictures.push(file);
  console.log('  shot', file);
};

// The panel's words for the host's quota block, as client/quota_view.gd must draw them.
const expected = (q) => (!q || q.needed <= 0 ? '' : q.earned < q.needed ? `RECORDED ${q.earned} OF ${q.needed}` : 'QUOTA MET. CALL THE CAR.');
// Every state read: the panel shows the host's quota (or a refusal's flash, which carries the host's own
// numbers from its event).
let reads = 0;
const wrong = [];
const state = async () => {
  const s = JSON.parse(await cmd('state'));
  if (s.quota) {
    reads++;
    const want = expected(s.quota.host);
    const shown = s.quota.view.flashing ? 'flash' : s.quota.panel;
    if (shown !== 'flash' && shown !== want && wrong.length < 8) wrong.push(`depth ${s.depth} ${s.phase}: panel "${shown}", host ${JSON.stringify(s.quota.host)} wants "${want}"`);
  }
  return s;
};
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
const busPeak = async (bus, ms) => {
  let best = -200;
  const end = Date.now() + ms;
  while (Date.now() < end) {
    const p = JSON.parse(await cmd('peaks'));
    best = Math.max(best, p[bus] ?? -200);
    await wait(30);
  }
  return best;
};

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
check('the run has the quota on, capped for the test, nothing recorded yet', s.quota?.host?.needed === cap && s.quota.host.earned === 0 && s.depth === 1,
  `quota ${JSON.stringify(s.quota?.host)}, depth ${s.depth}`);

// ---- 1. Out to the landing, facing the call panel.
await cmd('move 1 0 0 0');
s = await until((s) => !s.me.aboard && Math.hypot(s.me.x - car.doorX, s.me.z - car.doorZ) > 1.6, 5000, 50);
await cmd('stopmove');
s = await until((s) => s.phase === 'away', 20000, 100);
await walk(plan.landing.level, plan.landing.x, plan.landing.y, 6);
s = await state();
const at = s.quota.at;
await cmd(`face ${at[0]} ${at[2]} ${at[1]}`);
s = await until((s) => s.me.canCall === true, 3000, 50);
await wait(500);
s = await state();
check('before recording: the panel and the line under the prompt read RECORDED 0 OF N', s.me.canCall && s.quota.panel === `RECORDED 0 OF ${cap}` && s.quota.tone === 'count' && s.quota.hud === s.quota.panel,
  `panel "${s.quota.panel}", line "${s.quota.hud}", prompt "${s.client.prompt}"`);
await shot('1-panel-before-quota');

// ---- 2. Call too early: refused, the flash, the buzz.
const refused0 = s.events.callRefused ?? 0;
const called0 = s.events.called ?? 0;
await cmd('call');
s = await until((s) => (s.events.callRefused ?? 0) > refused0, 3000, 30);
const flashing = s.quota.view.flashing;
const buzz = await busPeak('UI', 500);
await shot('2-not-yet-flash');
s = await state();
check('call before the quota: refused by the host, the car does not come', (s.events.callRefused ?? 0) === refused0 + 1 && (s.events.called ?? 0) === called0 && s.phase === 'away',
  `refusals ${s.events.callRefused}, called ${s.events.called ?? 0}, phase ${s.phase}`);
check('the panel and the line flash NOT YET: 0 OF N in red', flashing && s.quota.view.lastFlash === `NOT YET: 0 OF ${cap}` && (s.quota.view.flashing ? s.quota.panel === `NOT YET: 0 OF ${cap}` && s.quota.tone === 'refused' && s.quota.hud === s.quota.panel : true),
  `flash "${s.quota.view.lastFlash}", panel "${s.quota.panel}" (${s.quota.tone}), line "${s.quota.hud}"`);
const sounds = JSON.parse(await cmd('sfx state'));
check('the buzz is heard', sounds.played.some((p) => p.name === 'refused') && buzz > -60, `UI bus peak ${buzz.toFixed(1)} dB`);
s = await until((s) => !s.quota.view.flashing, 3000, 50);
check('the flash ends and the panel reads RECORDED 0 OF N again', s.quota.panel === `RECORDED 0 OF ${cap}`, `panel "${s.quota.panel}"`);

// ---- 3. Record: the Orderly's corridor, back turned with the instrument up, look when it is close.
const S = 2;
// Where the Orderly really starts: the rules' body (a seeded cell deep in the dirty part since the Orderly fix, OR2),
// not the plan's entityStart; the cells to watch it from are tools/orderly_spot.mjs's (the rules say which sees it).
s = await state();
const es = orderlyCell(s, S);
const watchFrom = watchSpots(plan, es);
console.log('watch the Orderly from', JSON.stringify(watchFrom.slice(0, 3)), `(${watchFrom.length} spots)`);
let met = null;
const metSpoken = [];
for (let round = 0; round < 4 && !met; round++) {
  s = await state();
  if (round === 0) {
    for (const [i, p] of watchFrom.slice(0, 12).entries()) {
      await cmd(`teleport ${es.level} ${p.x} ${p.y}`);
      await wait(200);
      const now = (await state()).orderly;
      await cmd(`face ${now.x} ${now.z} ${(now.pose?.y ?? es.level * 3.2) + 1.4}`);
      s = await until((s) => s.orderly.seeing === true, i === 0 ? 3000 : 1500, 50);
      if (s.orderly.seeing === true) break;
    }
  }
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
  console.log(`  round ${round + 1}: tapes ${s.tapes.count} worth ${s.tapes.value.toFixed(1)}, host quota ${JSON.stringify(s.quota.host)}, caught ${s.events.caught ?? 0}`);
  if ((s.events.quotaMet ?? 0) > 0) met = s;
}
check('recorded: the host says the quota is met, once', met !== null && met.events.quotaMet === 1 && met.quota.host.earned >= cap, met ? `quota ${JSON.stringify(met.quota.host)}, quotaMet ${met.events.quotaMet}` : 'never met');
if (!met) await finish();
const voice = await busPeak('Voice', 4500);
s = await state();
const quotaLine = s.client.spoken.find((id) => id.startsWith('quota_'));
check('the announcer says the quota is met', quotaLine !== undefined && voice > -60, `spoken ${s.client.spoken.join(', ')}; Voice bus peak ${voice.toFixed(1)} dB; subtitle "${s.client.subtitle}"`);
check('the panel reads QUOTA MET. CALL THE CAR.', s.quota.panel === 'QUOTA MET. CALL THE CAR.' && s.quota.tone === 'met', `panel "${s.quota.panel}" (${s.quota.tone})`);
const held = s.tapes.value;

// ---- 4. Back at the lift: the panel, then the call is accepted.
s = await walk(plan.landing.level, plan.landing.x, plan.landing.y, 9);
if (s.client.caught) s = await until((s) => !s.client.noise, 4000);
s = await state();
await cmd(`face ${s.quota.at[0]} ${s.quota.at[2]} ${s.quota.at[1]}`);
s = await until((s) => s.me.canCall === true, 3000, 50);
await wait(500);
s = await state();
check('at the lift once met: the panel and the line under the prompt read QUOTA MET. CALL THE CAR.', s.quota.panel === 'QUOTA MET. CALL THE CAR.' && s.quota.hud === s.quota.panel, `panel "${s.quota.panel}", line "${s.quota.hud}"`);
await shot('3-panel-quota-met');
const refused1 = s.events.callRefused ?? 0;
await cmd('call');
s = await until((s) => s.phase === 'coming', 3000, 50);
check('call once met: accepted, the car is coming, no refusal', s.phase === 'coming' && (s.events.called ?? 0) === 1 && (s.events.callRefused ?? 0) === refused1, `phase ${s.phase}, called ${s.events.called ?? 0}, refusals ${s.events.callRefused ?? 0}`);

// ---- 5. Ride DOWN: on floor 2 the panel starts again from nothing recorded there.
// The call is loud and the Orderly comes from its far start, hunting. Waiting at the lift in the open ends in a
// catch and the wipe to the prison, so wait for the car the careful way (tools/careful.mjs, as playthrough.mjs):
// watch it in the light and get into a hide well clear of it, where it did not see you get in; out again when the car is here.
const ctx = { cmd, state, wait, until };
await cmd('timescale 2');
const hid = await hideForTheWait(ctx);
console.log(`  waiting for the car: ${hid.hide ? `in ${hid.hide.kind} ${hid.hide.id}, ${hid.note}` : `no hide, ${hid.note}`}`);
s = await state();
for (const end = Date.now() + 120000; s.phase === 'coming' && Date.now() < end;) {
  if (hid.hide && (s.mySeek?.phase ?? 'out') === 'out' && s.me.status === 'ok' && s.dark) s = await carefulGetIn(ctx, hid.hide);
  await wait(30);
  s = await state();
}
await cmd('timescale 1');
if (hid.hide && (s.mySeek?.phase ?? 'out') !== 'out') s = await getOut(ctx);
if (s.client.noise) s = await until((s) => !s.client.noise, 4000);
// Taken while the car came (a soft catch): the tape is on the floor where it happened. Get it back, so
// floor 2 starts with a tape held (what the floor-2 check is about).
s = await state();
const floorTape = s.tapes.count === 0 ? JSON.parse(await cmd('floortapes'))[0] : null;
if (floorTape) {
  await walk(floorTape.at.level, Math.floor(floorTape.at.x / S), Math.floor(floorTape.at.z / S), 9);
  await cmd('pick');
  s = await until((s) => s.tapes.count > 0, 2000, 50);
  console.log(`  taken while waiting: picked the tape up again (${s.tapes.value.toFixed(1)})`);
}
await walk(plan.landing.level, plan.landing.x, plan.landing.y, 9);
await cmd(`face ${car.doorX + car.inX * 2} ${car.doorZ + car.inZ * 2}`);
await cmd('move 1 0 0 0');
s = await until((s) => s.me.aboard === true && Math.abs((s.me.x - car.doorX) * car.inX + (s.me.z - car.doorZ) * car.inZ) > 1.1, 4000, 30);
await cmd('move 0 1 0 0');
s = await until((s) => s.me.side === 'down', 3000, 30);
await cmd('stopmove');
await cmd('timescale 4');
s = await until((s) => s.depth === 2 && s.client.built === 2 && s.doorsOpen, 60000, 100);
await cmd('timescale 1');
s = await until((s) => s.quota?.host?.earned === 0 && s.quota.host.needed > 0, 3000, 50);
check('floor 2: the panel reads the host\'s quota for this floor, RECORDED 0 OF N, though a tape is still held',
  s.depth === 2 && s.quota.panel === `RECORDED 0 OF ${s.quota.host.needed}` && s.quota.host.earned === 0 && s.tapes.value > 0,
  `depth ${s.depth}, panel "${s.quota.panel}", host ${JSON.stringify(s.quota.host)}, tapes held ${s.tapes.value.toFixed(1)} (floor 1 recorded ${held.toFixed(1)})`);

await finish();

async function finish() {
  check('on every state read the panel showed the host\'s quota (or a refusal\'s flash)', wrong.length === 0 && reads > 50, wrong.length ? wrong.join(' | ') : `${reads} reads`);
  const errors = consoleLines.filter((l) => /SCRIPT ERROR|ERROR:/.test(l));
  check('no script errors', errors.length === 0, errors.slice(0, 3).join(' | '));
  writeFileSync(join(shots, 'report.json'), JSON.stringify({ cap, results, pictures, errors, console: consoleLines.slice(-40) }, null, 2));
  const failed = results.filter((r) => !r.ok).length;
  console.log(`${results.length - failed}/${results.length} passed`);
  sock.write('quit\n');
  await wait(800);
  if (!exited) game.kill();
  sock.destroy();
  process.exit(failed ? 1 : 0);
}
