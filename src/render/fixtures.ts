// Fittings: stair steps and handrails, the balcony rail round the atrium opening, door frames, and
// the elevator at the landing. All untextured, coloured per vertex, one draw call together.

import { DIR_VEC, type FloorPlan, type Level } from '../sim/floor';
import { elevatorWall } from '../sim/landing';
import { LEVEL_HEIGHT } from '../sim/move';
import { DOOR_WIDTH, northEdge, westEdge, type EdgeKind } from '../sim/walls';
import type { GeoBuilder, RGB, V3 } from './geoBuilder';
import { TRIM } from './palette';
import { DOOR_HEIGHT } from './structure';

const STEP_RISE = 0.2;
const UP: V3 = [0, 1, 0];

/**
 * Steps matching the collision ramp in move.ts: the ramp runs from the bottom edge (y 0) to the top
 * edge (y LEVEL_HEIGHT), and each tread sits at most one rise above it.
 */
function stairs(g: GeoBuilder, plan: FloorPlan): void {
  const S = plan.cellSize;
  for (const s of plan.stairs) {
    const v = DIR_VEC[s.dir];
    const fwd: V3 = [v.dx, 0, v.dy];
    const lat: V3 = [-v.dy, 0, v.dx];
    const bx = (s.x + 0.5) * S - (v.dx * S) / 2;
    const bz = (s.y + 0.5) * S - (v.dy * S) / 2;
    const run = s.length * S;
    const n = Math.round(LEVEL_HEIGHT / STEP_RISE);
    const tread = run / n;
    const half = S / 2;
    const at = (a: number, l: number, y: number): V3 => [bx + v.dx * a + lat[0] * l, y, bz + v.dy * a + lat[2] * l];
    const across: V3 = [lat[0] * S, 0, lat[2] * S];
    const nose = 0.06;
    for (let i = 0; i < n; i++) {
      const a0 = i * tread;
      const y = (i + 1) * STEP_RISE;
      g.quadFacing(at(a0, -half, y), across, [v.dx * nose, 0, v.dy * nose], UP, TRIM.stepNose);
      g.quadFacing(at(a0 + nose, -half, y), across, [v.dx * (tread - nose), 0, v.dy * (tread - nose)], UP, TRIM.stepTread);
      g.quadFacing(at(a0, -half, y - STEP_RISE), across, [0, STEP_RISE, 0], [-v.dx, 0, -v.dy], TRIM.stepRiser);
    }
    // Handrails on both side walls, following the pitch: a top face and a face towards the middle.
    const rise: V3 = [fwd[0] * run, LEVEL_HEIGHT, fwd[2] * run];
    for (const side of [-1, 1]) {
      const inward: V3 = [-lat[0] * side, 0, -lat[2] * side];
      const p = at(0, side * (half - 0.03), 0.95);
      const w: V3 = [inward[0] * 0.06, 0, inward[2] * 0.06];
      g.quadFacing(p, rise, w, UP, TRIM.handrail);
      g.quadFacing([p[0] + w[0], p[1] - 0.07, p[2] + w[2]], rise, [0, 0.07, 0], inward, TRIM.handrail);
    }
  }
}

/** Calls fn with the endpoints (metres) of every edge of the wanted kind on a level. */
function forEdges(plan: FloorPlan, level: Level, want: EdgeKind, fn: (x0: number, z0: number, x1: number, z1: number) => void): void {
  const S = plan.cellSize;
  for (let y = 0; y <= plan.height; y++) {
    for (let x = 0; x <= plan.width; x++) {
      if (westEdge(plan, level, x, y) === want) fn(x * S, y * S, x * S, (y + 1) * S);
      if (northEdge(plan, level, x, y) === want) fn(x * S, y * S, (x + 1) * S, y * S);
    }
  }
}

/** A box along an axis-aligned segment, `thick` metres across it, between heights y0 and y1. */
function edgeBox(g: GeoBuilder, x0: number, z0: number, x1: number, z1: number, thick: number, y0: number, y1: number, c: RGB): void {
  const h = thick / 2;
  const alongX = z0 === z1;
  g.box(
    [Math.min(x0, x1) - (alongX ? 0 : h), y0, Math.min(z0, z1) - (alongX ? h : 0)],
    [Math.max(x0, x1) + (alongX ? 0 : h), y1, Math.max(z0, z1) + (alongX ? h : 0)],
    c,
  );
}

