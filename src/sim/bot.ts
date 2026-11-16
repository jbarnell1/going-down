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

import { cellAt, distancesFrom, findPath, isWalkable, posFromIndex, reachableFrom, type FloorPlan, type Pos } from './floor';
import { pathDone, stepPathWalk, type PathWalk } from './follow';
import { bodyAtCell, cellOf, type Body } from './move';
import { makeRng, type Rng } from './rng';
import { HEAR_RANGE, HUNT_SPEED, type PlayerView } from './entity';
import { carBody, doorsOpen, moveInRun, type PlayerInput, type RunState } from './run';
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

// ---------------------------------------------------------------------------------------------
// Waiting for the car: two ways a crew can live through the wait, for the blackout's tuning tests.
//
//   'stay'  stands on the landing the whole wait, watching the Orderly whenever the lights are on,
//           and boards when the doors open. In the dark it can do nothing.
//   'flee'  watches it while the lights are on and keeps a few metres from it. When a dark stretch
//           is announced that would let it reach them, and always for the blackout, it gets moving
//           during the warning (walking, still watching it), then runs in the dark: away from where it
//           is heard, to places it can reach first, never into a room (rooms are dead ends), choosing
//           again whenever it gets there, sprinting while it is heard close. When the lights come
//           back it heads for the landing, watching it whenever it can, and boards; whoever is aboard
//           holds the doors while someone is still coming.
// Deterministic: no random draws at all; ties go to the lower cell index.

/** Within this straight-line distance (m) a waiting bot hears the Orderly in the dark. */
export const WAIT_HEAR_RANGE = HEAR_RANGE;
/** A 'flee' bot backs off when the lit Orderly is closer than this (m)... */
export const WAIT_KEEP_AWAY = 4.5;
/** ...runs from a short blink if the Orderly could cover the distance in it plus this margin (m)... */
export const WAIT_BLINK_MARGIN = 6;
/** ...and sprints in the dark while it is heard within this distance (m). */
export const WAIT_SPRINT_RANGE = 14;

export type WaitStyle = 'stay' | 'flee';
type WaitMode = 'hold' | 'flee' | 'return' | 'board' | 'aboard';

export interface WaitBot {
  id: string;
  style: WaitStyle;
  body: Body;
  yaw: number;
  pitch: number;
  stamina: Stamina;
  gait: Gait;
  mode: WaitMode;
  /** Where it stands on the landing, car-local (u, v). */
  spot: { u: number; v: number };
  /** Where it boards, car-local. */
  seat: { u: number; v: number };
  walk: PathWalk | null;
  route: Body[];
  /** Last place the Orderly was seen or heard. */
  heard: Body | null;
  /** Seconds until the flee goal is chosen again. */
  rethink: number;
}

/** A waiting bot standing at landing spot `k` of the car. */
export function createWaitBot(st: RunState, id: string, k: number, style: WaitStyle): WaitBot {
  const spot = { u: -0.8 - 0.4 * Math.floor(k / 2), v: k % 2 ? 0.45 : -0.45 };
  return {
    id,
    style,
    body: carBody(st.car, spot.u, spot.v),
    yaw: 0,
    pitch: 0,
    stamina: freshStamina(),
    gait: 'walk',
    mode: 'hold',
    spot,
    seat: { u: 0.7 + 0.6 * Math.floor(k / 2), v: k % 2 ? 0.5 : -0.5 },
    walk: null,
    route: [],
    heard: null,
    rethink: 0,
  };
}

/** The input a waiting bot gives the run this tick. */
export function waitBotInput(bot: WaitBot, holdDoors = false, call = false): PlayerInput {
  return { id: bot.id, body: bot.body, eye: BOT_EYE, yaw: bot.yaw, pitch: bot.pitch, hFovDeg: BOT_HFOV_DEG, vFovDeg: BOT_VFOV_DEG, holdDoors, call };
}

/** Straight-line distance on the same level, else Infinity. */
function flatGap(a: Body, b: Body): number {
  return a.level === b.level ? Math.hypot(a.x - b.x, a.z - b.z) : Number.POSITIVE_INFINITY;
}

