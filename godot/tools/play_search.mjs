// Searching on screen (docs/floors/findables-and-day.md FD10), checked with two real game windows over the real
// network: a test server (tools/down_server.gd: the home server's room as in the game, findables on, its resident
// parked) on 127.0.0.1, and two game windows (the engine in GODOT on this project, small, `auto=1`, a test channel
// each) that join through the start screen's own Join, Ann and Bob, on floor 1 (the Clinic).
//   Ann walks to three pieces and searches them: one holding a poem (careful), one holding a page (careful), one
//   holding credits (rushed). At each: the piece's own prompt and the rushed search's line; holding F, the bar
//   fills with the host's times; the result line is the host's; a poem and a page open in the reader. The prompt
//   is gone from an opened piece. Bob then sees the same three pieces drawn open as the host has them, walks to the
//   poem's piece, gets "F  READ NOTE" and reads the same words. The lobby sheet on both screens is the host's.
// Pictures in export/shots/search/: the prompt, the bar part filled, a result line, a poem open, a page open, an
// opened drawer from Bob's view, and the lobby sheet. Prints `N passed, M failed`; exit code 1 on any failure.
//   node godot/tools/play_search.mjs [--port=4464] [--seed=search-1] [--headless=1]
// Ports 4460-4479 only: the server on port, the windows' test channels on port+1 and port+2, the server's control
// line on port+3. With windows, start .local/guard-mouse.ps1 beside it. Every process it starts is stopped.
import { spawn } from 'node:child_process';
import { existsSync, mkdirSync, writeFileSync } from 'node:fs';
import { connect } from 'node:net';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const here = dirname(fileURLToPath(import.meta.url));
const project = resolve(here, '..');
const root = resolve(project, '..');
const arg = (k, d) => (process.argv.find((a) => a.startsWith(`--${k}=`)) ?? `--${k}=${d}`).split('=')[1];
const port = Number(arg('port', 4464));
const seed = arg('seed', 'search-1');
const headless = arg('headless', '0') === '1';
const godot = process.env.GODOT || join(root, 'tools', 'godot', 'Godot_v4.7.2-stable_win64_console.exe');
if (!existsSync(godot)) throw new Error(`no engine at ${godot}: set GODOT`);
const testPorts = [port + 1, port + 2];
const ctlPort = port + 3;
for (const p of [port, ...testPorts, ctlPort]) if (!(p >= 4460 && p <= 4479)) throw new Error(`port ${p} is outside 4460-4479`);
const shots = resolve(project, 'export', 'shots', 'search');
mkdirSync(shots, { recursive: true });
const SECRET = 'test-passphrase';
const url = `ws://127.0.0.1:${port}`;
const RUSH = 'SHIFT+F  RIFLE IT. FAST. LOUD. HALF THE CREDITS.';

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
  const heard = async (name) => JSON.parse(await cmd('sfx state')).played.filter((cue) => cue.name === name).length;
  const shot = async (name) => { if (headless) return; const r = await cmd(`shot ${join(shots, name)}`); console.log(`  shot ${join(shots, name)} (${label}) ${r}`); };
  const close = async () => { try { sock.write('quit\n'); } catch { /* closed */ } await sleep(600); if (!g.exited) g.p.kill(); sock.destroy(); };
  return { label, g, cmd, state, heard, shot, close };
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

/** Moves a player to within `near` metres of (x, z) by facing it and stepping. */
async function approach(c, x, z, near, ms = 10000) {
  const end = Date.now() + ms;
  let s = await c.state();
  while (dist(s, x, z) > near && Date.now() < end) {
    await c.cmd(`face ${x} ${z}`);
    await c.cmd(dist(s, x, z) < 0.6 ? 'move 1 0 0 1' : 'move 1 0 0 0');
    await sleep(dist(s, x, z) < 0.6 ? 30 : 70);
    await c.cmd('stopmove');
    s = await c.state();
  }
  await c.cmd('stopmove');
  await sleep(150);
  return c.state();
}

