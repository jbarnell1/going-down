// Game night's hotfix, in one command, after the fix is committed:
//   node godot/tools/hotfix.mjs "what the fix is"            the whole chain, stopping at the first failure
//   node godot/tools/hotfix.mjs --dry-run "what the fix is"  print the steps and the deploy commands only
// Steps:
//   clean      godot/ and scripts/ have nothing uncommitted (the build id is the commit: net/build_info.gd)
//   tests      the quick test set (npm run godot:test -- --quick) and the night log summary's own test
//   export     npm run godot:export (writes the build id, imports, exports the web build and GoingDown.exe)
//   play_web   the browser playthrough on the new web build (a local static server, headless Chromium)
//   play_down  the down-then-out check, two game processes, no windows (--headless=1)
//   net_local  the network end to end: the server, three players, the probes, the night's log
//   play_late  floors 6 and 7 with two players on the real server, quick (node godot/tools/play_late.mjs --quick=1): the Ward
//              and the Reactor, then the old rooms' fallback; passes when the screens and the host agree. Skipped,
//              said loudly, when the private floor packs are not there (a fresh clone)
//   promote    npm run godot:promote -- "<note>"   (play/GoingDown.exe, play/web/)
//   package    npm run godot:package               (play/GoingDown-<time>.zip for the friends)
//   server     node godot/tools/godot.mjs export server  (godot/export/server/GoingDownServer.x86_64)
//   exported   node godot/tools/exported_server_check.mjs: the EXPORTED builds, not the project folder: the
//              Windows exe as a server from a folder holding only the exe (it must read its data, take a
//              player and post the Annex's sticky notes), and every data file inside the Linux server's pack
// Then it PRINTS the commands that put the new server on the lab box. It never runs them: deploying is
// done by hand. The box is named by the environment variable GD_LAB_SSH (USER@HOST) and the folder there
// by GD_LAB_DIR (default going-down); neither is ever written into the repository.
// Options: --web-port=4440 --down-port=4466 --net-port=4451 --late-port=4770 --exported-port=4492 (the playthroughs' ports;
// play_late takes the ten from --late-port), --skip=a,b (leave
// steps out, said loudly), and for checking this script itself: --stub=a,b|all (a step prints instead of
// running), --fail-at=STEP (that stub fails).
import { spawn, spawnSync } from 'node:child_process';
import { existsSync, readdirSync, readFileSync, statSync } from 'node:fs';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const here = dirname(fileURLToPath(import.meta.url));
const root = resolve(here, '..', '..');
const argv = process.argv.slice(2);
const flag = (name, def) => {
  const a = argv.find((x) => x === `--${name}` || x.startsWith(`--${name}=`));
  return a === undefined ? def : a.includes('=') ? a.slice(a.indexOf('=') + 1) : true;
};
const dryRun = flag('dry-run', false) === true;
const list = (v) => (typeof v === 'string' ? v.split(',').map((s) => s.trim()).filter(Boolean) : []);
const stubs = list(flag('stub', ''));
const skips = list(flag('skip', ''));
const failAt = flag('fail-at', '');
const webPort = Number(flag('web-port', 4440));
const downPort = Number(flag('down-port', 4466));
const netPort = Number(flag('net-port', 4451));
const exportedPort = Number(flag('exported-port', 4492));
const latePort = Number(flag('late-port', 4770));
const packsDir = process.env.GD_PACKS_DIR || join(root, '.local', 'floor-packs');
const note = argv.filter((a) => !a.startsWith('--')).join(' ').trim();
const node = process.execPath;
const sshTarget = process.env.GD_LAB_SSH || 'USER@HOST';
const boxDir = process.env.GD_LAB_DIR || 'going-down';

if (!note && !dryRun) {
  console.error('usage: node godot/tools/hotfix.mjs [--dry-run] "one line about the fix" (it goes in play/BUILD.txt)');
  process.exit(2);
}

