// npm run godot:reference  -> regenerate godot/tests/reference/*.json from the TypeScript rules
// npm run godot:test       -> run the Godot test suite headless (extra args pass through, e.g. -- --full)
//
// The engine is $GODOT, or tools/godot/Godot_v4.7.2-stable_win64_console.exe under the repo root.
// A GDScript parse error can leave a headless Godot waiting forever, so the run has a hard timeout:
// $GODOT_TIMEOUT seconds (default 3600, or 21600 with --full).
import { spawnSync } from 'node:child_process';
import { existsSync } from 'node:fs';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const here = dirname(fileURLToPath(import.meta.url));
const root = resolve(here, '..', '..');
const [command, ...rest] = process.argv.slice(2);

function run(cmd, args, opts = {}) {
  const r = spawnSync(cmd, args, { stdio: 'inherit', cwd: root, ...opts });
  if (r.error) {
    console.error(r.error.code === 'ETIMEDOUT' ? `timed out after ${opts.timeout / 1000} s` : r.error.message);
    return 1;
  }
  return r.status ?? 1;
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
  const godot = process.env.GODOT || join(root, 'tools', 'godot', 'Godot_v4.7.2-stable_win64_console.exe');
  if (!existsSync(godot)) {
    console.error(`Godot not found at ${godot}: set GODOT to the engine (the console build on Windows).`);
    process.exit(1);
  }
  const full = rest.includes('--full');
  const seconds = Number(process.env.GODOT_TIMEOUT || (full ? 21600 : 3600));
  const args = ['--headless', '--path', join(root, 'godot'), '--script', 'res://tests/run_tests.gd'];
  if (rest.length > 0) args.push('--', ...rest);
  process.exit(run(godot, args, { timeout: seconds * 1000, killSignal: 'SIGKILL' }));
} else {
  console.error('usage: node godot/tools/godot.mjs reference|test [args]');
  process.exit(2);
}
