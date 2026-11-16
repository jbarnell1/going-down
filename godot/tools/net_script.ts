// The scripted network sessions the network reference is made from (dump_reference.ts job 'net').
// Each scene runs the real NetHost and NetClients of src/net over the in-memory network of
// src/net/transport.ts (seeded delay, jitter, loss, reordering, duplication), on one global clock with
// every machine's own clock offset from it, exactly like tests/net/harness.ts. The players are driven
// by scripts that make their choices from what they see (and from the host, where that is simpler),
// but only the RESULT of each choice is recorded: every machine's LocalFrame on every frame, quantised
// (centimetres, milliradians, thousandths). tests/ref_net.gd replays those frames through the GDScript
// port (godot/net) with the same network and the same clocks and must reproduce, exactly:
//   - every message on the network (sender, receiver, time, length; the decoded message with the pay
//     fields masked; and, within 1e-9, with them);
//   - every frame of every client (what it draws: dark, the Orderly's pose, held, seeing, taken, the
//     other players' interpolated bodies, the render clock, placements, its tank, events received);
//   - the host's whole run state after every tick, and its counters.
// So the script itself is never ported.
//
// The scenes: two and four players; the Orderly watched and not watched at 0, 100 and 300 ms; jitter;
// a lossy link (loss, reordering, duplicates); a catch with the taken latch; blinks and the blackout;
// stepping out, calling the lift, boarding, the vote and banking (the server's HostRules, soft catch
// included); riding down to floor 2; a player joining mid-wait (a spectator until the next stop) and a
// player leaving.

import { BOT_EYE, BOT_HFOV_DEG, BOT_VFOV_DEG } from '../../src/sim/bot';
import { yawToward } from '../../src/sim/entity';
import { bodyAtCell, type Body } from '../../src/sim/move';
import { distancesFrom, posFromIndex } from '../../src/sim/floor';
import { carBody, CALL_REACH, type RunState } from '../../src/sim/run';
import { freshStamina, gaitFor, speedFor, stepStamina, type Gait, type Stamina } from '../../src/sim/stamina';
import { NetClient, type Frame, type LocalFrame } from '../../src/net/client';
import { NetHost } from '../../src/net/host';
import { decode, type Pose } from '../../src/net/protocol';
import { carFor, moveLocal, planFor } from '../../src/net/session';
import { MemoryNetwork, PERFECT_LINK, type LinkConfig } from '../../src/net/transport';
import { HostRules } from '../../src/game/runHost';
import { huntSetup } from '../../tests/net/harness';

export const FRAME = 1 / 60;

export interface MachineSpec {
  id: string;
  /** Remote machines get the link config below; the host's own machine (p0) a perfect one. */
  up: Partial<LinkConfig>;
  down: Partial<LinkConfig>;
  offset: number;
  phase: number;
  joinAt: number;
  leaveAt: number | null;
}

export interface SceneSpec {
  name: string;
  seed: string;
  /** 'hunt': players on the landing, Orderly hunting, car away (harness huntSetup). 'rules': the
   * server's HostRules (start spots in the car, soft catch); `entity` false parks the Orderly. */
  setup: 'hunt' | 'rules';
  entity: boolean;
  roster: string[];
  until: number;
  machines: MachineSpec[];
  /** Quick set: replayed by `--quick` too. */
  quick: boolean;
  /** The Orderly starts at the first cell (in index order) this many steps from the landing, or where the floor puts it (0). */
  near: number;
}

/** What a scene records (see dump_reference.ts dumpNet for the file format). */
export interface SceneRecord {
  spec: SceneSpec;
  /** Per machine, per frame: the LocalFrame as quantised integers (see Q below). */
  inputs: Record<string, number[][]>;
  frames: Record<string, unknown[]>;
  sends: { t: number; from: string; to: string; data: string }[];
  host: NetHost;
  clients: Record<string, NetClient>;
  hostStates: { tick: number; state: RunState; events: unknown[] }[];
}

