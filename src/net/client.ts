// A player's machine. It owns that player's body and camera (moved locally, so walking feels
// instant), sends the host its body, view and intents about 20 times a second, and draws everyone
// else and the Orderly from the host's snapshots, INTERP_DELAY behind the newest it could have.
//
// The Orderly is never seen to move on this screen. Every frame (frame()):
//  1. The drawn Orderly is checked against the real camera where it is DRAWN, with the logic's own
//     generous sight test (session.ts cameraSees).
//  2. While the local player can see the drawn figure, the drawing is frozen: same pose, animation
//     clock stopped, whatever snapshots say. The moment it is first seen the client sends the host a
//     seen report at once (not waiting for the 20 Hz slot): the exact pose it froze on and the two
//     snapshots it was blended from. Reports repeat in every input until the host acknowledges them.
//  3. It only goes back to following snapshots on a frame where neither the frozen pose nor the
//     snapshots' pose can be seen, so the jump between the two (if any) is never on screen.
// Consequence: a pose can change between two frames only if at least one of them did not show it.
//
// Blinks: the host announces each blink (its start in host time) in the snapshot's blink schedule.
// The screen is dark (a) while the estimated host clock is within the blink's blind window widened by
// the clock's error bound (half the best recent round trip) plus a tick, and (b) while the snapshots
// being drawn come from inside the blind window, so the movement a blink allows is never drawn lit.
//
// The local body is never taken from snapshots, except when the host moves the player (start,
// rides, being pushed out of the car, joining): those come as a numbered placement, applied here
// once and acknowledged in every input; the host ignores bodies until it is acknowledged.

import type { Body } from '../sim/move';
import { BLINK_TIME, BLINK_WARNING, type RunEvent } from '../sim/run';
import {
  decode,
  encode,
  lerpPose,
  q3,
  samePose,
  type InputMsg,
  type MemberSnap,
  type PeerId,
  type Placement,
  type Pose,
  type SeenReport,
  type SnapPlayer,
  type WorldSnap,
} from './protocol';
import { cameraSees, doorsOpenIn, HostClock, INPUT_INTERVAL, INTERP_DELAY, planFor, TICK, type Camera } from './session';
import type { Transport } from './transport';

/** What the game hands the client each frame: the camera, and the player's intents. */
export interface LocalFrame extends Camera {
  raised?: boolean;
  holdDoors?: boolean;
  /** The call button was pressed this frame. */
  call?: boolean;
  /** The pick-up key was pressed this frame. */
  pickUp?: boolean;
}

export interface DrawnPlayer {
  id: string;
  body: Body;
  yaw: number;
  pitch: number;
  active: boolean;
  status: SnapPlayer['status'];
}

export interface Frame {
  /** Screen dark for a blink. */
  dark: boolean;
  /** The Orderly to draw (the same object for as long as it is held), or null. */
  orderly: Pose | null;
  /** The drawing is frozen (seen, or held until a jump can happen out of view). */
  held: boolean;
  /** The local player sees the drawn Orderly on this frame. */
  seeing: boolean;
  /** Depth of the floor drawn. */
  depth: number;
  players: DrawnPlayer[];
  /** Host time of the state being drawn (-1 before the first). */
  renderTime: number;
  /** The host moved the local player: adopt this body. */
  placed: Body | null;
}

export interface ClientStats {
  frames: number;
  darkFrames: number;
  /** Frames dark only because of the guards (not blind at the estimated host time itself). */
  guardDarkFrames: number;
  reports: number;
  inputs: number;
  inputBytes: number;
  maxInputBytes: number;
  snapshots: number;
  /** Largest jump between a held pose and the pose drawn on the frame it was let go (never on screen). */
  maxReleaseJump: number;
  releases: number;
  /** Releases with a jump over 0.25 m. */
  bigReleases: number;
}

/** A state as stored for drawing; snapshots also carry how far the host had got with our reports. */
type Shown = WorldSnap & { ackSeen?: number };

interface KnownBlink {
  at: number;
  announced: boolean;
}

