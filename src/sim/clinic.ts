// The Clinic: a sterile, brightly lit hospital floor on two levels.
//
// Constructive, cannot fail. In a canonical orientation (stair band to the north), it:
//   1. lays a rectangular ring of long straight corridors on level 0, with a cross corridor through
//      the middle, so the corridor graph has loops and long sight lines;
//   2. fills one half of the ring's interior with the atrium (two storeys tall) and puts the nurses'
//      station in the other half;
//   3. places the elevator lobby off the south side of the ring, and one or two stairs climbing north
//      out of the ring to an upper hall on level 1;
//   4. copies the ring onto level 1 as a gallery round the atrium opening (the balcony), joined to
//      the upper hall by two connectors;
//   5. hangs rooms off every corridor run, packed side by side, including a few two- or three-room
//      suites that are reached through one door (the side branches);
// then rotates or mirrors the whole plan by a seeded symmetry so floors do not all face one way.
//
// Each stage draws from its own fork of the seed, so adding a draw in one stage does not reshuffle
// the others.

import { makeRng, type Rng } from './rng';
import {
  dirFromVec,
  distancesFrom,
  findSightlines,
  posIndex,
  sideBranches,
  stairCells,
  type CellKind,
  type Door,
  type FloorPlan,
  type Level,
  type Pos,
  type Room,
  type RoomKind,
  type Stair,
} from './floor';

const CELL_SIZE = 2;
const MARGIN = 1;
const STAIR_LENGTH = 4;
/** North band: stair, then the upper hall on level 1, then a row of 3-deep rooms beyond it. */
const NORTH_BAND = STAIR_LENGTH + 4;
const MIN_SIGHTLINE = 8;
const ENTITY_MIN_STEPS = 12;
const BASE_SIZE = 36;

export interface ClinicOptions {
  width?: number;
  height?: number;
}

/** Default grid size grows with depth, so deeper floors are larger. */
export function clinicSize(depth: number): { width: number; height: number } {
  const s = BASE_SIZE + 2 * Math.min(Math.max(depth, 1) - 1, 4);
  return { width: s, height: s };
}

// ---------------------------------------------------------------------------------------------
// Building state.

interface Builder {
  w: number;
  h: number;
  cells: [CellKind[], CellKind[]];
  reserved: [Uint8Array, Uint8Array];
  rooms: Room[];
  /** Rooms the fillers may still add. Fixed rooms (atrium, lobby, ...) do not draw on it. */
  budget: number;
  doors: Door[];
  stairs: Stair[];
}

function shuffled<T>(rng: Rng, items: readonly T[]): T[] {
  const out = [...items];
  for (let i = out.length - 1; i > 0; i--) {
    const j = rng.int(0, i);
    [out[i], out[j]] = [out[j] as T, out[i] as T];
  }
  return out;
}

function newBuilder(w: number, h: number): Builder {
  return {
    w,
    h,
    cells: [new Array<CellKind>(w * h).fill('void'), new Array<CellKind>(w * h).fill('void')],
    reserved: [new Uint8Array(w * h), new Uint8Array(w * h)],
    rooms: [],
    doors: [],
    stairs: [],
    budget: Number.POSITIVE_INFINITY,
  };
}

function isFree(b: Builder, level: Level, x: number, y: number): boolean {
  if (x < MARGIN || y < MARGIN || x >= b.w - MARGIN || y >= b.h - MARGIN) return false;
  const i = y * b.w + x;
  return b.cells[level][i] === 'void' && b.reserved[level][i] === 0;
}

function kindAt(b: Builder, level: Level, x: number, y: number): CellKind {
  if (x < 0 || y < 0 || x >= b.w || y >= b.h) return 'void';
  return b.cells[level][y * b.w + x] ?? 'void';
}

function setCell(b: Builder, level: Level, x: number, y: number, k: CellKind): void {
  b.cells[level][y * b.w + x] = k;
}

function carve(b: Builder, level: Level, x: number, y: number, w: number, h: number, k: CellKind): void {
  for (let yy = y; yy < y + h; yy++) for (let xx = x; xx < x + w; xx++) setCell(b, level, xx, yy, k);
}

