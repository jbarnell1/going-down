// Packages the Windows build in play/ into a zip to hand to friends.
//   npm run godot:package
// Run npm run godot:promote first. Writes play/GoingDown-<YYYY-MM-DD-HHMM>.zip (local time of the build)
// holding GoingDown.exe and READ ME FIRST.txt (made from scripts/friends-readme.txt).
// GD_PLAY_DIR overrides the folder to read and write (default: play).
import { execFileSync } from 'node:child_process';
import { copyFileSync, existsSync, mkdtempSync, readdirSync, readFileSync, rmSync, statSync, writeFileSync } from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const play = path.resolve(root, process.env.GD_PLAY_DIR || 'play');
const exe = path.join(play, 'GoingDown.exe');
const infoFile = path.join(play, 'build.json');

if (!existsSync(exe) || !existsSync(infoFile)) {
  console.error(`Nothing to package: ${path.join(play, 'GoingDown.exe')} and ${path.join(play, 'build.json')} must both exist. Run npm run godot:promote first.`);
  process.exit(1);
}

let info;
try { info = JSON.parse(readFileSync(infoFile, 'utf8')); } catch { /* handled below */ }
const built = info && new Date(info.builtAt);
if (!built || Number.isNaN(built.getTime())) {
  console.error(`Cannot read the build date from ${infoFile}. Run npm run godot:promote again.`);
  process.exit(1);
}

const p2 = (n) => String(n).padStart(2, '0');
const stamp = `${built.getFullYear()}-${p2(built.getMonth() + 1)}-${p2(built.getDate())}-${p2(built.getHours())}${p2(built.getMinutes())}`;
const date = built.toLocaleString('en-US', { dateStyle: 'long', timeStyle: 'short' });
const commit = `${info.commit || 'unknown'}${info.uncommittedChanges ? ' (plus unfinished changes)' : ''}`;

const text = readFileSync(path.join(root, 'scripts', 'friends-readme.txt'), 'utf8')
  .replace(/\r\n/g, '\n').replaceAll('{{DATE}}', date).replaceAll('{{COMMIT}}', commit).replace(/\n/g, '\r\n');

const zip = path.join(play, `GoingDown-${stamp}.zip`);
const stage = mkdtempSync(path.join(os.tmpdir(), 'goingdown-pack-'));
try {
  copyFileSync(exe, path.join(stage, 'GoingDown.exe'));
  // The floor packs the promote step put beside the game (the Hanging Ward and the Reactor need them).
  for (const f of readdirSync(play).filter((n) => n.endsWith('.pck'))) copyFileSync(path.join(play, f), path.join(stage, f));
  writeFileSync(path.join(stage, 'READ ME FIRST.txt'), text);
  const ps = '$ErrorActionPreference = "Stop"; Compress-Archive -Path (Join-Path $env:GD_STAGE "*") -DestinationPath $env:GD_ZIP -Force';
  execFileSync('powershell.exe', ['-NoProfile', '-NonInteractive', '-Command', ps], {
    env: { ...process.env, GD_STAGE: stage, GD_ZIP: zip },
    stdio: ['ignore', 'ignore', 'inherit'],
  });
} catch (e) {
  rmSync(zip, { force: true });
  console.error(`Could not write the zip: ${e.message}`);
  process.exit(1);
} finally {
  rmSync(stage, { recursive: true, force: true });
}
console.log(`${zip}\n${(statSync(zip).size / 1048576).toFixed(1)} MB`);
