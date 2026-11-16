// The shell of a floor: floor slabs, ceilings, walls with door gaps and lintels, ceiling lights.
// Walls come from walls.ts edgeKind, the same table collision uses.
//
// Walls are zero-thickness: each solid edge gets one face per non-empty side, back to back, so
// corners meet exactly with no cracks. Door frames (fixtures.ts) give the openings visible depth.

import { cellAt, isWalkable, type CellKind, type FloorPlan, type Level } from '../sim/floor';
import { LEVEL_HEIGHT } from '../sim/move';
import { DOOR_WIDTH, northEdge, westEdge, type EdgeKind } from '../sim/walls';
import { GeoBuilder, type RGB } from './geoBuilder';
import { areaAt, floorColour, scale, wallColour } from './palette';

export const DOOR_HEIGHT = 2.1;

export interface StructureGeometry {
  floors: GeoBuilder;
  walls: GeoBuilder;
  ceilings: GeoBuilder;
  lights: GeoBuilder;
}

/** Holes in the upper floor: you see down through these, and no ceiling is hung beneath them. */
function isHoleAbove(plan: FloorPlan, x: number, y: number): boolean {
  const k = cellAt(plan, 1, x, y);
  return k === 'atriumOpen' || k === 'stair';
}

/** Cells that get a ceiling on their level. */
function hasCeiling(plan: FloorPlan, level: Level, x: number, y: number): boolean {
  const k: CellKind = cellAt(plan, level, x, y);
  if (k === 'void') return false;
  return level === 1 || !isHoleAbove(plan, x, y);
}

/** Wall faces are darker near the floor: a cheap stand-in for ambient occlusion. */
function shade(c: RGB, yRel: number): RGB {
  return scale(c, 0.8 + 0.2 * Math.min(1, Math.max(0, yRel / LEVEL_HEIGHT)));
}

/**
 * One wall face on the edge from (x0, z0) to (x1, z1), facing the cell whose side it is (normal
 * (nx, nz)), between heights y0 and y1 above the storey's floor `base`. `from` and `to` cut the
 * piece along the edge in metres from its west/north end.
 */
function wallPiece(
  g: GeoBuilder,
  x0: number,
  z0: number,
  x1: number,
  z1: number,
  nx: number,
  nz: number,
  base: number,
  from: number,
  to: number,
  y0: number,
  y1: number,
  tint: RGB,
  plain: boolean,
): void {
  const len = Math.hypot(x1 - x0, z1 - z0);
  const ex = (x1 - x0) / len;
  const ez = (z1 - z0) / len;
  // Points along the edge, then ordered so the face points along the normal: u = right = (nz, -nx).
  let ax = x0 + ex * from;
  let az = z0 + ez * from;
  let bx = x0 + ex * to;
  let bz = z0 + ez * to;
  const rx = nz;
  const rz = -nx;
  if ((bx - ax) * rx + (bz - az) * rz < 0) [ax, az, bx, bz] = [bx, bz, ax, az];
  // Texture u follows the world so stripes and seams line up from cell to cell.
  const ua = (ax * rx + az * rz) / 2;
  const ub = (bx * rx + bz * rz) / 2;
  // Walls above the balcony line in the atrium get the plain top of the texture, not a second stripe.
  const v0 = plain ? 0.7 : y0 / LEVEL_HEIGHT;
  const v1 = plain ? 0.95 : y1 / LEVEL_HEIGHT;
  const c0 = shade(tint, y0);
  const c1 = shade(tint, y1);
  g.quad([ax, base + y0, az], [bx - ax, 0, bz - az], [0, y1 - y0, 0], [c0, c0, c1, c1], [ua, v0, ub, v1]);
}

