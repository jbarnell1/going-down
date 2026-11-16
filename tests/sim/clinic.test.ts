import { readdirSync, readFileSync, statSync } from 'node:fs';
import { join } from 'node:path';
import { describe, expect, it } from 'vitest';
import { generateClinic } from '../../src/sim/clinic';
import {
  canStep,
  cellAt,
  distancesFrom,
  findPath,
  hashPlan,
  isWalkable,
  neighbours,
  onSightline,
  posIndex,
  reachableFrom,
  renderAscii,
  roomIdAt,
  stairCells,
  stairEnds,
  type Door,
  type FloorPlan,
  type Level,
  type Pos,
} from '../../src/sim/floor';

const SEEDS = Array.from({ length: 200 }, (_, i) => `seed-${i}`);
const DEPTHS = [1, 2, 3, 4];

// Every requirement is checked on all 800 floors. Generated once and shared.
const PLANS: FloorPlan[] = [];
for (const depth of DEPTHS) for (const seed of SEEDS) PLANS.push(generateClinic(seed, depth));

function label(p: FloorPlan): string {
  return `${p.seed} d${p.depth}`;
}

function eachCell(p: FloorPlan, fn: (level: Level, x: number, y: number) => void): void {
  for (const level of [0, 1] as const) for (let y = 0; y < p.height; y++) for (let x = 0; x < p.width; x++) fn(level, x, y);
}

/**
 * Side branches, computed here from scratch rather than trusting the generator's labels.
 * A side branch is a set of `side` rooms that are joined to each other by doors (a connected group)
 * and joined to everything else by exactly one door, whose far side is corridor or a `main` room.
 */
function sideGroups(p: FloorPlan): { rooms: number[]; exits: Door[] }[] {
  const side = new Set(p.rooms.filter((r) => r.branch === 'side').map((r) => r.id));
  const doorRooms = (d: Door): [number, number] => [roomIdAt(p, d.level, d.ax, d.ay), roomIdAt(p, d.level, d.bx, d.by)];
  const parent = new Map<number, number>();
  const find = (x: number): number => {
    while ((parent.get(x) ?? x) !== x) x = parent.get(x) ?? x;
    return x;
  };
  for (const id of side) parent.set(id, id);
  for (const d of p.doors) {
    const [a, b] = doorRooms(d);
    if (side.has(a) && side.has(b)) parent.set(find(a), find(b));
  }
  const groups = new Map<number, { rooms: number[]; exits: Door[] }>();
  for (const id of side) {
    const g = groups.get(find(id)) ?? { rooms: [], exits: [] };
    g.rooms.push(id);
    groups.set(find(id), g);
  }
  for (const d of p.doors) {
    const [a, b] = doorRooms(d);
    for (const [inside, outside] of [
      [a, b],
      [b, a],
    ] as const) {
      if (side.has(inside) && !side.has(outside)) groups.get(find(inside))?.exits.push(d);
    }
  }
  return [...groups.values()];
}

describe('clinic: determinism', () => {
  it('the same seed and depth give an identical plan', () => {
    for (const seed of SEEDS.slice(0, 50)) {
      for (const depth of DEPTHS) {
        const a = generateClinic(seed, depth);
        const b = generateClinic(seed, depth);
        expect(b).toEqual(a);
        expect(hashPlan(b)).toBe(hashPlan(a));
      }
    }
  });

  it('different seeds almost always differ, and so do different depths', () => {
    const byDepth1 = new Set(PLANS.filter((p) => p.depth === 1).map(hashPlan));
    expect(byDepth1.size).toBeGreaterThanOrEqual(SEEDS.length - 1);
    expect(hashPlan(generateClinic('x', 1))).not.toBe(hashPlan(generateClinic('x', 2)));
  });

  it('hashPlan notices a one-cell change', () => {
    const p = generateClinic('hash-me', 1);
    const q: FloorPlan = { ...p, cells: [[...p.cells[0]], [...p.cells[1]]] };
    q.cells[1][0] = q.cells[1][0] === 'void' ? 'corridor' : 'void';
    expect(hashPlan(q)).not.toBe(hashPlan(p));
  });

  it('deeper floors are larger', () => {
    const d1 = generateClinic('grow', 1);
    const d4 = generateClinic('grow', 4);
    expect(d4.width * d4.height).toBeGreaterThan(d1.width * d1.height);
  });
});

