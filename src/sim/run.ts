// A run: the ride down. Pure, deterministic logic for the shape of a run and the elevator's rules;
// no rendering, audio or browser code. The game calls stepRun once per logic tick.
//
// The elevator is the bank, the briefing room and the only safe place. Per tick, in this order:
//   1. run rules: phase timers, the call and its indicator, light blinks, boarding, votes, the
//      bell, departures and arrivals;
//   2. the Orderly, with every player `blind` during a blink, players inside the car never
//      huntable, and (while the car is coming) the call itself as a blind target at the landing;
//   3. the crew's instruments, then pick-ups; readings that close are multiplied by the depth's pay.
//
// The car is the void 2 m cell on the far side of the landing's elevator wall (landing.ts says which
// wall). It is outside the floor plan, so nothing that moves with the plan's collision (the Orderly)
// can ever enter it; run.ts checks that anyway every tick and puts it back if it ever ended inside.
// Players get in and out through the doorway with moveInRun, which knows when the doors are open.
//
// Choices made where the design is silent (also listed in the report):
//  - Seeing out of the car: with the doors open, a player inside sees the floor as if their eyes stood
//    on the threshold (generous: it can only add sightings). With the doors shut they see nothing out.
//  - "Drawn to the call": the call is an extra blind target at the landing; the Orderly hunts the
//    nearest of it and the players by walking distance, and the pull ends once it is within
//    LURE_DROP_DISTANCE of the landing. A waiting Orderly is not woken by the call.
//  - Arrival: anyone still in the car when the arrival doors close is put out onto the landing.
//  - Caught players stay inactive until the car next RIDES DOWN (not when it leaves empty).
//  - The depth multiplier compounds and is applied when a reading closes onto a tape.
//  - Each floor's Orderly is a new subject (entity id `orderly-<depth>`), so repeat factors restart.
//  - The lights while the car comes (darkSchedule): blinks that grow, then the blackout, ending on the
//    tick the car arrives. A false stop (one floor above, in the last few seconds) always falls inside
//    the blackout: it is heard in the dark, and the blackout still ends as the doors really open.
//  - In the blackout the Orderly hunts at BLACKOUT_HUNT_SPEED and does not creep up on still prey (the
//    creep is there so a recorder can time a turn; nobody can see to do that in the dark). In the
//    short blinks it hunts exactly as before.
//  - BANK is the left half of the car as you walk in, DOWN the right half.

import { createOrderly, HUNT_SPEED, ORDERLY_RADIUS, seenBy, stepEntity, type OrderlyEvent, type OrderlyState, type PlayerView } from './entity';
import { generateClinic } from './clinic';
import { DIR_VEC, type Dir, type FloorPlan, type Level } from './floor';
import {
  createCrew,
  feetDistance,
  leaveFloor,
  pickUpTape,
  PICKUP_REACH,
  setRaised,
  stepCrew,
  type CrewEvent,
  type CrewMember,
  type CrewPlayer,
  type CrewState,
  type EntityTick,
} from './instrument';
import { elevatorWall } from './landing';
import { LEVEL_HEIGHT, moveWithCollision, type Body } from './move';
import { makeRng } from './rng';
import { emptyTape, tapeValue, type Tape } from './tape';

// ---------------------------------------------------------------------------------------------
// Tuning.

/** Width of the car along the elevator wall, metres (one cell). */
export const CAR_WIDTH = 2;
/** Depth of the car away from the landing, metres (one cell). */
export const CAR_DEPTH = 2;
/** Width of the door opening, centred on the landing cell's elevator wall, metres. */
export const CAR_DOOR_WIDTH = 1.2;
/** Seconds the car sits with its doors shut on arrival before they open. */
export const ARRIVE_DOOR_DELAY = 1;
/** On arrival the doors close this long after the last active player stepped out (seconds)... */
export const UNLOAD_EMPTY_CLOSE = 2;
/** ...or after this long regardless (seconds); then the car leaves. It is not waiting for you. */
export const UNLOAD_TIME = 12;
/** A player whose feet are within this distance (metres) of the door's centre can call the car. */
export const CALL_REACH = 2.2;
/** Seconds between the call and the car starting to move (drawn per call, uniform). */
export const CALL_START_DELAY_MIN = 1;
export const CALL_START_DELAY_MAX = 3;
/** How many floors away the car starts (drawn per call, never the same as the previous call). */
export const CALL_FLOORS_MIN = 6;
export const CALL_FLOORS_MAX = 12;
/** Seconds per floor on the indicator. Constant, so a player can read the wait: floors x 4 s. */
export const FLOOR_TIME = 4;
/** Chance per call that the car stops one floor above first. */
export const FALSE_STOP_CHANCE = 0.25;
/** Extra seconds a false stop costs (drawn per call, uniform). */
export const FALSE_STOP_EXTRA_MIN = 3.5;
export const FALSE_STOP_EXTRA_MAX = 5;
/** During a false stop, doors are heard opening this long after the chime (seconds)... */
export const FALSE_STOP_DOORS_OPEN_AT = 0.8;
/** ...and heard closing this long before the car moves on (seconds). */
export const FALSE_STOP_DOORS_CLOSE_BEFORE = 1.2;
/**
 * The lights while the car is coming (see darkSchedule): blinks that grow, then the blackout that ends
 * as the doors open. Blink lengths in order (seconds); a short wait uses only the first few.
 */
export const BLINK_LADDER: readonly number[] = [1, 1.5, 2.5, 4, 6];
/**
 * The lit gap after each blink, before the next warning (seconds, drawn uniform per gap), nearest the
 * blackout first: the gaps shrink as the blackout nears. Spare time in a long wait stretches them
 * (each to at most BLINK_GAP_STRETCH_MAX).
 */
