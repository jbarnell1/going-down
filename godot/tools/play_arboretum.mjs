// The Arboretum and the Groundskeeper (sim/noise.gd, sim/hearing.gd, sim/arboretum.gd, client/arboretum_view.gd,
// client/groundskeeper_view.gd), checked with two real game clients over the real network: the test server
// (tools/garden_server.gd: the home server's room with every rule on, the run starting on floor 5, down lasting
// 60 s, the Groundskeeper 12 to 15 m from the first whistle) on 127.0.0.1, and two games (`auto=1`, a test
// channel each) that join through the start screen's own Join. From BOTH screens:
//   - the floor is the Arboretum, each client's garden is the host's (the same hash), the near light is on, and
//     the ground under a player is what the host's garden says (gravel on the apron, moss on the worn line);
//   - Ann whistles (a sound emote): it tilts, then comes, on both screens; Ann creeps out of reach along the
//     moss and lives through the lean; it stands where the whistle was;
//   - Bob whistles and stays: it is taken when the lean ends and is down (one more heal left);
//   - Ann draws it off with a whistle, creeps back along the moss and heals Bob; again Bob whistles and is down;
//     healed again; the third snatch puts him out at once;
//   - Ann sprints away and is run down;
//   - in a fresh run, Bob records Ann's decoy, crosses moss in the blackout, and both bank at home.
// With --shots=1 (windowed only) it also takes pictures along the way into export/shots/arboretum/.
// Prints `N passed, M failed`; exit code 1 on any failure.
//   node godot/tools/play_arboretum.mjs [--port=4470] [--seed=garden-1] [--headless=1] [--scenario=all|escape]
// Ports 4460-4479 or 4490-4499 only; the games' test channels are on port+1 and port+2. Windowed: start
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
const seed = arg('seed', 'garden-1');
const headless = arg('headless', '0') === '1';
const escapeOnly = arg('scenario', 'all') === 'escape';
const godot = process.env.GODOT || join(root, 'tools', 'godot', 'Godot_v4.7.2-stable_win64_console.exe');
if (!existsSync(godot)) throw new Error(`no engine at ${godot}: set GODOT`);
const testPorts = [port + 1, port + 2];
for (const p of [port, ...testPorts]) if (!((p >= 4460 && p <= 4479) || (p >= 4490 && p <= 4499))) throw new Error(`port ${p} is outside 4460-4479 and 4490-4499`);
const shots = resolve(project, 'export', 'shots', 'arboretum');
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
const dist = (s, x, z) => Math.hypot(s.me.x - x, s.me.z - z);
const other = (s, id) => (s.others ?? []).find((o) => o.id === id);
const r2 = (x) => (typeof x === 'number' ? x.toFixed(2) : String(x));
const mode = (s) => s.orderly?.mode;

/** Walks the game's own way to the middle of the cell under (x, z), at a creep. */
async function creepTo(c, x, z, ms = 60000) {
  await c.cmd(`walkto 0 ${Math.floor(x / 2)} ${Math.floor(z / 2)} 1.2 creep`);
  await sleep(200);
  return until(c.state, (s) => s.auto !== 'walking', ms);
}
/** Creeps straight at (x, z) until within `near` of it. */
async function approach(c, x, z, near, ms = 10000) {
  const end = Date.now() + ms;
  let s = await c.state();
  while (dist(s, x, z) > near && Date.now() < end) {
    await c.cmd(`face ${x} ${z}`);
    await c.cmd('move 1 0 0 1');
    await sleep(60);
    s = await c.state();
  }
  await c.cmd('stopmove');
  await sleep(120);
  return c.state();
}