/** Per-client tuning. The host's own player, on a perfect in-page link, uses tighter values. */
export interface ClientOptions {
  /** How far behind the newest snapshot to draw, seconds (default INTERP_DELAY). */
  interpDelay?: number;
  /** Seconds between inputs (default INPUT_INTERVAL; 0 sends one every frame). */
  inputInterval?: number;
}

const LAG_WINDOW = 60;
const SNAP_KEEP = 3;

export class NetClient {
  /** Assigned by the host's welcome. */
  id: string | null = null;
  seed: string | null = null;
  /** In the run (otherwise watching until the next elevator stop). */
  playing = false;
  /** The host is gone: the session is over. */
  ended = false;
  /** The newest snapshot (or the welcome's state): phase, depth, crew, tapes, summary. */
  latest: WorldSnap | null = null;
  /** Every event in host order, each exactly once. */
  readonly events: RunEvent[] = [];
  /** Depth of the floor the local player is on. */
  localDepth = 1;
  /** Sequence number of this client's first event (1 unless it joined a run in progress). */
  firstEvent = 1;
  readonly clock = new HostClock();
  readonly stats: ClientStats = { frames: 0, darkFrames: 0, guardDarkFrames: 0, reports: 0, inputs: 0, inputBytes: 0, maxInputBytes: 0, snapshots: 0, maxReleaseJump: 0, releases: 0, bigReleases: 0 };
  /** Every input's size in bytes (tests read the bound). */
  readonly inputSizes: number[] = [];

  private evNext = 1;
  private readonly evBuf = new Map<number, RunEvent>();
  private snaps: Shown[] = [];
  private pin: { pose: Pose; id: number; depth: number } | null = null;
  private readonly lags: number[] = [];
  private rt: number | null = null;
  private rtLocal = 0;
  private drawn: Pose | null = null;
  private drawnDepth = -1;
  private frozen = false;
  private reportId = 0;
  private unacked: SeenReport[] = [];
  private seq = 0;
  private lastSend = -Infinity;
  private seeingLatch = false;
  private calls = 0;
  private pickUps = 0;
  private ackHt = -Infinity;
  private placeApplied = 0;
  private pendingPlace: Placement | null = null;
  private readonly blinks = new Map<number, KnownBlink>();
  private lastJoin = -Infinity;
  private readonly interpDelay: number;
  private readonly inputInterval: number;

  constructor(
    private readonly transport: Transport,
    readonly hostId: PeerId,
    readonly name: string,
    now: number,
    opts: ClientOptions = {},
  ) {
    this.interpDelay = opts.interpDelay ?? INTERP_DELAY;
    this.inputInterval = opts.inputInterval ?? INPUT_INTERVAL;
    this.sendJoin(now);
  }

  private sendJoin(now: number): void {
    this.lastJoin = now;
    this.transport.send(this.hostId, encode({ type: 'join', name: this.name, ct: now }));
  }

  /** Leaves the session. */
  leave(): void {
    this.transport.send(this.hostId, encode({ type: 'leave' }));
    this.transport.close();
    this.ended = true;
  }

  /** The local player's instrument and tapes, from the newest snapshot. */
  me(): MemberSnap | undefined {
    return this.latest?.crew.find((m) => m.id === this.id);
  }

  /** Blink starts the client knows of (host time). */
  knownBlinks(): number[] {
    return [...this.blinks.keys()].sort((a, b) => a - b);
  }

  /**
   * When the screen goes dark for each known blink, in LOCAL time, by the clock alone: the host's
   * blind window widened by a tick and by the clock's error bound. (frame() also stays dark while
   * the states being drawn come from inside a blind window, which can run a little longer.)
   */
  blinkWindows(): { start: number; end: number }[] {
    const guard = this.clock.errorBound + 0.01;
    const off = this.clock.offset;
    return this.knownBlinks().map((at) => ({ start: at - TICK - guard - off, end: at + BLINK_TIME + TICK + guard - off }));
  }

  // -------------------------------------------------------------------------------------------
  // Receiving.

