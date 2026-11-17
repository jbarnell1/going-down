// The multiplayer check on this PC, with the real Windows build: the headless server started from
// export/windows/GoingDown.exe on 127.0.0.1 (the test passphrase `test-passphrase`, passed in the
// environment), and TWO Windows game windows (small, `auto=1`, a test channel each, never capturing the
// mouse) that join through the start screen's own Join (the join=, name= and pass= arguments fill the
// form and press it). Asserts from BOTH clients' own state:
//   - a wrong passphrase shows the plain-words error on the start screen;
//   - each player draws a face in the face step after Join (the editor's own controls and mouse drags);
//   - the lobby lists both names; Start (pressed by one) starts the run for both;
//   - each sees the OTHER player's drawn face on that crewmate's mask (the picture on the mask, hashed,
//     against the face the other drew), and the lift's monitor shows both faces;
//   - B changes face mid-run at the face kiosk (the kiosk's own editor, opened by the test hook as F
//     at the prison's kiosk opens it): A sees B's new face on B's mask and on the lift's monitor;
//   - each sees the other as a crewmate where the other really stands (the drawn figure's position
//     against the other's own body), drawn, with a readable name tag; a picture from each;
//   - one creeps: their camera drops, and the other sees their figure crouch with its mask at their eye;
//   - the emote wheel: one aims and lets go, the other sees the emote on that figure;
//   - a watched Orderly never moves on the watcher's screen (consecutive seeing frames) while the
//     other looks away;
//   - the call, boarding and the bank end the run for both, and both are back in the lobby after;
// and, with --web (the default when export/web exists), that a browser client joins the same server
// (its lobby lists three names; it leaves before the run).
// Pictures in export/shots/net/. Prints `N passed, M failed`; exit code 1 on any failure.
//   node godot/tools/play_net.mjs [--port=4460] [--web=4464|0] [--keep]
// The game windows' test channels are on port+1..port+3. Start .local/guard-mouse.ps1 beside it.
// Ports 4460-4499 only; every process it starts is stopped.
import { spawn } from 'node:child_process';
import { existsSync, mkdirSync, writeFileSync } from 'node:fs';
import { connect } from 'node:net';
import { createRequire } from 'node:module';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const here = dirname(fileURLToPath(import.meta.url));
const arg = (k, d) => (process.argv.find((a) => a.startsWith(`--${k}=`)) ?? `--${k}=${d}`).split('=')[1];
const port = Number(arg('port', 4460));
const exeDir = resolve(here, '../export/windows');
const exe = join(exeDir, 'GoingDown.exe');
const webDir = resolve(here, '../export/web');
const webPort = Number(arg('web', existsSync(join(webDir, 'index.html')) ? 4464 : 0));
const shots = resolve(here, '../export/shots/net');
const SECRET = 'test-passphrase';
const url = `ws://127.0.0.1:${port}`;
const testPorts = [port + 1, port + 2, port + 3];
for (const p of [port, ...testPorts, ...(webPort ? [webPort] : [])]) if (!(p >= 4460 && p <= 4499)) throw new Error(`port ${p} is outside 4460-4499`);
if (webPort && [port, ...testPorts].includes(webPort)) throw new Error(`the web port ${webPort} is one of the game's ports`);
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

