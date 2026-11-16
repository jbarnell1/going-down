// Runs the whole run (sim/run.ts) at a fixed 20 ticks a second from an accumulator, so it behaves the
// same at any frame rate. One stepRun per tick steps the run's rules, the Orderly and the crew's
// instruments in the order the logic requires. The players list holds only the local player today;
// the networking task adds the others.
//
// A glance that falls between two ticks still counts: when a rendered frame shows the figure, the
// caller hands over that frame's view with noteSeen(), and the next tick is given that view for that
// player if the player's current view would no longer see it. The logic then holds it, exactly as if
// the tick had landed on the frame.
//
// Work-arounds for gaps in the logic, kept here and visible (see the report):
//  - createRun always starts at depth 1. ?depth=N swaps in floor N's plan, car and Orderly at once.
//  - With one player, run.ts wipes the run on ANY catch. The design says a catch is a wipe only when
//    the car is gone and nobody can call it; while the car is here or coming, a catch is the "YOU WENT
//    DOWN" placeholder and the player must still be able to finish the run. So when a catch would wipe
//    and the car was not 'away', the host re-runs that tick without the caught player to recover the
//    run's own phase, call and blink, keeps the Orderly and crew from the real tick (the dropped tape,
//    the dormant Orderly), and puts the player back on their feet ('ok').
//  - ?entity=0: the run always has an Orderly. The host parks it, dormant for ever, where it starts.
//  - Picking up a tape is done at once with the logic's pickUpTape (as the old crew host did), so a
//    paused logic clock (tests) cannot swallow the key press.

import { createOrderly, HUNT_SPEED, ORDERLY_HEIGHT, ORDERLY_RADIUS, seenBy, type OrderlyEvent, type OrderlyState, type PlayerView } from '../sim/entity';
import { generateClinic } from '../sim/clinic';
import { member, pickUpTape, PICKUP_REACH, setRaised, tapeValue, type CrewEvent, type CrewMember } from '../sim/instrument';
import type { Body } from '../sim/move';
import { carBody, carGeometry, createRun, stepRun, type PlayerInput, type RunEvent, type RunState } from '../sim/run';
import { canSee } from '../sim/sight';

export const TICK_HZ = 20;
export const TICK = 1 / TICK_HZ;
/** At most this many ticks run in one frame; a long stall drops time instead of spiralling. */
const MAX_TICKS_PER_FRAME = 5;

const ORDERLY_EVENTS = new Set(['firstSeen', 'startedHunting', 'froze', 'released', 'windUp', 'windUpCancelled', 'caught']);
const CREW_EVENTS = new Set(['slip', 'readingClosed', 'tapeDropped', 'tapePickedUp']);

export function isOrderlyEvent(e: RunEvent): e is OrderlyEvent & RunEvent {
  return ORDERLY_EVENTS.has(e.type);
}
export function isCrewEvent(e: RunEvent): e is CrewEvent & RunEvent {
  return CREW_EVENTS.has(e.type);
}

export interface PickUpResult {
  ok: boolean;
  reason: string;
  tapeId: string | null;
}

/** A dormant Orderly that never wakes, standing where the floor's Orderly would start. */
function parkedOrderly(state: RunState): OrderlyState {
  return { ...createOrderly(state.plan), mode: 'dormant', dormantLeft: Number.POSITIVE_INFINITY };
}

/** Where the local player stands in the car at the start: the middle, so the doorway is straight ahead. */
export const START_U = 1.45;

export class RunHost {
  state: RunState;
  /** The run as it was before the last tick: the Orderly is smoothed between the two. */
  prevState: RunState;
  /** Every Orderly event, crew event and run event so far, oldest first. */
  readonly orderlyEvents: OrderlyEvent[] = [];
  readonly crewEvents: CrewEvent[] = [];
  readonly runEvents: RunEvent[] = [];
  /** Logic seconds per real second (tests may speed it up, slow it down or stop it). */
  timeScale = 1;
  ticks = 0;
  /** Walk-cycle clock after the tick before last and after the last tick (seconds at running pace). */
  prevStride = 0;
  curStride = 0;
  /** Catches the host turned from a wipe into the placeholder (see the header). */
  softCatches = 0;
  private acc = 0;
  private latched: PlayerView | null = null;

