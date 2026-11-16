// Test 7: a whole run with two players over a 120 ms link. The host's own player (A) and a remote
// player (B, 120 ms each way) each act only on what THEIR machine shows: the drawn Orderly, the
// phase in their newest snapshot, their own events. Both earn on floor 1, A calls, both board on the
// DOWN side and ride; on floor 2 both earn again, A calls, both board on the BANK side and bank.
// Each wait ends in a blackout: both run from it when it is announced and come back when the doors open.

import { describe, expect, it } from 'vitest';
import { BOT_EYE, BOT_HFOV_DEG, BOT_VFOV_DEG, fleeGoal } from '../../src/sim/bot';
import { HUNT_SPEED, yawToward } from '../../src/sim/entity';
import { findPath } from '../../src/sim/floor';
import { bodyAtCell, cellOf, type Body } from '../../src/sim/move';
import { carBody } from '../../src/sim/run';
import { freshStamina, gaitFor, speedFor, stepStamina, type Gait, type Stamina } from '../../src/sim/stamina';
import type { LocalFrame } from '../../src/net/client';
import { carFor, moveLocal, planFor } from '../../src/net/session';
import { Session, type Machine } from './harness';

type Stage = 'waitOpen' | 'out' | 'away' | 'watch' | 'call' | 'wait' | 'flee' | 'return' | 'board' | 'done';

interface Actor {
  m: Machine;
  caller: boolean;
  u: number;
  stage: Stage;
  depth: number;
  waypoints: Body[];
  yaw: number;
  pitch: number;
  raised: boolean;
  watchUntil: number;
  floorEventsFrom: number;
  lastCall: number;
  t: number;
  stamina: Stamina;
  gait: Gait;
  /** When to choose where to run again (flee). */
  rethink: number;
  /** Farthest from the car door in a blackout (m). */
  farthest: number;
}

const near = (a: Body, b: { x: number; z: number }): number => Math.hypot(a.x - b.x, a.z - b.z);

/** Waypoints through the centres of a path's cells. */
function cellRoute(plan: ReturnType<typeof planFor>, from: Body, to: { level: 0 | 1; x: number; y: number }): Body[] {
  const path = findPath(plan, cellOf(plan, from), to);
  return path ? path.slice(1).map((p) => bodyAtCell(plan, p)) : [];
}

/** Into the car through the doorway: DOWN on the first floor, BANK on the second. */
function intoCar(a: Actor, car: ReturnType<typeof carFor>): Body[] {
  const v = a.depth === 1 ? 0.5 : -0.5;
  return [carBody(car, -0.6, 0), carBody(car, 0.45, 0), carBody(car, a.caller ? 0.8 : 1.3, v)];
}

/** A dark stretch is announced that would let the Orderly (as drawn) reach this player: always the blackout. */
function threatened(b: { announced: boolean; endsAt: number | null; blackout: boolean; len: number } | null | undefined, body: Body, o: { x: number; z: number } | null): boolean {
  if (!b || !b.announced || b.endsAt !== null) return false;
  return b.blackout || (o !== null && near(body, o) < HUNT_SPEED * b.len + 6);
}

function walk(a: Actor, body: Body, speed: number, dt: number): Body {
  const c = a.m.client;
  const phase = c.latest?.phase ?? 'arriving';
  const plan = planFor(c.seed as string, c.localDepth);
  let budget = speed * dt;
  let cur = body;
  while (budget > 1e-9 && a.waypoints.length > 0) {
    const w = a.waypoints[0] as Body;
    const d = near(cur, w);
    if (d < 0.02) {
      a.waypoints.shift();
      continue;
    }
    const step = Math.min(budget, d);
    const before = cur;
    cur = moveLocal(plan, phase, cur, ((w.x - cur.x) / d) * step, ((w.z - cur.z) / d) * step);
    budget -= step;
    if (near(cur, before) < 1e-6) break;
  }
  return cur;
}

function look(a: Actor, body: Body, at: { x: number; y: number; z: number }, away: boolean): void {
  const dx = at.x - body.x;
  const dz = at.z - body.z;
  if (away) {
    a.yaw = yawToward(-dx, -dz);
    a.pitch = 0;
  } else {
    a.yaw = yawToward(dx, dz);
    a.pitch = Math.atan2(at.y + 1.7 - (body.y + BOT_EYE), Math.max(0.1, Math.hypot(dx, dz)));
  }
}

function readingsBy(a: Actor, id: string): number {
  return a.m.client.events.slice(a.floorEventsFrom).filter((e) => e.type === 'readingClosed' && e.playerId === id).length;
}

