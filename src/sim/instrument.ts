// The instrument: how the crew earns. Pure, deterministic logic; no rendering or audio.
//
// Pay comes from holding the instrument near an entity. It works by closeness, not by aim, and
// holding it is not looking (nothing here touches a PlayerView). It only records the scary part:
// a trait records only while the entity is doing the thing its safety rule protects you from. For
// the Orderly's Stillness that is "while it moves", which is only while nobody is looking at it.
//
// Per tick, AFTER the entity has been stepped, the game calls stepCrew once. Each raised
// instrument decides its needle and grows its current reading; a reading closes after a short gap
// without recording and goes onto its holder's tape. A caught player drops every tape they hold.
//
// Choices made here:
//  - Distance is the straight 3D distance between the holder's feet and the entity's feet after
//    the tick. Same level: that distance alone. Different levels: also needs line of sight from
//    the instrument (INSTRUMENT_HEIGHT) to the entity's chest.
//  - "Moved this tick": its position changed, or its catching wind-up advanced (started,
//    progressed or completed) this tick, i.e. it was in or finishing a wind-up and not held.
//  - Raised with no entity within SENSE_RANGE (3D distance, walls ignored): needle 'idle'.
//    Lowered, or holder inactive: 'off'.
//  - The repeat factor is read live each tick from the crew's memory, so two players recording the
//    same entity at once both get the same factor; each reading that closes steps it down.
//  - Readings shorter than READING_MIN_TIME are discarded silently and do not step the factor.
//  - On a catch, the victim's open reading closes at once (onto their tape) before the drop, and
//    their instrument is lowered. Empty tapes are not dropped.

import type { OrderlyEvent, OrderlyState } from './entity';
import type { FloorPlan } from './floor';
import type { Body } from './move';
import { hasLineOfSight } from './sight';
import { addReading, emptyTape, tapeValue, type Reading, type Tape, type Trait } from './tape';

export type { Reading, Tape, Trait } from './tape';
export { tapeValue } from './tape';

// ---------------------------------------------------------------------------------------------
// Tuning.

/** Walking speed cap (m/s) while the instrument is raised: you cannot sprint away while recording. */
export const RAISED_SPEED_CAP = 2.2;
/** Recording range (metres, straight line) from the holder to the entity. */
export const RECORD_RANGE = 9;
/** Within this distance (metres, straight line, walls ignored) the needle wakes to 'dormant'. */
export const SENSE_RANGE = 16;
/** At or inside this distance (metres) the rate is at its maximum. */
export const NEAR_DISTANCE = 1.5;
/** Pay per second at the edge of RECORD_RANGE. */
export const RATE_EDGE = 8;
/** Pay per second at NEAR_DISTANCE or closer. */
export const RATE_NEAR = 140;
/** Shape of the rate curve between edge and near: 2 means most of the gain is in the last metres. */
export const RATE_CURVE = 3;
/** A reading closes once recording has stopped for this long (seconds). */
export const READING_GAP = 1.5;
/** A closed reading counts only if it recorded for at least this long (seconds). */
export const READING_MIN_TIME = 0.5;
/** Repeat factors by how many readings of this entity and trait the crew already closed this run; the last repeats. */
export const REPEAT_FACTORS: readonly number[] = [1, 0.5, 0.2];
/** Tick rate (Hz) of a raised instrument with no reading open. */
export const TICK_REST_HZ = 1;
/** Tick rate (Hz) the moment a reading opens... */
export const TICK_MIN_HZ = 3;
/** ...rising toward this as the reading grows. */
export const TICK_MAX_HZ = 14;
/** Reading value at which the ticking has covered about 63% of the way from min to max. */
export const TICK_SCALE = 120;
/** Loudness (0..1) of the rest tick. */
export const LOUDNESS_REST = 0.1;
/** Loudness when a reading opens... */
export const LOUDNESS_MIN = 0.45;
/** ...rising toward this. The ticking is loud on purpose. */
export const LOUDNESS_MAX = 1;
/** Reach for picking up a tape (metres, straight line from feet to the tape). */
export const PICKUP_REACH = 1.3;
/** Height above the feet at which the instrument is held (for line of sight across levels). */
export const INSTRUMENT_HEIGHT = 1.2;
/** Height above the entity's feet that line of sight across levels aims at. */
export const ENTITY_CHEST = 1.7;
/** What the slip says, per trait. Printed the first time a trait is recorded in a run. */
export const SLIP_TEXT: Readonly<Record<Trait, string>> = { stillness: 'recorded while: subject moving' };