/**
 * Where to run to: a corridor, stair or atrium cell as far from the Orderly as possible, never a
 * room; in the dark, only one the bot reaches well before the Orderly could. Null if there is none.
 */
export function fleeGoal(plan: FloorPlan, from: Body, threat: Body | null, lit: boolean): Pos | null {
  const dB = distancesFrom(plan, cellOf(plan, from));
  const dO = threat ? distancesFrom(plan, cellOf(plan, threat)) : null;
  let best = -1;
  let bestScore = Number.NEGATIVE_INFINITY;
  for (let i = 0; i < dB.length; i++) {
    const b = dB[i] ?? -1;
    if (b < 3 || b > 14) continue;
    const p = posFromIndex(plan, i);
    const kind = cellAt(plan, p.level, p.x, p.y);
    if (kind === 'room' || kind === 'void') continue;
    const o = dO ? (dO[i] ?? -1) : 99;
    if (o < 0) continue;
    // In the dark, only places it reaches first by a clear margin. In the light it is held still by
    // being watched, so walking past it to the far side is fine.
    if (!lit && o < b + 3) continue;
    const score = o - 0.25 * b;
    if (score > bestScore) {
      bestScore = score;
      best = i;
    }
  }
  return best < 0 ? null : posFromIndex(plan, best);
}

/** Aims the head at a body's chest. */
function aimAt(bot: WaitBot, target: Body): void {
  bot.yaw = Math.atan2(-(target.x - bot.body.x), -(target.z - bot.body.z));
  const d = Math.max(0.1, Math.hypot(target.x - bot.body.x, target.z - bot.body.z));
  bot.pitch = Math.atan2(target.y + 1.7 - (bot.body.y + BOT_EYE), d);
}

/** Moves along the bot's straight route, or else its path, up to `dist` metres; returns whether it moved. */
function follow(st: RunState, bot: WaitBot, dist: number): boolean {
  const before = bot.body;
  if (bot.route.length > 0) {
    let budget = dist;
    while (budget > 1e-9 && bot.route.length > 0) {
      const w = bot.route[0] as Body;
      const d = Math.hypot(w.x - bot.body.x, w.z - bot.body.z);
      if (d < 0.03) {
        bot.route.shift();
        continue;
      }
      const step = Math.min(budget, d);
      const prev = bot.body;
      bot.body = moveInRun(st, bot.body, ((w.x - bot.body.x) / d) * step, ((w.z - bot.body.z) / d) * step, BOT_RADIUS);
      budget -= step;
      if (Math.hypot(bot.body.x - prev.x, bot.body.z - prev.z) < 1e-6) break;
    }
  } else if (bot.walk) {
    bot.body = stepPathWalk(st.plan, bot.walk, bot.body, dist, BOT_RADIUS);
  }
  return Math.hypot(bot.body.x - before.x, bot.body.z - before.z) > 1e-6;
}

/** Whether the body stands in the landing cell. */
function onLanding(plan: FloorPlan, body: Body): boolean {
  const c = cellOf(plan, body);
  return c.level === plan.landing.level && c.x === plan.landing.x && c.y === plan.landing.y;
}

/**
 * Advances a waiting bot by dt (mutates it). It reads the run as a person could: where the Orderly
 * is while the lights are on (it watches it), where it is heard in the dark (within WAIT_HEAR_RANGE),
 * the warnings, and the doors.
 */
