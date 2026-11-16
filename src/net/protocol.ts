// The wire protocol between the host and the players' machines. Pure data: every message is a plain
// JSON-serialisable value, versioned, and the two 20 Hz messages (input and snapshot) travel in a
// compact positional-array form. Nothing here touches the network; transport.ts moves strings.
//
// Units: positions in metres, angles in radians, times in seconds. "Host time" is the run's own clock
// (RunState.t): the host's tick k is at host time k * TICK. Client times are the client's local clock.
//
// Quantisation: positions to the centimetre, angles and clocks to the millisecond. A quantised number
// survives a JSON round trip bit for bit, so the host can compute exactly what a client drew from the
// same quantised poses the client was sent (see lerpPose and host.ts).

import type { OrderlyAnim, OrderlyMode, OrderlyState } from '../sim/entity';
import type { Level } from '../sim/floor';
import type { Needle } from '../sim/instrument';
import type { Body } from '../sim/move';
import type { PlayerStatus, RunEvent, RunPhase, RunSummary, Side } from '../sim/run';
import type { Gait, Stamina } from '../sim/stamina';

export const PROTOCOL_VERSION = 1;

export type PeerId = string;

// ---------------------------------------------------------------------------------------------
// Numbers.

/** To the centimetre. */
export function q2(x: number): number {
  const r = Math.round(x * 100) / 100;
  return r === 0 ? 0 : r; // never -0: it does not survive JSON
}

/** To the thousandth. */
export function q3(x: number): number {
  const r = Math.round(x * 1000) / 1000;
  return r === 0 ? 0 : r;
}

export function qBody(b: Body): Body {
  return { x: q2(b.x), z: q2(b.z), y: q2(b.y), level: b.level };
}

function wrapAngle(a: number): number {
  let r = a % (2 * Math.PI);
  if (r > Math.PI) r -= 2 * Math.PI;
  if (r < -Math.PI) r += 2 * Math.PI;
  return r;
}

// ---------------------------------------------------------------------------------------------
// The Orderly as drawn.

/** What a renderer needs to draw the Orderly. */
export interface Pose {
  x: number;
  y: number;
  z: number;
  level: Level;
  yaw: number;
  anim: OrderlyAnim;
  animTime: number;
}

/** The Orderly in a snapshot: its pose plus what the HUD and sound need. */
export interface OrderlySnap extends Pose {
  speed: number;
  /** Held still this tick (seen, or in its grace). */
  frozen: boolean;
  mode: OrderlyMode;
  /** During a wind-up: whom it reaches for, and the seconds of it left (frozen while it is held). */
  windUp?: { target: string; left: number };
}

export function quantPose(p: Pose): Pose {
  return { x: q2(p.x), y: q2(p.y), z: q2(p.z), level: p.level, yaw: q3(p.yaw), anim: p.anim, animTime: q3(p.animTime) };
}

/** The snapshot form of the logic's Orderly (quantised). */
export function orderlySnap(o: OrderlyState): OrderlySnap {
  return {
    x: q2(o.body.x),
    y: q2(o.body.y),
    z: q2(o.body.z),
    level: o.body.level,
    yaw: q3(o.yaw),
    anim: o.anim,
    animTime: q3(o.animTime),
    speed: q2(o.speed),
    frozen: o.held,
    mode: o.mode,
    ...(o.mode === 'windUp' && o.windUpTarget !== null ? { windUp: { target: o.windUpTarget, left: q3(o.windUpLeft) } } : {}),
  };
}

/**
 * The pose drawn between two snapshot poses, `alpha` of the way from a to b, quantised. Shared by
 * the client (to draw) and the host (to know exactly what a client drew). Across a change of level
 * it does not blend: it shows a until b's time.
 */
export function lerpPose(a: Pose, b: Pose, alpha: number): Pose {
  if (a.level !== b.level || alpha <= 0) return quantPose(a);
  if (alpha >= 1) return quantPose(b);
  const k = alpha;
  const pick = k < 0.5 ? a : b;
  const animTime = a.anim === b.anim ? a.animTime + (b.animTime - a.animTime) * k : pick.animTime;
  return quantPose({
    x: a.x + (b.x - a.x) * k,
    y: a.y + (b.y - a.y) * k,
    z: a.z + (b.z - a.z) * k,
    level: a.level,
    yaw: wrapAngle(a.yaw + wrapAngle(b.yaw - a.yaw) * k),
    anim: pick.anim,
    animTime,
  });
}

