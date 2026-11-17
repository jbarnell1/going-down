// npm run godot:test       -> run the Godot test suite headless (extra args pass through, e.g. -- --full)
// npm run godot:test -- --quick  -> the quick set (about a minute): every test file, smaller runs
// npm run godot:golden     -> RECORD the goldens (godot/tests/golden/) from the GDScript implementation,
//                             then print what changed against the goldens that were on disk. Never part
//                             of the tests: run it on purpose after changing a rule (godot/tests/README.md).
//                             `-- ref_run prop_blackout` records only those test files; `-- --full`
//                             records only the full-size property counts (slow: hours).
// npm run godot:export -- server -> the dedicated server: godot/export/server/GoingDownServer.x86_64 (Linux, headless)
// npm run godot:export     -> import the assets, export godot/export/web and godot/export/windows/GoingDown.exe,
//                             then precompress the web build for the hub (node hub/precompress.mjs)
// node godot/tools/godot.mjs golden-diff DIR -> the same summary, comparing the goldens in DIR with godot/tests/golden/
// node godot/tools/godot.mjs import   -> only the import pass (assets, the global class list)
// npm run godot:reference  -> HISTORICAL: the TypeScript dumpers that produced the reference the first
//                             goldens were proved against; writes godot/export/typescript-reference/
//                             (see check_goldens_against_typescript.mjs). Needs Node and src/.
//
// The engine is $GODOT, or tools/godot/Godot_v4.7.2-stable_win64_console.exe under the repo root.
// A GDScript parse error can leave a headless Godot waiting forever, so every run has a hard timeout:
// $GODOT_TIMEOUT seconds (default 3600, or 21600 with --full; 600 for an import or an export).
import { spawnSync } from 'node:child_process';
import { existsSync, mkdirSync, readdirSync, readFileSync, statSync, writeFileSync } from 'node:fs';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const here = dirname(fileURLToPath(import.meta.url));
const root = resolve(here, '..', '..');
const project = join(root, 'godot');
const [command, ...rest] = process.argv.slice(2);
/** godot:golden's summary: at most this many changed parts are described one by one per file; the rest are named. */
const MAX_DESCRIBED = 12;

function run(cmd, args, opts = {}) {
  const r = spawnSync(cmd, args, { stdio: 'inherit', cwd: root, ...opts });
  if (r.error) {
    console.error(r.error.code === 'ETIMEDOUT' ? `timed out after ${opts.timeout / 1000} s` : r.error.message);
    return 1;
  }
  return r.status ?? 1;
}

function engine() {
  const godot = process.env.GODOT || join(root, 'tools', 'godot', 'Godot_v4.7.2-stable_win64_console.exe');
  if (!existsSync(godot)) {
    console.error(`Godot not found at ${godot}: set GODOT to the engine (the console build on Windows).`);
    process.exit(1);
  }
  return godot;
}

/** Runs Godot headless on the project; returns [exit code, output]. Output is echoed. */
function godotRun(args, seconds) {
  const r = spawnSync(engine(), ['--headless', '--path', project, ...args], { cwd: root, timeout: seconds * 1000, killSignal: 'SIGKILL', encoding: 'utf8', maxBuffer: 64 << 20 });
  const out = `${r.stdout ?? ''}${r.stderr ?? ''}`;
  if (r.error) return [1, `${out}\n${r.error.code === 'ETIMEDOUT' ? `timed out after ${seconds} s` : r.error.message}`];
  return [r.status ?? 1, out];
}

/** Lines of Godot output that are errors (script errors, failed loads, export failures). */
function errorLines(out) {
  return out.split(/\r?\n/).filter((l) => /\b(ERROR|SCRIPT ERROR|Parse Error|Failed)\b/.test(l));
}

function importPass() {
  const seconds = Number(process.env.GODOT_TIMEOUT || 600);
  const t0 = Date.now();
  const [code, out] = godotRun(['--import'], seconds);
  const errs = errorLines(out);
  console.log(`import: exit ${code}, ${((Date.now() - t0) / 1000).toFixed(1)} s${errs.length ? `, ${errs.length} error line(s)` : ''}`);
  for (const l of errs.slice(0, 20)) console.log(`  ${l}`);
  return code === 0 && errs.length === 0;
}