function addRoom(b: Builder, level: Level, kind: RoomKind, x: number, y: number, w: number, h: number): Room {
  const room: Room = { id: b.rooms.length, level, kind, x, y, w, h, branch: 'main' };
  b.budget--;
  b.rooms.push(room);
  carve(b, level, x, y, w, h, 'room');
  return room;
}

function addDoor(b: Builder, level: Level, ax: number, ay: number, bx: number, by: number): void {
  b.doors.push({ level, ax, ay, bx, by });
}

// ---------------------------------------------------------------------------------------------
// Hanging rooms off a corridor run.

/**
 * A straight run of corridor cells: along `line` (a row for 'h', a column for 'v'), from `from` to
 * `to` inclusive. Rooms go on one side of it; layer 0 is the corridor, layer k is k cells out.
 */
interface Run {
  axis: 'h' | 'v';
  line: number;
  from: number;
  to: number;
  side: 1 | -1;
}

function runCell(run: Run, along: number, layer: number): { x: number; y: number } {
  const across = run.line + run.side * layer;
  return run.axis === 'h' ? { x: along, y: across } : { x: across, y: along };
}

/** Rect covering `width` cells along the run and layers [layer0+1, layer0+depth]. */
function runRect(run: Run, along: number, width: number, layer0: number, depth: number) {
  const a = runCell(run, along, layer0 + 1);
  const c = runCell(run, along + width - 1, layer0 + depth);
  return { x: Math.min(a.x, c.x), y: Math.min(a.y, c.y), w: Math.abs(c.x - a.x) + 1, h: Math.abs(c.y - a.y) + 1 };
}

function layerFree(b: Builder, level: Level, run: Run, along: number, width: number, layer: number): boolean {
  for (let i = 0; i < width; i++) {
    const c = runCell(run, along + i, layer);
    if (!isFree(b, level, c.x, c.y)) return false;
  }
  return true;
}

function roomKindFor(w: number, d: number): RoomKind {
  if (Math.min(w, d) >= 4 && w * d >= 24) return 'ward';
  if (w * d <= 6) return 'closet';
  return 'exam';
}

interface FillOptions {
  maxDepth: number;
  /** Suites that must be placed as soon as there is room for one. */
  forceSuites?: number;
  suiteChance?: number;
  /** Chance of leaving a stretch of blank wall instead of the next room. */
  gapChance?: number;
}

/**
 * Packs rooms along one side of a run, each with a door onto the corridor. Some stretches are left
 * as blank wall: long featureless walls are part of the place, and they keep the room count sane.
 * Returns the number of suites placed.
 */
function fillAlong(b: Builder, rng: Rng, level: Level, run: Run, opts: FillOptions): number {
  let suitesToForce = opts.forceSuites ?? 0;
  let suites = 0;
  let pos = run.from;
  while (pos <= run.to) {
    // How wide a room could start here (it needs at least two free layers).
    let span = 0;
    while (pos + span <= run.to && span < 12 && layerFree(b, level, run, pos + span, 1, 1) && layerFree(b, level, run, pos + span, 1, 2)) {
      span++;
    }
    if (span < 2) {
      pos++;
      continue;
    }
    if (suitesToForce === 0 && rng.chance(opts.gapChance ?? 0)) {
      pos += rng.int(3, 8);
      continue;
    }
    let dmax = 0;
    while (dmax < opts.maxDepth && layerFree(b, level, run, pos, Math.min(span, 3), dmax + 1)) dmax++;

    // Choose what goes here, then how wide it is.
    const wantSuite = suitesToForce > 0 || rng.chance(opts.suiteChance ?? 0) || (dmax >= 6 && rng.chance(0.4));
    let kind: 'ward' | 'suite' | 'small';
    if (suitesToForce === 0 && span >= 6 && dmax >= 4 && rng.chance(0.25)) kind = 'ward';
    else if (wantSuite && dmax >= 5 && span >= 3) kind = 'suite';
    else kind = 'small';
    let w = kind === 'ward' ? rng.int(6, Math.min(12, span)) : kind === 'suite' ? rng.int(3, Math.min(6, span)) : rng.int(Math.min(3, span), Math.min(6, span));
    if (span - w === 1) w = w >= 4 ? w - 1 : w + 1; // never strand a 1-cell gap
    w = Math.min(w, span);
    let d = 0;
    while (d < opts.maxDepth && layerFree(b, level, run, pos, w, d + 1)) d++;
    if (d < 2) {
      pos++;
      continue;
    }

    if (suitesToForce === 0 && b.budget < (kind === 'suite' ? 3 : 1)) return suites;
    if (kind === 'suite' && d >= 5) {
      placeSuite(b, rng, level, run, pos, w, d);
      suitesToForce = Math.max(0, suitesToForce - 1);
      suites++;
      pos += w;
      continue;
    }

    // Small rooms stay small; wards take the full depth.
    const depth = kind === 'ward' ? Math.min(d, 8) : Math.min(d, rng.int(3, 5), 2 * w);
    const r = runRect(run, pos, w, 0, depth);
    const roomKind = kind === 'ward' && depth >= 4 ? 'ward' : roomKindFor(Math.min(w, 5), Math.min(depth, 4));
    addRoom(b, level, roomKind, r.x, r.y, r.w, r.h);
    // Wards are walk-through: two doors, so they sit on the main route rather than off it.
    const offsets = roomKind === 'ward' ? [1, w - 2] : [rng.int(0, w - 1)];
    for (const o of offsets) {
      const inner = runCell(run, pos + o, 1);
      const outer = runCell(run, pos + o, 0);
      addDoor(b, level, outer.x, outer.y, inner.x, inner.y);
    }
    pos += w;
  }
  return suites;
}