// ---------------------------------------------------------------------------------------------
// Quantised LocalFrames: [x cm, z cm, y cm, level, yaw mrad, pitch mrad, eye cm, hfov cdeg, vfov cdeg,
// flags, stamina milli]. flags: raised 1, holdDoors 2, call 4, pickUp 8, gait index << 4, has
// stamina 64, winded 128. The client gets exactly n / 100, n / 1000 (the same doubles on both sides).

const GAITS: Gait[] = ['walk', 'creep', 'sprint'];
export const Q_FIELDS = 11;

export function toRow(lf: LocalFrame): number[] {
  const st = lf.stamina;
  const flags =
    (lf.raised ? 1 : 0) | (lf.holdDoors ? 2 : 0) | (lf.call ? 4 : 0) | (lf.pickUp ? 8 : 0) | (GAITS.indexOf(lf.gait ?? 'walk') << 4) | (st ? 64 : 0) | (st?.winded ? 128 : 0);
  return [
    Math.round(lf.body.x * 100), Math.round(lf.body.z * 100), Math.round(lf.body.y * 100), lf.body.level,
    Math.round(lf.yaw * 1000), Math.round(lf.pitch * 1000), Math.round(lf.eye * 100), Math.round(lf.hFovDeg * 100), Math.round(lf.vFovDeg * 100),
    flags, st ? Math.round(st.level * 1000) : 0,
  ];
}

export function fromRow(r: number[]): LocalFrame {
  const flags = r[9] as number;
  const lf: LocalFrame = {
    body: { x: (r[0] as number) / 100, z: (r[1] as number) / 100, y: (r[2] as number) / 100, level: (r[3] as number) === 1 ? 1 : 0 },
    yaw: (r[4] as number) / 1000,
    pitch: (r[5] as number) / 1000,
    eye: (r[6] as number) / 100,
    hFovDeg: (r[7] as number) / 100,
    vFovDeg: (r[8] as number) / 100,
    raised: (flags & 1) !== 0,
    holdDoors: (flags & 2) !== 0,
    call: (flags & 4) !== 0,
    pickUp: (flags & 8) !== 0,
    gait: GAITS[(flags >> 4) & 3] as Gait,
  };
  if (flags & 64) lf.stamina = { level: (r[10] as number) / 1000, winded: (flags & 128) !== 0 };
  return lf;
}

/** Rows delta-coded: [mask, ...changed values' differences], mask bit i = field i changed. */
export function deltaRows(rows: number[][]): number[][] {
  const out: number[][] = [];
  let prev = new Array<number>(Q_FIELDS).fill(0);
  for (const r of rows) {
    let mask = 0;
    const vals: number[] = [];
    for (let i = 0; i < Q_FIELDS; i++) {
      const d = (r[i] as number) - (prev[i] as number);
      if (d !== 0) {
        mask |= 1 << i;
        vals.push(d);
      }
    }
    out.push([mask, ...vals]);
    prev = r;
  }
  return out;
}

// ---------------------------------------------------------------------------------------------
// The record of a frame (what tests/ref_net.gd builds from the GDScript client).

const B = (b: Body) => ({ x: b.x, z: b.z, level: b.level, y: b.y });
const P = (p: Pose) => ({ x: p.x, y: p.y, z: p.z, level: p.level, yaw: p.yaw, anim: p.anim, animTime: p.animTime });

export function frameRecord(c: NetClient, f: Frame, corrected: Stamina | null): unknown {
  return {
    dark: f.dark,
    orderly: f.orderly ? P(f.orderly) : null,
    visible: f.visible,
    held: f.held,
    seeing: f.seeing,
    taken: f.taken,
    depth: f.depth,
    players: f.players.map((p) => ({ id: p.id, body: B(p.body), yaw: p.yaw, pitch: p.pitch, active: p.active, status: p.status, gait: p.gait })),
    renderTime: f.renderTime,
    placed: f.placed ? B(f.placed) : null,
    id: c.id,
    playing: c.playing,
    localDepth: c.localDepth,
    events: c.events.length,
    latchReleased: c.latchReleased,
    hostStamina: c.hostStamina ? { level: c.hostStamina.level, winded: c.hostStamina.winded } : null,
    corrected: corrected ? { level: corrected.level, winded: corrected.winded } : null,
  };
}

