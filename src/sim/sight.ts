// Who can see what. Line of sight through a floor plan in 3D, and whether a viewer's screen could
// be showing a figure. Entities that obey "only moves while nobody is looking" ask this every tick
// for every player, so it walks the ray across the 2 m grid edge by edge rather than sampling it.
//
// Geometry, read straight from walls.ts and floor.ts:
//   - level 0 is the space y in [0, LEVEL_HEIGHT), level 1 is y >= LEVEL_HEIGHT. Which level's walls
//     a ray meets at a cell edge depends on the ray's height where it crosses that edge;
//   - walls are full storey height; a door is an opening DOOR_WIDTH wide (centred on its edge) and
//     DOOR_HEIGHT high, with wall either side and above it;
//   - the slab between the levels is solid except over holes in level 1: atrium openings and stair
//     shafts. A ray may change level only through a hole;
//   - balcony rails are see-through (generous: a real rail would hide a little below its top);
//   - the top of a stair is open on level 1 and closed on level 0, as walls.ts and the renderer say;
//   - the stair ramp itself does not block sight (generous).
//
// Fairness: every judgement that is close is decided as "visible". Door gaps, lintels, the slab
// holes and the height at which a ray changes level all carry a few centimetres of slack, and a ray
// that passes within CORNER_SLACK of a grid corner is let through if either way round the corner
// is open.

import { cellAt, type FloorPlan, type Level } from './floor';
import { LEVEL_HEIGHT, type Body } from './move';
import { DOOR_WIDTH, northEdge, westEdge, type EdgeKind } from './walls';

/** Height of a door opening above its floor, in metres. */
export const DOOR_HEIGHT = 2.1;
/** Slack in metres added in the viewer's favour to door gaps, lintels and the level boundary. */
export const SIGHT_SLACK = 0.05;
/** A ray that passes this close (metres along the ray) to a grid corner may go round either side. */
export const CORNER_SLACK = 0.1;
/** Slack in metres around the point where a ray passes through the slab between levels. */
export const SLAB_SLACK = 0.06;

/** Default widening of the view cone on every side, in degrees. */
export const SIGHT_MARGIN_DEG = 12;
/** Default far limit of sight, in metres (longer than any floor's diagonal). */
export const SIGHT_FAR = 130;
/** Default figure: the Orderly. */
export const FIGURE_HEIGHT = 2.6;
export const FIGURE_RADIUS = 0.35;
/**
 * Heights of the sampled points on a FIGURE_HEIGHT figure, metres: feet (just above the floor),
 * knees, waist, chest, top of the head. Other heights scale these.
 */
const FIGURE_LEVELS = [0.05, 0.52, 1.1, 1.7, 2.6] as const;
/** Shoulder height on a FIGURE_HEIGHT figure; shoulders sit `radius` to each side. */
const SHOULDER_LEVEL = 2.1;
/** Never widen a half-angle past this, so tan() stays finite. */
const MAX_HALF_ANGLE = (89.5 * Math.PI) / 180;

/** A point in the world: x and z on the floor plane (metres), y the absolute height. */
export interface Point3 {
  x: number;
  y: number;
  z: number;
  level: Level;
}

/** Someone looking: feet at body, eyes `eye` metres above the feet, yaw/pitch three.js style. */
export interface Viewer {
  body: Body;
  /** Eye height above the feet, in metres. */
  eye: number;
  /** Radians about +y: 0 faces -z (north), pi/2 faces -x (west). */
  yaw: number;
  /** Radians, positive looks up. */
  pitch: number;
  /** Full horizontal and vertical fields of view, degrees. */
  hFovDeg: number;
  vFovDeg: number;
}

export interface SightOptions {
  /** Widening of the cone on every side, degrees. Default SIGHT_MARGIN_DEG. */
  marginDeg?: number;
  /** Far limit, metres. Default SIGHT_FAR. */
  far?: number;
  /** Figure size. Defaults: the Orderly. */
  height?: number;
  radius?: number;
}

// ---------------------------------------------------------------------------------------------
// Line of sight.

function edgePasses(kind: EdgeKind, level: Level, along: number, y: number): boolean {
  switch (kind) {
    case 'open':
    case 'rail':
      return true;
    case 'stairTop':
      return level === 1;
    case 'door': {
      const floorY = level === 1 ? LEVEL_HEIGHT : 0;
      return Math.abs(along) <= DOOR_WIDTH / 2 + SIGHT_SLACK && y - floorY <= DOOR_HEIGHT + SIGHT_SLACK;
    }
    default:
      return false;
  }
}

