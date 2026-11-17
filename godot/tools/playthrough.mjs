// First copied from the client trial on 16 Nov 2026; this file is now edited here (see godot/README.md).
// The scripted playthrough, the same for the browser build (tools/play_web.mjs) and the Windows
// build (tools/play_desktop.mjs): step out, the clean side, the corrupted side, the Orderly's corridor,
// watch it (it does not move), turn away (it moves), take a reading, call the lift, flee at the blackout
// warning, come back when the lights return, board on BANK, bank; then a second run rides DOWN, and
// on that floor the camera drops for creeping and for being down (with the eye sent checked every frame).
// Every step is asserted from the rules' state as the bridge reports it; a picture at each step.
// driver: { cmd(text) -> reply, screenshot(path), wait(ms), close(), consoleLines: [] }
// opts: { shots (folder), only, report (file name), firstFrameMs, busPeaks (desktop: assert sound by bus) }
import { mkdirSync, writeFileSync } from 'node:fs';
import { join } from 'node:path';

export async function playthrough(driver, opts) {
const shots = opts.shots;
const only = opts.only ?? '';
mkdirSync(shots, { recursive: true });
const cmd = driver.cmd;
let caughtShots = 0;
const state = async () => {
  const s = JSON.parse(await cmd('state'));
  // Being taken is up to the Orderly, not the script: picture it whenever it happens (first time only).
  if (s.client.noise && caughtShots === 0) {
    caughtShots = 1;
    await driver.wait(700); // past the hard cut to black, into the noise
    await driver.screenshot(join(shots, 'caught-1-noise.png'));
    console.log('  shot caught-1-noise.png');
  } else if (s.client.wentDown && caughtShots === 1) {
    caughtShots = 2;
    await driver.screenshot(join(shots, 'caught-2-went-down.png'));
    console.log('  shot caught-2-went-down.png');
  }
  return s;
};
const wait = (ms) => driver.wait(ms);
let shotN = 0;
const results = [];
const shot = async (name) => {
  shotN++;
  const file = `${String(shotN).padStart(2, '0')}-${name}.png`;
  await driver.screenshot(join(shots, file));
  console.log('  shot', file);
  return file;
};
const check = (name, ok, detail = '') => {
  results.push({ name, ok, detail });
  console.log(`${ok ? 'PASS' : 'FAIL'} ${name}${detail ? ` (${detail})` : ''}`);
};
/** Polls the state until `pred` holds (or times out); returns the last state. */
const until = async (pred, ms = 30000, every = 100) => {
  const end = Date.now() + ms;
  let s = await state();
  while (!pred(s) && Date.now() < end) {
    await wait(every);
    s = await state();
  }
  return s;
};
const walk = async (level, x, y, pace = 6) => {
  await cmd(`walkto ${level} ${x} ${y} ${pace}`);
  await wait(200);
  return until((s) => s.auto !== 'walking', 60000);
};

// Sound, by measurement (desktop): the loudest each bus got over a short window, in dB.
const soundLog = [];
const soundCheck = async (name, bus, ms) => {
  if (!opts.busPeaks) return;
  let best = -200;
  const end = Date.now() + ms;
  while (Date.now() < end) {
    const p = JSON.parse(await cmd('peaks'));
    best = Math.max(best, p[bus] ?? -200);
    await driver.wait(40);
  }
  soundLog.push({ name, bus, db: Math.round(best * 10) / 10 });
  check(name, best > -60, `${bus} bus peak ${best.toFixed(1)} dB`);
};

const plan = JSON.parse(await cmd('plan'));
const W = plan.width;
const H = plan.height;
const S = 2;
const cellAt = (lv, x, y) => (x < 0 || y < 0 || x >= W || y >= H ? 'void' : plan.cells[lv][y * W + x]);
const dist = (lv, x, y) => plan.liftDist[lv * W * H + y * W + x];
const maxDist = Math.max(...plan.liftDist);
const centre = (x, y) => ({ x: (x + 0.5) * S, z: (y + 0.5) * S });
console.log(`plan ${W}x${H}, landing ${JSON.stringify(plan.landing)}, Orderly starts ${JSON.stringify(plan.entityStart)}, max walking distance ${maxDist} cells`);

// ---- 1. In the car, doors opening.
let s = await until((s) => s.phase === 'unloading' && s.client.doors > 0.95, 15000);
check('starts in the car, doors open onto the floor', s.me.aboard === true && s.doorsOpen === true, `phase ${s.phase}, doors ${s.client.doors.toFixed(2)}`);
await shot('in-the-car');
// The car (North Star C5, V9): 4 m by 4 m with a 1.8 m door by the rules, and drawn that size, its floor
// painted into a BANK half and a DOWN half 2 m wide each (measured from the lift's meshes on this screen).
{
  const car = plan.car;
  const d = s.client.lift ?? {};
  const near = (a, b, e) => typeof a === 'number' && Math.abs(a - b) <= e;
  check('the car is 4 m by 4 m with a 1.8 m door, and drawn that size with 2 m BANK and DOWN halves',
    car.width === 4 && car.depth === 4 && near(car.doorWidth, 1.8, 1e-9) && near(d.width, car.width, 0.15) && near(d.depth, car.depth, 0.15)
      && near(d.doorway, car.doorWidth, 0.01) && near(d.bank, car.width / 2, 0.06) && near(d.down, car.width / 2, 0.06),
    `rules ${car.width} x ${car.depth} m, door ${car.doorWidth} m; drawn ${JSON.stringify(d)}`);
  // From the back of the car, facing the doors and looking down: both halves and the doorway.
  await cmd('move -1 0 0 0');
  await until((t) => Math.abs((t.me.x - car.doorX) * car.inX + (t.me.z - car.doorZ) * car.inZ) > 3.3, 2500, 30);
  await cmd('stopmove');
  await cmd(`look ${(Math.atan2(car.inX, car.inZ) * 180) / Math.PI} -30`);
  await wait(400);
  await shot('car-inside-bank-down');
  await cmd(`look ${(Math.atan2(car.inX, car.inZ) * 180) / Math.PI} 0`);
}

// ---- 2. Step out.
await cmd('move 1 0 0 0');
s = await until((s) => !s.me.aboard && Math.hypot(s.me.x - plan.car.doorX, s.me.z - plan.car.doorZ) > 1.6, 5000, 50);
await cmd('stopmove');
check('steps out of the car with the rules moving the body', s.me.aboard === false, `at ${s.me.x.toFixed(2)}, ${s.me.z.toFixed(2)}`);
await wait(400);
await shot('stepped-out-clean-side');
await soundCheck("the announcer's welcome is heard", 'Voice', 2500);
await soundCheck('the light hum is heard', 'Ambience', 1500);

// ---- 3. The clean side and the corrupted side: sightlines by mean walking distance from the lift.
const mean = (sl) => {
  let n = 0;
  let sum = 0;
  for (let x = Math.min(sl.x1, sl.x2); x <= Math.max(sl.x1, sl.x2); x++)
    for (let y = Math.min(sl.y1, sl.y2); y <= Math.max(sl.y1, sl.y2); y++) {
      const d = dist(sl.level, x, y);
      if (d >= 0) { sum += d; n++; }
    }
  return n ? sum / n / maxDist : 0;
};
const es = plan.entityStart;
const farFromOrderly = (sl) => Math.hypot((sl.x1 + sl.x2) / 2 - es.x, (sl.y1 + sl.y2) / 2 - es.y) * S > 26 || sl.level !== es.level;
const lines = plan.sightlines.map((sl) => ({ ...sl, c: mean(sl) }));
const clean = lines.filter((l) => l.level === 0 && l.length >= 6).sort((a, b) => a.c - b.c)[0];
const corrupt = lines.filter((l) => l.length >= 5 && farFromOrderly(l)).sort((a, b) => b.c - a.c)[0];
const lookAlong = async (sl, fromNear = true) => {
  const d1 = dist(sl.level, sl.x1, sl.y1);
  const d2 = dist(sl.level, sl.x2, sl.y2);
  const a = (d1 <= d2) === fromNear ? { x: sl.x1, y: sl.y1 } : { x: sl.x2, y: sl.y2 };
  const b = a.x === sl.x1 && a.y === sl.y1 ? { x: sl.x2, y: sl.y2 } : { x: sl.x1, y: sl.y1 };
  await cmd(`teleport ${sl.level} ${a.x} ${a.y}`);
  await wait(150);
  const p = centre(b.x, b.y);
  await cmd(`face ${p.x} ${p.z}`);
  await wait(900);
};
await lookAlong(clean, true);
s = await state();
check('clean side: near the lift', clean.c < 0.35, `mean corruption ${clean.c.toFixed(2)}`);
await shot('clean-corridor');
await lookAlong(corrupt, false);
s = await state();
check('corrupted side: far from the lift', corrupt.c > 0.6, `mean corruption ${corrupt.c.toFixed(2)}, light level ${s.client.light}`);
await shot('corrupted-corridor');
if (only === 'first') { await finish(); }

// ---- 4. The Orderly's corridor: stand down its sightline, about 16 m off, and watch it.
const ePos = centre(es.x, es.y);
const along = plan.sightlines
  .filter((sl) => sl.level === es.level && ((sl.x1 === sl.x2 && sl.x1 === es.x && es.y >= Math.min(sl.y1, sl.y2) && es.y <= Math.max(sl.y1, sl.y2)) || (sl.y1 === sl.y2 && sl.y1 === es.y && es.x >= Math.min(sl.x1, sl.x2) && es.x <= Math.max(sl.x1, sl.x2))))
  .sort((a, b) => b.length - a.length)[0];
let spot = null;
if (along) {
  const cellsOn = [];
  for (let x = Math.min(along.x1, along.x2); x <= Math.max(along.x1, along.x2); x++)
    for (let y = Math.min(along.y1, along.y2); y <= Math.max(along.y1, along.y2); y++) cellsOn.push({ x, y, d: Math.hypot(x - es.x, y - es.y) * S });
  spot = cellsOn.filter((c) => c.d <= 10).sort((a, b) => b.d - a.d)[0];
}
console.log('Orderly sightline', JSON.stringify(along), 'watch from', JSON.stringify(spot));
// Walk most of the way there (the rules' path and collision), then the last stretch.
if (spot) {
  await cmd(`teleport ${es.level} ${spot.x} ${spot.y}`);
}
await wait(200);
await cmd(`face ${ePos.x} ${ePos.z} ${es.level * 3.2 + 1.4}`);
s = await until((s) => s.orderly.seeing === true, 4000, 50);
const o0 = { x: s.orderly.x, z: s.orderly.z };
check('the Orderly is in view and seen', s.orderly.seeing === true && s.orderly.drawn === true, `mode ${s.orderly.mode}, ${s.orderly.distance.toFixed(1)} m`);
await shot('orderly-watched');
// Keep watching for 2.5 s: it may wake (seen for a second), but it must not move.
let moved = 0;
for (let i = 0; i < 25; i++) {
  await wait(100);
  const t = await state();
  moved = Math.max(moved, Math.hypot(t.orderly.x - o0.x, t.orderly.z - o0.z));
  s = t;
}
check('watched, it does not move', moved < 1e-6 && s.orderly.held === true, `moved ${moved.toFixed(3)} m, mode ${s.orderly.mode}`);

// ---- 5. Turn away with the instrument up: it moves (and squeaks), the needle records; look back.
await cmd(`face ${2 * s.me.x - ePos.x} ${2 * s.me.z - ePos.z}`);
await cmd('raise 1');
s = await until((s) => s.orderly.moving === true, 4000, 50);
const sq = s.orderly.squeak;
await soundCheck('the squeak is heard while it moves unseen', 'Entity', 500);
await wait(600);
s = await state();
const moved2 = Math.hypot(s.orderly.x - o0.x, s.orderly.z - o0.z);
check('turned away, it moves (heard, not seen)', moved2 > 0.5 && sq.gain > 0, `moved ${moved2.toFixed(2)} m, squeak gain ${sq.gain.toFixed(2)}${sq.muffled ? ' muffled' : ''}`);
// Let it come on until the reading has built (or it gets too close for comfort).
s = await until((s) => (s.inst?.needle === 'recording' && s.inst.value > 30) || s.orderly.distance < 3.5, 8000, 50);
check('the instrument records while it moves (needle recording)', s.inst && s.inst.needle === 'recording', `needle ${s.inst?.needle}, value ${s.inst?.value.toFixed(1)}, rate ${s.inst?.rate.toFixed(1)}/s, tick ${s.inst?.tickHz.toFixed(1)} Hz, ${s.orderly.distance.toFixed(1)} m`);
await shot('turned-away-recording');
// Look back: it freezes at once.
await cmd(`face ${s.orderly.x} ${s.orderly.z} ${(s.orderly.pose?.y ?? 0) + 1.3}`);
s = await until((s) => s.orderly.seeing === true, 2000, 30);
const o1 = { x: s.orderly.x, z: s.orderly.z };
s = await until((s) => s.client.slipShown === true, 3000, 50);
check('the slip prints the first time the trait records', s.client.slip === 'recorded while: subject moving', `"${s.client.slip}"`);
await wait(1200);
await shot('orderly-closer-slip');
s = await state();
check('looked back, it stops', Math.hypot(s.orderly.x - o1.x, s.orderly.z - o1.z) < 1e-6 && s.orderly.held, `${s.orderly.distance.toFixed(1)} m away, mode ${s.orderly.mode}`);
s = await until((s) => s.tapes.count > 0, 5000, 100);
await cmd('raise 0');
check('the reading closes onto the tape (earnings on the display)', s.tapes.count > 0 && s.tapes.value > 0, `tapes ${s.tapes.count}, value ${s.tapes.value.toFixed(1)}, OSD "${s.client.tapeText}"`);
await wait(1000);
await shot('reading-on-tape');

// ---- 6. Back to the lift (backing away from it, still watching, then the rules' path), call it.
s = await walk(plan.landing.level, plan.landing.x, plan.landing.y, 9);
console.log(`  walk to the landing: ${s.auto}, at L${s.me.cell.level} (${s.me.cell.x},${s.me.cell.y}), caught ${s.client.caught}, orderly ${s.orderly.mode}`);
if (s.client.caught) await until((s) => !s.client.noise, 4000);
await cmd(`face ${plan.car.doorX} ${plan.car.doorZ} 2.0`);
s = await until((s) => s.me.canCall === true, 3000);
check('at the lift, the call button is in reach', s.me.canCall === true, `phase ${s.phase}, prompt "${s.client.prompt}", at (${s.me.cell.x},${s.me.cell.y})`);
await cmd('call');
s = await until((s) => s.phase === 'coming', 3000, 50);
check('the call: the car is coming, the indicator shows where it starts', s.phase === 'coming' && s.call && s.call.floorsAway > 0, `floors away ${s.call?.floorsAway}, eta ${s.call?.eta?.toFixed(1)} s, indicator ${s.client.indicator}`);
await wait(500);
await soundCheck('the announcer answers the call', 'Voice', 4000);
await shot('called-indicator');
// ---- 7. The wait, played the way a person would: watch the Orderly when it is in view (it freezes),
// back off down the clean corridor while a blink is warned or on, and at the blackout warning, flee.
const far = (() => {
  // The walkable level-0 cell at about 18 cells' walk from the lift, farthest from the Orderly's start.
  let best = null;
  for (let y = 0; y < H; y++) for (let x = 0; x < W; x++) {
    const d = dist(0, x, y);
    if (d < 14 || d > 22 || cellAt(0, x, y) !== 'corridor') continue;
    const k = Math.hypot(x - es.x, y - es.y);
    if (!best || k > best.k) best = { x, y, k };
  }
  return best;
})();
console.log('  refuge cell', JSON.stringify(far));
let sawBlink = false;
let fleeing = false;
const watchOrderly = async (s) => {
  if (s.orderly.level === s.me.level && s.orderly.distance < 30) await cmd(`face ${s.orderly.x} ${s.orderly.z} ${(s.orderly.pose?.y ?? 0) + 1.6}`);
};
s = await state();
while (s.phase === 'coming' && !(s.warn && s.blink?.blackout)) {
  if (s.dark && !s.blackout) sawBlink = true;
  if ((s.warn || s.dark) && !fleeing) {
    await cmd(`walkto 0 ${far.x} ${far.y} 5`);
    fleeing = true;
  } else if (!s.warn && !s.dark && fleeing) {
    await cmd('stopwalk');
    fleeing = false;
  }
  if (!fleeing && !s.client.noise) await watchOrderly(s);
  await wait(60);
  s = await state();
}
check('blinks before the blackout (it moves in them, frozen again when the lights return)', sawBlink && (s.events.blinkStart ?? 0) > 0, `blink starts ${s.events.blinkStart ?? 0}, caught ${s.events.caught ?? 0} times`);
check('the blackout warning', s.warn === true && s.blink?.blackout === true, `phase ${s.phase}`);
await shot('blackout-warning');
await cmd(`walkto 0 ${far.x} ${far.y} 5`);
s = await until((s) => s.blackout === true && s.client.emergency >= 1, 8000, 50);
check('the blackout: dark, emergency lighting on, the Orderly never drawn', s.blackout && s.client.emergency >= 1 && s.orderly.drawn === false, `emergency ${s.client.emergency}, drawn ${s.orderly.drawn}`);
await wait(200);
await shot('blackout-emergency-strips');
let drawnInDark = false;
s = await until((s) => {
  if (s.dark && s.orderly.drawn) drawnInDark = true;
  return s.phase !== 'coming';
}, 40000, 50);
await cmd('stopwalk');
// The screen is drawn a little behind the host (interpolation) and the client keeps a blink dark one
// tick past its end (net/client.gd _is_dark), so the lights come back a moment after the phase turns:
// within 0.3 s of host time.
{
  const lit = s.dark ? await until((s) => { if (s.dark && s.orderly.drawn) drawnInDark = true; return !s.dark; }, 3000, 20) : s;
  const late = lit.t - s.t;
  check('never drawn while dark (heard, not seen)', drawnInDark === false);
  check('the lights come back as the car arrives', s.phase === 'boarding' && !lit.dark && late <= 0.3, `phase ${s.phase}, lit ${late.toFixed(2)} s of host time after it turned, caught ${s.events.caught ?? 0} times so far`);
}

// ---- 8. The dash back. If it took us at some point, our tape is on the floor where it happened: get it.
if (s.client.noise) s = await until((s) => !s.client.noise, 4000);
await watchOrderly(s);
await wait(300);

s = await state();
const floorTape = s.tapes.count === 0 ? JSON.parse(await cmd('floortapes'))[0] : null;
if (floorTape) {
  const c = { level: floorTape.at.level, x: Math.floor(floorTape.at.x / S), y: Math.floor(floorTape.at.z / S) };
  await walk(c.level, c.x, c.y, 9);
  await cmd('pick');
  s = await until((s) => s.tapes.count > 0, 2000, 50);
  check('the dropped tape picked up again', s.tapes.count > 0, `value ${s.tapes.value.toFixed(1)}`);
}
await walk(plan.landing.level, plan.landing.x, plan.landing.y, 9);
await cmd(`face ${plan.car.doorX} ${plan.car.doorZ} 1.4`);
await wait(900);
s = await state();
await shot('lights-back-car-open');
check('the car is open for boarding', s.phase === 'boarding' && s.client.doors > 0.9, `bell in ${s.bellLeft.toFixed(1)} s, doors ${s.client.doors.toFixed(2)}`);// Walk in through the doorway, then step to the left half (BANK).
await cmd(`face ${plan.car.doorX + plan.car.inX * 2} ${plan.car.doorZ + plan.car.inZ * 2}`);
await cmd('move 1 0 0 0');
s = await until((s) => s.me.aboard === true && Math.abs((s.me.x - plan.car.doorX) * plan.car.inX + (s.me.z - plan.car.doorZ) * plan.car.inZ) > 1.1, 4000, 30);
await cmd('move 0 -1 0 0');
s = await until((s) => s.me.side === 'bank', 3000, 30);
await cmd('stopmove');
check('aboard, standing on BANK: the vote', s.me.aboard && s.me.side === 'bank' && s.votes.bank === 1, `votes ${JSON.stringify(s.votes)}`);
await cmd(`look ${(Math.atan2(plan.car.inX, plan.car.inZ) * 180) / Math.PI} -55`);
await wait(500);
await shot('vote-bank');
await cmd('look ' + ((Math.atan2(plan.car.inX, plan.car.inZ) * 180) / Math.PI) + ' 0');

// ---- 9. The bell; banked; the end screen.
await cmd('timescale 4');
s = await until((s) => s.phase === 'ended', 30000, 100);
await cmd('timescale 1');
check('the bell, then banked', s.phase === 'ended' && s.summary && !s.summary.wiped, `total ${s.summary?.total?.toFixed(1)}`);
s = await until((s) => s.client.end.length > 0, 8000, 100);
check('the end screen', s.client.end[0] === 'BANKED', s.client.end.join(' / '));
await shot('banked-end-screen');
const spoken = s.client.spoken;
check('the announcer spoke, never the same line twice running', spoken.length >= 3 && spoken.every((id, i) => i === 0 || id !== spoken[i - 1]), spoken.join(', '));

// ---- 10. A second run: ride DOWN to floor 2.
await cmd('newrun');
s = await until((s) => s.phase === 'unloading', 15000);
const p2 = JSON.parse(await cmd('plan'));
await cmd('move 1 0 0 0');
s = await until((s) => !s.me.aboard, 4000, 30);
await wait(500);
await cmd('stopmove');
s = await until((s) => s.phase === 'away', 15000, 100);
await walk(p2.landing.level, p2.landing.x, p2.landing.y, 9);
await cmd('call');
s = await until((s) => s.phase === 'coming', 3000, 50);
await cmd('timescale 6');
s = await until((s) => s.phase !== 'coming', 120000, 100);
await cmd('timescale 1');
await walk(p2.landing.level, p2.landing.x, p2.landing.y, 9);
await cmd(`face ${p2.car.doorX + p2.car.inX * 2} ${p2.car.doorZ + p2.car.inZ * 2}`);
await cmd('move 1 0 0 0');
s = await until((s) => s.me.aboard === true && Math.abs((s.me.x - p2.car.doorX) * p2.car.inX + (s.me.z - p2.car.doorZ) * p2.car.inZ) > 1.1, 4000, 30);
await cmd('move 0 1 0 0');
s = await until((s) => s.me.side === 'down', 3000, 30);
await cmd('stopmove');
check('second run: standing on DOWN', s.me.side === 'down', `votes ${JSON.stringify(s.votes)}`);
await cmd(`look ${(Math.atan2(p2.car.inX, p2.car.inZ) * 180) / Math.PI} -55`);
await wait(400);
await shot('vote-down');
await cmd('timescale 4');
s = await until((s) => s.phase === 'riding', 30000, 100);
await cmd('timescale 1');
await cmd(`look ${(Math.atan2(p2.car.inX, p2.car.inZ) * 180) / Math.PI} 12`);
await wait(700);
await shot('riding-down');
s = await until((s) => s.depth === 2 && s.client.built === 2 && s.doorsOpen, 20000, 100);
check('rode down to floor 2: a new plan, the doors open on it', s.depth === 2 && s.client.built === 2, `indicator ${s.client.indicator}`);
await wait(800);
await shot('floor-two');

// ---- 11. Geometry on this floor: the open room looking up (no floating lights), a doorway's wall seen
// edge-on (thickness), and two rooms' props by a wall, from inside and from beyond the wall.
const p3 = JSON.parse(await cmd('plan'));
const W3 = p3.width;
const H3 = p3.height;
const cell3 = (lv, x, y) => (x < 0 || y < 0 || x >= W3 || y >= H3 ? 'void' : p3.cells[lv][y * W3 + x]);
const roomOf = (lv, x, y) => p3.rooms.find((r) => r.level === lv && x >= r.x && x < r.x + r.w && y >= r.y && y < r.y + r.h)?.id ?? -1;
let open = null;
for (let y = 0; y < H3; y++) for (let x = 0; x < W3; x++) {
  if (cell3(0, x, y) !== 'room' || cell3(1, x, y) !== 'atriumOpen') continue;
  let k = 0;
  for (let dy = -1; dy <= 1; dy++) for (let dx = -1; dx <= 1; dx++) if (cell3(1, x + dx, y + dy) === 'atriumOpen') k++;
  if (!open || k > open.k) open = { x, y, k };
}
if (open) {
  await cmd(`teleport 0 ${open.x} ${open.y}`);
  await wait(200);
  await cmd('look 30 38');
  await wait(900);
  await shot('open-room-looking-up');
  await cmd('look 210 20');
  await wait(600);
  await shot('open-room-across');
}
check('an open (double-height) room to look up in', open !== null, open ? `cell (${open.x},${open.y})` : 'none on this floor');
const door = p3.doors.find((d) => d.level === 0 && ((cell3(0, d.ax, d.ay) === 'corridor' && cell3(0, d.bx, d.by) === 'room') || (cell3(0, d.bx, d.by) === 'corridor' && cell3(0, d.ax, d.ay) === 'room')));
if (door) {
  const c = cell3(0, door.ax, door.ay) === 'corridor' ? { x: door.ax, y: door.ay } : { x: door.bx, y: door.by };
  const r = c.x === door.ax && c.y === door.ay ? { x: door.bx, y: door.by } : { x: door.ax, y: door.ay };
  const into = { x: r.x - c.x, y: r.y - c.y };
  const along = { x: -into.y, y: into.x };
  await cmd(`teleport 0 ${c.x} ${c.y}`);
  await wait(200);
  await cmd(`nudge ${along.x * 0.75 - into.x * 0.1} ${along.y * 0.75 - into.y * 0.1}`);
  await wait(200);
  const mid = { x: (c.x + r.x + 1) * 0.5 * S, z: (c.y + r.y + 1) * 0.5 * S };
  await cmd(`face ${mid.x - along.x * 0.2} ${mid.z - along.y * 0.2} 1.3`);
  await wait(700);
  await shot('doorway-wall-thickness');
}
check('a doorway to see the wall edge-on', door !== undefined);
const spots = JSON.parse(await cmd('props'));
const usedRooms = new Set();
let propViews = 0;
let propSpot = null;
for (const sp of spots) {
  if (propViews >= 2 || sp.level !== 0 || sp.tipped || usedRooms.has(sp.room)) continue;
  const [wx, wy] = sp.wall;
  const beyond = { x: sp.cx + wx, y: sp.cy + wy };
  const inside = roomOf(0, sp.cx - wx, sp.cy - wy) === sp.room ? { x: sp.cx - wx, y: sp.cy - wy } : { x: sp.cx, y: sp.cy };
  if (!['corridor', 'room', 'landing'].includes(cell3(0, beyond.x, beyond.y)) || roomOf(0, beyond.x, beyond.y) === sp.room) continue;
  usedRooms.add(sp.room);
  propViews++;
  const fc = { x: sp.foot[0] + sp.foot[2] / 2, z: sp.foot[1] + sp.foot[3] / 2 };
  if (!propSpot) propSpot = { inside, fc };
  await cmd(`teleport 0 ${inside.x} ${inside.y}`);
  await wait(200);
  await cmd(`face ${fc.x} ${fc.z} 0.6`);
  await wait(700);
  await shot(`props-room-${propViews}-inside`);
  await cmd(`teleport 0 ${beyond.x} ${beyond.y}`);
  await wait(200);
  await cmd(`nudge ${wx * 0.6} ${wy * 0.6}`);
  await wait(200);
  await cmd(`face ${fc.x} ${fc.z} 0.9`);
  await wait(700);
  await shot(`props-room-${propViews}-other-side`);
}
check('two rooms with props by a wall, seen from both sides', propViews === 2, `${spots.length} props on this floor`);

// ---- 12. The camera drops when you creep (North Star B12): the same spot and the same look, standing
// then creeping (Ctrl held, standing still), then up again. The eye is the camera as drawn above the feet.
const eyeOf = (st) => st.client.camY - st.me.y;
if (propSpot) {
  await cmd(`teleport 0 ${propSpot.inside.x} ${propSpot.inside.y}`);
  await wait(200);
  await cmd(`face ${propSpot.fc.x} ${propSpot.fc.z} 0.9`);
  await wait(600);
}
const stood = await state();
await shot('eye-standing');
await cmd('move 0 0 0 1');
await wait(700);
const crept = await state();
await shot('eye-creeping-same-spot');
await cmd('stopmove');
await wait(600);
const upAgain = await state();
const sameSpot = Math.hypot(crept.me.x - stood.me.x, crept.me.z - stood.me.z) < 1e-6 && crept.client.yaw === stood.client.yaw && crept.client.pitch === stood.client.pitch;
check('creeping drops the camera (same spot, same look)', crept.me.gait === 'creep' && eyeOf(crept) < 1.3 && Math.abs(eyeOf(stood) - 1.65) < 0.005 && sameSpot,
  `standing eye ${eyeOf(stood).toFixed(3)} m, creeping ${eyeOf(crept).toFixed(3)} m (gait ${crept.me.gait}), same spot and look ${sameSpot}`);
check('standing up raises it again', Math.abs(eyeOf(upAgain) - 1.65) < 0.005 && upAgain.me.gait !== 'creep', `eye ${eyeOf(upAgain).toFixed(3)} m`);

// ---- 13. Down (the caught status stands for it until the downed-and-healed rules): the camera near the
// floor. Playing alone that is a wipe, so it comes last.
const downOk = JSON.parse(await cmd('down 1')).ok === true;
const downed = await until((st) => st.me.status === 'caught' && eyeOf(st) < 0.5, 3000, 50);
await wait(250);
await shot('eye-down');
check('down: the camera near the floor', downOk && downed.me.status === 'caught' && eyeOf(downed) < 0.5, `status ${downed.me.status}, eye ${eyeOf(downed).toFixed(3)} m`);
await wait(300);
// Every frame of the whole playthrough: the camera drawn against the camera the client judged sight
// from on that frame, and on every frame an input went, the eye in that input as sent.
const eyes = JSON.parse(await cmd('eyestats'));
const span = (k) => `${eyes[k].frames} frames ${eyes[k].min.toFixed(2)}-${eyes[k].max.toFixed(2)} m`;
check('every frame, standing, creeping and down: the eye sent to the rules is the camera drawn', eyes.mismatch === 0 && eyes.sentMismatch === 0 && eyes.stand.frames > 100 && eyes.creep.frames > 20 && eyes.down.frames > 5 && eyes.sent > 50,
  `${eyes.mismatch} frames off (largest gap ${eyes.maxDiff.toFixed(4)} m), ${eyes.sentMismatch} of ${eyes.sent} inputs off (largest ${eyes.maxSentDiff.toFixed(4)} m); standing ${span('stand')}, creeping ${span('creep')}, down ${span('down')}`);
check('creeping frames go below 1.3 m', eyes.creep.min < 1.3, `lowest creeping eye ${eyes.creep.min.toFixed(2)} m`);

await finish();

async function finish() {
  const stats = JSON.parse(await cmd('stats'));
  const errors = driver.consoleLines.filter((l) => /error|pageerror/i.test(l));
  writeFileSync(join(shots, opts.report ?? 'playthrough.json'), JSON.stringify({ firstFrameMs: opts.firstFrameMs, results, sound: soundLog, stats, errors, console: driver.consoleLines.slice(-60) }, null, 2));
  const failed = results.filter((r) => !r.ok).length;
  console.log(`${results.length - failed}/${results.length} passed; console errors ${errors.length}`);
  for (const e of errors.slice(0, 10)) console.log('  ', e);
  await driver.close();
  process.exit(failed ? 1 : 0);
}
}
