// Clinic textures, drawn in code: small, hard-edged, sampled with nearest filtering so they stay
// crisp at the low internal resolution. Every texture covers one 2 m cell (walls: one storey).

import * as THREE from 'three';

type Painter = (x: number, y: number) => readonly [number, number, number];

/** Cheap deterministic per-pixel noise in [0, 1). Row 0 is the bottom (v = 0). */
function noise(x: number, y: number, salt: number): number {
  let h = Math.imul(x * 374761393 + y * 668265263 + salt * 2147483647, 1274126177);
  h = Math.imul(h ^ (h >>> 13), 1103515245);
  return ((h ^ (h >>> 16)) >>> 0) / 4294967296;
}

function paint(w: number, h: number, fn: Painter): THREE.DataTexture {
  const data = new Uint8Array(w * h * 4);
  for (let y = 0; y < h; y++) {
    for (let x = 0; x < w; x++) {
      const [r, g, b] = fn(x, y);
      const i = (y * w + x) * 4;
      data[i] = Math.max(0, Math.min(255, Math.round(r)));
      data[i + 1] = Math.max(0, Math.min(255, Math.round(g)));
      data[i + 2] = Math.max(0, Math.min(255, Math.round(b)));
      data[i + 3] = 255;
    }
  }
  const t = new THREE.DataTexture(data, w, h, THREE.RGBAFormat);
  t.colorSpace = THREE.SRGBColorSpace;
  t.wrapS = THREE.RepeatWrapping;
  t.wrapT = THREE.RepeatWrapping;
  t.magFilter = THREE.NearestFilter;
  // Nearest texels up close; mip levels far away so long corridors do not crawl.
  t.minFilter = THREE.NearestMipmapLinearFilter;
  t.generateMipmaps = true;
  t.needsUpdate = true;
  return t;
}

/** White 50 cm tiles with grey grout, four by four per cell. */
export function floorTexture(): THREE.DataTexture {
  const tile = 16;
  return paint(64, 64, (x, y) => {
    if (x % tile === 0 || y % tile === 0) return [150, 156, 152];
    const t = noise(Math.floor(x / tile), Math.floor(y / tile), 1) * 8;
    const n = noise(x, y, 2) * 6;
    const v = 236 + t + n - 6;
    return [v, v + 2, v];
  });
}

/**
 * One storey of wall, 3.2 m tall, 1 px = 2.5 cm: a dark skirting, a pale field, and one washed-out
 * green stripe at hand height (about 0.9 to 1.1 m).
 */
export function wallTexture(): THREE.DataTexture {
  return paint(32, 128, (x, y) => {
    const n = noise(x, y, 3) * 5;
    if (y < 5) return [150 + n, 165 + n, 156 + n]; // skirting
    if (y === 5) return [120, 132, 126];
    if (y === 36 || y === 44) return [150 + n, 182 + n, 160 + n]; // stripe edges
    if (y > 36 && y < 44) return [178 + n, 210 + n, 186 + n]; // stripe
    if (x === 0) return [214, 218, 213]; // faint panel seam every 2 m
    return [232 + n, 236 + n, 230 + n];
  });
}

/** Ceiling tiles on a light T-bar grid. */
export function ceilingTexture(): THREE.DataTexture {
  const tile = 16;
  return paint(64, 64, (x, y) => {
    if (x % tile === 0 || y % tile === 0) return [200, 204, 202];
    const n = noise(x, y, 4) < 0.12 ? -14 : 0;
    return [234 + n, 236 + n, 234 + n];
  });
}
