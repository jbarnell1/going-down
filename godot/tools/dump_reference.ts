// Writes the reference files the Godot tests compare against, from the real TypeScript rules in
// src/sim (imported, never copied). Run from the repo root:
//   npm run godot:reference
// Output: godot/tests/reference/*.json
//
// Format. Floats travel as "~" + the 16 hex digits of their IEEE bits (Godot's JSON parser and its
// float literals are not exact; bits are). Integers travel as JSON numbers. Long traces carry, per
// tick, two digests (first 8 hex digits of an MD5) of a canonical text of the whole state (keys sorted, floats as
// bits): `exact` with the pay-derived fields masked, `full` with everything. The masked fields all
// come from `k ** 3` in rateAt, whose JavaScript result depends on the platform's pow (see
// godot/README.md); the Godot tests compare those fields within 1e-9 and say how many differ.
//
// The scenario drivers here (walks, scripted scenes, bot crews) are written again in
// godot/tests/ref_*.gd; both must stay in step. Inputs come from the seeded RNG on both sides.

import { createHash } from 'node:crypto';
import { mkdirSync, readdirSync, readFileSync, writeFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { botView, createBot, createWaitBot, stepBot, stepWaitBot, waitBotInput, BOT_EYE, BOT_HFOV_DEG, BOT_RADIUS, BOT_VFOV_DEG, type Bot, type WaitBot } from '../../src/sim/bot';
import { generateClinic } from '../../src/sim/clinic';
import { audibility, createOrderly, stepEntity, yawToward, type OrderlyEvent, type OrderlyState, type PlayerView } from '../../src/sim/entity';
import { cellAt, distancesFrom, findPath, hashPlan, isWalkable, posFromIndex, reachableFrom, renderAscii, sideBranches, stairCells, stairEnds, DIR_VEC, type Door, type FloorPlan, type Level, type Pos } from '../../src/sim/floor';
import { pathDone, startPathWalk, stepPathWalk } from '../../src/sim/follow';
import { createCrew, leaveFloor, member, pickUpTape, rateAt, repeatFactor, setRaised, stepCrew, tapeValue, type CrewEvent, type CrewPlayer, type CrewState } from '../../src/sim/instrument';
import { elevatorWall, landingFacing } from '../../src/sim/landing';
import { bodyAtCell, cellOf, feetHeight, moveWithCollision, wallClearance, type Body } from '../../src/sim/move';
import { makeRng, hashSeed } from '../../src/sim/rng';
import { BOARD_TIME, HOLD_LIMIT, callPlan, carBody, carGeometry, createRun, depthMultiplier, doorsOpen, moveInRun, stepRun, blackedOut, type CallPlan, type PlayerInput, type RunEvent, type RunPlayer, type RunState } from '../../src/sim/run';
import { canSee, hasLineOfSight, inViewCone, type Viewer } from '../../src/sim/sight';
import { exertion, freshStamina, gaitFor, speedFor, stepStamina, sustainedFleeSpeed, type Gait, type Stamina } from '../../src/sim/stamina';
import { addReading, emptyTape, type Tape } from '../../src/sim/tape';
import { edgeKind, northEdge, segmentsNear, westEdge } from '../../src/sim/walls';
import { runWait } from '../../tests/sim/waits';
import { bridgeScenes } from './bridge_script';

const OUT = join(dirname(fileURLToPath(import.meta.url)), '..', 'tests', 'reference');

// ---------------------------------------------------------------------------------------------
// Encoding.

const f64 = new Float64Array(1);
const u32 = new Uint32Array(f64.buffer);
function hex(x: number): string {
  f64[0] = x;
  return (u32[1] as number).toString(16).padStart(8, '0') + (u32[0] as number).toString(16).padStart(8, '0');
}
const isInt = (v: number): boolean => Number.isInteger(v) && Math.abs(v) < 2 ** 53;

/** Plain data for a reference file: non-integer numbers become "~hex". */
function J(v: unknown): unknown {
  if (v === null || v === undefined) return null;
  if (typeof v === 'number') return isInt(v) ? (Object.is(v, -0) ? 0 : v) : `~${hex(v)}`;
  if (typeof v === 'string' || typeof v === 'boolean') return v;
  if (Array.isArray(v)) return v.map(J);
  const o: Record<string, unknown> = {};
  for (const k of Object.keys(v as object)) o[k] = J((v as Record<string, unknown>)[k]);
  return o;
}

/** Fields derived from rateAt's pow (masked in the `exact` digest). */
const TAINT = new Set(['value', 'rate', 'recorded', 'tickHz', 'loudness', 'tickPhase', 'ticks', 'total', 'peakRate', 'lostValue', 'carriedValue', 'shares']);

/**
 * Canonical text of plain data: JSON with keys sorted, integers as numbers, every other number as
 * the string "h" + its bits, and (with mask) the pay-derived fields as the string "~". Godot builds
 * the same text with its native JSON.stringify(sort_keys), so both sides hash identical bytes.
 */
function canon(v: unknown, mask: boolean): string {
  if (v === null || v === undefined) return 'null';
  if (typeof v === 'boolean') return v ? 'true' : 'false';
  if (typeof v === 'number') return isInt(v) ? String(Object.is(v, -0) ? 0 : v) : JSON.stringify(`h${hex(v)}`);
  if (typeof v === 'string') return JSON.stringify(v);
  if (Array.isArray(v)) return `[${v.map((x) => canon(x, mask)).join(',')}]`;
  const o = v as Record<string, unknown>;
  return `{${Object.keys(o)
    .sort()
    .map((k) => `${JSON.stringify(k)}:${mask && TAINT.has(k) ? '"~"' : canon(o[k], mask)}`)
    .join(',')}}`;
}

/** The first 8 hex digits of the MD5 of a text (Godot: String.md5_text()). */
function fnv(text: string): string {
  return createHash('md5').update(text, 'utf8').digest('hex').slice(0, 8);
}
const digest = (v: unknown, mask: boolean): string => fnv(canon(v, mask));

// ---------------------------------------------------------------------------------------------
// Snapshots (plain data with the TypeScript field names). The Godot side builds the same shapes.

const P = (p: Pos) => ({ level: p.level, x: p.x, y: p.y });
const B = (b: Body) => ({ x: b.x, z: b.z, level: b.level, y: b.y });

function snapOrderly(s: OrderlyState) {
  return {
    t: s.t, body: B(s.body), yaw: s.yaw, mode: s.mode, anim: s.anim, animTime: s.animTime, seen: s.seen, held: s.held,
    frozen: s.frozen, moving: s.moving, everSeen: s.everSeen, seenTotal: s.seenTotal, lastSeenAt: s.lastSeenAt,
    targetId: s.targetId, speed: s.speed, preySpeed: s.preySpeed, preyX: s.preyX, preyZ: s.preyZ, preyId: s.preyId,
    path: s.path ? s.path.map(P) : null, pathNext: s.pathNext, replanIn: s.replanIn, windUpLeft: s.windUpLeft,
    windUpTarget: s.windUpTarget, dormantLeft: s.dormantLeft,
  };
}
const snapStamina = (s: Stamina) => ({ level: s.level, winded: s.winded });
function snapTape(t: Tape) {
  return { id: t.id, ownerId: t.ownerId, total: t.total, readings: t.readings.map((r) => ({ ...r })) };
}
function snapCrew(c: CrewState) {
  return {
    t: c.t,
    members: c.members.map((m) => ({
      id: m.id, body: m.body ? B(m.body) : null, active: m.active,
      instrument: { ...m.instrument, current: m.instrument.current ? { ...m.instrument.current } : null },
      tape: snapTape(m.tape), carrying: m.carrying.map(snapTape),
    })),
    floor: c.floor.map((f) => ({ tape: snapTape(f.tape), at: B(f.at) })),
    slipsPrinted: [...c.slipsPrinted], repeats: { ...c.repeats }, nextTape: c.nextTape, nextReading: c.nextReading,
  };
}
const snapWalk = (w: { path: Pos[]; next: number } | null) => (w ? { next: w.next, path: w.path.map(P) } : null);
function snapBot(b: Bot) {
  return {
    id: b.id, body: B(b.body), yaw: b.yaw, pitch: b.pitch, heading: b.heading, gait: b.gait, gaitLeft: b.gaitLeft, look: b.look,
    lookLeft: b.lookLeft, lookOffset: b.lookOffset, pitchWant: b.pitchWant, walk: snapWalk(b.walk), stuck: b.stuck,
    watchfulness: b.watchfulness, oblivious: b.oblivious, stamina: snapStamina(b.stamina), moveGait: b.moveGait, alarm: b.alarm,
  };
}
function snapWaitBot(b: WaitBot) {
  return {
    id: b.id, style: b.style, body: B(b.body), yaw: b.yaw, pitch: b.pitch, stamina: snapStamina(b.stamina), gait: b.gait, mode: b.mode,
    spot: { ...b.spot }, seat: { ...b.seat }, walk: snapWalk(b.walk), route: b.route.map(B), heard: b.heard ? B(b.heard) : null, rethink: b.rethink,
  };
}
const snapCallPlan = (p: CallPlan) => ({ delay: p.delay, floors: p.floors, falseStop: p.falseStop, extra: p.extra, wait: p.wait, darks: p.darks.map((d) => ({ ...d })) });
function snapRun(s: RunState) {
  return {
    seed: s.seed, t: s.t, depth: s.depth, planSeed: s.plan.seed, planDepth: s.plan.depth, car: { ...s.car, rect: { ...s.car.rect }, bank: { ...s.car.bank }, down: { ...s.car.down } },
    orderly: snapOrderly(s.orderly), entityId: s.entityId, crew: snapCrew(s.crew),
    players: s.players.map((p) => ({ id: p.id, body: B(p.body), status: p.status, aboard: p.aboard, side: p.side })),
    phase: s.phase, timer: s.timer, emptyFor: s.emptyFor, calls: s.calls, lastFloors: s.lastFloors,
    call: s.call ? { ...s.call, plan: snapCallPlan(s.call.plan) } : null, blink: s.blink ? { ...s.blink } : null,
    lure: s.lure, bellLeft: s.bellLeft, holdLeft: s.holdLeft, held: s.held, summary: s.summary ? { ...s.summary, shares: { ...s.summary.shares } } : null,
  };
}
/** Events are plain objects already; copy so later mutation cannot touch them. */
const snapEvent = (e: unknown): unknown => JSON.parse(JSON.stringify(e, (_k, v) => (typeof v === 'number' && !Number.isFinite(v) ? `~${hex(v)}` : v)));

// ---------------------------------------------------------------------------------------------
// Traces.

interface Trace {
  name: string;
  ticks: number;
  /** One 8-hex-digit digest per tick, concatenated. */
  exact: string;
  full: string;
  /** tick -> plain state (J-encoded), every `every` ticks and the last. */
  snaps: Record<string, unknown>;
  /** [tick, event] in order. */
  events: [number, unknown][];
  /** Per-tick extra values (J-encoded), when a scene has them. */
  extra: unknown[];
}
class Recorder {
  t: Trace;
  constructor(name: string, private every = 50) {
    this.t = { name, ticks: 0, exact: '', full: '', snaps: {}, events: [], extra: [] };
  }
  tick(state: unknown, events: readonly unknown[] = [], extra?: unknown): void {
    const k = this.t.ticks++;
    this.t.exact += digest(state, true);
    this.t.full += digest(state, false);
    for (const e of events) this.t.events.push([k, J(snapEvent(e))]);
    if (extra !== undefined) this.t.extra.push(J(extra));
    if (k % this.every === 0) this.t.snaps[String(k)] = J(state);
    this.last = state;
  }
  last: unknown = null;
  done(): Trace {
    if (this.t.ticks > 0) this.t.snaps[String(this.t.ticks - 1)] = J(this.last);
    return this.t;
  }
}

function write(name: string, data: unknown): void {
  mkdirSync(OUT, { recursive: true });
  const text = JSON.stringify(data);
  writeFileSync(join(OUT, name), text);
  console.log(`${name}: ${(text.length / 1024).toFixed(0)} KB`);
}

// ---------------------------------------------------------------------------------------------
// 1. RNG.

function dumpRng(): void {
  const cases = [];
  for (let i = 0; i < 50; i++) {
    const seed: string | number = i < 35 ? `seed-${i}` : [0, 1, 4294967295, 4294967296 + 5, -1, -123456789, 2654435761, 12345, 99, 7, 1 << 30, 3000000000, 42, 65535, 31337][i - 35] as number;
    const r = makeRng(seed);
    const next = Array.from({ length: 12 }, () => r.next());
    const ints = Array.from({ length: 12 }, () => r.int(-5, 17));
    const chance = Array.from({ length: 12 }, () => r.chance(0.3));
    const items = ['a', 'b', 'c', 'd', 'e', 'f', 'g'];
    const pick = Array.from({ length: 6 }, () => r.pick(items));
    const f = r.fork('floor-3');
    const fork = Array.from({ length: 6 }, () => f.next());
    const ff = r.fork('a').fork('b');
    const forkfork = Array.from({ length: 4 }, () => ff.next());
    const after = Array.from({ length: 4 }, () => r.next());
    cases.push({ seed, hash: typeof seed === 'string' ? hashSeed(seed) : null, next, ints, chance, pick, fork, forkfork, after });
  }
  write('rng.json', J(cases));
}

// ---------------------------------------------------------------------------------------------
// 2. Floors.

const CELL_CHAR: Record<string, string> = { void: 'v', corridor: 'c', room: 'r', stair: 's', landing: 'l', atriumOpen: 'o' };
const EDGE_CHAR: Record<string, string> = { none: 'n', open: 'o', door: 'd', wall: 'w', rail: 'r', stairTop: 't' };

function roomAtFor(plan: FloorPlan) {
  return (d: Door, end: 'a' | 'b'): number => {
    const x = end === 'a' ? d.ax : d.bx;
    const y = end === 'a' ? d.ay : d.by;
    const r = plan.rooms.find((rr) => rr.level === d.level && x >= rr.x && x < rr.x + rr.w && y >= rr.y && y < rr.y + rr.h);
    return r ? r.id : -1;
  };
}

export const FLOOR_CASES: [string, number][] = [];
for (const s of ['alpha', 'bravo', 'charlie', 'delta', 'echo']) for (const d of [1, 2, 3, 4]) FLOOR_CASES.push([s, d]);
for (let i = 0; i < 20; i++) FLOOR_CASES.push([`floor-${i}`, 1 + (i % 6)]);

function dumpFloors(): void {
  const floors = FLOOR_CASES.map(([seed, depth]) => {
    const p = generateClinic(seed, depth);
    const dist = distancesFrom(p, p.landing);
    let sum = 0;
    let max = -1;
    let reach = 0;
    dist.forEach((d) => {
      if (d >= 0) {
        sum += d;
        reach++;
        max = Math.max(max, d);
      }
    });
    const car = carGeometry(p);
    return {
      seed, depth, width: p.width, height: p.height, cellSize: p.cellSize, place: p.place,
      cells: p.cells.map((lv) => lv.map((k) => CELL_CHAR[k]).join('')),
      rooms: p.rooms.map((r) => [r.id, r.level, r.kind, r.x, r.y, r.w, r.h, r.branch]),
      doors: p.doors.map((d) => [d.level, d.ax, d.ay, d.bx, d.by]),
      stairs: p.stairs.map((s) => [s.x, s.y, s.dir, s.length]),
      landing: P(p.landing), entityStart: P(p.entityStart),
      sightlines: p.sightlines.map((s) => [s.level, s.x1, s.y1, s.x2, s.y2, s.length]),
      hash: hashPlan(p),
      sideBranches: sideBranches(p.rooms, p.doors, roomAtFor(p)),
      elevatorWall: elevatorWall(p), landingFacing: landingFacing(p),
      ascii: fnv(`${renderAscii(p, 0)}|${renderAscii(p, 1)}`),
      dist: { sum, max, reach },
      path: (findPath(p, p.landing, p.entityStart) ?? []).map((q) => [q.level, q.x, q.y]),
      car: { ...car, rect: { ...car.rect }, bank: { ...car.bank }, down: { ...car.down } },
    };
  });
  // Hashes of the 800 floors the clinic property tests use.
  const hashes: string[] = [];
  for (const depth of [1, 2, 3, 4]) for (let i = 0; i < 200; i++) hashes.push(hashPlan(generateClinic(`seed-${i}`, depth)));
  write('floors.json', J({ floors, hashes }));
}

// ---------------------------------------------------------------------------------------------
// 3. Walls, movement, collision, following a path, moving through the car door.

function dumpMove(): void {
  const out = [];
  for (const seed of ['alpha', 'bravo', 'charlie', 'delta', 'echo']) {
    const plan = generateClinic(seed, 2);
    const edges = [0, 1].map((level) => {
      let v = '';
      for (let y = 0; y < plan.height; y++) for (let x = 0; x <= plan.width; x++) v += EDGE_CHAR[westEdge(plan, level as Level, x, y)];
      let h = '';
      for (let y = 0; y <= plan.height; y++) for (let x = 0; x < plan.width; x++) h += EDGE_CHAR[northEdge(plan, level as Level, x, y)];
      return [v, h];
    });
    let segText = '';
    for (const level of [0, 1] as const) for (let y = 0; y < plan.height; y++) for (let x = 0; x < plan.width; x++) {
      if (!isWalkable(plan, level, x, y)) continue;
      segText += canon(segmentsNear(plan, level, x, y).map((g) => [g.ax, g.az, g.bx, g.bz]), false);
    }
    // The random walk of tests/sim/move.test.ts, shortened: every body after every step.
    const rng = makeRng(`walk:${seed}`);
    const starts: Pos[] = [plan.landing, plan.entityStart, ...plan.stairs.map((s) => stairEnds(s).bottom)];
    const walks: unknown[] = [];
    for (const start of starts) {
      let b = bodyAtCell(plan, start);
      let heading = rng.next() * Math.PI * 2;
      const steps: unknown[] = [];
      for (let i = 0; i < 250; i++) {
        if (rng.chance(0.05)) heading = rng.next() * Math.PI * 2;
        heading += (rng.next() - 0.5) * 0.3;
        const len = rng.chance(0.1) ? 0.6 : 0.05;
        b = moveWithCollision(plan, b, Math.cos(heading) * len, Math.sin(heading) * len, 0.3);
        steps.push(i % 25 === 0 ? [b.x, b.z, b.y, b.level, wallClearance(plan, b.level, b.x, b.z)] : digest([b.x, b.z, b.y, b.level, wallClearance(plan, b.level, b.x, b.z)], false));
      }
      walks.push(steps);
    }
    for (const stair of plan.stairs) {
      const v = DIR_VEC[stair.dir];
      let b = bodyAtCell(plan, stairEnds(stair).bottom);
      let dir = 1;
      const steps: unknown[] = [];
      for (let i = 0; i < 300; i++) {
        if (rng.chance(0.01)) dir = -dir;
        const c = cellOf(plan, b);
        const top = stairEnds(stair).top;
        const bottom = stairEnds(stair).bottom;
        if (c.level === top.level && c.x === top.x && c.y === top.y && rng.chance(0.2)) dir = -1;
        if (c.level === bottom.level && c.x === bottom.x && c.y === bottom.y && rng.chance(0.2)) dir = 1;
        const wob = (rng.next() - 0.5) * 0.15;
        b = moveWithCollision(plan, b, v.dx * 0.06 * dir + v.dy * wob, v.dy * 0.06 * dir + v.dx * wob, 0.3);
        steps.push(i % 25 === 0 ? [b.x, b.z, b.y, b.level, feetHeight(plan, b.level, b.x, b.z)] : digest([b.x, b.z, b.y, b.level, feetHeight(plan, b.level, b.x, b.z)], false));
      }
      walks.push(steps);
    }
    // Following findPath with real collision (tests/sim/move.test.ts), a digest of every body.
    const follows: unknown[] = [];
    for (const [from, to] of [[plan.landing, plan.entityStart], [plan.entityStart, plan.landing]] as const) {
      const path = findPath(plan, from, to) ?? [];
      const w = startPathWalk(path);
      let b = bodyAtCell(plan, from);
      let digests = '';
      let steps = 0;
      while (!pathDone(plan, w, b) && steps < 4000) {
        b = stepPathWalk(plan, w, b, 0.05, 0.3);
        digests += digest(B(b), false);
        steps++;
      }
      follows.push({ steps, digests, end: B(b), next: w.next });
    }
    // moveInRun around the car door, doors open and shut in turn.
    const run = createRun(`door:${seed}`, ['a']);
    const st: RunState = { ...run, plan, car: carGeometry(plan) };
    const r2 = makeRng(`door:${seed}`);
    let body = carBody(st.car, -1.2, 0);
    const door: unknown[] = [];
    for (let i = 0; i < 400; i++) {
      const open = Math.floor(i / 50) % 2 === 0;
      const s2 = { ...st, phase: open ? ('boarding' as const) : ('away' as const) };
      const toward = r2.chance(0.6);
      const ang = toward ? Math.atan2(st.car.inZ, st.car.inX) + (r2.next() - 0.5) * 1.6 : r2.next() * Math.PI * 2;
      const len = r2.next() * 0.3;
      body = moveInRun(s2, body, Math.cos(ang) * len, Math.sin(ang) * len, BOT_RADIUS);
      door.push(i % 25 === 0 ? [body.x, body.z, body.y, body.level] : digest([body.x, body.z, body.y, body.level], false));
    }
    out.push({ seed, depth: 2, edges, segments: fnv(segText), walks, follows, door });
  }
  write('move.json', J(out));
}

// ---------------------------------------------------------------------------------------------
// 4. Sight: seeded queries. The generator is mirrored in godot/tests/ref_sight.gd.

function sightCase(plan: FloorPlan, rng: ReturnType<typeof makeRng>, cells: number[]) {
  const cs = plan.cellSize;
  const kind = rng.int(0, 4);
  const jitter = (p: Pos): Body => {
    const x = (p.x + 0.2 + rng.next() * 0.6) * cs;
    const z = (p.y + 0.2 + rng.next() * 0.6) * cs;
    return { x, z, level: p.level, y: feetHeight(plan, p.level, x, z) };
  };
  let vp: Pos;
  let fp: Pos;
  if (kind === 1 && plan.doors.length > 0) {
    // Through a door: viewer one or two cells back on one side, figure on the other.
    const d = rng.pick(plan.doors);
    const flip = rng.chance(0.5);
    const a = flip ? { x: d.bx, y: d.by } : { x: d.ax, y: d.ay };
    const b = flip ? { x: d.ax, y: d.ay } : { x: d.bx, y: d.by };
    const back = rng.int(0, 2);
    const vx = a.x - (b.x - a.x) * back;
    const vy = a.y - (b.y - a.y) * back;
    vp = isWalkable(plan, d.level, vx, vy) ? { level: d.level, x: vx, y: vy } : { level: d.level, x: a.x, y: a.y };
    const fwd = rng.int(0, 2);
    const fx = b.x + (b.x - a.x) * fwd;
    const fy = b.y + (b.y - a.y) * fwd;
    fp = isWalkable(plan, d.level, fx, fy) ? { level: d.level, x: fx, y: fy } : { level: d.level, x: b.x, y: b.y };
  } else if (kind === 2) {
    // A stair: one end at the top or the bottom, the other on the stair or at the other end.
    const s = rng.pick(plan.stairs);
    const ends = stairEnds(s);
    const on = stairCells(s);
    const p1 = rng.chance(0.5) ? ends.top : ends.bottom;
    const p2 = rng.chance(0.7) ? { level: 0 as Level, ...rng.pick(on) } : rng.chance(0.5) ? ends.top : ends.bottom;
    if (rng.chance(0.5)) {
      vp = p1;
      fp = p2;
    } else {
      vp = p2;
      fp = p1;
    }
  } else if (kind === 3) {
    // Near: within a few cells on the same level.
    vp = posFromIndex(plan, rng.pick(cells));
    let tries = 0;
    do {
      fp = { level: vp.level, x: vp.x + rng.int(-4, 4), y: vp.y + rng.int(-4, 4) };
      tries++;
    } while (!isWalkable(plan, fp.level, fp.x, fp.y) && tries < 20);
    if (!isWalkable(plan, fp.level, fp.x, fp.y)) fp = vp;
  } else {
    vp = posFromIndex(plan, rng.pick(cells));
    fp = posFromIndex(plan, rng.pick(cells));
  }
  const v = jitter(vp);
  const f = jitter(fp);
  const eyeY = v.y + BOT_EYE;
  const dx = f.x - v.x;
  const dz = f.z - v.z;
  const yaw = Math.atan2(-dx, -dz) + (rng.next() - 0.5) * 2.4;
  const pitch = Math.atan2(f.y + 1.7 - eyeY, Math.hypot(dx, dz)) + (rng.next() - 0.5) * 0.8;
  const viewer: Viewer = { body: v, eye: BOT_EYE, yaw, pitch, hFovDeg: BOT_HFOV_DEG, vFovDeg: BOT_VFOV_DEG };
  const chest = { x: f.x, y: f.y + 1.7, z: f.z, level: f.level };
  const eye = { x: v.x, y: eyeY, z: v.z, level: v.level };
  const bits = [
    canSee(plan, viewer, f),
    canSee(plan, viewer, f, { height: 2.6, radius: 0.35 }),
    canSee(plan, viewer, f, { height: 2.6, radius: 1.1 }),
    canSee(plan, viewer, f, { height: 2.9, radius: 2.1 }),
    canSee(plan, viewer, f, { marginDeg: 0 }),
    hasLineOfSight(plan, eye, chest),
    inViewCone(viewer, chest),
  ];
  return { inputs: [kind, v.x, v.z, v.y, v.level, f.x, f.z, f.y, f.level, yaw, pitch], bits: bits.map((b) => (b ? '1' : '0')).join('') };
}

function dumpSight(): void {
  const out = [];
  for (const seed of ['alpha', 'bravo', 'charlie', 'delta', 'echo']) {
    for (const depth of [1, 3]) {
      const plan = generateClinic(seed, depth);
      const cells = [...reachableFrom(plan, plan.landing)].sort((a, b) => a - b);
      const rng = makeRng(`sight:${seed}:${depth}`);
      let bits = '';
      let inputs = '';
      for (let i = 0; i < 600; i++) {
        const c = sightCase(plan, rng, cells);
        bits += c.bits;
        inputs += canon(c.inputs, false);
      }
      out.push({ seed, depth, n: 600, bits, inputs: fnv(inputs) });
    }
  }
  write('sight.json', J(out));
}

// ---------------------------------------------------------------------------------------------
// 5. The Orderly: scripted scenes (mirrored in godot/tests/ref_entity.gd).

const DT = 0.05;
function view(id: string, b: Body, yaw: number, pitch = 0, active = true): PlayerView {
  return { id, body: b, eye: BOT_EYE, yaw, pitch, hFovDeg: BOT_HFOV_DEG, vFovDeg: BOT_VFOV_DEG, active };
}
const blindView = (id: string, b: Body): PlayerView => ({ ...view(id, b, 0, Math.PI / 2), hFovDeg: 0, vFovDeg: 0 });
const faceTo = (from: Body, to: Body): number => Math.atan2(-(to.x - from.x), -(to.z - from.z));

function entityScenes(): Trace[] {
  const traces: Trace[] = [];
  // Staring contest (entity.test.ts), three floors.
  let tried = 0;
  for (let i = 0; tried < 3 && i < 200; i++) {
    const p = generateClinic(`stare-${i}`, 1 + (i % 4));
    const s = p.sightlines.find((l) => l.level === p.entityStart.level && l.length >= 12 && ((l.x1 === p.entityStart.x && l.y1 === p.entityStart.y) || (l.x2 === p.entityStart.x && l.y2 === p.entityStart.y)));
    if (!s) continue;
    tried++;
    const atStart = s.x1 === p.entityStart.x && s.y1 === p.entityStart.y;
    const dx = Math.sign(s.x2 - s.x1) * (atStart ? 1 : -1);
    const dy = Math.sign(s.y2 - s.y1) * (atStart ? 1 : -1);
    const me = bodyAtCell(p, { level: s.level, x: p.entityStart.x + dx * 8, y: p.entityStart.y + dy * 8 });
    let st = createOrderly(p);
    const facing = faceTo(me, st.body);
    const rec = new Recorder(`stare-${i}`);
    for (let k = 0; k < 730; k++) {
      const yaw = k < 600 ? facing : k < 630 ? facing + Math.PI : facing;
      const r = stepEntity(p, st, [view('me', me, yaw)], DT);
      st = r.state;
      const a = audibility(p, st, view('me', me, yaw));
      rec.tick(snapOrderly(st), r.events, [a.gain, a.muffled]);
    }
    traces.push(rec.done());
  }
  // Blind hunt across levels to a room, to the catch and dormant (entity.test.ts), three floors.
  let scenes = 0;
  for (let i = 0; scenes < 3 && i < 100; i++) {
    const p = generateClinic(`stairs-${i}`, 1 + (i % 4));
    const other: Level = p.entityStart.level === 0 ? 1 : 0;
    const room = p.rooms.find((r) => r.level === other && r.kind !== 'lobby' && r.kind !== 'atrium' && r.branch === 'side');
    if (!room) continue;
    const cell: Pos = { level: other, x: room.x + Math.floor(room.w / 2), y: room.y + Math.floor(room.h / 2) };
    if (!isWalkable(p, cell.level, cell.x, cell.y) || !findPath(p, p.entityStart, cell)) continue;
    scenes++;
    const me = bodyAtCell(p, cell);
    let st: OrderlyState = { ...createOrderly(p), mode: 'hunting' };
    const rec = new Recorder(`stairs-${i}`);
    let caughtAt = -1;
    for (let k = 0; k < 120 / DT && (caughtAt < 0 || k < caughtAt + 260); k++) {
      const r = stepEntity(p, st, [blindView('me', me)], DT);
      st = r.state;
      if (caughtAt < 0 && r.events.some((e) => e.type === 'caught')) caughtAt = k;
      rec.tick(snapOrderly(st), r.events);
    }
    traces.push(rec.done());
  }
  // Wakes at 60 s far away; a wind-up cancelled by a look (entity.test.ts).
  {
    const p = generateClinic('wake', 1);
    let st = createOrderly(p);
    const rec = new Recorder('wake-60');
    for (let k = 0; k < 1240; k++) {
      const r = stepEntity(p, st, [blindView('me', bodyAtCell(p, p.landing))], DT);
      st = r.state;
      rec.tick(snapOrderly(st), r.events);
    }
    traces.push(rec.done());
  }
  {
    const p = generateClinic('windup', 1);
    const meBody = bodyAtCell(p, p.landing);
    let st: OrderlyState = { ...createOrderly(p), mode: 'hunting' };
    const rec = new Recorder('windup');
    // Blind until it starts reaching, one more blind tick (part way through), then 200 ticks looking.
    for (let k = 0; k < 2400; k++) {
      const r = stepEntity(p, st, [blindView('me', meBody)], DT);
      st = r.state;
      rec.tick(snapOrderly(st), r.events);
      if (r.events.some((e) => e.type === 'windUp')) break;
    }
    {
      const r = stepEntity(p, st, [blindView('me', meBody)], DT);
      st = r.state;
      rec.tick(snapOrderly(st), r.events);
    }
    const look = faceTo(meBody, st.body);
    for (let k = 0; k < 200; k++) {
      const r = stepEntity(p, st, [view('me', meBody, look)], DT);
      st = r.state;
      rec.tick(snapOrderly(st), r.events);
    }
    traces.push(rec.done());
  }
  // Creep near slow prey, full speed after a fleeing one: the player stands with their back turned
  // 9 m down the hall, then walks away at 3 m/s along it.
  {
    for (const seed of ['prey-a', 'prey-b']) {
      let p: FloorPlan | null = null;
      let s = null as FloorPlan['sightlines'][number] | null;
      for (let i = 0; i < 100 && !s; i++) {
        p = generateClinic(`${seed}-${i}`, 1 + (i % 4));
        const pl = p;
        s = pl.sightlines.find((l) => l.level === pl.entityStart.level && l.length >= 14 && ((l.x1 === pl.entityStart.x && l.y1 === pl.entityStart.y) || (l.x2 === pl.entityStart.x && l.y2 === pl.entityStart.y))) ?? null;
      }
      if (!p || !s) throw new Error('no prey corridor');
      const plan = p;
      const atStart = s.x1 === plan.entityStart.x && s.y1 === plan.entityStart.y;
      const dx = Math.sign(s.x2 - s.x1) * (atStart ? 1 : -1);
      const dz = Math.sign(s.y2 - s.y1) * (atStart ? 1 : -1);
      const o = bodyAtCell(plan, plan.entityStart);
      const along = (d: number): Body => {
        const x = o.x + dx * d;
        const z = o.z + dz * d;
        return { x, z, level: plan.entityStart.level, y: feetHeight(plan, plan.entityStart.level, x, z) };
      };
      const maxD = (s.length - 1) * plan.cellSize;
      let d = 9;
      let st: OrderlyState = { ...createOrderly(plan), mode: 'hunting' };
      const rec = new Recorder(`${seed}`);
      for (let k = 0; k < 500; k++) {
        if (k >= 80) d = Math.min(maxD, d + 3 * DT);
        const me = along(d);
        const r = stepEntity(plan, st, [view('me', me, Math.atan2(-dx, -dz))], DT);
        st = r.state;
        rec.tick(snapOrderly(st), r.events, [st.preySpeed, st.speed]);
      }
      traces.push(rec.done());
    }
  }
  // Hearing range: a listener at the landing facing away (entity.test.ts, heard before seen).
  for (let i = 0; i < 4; i++) {
    const p = generateClinic(`hear-${i}`, 1 + (i % 4));
    const me = bodyAtCell(p, p.landing);
    let st: OrderlyState = { ...createOrderly(p), mode: 'hunting' };
    const rec = new Recorder(`hear-${i}`);
    for (let k = 0; k < 1200; k++) {
      const v = view('me', me, faceTo(st.body, me));
      const r = stepEntity(p, st, [v], DT);
      st = r.state;
      const a = audibility(p, st, v);
      rec.tick(snapOrderly(st), r.events, [a.gain, a.muffled]);
    }
    traces.push(rec.done());
  }
  return traces;
}

// ---------------------------------------------------------------------------------------------
// 6. Stamina, the instrument and tapes.

function dumpStamina(): unknown {
  const traces = [];
  const r = makeRng('stamina');
  for (let n = 0; n < 6; n++) {
    let st: Stamina = n === 0 ? freshStamina() : { level: r.next(), winded: r.chance(0.5) };
    const rows = [];
    for (let i = 0; i < 400; i++) {
      const wish = { sprint: r.chance(0.6), creep: r.chance(0.15), moving: r.chance(0.9), cap: r.chance(0.2) ? 2.2 : Infinity };
      const gait: Gait = gaitFor(st, wish);
      const ground = r.chance(0.15) ? 0 : speedFor(gait, wish.cap) * (0.5 + r.next() * 0.5);
      st = stepStamina(st, gait, ground, 1 / 20);
      rows.push([gait, ground, st.level, st.winded, exertion(st)]);
    }
    traces.push(rows);
  }
  return { traces, flee: sustainedFleeSpeed() };
}

function corridor(minCells: number) {
  for (let i = 0; i < 300; i++) {
    const p = generateClinic(`corridor-${i}`, 1 + (i % 4));
    const e = p.entityStart;
    const s = p.sightlines.find((l) => l.level === e.level && l.length >= minCells && ((l.x1 === e.x && l.y1 === e.y) || (l.x2 === e.x && l.y2 === e.y)));
    if (!s) continue;
    const atStart = s.x1 === e.x && s.y1 === e.y;
    const dx = Math.sign(s.x2 - s.x1) * (atStart ? 1 : -1);
    const dz = Math.sign(s.y2 - s.y1) * (atStart ? 1 : -1);
    const o = bodyAtCell(p, e);
    const at = (d: number): Body => {
      const x = o.x + dx * d;
      const z = o.z + dz * d;
      return { x, z, level: e.level, y: feetHeight(p, e.level, x, z) };
    };
    return { p, at, toward: Math.atan2(dx, dz), away: Math.atan2(-dx, -dz) };
  }
  throw new Error('no corridor found');
}

/** Pay as the game shows it (crewList.ts, main.ts): whole units, and host.ts's two decimals. */
const shown = (v: number) => [Math.floor(v), v.toFixed(2)];

function instrumentScenes(): { traces: Trace[]; pay: unknown[] } {
  const traces: Trace[] = [];
  const pay: unknown[] = [];
  // The routine (instrument.test.ts): back turned from 8 m, turn at 2 m, back off, a second pass.
  {
    const c = corridor(9);
    let orderly = createOrderly(c.p);
    let crew = setRaised(createCrew(['me']), 'me', true);
    const rec = new Recorder('routine', 10);
    let me = c.at(8);
    let stage = 0;
    let s = 8;
    let waitTicks = 0;
    for (let k = 0; k < 3000 && stage < 6; k++) {
      let yaw = c.away;
      if (stage === 1 || stage === 2 || stage === 4) yaw = c.toward;
      if (stage === 2) {
        s += 2.2 * DT;
        me = c.at(s);
      }
      const v = view('me', me, yaw);
      const before = orderly;
      const res = stepEntity(c.p, before, [v], DT);
      orderly = res.state;
      const out = stepCrew(c.p, crew, [{ id: 'me', body: me, active: true }], [{ id: 'orderly', trait: 'stillness', prev: before, next: orderly, events: res.events }], DT);
      crew = out.crew;
      rec.tick({ orderly: snapOrderly(orderly), crew: snapCrew(crew) }, [...res.events, ...out.events]);
      const dist = Math.hypot(me.x - orderly.body.x, me.z - orderly.body.z);
      if (stage === 0 && dist <= 2.0) stage = 1;
      else if (stage === 1 && ++waitTicks >= 60) stage = 2;
      else if (stage === 2 && dist >= 8) stage = 3;
      else if (stage === 3 && dist <= 1.25) {
        stage = 4;
        waitTicks = 0;
      } else if (stage === 4 && ++waitTicks >= 60) stage = 6;
    }
    traces.push(rec.done());
    const tape = member(crew, 'me')?.tape;
    pay.push({ scene: 'routine', readings: (tape?.readings ?? []).map((r) => [r.value, ...shown(r.value), r.peakRate, r.duration]), total: [tape?.total ?? 0, ...shown(tape?.total ?? 0)] });
  }
  // Tapes (instrument.test.ts): dropped where caught, picked up within reach, carried, banked or lost.
  {
    const p = generateClinic('tapes', 1);
    const base = createOrderly(p);
    const at = (x: number, z: number): Body => ({ x, z, level: 0, y: 0 });
    const ent = (b: Body): OrderlyState => ({ ...base, mode: 'hunting', body: b });
    let crew = createCrew(['a', 'b', 'c', 'd']);
    for (const id of ['a', 'c', 'd']) crew = setRaised(crew, id, true);
    const pos: Record<string, Body> = { a: at(10, 10), b: at(11, 10), c: at(12, 10), d: at(60, 60) };
    const players = (): CrewPlayer[] => Object.entries(pos).map(([id, body]) => ({ id, body, active: true }));
    let e = ent(at(14, 10));
    const rec = new Recorder('tapes', 10);
    const step = (move: boolean, caught: string[] = []): void => {
      const prev = e;
      if (move) e = ent(at(e.body.x + 0.05, e.body.z));
      const events: OrderlyEvent[] = caught.map((id) => ({ type: 'caught', t: 0, playerId: id }));
      const out = stepCrew(p, crew, players(), [{ id: 'orderly', trait: 'stillness', prev, next: e, events }], DT);
      crew = out.crew;
      rec.tick(snapCrew(crew), out.events);
    };
    for (let k = 0; k < 20; k++) step(true);
    for (let k = 0; k < 40; k++) step(false);
    e = ent(at(64, 60));
    for (let k = 0; k < 20; k++) step(true);
    for (let k = 0; k < 40; k++) step(false);
    step(false, ['a']);
    step(false, ['c']);
    const picks: unknown[] = [];
    const ta = crew.floor[0]?.tape.id ?? '';
    const tc = crew.floor[1]?.tape.id ?? '';
    picks.push(pickUpTape(crew, 'd', ta).reason);
    let up = pickUpTape(crew, 'b', ta);
    picks.push(up.reason, up.event);
    crew = up.crew;
    up = pickUpTape(crew, 'b', tc);
    picks.push(up.reason);
    crew = up.crew;
    picks.push(pickUpTape(crew, 'b', ta).reason);
    step(false, ['d']);
    const dep = leaveFloor(crew);
    const dep2 = leaveFloor(crew, ['a', 'c']);
    const out = stepCrew(p, crew, [...players().filter((x) => x.id !== 'b'), { id: 'b', body: pos.d as Body, active: false }], [], DT);
    picks.push(pickUpTape(out.crew, 'b', crew.floor[0]?.tape.id ?? '').reason);
    traces.push(rec.done());
    pay.push({
      scene: 'tapes', picks: J(picks), carried: dep.carried.map((t) => t.id), lost: dep.lost.map((t) => t.id),
      carriedValue: [dep.carriedValue, ...shown(dep.carriedValue)], lostValue: [dep.lostValue, ...shown(dep.lostValue)],
      carried2: dep2.carried.map((t) => t.id), tapeValue: tapeValue(dep.carried),
    });
  }
  // Staring earns nothing (instrument.test.ts), 30 s.
  {
    const c = corridor(4);
    let orderly = createOrderly(c.p);
    let crew = setRaised(createCrew(['me']), 'me', true);
    const me = c.at(5);
    const rec = new Recorder('stare-earns-nothing', 20);
    for (let k = 0; k < 600; k++) {
      const before = orderly;
      const res = stepEntity(c.p, before, [view('me', me, c.toward)], DT);
      orderly = res.state;
      const out = stepCrew(c.p, crew, [{ id: 'me', body: me, active: true }], [{ id: 'orderly', trait: 'stillness', prev: before, next: orderly, events: res.events }], DT);
      crew = out.crew;
      rec.tick({ orderly: snapOrderly(orderly), crew: snapCrew(crew) }, [...res.events, ...out.events]);
    }
    traces.push(rec.done());
  }
  return { traces, pay };
}

function dumpInstrument(): void {
  const rates = [];
  for (let i = 0; i <= 200; i++) {
    const d = i * 0.05;
    rates.push([d, rateAt(d)]);
  }
  const { traces, pay } = instrumentScenes();
  const tapeOps = (() => {
    let t = emptyTape('t', 'o');
    const vals = [12.5, 0.1, 0.2, 99.99, 1 / 3];
    for (const [i, v] of vals.entries()) t = addReading(t, { id: `r${i}`, playerId: 'o', entityId: 'e', trait: 'stillness', value: v, duration: 1, peakRate: 2, closedAt: 0 });
    return { total: t.total, value: tapeValue(t), shown: shown(t.total) };
  })();
  write('instrument.json', J({ stamina: dumpStamina(), rates, repeat: [0, 1, 2, 3, 7].map(repeatFactor), traces, pay, tapeOps }));
}

// ---------------------------------------------------------------------------------------------
// 7. The run.

interface Actor {
  id: string;
  body: Body;
  yaw: number;
  pitch: number;
  raised?: boolean;
  call?: boolean;
  hold?: boolean;
}
function inputOf(a: Actor): PlayerInput {
  return { id: a.id, body: a.body, eye: BOT_EYE, yaw: a.yaw, pitch: a.pitch, hFovDeg: BOT_HFOV_DEG, vFovDeg: BOT_VFOV_DEG, call: a.call, holdDoors: a.hold, raised: a.raised };
}
function walkActor(st: RunState, a: Actor, waypoints: Body[], speed: number): boolean {
  let budget = speed * DT;
  while (budget > 1e-9 && waypoints.length > 0) {
    const w = waypoints[0] as Body;
    const d = Math.hypot(w.x - a.body.x, w.z - a.body.z);
    if (d < 0.02) {
      waypoints.shift();
      continue;
    }
    const step = Math.min(budget, d);
    const before = a.body;
    a.body = moveInRun(st, a.body, ((w.x - a.body.x) / d) * step, ((w.z - a.body.z) / d) * step, BOT_RADIUS);
    budget -= step;
    if (Math.hypot(a.body.x - before.x, a.body.z - before.z) < 1e-6) break;
  }
  return waypoints.length === 0;
}
const outOfCar = (st: RunState, u: number, v: number): Body[] => [carBody(st.car, 0.45, 0), carBody(st.car, -0.6, 0), carBody(st.car, u, v)];
function lookAt(a: Actor, target: Body): void {
  a.yaw = yawToward(target.x - a.body.x, target.z - a.body.z);
  const d = Math.hypot(target.x - a.body.x, target.z - a.body.z);
  a.pitch = Math.atan2(target.y + 1.7 - (a.body.y + BOT_EYE), Math.max(d, 0.1));
}
function lookAway(a: Actor, target: Body): void {
  a.yaw = yawToward(a.body.x - target.x, a.body.z - target.z);
  a.pitch = 0;
}

/** run.test.ts "a run: scripted from the first floor to the bank", as a closed loop. */
function scriptedRun(): Trace {
  let st = createRun('script-1', ['A', 'B']);
  const A: Actor = { id: 'A', body: st.players[0]?.body as Body, yaw: 0, pitch: 0, raised: true };
  const Bb: Actor = { id: 'B', body: st.players[1]?.body as Body, yaw: 0, pitch: 0 };
  const actors = [A, Bb];
  const rec = new Recorder('scripted-run', 150);
  const tick = (): RunEvent[] => {
    const r = stepRun(st, actors.map(inputOf), DT);
    st = r.state;
    for (const e of r.events) {
      if (e.type === 'rodeDown') for (const a of actors) a.body = e.bodies[a.id] ?? a.body;
      if (e.type === 'doorsClosed') for (const a of actors) a.body = e.pushedOut[a.id] ?? a.body;
    }
    rec.tick(snapRun(st), r.events);
    for (const a of actors) a.call = false;
    return r.events;
  };
  const until = (stop: (ev: RunEvent[]) => boolean, max: number, each?: () => void): void => {
    for (let k = 0; k < max / DT; k++) {
      each?.();
      if (stop(tick())) return;
    }
    throw new Error(`scripted run timed out in ${st.phase}`);
  };
  const has = (ev: RunEvent[], type: RunEvent['type']) => ev.some((e) => e.type === type);
  const floor = (bankAtEnd: boolean): void => {
    A.raised = true;
    until((ev) => has(ev, 'doorsOpened'), 3);
    const outA = outOfCar(st, -1.0, -0.45);
    const outB = outOfCar(st, -1.0, 0.45);
    until((ev) => has(ev, 'carLeft'), 20, () => {
      walkActor(st, A, outA, 2.5);
      walkActor(st, Bb, outB, 2.5);
    });
    let turned = false;
    until((ev) => turned && ev.some((e) => e.type === 'readingClosed' && e.playerId === 'A'), 240, () => {
      const o = st.orderly.body;
      if (!turned && Math.min(Math.hypot(A.body.x - o.x, A.body.z - o.z), Math.hypot(Bb.body.x - o.x, Bb.body.z - o.z)) <= 2.0) turned = true;
      for (const a of actors) (turned ? lookAt : lookAway)(a, o);
    });
    A.raised = false;
    A.call = true;
    const crew = actors.map((a, k) => {
      const b = createWaitBot(st, a.id, k, 'flee');
      b.body = a.body;
      b.seat = { u: 0.8 + 0.5 * k, v: bankAtEnd ? -0.5 : 0.5 };
      return b;
    });
    let first = true;
    until((ev) => has(ev, 'bell'), 80 + BOARD_TIME + HOLD_LIMIT, () => {
      // run.test.ts's oracleInCar: strictly inside the car's cell, any level.
      const r = st.car.rect;
      const waiting = crew.some((b) => !(b.body.x > r.x0 && b.body.x < r.x1 && b.body.z > r.z0 && b.body.z < r.z1));
      crew.forEach((b, k) => {
        if (!first) stepWaitBot(st, b, DT);
        const a = actors[k] as Actor;
        a.body = b.body;
        a.yaw = b.yaw;
        a.pitch = b.pitch;
        a.hold = b.mode === 'aboard' && waiting;
      });
      first = false;
    });
  };
  floor(false);
  until((ev) => has(ev, 'rodeDown'), 10);
  floor(true);
  return rec.done();
}

function boardingRun(seed: string, ids: string[]): RunState {
  const st = createRun(seed, ids);
  return {
    ...st, phase: 'boarding', bellLeft: BOARD_TIME, holdLeft: HOLD_LIMIT,
    players: st.players.map((p, i): RunPlayer => ({ ...p, body: carBody(st.car, -0.8, i % 2 ? 0.5 : -0.5), aboard: false })),
    orderly: { ...st.orderly, mode: 'dormant', dormantLeft: 1e9 },
  };
}
const BANK_SPOT = (st: RunState, k = 0): Body => carBody(st.car, 0.8 + 0.5 * (k % 2), -0.5);
const DOWN_SPOT = (st: RunState, k = 0): Body => carBody(st.car, 0.8 + 0.5 * (k % 2), 0.5);

/** Vote, hold and left-behind scenes from run.test.ts: every event and the end state. */
function runScenes(): Trace[] {
  const traces: Trace[] = [];
  const scene = (name: string, st0: RunState, actors: Actor[], seconds: number, each?: (st: RunState, k: number) => void, stopOn = 'bell') => {
    let st = st0;
    const rec = new Recorder(name, 100);
    for (let k = 0; k < seconds / DT; k++) {
      each?.(st, k);
      const r = stepRun(st, actors.map(inputOf), DT);
      st = r.state;
      for (const e of r.events) if (e.type === 'rodeDown') for (const a of actors) a.body = e.bodies[a.id] ?? a.body;
      rec.tick(snapRun(st), r.events);
      for (const a of actors) a.call = false;
      if (r.events.some((e) => e.type === stopOn)) break;
    }
    traces.push(rec.done());
  };
  const vote = (name: string, spots: ((st: RunState) => Body)[]) => {
    const ids = spots.map((_, k) => `v${k}`);
    const st = boardingRun(name, ids);
    const actors: Actor[] = ids.map((id, k) => ({ id, body: (spots[k] as (s: RunState) => Body)(st), yaw: 0, pitch: 0 }));
    scene(name, st, actors, BOARD_TIME + 8, undefined, 'rodeDown');
  };
  vote('vote-1', [(s) => BANK_SPOT(s, 0), (s) => BANK_SPOT(s, 1), (s) => DOWN_SPOT(s, 0)]);
  vote('vote-tie-2', [(s) => BANK_SPOT(s, 0), (s) => DOWN_SPOT(s, 0)]);
  vote('vote-tie-4', [(s) => BANK_SPOT(s, 0), (s) => BANK_SPOT(s, 1), (s) => DOWN_SPOT(s, 0), (s) => DOWN_SPOT(s, 1)]);
  vote('vote-down-3', [(s) => DOWN_SPOT(s, 0), (s) => DOWN_SPOT(s, 1), (s) => BANK_SPOT(s, 0)]);
  vote('vote-empty', [(s) => carBody(s.car, -1, 0)]);
  {
    const st = boardingRun('vote-switch', ['v0', 'v1']);
    const a: Actor = { id: 'v0', body: BANK_SPOT(st, 0), yaw: 0, pitch: 0 };
    const b: Actor = { id: 'v1', body: DOWN_SPOT(st, 0), yaw: 0, pitch: 0 };
    scene('vote-switch', st, [a, b], BOARD_TIME + 1, (s) => {
      if (s.t >= BOARD_TIME - 2) b.body = BANK_SPOT(s, 1);
    });
  }
  {
    const st = boardingRun('hold-1', ['in', 'out']);
    const inside: Actor = { id: 'in', body: DOWN_SPOT(st), yaw: 0, pitch: 0 };
    const outside: Actor = { id: 'out', body: carBody(st.car, -1, 0), yaw: 0, pitch: 0, hold: true };
    scene('hold-1', st, [inside, outside], 60, (s) => {
      inside.hold = s.t >= 5 && s.t < 12;
    });
  }
  {
    const st = boardingRun('hold-2', ['in', 'late']);
    const inside: Actor = { id: 'in', body: DOWN_SPOT(st), yaw: 0, pitch: 0, hold: true };
    const late: Actor = { id: 'late', body: carBody(st.car, -1.2, 0.3), yaw: 0, pitch: 0 };
    const route = [carBody(st.car, -0.6, 0), carBody(st.car, 0.45, 0), carBody(st.car, 1.3, 0.5)];
    scene('hold-2', st, [inside, late], 60, (s) => {
      if (s.t >= 28) walkActor(s, late, route, 2.5);
    }, 'rodeDown');
  }
  {
    let st = boardingRun('behind-1', ['aboard', 'behind', 'caught']);
    const tapeWith = (id: string, owner: string, values: number[]): Tape => {
      let t = emptyTape(id, owner);
      values.forEach((v, i) => (t = addReading(t, { id: `${id}-r${i}`, playerId: owner, entityId: 'test', trait: 'stillness', value: v, duration: 2, peakRate: 50, closedAt: 0 })));
      return t;
    };
    const crew = st.crew;
    st = {
      ...st,
      players: st.players.map((p): RunPlayer => (p.id === 'caught' ? { ...p, status: 'caught' } : p)),
      crew: {
        ...crew,
        members: crew.members.map((m) => (m.id === 'aboard' ? { ...m, tape: tapeWith(m.tape.id, m.id, [30, 12]) } : m.id === 'behind' ? { ...m, tape: tapeWith(m.tape.id, m.id, [50]), carrying: [tapeWith('tape-x', 'someone', [20])] } : m)),
        floor: [{ tape: tapeWith('tape-floor', 'caught', [40]), at: carBody(st.car, -3, 0) }],
      },
    };
    const a: Actor = { id: 'aboard', body: DOWN_SPOT(st), yaw: 0, pitch: 0 };
    const b: Actor = { id: 'behind', body: carBody(st.car, -1.5, 0), yaw: 0, pitch: 0, raised: true };
    const c: Actor = { id: 'caught', body: carBody(st.car, -3, 0), yaw: 0, pitch: 0 };
    scene('behind-1', st, [a, b, c], BOARD_TIME + 12, undefined, 'doorsOpened');
  }
  {
    // A wipe: one player, looking away from it, on the landing (run.test.ts).
    let st = createRun('wipe-1', ['solo']);
    const spot = carBody(st.car, -1, 0);
    const dist = distancesFrom(st.plan, st.plan.landing);
    const cands: Pos[] = [];
    for (let i = 0; i < dist.length; i++) {
      const d = dist[i] ?? -1;
      if (d < 3 || d > 8) continue;
      const p = posFromIndex(st.plan, i);
      if (p.level !== 0 || !isWalkable(st.plan, 0, p.x, p.y) || cellAt(st.plan, 0, p.x, p.y) === 'stair') continue;
      cands.push(p);
    }
    const start = makeRng('wipe').fork('o').pick(cands);
    st = { ...st, phase: 'away', players: st.players.map((p): RunPlayer => ({ ...p, body: spot, aboard: false })), orderly: { ...createOrderly(st.plan), body: bodyAtCell(st.plan, start), mode: 'hunting' } };
    const solo: Actor = { id: 'solo', body: spot, yaw: 0, pitch: 0 };
    scene('wipe-1', st, [solo], 120, (s) => lookAway(solo, s.orderly.body), 'wiped');
  }
  {
    // Calls with nobody boarding: the indicator, false stops and their door sounds (run.test.ts).
    for (const r of [0, 1]) {
      let st = createRun(`wait-${r}`, ['caller']);
      const spot = carBody(st.car, -1, 0);
      st = { ...st, phase: 'away', players: st.players.map((p): RunPlayer => ({ ...p, body: spot, aboard: false })), orderly: { ...st.orderly, mode: 'dormant', dormantLeft: 1e9 } };
      const caller: Actor = { id: 'caller', body: spot, yaw: 0, pitch: 0 };
      let calls = 0;
      scene(`calls-${r}`, st, [caller], 200, (s) => {
        if (s.phase === 'away' && calls < 3) {
          caller.call = true;
          calls++;
        }
      }, 'never');
    }
  }
  return traces;
}

function dumpRun(): void {
  const plans = [];
  for (let i = 0; i < 200; i++) {
    const prev = i % 5 === 0 ? null : 6 + (i % 7);
    const depth = 1 + (i % 4);
    plans.push({ seed: `sched-${i}`, index: i % 3, prev, depth, plan: snapCallPlan(callPlan(`sched-${i}`, i % 3, prev, depth)) });
  }
  const mult = Array.from({ length: 12 }, (_, d) => depthMultiplier(d));
  const scripted = scriptedRun();
  const scenes = runScenes();
  // Whole waits for the car with wait bots (tests/sim/waits.ts), every event.
  const waits = [];
  for (const style of ['stay', 'flee'] as const) {
    for (const depth of [1, 2, 3]) {
      for (const i of [0, 1, 2, 5]) {
        const r = runWait(style, depth, i);
        waits.push({ style, depth, i, caught: r.caught, boarded: r.boarded, caughtInBlackout: r.caughtInBlackout, caughtAfter: r.caughtAfter, darks: r.darks, closest: r.closest, farthest: r.farthest, boardedAfter: r.boardedAfter, events: r.events.map(snapEvent) });
      }
    }
  }
  write('run.json', J({ plans, mult, scripted, scenes, waits }));
}

// ---------------------------------------------------------------------------------------------
// 8. Bot crews (mirrored in godot/tests/ref_bots.gd): bots wander, the Orderly hunts them, every
// instrument is raised, one bot keeps lowering and raising its own, tapes are dropped and picked up.

function botCrew(i: number): Trace {
  const seed = `crew-${i}`;
  const depth = 1 + (i % 4);
  const nBots = 1 + (Math.floor(i / 4) % 4);
  const p = generateClinic(seed, depth);
  const rng = makeRng(seed).fork('setup');
  const toggles = makeRng(seed).fork('toggles');
  const bots: Bot[] = [];
  for (let b = 0; b < nBots; b++) {
    const oblivious = b === 0 && i % 3 === 0;
    bots.push(createBot(p, `bot${b}`, `${seed}:${b}`, { watchfulness: rng.next(), oblivious, start: b === 0 ? p.landing : undefined }));
  }
  const ids = bots.map((b) => b.id);
  const active = new Map(ids.map((id) => [id, true]));
  let crew = createCrew(ids);
  for (const id of ids) crew = setRaised(crew, id, true);
  let toggleIn = 2 + toggles.next() * 6;
  let orderly = createOrderly(p);
  const rec = new Recorder(seed, 450);
  for (let tick = 0; tick < 90 / DT; tick++) {
    toggleIn -= DT;
    if (toggleIn <= 0 && nBots > 1) {
      toggleIn = 1 + toggles.next() * 6;
      const m = member(crew, 'bot1');
      if (m) crew = setRaised(crew, 'bot1', !m.instrument.raised);
    }
    for (const b of bots) if (active.get(b.id)) stepBot(p, b, DT, member(crew, b.id)?.instrument.raised ? null : orderly.body, member(crew, b.id)?.instrument.raised ? 2.2 : Infinity);
    const views: PlayerView[] = bots.map((b) => ({ ...botView(b), active: active.get(b.id) ?? false }));
    const before = orderly;
    const res = stepEntity(p, before, views, DT);
    orderly = res.state;
    const players: CrewPlayer[] = views.map((v) => ({ id: v.id, body: v.body, active: v.active }));
    const out = stepCrew(p, crew, players, [{ id: 'orderly', trait: 'stillness', prev: before, next: orderly, events: res.events }], DT);
    crew = out.crew;
    const events: unknown[] = [...res.events, ...out.events];
    for (const e of res.events) if (e.type === 'caught') active.set(e.playerId, false);
    for (const f of [...crew.floor]) {
      for (const k of ids.keys()) {
        const id = ids[k] as string;
        const pl = players[k] as CrewPlayer;
        if (!active.get(id) || !pl.active || Math.hypot(pl.body.x - f.at.x, pl.body.y - f.at.y, pl.body.z - f.at.z) > 1.3) continue;
        const up = pickUpTape(crew, id, f.tape.id);
        if (up.ok) {
          crew = up.crew;
          events.push(up.event);
          break;
        }
      }
    }
    rec.tick({ bots: bots.map(snapBot), orderly: snapOrderly(orderly), crew: snapCrew(crew) }, events);
  }
  return rec.done();
}

function dumpBots(): void {
  const traces = [];
  for (let i = 0; i < 30; i++) traces.push(botCrew(i));
  write('bots.json', J(traces));
}

// ---------------------------------------------------------------------------------------------

// ---------------------------------------------------------------------------------------------
// 9. Float literals. GDScript's parser turns some decimal literals into the wrong double (measured:
// 269 of 6011 random literals of up to 15 digits). Every float literal in godot/sim is listed in a
// generated GDScript file beside the bits JavaScript gives it, so the compiler's reading is tested.

function dumpLiterals(): void {
  const simDir = join(OUT, '..', '..', 'sim');
  const found = new Map<string, string>();
  for (const name of readdirSync(simDir).filter((n) => n.endsWith('.gd')).sort()) {
    const text = readFileSync(join(simDir, name), 'utf8')
      .split('\n')
      .map((line) => line.replace(/"(?:[^"\\]|\\.)*"/g, '""').replace(/#.*$/, ''))
      .join('\n');
    for (const m of text.matchAll(/(?<![\w.])(\d+\.\d*(?:[eE][-+]?\d+)?|\d+[eE][-+]?\d+)(?![\w.])/g)) {
      const lit = m[1] as string;
      if (!found.has(lit)) found.set(lit, name);
    }
  }
  const lits = [...found.keys()];
  const gd = [
    '# Generated by godot/tools/dump_reference.ts: every float literal in godot/sim, and the bits',
    '# JavaScript reads it as. tests/test_jsmath.gd checks that GDScript reads each the same way.',
    'extends RefCounted',
    '',
    'const LITERALS: Array[float] = [',
    ...lits.map((l) => `\t${l},`),
    ']',
    'const TEXT: Array[String] = [',
    ...lits.map((l) => `\t"${l}",`),
    ']',
    'const BITS: Array[String] = [',
    ...lits.map((l) => `\t"${hex(Number(l))}",`),
    ']',
    '',
  ].join('\n');
  writeFileSync(join(OUT, '..', 'literals_generated.gd'), gd);
  console.log(`literals_generated.gd: ${lits.length} literals`);
}

/** Samples of the transcendental functions, for tests/test_jsmath.gd. */
function dumpMath(): void {
  const r = makeRng('math');
  const rows: Record<string, unknown[]> = { sin: [], cos: [], tan: [], atan: [], atan2: [], exp: [], hypot2: [], hypot3: [], powInt: [], fixed: [] };
  for (let i = 0; i < 2000; i++) {
    const x = (r.next() - 0.5) * 40;
    const y = (r.next() - 0.5) * 80;
    const z = (r.next() - 0.5) * 3;
    rows.sin?.push([x, Math.sin(x)]);
    rows.cos?.push([x, Math.cos(x)]);
    rows.tan?.push([z / 2, Math.tan(z / 2)]);
    rows.atan?.push([y, Math.atan(y)]);
    rows.atan2?.push([x, y, Math.atan2(x, y)]);
    rows.exp?.push([-Math.abs(y) * 3, Math.exp(-Math.abs(y) * 3)]);
    rows.hypot2?.push([x, y, Math.hypot(x, y)]);
    rows.hypot3?.push([x, y, z, Math.hypot(x, y, z)]);
    const k = r.next();
    rows.powInt?.push([k, 2, k ** 2], [k, 3, k ** 3]);
    const v = r.next() * 3000;
    rows.fixed?.push([v, v.toFixed(0), v.toFixed(1), v.toFixed(2)]);
  }
  for (let n = 0; n < 12; n++) rows.powInt?.push([1.35, n, 1.35 ** n]);
  for (const v of [0.125, 1.005, 2.5, 0.5, 1.5, -0.001, 0, 187.55, 246.85]) rows.fixed?.push([v, v.toFixed(0), v.toFixed(1), v.toFixed(2)]);
  write('math.json', J({ ...rows, hfov: BOT_HFOV_DEG }));
}

// ---------------------------------------------------------------------------------------------
// 11. The client's rules bridge: the reference host (rules_host.ts, the interim TypeScript host of
// the Godot client) driven by bridge_script.ts. Every reply is recorded as the client received it
// (JSON): per request the two digests of the reply without its events and plan, every event, the
// full reply every 20 requests and the last, every plan in full, and per request the pay-derived
// values (compared within 1e-9) plus the run's tick count.

function payOf(r: any): unknown[] {
  return [r.inst?.value ?? null, r.inst?.rate ?? null, r.inst?.tickHz ?? null, r.inst?.loudness ?? null, r.tapes?.value ?? null, r.ticks ?? null, r.summary?.total ?? null];
}

/** The keys of a frame request, in the order a compact frame row carries them (ref_bridge.gd FRAME_KEYS). */
const FRAME_KEYS = ['dt', 'f', 'r', 'sprint', 'creep', 'yaw', 'pitch', 'hfov', 'vfov', 'raised', 'call', 'hold', 'pickUp', 'still', 'timeScale'];
/** Frame requests as rows [values in FRAME_KEYS order] (they are most of the file); other requests as they are. */
function compactRequest(r: Record<string, unknown>): unknown {
  if (r.op !== 'frame') return r;
  const keys = Object.keys(r).filter((k) => k !== 'op');
  if (keys.length !== FRAME_KEYS.length || !FRAME_KEYS.every((k) => k in r)) throw new Error(`frame request with other keys: ${keys}`);
  return FRAME_KEYS.map((k) => r[k]);
}

function dumpBridge(): void {
  const scenes = bridgeScenes().map((sc) => {
    const rec = new Recorder(sc.name, 20);
    const plans: Record<string, unknown> = {};
    sc.replies.forEach((reply, k) => {
      const { events, plan, ...rest } = reply as Record<string, unknown>;
      if (plan !== undefined) plans[String(k)] = J(plan);
      rec.tick(rest, (events as unknown[] | undefined) ?? [], payOf(reply));
    });
    const types: Record<string, number> = {};
    for (const r of sc.replies) for (const e of (r.events ?? []) as { type: string }[]) types[e.type] = (types[e.type] ?? 0) + 1;
    const caughtIn = sc.replies.filter((r) => (r.events ?? []).some((e: { type: string }) => e.type === 'caught')).map((r) => (r.blackout ? 'blackout' : r.dark ? 'blink' : 'light'));
    console.log(`  ${sc.name}: ${sc.requests.length} requests, events ${JSON.stringify(types)}, caught in: ${caughtIn.join(',') || '-'}`);
    return { name: sc.name, frameKeys: FRAME_KEYS, requests: J(sc.requests.map(compactRequest)), trace: rec.done(), plans };
  });
  write('bridge.json', { scenes });
}

const only = process.argv[2];
const jobs: Record<string, () => void> = {
  literals: dumpLiterals,
  math: dumpMath,
  rng: dumpRng,
  floors: dumpFloors,
  move: dumpMove,
  sight: dumpSight,
  entity: () => write('entity.json', J(entityScenes())),
  instrument: dumpInstrument,
  run: dumpRun,
  bots: dumpBots,
  bridge: dumpBridge,
};
for (const [name, job] of Object.entries(jobs)) {
  if (only && only !== name) continue;
  const t0 = performance.now();
  job();
  console.log(`  ${name} in ${((performance.now() - t0) / 1000).toFixed(1)} s`);
}
// Keep the unused imports honest: these are part of the surface the Godot port mirrors.
void [blackedOut, doorsOpen, stepWaitBot, edgeKind, waitBotInput, snapWaitBot, cellOf];
