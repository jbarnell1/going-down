// The Playroom's look and the Minder (the Blender model, assets/entities/minder.glb), checked against
// the rules. Two runs with the engine in
// GODOT (or tools/godot/Godot_v4.7.2-stable_win64_console.exe under the repository root) on this
// project, so no export is needed:
//   1. headless, tools/playroom_look_check.gd on 40 floors (play-0..9 at depths 1 to 4): every hide's
//      furniture within 5 cm of its Playroom.hides spot, every squeaker tile in the rules drawn and no
//      other, every zone's signs reading its hide count from the rules, the lights under the limit,
//      the count-dark switch;
//   2. in a small window, client/playroom_demo.tscn: the same on 13 floors; the Minder's clips (every
//      pose the rules set has one, a new pose starts its clip at 0 and fades in, the gaits run on the
//      distance walked); its figure as posed (about 2.3 m as built, the mask on the front, under
//      1.6 m running on all fours, both hands on the mask counting); its pose hold off; its music box
//      heard to 30 m; its mask readable in count dark at 10 m; pictures to export/shots/playroom/;
//      and frame times walking the Playroom, the Minder prowling ahead, against a Clinic of the same
//      seed and depth.
// Writes export/shots/playroom/report.json. Exits non-zero if a check fails, a run does not finish,
// or the engine printed an error. The window never captures the mouse; start
// .local/guard-mouse.ps1 beside it anyway.
// Usage: node playroom_walk.mjs [--seed=play-1] [--depth=4] [--bench=5] [--rounds=2] [--floors=40]
//          [--break=sign|squeak] [--minder-break=clip|hold] [--window=0]
//   --break=sign   guesses each sign's number from its zone's kind (PlayroomView.test_break): must fail
//   --break=squeak leaves one squeaker tile out: must fail
//   --minder-break=clip  maps the look pose to a clip the model does not have: the clips check must fail
//   --minder-break=hold  draws the held pose handed in: the hold check must fail (clip+hold: both)
//   --window=0     only the headless check
import { spawn } from 'node:child_process';
import { mkdirSync, writeFileSync } from 'node:fs';
import { dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const here = dirname(fileURLToPath(import.meta.url));
const arg = (k, d) => (process.argv.find((a) => a.startsWith(`--${k}=`)) ?? `--${k}=${d}`).split('=')[1];
const seed = arg('seed', 'play-1');
const depth = arg('depth', '4');
const bench = arg('bench', '5');
const rounds = arg('rounds', '2');
const floors = arg('floors', '40');
const brk = arg('break', '');
const minderBrk = arg('minder-break', '');
const windowed = arg('window', '1') !== '0';
const project = resolve(here, '..');
const godot = process.env.GODOT || resolve(here, '../../tools/godot/Godot_v4.7.2-stable_win64_console.exe');
const shots = resolve(here, '../export/shots/playroom');
mkdirSync(shots, { recursive: true });

function run(args, prefix, seconds) {
  return new Promise((res) => {
    const lines = [];
    const game = spawn(godot, args, { stdio: ['ignore', 'pipe', 'pipe'] });
    const keep = (b) => {
      for (const l of b.toString().split(/\r?\n/)) {
        if (!l.trim()) continue;
        lines.push(l);
        if ((l.startsWith(prefix) && !l.includes(' json: ')) || l.startsWith('  ') || /ERROR/.test(l)) console.log(l);
      }
    };
    game.stdout.on('data', keep);
    game.stderr.on('data', keep);
    const timer = setTimeout(() => { console.log('timed out'); game.kill(); }, seconds * 1000);
    game.on('exit', (c) => { clearTimeout(timer); res({ code: c ?? 1, lines }); });
  });
}

const failures = [];
const report = { seed, depth, break: brk, minderBreak: minderBrk };
const errorsIn = (lines) => lines.filter((l) => /\b(SCRIPT ERROR|ERROR)\b/.test(l));

const head = ['--headless', '--path', project, '--script', 'res://tools/playroom_look_check.gd', '--', `floors=${floors}`];
if (brk) head.push(`break=${brk}`);
const h = await run(head, 'playroom look check', 600);
const summary = h.lines.find((l) => l.startsWith('playroom look check: '));
report.headless = { summary, problems: h.lines.filter((l) => l.startsWith('  ')), code: h.code };
if (!summary) failures.push('the headless check did not finish');
else if (!summary.includes(': PASS,')) failures.push(`headless: ${summary.slice('playroom look check: '.length)}`);
if (h.code !== 0 && summary?.includes(': PASS,')) failures.push(`headless exit code ${h.code}`);
if (errorsIn(h.lines).length) failures.push(`headless: ${errorsIn(h.lines).length} engine error line(s)`);

if (windowed) {
  const args = ['--path', project, '--resolution', '960x540', '--position', '40,40', 'res://client/playroom_demo.tscn', '--',
    `shots=${shots.replaceAll('\\', '/')}`, `seed=${seed}`, `depth=${depth}`, `bench=${bench}`, `rounds=${rounds}`];
  if (brk) args.push(`break=${brk}`);
  if (minderBrk) args.push(`minder_break=${minderBrk}`);
  const w = await run(args, 'playroom demo:', 400);
  const jsonLine = w.lines.find((l) => l.startsWith('playroom demo json: '));
  const demo = jsonLine ? JSON.parse(jsonLine.slice('playroom demo json: '.length)) : {};
  report.demo = demo;
  if (!jsonLine) failures.push('the demo did not finish');
  if (w.code !== 0) failures.push(`demo exit code ${w.code}`);
  for (const p of demo.problems ?? []) failures.push(p.length > 300 ? `${p.slice(0, 300)}...` : p);
  for (const s of demo.shots ?? []) if (/FAILED/.test(s)) failures.push(`picture ${s}`);
  if (errorsIn(w.lines).length) failures.push(`demo: ${errorsIn(w.lines).length} engine error line(s)`);
  const p = demo.bench_playroom;
  const c = demo.bench_clinic;
  if (p && c) {
    console.log(`frame time, Playroom vs Clinic (seed ${seed}, depth ${depth}): mean ${p.mean_ms.toFixed(2)} vs ${c.mean_ms.toFixed(2)} ms, p95 ${p.p95_ms.toFixed(2)} vs ${c.p95_ms.toFixed(2)} ms`);
    console.log(`real lights, Playroom vs Clinic: ${p.lights} + ${p.emergency_lights} emergency vs ${c.lights} + ${c.emergency_lights} emergency (limit 256)`);
  }
}
report.failures = failures;
const tag = [brk, minderBrk && `minder_${minderBrk}`].filter(Boolean).join('_');
writeFileSync(resolve(shots, tag ? `report_break_${tag}.json` : 'report.json'), JSON.stringify(report, null, 2));
console.log(failures.length ? `PLAYROOM WALK FAILED: ${failures.join('; ')}` : `PLAYROOM WALK PASSED (pictures in ${shots})`);
process.exit(failures.length ? 1 : 0);