/** The Orderly moved to the first cell `cells` steps from the landing (on the landing's level). */
export function nearOrderly(s: RunState, cells: number): RunState {
  if (cells <= 0) return s;
  const d = distancesFrom(s.plan, s.plan.landing);
  for (let i = 0; i < d.length; i++) {
    const p = posFromIndex(s.plan, i);
    if (d[i] === cells && p.level === s.plan.landing.level) return { ...s, orderly: { ...s.orderly, body: bodyAtCell(s.plan, p) } };
  }
  throw new Error(`no cell ${cells} steps from the landing`);
}

// ---------------------------------------------------------------------------------------------
// The scene driver (the event loop of tests/net/harness.ts Session.run, with scripted machines).

/** The network clock's sends, recorded. */
class RecordingNetwork extends MemoryNetwork {
  readonly sends: { t: number; from: string; to: string; data: string }[] = [];
  override post(from: string, to: string, data: string): void {
    this.sends.push({ t: this.now, from, to, data });
    super.post(from, to, data);
  }
}

interface Machine {
  spec: MachineSpec;
  k: number;
  client: NetClient | null;
  gone: boolean;
  last: Frame | null;
  agent: Agent;
}

export class Scene {
  readonly net: RecordingNetwork;
  readonly host: NetHost;
  readonly rules: HostRules | null;
  readonly machines: Machine[] = [];
  g = 0;
  readonly rec: SceneRecord;

  constructor(readonly spec: SceneSpec, script: (m: Agent, s: Scene) => void) {
    this.net = new RecordingNetwork(`${spec.seed}:net`, PERFECT_LINK);
    const hostT = this.net.connect('host');
    this.rules = spec.setup === 'rules' ? new HostRules(spec.entity, 1) : null;
    this.host = new NetHost({
      transport: hostT,
      seed: spec.seed,
      roster: spec.roster,
      now: 0,
      prepare: (s0) => nearOrderly(this.rules ? this.rules.prepare(s0) : huntSetup(s0), spec.near),
      step: this.rules ? this.rules.step : undefined,
    });
    this.rec = { spec, inputs: {}, frames: {}, sends: this.net.sends, host: this.host, clients: {}, hostStates: [] };
    for (const ms of spec.machines) {
      this.machines.push({ spec: ms, k: 0, client: null, gone: false, last: null, agent: new Agent(ms.id, script) });
      this.rec.inputs[ms.id] = [];
      this.rec.frames[ms.id] = [];
    }
  }

  private connect(m: Machine): void {
    const t = this.net.connect(m.spec.id);
    this.net.setLink('host', m.spec.id, m.spec.down);
    this.net.setLink(m.spec.id, 'host', m.spec.up);
    m.client = new NetClient(t, 'host', m.spec.id, this.g + m.spec.offset);
    this.rec.clients[m.spec.id] = m.client;
  }

  nextFrameAt(m: Machine): number {
    return m.spec.phase + m.k * FRAME;
  }

  run(): void {
    const until = this.spec.until;
    let recorded = this.hostStates(0);
    for (;;) {
      let next = this.host.ended ? Infinity : this.host.nextTickAt();
      for (const m of this.machines) {
        if (m.gone) continue;
        if (!m.client) next = Math.min(next, m.spec.joinAt);
        else {
          next = Math.min(next, this.nextFrameAt(m));
          if (m.spec.leaveAt !== null) next = Math.min(next, m.spec.leaveAt);
        }
      }
      const d = this.net.nextDelivery();
      if (d !== null) next = Math.min(next, d);
      if (next > until) break;
      this.g = Math.max(this.g, next);
      this.net.now = this.g;
      for (const m of this.machines) {
        if (m.gone) continue;
        if (!m.client && m.spec.joinAt <= this.g) this.connect(m);
        else if (m.client && m.spec.leaveAt !== null && m.spec.leaveAt <= this.g) {
          m.client.leave();
          m.gone = true;
        }
      }
      this.host.update(this.g);
      recorded = this.hostStates(recorded);
      for (const m of this.machines) if (m.client && !m.gone) m.client.receive(this.g + m.spec.offset);
      for (const m of this.machines) {
        if (!m.client || m.gone || this.nextFrameAt(m) > this.g + 1e-12) continue;
        this.frame(m);
        m.k++;
      }
    }
    this.g = until;
    this.net.now = until;
  }

