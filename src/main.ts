import * as THREE from 'three';
import { makeRng } from './sim/rng';

declare const __BUILD__: string;

// URL flags used by tests and by the owner when checking in. More are added as features land.
const params = new URLSearchParams(location.search);
const seed = params.get('seed') ?? 'orientation';

const canvas = document.getElementById('view') as HTMLCanvasElement;
const hud = document.getElementById('hud') as HTMLDivElement;

const renderer = new THREE.WebGLRenderer({ canvas, antialias: false, powerPreference: 'high-performance' });
renderer.setPixelRatio(1);

const scene = new THREE.Scene();
scene.background = new THREE.Color(0xe9efec);
scene.fog = new THREE.Fog(0xe9efec, 6, 22);

const camera = new THREE.PerspectiveCamera(70, 16 / 9, 0.05, 60);
camera.position.set(0, 1.65, 4);

// A placeholder room so the first screenshot proves the whole chain works: seed -> scene -> pixels.
const rng = makeRng(seed);
const tile = new THREE.MeshLambertMaterial({ color: 0xf4f7f5 });
const floor = new THREE.Mesh(new THREE.PlaneGeometry(8, 24), tile);
floor.rotation.x = -Math.PI / 2;
scene.add(floor);
for (const x of [-4, 4]) {
  const wall = new THREE.Mesh(new THREE.PlaneGeometry(24, 3), tile);
  wall.position.set(x, 1.5, 0);
  wall.rotation.y = x < 0 ? Math.PI / 2 : -Math.PI / 2;
  scene.add(wall);
}
const crateMat = new THREE.MeshLambertMaterial({ color: 0x9fd0b4 });
for (let i = 0; i < 6; i++) {
  const s = 0.4 + rng.next() * 0.6;
  const crate = new THREE.Mesh(new THREE.BoxGeometry(s, s, s), crateMat);
  crate.position.set(-3 + rng.next() * 6, s / 2, -8 + rng.next() * 9);
  crate.rotation.y = rng.next() * Math.PI;
  scene.add(crate);
}
scene.add(new THREE.HemisphereLight(0xffffff, 0xb8c4be, 1.6));
const key = new THREE.DirectionalLight(0xffffff, 1.2);
key.position.set(2, 6, 3);
scene.add(key);

// Low internal resolution, scaled up with hard pixels. The full tape look comes in a later task.
const INTERNAL_HEIGHT = 270;
function resize(): void {
  const aspect = window.innerWidth / Math.max(1, window.innerHeight);
  renderer.setSize(Math.round(INTERNAL_HEIGHT * aspect), INTERNAL_HEIGHT, false);
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

/** For tests: draw a frame and count distinct colours on a coarse grid, read straight from the GPU. */
function probeColours(): number {
  renderer.render(scene, camera);
  const gl = renderer.getContext();
  const w = gl.drawingBufferWidth;
  const h = gl.drawingBufferHeight;
  const px = new Uint8Array(w * h * 4);
  gl.readPixels(0, 0, w, h, gl.RGBA, gl.UNSIGNED_BYTE, px);
  const seen = new Set<number>();
  for (let y = 0; y < h; y += 6) {
    for (let x = 0; x < w; x += 6) {
      const i = (y * w + x) * 4;
      seen.add(((px[i] ?? 0) << 16) | ((px[i + 1] ?? 0) << 8) | (px[i + 2] ?? 0));
    }
  }
  return seen.size;
}

const state = { ready: false, frames: 0, build: __BUILD__, seed, gpu: gpuName(), probeColours };
(window as unknown as { __gd: typeof state }).__gd = state;
hud.textContent = `Going Down  build ${__BUILD__}  seed ${seed}`;

renderer.setAnimationLoop(() => {
  renderer.render(scene, camera);
  state.frames++;
  state.ready = true;
});
