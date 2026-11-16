// The counts the property tests in tests/sim print, for the full runs and for the shorter runs the
// Godot suite does by default (the first N seeds of the same sequences). The run loops and oracles
// below are copied from tests/sim/entity.test.ts, instrument.test.ts and run.test.ts (only the run
// counts became parameters), and the blackout tables come from tests/sim/waits.ts itself. The full
// counts must equal what Vitest prints; the Godot tests compare theirs with these.
// Run from the repo root: npm run godot:reference (it runs this after dump_reference.ts).

import { mkdirSync, writeFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { botView, createBot, stepBot, BOT_EYE, BOT_HFOV_DEG, BOT_RADIUS, BOT_VFOV_DEG, type Bot } from '../../src/sim/bot';
import { generateClinic } from '../../src/sim/clinic';
import { audibility, createOrderly, GRACE, ORDERLY_RADIUS, stepEntity, yawToward, type OrderlyState, type PlayerView } from '../../src/sim/entity';
import { canStep, cellAt, DIR_VEC, distancesFrom, findPath, hasDoor, isWalkable, posFromIndex, posIndex, reachableFrom, roomIdAt, stairCells, type FloorPlan, type Level, type Pos } from '../../src/sim/floor';
import { pathDone, stepPathWalk, type PathWalk } from '../../src/sim/follow';
import { createCrew, leaveFloor, member, pickUpTape, setRaised, stepCrew, type CrewPlayer, type CrewState, type EntityTick } from '../../src/sim/instrument';
import { elevatorWall } from '../../src/sim/landing';
import { bodyAtCell, cellOf, type Body } from '../../src/sim/move';
import { makeRng, type Rng } from '../../src/sim/rng';
import { BLACKOUT_WARNING, BLINK_GAPS, BLINK_WARNING, carBody, createRun, doorsOpen, LURE_ID, moveInRun, stepRun, type PlayerInput, type RunEvent, type RunPlayer, type RunState } from '../../src/sim/run';
import type { OrderlyEvent } from '../../src/sim/entity';
import { waitTable, tableLine } from '../../tests/sim/waits';

const OUT = join(dirname(fileURLToPath(import.meta.url)), '..', 'tests', 'reference');
const DT = 0.05;

/** Default sizes of the Godot suite (tests/prop_*.gd); --full runs the Vitest sizes. */
export const SUB = { entity: 24, instrument: 24, stare: 24, safe: 16, hear: 16, waits: 20 };
export const FULL = { entity: 500, instrument: 500, stare: 320, safe: 300, hear: 104, waits: 300 };

// =============================================================================================
// entity.test.ts: the oracle and runOne (copied).

const H = 3.2;
const DEG = Math.PI / 180;
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
function oracleCouldSee(plan: FloorPlan, v: { body: Body; eye: number }, fig: Body): boolean {
  const eye = { x: v.body.x, y: v.body.y + v.eye, z: v.body.z };
  return ORACLE_POINTS.some((h) => oracleLos(plan, eye, { x: fig.x, y: fig.y + h, z: fig.z }));
}

const RUN_SECONDS = 75;
const ORACLE_RANGE = 25;
interface ERun { label: string; travelled: number; seenTicks: number; oracleChecks: number; oracleSeenTicks: number; violations: string[]; frameViolations: number; catches: number; catchesWhileWatched: string[]; graceChecks: number; graceViolations: string[] }
function entityRun(i: number): ERun {
  const seed = `orderly-${i}`;
  const depth = 1 + (i % 4);
  const nBots = 1 + (Math.floor(i / 4) % 4);
  const p = generateClinic(seed, depth);
  const rng = makeRng(seed).fork('setup');
  const bots: Bot[] = [];
  for (let b = 0; b < nBots; b++) {
    const oblivious = b === 0 && i % 3 === 0;
    bots.push(createBot(p, `bot${b}`, `${seed}:${b}`, { watchfulness: rng.next(), oblivious, start: b === 0 ? p.landing : undefined }));
  }
  let state = createOrderly(p);
  const start = state.body;
  const r: ERun = { label: `${seed} d${depth} bots${nBots}`, travelled: 0, seenTicks: 0, oracleChecks: 0, oracleSeenTicks: 0, violations: [], frameViolations: 0, catches: 0, catchesWhileWatched: [], graceChecks: 0, graceViolations: [] };
  let prevFrameSeen = new Set<string>();
  const windUpWatched = new Map<string, boolean>();
  let lastSeenAt: number | null = null;
  const ticks = Math.round(RUN_SECONDS / DT);
  for (let tick = 0; tick < ticks; tick++) {
    for (const b of bots) stepBot(p, b, DT, state.body);
    const views = bots.map(botView);
    const before = state;
    const res = stepEntity(p, before, views, DT);
    state = res.state;
    const moved = state.body.x !== before.body.x || state.body.z !== before.body.z || state.body.y !== before.body.y || state.body.level !== before.body.level;
    r.travelled += Math.hypot(state.body.x - before.body.x, state.body.z - before.body.z);
    if (state.seen) r.seenTicks++;
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
      if (moved || state.yaw !== before.yaw) r.violations.push(`t=${state.t.toFixed(2)}`);
    }
    if (moved) for (const id of frameSeen) if (prevFrameSeen.has(id)) r.frameViolations++;
    prevFrameSeen = new Set<string>();
    for (const v of views) {
      if (Math.hypot(v.body.x - state.body.x, v.body.z - state.body.z) <= ORACLE_RANGE && oracleSees(p, v, state.body)) prevFrameSeen.add(v.id);
    }
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
    if (lastSeenAt !== null && !state.seen && state.t - lastSeenAt < GRACE + 1e-9) {
      r.graceChecks++;
      if (moved) r.graceViolations.push(`${r.label}`);
    }
    if (state.seen) lastSeenAt = state.t;
  }
  r.travelled = Math.max(r.travelled, Math.hypot(state.body.x - start.x, state.body.z - start.z));
  return r;
}
function entityCounts(n: number) {
  const rs: ERun[] = [];
  for (let i = 0; i < n; i++) rs.push(entityRun(i));
  const total = (f: (r: ERun) => number): number => rs.reduce((a, r) => a + f(r), 0);
  return {
    runs: n,
    oracleChecks: total((r) => r.oracleChecks),
    oracleSeenTicks: total((r) => r.oracleSeenTicks),
    moving: rs.filter((r) => r.travelled > 5).length,
    seenRuns: rs.filter((r) => r.seenTicks > 0).length,
    catchRuns: rs.filter((r) => r.catches > 0).length,
    catches: total((r) => r.catches),
    graceChecks: total((r) => r.graceChecks),
    violations: total((r) => r.violations.length),
    frameViolations: total((r) => r.frameViolations),
    catchesWhileWatched: total((r) => r.catchesWhileWatched.length),
    graceViolations: total((r) => r.graceViolations.length),
  };
}

