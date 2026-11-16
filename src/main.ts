import * as THREE from 'three';
import { GameAudio } from './game/audio';
import { AutoWalk } from './game/autoWalk';
import { CrewHost } from './game/crewHost';
import { EntityHost } from './game/entityHost';
import { Minimap } from './game/minimap';
import { FrameStats } from './game/frameStats';
import { Input } from './game/input';
import { EYE_HEIGHT, Player, WALK_SPEED, yawForDir, yawToward } from './game/player';
import { CaughtFx, NOISE_MS } from './render/caughtFx';
import { EntityPreview } from './render/entityPreview';
import { blendPose, EntityView, exactPose, type DrawnPose } from './render/entityView';
import { InstrumentView } from './render/instrumentView';
import { PickupPrompt } from './render/pickupPrompt';
import { TapeDrops } from './render/tapeDrops';
import { Osd } from './render/osd';
import { setLightGain, Tape, type FxLevel } from './render/tape';
import { buildWorld } from './render/world';
import { generateClinic } from './sim/clinic';
import { audibility, ORDERLY_HEIGHT, ORDERLY_RADIUS, REACH_RANGE, SQUEAK_HEIGHT, WIND_UP_TIME, type OrderlyAnim, type OrderlyEvent, type OrderlyState, type PlayerView } from './sim/entity';
import type { Level } from './sim/floor';
import { maxWalkSpeed, tapeValue, type CrewEvent, type EntityTick } from './sim/instrument';
import { landingFacing } from './sim/landing';
import { bodyAtCell, cellOf, LEVEL_HEIGHT, type Body } from './sim/move';
import { canSee } from './sim/sight';

declare const __BUILD__: string;

// URL flags used by tests and by the owner when checking in. More are added as features land.
const params = new URLSearchParams(location.search);
const seed = params.get('seed') ?? 'orientation';
const depth = Math.max(1, Math.floor(Number(params.get('depth') ?? '1')) || 1);
const debug = params.get('debug') === '1';
// ?preview=orderly[&anim=walk|idle|reach|duck|still] stands an entity model in the level.
const previewName = params.get('preview');
// ?fx=0 clean render, 1 the tape look (default), 2 heavy interference.
const fxParam = Number(params.get('fx') ?? '1');
const fxLevel: FxLevel = fxParam >= 2 ? 2 : fxParam === 0 ? 0 : 1;
// The live Orderly is on every floor by default. ?entity=0 leaves the floor empty; ?preview=orderly
// shows a static figure instead.
const entityOn = params.get('entity') !== '0' && previewName !== 'orderly';

const canvas = document.getElementById('view') as HTMLCanvasElement;
const hud = document.getElementById('hud') as HTMLDivElement;
const overlay = document.getElementById('start') as HTMLDivElement;
const debugBox = document.getElementById('debug') as HTMLDivElement;

const renderer = new THREE.WebGLRenderer({ canvas, antialias: false, powerPreference: 'high-performance' });
renderer.setPixelRatio(1);

const plan = generateClinic(seed, depth);
const { scene } = buildWorld(plan);
const camera = new THREE.PerspectiveCamera(70, 16 / 9, 0.05, 90);

const player = new Player(plan, plan.landing.level, plan.landing.x, plan.landing.y, yawForDir(landingFacing(plan)));
const input = new Input(canvas, overlay);
const autoWalk = new AutoWalk();

let preview: EntityPreview | null = null;
if (previewName === 'orderly') {
  renderer.shadowMap.enabled = true;
  preview = new EntityPreview(scene, `${import.meta.env.BASE_URL}assets/entities/orderly.glb`);
  preview.play(params.get('anim') ?? 'idle');
  // At the entity's start, facing down the sightline it sits at the end of.
  const s0 = plan.entityStart;
  const line = plan.sightlines.find((s) => s.level === s0.level && ((s.x1 === s0.x && s.y1 === s0.y) || (s.x2 === s0.x && s.y2 === s0.y)));
  const far = line ? (line.x1 === s0.x && line.y1 === s0.y ? { x: line.x2, y: line.y2 } : { x: line.x1, y: line.y1 }) : s0;
  const b = bodyAtCell(plan, s0);
  preview.place(b.x, b.y, b.z, line ? yawToward(far.x - s0.x, far.y - s0.y) : 0);
}
const stats = new FrameStats(120);

