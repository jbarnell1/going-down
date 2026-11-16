// The other members of the crew, drawn in the world: low-detail convicts in jumpsuits built from
// boxes in code (no model files). Each has a jumpsuit tint and a number on the chest and back, a
// head that turns and tilts where its player looks, a walk bob and swinging limbs while moving, the
// instrument held up in both hands while theirs is raised, and a name tag above in the camcorder
// font. Each casts a contact shadow the way the Orderly does: a light straight down with a small
// frustum following the figure onto a shadow-only patch under its feet (the light has no intensity,
// so it darkens only that patch and lights nothing).

import * as THREE from 'three';
import { drawText, textWidth } from './pixelFont';

/** Jumpsuit colours, one per crew slot (prison orange first). */
export const SUIT_TINTS = [0xd0662c, 0x5f86ad, 0xc4a12a, 0x7c9a46, 0xa94540, 0x8a70b2, 0x4f9e93, 0xb7ab98];

export interface CrewFigureState {
  id: string;
  name: string;
  /** Jumpsuit number (four digits). */
  number: string;
  /** Index into SUIT_TINTS. */
  slot: number;
  x: number;
  y: number;
  z: number;
  /** Where they look (three.js yaw/pitch, radians). */
  yaw: number;
  pitch: number;
  raised: boolean;
}

const SKIN = 0xc9a088;
const HAIR = 0x2a2420;
const BOOT = 0x22211f;
const DEVICE = 0x2c2f2e;
const HIP = 0.86;
const SHOULDER = 1.45;
const NECK = 1.53;

function label(text: string, colour: string, bg: string | null, px: number): HTMLCanvasElement {
  const w = textWidth(text) + 4;
  const c = document.createElement('canvas');
  c.width = w * px;
  c.height = 11 * px;
  const g = c.getContext('2d');
  if (g) {
    if (bg) {
      g.fillStyle = bg;
      g.fillRect(0, 0, c.width, c.height);
    }
    g.fillStyle = colour;
    drawText(g, text, 2 * px, 2 * px, px);
  }
  return c;
}

function texture(c: HTMLCanvasElement): THREE.CanvasTexture {
  const t = new THREE.CanvasTexture(c);
  t.magFilter = THREE.NearestFilter;
  t.minFilter = THREE.NearestFilter;
  t.generateMipmaps = false;
  t.colorSpace = THREE.SRGBColorSpace;
  return t;
}

/** A box with its top face at y = 0 (so it hangs from its pivot). */
function hanging(w: number, h: number, d: number): THREE.BoxGeometry {
  return new THREE.BoxGeometry(w, h, d).translate(0, -h / 2, 0);
}

class Figure {
  readonly root = new THREE.Group();
  private readonly body = new THREE.Group();
  private readonly head = new THREE.Group();
  private readonly armL = new THREE.Group();
  private readonly armR = new THREE.Group();
  private readonly legL = new THREE.Group();
  private readonly legR = new THREE.Group();
  private readonly device: THREE.Mesh;
  private readonly tag: THREE.Sprite;
  private readonly light: THREE.DirectionalLight;
  private readonly catcher: THREE.Mesh;
  private readonly disposables: { dispose(): void }[] = [];
  private tagText = '';
  private suitKey = '';
  private readonly suitMat: THREE.MeshLambertMaterial;
  private readonly chestMat: THREE.MeshLambertMaterial;
  private phase = 0;
  private bodyYaw: number | null = null;
  private raise = 0;
  private last: { x: number; z: number } | null = null;
  private speed = 0;

