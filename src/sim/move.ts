// Continuous movement through a floor plan: a circle sliding along walls, climbing stairs and
// changing level exactly where canStep allows. Shared by the local player, bots and entities, so it
// knows nothing about rendering.
//
// A body is a point on the floor with a radius. Its cell is the 2 m cell under its centre and its
// level follows floor.ts: a body on a stair is on level 0 until its centre crosses the top edge.

import { canStep, cellAt, DIR_VEC, isWalkable, type FloorPlan, type Level, type Pos, type Stair } from './floor';
import { segmentsNear, type Segment } from './walls';

/** Height of one storey in metres: level 1's floor is this far above level 0's. */
export const LEVEL_HEIGHT = 3.2;

export interface Body {
  /** Horizontal position in metres: cell (cx, cy) covers x in [cx*2, cx*2+2), z in [cy*2, cy*2+2). */
  x: number;
  z: number;
  level: Level;
  /** Height of the feet in metres. */
  y: number;
}

/** The plan cell under a body's centre. */
export function cellOf(plan: FloorPlan, b: { x: number; z: number; level: Level }): Pos {
  return { level: b.level, x: Math.floor(b.x / plan.cellSize), y: Math.floor(b.z / plan.cellSize) };
}

/** A body standing in the centre of a cell. */
export function bodyAtCell(plan: FloorPlan, pos: Pos): Body {
  const x = (pos.x + 0.5) * plan.cellSize;
  const z = (pos.y + 0.5) * plan.cellSize;
  return { x, z, level: pos.level, y: feetHeight(plan, pos.level, x, z) };
}

function stairUnder(plan: FloorPlan, cx: number, cy: number): Stair | undefined {
  return plan.stairs.find((s) => {
    const v = DIR_VEC[s.dir];
    for (let i = 0; i < s.length; i++) if (s.x + v.dx * i === cx && s.y + v.dy * i === cy) return true;
    return false;
  });
}

/** Height of the feet at a point: a straight ramp from the stair's bottom edge to its top edge. */
export function feetHeight(plan: FloorPlan, level: Level, x: number, z: number): number {
  if (level === 1) return LEVEL_HEIGHT;
  const s = plan.cellSize;
  const cx = Math.floor(x / s);
  const cy = Math.floor(z / s);
  if (cellAt(plan, 0, cx, cy) !== 'stair') return 0;
  const stair = stairUnder(plan, cx, cy);
  if (!stair) return 0;
  const v = DIR_VEC[stair.dir];
  const bx = (stair.x + 0.5) * s - (v.dx * s) / 2;
  const bz = (stair.y + 0.5) * s - (v.dy * s) / 2;
  const along = (x - bx) * v.dx + (z - bz) * v.dy;
  const t = Math.min(1, Math.max(0, along / (stair.length * s)));
  return t * LEVEL_HEIGHT;
}

/**
 * The level a walker ends up on after moving from cell `from` into the adjacent (or diagonal) cell
 * (cx, cy), or null if canStep forbids it. A diagonal move is allowed when it could be made as two
 * legal orthogonal steps through either corner cell.
 */
function levelAfterStep(plan: FloorPlan, from: Pos, cx: number, cy: number): Level | null {
  const dx = cx - from.x;
  const dy = cy - from.y;
  const levels = (l: Level): Level[] => [l, l === 0 ? 1 : 0];
  if (Math.abs(dx) + Math.abs(dy) === 1) {
    for (const l of levels(from.level)) if (canStep(plan, from, { level: l, x: cx, y: cy })) return l;
    return null;
  }
  if (Math.abs(dx) === 1 && Math.abs(dy) === 1) {
    for (const [mx, my] of [[cx, from.y], [from.x, cy]] as const) {
      for (const lm of levels(from.level)) {
        const mid: Pos = { level: lm, x: mx, y: my };
        if (!canStep(plan, from, mid)) continue;
        for (const ln of levels(lm)) if (canStep(plan, mid, { level: ln, x: cx, y: cy })) return ln;
      }
    }
  }
  return null;
}

