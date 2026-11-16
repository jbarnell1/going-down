// The scripted sequence the bridge reference is made from (dump_reference.ts job 'bridge'). It plays
// the game through the reference host (rules_host.ts, the real TypeScript rules) the way the client
// does: one 'frame' request per rendered frame, plus the test hooks. Choices are made from the
// replies (where to walk, where to look), but only the REQUESTS are replayed on the Godot side
// (tests/ref_bridge.gd), so the script itself is never ported: Godot must answer the same requests
// with the same replies.
//
// Covered: stepping out (walk, sprint, creep, strafe), both levels and the stair, approaching the
// Orderly, watching it (held) and looking away (it moves: the slip), raising and lowering the
// instrument (a reading closes), back to the lift unwatched, calling it, blinks and the blackout while
// facing the Orderly, being caught while the car is coming (the soft catch: `placed` with a yaw), a
// dropped tape picked up, boarding, holding the doors, the vote and banking; a second run with the
// Orderly parked that calls the lift, rides DOWN to floor 2 and uses the test hooks there; a third
// run started at depth 2.

import { generateClinic } from '../../src/sim/clinic';
import { distancesFrom, findPath, posFromIndex, type Pos } from '../../src/sim/floor';
import { RulesHost } from './rules_host';

/* eslint-disable @typescript-eslint/no-explicit-any */
type Reply = any;
type Req = Record<string, unknown>;

export interface BridgeScene {
  name: string;
  requests: Req[];
  replies: Reply[];
}

/** The client's horizontal field of view for a 70 degree vertical one at 16:9 (main.gd). */
const HFOV = (2 * Math.atan(Math.tan((70 * Math.PI) / 180 / 2) * (480 / 270)) * 180) / Math.PI;
/** Frame times the script cycles through: 60, 30, 45 and 144 Hz, a long stall (clamped to 0.1), none. */
const DTS = [1 / 60, 1 / 30, 1 / 45, 1 / 30, 1 / 144, 1 / 30, 1 / 60, 0.13, 1 / 30, 0];

class Driver {
  private host = new RulesHost();
  readonly requests: Req[] = [];
  readonly replies: Reply[] = [];
  s: Reply = null;
  plan: Reply = null;
  yaw = 0;
  pitch = 0;
  private n = 0;
  readonly seen = new Map<string, number>();
  softCatches = 0;

  send(req: Req): Reply {
    this.requests.push(req);
    const r = JSON.parse(this.host.handle(JSON.stringify(req)));
    this.replies.push(r);
    if (r.error) throw new Error(`host error on ${JSON.stringify(req)}: ${r.error}`);
    if (r.plan) this.plan = r.plan;
    if (req.op === 'frame' || req.op === 'start') {
      this.s = r;
      for (const e of r.events ?? []) this.seen.set(e.type, (this.seen.get(e.type) ?? 0) + 1);
      if (r.placed && r.placed.yaw !== undefined) {
        this.yaw = r.placed.yaw;
        if (req.op === 'frame') this.softCatches++;
      }
      if (r.autoYaw !== null && r.autoYaw !== undefined) this.yaw = r.autoYaw;
    }
    return r;
  }

  start(seed: string, depth: number, entity: boolean): Reply {
    return this.send({ op: 'start', seed, depth, entity });
  }

  frame(over: Req = {}): Reply {
    const dt = DTS[this.n++ % DTS.length] as number;
    return this.send({
      op: 'frame', dt, f: 0, r: 0, sprint: false, creep: false, yaw: this.yaw, pitch: this.pitch, hfov: HFOV, vfov: 70,
      raised: false, call: false, hold: false, pickUp: false, still: false, timeScale: 1, ...over,
    });
  }

  /** Frames until `done` holds (checked before each frame) or `max` frames. Returns whether it held. */
  until(done: (s: Reply) => boolean, max: number, input: (s: Reply) => Req = () => ({})): boolean {
    for (let i = 0; i < max; i++) {
      if (done(this.s)) return true;
      this.frame(input(this.s));
    }
    return done(this.s);
  }

  frames(k: number, input: (s: Reply) => Req = () => ({})): void {
    for (let i = 0; i < k; i++) this.frame(input(this.s));
  }

  /** The rules' own path walk (test hook), frames until it ends. */
  walkTo(p: Pos, pace: number, max = 4000, input: (s: Reply) => Req = () => ({})): string {
    const r = this.send({ op: 'walkTo', level: p.level, x: p.x, y: p.y, pace });
    if (!r.ok) return 'no path';
    this.frame(input(this.s));
    this.until((s) => s.auto !== 'walking', max, input);
    return this.s.auto;
  }

