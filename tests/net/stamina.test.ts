// Sprinting across the network: the host owns every player's tank and holds each body to the pace
// that tank allows. An honest client on a laggy link is never refused; a client that claims to sprint
// for ever covers no more ground than an honest one; the tank and the gaits survive the wire.

import { describe, expect, it } from 'vitest';
import { createOrderly } from '../../src/sim/entity';
import { generateClinic } from '../../src/sim/clinic';
import type { Body } from '../../src/sim/move';
import { carBody, type RunPlayer, type RunState } from '../../src/sim/run';
import { freshStamina, gaitFor, speedFor, SPRINT_SPEED, stepStamina, WALK_SPEED, type Gait, type Stamina } from '../../src/sim/stamina';
import { NetClient } from '../../src/net/client';
import { NetHost } from '../../src/net/host';
import { decode, encode, orderlySnap, type InputMsg, type SnapshotMsg } from '../../src/net/protocol';
import { MemoryNetwork, PERFECT_LINK } from '../../src/net/transport';

const FRAME = 1 / 60;

/** The player on the landing, the Orderly asleep for good: nothing but the bodies and the tanks. */
function quiet(s: RunState): RunState {
  const players = s.players.map((p, i): RunPlayer => ({ ...p, body: carBody(s.car, -0.7, i % 2 ? 0.45 : -0.45), aboard: false }));
  return { ...s, phase: 'away', players, orderly: { ...s.orderly, mode: 'dormant', dormantLeft: Number.POSITIVE_INFINITY } };
}

interface Result {
  /** Ground the host's copy of the body covered (sum of its moves tick to tick). */
  hostGround: number;
  /** Ground the client claims to have covered. */
  clientGround: number;
  refused: number;
  hostTank: Stamina;
  clientTank: Stamina;
  sprintTicks: number;
}

/**
 * One remote player on a 150 ms round trip (75 ms each way, 20 ms jitter, 2% loss, some reordering),
 * pacing back and forth along a 10 m line for `seconds`, asking to sprint the whole time. `honest`
 * steps its own tank (with the host's corrections, as the game does); otherwise it claims to sprint
 * at full speed whatever the tank says.
 */
function pace(seed: string, seconds: number, honest: boolean): Result {
  const net = new MemoryNetwork(`${seed}:net`, PERFECT_LINK);
  const hostT = net.connect('host');
  const t = net.connect('p0');
  const link = { delay: 0.075, jitter: 0.02, loss: 0.02, reorder: 0.02, reorderDelay: 0.05, duplicate: 0.01 };
  net.setLink('host', 'p0', link);
  net.setLink('p0', 'host', link);
  const host = new NetHost({ transport: hostT, seed, roster: ['p0'], now: 0, prepare: quiet });
  const client = new NetClient(t, 'host', 'p0', 0);
  let body: Body | null = null;
  let origin = 0;
  let dir = 1;
  let tank = freshStamina();
  let clientGround = 0;
  let hostGround = 0;
  let sprintTicks = 0;
  let last: Body | null = null;
  let tick = host.tick;
  for (let g = 0; g < seconds; g += FRAME) {
    net.now = g;
    host.update(g);
    if (host.tick !== tick) {
      tick = host.tick;
      const hb = host.state.players[0]?.body;
      if (hb && last && hb.level === last.level) hostGround += Math.hypot(hb.x - last.x, hb.z - last.z);
      if (hb) last = hb;
      if (host.gaitOf('p0') === 'sprint') sprintTicks++;
    }
    client.receive(g);
    let gait: Gait = 'walk';
    if (body) {
      tank = client.correctStamina(tank);
      gait = honest ? gaitFor(tank, { sprint: true, creep: false, moving: true, cap: Infinity }) : 'sprint';
      const step = (honest ? speedFor(gait) : SPRINT_SPEED) * FRAME;
      const b: Body = body;
      let x = b.x + dir * step;
      if (x > origin + 5 || x < origin - 5) {
        dir = -dir;
        x = b.x + dir * step;
      }
      body = { ...b, x };
      clientGround += step;
      tank = stepStamina(tank, gait, step / FRAME, FRAME);
    }
    const f = client.frame(g, { body: body ?? { x: 0, y: 0, z: 0, level: 0 }, eye: 1.65, yaw: 0, pitch: Math.PI / 2, hFovDeg: 0.01, vFovDeg: 0.01, gait, stamina: tank });
    if (f.placed) {
      body = f.placed;
      origin = body.x;
    }
  }
  return { hostGround, clientGround, refused: host.stats.clampedInputs, hostTank: host.staminaOf('p0') ?? freshStamina(), clientTank: tank, sprintTicks };
}