/** A front room on the corridor with one or two rooms behind it, reached only through it. */
function placeSuite(b: Builder, rng: Rng, level: Level, run: Run, pos: number, w: number, dmax: number): void {
  const df = rng.int(2, Math.min(4, dmax - 2));
  const db = Math.min(dmax - df, 4);
  const fr = runRect(run, pos, w, 0, df);
  // Suites are consulting rooms with stores or offices behind; never wards, which are walk-through.
  const notWard = (k: RoomKind): RoomKind => (k === 'ward' ? 'exam' : k);
  addRoom(b, level, notWard(roomKindFor(w, df)), fr.x, fr.y, fr.w, fr.h);
  const along = pos + rng.int(0, w - 1);
  const inner = runCell(run, along, 1);
  const outer = runCell(run, along, 0);
  addDoor(b, level, outer.x, outer.y, inner.x, inner.y);

  const half = Math.floor(w / 2);
  const backs: [number, number][] = w >= 5 && rng.chance(0.5) ? [[0, half], [half, w - half]] : [[0, w]];
  for (const [off, bw] of backs) {
    const br = runRect(run, pos + off, bw, df, db);
    addRoom(b, level, notWard(roomKindFor(bw, db)), br.x, br.y, br.w, br.h);
    const o = pos + off + rng.int(0, bw - 1);
    const front = runCell(run, o, df);
    const back = runCell(run, o, df + 1);
    addDoor(b, level, front.x, front.y, back.x, back.y);
  }
}

/**
 * Fills the block between two north-south halls (columns xl and xr), rows y0..y1. One full-width
 * ward cuts across it with a door onto each hall (a walk-through room on the main route, the kind
 * you take as a shortcut); the rest is smaller rooms backing onto each other from either hall.
 */
function fillBlock(b: Builder, rng: Rng, level: Level, xl: number, xr: number, y0: number, y1: number, gap: number): void {
  const bw = xr - xl - 1;
  const span = y1 - y0 + 1;
  if (span >= 4 && bw >= 4 && b.budget >= 1) {
    const hgt = rng.int(4, Math.min(7, span));
    const y = rng.pick([y0, y1 - hgt + 1, y0 + Math.floor((span - hgt) / 2)]);
    addRoom(b, level, bw * hgt >= 24 ? 'ward' : 'exam', xl + 1, y, bw, hgt);
    const wy = y + rng.int(0, hgt - 1);
    const ey = y + rng.int(0, hgt - 1);
    addDoor(b, level, xl, wy, xl + 1, wy);
    addDoor(b, level, xr, ey, xr - 1, ey);
  }
  const half = Math.ceil(bw / 2);
  fillAlong(b, rng, level, { axis: 'v', line: xl, from: y0, to: y1, side: 1 }, { gapChance: gap, maxDepth: rng.chance(0.5) ? half : bw });
  fillAlong(b, rng, level, { axis: 'v', line: xr, from: y0, to: y1, side: -1 }, { gapChance: gap, maxDepth: bw });
}

