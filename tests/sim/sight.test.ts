import { describe, expect, it } from 'vitest';
import { generateClinic } from '../../src/sim/clinic';
import { canStep, cellAt, isWalkable, type FloorPlan, type Level } from '../../src/sim/floor';
import { bodyAtCell, feetHeight, LEVEL_HEIGHT, type Body } from '../../src/sim/move';
import { canSee, figurePoints, hasLineOfSight, SIGHT_MARGIN_DEG, type Point3, type Viewer } from '../../src/sim/sight';
import { edgeKind } from '../../src/sim/walls';

const EYE = 1.65;
const V_FOV = 70;
const H_FOV = (2 * Math.atan(Math.tan((35 * Math.PI) / 180) * (16 / 9)) * 180) / Math.PI;
const DEG = Math.PI / 180;

const PLANS = ['alpha', 'bravo', 'charlie', 'delta', 'echo'].map((s) => generateClinic(s, 2));

function body(plan: FloorPlan, level: Level, x: number, z: number): Body {
  return { x, z, level, y: feetHeight(plan, level, x, z) };
}

/** A viewer at `at` looking straight at a point (yaw and pitch both aimed). */
function viewerAt(at: Body, look: { x: number; y: number; z: number }, extraYawDeg = 0): Viewer {
  const dx = look.x - at.x;
  const dz = look.z - at.z;
  const dy = look.y - (at.y + EYE);
  return {
    body: at,
    eye: EYE,
    yaw: Math.atan2(-dx, -dz) + extraYawDeg * DEG,
    pitch: Math.atan2(dy, Math.hypot(dx, dz)),
    hFovDeg: H_FOV,
    vFovDeg: V_FOV,
  };
}

function eyeOf(b: Body): Point3 {
  return { x: b.x, y: b.y + EYE, z: b.z, level: b.level };
}

function chestOf(b: Body): Point3 {
  return { x: b.x, y: b.y + 1.7, z: b.z, level: b.level };
}

const DIRS = [
  [1, 0],
  [-1, 0],
  [0, 1],
  [0, -1],
] as const;

describe('hasLineOfSight and canSee: walls and doors', () => {
  it('a wall between two cells blocks sight', () => {
    let checked = 0;
    for (const plan of PLANS) {
      for (let y = 0; y < plan.height; y++) {
        for (let x = 0; x < plan.width; x++) {
          if (cellAt(plan, 0, x, y) !== 'corridor') continue;
          for (const [dx, dy] of DIRS) {
            if (cellAt(plan, 0, x + dx, y + dy) !== 'room' || edgeKind(plan, 0, x, y, x + dx, y + dy) !== 'wall') continue;
            const v = bodyAtCell(plan, { level: 0, x, y });
            const f = bodyAtCell(plan, { level: 0, x: x + dx, y: y + dy });
            expect(hasLineOfSight(plan, eyeOf(v), chestOf(f))).toBe(false);
            expect(canSee(plan, viewerAt(v, chestOf(f)), f)).toBe(false);
            checked++;
          }
        }
      }
    }
    expect(checked).toBeGreaterThan(100);
  });

  it('a door gap lets sight through; the wall beside it does not; half hidden by the frame counts as seen', () => {
    let checked = 0;
    for (const plan of PLANS) {
      const cs = plan.cellSize;
      for (const d of plan.doors) {
        if (d.level !== 0 || edgeKind(plan, 0, d.ax, d.ay, d.bx, d.by) !== 'door') continue;
        // a = corridor side, b = the room it opens into.
        const corrA = cellAt(plan, 0, d.ax, d.ay) === 'corridor';
        const a = corrA ? { x: d.ax, y: d.ay } : { x: d.bx, y: d.by };
        const b = corrA ? { x: d.bx, y: d.by } : { x: d.ax, y: d.ay };
        if (cellAt(plan, 0, a.x, a.y) !== 'corridor' || cellAt(plan, 0, b.x, b.y) !== 'room') continue;
        const nx = b.x - a.x;
        const nz = b.y - a.y;
        const lx = -nz;
        const lz = nx;
        // Edge centre.
        const ex = (a.x + 0.5) * cs + (nx * cs) / 2;
        const ez = (a.y + 0.5) * cs + (nz * cs) / 2;
        const at = (n: number, l: number): Body => body(plan, 0, ex + nx * n + lx * l, ez + nz * n + lz * l);

        // Straight through the middle of the gap.
        const v0 = at(-1, 0);
        const f0 = at(1, 0);
        expect(canSee(plan, viewerAt(v0, chestOf(f0)), f0)).toBe(true);

        // From 0.3 m in front of the edge and 0.9 m to one side, a figure 1 m beyond the edge and
        // 0.65 m to the same side is entirely behind the wall beside the gap.
        const v1 = at(-0.3, 0.9);
        const hidden = at(1, 0.65);
        for (const p of figurePoints(hidden, v1.x, v1.z)) expect(hasLineOfSight(plan, eyeOf(v1), p)).toBe(false);
        expect(canSee(plan, viewerAt(v1, chestOf(hidden)), hidden)).toBe(false);

        // The same viewer, a figure 0.3 m to the other side: its centre line is behind the frame,
        // one shoulder is in the gap. Seen.
        const half = at(1, -0.3);
        expect(hasLineOfSight(plan, eyeOf(v1), chestOf(half))).toBe(false);
        expect(canSee(plan, viewerAt(v1, chestOf(half)), half)).toBe(true);
        checked++;
      }
    }
    expect(checked).toBeGreaterThan(20);
  });
});

