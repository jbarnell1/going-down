import { describe, expect, it } from 'vitest';
import { botView, createBot, stepBot, BOT_EYE, BOT_HFOV_DEG, BOT_VFOV_DEG, type Bot } from '../../src/sim/bot';
import { generateClinic } from '../../src/sim/clinic';
import { createOrderly, stepEntity, type OrderlyEvent, type OrderlyState, type PlayerView } from '../../src/sim/entity';
import type { FloorPlan } from '../../src/sim/floor';
import {
  createCrew,
  leaveFloor,
  LOUDNESS_REST,
  member,
  pickUpTape,
  rateAt,
  READING_GAP,
  repeatFactor,
  setRaised,
  SLIP_TEXT,
  stepCrew,
  tapeValue,
  TICK_REST_HZ,
  type CrewEvent,
  type CrewPlayer,
  type CrewState,
  type EntityTick,
} from '../../src/sim/instrument';
import { bodyAtCell, feetHeight, type Body } from '../../src/sim/move';
import { makeRng } from '../../src/sim/rng';

const DT = 0.05;

// =============================================================================================
// The oracle, written from first principles and sharing nothing with instrument.ts: the earning
// rule says a reading may only grow on a tick where (a) the holder's instrument was raised and
// the holder active, (b) the Orderly MOVED that tick: its position differs from the previous
// tick's, or its catching wind-up started, ran down, or completed, and (c) it was within 9 m in a
// straight line of the holder (feet to feet, measured here) after the tick.
// =============================================================================================

const ORACLE_RANGE = 9;

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

// =============================================================================================
// The property runs.
// =============================================================================================

const RUNS = 500;
const RUN_SECONDS = 60;

interface BotStat {
  /** Value of readings closed before any catch of this bot (the reading cut off by the catch excluded). */
  earnedBefore: number;
  /** Everything recorded, including the reading cut off by the catch. */
  recordedAll: number;
  caught: boolean;
}

interface RunResult {
  label: string;
  growthTicks: number;
  violations: string[];
  lowered: number;
  inactiveRaisedTicks: number;
  closedReadings: number;
  slips: number;
  slipOk: boolean;
  tapesDropped: number;
  pickups: number;
  carriedValue: number;
  lostValue: number;
  bots: BotStat[];
  hash: string;
}

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

function hashCrew(h: number, c: CrewState): number {
  const parts = c.members.map((m) => `${m.id}:${m.instrument.needle}:${m.instrument.current?.value ?? -1}:${m.instrument.tickHz}:${m.tape.id}:${m.tape.total}:${m.carrying.length}`);
  const text = `${c.t.toFixed(4)}|${parts.join(',')}|${c.floor.length}`;
  for (let i = 0; i < text.length; i++) h = Math.imul(h ^ text.charCodeAt(i), 16777619);
  return h >>> 0;
}