// ---------------------------------------------------------------------------------------------
// Layout.

interface Ring {
  x0: number;
  x1: number;
  y0: number;
  y1: number;
  wN: number;
  wS: number;
  wW: number;
  wE: number;
}

function interiorOf(r: Ring) {
  return { ix0: r.x0 + r.wW, ix1: r.x1 - r.wE, iy0: r.y0 + r.wN, iy1: r.y1 - r.wS };
}

function carveRing(b: Builder, level: Level, r: Ring): void {
  carve(b, level, r.x0, r.y0, r.x1 - r.x0 + 1, r.wN, 'corridor');
  carve(b, level, r.x0, r.y1 - r.wS + 1, r.x1 - r.x0 + 1, r.wS, 'corridor');
  carve(b, level, r.x0, r.y0, r.wW, r.y1 - r.y0 + 1, 'corridor');
  carve(b, level, r.x1 - r.wE + 1, r.y0, r.wE, r.y1 - r.y0 + 1, 'corridor');
}

/** Runs along the outside and inside faces of each ring side. */
function ringRuns(r: Ring) {
  const { ix0, ix1, iy0, iy1 } = interiorOf(r);
  return {
    northOut: { axis: 'h', line: r.y0, from: r.x0, to: r.x1, side: -1 } as Run,
    southOut: { axis: 'h', line: r.y1, from: r.x0, to: r.x1, side: 1 } as Run,
    westOut: { axis: 'v', line: r.x0, from: r.y0, to: r.y1, side: -1 } as Run,
    eastOut: { axis: 'v', line: r.x1, from: r.y0, to: r.y1, side: 1 } as Run,
    northIn: (from: number, to: number): Run => ({ axis: 'h', line: iy0 - 1, from, to, side: 1 }),
    southIn: (from: number, to: number): Run => ({ axis: 'h', line: iy1 + 1, from, to, side: -1 }),
    eastIn: { axis: 'v', line: ix1 + 1, from: iy0, to: iy1, side: -1 } as Run,
    westIn: { axis: 'v', line: ix0 - 1, from: iy0, to: iy1, side: 1 } as Run,
  };
}

interface Canonical {
  b: Builder;
  landing: Pos;
}