/** entity.test.ts "heard before seen" (copied; the seed count is a parameter). */
function hearCounts(n: number) {
  const view = (id: string, b: Body, yaw: number): PlayerView => ({ id, body: b, eye: BOT_EYE, yaw, pitch: 0, hFovDeg: BOT_HFOV_DEG, vFovDeg: BOT_VFOV_DEG, active: true });
  const dist = (a: Body, b: Body) => Math.hypot(a.x - b.x, a.z - b.z);
  const faceTo = (from: Body, to: Body): number => Math.atan2(-(to.x - from.x), -(to.z - from.z));
  const leads: number[] = [];
  const seeLeads: number[] = [];
  let plainSight = 0;
  let seenEver = 0;
  for (let i = 0; i < n; i++) {
    const p = generateClinic(`hear-${i}`, 1 + (i % 4));
    const me = bodyAtCell(p, p.landing);
    let st: OrderlyState = { ...createOrderly(p), mode: 'hunting' };
    if (oracleCouldSee(p, { body: me, eye: BOT_EYE }, st.body)) plainSight++;
    let heard = -1;
    let near = -1;
    let seeable = -1;
    for (let k = 0; k < 150 / DT && (near < 0 || seeable < 0); k++) {
      const v = view('me', me, faceTo(st.body, me));
      st = stepEntity(p, st, [v], DT).state;
      if (st.seen) seenEver++;
      if (heard < 0 && audibility(p, st, v).gain > 0.05) heard = st.t;
      if (seeable < 0 && oracleCouldSee(p, v, st.body)) seeable = st.t;
      if (near < 0 && dist(me, st.body) < 12 && st.body.level === me.level) near = st.t;
    }
    leads.push(near - heard);
    seeLeads.push(seeable - heard);
  }
  const median = (xs: number[]): number => [...xs].sort((a, b) => a - b)[Math.floor(xs.length / 2)] ?? 0;
  return { seeds: n, minSeeLead: Math.min(...seeLeads), medianSeeLead: median(seeLeads), minNearLead: Math.min(...leads), medianNearLead: median(leads), plainSight, seenEver };
}

