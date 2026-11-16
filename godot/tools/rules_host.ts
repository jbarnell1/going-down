// The reference host for godot/client/rules_bridge.gd. A copy of spikes/godot-client/tools/rules_host.ts
// (the interim TypeScript host the client used before the GDScript bridge), imports adjusted, the
// page global dropped. It runs the REAL TypeScript rules (src/sim, plus the host's own glue in
// src/game/runHost.ts and the sight test the network client uses, src/net/session.ts cameraSees)
// and answers one JSON request with one JSON reply. dump_reference.ts (job 'bridge') drives it
// through bridge_script.ts; tests/ref_bridge.gd replays the same requests through the GDScript bridge.
//
// Per frame (op 'frame') it does what src/main.ts does for the host's own player:
//   1. the player's body moves by moveInRun (walls, stair, the car's doorway) at the gait the stamina
//      rules allow (src/game/player.ts control, src/sim/stamina.ts), capped while the instrument is up;
//   2. the run is stepped at 20 Hz (src/net/session.ts TICK) through HostRules.step, with this frame's
//      camera as the player's view;
//   3. the Orderly to draw: the last two tick poses blended, held still while this camera could be
//      showing it (the hold of src/net/client.ts frame(), with the same cameraSees test), never drawn
//      in the dark;
//   4. everything the screen and the speakers need comes back in one snapshot.

import { HostRules, startBody } from '../../src/game/runHost';
import { cameraSees, TICK, type Camera } from '../../src/net/session';
import { lerpPose, samePose, type Pose } from '../../src/net/protocol';
import { audibility, REACH_RANGE, WIND_UP_TIME, type OrderlyState } from '../../src/sim/entity';
import { distancesFrom, findPath, type FloorPlan, type Level } from '../../src/sim/floor';
import { pathDone, startPathWalk, stepPathWalk, type PathWalk } from '../../src/sim/follow';
import { maxWalkSpeed, member, setRaised, tapeValue } from '../../src/sim/instrument';
import { elevatorWall, landingFacing } from '../../src/sim/landing';
import { bodyAtCell, cellOf, type Body } from '../../src/sim/move';
import {
  blackedOut,
  blinking,
  CALL_REACH,
  carLocal,
  carSide,
  createRun,
  depthMultiplier,
  doorsOpen,
  inCar,
  moveInRun,
  type RunEvent,
  type RunState,
} from '../../src/sim/run';
import { exertion, freshStamina, gaitFor, speedFor, stepStamina, WALK_SPEED, type Gait, type Stamina } from '../../src/sim/stamina';
import { northEdge, westEdge } from '../../src/sim/walls';

const ME = 'me';
const EYE_HEIGHT = 1.65; // src/game/player.ts
const PLAYER_RADIUS = 0.3; // src/game/player.ts
/** The door-hold button inside the car, car-local (src/render/elevator.ts HOLD_BUTTON; main.ts nearHoldButton). */
const HOLD_BUTTON_V = 0.84;
/** Most run ticks one frame may run (a test's time scale), so a stall never freezes the page. */
const MAX_TICKS_PER_FRAME = 400;

export interface FrameIn {
  dt: number;
  /** Walk wish: forward and right, each -1..1. */
  f?: number;
  r?: number;
  sprint?: boolean;
  creep?: boolean;
  /** Camera, three.js convention (the same as Godot's): yaw 0 faces -z, radians. */
  yaw: number;
  pitch: number;
  hfov: number;
  vfov: number;
  raised?: boolean;
  /** The call button was pressed this frame. */
  call?: boolean;
  hold?: boolean;
  pickUp?: boolean;
  /** The player cannot act (the caught noise, the end screen). */
  still?: boolean;
  /** Tests: run time passes this many times faster than real time. */
  timeScale?: number;
}

interface Auto {
  walk: PathWalk;
  stuck: number;
  pace: number;
}

function wantDir(d: string): number {
  // yawForDir in src/game/player.ts
  return ({ n: 0, w: Math.PI / 2, s: Math.PI, e: -Math.PI / 2 } as Record<string, number>)[d] ?? 0;
}

function poseOf(o: OrderlyState): Pose {
  return { x: o.body.x, y: o.body.y, z: o.body.z, level: o.body.level, yaw: o.yaw, anim: o.anim, animTime: o.animTime };
}