  /** Takes in everything that has arrived (call whenever; `now` is the local clock). */
  receive(now: number): void {
    for (const pe of this.transport.peerEvents()) if (pe.kind === 'left' && pe.peer === this.hostId) this.ended = true;
    for (const d of this.transport.receive()) {
      if (d.from !== this.hostId) continue;
      const m = decode(d.data);
      if (!m) continue;
      if (m.type === 'welcome') {
        if (this.id !== null) continue;
        this.id = m.you;
        this.seed = m.seed;
        this.playing = m.playing;
        this.evNext = m.evFrom;
        this.firstEvent = m.evFrom;
        this.latest = m.world;
        this.localDepth = m.world.depth;
        this.insert(m.world);
        this.learnBlink(m.world);
      } else if (m.type === 'snap') {
        if (this.id === null) continue;
        this.stats.snapshots++;
        if (m.echo) this.clock.sample(m.echo[0], m.echo[1], m.st, now);
        this.lags.push(now - m.st);
        if (this.lags.length > LAG_WINDOW) this.lags.shift();
        this.ackHt = Math.max(this.ackHt, m.ht);
        m.events.forEach((e, i) => {
          const n = m.evFrom + i;
          if (n >= this.evNext && !this.evBuf.has(n)) this.evBuf.set(n, e);
        });
        while (this.evBuf.has(this.evNext)) {
          this.events.push(this.evBuf.get(this.evNext) as RunEvent);
          this.evBuf.delete(this.evNext);
          this.evNext++;
        }
        this.unacked = this.unacked.filter((r) => r.id > m.ackSeen);
        if (m.place && m.place.seq > this.placeApplied && (!this.pendingPlace || m.place.seq > this.pendingPlace.seq)) this.pendingPlace = m.place;
        const world: Shown = { ...m };
        this.insert(world);
        if (!this.latest || m.tick > this.latest.tick) {
          this.latest = world;
          if (m.players.some((p) => p.id === this.id)) this.playing = true;
        }
        this.learnBlink(world);
      } else if (m.type === 'pong') {
        this.clock.sample(m.ct, m.st - m.hr, m.st, now);
      }
    }
  }

  private insert(w: Shown): void {
    const s = this.snaps;
    let i = s.length;
    while (i > 0 && (s[i - 1] as Shown).tick > w.tick) i--;
    if (i > 0 && (s[i - 1] as Shown).tick === w.tick) return;
    s.splice(i, 0, w);
    const newest = (s[s.length - 1] as WorldSnap).ht;
    while (s.length > 2 && (s[0] as WorldSnap).ht < newest - SNAP_KEEP) s.shift();
  }

  private learnBlink(w: WorldSnap): void {
    if (w.blink) {
      const k = this.blinks.get(w.blink.at);
      this.blinks.set(w.blink.at, { at: w.blink.at, announced: w.blink.announced || (k?.announced ?? false) });
    }
    // Only the newest state may say a scheduled blink was dropped (the car came first).
    if (this.latest !== w) return;
    for (const b of [...this.blinks.values()]) {
      if (b.at + BLINK_TIME + 10 < w.ht) this.blinks.delete(b.at);
      else if (!b.announced && w.ht >= b.at - BLINK_WARNING + TICK && w.blink?.at !== b.at) this.blinks.delete(b.at);
    }
  }

  // -------------------------------------------------------------------------------------------
  // A frame.

  /**
   * The host time to draw at: INTERP_DELAY behind the newest snapshot this client could have, judged
   * by the fastest recent arrival (local arrival time minus the host's send stamp). Advances with
   * the local clock, slewed by at most 10% toward that target, and never runs backwards (except to
   * recover from being more than a second ahead). Null until a snapshot has arrived.
   */
  private renderTime(now: number): number | null {
    if (this.lags.length === 0) return this.rt;
    let lag = Infinity;
    for (const l of this.lags) lag = Math.min(lag, l);
    const target = now - lag - this.interpDelay;
    if (this.rt === null) {
      this.rt = target;
    } else {
      const dt = Math.max(0, now - this.rtLocal);
      let adv = this.rt + dt;
      const err = target - adv;
      if (err > 0.3) adv = target;
      else if (err < -1) adv = target;
      else if (err < -0.3) adv = this.rt; // ahead: wait for it
      else adv += Math.max(-0.1 * dt, Math.min(0.1 * dt, err));
      this.rt = err < -1 ? adv : Math.max(this.rt, adv);
    }
    this.rtLocal = now;
    return this.rt;
  }

