// The host: one player's machine runs the run for everyone. It steps stepRun at 20 ticks a second
// with every player's latest input, is the only authority on the run, the Orderly, the instruments
// and the tapes, and sends every client a snapshot after every tick.
//
// The rule that must survive the network (the Orderly is never seen to move on anyone's screen) is
// kept by the clients' own drawing (client.ts) and honoured here:
//  - A "seen" report says: this client froze its drawing of the Orderly at this pose, blended from
//    these two snapshots. The host keeps HISTORY_SECONDS of the Orderly's states (as sent, quantised).
//    If the Orderly has moved on since, it is put back exactly to the pose the client holds (the state
//    the client was drawing, with the drawn position), and the history from that moment on is
//    rewritten to "it stood there", so later reports about the abandoned timeline change nothing.
//    Beyond PUT_BACK_MAX metres it is not moved; the violation is counted instead.
//  - Looking always saves you: a seen report, or any input saying "I can see it", cancels a wind-up
//    in progress, and the Orderly is held (as if seen this tick, with the usual grace after).
//  - A catch is not completed until the victim's machine has shown, by an input, that it drew every
//    frame up to the moment the wind-up would finish without seeing it (its newest snapshot and its
//    render clock have both passed that moment). Until then the Orderly holds its reach. A seen report
//    arriving meanwhile cancels it. After CATCH_CONFIRM_MAX the catch completes regardless.
//
// Inputs: the latest by sequence number wins; older ones still deliver their acknowledgements and
// seen reports. Bodies are the clients' own (no policing), except that a jump faster than
// MAX_PLAYER_SPEED is refused (the allowance grows until the next input fits), bodies are ignored
// until the client acknowledges a placement the run made (rides, push-outs, joining), and inputs from
// players who are caught, left behind or gone are not given to the run.
//
// Events are numbered and kept; each snapshot carries the events after the ones its client has
// acknowledged (up to EVENT_BUDGET bytes), so they arrive exactly once and in order.

import { GRACE, ORDERLY_RADIUS, type OrderlyEvent, type OrderlyState } from '../sim/entity';
import { isWalkable } from '../sim/floor';
import { createInstrument, member } from '../sim/instrument';
import { wallClearance, type Body } from '../sim/move';
import { carBody, createRun, rectDistance, stepRun, type PlayerInput, type RunEvent, type RunPlayer, type RunState, type RunStep } from '../sim/run';
import { emptyTape } from '../sim/tape';
import {
  decode,
  encode,
  lerpPose,
  orderlySnap,
  poseBody,
  qBody,
  snapshotText,
  worldJson,
  type InputMsg,
  type OrderlySnap,
  type PeerId,
  type Placement,
  type Pose,
  type SeenReport,
  type TapeSnap,
  type WorldSnap,
} from './protocol';
import {
  CATCH_CONFIRM_MAX,
  EVENT_BUDGET,
  HISTORY_SECONDS,
  JUMP_SLACK,
  MAX_PLAYER_SPEED,
  PUT_BACK_MAX,
  SEEING_TIMEOUT,
  TICK,
} from './session';
import type { Transport } from './transport';

const EPS = 1e-9;
const HISTORY_TICKS = Math.ceil(HISTORY_SECONDS / TICK);
/** Run states kept for inspection (tests compare clients against the host at a given tick). */
const STATE_TICKS = 200;

export interface HostOptions {
  transport: Transport;
  seed: string;
  /** Players in the run from the first tick (their peer ids). */
  roster: readonly string[];
  /** Host clock at the start, seconds. Tick k is due at now + k * TICK. */
  now: number;
  /** Tests: adjust the run before the first tick. */
  prepare?: (s: RunState) => RunState;
  /**
   * Steps the run one tick (default stepRun). The game passes its own wrapper for rules the logic
   * does not have yet (see game/runHost.ts); it must call stepRun and keep its contract.
   */
  step?: (s: RunState, inputs: readonly PlayerInput[], dt: number) => RunStep;
  /**
   * Players whose bodies are taken as sent, with no speed check: the host's own player, whose
   * machine is this one (a teleport by the game or a test is not a cheat).
   */
  trusted?: readonly string[];
}

