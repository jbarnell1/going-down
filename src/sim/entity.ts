// The Orderly: a 2.6 m figure pushing a squeaking trolley. Its trait is Stillness: it only moves
// while nobody is looking at it. Pure, deterministic logic; the renderer plays `anim` and `yaw`,
// the audio plays audibility().
//
// The fairness contract: entities always obey their traits, and anything that depends on looking
// is decided in the player's favour. So, within every tick:
//   1. decide whether any active player could be seeing it (sight.ts, with a widened cone and
//      generous geometry);
//   2. only then act. It never moves, turns, advances its animation, or progresses a wind-up in a
//      tick in which it is seen, nor for GRACE seconds after the last tick it was seen (so a player
//      whose view reaches the server late never sees it move);
//   3. looking at it during a wind-up always cancels the wind-up.
//
// Modes: waiting (standing at plan.entityStart) -> hunting -> windUp -> dormant -> hunting ...

import { distancesFrom, findPath, posIndex, type FloorPlan, type Pos } from './floor';
import { stepPathWalk, type PathWalk } from './follow';
import { bodyAtCell, cellOf, moveWithCollision, type Body } from './move';
import { canSee, eyePoint, figurePoints, hasLineOfSight, type Viewer } from './sight';
import { DOOR_WIDTH, northEdge, westEdge } from './walls';

// ---------------------------------------------------------------------------------------------
// Tuning.

export const ORDERLY_HEIGHT = 2.6;
export const ORDERLY_RADIUS = 0.35;
/**
 * How big it counts as being for the purpose of "can anyone see it". Larger than the body it
 * collides with, on purpose: the drawn figure's cap reaches 2.82 m and its reaching arm 2.0 m from
 * its centre, and an arm seen moving round a corner would break the rule as surely as the body.
 */
export const SEEN_HEIGHT = 2.9;
export const SEEN_RADIUS = 2.1;
/** The swinging arms in the walk reach about 1.05 m from its centre. */
export const SEEN_RADIUS_WALK = 1.1;
/** Seconds it stays frozen after the last tick anyone could see it. Absorbs network delay. */
export const GRACE = 0.3;
/** Waiting ends after it has been seen for this long in total (seconds)... */
export const WAKE_SEEN_TIME = 1.0;
/** ...or a player's walking distance to it drops under this (metres)... */
export const WAKE_DISTANCE = 12;
/** ...or this much time has passed (seconds). */
export const WAKE_TIMEOUT = 60;
/** Hunting speed in m/s: faster than a walk (3.0), slower than a sprint (5.0); see stamina.ts. */
export const HUNT_SPEED = 3.7;
/**
 * It runs down prey that runs, and creeps up on prey that stands still. Within CREEP_DISTANCE of a
 * target moving slower than CREEP_PREY_SPEED it slows to CREEP_SPEED. This is what makes recording it
 * a gamble a person can play: at full speed the last five metres take a second and a half, too fast
 * to choose when to turn; at a creep they take about four, with the ticking climbing all the way.
 * A player who flees still gets chased at full speed, so turning your back and walking away is no escape.
 */
export const CREEP_DISTANCE = 5.5;
export const CREEP_PREY_SPEED = 1.6;
export const CREEP_SPEED = 1.3;
/** Seconds between route re-plans while hunting. */
export const REPLAN_INTERVAL = 0.5;
/** Horizontal distance (metres) to a player on the same level at which it starts reaching. */
export const CATCH_RANGE = 0.9;
/** Wind-up of the reach, seconds. */
export const WIND_UP_TIME = 0.6;
/** A wind-up completes only if its target is still this close (metres) and on the same level. */
export const REACH_RANGE = 1.6;
/** After a catch it does nothing for this long (seconds). */
export const DORMANT_TIME = 10;
/** When it shares a cell with its target it walks straight at them, stopping this far away. */
export const APPROACH_STOP = 0.6;
/** Maximum turn rate, radians per second. */
export const TURN_RATE = 5;
/** Within this straight-line distance (metres, same level) it faces its target while it walks. */
export const FACE_TARGET_RANGE = 6;
/** It ducks while its centre is within this distance (metres) of a door's edge line. */
export const DUCK_DISTANCE = 0.6;
/** The trolley squeak: audible out to this straight-line distance (metres) while it moves. */
export const HEAR_RANGE = 34;
/** Gain multiplier when there is no line of sight to it. */
export const MUFFLED_GAIN = 0.45;
/** Height of the squeaking wheels above its feet (metres). */
export const SQUEAK_HEIGHT = 0.4;