// ---------------------------------------------------------------------------------------------
// The live Orderly.
const LOCAL_ID = 'local';
let host: EntityHost | null = null;
let orderlyView: EntityView | null = null;
if (entityOn) {
  renderer.shadowMap.enabled = true;
  host = new EntityHost(plan);
  orderlyView = new EntityView(scene, `${import.meta.env.BASE_URL}assets/entities/orderly.glb`);
}
const audio = new GameAudio();
const caughtFx = new CaughtFx(document.body);

// ---------------------------------------------------------------------------------------------
// The crew's instruments: stepped once per logic tick right after the Orderly (host.onTick), or on
// their own clock when the floor is empty.
const ORDERLY_ID = 'orderly';
const crew = new CrewHost(plan, [LOCAL_ID]);
const instrument = new InstrumentView();
const tapeDrops = new TapeDrops(scene);
const pickupPrompt = new PickupPrompt(document.body, () => void tryPickUp());
/** Set by the test hook __gd.raise(); null leaves it to the player's input. */
let forcedRaise: boolean | null = null;
/** Audible ticks the logic produced since the last frame (the needle kicks on each). */
let pendingTicks = 0;
if (host) {
  host.onTick = (prev, cur, events, players) => {
    const ent: EntityTick = { id: ORDERLY_ID, trait: 'stillness', prev, next: cur, events };
    crew.tick(players.map((p) => ({ id: p.id, body: p.body, active: p.active })), [ent]);
    pendingTicks += crew.member(LOCAL_ID)?.instrument.ticks ?? 0;
  };
}

function tryPickUp(): { ok: boolean; reason: string; tapeId: string | null } {
  if (caughtFx.noiseOn) return { ok: false, reason: 'inactive', tapeId: null };
  return crew.pickUp(LOCAL_ID, player.body);
}

function onCrewEvents(evs: CrewEvent[]): void {
  for (const e of evs) {
    if (e.playerId !== LOCAL_ID) continue;
    if (e.type === 'slip') {
      instrument.printSlip(e.text);
      audio.slipPrinted();
    } else if (e.type === 'readingClosed') audio.readingClosed();
  }
}
let catches = 0;
/** The local player's screen could show the figure this frame (any of the checks in frameSees). */
let orderlyVisible = false;
/** The logic's own judgement (radius ORDERLY_RADIUS) says the local view sees it this frame. */
let orderlyLogicSeen = false;
let squeak = { gain: 0, muffled: false };
/** Per-frame record for tests: what was drawn against where the logic had it. */
const trace: { f: number; vis: boolean; dx: number; dz: number; lx: number; lz: number; t: number; anim: string; clip: number }[] = [];

// The scene is drawn at a low internal resolution, then put on screen through the tape pass.
const INTERNAL_HEIGHT = 270;
// ?hdr=0 forces the 8-bit render path that older phones fall back to.
const tape = new Tape(renderer, fxLevel, INTERNAL_HEIGHT, params.get('hdr') === '0');
const osd = new Osd(document.body, seed);
osd.visible = fxLevel > 0;
/** Lights glare through the tape; the clean render keeps them as built. */
const LIGHT_GAIN = 3;
setLightGain(scene, fxLevel > 0 ? LIGHT_GAIN : 1);
function resize(): void {
  const aspect = window.innerWidth / Math.max(1, window.innerHeight);
  tape.setSize(window.innerWidth, window.innerHeight);
  camera.aspect = aspect;
  camera.updateProjectionMatrix();
  instrument.setAspect(aspect);
}
window.addEventListener('resize', resize);
resize();

function gpuName(): string {
  const gl = renderer.getContext();
  const ext = gl.getExtension('WEBGL_debug_renderer_info');
  return ext ? String(gl.getParameter(ext.UNMASKED_RENDERER_WEBGL)) : 'unknown';
}

