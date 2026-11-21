// Down first, then out, on screen (North Star B6; T8a's rules, T8c), checked with two real game windows over
// the real network: a test server (tools/down_server.gd: the home server's room with the down rule on as in
// the game, its resident parked until the check sends it after someone, through a control line) on
// 127.0.0.1, and two game windows (the engine in GODOT on this project, small, `auto=1`, a test channel each)
// that join through the start screen's own Join, Ann and Bob, on floor 1.
//   1. Healed. Ann stands 2 m from Bob facing him, Bob faces away; the resident is put just behind Ann and
//      catches her. On Ann's screen: the view drops to the floor, the timer DOWN N shows the host's own
//      numbers (until - hostNow, the run's down time) and counts down, the line says a crewmate can help.
//      On Bob's: Ann's figure lies on the floor, the resident is bent over her. Bob walks up: HOLD F TO HELP
//      with an empty bar; he holds F: the bar fills with the host's hold, Ann's screen says BOB IS HELPING
//      YOU UP; Ann is back on her feet, her view back up, the timer gone.
//   2. Out. The resident is put behind Ann again. She crawls (never faster than the rules' crawl). Bob comes,
//      holds F a while and lets go: the bar empties; holds again and walks out of reach: it empties again.
//      Nobody finishes: Ann is out. Her screen goes dark: OUT, YOU REJOIN WHEN THE CAR NEXT MOVES. A red spot
//      is on the floor where she lay, on both screens, where the host says; Ann's figure is gone from Bob's.
//   LS1 (North Star B7) along the way: while Ann is down Bob is the last one up, so his screen prints his tape's
//      bonus, hers says every camera is on him, and both cut the music; healed, it is over; out, her view is locked
//      on him.
// Pictures in export/shots/down/: Ann's downed view with the timer, Bob's prompt with the bar part filled,
// Ann's out screen, the red spot from Bob's view, and the resident bent over her from a step away. Prints `N passed, M failed`; exit code 1 on any failure.
//   node godot/tools/play_down.mjs [--port=4466] [--seed=down-1] [--headless=1]
//   --headless=1  a dry run with no windows (no pictures)
// Ports 4460-4479 only: the server on port, the windows' test channels on port+1 and port+2, the server's
// control line on port+3. Start .local/guard-mouse.ps1 beside it. Every process it starts is stopped.
import { spawn } from 'node:child_process';
import { existsSync, mkdirSync, writeFileSync } from 'node:fs';
import { connect } from 'node:net';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const here = dirname(fileURLToPath(import.meta.url));
const project = resolve(here, '..');
const root = resolve(project, '..');
const arg = (k, d) => (process.argv.find((a) => a.startsWith(`--${k}=`)) ?? `--${k}=${d}`).split('=')[1];
const port = Number(arg('port', 4466));
const seed = arg('seed', 'down-1');
const headless = arg('headless', '0') === '1';
const godot = process.env.GODOT || join(root, 'tools', 'godot', 'Godot_v4.7.2-stable_win64_console.exe');
if (!existsSync(godot)) throw new Error(`no engine at ${godot}: set GODOT`);
const testPorts = [port + 1, port + 2];
const ctlPort = port + 3;
for (const p of [port, ...testPorts, ctlPort]) if (!(p >= 4460 && p <= 4479)) throw new Error(`port ${p} is outside 4460-4479`);
const shots = resolve(project, 'export', 'shots', 'down');
mkdirSync(shots, { recursive: true });
const SECRET = 'test-passphrase';
const url = `ws://127.0.0.1:${port}`;
// The North Star's numbers (B6), the check's own: three held, the crawl no faster than 0.6 m/s; and the owner's
// 20 Nov "Probably need 30 seconds" down (DR1, the home server's room has the ring on), drawn as a ring, not words.
const DOWN_S = 30;
const CRAWL = 0.6;

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
const dist = (s, x, z) => Math.hypot(s.me.x - x, s.me.z - z);
const r2 = (x) => (typeof x === 'number' ? x.toFixed(2) : String(x));
const myDown = (s) => (s.downs?.host?.down ?? []).find((d) => d.id === s.me.id);
const downOf = (s, id) => (s.downs?.host?.down ?? []).find((d) => d.id === id);
const other = (s, id) => (s.others ?? []).find((o) => o.id === id);
const eyeOf = (s) => s.camPos[1] - s.me.y;