interface HostPlayer {
  id: string;
  peer: PeerId;
  connected: boolean;
  left: boolean;
  /** In the run's player list (else a spectator waiting for the next stop). */
  inRun: boolean;
  joined: boolean;
  lastSeq: number;
  input: InputMsg | null;
  /** Host time the latest input arrived. */
  inputAt: number;
  echo: [number, number] | null;
  body: Body | null;
  bodyCt: number | null;
  calls: number;
  callPending: boolean;
  pickUps: number;
  pickPending: boolean;
  ackEvent: number;
  ackHt: number;
  renderTime: number;
  place: Placement | null;
  placeAck: number;
  seenDone: Set<number>;
  ackSeen: number;
}

interface History {
  o: OrderlyState;
  pose: OrderlySnap;
}

export interface LoggedEvent {
  seq: number;
  tick: number;
  e: RunEvent;
}

export interface HostStats {
  ticks: number;
  reports: number;
  putBacks: number;
  maxPutBack: number;
  putBackDistances: number[];
  /** Reports beyond PUT_BACK_MAX: not moved. */
  boundViolations: number;
  maxViolationGap: number;
  /** Reports about a moment older than the history, or another floor. */
  staleReports: number;
  /** Reports about a moment before a catch: not put back across it. */
  afterCatch: number;
  windUpsCancelledByReport: number;
  catchHoldTicks: number;
  catchesForced: number;
  clampedInputs: number;
  snapshots: number;
  snapshotBytes: number;
  maxSnapshotBytes: number;
}

export class NetHost {
  state: RunState;
  tick = 0;
  ended = false;
  readonly seed: string;
  readonly log: LoggedEvent[] = [];
  readonly stats: HostStats = {
    ticks: 0,
    reports: 0,
    putBacks: 0,
    maxPutBack: 0,
    putBackDistances: [],
    boundViolations: 0,
    maxViolationGap: 0,
    staleReports: 0,
    afterCatch: 0,
    windUpsCancelledByReport: 0,
    catchHoldTicks: 0,
    catchesForced: 0,
    clampedInputs: 0,
    snapshots: 0,
    snapshotBytes: 0,
    maxSnapshotBytes: 0,
  };
  /** Every snapshot's size in bytes, by number of players in the run (tests read the bound). */
  readonly snapshotSizes: { players: number; bytes: number }[] = [];
  private readonly transport: Transport;
  private readonly startLocal: number;
  private readonly players = new Map<string, HostPlayer>();
  private readonly byPeer = new Map<PeerId, string>();
  private readonly hist = new Map<number, History>();
  private readonly states = new Map<number, RunState>();
  private readonly queue: { player: string; r: SeenReport }[] = [];
  private readonly rosterIds: Set<string>;
  private pendingCatch: { victim: string; armedAt: number; armedHost: number } | null = null;
  private lastCatchTick = -1;
  private nextId = 1;
  private readonly stepFn: (s: RunState, inputs: readonly PlayerInput[], dt: number) => RunStep;
  private readonly trusted: Set<string>;

  constructor(opts: HostOptions) {
    this.transport = opts.transport;
    this.seed = opts.seed;
    this.startLocal = opts.now;
    this.rosterIds = new Set(opts.roster);
    this.stepFn = opts.step ?? stepRun;
    this.trusted = new Set(opts.trusted ?? []);
    let s = createRun(opts.seed, opts.roster);
    if (opts.prepare) s = opts.prepare(s);
    this.state = s;
    for (const id of opts.roster) {
      const rp = s.players.find((p) => p.id === id);
      const hp = this.newPlayer(id, id, true);
      if (rp) {
        hp.body = rp.body;
        // A trusted player's page stands its own player where the run starts it (it is this page).
        if (!this.trusted.has(id)) hp.place = { seq: 1, depth: s.depth, body: qBody(rp.body) };
      }
      this.players.set(id, hp);
      this.byPeer.set(id, id);
    }
    this.record();
  }

  private newPlayer(id: string, peer: PeerId, inRun: boolean): HostPlayer {
    return {
      id,
      peer,
      connected: false,
      left: false,
      inRun,
      joined: false,
      lastSeq: 0,
      input: null,
      inputAt: -Infinity,
      echo: null,
      body: null,
      bodyCt: null,
      calls: 0,
      callPending: false,
      pickUps: 0,
      pickPending: false,
      ackEvent: 0,
      ackHt: -Infinity,
      renderTime: -Infinity,
      place: null,
      placeAck: 0,
      seenDone: new Set(),
      ackSeen: 0,
    };
  }

