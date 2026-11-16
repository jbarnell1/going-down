// The host's side of the rule, driven by hand-made inputs: put-backs to exactly the pose a client
// holds, the rewritten history, the bound, wind-ups cancelled by a report, catches that wait for the
// victim's screen, and the light policing of bodies (impossible jumps, caught players).

import { describe, expect, it } from 'vitest';
import { carBody, type RunPlayer, type RunState } from '../../src/sim/run';
import { NetHost } from '../../src/net/host';
import { decode, encode, lerpPose, type InputMsg, type SeenReport, type SnapshotMsg } from '../../src/net/protocol';
import { TICK } from '../../src/net/session';
import { MemoryNetwork, type MemoryTransport } from '../../src/net/transport';

/** The player stands on the landing looking straight up with no field of view: never sees anything. */
function blindLanding(s: RunState): RunState {
  const players = s.players.map((p, i): RunPlayer => ({ ...p, body: carBody(s.car, -0.7, i % 2 ? 0.45 : -0.45), aboard: false }));
  return { ...s, phase: 'away', players, orderly: { ...s.orderly, mode: 'hunting' } };
}

class Rig {
  readonly net = new MemoryNetwork('rig');
  readonly host: NetHost;
  readonly me: MemoryTransport;
  now = 0;
  seq = 0;
  ct = 0;
  readonly snaps = new Map<number, SnapshotMsg>();
  latest: SnapshotMsg | null = null;
  placeAck = 0;
  body = { x: 0, y: 0, z: 0, level: 0 as 0 | 1 };

  constructor(seed: string, prepare: (s: RunState) => RunState, roster = ['p0']) {
    const ht = this.net.connect('host');
    this.me = this.net.connect('p0');
    this.host = new NetHost({ transport: ht, seed, roster, now: 0, prepare });
    this.me.send('host', encode({ type: 'join', name: 'p0', ct: 0 }));
    this.tick();
  }

  input(over: Partial<InputMsg> = {}): void {
    this.ct += TICK;
    const m: InputMsg = {
      type: 'input',
      seq: ++this.seq,
      ct: this.ct,
      body: this.body,
      eye: 1.65,
      yaw: 0,
      pitch: Math.PI / 2,
      hFovDeg: 0.01,
      vFovDeg: 0.01,
      raised: false,
      holdDoors: false,
      seeing: false,
      calls: 0,
      pickUps: 0,
      ackEvent: 0,
      ackHt: this.latest?.ht ?? -1,
      renderTime: this.latest?.ht ?? -1,
      placeAck: this.placeAck,
      seen: [],
      ...over,
    };
    this.me.send('host', encode(m));
  }