if (command === 'reference') {
  const tsx = join(here, 'node_modules', 'tsx', 'dist', 'cli.mjs');
  if (!existsSync(tsx)) {
    const npm = process.platform === 'win32' ? 'npm.cmd' : 'npm';
    const code = run(npm, ['ci', '--no-audit', '--no-fund'], { cwd: here, shell: process.platform === 'win32' });
    if (code !== 0) process.exit(code);
  }
  let code = run(process.execPath, [tsx, join(here, 'dump_reference.ts'), ...rest]);
  const job = rest.find((a) => !a.startsWith('--'));
  if (code === 0 && job === undefined) code = run(process.execPath, [tsx, join(here, 'property_counts.ts'), ...rest]);
  process.exit(code);
} else if (command === 'test') {
  const full = rest.includes('--full');
  const seconds = Number(process.env.GODOT_TIMEOUT || (full ? 21600 : 3600));
  const args = ['--headless', '--path', project, '--script', 'res://tests/run_tests.gd'];
  if (rest.length > 0) args.push('--', ...rest);
  process.exit(run(engine(), args, { timeout: seconds * 1000, killSignal: 'SIGKILL' }));
} else if (command === 'golden') {
  const full = rest.includes('--full');
  const goldenDir = join(project, 'tests', 'golden');
  const before = readGoldens(goldenDir);
  const seconds = Number(process.env.GODOT_TIMEOUT || (full ? 43200 : 7200));
  const t0 = Date.now();
  const args = ['--headless', '--path', project, '--script', 'res://tests/run_tests.gd', '--', '--golden', ...rest];
  const code = run(engine(), args, { timeout: seconds * 1000, killSignal: 'SIGKILL' });
  const after = readGoldens(goldenDir);
  console.log('');
  console.log(`godot:golden finished in ${((Date.now() - t0) / 1000).toFixed(0)} s (exit ${code}).`);
  const files = rest.filter((a) => !a.startsWith('--'));
  console.log(`Test files recorded: ${files.length > 0 ? files.join(', ') : 'all'}.`);
  console.log(full
    ? 'Sizes recorded: the FULL property sizes only (properties.json key "full"). Nothing else was recorded.'
    : 'Sizes recorded: ref_* and test_jsmath at the default size (they cover the quick set); prop_* at the quick and default sizes (properties.json keys "quick", "sub", "clinic", "clinicQuick"). The full sizes ("full") were NOT recorded: run `npm run godot:golden -- --full` for those (slow).');
  printGoldenSummary(before, after);
  process.exit(code);
} else if (command === 'golden-diff') {
  // The same summary without recording: what differs between the goldens in DIR (for example a copy
  // taken from another commit) and godot/tests/golden/.  node godot/tools/godot.mjs golden-diff DIR
  const dir = rest.find((a) => !a.startsWith('--'));
  if (!dir || !existsSync(dir)) {
    console.error('usage: node godot/tools/godot.mjs golden-diff DIR (a folder of golden files to compare with godot/tests/golden/)');
    process.exit(2);
  }
  const before = readGoldens(resolve(dir));
  for (const v of before.values()) v.mtime = -1;
  printGoldenSummary(before, readGoldens(join(project, 'tests', 'golden')), `the goldens in ${dir}`);
  process.exit(0);
} else if (command === 'import') {
  process.exit(importPass() ? 0 : 1);
} else if (command === 'export') {
  // Which builds: `web`, `windows`, `server` (the Linux headless server), or web and windows (default).
  const which = rest.filter((a) => !a.startsWith('--'));
  const want = (k) => (which.length === 0 ? k !== 'server' : which.includes(k));
  if (!importPass()) process.exit(1);
  const out = join(project, 'export');
  mkdirSync(out, { recursive: true });
  writeFileSync(join(out, '.gdignore'), ''); // keep Godot from importing its own builds
  const seconds = Number(process.env.GODOT_TIMEOUT || 600);
  const builds = [
    ['web', 'Web', join(out, 'web', 'index.html')],
    ['windows', 'Windows', join(out, 'windows', 'GoingDown.exe')],
    ['server', 'Linux Server', join(out, 'server', 'GoingDownServer.x86_64')],
  ];
  let ok = true;
  for (const [key, preset, file] of builds) {
    if (!want(key)) continue;
    mkdirSync(dirname(file), { recursive: true });
    const t0 = Date.now();
    const [code, log] = godotRun(['--export-release', preset, file], seconds);
    const errs = errorLines(log);
    const fresh = existsSync(file) && statSync(file).mtimeMs >= t0 - 2000;
    console.log(`${key}: exit ${code}, ${((Date.now() - t0) / 1000).toFixed(1)} s, ${fresh ? `${(statSync(file).size / 1048576).toFixed(1)} MB` : 'NOT WRITTEN'} ${file.slice(root.length + 1)}`);
    for (const l of errs.slice(0, 20)) console.log(`  ${l}`);
    if (code !== 0 || !fresh || errs.length > 0) ok = false;
  }
  if (ok && want('web')) ok = run(process.execPath, [join(root, 'hub', 'precompress.mjs'), join('godot', 'export', 'web')]) === 0;
  process.exit(ok ? 0 : 1);
} else {
  console.error('usage: node godot/tools/godot.mjs test|golden|import|export|reference [args]');
  process.exit(2);
}

