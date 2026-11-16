// The network layer as the browser game drives it (src/net/crew.ts, src/main.ts): the host's own
// player is trusted with its body, a glance reported between two ticks is applied on that frame,
// the game's test hooks replace the Orderly without a later report undoing it, a put-back reports
// the freeze it makes, and a client's clock estimate follows a host clock that jumped.

import { describe, expect, it } from 'vitest';
import { carBody, type RunPlayer, type RunState } from '../../src/sim/run';
import { NetHost } from '../../src/net/host';
import { decode, encode, lerpPose, type InputMsg, type SeenReport, type SnapshotMsg } from '../../src/net/protocol';
import { HostClock, TICK } from '../../src/net/session';
import { MemoryNetwork, type MemoryTransport } from '../../src/net/transport';

function blindLanding(s: RunState): RunState {
  const players = s.players.map((p, i): RunPlayer => ({ ...p, body: carBody(s.car, -0.7, i % 2 ? 0.45 : -0.45), aboard: false }));
  return { ...s, phase: 'away', players, orderly: { ...s.orderly, mode: 'hunting' } };
}

class Rig {
  readonly net = new MemoryNetwork('game');
  readonly host: NetHost;
  readonly me: MemoryTransport;
  now = 0;
  seq = 0;
  ct = 0;
  readonly snaps = new Map<number, SnapshotMsg>();
  latest: SnapshotMsg | null = null;
  placeAck = 0;
  body = { x: 0, y: 0, z: 0, level: 0 as 0 | 1 };

  constructor(seed: string, trusted: string[] = []) {
    const ht = this.net.connect('host');
    this.me = this.net.connect('p0');
    this.host = new NetHost({ transport: ht, seed, roster: ['p0'], now: 0, prepare: blindLanding, trusted });
    this.body = { ...(this.host.state.players[0] as RunPlayer).body };
    this.me.send('host', encode({ type: 'join', name: 'p0', ct: 0 }));
    this.tick();
  }

  input(over: Partial<InputMsg> = {}): void {
    this.ct += TICK;
    const m: InputMsg = {
      type: 'input', seq: ++this.seq, ct: this.ct, body: this.body, eye: 1.65, yaw: 0, pitch: Math.PI / 2, hFovDeg: 0.01, vFovDeg: 0.01,
      raised: false, holdDoors: false, seeing: false, calls: 0, pickUps: 0, ackEvent: 0,
      ackHt: this.latest?.ht ?? -1, renderTime: this.latest?.ht ?? -1, placeAck: this.placeAck, seen: [], ...over,
    };
    this.me.send('host', encode(m));
  }

  receive(): void {
    for (const d of this.me.receive()) {
      const m = decode(d.data);
      if (m?.type !== 'snap') continue;
      this.snaps.set(m.tick, m);
      this.latest = m;
      if (m.place && m.place.seq > this.placeAck) {
        this.placeAck = m.place.seq;
        this.body = m.place.body;
      }
    }
  }

  tick(n = 1, each?: () => void): void {
    for (let i = 0; i < n; i++) {
      each?.();
      this.now += TICK;
      this.net.now = this.now;
      this.host.update(this.now);
      this.receive();
    }
  }

  report(id: number, a: number, alpha = 0.5): SeenReport {
    const sa = this.snaps.get(a) as SnapshotMsg;
    const sb = this.snaps.get(a + 1) as SnapshotMsg;
    return { id, depth: 1, a, b: a + 1, alpha, pose: lerpPose(sa.orderly, sb.orderly, alpha) };
  }
}

const dist = (a: { x: number; z: number }, b: { x: number; z: number }): number => Math.hypot(a.x - b.x, a.z - b.z);
const poseOf = (r: Rig) => {
  const o = r.host.state.orderly;
  return { x: o.body.x, y: o.body.y, z: o.body.z, level: o.body.level, yaw: o.yaw, anim: o.anim, animTime: o.animTime };
};