/** Cap, mid rail, kick plate and posts on every rail edge, sitting exactly on the opening's edge. */
function balconyRails(g: GeoBuilder, plan: FloorPlan): void {
  const base = LEVEL_HEIGHT;
  forEdges(plan, 1, 'rail', (x0, z0, x1, z1) => {
    const ux = Math.sign(x1 - x0);
    const uz = Math.sign(z1 - z0);
    // Cap and kick plate overhang the ends so runs and corners join without gaps.
    const o = 0.05;
    edgeBox(g, x0 - ux * o, z0 - uz * o, x1 + ux * o, z1 + uz * o, 0.1, base + 0.98, base + 1.05, TRIM.railCap);
    edgeBox(g, x0 - ux * o, z0 - uz * o, x1 + ux * o, z1 + uz * o, 0.05, base, base + 0.16, TRIM.railKick);
    edgeBox(g, x0, z0, x1, z1, 0.03, base + 0.55, base + 0.59, TRIM.railPost);
    for (const t of [0, 0.5]) {
      const px = x0 + (x1 - x0) * t;
      const pz = z0 + (z1 - z0) * t;
      g.box([px - 0.025, base, pz - 0.025], [px + 0.025, base + 0.98, pz + 0.025], TRIM.railPost);
    }
  });
}

/** Jambs and a head round every door gap, framing exactly the opening collision allows. */
function doorFrames(g: GeoBuilder, plan: FloorPlan): void {
  for (const level of [0, 1] as const) {
    const base = level * LEVEL_HEIGHT;
    forEdges(plan, level, 'door', (x0, z0, x1, z1) => {
      const len = Math.hypot(x1 - x0, z1 - z0);
      const ex = (x1 - x0) / len;
      const ez = (z1 - z0) / len;
      const g0 = (len - DOOR_WIDTH) / 2;
      const g1 = len - g0;
      const w = 0.07;
      const depth = 0.16;
      const p = (a: number): [number, number] => [x0 + ex * a, z0 + ez * a];
      const [ax0, az0] = p(g0 - w);
      const [ax1, az1] = p(g0);
      const [bx0, bz0] = p(g1);
      const [bx1, bz1] = p(g1 + w);
      edgeBox(g, ax0, az0, ax1, az1, depth, base, base + DOOR_HEIGHT + w, TRIM.doorFrame);
      edgeBox(g, bx0, bz0, bx1, bz1, depth, base, base + DOOR_HEIGHT + w, TRIM.doorFrame);
      edgeBox(g, ax1, az1, bx0, bz0, depth, base + DOOR_HEIGHT, base + DOOR_HEIGHT + w, TRIM.doorFrame);
    });
  }
}

/** Steel doors in a dark frame on the landing's back wall, a lit indicator, a marked floor square. */
function elevator(g: GeoBuilder, lights: GeoBuilder, plan: FloorPlan): void {
  const S = plan.cellSize;
  const { x, y, level } = plan.landing;
  const base = level * LEVEL_HEIGHT;
  const cx = (x + 0.5) * S;
  const cz = (y + 0.5) * S;
  const d = 0.8;
  const b = 0.12;
  g.quadFacing([cx - d, base + 0.006, cz - d], [2 * d, 0, 0], [0, 0, 2 * d], UP, TRIM.decalYellow);
  g.quadFacing([cx - d + b, base + 0.009, cz - d + b], [2 * (d - b), 0, 0], [0, 0, 2 * (d - b)], UP, TRIM.decalFill);

  const dir = elevatorWall(plan);
  if (!dir) return;
  const v = DIR_VEC[dir];
  const into: V3 = [-v.dx, 0, -v.dy];
  const lat: V3 = [-v.dy, 0, v.dx];
  // Centre of the wall line, at floor height.
  const wx = cx + (v.dx * S) / 2;
  const wz = cz + (v.dy * S) / 2;
  const pt = (l: number, out: number, yy: number): V3 => [wx + lat[0] * l + into[0] * out, yy, wz + lat[2] * l + into[2] * out];
  const halfW = 0.65;
  const doorH = 2.25;
  g.quadFacing(pt(-halfW, 0.02, base), [lat[0] * 2 * halfW, 0, lat[2] * 2 * halfW], [0, doorH, 0], into, TRIM.steel);
  g.quadFacing(pt(-0.025, 0.025, base), [lat[0] * 0.05, 0, lat[2] * 0.05], [0, doorH, 0], into, TRIM.seam);
  const fw = 0.14;
  const fd = 0.1;
  const frameBox = (l0: number, l1: number, y0: number, y1: number): void => {
    const a = pt(l0, -fd, y0);
    const c = pt(l1, fd, y1);
    g.box([Math.min(a[0], c[0]), y0, Math.min(a[2], c[2])], [Math.max(a[0], c[0]), y1, Math.max(a[2], c[2])], TRIM.steelDark);
  };
  frameBox(-halfW - fw, -halfW, base, base + doorH + fw);
  frameBox(halfW, halfW + fw, base, base + doorH + fw);
  frameBox(-halfW, halfW, base + doorH, base + doorH + fw);
  // Lit floor indicator above the doors.
  lights.quadFacing(pt(-0.15, 0.03, base + doorH + fw + 0.1), [lat[0] * 0.3, 0, lat[2] * 0.3], [0, 0.12, 0], into, [1, 1, 1]);
}

export function buildFixtures(plan: FloorPlan, trim: GeoBuilder, lights: GeoBuilder): void {
  stairs(trim, plan);
  balconyRails(trim, plan);
  doorFrames(trim, plan);
  elevator(trim, lights, plan);
}
