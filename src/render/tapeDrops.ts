// Tapes lying on the floor where someone went down: a chunky black cassette, slightly askew, with a
// red lamp that blinks hard enough to glare through the tape look and a red stain of its light on the floor, so
// it can be found on a white floor from down a corridor.

import * as THREE from 'three';
import type { Body } from '../sim/move';

/** Cassette size, metres (deliberately oversized: it has to read at 270 lines). */
const SIZE = { w: 0.25, h: 0.055, d: 0.16 };
/** Lamp blink: period (s) and the share of it the lamp is lit. */
const BLINK_PERIOD = 0.9;
const BLINK_ON = 0.45;
/** Lamp brightness while lit (linear, above 1 so the tape's bloom catches it). */
const LAMP_GAIN = 6;
/** The red stain of light the lamp throws on the floor round it: radius (m) and opacity lit. It is
 * blended normally, not added: added light vanishes on a floor that is already white. */
const POOL_R = 0.65;
const POOL_ALPHA = 0.75;

function topTexture(): THREE.CanvasTexture {
  const c = document.createElement('canvas');
  c.width = 40;
  c.height = 26;
  const g = c.getContext('2d');
  if (g) {
    g.fillStyle = '#17181a';
    g.fillRect(0, 0, 40, 26);
    // Label.
    g.fillStyle = '#e9e4d2';
    g.fillRect(3, 3, 34, 12);
    g.fillStyle = '#c23a2a';
    g.fillRect(3, 5, 34, 2);
    g.fillStyle = '#6b675c';
    g.fillRect(6, 10, 22, 1);
    // Reel windows.
    g.fillStyle = '#4b3a2c';
    g.fillRect(9, 17, 7, 5);
    g.fillRect(24, 17, 7, 5);
    g.fillStyle = '#d9d4c4';
    g.fillRect(11, 18, 3, 3);
    g.fillRect(26, 18, 3, 3);
  }
  const t = new THREE.CanvasTexture(c);
  t.colorSpace = THREE.SRGBColorSpace;
  t.magFilter = THREE.NearestFilter;
  t.minFilter = THREE.NearestFilter;
  t.generateMipmaps = false;
  return t;
}

function poolTexture(): THREE.CanvasTexture {
  const c = document.createElement('canvas');
  c.width = 32;
  c.height = 32;
  const g = c.getContext('2d');
  if (g) {
    const grad = g.createRadialGradient(16, 16, 0, 16, 16, 16);
    grad.addColorStop(0, 'rgba(255,255,255,1)');
    grad.addColorStop(1, 'rgba(255,255,255,0)');
    g.fillStyle = grad;
    g.fillRect(0, 0, 32, 32);
  }
  return new THREE.CanvasTexture(c);
}

interface Drop {
  group: THREE.Group;
  lamp: THREE.MeshBasicMaterial;
  pool: THREE.MeshBasicMaterial;
  phase: number;
}

export class TapeDrops {
  private readonly drops = new Map<string, Drop>();
  private readonly shell = new THREE.MeshLambertMaterial({ color: 0x1a1b1d });
  private readonly top: THREE.MeshLambertMaterial;
  private readonly box = new THREE.BoxGeometry(SIZE.w, SIZE.h, SIZE.d);
  private readonly poolGeo = new THREE.PlaneGeometry(POOL_R * 2, POOL_R * 2).rotateX(-Math.PI / 2);
  private readonly poolTex = poolTexture();
  private time = 0;

  constructor(private readonly scene: THREE.Scene) {
    this.top = new THREE.MeshLambertMaterial({ map: topTexture() });
  }

  /** Makes the drawn tapes match the logic's floor list. */
  sync(floor: readonly { tape: { id: string }; at: Body }[]): void {
    const live = new Set(floor.map((f) => f.tape.id));
    for (const [id, d] of this.drops) {
      if (live.has(id)) continue;
      this.scene.remove(d.group);
      d.lamp.dispose();
      d.pool.dispose();
      this.drops.delete(id);
    }
    for (const f of floor) {
      if (this.drops.has(f.tape.id)) continue;
      this.drops.set(f.tape.id, this.make(f.tape.id, f.at));
    }
  }

  update(dt: number): void {
    this.time += dt;
    for (const d of this.drops.values()) {
      const p = ((this.time + d.phase) % BLINK_PERIOD) / BLINK_PERIOD;
      const on = p < BLINK_ON;
      d.lamp.color.setRGB(on ? LAMP_GAIN : 0.25, on ? LAMP_GAIN * 0.12 : 0.03, on ? LAMP_GAIN * 0.08 : 0.02);
      d.pool.opacity = on ? POOL_ALPHA : POOL_ALPHA * 0.2;
    }
  }

  get count(): number {
    return this.drops.size;
  }

  private make(id: string, at: Body): Drop {
    let h = 0;
    for (const ch of id) h = (h * 31 + ch.charCodeAt(0)) | 0;
    const group = new THREE.Group();
    group.position.set(at.x, at.y + SIZE.h / 2 + 0.002, at.z);
    group.rotation.y = ((h % 360) * Math.PI) / 180;
    const body = new THREE.Mesh(this.box, [this.shell, this.shell, this.top, this.shell, this.shell, this.shell]);
    group.add(body);
    const lamp = new THREE.MeshBasicMaterial({ color: 0xff0000 });
    const led = new THREE.Mesh(new THREE.BoxGeometry(0.04, 0.024, 0.018), lamp);
    led.position.set(SIZE.w * 0.36, SIZE.h / 2 + 0.004, SIZE.d * 0.33);
    group.add(led);
    const pool = new THREE.MeshBasicMaterial({ map: this.poolTex, color: 0x9a140c, transparent: true, opacity: POOL_ALPHA, depthWrite: false });
    const poolMesh = new THREE.Mesh(this.poolGeo, pool);
    poolMesh.position.set(at.x, at.y + 0.004, at.z);
    poolMesh.renderOrder = 2;
    const holder = new THREE.Group();
    holder.add(group, poolMesh);
    this.scene.add(holder);
    // The holder is what gets removed; keep the cassette's own transform on `group`.
    return { group: holder, lamp, pool, phase: (Math.abs(h) % 100) / 100 };
  }
}
