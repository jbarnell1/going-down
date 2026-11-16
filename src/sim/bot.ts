// Wandering bot players: deterministic stand-ins for people, used by tests now and the game later.
// Each picks a reachable cell, walks there with the real collision code (sometimes creeping,
// sometimes stopping), and turns its head with a mix of looking where it goes, glancing behind and
// looking around. `watchfulness` (0..1) sets how often it looks anywhere but ahead; an `oblivious`
// bot never looks behind and only looks a little to the sides.

import { findPath, isWalkable, posFromIndex, reachableFrom, type FloorPlan, type Pos } from './floor';
import { pathDone, stepPathWalk, type PathWalk } from './follow';
import { bodyAtCell, cellOf, type Body } from './move';
import { makeRng, type Rng } from './rng';
import type { PlayerView } from './entity';

export const BOT_WALK_SPEED = 3.0;
export const BOT_CREEP_SPEED = 1.2;
export const BOT_RADIUS = 0.3;
export const BOT_EYE = 1.65;
/** The game camera: 70 degrees vertical at 16:9. */
export const BOT_VFOV_DEG = 70;
export const BOT_HFOV_DEG = (2 * Math.atan(Math.tan((35 * Math.PI) / 180) * (16 / 9)) * 180) / Math.PI;
/** Head turn rate, radians per second. */
export const BOT_TURN_RATE = 6;

export type BotGait = 'walk' | 'creep' | 'stop';
export type BotLook = 'ahead' | 'behind' | 'around';

export interface BotOptions {
  /** 0 never looks away from where it walks except to glance around a little; 1 looks around constantly. */
  watchfulness?: number;
  /** Never looks behind; side glances stay small. */
  oblivious?: boolean;
  /** Start cell; default: a random reachable cell. */
  start?: Pos;
}

export interface Bot {
  id: string;
  body: Body;
  /** Where the head points (yaw, pitch), three.js style. */
  yaw: number;
  pitch: number;
  /** Direction of travel. */
  heading: number;
  gait: BotGait;
  gaitLeft: number;
  look: BotLook;
  lookLeft: number;
  lookOffset: number;
  pitchWant: number;
  walk: PathWalk | null;
  stuck: number;
  watchfulness: number;
  oblivious: boolean;
  rng: Rng;
}

const reachableCache = new WeakMap<FloorPlan, number[]>();

/** Every position reachable from the landing, ascending posIndex. */
function reachableCells(plan: FloorPlan): number[] {
  const hit = reachableCache.get(plan);
  if (hit) return hit;
  const list = [...reachableFrom(plan, plan.landing)].sort((a, b) => a - b);
  reachableCache.set(plan, list);
  return list;
}

function wrap(a: number): number {
  let r = a % (2 * Math.PI);
  if (r > Math.PI) r -= 2 * Math.PI;
  if (r < -Math.PI) r += 2 * Math.PI;
  return r;
}

export function createBot(plan: FloorPlan, id: string, seed: string | number, opts: BotOptions = {}): Bot {
  const rng = makeRng(seed).fork(`bot:${id}`);
  const cells = reachableCells(plan);
  const start = opts.start ?? posFromIndex(plan, rng.pick(cells));
  const heading = (rng.next() * 2 - 1) * Math.PI;
  return {
    id,
    body: bodyAtCell(plan, start),
    yaw: heading,
    pitch: 0,
    heading,
    gait: 'walk',
    gaitLeft: 2 + rng.next() * 6,
    look: 'ahead',
    lookLeft: rng.next() * 2,
    lookOffset: 0,
    pitchWant: 0,
    walk: null,
    stuck: 0,
    watchfulness: Math.max(0, Math.min(1, opts.watchfulness ?? 0.5)),
    oblivious: opts.oblivious ?? false,
    rng,
  };
}

function newGoal(plan: FloorPlan, bot: Bot): void {
  const cells = reachableCells(plan);
  const from = cellOf(plan, bot.body);
  for (let tries = 0; tries < 8; tries++) {
    const goal = posFromIndex(plan, bot.rng.pick(cells));
    if (!isWalkable(plan, goal.level, goal.x, goal.y)) continue;
    const path = findPath(plan, from, goal);
    if (path && path.length > 1) {
      bot.walk = { path, next: 1 };
      return;
    }
  }
  bot.walk = null;
}