describe('the host as the browser game drives it', () => {
  it('a glance reported between ticks is applied at once, and the freeze it makes is reported', () => {
    const r = new Rig('game-a');
    r.tick(60, () => r.input());
    const rep = r.report(1, r.host.tick - 1, 0.4);
    expect(dist(r.host.state.orderly.body, rep.pose)).toBeGreaterThan(0.01);
    const ticks = r.host.tick;
    const before = r.host.log.length;
    r.input({ seeing: true, seen: [rep] });
    // Half a tick on: no tick is due, the report is applied anyway.
    r.net.now = r.now + TICK / 2;
    r.host.flushReports(r.now + TICK / 2);
    expect(r.host.tick).toBe(ticks);
    expect(poseOf(r)).toEqual(rep.pose);
    expect(r.host.state.orderly.frozen).toBe(true);
    // The put-back froze it outright: the tick would never have said so, so the host does.
    expect(r.host.log.slice(before).map((l) => l.e.type)).toContain('froze');
    // And it stays there through the next ticks while seen.
    r.tick(10, () => r.input({ seeing: true }));
    expect(poseOf(r)).toEqual(rep.pose);
  }, 120_000);

  it('a replaced Orderly is not put back by a report about a moment before it was replaced', () => {
    const r = new Rig('game-b');
    r.tick(60, () => r.input());
    const old = r.report(1, r.host.tick - 10);
    const o = r.host.state.orderly;
    const spot = { ...o.body, x: o.body.x + 1.5 };
    r.host.replaceOrderly({ ...o, body: spot, mode: 'dormant', dormantLeft: 60, path: null, moving: false, speed: 0 });
    r.input({ seeing: true, seen: [old] });
    r.tick();
    expect(r.host.state.orderly.body).toEqual(spot);
    expect(r.host.state.orderly.mode).toBe('dormant');
    expect(r.host.stats.putBacks).toBe(0);
  }, 120_000);

  it('a report of the pose as sent (rounded to the centimetre) leaves the exact position alone', () => {
    const r = new Rig('game-d');
    r.tick(10, () => r.input());
    const o = r.host.state.orderly;
    const exact = { ...o.body, x: o.body.x + 0.123456789 };
    r.host.replaceOrderly({ ...o, body: exact, mode: 'dormant', dormantLeft: 60, path: null, moving: false, speed: 0 });
    r.tick(3, () => r.input());
    const k = r.host.tick - 1;
    r.input({ seeing: true, seen: [r.report(1, k, 0.5)] });
    r.tick();
    expect(r.host.state.orderly.body).toEqual(exact);
    expect(r.host.stats.putBacks).toBe(0);
  }, 120_000);

  it("the host's own player's body is taken as sent (a teleport), another player's jump is refused", () => {
    const t = new Rig('game-c', ['p0']);
    // A trusted player places itself: no start placement is waiting to be acknowledged.
    expect(t.placeAck).toBe(0);
    t.tick(4, () => t.input());
    const far = { ...t.body, x: t.body.x + 12 };
    t.body = far;
    t.tick(2, () => t.input());
    expect(t.host.state.players[0]?.body.x).toBeCloseTo(far.x, 6);
    expect(t.host.stats.clampedInputs).toBe(0);

    const u = new Rig('game-c');
    expect(u.placeAck).toBe(1);
    u.tick(4, () => u.input());
    const start = u.host.state.players[0]?.body.x ?? 0;
    u.body = { ...u.body, x: u.body.x + 12 };
    u.tick(2, () => u.input());
    expect(u.host.state.players[0]?.body.x).toBeCloseTo(start, 6);
    expect(u.host.stats.clampedInputs).toBeGreaterThan(0);
  }, 120_000);
});

describe("a client's estimate of the host's clock", () => {
  it('follows at once when the host clock jumps (a stalled tab, a skipped wait)', () => {
    const c = new HostClock();
    for (let i = 0; i < 50; i++) c.sample(i * 0.05, 0.001, 100 + i * 0.05 + 0.002, i * 0.05 + 0.004);
    expect(c.offset).toBeCloseTo(100, 2);
    // The host skipped 30 s: the next sample says so, and the old samples are dropped.
    c.sample(3, 0.001, 133.002, 3.004);
    expect(c.offset).toBeCloseTo(130, 2);
    // Ordinary jitter does not reset it.
    c.sample(3.05, 0.001, 133.05 + 0.02, 3.05 + 0.03);
    expect(c.offset).toBeCloseTo(130, 2);
  });
});