  /** Records the host's state after each new tick (and the events logged at it). */
  private hostStates(from: number): number {
    for (let k = from; k <= this.host.tick; k++) {
      const st = this.host.stateAt(k);
      if (!st) throw new Error(`no state at tick ${k}`);
      this.rec.hostStates.push({ tick: k, state: st, events: this.host.log.filter((l) => l.tick === k).map((l) => l.e) });
    }
    return this.host.tick + 1;
  }

  private frame(m: Machine): void {
    const c = m.client as NetClient;
    const a = m.agent;
    a.scene = this;
    a.client = c;
    a.last = m.last;
    a.local = this.g + m.spec.offset;
    a.g = this.g;
    a.step();
    const row = toRow(a.frame());
    this.rec.inputs[m.spec.id]?.push(row);
    const lf = fromRow(row);
    const corrected = lf.stamina ? c.correctStamina(lf.stamina) : null;
    if (corrected) a.tank = corrected;
    const f = c.frame(this.g + m.spec.offset, lf);
    m.last = f;
    if (f.placed) a.place(f.placed);
    this.rec.frames[m.spec.id]?.push(frameRecord(c, f, corrected));
  }
}

// ---------------------------------------------------------------------------------------------
// The scripted player.

const q2 = (x: number): number => Math.round(x * 100) / 100;

export class Agent {
  scene!: Scene;
  client!: NetClient;
  last: Frame | null = null;
  local = 0;
  g = 0;
  body: Body | null = null;
  yaw = 0;
  pitch = 0;
  raised = false;
  hold = false;
  call = false;
  pickUp = false;
  gait: Gait = 'walk';
  tank: Stamina = freshStamina();
  /** Waypoints to walk to, in order. */
  route: Body[] = [];
  /** Where to look: the Orderly, away from it, the car door, or a fixed yaw. */
  look: 'orderly' | 'away' | 'door' | number = 0;
  /** Seconds of a scene, per agent (the script's own state). */
  mem: Record<string, number | string | boolean> = {};
  ground = 0;

  constructor(
    readonly id: string,
    private readonly script: (a: Agent, s: Scene) => void,
  ) {}

  get phase(): string {
    return this.client.latest?.phase ?? 'arriving';
  }

  get depth(): number {
    return this.client.localDepth;
  }

  get plan() {
    return planFor(this.scene.spec.seed, this.depth);
  }

  get car() {
    return carFor(this.plan);
  }

  /** The host's own Orderly (scripts may peek: only their choices are recorded). */
  get orderly(): Body {
    return this.scene.host.state.orderly.body;
  }

  place(b: Body): void {
    this.body = { ...b };
    this.route = [];
  }

  carSpot(u: number, v: number): Body {
    return carBody(this.car, u, v);
  }

  nearDoor(): boolean {
    const b = this.body;
    if (!b) return false;
    return Math.hypot(b.x - this.car.doorX, b.z - this.car.doorZ) <= CALL_REACH - 0.3;
  }

  myStatus(): string | null {
    return this.client.latest?.players.find((p) => p.id === this.client.id)?.status ?? null;
  }