const EPS = 1e-9;

// ---------------------------------------------------------------------------------------------
// Types.

/** 'idle': raised, nothing near. 'contaminated' is reserved for later and never produced. */
export type Needle = 'off' | 'idle' | 'dormant' | 'recording' | 'contaminated';

export interface OpenReading {
  entityId: string;
  trait: Trait;
  value: number;
  /** Seconds of recording so far. */
  duration: number;
  /** Seconds since the last recording tick (0 on a recording tick). */
  quiet: number;
  peakRate: number;
}

export interface Instrument {
  raised: boolean;
  needle: Needle;
  current: OpenReading | null;
  /** Pay per second added this tick (after the repeat factor); 0 unless recording. */
  rate: number;
  /** The repeat factor applied this tick (1 when not recording). */
  factor: number;
  /** Distance to the nearest entity this tick, or null if none was given. */
  distance: number | null;
  /** Ticking, for sound and for entities that hear: ticks per second and loudness 0..1. */
  tickHz: number;
  loudness: number;
  /** Fractional tick carried between steps. */
  tickPhase: number;
  /** Audible ticks that fell within this step. */
  ticks: number;
  /** Everything ever added to any reading by this instrument (kept or discarded). Never decreases. */
  recorded: number;
}

/** One entity's tick, as the instrument needs it. */
export interface EntityTick {
  id: string;
  trait: Trait;
  prev: OrderlyState;
  next: OrderlyState;
  events: readonly OrderlyEvent[];
}

export interface Holder {
  body: Body;
  active: boolean;
}

export interface CrewPlayer extends Holder {
  id: string;
}

export interface CrewMember {
  id: string;
  /** Where they were at the last stepCrew (null before the first). */
  body: Body | null;
  active: boolean;
  instrument: Instrument;
  /** Their own tape: what their instrument records onto. */
  tape: Tape;
  /** Other tapes they picked up. */
  carrying: readonly Tape[];
}

export interface FloorTape {
  tape: Tape;
  at: Body;
}

export interface CrewState {
  t: number;
  members: readonly CrewMember[];
  floor: readonly FloorTape[];
  /** Traits that already printed a slip this run (once per trait for the whole crew). */
  slipsPrinted: readonly Trait[];
  /** Closed readings per `${entityId}/${trait}` this run. */
  repeats: Readonly<Record<string, number>>;
  nextTape: number;
  nextReading: number;
}

export type CrewEvent =
  | { type: 'slip'; t: number; playerId: string; entityId: string; trait: Trait; text: string }
  | { type: 'readingClosed'; t: number; playerId: string; tapeId: string; reading: Reading; value: number }
  | { type: 'tapeDropped'; t: number; playerId: string; tapeId: string; at: Body }
  | { type: 'tapePickedUp'; t: number; playerId: string; tapeId: string };

// ---------------------------------------------------------------------------------------------
// Helpers.

/** The walking speed the game should allow: capped while the instrument is raised. */
export function maxWalkSpeed(raised: boolean, baseSpeed: number): number {
  return raised ? Math.min(baseSpeed, RAISED_SPEED_CAP) : baseSpeed;
}

/** Pay per second at a distance, before the repeat factor. 0 outside RECORD_RANGE. */
export function rateAt(distance: number): number {
  if (distance > RECORD_RANGE + EPS) return 0;
  const k = Math.max(0, Math.min(1, (RECORD_RANGE - distance) / (RECORD_RANGE - NEAR_DISTANCE)));
  return RATE_EDGE + (RATE_NEAR - RATE_EDGE) * k ** RATE_CURVE;
}

/** The repeat factor after `closed` readings of the same entity and trait. */
export function repeatFactor(closed: number): number {
  const i = Math.max(0, Math.min(REPEAT_FACTORS.length - 1, closed));
  return REPEAT_FACTORS[i] ?? 1;
}

