// The local player: a body moved by sim/move.ts, plus where they are looking.

import type * as THREE from 'three';
import type { Dir, FloorPlan, Level } from '../sim/floor';
import { bodyAtCell, moveWithCollision, type Body } from '../sim/move';
import type { Input } from './input';

export const EYE_HEIGHT = 1.65;
export const WALK_SPEED = 3;
export const CREEP_SPEED = 1.2;
export const PLAYER_RADIUS = 0.3;
const MOUSE_SENSITIVITY = 0.0022;
const MAX_PITCH = 1.45;

/**
 * Yaw is in radians about +y, three.js style: 0 faces north (-z, decreasing cell y), pi/2 faces
 * west (-x), pi faces south, -pi/2 faces east.
 */
export function yawForDir(d: Dir): number {
  return { n: 0, w: Math.PI / 2, s: Math.PI, e: -Math.PI / 2 }[d];
}

/** Yaw that faces along a horizontal direction (dx, dz). */
export function yawToward(dx: number, dz: number): number {
  return Math.atan2(-dx, -dz);
}

export class Player {
  body: Body;
  yaw = 0;
  pitch = 0;

  constructor(plan: FloorPlan, level: Level, cx: number, cy: number, yaw: number) {
    this.body = bodyAtCell(plan, { level, x: cx, y: cy });
    this.yaw = yaw;
  }

  teleport(plan: FloorPlan, level: Level, cx: number, cy: number, yaw?: number): void {
    this.body = bodyAtCell(plan, { level, x: cx, y: cy });
    if (yaw !== undefined) this.yaw = yaw;
  }

  /** Mouse look and WASD walking for one frame. */
  control(plan: FloorPlan, input: Input, dt: number): void {
    const [mx, my] = input.takeLook();
    this.yaw -= mx * MOUSE_SENSITIVITY;
    this.pitch = Math.max(-MAX_PITCH, Math.min(MAX_PITCH, this.pitch - my * MOUSE_SENSITIVITY));
    let f = 0;
    let r = 0;
    if (input.down('KeyW') || input.down('ArrowUp')) f += 1;
    if (input.down('KeyS') || input.down('ArrowDown')) f -= 1;
    if (input.down('KeyD') || input.down('ArrowRight')) r += 1;
    if (input.down('KeyA') || input.down('ArrowLeft')) r -= 1;
    if (f === 0 && r === 0) return;
    const speed = input.down('ShiftLeft') || input.down('ShiftRight') ? CREEP_SPEED : WALK_SPEED;
    const len = Math.hypot(f, r);
    const sin = Math.sin(this.yaw);
    const cos = Math.cos(this.yaw);
    // Forward is (-sin, -cos), right is (cos, -sin) on the (x, z) plane.
    const dx = ((-sin * f + cos * r) / len) * speed * dt;
    const dz = ((-cos * f - sin * r) / len) * speed * dt;
    this.body = moveWithCollision(plan, this.body, dx, dz, PLAYER_RADIUS);
  }

  toCamera(camera: THREE.PerspectiveCamera): void {
    camera.position.set(this.body.x, this.body.y + EYE_HEIGHT, this.body.z);
    camera.rotation.set(this.pitch, this.yaw, 0, 'YXZ');
  }
}