export const BLINK_GAPS: readonly (readonly [number, number])[] = [
  [3, 4],
  [3.5, 4.5],
  [4, 5],
  [4.5, 5.5],
  [5, 6],
];
export const BLINK_GAP_STRETCH_MAX = 9;
/** The first warning comes no sooner than this after the call (seconds). */
export const BLINK_FIRST_AFTER = 2.5;
/** How far ahead of a blink the game is told, so the screen and sound can telegraph it (seconds). */
export const BLINK_WARNING = 0.6;
/** The blackout: the last dark stretch of a wait, ending as the car's doors open (seconds, uniform)... */
export const BLACKOUT_MIN = 12;
export const BLACKOUT_MAX = 15;
/** ...shorter on the first floor of a run... */
export const BLACKOUT_FIRST_MIN = 9;
export const BLACKOUT_FIRST_MAX = 10;
/** ...and its warning, long and unmistakable (seconds). */
export const BLACKOUT_WARNING = 3;
/** The Orderly's hunting speed while the blackout is on (m/s; see entity.ts HUNT_SPEED). */
export const BLACKOUT_HUNT_SPEED = HUNT_SPEED;
/** The boarding window: seconds from the doors opening to the bell, not counting holds. */
export const BOARD_TIME = 20;
/** Total seconds the doors can be held per stop. */
export const HOLD_LIMIT = 15;
/** Seconds the ride down takes, doors shut. */
export const RIDE_TIME = 6;
/** Pay multiplier per floor of depth: readings closed at depth d are worth DEPTH_PAY_STEP^(d-1). */
export const DEPTH_PAY_STEP = 1.35;
/** The call stops pulling the Orderly once its centre is within this distance (metres) of the landing's centre. */
export const LURE_DROP_DISTANCE = 3;
/** Longest tick stepRun takes in one go (seconds); longer dt is split. Keeps the lure provably uncatchable. */
export const MAX_TICK = 0.1;
/** Id the call uses as a target in the Orderly's player list. Never a real player id. */
export const LURE_ID = '#call';

const EPS = 1e-9;
/** How far onto the landing side of the wall line the doorway channel reaches, beyond a body's radius. */
const DOOR_ZONE_SLACK = 0.01;

// ---------------------------------------------------------------------------------------------
// The car.

/**
 * Where the car is, in world metres. Local coordinates: u is the distance past the wall line into the
 * car (0 at the doors, CAR_DEPTH at the back), v is sideways, positive to the right as you walk in.
 */
export interface CarGeometry {
  /** Which side of the landing cell the doors are on. */
  wall: Dir;
  level: Level;
  /** Height of the car floor. */
  floorY: number;
  /** Centre of the door opening on the wall line. */
  doorX: number;
  doorZ: number;
  /** Unit vector from the landing into the car, and the unit vector to the right walking in. */
  inX: number;
  inZ: number;
  rightX: number;
  rightZ: number;
  width: number;
  depth: number;
  doorWidth: number;
  /** The car's floor as an axis-aligned rectangle (it is one plan cell). */
  rect: Rect;
  /** The BANK half (left walking in) and the DOWN half (right walking in). */
  bank: Rect;
  down: Rect;
}

export interface Rect {
  x0: number;
  z0: number;
  x1: number;
  z1: number;
}

export type Side = 'bank' | 'down';

function rectOf(points: readonly [number, number][]): Rect {
  const xs = points.map((p) => p[0]);
  const zs = points.map((p) => p[1]);
  return { x0: Math.min(...xs), z0: Math.min(...zs), x1: Math.max(...xs), z1: Math.max(...zs) };
}

/** The car for a floor plan. */
export function carGeometry(plan: FloorPlan): CarGeometry {
  const wall = elevatorWall(plan) ?? 'n';
  const v = DIR_VEC[wall];
  const s = plan.cellSize;
  const { level, x, y } = plan.landing;
  const doorX = (x + 0.5) * s + v.dx * (s / 2);
  const doorZ = (y + 0.5) * s + v.dy * (s / 2);
  const inX = v.dx;
  const inZ = v.dy;
  // Right as you face (inX, inZ), three.js style top-down: facing -z, right is +x.
  const rightX = -inZ;
  const rightZ = inX;
  const at = (u: number, w: number): [number, number] => [doorX + inX * u + rightX * w, doorZ + inZ * u + rightZ * w];
  const hw = CAR_WIDTH / 2;
  return {
    wall,
    level,
    floorY: level === 1 ? LEVEL_HEIGHT : 0,
    doorX,
    doorZ,
    inX,
    inZ,
    rightX,
    rightZ,
    width: CAR_WIDTH,
    depth: CAR_DEPTH,
    doorWidth: CAR_DOOR_WIDTH,
    rect: rectOf([at(0, -hw), at(CAR_DEPTH, hw)]),
    bank: rectOf([at(0, -hw), at(CAR_DEPTH, 0)]),
    down: rectOf([at(0, 0), at(CAR_DEPTH, hw)]),
  };
}

/** World position to car-local (u into the car, v to the right). */
export function carLocal(car: CarGeometry, x: number, z: number): { u: number; v: number } {
  const dx = x - car.doorX;
  const dz = z - car.doorZ;
  return { u: dx * car.inX + dz * car.inZ, v: dx * car.rightX + dz * car.rightZ };
}

/** A body standing at car-local (u, v). */
export function carBody(car: CarGeometry, u: number, v: number): Body {
  return { x: car.doorX + car.inX * u + car.rightX * v, z: car.doorZ + car.inZ * u + car.rightZ * v, level: car.level, y: car.floorY };
}

/** Whether a body's centre is inside the car. */
export function inCar(car: CarGeometry, b: Body): boolean {
  if (b.level !== car.level) return false;
  const { u, v } = carLocal(car, b.x, b.z);
  return u > 0 && u <= car.depth + EPS && Math.abs(v) <= car.width / 2 + EPS;
}

/** Which half of the car a body stands on, or null if it is not inside. */
export function carSide(car: CarGeometry, b: Body): Side | null {
  if (!inCar(car, b)) return null;
  return carLocal(car, b.x, b.z).v < 0 ? 'bank' : 'down';
}

/** Spawn spots inside the car, by player index. */
function carSlot(car: CarGeometry, i: number): Body {
  const slots: readonly [number, number][] = [
    [0.7, -0.5],
    [0.7, 0.5],
    [1.4, -0.5],
    [1.4, 0.5],
  ];
  const sl = slots[i % slots.length] ?? [1, 0];
  return carBody(car, sl[0], sl[1]);
}

