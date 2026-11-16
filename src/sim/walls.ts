// What stands on each cell edge of a floor plan: nothing, an opening, a door, a wall or a rail.
// Collision (move.ts) and the renderer both read this, so what you see is what stops you.
//
// Derived strictly from canStep in floor.ts:
//   - an edge canStep allows is 'open', or 'door' when only a Door makes it passable;
//   - the top of a stair joins the last stair cell (level 0) to the cell beyond it (level 1). It is
//     'stairTop' on both levels: walkers pass through it, and the renderer closes it on level 0 only
//     (under the upper floor) because the climber is above that wall by the time they reach it;
//   - holes in the upper floor (atrium opening, stair shaft) are 'open' among themselves;
//   - an atrium opening beside upper corridor is a 'rail' (the balcony); everything else is 'wall'.

import { canStep, cellAt, DIR_VEC, hasDoor, roomIdAt, type CellKind, type FloorPlan, type Level } from './floor';

export type EdgeKind = 'none' | 'open' | 'door' | 'wall' | 'rail' | 'stairTop';

/** Width of a door opening in metres, centred on its cell edge. The rest of that edge is wall. */
export const DOOR_WIDTH = 1.1;

/** Whether (a, b) is the top of some stair: its last cell and the cell just beyond, either order. */
export function isStairTop(plan: FloorPlan, ax: number, ay: number, bx: number, by: number): boolean {
  for (const s of plan.stairs) {
    const v = DIR_VEC[s.dir];
    const ex = s.x + v.dx * (s.length - 1);
    const ey = s.y + v.dy * (s.length - 1);
    const tx = ex + v.dx;
    const ty = ey + v.dy;
    if ((ax === ex && ay === ey && bx === tx && by === ty) || (bx === ex && by === ey && ax === tx && ay === ty)) return true;
  }
  return false;
}

function isHole(k: CellKind, level: Level): boolean {
  return k === 'atriumOpen' || (k === 'stair' && level === 1);
}

/** The edge between two edge-adjacent cells on one level. */
export function edgeKind(plan: FloorPlan, level: Level, ax: number, ay: number, bx: number, by: number): EdgeKind {
  const ka = cellAt(plan, level, ax, ay);
  const kb = cellAt(plan, level, bx, by);
  if (ka === 'void' && kb === 'void') return 'none';
  if (isStairTop(plan, ax, ay, bx, by)) return 'stairTop';
  const a = { level, x: ax, y: ay };
  const b = { level, x: bx, y: by };
  if (canStep(plan, a, b)) {
    const ra = roomIdAt(plan, level, ax, ay);
    const sameRoom = ra >= 0 && ra === roomIdAt(plan, level, bx, by);
    const bothCorridor = ka === 'corridor' && kb === 'corridor';
    if (!sameRoom && !bothCorridor && hasDoor(plan, level, ax, ay, bx, by)) return 'door';
    return 'open';
  }
  if (isHole(ka, level) && isHole(kb, level)) return ka === kb ? 'open' : 'wall';
  if ((ka === 'atriumOpen' && kb === 'corridor') || (kb === 'atriumOpen' && ka === 'corridor')) return 'rail';
  return 'wall';
}

// ---------------------------------------------------------------------------------------------
// Edge tables, cached per plan: collision asks for the same edges many times a second.

interface EdgeTable {
  /** Edge between (x-1, y) and (x, y), index y*(w+1)+x, for x in [0, w]. */
  vertical: EdgeKind[];
  /** Edge between (x, y-1) and (x, y), index y*w+x, for y in [0, h]. */
  horizontal: EdgeKind[];
}

const tableCache = new WeakMap<FloorPlan, [EdgeTable, EdgeTable]>();

function tables(plan: FloorPlan): [EdgeTable, EdgeTable] {
  const cached = tableCache.get(plan);
  if (cached) return cached;
  const w = plan.width;
  const h = plan.height;
  const build = (level: Level): EdgeTable => {
    const vertical: EdgeKind[] = [];
    for (let y = 0; y < h; y++) for (let x = 0; x <= w; x++) vertical.push(edgeKind(plan, level, x - 1, y, x, y));
    const horizontal: EdgeKind[] = [];
    for (let y = 0; y <= h; y++) for (let x = 0; x < w; x++) horizontal.push(edgeKind(plan, level, x, y - 1, x, y));
    return { vertical, horizontal };
  };
  const t: [EdgeTable, EdgeTable] = [build(0), build(1)];
  tableCache.set(plan, t);
  return t;
}

/** Edge on the west side of cell (x, y). Out of range reads as 'none'. */
export function westEdge(plan: FloorPlan, level: Level, x: number, y: number): EdgeKind {
  if (y < 0 || y >= plan.height || x < 0 || x > plan.width) return 'none';
  return tables(plan)[level].vertical[y * (plan.width + 1) + x] ?? 'none';
}

/** Edge on the north side of cell (x, y). Out of range reads as 'none'. */
export function northEdge(plan: FloorPlan, level: Level, x: number, y: number): EdgeKind {
  if (x < 0 || x >= plan.width || y < 0 || y > plan.height) return 'none';
  return tables(plan)[level].horizontal[y * plan.width + x] ?? 'none';
}

// ---------------------------------------------------------------------------------------------
// Collision segments.

/** A solid line segment in metres on the horizontal plane (x, z). */
export interface Segment {
  ax: number;
  az: number;
  bx: number;
  bz: number;
}

/** The solid parts of an edge from (x0, z0) to (x1, z1) for a walker. */
function solidParts(kind: EdgeKind, x0: number, z0: number, x1: number, z1: number, out: Segment[]): void {
  if (kind === 'wall' || kind === 'rail') {
    out.push({ ax: x0, az: z0, bx: x1, bz: z1 });
  } else if (kind === 'door') {
    const len = Math.hypot(x1 - x0, z1 - z0);
    const f = (len - DOOR_WIDTH) / 2 / len;
    out.push({ ax: x0, az: z0, bx: x0 + (x1 - x0) * f, bz: z0 + (z1 - z0) * f });
    out.push({ ax: x1 - (x1 - x0) * f, az: z1 - (z1 - z0) * f, bx: x1, bz: z1 });
  }
}

/**
 * Every solid segment on the edges of the 3x3 cells around (cx, cy). That covers anything within
 * one cell of a point inside (cx, cy), which is more than any walker's radius.
 */
export function segmentsNear(plan: FloorPlan, level: Level, cx: number, cy: number): Segment[] {
  const s = plan.cellSize;
  const out: Segment[] = [];
  for (let y = cy - 1; y <= cy + 1; y++) {
    for (let x = cx - 1; x <= cx + 2; x++) solidParts(westEdge(plan, level, x, y), x * s, y * s, x * s, (y + 1) * s, out);
  }
  for (let y = cy - 1; y <= cy + 2; y++) {
    for (let x = cx - 1; x <= cx + 1; x++) solidParts(northEdge(plan, level, x, y), x * s, y * s, (x + 1) * s, y * s, out);
  }
  return out;
}
