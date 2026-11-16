import { describe, expect, it } from 'vitest';
import { createBot, stepBot, BOT_EYE, BOT_HFOV_DEG, BOT_RADIUS, BOT_VFOV_DEG, type Bot } from '../../src/sim/bot';
import { createOrderly, ORDERLY_RADIUS, yawToward, type OrderlyState } from '../../src/sim/entity';
import { canStep, cellAt, DIR_VEC, distancesFrom, findPath, hasDoor, isWalkable, posFromIndex, roomIdAt, type FloorPlan, type Pos } from '../../src/sim/floor';
import { pathDone, stepPathWalk, type PathWalk } from '../../src/sim/follow';
import { member } from '../../src/sim/instrument';
import { elevatorWall } from '../../src/sim/landing';
import { bodyAtCell, cellOf, type Body } from '../../src/sim/move';
import { makeRng, type Rng } from '../../src/sim/rng';
import {
  BLINK_INTERVAL_MAX,
  BLINK_INTERVAL_MIN,
  BLINK_TIME,
  BOARD_TIME,
  carBody,
  createRun,
  depthMultiplier,
  doorsOpen,
  FALSE_STOP_CHANCE,
  FLOOR_TIME,
  HOLD_LIMIT,
  LURE_ID,
  moveInRun,
  stepRun,
  type PlayerInput,
  type RunEvent,
  type RunPlayer,
  type RunState,
} from '../../src/sim/run';
import { addReading, emptyTape, tapeValue, type Reading, type Tape } from '../../src/sim/tape';

const DT = 0.05;

// =============================================================================================
// Independent oracles, written here and sharing nothing with run.ts or sight.ts.
// =============================================================================================

interface Box {
  x0: number;
  z0: number;
  x1: number;
  z1: number;
}

/** The car: the plan cell on the far side of the landing's elevator wall. Checked to be void. */
function oracleCar(plan: FloorPlan): Box {
  const w = elevatorWall(plan);
  if (!w) throw new Error('no elevator wall');
  const v = DIR_VEC[w];
  const cx = plan.landing.x + v.dx;
  const cy = plan.landing.y + v.dy;
  expect(cellAt(plan, 0, cx, cy)).toBe('void');
  expect(cellAt(plan, 1, cx, cy)).toBe('void');
  const s = plan.cellSize;
  return { x0: cx * s, z0: cy * s, x1: (cx + 1) * s, z1: (cy + 1) * s };
}

function boxDistance(b: Box, x: number, z: number): number {
  const dx = Math.max(b.x0 - x, 0, x - b.x1);
  const dz = Math.max(b.z0 - z, 0, z - b.z1);
  return Math.hypot(dx, dz);
}

function oracleInCar(b: Box, body: Body): boolean {
  return body.x > b.x0 && body.x < b.x1 && body.z > b.z0 && body.z < b.z1;
}

/**
 * A deliberately strict line-of-sight check, used only to say "this was surely visible". Both ends
 * on level 0 below door height (eye 1.65 m, chest 1.7 m): the segment is sampled every 5 cm, and
 * every cell boundary it crosses must be passable by the floor rules (same room, corridor to
 * corridor, or a door, inside 0.5 m of the door's centre). A diagonal corner needs both ways round.
 */
function surelyClear(plan: FloorPlan, a: { x: number; z: number }, b: { x: number; z: number }): boolean {
  const cs = plan.cellSize;
  const n = Math.max(1, Math.ceil(Math.hypot(b.x - a.x, b.z - a.z) / 0.05));
  const edge = (p: { x: number; y: number }, q: { x: number; y: number }, mx: number, mz: number): boolean => {
    const A: Pos = { level: 0, x: p.x, y: p.y };
    const B: Pos = { level: 0, x: q.x, y: q.y };
    if (!canStep(plan, A, B)) return false;
    const ra = roomIdAt(plan, 0, p.x, p.y);
    const same = ra >= 0 && ra === roomIdAt(plan, 0, q.x, q.y);
    const corr = cellAt(plan, 0, p.x, p.y) === 'corridor' && cellAt(plan, 0, q.x, q.y) === 'corridor';
    if (same || corr || !hasDoor(plan, 0, p.x, p.y, q.x, q.y)) return true;
    const lateral = p.x !== q.x ? mz - (p.y + 0.5) * cs : mx - (p.x + 0.5) * cs;
    return Math.abs(lateral) <= 0.5;
  };
  let pc = { x: Math.floor(a.x / cs), y: Math.floor(a.z / cs) };
  let prev = a;
  for (let i = 1; i <= n; i++) {
    const q = { x: a.x + ((b.x - a.x) * i) / n, z: a.z + ((b.z - a.z) * i) / n };
    const qc = { x: Math.floor(q.x / cs), y: Math.floor(q.z / cs) };
    if (qc.x !== pc.x || qc.y !== pc.y) {
      const mx = (prev.x + q.x) / 2;
      const mz = (prev.z + q.z) / 2;
      const d = Math.abs(qc.x - pc.x) + Math.abs(qc.y - pc.y);
      if (d === 1) {
        if (!edge(pc, qc, mx, mz)) return false;
      } else {
        const v1 = { x: qc.x, y: pc.y };
        const v2 = { x: pc.x, y: qc.y };
        if (!(edge(pc, v1, mx, mz) && edge(v1, qc, mx, mz) && edge(pc, v2, mx, mz) && edge(v2, qc, mx, mz))) return false;
      }
    }
    pc = qc;
    prev = q;
  }
  return true;
}

/** A staring viewer at `from` surely sees the figure at `fig`: both on level 0's floor, clear sight to its chest, aimed at it. */
function oracleStareSees(plan: FloorPlan, from: Body, yaw: number, fig: Body): boolean {
  if (from.level !== 0 || fig.level !== 0 || from.y !== 0 || fig.y !== 0) return false;
  // Aimed within 30 degrees of the chest (true half-fov is 35 vertical, 51 horizontal).
  const want = Math.atan2(-(fig.x - from.x), -(fig.z - from.z));
  let d = Math.abs(want - yaw) % (2 * Math.PI);
  if (d > Math.PI) d = 2 * Math.PI - d;
  if (d > (30 * Math.PI) / 180) return false;
  return surelyClear(plan, from, fig);
}

// =============================================================================================
// Helpers.
// =============================================================================================

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

/** Steps the run with the actors' inputs, logs events, and moves actors the run placed (rides, push-outs). */
function tick(st: RunState, actors: Actor[], log: RunEvent[]): { st: RunState; ev: RunEvent[] } {
  const r = stepRun(st, actors.map(inputOf), DT);
  log.push(...r.events);
  for (const e of r.events) {
    if (e.type === 'rodeDown') for (const a of actors) a.body = e.bodies[a.id] ?? a.body;
    if (e.type === 'doorsClosed') for (const a of actors) a.body = e.pushedOut[a.id] ?? a.body;
  }
  return { st: r.state, ev: r.events };
}

