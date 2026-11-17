// First copied from the client trial on 16 Nov 2026; this file is now edited here (see godot/README.md).
// The scripted playthrough (tools/playthrough.mjs) on the Windows build. Starts
// export/windows/GoingDown.exe in a small window with `auto=1` (it never captures the mouse) and a
// test channel on 127.0.0.1, sends the same commands the browser hook takes, saves pictures through the
// game's own `shot` command (the window as drawn), and also asserts sound by measuring the audio buses
// (Master, Voice, Entity, Scare, Effects, Ambience, UI peaks). Closes the game at the end.
// Usage: node play_desktop.mjs [--port=4461] [--quality=full] [--only=first]
// Start .local/guard-mouse.ps1 beside it.
import { spawn } from 'node:child_process';
import { connect } from 'node:net';
import { dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { playthrough } from './playthrough.mjs';

const here = dirname(fileURLToPath(import.meta.url));
const arg = (k, d) => (process.argv.find((a) => a.startsWith(`--${k}=`)) ?? `--${k}=${d}`).split('=')[1];
const port = Number(arg('port', 4441));
const quality = arg('quality', 'full');
const only = arg('only', '');
const dir = resolve(here, '../export/windows');

const consoleLines = [];
const t0 = Date.now();
// quota=0 (with auto=1): no floor quota, so the playthrough's one reading is enough to call the lift.
const game = spawn(resolve(dir, 'GoingDown.exe'), ['--resolution', '960x540', '--position', '40,40', '--', 'auto=1', 'quota=0', `quality=${quality}`, `testport=${port}`], { cwd: dir, stdio: ['ignore', 'pipe', 'pipe'] });
const keep = (b) => { for (const l of b.toString().split(/\r?\n/)) if (l.trim()) consoleLines.push(l); };
game.stdout.on('data', keep);
game.stderr.on('data', keep);
let exited = false;
game.on('exit', () => { exited = true; });

// The test channel: one command per line, one reply per line.
let sock = null;
for (let i = 0; i < 200 && !sock && !exited; i++) {
  sock = await new Promise((res) => {
    const s = connect(port, '127.0.0.1', () => res(s));
    s.on('error', () => res(null));
  });
  if (!sock) await new Promise((r) => setTimeout(r, 150));
}
if (!sock) {
  console.log('could not reach the game\'s test channel', consoleLines.slice(-10));
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
// The start screen comes first: press its PLAY ALONE (the button's own code path), then the face step
// (Enter keeps the face it opens on: the editor's own key path), then ready once the run answers.
for (let i = 0; i < 200; i++) {
  if ((await cmd('ui alone')) === 'ok') break;
  await new Promise((r) => setTimeout(r, 100));
}
let faceStep = '';
for (let i = 0; i < 50 && faceStep !== 'face'; i++) {
  faceStep = JSON.parse(await cmd('screen')).screen;
  if (faceStep !== 'face') await new Promise((r) => setTimeout(r, 100));
}
if (faceStep !== 'face') console.log(`FAIL the face step did not come after PLAY ALONE (screen ${faceStep})`);
await cmd('draw done');
let ready = false;
for (let i = 0; i < 200 && !ready; i++) {
  try { ready = JSON.parse(await cmd('state')).phase !== undefined; } catch { /* not yet */ }
  if (!ready) await new Promise((r) => setTimeout(r, 100));
}
const firstFrameMs = Date.now() - t0;
console.log(`desktop ready ${firstFrameMs} ms after launch (quality ${quality})`);
await cmd('click');

await playthrough(
  {
    cmd,
    screenshot: (path) => cmd(`shot ${path}`),
    wait: (ms) => new Promise((r) => setTimeout(r, ms)),
    close: async () => {
      sock.write('quit\n');
      await new Promise((r) => setTimeout(r, 800));
      if (!exited) game.kill();
      sock.destroy();
    },
    consoleLines,
  },
  { shots: resolve(here, '../export/shots/desktop'), only, report: 'playthrough-desktop.json', firstFrameMs, busPeaks: true },
);
