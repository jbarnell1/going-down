// RW1: the Rigger on the Hanging Ward, played alone through the test channel, headless. The game is started with
// `auto=1 testport=P`, HOST PLAYTEST takes it to floor 6 (the Ward as a normal level), and then the same commands a
// person would type to look at him in a real window:
//   wardhouse <house> [spot]   stand in a house (alone only)
//   wardbring                  a noise where the player stands, heard as a flare's burst is (alone only)
//   state                      .rigger: encounter, house, drawn, where, clip, lamp
//   wardlook hand|head         the camera on him
// It checks he is heard before he is drawn (the loaded line's event before the first frame he is drawn, his lamp off
// until then), that he comes to the player's house, the clips (the climb, then the hang while he searches), and the
// camera's aim. Prints each check and a last line with the passed and failed counts.
//   node godot/tools/play_rigger.mjs [--port=4862] [--house=1] [--spot=corner] [--shots=<folder>]
// With --shots, `shot` saves the window at a few moments (a real window only: headless has no picture).
import { spawn } from 'node:child_process';
import { connect } from 'node:net';
import { dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const here = dirname(fileURLToPath(import.meta.url));
const root = resolve(here, '../..');
const project = resolve(root, 'godot');
const arg = (k, d) => (process.argv.find((a) => a.startsWith(`--${k}=`)) ?? `--${k}=${d}`).split('=').slice(1).join('=');
const port = Number(arg('port', 4862));
const house = arg('house', '1');
const spot = arg('spot', 'corner');
const shots = arg('shots', '');
const godot = process.env.GODOT || resolve(root, 'tools/godot/Godot_v4.7.2-stable_win64_console.exe');
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

let passed = 0;
let failed = 0;
const check = (ok, what, detail = '') => {
  if (ok) passed++; else failed++;
  console.log(`${ok ? 'PASS' : 'FAIL'} ${what}${detail ? ` (${detail})` : ''}`);
};

const lines = [];
const game = spawn(godot, ['--headless', '--path', project, '--', 'auto=1', `testport=${port}`], { cwd: root, stdio: ['ignore', 'pipe', 'pipe'] });
const keep = (b) => { for (const l of String(b).split(/\r?\n/)) if (l.trim()) lines.push(l); };
game.stdout.on('data', keep);
game.stderr.on('data', keep);
let exited = false;
game.on('exit', () => { exited = true; });
const finish = (code) => { try { game.kill(); } catch { /* gone */ } console.log(`play_rigger: ${passed} passed, ${failed} failed`); process.exit(code); };

let sock = null;
for (let i = 0; i < 300 && !sock && !exited; i++) {
  sock = await new Promise((res) => { const s = connect(port, '127.0.0.1', () => res(s)); s.on('error', () => res(null)); });
  if (!sock) await sleep(150);
}
if (!sock) { console.log('no test channel', lines.slice(-8).join(' | ')); failed++; finish(1); }
let buf = '';
const waiting = [];
sock.on('data', (d) => { buf += d; let i; while ((i = buf.indexOf('\n')) >= 0) { const l = buf.slice(0, i); buf = buf.slice(i + 1); waiting.shift()?.(l); } });
let chain = Promise.resolve();
const cmd = (c) => { const run = chain.then(() => new Promise((res) => { waiting.push(res); sock.write(c + '\n'); })); chain = run.catch(() => {}); return run; };
const json = async (c) => { try { return JSON.parse(await cmd(c)); } catch { return {}; } };
const until = async (fn, ok, ms, every = 100) => { const end = Date.now() + ms; let v; while (Date.now() < end) { v = await fn(); if (ok(v)) return v; await sleep(every); } return v; };

try {
  // The title, then HOST PLAYTEST, then FLOOR 6.
  await until(() => json('screen'), (s) => s.screen === 'title', 20000);
  await cmd('ui playtest');
  const picker = await until(() => json('screen'), (s) => s.screen === 'playtest', 5000);
  check(picker.screen === 'playtest', 'HOST PLAYTEST opens the floor picker', picker.screen);
  await cmd('ui 6');
  let s = await until(() => json('state'), (x) => x.rigger && x.depth === 6, 60000, 250);
  check(s.rigger != null && s.depth === 6, 'floor 6 is the Hanging Ward, drawn in the game', `depth ${s.depth}, place ${s.place}`);
  if (!s.rigger) throw new Error('no Ward');
  await cmd('click');
  check(s.rigger.drawn === false && s.rigger.lamp === false, 'before anything is heard he is not drawn and his lamp is off', JSON.stringify(s.rigger));
  const refused = await cmd('wardhouse 99');
  check(refused.includes('"ok":false'), 'a house that is not there is refused', refused);
  const placed = await json(`wardhouse ${house} ${spot}`);
  check(placed.ok === true && placed.clear === true, `wardhouse puts the player in house ${house} at its ${spot}`, JSON.stringify(placed));
  s = await until(() => json('state'), (x) => x.rigger?.phase === 'away', 15000, 200);
  check(s.rigger?.phase === 'away', 'the lift leaves once nobody is in it', s.rigger?.phase);
  const early = await json('wardbring');
  check(early.ok === true && early.queued === true, 'wardbring queues a noise where the player stands', JSON.stringify(early));
  // Every frame until he searches: when the line loads (its event) and when he is first drawn.
  let heardAt = null;
  let drawnAt = null;
  let litBeforeHeard = false;
  let drawnBeforeHeard = false;
  const clips = new Set();
  const end = Date.now() + 20000;
  while (Date.now() < end) {
    const x = await json('state');
    const r = x.rigger || {};
    const late = await json('late');
    const loaded = (late.events || []).find((e) => e.type === 'ward_line_loaded');
    if (loaded && heardAt === null) heardAt = x.hostNow;
    if (r.drawn && drawnAt === null) drawnAt = x.hostNow;
    if (r.drawn && heardAt === null) drawnBeforeHeard = true;
    if (r.lamp && heardAt === null) litBeforeHeard = true;
    if (r.drawn) clips.add(`${r.encounter}:${r.clip}`);
    if (r.encounter === 'searching' && r.drawn && r.handDrawn) { s = x; break; }
    await sleep(40);
  }
  check(heardAt !== null, 'the loaded line is heard (its event reached the screen)', `host ${heardAt}`);
  check(drawnAt !== null && !drawnBeforeHeard && drawnAt >= heardAt, 'he is heard before he is drawn', `heard ${heardAt}, drawn ${drawnAt}`);
  check(!litBeforeHeard, 'his lamp is never lit before the line is heard');
  check(s.rigger?.encounter === 'searching' && String(s.rigger?.house) === String(placed.house), `he searches house ${placed.house}, the player's`, JSON.stringify(s.rigger));
  // RR1: the crawling Rigger (on by default; rigger_roam=0 brings back the one who climbs straight up) plays "climb" as
  // he crawls his graph; the clinging one held "Rigger Climb" on his line.
  check(clips.has('climbing:Rigger Climb') || clips.has('climbing:climb'), 'he climbs with a climb clip', [...clips].join(', '));
  check(s.rigger?.clip === 'hang', 'he hangs (the hang clip) while he searches', s.rigger?.clip);
  check(s.rigger?.lamp === true, 'his lamp is lit while he is drawn');
  const look = await json('wardlook hand');
  const after = await json('state');
  const cam = after.camPos || [0, 0, 0];
  const at = look.at || [0, 0, 0];
  const want = Math.atan2(-(at[0] - cam[0]), -(at[2] - cam[2]));
  const yawOff = Math.abs(Math.atan2(Math.sin(after.client.yaw - want), Math.cos(after.client.yaw - want)));
  check(look.ok === true && yawOff < 0.2, 'wardlook hand turns the camera onto his hand', `yaw off by ${yawOff.toFixed(3)} rad`);
  if (shots) {
    await cmd(`shot ${resolve(shots, 'play-rigger-hand.png')}`);
    await cmd('wardlook head');
    await sleep(300);
    await cmd(`shot ${resolve(shots, 'play-rigger-head.png')}`);
  }
  finish(failed === 0 ? 0 : 1);
} catch (e) {
  console.log(`FAIL ${e.message}`, lines.slice(-8).join(' | '));
  failed++;
  finish(1);
}