/** A game window: the test channel (one command per line, one reply per line). */
async function game(label, testport, extra, pos) {
  const g = launch(['--resolution', '640x360', '--position', pos, '--', 'auto=1', `testport=${testport}`, ...extra], {});
  let sock = null;
  for (let i = 0; i < 200 && !sock && !g.exited; i++) {
    sock = await new Promise((res) => { const s = connect(testport, '127.0.0.1', () => res(s)); s.on('error', () => res(null)); });
    if (!sock) await sleep(150);
  }
  if (!sock) throw new Error(`${label}: no test channel (${g.lines.slice(-5).join(' | ')})`);
  let buf = '';
  const waiting = [];
  sock.on('data', (d) => { buf += d; let i; while ((i = buf.indexOf('\n')) >= 0) { const l = buf.slice(0, i); buf = buf.slice(i + 1); waiting.shift()?.(l); } });
  const cmd = (c) => new Promise((res) => { waiting.push(res); sock.write(c + '\n'); });
  const state = async () => JSON.parse(await cmd('state'));
  const shot = async (name) => { const r = await cmd(`shot ${join(shots, name)}`); console.log(`  shot ${name} (${label}) ${r}`); };
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
const inGame = (s) => s.phase !== undefined;
const scr = (s) => s.screen ?? {};
/** The face step after Join: waits for it, runs the drawing commands, then Done (the editor's Enter). */
async function drawFace(c, steps, shot = '') {
  const s = await until(c.state, (x) => scr(x).screen === 'face', 20000);
  if (scr(s).screen !== 'face') return false;
  for (const st of steps) await c.cmd(`draw ${st}`);
  if (shot) { await sleep(150); await c.shot(shot); }
  return (await c.cmd('draw done')) === 'ok';
}

// ---- The server.
const server = launch(['--headless', '--', 'server', `port=${port}`, 'bind=127.0.0.1', 'seed=alpha', 'stats=10'], { env: { GD_JOIN_SECRET: SECRET }, echo: 'server' });
await until(async () => server.lines.join('\n'), (t) => t.includes('listening on') || server.exited, 20000);
if (!server.lines.join('\n').includes('listening on')) { console.log('the server did not start'); process.exit(1); }

let A = null;
let B = null;
try {
  // ---- 1. A wrong passphrase: the plain-words error on the join form; then back to the title.
  const W = await game('wrong', testPorts[2], [`join=${url}`, 'name=Wrong', 'pass=not-the-passphrase'], '40,440');
  check('the face step comes first, and Enter keeps the face it opens on', await drawFace(W, []));
  let w = await until(W.state, (s) => /WRONG PASSPHRASE/.test(scr(s).error ?? ''), 20000);
  check('a wrong passphrase shows the plain-words error on the start screen', scr(w).screen === 'join' && /WRONG PASSPHRASE/.test(scr(w).error), `screen ${scr(w).screen}, close code ${scr(w).closeCode}, "${scr(w).error}"`);
  await W.shot('02-join-form-wrong-passphrase.png');
  await W.cmd('ui back');
  await sleep(400);
  w = await W.state();
  check('the way back: the title screen', scr(w).screen === 'title', `screen ${scr(w).screen}`);
  await W.shot('01-start-screen.png');
  await W.close();

  // ---- 2. Two players join through the form's own Join (arguments fill it in).
  A = await game('A', testPorts[0], [`join=${url}`, 'name=Ann', `pass=${SECRET}`], '40,40');
  B = await game('B', testPorts[1], [`join=${url}`, 'name=Bob', `pass=${SECRET}`], '700,40');
  // Each draws a different face: Ann starts from the shock and adds red cheeks, Bob from the frown with
  // a blue tear and a green brow (the editor's own buttons; strokes as mouse drags across the canvas).
  const drewA = await drawFace(A, ['press starter:shock', 'press colour:2', 'press brush:2', 'line 4 20 7 20', 'line 25 20 28 20'], '00-ann-draws-her-face.png');
  const drewB = await drawFace(B, ['press starter:frown', 'press colour:3', 'press brush:1', 'line 22 14 22 21', 'press colour:4', 'line 6 5 13 7']);
  check('both draw a face in the face step after Join', drewA && drewB);
  const lobbyOf = async (c, n) => until(c.state, (s) => scr(s).screen === 'lobby' && (scr(s).people ?? []).length >= n, 20000);
  let a = await lobbyOf(A, 2);
  let b = await lobbyOf(B, 2);
  const names = (s) => (scr(s).people ?? []).map((p) => p[1]).sort().join(',');
  check('both are in the lobby, each listing both names', names(a) === 'Ann,Bob' && names(b) === 'Ann,Bob', `A sees ${names(a)}, B sees ${names(b)}`);
  await A.shot('03-lobby-two-names.png');

  // ---- 3. A browser client joins the same server (and leaves before the run).
  if (webPort) {
    const serve = spawn(process.execPath, [join(here, 'serve.mjs'), webDir, String(webPort)], { stdio: 'ignore' });
    procs.add(serve);
    await sleep(500);
    const require = createRequire(import.meta.url);
    const { chromium } = require(resolve(here, '../../node_modules/playwright'));
    const browser = await chromium.launch({ headless: true, args: ['--use-angle=default', '--enable-gpu', '--ignore-gpu-blocklist'] });
    try {
      const page = await browser.newPage({ viewport: { width: 960, height: 540 } });
      await page.goto(`http://127.0.0.1:${webPort}/index.html?auto=1&join=${encodeURIComponent(url)}&name=Web&pass=${SECRET}`);
      await page.waitForFunction(() => window.gdReady === true, null, { timeout: 180000 });
      // The face step first (Enter keeps the face it opens on).
      await page.waitForFunction(() => { window.gdCmd('screen'); try { return JSON.parse(window.gdResult).screen === 'face'; } catch { return false; } }, null, { timeout: 20000 });
      await page.evaluate(() => window.gdCmd('draw done'));
      const webScreen = async () => page.evaluate(() => { window.gdCmd('screen'); return JSON.parse(window.gdResult); });
      const ws = await until(webScreen, (s) => s.screen === 'lobby' && s.people.length >= 3, 30000);
      a = await lobbyOf(A, 3);
      check('a browser client joins the same server', ws.screen === 'lobby' && ws.people.length === 3 && (scr(a).people ?? []).length === 3, `browser lobby: ${ws.people.map((p) => p[1]).join(', ')}`);
      await page.screenshot({ path: join(shots, '04-browser-lobby.png') });
      console.log('  shot 04-browser-lobby.png (browser)');
    } finally {
      await browser.close();
      serve.kill();
    }
    a = await until(A.state, (s) => (scr(s).people ?? []).length === 2, 30000);
    check('the browser client left; the lobby is back to two', (scr(a).people ?? []).length === 2);
  }

  // ---- 4. Start (A presses it): the run starts for both.
  await A.cmd('start');
  a = await until(A.state, inGame, 20000);
  b = await until(B.state, inGame, 20000);
  check('Start in the lobby starts the run for both', inGame(a) && inGame(b), `A ${a.phase}, B ${b.phase}`);
  await A.cmd('click');
  await B.cmd('click');
  const planA = JSON.parse(await A.cmd('plan'));
  const car = planA.car;
  await until(A.state, (s) => s.phase === 'unloading' && s.client.doors > 0.95, 15000);
  // ---- 4b. The lift's monitor (back wall, inside): both faces side by side, on both screens.
  a = await A.state();
  const yaw0 = (a.client.yaw * 180) / Math.PI;
  await A.cmd(`face ${car.doorX + car.inX * 3} ${car.doorZ + car.inZ * 3} ${car.floorY + 1.98}`);
  await sleep(500);
  const facesA0 = JSON.parse(await A.cmd('faces'));
  const facesB0 = JSON.parse(await B.cmd('faces'));
  const onMonitor = (f, own, other) => f.monitor.length === 2 && f.monitor.includes(own) && f.monitor.includes(other);
  check("the lift's monitor shows both crew faces (own and the other's) on both screens", facesA0.hasFace && facesB0.hasFace && facesA0.own !== facesB0.own
    && onMonitor(facesA0, facesA0.own, facesB0.own) && onMonitor(facesB0, facesB0.own, facesA0.own),
    `A's monitor ${JSON.stringify(facesA0.monitor)}, B's ${JSON.stringify(facesB0.monitor)}; Ann drew ${facesA0.own}, Bob drew ${facesB0.own}`);
  await A.shot('14-lift-monitor-faces.png');
  await A.cmd(`look ${yaw0} 0`);
  await sleep(200);
  await A.cmd('resetstats');
  await B.cmd('resetstats');

  // ---- 5. Out of the car, a little apart; then each turns to the other.
  await A.cmd('move 1 -0.35 0 0');
  await B.cmd('move 1 0.35 0 0');
  await sleep(1600);
  await A.cmd('stopmove');
  await B.cmd('stopmove');
  await sleep(500);
  a = await A.state();
  b = await B.state();
  await A.cmd(`face ${b.me.x} ${b.me.z} ${b.me.y + 1.5}`);
  await B.cmd(`face ${a.me.x} ${a.me.z} ${a.me.y + 1.5}`);
  await sleep(900);
  a = await A.state();
  b = await B.state();
  const sees = (viewer, other) => {
    const o = (viewer.others ?? []).find((x) => x.id === other.me.id);
    if (!o) return { ok: false, detail: 'not in the frame' };
    const off = o.at ? Math.hypot(o.at[0] - other.me.x, o.at[2] - other.me.z) : Infinity;
    const tag = viewer.client.tags.includes(o.name.toUpperCase());
    return { ok: o.drawn && off < 0.15 && tag && o.tagAlpha > 0.9, off, o, detail: `drawn ${o.drawn}, ${off.toFixed(3)} m from where ${o.name} stands, tag "${o.name.toUpperCase()}" ${tag ? 'shown' : 'NOT shown'} (alpha ${o.tagAlpha?.toFixed(2)}), clip ${o.clip}, patch ${o.index + 1}` };
  };
  const ab = sees(a, b);
  const ba = sees(b, a);
  check('A sees B as a crewmate where B stands, with a readable name tag', ab.ok, ab.detail);
  check('B sees A as a crewmate where A stands, with a readable name tag', ba.ok, ba.detail);
  check('each is dressed differently (skin, headwear, number from the player index)', ab.o && ba.o && ab.o.index !== ba.o.index, `A wears ${ba.o?.index + 1}, B wears ${ab.o?.index + 1}`);
  check('nobody sees their own figure', !(a.others ?? []).some((x) => x.id === a.me.id) && !(b.others ?? []).some((x) => x.id === b.me.id));
  await A.shot('05-ann-sees-bob.png');
  await B.shot('06-bob-sees-ann.png');
  // Each sees the OTHER's drawn face on that crewmate's mask: the picture on the mask (read back from
  // its material) against the picture decoded from the face the other player drew and sent.
  const facesA = JSON.parse(await A.cmd('faces'));
  const facesB = JSON.parse(await B.cmd('faces'));
  const maskOk = (f, otherId, otherOwn) => f.masks[otherId] === otherOwn && otherOwn !== '' && otherOwn !== f.default;
  const apart = Math.hypot(a.me.x - b.me.x, a.me.z - b.me.z);
  check("A sees the face B drew on B's mask, and B sees A's on A's", maskOk(facesA, b.me.id, facesB.own) && maskOk(facesB, a.me.id, facesA.own) && facesA.own !== facesB.own,
    `on A's screen B's mask shows ${facesA.masks[b.me.id]} (B drew ${facesB.own}); on B's screen A's mask shows ${facesB.masks[a.me.id]} (A drew ${facesA.own}); default face ${facesA.default}; ${apart.toFixed(2)} m apart`);
  check("faces came once each from the host (each received exactly the other's)", facesA.received === 1 && facesB.received === 1, `A received ${facesA.received}, B ${facesB.received}`);
  await A.shot('13-ann-sees-bobs-face.png');

  // ---- 5b. Bob changes his face mid-run at the face kiosk: the kiosk's editor opens on his face, he
  // starts from the smile and adds yellow cheeks, Done. Ann sees the new face on his mask and the monitor.
  const opened = await B.cmd('kiosk open');
  const kf = JSON.parse(await B.cmd('faces'));
  check('the face kiosk opens mid-run on Bob\'s screen', opened === 'ok' && kf.kioskOpen === true, `kiosk open: ${opened}`);
  for (const st of ['press starter:smile', 'press colour:5', 'press brush:2', 'line 5 19 8 19', 'line 24 19 27 19']) await B.cmd(`kiosk ${st}`);
  await sleep(150);
  await B.shot('15-bob-at-the-face-kiosk.png');
  const doneK = await B.cmd('kiosk done');
  const fB2 = JSON.parse(await B.cmd('faces'));
  const fA2 = await until(async () => JSON.parse(await A.cmd('faces')), (f) => f.masks[b.me.id] === fB2.own && f.monitor.includes(fB2.own), 8000, 100);
  check("Bob's new face reaches Ann: on his mask and on the lift's monitor", doneK === 'ok' && !fB2.kioskOpen && fB2.own !== facesB.own
    && fA2.masks[b.me.id] === fB2.own && fA2.monitor.includes(fB2.own) && !fA2.monitor.includes(facesB.own) && fB2.monitor.includes(fB2.own),
    `Bob drew ${facesB.own}, now ${fB2.own}; on Ann's screen his mask shows ${fA2.masks[b.me.id]}, her monitor ${JSON.stringify(fA2.monitor)}; Bob's monitor ${JSON.stringify(fB2.monitor)}`);
  check('the change came as one face message (Ann still holds one face: Bob\'s)', fA2.received === 1, `Ann received ${fA2.received}`);
  await sleep(300);
  await A.shot('16-ann-sees-bobs-new-face.png');
  a = await A.state();
  b = await B.state();
  // ---- 5c. B creeps (Ctrl held, in place): B's camera drops; on A's screen B's figure crouches, its mask
  // where B's eye is (the eye B's rules use), within a few centimetres; standing, the same.
  const eyeOf = (s) => s.client.camY - s.me.y;
  const maskOn = (viewer, other) => (viewer.others ?? []).find((x) => x.id === other.me.id);
  const standMask = maskOn(a, b);
  check("standing: B's mask on A's screen is at B's eye height", standMask && Math.abs(standMask.maskY - eyeOf(b)) < 0.06,
    `mask ${standMask?.maskY?.toFixed(3)} m, B's eye ${eyeOf(b).toFixed(3)} m, clip ${standMask?.clip}`);
  await B.cmd('move 0 0 0 1');
  await sleep(900);
  a = await A.state();
  b = await B.state();
  const creepMask = maskOn(a, b);
  check("B creeps: B's camera drops, and on A's screen B's figure crouches with its mask at B's eye", b.me.gait === 'creep' && eyeOf(b) < 1.3 && creepMask?.clip === 'sneak' && creepMask?.drawn && Math.abs(creepMask.maskY - eyeOf(b)) < 0.06,
    `B's eye ${eyeOf(b).toFixed(3)} m (gait ${b.me.gait}); on A's screen: clip ${creepMask?.clip}, gait ${creepMask?.gait}, mask ${creepMask?.maskY?.toFixed(3)} m, drawn ${creepMask?.drawn}`);
  await A.shot('17-ann-sees-bob-creeping.png');
  await B.shot('18-bob-creeping-sees-ann.png');
  await B.cmd('stopmove');
  await sleep(600);
  b = await B.state();
  check("B stands up: B's camera back at standing height", Math.abs(eyeOf(b) - 1.65) < 0.005, `B's eye ${eyeOf(b).toFixed(3)} m`);

  // ---- 6. The emote wheel: A holds R, aims at WAVE (the top), lets go; B sees it on A's figure.
  await A.cmd('wheel open');
  await A.cmd('wheel aim 0 -150');
  await sleep(250);
  a = await A.state();
  check('the wheel is open, aimed at WAVE', a.client.wheel === true && a.client.wheelSel === 0, `selected ${a.client.wheelSel}`);
  await A.shot('07-emote-wheel-open.png');
  const sent = JSON.parse(await A.cmd('wheel release'));
  b = await until(B.state, (s) => (s.others ?? []).some((x) => x.id === a.me.id && x.clip === 'wave'), 3000, 50);
  const seenWave = (b.others ?? []).find((x) => x.id === a.me.id);
  check('an emote sent by one is seen by the other', sent.sent === 'wave' && seenWave?.clip === 'wave' && b.emotesSeen.some((e) => e.player === a.me.id && e.emote === 'wave'), `sent ${sent.sent}; on B's screen A's figure plays "${seenWave?.clip}"`);
  await sleep(500);
  await B.shot('08-bob-sees-ann-wave.png');
  // A tap closes the wheel without sending anything.
  await A.cmd('wheel open');
  const tap = JSON.parse(await A.cmd('wheel release'));
  check('a tap of R closes the wheel and sends nothing', tap.sent === '', `sent "${tap.sent}"`);
  // A dance, from B this time, seen by A.
  await sleep(500);
  // The wheel's sectors go clockwise from the top, 60 degrees each: WAVE up, LOOK BEHIND up-right, PRAY
  // down-right, DANCE SPIN straight down, DANCE SNAKE down-left, BUTTON up-left (main.gd EMOTE_LABELS).
  await B.cmd('wheel open');
  await B.cmd('wheel aim 0 150');
  await sleep(100);
  const bAim = (await B.state()).client.wheelSel;
  const dance = JSON.parse(await B.cmd('wheel release'));
  a = await until(A.state, (s) => (s.others ?? []).some((x) => x.id === b.me.id && x.clip === 'dance_spin'), 3000, 50);
  const seenDance = (a.others ?? []).find((x) => x.id === b.me.id);
  check('B dances (DANCE SPIN), A sees it', bAim === 3 && dance.sent === 'dance_spin' && seenDance?.clip === 'dance_spin' && a.emotesSeen.some((e) => e.player === b.me.id && e.emote === 'dance_spin'), `aimed at ${bAim}, sent ${dance.sent}; on A's screen B's figure plays "${seenDance?.clip}"`);
  await sleep(700);
  await A.shot('09-ann-sees-bob-dance.png');

  // ---- 7. A calls the lift; then the wait: A watches the Orderly whenever it is in view, B looks at the doors.
  a = await A.state();
  await A.cmd(`walkto ${planA.landing.level} ${planA.landing.x} ${planA.landing.y} 3`);
  a = await until(A.state, (s) => s.auto !== 'walking', 20000);
  await A.cmd(`face ${car.doorX} ${car.doorZ} 2.0`);
  a = await until(A.state, (s) => s.me.canCall === true || s.phase !== 'away', 15000);
  await A.cmd('call');
  a = await until(A.state, (s) => s.phase === 'coming', 5000, 50);
  check('A calls the lift: the car is coming for both', a.phase === 'coming' && (await B.state()).phase === 'coming', `A ${a.phase}`);
  // B steps a little to the side (out of A's line toward the corridor), then looks at the doors.
  await B.cmd(`face ${car.doorX} ${car.doorZ} 1.6`);
  await B.cmd('move 0 1 0 0');
  await sleep(600);
  await B.cmd('stopmove');
  await B.cmd(`face ${car.doorX} ${car.doorZ} 1.6`);
  let bothSeeing = 0;
  let aSeeing = 0;
  let watchShot = false;
  const moved = { max: 0 };
  let last = null;
  const caught = new Map(); // label -> {at, dark, others' view of the figure}
  const t0 = Date.now();
  while (Date.now() - t0 < 150000) {
    a = await A.state();
    b = await B.state();
    if (a.phase !== 'coming' && b.phase !== 'coming') break;
    if (a.orderly.seeing) {
      aSeeing++;
      if (b.orderly.seeing) bothSeeing++;
      if (last && last.seeing) moved.max = Math.max(moved.max, Math.hypot(a.orderly.x - last.x, a.orderly.z - last.z));
      // The picture: close, and with Bob not standing in the line of sight (he would hide it).
      const bearing = (x, z) => Math.atan2(x - a.me.x, z - a.me.z);
      const apart = Math.abs(Math.atan2(Math.sin(bearing(a.orderly.x, a.orderly.z) - bearing(b.me.x, b.me.z)), Math.cos(bearing(a.orderly.x, a.orderly.z) - bearing(b.me.x, b.me.z))));
      if (!watchShot && a.orderly.distance < 14 && apart > 0.35) { watchShot = true; await A.shot('10-ann-watches-the-orderly.png'); const w = await A.state(); console.log(`  the watched Orderly in that picture: seeing ${w.orderly.seeing}, visible ${w.orderly.visible}, drawn ${w.orderly.drawn}, ${w.orderly.distance.toFixed(1)} m, pose ${JSON.stringify(w.orderly.pose)}; A at ${w.me.x.toFixed(2)},${w.me.z.toFixed(2)} yaw ${w.client.yaw.toFixed(2)} pitch ${w.client.pitch.toFixed(2)}`); }
    }
    last = { seeing: a.orderly.seeing, x: a.orderly.x, z: a.orderly.z };
    if (!a.client.noise && a.orderly.level === a.me.level && a.orderly.distance < 30 && a.orderly.pose) await A.cmd(`face ${a.orderly.x} ${a.orderly.z} ${(a.orderly.pose?.y ?? 0) + 1.6}`);
    // The blackout at the end of every wait (run.gd dark_schedule) is the Orderly's time to hunt: nobody
    // can see it, so it may catch whoever is nearest. Caught players sit out until the car rides down.
    for (const [me, other, s, o] of [[A, B, a, b], [B, A, b, a]]) {
      if (s.me.status === 'caught' && !caught.has(me.label)) {
        caught.set(me.label, { at: ((Date.now() - t0) / 1000).toFixed(1), dark: s.dark, blackout: s.blackout });
        console.log(`  ${me.label} caught after ${caught.get(me.label).at} s of the wait (dark ${s.dark}, blackout ${s.blackout})`);
      }
    }
    await sleep(60);
  }
  if (!watchShot) console.log('  no clear picture of the watched Orderly (Bob stood in the way, or it never came within 14 m)');
  a = await A.state();
  b = await B.state();
  check('the watched Orderly never moved on the watcher\'s screen', a.net.watchedMoves === 0 && b.net.watchedMoves === 0 && moved.max < 1e-6, `A: ${a.net.watchedPairs} pairs of seeing frames, ${a.net.watchedMoves} moves; sampled ${aSeeing} times seeing, largest step ${moved.max.toFixed(3)} m`);
  check('not vacuous: A watched it for more than half a second while B looked away', a.net.watchedPairs > 30 && aSeeing - bothSeeing > 5, `A seeing in ${aSeeing} samples, B also seeing in ${bothSeeing}`);
  const statsA = JSON.parse(await A.cmd('stats'));
  const statsB = JSON.parse(await B.cmd('stats'));
  // A catch comes from the host: the caught player's own screen plays the catch, and the crewmate sees
  // their figure downed where they were taken (until the downed-and-healed rules replace this).
  if (caught.size) {
    await sleep(1500);
    a = await A.state();
    b = await B.state();
    const views = [];
    let ok = true;
    for (const [s, o] of [[a, b], [b, a]]) {
      if (s.me.status !== 'caught') continue;
      const fig = (o.others ?? []).find((x) => x.id === s.me.id);
      ok &&= s.client.caught === true && fig?.downed === true && Math.hypot(fig.at[0] - s.me.x, fig.at[2] - s.me.z) < 0.15;
      views.push(`${s.me.id}: own screen caught ${s.client.caught}; the other draws them downed ${fig?.downed}, ${fig ? Math.hypot(fig.at[0] - s.me.x, fig.at[2] - s.me.z).toFixed(3) : '?'} m from where they lie`);
    }
    check('a crewmate caught in the blackout is caught on both screens (from the host)', ok && views.length > 0, views.join('; '));
    const victim = a.me.status === 'caught' ? A : B;
    await victim.shot('10b-caught-own-view.png');
  } else {
    console.log('  nobody was caught in the blackout');
  }
  console.log(`  bytes per second with two players: A in ${statsA.bytes_in_per_s.toFixed(0)}, out ${statsA.bytes_out_per_s.toFixed(0)}; B in ${statsB.bytes_in_per_s.toFixed(0)}, out ${statsB.bytes_out_per_s.toFixed(0)} (over ${statsA.seconds.toFixed(0)} s); client frame cost A ${statsA.rules_ms_avg.toFixed(3)} ms`);

  // ---- 8. Boarding on BANK, the bell, the bank: the run ends for both; both are back in the lobby.
  const t8 = Date.now();
  const say = (c, what, s) => console.log(`  [${((Date.now() - t8) / 1000).toFixed(1)} s] ${c.label} ${what}: phase ${s.phase}, bell ${s.bellLeft?.toFixed?.(1)}, at ${s.me ? `${s.me.x.toFixed(2)},${s.me.z.toFixed(2)} (${s.me.status}) aboard ${s.me.aboard} side ${s.me.side}` : 'not in a run'}, auto ${s.auto}`);
  const board = async (c) => {
    const s0 = await c.state();
    say(c, 'boarding starts', s0);
    if (s0.me?.status !== 'ok') return;
    await c.cmd(`walkto ${planA.landing.level} ${planA.landing.x} ${planA.landing.y} 3`);
    say(c, 'walked', await until(c.state, (s) => s.auto !== 'walking', 20000));
    await c.cmd(`face ${car.doorX + car.inX * 2} ${car.doorZ + car.inZ * 2}`);
    await c.cmd('move 1 0 0 0');
    say(c, 'in', await until(c.state, (s) => !s.me || (s.me.aboard === true && Math.abs((s.me.x - car.doorX) * car.inX + (s.me.z - car.doorZ) * car.inZ) > 1.1), 6000, 30));
    await c.cmd('move 0 -1 0 0');
    say(c, 'on a side', await until(c.state, (s) => !s.me || s.me.side === 'bank', 4000, 30));
    await c.cmd('stopmove');
  };
  a = await until(A.state, (s) => s.phase === 'boarding' || s.phase === 'ended', 60000);
  if (caught.size === 1) {
    // The lights are back: the one on their feet looks at the one who went down.
    const [down, up] = caught.has('A') ? [A, B] : [B, A];
    const ds = await down.state();
    await up.cmd(`face ${ds.me.x} ${ds.me.z} ${ds.me.y + 0.3}`);
    await sleep(300);
    await up.shot(`10c-${up.label === 'A' ? 'ann' : 'bob'}-sees-the-caught-crewmate.png`);
  }
  await Promise.all([board(A), board(B)]);
  a = await A.state();
  b = await B.state();
  // Everyone still on their feet boards on BANK; the host counts exactly their votes.
  const standing = [a, b].filter((s) => s.me?.status === 'ok');
  check('everyone on their feet is aboard on BANK, and the host counts exactly those votes', standing.length > 0 && standing.every((s) => s.me.side === 'bank') && a.votes?.bank === standing.length && b.votes?.bank === standing.length && a.votes?.down === 0,
    `A ${a.me?.side} (${a.me?.status}), B ${b.me?.side} (${b.me?.status}), votes on A's screen ${JSON.stringify(a.votes)}, on B's ${JSON.stringify(b.votes)}`);
  await A.cmd(`look ${(Math.atan2(car.inX, car.inZ) * 180) / Math.PI + 180} 0`);
  a = await until(A.state, (s) => s.phase === 'ended', 60000);
  b = await until(B.state, (s) => s.phase === 'ended', 10000);
  check('the bell, then banked, for both', a.phase === 'ended' && b.phase === 'ended' && a.summary && !a.summary.wiped && b.summary && !b.summary.wiped, `A ${a.phase}, B ${b.phase}, total ${a.summary?.total?.toFixed(1)}`);
  a = await until(A.state, (s) => (s.client?.end ?? []).length > 0, 8000);
  b = await until(B.state, (s) => (s.client?.end ?? []).length > 0, 8000);
  check('both see the end screen', a.client.end[0] === 'BANKED' && b.client.end[0] === 'BANKED', `${a.client.end.join(' / ')}`);
  await B.shot('11-bob-banked.png');
  a = await until(A.state, (s) => scr(s).screen === 'lobby', 30000);
  b = await until(B.state, (s) => scr(s).screen === 'lobby', 30000);
  check('both are back in the lobby after the run', scr(a).screen === 'lobby' && scr(b).screen === 'lobby' && (scr(a).people ?? []).length === 2, `A ${scr(a).screen}, B ${scr(b).screen}`);
  await A.shot('12-back-in-the-lobby.png');
  writeFileSync(join(shots, 'play_net.json'), JSON.stringify({ results, statsA, statsB, server: server.lines.slice(-30) }, null, 2));
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