  /** Host time (the run's clock) at host-local time `now`. */
  hostTime(now: number): number {
    return now - this.startLocal;
  }

  /** Host-local time the next tick is due. */
  nextTickAt(): number {
    return this.startLocal + (this.tick + 1) * TICK;
  }

  /** The run as it was after tick `k` (recent ticks only). */
  stateAt(k: number): RunState | undefined {
    return this.states.get(k);
  }

  /** Players the host knows (ids), with whether they are connected, in the run, and gone. */
  roster(): { id: string; connected: boolean; inRun: boolean; left: boolean }[] {
    return [...this.players.values()].map((p) => ({ id: p.id, connected: p.connected, inRun: p.inRun, left: p.left }));
  }

  /** Receives, then runs every tick that is due by `now` (host-local clock). */
  update(now: number): void {
    if (this.ended) return;
    for (const pe of this.transport.peerEvents()) {
      if (pe.kind === 'left') this.leave(pe.peer);
    }
    for (const m of this.transport.receive()) this.onMessage(m.from, m.data, now);
    while (this.nextTickAt() <= now + 1e-9) this.step(now);
  }

  /**
   * Applies the seen reports that have arrived since the last tick now, between ticks, instead of
   * waiting for the next one. The game calls it after every frame on the host's machine, so a
   * glance by the host's own player puts the Orderly back on the same frame, as the single-player
   * game always did. Remote reports go through it too: earlier is never worse for the rule.
   */
  flushReports(now: number): void {
    if (this.ended) return;
    for (const m of this.transport.receive()) this.onMessage(m.from, m.data, now);
    if (this.queue.length === 0) return;
    const extra: RunEvent[] = [];
    let s = this.state;
    for (const q of this.queue.splice(0)) s = this.applyReport(s, q.player, q.r, extra, s.t);
    this.state = s;
    this.states.set(this.tick, s);
    for (const e of extra) this.log.push({ seq: this.log.length + 1, tick: this.tick, e: JSON.parse(JSON.stringify(e)) as RunEvent });
  }

  /**
   * Replaces the Orderly outright (the game's test hooks: place it, wake it, rest it). The history
   * is rewritten to the new state, so a seen report about an earlier moment puts it back here and
   * never to where it stood before, nor to an earlier mode.
   */
  replaceOrderly(o: OrderlyState): void {
    this.state = { ...this.state, orderly: o };
    const h: History = { o, pose: orderlySnap(o) };
    for (const k of this.hist.keys()) this.hist.set(k, h);
    this.hist.set(this.tick, h);
    this.states.set(this.tick, this.state);
  }

  /**
   * Changes the run outside a tick (the host's own page: a pick-up pressed while a test has the
   * clock stopped). The events are logged and reach every client with the next snapshot.
   */
  act(f: (s: RunState) => RunStep): void {
    const r = f(this.state);
    this.state = r.state;
    this.states.set(this.tick, r.state);
    for (const e of r.events) this.log.push({ seq: this.log.length + 1, tick: this.tick, e: JSON.parse(JSON.stringify(e)) as RunEvent });
  }

  /** Moves a player (the host's decision, like a ride): the client adopts it and acknowledges it. */
  placePlayer(id: string, body: Body): void {
    this.place(id, body, this.state.depth);
    this.state = { ...this.state, players: this.state.players.map((p) => (p.id === id ? { ...p, body } : p)) };
  }

  /** Ends the session (the host leaving): every client is told by its transport. */
  close(): void {
    this.ended = true;
    this.transport.close();
  }

  // -------------------------------------------------------------------------------------------
  // Receiving.

  private onMessage(from: PeerId, data: string, now: number): void {
    const m = decode(data);
    if (!m) return;
    const ht = this.hostTime(now);
    switch (m.type) {
      case 'join':
        this.join(from);
        return;
      case 'leave':
        this.leave(from);
        return;
      case 'ping':
        this.transport.send(from, encode({ type: 'pong', ct: m.ct, hr: ht, st: ht }));
        return;
      case 'input': {
        const id = this.byPeer.get(from);
        const p = id ? this.players.get(id) : undefined;
        if (p && p.connected && !p.left) this.onInput(p, m, ht);
        return;
      }
      default:
        return;
    }
  }