  tick(n = 1, each?: () => void): void {
    for (let i = 0; i < n; i++) {
      each?.();
      this.now += TICK;
      this.net.now = this.now;
      this.host.update(this.now);
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
  }

  report(id: number, a: number, alpha = 0.5): SeenReport {
    const sa = this.snaps.get(a) as SnapshotMsg;
    const sb = this.snaps.get(a + 1) as SnapshotMsg;
    return { id, depth: 1, a, b: a + 1, alpha, pose: lerpPose(sa.orderly, sb.orderly, alpha) };
  }
}

const dist = (a: { x: number; z: number }, b: { x: number; z: number }): number => Math.hypot(a.x - b.x, a.z - b.z);

describe('the host honours what a client saw', () => {
  it('puts the Orderly back to exactly the pose the client holds, rewrites the history, and holds it while seen', () => {
    const r = new Rig('host-a', blindLanding);
    r.tick(60, () => r.input());
    const now = r.host.state.orderly.body;
    const k = r.host.tick - 20;
    const rep = r.report(1, k);
    expect(dist(now, rep.pose)).toBeGreaterThan(1); // it walked on since that frame
    r.input({ seeing: true, seen: [rep] });
    r.tick();
    const o = r.host.state.orderly;
    expect({ x: o.body.x, y: o.body.y, z: o.body.z, level: o.body.level, yaw: o.yaw, anim: o.anim, animTime: o.animTime }).toEqual(rep.pose);
    expect(r.host.stats.putBacks).toBe(1);
    expect(r.latest?.ackSeen).toBe(1);
    // A later report about the abandoned timeline changes nothing.
    r.input({ seeing: true, seen: [r.report(2, k + 5)] });
    r.tick();
    expect(r.host.state.orderly.body).toEqual(o.body);
    expect(r.host.stats.putBacks).toBe(1);
    // Held while the player says they see it, and for the grace after.
    r.tick(40, () => r.input({ seeing: true }));
    r.tick(5, () => r.input());
    expect(r.host.state.orderly.body).toEqual(o.body);
    r.tick(40, () => r.input());
    expect(dist(r.host.state.orderly.body, o.body)).toBeGreaterThan(0.5);
  }, 120_000);

  it('beyond the bound it is not moved: the violation is counted', () => {
    const r = new Rig('host-b', blindLanding);
    r.tick(58, () => r.input());
    let k = 1;
    while (dist(r.snaps.get(k)?.orderly ?? { x: 0, z: 0 }, r.host.state.orderly.body) <= 4.5) k++;
    const before = r.host.state.orderly.body;
    r.input({ seeing: true, seen: [r.report(1, k)] });
    r.tick();
    expect(r.host.state.orderly.body).toEqual(before);
    expect(r.host.stats.boundViolations).toBe(1);
    expect(r.host.stats.putBacks).toBe(0);
  }, 120_000);
});

describe('catches across the network', () => {
  /** The Orderly hunting, 0.7 m from the blind player on the landing. */
  const closeBy = (s: RunState): RunState => {
    const t = blindLanding(s);
    return { ...t, orderly: { ...t.orderly, body: carBody(t.car, -1.4, -0.45) } };
  };

  it('a catch waits until the victim has drawn up to its end without seeing it, then lands', () => {
    const r = new Rig('host-c', closeBy);
    let stale = -1;
    r.tick(30, () => r.input({ ackHt: stale, renderTime: stale }));
    const types = r.host.log.map((l) => l.e.type);
    expect(types).toContain('windUp');
    expect(types).not.toContain('caught');
    expect(r.host.stats.catchHoldTicks).toBeGreaterThan(0);
    expect(r.host.state.orderly.mode).toBe('windUp');
    // The victim's machine now shows it drew past the wind-up's end (and saw nothing).
    stale = r.latest?.ht ?? 0;
    r.tick(3, () => r.input());
    expect(r.host.log.map((l) => l.e.type)).toContain('caught');
  }, 120_000);

  it('a seen report during the wind-up cancels it, and nobody is caught while it is seen', () => {
    const r = new Rig('host-d', closeBy);
    r.tick(4, () => r.input({ ackHt: -1, renderTime: -1 }));
    expect(r.host.state.orderly.mode).toBe('windUp');
    const k = r.host.tick - 1;
    r.input({ seeing: true, seen: [r.report(1, k - 1, 0)] });
    r.tick();
    const types = r.host.log.map((l) => l.e.type);
    expect(types).toContain('windUpCancelled');
    r.tick(60, () => r.input({ seeing: true }));
    expect(r.host.log.map((l) => l.e.type)).not.toContain('caught');
  }, 120_000);
});

describe('policing bodies (friends, not strangers)', () => {
  it('refuses an impossible jump until enough time has passed to make it possible', () => {
    const r = new Rig('host-e', blindLanding);
    r.tick(5, () => r.input());
    const start = r.host.state.players[0]?.body;
    const far = { ...r.body, x: r.body.x + 12 };
    r.input({ body: far });
    r.tick();
    expect(r.host.stats.clampedInputs).toBe(1);
    expect(r.host.state.players[0]?.body).toEqual(start);
    r.ct += 3; // three seconds later the same spot is reachable
    r.input({ body: far });
    r.tick();
    expect(r.host.state.players[0]?.body).toEqual(far);
  }, 120_000);

  it('ignores the inputs of a caught player (no call, no movement)', () => {
    const caught = (s: RunState): RunState => {
      const t = blindLanding(s);
      return { ...t, players: t.players.map((p): RunPlayer => (p.id === 'p0' ? { ...p, status: 'caught' } : p)) };
    };
    const r = new Rig('host-f', caught, ['p0', 'p1']);
    const start = r.host.state.players[0]?.body;
    r.tick(20, () => r.input({ calls: 1, body: { ...r.body, x: r.body.x - 0.5 } }));
    expect(r.host.log.map((l) => l.e.type)).not.toContain('called');
    expect(r.host.state.players[0]?.body).toEqual(start);
    expect(r.host.state.phase).toBe('away');
  }, 120_000);
});