/** Whether a ray at height y gets through a cell edge; near the level boundary either level will do. */
function crossing(kindAt: (level: Level) => EdgeKind, along: number, y: number): boolean {
  if (y >= LEVEL_HEIGHT + SIGHT_SLACK) return edgePasses(kindAt(1), 1, along, y);
  if (y < LEVEL_HEIGHT - SIGHT_SLACK) return edgePasses(kindAt(0), 0, along, y);
  return edgePasses(kindAt(0), 0, along, y) || edgePasses(kindAt(1), 1, along, y);
}

function isHole(plan: FloorPlan, x: number, z: number): boolean {
  const k = cellAt(plan, 1, Math.floor(x / plan.cellSize), Math.floor(z / plan.cellSize));
  return k === 'atriumOpen' || k === 'stair';
}

/** Whether there is a hole in the slab at (or within SLAB_SLACK of) a point. */
function holeNear(plan: FloorPlan, x: number, z: number): boolean {
  const e = SLAB_SLACK;
  return isHole(plan, x, z) || isHole(plan, x - e, z - e) || isHole(plan, x + e, z - e) || isHole(plan, x - e, z + e) || isHole(plan, x + e, z + e);
}

/**
 * Whether nothing solid lies between two points: walls (with door gaps), the slab between levels
 * (except through atrium openings and stair shafts). The points' own levels are not used: the
 * height y decides which level's walls a ray meets.
 */
export function hasLineOfSight(plan: FloorPlan, from: Point3, to: Point3): boolean {
  const cs = plan.cellSize;
  const dx = to.x - from.x;
  const dy = to.y - from.y;
  const dz = to.z - from.z;

  // The slab: a straight ray crosses the level boundary at most once.
  if (from.y >= LEVEL_HEIGHT !== to.y >= LEVEL_HEIGHT) {
    const t = (LEVEL_HEIGHT - from.y) / dy;
    if (!holeNear(plan, from.x + dx * t, from.z + dz * t)) return false;
  }

  let cx = Math.floor(from.x / cs);
  let cz = Math.floor(from.z / cs);
  const ex = Math.floor(to.x / cs);
  const ez = Math.floor(to.z / cs);
  const stepX = dx > 0 ? 1 : dx < 0 ? -1 : 0;
  const stepZ = dz > 0 ? 1 : dz < 0 ? -1 : 0;
  const len = Math.hypot(dx, dz);
  let tMaxX = stepX !== 0 ? ((stepX > 0 ? cx + 1 : cx) * cs - from.x) / dx : Number.POSITIVE_INFINITY;
  let tMaxZ = stepZ !== 0 ? ((stepZ > 0 ? cz + 1 : cz) * cs - from.z) / dz : Number.POSITIVE_INFINITY;
  const tDeltaX = stepX !== 0 ? cs / Math.abs(dx) : Number.POSITIVE_INFINITY;
  const tDeltaZ = stepZ !== 0 ? cs / Math.abs(dz) : Number.POSITIVE_INFINITY;

  // Crossing the vertical grid line gx (between cells gx-1 and gx) in row `row`, at ray parameter t.
  const xLine = (gx: number, row: number, t: number): boolean => {
    const z = from.z + dz * t;
    return crossing((l) => westEdge(plan, l, gx, row), z - (row + 0.5) * cs, from.y + dy * t);
  };
  // Crossing the horizontal grid line gz (between rows gz-1 and gz) in column `col`.
  const zLine = (gz: number, col: number, t: number): boolean => {
    const x = from.x + dx * t;
    return crossing((l) => northEdge(plan, l, col, gz), x - (col + 0.5) * cs, from.y + dy * t);
  };

  const maxSteps = 2 * (plan.width + plan.height) + 8;
  for (let i = 0; i < maxSteps && (cx !== ex || cz !== ez); i++) {
    if (Math.min(tMaxX, tMaxZ) > 1) break; // rounding at the far end: nothing left to cross
    const gx = stepX > 0 ? cx + 1 : cx;
    const gz = stepZ > 0 ? cz + 1 : cz;
    if (tMaxX <= 1 && tMaxZ <= 1 && Math.abs(tMaxX - tMaxZ) * len < CORNER_SLACK) {
      // Close to a corner: through either neighbour will do.
      const viaX = xLine(gx, cz, tMaxX) && zLine(gz, cx + stepX, tMaxZ);
      const viaZ = zLine(gz, cx, tMaxZ) && xLine(gx, cz + stepZ, tMaxX);
      if (!viaX && !viaZ) return false;
      cx += stepX;
      cz += stepZ;
      tMaxX += tDeltaX;
      tMaxZ += tDeltaZ;
    } else if (tMaxX < tMaxZ) {
      if (!xLine(gx, cz, tMaxX)) return false;
      cx += stepX;
      tMaxX += tDeltaX;
    } else {
      if (!zLine(gz, cx, tMaxZ)) return false;
      cz += stepZ;
      tMaxZ += tDeltaZ;
    }
  }
  return true;
}