export function samePose(a: Pose, b: Pose): boolean {
  return a.x === b.x && a.y === b.y && a.z === b.z && a.level === b.level && a.yaw === b.yaw && a.anim === b.anim && a.animTime === b.animTime;
}

export function poseBody(p: Pose): Body {
  return { x: p.x, y: p.y, z: p.z, level: p.level };
}

// ---------------------------------------------------------------------------------------------
// Messages, in their readable (decoded) form.

/** A client saw the Orderly: where it was drawing it, and which snapshots that drawing came from. */
export interface SeenReport {
  /** Per-client, increasing from 1. */
  id: number;
  depth: number;
  /** Snapshot ticks the drawing was blended from, and how far between them. */
  a: number;
  b: number;
  alpha: number;
  /** The pose the client froze on (quantised; exactly what it draws). */
  pose: Pose;
}

export interface InputMsg {
  type: 'input';
  /** Per-client, increasing. */
  seq: number;
  /** Client clock at sending. */
  ct: number;
  body: Body;
  eye: number;
  yaw: number;
  pitch: number;
  hFovDeg: number;
  vFovDeg: number;
  raised: boolean;
  holdDoors: boolean;
  /** The gait asked for (creep, walk or sprint). The host decides what the tank allows. Default walk. */
  gait?: Gait;
  /** The local player saw the drawn Orderly on some frame since the last input. */
  seeing: boolean;
  /** Presses so far (a counter, so a lost or repeated message neither drops nor doubles a press). */
  calls: number;
  pickUps: number;
  /** Highest event sequence number received without a gap. */
  ackEvent: number;
  /** Host time of the newest snapshot received. */
  ackHt: number;
  /** Host time the client is drawing at. */
  renderTime: number;
  /** Placement sequence number the client has applied to its own body. */
  placeAck: number;
  /** Unacknowledged seen reports (newest last). */
  seen: SeenReport[];
}

export interface SnapPlayer {
  id: string;
  body: Body;
  yaw: number;
  pitch: number;
  /** Sending inputs and not caught or gone. */
  active: boolean;
  status: PlayerStatus;
  aboard: boolean;
  side: Side | null;
  connected: boolean;
  /** How they are moving, as the host allows it (so their figure can stride or run). */
  gait: Gait;
}

export interface TapeSnap {
  id: string;
  owner: string;
  readings: number;
  total: number;
}

export interface MemberSnap {
  id: string;
  needle: Needle;
  raised: boolean;
  /** Value of the open reading so far, 0 if none. */
  open: number;
  rate: number;
  tickHz: number;
  tape: TapeSnap;
  carrying: TapeSnap[];
}

export interface FloorTapeSnap extends TapeSnap {
  at: Body;
}

export interface BlinkSnap {
  /** Host time the blink starts. */
  at: number;
  /** Seconds it lasts (the blackout's ends when the car arrives, on this time). */
  len: number;
  /** Seconds of warning before `at`. */
  warn: number;
  /** The wait's last, long dark. */
  blackout: boolean;
  announced: boolean;
  endsAt: number | null;
}

/** The part of a snapshot that is the same for every client. */
export interface WorldSnap {
  tick: number;
  /** Host time of the state (RunState.t). */
  ht: number;
  phase: RunPhase;
  depth: number;
  timer: number;
  /** What the indicator shows (floors away), or null with no call. */
  floorsAway: number | null;
  bellLeft: number;
  holdLeft: number;
  held: boolean;
  blink: BlinkSnap | null;
  orderly: OrderlySnap;
  players: SnapPlayer[];
  crew: MemberSnap[];
  floor: FloorTapeSnap[];
  summary: RunSummary | null;
}

export interface Placement {
  seq: number;
  depth: number;
  body: Body;
}

export interface SnapshotMsg extends WorldSnap {
  type: 'snap';
  /** Host time at sending. */
  st: number;
  /** Highest input sequence number received from this client. */
  ackIn: number;
  /** That input's client time, and how long the host held it before this snapshot (for the clock). */
  echo: [number, number] | null;
  /** Highest seen-report id processed with no gap. */
  ackSeen: number;
  /** Sequence number of events[0]. */
  evFrom: number;
  events: RunEvent[];
  /** The host moved this client's player (ride, push-out, start, joining): until acknowledged. */
  place: Placement | null;
  /** This client's player's tank as the host has it after input `ackIn` (the truth), or null. */
  stamina?: Stamina | null;
}