function step(a: Actor, partner: () => Actor, dt: number): LocalFrame {
  a.t += dt;
  const c = a.m.client;
  const w = c.latest;
  // Until the host's first placement arrives, stand in the car.
  let body: Body = a.m.body ?? (c.seed ? carBody(carFor(planFor(c.seed, c.localDepth)), 1, 0) : { x: 0, y: 0, z: 0, level: 0 });
  const o = a.m.last?.orderly ?? null;
  let call = false;
  let hold = false;
  if (w && c.seed) {
    const car = carFor(planFor(c.seed, c.localDepth));
    switch (a.stage) {
      case 'waitOpen':
        if (w.phase === 'unloading' && w.depth === a.depth) {
          a.waypoints = [carBody(car, 0.45, 0), carBody(car, -0.6, 0), carBody(car, -1.0, a.caller ? -0.45 : 0.45)];
          a.floorEventsFrom = c.events.length;
          a.stage = 'out';
        }
        break;
      case 'out':
        body = walk(a, body, 2.5, dt);
        if (a.waypoints.length === 0 && w.phase === 'away') a.stage = 'away';
        break;
      case 'away':
        // Backs turned, instruments up, until it is close; then turn and watch it.
        a.raised = true;
        if (o) {
          look(a, body, o, true);
          if (near(body, o) < 3.5) {
            a.stage = 'watch';
            a.watchUntil = a.t + 3;
          }
        }
        break;
      case 'watch':
        if (o) look(a, body, o, false);
        if (a.t >= a.watchUntil) {
          const both = readingsBy(a, c.id as string) > 0 && readingsBy(a, partner().m.id) > 0;
          a.stage = both ? (a.caller ? 'call' : 'wait') : 'away';
        }
        break;
      case 'call':
        if (o) look(a, body, o, false);
        if (w.phase === 'away' && a.t - a.lastCall > 1) {
          call = true;
          a.lastCall = a.t;
        }
        if (w.phase === 'coming') a.stage = 'wait';
        break;
      case 'wait':
        // Keep it in sight and at a distance while the lights are on. When a dark stretch is announced
        // that would let it reach them, and always for the blackout, run (sim/bot.ts fleeGoal, from what
        // this screen shows and hears); come back when the lights do, and board when the doors open.
        a.raised = false;
        if (o) {
          const d = near(body, o);
          if (d < 5 && d > 1e-6) {
            a.waypoints = [{ ...body, x: body.x + ((body.x - o.x) / d) * 2, z: body.z + ((body.z - o.z) / d) * 2 }];
            body = walk(a, body, 2.5, dt);
            a.waypoints = [];
          }
          look(a, body, o, false);
        }
        if (threatened(w.blink, body, o)) {
          a.stage = 'flee';
          a.rethink = 0;
          a.waypoints = [];
        }
        if (w.phase === 'boarding') a.stage = 'board';
        if (a.stage === 'board') a.waypoints = intoCar(a, car);
        break;
      case 'flee': {
        const plan = planFor(c.seed, c.localDepth);
        const dark = a.m.last?.dark === true;
        if (!dark && !w.blink?.announced) {
          a.stage = 'return';
          a.waypoints = cellRoute(plan, body, plan.landing);
          break;
        }
        a.rethink -= dt;
        if (a.waypoints.length === 0 || a.rethink <= 0) {
          const goal = fleeGoal(plan, body, o ? { ...o } : null, !dark);
          if (goal) a.waypoints = cellRoute(plan, body, goal);
          a.rethink = 1.5;
        }
        a.gait = gaitFor(a.stamina, { sprint: dark && o !== null && near(body, o) < 14, creep: false, moving: true, cap: Infinity });
        const before = body;
        body = walk(a, body, speedFor(a.gait), dt);
        a.stamina = stepStamina(a.stamina, a.gait, near(body, before) / dt, dt);
        if (o && !dark) look(a, body, o, false);
        else if (near(body, before) > 1e-6) look(a, body, { x: 2 * body.x - before.x, y: body.y, z: 2 * body.z - before.z }, true);
        if (dark && w.blink?.blackout) a.farthest = Math.max(a.farthest, Math.hypot(body.x - car.doorX, body.z - car.doorZ));
        break;
      }
      case 'return': {
        // Back to the landing, watching it all the way (hurrying while far), then into the car if it is there.
        if (threatened(w.blink, body, o)) {
          a.stage = 'flee';
          a.rethink = 0;
          a.waypoints = [];
          break;
        }
        const before = body;
        a.gait = gaitFor(a.stamina, { sprint: a.waypoints.length > 6, creep: false, moving: true, cap: Infinity });
        body = walk(a, body, speedFor(a.gait), dt);
        a.stamina = stepStamina(a.stamina, a.gait, near(body, before) / dt, dt);
        if (o) look(a, body, o, false);
        if (a.waypoints.length === 0) {
          a.stage = w.phase === 'boarding' ? 'board' : 'wait';
          if (a.stage === 'board') a.waypoints = intoCar(a, car);
        }
        break;
      }
      case 'board':
        body = walk(a, body, 2.0, dt);
        if (o) look(a, body, o, false);
        // Aboard, hold the doors while the other is still coming.
        hold = a.waypoints.length === 0 && (partner().stage !== 'board' || partner().waypoints.length > 0) && partner().stage !== 'done';
        if (w.phase === 'riding' || w.phase === 'ended') {
          a.stage = 'done';
        }
        break;
      case 'done':
        if (w.phase === 'arriving' && w.depth === a.depth + 1) {
          a.depth++;
          a.stage = 'waitOpen';
        }
        break;
    }
  }
  a.m.body = body;
  return { body, eye: BOT_EYE, yaw: a.yaw, pitch: a.pitch, hFovDeg: BOT_HFOV_DEG, vFovDeg: BOT_VFOV_DEG, raised: a.raised, call, holdDoors: hold, gait: a.gait, stamina: a.stamina };
}