export function stepWaitBot(st: RunState, bot: WaitBot, dt: number): void {
  const plan = st.plan;
  const o = st.orderly.body;
  const b = st.blink;
  const dark = b !== null && b.endsAt !== null;
  const warn = b !== null && b.announced && b.endsAt === null ? b : null;
  const open = doorsOpen(st);
  if (!dark || flatGap(bot.body, o) <= WAIT_HEAR_RANGE) bot.heard = o;
  const threat = bot.heard;
  const near = threat ? flatGap(bot.body, threat) : Number.POSITIVE_INFINITY;
  let sprint = false;
  let moved = false;

  // The doors open (and the lights are on): everyone heads for the car.
  if (open && !dark && bot.mode !== 'board' && bot.mode !== 'aboard') {
    if (onLanding(plan, bot.body)) {
      bot.mode = 'board';
      bot.walk = null;
      bot.route = [carBody(st.car, -0.6, 0), carBody(st.car, 0.45, 0), carBody(st.car, bot.seat.u, bot.seat.v)];
    } else if (bot.mode !== 'return') {
      bot.mode = 'return';
      bot.walk = null;
      bot.route = [];
    }
  }

  switch (bot.mode) {
    case 'hold': {
      if (bot.style !== 'flee') break;
      const blinkThreat = warn !== null && !warn.blackout && near < HUNT_SPEED * warn.len + WAIT_BLINK_MARGIN;
      if (warn !== null && (warn.blackout || blinkThreat)) {
        bot.mode = 'flee';
        bot.route = [];
        bot.walk = null;
        bot.rethink = 0;
        break;
      }
      if (!dark && threat && near < WAIT_KEEP_AWAY && bot.route.length === 0) {
        // Back off, straight away from it, still watching it.
        const d = Math.max(near, 1e-6);
        const prev = bot.body;
        bot.body = moveInRun(st, bot.body, ((bot.body.x - threat.x) / d) * WALK_SPEED * dt, ((bot.body.z - threat.z) / d) * WALK_SPEED * dt, BOT_RADIUS);
        moved = Math.hypot(bot.body.x - prev.x, bot.body.z - prev.z) > 1e-6;
      }
      break;
    }
    case 'flee': {
      if (!dark && !b?.announced) {
        // The lights are back and nothing is announced: home.
        bot.mode = 'return';
        bot.walk = null;
        break;
      }
      bot.rethink -= dt;
      if (!bot.walk || pathDone(plan, bot.walk, bot.body) || bot.rethink <= 0) {
        const goal = fleeGoal(plan, bot.body, threat, !dark);
        const path = goal ? findPath(plan, cellOf(plan, bot.body), goal) : null;
        if (path && path.length > 1) bot.walk = { path, next: 1 };
        bot.rethink = 1.5;
      }
      // Lit (the warning): walk, watching it. Dark: run while it is heard close.
      sprint = dark && near < WAIT_SPRINT_RANGE;
      break;
    }
    case 'return': {
      if (warn?.blackout || (dark && b?.blackout)) {
        bot.mode = 'flee';
        bot.walk = null;
        bot.rethink = 0;
        break;
      }
      if (!bot.walk) {
        const path = findPath(plan, cellOf(plan, bot.body), plan.landing);
        bot.walk = path ? { path, next: path.length > 1 ? 1 : 0 } : null;
      }
      if (bot.walk && pathDone(plan, bot.walk, bot.body)) {
        bot.walk = null;
        if (!open) {
          bot.mode = 'hold';
          bot.route = [carBody(st.car, bot.spot.u, bot.spot.v)];
        }
      }
      // Hurry while there is far to go (it is watched while the lights are on).
      sprint = !dark && (bot.walk ? bot.walk.path.length - bot.walk.next > 6 : false);
      break;
    }
    default:
      break;
  }

  if (bot.mode === 'flee' || bot.mode === 'return' || bot.mode === 'board' || (bot.mode === 'hold' && bot.route.length > 0)) {
    bot.gait = gaitFor(bot.stamina, { sprint, creep: false, moving: true, cap: Infinity });
    moved = follow(st, bot, speedFor(bot.gait) * dt) || moved;
    if (bot.mode === 'board' && bot.route.length === 0) bot.mode = 'aboard';
  } else {
    bot.gait = 'walk';
  }
  bot.stamina = stepStamina(bot.stamina, bot.gait, moved ? speedFor(bot.gait) : 0, dt);

  // Eyes: on the Orderly whenever the lights are on (that is what holds it still); ahead in the dark.
  if (!dark && threat) aimAt(bot, threat);
  else if (bot.walk) {
    const wp = bot.walk.path[bot.walk.next];
    if (wp) bot.yaw = Math.atan2(-((wp.x + 0.5) * plan.cellSize - bot.body.x), -((wp.y + 0.5) * plan.cellSize - bot.body.z));
    bot.pitch = 0;
  }
}