  constructor(
    readonly seed: string,
    readonly localId: string,
    private readonly entityOn: boolean,
    depth = 1,
  ) {
    this.state = this.fresh(depth);
    this.prevState = this.state;
  }

  private fresh(depth: number): RunState {
    let s = createRun(this.seed, [this.localId]);
    if (depth > 1) {
      // Gap: createRun has no depth. Floor `depth` as the run itself would build it on arrival.
      const plan = generateClinic(this.seed, depth);
      const car = carGeometry(plan);
      const body = carBody(car, START_U, 0);
      s = {
        ...s,
        depth,
        plan,
        car,
        orderly: createOrderly(plan),
        entityId: `orderly-${depth}`,
        players: s.players.map((p) => ({ ...p, body })),
        crew: { ...s.crew, members: s.crew.members.map((m) => ({ ...m, body })) },
      };
    }
    if (!this.entityOn) s = { ...s, orderly: parkedOrderly(s) };
    return s;
  }

  /** A new run on the same seed, from depth `depth`. Event logs are kept; the clock restarts. */
  restart(depth = 1): void {
    this.state = this.fresh(depth);
    this.prevState = this.state;
    this.acc = 0;
    this.latched = null;
    this.prevStride = this.curStride;
  }

  get orderly(): OrderlyState {
    return this.state.orderly;
  }

  get prevOrderly(): OrderlyState {
    return this.prevState.orderly;
  }

  /** How far between the last two ticks the present moment is, 0..1. */
  get alpha(): number {
    return Math.min(1, this.acc / TICK);
  }

  /** The stride clock between the last two ticks. */
  stride(alpha = this.alpha): number {
    return this.prevStride + (this.curStride - this.prevStride) * Math.min(1, Math.max(0, alpha));
  }

  /** Whether this view could see the figure where the logic has it now, judged exactly as the logic judges it. */
  sees(view: PlayerView): boolean {
    return view.active && canSee(this.state.plan, view, this.state.orderly.body, { height: ORDERLY_HEIGHT, radius: ORDERLY_RADIUS });
  }

  /** A rendered frame showed the figure: make sure the next tick counts it as seen. */
  noteSeen(view: PlayerView): void {
    if (this.sees(view)) this.latched = { ...view, body: { ...view.body } };
  }

  /** Replaces the Orderly outright (tests: place it, wake it). Both smoothing ends jump there. */
  replaceOrderly(o: OrderlyState): void {
    this.state = { ...this.state, orderly: o };
    this.prevState = { ...this.prevState, orderly: o };
    this.prevStride = this.curStride;
  }

  member(id = this.localId): CrewMember | undefined {
    return member(this.state.crew, id);
  }

  /** Everything a player holds: their own tape and the ones they picked up. */
  held(id = this.localId): number {
    const m = this.member(id);
    return m ? tapeValue([m.tape, ...m.carrying]) : 0;
  }

  /** How many tapes with something on them a player holds. */
  heldCount(id = this.localId): number {
    const m = this.member(id);
    return m ? [m.tape, ...m.carrying].filter((t) => t.readings.length > 0).length : 0;
  }

  /** The nearest floor tape within reach of `body`, or null. */
  tapeInReach(body: Body): { id: string; d: number } | null {
    let best: { id: string; d: number } | null = null;
    for (const f of this.state.crew.floor) {
      if (f.at.level !== body.level) continue;
      const d = Math.hypot(f.at.x - body.x, f.at.y - body.y, f.at.z - body.z);
      if (d <= PICKUP_REACH && (!best || d < best.d)) best = { id: f.tape.id, d };
    }
    return best;
  }

  /** Picks up the nearest tape in reach of where the player stands now (at once; see the header). */
  pickUp(body: Body): PickUpResult {
    const near = this.tapeInReach(body);
    if (!near) return { ok: false, reason: this.state.crew.floor.length ? 'tooFar' : 'noTape', tapeId: null };
    const crew = { ...this.state.crew, members: this.state.crew.members.map((m) => (m.id === this.localId ? { ...m, body: { ...body } } : m)) };
    const r = pickUpTape(crew, this.localId, near.id);
    this.state = { ...this.state, crew: r.crew };
    if (r.event) {
      const ev = { ...r.event, t: this.state.t };
      this.crewEvents.push(ev);
      this.runEvents.push(ev);
      this.pendingOut.push(ev);
    }
    return { ok: r.ok, reason: r.reason, tapeId: r.ok ? near.id : null };
  }

