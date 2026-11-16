// Floor plans: the shared shape every place generator produces, and the pure helpers that bots,
// entities and the renderer use to move around one. A plan is a grid of 2 m cells on two levels.
//
// Walls are implicit. Two edge-adjacent walkable cells on the same level are connected when they
// are in the same room, when both are corridor, or when a Door joins them. Everything else is
// walled off, so rooms packed side by side are separate rooms with a wall between them.
//
// Stairs: a stair occupies the same cells on both levels (kind 'stair' in both grids). A walker on
// a stair counts as being on level 0 until they step off the top. Concretely:
//   - the bottom end is entered from the cell just behind the start, on level 0;
//   - stair cells connect to each other along the stair's axis only (it has side walls);
//   - the last stair cell (level 0) connects to the cell just beyond it on level 1.
// So on level 1 the stair cells are a hole in the floor you look down into, not floor you stand on.
//
// Plans are treated as immutable once generated: a lookup index is cached per plan object.

export type CellKind = 'void' | 'corridor' | 'room' | 'stair' | 'landing' | 'atriumOpen';
export type Level = 0 | 1;
export type Dir = 'n' | 'e' | 's' | 'w';
export type RoomKind = 'ward' | 'exam' | 'station' | 'closet' | 'atrium' | 'lobby';

export interface Room {
  id: number;
  level: Level;
  kind: RoomKind;
  x: number;
  y: number;
  w: number;
  h: number;
  /** 'side' rooms form dead-end groups off the main route; see sideBranches(). */
  branch: 'main' | 'side';
}
/** An opening between two edge-adjacent cells on the same level. */
export interface Door {
  level: Level;
  ax: number;
  ay: number;
  bx: number;
  by: number;
}
/** Starts at (x, y) on the bottom and climbs `length` cells in direction `dir`. */
export interface Stair {
  x: number;
  y: number;
  dir: Dir;
  length: number;
}
export interface Sightline {
  level: Level;
  x1: number;
  y1: number;
  x2: number;
  y2: number;
  /** In cells (multiply by cellSize for metres). Both ends included. */
  length: number;
}
export interface Pos {
  level: Level;
  x: number;
  y: number;
}
export interface FloorPlan {
  place: 'clinic';
  seed: string;
  depth: number;
  width: number;
  height: number;
  cellSize: number;
  /** Per level, row-major, length width*height. */
  cells: [CellKind[], CellKind[]];
  rooms: Room[];
  doors: Door[];
  stairs: Stair[];
  /** Where the elevator opens. The elevator is the only safe place. */
  landing: Pos;
  /** Where the entity begins: far from the landing, on or at the end of a long sightline. */
  entityStart: Pos;
  /** Long straight runs of corridor, so threats can be seen from far away. */
  sightlines: Sightline[];
}

export const DIR_VEC: Readonly<Record<Dir, { dx: number; dy: number }>> = {
  n: { dx: 0, dy: -1 },
  e: { dx: 1, dy: 0 },
  s: { dx: 0, dy: 1 },
  w: { dx: -1, dy: 0 },
};

export function dirFromVec(dx: number, dy: number): Dir {
  if (dx === 0 && dy === -1) return 'n';
  if (dx === 1 && dy === 0) return 'e';
  if (dx === 0 && dy === 1) return 's';
  if (dx === -1 && dy === 0) return 'w';
  throw new Error(`not a unit direction: ${dx},${dy}`);
}

export function inBounds(plan: FloorPlan, x: number, y: number): boolean {
  return x >= 0 && y >= 0 && x < plan.width && y < plan.height;
}

/** Out-of-grid cells read as 'void'. */
export function cellAt(plan: FloorPlan, level: Level, x: number, y: number): CellKind {
  if (!inBounds(plan, x, y)) return 'void';
  return plan.cells[level][y * plan.width + x] ?? 'void';
}

/** Whether someone can stand here. Stair cells count as level 0 only (see the header). */
export function isWalkable(plan: FloorPlan, level: Level, x: number, y: number): boolean {
  const k = cellAt(plan, level, x, y);
  if (k === 'corridor' || k === 'room' || k === 'landing') return true;
  return k === 'stair' && level === 0;
}

