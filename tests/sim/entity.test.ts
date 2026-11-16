import { describe, expect, it } from 'vitest';
import { botView, createBot, stepBot, BOT_EYE, BOT_HFOV_DEG, BOT_VFOV_DEG, type Bot } from '../../src/sim/bot';
import { generateClinic } from '../../src/sim/clinic';
import {
  audibility,
  createOrderly,
  GRACE,
  stepEntity,
  type OrderlyEvent,
  type OrderlyState,
  type PlayerView,
} from '../../src/sim/entity';
import { canStep, cellAt, DIR_VEC, findPath, hasDoor, isWalkable, posFromIndex, reachableFrom, roomIdAt, stairCells, type FloorPlan, type Level, type Pos } from '../../src/sim/floor';
import { bodyAtCell, cellOf, type Body } from '../../src/sim/move';
import { makeRng } from '../../src/sim/rng';
import { edgeKind } from '../../src/sim/walls';

const DT = 0.05;
const H = 3.2; // storey height, restated here rather than imported
const DEG = Math.PI / 180;

// =============================================================================================
// The oracle: a deliberately simple, slow, independent visibility check. It shares nothing with
// sight.ts. It samples the segment from the eye to a point every 5 cm and, wherever two samples
// fall in different cells, applies the crossing rules read directly from floor.ts: canStep (same
// room, corridor to corridor, doors), holes in the upper floor, the balcony rail and stair tops.
// Doors are 1.1 m wide and 2.1 m high; the balcony rail is 1.1 m high; the slab between storeys
// is solid except over level-1 'atriumOpen' and 'stair' cells. The figure is tested at its chest
// (1.7 m) and the top of its head (2.6 m) only, against the TRUE camera frustum (70 degrees
// vertical, 16:9, so about 51.2 degrees each side horizontally), with no margin.
// =============================================================================================

const TRUE_V_HALF = 35 * DEG;
const TRUE_H_HALF = Math.atan(Math.tan(TRUE_V_HALF) * (16 / 9));
const ORACLE_STEP = 0.05;
const ORACLE_POINTS = [1.7, 2.6];

function oracleStairTop(plan: FloorPlan, ax: number, ay: number, bx: number, by: number): boolean {
  for (const s of plan.stairs) {
    const last = stairCells(s)[s.length - 1];
    if (!last) continue;
    const v = DIR_VEC[s.dir];
    const tx = last.x + v.dx;
    const ty = last.y + v.dy;
    if ((ax === last.x && ay === last.y && bx === tx && by === ty) || (bx === last.x && by === last.y && ax === tx && ay === ty)) return true;
  }
  return false;
}

/** Can a ray at height `hAbove` over level L's floor pass from cell a to the adjacent cell b at `lateral` from the edge middle? */
function oracleEdge(plan: FloorPlan, L: Level, ax: number, ay: number, bx: number, by: number, lateral: number, hAbove: number): boolean {
  if (oracleStairTop(plan, ax, ay, bx, by)) return L === 1;
  const A: Pos = { level: L, x: ax, y: ay };
  const B: Pos = { level: L, x: bx, y: by };
  const ka = cellAt(plan, L, ax, ay);
  const kb = cellAt(plan, L, bx, by);
  if (canStep(plan, A, B)) {
    const ra = roomIdAt(plan, L, ax, ay);
    const sameRoom = ra >= 0 && ra === roomIdAt(plan, L, bx, by);
    const bothCorr = ka === 'corridor' && kb === 'corridor';
    if (sameRoom || bothCorr || !hasDoor(plan, L, ax, ay, bx, by)) return true;
    return Math.abs(lateral) <= 0.55 && hAbove <= 2.1;
  }
  const hole = (k: string): boolean => k === 'atriumOpen' || k === 'stair';
  if (L === 1 && hole(ka) && ka === kb) return true;
  if (L === 1 && ((ka === 'atriumOpen' && kb === 'corridor') || (kb === 'atriumOpen' && ka === 'corridor'))) return hAbove > 1.1;
  return false;
}