/** Draws a full frame (scene and tape pass) and reads the screen back, straight from the GPU. */
function readScreen(): { w: number; h: number; px: Uint8Array } {
  player.toCamera(camera);
  tape.render(scene, camera, instrument.visible ? instrument : null);
  const gl = renderer.getContext();
  const w = gl.drawingBufferWidth;
  const h = gl.drawingBufferHeight;
  const px = new Uint8Array(w * h * 4);
  gl.readPixels(0, 0, w, h, gl.RGBA, gl.UNSIGNED_BYTE, px);
  return { w, h, px };
}

/** For tests: draw a frame and count distinct colours on a coarse grid of the screen. */
function probeColours(): number {
  const { w, h, px } = readScreen();
  const seen = new Set<number>();
  for (let y = 0; y < h; y += 6) {
    for (let x = 0; x < w; x += 6) {
      const i = (y * w + x) * 4;
      seen.add(((px[i] ?? 0) << 16) | ((px[i + 1] ?? 0) << 8) | (px[i + 2] ?? 0));
    }
  }
  return seen.size;
}

/**
 * For tests: an n x n grid of screen pixels (top row first) as [r, g, b] triples, from one fresh
 * frame. Each probe averages a 5x5 patch so grain does not decide the answer alone.
 */
function probePixels(n = 8): number[][] {
  const { w, h, px } = readScreen();
  const out: number[][] = [];
  for (let j = 0; j < n; j++) {
    for (let i = 0; i < n; i++) {
      const cx = Math.floor(((i + 0.5) / n) * w);
      const cy = h - 1 - Math.floor(((j + 0.5) / n) * h);
      let r = 0;
      let g = 0;
      let b = 0;
      let k = 0;
      for (let y = Math.max(0, cy - 2); y <= Math.min(h - 1, cy + 2); y++) {
        for (let x = Math.max(0, cx - 2); x <= Math.min(w - 1, cx + 2); x++) {
          const o = (y * w + x) * 4;
          r += px[o] ?? 0;
          g += px[o + 1] ?? 0;
          b += px[o + 2] ?? 0;
          k++;
        }
      }
      out.push([r / k, g / k, b / k]);
    }
  }
  return out;
}

const DEG = Math.PI / 180;
/** The model's cap reaches 2.82 m; the logic samples its figure up to ORDERLY_HEIGHT (2.6 m). */
const MESH_EXTRA_HEIGHT = 0.22;

/** The local player as the logic sees them: eye height ABOVE THE FEET, the real camera's field of view. */
function localView(): PlayerView {
  const vFov = camera.fov;
  const hFov = (2 * Math.atan(Math.tan((vFov * DEG) / 2) * camera.aspect)) / DEG;
  return { id: LOCAL_ID, active: true, body: { ...player.body }, eye: EYE_HEIGHT, yaw: player.yaw, pitch: player.pitch, hFovDeg: hFov, vFovDeg: vFov };
}

/**
 * Whether this frame could show the figure: the logic's own test at the logic's position, the same
 * test widened to the measured reach of the current clip (the mesh pokes out past the logic's 0.35 m
 * body), and the widened test at the position drawn last frame.
 */
function frameSees(v: PlayerView, h: EntityHost, ev: EntityView): boolean {
  if (canSee(plan, v, h.cur.body, { height: ORDERLY_HEIGHT, radius: ORDERLY_RADIUS })) return true;
  const ext = (anim: OrderlyAnim): number => Math.max(ORDERLY_RADIUS, ev.extent(anim));
  // The mesh is taller than the logic's figure too (cap at 2.82 m against 2.6 m).
  const height = ORDERLY_HEIGHT + MESH_EXTRA_HEIGHT;
  // Widest of the clip the logic asks for and the clip on screen (a held reach pose, say).
  const reach = Math.max(ext(h.cur.anim), ev.drawn ? ext(ev.drawn.anim) : 0);
  const seenWide = canSee(plan, v, h.cur.body, { height, radius: reach });
  if (seenWide) {
    // Only the overhang is in view. Hand the logic this view with the field of view widened by
    // just the overhang's angle, so it holds the figure too (decided in the player's favour).
    const dist = Math.max(0.2, Math.hypot(h.cur.body.x - v.body.x, h.cur.body.z - v.body.z));
    const extra = (Math.atan2(reach - ORDERLY_RADIUS + MESH_EXTRA_HEIGHT, dist) / DEG + 1) * 2;
    h.noteSeen({ ...v, hFovDeg: v.hFovDeg + extra, vFovDeg: v.vFovDeg + extra });
    return true;
  }
  const d = ev.drawn;
  if (!d) return false;
  const body: Body = { x: d.x, y: d.y, z: d.z, level: d.y >= LEVEL_HEIGHT - 0.01 ? 1 : h.cur.body.level };
  return canSee(plan, v, body, { height, radius: Math.max(ext(d.anim), ext(h.cur.anim)) });
}