// =============================================================================================
// instrument.test.ts: runOne (copied).

const IRUN_SECONDS = 60;
function oracleMoved(before: OrderlyState, after: OrderlyState, events: readonly OrderlyEvent[]): boolean {
  const b = before.body;
  const a = after.body;
  if (b.x !== a.x || b.z !== a.z || b.y !== a.y || b.level !== a.level) return true;
  const started = before.mode !== 'windUp' && after.mode === 'windUp';
  const ranDown = before.mode === 'windUp' && after.mode === 'windUp' && after.windUpLeft < before.windUpLeft;
  const completed = before.mode === 'windUp' && events.some((e) => e.type === 'caught');
  return started || ranDown || completed;
}
function oracleDistance(p: Body, o: Body): number {
  const dx = p.x - o.x;
  const dy = p.y - o.y;
  const dz = p.z - o.z;
  return Math.sqrt(dx * dx + dy * dy + dz * dz);
}
interface BotStat { earnedBefore: number; recordedAll: number; caught: boolean }
interface IRun { growthTicks: number; violations: number; lowered: number; inactiveRaisedTicks: number; closedReadings: number; slips: number; slipOk: boolean; tapesDropped: number; pickups: number; carriedValue: number; lostValue: number; bots: BotStat[] }
function instrumentRun(i: number): IRun {
  const seed = `earn-${i}`;
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
  const r: IRun = { growthTicks: 0, violations: 0, lowered: 0, inactiveRaisedTicks: 0, closedReadings: 0, slips: 0, slipOk: true, tapesDropped: 0, pickups: 0, carriedValue: 0, lostValue: 0, bots: ids.map(() => ({ earnedBefore: 0, recordedAll: 0, caught: false })) };
  let anyGrowth = false;
  const ticks = Math.round(IRUN_SECONDS / DT);
  for (let tick = 0; tick < ticks; tick++) {
    toggleIn -= DT;
    if (toggleIn <= 0 && nBots > 1) {
      toggleIn = 1 + toggles.next() * 6;
      const m = member(crew, 'bot1');
      if (m) crew = setRaised(crew, 'bot1', !m.instrument.raised);
    }
    if (i % 2 === 1) for (const id of ids) if (!active.get(id)) crew = setRaised(crew, id, true);
    for (const b of bots) if (active.get(b.id)) stepBot(p, b, DT, member(crew, b.id)?.instrument.raised ? null : orderly.body);
    const views: PlayerView[] = bots.map((b) => ({ ...botView(b), active: active.get(b.id) ?? false }));
    const before = orderly;
    const res = stepEntity(p, before, views, DT);
    orderly = res.state;
    const players: CrewPlayer[] = views.map((v) => ({ id: v.id, body: v.body, active: v.active }));
    const entity: EntityTick = { id: 'orderly', trait: 'stillness', prev: before, next: orderly, events: res.events };
    const crewBefore = crew;
    const out = stepCrew(p, crew, players, [entity], DT);
    crew = out.crew;
    const moved = oracleMoved(before, orderly, res.events);
    let grewThisTick = false;
    for (let k = 0; k < ids.length; k++) {
      const id = ids[k] as string;
      const was = member(crewBefore, id);
      const now = member(crew, id);
      const pl = players[k] as CrewPlayer;
      if (!was || !now) throw new Error('member missing');
      if (!was.instrument.raised) r.lowered++;
      if (!pl.active && was.instrument.raised) r.inactiveRaisedTicks++;
      const grew = now.instrument.recorded > was.instrument.recorded;
      if (!grew) continue;
      grewThisTick = true;
      r.growthTicks++;
      (r.bots[k] as BotStat).recordedAll += now.instrument.recorded - was.instrument.recorded;
      const d = oracleDistance(pl.body, orderly.body);
      if (!was.instrument.raised || !pl.active || !moved || d > ORACLE_RANGE_I + 1e-9) r.violations++;
    }
    const slips = out.events.filter((e) => e.type === 'slip');
    r.slips += slips.length;
    if (slips.length > 0 && (anyGrowth || !grewThisTick)) r.slipOk = false;
    if (grewThisTick && !anyGrowth && slips.length !== 1) r.slipOk = false;
    if (grewThisTick) anyGrowth = true;
    const caughtNow = new Set(res.events.filter((e) => e.type === 'caught').map((e) => (e as { playerId: string }).playerId));
    for (const e of out.events) {
      const k = ids.indexOf(e.playerId);
      const stat = r.bots[k];
      if (!stat) continue;
      if (e.type === 'readingClosed') {
        r.closedReadings++;
        if (!stat.caught && !caughtNow.has(e.playerId)) stat.earnedBefore += e.value;
      }
      if (e.type === 'tapeDropped') r.tapesDropped++;
    }
    for (const id of caughtNow) {
      active.set(id, false);
      const stat = r.bots[ids.indexOf(id)];
      if (stat) stat.caught = true;
    }
    for (const f of [...crew.floor]) {
      for (const k of ids.keys()) {
        const id = ids[k] as string;
        const pl = players[k] as CrewPlayer;
        if (!active.get(id) || !pl.active || oracleDistance(pl.body, f.at) > 1.3) continue;
        const up = pickUpTape(crew, id, f.tape.id);
        if (up.ok) {
          crew = up.crew;
          r.pickups++;
          break;
        }
      }
    }
  }
  const dep = leaveFloor(crew, ids.filter((id) => active.get(id)));
  r.carriedValue = dep.carriedValue;
  r.lostValue = dep.lostValue;
  if (anyGrowth && r.slips !== 1) r.slipOk = false;
  if (!anyGrowth && r.slips !== 0) r.slipOk = false;
  return r;
}
const ORACLE_RANGE_I = 9;
function instrumentCounts(n: number) {
  const rs: IRun[] = [];
  for (let i = 0; i < n; i++) rs.push(instrumentRun(i));
  const total = (f: (r: IRun) => number): number => rs.reduce((a, r) => a + f(r), 0);
  const median = (xs: readonly number[]): number => [...xs].sort((a, b) => a - b)[Math.floor(xs.length / 2)] ?? 0;
  const values = rs.map((r) => r.carriedValue + r.lostValue).filter((v) => v > 0);
  const allBots = rs.flatMap((r) => r.bots);
  const earners = allBots.filter((b) => b.earnedBefore > 0);
  const nonEarners = allBots.filter((b) => b.recordedAll === 0);
  const caught = (bs: readonly BotStat[]) => bs.filter((b) => b.caught).length;
  return {
    runs: n,
    growthTicks: total((r) => r.growthTicks),
    lowered: total((r) => r.lowered),
    inactiveRaisedTicks: total((r) => r.inactiveRaisedTicks),
    withReading: rs.filter((r) => r.closedReadings > 0).length,
    closedReadings: total((r) => r.closedReadings),
    dropRuns: rs.filter((r) => r.tapesDropped > 0).length,
    tapesDropped: total((r) => r.tapesDropped),
    pickups: total((r) => r.pickups),
    medianValue: median(values),
    maxValue: Math.max(0, ...values),
    carried: total((r) => r.carriedValue),
    lost: total((r) => r.lostValue),
    earners: earners.length,
    earnersCaught: caught(earners),
    nonEarners: nonEarners.length,
    nonEarnersCaught: caught(nonEarners),
    violations: total((r) => r.violations),
    slipNotOk: rs.filter((r) => !r.slipOk).length,
  };
}