function oracleLos(plan: FloorPlan, from: { x: number; y: number; z: number }, to: { x: number; y: number; z: number }): boolean {
  const cs = plan.cellSize;
  const dist = Math.hypot(to.x - from.x, to.y - from.y, to.z - from.z);
  const n = Math.max(1, Math.ceil(dist / ORACLE_STEP));
  const at = (i: number) => {
    const t = i / n;
    return { x: from.x + (to.x - from.x) * t, y: from.y + (to.y - from.y) * t, z: from.z + (to.z - from.z) * t };
  };
  let p = at(0);
  for (let i = 1; i <= n; i++) {
    const q = at(i);
    const pc = { x: Math.floor(p.x / cs), y: Math.floor(p.z / cs) };
    const qc = { x: Math.floor(q.x / cs), y: Math.floor(q.z / cs) };
    if (p.y >= H !== q.y >= H) {
      const hole = (c: { x: number; y: number }): boolean => {
        const k = cellAt(plan, 1, c.x, c.y);
        return k === 'atriumOpen' || k === 'stair';
      };
      if (!hole(pc) && !hole(qc)) return false;
    }
    if (pc.x !== qc.x || pc.y !== qc.y) {
      const m = { x: (p.x + q.x) / 2, y: (p.y + q.y) / 2, z: (p.z + q.z) / 2 };
      const L: Level = m.y >= H ? 1 : 0;
      const hAbove = m.y - (L === 1 ? H : 0);
      const pass = (a: { x: number; y: number }, b: { x: number; y: number }): boolean => {
        const lateral = a.x !== b.x ? m.z - (a.y + 0.5) * cs : m.x - (a.x + 0.5) * cs;
        return oracleEdge(plan, L, a.x, a.y, b.x, b.y, lateral, hAbove);
      };
      const ddx = Math.abs(qc.x - pc.x);
      const ddy = Math.abs(qc.y - pc.y);
      if (ddx + ddy === 1) {
        if (!pass(pc, qc)) return false;
      } else if (ddx === 1 && ddy === 1) {
        const viaX = { x: qc.x, y: pc.y };
        const viaY = { x: pc.x, y: qc.y };
        if (!(pass(pc, viaX) && pass(viaX, qc)) && !(pass(pc, viaY) && pass(viaY, qc))) return false;
      } else {
        throw new Error('oracle step jumped more than one cell');
      }
    }
    p = q;
  }
  return true;
}

/** Inside the true camera frustum? Rotates into camera space (three.js YXZ), camera looks down -z. */
function oracleInFrustum(v: PlayerView, p: { x: number; y: number; z: number }): boolean {
  const wx = p.x - v.body.x;
  const wy = p.y - (v.body.y + v.eye);
  const wz = p.z - v.body.z;
  const c = Math.cos(v.yaw);
  const s = Math.sin(v.yaw);
  const x1 = wx * c - wz * s;
  const z1 = wx * s + wz * c;
  const cp = Math.cos(v.pitch);
  const sp = Math.sin(v.pitch);
  const y2 = wy * cp + z1 * sp;
  const z2 = -wy * sp + z1 * cp;
  const depth = -z2;
  if (depth <= 0) return false;
  return Math.atan2(Math.abs(x1), depth) <= TRUE_H_HALF && Math.atan2(Math.abs(y2), depth) <= TRUE_V_HALF;
}

function oracleSees(plan: FloorPlan, v: PlayerView, fig: Body): boolean {
  const eye = { x: v.body.x, y: v.body.y + v.eye, z: v.body.z };
  for (const h of ORACLE_POINTS) {
    const p = { x: fig.x, y: fig.y + h, z: fig.z };
    if (oracleInFrustum(v, p) && oracleLos(plan, eye, p)) return true;
  }
  return false;
}

/** Could they see it if they turned to look straight at it? (Line of sight only.) */
function oracleCouldSee(plan: FloorPlan, v: { body: Body; eye: number }, fig: Body): boolean {
  const eye = { x: v.body.x, y: v.body.y + v.eye, z: v.body.z };
  return ORACLE_POINTS.some((h) => oracleLos(plan, eye, { x: fig.x, y: fig.y + h, z: fig.z }));
}

// =============================================================================================
// The property runs.
// =============================================================================================

const RUNS = 500;
const RUN_SECONDS = 75;
/** The oracle is run, for each bot, on every tick that bot's eye is within this distance of the figure. */
const ORACLE_RANGE = 25;