/** Spots on the landing just outside the doors, by index. */
function landingSlot(car: CarGeometry, i: number): Body {
  const vs = [-0.5, 0.5, -0.1, 0.3];
  return carBody(car, -0.8 - 0.3 * Math.floor(i / vs.length), vs[i % vs.length] ?? 0);
}

// ---------------------------------------------------------------------------------------------
// The call schedule.

export interface CallPlan {
  /** Seconds before the car starts moving. */
  delay: number;
  /** Floors away it starts. */
  floors: number;
  falseStop: boolean;
  /** Extra seconds the false stop costs (0 without one). */
  extra: number;
  /** Total seconds from the call to the car arriving. */
  wait: number;
  /** The dark stretches of this wait, in order; the last is the blackout. */
  darks: DarkStretch[];
}

/** One dark stretch of a wait. Times in seconds after the call. */
export interface DarkStretch {
  /** When the lights go out. */
  at: number;
  /** How long they stay out (the blackout's ends as the car arrives: at + len === wait). */
  len: number;
  /** How long before `at` the warning starts. */
  warn: number;
  /** The last and longest: the blackout. */
  blackout: boolean;
}

/** The schedule of the `index`-th call of a run (0-based) at `depth`. Never starts from `prevFloors` floors away. */
export function callPlan(seed: string, index: number, prevFloors: number | null, depth = 1): CallPlan {
  const rng = makeRng(seed).fork(`call:${index}`);
  const delay = CALL_START_DELAY_MIN + rng.next() * (CALL_START_DELAY_MAX - CALL_START_DELAY_MIN);
  let floors = rng.int(CALL_FLOORS_MIN, CALL_FLOORS_MAX);
  if (floors === prevFloors) floors = floors === CALL_FLOORS_MAX ? CALL_FLOORS_MIN : floors + 1;
  const falseStop = rng.chance(FALSE_STOP_CHANCE);
  const extra = falseStop ? FALSE_STOP_EXTRA_MIN + rng.next() * (FALSE_STOP_EXTRA_MAX - FALSE_STOP_EXTRA_MIN) : 0;
  const wait = delay + floors * FLOOR_TIME + extra;
  return { delay, floors, falseStop, extra, wait, darks: darkSchedule(seed, index, wait, depth) };
}

/**
 * The lights of one wait, laid out when the car is called, from the run's seed alone. The last dark
 * stretch is the blackout: BLACKOUT_MIN..MAX seconds (less on the first floor), ending exactly when the
 * car arrives, after a BLACKOUT_WARNING warning. Before it, blinks of BLINK_LADDER lengths, each longer
 * than the last, with lit gaps that shrink toward the blackout. As many blinks as fit after
 * BLINK_FIRST_AFTER (a short wait gets fewer, never no blackout); spare time stretches the gaps
 * and delays the first blink.
 * Every wait draws the same seven numbers, whatever fits.
 */
export function darkSchedule(seed: string, index: number, wait: number, depth: number): DarkStretch[] {
  const rng = makeRng(seed).fork(`call:${index}:dark`);
  const [lo, hi] = depth <= 1 ? [BLACKOUT_FIRST_MIN, BLACKOUT_FIRST_MAX] : [BLACKOUT_MIN, BLACKOUT_MAX];
  const black = Math.min(lo + rng.next() * (hi - lo), Math.max(1, wait - BLACKOUT_WARNING));
  const gaps = BLINK_GAPS.map(([a, b]) => a + rng.next() * (b - a));
  // Of any spare time, this share (up to half) goes before the first blink, the rest into the gaps.
  const lead = rng.next() * 0.5;
  const blackAt = wait - black;
  const room = blackAt - BLACKOUT_WARNING - BLINK_FIRST_AFTER;
  const need = (n: number): number => {
    let s = 0;
    for (let k = 0; k < n; k++) s += (BLINK_LADDER[k] ?? 0) + BLINK_WARNING + (gaps[k] ?? 0);
    return s;
  };
  let n = BLINK_LADDER.length;
  while (n > 0 && need(n) > room + 1e-9) n--;
  // Spare time stretches the gaps evenly (each capped), so a long wait keeps its blinks spread out.
  const spare = room - need(n);
  const used = gaps.slice(0, n);
  const stretch = n > 0 ? (spare * (1 - lead)) / n : 0;
  const gap = used.map((g) => Math.min(BLINK_GAP_STRETCH_MAX, g + stretch));
  const out: DarkStretch[] = [{ at: blackAt, len: black, warn: BLACKOUT_WARNING, blackout: true }];
  let cursor = blackAt - BLACKOUT_WARNING;
  // Backwards from the blackout: the longest blink nearest it.
  for (let k = n - 1; k >= 0; k--) {
    const len = BLINK_LADDER[k] ?? 1;
    const end = cursor - (gap[n - 1 - k] ?? 0);
    const at = end - len;
    out.unshift({ at, len, warn: BLINK_WARNING, blackout: false });
    cursor = at - BLINK_WARNING;
  }
  return out;
}

/** Readings closed at this depth are worth this many times their recorded value. */
export function depthMultiplier(depth: number): number {
  return DEPTH_PAY_STEP ** Math.max(0, depth - 1);
}

// ---------------------------------------------------------------------------------------------
// Types.

export type RunPhase =
  /** Car here, doors shut, about to open onto the floor. */
  | 'arriving'
  /** Doors open on arrival; they close once everyone is out or after UNLOAD_TIME. */
  | 'unloading'
  /** Car gone; it must be called. */
  | 'away'
  /** Called and on its way. */
  | 'coming'
  /** Doors open, the bell is counting. */
  | 'boarding'
  /** Doors shut, going down. */
  | 'riding'
  | 'ended';

export type PlayerStatus = 'ok' | 'caught' | 'leftBehind';

