// The wire format, the in-memory transport and the host-clock estimator.

import { describe, expect, it } from 'vitest';
import { createOrderly } from '../../src/sim/entity';
import { generateClinic } from '../../src/sim/clinic';
import { makeRng } from '../../src/sim/rng';
import { decode, encode, lerpPose, messageBytes, orderlySnap, q2, quantPose, type InputMsg, type Message, type SnapshotMsg } from '../../src/net/protocol';
import { HostClock, TICK } from '../../src/net/session';
import { MemoryNetwork } from '../../src/net/transport';
import { LOSSY, Session } from './harness';

describe('protocol: compact, versioned, JSON-safe', () => {
  it('every message survives encode and decode', () => {
    const plan = generateClinic('wire', 1);
    const pose = orderlySnap(createOrderly(plan));
    const input: InputMsg = {
      type: 'input',
      seq: 7,
      ct: 1234.5678,
      body: { x: 12.34, z: 5.6, y: 0, level: 0 },
      eye: 1.65,
      yaw: -1.234,
      pitch: 0.2,
      hFovDeg: 102.45,
      vFovDeg: 70,
      raised: true,
      holdDoors: false,
      seeing: true,
      calls: 2,
      pickUps: 0,
      ackEvent: 40,
      ackHt: 12.35,
      renderTime: 12.2,
      placeAck: 1,
      seen: [{ id: 3, depth: 1, a: 240, b: 241, alpha: 0.25, pose: quantPose(pose) }],
    };
    const back = decode(encode(input)) as InputMsg;
    expect(back.type).toBe('input');
    expect(back.seen[0]?.pose).toEqual(input.seen[0]?.pose);
    expect(back.body).toEqual(input.body);
    expect(back.ct).toBeLessThanOrEqual(input.ct);
    expect(input.ct - back.ct).toBeLessThan(0.001);
    for (const m of [
      { type: 'join', name: 'p1', ct: 3 },
      { type: 'leave' },
      { type: 'ping', ct: 9.5 },
      { type: 'pong', ct: 9.5, hr: 10, st: 10.25 },
    ] as Message[]) {
      expect(decode(encode(m))).toEqual(m);
    }
    expect(decode('[2,"L"]')).toBeNull();
    expect(decode('not json')).toBeNull();
  }, 120_000);

  it('a quantised pose blends the same on both machines, bit for bit', () => {
    const rng = makeRng('lerp');
    for (let i = 0; i < 1000; i++) {
      const a = quantPose({ x: rng.next() * 80, y: 0, z: rng.next() * 80, level: 0, yaw: rng.next() * 6 - 3, anim: 'walk', animTime: rng.next() * 9 });
      const b = quantPose({ x: a.x + rng.next() * 0.2, y: 0, z: a.z - rng.next() * 0.2, level: 0, yaw: a.yaw + 0.1, anim: 'walk', animTime: a.animTime + 0.05 });
      const k = rng.next();
      const drawn = lerpPose(a, b, k);
      // What the host recomputes from a report: the same function on the same numbers after JSON.
      const sent = JSON.parse(JSON.stringify([a, b, k])) as [typeof a, typeof b, number];
      expect(lerpPose(sent[0], sent[1], sent[2])).toEqual(drawn);
      expect(quantPose(drawn)).toEqual(drawn);
      expect(JSON.parse(JSON.stringify(drawn))).toEqual(drawn);
    }
  }, 120_000);

  it('sizes: a 4-player snapshot stays under about 1.5 kB and an input under about 200 bytes (measured over sessions)', () => {
    const measure = (players: number, sessions: number) => {
      const snaps: number[] = [];
      const inputs: number[] = [];
      let ticks = 0;
      for (let i = 0; i < sessions; i++) {
        const s = new Session({ seed: `size-${players}-${i}`, remotes: players - 1, net: LOSSY });
        s.run(60);
        ticks += s.host.tick;
        for (const x of s.host.snapshotSizes) if (x.players === players) snaps.push(x.bytes);
        for (const m of s.machines) inputs.push(...m.client.inputSizes);
      }
      snaps.sort((a, b) => a - b);
      inputs.sort((a, b) => a - b);
      const mean = (xs: number[]): number => xs.reduce((a, b) => a + b, 0) / xs.length;
      const pct = (xs: number[], p: number): number => xs[Math.min(xs.length - 1, Math.floor(xs.length * p))] ?? 0;
      return { snaps, inputs, ticks, meanSnap: mean(snaps), meanIn: mean(inputs), p99Snap: pct(snaps, 0.99), p99In: pct(inputs, 0.99) };
    };
    const four = measure(4, 6);
    const eight = measure(8, 2);
    const line = (n: number, m: ReturnType<typeof measure>): string =>
      `${n} players (${m.ticks} ticks): snapshot mean ${m.meanSnap.toFixed(0)} B, p99 ${m.p99Snap} B, max ${m.snaps.at(-1)} B; input mean ${m.meanIn.toFixed(0)} B, p99 ${m.p99In} B, max ${m.inputs.at(-1)} B; ` +
      `at 20 Hz each player receives ${((m.meanSnap * 20) / 1000).toFixed(1)} kB/s and sends ${((m.meanIn * 20) / 1000).toFixed(1)} kB/s, the host sends ${((m.meanSnap * 20 * n) / 1000).toFixed(1)} kB/s and receives ${((m.meanIn * 20 * n) / 1000).toFixed(1)} kB/s`;
    console.log(`sizes:
  ${line(4, four)}
  ${line(8, eight)}`);
    expect(four.snaps.length).toBeGreaterThan(10000);
    expect(four.snaps.at(-1)).toBeLessThanOrEqual(1500);
    expect(four.p99In).toBeLessThanOrEqual(200);
    expect(four.inputs.at(-1)).toBeLessThanOrEqual(220);
  }, 120_000);

  it('a snapshot is decoded to the state that was encoded', () => {
    const s = new Session({ seed: 'roundtrip', remotes: 1, net: LOSSY });
    s.run(5);
    const w = s.host.world();
    const msg: SnapshotMsg = { type: 'snap', ...w, st: 5, ackIn: 3, echo: [1.5, 0.01], ackSeen: 0, evFrom: 1, events: [], place: null };
    const back = decode(encode(msg)) as SnapshotMsg;
    expect(back.phase).toBe(w.phase);
    expect(back.orderly).toEqual(w.orderly);
    expect(back.players.map((p) => [p.id, p.status, p.active, q2(p.body.x)])).toEqual(w.players.map((p) => [p.id, p.status, p.active, q2(p.body.x)]));
    expect(back.crew.map((m) => m.tape.id)).toEqual(w.crew.map((m) => m.tape.id));
    expect(messageBytes(encode(msg))).toBe(encode(msg).length);
  }, 120_000);
});