/** The floor as the client builds it: the plan itself plus what it needs and must not compute. */
function planDump(s: RunState): unknown {
  const plan = s.plan;
  const W = plan.width;
  const H = plan.height;
  const edges = ([0, 1] as const).map((level) => {
    const vertical: string[] = [];
    for (let y = 0; y < H; y++) for (let x = 0; x <= W; x++) vertical.push(westEdge(plan, level, x, y));
    const horizontal: string[] = [];
    for (let y = 0; y <= H; y++) for (let x = 0; x < W; x++) horizontal.push(northEdge(plan, level, x, y));
    return { vertical, horizontal };
  });
  // Walking distance (cells) from the landing to every position, -1 where unreachable: the client's
  // clean-to-corrupted gradient.
  const liftDist = Array.from(distancesFrom(plan, plan.landing));
  return {
    ...plan,
    sightlines: plan.sightlines,
    edges,
    elevatorWall: elevatorWall(plan),
    landingFacing: landingFacing(plan),
    car: s.car,
    liftDist,
  };
}

export class RulesHost {
  private rules = new HostRules(true, 1);
  private state: RunState | null = null;
  private body: Body = { x: 0, z: 0, y: 0, level: 0 };
  private stamina: Stamina = freshStamina();
  private gait: Gait = 'walk';
  private speed = 0;
  private acc = 0;
  private pendingCall = false;
  private pendingPick = false;
  private prevPose: Pose | null = null;
  private curPose: Pose | null = null;
  private drawn: Pose | null = null;
  private frozen = false;
  private auto: Auto | null = null;
  private autoStatus = 'idle';
  private planDepth = -1;
  private ticks = 0;
  private seed = 'alpha';

  handle(text: string): string {
    let req: Record<string, unknown>;
    try {
      req = JSON.parse(text) as Record<string, unknown>;
    } catch (e) {
      return JSON.stringify({ error: `bad json: ${String(e)}` });
    }
    try {
      return JSON.stringify(this.dispatch(req));
    } catch (e) {
      return JSON.stringify({ error: String((e as Error)?.stack ?? e) });
    }
  }

  private dispatch(req: Record<string, unknown>): unknown {
    switch (req.op) {
      case 'start':
        return this.start(String(req.seed ?? 'alpha'), Number(req.depth ?? 1), req.entity !== false);
      case 'frame':
        return this.frame(req as unknown as FrameIn);
      case 'teleport': {
        const s = this.need();
        const lv = Number(req.level) as Level;
        this.body = bodyAtCell(s.plan, { level: lv, x: Number(req.x), y: Number(req.y) });
        this.auto = null;
        this.autoStatus = 'idle';
        return { ok: true, placed: this.body };
      }
      case 'walkTo': {
        const s = this.need();
        const from = cellOf(s.plan, this.body);
        const path = findPath(s.plan, from, { level: Number(req.level) as Level, x: Number(req.x), y: Number(req.y) });
        if (!path) {
          this.autoStatus = 'failed: no path';
          return { ok: false };
        }
        this.auto = { walk: startPathWalk(path), stuck: 0, pace: Number(req.pace ?? WALK_SPEED) };
        this.autoStatus = 'walking';
        return { ok: true, cells: path.length };
      }
      case 'nudge': {
        const s = this.need();
        this.body = moveInRun(s, this.body, Number(req.dx) || 0, Number(req.dz) || 0, PLAYER_RADIUS);
        return { ok: true, body: this.body };
      }
      case 'stopWalk':
        this.auto = null;
        this.autoStatus = 'idle';
        return { ok: true };
      case 'debug': {
        const s = this.need();
        return { orderly: s.orderly, phase: s.phase, t: s.t, blink: s.blink, call: s.call, ticks: this.ticks, body: this.body };
      }
      default:
        return { error: `unknown op ${String(req.op)}` };
    }
  }

  private need(): RunState {
    if (!this.state) throw new Error('no run: send start first');
    return this.state;
  }

