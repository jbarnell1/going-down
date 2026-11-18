// Pictures of the Arboretum at game resolution through the tape filter, from one game played alone that starts
// on floor 5 (`floor=5 auto=1 quota=0`): the pavilion and its gravel apron lit, a landmark's lamp pool seen
// from the dark, moss against litter in lamp light, and the blackout (only the gravel and the near light).
// The Groundskeeper's pictures (coming, the lean) are tools/play_arboretum.mjs's, from a player's own screen.
// Windowed only: start .local/guard-mouse.ps1 beside it. Pictures in export/shots/arboretum/.
//   node godot/tools/garden_shots.mjs [--port=4478] [--seed=garden-1] [--size=1280x720]
import { spawn } from 'node:child_process';
import { existsSync, mkdirSync } from 'node:fs';
import { connect } from 'node:net';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const here = dirname(fileURLToPath(import.meta.url));
const project = resolve(here, '..');
const root = resolve(project, '..');
const arg = (k, d) => (process.argv.find((a) => a.startsWith(`--${k}=`)) ?? `--${k}=${d}`).split('=')[1];
const port = Number(arg('port', 4478));
const seed = arg('seed', 'garden-1');
const size = arg('size', '1280x720');
if (!(port >= 4460 && port <= 4479)) throw new Error(`port ${port} is outside 4460-4479`);
const godot = process.env.GODOT || join(root, 'tools', 'godot', 'Godot_v4.7.2-stable_win64_console.exe');
if (!existsSync(godot)) throw new Error(`no engine at ${godot}: set GODOT`);
const shots = resolve(project, 'export', 'shots', 'arboretum');
mkdirSync(shots, { recursive: true });
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

const game = spawn(godot, ['--path', project, '--resolution', size, '--position', '60,60', '--', 'auto=1', `testport=${port}`, `seed=${seed}`, 'floor=5', 'quota=0'], { cwd: root, stdio: ['ignore', 'pipe', 'pipe'] });
const lines = [];
game.stdout.on('data', (b) => lines.push(...String(b).split(/\r?\n/)));
game.stderr.on('data', (b) => lines.push(...String(b).split(/\r?\n/)));
process.on('exit', () => { try { game.kill(); } catch { /* gone */ } });
let sock = null;
for (let i = 0; i < 300 && !sock; i++) {
  sock = await new Promise((res) => { const s = connect(port, '127.0.0.1', () => res(s)); s.on('error', () => res(null)); });
  if (!sock) await sleep(150);
}
if (!sock) { console.log('no test channel', lines.slice(-8)); process.exit(1); }
let buf = '';
const waiting = [];
sock.on('data', (d) => { buf += d; let i; while ((i = buf.indexOf('\n')) >= 0) { const l = buf.slice(0, i); buf = buf.slice(i + 1); waiting.shift()?.(l); } });
const cmd = (c) => new Promise((res) => { waiting.push(res); sock.write(c + '\n'); });
const state = async () => JSON.parse(await cmd('state'));
async function until(fn, pred, ms = 30000, every = 80) {
  const end = Date.now() + ms;
  let v = await fn();
  while (!pred(v) && Date.now() < end) { await sleep(every); v = await fn(); }
  return v;
}
const shot = async (name) => { await sleep(900); console.log(`shot ${join(shots, name)}: ${await cmd(`shot ${join(shots, name)}`)}`); };
const creepTo = async (x, z, ms = 120000) => { await cmd(`walkto 0 ${Math.floor(x / 2)} ${Math.floor(z / 2)} 1.2 creep`); await sleep(250); return until(state, (s) => s.auto !== 'walking', ms); };
const lookAt = async (s, x, z, pitchDeg) => { const yaw = Math.atan2(-(x - s.me.x), -(z - s.me.z)) * 180 / Math.PI; await cmd(`look ${yaw} ${pitchDeg}`); };

