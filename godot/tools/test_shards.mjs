// The test run of tools/godot.mjs (npm run godot:test): one engine, or the test files split over several
// engines side by side (SH1). Called only by godot.mjs; see godot/README.md, "Running the tests in parallel".
//
//   node godot/tools/godot.mjs test --quick                    one engine, every file in order (as before)
//   node godot/tools/godot.mjs test --quick --shards=4         four engines side by side
//   node godot/tools/godot.mjs test --quick --shards=auto      the default for this machine (GD_TEST_SHARDS wins)
//   ... --port-base=4920        the first port of this run's ports (else a free block is picked and printed)
//   ... --record-timings        afterwards, write each file's seconds to godot/tests/timings.json
//
// A sharded run has three phases. FIRST (the files that say whether anything loads at all) runs alone; then
// the rest of the files, less the LOAD_SENSITIVE ones, are packed into N groups by their recorded seconds
// and run in N engines at once; then the LOAD_SENSITIVE files run alone in one engine, with the machine
// quieter. Every engine's lines are printed as they come, prefixed with its name ([first], [s1].., [last]).
// The last line is the totals in the single engine's own words: "X passed, Y failed in T s". An engine that
// exits with an error, dies, times out, or does not print its own totals counts as one more failure.
//
// Ports: each engine gets its own block of PORT_BLOCK ports (tests/test_ports.gd reads --port-base=). A run
// reserves its blocks with lock files in the system temp folder (going-down-test-ports/), so two runs in
// two checkouts never take the same ports; a lock whose run is gone is taken over.
// User data: in a sharded run each engine has its own user:// folder (APPDATA / XDG_DATA_HOME pointed at
// a fresh temp folder), so two engines never write the same file. A single-engine run uses the normal one.
import { spawn } from 'node:child_process';
import { mkdirSync, readFileSync, rmSync, statSync, unlinkSync, writeFileSync } from 'node:fs';
import net from 'node:net';
import { availableParallelism, tmpdir } from 'node:os';
import { join } from 'node:path';
import { createInterface } from 'node:readline';

/** Ports per engine. Must equal SIZE in godot/tests/test_ports.gd. */
export const PORT_BLOCK = 12;
/** Where a run looks for free ports when not given --port-base= (GD_TEST_PORT_RANGE=LO-HI overrides). */
export const PORT_RANGE = [5200, 5999];
/** Run first and alone, before anything else (AGENTS.md: they "stay first"). */
export const FIRST = ['test_scripts_load', 'test_export_data'];
/**
 * Run last and alone, after the parallel engines: files whose checks wait on real time (sockets, frames,
 * wall-clock budgets) and failed under a loaded machine while passing alone. Each one is named with why.
 */
export const LOAD_SENSITIVE = [];
/** The most engines the automatic choice starts. */
export const MAX_AUTO_SHARDS = 6;
/** Seconds for a file with no recorded time. */
const UNKNOWN_SECONDS = 5;

/** The test files in their order, read from run_tests.gd (FILES). */
export function testFiles(project) {
  const src = readFileSync(join(project, 'tests', 'run_tests.gd'), 'utf8');
  const m = /const FILES: Array\[String\] = \[([\s\S]*?)\n\]/.exec(src);
  if (!m) throw new Error('cannot find FILES in godot/tests/run_tests.gd');
  return [...m[1].matchAll(/"([^"]+)"/g)].map((x) => x[1]);
}

/** The automatic shard count: half the processors (the engines share the machine), at most MAX_AUTO_SHARDS. */
export function autoShards() {
  return Math.max(1, Math.min(MAX_AUTO_SHARDS, Math.floor(availableParallelism() / 2)));
}

/** How many engines: --shards=N, --shards=auto (GD_TEST_SHARDS, else autoShards), or GD_TEST_SHARDS, or 1. */
export function shardCount(opt, env = process.env.GD_TEST_SHARDS) {
  const num = (v, what) => {
    if (v === 'auto') return autoShards();
    const n = Number(v);
    if (!Number.isInteger(n) || n < 1) throw new Error(`${what} must be a whole number of engines or auto, not "${v}"`);
    return n;
  };
  if (opt === undefined) return env ? num(env, 'GD_TEST_SHARDS') : 1;
  if (opt === 'auto') return env ? num(env, 'GD_TEST_SHARDS') : autoShards();
  return num(opt, '--shards');
}