/** Below this, timers count as run out (float sums of dt are not exact). */
const EPS = 1e-9;

// ---------------------------------------------------------------------------------------------
// Types.

export type OrderlyMode = 'waiting' | 'hunting' | 'windUp' | 'dormant';
/** What the renderer plays. A frozen Orderly keeps its last hint and its clock stops. */
export type OrderlyAnim = 'idle' | 'walk' | 'duck' | 'reach';

/** A player as the Orderly sees them. `eye` is the eye height above the feet. */
export interface PlayerView extends Viewer {
  id: string;
  active: boolean;
  /**
   * Present and huntable (it can target, reach for and catch them) but seeing nothing this tick,
   * e.g. during a light blink. Never counts as looking. Default false.
   */
  blind?: boolean;
}

export interface OrderlyState {
  /** Simulation time in seconds. */
  t: number;
  body: Body;
  /** Facing, radians, three.js style (0 faces -z). */
  yaw: number;
  mode: OrderlyMode;
  anim: OrderlyAnim;
  /** Animation clock in seconds; stops whenever it is held still. */
  animTime: number;
  /** Some active player could see it this tick. */
  seen: boolean;
  /** Held still this tick: seen now, or within GRACE of the last seen tick. */
  held: boolean;
  /** Held while hunting or winding up (what `froze` and `released` report). */
  frozen: boolean;
  /** It changed position this tick. */
  moving: boolean;
  everSeen: boolean;
  /** Total seconds seen while waiting. */
  seenTotal: number;
  /** Time of the last tick it was seen, or null. */
  lastSeenAt: number | null;
  targetId: string | null;
  /** Its current walking speed in m/s (0 when not moving); the renderer and the squeak follow it. */
  speed: number;
  /** Smoothed speed of its target and where the target was on the last hunting tick. */
  preySpeed: number;
  preyX: number;
  preyZ: number;
  preyId: string | null;
  path: readonly Pos[] | null;
  pathNext: number;
  replanIn: number;
  windUpLeft: number;
  windUpTarget: string | null;
  dormantLeft: number;
}

export type OrderlyEvent =
  | { type: 'firstSeen'; t: number; playerId: string }
  | { type: 'startedHunting'; t: number }
  | { type: 'froze'; t: number; playerId: string | null }
  | { type: 'released'; t: number }
  | { type: 'windUp'; t: number; playerId: string }
  | { type: 'windUpCancelled'; t: number; playerId: string }
  | { type: 'caught'; t: number; playerId: string };

/** How it hunts this tick (the run's blackout changes it; see run.ts). */
export interface HuntOptions {
  /** Hunting speed in m/s (default HUNT_SPEED). */
  speed?: number;
  /** Whether it creeps up on slow prey (default true). */
  creep?: boolean;
}

export interface StepResult {
  state: OrderlyState;
  events: OrderlyEvent[];
}

// ---------------------------------------------------------------------------------------------
// Helpers.

/** Yaw that faces along (dx, dz), three.js style. */
export function yawToward(dx: number, dz: number): number {
  return Math.atan2(-dx, -dz);
}

function wrapAngle(a: number): number {
  let r = a % (2 * Math.PI);
  if (r > Math.PI) r -= 2 * Math.PI;
  if (r < -Math.PI) r += 2 * Math.PI;
  return r;
}

function turnToward(yaw: number, want: number, maxTurn: number): number {
  const d = wrapAngle(want - yaw);
  return wrapAngle(yaw + Math.max(-maxTurn, Math.min(maxTurn, d)));
}

/** One distance field per plan, for the cell asked for last: a waiting Orderly asks for the same one every tick. */
const fieldCache = new WeakMap<FloorPlan, { index: number; dist: Int32Array }>();

function distancesCached(plan: FloorPlan, from: Pos): Int32Array {
  const index = posIndex(plan, from);
  const hit = fieldCache.get(plan);
  if (hit && hit.index === index) return hit.dist;
  const dist = distancesFrom(plan, from);
  fieldCache.set(plan, { index, dist });
  return dist;
}

