// The Temp's checks (client/temp_demo.gd): runs the demo scene in a small window with the engine in
// GODOT (or tools/godot/Godot_v4.7.2-stable_win64_console.exe under the repository root) on this
// project, so no export is needed. The demo builds a seeded Annex floor, checks the face on the paper,
// the pose hold, the stapler clicks, the height and the frame time, and saves pictures to
// export/shots/temp/. Writes export/shots/temp/report.json. Exits non-zero if a check fails, the demo
// does not finish, or the engine printed an error. It never captures the mouse; start
// .local/guard-mouse.ps1 beside it anyway.
// Usage: node temp_check.mjs [--seed=annex-1] [--depth=3] [--bench=3] [--break=walk]
//   --break=walk advances the walk while seen (temp_view.gd break_walk_while_seen): the hold check must fail.
import { spawn } from 'node:child_process';
import { mkdirSync, writeFileSync } from 'node:fs';
import { dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const here = dirname(fileURLToPath(import.meta.url));
const arg = (k, d) => (process.argv.find((a) => a.startsWith(`--${k}=`)) ?? `--${k}=${d}`).split('=')[1];
const seed = arg('seed', 'annex-1');
const depth = arg('depth', '3');
const bench = arg('bench', '3');
const brk = arg('break', '');
const project = resolve(here, '..');
const godot = process.env.GODOT || resolve(here, '../../tools/godot/Godot_v4.7.2-stable_win64_console.exe');
const shots = resolve(here, '../export/shots/temp');
mkdirSync(shots, { recursive: true });

const args = ['--path', project, '--resolution', '960x540', '--position', '40,40', 'res://client/temp_demo.tscn', '--',
  `shots=${shots.replaceAll('\\', '/')}`, `seed=${seed}`, `depth=${depth}`, `bench=${bench}`];
if (brk) args.push(`break=${brk}`);
const lines = [];
const game = spawn(godot, args, { stdio: ['ignore', 'pipe', 'pipe'] });
const keep = (b) => {
  for (const l of b.toString().split(/\r?\n/)) {
    if (!l.trim()) continue;
    lines.push(l);
    if ((l.startsWith('temp demo:') && !l.startsWith('temp demo json')) || /ERROR/.test(l)) console.log(l);
  }
};
game.stdout.on('data', keep);
game.stderr.on('data', keep);
const timer = setTimeout(() => { console.log('timed out'); game.kill(); }, 300_000);
const code = await new Promise((res) => game.on('exit', (c) => res(c ?? 1)));
clearTimeout(timer);

const jsonLine = lines.find((l) => l.startsWith('temp demo json: '));
const report = jsonLine ? JSON.parse(jsonLine.slice('temp demo json: '.length)) : {};
const errors = lines.filter((l) => /\b(SCRIPT ERROR|ERROR)\b/.test(l));
const failures = [];
if (!jsonLine) failures.push('the demo did not finish');
if (code !== 0) failures.push(`exit code ${code}`);
for (const p of report.problems ?? []) failures.push(p);
if (errors.length) failures.push(`${errors.length} engine error line(s)`);
writeFileSync(resolve(shots, brk ? `report_break_${brk}.json` : 'report.json'), JSON.stringify({ ...report, failures }, null, 2));
console.log(failures.length ? `TEMP CHECK FAILED: ${failures.join('; ')}` : `TEMP CHECK PASSED (pictures in ${shots})`);
process.exit(failures.length ? 1 : 0);