  step(): void {
    this.call = false;
    this.pickUp = false;
    if (!this.body) {
      const me = this.client.latest?.players.find((p) => p.id === this.client.id);
      this.body = me ? { ...me.body } : this.carSpot(0.8, 0);
    }
    this.script(this, this.scene);
    // Walk the route (never while taken: the game holds the player still).
    const before = this.body;
    const taken = this.last?.taken === true;
    const want = this.route.length > 0 && !taken && this.myStatus() === 'ok';
    const gait = gaitFor(this.tank, { sprint: this.gait === 'sprint', creep: this.gait === 'creep', moving: want, cap: Infinity });
    let budget = want ? speedFor(gait) * FRAME : 0;
    while (budget > 1e-9 && this.route.length > 0) {
      const w = this.route[0] as Body;
      const b = this.body as Body;
      const dist = Math.hypot(w.x - b.x, w.z - b.z);
      if (dist < 0.03) {
        this.route.shift();
        continue;
      }
      const stp = Math.min(budget, dist);
      const nb = moveLocal(this.plan, this.phase as RunState['phase'], b, ((w.x - b.x) / dist) * stp, ((w.z - b.z) / dist) * stp);
      budget -= stp;
      this.body = { x: q2(nb.x), z: q2(nb.z), y: q2(nb.y), level: nb.level };
      if (Math.hypot(nb.x - b.x, nb.z - b.z) < 1e-6) {
        this.route.shift();
        break;
      }
    }
    const b = this.body as Body;
    this.ground = Math.hypot(b.x - before.x, b.z - before.z) / FRAME;
    this.tank = stepStamina(this.tank, gait, this.ground, FRAME);
    this.tank = { level: Math.round(this.tank.level * 1000) / 1000, winded: this.tank.winded };
    // Look.
    const o = this.orderly;
    if (this.look === 'orderly') {
      this.yaw = yawToward(o.x - b.x, o.z - b.z);
      const dist = Math.hypot(o.x - b.x, o.z - b.z);
      this.pitch = Math.atan2(o.y + 1.7 - (b.y + BOT_EYE), Math.max(dist, 0.1));
    } else if (this.look === 'away') {
      this.yaw = yawToward(b.x - o.x, b.z - o.z);
      this.pitch = 0;
    } else if (this.look === 'door') {
      this.yaw = yawToward(this.car.doorX - b.x, this.car.doorZ - b.z);
      this.pitch = 0;
    } else {
      this.yaw = this.look;
      this.pitch = 0;
    }
  }

  frame(): LocalFrame {
    return {
      body: this.body as Body,
      eye: BOT_EYE,
      yaw: this.yaw,
      pitch: this.pitch,
      hFovDeg: BOT_HFOV_DEG,
      vFovDeg: BOT_VFOV_DEG,
      raised: this.raised,
      holdDoors: this.hold,
      call: this.call,
      pickUp: this.pickUp,
      gait: this.gait,
      stamina: this.tank,
    };
  }
}

// ---------------------------------------------------------------------------------------------
// The scenes.

const link = (delay: number, jitter = 0, extra: Partial<LinkConfig> = {}): Partial<LinkConfig> => ({ delay, jitter, ...extra });
const LOCAL: Partial<LinkConfig> = { delay: 0 };

function machine(id: string, delay: number, jitter: number, offset: number, phase: number, extra: Partial<MachineSpec> & { lossy?: boolean } = {}): MachineSpec {
  const l = extra.lossy ? { loss: 0.05, reorder: 0.05, reorderDelay: 0.1, duplicate: 0.03 } : {};
  const up = id === 'p0' && delay === 0 ? LOCAL : link(delay, jitter, l);
  return { id, up, down: up, offset, phase, joinAt: 0, leaveAt: null, ...extra };
}

/** Watch the Orderly (`w` true) or keep it behind you, switching every `period` seconds if given. */
function watcher(start: boolean, period = 0) {
  return (a: Agent): void => {
    const on = period > 0 ? Math.floor(a.g / period) % 2 === 0 === start : start;
    a.look = on ? 'orderly' : 'away';
    a.raised = on;
  };
}

/** Out of the car to a spot on the landing (car-local u < 0), then whatever `then` says. */
function stepOut(u: number, v: number) {
  return (a: Agent): boolean => {
    if (a.mem.out) return true;
    if (a.phase !== 'unloading' && a.phase !== 'boarding') return false;
    a.route = [a.carSpot(0.45, 0), a.carSpot(-0.6, 0), a.carSpot(u, v)];
    a.mem.out = true;
    return true;
  };
}