describe('a whole run, two players, 120 ms apart', () => {
  it('both earn, one calls, both board, they vote DOWN then BANK, and both end with the same banked total and share', () => {
    const s = new Session({ seed: 'netrun-1', remotes: 1, net: { delayMin: 0.12, delayMax: 0.12, jitter: 0.01, loss: 0.02, reorder: 0, reorderDelay: 0, duplicate: 0 }, setup: 'run' });
    const [ma, mb] = s.machines as [Machine, Machine];
    const mk = (m: Machine, caller: boolean): Actor => ({ m, caller, u: 0, stage: 'waitOpen', depth: 1, waypoints: [], yaw: 0, pitch: 0, raised: false, watchUntil: 0, floorEventsFrom: 0, lastCall: -9, t: 0, stamina: freshStamina(), gait: 'walk', rethink: 0, farthest: 0 });
    const A = mk(ma, true);
    const B = mk(mb, false);
    ma.script = (_m, _s, dt) => step(A, () => B, dt);
    mb.script = (_m, _s, dt) => step(B, () => A, dt);
    for (let t = 0; t < 600 && s.host.state.phase !== 'ended'; t += 5) s.run(t + 5);
    s.run(s.g + 2);

    const h = s.host;
    const types = h.log.map((l) => l.e.type);
    const bells = h.log.map((l) => l.e).filter((e) => e.type === 'bell');
    const sum = h.state.summary;
    console.log(
      `run over 120 ms: ended at t=${h.state.t.toFixed(0)} s, depth ${h.state.depth}, bells ${JSON.stringify(bells.map((b) => (b.type === 'bell' ? [b.down, b.bank, b.outcome] : null)))}, ` +
        `banked ${sum?.total.toFixed(1)}, shares ${JSON.stringify(sum?.shares)}; put-backs ${h.stats.putBacks}, readings ${types.filter((x) => x === 'readingClosed').length}; ` +
        `blackouts ${h.log.filter((l) => l.e.type === 'blinkStart' && l.e.blackout).length}, fled ${A.farthest.toFixed(1)} m and ${B.farthest.toFixed(1)} m from the car`,
    );
    // Both waits ended in a blackout; both players ran from it and came back.
    expect(h.log.filter((l) => l.e.type === 'blinkStart' && l.e.blackout).length).toBe(2);
    expect(Math.min(A.farthest, B.farthest)).toBeGreaterThan(8);
    expect(types).not.toContain('caught');
    expect(sum).not.toBeNull();
    expect(sum?.wiped).toBe(false);
    expect(sum?.depth).toBe(2);
    expect(sum?.total ?? 0).toBeGreaterThan(0);
    expect(bells.map((b) => (b.type === 'bell' ? [b.down, b.bank, b.outcome] : null))).toEqual([
      [2, 0, 'ride'],
      [0, 2, 'bank'],
    ]);
    // Both earned on both floors.
    for (const id of ['p0', 'p1']) {
      const depthOf = (t: number): number => (h.log.find((l) => l.e.type === 'rodeDown' && l.e.t <= t) ? 2 : 1);
      const floors = new Set(h.log.filter((l) => l.e.type === 'readingClosed' && l.e.playerId === id).map((l) => depthOf(l.e.t)));
      expect([...floors].sort()).toEqual([1, 2]);
    }
    expect(types.filter((x) => x === 'called').length).toBe(2);
    expect(h.log.filter((l) => l.e.type === 'called').every((l) => l.e.type === 'called' && l.e.playerId === 'p0')).toBe(true);
    // Both machines end with the host's total and the same share each.
    for (const m of s.machines) {
      const ws = m.client.latest?.summary;
      expect(ws?.total).toBeCloseTo(sum?.total ?? -1, 9);
      expect(ws?.shares).toEqual(sum?.shares);
      const banked = m.client.events.find((e) => e.type === 'banked');
      expect(banked && banked.type === 'banked' ? banked.summary : null).toEqual(sum);
      expect(m.client.events.map((e) => JSON.stringify(e))).toEqual(h.log.slice(0, m.client.events.length).map((l) => JSON.stringify(l.e)));
    }
    expect(sum?.shares.p0).toBeCloseTo((sum?.total ?? 0) / 2, 9);
    expect(sum?.shares.p1).toBeCloseTo((sum?.total ?? 0) / 2, 9);
  }, 120_000);
});
