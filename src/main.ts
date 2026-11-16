import * as THREE from 'three';
import { AutoWalk } from './game/autoWalk';
import { Minimap } from './game/minimap';
import { FrameStats } from './game/frameStats';
import { Input } from './game/input';
import { EYE_HEIGHT, Player, yawForDir, yawToward } from './game/player';
import { EntityPreview } from './render/entityPreview';
import { Osd } from './render/osd';
import { setLightGain, Tape, type FxLevel } from './render/tape';
import { buildWorld } from './render/world';
import { generateClinic } from './sim/clinic';
import type { Level } from './sim/floor';
import { landingFacing } from './sim/landing';
import { bodyAtCell, cellOf } from './sim/move';

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
  tape.render(scene, camera);
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
  /** Hides the click-to-start overlay without a pointer lock. */
  start: () => input.dismissOverlay(),
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

let last = performance.now();
renderer.setAnimationLoop(() => {
  const now = performance.now();
  const ms = now - last;
  last = now;
  stats.add(ms);
  const dt = Math.min(ms / 1000, 0.1);

  preview?.update(dt);
  if (autoWalk.active) autoWalk.tick(plan, player);
  else player.control(plan, input, dt);
  player.toCamera(camera);
  tape.render(scene, camera);
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
    minimap?.update(c.level, b.x, b.z, player.yaw);
  }
});