export interface JoinMsg {
  type: 'join';
  name: string;
  ct: number;
}

export interface WelcomeMsg {
  type: 'welcome';
  you: string;
  seed: string;
  /** Whether you are in the run now; otherwise you watch until the next elevator stop. */
  playing: boolean;
  /** Your first event will carry this sequence number. */
  evFrom: number;
  /** The whole state a late joiner needs, as a snapshot body. */
  world: WorldSnap;
}

export interface LeaveMsg {
  type: 'leave';
}

export interface PingMsg {
  type: 'ping';
  ct: number;
}

export interface PongMsg {
  type: 'pong';
  ct: number;
  /** Host time at receipt and at reply. */
  hr: number;
  st: number;
}

export type Message = InputMsg | SnapshotMsg | JoinMsg | WelcomeMsg | LeaveMsg | PingMsg | PongMsg;

// ---------------------------------------------------------------------------------------------
// The compact wire form.

const PHASES: readonly RunPhase[] = ['arriving', 'unloading', 'away', 'coming', 'boarding', 'riding', 'ended'];
const ANIMS: readonly OrderlyAnim[] = ['idle', 'walk', 'duck', 'reach'];
const MODES: readonly OrderlyMode[] = ['waiting', 'hunting', 'windUp', 'dormant'];
const NEEDLES: readonly Needle[] = ['off', 'idle', 'dormant', 'recording', 'contaminated'];
const STATUSES: readonly PlayerStatus[] = ['ok', 'caught', 'leftBehind'];
const GAITS: readonly Gait[] = ['walk', 'creep', 'sprint'];

function idx<T>(list: readonly T[], v: T): number {
  const i = list.indexOf(v);
  if (i < 0) throw new RangeError(`not encodable: ${String(v)}`);
  return i;
}

function at<T>(list: readonly T[], i: unknown): T {
  const v = list[Number(i)];
  if (v === undefined) throw new RangeError(`bad code ${String(i)}`);
  return v;
}

type Wire = unknown[];

const encBody = (b: Body): Wire => [q2(b.x), q2(b.z), q2(b.y), b.level];
function decBody(w: unknown): Body {
  const a = w as number[];
  return { x: a[0] as number, z: a[1] as number, y: a[2] as number, level: (a[3] === 1 ? 1 : 0) as Level };
}

const encPose = (p: Pose): Wire => [p.x, p.z, p.y, p.level, p.yaw, idx(ANIMS, p.anim), p.animTime];
function decPose(w: unknown): Pose {
  const a = w as unknown[];
  return { x: a[0] as number, z: a[1] as number, y: a[2] as number, level: (a[3] === 1 ? 1 : 0) as Level, yaw: a[4] as number, anim: at(ANIMS, a[5]), animTime: a[6] as number };
}

const encTape = (t: TapeSnap): Wire => [t.id, t.owner, t.readings, q2(t.total)];
function decTape(w: unknown): TapeSnap {
  const a = w as unknown[];
  return { id: String(a[0]), owner: String(a[1]), readings: Number(a[2]), total: Number(a[3]) };
}

function encWorld(w: WorldSnap): Wire {
  const o = w.orderly;
  return [
    w.tick,
    w.ht,
    idx(PHASES, w.phase),
    w.depth,
    q2(w.timer),
    w.floorsAway,
    q2(w.bellLeft),
    q2(w.holdLeft),
    w.held ? 1 : 0,
    w.blink ? [w.blink.at, w.blink.announced ? 1 : 0, w.blink.endsAt, w.blink.len, w.blink.warn, w.blink.blackout ? 1 : 0] : 0,
    [...encPose(o), o.speed, o.frozen ? 1 : 0, idx(MODES, o.mode), ...(o.windUp ? [o.windUp.target, o.windUp.left] : [])],
    w.players.map((p) => [
      p.id,
      ...encBody(p.body),
      q3(p.yaw),
      q3(p.pitch),
      (p.active ? 1 : 0) | (p.aboard ? 2 : 0) | (p.connected ? 4 : 0) | (p.side === 'bank' ? 8 : p.side === 'down' ? 16 : 0) | (idx(STATUSES, p.status) << 5) | (idx(GAITS, p.gait) << 7),
    ]),
    w.crew.map((m) => [m.id, idx(NEEDLES, m.needle), m.raised ? 1 : 0, q2(m.open), q2(m.rate), q2(m.tickHz), encTape(m.tape), m.carrying.map(encTape)]),
    w.floor.map((f) => [...encTape(f), encBody(f.at)]),
    w.summary,
  ];
}