// =============================================================================================
// run.test.ts: the stare and safe runs (copied).

interface Box { x0: number; z0: number; x1: number; z1: number }
function oracleCar(plan: FloorPlan): Box {
  const w = elevatorWall(plan);
  if (!w) throw new Error('no elevator wall');
  const v = DIR_VEC[w];
  const cx = plan.landing.x + v.dx;
  const cy = plan.landing.y + v.dy;
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
function oracleStareSees(plan: FloorPlan, from: Body, yaw: number, fig: Body): boolean {
  if (from.level !== 0 || fig.level !== 0 || from.y !== 0 || fig.y !== 0) return false;
  const want = Math.atan2(-(fig.x - from.x), -(fig.z - from.z));
  let d = Math.abs(want - yaw) % (2 * Math.PI);
  if (d > Math.PI) d = 2 * Math.PI - d;
  if (d > (30 * Math.PI) / 180) return false;
  return surelyClear(plan, from, fig);
}
interface Actor { id: string; body: Body; yaw: number; pitch: number; raised?: boolean; call?: boolean; hold?: boolean }
function inputOf(a: Actor): PlayerInput {
  return { id: a.id, body: a.body, eye: BOT_EYE, yaw: a.yaw, pitch: a.pitch, hFovDeg: BOT_HFOV_DEG, vFovDeg: BOT_VFOV_DEG, call: a.call, holdDoors: a.hold, raised: a.raised };
}
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
const dist2 = (a: Body, b: Body): number => Math.hypot(a.x - b.x, a.z - b.z);
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
interface StareResult { violations: number; movedInBlink: number; blinkAdvance: number; caught: boolean; blinks: number; blackouts: number; telegraph: number; arrived: boolean }
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
  const res: StareResult = { violations: 0, movedInBlink: 0, blinkAdvance: 0, caught: false, blinks: 0, blackouts: 0, telegraph: 0, arrived: false };
  const out = new Set<string>();
  let blind = false;
  let lastSoon: { t: number; len: number; blackout: boolean } | null = null;
  let lastStart: number | null = null;
  let lastEnd: number | null = null;
  let lastLen = 0;
  let blackoutOn = false;
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
        if (lastSoon !== null) res.telegraph++;
        lastSoon = { t: e.t, len: e.len, blackout: e.blackout };
      }
      if (e.type === 'blinkStart') {
        res.blinks++;
        if (e.blackout) res.blackouts++;
        const warn = e.blackout ? BLACKOUT_WARNING : BLINK_WARNING;
        const lead = lastSoon === null ? -1 : e.t - lastSoon.t;
        if (Math.abs(lead - warn) > DT + 1e-9) res.telegraph++;
        if (lastSoon && (lastSoon.len !== e.len || lastSoon.blackout !== e.blackout)) res.telegraph++;
        if (e.len <= lastLen) res.telegraph++;
        const minGap = (BLINK_GAPS[0]?.[0] ?? 0) + warn;
        if (lastEnd !== null && e.t - lastEnd < minGap - DT - 1e-9) res.telegraph++;
        if (blackoutOn) res.telegraph++;
        blackoutOn = e.blackout;
        lastLen = e.len;
        lastStart = e.t;
        lastSoon = null;
      }
      if (e.type === 'blinkEnd' && lastStart !== null) {
        const len = e.t - lastStart;
        if (e.blackout) {
          if (!types.includes('carArrived')) res.telegraph++;
          if (len < 9 - DT - 1e-9) res.telegraph++;
        } else if (Math.abs(len - lastLen) > DT + 1e-9) res.telegraph++;
        lastEnd = e.t;
      }
      if (e.type === 'carArrived' && !(blackoutOn && types.includes('blinkEnd'))) res.telegraph++;
      if (e.type === 'caught') res.caught = true;
      if ('playerId' in e && e.playerId === LURE_ID) res.violations++;
    }
    const after = st.orderly.body;
    const moved = after.x !== before.x || after.z !== before.z || after.level !== before.level;
    if (moved) {
      const seers = actors.filter((a) => !out.has(a.id) && oracleStareSees(plan, a.body, a.yaw, before));
      if (seers.length > 0 && !blindNow) res.violations++;
      if (seers.length > 0 && blindNow) {
        res.movedInBlink++;
        res.blinkAdvance += dist2(before, after);
      }
    }
    for (const e of r.ev) if (e.type === 'caught') out.add(e.playerId);
    if (types.includes('carArrived') || st.phase === 'ended') {
      res.arrived = types.includes('carArrived');
      break;
    }
  }
  if (lastSoon !== null && st.phase === 'coming') res.telegraph++;
  return res;
}
function stareCounts(n: number) {
  const rs: StareResult[] = [];
  for (let i = 0; i < n; i++) rs.push(stareRun(i));
  return {
    runs: n,
    violations: rs.reduce((s, r) => s + r.violations, 0),
    telegraph: rs.reduce((s, r) => s + r.telegraph, 0),
    moved: rs.filter((r) => r.movedInBlink > 0).length,
    caught: rs.filter((r) => r.caught).length,
    blinks: rs.reduce((s, r) => s + r.blinks, 0),
    blackouts: rs.reduce((s, r) => s + r.blackouts, 0),
    advance: rs.reduce((s, r) => s + r.blinkAdvance, 0),
    arrived: rs.filter((r) => r.arrived).length,
    arrivedOneBlackout: rs.filter((r) => r.arrived && r.blackouts === 1).length,
  };
}
type RiderMode = 'exit' | 'wander' | 'toLanding' | 'enter' | 'inCar';
interface Rider { actor: Actor; bot: Bot; mode: RiderMode; timer: number; route: Body[]; walk: PathWalk | null; rng: Rng }
interface SafeResult { violations: number; caught: number; encounters: number; rides: number; events: number }
function safeRun(i: number, seconds = 90): SafeResult {
  const seed = `safe-${i}`;
  const n = 1 + (i % 4);
  const ids = Array.from({ length: n }, (_, k) => `b${k}`);
  let st = createRun(seed, ids);
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
  const res: SafeResult = { violations: 0, caught: 0, encounters: 0, rides: 0, events: 0 };
  const caught = new Set<string>();
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
          stepBot(st.plan, r.bot, DT, st.orderly.body);
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
      res.events++;
      if (e.type === 'caught') {
        res.caught++;
        caught.add(e.playerId);
        const b = sent.get(e.playerId);
        if (b && oracleInCar(box, b)) res.violations++;
        if (e.playerId === LURE_ID) res.violations++;
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
    if (st.phase !== 'riding' && o.level === 0 && gap < ORDERLY_RADIUS - 1e-3) res.violations++;
    if (st.phase !== 'riding' && gap < 2.5 && riders.some((r) => oracleInCar(box, r.actor.body))) res.encounters++;
  }
  return res;
}
function safeCounts(n: number) {
  const rs: SafeResult[] = [];
  for (let i = 0; i < n; i++) rs.push(safeRun(i));
  return {
    runs: n,
    violations: rs.reduce((s, r) => s + r.violations, 0),
    encounterRuns: rs.filter((r) => r.encounters > 0).length,
    encounterTicks: rs.reduce((s, r) => s + r.encounters, 0),
    caught: rs.reduce((s, r) => s + r.caught, 0),
    rides: rs.reduce((s, r) => s + r.rides, 0),
    events: rs.reduce((s, r) => s + r.events, 0),
  };
}