describe('clinic: connectivity', () => {
  it('every walkable cell, and so every room, is reachable from the landing', () => {
    for (const p of PLANS) {
      const seen = reachableFrom(p, p.landing);
      let missing = 0;
      eachCell(p, (level, x, y) => {
        if (isWalkable(p, level, x, y) && !seen.has(posIndex(p, { level, x, y }))) missing++;
      });
      expect(missing, label(p)).toBe(0);
      for (const r of p.rooms) expect(seen.has(posIndex(p, { level: r.level, x: r.x, y: r.y })), label(p)).toBe(true);
    }
  });

  it('walls are implicit: a room cell next to a corridor without a door is not a step', () => {
    let checked = 0;
    for (const p of PLANS.slice(0, 50)) {
      eachCell(p, (level, x, y) => {
        if (cellAt(p, level, x, y) !== 'room') return;
        for (const [dx, dy] of [
          [1, 0],
          [0, 1],
          [-1, 0],
          [0, -1],
        ] as const) {
          if (cellAt(p, level, x + dx, y + dy) !== 'corridor') continue;
          const door = p.doors.some(
            (d) => d.level === level && ((d.ax === x && d.ay === y && d.bx === x + dx && d.by === y + dy) || (d.bx === x && d.by === y && d.ax === x + dx && d.ay === y + dy)),
          );
          expect(canStep(p, { level, x, y }, { level, x: x + dx, y: y + dy })).toBe(door);
          checked++;
        }
      });
    }
    expect(checked).toBeGreaterThan(1000);
  });

  it('neighbours are symmetric', () => {
    let asymmetric = 0;
    for (const p of PLANS.slice(0, 40)) {
      eachCell(p, (level, x, y) => {
        if (!isWalkable(p, level, x, y)) return;
        const here: Pos = { level, x, y };
        for (const n of neighbours(p, here)) if (!canStep(p, n, here)) asymmetric++;
      });
    }
    expect(asymmetric).toBe(0);
  });
});

describe('clinic: two levels and stairs', () => {
  it('both levels have real content and a stair that paths actually use', () => {
    for (const p of PLANS) {
      for (const level of [0, 1] as const) {
        let walkable = 0;
        eachCell(p, (l, x, y) => {
          if (l === level && isWalkable(p, l, x, y)) walkable++;
        });
        expect(walkable, label(p)).toBeGreaterThan(150);
        expect(p.rooms.filter((r) => r.level === level).length, label(p)).toBeGreaterThanOrEqual(5);
      }
      expect(p.stairs.length).toBeGreaterThanOrEqual(1);
      for (const s of p.stairs) {
        for (const c of stairCells(s)) {
          expect(cellAt(p, 0, c.x, c.y)).toBe('stair');
          expect(cellAt(p, 1, c.x, c.y)).toBe('stair');
        }
        const { bottom, top } = stairEnds(s);
        expect(isWalkable(p, 0, bottom.x, bottom.y)).toBe(true);
        expect(isWalkable(p, 1, top.x, top.y)).toBe(true);
      }
      // Path from the landing to the entity's level-1 start (or any level-1 cell) changes level on a stair.
      const firstStair = p.stairs[0];
      if (!firstStair) throw new Error(`no stair on ${label(p)}`);
      const target: Pos = p.entityStart.level === 1 ? p.entityStart : stairEnds(firstStair).top;
      const path = findPath(p, p.landing, target);
      expect(path, label(p)).not.toBeNull();
      const changes = (path ?? []).flatMap((q, i, all) => {
        const prev = all[i - 1];
        return prev && prev.level !== q.level ? [[prev, q] as const] : [];
      });
      expect(changes.length).toBeGreaterThanOrEqual(1);
      for (const [a, b] of changes) {
        const lower = a.level === 0 ? a : b;
        const upper = a.level === 0 ? b : a;
        const used = p.stairs.some((s) => {
          const cells = stairCells(s);
          const end = cells[cells.length - 1];
          const { top } = stairEnds(s);
          return end?.x === lower.x && end.y === lower.y && top.x === upper.x && top.y === upper.y;
        });
        expect(used, label(p)).toBe(true);
      }
    }
  });
});