function decWorld(a: unknown[]): WorldSnap {
  const blink = a[9] as unknown[] | 0;
  const o = a[10] as unknown[];
  const pose = decPose(o);
  return {
    tick: Number(a[0]),
    ht: Number(a[1]),
    phase: at(PHASES, a[2]),
    depth: Number(a[3]),
    timer: Number(a[4]),
    floorsAway: a[5] === null ? null : Number(a[5]),
    bellLeft: Number(a[6]),
    holdLeft: Number(a[7]),
    held: a[8] === 1,
    blink: blink
      ? { at: Number(blink[0]), announced: blink[1] === 1, endsAt: blink[2] === null ? null : Number(blink[2]), len: Number(blink[3]), warn: Number(blink[4]), blackout: blink[5] === 1 }
      : null,
    orderly: { ...pose, speed: Number(o[7]), frozen: o[8] === 1, mode: at(MODES, o[9]), ...(o.length > 11 ? { windUp: { target: String(o[10]), left: Number(o[11]) } } : {}) },
    players: (a[11] as unknown[][]).map((p) => {
      const f = Number(p[7]);
      return {
        id: String(p[0]),
        body: decBody(p.slice(1, 5)),
        yaw: Number(p[5]),
        pitch: Number(p[6]),
        active: (f & 1) !== 0,
        aboard: (f & 2) !== 0,
        connected: (f & 4) !== 0,
        side: f & 8 ? 'bank' : f & 16 ? 'down' : null,
        status: at(STATUSES, (f >> 5) & 3),
        gait: at(GAITS, (f >> 7) & 3),
      };
    }),
    crew: (a[12] as unknown[][]).map((m) => ({
      id: String(m[0]),
      needle: at(NEEDLES, m[1]),
      raised: m[2] === 1,
      open: Number(m[3]),
      rate: Number(m[4]),
      tickHz: Number(m[5]),
      tape: decTape(m[6]),
      carrying: (m[7] as unknown[]).map(decTape),
    })),
    floor: (a[13] as unknown[][]).map((f) => ({ ...decTape(f), at: decBody(f[4]) })),
    summary: (a[14] as RunSummary | null) ?? null,
  };
}

const encReport = (r: SeenReport): Wire => [r.id, r.depth, r.a, r.b, q3(r.alpha), encPose(r.pose)];
function decReport(w: unknown): SeenReport {
  const a = w as unknown[];
  return { id: Number(a[0]), depth: Number(a[1]), a: Number(a[2]), b: Number(a[3]), alpha: Number(a[4]), pose: decPose(a[5]) };
}

/** The JSON text of a world snapshot (computed once per tick and shared by every client's snapshot). */
export function worldJson(w: WorldSnap): string {
  return JSON.stringify(encWorld(w));
}

/**
 * A snapshot's wire text. `world` is worldJson() of the shared part, so the host encodes the world
 * once per tick and only the per-client head per client.
 */
export function snapshotText(m: Omit<SnapshotMsg, keyof WorldSnap | 'type'>, world: string): string {
  const head = [
    m.st,
    m.ackIn,
    m.echo ?? 0,
    m.ackSeen,
    m.evFrom,
    m.events,
    m.place ? [m.place.seq, m.place.depth, encBody(m.place.body)] : 0,
    m.stamina ? [q3(m.stamina.level), m.stamina.winded ? 1 : 0] : 0,
  ];
  return `[${PROTOCOL_VERSION},"S",${JSON.stringify(head)},${world}]`;
}