  private start(seed: string, depth: number, entity: boolean): unknown {
    this.seed = seed;
    this.rules = new HostRules(entity, Math.max(1, Math.floor(depth)));
    const s = this.rules.prepare(createRun(seed, [ME]));
    this.state = s;
    this.body = s.players[0]?.body ?? startBody(s.car, 0, 1);
    this.stamina = freshStamina();
    this.gait = 'walk';
    this.speed = 0;
    this.acc = 0;
    this.pendingCall = false;
    this.pendingPick = false;
    this.resetOrderly();
    this.auto = null;
    this.autoStatus = 'idle';
    this.ticks = 0;
    this.planDepth = -1;
    const snap = this.snapshot([], { yaw: wantDir(landingFacing(s.plan)), pitch: 0, hfov: 100, vfov: 70, dt: 0 });
    return { ...snap, placed: { ...this.body, yaw: wantDir(landingFacing(s.plan)) } };
  }

  private resetOrderly(): void {
    const s = this.state;
    this.curPose = s ? poseOf(s.orderly) : null;
    this.prevPose = this.curPose;
    this.drawn = null;
    this.frozen = false;
  }

  private camera(inp: FrameIn): Camera {
    return { body: { ...this.body }, eye: EYE_HEIGHT, yaw: inp.yaw, pitch: inp.pitch, hFovDeg: inp.hfov, vFovDeg: inp.vfov };
  }

  private frame(inp: FrameIn): unknown {
    let s = this.need();
    const dt = Math.max(0, Math.min(0.1, Number(inp.dt) || 0));
    const playing = !inp.still && s.phase !== 'ended';
    if (inp.call) this.pendingCall = true;
    if (inp.pickUp) this.pendingPick = true;

    // The instrument answers at once (the walk cap and the drawing follow on this frame), as on the host's page.
    const wantRaised = playing && inp.raised === true;
    const m0 = member(s.crew, ME);
    if (m0 && m0.instrument.raised !== wantRaised) {
      s = { ...s, crew: setRaised(s.crew, ME, wantRaised) };
      this.state = s;
    }
    const raised = member(s.crew, ME)?.instrument.raised ?? false;

    // 1. Walking (src/game/player.ts control), or the test's auto-walk.
    let placedYaw: number | null = null;
    const before = this.body;
    this.speed = 0;
    if (this.auto && playing) {
      const a = this.auto;
      const step = a.pace * dt;
      if (pathDone(s.plan, a.walk, this.body)) {
        this.auto = null;
        this.autoStatus = 'done';
      } else {
        const b0 = this.body;
        this.body = stepPathWalk(s.plan, a.walk, b0, step, PLAYER_RADIUS);
        const mx = this.body.x - b0.x;
        const mz = this.body.z - b0.z;
        if (Math.hypot(mx, mz) > 1e-4) {
          placedYaw = Math.atan2(-mx, -mz);
          a.stuck = 0;
        } else if ((a.stuck += dt) > 3) {
          this.auto = null;
          this.autoStatus = 'failed: stuck';
        }
      }
      this.gait = 'walk';
      this.speed = dt > 0 ? Math.hypot(this.body.x - before.x, this.body.z - before.z) / dt : 0;
    } else {
      const f = playing ? Math.max(-1, Math.min(1, Number(inp.f) || 0)) : 0;
      const r = playing ? Math.max(-1, Math.min(1, Number(inp.r) || 0)) : 0;
      const moving = f !== 0 || r !== 0;
      const cap = raised ? maxWalkSpeed(true, WALK_SPEED) : Infinity;
      this.gait = gaitFor(this.stamina, { sprint: inp.sprint === true, creep: inp.creep === true, moving, cap });
      if (moving) {
        const len = Math.hypot(f, r);
        const nf = f / Math.max(1, len);
        const nr = r / Math.max(1, len);
        const speed = this.gait === 'sprint' ? speedFor('sprint', cap) : Math.min(cap, speedFor(this.gait));
        const sin = Math.sin(inp.yaw);
        const cos = Math.cos(inp.yaw);
        const dx = (-sin * nf + cos * nr) * speed * dt;
        const dz = (-cos * nf - sin * nr) * speed * dt;
        this.body = moveInRun(s, this.body, dx, dz, PLAYER_RADIUS);
        this.speed = speed;
      }
    }
    const moved = Math.hypot(this.body.x - before.x, this.body.z - before.z);
    this.stamina = stepStamina(this.stamina, this.gait, dt > 0 ? moved / dt : 0, dt);

    // 2. The run's ticks that are due.
    const scale = Math.max(0, Number(inp.timeScale ?? 1) || 1);
    this.acc += dt * scale;
    const events: RunEvent[] = [];
    let placed: (Body & { yaw?: number }) | null = null;
    const cam = (): Camera => this.camera({ ...inp, yaw: placedYaw ?? inp.yaw });
    for (let n = 0; this.acc >= TICK - 1e-9 && n < MAX_TICKS_PER_FRAME; n++) {
      this.acc -= TICK;
      const c = cam();
      const input = {
        id: ME,
        body: { ...this.body },
        eye: EYE_HEIGHT,
        yaw: c.yaw,
        pitch: c.pitch,
        hFovDeg: c.hFovDeg,
        vFovDeg: c.vFovDeg,
        raised: wantRaised,
        holdDoors: playing && inp.hold === true,
        call: this.pendingCall && playing ? true : undefined,
        pickUp: this.pendingPick && playing ? (true as const) : undefined,
      };
      this.pendingCall = false;
      this.pendingPick = false;
      const depthBefore = this.state?.depth ?? 1;
      const r = this.rules.step(this.need(), [input], TICK);
      this.state = r.state;
      this.ticks++;
      events.push(...r.events);
      // The run moved the player: a ride, being put out of the car, a catch turned into a placeholder.
      for (const e of r.events) {
        if (e.type === 'rodeDown' && e.bodies[ME]) placed = { ...e.bodies[ME] };
        if (e.type === 'doorsClosed' && e.pushedOut[ME]) placed = { ...e.pushedOut[ME] };
      }
      for (const id of this.rules.revived.splice(0)) {
        if (id !== ME) continue;
        const p = this.state.plan;
        placed = { ...bodyAtCell(p, p.landing), yaw: wantDir(landingFacing(p)) };
      }
      if (placed) {
        this.body = { x: placed.x, y: placed.y, z: placed.z, level: placed.level };
        if (this.auto) this.autoStatus = 'interrupted';
        this.auto = null;
      }
      if (this.state.depth !== depthBefore) {
        this.resetOrderly();
      } else {
        this.prevPose = this.curPose;
        this.curPose = poseOf(this.state.orderly);
      }
      if (this.state.phase === 'ended') break;
    }
    return { ...this.snapshot(events, { ...inp, yaw: placedYaw ?? inp.yaw }), placed, autoYaw: placedYaw };
  }