// =============================================================================================
// clinic.test.ts connectivity, as a count.

function clinicCounts() {
  let missing = 0;
  let unreachableRooms = 0;
  let walkable = 0;
  for (const depth of [1, 2, 3, 4]) {
    for (let i = 0; i < 200; i++) {
      const p = generateClinic(`seed-${i}`, depth);
      const seen = reachableFrom(p, p.landing);
      for (const level of [0, 1] as const) for (let y = 0; y < p.height; y++) for (let x = 0; x < p.width; x++) {
        if (!isWalkable(p, level, x, y)) continue;
        walkable++;
        if (!seen.has(posIndex(p, { level, x, y }))) missing++;
      }
      for (const r of p.rooms) if (!seen.has(posIndex(p, { level: r.level, x: r.x, y: r.y }))) unreachableRooms++;
    }
  }
  return { floors: 800, walkable, missing, unreachableRooms };
}

// =============================================================================================

function blackoutCounts(waits: number) {
  const tables = [];
  for (const depth of [1, 2, 3]) for (const style of ['stay', 'flee'] as const) tables.push(waitTable(style, depth, waits).table);
  return { waits, tables, lines: tables.map(tableLine) };
}

const t0 = performance.now();
const result: Record<string, unknown> = {};
const sizes = process.argv.includes('--sub-only') ? [['sub', SUB]] as const : ([['sub', SUB], ['full', FULL]] as const);
result.clinic = clinicCounts();
for (const [name, n] of sizes) {
  result[name] = {
    entity: entityCounts(n.entity),
    instrument: instrumentCounts(n.instrument),
    stare: stareCounts(n.stare),
    safe: safeCounts(n.safe),
    hear: hearCounts(n.hear),
    blackout: blackoutCounts(n.waits),
  };
  console.log(`${name}: ${JSON.stringify(result[name], (_k, v) => (typeof v === 'number' && !Number.isInteger(v) ? Number(v.toFixed(3)) : v))}`);
}
mkdirSync(OUT, { recursive: true });
writeFileSync(join(OUT, 'properties.json'), JSON.stringify(result, (_k, v) => (typeof v === 'number' && !Number.isInteger(v) ? `~${hexOf(v)}` : v)));
console.log(`properties.json written in ${((performance.now() - t0) / 1000).toFixed(1)} s`);

function hexOf(x: number): string {
  const f = new Float64Array([x]);
  const u = new Uint32Array(f.buffer);
  return (u[1] as number).toString(16).padStart(8, '0') + (u[0] as number).toString(16).padStart(8, '0');
}
void [stairCells, pickUpTape];