/** The cells a stair occupies, bottom first. */
export function stairCells(stair: Stair): { x: number; y: number }[] {
  const v = DIR_VEC[stair.dir];
  const out: { x: number; y: number }[] = [];
  for (let i = 0; i < stair.length; i++) out.push({ x: stair.x + v.dx * i, y: stair.y + v.dy * i });
  return out;
}

/** Level-0 cell you step onto the stair from, and the level-1 cell you step off onto. */
export function stairEnds(stair: Stair): { bottom: Pos; top: Pos } {
  const v = DIR_VEC[stair.dir];
  return {
    bottom: { level: 0, x: stair.x - v.dx, y: stair.y - v.dy },
    top: { level: 1, x: stair.x + v.dx * stair.length, y: stair.y + v.dy * stair.length },
  };
}

// ---------------------------------------------------------------------------------------------
// Lookup index, built once per plan.

interface PlanIndex {
  roomAt: [Int32Array, Int32Array];
  doors: Set<number>;
  stairAt: Int32Array; // level-0 cell -> stair index, or -1
}

const indexCache = new WeakMap<FloorPlan, PlanIndex>();

function doorKey(plan: FloorPlan, level: Level, a: number, b: number): number {
  const n = plan.width * plan.height;
  const lo = Math.min(a, b);
  const hi = Math.max(a, b);
  return (level * n + lo) * n + hi;
}

function indexOf(plan: FloorPlan): PlanIndex {
  const cached = indexCache.get(plan);
  if (cached) return cached;
  const n = plan.width * plan.height;
  const roomAt: [Int32Array, Int32Array] = [new Int32Array(n).fill(-1), new Int32Array(n).fill(-1)];
  for (const r of plan.rooms) {
    for (let y = r.y; y < r.y + r.h; y++) {
      for (let x = r.x; x < r.x + r.w; x++) {
        if (inBounds(plan, x, y)) roomAt[r.level][y * plan.width + x] = r.id;
      }
    }
  }
  const doors = new Set<number>();
  for (const d of plan.doors) {
    doors.add(doorKey(plan, d.level, d.ay * plan.width + d.ax, d.by * plan.width + d.bx));
  }
  const stairAt = new Int32Array(n).fill(-1);
  plan.stairs.forEach((s, i) => {
    for (const c of stairCells(s)) if (inBounds(plan, c.x, c.y)) stairAt[c.y * plan.width + c.x] = i;
  });
  const idx: PlanIndex = { roomAt, doors, stairAt };
  indexCache.set(plan, idx);
  return idx;
}

/** Room id at a cell, or -1. */
export function roomIdAt(plan: FloorPlan, level: Level, x: number, y: number): number {
  if (!inBounds(plan, x, y)) return -1;
  return indexOf(plan).roomAt[level][y * plan.width + x] ?? -1;
}

export function hasDoor(plan: FloorPlan, level: Level, ax: number, ay: number, bx: number, by: number): boolean {
  if (!inBounds(plan, ax, ay) || !inBounds(plan, bx, by)) return false;
  return indexOf(plan).doors.has(doorKey(plan, level, ay * plan.width + ax, by * plan.width + bx));
}

// ---------------------------------------------------------------------------------------------
// Movement.

/** Whether a walker may move from one cell to an edge-adjacent cell (possibly changing level on a stair). */
export function canStep(plan: FloorPlan, from: Pos, to: Pos): boolean {
  const dx = to.x - from.x;
  const dy = to.y - from.y;
  if (Math.abs(dx) + Math.abs(dy) !== 1) return false;
  if (!isWalkable(plan, from.level, from.x, from.y) || !isWalkable(plan, to.level, to.x, to.y)) return false;
  const idx = indexOf(plan);
  const w = plan.width;

  if (from.level !== to.level) {
    const lo = from.level === 0 ? from : to;
    const hi = from.level === 0 ? to : from;
    const s = plan.stairs[idx.stairAt[lo.y * w + lo.x] ?? -1];
    if (!s) return false;
    const v = DIR_VEC[s.dir];
    const endX = s.x + v.dx * (s.length - 1);
    const endY = s.y + v.dy * (s.length - 1);
    return lo.x === endX && lo.y === endY && hi.x === endX + v.dx && hi.y === endY + v.dy;
  }

  const level = from.level;
  const a = from.y * w + from.x;
  const b = to.y * w + to.x;
  const sa = level === 0 ? (idx.stairAt[a] ?? -1) : -1;
  const sb = level === 0 ? (idx.stairAt[b] ?? -1) : -1;
  if (sa >= 0 || sb >= 0) {
    // Two cells of the same straight stair are adjacent only along its axis.
    if (sa >= 0 && sb >= 0) return sa === sb;
    const s = plan.stairs[sa >= 0 ? sa : sb];
    if (!s) return false;
    const onStair = sa >= 0 ? from : to;
    const off = sa >= 0 ? to : from;
    const { bottom } = stairEnds(s);
    return onStair.x === s.x && onStair.y === s.y && off.x === bottom.x && off.y === bottom.y;
  }

  const ra = idx.roomAt[level][a] ?? -1;
  const rb = idx.roomAt[level][b] ?? -1;
  if (ra >= 0 && ra === rb) return true;
  if (plan.cells[level][a] === 'corridor' && plan.cells[level][b] === 'corridor') return true;
  return idx.doors.has(doorKey(plan, level, a, b));
}