/** Runs a command with its output shown; resolves to the exit code. */
function run(cmd, args, opts = {}) {
  return new Promise((res) => {
    // Never through a shell: the note is passed as it is, whatever it holds.
    const p = spawn(cmd, args, { cwd: root, stdio: 'inherit', env: { ...process.env, ...(opts.env ?? {}) } });
    p.on('error', (e) => { console.error(e.message); res(1); });
    p.on('exit', (code) => res(code ?? 1));
  });
}

/** The browser playthrough needs the web build served: a static server for the length of the check. */
async function playWeb() {
  const srv = spawn(node, [join(here, 'serve.mjs'), join('godot', 'export', 'web'), String(webPort)], { cwd: root, stdio: ['ignore', 'pipe', 'inherit'] });
  await new Promise((res) => { srv.stdout.on('data', (d) => { if (String(d).includes('serving')) res(); }); srv.on('exit', res); setTimeout(res, 5000); });
  try {
    return await run(node, [join(here, 'play_web.mjs'), String(webPort)]);
  } finally {
    srv.kill();
  }
}

/** PL2: floors 6 and 7 over the network, quick. The floor packs are private: on a fresh clone the step is skipped. */
async function playLate() {
  if (!existsSync(join(packsDir, 'WardGroundMedia.pck'))) {
    console.log(`      SKIPPED play_late: no private floor packs at ${packsDir} (a fresh clone; set GD_PACKS_DIR to check floors 6 and 7)`);
    return 0;
  }
  return run(node, [join(here, 'play_late.mjs'), '--quick=1', `--port=${latePort}`, `--packs=${packsDir}`]);
}

function changes() {
  const st = spawnSync('git', ['status', '--porcelain', '--', 'godot', 'scripts'], { cwd: root, encoding: 'utf8' });
  if (st.status !== 0) return ['(not a git checkout)'];
  return st.stdout.split(/\r?\n/).filter((l) => l.trim() && !l.endsWith('godot/default_bus_layout.tres'));
}

const steps = [
  ['clean', 'nothing uncommitted under godot/ or scripts/', async () => {
    const c = changes();
    if (c.length) {
      console.error(`Commit the fix first (the build id is the commit). Uncommitted:\n  ${c.slice(0, 20).join('\n  ')}`);
      return 1;
    }
    const head = spawnSync('git', ['log', '-1', '--format=%h %s'], { cwd: root, encoding: 'utf8' });
    console.log(`at ${head.stdout.trim()}`);
    return 0;
  }],
  ['tests', 'npm run godot:test -- --quick; node godot/tools/night_logs.test.mjs', async () => {
    const code = await run(node, [join(here, 'godot.mjs'), 'test', '--quick']);
    return code !== 0 ? code : run(node, [join(here, 'night_logs.test.mjs')]);
  }],
  ['export', 'npm run godot:export', () => run(node, [join(here, 'godot.mjs'), 'export'])],
  ['play_web', `node godot/tools/serve.mjs godot/export/web ${webPort} & node godot/tools/play_web.mjs ${webPort}`, playWeb],
  ['play_down', `node godot/tools/play_down.mjs --headless=1 --port=${downPort}`, () => run(node, [join(here, 'play_down.mjs'), '--headless=1', `--port=${downPort}`])],
  ['net_local', `node godot/tools/net_local.mjs ${netPort}`, () => run(node, [join(here, 'net_local.mjs'), String(netPort)])],
  ['play_late', `node godot/tools/play_late.mjs --quick=1 --port=${latePort} (packs: ${packsDir})`, playLate],
  ['promote', `npm run godot:promote -- "${note}"`, () => run(node, [join(root, 'scripts', 'promote-godot.mjs'), note])],
  ['package', 'npm run godot:package', () => run(node, [join(root, 'scripts', 'package-godot.mjs')])],
  ['server', 'node godot/tools/godot.mjs export server', () => run(node, [join(here, 'godot.mjs'), 'export', 'server'])],
  ['exported', `node godot/tools/exported_server_check.mjs --port=${exportedPort}`, () => run(node, [join(here, 'exported_server_check.mjs'), `--port=${exportedPort}`])],
];
for (const s of [...stubs, ...skips, ...(failAt ? [failAt] : [])]) {
  if (s !== 'all' && !steps.some(([name]) => name === s)) {
    console.error(`no step named ${s}; the steps are ${steps.map(([n]) => n).join(', ')}`);
    process.exit(2);
  }
}

