import * as THREE from 'three';
import { Announcer } from './game/announcer';
import { GameAudio } from './game/audio';
import { SettingsStore, type TapeLook } from './game/settings';
import { SettingsPanel } from './render/settingsPanel';
import { AutoWalk } from './game/autoWalk';
import { Minimap } from './game/minimap';
import { installDiagnostics, phoneLike, readSafeLevel } from './game/diagnostics';
import { FrameStats } from './game/frameStats';
import { Input } from './game/input';
import { EYE_HEIGHT, Player, WALK_SPEED, yawForDir, yawToward } from './game/player';
import { HostRules, isCrewEvent, isOrderlyEvent, startBody } from './game/runHost';
import { blinkingView, blinkWarningView, CallTracker, clientView, doorsOpenView, hostView, type RunView } from './game/runView';
import { ActionPrompt } from './render/actionPrompt';
import { CaughtFx, NOISE_MS } from './render/caughtFx';
import { CrewFigures, type CrewFigureState } from './render/crewFigures';
import { CrewList, type CrewRow } from './render/crewList';
import { ElevatorView, HOLD_BUTTON } from './render/elevator';
import { EndScreen, type EndLine } from './render/endScreen';
import { EntityPreview } from './render/entityPreview';
import { EntityView, type DrawnPose } from './render/entityView';
import { InstrumentView } from './render/instrumentView';
import { applyLighting } from './render/lighting';
import { cleanName, Lobby } from './render/lobby';
import { PickupPrompt } from './render/pickupPrompt';
import { TapeDrops } from './render/tapeDrops';
import { Osd } from './render/osd';
import { Tape, type FxLevel } from './render/tape';
import { buildWorld, FOG, replaceFloor } from './render/world';
import { BroadcastTransport } from './net/broadcastTransport';
import type { Frame, LocalFrame, NetClient } from './net/client';
import { CrewSession } from './net/crew';
import type { Pose } from './net/protocol';
import { carFor, moveLocal, planFor, TICK } from './net/session';
import type { Transport } from './net/transport';
import { audibility, HUNT_SPEED, REACH_RANGE, SQUEAK_HEIGHT, WIND_UP_TIME, type OrderlyEvent, type OrderlyState } from './sim/entity';
import { isWalkable, type FloorPlan, type Level } from './sim/floor';
import { LOUDNESS_MAX, LOUDNESS_MIN, LOUDNESS_REST, maxWalkSpeed, member, PICKUP_REACH, pickUpTape, setRaised, TICK_SCALE, tapeValue, type CrewEvent, type Instrument } from './sim/instrument';
import { landingFacing } from './sim/landing';
import { bodyAtCell, cellOf, LEVEL_HEIGHT, type Body } from './sim/move';
import { BOARD_TIME, CALL_REACH, carBody, carLocal, depthMultiplier, inCar, RIDE_TIME, type RunEvent, type RunSummary, type Side } from './sim/run';
import { exertion, freshStamina } from './sim/stamina';

declare const __BUILD__: string;

// URL flags used by tests and by the owner when checking in. More are added as features land.
const params = new URLSearchParams(location.search);
const urlSeed = params.get('seed');
const seed0 = urlSeed ?? 'orientation';
/** ?depth=N starts the run on floor N (the run normally starts at 1). */
const startDepth = Math.max(1, Math.floor(Number(params.get('depth') ?? '1')) || 1);
const debug = params.get('debug') === '1';
// ?preview=orderly[&anim=walk|idle|reach|duck|still] stands an entity model in the level.
const previewName = params.get('preview');
// The player's settings (saved in this browser). The address overrides some: ?voice=, ?subs=0, and
// ?fx=0 clean render, 1 the tape look (default), 2 heavy interference.
const settings = new SettingsStore(params);
// A device that lost its picture earlier draws more lightly: 1 = 8-bit and no shadows, 2 = also no tape look.
const safe = readSafeLevel(params);
const fxLevel: FxLevel = safe >= 2 ? 0 : settings.get('tape');
// The live Orderly is on every floor by default. ?entity=0 leaves the floor empty; ?preview=orderly
// shows a static figure instead.
const entityOn = params.get('entity') !== '0' && previewName !== 'orderly';
// A crew: ?room=CODE joins (or, in the tab that made it, hosts) that room; ?net=local keeps it to
// the tabs of this browser (BroadcastChannel), otherwise peer to peer over the internet (Trystero).
const roomParam = params.get('room')?.toUpperCase().replace(/[^A-Z0-9]/g, '').slice(0, 8) || null;
const netLocal = params.get('net') === 'local';

const canvas = document.getElementById('view') as HTMLCanvasElement;
const hud = document.getElementById('hud') as HTMLDivElement;
const overlay = document.getElementById('start') as HTMLDivElement;
const debugBox = document.getElementById('debug') as HTMLDivElement;

const renderer = new THREE.WebGLRenderer({ canvas, antialias: false, powerPreference: 'high-performance' });
renderer.setPixelRatio(1);
let lastRunEvent = 'none';
const diag = installDiagnostics(renderer, canvas, safe, () => ({
  build: __BUILD__, fx: fxLevel, frames: state.frames, lastRunEvent, phase: view?.phase ?? 'none', depth: view?.depth ?? 0,
  orderlyLoaded: orderlyView?.loaded ?? false, frameMs: stats.median(),
}));

// ---------------------------------------------------------------------------------------------
// The session. The run is always stepped by the network layer's host (src/net/host.ts), 20 times a
// second; this page's player always goes through a NetClient. Alone, this page is the host and its
// player is the only client, on an in-page link. In a crew, one page hosts and the others are clients.

const NAME_KEY = 'goingDown.name';
function readName(): string {
  try {
    const n = cleanName(localStorage.getItem(NAME_KEY) ?? '');
    if (n) return n;
  } catch {
    /* private window */
  }
  const n = `CONVICT ${String(1000 + Math.floor(Math.random() * 9000))}`;
  saveName(n);
  return n;
}
function saveName(n: string): void {
  try {
    localStorage.setItem(NAME_KEY, n);
  } catch {
    /* private window */
  }
}
let myName = readName();

const rules = new HostRules(entityOn, startDepth);
/** The host's run clock (seconds): real time times the test hooks' time scale. */
let vclock = 0;
let timeScale = 1;
/** Real seconds, for clients and the room. */
const realNow = (): number => performance.now() / 1000;
/** The session being played. */
let crew = new CrewSession(null, roomParam ? 'client' : 'host', myName, realNow());
/** A crew being gathered in the lobby while the solo run goes on behind it (the host's tab). */
let pending: CrewSession | null = null;
let seedOfRun = seed0;
/** Code of the room this tab is in, or null alone. */
let roomCode: string | null = roomParam;

function startRun(on: CrewSession): void {
  const runSeed = urlSeed ?? (on.peers().length > 0 ? randomSeed() : seed0);
  seedOfRun = runSeed;
  on.start({ seed: runSeed, prepare: rules.prepare, step: rules.step, now: vclock });
}
function randomSeed(): string {
  return `crew-${Math.floor(Math.random() * 1e9).toString(36)}`;
}
if (!roomParam) startRun(crew);

/** The client this page draws from (null before a run, on a client page). */
function client(): NetClient | null {
  return crew.client;
}
/** Local clock for the page's NetClient: the host's run clock on the host's page, real time elsewhere. */
function clientNow(): number {
  return crew.host ? vclock : realNow();
}
const myId = (): string => client()?.id ?? crew.myId;

// The floor drawn is the floor this page's player is on.
const backdrop = planFor(seed0, startDepth);
function wantedPlan(): FloorPlan {
  const c = client();
  if (c?.seed) return planFor(c.seed, c.localDepth);
  if (crew.host) return planFor(crew.host.seed, crew.host.state.depth);
  return backdrop;
}
let plan = wantedPlan();
let car = carFor(plan);
const world = buildWorld(plan);
const scene = world.scene;
const camera = new THREE.PerspectiveCamera(70, 16 / 9, 0.05, 90);
let elevator = new ElevatorView(car);
scene.add(elevator.group);