const planCache = new Map<string, FloorPlan>();
function plan(seed: string, depth: number): FloorPlan {
  const key = `${seed}/${depth}`;
  let p = planCache.get(key);
  if (!p) {
    p = generateClinic(seed, depth);
    planCache.set(key, p);
  }
  return p;
}

interface RunResult {
  label: string;
  travelled: number;
  seenTicks: number;
  oracleChecks: number;
  oracleSeenTicks: number;
  violations: string[];
  frameViolations: number;
  catches: number;
  catchesWhileWatched: string[];
  graceChecks: number;
  graceViolations: string[];
  stateHash: string;
}

function hashStates(h: number, s: OrderlyState): number {
  const text = `${s.t.toFixed(4)}|${s.body.x}|${s.body.z}|${s.body.y}|${s.body.level}|${s.yaw}|${s.mode}|${s.anim}|${s.animTime}`;
  for (let i = 0; i < text.length; i++) h = Math.imul(h ^ text.charCodeAt(i), 16777619);
  return h >>> 0;
}

function runOne(i: number): RunResult {
  const seed = `orderly-${i}`;
  const depth = 1 + (i % 4);
  const nBots = 1 + (Math.floor(i / 4) % 4);
  const p = plan(seed, depth);
  const rng = makeRng(seed).fork('setup');
  const bots: Bot[] = [];
  for (let b = 0; b < nBots; b++) {
    // A spread of watchfulness; in every third run the first bot never looks behind.
    const oblivious = b === 0 && i % 3 === 0;
    bots.push(createBot(p, `bot${b}`, `${seed}:${b}`, { watchfulness: rng.next(), oblivious, start: b === 0 ? p.landing : undefined }));
  }
  let state = createOrderly(p);
  const start = state.body;
  const r: RunResult = {
    label: `${seed} d${depth} bots${nBots}`,
    travelled: 0,
    seenTicks: 0,
    oracleChecks: 0,
    oracleSeenTicks: 0,
    violations: [],
    frameViolations: 0,
    catches: 0,
    catchesWhileWatched: [],
    graceChecks: 0,
    graceViolations: [],
    stateHash: '',
  };
  let hash = 2166136261;
  let prevFrameSeen = new Set<string>();
  const windUpWatched = new Map<string, boolean>();
  let lastSeenAt: number | null = null;
  const ticks = Math.round(RUN_SECONDS / DT);
  for (let tick = 0; tick < ticks; tick++) {
    for (const b of bots) stepBot(p, b, DT);
    const views = bots.map(botView);
    const before = state;
    const res = stepEntity(p, before, views, DT);
    state = res.state;
    hash = hashStates(hash, state);
    const moved = state.body.x !== before.body.x || state.body.z !== before.body.z || state.body.y !== before.body.y || state.body.level !== before.body.level;
    r.travelled += Math.hypot(state.body.x - before.body.x, state.body.z - before.body.z);
    if (state.seen) r.seenTicks++;

    // 1. The rule, by the oracle: if any bot could see it where it stood, it did not move or turn.
    //    2. The rendered frames: never visible in two consecutive frames at different positions.
    let oracleSeen = false;
    const frameSeen = new Set<string>();
    for (const v of views) {
      const d = Math.hypot(v.body.x - before.body.x, v.body.y + v.eye - before.body.y - 1.7, v.body.z - before.body.z);
      if (d > ORACLE_RANGE) continue;
      r.oracleChecks++;
      if (oracleSees(p, v, before.body)) oracleSeen = true;
      if (moved && oracleSees(p, v, state.body)) frameSeen.add(v.id);
    }
    if (oracleSeen) {
      r.oracleSeenTicks++;
      if (moved || state.yaw !== before.yaw) {
        r.violations.push(`t=${state.t.toFixed(2)} moved ${Math.hypot(state.body.x - before.body.x, state.body.z - before.body.z).toFixed(3)} m while the oracle saw it`);
      }
    }
    if (moved) for (const id of frameSeen) if (prevFrameSeen.has(id)) r.frameViolations++;
    prevFrameSeen = new Set<string>();
    for (const v of views) {
      if (Math.hypot(v.body.x - state.body.x, v.body.z - state.body.z) <= ORACLE_RANGE && oracleSees(p, v, state.body)) prevFrameSeen.add(v.id);
    }

    // 3. Looking saves you: watch every tick of every wind-up, from its target's eyes.
    for (const e of res.events) if (e.type === 'windUp') windUpWatched.set(e.playerId, false);
    if (before.mode === 'windUp' || state.mode === 'windUp' || res.events.some((e) => e.type === 'caught')) {
      for (const [id] of windUpWatched) {
        const v = views.find((vv) => vv.id === id);
        if (v && oracleSees(p, v, before.body)) windUpWatched.set(id, true);
      }
    }
    for (const e of res.events) {
      if (e.type === 'caught') {
        r.catches++;
        if (windUpWatched.get(e.playerId)) r.catchesWhileWatched.push(`${r.label} t=${e.t.toFixed(2)} ${e.playerId}`);
        windUpWatched.delete(e.playerId);
      }
      if (e.type === 'windUpCancelled') windUpWatched.delete(e.playerId);
    }

    // 4. Grace: for GRACE seconds after the last tick it was seen, it stays put.
    if (lastSeenAt !== null && !state.seen && state.t - lastSeenAt < GRACE + 1e-9) {
      r.graceChecks++;
      if (moved) r.graceViolations.push(`${r.label} moved ${(state.t - lastSeenAt).toFixed(3)} s after last seen`);
    }
    if (state.seen) lastSeenAt = state.t;
  }
  r.travelled = Math.max(r.travelled, Math.hypot(state.body.x - start.x, state.body.z - start.z));
  r.stateHash = hash.toString(16);
  return r;
}