  /** Events produced outside advance() (pick-ups), handed out with the next advance(). */
  private pendingOut: RunEvent[] = [];

  /**
   * Advances real time `dt` seconds. `input` builds the local player's input for a tick (called once
   * per tick that runs). Returns every event of the ticks that ran.
   */
  advance(dt: number, input: () => PlayerInput, onTick?: (events: readonly RunEvent[]) => void): RunEvent[] {
    this.acc += Math.max(0, dt) * this.timeScale;
    const out: RunEvent[] = this.pendingOut;
    this.pendingOut = [];
    let n = 0;
    while (this.acc >= TICK && n < MAX_TICKS_PER_FRAME) {
      this.acc -= TICK;
      n++;
      const evs = this.tick(input());
      onTick?.(evs);
      out.push(...evs);
    }
    if (n === MAX_TICKS_PER_FRAME && this.acc >= TICK) this.acc = this.acc % TICK;
    return out;
  }

  /**
   * Runs `seconds` of logic at once, tick by tick through stepRun (tests: skip a wait). `onTick` runs
   * after every tick; returning true stops early.
   */
  skip(seconds: number, input: () => PlayerInput, onTick?: (events: readonly RunEvent[]) => boolean | void): RunEvent[] {
    const out: RunEvent[] = [];
    const n = Math.max(0, Math.round(seconds / TICK));
    for (let i = 0; i < n; i++) {
      const evs = this.tick(input());
      out.push(...evs);
      if (onTick?.(evs) === true) break;
    }
    return out;
  }

  /**
   * Raises or lowers the local instrument at once (the next tick's input says the same), so the walk
   * cap and the drawn instrument answer the key on this frame, as they did before the run.
   */
  setRaised(raised: boolean): void {
    const m = this.member();
    if (m && m.instrument.raised !== raised) this.state = { ...this.state, crew: setRaised(this.state.crew, this.localId, raised) };
  }

  /** One logic tick. */
  private tick(raw: PlayerInput): RunEvent[] {
    const before = this.state;
    let inp = raw;
    const snap = this.latched;
    this.latched = null;
    // (Not on a tick that presses the call button: a test may press it from the landing.)
    if (snap && !raw.call) {
      const view: PlayerView = { id: raw.id, active: true, body: raw.body, eye: raw.eye, yaw: raw.yaw, pitch: raw.pitch, hFovDeg: raw.hFovDeg, vFovDeg: raw.vFovDeg };
      // The current view already sees it: nothing to add. Otherwise use the frame that did.
      if (!seenBy(before.plan, before.orderly.body, [view])) inp = { ...raw, body: snap.body, eye: snap.eye, yaw: snap.yaw, pitch: snap.pitch, hFovDeg: snap.hFovDeg, vFovDeg: snap.vFovDeg };
    }
    let r = stepRun(before, [inp], TICK);
    let events = r.events;
    const caughtLocal = events.some((e) => e.type === 'caught' && e.playerId === this.localId);
    if (caughtLocal && events.some((e) => e.type === 'wiped') && before.phase !== 'away') {
      // Not a wipe by the design's rule: the car is here or coming. See the header.
      const alt = stepRun(before, [], TICK);
      const players = r.state.players.map((p) => (p.id === this.localId ? { ...p, status: 'ok' as const } : p));
      r = { state: { ...alt.state, orderly: r.state.orderly, crew: r.state.crew, players, summary: null }, events };
      events = events.filter((e) => e.type !== 'wiped');
      this.softCatches++;
    }
    let state = r.state;
    if (!this.entityOn && events.some((e) => e.type === 'rodeDown')) state = { ...state, orderly: parkedOrderly(state) };
    const floorChanged = state.plan !== before.plan;
    this.prevState = floorChanged ? state : before;
    this.state = state;
    this.prevStride = this.curStride;
    this.curStride += TICK * (state.orderly.speed / HUNT_SPEED);
    this.ticks++;
    for (const e of events) {
      this.runEvents.push(e);
      if (isOrderlyEvent(e)) this.orderlyEvents.push(e);
      else if (isCrewEvent(e)) this.crewEvents.push(e);
    }
    if (this.runEvents.length > 4000) this.runEvents.splice(0, 1000);
    return events;
  }
}