/**
 * Packs files into n groups by seconds: the longest first, each to the group with the least so far.
 * Returns the groups (each in the order the files are listed) and their expected seconds.
 */
export function pack(files, seconds, n) {
  const groups = Array.from({ length: n }, () => ({ files: [], secs: 0 }));
  const order = files.map((f, i) => ({ f, i, s: seconds[f] ?? UNKNOWN_SECONDS })).sort((a, b) => b.s - a.s || a.i - b.i);
  for (const x of order) {
    const g = groups.reduce((best, g) => (g.secs < best.secs ? g : best), groups[0]);
    g.files.push(x);
    g.secs += x.s;
  }
  return groups.filter((g) => g.files.length > 0).map((g) => ({ files: g.files.sort((a, b) => a.i - b.i).map((x) => x.f), secs: g.secs }));
}

// --- ports ---------------------------------------------------------------------------------------------

const LOCK_DIR = join(tmpdir(), 'going-down-test-ports');
const held = new Set();
let lockInfo = { pid: process.pid, children: [], cwd: process.cwd() };

function alive(pid) {
  try {
    process.kill(pid, 0);
    return true;
  } catch (e) {
    return e.code === 'EPERM';
  }
}

/** True while the run that wrote this lock (or an engine it started) is still running. */
function lockLive(file) {
  try {
    const j = JSON.parse(readFileSync(file, 'utf8'));
    return [j.pid, ...(j.children ?? [])].some((p) => Number.isInteger(p) && alive(p));
  } catch {
    // Being written this moment, or unreadable: live for a minute, then taken over.
    try {
      return Date.now() - statSync(file).mtimeMs < 60000;
    } catch {
      return false;
    }
  }
}

function lockOne(port) {
  const file = join(LOCK_DIR, `${port}.lock`);
  for (let tries = 0; tries < 2; tries++) {
    try {
      writeFileSync(file, JSON.stringify(lockInfo), { flag: 'wx' });
      held.add(file);
      return { ok: true };
    } catch (e) {
      if (e.code !== 'EEXIST') throw e;
      if (lockLive(file)) {
        let by = '';
        try {
          by = ` by pid ${JSON.parse(readFileSync(file, 'utf8')).pid}`;
        } catch { /* being written */ }
        return { ok: false, why: `held${by}` };
      }
      try {
        unlinkSync(file);
      } catch { /* taken over by another run just now */ }
    }
  }
  return { ok: false, why: 'taken by another run' };
}

export function releasePorts() {
  for (const f of held) {
    try {
      unlinkSync(f);
    } catch { /* already gone */ }
  }
  held.clear();
}

/** Records an engine's pid in this run's locks, so the locks stay live while it runs. */
function noteChild(pid) {
  lockInfo = { ...lockInfo, children: [...lockInfo.children, pid] };
  for (const f of held) {
    try {
      writeFileSync(f, JSON.stringify(lockInfo));
    } catch { /* gone */ }
  }
}

function portFree(port) {
  return new Promise((res) => {
    const s = net.createServer();
    s.once('error', () => res(false));
    s.listen({ port, host: '127.0.0.1', exclusive: true }, () => s.close(() => res(true)));
  });
}

/** Reserves `units` blocks of PORT_BLOCK ports from `start`; on failure releases them and says why. */
async function reserve(start, units) {
  mkdirSync(LOCK_DIR, { recursive: true });
  const mine = [];
  for (let u = 0; u < units; u++) {
    const r = lockOne(start + u * PORT_BLOCK);
    if (!r.ok) {
      for (const f of mine) {
        held.delete(f);
        try {
          unlinkSync(f);
        } catch { /* gone */ }
      }
      return `ports ${start + u * PORT_BLOCK}-${start + (u + 1) * PORT_BLOCK - 1} are reserved by another test run (${r.why})`;
    }
    mine.push(join(LOCK_DIR, `${start + u * PORT_BLOCK}.lock`));
  }
  for (let p = start; p < start + units * PORT_BLOCK; p++) {
    if (!(await portFree(p))) {
      for (const f of mine) {
        held.delete(f);
        try {
          unlinkSync(f);
        } catch { /* gone */ }
      }
      return `port ${p} is in use by another program`;
    }
  }
  return '';
}

