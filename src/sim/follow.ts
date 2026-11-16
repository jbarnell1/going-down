// Walking a findPath route with real collision: aim at the centre of the next cell, move, repeat.
// Used by the auto-walk test hook now and by bots and entities later.

import type { FloorPlan, Pos } from './floor';
import { cellOf, moveWithCollision, type Body } from './move';

export interface PathWalk {
  path: Pos[];
  /** Index of the waypoint being walked to. */
  next: number;
}

/** How close to a waypoint's centre counts as reached. Small, so corners are turned square. */
const REACHED = 0.08;

export function startPathWalk(path: Pos[]): PathWalk {
  return { path, next: path.length > 1 ? 1 : 0 };
}

/** True once the body stands at the centre of the last cell of the path. */
export function pathDone(plan: FloorPlan, walk: PathWalk, body: Body): boolean {
  const last = walk.path[walk.path.length - 1];
  if (!last || walk.next < walk.path.length - 1) return false;
  const c = cellOf(plan, body);
  const s = plan.cellSize;
  return c.level === last.level && c.x === last.x && c.y === last.y && Math.hypot(body.x - (last.x + 0.5) * s, body.z - (last.y + 0.5) * s) <= REACHED;
}

/** Moves the body up to `maxDist` metres along the path. Returns the new body. */
export function stepPathWalk(plan: FloorPlan, walk: PathWalk, body: Body, maxDist: number, radius: number): Body {
  const s = plan.cellSize;
  let cur = body;
  let budget = maxDist;
  while (budget > 1e-9) {
    const wp = walk.path[walk.next];
    if (!wp) break;
    const tx = (wp.x + 0.5) * s;
    const tz = (wp.y + 0.5) * s;
    const d = Math.hypot(tx - cur.x, tz - cur.z);
    const c = cellOf(plan, cur);
    if (d <= REACHED && c.x === wp.x && c.y === wp.y && c.level === wp.level) {
      if (walk.next >= walk.path.length - 1) break;
      walk.next++;
      continue;
    }
    const step = Math.min(budget, d);
    const moved = moveWithCollision(plan, cur, ((tx - cur.x) / d) * step, ((tz - cur.z) / d) * step, radius);
    const progress = Math.hypot(moved.x - cur.x, moved.z - cur.z);
    cur = moved;
    budget -= step;
    if (progress < 1e-6) break; // blocked; the caller decides when to give up
  }
  return cur;
}