  /** The Orderly as this screen draws it (src/net/client.ts frame(), for one local player). */
  private drawOrderly(s: RunState, cam: Camera, dark: boolean): { pose: Pose | null; seeing: boolean; held: boolean } {
    const a = this.prevPose;
    const b = this.curPose;
    if (!a || !b) return { pose: null, seeing: false, held: false };
    const cand = lerpPose(a, b, Math.max(0, Math.min(1, this.acc / TICK)));
    const open = doorsOpen(s);
    const sees = (p: Pose): boolean => !dark && cameraSees(s.plan, cam, p, open);
    let seeing = false;
    if (this.frozen && this.drawn && sees(this.drawn)) {
      seeing = true;
    } else if (this.frozen && this.drawn && sees(cand)) {
      // The held pose left the view but the new one is in it: keep holding until neither is.
    } else {
      if (sees(cand)) {
        this.frozen = true;
        seeing = true;
      } else this.frozen = false;
      if (!this.drawn || !samePose(this.drawn, cand)) this.drawn = cand;
    }
    let pose = this.drawn;
    // Frozen within reach of you while hunting, it is drawn reaching (src/main.ts freezePose).
    if (pose && this.frozen) {
      const near = Math.hypot(this.body.x - pose.x, this.body.z - pose.z) <= REACH_RANGE && Math.abs(this.body.y - pose.y) < 1;
      const mode = s.orderly.mode;
      if (near && pose.anim !== 'reach' && (mode === 'hunting' || mode === 'windUp')) pose = { ...pose, anim: 'reach', animTime: WIND_UP_TIME * 0.85 };
    }
    return { pose, seeing, held: this.frozen };
  }