/** The first port of `units` blocks this run now holds: `base` if given, else the first free ones in range. */
export async function takePorts(units, base, range) {
  if (base !== undefined) {
    const why = await reserve(base, units);
    if (why) throw new Error(`--port-base=${base}: ${why}`);
    return base;
  }
  for (let start = range[0]; start + units * PORT_BLOCK - 1 <= range[1]; start += PORT_BLOCK) {
    if (!(await reserve(start, units))) return start;
  }
  throw new Error(`no ${units * PORT_BLOCK} free ports in ${range[0]}-${range[1]}: pass --port-base= or set GD_TEST_PORT_RANGE=LO-HI`);
}

// --- one engine ----------------------------------------------------------------------------------------

const RESULT = /^(PASS|FAIL)  (\S+)(?:  \((\d+(?:\.\d+)?) s\))?/;
const TOTALS = /^(\d+) passed, (\d+) failed in (\d+(?:\.\d+)?) s\s*$/;
const children = new Set();

/**
 * Runs one engine over `files` with `flags` (--quick, --full) and its port block; prints its lines with
 * `[tag] ` in front (or as they are, when tag is empty). Resolves to what it reported and how it ended.
 */
function runEngine(ctx, tag, files, base, env) {
  return new Promise((res) => {
    const args = [...ctx.prefix, '--headless', '--path', ctx.project, '--script', 'res://tests/run_tests.gd', '--', ...ctx.flags, `--port-base=${base}`, ...files];
    const r = { tag, files, passed: 0, failed: 0, totals: null, results: [], code: null, signal: null, error: '', timedOut: false, pid: 0 };
    const pre = tag ? `[${tag}] ` : '';
    let child;
    try {
      child = spawn(ctx.engine, args, { cwd: ctx.root, env, stdio: ['ignore', 'pipe', 'pipe'], windowsHide: true });
    } catch (e) {
      r.error = e.message;
      res(r);
      return;
    }
    r.pid = child.pid ?? 0;
    if (r.pid) noteChild(r.pid);
    children.add(child);
    if (tag) console.log(`${pre}engine pid ${r.pid}, ports ${base}-${base + PORT_BLOCK - 1}: ${files.length} file(s): ${files.join(' ')}`);
    const line = (l) => {
      console.log(`${pre}${l}`);
      const m = RESULT.exec(l);
      if (m) {
        if (m[1] === 'PASS') r.passed++;
        else r.failed++;
        r.results.push({ name: m[2], ok: m[1] === 'PASS', secs: m[3] === undefined ? 0 : Number(m[3]) });
      }
      const t = TOTALS.exec(l);
      if (t) r.totals = { passed: Number(t[1]), failed: Number(t[2]) };
    };
    createInterface({ input: child.stdout }).on('line', line);
    createInterface({ input: child.stderr }).on('line', line);
    const timer = setTimeout(() => {
      r.timedOut = true;
      child.kill('SIGKILL');
    }, ctx.seconds * 1000);
    child.on('error', (e) => {
      r.error = e.message;
    });
    child.on('close', (code, signal) => {
      clearTimeout(timer);
      children.delete(child);
      r.code = code;
      r.signal = signal;
      res(r);
    });
  });
}

/** Why an engine's run cannot be trusted, or '' when it ended as it should. */
function problem(r, ctx) {
  if (r.error) return `could not run: ${r.error}`;
  if (r.timedOut) return `timed out after ${ctx.seconds} s (GODOT_TIMEOUT)`;
  if (r.totals === null) return `ended (exit ${r.code ?? 'none'}${r.signal ? `, ${r.signal}` : ''}) without printing its totals: it crashed or was killed`;
  if (r.totals.passed !== r.passed || r.totals.failed !== r.failed) return `its totals (${r.totals.passed} passed, ${r.totals.failed} failed) do not match its ${r.passed + r.failed} result lines`;
  if (r.code !== 0 && r.failed === 0) return `exit ${r.code} with no failed test`;
  if (r.code === 0 && r.failed > 0) return `exit 0 with ${r.failed} failed test(s)`;
  return '';
}