function board(u: number, v: number) {
  return (a: Agent): void => {
    if (a.mem.boarded === a.depth) return;
    a.route = [a.carSpot(-0.6, 0), a.carSpot(0.45, 0), a.carSpot(u, v)];
    a.mem.boarded = a.depth;
  };
}

export function netScenes(): SceneSpec[] {
  return [
    {
      name: 'pair-0ms', seed: 'netref-a', setup: 'hunt', entity: true, roster: ['p0', 'p1'], until: 10, quick: true, near: 6,
      machines: [machine('p0', 0, 0, 12.5, 0.004), machine('p1', 0, 0, -31.25, 0.011)],
    },
    {
      name: 'pair-100ms', seed: 'netref-b', setup: 'hunt', entity: true, roster: ['p0', 'p1'], until: 12, quick: false, near: 6,
      machines: [machine('p0', 0, 0, 3.75, 0.002), machine('p1', 0.1, 0, 47.5, 0.009)],
    },
    {
      name: 'trio-300ms-jitter', seed: 'netref-c', setup: 'hunt', entity: true, roster: ['p0', 'p1', 'p2'], until: 15, quick: true, near: 5,
      machines: [machine('p0', 0, 0, -8.5, 0.001), machine('p1', 0.3, 0.04, 61.25, 0.007), machine('p2', 0.1, 0.02, 5.125, 0.013)],
    },
    {
      name: 'catch-latch', seed: 'netref-d', setup: 'hunt', entity: true, roster: ['p0', 'p1', 'p2'], until: 16, quick: true, near: 7,
      machines: [machine('p0', 0, 0, 0.5, 0.006), machine('p1', 0.1, 0, 22.25, 0.003), machine('p2', 0.3, 0.03, -77.75, 0.012)],
    },
    {
      name: 'lossy', seed: 'netref-e', setup: 'hunt', entity: true, roster: ['p0', 'p1', 'p2'], until: 15, quick: false, near: 5,
      machines: [machine('p0', 0, 0, 1.5, 0.008), machine('p1', 0.15, 0.06, 33.5, 0.001, { lossy: true }), machine('p2', 0.25, 0.06, -12.25, 0.014, { lossy: true })],
    },
    {
      name: 'four-bank', seed: 'netref-f', setup: 'rules', entity: true, roster: ['p0', 'p1', 'p2', 'p3'], until: 110, quick: false, near: 9,
      machines: [machine('p0', 0, 0, 2.25, 0.005), machine('p1', 0.05, 0.01, 18.5, 0.01), machine('p2', 0.15, 0.03, -40.0, 0.002), machine('p3', 0.3, 0.04, 90.75, 0.015)],
    },
    {
      name: 'ride-join-leave', seed: 'netref-g', setup: 'rules', entity: false, roster: ['p0', 'p1'], until: 120, quick: false, near: 0,
      machines: [
        machine('p0', 0, 0, 7.5, 0.003),
        machine('p1', 0.08, 0.01, -15.5, 0.008, { leaveAt: 108 }),
        machine('p2', 0.12, 0.02, 64.25, 0.012, { joinAt: 30 }),
      ],
    },
  ];
}