/** Walks a player to where they stand to search piece `p`, and faces it. */
async function goTo(c, p) {
  const [L, cx, cy] = p.cell;
  await c.cmd(`walkto ${L} ${cx} ${cy} 3`);
  await until(c.state, (s) => s.auto !== 'walking', 60000, 150);
  await approach(c, p.stand[0], p.stand[1], 0.1);
  await c.cmd(`face ${p.x} ${p.z} 0.6`);
  await sleep(300);
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
  // Ready-up (server/room.gd, FD5/FD6): both press READY on the controls card; the run starts after the count.
  await A.cmd('ready');
  await B.cmd('ready');
  let a = await until(A.state, inGame, 30000);
  await until(B.state, inGame, 30000);
  await A.cmd('click');
  await B.cmd('click');
  a = await until(A.state, (s) => s.phase === 'unloading' && s.client.doors > 0.95 && s.find?.host, 30000);
  const idA = a.me.id;
  const fin = await host('finds');
  check('the run has findables on (the host\'s find block on both screens, nothing open)', fin.ok && a.find?.host?.opened?.length === 0 && a.depth === 1,
    `finds ${fin.ok}, block ${JSON.stringify(a.find?.host)?.slice(0, 120)}, place ${a.place}`);
  const pieces = JSON.parse(await A.cmd('pieces'));
  const what = (p) => fin.contents[String(p.id)]?.what;
  const pick = (w, not = []) => pieces.filter((p) => what(p) === w && !not.includes(p.id))
    .sort((p, q) => fin.contents[String(p.id)].steps - fin.contents[String(q.id)].steps)[0];
  const poem = pick('note');
  const page = pick('page');
  const cred = pieces.filter((p) => what(p) === 'credits' && fin.contents[String(p.id)].credits >= 2).sort((p, q) => fin.contents[String(p.id)].steps - fin.contents[String(q.id)].steps)[0];
  if (!poem || !page || !cred) throw new Error(`no poem, page or credits piece: ${JSON.stringify({ poem, page, cred })}`);
  console.log(`  pieces: poem ${poem.id} (${poem.kind}), page ${page.id} (${page.kind}), credits ${cred.id} (${cred.kind}); sheet "${fin.sheet}"`);

  // Out of the car.
  for (const c of [A, B]) await c.cmd('move 1 0 0 0');
  await sleep(1600);
  for (const c of [A, B]) await c.cmd('stopmove');
  // The lobby sheet, on both screens, the host's.
  a = await A.state();
  let b = await B.state();
  check('the lobby sheet is the host\'s, on both screens', a.find.view.sheet === fin.sheet && b.find.view.sheet === fin.sheet,
    `Ann "${a.find.view.sheet}", Bob "${b.find.view.sheet}", host "${fin.sheet}"`);
  const sa = a.find.view.sheetAt;
  if (sa?.length === 3) {
    // A step back from the sheet, looking at it.
    await A.cmd(`face ${sa[0]} ${sa[2]} ${sa[1]}`);
    await sleep(400);
    await A.shot('7-sheet.png');
  }

  /** One search by Ann at piece `p` (`fast` the rushed one); returns the state when it ended. */
  async function search(p, fast, tag) {
    let s = await goTo(A, p);
    check(`${tag}: the piece's prompt and the rushed search's line`, s.find.view.piece === p.id && s.find.hudPrompt === p.prompt && s.find.reader.prompt2 === RUSH,
      `piece ${s.find.view.piece} (want ${p.id}), prompt "${s.find.hudPrompt}", second "${s.find.reader.prompt2}"`);
    if (tag === 'poem') await A.shot('1-prompt.png');
    const opening = {drawers_low: 'search_drawer', side_table: 'search_locker'}[p.kind];
    const before = opening ? await A.heard(opening) : 0;
    await A.cmd(`search ${fast ? 'fast' : 'careful'}`);
    s = await until(A.state, (x) => x.find.view.mine === p.id && x.find.fill > 0.3, 3000, 30);
    const row = (s.find.host.searching ?? []).find((r) => r.playerId === idA);
    const want = row ? Math.min(1, Math.max(0, (s.hostNow - row.from) / (row.done - row.from))) : -1;
    check(`${tag}: the bar fills with the host's times`, row && s.find.fill > 0 && s.find.fill < 1 && Math.abs(s.find.fill - want) < 0.15 && Math.abs((row.done - row.from) - (fast ? 0.8 : 2.5)) < 1e-6,
      `fill ${s.find.fill.toFixed(2)}, host ${want.toFixed(2)}, span ${row ? (row.done - row.from).toFixed(2) : '-'}`);
    if (tag === 'poem') await A.shot('2-bar.png');
    s = await until(A.state, (x) => x.find.view.lastDone?.piece === p.id, 6000, 30);
    await A.cmd('search off');
    if (opening && !fast) {
      check(`${tag}: the careful opening plays once for Ann`, await A.heard(opening) === before + 1 && await B.heard(opening) === 0);
    }
    return s;
  }

  // 1. The poem.
  a = await search(poem, false, 'poem');
  const pn = fin.contents[String(poem.id)].note;
  check('poem: the result is the host\'s and the poem opens in the reader', a.find.view.lastDone?.note === pn && a.find.reader.open === pn && a.find.reader.lines.length >= 4,
    `done ${JSON.stringify(a.find.view.lastDone)}, reader ${a.find.reader.open}: ${JSON.stringify(a.find.reader.lines)}`);
  check('the paper unfolds once for Ann', await A.heard('search_paper') === 1 && await B.heard('search_paper') === 0);
  await sleep(200);
  await A.shot('4-poem-open.png');
  const poemLines = a.find.reader.lines;
  await A.cmd('reader close');
  a = await A.state();
  check('poem: once opened its search prompt is gone (the note can be read again)', a.find.view.piece !== poem.id && a.find.hudPrompt !== poem.prompt && a.find.view.read === pn,
    `piece ${a.find.view.piece}, prompt "${a.find.hudPrompt}", read "${a.find.view.read}"`);

  // 2. The page.
  a = await search(page, false, 'page');
  const gn = fin.contents[String(page.id)].note;
  check('page: somebody\'s page opens in the reader', a.find.view.lastDone?.what === 'page' && a.find.reader.open === gn && a.find.reader.lines.length >= 2,
    `done ${JSON.stringify(a.find.view.lastDone)}, reader ${a.find.reader.open}`);
  await sleep(200);
  await A.shot('5-page-open.png');
  await A.cmd('reader close');

  // 3. The credits, rushed.
  a = await search(cred, true, 'credits');
  const full = fin.contents[String(cred.id)].credits;
  check('credits: a rushed search finds half, rounded down, and says so', a.find.view.lastDone?.credits === Math.floor(full / 2) && a.find.view.result === `CREDITS +${Math.floor(full / 2)}`,
    `found ${a.find.view.lastDone?.credits} of ${full}, line "${a.find.view.result}"`);
  await A.shot('3-result.png');

  // Both screens: the same three open, as the host has them.
  const fin2 = await host('finds');
  const hostOpen = fin2.opened.map((o) => o.piece).sort((x, y) => x - y);
  a = await until(A.state, (s) => JSON.stringify(s.find.view.open) === JSON.stringify(hostOpen), 3000);
  b = await until(B.state, (s) => JSON.stringify(s.find.view.open) === JSON.stringify(hostOpen), 3000);
  check('both screens draw the same three pieces open, as the host has them', hostOpen.length === 3 && JSON.stringify(a.find.view.open) === JSON.stringify(hostOpen)
    && JSON.stringify(b.find.view.open) === JSON.stringify(hostOpen), `host ${JSON.stringify(hostOpen)}, Ann ${JSON.stringify(a.find.view.open)}, Bob ${JSON.stringify(b.find.view.open)}`);
  check('the rushed search plays one world cue on each client', await A.heard('search_rifle') === 1 && await B.heard('search_rifle') === 1);
  // Bob reads the same note where it was found.
  b = await goTo(B, poem);
  check('Bob at the opened piece: F  READ NOTE, the same note', b.find.hudPrompt === 'F  READ NOTE' && b.find.view.read === pn, `prompt "${b.find.hudPrompt}", read "${b.find.view.read}"`);
  await B.shot('6-opened-from-bob.png');
  const rb = JSON.parse(await B.cmd(`reader read ${b.find.view.read}`));
  check('Bob reads the same words as Ann', JSON.stringify(rb.lines) === JSON.stringify(poemLines), `${JSON.stringify(rb.lines).slice(0, 80)}`);
  await B.cmd('reader close');
  // The sheet, from the landing.
  b = await B.state();
  const errors = [...A.g.lines, ...B.g.lines, ...server.lines].filter((l) => /SCRIPT ERROR|ERROR: .*\.gd/.test(l));
  check('no script errors', errors.length === 0, errors.slice(0, 3).join(' | '));
  writeFileSync(join(shots, 'play_search.json'), JSON.stringify({ results, seed }, null, 2));
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