describe('clinic: atrium', () => {
  it('has a level-0 atrium open to the sky of level 1, with a balcony beside the opening', () => {
    for (const p of PLANS) {
      const atria = p.rooms.filter((r) => r.kind === 'atrium');
      expect(atria.length, label(p)).toBeGreaterThanOrEqual(1);
      let balcony = 0;
      let wrong = 0;
      for (const a of atria) {
        expect(a.level).toBe(0);
        expect(a.w * a.h).toBeGreaterThanOrEqual(60);
        for (let y = a.y; y < a.y + a.h; y++) {
          for (let x = a.x; x < a.x + a.w; x++) {
            if (cellAt(p, 1, x, y) !== 'atriumOpen') wrong++;
            for (const [dx, dy] of [
              [1, 0],
              [0, 1],
              [-1, 0],
              [0, -1],
            ] as const) {
              if (isWalkable(p, 1, x + dx, y + dy)) balcony++;
            }
          }
        }
      }
      expect(wrong, label(p)).toBe(0);
      expect(balcony, label(p)).toBeGreaterThan(0);
    }
  });
});

describe('clinic: side branches', () => {
  it('every floor has at least two dead-end side branches off the main route, one door in, the same door out', () => {
    for (const p of PLANS) {
      const groups = sideGroups(p);
      expect(groups.length, label(p)).toBeGreaterThanOrEqual(2);
      // Not only single rooms: at least two are suites of two or more rooms.
      expect(groups.filter((g) => g.rooms.length >= 2).length, label(p)).toBeGreaterThanOrEqual(2);
      for (const g of groups) {
        expect(g.exits.length, `${label(p)} group ${g.rooms.join(',')}`).toBe(1);
        const exit = g.exits[0] as Door;
        const ra = roomIdAt(p, exit.level, exit.ax, exit.ay);
        const rb = roomIdAt(p, exit.level, exit.bx, exit.by);
        const outside = g.rooms.includes(ra) ? { x: exit.bx, y: exit.by, id: rb } : { x: exit.ax, y: exit.ay, id: ra };
        const onMain = outside.id < 0 ? cellAt(p, exit.level, outside.x, outside.y) === 'corridor' : p.rooms[outside.id]?.branch === 'main';
        expect(onMain, label(p)).toBe(true);
      }
    }
  });

  it('closing a branch door cuts the branch off (it really is a dead end)', () => {
    for (const p of PLANS.filter((_, i) => i % 8 === 0)) {
      for (const g of sideGroups(p)) {
        const exit = g.exits[0] as Door;
        const cut: FloorPlan = { ...p, doors: p.doors.filter((d) => d !== exit) };
        const seen = reachableFrom(cut, p.landing);
        for (const id of g.rooms) {
          const r = p.rooms[id];
          if (r) expect(seen.has(posIndex(cut, { level: r.level, x: r.x, y: r.y })), label(p)).toBe(false);
        }
      }
    }
  });

  it('main rooms other than the lobby can be walked through: two or more doors', () => {
    for (const p of PLANS) {
      for (const r of p.rooms) {
        if (r.branch !== 'main' || r.kind === 'lobby') continue;
        const doors = p.doors.filter((d) => roomIdAt(p, d.level, d.ax, d.ay) === r.id || roomIdAt(p, d.level, d.bx, d.by) === r.id);
        expect(doors.length, `${label(p)} room ${r.id}`).toBeGreaterThanOrEqual(2);
      }
    }
  });
});