function runOne(i: number): RunResult {
  const seed = `earn-${i}`;
  const depth = 1 + (i % 4);
  const nBots = 1 + (Math.floor(i / 4) % 4);
  const p = plan(seed, depth);
  const rng = makeRng(seed).fork('setup');
  const toggles = makeRng(seed).fork('toggles');
  const bots: Bot[] = [];
  for (let b = 0; b < nBots; b++) {
    // Watchfulness spread over 0..1; in every third run the first bot never looks behind.
    const oblivious = b === 0 && i % 3 === 0;
    bots.push(createBot(p, `bot${b}`, `${seed}:${b}`, { watchfulness: rng.next(), oblivious, start: b === 0 ? p.landing : undefined }));
  }
  const ids = bots.map((b) => b.id);
  const active = new Map(ids.map((id) => [id, true]));
  let crew = createCrew(ids);
  for (const id of ids) crew = setRaised(crew, id, true);
  // bot1 lowers and raises its instrument now and then, so lowered instruments get checked.
  let toggleIn = 2 + toggles.next() * 6;
  let orderly = createOrderly(p);
  const r: RunResult = {
    label: `${seed} d${depth} bots${nBots}`,
    growthTicks: 0,
    violations: [],
    lowered: 0,
    inactiveRaisedTicks: 0,
    closedReadings: 0,
    slips: 0,
    slipOk: true,
    tapesDropped: 0,
    pickups: 0,
    carriedValue: 0,
    lostValue: 0,
    bots: ids.map(() => ({ earnedBefore: 0, recordedAll: 0, caught: false })),
    hash: '',
  };
  let hash = 2166136261;
  let anyGrowth = false;
  const ticks = Math.round(RUN_SECONDS / DT);
  for (let tick = 0; tick < ticks; tick++) {
    toggleIn -= DT;
    if (toggleIn <= 0 && nBots > 1) {
      toggleIn = 1 + toggles.next() * 6;
      const m = member(crew, 'bot1');
      if (m) crew = setRaised(crew, 'bot1', !m.instrument.raised);
    }
    // A caught bot stays down, but in odd runs it raises its instrument anyway (it must not record).
    if (i % 2 === 1) for (const id of ids) if (!active.get(id)) crew = setRaised(crew, id, true);

    for (const b of bots) if (active.get(b.id)) stepBot(p, b, DT);
    const views: PlayerView[] = bots.map((b) => ({ ...botView(b), active: active.get(b.id) ?? false }));
    const before = orderly;
    const res = stepEntity(p, before, views, DT);
    orderly = res.state;
    const players: CrewPlayer[] = views.map((v) => ({ id: v.id, body: v.body, active: v.active }));
    const entity: EntityTick = { id: 'orderly', trait: 'stillness', prev: before, next: orderly, events: res.events };
    const crewBefore = crew;
    const out = stepCrew(p, crew, players, [entity], DT);
    crew = out.crew;
    hash = hashCrew(hash, crew);

    // 1. The earning rule, by the oracle.
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
      const why: string[] = [];
      if (!was.instrument.raised) why.push('lowered');
      if (!pl.active) why.push('inactive');
      if (!moved) why.push('entity did not move');
      if (d > ORACLE_RANGE + 1e-9) why.push(`out of range ${d.toFixed(2)} m`);
      if (why.length) r.violations.push(`t=${crew.t.toFixed(2)} ${id}: ${why.join(', ')}`);
    }

    // 6 (property form). The slip: once per run, on the first tick anything was recorded.
    const slips = out.events.filter((e) => e.type === 'slip');
    r.slips += slips.length;
    if (slips.length > 0 && (anyGrowth || !grewThisTick)) r.slipOk = false;
    if (grewThisTick && !anyGrowth && slips.length !== 1) r.slipOk = false;
    if (grewThisTick) anyGrowth = true;

    const caughtNow = new Set(res.events.filter((e) => e.type === 'caught').map((e) => e.playerId));
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

    // Active bots pick up any tape within reach of where they stand (distance measured here).
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
  r.hash = hash.toString(16);
  if (anyGrowth && r.slips !== 1) r.slipOk = false;
  if (!anyGrowth && r.slips !== 0) r.slipOk = false;
  return r;
}

const median = (xs: readonly number[]): number => [...xs].sort((a, b) => a - b)[Math.floor(xs.length / 2)] ?? 0;