/** Serialises any message to its wire text. */
export function encode(m: Message): string {
  switch (m.type) {
    case 'snap':
      return snapshotText(m, worldJson(m));
    case 'input':
      return JSON.stringify([
        PROTOCOL_VERSION,
        'I',
        m.seq,
        Math.floor(m.ct * 1000) / 1000, // rounded down: the clock's error bound stays a bound
        encBody(m.body),
        q2(m.eye),
        q3(m.yaw),
        q3(m.pitch),
        q2(m.hFovDeg),
        q2(m.vFovDeg),
        (m.raised ? 1 : 0) | (m.holdDoors ? 2 : 0) | (m.seeing ? 4 : 0) | (idx(GAITS, m.gait ?? 'walk') << 3),
        m.calls,
        m.pickUps,
        m.ackEvent,
        m.ackHt,
        Math.floor(m.renderTime * 1000) / 1000, // never claim a later moment than was drawn
        m.placeAck,
        m.seen.map(encReport),
      ]);
    case 'join':
      return JSON.stringify([PROTOCOL_VERSION, 'J', m.name, m.ct]);
    case 'welcome':
      return JSON.stringify([PROTOCOL_VERSION, 'W', m.you, m.seed, m.playing ? 1 : 0, m.evFrom, encWorld(m.world)]);
    case 'leave':
      return JSON.stringify([PROTOCOL_VERSION, 'L']);
    case 'ping':
      return JSON.stringify([PROTOCOL_VERSION, 'P', m.ct]);
    case 'pong':
      return JSON.stringify([PROTOCOL_VERSION, 'O', m.ct, m.hr, m.st]);
  }
}

/** Parses wire text; null for anything malformed or from another protocol version. */
export function decode(text: string): Message | null {
  let a: unknown;
  try {
    a = JSON.parse(text);
  } catch {
    return null;
  }
  if (!Array.isArray(a) || a[0] !== PROTOCOL_VERSION) return null;
  try {
    switch (a[1]) {
      case 'S': {
        const h = a[2] as unknown[];
        const echo = h[2] as number[] | 0;
        const place = h[6] as unknown[] | 0;
        const st = h[7] as unknown[] | 0 | undefined;
        return {
          type: 'snap',
          ...decWorld(a[3] as unknown[]),
          st: Number(h[0]),
          ackIn: Number(h[1]),
          echo: echo ? [Number(echo[0]), Number(echo[1])] : null,
          ackSeen: Number(h[3]),
          evFrom: Number(h[4]),
          events: h[5] as RunEvent[],
          place: place ? { seq: Number(place[0]), depth: Number(place[1]), body: decBody(place[2]) } : null,
          stamina: st ? { level: Math.max(0, Math.min(1, Number(st[0]))), winded: st[1] === 1 } : null,
        };
      }
      case 'I': {
        const f = Number(a[10]);
        return {
          type: 'input',
          seq: Number(a[2]),
          ct: Number(a[3]),
          body: decBody(a[4]),
          eye: Number(a[5]),
          yaw: Number(a[6]),
          pitch: Number(a[7]),
          hFovDeg: Number(a[8]),
          vFovDeg: Number(a[9]),
          raised: (f & 1) !== 0,
          holdDoors: (f & 2) !== 0,
          seeing: (f & 4) !== 0,
          gait: at(GAITS, (f >> 3) & 3),
          calls: Number(a[11]),
          pickUps: Number(a[12]),
          ackEvent: Number(a[13]),
          ackHt: Number(a[14]),
          renderTime: Number(a[15]),
          placeAck: Number(a[16]),
          seen: (a[17] as unknown[]).map(decReport),
        };
      }
      case 'J':
        return { type: 'join', name: String(a[2]), ct: Number(a[3]) };
      case 'W':
        return { type: 'welcome', you: String(a[2]), seed: String(a[3]), playing: a[4] === 1, evFrom: Number(a[5]), world: decWorld(a[6] as unknown[]) };
      case 'L':
        return { type: 'leave' };
      case 'P':
        return { type: 'ping', ct: Number(a[2]) };
      case 'O':
        return { type: 'pong', ct: Number(a[2]), hr: Number(a[3]), st: Number(a[4]) };
      default:
        return null;
    }
  } catch {
    return null;
  }
}

/** Approximate size of a message on the wire, in bytes (its UTF-8 text; ids and names are ASCII). */
export function messageBytes(m: Message | string): number {
  const text = typeof m === 'string' ? m : encode(m);
  let n = 0;
  for (let i = 0; i < text.length; i++) {
    const c = text.charCodeAt(i);
    n += c < 0x80 ? 1 : c < 0x800 ? 2 : 3;
  }
  return n;
}