try {
  for (let i = 0; i < 200; i++) { if ((await cmd('ui alone')) === 'ok') break; await sleep(100); }
  await until(async () => JSON.parse(await cmd('screen')).screen, (v) => v === 'face', 10000);
  await cmd('draw done');
  await until(async () => { try { return (await state()).phase; } catch { return undefined; } }, (v) => v !== undefined, 30000);
  await cmd('click');
  let s = await until(state, (x) => x.phase === 'unloading' && x.client.doors > 0.95, 30000);
  if (s.place !== 'arboretum') throw new Error(`floor ${s.depth} is ${s.place}`);
  const g = JSON.parse(await cmd('garden'));
  const W = g.w;
  const open = (cx, cy) => cx >= 0 && cy >= 0 && cx < W && cy < g.h && g.cells[cy * W + cx] !== '0';
  const surf = (cx, cy) => Number(g.cells[cy * W + cx]);
  const [dx, dz] = g.door;

  // Out of the car onto the landing by hand (the game's own walk starts from the floor).
  for (let i = 0; i < 200 && Math.hypot(s.me.x - dx, s.me.z - (dz - 3.7)) > 0.35; i++) {
    await cmd(`face ${dx} ${dz - 3.7}`);
    await cmd('move 1 0 0 1');
    await sleep(60);
    s = await state();
  }
  await cmd('stopmove');
  // 1. The pavilion and its gravel apron, lit: from open ground 6 to 10 m in front with the clearest line back
  // to the doorway (`door` is the apron cell outside it), looking back over the apron.
  let front = null;
  for (let cy = 0; cy < g.h; cy++) for (let cx = 0; cx < W; cx++) {
    if (!open(cx, cy) || surf(cx, cy) === 0) continue;
    const x = (cx + 0.5) * 2, z = (cy + 0.5) * 2;
    const d = Math.hypot(x - dx, z - dz);
    if (z < dz + 4 || d < 6 || d > 10) continue;
    let blocked = 0;
    for (let k = 1; k < 20; k++) { const px = x + (dx - x) * k / 20, pz = z + (dz - z) * k / 20; if (!open(Math.floor(px / 2), Math.floor(pz / 2))) blocked++; }
    const score = blocked * 10 + Math.abs(x - dx) + Math.abs(d - 8);
    if (!front || score < front.score) front = { x, z, score };
  }
  s = await creepTo(front ? front.x : dx, front ? front.z : dz + 2);
  await lookAt(s, dx, dz - 1, -7);
  await sleep(7000); // the car's lines leave the screen
  await shot('1_pavilion_and_apron.png');
  console.log(`  the pavilion, from ${Math.hypot(s.me.x - dx, s.me.z - dz).toFixed(1)} m in front of its doorway`);

  // 2. A landmark's lamp pool seen from the dark: the landmark nearest the pavilion, from about 10 m, along the
  // clearest line to its lamp.
  const marks = g.landmarks.slice(1).sort((p, q) => Math.hypot(p.lamp[0] - dx, p.lamp[1] - dz) - Math.hypot(q.lamp[0] - dx, q.lamp[1] - dz));
  const L = marks.find((m) => Math.hypot(m.lamp[0] - g.start[0], m.lamp[1] - g.start[1]) > 24) ?? marks[0];
  let best = null;
  for (let cy = 0; cy < g.h; cy++) for (let cx = 0; cx < W; cx++) {
    if (!open(cx, cy) || surf(cx, cy) === 0) continue;
    const x = (cx + 0.5) * 2, z = (cy + 0.5) * 2;
    const d = Math.hypot(x - L.lamp[0], z - L.lamp[1]);
    if (d < 9 || d > 12) continue;
    let blocked = 0;
    for (let k = 1; k < 20; k++) { const px = x + (L.lamp[0] - x) * k / 20, pz = z + (L.lamp[1] - z) * k / 20; if (!open(Math.floor(px / 2), Math.floor(pz / 2))) blocked++; }
    const score = blocked * 10 + Math.abs(d - 10.5);
    if (!best || score < best.score) best = { x, z, score };
  }
  s = await creepTo(best.x, best.z);
  await lookAt(s, L.lamp[0], L.lamp[1], 2);
  await shot('2_lamp_pool_from_the_dark.png');
  console.log(`  the ${L.kind}, from ${Math.hypot(s.me.x - L.lamp[0], s.me.z - L.lamp[1]).toFixed(1)} m`);

  // 3. Moss against litter in lamp light: in the landmark's clearing (moss), looking down at where it meets the
  // litter beside it, nearest the lamp.
  let edge = null;
  for (let cy = L.y; cy < L.y + L.h; cy++) for (let cx = L.x; cx < L.x + L.w; cx++) {
    if (surf(cx, cy) !== 1) continue;
    for (const [ox, oy] of [[1, 0], [-1, 0], [0, 1], [0, -1]]) {
      if (!open(cx + ox, cy + oy) || surf(cx + ox, cy + oy) !== 2) continue;
      const d = Math.hypot((cx + ox + 0.5) * 2 - L.lamp[0], (cy + oy + 0.5) * 2 - L.lamp[1]);
      if (!edge || d < edge.d) edge = { cx, cy, ox, oy, d };
    }
  }
  if (edge) {
    // Stand a cell back from the edge, inside the clearing if there is one there, else on the cell itself.
    const back = open(edge.cx - edge.ox, edge.cy - edge.oy) ? [edge.cx - edge.ox, edge.cy - edge.oy] : [edge.cx, edge.cy];
    s = await creepTo((back[0] + 0.5) * 2, (back[1] + 0.5) * 2);
    await lookAt(s, (edge.cx + edge.ox * 0.5 + 0.5) * 2, (edge.cy + edge.oy * 0.5 + 0.5) * 2, -32);
    await shot('3_moss_against_litter.png');
  } else console.log('  no moss beside litter at this landmark');

  // 4. The blackout: back to the landing, the call, and out onto the apron when the lights go: only the gravel
  // and the near light.
  const plan = JSON.parse(await cmd('plan'));
  s = await creepTo((plan.landing.x + 0.5) * 2, (plan.landing.y + 0.5) * 2);
  await cmd('call');
  await until(state, (x) => x.phase === 'coming', 5000);
  s = await creepTo(dx, dz + 2);
  s = await until(state, (x) => x.blackout === true, 90000, 100);
  // Along the walk: toward the furthest gravel within 12 m that is not the apron.
  let far = null;
  for (let cy = 0; cy < g.h; cy++) for (let cx = 0; cx < W; cx++) {
    if (surf(cx, cy) !== 3 || cy <= plan.landing.y + 3) continue;
    const x = (cx + 0.5) * 2, z = (cy + 0.5) * 2;
    const d = Math.hypot(x - s.me.x, z - s.me.z);
    if (d <= 12 && (!far || d > far.d)) far = { x, z, d };
  }
  await lookAt(s, far ? far.x : dx, far ? far.z : dz + 10, -16);
  await sleep(1500);
  await shot('4_blackout_gravel_and_near_light.png');
  console.log(`  blackout ${s.blackout}, near light ${JSON.stringify(s.nearLight)}`);
} catch (e) {
  console.log('FAILED', String(e?.stack ?? e), lines.slice(-6));
  process.exitCode = 1;
} finally {
  try { sock.write('quit\n'); } catch { /* closed */ }
  await sleep(600);
  try { game.kill(); } catch { /* gone */ }
  sock.destroy();
}