/** The pose to hold when it is first seen: the logic's exact pose, reaching if it froze within reach of you. */
function freezePose(s: OrderlyState): DrawnPose {
  const p = exactPose(s);
  const b = player.body;
  const near = b.level === s.body.level && Math.hypot(b.x - s.body.x, b.z - s.body.z) <= REACH_RANGE;
  if (near && p.anim !== 'reach' && (s.mode === 'hunting' || s.mode === 'windUp')) return { ...p, anim: 'reach', animTime: WIND_UP_TIME * 0.85 };
  return p;
}

function onEntityEvents(evs: OrderlyEvent[], now: number): void {
  for (const e of evs) {
    if (e.type !== 'caught' || e.playerId !== LOCAL_ID) continue;
    // Placeholder: interference, noise, and back to the landing (caughtFx decides when).
    catches++;
    tape.glitch(NOISE_MS + 500, 1);
    caughtFx.start(now);
    audio.caughtBurst();
  }
}

function orderlyInfo() {
  if (!host) return null;
  const s = host.cur;
  const c = cellOf(plan, s.body);
  const b = player.body;
  const d = orderlyView?.drawn;
  return {
    x: s.body.x,
    y: s.body.y,
    z: s.body.z,
    level: s.body.level,
    cx: c.x,
    cy: c.y,
    yaw: s.yaw / DEG,
    phase: s.mode,
    frozen: s.frozen,
    held: s.held,
    moving: s.moving,
    /** The local player's screen could show it this frame. */
    seen: orderlyVisible,
    /** The logic's own sight test from the local view this frame. */
    logicSeen: orderlyLogicSeen,
    anim: s.anim,
    animTime: s.animTime,
    distance: Math.hypot(b.x - s.body.x, b.z - s.body.z),
    t: s.t,
    loaded: orderlyView?.loaded ?? false,
    drawn: d ? { x: d.x, y: d.y, z: d.z, yaw: d.yaw / DEG, anim: d.anim, animTime: d.animTime, frozen: orderlyView?.isFrozen ?? false } : null,
  };
}