  constructor(private readonly scene: THREE.Scene) {
    const mat = (c: number): THREE.MeshLambertMaterial => {
      const m = new THREE.MeshLambertMaterial({ color: c });
      this.disposables.push(m);
      return m;
    };
    this.suitMat = mat(0xffffff);
    this.chestMat = new THREE.MeshLambertMaterial({ color: 0xffffff });
    this.disposables.push(this.chestMat);
    const mesh = (g: THREE.BufferGeometry, m: THREE.Material | THREE.Material[]): THREE.Mesh => {
      this.disposables.push(g);
      const x = new THREE.Mesh(g, m);
      x.castShadow = true;
      return x;
    };
    const suit = this.suitMat;
    // Torso: the number patch on the chest (-z, the front) and the back (+z).
    const torso = mesh(new THREE.BoxGeometry(0.46, SHOULDER + 0.06 - HIP, 0.26), suit);
    torso.position.y = (SHOULDER + 0.06 + HIP) / 2;
    const front = mesh(new THREE.PlaneGeometry(0.3, 0.1).rotateY(Math.PI), this.chestMat);
    front.position.set(0, 1.28, -0.132);
    const back = mesh(new THREE.PlaneGeometry(0.36, 0.12), this.chestMat);
    back.position.set(0, 1.22, 0.132);
    front.castShadow = false;
    back.castShadow = false;
    this.body.add(front, back);
    // A collar and the belt line, a shade darker.
    const collar = mesh(new THREE.BoxGeometry(0.3, 0.05, 0.27), mat(0x2b2a28));
    collar.position.y = SHOULDER + 0.05;
    this.body.add(torso, collar);
    // Head: face, hair cap, ears.
    const skin = mat(SKIN);
    const face = mesh(new THREE.BoxGeometry(0.24, 0.27, 0.25).translate(0, 0.16, 0), skin);
    const hair = mesh(new THREE.BoxGeometry(0.25, 0.07, 0.26).translate(0, 0.31, 0.005), mat(HAIR));
    const eyes = mesh(new THREE.BoxGeometry(0.16, 0.03, 0.01).translate(0, 0.2, -0.128), mat(0x141210));
    this.head.add(face, hair, eyes);
    this.head.position.y = NECK;
    this.body.add(this.head);
    // Arms hang from the shoulders, hands at the end.
    for (const [arm, side] of [
      [this.armL, -1],
      [this.armR, 1],
    ] as const) {
      const sleeve = mesh(hanging(0.12, 0.5, 0.14), suit);
      const hand = mesh(hanging(0.1, 0.12, 0.1).translate(0, -0.5, 0), skin);
      arm.add(sleeve, hand);
      arm.position.set(side * 0.29, SHOULDER, 0);
      this.body.add(arm);
    }
    // Legs from the hips, boots at the end.
    for (const [leg, side] of [
      [this.legL, -1],
      [this.legR, 1],
    ] as const) {
      const trouser = mesh(hanging(0.17, HIP - 0.1, 0.19), suit);
      const boot = mesh(hanging(0.18, 0.1, 0.25).translate(0, -(HIP - 0.1), -0.03), mat(BOOT));
      leg.add(trouser, boot);
      leg.position.set(side * 0.11, HIP, 0);
      this.body.add(leg);
    }
    // The instrument, held in both hands in front of the chest when raised.
    this.device = mesh(new THREE.BoxGeometry(0.22, 0.15, 0.12), mat(DEVICE));
    this.device.position.set(0, 1.2, -0.42);
    this.device.visible = false;
    this.body.add(this.device);
    this.root.add(this.body);

    this.tag = new THREE.Sprite(new THREE.SpriteMaterial({ transparent: true, depthWrite: false }));
    this.tag.position.y = 2.12;
    this.root.add(this.tag);

    this.light = new THREE.DirectionalLight(0xffffff, 0);
    this.light.castShadow = true;
    const cam = this.light.shadow.camera;
    cam.left = -1;
    cam.right = 1;
    cam.top = 1;
    cam.bottom = -1;
    cam.near = 0.5;
    cam.far = 10;
    this.light.shadow.mapSize.set(256, 256);
    this.light.shadow.bias = -0.002;
    this.light.shadow.radius = 1.5;
    this.catcher = new THREE.Mesh(new THREE.PlaneGeometry(2, 2).rotateX(-Math.PI / 2), new THREE.ShadowMaterial({ opacity: 0.38, depthWrite: false }));
    this.catcher.receiveShadow = true;
    this.catcher.renderOrder = 1;
    this.disposables.push(this.catcher.geometry, this.catcher.material as THREE.Material);
    scene.add(this.root, this.light, this.light.target, this.catcher);
  }

