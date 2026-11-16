import * as THREE from 'three';
import { Announcer } from './game/announcer';
import { GameAudio } from './game/audio';
import { AutoWalk } from './game/autoWalk';
import { Minimap } from './game/minimap';
import { installDiagnostics, phoneLike, readSafeLevel } from './game/diagnostics';
import { FrameStats } from './game/frameStats';
import { Input } from './game/input';
import { EYE_HEIGHT, Player, WALK_SPEED, yawForDir, yawToward } from './game/player';
import { isCrewEvent, isOrderlyEvent, RunHost, START_U } from './game/runHost';
import { ActionPrompt } from './render/actionPrompt';
import { CaughtFx, NOISE_MS } from './render/caughtFx';
import { ElevatorView, HOLD_BUTTON } from './render/elevator';
import { EndScreen, type EndLine } from './render/endScreen';
import { EntityPreview } from './render/entityPreview';
import { blendPose, EntityView, exactPose, type DrawnPose } from './render/entityView';
import { InstrumentView } from './render/instrumentView';
import { applyLighting } from './render/lighting';
import { PickupPrompt } from './render/pickupPrompt';
import { TapeDrops } from './render/tapeDrops';
import { Osd } from './render/osd';
import { Tape, type FxLevel } from './render/tape';
import { buildWorld, FOG, replaceFloor } from './render/world';
import { audibility, ORDERLY_HEIGHT, ORDERLY_RADIUS, REACH_RANGE, SQUEAK_HEIGHT, WIND_UP_TIME, type OrderlyAnim, type OrderlyEvent, type OrderlyState, type PlayerView } from './sim/entity';
import type { Level } from './sim/floor';
import { maxWalkSpeed, tapeValue, type CrewEvent } from './sim/instrument';
import { landingFacing } from './sim/landing';
import { bodyAtCell, cellOf, LEVEL_HEIGHT, type Body } from './sim/move';
import { blinking, BOARD_TIME, CALL_REACH, carBody, carLocal, depthMultiplier, doorsOpen, inCar, moveInRun, RIDE_TIME, type PlayerInput, type RunEvent, type RunSummary, type Side } from './sim/run';
import { canSee } from './sim/sight';

declare const __BUILD__: string;

// URL flags used by tests and by the owner when checking in. More are added as features land.
const params = new URLSearchParams(location.search);
const seed = params.get('seed') ?? 'orientation';
/** ?depth=N starts the run on floor N (the run normally starts at 1). */
const startDepth = Math.max(1, Math.floor(Number(params.get('depth') ?? '1')) || 1);
const debug = params.get('debug') === '1';
// ?preview=orderly[&anim=walk|idle|reach|duck|still] stands an entity model in the level.
const previewName = params.get('preview');
// ?fx=0 clean render, 1 the tape look (default), 2 heavy interference.
const fxParam = Number(params.get('fx') ?? '1');
// A device that lost its picture earlier draws more lightly: 1 = 8-bit and no shadows, 2 = also no tape look.
const safe = readSafeLevel(params);
const fxLevel: FxLevel = safe >= 2 ? 0 : fxParam >= 2 ? 2 : fxParam === 0 ? 0 : 1;
// The live Orderly is on every floor by default. ?entity=0 leaves the floor empty; ?preview=orderly
// shows a static figure instead.
const entityOn = params.get('entity') !== '0' && previewName !== 'orderly';

const canvas = document.getElementById('view') as HTMLCanvasElement;
const hud = document.getElementById('hud') as HTMLDivElement;
const overlay = document.getElementById('start') as HTMLDivElement;
const debugBox = document.getElementById('debug') as HTMLDivElement;

const renderer = new THREE.WebGLRenderer({ canvas, antialias: false, powerPreference: 'high-performance' });
renderer.setPixelRatio(1);
let lastRunEvent = 'none';
const diag = installDiagnostics(renderer, canvas, safe, () => ({
  build: __BUILD__, fx: fxLevel, frames: state.frames, lastRunEvent, phase: run.state.phase, depth: run.state.depth,
  orderlyLoaded: orderlyView?.loaded ?? false, frameMs: stats.median(),
}));

// ---------------------------------------------------------------------------------------------
// The run: one host steps the run's rules, the Orderly and the crew 20 times a second.
const LOCAL_ID = 'local';
const run = new RunHost(seed, LOCAL_ID, entityOn, startDepth);
let plan = run.state.plan;
const world = buildWorld(plan);
const scene = world.scene;
const camera = new THREE.PerspectiveCamera(70, 16 / 9, 0.05, 90);
let elevator = new ElevatorView(run.state.car);
scene.add(elevator.group);

const player = new Player(plan, plan.landing.level, plan.landing.x, plan.landing.y, yawForDir(landingFacing(plan)));
/** Puts the player in the car, in the middle, facing the doors. */
function placeInCar(u = START_U, v = 0): void {
  player.body = carBody(run.state.car, u, v);
  player.yaw = yawForDir(landingFacing(plan));
  player.pitch = 0;
}
placeInCar();
const input = new Input(canvas, overlay);
const autoWalk = new AutoWalk();