function lookAt(a: Actor, target: Body): void {
  a.yaw = yawToward(target.x - a.body.x, target.z - a.body.z);
  const d = Math.hypot(target.x - a.body.x, target.z - a.body.z);
  a.pitch = Math.atan2(target.y + 1.7 - (a.body.y + BOT_EYE), Math.max(d, 0.1));
}

function lookAway(a: Actor, target: Body): void {
  a.yaw = yawToward(a.body.x - target.x, a.body.z - target.z);
  a.pitch = 0;
}

/** Walks an actor toward a list of waypoints at `speed`; returns true once at the last one. */
function walk(st: RunState, a: Actor, waypoints: Body[], speed: number): boolean {
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

const intoCar = (st: RunState, u: number, v: number): Body[] => [carBody(st.car, -0.6, 0), carBody(st.car, 0.45, 0), carBody(st.car, u, v)];
const outOfCar = (st: RunState, u: number, v: number): Body[] => [carBody(st.car, 0.45, 0), carBody(st.car, -0.6, 0), carBody(st.car, u, v)];

function dist2(a: Body, b: Body): number {
  return Math.hypot(a.x - b.x, a.z - b.z);
}

function aReading(id: string, playerId: string, value: number): Reading {
  return { id, playerId, entityId: 'test', trait: 'stillness', value, duration: 2, peakRate: 50, closedAt: 0 };
}

function tapeWith(id: string, owner: string, values: number[]): Tape {
  let t = emptyTape(id, owner);
  values.forEach((v, i) => (t = addReading(t, aReading(`${id}-r${i}`, owner, v))));
  return t;
}

/** A run with the car standing open at floor 1's landing and the Orderly asleep far away. */
function boardingRun(seed: string, ids: string[]): RunState {
  const st = createRun(seed, ids);
  return {
    ...st,
    phase: 'boarding',
    bellLeft: BOARD_TIME,
    holdLeft: HOLD_LIMIT,
    players: st.players.map((p, i): RunPlayer => ({ ...p, body: carBody(st.car, -0.8, i % 2 ? 0.5 : -0.5), aboard: false })),
    orderly: { ...st.orderly, mode: 'dormant', dormantLeft: 1e9 },
  };
}

const BANK_SPOT = (st: RunState, k = 0): Body => carBody(st.car, 0.8 + 0.5 * (k % 2), -0.5);
const DOWN_SPOT = (st: RunState, k = 0): Body => carBody(st.car, 0.8 + 0.5 * (k % 2), 0.5);

function runUntil(st0: RunState, actors: Actor[], log: RunEvent[], stop: (ev: RunEvent[], st: RunState) => boolean, maxSeconds: number, each?: (st: RunState) => void): RunState {
  let st = st0;
  for (let k = 0; k < maxSeconds / DT; k++) {
    each?.(st);
    const r = tick(st, actors, log);
    st = r.st;
    for (const a of actors) a.call = false;
    if (stop(r.ev, st)) return st;
  }
  throw new Error(`timed out after ${maxSeconds} s in phase ${st.phase}`);
}

const has = (ev: RunEvent[], type: RunEvent['type']): boolean => ev.some((e) => e.type === type);

function hashText(h: number, text: string): number {
  for (let i = 0; i < text.length; i++) h = Math.imul(h ^ text.charCodeAt(i), 16777619);
  return h >>> 0;
}

// =============================================================================================
// 1. A whole run, scripted.
// =============================================================================================

describe('a run: scripted from the first floor to the bank', () => {
  it('board, arrive, step out, the car leaves; earn; call; ride down; earn deeper; call; bank', () => {
    const log: RunEvent[] = [];
    let st = createRun('script-1', ['A', 'B']);
    const A: Actor = { id: 'A', body: st.players[0]?.body as Body, yaw: 0, pitch: 0, raised: true };
    const B: Actor = { id: 'B', body: st.players[1]?.body as Body, yaw: 0, pitch: 0 };
    const actors = [A, B];
    const readings: { value: number; raw: number; depth: number }[] = [];
    let carBox = oracleCar(st.plan);
    const safety = (s: RunState): void => {
      expect(boxDistance(carBox, s.orderly.body.x, s.orderly.body.z)).toBeGreaterThanOrEqual(ORDERLY_RADIUS - 1e-3);
    };

    const floor = (bankAtEnd: boolean): void => {
      A.raised = true; // raised to earn on this floor; lowered again for the wait
      const depth = st.depth;
      carBox = oracleCar(st.plan);
      // Arrival: the doors open onto the landing.
      expect(st.players.every((p) => oracleInCar(carBox, p.body))).toBe(true);
      st = runUntil(st, actors, log, (ev) => has(ev, 'doorsOpened'), 3, safety);
      expect(st.phase).toBe('unloading');
      // Step out; the car leaves without us.
      const outA = outOfCar(st, -1.0, -0.45);
      const outB = outOfCar(st, -1.0, 0.45);
      st = runUntil(st, actors, log, (ev) => has(ev, 'carLeft'), 20, (s) => {
        walk(s, A, outA, 2.5);
        walk(s, B, outB, 2.5);
        safety(s);
      });
      expect(st.phase).toBe('away');
      expect(actors.every((a) => !oracleInCar(carBox, a.body))).toBe(true);

      // The routine: backs turned until it is within 2 m, then turn round and watch it.
      let turned = false;
      let lastOpen = 0;
      st = runUntil(
        st,
        actors,
        log,
        (ev) => {
          const closed = ev.find((e) => e.type === 'readingClosed' && e.playerId === 'A');
          if (closed && closed.type === 'readingClosed') readings.push({ value: closed.value, raw: lastOpen, depth });
          lastOpen = member(st.crew, 'A')?.instrument.current?.value ?? lastOpen;
          return turned && closed !== undefined;
        },
        240,
        (s) => {
          lastOpen = member(s.crew, 'A')?.instrument.current?.value ?? 0;
          const o = s.orderly.body;
          if (!turned && Math.min(dist2(A.body, o), dist2(B.body, o)) <= 2.0) turned = true;
          for (const a of actors) (turned ? lookAt : lookAway)(a, o);
          safety(s);
        },
      );
      const r = readings[readings.length - 1];
      expect(r).toBeDefined();
      expect(r?.raw).toBeGreaterThan(5);
      // Depth pays: the reading on the tape is the recorded value times this depth's multiplier.
      expect(r?.value).toBeCloseTo((r?.raw ?? 0) * depthMultiplier(depth), 6);
      const onTape = member(st.crew, 'A')?.tape.readings.at(-1);
      expect(onTape?.value).toBeCloseTo(r?.value ?? -1, 9);

      // Call, keep watching it; the indicator counts down floor by floor. The instrument goes down
      // for the wait: left raised it would go on recording every time the lights blink (which is a
      // real way to earn during the wait, but this script counts exactly one reading per floor).
      A.raised = false;
      A.call = true;
      const indicator: number[] = [];
      st = runUntil(st, actors, log, (ev) => {
        for (const e of ev) if (e.type === 'indicator') indicator.push(e.floorsAway);
        return has(ev, 'carArrived');
      }, 80, (s) => {
        // Staring alone is not safe: it gains ground in every blink. The counterplay is to keep it
        // at a distance, so each player backs away from it whenever it is within five metres.
        for (const a of actors) {
          const o = s.orderly.body;
          const dx = a.body.x - o.x;
          const dz = a.body.z - o.z;
          const d = Math.hypot(dx, dz);
          if (d < 5 && d > 1e-6) walk(s, a, [{ ...a.body, x: a.body.x + (dx / d) * 2, z: a.body.z + (dz / d) * 2 }], 2.5);
          lookAt(a, o);
        }
        safety(s);
      });
      expect(indicator.length).toBeGreaterThanOrEqual(7);
      indicator.forEach((f, k) => expect(f).toBe((indicator[0] ?? 0) - k));
      expect(indicator.at(-1)).toBe(0);
      expect(doorsOpen(st)).toBe(true);

      // Board onto one side, still watching it, and wait for the bell.
      const inA = intoCar(st, 0.8, bankAtEnd ? -0.5 : 0.5);
      const inB = intoCar(st, 1.3, bankAtEnd ? -0.5 : 0.5);
      let bell: RunEvent | undefined;
      st = runUntil(st, actors, log, (ev) => {
        bell = ev.find((e) => e.type === 'bell');
        return bell !== undefined;
      }, BOARD_TIME + 2, (s) => {
        walk(s, A, inA, 2.0);
        walk(s, B, inB, 2.0);
        for (const a of actors) lookAt(a, s.orderly.body);
        safety(s);
      });
      expect(bell && bell.type === 'bell' ? [bell.bank, bell.down, bell.outcome] : null).toEqual(bankAtEnd ? [2, 0, 'bank'] : [0, 2, 'ride']);
    };

    floor(false);
    // Riding down: tapes ride along unbanked, a new deeper floor and a fresh Orderly.
    expect(st.phase).toBe('riding');
    const firstPlan = st.plan;
    const carried = member(st.crew, 'A')?.tape.readings.length;
    expect(carried).toBe(1);
    st = runUntil(st, actors, log, (ev) => has(ev, 'rodeDown'), 10);
    expect(st.depth).toBe(2);
    expect(st.plan).not.toBe(firstPlan);
    expect(st.plan.depth).toBe(2);
    expect(st.orderly.mode).toBe('waiting');
    expect(st.entityId).toBe('orderly-2');
    expect(member(st.crew, 'A')?.tape.readings.length).toBe(1);
    expect(st.summary).toBeNull();

    floor(true);
    expect(depthMultiplier(2)).toBeCloseTo(1.35, 12);
    expect(readings.map((r) => r.depth)).toEqual([1, 2]);
    const banked = log.find((e) => e.type === 'banked');
    if (!banked || banked.type !== 'banked') throw new Error('not banked');
    const total = readings.reduce((s, r) => s + r.value, 0);
    expect(banked.summary.total).toBeCloseTo(total, 6);
    expect(banked.summary.depth).toBe(2);
    expect(banked.summary.readings).toBe(2);
    expect(banked.summary.shares.A).toBeCloseTo(total / 2, 6);
    expect(banked.summary.shares.B).toBeCloseTo(total / 2, 6);
    expect(st.phase).toBe('ended');
    expect(log.some((e) => e.type === 'caught')).toBe(false);
    // The event stream has the shape the design describes.
    const order = log.map((e) => e.type).filter((x) => ['doorsOpened', 'carLeft', 'called', 'carArrived', 'bell', 'rodeDown', 'banked'].includes(x));
    expect(order).toEqual(['doorsOpened', 'carLeft', 'called', 'carArrived', 'doorsOpened', 'bell', 'carLeft', 'rodeDown', 'doorsOpened', 'carLeft', 'called', 'carArrived', 'doorsOpened', 'bell', 'banked']);
    console.log(
      `script: floor 1 reading ${readings[0]?.value.toFixed(1)} (raw ${readings[0]?.raw.toFixed(1)}), floor 2 reading ${readings[1]?.value.toFixed(1)} (raw ${readings[1]?.raw.toFixed(1)} x ${depthMultiplier(2)}), ` +
        `banked ${banked.summary.total.toFixed(1)}, ${banked.summary.shares.A?.toFixed(1)} each, run time ${st.t.toFixed(0)} s`,
    );
  });
});

// =============================================================================================
// 2 and 3. The blink rule: a crew staring at the Orderly while the car comes.
// =============================================================================================

interface StareResult {
  label: string;
  violations: string[];
  movedInBlink: number;
  blinkAdvance: number;
  caught: boolean;
  blinks: number;
  telegraph: string[];
  waitedFor: number;
}

function nearLandingCell(plan: FloorPlan, rng: Rng, from: Body): Pos {
  const dist = distancesFrom(plan, plan.landing);
  const cands: Pos[] = [];
  const visible: Pos[] = [];
  for (let i = 0; i < dist.length; i++) {
    const d = dist[i] ?? -1;
    if (d < 3 || d > 8) continue;
    const p = posFromIndex(plan, i);
    if (p.level !== 0 || !isWalkable(plan, 0, p.x, p.y) || cellAt(plan, 0, p.x, p.y) === 'stair') continue;
    cands.push(p);
    if (surelyClear(plan, from, bodyAtCell(plan, p))) visible.push(p);
  }
  return rng.pick(visible.length > 0 ? visible : cands);
}

function stareRun(i: number): StareResult {
  const seed = `stare-${i}`;
  const n = 1 + (Math.floor(i / 4) % 4);
  const ids = Array.from({ length: n }, (_, k) => `p${k}`);
  const st0 = createRun(seed, ids);
  const plan = st0.plan;
  const spots = ids.map((_, k) => carBody(st0.car, -0.7 - 0.5 * Math.floor(k / 2), k % 2 ? 0.45 : -0.45));
  const start = nearLandingCell(plan, makeRng(seed).fork('orderly'), spots[0] as Body);
  const orderly: OrderlyState = { ...createOrderly(plan), body: bodyAtCell(plan, start), mode: 'hunting' };
  let st: RunState = { ...st0, phase: 'away', players: st0.players.map((p, k): RunPlayer => ({ ...p, body: spots[k] as Body, aboard: false })), orderly };
  const actors: Actor[] = ids.map((id, k) => ({ id, body: spots[k] as Body, yaw: 0, pitch: 0, call: k === 0 }));
  const res: StareResult = { label: `${seed} bots${n}`, violations: [], movedInBlink: 0, blinkAdvance: 0, caught: false, blinks: 0, telegraph: [], waitedFor: 0 };
  const out = new Set<string>();
  let blind = false;
  let lastSoon: number | null = null;
  let lastStart: number | null = null;
  const log: RunEvent[] = [];
  for (let k = 0; k < 90 / DT; k++) {
    for (const a of actors) lookAt(a, st.orderly.body);
    const before = st.orderly.body;
    const r = tick(st, actors, log);
    for (const a of actors) a.call = false;
    st = r.st;
    const types = r.ev.map((e) => e.type);
    const blindNow: boolean = types.includes('blinkStart') || (blind && !types.includes('blinkEnd'));
    blind = blindNow;
    for (const e of r.ev) {
      if (e.type === 'blinkSoon') {
        if (lastSoon !== null) res.telegraph.push(`t=${e.t.toFixed(2)} second blinkSoon before a blinkStart`);
        lastSoon = e.t;
      }
      if (e.type === 'blinkStart') {
        res.blinks++;
        const lead = lastSoon === null ? -1 : e.t - lastSoon;
        if (lead < 0.5 - 1e-9 || lead > 0.7 + 1e-9) res.telegraph.push(`t=${e.t.toFixed(2)} blinkStart with lead ${lead.toFixed(3)}`);
        if (lastStart !== null) {
          const gap = e.t - lastStart;
          if (gap < BLINK_INTERVAL_MIN - DT - 1e-9 || gap > BLINK_INTERVAL_MAX + DT + 1e-9) res.telegraph.push(`blink gap ${gap.toFixed(2)}`);
        }
        lastStart = e.t;
        lastSoon = null;
      }
      if (e.type === 'blinkEnd' && lastStart !== null) {
        const len = e.t - lastStart;
        if (Math.abs(len - BLINK_TIME) > DT + 1e-9) res.telegraph.push(`blink length ${len.toFixed(3)}`);
      }
      if (e.type === 'caught') res.caught = true;
      if ('playerId' in e && e.playerId === LURE_ID) res.violations.push(`event about the call target: ${e.type}`);
    }
    const after = st.orderly.body;
    const moved = after.x !== before.x || after.z !== before.z || after.level !== before.level;
    if (moved) {
      const seers = actors.filter((a) => !out.has(a.id) && oracleStareSees(plan, a.body, a.yaw, before));
      if (seers.length > 0 && !blindNow) res.violations.push(`t=${st.t.toFixed(2)} moved ${dist2(before, after).toFixed(3)} m while ${seers[0]?.id} stared at it, no blink`);
      if (seers.length > 0 && blindNow) {
        res.movedInBlink++;
        res.blinkAdvance += dist2(before, after);
      }
    }
    for (const e of r.ev) if (e.type === 'caught') out.add(e.playerId);
    if (types.includes('carArrived') || st.phase === 'ended') {
      const called = log.find((e) => e.type === 'called');
      res.waitedFor = st.t - (called?.t ?? 0);
      break;
    }
  }
  if (lastSoon !== null && st.phase === 'coming') res.telegraph.push('a blinkSoon was never followed by a blink');
  return res;
}

describe('the blink rule: staring at the landing while the car comes', () => {
  const N = 320;
  const results: StareResult[] = [];
  for (let i = 0; i < N; i++) results.push(stareRun(i));

  it('it moves only during blinks, never while stared at with the lights on (independent oracle)', () => {
    const bad = results.filter((r) => r.violations.length > 0);
    expect(bad.map((r) => `${r.label}: ${r.violations.slice(0, 3).join('; ')}`)).toEqual([]);
  });

  it('it does move during blinks in most runs: staring is not safe', () => {
    const moved = results.filter((r) => r.movedInBlink > 0).length;
    const caught = results.filter((r) => r.caught).length;
    const blinks = results.reduce((s, r) => s + r.blinks, 0);
    const adv = results.reduce((s, r) => s + r.blinkAdvance, 0);
    const advRuns = results.filter((r) => r.movedInBlink > 0);
    console.log(
      `staring crews: ${N} calls, ${blinks} blinks (${(blinks / N).toFixed(1)} per wait); it moved during a blink in ${moved} (${((100 * moved) / N).toFixed(0)}%), ` +
        `advancing ${(adv / Math.max(1, advRuns.length)).toFixed(2)} m per such wait (${(adv / Math.max(1, blinks)).toFixed(3)} m per blink); ` +
        `caught while waiting: ${caught}/${N} (${((100 * caught) / N).toFixed(1)}%)`,
    );
    expect(moved).toBeGreaterThan(N / 2);
  });

  it('every blink is telegraphed 0.5 to 0.7 s ahead, lasts BLINK_TIME, and blinks come every 5 to 9 s', () => {
    const bad = results.filter((r) => r.telegraph.length > 0);
    expect(bad.map((r) => `${r.label}: ${r.telegraph.slice(0, 3).join('; ')}`)).toEqual([]);
    expect(results.reduce((s, r) => s + r.blinks, 0)).toBeGreaterThan(N * 2);
  });
});

// =============================================================================================
// 4 and 10. The car is safe, with wandering and oblivious bots; and determinism.
// =============================================================================================

type RiderMode = 'exit' | 'wander' | 'toLanding' | 'enter' | 'inCar';

interface Rider {
  actor: Actor;
  bot: Bot;
  mode: RiderMode;
  timer: number;
  route: Body[];
  walk: PathWalk | null;
  rng: Rng;
}

interface SafeResult {
  label: string;
  violations: string[];
  caught: number;
  encounters: number;
  rides: number;
  hash: string;
  events: number;
}

function safeRun(i: number, seconds = 90): SafeResult {
  const seed = `safe-${i}`;
  const n = 1 + (i % 4);
  const ids = Array.from({ length: n }, (_, k) => `b${k}`);
  let st = createRun(seed, ids);
  // In three runs of four the Orderly starts awake a few cells from the landing, so it meets the car.
  if (i % 4 !== 3) {
    const start = nearLandingCell(st.plan, makeRng(seed).fork('orderly'), carBody(st.car, -1, 0));
    st = { ...st, orderly: { ...createOrderly(st.plan), body: bodyAtCell(st.plan, start), mode: 'hunting' } };
  }
  let box = oracleCar(st.plan);
  const riders: Rider[] = ids.map((id, k) => {
    const rng = makeRng(seed).fork(`rider:${id}`);
    const body = st.players[k]?.body as Body;
    const bot = createBot(st.plan, id, `${seed}:${id}`, { watchfulness: rng.next(), oblivious: k === 0 || rng.chance(0.4), start: st.plan.landing });
    return { actor: { id, body, yaw: rng.next() * 6, pitch: 0 }, bot, mode: 'exit', timer: 0, route: outOfCar(st, -1.0, (rng.next() - 0.5) * 1.2), walk: null, rng };
  });
  const res: SafeResult = { label: `${seed} bots${n}`, violations: [], caught: 0, encounters: 0, rides: 0, hash: '', events: 0 };
  const caught = new Set<string>();
  let h = 2166136261;
  const log: RunEvent[] = [];
  for (let k = 0; k < seconds / DT && st.phase !== 'ended'; k++) {
    for (const r of riders) {
      const a = r.actor;
      a.call = false;
      if (caught.has(a.id)) continue;
      r.timer -= DT;
      if (r.mode !== 'wander' && r.rng.chance(DT / 1.5)) a.yaw += (r.rng.next() - 0.5) * 3;
      switch (r.mode) {
        case 'exit':
          if (st.phase === 'riding' || st.phase === 'arriving') break;
          if (walk(st, a, r.route, 2.5) || !oracleInCar(box, a.body)) {
            if (!oracleInCar(box, a.body)) {
              r.mode = 'wander';
              r.bot.body = a.body;
              r.bot.walk = null;
              r.timer = 2 + r.rng.next() * 12;
            }
          }
          break;
        case 'wander':
          stepBot(st.plan, r.bot, DT);
          a.body = r.bot.body;
          a.yaw = r.bot.yaw;
          a.pitch = r.bot.pitch;
          if (r.timer <= 0) {
            const path = findPath(st.plan, cellOf(st.plan, a.body), st.plan.landing);
            if (path) {
              r.walk = { path, next: path.length > 1 ? 1 : 0 };
              r.mode = 'toLanding';
              r.timer = 60;
            } else r.timer = 5;
          }
          break;
        case 'toLanding': {
          const w = r.walk;
          if (w && !pathDone(st.plan, w, a.body)) {
            const before = a.body;
            a.body = stepPathWalk(st.plan, w, a.body, 3.0 * DT, BOT_RADIUS);
            if (dist2(before, a.body) > 1e-4) a.yaw = yawToward(a.body.x - before.x, a.body.z - before.z);
          } else {
            if (st.phase === 'away') a.call = true;
            if (st.phase === 'boarding' || st.phase === 'unloading') {
              r.mode = 'enter';
              r.route = intoCar(st, 0.6 + r.rng.next() * 1.0, (r.rng.next() - 0.5) * 1.3);
            }
          }
          if (r.timer <= 0 && r.mode === 'toLanding') {
            r.mode = 'wander';
            r.bot.body = a.body;
            r.bot.walk = null;
            r.timer = 5 + r.rng.next() * 20;
          }
          break;
        }
        case 'enter':
          if (!doorsOpen(st) && !oracleInCar(box, a.body)) {
            r.mode = 'toLanding';
            r.walk = null;
            break;
          }
          if (walk(st, a, r.route, 2.5)) {
            r.mode = 'inCar';
            r.timer = 3 + r.rng.next() * 25;
          }
          break;
        case 'inCar':
          a.hold = r.rng.chance(0.3);
          if (r.timer <= 0 && doorsOpen(st)) {
            r.mode = 'exit';
            r.route = outOfCar(st, -1.0, (r.rng.next() - 0.5) * 1.2);
          }
          break;
      }
    }
    const actors = riders.map((r) => r.actor);
    const sent = new Map(actors.map((a) => [a.id, a.body]));
    const t = tick(st, actors, log);
    st = t.st;
    for (const e of t.ev) {
      h = hashText(h, JSON.stringify(e));
      res.events++;
      if (e.type === 'caught') {
        res.caught++;
        caught.add(e.playerId);
        const b = sent.get(e.playerId);
        if (b && oracleInCar(box, b)) res.violations.push(`t=${e.t.toFixed(2)} caught ${e.playerId} inside the car`);
        if (e.playerId === LURE_ID) res.violations.push('caught the call');
      }
      if (e.type === 'rodeDown') {
        res.rides++;
        box = oracleCar(st.plan);
        caught.clear();
        for (const r of riders) {
          r.mode = 'exit';
          r.route = outOfCar(st, -1.0, (r.rng.next() - 0.5) * 1.2);
          r.bot.walk = null;
        }
      }
      if (e.type === 'doorsClosed') {
        for (const r of riders) {
          if (e.pushedOut[r.actor.id]) {
            r.mode = 'wander';
            r.bot.body = r.actor.body;
            r.bot.walk = null;
            r.timer = 5 + r.rng.next() * 20;
          }
        }
      }
    }
    const o = st.orderly.body;
    const gap = boxDistance(box, o.x, o.z);
    if (st.phase !== 'riding' && o.level === 0 && gap < ORDERLY_RADIUS - 1e-3) res.violations.push(`t=${st.t.toFixed(2)} Orderly ${gap.toFixed(3)} m from the car`);
    if (st.phase !== 'riding' && gap < 2.5 && riders.some((r) => oracleInCar(box, r.actor.body))) res.encounters++;
  }
  res.hash = h.toString(16);
  return res;
}

describe('the car is safe: wandering and oblivious bots over many runs', () => {
  const N = 300;
  const results: SafeResult[] = [];
  for (let i = 0; i < N; i++) results.push(safeRun(i));

  it('the Orderly never ends a tick inside (or overlapping) the car, and nobody inside is ever caught', () => {
    const bad = results.filter((r) => r.violations.length > 0);
    expect(bad.map((r) => `${r.label}: ${r.violations.slice(0, 3).join('; ')}`)).toEqual([]);
  });

  it('is not vacuous: the Orderly comes within 2.5 m of an occupied car in many runs, and catches happen', () => {
    const enc = results.filter((r) => r.encounters > 0).length;
    const caught = results.reduce((s, r) => s + r.caught, 0);
    const rides = results.reduce((s, r) => s + r.rides, 0);
    console.log(`car safety: ${N} runs, ${enc} with the Orderly within 2.5 m of an occupied car (${results.reduce((s, r) => s + r.encounters, 0)} ticks), ${caught} catches outside, ${rides} rides down`);
    expect(enc).toBeGreaterThan(N / 10);
    expect(caught).toBeGreaterThan(10);
  });

  it('determinism: the same seed and inputs give identical event streams', () => {
    for (const i of [0, 7, 101, 298]) {
      const again = safeRun(i);
      expect(again.hash).toBe(results[i]?.hash);
      expect(again.events).toBe(results[i]?.events);
    }
  });
});

// =============================================================================================
// 5, 6, 7, 9. Votes, holding the doors, left behind, a wipe.
// =============================================================================================

function bellOf(log: RunEvent[]): Extract<RunEvent, { type: 'bell' }> {
  const b = log.find((e) => e.type === 'bell');
  if (!b || b.type !== 'bell') throw new Error('no bell');
  return b;
}

/** Puts actors on spots (inside the car, or the landing) and runs to the bell. */
function voteScene(seed: string, spots: ((st: RunState) => Body)[]): { st: RunState; log: RunEvent[]; actors: Actor[] } {
  const ids = spots.map((_, k) => `v${k}`);
  let st = boardingRun(seed, ids);
  const actors: Actor[] = ids.map((id, k) => ({ id, body: (spots[k] as (s: RunState) => Body)(st), yaw: 0, pitch: 0 }));
  const log: RunEvent[] = [];
  st = runUntil(st, actors, log, (ev) => has(ev, 'bell'), BOARD_TIME + 1);
  return { st, log, actors };
}

describe('votes', () => {
  it('more on BANK banks', () => {
    const { st, log } = voteScene('vote-1', [(s) => BANK_SPOT(s, 0), (s) => BANK_SPOT(s, 1), (s) => DOWN_SPOT(s, 0)]);
    expect(bellOf(log)).toMatchObject({ bank: 2, down: 1, outcome: 'bank' });
    expect(st.phase).toBe('ended');
    expect(has(log, 'banked')).toBe(true);
    const bellT = bellOf(log).t;
    expect(bellT).toBeCloseTo(BOARD_TIME, 1);
  });

  it('a tie rides (1-1 and 2-2), and more on DOWN rides', () => {
    for (const spots of [
      [(s: RunState) => BANK_SPOT(s, 0), (s: RunState) => DOWN_SPOT(s, 0)],
      [(s: RunState) => BANK_SPOT(s, 0), (s: RunState) => BANK_SPOT(s, 1), (s: RunState) => DOWN_SPOT(s, 0), (s: RunState) => DOWN_SPOT(s, 1)],
      [(s: RunState) => DOWN_SPOT(s, 0), (s: RunState) => DOWN_SPOT(s, 1), (s: RunState) => BANK_SPOT(s, 0)],
    ]) {
      const { st, log } = voteScene(`vote-tie-${spots.length}`, spots);
      expect(bellOf(log).outcome).toBe('ride');
      expect(st.phase).toBe('riding');
      expect(log.some((e) => e.type === 'carLeft' && e.reason === 'ride')).toBe(true);
    }
  });

  it('nobody aboard: the doors close, the car goes away, and it must be called again', () => {
    const outside = (s: RunState): Body => carBody(s.car, -1, 0);
    const { st: st1, log, actors } = voteScene('vote-empty', [outside]);
    expect(bellOf(log)).toMatchObject({ bank: 0, down: 0, outcome: 'empty' });
    expect(st1.phase).toBe('away');
    expect(log.some((e) => e.type === 'carLeft' && e.reason === 'empty')).toBe(true);
    expect(actors.length).toBe(1);
  });

  it('switching sides before the bell counts; after the bell it does not', () => {
    // v1 starts on DOWN (a tie would ride) and crosses to BANK two seconds before the bell: it banks.
    {
      const ids = ['v0', 'v1'];
      let st = boardingRun('vote-switch', ids);
      const a: Actor = { id: 'v0', body: BANK_SPOT(st, 0), yaw: 0, pitch: 0 };
      const b: Actor = { id: 'v1', body: DOWN_SPOT(st, 0), yaw: 0, pitch: 0 };
      const log: RunEvent[] = [];
      st = runUntil(st, [a, b], log, (ev) => has(ev, 'bell'), BOARD_TIME + 1, (s) => {
        if (s.t >= BOARD_TIME - 2) b.body = BANK_SPOT(s, 1);
      });
      expect(bellOf(log)).toMatchObject({ bank: 2, down: 0, outcome: 'bank' });
      const votes = log.filter((e) => e.type === 'voteChanged' && e.playerId === 'v1').map((e) => (e.type === 'voteChanged' ? e.side : null));
      expect(votes).toEqual(['down', 'bank']);
    }
    // A tie at the bell rides; crossing to BANK just after the bell changes nothing.
    {
      let st = boardingRun('vote-late', ['v0', 'v1']);
      const a: Actor = { id: 'v0', body: BANK_SPOT(st, 0), yaw: 0, pitch: 0 };
      const b: Actor = { id: 'v1', body: DOWN_SPOT(st, 0), yaw: 0, pitch: 0 };
      const log: RunEvent[] = [];
      st = runUntil(st, [a, b], log, (ev) => has(ev, 'bell'), BOARD_TIME + 1);
      b.body = BANK_SPOT(st, 1);
      st = runUntil(st, [a, b], log, (ev) => has(ev, 'rodeDown'), 10);
      expect(bellOf(log).outcome).toBe('ride');
      expect(log.filter((e) => e.type === 'voteChanged' && e.t > bellOf(log).t)).toEqual([]);
      expect(st.depth).toBe(2);
      expect(has(log, 'banked')).toBe(false);
    }
  });
});

describe('the empty car must be called again', () => {
  it('after an empty bell nothing comes until someone calls; then it comes', () => {
    const outside = (s: RunState): Body => carBody(s.car, -1, 0);
    const { st: st1, log, actors } = voteScene('vote-empty-2', [outside]);
    expect(st1.phase).toBe('away');
    let st = st1;
    const before = log.length;
    for (let k = 0; k < 120 / DT; k++) st = tick(st, actors, log).st;
    expect(st.phase).toBe('away');
    expect(log.slice(before).filter((e) => e.type === 'carArrived' || e.type === 'doorsOpened')).toEqual([]);
    (actors[0] as Actor).call = true;
    st = runUntil(st, actors, log, (ev) => has(ev, 'carArrived'), 70);
    expect(log.filter((e) => e.type === 'called').length).toBe(1);
    expect(doorsOpen(st)).toBe(true);
  });
});

describe('holding the doors', () => {
  it('delays the bell while held, up to the limit, only from inside; a straggler who boards during the hold rides', () => {
    // Held from 5 s to 12 s: the bell rings 7 s late.
    {
      let st = boardingRun('hold-1', ['in', 'out']);
      const inside: Actor = { id: 'in', body: DOWN_SPOT(st), yaw: 0, pitch: 0 };
      const outside: Actor = { id: 'out', body: carBody(st.car, -1, 0), yaw: 0, pitch: 0, hold: true }; // holding from outside does nothing
      const log: RunEvent[] = [];
      st = runUntil(st, [inside, outside], log, (ev) => has(ev, 'bell'), 60, (s) => {
        inside.hold = s.t >= 5 && s.t < 12;
      });
      expect(bellOf(log).t).toBeCloseTo(BOARD_TIME + 7, 1);
      const changes = log.filter((e) => e.type === 'holdChanged').map((e) => (e.type === 'holdChanged' ? e.held : null));
      expect(changes).toEqual([true, false]);
    }
    // Held the whole time: the bell rings at BOARD_TIME + HOLD_LIMIT. The straggler walks in at 28 s and rides.
    {
      let st = boardingRun('hold-2', ['in', 'late']);
      const inside: Actor = { id: 'in', body: DOWN_SPOT(st), yaw: 0, pitch: 0, hold: true };
      const late: Actor = { id: 'late', body: carBody(st.car, -1.2, 0.3), yaw: 0, pitch: 0 };
      const route = intoCar(st, 1.3, 0.5);
      const log: RunEvent[] = [];
      st = runUntil(st, [inside, late], log, (ev) => has(ev, 'bell'), 60, (s) => {
        if (s.t >= 28) walk(s, late, route, 2.5);
      });
      const bell = bellOf(log);
      expect(bell.t).toBeCloseTo(BOARD_TIME + HOLD_LIMIT, 1);
      expect(bell.t).toBeGreaterThan(BOARD_TIME + 8);
      expect(bell).toMatchObject({ down: 2, bank: 0, outcome: 'ride' });
      const closed = log.find((e) => e.type === 'doorsClosed');
      expect(closed && closed.type === 'doorsClosed' ? closed.aboard.sort() : []).toEqual(['in', 'late']);
      expect(has(log, 'leftBehind')).toBe(false);
      st = runUntil(st, [inside, late], log, (ev) => has(ev, 'rodeDown'), 10);
      expect(st.depth).toBe(2);
    }
  });
});

describe('left behind and lost', () => {
  it('a player not aboard when it rides loses their tapes, sits out the ride, and rejoins in the car below; floor tapes are lost; the caught rejoin too', () => {
    let st = boardingRun('behind-1', ['aboard', 'behind', 'caught']);
    const crew = st.crew;
    st = {
      ...st,
      players: st.players.map((p): RunPlayer => (p.id === 'caught' ? { ...p, status: 'caught' } : p)),
      crew: {
        ...crew,
        members: crew.members.map((m) =>
          m.id === 'aboard'
            ? { ...m, tape: tapeWith(m.tape.id, m.id, [30, 12]) }
            : m.id === 'behind'
              ? { ...m, tape: tapeWith(m.tape.id, m.id, [50]), carrying: [tapeWith('tape-x', 'someone', [20])] }
              : m,
        ),
        floor: [{ tape: tapeWith('tape-floor', 'caught', [40]), at: carBody(st.car, -3, 0) }],
      },
    };
    const aboardTape = member(st.crew, 'aboard')?.tape.id;
    const behindTapes = ['tape-2', 'tape-x'];
    const a: Actor = { id: 'aboard', body: DOWN_SPOT(st), yaw: 0, pitch: 0 };
    const b: Actor = { id: 'behind', body: carBody(st.car, -1.5, 0), yaw: 0, pitch: 0, raised: true };
    const c: Actor = { id: 'caught', body: carBody(st.car, -3, 0), yaw: 0, pitch: 0 };
    const log: RunEvent[] = [];
    st = runUntil(st, [a, b, c], log, (ev) => has(ev, 'bell'), BOARD_TIME + 1);
    expect(st.phase).toBe('riding');
    const lb = log.filter((e) => e.type === 'leftBehind');
    expect(lb.map((e) => (e.type === 'leftBehind' ? [e.playerId, e.lostTapes, e.lostValue] : null))).toEqual([
      ['behind', behindTapes, 70],
      ['caught', [], 0],
    ]);
    const fl = log.find((e) => e.type === 'floorTapesLost');
    expect(fl && fl.type === 'floorTapesLost' ? [fl.tapes, fl.lostValue] : null).toEqual([['tape-floor'], 40]);
    // During the ride they are out: inactive, holding nothing.
    st = tick(st, [a, b, c], log).st;
    expect(st.players.find((p) => p.id === 'behind')?.status).toBe('leftBehind');
    expect(member(st.crew, 'behind')?.active).toBe(false);
    expect(member(st.crew, 'behind')?.instrument.raised).toBe(false);
    st = runUntil(st, [a, b, c], log, (ev) => has(ev, 'rodeDown'), 10);
    // Below: everyone is back in the car and active; what was left behind is gone for good.
    const box = oracleCar(st.plan);
    for (const actor of [a, b, c]) expect(oracleInCar(box, actor.body)).toBe(true);
    expect(st.players.map((p) => p.status)).toEqual(['ok', 'ok', 'ok']);
    st = tick(st, [a, b, c], log).st;
    expect(st.crew.members.every((m) => m.active)).toBe(true);
    const allTapes = [...st.crew.members.flatMap((m) => [m.tape, ...m.carrying]), ...st.crew.floor.map((f) => f.tape)];
    expect(allTapes.filter((tp) => tp.readings.length > 0).map((tp) => tp.id)).toEqual([aboardTape]);
    expect(tapeValue(allTapes)).toBeCloseTo(42, 9);
    expect(member(st.crew, 'behind')?.tape.readings).toEqual([]);
    expect(member(st.crew, 'behind')?.carrying).toEqual([]);
    expect(st.crew.floor).toEqual([]);
    // And the crew can step out onto the new floor.
    st = runUntil(st, [a, b, c], log, (ev) => has(ev, 'doorsOpened'), 3);
    expect(st.phase).toBe('unloading');
  });
});

describe('a wipe', () => {
  it('everyone caught: the run ends with nothing, even with readings on the tapes', () => {
    let st = createRun('wipe-1', ['solo']);
    const spot = carBody(st.car, -1, 0);
    const start = nearLandingCell(st.plan, makeRng('wipe').fork('o'), spot);
    st = {
      ...st,
      phase: 'away',
      players: st.players.map((p): RunPlayer => ({ ...p, body: spot, aboard: false })),
      orderly: { ...createOrderly(st.plan), body: bodyAtCell(st.plan, start), mode: 'hunting' },
      crew: { ...st.crew, members: st.crew.members.map((m) => ({ ...m, tape: tapeWith(m.tape.id, m.id, [99]) })) },
    };
    const solo: Actor = { id: 'solo', body: spot, yaw: 0, pitch: 0 };
    const log: RunEvent[] = [];
    st = runUntil(st, [solo], log, (ev) => has(ev, 'wiped'), 120, (s) => lookAway(solo, s.orderly.body));
    expect(has(log, 'caught')).toBe(true);
    const w = log.find((e) => e.type === 'wiped');
    if (!w || w.type !== 'wiped') throw new Error('no wipe');
    expect(w.summary).toMatchObject({ total: 0, readings: 0, wiped: true, shares: { solo: 0 } });
    expect(st.phase).toBe('ended');
    expect(has(log, 'banked')).toBe(false);
    // Nothing happens after the end.
    const after = tick(st, [solo], log);
    expect(after.ev).toEqual([]);
  });

  it('one caught while another is still up is not a wipe', () => {
    let st = boardingRun('wipe-2', ['a', 'b']);
    st = { ...st, players: st.players.map((p): RunPlayer => (p.id === 'a' ? { ...p, status: 'caught' } : p)) };
    const a: Actor = { id: 'a', body: carBody(st.car, -3, 0), yaw: 0, pitch: 0 };
    const b: Actor = { id: 'b', body: DOWN_SPOT(st), yaw: 0, pitch: 0 };
    const log: RunEvent[] = [];
    st = runUntil(st, [a, b], log, (ev) => has(ev, 'rodeDown'), 30);
    expect(has(log, 'wiped')).toBe(false);
    expect(st.players.every((p) => p.status === 'ok')).toBe(true);
  });
});

// =============================================================================================
// 8. The wait can be read but not memorised.
// =============================================================================================

describe('the wait for the car', () => {
  it('varies within the stated range, the indicator matches it, and false stops come about one call in four', () => {
    const waits: number[] = [];
    const floorsSeen: number[] = [];
    let falseStops = 0;
    const problems: string[] = [];
    const RUNS = 20;
    const CALLS = 10;
    for (let r = 0; r < RUNS; r++) {
      let st = createRun(`wait-${r}`, ['caller']);
      const spot = carBody(st.car, -1, 0);
      st = { ...st, phase: 'away', players: st.players.map((p): RunPlayer => ({ ...p, body: spot, aboard: false })), orderly: { ...st.orderly, mode: 'dormant', dormantLeft: 1e9 } };
      const caller: Actor = { id: 'caller', body: spot, yaw: 0, pitch: 0 };
      let prevFloors: number | null = null;
      for (let c = 0; c < CALLS; c++) {
        const log: RunEvent[] = [];
        caller.call = true;
        st = runUntil(st, [caller], log, (ev) => has(ev, 'carArrived'), 80);
        const called = log.find((e) => e.type === 'called');
        const arrived = log.find((e) => e.type === 'carArrived');
        const ind = log.filter((e) => e.type === 'indicator');
        const fs = log.filter((e) => e.type === 'falseStop');
        if (!called || called.type !== 'called' || !arrived) throw new Error('no call');
        const wait = arrived.t - called.t;
        waits.push(wait);
        const k = called.floorsAway;
        floorsSeen.push(k);
        if (prevFloors === k) problems.push(`call ${r}/${c}: same start floor twice running`);
        prevFloors = k;
        // Indicator: k at the call, then every floor down to 0, one floor at a time.
        const seq = ind.map((e) => (e.type === 'indicator' ? e.floorsAway : -1));
        if (seq.join(',') !== Array.from({ length: k + 1 }, (_, j) => k - j).join(',')) problems.push(`call ${r}/${c}: indicator ${seq.join(',')}`);
        if (ind[0]?.t !== called.t || ind.at(-1)?.t !== arrived.t) problems.push(`call ${r}/${c}: indicator not aligned with call/arrival`);
        // Gaps: the first includes the start delay (1-3 s), the rest are FLOOR_TIME, except after a false stop.
        let extra = 0;
        for (let j = 1; j < ind.length; j++) {
          const gap = (ind[j]?.t ?? 0) - (ind[j - 1]?.t ?? 0);
          const floorsAway = seq[j] ?? -1;
          const fsHere = fs.length > 0 && floorsAway === 0;
          if (j === 1) {
            if (gap < FLOOR_TIME + 1 - DT - 1e-9 || gap > FLOOR_TIME + 3 + DT + 1e-9) problems.push(`call ${r}/${c}: first gap ${gap.toFixed(2)}`);
          } else if (fsHere) {
            extra = gap - FLOOR_TIME;
            if (extra < 3.5 - DT - 1e-9 || extra > 5 + DT + 1e-9) problems.push(`call ${r}/${c}: false stop extra ${extra.toFixed(2)}`);
          } else if (Math.abs(gap - FLOOR_TIME) > DT + 1e-9) problems.push(`call ${r}/${c}: gap ${gap.toFixed(2)} at ${floorsAway}`);
        }
        if (fs.length > 1) problems.push(`call ${r}/${c}: ${fs.length} false stops`);
        if (fs.length === 1) {
          falseStops++;
          const at = ind.find((e) => e.type === 'indicator' && e.floorsAway === 1);
          if (fs[0]?.t !== at?.t) problems.push(`call ${r}/${c}: false stop not one floor above`);
          if (log.filter((e) => e.type === 'falseStopDoors').length !== 2) problems.push(`call ${r}/${c}: false stop doors not heard twice`);
        }
        // Reading it: the arrival is exactly (floors - 1) x FLOOR_TIME + the false stop after the indicator's first change.
        const fromFirstChange = arrived.t - (ind[1]?.t ?? 0);
        if (Math.abs(fromFirstChange - ((k - 1) * FLOOR_TIME + extra)) > 2 * DT) problems.push(`call ${r}/${c}: unreadable (${fromFirstChange.toFixed(2)})`);
        // Nobody boards: the bell rings on an empty car and it goes away again.
        st = runUntil(st, [caller], log, (ev) => has(ev, 'carLeft'), BOARD_TIME + 2);
        expect(st.phase).toBe('away');
      }
    }
    expect(problems).toEqual([]);
    const sorted = [...waits].sort((x, y) => x - y);
    const min = sorted[0] ?? 0;
    const max = sorted.at(-1) ?? 0;
    const mean = waits.reduce((s, w) => s + w, 0) / waits.length;
    const sd = Math.sqrt(waits.reduce((s, w) => s + (w - mean) ** 2, 0) / waits.length);
    const hist: Record<string, number> = {};
    for (const w of waits) {
      const b = `${Math.floor(w / 5) * 5}-${Math.floor(w / 5) * 5 + 5}`;
      hist[b] = (hist[b] ?? 0) + 1;
    }
    const rate = falseStops / waits.length;
    console.log(
      `waits over ${waits.length} calls: min ${min.toFixed(1)} s, median ${sorted[Math.floor(sorted.length / 2)]?.toFixed(1)} s, mean ${mean.toFixed(1)} s, max ${max.toFixed(1)} s, sd ${sd.toFixed(1)} s; ` +
        `by 5 s: ${Object.entries(hist).sort((x, y) => parseFloat(x[0]) - parseFloat(y[0])).map(([k, v]) => `${k}:${v}`).join(' ')}; ` +
        `start floors ${Math.min(...floorsSeen)}-${Math.max(...floorsSeen)}; false stops ${falseStops}/${waits.length} (${(100 * rate).toFixed(1)}%)`,
    );
    expect(min).toBeGreaterThanOrEqual(25 - DT);
    expect(max).toBeLessThanOrEqual(56 + DT);
    expect(sd).toBeGreaterThan(5);
    expect(new Set(floorsSeen).size).toBe(7);
    expect(Math.abs(rate - FALSE_STOP_CHANCE)).toBeLessThan(0.08);
  });
});