  private snapshot(events: RunEvent[], inp: Pick<FrameIn, 'yaw' | 'pitch' | 'hfov' | 'vfov' | 'dt'>): Record<string, unknown> {
    const s = this.need();
    const car = s.car;
    const me = s.players.find((p) => p.id === ME);
    const mem = member(s.crew, ME);
    const inst = mem?.instrument;
    const dark = blinking(s);
    const b = s.blink;
    const warn = b !== null && b.announced && b.endsAt === null;
    const cam = this.camera(inp as FrameIn);
    const o = s.phase === 'riding' || s.phase === 'ended' ? { pose: null, seeing: false, held: false } : this.drawOrderly(s, cam, dark);
    const moving = s.orderly.moving;
    const squeak =
      o.pose && !o.seeing && !o.held && moving
        ? audibility(s.plan, { ...s.orderly, body: { x: o.pose.x, y: o.pose.y, z: o.pose.z, level: o.pose.level }, moving } as OrderlyState, { body: this.body, eye: EYE_HEIGHT })
        : { gain: 0, muffled: false };
    const inCarNow = inCar(car, this.body);
    const tapes = mem ? [mem.tape, ...mem.carrying] : [];
    const local = carLocal(car, this.body.x, this.body.z);
    const c = s.call;
    const out: Record<string, unknown> = {
      t: s.t,
      seed: this.seed,
      depth: s.depth,
      multiplier: depthMultiplier(s.depth),
      phase: s.phase,
      timer: s.timer,
      bellLeft: s.bellLeft,
      holdLeft: s.holdLeft,
      held: s.held,
      calls: s.calls,
      call: c
        ? { floorsAway: c.floorsAway, floors: c.plan.floors, falseStop: c.stopUntil !== null, eta: Math.max(0, c.at + c.plan.wait - s.t), darks: c.plan.darks.map((d) => ({ ...d, at: c.at + d.at })) }
        : null,
      blink: b ? { at: b.at, len: b.len, warn: b.warn, blackout: b.blackout, announced: b.announced, on: b.endsAt !== null, endsAt: b.endsAt } : null,
      dark,
      blackout: blackedOut(s),
      warn,
      doorsOpen: doorsOpen(s),
      me: {
        x: this.body.x,
        y: this.body.y,
        z: this.body.z,
        level: this.body.level,
        eye: EYE_HEIGHT,
        status: me?.status ?? 'ok',
        aboard: inCarNow,
        side: me?.side ?? null,
        standing: carSide(car, this.body),
        gait: this.gait,
        speed: this.speed,
        stamina: this.stamina.level,
        winded: this.stamina.winded,
        exertion: exertion(this.stamina),
        canCall: s.phase === 'away' && this.body.level === car.level && !inCarNow && Math.hypot(this.body.x - car.doorX, this.body.z - car.doorZ) <= CALL_REACH - 0.05,
        nearHold: s.phase === 'boarding' && inCarNow && Math.hypot(local.u - 0.3, local.v - HOLD_BUTTON_V) <= 0.75,
        cell: cellOf(s.plan, this.body),
      },
      orderly: {
        pose: o.pose,
        visible: o.pose !== null && !dark,
        seeing: o.seeing,
        held: o.held,
        mode: s.orderly.mode,
        frozen: s.orderly.frozen,
        moving,
        speed: s.orderly.speed,
        x: s.orderly.body.x,
        z: s.orderly.body.z,
        level: s.orderly.body.level,
        squeak,
        distance: Math.hypot(this.body.x - s.orderly.body.x, this.body.z - s.orderly.body.z),
      },
      inst: inst
        ? { raised: inst.raised, needle: inst.needle, value: inst.current?.value ?? 0, rate: inst.rate, tickHz: inst.tickHz, loudness: inst.loudness, distance: inst.distance }
        : null,
      tapes: { count: tapes.filter((tp) => tp.readings.length > 0).length, value: tapeValue(tapes) },
      floorTapes: s.crew.floor.map((f) => ({ id: f.tape.id, at: f.at })),
      votes: { bank: s.players.filter((p) => p.side === 'bank').length, down: s.players.filter((p) => p.side === 'down').length },
      summary: s.summary,
      events,
      auto: this.autoStatus,
      ticks: this.ticks,
    };
    if (s.depth !== this.planDepth) {
      this.planDepth = s.depth;
      out.plan = planDump(s);
    }
    return out;
  }
}

export function makeHost(): { call(text: string): string } {
  const host = new RulesHost();
  return { call: (text: string) => host.handle(text) };
}

export type { FloorPlan };
