import { describe, expect, it } from 'vitest';
import { generateClinic } from '../../src/sim/clinic';
import { canStep, cellAt, findPath, isWalkable, stairCells, stairEnds, DIR_VEC, type FloorPlan, type Pos } from '../../src/sim/floor';
import { pathDone, startPathWalk, stepPathWalk } from '../../src/sim/follow';
import { bodyAtCell, cellOf, LEVEL_HEIGHT, moveWithCollision, wallClearance, type Body } from '../../src/sim/move';
import { makeRng } from '../../src/sim/rng';
import { edgeKind } from '../../src/sim/walls';

const R = 0.3;
const alpha = generateClinic('alpha', 1);

/** Pushes in small steps, as a 60 Hz game would. */
function walk(plan: FloorPlan, b: Body, dx: number, dz: number, steps: number): Body {
  let cur = b;
  for (let i = 0; i < steps; i++) cur = moveWithCollision(plan, cur, dx, dz, R);
  return cur;
}

function sameCell(a: Pos, b: Pos): boolean {
  return a.level === b.level && a.x === b.x && a.y === b.y;
}

/** Whether moving from cell a to cell b (orthogonal or diagonal) is a legal sequence of canStep moves. */
function legalMove(plan: FloorPlan, a: Pos, b: Pos): boolean {
  if (sameCell(a, b)) return true;
  if (Math.abs(a.x - b.x) + Math.abs(a.y - b.y) === 1) return canStep(plan, a, b);
  for (const [mx, my] of [[b.x, a.y], [a.x, b.y]] as const) {
    for (const lm of [0, 1] as const) {
      const m: Pos = { level: lm, x: mx, y: my };
      if (canStep(plan, a, m) && canStep(plan, m, b)) return true;
    }
  }
  return false;
}

describe('moveWithCollision on alpha d1', () => {
  it('cannot pass through a wall', () => {
    // (10,8) is on the long level-0 corridor; north of it is solid wall.
    expect(edgeKind(alpha, 0, 10, 7, 10, 8)).toBe('wall');
    const end = walk(alpha, bodyAtCell(alpha, { level: 0, x: 10, y: 8 }), 0, -0.05, 60);
    expect(cellOf(alpha, end)).toEqual({ level: 0, x: 10, y: 8 });
    expect(end.z).toBeCloseTo(16 + R, 5);
  });

  it('passes through a door but not beside it', () => {
    const door = alpha.doors.find(
      (d) => d.level === 0 && edgeKind(alpha, 0, d.ax, d.ay, d.bx, d.by) === 'door' && cellAt(alpha, 0, d.ax, d.ay) === 'corridor',
    );
    expect(door).toBeDefined();
    if (!door) return;
    const dx = door.bx - door.ax;
    const dy = door.by - door.ay;
    const start = bodyAtCell(alpha, { level: 0, x: door.ax, y: door.ay });
    const through = walk(alpha, start, dx * 0.05, dy * 0.05, 40);
    expect(cellOf(alpha, through)).toEqual({ level: 0, x: door.bx, y: door.by });

    // Same walk, 0.75 m to one side of the door's centre line: the wall beside the gap stops it.
    for (const side of [-1, 1]) {
      const beside = { ...start, x: start.x + Math.abs(dy) * 0.75 * side, z: start.z + Math.abs(dx) * 0.75 * side };
      const blocked = walk(alpha, beside, dx * 0.05, dy * 0.05, 40);
      expect(cellOf(alpha, blocked)).toEqual({ level: 0, x: door.ax, y: door.ay });
    }
  });

  it('slides along a wall instead of stopping', () => {
    const start = bodyAtCell(alpha, { level: 0, x: 10, y: 8 });
    const end = walk(alpha, start, 0.05, -0.05, 40);
    expect(end.x - start.x).toBeGreaterThan(1.9);
    expect(end.z).toBeCloseTo(16 + R, 5);
  });

  it('walks up the stair to level 1 and back down with y continuous', () => {
    const stair = alpha.stairs[0];
    expect(stair).toBeDefined();
    if (!stair) return;
    const v = DIR_VEC[stair.dir];
    const { bottom, top } = stairEnds(stair);
    let b = bodyAtCell(alpha, bottom);
    const ys: number[] = [b.y];
    for (let i = 0; i < 400 && !sameCell(cellOf(alpha, b), top); i++) {
      b = moveWithCollision(alpha, b, v.dx * 0.05, v.dy * 0.05, R);
      ys.push(b.y);
    }
    expect(cellOf(alpha, b)).toEqual(top);
    expect(b.y).toBe(LEVEL_HEIGHT);
    for (let i = 1; i < ys.length; i++) {
      expect(ys[i] ?? 0).toBeGreaterThanOrEqual(ys[i - 1] ?? 0);
      expect((ys[i] ?? 0) - (ys[i - 1] ?? 0)).toBeLessThan(0.05);
    }
    // While on the stair it counted as level 0, as floor.ts says.
    const mid = stairCells(stair)[2];
    if (mid) expect(isWalkable(alpha, 0, mid.x, mid.y)).toBe(true);

    const down: number[] = [b.y];
    for (let i = 0; i < 400 && !sameCell(cellOf(alpha, b), bottom); i++) {
      b = moveWithCollision(alpha, b, -v.dx * 0.05, -v.dy * 0.05, R);
      down.push(b.y);
    }
    expect(cellOf(alpha, b)).toEqual(bottom);
    expect(b.y).toBe(0);
    for (let i = 1; i < down.length; i++) expect(Math.abs((down[i] ?? 0) - (down[i - 1] ?? 0))).toBeLessThan(0.05);
  });

  it('cannot step off a stair sideways, or into the stair shaft from level 1', () => {
    const stair = alpha.stairs[0];
    if (!stair) throw new Error('no stair');
    const v = DIR_VEC[stair.dir];
    const mid = stairCells(stair)[1] as { x: number; y: number };
    const onStair = walk(alpha, bodyAtCell(alpha, { level: 0, ...mid }), v.dy * 0.05, v.dx * 0.05, 60);
    expect(cellOf(alpha, onStair)).toEqual({ level: 0, ...mid });
    // On level 1, beside the shaft: find a walkable neighbour of a shaft cell and push into it.
    for (const c of stairCells(stair)) {
      for (const [sx, sy] of [[v.dy, v.dx], [-v.dy, -v.dx]] as const) {
        if (!isWalkable(alpha, 1, c.x + sx, c.y + sy)) continue;
        const b = walk(alpha, bodyAtCell(alpha, { level: 1, x: c.x + sx, y: c.y + sy }), -sx * 0.05, -sy * 0.05, 60);
        expect(cellOf(alpha, b)).toEqual({ level: 1, x: c.x + sx, y: c.y + sy });
      }
    }
  });

  it('cannot walk into the atrium opening from the balcony', () => {
    let tried = 0;
    for (let y = 0; y < alpha.height; y++) {
      for (let x = 0; x < alpha.width; x++) {
        if (cellAt(alpha, 1, x, y) !== 'corridor') continue;
        for (const [dx, dy] of [[1, 0], [-1, 0], [0, 1], [0, -1]] as const) {
          if (cellAt(alpha, 1, x + dx, y + dy) !== 'atriumOpen') continue;
          const b = walk(alpha, bodyAtCell(alpha, { level: 1, x, y }), dx * 0.05, dy * 0.05, 60);
          expect(cellOf(alpha, b)).toEqual({ level: 1, x, y });
          tried++;
        }
      }
    }
    expect(tried).toBeGreaterThan(10);
  });
});