/** The script of each scene: what every player does, frame by frame. */
export function sceneScript(name: string): (a: Agent, s: Scene) => void {
  switch (name) {
    case 'pair-0ms':
      return (a) => watcher(a.id === 'p0')(a);
    case 'pair-100ms':
      return (a) => watcher(a.id === 'p1')(a);
    case 'trio-300ms-jitter':
      return (a) => {
        watcher(a.id !== 'p2', a.id === 'p0' ? 2.5 : 1.5)(a);
        // p2 sidesteps along the landing now and then (sprinting: the host's tank answers).
        if (a.id === 'p2' && a.route.length === 0 && Math.floor(a.g) % 4 === 1) {
          a.gait = Math.floor(a.g) % 8 === 1 ? 'sprint' : 'walk';
          const side = Math.floor(a.g / 4) % 2 === 0 ? 0.8 : -0.8;
          a.route = [a.carSpot(-1.4, side)];
        }
      };
    case 'catch-latch':
      // Nobody looks until the Orderly winds up on someone; then p2 (300 ms behind) looks once,
      // late, and the others keep their backs turned: catches with the taken latch, and a false latch.
      return (a, s) => {
        a.look = 'away';
        const o = s.host.state.orderly;
        if (a.id === 'p2' && o.mode === 'windUp' && o.windUpTarget !== 'p2' && !a.mem.looked) {
          a.mem.looked = true;
          a.mem.lookUntil = a.g + 1.2;
        }
        if (a.id === 'p2' && typeof a.mem.lookUntil === 'number' && a.g < a.mem.lookUntil) a.look = 'orderly';
      };
    case 'lossy':
      return (a) => {
        watcher(a.id === 'p1', a.id === 'p2' ? 2 : 3)(a);
        if (a.id === 'p0' && a.route.length === 0 && Math.floor(a.g * 2) % 9 === 4) a.route = [a.carSpot(-1.2 - (Math.floor(a.g) % 3) * 0.3, 0.3)];
      };
    case 'four-bank': {
      const spots: Record<string, [number, number]> = { p0: [-1.0, -0.5], p1: [-1.0, 0.5], p2: [-1.6, -0.3], p3: [-1.6, 0.6] };
      const seats: Record<string, [number, number]> = { p0: [0.9, -0.5], p1: [1.5, -0.5], p2: [0.9, 0.5], p3: [1.5, -0.2] };
      return (a, s) => {
        const [u, v] = spots[a.id] as [number, number];
        if (!stepOut(u, v)(a)) return;
        const ph = a.phase;
        // While waiting: p0 and p2 watch the Orderly, p1 watches the door, p3 alternates.
        if (ph === 'away' || ph === 'coming' || ph === 'unloading') {
          a.look = a.id === 'p0' || a.id === 'p2' ? 'orderly' : a.id === 'p1' ? 'door' : Math.floor(a.g / 3) % 2 ? 'orderly' : 'away';
          a.raised = a.id !== 'p3';
          if (a.id === 'p0' && ph === 'away' && a.nearDoor() && !a.mem.called && s.host.state.phase === 'away') {
            a.call = true;
            a.mem.called = true;
          }
        }
        if (ph === 'boarding') {
          const [su, sv] = seats[a.id] as [number, number];
          board(su, sv)(a);
          a.look = 'door';
          a.raised = false;
          a.hold = a.id === 'p1' && a.g % 6 < 2;
        }
      };
    }
    case 'ride-join-leave':
      // The Orderly is parked. Out of the car, call it, board and stand on the DOWN half; ride to
      // floor 2 (p2 joined during the wait and is admitted there); step out; p1 leaves.
      return (a, s) => {
        if (a.id === 'p2' && !a.client.playing) {
          a.look = 'door';
          return;
        }
        const u = a.id === 'p0' ? -1.0 : a.id === 'p1' ? -1.2 : -1.4;
        const v = a.id === 'p0' ? -0.4 : a.id === 'p1' ? 0.4 : 0.0;
        if (a.mem.floor !== a.depth) {
          a.mem.floor = a.depth;
          a.mem.out = false;
          a.mem.called = false;
        }
        if (!stepOut(u, v)(a)) return;
        a.look = 'door';
        a.raised = a.g % 7 < 3;
        if (a.id === 'p0' && a.phase === 'away' && a.route.length === 0 && !a.mem.called && s.host.state.phase === 'away') {
          a.call = true;
          a.mem.called = true;
        }
        if (a.phase === 'boarding') {
          const down = s.host.state.car.down;
          void down;
          board(0.9 + (a.id === 'p1' ? 0.4 : 0), 0.5)(a);
        }
      };
  }
  throw new Error(`no script for ${name}`);
}

/** Runs every scene; returns the records. */
export function runNetScenes(only?: (s: SceneSpec) => boolean): SceneRecord[] {
  const out: SceneRecord[] = [];
  for (const spec of netScenes()) {
    if (only && !only(spec)) continue;
    const sc = new Scene(spec, sceneScript(spec.name));
    sc.run();
    out.push(sc.rec);
  }
  return out;
}

export { decode };