// ---------------------------------------------------------------------------------------------
// The summary godot:golden prints: what changed in the goldens, scenario by scenario.

/** name -> {text, mtime} of every golden file in `dir` (empty when the folder is missing). */
function readGoldens(dir) {
  const out = new Map();
  if (!existsSync(dir)) return out;
  for (const name of readdirSync(dir).filter((n) => n.endsWith('.json')).sort()) {
    out.set(name, { text: readFileSync(join(dir, name), 'utf8'), mtime: statSync(join(dir, name)).mtimeMs });
  }
  return out;
}

function printGoldenSummary(before, after, against = 'the files on disk before this run') {
  console.log('');
  console.log(`What changed in godot/tests/golden/ (compared with ${against}):`);
  const names = [...new Set([...before.keys(), ...after.keys()])].sort();
  for (const name of names) {
    const fa = before.get(name);
    const fb = after.get(name);
    if (fa === undefined) {
      console.log(`  ${name}: NEW FILE`);
      continue;
    }
    if (fb === undefined) {
      console.log(`  ${name}: REMOVED`);
      continue;
    }
    if (fa.mtime === fb.mtime && fa.text === fb.text) {
      console.log(`  ${name}: not recorded in this run (kept as it was)`);
      continue;
    }
    if (fa.text === fb.text) {
      console.log(`  ${name}: ${fa.mtime === -1 ? 'unchanged' : 'recorded, unchanged'}`);
      continue;
    }
    const units = goldenUnits(name, JSON.parse(fa.text), JSON.parse(fb.text));
    const changed = units.filter((u) => !deepEqual(u.a, u.b));
    const same = units.filter((u) => deepEqual(u.a, u.b));
    console.log(`  ${name}: ${changed.length} of ${units.length} parts changed`);
    for (const u of changed.slice(0, MAX_DESCRIBED)) {
      const lines = describe(u.a, u.b);
      console.log(`    CHANGED ${u.label}: ${lines[0] ?? ''}`);
      for (const l of lines.slice(1, 8)) console.log(`        ${l}`);
      if (lines.length > 8) console.log(`        ... ${lines.length - 8} more differences`);
    }
    if (changed.length > MAX_DESCRIBED) console.log(`    also changed (${changed.length - MAX_DESCRIBED}): ${changed.slice(MAX_DESCRIBED).map((u) => u.label).join(', ')}`);
    if (same.length > 0) console.log(`    unchanged (${same.length}): ${same.slice(0, 20).map((u) => u.label).join(', ')}${same.length > 20 ? `, ... ${same.length - 20} more` : ''}`);
  }
}

/** A label for a scenario object: its name, seed (and depth), style, or scene. */
function labelOf(v, i) {
  if (v && typeof v === 'object' && !Array.isArray(v)) {
    if (typeof v.name === 'string') return v.name;
    if (typeof v.style === 'string') return `${v.style} d${v.depth} #${v.i}`;
    if (v.seed !== undefined) return v.depth !== undefined ? `${v.seed} d${v.depth}` : `${v.seed}`;
    if (typeof v.scene === 'string') return v.scene;
  }
  return `#${i}`;
}