function killAll() {
  for (const c of children) {
    try {
      c.kill('SIGKILL');
    } catch { /* gone */ }
  }
}

// --- the command ---------------------------------------------------------------------------------------

function timingsFile(project) {
  return join(project, 'tests', 'timings.json');
}

function readTimings(project, key) {
  try {
    return JSON.parse(readFileSync(timingsFile(project), 'utf8'))[key] ?? {};
  } catch {
    return {};
  }
}

/** Writes each file's seconds (the sum of its tests' own times) under `key`, keeping the other keys. */
function writeTimings(project, key, results) {
  let all = {};
  try {
    all = JSON.parse(readFileSync(timingsFile(project), 'utf8'));
  } catch { /* a new file */ }
  const per = {};
  for (const x of results) {
    const f = x.name.split('.')[0];
    per[f] = Math.round(((per[f] ?? 0) + x.secs) * 10) / 10;
  }
  all[key] = Object.fromEntries(Object.entries({ ...(all[key] ?? {}), ...per }).sort(([a], [b]) => (a < b ? -1 : 1)));
  writeFileSync(timingsFile(project), `${JSON.stringify(all, null, 2)}\n`);
  console.log(`timings: ${Object.keys(per).length} file(s) written to godot/tests/timings.json (key "${key}")`);
}

let cleanupSet = false;

function option(rest, name) {
  const a = rest.find((x) => x === `--${name}` || x.startsWith(`--${name}=`));
  if (a === undefined) return undefined;
  return a.includes('=') ? a.slice(a.indexOf('=') + 1) : true;
}

/**
 * `node godot/tools/godot.mjs test [args]`. Resolves to the exit code. `prefix` goes before the engine's
 * arguments (tools/test_shards.test.mjs runs a stand-in engine as `node fake_engine.mjs ...`).
 */