  /** A join (or a repeated one, when the welcome was lost): the welcome carries the whole state. */
  private join(peer: PeerId): void {
    let id = this.byPeer.get(peer);
    let p = id ? this.players.get(id) : undefined;
    if (p && p.left) return; // no rejoining under the same peer (known limit)
    if (!p) {
      id = this.rosterIds.has(peer) || !this.players.has(peer) ? peer : `p${this.nextId++}`;
      p = this.newPlayer(id, peer, false);
      this.players.set(id, p);
      this.byPeer.set(peer, id);
      // A spectator from the first event after now; the welcome carries the state.
      p.ackEvent = this.log.length;
    }
    p.connected = true;
    p.joined = true;
    const evFrom = p.ackEvent + 1;
    this.transport.send(peer, encode({ type: 'welcome', you: p.id, seed: this.seed, playing: p.inRun, evFrom, world: this.world() }));
  }

  private leave(peer: PeerId): void {
    const id = this.byPeer.get(peer);
    const p = id ? this.players.get(id) : undefined;
    if (!p || p.left) return;
    p.left = true;
    p.connected = false;
    p.input = null;
    if (this.pendingCatch?.victim === p.id) this.pendingCatch = null;
  }

  private onInput(p: HostPlayer, m: InputMsg, ht: number): void {
    p.ackEvent = Math.max(p.ackEvent, Math.min(m.ackEvent, this.log.length));
    p.ackHt = Math.max(p.ackHt, m.ackHt);
    p.renderTime = Math.max(p.renderTime, m.renderTime);
    if (p.place && m.placeAck >= p.place.seq) p.placeAck = Math.max(p.placeAck, m.placeAck);
    for (const r of m.seen) {
      if (p.seenDone.has(r.id)) continue;
      p.seenDone.add(r.id);
      this.queue.push({ player: p.id, r });
    }
    while (p.seenDone.has(p.ackSeen + 1)) p.ackSeen++;
    if (m.seq <= p.lastSeq) return;
    p.lastSeq = m.seq;
    p.input = m;
    p.inputAt = ht;
    p.echo = [m.ct, ht];
    if (m.calls > p.calls) {
      p.calls = m.calls;
      p.callPending = true;
    }
    if (m.pickUps > p.pickUps) {
      p.pickUps = m.pickUps;
      p.pickPending = true;
    }
    // The body: not until the client has the latest placement; never an impossible jump.
    if (p.place && m.placeAck < p.place.seq) return;
    if (p.body && p.bodyCt !== null && !this.trusted.has(p.id)) {
      const dt = Math.max(0, m.ct - p.bodyCt);
      const jump = Math.hypot(m.body.x - p.body.x, m.body.z - p.body.z, m.body.y - p.body.y);
      if (jump > MAX_PLAYER_SPEED * dt + JUMP_SLACK) {
        this.stats.clampedInputs++;
        return;
      }
    }
    p.body = m.body;
    p.bodyCt = m.ct;
  }

  // -------------------------------------------------------------------------------------------
  // The tick.

  private runPlayer(id: string): RunPlayer | undefined {
    return this.state.players.find((q) => q.id === id);
  }

  private playing(p: HostPlayer): boolean {
    return p.inRun && p.connected && !p.left && p.input !== null && this.runPlayer(p.id)?.status === 'ok';
  }