// ---------------------------------------------------------------------------------------------
// Seeing a figure.

/** Where a viewer's eyes are. */
export function eyePoint(v: Pick<Viewer, 'body' | 'eye'>): Point3 {
  return { x: v.body.x, y: v.body.y + v.eye, z: v.body.z, level: v.body.level };
}

/**
 * The points sampled on a standing figure: feet, knees, waist, chest, head, and two shoulders set
 * `radius` to either side as seen from (fromX, fromZ), so the widest silhouette is tested.
 */
export function figurePoints(figure: Body, fromX: number, fromZ: number, height = FIGURE_HEIGHT, radius = FIGURE_RADIUS): Point3[] {
  const k = height / FIGURE_HEIGHT;
  const out: Point3[] = FIGURE_LEVELS.map((h) => ({ x: figure.x, y: figure.y + h * k, z: figure.z, level: figure.level }));
  let sx = -(figure.z - fromZ);
  let sz = figure.x - fromX;
  const n = Math.hypot(sx, sz);
  if (n > 1e-9) {
    sx = (sx / n) * radius;
    sz = (sz / n) * radius;
    const y = figure.y + SHOULDER_LEVEL * k;
    out.push({ x: figure.x + sx, y, z: figure.z + sz, level: figure.level }, { x: figure.x - sx, y, z: figure.z - sz, level: figure.level });
  }
  return out;
}

/** Camera basis for yaw/pitch (three.js 'YXZ' order): forward, right, up. */
function basis(yaw: number, pitch: number) {
  const sy = Math.sin(yaw);
  const cy = Math.cos(yaw);
  const sp = Math.sin(pitch);
  const cp = Math.cos(pitch);
  return {
    f: [-cp * sy, sp, -cp * cy] as const,
    r: [cy, 0, -sy] as const,
    u: [sp * sy, cp, sp * cy] as const,
  };
}

/** Whether a point is inside the viewer's frustum widened by `marginDeg` on every side (no walls). */
export function inViewCone(viewer: Viewer, p: { x: number; y: number; z: number }, marginDeg = SIGHT_MARGIN_DEG): boolean {
  const { f, r, u } = basis(viewer.yaw, viewer.pitch);
  const vx = p.x - viewer.body.x;
  const vy = p.y - (viewer.body.y + viewer.eye);
  const vz = p.z - viewer.body.z;
  const d = vx * f[0] + vy * f[1] + vz * f[2];
  if (d <= 0) return false;
  const m = (marginDeg * Math.PI) / 180;
  const h = Math.min(MAX_HALF_ANGLE, (viewer.hFovDeg * Math.PI) / 360 + m);
  const v = Math.min(MAX_HALF_ANGLE, (viewer.vFovDeg * Math.PI) / 360 + m);
  const side = vx * r[0] + vz * r[2];
  const up = vx * u[0] + vy * u[1] + vz * u[2];
  return Math.abs(side) <= d * Math.tan(h) && Math.abs(up) <= d * Math.tan(v);
}

/**
 * Whether the viewer's screen could be showing the figure: any sampled point on it is inside the
 * widened view cone, within the far limit, with a clear line of sight from the eyes.
 */
export function canSee(plan: FloorPlan, viewer: Viewer, figure: Body, opts: SightOptions = {}): boolean {
  const margin = opts.marginDeg ?? SIGHT_MARGIN_DEG;
  const far = opts.far ?? SIGHT_FAR;
  const eye = eyePoint(viewer);
  for (const p of figurePoints(figure, eye.x, eye.z, opts.height, opts.radius)) {
    if (Math.hypot(p.x - eye.x, p.y - eye.y, p.z - eye.z) > far) continue;
    if (!inViewCone(viewer, p, margin)) continue;
    if (hasLineOfSight(plan, eye, p)) return true;
  }
  return false;
}
