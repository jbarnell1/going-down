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
// (4001; after repeated failures the address is refused before any handshake).
//   node godot/tools/net_local.mjs [port]      (port 4450-4459, default 4451)
// Uses the test passphrase `test-passphrase` (local only). Stops every process it starts.
import { spawn } from 'node:child_process';
import { existsSync } from 'node:fs';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const here = dirname(fileURLToPath(import.meta.url));
const root = resolve(here, '..', '..');
const project = join(root, 'godot');
const godot = process.env.GODOT || join(root, 'tools', 'godot', 'Godot_v4.7.2-stable_win64_console.exe');
if (!existsSync(godot)) throw new Error(`Godot not found at ${godot}`);
const port = Number(process.argv[2] || 4451);
if (!(port >= 4450 && port <= 4459)) throw new Error('port must be 4450-4459');
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

const server = run(['res://server/server.tscn', '--', 'server', `port=${port}`, 'bind=127.0.0.1', 'seed=e2e-1', 'stats=10', 'quota=0'], { env: { GD_JOIN_SECRET: SECRET }, echo: 'server', timeout: 600 });
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
  run(['--script', 'res://tests/net_e2e_client.gd', '--', `url=${url}`, `secret=${SECRET}`, 'role=player', `name=${name}`, `delay=${delay}`, `behave=${behave}`, 'expect=3', `starts=${starts}`, 'timeout=200'], { timeout: 230 }),
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

const probe = async (kind) => result((await run(['--script', 'res://tests/net_e2e_client.gd', '--', `url=${url}`, `secret=${SECRET}`, 'role=probe', `kind=${kind}`, 'timeout=60'], { timeout: 90 }).done).out);
const ninth = await probe('ninth');
check(ninth && ninth.admitted === 8 && ninth.code === 4002, `a ninth player is refused (8 admitted, the ninth closed with ${ninth?.code})`);
const big = await probe('oversize');
check(big && big.sent && (big.code === 4003 || big.code === 1009), `an oversized message closes the connection (code ${big?.code})`);
const flood = await probe('flood');
check(flood && flood.sent && flood.code === 4004, `a flood closes the connection (code ${flood?.code})`);
const garbage = await probe('garbage');
check(garbage && garbage.code === 4005, `a message outside the protocol closes the connection (code ${garbage?.code})`);
const wrong = await probe('wrongpass');
check(wrong && wrong.codes[0] === 4001 && wrong.codes[1] === 4001 && wrong.codes[3] !== 4001, `a wrong passphrase is refused (codes ${JSON.stringify(wrong?.codes)}: 4001, then refused before the handshake)`);

server.p.kill();
await server.done;
const bad = checks.filter(([ok]) => !ok).length;
console.log(`${checks.length - bad} passed, ${bad} failed`);
process.exit(bad ? 1 : 0);