  private step(now: number): void {
    const ht = this.hostTime(now);
    const extra: RunEvent[] = [];
    let s = this.state;
    const tNext = s.t + TICK;

    // 1. What the clients saw.
    for (const q of this.queue.splice(0)) s = this.applyReport(s, q.player, q.r, extra, tNext);

    // 2. Anyone saying they can see it now: held, and a wind-up is off.
    const seeing = [...this.players.values()].some((p) => this.playing(p) && p.input?.seeing === true && ht - p.inputAt <= SEEING_TIMEOUT);
    if (seeing) s = this.hold(s, true, extra, tNext, null);

    // 3. A catch waits for its victim's screen.
    s = this.confirmCatch(s, ht);

    // 4. Inputs.
    const inputs: PlayerInput[] = [];
    for (const rp of s.players) {
      const p = this.players.get(rp.id);
      if (!p || !this.playing(p) || !p.input) continue;
      const m = p.input;
      inputs.push({
        id: p.id,
        body: p.body ?? rp.body,
        eye: m.eye,
        yaw: m.yaw,
        pitch: m.pitch,
        hFovDeg: m.hFovDeg,
        vFovDeg: m.vFovDeg,
        raised: m.raised,
        holdDoors: m.holdDoors,
        call: p.callPending || undefined,
        pickUp: p.pickPending ? true : undefined,
      });
      p.callPending = false;
      p.pickPending = false;
    }

    // 5. The run.
    const r = this.stepFn(s, inputs, TICK);
    let state = r.state;
    const events = [...extra, ...r.events];

    // 6. After: placements, the gone, joiners.
    for (const e of r.events) {
      if (e.type === 'doorsClosed') for (const [id, b] of Object.entries(e.pushedOut)) this.place(id, b, state.depth);
      if (e.type === 'rodeDown') for (const [id, b] of Object.entries(e.bodies)) this.place(id, b, state.depth);
      if (e.type === 'caught') {
        this.lastCatchTick = this.tick + 1;
        if (this.pendingCatch?.victim === e.playerId) this.pendingCatch = null;
      }
      if (e.type === 'windUpCancelled' && this.pendingCatch?.victim === e.playerId) this.pendingCatch = null;
    }
    if (state.orderly.mode !== 'windUp') this.pendingCatch = null;
    const gone = new Set([...this.players.values()].filter((p) => p.inRun && p.left).map((p) => p.id));
    if (gone.size > 0 && state.phase !== 'ended') {
      state = { ...state, players: state.players.map((p): RunPlayer => (gone.has(p.id) && p.status === 'ok' ? { ...p, status: 'leftBehind', side: null } : p)) };
    }
    if (state.phase === 'arriving') state = this.admit(state);
    this.state = state;
    this.tick++;
    this.stats.ticks++;
    for (const e of events) this.log.push({ seq: this.log.length + 1, tick: this.tick, e: JSON.parse(JSON.stringify(e)) as RunEvent });
    this.record();
    this.sendSnapshots(ht);
  }

  private record(): void {
    const s = this.state;
    this.hist.set(this.tick, { o: s.orderly, pose: orderlySnap(s.orderly) });
    this.hist.delete(this.tick - HISTORY_TICKS);
    this.states.set(this.tick, s);
    this.states.delete(this.tick - STATE_TICKS);
  }

  private place(id: string, body: Body, depth: number): void {
    const p = this.players.get(id);
    if (!p) return;
    p.place = { seq: (p.place?.seq ?? 0) + 1, depth, body: qBody(body) };
    p.body = body;
    p.bodyCt = null;
  }

  /** Spectators waiting for the next stop join the run now (the car is here, doors shut, crew inside). */
  private admit(s: RunState): RunState {
    const waiting = [...this.players.values()].filter((p) => !p.inRun && p.connected && !p.left);
    if (waiting.length === 0) return s;
    let players = [...s.players];
    let crew = s.crew;
    for (const p of waiting) {
      const k = players.length;
      const body = carBody(s.car, 0.6 + 0.4 * (Math.floor(k / 2) % 3), k % 2 ? 0.55 : -0.55);
      players = [...players, { id: p.id, body, status: 'ok', aboard: true, side: null }];
      crew = {
        ...crew,
        members: [...crew.members, { id: p.id, body: null, active: true, instrument: createInstrument(), tape: emptyTape(`tape-${crew.nextTape}`, p.id), carrying: [] }],
        nextTape: crew.nextTape + 1,
      };
      p.inRun = true;
      this.place(p.id, body, s.depth);
    }
    return { ...s, players, crew };
  }

  // -------------------------------------------------------------------------------------------
  // Holding the Orderly.

  /**
   * Treats the Orderly as seen this tick. `full`: with the usual grace after (as if a player saw it);
   * otherwise only for this tick. A full hold also cancels a wind-up: looking always saves you.
   */
  private hold(s: RunState, full: boolean, extra: RunEvent[], t: number, cause: string | null): RunState {
    let o = s.orderly;
    const last = full ? o.t : o.t - GRACE + TICK / 2;
    if (o.lastSeenAt === null || o.lastSeenAt < last) o = { ...o, lastSeenAt: last };
    if (full && o.mode === 'windUp') {
      extra.push({ type: 'windUpCancelled', t, playerId: o.windUpTarget ?? '' } satisfies OrderlyEvent);
      if (cause) this.stats.windUpsCancelledByReport++;
      o = { ...o, mode: 'hunting', windUpTarget: null, windUpLeft: 0, replanIn: 0 };
      this.pendingCatch = null;
    }
    return o === s.orderly ? s : { ...s, orderly: o };
  }