function newGait(bot: Bot): void {
  const r = bot.rng.next();
  if (r < 0.72) {
    bot.gait = 'walk';
    bot.gaitLeft = 3 + bot.rng.next() * 8;
  } else if (r < 0.88) {
    bot.gait = 'creep';
    bot.gaitLeft = 2 + bot.rng.next() * 4;
  } else {
    bot.gait = 'stop';
    bot.gaitLeft = 0.8 + bot.rng.next() * 3;
  }
}

function newLook(bot: Bot): void {
  const w = bot.watchfulness;
  const stopped = bot.gait === 'stop';
  const pBehind = bot.oblivious ? 0 : 0.04 + 0.3 * w;
  const pAround = (bot.oblivious ? 0.1 : 0.12 + 0.35 * w) + (stopped ? 0.3 : 0);
  const r = bot.rng.next();
  if (r < pBehind) {
    bot.look = 'behind';
    bot.lookLeft = 0.4 + bot.rng.next() * 0.9;
    bot.lookOffset = Math.PI + (bot.rng.next() - 0.5) * 0.8;
  } else if (r < pBehind + pAround) {
    bot.look = 'around';
    bot.lookLeft = 0.8 + bot.rng.next() * 1.8;
    const span = bot.oblivious ? Math.PI / 3 : (Math.PI * 5) / 6;
    bot.lookOffset = (bot.rng.next() * 2 - 1) * span;
  } else {
    bot.look = 'ahead';
    bot.lookLeft = (1.5 + bot.rng.next() * 4) * (1 - 0.6 * w);
    bot.lookOffset = (bot.rng.next() - 0.5) * 0.4;
  }
  bot.pitchWant = ((bot.rng.next() - 0.6) * 20 * Math.PI) / 180;
}

/** Advances a bot by dt seconds (mutates it). */
export function stepBot(plan: FloorPlan, bot: Bot, dt: number): void {
  bot.gaitLeft -= dt;
  if (bot.gaitLeft <= 0) newGait(bot);

  if (bot.gait !== 'stop') {
    if (!bot.walk || pathDone(plan, bot.walk, bot.body) || bot.stuck > 1) {
      bot.stuck = 0;
      newGoal(plan, bot);
      if (bot.walk && bot.rng.chance(0.2)) {
        bot.gait = 'stop';
        bot.gaitLeft = 0.5 + bot.rng.next() * 2.5;
      }
    }
    if (bot.walk && bot.gait !== 'stop') {
      const speed = bot.gait === 'creep' ? BOT_CREEP_SPEED : BOT_WALK_SPEED;
      const before = bot.body;
      bot.body = stepPathWalk(plan, bot.walk, before, speed * dt, BOT_RADIUS);
      const mx = bot.body.x - before.x;
      const mz = bot.body.z - before.z;
      const moved = Math.hypot(mx, mz);
      if (moved > 1e-4) {
        bot.heading = Math.atan2(-mx, -mz);
        bot.stuck = 0;
      } else {
        bot.stuck += dt;
      }
    }
  }

  bot.lookLeft -= dt;
  if (bot.lookLeft <= 0) newLook(bot);
  const want = wrap(bot.heading + bot.lookOffset);
  const d = wrap(want - bot.yaw);
  const max = BOT_TURN_RATE * dt;
  bot.yaw = wrap(bot.yaw + Math.max(-max, Math.min(max, d)));
  bot.pitch += Math.max(-max, Math.min(max, bot.pitchWant - bot.pitch));
}

/** The bot as a player the Orderly can look for. */
export function botView(bot: Bot): PlayerView {
  return { id: bot.id, body: bot.body, eye: BOT_EYE, yaw: bot.yaw, pitch: bot.pitch, hFovDeg: BOT_HFOV_DEG, vFovDeg: BOT_VFOV_DEG, active: true };
}
