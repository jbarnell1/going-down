// npm run godot:reference  -> regenerate godot/tests/reference/*.json from the TypeScript rules
// npm run godot:test       -> run the Godot test suite headless (extra args pass through, e.g. -- --full)
// npm run godot:test -- --quick  -> the quick set (about a minute): every test file, smaller runs
// npm run godot:export     -> import the assets, export godot/export/web and godot/export/windows/GoingDown.exe,
//                             then precompress the web build for the hub (node hub/precompress.mjs)
// node godot/tools/godot.mjs import   -> only the import pass (assets, the global class list)
//
// The engine is $GODOT, or tools/godot/Godot_v4.7.2-stable_win64_console.exe under the repo root.
// A GDScript parse error can leave a headless Godot waiting forever, so every run has a hard timeout:
// $GODOT_TIMEOUT seconds (default 3600, or 21600 with --full; 600 for an import or an export).
import { spawnSync } from 'node:child_process';
import { existsSync, mkdirSync, statSync, writeFileSync } from 'node:fs';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const here = dirname(fileURLToPath(import.meta.url));
const root = resolve(here, '..', '..');
const project = join(root, 'godot');
const [command, ...rest] = process.argv.slice(2);

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
  if (code === 0 && rest.length === 0) code = run(process.execPath, [tsx, join(here, 'property_counts.ts')]);
  process.exit(code);
} else if (command === 'test') {
  const full = rest.includes('--full');
  const seconds = Number(process.env.GODOT_TIMEOUT || (full ? 21600 : 3600));
  const args = ['--headless', '--path', project, '--script', 'res://tests/run_tests.gd'];
  if (rest.length > 0) args.push('--', ...rest);
  process.exit(run(engine(), args, { timeout: seconds * 1000, killSignal: 'SIGKILL' }));
} else if (command === 'import') {
  process.exit(importPass() ? 0 : 1);
} else if (command === 'export') {
  // Which builds: `web`, `windows` or both (default).
  const which = rest.filter((a) => !a.startsWith('--'));
  const want = (k) => which.length === 0 || which.includes(k);
  if (!importPass()) process.exit(1);
  const out = join(project, 'export');
  mkdirSync(out, { recursive: true });
  writeFileSync(join(out, '.gdignore'), ''); // keep Godot from importing its own builds
  const seconds = Number(process.env.GODOT_TIMEOUT || 600);
  const builds = [
    ['web', 'Web', join(out, 'web', 'index.html')],
    ['windows', 'Windows', join(out, 'windows', 'GoingDown.exe')],
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
  console.error('usage: node godot/tools/godot.mjs reference|test|import|export [args]');
  process.exit(2);
}