describe('sprinting across the network: the host owns the tank', () => {
  it('an honest sprinter on a 150 ms link is never refused, and its tank follows the host', () => {
    const r = pace('tank-honest', 40, true);
    console.log(
      `honest, 40 s asking to sprint: client covered ${r.clientGround.toFixed(1)} m, host ${r.hostGround.toFixed(1)} m, refused inputs ${r.refused}, ` +
        `host sprint ticks ${r.sprintTicks}; tank at the end client ${r.clientTank.level.toFixed(3)} host ${r.hostTank.level.toFixed(3)}`,
    );
    expect(r.refused).toBe(0);
    // It really did sprint and tire: more ground than walking, less than sprinting throughout.
    expect(r.clientGround).toBeGreaterThan(WALK_SPEED * 40 + 10);
    expect(r.clientGround).toBeLessThan(SPRINT_SPEED * 40 - 40);
    expect(r.sprintTicks).toBeGreaterThan(100);
    // The host saw the same walk, give or take the turns its 20 Hz samples cut and the last moments
    // the link has not delivered yet.
    expect(Math.abs(r.hostGround - r.clientGround)).toBeLessThan(6);
    // Two copies of one tank, a round trip apart: close.
    expect(Math.abs(r.hostTank.level - r.clientTank.level)).toBeLessThan(0.08);
  }, 120_000);

  it('a client claiming endless sprint covers no more ground over 30 s than an honest one', () => {
    const honest = pace('tank-cheat', 30, true);
    const cheat = pace('tank-cheat', 30, false);
    console.log(
      `30 s: honest host-ground ${honest.hostGround.toFixed(1)} m (claimed ${honest.clientGround.toFixed(1)}); ` +
        `endless-sprint claim host-ground ${cheat.hostGround.toFixed(1)} m (claimed ${cheat.clientGround.toFixed(1)}), refused inputs ${cheat.refused}`,
    );
    expect(cheat.clientGround).toBeGreaterThan(SPRINT_SPEED * 30 - 5);
    expect(cheat.refused).toBeGreaterThan(0);
    // The host's copy of its tank runs dry and recovers exactly as an honest player's would, so it is
    // allowed exactly an honest player's ground and no more, whatever it claims.
    expect(cheat.hostGround).toBeLessThanOrEqual(honest.hostGround);
    expect(cheat.hostGround).toBeLessThan(cheat.clientGround - 25);
  }, 120_000);
});

describe('the tank and the gaits on the wire', () => {
  it('a snapshot carries the player their own tank, and every player their gait', () => {
    const plan = generateClinic('wire', 1);
    const base = { tick: 3, ht: 0.15, phase: 'away' as const, depth: 1, timer: 0, floorsAway: null, bellLeft: 0, holdLeft: 0, held: false, blink: null, orderly: orderlySnap(createOrderly(plan)), crew: [], floor: [], summary: null };
    const player = (id: string, gait: Gait) => ({ id, body: { x: 1.5, y: 0, z: 2.25, level: 0 as const }, yaw: 0.5, pitch: 0, active: true, status: 'ok' as const, aboard: false, side: null, connected: true, gait });
    const msg: SnapshotMsg = {
      type: 'snap',
      ...base,
      players: [player('a', 'sprint'), player('b', 'creep'), { ...player('c', 'walk'), status: 'leftBehind', side: 'down' }],
      st: 1,
      ackIn: 42,
      echo: null,
      ackSeen: 0,
      evFrom: 1,
      events: [],
      place: null,
      stamina: { level: 0.4567, winded: true },
    };
    const back = decode(encode(msg)) as SnapshotMsg;
    expect(back.stamina).toEqual({ level: 0.457, winded: true });
    expect(back.ackIn).toBe(42);
    expect(back.players.map((p) => [p.id, p.gait, p.status, p.side])).toEqual([
      ['a', 'sprint', 'ok', null],
      ['b', 'creep', 'ok', null],
      ['c', 'walk', 'leftBehind', 'down'],
    ]);
    const none = decode(encode({ ...msg, stamina: null })) as SnapshotMsg;
    expect(none.stamina).toBeNull();
    const full = decode(encode({ ...msg, stamina: freshStamina() })) as SnapshotMsg;
    expect(full.stamina).toEqual({ level: 1, winded: false });
  });

  it('an input carries the gait asked for (walk when unsaid), alongside its other flags', () => {
    const input: InputMsg = {
      type: 'input', seq: 1, ct: 1, body: { x: 0, y: 0, z: 0, level: 0 }, eye: 1.65, yaw: 0, pitch: 0, hFovDeg: 90, vFovDeg: 70,
      raised: true, holdDoors: true, seeing: true, calls: 0, pickUps: 0, ackEvent: 0, ackHt: 0, renderTime: 0, placeAck: 0, seen: [],
    };
    for (const gait of ['walk', 'creep', 'sprint'] as const) {
      const back = decode(encode({ ...input, gait })) as InputMsg;
      expect([back.gait, back.raised, back.holdDoors, back.seeing]).toEqual([gait, true, true, true]);
    }
    expect((decode(encode(input)) as InputMsg).gait).toBe('walk');
  });
});
