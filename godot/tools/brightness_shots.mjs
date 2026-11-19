// Pictures of the brightness card (T27a) as the window draws it, at the bottom, the first step up and the
// top (and the default), for checking by eye on a real screen. Opens a game WINDOW: run it on the owner's
// PC with .local/guard-mouse.ps1 beside it, one windowed run at a time.
// Runs the game from source with the console engine (or the Windows export with --exe), `auto=1` so the
// mouse is never captured and nothing is saved, and the desktop test channel on 127.0.0.1.
// Usage: node godot/tools/brightness_shots.mjs [--port=4661] [--out=godot/export/brightness-shots] [--exe]
// The numbers behind the pictures: "$GODOT" --headless --path godot --script res://tools/brightness_table.gd
import { spawn } from 'node:child_process';
import { mkdirSync } from 'node:fs';
import { connect } from 'node:net';
import { dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const here = dirname(fileURLToPath(import.meta.url));
const arg = (k, d) => (process.argv.find((a) => a.startsWith(`--${k}=`)) ?? `--${k}=${d}`).split('=')[1];
const port = Number(arg('port', 4661));
const out = resolve(arg('out', resolve(here, '../export/brightness-shots')));
const useExe = process.argv.includes('--exe');
mkdirSync(out, { recursive: true });

const godot = process.env.GODOT ?? resolve(here, '../../tools/godot/Godot_v4.7.2-stable_win64_console.exe');
const exeDir = resolve(here, '../export/windows');
const gameArgs = ['--', 'auto=1', 'quota=0', `testport=${port}`];
const game = useExe
  ? spawn(resolve(exeDir, 'GoingDown.exe'), ['--resolution', '1280x720', '--position', '40,40', ...gameArgs], { cwd: exeDir, stdio: 'ignore' })
  : spawn(godot, ['--path', resolve(here, '..'), '--resolution', '1280x720', '--position', '40,40', ...gameArgs], { stdio: 'ignore' });
let exited = false;
game.on('exit', () => { exited = true; });

let sock = null;
for (let i = 0; i < 200 && !sock && !exited; i++) {
  sock = await new Promise((res) => {
    const s = connect(port, '127.0.0.1', () => res(s));
    s.on('error', () => res(null));
  });
  if (!sock) await new Promise((r) => setTimeout(r, 150));
}
if (!sock) {
  console.log('could not reach the game\'s test channel');
  game.kill();
  process.exit(1);
}
let buf = '';
const waiting = [];
sock.on('data', (d) => {
  buf += d.toString();
  let i;
  while ((i = buf.indexOf('\n')) >= 0) {
    const line = buf.slice(0, i);
    buf = buf.slice(i + 1);
    waiting.shift()?.(line);
  }
});
const cmd = (c) => new Promise((res) => { waiting.push(res); sock.write(c + '\n'); });
const wait = (ms) => new Promise((r) => setTimeout(r, ms));

let passed = 0;
let failed = 0;
await wait(1500);
const opened = JSON.parse(await cmd('brightness open'));
if (opened.open) passed++; else failed++;
for (const [name, level] of [['min', 0], ['first-step', 1], ['two-steps', 2], ['default', 10], ['max', 20]]) {
  const st = JSON.parse(await cmd(`brightness ${level}`));
  await wait(300);
  const file = resolve(out, `card-${name}-${level}.png`).replaceAll('\\', '/');
  const ok = (await cmd(`shot ${file}`)) === 'ok' && st.level === level;
  if (ok) passed++; else failed++;
  console.log(`  ${name} (${level}): lift ${Number(st.lift).toFixed(4)} gamma ${Number(st.gamma).toFixed(4)} -> ${ok ? file : 'FAILED'}`);
}
await cmd('brightness done');
sock.write('quit\n');
await wait(500);
if (!exited) game.kill();
console.log(`brightness shots: ${passed} passed, ${failed} failed`);
process.exit(failed ? 1 : 0);