/** Moves a player to within `near` metres of (x, z) by facing it and stepping. */
async function approach(c, x, z, near, gait = 'walk', ms = 8000) {
  const end = Date.now() + ms;
  let s = await c.state();
  while (dist(s, x, z) > near && Date.now() < end) {
    await c.cmd(`face ${x} ${z}`);
    await c.cmd(gait === 'creep' ? 'move 1 0 0 1' : 'move 1 0 0 0');
    await sleep(dist(s, x, z) < near + 0.5 ? 30 : 70);
    s = await c.state();
  }
  await c.cmd('stopmove');
  await sleep(100);
  return c.state();
}

// ---- The server.
const server = launch(['--headless', '--path', project, '-s', 'res://tools/down_server.gd', '--', `port=${port}`, `ctl=${ctlPort}`, `seed=${seed}`], { env: { GD_JOIN_SECRET: SECRET }, echo: 'server' });
await until(async () => server.lines.join('\n'), (t) => t.includes('listening on') || server.exited, 30000);
if (!server.lines.join('\n').includes('listening on')) { console.log('the server did not start'); process.exit(1); }
const ctl = await line(ctlPort, 'server control', () => !server.exited);
const host = async (c) => JSON.parse(await ctl.cmd(c));

let A = null;
let B = null;
try {
  A = await game('A', testPorts[0], [`join=${url}`, 'name=Ann', `pass=${SECRET}`], '40,40');
  B = await game('B', testPorts[1], [`join=${url}`, 'name=Bob', `pass=${SECRET}`], '700,40');
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
  const idA = a.me.id;
  const idB = (await B.state()).me.id;
  check('the run has the down rule on (the host\'s downs block, nobody down)', Array.isArray(a.downs?.host?.down) && a.downs.host.down.length === 0 && a.depth === 1,
    `downs ${JSON.stringify(a.downs?.host)}, depth ${a.depth}, place ${a.place}`);

  // Two spots: Ann on a cell open on all four sides, Bob on the cell next to it toward the lift.
  const plan = JSON.parse(await A.cmd('plan'));
  const w = plan.width;
  const h = plan.height;
  const L = plan.landing.level;
  const at = (x, y) => (x < 0 || y < 0 || x >= w || y >= h ? -1 : plan.liftDist[L * w * h + y * w + x]);
  const vert = (x, y) => plan.edges[L].vertical[y * (w + 1) + x];
  const horz = (x, y) => plan.edges[L].horizontal[y * w + x];
  const free = (e) => e === 'open' || e === 'none';
  const open = (x, y) => free(vert(x, y)) && free(vert(x + 1, y)) && free(horz(x, y)) && free(horz(x, y + 1))
    && at(x - 1, y) >= 0 && at(x + 1, y) >= 0 && at(x, y - 1) >= 0 && at(x, y + 1) >= 0;
  let spotA = null;
  let spotB = null;
  for (let d = 3; d <= 9 && !spotA; d++) {
    for (let y = 0; y < h && !spotA; y++) {
      for (let x = 0; x < w && !spotA; x++) {
        if (at(x, y) !== d || !open(x, y)) continue;
        const n = [[x - 1, y], [x + 1, y], [x, y - 1], [x, y + 1]].find(([nx, ny]) => at(nx, ny) === d - 1 && open(nx, ny));
        if (n) { spotA = { x, y }; spotB = { x: n[0], y: n[1] }; }
      }
    }
  }
  if (!spotA) throw new Error('no open pair of cells near the lift');
  const C = (p) => ({ x: (p.x + 0.5) * 2, z: (p.y + 0.5) * 2 });
  const pa = C(spotA);
  const pb = C(spotB);
  console.log(`  Ann's spot ${JSON.stringify(spotA)} (${pa.x}, ${pa.z}), Bob's ${JSON.stringify(spotB)} (${pb.x}, ${pb.z})`);
  for (const c of [A, B]) await c.cmd('move 1 0 0 0');
  await sleep(1600);
  for (const c of [A, B]) await c.cmd('stopmove');
  await A.cmd(`walkto ${L} ${spotA.x} ${spotA.y} 3`);
  await B.cmd(`walkto ${L} ${spotB.x} ${spotB.y} 3`);
  a = await until(A.state, (s) => s.auto !== 'walking', 40000);
  b = await until(B.state, (s) => s.auto !== 'walking', 40000);
  a = await approach(A, pa.x, pa.z, 0.15);
  b = await approach(B, pb.x, pb.z, 0.15);
  a = await until(A.state, (s) => s.phase === 'away', 30000, 200);

  /**
   * FX3: the resident goes behind `name` only once the host has them facing `to` (the server puts it behind the way
   * the host's last input faces: with an input still in flight it was put at their side, in their view, held there and
   * never caught them), then waits on the host's state for it to be hunting (sent again once, said loudly, if not).
   */
  async function sendBehind(name, to) {
    const me = (i) => (i.players ?? []).find((q) => q.name === name);
    const turned = (i) => {
      const p = me(i);
      if (!to) return true;
      if (!p || p.yaw == null) return false;
      const want = Math.atan2(-(to.x - p.x), -(to.z - p.z));
      return Math.abs(Math.atan2(Math.sin(p.yaw - want), Math.cos(p.yaw - want))) < 0.15;
    };
    let info = await until(() => host('info'), turned, 5000, 50);
    if (!turned(info)) console.log(`  the host never had ${name} facing the way asked: ${JSON.stringify(me(info))}`);
    let r = null;
    const going = (i) => ['hunting', 'windUp', 'bending'].includes(i.orderly?.mode) || me(i)?.status === 'down';
    for (let tries = 0; tries < 2; tries++) {
      r = await host(`behind ${name}`);
      if (!r.ok) throw new Error(`the server could not send the resident: ${JSON.stringify(r)}`);
      info = await until(() => host('info'), going, 2000, 40);
      if (going(info)) {
        if (info.orderly?.held) console.log(`  the resident behind ${name} is held (seen) as it starts: ${JSON.stringify(info.orderly)}`);
        return r;
      }
      console.log(`RETRY the resident behind ${name}: not hunting on the host after 2 s (${JSON.stringify(info.orderly)}), sending it again`);
    }
    return r;
  }

  /** Ann faces Bob, Bob faces away from her; then the resident is sent after Ann from just behind her. */
  async function catchAnn() {
    let s = await A.state();
    const t = await B.state();
    await A.cmd(`face ${t.me.x} ${t.me.z}`);
    await B.cmd(`face ${2 * t.me.x - s.me.x} ${2 * t.me.z - s.me.z}`);
    await sendBehind('Ann', { x: t.me.x, z: t.me.z });
    s = await until(A.state, (x) => x.me.status === 'down', 12000, 40);
    return s;
  }

  // ---- 1. Healed.
  a = await catchAnn();
  const downedAt = Date.now();
  check('1. caught: Ann is down (the host\'s status and downs block), the resident bends over her', a.me.status === 'down' && myDown(a) !== undefined,
    `status ${a.me.status}, down ${JSON.stringify(myDown(a))}, resident ${JSON.stringify((await host('info')).orderly)}`);
  const d0 = myDown(a) ?? {};
  // Bob, meanwhile, walks over (he sees her fall first).
  const bobGoes = (async () => {
    let t = await until(B.state, (s) => other(s, idA)?.status === 'down', 4000, 40);
    const seenDown = other(t, idA);
    t = await approach(B, seenDown.x, seenDown.z, 0.95);
    return { t, seenDown };
  })();
  a = await until(A.state, (s) => s.downs?.hud?.head?.startsWith('DOWN'), 6000, 50);
  const ringAfter = Date.now() - downedAt;
  // CS1: the Orderly's own caught scene played on Ann's screen only, and the ring came within about 1.2 s of it.
  const sceneA = a.client?.caughtScene ?? {};
  check('Ann\'s screen: the Orderly\'s caught scene played, then the down ring within about 1.2 s', sceneA.last === 'orderly' && sceneA.starts >= 1 && ringAfter <= 1600,
    `scene ${JSON.stringify({ last: sceneA.last, starts: sceneA.starts, model: sceneA.model })}, ring ${ringAfter} ms after her screen had her down (polled every 50 ms)`);
  await sleep(300);
  a = await A.state();
  const left1 = myDown(a) ? myDown(a).until - a.hostNow : NaN;
  const shown1 = a.downs.view.seconds;
  check('Ann\'s screen: the view drops to the floor', eyeOf(a) > 0.3 && eyeOf(a) < 0.6 && a.me.eye < 0.6, `eye ${r2(eyeOf(a))} m above her feet (me.eye ${a.me.eye})`);
  check('Ann\'s screen: the timer DOWN N is the host\'s, the run\'s own down time', a.downs.hud.head === `DOWN  ${Math.ceil(shown1)}` && Math.abs(shown1 - left1) < 0.15
    && Math.abs((d0.until - d0.at) - DOWN_S) < 1e-6 && a.downs.hud.left > 0 && a.downs.hud.left < 1,
    `"${a.downs.hud.head}", shown ${r2(shown1)} s, host until - now ${r2(left1)} s, the run's down time ${r2(d0.until - d0.at)} s, bar ${r2(a.downs.hud.left)}`);
  check('Ann\'s screen: a line says a crewmate can help, and what she can do', /CREWMATE CAN HOLD F|IS HELPING YOU UP/.test(a.downs.hud.line) && /CRAWL/.test(a.downs.hud.line2),
    `"${a.downs.hud.line}" / "${a.downs.hud.line2}"`);
  await A.shot('1-down-timer.png');
  await sleep(1000);
  a = await A.state();
  const shown2 = a.downs.view.seconds;
  check('Ann\'s timer counts down', shown2 < shown1 - 0.7 && shown2 > 0, `${r2(shown1)} s then ${r2(shown2)} s a second later; "${a.downs.hud.head}"`);
  const { t: b1, seenDown } = await bobGoes;
  b = b1;
  // LS1 (North Star B7): Ann down leaves Bob the last one up: the spotlight on both screens, the music cut.
  const ls = (s) => s.lastStand ?? {};
  check('LS1: Bob is the last one up: his screen prints his tape\'s bonus, Ann\'s says the cameras are on him, the music is cut on both',
    ls(b).host?.id === idB && ls(b).self === true && /^LAST ONE UP\. YOUR TAPE PAYS X1\.5 /.test(ls(b).line ?? '') && ls(a).line === 'ALL CAMERAS ON BOB. THE LAST ONE UP'
    && ls(a).music?.hushed === true && ls(b).music?.hushed === true,
    `host ${JSON.stringify(ls(b).host)}; Bob "${ls(b).line}", Ann "${ls(a).line}", hushed ${ls(a).music?.hushed}/${ls(b).music?.hushed}`);
  check('Bob\'s screen: no caught scene for Ann\'s catch (he sees the figure in the world)', (b.client?.caughtScene?.starts ?? -1) === 0,
    `starts ${b.client?.caughtScene?.starts}`);
  const figA = other(b, idA);
  check('Bob\'s screen: Ann\'s figure lies on the floor (downed, lying or crawling, not standing)', figA?.downed === true && ['taken', 'crawl', 'down_idle'].includes(figA.clip) && figA.drawn === true,
    `downed ${figA?.downed}, clip ${figA?.clip}, drawn ${figA?.drawn}, mask at ${r2(figA?.maskY)} m`);
  check('Bob\'s screen: the resident is bent over her (the host\'s mode, drawn in the bend)', b.orderly.mode === 'bending' && b.orderly.pose?.anim === 'bend' && (b.downs.bend ?? 0) > 0.5 && b.client.residentDrawn,
    `mode ${b.orderly.mode}, pose ${b.orderly.pose?.anim}, drawn ${b.client.residentDrawn}, bend ${r2(b.downs.bend)}`);
  check('Bob beside her: HOLD F TO HELP with an empty bar', b.client.prompt === 'HOLD F TO HELP' && b.downs.hud.fill === 0 && b.downs.view.target === idA,
    `prompt "${b.client.prompt}", bar ${b.downs.hud.fill}, ${r2(dist(b, seenDown.x, seenDown.z))} m from her`);
  check('the first catch uses the default bend on the other screen', b.orderly.clip === 'mixamo_reach', b.orderly.clip);
  await B.cmd(`face ${seenDown.x} ${seenDown.z} 0.2`);
  await B.cmd('use 1');
  b = await until(B.state, (s) => (s.downs?.hud?.fill ?? 0) >= 0.3, 4000, 30);
  const fillA = b.downs.hud.fill;
  await B.shot('2-help-prompt.png');
  a = await A.state();
  check('Bob holds F: the bar fills with the host\'s hold', b.client.prompt === 'HOLD F TO HELP' && fillA >= 0.3 && fillA < 0.9 && downOf(b, idA)?.healer === idB,
    `bar ${r2(fillA)}, host healer ${downOf(b, idA)?.healer}`);
  check('Ann\'s screen: BOB IS HELPING YOU UP, with the hold\'s bar', a.downs.hud.line === 'BOB IS HELPING YOU UP' && a.downs.hud.heal > 0,
    `"${a.downs.hud.line}", bar ${r2(a.downs.hud.heal)}`);
  a = await until(A.state, (s) => s.me.status === 'ok', 5000, 40);
  const healedIn = (Date.now() - downedAt) / 1000;
  await B.cmd('use 0');
  await sleep(400);
  a = await A.state();
  b = await B.state();
  check('1. healed: Ann is back on her feet, her view back up, the timer gone', a.me.status === 'ok' && eyeOf(a) > 1.5 && a.downs.hud.head === '' && !a.downs.hud.out && (a.events.healed ?? 0) === 1,
    `status ${a.me.status}, eye ${r2(eyeOf(a))} m, head "${a.downs.hud.head}", healed ${a.events.healed} (${r2(healedIn)} s after going down)`);
  check('Bob\'s screen: Ann stands, the prompt is gone', other(b, idA)?.downed === false && b.client.prompt !== 'HOLD F TO HELP', `downed ${other(b, idA)?.downed}, prompt "${b.client.prompt}"`);
  check('LS1: healed, the spotlight is over on both screens', (b.lastStand?.host ?? null) === null && (b.lastStand?.line ?? '') === '' && (a.lastStand?.line ?? '') === '',
    `host ${JSON.stringify(b.lastStand?.host)}, lines "${b.lastStand?.line}" / "${a.lastStand?.line}"`);
  await A.cmd('move 1 0 0 0');
  await sleep(500);
  await A.cmd('stopmove');
  a = await A.state();
  check('play goes on: Ann walks', a.me.status === 'ok' && a.me.speed > 1.0 || dist(a, pa.x, pa.z) > 0.3, `${r2(dist(a, pa.x, pa.z))} m from where she lay`);

  // ---- 2. Out: nobody finishes the hold.
  check('the host enables the optional catch dance from the panel', await A.cmd('panel set orderly.catch_dance 1') === 'sent');
  a = await approach(A, pa.x, pa.z, 0.2);
  b = await approach(B, pb.x, pb.z, 0.2);
  await sleep(500);
  a = await catchAnn();
  check('2. caught again: Ann is down', a.me.status === 'down', `status ${a.me.status}`);
  const bobTries = (async () => {
    let t = await until(B.state, (s) => other(s, idA)?.status === 'down', 4000, 40);
    let o = other(t, idA);
    t = await approach(B, o.x, o.z, 0.95);
    o = other(t, idA);
    await B.cmd(`face ${o.x} ${o.z} 0.2`);
    const p0 = t.client.prompt;
    await B.cmd('use 1');
    t = await until(B.state, (s) => (s.downs?.hud?.fill ?? 0) >= 0.25, 3000, 30);
    const f1 = t.downs.hud.fill;
    // A witness can see the dance while attempting a rescue. Keep holding until the full bend has played.
    t = await until(B.state, (s) => s.orderly.clip === 'bellydance', 1400, 40);
    check('Bob sees the host-enabled belly dance while Ann is down', t.orderly.clip === 'bellydance' && t.me.status === 'ok' && other(t, idA)?.status === 'down',
      `clip ${t.orderly.clip}, pose ${t.orderly.pose?.anim}, catch ${t.orderly.pose?.catch_active}`);
    await B.cmd('use 0');
    await sleep(350);
    t = await B.state();
    const letGo = { fill: t.downs.hud.fill, healer: downOf(t, idA)?.healer, prompt: t.client.prompt };
    await B.cmd('use 1');
    t = await until(B.state, (s) => (s.downs?.hud?.fill ?? 0) >= 0.15, 3000, 30);
    const f2 = t.downs.hud.fill;
    // Away, F still held, until out of reach.
    o = other(t, idA);
    await B.cmd(`face ${2 * t.me.x - o.x} ${2 * t.me.z - o.z}`);
    await B.cmd('move 1 0 0 0');
    t = await until(B.state, (s) => Math.hypot(s.me.x - o.x, s.me.z - o.z) > 2.0, 3000, 30);
    await B.cmd('stopmove');
    await sleep(350);
    t = await B.state();
    const away = { fill: t.downs.hud.fill, healer: downOf(t, idA)?.healer, prompt: t.client.prompt, dist: Math.hypot(t.me.x - o.x, t.me.z - o.z) };
    await B.cmd('use 0');
    // From out here, a look back at the resident bent over her (a picture only).
    await B.cmd(`face ${t.orderly.x} ${t.orderly.z} 0.9`);
    await sleep(250);
    await B.shot('5-resident-bent-over.png');
    return { p0, f1, letGo, f2, away };
  })();
  // Ann crawls once the resident's turn of her head is over.
  a = await until(A.state, (s) => s.downs?.hud?.head?.startsWith('DOWN') && !s.downs.turning, 6000, 50);
  const c0 = { x: a.me.x, z: a.me.z, t: Date.now() };
  await A.cmd(`look ${(a.client.yaw * 180) / Math.PI + 180} 0`);
  await A.cmd('move 1 0 0 0');
  await sleep(1200);
  await A.cmd('stopmove');
  await sleep(150);
  a = await A.state();
  const crawled = Math.hypot(a.me.x - c0.x, a.me.z - c0.z);
  const crawlSpeed = crawled / ((Date.now() - c0.t) / 1000);
  check('Ann crawls, no faster than the rules\' crawl', a.me.status === 'down' && crawled > 0.2 && crawlSpeed <= CRAWL + 0.05,
    `${r2(crawled)} m in ${r2((Date.now() - c0.t) / 1000)} s (${r2(crawlSpeed)} m/s), gait ${a.me.gait}`);
  const tries = await bobTries;
  check('Bob lets go: the bar empties (the host stops the hold)', tries.p0 === 'HOLD F TO HELP' && tries.f1 >= 0.25 && tries.letGo.fill === 0 && (tries.letGo.healer ?? '') === '',
    `prompt "${tries.p0}", bar ${r2(tries.f1)} then ${r2(tries.letGo.fill)} after letting go, host healer "${tries.letGo.healer}"`);
  check('Bob walks out of reach holding F: the bar empties, the prompt goes', tries.f2 >= 0.15 && tries.away.prompt !== 'HOLD F TO HELP' && (tries.away.healer ?? '') === '',
    `bar ${r2(tries.f2)}, then ${r2(tries.away.dist)} m away: prompt "${tries.away.prompt}", host healer "${tries.away.healer}"`);
  a = await until(A.state, (s) => s.me.status === 'out', (DOWN_S + 2) * 1000, 50);
  await sleep(500);
  a = await A.state();
  check('2. not healed: Ann is out', a.me.status === 'out' && (a.events.out ?? 0) === 1, `status ${a.me.status}, out events ${a.events.out}`);
  check('Ann\'s screen goes dark: OUT, YOU REJOIN WHEN THE CAR NEXT MOVES', (a.downs.hud.out === true || a.watch?.watching === true) && a.downs.hud.outLines[0] === 'OUT' && a.downs.hud.outLines.includes('YOU REJOIN WHEN THE CAR NEXT MOVES') && a.downs.hud.head === '',
    `out ${a.downs.hud.out}, lines ${JSON.stringify(a.downs.hud.outLines)}`);
  check('LS1: out, Ann\'s view is locked on Bob, the last one up', a.watch?.watching === true && a.watch?.id === idB && a.watch?.locked === true && /THE LAST ONE UP/.test(a.watch?.caption ?? ''),
    `watch ${JSON.stringify({ watching: a.watch?.watching, id: a.watch?.id, locked: a.watch?.locked, caption: a.watch?.caption })}`);
  await A.shot('3-out-screen.png');
  const info = await host('info');
  const spot = (info.spots ?? [])[0];
  b = await B.state();
  const near = (p) => spot && p && Math.abs(p[0] - spot.x) < 0.02 && Math.abs(p[2] - spot.z) < 0.02 && Math.abs(p[1] - spot.y) < 0.05;
  check('a red spot where she lay, on both screens, where the host has it', info.spots?.length === 1 && spot.playerId === idA
    && a.downs.host.spots.length === 1 && b.downs.host.spots.length === 1 && a.downs.view.spots.length === 1 && b.downs.view.spots.length === 1
    && near(a.downs.view.spots[0]) && near(b.downs.view.spots[0]),
    `host ${JSON.stringify(spot)}; drawn on Ann's ${JSON.stringify(a.downs.view.spots)}, on Bob's ${JSON.stringify(b.downs.view.spots)}`);
  check('Bob\'s screen: Ann\'s figure is gone', other(b, idA)?.drawn === false && other(b, idA)?.status === 'out', `drawn ${other(b, idA)?.drawn}, status ${other(b, idA)?.status}`);
  if (spot) {
    await B.cmd(`face ${spot.x} ${spot.z} ${spot.y}`);
    await sleep(400);
    await B.shot('4-red-spot.png');
  }
  b = await B.state();
  check('Bob plays on, on his feet', b.me.status === 'ok' && b.phase !== 'ended', `status ${b.me.status}, phase ${b.phase}`);

  // ---- 3. LS1 (North Star B7): the wipe. The resident goes after Bob too; nobody is left to help him. When he is out the
  // whole crew is: every screen plays the same scene of the empty car taking the resident up, then the prison shows a
  // standee of Bob, the last one caught.
  b = await B.state();
  if (spot) await B.cmd(`face ${2 * b.me.x - spot.x} ${2 * b.me.z - spot.z}`);
  const r3 = await sendBehind('Bob', spot ? { x: 2 * b.me.x - spot.x, z: 2 * b.me.z - spot.z } : null);
  b = await until(B.state, (s) => s.me.status === 'down', 20000, 40);
  if (b.me.status !== 'down') console.log(`  Bob not caught: host ${JSON.stringify(await host('info'))}, sent ${JSON.stringify(r3)}`);
  a = await A.state();
  check('3. caught: Bob is down too, so nobody is up: no spotlight', b.me.status === 'down' && (b.lastStand?.host ?? null) === null && (a.lastStand?.line ?? '') === '',
    `status ${b.me.status}, host ${JSON.stringify(b.lastStand?.host)}`);
  const [sa, sb] = await Promise.all([
    until(A.state, (s) => s.lastStand?.sceneOn === true && s.lastStand?.scene?.figureDrawn === true, (DOWN_S + 12) * 1000, 40),
    until(B.state, (s) => s.lastStand?.sceneOn === true && s.lastStand?.scene?.figureDrawn === true, (DOWN_S + 12) * 1000, 40)]);
  const wa = sa.lastStand?.wipe ?? {};
  const wb = sb.lastStand?.wipe ?? {};
  check('the wipe: both screens play the scene from the one host event, naming the Orderly and Bob', wa.at === wb.at && wa.by === 'orderly' && wa.last === idB && wb.last === idB
    && sa.lastStand.scene.figureKind === 'orderly' && sb.lastStand.scene.figureKind === 'orderly' && sa.lastStand.letterbox && sb.lastStand.letterbox,
    `Ann ${JSON.stringify(wa)} / Bob ${JSON.stringify(wb)}; figures ${sa.lastStand.scene.figureKind}/${sb.lastStand.scene.figureKind}`);
  check('the scene: the doors are open as the Orderly walks in, the music is cut', sa.lastStand.scene.doors === true && sb.lastStand.scene.doors === true && sa.lastStand.scene.anim === 'walk'
    && sa.lastStand.music?.hushed === true && sb.lastStand.music?.hushed === true,
    `doors ${sa.lastStand.scene.doors}/${sb.lastStand.scene.doors}, anim ${sa.lastStand.scene.anim}, ${r2(sa.lastStand.scene.e)} s / ${r2(sb.lastStand.scene.e)} s in`);
  await A.shot('5-wipe-scene.png');
  const [ha, hb] = await Promise.all([
    until(A.state, (s) => s.depth === 0 && s.lastStand?.standeeShown?.name, 45000, 100),
    until(B.state, (s) => s.depth === 0 && s.lastStand?.standeeShown?.name, 45000, 100)]);
  check('the prison: both screens show a standee of Bob, the last one caught, with the same face', ha.lastStand.standeeShown.name === 'BOB' && hb.lastStand.standeeShown.name === 'BOB'
    && ha.lastStand.standeeShown.hash === hb.lastStand.standeeShown.hash && ha.lastStand.standee === idB,
    `Ann's ${JSON.stringify(ha.lastStand.standeeShown)}, Bob's ${JSON.stringify(hb.lastStand.standeeShown)}`);
  if (ha.lastStand.standeeShown.at) {
    await A.cmd(`face ${ha.lastStand.standeeShown.at[0]} ${ha.lastStand.standeeShown.at[1]} 1.2`);
    await sleep(400);
    await A.shot('6-standee.png');
  }
  const errors = [...A.g.lines, ...B.g.lines, ...server.lines].filter((l) => /SCRIPT ERROR|ERROR: .*\.gd/.test(l));
  check('no script errors', errors.length === 0, errors.slice(0, 3).join(' | '));
  writeFileSync(join(shots, 'play_down.json'), JSON.stringify({ results, seed }, null, 2));
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