const STEPS: readonly (readonly [number, number])[] = [
  [0, -1],
  [1, 0],
  [0, 1],
  [-1, 0],
];

/** Every position reachable in one step, including the level change at a stair. */
export function neighbours(plan: FloorPlan, pos: Pos): Pos[] {
  const out: Pos[] = [];
  for (const level of [pos.level, pos.level === 0 ? 1 : 0] as const) {
    for (const [dx, dy] of STEPS) {
      const to: Pos = { level, x: pos.x + dx, y: pos.y + dy };
      if (canStep(plan, pos, to)) out.push(to);
    }
  }
  return out;
}

/** A position packed into one integer, for sets and arrays. */
export function posIndex(plan: FloorPlan, pos: Pos): number {
  return pos.level * plan.width * plan.height + pos.y * plan.width + pos.x;
}

export function posFromIndex(plan: FloorPlan, index: number): Pos {
  const n = plan.width * plan.height;
  const level: Level = index >= n ? 1 : 0;
  const rest = index - level * n;
  return { level, x: rest % plan.width, y: Math.floor(rest / plan.width) };
}

/** Path-step distance from `from` to every position (indexed by posIndex), -1 if unreachable. */
export function distancesFrom(plan: FloorPlan, from: Pos): Int32Array {
  const dist = new Int32Array(plan.width * plan.height * 2).fill(-1);
  if (!isWalkable(plan, from.level, from.x, from.y)) return dist;
  const queue: Pos[] = [from];
  dist[posIndex(plan, from)] = 0;
  for (let head = 0; head < queue.length; head++) {
    const p = queue[head] as Pos;
    const d = dist[posIndex(plan, p)] ?? 0;
    for (const q of neighbours(plan, p)) {
      const qi = posIndex(plan, q);
      if (dist[qi] !== -1) continue;
      dist[qi] = d + 1;
      queue.push(q);
    }
  }
  return dist;
}

/** Shortest path (BFS), from and to included, or null if there is none. */
export function findPath(plan: FloorPlan, from: Pos, to: Pos): Pos[] | null {
  if (!isWalkable(plan, from.level, from.x, from.y) || !isWalkable(plan, to.level, to.x, to.y)) return null;
  const goal = posIndex(plan, to);
  const prev = new Int32Array(plan.width * plan.height * 2).fill(-2);
  const start = posIndex(plan, from);
  prev[start] = -1;
  const queue: Pos[] = [from];
  for (let head = 0; head < queue.length && prev[goal] === -2; head++) {
    const p = queue[head] as Pos;
    const pi = posIndex(plan, p);
    for (const q of neighbours(plan, p)) {
      const qi = posIndex(plan, q);
      if (prev[qi] !== -2) continue;
      prev[qi] = pi;
      queue.push(q);
    }
  }
  if (prev[goal] === -2) return null;
  const path: Pos[] = [];
  for (let i = goal; i !== -1; i = prev[i] ?? -1) path.push(posFromIndex(plan, i));
  return path.reverse();
}

/** All positions reachable from `pos`, as posIndex values. */
export function reachableFrom(plan: FloorPlan, pos: Pos): Set<number> {
  const dist = distancesFrom(plan, pos);
  const out = new Set<number>();
  dist.forEach((d, i) => {
    if (d >= 0) out.add(i);
  });
  return out;
}

// ---------------------------------------------------------------------------------------------
// Analysis shared by generators and tests.