describe('the Orderly: Stillness, checked by an independent oracle over many runs', () => {
  const results: RunResult[] = [];
  const t0 = performance.now();
  for (let i = 0; i < RUNS; i++) results.push(runOne(i));
  const seconds = (performance.now() - t0) / 1000;

  const total = (f: (r: RunResult) => number): number => results.reduce((a, r) => a + f(r), 0);
  const moving = results.filter((r) => r.travelled > 5).length;
  const seenRuns = results.filter((r) => r.seenTicks > 0).length;
  const catchRuns = results.filter((r) => r.catches > 0).length;
  console.log(
    [
      `Orderly property runs: ${RUNS} runs x ${RUN_SECONDS} s at ${1 / DT} Hz in ${seconds.toFixed(1)} s`,
      `  oracle sampling: every tick, every bot whose eye is within ${ORACLE_RANGE} m of the figure's chest`,
      `  oracle checks (bot-ticks sampled): ${total((r) => r.oracleChecks)}`,
      `  seen-ticks checked by the oracle: ${total((r) => r.oracleSeenTicks)}`,
      `  runs where it travelled > 5 m: ${moving}/${RUNS} (${((100 * moving) / RUNS).toFixed(1)}%)`,
      `  runs where it was seen: ${seenRuns}/${RUNS}`,
      `  runs with a catch: ${catchRuns} (catches: ${total((r) => r.catches)})`,
      `  grace ticks checked: ${total((r) => r.graceChecks)}`,
    ].join('\n'),
  );

  it('never moves or turns on a tick where the oracle says any bot sees it', () => {
    const bad = results.flatMap((r) => r.violations.map((v) => `${r.label}: ${v}`));
    expect(bad.slice(0, 10)).toEqual([]);
    expect(total((r) => r.oracleSeenTicks)).toBeGreaterThan(5000);
  });

  it('is never visible to a bot in two consecutive frames at two different positions', () => {
    expect(total((r) => r.frameViolations)).toBe(0);
  });

  it('is not vacuous: it moves in most runs, is seen in most runs, and sometimes catches someone', () => {
    expect(moving / RUNS).toBeGreaterThan(0.6);
    expect(seenRuns / RUNS).toBeGreaterThan(0.6);
    expect(catchRuns).toBeGreaterThan(10);
  });

  it('looking saves you: no catch of a player who could see it at any tick of the wind-up', () => {
    expect(results.flatMap((r) => r.catchesWhileWatched)).toEqual([]);
  });

  it('grace: it stays put for at least 0.3 s after the last tick it was seen', () => {
    expect(results.flatMap((r) => r.graceViolations).slice(0, 10)).toEqual([]);
    expect(total((r) => r.graceChecks)).toBeGreaterThan(1000);
  });

  it('determinism: the same seed and inputs give the same state sequence', () => {
    for (const i of [0, 7, 123, 250]) {
      const again = runOne(i);
      expect(again.stateHash).toBe(results[i]?.stateHash);
    }
  });
});