let preview: EntityPreview | null = null;
if (previewName === 'orderly') {
  renderer.shadowMap.enabled = safe === 0;
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

let orderlyView: EntityView | null = null;
if (entityOn) {
  renderer.shadowMap.enabled = safe === 0;
  orderlyView = new EntityView(scene, `${import.meta.env.BASE_URL}assets/entities/orderly.glb`);
}
const audio = new GameAudio();
// The elevator's voice (recorded lines through a speaker built in Web Audio). ?subs=0 hides its subtitles;
// so does the clean render (?fx=0), which shows no on-screen display at all (the reference pictures use it).
const announcer = new Announcer(() => audio.context, import.meta.env.BASE_URL, document.body, params.get('subs') !== '0' && fxLevel > 0);
announcer.startRun();
const caughtFx = new CaughtFx(document.body);
const endScreen = new EndScreen(document.body);

// The crew's instruments, the tapes on the floor, and the prompts.
const instrument = new InstrumentView();
const tapeDrops = new TapeDrops(scene);
const pickupPrompt = new PickupPrompt(document.body, () => void tryPickUp());
/** Set by the test hook __gd.raise(); null leaves it to the player's input. */
let forcedRaise: boolean | null = null;
/** Audible ticks the logic produced since the last frame (the needle kicks on each). */
let pendingTicks = 0;

// The elevator's controls: the call button on the landing, the door-hold button in the car.
/** A call is pressed: sent with the next tick. `callBody`, if set, is where the press is made from (tests). */
let pendingCall = false;
let callBody: Body | null = null;
/** Set by runCtl.hold(); null leaves holding the doors to the player. */
let forcedHold: boolean | null = null;
const liftPrompt = new ActionPrompt(document.body, 'lift-prompt', () => {
  if (canCall()) pendingCall = true;
});

function tryPickUp(): { ok: boolean; reason: string; tapeId: string | null } {
  if (caughtFx.noiseOn || endScreen.shown) return { ok: false, reason: 'inactive', tapeId: null };
  return run.pickUp(player.body);
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
// Phones take the 8-bit path from the start: it is the cheaper one and costs nothing visible there.
const tape = new Tape(renderer, fxLevel, INTERNAL_HEIGHT, params.get('hdr') === '0' || safe >= 1 || phoneLike());
const osd = new Osd(document.body, seed);
osd.visible = fxLevel > 0;
/** Lights glare through the tape; the clean render keeps them as built. */
const LIGHT_GAIN = 3;
let lightGain = fxLevel > 0 ? LIGHT_GAIN : 1;
/** The light level last applied (1 all on); applied again only when it changes. */
let appliedLight = { gain: -1, level: -1 };
function setLights(level: number): void {
  if (appliedLight.gain === lightGain && appliedLight.level === level) return;
  appliedLight = { gain: lightGain, level };
  applyLighting(scene, lightGain, level, FOG);
  applyLighting(instrument.scene, 1, 0.25 + 0.75 * level, 0x000000);
}
setLights(1);
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
function frameSees(v: PlayerView, h: RunHost, ev: EntityView): boolean {
  const o = h.orderly;
  if (canSee(plan, v, o.body, { height: ORDERLY_HEIGHT, radius: ORDERLY_RADIUS })) return true;
  const ext = (anim: OrderlyAnim): number => Math.max(ORDERLY_RADIUS, ev.extent(anim));
  // The mesh is taller than the logic's figure too (cap at 2.82 m against 2.6 m).
  const height = ORDERLY_HEIGHT + MESH_EXTRA_HEIGHT;
  // Widest of the clip the logic asks for and the clip on screen (a held reach pose, say).
  const reach = Math.max(ext(o.anim), ev.drawn ? ext(ev.drawn.anim) : 0);
  const seenWide = canSee(plan, v, o.body, { height, radius: reach });
  if (seenWide) {
    // Only the overhang is in view. Hand the logic this view with the field of view widened by
    // just the overhang's angle, so it holds the figure too (decided in the player's favour).
    const dist = Math.max(0.2, Math.hypot(o.body.x - v.body.x, o.body.z - v.body.z));
    const extra = (Math.atan2(reach - ORDERLY_RADIUS + MESH_EXTRA_HEIGHT, dist) / DEG + 1) * 2;
    h.noteSeen({ ...v, hFovDeg: v.hFovDeg + extra, vFovDeg: v.vFovDeg + extra });
    return true;
  }
  const d = ev.drawn;
  if (!d) return false;
  const body: Body = { x: d.x, y: d.y, z: d.z, level: d.y >= LEVEL_HEIGHT - 0.01 ? 1 : o.body.level };
  return canSee(plan, v, body, { height, radius: Math.max(ext(d.anim), ext(o.anim)) });
}

/** The pose to hold when it is first seen: the logic's exact pose, reaching if it froze within reach of you. */
function freezePose(s: OrderlyState): DrawnPose {
  const p = exactPose(s);
  const b = player.body;
  const near = b.level === s.body.level && Math.hypot(b.x - s.body.x, b.z - s.body.z) <= REACH_RANGE;
  if (near && p.anim !== 'reach' && (s.mode === 'hunting' || s.mode === 'windUp')) return { ...p, anim: 'reach', animTime: WIND_UP_TIME * 0.85 };
  return p;
}

// ---------------------------------------------------------------------------------------------
// The elevator on screen and in the ears.

/** The indicator's name for a floor: B1, B2 ... below ground, G at ground, 1, 2 ... above. */
function floorLabel(floor: number): string {
  if (floor >= 1) return floor < 10 ? `B${floor}` : String(floor);
  return floor === 0 ? 'G' : String(-floor);
}

/** After the car leaves empty, the indicator climbs away for a few floors (cosmetic: the logic does not track it). */
let leftAt = -1;
const LEAVE_FLOORS = 5;
const LEAVE_FLOOR_MS = 1300;
/** performance.now() of the last floor-change the indicator showed (for the riding count). */
let rideStartedAt = -1;
/** How the run ended for this player, once it has; the screen follows after a short beat. */
let ending: { kind: 'banked' | 'wiped' | 'leftBehind'; at: number; summary: RunSummary | null; lost?: number } | null = null;
/** Totals across runs, kept in this browser. */
const LIFETIME_KEY = 'goingDown.lifetime';
function readLifetime(): number {
  try {
    return Number(localStorage.getItem(LIFETIME_KEY) ?? '0') || 0;
  } catch {
    return 0;
  }
}
let lifetime = readLifetime();
function addLifetime(v: number): void {
  lifetime += v;
  try {
    localStorage.setItem(LIFETIME_KEY, String(lifetime));
  } catch {
    /* private window: the total lives only this session */
  }
}
/** Seconds of bell countdown at which the warning dings sound. */
const BELL_WARNINGS = [5, 3];
/** Seconds before the doors close that the announcer's bell line starts, so it ends near the bell. */
const ANNOUNCE_BELL_AT = 7;
let prevBellLeft = BOARD_TIME;
/** Readings closed so far on each floor depth (tests: the depth multiplier). */
let lastReadingDepth = 1;

function localSide(): Side | null {
  return run.state.players.find((p) => p.id === LOCAL_ID)?.side ?? null;
}

function canCall(): boolean {
  const s = run.state;
  if (s.phase !== 'away' || caughtFx.noiseOn || endScreen.shown) return false;
  const b = player.body;
  return b.level === s.car.level && !inCar(s.car, b) && Math.hypot(b.x - s.car.doorX, b.z - s.car.doorZ) <= CALL_REACH - 0.05;
}

function nearHoldButton(): boolean {
  const s = run.state;
  if (s.phase !== 'boarding' || !inCar(s.car, player.body)) return false;
  const { u, v } = carLocal(s.car, player.body.x, player.body.z);
  return Math.hypot(u - 0.3, v - HOLD_BUTTON.x) <= 0.75;
}

/** What the car is doing, in one word. */
function carState(): 'arriving' | 'open' | 'away' | 'coming' | 'riding' | 'ended' {
  const p = run.state.phase;
  if (p === 'unloading' || p === 'boarding') return 'open';
  if (p === 'arriving') return 'arriving';
  if (p === 'away') return 'away';
  if (p === 'coming') return 'coming';
  if (p === 'riding') return 'riding';
  return 'ended';
}

/** Seconds until the car arrives (while it is coming), else null. */
function eta(): number | null {
  const c = run.state.call;
  return run.state.phase === 'coming' && c ? Math.max(0, c.at + c.plan.wait - run.state.t) : null;
}

/** The lights warn of a blink (announced, not yet dark). */
function blinkWarning(): boolean {
  const b = run.state.blink;
  return b !== null && b.announced && b.endsAt === null;
}

/** Updates the indicator from the run (and, when the car has left empty, its cosmetic climb). */
function showIndicator(now: number): void {
  const s = run.state;
  const here = floorLabel(s.depth);
  switch (s.phase) {
    case 'arriving':
    case 'unloading':
    case 'boarding':
      elevator.setIndicator(here, true, 0);
      break;
    case 'coming': {
      const c = s.call;
      const label = floorLabel(s.depth - (c?.floorsAway ?? 0));
      // A false stop: the car sits one floor up, the arrow off.
      elevator.setIndicator(label, true, c && c.stopUntil !== null ? 0 : -1);
      break;
    }
    case 'away': {
      const k = leftAt < 0 ? LEAVE_FLOORS : Math.min(LEAVE_FLOORS, Math.floor((now - leftAt) / LEAVE_FLOOR_MS) + 1);
      elevator.setIndicator(floorLabel(s.depth - k), k < LEAVE_FLOORS, k < LEAVE_FLOORS ? 1 : 0);
      break;
    }
    case 'riding': {
      const half = rideStartedAt >= 0 && now - rideStartedAt > (RIDE_TIME * 1000) / 2;
      elevator.setIndicator(floorLabel(s.depth + (half ? 1 : 0)), true, -1);
      break;
    }
    default:
      elevator.setIndicator('', false, 0);
  }
}

/** After every logic tick: count the instrument's audible ticks, and follow the run if it moved the player. */
function afterTick(events: readonly RunEvent[]): void {
  pendingTicks += run.member()?.instrument.ticks ?? 0;
  // The bell's warning dings, as the boarding countdown passes them (tick by tick, so a skip hears them too).
  const s = run.state;
  if (s.phase === 'boarding') {
    for (const w of BELL_WARNINGS) if (prevBellLeft > w && s.bellLeft <= w) audio.bellWarning();
    if (prevBellLeft > ANNOUNCE_BELL_AT && s.bellLeft <= ANNOUNCE_BELL_AT) announcer.bellSoon();
    prevBellLeft = s.bellLeft;
  }
  syncBodies(events);
}

/** The run moved the player (pushed out of the doorway, carried to a new floor): follow it, tick by tick. */
function syncBodies(events: readonly RunEvent[]): void {
  for (const e of events) {
    lastRunEvent = e.type;
    diag.note(e.type);
    if (e.type === 'doorsClosed') {
      const b = e.pushedOut[LOCAL_ID];
      if (b) player.body = { ...b };
    } else if (e.type === 'rodeDown') {
      newFloor();
      const b = e.bodies[LOCAL_ID];
      if (b) player.body = { ...b };
    }
  }
}

/** The run is on a new plan (rode down, or a new run): rebuild everything that belongs to a floor. */
function newFloor(): void {
  if (run.state.plan === plan) return;
  plan = run.state.plan;
  replaceFloor(world, plan);
  elevator.dispose();
  elevator = new ElevatorView(run.state.car);
  scene.add(elevator.group);
  elevator.setDoors(doorsOpen(run.state), true);
  appliedLight = { gain: -1, level: -1 };
  autoWalk.cancel('new floor');
  carWalk = null;
  trace.length = 0;
  if (minimap) {
    minimap.canvas.remove();
    minimap = new Minimap(plan);
    debugBox.append(minimap.canvas);
  }
  hud.textContent = `Going Down  build ${__BUILD__}  seed ${seed}  depth ${run.state.depth}`;
}

/** A new run, without reloading: the car, the floor, the tapes and the Orderly start over. */
function restartRun(): void {
  run.restart(startDepth);
  newFloor();
  placeInCar();
  elevator.setDoors(false, true);
  elevator.setVote(null);
  elevator.setCallLit(false);
  elevator.setHoldLit(false);
  caughtFx.reset();
  endScreen.hide();
  ending = null;
  leftAt = -1;
  rideStartedAt = -1;
  pendingCall = false;
  callBody = null;
  autoWalk.cancel('new run');
  carWalk = null;
  audio.resetLift();
  tape.setDarkness(0);
  prevBellLeft = BOARD_TIME;
  announcer.startRun();
  runs++;
}
let runs = 1;

function summaryLines(s: RunSummary): EndLine[] {
  const n = (v: number): string => String(Math.floor(v)).padStart(4, '0');
  return [
    { text: 'BANKED', strong: true },
    { text: '' },
    { text: `FLOORS ${s.depth}` },
    { text: `READINGS ${s.readings}` },
    { text: `TOTAL ${n(s.total)}`, strong: true },
    { text: `YOUR SHARE ${n(s.shares[LOCAL_ID] ?? 0)}`, strong: true },
    { text: '' },
    { text: `LIFETIME ${n(lifetime)}` },
    { text: '' },
    { text: input.touch ? 'TAP FOR A NEW RUN' : 'PRESS A KEY FOR A NEW RUN' },
  ];
}

function showEnd(now: number): void {
  if (!ending || endScreen.shown) return;
  const wait = ending.kind === 'banked' ? 2600 : ending.kind === 'wiped' ? NOISE_MS + 200 : 1500;
  if (now - ending.at < wait) return;
  audio.ride(false);
  const again = { text: input.touch ? 'TAP FOR A NEW RUN' : 'PRESS A KEY FOR A NEW RUN' };
  if (ending.kind === 'banked' && ending.summary) endScreen.show(summaryLines(ending.summary));
  else if (ending.kind === 'wiped') {
    endScreen.show([
      { text: 'NOBODY CAME BACK UP', strong: true },
      { text: '' },
      { text: `FLOORS ${ending.summary?.depth ?? run.state.depth}` },
      { text: 'NOTHING BANKED' },
      { text: '' },
      { text: `LIFETIME ${String(Math.floor(lifetime)).padStart(4, '0')}` },
      { text: '' },
      again,
    ]);
  } else {
    endScreen.show([{ text: 'THE CAR WENT DOWN WITHOUT YOU', strong: true }, { text: '' }, again]);
  }
  document.exitPointerLock?.();
}

// A key or a tap on the end screen starts a new run (after a moment, so a held key does not skip it).
const END_LOCK_MS = 1200;
function endInput(): void {
  if (endScreen.shown && performance.now() - endScreen.shownAt > END_LOCK_MS) restartRun();
}
window.addEventListener('keydown', () => endInput());
endScreen.el.addEventListener('pointerdown', (e) => {
  e.stopPropagation();
  endInput();
});

/** Events that change what is seen and heard (sounds, doors, the end), after the ticks that made them. */
function present(events: readonly RunEvent[], now: number): void {
  const s = run.state;
  const orderlyEvs: OrderlyEvent[] = [];
  const crewEvs: CrewEvent[] = [];
  announcer.onEvents(events, startDepth);
  for (const e of events) {
    if (isOrderlyEvent(e)) {
      orderlyEvs.push(e);
      continue;
    }
    if (isCrewEvent(e)) {
      crewEvs.push(e);
      continue;
    }
    switch (e.type) {
      case 'doorsOpened':
        elevator.setDoors(true);
        audio.doors(true);
        break;
      case 'doorsClosed':
        elevator.setDoors(false);
        audio.doors(false);
        break;
      case 'carLeft':
        if (e.reason === 'ride') {
          rideStartedAt = now;
          audio.ride(true, RIDE_TIME);
        } else leftAt = now;
        break;
      case 'called':
        elevator.setCallLit(true);
        audio.callChime();
        break;
      case 'indicator': {
        const total = s.call?.plan.floors ?? e.floorsAway;
        audio.floorDing(total > 0 ? 1 - e.floorsAway / total : 1);
        break;
      }
      case 'falseStop':
        audio.callChime(true);
        break;
      case 'falseStopDoors':
        audio.doors(e.open, true);
        break;
      case 'blinkSoon':
        audio.blinkWarning();
        break;
      case 'blinkStart':
        audio.blink(true);
        break;
      case 'blinkEnd':
        audio.blink(false);
        break;
      case 'carArrived':
        elevator.setCallLit(false);
        prevBellLeft = BOARD_TIME;
        break;
      case 'holdChanged':
        elevator.setHoldLit(e.held);
        break;
      case 'bell':
        audio.bell();
        elevator.setHoldLit(false);
        break;
      case 'voteChanged':
        if (e.playerId === LOCAL_ID) elevator.setVote(e.side);
        break;
      case 'rodeDown':
        audio.ride(false);
        rideStartedAt = -1;
        elevator.setVote(null);
        break;
      case 'banked':
        addLifetime(e.summary.total);
        ending = { kind: 'banked', at: now, summary: e.summary };
        audio.ride(true, 3);
        elevator.setVote(null);
        break;
      case 'wiped':
        ending = { kind: 'wiped', at: now, summary: e.summary };
        break;
      case 'leftBehind':
        if (e.playerId === LOCAL_ID) ending = { kind: 'leftBehind', at: now, summary: null, lost: e.lostValue };
        break;
      default:
        break;
    }
  }
  for (const e of orderlyEvs) {
    if (e.type !== 'caught' || e.playerId !== LOCAL_ID) continue;
    // Placeholder: interference, noise, and back to the landing (caughtFx decides when).
    catches++;
    tape.glitch(NOISE_MS + 500, 1);
    caughtFx.start(now);
    audio.caughtBurst();
  }
  for (const e of crewEvs) {
    if (e.playerId !== LOCAL_ID) continue;
    if (e.type === 'slip') {
      instrument.printSlip(e.text);
      audio.slipPrinted();
    } else if (e.type === 'readingClosed') {
      audio.readingClosed();
      lastReadingDepth = s.depth;
    }
  }
}

// ---------------------------------------------------------------------------------------------
// Walking in and out of the car (tests): straight lines through the doorway with the run's collision.
let carWalk: { points: { u: number; v: number }[]; resolve: () => void; reject: (e: Error) => void; stuck: number } | null = null;

function startCarWalk(u: number, v: number): Promise<void> {
  carWalk?.reject(new Error('replaced by a new walk'));
  autoWalk.cancel('car walk');
  const car = run.state.car;
  const here = carLocal(car, player.body.x, player.body.z);
  const inside = (p: { u: number }): boolean => p.u > 0;
  const points: { u: number; v: number }[] = [];
  if (inside(here) !== inside({ u })) {
    if (inside(here)) points.push({ u: 0.45, v: 0 }, { u: -0.6, v: 0 });
    else points.push({ u: -0.6, v: 0 }, { u: 0.45, v: 0 });
  }
  points.push({ u, v });
  return new Promise<void>((resolve, reject) => {
    carWalk = { points, resolve, reject, stuck: 0 };
  });
}

function stepCarWalk(dt: number): void {
  const w = carWalk;
  if (!w) return;
  const car = run.state.car;
  const target = w.points[0];
  if (!target) {
    carWalk = null;
    w.resolve();
    return;
  }
  const here = carLocal(car, player.body.x, player.body.z);
  const du = target.u - here.u;
  const dv = target.v - here.v;
  const dist = Math.hypot(du, dv);
  if (dist < 0.03) {
    w.points.shift();
    return;
  }
  const step = Math.min(dist, WALK_SPEED * dt);
  const wx = car.inX * du + car.rightX * dv;
  const wz = car.inZ * du + car.rightZ * dv;
  const before = player.body;
  player.body = moveInRun(run.state, before, (wx / dist) * step, (wz / dist) * step, 0.3);
  player.yaw = yawToward(wx, wz);
  if (Math.hypot(player.body.x - before.x, player.body.z - before.z) < step * 0.2) {
    if ((w.stuck += dt) > 1.5) {
      carWalk = null;
      w.reject(new Error('car walk stuck (doors shut?)'));
    }
  } else w.stuck = 0;
}

// ---------------------------------------------------------------------------------------------
// The input for one logic tick.
let wantRaisedNow = false;
let holdNow = false;
function tickInput(): PlayerInput {
  const v = localView();
  const inp: PlayerInput = { id: LOCAL_ID, body: v.body, eye: v.eye, yaw: v.yaw, pitch: v.pitch, hFovDeg: v.hFovDeg, vFovDeg: v.vFovDeg, raised: wantRaisedNow };
  if (pendingCall) {
    inp.call = true;
    if (callBody) inp.body = { ...callBody };
    pendingCall = false;
    callBody = null;
  }
  if (holdNow) inp.holdDoors = true;
  return inp;
}

function orderlyInfo() {
  if (!orderlyView) return null;
  const s = run.orderly;
  const c = cellOf(plan, s.body);
  const b = player.body;
  const d = orderlyView.drawn;
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
    loaded: orderlyView.loaded,
    drawn: d ? { x: d.x, y: d.y, z: d.z, yaw: d.yaw / DEG, anim: d.anim, animTime: d.animTime, frozen: orderlyView.isFrozen } : null,
  };
}

/** A cheap fingerprint of the floor plan, so a test can tell floors apart. */
function planKey(): string {
  let h = 2166136261;
  for (const level of plan.cells) for (const c of level) h = Math.imul(h ^ c.charCodeAt(0), 16777619);
  return `${plan.width}x${plan.height}:${(h >>> 0).toString(16)}`;
}

function runInfo() {
  const s = run.state;
  const me = s.players.find((p) => p.id === LOCAL_ID);
  const c = s.call;
  return {
    phase: s.phase,
    depth: s.depth,
    t: s.t,
    car: carState(),
    doorsOpen: doorsOpen(s),
    /** The doors as drawn: 0 shut .. 1 open. */
    doors: elevator.status().doors,
    indicator: { floorsAway: c?.floorsAway ?? 0, label: elevator.status().indicator, falseStop: c ? c.stopUntil !== null : false },
    eta: eta(),
    blink: blinking(s),
    blinkSoon: blinkWarning(),
    vote: me?.side ?? null,
    aboard: me?.aboard ?? false,
    status: me?.status ?? 'ok',
    bellLeft: s.bellLeft,
    holdLeft: s.holdLeft,
    held: s.held,
    calls: s.calls,
    banked: s.summary && !s.summary.wiped ? s.summary.total : 0,
    summary: s.summary,
    lifetime,
    multiplier: depthMultiplier(s.depth),
    lastReadingDepth,
    planKey: planKey(),
    ended: ending?.kind ?? null,
    endShown: endScreen.shown,
    endText: endScreen.text,
    runs,
    softCatches: run.softCatches,
    callPrompt: !liftPrompt.el.hidden && canCall(),
    holdPrompt: !liftPrompt.el.hidden && nearHoldButton(),
    lightLevel: appliedLight.level,
    car3: { doorX: s.car.doorX, doorZ: s.car.doorZ, inX: s.car.inX, inZ: s.car.inZ, rightX: s.car.rightX, rightZ: s.car.rightZ, level: s.car.level },
  };
}

/** Events from runCtl.skip, presented on the next frame. */
const skipped: RunEvent[] = [];

// Test hooks. Yaw is in degrees: 0 faces north (-z), 90 west, 180 south, -90 east.
const state = {
  ready: false,
  frames: 0,
  build: __BUILD__,
  seed,
  get depth() {
    return run.state.depth;
  },
  gpu: gpuName(),
  probeColours,
  probePixels,
  /** The floor plan the run is on now. */
  get plan() {
    return plan;
  },
  player: () => {
    const c = cellOf(plan, player.body);
    return { ...player.body, eye: player.body.y + EYE_HEIGHT, cx: c.x, cy: c.y, yaw: player.yaw / DEG, pitch: player.pitch / DEG, inCar: inCar(run.state.car, player.body) };
  },
  teleport: (level: Level, cx: number, cy: number, yawDegrees?: number) => {
    autoWalk.cancel('teleported');
    carWalk = null;
    player.teleport(plan, level, cx, cy, yawDegrees === undefined ? undefined : yawDegrees * DEG);
  },
  look: (yawDegrees: number, pitchDegrees = 0) => {
    player.yaw = yawDegrees * DEG;
    player.pitch = pitchDegrees * DEG;
  },
  walkTo: (level: Level, cx: number, cy: number) => {
    if (inCar(run.state.car, player.body)) return Promise.reject(new Error('in the elevator car: step out first (runCtl.walkCar)'));
    return autoWalk.start(plan, player, { level, x: cx, y: cy });
  },
  frameMs: () => stats.median(),
  /** Tape strength: 0 clean, 1 default, 2 heavy. */
  fx: () => tape.fx,
  setFx: (level: number) => {
    const l = tape.setFx(level);
    osd.visible = l > 0;
    lightGain = l > 0 ? LIGHT_GAIN : 1;
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
  events: (): OrderlyEvent[] => (orderlyView ? run.orderlyEvents.map((e) => ({ ...e })) : []),
  catches: () => catches,
  caught: () => ({ noise: caughtFx.noiseOn, line: caughtFx.lineOn }),
  /** Test controls for the live Orderly (null with ?entity=0). */
  entityCtl: orderlyView && {
    placeCell: (level: Level, cx: number, cy: number, yawDegrees?: number) => {
      const o = run.orderly;
      const body = bodyAtCell(plan, { level, x: cx, y: cy });
      run.replaceOrderly({ ...o, body, yaw: yawDegrees === undefined ? o.yaw : yawDegrees * DEG, path: null, replanIn: 0 });
    },
    placeAt: (x: number, z: number, level: Level = 0, yawDegrees?: number) => {
      const o = run.orderly;
      const body = { x, z, level, y: level === 1 ? LEVEL_HEIGHT : 0 };
      run.replaceOrderly({ ...o, body, yaw: yawDegrees === undefined ? o.yaw : yawDegrees * DEG, path: null, replanIn: 0 });
    },
    /** Ends its waiting (or dormancy): it hunts on the next tick it is free to act. */
    wake: () => {
      const o = run.orderly;
      if (o.mode === 'waiting' || o.mode === 'dormant') run.replaceOrderly({ ...o, mode: 'hunting', dormantLeft: 0, replanIn: 0, path: null });
    },
    /** Puts it to rest (dormant) for `seconds` of logic time, where it stands. */
    rest: (seconds: number) => {
      run.replaceOrderly({ ...run.orderly, mode: 'dormant', dormantLeft: seconds, path: null, moving: false, speed: 0 });
    },
    /** Logic seconds per real second: the whole run's clock (the Orderly is stepped by the run). */
    setTimeScale: (k: number) => {
      run.timeScale = Math.max(0, k);
    },
    /** Per-frame records: drawn position (dx, dz) against the logic's (lx, lz), and visibility. */
    trace: () => trace.slice(),
    /** Widest reach of the mesh from its feet axis per clip, metres (measured at load). */
    extents: () => Object.fromEntries(['idle', 'walk', 'duck', 'reach', 'still'].map((n) => [n, orderlyView?.model.extent(n) ?? 0])),
    ticks: () => run.ticks,
  },
  audio: { state: () => audio.state() },
  /** The announcer: what is playing, waiting and said this run; say(id) asks for a line (false if it cannot). */
  announcer: { state: () => announcer.state(), say: (id: string) => announcer.say(id) },
  /** The local player's instrument: the logic's state and what is drawn. */
  instrument: () => {
    const m = run.member();
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
      total: run.held(),
      own: tapeValue(m.tape),
      tickHz: i.tickHz,
      loudness: i.loudness,
      /** Tapes held with something on them. */
      tapes: run.heldCount(),
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
    run.state.crew.floor.map((f) => {
      const c = cellOf(plan, f.at);
      return { id: f.tape.id, value: f.tape.total, readings: f.tape.readings.length, x: f.at.x, y: f.at.y, z: f.at.z, level: f.at.level, cx: c.x, cy: c.y };
    }),
  /** Tries to pick up the nearest tape within reach. */
  pickUp: () => tryPickUp(),
  /** Every crew event (slip, readingClosed, tapeDropped, tapePickedUp) so far. */
  crewEvents: (): CrewEvent[] => run.crewEvents.map((e) => ({ ...e })),
  /** Whether the pick-up prompt is showing. */
  pickupShown: () => !pickupPrompt.el.hidden,
  /** The run: phase, depth, the car, the indicator, the blink, the vote, the totals. */
  run: runInfo,
  /** Every run event so far (the last few thousand), with its type and time. */
  runEvents: (): { type: string; t: number }[] => run.runEvents.map((e) => ({ ...e })),
  /** Test controls for the run. */
  runCtl: {
    /** Presses the call button (from where the player stands; `force` presses it from the landing wherever they are). */
    call: (opts: { force?: boolean } = {}) => {
      const ok = run.state.phase === 'away' && (opts.force === true || canCall());
      if (ok) {
        pendingCall = true;
        if (opts.force) callBody = carBody(run.state.car, -0.8, 0);
      }
      return ok;
    },
    /** Holds the doors (true), lets go (false), or hands it back to the player (null). */
    hold: (on: boolean | null) => {
      forcedHold = on;
    },
    /** Logic seconds per real second (the whole run). */
    setTimeScale: (k: number) => {
      run.timeScale = Math.max(0, k);
    },
    /** Runs `seconds` of logic now, tick by tick through stepRun, the player standing as they are. */
    skip: (seconds: number) => {
      const evs = run.skip(seconds, tickInput, (e) => afterTick(e));
      skipped.push(...evs);
      return evs.map((e) => e.type);
    },
    /** Runs logic tick by tick until an event of this type, or `max` seconds. Returns whether it came. */
    skipUntil: (type: string, max = 120) => {
      let hit = false;
      const evs = run.skip(max, tickInput, (e) => {
        afterTick(e);
        hit = e.some((x) => x.type === type);
        return hit;
      });
      skipped.push(...evs);
      return hit;
    },
    /** Walks to car-local (u into the car, v to the right walking in), through the doorway if need be. */
    walkCar: (u: number, v: number) => startCarWalk(u, v),
    /** Starts a new run now (as the end screen's key does). */
    restart: () => restartRun(),
    /** A side of the car's floor in car-local metres: [u, v] of its middle. */
    spot: (side: Side) => (side === 'bank' ? [1.1, -0.5] : [1.1, 0.5]),
  },
};
(window as unknown as { __gd: typeof state }).__gd = state;
hud.textContent = `Going Down  build ${__BUILD__}  seed ${seed}  depth ${run.state.depth}`;
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
  const s0 = run.state;
  const ended = s0.phase === 'ended' || endScreen.shown;

  preview?.update(dt);
  // The instrument is up only while held (or forced by a test), never while the picture is noise.
  wantRaisedNow = !caughtFx.noiseOn && !ended && (forcedRaise ?? input.instrumentHeld());
  run.setRaised(wantRaisedNow);
  const raised = run.member()?.instrument.raised ?? false;
  const mover = (b: Body, dx: number, dz: number, r: number): Body => moveInRun(run.state, b, dx, dz, r);
  if (carWalk) stepCarWalk(dt);
  else if (autoWalk.active) autoWalk.tick(plan, player);
  else if (!caughtFx.noiseOn && !ended) player.control(plan, input, dt, raised ? maxWalkSpeed(true, WALK_SPEED) : Infinity, mover);
  else {
    input.takeLook();
    player.lastSpeed = 0;
  }
  if (caughtFx.update(now, ending?.kind !== 'wiped')) {
    if (ending?.kind !== 'wiped') {
      // Back at the elevator landing, facing out, as on arrival.
      autoWalk.cancel('caught');
      carWalk = null;
      player.teleport(plan, plan.landing.level, plan.landing.x, plan.landing.y, yawForDir(landingFacing(plan)));
      player.pitch = 0;
    }
  }
  player.toCamera(camera);

  // The elevator's controls.
  const callable = canCall();
  const holdable = nearHoldButton();
  liftPrompt.update((callable || holdable) && !ended, input.touch, callable ? '▼' : '<|>');
  const ePressed = input.takePress('KeyE');
  if (ePressed && callable) pendingCall = true;
  holdNow = forcedHold ?? (holdable && (input.down('KeyE') || liftPrompt.held));

  const v = localView();
  const dark = blinking(run.state);
  // 1. A glance on this frame counts, even if no tick lands on it (not in the dark: nobody can see).
  let vis = false;
  if (orderlyView && !dark) {
    vis = frameSees(v, run, orderlyView);
    run.noteSeen(v);
  }
  const events = skipped.splice(0);
  events.push(...run.advance(dt, tickInput, (e) => afterTick(e)));
  present(events, now);
  if (events.some((e) => e.type === 'rodeDown' || e.type === 'doorsClosed')) player.toCamera(camera);

  const s = run.state;
  const darkNow = blinking(s);
  if (orderlyView) {
    // 2. After the ticks: it may have stepped into view.
    orderlyLogicSeen = !darkNow && run.sees(v);
    if (orderlyLogicSeen) run.noteSeen(v);
    vis = !darkNow && (vis || frameSees(v, run, orderlyView));
    orderlyVisible = vis;
    // 3. Seen: exactly where the logic has it, clock stopped. Unseen (or in the dark): smoothed between ticks.
    // Walking clips run on the stride clock, which follows its speed: a creep is a slow stride.
    const smooth = blendPose(run.prevOrderly, run.orderly, run.alpha);
    if (smooth.anim === 'walk' || smooth.anim === 'duck') smooth.animTime = run.stride();
    const hold = freezePose(run.orderly);
    if (hold.anim === 'walk' || hold.anim === 'duck') hold.animTime = run.curStride;
    orderlyView.update(vis, smooth, hold);
    const d = orderlyView.drawn;
    if (d) {
      trace.push({ f: state.frames + 1, vis, dx: d.x, dz: d.z, lx: run.orderly.body.x, lz: run.orderly.body.z, t: run.orderly.t, anim: d.anim, clip: d.animTime });
      if (trace.length > 600) trace.shift();
    }
    // Sound: silent the instant it is seen, whatever the next tick says. Heard in the dark if it moves.
    const away = s.phase === 'riding' || s.phase === 'ended';
    squeak = vis || run.orderly.held || away ? { gain: 0, muffled: false } : audibility(plan, run.orderly, { body: player.body, eye: EYE_HEIGHT });
    const src = d ?? exactPose(run.orderly);
    camForward.set(0, 0, -1).applyQuaternion(camera.quaternion);
    camUp.set(0, 1, 0).applyQuaternion(camera.quaternion);
    audio.update(dt, squeak.gain, squeak.muffled, { x: src.x, y: src.y + SQUEAK_HEIGHT, z: src.z }, camera.position, camForward, camUp, run.orderly.speed);
  }

  // The elevator: doors, indicator, vote, the bell's warnings, the machinery, and the lights.
  showIndicator(now);
  const c = s.call;
  const machine = s.phase === 'coming' && c ? (1 - c.floorsAway / Math.max(1, c.plan.floors)) * (c.stopUntil !== null ? 0.5 : 1) + 0.05 : 0;
  audio.machinery(machine, { x: s.car.doorX, y: s.car.floorY + 1.5, z: s.car.doorZ });
  // The blink: a flicker through the warning, then a deep dark with tape noise, then the lights back.
  let light = 1;
  if (darkNow) light = 0.07;
  // The warning: the tubes sag and stutter (never back to full), so a glance at any moment of it shows trouble.
  else if (blinkWarning()) light = Math.floor(now / 55) % 4 === 1 || Math.floor(now / 140) % 3 === 2 ? 0.18 : 0.6;
  setLights(light);
  tape.setDarkness(darkNow ? 1 : 0);
  // The announcer: close in the car, from the speaker over the landing doors out on the floor.
  camForward.set(0, 0, -1).applyQuaternion(camera.quaternion);
  announcer.update({
    depth: s.depth,
    inCar: inCar(s.car, player.body),
    ear: camera.position,
    forward: camForward,
    speaker: { x: s.car.doorX, y: s.car.floorY + 2.3, z: s.car.doorZ },
    quiet: !darkNow && !blinkWarning() && !run.member()?.instrument.current && !caughtFx.noiseOn && !ended,
  });
  elevator.update(dt, light, lightGain);

  // The instrument, its sound, the tapes on the floor and the tape count.
  const inst = run.member()?.instrument;
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
  tapeDrops.sync(s.crew.floor);
  tapeDrops.update(dt);
  osd.setTapes(run.heldCount(), run.held());
  const inReach = !caughtFx.noiseOn && !ended && run.tapeInReach(player.body) !== null;
  pickupPrompt.update(inReach && !callable, input.touch);
  if (ePressed && inReach && !callable) tryPickUp();

  showEnd(now);
  tape.render(scene, camera, instrument.visible ? instrument : null);
  osd.update(!tape.motion || Math.floor(now / 700) % 2 === 0);
  state.frames++;
  state.ready = true;

  if (debug && state.frames % 10 === 0) {
    const b = player.body;
    const cc = cellOf(plan, b);
    const fm = stats.median();
    const e = eta();
    debugText.textContent =
      `fps ${fm > 0 ? (1000 / fm).toFixed(0) : '-'}  median ${fm.toFixed(1)} ms\n` +
      `tape fx${tape.fx}${tape.motion ? '' : ' (reduced motion)'}\n` +
      `pos ${b.x.toFixed(2)} ${b.y.toFixed(2)} ${b.z.toFixed(2)}\n` +
      `cell L${cc.level} (${cc.x},${cc.y})  yaw ${(player.yaw / DEG).toFixed(0)}\n` +
      `run ${s.phase}  depth ${s.depth}  car ${carState()}${e !== null ? `  eta ${e.toFixed(1)} s` : ''}${darkNow ? '  BLINK' : blinkWarning() ? '  blink soon' : ''}\n` +
      `vote ${localSide() ?? '-'}${s.phase === 'boarding' ? `  bell ${s.bellLeft.toFixed(1)} s  hold ${s.holdLeft.toFixed(1)} s${s.held ? ' HELD' : ''}` : ''}`;
    let ent: { level: Level; x: number; z: number; seen: boolean } | null = null;
    if (orderlyView) {
      const o = run.orderly;
      const dist = Math.hypot(o.body.x - b.x, o.body.z - b.z);
      debugText.textContent +=
        `\norderly ${o.mode}${o.frozen ? ' frozen' : ''}  ${orderlyVisible ? 'SEEN' : 'unseen'}  ${dist.toFixed(1)} m\n` +
        `squeak ${squeak.gain.toFixed(2)}${squeak.muffled ? ' muffled' : ''}  audio ${audio.state().running ? 'on' : 'off'}  catches ${catches}`;
      ent = { level: o.body.level, x: o.body.x, z: o.body.z, seen: orderlyVisible };
    }
    if (inst) {
      debugText.textContent +=
        `\ninstrument ${inst.raised ? 'up' : 'down'} ${inst.needle}  value ${(inst.current?.value ?? 0).toFixed(1)}  tick ${inst.tickHz.toFixed(1)} Hz\n` +
        `tapes held ${run.heldCount()} worth ${run.held().toFixed(1)}  on floor ${s.crew.floor.length}`;
    }
    const floorTapes = s.crew.floor.map((f) => ({ level: f.at.level, x: f.at.x, z: f.at.z }));
    minimap?.update(cc.level, b.x, b.z, player.yaw, ent, floorTapes);
  }
});