function layOut(seed: string, depth: number, W: number, H: number): Canonical {
  const root = makeRng(`clinic:${seed}:${depth}`);
  const shape = root.fork('shape');
  const b = newBuilder(W, H);

  // --- Ring of main halls. Bands outside the ring hold rooms; the north band also holds the stairs.
  const usableW = W - 2 * MARGIN;
  const usableH = H - 2 * MARGIN;
  const bandSumMax = usableW - 19; // keeps the ring at least 19 wide, its interior at least 15
  const bW = shape.int(4, Math.min(8, bandSumMax - 4));
  const bE = shape.int(4, Math.min(8, bandSumMax - bW));
  const bS = shape.int(4, Math.min(8, usableH - NORTH_BAND - 17));
  const ring: Ring = {
    x0: MARGIN + bW,
    x1: W - 1 - MARGIN - bE,
    y0: MARGIN + NORTH_BAND,
    y1: H - 1 - MARGIN - bS,
    wN: shape.chance(0.5) ? 2 : 1,
    wS: shape.chance(0.5) ? 2 : 1,
    wW: shape.chance(0.4) ? 2 : 1,
    wE: shape.chance(0.4) ? 2 : 1,
  };
  const { ix0, ix1, iy0, iy1 } = interiorOf(ring);
  const iw = ix1 - ix0 + 1;
  const ih = iy1 - iy0 + 1;

  // --- Cross corridor splits the interior: atrium on one side, station and rooms on the other.
  const aw = shape.int(8, Math.min(12, iw - 6));
  const cx = ix0 + aw;
  const strip = ih >= 13 && shape.chance(0.5) ? shape.int(3, Math.min(5, ih - 10)) : 0;
  // A wide far half gets a second cross corridor: another loop, and blocks no deeper than a ward.
  const far = ix1 - cx;
  const cx2 = far >= 13 ? cx + 1 + shape.int(6, far - 7) : 0;

  for (const level of [0, 1] as const) {
    carveRing(b, level, ring);
    carve(b, level, cx, iy0, 1, ih, 'corridor');
    if (cx2 > 0) carve(b, level, cx2, iy0, 1, ih, 'corridor');
  }

  // Atrium: a room on level 0, an opening on level 1 with the gallery running round it.
  const atrium = addRoom(b, 0, 'atrium', ix0, iy0, aw, ih - strip);
  carve(b, 1, atrium.x, atrium.y, atrium.w, atrium.h, 'atriumOpen');
  const doorRows = [atrium.y + 1 + shape.int(0, Math.floor(atrium.h / 3)), atrium.y + atrium.h - 2 - shape.int(0, Math.floor(atrium.h / 3))];
  for (const y of doorRows) addDoor(b, 0, ix0 - 1, y, ix0, y);
  addDoor(b, 0, cx, atrium.y + Math.floor(atrium.h / 2), cx - 1, atrium.y + Math.floor(atrium.h / 2));
  const nx = atrium.x + shape.int(1, atrium.w - 2);
  addDoor(b, 0, nx, iy0 - 1, nx, iy0);

  // Nurses' station: at the head of the other half, opening onto both the north hall and the cross.
  const bw = (cx2 > 0 ? cx2 : ix1 + 1) - cx - 1;
  const sw = Math.min(bw, shape.int(4, 6));
  const sh = shape.int(3, 4);
  addRoom(b, 0, 'station', cx + 1, iy0, sw, sh);
  const stx = cx + 1 + shape.int(0, sw - 1);
  addDoor(b, 0, stx, iy0 - 1, stx, iy0);
  const sy = iy0 + shape.int(0, sh - 1);
  addDoor(b, 0, cx, sy, cx + 1, sy);

  // --- Elevator lobby off the south hall. Two doors, so it is not a dead end.
  const lw = 5;
  const ld = Math.min(bS, 4);
  const lx = shape.int(ring.x0 + 2, ring.x1 - 2 - lw);
  const lobby = addRoom(b, 0, 'lobby', lx, ring.y1 + 1, lw, ld);
  addDoor(b, 0, lx, ring.y1, lx, ring.y1 + 1);
  addDoor(b, 0, lx + lw - 1, ring.y1, lx + lw - 1, ring.y1 + 1);
  const landing: Pos = { level: 0, x: lx + Math.floor(lw / 2), y: lobby.y + lobby.h - 1 };
  setCell(b, 0, landing.x, landing.y, 'landing');
  b.reserved[1][landing.y * W + landing.x] = 1; // elevator shaft

  // --- Stairs climb north out of the ring to the upper hall on level 1.
  const stairRng = root.fork('stairs');
  const twoStairs = stairRng.chance(Math.min(0.9, 0.35 + 0.2 * depth)) && ring.x1 - ring.x0 >= 18;
  const span = ring.x1 - ring.x0;
  const stairXs = twoStairs
    ? [stairRng.int(ring.x0 + 3, ring.x0 + Math.floor(span / 2) - 3), stairRng.int(ring.x0 + Math.floor(span / 2) + 3, ring.x1 - 3)]
    : [stairRng.int(ring.x0 + 3, ring.x1 - 3)];
  for (const sx of stairXs) {
    const stair: Stair = { x: sx, y: ring.y0 - 1, dir: 'n', length: STAIR_LENGTH };
    b.stairs.push(stair);
    for (const c of stairCells(stair)) {
      setCell(b, 0, c.x, c.y, 'stair');
      setCell(b, 1, c.x, c.y, 'stair');
    }
  }
  const hallY = ring.y0 - STAIR_LENGTH - 1;
  carve(b, 1, ring.x0, hallY, ring.x1 - ring.x0 + 1, 1, 'corridor');
  carve(b, 1, ring.x0, hallY, 1, ring.y0 - hallY, 'corridor');
  carve(b, 1, ring.x1, hallY, 1, ring.y0 - hallY, 'corridor');

  // --- Rooms. Level 0 first, then level 1, each from its own fork.
  const runs = ringRuns(ring);
  const deeper = Math.max(0, depth - 1);
  const gap = 0.35 + 0.03 * deeper;
  // A room budget keeps every floor in a sane range however big the grid gets: runs filled later
  // run out and are left as blank wall. Run order is shuffled so it is not always the same side.
  const maxRooms = Math.min(40, 32 + 3 * depth);
  const r0 = root.fork('rooms0');
  b.budget = Math.floor(maxRooms * 0.6) - b.rooms.length;
  fillAlong(b, r0, 0, runs.northOut, { gapChance: gap, maxDepth: NORTH_BAND, forceSuites: 2, suiteChance: 0.3 + 0.1 * deeper });
  fillBlock(b, r0, 0, cx, cx2 > 0 ? cx2 : ix1 + 1, iy0 + sh, iy1, gap);
  if (cx2 > 0) fillBlock(b, r0, 0, cx2, ix1 + 1, iy0, iy1, gap);
  const lower: [Run, FillOptions][] = [
    [runs.southOut, { gapChance: gap, maxDepth: bS, suiteChance: 0.15 * deeper }],
    [runs.westOut, { gapChance: gap, maxDepth: bW, suiteChance: 0.2 + 0.1 * deeper }],
    [runs.eastOut, { gapChance: gap, maxDepth: bE, suiteChance: 0.2 + 0.1 * deeper }],
  ];
  if (strip > 0) lower.push([runs.southIn(ix0, cx - 1), { gapChance: gap, maxDepth: strip }]);
  for (const [run, o] of shuffled(r0, lower)) fillAlong(b, r0, 0, run, o);

  const r1 = root.fork('rooms1');
  b.budget = maxRooms - b.rooms.length;
  fillBlock(b, r1, 1, cx, cx2 > 0 ? cx2 : ix1 + 1, iy0, iy1, gap);
  if (cx2 > 0) fillBlock(b, r1, 1, cx2, ix1 + 1, iy0, iy1, gap);
  const hallRun: Run = { axis: 'h', line: hallY, from: ring.x0, to: ring.x1, side: -1 };
  fillAlong(b, r1, 1, { ...hallRun, from: ring.x0 + 1, to: ring.x1 - 1, side: 1 }, { gapChance: gap, maxDepth: STAIR_LENGTH });
  const upper: [Run, FillOptions][] = [[hallRun, { gapChance: gap, maxDepth: hallY - MARGIN }]];
  if (strip > 0) upper.push([runs.southIn(ix0, cx - 1), { gapChance: gap, maxDepth: strip }]);
  // The upper storey is smaller than the lower: each outer wing is built only some of the time.
  const wings = root.fork('wings');
  const westUp = wings.chance(0.6);
  const eastUp = wings.chance(westUp ? 0.5 : 1);
  if (westUp) upper.push([{ axis: 'v', line: ring.x0, from: hallY, to: ring.y1, side: -1 }, { gapChance: gap, maxDepth: bW, suiteChance: 0.25 }]);
  if (eastUp) upper.push([{ axis: 'v', line: ring.x1, from: hallY, to: ring.y1, side: 1 }, { gapChance: gap, maxDepth: bE, suiteChance: 0.25 }]);
  if (wings.chance(0.25 + 0.1 * deeper)) upper.push([runs.southOut, { gapChance: gap, maxDepth: bS }]);
  for (const [run, o] of shuffled(r1, upper)) fillAlong(b, r1, 1, run, o);

  return { b, landing };
}