/**
 * Maximal straight runs of corridor cells at least `minLength` long, per level. Corridor cells are
 * always connected to each other, so a straight run is a clear line of sight down a hall.
 */
export function findSightlines(plan: FloorPlan, minLength: number): Sightline[] {
  const out: Sightline[] = [];
  for (const level of [0, 1] as const) {
    const isCorr = (x: number, y: number): boolean => cellAt(plan, level, x, y) === 'corridor';
    for (let y = 0; y < plan.height; y++) {
      let x = 0;
      while (x < plan.width) {
        if (!isCorr(x, y)) {
          x++;
          continue;
        }
        let e = x;
        while (isCorr(e + 1, y)) e++;
        if (e - x + 1 >= minLength) out.push({ level, x1: x, y1: y, x2: e, y2: y, length: e - x + 1 });
        x = e + 1;
      }
    }
    for (let x = 0; x < plan.width; x++) {
      let y = 0;
      while (y < plan.height) {
        if (!isCorr(x, y)) {
          y++;
          continue;
        }
        let e = y;
        while (isCorr(x, e + 1)) e++;
        if (e - y + 1 >= minLength) out.push({ level, x1: x, y1: y, x2: x, y2: e, length: e - y + 1 });
        y = e + 1;
      }
    }
  }
  return out;
}

export function onSightline(s: Sightline, pos: Pos): boolean {
  return (
    s.level === pos.level &&
    pos.x >= Math.min(s.x1, s.x2) &&
    pos.x <= Math.max(s.x1, s.x2) &&
    pos.y >= Math.min(s.y1, s.y2) &&
    pos.y <= Math.max(s.y1, s.y2)
  );
}

/**
 * Side branches. Definition: treat each room as a node and each door as an edge, with all corridors
 * (and stairs) on both levels merged into one "hall" node. Repeatedly remove any room, other than
 * the lobby and the atrium, that has exactly one door left. The removed rooms are the side rooms; a
 * side branch is a group of side rooms joined to each other by doors. Each group is joined to the
 * rest of the floor by exactly one door, so whoever explores it leaves the way they came in.
 * Returns groups of room ids, each sorted, in order of their smallest id.
 */
export function sideBranches(rooms: readonly Room[], doors: readonly Door[], roomAt: (d: Door, end: 'a' | 'b') => number): number[][] {
  const HALL = -1;
  const edges: [number, number][] = [];
  for (const d of doors) {
    const ra = roomAt(d, 'a');
    const rb = roomAt(d, 'b');
    if (ra === rb) continue;
    edges.push([ra, rb]);
  }
  const degree = new Map<number, number>();
  for (const [a, b] of edges) {
    degree.set(a, (degree.get(a) ?? 0) + 1);
    degree.set(b, (degree.get(b) ?? 0) + 1);
  }
  const protectedRoom = new Set(rooms.filter((r) => r.kind === 'lobby' || r.kind === 'atrium').map((r) => r.id));
  const removed = new Set<number>();
  const alive = edges.map(() => true);
  const queue = rooms.filter((r) => (degree.get(r.id) ?? 0) === 1 && !protectedRoom.has(r.id)).map((r) => r.id);
  while (queue.length > 0) {
    const r = queue.shift() as number;
    if (removed.has(r) || (degree.get(r) ?? 0) !== 1) continue;
    removed.add(r);
    edges.forEach(([a, b], i) => {
      if (!alive[i] || (a !== r && b !== r)) return;
      alive[i] = false;
      const other = a === r ? b : a;
      degree.set(r, 0);
      degree.set(other, (degree.get(other) ?? 0) - 1);
      if (other !== HALL && !removed.has(other) && !protectedRoom.has(other) && degree.get(other) === 1) queue.push(other);
    });
  }
  // Group removed rooms by doors between two removed rooms.
  const parent = new Map<number, number>();
  const find = (x: number): number => {
    let p = parent.get(x) ?? x;
    while (p !== (parent.get(p) ?? p)) p = parent.get(p) ?? p;
    parent.set(x, p);
    return p;
  };
  for (const r of removed) parent.set(r, r);
  for (const [a, b] of edges) if (removed.has(a) && removed.has(b)) parent.set(find(a), find(b));
  const groups = new Map<number, number[]>();
  for (const r of [...removed].sort((p, q) => p - q)) {
    const g = find(r);
    const list = groups.get(g) ?? [];
    list.push(r);
    groups.set(g, list);
  }
  return [...groups.values()].sort((p, q) => (p[0] ?? 0) - (q[0] ?? 0));
}