// Test hooks. Yaw is in degrees: 0 faces north (-z), 90 west, 180 south, -90 east.
const state = {
  ready: false,
  frames: 0,
  build: __BUILD__,
  seed,
  depth,
  gpu: gpuName(),
  probeColours,
  probePixels,
  plan,
  player: () => {
    const c = cellOf(plan, player.body);
    return { ...player.body, eye: player.body.y + EYE_HEIGHT, cx: c.x, cy: c.y, yaw: player.yaw / DEG, pitch: player.pitch / DEG };
  },
  teleport: (level: Level, cx: number, cy: number, yawDegrees?: number) => {
    autoWalk.cancel('teleported');
    player.teleport(plan, level, cx, cy, yawDegrees === undefined ? undefined : yawDegrees * DEG);
  },
  look: (yawDegrees: number, pitchDegrees = 0) => {
    player.yaw = yawDegrees * DEG;
    player.pitch = pitchDegrees * DEG;
  },
  walkTo: (level: Level, cx: number, cy: number) => autoWalk.start(plan, player, { level, x: cx, y: cy }),
  frameMs: () => stats.median(),
  /** Tape strength: 0 clean, 1 default, 2 heavy. */
  fx: () => tape.fx,
  setFx: (level: number) => {
    const l = tape.setFx(level);
    osd.visible = l > 0;
    setLightGain(scene, l > 0 ? LIGHT_GAIN : 1);
    return l;
  },
  /** A burst of tape interference, `ms` long, `strength` 0..1. */
  glitch: (ms: number, strength = 1) => tape.glitch(ms, strength),
  /** The previewed entity (?preview=orderly), or null. Positions in world metres, yaw in degrees. */
  entity: preview && {
    loaded: () => preview?.loaded ?? false,
    animations: () => preview?.animations() ?? [],
    current: () => preview?.current() ?? '',
    play: (name: string) => preview?.play(name) ?? false,
    placeCell: (level: Level, cx: number, cy: number, yawDegrees = 0) => {
      const b = bodyAtCell(plan, { level, x: cx, y: cy });
      preview?.place(b.x, b.y, b.z, yawDegrees * DEG);
    },
    placeAt: (x: number, y: number, z: number, yawDegrees = 0) => preview?.place(x, y, z, yawDegrees * DEG),
    bone: (name: string) => preview?.bonePosition(name) ?? null,
  },
  /** Hides the click-to-start overlay without a pointer lock (and starts audio where allowed). */
  start: () => {
    input.dismissOverlay();
    audio.unlock();
  },
  /** The live Orderly's state, or null with ?entity=0. Positions in metres, yaw in degrees. */
  orderly: orderlyInfo,
  /** Everything the Orderly's logic has reported so far. */
  events: (): OrderlyEvent[] => (host ? host.events.map((e) => ({ ...e })) : []),
  catches: () => catches,
  caught: () => ({ noise: caughtFx.noiseOn, line: caughtFx.lineOn }),
  /** Test controls for the live Orderly (null with ?entity=0). */
  entityCtl: host && {
    placeCell: (level: Level, cx: number, cy: number, yawDegrees?: number) => {
      if (!host) return;
      const body = bodyAtCell(plan, { level, x: cx, y: cy });
      host.replace({ ...host.cur, body, yaw: yawDegrees === undefined ? host.cur.yaw : yawDegrees * DEG, path: null, replanIn: 0 });
    },
    placeAt: (x: number, z: number, level: Level = 0, yawDegrees?: number) => {
      if (!host) return;
      const body = { x, z, level, y: level === 1 ? LEVEL_HEIGHT : 0 };
      host.replace({ ...host.cur, body, yaw: yawDegrees === undefined ? host.cur.yaw : yawDegrees * DEG, path: null, replanIn: 0 });
    },
    /** Ends its waiting (or dormancy): it hunts on the next tick it is free to act. */
    wake: () => {
      if (!host) return;
      if (host.cur.mode === 'waiting' || host.cur.mode === 'dormant') host.replace({ ...host.cur, mode: 'hunting', dormantLeft: 0, replanIn: 0, path: null });
    },
    setTimeScale: (k: number) => {
      if (host) host.timeScale = Math.max(0, k);
    },
    /** Per-frame records: drawn position (dx, dz) against the logic's (lx, lz), and visibility. */
    trace: () => trace.slice(),
    /** Widest reach of the mesh from its feet axis per clip, metres (measured at load). */
    extents: () => Object.fromEntries(['idle', 'walk', 'duck', 'reach', 'still'].map((n) => [n, orderlyView?.model.extent(n) ?? 0])),
    ticks: () => host?.ticks ?? 0,
  },
  audio: { state: () => audio.state() },
  /** The local player's instrument: the logic's state and what is drawn. */
  instrument: () => {
    const m = crew.member(LOCAL_ID);
    if (!m) return null;
    const i = m.instrument;
    return {
      raised: i.raised,
      needle: i.needle,
      /** Value of the reading open now (0 if none). */
      value: i.current?.value ?? 0,
      /** Seconds recorded in the open reading. */
      recording: i.current?.duration ?? 0,
      /** Everything held: own tape plus tapes picked up. */
      total: crew.held(LOCAL_ID),
      own: tapeValue(m.tape),
      tickHz: i.tickHz,
      loudness: i.loudness,
      /** Tapes held with something on them. */
      tapes: crew.heldCount(LOCAL_ID),
      carrying: m.carrying.length,
      distance: i.distance,
      drawnRaise: instrument.raisedAmount,
      needleAngle: instrument.needleAngle,
      slip: { text: instrument.slipText, shown: instrument.slipShown },
      osd: osd.tapeText,
    };
  },
  /** Raises (true) or lowers (false) the instrument regardless of input; null hands it back to input. */
  raise: (on: boolean | null) => {
    forcedRaise = on;
  },
  /** Tapes lying on the floor. */
  tapes: () =>
    crew.crew.floor.map((f) => {
      const c = cellOf(plan, f.at);
      return { id: f.tape.id, value: f.tape.total, readings: f.tape.readings.length, x: f.at.x, y: f.at.y, z: f.at.z, level: f.at.level, cx: c.x, cy: c.y };
    }),
  /** Tries to pick up the nearest tape within reach. */
  pickUp: () => tryPickUp(),
  /** Every crew event (slip, readingClosed, tapeDropped, tapePickedUp) so far. */
  crewEvents: (): CrewEvent[] => crew.events.map((e) => ({ ...e })),
  /** Whether the pick-up prompt is showing. */
  pickupShown: () => !pickupPrompt.el.hidden,
};
(window as unknown as { __gd: typeof state }).__gd = state;
hud.textContent = `Going Down  build ${__BUILD__}  seed ${seed}  depth ${depth}`;
debugBox.hidden = !debug;
const debugText = document.createElement('div');
let minimap: Minimap | null = null;
if (debug) {
  debugBox.append(debugText);
  minimap = new Minimap(plan);
  debugBox.append(minimap.canvas);
}