function buildId() {
  const f = join(root, 'godot', 'build_id.gd');
  const m = existsSync(f) ? /BUILD := "([^"]+)"/.exec(readFileSync(f, 'utf8')) : null;
  return m ? m[1] : '(written by the export)';
}

function newestZip() {
  const play = join(root, 'play');
  if (!existsSync(play)) return 'play/GoingDown-<time>.zip';
  const zips = readdirSync(play).filter((f) => /^GoingDown-.*\.zip$/.test(f)).sort((a, b) => statSync(join(play, b)).mtimeMs - statSync(join(play, a)).mtimeMs);
  return zips.length ? join('play', zips[0]) : 'play/GoingDown-<time>.zip';
}

function deployText() {
  const files = ['godot/export/server/GoingDownServer.x86_64', 'godot/server/Dockerfile.scratch', 'godot/server/build-on-host.sh', 'godot/server/run-on-host.sh'];
  return [
    '',
    `Deploy by hand (build ${buildId()}). ${sshTarget === 'USER@HOST' ? 'Set GD_LAB_SSH=USER@HOST first, or replace USER@HOST below.' : ''}`,
    '  1. Save tonight\'s logs first (run-on-host.sh removes the old container, and its logs with it):',
    `       node godot/tools/night_logs.mjs --ssh ${sshTarget}`,
    '  2. Copy the new server and its scripts to the box:',
    `       scp ${files.join(' ')} ${sshTarget}:${boxDir}/`,
    '  3. Build the image and restart the server there (players in a run are dropped; they rejoin):',
    `       ssh ${sshTarget} "cd ${boxDir} && sh build-on-host.sh && sh run-on-host.sh"`,
    '  4. Check it is the new build:',
    `       ssh ${sshTarget} "docker logs going-down 2>&1 | grep -m1 listening"`,
    `  5. Send the friends ${newestZip()}: an old GoingDown.exe is now refused with "Your game is out of date".`,
  ].join('\n');
}

console.log(`Hotfix${note ? `: ${note}` : ''}${dryRun ? ' (dry run: nothing is run)' : ''}`);
const t0 = Date.now();
for (const [i, [name, what, fn]] of steps.entries()) {
  const label = `[${i + 1}/${steps.length}] ${name}: ${what}`;
  if (skips.includes(name)) {
    console.log(`${label}\n      SKIPPED (--skip)`);
    continue;
  }
  if (dryRun) {
    console.log(label);
    continue;
  }
  console.log(`\n${label}`);
  const s0 = Date.now();
  let code;
  if (stubs.includes(name) || stubs.includes('all')) {
    code = failAt === name ? 1 : 0;
    console.log(`      (stub: ${code === 0 ? 'passes' : 'fails'})`);
  } else {
    code = await fn();
  }
  if (code !== 0) {
    console.error(`\nSTOPPED at ${name} (exit ${code}) after ${((Date.now() - s0) / 1000).toFixed(0)} s. Nothing after it ran; fix it and run the hotfix again.`);
    process.exit(1);
  }
  console.log(`      ${name} passed in ${((Date.now() - s0) / 1000).toFixed(0)} s`);
}
if (!dryRun) console.log(`\nEvery step passed in ${((Date.now() - t0) / 60000).toFixed(1)} min.${stubs.length || skips.length ? ` (stubbed: ${stubs.join(', ') || 'none'}; skipped: ${skips.join(', ') || 'none'})` : ''}`);
console.log(deployText());