export interface RunPlayer {
  id: string;
  /** Where the run last knew them (from the inputs, or where it placed them). */
  body: Body;
  status: PlayerStatus;
  /** Inside the car this tick. */
  aboard: boolean;
  /** Their vote: the half of the car they stand on (null when not aboard or not active). */
  side: Side | null;
}

export interface CallState {
  index: number;
  /** Run time of the call. */
  at: number;
  plan: CallPlan;
  /** What the indicator shows: floors away. */
  floorsAway: number;
  /** Run time the indicator next changes (or the car arrives). */
  nextAt: number;
  /** False stop in progress: run time it ends, and which of its sounds have played. */
  stopUntil: number | null;
  stopDoorsOpened: boolean;
  stopDoorsClosed: boolean;
}

export interface BlinkState {
  callIndex: number;
  /** Blink number within the call. */
  n: number;
  /** Run time this blink starts. */
  at: number;
  /** Seconds it lasts (the blackout's is nominal: it ends when the car arrives). */
  len: number;
  /** Seconds of warning before `at`. */
  warn: number;
  /** The wait's last dark stretch: the blackout. */
  blackout: boolean;
  announced: boolean;
  /** Run time it ends once started, else null. */
  endsAt: number | null;
}

export interface RunSummary {
  /** Deepest floor reached. */
  depth: number;
  /** Readings on the banked tapes. */
  readings: number;
  total: number;
  /** Each player's share: the total split evenly between everyone in the run. */
  shares: Record<string, number>;
  /** Tapes banked. */
  tapes: string[];
  wiped: boolean;
}

export interface RunState {
  seed: string;
  /** Run time, seconds. */
  t: number;
  depth: number;
  plan: FloorPlan;
  car: CarGeometry;
  orderly: OrderlyState;
  /** Entity id of this floor's Orderly. */
  entityId: string;
  crew: CrewState;
  players: readonly RunPlayer[];
  phase: RunPhase;
  /** Seconds left in a timed phase (arriving, unloading, riding). */
  timer: number;
  /** Unloading: seconds the car has been empty of active players. */
  emptyFor: number;
  calls: number;
  lastFloors: number | null;
  call: CallState | null;
  blink: BlinkState | null;
  /** The Orderly is being pulled toward the landing by the call. */
  lure: boolean;
  /** Boarding: seconds of boarding window left, hold seconds left, whether the doors are held. */
  bellLeft: number;
  holdLeft: number;
  held: boolean;
  /** Set when the run ends (banked or wiped). */
  summary: RunSummary | null;
}

export interface PlayerInput {
  id: string;
  body: Body;
  /** Eye height above the feet, yaw/pitch three.js style, full fields of view in degrees. */
  eye: number;
  yaw: number;
  pitch: number;
  hFovDeg: number;
  vFovDeg: number;
  /** Pressing the call button. */
  call?: boolean;
  /** Holding the doors (only counts from inside the car while boarding). */
  holdDoors?: boolean;
  /** Instrument raised. */
  raised?: boolean;
  /** Pick up a tape: its id, or true for the nearest one within reach. */
  pickUp?: string | true;
  /** Sees nothing this tick, though present and huntable (the host's call: see net/host.ts). */
  blind?: boolean;
}

export type RunEvent =
  | { type: 'doorsOpened'; t: number; depth: number; reason: 'arrival' | 'boarding' }
  | { type: 'doorsClosed'; t: number; aboard: string[]; pushedOut: Record<string, Body> }
  | { type: 'carLeft'; t: number; reason: 'unloaded' | 'empty' | 'ride' }
  | { type: 'called'; t: number; playerId: string; floorsAway: number; at: Body }
  | { type: 'indicator'; t: number; floorsAway: number; floor: number }
  | { type: 'falseStop'; t: number; extra: number }
  | { type: 'falseStopDoors'; t: number; open: boolean }
  | { type: 'blinkSoon'; t: number; at: number; len: number; blackout: boolean }
  | { type: 'blinkStart'; t: number; len: number; blackout: boolean }
  | { type: 'blinkEnd'; t: number; blackout: boolean }
  | { type: 'carArrived'; t: number; wait: number }
  | { type: 'holdChanged'; t: number; held: boolean; holdLeft: number }
  | { type: 'bell'; t: number; bank: number; down: number; outcome: 'bank' | 'ride' | 'empty' }
  | { type: 'voteChanged'; t: number; playerId: string; side: Side | null }
  | { type: 'leftBehind'; t: number; playerId: string; lostTapes: string[]; lostValue: number }
  | { type: 'floorTapesLost'; t: number; tapes: string[]; lostValue: number }
  | { type: 'rodeDown'; t: number; depth: number; bodies: Record<string, Body> }
  | { type: 'banked'; t: number; summary: RunSummary }
  | { type: 'wiped'; t: number; summary: RunSummary }
  | OrderlyEvent
  | CrewEvent;

export interface RunStep {
  state: RunState;
  events: RunEvent[];
}

// ---------------------------------------------------------------------------------------------
// Creating a run.

function floorFor(seed: string, depth: number): { plan: FloorPlan; car: CarGeometry; orderly: OrderlyState; entityId: string } {
  const plan = generateClinic(seed, depth);
  return { plan, car: carGeometry(plan), orderly: createOrderly(plan), entityId: `orderly-${depth}` };
}

/** A new run: the crew in the car at floor 1's landing, doors about to open. */
export function createRun(seed: string, playerIds: readonly string[]): RunState {
  if (playerIds.length === 0) throw new RangeError('a run needs at least one player');
  if (new Set(playerIds).size !== playerIds.length || playerIds.includes(LURE_ID)) throw new RangeError('player ids must be unique and not the call id');
  const f = floorFor(seed, 1);
  return {
    seed,
    t: 0,
    depth: 1,
    plan: f.plan,
    car: f.car,
    orderly: f.orderly,
    entityId: f.entityId,
    crew: createCrew(playerIds),
    players: playerIds.map((id, i) => ({ id, body: carSlot(f.car, i), status: 'ok', aboard: true, side: null })),
    phase: 'arriving',
    timer: ARRIVE_DOOR_DELAY,
    emptyFor: 0,
    calls: 0,
    lastFloors: null,
    call: null,
    blink: null,
    lure: false,
    bellLeft: 0,
    holdLeft: 0,
    held: false,
    summary: null,
  };
}