  update(s: CrewFigureState, dt: number): void {
    // Suit colour and number.
    const key = `${s.slot}|${s.number}`;
    if (key !== this.suitKey) {
      this.suitKey = key;
      const tint = new THREE.Color(SUIT_TINTS[s.slot % SUIT_TINTS.length] ?? 0xd0662c);
      this.suitMat.color.copy(tint);
      const c = label(s.number, '#1b1a18', `#${tint.getHexString()}`, 2);
      this.chestMat.map?.dispose();
      this.chestMat.map = texture(c);
      this.chestMat.needsUpdate = true;
    }
    const name = s.name.toUpperCase();
    if (name !== this.tagText) {
      this.tagText = name;
      const c = label(name, '#e8ece9', 'rgba(8,10,9,0.55)', 1);
      const m = this.tag.material;
      m.map?.dispose();
      m.map = texture(c);
      m.needsUpdate = true;
      this.tag.scale.set((c.width / c.height) * 0.2, 0.2, 1);
    }
    // Walking: speed from how far the drawn position moved.
    const moved = this.last ? Math.hypot(s.x - this.last.x, s.z - this.last.z) : 0;
    this.last = { x: s.x, z: s.z };
    const v = dt > 0 && moved < 1 ? moved / dt : 0;
    this.speed += (v - this.speed) * Math.min(1, dt * 10);
    const walking = this.speed > 0.25;
    this.phase += dt * Math.min(this.speed, 4) * 3.4;
    const swing = walking ? Math.sin(this.phase) * Math.min(0.55, this.speed * 0.2) : 0;
    // The body turns toward where they look, lazily; the head the rest of the way.
    if (this.bodyYaw === null) this.bodyYaw = s.yaw;
    let d = wrap(s.yaw - this.bodyYaw);
    const lag = walking ? 8 : 3;
    this.bodyYaw = wrap(this.bodyYaw + d * Math.min(1, dt * lag));
    d = wrap(s.yaw - this.bodyYaw);
    if (Math.abs(d) > 1.1) {
      this.bodyYaw = wrap(s.yaw - Math.sign(d) * 1.1);
      d = Math.sign(d) * 1.1;
    }
    this.root.position.set(s.x, s.y, s.z);
    this.root.rotation.y = this.bodyYaw;
    this.body.position.y = walking ? Math.abs(Math.cos(this.phase)) * 0.045 : 0;
    this.head.rotation.set(Math.max(-0.7, Math.min(0.7, s.pitch)), d, 0, 'YXZ');
    this.legL.rotation.x = swing;
    this.legR.rotation.x = -swing;
    // Raised: both arms forward holding the instrument up at the chest.
    this.raise += ((s.raised ? 1 : 0) - this.raise) * Math.min(1, dt * 9);
    const up = this.raise;
    this.armL.rotation.set(-swing * (1 - up) + 1.25 * up, 0, -0.2 * up);
    this.armR.rotation.set(swing * (1 - up) + 1.25 * up, 0, 0.2 * up);
    this.device.visible = up > 0.5;
    // Its shadow follows.
    this.light.position.set(s.x, s.y + 4, s.z);
    this.light.target.position.set(s.x, s.y, s.z);
    this.light.target.updateMatrixWorld();
    this.catcher.position.set(s.x, s.y + 0.006, s.z);
  }

  dispose(): void {
    this.scene.remove(this.root, this.light, this.light.target, this.catcher);
    this.chestMat.map?.dispose();
    this.tag.material.map?.dispose();
    this.tag.material.dispose();
    this.light.dispose();
    for (const d of this.disposables) d.dispose();
  }
}

function wrap(a: number): number {
  let r = a % (2 * Math.PI);
  if (r > Math.PI) r -= 2 * Math.PI;
  if (r < -Math.PI) r += 2 * Math.PI;
  return r;
}

export class CrewFigures {
  private readonly figures = new Map<string, Figure>();
  /** What was drawn on the last frame (tests). */
  drawn: CrewFigureState[] = [];

  constructor(private readonly scene: THREE.Scene) {}

  /** Draws exactly these crew members this frame (and removes the rest). */
  sync(list: readonly CrewFigureState[], dt: number): void {
    const keep = new Set(list.map((s) => s.id));
    for (const [id, f] of this.figures) {
      if (!keep.has(id)) {
        f.dispose();
        this.figures.delete(id);
      }
    }
    for (const s of list) {
      let f = this.figures.get(s.id);
      if (!f) {
        f = new Figure(this.scene);
        this.figures.set(s.id, f);
      }
      f.update(s, dt);
    }
    this.drawn = list.map((s) => ({ ...s }));
  }

  clear(): void {
    this.sync([], 0);
  }
}