  private bracket(rt: number): { a: Shown; b: Shown; alpha: number } | null {
    const s = this.snaps;
    if (s.length === 0) return null;
    let i = s.length - 1;
    while (i >= 0 && (s[i] as Shown).ht > rt) i--;
    if (i < 0) return { a: s[0] as Shown, b: s[0] as Shown, alpha: 0 };
    const a = s[i] as Shown;
    const b = s[i + 1];
    if (!b || b.depth !== a.depth) return { a, b: a, alpha: 0 };
    return { a, b, alpha: Math.max(0, Math.min(1, (rt - a.ht) / (b.ht - a.ht))) };
  }

  /** Whether a blink makes the screen dark: by the estimated host clock, or by what is being drawn. */
  private isDark(hostNow: number, show: { a: WorldSnap; b: WorldSnap } | null): { dark: boolean; byClockOnly: boolean } {
    const guard = this.clock.errorBound + 0.01; // see blinkWindows()
    let dark = false;
    let real = false;
    for (const k of this.blinks.values()) {
      const lo = k.at - TICK;
      const hi = k.at + BLINK_TIME + TICK;
      if (hostNow >= lo - guard && hostNow <= hi + guard) dark = true;
      if (hostNow >= lo && hostNow <= hi) real = true;
      if (show && show.a.ht <= hi && show.b.ht >= lo) dark = true;
    }
    return { dark, byClockOnly: dark && !real };
  }

  /**
   * One rendered frame at local time `now`: what to draw, and (when due) the input to the host.
   * Call receive() first. If the host placed the local player, `placed` says where: adopt it.
   */
  frame(now: number, local: LocalFrame): Frame {
    this.stats.frames++;
    if (local.call) this.calls++;
    if (local.pickUp) this.pickUps++;
    const empty = (placed: Body | null = null): Frame => ({ dark: false, orderly: null, held: false, seeing: false, depth: this.localDepth, players: [], renderTime: -1, placed });
    if (this.id === null || this.seed === null) {
      if (now - this.lastJoin >= 0.5) this.sendJoin(now);
      return empty();
    }
    let placed: Body | null = null;
    if (this.pendingPlace && this.pendingPlace.seq > this.placeApplied) {
      placed = this.pendingPlace.body;
      this.placeApplied = this.pendingPlace.seq;
      this.localDepth = this.pendingPlace.depth;
      this.pendingPlace = null;
    }
    const cam: Camera = { body: placed ?? local.body, eye: local.eye, yaw: local.yaw, pitch: local.pitch, hFovDeg: local.hFovDeg, vFovDeg: local.vFovDeg };
    const clockRt = this.renderTime(now);
    const show = clockRt === null ? this.bracket(Infinity) : this.bracket(clockRt);
    // The host time of the state actually drawn (behind the clock when snapshots are late).
    const rt = show ? show.a.ht + (show.b.ht - show.a.ht) * show.alpha : -1;
    const hostNow = this.clock.hostTime(now);
    const dk = this.isDark(hostNow, show);
    if (dk.dark) this.stats.darkFrames++;
    if (dk.byClockOnly) this.stats.guardDarkFrames++;

    // The Orderly.
    let seeingNow = false;
    let report: SeenReport | null = null;
    let orderly: Pose | null = null;
    if (show && show.a.depth === this.localDepth) {
      const { a, b, alpha } = show;
      // Pinned: until the snapshots drawn show the host has handled our last report, they are the
      // timeline it is about to abandon (it puts the Orderly back where we froze it), so keep that.
      if (this.pin && (this.pin.depth !== a.depth || (a.ackSeen ?? 0) >= this.pin.id)) this.pin = null;
      const pinned = this.pin !== null;
      const cand = this.pin ? this.pin.pose : lerpPose(a.orderly, b.orderly, alpha);
      const plan = planFor(this.seed, a.depth);
      const open = doorsOpenIn(a.phase) || doorsOpenIn(b.phase) || (this.latest !== null && doorsOpenIn(this.latest.phase));
      const sees = (p: Pose): boolean => !dk.dark && cameraSees(plan, cam, p, open);
      const same = this.drawn !== null && this.drawnDepth === a.depth;
      if (this.frozen && same && sees(this.drawn as Pose)) {
        // Seen: held exactly where it is, whatever the snapshots say.
        seeingNow = true;
      } else if (this.frozen && same && sees(cand)) {
        // The held pose has left the view but the snapshots' pose is in it: keep holding until
        // neither is, so the jump between them never happens on screen.
      } else {
        if (this.frozen && this.drawn) {
          const d = this.drawn;
          this.stats.releases++;
          const jump = Math.hypot(d.x - cand.x, d.y - cand.y, d.z - cand.z);
          this.stats.maxReleaseJump = Math.max(this.stats.maxReleaseJump, jump);
          if (jump > 0.25) this.stats.bigReleases++;
        }
        if (sees(cand)) {
          this.frozen = true;
          seeingNow = true;
          if (!pinned) report = this.makeReport(a, b, alpha, cand);
        } else {
          this.frozen = false;
        }
        if (!this.drawn || !samePose(this.drawn, cand)) this.drawn = cand;
      }
      this.drawnDepth = a.depth;
      orderly = this.drawn;
    } else {
      this.drawn = null;
      this.frozen = false;
    }
    if (seeingNow) this.seeingLatch = true;

    // Everyone else.
    const players: DrawnPlayer[] = [];
    if (show) {
      const { a, b, alpha } = show;
      for (const pa of a.players) {
        if (pa.id === this.id) continue;
        const pb = b.players.find((p) => p.id === pa.id) ?? pa;
        const blend = pa.body.level === pb.body.level;
        const k = blend ? alpha : 0;
        players.push({
          id: pa.id,
          body: {
            x: pa.body.x + (pb.body.x - pa.body.x) * k,
            y: pa.body.y + (pb.body.y - pa.body.y) * k,
            z: pa.body.z + (pb.body.z - pa.body.z) * k,
            level: pa.body.level,
          },
          yaw: pa.yaw + angleDiff(pa.yaw, pb.yaw) * k,
          pitch: pa.pitch + (pb.pitch - pa.pitch) * k,
          active: pa.active,
          status: pa.status,
        });
      }
    }

    // The input: every INPUT_INTERVAL, and at once on a new sighting.
    if (report || now - this.lastSend >= this.inputInterval - 1e-9) this.send(now, cam, local, rt);
    return { dark: dk.dark, orderly, held: this.frozen, seeing: seeingNow, depth: show?.a.depth ?? this.localDepth, players, renderTime: rt, placed };
  }

