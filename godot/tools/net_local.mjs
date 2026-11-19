// The end-to-end check of the network on this PC: the real headless server (server/server.tscn) on
// 127.0.0.1, three headless GDScript players (tests/net_e2e_client.gd) over real WebSockets with
// injected delay (50, 150 and 300 ms each way), a scripted session (out of the car; A watches the
// Orderly and calls the lift, B keeps it behind him, C watches the door; board on the bank half; bank),
// then hostile probes. Asserts from every player's own screen:
//   - the watched Orderly never moved on a screen that was seeing it (consecutive seeing frames);
//   - nobody was caught while their own screen showed the Orderly during the wind-up;
//   - the run banked and every player saw it;
// and that the server refused: a ninth player (4002), an oversized message (4003, or 1009 from the
// WebSocket layer), a flood (4004), a message outside the protocol (4005), and a wrong passphrase
// (4001; after repeated failures the address is refused before any handshake), and a client of another
// build (4007, with the out-of-date reason). Ready-up (server/room.gd): the session's players all ready and
// the run starts after the 5 s count (A's START sent at once does not start it early); a probe checks START
// WITHOUT: refused from a non-host and from the host before 30 s, taken from the host after. And the night's log (server/night_log.gd): JSON lines for the
// joins, the players' heartbeats, error lines and F9 reports, the run and its events, the leaves; never the
// passphrase, never an address.
//   node godot/tools/net_local.mjs [port] [--save-log=FILE]   (port 4450-4459 or 4490-4499, default 4451;
//   --save-log writes everything the server printed to FILE: a fixture for tools/night_logs.mjs)
// Uses the test passphrase `test-passphrase` (local only). Stops every process it starts.
import { spawn } from 'node:child_process';
import { existsSync, writeFileSync } from 'node:fs';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const here = dirname(fileURLToPath(import.meta.url));
const root = resolve(here, '..', '..');
const project = join(root, 'godot');
const godot = process.env.GODOT || join(root, 'tools', 'godot', 'Godot_v4.7.2-stable_win64_console.exe');
if (!existsSync(godot)) throw new Error(`Godot not found at ${godot}`);
const positional = process.argv.slice(2).filter((a) => !a.startsWith('--'));
const saveLog = process.argv.slice(2).find((a) => a.startsWith('--save-log='))?.slice('--save-log='.length);
const port = Number(positional[0] || 4451);
if (!((port >= 4450 && port <= 4459) || (port >= 4490 && port <= 4499))) throw new Error('port must be 4450-4459 or 4490-4499');
/** The build id the server and every client say (a server takes only its own: net/build_info.gd). */
const BUILD = 'e2e-build';
const SECRET = 'test-passphrase';
const url = `ws://127.0.0.1:${port}`;
const procs = new Set();

function run(args, opts = {}) {
  const p = spawn(godot, ['--headless', '--path', project, ...args], { cwd: root, env: { ...process.env, ...(opts.env || {}) }, stdio: ['ignore', 'pipe', 'pipe'] });
  procs.add(p);
  let out = '';
  p.stdout.on('data', (d) => {
    out += d;
    if (opts.echo) process.stdout.write(String(d).split('\n').filter((l) => l.trim()).map((l) => `  [${opts.echo}] ${l}\n`).join(''));
  });
  p.stderr.on('data', (d) => (out += d));
  const done = new Promise((res) => p.on('exit', (code) => { procs.delete(p); res({ code, out }); }));
  const timer = setTimeout(() => p.kill(), (opts.timeout || 240) * 1000);
  done.then(() => clearTimeout(timer));
  return { p, done, get out() { return out; } };
}

function result(out) {
  const line = out.split(/\r?\n/).find((l) => l.startsWith('RESULT '));
  return line ? JSON.parse(line.slice(7)) : null;
}

const checks = [];
function check(ok, what) {
  checks.push([ok, what]);
  console.log(`${ok ? 'PASS' : 'FAIL'}  ${what}`);
}

const cleanup = () => { for (const p of procs) p.kill(); };
process.on('exit', cleanup);
process.on('SIGINT', () => { cleanup(); process.exit(1); });

const server = run(['res://server/server.tscn', '--', 'server', `port=${port}`, 'bind=127.0.0.1', 'seed=e2e-1', 'stats=10', 'quota=0', 'watchers=0', 'orientation_campaign=0', `build=${BUILD}`], { env: { GD_JOIN_SECRET: SECRET }, echo: 'server', timeout: 600 });
await new Promise((res) => {
  const t = setInterval(() => { if (server.out.includes('listening on')) { clearInterval(t); res(); } }, 100);
});