/** Whether the car's doors are open at this floor's landing. */
export function doorsOpen(state: RunState): boolean {
  return state.phase === 'unloading' || state.phase === 'boarding';
}

/** Whether every player is blind this tick (a blink is on). */
export function blinking(state: RunState): boolean {
  return state.blink !== null && state.blink.endsAt !== null;
}

/** Whether the blackout (the wait's last, long dark) is on this tick. */
export function blackedOut(state: RunState): boolean {
  return blinking(state) && state.blink?.blackout === true;
}

/** The `n`-th dark stretch of a call as run state (unannounced), or null past the last. */
function blinkOf(call: CallState, n: number): BlinkState | null {
  const d = call.plan.darks[n];
  if (!d) return null;
  return { callIndex: call.index, n, at: call.at + d.at, len: d.len, warn: d.warn, blackout: d.blackout, announced: false, endsAt: null };
}

// ---------------------------------------------------------------------------------------------
// Moving bodies with the car in mind.

/**
 * Moves a player's body by (dx, dz) like moveWithCollision, except that the car's doorway is open
 * while the doors are, and inside the car the car's walls hold. A body caught in the doorway when
 * the doors shut is pushed to whichever side its centre is on.
 */
export function moveInRun(state: RunState, body: Body, dx: number, dz: number, radius: number): Body {
  const dist = Math.hypot(dx, dz);
  const n = Math.max(1, Math.ceil(dist / 0.05));
  let cur = body;
  for (let i = 0; i < n; i++) cur = moveStep(state.plan, state.car, doorsOpen(state), cur, dx / n, dz / n, radius);
  return cur;
}

function clamp(x: number, lo: number, hi: number): number {
  return Math.max(lo, Math.min(hi, x));
}

function moveStep(plan: FloorPlan, car: CarGeometry, open: boolean, cur: Body, sx: number, sz: number, r: number): Body {
  if (cur.level !== car.level) return moveWithCollision(plan, cur, sx, sz, r);
  const here = carLocal(car, cur.x, cur.z);
  const next = carLocal(car, cur.x + sx, cur.z + sz);
  const band = car.doorWidth / 2 - r;
  const out = -(r + DOOR_ZONE_SLACK);
  const inChannel = (p: { u: number; v: number }): boolean => p.u > out && Math.abs(p.v) <= band + EPS;
  const zone = here.u > 0 || inChannel(here);
  if (!zone) {
    if (open && inChannel(next)) return carBody(car, next.u, next.v);
    return moveWithCollision(plan, cur, sx, sz, r);
  }
  const insideV = car.width / 2 - r;
  const maxU = car.depth - r;
  if (open && Math.abs(next.v) <= band + EPS) return carBody(car, Math.min(next.u, maxU), next.v);
  if (here.u > 0) {
    // Inside: the car's walls hold. In the open doorway, slide along it; otherwise stay clear of the front wall.
    if (open && here.u < r) return carBody(car, Math.min(next.u, maxU), clamp(next.v, -band, band));
    return carBody(car, clamp(next.u, r, maxU), clamp(next.v, -insideV, insideV));
  }
  // On the landing side of the doorway with the doors shut (or stepping sideways out of the gap): back out.
  return carBody(car, Math.min(next.u, out - 0.001), clamp(next.v, -insideV, insideV));
}

// ---------------------------------------------------------------------------------------------
// Helpers.

function viewOf(inp: PlayerInput, active: boolean, blind: boolean): PlayerView {
  return { id: inp.id, body: inp.body, eye: inp.eye, yaw: inp.yaw, pitch: inp.pitch, hFovDeg: inp.hFovDeg, vFovDeg: inp.vFovDeg, active, blind };
}

/** The view a player inside the car has of the floor: eyes moved onto the threshold. */
function thresholdView(car: CarGeometry, inp: PlayerInput): PlayerView {
  const { v } = carLocal(car, inp.body.x, inp.body.z);
  const at = carBody(car, -0.02, clamp(v, -car.doorWidth / 2, car.doorWidth / 2));
  return viewOf({ ...inp, body: { ...at, y: inp.body.y } }, true, false);
}

/** Squared distance from a point to a rectangle (0 inside). */
export function rectDistance(r: Rect, x: number, z: number): number {
  const dx = Math.max(r.x0 - x, 0, x - r.x1);
  const dz = Math.max(r.z0 - z, 0, z - r.z1);
  return Math.hypot(dx, dz);
}

/** Every tape held by members, carried, or on the floor, with readings scaled by id. */
function scaleReadings(crew: CrewState, ids: ReadonlySet<string>, mult: number): CrewState {
  if (ids.size === 0 || mult === 1) return crew;
  const fix = (tape: Tape): Tape => {
    if (!tape.readings.some((r) => ids.has(r.id))) return tape;
    const readings = tape.readings.map((r) => (ids.has(r.id) ? { ...r, value: r.value * mult, peakRate: r.peakRate * mult } : r));
    return { ...tape, readings, total: readings.reduce((s, r) => s + r.value, 0) };
  };
  return {
    ...crew,
    members: crew.members.map((m) => ({ ...m, tape: fix(m.tape), carrying: m.carrying.map(fix) })),
    floor: crew.floor.map((f) => ({ ...f, tape: fix(f.tape) })),
  };
}

/** stepCrew, with closed readings multiplied by the depth's pay (tapes and events both). */
function crewTick(s: RunState, players: readonly CrewPlayer[], entities: readonly EntityTick[], dt: number): { crew: CrewState; events: CrewEvent[] } {
  const out = stepCrew(s.plan, s.crew, players, entities, dt);
  const mult = depthMultiplier(s.depth);
  const ids = new Set<string>();
  for (const e of out.events) if (e.type === 'readingClosed') ids.add(e.reading.id);
  if (ids.size === 0 || mult === 1) return out;
  const events = out.events.map((e) =>
    e.type === 'readingClosed' ? { ...e, value: e.value * mult, reading: { ...e.reading, value: e.reading.value * mult, peakRate: e.reading.peakRate * mult } } : e,
  );
  return { crew: scaleReadings(out.crew, ids, mult), events };
}