describe('clinic: loops', () => {
  /**
   * Loop definition: on some level, a group of non-corridor cells (8-connected) is completely ringed
   * by corridor, i.e. it does not reach the edge of the grid. Corridor cells are always connected
   * to each other, so a walker can go round it either way: two routes between any two cells on the
   * ring that share no cells. (This ignores the trivial "loops" inside a 2-wide corridor, which
   * enclose nothing.)
   */
  function enclosedIslands(p: FloorPlan, level: Level): number {
    const seen = new Uint8Array(p.width * p.height);
    let islands = 0;
    for (let y = 0; y < p.height; y++) {
      for (let x = 0; x < p.width; x++) {
        const i = y * p.width + x;
        if (seen[i] || cellAt(p, level, x, y) === 'corridor') continue;
        let touchesEdge = false;
        const stack = [i];
        seen[i] = 1;
        while (stack.length > 0) {
          const c = stack.pop() as number;
          const cx = c % p.width;
          const cy = Math.floor(c / p.width);
          if (cx === 0 || cy === 0 || cx === p.width - 1 || cy === p.height - 1) touchesEdge = true;
          for (let dy = -1; dy <= 1; dy++) {
            for (let dx = -1; dx <= 1; dx++) {
              const nx = cx + dx;
              const ny = cy + dy;
              if (nx < 0 || ny < 0 || nx >= p.width || ny >= p.height) continue;
              const n = ny * p.width + nx;
              if (seen[n] || cellAt(p, level, nx, ny) === 'corridor') continue;
              seen[n] = 1;
              stack.push(n);
            }
          }
        }
        if (!touchesEdge) islands++;
      }
    }
    return islands;
  }

  it('every floor has at least one corridor loop', () => {
    for (const p of PLANS) expect(enclosedIslands(p, 0) + enclosedIslands(p, 1), label(p)).toBeGreaterThanOrEqual(1);
  });

  it('the loop really gives two routes: removing any one corridor cell of the ring keeps it connected', () => {
    // Spot check on a few floors: the shortest path between two far ring cells changes but survives
    // when a cell on it is blocked.
    for (const p of PLANS.slice(0, 20)) {
      const s = [...p.sightlines].sort((a, b) => b.length - a.length)[0];
      if (!s) throw new Error('no sightline');
      const a: Pos = { level: s.level, x: s.x1, y: s.y1 };
      const b: Pos = { level: s.level, x: s.x2, y: s.y2 };
      const mid: Pos = { level: s.level, x: Math.floor((s.x1 + s.x2) / 2), y: Math.floor((s.y1 + s.y2) / 2) };
      const cells: [FloorPlan['cells'][0], FloorPlan['cells'][1]] = [[...p.cells[0]], [...p.cells[1]]];
      // Block the whole width of the corridor at the midpoint.
      for (let d = -2; d <= 2; d++) {
        const x = s.x1 === s.x2 ? mid.x + d : mid.x;
        const y = s.x1 === s.x2 ? mid.y : mid.y + d;
        if (cellAt(p, s.level, x, y) === 'corridor') cells[s.level][y * p.width + x] = 'void';
      }
      const blocked: FloorPlan = { ...p, cells, sightlines: [] };
      expect(findPath(blocked, a, b), label(p)).not.toBeNull();
    }
  });
});

describe('clinic: sightlines and the entity start', () => {
  it('has a sightline of 8+ cells, each listed one is a real straight clear corridor run', () => {
    for (const p of PLANS) {
      expect(Math.max(...p.sightlines.map((s) => s.length)), label(p)).toBeGreaterThanOrEqual(8);
      for (const s of p.sightlines) {
        expect(s.x1 === s.x2 || s.y1 === s.y2).toBe(true);
        expect(s.length).toBe(Math.abs(s.x2 - s.x1) + Math.abs(s.y2 - s.y1) + 1);
        const dx = Math.sign(s.x2 - s.x1);
        const dy = Math.sign(s.y2 - s.y1);
        let clear = true;
        for (let i = 0; i < s.length; i++) {
          const x = s.x1 + dx * i;
          const y = s.y1 + dy * i;
          if (cellAt(p, s.level, x, y) !== 'corridor') clear = false;
          if (i > 0 && !canStep(p, { level: s.level, x: x - dx, y: y - dy }, { level: s.level, x, y })) clear = false;
        }
        expect(clear, label(p)).toBe(true);
      }
    }
  });

  it('the entity starts 12+ steps from the landing, on a long sightline', () => {
    for (const p of PLANS) {
      const dist = distancesFrom(p, p.landing);
      expect(dist[posIndex(p, p.entityStart)], label(p)).toBeGreaterThanOrEqual(12);
      expect(p.sightlines.some((s) => s.length >= 8 && onSightline(s, p.entityStart)), label(p)).toBe(true);
    }
  });
});

