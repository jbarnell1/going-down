// Builds the game and puts it where the hub serves it (.live/, reachable at /play/).
// Only run this on a green build: the live link must never hold a broken one.
//   npm run deploy:live -- "one line about what is new"
import { execSync } from 'node:child_process';
import { cpSync, existsSync, mkdirSync, renameSync, rmSync, writeFileSync } from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const dist = path.join(root, 'dist');
// GD_LIVE_DIR lets a second working copy deploy to the folder the hub serves.
const live = process.env.GD_LIVE_DIR ? path.resolve(process.env.GD_LIVE_DIR) : path.join(root, '.live');
const next = live + '.next';
const old = live + '.old';
const note = process.argv.slice(2).join(' ').trim();

const sh = (cmd) => execSync(cmd, { cwd: root, encoding: 'utf8', stdio: ['ignore', 'pipe', 'inherit'] }).trim();

sh('npm run build');
if (!existsSync(path.join(dist, 'index.html'))) throw new Error('build produced no index.html');

let commit = 'unknown';
let dirty = false;
try {
  commit = sh('git rev-parse --short HEAD');
  dirty = sh('git status --porcelain').length > 0;
} catch { /* not a git checkout */ }

rmSync(next, { recursive: true, force: true });
mkdirSync(next, { recursive: true });
cpSync(dist, next, { recursive: true });
writeFileSync(path.join(next, 'version.json'), JSON.stringify({
  commit: dirty ? `${commit}+local` : commit,
  deployedAt: new Date().toISOString(),
  note,
}, null, 2));

// Swap in one step so the hub never serves a half-copied build.
rmSync(old, { recursive: true, force: true });
if (existsSync(live)) renameSync(live, old);
renameSync(next, live);
rmSync(old, { recursive: true, force: true });
console.log(`live build is now ${commit}${dirty ? ' (with uncommitted changes)' : ''}`);
