// Per-area tints, multiplied over the textures through vertex colours. Small shifts, enough that a
// ward, an exam room and the nurses' station do not look like the same box.

import * as THREE from 'three';
import { cellAt, roomIdAt, type FloorPlan, type Level, type RoomKind } from '../sim/floor';
import type { RGB } from './geoBuilder';

export type Area = RoomKind | 'corridor';

interface Tint {
  wall: number;
  floor: number;
}

const TINTS: Record<Area, Tint> = {
  corridor: { wall: 0xffffff, floor: 0xffffff },
  ward: { wall: 0xe8f0ff, floor: 0xf4f7ff },
  exam: { wall: 0xe6fff0, floor: 0xffffff },
  station: { wall: 0xfff3dc, floor: 0xfaf0e0 },
  closet: { wall: 0xc8cbc6, floor: 0xbcbfb9 },
  lobby: { wall: 0xfff7ea, floor: 0xc9d0d6 },
  // The atrium floor is a shade darker and greener, so from the balcony the drop reads at once.
  atrium: { wall: 0xf4ffff, floor: 0xcfe3d8 },
};

/** Linear RGB for vertex colours (THREE.Color converts from sRGB hex). */
export function rgb(hex: number): RGB {
  const c = new THREE.Color(hex);
  return [c.r, c.g, c.b];
}

export function scale(c: RGB, k: number): RGB {
  return [c[0] * k, c[1] * k, c[2] * k];
}

const wallTint = new Map<Area, RGB>();
const floorTint = new Map<Area, RGB>();
for (const [area, t] of Object.entries(TINTS) as [Area, Tint][]) {
  wallTint.set(area, rgb(t.wall));
  floorTint.set(area, rgb(t.floor));
}

/** What kind of space a cell is, for tinting. */
export function areaAt(plan: FloorPlan, level: Level, x: number, y: number): Area {
  const id = roomIdAt(plan, level, x, y);
  const room = id >= 0 ? plan.rooms[id] : undefined;
  if (room) return room.kind;
  if (cellAt(plan, level, x, y) === 'atriumOpen') return 'atrium';
  return 'corridor';
}

export function wallColour(area: Area): RGB {
  return wallTint.get(area) ?? [1, 1, 1];
}

export function floorColour(area: Area): RGB {
  return floorTint.get(area) ?? [1, 1, 1];
}

/** Fittings: door frames, rails, stairs, the elevator. */
export const TRIM = {
  doorFrame: rgb(0x8fa89a),
  railPost: rgb(0x9aa3a6),
  railCap: rgb(0x6f8a7c),
  railKick: rgb(0xd8dcd6),
  stepTread: rgb(0xd9ddd8),
  stepNose: rgb(0x55605a),
  stepRiser: rgb(0xc4c9c3),
  handrail: rgb(0x6f8a7c),
  steel: rgb(0xa9b2b6),
  steelDark: rgb(0x4d5559),
  seam: rgb(0x2a2f31),
  decalYellow: rgb(0xf2c230),
  decalFill: rgb(0x9fc3dd),
};