  face(x: number, z: number): void {
    const me = this.s.me;
    this.yaw = Math.atan2(-(x - me.x), -(z - me.z));
  }

  faceOrderly(): void {
    this.face(this.s.orderly.x, this.s.orderly.z);
  }

  /** A point in the car, car-local (u into the car, v to the right). */
  carPoint(u: number, v: number): [number, number] {
    const c = this.plan.car;
    return [c.doorX + c.inX * u + c.rightX * v, c.doorZ + c.inZ * u + c.rightZ * v];
  }

  /** Walks (forward key) toward a point on this level, turning toward it every frame. */
  steerTo(x: number, z: number, max: number, extra: Req = {}): boolean {
    return this.until(
      (s) => Math.hypot(s.me.x - x, s.me.z - z) < 0.12,
      max,
      () => {
        this.face(x, z);
        return { f: 1, ...extra };
      },
    );
  }

  need(types: string[]): void {
    const missing = types.filter((t) => !this.seen.has(t));
    if (missing.length > 0) throw new Error(`bridge script did not reach: ${missing.join(', ')} (seen ${JSON.stringify([...this.seen])})`);
  }
}

const landingPos = (plan: Reply): Pos => ({ level: plan.landing.level, x: plan.landing.x, y: plan.landing.y });

/** Run A: the whole first floor on seed alpha, banking at the end. */
function runA(): BridgeScene {
  const d = new Driver();
  d.start('alpha', 1, true);
  const fp = generateClinic('alpha', 1);
  const landing = landingPos(d.plan);
  d.yaw = d.s.placed.yaw;
  // In the car while the doors open.
  d.until((s) => s.doorsOpen, 400);
  // Step out: walk, sprint, creep, strafe, a look up and down.
  d.frames(40, () => ({ f: 1 }));
  d.frames(30, () => ({ f: 1, sprint: true }));
  d.frames(20, () => ({ f: 1, creep: true }));
  d.frames(15, () => ({ r: 1 }));
  d.frames(15, () => ({ f: -0.5, r: -0.7 }));
  d.pitch = 0.4;
  d.frames(5);
  d.pitch = 0;
  // Up the stair to level 1 and back down (the rules' path, with collision).
  const dist = distancesFrom(fp, fp.landing);
  const cellsPerLevel = fp.width * fp.height;
  let min1 = Infinity;
  for (let i = cellsPerLevel; i < dist.length; i++) if ((dist[i] as number) > 0) min1 = Math.min(min1, dist[i] as number);
  let up: Pos | null = null;
  for (let i = cellsPerLevel; i < dist.length; i++) if (dist[i] === min1 + 4) { up = posFromIndex(fp, i); break; }
  if (!up) throw new Error('no level-1 cell to walk to');
  d.walkTo(up, 6);
  if (d.s.me.level !== 1) throw new Error(`did not reach level 1 (${d.s.auto})`);
  d.frames(20, () => ({ f: 1 }));
  d.walkTo(landing, 6);
  // Toward the Orderly: four cells short of where it waits, on the path from the landing.
  const path = findPath(fp, fp.landing, fp.entityStart);
  if (!path) throw new Error('no path to the Orderly');
  const near = path[Math.max(0, path.length - 5)] as Pos;
  d.walkTo(near, 4);
  // Watch it with the instrument up: recording, it is held.
  d.faceOrderly();
  d.frames(90, () => { d.faceOrderly(); return { raised: true }; });
  // Look away with the instrument still up: it moves while recorded (the slip), the squeak.
  d.yaw += Math.PI;
  d.until((s) => s.orderly.distance < 3.5, 60, () => ({ raised: true }));
  // Look back (it freezes), lower: the reading closes.
  d.frames(30, () => { d.faceOrderly(); return { raised: true }; });
  d.frames(70, () => { d.faceOrderly(); return {}; });
  // Back to the lift, not watching it.
  d.walkTo(landing, 6);
  // Call the lift (the client asks only when canCall), then face the Orderly through the wait.
  d.until((s) => s.phase === 'away', 600, () => { d.faceOrderly(); return {}; });
  d.frame({ call: true });
  if (d.s.calls < 1) d.until((s) => s.calls >= 1, 10, () => ({ call: true }));
  let picked = false;
  d.until(
    (s) => s.phase === 'boarding' || s.phase === 'ended',
    6000,
    (s) => {
      d.faceOrderly();
      // Once caught (put back at the landing), fetch the dropped tape if it is on this level.
      if (!picked && d.softCatches > 0 && s.floorTapes.length > 0 && s.auto !== 'walking') {
        picked = true;
        const at = s.floorTapes[0].at;
        const r = d.send({ op: 'walkTo', level: at.level, x: Math.floor(at.x / 2), y: Math.floor(at.z / 2), pace: 6 });
        if (!r.ok) return {};
      }
      if (picked && s.auto === 'done' && s.floorTapes.length > 0) return { pickUp: true };
      return {};
    },
  );
  if (d.s.phase !== 'boarding') throw new Error(`run A: never boarding (${d.s.phase})`);
  // Board: to the doorway, in, onto the BANK half; hold the doors a moment.
  d.send({ op: 'stopWalk' });
  const [ox, oz] = d.carPoint(-0.7, 0);
  d.steerTo(ox, oz, 600);
  const [bx, bz] = d.carPoint(1.0, -0.5);
  d.steerTo(bx, bz, 300);
  d.frames(20, () => ({ hold: true }));
  d.until((s) => s.phase === 'ended', 2000, () => ({}));
  d.frames(10, () => ({ still: true }));
  d.need(['firstSeen', 'startedHunting', 'froze', 'released', 'readingClosed', 'slip', 'called', 'indicator', 'blinkSoon', 'blinkStart',
    'blinkEnd', 'caught', 'tapeDropped', 'carArrived', 'doorsOpened', 'voteChanged', 'bell', 'banked', 'doorsClosed', 'carLeft']);
  if (d.softCatches === 0) throw new Error('run A: never caught while the car was coming');
  return { name: 'alpha-bank', requests: d.requests, replies: d.replies };
}