function heldTapes(m: CrewMember): Tape[] {
  return [m.tape, ...m.carrying].filter((tp) => tp.readings.length > 0);
}

function summarize(s: RunState, tapes: readonly Tape[], wiped: boolean): RunSummary {
  const total = wiped ? 0 : tapeValue(tapes);
  const share = total / s.players.length;
  return {
    depth: s.depth,
    readings: wiped ? 0 : tapes.reduce((n, tp) => n + tp.readings.length, 0),
    total,
    shares: Object.fromEntries(s.players.map((p) => [p.id, share])),
    tapes: wiped ? [] : tapes.map((tp) => tp.id),
    wiped,
  };
}

// ---------------------------------------------------------------------------------------------
// The tick.

/** Advances the run by dt seconds. Never mutates `prev`. Inputs for unknown ids are ignored. */
export function stepRun(prev: RunState, inputs: readonly PlayerInput[], dt: number): RunStep {
  if (dt > MAX_TICK + EPS) {
    const n = Math.ceil(dt / MAX_TICK - EPS);
    let state = prev;
    const events: RunEvent[] = [];
    for (let i = 0; i < n; i++) {
      const r = stepOnce(state, inputs, dt / n);
      state = r.state;
      events.push(...r.events);
    }
    return { state, events };
  }
  return stepOnce(prev, inputs, dt);
}