/** The longest straight corridor run on level 0 of a plan. */
function longestRun(plan: FloorPlan) {
  const s = [...plan.sightlines].filter((l) => l.level === 0).sort((p, q) => q.length - p.length)[0];
  if (!s) throw new Error('no sightline');
  return s;
}

describe('canSee: the view cone', () => {
  it('inside the margin counts, outside it does not, and behind is never seen', () => {
    for (const plan of PLANS) {
      const s = longestRun(plan);
      const dx = Math.sign(s.x2 - s.x1);
      const dy = Math.sign(s.y2 - s.y1);
      const v = bodyAtCell(plan, { level: 0, x: s.x1, y: s.y1 });
      const f = bodyAtCell(plan, { level: 0, x: s.x1 + dx * 5, y: s.y1 + dy * 5 });
      const chest = chestOf(f);
      expect(canSee(plan, viewerAt(v, chest), f)).toBe(true);
      const halfH = H_FOV / 2;
      for (const sign of [1, -1]) {
        // 6 degrees past the screen's edge: only the margin catches it.
        const nearEdge = viewerAt(v, chest, sign * (halfH + 6));
        expect(canSee(plan, nearEdge, f)).toBe(true);
        expect(canSee(plan, nearEdge, f, { marginDeg: 0 })).toBe(false);
        // Past the margin too.
        expect(canSee(plan, viewerAt(v, chest, sign * (halfH + SIGHT_MARGIN_DEG + 4)), f)).toBe(false);
      }
      // Vertical edge: looking up so the figure sits just below the bottom of the screen.
      const up = viewerAt(v, chest);
      up.pitch = (V_FOV / 2 + 6) * DEG + Math.atan2(2.6 - 1.65, Math.hypot(f.x - v.x, f.z - v.z));
      expect(canSee(plan, up, f)).toBe(true);
      expect(canSee(plan, up, f, { marginDeg: 0 })).toBe(false);
      // Behind.
      expect(canSee(plan, viewerAt(v, chest, 180), f)).toBe(false);
      expect(canSee(plan, viewerAt(v, chest, 180), f, { marginDeg: 40 })).toBe(false);
    }
  });

  it('sees a figure at the far end of a long corridor', () => {
    for (const plan of PLANS) {
      const s = longestRun(plan);
      expect(s.length).toBeGreaterThanOrEqual(12);
      const v = bodyAtCell(plan, { level: 0, x: s.x1, y: s.y1 });
      const f = bodyAtCell(plan, { level: 0, x: s.x2, y: s.y2 });
      expect(canSee(plan, viewerAt(v, chestOf(f)), f)).toBe(true);
      // and nothing beyond the far limit
      expect(canSee(plan, viewerAt(v, chestOf(f)), f, { far: 5 })).toBe(false);
    }
  });
});