// ---------------------------------------------------------------------------------------------
// Orientation: one of the grid's symmetries, applied to everything.

type Xf = (x: number, y: number) => [number, number];

function symmetries(W: number, H: number): Xf[] {
  const flips: Xf[] = [
    (x, y) => [x, y],
    (x, y) => [W - 1 - x, y],
    (x, y) => [x, H - 1 - y],
    (x, y) => [W - 1 - x, H - 1 - y],
  ];
  if (W !== H) return flips;
  return [...flips, (x, y) => [y, x], (x, y) => [W - 1 - y, x], (x, y) => [y, H - 1 - x], (x, y) => [W - 1 - y, H - 1 - x]];
}

function transform(b: Builder, landing: Pos, f: Xf): { b: Builder; landing: Pos } {
  const out = newBuilder(b.w, b.h);
  for (const level of [0, 1] as const) {
    for (let y = 0; y < b.h; y++) {
      for (let x = 0; x < b.w; x++) {
        const [nx, ny] = f(x, y);
        setCell(out, level, nx, ny, kindAt(b, level, x, y));
      }
    }
  }
  out.rooms = b.rooms.map((r) => {
    const [ax, ay] = f(r.x, r.y);
    const [cx, cy] = f(r.x + r.w - 1, r.y + r.h - 1);
    return { ...r, x: Math.min(ax, cx), y: Math.min(ay, cy), w: Math.abs(cx - ax) + 1, h: Math.abs(cy - ay) + 1 };
  });
  out.doors = b.doors.map((d) => {
    const [ax, ay] = f(d.ax, d.ay);
    const [bx, by] = f(d.bx, d.by);
    return { level: d.level, ax, ay, bx, by };
  });
  out.stairs = b.stairs.map((s) => {
    const [x, y] = f(s.x, s.y);
    const v = { n: [0, -1], e: [1, 0], s: [0, 1], w: [-1, 0] }[s.dir] as [number, number];
    const [x2, y2] = f(s.x + v[0], s.y + v[1]);
    return { x, y, dir: dirFromVec(x2 - x, y2 - y), length: s.length };
  });
  const [lx, ly] = f(landing.x, landing.y);
  return { b: out, landing: { level: landing.level, x: lx, y: ly } };
}