async function escapeGarden(A, B, st, plan, doorOut, lz) {
  // The middle moss station is in recording range but outside the reach of the lean.
  await creepTo(B, ...st[2], 20000);
  await B.cmd('raise 1');
  await A.cmd('emote button');
  await until(A.state, (s) => mode(s) === 'coming', 4000, 30);
  const [fx, fz] = st[4];
  const [mx, mz] = st[2];
  const [recorded] = await Promise.all([
    until(B.state, (s) => mode(s) === 'coming' && s.inst?.needle === 'recording' && s.inst.value > 0, 7000, 30),
    approach(A, fx + (mx - fx) * 0.64, fz + (mz - fz) * 0.64, 0.1),
  ]);
  check('Bob records the Groundskeeper while it comes to Ann’s whistle', mode(recorded) === 'coming' && recorded.inst?.needle === 'recording' && recorded.inst.value > 0,
    `mode ${mode(recorded)}, needle ${recorded.inst?.needle}, value ${r2(recorded.inst?.value)}`);
  await until(A.state, (s) => mode(s) === 'listening', 10000);
  await B.cmd('raise 0');

  await creepTo(A, ...doorOut);
  await approach(A, doorOut[0], lz, 0.4);
  await until(A.state, (s) => s.phase === 'away' && s.me.canCall, 6000);
  await A.cmd('call');
  const called = await until(A.state, (s) => s.phase === 'coming', 5000);
  if (called.phase !== 'coming') {
    check('Ann calls the lift', false, `phase ${called.phase}, can call ${called.me.canCall}, position ${called.me.x},${called.me.z}, status ${called.me.status}`);
    return;
  }
  const [darkA, darkB] = await Promise.all([A, B].map((c) =>
    until(c.state, (s) => (s.blackout === true && s.dark === true) || s.phase === 'boarding', 100000)
  ));
  check('the crew calls the lift and both clients enter the blackout', [darkA, darkB].every((s) => s.phase === 'coming' && s.blackout === true && s.dark === true),
    `Ann ${darkA.phase}, blackout ${darkA.blackout}; Bob ${darkB.phase}, blackout ${darkB.blackout}`);

  const silentMoss = (s) => s.blackout === true && s.dark === true && s.garden?.ground === 'moss' && mode(s) === 'listening' && s.me.status === 'ok';
  let quiet = silentMoss(darkB);
  await B.cmd(`walkto 0 ${Math.floor(st[0][0] / 2)} ${Math.floor(st[0][1] / 2)} 1.2 creep`);
  const crossed = await until(B.state, (s) => {
    quiet &&= silentMoss(s);
    return dist(s, ...st[0]) < 0.2 || !quiet;
  }, 12000, 40);
  await B.cmd('stopwalk');
  check('Bob crosses four metres of moss during the blackout without being heard',
    quiet && dist(darkB, ...st[2]) < 0.2 && dist(crossed, ...st[0]) < 0.2,
    `moved ${r2(dist(darkB, crossed.me.x, crossed.me.z))} m, blackout ${crossed.blackout}, ground ${crossed.garden?.ground}, resident ${mode(crossed)}, Bob ${crossed.me.status}`);

  await Promise.all([A, B].map((c) => until(c.state, (s) => s.phase === 'boarding' && s.client.doors > 0.95, 40000)));
  async function board(c) {
    const { doorX, doorZ, inX, inZ } = plan.car;
    if (c === B) await creepTo(c, ...doorOut, 20000);
    await approach(c, doorOut[0], lz, 0.25);
    await c.cmd(`face ${doorX + inX * 2} ${doorZ + inZ * 2}`);
    await c.cmd('move 1 0 0 1');
    await until(c.state, (s) => s.me.aboard && (s.me.x - doorX) * inX + (s.me.z - doorZ) * inZ > 1.1, 8000, 30);
    await c.cmd('move 0 -1 0 1');
    const aboard = await until(c.state, (s) => s.me.aboard && s.me.side === 'bank', 4000, 30);
    await c.cmd('stopmove');
    return aboard;
  }
  let [a, b] = await Promise.all([A, B].map(board));
  check('both crew members return alive through the opened doors and vote Bank',
    [a, b].every((s) => s.phase === 'boarding' && s.me.aboard && s.me.side === 'bank' && s.me.status === 'ok'),
    `Ann ${a.phase}/${a.me.side}/${a.me.status}; Bob ${b.phase}/${b.me.side}/${b.me.status}`);
  [a, b] = await Promise.all([A, B].map((c) => until(c.state, (s) => s.depth === 0 && s.phase === 'unloading' && s.client.doors > 0.95, 65000)));
  check('the lift banks the crew’s reading and both clients arrive home',
    [a, b].every((s) => s.depth === 0 && s.phase === 'unloading' && s.me.aboard && s.me.status === 'ok' && s.summary?.total > 0),
    `Ann floor ${a.depth}, banked ${a.summary?.total}; Bob floor ${b.depth}, banked ${b.summary?.total}`);
  await Promise.all([A, B].map(async (c) => {
    const { doorX, doorZ, inX, inZ } = JSON.parse(await c.cmd('plan')).car;
    await c.cmd(`face ${doorX - inX * 3} ${doorZ - inZ * 3}`);
    await c.cmd('move 1 0 0 0');
    await until(c.state, (s) => s.me.aboard === false, 8000, 30);
    await c.cmd('stopmove');
  }));
  [a, b] = await Promise.all([A, B].map((c) => until(c.state, (s) => s.phase === 'night', 15000)));
  check('both clients leave the car at home and the run continues into the night',
    [a, b].every((s) => s.depth === 0 && s.phase === 'night' && !s.me.aboard && s.me.status === 'ok'),
    `Ann ${a.phase}, aboard ${a.me.aboard}; Bob ${b.phase}, aboard ${b.me.aboard}`);
}