function repeatKey(entityId: string, trait: Trait): string {
  return `${entityId}/${trait}`;
}

/** Straight 3D distance between two bodies' feet. */
export function feetDistance(a: Body, b: Body): number {
  return Math.hypot(a.x - b.x, a.y - b.y, a.z - b.z);
}

/** Stillness: the Orderly moved this tick, or its wind-up advanced this tick. */
export function stillnessActing(prev: OrderlyState, next: OrderlyState): boolean {
  const a = prev.body;
  const b = next.body;
  if (a.x !== b.x || a.z !== b.z || a.y !== b.y || a.level !== b.level) return true;
  if (next.held) return false;
  return next.mode === 'windUp' || (prev.mode === 'windUp' && next.mode === 'dormant');
}

/** Whether the trait's dangerous behaviour is happening this tick. */
export function traitActing(e: EntityTick): boolean {
  switch (e.trait) {
    case 'stillness':
      return stillnessActing(e.prev, e.next);
  }
}

/** In recording range: within RECORD_RANGE, and with line of sight if on different levels. */
export function inRecordRange(plan: FloorPlan, holder: Body, entity: Body, distance = feetDistance(holder, entity)): boolean {
  if (distance > RECORD_RANGE + EPS) return false;
  if (holder.level === entity.level) return true;
  return hasLineOfSight(
    plan,
    { x: holder.x, y: holder.y + INSTRUMENT_HEIGHT, z: holder.z, level: holder.level },
    { x: entity.x, y: entity.y + ENTITY_CHEST, z: entity.z, level: entity.level },
  );
}

export function createInstrument(): Instrument {
  return { raised: false, needle: 'off', current: null, rate: 0, factor: 1, distance: null, tickHz: 0, loudness: 0, tickPhase: 0, ticks: 0, recorded: 0 };
}

// ---------------------------------------------------------------------------------------------
// One instrument.

export interface InstrumentStep {
  instrument: Instrument;
  /** Set on a tick that recorded: which entity and trait. */
  recordedFrom: { entityId: string; trait: Trait } | null;
  /** Readings that closed this tick (any length; the crew decides whether they count). */
  closed: OpenReading[];
}

/**
 * Advances one instrument by dt. Call after the entities have been stepped for this tick.
 * `factorFor` gives the current repeat factor for an entity and trait.
 */
export function stepInstrument(
  plan: FloorPlan,
  prev: Instrument,
  holder: Holder,
  entities: readonly EntityTick[],
  factorFor: (entityId: string, trait: Trait) => number,
  dt: number,
): InstrumentStep {
  const inst: Instrument = { ...prev, rate: 0, factor: 1, ticks: 0, distance: null };
  const closed: OpenReading[] = [];
  let recordedFrom: InstrumentStep['recordedFrom'] = null;
  const live = inst.raised && holder.active;

  let best: { e: EntityTick; d: number } | null = null;
  let sensed = false;
  for (const e of entities) {
    const d = feetDistance(holder.body, e.next.body);
    if (inst.distance === null || d < inst.distance) inst.distance = d;
    if (d <= SENSE_RANGE + EPS) sensed = true;
    if (!live) continue;
    if (traitActing(e) && inRecordRange(plan, holder.body, e.next.body, d) && (!best || d < best.d)) best = { e, d };
  }

  let cur = inst.current;
  if (best) {
    if (cur && (cur.entityId !== best.e.id || cur.trait !== best.e.trait)) {
      closed.push(cur);
      cur = null;
    }
    const factor = factorFor(best.e.id, best.e.trait);
    const rate = rateAt(best.d) * factor;
    const add = rate * dt;
    cur = cur
      ? { ...cur, value: cur.value + add, duration: cur.duration + dt, quiet: 0, peakRate: Math.max(cur.peakRate, rate) }
      : { entityId: best.e.id, trait: best.e.trait, value: add, duration: dt, quiet: 0, peakRate: rate };
    inst.rate = rate;
    inst.factor = factor;
    inst.recorded = prev.recorded + add;
    inst.needle = 'recording';
    recordedFrom = { entityId: best.e.id, trait: best.e.trait };
  } else {
    if (cur) {
      const quiet = cur.quiet + dt;
      if (quiet >= READING_GAP - EPS) {
        closed.push(cur);
        cur = null;
      } else {
        cur = { ...cur, quiet };
      }
    }
    inst.needle = !live ? 'off' : sensed ? 'dormant' : 'idle';
  }
  inst.current = cur;
  setTicking(inst, live, dt);
  return { instrument: inst, recordedFrom, closed };
}

