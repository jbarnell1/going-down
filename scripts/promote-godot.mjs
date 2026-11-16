// Copies a CHECKED Godot build to the one fixed place the owner runs it from: play/ (not in git).
//   play/GoingDown.exe      the Windows game
//   play/web/               the browser build the hub serves at /godot/
//   play/BUILD.txt          when it was built and from which commit, in plain words
// Run it only after the playthroughs passed on godot/export/ (npm run godot:export writes there):
//   npm run godot:promote -- "one line about what is new"
import { execSync } from 'node:child_process';
import { cpSync, existsSync, mkdirSync, renameSync, rmSync, statSync, writeFileSync } from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const from = path.join(root, 'godot', 'export');
const play = path.join(root, 'play');
const note = process.argv.slice(2).join(' ').trim();
const exe = path.join(from, 'windows', 'GoingDown.exe');
const web = path.join(from, 'web');
if (!existsSync(exe) || !existsSync(path.join(web, 'index.html'))) {
  console.error('No build to promote: run npm run godot:export first.');
  process.exit(1);
}
const sh = (cmd) => execSync(cmd, { cwd: root, encoding: 'utf8', stdio: ['ignore', 'pipe', 'ignore'] }).trim();
let commit = 'unknown';
let dirty = false;
try { commit = sh('git rev-parse --short HEAD'); dirty = sh('git status --porcelain -- godot').length > 0; } catch { /* not a git checkout */ }

mkdirSync(play, { recursive: true });
// The game file: copy beside the old one, then swap, so a half-written file is never the one that runs.
const target = path.join(play, 'GoingDown.exe');
const next = target + '.next';
cpSync(exe, next);
try {
  rmSync(target, { force: true });
  renameSync(next, target);
} catch (e) {
  rmSync(next, { force: true });
  console.error(`Could not replace ${target}: close the game if it is running, then run this again. (${e.code ?? e.message})`);
  process.exit(1);
}
const webNext = path.join(play, 'web.next');
rmSync(webNext, { recursive: true, force: true });
cpSync(web, webNext, { recursive: true, preserveTimestamps: true });
rmSync(path.join(play, 'web'), { recursive: true, force: true });
renameSync(webNext, path.join(play, 'web'));

const builtAt = statSync(exe).mtime;
const info = { builtAt: builtAt.toISOString(), promotedAt: new Date().toISOString(), commit, uncommittedChanges: dirty, note };
writeFileSync(path.join(play, 'build.json'), JSON.stringify(info, null, 2) + '\n');
writeFileSync(path.join(play, 'BUILD.txt'), [
  'Going Down, Windows build',
  `Built: ${builtAt.toLocaleString('en-US', { dateStyle: 'full', timeStyle: 'short' })}`,
  `From commit: ${commit}${dirty ? ' plus changes not yet committed' : ''}`,
  note ? `New in this build: ${note}` : '',
  '',
  'Run GoingDown.exe. Esc shows the controls.',
  '',
].filter((l, i, a) => l !== '' || a[i - 1] !== '').join('\r\n'));
console.log(`promoted to play/ (${commit}${dirty ? ', with uncommitted changes' : ''}), built ${builtAt.toISOString()}`);