export async function testCommand({ root, project, engine, rest, prefix = [] }) {
  const ours = ['--shards', '--port-base', '--record-timings'];
  const own = (a) => ours.some((o) => a === o || a.startsWith(`${o}=`));
  const engineArgs = rest.filter((a) => !own(a));
  const full = engineArgs.includes('--full');
  const quick = engineArgs.includes('--quick') && !full;
  const ctx = {
    root,
    project,
    engine,
    prefix,
    flags: engineArgs.filter((a) => a.startsWith('--')),
    seconds: Number(process.env.GODOT_TIMEOUT || (full ? 21600 : 3600)),
  };
  let shards;
  let base;
  let range = PORT_RANGE;
  try {
    shards = shardCount(option(rest, 'shards'));
    const pb = option(rest, 'port-base');
    if (pb !== undefined) {
      base = Number(pb);
      if (!Number.isInteger(base) || base < 1024 || base > 65535 - PORT_BLOCK) throw new Error(`--port-base must be a port number, not "${pb}"`);
    }
    const env = process.env.GD_TEST_PORT_RANGE;
    if (env) {
      const m = /^(\d+)-(\d+)$/.exec(env);
      if (!m || Number(m[1]) < 1024 || Number(m[2]) > 65535 || Number(m[1]) > Number(m[2])) throw new Error(`GD_TEST_PORT_RANGE must be LO-HI, not "${env}"`);
      range = [Number(m[1]), Number(m[2])];
    }
  } catch (e) {
    console.error(e.message);
    return 2;
  }
  const record = option(rest, 'record-timings') !== undefined;
  const key = full ? 'full' : quick ? 'quick' : 'default';
  const all = testFiles(project);
  const named = engineArgs.filter((a) => !a.startsWith('--'));
  // A name that is not a test file: one engine says so in its own words, as before.
  if (named.some((n) => !all.includes(n))) shards = 1;
  const files = named.length > 0 ? all.filter((f) => named.includes(f)) : all;

  if (!cleanupSet) {
    cleanupSet = true;
    const onSignal = () => {
      killAll();
      releasePorts();
      process.exit(130);
    };
    process.on('SIGINT', onSignal);
    process.on('SIGTERM', onSignal);
    process.on('exit', () => {
      killAll();
      releasePorts();
    });
  }

  const t0 = Date.now();
  if (shards <= 1) {
    // One engine, every file in order, its output exactly as it prints it.
    try {
      base = await takePorts(1, base, range);
    } catch (e) {
      console.error(e.message);
      return 2;
    }
    console.log(`test ports: ${base}-${base + PORT_BLOCK - 1} (one engine)`);
    const r = await runEngine(ctx, '', named, base, process.env);
    if (record) writeTimings(project, key, r.results);
    // As before, the engine's own exit code; and an engine that died or hung is a failure, never a pass.
    const why = problem(r, ctx);
    if (why && !(r.totals !== null && r.failed > 0 && r.code !== 0)) {
      console.log(`FAIL  engine (the only one): ${why}`);
      return r.code || 1;
    }
    return r.code ?? 1;
  }

  const first = files.filter((f) => FIRST.includes(f));
  const last = files.filter((f) => LOAD_SENSITIVE.includes(f) && !FIRST.includes(f));
  const middle = files.filter((f) => !FIRST.includes(f) && !LOAD_SENSITIVE.includes(f));
  const groups = pack(middle, readTimings(project, key), shards);
  try {
    base = await takePorts(Math.max(1, groups.length), base, range);
  } catch (e) {
    console.error(e.message);
    return 2;
  }
  const dataRoot = join(tmpdir(), 'going-down-test-data', `${process.pid}-${Date.now().toString(36)}`);
  const envFor = (tag) => {
    const dir = join(dataRoot, tag);
    mkdirSync(dir, { recursive: true });
    return { ...process.env, APPDATA: dir, XDG_DATA_HOME: dir };
  };
  console.log(`sharded test run: ${files.length} file(s); first ${first.length} alone, then ${groups.length} engines side by side, then ${last.length} alone`);
  console.log(`test ports: ${base}-${base + Math.max(1, groups.length) * PORT_BLOCK - 1} (${PORT_BLOCK} per engine)`);
  for (const [i, g] of groups.entries()) console.log(`  s${i + 1}: ${g.files.length} file(s), about ${g.secs.toFixed(0)} s recorded`);

  const runs = [];
  if (first.length > 0) runs.push(await runEngine(ctx, 'first', first, base, envFor('first')));
  const tMid = Date.now();
  runs.push(...(await Promise.all(groups.map((g, i) => runEngine(ctx, `s${i + 1}`, g.files, base + i * PORT_BLOCK, envFor(`s${i + 1}`))))));
  const midSecs = (Date.now() - tMid) / 1000;
  if (last.length > 0) runs.push(await runEngine(ctx, 'last', last, base, envFor('last')));

  let passed = 0;
  let failed = 0;
  const results = [];
  console.log('');
  console.log('engines:');
  for (const r of runs) {
    passed += r.passed;
    failed += r.failed;
    results.push(...r.results);
    const why = problem(r, ctx);
    console.log(`  ${r.tag}: ${r.passed} passed, ${r.failed} failed${why ? `: ${why}` : ''}`);
    // An engine that did not finish as it should is a failure of its own, never dropped.
    if (why && !(r.totals !== null && r.failed > 0 && r.code !== 0)) {
      failed += 1;
      console.log(`FAIL  engine ${r.tag} (${r.files.join(' ')}): ${why}`);
    }
  }
  const expectedFiles = new Set(files);
  const reported = new Set(results.map((x) => x.name.split('.')[0]));
  const silent = [...expectedFiles].filter((f) => !reported.has(f));
  if (silent.length > 0) console.log(`files with no result line: ${silent.join(', ')}`);
  console.log(`parallel phase: ${midSecs.toFixed(1)} s`);
  try {
    rmSync(dataRoot, { recursive: true, force: true });
  } catch { /* a file still open: left in the temp folder */ }
  if (record) writeTimings(project, key, results);
  const secs = (Date.now() - t0) / 1000;
  console.log(`${passed} passed, ${failed} failed in ${secs.toFixed(1)} s`);
  return failed === 0 && passed > 0 ? 0 : 1;
}