function setTicking(inst: Instrument, live: boolean, dt: number): void {
  if (inst.current) {
    const k = 1 - Math.exp(-inst.current.value / TICK_SCALE);
    inst.tickHz = TICK_MIN_HZ + (TICK_MAX_HZ - TICK_MIN_HZ) * k;
    inst.loudness = LOUDNESS_MIN + (LOUDNESS_MAX - LOUDNESS_MIN) * k;
  } else if (live) {
    inst.tickHz = TICK_REST_HZ;
    inst.loudness = LOUDNESS_REST;
  } else {
    inst.tickHz = 0;
    inst.loudness = 0;
    inst.tickPhase = 0;
  }
  const phase = inst.tickPhase + inst.tickHz * dt;
  inst.ticks = Math.floor(phase + EPS);
  inst.tickPhase = Math.max(0, phase - inst.ticks);
}

// ---------------------------------------------------------------------------------------------
// The crew.

/** A fresh crew for a run: instruments lowered, one empty tape each (ids tape-1, tape-2, ...). */
export function createCrew(playerIds: readonly string[]): CrewState {
  return {
    t: 0,
    members: playerIds.map((id, i) => ({ id, body: null, active: true, instrument: createInstrument(), tape: emptyTape(`tape-${i + 1}`, id), carrying: [] })),
    floor: [],
    slipsPrinted: [],
    repeats: {},
    nextTape: playerIds.length + 1,
    nextReading: 1,
  };
}

/** Raises or lowers a player's instrument. Unknown players: unchanged. */
export function setRaised(crew: CrewState, playerId: string, raised: boolean): CrewState {
  if (!crew.members.some((m) => m.id === playerId)) return crew;
  return { ...crew, members: crew.members.map((m) => (m.id === playerId ? { ...m, instrument: { ...m.instrument, raised } } : m)) };
}

export function member(crew: CrewState, playerId: string): CrewMember | undefined {
  return crew.members.find((m) => m.id === playerId);
}

export interface CrewStep {
  crew: CrewState;
  events: CrewEvent[];
}

/**
 * Advances the whole crew by one tick, after the entities have been stepped. Steps every
 * instrument, writes closed readings to tapes, prints slips, and drops the tapes of anyone the
 * entities caught this tick. Players missing from `players` count as inactive where they last were.
 */