/** Run B: the Orderly parked; call, ride DOWN to floor 2, then the test hooks there. */
function runB(): BridgeScene {
  const d = new Driver();
  d.start('alpha', 1, false);
  const landing = landingPos(d.plan);
  d.yaw = d.s.placed.yaw;
  d.until((s) => s.doorsOpen, 400);
  d.frames(45, () => ({ f: 1 }));
  d.until((s) => s.phase === 'away', 800, () => ({ timeScale: 3 }));
  d.walkTo(landing, 3);
  d.frame({ call: true });
  d.until((s) => s.phase === 'boarding', 4000, () => ({ timeScale: 3 }));
  const [ox, oz] = d.carPoint(-0.7, 0);
  d.steerTo(ox, oz, 600);
  const [dx, dz] = d.carPoint(1.0, 0.5);
  d.steerTo(dx, dz, 300);
  d.until((s) => s.depth === 2, 3000, () => ({}));
  if (d.s.depth !== 2) throw new Error(`run B: did not ride down (${d.s.phase})`);
  d.until((s) => s.doorsOpen, 400);
  d.frames(40, () => ({ f: 1 }));
  d.send({ op: 'debug' });
  const fp2 = generateClinic('alpha', 2);
  d.send({ op: 'teleport', level: fp2.landing.level, x: fp2.landing.x, y: fp2.landing.y });
  d.frames(3);
  d.send({ op: 'nudge', dx: 0.7, dz: -0.4 });
  d.send({ op: 'nudge', dx: 40, dz: 0 });
  d.frames(3);
  const path = findPath(fp2, fp2.landing, fp2.entityStart) as Pos[];
  d.walkTo(path[Math.min(path.length - 1, 8)] as Pos, 5);
  d.send({ op: 'walkTo', level: 0, x: -5, y: -5 });
  d.walkTo(path[Math.min(path.length - 1, 14)] as Pos, 3, 30);
  d.send({ op: 'stopWalk' });
  d.frames(30, () => ({ f: 1, r: 0.3 }));
  d.send({ op: 'debug' });
  d.need(['rodeDown', 'called', 'bell', 'voteChanged', 'carArrived']);
  return { name: 'alpha-ride', requests: d.requests, replies: d.replies };
}

/** Run C: started on floor 2 (HostRules.prepare's depth override). */
function runC(): BridgeScene {
  const d = new Driver();
  d.start('beta', 2, true);
  d.yaw = d.s.placed.yaw;
  d.until((s) => s.doorsOpen, 400);
  d.frames(60, () => ({ f: 1 }));
  d.frames(60, () => { d.faceOrderly(); return { raised: true }; });
  d.send({ op: 'debug' });
  return { name: 'beta-depth2', requests: d.requests, replies: d.replies };
}

export function bridgeScenes(): BridgeScene[] {
  return [runA(), runB(), runC()];
}
