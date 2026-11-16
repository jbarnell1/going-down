// Wandering bot players: deterministic stand-ins for people, used by tests now and the game later.
// Each picks a reachable cell, walks there with the real collision code (sometimes creeping,
// sometimes stopping), and turns its head with a mix of looking where it goes, glancing behind and
// looking around. `watchfulness` (0..1) sets how often it looks anywhere but ahead; an `oblivious`
// bot never looks behind and only looks a little to the sides.
//
// Bots have the players' tank (stamina.ts) and, given where the Orderly is, use it as a person
// would: a bot that glances behind and sees it within BOT_FLEE_RANGE is alarmed for BOT_ALARM_TIME
// seconds, and while alarmed it sprints whenever the Orderly is close behind it (same level, in
// range, behind its direction of travel) and the tank allows; otherwise it walks, creeps or stops as
// before. So a watchful bot runs for it and an oblivious one (it never looks behind) never knows.
// Deterministic: no extra random draws.

import { findPath, isWalkable, posFromIndex, reachableFrom, type FloorPlan, type Pos } from './floor';
import { pathDone, stepPathWalk, type PathWalk } from './follow';
import { bodyAtCell, cellOf, type Body } from './move';
import { makeRng, type Rng } from './rng';
import type { PlayerView } from './entity';
import { CREEP_SPEED, freshStamina, gaitFor, speedFor, stepStamina, WALK_SPEED, type Gait, type Stamina } from './stamina';

export const BOT_WALK_SPEED = WALK_SPEED;
export const BOT_CREEP_SPEED = CREEP_SPEED;
/** A bot flees (sprints) from an Orderly within this many metres behind it... */
export const BOT_FLEE_RANGE = 10;
/** ...for this many seconds after it last glanced back and saw it there. */
export const BOT_ALARM_TIME = 5;
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
  stamina: Stamina;
  /** The gait it actually moved with on the last step (what a player's input would say). */
  moveGait: Gait;
  /** Seconds of alarm left: it glanced back and saw the Orderly close. */
  alarm: number;
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
    stamina: freshStamina(),
    moveGait: 'walk',
    alarm: 0,
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

/** Whether a threat is close behind a bot: same level, in range, behind its direction of travel. */
export function threatBehind(bot: Bot, threat: { x: number; z: number; level: number } | null | undefined): boolean {
  if (!threat || threat.level !== bot.body.level) return false;
  const dx = threat.x - bot.body.x;
  const dz = threat.z - bot.body.z;
  const d = Math.hypot(dx, dz);
  if (d > BOT_FLEE_RANGE || d < 1e-6) return false;
  // Forward is (-sin h, -cos h), three.js style.
  return -Math.sin(bot.heading) * dx - Math.cos(bot.heading) * dz < 0;
}

/** A bot looking back over its shoulder at a threat close behind it notices it. */
function noticesBehind(bot: Bot, threat: { x: number; z: number; level: number } | null | undefined): boolean {
  return bot.look === 'behind' && threatBehind(bot, threat);
}

/**
 * Advances a bot by dt seconds (mutates it). `threat` is where the Orderly is, if the bot knows: it
 * sprints away while that is close behind and its tank allows. `cap` limits its pace (a raised
 * instrument); a capped bot cannot sprint, like a player.
 */
export function stepBot(plan: FloorPlan, bot: Bot, dt: number, threat?: { x: number; z: number; level: number } | null, cap = Infinity): void {
  bot.gaitLeft -= dt;
  if (bot.gaitLeft <= 0) newGait(bot);
  const before0 = bot.body;
  bot.alarm = noticesBehind(bot, threat) ? BOT_ALARM_TIME : Math.max(0, bot.alarm - dt);
  const flee = bot.gait !== 'stop' && bot.alarm > 0 && threatBehind(bot, threat);
  bot.moveGait = bot.gait === 'stop' ? 'walk' : gaitFor(bot.stamina, { sprint: flee, creep: bot.gait === 'creep' && !flee, moving: true, cap });

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
      const speed = speedFor(bot.moveGait, cap);
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

  const moved = Math.hypot(bot.body.x - before0.x, bot.body.z - before0.z);
  bot.stamina = stepStamina(bot.stamina, bot.moveGait, dt > 0 ? moved / dt : 0, dt);

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
