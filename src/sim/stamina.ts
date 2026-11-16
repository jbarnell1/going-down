// How fast a player may move, and for how long. Pure logic, shared by the game, bots and tests.
//
// The Orderly hunts faster than a walk. A player who only walks is slowly run down; a player who
// sprints pulls away but tires. Mixing the two over a long stretch keeps you ahead of it, but only
// just: on the numbers below a perfect run-and-walk cycle averages about 3.8 m/s against the
// Orderly's 3.7. So fleeing is never a plan by itself. You have to look back and freeze it.

/** Metres per second. */
export const WALK_SPEED = 3.0;
export const SPRINT_SPEED = 5.0;
export const CREEP_SPEED = 1.2;

/** Seconds of sprinting on a full tank. */
export const SPRINT_SECONDS = 5;
/** Seconds to refill from empty while walking, and while standing still or creeping. */
export const RECOVER_WALKING = 8;
export const RECOVER_RESTING = 5;
/** After running dry you cannot sprint again until the tank is back to this share. */
export const WINDED_UNTIL = 0.35;
/** Sprinting only counts when you are actually covering ground (m/s). */
const MOVING = 0.5;

export type Gait = 'creep' | 'walk' | 'sprint';

export interface Stamina {
  /** 0 (empty) to 1 (full). */
  level: number;
  /** True from running dry until the tank passes WINDED_UNTIL; the sprint key does nothing meanwhile. */
  winded: boolean;
}

export const freshStamina = (): Stamina => ({ level: 1, winded: false });

export interface GaitWish {
  sprint: boolean;
  creep: boolean;
  /** Whether the player is trying to move at all. */
  moving: boolean;
  /** A speed cap from something held, such as the raised instrument; Infinity for none. */
  cap: number;
}

/** The gait a player actually gets this tick. Creep wins over sprint; a capped player cannot sprint. */
export function gaitFor(st: Stamina, wish: GaitWish): Gait {
  if (wish.creep) return 'creep';
  if (wish.sprint && wish.moving && !st.winded && st.level > 0 && wish.cap >= SPRINT_SPEED) return 'sprint';
  return 'walk';
}

export function speedFor(gait: Gait, cap = Infinity): number {
  const s = gait === 'sprint' ? SPRINT_SPEED : gait === 'creep' ? CREEP_SPEED : WALK_SPEED;
  return Math.min(s, cap);
}

/**
 * Advances stamina by dt seconds. `groundSpeed` is how fast the player really moved (m/s), so that
 * sprinting into a wall costs nothing and standing still recovers fastest.
 */
export function stepStamina(st: Stamina, gait: Gait, groundSpeed: number, dt: number): Stamina {
  let level = st.level;
  let winded = st.winded;
  if (gait === 'sprint' && groundSpeed > MOVING) {
    level -= dt / SPRINT_SECONDS;
    if (level <= 0) {
      level = 0;
      winded = true;
    }
  } else {
    const resting = gait === 'creep' || groundSpeed <= MOVING;
    level = Math.min(1, level + dt / (resting ? RECOVER_RESTING : RECOVER_WALKING));
    if (winded && level >= WINDED_UNTIL) winded = false;
  }
  return { level, winded };
}

/**
 * How out of breath a player is: 0 on a full tank, rising as it empties, and from 0.7 up to 1 while
 * winded. The game turns it into breathing and a darkening at the edge of the view (no meter).
 */
export function exertion(st: Stamina): number {
  if (st.winded) return 0.7 + 0.3 * Math.max(0, 1 - st.level / WINDED_UNTIL);
  return Math.max(0, Math.min(1, 1 - st.level));
}

/** Average speed of the best endless run-then-walk cycle: what a fleeing player can sustain. */
export function sustainedFleeSpeed(): number {
  // Sprint from full to empty, walk until the winded mark is passed, sprint again from there.
  const sprintTime = SPRINT_SECONDS * WINDED_UNTIL;
  const walkTime = RECOVER_WALKING * WINDED_UNTIL;
  // The first cycle from a full tank is better; this is the steady state once tired.
  return (sprintTime * SPRINT_SPEED + walkTime * WALK_SPEED) / (sprintTime + walkTime);
}
