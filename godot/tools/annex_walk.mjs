// The Annex's look on the Windows build: starts export/windows/GoingDown.exe in a small window with
// `scene=annex_demo` (main.gd switches to client/annex_demo.tscn), which builds seeded Annex floors,
// checks that same-shaped rooms are dressed alike, saves pictures from a scripted camera to
// export/shots/annex/, then walks the camera on the Annex and on a Clinic floor of the same seed and
// reports frame times (vsync off). Writes export/shots/annex/report.json. Exits non-zero if the
// same-shape check fails (with its light-count and blackout-colour checks, annex_demo.gd check_floors),
// the Annex is slower than the Clinic (mean or p95, beyond 5 %), the Annex has more lights than the
// renderer draws a frame (256), or the game does not finish. It never captures the mouse; start
// .local/guard-mouse.ps1 beside it anyway.
// Usage: node annex_walk.mjs [--seed=annex-1] [--depth=3] [--bench=6] [--rounds=2]
import { spawn } from 'node:child_process';
import { mkdirSync, writeFileSync } from 'node:fs';
import { dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const here = dirname(fileURLToPath(import.meta.url));
const arg = (k, d) => (process.argv.find((a) => a.startsWith(`--${k}=`)) ?? `--${k}=${d}`).split('=')[1];
const seed = arg('seed', 'annex-1');
const depth = arg('depth', '3');
const bench = arg('bench', '6');
const rounds = arg('rounds', '2');
const dir = resolve(here, '../export/windows');
const shots = resolve(here, '../export/shots/annex');
const LIGHT_LIMIT = 256;
mkdirSync(shots, { recursive: true });

const lines = [];
const game = spawn(resolve(dir, 'GoingDown.exe'), ['--resolution', '960x540', '--position', '40,40', '--',
  'scene=annex_demo', `shots=${shots.replaceAll('\\', '/')}`, `seed=${seed}`, `depth=${depth}`, `bench=${bench}`, `rounds=${rounds}`],
{ cwd: dir, stdio: ['ignore', 'pipe', 'pipe'] });
const keep = (b) => {
  for (const l of b.toString().split(/\r?\n/)) {
    if (!l.trim()) continue;
    lines.push(l);
    if (l.startsWith('annex demo:') || /ERROR/.test(l)) console.log(l);
  }
};
game.stdout.on('data', keep);
game.stderr.on('data', keep);
const timer = setTimeout(() => { console.log('timed out'); game.kill(); }, 300_000);
const code = await new Promise((res) => game.on('exit', (c) => res(c ?? 1)));
clearTimeout(timer);

const jsonLine = lines.find((l) => l.startsWith('annex demo json: '));
const report = jsonLine ? JSON.parse(jsonLine.slice('annex demo json: '.length)) : {};
const errors = lines.filter((l) => /\b(SCRIPT ERROR|ERROR)\b/.test(l));
const failures = [];
if (!jsonLine) failures.push('the demo did not finish');
if (code !== 0) failures.push(`exit code ${code}`);
if ((report.check?.problems ?? ['missing']).length) failures.push('same-shape check failed');
if (errors.length) failures.push(`${errors.length} engine error line(s)`);
const a = report.bench_annex;
const c = report.bench_clinic;
if (a && c) {
  console.log(`frame time, Annex vs Clinic (seed ${seed}, depth ${depth}): mean ${a.mean_ms.toFixed(2)} vs ${c.mean_ms.toFixed(2)} ms, p95 ${a.p95_ms.toFixed(2)} vs ${c.p95_ms.toFixed(2)} ms`);
  if (a.mean_ms > c.mean_ms * 1.05 || a.p95_ms > c.p95_ms * 1.05) failures.push('the Annex is slower than the Clinic');
}
// The renderer draws at most 256 lights a frame (project.godot limits/opengl/max_renderable_lights).
if (a) {
  const lights = a.lights + a.emergency_lights;
  console.log(`lights, Annex vs Clinic: ${a.lights} + ${a.emergency_lights} emergency vs ${c?.lights} + ${c?.emergency_lights} emergency (limit ${LIGHT_LIMIT}); at most ${report.check?.max_lights} on the ${report.check?.floors} checked Annex floors`);
  if (lights > LIGHT_LIMIT) failures.push(`the Annex has ${lights} lights, over ${LIGHT_LIMIT}`);
}
report.errors = errors;
report.failures = failures;
writeFileSync(resolve(shots, 'report.json'), JSON.stringify(report, null, 2));
console.log(failures.length ? `FAIL: ${failures.join('; ')}` : 'PASS');
process.exit(failures.length ? 1 : 0);
