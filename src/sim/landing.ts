// Where the elevator is at the landing, and which way a player faces stepping out of it.

import { DIR_VEC, isWalkable, type Dir, type FloorPlan } from './floor';
import { edgeKind } from './walls';

const DIRS: readonly Dir[] = ['n', 'e', 's', 'w'];

/**
 * The side of the landing cell the elevator doors are on: a walled side whose opposite side opens
 * into the floor, so stepping out of the elevator walks you straight in. Null if no side is walled.
 */
export function elevatorWall(plan: FloorPlan): Dir | null {
  const { level, x, y } = plan.landing;
  let fallback: Dir | null = null;
  for (const d of DIRS) {
    const v = DIR_VEC[d];
    if (edgeKind(plan, level, x, y, x + v.dx, y + v.dy) !== 'wall') continue;
    fallback ??= d;
    if (isWalkable(plan, level, x - v.dx, y - v.dy)) return d;
  }
  return fallback;
}

/** The direction a player faces stepping out of the elevator. */
export function landingFacing(plan: FloorPlan): Dir {
  const wall = elevatorWall(plan);
  const opposite: Record<Dir, Dir> = { n: 's', e: 'w', s: 'n', w: 'e' };
  return wall ? opposite[wall] : 'n';
}