describe('the in-memory transport', () => {
  it('delays, jitters, loses, reorders and duplicates as configured, from its seed', () => {
    const run = (): { got: number[]; times: number[]; lost: number; dup: number } => {
      const net = new MemoryNetwork('t1');
      const a = net.connect('a');
      const b = net.connect('b');
      net.setLink('a', 'b', { delay: 0.1, jitter: 0.05, loss: 0.1, reorder: 0.2, reorderDelay: 0.1, duplicate: 0.1 });
      const got: number[] = [];
      const times: number[] = [];
      for (let i = 0; i < 2000; i++) {
        net.now = i * 0.01;
        a.send('b', String(i));
        for (const m of b.receive()) {
          got.push(Number(m.data));
          times.push(net.now - Number(m.data) * 0.01);
        }
      }
      net.now = 100;
      for (const m of b.receive()) got.push(Number(m.data));
      const st = net.stats.get('a>b');
      return { got, times, lost: st?.lost ?? 0, dup: st?.duplicated ?? 0 };
    };
    const r = run();
    const unique = new Set(r.got);
    expect(r.lost / 2000).toBeGreaterThan(0.07);
    expect(r.lost / 2000).toBeLessThan(0.13);
    expect(r.got.length - unique.size).toBeGreaterThan(100); // duplicates delivered
    expect(unique.size).toBe(2000 - r.lost);
    let inversions = 0;
    for (let i = 1; i < r.got.length; i++) if ((r.got[i] as number) < (r.got[i - 1] as number)) inversions++;
    expect(inversions).toBeGreaterThan(100);
    expect(Math.min(...r.times)).toBeGreaterThanOrEqual(0.1 - 0.01);
    expect(run().got).toEqual(r.got);
  }, 120_000);

  it('peers hear of each other joining and leaving; nothing reaches a peer that left', () => {
    const net = new MemoryNetwork('t2');
    const a = net.connect('a');
    const b = net.connect('b');
    expect(a.peerEvents()).toEqual([{ kind: 'joined', peer: 'b' }]);
    expect(b.peerEvents()).toEqual([{ kind: 'joined', peer: 'a' }]);
    b.close();
    expect(a.peerEvents()).toEqual([{ kind: 'left', peer: 'b' }]);
    a.send('b', 'x');
    a.broadcast('y');
    expect(net.nextDelivery()).toBeNull();
  }, 120_000);
});

describe('the host-clock estimator', () => {
  it('its error stays within its own bound under asymmetric delay and jitter', () => {
    const rng = makeRng('clock');
    let worst = 0;
    for (let trial = 0; trial < 200; trial++) {
      const offset = (rng.next() - 0.5) * 1000;
      const up = rng.next() * 0.25;
      const down = rng.next() * 0.25;
      const c = new HostClock();
      for (let k = 0; k < 100; k++) {
        const t0 = k * TICK;
        const ju = rng.next() * 0.06;
        const jd = rng.next() * 0.06;
        const hostRecv = t0 + offset + up + ju;
        const hold = rng.next() * TICK;
        const hostSend = hostRecv + hold;
        const t3 = hostSend - offset + down + jd;
        c.sample(Math.floor(t0 * 1000) / 1000, hold, hostSend, t3);
      }
      const err = Math.abs(c.offset - offset);
      expect(err).toBeLessThanOrEqual(c.errorBound + 1e-9);
      worst = Math.max(worst, err);
    }
    expect(worst).toBeGreaterThan(0.05); // asymmetry really is there, and covered by the bound
  }, 120_000);
});
