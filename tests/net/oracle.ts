// The independent oracle for the network tests: a deliberately simple, slow visibility check that
// shares nothing with sight.ts, entity.ts or src/net. It is the entity tests' oracle, restated: the
// segment from the eye to a point is sampled every 5 cm and, wherever two samples fall in different
// cells, the crossing rules are read straight from floor.ts (canStep, doors 1.1 m wide and 2.1 m
// high, the balcony rail 1.1 m high, stair tops, holes in the upper floor). The figure is tested at
// its chest (1.7 m) and the top of its head (2.6 m), against the viewer's TRUE frustum, no margin.

import { canStep, cellAt, DIR_VEC, hasDoor, roomIdAt, stairCells, type FloorPlan, type Level, type Pos } from '../../src/sim/floor';

const H = 3.2; // storey height, restated
const ORACLE_STEP = 0.05;
const ORACLE_POINTS = [1.7, 2.6];
/** Beyond this distance (eye to the figure's chest) the oracle does not look (the entity tests use 25 m). */
export const ORACLE_RANGE = 25;

export interface OracleViewer {
  body: { x: number; y: number; z: number };
  eye: number;
  yaw: number;
  pitch: number;
  hFovDeg: number;
  vFovDeg: number;
}

export interface OracleFigure {
  x: number;
  y: number;
  z: number;
}

function oracleStairTop(plan: FloorPlan, ax: number, ay: number, bx: number, by: number): boolean {
  for (const s of plan.stairs) {
    const last = stairCells(s)[s.length - 1];
    if (!last) continue;
    const v = DIR_VEC[s.dir];
    const tx = last.x + v.dx;
    const ty = last.y + v.dy;
    if ((ax === last.x && ay === last.y && bx === tx && by === ty) || (bx === last.x && by === last.y && ax === tx && ay === ty)) return true;
  }
  return false;
}

function oracleEdge(plan: FloorPlan, L: Level, ax: number, ay: number, bx: number, by: number, lateral: number, hAbove: number): boolean {
  if (oracleStairTop(plan, ax, ay, bx, by)) return L === 1;
  const A: Pos = { level: L, x: ax, y: ay };
  const B: Pos = { level: L, x: bx, y: by };
  const ka = cellAt(plan, L, ax, ay);
  const kb = cellAt(plan, L, bx, by);
  if (canStep(plan, A, B)) {
    const ra = roomIdAt(plan, L, ax, ay);
    const sameRoom = ra >= 0 && ra === roomIdAt(plan, L, bx, by);
    const bothCorr = ka === 'corridor' && kb === 'corridor';
    if (sameRoom || bothCorr || !hasDoor(plan, L, ax, ay, bx, by)) return true;
    return Math.abs(lateral) <= 0.55 && hAbove <= 2.1;
  }
  const hole = (k: string): boolean => k === 'atriumOpen' || k === 'stair';
  if (L === 1 && hole(ka) && ka === kb) return true;
  if (L === 1 && ((ka === 'atriumOpen' && kb === 'corridor') || (kb === 'atriumOpen' && ka === 'corridor'))) return hAbove > 1.1;
  return false;
}

function oracleLos(plan: FloorPlan, from: OracleFigure, to: OracleFigure): boolean {
  const cs = plan.cellSize;
  const dist = Math.hypot(to.x - from.x, to.y - from.y, to.z - from.z);
  const n = Math.max(1, Math.ceil(dist / ORACLE_STEP));
  const at = (i: number) => {
    const t = i / n;
    return { x: from.x + (to.x - from.x) * t, y: from.y + (to.y - from.y) * t, z: from.z + (to.z - from.z) * t };
  };
  let p = at(0);
  for (let i = 1; i <= n; i++) {
    const q = at(i);
    const pc = { x: Math.floor(p.x / cs), y: Math.floor(p.z / cs) };
    const qc = { x: Math.floor(q.x / cs), y: Math.floor(q.z / cs) };
    if (p.y >= H !== q.y >= H) {
      const hole = (c: { x: number; y: number }): boolean => {
        const k = cellAt(plan, 1, c.x, c.y);
        return k === 'atriumOpen' || k === 'stair';
      };
      if (!hole(pc) && !hole(qc)) return false;
    }
    if (pc.x !== qc.x || pc.y !== qc.y) {
      const m = { x: (p.x + q.x) / 2, y: (p.y + q.y) / 2, z: (p.z + q.z) / 2 };
      const L: Level = m.y >= H ? 1 : 0;
      const hAbove = m.y - (L === 1 ? H : 0);
      const pass = (a: { x: number; y: number }, b: { x: number; y: number }): boolean => {
        const lateral = a.x !== b.x ? m.z - (a.y + 0.5) * cs : m.x - (a.x + 0.5) * cs;
        return oracleEdge(plan, L, a.x, a.y, b.x, b.y, lateral, hAbove);
      };
      const ddx = Math.abs(qc.x - pc.x);
      const ddy = Math.abs(qc.y - pc.y);
      if (ddx + ddy === 1) {
        if (!pass(pc, qc)) return false;
      } else if (ddx === 1 && ddy === 1) {
        const viaX = { x: qc.x, y: pc.y };
        const viaY = { x: pc.x, y: qc.y };
        if (!(pass(pc, viaX) && pass(viaX, qc)) && !(pass(pc, viaY) && pass(viaY, qc))) return false;
      } else {
        throw new Error('oracle step jumped more than one cell');
      }
    }
    p = q;
  }
  return true;
}

/** Inside the viewer's true frustum? Rotates into camera space (three.js YXZ); the camera looks down -z. */
function oracleInFrustum(v: OracleViewer, p: OracleFigure): boolean {
  const wx = p.x - v.body.x;
  const wy = p.y - (v.body.y + v.eye);
  const wz = p.z - v.body.z;
  const c = Math.cos(v.yaw);
  const s = Math.sin(v.yaw);
  const x1 = wx * c - wz * s;
  const z1 = wx * s + wz * c;
  const cp = Math.cos(v.pitch);
  const sp = Math.sin(v.pitch);
  const y2 = wy * cp + z1 * sp;
  const z2 = -wy * sp + z1 * cp;
  const depth = -z2;
  if (depth <= 0) return false;
  const hHalf = (v.hFovDeg * Math.PI) / 360;
  const vHalf = (v.vFovDeg * Math.PI) / 360;
  return Math.atan2(Math.abs(x1), depth) <= hHalf && Math.atan2(Math.abs(y2), depth) <= vHalf;
}

/** Whether the viewer's screen shows the figure standing at `fig` (feet). */
export function oracleSees(plan: FloorPlan, v: OracleViewer, fig: OracleFigure): boolean {
  const eye = { x: v.body.x, y: v.body.y + v.eye, z: v.body.z };
  if (Math.hypot(fig.x - eye.x, fig.y + 1.7 - eye.y, fig.z - eye.z) > ORACLE_RANGE) return false;
  const pts = ORACLE_POINTS.map((h) => ({ x: fig.x, y: fig.y + h, z: fig.z }));
  const inView = pts.filter((p) => oracleInFrustum(v, p));
  for (const p of inView) if (oracleLos(plan, eye, p)) return true;
  return false;
}
