// Runs the Orderly's logic (sim/entity.ts) at a fixed 20 ticks a second from an accumulator, so it
// behaves the same at any frame rate. The players list is passed in each frame; today it holds only
// the local player, and the networking task adds the others to the same list.
//
// A glance that falls between two ticks still counts: when a rendered frame shows the figure, the
// caller hands over that frame's view with noteSeen(), and the next tick is given that view for that
// player if the player's current view would no longer see it. The logic then holds it, exactly as if
// the tick had landed on the frame.
//
// After each tick the onTick hook runs (the crew's instruments are stepped there, after the Orderly,
// as the instrument logic requires). The host also keeps a stride clock: seconds of walk cycle, which
// advance with the logic's speed, so a slow creep is drawn as a slow stride and a run as a fast one.

import { createOrderly, HUNT_SPEED, ORDERLY_HEIGHT, ORDERLY_RADIUS, seenBy, stepEntity, type OrderlyEvent, type OrderlyState, type PlayerView } from '../sim/entity';
import type { FloorPlan } from '../sim/floor';
import { canSee } from '../sim/sight';

export const TICK_HZ = 20;
export const TICK = 1 / TICK_HZ;
/** At most this many ticks run in one frame; a long stall drops time instead of spiralling. */
const MAX_TICKS_PER_FRAME = 5;

export class EntityHost {
  /** State after the tick before last, and after the last tick: the view smooths between them. */
  prev: OrderlyState;
  cur: OrderlyState;
  /** Every event so far, oldest first. */
  readonly events: OrderlyEvent[] = [];
  /** Logic seconds per real second (tests may speed it up or slow it down). */
  timeScale = 1;
  /** Ticks run so far. */
  ticks = 0;
  /** Walk-cycle clock after the tick before last and after the last tick (seconds at running pace). */
  prevStride = 0;
  curStride = 0;
  /** Called after every tick with the states either side of it, its events and the players given to it. */
  onTick: ((prev: OrderlyState, cur: OrderlyState, events: readonly OrderlyEvent[], players: readonly PlayerView[]) => void) | null = null;
  private acc = 0;
  private readonly latched = new Map<string, PlayerView>();

  constructor(private readonly plan: FloorPlan, start: OrderlyState = createOrderly(plan)) {
    this.prev = start;
    this.cur = start;
  }

  /** How far between the last two ticks the present moment is, 0..1. */
  get alpha(): number {
    return Math.min(1, this.acc / TICK);
  }

  /** Whether this view could see the figure where the logic has it now, judged exactly as the logic judges it. */
  sees(view: PlayerView): boolean {
    return view.active && canSee(this.plan, view, this.cur.body, { height: ORDERLY_HEIGHT, radius: ORDERLY_RADIUS });
  }

  /** A rendered frame showed the figure to this player: make sure the next tick counts it as seen. */
  noteSeen(view: PlayerView): void {
    if (this.sees(view)) this.latched.set(view.id, { ...view, body: { ...view.body } });
  }

  /** Replaces the state outright (tests: place it, wake it). Both smoothing ends jump there. */
  replace(state: OrderlyState): void {
    this.prev = state;
    this.cur = state;
    this.prevStride = this.curStride;
  }

  /** The stride clock between the last two ticks. */
  stride(alpha = this.alpha): number {
    return this.prevStride + (this.curStride - this.prevStride) * Math.min(1, Math.max(0, alpha));
  }

  /** Advances real time `dt` seconds. Returns the events of the ticks that ran. */
  advance(dt: number, players: readonly PlayerView[]): OrderlyEvent[] {
    this.acc += Math.max(0, dt) * this.timeScale;
    const out: OrderlyEvent[] = [];
    let n = 0;
    while (this.acc >= TICK && n < MAX_TICKS_PER_FRAME) {
      this.acc -= TICK;
      n++;
      const views = players.map((p) => {
        const snap = this.latched.get(p.id);
        if (!snap) return p;
        // The current view already sees it: nothing to add. Otherwise use the frame that did.
        return seenBy(this.plan, this.cur.body, [p]) ? p : { ...snap, active: p.active };
      });
      this.latched.clear();
      const r = stepEntity(this.plan, this.cur, views, TICK);
      this.prev = this.cur;
      this.cur = r.state;
      this.prevStride = this.curStride;
      this.curStride += TICK * (r.state.speed / HUNT_SPEED);
      this.ticks++;
      for (const e of r.events) {
        this.events.push(e);
        out.push(e);
      }
      this.onTick?.(this.prev, this.cur, r.events, players);
    }
    if (n === MAX_TICKS_PER_FRAME && this.acc >= TICK) this.acc = this.acc % TICK;
    return out;
  }
}