/** The nearest active player by walking distance (ties: straight-line distance, then list order). */
function nearestByWalk(plan: FloorPlan, body: Body, players: readonly PlayerView[]): { player: PlayerView; steps: number } | null {
  const dist = distancesCached(plan, cellOf(plan, body));
  let best: { player: PlayerView; steps: number; line: number } | null = null;
  for (const p of players) {
    if (!p.active) continue;
    const steps = dist[posIndex(plan, cellOf(plan, p.body))] ?? -1;
    if (steps < 0) continue;
    const line = Math.hypot(p.body.x - body.x, p.body.z - body.z);
    if (!best || steps < best.steps || (steps === best.steps && line < best.line)) best = { player: p, steps, line };
  }
  return best;
}

function sameCell(a: Pos, b: Pos): boolean {
  return a.level === b.level && a.x === b.x && a.y === b.y;
}

/** Whether a body's centre is within DUCK_DISTANCE of a door on one of its cell's edges. */
export function nearDoor(plan: FloorPlan, body: Body): boolean {
  const s = plan.cellSize;
  const c = cellOf(plan, body);
  const half = DOOR_WIDTH / 2 + ORDERLY_RADIUS;
  const lx = body.x - c.x * s;
  const lz = body.z - c.y * s;
  const alongZ = Math.abs(lz - s / 2) <= half;
  const alongX = Math.abs(lx - s / 2) <= half;
  if (alongZ && lx <= DUCK_DISTANCE && westEdge(plan, c.level, c.x, c.y) === 'door') return true;
  if (alongZ && s - lx <= DUCK_DISTANCE && westEdge(plan, c.level, c.x + 1, c.y) === 'door') return true;
  if (alongX && lz <= DUCK_DISTANCE && northEdge(plan, c.level, c.x, c.y) === 'door') return true;
  if (alongX && s - lz <= DUCK_DISTANCE && northEdge(plan, c.level, c.x, c.y + 1) === 'door') return true;
  return false;
}

// ---------------------------------------------------------------------------------------------
// The state machine.

/** A waiting Orderly at plan.entityStart, facing the landing. */
export function createOrderly(plan: FloorPlan): OrderlyState {
  const body = bodyAtCell(plan, plan.entityStart);
  const s = plan.cellSize;
  const yaw = yawToward((plan.landing.x + 0.5) * s - body.x, (plan.landing.y + 0.5) * s - body.z);
  return {
    t: 0,
    body,
    yaw,
    mode: 'waiting',
    anim: 'idle',
    animTime: 0,
    seen: false,
    held: false,
    frozen: false,
    moving: false,
    everSeen: false,
    seenTotal: 0,
    lastSeenAt: null,
    targetId: null,
    speed: 0,
    preySpeed: HUNT_SPEED,
    preyX: 0,
    preyZ: 0,
    preyId: null,
    path: null,
    pathNext: 0,
    replanIn: 0,
    windUpLeft: 0,
    windUpTarget: null,
    dormantLeft: 0,
  };
}

/** Whether any active player's screen could be showing it, and who (first in list order). */
export function seenBy(plan: FloorPlan, body: Body, players: readonly PlayerView[]): PlayerView | null {
  for (const p of players) {
    if (!p.active || p.blind === true) continue;
    // The true body first, then the larger outlines the drawn figure can reach. Each extra pass can
    // only add sightings: checking the big outline INSTEAD of the body moved the sample points above
    // door frames and missed real ones, which the independent oracle caught.
    if (
      canSee(plan, p, body, { height: ORDERLY_HEIGHT, radius: ORDERLY_RADIUS }) ||
      canSee(plan, p, body, { height: ORDERLY_HEIGHT, radius: SEEN_RADIUS_WALK }) ||
      canSee(plan, p, body, { height: SEEN_HEIGHT, radius: SEEN_RADIUS })
    ) return p;
  }
  return null;
}