  private confirmCatch(s: RunState, ht: number): RunState {
    const o = s.orderly;
    if (o.mode !== 'windUp' || o.windUpLeft - TICK > EPS || !o.windUpTarget) return s;
    // Already held this tick by grace: it will not complete now anyway.
    if (o.lastSeenAt !== null && o.t - o.lastSeenAt < GRACE - EPS) return s;
    const victim = o.windUpTarget;
    if (!this.pendingCatch || this.pendingCatch.victim !== victim) this.pendingCatch = { victim, armedAt: s.t + TICK, armedHost: ht };
    const pc = this.pendingCatch;
    const p = this.players.get(victim);
    const gone = !p || !p.connected || p.left;
    const shown = p !== undefined && p.ackHt >= pc.armedAt - 1e-6 && p.renderTime >= pc.armedAt - 1e-6;
    if (gone || shown) return s;
    if (ht - pc.armedHost >= CATCH_CONFIRM_MAX) {
      this.stats.catchesForced++;
      return s;
    }
    this.stats.catchHoldTicks++;
    return this.hold(s, false, [], s.t + TICK, null);
  }

  private applyReport(s: RunState, playerId: string, r: SeenReport, extra: RunEvent[], t: number): RunState {
    const p = this.players.get(playerId);
    if (!p || !this.playing(p)) return s;
    this.stats.reports++;
    if (r.depth !== s.depth) {
      this.stats.staleReports++;
      return s;
    }
    const held = (): RunState => this.hold(s, true, extra, t, 'report');
    const ha = this.hist.get(r.a);
    const hb = this.hist.get(r.b) ?? ha;
    if (!ha || !hb) {
      this.stats.staleReports++;
      return held();
    }
    const expected = lerpPose(ha.pose, hb.pose, r.alpha);
    let target: Pose = closePose(expected, r.pose) ? r.pose : expected;
    const o = s.orderly;
    const gap = Math.hypot(o.body.x - target.x, o.body.z - target.z, o.body.y - target.y);
    if (gap <= 1e-6 && o.body.level === target.level && Math.abs(o.yaw - target.yaw) < 1e-3) return held();
    // The client froze on the host's own pose as sent (to the centimetre): nothing to put back. Moving
    // the logic onto the rounded pose would shift a figure in plain view by up to half a centimetre.
    const sent = orderlySnap(o);
    if (sent.x === target.x && sent.y === target.y && sent.z === target.z && sent.level === target.level && sent.yaw === target.yaw) return held();
    if (gap > PUT_BACK_MAX) {
      this.stats.boundViolations++;
      this.stats.maxViolationGap = Math.max(this.stats.maxViolationGap, gap);
      return held();
    }
    if (this.lastCatchTick > r.a) {
      this.stats.afterCatch++;
      return held();
    }
    const base = (r.alpha < 0.5 ? ha : hb).o;
    // Never back into a wall or the car: blends across a missing snapshot can cut a corner.
    if (!this.validSpot(s, poseBody(target))) target = { ...base.body, yaw: base.yaw, anim: base.anim, animTime: base.animTime };
    const wasWinding = o.mode === 'windUp';
    const mode = base.mode === 'windUp' ? 'hunting' : base.mode;
    const restored: OrderlyState = {
      ...base,
      t: o.t,
      body: poseBody(target),
      yaw: target.yaw,
      anim: target.anim,
      animTime: target.animTime,
      mode,
      windUpTarget: null,
      windUpLeft: 0,
      seen: true,
      held: true,
      frozen: mode === 'hunting',
      moving: false,
      speed: 0,
      everSeen: true,
      lastSeenAt: o.t,
      replanIn: 0,
      dormantLeft: mode === 'dormant' ? base.dormantLeft : 0,
    };
    // The put-back freezes it outright, so the tick will not see the change: report it here.
    if (restored.frozen && !o.frozen) extra.push({ type: 'froze', t, playerId: playerId } satisfies OrderlyEvent);
    if (wasWinding) {
      extra.push({ type: 'windUpCancelled', t, playerId: o.windUpTarget ?? '' });
      this.stats.windUpsCancelledByReport++;
      this.pendingCatch = null;
    }
    this.stats.putBacks++;
    this.stats.maxPutBack = Math.max(this.stats.maxPutBack, gap);
    this.stats.putBackDistances.push(gap);
    // Rewrite the history: from that moment it stood there.
    const pose = orderlySnap(restored);
    for (const k of this.hist.keys()) if (k > r.a) this.hist.set(k, { o: restored, pose });
    return { ...s, orderly: restored };
  }