describe('the instrument: the earning rule over many runs, checked by an independent oracle', () => {
  const results: RunResult[] = [];
  const t0 = performance.now();
  for (let i = 0; i < RUNS; i++) results.push(runOne(i));
  const seconds = (performance.now() - t0) / 1000;
  const total = (f: (r: RunResult) => number): number => results.reduce((a, r) => a + f(r), 0);

  const withReading = results.filter((r) => r.closedReadings > 0).length;
  const dropRuns = results.filter((r) => r.tapesDropped > 0).length;
  const values = results.map((r) => r.carriedValue + r.lostValue).filter((v) => v > 0);
  const allBots = results.flatMap((r) => r.bots);
  const earners = allBots.filter((b) => b.earnedBefore > 0);
  const nonEarners = allBots.filter((b) => b.recordedAll === 0);
  const rate = (bs: readonly BotStat[]): number => (bs.length ? bs.filter((b) => b.caught).length / bs.length : 0);
  const recorders = allBots.filter((b) => b.recordedAll > 0);
  const noEarnBefore = allBots.filter((b) => b.earnedBefore === 0);
  const byEarn = [...earners].sort((a, b) => a.earnedBefore - b.earnedBefore);
  const lowHalf = byEarn.slice(0, Math.floor(byEarn.length / 2));
  const highHalf = byEarn.slice(Math.floor(byEarn.length / 2));
  console.log(
    [
      `Instrument property runs: ${RUNS} runs x ${RUN_SECONDS} s at ${1 / DT} Hz in ${seconds.toFixed(1)} s (every third run's first bot is oblivious)`,
      `  growth-ticks checked by the oracle: ${total((r) => r.growthTicks)}`,
      `  lowered instrument-ticks: ${total((r) => r.lowered)}, inactive-with-raised-instrument ticks: ${total((r) => r.inactiveRaisedTicks)}`,
      `  runs with at least one closed reading: ${withReading}/${RUNS} (closed readings: ${total((r) => r.closedReadings)})`,
      `  tape value per earning run (carried + lost): median ${median(values).toFixed(1)}, max ${Math.max(0, ...values).toFixed(1)} (${values.length} runs)`,
      `  carried out ${total((r) => r.carriedValue).toFixed(0)}, lost on the floor ${total((r) => r.lostValue).toFixed(0)}`,
      `  runs with a tape dropped: ${dropRuns} (tapes dropped ${total((r) => r.tapesDropped)}, picked up ${total((r) => r.pickups)})`,
      `  catch rate, earned before any catch: ${(100 * rate(earners)).toFixed(1)}% of ${earners.length}; recorded nothing: ${(100 * rate(nonEarners)).toFixed(1)}% of ${nonEarners.length}`,
      `  catch rate, recorded anything at all (incl. the reading cut off by the catch): ${(100 * rate(recorders)).toFixed(1)}% of ${recorders.length}`,
      `  catch rate, closed no reading before any catch (includes those caught on their first pass): ${(100 * rate(noEarnBefore)).toFixed(1)}% of ${noEarnBefore.length}`,
      `  among earners: lower-earning half caught ${(100 * rate(lowHalf)).toFixed(1)}% (median earned ${median(lowHalf.map((b) => b.earnedBefore)).toFixed(1)}), higher-earning half ${(100 * rate(highHalf)).toFixed(1)}% (median ${median(highHalf.map((b) => b.earnedBefore)).toFixed(1)})`,
    ].join('\n'),
  );

  it('a reading only grows while the Orderly moves within range of a raised, active holder', () => {
    const bad = results.flatMap((r) => r.violations.map((v) => `${r.label}: ${v}`));
    expect(bad.slice(0, 10)).toEqual([]);
    expect(total((r) => r.growthTicks)).toBeGreaterThan(5000);
    expect(total((r) => r.lowered)).toBeGreaterThan(1000);
    expect(total((r) => r.inactiveRaisedTicks)).toBeGreaterThan(1000);
  });

  it('is not vacuous: readings close in many runs and tapes get dropped', () => {
    expect(withReading / RUNS).toBeGreaterThan(0.3);
    expect(dropRuns).toBeGreaterThan(10);
    expect(Math.max(...values)).toBeGreaterThan(50);
  });

  it('greed costs: players who earned were caught more often than players who recorded nothing', () => {
    expect(earners.length).toBeGreaterThan(50);
    expect(rate(earners)).toBeGreaterThan(rate(nonEarners));
  });

  it('the slip prints exactly once per run that recorded anything, on the first recording tick', () => {
    expect(results.filter((r) => !r.slipOk).map((r) => r.label)).toEqual([]);
  });

  it('determinism: the same seed gives the same crew state sequence', () => {
    for (const i of [0, 9, 123, 377]) expect(runOne(i).hash).toBe(results[i]?.hash);
  });
});

// =============================================================================================
// Scripted scenes on a straight corridor running out from where the Orderly starts.
// =============================================================================================

interface Corridor {
  p: FloorPlan;
  /** A body on the corridor's axis, `s` metres from the Orderly's start. */
  at: (s: number) => Body;
  /** Yaw looking back toward the Orderly's start, and away from it. */
  toward: number;
  away: number;
}

function corridor(minCells: number): Corridor {
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
    // Yaw facing along (fx, fz), three.js style.
    const toward = Math.atan2(dx, dz); // facing (-dx, -dz)
    const away = Math.atan2(-dx, -dz);
    return { p, at, toward, away };
  }
  throw new Error('no corridor found');
}

function view(id: string, b: Body, yaw: number, active = true): PlayerView {
  return { id, body: b, eye: BOT_EYE, yaw, pitch: 0, hFovDeg: BOT_HFOV_DEG, vFovDeg: BOT_VFOV_DEG, active };
}

interface Scene {
  p: FloorPlan;
  orderly: OrderlyState;
  crew: CrewState;
  events: CrewEvent[];
}

