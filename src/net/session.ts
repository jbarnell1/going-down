// What the host and the clients share: timing constants, the rules for joining and leaving, the
// host-clock estimator, and the one sight test both sides use for "can this player see the Orderly
// where it is drawn".
//
// Joining a run in progress: a new player is told the seed and the whole state at once (welcome) and
// watches as a spectator; they become a player at the next elevator stop, i.e. the next time the car
// is at a landing with its doors shut and the crew inside ('arriving': the start of the run and every
// arrival after a ride). They appear in the car with an empty tape. Players named in the host's
// starting roster are players from the first tick.
//
// Leaving: a player who leaves (or whose connection drops) becomes inactive at once and stays so: the
// run keeps them in its player list (their share of a bank is still theirs), they are never hunted,
// never vote and never count against a wipe. The host leaving ends the session: there is no host
// migration (known limit).

import { seenBy, type PlayerView } from '../sim/entity';
import { generateClinic } from '../sim/clinic';
import type { FloorPlan } from '../sim/floor';
import type { Body } from '../sim/move';
import { carBody, carGeometry, carLocal, inCar, moveInRun, type CarGeometry, type RunPhase, type RunState } from '../sim/run';
import { poseBody, type Pose } from './protocol';

/** Logic ticks per second on the host, and snapshots per second. */
export const TICK_HZ = 20;
export const TICK = 1 / TICK_HZ;
/** Seconds between a client's inputs (it also sends at once when it starts seeing the Orderly). */
export const INPUT_INTERVAL = 1 / 20;
/** Clients draw other players and the Orderly this far behind the newest snapshot they could have. */
export const INTERP_DELAY = 0.1;
/** Seconds of Orderly history the host keeps for put-backs (must exceed the worst round trip plus INTERP_DELAY). */
export const HISTORY_SECONDS = 3;
/** The host puts the Orderly back to where a client saw it only if that is within this many metres. */
export const PUT_BACK_MAX = 4;
/** A player's "I can see it" stops counting if no input has come for this long (seconds). */
export const SEEING_TIMEOUT = 1;
/** A catch whose victim has not confirmed their screen within this long is completed anyway (seconds). */
export const CATCH_CONFIRM_MAX = 1.5;
/** Fastest a player's body may move between inputs (m/s), plus a fixed allowance (m). Players walk 3. */
export const MAX_PLAYER_SPEED = 6;
export const JUMP_SLACK = 0.75;
/** Events per snapshot are capped at roughly this many bytes (at least one event is always sent). */
export const EVENT_BUDGET = 560;
/** A body's radius when the client moves its own player. */
export const PLAYER_RADIUS = 0.3;

// ---------------------------------------------------------------------------------------------
// Floors.

const planCache = new Map<string, FloorPlan>();

/** The floor plan of a depth (every machine builds the same one from the seed). */
export function planFor(seed: string, depth: number): FloorPlan {
  const key = `${seed}/${depth}`;
  let p = planCache.get(key);
  if (!p) {
    p = generateClinic(seed, depth);
    planCache.set(key, p);
    if (planCache.size > 16) {
      const first = planCache.keys().next().value;
      if (first !== undefined) planCache.delete(first);
    }
  }
  return p;
}

const carCache = new WeakMap<FloorPlan, CarGeometry>();
export function carFor(plan: FloorPlan): CarGeometry {
  let c = carCache.get(plan);
  if (!c) {
    c = carGeometry(plan);
    carCache.set(plan, c);
  }
  return c;
}

export function doorsOpenIn(phase: RunPhase): boolean {
  return phase === 'unloading' || phase === 'boarding';
}

/**
 * Moves the local player the way the run does (moveInRun: walls, stairs, the car's doorway while the
 * doors are open). moveInRun takes a whole RunState but reads only the plan, the car and the phase.
 */
export function moveLocal(plan: FloorPlan, phase: RunPhase, body: Body, dx: number, dz: number, radius = PLAYER_RADIUS): Body {
  const view = { plan, car: carFor(plan), phase } as unknown as RunState;
  return moveInRun(view, body, dx, dz, radius);
}

// ---------------------------------------------------------------------------------------------
// Sight.

/** A camera: where the eyes are and where they look. */
export interface Camera {
  body: Body;
  eye: number;
  yaw: number;
  pitch: number;
  hFovDeg: number;
  vFovDeg: number;
}

/** The view a player inside the car has of the floor with the doors open (as run.ts judges it). */
function thresholdCamera(car: CarGeometry, cam: Camera): Camera {
  const { v } = carLocal(car, cam.body.x, cam.body.z);
  const half = car.doorWidth / 2;
  const at = carBody(car, -0.02, Math.max(-half, Math.min(half, v)));
  return { ...cam, body: { ...at, y: cam.body.y } };
}

/**
 * Whether a camera could be showing the Orderly drawn at `pose`: the logic's own generous test
 * (entity.ts seenBy: widened cone, the body plus the larger outlines the figure can reach). From
 * inside the car with the doors open it also looks from the threshold, as the logic does; either
 * view counts.
 */
export function cameraSees(plan: FloorPlan, cam: Camera, pose: Pose, doorsOpen: boolean): boolean {
  const views: PlayerView[] = [{ id: 'me', active: true, ...cam }];
  const car = carFor(plan);
  if (doorsOpen && inCar(car, cam.body)) views.push({ id: 'me', active: true, ...thresholdCamera(car, cam) });
  return seenBy(plan, poseBody(pose), views) !== null;
}

// ---------------------------------------------------------------------------------------------
// The host clock, as a client estimates it.

/**
 * Round-trip samples: the client stamps each input with its own clock; the host echoes the stamp of
 * the newest input it has with how long it held it, and stamps its own clock on the snapshot. One
 * sample gives a round trip (minus the hold) and an offset that assumes the two directions took the
 * same time. The estimate uses the sample with the smallest round trip in a recent window (it is
 * the least disturbed by jitter); its offset error is at most half that round trip, whatever the
 * asymmetry, because neither direction can take less than nothing. That bound is the guard.
 */
export class HostClock {
  private readonly rtts: number[] = [];
  private readonly offsets: number[] = [];

  constructor(private readonly window = 120) {}

  /** One echo: client sent at `t0`, the host held it `hold` s and stamped `hostSend`; it arrived at `t3`. */
  sample(t0: number, hold: number, hostSend: number, t3: number): void {
    const rtt = t3 - t0 - hold;
    if (!(rtt >= 0) || !(hold >= 0)) return;
    this.rtts.push(rtt);
    this.offsets.push(hostSend + rtt / 2 - t3);
    if (this.rtts.length > this.window) {
      this.rtts.shift();
      this.offsets.shift();
    }
  }

  get ready(): boolean {
    return this.rtts.length > 0;
  }

  private best(): number {
    let b = 0;
    for (let i = 1; i < this.rtts.length; i++) if ((this.rtts[i] as number) < (this.rtts[b] as number)) b = i;
    return b;
  }

  /** Host time minus local time. */
  get offset(): number {
    return this.ready ? (this.offsets[this.best()] as number) : 0;
  }

  /** The smallest recent round trip, seconds. */
  get rtt(): number {
    return this.ready ? (this.rtts[this.best()] as number) : 0.5;
  }

  /** How far the estimated host time can be from the real one (seconds). */
  get errorBound(): number {
    return this.ready ? this.rtt / 2 : 0.5;
  }

  hostTime(local: number): number {
    return local + this.offset;
  }
}

export type { PlayerView };