// ---------------------------------------------------------------------------------------------

export function generateClinic(seed: string, depth: number, opts: ClinicOptions = {}): FloorPlan {
  const size = clinicSize(depth);
  const W = opts.width ?? size.width;
  const H = opts.height ?? size.height;
  if (W < 32 || H < 32) throw new RangeError(`clinic needs at least 32x32 cells, got ${W}x${H}`);

  const canon = layOut(seed, depth, W, H);
  const syms = symmetries(W, H);
  const pick = makeRng(`clinic:${seed}:${depth}`).fork('orient').int(0, syms.length - 1);
  const { b, landing } = transform(canon.b, canon.landing, syms[pick] as Xf);

  const plan: FloorPlan = {
    place: 'clinic',
    seed,
    depth,
    width: W,
    height: H,
    cellSize: CELL_SIZE,
    cells: b.cells,
    rooms: b.rooms,
    doors: b.doors,
    stairs: b.stairs,
    landing,
    entityStart: landing,
    sightlines: [],
  };

  // Side branches: mark every room in a dead-end group.
  const roomAt = (d: Door, end: 'a' | 'b'): number => {
    const x = end === 'a' ? d.ax : d.bx;
    const y = end === 'a' ? d.ay : d.by;
    const r = b.rooms.find((rr) => rr.level === d.level && x >= rr.x && x < rr.x + rr.w && y >= rr.y && y < rr.y + rr.h);
    return r ? r.id : -1;
  };
  for (const group of sideBranches(b.rooms, b.doors, roomAt)) {
    for (const id of group) {
      const r = b.rooms[id];
      if (r) r.branch = 'side';
    }
  }

  plan.sightlines = findSightlines(plan, MIN_SIGHTLINE);
  plan.entityStart = chooseEntityStart(plan, makeRng(`clinic:${seed}:${depth}`).fork('entity'));
  return plan;
}

/**
 * The entity starts at the far end of a long hall, at least ENTITY_MIN_STEPS from the landing, so
 * the crew can see it down the corridor before it can reach them. Ends of sightlines are preferred;
 * among them, one of the farthest from the landing.
 */
function chooseEntityStart(plan: FloorPlan, rng: Rng): Pos {
  const dist = distancesFrom(plan, plan.landing);
  const steps = (p: Pos): number => dist[posIndex(plan, p)] ?? -1;
  let candidates: Pos[] = [];
  for (const s of plan.sightlines) {
    candidates.push({ level: s.level, x: s.x1, y: s.y1 }, { level: s.level, x: s.x2, y: s.y2 });
  }
  candidates = candidates.filter((p) => steps(p) >= ENTITY_MIN_STEPS);
  if (candidates.length === 0) {
    // Not expected with this layout; fall back to the farthest point on any sightline.
    for (const s of plan.sightlines) {
      for (let x = Math.min(s.x1, s.x2); x <= Math.max(s.x1, s.x2); x++) {
        for (let y = Math.min(s.y1, s.y2); y <= Math.max(s.y1, s.y2); y++) candidates.push({ level: s.level, x, y });
      }
    }
  }
  if (candidates.length === 0) return plan.landing;
  const far = Math.max(...candidates.map(steps));
  const pool = candidates.filter((p) => steps(p) >= far * 0.8);
  return rng.pick(pool);
}