interface TickLog {
  needle: string;
  value: number;
  rate: number;
  factor: number;
  distance: number;
  tickHz: number;
  loudness: number;
  events: CrewEvent[];
}

function tick(sc: Scene, me: Body, yaw: number): TickLog {
  const v = view('me', me, yaw);
  const before = sc.orderly;
  const res = stepEntity(sc.p, before, [v], DT);
  sc.orderly = res.state;
  const out = stepCrew(sc.p, sc.crew, [{ id: 'me', body: me, active: true }], [{ id: 'orderly', trait: 'stillness', prev: before, next: res.state, events: res.events }], DT);
  sc.crew = out.crew;
  sc.events.push(...out.events);
  const inst = member(sc.crew, 'me')?.instrument;
  if (!inst) throw new Error('no me');
  return {
    needle: inst.needle,
    value: inst.current?.value ?? 0,
    rate: inst.rate,
    factor: inst.factor,
    distance: Math.hypot(me.x - res.state.body.x, me.z - res.state.body.z),
    tickHz: inst.tickHz,
    loudness: inst.loudness,
    events: out.events,
  };
}

describe('the instrument: scripted scenes', () => {
  it('staring earns nothing: 30 s at 5 m, instrument raised, needle dormant, value 0', () => {
    const c = corridor(4);
    const sc: Scene = { p: c.p, orderly: createOrderly(c.p), crew: setRaised(createCrew(['me']), 'me', true), events: [] };
    const me = c.at(5);
    const start = sc.orderly.body;
    for (let k = 0; k < 30 / DT; k++) {
      const l = tick(sc, me, c.toward);
      expect(l.needle).toBe('dormant');
      expect(l.value).toBe(0);
    }
    expect(sc.orderly.body).toEqual(start);
    expect(sc.orderly.mode).toBe('hunting'); // awake, and held still by the stare
    expect(member(sc.crew, 'me')?.instrument.recorded).toBe(0);
    expect(member(sc.crew, 'me')?.tape.readings).toEqual([]);
    expect(sc.events).toEqual([]);
  });

  it('the routine: back turned from 8 m, turn at 2 m, the reading closes onto the tape; a closer second pass pays at the repeat factor; slip once; ticking rises then rests', () => {
    const c = corridor(9);
    const sc: Scene = { p: c.p, orderly: createOrderly(c.p), crew: setRaised(createCrew(['me']), 'me', true), events: [] };
    let me = c.at(8);

    // Pass 1: back turned until it is within 2 m.
    const pass1: TickLog[] = [];
    for (let k = 0; k < 20 / DT; k++) {
      const l = tick(sc, me, c.away);
      pass1.push(l);
      if (l.distance <= 2.0) break;
    }
    const rec1 = pass1.filter((l) => l.needle === 'recording');
    expect(pass1[pass1.length - 1]?.distance).toBeLessThanOrEqual(2.0);
    expect(rec1.length).toBeGreaterThan(20);
    // Climbing: the value never drops while recording, and the rate rises as it closes in.
    for (let k = 1; k < rec1.length; k++) {
      expect((rec1[k] as TickLog).value).toBeGreaterThan((rec1[k - 1] as TickLog).value);
      expect((rec1[k] as TickLog).rate).toBeGreaterThanOrEqual((rec1[k - 1] as TickLog).rate - 1e-9);
    }
    // 8. Ticking rises with the reading.
    for (let k = 1; k < rec1.length; k++) {
      expect((rec1[k] as TickLog).tickHz).toBeGreaterThan((rec1[k - 1] as TickLog).tickHz);
      expect((rec1[k] as TickLog).loudness).toBeGreaterThan((rec1[k - 1] as TickLog).loudness);
    }
    expect(rec1[0]?.factor).toBe(1);
    // 6. The slip: exactly once, exact text, on the first recording tick.
    const firstRec = pass1.findIndex((l) => l.needle === 'recording');
    const slipTicks = pass1.map((l, k) => (l.events.some((e) => e.type === 'slip') ? k : -1)).filter((k) => k >= 0);
    expect(slipTicks).toEqual([firstRec]);
    const slip = sc.events.find((e) => e.type === 'slip');
    expect(slip && slip.type === 'slip' ? slip.text : '').toBe('recorded while: subject moving');
    expect(SLIP_TEXT.stillness).toBe('recorded while: subject moving');
    const value1 = pass1[pass1.length - 1]?.value ?? 0;

    // Turn round: it freezes, recording stops at once, and the reading closes after the gap.
    const frozenAt = sc.orderly.body;
    let closedAfter = -1;
    let rested: TickLog | null = null;
    for (let k = 0; k < 3 / DT; k++) {
      const l = tick(sc, me, c.toward);
      expect(sc.orderly.body).toEqual(frozenAt);
      expect(l.needle).toBe('dormant');
      if (closedAfter < 0 && l.events.some((e) => e.type === 'readingClosed')) {
        closedAfter = (k + 1) * DT;
        rested = l;
      }
    }
    expect(closedAfter).toBeCloseTo(READING_GAP, 5);
    expect(rested?.tickHz).toBe(TICK_REST_HZ);
    expect(rested?.loudness).toBe(LOUDNESS_REST);
    const tape1 = member(sc.crew, 'me')?.tape;
    expect(tape1?.readings.length).toBe(1);
    expect(tape1?.readings[0]?.value).toBeCloseTo(value1, 9);
    expect(tape1?.total).toBeCloseTo(value1, 9);

    // Back away to 8 m while watching it (it stays frozen), then turn away again, and turn back
    // only once it is within 1.25 m.
    let s = 8;
    while (Math.hypot(me.x - sc.orderly.body.x, me.z - sc.orderly.body.z) < 8) {
      s += 2.2 * DT;
      me = c.at(s);
      tick(sc, me, c.toward);
      expect(sc.orderly.body).toEqual(frozenAt);
    }
    const pass2: TickLog[] = [];
    for (let k = 0; k < 20 / DT; k++) {
      const l = tick(sc, me, c.away);
      pass2.push(l);
      if (l.distance <= 1.25) break;
    }
    expect(pass2[pass2.length - 1]?.distance).toBeLessThanOrEqual(1.25);
    for (let k = 0; k < 3 / DT; k++) tick(sc, me, c.toward);
    const rec2 = pass2.filter((l) => l.needle === 'recording');
    expect(rec2.length).toBeGreaterThan(20);
    // The repeat factor is applied, tick by tick: rate = rateAt(distance) x the second factor,
    // so lower than the first reading would have paid at the same distance.
    const f2 = repeatFactor(1);
    expect(f2).toBeLessThan(1);
    for (const l of rec2) {
      expect(l.factor).toBe(f2);
      expect(l.rate).toBeCloseTo(rateAt(l.distance) * f2, 9);
      expect(l.rate).toBeLessThan(rateAt(l.distance));
    }
    // Closer is greedier: the raw rate at the closest point of pass 2 beats pass 1's best.
    const peak1 = Math.max(...rec1.map((l) => l.rate / l.factor));
    const peak2raw = Math.max(...rec2.map((l) => l.rate / l.factor));
    expect(peak2raw).toBeGreaterThan(peak1);
    const tape2 = member(sc.crew, 'me')?.tape;
    expect(tape2?.readings.length).toBe(2);
    expect(sc.events.filter((e) => e.type === 'slip').length).toBe(1);
    const r1 = tape2?.readings[0];
    const r2 = tape2?.readings[1];
    console.log(
      `routine: pass 1 (8 m -> 2 m) ${r1?.value.toFixed(1)} in ${r1?.duration.toFixed(2)} s (peak ${r1?.peakRate.toFixed(1)}/s); ` +
        `pass 2 (8 m -> 1.25 m, factor ${f2}) ${r2?.value.toFixed(1)} in ${r2?.duration.toFixed(2)} s (peak ${r2?.peakRate.toFixed(1)}/s, raw ${peak2raw.toFixed(1)}/s)`,
    );
  });

  it('tapes: dropped where the player is caught, picked up within reach, carried in twos, carried out or lost', () => {
    const p = generateClinic('tapes', 1);
    const base = createOrderly(p);
    const at = (x: number, z: number): Body => ({ x, z, level: 0, y: 0 });
    const ent = (b: Body): OrderlyState => ({ ...base, mode: 'hunting', body: b });
    let crew = createCrew(['a', 'b', 'c', 'd']);
    for (const id of ['a', 'c', 'd']) crew = setRaised(crew, id, true);
    const pos: Record<string, Body> = { a: at(10, 10), b: at(11, 10), c: at(12, 10), d: at(60, 60) };
    const players = (): CrewPlayer[] => Object.entries(pos).map(([id, body]) => ({ id, body, active: true }));
    let e = ent(at(14, 10));
    const all: CrewEvent[] = [];
    const step = (move: boolean, caught: string[] = []): void => {
      const prev = e;
      if (move) e = ent(at(e.body.x + 0.05, e.body.z));
      const events: OrderlyEvent[] = caught.map((id) => ({ type: 'caught', t: 0, playerId: id }));
      const out = stepCrew(p, crew, players(), [{ id: 'orderly', trait: 'stillness', prev, next: e, events }], DT);
      crew = out.crew;
      all.push(...out.events);
    };

    // a and c record 1 s (d is far away: 46+ m, nothing), then it stops and the readings close.
    for (let k = 0; k < 20; k++) step(true);
    for (let k = 0; k < 40; k++) step(false);
    const ta = member(crew, 'a')?.tape;
    const tc = member(crew, 'c')?.tape;
    expect(ta?.readings.length).toBe(1);
    expect(tc?.readings.length).toBe(1);
    expect(member(crew, 'd')?.tape.readings.length).toBe(0);
    // Give d a reading of its own: it comes near d.
    e = ent(at(64, 60));
    for (let k = 0; k < 20; k++) step(true);
    for (let k = 0; k < 40; k++) step(false);
    const td = member(crew, 'd')?.tape;
    expect(td?.readings.length).toBe(1);

    // a is caught: the tape lies at a's feet, readings intact; a gets a fresh, empty tape.
    step(false, ['a']);
    const dropA = all.find((x) => x.type === 'tapeDropped' && x.playerId === 'a');
    expect(dropA && dropA.type === 'tapeDropped' ? dropA.tapeId : '').toBe(ta?.id);
    expect(crew.floor.length).toBe(1);
    expect(crew.floor[0]?.at).toEqual(pos.a);
    expect(crew.floor[0]?.tape.readings).toEqual(ta?.readings);
    expect(member(crew, 'a')?.tape.readings.length).toBe(0);
    expect(member(crew, 'a')?.tape.id).not.toBe(ta?.id);
    expect(member(crew, 'a')?.instrument.raised).toBe(false);
    // c is caught too, right next to it.
    step(false, ['c']);
    expect(crew.floor.length).toBe(2);

    // d, 50 m away, cannot pick either up; b, 1 m from a and 1 m from c, picks up both.
    expect(pickUpTape(crew, 'd', ta?.id ?? '').reason).toBe('tooFar');
    let up = pickUpTape(crew, 'b', ta?.id ?? '');
    expect(up.ok).toBe(true);
    expect(up.event?.type).toBe('tapePickedUp');
    crew = up.crew;
    up = pickUpTape(crew, 'b', tc?.id ?? '');
    expect(up.ok).toBe(true);
    crew = up.crew;
    expect(member(crew, 'b')?.carrying.map((x) => x.id)).toEqual([ta?.id, tc?.id]);
    expect(crew.floor.length).toBe(0);
    expect(pickUpTape(crew, 'b', ta?.id ?? '').reason).toBe('noTape');

    // d is caught far away: its tape is on the floor when the elevator leaves.
    step(false, ['d']);
    expect(crew.floor.length).toBe(1);
    const dep = leaveFloor(crew);
    expect(dep.carried.map((x) => x.id).sort()).toEqual([ta?.id, tc?.id].sort());
    expect(dep.lost.map((x) => x.id)).toEqual([td?.id]);
    expect(dep.carriedValue).toBeCloseTo((ta?.total ?? 0) + (tc?.total ?? 0), 9);
    expect(dep.lostValue).toBeCloseTo(td?.total ?? 0, 9);
    expect(tapeValue(dep.carried)).toBeCloseTo(dep.carriedValue, 9);
    expect(dep.carriedValue).toBeGreaterThan(0);
    // b caught on the way would have lost everything b carried.
    expect(leaveFloor(crew, ['a', 'c']).carried).toEqual([]);

    // An inactive player cannot pick anything up.
    const out = stepCrew(p, crew, [...players().filter((x) => x.id !== 'b'), { id: 'b', body: pos.d as Body, active: false }], [], DT);
    expect(pickUpTape(out.crew, 'b', td?.id ?? '').reason).toBe('inactive');
  });
});
