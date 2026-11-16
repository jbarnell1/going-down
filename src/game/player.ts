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

/** Moves a body by (dx, dz) with collision. */
export type Mover = (body: Body, dx: number, dz: number, radius: number) => Body;

export class Player {
  body: Body;
  yaw = 0;
  pitch = 0;
  /** The speed asked for on the last control() call, m/s (0 when standing). */
  lastSpeed = 0;

  constructor(plan: FloorPlan, level: Level, cx: number, cy: number, yaw: number) {
    this.body = bodyAtCell(plan, { level, x: cx, y: cy });
    this.yaw = yaw;
  }

  teleport(plan: FloorPlan, level: Level, cx: number, cy: number, yaw?: number): void {
    this.body = bodyAtCell(plan, { level, x: cx, y: cy });
    if (yaw !== undefined) this.yaw = yaw;
  }

  /**
   * Mouse look and WASD walking for one frame. `maxSpeed` caps the walk (instrument raised). `move`
   * does the collision (the run's, which knows the elevator's doorway); plain floor collision if absent.
   */
  control(plan: FloorPlan, input: Input, dt: number, maxSpeed = Infinity, move?: Mover): void {
    const [mx, my] = input.takeLook();
    this.yaw -= mx * MOUSE_SENSITIVITY;
    this.pitch = Math.max(-MAX_PITCH, Math.min(MAX_PITCH, this.pitch - my * MOUSE_SENSITIVITY));
    const want = input.move();
    this.lastSpeed = 0;
    if (!want) return;
    // Keys walk or creep. A phone's stick is analogue: push gently to go slowly.
    const speed = Math.min(maxSpeed, want.creep ? CREEP_SPEED : WALK_SPEED * want.strength);
    this.lastSpeed = speed;
    const { f, r } = want;
    const sin = Math.sin(this.yaw);
    const cos = Math.cos(this.yaw);
    // Forward is (-sin, -cos), right is (cos, -sin) on the (x, z) plane.
    const dx = (-sin * f + cos * r) * speed * dt;
    const dz = (-cos * f - sin * r) * speed * dt;
    this.body = move ? move(this.body, dx, dz, PLAYER_RADIUS) : moveWithCollision(plan, this.body, dx, dz, PLAYER_RADIUS);
  }

  toCamera(camera: THREE.PerspectiveCamera): void {
    camera.position.set(this.body.x, this.body.y + EYE_HEIGHT, this.body.z);
    camera.rotation.set(this.pitch, this.yaw, 0, 'YXZ');
  }
}