async function runScenario(escape) {
  const verify = (name, ok, detail) => { if (!escape || escapeOnly || !ok) check(name, ok, detail); };
  const server = launch(['--headless', '--path', project, '-s', 'res://tools/garden_server.gd', '--', `port=${port}`, `seed=${seed}`, 'depth=5'], { env: { GD_JOIN_SECRET: SECRET }, echo: 'server' });
  await until(async () => server.lines.join('\n'), (t) => t.includes('listening on') || server.exited, 30000);
  if (!server.lines.join('\n').includes('listening on')) { console.log('the server did not start'); process.exit(1); }

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
    // Ready-up: both press READY; the run starts for both after the 5 s count.
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
    const line = (await until(async () => server.lines.find((l) => l.includes('garden: run')) ?? '', (l) => l !== '', 10000));
    const m = /stations (.+) keeper ([\d.]+),([\d.]+) hash (\w+)/.exec(line);
    if (!m) throw new Error(`the server announced no stations: "${line}"`);
    const st = m[1].trim().split(' ').map((p) => p.split(',').map(Number));
    const keeper = [Number(m[2]), Number(m[3])];
    const hash = m[4];
    console.log(`  stations ${JSON.stringify(st)}, the Groundskeeper at ${keeper}`);
    verify('the server found five moss cells in a line and a spot for the Groundskeeper', st.length === 5 && keeper[0] > 0, line.replace(/^.*garden:/, ''));

    // ---- 1. The place, the garden, the near light, the ground under a player.
    verify('the run starts on the Arboretum, on both screens', a.place === 'arboretum' && b.place === 'arboretum' && a.depth === 5, `A ${a.place} depth ${a.depth}, B ${b.place}`);
    verify('each client drew the host\'s garden (the same hash), with its lamps and landmarks', a.garden?.hash === hash && b.garden?.hash === hash && a.garden.lamps >= 7 && a.garden.landmarks >= 6,
      `host ${hash}, A ${a.garden?.hash}, B ${b.garden?.hash}; ${a.garden?.lamps} lights, ${a.garden?.landmarks} landmarks`);
    verify('the near light is on in the garden, on each player\'s own screen', a.nearLight?.on === true && b.nearLight?.on === true && a.nearLight.energy > 0.2 && a.nearLight.reach <= 4.01,
      `A ${JSON.stringify(a.nearLight)}, B ${JSON.stringify(b.nearLight)}`);
    verify('the live garden recordings are available to both clients', (a.garden?.sounds ?? []).length >= 20 && JSON.stringify(a.garden.sounds) === JSON.stringify(b.garden?.sounds), `${(a.garden?.sounds ?? []).length} takes`);
    if (!escape) await A.shot('01_pavilion_inside.png');
    // Out through the one doorway, at a creep (a walk on the apron's gravel carries 10 m).
    const plan = JSON.parse(await A.cmd('plan'));
    const doorOut = [(plan.landing.x + 0.5) * 2, (plan.landing.y + 2.5) * 2];
    const lz = (plan.landing.y + 0.5) * 2;
    await approach(A, doorOut[0], lz + 0.3, 0.35);
    await creepTo(A, doorOut[0], doorOut[1] + 2);
    await approach(B, doorOut[0], lz + 0.3, 0.35);
    await creepTo(B, doorOut[0], doorOut[1]);
    a = await A.state();
    b = await B.state();
    verify('on the apron the ground under a player is gravel, as the host\'s garden has it', a.garden.ground === 'gravel' && b.garden.ground === 'gravel', `A ${a.garden.ground}, B ${b.garden.ground}`);
    await A.cmd(`face ${doorOut[0]} ${doorOut[1] - 6}`);
    await sleep(300);
    if (!escape) await A.shot('02_pavilion_and_apron.png');
    // To the stations: Bob to the near end, Ann to the far end.
    await Promise.all([creepTo(B, st[0][0], st[0][1], 120000), creepTo(A, st[4][0], st[4][1], 120000)]);
    a = await A.state();
    b = await B.state();
    verify('both crept to their stations on the worn line: moss underfoot, nobody heard', dist(a, st[4][0], st[4][1]) < 0.4 && dist(b, st[0][0], st[0][1]) < 0.4 && a.garden.ground === 'moss' && b.garden.ground === 'moss' && mode(a) === 'listening' && a.me.status === 'ok' && b.me.status === 'ok',
      `A ${r2(dist(a, st[4][0], st[4][1]))} m off on ${a.garden.ground}, B ${r2(dist(b, st[0][0], st[0][1]))} m off on ${b.garden.ground}; it is ${mode(a)}, ${r2(a.orderly.distance)} m from Ann`);

    if (escape) {
      await escapeGarden(A, B, st, plan, doorOut, lz);
      return;
    }

    // ---- 2. Ann whistles: the tilt, the coming, the lean she lives through.
    await A.cmd(`face ${keeper[0]} ${keeper[1]}`);
    await sleep(200);
    await A.shot('03_listening_in_the_dark.png');
    await A.cmd('emote button');
    const [ta, tb] = await Promise.all([until(A.state, (s) => mode(s) === 'tilt' || mode(s) === 'coming', 3000, 20), until(B.state, (s) => mode(s) === 'tilt' || mode(s) === 'coming', 3000, 20)]);
    check('Ann whistles: both screens receive its hearing reaction', mode(ta) === 'tilt' && (mode(tb) === 'tilt' || mode(tb) === 'coming'), `A ${mode(ta)} (${ta.orderly.pose?.anim}), B ${mode(tb)}`);
    const [ca, cb] = await Promise.all([until(A.state, (s) => mode(s) === 'coming' && s.orderly.pose?.anim === 'walk', 3000, 20), until(B.state, (s) => mode(s) === 'coming' && s.orderly.pose?.anim === 'walk', 3000, 20)]);
    check('then it comes, on both screens', mode(ca) === 'coming' && mode(cb) === 'coming' && ca.orderly.pose?.anim === 'walk' && cb.orderly.pose?.anim === 'walk', `A ${mode(ca)} ${ca.orderly.pose?.anim}, B ${mode(cb)} ${cb.orderly.pose?.anim}`);
    // Seen from about 10 m in the dark.
    await until(A.state, (s) => s.orderly.distance < 10.5 || mode(s) !== 'coming', 3000, 15);
    await A.shot('04_coming.png');
    // And as it reaches the edge of the near light.
    await until(A.state, (s) => s.orderly.distance < 5.2 || mode(s) !== 'coming', 3000, 10);
    await A.shot('04b_coming_at_the_near_light.png');
    // Out of reach along the moss, toward Bob: she stops 2.5 m from where she whistled, just outside its reach.
    await A.cmd(`walkto 0 ${Math.floor(st[2][0] / 2)} ${Math.floor(st[2][1] / 2)} 1.2 creep`);
    const creeping = until(A.state, (s) => dist(s, st[4][0], st[4][1]) >= 2.5 || s.auto !== 'walking', 20000, 20).then(() => A.cmd('stopwalk'));
    const la = await until(A.state, (s) => mode(s) === 'lean' || mode(s) === 'sweep', 8000, 20);
    const lb = await until(B.state, (s) => mode(s) === 'lean' || mode(s) === 'sweep', 3000, 20);
    check('it arrives where the whistle was and leans to Ann, on both screens', mode(la) === 'lean' && mode(lb) === 'lean' && Math.hypot(la.orderly.x - st[4][0], la.orderly.z - st[4][1]) < 0.3,
      `A ${mode(la)}, B ${mode(lb)}; it stands ${r2(Math.hypot(la.orderly.x - st[4][0], la.orderly.z - st[4][1]))} m from the whistle's place, ${r2(la.orderly.distance)} m from Ann`);
    // Out of its reach already (the creep took her past 2 m): she stops and turns to look at it.
    await creeping;
    await A.cmd(`face ${st[4][0]} ${st[4][1]}`);
    await A.cmd('look ' + (Math.atan2(-(st[4][0] - la.me.x), -(st[4][1] - la.me.z)) * 180 / Math.PI) + ' -4');
    await sleep(700);
    await A.shot('05_the_lean.png');
    a = await until(A.state, (s) => mode(s) === 'listening', 8000, 40);
    await creepTo(A, st[2][0], st[2][1], 20000);
    a = await A.state();
    b = await B.state();
    check('Ann crept out of reach on the moss and lived through the lean', a.me.status === 'ok' && other(b, idA)?.status === 'ok' && mode(a) === 'listening' && dist(a, st[4][0], st[4][1]) > 2.0,
      `Ann ${a.me.status}, ${r2(dist(a, st[4][0], st[4][1]))} m from where she whistled; it is ${mode(a)}`);

    // ---- 3 to 6. Bob whistles and stays: down, healed, down, healed, out.
    const drawOffAndHeal = async (n) => {
      // Ann to the far end, a whistle, back two cells; it comes, leans, lets her be. Then to Bob, and F.
      await creepTo(A, st[4][0], st[4][1], 20000);
      await A.cmd('emote button');
      await until(A.state, (s) => mode(s) === 'tilt' || mode(s) === 'coming', 3000, 20);
      await creepTo(A, st[2][0], st[2][1], 20000);
      let s = await until(A.state, (x) => mode(x) === 'listening' && Math.hypot(x.orderly.x - st[4][0], x.orderly.z - st[4][1]) < 0.4, 15000, 40);
      check(`${n}. Ann draws it off Bob with a whistle and lives`, s.me.status === 'ok' && Math.hypot(s.orderly.x - st[4][0], s.orderly.z - st[4][1]) < 0.4, `Ann ${s.me.status}, it is ${mode(s)} ${r2(Math.hypot(s.orderly.x - st[4][0], s.orderly.z - st[4][1]))} m from the far end`);
      await creepTo(A, st[1][0], st[1][1], 20000);
      await approach(A, st[0][0], st[0][1], 1.25);
      await A.cmd('use 1');
      const up = await until(B.state, (x) => x.me.status === 'ok', 8000, 40);
      await A.cmd('use 0');
      s = await until(A.state, (x) => other(x, idB)?.status === 'ok', 3000, 40);
      check(`${n}. Ann heals Bob: he is back on his feet, and it did not hear him get up`, up.me.status === 'ok' && other(s, idB)?.status === 'ok' && mode(s) === 'listening', `Bob ${up.me.status}, it is ${mode(s)}`);
      // Ann out of the way before Bob's next whistle.
      await creepTo(A, st[2][0], st[2][1], 20000);
    };
    for (let n = 1; n <= 3; n++) {
      await B.cmd('emote button');
      const want = n < 3 ? 'down' : 'out';
      b = await until(B.state, (s) => s.me.status === want, 15000, 40);
      a = await until(A.state, (s) => other(s, idB)?.status === want, 4000, 40);
      check(`${n}. Bob whistles and stays where the noise was: taken when the lean ends, and ${want}`, b.me.status === want && other(a, idB)?.status === want,
        `Bob ${b.me.status} on his screen, ${other(a, idB)?.status} on Ann's; Ann ${a.me.status}`);
      if (n === 1) await B.shot('06_down.png');
      if (n < 3) await drawOffAndHeal(n);
    }
    check('Ann, 4 m from each snatch and silent, was never taken', (await A.state()).me.status === 'ok');

    // ---- 7. A sprinter is run down.
    a = await A.state();
    await A.cmd(`face ${st[4][0] + (st[4][0] - st[0][0])} ${st[4][1] + (st[4][1] - st[0][1])}`);
    await A.cmd('move 1 0 1 0');
    const t0 = Date.now();
    a = await until(A.state, (s) => s.me.status !== 'ok', 40000, 40);
    await A.cmd('stopmove');
    check('Ann sprints away: it runs her down', a.me.status === 'down', `Ann ${a.me.status} after ${r2((Date.now() - t0) / 1000)} s`);
  } catch (e) {
    check('the playthrough ran to its end', false, String(e?.stack ?? e));
  } finally {
    for (const c of [A, B]) if (c) await c.close();
    if (!server.exited) {
      const stopped = new Promise((resolve) => server.p.once('exit', resolve));
      server.p.kill();
      await stopped;
    }
  }
}
if (!escapeOnly) await runScenario(false);
await runScenario(true);
const failed = results.filter((r) => !r.ok);
console.log(`${results.length - failed.length} passed, ${failed.length} failed`);
process.exit(failed.length ? 1 : 0);