describe('canSee: between levels', () => {
  /** A balcony cell (level-1 corridor beside the atrium opening) and an atrium floor cell 3 in. */
  function balconyAndFloor(plan: FloorPlan) {
    for (let y = 0; y < plan.height; y++) {
      for (let x = 0; x < plan.width; x++) {
        if (cellAt(plan, 1, x, y) !== 'corridor') continue;
        for (const [dx, dy] of DIRS) {
          const fx = x + dx * 3;
          const fy = y + dy * 3;
          let open = true;
          for (let i = 1; i <= 3; i++) if (cellAt(plan, 1, x + dx * i, y + dy * i) !== 'atriumOpen') open = false;
          if (open && isWalkable(plan, 0, fx, fy)) return { balcony: { x, y }, floor: { x: fx, y: fy } };
        }
      }
    }
    throw new Error('no balcony');
  }

  it('a viewer on the balcony sees a figure on the atrium floor, and the other way round', () => {
    for (const plan of PLANS) {
      const { balcony, floor } = balconyAndFloor(plan);
      const up = bodyAtCell(plan, { level: 1, ...balcony });
      const down = bodyAtCell(plan, { level: 0, ...floor });
      expect(up.y).toBe(LEVEL_HEIGHT);
      expect(canSee(plan, viewerAt(up, chestOf(down)), down)).toBe(true);
      expect(canSee(plan, viewerAt(down, chestOf(up)), up)).toBe(true);
    }
  });

  it('there is no sight through the floor anywhere else', () => {
    let checked = 0;
    for (const plan of PLANS) {
      for (let y = 0; y < plan.height; y++) {
        for (let x = 0; x < plan.width; x++) {
          // Viewer on level 1 over solid floor, figure on level 0 one cell away, under solid floor too.
          if (!isWalkable(plan, 1, x, y) || cellAt(plan, 1, x, y) === 'stair') continue;
          for (const [dx, dy] of DIRS) {
            const k1 = cellAt(plan, 1, x + dx, y + dy);
            if (!isWalkable(plan, 0, x + dx, y + dy) || k1 === 'atriumOpen' || k1 === 'stair') continue;
            if (cellAt(plan, 0, x + dx, y + dy) === 'stair') continue;
            const v = bodyAtCell(plan, { level: 1, x, y });
            const f = bodyAtCell(plan, { level: 0, x: x + dx, y: y + dy });
            const look = viewerAt(v, chestOf(f));
            expect(canSee(plan, look, f, { marginDeg: 40 })).toBe(false);
            expect(canSee(plan, viewerAt(f, chestOf(v)), v, { marginDeg: 40 })).toBe(false);
            checked++;
          }
        }
      }
    }
    expect(checked).toBeGreaterThan(200);
  });

  it('a stair: from the top you see someone halfway up it', () => {
    for (const plan of PLANS) {
      const st = plan.stairs[0];
      if (!st) throw new Error('no stair');
      const v = { n: [0, -1], e: [1, 0], s: [0, 1], w: [-1, 0] }[st.dir] as [number, number];
      const top = { level: 1 as Level, x: st.x + v[0] * st.length, y: st.y + v[1] * st.length };
      expect(canStep(plan, { level: 0, x: st.x + v[0] * (st.length - 1), y: st.y + v[1] * (st.length - 1) }, top)).toBe(true);
      const viewer = bodyAtCell(plan, top);
      const mid = bodyAtCell(plan, { level: 0, x: st.x + v[0], y: st.y + v[1] });
      expect(mid.y).toBeGreaterThan(0);
      expect(canSee(plan, viewerAt(viewer, chestOf(mid)), mid)).toBe(true);
      expect(canSee(plan, viewerAt(mid, chestOf(viewer)), viewer)).toBe(true);
    }
  });
});

describe('canSee: speed', () => {
  it('is cheap enough to run for every player every tick', () => {
    const plan = PLANS[0] as FloorPlan;
    const s = longestRun(plan);
    const v = bodyAtCell(plan, { level: 0, x: s.x1, y: s.y1 });
    const f = bodyAtCell(plan, { level: 0, x: s.x2, y: s.y2 });
    const look = viewerAt(v, chestOf(f));
    const n = 20000;
    const t0 = performance.now();
    let seen = 0;
    for (let i = 0; i < n; i++) if (canSee(plan, look, f)) seen++;
    const perCall = (performance.now() - t0) / n;
    expect(seen).toBe(n);
    expect(perCall).toBeLessThan(0.05); // ms; a clear long view is close to the worst case
  });
});