function stepOnce(prev: RunState, inputs: readonly PlayerInput[], dt: number): RunStep {
  if (prev.phase === 'ended') return { state: { ...prev, t: prev.t + dt }, events: [] };
  const t = prev.t + dt;
  const s: RunState = { ...prev, t };
  const events: RunEvent[] = [];
  const car = s.car;

  // Each player's input this tick; players without one stay where they were, inactive.
  const inputOf = new Map<string, PlayerInput>();
  for (const inp of inputs) inputOf.set(inp.id, inp);
  const fallback = (p: RunPlayer): PlayerInput => ({ id: p.id, body: p.body, eye: 1.65, yaw: 0, pitch: 0, hFovDeg: 90, vFovDeg: 70 });
  const inp = (p: RunPlayer): PlayerInput => inputOf.get(p.id) ?? fallback(p);
  const isActive = (p: RunPlayer): boolean => p.status === 'ok' && inputOf.has(p.id);

  let players: RunPlayer[] = prev.players.map((p) => {
    const body = inputOf.get(p.id)?.body ?? p.body;
    const aboard = inCar(car, body);
    return { ...p, body, aboard, side: p.side };
  });

  // ---- 1. Run rules.
  const activeAboard = (): RunPlayer[] => players.filter((p) => isActive(p) && p.aboard);

  // Blinks run on their own clock: once announced, a blink always happens, even after the car arrives
  // (the schedule ends each one before the blackout, so that does not happen). The blackout ends when
  // the car arrives, on the tick its doors open.
  const stepBlink = (): void => {
    const b = s.blink;
    if (!b) return;
    if (!b.announced && t >= b.at - b.warn - EPS) {
      // While the car is coming, or later if it was already scheduled to be announced before arrival.
      if (s.phase !== 'coming') {
        s.blink = null;
        return;
      }
      s.blink = { ...b, announced: true };
      events.push({ type: 'blinkSoon', t, at: b.at, len: b.len, blackout: b.blackout });
    }
    const c = s.blink;
    if (c && c.announced && c.endsAt === null && t >= c.at - EPS) {
      s.blink = { ...c, endsAt: t + c.len };
      events.push({ type: 'blinkStart', t, len: c.len, blackout: c.blackout });
    }
    const d = s.blink;
    if (d && d.endsAt !== null && (d.blackout ? s.phase !== 'coming' : t >= d.endsAt - EPS)) {
      events.push({ type: 'blinkEnd', t, blackout: d.blackout });
      s.blink = s.phase === 'coming' && s.call ? blinkOf(s.call, d.n + 1) : null;
    }
  };

  switch (s.phase) {
    case 'arriving': {
      s.timer -= dt;
      if (s.timer <= EPS) {
        s.phase = 'unloading';
        s.timer = UNLOAD_TIME;
        s.emptyFor = 0;
        events.push({ type: 'doorsOpened', t, depth: s.depth, reason: 'arrival' });
      }
      break;
    }
    case 'unloading': {
      s.timer -= dt;
      s.emptyFor = activeAboard().length === 0 ? s.emptyFor + dt : 0;
      if (s.emptyFor >= UNLOAD_EMPTY_CLOSE - EPS || s.timer <= EPS) {
        const pushedOut: Record<string, Body> = {};
        let k = 0;
        players = players.map((p): RunPlayer => {
          if (!p.aboard) return p;
          const body = landingSlot(car, k++);
          pushedOut[p.id] = body;
          return { ...p, body, aboard: false };
        });
        s.phase = 'away';
        events.push({ type: 'doorsClosed', t, aboard: [], pushedOut }, { type: 'carLeft', t, reason: 'unloaded' });
      }
      break;
    }
    case 'away': {
      const caller = players.find((p) => isActive(p) && !p.aboard && inp(p).call === true && Math.hypot(p.body.x - car.doorX, p.body.z - car.doorZ) <= CALL_REACH + EPS && p.body.level === car.level);
      if (caller) {
        const index = s.calls;
        const plan = callPlan(s.seed, index, s.lastFloors, s.depth);
        s.calls = index + 1;
        s.lastFloors = plan.floors;
        s.call = { index, at: t, plan, floorsAway: plan.floors, nextAt: t + plan.delay + FLOOR_TIME, stopUntil: null, stopDoorsOpened: false, stopDoorsClosed: false };
        s.phase = 'coming';
        s.lure = true;
        // The call is loud. If the Orderly was still standing where the floor began, it wakes now.
        if (s.orderly.mode === 'waiting') {
          s.orderly = { ...s.orderly, mode: 'hunting', replanIn: 0 };
          events.push({ type: 'startedHunting', t });
        }
        s.blink = blinkOf(s.call, 0);
        events.push({ type: 'called', t, playerId: caller.id, floorsAway: plan.floors, at: caller.body });
        events.push({ type: 'indicator', t, floorsAway: plan.floors, floor: s.depth - plan.floors });
      }
      break;
    }
    case 'coming': {
      let c: CallState | null = s.call;
      if (!c) break;
      // The indicator, floor by floor; the false stop one floor above.
      for (let guard = 0; guard < 64; guard++) {
        const stop: number | null = c.stopUntil;
        if (stop !== null) {
          if (!c.stopDoorsOpened && t >= stop - c.plan.extra + FALSE_STOP_DOORS_OPEN_AT - EPS) {
            c = { ...c, stopDoorsOpened: true };
            events.push({ type: 'falseStopDoors', t, open: true });
          }
          if (!c.stopDoorsClosed && t >= stop - FALSE_STOP_DOORS_CLOSE_BEFORE - EPS) {
            c = { ...c, stopDoorsClosed: true };
            events.push({ type: 'falseStopDoors', t, open: false });
          }
          if (t < stop - EPS) break;
          c = { ...c, nextAt: stop + FLOOR_TIME, stopUntil: null };
          continue;
        }
        if (t < c.nextAt - EPS) break;
        const floorsAway: number = c.floorsAway - 1;
        events.push({ type: 'indicator', t, floorsAway, floor: s.depth - floorsAway });
        if (floorsAway === 1 && c.plan.falseStop) {
          c = { ...c, floorsAway, stopUntil: c.nextAt + c.plan.extra };
          events.push({ type: 'falseStop', t, extra: c.plan.extra });
          continue;
        }
        c = { ...c, floorsAway, nextAt: c.nextAt + FLOOR_TIME };
        if (floorsAway <= 0) break;
      }
      s.call = c;
      if (c.floorsAway <= 0) {
        s.phase = 'boarding';
        s.lure = false;
        s.bellLeft = BOARD_TIME;
        s.holdLeft = HOLD_LIMIT;
        s.held = false;
        events.push({ type: 'carArrived', t, wait: t - c.at }, { type: 'doorsOpened', t, depth: s.depth, reason: 'boarding' });
        s.call = null;
      }
      break;
    }
    case 'boarding': {
      const aboard = activeAboard();
      const holding = s.holdLeft > EPS && aboard.some((p) => inp(p).holdDoors === true);
      if (holding !== s.held) {
        s.held = holding;
        events.push({ type: 'holdChanged', t, held: holding, holdLeft: s.holdLeft });
      }
      if (holding) {
        s.holdLeft = Math.max(0, s.holdLeft - dt);
        if (s.holdLeft <= EPS) {
          s.held = false;
          events.push({ type: 'holdChanged', t, held: false, holdLeft: 0 });
        }
      } else {
        s.bellLeft -= dt;
      }
      break;
    }
    case 'riding': {
      s.timer -= dt;
      break;
    }
  }
  stepBlink();

  // Votes: the half of the car each active player stands on, while boarding and before the bell.
  if (s.phase === 'boarding') {
    players = players.map((p): RunPlayer => {
      const side = isActive(p) ? carSide(car, p.body) : null;
      if (side !== p.side) events.push({ type: 'voteChanged', t, playerId: p.id, side });
      return { ...p, side };
    });
  }

  // The bell: count, close the doors, and go (or not).
  let departing: 'bank' | 'ride' | null = null;
  if (s.phase === 'boarding' && s.bellLeft <= EPS) {
    const aboard = activeAboard();
    const bank = aboard.filter((p) => p.side === 'bank').length;
    const down = aboard.filter((p) => p.side === 'down').length;
    const outcome = aboard.length === 0 ? 'empty' : bank > down ? 'bank' : 'ride';
    events.push({ type: 'bell', t, bank, down, outcome });
    events.push({ type: 'doorsClosed', t, aboard: aboard.map((p) => p.id), pushedOut: {} });
    s.held = false;
    if (outcome === 'empty') {
      s.phase = 'away';
      events.push({ type: 'carLeft', t, reason: 'empty' });
    } else {
      departing = outcome;
    }
  }

  if (departing === 'bank') {
    // Flush open readings of those aboard onto their tapes, then bank everything aboard.
    const aboardIds = activeAboard().map((p) => p.id);
    let crew = s.crew;
    for (const p of players) crew = setRaised(crew, p.id, false);
    const crewPlayers: CrewPlayer[] = players.map((p) => ({ id: p.id, body: p.body, active: aboardIds.includes(p.id) }));
    const flushState = { ...s, crew };
    for (let k = 0; k < 20; k++) {
      const out = crewTick(flushState, crewPlayers, [], 0.1);
      flushState.crew = out.crew;
      events.push(...out.events.map((e) => ({ ...e, t })));
    }
    s.crew = flushState.crew;
    const dep = leaveFloor(s.crew, aboardIds);
    s.players = players;
    const summary = summarize(s, dep.carried, false);
    s.summary = summary;
    s.phase = 'ended';
    s.blink = null;
    events.push({ type: 'banked', t, summary });
    return { state: s, events };
  }

  if (departing === 'ride') {
    const aboardIds = new Set(activeAboard().map((p) => p.id));
    // Everyone not aboard is lost for this floor, with what they hold; so is everything on the floor.
    let nextTape = s.crew.nextTape;
    const members = s.crew.members.map((m) => {
      if (aboardIds.has(m.id)) return m;
      const lost = heldTapes(m);
      events.push({ type: 'leftBehind', t, playerId: m.id, lostTapes: lost.map((tp) => tp.id), lostValue: tapeValue(lost) });
      return { ...m, tape: emptyTape(`tape-${nextTape++}`, m.id), carrying: [], instrument: { ...m.instrument, current: null, raised: false } };
    });
    if (s.crew.floor.length > 0) {
      const lost = s.crew.floor.map((f) => f.tape);
      events.push({ type: 'floorTapesLost', t, tapes: lost.map((tp) => tp.id), lostValue: tapeValue(lost) });
    }
    s.crew = { ...s.crew, members, floor: [], nextTape };
    players = players.map((p): RunPlayer => (aboardIds.has(p.id) ? p : { ...p, status: p.status === 'caught' ? 'caught' : 'leftBehind', side: null }));
    s.phase = 'riding';
    s.timer = RIDE_TIME;
    s.blink = null;
    s.lure = false;
    events.push({ type: 'carLeft', t, reason: 'ride' });
  }

  // ---- 2. The Orderly (not while riding: that floor is behind the crew).
  let entityTicks: EntityTick[] = [];
  if (s.phase !== 'riding') {
    const blind = blinking(s);
    const open = doorsOpen(s);
    const views: PlayerView[] = [];
    for (const p of players) {
      const i = inp(p);
      if (!isActive(p)) {
        views.push(viewOf(i, false, false));
      } else if (p.aboard) {
        // Never huntable inside the car. With the doors open and the lights on, they still watch the floor.
        const w = thresholdView(car, i);
        if (open && !blind && i.blind !== true && seenBy(s.plan, s.orderly.body, [w]) !== null) views.push(w);
        else views.push(viewOf(i, false, false));
      } else {
        views.push(viewOf(i, true, blind || i.blind === true));
      }
    }
    // The call pulls it toward the landing, until it gets there.
    const s2 = s.plan.cellSize;
    const lx = (s.plan.landing.x + 0.5) * s2;
    const lz = (s.plan.landing.y + 0.5) * s2;
    if (s.lure && Math.hypot(s.orderly.body.x - lx, s.orderly.body.z - lz) <= LURE_DROP_DISTANCE) s.lure = false;
    if (s.lure) {
      views.push({ id: LURE_ID, body: { x: lx, z: lz, level: s.plan.landing.level, y: car.floorY }, eye: 1.6, yaw: 0, pitch: 0, hFovDeg: 1, vFovDeg: 1, active: true, blind: true });
    }
    const before = s.orderly;
    // In the blackout it runs its prey down: no creeping up on the still (that is for recording it,
    // and nobody can see to time a turn in the dark), at BLACKOUT_HUNT_SPEED.
    const res = stepEntity(s.plan, before, views, dt, blackedOut(s) ? { speed: BLACKOUT_HUNT_SPEED, creep: false } : {});
    let next = res.state;
    // Belt and braces: it can never end a tick in (or overlapping) the car.
    if (rectDistance(car.rect, next.body.x, next.body.z) < ORDERLY_RADIUS - 1e-3 && next.body.level === car.level) next = { ...next, body: before.body, moving: false, speed: 0 };
    s.orderly = next;
    const oEvents = res.events.filter((e) => !('playerId' in e) || e.playerId !== LURE_ID);
    events.push(...oEvents.map((e) => ({ ...e, t })));
    entityTicks = [{ id: s.entityId, trait: 'stillness', prev: before, next, events: oEvents }];
    for (const e of oEvents) {
      if (e.type !== 'caught') continue;
      players = players.map((p): RunPlayer => (p.id === e.playerId ? { ...p, status: 'caught', side: null } : p));
    }
  }

  // ---- 3. The crew.
  let crew = s.crew;
  for (const p of players) {
    const i = inputOf.get(p.id);
    if (i && i.raised !== undefined) crew = setRaised(crew, p.id, i.raised && p.status === 'ok');
  }
  s.crew = crew;
  const crewPlayers: CrewPlayer[] = players.map((p) => ({ id: p.id, body: p.body, active: isActive(p) }));
  const out = crewTick(s, crewPlayers, entityTicks, dt);
  s.crew = out.crew;
  events.push(...out.events.map((e) => ({ ...e, t })));
  for (const p of players) {
    const want = inputOf.get(p.id)?.pickUp;
    if (want === undefined || !isActive(p)) continue;
    const m = s.crew.members.find((x) => x.id === p.id);
    let tapeId: string | null = null;
    if (want === true) {
      let best = Number.POSITIVE_INFINITY;
      for (const f of s.crew.floor) {
        const d = m?.body ? feetDistance(m.body, f.at) : Number.POSITIVE_INFINITY;
        if (d <= PICKUP_REACH + EPS && d < best) {
          best = d;
          tapeId = f.tape.id;
        }
      }
    } else tapeId = want;
    if (tapeId === null) continue;
    const up = pickUpTape(s.crew, p.id, tapeId);
    if (up.ok) {
      s.crew = up.crew;
      if (up.event) events.push({ ...up.event, t });
    }
  }

  // ---- Arriving on the next floor.
  if (s.phase === 'riding' && s.timer <= EPS) {
    const depth = s.depth + 1;
    const f = floorFor(s.seed, depth);
    const bodies: Record<string, Body> = {};
    players = players.map((p, i): RunPlayer => {
      let body: Body;
      if (p.status === 'ok' && inCar(car, p.body)) {
        const { u, v } = carLocal(car, p.body.x, p.body.z);
        body = carBody(f.car, u, v);
      } else {
        body = carSlot(f.car, i);
      }
      bodies[p.id] = body;
      return { ...p, body, status: 'ok', aboard: true, side: null };
    });
    s.depth = depth;
    s.plan = f.plan;
    s.car = f.car;
    s.orderly = f.orderly;
    s.entityId = f.entityId;
    s.crew = { ...s.crew, members: s.crew.members.map((m) => ({ ...m, body: bodies[m.id] ?? m.body, active: true })) };
    s.phase = 'arriving';
    s.timer = ARRIVE_DOOR_DELAY;
    events.push({ type: 'rodeDown', t, depth, bodies });
  }

  s.players = players;

  // ---- A wipe: nobody left who can call or board.
  if (s.phase !== 'riding' && players.every((p) => p.status !== 'ok')) {
    const summary = summarize(s, [], true);
    s.summary = summary;
    s.phase = 'ended';
    s.blink = null;
    events.push({ type: 'wiped', t, summary });
  }
  return { state: s, events };
}