// =============================================================================================
// Scripted scenes.
// =============================================================================================

function view(id: string, b: Body, yaw: number, pitch = 0, active = true): PlayerView {
  return { id, body: b, eye: BOT_EYE, yaw, pitch, hFovDeg: BOT_HFOV_DEG, vFovDeg: BOT_VFOV_DEG, active };
}

function yawToward(from: Body, to: Body): number {
  return Math.atan2(-(to.x - from.x), -(to.z - from.z));
}

function dist(a: Body, b: Body): number {
  return Math.hypot(a.x - b.x, a.z - b.z);
}

describe('the Orderly: scripted scenes', () => {
  it('staring contest: frozen while stared at, moving within 1 s of looking away, frozen again when looked at', () => {
    let tried = 0;
    for (let i = 0; tried < 5 && i < 200; i++) {
      const p = generateClinic(`stare-${i}`, 1 + (i % 4));
      const s = p.sightlines.find((l) => l.level === p.entityStart.level && l.length >= 12 && ((l.x1 === p.entityStart.x && l.y1 === p.entityStart.y) || (l.x2 === p.entityStart.x && l.y2 === p.entityStart.y)));
      if (!s) continue;
      tried++;
      const atStart = s.x1 === p.entityStart.x && s.y1 === p.entityStart.y;
      const dx = Math.sign(s.x2 - s.x1) * (atStart ? 1 : -1);
      const dy = Math.sign(s.y2 - s.y1) * (atStart ? 1 : -1);
      const me = bodyAtCell(p, { level: s.level, x: p.entityStart.x + dx * 8, y: p.entityStart.y + dy * 8 });
      let st = createOrderly(p);
      const startBody = st.body;
      const facing = yawToward(me, st.body);
      const events: OrderlyEvent[] = [];
      for (let k = 0; k < 600; k++) {
        const r = stepEntity(p, st, [view('me', me, facing)], DT);
        st = r.state;
        events.push(...r.events);
        expect(st.body).toEqual(startBody);
      }
      expect(events.map((e) => e.type)).toEqual(expect.arrayContaining(['firstSeen', 'startedHunting', 'froze']));
      expect(st.mode).toBe('hunting');
      expect(st.frozen).toBe(true);
      const d0 = dist(me, st.body);

      // Turn around.
      let firstMove = -1;
      for (let k = 0; k < 30; k++) {
        const before = st.body;
        st = stepEntity(p, st, [view('me', me, facing + Math.PI)], DT).state;
        if (firstMove < 0 && dist(before, st.body) > 0) firstMove = (k + 1) * DT;
      }
      expect(firstMove).toBeGreaterThan(GRACE - 1e-9);
      expect(firstMove).toBeLessThanOrEqual(1.0);
      const d1 = dist(me, st.body);
      expect(d1).toBeLessThan(d0 - 2);
      expect(st.anim === 'walk' || st.anim === 'duck').toBe(true);

      // Turn back: closer, and frozen from the very next tick.
      const frozenAt = st.body;
      const frozenClock = st.animTime;
      for (let k = 0; k < 100; k++) {
        st = stepEntity(p, st, [view('me', me, facing)], DT).state;
        expect(st.body).toEqual(frozenAt);
        expect(st.animTime).toBe(frozenClock);
        expect(st.moving).toBe(false);
      }
      expect(dist(me, st.body)).toBeLessThan(d0);
      expect(audibility(p, st, view('me', me, facing)).gain).toBe(0);
    }
    expect(tried).toBe(5);
  });

  it('crosses levels by the stairs to reach a player in a room, ducking at every door edge it crosses', () => {
    let scenes = 0;
    let crossings = 0;
    for (let i = 0; scenes < 6 && i < 100; i++) {
      const p = generateClinic(`stairs-${i}`, 1 + (i % 4));
      const other: Level = p.entityStart.level === 0 ? 1 : 0;
      // A room cell on the other level, as far as possible from the stairs' feet and heads.
      const room = p.rooms.find((r) => r.level === other && r.kind !== 'lobby' && r.kind !== 'atrium' && r.branch === 'side');
      if (!room) continue;
      const cell: Pos = { level: other, x: room.x + Math.floor(room.w / 2), y: room.y + Math.floor(room.h / 2) };
      if (!isWalkable(p, cell.level, cell.x, cell.y) || !findPath(p, p.entityStart, cell)) continue;
      scenes++;
      const me = bodyAtCell(p, cell);
      // Blind: looking straight up with no field of view, so it is never seen.
      const blind = view('me', me, 0, Math.PI / 2);
      blind.hFovDeg = 0;
      blind.vFovDeg = 0;
      let st: OrderlyState = { ...createOrderly(p), mode: 'hunting' };
      let caught = false;
      let changedLevel = false;
      for (let k = 0; k < 120 / DT && !caught; k++) {
        const before = st.body;
        const r = stepEntity(p, st, [blind], DT);
        st = r.state;
        if (st.body.level !== before.level) changedLevel = true;
        const a = cellOf(p, before);
        const b = cellOf(p, st.body);
        if (a.level === b.level && Math.abs(a.x - b.x) + Math.abs(a.y - b.y) === 1 && edgeKind(p, a.level, a.x, a.y, b.x, b.y) === 'door') {
          crossings++;
          expect(st.anim, `${p.seed} t=${st.t.toFixed(2)}`).toBe('duck');
        }
        if (r.events.some((e) => e.type === 'caught' && e.playerId === 'me')) caught = true;
      }
      expect(changedLevel, p.seed).toBe(true);
      expect(caught, p.seed).toBe(true);
      expect(st.mode).toBe('dormant');
    }
    expect(scenes).toBe(6);
    expect(crossings).toBeGreaterThanOrEqual(6);
  });

  it('dormant after a catch: does not move or catch for 10 s, then hunts again', () => {
    const p = generateClinic('dormant', 2);
    const me = bodyAtCell(p, p.landing);
    const blind = { ...view('me', me, 0, Math.PI / 2), hFovDeg: 0, vFovDeg: 0 };
    let st: OrderlyState = { ...createOrderly(p), mode: 'hunting' };
    let caughtAt = -1;
    for (let k = 0; k < 120 / DT && caughtAt < 0; k++) {
      const r = stepEntity(p, st, [blind], DT);
      st = r.state;
      if (r.events.some((e) => e.type === 'caught')) caughtAt = st.t;
    }
    expect(caughtAt).toBeGreaterThan(0);
    const where = st.body;
    for (let k = 0; k < Math.round(9.9 / DT); k++) {
      const r = stepEntity(p, st, [blind], DT);
      st = r.state;
      expect(st.body).toEqual(where);
      expect(r.events.filter((e) => e.type === 'caught' || e.type === 'windUp')).toEqual([]);
    }
    let again = false;
    for (let k = 0; k < 10 && !again; k++) {
      const r = stepEntity(p, st, [blind], DT);
      st = r.state;
      if (r.events.some((e) => e.type === 'startedHunting')) again = true;
    }
    expect(again).toBe(true);
  });

  it('wakes when a player walks within 12 m, and after 60 s regardless', () => {
    const p = generateClinic('wake', 1);
    // Far away and blind: wakes at 60 s.
    const far = { ...view('me', bodyAtCell(p, p.landing), 0, Math.PI / 2), hFovDeg: 0, vFovDeg: 0 };
    let st = createOrderly(p);
    let woke = -1;
    for (let k = 0; k < 70 / DT && woke < 0; k++) {
      const r = stepEntity(p, st, [far], DT);
      st = r.state;
      if (r.events.some((e) => e.type === 'startedHunting')) woke = st.t;
    }
    expect(woke).toBeCloseTo(60, 5);
    // Blind, five cells' walk away: wakes on the first tick.
    const reach = reachableFrom(p, p.entityStart);
    const five = [...reach].map((ix) => posFromIndex(p, ix)).find((q) => {
      const path = findPath(p, p.entityStart, q);
      return path !== null && path.length === 6;
    });
    if (!five) throw new Error('no cell five steps away');
    const near = { ...view('me', bodyAtCell(p, five), 0, Math.PI / 2), hFovDeg: 0, vFovDeg: 0 };
    const r = stepEntity(p, createOrderly(p), [near], DT);
    expect(r.events.map((e) => e.type)).toContain('startedHunting');
  });

  it('a wind-up is cancelled the moment anyone looks, and the target is not caught', () => {
    const p = generateClinic('windup', 1);
    const meBody = bodyAtCell(p, p.landing);
    const blind = { ...view('me', meBody, 0, Math.PI / 2), hFovDeg: 0, vFovDeg: 0 };
    let st: OrderlyState = { ...createOrderly(p), mode: 'hunting' };
    let wound = false;
    for (let k = 0; k < 120 / DT && !wound; k++) {
      const r = stepEntity(p, st, [blind], DT);
      st = r.state;
      if (r.events.some((e) => e.type === 'windUp')) wound = true;
    }
    expect(wound).toBe(true);
    st = stepEntity(p, st, [blind], DT).state; // part way through
    const look = view('me', meBody, yawToward(meBody, st.body));
    const r = stepEntity(p, st, [look], DT);
    expect(r.events.map((e) => e.type)).toEqual(expect.arrayContaining(['windUpCancelled', 'froze']));
    expect(r.state.mode).toBe('hunting');
    st = r.state;
    for (let k = 0; k < 200; k++) {
      const rr = stepEntity(p, st, [look], DT);
      st = rr.state;
      expect(rr.events.filter((e) => e.type === 'caught')).toEqual([]);
    }
  });

  it('heard before seen: audible at least 1 s before it could first be seen by a player facing away (104 seeds)', () => {
    // The listener stands still at the landing, always facing directly away from it, so it hunts
    // them unseen. Measured: the first tick its squeak gain exceeds 0.05, against the first tick the
    // oracle says it would be in view if they turned to look straight at it (line of sight to its
    // chest or head). Also asserted: heard at least 1 s before it comes within 12 m. The landing is
    // never in plain sight of its start on these floors (asserted), so the stronger measure holds.
    const leads: number[] = [];
    const seeLeads: number[] = [];
    let plainSight = 0;
    let n = 0;
    for (let i = 0; i < 104; i++) {
      const p = generateClinic(`hear-${i}`, 1 + (i % 4));
      n++;
      const me = bodyAtCell(p, p.landing);
      let st: OrderlyState = { ...createOrderly(p), mode: 'hunting' };
      if (oracleCouldSee(p, { body: me, eye: BOT_EYE }, st.body)) plainSight++;
      let heard = -1;
      let near = -1;
      let seeable = -1;
      for (let k = 0; k < 150 / DT && (near < 0 || seeable < 0); k++) {
        const v = view('me', me, yawToward(st.body, me)); // back to it: face directly away
        st = stepEntity(p, st, [v], DT).state;
        expect(st.seen).toBe(false);
        if (heard < 0 && audibility(p, st, v).gain > 0.05) heard = st.t;
        if (seeable < 0 && oracleCouldSee(p, v, st.body)) seeable = st.t;
        if (near < 0 && dist(me, st.body) < 12 && st.body.level === me.level) near = st.t;
      }
      expect(near, p.seed).toBeGreaterThan(0);
      expect(seeable, p.seed).toBeGreaterThan(0);
      expect(heard, p.seed).toBeGreaterThan(0);
      leads.push(near - heard);
      seeLeads.push(seeable - heard);
    }
    const median = (xs: number[]): string => ([...xs].sort((a, b) => a - b)[Math.floor(xs.length / 2)] ?? 0).toFixed(2);
    console.log(
      `heard before seen: ${n} seeds, listener at the landing facing away; ` +
        `hearing leads first possible sight by min ${Math.min(...seeLeads).toFixed(2)} s (median ${median(seeLeads)} s), ` +
        `leads coming within 12 m by min ${Math.min(...leads).toFixed(2)} s (median ${median(leads)} s); in plain sight at the start: ${plainSight}`,
    );
    expect(n).toBeGreaterThanOrEqual(100);
    expect(plainSight).toBe(0);
    expect(Math.min(...seeLeads)).toBeGreaterThanOrEqual(1.0);
    expect(Math.min(...leads)).toBeGreaterThanOrEqual(1.0);
  });
});