  private makeReport(a: WorldSnap, b: WorldSnap, alpha: number, pose: Pose): SeenReport {
    const r: SeenReport = { id: ++this.reportId, depth: a.depth, a: a.tick, b: b.tick, alpha: q3(alpha), pose };
    this.unacked.push(r);
    this.pin = { pose, id: r.id, depth: a.depth };
    this.stats.reports++;
    return r;
  }

  private send(now: number, cam: Camera, local: LocalFrame, rt: number): void {
    const m: InputMsg = {
      type: 'input',
      seq: ++this.seq,
      ct: now,
      body: cam.body,
      eye: cam.eye,
      yaw: cam.yaw,
      pitch: cam.pitch,
      hFovDeg: cam.hFovDeg,
      vFovDeg: cam.vFovDeg,
      raised: local.raised === true,
      holdDoors: local.holdDoors === true,
      seeing: this.seeingLatch,
      calls: this.calls,
      pickUps: this.pickUps,
      ackEvent: this.evNext - 1,
      ackHt: Number.isFinite(this.ackHt) ? this.ackHt : -1,
      renderTime: rt,
      placeAck: this.placeApplied,
      seen: this.unacked.slice(-2),
    };
    const text = encode(m);
    this.transport.send(this.hostId, text);
    this.lastSend = now;
    this.seeingLatch = false;
    this.stats.inputs++;
    this.stats.inputBytes += text.length;
    this.stats.maxInputBytes = Math.max(this.stats.maxInputBytes, text.length);
    this.inputSizes.push(text.length);
  }
}

function angleDiff(a: number, b: number): number {
  let d = (b - a) % (2 * Math.PI);
  if (d > Math.PI) d -= 2 * Math.PI;
  if (d < -Math.PI) d += 2 * Math.PI;
  return d;
}
