// The crewmates in motion, in a real two-player game on this PC (the Windows build, the headless
// server on 127.0.0.1, two game windows that join through the start screen's own Join, as
// play_net.mjs). Ann (1280x720, the tape on) stands at one end of a straight corridor and keeps her
// eyes on Bob, who walks toward her, walks away backwards, runs toward her, backs off again and creeps
// toward her. On Ann's screen, for each stretch, it measures Bob's foot slip as drawn: over each plant,
// how far his planted toe ends up from where it touched down against how far his body went meanwhile
// (client/crew_view.gd `slip`, read through Ann's test state; a plant spanning a frozen frame, such as
// the one a picture is saved in, is dropped and counted), and asserts:
//   - slip at most SLIP_MAX of the body's travel for walk, backwards walk, run and creep;
//   - the creep plays the sneak at a sensible rate (CREEP_RATE_MIN..MAX), not slowed to half speed;
//   - Bob's name tag shows only up close (main.gd TAG_RANGE): on Ann's screen at 1.5 m, not at 4 or 8 m;
//   - Bob's mask on Ann's screen shows the face Bob drew.
// Pictures (Ann's window as drawn) in export/shots/crew/: Bob walking at 4 m, standing at 1.5 m (his tag), creeping, his face
// screen close up. Prints `N passed, M failed`; exit code 1 on any failure.
//   node godot/tools/crew_check.mjs [--port=4470] [--break=rate|swing]
// --break passes crewbreak= to Ann's game (CrewView.test_break): the slip checks must then fail.
// Ports 4460-4479 only; every process it starts is stopped. Start .local/guard-mouse.ps1 beside it.
import { spawn } from 'node:child_process';
import { existsSync, mkdirSync, writeFileSync } from 'node:fs';
import { connect } from 'node:net';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const here = dirname(fileURLToPath(import.meta.url));
const arg = (k, d) => (process.argv.find((a) => a.startsWith(`--${k}=`)) ?? `--${k}=${d}`).split('=')[1];
const port = Number(arg('port', 4470));
const brk = arg('break', '');
const exeDir = resolve(here, '../export/windows');
const exe = join(exeDir, 'GoingDown.exe');
const shots = resolve(here, '../export/shots/crew');
const SECRET = 'test-passphrase';
const url = `ws://127.0.0.1:${port}`;
const testPorts = [port + 1, port + 2];
/** A planted toe may move at most this share of the body's travel (crew_check.gd SLIP_MAX, plus a
 *  little for the network's interpolation). */
const SLIP_MAX = 0.15;
const CREEP_RATE_MIN = 0.75;
const CREEP_RATE_MAX = 1.3;
for (const p of [port, ...testPorts]) if (!(p >= 4460 && p <= 4479)) throw new Error(`port ${p} is outside 4460-4479`);
if (!existsSync(exe)) throw new Error(`no Windows build at ${exe}: npm run godot:export first`);
mkdirSync(shots, { recursive: true });

const procs = new Set();
const cleanup = () => { for (const p of procs) { try { p.kill(); } catch { /* gone */ } } };
process.on('exit', cleanup);
process.on('SIGINT', () => { cleanup(); process.exit(1); });
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

function launch(args, opts = {}) {
  const p = spawn(exe, args, { cwd: exeDir, env: { ...process.env, ...(opts.env || {}) }, stdio: ['ignore', 'pipe', 'pipe'] });
  procs.add(p);
  const lines = [];
  const keep = (b) => { for (const l of String(b).split(/\r?\n/)) if (l.trim()) { lines.push(l); if (opts.echo) console.log(`  [${opts.echo}] ${l}`); } };
  p.stdout.on('data', keep);
  p.stderr.on('data', keep);
  let exited = false;
  p.on('exit', () => { exited = true; procs.delete(p); });
  return { p, lines, get exited() { return exited; } };
}

async function game(label, testport, extra, res, pos) {
  const g = launch(['--resolution', res, '--position', pos, '--', 'auto=1', `testport=${testport}`, ...extra], {});
  let sock = null;
  for (let i = 0; i < 200 && !sock && !g.exited; i++) {
    sock = await new Promise((r) => { const s = connect(testport, '127.0.0.1', () => r(s)); s.on('error', () => r(null)); });
    if (!sock) await sleep(150);
  }
  if (!sock) throw new Error(`${label}: no test channel (${g.lines.slice(-5).join(' | ')})`);
  let buf = '';
  const waiting = [];
  sock.on('data', (d) => { buf += d; let i; while ((i = buf.indexOf('\n')) >= 0) { const l = buf.slice(0, i); buf = buf.slice(i + 1); waiting.shift()?.(l); } });
  const cmd = (c) => new Promise((r) => { waiting.push(r); sock.write(c + '\n'); });
  const state = async () => JSON.parse(await cmd('state'));
  const shot = async (name) => { const r = await cmd(`shot ${join(shots, name)}`); console.log(`  shot ${name} (${label}) ${r}`); return r; };
  const close = async () => { try { sock.write('quit\n'); } catch { /* closed */ } await sleep(600); if (!g.exited) g.p.kill(); sock.destroy(); };
  return { label, g, cmd, state, shot, close };
}

