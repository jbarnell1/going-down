// One wait for the car, start to bell, with a crew of waiting bots (sim/bot.ts) of one style, on a
// floor of a given depth. Shared by the blackout tests and the tuning script.

import { createWaitBot, stepWaitBot, waitBotInput, type WaitStyle } from '../../src/sim/bot';
import { generateClinic } from '../../src/sim/clinic';
import { createOrderly } from '../../src/sim/entity';
import { distancesFrom, isWalkable, posFromIndex, type Pos } from '../../src/sim/floor';
import { bodyAtCell } from '../../src/sim/move';
import { makeRng } from '../../src/sim/rng';
import { carGeometry, createRun, inCar, stepRun, type RunEvent, type RunPlayer, type RunState } from '../../src/sim/run';

export const WAIT_DT = 0.05;
/** Where the Orderly starts, hunting: this many cells' walk from the landing (drawn per wait). */
export const ORDERLY_FROM_CELLS = [6, 14] as const;

export interface WaitResult {
  label: string;
  crew: number;
  caught: number;
  /** Every crew member not caught was aboard when the doors closed. */
  boarded: boolean;
  /** Caught during the blackout (from its start to the doors opening). */
  caughtInBlackout: number;
  /** Caught after the lights came back. */
  caughtAfter: number;
  darks: number[];
  /** During the blackout: the Orderly's closest approach to anyone not yet caught (m, same level), and how far anyone got from the car door (m). */
  closest: number;
  farthest: number;
  /** Seconds from the doors opening to the last surviving member boarding (null if not all did). */
  boardedAfter: number | null;
  events: RunEvent[];
}

/** A floor of `depth` with the car away, the crew on the landing, and the Orderly hunting some way off. */
export function waitStart(seed: string, depth: number, n: number): RunState {
  const ids = Array.from({ length: n }, (_, k) => `p${k}`);
  const base = createRun(seed, ids);
  const plan = generateClinic(seed, depth);
  const car = carGeometry(plan);
  const dist = distancesFrom(plan, plan.landing);
  const cands: Pos[] = [];
  for (let i = 0; i < dist.length; i++) {
    const d = dist[i] ?? -1;
    if (d < ORDERLY_FROM_CELLS[0] || d > ORDERLY_FROM_CELLS[1]) continue;
    const p = posFromIndex(plan, i);
    if (isWalkable(plan, p.level, p.x, p.y)) cands.push(p);
  }
  const at = makeRng(seed).fork('orderly').pick(cands);
  const orderly = { ...createOrderly(plan), body: bodyAtCell(plan, at), mode: 'hunting' as const };
  return { ...base, depth, plan, car, orderly, entityId: `orderly-${depth}`, phase: 'away', players: base.players.map((p): RunPlayer => ({ ...p, aboard: false })) };
}

export function runWait(style: WaitStyle, depth: number, i: number): WaitResult {
  const seed = `wait-${depth}-${i}`;
  const n = 1 + (i % 4);
  let st = waitStart(seed, depth, n);
  const bots = st.players.map((p, k) => createWaitBot(st, p.id, k, style));
  st = { ...st, players: st.players.map((p, k): RunPlayer => ({ ...p, body: (bots[k] as (typeof bots)[number]).body })) };
  const caught = new Set<string>();
  const events: RunEvent[] = [];
  const res: WaitResult = { label: `${seed} ${style} x${n}`, crew: n, caught: 0, boarded: false, caughtInBlackout: 0, caughtAfter: 0, darks: [], closest: Number.POSITIVE_INFINITY, farthest: 0, boardedAfter: null, events };
  let blackout = false;
  let lit = false;
  let openedAt: number | null = null;
  for (let k = 0; k < 140 / WAIT_DT; k++) {
    const live = bots.filter((b) => !caught.has(b.id));
    for (const b of live) if (k > 0) stepWaitBot(st, b, WAIT_DT);
    const waiting = live.some((b) => !inCar(st.car, b.body));
    const inputs = live.map((b, j) => waitBotInput(b, b.mode === 'aboard' && waiting, k === 0 && j === 0));
    const r = stepRun(st, inputs, WAIT_DT);
    st = r.state;
    events.push(...r.events);
    for (const e of r.events) {
      if (e.type === 'blinkStart') {
        res.darks.push(e.len);
        if (e.blackout) blackout = true;
      }
      if (e.type === 'carArrived') {
        lit = true;
        openedAt = e.t;
      }
      if (e.type === 'caught') {
        caught.add(e.playerId);
        res.caught++;
        if (blackout && !lit) res.caughtInBlackout++;
        if (lit) res.caughtAfter++;
      }
    }
    if (blackout && !lit) {
      const o = st.orderly.body;
      for (const b of bots) {
        if (caught.has(b.id)) continue;
        if (b.body.level === o.level) res.closest = Math.min(res.closest, Math.hypot(b.body.x - o.x, b.body.z - o.z));
        res.farthest = Math.max(res.farthest, Math.hypot(b.body.x - st.car.doorX, b.body.z - st.car.doorZ));
      }
    }
    if (openedAt !== null && res.boardedAfter === null && bots.every((b) => caught.has(b.id) || inCar(st.car, b.body))) res.boardedAfter = st.t - openedAt;
    const bell = r.events.find((e) => e.type === 'bell');
    if (bell || st.phase === 'ended') {
      const closed = r.events.find((e) => e.type === 'doorsClosed');
      const aboard = new Set(closed && closed.type === 'doorsClosed' ? closed.aboard : []);
      res.boarded = bots.every((b) => caught.has(b.id) || aboard.has(b.id));
      return res;
    }
  }
  throw new Error(`${res.label}: no bell after 140 s (phase ${st.phase})`);
}

export interface WaitTable {
  style: WaitStyle;
  depth: number;
  waits: number;
  lost: number;
  boarded: number;
  caught: number;
  caughtInBlackout: number;
  caughtAfter: number;
  /** Waits where the Orderly came within 5 m of someone in the blackout (a chase). */
  chased: number;
  /** Median of the farthest anyone got from the car in the blackout (m). */
  medianFarthest: number;
}

export function waitTable(style: WaitStyle, depth: number, waits: number): { table: WaitTable; results: WaitResult[] } {
  const results: WaitResult[] = [];
  for (let i = 0; i < waits; i++) results.push(runWait(style, depth, i));
  const table: WaitTable = {
    style,
    depth,
    waits,
    lost: results.filter((r) => r.caught > 0).length,
    boarded: results.filter((r) => r.boarded).length,
    caught: results.reduce((s, r) => s + r.caught, 0),
    caughtInBlackout: results.reduce((s, r) => s + r.caughtInBlackout, 0),
    caughtAfter: results.reduce((s, r) => s + r.caughtAfter, 0),
    chased: results.filter((r) => r.closest < 5).length,
    medianFarthest: [...results.map((r) => r.farthest)].sort((a, b) => a - b)[Math.floor(results.length / 2)] ?? 0,
  };
  return { table, results };
}

export function tableLine(t: WaitTable): string {
  const pc = (x: number): string => `${((100 * x) / t.waits).toFixed(1)}%`;
  return `depth ${t.depth} ${t.style.padEnd(4)}: ${t.waits} waits, lost someone ${t.lost} (${pc(t.lost)}), all survivors boarded ${t.boarded} (${pc(t.boarded)}), catches ${t.caught} (in the blackout ${t.caughtInBlackout}, after the lights ${t.caughtAfter}); chased within 5 m in the blackout ${t.chased} (${pc(t.chased)}), median farthest from the car ${t.medianFarthest.toFixed(1)} m`;
}