export function stepCrew(plan: FloorPlan, crew: CrewState, players: readonly CrewPlayer[], entities: readonly EntityTick[], dt: number): CrewStep {
  const t = crew.t + dt;
  const events: CrewEvent[] = [];
  const repeats: Record<string, number> = { ...crew.repeats };
  const slips: Trait[] = [...crew.slipsPrinted];
  const floor: FloorTape[] = [...crew.floor];
  let nextTape = crew.nextTape;
  let nextReading = crew.nextReading;
  // Factors as they stood at the start of the tick: everyone recording this tick gets the same one.
  const startRepeats = crew.repeats;
  const factorFor = (entityId: string, trait: Trait): number => repeatFactor(startRepeats[repeatKey(entityId, trait)] ?? 0);

  const finish = (m: CrewMember, open: OpenReading): CrewMember => {
    if (open.duration < READING_MIN_TIME - EPS) return m;
    const reading: Reading = {
      id: `reading-${nextReading++}`,
      playerId: m.id,
      entityId: open.entityId,
      trait: open.trait,
      value: open.value,
      duration: open.duration,
      peakRate: open.peakRate,
      closedAt: t,
    };
    const key = repeatKey(open.entityId, open.trait);
    repeats[key] = (repeats[key] ?? 0) + 1;
    events.push({ type: 'readingClosed', t, playerId: m.id, tapeId: m.tape.id, reading, value: reading.value });
    return { ...m, tape: addReading(m.tape, reading) };
  };

  const members: CrewMember[] = crew.members.map((old) => {
    const p = players.find((q) => q.id === old.id);
    let m: CrewMember = { ...old, body: p ? p.body : old.body, active: p ? p.active : false };
    if (!m.body) return m;
    const r = stepInstrument(plan, m.instrument, { body: m.body, active: m.active }, entities, factorFor, dt);
    m = { ...m, instrument: r.instrument };
    if (r.recordedFrom && !slips.includes(r.recordedFrom.trait)) {
      slips.push(r.recordedFrom.trait);
      events.push({ type: 'slip', t, playerId: m.id, entityId: r.recordedFrom.entityId, trait: r.recordedFrom.trait, text: SLIP_TEXT[r.recordedFrom.trait] });
    }
    for (const c of r.closed) m = finish(m, c);
    return m;
  });

  for (const e of entities) {
    for (const ev of e.events) {
      if (ev.type !== 'caught') continue;
      const i = members.findIndex((m) => m.id === ev.playerId);
      let m = members[i];
      if (!m) continue;
      const open = m.instrument.current;
      m = { ...m, instrument: { ...m.instrument, current: null, raised: false, needle: 'off', rate: 0, tickHz: 0, loudness: 0, tickPhase: 0 } };
      if (open) m = finish(m, open);
      const at = m.body;
      if (at) {
        for (const tape of [m.tape, ...m.carrying]) {
          if (tape.readings.length === 0) continue;
          floor.push({ tape, at });
          events.push({ type: 'tapeDropped', t, playerId: m.id, tapeId: tape.id, at });
        }
        m = { ...m, tape: emptyTape(`tape-${nextTape++}`, m.id), carrying: [] };
      }
      members[i] = m;
    }
  }

  return { crew: { t, members, floor, slipsPrinted: slips, repeats, nextTape, nextReading }, events };
}

export interface PickUp {
  crew: CrewState;
  ok: boolean;
  event: CrewEvent | null;
  reason: 'ok' | 'noPlayer' | 'inactive' | 'noTape' | 'tooFar';
}

/**
 * An active player picks up a tape lying on the floor, if it is within PICKUP_REACH of where they
 * stood at the last stepCrew. They can carry any number.
 */
export function pickUpTape(crew: CrewState, playerId: string, tapeId: string): PickUp {
  const fail = (reason: PickUp['reason']): PickUp => ({ crew, ok: false, event: null, reason });
  const m = member(crew, playerId);
  if (!m || !m.body) return fail('noPlayer');
  if (!m.active) return fail('inactive');
  const ft = crew.floor.find((f) => f.tape.id === tapeId);
  if (!ft) return fail('noTape');
  if (feetDistance(m.body, ft.at) > PICKUP_REACH + EPS) return fail('tooFar');
  const next: CrewState = {
    ...crew,
    floor: crew.floor.filter((f) => f !== ft),
    members: crew.members.map((x) => (x.id === playerId ? { ...x, carrying: [...x.carrying, ft.tape] } : x)),
  };
  return { crew: next, ok: true, event: { type: 'tapePickedUp', t: crew.t, playerId, tapeId }, reason: 'ok' };
}

export interface Departure {
  /** Tapes that leave with the crew (non-empty only). */
  carried: Tape[];
  /** Tapes left behind: on the floor, or held by someone not aboard. */
  lost: Tape[];
  carriedValue: number;
  lostValue: number;
}

/**
 * The elevator leaves. Everything held by a member who is aboard goes with it; everything on the
 * floor is lost. `aboard` defaults to every member (who boarded is the elevator's business).
 */
export function leaveFloor(crew: CrewState, aboard?: readonly string[]): Departure {
  const carried: Tape[] = [];
  const lost: Tape[] = crew.floor.map((f) => f.tape);
  for (const m of crew.members) {
    const held = [m.tape, ...m.carrying].filter((tp) => tp.readings.length > 0);
    if (!aboard || aboard.includes(m.id)) carried.push(...held);
    else lost.push(...held);
  }
  return { carried, lost, carriedValue: tapeValue(carried), lostValue: tapeValue(lost) };
}
