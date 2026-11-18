// Proves the EXPORTED builds, not the project folder. On 18 Nov the Linux server preset left data/* out of
// the build: on the real server the rules could not read the Temp's sticky notes, the report's awards or the
// upgrades, and nothing caught it, because every network test runs the server from the project folder,
// where the files exist. This check runs after `npm run godot:export` and `node godot/tools/godot.mjs export
// server` (tools/hotfix.mjs step `exported`):
//   (a) copies godot/export/windows/GoingDown.exe (its pack is embedded; a GoingDown.pck beside it is copied
//       too) ALONE into a new temp folder and starts it there as the dedicated server (`--headless -- server`,
//       the same server/server.gd the Linux build runs), with a test passphrase (GD_TEST_PASSPHRASE from the
//       environment, or a random one; never printed), on 127.0.0.1 port 4490-4499, every run starting on the
//       Annex (the test argument depth=3) with the game's own rules otherwise. Nothing of the project folder
//       is beside it, and it is given no --path, so it can read only what is inside the exe;
//   (b) waits for its `data: N files read` line (server/data_check.gd: every data file the rules read) and
//       `listening on`;
//   (c) joins it with the test player (tests/net_e2e_client.gd, run from the project as tools/net_local.mjs
//       runs it: the SERVER is what is proved) and plays a short session: the run starts, the player is
//       placed and walks out of the car;
//   (d) on the Annex the server must post at least one of the Temp's sticky notes (the arrival's "lobby"
//       note, from data/annex_notes.json) that reaches the player, with no "did not parse"/"did not load"
//       and no script error in the server's output;
//   (f) reads the file table of the Linux server's pack (the PCK embedded at the end of
//       godot/export/server/GoingDownServer.x86_64; the Linux binary cannot run here) and checks every data
//       file of server/data_check.gd FILES is inside; the same for the Windows exe's pack (and that the table
//       reader is not vacuous: project.binary and server/server.gd are found in both);
//   (e) prints `N passed, M failed`; exit code 1 on any failure.
//   node godot/tools/exported_server_check.mjs [--port=4492] [--keep]   (--keep leaves the temp folder)
import { spawn } from 'node:child_process';
import { randomBytes } from 'node:crypto';
import { copyFileSync, existsSync, mkdtempSync, openSync, readFileSync, readSync, closeSync, fstatSync, readdirSync, rmSync, statSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const here = dirname(fileURLToPath(import.meta.url));
const root = resolve(here, '..', '..');
const project = join(root, 'godot');
const arg = (k, d) => (process.argv.find((a) => a.startsWith(`--${k}=`)) ?? `--${k}=${d}`).split('=')[1];
const port = Number(arg('port', 4492));
const keep = process.argv.includes('--keep');
if (!(port >= 4490 && port <= 4499)) throw new Error(`port ${port} is outside 4490-4499`);
const godot = process.env.GODOT || join(root, 'tools', 'godot', 'Godot_v4.7.2-stable_win64_console.exe');
const exeSrc = join(project, 'export', 'windows', 'GoingDown.exe');
const linuxServer = join(project, 'export', 'server', 'GoingDownServer.x86_64');
const SECRET = process.env.GD_TEST_PASSPHRASE || `test-${randomBytes(9).toString('hex')}`;
const ANNEX = 3;

const results = [];
const check = (name, ok, detail = '') => { results.push({ name, ok }); console.log(`${ok ? 'PASS' : 'FAIL'} ${name}${detail ? ` (${detail})` : ''}`); return ok; };
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const procs = new Set();
const cleanup = () => { for (const p of procs) { try { p.kill(); } catch { /* gone */ } } };
process.on('exit', cleanup);
process.on('SIGINT', () => { cleanup(); process.exit(1); });

/** The data files the rules read (server/data_check.gd FILES), as pack paths without res://. */
function registry() {
  const src = readFileSync(join(project, 'server', 'data_check.gd'), 'utf8');
  const block = /const FILES: Array\[String\] = \[([\s\S]*?)\]/.exec(src);
  if (!block) throw new Error('server/data_check.gd has no FILES list');
  return [...block[1].matchAll(/"res:\/\/(data\/[^"]+\.json)"/g)].map((m) => m[1]);
}

/**
 * The file table of a Godot pack (PCK) embedded at the end of an executable (or a .pck file): the paths
 * inside, without res://. Format (core/io/file_access_pack.cpp): an embedded pack ends with its size (u64)
 * and the magic "GDPC"; the pack starts with "GDPC", the format version (2 or 3), the engine's major, minor
 * and patch, flags, the file base (u64); versions 3 and 4 (Godot 4.7.2 writes 4) then have the directory's
 * offset (u64, from the pack's start), version 2 sixteen reserved u32 and the directory right after. The directory: a file count (u32),
 * then per file the path's length (u32), the path (padded), offset (u64), size (u64), md5 (16 bytes) and
 * flags (u32). An encrypted directory cannot be read (flag 1).
 */
function packFiles(file) {
  const fd = openSync(file, 'r');
  try {
    const size = fstatSync(fd).size;
    const at = (pos, n) => { const b = Buffer.alloc(n); readSync(fd, b, 0, n, pos); return b; };
    const MAGIC = 0x43504447; // "GDPC" little-endian
    let start = 0;
    if (at(0, 4).readUInt32LE(0) !== MAGIC) {
      if (at(size - 4, 4).readUInt32LE(0) !== MAGIC) throw new Error('no pack found (no GDPC at its end)');
      const packSize = Number(at(size - 12, 8).readBigUInt64LE(0));
      start = size - 12 - packSize;
      if (start < 0 || at(start, 4).readUInt32LE(0) !== MAGIC) throw new Error('the pack trailer does not point at a pack');
    }
    const h = at(start, 4 + 4 * 5 + 8 + 8);
    const version = h.readUInt32LE(4);
    const engine = `${h.readUInt32LE(8)}.${h.readUInt32LE(12)}.${h.readUInt32LE(16)}`;
    const flags = h.readUInt32LE(20);
    if (flags & 1) throw new Error('the pack directory is encrypted');
    let dir;
    if (version === 3 || version === 4) dir = start + Number(h.readBigUInt64LE(32));
    else if (version === 2) dir = start + 4 + 4 * 5 + 8 + 16 * 4;
    else throw new Error(`pack format ${version} is not one this reader knows (2, 3 or 4)`);
    const count = at(dir, 4).readUInt32LE(0);
    if (count > 200000) throw new Error(`implausible file count ${count}`);
    let pos = dir + 4;
    const files = [];
    for (let i = 0; i < count; i++) {
      const len = at(pos, 4).readUInt32LE(0);
      if (len > 4096) throw new Error(`implausible path length ${len} at entry ${i}`);
      const path = at(pos + 4, len).toString('utf8').replace(/\0+$/, '');
      files.push(path.replace(/^res:\/\//, ''));
      pos += 4 + len + 8 + 8 + 16 + 4;
    }
    return { version, engine, files };
  } finally {
    closeSync(fd);
  }
}

const want = registry();
console.log(`data files the rules read (server/data_check.gd): ${want.join(', ')}`);
check('the data check lists at least the three files of 18 Nov', ['data/annex_notes.json', 'data/report_awards.json', 'data/upgrades.json'].every((f) => want.includes(f)), want.join(', '));

// ---- (f) What the exported packs hold.
for (const [label, file] of [['the Linux server', linuxServer], ['the Windows game', exeSrc]]) {
  if (!check(`${label} build exists (${file.slice(root.length + 1).replaceAll('\\', '/')})`, existsSync(file), existsSync(file) ? `built ${statSync(file).mtime.toISOString()}` : 'export it first')) continue;
  let pack;
  try {
    pack = packFiles(file);
  } catch (e) {
    check(`${label}'s pack can be read`, false, e.message);
    continue;
  }
  const has = (f) => pack.files.includes(f);
  check(`${label}'s pack can be read, and the reader is not vacuous (project.binary and server/server.gd are in it)`, has('project.binary') && pack.files.some((f) => f.startsWith('server/server.gd')),
    `pack format ${pack.version}, Godot ${pack.engine}, ${pack.files.length} files`);
  const missing = want.filter((f) => !has(f));
  check(`${label}'s pack holds every data file the rules read`, missing.length === 0, missing.length ? `MISSING ${missing.join(', ')}` : `${want.length} of ${want.length}`);
}

// ---- (a)-(d) The Windows exe as the server, from a folder holding only the exe.
if (!existsSync(exeSrc)) {
  check('the exported Windows server runs', false, `no ${exeSrc}: npm run godot:export first`);
} else {
  const dir = mkdtempSync(join(tmpdir(), 'gd-exported-'));
  const exe = join(dir, 'GoingDown.exe');
  copyFileSync(exeSrc, exe);
  const pck = join(dirname(exeSrc), 'GoingDown.pck');
  if (existsSync(pck)) copyFileSync(pck, join(dir, 'GoingDown.pck'));
  const alone = readdirSync(dir);
  check('the server runs from a temp folder holding only the exported exe (and its pack, if separate)', alone.every((f) => /^GoingDown\.(exe|pck)$/.test(f)), `${dir}: ${alone.join(', ')}`);
  const env = { ...process.env, GD_JOIN_SECRET: SECRET };
  delete env.GD_JOIN_SECRET_FILE;
  const server = spawn(exe, ['--headless', '--', 'server', `port=${port}`, 'bind=127.0.0.1', 'seed=exported-1', 'stats=10', `depth=${ANNEX}`], { cwd: dir, env, stdio: ['ignore', 'pipe', 'pipe'] });
  procs.add(server);
  let out = '';
  let exited = null;
  const echo = (d) => { out += d; for (const l of String(d).split(/\r?\n/)) if (l.trim()) console.log(`  [server] ${l}`); };
  server.stdout.on('data', echo);
  server.stderr.on('data', echo);
  server.on('exit', (code) => { exited = code; procs.delete(server); });
  const t0 = Date.now();
  while (!out.includes('listening on') && exited === null && Date.now() - t0 < 30000) await sleep(100);
  const dataLine = /data: (\d+) files read/.exec(out);
  check('the exported server read its data before listening (`data: N files read`, N = the list)', dataLine !== null && Number(dataLine[1]) === want.length && out.indexOf('data: ') < out.indexOf('listening on'),
    dataLine ? dataLine[0] : (/not started:[^\r\n]*/.exec(out)?.[0] ?? `no data line (exit ${exited})`));
  const listening = /listening on [^\r\n]*build (\S+)/.exec(out);
  check('the exported server is listening', listening !== null && exited === null, listening ? listening[0] : `exit ${exited}`);
  if (listening && exited === null) {
    const build = listening[1];
    // The test player, run from the project (as tools/net_local.mjs runs it), saying the server's build id.
    const player = spawn(godot, ['--headless', '--path', project, '--script', 'res://tests/net_e2e_client.gd', '--', `url=ws://127.0.0.1:${port}`, `secret=${SECRET}`, 'role=player', 'name=X',
      'behave=watch', 'expect=1', 'starts=1', 'timeout=120', 'stop_after_note=8', `build=${build}`], { cwd: root, stdio: ['ignore', 'pipe', 'pipe'] });
    procs.add(player);
    let pout = '';
    player.stdout.on('data', (d) => (pout += d));
    player.stderr.on('data', (d) => (pout += d));
    await new Promise((res) => { player.on('exit', res); setTimeout(() => { player.kill(); res(); }, 150000); });
    procs.delete(player);
    const line = pout.split(/\r?\n/).find((l) => l.startsWith('RESULT '));
    const r = line ? JSON.parse(line.slice(7)) : null;
    console.log(`  player: ${line ? JSON.stringify(r) : pout.split(/\r?\n/).slice(-6).join(' | ')}`);
    check('a player joins the exported server and plays: the run starts, they are placed and see frames', r !== null && !r.closed && r.placements > 0 && r.frames > 100, r ? `placements ${r.placements}, frames ${r.frames}, closed ${r.closed ?? 'no'}` : 'no RESULT line');
    check(`the run started on the Annex (depth ${ANNEX})`, r?.depth === ANNEX && /every run starts at depth 3/.test(out), `the player's depth ${r?.depth}`);
    check("the exported server posted the Temp's sticky notes (data/annex_notes.json) and the player got them", (r?.notes ?? 0) >= 1, `${r?.notes ?? 0} note(s)${r?.noteText ? `, first: "${r.noteText}"` : ''}`);
    await sleep(500);
  }
  server.kill();
  await sleep(500);
  const bad = out.split(/\r?\n/).filter((l) => /did not parse|did not load|SCRIPT ERROR|"ev":"serr"|ERROR:/.test(l));
  check('the server printed no "did not parse", "did not load" or script error', bad.length === 0, bad.length ? bad.slice(0, 3).join(' | ') : `${out.split(/\r?\n/).length} lines`);
  check('the passphrase is in no line the server printed', !out.includes(SECRET));
  if (keep) console.log(`  kept ${dir}`);
  else {
    try { rmSync(dir, { recursive: true, force: true }); } catch { /* the exe may linger a moment */ }
  }
}

const failed = results.filter((r) => !r.ok).length;
console.log(`${results.length - failed} passed, ${failed} failed`);
process.exit(failed ? 1 : 0);