const camForward = new THREE.Vector3();
const camUp = new THREE.Vector3();
let last = performance.now();
renderer.setAnimationLoop(() => {
  const now = performance.now();
  const ms = now - last;
  last = now;
  stats.add(ms);
  const dt = Math.min(ms / 1000, 0.1);

  preview?.update(dt);
  // The instrument is up only while held (or forced by a test), never while the picture is noise.
  const wantRaised = !caughtFx.noiseOn && (forcedRaise ?? input.instrumentHeld());
  crew.setRaised(LOCAL_ID, wantRaised);
  const raised = crew.member(LOCAL_ID)?.instrument.raised ?? false;
  if (autoWalk.active) autoWalk.tick(plan, player);
  else if (!caughtFx.noiseOn) player.control(plan, input, dt, raised ? maxWalkSpeed(true, WALK_SPEED) : Infinity);
  else player.lastSpeed = 0;
  if (caughtFx.update(now)) {
    // Back at the elevator landing, facing out, as on arrival.
    autoWalk.cancel('caught');
    player.teleport(plan, plan.landing.level, plan.landing.x, plan.landing.y, yawForDir(landingFacing(plan)));
    player.pitch = 0;
  }
  player.toCamera(camera);

  if (host && orderlyView) {
    const v = localView();
    // 1. A glance on this frame counts, even if no tick lands on it.
    let vis = frameSees(v, host, orderlyView);
    host.noteSeen(v);
    onEntityEvents(host.advance(dt, [v]), now);
    // 2. After the ticks: it may have stepped into view.
    orderlyLogicSeen = host.sees(v);
    if (orderlyLogicSeen) host.noteSeen(v);
    vis = vis || frameSees(v, host, orderlyView);
    orderlyVisible = vis;
    // 3. Seen: exactly where the logic has it, clock stopped. Unseen: smoothed between ticks.
    // Walking clips run on the stride clock, which follows its speed: a creep is a slow stride.
    const smooth = blendPose(host.prev, host.cur, host.alpha);
    if (smooth.anim === 'walk' || smooth.anim === 'duck') smooth.animTime = host.stride();
    const hold = freezePose(host.cur);
    if (hold.anim === 'walk' || hold.anim === 'duck') hold.animTime = host.curStride;
    orderlyView.update(vis, smooth, hold);
    const d = orderlyView.drawn;
    if (d) {
      trace.push({ f: state.frames + 1, vis, dx: d.x, dz: d.z, lx: host.cur.body.x, lz: host.cur.body.z, t: host.cur.t, anim: d.anim, clip: d.animTime });
      if (trace.length > 600) trace.shift();
    }
    // Sound: silent the instant it is seen, whatever the next tick says.
    squeak = vis || host.cur.held ? { gain: 0, muffled: false } : audibility(plan, host.cur, { body: player.body, eye: EYE_HEIGHT });
    const src = d ?? exactPose(host.cur);
    camForward.set(0, 0, -1).applyQuaternion(camera.quaternion);
    camUp.set(0, 1, 0).applyQuaternion(camera.quaternion);
    audio.update(dt, squeak.gain, squeak.muffled, { x: src.x, y: src.y + SQUEAK_HEIGHT, z: src.z }, camera.position, camForward, camUp, host.cur.speed);
  } else {
    crew.advanceAlone(dt, [{ id: LOCAL_ID, body: { ...player.body }, active: true }]);
  }

  // The instrument, its sound, the tapes on the floor and the tape count.
  onCrewEvents(crew.take());
  const inst = crew.member(LOCAL_ID)?.instrument;
  if (inst) {
    instrument.setTouchLayout(input.touch);
    instrument.update(dt, {
      raised: inst.raised,
      needle: inst.needle,
      value: inst.current?.value ?? 0,
      distance: inst.distance,
      tickHz: inst.tickHz,
      ticks: pendingTicks,
      walkSpeed: player.lastSpeed,
    });
    audio.ticking(inst.tickHz, inst.loudness);
  }
  pendingTicks = 0;
  tapeDrops.sync(crew.crew.floor);
  tapeDrops.update(dt);
  osd.setTapes(crew.heldCount(LOCAL_ID), crew.held(LOCAL_ID));
  const inReach = !caughtFx.noiseOn && crew.tapeInReach(player.body) !== null;
  pickupPrompt.update(inReach, input.touch);
  if (input.takePress('KeyE') && inReach) tryPickUp();

  tape.render(scene, camera, instrument.visible ? instrument : null);
  osd.update(!tape.motion || Math.floor(now / 700) % 2 === 0);
  state.frames++;
  state.ready = true;

  if (debug && state.frames % 10 === 0) {
    const b = player.body;
    const c = cellOf(plan, b);
    const fm = stats.median();
    debugText.textContent =
      `fps ${fm > 0 ? (1000 / fm).toFixed(0) : '-'}  median ${fm.toFixed(1)} ms\n` +
      `tape fx${tape.fx}${tape.motion ? '' : ' (reduced motion)'}\n` +
      `pos ${b.x.toFixed(2)} ${b.y.toFixed(2)} ${b.z.toFixed(2)}\n` +
      `cell L${c.level} (${c.x},${c.y})  yaw ${(player.yaw / DEG).toFixed(0)}`;
    let ent: { level: Level; x: number; z: number; seen: boolean } | null = null;
    if (host) {
      const o = host.cur;
      const dist = Math.hypot(o.body.x - b.x, o.body.z - b.z);
      debugText.textContent +=
        `\norderly ${o.mode}${o.frozen ? ' frozen' : ''}  ${orderlyVisible ? 'SEEN' : 'unseen'}  ${dist.toFixed(1)} m\n` +
        `squeak ${squeak.gain.toFixed(2)}${squeak.muffled ? ' muffled' : ''}  audio ${audio.state().running ? 'on' : 'off'}  catches ${catches}`;
      ent = { level: o.body.level, x: o.body.x, z: o.body.z, seen: orderlyVisible };
    }
    if (inst) {
      debugText.textContent +=
        `\ninstrument ${inst.raised ? 'up' : 'down'} ${inst.needle}  value ${(inst.current?.value ?? 0).toFixed(1)}  tick ${inst.tickHz.toFixed(1)} Hz\n` +
        `tapes held ${crew.heldCount(LOCAL_ID)} worth ${crew.held(LOCAL_ID).toFixed(1)}  on floor ${crew.crew.floor.length}`;
    }
    const floorTapes = crew.crew.floor.map((f) => ({ level: f.at.level, x: f.at.x, z: f.at.z }));
    minimap?.update(c.level, b.x, b.z, player.yaw, ent, floorTapes);
  }
});