describe('moveWithCollision never leaves walkable space', () => {
  for (const seed of ['alpha', 'bravo', 'charlie', 'delta', 'echo']) {
    it(`random walk on ${seed}`, () => {
      const plan = generateClinic(seed, 2);
      const rng = makeRng(`walk:${seed}`);
      // Start somewhere on each storey so both levels and the stairs get exercised.
      const starts: Pos[] = [plan.landing, plan.entityStart, ...plan.stairs.map((s) => stairEnds(s).bottom)];
      let levelChanges = 0;
      for (const start of starts) {
        let b = bodyAtCell(plan, start);
        let heading = rng.next() * Math.PI * 2;
        for (let i = 0; i < 1500; i++) {
          if (rng.chance(0.05)) heading = rng.next() * Math.PI * 2;
          heading += (rng.next() - 0.5) * 0.3;
          const len = rng.chance(0.1) ? 0.6 : 0.05;
          const before = cellOf(plan, b);
          b = moveWithCollision(plan, b, Math.cos(heading) * len, Math.sin(heading) * len, R);
          const after = cellOf(plan, b);
          if (after.level !== before.level) levelChanges++;
          expect(isWalkable(plan, after.level, after.x, after.y)).toBe(true);
          expect(wallClearance(plan, b.level, b.x, b.z)).toBeGreaterThanOrEqual(R - 1e-6);
          expect(legalMove(plan, before, after)).toBe(true);
        }
      }
      // Then jitter up and down every stair, with sideways wobble, so the top edge is crossed often.
      for (const stair of plan.stairs) {
        const v = DIR_VEC[stair.dir];
        let b = bodyAtCell(plan, stairEnds(stair).bottom);
        let dir = 1;
        for (let i = 0; i < 1500; i++) {
          if (rng.chance(0.01)) dir = -dir;
          const top = cellOf(plan, b);
          if (sameCell(top, stairEnds(stair).top) && rng.chance(0.2)) dir = -1;
          if (sameCell(top, stairEnds(stair).bottom) && rng.chance(0.2)) dir = 1;
          const wob = (rng.next() - 0.5) * 0.15;
          const before = cellOf(plan, b);
          b = moveWithCollision(plan, b, v.dx * 0.06 * dir + v.dy * wob, v.dy * 0.06 * dir + v.dx * wob, R);
          const after = cellOf(plan, b);
          if (after.level !== before.level) levelChanges++;
          expect(isWalkable(plan, after.level, after.x, after.y)).toBe(true);
          expect(wallClearance(plan, b.level, b.x, b.z)).toBeGreaterThanOrEqual(R - 1e-6);
          expect(legalMove(plan, before, after)).toBe(true);
        }
      }
      expect(levelChanges).toBeGreaterThanOrEqual(2);
    });
  }
});

describe('following findPath with real collision', () => {
  for (const seed of ['alpha', 'bravo', 'charlie', 'delta']) {
    for (const depth of [1, 3]) {
      it(`reaches entityStart from the landing on ${seed} d${depth}`, () => {
        const plan = generateClinic(seed, depth);
        const path = findPath(plan, plan.landing, plan.entityStart);
        expect(path).not.toBeNull();
        if (!path) return;
        const w = startPathWalk(path);
        let b = bodyAtCell(plan, plan.landing);
        let steps = 0;
        while (!pathDone(plan, w, b) && steps < 20000) {
          b = stepPathWalk(plan, w, b, 0.05, R);
          steps++;
        }
        expect(pathDone(plan, w, b)).toBe(true);
        expect(cellOf(plan, b)).toEqual(plan.entityStart);
      });
    }
  }
});
