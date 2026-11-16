// The game's own rules around the run, applied by the host (src/net/host.ts steps the run through
// these). The run itself (sim/run.ts) is stepped 20 times a second by NetHost, for one player or
// four, the same way; this file holds only what the logic does not do yet. Work-arounds for gaps in
// the logic, kept here and visible (see the report):
//  - createRun always starts at depth 1. ?depth=N swaps in floor N's plan, car and Orderly at once.
//  - run.ts wipes the run when its last active player is caught. The design says a catch is a wipe
//    only when the car is gone and nobody can call it; while the car is here or coming, a catch is
//    the "YOU WENT DOWN" placeholder and the player must still be able to finish the run. So when a
//    catch would wipe and the car was not 'away', the tick is re-run without the caught players to
//    recover the run's own phase, call and blink, the Orderly and crew are kept from the real tick
//    (the dropped tape, the dormant Orderly), and the players are put back on their feet ('ok').
//  - ?entity=0: the run always has an Orderly. The host parks it, dormant for ever, where it starts.
//  - A test may press the call button "from the landing" wherever the player stands.

import { createOrderly, type OrderlyEvent, type OrderlyState } from '../sim/entity';
import { generateClinic } from '../sim/clinic';
import type { CrewEvent } from '../sim/instrument';
import type { Body } from '../sim/move';
import { carBody, carGeometry, stepRun, type CarGeometry, type PlayerInput, type RunEvent, type RunState, type RunStep } from '../sim/run';

const ORDERLY_EVENTS = new Set(['firstSeen', 'startedHunting', 'froze', 'released', 'windUp', 'windUpCancelled', 'caught']);
const CREW_EVENTS = new Set(['slip', 'readingClosed', 'tapeDropped', 'tapePickedUp']);

export function isOrderlyEvent(e: RunEvent): e is OrderlyEvent & RunEvent {
  return ORDERLY_EVENTS.has(e.type);
}
export function isCrewEvent(e: RunEvent): e is CrewEvent & RunEvent {
  return CREW_EVENTS.has(e.type);
}

/** Where a player stands alone in the car at the start: the middle, so the doorway is straight ahead. */
export const START_U = 1.45;

/** Where player `i` of `n` stands in the car at the start (car-local u, v). */
export function startSpot(i: number, n: number): [number, number] {
  if (n <= 1) return [START_U, 0];
  const spots: [number, number][] = [
    [1.0, -0.45],
    [1.0, 0.45],
    [1.6, -0.45],
    [1.6, 0.45],
  ];
  return spots[i % spots.length] ?? [START_U, 0];
}

export function startBody(car: CarGeometry, i: number, n: number): Body {
  const [u, v] = startSpot(i, n);
  return carBody(car, u, v);
}

/** A dormant Orderly that never wakes, standing where the floor's Orderly would start. */
function parkedOrderly(state: RunState): OrderlyState {
  return { ...createOrderly(state.plan), mode: 'dormant', dormantLeft: Number.POSITIVE_INFINITY };
}

export class HostRules {
  /** Catches turned from a wipe into the placeholder (see the header). */
  softCatches = 0;
  /** Players put back on their feet since the glue last asked. */
  revived: string[] = [];
  private forced: { id: string; body: Body } | null = null;

  constructor(
    private readonly entityOn: boolean,
    private readonly depth: number,
  ) {}

  /** The first state of a run (createRun's, adjusted). */
  readonly prepare = (s0: RunState): RunState => {
    let s = s0;
    if (this.depth > 1) {
      // Gap: createRun has no depth. Floor `depth` as the run itself would build it on arrival.
      const plan = generateClinic(s.seed, this.depth);
      s = { ...s, depth: this.depth, plan, car: carGeometry(plan), orderly: createOrderly(plan), entityId: `orderly-${this.depth}` };
    }
    const n = s.players.length;
    const bodies = new Map(s.players.map((p, i) => [p.id, startBody(s.car, i, n)]));
    s = { ...s, players: s.players.map((p) => ({ ...p, body: bodies.get(p.id) ?? p.body })) };
    if (this.depth > 1) s = { ...s, crew: { ...s.crew, members: s.crew.members.map((m) => ({ ...m, body: bodies.get(m.id) ?? null })) } };
    if (!this.entityOn) s = { ...s, orderly: parkedOrderly(s) };
    return s;
  };

  /** Tests: the next tick presses the call button for `id` from `body`. */
  forceCall(id: string, body: Body): void {
    this.forced = { id, body };
  }

  /** One tick of the run, with the rules above. */
  readonly step = (before: RunState, raw: readonly PlayerInput[], dt: number): RunStep => {
    let inputs = raw;
    const f = this.forced;
    if (f) {
      this.forced = null;
      inputs = raw.map((i) => (i.id === f.id ? { ...i, body: { ...f.body }, call: true } : i));
    }
    let r = stepRun(before, inputs, dt);
    let events = r.events;
    const caught = new Set(events.filter((e) => e.type === 'caught').map((e) => (e as { playerId: string }).playerId));
    if (caught.size > 0 && events.some((e) => e.type === 'wiped') && before.phase !== 'away') {
      // Not a wipe by the design's rule: the car is here or coming. See the header.
      const alt = stepRun(before, inputs.filter((i) => !caught.has(i.id)), dt);
      const players = r.state.players.map((p) => (caught.has(p.id) ? { ...p, status: 'ok' as const } : p));
      r = { state: { ...alt.state, orderly: r.state.orderly, crew: r.state.crew, players, summary: null }, events };
      events = events.filter((e) => e.type !== 'wiped');
      r = { ...r, events };
      this.softCatches++;
      this.revived.push(...caught);
    }
    let state = r.state;
    if (!this.entityOn && events.some((e) => e.type === 'rodeDown')) state = { ...state, orderly: parkedOrderly(state) };
    return { state, events };
  };
}