describe('clinic: sanity bounds', () => {
  it('room count, room placement, doors, corridor width and cell bookkeeping are sane', () => {
    // Problems are collected as text (one expect per floor), because per-cell expects are slow.
    for (const p of PLANS) {
      const bad: string[] = [];
      const fail = (msg: string): void => {
        if (bad.length < 10) bad.push(msg);
      };
      if (p.rooms.length < 12 || p.rooms.length > 40) fail(`room count ${p.rooms.length}`);
      if (p.cells[0].length !== p.width * p.height || p.cells[1].length !== p.width * p.height) fail('cell array size');

      const owner: [Int32Array, Int32Array] = [new Int32Array(p.width * p.height).fill(-1), new Int32Array(p.width * p.height).fill(-1)];
      p.rooms.forEach((r, i) => {
        if (r.id !== i) fail(`room ${i} has id ${r.id}`);
        if (r.x < 0 || r.y < 0 || r.x + r.w > p.width || r.y + r.h > p.height) fail(`room ${i} outside grid`);
        if (Math.min(r.w, r.h) < 2) fail(`room ${i} thinner than 2 cells`);
        for (let y = r.y; y < r.y + r.h; y++) {
          for (let x = r.x; x < r.x + r.w; x++) {
            const o = owner[r.level][y * p.width + x];
            if (o !== -1) fail(`rooms ${o} and ${i} overlap at L${r.level} ${x},${y}`);
            owner[r.level][y * p.width + x] = r.id;
            const k = cellAt(p, r.level, x, y);
            if (k !== 'room' && k !== 'landing') fail(`room ${i} cell ${x},${y} is ${k}`);
          }
        }
      });
      eachCell(p, (level, x, y) => {
        const k = cellAt(p, level, x, y);
        if ((k === 'room' || k === 'landing') && (owner[level][y * p.width + x] ?? -1) < 0) fail(`orphan ${k} cell L${level} ${x},${y}`);
      });
      if (cellAt(p, p.landing.level, p.landing.x, p.landing.y) !== 'landing') fail('landing cell');
      if (p.rooms[roomIdAt(p, p.landing.level, p.landing.x, p.landing.y)]?.kind !== 'lobby') fail('landing not in lobby');
      if (!isWalkable(p, p.entityStart.level, p.entityStart.x, p.entityStart.y)) fail('entity start not walkable');

      for (const d of p.doors) {
        const where = `door L${d.level} ${d.ax},${d.ay}-${d.bx},${d.by}`;
        if (Math.abs(d.ax - d.bx) + Math.abs(d.ay - d.by) !== 1) fail(`${where} not adjacent`);
        if (!isWalkable(p, d.level, d.ax, d.ay) || !isWalkable(p, d.level, d.bx, d.by)) fail(`${where} not walkable`);
        if (!canStep(p, { level: d.level, x: d.ax, y: d.ay }, { level: d.level, x: d.bx, y: d.by })) fail(`${where} not passable`);
      }

      // Corridors are 1 or 2 cells wide: no 3x3 block of corridor anywhere.
      for (const level of [0, 1] as const) {
        for (let y = 0; y + 2 < p.height; y++) {
          for (let x = 0; x + 2 < p.width; x++) {
            let all = true;
            for (let j = 0; j < 9 && all; j++) all = cellAt(p, level, x + (j % 3), y + Math.floor(j / 3)) === 'corridor';
            if (all) fail(`3x3 corridor at L${level} ${x},${y}`);
          }
        }
      }
      expect(bad, label(p)).toEqual([]);
    }
  });

  it('generates a floor in under 50 ms on average', () => {
    const n = 100;
    const t0 = performance.now();
    for (let i = 0; i < n; i++) generateClinic(`speed-${i}`, 1 + (i % 4));
    const avg = (performance.now() - t0) / n;
    expect(avg).toBeLessThan(50);
  });

  it('renders a map with one character per cell', () => {
    const p = PLANS[0] as FloorPlan;
    for (const level of [0, 1] as const) {
      const rows = renderAscii(p, level).split('\n');
      expect(rows.length).toBe(p.height);
      for (const row of rows) expect(row.length).toBe(p.width);
    }
    expect(renderAscii(p, p.landing.level)).toContain('E');
    expect(renderAscii(p, p.entityStart.level)).toContain('X');
  });

  it('rejects grids too small to hold the layout', () => {
    expect(() => generateClinic('tiny', 1, { width: 20, height: 20 })).toThrow(RangeError);
    const wide = generateClinic('wide', 1, { width: 48, height: 36 });
    expect(wide.width).toBe(48);
    expect(reachableFrom(wide, wide.landing).size).toBeGreaterThan(300);
  });
});

describe('src/sim stays pure', () => {
  it('has no Math.random, Date, DOM or three.js under src/sim', () => {
    const root = join(process.cwd(), 'src', 'sim');
    const files: string[] = [];
    const walk = (dir: string): void => {
      for (const name of readdirSync(dir)) {
        const full = join(dir, name);
        if (statSync(full).isDirectory()) walk(full);
        else if (full.endsWith('.ts')) files.push(full);
      }
    };
    walk(root);
    expect(files.length).toBeGreaterThanOrEqual(3);
    for (const f of files) {
      // Comments may mention the forbidden names (rng.ts does, to forbid them); code may not.
      const text = readFileSync(f, 'utf8')
        .replace(/\/\*[\s\S]*?\*\//g, '')
        .replace(/\/\/.*$/gm, '');
      expect(text, f).not.toMatch(/Math\.random/);
      expect(text, f).not.toMatch(/\bnew Date\b|\bDate\.now\b/);
      expect(text, f).not.toMatch(/from ['"]three['"]|\bdocument\.|\bwindow\./);
    }
  });
});