const player = new Player(plan, plan.landing.level, plan.landing.x, plan.landing.y, yawForDir(landingFacing(plan)));
/** Puts the player in the car where the run starts them, facing the doors. */
function placeInCar(body: Body | null): void {
  player.body = body ? { ...body } : startBody(car, 0, 1);
  player.yaw = yawForDir(landingFacing(plan));
  player.pitch = 0;
}
placeInCar(crew.host?.state.players.find((p) => p.id === crew.myId)?.body ?? null);
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
const figures = new CrewFigures(scene);
const audio = new GameAudio();
audio.setVolume(settings.get('volume'));
// The elevator's voice (recorded lines through a speaker built in Web Audio), in the voice and with the
// subtitles the settings say.
const announcer = new Announcer(() => audio.context, () => audio.output, import.meta.env.BASE_URL, document.body, settings.get('subtitles'), settings.get('voice'));
announcer.startRun();
const caughtFx = new CaughtFx(document.body);
const endScreen = new EndScreen(document.body);
const crewList = new CrewList(document.body);
const lobby = new Lobby(document.body, overlay);

// The crew's instruments, the tapes on the floor, and the prompts.
const instrument = new InstrumentView();
const tapeDrops = new TapeDrops(scene);
const pickupPrompt = new PickupPrompt(document.body, () => void tryPickUp());
/** Set by the test hook __gd.raise(); null leaves it to the player's input. */
let forcedRaise: boolean | null = null;
/** The instrument's audible ticks, counted here from its tick rate (the needle kicks on each). */
let tickPhase = 0;

// The elevator's controls: the call button on the landing, the door-hold button in the car.
/** A call is pressed: sent with the next input. */
let pendingCall = false;
/** A pick-up is pressed: sent with the next input. */
let pendingPick = false;
/** Set by runCtl.hold(); null leaves holding the doors to the player. */
let forcedHold: boolean | null = null;
const liftPrompt = new ActionPrompt(document.body, 'lift-prompt', () => {
  if (canCall()) pendingCall = true;
});

/** The run as this page shows it (refreshed during the frame). */
let view: RunView | null = null;
const callTracker = new CallTracker();
function readView(): RunView | null {
  const c = client();
  if (crew.host && crew.host.state) return hostView(crew.host);
  return c ? clientView(c, callTracker) : null;
}
view = readView();

/** The nearest floor tape within reach of `body`, or null. */
function tapeInReach(body: Body): { id: string; d: number } | null {
  let best: { id: string; d: number } | null = null;
  for (const f of view?.floor ?? []) {
    if (f.at.level !== body.level) continue;
    const d = Math.hypot(f.at.x - body.x, f.at.y - body.y, f.at.z - body.z);
    if (d <= PICKUP_REACH && (!best || d < best.d)) best = { id: f.id, d };
  }
  return best;
}

function tryPickUp(): { ok: boolean; reason: string; tapeId: string | null } {
  if (caughtFx.noiseOn || endScreen.shown) return { ok: false, reason: 'inactive', tapeId: null };
  const near = tapeInReach(player.body);
  if (!near) return { ok: false, reason: view?.floor.length ? 'tooFar' : 'noTape', tapeId: null };
  const h = crew.host;
  if (!h) {
    // Another page's host picks it up on its next tick.
    pendingPick = true;
    return { ok: true, reason: 'ok', tapeId: near.id };
  }
  // The host's own player: at once, so a stopped clock (tests) cannot swallow the key press.
  let out = { ok: false, reason: 'noTape', tapeId: null as string | null };
  h.act((s) => {
    const id = crew.myId;
    const c = { ...s.crew, members: s.crew.members.map((m) => (m.id === id ? { ...m, body: { ...player.body } } : m)) };
    const r = pickUpTape(c, id, near.id);
    out = { ok: r.ok, reason: r.reason, tapeId: r.ok ? near.id : null };
    return { state: { ...s, crew: r.crew }, events: r.event ? [{ ...r.event, t: s.t }] : [] };
  });
  return out;
}

let catches = 0;
/** The local player's screen shows the figure this frame (NetClient's own sight test). */
let orderlyVisible = false;
let squeak = { gain: 0, muffled: false };
/** Per-frame record for tests: what was drawn against where the run has it. */
const trace: { f: number; vis: boolean; dx: number; dz: number; lx: number; lz: number; t: number; anim: string; clip: number }[] = [];

// The scene is drawn at a low internal resolution, then put on screen through the tape pass.
const INTERNAL_HEIGHT = 270;
// ?hdr=0 forces the 8-bit render path that older phones fall back to.
// Phones take the 8-bit path from the start: it is the cheaper one and costs nothing visible there.
const tape = new Tape(renderer, fxLevel, INTERNAL_HEIGHT, params.get('hdr') === '0' || safe >= 1 || phoneLike());
const osd = new Osd(document.body, seed0);
osd.visible = fxLevel > 0;
/** Lights glare through the tape; the clean render keeps them as built. */
const LIGHT_GAIN = 3;
let lightGain = fxLevel > 0 ? LIGHT_GAIN : 1;
/** Sets the tape look (0 clean, 1 normal, 2 heavy) and everything that goes with it. */
function applyFx(level: number): FxLevel {
  const l = tape.setFx(level);
  osd.visible = l > 0;
  lightGain = l > 0 ? LIGHT_GAIN : 1;
  return l;
}

// ---------------------------------------------------------------------------------------------
// The settings panel. Esc on a computer (the browser releases the mouse, and the panel opens in place
// of the start screen), the gear button on a phone; closed the same way or by clicking back into the
// game. It never pauses the run.
const panel = new SettingsPanel(document.body);
panel.choice('voice', 'VOICE', () => announcer.voices().map((v) => ({ value: v.id, label: v.name })), () => settings.get('voice'), (v) => settings.set('voice', v));
panel.action('sample', 'PLAY A SAMPLE', () => {
  audio.unlock();
  announcer.sample();
});
panel.choice('subtitles', 'SUBTITLES', () => [{ value: true, label: 'ON' }, { value: false, label: 'OFF' }], () => settings.get('subtitles'), (v) => settings.set('subtitles', v));
panel.choice<TapeLook>('tape', 'TAPE LOOK', () => [{ value: 0, label: 'OFF' }, { value: 1, label: 'NORMAL' }, { value: 2, label: 'HEAVY' }], () => settings.get('tape'), (v) => settings.set('tape', v));
panel.stepper('volume', 'VOLUME', () => settings.get('volume'), (n) => settings.set('volume', n), { step: 0.1, min: 0, max: 1, format: (n) => String(Math.round(n * 100)) });
panel.action('close', 'BACK TO THE GAME', () => closePanel());
settings.onChange((key, v) => {
  if (key === 'voice') announcer.setVoice(v.voice);
  else if (key === 'subtitles') announcer.setSubtitles(v.subtitles);
  else if (key === 'tape') applyFx(v.tape);
  else if (key === 'volume') audio.setVolume(v.volume);
  panel.refresh();
});
/** The panel was opened by losing the mouse: closing it asks for the mouse back. */
let panelFromUnlock = false;
function openPanel(fromUnlock: boolean): void {
  panelFromUnlock = fromUnlock;
  panel.open();
}
function closePanel(): void {
  panel.close();
  if (panelFromUnlock && !input.locked) input.relock();
  panelFromUnlock = false;
}
input.onUnlock = () => {
  if (endScreen.shown || lobby.shown) return false;
  openPanel(true);
  return true;
};
input.onEscape = () => {
  // The Esc that released the mouse may arrive too: ignore it straight after opening.
  if (performance.now() - panel.changedAt < 300) return;
  if (panel.isOpen) closePanel();
  else openPanel(false);
};
// Clicking (or tapping) back into the game closes it.
window.addEventListener('pointerdown', () => {
  if (panel.isOpen && performance.now() - panel.changedAt > 200) closePanel();
});
// A refused mouse lock (closing with Esc is not always allowed to take it back) shows the start screen.
document.addEventListener('pointerlockerror', () => {
  if (!input.touch && !panel.isOpen && !lobby.shown) overlay.hidden = false;
});
const coarsePointer = typeof matchMedia === 'function' && matchMedia('(pointer: coarse)').matches;
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

