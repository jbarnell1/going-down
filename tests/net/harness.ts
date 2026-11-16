// A whole networked session in one process: a host machine (NetHost plus its own player's NetClient
// on a perfect loopback link) and remote players' machines, all over the in-memory network, on one
// global clock with every machine's own clock offset from it. Each client renders at 60 frames a
// second in its own local time; a bot (sim/bot.ts) drives each player. Event-driven: time jumps to
// the next frame, tick or delivery.

import { botView, createBot, stepBot, BOT_EYE, type Bot } from '../../src/sim/bot';
import { isWalkable } from '../../src/sim/floor';
import { cellOf, type Body } from '../../src/sim/move';
import { makeRng, type Rng } from '../../src/sim/rng';
import { carBody, CALL_REACH, type RunPlayer, type RunState } from '../../src/sim/run';
import { NetClient, type Frame, type LocalFrame } from '../../src/net/client';
import { NetHost } from '../../src/net/host';
import type { Pose } from '../../src/net/protocol';
import { carFor, planFor, type Camera } from '../../src/net/session';
import { MemoryNetwork, PERFECT_LINK } from '../../src/net/transport';

export interface NetConfig {
  delayMin: number;
  delayMax: number;
  jitter: number;
  loss: number;
  reorder: number;
  reorderDelay: number;
  duplicate: number;
}

/** The hostile network of the property tests. */
export const LOSSY: NetConfig = { delayMin: 0, delayMax: 0.25, jitter: 0.06, loss: 0.05, reorder: 0.05, reorderDelay: 0.1, duplicate: 0.03 };
export const ZERO: NetConfig = { delayMin: 0, delayMax: 0, jitter: 0, loss: 0, reorder: 0, reorderDelay: 0, duplicate: 0 };

export const FRAME = 1 / 60;

export interface FrameRec {
  /** Global time = true host time (the host's clock starts at 0 with the session). */
  g: number;
  local: number;
  rt: number;
  dark: boolean;
  seeing: boolean;
  held: boolean;
  pose: Pose | null;
  depth: number;
  cam: Camera;
  frame: Frame;
}

export interface Machine {
  id: string;
  /** Local clock = global time + offset. */
  offset: number;
  phase: number;
  k: number;
  client: NetClient;
  bot: Bot | null;
  botDepth: number;
  /** Scripted control instead of the bot (returns the local frame), if set. */
  script: ((m: Machine, s: Session, dt: number) => LocalFrame) | null;
  body: Body | null;
  rng: Rng;
  frames: number;
  gone: boolean;
  /** The last frame this machine drew. */
  last: Frame | null;
}

export interface SessionOpts {
  seed: string;
  /** Remote players (the host's own player is always there too). */
  remotes: number;
  net: NetConfig;
  /** 'hunt': players start on the landing, the Orderly hunting, the car away. 'run': as createRun. */
  setup?: 'hunt' | 'run';
  prepare?: (s: RunState) => RunState;
  onFrame?: (m: Machine, rec: FrameRec, s: Session) => void;
  /** After every host tick. */
  onTick?: (s: Session) => void;
}

export function huntSetup(s: RunState): RunState {
  const players = s.players.map((p, i): RunPlayer => ({ ...p, body: carBody(s.car, -0.7 - 0.45 * Math.floor(i / 2), i % 2 ? 0.45 : -0.45), aboard: false }));
  return { ...s, phase: 'away', players, orderly: { ...s.orderly, mode: 'hunting' } };
}

export class Session {
  readonly net: MemoryNetwork;
  readonly host: NetHost;
  readonly machines: Machine[] = [];
  g = 0;
  readonly seed: string;
  private readonly opts: SessionOpts;
  private readonly rng: Rng;

  constructor(opts: SessionOpts) {
    this.opts = opts;
    this.seed = opts.seed;
    this.rng = makeRng(`${opts.seed}:session`);
    this.net = new MemoryNetwork(`${opts.seed}:net`, PERFECT_LINK);
    const ids = Array.from({ length: opts.remotes + 1 }, (_, i) => `p${i}`);
    const hostT = this.net.connect('host');
    const prepare = opts.prepare ?? (opts.setup === 'run' ? undefined : huntSetup);
    this.host = new NetHost({ transport: hostT, seed: opts.seed, roster: ids, now: 0, prepare });
    for (const id of ids) this.addMachine(id, id !== 'p0');
  }

  /** Connects a player's machine (a remote one gets a lossy link drawn from the config). */
  addMachine(id: string, remote: boolean): Machine {
    const n = this.opts.net;
    const t = this.net.connect(id);
    if (remote) {
      for (const [a, b] of [
        ['host', id],
        [id, 'host'],
      ] as const) {
        const delay = n.delayMin + this.rng.next() * (n.delayMax - n.delayMin);
        this.net.setLink(a, b, { delay, jitter: n.jitter, loss: n.loss, reorder: n.reorder, reorderDelay: n.reorderDelay, duplicate: n.duplicate });
      }
    }
    const offset = (this.rng.next() - 0.5) * 200;
    const phase = this.g + this.rng.next() * FRAME;
    const m: Machine = {
      id,
      offset,
      phase,
      k: 0,
      client: new NetClient(t, 'host', id, this.g + offset),
      bot: null,
      botDepth: 0,
      script: null,
      body: null,
      rng: makeRng(`${this.seed}:${id}:intents`),
      frames: 0,
      gone: false,
      last: null,
    };
    this.machines.push(m);
    return m;
  }

