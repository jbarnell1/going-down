// The lights of a floor, as one dial. 1 is every light on, exactly as built (the reference pictures
// are taken there); lower values are the lights failing: a blink takes the floor to a deep dark, not
// to black, so the tape's grain and lifted blacks still show shapes and the game never looks frozen.
//
// It scales, from values remembered the first time it sees them: every light's intensity, the
// ceiling light panels (the mesh named 'lights', with the tape's glare gain on top), every material's
// emission, and the background and fog colour.

import * as THREE from 'three';

interface Remembered {
  intensity?: number;
  emissive?: THREE.Color;
  colour?: THREE.Color;
}

const memo = new WeakMap<object, Remembered>();

function remember<T extends object>(o: T): Remembered {
  let r = memo.get(o);
  if (!r) {
    r = {};
    memo.set(o, r);
  }
  return r;
}

/** How dark the panels and the sky go for a given light level (panels die faster than the room). */
function panelLevel(level: number): number {
  return level >= 1 ? 1 : level * level;
}

/**
 * Applies a light level (0..1) and the light-panel glare gain to a scene. Objects whose userData has
 * `ownLight` are skipped (the elevator drives its own panel and buttons).
 */
export function applyLighting(scene: THREE.Scene, gain: number, level: number, background: number): void {
  const k = Math.max(0, Math.min(1, level));
  scene.traverse((o) => {
    if (o.userData.ownLight) return;
    const light = o as THREE.Light;
    if (light.isLight) {
      const r = remember(light);
      r.intensity ??= light.intensity;
      light.intensity = r.intensity * k;
      return;
    }
    const mesh = o as THREE.Mesh;
    if (!mesh.isMesh) return;
    const mats = Array.isArray(mesh.material) ? mesh.material : [mesh.material];
    for (const m of mats) {
      const r = remember(m);
      const basic = m as THREE.MeshBasicMaterial;
      if (mesh.name === 'lights' && basic.color) {
        r.colour ??= basic.color.clone();
        basic.color.copy(r.colour).multiplyScalar(gain * panelLevel(k));
      }
      const em = m as THREE.MeshLambertMaterial;
      if (em.emissive && !(em.emissive.r === 0 && em.emissive.g === 0 && em.emissive.b === 0 && !r.emissive)) {
        r.emissive ??= em.emissive.clone();
        em.emissive.copy(r.emissive).multiplyScalar(k);
      }
    }
  });
  const bg = new THREE.Color(background).multiplyScalar(panelLevel(k));
  if (scene.background instanceof THREE.Color) scene.background.copy(bg);
  if (scene.fog) scene.fog.color.copy(bg);
}

/**
 * The emergency lighting's level (0..1) `seconds` after the lights went out: the battery lights take
 * a moment, stutter, then hold. So a 1 s blink stays almost fully dark, and anything longer gets them.
 */
export const EMERGENCY_DELAY = 0.8;
export const EMERGENCY_RISE = 0.8;
export function emergencyLevel(seconds: number): number {
  if (seconds < EMERGENCY_DELAY) return 0;
  const k = Math.min(1, (seconds - EMERGENCY_DELAY) / EMERGENCY_RISE);
  if (k >= 1) return 1;
  // Two stutters on the way up.
  return Math.floor(seconds * 12) % 3 === 0 ? k * 0.25 : k;
}