  private validSpot(s: RunState, b: Body): boolean {
    const plan = s.plan;
    if (b.level === s.car.level && rectDistance(s.car.rect, b.x, b.z) < ORDERLY_RADIUS) return false;
    if (!isWalkable(plan, b.level, Math.floor(b.x / plan.cellSize), Math.floor(b.z / plan.cellSize))) return false;
    return wallClearance(plan, b.level, b.x, b.z) >= ORDERLY_RADIUS - 0.02;
  }

  // -------------------------------------------------------------------------------------------
  // Sending.

  /** The shared part of a snapshot (also the welcome's state). */
  world(): WorldSnap {
    const s = this.state;
    const tape = (t: { id: string; ownerId: string; readings: readonly unknown[]; total: number }): TapeSnap => ({ id: t.id, owner: t.ownerId, readings: t.readings.length, total: t.total });
    return {
      tick: this.tick,
      ht: s.t,
      phase: s.phase,
      depth: s.depth,
      timer: s.timer,
      floorsAway: s.call ? s.call.floorsAway : null,
      bellLeft: s.bellLeft,
      holdLeft: s.holdLeft,
      held: s.held,
      blink: s.blink ? { at: s.blink.at, announced: s.blink.announced, endsAt: s.blink.endsAt } : null,
      orderly: orderlySnap(s.orderly),
      players: s.players.map((rp) => {
        const p = this.players.get(rp.id);
        const m = p?.input;
        return {
          id: rp.id,
          body: rp.body,
          yaw: m?.yaw ?? 0,
          pitch: m?.pitch ?? 0,
          active: p !== undefined && this.playing(p),
          status: rp.status,
          aboard: rp.aboard,
          side: rp.side,
          connected: p?.connected === true,
        };
      }),
      crew: s.crew.members.map((m) => ({
        id: m.id,
        needle: m.instrument.needle,
        raised: m.instrument.raised,
        open: m.instrument.current?.value ?? 0,
        rate: m.instrument.rate,
        tickHz: m.instrument.tickHz,
        tape: tape(m.tape),
        carrying: m.carrying.map(tape),
      })),
      floor: s.crew.floor.map((f) => ({ ...tape(f.tape), at: f.at })),
      summary: s.summary,
    };
  }

  private sendSnapshots(ht: number): void {
    const w = this.world();
    const text = worldJson(w);
    const inRun = this.state.players.length;
    for (const p of this.players.values()) {
      if (!p.connected || p.left || !p.joined) continue;
      const events: RunEvent[] = [];
      let bytes = 0;
      for (let i = p.ackEvent; i < this.log.length; i++) {
        const e = (this.log[i] as LoggedEvent).e;
        const b = JSON.stringify(e).length + 1;
        if (events.length > 0 && bytes + b > EVENT_BUDGET) break;
        events.push(e);
        bytes += b;
      }
      const place = p.place && p.place.seq > p.placeAck ? p.place : null;
      const data = snapshotText(
        { st: ht, ackIn: p.lastSeq, echo: p.echo ? [p.echo[0], ht - p.echo[1]] : null, ackSeen: p.ackSeen, evFrom: p.ackEvent + 1, events, place },
        text,
      );
      this.transport.send(p.peer, data);
      this.stats.snapshots++;
      this.stats.snapshotBytes += data.length;
      this.stats.maxSnapshotBytes = Math.max(this.stats.maxSnapshotBytes, data.length);
      this.snapshotSizes.push({ players: inRun, bytes: data.length });
    }
  }

  /** A member's tapes as the host has them (tests). */
  tapesOf(id: string): string[] {
    const m = member(this.state.crew, id);
    return m ? [m.tape, ...m.carrying].map((t) => `${t.id}:${t.readings.length}:${t.total.toFixed(2)}`) : [];
  }
}

function closePose(a: Pose, b: Pose): boolean {
  return a.level === b.level && Math.hypot(a.x - b.x, a.y - b.y, a.z - b.z) <= 0.05;
}