  nextFrameAt(m: Machine): number {
    return m.phase + m.k * FRAME;
  }

  /** Runs the session until global time `until`. */
  run(until: number): void {
    for (;;) {
      let next = this.host.ended ? Infinity : this.host.nextTickAt();
      for (const m of this.machines) if (!m.gone) next = Math.min(next, this.nextFrameAt(m));
      const d = this.net.nextDelivery();
      if (d !== null) next = Math.min(next, d);
      if (next > until) break;
      this.g = Math.max(this.g, next);
      this.net.now = this.g;
      const tick = this.host.tick;
      this.host.update(this.g);
      if (this.host.tick !== tick) this.opts.onTick?.(this);
      for (const m of this.machines) if (!m.gone) m.client.receive(this.g + m.offset);
      for (const m of this.machines) {
        if (m.gone || this.nextFrameAt(m) > this.g + 1e-12) continue;
        this.frame(m);
        m.k++;
      }
    }
    this.g = until;
    this.net.now = until;
  }

  private myStatus(m: Machine): string | null {
    const p = m.client.latest?.players.find((q) => q.id === m.client.id);
    return p ? p.status : null;
  }

  private frame(m: Machine): void {
    const local = this.g + m.offset;
    const c = m.client;
    m.frames++;
    let lf: LocalFrame;
    if (m.script) {
      lf = m.script(m, this, FRAME);
    } else {
      const plan = planFor(this.seed, c.localDepth);
      // The bot flees (sprints) from the Orderly where this machine last drew it, if it is close behind.
      const seen = m.last?.orderly ?? null;
      // Taken (the screen latched blind at the end of a wind-up on it): the game holds the player still.
      const taken = m.last?.taken === true;
      if (m.bot && !taken && m.botDepth === c.localDepth && c.playing && this.myStatus(m) === 'ok') stepBot(plan, m.bot, FRAME, seen);
      if (m.bot) m.body = m.bot.body;
      const v = m.bot ? botView(m.bot) : null;
      const body = m.body ?? carBody(carFor(plan), 0.8, 0);
      // Intents: the instrument up some of the time; the call pressed every 2 s within reach of the doors.
      const car = carFor(plan);
      const nearDoor = Math.hypot(body.x - car.doorX, body.z - car.doorZ) <= CALL_REACH - 0.3;
      const slot = Math.floor(this.g * 2 + Number(m.id.slice(1)));
      lf = {
        body,
        eye: BOT_EYE,
        yaw: v?.yaw ?? 0,
        pitch: v?.pitch ?? 0,
        hFovDeg: v?.hFovDeg ?? 90,
        vFovDeg: v?.vFovDeg ?? 70,
        // A sprinting bot has its instrument down (a raised instrument rules out a sprint).
        raised: slot % 5 < 2 && m.bot?.moveGait !== 'sprint',
        call: nearDoor && m.frames % 120 === 7,
        gait: m.bot?.moveGait ?? 'walk',
      };
    }
    const f = c.frame(local, lf);
    m.last = f;
    if (f.placed) this.adopt(m, f.placed, c.localDepth);
    const cam: Camera = { body: f.placed ?? lf.body, eye: lf.eye, yaw: lf.yaw, pitch: lf.pitch, hFovDeg: lf.hFovDeg, vFovDeg: lf.vFovDeg };
    this.opts.onFrame?.(m, { g: this.g, local, rt: f.renderTime, dark: f.dark, seeing: f.seeing, held: f.held, pose: f.orderly, depth: f.depth, cam, frame: f }, this);
  }

  /** The host moved the player: the bot starts again from there. */
  private adopt(m: Machine, body: Body, depth: number): void {
    m.body = body;
    if (m.script) return;
    const plan = planFor(this.seed, depth);
    const cell = cellOf(plan, body);
    const start = isWalkable(plan, cell.level, cell.x, cell.y) ? cell : plan.landing;
    const watch = m.rng.next();
    m.bot = createBot(plan, m.id, `${this.seed}:${m.id}:${depth}:${m.frames}`, { start, watchfulness: watch, oblivious: m.rng.next() < 0.25 });
    m.bot.body = body;
    m.botDepth = depth;
  }

  /** A machine leaves the session (sends leave and drops off the network). */
  leave(id: string): void {
    const m = this.machines.find((q) => q.id === id);
    if (!m || m.gone) return;
    m.client.leave();
    m.gone = true;
  }
}