/** Advances the Orderly by dt seconds. Never mutates `prev`. */
export function stepEntity(plan: FloorPlan, prev: OrderlyState, players: readonly PlayerView[], dt: number, opts: HuntOptions = {}): StepResult {
  const t = prev.t + dt;
  const s: OrderlyState = { ...prev, t, moving: false, speed: 0 };
  const events: OrderlyEvent[] = [];

  // 1. Is it seen? Decided before anything else, from where it stands now.
  const seer = seenBy(plan, prev.body, players);
  const seen = seer !== null;
  s.seen = seen;
  if (seen) s.lastSeenAt = t;
  // Held: seen now, or the time since it was last seen, measured from the start of this tick's
  // movement interval, is still under GRACE.
  const held = seen || (prev.lastSeenAt !== null && t - dt - prev.lastSeenAt < GRACE - EPS);
  s.held = held;
  if (seer && !prev.everSeen) {
    s.everSeen = true;
    events.push({ type: 'firstSeen', t, playerId: seer.id });
  }

  // 2. Mode changes that do not need it to move.
  if (s.mode === 'waiting') {
    if (seen) s.seenTotal += dt;
    const near = nearestByWalk(plan, s.body, players);
    const close = near !== null && near.steps * plan.cellSize < WAKE_DISTANCE;
    if (s.seenTotal >= WAKE_SEEN_TIME - EPS || close || t >= WAKE_TIMEOUT - EPS) {
      s.mode = 'hunting';
      s.replanIn = 0;
      events.push({ type: 'startedHunting', t });
    }
  } else if (s.mode === 'dormant') {
    s.dormantLeft -= dt;
    if (s.dormantLeft <= EPS) {
      s.dormantLeft = 0;
      s.mode = 'hunting';
      s.replanIn = 0;
      events.push({ type: 'startedHunting', t });
    }
  } else if (s.mode === 'windUp' && seer) {
    // Looking at it always saves you.
    events.push({ type: 'windUpCancelled', t, playerId: s.windUpTarget ?? '' });
    s.mode = 'hunting';
    s.windUpTarget = null;
    s.windUpLeft = 0;
  }

  s.frozen = held && (s.mode === 'hunting' || s.mode === 'windUp');
  if (s.frozen && !prev.frozen) events.push({ type: 'froze', t, playerId: seer ? seer.id : null });
  if (!s.frozen && prev.frozen && (s.mode === 'hunting' || s.mode === 'windUp')) events.push({ type: 'released', t });

  // 3. Held: nothing else changes. Position, facing, animation hint and clock all stay as they are.
  if (held) {
    if (s.mode === 'waiting' || s.mode === 'dormant') s.anim = 'idle';
    return { state: s, events };
  }
  s.animTime += dt;

  // 4. Act.
  if (s.mode === 'waiting' || s.mode === 'dormant') {
    s.anim = 'idle';
    return { state: s, events };
  }

  if (s.mode === 'windUp') {
    const target = players.find((p) => p.id === s.windUpTarget);
    const ok =
      target !== undefined &&
      target.active &&
      target.body.level === s.body.level &&
      Math.hypot(target.body.x - s.body.x, target.body.z - s.body.z) <= REACH_RANGE;
    if (!ok) {
      events.push({ type: 'windUpCancelled', t, playerId: s.windUpTarget ?? '' });
      s.mode = 'hunting';
      s.windUpTarget = null;
      s.windUpLeft = 0;
    } else {
      s.yaw = turnToward(s.yaw, yawToward(target.body.x - s.body.x, target.body.z - s.body.z), TURN_RATE * dt);
      s.windUpLeft -= dt;
      s.anim = 'reach';
      if (s.windUpLeft <= EPS) {
        events.push({ type: 'caught', t, playerId: target.id });
        s.mode = 'dormant';
        s.dormantLeft = DORMANT_TIME;
        s.windUpTarget = null;
        s.windUpLeft = 0;
        s.path = null;
        s.targetId = null;
        s.anim = 'idle';
      }
      return { state: s, events };
    }
  }

  // Hunting and free to act. Close enough to someone on this level? Start reaching, do not move.
  let victim: PlayerView | null = null;
  let victimDist = Number.POSITIVE_INFINITY;
  for (const p of players) {
    if (!p.active || p.body.level !== s.body.level) continue;
    const d = Math.hypot(p.body.x - s.body.x, p.body.z - s.body.z);
    if (d <= CATCH_RANGE && d < victimDist) {
      victim = p;
      victimDist = d;
    }
  }
  if (victim) {
    s.mode = 'windUp';
    s.windUpTarget = victim.id;
    s.windUpLeft = WIND_UP_TIME;
    s.anim = 'reach';
    s.animTime = 0;
    events.push({ type: 'windUp', t, playerId: victim.id });
    return { state: s, events };
  }

  hunt(plan, s, players, dt, opts);
  return { state: s, events };
}