/** The local player's camera as the network layer judges sight: eye height above the feet, the real field of view. */
function localFrame(): LocalFrame {
  const vFov = camera.fov;
  const hFov = (2 * Math.atan(Math.tan((vFov * DEG) / 2) * camera.aspect)) / DEG;
  return { body: { ...player.body }, eye: EYE_HEIGHT, yaw: player.yaw, pitch: player.pitch, hFovDeg: hFov, vFovDeg: vFov };
}

/** The pose to hold while it is seen: frozen within reach of you while hunting, it is drawn reaching. */
function freezePose(p: DrawnPose): DrawnPose {
  const b = player.body;
  const mode = view?.orderly.mode;
  const near = Math.hypot(b.x - p.x, b.z - p.z) <= REACH_RANGE && Math.abs(b.y - p.y) < 1;
  if (near && p.anim !== 'reach' && (mode === 'hunting' || mode === 'windUp')) return { ...p, anim: 'reach', animTime: WIND_UP_TIME * 0.85 };
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

function me(v: RunView | null = view) {
  return v?.players.find((p) => p.id === myId()) ?? null;
}

function canCall(): boolean {
  const s = view;
  if (!s || s.phase !== 'away' || caughtFx.noiseOn || endScreen.shown) return false;
  const b = player.body;
  return b.level === car.level && !inCar(car, b) && Math.hypot(b.x - car.doorX, b.z - car.doorZ) <= CALL_REACH - 0.05;
}

function nearHoldButton(): boolean {
  if (view?.phase !== 'boarding' || !inCar(car, player.body)) return false;
  const { u, v } = carLocal(car, player.body.x, player.body.z);
  return Math.hypot(u - 0.3, v - HOLD_BUTTON.x) <= 0.75;
}

/** What the car is doing, in one word. */
function carState(): 'arriving' | 'open' | 'away' | 'coming' | 'riding' | 'ended' {
  const p = view?.phase;
  if (p === 'unloading' || p === 'boarding') return 'open';
  if (p === 'arriving') return 'arriving';
  if (p === 'away') return 'away';
  if (p === 'coming') return 'coming';
  if (p === 'riding') return 'riding';
  return 'ended';
}

/** Updates the indicator from the run (and, when the car has left empty, its cosmetic climb). */
function showIndicator(now: number): void {
  const s = view;
  if (!s) return;
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
      elevator.setIndicator(label, true, c && c.falseStop ? 0 : -1);
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

/** The bell's warning dings and the announcer's bell line, as the boarding countdown passes them. */
function bellCheck(): void {
  const s = view;
  if (!s || s.phase !== 'boarding') return;
  for (const w of BELL_WARNINGS) if (prevBellLeft > w && s.bellLeft <= w) audio.bellWarning();
  if (prevBellLeft > ANNOUNCE_BELL_AT && s.bellLeft <= ANNOUNCE_BELL_AT) announcer.bellSoon();
  prevBellLeft = s.bellLeft;
}

/** The floor this page's player is on changed (rode down, a new run, joined a crew): rebuild it. */
function newFloor(next: FloorPlan): void {
  if (next === plan) return;
  plan = next;
  car = carFor(plan);
  replaceFloor(world, plan);
  elevator.dispose();
  elevator = new ElevatorView(car);
  scene.add(elevator.group);
  elevator.setDoors(view ? doorsOpenView(view) : false, true);
  appliedLight = { gain: -1, level: -1 };
  autoWalk.cancel('new floor');
  carWalk = null;
  trace.length = 0;
  if (minimap) {
    minimap.canvas.remove();
    minimap = new Minimap(plan);
    debugBox.append(minimap.canvas);
  }
  setHud();
}

function setHud(): void {
  hud.textContent = `Going Down  build ${__BUILD__}  seed ${seedOfRun}  depth ${view?.depth ?? startDepth}${roomCode ? `  crew ${roomCode}` : ''}`;
}

/** Everything that belongs to one run starts over (a new run, or the first run of a crew). */
let runs = 0;
let runClient: NetClient | null = null;
let eventsSeen = 0;
/** The first placement of a run turns the player to face the doors. */
let facePending = false;
function resetForRun(): void {
  runClient = client();
  // A run begins for this page (GO DOWN, or a client let into one): the lobby gives way to the game.
  if (runClient && lobby.shown && !crew.ended && !pending) lobby.hide();
  eventsSeen = 0;
  callTracker.reset();
  view = readView();
  newFloor(wantedPlan());
  if (crew.host) placeInCar(crew.host.state.players.find((p) => p.id === crew.myId)?.body ?? null);
  facePending = !crew.host;
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
  pendingPick = false;
  autoWalk.cancel('new run');
  carWalk = null;
  audio.resetLift();
  tape.setDarkness(0);
  prevBellLeft = BOARD_TIME;
  if (runs > 0) announcer.startRun();
  figures.clear();
  stride = { x: 0, z: 0, t: 0, have: false };
  player.stamina = freshStamina();
  player.gait = 'walk';
  runs++;
  setHud();
}

/** A new run on the same crew, without reloading (the host decides; alone, that is you). */
function restartRun(): void {
  if (!crew.host) return;
  startRun(crew);
  resetForRun();
}

function shareOf(s: RunSummary, id: string): number {
  return s.shares[id] ?? 0;
}

function summaryLines(s: RunSummary): EndLine[] {
  const n = (v: number): string => String(Math.floor(v)).padStart(4, '0');
  const ids = Object.keys(s.shares);
  const lines: EndLine[] = [
    { text: 'BANKED', strong: true },
    { text: '' },
    { text: `FLOORS ${s.depth}` },
    { text: `READINGS ${s.readings}` },
    { text: `TOTAL ${n(s.total)}`, strong: true },
    { text: `YOUR SHARE ${n(shareOf(s, myId()))}`, strong: true },
  ];
  if (ids.length > 1) {
    lines.push({ text: '' });
    for (const id of ids) lines.push({ text: `${(nameOf(id) || id).padEnd(14).slice(0, 14)} ${n(shareOf(s, id))}`, strong: id === myId() });
  }
  lines.push({ text: '' }, { text: `LIFETIME ${n(lifetime)}` }, { text: '' }, { text: againText() });
  return lines;
}

function againText(): string {
  if (!crew.host) return 'THE HOST STARTS THE NEXT RUN';
  return input.touch ? 'TAP FOR A NEW RUN' : 'PRESS A KEY FOR A NEW RUN';
}

function showEnd(now: number): void {
  if (!ending || endScreen.shown) return;
  const wait = ending.kind === 'banked' ? 2600 : ending.kind === 'wiped' ? NOISE_MS + 200 : 1500;
  if (now - ending.at < wait) return;
  audio.ride(false);
  const again = { text: againText() };
  if (ending.kind === 'banked' && ending.summary) endScreen.show(summaryLines(ending.summary));
  else if (ending.kind === 'wiped') {
    endScreen.show([
      { text: 'NOBODY CAME BACK UP', strong: true },
      { text: '' },
      { text: `FLOORS ${ending.summary?.depth ?? view?.depth ?? 1}` },
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

/** Events that change what is seen and heard (sounds, doors, the end), in host order, each once. */
function present(events: readonly RunEvent[], now: number): void {
  const orderlyEvs: OrderlyEvent[] = [];
  const crewEvs: CrewEvent[] = [];
  const id = myId();
  announcer.onEvents(events, startDepth);
  for (const e of events) {
    lastRunEvent = e.type;
    diag.note(e.type);
    callTracker.onEvent(e);
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
        const total = view?.call?.floors ?? e.floorsAway;
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
      case 'rodeDown':
        audio.ride(false);
        rideStartedAt = -1;
        break;
      case 'banked':
        addLifetime(shareOf(e.summary, id));
        ending = { kind: 'banked', at: now, summary: e.summary };
        audio.ride(true, 3);
        break;
      case 'wiped':
        ending = { kind: 'wiped', at: now, summary: e.summary };
        break;
      case 'leftBehind':
        if (e.playerId === id) ending = { kind: 'leftBehind', at: now, summary: null, lost: e.lostValue };
        break;
      default:
        break;
    }
  }
  for (const e of orderlyEvs) {
    if (e.type !== 'caught' || e.playerId !== id) continue;
    // Placeholder: interference, noise, and back to the landing (caughtFx decides when).
    catches++;
    tape.glitch(NOISE_MS + 500, 1);
    caughtFx.start(now);
    audio.caughtBurst();
  }
  for (const e of crewEvs) {
    if (e.playerId !== id) continue;
    if (e.type === 'slip') {
      instrument.printSlip(e.text);
      audio.slipPrinted();
    } else if (e.type === 'readingClosed') {
      audio.readingClosed();
      lastReadingDepth = view?.depth ?? 1;
    }
  }
}

// ---------------------------------------------------------------------------------------------
// Walking in and out of the car (tests): straight lines through the doorway with the run's collision.
let carWalk: { points: { u: number; v: number }[]; resolve: () => void; reject: (e: Error) => void; stuck: number } | null = null;

function startCarWalk(u: number, v: number): Promise<void> {
  carWalk?.reject(new Error('replaced by a new walk'));
  autoWalk.cancel('car walk');
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

function mover(b: Body, dx: number, dz: number, r: number): Body {
  return moveLocal(plan, view?.phase ?? 'arriving', b, dx, dz, r);
}

function stepCarWalk(dt: number): void {
  const w = carWalk;
  if (!w) return;
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
  player.body = mover(before, (wx / dist) * step, (wz / dist) * step, 0.3);
  player.yaw = yawToward(wx, wz);
  if (Math.hypot(player.body.x - before.x, player.body.z - before.z) < step * 0.2) {
    if ((w.stuck += dt) > 1.5) {
      carWalk = null;
      w.reject(new Error('car walk stuck (doors shut?)'));
    }
  } else w.stuck = 0;
}

// ---------------------------------------------------------------------------------------------
// One network frame: the local player's camera and intents in, what to draw out.
let wantRaisedNow = false;
let holdNow = false;
/** The latest network frame. */
let netFrame: Frame | null = null;

function intents(): LocalFrame {
  const lf = localFrame();
  lf.raised = wantRaisedNow;
  lf.holdDoors = holdNow;
  lf.gait = player.gait;
  lf.stamina = { ...player.stamina };
  if (pendingCall) lf.call = true;
  if (pendingPick) lf.pickUp = true;
  pendingCall = false;
  pendingPick = false;
  return lf;
}

/**
 * Being taken, on this screen: the moment the network layer latches (the wind-up it drew ended and
 * nothing saw it) the picture cuts hard to black through a tape glitch, held until the caught noise
 * takes over. A latch the host calls off (a crewmate looked in time) ends in a tape drop-out and the
 * picture snaps back. The player is held still meanwhile: they are in its hands.
 */
let wasTaken = false;
function showTaken(f: Frame, falseRelease: boolean): void {
  if (f.taken && !wasTaken) tape.glitch(260, 1);
  if (!f.taken && wasTaken && falseRelease) tape.glitch(420, 0.9);
  caughtFx.blackout(f.taken);
  wasTaken = f.taken;
}

/** The host moved this page's player: adopt it (and the floor it is on). */
function adopt(f: Frame): void {
  if (!f.placed) return;
  newFloor(wantedPlan());
  player.body = { ...f.placed };
  autoWalk.cancel('placed');
  carWalk = null;
  if (facePending) {
    facePending = false;
    player.yaw = yawForDir(landingFacing(plan));
    player.pitch = 0;
  }
}

/** The host's machine: the run's ticks that are due, then any glance reported since. */
function hostStep(): void {
  const h = crew.host;
  if (!h) return;
  h.update(vclock);
  for (const id of rules.revived.splice(0)) {
    // Back on their feet at the landing (this page's own player walks there itself, after the noise).
    if (id !== crew.myId) h.placePlayer(id, bodyAtCell(h.state.plan, h.state.plan.landing));
  }
  h.flushReports(vclock);
}

/** Events that have arrived since the last frame. */
function takeEvents(): RunEvent[] {
  const c = client();
  if (!c || c !== runClient) return [];
  const out = c.events.slice(eventsSeen);
  eventsSeen = c.events.length;
  return out;
}

/** Runs the host's clock forward `n` ticks at once (tests: skip a wait), a network frame per tick. */
function skipTicks(n: number, stop?: (types: string[]) => boolean): RunEvent[] {
  const h = crew.host;
  const c = client();
  if (!h || !c) return [];
  const from = h.log.length;
  for (let i = 0; i < n; i++) {
    const logBefore = h.log.length;
    vclock += TICK;
    c.receive(vclock);
    const f = c.frame(vclock, intents());
    adopt(f);
    showTaken(f, c.latchReleased);
    hostStep();
    c.receive(vclock);
    view = readView();
    bellCheck();
    if (stop?.(h.log.slice(logBefore).map((e) => e.e.type))) break;
  }
  return h.log.slice(from).map((e) => e.e);
}

// ---------------------------------------------------------------------------------------------
// The crew around this page: names, figures, the list in the corner.

function nameOf(id: string): string {
  return crew.nameOf(id);
}

/** A jumpsuit number for a player: the digits of a CONVICT name, else from their id. */
function suitNumber(id: string): string {
  const m = /(\d{4})/.exec(nameOf(id));
  if (m?.[1]) return m[1];
  let h = 2166136261;
  for (let i = 0; i < id.length; i++) h = Math.imul(h ^ id.charCodeAt(i), 16777619);
  return String(1000 + ((h >>> 0) % 9000));
}

function memberTotal(id: string): number {
  const m = view?.crew.find((c) => c.id === id);
  return m ? m.tape.total + m.carrying.reduce((s, t) => s + t.total, 0) : 0;
}

function crewRows(): CrewRow[] {
  const v = view;
  if (!v) return [];
  const rows: CrewRow[] = v.players.map((p) => ({
    name: nameOf(p.id) || '...',
    me: p.id === myId(),
    mark: p.status === 'caught' ? 'TAKEN' : p.status === 'leftBehind' ? (p.connected ? 'LEFT' : 'GONE') : !p.connected ? 'GONE' : '',
    total: memberTotal(p.id),
  }));
  // Watchers: in the room, not yet in the run (they board at the next stop).
  const inRun = new Set(v.players.map((p) => p.id));
  for (const p of crew.people()) if (!inRun.has(p.id) && p.here && crew.runningEpoch > 0 && crew.role === 'host') rows.push({ name: p.name, me: p.me, mark: 'WATCHING', total: 0 });
  return rows;
}

function drawFigures(f: Frame | null, dt: number): void {
  const v = view;
  if (!f || !v || f.depth !== client()?.localDepth) {
    figures.sync([], dt);
    return;
  }
  const order = v.players.map((p) => p.id);
  const list: CrewFigureState[] = [];
  for (const p of f.players) {
    const snap = v.players.find((q) => q.id === p.id);
    if (p.status !== 'ok' || !snap?.connected) continue;
    list.push({
      id: p.id,
      name: nameOf(p.id) || '...',
      number: suitNumber(p.id),
      slot: Math.max(0, order.indexOf(p.id)),
      x: p.body.x,
      y: p.body.y,
      z: p.body.z,
      yaw: p.yaw,
      pitch: p.pitch,
      raised: v.crew.find((m) => m.id === p.id)?.raised ?? false,
      gait: p.gait,
    });
  }
  if (list.length > 0 && entityOn === false && safe === 0) renderer.shadowMap.enabled = true;
  figures.sync(list, dt);
}

// ---------------------------------------------------------------------------------------------
// The local player's instrument as the run has it.

function myMember(): Instrument | null {
  const h = crew.host;
  if (h) return member(h.state.crew, crew.myId)?.instrument ?? null;
  const m = view?.crew.find((c) => c.id === myId());
  if (!m) return null;
  const k = 1 - Math.exp(-m.open / TICK_SCALE);
  return {
    raised: m.raised,
    needle: m.needle,
    current: m.open > 0 ? { value: m.open, duration: 0 } : null,
    rate: m.rate,
    factor: 1,
    distance: null,
    tickHz: m.tickHz,
    loudness: m.open > 0 ? LOUDNESS_MIN + (LOUDNESS_MAX - LOUDNESS_MIN) * k : m.tickHz > 0 ? LOUDNESS_REST : 0,
    tickPhase: 0,
    ticks: 0,
    recorded: 0,
  } as unknown as Instrument;
}

function heldTapes(): { count: number; value: number; carrying: number; own: number } {
  const h = crew.host;
  if (h) {
    const m = member(h.state.crew, crew.myId);
    if (!m) return { count: 0, value: 0, carrying: 0, own: 0 };
    const all = [m.tape, ...m.carrying];
    return { count: all.filter((t) => t.readings.length > 0).length, value: tapeValue(all), carrying: m.carrying.length, own: tapeValue(m.tape) };
  }
  const m = view?.crew.find((c) => c.id === myId());
  if (!m) return { count: 0, value: 0, carrying: 0, own: 0 };
  const all = [m.tape, ...m.carrying];
  return { count: all.filter((t) => t.readings > 0).length, value: all.reduce((s, t) => s + t.total, 0), carrying: m.carrying.length, own: m.tape.total };
}

// ---------------------------------------------------------------------------------------------
// The Orderly's walk clock: walking clips run on the distance it has walked, so a creep is a slow
// stride (as when the run's host smoothed it). Derived from the pose drawn, so it stops when it does.
let stride = { x: 0, z: 0, t: 0, have: false };
function strideOf(p: Pose): number {
  if (stride.have) {
    const d = Math.hypot(p.x - stride.x, p.z - stride.z);
    if (d < 1) stride.t += d / HUNT_SPEED;
  }
  stride = { x: p.x, z: p.z, t: stride.t, have: true };
  return stride.t;
}

function orderlyInfo() {
  if (!orderlyView || !view) return null;
  const h = crew.host;
  const s: OrderlyState | null = h ? h.state.orderly : null;
  const o = view.orderly;
  const c = cellOf(plan, o);
  const b = player.body;
  const d = orderlyView.drawn;
  return {
    x: s ? s.body.x : o.x,
    y: s ? s.body.y : o.y,
    z: s ? s.body.z : o.z,
    level: o.level,
    cx: c.x,
    cy: c.y,
    yaw: (s ? s.yaw : o.yaw) / DEG,
    phase: o.mode,
    frozen: s ? s.frozen : o.frozen && (o.mode === 'hunting' || o.mode === 'windUp'),
    held: s ? s.held : o.frozen,
    moving: view.orderly.moving,
    /** The local player's screen shows it this frame. */
    seen: orderlyVisible,
    /** The same, as judged by the network layer's sight test. */
    logicSeen: orderlyVisible,
    anim: o.anim,
    animTime: o.animTime,
    distance: Math.hypot(b.x - (s ? s.body.x : o.x), b.z - (s ? s.body.z : o.z)),
    t: view.t,
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
  const s = view;
  const mine = me();
  const c = s?.call ?? null;
  return {
    phase: s?.phase ?? 'none',
    depth: s?.depth ?? 0,
    t: s?.t ?? 0,
    car: carState(),
    doorsOpen: s ? doorsOpenView(s) : false,
    /** The doors as drawn: 0 shut .. 1 open. */
    doors: elevator.status().doors,
    indicator: { floorsAway: c?.floorsAway ?? 0, label: elevator.status().indicator, falseStop: c ? c.falseStop : false },
    eta: c?.eta ?? null,
    blink: s ? blinkingView(s) : false,
    blinkSoon: s ? blinkWarningView(s) : false,
    /** The screen is dark for a blink this frame (the network layer's window), or blind while taken. */
    dark: netFrame?.dark ?? false,
    /** This screen has committed to being taken (black until the catch lands or is called off). */
    taken: netFrame?.taken ?? false,
    vote: mine?.side ?? null,
    votes: elevator.status().votes,
    aboard: mine?.aboard ?? false,
    status: mine?.status ?? 'ok',
    bellLeft: s?.bellLeft ?? 0,
    holdLeft: s?.holdLeft ?? 0,
    held: s?.held ?? false,
    calls: s?.calls ?? 0,
    banked: s?.summary && !s.summary.wiped ? s.summary.total : 0,
    summary: s?.summary ?? null,
    lifetime,
    multiplier: depthMultiplier(s?.depth ?? 1),
    lastReadingDepth,
    planKey: planKey(),
    ended: ending?.kind ?? null,
    endShown: endScreen.shown,
    endText: endScreen.text,
    runs,
    softCatches: rules.softCatches,
    callPrompt: !liftPrompt.el.hidden && canCall(),
    holdPrompt: !liftPrompt.el.hidden && nearHoldButton(),
    lightLevel: appliedLight.level,
    car3: { doorX: car.doorX, doorZ: car.doorZ, inX: car.inX, inZ: car.inZ, rightX: car.rightX, rightZ: car.rightZ, level: car.level },
  };
}

/** Replaces the run's Orderly (host only). */
function setOrderly(f: (o: OrderlyState) => OrderlyState): void {
  const h = crew.host;
  if (!h) return;
  h.replaceOrderly(f(h.state.orderly));
  // A test's teleport is not a move: this page drops the pose it was drawing (or holding, if it was in
  // view) and draws the new one from the next snapshot, as on a new floor.
  client()?.forgetOrderly();
}

// ---------------------------------------------------------------------------------------------
// Rooms and the lobby.

const CODE_ALPHABET = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';
function newCode(): string {
  const a = new Uint8Array(5);
  crypto.getRandomValues(a);
  return [...a].map((b) => CODE_ALPHABET[b % CODE_ALPHABET.length]).join('');
}
const HOST_KEY = 'goingDown.hosting';
function hostingMarker(): string | null {
  try {
    return sessionStorage.getItem(HOST_KEY);
  } catch {
    return null;
  }
}
function setHostingMarker(code: string): void {
  try {
    sessionStorage.setItem(HOST_KEY, code);
  } catch {
    /* private window: a reload of this tab joins instead of hosting */
  }
}
function roomUrl(code: string): string {
  const p = new URLSearchParams();
  p.set('room', code);
  if (netLocal) p.set('net', 'local');
  return `${location.origin}${location.pathname}?${p.toString()}`;
}
/** Opens the room's transport: BroadcastChannel for ?net=local, Trystero otherwise. */
async function openTransport(code: string): Promise<Transport> {
  if (netLocal) return new BroadcastTransport(code);
  const { TrysteroTransport } = await import('./net/trysteroTransport');
  return TrysteroTransport.open(code);
}
/** Seconds after which a joining tab that has heard no host says so. */
const NO_HOST_AFTER = 12;
let netError = '';

/** Alone: START A CREW. The solo run goes on behind the lobby until GO DOWN. */
async function startCrew(code = newCode()): Promise<string> {
  if (pending || roomCode) return roomCode ?? code;
  roomCode = code;
  setHostingMarker(code);
  const p = new URLSearchParams(location.search);
  p.set('room', code);
  history.replaceState(null, '', `${location.pathname}?${p.toString()}`);
  lobby.showHost(code, roomUrl(code), myName);
  lobby.setStatus('OPENING THE ROOM...');
  try {
    const t = await openTransport(code);
    pending = new CrewSession(t, 'host', myName, realNow());
  } catch (e) {
    netError = String(e);
    lobby.setStatus('COULD NOT OPEN THE ROOM.\nCHECK THE CONNECTION.');
  }
  setHud();
  return code;
}

/** The host: GO DOWN. Everyone in the room starts a run together. */
function goDown(fromClick = false): boolean {
  if (pending) {
    crew.close();
    crew = pending;
    pending = null;
  }
  // Still opening the room (or not hosting): nothing to start yet.
  if (crew.role !== 'host' || (roomCode !== null && crew.isSolo)) return false;
  lobby.hide();
  startRun(crew);
  resetForRun();
  if (fromClick) input.relock();
  else input.dismissOverlay();
  return true;
}

/** A joining tab: JOIN. */
/** JOIN was pressed (maybe before the room's transport had opened: it joins as soon as it has). */
let joinWanted = false;
function join(fromClick = false): void {
  joinWanted = true;
  crew.join(realNow());
  lobby.joined();
  updateLobby();
  if (fromClick) input.relock();
}

async function openRoom(code: string): Promise<void> {
  const hosting = hostingMarker() === code;
  if (hosting) lobby.showHost(code, roomUrl(code), myName);
  else lobby.showJoin(code, myName);
  lobby.setStatus('LOOKING FOR THE CREW...');
  try {
    const t = await openTransport(code);
    if (hosting) {
      // This tab made the room (and was reloaded): it hosts again, alone until GO DOWN.
      crew = new CrewSession(null, 'host', myName, realNow());
      startRun(crew);
      resetForRun();
      pending = new CrewSession(t, 'host', myName, realNow());
    } else {
      crew = new CrewSession(t, 'client', myName, realNow());
      if (joinWanted) crew.join(realNow());
    }
  } catch (e) {
    netError = String(e);
    lobby.setStatus('COULD NOT REACH THE INTERNET.\nCHECK THE CONNECTION.');
  }
}

lobby.onCrew = () => void startCrew();
lobby.onGoDown = () => void goDown(true);
lobby.onJoin = () => join(true);
lobby.onLeave = () => {
  crew.close();
  pending?.close();
  try {
    sessionStorage.removeItem(HOST_KEY);
  } catch {
    /* nothing kept */
  }
  location.href = `${location.origin}${location.pathname}${netLocal ? '?net=local' : ''}`;
};
lobby.onName = (n) => {
  myName = n;
  saveName(n);
  crew.setName(n);
  pending?.setName(n);
};
if (roomParam) void openRoom(roomParam);
window.addEventListener('pagehide', () => {
  crew.close();
  pending?.close();
});

/** What the lobby says, every few frames. */
function updateLobby(): void {
  if (!lobby.shown) return;
  const on = pending ?? crew;
  if (crew.ended) return;
  lobby.setPeople(on.people().filter((p) => p.here).map((p) => ({ name: p.name, host: p.host, me: p.me })));
  if (on.role === 'host') {
    const n = on.peers().length;
    lobby.setCanGo(pending !== null);
    if (pending) lobby.setStatus(n === 0 ? 'WAITING FOR THE CREW.\nOR GO DOWN ALONE.' : 'READY WHEN YOU ARE');
    return;
  }
  const waited = realNow() - on.since;
  if (on.hostPeer === null) lobby.setStatus(waited > NO_HOST_AFTER ? 'NOBODY IS HOSTING THIS CODE.\nASK FOR A NEW LINK.' : `LOOKING FOR THE CREW... ${Math.floor(waited)}`);
  else if (!on.hasJoined) lobby.setStatus('PRESS JOIN');
  else if (on.runningEpoch === 0) lobby.setStatus('WAITING FOR THE HOST\nTO GO DOWN');
  else lobby.setStatus('A RUN IS ON.\nYOU BOARD AT THE NEXT STOP.');
}

// ---------------------------------------------------------------------------------------------
// Test hooks. Yaw is in degrees: 0 faces north (-z), 90 west, 180 south, -90 east.
const state = {
  ready: false,
  frames: 0,
  build: __BUILD__,
  seed: seed0,
  get depth() {
    return view?.depth ?? startDepth;
  },
  gpu: gpuName(),
  probeColours,
  probePixels,
  /** The floor plan this page's player is on. */
  get plan() {
    return plan;
  },
  player: () => {
    const c = cellOf(plan, player.body);
    return { ...player.body, eye: player.body.y + EYE_HEIGHT, cx: c.x, cy: c.y, yaw: player.yaw / DEG, pitch: player.pitch / DEG, inCar: inCar(car, player.body), gait: player.gait, speed: player.lastSpeed };
  },
  /**
   * The local player's breath: the page's tank (0..1) and whether winded, the gait, how out of
   * breath that sounds and looks (0..1), and the host's copy (the truth, a round trip old).
   */
  stamina: () => {
    const h = client()?.hostStamina ?? null;
    return {
      level: player.stamina.level,
      winded: player.stamina.winded,
      gait: player.gait,
      exertion: exertion(player.stamina),
      vignette: tape.tired,
      breath: audio.breathState(),
      host: h ? { level: h.level, winded: h.winded } : null,
      ctrlCreep: input.ctrlCreep,
    };
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
    if (inCar(car, player.body)) return Promise.reject(new Error('in the elevator car: step out first (runCtl.walkCar)'));
    return autoWalk.start(plan, player, { level, x: cx, y: cy });
  },
  frameMs: () => stats.median(),
  /** Tape strength: 0 clean, 1 default, 2 heavy. */
  fx: () => tape.fx,
  setFx: (level: number) => applyFx(level),
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
  /** The live Orderly as this page has it, or null with ?entity=0. Positions in metres, yaw in degrees. */
  orderly: orderlyInfo,
  /** Everything the Orderly's logic has reported so far (as this page heard it). */
  events: (): OrderlyEvent[] => (orderlyView ? (client()?.events ?? []).filter(isOrderlyEvent).map((e) => ({ ...e })) : []),
  catches: () => catches,
  caught: () => ({ noise: caughtFx.noiseOn, line: caughtFx.lineOn }),
  /** Test controls for the live Orderly (null with ?entity=0). They act on the host's page. */
  entityCtl: orderlyView && {
    /** Stands it in a cell; refused (false) for a cell it could never be in (not walkable: a wall, the void). */
    placeCell: (level: Level, cx: number, cy: number, yawDegrees?: number): boolean => {
      if (!isWalkable(plan, level, cx, cy)) return false;
      const body = bodyAtCell(plan, { level, x: cx, y: cy });
      setOrderly((o) => ({ ...o, body, yaw: yawDegrees === undefined ? o.yaw : yawDegrees * DEG, path: null, replanIn: 0 }));
      return true;
    },
    placeAt: (x: number, z: number, level: Level = 0, yawDegrees?: number) => {
      const body = { x, z, level, y: level === 1 ? LEVEL_HEIGHT : 0 };
      setOrderly((o) => ({ ...o, body, yaw: yawDegrees === undefined ? o.yaw : yawDegrees * DEG, path: null, replanIn: 0 }));
    },
    /** Ends its waiting (or dormancy): it hunts on the next tick it is free to act. */
    wake: () => setOrderly((o) => (o.mode === 'waiting' || o.mode === 'dormant' ? { ...o, mode: 'hunting', dormantLeft: 0, replanIn: 0, path: null } : o)),
    /** Puts it to rest (dormant) for `seconds` of logic time, where it stands. */
    rest: (seconds: number) => setOrderly((o) => ({ ...o, mode: 'dormant', dormantLeft: seconds, path: null, moving: false, speed: 0 })),
    /** Logic seconds per real second: the whole run's clock (the Orderly is stepped by the run). */
    setTimeScale: (k: number) => {
      timeScale = Math.max(0, k);
    },
    /** Per-frame records: drawn position (dx, dz) against the run's (lx, lz), and visibility. */
    trace: () => trace.slice(),
    /** Widest reach of the mesh from its feet axis per clip, metres (measured at load). */
    extents: () => Object.fromEntries(['idle', 'walk', 'duck', 'reach', 'still'].map((n) => [n, orderlyView?.model.extent(n) ?? 0])),
    ticks: () => crew.host?.tick ?? 0,
  },
  audio: { state: () => audio.state() },
  /** The announcer: what is playing, waiting and said this run; say(id) asks for a line (false if it cannot). */
  announcer: { state: () => announcer.state(), say: (id: string) => announcer.say(id) },
  /** The settings in force, and the panel (open, close, whether open, whether its gear button shows). */
  settings: {
    get: () => ({ ...settings.all }),
    open: () => openPanel(false),
    close: () => closePanel(),
    isOpen: () => panel.isOpen,
    gearShown: () => !panel.gear.hidden,
  },
  /** The local player's instrument: the run's state and what is drawn. */
  instrument: () => {
    const i = myMember();
    if (!i) return null;
    const t = heldTapes();
    return {
      raised: i.raised,
      needle: i.needle,
      /** Value of the reading open now (0 if none). */
      value: i.current?.value ?? 0,
      /** Seconds recorded in the open reading. */
      recording: i.current?.duration ?? 0,
      /** Everything held: own tape plus tapes picked up. */
      total: t.value,
      own: t.own,
      tickHz: i.tickHz,
      loudness: i.loudness,
      /** Tapes held with something on them. */
      tapes: t.count,
      carrying: t.carrying,
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
    (view?.floor ?? []).map((f) => {
      const c = cellOf(plan, f.at);
      return { id: f.id, value: f.total, readings: f.readings, owner: f.owner, x: f.at.x, y: f.at.y, z: f.at.z, level: f.at.level, cx: c.x, cy: c.y };
    }),
  /** Tries to pick up the nearest tape within reach. */
  pickUp: () => tryPickUp(),
  /** Every crew event (slip, readingClosed, tapeDropped, tapePickedUp) so far. */
  crewEvents: (): CrewEvent[] => (client()?.events ?? []).filter(isCrewEvent).map((e) => ({ ...e })),
  /** Whether the pick-up prompt is showing. */
  pickupShown: () => !pickupPrompt.el.hidden,
  /** The run: phase, depth, the car, the indicator, the blink, the vote, the totals. */
  run: runInfo,
  /** Every run event so far, with its type and time. */
  runEvents: (): { type: string; t: number }[] => (client()?.events ?? []).map((e) => ({ ...e })),
  /** Test controls for the run (they act on the host's page). */
  runCtl: {
    /** Presses the call button (from where the player stands; `force` presses it from the landing wherever they are). */
    call: (opts: { force?: boolean } = {}) => {
      const ok = view?.phase === 'away' && (opts.force === true || canCall());
      if (ok) {
        if (opts.force && crew.host) rules.forceCall(crew.myId, carBody(car, -0.8, 0));
        else pendingCall = true;
      }
      return ok;
    },
    /** Holds the doors (true), lets go (false), or hands it back to the player (null). */
    hold: (on: boolean | null) => {
      forcedHold = on;
    },
    /** Logic seconds per real second (the whole run). */
    setTimeScale: (k: number) => {
      timeScale = Math.max(0, k);
    },
    /** Runs `seconds` of logic now, tick by tick through stepRun, the player standing as they are. */
    skip: (seconds: number) => skipTicks(Math.max(0, Math.round(seconds / TICK))).map((e) => e.type),
    /** Runs logic tick by tick until an event of this type, or `max` seconds. Returns whether it came. */
    skipUntil: (type: string, max = 120) => {
      let hit = false;
      skipTicks(Math.max(0, Math.round(max / TICK)), (types) => (hit = types.includes(type)));
      return hit;
    },
    /** Walks to car-local (u into the car, v to the right walking in), through the doorway if need be. */
    walkCar: (u: number, v: number) => startCarWalk(u, v),
    /** Starts a new run now (as the end screen's key does). */
    restart: () => restartRun(),
    /** A side of the car's floor in car-local metres: [u, v] of its middle. */
    spot: (side: Side) => (side === 'bank' ? [1.1, -0.5] : [1.1, 0.5]),
  },
  /** The network: this page's role, room, peers and their names, round trip, snapshot age. */
  net: () => {
    const c = client();
    const on = pending ?? crew;
    const now = realNow();
    return {
      role: on.role,
      room: roomCode,
      transport: on.isSolo ? 'none' : netLocal ? 'broadcast' : 'trystero',
      me: myId(),
      host: on.hostPeer,
      epoch: on.epoch,
      running: on.runningEpoch,
      ended: on.ended,
      joined: on.hasJoined,
      inRun: c?.playing ?? false,
      peers: on.peers().map((id) => ({ id, name: on.nameOf(id) })),
      people: on.people(),
      rttMs: c ? c.clock.rtt * 1000 : null,
      snapshotAgeMs: crew.host ? 0 : Number.isFinite(on.lastFromHost) ? (now - on.lastFromHost) * 1000 : null,
      snapshots: c?.stats.snapshots ?? 0,
      latches: c?.stats.latches ?? 0,
      falseLatches: c?.stats.falseLatches ?? 0,
      lobby: lobby.shown ? lobby.statusLine : null,
      error: netError,
    };
  },
  /** Every other player this page draws, with where, whether their instrument is up, and their gait (as the host allows it). */
  crew: () => figures.drawn.map((f) => ({ id: f.id, name: f.name, number: f.number, slot: f.slot, x: f.x, y: f.y, z: f.z, yaw: f.yaw / DEG, raised: f.raised, gait: f.gait ?? 'walk' })),
  /** Everyone in the run as this page last heard it from the host (where the host has them). */
  players: () =>
    (view?.players ?? []).map((p) => ({ id: p.id, name: nameOf(p.id), me: p.id === myId(), ...p.body, status: p.status, side: p.side, aboard: p.aboard, connected: p.connected, total: memberTotal(p.id) })),
  /** The crew list in the corner, as drawn (shown with more than one in the run). */
  crewList: () => ({ shown: !crewList.el.hidden, rows: crewList.rows }),
  /** The lobby without clicking: set a name, start a crew (optionally with a given code), join, go down. */
  lobby: {
    setName: (n: string) => {
      const c = cleanName(n);
      if (c) lobby.onName?.(c);
      lobby.nameInput.value = c;
      return c;
    },
    startCrew: (code?: string) => startCrew(code ? cleanName(code).replace(/\s/g, '') : undefined),
    join: () => join(false),
    goDown: () => goDown(false),
    shown: () => lobby.shown,
    status: () => lobby.statusLine,
  },
};
(window as unknown as { __gd: typeof state }).__gd = state;
setHud();
debugBox.hidden = !debug;
const debugText = document.createElement('div');
let minimap: Minimap | null = null;
if (debug) {
  debugBox.append(debugText);
  minimap = new Minimap(plan);
  debugBox.append(minimap.canvas);
}
runClient = client();
runs = 1;

const camForward = new THREE.Vector3();
const camUp = new THREE.Vector3();
let last = performance.now();
renderer.setAnimationLoop(() => {
  const now = performance.now();
  const ms = now - last;
  last = now;
  stats.add(ms);
  const dt = Math.min(ms / 1000, 0.1);
  if (crew.host) vclock += dt * timeScale;
  // The room: lobby messages, and the other players' messages for the host or this client.
  crew.pump(realNow());
  pending?.pump(realNow());
  if (crew.ended && !endScreen.shown && !lobby.shown) {
    lobby.showEnded('THE HOST LEFT. THE SESSION IS OVER.', 'START A NEW ONE');
    document.exitPointerLock?.();
  }
  if (client() !== runClient) resetForRun();
  const c = client();
  c?.receive(clientNow());
  view = readView();
  const ended = view?.phase === 'ended' || endScreen.shown;

  preview?.update(dt);
  // The instrument is up only while held (or forced by a test), never while the picture is noise.
  wantRaisedNow = !caughtFx.noiseOn && !ended && !lobby.shown && (forcedRaise ?? input.instrumentHeld());
  const h = crew.host;
  if (h) {
    // The host's own player raises it at once (the walk cap and the drawing answer on this frame).
    const m = member(h.state.crew, crew.myId);
    if (m && m.instrument.raised !== wantRaisedNow) h.state = { ...h.state, crew: setRaised(h.state.crew, crew.myId, wantRaisedNow) };
  }
  const raised = h ? (member(h.state.crew, crew.myId)?.instrument.raised ?? false) : wantRaisedNow;
  const playing = !caughtFx.noiseOn && !ended && !lobby.shown;
  // The tank: the host's truth (a round trip old) corrects this page's copy before the frame uses it.
  if (c) player.stamina = c.correctStamina(player.stamina);
  if (carWalk) {
    stepCarWalk(dt);
    player.idle(dt, WALK_SPEED);
  } else if (autoWalk.active) {
    autoWalk.tick(plan, player);
    player.idle(dt, WALK_SPEED);
  } else if (playing && netFrame?.taken !== true) player.control(plan, input, dt, raised ? maxWalkSpeed(true, WALK_SPEED) : Infinity, mover);
  else {
    input.takeLook();
    player.idle(dt);
  }
  // Breath, without a meter: breathing that rises as the tank empties (ragged when winded), and the
  // edge of the view closing in a little. A full tank is silent and draws exactly as before.
  const tired = playing ? exertion(player.stamina) : 0;
  audio.breathing(tired, playing && player.stamina.winded);
  tape.setTired(tired);
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
  const inReach = !caughtFx.noiseOn && !ended && tapeInReach(player.body) !== null;
  if (ePressed && inReach && !callable) tryPickUp();

  // The network frame: this frame's camera and intents go to the host; what to draw comes back. On
  // the host's page the run's due ticks follow, and any glance this frame is applied at once.
  let f: Frame | null = null;
  if (c) {
    f = c.frame(clientNow(), intents());
    adopt(f);
    showTaken(f, c.latchReleased);
  }
  hostStep();
  c?.receive(clientNow());
  newFloor(wantedPlan());
  view = readView();
  bellCheck();
  netFrame = f;
  present(takeEvents(), now);
  if (f?.placed) player.toCamera(camera);

  const s = view;
  const dark = f?.dark ?? false;
  orderlyVisible = f?.seeing ?? false;
  if (orderlyView) {
    const p = f?.orderly ?? null;
    orderlyView.setVisible(p !== null);
    if (p) {
      // Seen: held exactly as the network layer holds it. Unseen: as it draws it. Walking clips run
      // on the stride clock (the distance walked), so a creep is a slow stride.
      const pose: DrawnPose = { x: p.x, y: p.y, z: p.z, yaw: p.yaw, anim: p.anim, animTime: p.animTime };
      const st = strideOf(p);
      if (pose.anim === 'walk' || pose.anim === 'duck') pose.animTime = st;
      orderlyView.update(f?.held === true, pose, freezePose(pose));
      const d = orderlyView.drawn;
      const lo = crew.host ? crew.host.state.orderly.body : s?.orderly;
      if (d && lo) {
        trace.push({ f: state.frames + 1, vis: f?.held === true, dx: d.x, dz: d.z, lx: lo.x, lz: lo.z, t: s?.t ?? 0, anim: d.anim, clip: d.animTime });
        if (trace.length > 600) trace.shift();
      }
      // Sound: silent the instant it is seen, whatever the next tick says. Heard in the dark if it moves.
      const away = s?.phase === 'riding' || s?.phase === 'ended';
      const moving = s?.orderly.moving ?? false;
      squeak =
        orderlyVisible || f?.held || !moving || away || !s
          ? { gain: 0, muffled: false }
          : audibility(plan, { body: { x: p.x, y: p.y, z: p.z, level: p.level }, moving } as OrderlyState, { body: player.body, eye: EYE_HEIGHT });
      camForward.set(0, 0, -1).applyQuaternion(camera.quaternion);
      camUp.set(0, 1, 0).applyQuaternion(camera.quaternion);
      audio.update(dt, squeak.gain, squeak.muffled, { x: p.x, y: p.y + SQUEAK_HEIGHT, z: p.z }, camera.position, camForward, camUp, s?.orderly.speed ?? 0);
    } else {
      squeak = { gain: 0, muffled: false };
      audio.update(dt, 0, false, { x: 0, y: 0, z: 0 }, camera.position, camForward, camUp, 0);
    }
  }
  drawFigures(f, dt);

  // The elevator: doors, indicator, votes, the bell's warnings, the machinery, and the lights.
  showIndicator(now);
  if (s) {
    const mine = me(s);
    const bank = s.players.filter((p) => p.side === 'bank').length;
    const down = s.players.filter((p) => p.side === 'down').length;
    elevator.setVotes(mine?.side ?? null, bank, down);
  }
  const cl = s?.call ?? null;
  const machine = s?.phase === 'coming' && cl ? (1 - cl.floorsAway / Math.max(1, cl.floors)) * (cl.falseStop ? 0.5 : 1) + 0.05 : 0;
  audio.machinery(machine, { x: car.doorX, y: car.floorY + 1.5, z: car.doorZ });
  // The blink: a flicker through the warning, then a deep dark with tape noise, then the lights back.
  // Dark exactly while the network layer says so (its window covers the clock's uncertainty).
  const warn = s ? blinkWarningView(s) : false;
  let light = 1;
  if (dark) light = 0.07;
  // The warning: the tubes sag and stutter (never back to full), so a glance at any moment of it shows trouble.
  else if (warn) light = Math.floor(now / 55) % 4 === 1 || Math.floor(now / 140) % 3 === 2 ? 0.18 : 0.6;
  setLights(light);
  tape.setDarkness(dark ? 1 : 0);
  // The announcer: close in the car, from the speaker over the landing doors out on the floor.
  camForward.set(0, 0, -1).applyQuaternion(camera.quaternion);
  const inst = myMember();
  announcer.update({
    depth: s?.depth ?? startDepth,
    inCar: inCar(car, player.body),
    ear: camera.position,
    forward: camForward,
    speaker: { x: car.doorX, y: car.floorY + 2.3, z: car.doorZ },
    quiet: !dark && !warn && !inst?.current && !caughtFx.noiseOn && !ended,
  });
  elevator.update(dt, light, lightGain);

  // The instrument, its sound, the tapes on the floor and the tape count.
  if (inst) {
    tickPhase += inst.tickHz * dt;
    const ticks = Math.floor(tickPhase);
    tickPhase -= ticks;
    instrument.setTouchLayout(input.touch);
    instrument.update(dt, {
      raised: h ? inst.raised : wantRaisedNow,
      needle: inst.needle,
      value: inst.current?.value ?? 0,
      distance: inst.distance,
      tickHz: inst.tickHz,
      ticks,
      walkSpeed: player.lastSpeed,
    });
    audio.ticking(inst.tickHz, inst.loudness);
  } else tickPhase = 0;
  tapeDrops.sync((s?.floor ?? []).map((t) => ({ tape: { id: t.id }, at: t.at })));
  tapeDrops.update(dt);
  const held = heldTapes();
  osd.setTapes(held.count, held.value);
  pickupPrompt.update(inReach && !callable, input.touch);

  // The crew in the corner (only with company), and the lobby.
  const rows = crewRows();
  crewList.update(rows, rows.length > 1 && !endScreen.shown && !lobby.shown);
  if (state.frames % 5 === 0) updateLobby();

  showEnd(now);
  // The gear button: phones only (never on a computer, so never in the reference pictures).
  panel.showGear((input.touch || coarsePointer) && overlay.hidden && !endScreen.shown && !lobby.shown);
  tape.render(scene, camera, instrument.visible ? instrument : null);
  osd.update(!tape.motion || Math.floor(now / 700) % 2 === 0);
  state.frames++;
  state.ready = true;

  if (debug && state.frames % 10 === 0 && s) {
    const b = player.body;
    const cc = cellOf(plan, b);
    const fm = stats.median();
    const e = s.call?.eta ?? null;
    debugText.textContent =
      `fps ${fm > 0 ? (1000 / fm).toFixed(0) : '-'}  median ${fm.toFixed(1)} ms\n` +
      `tape fx${tape.fx}${tape.motion ? '' : ' (reduced motion)'}\n` +
      `pos ${b.x.toFixed(2)} ${b.y.toFixed(2)} ${b.z.toFixed(2)}\n` +
      `cell L${cc.level} (${cc.x},${cc.y})  yaw ${(player.yaw / DEG).toFixed(0)}\n` +
      `run ${s.phase}  depth ${s.depth}  car ${carState()}${e !== null ? `  eta ${e.toFixed(1)} s` : ''}${dark ? '  BLINK' : warn ? '  blink soon' : ''}\n` +
      `vote ${me(s)?.side ?? '-'}${s.phase === 'boarding' ? `  bell ${s.bellLeft.toFixed(1)} s  hold ${s.holdLeft.toFixed(1)} s${s.held ? ' HELD' : ''}` : ''}`;
    let ent: { level: Level; x: number; z: number; seen: boolean } | null = null;
    if (orderlyView) {
      const o = orderlyInfo();
      if (o) {
        debugText.textContent +=
          `\norderly ${o.phase}${o.frozen ? ' frozen' : ''}  ${orderlyVisible ? 'SEEN' : 'unseen'}  ${o.distance.toFixed(1)} m\n` +
          `squeak ${squeak.gain.toFixed(2)}${squeak.muffled ? ' muffled' : ''}  audio ${audio.state().running ? 'on' : 'off'}  catches ${catches}`;
        ent = { level: o.level, x: o.x, z: o.z, seen: orderlyVisible };
      }
    }
    if (inst) {
      debugText.textContent +=
        `\ninstrument ${inst.raised ? 'up' : 'down'} ${inst.needle}  value ${(inst.current?.value ?? 0).toFixed(1)}  tick ${inst.tickHz.toFixed(1)} Hz\n` +
        `tapes held ${held.count} worth ${held.value.toFixed(1)}  on floor ${s.floor.length}`;
    }
    const floorTapes = s.floor.map((t) => ({ level: t.at.level, x: t.at.x, z: t.at.z }));
    minimap?.update(cc.level, b.x, b.z, player.yaw, ent, floorTapes);
  }
});