console.log('session: A (50 ms, watches, calls), B (150 ms, looks away), C (300 ms, watches the door)');
const t0 = Date.now();
const players = [
  ['A', 0.05, 'watch', '1'],
  ['B', 0.15, 'away', '0'],
  ['C', 0.3, 'door', '0'],
].map(([name, delay, behave, starts]) =>
  run(['--script', 'res://tests/net_e2e_client.gd', '--', `url=${url}`, `secret=${SECRET}`, 'role=player', `name=${name}`, `delay=${delay}`, `behave=${behave}`, 'expect=3', `starts=${starts}`, 'timeout=200', `build=${BUILD}`], { timeout: 230 }),
);
const outs = await Promise.all(players.map((p) => p.done));
const results = outs.map((o) => result(o.out));
console.log(`session over in ${((Date.now() - t0) / 1000).toFixed(1)} s`);
results.forEach((r, i) => console.log(`  ${'ABC'[i]}: ${JSON.stringify(r)}`));
check(results.every((r) => r && !r.timeout), 'every player finished the session');
check(results.every((r) => r && r.banked), 'the run banked, and every player saw the bank');
check(results.every((r) => r && r.watchedMoves === 0), `the watched Orderly never moved on a screen that saw it (pairs of seeing frames: ${results.map((r) => r?.watchedPairs).join(', ')})`);
check(results.some((r) => r && r.watchedPairs > 30), 'not vacuous: a screen watched the Orderly for more than half a second');
check(results.every((r) => r && r.caughtWhileSeen === 0), `nobody was caught while their own screen showed the Orderly (catches: ${results.map((r) => r?.catches).join(', ')})`);
// Ready-up (server/room.gd): all three ready once the room is full, A also sends START at once. START
// WITHOUT is the host's alone, 30 s after readying, so the run waits for the 5 s count on everyone's ready.
const waits = results.map((r) => r?.countWait);
check(waits.every((w) => typeof w === 'number' && w >= 4.5 && w < 12), `the run starts after the 5 s count on everyone's ready, not on A's early START (ready to run on each screen: ${waits.map((w) => w?.toFixed(1)).join(', ')} s)`);

const probe = async (kind, secs = 60) => result((await run(['--script', 'res://tests/net_e2e_client.gd', '--', `url=${url}`, `secret=${SECRET}`, 'role=probe', `kind=${kind}`, `timeout=${secs}`, `build=${BUILD}`], { timeout: secs + 30 }).done).out);
const sw = await probe('startwithout', 75);
check(sw && sw.hostIsFirst && sw.notHostStarted === false && sw.earlyStarted === false, `START from a player who is not the host, and the host's before 30 s, start nothing (${JSON.stringify(sw)})`);
check(sw && sw.started && sw.after >= 30 && sw.hostInRun && !sw.readerInRun, `the host's START WITHOUT after 30 s starts the run with the ready host, and the player still reading stays out (after ${sw?.after?.toFixed(1)} s)`);
const ninth = await probe('ninth');
check(ninth && ninth.admitted === 8 && ninth.code === 4002, `a ninth player is refused (8 admitted, the ninth closed with ${ninth?.code})`);
const big = await probe('oversize');
check(big && big.sent && (big.code === 4003 || big.code === 1009), `an oversized message closes the connection (code ${big?.code})`);
const flood = await probe('flood');
check(flood && flood.sent && flood.code === 4004, `a flood closes the connection (code ${flood?.code})`);
const garbage = await probe('garbage');
check(garbage && garbage.code === 4005, `a message outside the protocol closes the connection (code ${garbage?.code})`);
// Before the wrong passphrases (which leave this address refused for a while).
const oldBuild = await probe('oldbuild');
check(oldBuild && oldBuild.code === 4007 && /out of date/.test(oldBuild.reason ?? ''), `a client of another build is refused with the out-of-date reason (code ${oldBuild?.code}, "${oldBuild?.reason}")`);
const wrong = await probe('wrongpass');
check(wrong && wrong.codes[0] === 4001 && wrong.codes[1] === 4001 && wrong.codes[3] !== 4001, `a wrong passphrase is refused (codes ${JSON.stringify(wrong?.codes)}: 4001, then refused before the handshake)`);

server.p.kill();
await server.done;
// The night's log: one JSON object per line, among the server's plain lines.
const out = server.out;
const night = out.split(/\r?\n/).filter((l) => l.startsWith('{"gd":1')).map((l) => JSON.parse(l));
const evs = (ev) => night.filter((d) => d.ev === ev);
const names = ['A', 'B', 'C'];
check(!out.includes(SECRET), `the passphrase is in no line the server printed (${out.split(/\r?\n/).length} lines)`);
check(!out.replace(/listening on 127\.0\.0\.1:\d+/g, '').includes('127.0.0.1'), 'no address is written down (only salted tags)');
check(names.every((n) => evs('join').some((d) => d.name === n && d.build === BUILD)), `the log has every join, with its build (${evs('join').length} joins)`);
check(names.every((n) => ['hb', 'clog', 'report'].every((ev) => evs(ev).some((d) => d.name === n))), "the log has every player's heartbeat, error line and F9 report");
check(evs('run').length >= 1 && evs('game').some((d) => d.type === 'banked'), `the log has the run and its events (${[...new Set(evs('game').map((d) => d.type))].join(', ')})`);
check(evs('leave').length >= 3 && evs('tick').length >= 1, `the log has the leaves (${evs('leave').length}) and the tick cost (${evs('tick').length} lines)`);
if (saveLog) {
  writeFileSync(saveLog, out);
  console.log(`the server's output is saved in ${saveLog}`);
}
const bad = checks.filter(([ok]) => !ok).length;
console.log(`${checks.length - bad} passed, ${bad} failed`);
process.exit(bad ? 1 : 0);