/** One tick of walking toward the nearest player. Mutates the (already copied) state. */
function hunt(plan: FloorPlan, s: OrderlyState, players: readonly PlayerView[], dt: number, opts: HuntOptions): void {
  s.replanIn -= dt;
  if (s.replanIn <= EPS || s.path === null) {
    s.replanIn = REPLAN_INTERVAL;
    const near = nearestByWalk(plan, s.body, players);
    s.targetId = near ? near.player.id : null;
    s.path = near ? findPath(plan, cellOf(plan, s.body), cellOf(plan, near.player.body)) : null;
    s.pathNext = s.path && s.path.length > 1 ? 1 : 0;
  }
  const target = players.find((p) => p.id === s.targetId && p.active);
  if (!target || !s.path) {
    s.anim = 'idle';
    s.path = null;
    return;
  }

  const before = s.body;

  // How fast is the prey moving? Measured between hunting ticks and smoothed over about a quarter
  // of a second. A new target is assumed to be running until shown otherwise.
  if (s.preyId === target.id && dt > EPS) {
    const inst = Math.min(6, Math.hypot(target.body.x - s.preyX, target.body.z - s.preyZ) / dt);
    s.preySpeed += (inst - s.preySpeed) * Math.min(1, dt * 4);
  } else {
    s.preySpeed = HUNT_SPEED;
  }
  s.preyId = target.id;
  s.preyX = target.body.x;
  s.preyZ = target.body.z;
  const gap = Math.hypot(target.body.x - before.x, target.body.z - before.z);
  const creeping = opts.creep !== false && target.body.level === before.level && gap < CREEP_DISTANCE && s.preySpeed < CREEP_PREY_SPEED;
  const pace = creeping ? CREEP_SPEED : (opts.speed ?? HUNT_SPEED);

  const here = cellOf(plan, before);
  if (sameCell(here, cellOf(plan, target.body))) {
    const dx = target.body.x - before.x;
    const dz = target.body.z - before.z;
    const d = Math.hypot(dx, dz);
    const step = Math.min(pace * dt, d - APPROACH_STOP);
    if (step > 1e-6) s.body = moveWithCollision(plan, before, (dx / d) * step, (dz / d) * step, ORDERLY_RADIUS);
  } else {
    // stepPathWalk only advances `next`; the path itself is never written to.
    const walk: PathWalk = { path: s.path as Pos[], next: s.pathNext };
    s.body = stepPathWalk(plan, walk, before, pace * dt, ORDERLY_RADIUS);
    s.pathNext = walk.next;
  }
  s.speed = Math.hypot(s.body.x - before.x, s.body.z - before.z) / Math.max(dt, EPS);

  const mx = s.body.x - before.x;
  const mz = s.body.z - before.z;
  const moved = Math.hypot(mx, mz);
  s.moving = moved > 1e-9;
  if (moved < 1e-4) s.replanIn = 0; // blocked or arrived: think again next tick

  const tx = target.body.x - s.body.x;
  const tz = target.body.z - s.body.z;
  const faceTarget = target.body.level === s.body.level && Math.hypot(tx, tz) <= FACE_TARGET_RANGE;
  if (faceTarget) s.yaw = turnToward(s.yaw, yawToward(tx, tz), TURN_RATE * dt);
  else if (s.moving) s.yaw = turnToward(s.yaw, yawToward(mx, mz), TURN_RATE * dt);
  s.anim = s.moving ? (nearDoor(plan, s.body) ? 'duck' : 'walk') : 'idle';
}

// ---------------------------------------------------------------------------------------------
// Sound.

export interface Audibility {
  /** 0 (silent) to 1. */
  gain: number;
  /** No line of sight: play it through a low-pass filter. */
  muffled: boolean;
}

/**
 * How loud the trolley squeak is for a listener. Silent unless it moved this tick: squeaking means
 * nobody is watching it; silence means it is watched, or standing still. Falls off with straight-line
 * distance to nothing at HEAR_RANGE; muffled and quieter without line of sight.
 */
export function audibility(plan: FloorPlan, state: OrderlyState, listener: Pick<Viewer, 'body' | 'eye'>): Audibility {
  if (!state.moving) return { gain: 0, muffled: false };
  const ear = eyePoint(listener);
  const b = state.body;
  const d = Math.hypot(b.x - ear.x, b.y + SQUEAK_HEIGHT - ear.y, b.z - ear.z);
  if (d >= HEAR_RANGE) return { gain: 0, muffled: false };
  const base = (1 - d / HEAR_RANGE) ** 2;
  const src = { x: b.x, y: b.y + SQUEAK_HEIGHT, z: b.z, level: b.level };
  const clear = hasLineOfSight(plan, ear, src) || figurePoints(b, ear.x, ear.z, ORDERLY_HEIGHT, ORDERLY_RADIUS).some((p) => hasLineOfSight(plan, ear, p));
  return clear ? { gain: base, muffled: false } : { gain: base * MUFFLED_GAIN, muffled: true };
}
