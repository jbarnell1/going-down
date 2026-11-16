// Runs the crew's instrument logic (sim/instrument.ts) beside the Orderly. The entity host calls
// tick() once per logic tick, AFTER the Orderly has been stepped, with every player's body; with no
// Orderly on the floor (?entity=0) advanceAlone() runs the same ticks against an empty list. The
// players list holds only the local player today; the networking task adds the others.

import { createCrew, member, pickUpTape, PICKUP_REACH, setRaised, stepCrew, tapeValue, type CrewEvent, type CrewMember, type CrewPlayer, type CrewState, type EntityTick } from '../sim/instrument';
import type { FloorPlan } from '../sim/floor';
import type { Body } from '../sim/move';
import { TICK } from './entityHost';

export interface PickUpResult {
  ok: boolean;
  reason: string;
  tapeId: string | null;
}

export class CrewHost {
  crew: CrewState;
  /** Every crew event so far, oldest first. */
  readonly events: CrewEvent[] = [];
  /** Events not yet taken by the frame loop (sound, slip, display). */
  private pending: CrewEvent[] = [];
  private acc = 0;

  constructor(private readonly plan: FloorPlan, playerIds: readonly string[]) {
    this.crew = createCrew(playerIds);
  }

  member(id: string): CrewMember | undefined {
    return member(this.crew, id);
  }

  /** Raises or lowers a player's instrument (a no-op when it already is). */
  setRaised(id: string, raised: boolean): void {
    const m = this.member(id);
    if (m && m.instrument.raised !== raised) this.crew = setRaised(this.crew, id, raised);
  }

  /** One logic tick, after the entities have been stepped. */
  tick(players: readonly CrewPlayer[], entities: readonly EntityTick[], dt = TICK): void {
    const r = stepCrew(this.plan, this.crew, players, entities, dt);
    this.crew = r.crew;
    for (const e of r.events) {
      this.events.push(e);
      this.pending.push(e);
    }
  }

  /** With no entity host: runs the same fixed ticks with no entities. */
  advanceAlone(dt: number, players: readonly CrewPlayer[]): void {
    this.acc += Math.max(0, dt);
    let n = 0;
    while (this.acc >= TICK && n < 5) {
      this.acc -= TICK;
      n++;
      this.tick(players, []);
    }
    if (n === 5 && this.acc >= TICK) this.acc %= TICK;
  }

  /** Events since the last call. */
  take(): CrewEvent[] {
    const out = this.pending;
    this.pending = [];
    return out;
  }

  /** Everything a player holds: their own tape and the ones they picked up. */
  held(id: string): number {
    const m = this.member(id);
    return m ? tapeValue([m.tape, ...m.carrying]) : 0;
  }

  /** How many tapes with something on them a player holds. */
  heldCount(id: string): number {
    const m = this.member(id);
    return m ? [m.tape, ...m.carrying].filter((t) => t.readings.length > 0).length : 0;
  }

  /** The nearest floor tape within reach of `body`, or null. */
  tapeInReach(body: Body): { id: string; d: number } | null {
    let best: { id: string; d: number } | null = null;
    for (const f of this.crew.floor) {
      const d = Math.hypot(f.at.x - body.x, f.at.y - body.y, f.at.z - body.z);
      if (d <= PICKUP_REACH && (!best || d < best.d)) best = { id: f.tape.id, d };
    }
    return best;
  }

  /**
   * A player picks up the nearest tape in reach of where they stand now. The logic judges reach from
   * where it last saw them, so their body is brought up to date first (it may be paused, in tests).
   */
  pickUp(id: string, body: Body): PickUpResult {
    const near = this.tapeInReach(body);
    if (!near) return { ok: false, reason: this.crew.floor.length ? 'tooFar' : 'noTape', tapeId: null };
    this.crew = { ...this.crew, members: this.crew.members.map((m) => (m.id === id ? { ...m, body: { ...body } } : m)) };
    const r = pickUpTape(this.crew, id, near.id);
    this.crew = r.crew;
    if (r.event) {
      this.events.push(r.event);
      this.pending.push(r.event);
    }
    return { ok: r.ok, reason: r.reason, tapeId: r.ok ? near.id : null };
  }
}