function closestOnSegment(px: number, pz: number, g: Segment): [number, number] {
  const ex = g.bx - g.ax;
  const ez = g.bz - g.az;
  const len2 = ex * ex + ez * ez;
  const t = len2 > 0 ? Math.min(1, Math.max(0, ((px - g.ax) * ex + (pz - g.az) * ez) / len2)) : 0;
  return [g.ax + ex * t, g.az + ez * t];
}

/** Distance from a point to the nearest solid segment on a level (Infinity if none is near). */
export function wallClearance(plan: FloorPlan, level: Level, x: number, z: number): number {
  const s = plan.cellSize;
  let best = Number.POSITIVE_INFINITY;
  for (const g of segmentsNear(plan, level, Math.floor(x / s), Math.floor(z / s))) {
    const [qx, qz] = closestOnSegment(x, z, g);
    best = Math.min(best, Math.hypot(x - qx, z - qz));
  }
  return best;
}

/** Pushes a circle out of every segment it overlaps. A few passes settle corners. */
function pushOut(plan: FloorPlan, level: Level, x: number, z: number, r: number, fromX: number, fromZ: number): [number, number] {
  const s = plan.cellSize;
  for (let pass = 0; pass < 4; pass++) {
    let moved = false;
    for (const g of segmentsNear(plan, level, Math.floor(x / s), Math.floor(z / s))) {
      const [qx, qz] = closestOnSegment(x, z, g);
      let nx = x - qx;
      let nz = z - qz;
      let d = Math.hypot(nx, nz);
      if (d >= r) continue;
      if (d < 1e-9) {
        // Exactly on the line: push back towards where we came from.
        nx = fromX - qx;
        nz = fromZ - qz;
        d = Math.hypot(nx, nz);
        if (d < 1e-9) return [fromX, fromZ];
      }
      x = qx + (nx / d) * r;
      z = qz + (nz / d) * r;
      moved = true;
    }
    if (!moved) break;
  }
  return [x, z];
}

const CLEARANCE_SLACK = 1e-6;

/** One small step, or null if it would end somewhere illegal. */
function tryStep(plan: FloorPlan, cur: Body, sx: number, sz: number, r: number): Body | null {
  if (sx === 0 && sz === 0) return null;
  const from = cellOf(plan, cur);
  let [x, z] = pushOut(plan, cur.level, cur.x + sx, cur.z + sz, r, cur.x, cur.z);
  const s = plan.cellSize;
  let cx = Math.floor(x / s);
  let cy = Math.floor(z / s);
  let level: Level = cur.level;
  if (cx !== from.x || cy !== from.y) {
    const l = levelAfterStep(plan, from, cx, cy);
    if (l === null) return null;
    level = l;
    if (level !== cur.level) {
      // Crossing the top of a stair: settle against the new level's walls too.
      [x, z] = pushOut(plan, level, x, z, r, cur.x, cur.z);
      if (Math.floor(x / s) !== cx || Math.floor(z / s) !== cy) return null;
    }
  }
  cx = Math.floor(x / s);
  cy = Math.floor(z / s);
  if (!isWalkable(plan, level, cx, cy)) return null;
  if (wallClearance(plan, level, x, z) < r - CLEARANCE_SLACK) return null;
  return { x, z, level, y: feetHeight(plan, level, x, z) };
}

/**
 * Moves a body by (dx, dz) metres, sliding along walls, climbing stairs and changing level at the
 * top. Never ends inside a wall or outside walkable space: a step that would is dropped, then
 * retried along each axis alone, so a walker pressed into a corner still slides where it can.
 */
export function moveWithCollision(plan: FloorPlan, body: Body, dx: number, dz: number, radius: number): Body {
  const dist = Math.hypot(dx, dz);
  if (dist === 0) return body;
  // Steps shorter than half the radius cannot tunnel through a zero-thickness wall.
  const maxStep = Math.min(0.1, radius * 0.5);
  const n = Math.max(1, Math.ceil(dist / maxStep));
  const sx = dx / n;
  const sz = dz / n;
  let cur = body;
  for (let i = 0; i < n; i++) {
    const next = tryStep(plan, cur, sx, sz, radius) ?? tryStep(plan, cur, sx, 0, radius) ?? tryStep(plan, cur, 0, sz, radius);
    if (!next) break;
    cur = next;
  }
  return cur;
}
