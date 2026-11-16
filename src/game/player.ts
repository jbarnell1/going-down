// The local player: a body moved by sim/move.ts, plus where they are looking.

import type * as THREE from 'three';
import type { Dir, FloorPlan, Level } from '../sim/floor';
import { bodyAtCell, moveWithCollision, type Body } from '../sim/move';
import { freshStamina, gaitFor, speedFor, stepStamina, type Gait, type Stamina } from '../sim/stamina';
import type { Input } from './input';

// The speeds and the tank are the logic's (sim/stamina.ts), shared with the host and the bots.
export { CREEP_SPEED, SPRINT_SPEED, WALK_SPEED } from '../sim/stamina';
export const EYE_HEIGHT = 1.65;
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
  /** The gait this frame: creep, walk or sprint (sprint only while there is breath for it). */
  gait: Gait = 'walk';
  /** The local copy of the tank; the host owns the truth and the page corrects this from it. */
  stamina: Stamina = freshStamina();

  constructor(plan: FloorPlan, level: Level, cx: number, cy: number, yaw: number) {
    this.body = bodyAtCell(plan, { level, x: cx, y: cy });
    this.yaw = yaw;
  }

  teleport(plan: FloorPlan, level: Level, cx: number, cy: number, yaw?: number): void {
    this.body = bodyAtCell(plan, { level, x: cx, y: cy });
    if (yaw !== undefined) this.yaw = yaw;
  }

  /**
   * Mouse look and walking for one frame: WASD walk, Shift sprints while the tank lasts, C creeps.
   * `maxSpeed` caps the pace (instrument raised: no sprinting either). `move` does the collision
   * (the run's, which knows the elevator's doorway); plain floor collision if absent.
   */
  control(plan: FloorPlan, input: Input, dt: number, maxSpeed = Infinity, move?: Mover): void {
    const [mx, my] = input.takeLook();
    this.yaw -= mx * MOUSE_SENSITIVITY;
    this.pitch = Math.max(-MAX_PITCH, Math.min(MAX_PITCH, this.pitch - my * MOUSE_SENSITIVITY));
    const want = input.move();
    this.gait = gaitFor(this.stamina, { sprint: want?.sprint === true, creep: want?.creep === true, moving: want !== null, cap: maxSpeed });
    this.lastSpeed = 0;
    let moved = 0;
    if (want) {
      // Keys push fully. A phone's stick is analogue: push gently to go slowly, to the rim to sprint.
      const speed = this.gait === 'sprint' ? speedFor('sprint', maxSpeed) : Math.min(maxSpeed, speedFor(this.gait) * want.strength);
      this.lastSpeed = speed;
      const { f, r } = want;
      const sin = Math.sin(this.yaw);
      const cos = Math.cos(this.yaw);
      // Forward is (-sin, -cos), right is (cos, -sin) on the (x, z) plane.
      const dx = (-sin * f + cos * r) * speed * dt;
      const dz = (-cos * f - sin * r) * speed * dt;
      const before = this.body;
      this.body = move ? move(this.body, dx, dz, PLAYER_RADIUS) : moveWithCollision(plan, this.body, dx, dz, PLAYER_RADIUS);
      moved = Math.hypot(this.body.x - before.x, this.body.z - before.z);
    }
    this.breathe(dt, dt > 0 ? moved / dt : 0);
  }

  /** Spends or recovers breath for a frame of the current gait at this ground speed (m/s). */
  breathe(dt: number, groundSpeed: number): void {
    this.stamina = stepStamina(this.stamina, this.gait, groundSpeed, dt);
  }

  /** A frame without control (walked by a test, in the car's walk, caught): walking pace or rest. */
  idle(dt: number, groundSpeed = 0): void {
    this.gait = 'walk';
    this.lastSpeed = 0;
    this.breathe(dt, groundSpeed);
  }

  toCamera(camera: THREE.PerspectiveCamera): void {
    camera.position.set(this.body.x, this.body.y + EYE_HEIGHT, this.body.z);
    camera.rotation.set(this.pitch, this.yaw, 0, 'YXZ');
  }
}
