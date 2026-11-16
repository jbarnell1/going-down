// Auto-walk for tests and demos: follows findPath with the real collision code, at a fixed step,
// several steps per frame so a test does not wait out real walking time.

import { findPath, type FloorPlan, type Pos } from '../sim/floor';
import { pathDone, startPathWalk, stepPathWalk, type PathWalk } from '../sim/follow';
import { cellOf } from '../sim/move';
import { PLAYER_RADIUS, WALK_SPEED, yawToward, type Player } from './player';

const STEP_DT = 1 / 60;
const STEPS_PER_FRAME = 10;
/** Give up after this many fixed steps without getting closer to the next waypoint. */
const STUCK_STEPS = 240;

export class AutoWalk {
  private walk: PathWalk | null = null;
  private resolve: (() => void) | null = null;
  private reject: ((e: Error) => void) | null = null;
  private stuck = 0;

  get active(): boolean {
    return this.walk !== null;
  }

  start(plan: FloorPlan, player: Player, to: Pos): Promise<void> {
    this.cancel('replaced by a new walk');
    const from = cellOf(plan, player.body);
    const path = findPath(plan, from, to);
    if (!path) return Promise.reject(new Error(`no path from L${from.level}(${from.x},${from.y}) to L${to.level}(${to.x},${to.y})`));
    this.walk = startPathWalk(path);
    this.stuck = 0;
    return new Promise<void>((res, rej) => {
      this.resolve = res;
      this.reject = rej;
    });
  }

  cancel(reason: string): void {
    if (this.reject) this.reject(new Error(reason));
    this.walk = null;
    this.resolve = null;
    this.reject = null;
  }

  /** Advances the walk by one frame's worth of fixed steps. */
  tick(plan: FloorPlan, player: Player): void {
    const walk = this.walk;
    if (!walk) return;
    for (let i = 0; i < STEPS_PER_FRAME; i++) {
      if (pathDone(plan, walk, player.body)) {
        const res = this.resolve;
        this.walk = null;
        this.resolve = null;
        this.reject = null;
        res?.();
        return;
      }
      const before = player.body;
      player.body = stepPathWalk(plan, walk, before, WALK_SPEED * STEP_DT, PLAYER_RADIUS);
      const mx = player.body.x - before.x;
      const mz = player.body.z - before.z;
      if (Math.hypot(mx, mz) > 1e-4) {
        player.yaw = yawToward(mx, mz);
        this.stuck = 0;
      } else if (++this.stuck > STUCK_STEPS) {
        const c = cellOf(plan, player.body);
        this.cancel(`auto-walk stuck at L${c.level}(${c.x},${c.y})`);
        return;
      }
    }
  }
}