/** The parts of a golden file that are reported one by one (scenarios, count groups). */
function goldenUnits(name, a, b) {
  const units = [];
  const list = (prefix, xa, xb) => {
    const n = Math.max(xa?.length ?? 0, xb?.length ?? 0);
    for (let i = 0; i < n; i++) {
      const label = labelOf(xb?.[i] ?? xa?.[i], i);
      units.push({ label: prefix ? `${prefix} ${label}` : label, a: xa?.[i], b: xb?.[i] });
    }
  };
  const labelled = (x) => Array.isArray(x) && x.length > 0 && x.every((e) => e && typeof e === 'object' && !Array.isArray(e));
  if (Array.isArray(a) || Array.isArray(b)) {
    list('', a, b);
    return units;
  }
  for (const k of [...new Set([...Object.keys(a ?? {}), ...Object.keys(b ?? {})])]) {
    const xa = a?.[k];
    const xb = b?.[k];
    if (name === 'properties.json' && ((xa && typeof xa === 'object' && !Array.isArray(xa) && !('floors' in xa)) || (xb && typeof xb === 'object' && !Array.isArray(xb) && !('floors' in xb)))) {
      for (const g of [...new Set([...Object.keys(xa ?? {}), ...Object.keys(xb ?? {})])]) units.push({ label: `${k}.${g}`, a: xa?.[g], b: xb?.[g] });
    } else if (labelled(xa) || labelled(xb)) {
      list(k, xa, xb);
    } else {
      units.push({ label: k, a: xa, b: xb });
    }
  }
  return units;
}

function deepEqual(x, y) {
  return JSON.stringify(x) === JSON.stringify(y);
}

/** "~hex" -> the number, for display. */
function num(v) {
  if (typeof v === 'string' && /^~[0-9a-f]{16}$/.test(v)) return Buffer.from(v.slice(1), 'hex').readDoubleBE(0);
  return v;
}
function show(v) {
  const x = num(v);
  const s = typeof x === 'number' ? String(x) : JSON.stringify(x, (_k, e) => num(e));
  return s === undefined ? 'missing' : s.length > 160 ? `${s.slice(0, 157)}...` : s;
}
function firstChunk(x, y, size) {
  const n = Math.min(x.length, y.length);
  for (let i = 0; i < n; i += size) if (x.slice(i, i + size) !== y.slice(i, i + size)) return i / size;
  return x.length === y.length ? -1 : n / size;
}
function isTrace(v) {
  return v && typeof v === 'object' && typeof v.full === 'string' && typeof v.ticks === 'number' && 'events' in v;
}

/** Lines describing how `b` differs from `a`: the first line is the headline. */
function describe(a, b) {
  if (a === undefined) return ['new (not in the goldens before)'];
  if (b === undefined) return ['gone (no longer recorded)'];
  if (isTrace(a) && isTrace(b)) return traceLines(a, b);
  if (a && b && typeof a === 'object' && a.msgs && b.msgs) return netLines(a, b);
  if (a && b && typeof a === 'object' && isTrace(a.trace) && isTrace(b.trace)) {
    const lines = traceLines(a.trace, b.trace);
    const pa = Object.keys(a.plans ?? {});
    const pb = Object.keys(b.plans ?? {});
    const pd = [...new Set([...pa, ...pb])].filter((k) => !deepEqual(a.plans?.[k], b.plans?.[k]));
    if (pd.length > 0) lines.push(`floor plans sent at requests ${pd.slice(0, 8).join(', ')} differ`);
    return lines;
  }
  const leaves = [];
  leafDiffs(a, b, '', leaves);
  return [`${leaves.length} value(s) differ`, ...leaves];
}