function wallFaces(
  g: GeoBuilder,
  plan: FloorPlan,
  level: Level,
  kind: EdgeKind,
  x0: number,
  z0: number,
  x1: number,
  z1: number,
  sides: { cx: number; cy: number; nx: number; nz: number }[],
): void {
  const solid = kind === 'wall' || kind === 'door' || (kind === 'stairTop' && level === 0);
  if (!solid) return;
  const base = level * LEVEL_HEIGHT;
  const H = LEVEL_HEIGHT;
  const len = Math.hypot(x1 - x0, z1 - z0);
  const gap0 = (len - DOOR_WIDTH) / 2;
  const gap1 = len - gap0;
  for (const s of sides) {
    const k = cellAt(plan, level, s.cx, s.cy);
    if (k === 'void') continue;
    // A level-0 stair-top wall faces only the stair; the cell beyond is under the upper floor.
    if (kind === 'stairTop' && k !== 'stair') continue;
    const tint = wallColour(areaAt(plan, level, s.cx, s.cy));
    const plain = level === 1 && k === 'atriumOpen';
    if (kind === 'door') {
      wallPiece(g, x0, z0, x1, z1, s.nx, s.nz, base, 0, gap0, 0, H, tint, plain);
      wallPiece(g, x0, z0, x1, z1, s.nx, s.nz, base, gap1, len, 0, H, tint, plain);
      wallPiece(g, x0, z0, x1, z1, s.nx, s.nz, base, gap0, gap1, DOOR_HEIGHT, H, tint, plain);
    } else {
      wallPiece(g, x0, z0, x1, z1, s.nx, s.nz, base, 0, len, 0, H, tint, plain);
    }
  }
}

export function buildStructure(plan: FloorPlan): StructureGeometry {
  const S = plan.cellSize;
  const H = LEVEL_HEIGHT;
  const floors = new GeoBuilder();
  const walls = new GeoBuilder();
  const ceilings = new GeoBuilder();
  const lights = new GeoBuilder();
  const white: RGB = [1, 1, 1];

  for (const level of [0, 1] as const) {
    const base = level * H;
    for (let y = 0; y < plan.height; y++) {
      for (let x = 0; x < plan.width; x++) {
        const k = cellAt(plan, level, x, y);
        const x0 = x * S;
        const z0 = y * S;
        // Floor: walkable cells, except stairs, which get steps instead.
        if (isWalkable(plan, level, x, y) && k !== 'stair') {
          floors.quad([x0, base, z0 + S], [S, 0, 0], [0, 0, -S], floorColour(areaAt(plan, level, x, y)), [x0 / S, -(z0 + S) / S, (x0 + S) / S, -z0 / S]);
        }
        if (hasCeiling(plan, level, x, y)) {
          const top = base + H;
          const c = scale(wallColour(areaAt(plan, level, x, y)), 0.92);
          ceilings.quad([x0, top, z0], [S, 0, 0], [0, 0, S], c, [x0 / S, z0 / S, (x0 + S) / S, (z0 + S) / S]);
          // Light panels on a checkerboard: every other cell along any run, so halls read as long.
          if ((x + y) % 2 === 0) {
            // Panels lie across the way a hall runs, like the light fittings of a real corridor.
            const open = (k: EdgeKind): number => (k === 'open' || k === 'stairTop' ? 1 : 0);
            const runsX = open(westEdge(plan, level, x, y)) + open(westEdge(plan, level, x + 1, y));
            const runsZ = open(northEdge(plan, level, x, y)) + open(northEdge(plan, level, x, y + 1));
            const hw = runsX > runsZ ? 0.3 : 0.6;
            const hl = runsX > runsZ ? 0.6 : 0.3;
            const cx = x0 + S / 2;
            const cz = z0 + S / 2;
            lights.quad([cx - hw, top - 0.01, cz - hl], [2 * hw, 0, 0], [0, 0, 2 * hl], white);
          }
        }
        // West and north edges of this cell; the last column/row's far edges are handled below.
        const west = westEdge(plan, level, x, y);
        wallFaces(walls, plan, level, west, x0, z0, x0, z0 + S, [
          { cx: x - 1, cy: y, nx: -1, nz: 0 },
          { cx: x, cy: y, nx: 1, nz: 0 },
        ]);
        const north = northEdge(plan, level, x, y);
        wallFaces(walls, plan, level, north, x0, z0, x0 + S, z0, [
          { cx: x, cy: y - 1, nx: 0, nz: -1 },
          { cx: x, cy: y, nx: 0, nz: 1 },
        ]);
      }
    }
    // Plans keep a void margin, so the far boundary edges never have anything on them; drawn anyway
    // for safety on hand-made plans.
    for (let y = 0; y < plan.height; y++) {
      const x = plan.width;
      wallFaces(walls, plan, level, westEdge(plan, level, x, y), x * S, y * S, x * S, (y + 1) * S, [{ cx: x - 1, cy: y, nx: -1, nz: 0 }]);
    }
    for (let x = 0; x < plan.width; x++) {
      const y = plan.height;
      wallFaces(walls, plan, level, northEdge(plan, level, x, y), x * S, y * S, (x + 1) * S, y * S, [{ cx: x, cy: y - 1, nx: 0, nz: -1 }]);
    }
  }
  return { floors, walls, ceilings, lights };
}
