// The Prison hub walk, on the Windows build (like play_desktop.mjs). Starts
// export/windows/GoingDown.exe in a small window with `-- scene=prison_demo`, which main.gd turns into
// the scene res://client/prison_demo.tscn (a release build takes no scene path); it never captures the
// mouse. In it the rules' body walks from the lift to every bunk at walking pace and the times
// are checked against the design's ten seconds; pictures are taken from the lift doors, in the bank
// room facing the windows, at a cell, inside it and from the far end, saved to export/shots/prison/ and
// checked (the bank room must be bright and brighter than the corridor, the cell must show orange).
// Then frame times: the camera walks lift -> farthest bunk -> lift with vsync off, in the prison and on a
// Clinic floor walked as far from its lift, and the prison must be no slower.
// Usage: node godot/tools/prison_walk.mjs [--only=pictures|bench] [--bench=20] [--seed=alpha] [--editor]
//   --editor runs the engine on the project instead of the build ($GODOT, or tools/godot/ in the repo).
// Start .local/guard-mouse.ps1 beside it. Exit code 0 only if every check passes.
import { spawn } from 'node:child_process';
import { existsSync, mkdirSync, writeFileSync } from 'node:fs';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const here = dirname(fileURLToPath(import.meta.url));
const project = resolve(here, '..');
const arg = (k, d) => (process.argv.find((a) => a.startsWith(`--${k}=`)) ?? `--${k}=${d}`).split('=')[1];
const only = arg('only', '');
const benchSecs = Number(arg('bench', 20));
const seed = arg('seed', 'alpha');
const editor = process.argv.includes('--editor');
const shots = resolve(project, 'export/shots/prison');
mkdirSync(shots, { recursive: true });

function command() {
  if (editor) {
    const godot = process.env.GODOT || resolve(project, '..', 'tools', 'godot', 'Godot_v4.7.2-stable_win64_console.exe');
    return { exe: godot, pre: ['--path', project], cwd: project };
  }
  const dir = resolve(project, 'export/windows');
  const exe = join(dir, 'GoingDown.exe');
  if (!existsSync(exe)) {
    console.log(`no build at ${exe}: run npm run godot:export -- windows, or pass --editor`);
    process.exit(1);
  }
  return { exe, pre: [], cwd: dir };
}

/** One run of the demo scene; resolves with its exit code and its "prison_demo:" lines. */
function demo(userArgs, seconds = 240) {
  const { exe, pre, cwd } = command();
  const args = [...pre, '--resolution', '960x540', '--position', '40,40', '--', 'scene=prison_demo', `shots=${shots}`, ...userArgs];
  return new Promise((res) => {
    const lines = [];
    const other = [];
    const game = spawn(exe, args, { cwd, stdio: ['ignore', 'pipe', 'pipe'] });
    const keep = (b) => {
      for (const l of b.toString().split(/\r?\n/)) {
        if (l.startsWith('prison_demo: ')) lines.push(l.slice(13));
        else if (/ERROR|SCRIPT ERROR/.test(l)) other.push(l);
      }
    };
    game.stdout.on('data', keep);
    game.stderr.on('data', keep);
    const timer = setTimeout(() => { other.push(`timed out after ${seconds} s`); game.kill(); }, seconds * 1000);
    game.on('error', (e) => { clearTimeout(timer); res({ code: 1, lines, errors: [`could not start ${exe}: ${e.message}`] }); });
    game.on('exit', (code) => { clearTimeout(timer); res({ code: code ?? 1, lines, errors: other }); });
  });
}

const report = { build: editor ? 'editor' : 'export/windows/GoingDown.exe', checks: [], walk: [], bench: {} };
let ok = true;

if (only !== 'bench') {
  const r = await demo([]);
  for (const l of r.lines) console.log(`  ${l}`);
  for (const l of r.errors.slice(0, 10)) console.log(`  ! ${l}`);
  report.walk = r.lines.filter((l) => l.startsWith('walk'));
  report.checks = r.lines.filter((l) => l.startsWith('check'));
  report.pictures = r.lines.filter((l) => l.startsWith('picture')).map((l) => l.split(' ')[1]);
  if (r.code !== 0 || r.errors.length > 0) ok = false;
  console.log(`pictures and walk: ${r.code === 0 && r.errors.length === 0 ? 'PASS' : 'FAIL'}`);
}

if (only !== 'pictures') {
  const parse = (lines) => {
    const l = lines.find((x) => x.startsWith('bench '));
    if (!l) return null;
    const o = {};
    for (const kv of l.slice(6).split(' ')) {
      const [k, v] = kv.split('=');
      o[k] = Number.isNaN(Number(v)) ? v : Number(v);
    }
    return o;
  };
  for (const place of ['prison', 'clinic']) {
    const r = await demo([`place=${place}`, `bench=${benchSecs}`, `seed=${seed}`], benchSecs + 120);
    for (const l of r.errors.slice(0, 10)) console.log(`  ! ${l}`);
    report.bench[place] = parse(r.lines);
    const b = report.bench[place];
    if (!b) { ok = false; console.log(`bench ${place}: no result`); continue; }
    console.log(`bench ${place}: ${b.frames} frames, mean ${b.mean_ms.toFixed(3)} ms, p95 ${b.p95_ms.toFixed(3)} ms, max ${b.max_ms.toFixed(3)} ms, ${b.draw_calls} draw calls (${b.renderer})`);
  }
  const p = report.bench.prison;
  const c = report.bench.clinic;
  if (p && c) {
    // "No worse": the prison's mean and 95th percentile within 5% (timer noise) of the Clinic's, or better.
    const fine = p.mean_ms <= c.mean_ms * 1.05 && p.p95_ms <= c.p95_ms * 1.05;
    report.frameVerdict = fine ? 'PASS' : 'FAIL';
    if (!fine) ok = false;
    console.log(`frame time prison vs clinic: mean ${p.mean_ms.toFixed(3)} vs ${c.mean_ms.toFixed(3)} ms, p95 ${p.p95_ms.toFixed(3)} vs ${c.p95_ms.toFixed(3)} ms: ${report.frameVerdict}`);
  }
}

writeFileSync(join(shots, 'report.json'), JSON.stringify(report, null, 2));
console.log(`prison walk: ${ok ? 'PASS' : 'FAIL'} (report ${join(shots, 'report.json')})`);
process.exit(ok ? 0 : 1);