// ---------------------------------------------------------------------------------------------
// Hashing and debug output.

function stableStringify(v: unknown): string {
  if (v === null || typeof v !== 'object') return JSON.stringify(v) ?? 'null';
  if (Array.isArray(v)) return `[${v.map(stableStringify).join(',')}]`;
  const o = v as Record<string, unknown>;
  return `{${Object.keys(o)
    .sort()
    .map((k) => `${JSON.stringify(k)}:${stableStringify(o[k])}`)
    .join(',')}}`;
}

/** A short stable string that changes if anything in the plan changes. */
export function hashPlan(plan: FloorPlan): string {
  const text = stableStringify(plan);
  let h1 = 0x811c9dc5;
  let h2 = 0x01000193 ^ text.length;
  for (let i = 0; i < text.length; i++) {
    const c = text.charCodeAt(i);
    h1 = Math.imul(h1 ^ c, 16777619);
    h2 = Math.imul(h2 ^ c, 2246822519) + (h2 >>> 13);
  }
  return (h1 >>> 0).toString(16).padStart(8, '0') + (h2 >>> 0).toString(16).padStart(8, '0');
}

const ROOM_CHAR: Readonly<Record<RoomKind, string>> = {
  ward: 'W',
  exam: 'R',
  station: 'N',
  closet: 'C',
  atrium: 'A',
  lobby: 'L',
};

export const ASCII_LEGEND =
  "# void  . corridor  ^>v< stair (points uphill)  o atrium opening  E elevator landing  X entity start  " +
  '+ door (drawn on the room side)  W ward  R exam  N nurses station  C closet  A atrium  L lobby  ' +
  '(neighbouring rooms of the same kind alternate upper/lower case)';

/** A text map of one level, one character per cell, rows separated by newlines. */
export function renderAscii(plan: FloorPlan, level: Level): string {
  const w = plan.width;
  const grid: string[] = new Array<string>(w * plan.height).fill('#');
  const rooms = plan.rooms.filter((r) => r.level === level);

  // Same-kind neighbours get opposite case, so packed rooms read as separate rooms.
  const lower = new Map<number, boolean>();
  for (const r of rooms) {
    const used = new Set<boolean>();
    for (const o of rooms) {
      if (o.id === r.id || o.kind !== r.kind || !lower.has(o.id)) continue;
      const touch = o.x <= r.x + r.w && r.x <= o.x + o.w && o.y <= r.y + r.h && r.y <= o.y + o.h;
      if (touch) used.add(lower.get(o.id) === true);
    }
    lower.set(r.id, used.has(false) && !used.has(true));
  }

  for (let i = 0; i < w * plan.height; i++) {
    const k = plan.cells[level][i];
    if (k === 'corridor') grid[i] = '.';
    else if (k === 'atriumOpen') grid[i] = 'o';
  }
  for (const r of rooms) {
    const c = lower.get(r.id) ? ROOM_CHAR[r.kind].toLowerCase() : ROOM_CHAR[r.kind];
    for (let y = r.y; y < r.y + r.h; y++) for (let x = r.x; x < r.x + r.w; x++) grid[y * w + x] = c;
  }
  const arrow: Record<Dir, string> = { n: '^', e: '>', s: 'v', w: '<' };
  for (const s of plan.stairs) for (const c of stairCells(s)) grid[c.y * w + c.x] = arrow[s.dir];
  for (const d of plan.doors) {
    if (d.level !== level) continue;
    // Draw on the room side; for room-to-room doors, on the later (inner) room.
    const ra = roomIdAt(plan, level, d.ax, d.ay);
    const rb = roomIdAt(plan, level, d.bx, d.by);
    const useB = rb > ra;
    grid[(useB ? d.by : d.ay) * w + (useB ? d.bx : d.ax)] = '+';
  }
  if (plan.landing.level === level) grid[plan.landing.y * w + plan.landing.x] = 'E';
  if (plan.entityStart.level === level) grid[plan.entityStart.y * w + plan.entityStart.x] = 'X';
  const rows: string[] = [];
  for (let y = 0; y < plan.height; y++) rows.push(grid.slice(y * w, (y + 1) * w).join(''));
  return rows.join('\n');
}