function leafDiffs(a, b, path, out) {
  if (deepEqual(a, b)) return;
  if (typeof a === 'string' && typeof b === 'string' && a.length > 40 && a.length % 8 === 0 && /^[0-9a-f]+$/.test(a + b)) {
    out.push(`${path || '(value)'}: digests differ from item ${firstChunk(a, b, 8)} (of ${b.length / 8})`);
    return;
  }
  if (typeof a === 'string' && typeof b === 'string' && /^[01]+$/.test(a + b) && a.length > 40) {
    const i = firstChunk(a, b, 1);
    out.push(`${path || '(value)'}: answers differ from answer ${i} (query ${Math.floor(i / 7)}); ${[...a].filter((c, k) => c !== b[k]).length} differ`);
    return;
  }
  const ao = a && typeof a === 'object';
  const bo = b && typeof b === 'object';
  if (ao && bo && Array.isArray(a) === Array.isArray(b)) {
    if (Array.isArray(a) && a.length !== b.length) out.push(`${path || '(list)'}: ${a.length} items -> ${b.length}`);
    const keys = Array.isArray(a) ? [...Array(Math.min(a.length, b.length)).keys()] : [...new Set([...Object.keys(a), ...Object.keys(b)])];
    for (const k of keys) {
      if (out.length >= 40) return;
      leafDiffs(a[k], b[k], path ? `${path}${Array.isArray(a) ? `[${k}]` : `.${k}`}` : String(k), out);
    }
    return;
  }
  const x = num(a);
  const y = num(b);
  const delta = typeof x === 'number' && typeof y === 'number' ? ` (${y - x >= 0 ? '+' : ''}${+(y - x).toPrecision(6)})` : '';
  out.push(`${path || '(value)'}: ${show(a)} -> ${show(b)}${delta}`);
}

function traceLines(a, b) {
  const lines = [];
  const f = firstChunk(a.full, b.full, 8);
  const e = firstChunk(a.exact, b.exact, 8);
  const head = f < 0 ? 'every tick\'s state the same' : `state differs from tick ${f}${e < 0 ? ' (in the pay fields only)' : e > f ? ` (outside the pay from tick ${e})` : ''}`;
  lines.push(`${head}; ${a.ticks} ticks -> ${b.ticks}; ${a.events.length} events -> ${b.events.length}`);
  const n = Math.min(a.events.length, b.events.length);
  let i = 0;
  while (i < n && deepEqual(a.events[i], b.events[i])) i++;
  if (i < a.events.length || i < b.events.length) {
    lines.push(`first different event: #${i}: before ${show(a.events[i])}`);
    lines.push(`                              after  ${show(b.events[i])}`);
  }
  const snaps = [...new Set([...Object.keys(a.snaps ?? {}), ...Object.keys(b.snaps ?? {})])].map(Number).sort((x, y) => x - y);
  const sd = snaps.find((k) => !deepEqual(a.snaps?.[k], b.snaps?.[k]));
  if (sd !== undefined) {
    const leaves = [];
    leafDiffs(a.snaps?.[sd], b.snaps?.[sd], `state@${sd}`, leaves);
    lines.push(`first different full state: tick ${sd}: ${leaves.slice(0, 4).join('; ')}`);
  }
  if (!deepEqual(a.extra, b.extra)) {
    const xi = (a.extra ?? []).findIndex((x, k) => !deepEqual(x, b.extra?.[k]));
    lines.push(`per-tick values differ from tick ${xi < 0 ? Math.min(a.extra?.length ?? 0, b.extra?.length ?? 0) : xi}`);
  }
  return lines;
}

function netLines(a, b) {
  const lines = [];
  const m = firstChunk(a.msgs.text, b.msgs.text, 8);
  const r = firstChunk(a.msgs.route, b.msgs.route, 8);
  const first = [m, r].filter((x) => x >= 0);
  lines.push(first.length === 0 ? `every message the same (${b.msgs.n})` : `messages differ from message ${Math.min(...first)} (${a.msgs.n} messages -> ${b.msgs.n})`);
  for (const id of [...new Set([...Object.keys(a.frames ?? {}), ...Object.keys(b.frames ?? {})])]) {
    const fa = a.frames?.[id];
    const fb = b.frames?.[id];
    if (deepEqual(fa, fb)) continue;
    lines.push(`${id}: drawn frames differ from frame ${fa && fb ? firstChunk(fa.digests, fb.digests, 8) : 0} (${fa?.n ?? 0} frames -> ${fb?.n ?? 0})`);
  }
  if (!deepEqual(a.host, b.host)) lines.push(`host: ${traceLines(a.host, b.host).join('; ')}`);
  const leaves = [];
  leafDiffs({ hostStats: a.hostStats, clientStats: a.clientStats, logLength: a.logLength }, { hostStats: b.hostStats, clientStats: b.clientStats, logLength: b.logLength }, '', leaves);
  lines.push(...leaves);
  return lines;
}