const results = [];
const check = (name, ok, detail = '') => { results.push({ name, ok, detail }); console.log(`${ok ? 'PASS' : 'FAIL'} ${name}${detail ? ` (${detail})` : ''}`); };
async function until(fn, pred, ms = 30000, every = 100) {
  const end = Date.now() + ms;
  let v = await fn();
  while (!pred(v) && Date.now() < end) { await sleep(every); v = await fn(); }
  return v;
}
const scr = (s) => s.screen ?? {};
async function drawFace(c, steps) {
  const s = await until(c.state, (x) => scr(x).screen === 'face', 20000);
  if (scr(s).screen !== 'face') return false;
  for (const st of steps) await c.cmd(`draw ${st}`);
  return (await c.cmd('draw done')) === 'ok';
}

const server = launch(['--headless', '--', 'server', `port=${port}`, 'bind=127.0.0.1', 'seed=alpha'], { env: { GD_JOIN_SECRET: SECRET } });
await until(async () => server.lines.join('\n'), (t) => t.includes('listening on') || server.exited, 20000);
if (!server.lines.join('\n').includes('listening on')) { console.log('the server did not start'); process.exit(1); }

let A = null;
let B = null;
const report = { segments: [] };
try {
  A = await game('Ann', testPorts[0], [`join=${url}`, 'name=Ann', `pass=${SECRET}`, ...(brk ? [`crewbreak=${brk}`] : [])], '1280x720', '20,20');
  B = await game('Bob', testPorts[1], [`join=${url}`, 'name=Bob', `pass=${SECRET}`], '640x360', '1320,20');
  const drew = (await drawFace(A, [])) && (await drawFace(B, ['press starter:frown', 'press colour:3', 'press brush:1', 'line 22 14 22 21', 'press colour:4', 'line 6 5 13 7']));
  check('both join and Bob draws a face', drew);
  await until(A.state, (s) => scr(s).screen === 'lobby' && (scr(s).people ?? []).length >= 2, 20000);
  // Ready-up (server/room.gd, FD5/FD6): both press READY on the controls card; the run starts for both
  // after the 5 s count.
  await A.cmd('ready');
  await B.cmd('ready');
  let a = await until(A.state, (s) => s.phase !== undefined, 20000);
  let b = await until(B.state, (s) => s.phase !== undefined, 20000);
  await A.cmd('click');
  await B.cmd('click');
  const plan = JSON.parse(await A.cmd('plan'));
  await until(A.state, (s) => s.phase === 'unloading' && s.client.doors > 0.95, 15000);

  // A straight corridor on the landing's level, at least 7 cells (14 m), nearest the landing.
  const L = plan.landing;
  const lines = plan.sightlines.filter((l) => l.level === L.level && l.length >= 7 && (l.x1 === l.x2 || l.y1 === l.y2));
  const near = (l) => Math.min(Math.abs(l.x1 - L.x) + Math.abs(l.y1 - L.y), Math.abs(l.x2 - L.x) + Math.abs(l.y2 - L.y));
  lines.sort((p, q) => near(p) - near(q));
  if (!lines.length) throw new Error('no straight corridor of 7 cells on the landing level');
  const line = lines[0];
  const flip = Math.abs(line.x2 - L.x) + Math.abs(line.y2 - L.y) < Math.abs(line.x1 - L.x) + Math.abs(line.y1 - L.y);
  const e1 = flip ? { x: line.x2, y: line.y2 } : { x: line.x1, y: line.y1 };
  const e2 = flip ? { x: line.x1, y: line.y1 } : { x: line.x2, y: line.y2 };
  const step = { x: Math.sign(e2.x - e1.x), y: Math.sign(e2.y - e1.y) };
  const far = { x: e1.x + step.x * 6, y: e1.y + step.y * 6 };
  console.log(`  corridor ${line.length} cells from ${e1.x},${e1.y} toward ${e2.x},${e2.y}; Ann at its near end, Bob 6 cells along`);
  // Out of the car first (from inside it there is no path), a little apart, as play_net does.
  await A.cmd('move 1 -0.35 0 0');
  await B.cmd('move 1 0.35 0 0');
  await sleep(1600);
  await A.cmd('stopmove');
  await B.cmd('stopmove');
  await A.cmd(`walkto ${L.level} ${e1.x} ${e1.y} 3`);
  await B.cmd(`walkto ${L.level} ${far.x} ${far.y} 3`);
  a = await until(A.state, (s) => s.auto !== 'walking', 30000);
  b = await until(B.state, (s) => s.auto !== 'walking', 30000);
  check('both reach the corridor', !/walking|failed/.test(a.auto) && !/walking|failed/.test(b.auto), `Ann ${a.auto}, Bob ${b.auto}`);

  const bobOn = (s) => (s.others ?? []).find((x) => x.name === 'Bob');
  const apart = (s) => { const o = bobOn(s); return o ? Math.hypot(o.x - s.me.x, o.z - s.me.z) : Infinity; };
  // Ann keeps her eyes on Bob's mask; Bob faces Ann (or away) by his own yaw.
  const annLooks = async (s) => { const o = bobOn(s); if (o) await A.cmd(`face ${o.x} ${o.z} ${o.y + (o.gait === 'creep' ? 1.0 : 1.45)}`); };
  const bobFacesAnn = async () => { const s = await A.state(); await B.cmd(`face ${s.me.x} ${s.me.z} ${s.me.y + 1.6}`); };
  const slipOf = (s) => bobOn(s)?.motion?.slip ?? {};
  const shotAt = {};
  /** One stretch: Bob moves by `move` until `done(distance)`; Ann watches; slip measured over it unless
   *  it takes pictures (saving one freezes Ann's game for a frame or more, which a player never sees). */
  async function stretch(name, move, done, clip, pics = [], measured = pics.length === 0) {
    await bobFacesAnn();
    let s = await A.state();
    const before = slipOf(s)[clip] ?? {};
    await B.cmd(`move ${move}`);
    const t0 = Date.now();
    const rates = [];
    let dark = false;
    while (Date.now() - t0 < 15000) {
      s = await A.state();
      await annLooks(s);
      const d = apart(s);
      const o = bobOn(s);
      if (o?.motion?.clip === clip) rates.push(Math.abs(o.motion.rate));
      dark ||= s.dark;
      for (const p of pics) {
        if (!shotAt[p.file] && Math.abs(d - p.at) < 0.45 && !s.dark && o?.motion?.clip === clip) {
          shotAt[p.file] = { d, tagAlpha: o?.tagAlpha, tags: s.client.tags, clip: o?.motion?.clip, range: s.client.tagRange };
          if (!p.stateOnly) await A.shot(p.file);
          console.log(`    ${p.file}: Bob ${d.toFixed(2)} m away, clip ${o?.motion?.clip}, tag alpha ${o?.tagAlpha?.toFixed(2)}, tags ${JSON.stringify(s.client.tags)}`);
        }
      }
      if (done(d) || s.me.status !== 'ok') break;
    }
    await B.cmd('stopmove');
    await sleep(300);
    s = await A.state();
    const after = slipOf(s)[clip] ?? {};
    const dif = (k) => (after[k] ?? 0) - (before[k] ?? 0);
    const t = dif('t');
    const foot = dif('foot');
    const body = dif('body');
    const plants = dif('plants');
    const hitches = dif('hitches');
    const ratio = foot / Math.max(body, 1e-6);
    // How evenly the network placed Bob's body: rms speed over mean speed (1 = perfectly even).
    const even = Math.sqrt(dif('v2') / Math.max(t, 1e-6)) / Math.max(body / Math.max(t, 1e-6), 1e-6);
    const rate = rates.length ? rates[Math.floor(rates.length / 2)] : 0;
    report.segments.push({ name, clip, t, foot, body, ratio, rate, dark, even, plants, hitches, measured });
    if (measured) check(`${name}: on Ann's screen Bob's planted toe slips at most ${SLIP_MAX * 100} % of his travel`, t > 0.5 && plants >= 3 && ratio <= SLIP_MAX,
      `clip ${clip} at ${rate.toFixed(2)}x, ${plants} plants (${hitches} dropped for a frozen frame), toe planted ${t.toFixed(2)} s, toe ${(foot / Math.max(t, 1e-6)).toFixed(3)} m/s against body ${(body / Math.max(t, 1e-6)).toFixed(3)} m/s, slip ${(ratio * 100).toFixed(1)} %; body speed rms/mean ${even.toFixed(2)}`);
    return { rate, ratio };
  }

  await stretch('walk toward Ann', '1 0 0 0', (d) => d < 2.6, 'walk');
  await stretch('walk away backwards', '-1 0 0 0', (d) => d > 11, 'walk');
  await stretch('run toward Ann', '1 0 1 0', (d) => d < 2.6, 'run');
  await stretch('walk away backwards again', '-1 0 0 0', (d) => d > 9.5, 'walk');
  const creep = await stretch('creep toward Ann', '1 0 0 1', (d) => d < 2.2, 'sneak');
  check('the creep plays a sneak at a sensible rate, not a slowed one', creep.rate >= CREEP_RATE_MIN && creep.rate <= CREEP_RATE_MAX, `${creep.rate.toFixed(2)}x (want ${CREEP_RATE_MIN}-${CREEP_RATE_MAX})`);
  // The pictures, on passes of their own.
  await stretch('back off for the pictures', '-1 0 0 0', (d) => d > 10, 'walk', [], false);
  await stretch('walk toward Ann, pictures', '1 0 0 0', (d) => d < 1.6, 'walk',
    [{ file: 'at-8m', at: 8, stateOnly: true }, { file: 'bob-walking-4m.png', at: 4 }]);
  // Bob has stopped about 1.5 m from Ann: inside the tag range.
  {
    const s = await A.state();
    await annLooks(s);
    await sleep(200);
    const s2 = await A.state();
    const o = bobOn(s2);
    shotAt['bob-1.5m.png'] = { d: apart(s2), tagAlpha: o?.tagAlpha, tags: s2.client.tags, clip: o?.motion?.clip, range: s2.client.tagRange };
    await A.shot('bob-1.5m.png');
    console.log(`    bob-1.5m.png: Bob ${apart(s2).toFixed(2)} m away, clip ${o?.motion?.clip}, tag alpha ${o?.tagAlpha?.toFixed(2)}, tags ${JSON.stringify(s2.client.tags)}`);
  }
  await stretch('back off again', '-1 0 0 0', (d) => d > 7, 'walk', [], false);
  await stretch('creep toward Ann, picture', '1 0 0 1', (d) => d < 3, 'sneak', [{ file: 'bob-creeping-5m.png', at: 5 }]);
  // Name tags only up close (main.gd TAG_RANGE): who is who further off is for asking or walking up.
  const at8 = shotAt['at-8m'];
  const at15 = shotAt['bob-1.5m.png'];
  const at4 = shotAt['bob-walking-4m.png'];
  check("Bob's name tag is not on Ann's screen at 8 m or 4 m (beyond the tag range)", !!at8 && !!at4 && !at8.tags.includes('BOB') && !at4.tags.includes('BOB') && at8.tagAlpha === 0 && at4.tagAlpha === 0,
    `range ${at8?.range} m; at ${at8?.d?.toFixed(2)} m alpha ${at8?.tagAlpha}, at ${at4?.d?.toFixed(2)} m alpha ${at4?.tagAlpha}`);
  check("Bob's name tag is on Ann's screen, fully opaque, at 1.5 m", !!at15 && at15.tags.includes('BOB') && at15.tagAlpha >= 0.99, at15 ? `at ${at15.d.toFixed(2)} m, alpha ${at15.tagAlpha?.toFixed(2)}` : 'no picture at 1.5 m');

  // The face screen close up: Bob steps up to Ann and stands; Ann looks at his mask.
  await bobFacesAnn();
  await B.cmd('move 1 0 0 0');
  await until(A.state, (s) => apart(s) < 1.25, 4000, 30);
  await B.cmd('stopmove');
  await sleep(500);
  await bobFacesAnn();
  await sleep(500);
  a = await A.state();
  const o = bobOn(a);
  await A.cmd(`face ${o.x} ${o.z} ${o.y + 1.6}`);
  await sleep(300);
  await A.shot('bob-face-screen-closeup.png');
  const faces = JSON.parse(await A.cmd('faces'));
  const bobFaces = JSON.parse(await B.cmd('faces'));
  check("Bob's mask on Ann's screen shows the face Bob drew", faces.masks[o.id] === bobFaces.own && bobFaces.own !== faces.default, `mask ${faces.masks[o.id]}, Bob drew ${bobFaces.own}, ${apart(a).toFixed(2)} m apart`);
  check('Ann never sees her own figure', !(a.others ?? []).some((x) => x.id === a.me.id));
  writeFileSync(join(shots, 'crew_check.json'), JSON.stringify({ results, report, shotAt }, null, 2));
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
